#ifndef LOGOS_API_H
#define LOGOS_API_H

#include "logos_mode.h"
#include "logos_shared_api.h"
#include "logos_transport_config.h"
#include "logos_types.h"

#include <QHash>
#include <QHashFunctions>
#include <QObject>
#include <QString>

#include <functional>
#include <optional>
#include <string>

class LogosAPIClient;
class LogosAPIProvider;
class TokenManager;

// qHash for LogosTransportConfig — combined with operator== from
// logos_transport_config.h, this lets QHash use it as a key. Lives here
// rather than in logos_transport_config.h so that header stays Qt-free
// (the SDK is being de-Qt'd; only Qt-using consumers like the cache
// here pull in the QHash adapter).
//
// Every field that distinguishes one explicit-transport client from
// another contributes to the hash; otherwise two callers with different
// TLS or codec settings could land on the same bucket and cache-alias
// onto a single client.
inline size_t qHash(const LogosTransportConfig& cfg, size_t seed = 0) noexcept
{
    return qHashMulti(seed,
        static_cast<int>(cfg.protocol),
        std::hash<std::string>{}(cfg.host),
        cfg.port,
        std::hash<std::string>{}(cfg.caFile),
        std::hash<std::string>{}(cfg.certFile),
        std::hash<std::string>{}(cfg.keyFile),
        cfg.verifyPeer,
        static_cast<int>(cfg.codec));
}

// LogosAPIClient cache key. Mirrors the factory's transport-resolution
// rule so two callers that would observe the same connection share a
// cached client:
//
//   - Mock / Local mode   → transport is ignored at construction; key
//                            ignores it too. Switching mode changes the
//                            key (so cached clients don't bleed across
//                            mode switches in tests).
//   - Remote mode         → cfg picks the wire endpoint; key includes
//                            the full LogosTransportConfig.
//
// Without the mode-aware comparison, calling
// `getClient(x, tcp)` and `getClient(x, tcp_ssl)` in Mock mode would
// allocate two clients pointing at functionally identical
// MockTransportConnections.
struct LogosAPIClientCacheKey {
    QString               target;
    LogosMode             mode;
    LogosTransportConfig  transport;  // only compared when mode == Remote
};

inline bool operator==(const LogosAPIClientCacheKey& a,
                       const LogosAPIClientCacheKey& b) noexcept
{
    if (a.target != b.target) return false;
    if (a.mode   != b.mode)   return false;
    return a.mode == LogosMode::Remote ? a.transport == b.transport : true;
}

inline size_t qHash(const LogosAPIClientCacheKey& k, size_t seed = 0) noexcept
{
    if (k.mode == LogosMode::Remote) {
        return qHashMulti(seed, k.target, static_cast<int>(k.mode), k.transport);
    }
    // Mock / Local: transport is irrelevant — leave it out of the hash
    // so it can't bias which bucket the key lands in.
    return qHashMulti(seed, k.target, static_cast<int>(k.mode));
}

/**
 * @brief LogosAPI provides a unified interface to the Logos SDK
 * 
 * This class initializes and keeps instances of the client provider and token manager.
 *
 * LOGOS_SHARED_API because this is the object handed across the DLL boundary:
 * the host constructs a LogosAPI inside liblogos_core and passes the pointer to
 * the UI plugin through PluginInterface::logosAPI. Its constructor caches
 * `&TokenManager::instance()`, so on PE a plugin that links its own copy of
 * logos_api.cpp.obj caches a DIFFERENT singleton than the one the host wrote
 * the token into. Importing instead of re-linking is what makes the two agree.
 * See logos_shared_api.h in logos-protocol.
 */
class LOGOS_SHARED_API LogosAPI : public QObject
{
    Q_OBJECT

public:
    /**
     * @brief Construct a new LogosAPI instance
     * @param module_name The name of this module
     * @param parent Parent QObject
     */
    explicit LogosAPI(const QString& module_name, QObject *parent = nullptr);

    /**
     * @brief Construct a new LogosAPI with an explicit transport set.
     *
     * `transports` is empty ⇒ use the process-global default (back-compat).
     * Non-empty ⇒ provider publishes on every configured transport
     * (e.g. a daemon listing both LocalSocket and TCP+SSL so the CLI has
     * a fast in-process path *and* remote clients have a secure path).
     */
    LogosAPI(const QString& module_name,
             LogosTransportSet transports,
             QObject *parent = nullptr);

    /**
     * @brief Construct a new LogosAPI instance (const char* overload — resolves ambiguity)
     */
    explicit LogosAPI(const char* module_name, QObject *parent = nullptr)
        : LogosAPI(QString(module_name), parent) {}

    /**
     * @brief Construct with const char* and explicit transport set.
     */
    LogosAPI(const char* module_name, LogosTransportSet transports, QObject *parent = nullptr)
        : LogosAPI(QString(module_name), std::move(transports), parent) {}

    /**
     * @brief Construct a new LogosAPI instance (std::string overload)
     */
    explicit LogosAPI(const std::string& module_name, QObject *parent = nullptr);

    /**
     * @brief Construct with std::string and explicit transport set.
     */
    LogosAPI(const std::string& module_name, LogosTransportSet transports, QObject *parent = nullptr)
        : LogosAPI(QString::fromStdString(module_name), std::move(transports), parent) {}
    
