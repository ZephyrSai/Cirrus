using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using Cirrus.App.Model;
using Cirrus.App.Platform;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

public sealed class PhotoRowSelector : DataTemplateSelector
{
    public DataTemplate? Header { get; set; }
    public DataTemplate? Tiles { get; set; }
    public override DataTemplate? SelectTemplate(object item, DependencyObject container) => item is PhotoRow { IsHeader: true } ? Header : Tiles;
}

/// <summary>One tab: a location with history, three views (details, icons, photo grid), filter, sorting, drag and drop.</summary>
public partial class BrowserTab : UserControl
{
    public static readonly DependencyProperty TileSizeProperty = DependencyProperty.Register(nameof(TileSize), typeof(double), typeof(BrowserTab), new PropertyMetadata(120.0));
    public double TileSize { get => (double)GetValue(TileSizeProperty); set => SetValue(TileSizeProperty, value); }

    public Location Current { get; private set; } = Location.Home();
    readonly List<Location> _back = [], _forward = [];
    readonly ObservableCollection<Item> _items = [];
    readonly ObservableCollection<PhotoRow> _rows = [];
    readonly ICollectionView _view;
    CancellationTokenSource? _loadCts;
    string _filter = "";
    string _sortKey = "Name";
    bool _sortDesc;
    string _viewMode = Settings.Current.ViewMode;
    Item? _anchor;
    Point _dragStart;
    bool _dragArmed;
    readonly DispatcherTimer _relayout;

    public event Action? LocationChanged;
    public event Action? SelectionChanged;
    public event Action? StatusChanged;
    public MainWindow? Host { get; set; }

    public string Status { get; private set; } = "";
    public bool IsLoading { get; private set; }

    public BrowserTab()
    {
        InitializeComponent();
        _view = CollectionViewSource.GetDefaultView(_items);
        _view.Filter = o => o is Item i && (_filter.Length == 0 || i.Name.Contains(_filter, StringComparison.CurrentCultureIgnoreCase));
        DetailsList.ItemsSource = _view;
        IconsList.ItemsSource = _view;
        PhotoGrid.ItemsSource = _rows;
        TileSize = Settings.Current.PhotoSize;
        _relayout = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _relayout.Tick += (_, _) => { _relayout.Stop(); BuildRows(); };
        DragOver += OnDragOver;
        Drop += OnDrop;
        Catalog.Shared.Invalidated += OnInvalidated;
        Catalog.Shared.PhotosPatched += OnPhotosPatched;
        PreviewKeyDown += OnKey;
        DetailsList.ContextMenu = new ContextMenu();
        IconsList.ContextMenu = new ContextMenu();
        DetailsList.PreviewMouseRightButtonDown += List_PreviewRightDown;
        IconsList.PreviewMouseRightButtonDown += List_PreviewRightDown;
        DetailsList.PreviewMouseLeftButtonUp += List_PreviewMouseUp;
        IconsList.PreviewMouseLeftButtonUp += List_PreviewMouseUp;
    }

    void OnInvalidated(Location loc) => Dispatcher.InvokeAsync(() => { if (loc == Current) Reload(keepSelection: true); });

    /// <summary>F5 / Refresh: ask the server again, skipping every cache for this place.</summary>
    public async void Refresh()
    {
        await Catalog.Shared.ForceRefresh(Current);
        Reload(keepSelection: true);
    }

    /// <summary>Our own favorite/hide/delete edits: update the shown photos in place (no re-download).</summary>
    void OnPhotosPatched(string account, string library, IReadOnlyList<PhotoAsset> updated, IReadOnlySet<string> removed) => Dispatcher.InvokeAsync(() =>
    {
        if (Current.Kind != LocKind.Album || Current.Account != account || Current.Library != library || ListingCache.EditSensitive.Contains(Current.Id)) return;
        var byID = updated.GroupBy(u => u.Id).ToDictionary(g => g.Key, g => g.First());
        foreach (var gone in _items.Where(i => i.Photo is { } p && removed.Contains(p.Id)).ToList()) _items.Remove(gone);
        foreach (var i in _items) if (i.Photo is { } p && byID.TryGetValue(p.Id, out var u)) { i.Photo = u; i.Refresh(); }
        BuildRows();
        UpdateStatus();
    });

    /// <summary>Called when the tab closes: stop listening and cancel any listing in flight.</summary>
    public void Detach()
    {
        Catalog.Shared.Invalidated -= OnInvalidated;
        Catalog.Shared.PhotosPatched -= OnPhotosPatched;
        _loadCts?.Cancel();
    }

