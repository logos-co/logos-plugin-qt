#include "logos_provider_object.h"
#include "logos_api.h"
#include "token_manager.h"
#include <QDebug>

// The LogosProviderObject universal-interface defaults and Std bridges moved
// to logos-protocol (logos_provider_interface.cpp) together with the abstract
// interface. What remains here is LogosProviderBase — the base the generated
// Qt plugin glue (<name>_cdylib_glue.cpp) derives from — because it talks to
// LogosAPI, which layers above the protocol. It used to be hand-derived by
// `interface: "provider"` module code; that interface is gone, and module code
// now derives from logos-cpp-sdk's Qt-free LogosModuleContext instead.

// ---------------------------------------------------------------------------
// LogosProviderBase
// ---------------------------------------------------------------------------

void LogosProviderBase::init(void* apiInstance)
{
    m_logosAPI = static_cast<LogosAPI*>(apiInstance);
    qDebug() << "[LogosProviderObject] LogosProviderBase::init called";
    onInit(m_logosAPI);
}

bool LogosProviderBase::informModuleToken(const QString& moduleName, const QString& token)
{
    if (!m_logosAPI) {
        qWarning() << "[LogosProviderObject] informModuleToken: LogosAPI not available";
        return false;
    }

    TokenManager* tokenManager = m_logosAPI->getTokenManager();
    if (!tokenManager) {
        qWarning() << "[LogosProviderObject] informModuleToken: TokenManager not available";
        return false;
    }

    qDebug() << "[LogosProviderObject] Saving token for module:" << moduleName;
    tokenManager->saveToken(moduleName, token);
    return true;
}

void LogosProviderBase::emitEvent(const QString& eventName, const QVariantList& data)
{
    if (m_eventCallback) {
        qDebug() << "[LogosProviderObject] emitEvent:" << eventName;
        m_eventCallback(eventName, data);
    } else {
        qWarning() << "[LogosProviderObject] emitEvent: no listener set for" << eventName;
    }
}
