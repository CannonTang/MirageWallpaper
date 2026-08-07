#include "VideoRendererMF.h"
#include <mfidl.h>
#include <d3dcompiler.h>
#include <iostream>
#include <thread>
#include <algorithm>
#include <cmath>
#include <filesystem>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")

namespace SceneRenderer::VideoRenderer {

namespace {
    // Global instance for window proc
    VideoRendererMF* g_videoInstance = nullptr;

    LRESULT CALLBACK VideoWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
        switch (msg) {
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_SIZE:
            if (g_videoInstance) {
                g_videoInstance->m_windowWidth = LOWORD(lParam);
                g_videoInstance->m_windowHeight = HIWORD(lParam);
                g_videoInstance->updateRenderTarget();
            }
            return 0;
        case WM_TIMER:
            if (g_videoInstance && wParam == 1) {
                g_videoInstance->renderFrame();
            }
            return 0;
        case WM_PAINT:
            if (g_videoInstance) {
                g_videoInstance->renderFrame();
            }
            ValidateRect(hwnd, nullptr);
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    // WIC GUID for JPEG
    const GUID GUID_ContainerFormatJpeg =
        { 0x19e4a5aa, 0x5662, 0x4fc5, { 0xa0, 0xc0, 0x17, 0x58, 0x02, 0x8e, 0x10, 0x57 } };
}

VideoRendererMF::VideoRendererMF() = default;
VideoRendererMF::~VideoRendererMF() { shutdown(); }

// ============================================================
// Initialization
// ============================================================

bool VideoRendererMF::initMediaFoundation() {
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    return SUCCEEDED(hr);
}

bool VideoRendererMF::initialize(const VideoRendererConfig& config) {
    if (m_initialized) return true;

    m_config = config;
    g_videoInstance = this;

    if (!initMediaFoundation()) return false;
    if (!openMediaSource()) return false;
    if (!configureSourceReader()) return false;
    if (!createDirectXResources()) return false;
    if (!createWallpaperWindow()) return false;

    m_initialized = true;
    m_state = State::Paused;
    return true;
}

bool VideoRendererMF::openMediaSource() {
    HRESULT hr = MFCreateSourceReaderFromURL(
        m_config.filePath.c_str(),
        nullptr,
        &m_sourceReader
    );

    if (FAILED(hr)) {
        // Try byte stream for files with non-ASCII paths
        ComPtr<IMFByteStream> byteStream;
        hr = MFCreateFile(MF_ACCESSMODE_READ, MF_OPENMODE_FAIL_IF_NOT_EXIST,
                          MF_FILEFLAGS_NONE, m_config.filePath.c_str(), &byteStream);
        if (SUCCEEDED(hr)) {
            ComPtr<IMFAttributes> attrs;
            MFCreateAttributes(&attrs, 1);
            attrs->SetString(MF_BYTESTREAM_CONTENT_TYPE, L"video/mp4");
            attrs->SetUINT32(MF_BYTESTREAM_DURATION_ATTRIBUTE, 0);

            hr = MFCreateSourceReaderFromByteStream(byteStream.Get(), attrs.Get(), &m_sourceReader);
        }
    }

    if (FAILED(hr)) return false;

    // Get video duration
    ComPtr<IMFMediaType> nativeType;
    if (SUCCEEDED(m_sourceReader->GetNativeMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &nativeType))) {
        UINT64 duration = 0;
        if (SUCCEEDED(m_sourceReader->GetPresentationAttribute(
                (DWORD)MF_SOURCE_READER_MEDIASOURCE,
                MF_PD_DURATION, &duration))) {
            m_duration = static_cast<double>(duration) / 10000000.0;
        }

        UINT32 w = 0, h = 0;
        MFGetAttributeSize(nativeType.Get(), MF_MT_FRAME_SIZE, &w, &h);
        m_width = w;
        m_height = h;

        UINT32 num = 0, denom = 1;
        MFGetAttributeRatio(nativeType.Get(), MF_MT_FRAME_RATE, &num, &denom);
        if (num == 0) { num = 30; denom = 1; }
        m_numerator = num;
        m_denominator = denom;
    }

