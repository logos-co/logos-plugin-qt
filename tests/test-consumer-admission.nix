# ADOPTING AN ADMITTED CONSUMER — the operation, run for real.
#
# The runtime admits a non-module consumer (a UI plugin, a shell's co-process):
# a host asks core_service.admitConsumer and capability_module, the token
# authority, mints and records its credential. logos::adoptAdmittedConsumer is
# this image's half: an isolated token store for the name, with that credential
# installed under the bootstrap keys, so the identity presents its OWN credential
# and is named as itself. Nothing here mints or registers.
#
# WHY A REAL PROXY AND NOT A MOCK. Mock mode authorizes everything and records
# nothing, so an identity presenting the wrong credential would pass. This runs a
# genuine ModuleProxy for "capability_module" in Local mode, so the consumer's
# call goes through ModuleProxy::authorize. The stand-in learns the credential
# over the host's channel, as the runtime's admission would tell capability.
#
# WHAT THIS CANNOT SHOW: it is one process and one image, so it says nothing
# about the cross-image concerns (a module cdylib's own TokenManager). Those are
# guarded in logos-protocol and by the symbol gates downstream.
{ pkgs, qtHost }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host-consumer-admission-test";
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
    #include "logos_api_client.h"
    #include "logos_consumer.h"

    #include "logos_caller_scope.h"
    #include "logos_mode.h"
    #include "logos_provider_interface.h"
    #include "logos_rpc_status.h"
    #include "module_proxy.h"
    #include "plugin_registry.h"
    #include "token_manager.h"

    #include <QCoreApplication>
    #include <QJsonArray>
    #include <QJsonObject>
    #include <QString>
    #include <QVariant>
    #include <QVariantList>

    #include <cstdio>
    #include <string>

    static int g_failures = 0;

    static void check(bool ok, const char* what)
    {
        std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
        if (!ok) ++g_failures;
    }

    // The stand-in for capability_module: a real provider behind a real
    // ModuleProxy, registered in the Local-mode plugin registry under the name
    // LogosAPIConsumer asks for.
    class CapabilityStandIn : public LogosProviderObject {
    public:
        QVariant callMethod(const QString& method, const QVariantList&) override {
            ++calls;
            seenCaller = logos::currentInboundCallerJson();
            if (method == QLatin1String("work")) return QStringLiteral("ok");
            return QVariant();
        }
        bool informModuleToken(const QString& moduleName, const QString& token) override {
            ++informs;
            // A real capability_module also files the token in its own store;
            // mirrored here so the proxy's behaviour is the real one.
            TokenManager::instance().saveToken(moduleName, token);
            return true;
        }
        QJsonArray getMethods() override {
            QJsonObject work;
            work["name"] = QStringLiteral("work");
            work["type"] = QStringLiteral("method");
            return QJsonArray{ work };
        }
        void setEventListener(EventCallback) override {}
        void init(void*) override {}
        QString providerName() const override { return QStringLiteral("capability_module"); }
        QString providerVersion() const override { return QStringLiteral("1.0.0"); }

        int         calls   = 0;
        int         informs = 0;
        std::string seenCaller;
    };

    static bool dispatched(const QVariant& r) {
        return !logos::isUnauthorizedSentinel(r) && r.toString() == QStringLiteral("ok");
    }

    static std::string moduleDoc(const QString& name) {
        return std::string(R"({"kind":"module","name":")") + name.toStdString() + R"("})";
    }

    int main(int argc, char** argv)
    {
        QCoreApplication app(argc, argv);
        LogosModeConfig::setMode(LogosMode::Local);

        // The host's own credential, exactly where a host writes it.
        const QString hostAnchor = QStringLiteral("probe-host-anchor");
        TokenManager::instance().adoptCredential(hostAnchor);

        CapabilityStandIn capability;
        ModuleProxy capProxy(&capability, nullptr, &TokenManager::instance());
        PluginRegistry::registerPlugin(&capProxy, QStringLiteral("capability_module"));

        LogosAPI hostApi(QStringLiteral("core"), &app);

        // ── an identity nobody admitted can do nothing ───────────────────────
        //
        // LogosAPI::forIdentity on its own is HALF an identity: an isolated
        // store and no credential. It must be inert rather than powerful.
        const QString halfIdentity = QStringLiteral("probe_view_half");
        LogosAPI* halfApi = LogosAPI::forIdentity(halfIdentity, &app);
        check(halfApi != nullptr, "forIdentity still builds an isolated LogosAPI");
        const QString halfPresents =
            halfApi ? halfApi->getTokenManager()->getToken(QStringLiteral("capability_module"))
                    : QStringLiteral("x");
        check(halfPresents.isEmpty(), "an unadmitted identity has nothing to present");
        check(logos::isUnauthorizedSentinel(
                  capProxy.callRemoteMethod(halfPresents, QStringLiteral("work"), {})),
              "an unadmitted identity is refused");

        // ── adoptAdmittedConsumer: capability_module minted it elsewhere ─────
        //
        // With capability as the token authority the runtime admits the name
        // (core_service.admitConsumer) and this image only installs. The stand-in
        // learns the credential over the host's channel, as that admission would.
        const QString adopted = QStringLiteral("probe_view_adopted");
        const QString minted  = QStringLiteral("probe-minted-by-capability");
        hostApi.getClient(QStringLiteral("capability_module"))
            ->informModuleToken(hostAnchor, adopted, minted);
        const int informsBefore = capability.informs;
        logos::ConsumerIdentity adoptedId = logos::adoptAdmittedConsumer(adopted, minted, &app);
        check(static_cast<bool>(adoptedId), "adoptAdmittedConsumer returns an identity");
        check(capability.informs == informsBefore, "and registers nothing itself");
        TokenManager* adoptedStore = adoptedId.api ? adoptedId.api->getTokenManager() : nullptr;
        check(adoptedStore != nullptr && adoptedStore != &TokenManager::instance(),
              "the consumer's store is private, not the ambient ring");
        if (adoptedStore) {
            check(adoptedStore->getToken(QStringLiteral("capability_module")) == minted,
                  "its capability_module token is the credential it was given");
            check(adoptedStore->getToken(QStringLiteral("core")) == minted,
                  "so is its core token");
            check(adoptedStore->tokenCount() == TokenManager::bootstrapKeys().size(),
                  "and nothing else was installed");
        }
        check(TokenManager::identitiesSharingHostAnchor().isEmpty(),
              "no isolated identity holds a value of the host's");
        check(dispatched(capProxy.callRemoteMethod(minted, QStringLiteral("work"), {})),
              "NO LOCKOUT: the adopted credential authorizes at capability_module");
        check(capability.seenCaller == moduleDoc(adopted),
              "and it is NAMED as itself, not as the host");

        // The control: the host still authorizes and still reads as the host.
        check(dispatched(capProxy.callRemoteMethod(hostAnchor, QStringLiteral("work"), {})),
              "control: the host's own anchor still authorizes");
        check(capability.seenCaller == R"({"kind":"host"})",
              "control: and still reads as the host");
        check(!logos::adoptAdmittedConsumer(QStringLiteral("probe_view_empty"), QString(), &app),
              "an empty credential is refused");
        check(!logos::adoptAdmittedConsumer(QStringLiteral("probe_view_anchor"), hostAnchor, &app),
              "the host's anchor is refused");

        const QString reminted = QStringLiteral("probe-reminted");
        if (adoptedStore) adoptedStore->saveToken(QStringLiteral("some_target"),
                                                  QStringLiteral("probe-stale"));
        check(logos::replaceConsumerCredential(adoptedId.api, reminted),
              "replaceConsumerCredential installs a re-admission's credential");
        check(adoptedStore && adoptedStore->getToken(QStringLiteral("capability_module")) == reminted
                  && adoptedStore->getToken(QStringLiteral("some_target")).isEmpty(),
              "and drops the previous incarnation's tokens");
        LogosAPI neverAdopted(QStringLiteral("probe_view_never_adopted"), &app);
        check(!logos::replaceConsumerCredential(&neverAdopted, reminted),
              "an identity that was never adopted is refused");

        // ── adoptConsumerCredential: the co-process form ─────────────────────
        //
        // ui-host's case: the runtime admitted it, this image only installs.
        // Its store is its own image's instance(), which is correct for a
        // separate process.
        LogosAPI coprocess(QStringLiteral("probe_view_coprocess"), &app);
        logos::adoptConsumerCredential(&coprocess, QStringLiteral("probe-coprocess-cred"));
        check(coprocess.getTokenManager()->getToken(QStringLiteral("core"))
                  == QStringLiteral("probe-coprocess-cred")
              && coprocess.getTokenManager()->getToken(QStringLiteral("capability_module"))
                  == QStringLiteral("probe-coprocess-cred"),
              "adoptConsumerCredential installs under every bootstrap key");

        std::printf("%s\n", g_failures == 0 ? "ALL OK" : "FAILURES");
        return g_failures == 0 ? 0 : 1;
    }
    EOF

    cat > CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.14)
    project(LogosConsumerAdmissionProbe CXX)
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
    export XDG_RUNTIME_DIR=$TMPDIR
    ./build/probe
    touch $out
    runHook postInstall
  '';

  dontFixup = true;
}
