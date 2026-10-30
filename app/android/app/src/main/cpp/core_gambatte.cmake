# Gambatte (Game Boy / Game Boy Color) -> libgs_gambatte.so
# Source list mirrors upstream libgambatte/Makefile.common + Makefile.libretro.
# We intentionally do NOT define VIDEO_RGB565 so the core negotiates
# RETRO_PIXEL_FORMAT_XRGB8888, the same 32-bit path the runner renders.

set(GAM "${THIRD_PARTY}/gambatte/libgambatte")
if(NOT EXISTS "${GAM}/libretro/libretro.cpp")
  message(FATAL_ERROR "gambatte core not found at ${GAM}. Run scripts/sync-cores.ps1 first.")
endif()
set(GLC "${GAM}/libretro-common")

set(GAM_C_SRCS
  "${GAM}/libretro/gambatte_log.c"
  "${GAM}/libretro/blipper.c"
  "${GAM}/libretro/cc_resampler.c"
  "${GLC}/compat/compat_posix_string.c"
  "${GLC}/compat/compat_snprintf.c"
  "${GLC}/compat/compat_strcasestr.c"
  "${GLC}/compat/compat_strl.c"
  "${GLC}/compat/fopen_utf8.c"
  "${GLC}/encodings/encoding_utf.c"
  "${GLC}/file/file_path.c"
  "${GLC}/file/file_path_io.c"
  "${GLC}/streams/file_stream.c"
  "${GLC}/streams/file_stream_transforms.c"
  "${GLC}/string/stdstring.c"
  "${GLC}/time/rtime.c"
  "${GLC}/vfs/vfs_implementation.c"
)

set(GAM_CXX_SRCS
  "${GAM}/src/bootloader.cpp"
  "${GAM}/src/cpu.cpp"
  "${GAM}/src/gambatte.cpp"
  "${GAM}/src/initstate.cpp"
  "${GAM}/src/interrupter.cpp"
  "${GAM}/src/interruptrequester.cpp"
  "${GAM}/src/gambatte-memory.cpp"
  "${GAM}/src/sound.cpp"
  "${GAM}/src/statesaver.cpp"
  "${GAM}/src/tima.cpp"
  "${GAM}/src/video.cpp"
  "${GAM}/src/video_libretro.cpp"
  "${GAM}/src/mem/cartridge.cpp"
  "${GAM}/src/mem/cartridge_libretro.cpp"
  "${GAM}/src/mem/huc3.cpp"
  "${GAM}/src/mem/memptrs.cpp"
  "${GAM}/src/mem/rtc.cpp"
  "${GAM}/src/sound/channel1.cpp"
  "${GAM}/src/sound/channel2.cpp"
  "${GAM}/src/sound/channel3.cpp"
  "${GAM}/src/sound/channel4.cpp"
  "${GAM}/src/sound/duty_unit.cpp"
  "${GAM}/src/sound/envelope_unit.cpp"
  "${GAM}/src/sound/length_counter.cpp"
  "${GAM}/src/video/ly_counter.cpp"
  "${GAM}/src/video/lyc_irq.cpp"
  "${GAM}/src/video/next_m0_time.cpp"
  "${GAM}/src/video/ppu.cpp"
  "${GAM}/src/video/sprite_mapper.cpp"
  "${GAM}/libretro/libretro.cpp"
)

gs_add_core(gambatte
  SOURCES ${GAM_C_SRCS} ${GAM_CXX_SRCS}
  INCLUDES
    "${GAM}/src"
    "${GAM}/include"
    "${THIRD_PARTY}/gambatte/common"
    "${GAM}/libretro"
    "${GLC}/include"
  DEFINES
    HAVE_STDINT_H
    HAVE_INTTYPES_H
    CC_RESAMPLER_NO_HIGHPASS
    GIT_VERSION=\"gamepouch\"
)

# Upstream builds this core as C++98 without RTTI/exceptions.
target_compile_options(gs_gambatte PRIVATE
  $<$<COMPILE_LANGUAGE:CXX>:-fno-rtti -fno-exceptions -Wno-unused-but-set-variable>)