    return true;
}

bool VideoRendererMF::configureSourceReader() {
    // Get the first video stream
    HRESULT hr = m_sourceReader->SetStreamSelection(
        (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (FAILED(hr)) return false;

    hr = m_sourceReader->SetStreamSelection(
        (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(hr)) return false;

    // Set output format to NV12 (widely supported for hardware decode)
    ComPtr<IMFMediaType> outputType;
    MFCreateMediaType(&outputType);
    outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    outputType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

    hr = m_sourceReader->SetCurrentMediaType(
        (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
        nullptr, outputType.Get());

    // Fallback to any video format if NV12 is not supported
    if (FAILED(hr)) {
        // Just use the native type
    }

    return true;
}

bool VideoRendererMF::createDirectXResources() {
    // Create D3D11 device
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#ifdef _DEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    D3D_FEATURE_LEVEL featureLevels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0
    };

    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
        featureLevels, ARRAYSIZE(featureLevels),
        D3D11_SDK_VERSION, &m_d3dDevice, nullptr, &m_d3dContext);

    if (FAILED(hr)) return false;

    // Create DXGI factory
    ComPtr<IDXGIDevice> dxgiDevice;
    hr = m_d3dDevice.As(&dxgiDevice);
    if (FAILED(hr)) return false;

    ComPtr<IDXGIAdapter> adapter;
    dxgiDevice->GetAdapter(&adapter);

    ComPtr<IDXGIFactory2> factory;
    adapter->GetParent(IID_PPV_ARGS(&m_dxgiFactory));

    // Create D2D factory and device
    D2D1_FACTORY_OPTIONS d2dOptions = {};
#ifdef _DEBUG
    d2dOptions.debugLevel = D2D1_DEBUG_LEVEL_INFORMATION;
#endif

    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                           __uuidof(ID2D1Factory1), &d2dOptions,
                           (void**)m_d2dFactory.GetAddressOf());
    if (FAILED(hr)) return false;

    hr = m_d2dFactory->CreateDevice(dxgiDevice.Get(), &m_d2dDevice);
    if (FAILED(hr)) return false;

    hr = m_d2dDevice->CreateDeviceContext(
        D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &m_d2dContext);
    if (FAILED(hr)) return false;

    return true;
}

bool VideoRendererMF::createWallpaperWindow() {
    // Register window class
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = VideoWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"MirageVideoRendererW";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    RegisterClassExW(&wc);

    // Get monitor dimensions
    POINT pt = {};
    HMONITOR hMonitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = { sizeof(MONITORINFO) };
    GetMonitorInfoW(hMonitor, &mi);

    m_windowWidth = mi.rcMonitor.right - mi.rcMonitor.left;
    m_windowHeight = mi.rcMonitor.bottom - mi.rcMonitor.top;

    // Create window
    m_hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"MirageVideoRendererW",
        L"Mirage Video Wallpaper",
        WS_POPUP,
        mi.rcMonitor.left, mi.rcMonitor.top,
        m_windowWidth, m_windowHeight,
        nullptr, nullptr,
        GetModuleHandleW(nullptr),
        nullptr
    );

    if (!m_hwnd) return false;

    // Embed into wallpaper layer
    embedIntoWallpaperLayer();

    // Create swapchain for the window
    DXGI_SWAP_CHAIN_DESC1 swapDesc = {};
    swapDesc.Width = m_windowWidth;
    swapDesc.Height = m_windowHeight;
    swapDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swapDesc.BufferCount = 2;
    swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swapDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    swapDesc.SampleDesc.Count = 1;
    swapDesc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    HRESULT hr = m_dxgiFactory->CreateSwapChainForHwnd(
        m_d3dDevice.Get(), m_hwnd, &swapDesc,
        nullptr, nullptr, &m_swapChain);

    if (FAILED(hr)) {
        // Hwnd swapchain not supported (e.g. on D3D11On12), try composition
        hr = m_dxgiFactory->CreateSwapChainForComposition(
            m_d3dDevice.Get(), &swapDesc, nullptr, &m_swapChain);
    }

    if (FAILED(hr)) return false;

    updateRenderTarget();

    ShowWindow(m_hwnd, SW_SHOW);
    UpdateWindow(m_hwnd);

    return true;
}

bool VideoRendererMF::embedIntoWallpaperLayer() {
    HWND hwndProgman = FindWindowW(L"Progman", nullptr);
    if (!hwndProgman) return false;

    SendMessageTimeoutW(hwndProgman, 0x052C, 0, 0, SMTO_NORMAL, 1000, nullptr);

    HWND hwndWorkerW = findWorkerW();
    if (!hwndWorkerW) {
        Sleep(500);
        hwndWorkerW = findWorkerW();
    }
    if (!hwndWorkerW) return false;

    SetParent(m_hwnd, hwndWorkerW);
    SetWindowPos(m_hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

    return true;
}

HWND VideoRendererMF::findWorkerW() {
    HWND result = nullptr;
    EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
        wchar_t className[64];
        GetClassNameW(hwnd, className, 64);
        if (wcscmp(className, L"WorkerW") == 0) {
            HWND defView = FindWindowExW(hwnd, nullptr, L"SHELLDLL_DefView", nullptr);
            if (defView) {
                *(HWND*)lParam = hwnd;
                return FALSE;
            }
        }
        return TRUE;
    }, (LPARAM)&result);
    return result;
}

