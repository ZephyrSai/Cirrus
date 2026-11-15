using System.IO;
using Cirrus.App.Platform;
using Cirrus.Core;

namespace Cirrus.App.Model;

/// <summary>Lists locations and knows their names, icons, breadcrumbs and capabilities.</summary>
public sealed class Catalog
{
    public static Catalog Shared { get; } = new();

    readonly object _lock = new();
    readonly Dictionary<string, (string Name, string? Parent)> _driveNames = [];     // "acct|id"
    readonly Dictionary<string, List<PhotoAlbum>> _albums = [];                     // "acct|lib"
    readonly Dictionary<string, List<PhotoLibraryRef>> _libraries = [];             // acct

    /// <summary>Raised (on any thread) when a location's contents changed and open tabs should reload.</summary>
    public event Action<Location>? Invalidated;
    public void Invalidate(Location loc) => Invalidated?.Invoke(loc);

    public static string Glyph(Location loc) => loc.Kind switch
    {
        LocKind.Computer => "",
        LocKind.Local => "",
        LocKind.Drive => "",
        LocKind.DriveTrash => "",
        LocKind.Photos => "",
        _ => loc.Id == "smart:Recently Deleted" ? "" : loc.Id == "smart:Favorites" ? "" : "",
    };

    // MARK: Titles

    public string Title(Location loc)
    {
        switch (loc.Kind)
        {
            case LocKind.Computer: return "This PC";
            case LocKind.Local:
            {
                var p = loc.Path!;
                var acct = AccountManager.Shared.NativeAccount;
                if (acct?.DriveRoot is { } dr && Same(dr, p)) return "iCloud Drive";
                if (acct?.PhotosRoot is { } pr && Same(pr, p)) return "iCloud Photos";
                if (Path.GetPathRoot(p) == p) return VolumeInfo.Info(p)?.DisplayName ?? p;
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (Same(home, p)) return Path.GetFileName(home);
                return Path.GetFileName(p);
            }
            case LocKind.Drive:
            {
                var a = loc.AccountRef;
                if (a?.Drive is { } d && d.RootID == loc.Id) return "iCloud Drive";
                lock (_lock) return _driveNames.TryGetValue(loc.Account + "|" + loc.Id, out var n) ? n.Name : "Folder";
            }
            case LocKind.DriveTrash: return "Recently Deleted";
            case LocKind.Photos:
            {
                if (loc.Id is { } folder) return AlbumIn(loc.Account!, loc.Library!, folder)?.Name ?? "Folder";
                List<PhotoLibraryRef>? libs;
                lock (_lock) _libraries.TryGetValue(loc.Account!, out libs);
                if (libs is { Count: > 1 } && libs.FirstOrDefault(l => l.Id == loc.Library) is { } lib) return lib.Name;
                return "Photos";
            }
            default:
                return AlbumIn(loc.Account!, loc.Library!, loc.Id!)?.Name ?? (loc.Id!.StartsWith("smart:") ? loc.Id[6..] : "Album");
        }
    }

    static bool Same(string a, string b) => string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

    PhotoAlbum? AlbumIn(string acct, string lib, string id)
    {
        lock (_lock) return _albums.TryGetValue(acct + "|" + lib, out var l) ? l.FirstOrDefault(a => a.Id == id) : null;
    }

    public string AccountTitle(Location loc) => loc.AccountRef is { } a ? (a.Kind == AccountKind.Demo ? "Demo iCloud" : a.Title) : "";

    /// <summary>Window/tab title: "Docs — iCloud Drive (name)" for remote places.</summary>
    public string LongTitle(Location loc) => loc.IsRemote && AccountManager.Shared.WebAccounts.Count + (AccountManager.Shared.DemoMode ? 1 : 0) > 1
        ? $"{Title(loc)} — {AccountTitle(loc)}" : Title(loc);

    // MARK: Parents and breadcrumbs

    public Location? Parent(Location loc)
    {
        switch (loc.Kind)
        {
            case LocKind.Local:
                var parent = Path.GetDirectoryName(loc.Path!);
                if (AccountManager.Shared.NativeAccount is { } n && ((n.DriveRoot is { } dr && Same(dr, loc.Path!)) || (n.PhotosRoot is { } pr && Same(pr, loc.Path!)))) return null;
                return parent is null ? Location.Computer : Location.Local(parent);
            case LocKind.Drive:
                if (loc.AccountRef?.Drive is { } d && d.RootID == loc.Id) return null;
                lock (_lock)
                    if (_driveNames.TryGetValue(loc.Account + "|" + loc.Id, out var dn) && dn.Parent is { } p) return Location.Drive(loc.Account!, p);
                return loc.AccountRef?.Drive is { } dd ? Location.Drive(loc.Account!, dd.RootID) : null;
            case LocKind.Photos:
                if (loc.Id is null) return null;
                var parentFolder = AlbumIn(loc.Account!, loc.Library!, loc.Id)?.ParentID;
                return Location.Photos(loc.Account!, loc.Library!, parentFolder);
            case LocKind.Album:
                var album = AlbumIn(loc.Account!, loc.Library!, loc.Id!);
                return Location.Photos(loc.Account!, loc.Library!, album?.ParentID);
            default: return null;
        }
    }

