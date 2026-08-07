using System.Text.Json.Serialization;

namespace MirageWallpaper.Models;

public enum WallpaperKind
{
    Scene,
    Video,
    Web,
    Unsupported,
    Invalid
}

public enum FillMode
{
    Cover,
    Contain,
    Stretch
}

public enum ContentRating
{
    General,
    Mature,
    Questionable,
    Unknown
}

public enum WallpaperSource
{
    Local,
    SteamWorkshop,
    Imported
}

public record WallpaperModel
{
    public string Id { get; init; } = string.Empty;
    public string Title { get; init; } = string.Empty;
    public WallpaperKind Kind { get; init; }
    public string Directory { get; init; } = string.Empty;
    public WallpaperSource Source { get; init; } = WallpaperSource.Local;
    public ContentRating Rating { get; init; } = ContentRating.Unknown;
    public string[] Tags { get; init; } = [];
    public string? WorkshopId { get; init; }
    public string? PreviewPath { get; init; }
    public DateTime AddedAt { get; init; } = DateTime.Now;
    public DateTime LastUsedAt { get; init; } = DateTime.Now;
    public bool IsFavorite { get; init; }
    public string? Author { get; init; }
    public string? Description { get; init; }
    public long SizeBytes { get; init; }

    public bool IsValid => Kind != WallpaperKind.Invalid && Kind != WallpaperKind.Unsupported;

    public bool IsSceneWallpaper => Kind == WallpaperKind.Scene;
    public bool IsWebWallpaper => Kind == WallpaperKind.Web;
    public bool IsVideoWallpaper => Kind == WallpaperKind.Video;

    [JsonIgnore]
    public string KindDisplay => Kind switch
    {
        WallpaperKind.Scene => "场景",
        WallpaperKind.Video => "视频",
        WallpaperKind.Web => "网页",
        WallpaperKind.Unsupported => "不支持",
        _ => "无效"
    };

    [JsonIgnore]
    public string RatingDisplay => Rating switch
    {
        ContentRating.General => "全年龄",
        ContentRating.Mature => "成人",
        ContentRating.Questionable => "敏感",
        _ => "未知"
    };

    [JsonIgnore]
    public string SourceDisplay => Source switch
    {
        WallpaperSource.SteamWorkshop => "创意工坊",
        WallpaperSource.Imported => "已导入",
        _ => "本地"
    };
}

public record WallpaperRuntimeState
{
    public float Volume { get; init; } = 1.0f;
    public float Speed { get; init; } = 1.0f;
    public bool Muted { get; init; }
    public FillMode FillMode { get; init; } = FillMode.Cover;
    public Dictionary<string, WEPropertyValue> PropertyOverrides { get; init; } = new();
}
