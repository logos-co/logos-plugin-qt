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
 * WHO ADMITS IT. The runtime: a host asks core_service.admitConsumer, and
 * capability_module, the token authority, mints and records the credential.
 * This header only ADOPTS it: an isolated token store for the name, and the
 * credential installed in it. Hosts used to mint and register credentials
 * themselves, on their own trusted channel; that is gone.
 *
 * WHY logos-plugin-qt AND NOT logos-liblogos. Adoption builds a LogosAPI, which
 * lives here; so does ui-host in logos-view-module-runtime, which links this
 * library and Qt but NOT liblogos, and could not get a LogosAPI* across the
 * logos_core_* C boundary anyway.
 *
 * A SEPARATE HEADER, not a static on LogosAPI, because LogosAPI is the object
 * handed to every module and plugin, and this is a verb only a HOST may say.
 */
// ── the wave order, made a build failure ────────────────────────────────────
//
// A private token store is created EMPTY as of protocol 0.7. Everything that
// makes that survivable lives HERE and in the hosts: adoptAdmittedConsumer
// installs an identity's own credential. Bump logos-protocol
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
// RAISED 10 -> 11 for the Qt-free host callback additions. Protocol 0.11 adds
// a provider-side persistent-token validator and wildcard event subscription
// to the public C ABI. It does not change private stores, bootstrap keys,
// credential adoption, caller identity, or consumer admission; the Qt host
// continues to seed consumers exactly as it did at 0.10.
//
// RAISED 11 -> 12 for staged provider publication and a protocol-owned string
// copy helper. Both are additive and change no private store, bootstrap key,
// credential adoption, caller identity, or consumer-admission behavior.
//
// RAISED 12 -> 13 for inproc, caller resolvers, runtime delegates and token
// revocation. Seeding is untouched (TokenManager gains one non-virtual method),
// the Qt runtime refuses inproc, and only "@op:" keys read as operators.
//
// RAISED 8 -> 9 for logos-protocol 0.9 (subscription continuity: a liveness
// watchdog plus a per-TARGET status callback, generation counter and restart
// policy). Unlike the 0.8 wave below, this repo has nothing to move: 0.9 does
// not touch consumer admission at all. The review the error above asks for,
// carried out against the 0.8 -> 0.9 range (42460e5b..the 0.9 head):
//
//   * bootstrapKeys(), adoptCredential(), adoptCredentialFor(), credential()
//     and admitConsumer() have ZERO changed lines across the range.
//   * No token, capability, credential or caller-scope file is touched;
//     token_manager.{h,cpp} is byte-identical, so TokenManager's layout — which
//     the host allocates and module images mutate — is unchanged.
//   * The whole surface added is the EVENT path (logos_api_consumer's pending
//     registry and its per-target record, logos_protocol's
//     lp_client_set_subscription_status_cb and friends) plus a mock-fixture
//     fix. A consumer is seeded exactly as it was at 0.8.
//
// So this raise records "nothing to do", not "reviewed and migrated". If a
// later protocol changes how a store is seeded, this bound must fire again.
//
// THE BOUND IS `>` AND NOT `>=` ON PURPOSE, so every MINOR stops here and
// someone has to look. The cost is a note like this one each time; the
// alternative is a protocol that changes consumer seeding sailing through
// because the last one happened not to.
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
        || (LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR > 13))
#  error "logos-protocol is newer than the consumer-admission contract this file implements. \
A private token store is created empty; if the protocol changed how a consumer is seeded, \
this file and the hosts calling logos::adoptAdmittedConsumer must move in the SAME wave. Review \
adoptCredentialFor / bootstrapKeys, then raise this bound."
#endif

namespace logos {

/**
 * @brief What a host gets back for an admitted consumer.
 *
 * `api` speaks AS the consumer, on the consumer's own isolated token store.
 * Hand it to the view / widget / bridge; it is parented to whatever `parent`
 * was passed to adoptAdmittedConsumer.
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
 * @brief Adopt an identity the runtime admitted: core_service.admitConsumer
 * (logos::host::LogosCore::admitConsumer), with capability_module as the token
 * authority, minted and recorded `credential` for `identity`.
 *
 * Isolates the identity's store, builds its LogosAPI and installs the
 * credential; it registers nothing, because capability_module already holds
 * it. Falsy when the name cannot be isolated, the credential is empty, or it
 * is the host's anchor.
 */
LOGOS_QT_HOST_API ConsumerIdentity adoptAdmittedConsumer(const QString& identity,
                                                         const QString& credential,
                                                         QObject* parent = nullptr);

/**
 * @brief Install a re-admission's credential in an adopted identity's store,
 * dropping the previous incarnation's tokens. False when it was never adopted.
 */
LOGOS_QT_HOST_API bool replaceConsumerCredential(LogosAPI* consumerApi,
                                                 const QString& credential);

/**
 * @brief Adopt a credential that was minted and registered ELSEWHERE.
 *
 * For a co-process of an already-admitted identity: ui-host is handed the
 * credential the runtime admitted it with, on stdin, and must install it in its
 * own image's token store. No isolation and no registration: its process ring
 * is the identity's store, and capability_module already holds the credential.
 *
 * This exists so the bootstrap key set stops being spelled out in a fifth
 * place; TokenManager::bootstrapKeys() owns it.
 */
LOGOS_QT_HOST_API void adoptConsumerCredential(LogosAPI* consumerApi,
                                               const QString& credential);

} // namespace logos

#endif // LOGOS_CONSUMER_H
