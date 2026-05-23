using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Data.Sqlite;

namespace Myangler.Preferences;

public partial class MainWindow : Window
{
    // Suppresses the change handler while we're loading values into
    // the controls from the registry on startup. Otherwise the
    // first load would round-trip every value back through the
    // setter and we'd see spurious "Saved" status messages.
    private bool _loading = true;

    public MainWindow()
    {
        InitializeComponent();
        Theme.HookWindow(this); // live light/dark + DWM hints
        LoadPreferencesIntoControls();
        Loaded += (_, _) =>
        {
            _loading = false;
            RefreshHistory();
            RefreshDiagnostics();
        };
    }

    // ============================================================
    //   Setup tab
    // ============================================================

    private void OnOpenLanguageSettings(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("ms-settings:keyboard")
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                $"Couldn't open language settings: {ex.Message}",
                "Myangler", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // ============================================================
    //   Preferences tab
    // ============================================================

    private void LoadPreferencesIntoControls()
    {
        CommitOnSpaceCheck.IsChecked  = RegistrySettings.GetBool(RegistrySettings.KeyCommitOnSpace, false);
        ClusterAliasesCheck.IsChecked = RegistrySettings.GetBool(RegistrySettings.KeyClusterAliases, true);
        BurmesePunctCheck.IsChecked   = RegistrySettings.GetBool(RegistrySettings.KeyBurmesePunctuation, false);
        NumberMeasureCheck.IsChecked  = RegistrySettings.GetBool(RegistrySettings.KeyNumberMeasureWords, false);
        LearningCheck.IsChecked       = RegistrySettings.GetBool(RegistrySettings.KeyLearning, true);

        PageSizeSlider.Value = RegistrySettings.GetInt(RegistrySettings.KeyCandidatePageSize, 9);
        AnchorSlider.Value   = RegistrySettings.GetInt(RegistrySettings.KeyAnchorThreshold, 8);
        LMPruneSlider.Value  = RegistrySettings.GetDouble(RegistrySettings.KeyLMPruneMargin, 8.0);

        UpdateSliderReadouts();
    }

    private void UpdateSliderReadouts()
    {
        PageSizeValue.Text = ((int)PageSizeSlider.Value).ToString(CultureInfo.InvariantCulture);
        AnchorValue.Text   = ((int)AnchorSlider.Value).ToString(CultureInfo.InvariantCulture);
        LMPruneValue.Text  = LMPruneSlider.Value.ToString("0.0", CultureInfo.InvariantCulture);
    }

    private void OnSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading) return;
        UpdateSliderReadouts();
        SaveCurrentPreferences();
    }

    private void OnSettingsChanged(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        SaveCurrentPreferences();
    }

    private void SaveCurrentPreferences()
    {
        try
        {
            RegistrySettings.SetBool(RegistrySettings.KeyCommitOnSpace,      CommitOnSpaceCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyClusterAliases,     ClusterAliasesCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyBurmesePunctuation, BurmesePunctCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyNumberMeasureWords, NumberMeasureCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyLearning,           LearningCheck.IsChecked == true);

            RegistrySettings.SetInt(RegistrySettings.KeyCandidatePageSize, (int)PageSizeSlider.Value);
            RegistrySettings.SetInt(RegistrySettings.KeyAnchorThreshold,   (int)AnchorSlider.Value);
            RegistrySettings.SetDouble(RegistrySettings.KeyLMPruneMargin,  LMPruneSlider.Value);

            PreferencesStatus.Text = "Saved. The IME picks up changes within a second.";
        }
        catch (Exception ex)
        {
            PreferencesStatus.Text = $"Save failed: {ex.Message}";
        }
    }

    // Restore-defaults wired to four logical sections, matching the
    // groupings on macOS and Linux. Restoring writes the defaults to
    // the registry and refreshes the relevant controls.

    private void OnRestoreInputBehavior(object sender, RoutedEventArgs e)
    {
        _loading = true;
        try
        {
            CommitOnSpaceCheck.IsChecked  = false;
            ClusterAliasesCheck.IsChecked = true;
            PageSizeSlider.Value          = 9;
            UpdateSliderReadouts();
        }
        finally { _loading = false; }
        SaveCurrentPreferences();
    }

    private void OnRestoreCandidateRanking(object sender, RoutedEventArgs e)
    {
        _loading = true;
        try
        {
            LMPruneSlider.Value = 8.0;
            AnchorSlider.Value  = 8;
            UpdateSliderReadouts();
        }
        finally { _loading = false; }
        SaveCurrentPreferences();
    }

    private void OnRestoreTextOutput(object sender, RoutedEventArgs e)
    {
        _loading = true;
        try
        {
            BurmesePunctCheck.IsChecked   = false;
            NumberMeasureCheck.IsChecked  = false;
        }
        finally { _loading = false; }
        SaveCurrentPreferences();
    }

    private void OnRestoreLearning(object sender, RoutedEventArgs e)
    {
        _loading = true;
        try
        {
            LearningCheck.IsChecked = true;
        }
        finally { _loading = false; }
        SaveCurrentPreferences();
    }

    // ============================================================
    //   History tab
    // ============================================================

    public class HistoryRow
    {
        public string Reading    { get; set; } = string.Empty;
        public string Surface    { get; set; } = string.Empty;
        public long   Count      { get; set; }
        public string LastPicked { get; set; } = string.Empty;
    }

    private readonly ObservableCollection<HistoryRow> _historyRows = new();

    private void OnHistoryRefresh(object sender, RoutedEventArgs e) => RefreshHistory();

    private void RefreshHistory()
    {
        HistoryGrid.ItemsSource = _historyRows;
        _historyRows.Clear();

        string path = HistoryDatabasePath();
        if (!File.Exists(path))
        {
            HistoryStatus.Text = $"No history database at {path} yet — type something with the IME first.";
            return;
        }

        try
        {
            // Read-only open via the URI form so we don't trigger a
            // write-lock contention with the live TIP DLL.
            using var conn = new SqliteConnection($"Data Source={path};Mode=ReadOnly");
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText =
                "SELECT reading, surface, count, last_picked_at " +
                "FROM selections " +
                "ORDER BY count DESC, last_picked_at DESC " +
                "LIMIT 500";
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                _historyRows.Add(new HistoryRow
                {
                    Reading    = rdr.GetString(0),
                    Surface    = rdr.GetString(1),
                    Count      = rdr.GetInt64(2),
                    LastPicked = FormatEpoch(rdr.GetDouble(3))
                });
            }
            HistoryStatus.Text = $"{_historyRows.Count} entries from {path}";
        }
        catch (Exception ex)
        {
            HistoryStatus.Text = $"Read failed: {ex.Message}";
        }
    }

    private void OnHistoryClearAll(object sender, RoutedEventArgs e)
    {
        var ok = MessageBox.Show(this,
            "Delete every learned entry? This cannot be undone.",
            "Clear history",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning);
        if (ok != MessageBoxResult.OK) return;

        string path = HistoryDatabasePath();
        if (!File.Exists(path)) return;
        try
        {
            using var conn = new SqliteConnection($"Data Source={path}");
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "DELETE FROM selections";
            cmd.ExecuteNonQuery();
            HistoryStatus.Text = "Cleared.";
            RefreshHistory();
        }
        catch (Exception ex)
        {
            HistoryStatus.Text = $"Clear failed: {ex.Message}";
        }
    }

    private void OnHistoryRowDelete(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.DataContext is not HistoryRow row) return;
        string path = HistoryDatabasePath();
        if (!File.Exists(path)) return;
        try
        {
            using var conn = new SqliteConnection($"Data Source={path}");
            conn.Open();
            using var cmd = conn.CreateCommand();
            // Selections are uniquely keyed on (reading, surface) —
            // see SQLiteUserHistoryStore.swift schema.
            cmd.CommandText = "DELETE FROM selections WHERE reading=@r AND surface=@s";
            cmd.Parameters.AddWithValue("@r", row.Reading);
            cmd.Parameters.AddWithValue("@s", row.Surface);
            cmd.ExecuteNonQuery();
            _historyRows.Remove(row);
            HistoryStatus.Text = $"{_historyRows.Count} entries.";
        }
        catch (Exception ex)
        {
            HistoryStatus.Text = $"Delete failed: {ex.Message}";
        }
    }

    private static string FormatEpoch(double seconds)
    {
        try
        {
            var dt = DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)).LocalDateTime;
            return dt.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        }
        catch
        {
            return seconds.ToString("G", CultureInfo.InvariantCulture);
        }
    }

    private static string HistoryDatabasePath()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Myangler", "UserHistory.sqlite");
    }

    // ============================================================
    //   Convert tab
    // ============================================================

    private void OnConvertClick(object sender, RoutedEventArgs e)
    {
        try
        {
            ConvertOutput.Text = Ffi.ReverseRomanize(ConvertInput.Text ?? string.Empty);
        }
        catch (Exception ex)
        {
            ConvertOutput.Text = $"FFI call failed: {ex.Message}";
        }
    }

    // ============================================================
    //   Diagnostics tab
    // ============================================================

    private string _diagRawJson = string.Empty;

    private void OnDiagnosticsRefresh(object sender, RoutedEventArgs e) => RefreshDiagnostics();

    private void OnDiagnosticsCopy(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_diagRawJson)) return;
        try
        {
            Clipboard.SetText(_diagRawJson);
            DiagStatus.Text = "Copied to clipboard.";
        }
        catch (Exception ex)
        {
            DiagStatus.Text = $"Copy failed: {ex.Message}";
        }
    }

    private void RefreshDiagnostics()
    {
        string raw;
        try
        {
            // Resolve the same paths the TIP DLL would: data files
            // sit next to BurmeseIMETIP.dll under
            // %ProgramFiles%\Myangler\Data\, history at
            // %LOCALAPPDATA%\Myangler\UserHistory.sqlite.
            // AppContext.BaseDirectory is the single-file-safe way
            // to get the exe's directory.
            string installRoot = AppContext.BaseDirectory;
            string lex  = Path.Combine(installRoot, "Data", "BurmeseLexicon.sqlite");
            string lm   = Path.Combine(installRoot, "Data", "BurmeseLM.bin");
            string hist = HistoryDatabasePath();
            raw = Ffi.Diagnostics(lex, lm, hist);
        }
        catch (Exception ex)
        {
            raw = JsonSerializer.Serialize(new { error = ex.Message });
        }

        _diagRawJson = raw;
        ApplyDiagnosticsToView(raw);
    }

    /// <summary>
    /// Parse the diagnostics JSON the FFI returned (one flat object,
    /// keys: version, lexicon_path, lexicon_bytes, lm_path, lm_bytes,
    /// history_path, history_bytes, optionally error) and project
    /// each field onto a labeled row in the structured view.
    /// </summary>
    private void ApplyDiagnosticsToView(string raw)
    {
        // Pretty-print the raw payload for the expander.
        DiagRawOutput.Text = PrettyJson(raw);

        try
        {
            using var doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;

            // Surface FFI-level errors as a status banner; still try
            // to render any fields that are present.
            if (root.TryGetProperty("error", out var err))
            {
                DiagStatus.Text = $"FFI reported: {err.GetString()}";
                DiagStructuredCard.Visibility = Visibility.Collapsed;
                DiagRawExpander.Visibility    = Visibility.Visible;
                DiagRawExpander.IsExpanded    = true;
                return;
            }

            DiagVersion.Text       = GetStr(root, "version", "(unknown)");
            DiagLexiconPath.Text   = GetStr(root, "lexicon_path", "(missing)");
            DiagLexiconSize.Text   = FormatBytes(GetLong(root, "lexicon_bytes"));
            DiagLMPath.Text        = GetStr(root, "lm_path",      "(missing)");
            DiagLMSize.Text        = FormatBytes(GetLong(root, "lm_bytes"));
            DiagHistoryPath.Text   = GetStr(root, "history_path", "(missing)");
            DiagHistorySize.Text   = FormatBytes(GetLong(root, "history_bytes"));

            DiagStructuredCard.Visibility = Visibility.Visible;
            // Keep the raw expander available but collapsed by default —
            // power users can pop it open for bug reports.
            DiagRawExpander.Visibility = Visibility.Visible;
            DiagRawExpander.IsExpanded = false;
            DiagStatus.Text = string.Empty;
        }
        catch (JsonException ex)
        {
            // Not parseable — show the raw text and the parse error so
            // the user can still file a meaningful bug report.
            DiagStructuredCard.Visibility = Visibility.Collapsed;
            DiagRawExpander.Visibility    = Visibility.Visible;
            DiagRawExpander.IsExpanded    = true;
            DiagStatus.Text = $"Couldn't parse diagnostics: {ex.Message}";
        }
    }

    private static string GetStr(JsonElement root, string key, string fallback)
    {
        if (root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
        {
            string? s = v.GetString();
            return string.IsNullOrEmpty(s) ? fallback : s;
        }
        return fallback;
    }

    private static long GetLong(JsonElement root, string key)
    {
        if (root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number
            && v.TryGetInt64(out var n))
        {
            return n;
        }
        return 0;
    }

    private static string PrettyJson(string raw)
    {
        try
        {
            using var doc = JsonDocument.Parse(raw);
            return JsonSerializer.Serialize(doc.RootElement,
                new JsonSerializerOptions { WriteIndented = true });
        }
        catch
        {
            return raw;
        }
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes <= 0) return "—";
        if (bytes < 1024) return $"{bytes} B";
        double v = bytes;
        string[] units = { "B", "KB", "MB", "GB" };
        int unit = 0;
        while (v >= 1024 && unit < units.Length - 1) { v /= 1024; unit++; }
        return v < 10
            ? string.Format(CultureInfo.InvariantCulture, "{0:F2} {1}", v, units[unit])
            : string.Format(CultureInfo.InvariantCulture, "{0:F1} {1}", v, units[unit]);
    }
}
