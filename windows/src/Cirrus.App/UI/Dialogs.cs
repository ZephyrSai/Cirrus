using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>Message boxes with custom buttons, built in code so they pick up the Fluent theme.</summary>
static class Dialogs
{
    public static Window? Owner(DependencyObject? d) => d is null ? Application.Current?.MainWindow : (d as Window ?? Window.GetWindow(d) ?? Application.Current?.MainWindow);

    /// <summary>Returns the index of the button pressed, or <paramref name="cancelIndex"/> when closed.</summary>
    public static int Ask(DependencyObject? owner, string title, string body, string[] buttons, int defaultIndex = 0, int cancelIndex = -1,
        PreflightSeverity severity = PreflightSeverity.Info, int destructiveIndex = -1)
    {
        int result = cancelIndex;
        var w = new Window
        {
            Title = "Cirrus", SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            WindowStartupLocation = Owner(owner) is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            MaxWidth = 560, MinWidth = 380,
        };
        if (Owner(owner) is { IsLoaded: true } o && o != w) w.Owner = o;
        var root = new Grid { Margin = new Thickness(24, 20, 24, 18) };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var glyph = new TextBlock
        {
            Text = severity switch { PreflightSeverity.Critical => "", PreflightSeverity.Warning => "", _ => "" },
            FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 28, Margin = new Thickness(0, 2, 16, 0), VerticalAlignment = VerticalAlignment.Top,
            Foreground = severity switch { PreflightSeverity.Critical => Brushes.IndianRed, PreflightSeverity.Warning => Brushes.DarkOrange, _ => SystemColors.HighlightBrush },
        };
        root.Children.Add(glyph);
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        if (!string.IsNullOrEmpty(body))
            text.Children.Add(new TextBox
            {
                Text = body, TextWrapping = TextWrapping.Wrap, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                Padding = new Thickness(0), MaxHeight = 360, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            });
        Grid.SetColumn(text, 1);
        root.Children.Add(text);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 20, 0, 0) };
        for (int i = 0; i < buttons.Length; i++)
        {
            var idx = i;
            var b = new Button { Content = buttons[i], MinWidth = 96, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(14, 6, 14, 6), IsDefault = i == defaultIndex, IsCancel = i == cancelIndex };
            if (i == defaultIndex && i != destructiveIndex) b.SetResourceReference(Control.StyleProperty, "AccentButtonStyle");
            if (i == destructiveIndex) b.Foreground = Brushes.IndianRed;
            b.Click += (_, _) => { result = idx; w.Close(); };
            row.Children.Add(b);
        }
        Grid.SetRow(row, 1);
        Grid.SetColumnSpan(row, 2);
        root.Children.Add(row);
        w.Content = root;
        w.KeyDown += (_, e) => { if (e.Key == Key.Escape) { result = cancelIndex; w.Close(); } };
        w.ShowDialog();
        return result;
    }

    public static bool Confirm(DependencyObject? owner, string title, string body, string ok, bool destructive = false) =>
        Ask(owner, title, body, [ok, "Cancel"], destructive ? 1 : 0, 1, destructive ? PreflightSeverity.Warning : PreflightSeverity.Info, destructive ? 0 : -1) == 0;

    public static void Error(DependencyObject? owner, string title, string message) =>
        Ask(owner, title, message, ["OK"], 0, 0, PreflightSeverity.Warning);

    public static void Info(DependencyObject? owner, string title, string message) => Ask(owner, title, message, ["OK"], 0, 0);

    /// <summary>A one-line text prompt (rename, new folder…). Returns null when cancelled.</summary>
    public static string? Prompt(DependencyObject? owner, string title, string label, string initial, string ok = "OK", bool selectStem = false)
    {
        string? result = null;
        var w = new Window
        {
            Title = title, SizeToContent = SizeToContent.Height, Width = 420, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        if (Owner(owner) is { IsLoaded: true } o) w.Owner = o;
        var sp = new StackPanel { Margin = new Thickness(20) };
        sp.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 8), TextWrapping = TextWrapping.Wrap });
        var box = new TextBox { Text = initial };
        sp.Children.Add(box);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var okB = new Button { Content = ok, IsDefault = true, MinWidth = 90, Padding = new Thickness(12, 5, 12, 5) };
        okB.SetResourceReference(Control.StyleProperty, "AccentButtonStyle");
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 5, 12, 5) };
        okB.Click += (_, _) => { if (box.Text.Trim().Length > 0) { result = box.Text.Trim(); w.Close(); } };
        row.Children.Add(okB); row.Children.Add(cancel);
        sp.Children.Add(row);
        w.Content = sp;
        w.Loaded += (_, _) =>
        {
            box.Focus();
            var dot = box.Text.LastIndexOf('.');
            if (selectStem && dot > 0) box.Select(0, dot); else box.SelectAll();
        };
        w.ShowDialog();
        return result;
    }
}

/// <summary>Job results and other background news: a banner in the main window and a taskbar flash.</summary>
static class Notifier
{
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    public static void JobFinished(Guid id, bool success, string message)
    {
        var name = SyncStore.Shared.Job(id)?.Name ?? "Job";
        Show(success ? $"{name} finished — {message}" : $"{name} needs attention — {message}", !success);
    }

    public static void Show(string message, bool attention = false)
    {
        if (Application.Current?.MainWindow is not MainWindow w) return;
        w.ShowBanner(message, attention);
        if (!w.IsActive)
        {
            var fi = new FLASHWINFO { cbSize = (uint)Marshal.SizeOf<FLASHWINFO>(), hwnd = new WindowInteropHelper(w).Handle, dwFlags = 3 | 12, uCount = 3 };
            FlashWindowEx(ref fi);
        }
    }
}
