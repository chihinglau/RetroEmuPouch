# Stella 2014 (Atari 2600) -> libgs_stella2014.so
# Source list mirrors the upstream Makefile + Makefile.common.
# Core prefers XRGB8888 (with an RGB565 fallback the runner also supports).

set(STE "${THIRD_PARTY}/stella2014")
set(STC "${STE}/stella")
if(NOT EXISTS "${STE}/libretro.cxx")
  message(FATAL_ERROR "stella2014 core not found at ${STE}. Run scripts/sync-cores.ps1 first.")
endif()
set(SLC "${STE}/libretro-common")

file(GLOB STE_EMUCORE_SRCS "${STC}/src/emucore/*.cxx")

set(STE_CXX_SRCS
  "${STC}/src/common/Base.cxx"
  "${STC}/src/common/Sound.cxx"
  ${STE_EMUCORE_SRCS}
  "${STE}/libretro.cxx"
)

set(STE_C_SRCS
  "${STC}/src/emucore/Thumbulator.c"
  "${SLC}/compat/compat_posix_string.c"
  "${SLC}/compat/compat_strcasestr.c"
  "${SLC}/compat/compat_snprintf.c"
  "${SLC}/compat/compat_strl.c"
  "${SLC}/compat/fopen_utf8.c"
  "${SLC}/encodings/encoding_utf.c"
  "${SLC}/file/file_path.c"
  "${SLC}/file/file_path_io.c"
  "${SLC}/time/rtime.c"
  "${SLC}/streams/file_stream.c"
  "${SLC}/streams/file_stream_transforms.c"
  "${SLC}/string/stdstring.c"
  "${SLC}/vfs/vfs_implementation.c"
)

gs_add_core(stella2014
  SOURCES ${STE_C_SRCS} ${STE_CXX_SRCS}
  INCLUDES
    "${STE}"
    "${STC}"
    "${STC}/src"
    "${STC}/stubs"
    "${STC}/src/emucore"
    "${STC}/src/common"
    "${STC}/src/gui"
    "${SLC}/include"
  DEFINES
    THUMB_SUPPORT
    GIT_VERSION=\"gamepouch\"
)

target_compile_options(gs_stella2014 PRIVATE
  -Wno-sign-compare -Wno-unused-variable -Wno-unused-function
  -Wno-uninitialized -Wno-strict-aliasing -Wno-overflow -Wno-register)
