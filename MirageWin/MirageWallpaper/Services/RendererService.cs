using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace MirageWallpaper.Services;

/// <summary>
/// Manages wallpaper renderer processes (SceneRenderer, VideoRenderer, WebRenderer).
/// Communicates with renderer processes via stdin JSON lines (ControlChannel protocol).
/// </summary>
public class RendererService : IDisposable
{
    private readonly ConcurrentDictionary<int, RendererInstance> _renderers = new();
    private readonly string _rendererBinDir;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public event Action<int, RendererState>? StateChanged;

    public enum RendererState
    {
        Stopped,
        Starting,
        Running,
        Paused,
        Stopping,
    }

    private record RendererInstance
    {
        public Process? Process { get; set; }
        public StreamWriter? Stdin { get; set; }
        public RendererState State { get; set; } = RendererState.Stopped;
        public string? WallpaperId { get; set; }
        public int ScreenIndex { get; init; }
        public CancellationTokenSource? Cts { get; set; }
    }

    public RendererService()
    {
        // Find the renderer binaries relative to the app
        var exeDir = AppContext.BaseDirectory;
        _rendererBinDir = FindRendererDirectory(exeDir);
    }

    public string RendererBinDirectory => _rendererBinDir;

    private static string FindRendererDirectory(string exeDir)
    {
        // Try common locations
        var candidates = new[]
        {
            Path.Combine(exeDir, "Renderers"),
            Path.Combine(exeDir, "..", "..", "..", "SceneRenderer", "windows", "build", "w7", "bin", "Release"),
            Path.Combine(exeDir, "..", "SceneRenderer", "windows", "build", "w7", "bin", "Release"),
            Path.Combine(exeDir, "..", "..", "SceneRenderer", "windows", "build", "w7", "bin", "Release"),
        };

        foreach (var candidate in candidates)
        {
            var fullPath = Path.GetFullPath(candidate);
            if (Directory.Exists(fullPath)) return fullPath;
        }

        return exeDir;
    }

    public bool IsRunning(int screen = 0) =>
        _renderers.TryGetValue(screen, out var r) && r.State is RendererState.Running or RendererState.Paused;

    public RendererState GetState(int screen = 0) =>
        _renderers.TryGetValue(screen, out var r) ? r.State : RendererState.Stopped;

    /// <summary>
    /// Start a scene wallpaper renderer.
    /// </summary>
    public async Task StartSceneAsync(string assetsDir, string scenePkg, int screen = 0,
        int fps = 30, string? wallpaperId = null, CancellationToken ct = default)
    {
        await StopAsync(screen);
        var args = $"\"{assetsDir}\" \"{scenePkg}\" --screen {screen} --fps {fps} --control-stdin";
        await StartProcessAsync("SceneWallpaperWin.exe", args, screen, wallpaperId, ct);
    }

    /// <summary>
    /// Start a video wallpaper renderer.
    /// </summary>
    public async Task StartVideoAsync(string videoFile, int screen = 0,
        int fps = 30, float volume = 1.0f, bool muted = false, string? wallpaperId = null,
        CancellationToken ct = default)
    {
        await StopAsync(screen);
        var args = $"\"{videoFile}\" --screen {screen} --fps {fps}";
        if (muted) args += " --muted";
        else args += $" --volume {volume}";
        await StartProcessAsync("VideoWallpaperWin.exe", args, screen, wallpaperId, ct);
    }

    /// <summary>
    /// Start a web wallpaper renderer.
    /// </summary>
    public async Task StartWebAsync(string projectDir, int screen = 0,
        string? wallpaperId = null, CancellationToken ct = default)
    {
        await StopAsync(screen);
        var args = $"\"{projectDir}\"";
        await StartProcessAsync("WebWallpaperWin.exe", args, screen, wallpaperId, ct);
    }

