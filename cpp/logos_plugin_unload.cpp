#include "logos_plugin_unload.h"

#include <QElapsedTimer>
#include <QEventLoop>
#include <QMetaObject>
#include <QObject>
#include <QTimer>
#include <QtGlobal>

namespace logos {

// Invoked BY NAME, not through the vtable, and that is the whole reason this is
// shaped the way it is. `PluginInterface` is compiled into every module .so
// separately; adding a virtual to it would shift the vtable under every plugin
// already built and turn a missing hook into undefined behaviour instead of a
// no-op. `initLogos` is delivered the same way for the same reason.
//
// A plugin that does not declare the hook simply has no such meta-method:
// invokeMethod returns false, we log nothing and move on. That is the common
// case and it must stay free.
void runPluginAboutToUnload(QObject* plugin, int graceMs)
{
    if (!plugin) return;

    int flag = 0;  // LogosShutdown::Synchronous
    if (!QMetaObject::invokeMethod(plugin, "aboutToUnload",
                                   Qt::DirectConnection, Q_RETURN_ARG(int, flag))) {
        return;  // module predates the hook, or does not want it
    }
    if (flag == 0) return;  // Synchronous: already quiescent

    // Asynchronous: the module is finishing. Run a nested event loop rather
    // than sleeping -- unloadFinished() may arrive as a queued event from a
    // worker thread, and a module doing its last work almost certainly needs
    // the loop running to do it. The signal is reached by NAME for the same
    // ABI reason as the hook itself.
    QElapsedTimer elapsed;
    elapsed.start();

    QEventLoop loop;
    QTimer deadline;
    deadline.setSingleShot(true);
    const bool connected = QObject::connect(plugin, SIGNAL(unloadFinished()),
                                            &loop, SLOT(quit()));
    if (!connected) {
        // The module said Asynchronous but exposes no way to say it is done.
        // Waiting out the full grace period for a signal that cannot arrive
        // helps nobody.
        qWarning("module returned Asynchronous from aboutToUnload() but has no "
                 "unloadFinished() signal; not waiting");
        return;
    }
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    deadline.start(graceMs);
    loop.exec();

    // Still armed means the loop was quit by the signal rather than by the
    // deadline -- the one bit that separates "finished" from "gave up".
    const bool finished = deadline.isActive();
    deadline.stop();

    if (!finished) {
        // Loud, because it costs every teardown of this module the full grace
        // period and the module is the only thing that can fix it.
        qWarning("module did not finish unloading within %dms; proceeding", graceMs);
    } else {
        qDebug("module finished unloading in %lldms", (long long)elapsed.elapsed());
    }
}

} // namespace logos
