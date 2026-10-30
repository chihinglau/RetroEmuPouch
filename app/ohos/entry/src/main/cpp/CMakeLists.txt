cmake_minimum_required(VERSION 3.16.0)
project(gpretro)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# ---- Netplay lockstep engine (shared, pure POSIX C++; see §16.4) ----
# The OHOS frontend reuses the same delay-based lockstep transport the Android
# build uses. Referenced from the Android source tree to keep a single copy.
set(NETPLAY_SRC_ROOT "D:/ai/prj/trae/HuaWei/RetroEmuPouch/app/android/app/src/main/cpp/netplay")
add_library(gpretro SHARED
    gpretro.cpp
    ${NETPLAY_SRC_ROOT}/gs_netplay.cpp
    ${NETPLAY_SRC_ROOT}/gs_np_ring.cpp
    ${NETPLAY_SRC_ROOT}/gs_np_replay.cpp
    ${NETPLAY_SRC_ROOT}/gs_np_delay.cpp
    ${NETPLAY_SRC_ROOT}/gs_np_codec.cpp
    ${NETPLAY_SRC_ROOT}/gs_np_sha256.c
)

# libretro API headers (for the retro_* host callbacks and struct definitions)
# come from the fceumm core's vendored libretro-common.
set(LIBRETRO_COMMON_INC "D:/ai/prj/trae/HuaWei/RetroEmuPouch/cores/libretro-fceumm/drivers/libretro/libretro-common/include")

target_include_directories(gpretro PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    ${LIBRETRO_COMMON_INC}
    ${NETPLAY_SRC_ROOT}
)

# OHOS system libs required by the emulator host.
#   ace_ndk.z  -> XComponent C API (OH_NativeXComponent_*)
#   ace_napi.z -> NAPI runtime (napi_get_cb_info / napi_unwrap / module register)
#   EGL/GLESv3 -> native rendering into the XComponent window
#   ohaudio    -> OH_AudioRenderer (sine tone in M0)
#   hilog_ndk.z-> OH_LOG_Print (M0 verification logging)
#   native_window -> OH_NativeWindow_NativeWindowHandleOpt (EGL surface format)
target_link_libraries(gpretro PUBLIC
    ace_ndk.z
    ace_napi.z
    EGL
    GLESv3
    ohaudio
    hilog_ndk.z
    native_window
)

# Package the cross-compiled libretro cores (libgs_<id>.so) into the native lib
# output dir so hvigor bundles them into the HAP under libs/<abi>/. The host
# dlopen()s one sibling at runtime by coreId. Copy to
# CMAKE_LIBRARY_OUTPUT_DIRECTORY directly (a target reference would create a
# dependency cycle) and re-copy whenever any core .so changes.
# CONFIGURE_DEPENDS: re-glob at build time so a newly built core (e.g. the
# 189MB libgs_mame.so) is staged into the HAP without a manual CMake reconfigure.
file(GLOB GS_CORE_SOS CONFIGURE_DEPENDS "D:/ai/prj/trae/HuaWei/RetroEmuPouch/cores/ohos/build/libgs_*.so")
set(GPRETRO_LIB_OUT "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
if(NOT GPRETRO_LIB_OUT)
    set(GPRETRO_LIB_OUT "${CMAKE_CURRENT_BINARY_DIR}")
endif()
set(GS_CORE_STAMP "${CMAKE_CURRENT_BINARY_DIR}/gscores.stamp")
add_custom_command(
    OUTPUT ${GS_CORE_STAMP}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different ${GS_CORE_SOS} "${GPRETRO_LIB_OUT}/"
    COMMAND ${CMAKE_COMMAND} -E touch ${GS_CORE_STAMP}
    DEPENDS ${GS_CORE_SOS}
    COMMENT "Staging libretro cores into ${GPRETRO_LIB_OUT}")
add_custom_target(stage_gscores ALL DEPENDS ${GS_CORE_STAMP})
