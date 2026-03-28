# Logos Qt Plugin Backend
#
# This module exports the backend interface that logos-module-builder uses
# to build Qt 6 plugins. It encapsulates all Qt-specific build logic:
# CMake configuration, Qt dependencies, code generation, and header generation.
#
# Backend interface:
#   buildPlugin   — compile sources + metadata → Qt plugin .so/.dylib
#   buildHeaders  — introspect compiled plugin → SDK headers for consumers
#   devShellInputs — Qt-specific dev shell dependencies
#   common        — Qt-specific utilities (deps, cmake flags, platform helpers)
#
{ nixpkgs, logos-cpp-sdk, logos-module, lib, backendRoot }:

let
  common = import ./common.nix { inherit lib; };
  mkBuildPlugin = import ./buildPlugin.nix { inherit lib common; };
  mkBuildHeaders = import ./buildHeaders.nix { inherit lib common; };

in {
  # Build a Qt plugin from sources.
  # Returns: derivation with lib/{name}_plugin.so and include/ (general SDK headers)
  buildPlugin = {
    pkgs,
    src,
    config,
    moduleDeps ? {},
    externalLibs ? {},
    extraNativeBuildInputs ? [],
    extraBuildInputs ? [],
    preConfigure ? "",
    postInstall ? "",
  }:
  let
    logosSdk = logos-cpp-sdk.packages.${pkgs.system}.default;
    logosModule = logos-module.packages.${pkgs.system}.default;
    commonArgs = {
      pname = "logos-${config.name}-module";
      version = config.version;
      nativeBuildInputs = common.commonNativeBuildInputs pkgs ++ [ logosSdk ] ++ extraNativeBuildInputs;
      buildInputs = common.commonBuildInputs pkgs ++ extraBuildInputs;
      cmakeFlags = common.commonCmakeFlags { inherit logosSdk logosModule; };
      env = {
        LOGOS_CPP_SDK_ROOT = "${logosSdk}";
        LOGOS_MODULE_ROOT = "${logosModule}";
        # Keep LOGOS_MODULE_BUILDER_ROOT for backward compatibility with existing CMakeLists.txt
        LOGOS_MODULE_BUILDER_ROOT = "${backendRoot}";
      };
      meta = with lib; {
        description = config.description;
        platforms = platforms.unix;
      };
    };
  in mkBuildPlugin.build {
    inherit pkgs src config commonArgs logosSdk moduleDeps externalLibs preConfigure postInstall;
  };

  # Generate SDK headers from a compiled plugin.
  # Returns: derivation with include/*.h (module-specific API headers for consumers)
  buildHeaders = {
    pkgs,
    src,
    config,
    pluginLib,
  }:
  let
    logosSdk = logos-cpp-sdk.packages.${pkgs.system}.default;
    commonArgs = {
      pname = "logos-${config.name}-module";
      version = config.version;
      meta = with lib; {
        description = config.description;
        platforms = platforms.unix;
      };
    };
  in mkBuildHeaders.build {
    inherit pkgs src config commonArgs logosSdk;
    lib = pluginLib;
  };

  # Dev shell dependencies for modules using this backend.
  # Returns: { nativeBuildInputs, buildInputs, shellHook }
  devShellInputs = pkgs:
  let
    logosSdk = logos-cpp-sdk.packages.${pkgs.system}.default;
    logosModule = logos-module.packages.${pkgs.system}.default;
  in {
    nativeBuildInputs = common.commonNativeBuildInputs pkgs;
    buildInputs = common.commonBuildInputs pkgs;
    shellHook = ''
      export LOGOS_CPP_SDK_ROOT="${logosSdk}"
      export LOGOS_MODULE_ROOT="${logosModule}"
      export LOGOS_MODULE_BUILDER_ROOT="${backendRoot}"
    '';
  };

  # Backend metadata
  name = "qt";
  version = "0.1.0";
  inherit common;
}