    /// <summary>Copies a freshly built menu into an element's existing ContextMenu (WPF only opens menus that exist up front).</summary>
    public static bool Fill(ContextMenu target, ContextMenu? built)
    {
        target.Items.Clear();
        if (built is null) return false;
        foreach (var item in built.Items.Cast<object>().ToList()) { built.Items.Remove(item); target.Items.Add(item); }
        return target.Items.Count > 0;
    }

    public string Title => Catalog.Shared.Title(Current);
    public bool CanGoBack => _back.Count > 0;
    public bool CanGoForward => _forward.Count > 0;
    public bool CanGoUp => Catalog.Shared.Parent(Current) is not null;

    // MARK: Navigation

    public void Navigate(Location loc, bool record = true)
    {
        if (record && loc != Current) { _back.Add(Current); _forward.Clear(); }
        Current = loc;
        _filter = "";
        Reload();
        LocationChanged?.Invoke();
    }

    public void Back() { if (_back.Count == 0) return; _forward.Add(Current); var l = _back[^1]; _back.RemoveAt(_back.Count - 1); Current = l; Reload(); LocationChanged?.Invoke(); }
    public void Forward() { if (_forward.Count == 0) return; _back.Add(Current); var l = _forward[^1]; _forward.RemoveAt(_forward.Count - 1); Current = l; Reload(); LocationChanged?.Invoke(); }
    public void Up() { if (Catalog.Shared.Parent(Current) is { } p) Navigate(p); }

    public void SetFilter(string text)
    {
        _filter = text.Trim();
        _view.Refresh();
        if (Current.IsPhotoGrid) BuildRows();
        UpdateStatus();
    }

    public void SetViewMode(string mode)
    {
        _viewMode = mode;
        Settings.Current.ViewMode = mode;
        Settings.Current.Save();
        ApplyView();
    }

    public string ViewMode => Current.IsPhotoGrid ? "photos" : _viewMode;

    void ApplyView()
    {
        var photos = Current.IsPhotoGrid;
        DetailsList.Visibility = !photos && _viewMode == "details" ? Visibility.Visible : Visibility.Collapsed;
        IconsList.Visibility = !photos && _viewMode == "icons" ? Visibility.Visible : Visibility.Collapsed;
        PhotoGrid.Visibility = photos ? Visibility.Visible : Visibility.Collapsed;
        if (_viewMode == "icons") foreach (var i in _items) i.Icon = null;
        foreach (var i in _items) Thumbnails.Attach(i, _viewMode == "icons");
    }

    // MARK: Loading

    public async void Reload(bool keepSelection = false)
    {
        _loadCts?.Cancel();
        var cts = new CancellationTokenSource();
        _loadCts = cts;
        var keep = keepSelection ? Selected.Select(i => i.Key).ToHashSet() : [];
        var loc = Current;
        _items.Clear();
        _rows.Clear();
        ApplyView();
        IsLoading = true;
        ShowOverlay("Loading…", spinner: true);
        UpdateStatus();
        var streamed = new HashSet<string>();
        try
        {
            var items = await Catalog.Shared.List(loc, page => Dispatcher.InvokeAsync(() =>
            {
                if (cts.IsCancellationRequested) return;
                foreach (var i in page) if (streamed.Add(i.Key)) Add(i);
                HideOverlay();
                SortAndShow();
            }), cts.Token);
            if (cts.IsCancellationRequested) return;
            _items.Clear();
            foreach (var i in items) Add(i);
            SortAndShow();
            if (_items.Count == 0) ShowOverlay(EmptyText(loc), spinner: false); else HideOverlay();
            if (keep.Count > 0) Reselect(keep);
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            if (cts.IsCancellationRequested) return;
            var signIn = e is ICloudException { Kind: ICloudErrorKind.NeedsSignIn };
            ShowOverlay(e.Message, spinner: false, button: signIn ? "Sign In…" : "Try Again");
            Log.Status("listing failed: " + e.GetType().Name);
        }
        finally
        {
            if (_loadCts == cts) { IsLoading = false; UpdateStatus(); }
        }
    }

    void Add(Item i)
    {
        Thumbnails.Attach(i, _viewMode == "icons");
        _items.Add(i);
    }

    static string EmptyText(Location loc) => loc.Kind switch
    {
        LocKind.DriveTrash => (loc.AccountRef?.DeletedTitle ?? "Recently Deleted") + " is empty.",
        LocKind.Album => "No photos here.",
        _ => "This folder is empty. Drop files here to copy them in.",
    };

