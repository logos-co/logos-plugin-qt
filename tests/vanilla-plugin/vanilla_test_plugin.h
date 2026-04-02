#pragma once
#include <QObject>
#include "interface.h"

class VanillaTestPlugin : public QObject, public PluginInterface {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PluginInterface_iid FILE "metadata.json")
    Q_INTERFACES(PluginInterface)
public:
    QString name() const override { return "vanilla_test"; }
    QString version() const override { return "1.0.0"; }
    Q_INVOKABLE QString hello() { return "world"; }
};
