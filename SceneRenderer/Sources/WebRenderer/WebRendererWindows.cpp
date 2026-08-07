#include "WebRendererWindows.h"
#include <ShlObj.h>
#include <shellapi.h>
#include <thread>
#include <mutex>
#include <queue>
#include <cassert>
#include <algorithm>
#include <iostream>
#include <string>
#include <cstdio>

// WebView2 headers (installed via NuGet/nuget package)
#include <WebView2.h>
#include <wrl/client.h>
#include <wrl/event.h>  // Microsoft::WRL::Callback<>
using namespace Microsoft::WRL;

namespace SceneRenderer::WebRenderer {

// Control commands received from stdin
struct ControlCommand {
    std::string type;
    std::string data;
};

namespace {
    // Globals for the window procedure
    WebRendererWin* g_instance = nullptr;

    LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
        switch (msg) {
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_SIZE:
            if (g_instance && g_instance->m_webView2Controller) {
                RECT bounds;
                GetClientRect(hwnd, &bounds);
                auto* controller = static_cast<ICoreWebView2Controller*>(g_instance->m_webView2Controller);
                controller->put_Bounds(bounds);
            }
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

WebRendererWin::~WebRendererWin() {
    shutdown();
}

bool WebRendererWin::initialize(const WebRendererConfig& config) {
    if (m_initialized) return true;
    m_config = config;
    g_instance = this;

    // Register window class
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"MirageWebRenderer";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    RegisterClassExW(&wc);

    if (!createWallpaperWindow())
        return false;

    if (!initWebView2(m_hwnd))
        return false;

    m_initialized = true;
    return true;
}

bool WebRendererWin::createWallpaperWindow() {
    // Create a borderless window for the wallpaper layer
    POINT pt = {};
    HMONITOR hMonitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);

    MONITORINFO mi = {};
    mi.cbSize = sizeof(MONITORINFO);
    GetMonitorInfoW(hMonitor, &mi);

    int x = mi.rcMonitor.left;
    int y = mi.rcMonitor.top;
    int w = mi.rcMonitor.right - mi.rcMonitor.left;
    int h = mi.rcMonitor.bottom - mi.rcMonitor.top;

    m_config.width = w;
    m_config.height = h;

    // Create the wallpaper window
    m_hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
        L"MirageWebRenderer",
        L"Mirage Web Wallpaper",
        WS_POPUP,
        x, y, w, h,
        nullptr, nullptr,
        GetModuleHandleW(nullptr),
        nullptr
    );

    if (!m_hwnd) return false;

    // Embed into wallpaper layer
    if (!embedIntoWallpaper())
        return false;

    ShowWindow(m_hwnd, SW_SHOW);
    UpdateWindow(m_hwnd);

