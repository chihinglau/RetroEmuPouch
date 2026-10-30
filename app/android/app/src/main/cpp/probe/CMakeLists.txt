# Phase-0 netplay probe — standalone arm64 executable, NOT part of the app.
#
# Built out-of-tree (see probe build script), pushed to /data/local/tmp:
# it exercises the packaged libgs_fbalpha2012.so over UDP between two phones
# without touching any shipping code path. AGP never sees this directory.
cmake_minimum_required(VERSION 3.22)
project(gs_probe LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# probe/ -> cpp -> main -> src -> app(module) -> android -> app(flutter) -> root
file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../third_party"
     GS_THIRD_PARTY)

# Reuse the runner's MGS1 lockfile decryptor and the netplay pure-logic
# layer (codec/HMAC/replay window/input ring/adaptive-D) unchanged.
add_executable(gs_probe
  gs_probe.cpp
  ../netplay/gs_np_codec.cpp
  ../netplay/gs_np_sha256.c
  ../netplay/gs_np_replay.cpp
  ../netplay/gs_np_ring.cpp
  ../netplay/gs_np_delay.cpp
  ../netplay/gs_netplay.cpp)

target_include_directories(gs_probe PRIVATE
  "${GS_THIRD_PARTY}/fceumm/src/drivers/libretro/libretro-common/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../netplay")

target_compile_options(gs_probe PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)

find_library(log-lib log)
target_link_libraries(gs_probe ${log-lib} dl)
