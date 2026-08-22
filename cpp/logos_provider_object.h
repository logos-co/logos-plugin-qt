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
// historical name and continues to carry the Qt-side pieces:
// LogosProviderBase (which hands a LogosAPI* to the plugin glue above it,
// hence it lives here above the protocol layer), LogosProviderPlugin, and the
// now-vestigial LOGOS_PROVIDER / LOGOS_METHOD macros.
#include "logos_provider_interface.h"

class LogosAPI;

// ---------------------------------------------------------------------------
// LogosProviderBase — the host-side provider base the generated Qt plugin
// glue derives from
//
// Handles framework plumbing (token, event listener, LogosAPI hand-off) so the
// generated glue only has to forward calls. callMethod() and getMethods() are
// supplied by that generated code: logos-qt-host-generator --backend cdylib
// emits `<name>_cdylib_glue.{h,cpp}` from the module's LIDL contract, and the
// `<Name>CdylibProvider` in it derives from this class.
//
// (It was logos-cpp-generator --provider-header that filled those two slots,
// from LOGOS_METHOD markers in a hand-written `interface: "provider"` class.
// That flag is gone — it now exits non-zero pointing at interface: "universal"
// — and so is the `logos_provider_dispatch.cpp` it wrote. Module code itself no
// longer subclasses this at all; it derives from logos-cpp-sdk's Qt-FREE
// LogosModuleContext, and Qt appears only in the generated glue.)
// ---------------------------------------------------------------------------
class LogosProviderBase : public LogosProviderObject {
public:
    // These two are implemented by generated code (<name>_cdylib_glue.cpp):
    //   QVariant callMethod(const QString& methodName, const QVariantList& args) override;
    //   QJsonArray getMethods() override;

    void setEventListener(EventCallback callback) override { m_eventCallback = callback; }
    bool informModuleToken(const QString& moduleName, const QString& token) override;
    void init(void* apiInstance) override;

protected:
    void emitEvent(const QString& eventName, const QVariantList& data);
    virtual void onInit(LogosAPI* api) {}
    LogosAPI* logosAPI() const { return m_logosAPI; }

    /**
     * @brief THE PULL: who is calling the dispatch running on THIS thread,
     *        fetched out of the HOST image.
     *
     * Returns the logos-protocol caller document (a JSON object with a
     * mandatory "kind" — logos_module_impl.h has the normative shape), ready to
     * hand straight to logos_module_set_call_caller(). NEVER EMPTY and never
     * null: everything that cannot be answered resolves to
     * logos::callerUnknownJson(), because on that C ABI a NULL document is the
     * POP, so pushing one would leave the module reading whatever caller the
     * previous dispatch on this thread left behind.
     *
     * EXISTS SO THE GENERATED GLUE HAS ONE CALL. The body is a
     * QMetaObject::invokeMethod incantation whose every detail is load-bearing
     * (by name, DirectConnection, Q_RETURN_ARG) and which would otherwise be
     * copied into two emission sites — the single and the multi branch — where
     * a wrong copy still compiles.
     *
     * MUST BE CALLED ON THE DISPATCH THREAD, before any hand-off to a worker.
     * The document lives in a thread-local that ModuleProxy opened on the
     * thread it delivered the call on; a concurrency:"multi" worker has no such
     * scope and never will, so a pull made there answers Unknown on every
     * platform. std::string rather than QString or QByteArray so the value is
     * trivially safe to copy BY VALUE into that worker's lambda.
     */
    std::string currentCallerJson() const;

private:
    EventCallback m_eventCallback;
    LogosAPI* m_logosAPI = nullptr;
};

// LogosProviderPlugin (the plugin-detection interface) now lives in
// logos-protocol's logos_provider_interface.h, included above — it stays
// visible to existing includers of this header.

// ---------------------------------------------------------------------------
// Macros — VESTIGIAL
//
// These were the developer-facing API of `interface: "provider"`: you wrote the
// provider class by hand, tagged it LOGOS_PROVIDER and each exposed method
// LOGOS_METHOD, and logos-cpp-generator --provider-header scanned the header to
// emit the dispatch. That flag was removed (it now refuses, naming
// interface: "universal"), so NOTHING scans LOGOS_METHOD any more, and no
// module this repo builds expands LOGOS_PROVIDER — the generated cdylib glue
// writes the same overrides out longhand. They are kept only so an older
// translation unit still compiles. A module's plain public methods are now its
// API; the contract is derived from the impl header named by
// codegen.impl_class / codegen.impl_header.
// ---------------------------------------------------------------------------

// LOGOS_PROVIDER: declares providerName/providerVersion, the callMethod /
// getMethods overrides the generated dispatch defined, and a private typedef.
// Place at the top of the class body (like Q_OBJECT).
#define LOGOS_PROVIDER(ClassName, Name, Version)            \
public:                                                     \
    QString providerName() const override { return Name; }  \
    QString providerVersion() const override { return Version; } \
    QVariant callMethod(const QString& methodName, const QVariantList& args) override; \
    QJsonArray getMethods() override;                        \
private:                                                    \
    using _LogosProviderThisType = ClassName;

// LOGOS_METHOD: marked a method as callable by the framework.
// Expands to nothing, and now that is all it does: the scanner that read it
// (logos-cpp-generator --provider-header) was removed, so this is a no-op
// retained for source compatibility only.
#define LOGOS_METHOD

#endif // LOGOS_PROVIDER_OBJECT_H
