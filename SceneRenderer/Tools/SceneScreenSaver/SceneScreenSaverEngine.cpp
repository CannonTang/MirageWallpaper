#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

import rstd.cppstd;
import rstd.log;
import sr.json;
import sr.scene_wallpaper;
import sr.utils;

extern "C" void SceneRendererSetLiveMetalFrameCallback(
    void (*cb)(void*, std::uint32_t, std::uint32_t, void*), void* userdata);
extern "C" void* MirageSceneSaverHostCreate(void* ns_view, std::uint32_t drawable_width,
                                               std::uint32_t drawable_height);
extern "C" void* MirageSceneDesktopHostCreate(void* ca_layer, std::uint32_t drawable_width,
                                                std::uint32_t drawable_height);
extern "C" void MirageSceneSaverHostDestroy(void* host);
extern "C" void MirageSceneSaverHostPresent(void* host, void* texture, std::uint32_t width,
                                               std::uint32_t height);

namespace {

struct SaverEngine {
    sr::SceneWallpaper wallpaper;
    std::vector<void*> hosts;
    std::string configuration_key;
};

struct SaverInstance {
    SaverEngine* engine { nullptr };
    void* host { nullptr };
    bool paused { false };
};

std::mutex g_engine_mutex;
SaverEngine* g_engine { nullptr };
std::vector<SaverInstance*> g_instances;

void Present(void* texture, std::uint32_t width, std::uint32_t height, void* userdata) {
    auto* engine = static_cast<SaverEngine*>(userdata);
    std::scoped_lock lock(g_engine_mutex);
    if (engine == nullptr || engine != g_engine) return;
    for (void* host : engine->hosts) {
        MirageSceneSaverHostPresent(host, texture, width, height);
    }
}

bool LoadProperties(const char* json, sr::SceneWallpaperConfig& config) {
    if (json == nullptr || json[0] == '\0') return true;
    auto parsed = sr::ParseJson(json, { .allow_comments = false });
    if (parsed.is_err()) return false;
    auto value = parsed.unwrap();
    if (!value.is_object()) return false;
    auto object = value.as_object();
    (*object)->iter().for_each([&](auto entry) {
        auto [key, property] = entry;
        config.user_properties.insert(::alloc::string::String::make(key->as_str()), property->clone());
    });
    return true;
}

void* CreateInstance(void* host, const char* assets_dir, const char* scene_pkg,
                     const char* properties_json, std::uint32_t width,
                     std::uint32_t height, std::uint32_t fps) {
    if (host == nullptr || assets_dir == nullptr || scene_pkg == nullptr) return nullptr;
    static rstd::log::EnvLogger logger;
    static bool logger_set = false;
    if (!logger_set) {
        rstd::log::set_logger(logger);
        rstd::log::set_max_level(logger.filter());
        logger_set = true;
    }
    const std::string configuration_key =
        std::string(assets_dir) + "\n" + scene_pkg + "\n" +
        (properties_json == nullptr ? "" : properties_json) + "\n" + std::to_string(fps);
    std::unique_lock lock(g_engine_mutex);
    if (g_engine != nullptr && g_engine->configuration_key == configuration_key) {
        auto* instance = new SaverInstance { g_engine, host, false };
        g_engine->hosts.push_back(host);
        g_instances.push_back(instance);
        return instance;
    }
    SaverEngine* retired_engine = g_engine;
    if (retired_engine != nullptr) {
        SceneRendererSetLiveMetalFrameCallback(nullptr, nullptr);
        g_engine = nullptr;
        retired_engine->hosts.clear();
        for (auto* instance : g_instances) {
            if (instance->engine == retired_engine) instance->engine = nullptr;
        }
        g_instances.clear();
    }
    lock.unlock();
    delete retired_engine;
    auto engine = std::make_unique<SaverEngine>();
    engine->hosts.push_back(host);
    engine->configuration_key = configuration_key;
    if (!engine->wallpaper.init()) {
        MirageSceneSaverHostDestroy(host);
        return nullptr;
    }
    sr::SceneWallpaperConfig config;
    config.assets_dir = assets_dir;
    config.source_pkg_path = scene_pkg;
    config.cache_dir = sr::platform::GetCachePath("MirageDynamicWallpaper");
    config.fps = std::clamp<std::uint32_t>(fps, 10u, 60u);
    config.muted = true;
    if (!LoadProperties(properties_json, config)) {
        MirageSceneSaverHostDestroy(host);
        return nullptr;
    }
    SceneRendererSetLiveMetalFrameCallback(Present, engine.get());
    sr::RenderInitInfo info;
    info.offscreen = true;
    info.width = std::clamp<std::uint32_t>(width, 500u, 8192u);
    info.height = std::clamp<std::uint32_t>(height, 500u, 8192u);
    info.msaa_samples = 1;
    engine->wallpaper.configure(std::move(config));
    engine->wallpaper.initVulkan(std::move(info));
    if (!engine->wallpaper.waitVulkanInited(30000)) {
        SceneRendererSetLiveMetalFrameCallback(nullptr, nullptr);
        MirageSceneSaverHostDestroy(host);
        return nullptr;
    }
    lock.lock();
    g_engine = engine.release();
    auto* instance = new SaverInstance { g_engine, host, false };
    g_instances.push_back(instance);
    return instance;
}

}

