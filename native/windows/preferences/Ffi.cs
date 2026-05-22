using System.Runtime.InteropServices;
using System.Text;

namespace Myangler.Preferences;

/// <summary>
/// P/Invoke wrappers around BurmeseIMEFFI.dll for the two FFI calls
/// the Preferences app uses:
///   * <see cref="ReverseRomanize"/> for the Convert tab.
///   * <see cref="Diagnostics"/> for the Diagnostics tab.
///
/// BurmeseIMEFFI.dll is expected to sit alongside this exe — that's
/// the layout the MSI installs (everything under
/// %ProgramFiles%\Myangler\). The Windows DLL loader searches the
/// exe's directory by default, so no SetDllDirectory dance.
/// </summary>
internal static class Ffi
{
    private const string Dll = "BurmeseIMEFFI.dll";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "burmese_engine_reverse_romanize")]
    private static extern nint burmese_engine_reverse_romanize(nint myanmarUtf8);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "burmese_engine_new")]
    private static extern nint burmese_engine_new(
        nint lexiconPath,
        nint lmPath,
        nint historyPath,
        nint settingsSuiteName);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "burmese_engine_free")]
    private static extern void burmese_engine_free(nint engine);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "burmese_engine_diagnostics")]
    private static extern nint burmese_engine_diagnostics(nint engine);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl,
               EntryPoint = "burmese_engine_string_free")]
    private static extern void burmese_engine_string_free(nint str);

    /// <summary>
    /// Pure function. Reverse-romanize a Myanmar string.
    /// </summary>
    public static string ReverseRomanize(string myanmar)
    {
        nint input = StringToUtf8(myanmar);
        try
        {
            nint result = burmese_engine_reverse_romanize(input);
            return Utf8ToStringAndFree(result);
        }
        finally
        {
            if (input != 0) Marshal.FreeHGlobal(input);
        }
    }

    /// <summary>
    /// Spin up a short-lived engine handle pointing at the same
    /// paths the TIP DLL uses, ask for its diagnostics JSON, and
    /// dispose. Returns the JSON document the FFI emits (lexicon
    /// path / size, LM path / size, history path / size, version).
    /// </summary>
    public static string Diagnostics(string? lexiconPath, string? lmPath, string? historyPath)
    {
        nint lex  = StringToUtf8(lexiconPath ?? string.Empty);
        nint lm   = StringToUtf8(lmPath ?? string.Empty);
        nint hist = StringToUtf8(historyPath ?? string.Empty);
        nint handle = 0;
        try
        {
            handle = burmese_engine_new(lex, lm, hist, 0);
            if (handle == 0) return "{\"error\":\"burmese_engine_new returned null\"}";
            nint result = burmese_engine_diagnostics(handle);
            return Utf8ToStringAndFree(result);
        }
        finally
        {
            if (handle != 0) burmese_engine_free(handle);
            if (lex  != 0) Marshal.FreeHGlobal(lex);
            if (lm   != 0) Marshal.FreeHGlobal(lm);
            if (hist != 0) Marshal.FreeHGlobal(hist);
        }
    }

    private static nint StringToUtf8(string s)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s + '\0');
        nint p = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, p, bytes.Length);
        return p;
    }

    private static string Utf8ToStringAndFree(nint ptr)
    {
        if (ptr == 0) return string.Empty;
        try
        {
            return PtrToStringUTF8(ptr) ?? string.Empty;
        }
        finally
        {
            burmese_engine_string_free(ptr);
        }
    }

    // Marshal.PtrToStringUTF8 exists on .NET Core 3+; route through
    // it explicitly so the conversion ownership is unambiguous.
    private static string? PtrToStringUTF8(nint ptr) => Marshal.PtrToStringUTF8(ptr);
}
