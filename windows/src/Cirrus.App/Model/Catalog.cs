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
    /// <summary>Our own photo edits, applied in place: (account, library, updated assets, removed asset ids).</summary>
    public event Action<string, string, IReadOnlyList<PhotoAsset>, IReadOnlySet<string>>? PhotosPatched;

    // In-memory listings, trusted for a while before asking the server again (our own edits invalidate sooner).
    readonly Dictionary<Location, (List<Item> Items, DateTimeOffset At)> _memory = [];
    readonly HashSet<Location> _forceNext = [];
    /// <summary>Bumped by every invalidation: a listing that started before it may not store its (older) result.</summary>
    readonly Dictionary<Location, long> _generation = [];

    long Generation(Location loc) { lock (_lock) return _generation.TryGetValue(loc, out var g) ? g : 0; }

    static TimeSpan Ttl(Location loc) => loc.Kind switch
    {
        // Recently Deleted is never served from memory: it feeds Delete Immediately.
        LocKind.Drive => TimeSpan.FromSeconds(60),
        LocKind.Photos => TimeSpan.FromSeconds(300),
        _ => TimeSpan.Zero,          // albums check freshness themselves (sync token); local folders are cheap
    };

    /// <summary>Our own change: the next listing of this place goes to the server, skipping caches. Open tabs reload.</summary>
    public void Invalidate(Location loc)
    {
        lock (_lock) { _memory.Remove(loc); _forceNext.Add(loc); _generation[loc] = Generation(loc) + 1; }
        if (loc.Kind == LocKind.Album && loc.Account is { } a && loc.Library is { } l) ListingCache.Shared.MarkAlbumStale(a, l, loc.Id!);
        Invalidated?.Invoke(loc);
    }

    /// <summary>F5 / Refresh: skip every cache for this place (for Photos, the album list too).</summary>
    public async Task ForceRefresh(Location loc)
    {
        lock (_lock) { _memory.Remove(loc); _forceNext.Add(loc); _generation[loc] = Generation(loc) + 1; }
        if (loc.Kind is LocKind.Photos or LocKind.Album && loc.AccountRef is { } a)
        {
            try { await Albums(a, loc.Library!, fresh: true); } catch { }
        }
    }

    /// <summary>Forget everything cached in memory for an account (sign-out).</summary>
    public void ForgetAccount(string accountID)
    {
        lock (_lock)
        {
            foreach (var k in _memory.Keys.Where(k => k.Account == accountID).ToList()) _memory.Remove(k);
            foreach (var k in _albums.Keys.Where(k => k.StartsWith(accountID + "|", StringComparison.Ordinal)).ToList()) _albums.Remove(k);
            _libraries.Remove(accountID);
            foreach (var k in _driveNames.Keys.Where(k => k.StartsWith(accountID + "|", StringComparison.Ordinal)).ToList()) _driveNames.Remove(k);
        }
        Services.Thumbnails.Forget(accountID);
    }

    /// <summary>
    /// Reflect our own favorite/hide/delete edits everywhere without re-downloading: cached listings (memory and disk)
    /// are patched; Favorites, Hidden and Recently Deleted are re-listed next time.
    /// </summary>
    public void PatchPhotos(string accountID, string library, IReadOnlyList<PhotoAsset> updated, IReadOnlySet<string> removed)
    {
        var byID = new Dictionary<string, PhotoAsset>();
        foreach (var u in updated) byID.TryAdd(u.Id, u);
        lock (_lock)
            foreach (var k in _memory.Keys.Where(k => k.Kind == LocKind.Album && k.Account == accountID && k.Library == library).ToList())
            {
                if (ListingCache.EditSensitive.Contains(k.Id)) { _memory.Remove(k); _forceNext.Add(k); continue; }
                var (items, at) = _memory[k];
                _memory[k] = (items.Where(i => i.Photo is null || !removed.Contains(i.Photo.Id)).ToList(), at);
            }
        ListingCache.Shared.PatchPhotos(accountID, library, updated, removed);
        foreach (var id in ListingCache.EditSensitive) lock (_lock) _forceNext.Add(Location.Album(accountID, library, id));
        PhotosPatched?.Invoke(accountID, library, updated, removed);
        foreach (var id in ListingCache.EditSensitive) Invalidated?.Invoke(Location.Album(accountID, library, id));
    }

    public static string Glyph(Location loc) => loc.Kind switch
    {
        LocKind.Drive when loc.AccountRef is { Kind: AccountKind.Cloud, Drive: { } d } a && d.RootID == loc.Id => a.Provider!.Value.Glyph(),
        LocKind.Computer => "\uE7F8",
        LocKind.Local => "\uE8B7",
        LocKind.Drive => "\uE753",
        LocKind.DriveTrash => "\uE74D",
        LocKind.Photos => "\uEB9F",
        _ => loc.Id == "smart:Recently Deleted" ? "\uE74D" : loc.Id == "smart:Favorites" ? "\uEB51" : "\uE8B9",
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
                if (a?.Drive is { } d && d.RootID == loc.Id) return a.DriveTitle;
                lock (_lock) return _driveNames.TryGetValue(loc.Account + "|" + loc.Id, out var n) ? n.Name : "Folder";
            }
            case LocKind.DriveTrash: return loc.AccountRef?.DeletedTitle ?? "Recently Deleted";
            case LocKind.Photos:
            {
                if (loc.Id is { } folder) return AlbumIn(loc.Account!, loc.Library!, folder)?.Name ?? "Folder";
                List<PhotoLibraryRef>? libs;
                lock (_lock) _libraries.TryGetValue(loc.Account!, out libs);
                if (libs is { Count: > 1 } && libs.FirstOrDefault(l => l.Id == loc.Library) is { } lib) return lib.Name;
                return loc.AccountRef is { Kind: AccountKind.Cloud } ca ? ca.DriveTitle : "Photos";
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
    public string LongTitle(Location loc)
    {
        if (!loc.IsRemote) return Title(loc);
        var am = AccountManager.Shared;
        // Another cloud: name its account when two of that service are connected.
        if (loc.AccountRef is { Kind: AccountKind.Cloud } c)
            return am.CloudAccounts.Count(x => x.Provider == c.Provider) > 1 ? $"{Title(loc)} — {c.Title}" : Title(loc);
        return am.WebAccounts.Count + (am.DemoMode ? 1 : 0) > 1 ? $"{Title(loc)} — {AccountTitle(loc)}" : Title(loc);
    }

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
        // Read-only mode protects iCloud only; other clouds are always writable.
        var icloudAcct = loc.AccountRef?.IsICloud ?? true;
        var ro = SafetyPolicy.ReadOnlyICloud && icloudAcct;
        switch (loc.Kind)
        {
            case LocKind.Local:
                var icloud = SafetyPolicy.IsICloudPath(loc.Path!);
                var writable = !(icloud && ro);
                return new LocationCaps(writable, "New Folder", writable, writable, writable, IsICloud: icloud);
            case LocKind.Drive:
                return new LocationCaps(!ro, "New Folder", !ro, !ro, !ro, IsICloud: icloudAcct);
            case LocKind.DriveTrash:
                return new LocationCaps(IsTrash: true, CanDeleteForever: !ro && (loc.AccountRef?.CanListTrash ?? true), IsICloud: icloudAcct);
            case LocKind.Photos:
                return new LocationCaps(!ro && loc.Id is null, "New Album", !ro, IsICloud: icloudAcct);
            case LocKind.Album:
                var a = AlbumIn(loc.Account!, loc.Library!, loc.Id!);
                if (loc.Id == "smart:Recently Deleted") return new LocationCaps(IsTrash: true, IsICloud: icloudAcct);
                var accepts = !ro && (loc.Id == "smart:All Photos" || a?.Kind == PhotoAlbumKind.Album);
                return new LocationCaps(false, "New Album", accepts, CanTrash: !ro, IsICloud: icloudAcct);
            default:
                return new LocationCaps();
        }
    }

    // MARK: Lookups

    public async Task<List<PhotoLibraryRef>> Libraries(Account acct, CancellationToken ct = default)
    {
        lock (_lock) if (_libraries.TryGetValue(acct.Id, out var l)) return l;
        if (acct.Photos is not { } p) return [];
        if (acct.Kind == AccountKind.Web)
        {
            // Last known libraries on disk: trusted for a day; older ones are shown while a fresh list loads quietly.
            var (cached, fresh) = ListingCache.Shared.LoadList<PhotoLibraryRef>(acct.Id, "libraries", ListingCache.LibraryListMaxAge);
            if (cached is { Count: > 0 })
            {
                lock (_lock) _libraries[acct.Id] = cached;
                if (p is WebPhotos wp) wp.Remember(cached);   // shared zones need their owner and area
                if (!fresh)
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            var f = await p.LibrariesAsync();
                            if (p is WebPhotos { SharedLookupFailed: true }) return;   // possibly missing a Shared Library: keep the known list
                            lock (_lock) _libraries[acct.Id] = f;
                            ListingCache.Shared.SaveList(acct.Id, "libraries", f);
                        }
                        catch { }
                    });
                return cached;
            }
        }
        var libs = await p.LibrariesAsync(ct);
        // A list made while the shared database didn't answer may lack a Shared Library: use it, but don't keep it.
        if (p is WebPhotos { SharedLookupFailed: true }) return libs;
        lock (_lock) _libraries[acct.Id] = libs;
        if (acct.Kind == AccountKind.Web) ListingCache.Shared.SaveList(acct.Id, "libraries", libs);
        return libs;
    }

    public async Task<PhotoLibraryRef> Library(Account acct, string id, CancellationToken ct = default) =>
        (await Libraries(acct, ct)).FirstOrDefault(l => l.Id == id) ?? new PhotoLibraryRef(id, id, false);

    public async Task<List<PhotoAlbum>> Albums(Account acct, string libID, bool fresh = false, CancellationToken ct = default)
    {
        var key = acct.Id + "|" + libID;
        if (!fresh) lock (_lock) if (_albums.TryGetValue(key, out var hit)) return hit;
        if (acct.Photos is not { } photos) return [];
        if (!fresh && acct.Kind == AccountKind.Web)
        {
            // Last known album list on disk: trusted for 10 minutes; older ones are shown while a fresh list loads.
            var (cached, recent) = ListingCache.Shared.LoadList<PhotoAlbum>(acct.Id, "albums|" + libID, ListingCache.AlbumListMaxAge);
            if (cached is not null)
            {
                lock (_lock) _albums[key] = cached;
                if (!recent)
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            var f = await Albums(acct, libID, fresh: true);
                            var changed = f.Count != cached.Count || f.Zip(cached).Any(x => x.First.Id != x.Second.Id || x.First.Name != x.Second.Name || x.First.Count != x.Second.Count);
                            if (changed) Invalidated?.Invoke(Location.Photos(acct.Id, libID));
                        }
                        catch { }
                    });
                return cached;
            }
        }
        var albums = await photos.AlbumsAsync(await Library(acct, libID, ct), ct);
        lock (_lock) _albums[key] = albums;
        if (acct.Kind == AccountKind.Web) ListingCache.Shared.SaveList(acct.Id, "albums|" + libID, albums);
        return albums;
    }

    public async Task<PhotoAlbum?> Album(Account acct, string libID, string albumID, CancellationToken ct = default) =>
        (await Albums(acct, libID, false, ct)).FirstOrDefault(a => a.Id == albumID) ?? (await Albums(acct, libID, true, ct)).FirstOrDefault(a => a.Id == albumID);

    public void RememberDrive(string acct, DriveNode n)
    {
        lock (_lock) _driveNames[acct + "|" + n.Id] = (n.Name, n.ParentID);
    }

    // MARK: Listing

    /// <summary>
    /// Lists a location through the caches. <paramref name="page"/> receives a quick first answer: the cached copy of
    /// an iCloud Drive folder or album while it's being checked, or album pages as they stream in.
    /// </summary>
    public async Task<List<Item>> List(Location loc, Action<IReadOnlyList<Item>>? page, CancellationToken ct)
    {
        bool forced;
        long gen;
        lock (_lock)
        {
            forced = _forceNext.Remove(loc);
            gen = Generation(loc);
            if (!forced && _memory.TryGetValue(loc, out var m) && DateTimeOffset.UtcNow - m.At < Ttl(loc)) return m.Items;
        }
        var started = DateTimeOffset.UtcNow;
        List<Item> items;
        try { items = await ListFresh(loc, forced, page, ct); }
        catch
        {
            if (forced) lock (_lock) _forceNext.Add(loc);   // a failed forced listing stays forced for the retry
            throw;
        }
        var secs = (DateTimeOffset.UtcNow - started).TotalSeconds;
        if (secs > 1) Log.Status($"list {loc.Kind.ToString().ToLowerInvariant()} {items.Count} items in {secs:0.0}s");
        // Only keep it if nothing was invalidated while it ran (otherwise it may predate our own change).
        if (Ttl(loc) > TimeSpan.Zero) lock (_lock) if (Generation(loc) == gen) _memory[loc] = (items, DateTimeOffset.UtcNow);
        return items;
    }

    async Task<List<Item>> ListFresh(Location loc, bool forced, Action<IReadOnlyList<Item>>? page, CancellationToken ct)
    {
        switch (loc.Kind)
        {
            case LocKind.Computer: return ListComputer();
            case LocKind.Local: return await Task.Run(() => ListLocal(loc.Path!), ct);
            case LocKind.Drive:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var drive = acct.Drive ?? throw ICloudException.NeedsSignIn();
                // Last known listings on disk: iCloud web accounts and other clouds (both are slow to list).
                var web = acct.Kind is AccountKind.Web or AccountKind.Cloud;
                if (web && !forced && ListingCache.Shared.LoadDrive(acct.Id, loc.Id!) is { } cached)
                    page?.Invoke(cached.Nodes.Select(n => DriveItem(acct, n)).ToList());   // last known contents at once
                var gen = Generation(loc);
                var nodes = await drive.ListAsync(loc.Id!, ct);
                if (web && Generation(loc) == gen) ListingCache.Shared.SaveDrive(acct.Id, loc.Id!, nodes);
                return nodes.Select(n => DriveItem(acct, n)).ToList();
            }
            case LocKind.DriveTrash:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                if (!acct.CanListTrash) return [];   // OneDrive's and Dropbox's can't be listed: the empty view explains
                var nodes = await (acct.Drive ?? throw ICloudException.NeedsSignIn()).ListTrashAsync(ct);
                return nodes.Select(n => DriveItem(acct, n, inTrash: true)).ToList();
            }
            case LocKind.Photos:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var albums = await Albums(acct, loc.Library!, fresh: forced, ct);
                return albums.Where(a => a.ParentID == loc.Id && (loc.Id is not null || a.Kind != PhotoAlbumKind.Smart || a.Id is "smart:All Photos" or "smart:Favorites" or "smart:Videos" or "smart:Live" or "smart:Hidden" or "smart:Recently Deleted" or "smart:Screenshots"))
                    .Select(a => new Item
                    {
                        Key = "album:" + acct.Id + "|" + a.Id, Name = a.Name, IsContainer = true, Album = a, Count = a.Count, AccountID = acct.Id,
                        Target = a.Kind == PhotoAlbumKind.Folder ? Location.Photos(acct.Id, loc.Library!, a.Id) : Location.Album(acct.Id, loc.Library!, a.Id),
                        Glyph = a.Kind == PhotoAlbumKind.Folder ? "\uE8B7" : a.Id == "smart:Recently Deleted" ? "\uE74D" : a.Id == "smart:Favorites" ? "\uEB51" : "\uE8B9",
                    }).ToList();
            }
            default:
            {
                var acct = loc.AccountRef ?? throw ICloudException.NeedsSignIn();
                var photos = acct.Photos ?? throw ICloudException.NeedsSignIn();
                var lib = await Library(acct, loc.Library!, ct);
                var album = await Album(acct, loc.Library!, loc.Id!, ct) ?? new PhotoAlbum(loc.Id!, Title(loc), PhotoAlbumKind.Smart);
                var assets = await ListingCache.Shared.ListAlbumAsync(photos, acct.Id, lib, album, forced, useDisk: acct.Kind == AccountKind.Web,
                    page is null ? null : batch => page(batch.Select(a => PhotoItem(acct, a)).ToList()), ct);
                return assets.Select(a => PhotoItem(acct, a)).ToList();
            }
        }
    }

    static List<Item> ListComputer()
    {
        var items = new List<Item>();
        if (AccountManager.Shared.NativeAccount is { } n)
        {
            if (n.DriveRoot is { } dr) items.Add(new Item { Key = "native-drive", Name = "iCloud Drive", IsContainer = true, LocalPath = dr, Target = Location.Local(dr), Glyph = "\uE753" });
            if (n.PhotosRoot is { } pr) items.Add(new Item { Key = "native-photos", Name = "iCloud Photos", IsContainer = true, LocalPath = pr, Target = Location.Local(pr), Glyph = "\uEB9F" });
        }
        foreach (var v in VolumeInfo.All())
            items.Add(new Item { Key = "vol:" + v.Root, Name = v.DisplayName, IsContainer = true, Volume = v, LocalPath = v.Root, Target = Location.Local(v.Root), Glyph = v.IsRemovable ? "\uE88E" : "\uEDA2" });
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
                Cloud = icloud ? LocalFiles.GetCloudState(e.FullName) : LocalFiles.CloudState.NotCloud, Glyph = isDir ? "\uE8B7" : "\uE8A5",
            });
        }
        return items;
    }

    public Item DriveItem(Account acct, DriveNode n, bool inTrash = false)
    {
        RememberDrive(acct.Id, n);
        var native = n.IsGoogleNative();   // Google Docs, Sheets…: no size, Google's own kind name
        return new Item
        {
            Key = "drive:" + acct.Id + "|" + n.Id, Name = n.Name, IsContainer = n.IsFolder, Size = n.IsFolder || native ? null : n.Size, Modified = n.Modified, Created = n.Created,
            KindName = native ? GoogleKind(n.Zone) : null,
            Node = n, AccountID = acct.Id, Count = n.ChildCount, Target = n.IsFolder && !inTrash ? Location.Drive(acct.Id, n.Id) : null,
            Glyph = n.IsFolder ? "\uE8B7" : "\uE8A5",
        };
    }

    static string GoogleKind(string mime) => mime[CloudConventions.GoogleNativePrefix.Length..] switch
    {
        "document" => "Google Docs document",
        "spreadsheet" => "Google Sheets spreadsheet",
        "presentation" => "Google Slides presentation",
        "drawing" => "Google Drawings drawing",
        _ => GoogleDocFormats.KindName(mime),
    };

    public static Item PhotoItem(Account acct, PhotoAsset a) => new()
    {
        Key = "photo:" + acct.Id + "|" + a.Id, Name = a.Filename, Size = a.Size, Modified = a.Created, Created = a.Added, Photo = a, AccountID = acct.Id,
        Glyph = a.IsVideo ? "\uE714" : "\uEB9F",
    };
}
