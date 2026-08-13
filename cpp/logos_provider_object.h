#ifndef LOGOS_PROVIDER_OBJECT_H
#define LOGOS_PROVIDER_OBJECT_H

#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QJsonArray>
#include <nlohmann/json.hpp>
#include <functional>
#include <string>
#include <vector>

#include "logos_json_convert.h"

// The abstract LogosProviderObject interface (the provider-side counterpart
// of LogosObject, wrapped by ModuleProxy) moved to logos-protocol with the
// transport layer — see logos_provider_interface.h. This header keeps its
// historical name and continues to carry the developer-facing pieces:
// LogosProviderBase (which hands a LogosAPI* to module code, hence it lives
// here above the protocol layer), LogosProviderPlugin, and the
// LOGOS_PROVIDER / LOGOS_METHOD macros.
#include "logos_provider_interface.h"

class LogosAPI;

// ---------------------------------------------------------------------------
// LogosProviderBase — convenience base class for new-API modules
//
// Handles framework plumbing so the developer only writes business logic.
// callMethod() and getMethods() are provided by generated code produced
// by logos-cpp-generator --provider-header (analogous to Qt MOC).
// ---------------------------------------------------------------------------
class LogosProviderBase : public LogosProviderObject {
public:
    // These two are implemented by generated code (logos_provider_dispatch.cpp):
    //   QVariant callMethod(const QString& methodName, const QVariantList& args) override;
    //   QJsonArray getMethods() override;

    void setEventListener(EventCallback callback) override { m_eventCallback = callback; }
    bool informModuleToken(const QString& moduleName, const QString& token) override;
    void init(void* apiInstance) override;

protected:
    void emitEvent(const QString& eventName, const QVariantList& data);
    virtual void onInit(LogosAPI* api) {}
    LogosAPI* logosAPI() const { return m_logosAPI; }

private:
    EventCallback m_eventCallback;
    LogosAPI* m_logosAPI = nullptr;
};

// LogosProviderPlugin (the plugin-detection interface) now lives in
// logos-protocol's logos_provider_interface.h, included above — it stays
// visible to existing includers of this header.

// ---------------------------------------------------------------------------
// Macros — the developer-facing API
// ---------------------------------------------------------------------------

// LOGOS_PROVIDER: declares providerName/providerVersion and a private typedef.
// Place at the top of the class body (like Q_OBJECT).
#define LOGOS_PROVIDER(ClassName, Name, Version)            \
public:                                                     \
    QString providerName() const override { return Name; }  \
    QString providerVersion() const override { return Version; } \
    QVariant callMethod(const QString& methodName, const QVariantList& args) override; \
    QJsonArray getMethods() override;                        \
private:                                                    \
    using _LogosProviderThisType = ClassName;

// LOGOS_METHOD: marks a method as callable by the framework.
// Expands to nothing — scanned by logos-cpp-generator to produce
// callMethod() dispatch and getMethods() metadata (like Q_INVOKABLE + MOC).
#define LOGOS_METHOD

#endif // LOGOS_PROVIDER_OBJECT_H