    return true;
}

bool WebRendererWin::embedIntoWallpaper() {
    // Find the Progman window
    HWND hwndProgman = FindWindowW(L"Progman", nullptr);
    if (!hwndProgman) return false;

    // Send the magic message to create WorkerW
    auto result = SendMessageTimeoutW(
        hwndProgman, 0x052C, 0, 0,
        SMTO_NORMAL, 1000, nullptr
    );
    if (!result) return false;

    // Find the WorkerW window behind desktop icons
    HWND hwndWorkerW = findWallpaperWorkerW();
    if (!hwndWorkerW) {
        // WorkerW may need a bit of time, try again
        Sleep(500);
        hwndWorkerW = findWallpaperWorkerW();
        if (!hwndWorkerW) return false;
    }

    // Reparent our window to WorkerW
    SetParent(m_hwnd, hwndWorkerW);

    // Ensure it stays at the bottom of z-order
    SetWindowPos(m_hwnd, HWND_BOTTOM, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

    return true;
}

HWND WebRendererWin::findWallpaperWorkerW() {
    // Find the WorkerW that hosts the desktop wallpaper
    HWND hwndProgman = FindWindowW(L"Progman", nullptr);
    HWND hwndShellDefView = FindWindowExW(hwndProgman, nullptr, L"SHELLDLL_DefView", nullptr);
    HWND hwndWorkerW = nullptr;

    if (hwndShellDefView) {
        // On modern Windows, WorkerW is a sibling of Progman
        HWND hwndDesktop = FindWindowExW(nullptr, nullptr, L"WorkerW", nullptr);
        if (hwndDesktop) {
            // Check if this WorkerW has a SHELLDLL_DefView child
            HWND hwndDefView = FindWindowExW(hwndDesktop, nullptr, L"SHELLDLL_DefView", nullptr);
            if (hwndDefView) {
                return hwndDesktop;
            }
        }
    }

    // Fallback: enumerating WorkerW windows
    struct EnumCtx {
        HWND result;
        HWND targetDefView;
    } ctx = { nullptr, hwndShellDefView };

    EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
        auto* ctx = reinterpret_cast<EnumCtx*>(lParam);
        wchar_t className[64];
        GetClassNameW(hwnd, className, 64);
        if (wcscmp(className, L"WorkerW") == 0) {
            HWND defView = FindWindowExW(hwnd, nullptr, L"SHELLDLL_DefView", nullptr);
            if (defView) {
                ctx->result = hwnd;
                return FALSE; // Found it, stop
            }
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&ctx));

    return ctx.result;
}

bool WebRendererWin::initWebView2(HWND hwnd) {
    // Create WebView2 environment (async; callbacks fire in message loop)
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, nullptr, nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [hwnd, this](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result)) return result;

                // Create WebView2 controller (also async)
                HRESULT hrCtrl = env->CreateCoreWebView2Controller(hwnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [this](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(result)) return result;

                            m_webView2Controller = controller;
                            controller->AddRef();  // We own this reference

                            ComPtr<ICoreWebView2> webView;
                            HRESULT hr2 = controller->get_CoreWebView2(&webView);
                            if (FAILED(hr2)) return hr2;

                            m_webView2 = webView.Detach();
                            setupWebView2Callbacks();

                            // Size the WebView to fill the parent window
                            RECT bounds;
                            GetClientRect(m_hwnd, &bounds);
                            controller->put_Bounds(bounds);

                            // Navigate to the target URL
                            auto* wv = static_cast<ICoreWebView2*>(m_webView2);
                            std::wstring wurl(m_config.url.begin(), m_config.url.end());
                            wv->Navigate(wurl.c_str());

                            return S_OK;
                        }).Get());

                return hrCtrl;
            }).Get()
    );

    return SUCCEEDED(hr);
}

void WebRendererWin::setupWebView2Callbacks() {
    auto* webView = static_cast<ICoreWebView2*>(m_webView2);
    if (!webView) return;

    // Configure WebView2 settings
    ComPtr<ICoreWebView2Settings> settings;
    if (SUCCEEDED(webView->get_Settings(&settings))) {
        settings->put_IsScriptEnabled(TRUE);
        settings->put_IsWebMessageEnabled(TRUE);
        settings->put_AreDefaultScriptDialogsEnabled(TRUE);
        settings->put_IsStatusBarEnabled(FALSE);
        settings->put_AreDevToolsEnabled(m_config.debug ? TRUE : FALSE);

        // Make background transparent if configured
        if (m_config.transparent) {
            ComPtr<ICoreWebView2Settings2> settings2;
            if (SUCCEEDED(settings.As(&settings2))) {
                // Not all versions support transparent background
            }
        }
    }

    // Handle navigation events
    webView->add_NavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
            [](ICoreWebView2* sender, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
                return S_OK;
            }).Get(),
        nullptr
    );

    // Handle navigation completion
    webView->add_NavigationCompleted(
        Callback<ICoreWebView2NavigationCompletedEventHandler>(
            [](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
                BOOL success;
                args->get_IsSuccess(&success);
                return S_OK;
            }).Get(),
        nullptr
    );

    // Handle web messages (for bidirectional communication)
    webView->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [this](ICoreWebView2* sender, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                LPWSTR message = nullptr;
                HRESULT hr = args->TryGetWebMessageAsString(&message);
                if (SUCCEEDED(hr) && message) {
                    // Forward message to stdout for the manager
                    printf("{\"event\":\"webmessage\",\"data\":\"%S\"}\n", message);
                    fflush(stdout);
                    CoTaskMemFree(message);
                }
                return S_OK;
            }).Get(),
        nullptr
    );
}

