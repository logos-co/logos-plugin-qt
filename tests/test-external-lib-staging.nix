# buildPlugin stages external libraries from the read-only store into lib/, then
# cmakeConfigurePhase's fixCmakeFiles rewrites every *.cmake there in place.
# Builds a plugin whose external library ships lib/cmake/<pkg>/, staged twice
# (two archives of one package, as logos-lidl is linked).
{ pkgs, buildPlugin }:

let
  stub = name: pkgs.runCommand "stub-${name}" { } "mkdir -p $out";

  # Only the installed layout matters; the vanilla plugin links none of it.
  extfixture = pkgs.runCommand "extfixture" { } ''
    mkdir -p $out/lib/cmake/extfixture $out/include/extfixture
    touch $out/lib/libextfixture.a $out/lib/libextfixture_c.a
    echo '#pragma once' > $out/include/extfixture/extfixture.hpp
    echo 'set(extfixture_FOUND TRUE)' > $out/lib/cmake/extfixture/extfixtureConfig.cmake
  '';

  # The generation step requires a non-empty umbrella; the SDK is not an input here.
  cppGeneratorStub = pkgs.writeShellScriptBin "logos-cpp-generator" ''
    while [ $# -gt 0 ]; do
      if [ "$1" = --output-dir ]; then out="$2"; fi
      shift
    done
    mkdir -p "$out"
    echo '// stub' > "$out/logos_sdk.h"
    echo '// stub' > "$out/logos_sdk.cpp"
  '';

in buildPlugin {
  inherit pkgs;
  src = ./vanilla-plugin;
  config = {
    name = "vanilla_test";
    version = "1.0.0";
    description = "external-lib staging fixture";
    interface = "legacy";
    type = "core";
    external_libraries = [ { name = "extfixture_c"; } { name = "extfixture"; } ];
  };
  logosModule = stub "logos-module";
  externalLibs = { extfixture = extfixture; extfixture_c = extfixture; };
  extraNativeBuildInputs = [ cppGeneratorStub ];
  # Runs after staging, before fixCmakeFiles.
  preConfigure = ''
    for f in extfixture/extfixture.hpp cmake/extfixture/extfixtureConfig.cmake; do
      test -f "lib/$f" || { echo "FAIL: lib/$f was not staged"; exit 1; }
    done
    if [ -n "$(find lib ! -perm -u+w -print -quit)" ]; then
      echo "FAIL: staged paths are read-only:"; find lib ! -perm -u+w; exit 1
    fi
  '';
}
