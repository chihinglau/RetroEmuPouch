#include "gs_core.h"

#include <dlfcn.h>

namespace {
template <typename T>
bool resolve(void *h, const char *name, T &out, std::string &err) {
    out = reinterpret_cast<T>(dlsym(h, name));
    if (!out) {
        const char *e = dlerror();
        err += std::string("dlsym ") + name + ": " + (e ? e : "null") + "\n";
        return false;
    }
    return true;
}
}  // namespace

GsCoreApi gsLoadCore(const std::string &coreId, std::string &err) {
    GsCoreApi api;
    const std::string soname = "libgs_" + coreId + ".so";
    dlerror();
    api.handle = dlopen(soname.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!api.handle) {
        const char *e = dlerror();
        err = "dlopen " + soname + " failed: " + (e ? e : "unknown");
        return api;
    }
    bool ok = true;
    ok &= resolve(api.handle, "retro_api_version", api.api_version, err);
    ok &= resolve(api.handle, "retro_set_environment", api.set_environment, err);
    ok &= resolve(api.handle, "retro_set_video_refresh", api.set_video_refresh, err);
    ok &= resolve(api.handle, "retro_set_audio_sample", api.set_audio_sample, err);
    ok &= resolve(api.handle, "retro_set_audio_sample_batch",
                  api.set_audio_sample_batch, err);
    ok &= resolve(api.handle, "retro_set_input_poll", api.set_input_poll, err);
    ok &= resolve(api.handle, "retro_set_input_state", api.set_input_state, err);
    // Optional: cores without multi-device support may omit it.
    api.set_controller_port_device = reinterpret_cast<
        void (*)(unsigned, unsigned)>(dlsym(api.handle,
        "retro_set_controller_port_device"));
    dlerror();
    ok &= resolve(api.handle, "retro_init", api.init, err);
    ok &= resolve(api.handle, "retro_deinit", api.deinit, err);
    ok &= resolve(api.handle, "retro_load_game", api.load_game, err);
    ok &= resolve(api.handle, "retro_unload_game", api.unload_game, err);
    ok &= resolve(api.handle, "retro_run", api.run, err);
    ok &= resolve(api.handle, "retro_get_system_av_info",
                  api.get_system_av_info, err);
    ok &= resolve(api.handle, "retro_serialize_size", api.serialize_size, err);
    ok &= resolve(api.handle, "retro_serialize", api.serialize, err);
    ok &= resolve(api.handle, "retro_unserialize", api.unserialize, err);
    ok &= resolve(api.handle, "retro_get_memory_data", api.get_memory_data, err);
    ok &= resolve(api.handle, "retro_get_memory_size", api.get_memory_size, err);
    ok &= resolve(api.handle, "retro_cheat_reset", api.cheat_reset, err);
    ok &= resolve(api.handle, "retro_cheat_set", api.cheat_set, err);
    if (!ok) {
        dlclose(api.handle);
        api.handle = nullptr;
    }
    return api;
}

void gsUnloadCore(GsCoreApi &api) {
    if (api.handle) {
        dlclose(api.handle);
        api.handle = nullptr;
    }
}
