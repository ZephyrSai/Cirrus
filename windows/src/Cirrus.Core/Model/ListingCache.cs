using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Cirrus.Core;

/// <summary>
/// Disk caches for iCloud listings, so opening a folder or album never starts from scratch (port of the Mac
/// Catalog caches):
/// <list type="bullet">
/// <item>Album assets {assets, syncToken, savedAt}: younger than <see cref="AlbumFreshFor"/> → served with no
/// network at all; older → CloudKit is asked whether anything changed since the token, and the cache is kept when
/// nothing did.</item>
/// <item>iCloud Drive folders (shown at once, then refreshed).</item>
/// <item>Album lists (10 minutes) and library lists (1 day).</item>
/// </list>
/// Files live under Cache\listings\&lt;hash(account)&gt;\, names hashed (no Apple IDs or album names on disk).
/// </summary>
public sealed class ListingCache
{
    public static ListingCache Shared { get; } = new();

    public static TimeSpan AlbumFreshFor { get; set; } = TimeSpan.FromSeconds(300);
    public static readonly TimeSpan AlbumListMaxAge = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan LibraryListMaxAge = TimeSpan.FromDays(1);
    /// <summary>Smart albums whose membership our own edits change: never patched, always re-listed.</summary>
    public static readonly string[] EditSensitive = ["smart:Recently Deleted", "smart:Favorites", "smart:Hidden"];

    public sealed class AlbumCache
    {
        public List<PhotoAsset> Assets { get; set; } = [];
        public string? Token { get; set; }
        public DateTimeOffset SavedAt { get; set; }
        public string Library { get; set; } = "";
        public string Album { get; set; } = "";
    }

    public sealed class DriveCache
    {
        public List<DriveNode> Nodes { get; set; } = [];
        public DateTimeOffset SavedAt { get; set; }
    }

    sealed class ListEnvelope<T>
    {
        public List<T> Items { get; set; } = [];
        public DateTimeOffset SavedAt { get; set; }
    }

    /// <summary>Test hook for "now".</summary>
    internal Func<DateTimeOffset> Clock { get; set; } = () => DateTimeOffset.UtcNow;
    readonly object _lock = new();
    /// <summary>Accounts signed out in this run: late answers from requests still in flight are never written back.</summary>
    readonly HashSet<string> _wiped = [];
    /// <summary>Our own photo edits, numbered, so a listing that was running meanwhile can apply them to its result.</summary>
    readonly List<(long Epoch, string Account, string Library, IReadOnlyList<PhotoAsset> Updated, IReadOnlySet<string> Removed)> _patches = [];
    long _epoch;

