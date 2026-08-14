#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_api_provider.h"
#include "logos_thread_marshal.h"
#include "token_manager.h"
#include <QDebug>
#include <QVariant>
#include <string>

LogosAPI::LogosAPI(const QString& module_name, QObject *parent)
    : LogosAPI(module_name, LogosTransportSet{}, parent)
{
}

LogosAPI::LogosAPI(const QString& module_name,
                   LogosTransportSet transports,
                   QObject *parent)
    : LogosAPI(module_name, nullptr, std::move(transports), parent)
{
}

LogosAPI::LogosAPI(const QString& module_name,
                   TokenManager* token_store,
                   LogosTransportSet transports,
                   QObject *parent)
    : QObject(parent)
    , m_module_name(module_name)
    , m_provider(nullptr)
    , m_token_manager(nullptr)
{
    m_provider = new LogosAPIProvider(m_module_name, std::move(transports), this);
    // An explicit store wins. NULL resolves to the store for the identity this
    // object says it is — which is TokenManager::instance() itself, the same
    // object this line used to name outright, for every identity nobody has
    // isolated. So this is not a behaviour change; it is the hook that lets one
    // BECOME a behaviour change, for one name, when a host asks for it.
    m_token_manager = token_store ? token_store
                                  : &TokenManager::forIdentity(m_module_name);
    qRegisterMetaType<LogosResult>("LogosResult");
}

LogosAPI* LogosAPI::forIdentity(const QString& identity, QObject* parent)
{
    if (identity.isEmpty()) {
        qWarning() << "LogosAPI::forIdentity: refusing to isolate the empty identity";
        return nullptr;
    }
    if (!TokenManager::isolateIdentity(identity)) {
        // Not advisory. A client for this name already captured the ambient
        // ring as a raw pointer, so isolating now would split the identity
        // across two stores.
        qWarning() << "LogosAPI::forIdentity: cannot isolate" << identity
                   << "- the shared token store was already handed out under"
                      " that name; refusing to hand back a half-isolated identity";
        return nullptr;
    }
    return new LogosAPI(identity, &TokenManager::forIdentity(identity), parent);
}

LogosAPI::LogosAPI(const std::string& module_name, QObject *parent)
    : LogosAPI(QString::fromStdString(module_name), parent)
{
}

LogosAPI::~LogosAPI()
{
    // Provider and client will be automatically deleted as child objects
    // Token manager is a singleton, so we don't delete it


}

LogosAPIProvider* LogosAPI::getProvider() const
{
    return m_provider;
}

LogosAPIClient* LogosAPI::getClient(const QString& target_module) const
{
    // The no-transport overload is just shorthand for "use the
    // process-global default" — the explicit-transport overload below
    // is the single resolution path. Mode-awareness lives in the
    // factory, so this delegation preserves Mock/Local semantics.
    return getClient(target_module, LogosTransportConfigGlobal::getDefault());
}

LogosAPIClient* LogosAPI::getClient(const std::string& target_module) const
{
    return getClient(QString::fromStdString(target_module));
}

LogosAPIClient* LogosAPI::getClient(const QString& target_module,
                                    const LogosTransportConfig& transport) const
{
    // Create the client (and its consumers + transport replicas) on this
    // LogosAPI's owner thread — the module's main/event-loop thread — even when
    // called from a worker thread (e.g. an HTTP handler). Qt Remote Objects
    // replicas only work on the thread that created them, so construction (and
    // the cache it populates) must happen there. invokeRemoteMethod() then
    // marshals calls back to the same thread. See logos_thread_marshal.h.
    return logos::runOnOwnerThread(const_cast<LogosAPI*>(this),
                                   [&]() -> LogosAPIClient* {
    // Single cache, single construction path. Key composition mirrors
    // the factory's resolution rule (see LogosAPIClientCacheKey in
    // logos_api.h):
    //   - Mock/Local mode: every cfg collapses to one cache slot per
    //     target — switching cfg returns the same MockTransport-backed
    //     client instead of allocating a duplicate.
    //   - Remote mode: every distinguishing field of cfg matters, so
    //     two callers with different TLS/codec settings get separate
    //     clients (no risk of silently reusing an insecure transport).
    //
    // The capability_module transport — used by the client's
    // auto-`requestModule` flow — falls back to the registered
    // override (if any) or the global default. Two-arg getClient
    // intentionally doesn't expose a second transport here; callers
    // that care register the capability_module transport once via
    // setCapabilityModuleTransport() and the rest is plumbing.
    const LogosAPIClientCacheKey key{
        target_module, LogosModeConfig::getMode(), transport};
    auto it = m_clients.constFind(key);
    if (it != m_clients.constEnd()) return it.value();

    const LogosTransportConfig capabilityTransport =
        m_capabilityModuleTransport.has_value()
            ? *m_capabilityModuleTransport
            : LogosTransportConfigGlobal::getDefault();

    LogosAPIClient* client = new LogosAPIClient(
        target_module, m_module_name, m_token_manager,
        transport, capabilityTransport,
        const_cast<LogosAPI*>(this));
    m_clients.insert(key, client);
    return client;
    });
}

TokenManager* LogosAPI::getTokenManager() const
{
    return m_token_manager;
}

void LogosAPI::setCapabilityModuleTransport(const LogosTransportConfig& transport)
{
    m_capabilityModuleTransport = transport;
}

bool LogosAPI::setProperty(const char* name, const std::string& value)
{
    return QObject::setProperty(name, QVariant(QString::fromStdString(value)));
}
