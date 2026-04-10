cmake_minimum_required(VERSION 3.14)
project(RepFileTestPlugin LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core RemoteObjects Qml)

# ── Locate templates (injected by the nix test harness into cmake/) ────────
set(TEMPLATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

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