void WebRendererWin::destroyWebView2() {
    if (m_webView2Controller) {
        auto* controller = static_cast<ICoreWebView2Controller*>(m_webView2Controller);
        controller->Close();
        m_webView2Controller = nullptr;
    }
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        webView->Release();
        m_webView2 = nullptr;
    }
}

void WebRendererWin::cleanupWallpaperWindow() {
    if (m_hwnd) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }
    UnregisterClassW(L"MirageWebRenderer", GetModuleHandleW(nullptr));
}

int WebRendererWin::run() {
    if (!m_initialized) return -1;

    m_running = true;

    // Start stdin reader thread for control commands
    std::thread cmdReader([this]() {
        std::string line;
        while (m_running) {
            std::getline(std::cin, line);
            if (line.empty()) continue;

            // Parse command: simple key=value or JSON
            if (line == "quit") {
                shutdown();
                PostMessageW(m_hwnd, WM_CLOSE, 0, 0);
                break;
            } else if (line == "pause") {
                pause();
            } else if (line == "resume") {
                resume();
            } else if (line == "reload") {
                reload();
            } else if (line.starts_with("navigate ")) {
                std::string url = line.substr(9);
                navigate(url);
            } else if (line.starts_with("script ")) {
                std::string script = line.substr(7);
                executeScript(script);
            } else if (line.starts_with("volume ")) {
                float vol = std::stof(line.substr(7));
                setVolume(vol);
            } else if (line.starts_with("mute")) {
                setMuted(true);
            } else if (line.starts_with("unmute")) {
                setMuted(false);
            }
        }
    });

    // Main message loop
    MSG msg = {};
    while (m_running && GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    m_running = false;
    if (cmdReader.joinable()) cmdReader.join();

    return 0;
}

void WebRendererWin::shutdown() {
    m_running = false;
    destroyWebView2();
    cleanupWallpaperWindow();
    m_initialized = false;
}

void WebRendererWin::setVolume(float volume) {
    m_volume = std::clamp(volume, 0.0f, 1.0f);
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        std::wstring script = L"document.querySelectorAll('video,audio').forEach(e=>e.volume="
            + std::to_wstring(m_volume) + L")";
        webView->ExecuteScript(script.c_str(), nullptr);
    }
}

void WebRendererWin::setMuted(bool muted) {
    m_muted = muted;
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        std::wstring script = std::wstring(L"document.querySelectorAll('video,audio').forEach(e=>e.muted=")
            + (muted ? L"true" : L"false") + L")";
        webView->ExecuteScript(script.c_str(), nullptr);
    }
}

void WebRendererWin::navigate(const std::string& url) {
    m_config.url = url;
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        std::wstring wurl(url.begin(), url.end());
        webView->Navigate(wurl.c_str());
    }
}

void WebRendererWin::executeScript(const std::string& script) {
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        std::wstring wscript(script.begin(), script.end());
        webView->ExecuteScript(wscript.c_str(), nullptr);
    }
}

void WebRendererWin::reload() {
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        webView->Reload();
    }
}

void WebRendererWin::pause() {
    m_paused = true;
    // Minimize rendering by hiding the window or executing pause script
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        webView->ExecuteScript(L"document.querySelectorAll('video,audio').forEach(e=>e.pause())",
                                nullptr);
    }
}

void WebRendererWin::resume() {
    m_paused = false;
    if (m_webView2) {
        auto* webView = static_cast<ICoreWebView2*>(m_webView2);
        webView->ExecuteScript(L"document.querySelectorAll('video,audio').forEach(e=>e.play())",
                                nullptr);
    }
}

} // namespace SceneRenderer::WebRenderer
