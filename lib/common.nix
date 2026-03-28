# Qt-specific utilities for building Logos plugins
{ lib }:

{
  # Supported target systems
  systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

  # Determine library extension based on platform
  getLibExtension = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else "so";

  # Get the plugin filename for a module
  getPluginFilename = pkgs: name:
    "${name}_plugin.${if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so"}";

  # Qt-specific native build inputs
  commonNativeBuildInputs = pkgs: [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsNoGuiHook
  ];

  # Qt-specific build inputs
  commonBuildInputs = pkgs: [
    pkgs.qt6.qtbase
    pkgs.qt6.qtremoteobjects
  ];

  # CMake flags for Qt plugin builds
  commonCmakeFlags = { logosSdk, logosModule }: [
    "-GNinja"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_MODULE_ROOT=${logosModule}"
  ];

  # Platform-specific post-build commands for library path fixing
  fixLibraryPaths = pkgs: libName: ''
    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      # Fix install name on macOS
      if [ -f "$out/lib/${libName}.dylib" ]; then
        ${pkgs.darwin.cctools}/bin/install_name_tool -id "@rpath/${libName}.dylib" "$out/lib/${libName}.dylib"
      fi
    ''}
  '';
}
