using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace MirageWallpaper.ViewModels;

public class SettingsViewModel : INotifyPropertyChanged
{
    private string _testSetting = "test";
    public string TestSetting
    {
        get => _testSetting;
        set { _testSetting = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
