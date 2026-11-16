using System.IO;
using System.Windows;
using System.Windows.Controls;
using Cirrus.App.Model;
using Cirrus.Core;

namespace Cirrus.App.UI;

/// <summary>
/// "Copy To… / Move To…" picker: this PC's folders, iCloud for Windows, and every account's iCloud Drive
/// folders and Photos albums, loaded lazily as they're expanded.
/// </summary>
sealed class LocationPicker : Window
{
    readonly TreeView _tree = new() { Height = 380, BorderThickness = new Thickness(1) };
    readonly TextBlock _chosenText = Ui.Text("", 12, opacity: 0.75);
    readonly Button _ok;
    readonly bool _foldersOnly;
    public Location? Chosen { get; private set; }

    /// <param name="foldersOnly">Only folders (sync job endpoints) — no Photos albums.</param>
    readonly bool _anyLocation;

    /// <param name="anyLocation">Choosing a source: the place doesn't need to accept new items.</param>
    public LocationPicker(string title, string okText, Location? start, bool foldersOnly = false, bool includePhotos = true, bool anyLocation = false)
    {
        Title = title;
        Width = 520;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        _foldersOnly = foldersOnly;
        _anyLocation = anyLocation;
        _ok = Ui.Button(okText, () => { DialogResult = true; }, accent: true, isDefault: true);
        _ok.IsEnabled = false;
        var newFolder = Ui.Button("New Folder…", async () => await MakeFolder());
        newFolder.Margin = new Thickness(0);
        var buttons = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
        DockPanel.SetDock(newFolder, Dock.Left);
        buttons.Children.Add(newFolder);
        var right = Ui.Row(_ok, Ui.Button("Cancel", () => { DialogResult = false; }, isCancel: true));
        right.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Children.Add(right);
        var root = Ui.Stack(Ui.Text("Choose where to put the items:", 13), _tree, _chosenText, buttons);
        root.Margin = new Thickness(20);
        Content = root;
        _tree.SelectedItemChanged += (_, e) =>
        {
            Chosen = (e.NewValue as TreeViewItem)?.Tag as Location;
            var accepts = Chosen is not null && (_anyLocation || Catalog.Shared.Caps(Chosen).AcceptsDrops);
            _ok.IsEnabled = accepts;
            _chosenText.Text = Chosen is null ? "" : accepts ? Catalog.Shared.LongTitle(Chosen) : $"“{Catalog.Shared.Title(Chosen)}” doesn’t accept new items" + (SafetyPolicy.ReadOnlyICloud && Catalog.Shared.Caps(Chosen).IsICloud ? " (read-only mode is on)." : ".");
        };
        Build(includePhotos);
    }

    TreeViewItem Node(ItemsControl parent, string title, string glyph, Location? loc, Func<TreeViewItem, Task>? expand = null)
    {
        var header = Ui.Row(Ui.Glyph(glyph, 14), new TextBlock { Text = "  " + title, VerticalAlignment = VerticalAlignment.Center });
        header.Margin = new Thickness(0);
        var n = new TreeViewItem { Header = header, Tag = loc };
        if (expand is not null)
        {
            n.Items.Add(new TreeViewItem { Header = "Loading…", IsEnabled = false });
            var loaded = false;
            n.Expanded += async (_, e) =>
            {
                if (e.OriginalSource != n || loaded) return;
                loaded = true;
                n.Items.Clear();
                try { await expand(n); }
                catch (Exception ex) { n.Items.Add(new TreeViewItem { Header = ex.Message, IsEnabled = false }); }
            };
        }
        parent.Items.Add(n);
        return n;
    }

