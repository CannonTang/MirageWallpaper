using System.Text;
using System.Text.Json;

namespace MirageWallpaper.Models;

public enum GSPlayback
{
    KeepRunning,
    Mute,
    Pause,
    Stop
}

public enum GSAntiAliasingQuality
{
    None,
    MsaaX2,
    MsaaX4,
    MsaaX8
}

public enum GSPostProcessingQuality
{
    Disabled,
    Enabled,
    Ultra
}

public enum GSTextureResolutionQuality
{
    HighQuality,
    HighPerformance,
    Automatic
}

public enum GSWallpaperLoadSource
{
    Disk,
    Memory
}

public enum GSAppearance
{
    Light,
    Dark,
    FollowSystem
}

public enum GSLanguage
{
    EnUS,
    ZhCN,
    ZhTW,
    FollowSystem
}

public enum GSProcessPriority
{
    Normal,
    BelowNormal
}

public enum GSLogLevel
{
    Error,
    Verbose,
    None
}

public enum GSSteamAPIEndpoint
{
    Official,
    Mirror
}

public record GlobalSettings
{
    // Playback
    public GSPlayback OtherApplicationFocused { get; set; } = GSPlayback.KeepRunning;
    public GSPlayback OtherApplicationFullscreen { get; set; } = GSPlayback.KeepRunning;
    public GSPlayback OtherApplicationPlayingAudio { get; set; } = GSPlayback.KeepRunning;
    public GSPlayback DisplayAsleep { get; set; } = GSPlayback.KeepRunning;
    public GSPlayback LaptopOnBattery { get; set; } = GSPlayback.KeepRunning;

    // Quality
    public GSAntiAliasingQuality AntiAliasing { get; set; } = GSAntiAliasingQuality.MsaaX2;
    public GSPostProcessingQuality PostProcessing { get; set; } = GSPostProcessingQuality.Disabled;
    public GSTextureResolutionQuality TextureResolution { get; set; } = GSTextureResolutionQuality.Automatic;
    public GSWallpaperLoadSource WallpaperLoadSource { get; set; } = GSWallpaperLoadSource.Disk;
    public bool Reflections { get; set; }
    public double Fps { get; set; } = 30;

    // Automatic Setup
    public bool AutoStart { get; set; }
    public bool SafeMode { get; set; }
    public bool AutomaticUpdatesEnabled { get; set; } = true;
    public bool ReceivePrereleaseUpdates { get; set; }
    public bool AutoRefresh { get; set; } = true;

    // Language
    public GSLanguage Language { get; set; } = GSLanguage.FollowSystem;

    // Appearance
    public GSAppearance Appearance { get; set; } = GSAppearance.FollowSystem;
    public bool AdjustMenuBarTint { get; set; } = true;

    // Audio
    public bool AudioOutput { get; set; } = true;
    public bool ReloadWhenChangingOutputDevice { get; set; } = true;
    public double MasterVolume { get; set; } = 1.0;
    public bool GlobalMuted { get; set; }
    public bool EnableSpectrum { get; set; } = true;

    // Advanced
    public GSProcessPriority ProcessPriority { get; set; } = GSProcessPriority.Normal;
    public bool PauseOnVRAMExhausted { get; set; }
    public bool RestartAfterCrashing { get; set; }

    // Developer
    public GSLogLevel LogLevel { get; set; } = GSLogLevel.None;
    public bool VerboseLog { get; set; }

    // Steam Workshop
    public GSSteamAPIEndpoint SteamAPIEndpoint { get; set; } = GSSteamAPIEndpoint.Official;
    public string SteamAPIKey { get; set; } = "";
    public bool AutoStartSteamCmd { get; set; }

    // Windows specific
    public bool MultiMonitorSupport { get; set; } = true;
    public bool StartWithWindows { get; set; }
    public bool MinimizeToTray { get; set; } = true;
    public int PreferredScreenIndex { get; set; }
}

public static class GlobalSettingsDefaults
{
    public static GlobalSettings Default => new();
}
