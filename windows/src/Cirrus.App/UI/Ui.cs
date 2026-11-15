using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Cirrus.App.UI;

/// <summary>Small helpers for building dialog layouts in code.</summary>
static class Ui
{
    public static FontFamily IconFont => (FontFamily)Application.Current.Resources["IconFont"];

    public static TextBlock Text(string s, double size = 13, bool bold = false, double opacity = 1, bool wrap = true) => new()
    {
        Text = s, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, Opacity = opacity,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, Margin = new Thickness(0, 0, 0, 4),
    };

    public static TextBlock Header(string s) => new() { Text = s, FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 14, 0, 6) };

    public static TextBlock Glyph(string g, double size = 16) => new() { Text = g, FontFamily = IconFont, FontSize = size, VerticalAlignment = VerticalAlignment.Center };

    public static Button Button(string text, Action onClick, bool accent = false, bool isDefault = false, bool isCancel = false)
    {
        var b = new Button { Content = text, Padding = new Thickness(14, 5, 14, 5), Margin = new Thickness(8, 0, 0, 0), MinWidth = 90, IsDefault = isDefault, IsCancel = isCancel };
        if (accent) b.SetResourceReference(FrameworkElement.StyleProperty, "AccentButtonStyle");
        b.Click += (_, _) => onClick();
        return b;
    }

    public static CheckBox Check(string text, bool value, Action<bool>? changed = null)
    {
        var c = new CheckBox { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap }, IsChecked = value, Margin = new Thickness(0, 3, 0, 3) };
        if (changed is not null) { c.Checked += (_, _) => changed(true); c.Unchecked += (_, _) => changed(false); }
        return c;
    }

    public static StackPanel Row(params UIElement[] children)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        foreach (var c in children) sp.Children.Add(c);
        return sp;
    }

    public static StackPanel Buttons(params UIElement[] children)
    {
        var sp = Row(children);
        sp.HorizontalAlignment = HorizontalAlignment.Right;
        sp.Margin = new Thickness(0, 16, 0, 0);
        return sp;
    }

    public static StackPanel Stack(params UIElement[] children)
    {
        var sp = new StackPanel();
        foreach (var c in children) sp.Children.Add(c);
        return sp;
    }

    public static Grid Labeled(string label, UIElement field, double labelWidth = 130)
    {
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(labelWidth) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.85 };
        g.Children.Add(l);
        Grid.SetColumn(field, 1);
        g.Children.Add(field);
        return g;
    }

    public static Border Card(UIElement child)
    {
        var b = new Border { Child = child, Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 4, 0, 4), BorderThickness = new Thickness(1) };
        b.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        b.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        return b;
    }

    public static Window Window(string title, double width, Window? owner, bool resizable = false)
    {
        var w = new Window
        {
            Title = title, Width = width, SizeToContent = SizeToContent.Height, ResizeMode = resizable ? ResizeMode.CanResize : ResizeMode.NoResize,
            WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        if (owner is not null) w.Owner = owner;
        return w;
    }
}
