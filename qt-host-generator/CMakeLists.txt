cmake_minimum_required(VERSION 3.16)
project(LogosQtHostGenerator VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Core)

# logos-lidl: the canonical, language-neutral LIDL frontend (lexer/parser/AST).
# Every Logos generator links the same one, so the parsed surface cannot skew
# between them. Nothing else is needed here — the single helper this backend
# borrowed from logos-cpp-sdk's shared frontend is inlined in
# lidl_emit_common.h, which is what keeps that SDK out of this repo's inputs.
find_package(logos-lidl REQUIRED)

add_executable(logos-qt-host-generator
    main.cpp
    lidl_gen_cdylib_glue.cpp
)

target_include_directories(logos-qt-host-generator PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(logos-qt-host-generator PRIVATE Qt6::Core logos-lidl::logos_lidl)

install(TARGETS logos-qt-host-generator RUNTIME DESTINATION bin)
