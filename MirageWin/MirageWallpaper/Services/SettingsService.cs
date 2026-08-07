using System.Text.Json;
using MirageWallpaper.Models;

namespace MirageWallpaper.Services;

public class SettingsService
{
    private readonly string _settingsPath;
    private GlobalSettings _data = GlobalSettingsDefaults.Default;
    private readonly JsonSerializerOptions _jsonOptions;

    public GlobalSettings Data
    {
        get => _data;
        private set { _data = value; SettingsChanged?.Invoke(); }
    }

    public event Action? SettingsChanged;

    public SettingsService()
    {
        _jsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
        };

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "MirageWallpaper");
        Directory.CreateDirectory(dir);
        _settingsPath = Path.Combine(dir, "settings.json");
    }

    public void Load()
    {
        try
        {
            if (File.Exists(_settingsPath))
            {
                var json = File.ReadAllText(_settingsPath);
                var loaded = JsonSerializer.Deserialize<GlobalSettings>(json, _jsonOptions);
                if (loaded is not null)
                {
                    _data = loaded;
                    return;
                }
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[SettingsService] Failed to load: {ex.Message}");
        }
        _data = GlobalSettingsDefaults.Default;
    }

    public void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(_settingsPath)!;
            Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(_data, _jsonOptions);
            File.WriteAllText(_settingsPath, json);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[SettingsService] Failed to save: {ex.Message}");
        }
    }

    // Returns effective playback action considering the current context.
    // For now returns the default; will be extended with context detection.
    public GSPlayback EffectivePlaybackAction(
        bool isOtherAppFocused = false,
        bool isFullscreen = false,
        bool isPlayingAudio = false,
        bool isDisplayAsleep = false,
        bool isOnBattery = false)
    {
        if (isDisplayAsleep && _data.DisplayAsleep != GSPlayback.KeepRunning)
            return _data.DisplayAsleep;
        if (isOnBattery && _data.LaptopOnBattery != GSPlayback.KeepRunning)
            return _data.LaptopOnBattery;
        if (isFullscreen && _data.OtherApplicationFullscreen != GSPlayback.KeepRunning)
            return _data.OtherApplicationFullscreen;
        if (isPlayingAudio && _data.OtherApplicationPlayingAudio != GSPlayback.KeepRunning)
            return _data.OtherApplicationPlayingAudio;
        if (isOtherAppFocused && _data.OtherApplicationFocused != GSPlayback.KeepRunning)
            return _data.OtherApplicationFocused;
        return GSPlayback.KeepRunning;
    }
}
