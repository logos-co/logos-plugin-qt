#ifndef LOGOS_CONSUMER_H
#define LOGOS_CONSUMER_H

#include "logos_protocol.h"

#include "logos_shared_api.h"

#include <QString>

class LogosAPI;
class QObject;

/**
 * @file logos_consumer.h
 * @brief Admitting a NON-MODULE CONSUMER to a running Logos system.
 *
 * WHAT A CONSUMER IS, and why it needed a name of its own. A module is loaded,
 * published to the registry, callable by anyone who can get a token for it, and
 * lives in --modules-dir. A CONSUMER is none of those things: it is a QML view,
 * an in-process widget plugin, or a co-process view host that only ever CALLS
 * out. It still needs an identity, because every outbound call presents a token
 * and something has to decide which tokens it may present.
 *
 * WHY THIS EXISTS AT ALL. Two applications hand-rolled the same three steps
 * independently — isolate a token store, mint a UUID, register that UUID with
 * capability_module — and the pure-QML identity bug was exactly one of them
 * getting the ORDER wrong: logos-basecamp did the registration inside its
 * has-a-backend branch, below an early return, so pure-QML plugins registered
 * nothing at all. It went unnoticed because the view was calling on the host's
 * ambient token ring, where every token already existed and no handshake ever
 * happened. A convention repeated in two places is a convention that will
 * differ in two places.
 *
 * WHY logos-plugin-qt AND NOT logos-liblogos. Both hand-rolled sites call
 * LogosAPI, which lives here; so does ui-host in logos-view-module-runtime,
 * which links this library and Qt but NOT liblogos. liblogos DEPENDS on this
 * library, so putting the operation there would put it above two images that
 * need it and cannot reach it. It also could not return the thing every caller
 * actually needs — a LogosAPI* for the identity — across the logos_core_* C
 * boundary, so a liblogos home would unify the TOKEN half and leave
 * LogosAPI::forIdentity hand-rolled at each site: the two halves split across a
 * repo boundary, which is precisely the split the ordering bug lived in.
 *
 * A SEPARATE HEADER, not a static on LogosAPI, because LogosAPI is the object
 * handed to every module and plugin, and this is a verb only a HOST may say.
 */
// ── the wave order, made a build failure ────────────────────────────────────
//
// A private token store is created EMPTY as of protocol 0.7. Everything that
// makes that survivable lives HERE and in the hosts: admitConsumer mints,
// registers and installs an identity's own credential. Bump logos-protocol
// past this repo and every isolated identity gets an empty store — the
// outbound handshake dies at ModuleProxy's `authToken.isEmpty()` and every
// in-process consumer is refused.
//
// Nothing would stop that build. Every LOGOS_PROTOCOL_VERSION_MINOR guard in
// the fleet is `>=`, so a newer protocol satisfies all of them, and in
// basecamp's ui_qml path the ui-host half keeps working — the co-process
// adopts its credential on stdin — so the integration tests can stay GREEN
// while every in-process bridge is refused.
//
// So the ordering constraint is spelled as a compile error rather than left to
// a reviewer. If this fires, the fix is to update logos-plugin-qt and the
// hosts in the same wave as the protocol bump, then raise the bound.
//
// RAISED 7 -> 8 for logos-protocol 0.8 (the INBOUND/OUTBOUND direction split),
// which is the wave THIS repo moves in: the glue emitted here now routes
// informModuleToken through logos_module_accept_inbound_token. The review the
// error above asks for, carried out against protocol 42460e5b:
//
//   * bootstrapKeys(), adoptCredential() and adoptCredentialFor() are
//     signature- and semantics-identical to 0.7. 0.8 changed the KEY NAMESPACE
//     (inbound is a reserved-prefix key, outbound stays the bare peer name),
//     not how a store is seeded, and TokenManager's layout is byte-identical.
//   * credential() became DERIVED from bootstrapKeys() rather than cached.
//     That STRENGTHENS this path: a cached field read empty on a store another
//     image wrote and then refused every push.
//   * 0.8's own adoptCredential() contract spells out both halves of what
//     admitConsumer needs -- OUTBOUND, the identity presents its credential and
//     capability_module's proxy resolves it from the caller-keyed inbound
//     record rather than an anchor key, so the caller is named as the identity
//     and not as the host; INBOUND, capability_module pushes with
//     getToken(moduleName), which IS that credential, so informModuleToken's
//     trusted-channel gate still passes.
//
// The consumer-admission check is the oracle, not this comment: it runs a real
// ModuleProxy in Local mode and asserts the consumer authorizes AS ITSELF.
#if defined(LOGOS_PROTOCOL_VERSION_MINOR) \
    && (LOGOS_PROTOCOL_VERSION_MAJOR > 0 \
        || (LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR > 8))
