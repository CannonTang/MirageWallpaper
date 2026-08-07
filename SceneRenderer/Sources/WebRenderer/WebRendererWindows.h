#pragma once
#include <windows.h>
#include <string>

namespace SceneRenderer::WebRenderer {

/// Settings for web wallpaper renderer
struct WebRendererConfig {
    std::string url;                    // URL or file:// path to render
    std::string projectDir;             // Base directory for resolving local files
    int screenIndex = 0;               // Target monitor index
    int width = 1920;
    int height = 1080;
    int fps = 30;
    float volume = 1.0f;
    bool muted = false;
    bool transparent = false;
    bool debug = false;
};

/// Web wallpaper renderer using WebView2
class WebRendererWin {
    friend LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
public:
    WebRendererWin() = default;
    ~WebRendererWin();

    // Non-copyable
    WebRendererWin(const WebRendererWin&) = delete;
    WebRendererWin& operator=(const WebRendererWin&) = delete;

    /// Initialize WebView2 and create the render window
    bool initialize(const WebRendererConfig& config);

    /// Start rendering (message loop)
    int run();

    /// Stop rendering and cleanup
    void shutdown();

    // Runtime controls
    void setVolume(float volume);
    void setMuted(bool muted);
    void navigate(const std::string& url);
    void executeScript(const std::string& script);
    void reload();
    void pause();
    void resume();

private:
    bool createWallpaperWindow();
    bool initWebView2(HWND hwnd);
    void setupWebView2Callbacks();
    void destroyWebView2();
    void cleanupWallpaperWindow();

    // WorkerW wallpaper window management
    HWND findWallpaperWorkerW();
    bool embedIntoWallpaper();

    WebRendererConfig m_config;
    HWND m_hwnd = nullptr;
    HWND m_webViewHwnd = nullptr;
    void* m_webView2Controller = nullptr;  // ICoreWebView2Controller*
    void* m_webView2 = nullptr;            // ICoreWebView2*
    bool m_initialized = false;
    bool m_running = false;
    bool m_paused = false;
    bool m_muted = false;
    float m_volume = 1.0f;
};

} // namespace SceneRenderer::WebRenderer
