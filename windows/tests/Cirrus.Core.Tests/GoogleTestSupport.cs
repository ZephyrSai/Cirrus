using System.Security.Cryptography;
using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>A read-only Photos library for move tests: every write is counted and refused.</summary>
sealed class TestPhotos : IPhotosBackend
{
    readonly object _lock = new();
    public List<PhotoAsset> Assets = [];
    public List<PhotoAlbum> UserAlbums = [];
    public Dictionary<string, List<string>> Membership = [];
    public int Writes;
    /// <summary>Listing these albums fails (network trouble).</summary>
    public HashSet<string> FailingAlbums = [];
    public PhotoCapabilities Capabilities => PhotoCapabilities.None;
    public string CacheKey => "test";

    public static PhotoAsset Asset(int i, bool video = false, bool live = false, bool favorite = false, long size = 40_000, string? name = null)
    {
        var id = $"A{i:0000}";
        var fname = name ?? (video ? $"IMG_{i:0000}.MOV" : $"IMG_{i:0000}.HEIC");
        var res = new List<PhotoResource> { new() { Kind = PhotoResourceKind.Original, Filename = fname, Size = size, Key = "o", RecordName = id } };
        if (live) res.Add(new PhotoResource { Kind = PhotoResourceKind.LiveVideo, Filename = $"IMG_{i:0000}.MOV", Size = 30_000, Key = "v", RecordName = id });
        return new PhotoAsset
        {
            Id = id, MasterID = id, ChangeTag = "1", Library = "lib", Filename = fname, Size = size, Created = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i * 3600L),
            Width = 100, Height = 100, IsVideo = video, IsLive = live, IsFavorite = favorite, Resources = res,
        };
    }

    public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("lib", "Personal Library", false) });
    public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default)
    {
        lock (_lock) return Task.FromResult(new List<PhotoAlbum> { new("smart:All Photos", "All Photos", PhotoAlbumKind.Smart) }.Concat(UserAlbums).ToList());
    }
    public Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
    {
        if (FailingAlbums.Contains(album.Id)) throw ICloudException.Server("listing failed");
        List<PhotoAsset> list;
        lock (_lock) list = album.IsAllPhotos ? Assets.ToList() : Assets.Where(a => Membership.GetValueOrDefault(album.Id)?.Contains(a.Id) == true).ToList();
        page?.Invoke(list, list.Count);
        return Task.FromResult(list);
    }
    public Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);
    /// <summary>Deterministic bytes: a per-item header makes every file's MD5 different.</summary>
    public static byte[] Bytes(PhotoAsset asset, PhotoResourceKind kind)
    {
        var size = (int)(asset.Resource(kind)?.Size ?? asset.Size);
        var d = new byte[size];
        var h = SHA256.HashData(Encoding.UTF8.GetBytes($"{asset.Id}|{kind}|{asset.ChangeTag}"));
        h.AsSpan(0, Math.Min(h.Length, size)).CopyTo(d);
        return d;
    }
    public Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        var d = Bytes(asset, resource);
        File.WriteAllBytes(destination, d);
        progress?.Invoke(d.Length, d.Length);
        return Task.CompletedTask;
    }
    Exception Refuse() { lock (_lock) Writes++; return ICloudException.Server("tests never write to iCloud"); }
    public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default) => throw Refuse();
    public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default) => throw Refuse();
    public Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) => throw Refuse();
    public Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) => throw Refuse();
    public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) => throw Refuse();
    public Task AddAsync(IReadOnlyList<PhotoAsset> assets, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default) => throw Refuse();
    public Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default) => throw Refuse();
    public string? SyncToken(PhotoLibraryRef library) => null;
    public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult((true, (string?)null));
}

