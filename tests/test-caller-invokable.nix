# THE ONE PART OF THIS THAT CAN ACTUALLY BE RUN.
#
# tests/test-caller-contract.nix guards the by-name contract as TEXT, which is
# the only instrument that reaches a string the compiler never sees. This one
# RUNS the host half: it builds a real LogosAPI, opens a real logos::CallerScope,
# and reaches the invokable the way the generated glue reaches it -- through
# QMetaObject::invokeMethod, by name, DirectConnection, Q_RETURN_ARG.
#
# WHAT IT CANNOT SHOW, said plainly so nobody reads more into a green run than
# is there: this is ONE image. The whole reason the pull is a dynamic by-name
# call is that the host and the module plugin each link their own copy of
# LogosAPI and of the protocol's caller thread-local, and a direct call binds to
# the wrong one on Mach-O and PE. A single-image test cannot distinguish the two
# -- a version that called logos::currentInboundCallerJson() directly would pass
# every assertion below. That property is guarded structurally, next door.
#
# What it DOES show, and what nothing else here can:
#   * the invokable is reachable BY NAME at runtime -- the meta-object really
#     carries it, rather than the string merely matching a declaration;
#   * "no dispatch in flight" comes back as {"kind":"unknown"} and never as an
#     empty string, which is the conversion the C ABI depends on (NULL there is
#     the POP, not a weaker identity);
#   * a scope's document survives the round trip verbatim, and the scope closes;
#   * A SCOPE OPEN ON ONE THREAD IS INVISIBLE ON ANOTHER. That is the oracle for
#     the rule the concurrency:"multi" emission is built around, and the reason
#     the pull has to happen before the worker is created rather than inside it.
{ pkgs, qtHost }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host-caller-invokable-test";
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
    #include "logos_api.h"
    #include "logos_caller_scope.h"
    #include "logos_mode.h"

    #include <QCoreApplication>
    #include <QMetaObject>
    #include <QString>

    #include <cstdio>
    #include <string>
    #include <thread>

    static int g_failures = 0;

    static void check(bool ok, const char* what)
    {
        std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
        if (!ok) ++g_failures;
    }

    // Exactly the call LogosProviderBase::currentCallerJson() makes. Spelled out
    // here rather than reused so this test exercises the CHANNEL (name +
    // DirectConnection + QString return), not the helper that wraps it.
    static QString pull(LogosAPI* api)
    {
        QString out;
        if (!QMetaObject::invokeMethod(api, "currentCallerJson",
                                       Qt::DirectConnection,
                                       Q_RETURN_ARG(QString, out))) {
            return QStringLiteral("<invokeMethod failed>");
        }
        return out;
    }

    int main(int argc, char** argv)
    {
        QCoreApplication app(argc, argv);
        // Mock: the provider's ctor builds a transport host, and this test has no
        // business binding a socket.
        LogosModeConfig::setMode(LogosMode::Mock);
        LogosAPI api("caller_probe");

        const QString unknown = QString::fromStdString(logos::callerUnknownJson());

        // 1. The meta-object really carries it. A plain (non-Q_INVOKABLE) method
        //    compiles, matches every grep, and fails right here.
        QString out;
        const bool reachable = QMetaObject::invokeMethod(
            &api, "currentCallerJson", Qt::DirectConnection,
            Q_RETURN_ARG(QString, out));
        check(reachable, "the invokable is reachable BY NAME through the meta-object");

        // 2. No dispatch in flight => the unknown DOCUMENT, never empty.
        //    logos::currentInboundCallerJson() answers empty here; converting that
        //    at this boundary is the contract, because on the module-impl C ABI a
        //    null document is the POP and would leave the module reading the
        //    PREVIOUS dispatch's caller.
        check(!out.isEmpty(), "outside a dispatch the answer is not empty");
        check(out == unknown, "outside a dispatch the answer is the unknown document");

        // 3. A scope's document survives the round trip verbatim.
        const std::string moduleDoc = logos::callerModuleJson("chat_module");
        {
            logos::CallerScope scope(moduleDoc);
            check(pull(&api) == QString::fromStdString(moduleDoc),
                  "inside a scope the scope's document comes back verbatim");

            // 4. THE MULTI ORACLE. The scope above is open on THIS thread. Another
            //    thread must see no caller at all -- which is why the generated
            //    concurrency:"multi" glue pulls before it creates its worker, and
            //    why pulling inside the worker yields Unknown on every platform.
            QString fromWorker;
            std::thread worker([&] { fromWorker = pull(&api); });
            worker.join();
            check(fromWorker == unknown,
                  "a scope open on one thread is INVISIBLE on another");
        }

        // 5. And it closes.
        check(pull(&api) == unknown, "the scope closes: back to the unknown document");

        if (g_failures) {
            std::printf("\n%d assertion(s) failed\n", g_failures);
            return 1;
        }
        std::printf("\nall assertions passed\n");
        return 0;
    }
    EOF

    cat > CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.14)
    project(LogosCallerInvokableProbe CXX)
    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)

    find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects)
    find_package(logos-qt-host REQUIRED)

    add_executable(probe probe.cpp)
    target_link_libraries(probe PRIVATE
      logos-qt-host::logos_qt_host
      Qt6::Core Qt6::RemoteObjects)
    EOF

    cmake -S . -B build -GNinja
    cmake --build build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # QT_QPA_PLATFORM is irrelevant to QCoreApplication, but the sandbox has no
    # writable runtime dir and Qt is noisy about it.
    export XDG_RUNTIME_DIR=$TMPDIR
    ./build/probe
    touch $out
    runHook postInstall
  '';

  dontFixup = true;
}
