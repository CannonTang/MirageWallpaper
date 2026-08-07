# build.ps1 — SceneRenderer Windows build script
# Usage: .\build.ps1 [-Clean] [-Config Release|Debug]
param([switch]$Clean, [string]$Config = "Release")

$ErrorActionPreference = "Stop"

# --- Environment setup ---
$VsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community"
$VulkanSdk = "C:\VulkanSDK\1.4.350.0"
$VcpkgRoot = "C:\vcpkg"

# Enter VS Dev Shell
Import-Module "$VsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll" -ErrorAction Stop
Enter-VsDevShell -VsInstallPath $VsPath -DevCmdArguments "-arch=amd64" -SkipAutomaticLocation | Out-Null

# Add LLVM, CMake, Ninja, Vulkan to PATH
$env:PATH = @(
    "C:\Program Files\LLVM\bin"
    "C:\Program Files\CMake\bin"
    "$VulkanSdk\Bin"
    "C:\Users\pikachuren\AppData\Local\Microsoft\WinGet\Links"
    $env:PATH
) -join ";"

Write-Host "=== Build Tools ===" -ForegroundColor Cyan
clang++ --version 2>&1 | Select-Object -First 2
cmake --version 2>&1 | Select-Object -First 1
Write-Host ""

# --- Build directory ---
$BuildDir = Join-Path $PSScriptRoot "build\w7"
if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host "Cleaning build directory..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $BuildDir
}

# --- Configure ---
Write-Host "=== Configuring ($Config) ===" -ForegroundColor Cyan
$cmakeArgs = @(
    "-S", $PSScriptRoot,
    "-B", $BuildDir,
    "-G", "Ninja",
    "-DCMAKE_CXX_COMPILER=clang++",
    "-DCMAKE_C_COMPILER=clang",
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot/scripts/buildsystems/vcpkg.cmake",
    "-DVCPKG_TARGET_TRIPLET=x64-windows"
)

& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "CONFIGURE FAILED" -ForegroundColor Red
    exit 1
}

# --- Build ---
Write-Host "`n=== Building ===" -ForegroundColor Cyan
& cmake --build $BuildDir --config $Config -j 8
if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== BUILD SUCCEEDED ===" -ForegroundColor Green
Write-Host "Output: $BuildDir\SceneWallpaperWin.exe" -ForegroundColor Green
