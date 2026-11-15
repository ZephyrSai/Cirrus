using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Cirrus.App.Model;
using Cirrus.App.Platform;
using Cirrus.App.Services;
using Cirrus.Core;

namespace Cirrus.App.UI;

public partial class MainWindow : Window
{
    readonly TransfersPanel _transfers = new();
    readonly DispatcherTimer _sidebarRefresh;
    List<Item> _clipboard = [];
    Location? _clipboardSource;
    bool _syncingSidebar;

    public MainWindow()
    {
        InitializeComponent();
        TransfersHost.Child = _transfers;
        _sidebarRefresh = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _sidebarRefresh.Tick += (_, _) => { _sidebarRefresh.Stop(); BuildSidebar(); };
        AccountManager.Shared.Changed += () => Dispatcher.InvokeAsync(() => { _sidebarRefresh.Stop(); _sidebarRefresh.Start(); });
        SyncStore.Shared.Changed += () => Dispatcher.InvokeAsync(() => { _sidebarRefresh.Stop(); _sidebarRefresh.Start(); });
        TransferManager.Shared.Changed += () => Dispatcher.InvokeAsync(UpdateTransferStatus);
        Sidebar.Drop += Sidebar_Drop;
        Sidebar.DragOver += Sidebar_DragOver;
        PreviewKeyDown += OnKey;
        Loaded += (_, _) =>
        {
            BuildSidebar();
            OpenTab(StartLocation());
            UpdateReadOnlyBanner();
            if (BuildInfo.IsTester && Settings.Current.ReadOnlyICloud)
                ShowBanner("This is a tester build: it starts in read-only mode, so nothing in iCloud can change until you turn that off in Settings › Safety.", false);
        };
        Closing += (_, e) =>
        {
            if (TransferManager.Shared.Active.Count > 0 &&
                !Dialogs.Confirm(this, "Transfers are still running", $"{TransferManager.Shared.Active.Count} transfer(s) will stop if you quit now.", "Quit Anyway", destructive: true))
                e.Cancel = true;
        };
    }

    static Location StartLocation()
    {
        var am = AccountManager.Shared;
        if (am.Accounts.FirstOrDefault(a => a.Kind == AccountKind.Demo) is { } demo) return Location.Drive(demo.Id, demo.Drive!.RootID);
        if (am.WebAccounts.FirstOrDefault(a => a.Status != AccountStatus.NeedsSignIn) is { Drive: { } d } web) return Location.Drive(web.Id, d.RootID);
        if (am.NativeAccount?.DriveRoot is { } root) return Location.Local(root);
        return Location.Home();
    }

    // MARK: Tabs

    public BrowserTab? ActiveTab => (Tabs.SelectedItem as TabItem)?.Content as BrowserTab;

    public void OpenTab(Location loc)
    {
        var tab = new BrowserTab { Host = this };
        var title = new TextBlock { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis };
        var glyph = new TextBlock { Style = (Style)FindResource("IconText"), FontSize = 12, Margin = new Thickness(0, 0, 6, 0) };
        var close = new Button { Content = new TextBlock { Text = "\uE711", Style = (Style)FindResource("IconText"), FontSize = 9 }, Padding = new Thickness(4), Margin = new Thickness(8, 0, 0, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = "Close tab (Ctrl+W)" };
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(glyph); header.Children.Add(title); header.Children.Add(close);
        var item = new TabItem { Header = header, Content = tab };
        close.Click += (_, _) => CloseTab(item);
        header.MouseDown += (_, e) => { if (e.ChangedButton == MouseButton.Middle) CloseTab(item); };
        item.AllowDrop = true;
        item.DragOver += (_, e) => { Tabs.SelectedItem = item; e.Effects = BrowserTab.DropEffect(e, tab.Current); e.Handled = true; };
        item.Drop += (_, e) => { e.Handled = true; _ = BrowserTab.HandleDrop(e.Data, tab.Current, e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey), this); };
        tab.LocationChanged += () =>
        {
            title.Text = Catalog.Shared.Title(tab.Current);
            glyph.Text = Catalog.Glyph(tab.Current);
            if (tab == ActiveTab) SyncChrome();
        };
        tab.SelectionChanged += () => { if (tab == ActiveTab) SyncToolbar(); };
        tab.StatusChanged += () => { if (tab == ActiveTab) StatusText.Text = tab.Status; };
        Tabs.Items.Add(item);
        Tabs.SelectedItem = item;
        tab.Navigate(loc, record: false);
    }

