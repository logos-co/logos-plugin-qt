#include "logos_provider_object.h"
#include "logos_api.h"
#include "token_manager.h"
// LOGOS_PROTOCOL_VERSION_{MAJOR,MINOR} for the guard below — by name, so an
// undefined macro cannot quietly turn the guard FALSE and leave every module
// with a permanently unknown caller.
#include "logos_protocol.h"
#include <QDebug>
#include <QMetaObject>
#include <QString>

#if defined(LOGOS_PROTOCOL_VERSION_MINOR) && (LOGOS_PROTOCOL_VERSION_MAJOR > 0 || \
    (LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR >= 6))
// Only for logos::callerUnknownJson() — the fail-closed document. NOT for
// logos::currentInboundCallerJson(): calling that here would read THIS image's
// thread-local, which is the bug this whole file exists to avoid. See below.
#include "logos_caller_scope.h"
#endif

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

// THE PULL. Everything about the four lines below is deliberate; see the
// declaration in logos_provider_object.h and logos_caller_scope.h in
// logos-protocol for the measurement behind it.
//
//   invokeMethod, NOT m_logosAPI->currentCallerJson(). This translation unit is
//   compiled into the MODULE image, which links its own copy of LogosAPI —
//   meta-object included — with its own function-local statics at its own
//   addresses and no undefined reference to the host's. A direct call binds to
//   THIS image's copy and reads THIS image's caller thread-local, which no
//   CallerScope ever wrote. It is silently empty forever on macOS and Windows,
//   and correct on Linux, so a green Linux run proves nothing about it.
//   invokeMethod resolves through metaObject()/qt_metacall — virtual, vptr
//   written by the HOST's constructor — and therefore lands in host code.
//
//   BY NAME, so this string and the Q_INVOKABLE in logos_api.h are one
//   contract with no compiler between them. tests/test-caller-contract.nix is
//   what holds them together; without it a rename is a silent, permanent
//   Unknown across the whole fleet.
//
//   DirectConnection, because the answer is per-THREAD. The scope is open on
//   the thread the dispatch was delivered on, and this call must read that
//   thread's slot rather than hop to LogosAPI's owner thread. (Qt also refuses
//   Q_RETURN_ARG on a queued connection, so the alternative is a runtime
//   warning and a permanent Unknown, not a build failure.)
std::string LogosProviderBase::currentCallerJson() const
{
#if defined(LOGOS_PROTOCOL_VERSION_MINOR) && (LOGOS_PROTOCOL_VERSION_MAJOR > 0 || \
    (LOGOS_PROTOCOL_VERSION_MAJOR == 0 && LOGOS_PROTOCOL_VERSION_MINOR >= 6))
    QString caller;
    if (m_logosAPI
        && QMetaObject::invokeMethod(m_logosAPI, "currentCallerJson",
                                     Qt::DirectConnection,
                                     Q_RETURN_ARG(QString, caller))
        && !caller.isEmpty()) {
        return caller.toStdString();
    }
    // No LogosAPI yet, a host too old to carry the invokable, or an empty
    // answer. Fail closed to the ONE document logos-protocol produces for
    // "could not name the caller" — never to an empty string, which on the
    // module-impl C ABI is not a weaker identity but a different operation.
    return logos::callerUnknownJson();
#else
    // Below protocol 0.6 there is no caller surface at either end: no
    // logos_module_set_call_caller for the glue to push into, and no
    // callerUnknownJson() to name. Empty is the absence of the whole mechanism,
    // and the glue's push is guarded on this same expression, so nothing reads
    // it.
    return std::string();
#endif
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
