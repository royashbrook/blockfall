cmake_minimum_required(VERSION 3.28)
project(blockcore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# arm64-only (spec §2/§4.11 — both ends Apple Silicon)
if(APPLE)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
  # Match the Swift app's deployment floor (spec §5: macOS 14+).
  set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "" FORCE)
endif()

# Sanitizers wired for ci/check.sh (spec §5). Off by default; -DBF_SANITIZE=address/thread/undefined
if(BF_SANITIZE)
  add_compile_options(-fsanitize=${BF_SANITIZE} -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=${BF_SANITIZE})
endif()

add_library(blockcore STATIC
  src/engine_stub.cpp   # C ABI impl over the World (M1 engine)
  src/jobs.cpp          # Track A — work-stealing job system
  src/mesher.cpp        # Track D — greedy meshing
  src/worldgen.cpp      # Track C — procedural generation
  src/content.cpp       # Track J — content registries (blocks/items/recipes)
  src/net.cpp           # Track H — reliable UDP transport
)
find_package(Threads REQUIRED)

target_include_directories(blockcore
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract   # engine_c_api.h, interfaces
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(blockcore PUBLIC Threads::Threads)

target_compile_options(blockcore PRIVATE
  -Wall -Wextra -Wpedantic -Wconversion -Wshadow
)

# Optional: a tiny self-test harness that links blockcore (ci unit smoke).
option(BF_BUILD_TESTS "Build engine unit smoke tests" OFF)
if(BF_BUILD_TESTS)
  enable_testing()
  set(BF_TEST_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../tests/unit)
  foreach(t abi:smoke_abi arena:test_arena jobs:test_jobs chunk:test_chunk mesher:test_mesher winding:test_winding worldgen:test_worldgen lighting:test_lighting content:test_content inventory:test_inventory net:test_net coop:test_coop quest:test_quest questloop:test_questloop world:test_world gameplay:test_gameplay saveload:test_saveload)
    string(REPLACE ":" ";" parts ${t})
    list(GET parts 0 tname)
    list(GET parts 1 tsrc)
    add_executable(blockcore_${tname} ${BF_TEST_DIR}/${tsrc}.cpp)
    target_link_libraries(blockcore_${tname} PRIVATE blockcore)
    add_test(NAME ${tname} COMMAND blockcore_${tname})
  endforeach()
endif()