void VideoRendererMF::updateRenderTarget() {
    // Release current targets before resize
    m_d2dBitmap = nullptr;
    m_d2dContext->SetTarget(nullptr);
    m_renderTargetView = nullptr;

    m_swapChain->ResizeBuffers(2, m_windowWidth, m_windowHeight,
                               DXGI_FORMAT_B8G8R8A8_UNORM, 0);

    ComPtr<ID3D11Texture2D> backBuffer;
    m_swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    m_d3dDevice->CreateRenderTargetView(backBuffer.Get(), nullptr, &m_renderTargetView);

    // Create D2D render target bitmap from the DXGI surface
    ComPtr<IDXGISurface> dxgiSurface;
    if (SUCCEEDED(backBuffer.As(&dxgiSurface))) {
        D2D1_BITMAP_PROPERTIES1 bitmapProps = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
            96.0f, 96.0f
        );
        if (SUCCEEDED(m_d2dContext->CreateBitmapFromDxgiSurface(
                dxgiSurface.Get(), &bitmapProps, &m_d2dBitmap))) {
            m_d2dContext->SetTarget(m_d2dBitmap.Get());
        }
    }
}

// ============================================================
// Rendering
// ============================================================

bool VideoRendererMF::renderFrame() {
    if (!m_sourceReader || m_state != State::Playing) return false;

    DWORD streamIndex = 0, streamFlags = 0;
    LONGLONG sampleTime = 0;
    ComPtr<IMFSample> sample;

    HRESULT hr = m_sourceReader->ReadSample(
        (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
        0, &streamIndex, &streamFlags, &sampleTime, &sample);

    if (FAILED(hr)) return false;

    // Handle end of stream → loop or stop
    if (streamFlags & MF_SOURCE_READERF_ENDOFSTREAM) {
        if (m_config.loop) {
            PROPVARIANT pos = {};
            pos.vt = VT_I8;
            pos.hVal.QuadPart = 0;
            m_sourceReader->SetCurrentPosition(GUID_NULL, pos);
            m_currentSampleTime = 0;
            return true;
        }
        m_state = State::Stopped;
        return false;
    }

    if (!sample) return true;  // No frame yet (e.g. at start), not an error

    // Merge all buffers into a single contiguous buffer
    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return false;

    BYTE* pData = nullptr;
    DWORD maxLen = 0, curLen = 0;
    hr = buffer->Lock(&pData, &maxLen, &curLen);
    if (FAILED(hr)) return false;

    const UINT32 w = m_width, h = m_height;
    const size_t bgraSize = (size_t)w * h * 4;

    if (m_convBuf.size() < bgraSize)
        m_convBuf.resize(bgraSize);

    // Determine actual subtype from reader
    ComPtr<IMFMediaType> curType;
    m_sourceReader->GetCurrentMediaType(
        (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &curType);
    GUID subtype = GUID_NULL;
    if (curType) curType->GetGUID(MF_MT_SUBTYPE, &subtype);

    // ── NV12 → BGRA (BT.601 limited range) ──────────────────────────────────
    const bool isNV12 = (subtype == MFVideoFormat_NV12)
                     || (curLen == (size_t)w * h * 3 / 2);
    if (isNV12) {
        const BYTE* Y  = pData;
        const BYTE* UV = pData + (size_t)w * h;
        BYTE* bgra = m_convBuf.data();

        for (UINT32 row = 0; row < h; ++row) {
            const BYTE* srcY  = Y  + (size_t)row * w;
            const BYTE* srcUV = UV + (size_t)(row >> 1) * w;
            BYTE*        dst  = bgra + (size_t)row * w * 4;

            for (UINT32 col = 0; col < w; ++col) {
                int y = (int)srcY[col]           - 16;
                int u = (int)srcUV[(col & ~1u)]  - 128;
                int v = (int)srcUV[(col & ~1u)+1]- 128;

                // ITU-R BT.601 fixed-point coefficients
                int r = (298*y + 409*v           + 128) >> 8;
                int g = (298*y - 100*u - 208*v   + 128) >> 8;
                int b = (298*y + 516*u            + 128) >> 8;

                dst[col*4 + 0] = (BYTE)std::clamp(b, 0, 255);
                dst[col*4 + 1] = (BYTE)std::clamp(g, 0, 255);
                dst[col*4 + 2] = (BYTE)std::clamp(r, 0, 255);
                dst[col*4 + 3] = 255;
            }
        }
    } else {
        // Assume BGRA / fallback
        size_t toCopy = std::min((size_t)curLen, bgraSize);
        memcpy(m_convBuf.data(), pData, toCopy);
        if (toCopy < bgraSize)
            memset(m_convBuf.data() + toCopy, 0, bgraSize - toCopy);
    }

    buffer->Unlock();

    // ── Upload BGRA → D2D bitmap and draw ────────────────────────────────────
    if (!m_d2dContext || !m_d2dBitmap) return false;

    D2D1_BITMAP_PROPERTIES srcBitmapProps = {
        { DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE },
        96.0f, 96.0f
    };
    ComPtr<ID2D1Bitmap> srcBitmap;
    hr = m_d2dContext->CreateBitmap(
        D2D1::SizeU(w, h),
        m_convBuf.data(), w * 4,
        srcBitmapProps,
        &srcBitmap);
    if (FAILED(hr)) return false;

    D2D1_RECT_F destRect;
    applyFillMode((float)w, (float)h, destRect);

    m_d2dContext->BeginDraw();
    m_d2dContext->Clear(D2D1::ColorF(D2D1::ColorF::Black));
    m_d2dContext->DrawBitmap(
        srcBitmap.Get(),
        &destRect,
        1.0f,
        D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
        nullptr);
    m_d2dContext->EndDraw();

    m_swapChain->Present(0, 0);
    m_currentSampleTime = sampleTime;
    return true;
}

void VideoRendererMF::applyFillMode(float videoW, float videoH,
                                     D2D1_RECT_F& destRect) {
    float windowW = static_cast<float>(m_windowWidth);
    float windowH = static_cast<float>(m_windowHeight);

    float videoAspect = videoW / videoH;
    float windowAspect = windowW / windowH;

    float drawW, drawH, offsetX, offsetY;

    switch (m_fillMode) {
    case VideoFillMode::Cover:
        if (videoAspect > windowAspect) {
            drawH = windowH;
            drawW = drawH * videoAspect;
        } else {
            drawW = windowW;
            drawH = drawW / videoAspect;
        }
        offsetX = (windowW - drawW) / 2.0f;
        offsetY = (windowH - drawH) / 2.0f;
        break;

    case VideoFillMode::Contain:
        if (videoAspect > windowAspect) {
            drawW = windowW;
            drawH = drawW / videoAspect;
        } else {
            drawH = windowH;
            drawW = drawH * videoAspect;
        }
        offsetX = (windowW - drawW) / 2.0f;
        offsetY = (windowH - drawH) / 2.0f;
        break;

    case VideoFillMode::Stretch:
    default:
        drawW = windowW;
        drawH = windowH;
        offsetX = 0;
        offsetY = 0;
        break;
    }

    destRect = { offsetX, offsetY, offsetX + drawW, offsetY + drawH };
}

// ============================================================
// Main loop
// ============================================================

int VideoRendererMF::run() {
    if (!m_initialized) return -1;
    m_running = true;

    // Start command reader thread
    std::thread cmdThread(&VideoRendererMF::commandReaderThread, this);

    // Set timer for frame pacing
    double frameInterval = (m_config.targetFps > 0) ?
        1000.0 / m_config.targetFps :
        1000.0 * m_denominator / m_numerator;

    UINT timerId = SetTimer(m_hwnd, 1, static_cast<UINT>(frameInterval), nullptr);

    // Auto-play
    play();

    // Message loop
    MSG msg = {};
    while (m_running && GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    KillTimer(m_hwnd, timerId);
    if (cmdThread.joinable()) cmdThread.join();

    return 0;
}

void VideoRendererMF::commandReaderThread() {
    std::string line;
    while (m_running) {
        std::getline(std::cin, line);
        if (line.empty()) continue;

        if (line == "quit") {
            shutdown();
        } else if (line == "play") {
            play();
        } else if (line == "pause") {
            pause();
        } else if (line == "toggle") {
            togglePause();
        } else if (line == "mutetoggle") {
            toggleMuted();
        } else if (line.starts_with("volume ")) {
            float vol = 0.0f;
            try { vol = std::stof(line.substr(7)); }
            catch (...) {}
            setVolume(vol);
        } else if (line.starts_with("mute")) {
            setMuted(true);
        } else if (line.starts_with("unmute")) {
            setMuted(false);
        } else if (line.starts_with("seek ")) {
            float sec = 0.0f;
            try { sec = std::stof(line.substr(5)); }
            catch (...) {}
            seek(sec);
        } else if (line.starts_with("speed ")) {
            float spd = 1.0f;
            try { spd = std::stof(line.substr(6)); }
            catch (...) {}
            setSpeed(spd);
        } else if (line.starts_with("skip ")) {
            double sec = 0.0;
            try { sec = std::stod(line.substr(5)); }
            catch (...) {}
            skipNext(sec);
        }
    }
}

// ============================================================
// Playback Control
// ============================================================

void VideoRendererMF::play() {
    m_state = State::Playing;
    m_lastFrameTime = std::chrono::steady_clock::now();
    printf("{\"event\":\"playing\"}\n");
    fflush(stdout);
}

void VideoRendererMF::pause() {
    m_state = State::Paused;
    m_pauseTime = std::chrono::steady_clock::now();
    printf("{\"event\":\"paused\"}\n");
    fflush(stdout);
}

void VideoRendererMF::togglePause() {
    if (m_state == State::Playing) pause(); else play();
}

void VideoRendererMF::seek(float seconds) {
    PROPVARIANT pos;
    pos.vt = VT_I8;
    pos.hVal.QuadPart = static_cast<LONGLONG>(seconds * 10000000.0);
    m_sourceReader->SetCurrentPosition(GUID_NULL, pos);
    m_currentSampleTime = pos.hVal.QuadPart;
}

void VideoRendererMF::setVolume(float volume) {
    m_volume = std::clamp(volume, 0.0f, 1.0f);
}

void VideoRendererMF::setMuted(bool muted) {
    m_muted = muted;
}

void VideoRendererMF::toggleMuted() {
    m_muted = !m_muted;
    printf("{\"event\":\"muted\",\"value\":%s}\n", m_muted ? "true" : "false");
    fflush(stdout);
}

void VideoRendererMF::setSpeed(float speed) {
    m_speed = std::max(0.1f, std::min(speed, 16.0f));

    // Adjust presentation descriptor for speed
    ComPtr<IMFMediaSource> source;
    if (SUCCEEDED(m_sourceReader->GetServiceForStream(
            (DWORD)MF_SOURCE_READER_MEDIASOURCE, GUID_NULL,
            IID_PPV_ARGS(&source)))) {
        ComPtr<IMFRateControl> rateControl;
        if (SUCCEEDED(source.As(&rateControl))) {
            rateControl->SetRate(FALSE, m_speed);
        }
    }
}

void VideoRendererMF::setFillMode(VideoFillMode mode) {
    m_fillMode = mode;
}

void VideoRendererMF::skipNext(double seconds) {
    LONGLONG target = m_currentSampleTime + static_cast<LONGLONG>(seconds * 10000000.0);
    PROPVARIANT pos;
    pos.vt = VT_I8;
    pos.hVal.QuadPart = target;
    m_sourceReader->SetCurrentPosition(GUID_NULL, pos);
    m_currentSampleTime = target;
}

double VideoRendererMF::currentTime() const {
    return static_cast<double>(m_currentSampleTime) / 10000000.0;
}

// ============================================================
// Shutdown
// ============================================================

void VideoRendererMF::shutdown() {
    m_running = false;
    m_state = State::Stopped;

    m_renderTargetView = nullptr;
    m_swapChain = nullptr;
    m_d2dBitmap = nullptr;
    m_d2dContext = nullptr;
    m_d2dDevice = nullptr;
    m_d2dFactory = nullptr;
    m_d3dContext = nullptr;
    m_d3dDevice = nullptr;
    m_sourceReader = nullptr;
    m_mediaSource = nullptr;

    if (m_hwnd) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }

    UnregisterClassW(L"MirageVideoRendererW", GetModuleHandleW(nullptr));
    MFShutdown();
    m_initialized = false;
}

} // namespace SceneRenderer::VideoRenderer
