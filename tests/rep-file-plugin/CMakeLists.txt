cmake_minimum_required(VERSION 3.14)
project(RepFileTestPlugin LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects Qml)

# ── Locate templates ──────────────────────────────────────────────────────
# The fixture does NOT carry its own copy. It used to: the templates were
# moved in here when this repo's duplicate LogosModule.cmake was deleted, and
# they then sat byte-identical to logos-module-builder's with nothing comparing
# them. They are owned by this repo now (../../cmake) and the harness passes
# that directory in, the same way logos_module() receives it in a real build.
if(NOT LOGOS_VIEW_TEMPLATE_DIR AND DEFINED ENV{LOGOS_VIEW_TEMPLATE_DIR})
    set(LOGOS_VIEW_TEMPLATE_DIR "$ENV{LOGOS_VIEW_TEMPLATE_DIR}")
endif()
if(NOT LOGOS_VIEW_TEMPLATE_DIR)
    message(FATAL_ERROR
        "rep-file-plugin: LOGOS_VIEW_TEMPLATE_DIR is not set. Pass the "
        "repository's cmake/ directory; this fixture has no copy to fall "
        "back to, deliberately.")
endif()
set(TEMPLATE_DIR "${LOGOS_VIEW_TEMPLATE_DIR}")

# ── .rep file under test ──────────────────────────────────────────────────
set(REP_FILE "${CMAKE_CURRENT_SOURCE_DIR}/rep_test.rep")

# Parse class name from the .rep (mirrors LogosModule.cmake logic)
file(READ "${REP_FILE}" _REP_CONTENTS)
string(REGEX MATCH "class[ \t]+([A-Za-z_][A-Za-z0-9_]*)" _ "${_REP_CONTENTS}")
set(LOGOS_REP_CLASS "${CMAKE_MATCH_1}")    # RepTest
get_filename_component(LOGOS_REP_BASE "${REP_FILE}" NAME_WE)  # rep_test
set(LOGOS_FACTORY_CLASS "${LOGOS_REP_CLASS}ReplicaFactoryPlugin")
set(LOGOS_QML_URI "Logos.${LOGOS_REP_CLASS}")
set(LOGOS_QML_TYPE_NAME "${LOGOS_REP_CLASS}")

# ── Generate factory sources from templates ───────────────────────────────
set(GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/replica_factory_gen")
file(MAKE_DIRECTORY "${GEN_DIR}")
configure_file("${TEMPLATE_DIR}/LogosViewReplicaFactory.h.in"
               "${GEN_DIR}/LogosViewReplicaFactory.h" @ONLY)
configure_file("${TEMPLATE_DIR}/LogosViewReplicaFactory.cpp.in"
               "${GEN_DIR}/LogosViewReplicaFactory.cpp" @ONLY)

# ── Build the replica factory plugin ──────────────────────────────────────
add_library(rep_test_replica_factory SHARED
    "${GEN_DIR}/LogosViewReplicaFactory.h"
    "${GEN_DIR}/LogosViewReplicaFactory.cpp"
)

set_target_properties(rep_test_replica_factory PROPERTIES
    AUTOMOC ON
    PREFIX ""
    OUTPUT_NAME "rep_test_replica_factory"
)

target_include_directories(rep_test_replica_factory PRIVATE
    "${GEN_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}"
)

qt6_add_repc_replicas(rep_test_replica_factory "${REP_FILE}")

target_link_libraries(rep_test_replica_factory PRIVATE
    Qt6::Core
    Qt6::RemoteObjects
    Qt6::Qml
)

# ── Loader check ──────────────────────────────────────────────────────────
# Loads the plugin above the way logos-view-module-runtime does and asserts
# the exact IID plus a successful qobject_cast. `strings | grep` cannot see
# either: it matched "logos.view.replica_factory" as a SUBSTRING, so an IID
# bumped to /2.0 passed, and a deleted Q_INTERFACES (which leaves the IID
# untouched and only breaks the cast) passed too.
#
# AUTOMOC is deliberately OFF here. This target includes the generated
# LogosViewReplicaFactory.h purely for the interface declaration and the
# Q_DECLARE_INTERFACE that gives qobject_cast its IID; it must NOT moc the
# concrete plugin class that header also declares, or the checker would
# export a second copy of the plugin metadata.
add_executable(load_factory_check
    "${CMAKE_CURRENT_SOURCE_DIR}/load_factory_check.cpp"
)

set_target_properties(load_factory_check PROPERTIES AUTOMOC OFF)

target_include_directories(load_factory_check PRIVATE "${GEN_DIR}")

target_link_libraries(load_factory_check PRIVATE Qt6::Core)