    void SortAndShow()
    {
        var foldersOnTop = Settings.Current.FoldersOnTop;
        Comparison<Item> cmp = _sortKey switch
        {
            "Date" => (a, b) => Nullable.Compare(a.Modified ?? a.Created, b.Modified ?? b.Created),
            "Size" => (a, b) => Nullable.Compare(a.Size, b.Size),
            "Kind" => (a, b) => string.Compare(a.KindText, b.KindText, StringComparison.CurrentCultureIgnoreCase),
            "Cloud" => (a, b) => string.Compare(a.CloudText, b.CloudText, StringComparison.CurrentCultureIgnoreCase),
            _ => (a, b) => NaturalComparer.Instance.Compare(a.Name, b.Name),
        };
        if (Current.IsPhotoGrid) cmp = (a, b) => Nullable.Compare(a.Photo?.Created, b.Photo?.Created);
        var list = _items.ToList();
        list.Sort((a, b) =>
        {
            if (foldersOnTop && a.IsContainer != b.IsContainer && !Current.IsPhotoGrid) return a.IsContainer ? -1 : 1;
            var c = cmp(a, b);
            if (c == 0) c = NaturalComparer.Instance.Compare(a.Name, b.Name);
            return _sortDesc && !Current.IsPhotoGrid ? -c : c;
        });
        if (!list.SequenceEqual(_items))
        {
            _items.Clear();
            foreach (var i in list) _items.Add(i);
        }
        if (Current.IsPhotoGrid) BuildRows();
        UpdateStatus();
    }