    void CloseTab(TabItem item)
    {
        if (Tabs.Items.Count <= 1) { (item.Content as BrowserTab)?.Navigate(Location.Home()); return; }
        (item.Content as BrowserTab)?.Detach();
        Tabs.Items.Remove(item);
    }

    void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (e.OriginalSource == Tabs) SyncChrome(); }

    void SyncChrome()
    {
        if (ActiveTab is not { } tab) return;
        Title = "Cirrus — " + Catalog.Shared.LongTitle(tab.Current);
        BuildPathBar(tab.Current);
        SyncToolbar();
        StatusText.Text = tab.Status;
        if (FilterBox.Text.Length > 0) FilterBox.Text = "";
        SelectSidebar(tab.Current);
    }

    void SyncToolbar()
    {
        if (ActiveTab is not { } tab) return;
        BackButton.IsEnabled = tab.CanGoBack;
        ForwardButton.IsEnabled = tab.CanGoForward;
        UpButton.IsEnabled = tab.CanGoUp;
        var caps = Catalog.Shared.Caps(tab.Current);
        NewFolderButton.IsEnabled = caps.CanCreateFolder;
        NewFolderButton.ToolTip = caps.NewFolderTitle + " (Ctrl+Shift+N)";
        var photos = tab.Current.IsPhotoGrid;
        DetailsView.IsEnabled = IconsView.IsEnabled = !photos;
        DetailsView.IsChecked = !photos && tab.ViewMode == "details";
        IconsView.IsChecked = !photos && tab.ViewMode == "icons";
    }

    void BuildPathBar(Location loc)
    {
        PathBar.Children.Clear();
        var crumbs = Catalog.Shared.Breadcrumbs(loc);
        if (loc.IsRemote)
            PathBar.Children.Add(new TextBlock { Text = Catalog.Shared.AccountTitle(loc), Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0) });
        foreach (var c in crumbs)
        {
            if (PathBar.Children.Count > 0)
                PathBar.Children.Add(new TextBlock { Text = "\uE76C", Style = (Style)FindResource("IconText"), FontSize = 9, Opacity = 0.6, Margin = new Thickness(2, 0, 2, 0) });
            var b = new Button { Content = Catalog.Shared.Title(c), Padding = new Thickness(6, 2, 6, 2), Background = Brushes.Transparent, BorderThickness = new Thickness(0), AllowDrop = true };
            var target = c;
            b.Click += (_, _) => ActiveTab?.Navigate(target);
            b.DragOver += (_, e) => { e.Effects = BrowserTab.DropEffect(e, target); e.Handled = true; };
            b.Drop += (_, e) => { e.Handled = true; _ = BrowserTab.HandleDrop(e.Data, target, e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey), this); };
            PathBar.Children.Add(b);
        }
        PathScroll.ScrollToRightEnd();
    }

    // MARK: Toolbar

    void Back_Click(object sender, RoutedEventArgs e) => ActiveTab?.Back();
    void Forward_Click(object sender, RoutedEventArgs e) => ActiveTab?.Forward();
    void Up_Click(object sender, RoutedEventArgs e) => ActiveTab?.Up();
    void Refresh_Click(object sender, RoutedEventArgs e) => ActiveTab?.Refresh();
    void NewTab_Click(object sender, RoutedEventArgs e) => OpenTab(ActiveTab?.Current ?? Location.Home());
    void Filter_Changed(object sender, TextChangedEventArgs e) => ActiveTab?.SetFilter(FilterBox.Text);
    void View_Click(object sender, RoutedEventArgs e) { if (sender is ToggleButton { Tag: string mode }) ActiveTab?.SetViewMode(mode); SyncToolbar(); }

    async void NewFolder_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveTab is { } tab && Catalog.Shared.Caps(tab.Current).CanCreateFolder) await Ops.NewFolder(tab.Current, this);
    }

    void TransfersToggle_Click(object sender, RoutedEventArgs e) => SetTransfersVisible(TransfersToggle.IsChecked == true);

    public void SetTransfersVisible(bool visible)
    {
        TransfersHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        TransfersToggle.IsChecked = visible;
        if (visible) _transfers.Refresh();
    }

    void UpdateTransferStatus()
    {
        var tm = TransferManager.Shared;
        var (done, total, count) = tm.Overall;
        TransferBadge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        TransferBadgeText.Text = count.ToString();
        var running = tm.Transfers.Where(t => t.State == TransferState.Running).ToList();
        var speed = running.Sum(t => t.Speed);
        TransferStatus.Text = count == 0 ? "" : $"{count} transfer{(count == 1 ? "" : "s")}" + (total > 0 ? $" — {done.ByteString()} of {total.ByteString()}" : "") + (speed > 1 ? $" — {((long)speed).ByteString()}/s" : "");
        if (TransfersHost.Visibility == Visibility.Visible) _transfers.Refresh();
        if (count > 0 && TransfersHost.Visibility != Visibility.Visible && tm.Transfers.Count(t => !t.IsFinished) == 1 && running.Count <= 1 && !_autoOpened)
        {
            _autoOpened = true;
            SetTransfersVisible(true);
        }
    }
    bool _autoOpened;

    void Menu_Click(object sender, RoutedEventArgs e)
    {
        var m = new ContextMenu { PlacementTarget = MenuButton, Placement = PlacementMode.Bottom };
        m.Items.Add(MenuItem("New Tab", "\uE710", () => OpenTab(ActiveTab?.Current ?? Location.Home()), "Ctrl+T"));
        m.Items.Add(MenuItem("New Window", "\uE8A7", () => { var w = new MainWindow(); w.Show(); }, "Ctrl+N"));
        m.Items.Add(new Separator());
        m.Items.Add(MenuItem("Back Up iCloud…", "\uE8F7", () => ShowBackup()));
        m.Items.Add(MenuItem("Sync Jobs…", "\uE895", () => ShowSyncJobs()));
        m.Items.Add(MenuItem("Transfers", "\uE896", () => SetTransfersVisible(true)));
        m.Items.Add(new Separator());
        m.Items.Add(MenuItem("Add Apple ID…", "\uE8FA", () => SignIn(null)));
        m.Items.Add(MenuItem("Settings…", "\uE713", () => ShowSettings(), "Ctrl+,"));
        m.IsOpen = true;
    }

    static MenuItem MenuItem(string header, string? glyph, Action action, string? gesture = null, bool enabled = true)
    {
        var mi = new MenuItem { Header = header, InputGestureText = gesture ?? "", IsEnabled = enabled };
        if (glyph is not null) mi.Icon = new TextBlock { Text = glyph, FontFamily = (FontFamily)Application.Current.Resources["IconFont"], FontSize = 14 };
        mi.Click += (_, _) => action();
        return mi;
    }

    // MARK: Banners

    public void ShowBanner(string message, bool attention)
    {
        BannerText.Text = message;
        Banner.Visibility = Visibility.Visible;
    }

    void DismissBanner_Click(object sender, RoutedEventArgs e) => Banner.Visibility = Visibility.Collapsed;
    void SafetySettings_Click(object sender, RoutedEventArgs e) => ShowSettings();

    public void UpdateReadOnlyBanner()
    {
        ReadOnlyBanner.Visibility = SafetyPolicy.ReadOnlyICloud ? Visibility.Visible : Visibility.Collapsed;
        SyncToolbar();
        ActiveTab?.UpdateStatus();
    }

    // MARK: Windows

    public void SignIn(string? appleID)
    {
        var w = new SignInWindow(appleID) { Owner = this };
        if (w.ShowDialog() == true && w.SignedInAccount is { } acct && acct.Drive is { } d)
            ActiveTab?.Navigate(Location.Drive(acct.Id, d.RootID));
    }

    public void ShowSettings()
    {
        var w = new SettingsWindow { Owner = this };
        w.ShowDialog();
        UpdateReadOnlyBanner();
        BuildSidebar();
        ActiveTab?.Reload(keepSelection: true);
    }

    public void ShowBackup(string? accountID = null) => new BackupWindow(accountID) { Owner = this }.Show();
    public void ShowSyncJobs() => new SyncJobsWindow { Owner = this }.Show();

    // MARK: Keyboard

    void OnKey(object sender, KeyEventArgs e)
    {
        var tab = ActiveTab;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        var alt = Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var inText = Keyboard.FocusedElement is TextBox;
        bool handled = true;
        if (alt && key == Key.Left) tab?.Back();
        else if (alt && key == Key.Right) tab?.Forward();
        else if (alt && key == Key.Up) tab?.Up();
        else if (key == Key.F5 || (ctrl && key == Key.R)) tab?.Refresh();
        else if (ctrl && key == Key.T) OpenTab(tab?.Current ?? Location.Home());
        else if (ctrl && key == Key.W && Tabs.SelectedItem is TabItem ti) CloseTab(ti);
        else if (ctrl && key == Key.N && !shift) new MainWindow().Show();
        else if (ctrl && shift && key == Key.N && tab is not null && Catalog.Shared.Caps(tab.Current).CanCreateFolder) _ = Ops.NewFolder(tab.Current, this);
        else if (ctrl && key == Key.F) { FilterBox.Focus(); FilterBox.SelectAll(); }
        else if (ctrl && key == Key.OemComma) ShowSettings();
        else if (ctrl && key == Key.Tab && Tabs.Items.Count > 1) Tabs.SelectedIndex = (Tabs.SelectedIndex + (shift ? Tabs.Items.Count - 1 : 1)) % Tabs.Items.Count;
        else if (inText) handled = false;
        else if (tab is null) handled = false;
        else if (key == Key.Delete) _ = Remove(tab, tab.Selected);
        else if (key == Key.F2 && tab.Selected.Count == 1 && Catalog.Shared.Caps(tab.Current).CanRename) _ = Ops.Rename(tab.Selected[0], tab.Current, this);
        else if (ctrl && key == Key.C) CopyToClipboard(tab);
        else if (ctrl && key == Key.V) _ = Paste(tab);
        else if (ctrl && key == Key.A) tab.SelectAll();
        else if (key == Key.Escape && FilterBox.Text.Length > 0) FilterBox.Text = "";
        else handled = false;
        if (handled) e.Handled = true;
    }

    void CopyToClipboard(BrowserTab tab)
    {
        _clipboard = tab.Selected.ToList();
        _clipboardSource = tab.Current;
        var local = _clipboard.Where(i => i.LocalPath is not null && i.Volume is null).Select(i => i.LocalPath!).ToList();
        try
        {
            if (local.Count == _clipboard.Count && local.Count > 0)
            {
                var sc = new System.Collections.Specialized.StringCollection();
                sc.AddRange(local.ToArray());
                Clipboard.SetFileDropList(sc);
            }
        }
        catch { }
        if (_clipboard.Count > 0) StatusText.Text = $"Copied {_clipboard.Count} item{(_clipboard.Count == 1 ? "" : "s")}. Paste (Ctrl+V) in another folder.";
    }

    async Task Paste(BrowserTab tab)
    {
        var dest = await Ops.DestinationFor(tab.Current);
        if (dest is null) { Dialogs.Info(this, "Can’t paste here", "This place doesn’t accept new items."); return; }
        if (_clipboard.Count > 0 && _clipboardSource != tab.Current) { await Ops.Transfer(_clipboard, dest, false, this); return; }
        try
        {
            if (Clipboard.ContainsFileDropList())
                await Ops.Deliver(Clipboard.GetFileDropList().Cast<string>().ToList(), dest, false, this);
        }
        catch (Exception e) { Ops.ShowError(e, "Couldn’t paste", this); }
    }

    async Task Remove(BrowserTab tab, IReadOnlyList<Item> sel)
    {
        if (sel.Count == 0) return;
        var caps = Catalog.Shared.Caps(tab.Current);
        if (caps.IsTrash && caps.CanDeleteForever) await Ops.DeleteForever(sel, tab.Current, this);
        else if (caps.CanTrash) await Ops.Trash(sel, tab.Current, this);
    }

    // MARK: Context menu

    public ContextMenu BuildContextMenu(BrowserTab tab, IReadOnlyList<Item> sel)
    {
        var m = new ContextMenu();
        var loc = tab.Current;
        var caps = Catalog.Shared.Caps(loc);
        var one = sel.Count == 1 ? sel[0] : null;
        var ro = SafetyPolicy.ReadOnlyICloud;
        if (sel.Count > 0)
        {
            if (one?.Target is { } t)
            {
                m.Items.Add(MenuItem("Open", "\uE8E5", () => tab.Navigate(t)));
                m.Items.Add(MenuItem("Open in New Tab", "\uE8A7", () => OpenTab(t)));
            }
            else if (!caps.IsTrash) m.Items.Add(MenuItem("Open", "\uE8E5", () => _ = Ops.Open(sel, this)));
            if (sel.Any(i => i.LocalPath is null))
                m.Items.Add(MenuItem("Download To…", "\uE896", () => _ = DownloadTo(sel)));
            if (!caps.IsTrash)
            {
                m.Items.Add(MenuItem("Copy To…", "\uE8C8", () => _ = CopyMoveTo(tab, sel, false)));
                if (caps.CanTrash) m.Items.Add(MenuItem("Move To…", "\uE8DE", () => _ = CopyMoveTo(tab, sel, true)));
                m.Items.Add(MenuItem("Copy", "\uE8C8", () => CopyToClipboard(tab), "Ctrl+C"));
            }
            if (one is not null && one.LocalPath is { } lp && one.Volume is null)
                m.Items.Add(MenuItem("Show in Explorer", "\uEC50", () => Ops.ShowInExplorer(lp)));
            if (caps.IsICloud && loc.Kind == LocKind.Local && sel.All(i => i.LocalPath is not null))
            {
                m.Items.Add(new Separator());
                m.Items.Add(MenuItem("Always Keep on This Device", "\uE896", () => { Ops.KeepOnDevice(sel, this); tab.Reload(true); }));
                m.Items.Add(MenuItem("Free Up Space", "\uE753", () => { Ops.FreeUpSpace(sel, this); tab.Reload(true); }));
            }
            if (sel.Any(i => i.IsPhoto) && !caps.IsTrash)
            {
                m.Items.Add(new Separator());
                var fav = sel.All(i => i.IsFavorite);
                m.Items.Add(MenuItem(fav ? "Remove from Favorites" : "Favorite", fav ? "\uEB51" : "\uEB52", () => _ = Ops.SetFavorite(sel, !fav, loc, this), enabled: !ro));
                var hidden = loc.Id == "smart:Hidden";
                m.Items.Add(MenuItem(hidden ? "Unhide" : "Hide", "\uED1A", () => _ = Ops.SetHidden(sel, !hidden, loc, this), enabled: !ro));
            }
            m.Items.Add(new Separator());
            if (caps.CanRename && one is not null && one.Album is null)
                m.Items.Add(MenuItem("Rename", "\uE8AC", () => _ = Ops.Rename(one, loc, this), "F2"));
            if (caps.IsTrash)
            {
                m.Items.Add(MenuItem("Recover", "\uE777", () => _ = Ops.Restore(sel, loc, this), enabled: !ro));
                if (loc.Kind == LocKind.DriveTrash)
                    m.Items.Add(MenuItem("Delete Immediately…", "\uE74D", () => _ = Ops.DeleteForever(sel, loc, this), "Del", enabled: !ro));
            }
            else if (caps.CanTrash && sel.All(i => i.Album is null && i.Volume is null))
            {
                var label = loc.Kind == LocKind.Local ? "Move to Recycle Bin" : sel.Any(i => i.IsPhoto) ? "Delete (to Recently Deleted)" : "Move to Recently Deleted";
                m.Items.Add(MenuItem(label, "\uE74D", () => _ = Ops.Trash(sel, loc, this), "Del"));
            }
        }
        else
        {
            if (caps.CanCreateFolder) m.Items.Add(MenuItem(caps.NewFolderTitle, "\uE8F4", () => _ = Ops.NewFolder(loc, this), "Ctrl+Shift+N"));
            if (caps.AcceptsDrops) m.Items.Add(MenuItem("Paste", "\uE77F", () => _ = Paste(tab), "Ctrl+V"));
            m.Items.Add(MenuItem("Refresh", "\uE72C", () => tab.Refresh(), "F5"));
            if (loc.Kind == LocKind.Local) m.Items.Add(MenuItem("Open in Explorer", "\uEC50", () => Ops.ShowInExplorer(loc.Path!)));
            if (loc.Kind == LocKind.Local && !Settings.Current.Favorites.Contains(loc.Path!, StringComparer.OrdinalIgnoreCase))
                m.Items.Add(MenuItem("Add to Favorites", "\uE734", () => { Settings.Current.Favorites.Add(loc.Path!); Settings.Current.Save(); BuildSidebar(); }));
        }
        if (m.Items.Count > 0 && m.Items[^1] is Separator) m.Items.RemoveAt(m.Items.Count - 1);
        return m;
    }

    async Task DownloadTo(IReadOnlyList<Item> sel)
    {
        var dlg = new Microsoft.Win32.OpenFolderDialog { Title = "Download to", InitialDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads") };
        if (dlg.ShowDialog(this) != true) return;
        await Ops.Transfer(sel, new Destination.Local(dlg.FolderName), false, this);
    }

    async Task CopyMoveTo(BrowserTab tab, IReadOnlyList<Item> sel, bool move)
    {
        var picker = new LocationPicker(move ? "Move To" : "Copy To", move ? "Move" : "Copy", tab.Current) { Owner = this };
        if (picker.ShowDialog() != true || picker.Chosen is not { } target) return;
        var dest = await Ops.DestinationFor(target);
        if (dest is null) { Dialogs.Info(this, "Can’t put items there", "That place doesn’t accept new items."); return; }
        await Ops.Transfer(sel, dest, move, this);
    }

    // MARK: Sidebar

    sealed record SidebarAction(Action Run);

    void BuildSidebar()
    {
        _syncingSidebar = true;
        Sidebar.Items.Clear();
        TreeViewItem Section(string title)
        {
            var s = new TreeViewItem
            {
                Header = new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Opacity = 0.7, FontSize = 12, Margin = new Thickness(0, 8, 0, 2) },
                IsExpanded = true, Focusable = false,
            };
            Sidebar.Items.Add(s);
            return s;
        }
        TreeViewItem Node(ItemsControl parent, string title, string glyph, object tag, Brush? tint = null)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            var g = new TextBlock { Text = glyph, Style = (Style)FindResource("IconText"), FontSize = 14, Margin = new Thickness(0, 0, 8, 0) };
            if (tint is not null) g.Foreground = tint;
            sp.Children.Add(g);
            sp.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            var n = new TreeViewItem { Header = sp, Tag = tag, AllowDrop = tag is Location };
            n.ContextMenu = new ContextMenu();
            n.ContextMenuOpening += (_, e) => { if (!BrowserTab.Fill(n.ContextMenu, SidebarMenu(tag))) e.Handled = true; };
            parent.Items.Add(n);
            return n;
        }

        var fav = Section("Favorites");
        foreach (var p in Settings.Current.Favorites.Where(Directory.Exists))
            Node(fav, Catalog.Shared.Title(Location.Local(p)), "\uE8B7", Location.Local(p));

        var am = AccountManager.Shared;
        if (am.NativeAccount is { } native)
        {
            var s = Section("iCloud for Windows");
            if (native.DriveRoot is { } dr) Node(s, "iCloud Drive", "\uE753", Location.Local(dr));
            if (native.PhotosRoot is { } pr) Node(s, "iCloud Photos", "\uEB9F", Location.Local(pr));
        }
        foreach (var a in am.Accounts.Where(a => a.Kind != AccountKind.Native))
        {
            var s = Section(a.Kind == AccountKind.Demo ? "Demo iCloud" : "iCloud — " + a.Title);
            s.Tag = a;
            s.ContextMenu = SidebarMenu(a);
            if (a.Status == AccountStatus.NeedsSignIn)
            {
                Node(s, "Sign In…", "\uE7BA", new SidebarAction(() => SignIn(a.AppleID)), Brushes.DarkOrange);
                continue;
            }
            if (a.Status == AccountStatus.WaitingForApproval)
                Node(s, "Approve on your Apple device…", "\uE8D7", new SidebarAction(() => Dialogs.Info(this, "Waiting for approval",
                    "Advanced Data Protection is on. Approve the request on your iPhone, iPad or Mac to let Cirrus read this iCloud data.")), Brushes.DarkOrange);
            if (a.Drive is { } d)
            {
                Node(s, "iCloud Drive", "\uE753", Location.Drive(a.Id, d.RootID));
                Node(s, "Recently Deleted", "\uE74D", Location.DriveTrash(a.Id));
            }
            if (a.Photos is not null)
            {
                var lib = a.PrimaryLibraryID;
                Node(s, "Photos", "\uEB9F", Location.Album(a.Id, lib, "smart:All Photos"));
                var albums = Node(s, "Albums", "\uE8B9", Location.Photos(a.Id, lib));
                albums.Items.Add(new TreeViewItem { Header = "Loading…", IsEnabled = false });
                albums.Expanded += async (_, _) =>
                {
                    if (albums.Items.Count != 1 || albums.Items[0] is not TreeViewItem { IsEnabled: false }) return;
                    try
                    {
                        var list = await Catalog.Shared.Albums(a, lib);
                        albums.Items.Clear();
                        foreach (var al in list.Where(x => x.Kind is PhotoAlbumKind.Album or PhotoAlbumKind.Shared && x.ParentID is null).OrderBy(x => x.Name, NaturalComparer.Instance))
                            Node(albums, al.Name, "\uE8B9", Location.Album(a.Id, lib, al.Id));
                        foreach (var f in list.Where(x => x.Kind == PhotoAlbumKind.Folder && x.ParentID is null))
                            Node(albums, f.Name, "\uE8B7", Location.Photos(a.Id, lib, f.Id));
                    }
                    catch (Exception e) { albums.Items.Clear(); albums.Items.Add(new TreeViewItem { Header = e.Message, IsEnabled = false }); }
                };
                Node(s, "Photos Recently Deleted", "\uE74D", Location.Album(a.Id, lib, "smart:Recently Deleted"));
            }
            Node(s, "Back Up…", "\uE8F7", new SidebarAction(() => ShowBackup(a.Id)));
        }
        if (!am.WebAccounts.Any())
            Node(Section("iCloud"), "Sign In with Apple ID…", "\uE8FA", new SidebarAction(() => SignIn(null)));

        var pc = Section("This PC");
        Node(pc, "This PC", "\uE7F8", Location.Computer);
        foreach (var v in VolumeInfo.All())
            Node(pc, v.DisplayName, v.IsRemovable ? "\uE88E" : v.IsNetwork ? "\uE8CE" : "\uEDA2", Location.Local(v.Root));

        var tools = Section("Cirrus");
        Node(tools, "Back Up iCloud…", "\uE8F7", new SidebarAction(() => ShowBackup()));
        var running = SyncStore.Shared.Jobs.Count(j => SyncStore.Shared.IsRunning(j.Id));
        Node(tools, running > 0 ? $"Sync Jobs ({running} running)" : "Sync Jobs…", "\uE895", new SidebarAction(() => ShowSyncJobs()));
        Node(tools, "Transfers", "\uE896", new SidebarAction(() => SetTransfersVisible(true)));
        Node(tools, "Settings…", "\uE713", new SidebarAction(() => ShowSettings()));
        _syncingSidebar = false;
        if (ActiveTab is { } tab) SelectSidebar(tab.Current);
    }

    ContextMenu? SidebarMenu(object tag)
    {
        var m = new ContextMenu();
        switch (tag)
        {
            case Location loc:
                m.Items.Add(MenuItem("Open in New Tab", "\uE8A7", () => OpenTab(loc)));
                if (loc.Kind == LocKind.Local && Settings.Current.Favorites.Contains(loc.Path!, StringComparer.OrdinalIgnoreCase))
                    m.Items.Add(MenuItem("Remove from Favorites", "\uE74D", () => { Settings.Current.Favorites.RemoveAll(f => string.Equals(f, loc.Path, StringComparison.OrdinalIgnoreCase)); Settings.Current.Save(); BuildSidebar(); }));
                return m;
            case Account a when a.Kind == AccountKind.Web:
                m.Items.Add(MenuItem("Back Up This Account…", "\uE8F7", () => ShowBackup(a.Id)));
                m.Items.Add(MenuItem("Sign In Again…", "\uE8FA", () => SignIn(a.AppleID)));
                m.Items.Add(MenuItem("Sign Out…", "\uF3B1", () =>
                {
                    if (Dialogs.Confirm(this, $"Sign out of {a.AppleID}?", "Cirrus forgets this session and any saved password. Nothing in iCloud changes.", "Sign Out"))
                    {
                        AccountManager.Shared.SignOut(a);
                        Catalog.Shared.ForgetAccount(a.Id);
                    }
                }));
                return m;
            default: return null;
        }
    }

    void SelectSidebar(Location loc)
    {
        _syncingSidebar = true;
        try
        {
            foreach (var n in AllNodes(Sidebar.Items))
                if (n.Tag is Location l && l == loc) { n.IsSelected = true; return; }
            if (Sidebar.SelectedItem is TreeViewItem sel) sel.IsSelected = false;
        }
        finally { _syncingSidebar = false; }
    }

    static IEnumerable<TreeViewItem> AllNodes(ItemCollection items)
    {
        foreach (var o in items)
            if (o is TreeViewItem t)
            {
                yield return t;
                foreach (var c in AllNodes(t.Items)) yield return c;
            }
    }

    void Sidebar_SelectionChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (_syncingSidebar || e.NewValue is not TreeViewItem n) return;
        switch (n.Tag)
        {
            case Location loc:
                if (ActiveTab is { } tab && tab.Current != loc) tab.Navigate(loc);
                break;
            case SidebarAction act:
                Dispatcher.InvokeAsync(() => { act.Run(); if (ActiveTab is { } t) SelectSidebar(t.Current); });
                break;
        }
    }

    TreeViewItem? NodeAt(DragEventArgs e)
    {
        var d = e.OriginalSource as DependencyObject;
        while (d is not null && d is not TreeViewItem) d = VisualTreeHelper.GetParent(d);
        return d as TreeViewItem;
    }

    void Sidebar_DragOver(object sender, DragEventArgs e)
    {
        var n = NodeAt(e);
        if (n?.Tag is Location loc) e.Effects = BrowserTab.DropEffect(e, loc);
        else if (n?.Header is TextBlock { Text: "Favorites" } && e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effects = DragDropEffects.Link;
        else e.Effects = DragDropEffects.None;
        e.Handled = true;
    }

    void Sidebar_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        var n = NodeAt(e);
        if (n?.Header is TextBlock { Text: "Favorites" } && e.Data.GetData(DataFormats.FileDrop) is string[] dirs)
        {
            foreach (var d in dirs.Where(Directory.Exists)) if (!Settings.Current.Favorites.Contains(d, StringComparer.OrdinalIgnoreCase)) Settings.Current.Favorites.Add(d);
            Settings.Current.Save();
            BuildSidebar();
            return;
        }
        if (n?.Tag is Location loc) _ = BrowserTab.HandleDrop(e.Data, loc, e.KeyStates.HasFlag(DragDropKeyStates.ShiftKey), this);
    }
}
