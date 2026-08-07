cmake_minimum_required(VERSION 3.28)

# ---------------------------------------------------------------------------
# SceneRenderer — Windows independent CMake project.
#
# Builds the SceneRenderer engine (8 static libraries via C++20 modules) plus
# the SceneWallpaperWin.exe host from a self-contained cmake tree that shares
# no build logic with the macOS CMakeLists.txt.
#
# Prerequisites:
#   vcpkg install vulkan ffmpeg freetype lz4 fontconfig pkgconf
#   (or the equivalent cmake preset that injects the toolchain)
# ---------------------------------------------------------------------------

project(SceneRendererWin
    VERSION 0.1.8
    LANGUAGES C CXX)

# Enable C++20 module support
# CMake 3.28-3.30: requires experimental API UUID
# CMake 4.0+: built-in (the UUID variable was removed)
set(CMAKE_CXX_SCAN_FOR_MODULES ON)
if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.28" AND CMAKE_VERSION VERSION_LESS "4.0")
    set(CMAKE_EXPERIMENTAL_CXX_MODULE_CMAKE_API "2182bf5c-ef0d-489a-91da-49dbc3090d2a")
endif()

# clang-cl: enable C++20 modules + relaxed submodule visibility
# for rstd::Impl friend declarations across module partitions
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    add_compile_options(
        "-Xclang;-fmodules-local-submodule-visibility")
endif()

# --- Paths ---
get_filename_component(SR_ROOT ${CMAKE_CURRENT_LIST_DIR}/.. ABSOLUTE)
set(ENGINE_SRC ${SR_ROOT}/Sources/SceneRenderer)

# --- C++20 standard ---
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# --- wavsen audio backend: stub on Windows (no PulseAudio / CoreAudio) ---
set(WAVSEN_AUDIO_BACKEND "stub" CACHE STRING
    "Audio backend (stub on Windows; WASAPI appended separately)")

# --- Dependencies (vcpkg) ---
find_package(Vulkan REQUIRED)
find_package(Freetype REQUIRED)
find_package(lz4 CONFIG REQUIRED)
find_package(PkgConfig REQUIRED)

# fontconfig: optional on Windows (vcpkg install may take long; fallback to NOTFOUND)
find_package(fontconfig QUIET)
if(fontconfig_FOUND)
    set(FONTCONFIG_LIBS PkgConfig::FONTCONFIG)
else()
    message(STATUS "fontconfig not found — SceneRendererImporter will lack system font lookup")
    set(FONTCONFIG_LIBS "") # empty fallback
endif()

# FFmpeg via pkg-config (vcpkg provides .pc files)
pkg_check_modules(FFMPEG IMPORTED_TARGET
    libavformat libavcodec libavutil libswscale libswresample)
if(NOT FFMPEG_FOUND)
    message(WARNING "FFmpeg not found via pkg-config — video decoding will be unavailable")
endif()

# Threads
find_package(Threads REQUIRED)
if(CMAKE_USE_PTHREADS_INIT)
    add_compile_options("$<$<COMPILE_LANG_AND_ID:CXX,Clang,GNU>:-pthread>")
    add_link_options("$<$<LINK_LANG_AND_ID:CXX,Clang,GNU>:-pthread>")
endif()

# --- Windows POSIX compatibility shims ---
# Prepend windows/compat/ so #include <unistd.h> (and other POSIX headers
# missing on Windows) resolve to our stubs rather than a "file not found" error.
if(WIN32)
    include_directories(${CMAKE_CURRENT_LIST_DIR}/compat)
endif()

# Work around Clang 19 + MSVC STL 14.43 incompatibility.
# The STL's <memory> uses 'friend' on using-declarations (e.g.
# friend shared_ptr<_Ty> make_shared(...)), which Clang 19 rejects.
# Disabling shared_ptr feature detection makes the STL skip those
# friend declarations, producing code that Clang 19 can compile.
# Fixed upstream in Clang 20+.
# MUST be set before add_subdirectory() so all targets inherit it.
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -D__cpp_lib_shared_ptr=0 -D__cpp_lib_smart_ptr_for_overwrite=0 -D__cpp_lib_make_unique=0")
endif()

# --- Vendor (third-party libraries) ---
include_directories(SYSTEM ${SR_ROOT}/Vendor)
add_subdirectory(${SR_ROOT}/Vendor ${CMAKE_BINARY_DIR}/vendor)