/// <summary>An iCloud Photos stand-in that records what it receives (and keeps a copy to inspect).</summary>
sealed class RecordingPhotos : IPhotosBackend
{
    readonly string _dir;
    readonly object _lock = new();
    public List<PhotoAsset> Assets = [];
    public List<PhotoAlbum> AlbumList = [];
    public Dictionary<string, List<string>> Membership = [];
    public List<List<string>> ImportCalls = [];
    public Dictionary<string, string> Stored = [];
    /// <summary>The modification time each file had when it reached "iCloud" (what iCloud.com's lastModDate carries).</summary>
    public Dictionary<string, DateTime> ReceivedMtime = [];
    /// <summary>Importing a file with this name fails (after the files before it in the call went in).</summary>
    public string? FailOnName;
    public PhotoCapabilities Capabilities => PhotoCapabilities.Favorite | PhotoCapabilities.ImportFiles | PhotoCapabilities.Albums | PhotoCapabilities.CreateAlbum;
    public string CacheKey => "recording";

    public RecordingPhotos(string dir) { _dir = dir; Directory.CreateDirectory(dir); }

    public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("lib", "Personal Library", false) });
    public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default) { lock (_lock) return Task.FromResult(AlbumList.ToList()); }
    public Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
    {
        List<PhotoAsset> list;
        lock (_lock) list = album.IsAllPhotos ? Assets.ToList() : Assets.Where(a => Membership.GetValueOrDefault(album.Id)?.Contains(a.Id) == true).ToList();
        page?.Invoke(list, list.Count);
        return Task.FromResult(list);
    }
    public Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);
    public Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default) => throw ICloudException.NotFound();
    public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) =>
        ImportFilesEachAsync(files, album, library, progress, (_, _) => { }, ct);

    public Task ImportFilesEachAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress,
        Action<string, string?> imported, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var names = new List<string>();
        foreach (var f in files)
        {
            if (Path.GetFileName(f) == FailOnName) { lock (_lock) ImportCalls.Add(names); throw ICloudException.Server("upload refused"); }
            var id = "R" + Guid.NewGuid().ToString("N")[..8];
            var copy = Path.Combine(_dir, id + "-" + Path.GetFileName(f));
            File.Copy(f, copy);
            var size = new FileInfo(copy).Length;
            var mtime = File.GetLastWriteTimeUtc(f);
            var a = new PhotoAsset
            {
                Id = id, Library = "lib", Filename = Path.GetFileName(f), Size = size, Created = new DateTimeOffset(mtime, TimeSpan.Zero),
                IsVideo = Path.GetExtension(f).ToLowerInvariant() is ".mov" or ".mp4",
                Resources = [new PhotoResource { Kind = PhotoResourceKind.Original, Filename = Path.GetFileName(f), Size = size, Key = "o", RecordName = id }],
            };
            lock (_lock)
            {
                Assets.Add(a);
                Stored[Path.GetFileName(f) + "#" + size] = copy;
                ReceivedMtime[Path.GetFileName(f)] = mtime;
                if (album is not null) { if (!Membership.TryGetValue(album.Id, out var l)) Membership[album.Id] = l = []; l.Add(id); }
            }
            names.Add(Path.GetFileName(f));
            imported(f, id);
        }
        lock (_lock) ImportCalls.Add(names);
        progress?.Invoke(files.Count, files.Count);
        return Task.CompletedTask;
    }
    public Task AddAsync(IReadOnlyList<PhotoAsset> list, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default)
    {
        lock (_lock)
        {
            if (!Membership.TryGetValue(album.Id, out var l)) Membership[album.Id] = l = [];
            foreach (var a in list) if (!l.Contains(a.Id)) l.Add(a.Id);
        }
        return Task.CompletedTask;
    }
    public Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var a = new PhotoAlbum("album:" + Guid.NewGuid().ToString("N")[..6], name, PhotoAlbumKind.Album);
        lock (_lock) AlbumList.Add(a);
        return Task.FromResult(a);
    }
    public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> list, bool value, CancellationToken ct = default)
    {
        lock (_lock) foreach (var a in Assets.Where(x => list.Any(l => l.Id == x.Id))) a.IsFavorite = value;
        return Task.FromResult(list.ToList());
    }
    public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default) => throw ICloudException.Server("not used");
    public Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) => throw ICloudException.Server("Cirrus never deletes here");
    public Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default) => throw ICloudException.Server("not used");
    public string? SyncToken(PhotoLibraryRef library) => null;
    public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult((true, (string?)null));

    public List<PhotoAsset> Members(string name)
    {
        lock (_lock)
        {
            if (AlbumList.FirstOrDefault(a => a.Name == name) is not { } a) return [];
            var ids = Membership.GetValueOrDefault(a.Id) ?? [];
            return Assets.Where(x => ids.Contains(x.Id)).ToList();
        }
    }
    public string? Copy(string name) { lock (_lock) return Stored.FirstOrDefault(kv => kv.Key.StartsWith(name + "#", StringComparison.Ordinal)).Value; }
}

