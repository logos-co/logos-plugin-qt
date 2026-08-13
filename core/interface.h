#ifndef PLUGIN_INTERFACE_H
#define PLUGIN_INTERFACE_H

#include <QtPlugin>
#include <QString>
#include "../cpp/logos_api.h"

// Define the common base interface for all modules
class PluginInterface
{
public:
    virtual ~PluginInterface() {}
    
    // Common plugin methods
    virtual QString name() const = 0;
    virtual QString version() const = 0;

    // TODO: this should be defined here and removed from the modules, but needs some work
    // Q_INVOKABLE void initLogos(LogosAPI* logosAPIInstance);

    LogosAPI* logosAPI = nullptr;
};

// Define the interface ID used by Qt's plugin system
#define PluginInterface_iid "com.example.PluginInterface"

Q_DECLARE_INTERFACE(PluginInterface, PluginInterface_iid)

#endif // PLUGIN_INTERFACE_H 
