using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
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
        LoadPreferencesIntoControls();
        Loaded += (_, _) =>
        {
            _loading = false;
            RefreshHistory();
            RefreshDiagnostics();
        };
    }

    // -------- Setup tab --------

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

    // -------- Preferences tab --------

    private void LoadPreferencesIntoControls()
    {
        CommitOnSpaceCheck.IsChecked    = RegistrySettings.GetBool(RegistrySettings.KeyCommitOnSpace, false);
        ClusterAliasesCheck.IsChecked   = RegistrySettings.GetBool(RegistrySettings.KeyClusterAliases, true);
        BurmesePunctCheck.IsChecked     = RegistrySettings.GetBool(RegistrySettings.KeyBurmesePunctuation, false);
        NumberMeasureCheck.IsChecked    = RegistrySettings.GetBool(RegistrySettings.KeyNumberMeasureWords, false);
        LearningCheck.IsChecked         = RegistrySettings.GetBool(RegistrySettings.KeyLearning, true);

        PageSizeBox.Text          = RegistrySettings.GetInt(RegistrySettings.KeyCandidatePageSize, 9)
                                     .ToString(CultureInfo.InvariantCulture);
        AnchorThresholdBox.Text   = RegistrySettings.GetInt(RegistrySettings.KeyAnchorThreshold, 8)
                                     .ToString(CultureInfo.InvariantCulture);
        LMPruneBox.Text           = RegistrySettings.GetDouble(RegistrySettings.KeyLMPruneMargin, 8.0)
                                     .ToString("G", CultureInfo.InvariantCulture);
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
            RegistrySettings.SetBool(RegistrySettings.KeyCommitOnSpace,        CommitOnSpaceCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyClusterAliases,       ClusterAliasesCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyBurmesePunctuation,   BurmesePunctCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyNumberMeasureWords,   NumberMeasureCheck.IsChecked == true);
            RegistrySettings.SetBool(RegistrySettings.KeyLearning,             LearningCheck.IsChecked == true);

            if (int.TryParse(PageSizeBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var ps)
                && ps >= 1 && ps <= 24)
            {
                RegistrySettings.SetInt(RegistrySettings.KeyCandidatePageSize, ps);
            }
            if (int.TryParse(AnchorThresholdBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var th)
                && th >= 1 && th <= 64)
            {
                RegistrySettings.SetInt(RegistrySettings.KeyAnchorThreshold, th);
            }
            if (double.TryParse(LMPruneBox.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var lm)
                && lm >= 0.0 && lm <= 40.0)
            {
                RegistrySettings.SetDouble(RegistrySettings.KeyLMPruneMargin, lm);
            }
            PreferencesStatus.Text = "Saved. The IME picks up changes within a second.";
        }
        catch (Exception ex)
        {
            PreferencesStatus.Text = $"Save failed: {ex.Message}";
        }
    }

    // -------- History tab --------

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
                    // last_picked_at is a Unix epoch seconds Real per
                    // the Swift core's SQLiteUserHistoryStore.
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

    // -------- Convert tab --------

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

    // -------- Diagnostics tab --------

    private void OnDiagnosticsRefresh(object sender, RoutedEventArgs e) => RefreshDiagnostics();

    private void RefreshDiagnostics()
    {
        try
        {
            // Resolve the same paths the TIP DLL would: data files
            // sit next to BurmeseIMETIP.dll under
            // %ProgramFiles%\Myangler\Data\, history at
            // %LOCALAPPDATA%\Myangler\UserHistory.sqlite.
            // AppContext.BaseDirectory is the single-file-safe way
            // to get the exe's directory (Assembly.Location returns
            // an empty string when running under PublishSingleFile).
            string installRoot = AppContext.BaseDirectory;
            string lex  = Path.Combine(installRoot, "Data", "BurmeseLexicon.sqlite");
            string lm   = Path.Combine(installRoot, "Data", "BurmeseLM.bin");
            string hist = HistoryDatabasePath();
            DiagnosticsOutput.Text = Ffi.Diagnostics(lex, lm, hist);
        }
        catch (Exception ex)
        {
            DiagnosticsOutput.Text = $"FFI call failed: {ex.Message}";
        }
    }
}
