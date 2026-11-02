# Unwritten native mods, built together with the UE4SS source they link against.
# RE-UE4SS is cloned into client/cpp/RE-UE4SS (not committed; see docs/Phase 0 Runbook.md, Step 3).
# Build with the "Game__Shipping__Win64" configuration so it matches the UE4SS you installed (main @ 1ceefac8).
cmake_minimum_required(VERSION 3.22)
project(UnwrittenMods)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/RE-UE4SS/CMakeLists.txt")
  message(FATAL_ERROR "RE-UE4SS not found. Clone it into client/cpp/RE-UE4SS (runbook Step 3).")
endif()

add_subdirectory(RE-UE4SS)
add_subdirectory(UnwrittenClient)
