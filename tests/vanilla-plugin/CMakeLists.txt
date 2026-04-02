cmake_minimum_required(VERSION 3.14)
project(VanillaTestPlugin LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core)

# Copy metadata.json to build dir so Q_PLUGIN_METADATA can find it
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/metadata.json ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

add_library(vanilla_test_plugin SHARED
    vanilla_test_plugin.h
    interface.h
)

set_target_properties(vanilla_test_plugin PROPERTIES
    PREFIX ""
    OUTPUT_NAME "vanilla_test_plugin"
)

target_include_directories(vanilla_test_plugin PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
)

target_link_libraries(vanilla_test_plugin PRIVATE Qt6::Core)
