# Builds logos-qt-host — the Qt HOST RUNTIME a Logos Qt plugin links against:
# LogosAPI (the object handed to initLogos), LogosAPIProvider (the transport
# hosts, ModuleProxy/handshake publication and token-validator injection),
# LogosProviderBase (the base the generated <name>_cdylib_glue.cpp derives from;
# the LOGOS_PROVIDER/LOGOS_METHOD macros beside it are vestigial — the
# --provider-header scanner that read them is gone), and the legacy QMetaObject
# adapter. A static library plus its headers and CMake package config, so a
# plugin build can `find_package(logos-qt-host)`.
#
# Builds for the x86_64-windows cross target too. The two differences that
# target needs are gated on `isWindows` and interpolate to nothing otherwise, so
# the native derivation is bit-identical to the one that predates Windows
# support — the whole dependency chain below this package (logos-liblogos,
# logos-basecamp, every module) keeps its store paths.
{ pkgs, src, protocolLib }:

let
  inherit (pkgs) lib;
  # The HOST platform is the target under cross, which is what decides both
  # gates below. Tested as `isWindows` and not as "not unix": under mingw cross
  # isDarwin and isAarch64 are both false and x86_64 still matches, so a
  # Windows-last platform chain silently takes the Linux branch.
  isWindows = pkgs.stdenv.hostPlatform.isWindows;
in

pkgs.stdenv.mkDerivation ({
  pname = "logos-qt-host";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
  ]
  # The Qt wrapper hooks cannot evaluate for a mingw host, and there would be
  # nothing for them to wrap: this package installs an archive and headers, no
  # executable. qtbase's own setup hook still aborts in qtPreHook unless one of
  # them ran, so the Windows leg satisfies it with dontWrapQtApps below.
  ++ lib.optional (!isWindows) pkgs.qt6.wrapQtAppsNoGuiHook;

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

  # A hand-rolled cmake line that omits $cmakeFlags is the classic cross
  # failure here: mkDerivation puts -DCMAKE_SYSTEM_NAME, -DCMAKE_SYSTEM_PROCESSOR
  # and the host-system triple into that variable for a cross build (and leaves
  # it empty natively), so dropping it means CMake never learns it is
  # cross-compiling and the error surfaces nowhere near the cause.
  buildPhase = ''
    runHook preBuild

    mkdir -p build-qt-host
    cd build-qt-host
    cmake ../cpp -GNinja -DCMAKE_INSTALL_PREFIX=$out \
      -DLOGOS_PROTOCOL_ROOT=${protocolLib}${lib.optionalString isWindows " $cmakeFlags"}
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
    platforms = platforms.unix ++ platforms.windows;
  };
}

// lib.optionalAttrs isWindows {
  dontWrapQtApps = true;

  # The Qt half of the cross flags. CMAKE_AUTOMOC is on and RemoteObjects is a
  # required component, so the build needs moc and repc — which must RUN on the
  # builder and therefore come from the BUILD platform's Qt, not from the
  # target's PEs. logos-nix's Windows overlay defines this attribute; `or []`
  # keeps the file evaluable against a plain nixpkgs.
  cmakeFlags = pkgs.logosQtCrossCmakeFlags or [ ];
})