    async Task LocalChildren(TreeViewItem n, string dir)
    {
        var dirs = await Task.Run(() =>
            new DirectoryInfo(dir).EnumerateDirectories("*", new EnumerationOptions { IgnoreInaccessible = true })
                .Where(d => (d.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0 && !d.Name.StartsWith('.'))
                .OrderBy(d => d.Name, NaturalComparer.Instance).Select(d => d.FullName).ToList());
        foreach (var p in dirs) Node(n, Path.GetFileName(p), "\uE8B7", Location.Local(p), c => LocalChildren(c, p));
    }

    async Task DriveChildren(TreeViewItem n, Account a, string folderID)
    {
        var nodes = await a.Drive!.ListAsync(folderID);
        foreach (var f in nodes.Where(x => x.IsFolder).OrderBy(x => x.Name, NaturalComparer.Instance))
        {
            Catalog.Shared.RememberDrive(a.Id, f);
            Node(n, f.Name, "\uE8B7", Location.Drive(a.Id, f.Id), c => DriveChildren(c, a, f.Id));
        }
    }

    void Build(bool includePhotos)
    {
        var am = AccountManager.Shared;
        var favs = Node(_tree, "Favorites", "\uE734", null);
        favs.IsExpanded = true;
        foreach (var p in Settings.Current.Favorites.Where(Directory.Exists))
            Node(favs, Catalog.Shared.Title(Location.Local(p)), "\uE8B7", Location.Local(p), c => LocalChildren(c, p));
        if (am.NativeAccount is { } native)
        {
            var s = Node(_tree, "iCloud for Windows", "\uE753", null);
            s.IsExpanded = true;
            if (native.DriveRoot is { } dr) Node(s, "iCloud Drive", "\uE753", Location.Local(dr), c => LocalChildren(c, dr));
            if (native.PhotosRoot is { } pr && !_foldersOnly) Node(s, "iCloud Photos", "\uEB9F", Location.Local(pr), c => LocalChildren(c, pr));
        }
        foreach (var a in am.Accounts.Where(a => a.Kind != AccountKind.Native && a.Status != AccountStatus.NeedsSignIn && (a.Drive is not null || a.Photos is not null)))
        {
            var s = Node(_tree, a.Kind == AccountKind.Demo ? "Demo iCloud" : a.Title, a.IsICloud ? "\uE77B" : a.Provider!.Value.Glyph(), null);
            s.IsExpanded = true;
            if (a.Drive is { } d)
            {
                var root = Node(s, a.DriveTitle, a.IsICloud ? "\uE753" : a.Provider!.Value.Glyph(), Location.Drive(a.Id, d.RootID), c => DriveChildren(c, a, d.RootID));
                root.IsExpanded = false;
            }
            if (includePhotos && !_foldersOnly && a.Photos is not null)
            {
                var lib = a.PrimaryLibraryID;
                Node(s, "Photos", "\uEB9F", Location.Album(a.Id, lib, "smart:All Photos"), async c =>
                {
                    foreach (var al in (await Catalog.Shared.Albums(a, lib)).Where(x => x.Kind == PhotoAlbumKind.Album).OrderBy(x => x.Name, NaturalComparer.Instance))
                        Node(c, al.Name, "\uE8B9", Location.Album(a.Id, lib, al.Id));
                });
            }
        }
        var pc = Node(_tree, "This PC", "\uE7F8", null);
        pc.IsExpanded = true;
        foreach (var v in VolumeInfo.All())
            Node(pc, v.DisplayName, v.IsRemovable ? "\uE88E" : "\uEDA2", Location.Local(v.Root), c => LocalChildren(c, v.Root));
    }

    async Task MakeFolder()
    {
        if (Chosen is not { } loc || !Catalog.Shared.Caps(loc).CanCreateFolder || loc.Kind is not (LocKind.Local or LocKind.Drive)) return;
        if (await Services.Ops.NewFolder(loc, this) is not { } name) return;
        if (_tree.SelectedItem is TreeViewItem n)
        {
            n.Items.Clear();
            if (loc.Kind == LocKind.Local) await LocalChildren(n, loc.Path!);
            else if (loc.AccountRef is { } a) await DriveChildren(n, a, loc.Id!);
            n.IsExpanded = true;
        }
    }
}