# Windows ABI workaround: rstd nonzero niche optimization assumes
# sizeof(Option<NonZero<u64>>) == sizeof(u64), which holds on LP64 but
# not on LLP64 (Windows). Disable the static_assert until rstd adapts.
if(TARGET rstd.core)
    target_compile_definitions(rstd.core PRIVATE
        RSTD_WINDOWS_ABI_WORKAROUND=1)
endif()

# --- WASAPI audio backend ---
# M1: WASAPI sources forward-declare wavsen module types but are compiled
# outside the wavsen_audio module target (cannot be added via target_sources
# due to Clang module scanner conflicts).  This causes ODR violations at link
# time because AudioDevice::Impl defined here differs from the module's Impl.
#
# For M1, audio is provided by the wavsen stub backend (no-op).
# WASAPI integration is deferred to M4 when the wavsen module interface
# is refactored to support PIMPL registration from external TUs.
option(ENABLE_WASAPI "Build with WASAPI audio backend (experimental)" OFF)
if(ENABLE_WASAPI)
    set(WASAPI_SOURCES
        ${SR_ROOT}/Vendor/wavsen/src/audio/audio_device_wasapi.cpp
        ${SR_ROOT}/Vendor/wavsen/src/audio/audio_capture_wasapi.cpp)
    message(WARNING "WASAPI enabled — may cause ODR/link errors with wavsen module types")
else()
    set(WASAPI_SOURCES "")
endif()

# --- Engine targets (replicates macOS CMake structure) ---
include(cmake/EngineTargets.cmake)

# --- SceneWallpaperWin executable ---
add_executable(SceneWallpaperWin
    ${SR_ROOT}/Tools/SceneWallpaper/WallpaperApp_win32.cpp
    ${SR_ROOT}/Sources/SceneRenderer/Host/win32/ControlChannel_win32.cpp
    ${SR_ROOT}/Sources/SceneRenderer/Host/win32/WinDesktopHost.cpp
    ${SR_ROOT}/Sources/SceneRenderer/Host/win32/WinWallpaperWindow.cpp
    ${SR_ROOT}/Sources/SceneRenderer/Host/win32/WinSwapchainPresenter.cpp
    ${WASAPI_SOURCES})

target_include_directories(SceneWallpaperWin PRIVATE
    ${SR_ROOT}/Tools/SceneWallpaper
    ${SR_ROOT}/Sources/SceneRenderer/Host/win32)

target_compile_definitions(SceneWallpaperWin PRIVATE
    $<$<BOOL:${ENABLE_WASAPI}>:WAVSEN_AUDIO_BACKEND_WASAPI>)

target_link_libraries(SceneWallpaperWin PRIVATE
    SceneRendererRenderer
    Vulkan::Vulkan
    dwmapi user32 gdi32 dbghelp ole32)

# C++20 modules support
set_property(TARGET SceneWallpaperWin PROPERTY CXX_SCAN_FOR_MODULES ON)
target_compile_features(SceneWallpaperWin PRIVATE cxx_std_20)

# Keep console window for log output (Windows subsystem)
set_target_properties(SceneWallpaperWin PROPERTIES WIN32_EXECUTABLE FALSE)

# ---------------------------------------------------------------------------
# M2: WebRenderer — WebView2-based web wallpaper renderer
# ---------------------------------------------------------------------------
option(BUILD_WEB_RENDERER "Build the WebView2 web wallpaper renderer" ON)
if(BUILD_WEB_RENDERER)
    if(EXISTS "${SR_ROOT}/Sources/WebRenderer/CMakeLists.txt")
        add_subdirectory(${SR_ROOT}/Sources/WebRenderer
                        ${CMAKE_BINARY_DIR}/WebRenderer)
    endif()
endif()

# ---------------------------------------------------------------------------
# M3: VideoRenderer — Media Foundation video wallpaper renderer
# ---------------------------------------------------------------------------
option(BUILD_VIDEO_RENDERER "Build the Media Foundation video wallpaper renderer" ON)
if(BUILD_VIDEO_RENDERER)
    if(EXISTS "${SR_ROOT}/Sources/VideoRenderer/CMakeLists.txt")
        add_subdirectory(${SR_ROOT}/Sources/VideoRenderer
                        ${CMAKE_BINARY_DIR}/VideoRenderer)
    endif()
endif()
