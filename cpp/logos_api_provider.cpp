#include "logos_api_provider.h"
#include "logos_object.h"
#include "logos_provider_object.h"
#include "qt_provider_object.h"
#include "module_proxy.h"
#include "logos_api.h"
#include "logos_instance.h"
#include "logos_transport.h"
#include "logos_transport_factory.h"
#include "token_manager.h"
#include <QDebug>
#include <string>

LogosAPIProvider::LogosAPIProvider(const QString& module_name,
                                   LogosTransportSet transports,
                                   QObject *parent)
    : QObject(parent)
    , m_registryUrl(LogosInstance::id(module_name))
    , m_moduleProxy(nullptr)
    , m_qtProviderObject(nullptr)
{
    // Helper: defer-construct one host and only retain it if the
    // factory actually returned something. createHost() can return
    // nullptr — e.g. PlainTransportHost::start() failure (TCP bind,
    // SSL cert load) — and we don't want to leave a null entry that
    // would crash the publish/unpublish paths later.
    auto pushHost = [&](auto&& host, const char* label) {
        if (host) {
            m_transports.push_back(std::forward<decltype(host)>(host));
        } else {
            qWarning() << "LogosAPIProvider: createHost returned null"
                       << "for" << module_name << label
                       << "— transport disabled";
        }
    };

    if (transports.empty()) {
        // Back-compat: one host, chosen by the global mode + transport config.
        pushHost(LogosTransportFactory::createHost(m_registryUrl), "(default)");
    } else {
        // One host per configured transport — lets a single provider serve
        // its object on several endpoints simultaneously (local-socket +
        // TCP, TCP + TCP+SSL, etc.).
        for (const auto& cfg : transports)
            pushHost(LogosTransportFactory::createHost(cfg, m_registryUrl), "(per-cfg)");
    }
}

LogosAPIProvider::~LogosAPIProvider()
{
    if (!m_registeredObjectName.isEmpty()) {
        // Defensive: m_transports should never contain nullptr (the
        // ctor filters them out via pushHost), but guard here too —
        // a future code path that pushes directly without going
        // through pushHost would otherwise crash on shutdown.
        for (auto& t : m_transports) {
            if (t) t->unpublishObject(m_registeredObjectName);
        }
    }
    if (!m_registeredHandshakeName.isEmpty()) {
        for (auto& t : m_transports) {
            if (t) t->unpublishObject(m_registeredHandshakeName);
        }
    }
}

// QObject* path: auto-detects LogosProviderPlugin; falls back to QtProviderObject wrapper
bool LogosAPIProvider::registerObject(const QString& name, QObject* object)
{
    if (!object) {
        qWarning() << "LogosAPIProvider: Cannot register null object";
        return false;
    }

    if (name.isEmpty()) {
        qWarning() << "LogosAPIProvider: Cannot register object with empty name";
        return false;
    }

    if (m_moduleProxy) {
        qCritical() << "LogosAPIProvider: Object already registered. Only one registration per provider is allowed";
        return false;
    }

    // Check if this plugin implements LogosProviderPlugin (new API)
    LogosProviderPlugin* providerPlugin = qobject_cast<LogosProviderPlugin*>(object);
    if (providerPlugin) {
        qDebug() << "[LogosProviderObject] LogosAPIProvider: detected LogosProviderPlugin for" << name;
        LogosProviderObject* provider = providerPlugin->createProviderObject();
        if (provider) {
            return registerObject(name, provider);
        }
        qWarning() << "LogosAPIProvider: createProviderObject() returned null for" << name;
    }

    // Legacy path: wrap QObject in QtProviderObject adapter
    qDebug() << "[LogosProviderObject] LogosAPIProvider: wrapping QObject in QtProviderObject for" << name;

    m_qtProviderObject = new QtProviderObject(object, this);

    // Handshake surface before init, business object after — see the
    // LogosProviderObject overload for why.
    publishHandshake(name, m_qtProviderObject);

    m_qtProviderObject->init(qobject_cast<LogosAPI*>(parent()));

    return publishProvider(name, m_qtProviderObject);
}

bool LogosAPIProvider::registerObject(const std::string& name, QObject* object)
{
    return registerObject(QString::fromStdString(name), object);
}

// New path: LogosProviderObject* -> ModuleProxy -> transport
bool LogosAPIProvider::registerObject(const QString& name, LogosProviderObject* provider)
{
    if (!provider) {
        qWarning() << "LogosAPIProvider: Cannot register null provider";
        return false;
    }

    if (name.isEmpty()) {
        qWarning() << "LogosAPIProvider: Cannot register provider with empty name";
        return false;
    }

    if (m_moduleProxy) {
        qCritical() << "LogosAPIProvider: Object already registered. Only one registration per provider is allowed";
        return false;
    }

    qDebug() << "[LogosProviderObject] LogosAPIProvider: registering LogosProviderObject directly for" << name;

    // Publish the handshake surface BEFORE the initializer runs, and the
    // business object after it, as always. The initializer is synchronous and
    // routinely calls out — including capability_module's requestModule, which
    // capability answers by pushing a token back to this very module. With only
    // the business object, that push was unsatisfiable: capability waited for a
    // source that could not appear until the initializer returned, and the
    // initializer could not return until capability answered.
    //
    // Publishing the token-only surface early breaks that circle without
    // changing what callers of real methods see: they still block at acquire
    // until the business object appears, exactly as before.
    publishHandshake(name, provider);

    provider->init(qobject_cast<LogosAPI*>(parent()));

    return publishProvider(name, provider);
}

void LogosAPIProvider::setTokenValidator(TokenValidator validator)
{
    // Store first, then forward the member — a single source of truth, so the
    // proxy and the pending copy can't diverge if the validator carries state.
    m_pendingValidator = std::move(validator);
    if (m_moduleProxy) {
        m_moduleProxy->setTokenValidator(m_pendingValidator);
    }
}

