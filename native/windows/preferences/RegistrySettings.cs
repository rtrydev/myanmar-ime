using System.Globalization;
using Microsoft.Win32;

namespace Myangler.Preferences;

/// <summary>
/// Reads / writes the eight Burmese IME settings under
/// HKCU\Software\Myangler\BurmeseIME. The TIP's
/// RegNotifyChangeKeyValue watcher picks up our writes within
/// roughly one message-pump dispatch and reapplies via the per-key
/// FFI setters (see native/windows/tsf-engine/src/settings.cpp).
///
/// Keys + types + defaults match the schema documented in
/// native/windows/tsf-engine/src/settings.h.
/// </summary>
internal static class RegistrySettings
{
    private const string SubKey = @"Software\Myangler\BurmeseIME";

    public const string KeyCandidatePageSize     = "CandidatePageSize";
    public const string KeyCommitOnSpace         = "CommitOnSpace";
    public const string KeyClusterAliases        = "ClusterAliasesEnabled";
    public const string KeyLMPruneMargin         = "LMPruneMargin";
    public const string KeyAnchorThreshold       = "AnchorCommitThreshold";
    public const string KeyBurmesePunctuation    = "BurmesePunctuationEnabled";
    public const string KeyNumberMeasureWords    = "NumberMeasureWordsEnabled";
    public const string KeyLearning              = "LearningEnabled";

    private static RegistryKey OpenRW()
        => Registry.CurrentUser.CreateSubKey(SubKey, writable: true);

    public static int GetInt(string name, int fallback)
    {
        using var k = Registry.CurrentUser.OpenSubKey(SubKey);
        if (k?.GetValue(name) is int v) return v;
        return fallback;
    }

    public static bool GetBool(string name, bool fallback)
    {
        using var k = Registry.CurrentUser.OpenSubKey(SubKey);
        if (k?.GetValue(name) is int v) return v != 0;
        return fallback;
    }

    public static double GetDouble(string name, double fallback)
    {
        using var k = Registry.CurrentUser.OpenSubKey(SubKey);
        if (k?.GetValue(name) is string s
            && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
        {
            return v;
        }
        return fallback;
    }

    public static void SetInt(string name, int value)
    {
        using var k = OpenRW();
        k.SetValue(name, value, RegistryValueKind.DWord);
    }

    public static void SetBool(string name, bool value)
    {
        using var k = OpenRW();
        k.SetValue(name, value ? 1 : 0, RegistryValueKind.DWord);
    }

    public static void SetDouble(string name, double value)
    {
        using var k = OpenRW();
        k.SetValue(name, value.ToString("G", CultureInfo.InvariantCulture),
                   RegistryValueKind.String);
    }
}
