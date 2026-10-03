#include "logos_consumer.h"

#include "logos_api.h"
#include "token_manager.h"

#include <QDebug>

logos::ConsumerIdentity logos::adoptAdmittedConsumer(const QString& identity,
                                                     const QString& credential,
                                                     QObject* parent)
{
    if (identity.isEmpty() || credential.isEmpty()) {
        qWarning() << "logos::adoptAdmittedConsumer: needs a name and the credential"
                      " capability_module minted for it";
        return {};
    }
    LogosAPI* api = LogosAPI::forIdentity(identity, parent);
    if (!api) {
        qWarning() << "logos::adoptAdmittedConsumer: could not give" << identity
                   << "a token store of its own";
        return {};
    }
    // Refuses the host's anchor, so a credential can never elevate the identity.
    if (!TokenManager::adoptCredentialFor(identity, credential)) {
        qWarning() << "logos::adoptAdmittedConsumer: could not install" << identity
                   << "'s credential";
        delete api;
        return {};
    }
    return ConsumerIdentity{api, credential};
}

bool logos::replaceConsumerCredential(LogosAPI* consumerApi, const QString& credential)
{
    const QString identity = consumerApi ? consumerApi->moduleName() : QString();
    if (identity.isEmpty() || credential.isEmpty() || !TokenManager::isIsolated(identity)) {
        qWarning() << "logos::replaceConsumerCredential:" << identity
                   << "was never adopted, or the credential is empty";
        return false;
    }
    TokenManager::resetIdentity(identity);
    if (!TokenManager::adoptCredentialFor(identity, credential)) {
        qWarning() << "logos::replaceConsumerCredential: could not install the new"
                      " credential for" << identity << "- it is now locked out";
        return false;
    }
    return true;
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
                   << "identity is adopted with logos::adoptAdmittedConsumer,"
                   << "over TokenManager::adoptCredentialFor, which refuses the"
                   << "host anchor.";
        return;
    }
    store->adoptCredential(credential);
}
