using System.Text.Json;

namespace Cirrus.Core;

// Demo iCloud (CIRRUS_DEMO=1): a disk-backed fake Drive + Photos library so the UI, drag and drop,
// transfers, sync and backup can be exercised without an Apple ID. Never touches real accounts.

public sealed class DemoDrive : IDriveBackend
{
    static readonly Lazy<DemoDrive> _shared = new(() => new DemoDrive());
    public static DemoDrive Shared => _shared.Value;
    public string RootID => "FOLDER::demo::";
    readonly string _root, _trash;
    readonly int _delayMs;
    readonly object _lock = new();

    DemoDrive()
    {
        var baseDir = Paths.CacheDir("demo");
        _root = Path.Combine(baseDir, "drive");
        _trash = Path.Combine(baseDir, "drive-trash");
        _delayMs = Env.Flag("CIRRUS_DEMO_FAST") ? 0 : 120;
        Seed();
    }

    void Seed()
    {
        Directory.CreateDirectory(_trash);
        if (Directory.Exists(_root)) return;
        (string, string)[] files =
        [
            ("Documents/Budget 2026.csv", "Month,Income,Spend\nJan,4200,3100\nFeb,4200,2950\n"),
            ("Documents/Notes/Ideas.txt", "Cirrus demo notes.\n"),
            ("Documents/Notes/Trip checklist.md", "# Trip\n- Passport\n- Charger\n"),
            ("Projects/Cirrus/README.md", "# Cirrus\nA Finder for iCloud.\n"),
            ("Projects/Cirrus/roadmap.txt", "v1: browse, transfer, sync, backup\n"),
            ("Desktop/todo.txt", "Back up photos\n"),
            ("Recipe.txt", "Pancakes: flour, milk, eggs.\n"),
        ];
        foreach (var (p, s) in files)
        {
            var u = Paths.Combine(_root, p);
            Directory.CreateDirectory(Path.GetDirectoryName(u)!);
            File.WriteAllText(u, s);
        }
        for (int i = 0; i < 6; i++)
        {
            var u = Path.Combine(_root, "Pictures", $"Wallpaper {i + 1}.png");
            Directory.CreateDirectory(Path.GetDirectoryName(u)!);
            File.WriteAllBytes(u, DemoArt.Png(1280, 800, i / 6.0, $"Wallpaper {i + 1}"));
        }
        var big = Path.Combine(_root, "Archives", "Big download.bin");
        Directory.CreateDirectory(Path.GetDirectoryName(big)!);
        using (var fs = File.Create(big)) fs.SetLength(24 << 20);
    }

    static string Rel(string id) => string.Join("::", id.Split("::").Skip(2));
    string PathOf(string id) => Rel(id) is var r && r.Length == 0 ? _root : Paths.Combine(_root, r);

