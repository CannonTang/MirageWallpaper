using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using MirageWallpaper.Models;
using MirageWallpaper.Services;

namespace MirageWallpaper.ViewModels;

public class MainViewModel : INotifyPropertyChanged
{
    private static readonly DependencyObject s_dummy = new();
    private readonly SettingsService _settings;
    private readonly WallpaperLibraryService _library;
    private readonly RendererService _renderer;

    // ---- Tab ----
    private int _selectedTabIndex;
    public int SelectedTabIndex
    {
        get => _selectedTabIndex;
        set { _selectedTabIndex = value; OnPropertyChanged(); }
    }

    // ---- Selected wallpaper ----
    private WallpaperModel? _selectedWallpaper;
    public WallpaperModel? SelectedWallpaper
    {
        get => _selectedWallpaper;
        set { _selectedWallpaper = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasSelection)); }
    }

    public bool HasSelection => _selectedWallpaper is not null;

    // ---- Search / Filter ----
    private string _searchQuery = "";
    public string SearchQuery
    {
        get => _searchQuery;
        set { _searchQuery = value; OnPropertyChanged(); RefreshFiltered(); }
    }

    private WallpaperKind? _selectedKindFilter;
    public WallpaperKind? SelectedKindFilter
    {
        get => _selectedKindFilter;
        set { _selectedKindFilter = value; OnPropertyChanged(); RefreshFiltered(); }
    }

    private ContentRating? _selectedRatingFilter;
    public ContentRating? SelectedRatingFilter
    {
        get => _selectedRatingFilter;
        set { _selectedRatingFilter = value; OnPropertyChanged(); RefreshFiltered(); }
    }

    private string _sortMode = "title";
    public string SortMode
    {
        get => _sortMode;
        set { _sortMode = value; OnPropertyChanged(); RefreshFiltered(); }
    }

    // ---- Settings panel ----
    private bool _isSettingsOpen;
    public bool IsSettingsOpen
    {
        get => _isSettingsOpen;
        set { _isSettingsOpen = value; OnPropertyChanged(); }
    }

    // ---- Playback controls ----
    private float _playVolume = 1.0f;
    public float PlayVolume
    {
        get => _playVolume;
        set
        {
            _playVolume = Math.Clamp(value, 0f, 1f);
            OnPropertyChanged();
            _renderer.SetVolume(_playVolume);
        }
    }

    private float _playSpeed = 1.0f;
    public float PlaySpeed
    {
        get => _playSpeed;
        set
        {
            _playSpeed = Math.Clamp(value, 0.1f, 2.0f);
            OnPropertyChanged();
            _renderer.SetSpeed(_playSpeed);
        }
    }

    private bool _isMuted;
    public bool IsMuted
    {
        get => _isMuted;
        set
        {
            _isMuted = value;
            OnPropertyChanged();
            _renderer.SetMuted(_isMuted);
        }
    }

    private bool _isPaused;
    public bool IsPaused
    {
        get => _isPaused;
        set
        {
            _isPaused = value;
            OnPropertyChanged();
            if (_isPaused) _renderer.Pause();
            else _renderer.Resume();
        }
    }

    private int _fps = 30;
    public int Fps
    {
        get => _fps;
        set
        {
            _fps = Math.Clamp(value, 10, 120);
            OnPropertyChanged();
            _renderer.SetFps(_fps);
        }
    }

    // ---- Library data ----
    public ObservableCollection<WallpaperModel> FilteredWallpapers { get; } = [];

    // Static filter option lists for ComboBox binding
    public static List<WallpaperKindWrapper> KindFilters { get; } =
    [
        new(null, "全部类型"),
        new(WallpaperKind.Scene, "场景"),
        new(WallpaperKind.Video, "视频"),
        new(WallpaperKind.Web, "网页"),
    ];

    public static List<ContentRatingWrapper> RatingFilters { get; } =
    [
        new(null, "全部分级"),
        new(ContentRating.General, "全年龄"),
        new(ContentRating.Mature, "成人"),
        new(ContentRating.Questionable, "敏感"),
    ];

    public static List<SortOption> SortOptions { get; } =
    [
        new("title", "按名称"),
        new("added", "按添加时间"),
        new("author", "按作者"),
    ];

    // All unique tags from the library
    public ObservableCollection<string> AvailableTags { get; } = [];
    private string? _selectedTagFilter;
    public string? SelectedTagFilter
    {
        get => _selectedTagFilter;
        set { _selectedTagFilter = value; OnPropertyChanged(); RefreshFiltered(); }
    }

    // ---- Settings access ----
    public GlobalSettings Settings => _settings.Data;

    // ---- Commands ----
    public ICommand ToggleSettingsCommand { get; }
    public ICommand ToggleMuteCommand { get; }
    public ICommand TogglePauseCommand { get; }
    public ICommand ImportWallpaperCommand { get; }
    public ICommand ApplyWallpaperCommand { get; }
    public ICommand RefreshLibraryCommand { get; }
    public ICommand ClearFiltersCommand { get; }
    public ICommand IncrementVolumeCommand { get; }
    public ICommand DecrementVolumeCommand { get; }

    public MainViewModel(SettingsService settingsService, WallpaperLibraryService libraryService,
        RendererService rendererService)
    {
        _settings = settingsService;
        _library = libraryService;
        _renderer = rendererService;
        _playVolume = (float)_settings.Data.MasterVolume;
        _fps = (int)_settings.Data.Fps;

        // Wire up library change event
        _library.LibraryChanged += () =>
        {
            Application.Current.Dispatcher.BeginInvoke(new Action(RefreshFiltered));
        };

        // Wire up renderer state change
        _renderer.StateChanged += (screen, state) =>
        {
            Application.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                _isPaused = state == RendererService.RendererState.Paused;
                OnPropertyChanged(nameof(IsPaused));
            }));
        };

        // Commands
        ToggleSettingsCommand = new RelayCommand(() => IsSettingsOpen = !IsSettingsOpen);
        ToggleMuteCommand = new RelayCommand(() => IsMuted = !IsMuted);
        TogglePauseCommand = new RelayCommand(() => IsPaused = !IsPaused);
        ImportWallpaperCommand = new AsyncRelayCommand(ImportWallpaperAsync);
        ApplyWallpaperCommand = new AsyncRelayCommand<WallpaperModel?>(ApplyWallpaperAsync);
        RefreshLibraryCommand = new RelayCommand(RefreshLibrary);
        ClearFiltersCommand = new RelayCommand(ClearFilters);
        IncrementVolumeCommand = new RelayCommand(() => PlayVolume += 0.05f);
        DecrementVolumeCommand = new RelayCommand(() => PlayVolume -= 0.05f);
    }

    public void Initialize()
    {
        _settings.Load();
        _library.Load();
        RefreshFiltered();
    }

    public void Shutdown()
    {
        _settings.Save();
        _library.Save();
        _renderer.StopAll();
    }

    // ---- Filtering & Sorting ----

    private void RefreshFiltered()
    {
        FilteredWallpapers.Clear();
        var query = _searchQuery?.Trim() ?? "";
        var source = ApplySort(_library.Wallpapers);

        foreach (var wp in source)
        {
            if (!wp.IsValid) continue;

            // Type filter
            if (_selectedKindFilter.HasValue && wp.Kind != _selectedKindFilter.Value)
                continue;

            // Rating filter
            if (_selectedRatingFilter.HasValue && wp.Rating != _selectedRatingFilter.Value)
                continue;

            // Tag filter
            if (!string.IsNullOrEmpty(_selectedTagFilter) &&
                !wp.Tags.Any(t => t.Equals(_selectedTagFilter, StringComparison.OrdinalIgnoreCase)))
                continue;

            // Text search
            if (!string.IsNullOrEmpty(query) &&
                !wp.Title.Contains(query, StringComparison.OrdinalIgnoreCase) &&
                !(wp.Author?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false) &&
                !(wp.Description?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false))
                continue;

            FilteredWallpapers.Add(wp);
        }

        // Collect available tags
        AvailableTags.Clear();
        foreach (var tag in _library.Wallpapers
            .SelectMany(w => w.Tags)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(t => t))
        {
            AvailableTags.Add(tag);
        }
    }

    private IEnumerable<WallpaperModel> ApplySort(IEnumerable<WallpaperModel> source)
    {
        return _sortMode switch
        {
            "added" => source.OrderByDescending(w => w.AddedAt),
            "author" => source.OrderBy(w => w.Author ?? "")
                .ThenBy(w => w.Title),
            _ => source.OrderBy(w => w.Title, StringComparer.OrdinalIgnoreCase),
        };
    }

    private void ClearFilters()
    {
        _searchQuery = "";
        _selectedKindFilter = null;
        _selectedRatingFilter = null;
        _selectedTagFilter = null;
        OnPropertyChanged(nameof(SearchQuery));
        OnPropertyChanged(nameof(SelectedKindFilter));
        OnPropertyChanged(nameof(SelectedRatingFilter));
        OnPropertyChanged(nameof(SelectedTagFilter));
        RefreshFiltered();
    }

    private void RefreshLibrary()
    {
        _library.ScanAllDirectories();
        RefreshFiltered();
    }

    // ---- Actions ----

    private async Task ImportWallpaperAsync()
    {
        // Open file picker to import wallpapers
        // For now, just scan directories
        await Task.Run(() => _library.ScanAllDirectories());
    }

    private async Task ApplyWallpaperAsync(WallpaperModel? wallpaper)
    {
        if (wallpaper is null) return;

        SelectedWallpaper = wallpaper;
        var screen = _settings.Data.PreferredScreenIndex;

        try
        {
            IsPaused = false;
            await Task.Run(async () =>
            {
                switch (wallpaper.Kind)
                {
                    case WallpaperKind.Scene:
                        var pkgPath = Path.Combine(wallpaper.Directory, "scene.pkg");
                        if (File.Exists(pkgPath))
                            await _renderer.StartSceneAsync(wallpaper.Directory, pkgPath, screen,
                                _fps, wallpaper.Id);
                        break;
                    case WallpaperKind.Video:
                        await _renderer.StartVideoAsync(wallpaper.Directory, screen,
                            _fps, _playVolume, _isMuted, wallpaper.Id);
                        break;
                    case WallpaperKind.Web:
                        await _renderer.StartWebAsync(wallpaper.Directory, screen, wallpaper.Id);
                        break;
                }
            });

            // Apply playback settings
            if (!_isMuted) _renderer.SetVolume(_playVolume, screen);
            else _renderer.SetMuted(true, screen);
            _renderer.SetSpeed(_playSpeed, screen);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[VM] Failed to apply wallpaper: {ex.Message}");
        }
    }

    // ---- INotifyPropertyChanged ----

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

