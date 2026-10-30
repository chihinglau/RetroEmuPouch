# mGBA (Game Boy Advance + Game Boy) -> libgs_mgba.so
#
# mGBA ships a large first-party CMake build with code generation
# (version-info) and hundreds of sources, so rather than mirroring its
# source list we delegate to that build with BUILD_LIBRETRO=ON:
#   * DISABLE_DEPS=ON - no zlib/png/lzma/sqlite/lua/ffmpeg (console-style
#     minimal core; plain .gba ROMs and battery saves still work)
#   * SKIP_LIBRARY=ON - skip the standalone libmgba target
# The upstream target emits "mgba_libretro.so" (no lib prefix). We create
# a placeholder gs_mgba shared target so AGP's native packaging picks the
# path up, then overwrite its file with the upstream blob post-build.

include(ExternalProject)

set(MGBA "${THIRD_PARTY}/mgba")
if(NOT EXISTS "${MGBA}/CMakeLists.txt")
  message(FATAL_ERROR "mgba core not found at ${MGBA}. Run scripts/sync-cores.ps1 first.")
endif()

set(MGBA_EP_DIR "${CMAKE_CURRENT_BINARY_DIR}/mgba-ep")
set(MGBA_BLOB   "${MGBA_EP_DIR}/build/mgba_libretro.so")

# ExternalProject re-uses these args in a generated cmake script, where
# Windows backslashes become invalid escape sequences - normalise them.
file(TO_CMAKE_PATH "${CMAKE_TOOLCHAIN_FILE}" MGBA_TOOLCHAIN)
file(TO_CMAKE_PATH "${CMAKE_MAKE_PROGRAM}"  MGBA_MAKE_PROGRAM)

ExternalProject_Add(mgba_ep
  PREFIX        "${MGBA_EP_DIR}"
  SOURCE_DIR    "${MGBA}"
  BINARY_DIR    "${MGBA_EP_DIR}/build"
  CMAKE_GENERATOR "${CMAKE_GENERATOR}"
  CMAKE_ARGS
    -DCMAKE_TOOLCHAIN_FILE=${MGBA_TOOLCHAIN}
    -DCMAKE_MAKE_PROGRAM=${MGBA_MAKE_PROGRAM}
    -DANDROID_ABI=${ANDROID_ABI}
    -DANDROID_PLATFORM=${ANDROID_PLATFORM}
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_LIBRETRO=ON
    -DSKIP_LIBRARY=ON
    -DDISABLE_DEPS=ON
    -DENABLE_SCRIPTING=OFF
    -DENABLE_GDB_STUB=OFF
    -DBUILD_SHARED=OFF
    -DBUILD_STATIC=OFF
    -DBUILD_SDL=OFF
    -DBUILD_QT=OFF
    -DBUILD_PYTHON=OFF
    -DBUILD_HEADLESS=OFF
    -DBUILD_PERF=OFF
    -DBUILD_TEST=OFF
    -DBUILD_SUITE=OFF
    -DBUILD_CINEMA=OFF
  BUILD_ALWAYS  FALSE
  INSTALL_COMMAND ""
  BUILD_BYPRODUCTS "${MGBA_BLOB}"
  LOG_CONFIGURE TRUE
  LOG_BUILD     TRUE
)

# Placeholder target reserving the packaged output path.
file(WRITE "${MGBA_EP_DIR}/gs_mgba_stub.c"
     "/* placeholder replaced by mGBA libretro blob post-build */\n")
add_library(gs_mgba SHARED "${MGBA_EP_DIR}/gs_mgba_stub.c")
set_target_properties(gs_mgba PROPERTIES
  C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden)
target_link_libraries(gs_mgba ${log-lib} android)
add_dependencies(gs_mgba mgba_ep)
add_custom_command(TARGET gs_mgba POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${MGBA_BLOB}" "$<TARGET_FILE:gs_mgba>"
  COMMENT "Embedding upstream mGBA libretro core as libgs_mgba.so"
  VERBATIM)