    DriveNode Node(string path, string? baseDir = null)
    {
        baseDir ??= _root;
        var r = Path.GetRelativePath(baseDir, path).Replace(Path.DirectorySeparatorChar, '/');
        if (r == ".") r = "";
        var dir = Directory.Exists(path);
        FileSystemInfo info = dir ? new DirectoryInfo(path) : new FileInfo(path);
        var parentRel = r.Contains('/') ? r[..r.LastIndexOf('/')] : "";
        var mtime = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);
        return new DriveNode
        {
            Id = (dir ? "FOLDER" : "FILE") + "::demo::" + r, DocID = r, Zone = "demo", ParentID = "FOLDER::demo::" + parentRel,
            Name = Path.GetFileName(path), Type = dir ? "FOLDER" : "FILE", Size = dir ? 0 : ((FileInfo)info).Length,
            Modified = mtime, Created = new DateTimeOffset(info.CreationTimeUtc, TimeSpan.Zero), Etag = mtime.ToUnixTimeSeconds().ToString(),
            ChildCount = dir ? Directory.EnumerateFileSystemEntries(path).Count(e => !Path.GetFileName(e).StartsWith('.')) : null,
        };
    }

    Task Pause(CancellationToken ct) => _delayMs > 0 ? Task.Delay(_delayMs, ct) : Task.CompletedTask;

    public async Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default)
    {
        await Pause(ct).ConfigureAwait(false);
        var u = PathOf(folderID);
        if (!Directory.Exists(u)) throw ICloudException.NotFound();
        return Directory.EnumerateFileSystemEntries(u).Where(e => !Path.GetFileName(e).StartsWith('.')).Select(e => Node(e)).ToList();
    }

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        var o = new Dictionary<string, List<DriveNode>>();
        foreach (var f in folderIDs) o[f] = await ListAsync(f, ct).ConfigureAwait(false);
        return o;
    }

    public async Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        var src = PathOf(node.Id);
        var total = node.Size;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (_delayMs > 0 && total > 1 << 20)
            for (int s = 1; s <= 12; s++) { await Task.Delay(90, ct).ConfigureAwait(false); progress?.Invoke(total * s / 12, total); }
        File.Copy(src, destination, overwrite: true);
        progress?.Invoke(total, total);
        if (node.Modified is { } m) File.SetLastWriteTimeUtc(destination, m.UtcDateTime);
    }

    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await Pause(ct).ConfigureAwait(false);
        var size = new FileInfo(file).Length;
        if (size > Limits.ICloudDriveMax) throw ICloudException.Server($"“{name}” is {size.ByteString()}, larger than iCloud Drive’s 50 GB file limit.");
        var dest = Path.Combine(PathOf(folderID), name);
        if (_delayMs > 0 && size > 1 << 20)
            for (int s = 1; s <= 10; s++) { await Task.Delay(80, ct).ConfigureAwait(false); progress?.Invoke(size * s / 10, size); }
        File.Copy(file, dest, overwrite: true);   // demo store: an upload over an existing name is iCloud's "replace" (Cirrus uses SafeReplace)
        if (modified is { } m) File.SetLastWriteTimeUtc(dest, m.UtcDateTime);
        progress?.Invoke(size, size);
        return Node(dest);
    }

    public async Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await Pause(ct).ConfigureAwait(false);
        var u = Path.Combine(PathOf(folderID), name);
        if (Directory.Exists(u) || File.Exists(u)) throw ICloudException.Server("An item with that name already exists.");
        Directory.CreateDirectory(u);
        return Node(u);
    }

    public async Task<DriveNode> RenameAsync(DriveNode n, string name, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await Pause(ct).ConfigureAwait(false);
        var src = PathOf(n.Id);
        var dst = Path.Combine(Path.GetDirectoryName(src)!, name);
        if (LocalFiles.Exists(dst)) throw ICloudException.Server("An item with that name already exists.");
        LocalFiles.MoveItem(src, dst);
        return Node(dst);
    }

    public async Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await Pause(ct).ConfigureAwait(false);
        foreach (var n in nodes)
        {
            var src = PathOf(n.Id);
            LocalFiles.MoveItem(src, Path.Combine(PathOf(folderID), Path.GetFileName(src)));
        }
    }

    public async Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await Pause(ct).ConfigureAwait(false);
        lock (_lock)
            foreach (var n in nodes)
            {
                var src = PathOf(n.Id);
                var name = Path.GetFileName(src);
                var dst = Path.Combine(_trash, name);
                if (LocalFiles.Exists(dst)) { name = Guid.NewGuid().ToString("N")[..6] + " " + name; dst = Path.Combine(_trash, name); }
                LocalFiles.MoveItem(src, dst);
                File.WriteAllText(Path.Combine(_trash, "." + name + ".origin"), Rel(n.Id));
            }
    }

    public async Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default)
    {
        await Pause(ct).ConfigureAwait(false);
        return Directory.EnumerateFileSystemEntries(_trash).Where(e => !Path.GetFileName(e).StartsWith('.')).Select(e =>
        {
            var d = Node(e, _trash);
            d.Id = "TRASH::demo::" + Path.GetFileName(e);
            d.ParentID = "TRASH_ROOT";
            return d;
        }).ToList();
    }

    public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        lock (_lock)
            foreach (var n in nodes)
            {
                var name = Rel(n.Id);
                var src = Path.Combine(_trash, name);
                var originFile = Path.Combine(_trash, "." + name + ".origin");
                var origin = File.Exists(originFile) ? File.ReadAllText(originFile) : name;
                var dst = Paths.Combine(_root, origin);
                Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                if (LocalFiles.Exists(dst)) dst = Path.Combine(Path.GetDirectoryName(dst)!, Path.GetFileNameWithoutExtension(dst) + " (recovered)" + Path.GetExtension(dst));
                LocalFiles.MoveItem(src, dst);
                File.Delete(originFile);
            }
        return Task.CompletedTask;
    }

    /// <summary>Demo store only: removes items from the demo's Recently Deleted folder.</summary>
    public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        DriveBackendExtensions.GuardTrashOnly(nodes);
        lock (_lock)
            foreach (var n in nodes)
            {
                var name = Rel(n.Id);
                var p = Path.Combine(_trash, name);
                if (Directory.Exists(p)) Directory.Delete(p, true); else if (File.Exists(p)) File.Delete(p);
                var o = Path.Combine(_trash, "." + name + ".origin");
                if (File.Exists(o)) File.Delete(o);
            }
        return Task.CompletedTask;
    }
}

