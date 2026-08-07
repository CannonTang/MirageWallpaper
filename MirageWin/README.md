# Mirage Wallpaper for Windows (WinUI 3)

基于 WinUI 3 的 Windows 动态壁纸管理器。

## 前置条件

1. **Visual Studio 2022** (17.x+)
   - 安装 "Windows 应用程序开发" 工作负载
   - 安装 .NET 8.0 SDK

2. **Windows App SDK**
   - 在 Visual Studio Installer 中安装 Windows App SDK 组件
   - 或运行: `winget install Microsoft.WindowsAppSDK`

3. **WebView2 Runtime** (Web 壁纸渲染)
   - 通常预装在 Windows 10/11 中
   - 或从 https://developer.microsoft.com/microsoft-edge/webview2/ 安装

## 项目结构

```
MirageWin/
├── MirageWallpaper.sln            # VS解决方案
├── README.md
└── MirageWallpaper/
    ├── MirageWallpaper.csproj     # 项目文件 (WinUI 3)
    ├── App.xaml / App.xaml.cs     # 应用入口
    ├── app.manifest               # DPI 感知配置
    ├── Models/
    │   ├── WallpaperModel.cs      # 壁纸数据模型
    │   ├── WEProject.cs           # Wallpaper Engine project.json 解析
    │   ├── Settings.cs            # 全局设置枚举和模型
    │   └── SettingHelpers.cs      # 枚举显示辅助类
    ├── Services/
    │   ├── SettingsService.cs     # 设置持久化
    │   ├── WallpaperLibraryService.cs  # 壁纸库管理
    │   ├── RendererService.cs     # 渲染器进程管理
    │   └── SteamCMDService.cs     # SteamCMD 集成
    ├── ViewModels/
    │   ├── MainViewModel.cs       # 主窗口 MVVM ViewModel
    │   └── SettingsViewModel.cs   # 设置页 ViewModel
    └── Views/
        ├── MainWindow.xaml/cs     # 主窗口
        ├── SettingsPage.xaml/cs   # 设置页面
        └── WallpaperPreviewControl.xaml/cs  # 壁纸预览面板
```

## 构建

在 Visual Studio 2022 中:
1. 打开 `MirageWallpaper.sln`
2. 选择 x64 平台
3. 按 F5 构建并运行

命令行构建 (需要 VS Dev Prompt 或 .NET 8 SDK + Windows App SDK 工作负载):

```powershell
dotnet workload install windows
cd MirageWallpaper
dotnet restore
dotnet build
```

## 功能对应关系

| macOS Mirage App | WinUI 3 MirageApp |
|---|---|
| ContentView (SwiftUI) | MainWindow (XAML) |
| WallpaperViewModel | MainViewModel.cs |
| GlobalSettingsService | SettingsService.cs |
| WallpaperLibrary | WallpaperLibraryService.cs |
| WEProject | WEProject.cs (models) |
| SteamCMDManager | SteamCMDService.cs |
| StatusBarController | MainWindow bottom bar |
| Settings | SettingsPage.xaml |

## 渲染器

WinUI 3 壁纸管理器启动独立的渲染器进程:

- **SceneWallpaperWin.exe** - 场景壁纸 (Vulkan)
- **WebWallpaperWin.exe** - 网页壁纸 (WebView2)
- **VideoWallpaperWin.exe** - 视频壁纸 (Media Foundation)

通信通过 stdin/stdout JSON 管道进行。