    static string Hash(string s) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(s)))[..24];

    public static string AccountDir(string accountID) => Path.Combine(Paths.CacheDir("listings"), Hash(accountID));

    string FileFor(string accountID, string kind, string key)
    {
        var dir = AccountDir(accountID);
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, kind + "-" + Hash(key) + ".json");
    }

    T? Read<T>(string file) where T : class
    {
        lock (_lock)
        {
            try { return File.Exists(file) ? JsonSerializer.Deserialize<T>(File.ReadAllBytes(file)) : null; } catch { return null; }
        }
    }

    void Write<T>(string accountID, string file, T value)
    {
        lock (_lock)
        {
            if (_wiped.Contains(accountID)) return;
            AtomicFile.Write(file, JsonSerializer.SerializeToUtf8Bytes(value));
        }
    }

    // MARK: Album assets

    public AlbumCache? LoadAlbum(string accountID, string library, string albumID) => Read<AlbumCache>(FileFor(accountID, "album", library + "|" + albumID));

    public void SaveAlbum(string accountID, string library, string albumID, AlbumCache c)
    {
        c.Library = library; c.Album = albumID;
        Write(accountID, FileFor(accountID, "album", library + "|" + albumID), c);
    }

    /// <summary>
    /// Lists an album through the cache. <paramref name="partial"/> receives the cached listing while the freshness
    /// check runs, or pages as they stream in when there is no cache.
    /// </summary>
    public async Task<List<PhotoAsset>> ListAlbumAsync(IPhotosBackend photos, string accountID, PhotoLibraryRef lib, PhotoAlbum album, bool forced,
        bool useDisk, Action<IReadOnlyList<PhotoAsset>>? partial, CancellationToken ct = default)
    {
        var cache = useDisk ? LoadAlbum(accountID, lib.Id, album.Id) : null;
        if (cache is not null && !forced)
        {
            if (Clock() - cache.SavedAt < AlbumFreshFor) return cache.Assets;          // fresh: no network at all
            partial?.Invoke(cache.Assets);
            if (cache.Token is { } token)
            {
                (bool Changed, string? Token)? check = null;
                try { check = await photos.HasChangesAsync(token, lib, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { throw; }
                catch (Exception e) { Log.Status("photos: change check failed (" + e.GetType().Name + "), listing again"); }
                if (check is { Changed: false } c)
                {
                    cache.Token = c.Token ?? token;
                    cache.SavedAt = Clock();
                    SaveAlbum(accountID, lib.Id, album.Id, cache);
                    Log.Status($"photos: album unchanged, served from cache ({cache.Assets.Count} items)");
                    return cache.Assets;
                }
            }
        }
        var hadCache = cache is not null;
        // The token is taken BEFORE listing: anything that changes while the listing runs is then newer than the
        // token, so the next change check sees it (a token read afterwards could vouch for changes the listing missed).
        var tokenBefore = photos.SyncToken(lib);
        long epochBefore;
        lock (_lock) epochBefore = _epoch;
        var streamed = new List<PhotoAsset>();
        var gate = new object();
        var assets = await photos.AssetsAsync(album, lib, hadCache || partial is null ? null : (batch, _) =>
        {
            List<PhotoAsset> snapshot;
            lock (gate) { streamed.AddRange(batch); snapshot = streamed.ToList(); }
            partial(snapshot);
        }, ct).ConfigureAwait(false);
        // Our own edits made while the listing ran (the server may have answered before them).
        List<(long Epoch, string Account, string Library, IReadOnlyList<PhotoAsset> Updated, IReadOnlySet<string> Removed)> during;
        lock (_lock) during = _patches.Where(p => p.Epoch > epochBefore && p.Account == accountID && p.Library == lib.Id).ToList();
        var stale = false;
        if (during.Count > 0)
        {
            if (EditSensitive.Contains(album.Id)) stale = true;   // membership changed in ways a patch can't express
            else
                foreach (var p in during)
                {
                    assets.RemoveAll(a => p.Removed.Contains(a.Id));
                    var byID = p.Updated.GroupBy(u => u.Id).ToDictionary(g => g.Key, g => g.First());
                    assets = assets.Select(a => byID.TryGetValue(a.Id, out var u) ? u : a).ToList();
                }
        }
        if (useDisk)
            SaveAlbum(accountID, lib.Id, album.Id, new AlbumCache
            {
                Assets = assets, Token = stale ? null : tokenBefore, SavedAt = stale ? DateTimeOffset.MinValue : Clock(),
            });
        return assets;
    }

    /// <summary>Our own change to an album (upload, add, F5): its cached copy must be listed again before it's trusted.</summary>
    public void MarkAlbumStale(string accountID, string library, string albumID)
    {
        var f = FileFor(accountID, "album", library + "|" + albumID);
        if (Read<AlbumCache>(f) is { } c) { c.SavedAt = DateTimeOffset.MinValue; c.Token = null; Write(accountID, f, c); }
    }

    /// <summary>
    /// Applies our own photo edits to every cached album of a library (no re-download). Albums whose membership the
    /// edit changes (Favorites, Hidden, Recently Deleted) are marked stale instead.
    /// </summary>
    public void PatchPhotos(string accountID, string library, IReadOnlyList<PhotoAsset> updated, IReadOnlySet<string> removed)
    {
        var byID = new Dictionary<string, PhotoAsset>();
        foreach (var u in updated) byID.TryAdd(u.Id, u);
        lock (_lock)
        {
            _patches.Add((++_epoch, accountID, library, updated.ToList(), removed.ToHashSet()));
            if (_patches.Count > 200) _patches.RemoveRange(0, _patches.Count - 200);
        }
        var dir = AccountDir(accountID);
        if (!Directory.Exists(dir)) return;
        foreach (var f in Directory.EnumerateFiles(dir, "album-*.json"))
        {
            if (Read<AlbumCache>(f) is not { } c || c.Library != library) continue;
            if (EditSensitive.Contains(c.Album)) { c.SavedAt = DateTimeOffset.MinValue; c.Token = null; }   // must be listed again
            else
            {
                c.Assets.RemoveAll(a => removed.Contains(a.Id));
                c.Assets = c.Assets.Select(a => byID.TryGetValue(a.Id, out var u) ? u : a).ToList();
            }
            Write(accountID, f, c);
        }
    }

    // MARK: Drive folders

    public DriveCache? LoadDrive(string accountID, string folderID) => Read<DriveCache>(FileFor(accountID, "drive", folderID));
    public void SaveDrive(string accountID, string folderID, List<DriveNode> nodes) =>
        Write(accountID, FileFor(accountID, "drive", folderID), new DriveCache { Nodes = nodes, SavedAt = Clock() });

    // MARK: Album and library lists

    /// <summary>A cached list and whether it's still within <paramref name="maxAge"/>.</summary>
    public (List<T>? Items, bool Fresh) LoadList<T>(string accountID, string name, TimeSpan maxAge)
    {
        var env = Read<ListEnvelope<T>>(FileFor(accountID, "list", name));
        if (env is null) return (null, false);
        return (env.Items, Clock() - env.SavedAt < maxAge);
    }

    public void SaveList<T>(string accountID, string name, List<T> items) =>
        Write(accountID, FileFor(accountID, "list", name), new ListEnvelope<T> { Items = items, SavedAt = Clock() });

    /// <summary>Sign-out: forgets every listing of the account (Cirrus' own cache).</summary>
    public void WipeAccount(string accountID)
    {
        lock (_lock)
        {
            _wiped.Add(accountID);
            try { var d = AccountDir(accountID); if (Directory.Exists(d)) Directory.Delete(d, true); } catch { }
        }
    }

    /// <summary>Signing in again lifts the sign-out tombstone.</summary>
    public void Revive(string accountID) { lock (_lock) _wiped.Remove(accountID); }

    /// <summary>Removes listing folders of accounts that no longer exist (Cirrus' own cache).</summary>
    public void PruneAccounts(IEnumerable<string> keepAccountIDs)
    {
        var keep = keepAccountIDs.Select(Hash).ToHashSet();
        lock (_lock)
        {
            try
            {
                foreach (var d in Directory.EnumerateDirectories(Paths.CacheDir("listings")))
                    if (!keep.Contains(Path.GetFileName(d))) { try { Directory.Delete(d, true); } catch { } }
            }
            catch { }
        }
    }
}
