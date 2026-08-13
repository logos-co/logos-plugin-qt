#ifndef LOGOS_API_PROVIDER_H
#define LOGOS_API_PROVIDER_H

#include "logos_transport_config.h"

#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QMap>
#include <functional>
#include <memory>
#include <string>

class LogosTransportHost;
class LogosObject;
class ModuleProxy;
class ModuleHandshakeProxy;
class LogosProviderObject;
class QtProviderObject;

/**
 * @brief LogosAPIProvider handles registering objects for access by consumers
 * 
 * Supports two registration paths:
 *   1. registerObject(name, QObject*)           — wraps in QtProviderObject, then ModuleProxy
 *   2. registerObject(name, LogosProviderObject*) — wraps directly in ModuleProxy
 * Both paths converge at ModuleProxy -> transport.
 */
class LogosAPIProvider : public QObject
{
    Q_OBJECT

public:
    /**
     * @param module_name  The module this provider belongs to.
     * @param transports   Optional per-instance transport override. When empty,
     *                     the provider uses the process-global default. This
     *                     is what lets a daemon expose `core_service` on
     *                     TCP/TLS while keeping module-to-module traffic on
     *                     the local-socket default.
     */
    explicit LogosAPIProvider(const QString& module_name,
                              LogosTransportSet transports = {},
                              QObject *parent = nullptr);
    // Back-compat overload
    LogosAPIProvider(const QString& module_name, QObject *parent)
        : LogosAPIProvider(module_name, LogosTransportSet{}, parent) {}
    ~LogosAPIProvider();

    /**
     * @brief Register a legacy QObject-based plugin.
     * Wraps in QtProviderObject, then ModuleProxy.
     */
    bool registerObject(const QString& name, QObject* object);

    /**
     * @brief Register a legacy QObject-based plugin — const char* overload (resolves ambiguity)
     */
    bool registerObject(const char* name, QObject* object)
        { return registerObject(QString(name), object); }

    /**
     * @brief Register a legacy QObject-based plugin (std::string overload).
     */
    bool registerObject(const std::string& name, QObject* object);

    /**
     * @brief Register a new-API LogosProviderObject plugin.
     * Wraps directly in ModuleProxy.
     */
    bool registerObject(const QString& name, LogosProviderObject* provider);

    QString registryUrl() const;
    bool saveToken(const QString& from_module_name, const QString& token);

    // Install an extra token authorizer, forwarded to the ModuleProxy. Consulted
    // in addition to the built-in issued-token scan, with the call's transport
    // ("local" | "tcp" | "tcp_ssl") so local_only tokens can be enforced. The
    // daemon backs this with TokenStore::lookupByToken so operator-issued named
    // tokens authorize. Safe to call before or after registerObject(); a
    // validator set before registration is applied when the proxy is created.
    using TokenValidator = std::function<bool(const QString& token,
                                              const QString& transportProtocol)>;
    void setTokenValidator(TokenValidator validator);

public slots:
    void onEventResponse(LogosObject* object, const QString& eventName, const QVariantList& data);

private:
    bool publishProvider(const QString& name, LogosProviderObject* provider);
    // Publishes the token-only handshake surface (logos::handshakeObjectName)
    // before the module's initializer runs, so capability_module can deliver a
    // token to a module that is still starting up. Best-effort: a transport that
    // declines it simply leaves capability_module falling back to the business
    // object, which is the pre-existing behaviour.
    void publishHandshake(const QString& name, LogosProviderObject* provider);
    // Installs the host-issued token as this module's "core"/"capability_module"
    // trust anchor before the handshake surface is published. Without it the
    // surface is reachable but refuses every push for the whole pre-init window
    // it exists to cover, because the initializer that normally seeds those
    // entries has not run yet. Never overwrites an existing entry, and is a no-op
    // on a host that does not publish an `authToken` property.
    void seedHandshakeTrustAnchor();

    // One host per configured transport. Single-entry vector for back-compat.
    std::vector<std::unique_ptr<LogosTransportHost>> m_transports;
    QString m_registryUrl;
    QMap<QString, QString> m_tokens;
    ModuleProxy* m_moduleProxy;
    ModuleHandshakeProxy* m_handshakeProxy = nullptr;
    QString m_registeredHandshakeName;
    QtProviderObject* m_qtProviderObject;
    QString m_registeredObjectName;
    // Appended (never inserted mid-list): keeps every pre-existing member's
    // offset identical between builds, so a LogosAPIProvider is layout-safe even
    // if a future co-located consumer ever accessed one across a version
    // boundary. Held until the proxy exists (registerObject may come after the
    // setter).
    TokenValidator m_pendingValidator;
};

#endif // LOGOS_API_PROVIDER_H
