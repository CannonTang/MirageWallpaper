#include "WebRendererWindows.h"
#include <windows.h>
#include <string>
#include <iostream>
#include <filesystem>
#include <fstream>

// Entry point for WebWallpaperWin.exe
// Usage: WebWallpaperWin.exe <project_dir>
//   Reads commands from stdin, renders web wallpaper from project_dir/project.json

using namespace SceneRenderer::WebRenderer;

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR lpCmdLine, int nCmdShow) {
    // Parse command line
    int argc;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    if (argc < 2) {
        MessageBoxW(nullptr, L"Usage: WebWallpaperWin.exe <project_dir>", L"Mirage Web Wallpaper", MB_OK);
        return 1;
    }

    std::filesystem::path projectDir(argv[1]);
    LocalFree(argv);

    if (!std::filesystem::exists(projectDir)) {
        MessageBoxW(nullptr, L"Project directory not found", L"Error", MB_OK);
        return 1;
    }

    // Load project.json
    std::string projectJsonPath = (projectDir / "project.json").string();
    std::string htmlPath;

    // Read HTML file from project.json
    std::ifstream configFile(projectJsonPath);
    if (configFile.is_open()) {
        std::string line;
        while (std::getline(configFile, line)) {
            // Find the "file" field to get HTML path
            size_t pos = line.find("\"file\"");
            if (pos != std::string::npos) {
                pos = line.find(':', pos);
                if (pos != std::string::npos) {
                    size_t start = line.find('"', pos) + 1;
                    size_t end = line.find('"', start);
                    if (start != std::string::npos && end != std::string::npos) {
                        htmlPath = line.substr(start, end - start);
                    }
                }
            }
        }
    }

    if (htmlPath.empty()) {
        // Try index.html as default
        htmlPath = "index.html";
    }

    // Build full file:// URL
    std::filesystem::path fullHtmlPath = projectDir / htmlPath;
    std::string url = "file:///" + fullHtmlPath.string();
    // Replace backslashes with forward slashes for file:// URLs
    std::replace(url.begin(), url.end(), '\\', '/');

    // Configure WebRenderer
    WebRendererConfig config;
    config.url = url;
    config.projectDir = projectDir.string();
    config.fps = 30;
    config.volume = 1.0f;
    config.muted = false;
    config.transparent = false;

    // Parse additional options from command line
    for (int i = 2; i < argc; i++) {
        // (parsed earlier, skip)
    }

    // Check for --debug flag
    std::wstring cmdLine(lpCmdLine);
    if (cmdLine.find(L"--debug") != std::wstring::npos) {
        config.debug = true;
    }

    // Initialize COM for WebView2
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) {
        MessageBoxW(nullptr, L"Failed to initialize COM", L"Error", MB_OK);
        return 1;
    }

    // Create renderer
    WebRendererWin renderer;
    if (!renderer.initialize(config)) {
        CoUninitialize();
        MessageBoxW(nullptr, L"Failed to initialize WebRenderer", L"Error", MB_OK);
        return 1;
    }

    // Run message loop (blocks until quit)
    int result = renderer.run();

    CoUninitialize();
    return result;
}
