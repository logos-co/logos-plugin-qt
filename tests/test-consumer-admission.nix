# ADMITTING A NON-MODULE CONSUMER — the operation, run for real.
#
# logos::admitConsumer is the one place that performs the four steps a host used
# to hand-roll: isolate the identity's token store, mint its credential,
# REGISTER that credential with capability_module over the host's trusted
# channel, and only then ADOPT it into the identity's own store. Two applications
# spelled those steps out independently and one of them got the ORDER wrong, so
# this probe checks the order rather than just the outcome.
#
# WHY A REAL PROXY AND NOT A MOCK. Mock mode's informModuleToken returns true
# unconditionally and records nothing, so an admitConsumer that registered with
# the wrong token — or did not register at all — would pass. This runs a genuine
# ModuleProxy for "capability_module" in Local mode, so the registration goes
# through ModuleProxy::informModuleToken's trusted-channel gate and the
# consumer's later call goes through ModuleProxy::authorize.
#
# THE ORDERING ASSERTION is the one that could not be made any other way: the
# stand-in capability_module reads the consumer's private store from INSIDE the
# informModuleToken push, and asserts it is still empty at that instant. Adopting
# before registering would put a credential in the store that the trust root has
# not yet accepted — the window both hosts' comments say they close, now closed
# by construction instead of by comment.
#
# WHAT THIS CANNOT SHOW: it is one process and one image, so it says nothing
# about the cross-image concerns (a module cdylib's own TokenManager). Those are
# guarded in logos-protocol and by the symbol gates downstream.
#
# VALIDATED BY RUNNING IT AGAINST CODE THAT DOES NOT HAVE THE MECHANISM — two
# throwaway edits to cpp/logos_consumer.cpp, made and thrown away:
#
#   (N1) THE ADOPT STEP REMOVED — mint and register, then drop the credential on
#        the floor. That is exactly what all five hand-rolled registration sites
#        do today. 5 checks FAIL:
#          its capability_module token is its OWN credential
#          so is its core token
#          and nothing else was installed
#          NO LOCKOUT: the consumer's own credential authorizes at capability_module
#          and it is NAMED as itself, not as the host
#        i.e. the identity is registered under a credential nobody holds, and it
#        can call nothing. On master this is masked by the private store having
#        been born holding the host's anchor.
#
#   (N2) ADOPT BEFORE REGISTER — the two steps swapped. 2 checks FAIL:
#          REGISTER BEFORE ADOPT: the store is still empty during the push
#          and leaves no credential behind
#        The second is the part that is easy to miss: with the order reversed, a
#        registration that FAILS leaves a live credential in the consumer's store
#        that capability_module never accepted. Ordering is not a stylistic
#        preference here.
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
    #include <functional>
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
            lastName  = moduleName;
            lastToken = token;
            if (onInform) onInform(moduleName);
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
        QString     lastName;
        QString     lastToken;
        std::string seenCaller;
        std::function<void(const QString&)> onInform;
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

        // ── the ordering assertion, armed before the admission ───────────────
        //
        // Read the consumer's store from INSIDE the push. Register-before-adopt
        // means it is still empty at this instant.
        bool storeWasEmptyAtRegistration = false;
        bool sawRegistration             = false;
        capability.onInform = [&](const QString& name) {
            sawRegistration = true;
            storeWasEmptyAtRegistration =
                TokenManager::forIdentity(name).tokenCount() == 0;
        };

        const QString identity = QStringLiteral("probe_view_alpha");
        logos::ConsumerIdentity consumer = logos::admitConsumer(identity, &hostApi, &app);
        capability.onInform = nullptr;

        check(static_cast<bool>(consumer), "admitConsumer returns an identity");
        check(consumer.api != nullptr, "the consumer gets a LogosAPI of its own");
        check(!consumer.credential.isEmpty(), "the consumer gets a credential");
        check(consumer.credential != hostAnchor,
              "the credential is NOT the host's anchor");
        check(sawRegistration, "capability_module was told about the identity");
        check(capability.lastName == identity,
              "it was told about THIS identity");
        check(capability.lastToken == consumer.credential,
              "it was told the credential the caller was handed");
        check(storeWasEmptyAtRegistration,
              "REGISTER BEFORE ADOPT: the store is still empty during the push");

        // ── the store the consumer actually presents from ────────────────────
        TokenManager* store = consumer.api ? consumer.api->getTokenManager() : nullptr;
        check(store != nullptr && store != &TokenManager::instance(),
              "the consumer's store is private, not the ambient ring");
        if (store) {
            check(store->getToken(QStringLiteral("capability_module")) == consumer.credential,
                  "its capability_module token is its OWN credential");
            check(store->getToken(QStringLiteral("core")) == consumer.credential,
                  "so is its core token");
            check(store->tokenCount() == TokenManager::bootstrapKeys().size(),
                  "and nothing else was installed");
            check(store->getToken(QStringLiteral("capability_module")) != hostAnchor,
                  "NO ANCHOR: it does not hold the host's credential");
        }
        check(TokenManager::identitiesSharingHostAnchor().isEmpty(),
              "no isolated identity holds a value of the host's");

        // ── NO LOCKOUT: the consumer can actually call capability_module ──────
        const QString presented =
            store ? store->getToken(QStringLiteral("capability_module")) : QString();
        check(dispatched(capProxy.callRemoteMethod(presented, QStringLiteral("work"), {})),
              "NO LOCKOUT: the consumer's own credential authorizes at capability_module");
        check(capability.seenCaller == moduleDoc(identity),
              "and it is NAMED as itself, not as the host");

        // The control: the host still authorizes and still reads as the host.
        check(dispatched(capProxy.callRemoteMethod(hostAnchor, QStringLiteral("work"), {})),
              "control: the host's own anchor still authorizes");
        check(capability.seenCaller == R"({"kind":"host"})",
              "control: and still reads as the host");

        // ── an identity nobody admitted can do nothing ───────────────────────
        //
        // LogosAPI::forIdentity on its own is HALF an identity: an isolated
        // store and no credential. That is what a host doing only the first
        // hand-rolled step produces, and it must be inert rather than powerful.
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

        // ── reissue: a reload rotates the credential ─────────────────────────
        const QString first = consumer.credential;
        if (store) store->saveToken(QStringLiteral("some_target"),
                                    QStringLiteral("probe-stale-per-target"));
        const QString second = logos::reissueConsumerCredential(consumer.api, &hostApi);
        check(!second.isEmpty(), "reissue returns a new credential");
        check(second != first, "and it is a different one");
        if (store) {
            check(store->getToken(QStringLiteral("capability_module")) == second,
                  "the store presents the new credential");
            check(store->getToken(QStringLiteral("some_target")).isEmpty(),
                  "and the previous incarnation's per-target tokens are gone");
        }
        check(dispatched(capProxy.callRemoteMethod(second, QStringLiteral("work"), {})),
              "the new credential authorizes");
        check(logos::isUnauthorizedSentinel(
                  capProxy.callRemoteMethod(first, QStringLiteral("work"), {})),
              "the superseded credential does not");

        // ── adoptConsumerCredential: the co-process form ─────────────────────
        //
        // ui-host's case: the parent minted and registered, this image only
        // installs. Its store is its own image's instance(), which is correct
        // for a separate process.
        LogosAPI coprocess(QStringLiteral("probe_view_coprocess"), &app);
        logos::adoptConsumerCredential(&coprocess, QStringLiteral("probe-coprocess-cred"));
        check(coprocess.getTokenManager()->getToken(QStringLiteral("core"))
                  == QStringLiteral("probe-coprocess-cred")
              && coprocess.getTokenManager()->getToken(QStringLiteral("capability_module"))
                  == QStringLiteral("probe-coprocess-cred"),
              "adoptConsumerCredential installs under every bootstrap key");

        // ── the failure path leaves nothing half-admitted ────────────────────
        //
        // A host with no capability_module token is not the trusted channel, so
        // registration cannot happen — and the identity must end up with NO
        // credential rather than an unregistered one.
        LogosAPI strangerHost(QStringLiteral("probe_stranger_host"), &app);
        strangerHost.getTokenManager();   // its store is the ambient ring
        TokenManager::instance().removeToken(QStringLiteral("capability_module"));
        const QString doomed = QStringLiteral("probe_view_doomed");
        logos::ConsumerIdentity none = logos::admitConsumer(doomed, &strangerHost, &app);
        check(!static_cast<bool>(none), "admitConsumer fails when the host is not trusted");
        check(TokenManager::forIdentity(doomed).tokenCount() == 0,
              "and leaves no credential behind");

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
