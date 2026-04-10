# Integration test: build a replica factory plugin from a .rep file.
# Proves the repc pipeline + factory template instantiation produces a loadable plugin.
{ pkgs, backendCommon }:

let
  pluginSrc = ./rep-file-plugin;
in
pkgs.stdenv.mkDerivation {
  pname = "logos-plugin-qt-rep-file-test";
  version = "0.0.1";

  src = pluginSrc;

  nativeBuildInputs = backendCommon.commonNativeBuildInputs pkgs;
  buildInputs = backendCommon.commonBuildInputs pkgs ++ [
    pkgs.qt6.qtdeclarative   # provides Qt6::Qml
  ];

  dontUseCmakeConfigure = true;

  # The CMakeLists.txt expects templates in cmake/ under the source root.
  postUnpack = ''
    mkdir -p $sourceRoot/cmake
    cp ${../cmake/LogosViewReplicaFactory.h.in} $sourceRoot/cmake/LogosViewReplicaFactory.h.in
    cp ${../cmake/LogosViewReplicaFactory.cpp.in} $sourceRoot/cmake/LogosViewReplicaFactory.cpp.in
  '';

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

    # Verify the replica factory plugin was created
    FACTORY="build/rep_test_replica_factory.so"
    if [ ! -f "$FACTORY" ]; then
      FACTORY="build/rep_test_replica_factory.dylib"
    fi

    if [ ! -f "$FACTORY" ]; then
      echo "FAIL: Replica factory binary not found"
      ls -la build/
      exit 1
    fi

    echo "OK: Replica factory binary exists at $FACTORY"
    echo "Size: $(stat -c%s "$FACTORY" 2>/dev/null || stat -f%z "$FACTORY") bytes"

    # Verify it's a valid shared library
    file "$FACTORY" | grep -q "shared object\|dynamically linked\|Mach-O" || {
      echo "FAIL: Replica factory is not a valid shared library"
      file "$FACTORY"
      exit 1
    }
    echo "OK: Replica factory is a valid shared library"

    # Verify the factory class metadata is embedded (from Q_PLUGIN_METADATA)
    if strings "$FACTORY" | grep -q "replica_factory"; then
      echo "OK: Replica factory metadata found in binary"
    else
      echo "FAIL: Replica factory metadata not found in binary"
      exit 1
    fi

    # Verify the IID is embedded (LogosViewReplicaFactory interface)
    if strings "$FACTORY" | grep -q "logos.view.replica_factory"; then
      echo "OK: LogosViewReplicaFactory IID found in binary"
    else
      echo "FAIL: LogosViewReplicaFactory IID not found in binary"
      exit 1
    fi

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp build/rep_test_replica_factory.* $out/lib/ 2>/dev/null || true
    echo "REP_FILE replica factory test passed" > $out/result.txt
  '';
}
