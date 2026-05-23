using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace Myangler.Preferences;

/// <summary>
/// Light/dark theme + system accent color tracker. WPF on .NET 9 does
/// not auto-theme the way WinUI 3 does, so we read Windows' Personalize
/// keys ourselves and republish a fixed set of dynamic brushes into
/// App.Resources. Anything in XAML that says
/// `{DynamicResource Theme.Foreground}` etc. follows the system.
///
/// We also flip the DWM dark-mode and Mica backdrop attributes on a
/// given Window so the title bar, system shadow, and Mica fill match
/// the in-window content.
/// </summary>
internal static class Theme
{
    public static bool IsDark { get; private set; }
    public static Color Accent { get; private set; } = Color.FromRgb(0x00, 0x67, 0xC0);

    /// <summary>Re-evaluate light/dark + accent and refresh App brushes.</summary>
    public static void Apply()
    {
        IsDark = ReadAppsUseLight() == 0;
        Accent = ReadAccentColor();
        PublishBrushes();
    }

    /// <summary>Hook WM_SETTINGCHANGE for live theme follow.</summary>
    public static void HookWindow(Window window)
    {
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            var src  = HwndSource.FromHwnd(hwnd);
            src?.AddHook(WndProc);
            ApplyDwmAttributes(hwnd);
        };
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        // WM_SETTINGCHANGE = 0x001A. lParam is a string area like
        // "ImmersiveColorSet" / "WindowsThemeElement" / "Environment".
        // Cheapest correct behaviour: re-read on any setting change.
        if (msg == 0x001A)
        {
            Apply();
            ApplyDwmAttributes(hwnd);
        }
        return IntPtr.Zero;
    }

    // ---- DWM hints -----------------------------------------------

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    private const int DWMWA_SYSTEMBACKDROP_TYPE     = 38;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;

    // DWM_SYSTEMBACKDROP_TYPE
    private const int DWMSBT_MAINWINDOW = 2; // Mica

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private static void ApplyDwmAttributes(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;

        // Immersive dark mode controls title-bar color. Available
        // since Windows 10 build 17763; failure is harmless on older
        // builds — the title bar just stays light.
        int dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));

        // Mica backdrop — Win11 22H2+. Older builds return non-zero
        // and the window falls back to a solid System.Window color
        // (which we override anyway via the WPF Background brush).
        int backdrop = DWMSBT_MAINWINDOW;
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));

        // Rounded corners — Win11. DWMWCP_DEFAULT = 0 (system picks),
        // DWMWCP_ROUND = 2. The default is already round for top-level
        // windows on Win11, but set explicitly so older Win11 builds
        // that ship in mixed configurations stay consistent.
        int corner = 2;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
    }

    // ---- Registry probes ----------------------------------------

    private static int ReadAppsUseLight()
    {
        using var k = Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        if (k?.GetValue("AppsUseLightTheme") is int v) return v;
        // Some images ship without the value; default to light to
        // match Windows' own default.
        return 1;
    }

    private static Color ReadAccentColor()
    {
        // DWM stores the accent as an ABGR DWORD under
        // HKCU\Software\Microsoft\Windows\DWM\AccentColor. The high byte
        // is alpha (usually 0xFF), then BB GG RR. Translate to a
        // standards-friendly ARGB Color.
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
        if (k?.GetValue("AccentColor") is int packed)
        {
            uint u = unchecked((uint)packed);
            byte a = (byte)((u >> 24) & 0xFF);
            byte b = (byte)((u >> 16) & 0xFF);
            byte g = (byte)((u >> 8)  & 0xFF);
            byte r = (byte)( u        & 0xFF);
            return Color.FromArgb(a == 0 ? (byte)0xFF : a, r, g, b);
        }
        // Fallback: Windows 11 default blue.
        return Color.FromRgb(0x00, 0x67, 0xC0);
    }

    // ---- Brush publication --------------------------------------

    private static void PublishBrushes()
    {
        var r = Application.Current.Resources;

        // Pair of palettes, side by side so the diff is easy to read.
        Color bgWindow, bgCard, bgCardHover, bgInput, fgPrimary, fgSecondary,
              border, borderSubtle, divider, hover, destructive, destructiveFg;

        if (IsDark)
        {
            bgWindow      = Color.FromRgb(0x20, 0x20, 0x20);
            bgCard        = Color.FromRgb(0x2B, 0x2B, 0x2B);
            bgCardHover   = Color.FromRgb(0x33, 0x33, 0x33);
            bgInput       = Color.FromRgb(0x1E, 0x1E, 0x1E);
            fgPrimary     = Color.FromRgb(0xFF, 0xFF, 0xFF);
            fgSecondary   = Color.FromRgb(0xC7, 0xC7, 0xC7);
            border        = Color.FromArgb(0x60, 0xFF, 0xFF, 0xFF);
            borderSubtle  = Color.FromArgb(0x22, 0xFF, 0xFF, 0xFF);
            divider       = Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF);
            hover         = Color.FromArgb(0x12, 0xFF, 0xFF, 0xFF);
            destructive   = Color.FromRgb(0xFF, 0x99, 0xA4);
            destructiveFg = Color.FromRgb(0x40, 0x14, 0x14);
        }
        else
        {
            bgWindow      = Color.FromRgb(0xF3, 0xF3, 0xF3);
            bgCard        = Color.FromRgb(0xFB, 0xFB, 0xFB);
            bgCardHover   = Color.FromRgb(0xF5, 0xF5, 0xF5);
            bgInput       = Color.FromRgb(0xFF, 0xFF, 0xFF);
            fgPrimary     = Color.FromRgb(0x1A, 0x1A, 0x1A);
            fgSecondary   = Color.FromRgb(0x5C, 0x5C, 0x5C);
            border        = Color.FromArgb(0x88, 0x00, 0x00, 0x00);
            borderSubtle  = Color.FromArgb(0x16, 0x00, 0x00, 0x00);
            divider       = Color.FromArgb(0x14, 0x00, 0x00, 0x00);
            hover         = Color.FromArgb(0x08, 0x00, 0x00, 0x00);
            destructive   = Color.FromRgb(0xC4, 0x29, 0x29);
            destructiveFg = Color.FromRgb(0xFF, 0xFF, 0xFF);
        }

        SetBrush(r, "Theme.WindowBackground", bgWindow);
        SetBrush(r, "Theme.CardBackground",   bgCard);
        SetBrush(r, "Theme.CardHover",        bgCardHover);
        SetBrush(r, "Theme.InputBackground",  bgInput);
        SetBrush(r, "Theme.Foreground",       fgPrimary);
        SetBrush(r, "Theme.ForegroundMuted",  fgSecondary);
        SetBrush(r, "Theme.Border",           border);
        SetBrush(r, "Theme.BorderSubtle",     borderSubtle);
        SetBrush(r, "Theme.Divider",          divider);
        SetBrush(r, "Theme.Hover",            hover);
        SetBrush(r, "Theme.Destructive",      destructive);
        SetBrush(r, "Theme.DestructiveForeground", destructiveFg);

        // Accent + an alpha-blended variant for selection backgrounds.
        SetBrush(r, "Theme.Accent",           Accent);
        SetBrush(r, "Theme.AccentSubtle",
                 Color.FromArgb(IsDark ? (byte)0x55 : (byte)0x28,
                                Accent.R, Accent.G, Accent.B));
        SetBrush(r, "Theme.AccentForeground",
                 IsDark ? Colors.Black : Colors.White);
    }

    private static void SetBrush(ResourceDictionary r, string key, Color c)
    {
        var brush = new SolidColorBrush(c);
        brush.Freeze();
        r[key] = brush;
    }
}
