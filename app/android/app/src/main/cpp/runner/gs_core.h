#pragma once
// Dynamic libretro core loading for M4+: every core ships as its own
// libgs_<id>.so packaged in the APK; the runner resolves the retro_* ABI
// with dlopen/dlsym at startup instead of statically linking one core.
//
// Android's classloader-native namespace allows dlopen() of sibling
// libraries from the app's lib dir, so a plain soname works.

#include <string>

extern "C" {
#include <libretro.h>
}

struct GsCoreApi {
    void *handle = nullptr;

    unsigned (*api_version)(void) = nullptr;
    void (*set_environment)(retro_environment_t cb) = nullptr;
    void (*set_video_refresh)(retro_video_refresh_t cb) = nullptr;
    void (*set_audio_sample)(retro_audio_sample_t cb) = nullptr;
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t cb) = nullptr;
    void (*set_input_poll)(retro_input_poll_t cb) = nullptr;
    void (*set_input_state)(retro_input_state_t cb) = nullptr;
    void (*set_controller_port_device)(unsigned port, unsigned device) = nullptr;
    void (*init)(void) = nullptr;
    void (*deinit)(void) = nullptr;
    bool (*load_game)(const retro_game_info *game) = nullptr;
    void (*unload_game)(void) = nullptr;
    void (*run)(void) = nullptr;
    void (*get_system_av_info)(retro_system_av_info *info) = nullptr;
    size_t (*serialize_size)(void) = nullptr;
    bool (*serialize)(void *data, size_t size) = nullptr;
    bool (*unserialize)(const void *data, size_t size) = nullptr;
    void *(*get_memory_data)(unsigned type) = nullptr;
    size_t (*get_memory_size)(unsigned type) = nullptr;
    void (*cheat_reset)(void) = nullptr;
    void (*cheat_set)(unsigned index, bool enabled, const char *code) = nullptr;

    bool valid() const {
        return handle && set_environment && init && load_game && run;
    }
};

/// dlopens libgs_<coreId>.so and resolves every ABI symbol. On failure
/// returns an api with handle==nullptr and fills [err].
GsCoreApi gsLoadCore(const std::string &coreId, std::string &err);

/// Closes the core after retro_deinit/retro_unload_game have been called.
void gsUnloadCore(GsCoreApi &api);
