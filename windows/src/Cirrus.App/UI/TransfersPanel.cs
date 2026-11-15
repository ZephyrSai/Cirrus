using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>Transfers list: progress, speed and ETA per row; cancel, retry, show in Explorer; clear finished.</summary>
sealed class TransfersPanel : DockPanel
{
    readonly StackPanel _rows = new();
    readonly TextBlock _summary = new() { VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75 };
    readonly Dictionary<Guid, Row> _byId = [];

    sealed class Row
    {
        public required Border Root;
        public required TextBlock Title, Detail, Status;
        public required ProgressBar Bar;
        public required Button Action, Reveal;
    }

    public TransfersPanel()
    {
        var head = new DockPanel { Margin = new Thickness(12, 6, 12, 6) };
        var clear = new Button { Content = "Clear Finished", Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(6, 0, 0, 0) };
        clear.Click += (_, _) => TransferManager.Shared.ClearFinished();
        var cancelAll = new Button { Content = "Stop All", Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(6, 0, 0, 0) };
        cancelAll.Click += (_, _) => { if (Dialogs.Confirm(this, "Stop all transfers?", "Files already copied stay where they are.", "Stop All")) TransferManager.Shared.CancelAll(); };
        DockPanel.SetDock(clear, Dock.Right); DockPanel.SetDock(cancelAll, Dock.Right);
        head.Children.Add(clear); head.Children.Add(cancelAll);
        head.Children.Add(new TextBlock { Text = "Transfers", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) });
        head.Children.Add(_summary);
        DockPanel.SetDock(head, Dock.Top);
        Children.Add(head);
        Children.Add(new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8, 0, 8, 8) });
    }

    public void Refresh()
    {
        var list = TransferManager.Shared.Transfers.Reverse().ToList();
        var ids = list.Select(t => t.Id).ToHashSet();
        foreach (var gone in _byId.Keys.Where(k => !ids.Contains(k)).ToList()) { _rows.Children.Remove(_byId[gone].Root); _byId.Remove(gone); }
        for (int i = 0; i < list.Count; i++)
        {
            var t = list[i];
            if (!_byId.TryGetValue(t.Id, out var row)) { row = Make(t); _byId[t.Id] = row; _rows.Children.Insert(Math.Min(i, _rows.Children.Count), row.Root); }
            Update(row, t);
        }
        var (done, total, count) = TransferManager.Shared.Overall;
        _summary.Text = count == 0 ? (list.Count == 0 ? "Nothing is transferring." : "All done.") : $"{count} active — {done.ByteString()} of {total.ByteString()}";
    }

    Row Make(Transfer t)
    {
        var title = new TextBlock { FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var detail = new TextBlock { Opacity = 0.7, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        var status = new TextBlock { Opacity = 0.7, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        var bar = new ProgressBar { Height = 4, Margin = new Thickness(0, 4, 0, 4), Minimum = 0, Maximum = 1 };
        var action = new Button { Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var reveal = new Button { Content = "Show", Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        action.Click += (_, _) =>
        {
            if (t.IsFinished) TransferManager.Shared.Retry(t); else TransferManager.Shared.Cancel(t);
        };
        reveal.Click += (_, _) => { if (t.ResultPath is { } p) Ops.ShowInExplorer(p); };
        var text = new StackPanel();
        text.Children.Add(title); text.Children.Add(bar); text.Children.Add(status); text.Children.Add(detail);
        var dock = new DockPanel();
        DockPanel.SetDock(action, Dock.Right); DockPanel.SetDock(reveal, Dock.Right);
        dock.Children.Add(action); dock.Children.Add(reveal);
        var glyph = new TextBlock
        {
            Text = t.Direction switch { TransferDirection.Upload => "", TransferDirection.Download => "", TransferDirection.Copy => "", _ => "" },
            FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 18, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        DockPanel.SetDock(glyph, Dock.Left);
        dock.Children.Add(glyph);
        dock.Children.Add(text);
        var root = new Border { Child = dock, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 2, 0, 2), CornerRadius = new CornerRadius(4) };
        root.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        return new Row { Root = root, Title = title, Detail = detail, Status = status, Bar = bar, Action = action, Reveal = reveal };
    }

    static void Update(Row r, Transfer t)
    {
        r.Title.Text = t.Title;
        r.Detail.Text = t.Detail;
        r.Status.Text = t.StatusText;
        r.Bar.IsIndeterminate = t.State == TransferState.Running && t.Total <= 0;
        r.Bar.Value = t.Fraction;
        r.Bar.Visibility = t.State is TransferState.Running or TransferState.Queued ? Visibility.Visible : Visibility.Collapsed;
        r.Status.Foreground = t.State == TransferState.Failed ? Brushes.IndianRed : r.Detail.Foreground;
        r.Action.Content = t.State switch { TransferState.Failed or TransferState.Cancelled => "Retry", TransferState.Done => "", _ => "Stop" };
        r.Action.Visibility = t.State == TransferState.Done ? Visibility.Collapsed : Visibility.Visible;
        r.Reveal.Visibility = t.State == TransferState.Done && t.ResultPath is not null ? Visibility.Visible : Visibility.Collapsed;
    }
}
