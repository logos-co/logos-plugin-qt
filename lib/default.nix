# Logos Qt Plugin Backend
#
# Builds Logos modules as Qt 6 plugins. Encapsulates Qt-specific build logic:
# CMake configuration, Qt dependencies, plugin compilation, and macOS fixups.
#
# This backend does NOT know about logos-cpp-sdk. It only knows about:
# - Qt (cmake, ninja, qtbase, qtremoteobjects)
# - logosModule (interface.h — the plugin interface contract)
#
# The logos-cpp-sdk (generator, SDK lib, headers) is added by the caller
# (logos-module-builder) via extraNativeBuildInputs / extraBuildInputs / env.
#
{ nixpkgs, lib, backendRoot }:

let
  common = import ./common.nix { inherit lib; };
  mkBuildPlugin = import ./buildPlugin.nix { inherit lib common; };
  mkBuildHeaders = import ./buildHeaders.nix { inherit lib common; };

in {
  # Build a Qt plugin from sources.
  # logosModule provides interface.h. Everything else (SDK, generator) comes
  # via extraNativeBuildInputs/extraBuildInputs passed by the caller.
  # Returns: derivation with lib/{name}_plugin.so
  buildPlugin = {
    pkgs,
    src,
    config,
    logosModule,
    moduleDeps ? {},
    interfaceDeps ? [],
    staticDeps ? [],
    externalLibs ? {},
    extraNativeBuildInputs ? [],
    extraBuildInputs ? [],
    extraCmakeFlags ? [],
    extraEnv ? {},
    preConfigure ? "",
    postInstall ? "",
  }:
  let
    commonArgs = {
      pname = "logos-${config.name}-module";
      version = config.version;
      nativeBuildInputs = common.commonNativeBuildInputs pkgs ++ extraNativeBuildInputs;
      buildInputs = common.commonBuildInputs pkgs ++ extraBuildInputs;
      cmakeFlags = common.commonCmakeFlags { inherit logosModule; } ++ extraCmakeFlags;
      env = {
        LOGOS_MODULE_ROOT = "${logosModule}";
        LOGOS_MODULE_BUILDER_ROOT = "${backendRoot}";
      } // extraEnv;
      meta = with lib; {
        description = config.description;
        platforms = platforms.unix ++ platforms.windows;
      };
    };
  in mkBuildPlugin.build {
    inherit pkgs src config commonArgs moduleDeps interfaceDeps staticDeps externalLibs preConfigure postInstall;
    logosSdk = null;  # not used by buildPlugin.nix directly, kept for compat
  };

  # Generate-only: run the same code generators as buildPlugin but emit a
  # ready-to-build source tree (module source + generated_code/) instead of a
  # compiled plugin. Same args as buildPlugin so the caller (logos-module-builder)
  # can pass the identical inputs and get a tree that matches a real build.
  # Returns: derivation whose $out is the snapshotted source tree.
  generate = {
    pkgs,
    src,
    config,
    logosModule,
    moduleDeps ? {},
    interfaceDeps ? [],
    staticDeps ? [],
    externalLibs ? {},
    extraNativeBuildInputs ? [],
    extraBuildInputs ? [],
    extraCmakeFlags ? [],
    extraEnv ? {},
    preConfigure ? "",
    postInstall ? "",
  }:
  let
    commonArgs = {
      pname = "logos-${config.name}-module";
      version = config.version;
      nativeBuildInputs = common.commonNativeBuildInputs pkgs ++ extraNativeBuildInputs;
      buildInputs = common.commonBuildInputs pkgs ++ extraBuildInputs;
      cmakeFlags = common.commonCmakeFlags { inherit logosModule; } ++ extraCmakeFlags;
      env = {
        LOGOS_MODULE_ROOT = "${logosModule}";
        LOGOS_MODULE_BUILDER_ROOT = "${backendRoot}";
      } // extraEnv;
      meta = with lib; {
        description = config.description;
        platforms = platforms.unix ++ platforms.windows;
      };
    };
  in mkBuildPlugin.generate {
    inherit pkgs src config commonArgs moduleDeps interfaceDeps staticDeps externalLibs preConfigure postInstall;
    logosSdk = null;  # not used by buildPlugin.nix directly, kept for compat
  };

  # Generate SDK headers from a compiled plugin.
  # `apiStyle` picks which type surface the generated `<Module>` client
  # wrapper exposes ("qt" or "lp"); each module is built once per
  # style so downstream consumers can pick the variant matching their
  # own --api-style without re-running the codegen. Default is "qt"
  # — historically the only option, kept for backward compat.
  # Returns: derivation with include/*.h
  buildHeaders = {
    pkgs,
    src,
    config,
    pluginLib,
    logosSdk,
    apiStyle ? "qt",
    # Path to this module's LIDL contract (or null). This is the PRIMARY input
    # for the qt surface — a module that publishes a contract has its wrapper
    # generated from it and is never introspected. Only a module with no
    # contract falls back to reading its compiled plugin.
    contractLidl ? null,
    # logos-qt-generator (build-platform). Required to take the contract-driven
    # qt path; null demotes it to the legacy emitter, loudly.
    qtGenerator ? null,
  }:
  let
    commonArgs = {
      pname = "logos-${config.name}-module";
      version = config.version;
      meta = with lib; {
        description = config.description;
        platforms = platforms.unix ++ platforms.windows;
      };
    };
  in mkBuildHeaders.build {
    inherit pkgs src config commonArgs logosSdk apiStyle contractLidl qtGenerator;
    lib = pluginLib;
  };

  # Dev shell dependencies — Qt only.
  # SDK env vars are added by the caller (logos-module-builder).
  devShellInputs = pkgs: {
    logosModule ? null,
  }: {
    nativeBuildInputs = common.commonNativeBuildInputs pkgs;
    buildInputs = common.commonBuildInputs pkgs;
    shellHook = ''
      ${if logosModule != null then ''export LOGOS_MODULE_ROOT="${logosModule}"'' else ""}
      export LOGOS_MODULE_BUILDER_ROOT="${backendRoot}"
    '';
  };

  # Backend metadata
  name = "qt";
  version = "0.1.0";
  inherit common;
}
