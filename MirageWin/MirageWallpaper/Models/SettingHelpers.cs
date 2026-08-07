using MirageWallpaper.Models;

namespace MirageWallpaper.Models;

public static class GSPlaybackHelpers
{
    public static GSPlayback[] All { get; } = Enum.GetValues<GSPlayback>();

    public static string ToDisplayString(this GSPlayback p) => p switch
    {
        GSPlayback.KeepRunning => "继续运行",
        GSPlayback.Mute => "静音",
        GSPlayback.Pause => "暂停",
        GSPlayback.Stop => "停止",
        _ => p.ToString()
    };
}

public static class GSAntiAliasingHelpers
{
    public static GSAntiAliasingQuality[] All { get; } = Enum.GetValues<GSAntiAliasingQuality>();

    public static string ToDisplayString(this GSAntiAliasingQuality q) => q switch
    {
        GSAntiAliasingQuality.None => "关闭",
        GSAntiAliasingQuality.MsaaX2 => "2x MSAA",
        GSAntiAliasingQuality.MsaaX4 => "4x MSAA",
        GSAntiAliasingQuality.MsaaX8 => "8x MSAA",
        _ => q.ToString()
    };
}

public static class GSTextureResolutionHelpers
{
    public static GSTextureResolutionQuality[] All { get; } = Enum.GetValues<GSTextureResolutionQuality>();

    public static string ToDisplayString(this GSTextureResolutionQuality q) => q switch
    {
        GSTextureResolutionQuality.HighQuality => "高质量",
        GSTextureResolutionQuality.HighPerformance => "高性能",
        GSTextureResolutionQuality.Automatic => "自动",
        _ => q.ToString()
    };
}

public static class GSLoadSourceHelpers
{
    public static GSWallpaperLoadSource[] All { get; } = Enum.GetValues<GSWallpaperLoadSource>();

    public static string ToDisplayString(this GSWallpaperLoadSource s) => s switch
    {
        GSWallpaperLoadSource.Disk => "磁盘加载",
        GSWallpaperLoadSource.Memory => "内存加载",
        _ => s.ToString()
    };
}

public static class GSAppearanceHelpers
{
    public static GSAppearance[] All { get; } = Enum.GetValues<GSAppearance>();

    public static string ToDisplayString(this GSAppearance a) => a switch
    {
        GSAppearance.Light => "浅色",
        GSAppearance.Dark => "深色",
        GSAppearance.FollowSystem => "跟随系统",
        _ => a.ToString()
    };
}

public static class GSSteamAPIHelpers
{
    public static GSSteamAPIEndpoint[] All { get; } = Enum.GetValues<GSSteamAPIEndpoint>();

    public static string ToDisplayString(this GSSteamAPIEndpoint e) => e switch
    {
        GSSteamAPIEndpoint.Official => "官方",
        GSSteamAPIEndpoint.Mirror => "镜像",
        _ => e.ToString()
    };
}

public static class GSLogLevelHelpers
{
    public static GSLogLevel[] All { get; } = Enum.GetValues<GSLogLevel>();

    public static string ToDisplayString(this GSLogLevel l) => l switch
    {
        GSLogLevel.Error => "仅错误",
        GSLogLevel.Verbose => "详细",
        GSLogLevel.None => "关闭",
        _ => l.ToString()
    };
}