/// <summary>Records removals instead of using the Recycle Bin.</summary>
sealed class TrashBin
{
    readonly string _dir;
    public List<string> Items = [];
    public TrashBin(string dir) { _dir = dir; Directory.CreateDirectory(dir); }
    public void Trash(string path, string root)
    {
        File.Move(path, Path.Combine(_dir, Guid.NewGuid().ToString("N")[..4] + "-" + Path.GetFileName(path)));
        lock (Items) Items.Add(Path.GetFileName(path));
    }
}

static class G
{
    public static readonly GoogleOAuthClient Client = new("demo-client.apps.googleusercontent.com", "demo-secret");

    /// <summary>Signs in through the real loopback listener and returns a fast-retrying API client.</summary>
    public static async Task<(FakeGoogle Fake, GoogleApi Api)> Connect(FakeGoogle.State? s = null, IEnumerable<string>? scopes = null)
    {
        var g = new FakeGoogle(s);
        var oauth = new GoogleOAuth(Client, g) { Delay = (_, _) => Task.CompletedTask };
        var tokens = await oauth.AuthorizeAsync(u => g.ApproveAsync(u), scopes ?? GoogleScopes.All);
        var refresh = tokens.RefreshToken ?? throw new Exception("no refresh token");
        var api = new GoogleApi(g.S.UserID, oauth, tokens.Scopes, _ => Task.FromResult(refresh), g, tokens) { RetryBase = 0.001, BatchCreateMinBackoff = 0 };
        return (g, api);
    }

    public static MigrationEngine Engine(GoogleApi api, string state, string? driveRoot = null, IPhotosBackend? photos = null, MigrationOptions? options = null,
        int chunk = 256 * 1024, IDriveBackend? drive = null, string key = "test:icloud")
    {
        var target = new MigrationEngine.Target(api);
        target.Drive.ChunkSize = chunk;
        target.Photos.ChunkSize = chunk;
        var src = new MigrationEngine.Sources(key, "Test iCloud", drive, drive is null ? driveRoot : null, photos);
        return new MigrationEngine(src, target, options ?? new MigrationOptions(), state, Path.Combine(state, "staging"));
    }

    public static ImportEngine Import(GoogleApi api, string state, IReadOnlyList<string>? takeout = null, IReadOnlyList<GooglePickedItem>? picked = null,
        string? driveRoot = null, IPhotosBackend? photos = null, ImportOptions? options = null, bool readOnly = false, TrashBin? bin = null,
        IDriveBackend? drive = null, string key = "test:icloud", bool isWeb = false)
    {
        var target = new ImportEngine.TargetSpec(key, "Test iCloud", drive, drive is null ? driveRoot : null, photos, null, isWeb);
        var trash = bin ?? new TrashBin(Path.Combine(state, "trash"));
        return new ImportEngine(new ImportEngine.SourceSpec(api, takeout ?? [], picked ?? []), target, options ?? new ImportOptions(), state,
            Path.Combine(state, "staging"), () => readOnly, trash.Trash);
    }

    public static string Md5(string path) => Convert.ToHexStringLower(MD5.HashData(File.ReadAllBytes(path)));
}
