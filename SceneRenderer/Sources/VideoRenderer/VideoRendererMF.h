#pragma once
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>  // IMFMediaEngine (required by mfreadwrite in SDK ≥10.0.26000)
#include <mfreadwrite.h>
#include <d3d11.h>
#include <d2d1_3.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <chrono>
#include <string>
#include <vector>
#include <functional>

namespace SceneRenderer::VideoRenderer {

using Microsoft::WRL::ComPtr;

enum class VideoFillMode { Cover, Contain, Stretch };

struct VideoRendererConfig {
    std::wstring filePath;
    int screenIndex = 0;
    int targetFps = 0;  // 0 = use video's native FPS
    float volume = 1.0f;
    bool muted = false;
    bool loop = true;
    VideoFillMode fillMode = VideoFillMode::Cover;
    HWND parentHwnd = nullptr;
};

/// Video wallpaper renderer using Media Foundation + DirectX 11
class VideoRendererMF {
public:
    VideoRendererMF();
    ~VideoRendererMF();

    VideoRendererMF(const VideoRendererMF&) = delete;
    VideoRendererMF& operator=(const VideoRendererMF&) = delete;

    bool initialize(const VideoRendererConfig& config);
    int run();
    void shutdown();

    // Playback control
    void play();
    void pause();
    void togglePause();
    void seek(float seconds);
    void setVolume(float volume);
    void setMuted(bool muted);
    void toggleMuted();
    void setSpeed(float speed);
    void setFillMode(VideoFillMode mode);
    void skipNext(double seconds);

    // State queries
    bool isPlaying() const { return m_state == State::Playing; }
    bool isPaused() const { return m_state == State::Paused; }
    double currentTime() const;
    double duration() const { return m_duration; }
    float volume() const { return m_volume; }
    bool muted() const { return m_muted; }
    float speed() const { return m_speed; }

private:
    enum class State { Uninitialized, Playing, Paused, Stopped };

    // Media Foundation initialization
    bool initMediaFoundation();
    bool openMediaSource();
    bool configureSourceReader();
    bool createDirectXResources();

    // Rendering
    bool renderFrame();
    void updateRenderTarget();
    void applyFillMode(float videoW, float videoH, D2D1_RECT_F& destRect);

    // Wallpaper window management
    bool createWallpaperWindow();
    bool embedIntoWallpaperLayer();
    HWND findWorkerW();

    // Threads
    void commandReaderThread();

    // Video metadata
    UINT m_width = 0;
    UINT m_height = 0;
    UINT m_numerator = 0;
    UINT m_denominator = 1;
    double m_duration = 0.0;

    // Media Foundation objects
    ComPtr<IMFSourceReader> m_sourceReader;
    ComPtr<IMFMediaSource> m_mediaSource;
    ComPtr<IMFPresentationDescriptor> m_presentationDesc;

    // DirectX objects
    ComPtr<ID3D11Device> m_d3dDevice;
    ComPtr<ID3D11DeviceContext> m_d3dContext;
    ComPtr<IDXGIFactory2> m_dxgiFactory;
    ComPtr<IDXGISwapChain1> m_swapChain;
    ComPtr<ID3D11RenderTargetView> m_renderTargetView;
    ComPtr<ID2D1Factory1> m_d2dFactory;   // ID2D1Factory1+ required for CreateDevice
    ComPtr<ID2D1Device> m_d2dDevice;
    ComPtr<ID2D1DeviceContext> m_d2dContext;
    ComPtr<ID2D1Bitmap1> m_d2dBitmap;     // D2D render target bitmap (backed by swapchain)

    // CPU-side NV12 → BGRA conversion buffer
    std::vector<uint8_t> m_convBuf;

    // Window
    HWND m_hwnd = nullptr;
    int m_windowWidth = 1920;
    int m_windowHeight = 1080;

    // State
    State m_state = State::Uninitialized;
    bool m_initialized = false;
    bool m_running = false;
    bool m_muted = false;
    float m_volume = 1.0f;
    float m_speed = 1.0f;
    VideoFillMode m_fillMode = VideoFillMode::Cover;
    VideoRendererConfig m_config;

    // Timing
    std::chrono::steady_clock::time_point m_lastFrameTime;
    std::chrono::steady_clock::time_point m_pauseTime;
    std::chrono::nanoseconds m_pauseDuration{0};
    LONGLONG m_currentSampleTime = 0;
};

} // namespace SceneRenderer::VideoRenderer
