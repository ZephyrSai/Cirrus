using System.Net;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core.Tests;

/// <summary>Tests for the Mac parity round: downloads, caching, privacy and network robustness.</summary>
public class ParityTests
{
    // MARK: Downloads

    /// <summary>Content host: the body is the first path component, after a random delay.</summary>
    sealed class ContentHost : HttpMessageHandler
    {
        public int FailFirstGets;
        public int Calls;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            Interlocked.Increment(ref Calls);
            if (req.Method == HttpMethod.Get && Interlocked.Decrement(ref FailFirstGets) >= 0)
                throw new HttpRequestException(HttpRequestError.ConnectionError, "The network connection was lost.");
            await Task.Delay(Random.Shared.Next(1, 40), ct);
            var name = req.RequestUri!.AbsolutePath.Trim('/').Split('/')[0];
            if (req.RequestUri.Host == "p01-drivews.icloud.com")
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("[]", Encoding.UTF8, "application/json") };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Encoding.UTF8.GetBytes(name)) };
        }
    }

    [Fact]
    public async Task ConcurrentDownloadsNeverCross()
    {
        // Regression (Mac 13d0d66): 24 downloads started at once must each get their own bytes.
        var session = new ICloudSession(new SessionState("x@example.com"), new ContentHost());
        var dir = TestEnv.TempDir("dl-cross");
        await Task.WhenAll(Enumerable.Range(0, 24).Select(async i =>
        {
            var dest = Path.Combine(dir, $"dl-{Guid.NewGuid():N}");
            await session.DownloadAsync($"https://cvws.example.com/item{i}/${{f}}?k={i}", dest, null, null);
            Assert.Equal($"item{i}", File.ReadAllText(dest));
        }));
        Assert.Empty(Directory.GetFiles(dir, ".cirrus-dl-*"));
    }

    [Fact]
    public async Task SafeCallsRetryDroppedConnectionsAndUnsafeOnesDont()
    {
        var host = new ContentHost { FailFirstGets = 1 };
        var state = new SessionState("x@example.com")
        {
            AccountInfoData = Encoding.UTF8.GetBytes("{\"webservices\":{\"drivews\":{\"url\":\"https://p01-drivews.icloud.com\"}}}"),
            Cookies = [new StoredCookie { Name = "X-APPLE-WEBAUTH-USER", Value = "x" }],
        };
        var session = new ICloudSession(state, host) { Delay = (_, _) => Task.CompletedTask };
        // Idempotent listing (POST marked idempotent): a dropped connection is retried.
        await session.RequestAsync("https://p01-drivews.icloud.com/retrieveItemDetailsInFolders", json: new JsonArray(), idempotent: true);
        // GET downloads retry too.
        host.FailFirstGets = 1;
        var dest = Path.Combine(TestEnv.TempDir("retry"), "a");
        await session.DownloadAsync("https://cvws.example.com/body/file", dest, null, null);
        Assert.Equal("body", File.ReadAllText(dest));
        // A non-idempotent change is never sent twice.
        var once = new OnceFails();
        var s2 = new ICloudSession(state, once) { Delay = (_, _) => Task.CompletedTask };
        await Assert.ThrowsAsync<HttpRequestException>(() => s2.RequestAsync("https://p01-drivews.icloud.com/moveItems", json: new JsonObject(), idempotent: false));
        Assert.Equal(1, once.Calls);
    }

    sealed class OnceFails : HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Calls++;
            throw new HttpRequestException(HttpRequestError.ConnectionError, "The network connection was lost.");
        }
    }

    // MARK: Caching

    sealed class CountingPhotos(List<PhotoAsset> assets) : IPhotosBackend
    {
        public int Listings, Checks;
        public bool ChangedSinceToken;
        public string Token = "t1";
        public PhotoCapabilities Capabilities => PhotoCapabilities.None;
        public string CacheKey => "counting";
        public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("lib", "Lib", false) });
        public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult(new List<PhotoAlbum>());
        public Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
        {
            Listings++;
            page?.Invoke(assets.Take(1).ToList(), assets.Count);
            return Task.FromResult(assets.Select(a => a.Copy()).ToList());
        }
        public string? SyncToken(PhotoLibraryRef library) => Token;
        public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default)
        {
            Checks++;
            return Task.FromResult((ChangedSinceToken, (string?)Token));
        }
        public Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);
        public Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> a, bool value, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> a, bool value, CancellationToken ct = default) => throw new NotSupportedException();
        public Task DeleteAsync(IReadOnlyList<PhotoAsset> a, CancellationToken ct = default) => throw new NotSupportedException();
        public Task RestoreAsync(IReadOnlyList<PhotoAsset> a, CancellationToken ct = default) => throw new NotSupportedException();
        public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task AddAsync(IReadOnlyList<PhotoAsset> a, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default) => throw new NotSupportedException();
    }

    static List<PhotoAsset> Assets(int n) => Enumerable.Range(0, n).Select(i => new PhotoAsset { Id = "A" + i, Library = "lib", Filename = $"IMG_{i}.JPG", Size = 10 }).ToList();

    [Fact]
    public async Task AlbumCacheServesFreshListingsAndChecksTheSyncTokenWhenOlder()
    {
        var cache = new ListingCache();
        var now = DateTimeOffset.UtcNow;
        cache.Clock = () => now;
        var photos = new CountingPhotos(Assets(5));
        var lib = new PhotoLibraryRef("lib", "Lib", false);
        var album = new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart);
        var acct = "web:" + Guid.NewGuid().ToString("N")[..6];
        var pages = 0;
        // 1) No cache: listed from the server, pages streamed.
        Assert.Equal(5, (await cache.ListAlbumAsync(photos, acct, lib, album, false, true, _ => pages++)).Count);
        Assert.Equal((1, 1), (photos.Listings, pages));
        // 2) Within 300 s: no network at all.
        now = now.AddSeconds(200);
        Assert.Equal(5, (await cache.ListAlbumAsync(photos, acct, lib, album, false, true, null)).Count);
        Assert.Equal((1, 0), (photos.Listings, photos.Checks));
        // 3) Older, nothing changed in CloudKit: one cheap change check, cache kept.
        now = now.AddSeconds(400);
        var shownFromCache = 0;
        Assert.Equal(5, (await cache.ListAlbumAsync(photos, acct, lib, album, false, true, p => shownFromCache = p.Count)).Count);
        Assert.Equal((1, 1, 5), (photos.Listings, photos.Checks, shownFromCache));
        // …and that check renewed the cache.
        now = now.AddSeconds(100);
        await cache.ListAlbumAsync(photos, acct, lib, album, false, true, null);
        Assert.Equal((1, 1), (photos.Listings, photos.Checks));
        // 4) Older and changed: listed again.
        now = now.AddSeconds(400);
        photos.ChangedSinceToken = true;
        await cache.ListAlbumAsync(photos, acct, lib, album, false, true, null);
        Assert.Equal((2, 2), (photos.Listings, photos.Checks));
        // 5) F5 forces the server even when the cache is brand new.
        await cache.ListAlbumAsync(photos, acct, lib, album, forced: true, useDisk: true, null);
        Assert.Equal(3, photos.Listings);
        // Demo/local accounts don't use the disk cache.
        await cache.ListAlbumAsync(photos, "demo", lib, album, false, false, null);
        await cache.ListAlbumAsync(photos, "demo", lib, album, false, false, null);
        Assert.Equal(5, photos.Listings);
    }

    [Fact]
    public async Task PhotoEditsPatchCachedAlbumsInPlace()
    {
        var cache = new ListingCache();
        var photos = new CountingPhotos(Assets(4));
        var lib = new PhotoLibraryRef("lib", "Lib", false);
        var acct = "web:" + Guid.NewGuid().ToString("N")[..6];
        var all = new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart);
        var favs = new PhotoAlbum("smart:Favorites", "Favorites", PhotoAlbumKind.Smart);
        await cache.ListAlbumAsync(photos, acct, lib, all, false, true, null);
        await cache.ListAlbumAsync(photos, acct, lib, favs, false, true, null);
        var fav = Assets(4)[1]; fav.IsFavorite = true;
        cache.PatchPhotos(acct, "lib", [fav], new HashSet<string> { "A3" });
        var patched = await cache.ListAlbumAsync(photos, acct, lib, all, false, true, null);
        Assert.Equal(2, photos.Listings);                                  // served from the patched cache
        Assert.Equal(["A0", "A1", "A2"], patched.Select(a => a.Id).ToList());
        Assert.True(patched.Single(a => a.Id == "A1").IsFavorite);
        await cache.ListAlbumAsync(photos, acct, lib, favs, false, true, null);
        Assert.Equal(3, photos.Listings);                                  // Favorites is re-listed, not patched
    }

    [Fact]
    public void DriveAndListCachesRoundTripAndSignOutWipesThem()
    {
        var cache = new ListingCache();
        var now = DateTimeOffset.UtcNow;
        cache.Clock = () => now;
        var acct = "web:" + Guid.NewGuid().ToString("N")[..6];
        cache.SaveDrive(acct, "FOLDER::z::root", [new DriveNode { Id = "FILE::z::1", Name = "Tax return 2025.pdf", Size = 7 }]);
        Assert.Equal("Tax return 2025.pdf", cache.LoadDrive(acct, "FOLDER::z::root")!.Nodes.Single().Name);
        cache.SaveList(acct, "albums|lib", new List<PhotoAlbum> { new("album:x", "Holiday", PhotoAlbumKind.Album) });
        Assert.True(cache.LoadList<PhotoAlbum>(acct, "albums|lib", ListingCache.AlbumListMaxAge).Fresh);
        now = now.AddMinutes(11);
        var (items, fresh) = cache.LoadList<PhotoAlbum>(acct, "albums|lib", ListingCache.AlbumListMaxAge);
        Assert.False(fresh);
        Assert.Single(items!);
        // No account names, album names or file names in the cache's file names.
        foreach (var f in Directory.EnumerateFileSystemEntries(Paths.CacheDir("listings"), "*", SearchOption.AllDirectories))
        {
            Assert.DoesNotContain("web", Path.GetFileName(f));
            Assert.DoesNotContain("Holiday", Path.GetFileName(f));
        }
        cache.WipeAccount(acct);
        Assert.Null(cache.LoadDrive(acct, "FOLDER::z::root"));
    }

    [Fact]
    public void ThumbnailCacheIsVersionedHashedAndPruned()
    {
        ThumbnailDiskCache.Write([1, 2, 3], "web-acct", "PHOTO-RECORD-1", 360);
        var p = ThumbnailDiskCache.PathFor("web-acct", "PHOTO-RECORD-1", 360);
        Assert.DoesNotContain("PHOTO", p);
        Assert.Equal([1, 2, 3], ThumbnailDiskCache.Read("web-acct", "PHOTO-RECORD-1", 360));
        var stale = Path.Combine(Paths.CacheDir("thumbs"), "17");     // a v1-era bucket folder
        Directory.CreateDirectory(stale);
        File.WriteAllBytes(Path.Combine(stale, "web-acct_PHOTO-360.jpg"), [9]);
        ThumbnailDiskCache.PruneOldVersions(["web-acct"]);
        Assert.False(Directory.Exists(stale));
        Assert.NotNull(ThumbnailDiskCache.Read("web-acct", "PHOTO-RECORD-1", 360));
        ThumbnailDiskCache.PruneOldVersions([]);                        // the account is gone
        Assert.Null(ThumbnailDiskCache.Read("web-acct", "PHOTO-RECORD-1", 360));
    }

    // MARK: Privacy

    [Fact]
    public void LogFileKeepsOnlyContentFreeStatusLines()
    {
        var marker = "Secret Plans " + Guid.NewGuid().ToString("N")[..6] + ".docx";
        Log.Info("uploaded " + marker);
        Log.Error("couldn’t copy " + marker);
        Log.Status("http POST p01-drivews.icloud.com/moveItems → 409");
        var text = File.ReadAllText(Log.FilePath);
        Assert.DoesNotContain(marker, text);
        Assert.Contains("moveItems → 409", text);
    }

    [Fact]
    public void CachesAreOwnerOnly()
    {
        if (OperatingSystem.IsWindows()) return;   // ACL variant needs Windows
        var mode = File.GetUnixFileMode(Paths.AppSupport);
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, mode);
    }

    [Fact]
    public void CacheCleanupAgesOutScratchAndRecyclesOpenedCopies()
    {
        var preview = Path.Combine(Paths.CacheDir("preview"), "old-preview.png");
        var fresh = Path.Combine(Paths.CacheDir("preview"), "new-preview.png");
        var opened = Path.Combine(Paths.CacheDir("open"), "k1");
        var openedRecent = Path.Combine(Paths.CacheDir("open"), "k2");
        File.WriteAllText(preview, "p"); File.WriteAllText(fresh, "p");
        TestEnv.Write("edited by the user", Path.Combine(opened, "Report.docx"));
        TestEnv.Write("x", Path.Combine(openedRecent, "Notes.txt"));
        File.SetLastWriteTimeUtc(preview, DateTime.UtcNow.AddDays(-2));
        File.SetLastWriteTimeUtc(Path.Combine(opened, "Report.docx"), DateTime.UtcNow.AddDays(-20));
        Directory.SetLastWriteTimeUtc(opened, DateTime.UtcNow.AddDays(-20));
        Directory.SetLastWriteTimeUtc(openedRecent, DateTime.UtcNow.AddDays(-3));
        Paths.CleanCaches();
        Assert.False(File.Exists(preview));
        Assert.True(File.Exists(fresh));
        Assert.False(Directory.Exists(opened));
        Assert.True(Directory.Exists(openedRecent));                    // opened copies live two weeks
        // The old opened copy wasn't deleted: it went to the Recycle Bin (here: moved aside).
        Assert.Single(Directory.GetFiles(Path.Combine(Paths.CacheDir("open"), ".cirrus", "Removed"), "Report.docx", SearchOption.AllDirectories));
    }

    [Fact]
    public void SignOutWipesTheAccountsCaches()
    {
        var am = new AccountManager(new MemorySecretStore(), null);
        var id = $"wipe{Guid.NewGuid():N}"[..12] + "@example.com";
        var acct = am.FinishSignIn(id, new ICloudSession(new SessionState(id)), null);
        ListingCache.Shared.SaveDrive(acct.Id, "root", [new DriveNode { Id = "x", Name = "a" }]);
        ThumbnailDiskCache.Write([1], acct.Photos!.CacheKey, "p1", 360);
        var preview = Paths.AccountCacheDir("preview", acct.Id);
        Directory.CreateDirectory(preview);
        File.WriteAllText(Path.Combine(preview, "p.png"), "x");
        var otherPreview = Paths.AccountCacheDir("preview", "web:someone-else@example.com");
        Directory.CreateDirectory(otherPreview);
        File.WriteAllText(Path.Combine(otherPreview, "q.png"), "x");
        am.SignOut(acct);
        Assert.Null(ListingCache.Shared.LoadDrive(acct.Id, "root"));
        Assert.Null(ThumbnailDiskCache.Read(acct.Photos.CacheKey, "p1", 360));
        Assert.False(File.Exists(Path.Combine(preview, "p.png")));
        Assert.True(File.Exists(Path.Combine(otherPreview, "q.png")));     // other accounts' copies are left alone
        Assert.Empty(am.WebAccounts);
    }

    [Fact]
    public void ReleaseLockDownIgnoresAutomationSwitches()
    {
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", TestEnv.Root);
        Environment.SetEnvironmentVariable("CIRRUS_DEMO", "1");
        try
        {
            Assert.Equal(TestEnv.Root, Env.Get("CIRRUS_NATIVE_DRIVE"));
            Env.LockDown();
            Assert.Null(Env.Get("CIRRUS_NATIVE_DRIVE"));
            Assert.Null(Env.Get("CIRRUS_DATA_DIR"));
            Assert.Null(Env.Get("CIRRUS_DEBUG"));
            Assert.True(Env.Flag("CIRRUS_DEMO"));                         // user-facing demo mode still works
            Assert.False(SafetyPolicy.IsICloudPath(TestEnv.Root));
        }
        finally
        {
            Env.UnlockForTests();
            Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", null);
            Environment.SetEnvironmentVariable("CIRRUS_DEMO", null);
        }
    }

    // MARK: Photos discovery

    sealed class SlowShared : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            var path = req.RequestUri!.AbsolutePath;
            if (path.Contains("/shared/")) await Task.Delay(TimeSpan.FromSeconds(30), ct);   // shared database hangs
            var body = path.Contains("changes/database")
                ? "{\"zones\":[{\"zoneID\":{\"zoneName\":\"PrimarySync\"}}]}"
                : path.Contains("changes/zone") ? "{\"zones\":[{\"syncToken\":\"t2\",\"records\":[],\"moreComing\":false}]}" : "{}";
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }

    [Fact]
    public async Task SharedLibraryLookupCantStallDiscoveryAndChangeChecksWork()
    {
        var state = new SessionState("x@example.com")
        {
            AccountInfoData = Encoding.UTF8.GetBytes("{\"webservices\":{\"ckdatabasews\":{\"url\":\"https://p01-ckdatabasews.icloud.com\"}}}"),
            Cookies = [new StoredCookie { Name = "X-APPLE-WEBAUTH-USER", Value = "x" }],
        };
        var photos = new WebPhotos(new ICloudSession(state, new SlowShared()), "x@example.com") { SharedZoneTimeout = TimeSpan.FromMilliseconds(300) };
        var started = DateTimeOffset.UtcNow;
        var libs = await photos.LibrariesAsync();
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(5));
        Assert.Equal("PrimarySync", Assert.Single(libs).Id);
        var (changed, token) = await photos.HasChangesAsync("t1", libs[0]);
        Assert.False(changed);
        Assert.Equal("t2", token);
        Assert.Equal("t2", photos.SyncToken(libs[0]));
    }
}