// ---- Wrapper types for ComboBox binding ----

public record WallpaperKindWrapper(WallpaperKind? Kind, string Display)
{
    public override string ToString() => Display;
}

public record ContentRatingWrapper(ContentRating? Rating, string Display)
{
    public override string ToString() => Display;
}

public record SortOption(string Value, string Display)
{
    public override string ToString() => Display;
}

// ---- Command implementations ----

public class RelayCommand : ICommand
{
    private readonly Action _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;
    public void Execute(object? parameter) => _execute();
}

public class RelayCommand<T> : ICommand
{
    private readonly Action<T?> _execute;
    private readonly Func<T?, bool>? _canExecute;

    public RelayCommand(Action<T?> execute, Func<T?, bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);

    public bool CanExecute(object? parameter) => _canExecute?.Invoke((T?)parameter) ?? true;
    public void Execute(object? parameter) => _execute((T?)parameter);
}

public class AsyncRelayCommand : ICommand
{
    private readonly Func<Task> _execute;
    private bool _isExecuting;

    public AsyncRelayCommand(Func<Task> execute) => _execute = execute;

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => !_isExecuting;

    public async void Execute(object? parameter)
    {
        if (_isExecuting) return;
        _isExecuting = true;
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        try { await _execute(); }
        finally
        {
            _isExecuting = false;
            CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}

public class AsyncRelayCommand<T> : ICommand
{
    private readonly Func<T?, Task> _execute;
    private bool _isExecuting;

    public AsyncRelayCommand(Func<T?, Task> execute) => _execute = execute;

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => !_isExecuting;

    public async void Execute(object? parameter)
    {
        if (_isExecuting) return;
        _isExecuting = true;
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        try { await _execute((T?)parameter); }
        finally
        {
            _isExecuting = false;
            CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
