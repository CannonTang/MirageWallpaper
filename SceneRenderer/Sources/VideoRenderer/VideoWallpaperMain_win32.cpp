#include "VideoRendererMF.h"
#include <windows.h>
#include <shellapi.h>
#include <filesystem>

using namespace SceneRenderer::VideoRenderer;

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR lpCmdLine, int nCmdShow) {
    int argc;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    if (argc < 2) {
        MessageBoxW(nullptr, L"Usage: VideoWallpaperWin.exe <video_file> [options]\n"
            L"  --screen N    Target monitor index (default: 0)\n"
            L"  --fps N       Target FPS (0 = native)\n"
            L"  --muted       Start muted\n"
            L"  --volume V    Volume 0.0-1.0\n"
            L"  --fill MODE   Cover/Contain/Stretch\n"
            L"  --no-loop     Do not loop",
            L"Mirage Video Wallpaper", MB_OK);
        return 1;
    }

    VideoRendererConfig config;
    config.filePath = argv[1];
    config.loop = true;
    config.volume = 1.0f;

    for (int i = 2; i < argc; i++) {
        std::wstring arg(argv[i]);
        if (arg == L"--muted") {
            config.muted = true;
        } else if (arg == L"--no-loop") {
            config.loop = false;
        } else if ((arg == L"--screen" || arg == L"-s") && i + 1 < argc) {
            config.screenIndex = _wtoi(argv[++i]);
        } else if ((arg == L"--fps" || arg == L"-f") && i + 1 < argc) {
            config.targetFps = _wtoi(argv[++i]);
        } else if ((arg == L"--volume" || arg == L"-V") && i + 1 < argc) {
            config.volume = _wtof(argv[++i]);
        } else if ((arg == L"--fill") && i + 1 < argc) {
            std::wstring mode(argv[++i]);
            if (mode == L"Contain") config.fillMode = VideoFillMode::Contain;
            else if (mode == L"Stretch") config.fillMode = VideoFillMode::Stretch;
            else config.fillMode = VideoFillMode::Cover;
        }
    }
    LocalFree(argv);

    if (!std::filesystem::exists(config.filePath)) {
        MessageBoxW(nullptr, L"Video file not found", L"Error", MB_OK);
        return 1;
    }

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    VideoRendererMF renderer;
    if (!renderer.initialize(config)) {
        CoUninitialize();
        MessageBoxW(nullptr, L"Failed to initialize video renderer", L"Error", MB_OK);
        return 1;
    }

    int result = renderer.run();
    CoUninitialize();

    return result;
}