    /**
     * @brief Destructor
     */
    ~LogosAPI();

    /**
     * @brief The name of the module this LogosAPI belongs to.
     *
     * Every outbound call already carries it (LogosAPIClient's `origin`), it
     * was just never readable from the outside. Generated consumer wrappers
     * need it: a wrapper that reaches the transport through the lp C ABI must
     * name its origin at client-creation time, and the only handle it is given
     * is this object. Reading it here keeps the wrapper's constructor
     * signature — `(LogosAPI*)` / `(LogosAPI*, const QString&)` — unchanged,
     * so no call site moves.
     */
    QString moduleName() const { return m_module_name; }

    /**
     * @brief Get the client provider instance
     * @return LogosAPIProvider* Pointer to the provider
     */
    LogosAPIProvider* getProvider() const;

    /**
     * @brief Get the client instance for communicating with a module
     * @param target_module The module to communicate with
     * @return LogosAPIClient* Pointer to the client
     */
    LogosAPIClient* getClient(const QString& target_module) const;

    /**
     * @brief Get the client instance — const char* overload (resolves ambiguity)
     */
    LogosAPIClient* getClient(const char* target_module) const
        { return getClient(QString(target_module)); }

    /**
     * @brief Get the client instance for communicating with a module (std::string overload)
     */
    LogosAPIClient* getClient(const std::string& target_module) const;

    /**
     * @brief Get a client that uses an *explicit* transport instead of
     *        the process-global default.
     *
     * Use this when the caller needs to dial one module over a
     * particular protocol without side-effecting the rest of the
     * process. Canonical case: a CLI that talks only to `core_service`
     * over tcp_ssl — using `LogosTransportConfigGlobal::setDefault` for
     * that would also flip the same process's `LogosAPIProvider` into
     * trying to bind a tcp_ssl server, which the CLI has no cert for.
     *
     * Cached per (target_module, full LogosTransportConfig) — repeat
     * calls with the same target *and* the same transport return the
     * same client. The cache key covers every config field that can
     * distinguish two clients (protocol, host, port, codec, all TLS
     * settings), via the operator== / qHash defined alongside
     * LogosTransportConfig, so two callers with different TLS or codec
     * settings always get separate clients — no risk of silently
     * reusing an insecure connection where a secure one was asked for.
     */
    LogosAPIClient* getClient(const QString& target_module,
                              const LogosTransportConfig& transport) const;

    /**
     * @brief Get the token manager instance
     * @return TokenManager* Pointer to the token manager
     */
    TokenManager* getTokenManager() const;

    /**
     * @brief Set the transport used by the SDK's auto-`requestModule`
     * token-fetch flow (inside LogosAPIClient::invokeRemoteMethod{,Async}).
     *
     * That flow always dials `capability_module` to fetch a per-target
     * token, regardless of which module is the actual call target.
     * Without an explicit transport it falls through to
     * LogosTransportConfigGlobal::getDefault() (LocalSocket), which
     * times out 20 s when capability_module is reachable only on TCP
     * (e.g. CLI on host, daemon in container).
     *
     * Callers that have read the daemon's per-module advertised
     * transports (e.g. from logoscore's daemon.json) should register
     * capability_module's transport here so getClient builds each
     * LogosAPIClient with the right capability_consumer.
     *
     * The setting only affects clients constructed *after* this call
     * — clients already in the cache keep whatever capability transport
     * they were built with.
     */
    void setCapabilityModuleTransport(const LogosTransportConfig& transport);

    using QObject::setProperty;

    /**
     * @brief Set a dynamic property from a UTF-8 std::string (delegates to QVariant + QString).
     */
    bool setProperty(const char* name, const std::string& value);

private:
    QString m_module_name;
    LogosAPIProvider* m_provider;
    // Single cache for both getClient overloads. Keyed by a
    // mode-aware composite (LogosAPIClientCacheKey above) so that:
    //  - Mock/Local mode buckets ignore transport (the factory does too)
    //  - Remote mode keys include the full LogosTransportConfig
    //  - the no-transport overload resolves to the same key as an
    //    explicit caller passing LogosTransportConfigGlobal::getDefault()
    //  - mode switches don't return stale clients from the previous mode
    mutable QHash<LogosAPIClientCacheKey, LogosAPIClient*> m_clients;
    TokenManager* m_token_manager;
    // ABI note: this private layout is consumed by every plugin that
    // statically links libsdk. Inserting a field above m_token_manager
    // shifts its offset and SILENTLY breaks plugins compiled before
    // the change — they read garbage where m_token_manager used to
    // live, getClient() then constructs LogosAPIClients with a bogus
    // TokenManager*, and the first cross-process call segfaults.
    // Append new private members at the END only. (Long-term cure:
    // pimpl this class so sizeof / offsets become opaque.)
    //
    // Optional override for the capability_module transport used by
    // each LogosAPIClient's pre-built m_capability_consumer. Set via
    // setCapabilityModuleTransport(). nullopt = use the global default.
    std::optional<LogosTransportConfig> m_capabilityModuleTransport;
};

#endif // LOGOS_API_H