public sealed class DemoPhotos : IPhotosBackend
{
    static readonly Lazy<DemoPhotos> _shared = new(() => new DemoPhotos());
    public static DemoPhotos Shared => _shared.Value;
    public string CacheKey => "demo";
    public PhotoCapabilities Capabilities => PhotoCapabilities.Favorite | PhotoCapabilities.Hide | PhotoCapabilities.Delete | PhotoCapabilities.Restore
        | PhotoCapabilities.ImportFiles | PhotoCapabilities.Albums | PhotoCapabilities.CreateAlbum;

    sealed class Store
    {
        public List<PhotoAsset> Assets { get; set; } = [];
        public List<PhotoAlbum> Albums { get; set; } = [];
        public Dictionary<string, List<string>> Membership { get; set; } = [];   // album id → asset ids
        /// <summary>Bumped on every change: the demo's stand-in for a CloudKit sync token.</summary>
        public long Version { get; set; } = 1;
    }

    readonly string _dir;
    readonly object _lock = new();
    Store _store;
    const int ArtVersion = 3;
    static bool Fast => Env.Flag("CIRRUS_DEMO_FAST");

    DemoPhotos()
    {
        _dir = Path.Combine(Paths.CacheDir("demo"), "photos");
        var marker = Path.Combine(_dir, $"art-v{ArtVersion}");
        if (!File.Exists(marker) && Directory.Exists(_dir)) Directory.Delete(_dir, true);   // the demo's own generated cache
        Directory.CreateDirectory(_dir);
        File.WriteAllText(marker, "");
        var file = Path.Combine(_dir, "store.json");
        try
        {
            if (File.Exists(file) && JsonSerializer.Deserialize<Store>(File.ReadAllBytes(file)) is { } s) { _store = s; return; }
        }
        catch { }
        _store = new Store();
        Seed();
    }

    void Save() { lock (_lock) { _store.Version++; AtomicFile.Write(Path.Combine(_dir, "store.json"), JsonSerializer.SerializeToUtf8Bytes(_store)); } }

    public string? SyncToken(PhotoLibraryRef library) { lock (_lock) return "demo-" + _store.Version; }

