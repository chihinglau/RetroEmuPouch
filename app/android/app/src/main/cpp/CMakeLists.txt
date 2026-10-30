cmake_minimum_required(VERSION 3.22.1)
project(gsrunner LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# ---------------------------------------------------------------------------
# Layout (M4 multi-core):
#   libgsrunner.so          JNI + platform runner; dlopens one core at runtime
#   libgs_<coreId>.so       one libretro core each (fceumm/gambatte/...)
# Every .so built here is packaged into the APK by AGP; Android's native
# classloader namespace lets the runner dlopen() sibling libraries by soname.
# Cores are intentionally NOT linked together: their libretro-common copies
# and global state would collide in one namespace.
# ---------------------------------------------------------------------------

# app/android/app/src/main/cpp -> 6 levels up to the repository root
file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../third_party" THIRD_PARTY)

# libretro.h for the runner itself (API is core-independent).
set(FCE "${THIRD_PARTY}/fceumm")

add_library(gsrunner SHARED
  jni_bridge.cpp
  runner/gs_runner.cpp
  runner/gs_core.cpp
  netplay/gs_np_codec.cpp
  netplay/gs_np_sha256.c
  netplay/gs_np_replay.cpp
  netplay/gs_np_ring.cpp
  netplay/gs_np_delay.cpp
  netplay/gs_netplay.cpp
)

target_include_directories(gsrunner PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/runner"
  "${CMAKE_CURRENT_SOURCE_DIR}/netplay"
  "${FCE}/src/drivers/libretro/libretro-common/include"
)

target_compile_definitions(gsrunner PRIVATE PATH_MAX=1024)

target_compile_options(gsrunner PRIVATE
  # Last -O flag wins under clang; AGP debug sets -O0 upstream.
  -O2
  $<$<COMPILE_LANGUAGE:C>:-Wno-error -Wno-implicit-function-declaration
     -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-pointer-sign>
)

find_library(log-lib log)
target_link_libraries(gsrunner ${log-lib} aaudio android dl)

# ---------------------------------------------------------------------------
# Core build helper. Usage:
#   gs_add_core(<id>
#       SOURCES  <c/c++ files...>
#       INCLUDES <dirs...>
#       DEFINES  <macros...>)
# Produces libgs_<id>.so with the standard libretro compile flags.
# ---------------------------------------------------------------------------
function(gs_add_core CORE_ID)
  cmake_parse_arguments(ARG "" "" "SOURCES;INCLUDES;DEFINES" ${ARGN})
  add_library(gs_${CORE_ID} SHARED ${ARG_SOURCES})
  set_target_properties(gs_${CORE_ID} PROPERTIES
      C_VISIBILITY_PRESET hidden
      CXX_VISIBILITY_PRESET hidden)
  target_include_directories(gs_${CORE_ID} PRIVATE ${ARG_INCLUDES})
  target_compile_definitions(gs_${CORE_ID} PRIVATE
      __LIBRETRO__ PATH_MAX=1024 PSS_STYLE=1 ${ARG_DEFINES})
  target_compile_options(gs_${CORE_ID} PRIVATE
      -O2 -fvisibility=hidden
      $<$<COMPILE_LANGUAGE:C>:-Wno-error -Wno-implicit-function-declaration
         -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-pointer-sign
         -Wno-unused-function -Wno-unused-variable
         -Wno-deprecated-declarations -Wno-implicit-int>
      $<$<COMPILE_LANGUAGE:CXX>:-Wno-error -Wno-write-strings
         -Wno-deprecated-declarations>)
  target_link_libraries(gs_${CORE_ID} ${log-lib} android)
endfunction()

# ---------------------------------------------------------------------------
# Per-core source manifests (kept in separate files for readability)
# ---------------------------------------------------------------------------
include(${CMAKE_CURRENT_SOURCE_DIR}/core_fceumm.cmake)
# A core joins the build once its manifest is written (and the repo synced).
foreach(_id IN ITEMS gambatte stella2014 picodrive mgba)
  set(_manifest "${CMAKE_CURRENT_SOURCE_DIR}/core_${_id}.cmake")
  if(EXISTS "${_manifest}")
    include(${_manifest})
  else()
    message(STATUS "gs: core manifest not present, skipping libgs_${_id}.so")
  endif()
endforeach()
