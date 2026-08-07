# VideoRenderer CMakeLists - Media Foundation-based video wallpaper renderer
# Requires: Windows 10+, DirectX 11, Media Foundation

cmake_minimum_required(VERSION 3.21)

set(TARGET_NAME VideoWallpaperWin)

add_executable(${TARGET_NAME} WIN32
    VideoRendererMF.cpp
    VideoRendererMF.h
    VideoWallpaperMain_win32.cpp
)

target_compile_features(${TARGET_NAME} PRIVATE cxx_std_20)

# Windows SDK libraries
target_link_libraries(${TARGET_NAME} PRIVATE
    # Windows APIs
    user32 gdi32 shell32 dwmapi shlwapi ole32

    # Media Foundation
    mfplat mfreadwrite mfuuid strmiids

    # DirectX
    d3d11 d3dcompiler dxgi dxguid

    # D2D for rendering
    d2d1
)

# Set subsystem to Windows (no console)
set_target_properties(${TARGET_NAME} PROPERTIES
    WIN32_EXECUTABLE TRUE)

message(STATUS "VideoWallpaperWin configured (Media Foundation)")