extern "C" void* MirageSceneSaverCreate(void* ns_view, const char* assets_dir,
                                          const char* scene_pkg, const char* properties_json,
                                          std::uint32_t width, std::uint32_t height,
                                          std::uint32_t drawable_width,
                                          std::uint32_t drawable_height,
                                          std::uint32_t fps) {
    void* host = MirageSceneSaverHostCreate(ns_view, drawable_width, drawable_height);
    return CreateInstance(host, assets_dir, scene_pkg, properties_json, width, height, fps);
}

extern "C" void* MirageSceneDesktopCreate(void* ca_layer, const char* assets_dir,
                                            const char* scene_pkg, const char* properties_json,
                                            std::uint32_t width, std::uint32_t height,
                                            std::uint32_t fps) {
    void* host = MirageSceneDesktopHostCreate(ca_layer, width, height);
    return CreateInstance(host, assets_dir, scene_pkg, properties_json, width, height, fps);
}

extern "C" void MirageSceneSaverSetPaused(void* handle, int paused) {
    auto* instance = static_cast<SaverInstance*>(handle);
    std::scoped_lock lock(g_engine_mutex);
    if (instance == nullptr || instance->engine != g_engine) return;
    instance->paused = paused != 0;
    const bool all_paused = std::all_of(g_instances.begin(), g_instances.end(), [](auto* item) {
        return item->paused;
    });
    if (all_paused) g_engine->wallpaper.pause();
    else g_engine->wallpaper.play();
}

extern "C" void MirageSceneDesktopSetPaused(void* handle, int paused) {
    MirageSceneSaverSetPaused(handle, paused);
}

extern "C" void MirageSceneSaverDestroy(void* handle) {
    auto* instance = static_cast<SaverInstance*>(handle);
    if (instance == nullptr) return;
    std::unique_lock lock(g_engine_mutex);
    void* host = instance->host;
    auto* engine = instance->engine;
    std::erase(g_instances, instance);
    if (engine != nullptr) std::erase(engine->hosts, host);
    delete instance;
    const bool last = g_instances.empty() && engine == g_engine;
    if (last) {
        SceneRendererSetLiveMetalFrameCallback(nullptr, nullptr);
        g_engine = nullptr;
    }
    lock.unlock();
    if (last) delete engine;
    MirageSceneSaverHostDestroy(host);
}

extern "C" void MirageSceneDesktopDestroy(void* handle) {
    MirageSceneSaverDestroy(handle);
}