    public List<Location> Breadcrumbs(Location loc)
    {
        var list = new List<Location>();
        Location? cur = loc;
        int guard = 0;
        while (cur is not null && guard++ < 64) { list.Insert(0, cur); cur = Parent(cur); }
        return list;
    }

    public LocationCaps Caps(Location loc)
    {
        var ro = SafetyPolicy.ReadOnlyICloud;
        switch (loc.Kind)
        {
            case LocKind.Local:
                var icloud = SafetyPolicy.IsICloudPath(loc.Path!);
                var writable = !(icloud && ro);
                return new LocationCaps(writable, "New Folder", writable, writable, writable, IsICloud: icloud);
            case LocKind.Drive:
                return new LocationCaps(!ro, "New Folder", !ro, !ro, !ro, IsICloud: true);
            case LocKind.DriveTrash:
                return new LocationCaps(IsTrash: true, CanDeleteForever: !ro, IsICloud: true);
            case LocKind.Photos:
                return new LocationCaps(!ro && loc.Id is null, "New Album", !ro, IsICloud: true);
            case LocKind.Album:
                var a = AlbumIn(loc.Account!, loc.Library!, loc.Id!);
                if (loc.Id == "smart:Recently Deleted") return new LocationCaps(IsTrash: true, IsICloud: true);
                var accepts = !ro && (loc.Id == "smart:All Photos" || a?.Kind == PhotoAlbumKind.Album);
                return new LocationCaps(false, "New Album", accepts, CanTrash: !ro, IsICloud: true);
            default:
                return new LocationCaps();
        }
    }

    // MARK: Lookups

    public async Task<List<PhotoLibraryRef>> Libraries(Account acct, CancellationToken ct = default)
    {
        lock (_lock) if (_libraries.TryGetValue(acct.Id, out var l)) return l;
        var libs = acct.Photos is { } p ? await p.LibrariesAsync(ct) : [];
        lock (_lock) _libraries[acct.Id] = libs;
        return libs;
    }

    public async Task<PhotoLibraryRef> Library(Account acct, string id, CancellationToken ct = default) =>
        (await Libraries(acct, ct)).FirstOrDefault(l => l.Id == id) ?? new PhotoLibraryRef(id, id, false);

    public async Task<List<PhotoAlbum>> Albums(Account acct, string libID, bool fresh = false, CancellationToken ct = default)
    {
        var key = acct.Id + "|" + libID;
        if (!fresh) lock (_lock) if (_albums.TryGetValue(key, out var hit)) return hit;
        if (acct.Photos is not { } photos) return [];
        var albums = await photos.AlbumsAsync(await Library(acct, libID, ct), ct);
        lock (_lock) _albums[key] = albums;
        return albums;
    }

    public async Task<PhotoAlbum?> Album(Account acct, string libID, string albumID, CancellationToken ct = default) =>
        (await Albums(acct, libID, false, ct)).FirstOrDefault(a => a.Id == albumID) ?? (await Albums(acct, libID, true, ct)).FirstOrDefault(a => a.Id == albumID);

    public void RememberDrive(string acct, DriveNode n)
    {
        lock (_lock) _driveNames[acct + "|" + n.Id] = (n.Name, n.ParentID);
    }

    // MARK: Listing

