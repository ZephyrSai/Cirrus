using System.Net;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core.Tests;

/// <summary>Regression tests for the second safety audit (caching, retries, privacy).</summary>
public class SecondAuditTests
{
    sealed class Scripted(Func<HttpRequestMessage, int, Task<HttpResponseMessage>> reply) : HttpMessageHandler
    {
        public int Calls;
        public readonly List<string?> Cookies = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            var n = Interlocked.Increment(ref Calls);
            lock (Cookies) Cookies.Add(req.Headers.TryGetValues("Cookie", out var c) ? c.Single() : null);
            return reply(req, n);
        }
    }

    static SessionState State() => new("x@example.com")
    {
        AccountInfoData = Encoding.UTF8.GetBytes("{\"webservices\":{\"drivews\":{\"url\":\"https://p01-drivews.icloud.com\"}}}"),
        Cookies = [new StoredCookie { Name = "X-APPLE-WEBAUTH-USER", Value = "secret-cookie" }],
    };

    static HttpResponseMessage Ok(string body = "{}") => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    [Fact]
    public async Task UploadsAreNeverRepeatedOnceTheyMayHaveReachedTheServer()
    {
        var file = Path.Combine(TestEnv.TempDir("up"), "a.jpg");
        File.WriteAllText(file, "photo");
        // The connection drops after sending: the server may have the photo, so no second upload.
        var dropped = new Scripted((_, _) => throw new HttpRequestException(HttpRequestError.ResponseEnded, "ended"));
        var s1 = new ICloudSession(State(), dropped) { Delay = (_, _) => Task.CompletedTask };
        await Assert.ThrowsAsync<HttpRequestException>(() => s1.UploadAsync("https://p01-uploadimagews.icloud.com/upload", null, file, null, "application/octet-stream", null));
        Assert.Equal(1, dropped.Calls);
        // A name lookup failure happens before anything is sent: safe to try again.
        var dns = new Scripted((_, n) => n == 1 ? throw new HttpRequestException(HttpRequestError.NameResolutionError, "dns") : Task.FromResult(Ok()));
        var s2 = new ICloudSession(State(), dns) { Delay = (_, _) => Task.CompletedTask };
        await s2.UploadAsync("https://p01-uploadimagews.icloud.com/upload", null, file, null, "application/octet-stream", null);
        Assert.Equal(2, dns.Calls);
    }

    [Fact]
    public async Task ServerErrorsRepeatOnlyIdempotentCalls()
    {
        var busy = new Scripted((_, n) => Task.FromResult(n == 1 ? new HttpResponseMessage(HttpStatusCode.BadGateway) : Ok()));
        var s = new ICloudSession(State(), busy) { Delay = (_, _) => Task.CompletedTask };
        var e = await Assert.ThrowsAsync<ICloudException>(() => s.RequestAsync("https://p01-drivews.icloud.com/moveItems", json: new JsonObject(), idempotent: false));
        Assert.Equal(502, e.StatusCode);
        Assert.Equal(1, busy.Calls);
        // 429 = "not processed, slow down": safe even for a change.
        var limited = new Scripted((_, n) => Task.FromResult(n == 1 ? new HttpResponseMessage((HttpStatusCode)429) : Ok()));
        var s2 = new ICloudSession(State(), limited) { Delay = (_, _) => Task.CompletedTask };
        await s2.RequestAsync("https://p01-drivews.icloud.com/moveItems", json: new JsonObject(), idempotent: false);
        Assert.Equal(2, limited.Calls);
        // Listings are repeated after a 502.
        var list = new Scripted((_, n) => Task.FromResult(n == 1 ? new HttpResponseMessage(HttpStatusCode.BadGateway) : Ok("[]")));
        var s3 = new ICloudSession(State(), list) { Delay = (_, _) => Task.CompletedTask };
        await s3.RequestAsync("https://p01-drivews.icloud.com/retrieveItemDetailsInFolders", json: new JsonArray(), idempotent: true);
        Assert.Equal(2, list.Calls);
    }

    [Fact]
    public async Task CookiesGoOnlyToAppleHosts()
    {
        var host = new Scripted((req, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1]) }));
        var s = new ICloudSession(State(), host);
        var dir = TestEnv.TempDir("cookies");
        await s.DownloadAsync("https://cvws.icloud-content.com/B/x/file", Path.Combine(dir, "a"), null, null);
        await s.DownloadAsync("https://downloads.example.net/x", Path.Combine(dir, "b"), null, null);
        Assert.Contains("secret-cookie", host.Cookies[0]);
        Assert.Null(host.Cookies[1]);
    }

    sealed class ChangingPhotos(ListingCache cache, List<PhotoAsset> assets) : IPhotosBackend
    {
        public string Token = "t0";
        public Action? DuringListing;
        public PhotoCapabilities Capabilities => PhotoCapabilities.None;
        public string CacheKey => "changing";
        public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("lib", "Lib", false) });
        public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult(new List<PhotoAlbum>());
        public Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
        {
            DuringListing?.Invoke();       // something changes while the listing runs…
            Token = "t9";                  // …and the library's newest token moves on
            return Task.FromResult(assets.Select(a => a.Copy()).ToList());
        }
        public string? SyncToken(PhotoLibraryRef library) => Token;
        public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult((token != "t9", (string?)"t9"));
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

    [Fact]
    public async Task AlbumCacheUsesTheTokenFromBeforeTheListingAndKeepsEditsMadeMeanwhile()
    {
        var cache = new ListingCache();
        var acct = "web:" + Guid.NewGuid().ToString("N")[..6];
        var assets = Enumerable.Range(0, 3).Select(i => new PhotoAsset { Id = "A" + i, Library = "lib", Filename = $"{i}.jpg" }).ToList();
        var photos = new ChangingPhotos(cache, assets);
        // The user deletes A1 from the partly loaded grid while the listing is still running.
        photos.DuringListing = () => cache.PatchPhotos(acct, "lib", [], new HashSet<string> { "A1" });
        var lib = new PhotoLibraryRef("lib", "Lib", false);
        var album = new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart);
        var result = await cache.ListAlbumAsync(photos, acct, lib, album, false, true, null);
        Assert.Equal(["A0", "A2"], result.Select(a => a.Id).ToList());     // the edit made meanwhile is kept
        var saved = cache.LoadAlbum(acct, "lib", album.Id)!;
        Assert.Equal("t0", saved.Token);                                   // not the newer token seen during the listing
        Assert.DoesNotContain(saved.Assets, a => a.Id == "A1");
    }

    [Fact]
    public async Task JobsNeverFallBackToAnotherPhotosLibrary()
    {
        var previous = AccountManager.Shared;
        var am = new AccountManager(new MemorySecretStore(), null) { DemoMode = true };
        am.Load();
        AccountManager.Shared = am;
        try
        {
            var job = new SyncJob("Export shared", JobKind.PhotosExport, SyncEndpoint.Photos("demo", "SharedSync-ABC", null, null),
                SyncEndpoint.Local(TestEnv.TempDir("shared-export")));
            var e = await Assert.ThrowsAsync<SyncException>(() => JobEngine.Shared.PreviewAsync(job, null));
            Assert.Contains("isn’t available", e.Message);
        }
        finally { AccountManager.Shared = previous; }
    }

    [Fact]
    public void ProfileNamesCantRedirectTheDataFolder()
    {
        var was = Environment.GetEnvironmentVariable("CIRRUS_PROFILE");
        try
        {
            Environment.SetEnvironmentVariable("CIRRUS_PROFILE", Path.Combine("x", "..", "..", "Documents"));
            Assert.Equal("Cirrus", Path.GetFileName(Paths.AppSupport));
            Environment.SetEnvironmentVariable("CIRRUS_PROFILE", "work_2");
            Assert.Equal("Cirrus-work_2", Path.GetFileName(Paths.AppSupport));
        }
        finally { Environment.SetEnvironmentVariable("CIRRUS_PROFILE", was); }
    }

    [Fact]
    public void OpenedCopiesAgeByTheirNewestEditAndPerAccount()
    {
        var acctDir = Paths.AccountCacheDir("open", "web:age-test");
        var edited = Path.Combine(acctDir, "doc1");
        TestEnv.Write("saved today", Path.Combine(edited, "Report.docx"));
        Directory.SetLastWriteTimeUtc(edited, DateTime.UtcNow.AddDays(-30));   // folder is old, but the file was just saved
        var old = Path.Combine(acctDir, "doc2");
        TestEnv.Write("old", Path.Combine(old, "Old.docx"));
        File.SetLastWriteTimeUtc(Path.Combine(old, "Old.docx"), DateTime.UtcNow.AddDays(-30));
        Directory.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-30));
        Paths.CleanCaches();
        Assert.True(File.Exists(Path.Combine(edited, "Report.docx")));
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(acctDir));   // the account folder itself stays
    }
}
