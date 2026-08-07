# WebRenderer CMakeLists - WebView2-based web wallpaper renderer
# Requires: Windows SDK 10.0.19041+, WebView2 Runtime, vcpkg

cmake_minimum_required(VERSION 3.21)

set(TARGET_NAME WebWallpaperWin)

add_executable(${TARGET_NAME} WIN32
    WebRendererWindows.cpp
    WebRendererWindows.h
    WebWallpaperMain_win32.cpp
)

target_compile_features(${TARGET_NAME} PRIVATE cxx_std_20)

# Find WebView2 (bundled with Windows/Edge, but need headers)
# Usually installed via NuGet: Microsoft.Web.WebView2
find_path(WEBVIEW2_INCLUDE_DIR
    NAMES WebView2.h
    PATHS
        "$ENV{USERPROFILE}/.nuget/packages/microsoft.web.webview2/*/build/native/include"
        "${CMAKE_SOURCE_DIR}/../packages/Microsoft.Web.WebView2.*/build/native/include"
)

if(NOT WEBVIEW2_INCLUDE_DIR)
    message(STATUS "WebView2 headers not found via NuGet. Looking for WebView2Loader.dll...")
    # Try to find WebView2 SDK via vcpkg or system
    find_path(WEBVIEW2_INCLUDE_DIR
        NAMES WebView2.h
        PATHS
            "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include"
    )
endif()

if(WEBVIEW2_INCLUDE_DIR)
    target_include_directories(${TARGET_NAME} PRIVATE ${WEBVIEW2_INCLUDE_DIR})
    message(STATUS "WebView2 headers found at: ${WEBVIEW2_INCLUDE_DIR}")
else()
    message(WARNING "WebView2 headers not found. Install via: nuget install Microsoft.Web.WebView2")
endif()

# Link libraries
target_link_libraries(${TARGET_NAME} PRIVATE
    user32 gdi32 shell32 dwmapi shlwapi ole32
)

# Copy WebView2Loader.dll to output
if(EXISTS "${WEBVIEW2_INCLUDE_DIR}/../runtimes/win-${CMAKE_VS_PLATFORM_NAME}/native/WebView2Loader.dll")
    add_custom_command(TARGET ${TARGET_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${WEBVIEW2_INCLUDE_DIR}/../runtimes/win-${CMAKE_VS_PLATFORM_NAME}/native/WebView2Loader.dll"
            "$<TARGET_FILE_DIR:${TARGET_NAME}>/WebView2Loader.dll"
        COMMENT "Copying WebView2Loader.dll to output"
    )
endif()

message(STATUS "WebWallpaperWin configured")
