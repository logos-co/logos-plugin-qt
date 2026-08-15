// Load the built replica-factory plugin the way the host does, and assert the
// two bindings that a `strings | grep` cannot see.
//
// The host (logos-view-module-runtime, LogosQmlBridge::loadFactory) does
// exactly this: QPluginLoader::instance(), then
// qobject_cast<LogosViewReplicaFactory*>. Those are two SEPARATE bindings and
// they fail in different ways:
//
//   * the IID in Q_PLUGIN_METADATA is what QPluginLoader reads out of the
//     binary and what any IID-filtered discovery (QFactoryLoader, tooling)
//     matches on. Changing it does not necessarily break the qobject_cast
//     below — which is exactly why it is easy to change by accident and why
//     it has to be asserted EXACTLY rather than by substring.
//
//   * Q_INTERFACES is what makes moc emit the qt_metacast branch that
//     qobject_cast walks. Delete it and the cast returns nullptr: the plugin
//     loads, nothing errors, and the view is simply blank.
//
// This fixture is the module side, so it includes the module-side header the
// build just generated from the template under test. It does not carry a copy
// of the interface — that duplication is the thing being guarded against.
// Whether the module side agrees with the HOST side is a different question,
// answered by logos-module-builder's `view-interface-abi` check.

#include "LogosViewReplicaFactory.h"

#include <QCoreApplication>
#include <QJsonObject>
#include <QMetaObject>
#include <QPluginLoader>
#include <QString>

#include <cstdio>

static int fail(const char* what)
{
    std::fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    if (argc < 4) {
        std::fprintf(stderr,
                     "usage: %s <plugin> <expected-iid> <expected-replica-class>\n",
                     argv[0]);
        return 2;
    }
    const QString pluginPath = QString::fromLocal8Bit(argv[1]);
    const QString expectedIid = QString::fromLocal8Bit(argv[2]);
    const QString expectedReplica = QString::fromLocal8Bit(argv[3]);

    QPluginLoader loader(pluginPath);

    // 1. The IID the binary advertises, compared EXACTLY.
    const QString iid = loader.metaData().value(QStringLiteral("IID")).toString();
    if (iid.isEmpty())
        return fail("plugin exports no IID in its metadata "
                    "(Q_PLUGIN_METADATA missing, or moc did not run)");
    if (iid != expectedIid) {
        std::fprintf(stderr,
                     "FAIL: plugin advertises IID \"%s\", expected \"%s\"\n",
                     qUtf8Printable(iid), qUtf8Printable(expectedIid));
        return 1;
    }
    std::printf("OK: plugin advertises IID \"%s\" (exact match)\n",
                qUtf8Printable(iid));

    // 2. It actually loads.
    QObject* instance = loader.instance();
    if (!instance) {
        std::fprintf(stderr, "FAIL: QPluginLoader::instance() returned null: %s\n",
                     qUtf8Printable(loader.errorString()));
        return 1;
    }
    std::printf("OK: plugin instantiated as %s\n", instance->metaObject()->className());

    // 3. The cast the host performs. This is the Q_INTERFACES binding.
    auto* factory = qobject_cast<LogosViewReplicaFactory*>(instance);
    if (!factory)
        return fail("qobject_cast<LogosViewReplicaFactory*> returned nullptr — "
                    "the plugin does not declare the interface to moc "
                    "(Q_INTERFACES missing). The host would load this plugin, "
                    "log one warning, and show a blank view.");
    std::printf("OK: qobject_cast<LogosViewReplicaFactory*> succeeded\n");

    // 4. The interface is usable, and wired to the repc-generated replica.
    const QMetaObject* mo = factory->replicaMetaObject();
    if (!mo)
        return fail("replicaMetaObject() returned nullptr");
    if (expectedReplica != QString::fromLatin1(mo->className())) {
        std::fprintf(stderr,
                     "FAIL: replicaMetaObject() is \"%s\", expected \"%s\"\n",
                     mo->className(), qUtf8Printable(expectedReplica));
        return 1;
    }
    std::printf("OK: replicaMetaObject() is %s\n", mo->className());

    return 0;
}
