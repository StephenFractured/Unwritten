# UnwrittenClient native half (ENet bridge for the UnwrittenClient Lua mod).
# Built from client/cpp/CMakeLists.txt next to RE-UE4SS. See docs/Phase 0 Runbook.md, Step 3.
cmake_minimum_required(VERSION 3.22)

set(TARGET UnwrittenClient)
project(${TARGET})

include(FetchContent)
FetchContent_Declare(enet
  GIT_REPOSITORY https://github.com/lsalzman/enet.git
  GIT_TAG v1.3.18)
FetchContent_MakeAvailable(enet)
# ENet's CMake target does not export its include dir.
target_include_directories(enet PUBLIC ${enet_SOURCE_DIR}/include)

# The Unwritten repo's shared/ folder (protocol.hpp).
set(UNWRITTEN_SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../../../shared" CACHE PATH "Unwritten shared headers")

# Where the built mod is copied after every build. Point it at your game's UE4SS Mods folder.
set(UW_MODS_DIR "E:/HogwartsLegacy/Phoenix/Binaries/Win64/ue4ss/Mods" CACHE PATH "UE4SS Mods folder")

add_library(${TARGET} SHARED src/dllmain.cpp)
set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME main)  # UE4SS loads Mods/<Name>/dlls/main.dll
target_compile_definitions(${TARGET} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(${TARGET} PRIVATE ${UNWRITTEN_SHARED})
target_link_libraries(${TARGET} PUBLIC UE4SS enet ws2_32 winmm)

if(EXISTS "${UW_MODS_DIR}")
  add_custom_command(TARGET ${TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${UW_MODS_DIR}/UnwrittenClient/dlls"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:${TARGET}>" "${UW_MODS_DIR}/UnwrittenClient/dlls/main.dll"
    COMMENT "Installing main.dll into ${UW_MODS_DIR}/UnwrittenClient/dlls")
endif()
