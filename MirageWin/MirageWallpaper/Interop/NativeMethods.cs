using System.Runtime.InteropServices;

namespace MirageWallpaper.Interop;

internal static class NativeMethods
{
    // DWM window attributes
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_MICA_OR_ACRYLIC = 1;

    public const int DWMWCP_ROUND = 1;
    public const int DWMWCP_ROUNDSMALL = 2;

    // System backdrop types (Win11 22H2+)
    public const int DWMSBT_AUTO = 0;
    public const int DWMSBT_NONE = 1;
    public const int DWMSBT_MAINWINDOW = 2;      // Mica
    public const int DWMSBT_TRANSIENTWINDOW = 3;  // Acrylic
    public const int DWMSBT_TABBEDWINDOW = 4;     // Mica Alt

    public const int WM_NCLBUTTONDOWN = 0x00A1;
    public const int HT_CAPTION = 0x0002;

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int dwAttribute,
        ref int pvAttribute,
        int cbAttribute);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(
        IntPtr hwnd,
        ref MARGINS pMarInset);

    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS
    {
        public int Left, Right, Top, Bottom;
    }

    public static bool TryApplyBackdrop(IntPtr hwnd, int backdropType = DWMSBT_MAINWINDOW)
    {
        try
        {
            int value = backdropType;
            int hr = DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
                ref value, sizeof(int));
            return hr == 0;
        }
        catch { return false; }
    }

    public static bool TryApplyRoundedCorners(IntPtr hwnd, int cornerType = DWMWCP_ROUND)
    {
        try
        {
            int value = cornerType;
            int hr = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                ref value, sizeof(int));
            return hr == 0;
        }
        catch { return false; }
    }

    public static bool TryApplyDarkMode(IntPtr hwnd, bool dark)
    {
        try
        {
            int value = dark ? 1 : 0;
            int hr = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                ref value, sizeof(int));
            return hr == 0;
        }
        catch { return false; }
    }
}