    private async Task StartProcessAsync(string exeName, string args, int screen,
        string? wallpaperId, CancellationToken ct)
    {
        var exePath = Path.Combine(_rendererBinDir, exeName);
        if (!File.Exists(exePath))
        {
            Debug.WriteLine($"[RendererService] Executable not found: {exePath}");
            return;
        }

        var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var instance = new RendererInstance
        {
            ScreenIndex = screen,
            WallpaperId = wallpaperId,
            Cts = cts,
        };

        var psi = new ProcessStartInfo
        {
            FileName = exePath,
            Arguments = args,
            RedirectStandardInput = true,
            RedirectStandardOutput = false,
            RedirectStandardError = false,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };

        process.Exited += (_, _) =>
        {
            if (instance.State != RendererState.Stopping)
            {
                instance.State = RendererState.Stopped;
                StateChanged?.Invoke(screen, RendererState.Stopped);
            }
            instance.Process = null;
            instance.Stdin?.Dispose();
            instance.Stdin = null;
            cts.Dispose();
        };

        try
        {
            process.Start();
            instance.Process = process;
            instance.Stdin = process.StandardInput;
            instance.State = RendererState.Running;
            _renderers.AddOrUpdate(screen, instance, (_, old) =>
            {
                old.Cts?.Cancel();
                old.Stdin?.Dispose();
                old.Process?.Kill();
                return instance;
            });

            // Give the renderer a moment to initialize
            await Task.Delay(200, ct);
            StateChanged?.Invoke(screen, RendererState.Running);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RendererService] Failed to start {exeName}: {ex.Message}");
            instance.State = RendererState.Stopped;
            cts.Dispose();
        }
    }

    public async Task StopAsync(int screen = 0)
    {
        if (!_renderers.TryRemove(screen, out var instance)) return;

        instance.State = RendererState.Stopping;
        try
        {
            // Send quit command
            SendCommand(screen, "quit");
            await Task.Delay(500);

            if (instance.Process is { HasExited: false })
            {
                instance.Process.Kill(entireProcessTree: true);
                await Task.Delay(200);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RendererService] Error stopping screen {screen}: {ex.Message}");
        }
        finally
        {
            instance.State = RendererState.Stopped;
            instance.Cts?.Cancel();
            instance.Stdin?.Dispose();
            instance.Process?.Dispose();
            StateChanged?.Invoke(screen, RendererState.Stopped);
        }
    }

    public void StopAll()
    {
        foreach (var screen in _renderers.Keys.ToList())
        {
            StopAsync(screen).Wait(TimeSpan.FromSeconds(3));
        }
    }

    // ---- Control commands (send via stdin) ----

    public void Pause(int screen = 0) => SendCommand(screen, "pause");
    public void Resume(int screen = 0) => SendCommand(screen, "resume");
    public void SetVolume(float volume, int screen = 0) =>
        SendCommand(screen, "volume", volume);
    public void SetMuted(bool muted, int screen = 0) =>
        SendCommand(screen, "muted", muted);
    public void SetSpeed(float speed, int screen = 0) =>
        SendCommand(screen, "speed", speed);
    public void SetFps(int fps, int screen = 0) =>
        SendCommand(screen, "fps", fps);
    public void SetFillMode(string mode, int screen = 0) =>
        SendCommand(screen, "fillmode", mode);
    public void SetProperty(string key, object value, string? type = null, int screen = 0)
    {
        var cmd = new Dictionary<string, object>
        {
            ["cmd"] = "setProperty",
            ["key"] = key,
            ["type"] = type ?? "text",
            ["value"] = value,
        };
        SendJson(screen, cmd);
    }

    private void SendCommand(int screen, string cmd, object? value = null)
    {
        if (!_renderers.TryGetValue(screen, out var instance) ||
            instance.Stdin is null) return;

        try
        {
            var msg = new Dictionary<string, object> { ["cmd"] = cmd };
            if (value is not null)
                msg["value"] = value;

            var json = JsonSerializer.Serialize(msg, JsonOptions);
            instance.Stdin.WriteLine(json);
            instance.Stdin.Flush();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RendererService] Failed to send command '{cmd}': {ex.Message}");
        }
    }

    private void SendJson(int screen, Dictionary<string, object> msg)
    {
        if (!_renderers.TryGetValue(screen, out var instance) ||
            instance.Stdin is null) return;

        try
        {
            msg["cmd"] = "setProperty";
            var json = JsonSerializer.Serialize(msg, JsonOptions);
            instance.Stdin.WriteLine(json);
            instance.Stdin.Flush();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RendererService] SendJson failed: {ex.Message}");
        }
    }

    public void Dispose()
    {
        StopAll();
        _renderers.Clear();
    }
}
