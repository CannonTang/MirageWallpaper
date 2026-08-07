using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using MirageWallpaper.Models;

namespace MirageWallpaper.Services;

public class WallpaperLibraryService
{
    private readonly string _libraryPath;
    private readonly string _appDataDir;
    private readonly List<WallpaperModel> _wallpapers = [];
    private readonly JsonSerializerOptions _jsonOptions;

    // Default wallpaper search directories
    private static readonly string[] DefaultWorkshopDirs =
    [
        // Steam Workshop for Wallpaper Engine
        @"C:\Program Files (x86)\Steam\steamapps\workshop\content\431960",
        // Alternative Steam library locations
        @"C:\Steam\steamapps\workshop\content\431960",
        @"D:\Steam\steamapps\workshop\content\431960",
        @"E:\Steam\steamapps\workshop\content\431960",
    ];

    // Valid wallpaper entry-points
    private static readonly HashSet<string> ValidWebDirs = new(StringComparer.OrdinalIgnoreCase)
    {
        "index.html"
    };

    private static readonly HashSet<string> ValidVideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".webm", ".wmv", ".mov", ".avi", ".mkv"
    };

    public IReadOnlyList<WallpaperModel> Wallpapers => _wallpapers.AsReadOnly();
    public event Action? LibraryChanged;

    public WallpaperLibraryService()
    {
        _jsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
        };

        _appDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "MirageWallpaper");
        Directory.CreateDirectory(_appDataDir);
        _libraryPath = Path.Combine(_appDataDir, "library.json");
    }

    public void Load()
    {
        _wallpapers.Clear();
        var cached = LoadCachedLibrary();
        if (cached.Count > 0)
        {
            _wallpapers.AddRange(cached);
        }
        ScanAllDirectories();
        LibraryChanged?.Invoke();
    }

    public void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(_wallpapers, _jsonOptions);
            File.WriteAllText(_libraryPath, json);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WallpaperLibrary] Failed to save: {ex.Message}");
        }
    }

    public void ScanAllDirectories()
    {
        var found = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // 1. Scan Steam Workshop directories
        foreach (var wsDir in DefaultWorkshopDirs)
        {
            if (Directory.Exists(wsDir))
                ScanDirectory(wsDir, WallpaperSource.SteamWorkshop, found);
        }

        // 2. Scan my_workshop folder in app data
        var myWorkshop = Path.Combine(_appDataDir, "my_workshop");
        if (Directory.Exists(myWorkshop))
            ScanDirectory(myWorkshop, WallpaperSource.Local, found);

        // 3. Scan imported wallpapers
        var imported = Path.Combine(_appDataDir, "imported");
        if (Directory.Exists(imported))
            ScanDirectory(imported, WallpaperSource.Imported, found);

        // Clean up stale entries (directories that no longer exist)
        _wallpapers.RemoveAll(w => !Directory.Exists(w.Directory));

        Save();
        LibraryChanged?.Invoke();
    }

    private void ScanDirectory(string rootDir, WallpaperSource source, HashSet<string> found)
    {
        if (!Directory.Exists(rootDir)) return;

        foreach (var subDir in Directory.GetDirectories(rootDir))
        {
            var normalizedPath = Path.GetFullPath(subDir);
            if (!found.Add(normalizedPath)) continue;

            // Skip if already in library with same path
            if (_wallpapers.Any(w =>
                string.Equals(Path.GetFullPath(w.Directory), normalizedPath, StringComparison.OrdinalIgnoreCase)))
                continue;

            var wallpaper = DiscoverWallpaper(subDir, source);
            if (wallpaper is not null && wallpaper.IsValid)
            {
                _wallpapers.Add(wallpaper);
            }
        }
    }

    private WallpaperModel? DiscoverWallpaper(string dir, WallpaperSource source)
    {
        // Try to load project.json first (scene / web wallpapers)
        var projectJsonPath = Path.Combine(dir, "project.json");
        if (File.Exists(projectJsonPath))
        {
            return ParseProjectWallpaper(dir, projectJsonPath, source);
        }

        // Check for standalone video
        return DiscoverVideoWallpaper(dir, source);
    }

    private WallpaperModel? ParseProjectWallpaper(string dir, string projectJsonPath, WallpaperSource source)
    {
        try
        {
            var json = File.ReadAllText(projectJsonPath);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            var type = root.TryGetProperty("type", out var t) ? t.GetString() ?? "" : "";
            var title = root.TryGetProperty("title", out var ti) ? ti.GetString() ?? "" : Path.GetFileName(dir);
            var file = root.TryGetProperty("file", out var f)
                ? f.GetString() ?? ""
                : Path.GetFileName(dir);

            var wallpaper = new WallpaperModel
            {
                Id = Guid.NewGuid().ToString("N")[..12],
                Title = string.IsNullOrWhiteSpace(title) ? Path.GetFileName(dir) : title,
                Directory = dir,
                Source = source,
                Kind = ClassifyType(type),
                Author = root.TryGetProperty("description", out var dsec)
                    ? dsec.GetString()
                    : null,
                PreviewPath = FindPreviewImage(dir),
                AddedAt = File.GetCreationTime(projectJsonPath),
                LastUsedAt = DateTime.MinValue,
                Tags = ParseTags(root),
                WorkshopId = root.TryGetProperty("workshopid", out var wsid)
                    ? wsid.GetString()
                    : null,
                SizeBytes = GetDirectorySize(dir),
            };

            // Parse content rating
            if (root.TryGetProperty("contentrating", out var rating))
            {
                wallpaper = wallpaper with
                {
                    Rating = ParseRating(rating.GetString() ?? "")
                };
            }

            return wallpaper.IsValid ? wallpaper : null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WallpaperLibrary] Failed to parse {projectJsonPath}: {ex.Message}");
            return null;
        }
    }

    private WallpaperModel? DiscoverVideoWallpaper(string dir, WallpaperSource source)
    {
        // Look for video files directly in the directory
        foreach (var file in Directory.GetFiles(dir))
        {
            var ext = Path.GetExtension(file);
            if (ValidVideoExtensions.Contains(ext))
            {
                return new WallpaperModel
                {
                    Id = Guid.NewGuid().ToString("N")[..12],
                    Title = Path.GetFileNameWithoutExtension(file),
                    Kind = WallpaperKind.Video,
                    Directory = dir,
                    Source = source,
                    PreviewPath = FindPreviewImage(dir) ?? GenerateVideoThumbnailPath(file),
                    AddedAt = File.GetCreationTime(file),
                    LastUsedAt = DateTime.MinValue,
                    SizeBytes = new FileInfo(file).Length,
                };
            }
        }
        return null;
    }

    private static WallpaperKind ClassifyType(string type)
    {
        return type.ToLowerInvariant() switch
        {
            "scene" => WallpaperKind.Scene,
            "video" => WallpaperKind.Video,
            "web" => WallpaperKind.Web,
            "application" or "program" or "executable" => WallpaperKind.Unsupported,
            "" => WallpaperKind.Scene, // Default to scene if no type
            _ => WallpaperKind.Scene,
        };
    }

    private static ContentRating ParseRating(string rating)
    {
        return rating.ToLowerInvariant() switch
        {
            "general" or "g" => ContentRating.General,
            "mature" or "m" or "adult" => ContentRating.Mature,
            "questionable" or "q" => ContentRating.Questionable,
            _ => ContentRating.Unknown,
        };
    }

    private static string[] ParseTags(JsonElement root)
    {
        if (!root.TryGetProperty("tags", out var tags)) return [];
        if (tags.ValueKind != JsonValueKind.Array) return [];
        return tags.EnumerateArray()
            .Select(t => t.GetString() ?? "")
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .ToArray();
    }

    private static string? FindPreviewImage(string dir)
    {
        var previewNames = new[] { "preview.jpg", "preview.png", "preview.gif", "thumbnail.png", "thumb.jpg" };
        foreach (var name in previewNames)
        {
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) return path;
        }
        // Also check for any png/jpg that might be a preview
        foreach (var file in Directory.GetFiles(dir, "*.png"))
        {
            return file; // First png is likely the preview
        }
        foreach (var file in Directory.GetFiles(dir, "*.jpg"))
        {
            return file;
        }
        return null;
    }

    private static string GenerateVideoThumbnailPath(string videoPath)
    {
        return videoPath; // For now, just return video path; thumb generation is separate
    }

    private static long GetDirectorySize(string dir)
    {
        try
        {
            long size = 0;
            foreach (var file in Directory.GetFiles(dir, "*.*", SearchOption.AllDirectories))
            {
                try { size += new FileInfo(file).Length; }
                catch { /* ignore access errors */ }
            }
            return size;
        }
        catch { return 0; }
    }

    private List<WallpaperModel> LoadCachedLibrary()
    {
        try
        {
            if (File.Exists(_libraryPath))
            {
                var json = File.ReadAllText(_libraryPath);
                var items = JsonSerializer.Deserialize<List<WallpaperModel>>(json, _jsonOptions);
                if (items is not null) return items;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WallpaperLibrary] Failed to load cache: {ex.Message}");
        }
        return [];
    }

    public void AddWallpaper(WallpaperModel wallpaper)
    {
        if (_wallpapers.Any(w => w.Id == wallpaper.Id)) return;
        _wallpapers.Add(wallpaper);
        Save();
        LibraryChanged?.Invoke();
    }

    public void RemoveWallpaper(string id)
    {
        _wallpapers.RemoveAll(w => w.Id == id);
        Save();
        LibraryChanged?.Invoke();
    }

    public WallpaperModel? FindById(string id) =>
        _wallpapers.FirstOrDefault(w => w.Id == id);

    // Find the Steam Workshop path(s) actually present on disk
    public List<string> GetActualWorkshopPaths()
    {
        return DefaultWorkshopDirs.Where(Directory.Exists).ToList();
    }
}
