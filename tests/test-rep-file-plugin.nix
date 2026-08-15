# Integration test: build a replica factory plugin from a .rep file.
# Proves the repc pipeline + factory template instantiation produces a loadable plugin.
{ pkgs, backendCommon }:

let
  pluginSrc = ./rep-file-plugin;
  # The ONE copy of the templates, straight from this repo's cmake/. The
  # fixture is handed the same directory logos_module() is handed in a real
  # build, so this check now exercises the file every ui_qml module compiles —
  # not a private duplicate of it that could pass while the real one is broken.
  viewTemplates = ../cmake;
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

  # The templates are this repo's, and there is exactly one copy of them:
  # cmake/. LogosModule.cmake still belongs to logos-module-builder — only the
  # Qt-specific templates it instantiates are published from this side, because
  # logos-module-builder depends on this repo and not the reverse, so this is
  # the only directory both it and this fixture can read. See cmake/README.md.
  LOGOS_VIEW_TEMPLATE_DIR = "${viewTemplates}";

  buildPhase = ''
    runHook preBuild

    mkdir -p build
    cd build
    cmake .. -GNinja -DLOGOS_VIEW_TEMPLATE_DIR="$LOGOS_VIEW_TEMPLATE_DIR"
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

    # ── The IID, EXACTLY ────────────────────────────────────────────────
    # This used to be `strings | grep -q "logos.view.replica_factory"`, a
    # SUBSTRING match. It therefore passed unchanged when the plugin class's
    # Q_PLUGIN_METADATA was bumped to .../2.0 — the binary still contained
    # the substring, so the assertion said nothing about which IID the
    # plugin actually advertises.
    #
    # Assert the exact set instead: every replica_factory IID present in the
    # binary must be the one and only expected IID. A binary carrying both
    # /1.0 and /2.0 (the shape a bumped Q_PLUGIN_METADATA produces, since
    # Q_DECLARE_INTERFACE still emits the old one) fails here.
    EXPECTED_IID="logos.view.replica_factory/1.0"
    FOUND_IIDS=$(strings "$FACTORY" \
      | grep -oE 'logos\.view\.replica_factory/[0-9]+\.[0-9]+' \
      | sort -u)
    if [ -z "$FOUND_IIDS" ]; then
      echo "FAIL: no LogosViewReplicaFactory IID embedded in the binary"
      echo "      (Q_PLUGIN_METADATA missing, or moc did not run)"
      exit 1
    fi
    if [ "$FOUND_IIDS" != "$EXPECTED_IID" ]; then
      echo "FAIL: binary does not carry exactly one replica-factory IID."
      echo "  expected: $EXPECTED_IID"
      echo "  found:"
      echo "$FOUND_IIDS" | sed 's/^/    /'
      echo "  Two different IIDs means Q_PLUGIN_METADATA and"
      echo "  Q_DECLARE_INTERFACE disagree — the host reads the first and"
      echo "  casts on the second."
      exit 1
    fi
    echo "OK: binary advertises exactly $EXPECTED_IID"

    # ── Load it the way the host does ───────────────────────────────────
    # The exact-IID assertion above still cannot see whether the plugin
    # DECLARES the interface to moc. Deleting Q_INTERFACES leaves every
    # string in the binary untouched and only makes qobject_cast return
    # nullptr — the failure that shows up as a blank view. So the plugin is
    # actually loaded and cast, exactly as
    # logos-view-module-runtime's LogosQmlBridge::loadFactory does it.
    ./build/load_factory_check "$PWD/$FACTORY" "$EXPECTED_IID" "RepTestReplica"

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp build/rep_test_replica_factory.* $out/lib/ 2>/dev/null || true
    echo "REP_FILE replica factory test passed" > $out/result.txt
  '';
}
