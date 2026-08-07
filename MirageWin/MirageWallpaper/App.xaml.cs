using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using MirageWallpaper.Services;
using MirageWallpaper.ViewModels;

namespace MirageWallpaper;

public partial class App : Application
{
    private readonly ServiceProvider _services;

    public App()
    {
        _services = ConfigureServices();
    }

    private static ServiceProvider ConfigureServices()
    {
        var services = new ServiceCollection();
        services.AddSingleton<SettingsService>();
        services.AddSingleton<WallpaperLibraryService>();
        services.AddSingleton<RendererService>();
        services.AddSingleton<MainViewModel>();
        services.AddTransient<Views.MainWindow>();
        return services.BuildServiceProvider();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = _services.GetRequiredService<Views.MainWindow>();
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _services.GetService<MainViewModel>()?.Shutdown();
        _services.Dispose();
        base.OnExit(e);
    }
}
