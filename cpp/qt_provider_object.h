#ifndef QT_PROVIDER_OBJECT_H
#define QT_PROVIDER_OBJECT_H

#include "logos_provider_object.h"
#include <QObject>

class PluginInterface;

// LEGACY, and carried here deliberately. This adapter is slated for deletion,
// but LogosAPIProvider::registerObject still falls back to it for any plugin
// that exposes a plain QObject instead of a LogosProviderPlugin, and the
// modules that rely on that fallback have not been migrated yet. Dropping it
// while relocating the host runtime would have changed behaviour for them, so
// it comes across unchanged; it goes once the last legacy module is migrated.

/**
 * @brief Adapter that wraps an existing QObject-based plugin as a LogosProviderObject.
 *
 * This allows legacy plugins (using Q_INVOKABLE / Qt signals) to work through
 * the new LogosProviderObject interface without any changes to the plugin code.
 * All dispatch goes through QMetaObject — the same path that ModuleProxy used
 * to handle directly.
 */
class QtProviderObject : public QObject, public LogosProviderObject {
    Q_OBJECT

public:
    explicit QtProviderObject(QObject* module, QObject* parent = nullptr);
    ~QtProviderObject() override;

    QVariant callMethod(const QString& methodName, const QVariantList& args) override;
    bool informModuleToken(const QString& moduleName, const QString& token) override;
    QJsonArray getMethods() override;
    void setEventListener(EventCallback callback) override;
    void init(void* apiInstance) override;
    QString providerName() const override;
    QString providerVersion() const override;

private slots:
    void onWrappedEventResponse(const QString& eventName, const QVariantList& data);

private:
    QObject* m_module;
    EventCallback m_eventCallback;
};

#endif // QT_PROVIDER_OBJECT_H
