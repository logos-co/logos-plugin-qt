#include "logos_consumer.h"

#include "logos_api.h"
#include "logos_api_client.h"
#include "token_manager.h"

#include <QDebug>
#include <QUuid>

namespace {

// A per-admission secret. UUID rather than anything derived from the identity
// name: the value must not be guessable from public information, because
// holding it IS being that consumer.
QString mintCredential()
{
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

// Make (identity, credential) a known caller AT capability_module.
//
// Deliberately over the HOST's client and the HOST's token: informModuleToken
// is accepted only from a caller presenting the trusted core/capability
// channel's token (ModuleProxy::informModuleToken), and the host is that
// channel. The consumer cannot register itself — that is the entire point.
bool registerAtCapability(LogosAPI* hostApi, const QString& identity,
                          const QString& credential)
{
    if (!hostApi) {
        qWarning() << "logos::admitConsumer: no host LogosAPI - identity" << identity
                   << "cannot be registered, so every call it makes would be refused";
        return false;
    }
    LogosAPIClient* cap = hostApi->getClient(QStringLiteral("capability_module"));
    if (!cap) {
        qWarning() << "logos::admitConsumer: no capability_module client - identity"
                   << identity << "will not be registered";
        return false;
    }
    TokenManager* hostStore = hostApi->getTokenManager();
    const QString hostCapToken =
        hostStore ? hostStore->getToken(QStringLiteral("capability_module")) : QString();
    if (hostCapToken.isEmpty()) {
        qWarning() << "logos::admitConsumer: the host holds no capability_module token,"
                      " so it is not the trusted channel; identity" << identity
                   << "will not be registered";
        return false;
    }
    if (!cap->informModuleToken(hostCapToken, identity, credential)) {
        qWarning() << "logos::admitConsumer: capability_module.informModuleToken failed"
                      " for identity" << identity;
        return false;
    }
    return true;
}

} // namespace

logos::ConsumerIdentity logos::admitConsumer(const QString& identity,
                                             LogosAPI* hostApi,
                                             QObject* parent)
{
    if (identity.isEmpty()) {
        qWarning() << "logos::admitConsumer: refusing to admit an unnamed consumer";
        return {};
    }

    // (1) + (2): isolate, then construct. LogosAPI::forIdentity does both in
    // that order and returns nullptr if the name was already vended on the
    // ambient ring — which must fail the load rather than fall back to the
    // host's own LogosAPI.
    LogosAPI* api = LogosAPI::forIdentity(identity, parent);
    if (!api) {
        qWarning() << "logos::admitConsumer: could not give" << identity
                   << "a token store of its own - refusing to run it with the"
                      " host's authority";
        return {};
    }

    const QString credential = mintCredential();

    // (3) REGISTER, and only then (4) ADOPT. See the header: this order is what
    // makes the window in which the consumer holds an unknown credential not
    // merely short but nonexistent.
    if (!registerAtCapability(hostApi, identity, credential)) {
        delete api;
        return {};
    }
    if (!TokenManager::adoptCredentialFor(identity, credential)) {
        // Reachable in exactly two ways, and both are bugs here rather than
        // conditions to survive: the identity is not isolated (impossible, step
        // 1 succeeded) or the minted credential collided with the host's own
        // anchor (impossible with a UUID). Fail loudly.
        qWarning() << "logos::admitConsumer: could not install" << identity
                   << "'s own credential in its store - it would be locked out";
        delete api;
        return {};
    }

    return ConsumerIdentity{api, credential};
}

QString logos::reissueConsumerCredential(LogosAPI* consumerApi, LogosAPI* hostApi)
{
    if (!consumerApi) return {};
    const QString identity = consumerApi->moduleName();
    if (identity.isEmpty()) return {};
    if (!TokenManager::isIsolated(identity)) {
        qWarning() << "logos::reissueConsumerCredential:" << identity
                   << "was never admitted (its store is the ambient ring);"
                      " refusing to rotate a credential it does not have";
        return {};
    }

    const QString credential = mintCredential();
    if (!registerAtCapability(hostApi, identity, credential)) return {};

    // Reset AFTER the registration lands: between the two, the identity holds a
    // credential that is already dead at the target, and the reset is what
    // removes it. Doing the reset first would widen that window rather than
    // close it.
    TokenManager::resetIdentity(identity);
    if (!TokenManager::adoptCredentialFor(identity, credential)) {
        qWarning() << "logos::reissueConsumerCredential: could not install the new"
                      " credential for" << identity << "- it is now locked out";
        return {};
    }
    return credential;
}

void logos::adoptConsumerCredential(LogosAPI* consumerApi, const QString& credential)
{
    if (!consumerApi || credential.isEmpty()) return;
    TokenManager* store = consumerApi->getTokenManager();
    if (!store) return;

    // Refused against an ISOLATED store, and this is the whole reason the
    // function is narrow. adoptCredential checks neither isolation nor
    // anchor-equality — correct for the co-process case it exists for, where
    // the store IS the process ring and the credential came in on stdin. Point
    // it at an in-process private store and it becomes a public verb that will
    // install whatever it is handed, including the host's anchor, straight past
    // adoptCredentialFor's refusal. The elevation this change removed would be
    // one call away again.
    if (store != &TokenManager::instance()) {
        qWarning() << "logos::adoptConsumerCredential: refusing an ISOLATED store."
                   << "This verb is for a co-process adopting its parent's"
                   << "credential into its own process ring. An in-process"
                   << "identity is admitted with logos::admitConsumer, which"
                   << "mints, registers and installs as one operation --"
                   << "TokenManager::adoptCredentialFor is the primitive under"
                   << "it and refuses the host anchor.";
        return;
    }
    store->adoptCredential(credential);
}