    /// <summary>Lists a location. Photo albums stream pages through <paramref name="page"/> as they arrive.</summary>
    public async Task<List<Item>> List(Location loc, Action<IReadOnlyList<Item>>? page, CancellationToken ct)
    {
        switch (loc.Kind)
        {
            case LocKind.Computer: return ListComputer();
            case LocKind.Local: return await Task.Run(() => ListLocal(loc.Path!), ct);
            case LocKind.Drive:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var drive = acct.Drive ?? throw ICloudException.NeedsSignIn();
                var nodes = await drive.ListAsync(loc.Id!, ct);
                return nodes.Select(n => DriveItem(acct, n)).ToList();
            }
            case LocKind.DriveTrash:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var nodes = await (acct.Drive ?? throw ICloudException.NeedsSignIn()).ListTrashAsync(ct);
                return nodes.Select(n => DriveItem(acct, n, inTrash: true)).ToList();
            }
            case LocKind.Photos:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var albums = await Albums(acct, loc.Library!, fresh: true, ct);
                return albums.Where(a => a.ParentID == loc.Id && (loc.Id is not null || a.Kind != PhotoAlbumKind.Smart || a.Id is "smart:All Photos" or "smart:Favorites" or "smart:Videos" or "smart:Live" or "smart:Hidden" or "smart:Recently Deleted" or "smart:Screenshots"))
                    .Select(a => new Item
                    {
                        Key = "album:" + acct.Id + "|" + a.Id, Name = a.Name, IsContainer = true, Album = a, Count = a.Count, AccountID = acct.Id,
                        Target = a.Kind == PhotoAlbumKind.Folder ? Location.Photos(acct.Id, loc.Library!, a.Id) : Location.Album(acct.Id, loc.Library!, a.Id),
                        Glyph = a.Kind == PhotoAlbumKind.Folder ? "" : a.Id == "smart:Recently Deleted" ? "" : a.Id == "smart:Favorites" ? "" : "",
                    }).ToList();
            }
            default:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var photos = acct.Photos ?? throw ICloudException.NeedsSignIn();
                var lib = await Library(acct, loc.Library!, ct);
                var album = await Album(acct, loc.Library!, loc.Id!, ct) ?? new PhotoAlbum(loc.Id!, Title(loc), PhotoAlbumKind.Smart);
                var assets = await photos.AssetsAsync(album, lib, (batch, _) => page?.Invoke(batch.Select(a => PhotoItem(acct, a)).ToList()), ct);
                return assets.Select(a => PhotoItem(acct, a)).ToList();
            }
        }
    }

    static List<Item> ListComputer()
    {
        var items = new List<Item>();
        if (AccountManager.Shared.NativeAccount is { } n)
        {
            if (n.DriveRoot is { } dr) items.Add(new Item { Key = "native-drive", Name = "iCloud Drive", IsContainer = true, LocalPath = dr, Target = Location.Local(dr), Glyph = "" });
            if (n.PhotosRoot is { } pr) items.Add(new Item { Key = "native-photos", Name = "iCloud Photos", IsContainer = true, LocalPath = pr, Target = Location.Local(pr), Glyph = "" });
        }
        foreach (var v in VolumeInfo.All())
            items.Add(new Item { Key = "vol:" + v.Root, Name = v.DisplayName, IsContainer = true, Volume = v, LocalPath = v.Root, Target = Location.Local(v.Root), Glyph = v.IsRemovable ? "" : "" });
        return items;
    }

    static List<Item> ListLocal(string dir)
    {
        var show = Settings.Current.ShowHidden;
        var items = new List<Item>();
        var info = new DirectoryInfo(dir);
        if (!info.Exists) throw new DirectoryNotFoundException($"“{dir}” isn’t available.");
        var icloud = SafetyPolicy.IsICloudPath(dir);
        foreach (var e in info.EnumerateFileSystemInfos("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0 }))
        {
            var hidden = (e.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0 || e.Name.StartsWith('.');
            if (hidden && !show) continue;
            var isDir = (e.Attributes & FileAttributes.Directory) != 0;
            items.Add(new Item
            {
                Key = "file:" + e.FullName.ToLowerInvariant(), Name = e.Name, IsContainer = isDir, Size = isDir ? null : ((FileInfo)e).Length,
                Modified = new DateTimeOffset(e.LastWriteTimeUtc, TimeSpan.Zero), Created = new DateTimeOffset(e.CreationTimeUtc, TimeSpan.Zero),
                LocalPath = e.FullName, Target = isDir ? Location.Local(e.FullName) : null, IsHiddenFile = hidden,
                Cloud = icloud ? LocalFiles.GetCloudState(e.FullName) : LocalFiles.CloudState.NotCloud, Glyph = isDir ? "" : "",
            });
        }
        return items;
    }

    public Item DriveItem(Account acct, DriveNode n, bool inTrash = false)
    {
        RememberDrive(acct.Id, n);
        return new Item
        {
            Key = "drive:" + acct.Id + "|" + n.Id, Name = n.Name, IsContainer = n.IsFolder, Size = n.IsFolder ? null : n.Size, Modified = n.Modified, Created = n.Created,
            Node = n, AccountID = acct.Id, Count = n.ChildCount, Target = n.IsFolder && !inTrash ? Location.Drive(acct.Id, n.Id) : null,
            Glyph = n.IsFolder ? "" : "",
        };
    }

    public static Item PhotoItem(Account acct, PhotoAsset a) => new()
    {
        Key = "photo:" + acct.Id + "|" + a.Id, Name = a.Filename, Size = a.Size, Modified = a.Created, Created = a.Added, Photo = a, AccountID = acct.Id,
        Glyph = a.IsVideo ? "" : "",
    };
}
