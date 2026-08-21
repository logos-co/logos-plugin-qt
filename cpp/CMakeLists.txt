cmake_minimum_required(VERSION 3.14)
project(LogosQtHost)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(QT NAMES Qt6 Qt5 REQUIRED COMPONENTS Core RemoteObjects)
find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Core RemoteObjects)

# The protocol layer — transports, consumer core, token manager, the abstract
# LogosProviderObject interface and the lp_* C ABI. This library is the Qt
# HOST runtime on top of it: the object a Qt plugin is handed (LogosAPI), the
# provider side that publishes it (LogosAPIProvider), the provider base the
# generated <name>_cdylib_glue.cpp derives from (LogosProviderBase), and the
# QtProviderObject adapter that wraps a legacy Q_INVOKABLE QObject plugin.
# (Hand-written provider classes — `interface: "provider"` — no longer exist.)
if(NOT DEFINED LOGOS_PROTOCOL_ROOT)
    if(DEFINED ENV{LOGOS_PROTOCOL_ROOT})
        set(LOGOS_PROTOCOL_ROOT "$ENV{LOGOS_PROTOCOL_ROOT}")
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../logos-protocol/cpp/logos_protocol.h")
        set(LOGOS_PROTOCOL_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../logos-protocol")
    endif()
endif()
if(EXISTS "${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol")
    # Installed protocol package → proper layered link.
    find_package(logos-protocol REQUIRED
        PATHS "${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol" NO_DEFAULT_PATH)
    set(LP_TARGET logos-protocol::logos_protocol)
    set(LP_SHARED_TARGET logos-protocol::logos_protocol_shared)
elseif(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/CMakeLists.txt")
    # Source checkout → build it as a subproject (dev convenience).
    add_subdirectory("${LOGOS_PROTOCOL_ROOT}/cpp"
                     "${CMAKE_BINARY_DIR}/logos-protocol-build")
    set(LP_TARGET logos_protocol)
    set(LP_SHARED_TARGET logos_protocol_shared)
else()
    message(FATAL_ERROR "logos-protocol not found. Set LOGOS_PROTOCOL_ROOT to an "
                        "installed logos-protocol prefix or a source checkout.")
endif()

set(QT_HOST_SOURCES
    logos_api.cpp
    logos_api.h
    logos_api_provider.cpp
    logos_api_provider.h
    logos_provider_object.cpp
    logos_provider_object.h
    qt_provider_object.cpp
    qt_provider_object.h
    # Not part of the host runtime proper, but qt_provider_object.cpp's
    # QMetaObject dispatch decodes every incoming argument through
    # logos::qtArgDecode. Carrying the legacy adapter means carrying this.
    logos_qt_arg_decode.cpp
    logos_qt_arg_decode.h
)

add_library(logos_qt_host STATIC ${QT_HOST_SOURCES})

target_link_libraries(logos_qt_host PUBLIC
    ${LP_TARGET}
    Qt${QT_VERSION_MAJOR}::Core
    Qt${QT_VERSION_MAJOR}::RemoteObjects
)

target_include_directories(logos_qt_host PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

set_target_properties(logos_qt_host PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

install(TARGETS logos_qt_host
    EXPORT logos-qt-hostTargets
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
    INCLUDES DESTINATION include
)

# ---------------------------------------------------------------------------
# logos_qt_host_shared — the Qt host runtime as a SHARED library.
#
# WHY. The types in here (LogosAPI) and in logos-protocol (TokenManager,
# LogosAPIClient, the per-identity StoreRegistry) must exist EXACTLY ONCE per
# process. Every image that links a static archive gets its own copy of every
# function-local static inside it, so the host writes a capability token into
# one store and another in-process image reads an empty one -- with no build
# diagnostic. Linking ONE shared library is what replaces the whole-archive +
# generated-.def scheme in which liblogos_core absorbed both archives and
# re-exported them.
#
# THE STATIC ARCHIVE STAYS, and not transitionally. Module plugins and ui_qml
# backends run in their OWN processes, so their own copy is the CORRECT
# per-process singleton; staying static also keeps a .lgx self-contained (a .lgx
# records an empty nix closure, so a shared library would not travel with it).
# In-process images link the shared one; out-of-process images link the archive.
if(NOT TARGET ${LP_SHARED_TARGET})
    # Hard failure rather than "skip the shared target", because every failure
    # mode here is silent: a consumer that wanted the shared runtime would fall
    # back to the archive, link cleanly, and reintroduce the duplicate singleton
    # at runtime.
    message(FATAL_ERROR
        "${LP_SHARED_TARGET} is not a target, so logos_qt_host_shared cannot be "
        "built. It requires a logos-protocol that EXPORTS its shared library "
        "(logos-protocol#65). Check that LOGOS_PROTOCOL_ROOT points at a "
        "protocol build new enough to provide it.")
endif()

add_library(logos_qt_host_shared SHARED ${QT_HOST_SOURCES})

# PUBLIC-links the SHARED protocol, NOT ${LP_TARGET}.
#
# This single line is the whole correctness of this target. Linking the static
# archive here would embed a second copy of TokenManager INSIDE
# liblogos_qt_host.{so,dylib,dll} -- the exact bug this migration removes, one
# layer down, and invisible to a consumer-side symbol gate because the duplicate
# would live in a library the gate treats as a provider.
target_link_libraries(logos_qt_host_shared PUBLIC
    ${LP_SHARED_TARGET}
    Qt${QT_VERSION_MAJOR}::Core
    Qt${QT_VERSION_MAJOR}::RemoteObjects
)

# LogosAPI is EXPORTED from this library (LOGOS_QT_HOST_API), while TokenManager
# and LogosAPIClient -- owned by logos-protocol -- must be IMPORTED from
# liblogos_protocol. That is why they are two macros and not one: a single macro
# cannot say "export" and "import" in the same translation unit.
#
# LOGOS_QT_HOST_BUILDING_SHARED is tested FIRST in logos_shared_api.h, so
# LogosAPI still resolves to dllexport here even with LOGOS_SHARED_USE_DLL set.
target_compile_definitions(logos_qt_host_shared PRIVATE LOGOS_QT_HOST_BUILDING_SHARED)
if(WIN32)
    target_compile_definitions(logos_qt_host_shared PRIVATE LOGOS_SHARED_USE_DLL)
endif()

target_include_directories(logos_qt_host_shared PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>
)

# Same basename as the archive; the LIBRARY install lands it in $out/lib beside
# liblogos_qt_host.a.
set_target_properties(logos_qt_host_shared PROPERTIES
    OUTPUT_NAME logos_qt_host
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# ARCHIVE DESTINATION is load-bearing on Windows and inert elsewhere: a shared
# library's IMPORT library (.dll.a) is the ARCHIVE artifact while the DLL is
# RUNTIME, so omitting it installs no import library and a consumer gets an
# imported target whose IMPORTED_IMPLIB does not exist. Invisible on ELF/Mach-O.
install(TARGETS logos_qt_host_shared
    EXPORT logos-qt-hostTargets
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
    INCLUDES DESTINATION include
)

install(EXPORT logos-qt-hostTargets
    FILE logos-qt-hostTargets.cmake
    NAMESPACE logos-qt-host::
    DESTINATION lib/cmake/logos-qt-host
)

include(CMakePackageConfigHelpers)
configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/logos-qt-hostConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/logos-qt-hostConfig.cmake"
    INSTALL_DESTINATION lib/cmake/logos-qt-host
)
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/logos-qt-hostConfigVersion.cmake"
    VERSION 0.1.0
    COMPATIBILITY SameMajorVersion
)
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/logos-qt-hostConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/logos-qt-hostConfigVersion.cmake"
    DESTINATION lib/cmake/logos-qt-host
)

set(QT_HOST_PUBLIC_HEADERS
    logos_api.h
    logos_api_provider.h
    logos_provider_object.h
    qt_provider_object.h
    logos_qt_arg_decode.h
)

# Headers keep their historical names so existing `#include "logos_api.h"`
# lines resolve unchanged once consumers add this prefix's include dir.
install(FILES ${QT_HOST_PUBLIC_HEADERS} DESTINATION include)

# Legacy Qt plugin interface (PluginInterface / initLogos(LogosAPI*)) —
# installed at include/core/ exactly where logos-cpp-sdk, and then
# logos-qt-sdk, shipped it. Consumers put include/core on the include path.
install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/../core/interface.h
    DESTINATION include/core
)

# interface.h reaches LogosAPI as `#include "../cpp/logos_api.h"`, i.e. it
# resolves RELATIVE TO ITSELF, so from include/core/ it needs include/cpp/ to
# exist. logos-qt-sdk satisfied that by shipping a second, source-export copy
# of the headers from a separate derivation; here the same mirror is part of
# the one install, which keeps the prefix self-consistent on its own. The flat
# copy above stays the one consumers include by name — this exists only so the
# relative shape inside interface.h keeps resolving, unchanged.
install(FILES ${QT_HOST_PUBLIC_HEADERS} DESTINATION include/cpp)
