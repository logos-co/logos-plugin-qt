# Builds logos-qt-host — the Qt HOST RUNTIME a Logos Qt plugin links against:
# LogosAPI (the object handed to initLogos), LogosAPIProvider (the transport
# hosts, ModuleProxy/handshake publication and token-validator injection),
# LogosProviderBase + the LOGOS_PROVIDER/LOGOS_METHOD macros, and the legacy
# QMetaObject adapter. A static library plus its headers and CMake package
# config, so a plugin build can `find_package(logos-qt-host)`.
{ pkgs, src, protocolLib }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host";
  version = "0.1.0";

  inherit src;

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
    protocolLib
  ];

  # Same propagation policy as logos-protocol / logos-qt-sdk: Qt is excluded
  # (setup-hook ordering), the protocol and the plain transport's deps are
  # carried so a consumer's find_dependency() resolves them.
  propagatedBuildInputs = [
    pkgs.boost
    pkgs.openssl
    pkgs.nlohmann_json
    protocolLib
  ];

  # The CMake project is cpp/, but the source tree must be the repo root:
  # cpp/CMakeLists.txt installs ../core/interface.h alongside its own headers.
  dontUseCmakeConfigure = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p build-qt-host
    cd build-qt-host
    cmake ../cpp -GNinja -DCMAKE_INSTALL_PREFIX=$out \
      -DLOGOS_PROTOCOL_ROOT=${protocolLib}
    ninja
    cd ..

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cmake --install build-qt-host
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Logos Qt host runtime — LogosAPI, provider base classes, Qt plugin glue";
    platforms = platforms.unix;
  };
}
