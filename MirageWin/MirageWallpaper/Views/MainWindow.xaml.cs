using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using MirageWallpaper.Interop;
using MirageWallpaper.Models;

namespace MirageWallpaper.Views;

public partial class MainWindow : Window
{
    private ViewModels.MainViewModel ViewModel => (ViewModels.MainViewModel)DataContext;

    // Value converter for search clear button visibility
    public static readonly IValueConverter IsNotEmptyConverter = new IsNotEmptyValueConverter();

    public MainWindow(ViewModels.MainViewModel viewModel)
    {
        DataContext = viewModel;
        InitializeComponent();

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;

        viewModel.Initialize();
        viewModel.PropertyChanged += OnViewModelChanged;
        UpdatePlaybackDisplay();
        UpdateFilterHighlights();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero)
        {
            NativeMethods.TryApplyRoundedCorners(handle, NativeMethods.DWMWCP_ROUND);
            NativeMethods.TryApplyBackdrop(handle, NativeMethods.DWMSBT_MAINWINDOW);
            NativeMethods.TryApplyDarkMode(handle, true);
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Set icon emojis for wallpaper kind cards
        UpdateKindIcons();
    }

    private void OnViewModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ViewModel.SelectedWallpaper):
            case nameof(ViewModel.IsPaused):
                UpdatePlaybackDisplay();
                break;
            case nameof(ViewModel.SelectedKindFilter):
                UpdateFilterHighlights();
                break;
        }
    }

    private void UpdatePlaybackDisplay()
    {
        var wp = ViewModel.SelectedWallpaper;
        if (wp is null)
        {
            NowPlayingText.Text = "No wallpaper active";
            NowPlayingKind.Text = "";
            DebugInfo.Text = "";
        }
        else
        {
            var state = ViewModel.IsPaused ? " - Paused" : "";
            NowPlayingText.Text = $"{wp.Title}{state}";
            NowPlayingKind.Text = wp.KindDisplay switch
            {
                "Scene" => "🏔",
                "Video" => "🎬",
                "Web" => "🌐",
                _ => "📦"
            };
            DebugInfo.Text = $"{wp.Fps}fps | {wp.SourceDisplay}";
        }
    }

    private void UpdateFilterHighlights()
    {
        UpdateKindIcons();
    }

    private void UpdateKindIcons()
    {
        // Walk the ItemsControl to set icons
        // Handled in ItemContainerGenerator status event
    }

    #region Title Bar Controls

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            WindowState = WindowState == WindowState.Maximized
                ? WindowState.Normal : WindowState.Maximized;
        }
        else
        {
            DragMove();
        }
    }

    private void MinimizeClick(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void CloseClick(object sender, RoutedEventArgs e)
    {
        Application.Current.Shutdown();
    }

    private void RefreshClick(object sender, RoutedEventArgs e)
    {
        ViewModel.RefreshLibraryCommand.Execute(null);
    }

    private void SettingsClick(object sender, RoutedEventArgs e)
    {
        ViewModel.ToggleSettingsCommand.Execute(null);
    }

    private void ClearSearch_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.SearchQuery = "";
        SearchBox.Text = "";
    }

    #endregion

    #region Filter Clicks

    private void KindFilter_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is WallpaperKindWrapper kw)
        {
            ViewModel.SelectedKindFilter = kw.Kind;
            UpdateKindIcons();
        }
    }

    private void RatingFilter_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is ContentRatingWrapper rw)
        {
            ViewModel.SelectedRatingFilter = rw.Rating;
        }
    }

    #endregion

    #region Wallpaper Card Click

    private void WallpaperCard_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is WallpaperModel wp)
        {
            ViewModel.ApplyWallpaperCommand.Execute(wp);
        }
    }

    #endregion
}

internal class IsNotEmptyValueConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        return !string.IsNullOrEmpty(value as string)
            ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotImplementedException();
    }
}
