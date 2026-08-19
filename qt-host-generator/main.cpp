// logos-qt-host-generator — the cdylib -> Qt-plugin glue for a Logos module.
//
// A cdylib module (Rust, or C++ compiled to the same shape) exposes the
// language-neutral module-impl C ABI (logos_module_impl.h) and nothing else.
// This tool emits the Qt plugin that logos_host actually loads around it:
//
//   <name>_cdylib_glue.h    the *CdylibProvider (LogosProviderBase) and the
//                           *CdylibPlugin (PluginInterface +
//                           LogosProviderPlugin, Q_PLUGIN_METADATA)
//   <name>_cdylib_glue.cpp  callMethod / getMethods / informModuleToken /
//                           setEventListener / onInit, each forwarding across
//                           the C ABI
//
// The glue is uniform: it only knows the C symbols, so it is identical
// whatever language sits behind them. That is why it belongs with the Qt
// plugin BACKEND (this repo) rather than with a language SDK — the C-ABI
// impl-exports on the other side of that boundary are logos-cpp-generator's
// job, and the two halves meet only at logos_module_impl.h.
//
// Usage:
//   logos-qt-host-generator --lidl <contract.lidl>
//                           [--concurrency multi] [--output-dir <dir>]

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTextStream>

#include "lidl_compat.h"
#include "lidl_gen_cdylib_glue.h"

namespace {

struct Out { QString file; QString content; };

int writeAll(const QList<Out>& outs, const QString& dir,
             QTextStream& out, QTextStream& err)
{
    for (const Out& o : outs) {
        const QString abs = QDir(dir).filePath(o.file);
        QFile f(abs);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
            err << "Failed to write: " << abs << "\n";
            return 1;
        }
        f.write(o.content.toUtf8());
        out << "Generated: " << abs << "\n";
    }
    return 0;
}

QString argValue(const QStringList& args, const QString& flag)
{
    const int i = args.indexOf(flag);
    return (i != -1 && i + 1 < args.size()) ? args.at(i + 1) : QString();
}

} // namespace

int main(int argc, char* argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    QTextStream err(stderr);
    const QStringList args = app.arguments();

    const QString lidlPath = argValue(args, "--lidl");
    // concurrency:"multi" (from metadata.json, fed by the builder) ⇒ emit the
    // deferred dispatch instead: callMethod hands the call to a worker and
    // returns a pending sentinel, and the result comes back as a completion
    // event. Anything other than the exact word "multi" means single.
    const bool multi = argValue(args, "--concurrency") == QStringLiteral("multi");
    QString outputDir = argValue(args, "--output-dir");

    if (lidlPath.isEmpty()) {
        err << "Usage: logos-qt-host-generator --lidl <contract.lidl>\n"
               "         [--concurrency multi] [--output-dir <dir>]\n";
        return 1;
    }

    // This binary emits ONE backend, so --backend is not a mode selector here.
    // Accept the value the multi-backend generator used for this path, and
    // REFUSE any other, rather than ignoring the flag: callers are migrating
    // from a tool where --backend was required and dispatched on, so silently
    // treating `--backend qt` as cdylib would hand back confidently wrong
    // artifacts (the qt backend emitted <name>_qt_glue.h + _dispatch.cpp +
    // _events.cpp — different files entirely; it has since been removed from
    // logos-qt-generator too, which now emits only `consumer` and `ui`) with a
    // zero exit status.
    const QString backend = argValue(args, "--backend");
    if (!backend.isEmpty() && backend != QStringLiteral("cdylib")) {
        err << "Error: logos-qt-host-generator only emits the cdylib backend, "
            << "but --backend " << backend << " was requested.\n";
        return 2;
    }
    if (outputDir.isEmpty())
        outputDir = QDir::current().filePath("generated");
    QDir().mkpath(outputDir);

    QFile f(lidlPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        err << "Failed to open LIDL file: " << lidlPath << "\n";
        return 3;
    }
    LidlParseResult pr = lidlParse(QString::fromUtf8(f.readAll()));
    if (pr.hasError()) {
        err << lidlPath << ":" << pr.errorLine << ":" << pr.errorColumn
            << ": " << pr.error << "\n";
        return 4;
    }
    const ModuleDecl& mod = pr.module;

    QList<Out> outs;
    outs.append({qs(mod.name) + "_cdylib_glue.h", lidlMakeCdylibGlueHeader(mod, multi)});
    outs.append({qs(mod.name) + "_cdylib_glue.cpp", lidlMakeCdylibGlueSource(mod, multi)});

    const int rc = writeAll(outs, outputDir, out, err);
    out.flush();
    return rc;
}
