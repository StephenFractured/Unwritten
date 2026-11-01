# Built as part of the RE-UE4SS source tree (Windows, MSVC). See docs/phase0-runbook.md.
# Place this folder at <RE-UE4SS>/cppmods/UnwrittenClient and add
#   add_subdirectory(cppmods/UnwrittenClient)
# to RE-UE4SS's top-level CMakeLists.txt (or the cppmods/CMakeLists.txt if your version has one).
cmake_minimum_required(VERSION 3.22)

set(TARGET UnwrittenClient)
project(${TARGET})

include(FetchContent)
FetchContent_Declare(enet
  GIT_REPOSITORY https://github.com/lsalzman/enet.git
  GIT_TAG v1.3.18)
FetchContent_MakeAvailable(enet)
# ENet's CMake target does not export its include dir. (It already links ws2_32/winmm.)
target_include_directories(enet PUBLIC ${enet_SOURCE_DIR}/include)

# Path to the Unwritten repo's shared/ folder (protocol.hpp).
set(UNWRITTEN_SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared" CACHE PATH "Unwritten shared headers")

add_library(${TARGET} SHARED src/dllmain.cpp)
target_compile_definitions(${TARGET} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(${TARGET} PRIVATE ${UNWRITTEN_SHARED})
target_link_libraries(${TARGET} PUBLIC UE4SS enet)
