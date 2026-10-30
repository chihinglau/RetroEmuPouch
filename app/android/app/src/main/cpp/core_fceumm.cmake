# FCEUmm (NES/Famicom) -> libgs_fceumm.so
# Source list mirrors the upstream libretro build (Android.mk/Makefile).

set(FCE "${THIRD_PARTY}/fceumm")
if(NOT EXISTS "${FCE}/src/drivers/libretro/libretro.c")
  message(FATAL_ERROR "FCEUmm core not found at ${FCE}. Run scripts/sync-cores.ps1 first.")
endif()
set(LC "${FCE}/src/drivers/libretro/libretro-common")

file(GLOB FCE_BOARD_SRCS "${FCE}/src/boards/*.c")
file(GLOB FCE_INPUT_SRCS "${FCE}/src/input/*.c")

set(FCE_CORE_SRCS
  "${FCE}/src/ntsc/nes_ntsc.c"
  "${FCE}/src/drivers/libretro/libretro.c"
  "${FCE}/src/drivers/libretro/libretro_dipswitch.c"
  "${FCE}/src/cart.c"
  "${FCE}/src/cheat.c"
  "${FCE}/src/crc32.c"
  "${FCE}/src/fceu-endian.c"
  "${FCE}/src/fceu-memory.c"
  "${FCE}/src/fceu.c"
  "${FCE}/src/fds.c"
  "${FCE}/src/fds_apu.c"
  "${FCE}/src/file.c"
  "${FCE}/src/filter.c"
  "${FCE}/src/general.c"
  "${FCE}/src/input.c"
  "${FCE}/src/md5.c"
  "${FCE}/src/nsf.c"
  "${FCE}/src/palette.c"
  "${FCE}/src/ppu.c"
  "${FCE}/src/sound.c"
  "${FCE}/src/state.c"
  "${FCE}/src/video.c"
  "${FCE}/src/vsuni.c"
  "${FCE}/src/ines.c"
  "${FCE}/src/unif.c"
  "${FCE}/src/x6502.c"
  # libretro-common (same set the Android.mk builds)
  "${LC}/streams/memory_stream.c"
  "${LC}/compat/compat_posix_string.c"
  "${LC}/compat/compat_snprintf.c"
  "${LC}/compat/compat_strcasestr.c"
  "${LC}/compat/compat_strl.c"
  "${LC}/compat/fopen_utf8.c"
  "${LC}/encodings/encoding_utf.c"
  "${LC}/file/file_path.c"
  "${LC}/file/file_path_io.c"
  "${LC}/streams/file_stream.c"
  "${LC}/streams/file_stream_transforms.c"
  "${LC}/string/stdstring.c"
  "${LC}/time/rtime.c"
  "${LC}/vfs/vfs_implementation.c"
)

gs_add_core(fceumm
  SOURCES ${FCE_BOARD_SRCS} ${FCE_INPUT_SRCS} ${FCE_CORE_SRCS}
  INCLUDES
    "${FCE}/src/drivers/libretro"
    "${LC}/include"
    "${FCE}/src"
    "${FCE}/src/input"
    "${FCE}/src/boards"
    "${FCE}/src/ntsc"
  DEFINES
    FCEU_VERSION_NUMERIC=9900
    FRONTEND_SUPPORTS_RGB888
    HAVE_NTSC_FILTER
    GIT_VERSION=\"gamepouch\"
)
