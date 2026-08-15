# Qt-specific utilities for building Logos plugins
#
# This module only knows about Qt. It does NOT reference logos-cpp-sdk.
# The logosModule dependency (interface.h) is the only Logos-specific dep,
# and it's passed in by the caller.
{ lib }:

# `rec` so getPluginFilename can reuse getLibExtension instead of repeating the
# platform branch -- the duplication is exactly what let them disagree about
# Windows.
rec {
  # Supported target systems. "x86_64-windows" is a pseudo-system: a cross
  # derivation's `system` attribute is its BUILD platform.
  systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" "x86_64-windows" ];

  # Determine library extension based on platform
  getLibExtension = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else "so";

  # Get the plugin filename for a module.
  #
  # Reuses getLibExtension rather than repeating the branch: this used to have
  # its own darwin/else test and returned ".so" on Windows, disagreeing with
  # getLibExtension two lines above, which already answered "dll".
  getPluginFilename = pkgs: name:
    "${name}_plugin.${getLibExtension pkgs}";

  # Qt-specific native build inputs
  commonNativeBuildInputs = pkgs: [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    # Mandatory guard, not an optimisation: wrapQtAppsNoGuiHook does not even
    # EVALUATE for a mingw host, and would be inert anyway -- wrap-qt-apps-hook
    # skips anything that is not ELF or Mach-O, so a PE is never wrapped.
    # qtbase's own setup hook then hard-errors in qtPreHook unless
    # dontWrapQtApps is set, which is why both halves are needed.
  ] ++ pkgs.lib.optional (!pkgs.stdenv.hostPlatform.isWindows)
    pkgs.qt6.wrapQtAppsNoGuiHook ++ [
  ];

  # Qt-specific build inputs
  commonBuildInputs = pkgs: [
    pkgs.qt6.qtbase
    pkgs.qt6.qtremoteobjects
  ];

  # The ONE copy of the LogosView*.in templates that logos_module(REP_FILE ...)
  # instantiates. See ../cmake/README.md for why they are owned here rather
  # than next to LogosModule.cmake: logos-module-builder depends on this repo
  # and not the reverse, so this is the only directory both consumers of the
  # templates — that repo's LogosModule.cmake, and this repo's
  # tests/rep-file-plugin fixture — can read from.
  viewTemplateDir = ../cmake;

  # CMake flags for Qt plugin builds.
  # Only includes logosModule (for interface.h).
  # SDK flags are added by the builder layer, not here.
  commonCmakeFlags = { logosModule }: [
    "-GNinja"
    "-DLOGOS_MODULE_ROOT=${logosModule}"
    "-DLOGOS_VIEW_TEMPLATE_DIR=${viewTemplateDir}"
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