void LogosAPIProvider::seedHandshakeTrustAnchor()
{
    QObject* api = parent();
    if (!api) {
        return;
    }

    // The host publishes its token as a property on the LogosAPI object before
    // calling registerObject (logos-module-loader-qt module_initializer.cpp).
    // An older host that does not set it leaves the store empty — the handshake
    // surface then refuses, and the consumer falls back to the business object
    // exactly as it did before this surface existed.
    const QString hostToken = api->property("authToken").toString();
    if (hostToken.isEmpty()) {
        qDebug() << "[LogosProviderObject] LogosAPIProvider: no authToken property"
                 << "- handshake surface will refuse until the initializer seeds the"
                 << "token store; consumers fall back to the business object";
        return;
    }

    // Never overwrite an entry the module already holds: this runs before init(),
    // so a non-empty value here came from somewhere with more context than us.
    TokenManager& tokens = TokenManager::instance();
    for (const QString& key : { QStringLiteral("core"), QStringLiteral("capability_module") }) {
        if (tokens.getToken(key).isEmpty()) {
            tokens.saveToken(key, hostToken);
        }
    }
}

void LogosAPIProvider::publishHandshake(const QString& name, LogosProviderObject* provider)
{
    // The handshake proxy needs the ModuleProxy that will own the token store,
    // so build that now; publishProvider() reuses it rather than making another.
    if (!m_moduleProxy) {
        m_moduleProxy = new ModuleProxy(provider, this);
        if (m_pendingValidator) {
            m_moduleProxy->setTokenValidator(m_pendingValidator);
        }
    }

    // Seed the trust anchor BEFORE the surface goes live.
    //
    // ModuleProxy::informModuleToken only accepts a caller whose token matches
    // TokenManager's "core" or "capability_module" entry. Those entries are
    // written by the module's own initializer — the generated cdylib glue reads
    // the host's `authToken` property and calls logos_module_accept_token("core")
    // / ("capability_module") — and init() runs AFTER this point, between
    // publishHandshake and publishProvider.
    //
    // That is precisely the window this surface exists to serve, so without this
    // the store is empty for the whole window and every push that arrives is
    // refused: the surface would be reachable and useless, and capability_module
    // would report a failed grant. (Measured before this line existed: the
    // rejection appeared in 29 of 34 runs and never in the pre-fix baseline.)
    //
    // This grants nothing new. It installs the same host-issued token the
    // initializer installs moments later, just early enough to be usable.
    seedHandshakeTrustAnchor();

    m_handshakeProxy = new ModuleHandshakeProxy(m_moduleProxy, this);
    const QString handshakeName = logos::handshakeObjectName(name);

    bool published = false;
    for (auto& t : m_transports) {
        if (!t) continue;
        if (t->publishObject(handshakeName, m_handshakeProxy)) published = true;
    }
    if (published) {
        m_registeredHandshakeName = handshakeName;
        qDebug() << "[LogosProviderObject] LogosAPIProvider: published handshake surface"
                 << handshakeName << "- token delivery is reachable while" << name
                 << "initializes";
    } else {
        // Not fatal: a transport that cannot carry the handshake surface just
        // means capability_module falls back to the business object, which is
        // exactly how things worked before this existed.
        qDebug() << "[LogosProviderObject] LogosAPIProvider: no transport published"
                 << handshakeName << "- capability_module will fall back to" << name;
    }
}

bool LogosAPIProvider::publishProvider(const QString& name, LogosProviderObject* provider)
{
    // publishHandshake() may already have created the proxy (it needs the token
    // store to exist before the initializer runs); reuse it so the token a peer
    // delivered early is the one the business object consults.
    if (!m_moduleProxy) {
        m_moduleProxy = new ModuleProxy(provider, this);
    }
    // Apply a validator installed before registration, before the proxy is
    // published on any transport (so no call can slip in unvalidated).
    if (m_pendingValidator) {
        m_moduleProxy->setTokenValidator(m_pendingValidator);
    }

    // Publish on every configured transport. Success = any transport
    // accepted the publish (follow-up: surface per-transport failures).
    bool success = false;
    for (auto& t : m_transports) {
        if (!t) continue;  // see ~LogosAPIProvider — defensive null-skip.
        if (t->publishObject(name, m_moduleProxy)) success = true;
    }
    if (success) {
        m_registeredObjectName = name;
        qDebug() << "[LogosProviderObject] LogosAPIProvider: successfully published" << name;
    } else {
        qCritical() << "LogosAPIProvider: Failed to publish" << name;
    }

    return success;
}

QString LogosAPIProvider::registryUrl() const
{
    return m_registryUrl;
}

bool LogosAPIProvider::saveToken(const QString& from_module_name, const QString& token)
{
    if (!m_moduleProxy) {
        qWarning() << "LogosAPIProvider: Cannot save token - no module proxy available";
        return false;
    }

    qDebug() << "LogosAPIProvider: Delegating saveToken to module proxy for:" << from_module_name;
    return m_moduleProxy->saveToken(from_module_name, token);
}

void LogosAPIProvider::onEventResponse(LogosObject* object, const QString& eventName, const QVariantList& data)
{
    qDebug() << "[LogosObject] LogosAPIProvider::onEventResponse" << eventName << "-> LogosObject::emitEvent";

    if (eventName.isEmpty()) {
        qWarning() << "LogosAPIProvider: Event name cannot be empty";
        return;
    }
    if (!object) {
        qWarning() << "LogosAPIProvider: Cannot emit event on null object";
        return;
    }

    object->emitEvent(eventName, data);
}