    public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default)
    {
        var now = SyncToken(library);
        return Task.FromResult((token != now, now));
    }

    void Seed()
    {
        var count = int.TryParse(Env.Get("CIRRUS_DEMO_PHOTOS"), out var c) ? c : 96;
        string[] names = ["Beach", "Hike", "City", "Dinner", "Sunset", "Garden", "Snow", "Lake", "Market", "Concert", "Bridge", "Cafe"];
        var assets = new List<PhotoAsset>();
        var now = DateTimeOffset.Now;
        Parallel.For(0, count, i =>
        {
            int w = i % 7 == 0 ? 720 : 960, h = i % 7 == 0 ? 960 : 720;
            File.WriteAllBytes(Path.Combine(_dir, $"DEMO-{i:0000}.png"), DemoArt.Png(w, h, (i * 37 % 100) / 100.0, $"{names[i % names.Length]} {i + 1}"));
        });
        for (int i = 0; i < count; i++)
        {
            var id = $"DEMO-{i:0000}";
            var fname = $"IMG_{1000 + i:0000}.PNG";
            int w = i % 7 == 0 ? 720 : 960, h = i % 7 == 0 ? 960 : 720;
            var size = new FileInfo(Path.Combine(_dir, id + ".png")).Length;
            var created = now.AddSeconds(-(i * 86400 * 9.5) - (i * 7919 % 86400));
            var res = new List<PhotoResource> { new() { Kind = PhotoResourceKind.Original, Filename = fname, Size = size, Key = "file", RecordName = id, Uti = "public.png" } };
            if (i % 9 == 4)
            {
                using (var fs = File.Create(Path.Combine(_dir, id + ".mov"))) fs.SetLength(180_000);
                res.Add(new PhotoResource { Kind = PhotoResourceKind.LiveVideo, Filename = Path.GetFileNameWithoutExtension(fname) + ".MOV", Size = 180_000, Key = "mov", RecordName = id, Uti = "com.apple.quicktime-movie" });
            }
            assets.Add(new PhotoAsset
            {
                Id = id, MasterID = id, ChangeTag = "1", Library = "demo", Filename = fname, Size = size, Created = created, Added = created,
                Width = w, Height = h, IsLive = i % 9 == 4, IsFavorite = i % 11 == 0, IsHidden = i == 5, Uti = "public.png", Resources = res,
            });
        }
        _store.Assets = assets;
        _store.Albums =
        [
            new PhotoAlbum("folder:trips", "Trips", PhotoAlbumKind.Folder, symbol: "folder"),
            new PhotoAlbum("album:travel", "Travel", PhotoAlbumKind.Album, "folder:trips"),
            new PhotoAlbum("album:family", "Family", PhotoAlbumKind.Album),
            new PhotoAlbum("album:food", "Food", PhotoAlbumKind.Album),
        ];
        _store.Membership = new()
        {
            ["album:travel"] = assets.Where((_, i) => i % 4 == 0).Select(a => a.Id).ToList(),
            ["album:family"] = assets.Where((_, i) => i % 5 == 1).Select(a => a.Id).ToList(),
            ["album:food"] = assets.Where((_, i) => i % 12 == 3).Select(a => a.Id).ToList(),
        };
        Save();
    }

    public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("demo", "Personal Library", false) });

    List<PhotoAsset> Members(PhotoAlbum album)
    {
        lock (_lock)
        {
            var live = _store.Assets.Where(a => !a.IsDeleted).ToList();
            var list = album.Id switch
            {
                "smart:All Photos" => live.Where(a => !a.IsHidden),
                "smart:Favorites" => live.Where(a => a.IsFavorite && !a.IsHidden),
                "smart:Live" => live.Where(a => a.IsLive && !a.IsHidden),
                "smart:Videos" => live.Where(a => a.IsVideo && !a.IsHidden),
                "smart:Hidden" => live.Where(a => a.IsHidden),
                "smart:Recently Deleted" => _store.Assets.Where(a => a.IsDeleted),
                _ => live.Where(a => (_store.Membership.GetValueOrDefault(album.Id) ?? []).Contains(a.Id)),
            };
            return list.Select(a => a.Copy()).ToList();
        }
    }

    public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default)
    {
        var output = new List<PhotoAlbum>
        {
            new("smart:All Photos", "All Photos", PhotoAlbumKind.Smart, symbol: "photos"),
            new("smart:Favorites", "Favorites", PhotoAlbumKind.Smart, symbol: "heart"),
            new("smart:Live", "Live Photos", PhotoAlbumKind.Smart, symbol: "live"),
            new("smart:Hidden", "Hidden", PhotoAlbumKind.Smart, symbol: "hidden"),
            new("smart:Recently Deleted", "Recently Deleted", PhotoAlbumKind.Smart, symbol: "trash"),
        };
        lock (_lock) output.AddRange(_store.Albums.Select(a => new PhotoAlbum(a.Id, a.Name, a.Kind, a.ParentID, a.Count, a.Symbol)));
        foreach (var a in output.Where(a => a.Kind != PhotoAlbumKind.Folder)) a.Count = Members(a).Count;
        return Task.FromResult(output);
    }

    public async Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
    {
        var all = Members(album);
        foreach (var chunk in all.Chunk(40))
        {
            if (!Fast) await Task.Delay(60, ct).ConfigureAwait(false);
            page?.Invoke(chunk, all.Count);
        }
        return all;
    }

    string FileOf(PhotoAsset asset, PhotoResourceKind kind)
    {
        var b = asset.MasterID ?? asset.Id;
        if (kind == PhotoResourceKind.LiveVideo) return Path.Combine(_dir, b + ".mov");
        var ext = Path.GetExtension(asset.Resource(PhotoResourceKind.Original)?.Filename ?? ".png").TrimStart('.').ToLowerInvariant();
        var f = Path.Combine(_dir, b + "." + ext);
        return File.Exists(f) ? f : Path.Combine(_dir, b + ".png");
    }

    public Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default)
    {
        var f = FileOf(asset, PhotoResourceKind.Original);
        return Task.FromResult(File.Exists(f) ? File.ReadAllBytes(f) : null);
    }

    public async Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (asset.Resource(resource) is null) throw ICloudException.NotFound();
        if (!Fast) await Task.Delay(50, ct).ConfigureAwait(false);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        File.Copy(FileOf(asset, resource), destination, overwrite: true);
        if (asset.Created is { } d) { File.SetLastWriteTimeUtc(destination, d.UtcDateTime); try { File.SetCreationTimeUtc(destination, d.UtcDateTime); } catch { } }
        var s = asset.Resource(resource)?.Size ?? 0;
        progress?.Invoke(s, s);
    }

    List<PhotoAsset> Mutate(IReadOnlyList<PhotoAsset> assets, Action<PhotoAsset> f)
    {
        List<PhotoAsset> result;
        lock (_lock)
        {
            var ids = assets.Select(a => a.Id).ToHashSet();
            foreach (var a in _store.Assets.Where(a => ids.Contains(a.Id))) f(a);
            result = _store.Assets.Where(a => ids.Contains(a.Id)).Select(a => a.Copy()).ToList();
        }
        Save();
        return result;
    }

    public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default) { SafetyPolicy.CheckWrite(); return Task.FromResult(Mutate(assets, a => a.IsFavorite = value)); }
    public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default) { SafetyPolicy.CheckWrite(); return Task.FromResult(Mutate(assets, a => a.IsHidden = value)); }
    public Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) { SafetyPolicy.CheckWrite(); Mutate(assets, a => a.IsDeleted = true); return Task.CompletedTask; }
    public Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) { SafetyPolicy.CheckWrite(); Mutate(assets, a => a.IsDeleted = false); return Task.CompletedTask; }

    public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        long n = 0;
        foreach (var g in LivePairing.GroupFiles(files))
        {
            ct.ThrowIfCancellationRequested();
            var id = "DEMO-" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
            var ext = Path.GetExtension(g.Primary).TrimStart('.').ToLowerInvariant();
            var dst = Path.Combine(_dir, id + "." + (ext.Length == 0 ? "jpg" : ext));
            File.Copy(g.Primary, dst);
            var size = new FileInfo(dst).Length;
            var res = new List<PhotoResource> { new() { Kind = PhotoResourceKind.Original, Filename = Path.GetFileName(g.Primary), Size = size, Key = "file", RecordName = id } };
            if (g.PairedVideo is { } v)
            {
                File.Copy(v, Path.Combine(_dir, id + ".mov"));
                res.Add(new PhotoResource { Kind = PhotoResourceKind.LiveVideo, Filename = Path.GetFileName(v), Size = new FileInfo(v).Length, Key = "mov", RecordName = id });
            }
            var dims = ImageInfo.Size(dst);
            var a = new PhotoAsset
            {
                Id = id, MasterID = id, ChangeTag = "1", Library = "demo", Filename = Path.GetFileName(g.Primary), Size = size,
                Created = new DateTimeOffset(File.GetLastWriteTimeUtc(g.Primary), TimeSpan.Zero), Added = DateTimeOffset.Now,
                Width = dims?.Width ?? 0, Height = dims?.Height ?? 0, IsVideo = PhotoFormats.IsVideoFile(g.Primary), IsLive = g.PairedVideo is not null,
                Resources = res,
            };
            lock (_lock)
            {
                _store.Assets.Insert(0, a);
                if (album is { Kind: PhotoAlbumKind.Album })
                {
                    if (!_store.Membership.TryGetValue(album.Id, out var l)) _store.Membership[album.Id] = l = [];
                    l.Add(id);
                }
            }
            n++;
            progress?.Invoke(n, files.Count);
        }
        Save();
        return Task.CompletedTask;
    }

    public Task AddAsync(IReadOnlyList<PhotoAsset> assets, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        lock (_lock)
        {
            if (!_store.Membership.TryGetValue(album.Id, out var ids)) _store.Membership[album.Id] = ids = [];
            foreach (var a in assets) if (!ids.Contains(a.Id)) ids.Add(a.Id);
        }
        Save();
        return Task.CompletedTask;
    }

    public Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var a = new PhotoAlbum("album:" + Guid.NewGuid().ToString("N")[..8], name, PhotoAlbumKind.Album, count: 0);
        lock (_lock) _store.Albums.Add(a);
        Save();
        return Task.FromResult(a);
    }
}