    void Header_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not GridViewColumnHeader { Tag: string key }) return;
        if (_sortKey == key) _sortDesc = !_sortDesc; else { _sortKey = key; _sortDesc = key is "Date" or "Size"; }
        SortAndShow();
    }

    void Reselect(HashSet<string> keys)
    {
        var list = ActiveList;
        if (list is null) { foreach (var i in _items) i.IsSelected = keys.Contains(i.Key); return; }
        list.SelectedItems.Clear();
        foreach (var i in _items.Where(i => keys.Contains(i.Key))) list.SelectedItems.Add(i);
    }

    // MARK: Photo grid rows

    void PhotoGrid_SizeChanged(object sender, SizeChangedEventArgs e) { if (Current.IsPhotoGrid && e.WidthChanged) { _relayout.Stop(); _relayout.Start(); } }

    void BuildRows()
    {
        var width = Math.Max(200, PhotoGrid.ActualWidth - 36);
        var tile = TileSize + 4;
        var perRow = Math.Max(1, (int)(width / tile));
        var visible = _items.Where(i => _filter.Length == 0 || i.Name.Contains(_filter, StringComparison.CurrentCultureIgnoreCase)).ToList();
        var rows = new List<PhotoRow>();
        var byMonth = Settings.Current.GroupPhotosByMonth;
        string? month = null;
        var cur = new List<Item>();
        void Flush() { if (cur.Count > 0) { rows.Add(new PhotoRow { Cells = cur }); cur = []; } }
        foreach (var i in visible)
        {
            if (byMonth)
            {
                var m = i.Photo?.Created is { } d ? d.ToLocalTime().ToString("MMMM yyyy", CultureInfo.CurrentCulture) : "Unknown date";
                if (m != month) { Flush(); rows.Add(new PhotoRow { Header = m }); month = m; }
            }
            cur.Add(i);
            if (cur.Count == perRow) Flush();
        }
        Flush();
        _rows.Clear();
        foreach (var r in rows) _rows.Add(r);
    }

    void Tile_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: Item item }) _ = Thumbnails.Load(item, (int)Math.Max(240, TileSize * 2), _loadCts?.Token ?? default);
    }

    void IconCell_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: Item item } && Thumbnails.CanPreview(item)) _ = Thumbnails.Load(item, 160, _loadCts?.Token ?? default);
    }

    /// <summary>Details view: small previews too (rows are recycled, so also when a row gets a new item).</summary>
    void NameCell_Loaded(object sender, RoutedEventArgs e) => NameCell(sender);
    void NameCell_DataContextChanged(object sender, DependencyPropertyChangedEventArgs e) => NameCell(sender);
    void NameCell(object sender)
    {
        if (sender is FrameworkElement { DataContext: Item item, IsLoaded: true } && Thumbnails.CanPreview(item)) _ = Thumbnails.Load(item, 64, _loadCts?.Token ?? default);
    }

    void Tile_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: Item item } el) return;
        PhotoGrid.Focus();
        if (e.ClickCount == 2) { _ = Ops.Open([item], this); e.Handled = true; return; }
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (shift && _anchor is not null)
        {
            var a = _items.IndexOf(_anchor); var b = _items.IndexOf(item);
            if (!ctrl) foreach (var i in _items) i.IsSelected = false;
            for (int k = Math.Min(a, b); k <= Math.Max(a, b); k++) if (k >= 0) _items[k].IsSelected = true;
        }
        else if (ctrl) { item.IsSelected = !item.IsSelected; _anchor = item; }
        else
        {
            if (!item.IsSelected) { foreach (var i in _items) i.IsSelected = false; item.IsSelected = true; }
            _anchor = item;
        }
        _dragStart = e.GetPosition(this);
        _dragArmed = true;
        SelectionChanged?.Invoke();
        UpdateStatus();
        e.Handled = true;
    }

    void Tile_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragArmed || e.LeftButton != MouseButtonState.Pressed) { _dragArmed = false; return; }
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragArmed = false;
        StartDrag(Selected);
    }

    void Tile_RightClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: Item item } el) return;
        if (!item.IsSelected) { foreach (var i in _items) i.IsSelected = false; item.IsSelected = true; _anchor = item; SelectionChanged?.Invoke(); }
        var menu = Host?.BuildContextMenu(this, Selected);
        if (menu is null) return;
        menu.PlacementTarget = el;
        menu.IsOpen = true;
        e.Handled = true;
    }

    void PhotoGrid_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control) { foreach (var i in _items) i.IsSelected = true; SelectionChanged?.Invoke(); UpdateStatus(); e.Handled = true; }
        if (e.Key == Key.Enter) { _ = Ops.Open(Selected, this); e.Handled = true; }
    }

    // MARK: Lists

    ListBox? ActiveList => Current.IsPhotoGrid ? null : _viewMode == "icons" ? IconsList : DetailsList;

    public IReadOnlyList<Item> Selected => ActiveList is { } l ? l.SelectedItems.Cast<Item>().ToList() : _items.Where(i => i.IsSelected).ToList();
    public IReadOnlyList<Item> AllItems => _items;

    public void SelectAll()
    {
        if (ActiveList is { } l) l.SelectAll(); else foreach (var i in _items) i.IsSelected = true;
        UpdateStatus();
    }

    void List_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement((ItemsControl)sender, d) is ListBoxItem { DataContext: Item item })
            Activate(item);
    }

    public void Activate(Item item)
    {
        if (item.Target is { } t) Navigate(t);
        else _ = Ops.Open([item], this);
    }

    void List_SelectionChanged(object sender, SelectionChangedEventArgs e) { SelectionChanged?.Invoke(); UpdateStatus(); }

    ListBoxItem? _pendingSingle;

    void List_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(this);
        var container = e.OriginalSource is DependencyObject d ? ItemsControl.ContainerFromElement((ItemsControl)sender, d) as ListBoxItem : null;
        _dragArmed = container is not null;
        _pendingSingle = null;
        // Like Explorer: pressing on an already-selected item keeps the multi-selection so it can be dragged;
        // it collapses to that one item on release if no drag happened.
        if (container is { IsSelected: true } && Keyboard.Modifiers == ModifierKeys.None && e.ClickCount == 1 && ((ListBox)sender).SelectedItems.Count > 1)
        {
            _pendingSingle = container;
            container.Focus();
            e.Handled = true;
        }
    }

    void List_PreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_pendingSingle is { } c && sender is ListBox lb)
        {
            lb.SelectedItems.Clear();
            c.IsSelected = true;
        }
        _pendingSingle = null;
    }

    void List_PreviewRightDown(object sender, MouseButtonEventArgs e)
    {
        var container = e.OriginalSource is DependencyObject d ? ItemsControl.ContainerFromElement((ItemsControl)sender, d) as ListBoxItem : null;
        if (container is null) ((ListBox)sender).SelectedItems.Clear();   // right-click on empty space: folder commands
        else if (!container.IsSelected) { ((ListBox)sender).SelectedItems.Clear(); container.IsSelected = true; }
    }

    void List_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (!_dragArmed || e.LeftButton != MouseButtonState.Pressed) return;
        var p = e.GetPosition(this);
        if (Math.Abs(p.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(p.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragArmed = false;
        _pendingSingle = null;
        var sel = Selected;
        if (sel.Count > 0) StartDrag(sel);
    }

    void List_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var fe = (FrameworkElement)sender;
        fe.ContextMenu ??= new ContextMenu();
        if (!Fill(fe.ContextMenu, Host?.BuildContextMenu(this, Selected))) e.Handled = true;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        var sel = Selected;
        if (e.Key == Key.Enter && sel.Count == 1 && Current.Kind != LocKind.DriveTrash) { Activate(sel[0]); e.Handled = true; }
        else if (e.Key == Key.Back && Keyboard.FocusedElement is not TextBox) { Back(); e.Handled = true; }
    }

    // MARK: Status

    public void UpdateStatus()
    {
        var n = _view.Cast<object>().Count();
        var sel = Selected;
        var s = IsLoading && n > 0 ? $"Loading… {n} items" : $"{n} item{(n == 1 ? "" : "s")}";
        if (sel.Count > 0)
        {
            var bytes = sel.Sum(i => i.Size ?? 0);
            s += $", {sel.Count} selected" + (bytes > 0 ? $" ({bytes.ByteString()})" : "");
        }
        if (Current.Kind == LocKind.Local && VolumeInfo.Info(Current.Path!) is { } v) s += $" — {v.Available.ByteString()} free on {v.DisplayName}";
        if (Catalog.Shared.Caps(Current).IsICloud && SafetyPolicy.ReadOnlyICloud) s += " — read-only";
        Status = s;
        StatusChanged?.Invoke();
    }

    void ShowOverlay(string text, bool spinner, string? button = null)
    {
        Overlay.Visibility = Visibility.Visible;
        Spinner.Visibility = spinner ? Visibility.Visible : Visibility.Collapsed;
        OverlayText.Text = text;
        OverlayButton.Visibility = button is null ? Visibility.Collapsed : Visibility.Visible;
        OverlayButton.Content = button;
    }

    void HideOverlay() => Overlay.Visibility = Visibility.Collapsed;

    void OverlayButton_Click(object sender, RoutedEventArgs e)
    {
        if ((string?)OverlayButton.Content == "Sign In…" && Current.AccountRef is { } a) Host?.SignIn(a.AppleID);
        else Reload();
    }

    // MARK: Drag and drop

    void StartDrag(IReadOnlyList<Item> items)
    {
        if (items.Count == 0 || items.Any(i => i.Volume is not null)) return;
        var data = new CirrusDataObject(items, Current);
        var localOnly = items.All(i => i.LocalPath is not null);
        var lockedICloud = SafetyPolicy.ReadOnlyICloud && items.Any(i => i.LocalPath is { } p && SafetyPolicy.TouchesICloud(p));
        var effects = localOnly && !lockedICloud ? DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link : DragDropEffects.Copy;
        try { DragDrop.DoDragDrop(this, data, effects); }
        catch (Exception e) { Log.Status("drag failed: " + e.GetType().Name); }
        finally { data.Finish(); }
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = DropEffect(e, Current);
        e.Handled = true;
    }

    public static DragDropEffects DropEffect(DragEventArgs e, Location target)
    {
        var caps = Catalog.Shared.Caps(target);
        if (!caps.AcceptsDrops) return DragDropEffects.None;
        if (e.Data.GetDataPresent(CirrusDataObject.InternalFormat))
        {
            if (e.Data.GetData(CirrusDataObject.InternalFormat) is CirrusDataObject.Payload p && p.Source == target) return DragDropEffects.None;
            return e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey) ? DragDropEffects.Move : DragDropEffects.Copy;
        }
        if (e.Data.GetDataPresent(DataFormats.FileDrop))
            return e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey) && target.Kind == LocKind.Local ? DragDropEffects.Move : DragDropEffects.Copy;
        return DragDropEffects.None;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        _ = HandleDrop(e.Data, Current, e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey), this);
    }

    /// <summary>Drops from Explorer (upload/import with preflight) or from another Cirrus tab.</summary>
    public static async Task HandleDrop(IDataObject data, Location target, bool move, DependencyObject owner)
    {
        if (!Catalog.Shared.Caps(target).AcceptsDrops) return;
        var dest = await Ops.DestinationFor(target);
        if (dest is null) { Dialogs.Info(owner, "Can’t drop here", "This place doesn’t accept new items."); return; }
        if (data.GetData(CirrusDataObject.InternalFormat) is CirrusDataObject.Payload p)
        {
            if (p.Source == target) return;
            await Ops.Transfer(p.Items, dest, move, owner);
            return;
        }
        if (data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0)
            await Ops.Deliver(files, dest, move && target.Kind == LocKind.Local, owner);
    }

    public void FocusList()
    {
        if (ActiveList is { } l) { l.Focus(); if (l.SelectedIndex < 0 && l.Items.Count > 0) l.SelectedIndex = 0; }
        else PhotoGrid.Focus();
    }
}
