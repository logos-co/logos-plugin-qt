# A legacy Q_INVOKABLE plugin, wrapped in QtProviderObject, asked for a method it
# does not have. That used to answer an empty QVariant, which a typed caller read
# as the return type's default with an ok error; now it answers a rejection.
{ pkgs, qtHost }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host-qt-provider-unknown-method-test";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsNoGuiHook
  ];

  buildInputs = [
    pkgs.qt6.qtbase
    pkgs.qt6.qtremoteobjects
    pkgs.boost
    pkgs.openssl
    pkgs.nlohmann_json
    qtHost
  ];

  dontUseCmakeConfigure = true;

  buildPhase = ''
    runHook preBuild
    mkdir -p work && cd work

    cat > probe.cpp <<'EOF'
    #include "interface.h"
    #include "logos_api.h"
    #include "logos_mode.h"
    #include "qt_provider_object.h"

    #include <QCoreApplication>
    #include <QDebug>
    #include <QObject>
    #include <QVariantMap>

    #include <cstdio>

    class LegacyProbe : public QObject, public PluginInterface {
        Q_OBJECT
        Q_INTERFACES(PluginInterface)
    public:
        QString name() const override { return QStringLiteral("legacy_probe"); }
        QString version() const override { return QStringLiteral("1.0.0"); }
        Q_INVOKABLE int add(int a, int b) { return a + b; }
        Q_INVOKABLE int over(int a) { return a; }
        Q_INVOKABLE int over(int a, int b) { return a + b; }
    signals:
        void eventResponse(const QString& eventName, const QVariantList& data);
    };

    static int g_failures = 0;

    static void check(bool ok, const char* what, const QVariant& got)
    {
        QString shown;
        QDebug(&shown) << got;
        std::printf("%s  %s (got %s)\n", ok ? "ok  " : "FAIL", what, qPrintable(shown));
        if (!ok) ++g_failures;
    }

    static QVariantMap rejection(const char* code, const QString& message)
    {
        return {{QStringLiteral("code"), QString::fromLatin1(code)},
                {QStringLiteral("message"), message},
                {QStringLiteral("origin"), QStringLiteral("legacy_probe")}};
    }

    int main(int argc, char** argv)
    {
        QCoreApplication app(argc, argv);
        // Mock: the provider's ctor builds a transport host, and this test has no
        // business binding a socket.
        LogosModeConfig::setMode(LogosMode::Mock);
        LogosAPI api("legacy_probe");
        LegacyProbe plugin;
        plugin.logosAPI = &api;
        QtProviderObject provider(&plugin);

        QVariant got = provider.callMethod(QStringLiteral("add"), {2, 3});
        check(got.toInt() == 5, "a known method still answers", got);

        got = provider.callMethod(QStringLiteral("noSuchMethod"), {});
        check(got.toMap() == rejection("unknown_method", QStringLiteral("unknown method 'noSuchMethod'")),
              "an unknown name is refused as unknown_method", got);

        got = provider.callMethod(QStringLiteral("add"), {1});
        check(got.toMap() == rejection("invalid_args", QStringLiteral("expected 2 arguments, got 1")),
              "a known name with the wrong arity is refused as invalid_args", got);

        got = provider.callMethod(QStringLiteral("over"), {1, 2, 3});
        check(got.toMap() == rejection("invalid_args", QStringLiteral("no overload of 'over' takes 3 arguments")),
              "no overload with that arity is refused as invalid_args", got);

        // ModuleProxy answers these from providerName()/providerVersion(), on an empty reply.
        got = provider.callMethod(QStringLiteral("name"), {});
        check(!got.isValid(), "a bare name() the plugin lacks is left empty for the host", got);
        got = provider.callMethod(QStringLiteral("version"), {});
        check(!got.isValid(), "a bare version() the plugin lacks is left empty for the host", got);

        if (g_failures) {
            std::printf("\n%d assertion(s) failed\n", g_failures);
            return 1;
        }
        std::printf("\nall assertions passed\n");
        return 0;
    }

    #include "probe.moc"
    EOF

    cat > CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.14)
    project(LogosQtProviderUnknownMethodProbe CXX)
    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_AUTOMOC ON)

    find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects)
    find_package(logos-qt-host REQUIRED)

    add_executable(probe probe.cpp)
    target_include_directories(probe PRIVATE ''${LOGOS_QT_HOST_PREFIX}/include/core)
    target_link_libraries(probe PRIVATE
      logos-qt-host::logos_qt_host
      Qt6::Core Qt6::RemoteObjects)
    EOF

    cmake -S . -B build -GNinja -DLOGOS_QT_HOST_PREFIX=${qtHost}
    cmake --build build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    export XDG_RUNTIME_DIR=$TMPDIR
    ./build/probe
    touch $out
    runHook postInstall
  '';

  dontFixup = true;
}
