using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Myangler.Preferences;

/// <summary>
/// Writing-rules / romanization reference. Mirrors macOS
/// SyntaxReferenceView.swift. Data table lives in Romanization.cs and
/// is rendered into a grid of cards at Loaded time so the C# code can
/// react to settings (e.g. dim the cluster-alias section when the
/// setting is off).
/// </summary>
public partial class SyntaxTab : UserControl
{
    public SyntaxTab()
    {
        InitializeComponent();
        Loaded += (_, _) => Populate();
    }

    private void Populate()
    {
        ConsonantsGrid.Items.Clear();
        foreach (var c in Romanization.Consonants)
        {
            ConsonantsGrid.Items.Add(MakeGlyphCard(
                glyph: c.Myanmar,
                primary: Romanization.StripDisambiguators(c.Roman)));
        }

        MedialsGrid.Items.Clear();
        foreach (var m in Romanization.Medials)
        {
            // Render against က so the medial is visible.
            MedialsGrid.Items.Add(MakeGlyphCard(
                glyph: "က" + m.Myanmar,
                primary: Romanization.StripDisambiguators(m.Roman)));
        }

        ClusterAliasesGrid.Items.Clear();
        bool aliasesOn = RegistrySettings.GetBool(RegistrySettings.KeyClusterAliases, true);
        ClusterAliasHint.Text = aliasesOn
            ? "Optional phonetic shortcuts for common consonant + medial clusters. " +
              "Spelling out the consonant and medial still works."
            : "Shortcuts are currently disabled. Enable them in the Preferences tab to use keys " +
              "like j, ch, gy, sh.";
        ClusterAliasesGrid.Opacity = aliasesOn ? 1.0 : 0.45;
        foreach (var ca in Romanization.ClusterAliases)
        {
            ClusterAliasesGrid.Items.Add(MakeGlyphCard(
                glyph: ca.MyanmarCluster,
                primary: ca.Roman,
                secondary: ca.Canonical,
                minWidth: 96));
        }

        VowelFamiliesList.Items.Clear();
        foreach (var family in Romanization.VowelFamilies)
        {
            VowelFamiliesList.Items.Add(MakeVowelFamilyBlock(family));
        }

        SpecialsList.Items.Clear();
        foreach (var s in Romanization.Specials)
        {
            SpecialsList.Items.Add(MakeSpecialRow(s));
        }

        ExamplesList.Items.Clear();
        foreach (var sample in Romanization.WorkedExamples)
        {
            ExamplesList.Items.Add(MakeExampleRow(sample));
        }
    }

    // -------------------------------------------------------------
    // Renderers
    // -------------------------------------------------------------

    private static UIElement MakeGlyphCard(
        string glyph,
        string primary,
        string? secondary = null,
        double minWidth = 76)
    {
        var glyphText = new TextBlock
        {
            Text = glyph,
            FontFamily = new FontFamily("Myanmar Text, Segoe UI"),
            FontSize = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            Height = 32,
        };
        glyphText.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var keyText = new TextBlock
        {
            Text = primary,
            FontFamily = new FontFamily("Consolas, Cascadia Mono"),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 2, 0, 0),
        };
        keyText.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var panel = new StackPanel { Orientation = Orientation.Vertical };
        panel.Children.Add(glyphText);
        panel.Children.Add(keyText);

        if (secondary is not null)
        {
            var sub = new TextBlock
            {
                Text = secondary,
                FontFamily = new FontFamily("Consolas, Cascadia Mono"),
                FontSize = 11,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 1, 0, 0),
            };
            sub.SetResourceReference(TextBlock.ForegroundProperty, "Theme.ForegroundMuted");
            panel.Children.Add(sub);
        }

        var border = new Border
        {
            Style = (Style)Application.Current.Resources["Theme.GlyphCard"],
            Child = panel,
            Margin = new Thickness(4),
            MinWidth = minWidth,
        };
        return border;
    }

    private static UIElement MakeVowelFamilyBlock(Romanization.VowelFamily f)
    {
        var title = new TextBlock
        {
            Text = f.Title,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            Margin = new Thickness(0, 8, 0, 2),
        };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var note = new TextBlock
        {
            Text = f.Note,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Margin = new Thickness(0, 0, 0, 4),
        };
        note.SetResourceReference(TextBlock.ForegroundProperty, "Theme.ForegroundMuted");

        var grid = new ItemsControl();
        var panelFactory = new FrameworkElementFactory(typeof(WrapPanel));
        panelFactory.SetValue(WrapPanel.OrientationProperty, Orientation.Horizontal);
        grid.ItemsPanel = new ItemsPanelTemplate(panelFactory);

        foreach (var entry in f.Entries)
        {
            grid.Items.Add(MakeGlyphCard(
                glyph: entry.MyanmarExample,
                primary: Romanization.StripDisambiguators(entry.Roman),
                minWidth: 84));
        }

        var stack = new StackPanel();
        stack.Children.Add(title);
        stack.Children.Add(note);
        stack.Children.Add(grid);
        return stack;
    }

    private static UIElement MakeSpecialRow(Romanization.SpecialEntry s)
    {
        var chip = new Border
        {
            Style = (Style)Application.Current.Resources["Theme.KeyChip"],
            Width = 44,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 12, 0),
            Child = new TextBlock
            {
                Text = s.Key,
                FontFamily = new FontFamily("Consolas, Cascadia Mono"),
                FontSize = 13,
                HorizontalAlignment = HorizontalAlignment.Center,
            },
        };
        ((TextBlock)chip.Child).SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var title = new TextBlock
        {
            Text = s.Title,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
        };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var detail = new TextBlock
        {
            Text = s.Detail,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Margin = new Thickness(0, 1, 0, 0),
        };
        detail.SetResourceReference(TextBlock.ForegroundProperty, "Theme.ForegroundMuted");

        var textStack = new StackPanel { Orientation = Orientation.Vertical };
        textStack.Children.Add(title);
        textStack.Children.Add(detail);

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 4, 0, 4),
        };
        row.Children.Add(chip);
        row.Children.Add(textStack);
        return row;
    }

    private static UIElement MakeExampleRow(string sample)
    {
        // Reverse-romanize via the live FFI so this teaches what the
        // engine actually produces; if the call fails (FFI missing,
        // dev build), substitute a placeholder.
        string reading;
        try { reading = Ffi.ReverseRomanize(sample); }
        catch { reading = "(ffi unavailable)"; }
        reading = Romanization.StripDisambiguators(reading);

        var readingText = new TextBlock
        {
            Text = reading,
            FontFamily = new FontFamily("Consolas, Cascadia Mono"),
            FontSize = 13,
            MinWidth = 180,
            VerticalAlignment = VerticalAlignment.Center,
        };
        readingText.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var arrow = new TextBlock
        {
            Text = "  →  ",
            FontSize = 13,
            VerticalAlignment = VerticalAlignment.Center,
        };
        arrow.SetResourceReference(TextBlock.ForegroundProperty, "Theme.ForegroundMuted");

        var burmeseText = new TextBlock
        {
            Text = sample,
            FontFamily = new FontFamily("Myanmar Text, Segoe UI"),
            FontSize = 18,
            VerticalAlignment = VerticalAlignment.Center,
        };
        burmeseText.SetResourceReference(TextBlock.ForegroundProperty, "Theme.Foreground");

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 2, 0, 2),
        };
        row.Children.Add(readingText);
        row.Children.Add(arrow);
        row.Children.Add(burmeseText);
        return row;
    }
}
