using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;

namespace Myangler.Preferences;

public partial class App : Application
{
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Myangler", "preferences.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        // Surface silent crashes to a log file under
        // %LOCALAPPDATA%\Myangler\preferences.log. Without this, a
        // startup exception (XAML parse, missing dependency,
        // P/Invoke resolution failure) leaves the user with a
        // Start-Menu shortcut that does nothing — no message box,
        // no event-log entry that's easy to find. The log file
        // bridges that gap.
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            LogCrash("AppDomain.UnhandledException", args.ExceptionObject as Exception);
        DispatcherUnhandledException += (_, args) =>
            LogCrash("Dispatcher.UnhandledException", args.Exception);
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, args) =>
            LogCrash("TaskScheduler.UnobservedTaskException", args.Exception);

        // Route every [DllImport("BurmeseIMEFFI.dll")] through a
        // custom resolver that loads the sibling DLL with
        // LOAD_WITH_ALTERED_SEARCH_PATH equivalent
        // (UseDllDirectoryForDependencies), so the Swift runtime
        // siblings (Foundation.dll, swiftCore.dll, ...) resolve
        // out of the install dir instead of failing in the standard
        // search path.
        NativeLibrary.SetDllImportResolver(typeof(Ffi).Assembly, ResolveBurmeseFfi);

        // Publish the initial Theme.* brushes BEFORE base.OnStartup
        // dispatches StartupUri, otherwise MainWindow.xaml parses while
        // the resource keys are still missing and WPF logs binding
        // errors (and the window flashes default WPF chrome for a
        // frame). Apply() seeds App.Resources from the system
        // Personalize key; per-window MicaB / dark-mode DWM hints are
        // applied later via Theme.HookWindow in MainWindow.
        Theme.Apply();

        base.OnStartup(e);
        LogInfo($"started, BaseDirectory={AppContext.BaseDirectory}");
    }

    private static nint ResolveBurmeseFfi(string name, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(name, "BurmeseIMEFFI.dll", StringComparison.OrdinalIgnoreCase))
        {
            return 0;   // fall through to default resolution
        }
        string sibling = Path.Combine(AppContext.BaseDirectory, name);
        if (!File.Exists(sibling))
        {
            LogInfo($"ResolveBurmeseFfi: sibling not found at {sibling}");
            return 0;
        }
        try
        {
            return NativeLibrary.Load(
                sibling,
                assembly,
                DllImportSearchPath.UseDllDirectoryForDependencies);
        }
        catch (Exception ex)
        {
            LogCrash("ResolveBurmeseFfi", ex);
            return 0;
        }
    }

    private static void LogCrash(string tag, Exception? ex)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {tag}: {ex}{Environment.NewLine}");
        }
        catch { /* logging must never crash the logger */ }
    }

    private static void LogInfo(string msg)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] info: {msg}{Environment.NewLine}");
        }
        catch { }
    }
}
