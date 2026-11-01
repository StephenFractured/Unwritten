cmake_minimum_required(VERSION 3.20)
project(unwritten LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Use a system ENet if present (Linux: apt install libenet-dev), otherwise fetch v1.3.18.
find_path(ENET_INCLUDE_DIR enet/enet.h)
find_library(ENET_LIBRARY enet)
if(ENET_INCLUDE_DIR AND ENET_LIBRARY AND NOT UW_FETCH_ENET)
  add_library(enet INTERFACE)
  target_include_directories(enet INTERFACE ${ENET_INCLUDE_DIR})
  target_link_libraries(enet INTERFACE ${ENET_LIBRARY})
else()
  include(FetchContent)
  FetchContent_Declare(enet
    GIT_REPOSITORY https://github.com/lsalzman/enet.git
    GIT_TAG v1.3.18)
  FetchContent_MakeAvailable(enet)
  # ENet's CMake target does not export its include dir.
  target_include_directories(enet PUBLIC ${enet_SOURCE_DIR}/include)
endif()

if(WIN32)
  # windows.h (pulled in by enet.h) defines min/max macros that break std::min/std::max.
  add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)
  # ENet v1.3.18 does not link its own Windows socket/timer libraries, so we do.
  set(UW_PLATFORM_LIBS ws2_32 winmm)
endif()

add_executable(unwritten-server server/main.cpp)
target_include_directories(unwritten-server PRIVATE shared)
target_link_libraries(unwritten-server PRIVATE enet ${UW_PLATFORM_LIBS})

add_executable(botswarm tools/botswarm/main.cpp)
target_include_directories(botswarm PRIVATE shared)
target_link_libraries(botswarm PRIVATE enet ${UW_PLATFORM_LIBS})