#  error "logos-protocol is newer than the consumer-admission contract this file implements. \
A private token store is created empty; if the protocol changed how a consumer is seeded, \
this file and the hosts calling logos::admitConsumer must move in the SAME wave. Review \
adoptCredentialFor / bootstrapKeys, then raise this bound."
#endif

namespace logos {

/**
 * @brief What a host gets back for an admitted consumer.
 *
 * `api` speaks AS the consumer, on the consumer's own isolated token store.
 * Hand it to the view / widget / bridge; it is parented to whatever `parent`
 * was passed to admitConsumer.
 *
 * `credential` is that identity's own token. Give it to a CO-PROCESS of the
 * same identity — ViewModuleHost::spawn hands it to ui-host, which adopts it
 * into its own image's store — and to nothing else. It is not a capability, it
 * is a name: anything holding it can speak as this consumer.
 */
struct ConsumerIdentity {
    LogosAPI* api = nullptr;
    QString   credential;

    explicit operator bool() const noexcept { return api != nullptr; }
};

/**
 * @brief Admit a non-module consumer under `identity`.
 *
 * ONE SENTENCE: gives a name a private token store, mints its credential, tells
 * capability_module about it, and puts it in that store — so the identity can
 * ask for capabilities, and can be NAMED when it does.
 *
 * The four steps, in this order, and the order is the mechanism:
 *
 *   1. TokenManager::isolateIdentity(identity) — must precede any client for
 *      the name, because LogosAPIClient captures its store as a raw pointer at
 *      construction. LogosAPI::forIdentity does this and then constructs.
 *   2. The LogosAPI is created on a store that is now EMPTY. It cannot call
 *      anything yet, and that is deliberate.
 *   3. REGISTER FIRST: informModuleToken(identity, credential) over `hostApi`'s
 *      trusted channel — synchronous, so it completes before this returns.
 *   4. ADOPT SECOND: the credential goes into the identity's own store.
 *
 * Register-before-adopt makes the bad window IMPOSSIBLE rather than merely
 * short: at no instant does the consumer hold a credential capability_module
 * has not already accepted. And all four steps complete before the caller
 * creates the bridge or widget, which closes the other race both hosts
 * documented — plugin constructors routinely schedule their first IPC via
 * QTimer::singleShot(0, ...), which fires the moment the event loop turns.
 *
 * `hostApi` is the HOST's LogosAPI (basecamp's "core", standalone's
 * "standalone"): informModuleToken is accepted only from the trusted
 * core/capability channel, and the host is that channel.
 *
 * Returns a falsy ConsumerIdentity on ANY failure, and every one of them is
 * fatal for the load rather than something to continue past:
 *   * the name could not be isolated (a client for it already exists on the
 *     ambient ring — half an identity is worse than none);
 *   * there is no capability_module client, or the host holds no
 *     capability_module token;
 *   * capability_module refused the registration.
 * Falling back to the host's own LogosAPI on any of these is what produced the
 * elevation this whole surface replaces.
 */
LOGOS_QT_HOST_API ConsumerIdentity admitConsumer(const QString& identity,
                                                 LogosAPI* hostApi,
                                                 QObject* parent = nullptr);

/**
 * @brief Rotate an already-admitted consumer's credential — a reload.
 *
 * Mint, register, RESET the identity's store, adopt. The reset is not
 * housekeeping: a reload re-registers, and ModuleProxy::saveToken overwrites
 * m_tokens[name], so the previous credential is dead at the target the instant
 * the new one is accepted. A store left holding the stale credential is a
 * locked-out reload that looks like a live one. The reset also drops per-target
 * tokens minted for the previous incarnation, which are stale anyway.
 *
 * Returns the new credential, or an empty string on failure — which is fatal
 * for the reload, for the same reasons admitConsumer's failures are.
 */
LOGOS_QT_HOST_API QString reissueConsumerCredential(LogosAPI* consumerApi,
                                                    LogosAPI* hostApi);

/**
 * @brief Adopt a credential that was minted and registered ELSEWHERE.
 *
 * For a co-process of an already-admitted identity: ui-host is handed its
 * parent's per-spawn credential on stdin and must install it in its own image's
 * token store. No isolation and no registration — the parent did both, and
 * doing either again from here would be wrong (a second registration would
 * invalidate the credential the parent is still holding).
 *
 * This exists so the bootstrap key set stops being spelled out in a fifth
 * place; TokenManager::bootstrapKeys() owns it.
 */
LOGOS_QT_HOST_API void adoptConsumerCredential(LogosAPI* consumerApi,
                                               const QString& credential);

} // namespace logos

#endif // LOGOS_CONSUMER_H
