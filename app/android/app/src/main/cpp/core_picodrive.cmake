# PicoDrive (Master System / Game Gear / Genesis-MD / 32X / Sega-CD)
# -> libgs_picodrive.so
# Source selection mirrors upstream Makefile.libretro + Makefile +
# platform/common/common.mak for platform=arm64 (ARCH=aarch64):
#   * M68k  = famec (pure C interpreter, FAMEC_NO_GOTOS)
#   * Z80   = cz80  (pure C)
#   * SH2   = C interpreter (DRC_SH2 intentionally OFF: no RWX/arm64 DRC
#             needed for cartridge titles, avoids emit_arm64 surface)
#   * SVP   = ssp16 C interpreter (no _SVP_DRC)
#   * no 32-bit ARM asm, no generated pico_int_offs.h
# CD image support keeps mp3 (dr_mp3) + tremor; CHD/libchdr and its
# lzma/zstd deps are dropped (chd_parse() has a non-CHD stub).
# zlib comes from the NDK sysroot (-lz) instead of the bundled sources.

set(PD "${THIRD_PARTY}/picodrive")
if(NOT EXISTS "${PD}/platform/libretro/libretro.c")
  message(FATAL_ERROR "picodrive core not found at ${PD}. Run scripts/sync-cores.ps1 first.")
endif()
set(PDLC "${PD}/platform/libretro/libretro-common")

set(PD_SRCS
  # --- Pico core ---
  "${PD}/pico/pico.c"
  "${PD}/pico/cart.c"
  "${PD}/pico/memory.c"
  "${PD}/pico/state.c"
  "${PD}/pico/sek.c"
  "${PD}/pico/z80if.c"
  "${PD}/pico/videoport.c"
  "${PD}/pico/draw2.c"
  "${PD}/pico/draw.c"
  "${PD}/pico/mode4.c"
  "${PD}/pico/misc.c"
  "${PD}/pico/eeprom.c"
  "${PD}/pico/patch.c"
  "${PD}/pico/debug.c"
  "${PD}/pico/media.c"
  "${PD}/pico/sms.c"
  # --- Mega-CD (kept, links with mp3/ogg backends) ---
  "${PD}/pico/cd/mcd.c"
  "${PD}/pico/cd/memory.c"
  "${PD}/pico/cd/sek.c"
  "${PD}/pico/cd/cdc.c"
  "${PD}/pico/cd/cdd.c"
  "${PD}/pico/cd/cd_image.c"
  "${PD}/pico/cd/cd_parse.c"
  "${PD}/pico/cd/gfx.c"
  "${PD}/pico/cd/gfx_dma.c"
  "${PD}/pico/cd/misc.c"
  "${PD}/pico/cd/pcm.c"
  "${PD}/pico/cd/megasd.c"
  # --- 32X (SH2 interpreter) ---
  "${PD}/pico/32x/32x.c"
  "${PD}/pico/32x/memory.c"
  "${PD}/pico/32x/draw.c"
  "${PD}/pico/32x/sh2soc.c"
  "${PD}/pico/32x/pwm.c"
  # --- Pico (secondary 68k bus) ---
  "${PD}/pico/pico/pico.c"
  "${PD}/pico/pico/memory.c"
  "${PD}/pico/pico/xpcm.c"
  # --- cartridge hardware / SVP ---
  "${PD}/pico/carthw/carthw.c"
  "${PD}/pico/carthw/eeprom_spi.c"
  "${PD}/pico/carthw/svp/svp.c"
  "${PD}/pico/carthw/svp/memory.c"
  "${PD}/pico/carthw/svp/ssp16.c"
  # --- sound ---
  "${PD}/pico/sound/sound.c"
  "${PD}/pico/sound/resampler.c"
  "${PD}/pico/sound/sn76496.c"
  "${PD}/pico/sound/ym2612.c"
  "${PD}/pico/sound/ym2413.c"
  "${PD}/pico/sound/vgm.c"
  "${PD}/pico/sound/mix.c"
  # --- CPUs ---
  "${PD}/cpu/fame/famec.c"
  "${PD}/cpu/cz80/cz80.c"
  "${PD}/cpu/drc/cmn.c"
  "${PD}/cpu/sh2/sh2.c"
  "${PD}/cpu/sh2/mame/sh2pico.c"
  # --- zip rom loading (uses sysroot zlib) ---
  "${PD}/unzip/unzip.c"
  # --- CD audio: mp3 (dr_mp3) + ogg (tremor) ---
  "${PD}/platform/common/mp3.c"
  "${PD}/platform/common/mp3_sync.c"
  "${PD}/platform/common/mp3_drmp3.c"
  "${PD}/platform/common/ogg.c"
  "${PD}/platform/common/tremor/block.c"
  "${PD}/platform/common/tremor/codebook.c"
  "${PD}/platform/common/tremor/floor0.c"
  "${PD}/platform/common/tremor/floor1.c"
  "${PD}/platform/common/tremor/info.c"
  "${PD}/platform/common/tremor/mapping0.c"
  "${PD}/platform/common/tremor/mdct.c"
  "${PD}/platform/common/tremor/registry.c"
  "${PD}/platform/common/tremor/res012.c"
  "${PD}/platform/common/tremor/sharedbook.c"
  "${PD}/platform/common/tremor/synthesis.c"
  "${PD}/platform/common/tremor/window.c"
  "${PD}/platform/common/tremor/vorbisfile.c"
  "${PD}/platform/common/tremor/framing.c"
  "${PD}/platform/common/tremor/bitwise.c"
  # --- libretro glue ---
  "${PD}/platform/libretro/libretro.c"
  "${PDLC}/compat/compat_strcasestr.c"
  "${PDLC}/compat/compat_strl.c"
  "${PDLC}/encodings/encoding_utf.c"
  "${PDLC}/file/file_path.c"
  "${PDLC}/file/file_path_io.c"
  "${PDLC}/formats/png/rpng.c"
  "${PDLC}/streams/trans_stream.c"
  "${PDLC}/streams/trans_stream_pipe.c"
  "${PDLC}/streams/trans_stream_zlib.c"
  "${PDLC}/string/stdstring.c"
  "${PDLC}/time/rtime.c"
  "${PDLC}/vfs/vfs_implementation.c"
)

gs_add_core(picodrive
  SOURCES ${PD_SRCS}
  INCLUDES
    "${PD}"
    "${PD}/pico/sound"
    "${PD}/platform/common"
    "${PD}/platform/common/tremor"
    "${PDLC}/include"
    "${PDLC}/include/compat"
    "${PDLC}/include/encodings"
    "${PDLC}/include/formats"
    "${PDLC}/include/streams"
    "${PDLC}/include/string"
    "${PDLC}/include/vfs"
  DEFINES
    EMU_F68K
    _USE_CZ80
    FAMEC_NO_GOTOS
    HAVE_ZLIB
    USE_TREMOR
    REVISION=\"-mygs\"
)

# Third-party code: silence warnings globally; aliasing assumptions in the
# software blitters require -fno-strict-aliasing (matches upstream Makefile).
target_compile_options(gs_picodrive PRIVATE -w -fno-strict-aliasing)
# rpng / trans_stream_zlib / unzip use the platform zlib.
target_link_libraries(gs_picodrive z)
