#ifndef LOGOS_PLUGIN_UNLOAD_H
#define LOGOS_PLUGIN_UNLOAD_H

// The host side of the module teardown hook.
//
// A Logos Qt plugin may expose, on its plugin class:
//
//     Q_INVOKABLE int aboutToUnload();   // 0 = Synchronous, 1 = Asynchronous
//   Q_SIGNALS:
//     void unloadFinished();
//
// modelled on Qt Creator's IPlugin::aboutToShutdown()/ShutdownFlag. Returning
// Asynchronous buys the module a bounded GRACE PERIOD, not a veto: the host
// waits for unloadFinished() or the deadline, whichever comes first, and then
// proceeds to tear the plugin down regardless.
//
// WHY THIS LIVES HERE. Two hosts drive this hook -- logos_host (the core-module
// loader) and ui-host (the view-module runtime) -- and the dance below is
// subtle enough that two copies of it would drift. This repo is the one that
// also EMITS the surface it reaches (qt-host-generator/lidl_gen_cdylib_glue.cpp
// writes both member declarations above), so keeping the consumer beside the
// emitter puts both halves of a BY-NAME contract under one test:
// tests/test-unload-contract.nix extracts the names from freshly generated glue
// and greps this helper's implementation for the same ones, so renaming either
// half alone turns red.
//
// The GRACE PERIOD is deliberately NOT a constant here. It is a policy each
// host owns, because each host is carved out of a different hard-kill budget:
// logos_host has 5s from the container before SIGKILL, ui-host has 3s from
// ViewModuleHost::stop() before kill(). Passing it in is what keeps one
// algorithm serving two budgets.

class QObject;

namespace logos {

// Give `plugin` its chance to finish, then return.
//
// Call this AFTER the application event loop has returned and BEFORE deleting
// the plugin -- the nested event loop below is only safe once the outer
// exec() is done.
//
// Returns as soon as the plugin says it is already quiescent, which is the
// common case and costs one meta-call. Blocks for at most `graceMs` otherwise.
// A null plugin, a plugin with no such meta-method, or a plugin that returns
// Synchronous are all no-ops.
void runPluginAboutToUnload(QObject* plugin, int graceMs);

} // namespace logos

#endif // LOGOS_PLUGIN_UNLOAD_H
