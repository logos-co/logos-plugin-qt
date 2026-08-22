# DOES THE EMITTED GLUE ACTUALLY COMPILE.
#
# Every other check in this repo greps the generator's output as TEXT. That is
# the right instrument for the by-name contracts -- a string the compiler never
# sees -- but it has a documented blind spot, recorded in
# tests/test-qt-host-generator.nix: the multi worker's capture list once omitted
# a local its body still named, so `concurrency: "multi"` on a module with a
# void method and no result method did not compile AT ALL, and every check here
# stayed green. It surfaced as a build failure in somebody else's repo.
#
# So: build a real Qt plugin out of the emitted glue, exactly as a module build
# does -- AUTOMOC over the plugin class, find_package(logos-qt-host), the
# include/core layout the runtime installs -- with the module-impl C ABI
# satisfied by a stub instead of a real cdylib. Nothing here executes; the claim
# is only that the text the generator writes is valid C++ against the headers
# this repo ships.
#
# --no-undefined is what makes the LINK meaningful. A MODULE library on ELF
# happily leaves undefined symbols for load time by default, which would let a
# call to a nonexistent C ABI entry point (or a mistyped one) link clean and
# fail at the user's dlopen -- the exact shape of the two prior ABI breaks.
{ pkgs, generator, qtHost, protocolSrc }:

pkgs.stdenv.mkDerivation {
  pname = "logos-qt-host-glue-compiles-test";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    generator
    pkgs.qt6.wrapQtAppsNoGuiHook
  ];

  buildInputs = [
    pkgs.qt6.qtbase
    pkgs.qt6.qtremoteobjects
    pkgs.boost
    pkgs.openssl
    pkgs.nlohmann_json
    # Propagates logos-protocol, so find_package(logos-protocol) inside
    # logos-qt-hostConfig.cmake resolves from CMAKE_PREFIX_PATH.
    qtHost
  ];

  dontUseCmakeConfigure = true;

  buildPhase = ''
    runHook preBuild
    mkdir -p work && cd work

    # A contract with BOTH shapes the glue special-cases (void and result), so
    # the multi branch emits both flags AND the caller document into one capture
    # list -- the combination that has broken before.
    cat > sample.lidl <<'EOF'
    module glue_probe {
      version "1.0.0"

      method ping() -> tstr
      method echoInt(v: int) -> int
      method doVoid() -> void
      method makeResult(ok: bool) -> result

      event tickEvent(v: tstr)
    }
    EOF

    logos-qt-host-generator --lidl sample.lidl --output-dir single
    logos-qt-host-generator --lidl sample.lidl --concurrency multi --output-dir multi

    # Q_PLUGIN_METADATA(IID ... FILE "metadata.json") -- moc resolves the file
    # relative to the header it is reading, so one copy per output dir.
    for d in single multi; do
      cat > $d/metadata.json <<'EOF'
    { "name": "glue_probe", "version": "1.0.0", "type": "core" }
    EOF
    done

    # The module-impl C ABI, stubbed. A real module's cdylib defines these; the
    # glue only ever knows the symbols. Declared from the protocol's own header
    # so a signature drift here is a compile error rather than a silent
    # mismatched definition.
    cat > abi_stub.cpp <<'EOF'
    #include "logos_module_impl.h"
    #include "logos_protocol.h"   // LOGOS_PROTOCOL_VERSION_STRING
    #include <cstdlib>
    #include <cstring>

    extern "C" {
    char* logos_module_dispatch(const char*, const char*) { return nullptr; }
    char* logos_module_get_methods(void) { return nullptr; }
    void logos_module_set_context(const char*, const char*, const char*) {}
    void logos_module_set_emit_callback(logos_module_emit_cb, void*) {}
    int logos_module_accept_token(const char*, const char*) { return 0; }
    int logos_module_grant_host_services(const char*) { return 0; }
    void logos_module_set_unload_done_callback(logos_module_unload_done_cb, void*) {}
    int logos_module_about_to_unload(void) { return 0; }
    void logos_module_set_call_caller(const char*) {}
    const char* logos_module_get_protocol_version(void) { return LOGOS_PROTOCOL_VERSION_STRING; }
    void logos_module_string_free(char* s) { std::free(s); }
    }
    EOF

    cat > CMakeLists.txt <<'EOF'
    cmake_minimum_required(VERSION 3.14)
    project(LogosGlueCompileProbe CXX)
    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_AUTOMOC ON)

    find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects)
    find_package(logos-qt-host REQUIRED)

    # include/core is where the runtime installs the legacy plugin interface
    # (PluginInterface / initLogos), and every module build puts it on the
    # include path the same way. interface.h then reaches LogosAPI as
    # "../cpp/logos_api.h", which is why include/cpp exists beside it.
    foreach(variant single multi)
      add_library(''${variant}_glue MODULE
        ''${CMAKE_CURRENT_SOURCE_DIR}/''${variant}/glue_probe_cdylib_glue.cpp
        ''${CMAKE_CURRENT_SOURCE_DIR}/''${variant}/glue_probe_cdylib_glue.h
        ''${CMAKE_CURRENT_SOURCE_DIR}/abi_stub.cpp)
      target_include_directories(''${variant}_glue PRIVATE
        ''${CMAKE_CURRENT_SOURCE_DIR}/''${variant}
        ''${LOGOS_QT_HOST_PREFIX}/include/core
        # The protocol SOURCE tree, not its installed prefix, and that is not a
        # shortcut -- it is what logos-module-builder does
        # (cmake/LogosModule.cmake, LOGOS_PROTOCOL_ROOT/cpp). It has to:
        # logos_async_dispatch.h, which every concurrency:"multi" glue includes,
        # is NOT in logos-protocol's install(FILES ... DESTINATION include)
        # list, so a multi module built against an installed prefix alone does
        # not compile. Mirrored here so this gate builds the configuration that
        # actually ships rather than one that cannot exist.
        ''${LOGOS_PROTOCOL_SRC}/cpp)
      target_link_libraries(''${variant}_glue PRIVATE
        logos-qt-host::logos_qt_host
        Qt6::Core Qt6::RemoteObjects)
      # See the header comment: without this a missing or mistyped C ABI entry
      # point links clean and dies at the user's dlopen.
      if(NOT APPLE)
        target_link_options(''${variant}_glue PRIVATE -Wl,--no-undefined)
      endif()
    endforeach()
    EOF

    cmake -S . -B build -GNinja \
      -DLOGOS_QT_HOST_PREFIX=${qtHost} \
      -DLOGOS_PROTOCOL_SRC=${protocolSrc}
    cmake --build build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # Both plugins exist, or the build silently produced nothing.
    for variant in single multi; do
      found=$(find build -name "*''${variant}_glue*" -type f | head -1)
      test -n "$found" || { echo "no artifact for the $variant branch"; exit 1; }
      echo "built: $found"
    done
    touch $out
    runHook postInstall
  '';

  dontFixup = true;
}
