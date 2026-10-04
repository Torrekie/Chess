cmake_minimum_required(VERSION 3.16)
project(ChessGLCompatibility LANGUAGES C)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_EXTENSIONS ON)

# Keep source-location diagnostics independent of the build machine.
add_compile_options("-ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=ThirdParty")

# Reuse the pinned upstream source list, without its desktop loader or tests.
set(STATICLIB ON)
set(NO_LOADER ON)
set(NOX11 ON)
set(NOEGL ON)
set(NO_GBM ON)
add_compile_definitions(STATICLIB NOX11 NOEGL
    EGL_NO_X11 NO_GBM DEFAULT_ES=2)
include_directories("${CMAKE_CURRENT_SOURCE_DIR}/gl4es/include")
add_subdirectory(gl4es/src gl4es)
target_compile_options(GL PRIVATE -Wno-deprecated-declarations
    -Wno-pointer-sign -Wno-dangling-else)
set_target_properties(GL PROPERTIES OUTPUT_NAME ChessGL4ES)

add_library(ChessGLU STATIC GLU/src/libutil/quad.c GLU/src/libutil/project.c)
target_include_directories(ChessGLU BEFORE PRIVATE GLU/include GLU/src/include)
