# Integration test: build a vanilla Qt plugin using only Qt deps (no logos-cpp-sdk).
# Proves the backend can compile a .so without any Logos SDK dependency.
{ pkgs, backendCommon }:

let
  pluginSrc = ./vanilla-plugin;
in
pkgs.stdenv.mkDerivation {
  pname = "logos-plugin-qt-vanilla-test";
  version = "0.0.1";

  src = pluginSrc;

  nativeBuildInputs = backendCommon.commonNativeBuildInputs pkgs;
  buildInputs = backendCommon.commonBuildInputs pkgs;

  dontUseCmakeConfigure = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p build
    cd build
    cmake .. -GNinja
    ninja
    cd ..

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    # Verify the plugin .so was created
    PLUGIN="build/vanilla_test_plugin.so"
    if [ ! -f "$PLUGIN" ]; then
      PLUGIN="build/vanilla_test_plugin.dylib"
    fi

    if [ ! -f "$PLUGIN" ]; then
      echo "FAIL: Plugin binary not found"
      ls -la build/
      exit 1
    fi

    echo "OK: Plugin binary exists at $PLUGIN"
    echo "Size: $(stat -c%s "$PLUGIN" 2>/dev/null || stat -f%z "$PLUGIN") bytes"

    # Verify it's a valid shared library
    file "$PLUGIN" | grep -q "shared object\|dynamically linked\|Mach-O" || {
      echo "FAIL: Plugin is not a valid shared library"
      file "$PLUGIN"
      exit 1
    }
    echo "OK: Plugin is a valid shared library"

    # Verify Qt plugin metadata is embedded
    if strings "$PLUGIN" | grep -q "vanilla_test"; then
      echo "OK: Qt plugin metadata found in binary"
    else
      echo "FAIL: Qt plugin metadata not found in binary"
      exit 1
    fi

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp build/vanilla_test_plugin.* $out/lib/ 2>/dev/null || true
    echo "Vanilla Qt plugin test passed" > $out/result.txt
  '';
}
