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
elseif(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/CMakeLists.txt")
    # Source checkout → build it as a subproject (dev convenience).
    add_subdirectory("${LOGOS_PROTOCOL_ROOT}/cpp"
                     "${CMAKE_BINARY_DIR}/logos-protocol-build")
    set(LP_TARGET logos_protocol)
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
