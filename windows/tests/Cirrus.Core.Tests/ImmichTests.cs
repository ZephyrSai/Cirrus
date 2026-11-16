using System.Text.Json.Nodes;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>The Immich connector against FakeImmichServer (port of ImmichTests.swift; each test has its own fake).</summary>
public class ImmichTests
{
    const string Key = FakeImmichServer.TestAPIKey;
    static PhotoLibraryRef Lib => ImmichPhotos.Library;

    static (FakeImmichServer Fake, ImmichPhotos Photos) Backend(FakeImmichServer.State? s = null, string key = Key, Dictionary<string, string>? options = null)
    {
        var fake = new FakeImmichServer(s ?? FakeImmichServer.State.Seeded());
        var r = new CloudAccountRecord(CloudProvider.Immich, "alex@example.com (photos.example.com)", "https://photos.example.com", "alex@example.com", options,
            id: "cloud:immich:test-" + Guid.NewGuid().ToString("N")[..8]);
        var b = Assert.IsType<ImmichPhotos>(ImmichCloud.Make(r, new CloudSecret { Password = key }, fake));
        b.Client.RetryBase = 0.001;
        return (fake, b);
    }

    static async Task<CloudException> Fails(Func<Task> op) => await Assert.ThrowsAsync<CloudException>(op);

    static async Task<PhotoAlbum> Album(ImmichPhotos b, string id) =>
        (await b.AlbumsAsync(Lib)).FirstOrDefault(a => a.Id == id) ?? throw new Xunit.Sdk.XunitException("no album " + id);

    static async Task<List<PhotoAsset>> List(ImmichPhotos b, string id) => await b.AssetsAsync(await Album(b, id), Lib, null);

    static async Task<PhotoAsset> AssetIn(ImmichPhotos b, string albumID, string name) =>
        (await List(b, albumID)).FirstOrDefault(a => a.Filename == name) ?? throw new Xunit.Sdk.XunitException("no asset " + name);

    /// <summary>What All Photos should hold: the user's own timeline photos, newest first.</summary>
    static List<string> ExpectedTimeline(FakeImmichServer.State s) =>
        s.Assets.Values.Where(a => a.OwnerID == s.Me.Id && a.Visibility == "timeline" && !a.IsTrashed)
            .OrderByDescending(a => a.FileCreatedAt).ThenByDescending(a => a.Id, StringComparer.Ordinal).Select(a => a.Id).ToList();

    static string PhotoFile(string name, int seed, DateTimeOffset date, string dir)
    {
        var path = Path.Combine(dir, name);
        File.WriteAllBytes(path, DemoArt.Png(160, 120, seed % 100 / 100.0, "P" + seed));
        File.SetLastWriteTimeUtc(path, date.UtcDateTime);
        try { File.SetCreationTimeUtc(path, date.UtcDateTime); } catch { }
        return path;
    }

    static (int W, int H) PngSize(byte[] d)
    {
        Assert.True(d.Length > 24 && d[0] == 0x89 && d[1] == 'P', "a PNG");
        return ((d[16] << 24) | (d[17] << 16) | (d[18] << 8) | d[19], (d[20] << 24) | (d[21] << 16) | (d[22] << 8) | d[23]);
    }

    sealed class ProgressLog
    {
        readonly List<(long Done, long Total)> _values = [];
        public void Note(long a, long b) { lock (_values) _values.Add((a, b)); }
        public (long Done, long Total)? Last { get { lock (_values) return _values.Count == 0 ? null : _values[^1]; } }
    }

    // MARK: Server address

    [Fact]
    public void ServerAddressesAreNormalized()
    {
        string Norm(string s) => ImmichCloud.ServerString(ImmichCloud.ServerURL(s));
        Assert.Equal("https://photos.example.com", Norm("photos.example.com"));
        Assert.Equal("https://photos.example.com", Norm("  https://Photos.Example.com/api/ "));
        Assert.Equal("https://photos.example.com", Norm("https://photos.example.com/api/api"));
        Assert.Equal("https://photos.example.com:8443", Norm("HTTPS://photos.example.com:8443/photos/abc?x=1#y"));
        Assert.Equal("https://example.com/immich", Norm("https://example.com/immich/albums"));
        Assert.Equal("https://photos.example.com", Norm("https://user:pw@photos.example.com"));
        // No scheme on the local network: Immich's own port serves plain http.
        Assert.Equal("http://192.168.1.20:2283", Norm("192.168.1.20:2283"));
        Assert.Equal("http://immich.local:2283", Norm("immich.local:2283/api"));
        Assert.Equal("https://192.168.1.20", Norm("https://192.168.1.20"));
        Assert.Equal(CloudErrorKind.NotConfigured, Assert.Throws<CloudException>(() => ImmichCloud.ServerURL("")).Kind);
        Assert.Equal(CloudErrorKind.Unsupported, Assert.Throws<CloudException>(() => ImmichCloud.ServerURL("ftp://photos.example.com")).Kind);
    }

    [Fact]
    public void PlainHttpOnlyOnTheLocalNetwork()
    {
        foreach (var ok in new[] { "http://192.168.1.20:2283", "http://10.0.0.5", "http://172.16.0.9", "http://172.31.255.1", "http://127.0.0.1:2283",
                     "http://localhost:2283", "http://immich.local", "http://nas:2283", "http://[fd12:3456::1]:2283", "http://[::1]", "http://169.254.10.2" })
            ImmichCloud.ServerURL(ok);
        foreach (var bad in new[] { "http://photos.example.com", "http://172.32.0.1", "http://8.8.8.8", "http://192.169.1.1", "http://100.64.0.1",
                     "http://[2001:db8::1]", "http://11.0.0.1" })
        {
            var e = Assert.Throws<CloudException>(() => ImmichCloud.ServerURL(bad));
            Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
            Assert.Contains("https://", e.Message);
        }
        Assert.Equal("http://[fd12:3456::1]:2283", ImmichCloud.ServerString(ImmichCloud.ServerURL("http://[fd12:3456::1]:2283/api")));
        Assert.Equal("http://[fd12::5]:2283", ImmichCloud.ServerString(ImmichCloud.ServerURL("[fd12::5]:2283")));
        Assert.True(ImmichCloud.IsLocalNetwork("192.168.0.1"));
        Assert.False(ImmichCloud.IsLocalNetwork("192.168.0.256"));
        Assert.False(ImmichCloud.IsLocalNetwork("photos.example.com"));
        Assert.True(ImmichCloud.IsLocalNetwork("[FE80::1]"));
    }

    // MARK: Connect

    [Fact]
    public async Task ConnectChecksServerVersionAndKey()
    {
        var fake = new FakeImmichServer(FakeImmichServer.State.Seeded());
        var (record, secret) = await ImmichCloud.ConnectAsync("photos.example.com/api/", " " + Key + "\n", fake);
        Assert.Equal(CloudProvider.Immich, record.Provider);
        Assert.StartsWith("cloud:immich:", record.Id);
        Assert.Equal("alex@example.com (photos.example.com)", record.Title);
        Assert.Equal("alex@example.com", record.Username);
        Assert.Equal("https://photos.example.com", record.Server);
        Assert.Equal("all", record.Option("permissions"));
        Assert.Equal("3.4.1", record.Option("version"));
        Assert.Equal(new CloudSecret { Password = Key }, secret);
        var s = fake.S;
        Assert.Equal(["GET /server/ping", "GET /server/version", "GET /users/me"], s.Calls.Take(3));
        Assert.DoesNotContain("/server/ping", s.KeyedPaths);   // the key isn't sent before the server is known to be Immich
        Assert.Contains("/users/me", s.KeyedPaths);
        Assert.StartsWith("Cirrus", s.LastUserAgent);
        // The saved account works through the app's factory.
        var before = CloudBackends.Transport;
        CloudBackends.Transport = fake;
        try { Assert.IsType<ImmichPhotos>(CloudBackends.MakePhotos(record, secret)); }
        finally { CloudBackends.Transport = before; }
    }

    [Fact]
    public async Task ConnectOnTheLocalNetwork()
    {
        var fake = new FakeImmichServer(FakeImmichServer.State.Seeded());
        var lan = await ImmichCloud.ConnectAsync("192.168.1.20:2283", Key, fake);
        Assert.Equal("http://192.168.1.20:2283", lan.Record.Server);
        Assert.Equal("alex@example.com (192.168.1.20:2283)", lan.Record.Title);
        var local = await ImmichCloud.ConnectAsync("immich.local", Key, fake);
        Assert.Equal("http://immich.local", local.Record.Server);
        var e = await Fails(() => ImmichCloud.ConnectAsync("http://photos.example.com", Key, fake));
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
    }

    [Fact]
    public async Task ConnectRefusesBadKeysOldServersAndOtherSites()
    {
        var fake = new FakeImmichServer(FakeImmichServer.State.Seeded());
        var e = await Fails(() => ImmichCloud.ConnectAsync("photos.example.com", "wrong-key", fake));
        Assert.Equal(CloudErrorKind.Denied, e.Kind);
        Assert.Equal(ImmichCloud.BadKeyMessage, e.Message);
        e = await Fails(() => ImmichCloud.ConnectAsync("photos.example.com", "   ", fake));
        Assert.Equal(CloudErrorKind.NotConfigured, e.Kind);

        fake.Update(s => s.Version = new ImmichVersion(2, 7, 5));
        e = await Fails(() => ImmichCloud.ConnectAsync("photos.example.com", Key, fake));
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
        Assert.Contains("2.7.5", e.Message);
        Assert.Contains("3.0", e.Message);

        fake.Reset(FakeImmichServer.State.Seeded());
        e = await Fails(() => ImmichCloud.ConnectAsync("www.example.com", Key, fake));
        Assert.Equal(CloudErrorKind.NotConfigured, e.Kind);
        Assert.Contains("no Immich server", e.Message);
        Assert.Empty(fake.S.KeyedPaths);   // no key sent to a server that isn't Immich

        e = await Fails(() => ImmichCloud.ConnectAsync("old.example.com", Key, fake));
        Assert.Equal(CloudErrorKind.NotConfigured, e.Kind);
        Assert.Contains("like https://photos.example.com.", e.Message);
        Assert.Empty(fake.S.KeyedPaths);
    }

    [Fact]
    public async Task ConnectChecksTheKeysPermissions()
    {
        var s = FakeImmichServer.State.Seeded();
        s.ApiKeys["limited"] = ["user.read", "asset.read"];
        s.ApiKeys["readonly"] = [.. ImmichCloud.ReadPermissions];
        var fake = new FakeImmichServer(s);
        var e = await Fails(() => ImmichCloud.ConnectAsync("photos.example.com", "limited", fake));
        Assert.Equal(CloudErrorKind.Denied, e.Kind);
        Assert.Contains("album.read", e.Message);
        Assert.Contains("asset.view", e.Message);
        Assert.DoesNotContain("user.read", e.Message);

        var (record, secret) = await ImmichCloud.ConnectAsync("photos.example.com", "readonly", fake);
        Assert.Equal(string.Join(",", ImmichCloud.ReadPermissions.Order(StringComparer.Ordinal)), record.Option("permissions"));
        var b = Assert.IsType<ImmichPhotos>(ImmichCloud.Make(record, secret, fake));
        Assert.Equal(PhotoCapabilities.Albums, b.Capabilities);
        fake.Update(st => st.ApiKeys["readonly"] = ["all"]);
        await b.LibrariesAsync();   // refreshes the permissions
        Assert.Equal(PhotoCapabilities.Favorite | PhotoCapabilities.Hide | PhotoCapabilities.Delete | PhotoCapabilities.Restore
            | PhotoCapabilities.ImportFiles | PhotoCapabilities.Albums | PhotoCapabilities.CreateAlbum, b.Capabilities);
    }

    [Fact]
    public void MakeNeedsAKeyAndAServer()
    {
        var r = new CloudAccountRecord(CloudProvider.Immich, "alex@example.com", "https://photos.example.com");
        var e = Assert.Throws<CloudException>(() => ImmichCloud.Make(r, new CloudSecret(), null));
        Assert.Equal(CloudErrorKind.SignInNeeded, e.Kind);
        Assert.Equal("Immich (alex@example.com)", e.Detail);
        var plain = r.Copy();
        plain.Server = "http://photos.example.com";
        Assert.Equal(CloudErrorKind.Unsupported, Assert.Throws<CloudException>(() => ImmichCloud.Make(plain, new CloudSecret { Password = "k" }, null)).Kind);
        var none = r.Copy();
        none.Server = null;
        Assert.Equal(CloudErrorKind.NotConfigured, Assert.Throws<CloudException>(() => ImmichCloud.Make(none, new CloudSecret { Password = "k" }, null)).Kind);
        var other = new CloudAccountRecord(CloudProvider.Nextcloud, "x");
        Assert.Equal(CloudErrorKind.Unsupported, Assert.Throws<CloudException>(() => ImmichCloud.Make(other, new CloudSecret { Password = "k" }, null)).Kind);
        Assert.Throws<CloudException>(() => CloudBackends.Make(r, new CloudSecret { Password = "k" }));
    }

    // MARK: Libraries & albums

    [Fact]
    public async Task OneLibraryWithSmartAndUserAlbums()
    {
        var (fake, b) = Backend();
        var libs = await b.LibrariesAsync();
        Assert.Single(libs);
        Assert.Equal(("immich", "Immich", false), (libs[0].Id, libs[0].Name, libs[0].IsShared));
        var albums = await b.AlbumsAsync(Lib);
        var s = fake.S;
        var own = s.Assets.Values.Where(a => a.OwnerID == s.Me.Id).ToList();
        Assert.Equal(["smart:All Photos", "smart:Favorites", "smart:Videos", "smart:Hidden", "smart:Recently Deleted"], albums.Take(5).Select(a => a.Id));
        Assert.All(albums.Take(5), a => Assert.Equal(PhotoAlbumKind.Smart, a.Kind));
        Assert.True(albums[0].IsAllPhotos && albums[4].IsDeletedBin);
        Assert.Equal(ExpectedTimeline(s).Count, albums[0].Count);
        Assert.Equal(own.Count(a => a.IsFavorite && a.Visibility == "timeline" && !a.IsTrashed), albums[1].Count);
        Assert.Equal(1, albums[2].Count);
        Assert.Equal((1, "Archive"), (albums[3].Count, albums[3].Name));
        Assert.Equal((1, "Trash"), (albums[4].Count, albums[4].Name));
        var user = albums.Skip(5).ToList();
        Assert.Equal(["Family", "Summer Trip", "Sam’s Garden"], user.Select(a => a.Name));
        var family = user.Single(a => a.Name == "Family");
        var fakeFamily = s.AlbumNamed("Family")!;
        Assert.Equal("album:" + fakeFamily.Id, family.Id);
        Assert.Equal(PhotoAlbumKind.Album, family.Kind);
        Assert.Equal("album.shared", family.Symbol);
        Assert.Equal(fakeFamily.AssetIDs.Count, family.Count);
        var garden = user.Single(a => a.Name == "Sam’s Garden");
        Assert.Equal((PhotoAlbumKind.Shared, (int?)1), (garden.Kind, garden.Count));
        // Immich has no change feed Cirrus uses: every listing asks the server.
        Assert.Null(b.SyncToken(Lib));
        Assert.Equal((true, (string?)null), await b.HasChangesAsync("x", Lib));
        Assert.StartsWith("immich-", b.CacheKey);
        Assert.DoesNotContain("test-", b.CacheKey);
    }

    [Fact]
    public async Task AllPhotosIsPagedNewestFirst()
    {
        var (fake, b) = Backend();
        b.FirstPageSize = 3;
        b.PageSize = 5;
        var all = await Album(b, "smart:All Photos");
        fake.Update(s => s.SearchBodies.Clear());
        var pages = new List<(IReadOnlyList<PhotoAsset> Batch, int? Total)>();
        var assets = await b.AssetsAsync(all, Lib, (batch, total) => pages.Add((batch, total)));
        var st = fake.S;
        Assert.Equal(ExpectedTimeline(st), assets.Select(a => a.Id));
        Assert.True(pages.Count >= 4);
        Assert.Equal(assets.Select(a => a.Id), pages.SelectMany(p => p.Batch).Select(a => a.Id));
        Assert.All(pages, p => Assert.Equal(all.Count, p.Total));
        Assert.All(assets.Zip(assets.Skip(1)), p => Assert.True(p.First.Created >= p.Second.Created));
        // The partner's photos, the archive, the trash and Live Photo motion parts stay out.
        var names = assets.Select(a => a.Filename).ToHashSet();
        foreach (var n in new[] { "PXL_3001.PNG", "PXL_3002.PNG", "IMG_1007.PNG", "IMG_1012.PNG", "IMG_1003.MOV" }) Assert.DoesNotContain(n, names);
        Assert.Contains("VID_2001.MP4", names);
        // v3.2+ request shape: structured filter, cursor paging, no deprecated fields.
        var bodies = st.SearchBodies;
        Assert.True(bodies.Count >= 4);
        Assert.Equal(3, (int)bodies[0]["size"]!);
        Assert.False(bodies[0].ContainsKey("cursor"));
        Assert.Equal(5, (int)bodies[1]["size"]!);
        Assert.NotNull((string?)bodies[1]["cursor"]);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""{"visibility":{"eq":"timeline"},"trashedAt":{"eq":null}}"""), bodies[0]["filter"]));
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""{"field":"fileCreatedAt","direction":"desc"}"""), bodies[0]["orderBy"]));
        Assert.All(bodies, x => Assert.True(!x.ContainsKey("page") && !x.ContainsKey("visibility") && (bool)x["withExif"]!));
    }

    [Fact]
    public async Task OlderServersGetTheFlatSearchFields()
    {
        var s = FakeImmichServer.State.Seeded();
        s.Version = new ImmichVersion(3, 1, 2);
        var (fake, b) = Backend(s);
        b.PageSize = 4;
        var assets = await b.AssetsAsync(await Album(b, "smart:All Photos"), Lib, null);
        Assert.Equal(ExpectedTimeline(fake.S), assets.Select(a => a.Id));
        var bodies = fake.S.SearchBodies;
        Assert.All(bodies, x => Assert.True(!x.ContainsKey("filter") && !x.ContainsKey("cursor") && (string?)x["visibility"] == "timeline"));
        Assert.Equal(Enumerable.Range(1, bodies.Count), bodies.Select(x => (int)x["page"]!));
        Assert.All(bodies, x => Assert.Equal(4, (int)x["size"]!));
        Assert.Equal(["IMG_1012.PNG"], (await List(b, "smart:Recently Deleted")).Select(a => a.Filename));
        var trip = await List(b, "album:" + fake.S.AlbumNamed("Summer Trip")!.Id);
        Assert.NotEmpty(trip);
        Assert.All(trip, a => Assert.False(a.IsDeleted));
    }

    [Fact]
    public async Task SmartAlbumsAndAlbumsHoldTheRightPhotos()
    {
        var (fake, b) = Backend();
        var s = fake.S;
        Assert.Equal(["IMG_1000.PNG", "IMG_1004.PNG", "IMG_1009.PNG"], (await List(b, "smart:Favorites")).Select(a => a.Filename).Order());
        Assert.Equal(["VID_2001.MP4"], (await List(b, "smart:Videos")).Select(a => a.Filename));
        var archived = await List(b, "smart:Hidden");
        Assert.Equal(["IMG_1007.PNG"], archived.Select(a => a.Filename));
        Assert.True(archived[0].IsHidden);
        var trashed = await List(b, "smart:Recently Deleted");
        Assert.Equal(["IMG_1012.PNG"], trashed.Select(a => a.Filename));
        Assert.True(trashed[0].IsDeleted);
        var trip = s.AlbumNamed("Summer Trip")!;
        var expected = trip.AssetIDs.Select(id => s.Assets[id]).Where(a => !a.IsTrashed).OrderByDescending(a => a.FileCreatedAt).Select(a => a.Id);
        Assert.Equal(expected, (await List(b, "album:" + trip.Id)).Select(a => a.Id));
        // An album someone shared holds their photos.
        Assert.Equal(["PXL_3001.PNG"], (await List(b, "album:" + s.AlbumNamed("Sam’s Garden")!.Id)).Select(a => a.Filename));
        // Unknown albums.
        var e = await Fails(() => b.AssetsAsync(new PhotoAlbum("smart:Nope", "x", PhotoAlbumKind.Smart), Lib, null));
        Assert.Equal(CloudErrorKind.NotFound, e.Kind);
        Assert.Empty(await b.AssetsAsync(new PhotoAlbum("folder:x", "x", PhotoAlbumKind.Folder), Lib, null));
    }

    [Fact]
    public async Task AssetFieldsLivePhotosAndVideos()
    {
        var (fake, b) = Backend();
        var s = fake.S;
        var all = await List(b, "smart:All Photos");
        var still = all.Single(a => a.Filename == "IMG_1003.PNG");
        var fakeStill = s.AssetNamed("IMG_1003.PNG")!;
        var motion = s.AssetNamed("IMG_1003.MOV")!;
        Assert.Equal((fakeStill.Id, "immich"), (still.Id, still.Library));
        Assert.True(still.IsLive && !still.IsVideo);
        var live = still.Resource(PhotoResourceKind.LiveVideo)!;
        Assert.Equal((motion.Id, "IMG_1003.MOV"), (live.RecordName, live.Filename));
        Assert.Equal(fakeStill.Data.Length, still.Size);
        Assert.Equal(still.Size, still.Resource(PhotoResourceKind.Original)!.Size);
        Assert.Equal((480, 360), (still.Width, still.Height));
        Assert.Equal("public.png", still.Uti);
        Assert.True(Math.Abs((still.Created!.Value - fakeStill.FileCreatedAt).TotalSeconds) < 0.01);
        Assert.NotNull(still.Added);
        Assert.NotNull(still.ChangeTag);
        var video = all.Single(a => a.Filename == "VID_2001.MP4");
        Assert.True(video.IsVideo && !video.IsLive);
        Assert.Equal(4.0, video.Duration);
        Assert.Equal(1920, video.Width);
        Assert.Equal("public.mpeg-4", video.Uti);
        Assert.Null(still.Duration);
        var edited = all.Single(a => a.Filename == "IMG_1009.PNG");
        Assert.True(edited.IsEdited && edited.IsFavorite);
        Assert.NotNull(edited.Resource(PhotoResourceKind.Edited));
        Assert.Contains("edited=true", edited.Resource(PhotoResourceKind.Thumbnail)!.Url);
        Assert.Equal(62.5, ImmichPhotos.Duration(new J(JsonValue.Create("0:01:02.500000"))));
        Assert.Null(ImmichPhotos.Duration(new J(JsonValue.Create(0))));
        Assert.Null(ImmichPhotos.Duration(J.Null));
        Assert.Equal(2.5, ImmichPhotos.Duration(new J(JsonValue.Create(2500))));
    }

    // MARK: Content

    [Fact]
    public async Task ThumbnailsUseServerRenditionsAndTheDiskCache()
    {
        var (fake, b) = Backend();
        var a = await AssetIn(b, "smart:All Photos", "IMG_1001.PNG");
        fake.Update(s => s.ThumbnailRequests.Clear());
        var small = await b.ThumbnailAsync(a, 256);
        var (w, h) = PngSize(small!);
        Assert.True(Math.Max(w, h) <= 256);
        Assert.Equal(["thumbnail"], fake.S.ThumbnailRequests);
        Assert.Equal(small, await b.ThumbnailAsync(a, 256));
        Assert.Equal(["thumbnail"], fake.S.ThumbnailRequests);   // second request served from the disk cache
        var big = await b.ThumbnailAsync(a, 1024);
        Assert.True(PngSize(big!).W > w);
        Assert.Equal(["thumbnail", "preview"], fake.S.ThumbnailRequests);
        // A video gets its poster frame.
        var v = await AssetIn(b, "smart:Videos", "VID_2001.MP4");
        Assert.NotNull(await b.ThumbnailAsync(v, 256));
        // A photo gone from the server has none.
        fake.Update(s => s.Assets.Remove(v.Id));
        Assert.Equal(CloudErrorKind.Denied, (await Fails(() => b.ThumbnailAsync(v, 1024))).Kind);
    }

    [Fact]
    public async Task ExportsOriginalsLiveVideosAndEditsWithTheCaptureDate()
    {
        var (fake, b) = Backend();
        var s = fake.S;
        var dir = TestEnv.TempDir("immich-export");
        var still = await AssetIn(b, "smart:All Photos", "IMG_1003.PNG");
        var p = new ProgressLog();
        var dest = Path.Combine(dir, still.Filename);
        File.WriteAllText(dest, "old");
        await b.ExportAsync(still, PhotoResourceKind.Original, dest, p.Note);
        var fakeStill = s.AssetNamed("IMG_1003.PNG")!;
        Assert.Equal(fakeStill.Data, File.ReadAllBytes(dest));
        Assert.True(Math.Abs((File.GetLastWriteTimeUtc(dest) - fakeStill.FileCreatedAt.UtcDateTime).TotalSeconds) < 1);
        Assert.Equal(fakeStill.Data.Length, p.Last!.Value.Done);
        var mov = Path.Combine(dir, "IMG_1003.MOV");
        await b.ExportAsync(still, PhotoResourceKind.LiveVideo, mov, null);
        Assert.Equal(s.AssetNamed("IMG_1003.MOV")!.Data, File.ReadAllBytes(mov));
        var edited = await AssetIn(b, "smart:All Photos", "IMG_1009.PNG");
        string e1 = Path.Combine(dir, "edited.png"), e0 = Path.Combine(dir, "orig.png");
        await b.ExportAsync(edited, PhotoResourceKind.Edited, e1, null);
        await b.ExportAsync(edited, PhotoResourceKind.Original, e0, null);
        Assert.Equal(s.AssetNamed("IMG_1009.PNG")!.EditedData, File.ReadAllBytes(e1));
        Assert.Equal(s.AssetNamed("IMG_1009.PNG")!.Data, File.ReadAllBytes(e0));
        // Downloads land next to the destination first: nothing is left behind.
        Assert.Empty(Directory.EnumerateFiles(dir, ".cirrus-dl-*"));
        // No such resource.
        var plain = await AssetIn(b, "smart:All Photos", "IMG_1001.PNG");
        var e = await Fails(() => b.ExportAsync(plain, PhotoResourceKind.LiveVideo, Path.Combine(dir, "x.mov"), null));
        Assert.Equal(CloudErrorKind.NotFound, e.Kind);
    }

    // MARK: Edits

    [Fact]
    public async Task FavoritesAndArchive()
    {
        var (fake, b) = Backend();
        var all = await List(b, "smart:All Photos");
        var two = all.Where(a => a.Filename is "IMG_1001.PNG" or "IMG_1002.PNG").ToList();
        Assert.Equal(2, two.Count);
        var fav = await b.SetFavoriteAsync(two, true);
        Assert.All(fav, a => Assert.True(a.IsFavorite));
        Assert.Equal(two.Select(a => a.Id), fav.Select(a => a.Id));
        Assert.All(two, a => Assert.True(fake.S.Assets[a.Id].IsFavorite));
        Assert.Superset(new HashSet<string> { "IMG_1001.PNG", "IMG_1002.PNG" }, (await List(b, "smart:Favorites")).Select(a => a.Filename).ToHashSet());
        await b.SetFavoriteAsync([fav[0]], false);
        Assert.False(fake.S.Assets[fav[0].Id].IsFavorite);

        var hidden = await b.SetHiddenAsync([two[1]], true);
        Assert.True(hidden[0].IsHidden);
        Assert.Equal("archive", fake.S.Assets[two[1].Id].Visibility);
        Assert.DoesNotContain(await List(b, "smart:All Photos"), a => a.Id == two[1].Id);
        Assert.Contains(await List(b, "smart:Hidden"), a => a.Id == two[1].Id);
        await b.SetHiddenAsync(hidden, false);
        Assert.Equal("timeline", fake.S.Assets[two[1].Id].Visibility);
        Assert.Equal(4, fake.S.Calls.Count(c => c == "PUT /assets"));
    }

    [Fact]
    public async Task DeleteGoesToTheTrashAndRestores()
    {
        var (fake, b) = Backend();
        var a = await AssetIn(b, "smart:All Photos", "IMG_1005.PNG");
        await b.DeleteAsync([a]);
        Assert.True(fake.S.Assets[a.Id].IsTrashed);
        Assert.Equal(0, fake.S.ForceDeletes);
        Assert.DoesNotContain(await List(b, "smart:All Photos"), x => x.Id == a.Id);
        var t = (await List(b, "smart:Recently Deleted")).Single(x => x.Id == a.Id);
        Assert.True(t.IsDeleted);
        Assert.Equal(2, (await Album(b, "smart:Recently Deleted")).Count);
        await b.RestoreAsync([t]);
        Assert.False(fake.S.Assets[a.Id].IsTrashed);
        Assert.Contains(await List(b, "smart:All Photos"), x => x.Id == a.Id);
        Assert.NotEmpty(fake.S.DeleteBodies);
        Assert.All(fake.S.DeleteBodies, body => Assert.False(body.ContainsKey("force")));
    }

    [Fact]
    public async Task DeleteIsRefusedWhenTheServersTrashIsOff()
    {
        var s = FakeImmichServer.State.Seeded();
        s.TrashEnabled = false;
        var (fake, b) = Backend(s);
        var a = await AssetIn(b, "smart:All Photos", "IMG_1005.PNG");
        var e = await Fails(() => b.DeleteAsync([a]));
        Assert.Equal(CloudErrorKind.Denied, e.Kind);
        Assert.Equal(ImmichPhotos.TrashOffMessage, e.Message);
        Assert.True(fake.S.Assets.TryGetValue(a.Id, out var still) && !still.IsTrashed);
        Assert.DoesNotContain("DELETE /assets", fake.S.Calls);
    }

    [Fact]
    public async Task SomeoneElsesPhotosAreLeftAlone()
    {
        var (fake, b) = Backend();
        var garden = fake.S.AlbumNamed("Sam’s Garden")!;
        var theirs = (await List(b, "album:" + garden.Id)).First();
        var calls = fake.S.Calls.Count;
        foreach (var op in new Func<Task>[] { () => b.SetFavoriteAsync([theirs], true), () => b.SetHiddenAsync([theirs], true), () => b.DeleteAsync([theirs]) })
        {
            var e = await Fails(op);
            Assert.Equal(CloudErrorKind.Denied, e.Kind);
            Assert.Contains("shared it with you", e.Message);
        }
        Assert.Equal(calls, fake.S.Calls.Count);   // refused before asking the server
        // A viewer can't add to the album.
        var mine = await AssetIn(b, "smart:All Photos", "IMG_1001.PNG");
        var album = await Album(b, "album:" + garden.Id);
        Assert.Equal(CloudErrorKind.Denied, (await Fails(() => b.AddAsync([mine], album, Lib))).Kind);
    }

    [Fact]
    public async Task CreateAlbumAndAddPhotos()
    {
        var (fake, b) = Backend();
        var created = await b.CreateAlbumAsync("  Road Trip ", Lib);
        Assert.StartsWith("album:", created.Id);
        Assert.Equal((PhotoAlbumKind.Album, "Road Trip", (int?)0), (created.Kind, created.Name, created.Count));
        var fakeAlbum = fake.S.AlbumNamed("Road Trip")!;
        Assert.Equal("album:" + fakeAlbum.Id, created.Id);
        var three = (await List(b, "smart:All Photos")).Take(3).ToList();
        await b.AddAsync(three, created, Lib);
        await b.AddAsync([three[0]], created, Lib);   // already there: fine
        Assert.Equal(three.Select(a => a.Id), fake.S.AlbumNamed("Road Trip")!.AssetIDs);
        Assert.Equal(3, (await Album(b, created.Id)).Count);
        Assert.Equal(three.Select(a => a.Id), (await List(b, created.Id)).Select(a => a.Id));
        var favorites = await Album(b, "smart:Favorites");
        Assert.Equal(CloudErrorKind.Unsupported, (await Fails(() => b.AddAsync(three, favorites, Lib))).Kind);
        Assert.Equal(CloudErrorKind.NotConfigured, (await Fails(() => b.CreateAlbumAsync("  ", Lib))).Kind);
    }

    // MARK: Import

    [Fact]
    public async Task ImportUploadsOnceAndDetectsDuplicates()
    {
        var (fake, b) = Backend();
        var dir = TestEnv.TempDir("immich-import");
        var date = DateTimeOffset.FromUnixTimeSeconds(1_780_000_000);
        var a = PhotoFile("Beach day.png", 501, date, dir);
        var c = PhotoFile("Café.png", 502, date.AddSeconds(60), dir);
        var p = new ProgressLog();
        var ids = await b.ImportReturningIDsAsync([a, c], p.Note);
        Assert.Equal(2, ids.Count);
        var s = fake.S;
        Assert.Equal(2, s.Uploads);
        var up = s.Assets[ids[0]];
        Assert.Equal(("Beach day.png", s.Me.Id, "IMAGE"), (up.OriginalFileName, up.OwnerID, up.Type));
        Assert.Equal((160, 120), (up.Width ?? 0, up.Height ?? 0));
        Assert.True(Math.Abs((up.FileCreatedAt - date).TotalSeconds) < 0.01);
        Assert.Equal("Café.png", s.Assets[ids[1]].OriginalFileName);
        Assert.All(s.UploadFields, f => Assert.Equal(["fileCreatedAt", "fileModifiedAt", "filename"], f.Keys.Order(StringComparer.Ordinal)));
        var total = new FileInfo(a).Length + new FileInfo(c).Length;
        Assert.Equal((total, total), p.Last);
        // Again: nothing is sent, the same ids come back.
        Assert.Equal(ids, await b.ImportReturningIDsAsync([a, c], null));
        Assert.Equal(2, fake.S.Uploads);
        Assert.Equal(4, fake.S.Calls.Count(x => x == "POST /assets/bulk-upload-check"));
        Assert.Equal(2, fake.S.Calls.Count(x => x == "POST /assets"));
        // A copy of a photo in the trash brings that photo back.
        var trashed = fake.S.AssetNamed("IMG_1012.PNG")!;
        var copy = Path.Combine(dir, "copy.png");
        File.WriteAllBytes(copy, trashed.Data);
        Assert.Equal([trashed.Id], await b.ImportReturningIDsAsync([copy], null));
        Assert.False(fake.S.Assets[trashed.Id].IsTrashed);
        Assert.Equal(2, fake.S.Uploads);
        // Into an album, each file reported as soon as it is in the library.
        var fam = await Album(b, "album:" + fake.S.AlbumNamed("Family")!.Id);
        var d = PhotoFile("Dinner.png", 503, date, dir);
        var reported = new List<(string File, string? ID)>();
        await b.ImportFilesEachAsync([d], fam, Lib, null, (f, id) => reported.Add((f, id)));
        var dinner = fake.S.AssetNamed("Dinner.png")!;
        Assert.Equal([(d, (string?)dinner.Id)], reported);
        Assert.Contains(dinner.Id, fake.S.AlbumNamed("Family")!.AssetIDs);
    }

    [Fact]
    public async Task ImportLinksLivePhotos()
    {
        var (fake, b) = Backend();
        var dir = TestEnv.TempDir("immich-live");
        var date = DateTimeOffset.FromUnixTimeSeconds(1_781_000_000);
        var still = PhotoFile("IMG_5000.PNG", 600, date, dir);
        var mov = Path.Combine(dir, "IMG_5000.MOV");
        File.WriteAllBytes(mov, FakeImmichServer.Movie("qt  ", 5000, 9));
        var reported = new List<(string File, string? ID)>();
        await b.ImportFilesEachAsync([still, mov], null, Lib, null, (f, id) => reported.Add((f, id)));
        var s = fake.S;
        var photo = s.AssetNamed("IMG_5000.PNG")!;
        Assert.Equal([(still, (string?)photo.Id), (mov, (string?)photo.Id)], reported);
        var video = s.Assets[photo.LivePhotoVideoID!];
        Assert.Equal("IMG_5000.MOV", video.OriginalFileName);
        Assert.Equal(("VIDEO", "hidden"), (video.Type, video.Visibility));
        Assert.Equal(2, s.UploadFields.Count);
        Assert.False(s.UploadFields[0].ContainsKey("livePhotoVideoId"));
        Assert.Equal(video.Id, s.UploadFields[1]["livePhotoVideoId"]);
        var listed = await AssetIn(b, "smart:All Photos", "IMG_5000.PNG");
        Assert.True(listed.IsLive);
        Assert.Equal(video.Id, listed.Resource(PhotoResourceKind.LiveVideo)!.RecordName);
        Assert.DoesNotContain(await List(b, "smart:All Photos"), a => a.Filename == "IMG_5000.MOV");
        // Importing the pair again sends nothing.
        Assert.Equal([photo.Id], await b.ImportReturningIDsAsync([still, mov], null));
        Assert.Equal(2, fake.S.Uploads);
    }

    [Fact]
    public async Task UnsupportedFilesAreRefusedWithAMessage()
    {
        var (_, b) = Backend();
        var f = Path.Combine(TestEnv.TempDir("immich-txt"), "notes.txt");
        File.WriteAllText(f, "hello");
        var e = await Fails(() => b.ImportReturningIDsAsync([f], null));
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
        Assert.Contains("isn’t supported", e.Message);
        Assert.DoesNotContain("notes.txt", e.Message);
    }

    // MARK: Errors

    [Fact]
    public async Task ErrorsMapToCloudErrors()
    {
        var (fake, b) = Backend();
        await b.LibrariesAsync();
        // Revoked key.
        fake.Update(s => s.ApiKeys.Clear());
        var e1 = await Fails(() => b.LibrariesAsync());
        Assert.Equal(CloudErrorKind.SignInNeeded, e1.Kind);
        Assert.Equal("Immich (alex@example.com (photos.example.com))", e1.Detail);
        // A key without a permission.
        fake.Update(s => s.ApiKeys[Key] = [.. ImmichCloud.ReadPermissions]);
        var a = await AssetIn(b, "smart:All Photos", "IMG_1001.PNG");
        var e2 = await Fails(() => b.SetFavoriteAsync([a], true));
        Assert.Equal(CloudErrorKind.Denied, e2.Kind);
        Assert.Contains("asset.update", e2.Message);
        // Server errors and messages (v3 and older bodies).
        Assert.Equal("Validation failed — filter.size: Too big",
            ImmichClient.Message("""{"message":"Validation failed","errors":[{"path":["filter","size"],"message":"Too big"}]}"""u8.ToArray()));
        Assert.Equal("size must be an integer", ImmichClient.Message("""{"message":["size must be an integer"],"error":"Bad Request","statusCode":400}"""u8.ToArray()));
        Assert.Equal(CloudErrorKind.NotFound, ImmichClient.Failure(404, [], "Immich").Kind);
        var quota = ImmichClient.Failure(400, """{"message":"Quota has been exceeded!"}"""u8.ToArray(), "Immich");
        Assert.Equal((CloudErrorKind.QuotaExceeded, "Immich"), (quota.Kind, quota.Detail));
        var m500 = ImmichClient.Failure(500, """{"message":"Failed to upload"}"""u8.ToArray(), "Immich");
        Assert.Equal(CloudErrorKind.Server, m500.Kind);
        Assert.Contains("500", m500.Message);
        Assert.Contains("Failed to upload", m500.Message);
        // A proxy asking for its own password.
        Assert.Equal(CloudErrorKind.Denied, ImmichClient.ProxySignIn().Kind);
        // A photo deleted on the server meanwhile.
        fake.Update(s => { s.ApiKeys[Key] = ["all"]; s.Assets.Remove(a.Id); });
        var e3 = await Fails(() => b.ExportAsync(a, PhotoResourceKind.Original, Path.Combine(TestEnv.TempDir("immich-gone"), "x.png"), null));
        Assert.Equal(CloudErrorKind.Denied, e3.Kind);
        Assert.Contains("couldn’t find", e3.Message);
    }

    [Fact]
    public async Task BusyServersAreRetried()
    {
        var (fake, b) = Backend();
        fake.Update(s => { s.RateLimitNext = 2; s.UnavailableNext = 1; });
        Assert.Equal(8, (await b.AlbumsAsync(Lib)).Count);
        fake.Update(s => s.DropNext = 1);
        Assert.NotEmpty(await List(b, "smart:Videos"));
        fake.Update(s => s.FailNext = 1);
        Assert.Equal(CloudErrorKind.Server, (await Fails(() => b.CreateAlbumAsync("X", Lib))).Kind);   // 500 is not retried
        fake.Update(s => s.RateLimitNext = 10);
        var busy = await Fails(() => b.CreateAlbumAsync("Y", Lib));
        Assert.Equal(CloudErrorKind.Server, busy.Kind);
        Assert.Contains("busy", busy.Message);
    }

    [Fact]
    public async Task ListingCanBeCancelled()
    {
        var (fake, b) = Backend();
        await b.LibrariesAsync();
        b.FirstPageSize = 1;
        b.PageSize = 1;
        fake.Update(s => s.Latency = 0.15);
        using var cts = new CancellationTokenSource();
        var task = b.AssetsAsync(new PhotoAlbum("smart:All Photos", "All Photos", PhotoAlbumKind.Smart, count: 19), Lib, null, cts.Token);
        await Task.Delay(250);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        fake.Update(s => s.Latency = 0);
        Assert.True(fake.S.SearchBodies.Count < 19);
    }

    // MARK: Demo

    [Fact]
    public async Task DemoAccount()
    {
        var fake = FakeImmichServer.Demo();
        var demo = Assert.Single(fake.DemoAccounts());
        Assert.Equal(("cloud:immich:demo", CloudProvider.Immich, "alex@example.com"), (demo.Record.Id, demo.Record.Provider, demo.Record.Title));
        Assert.True(fake.Handles(new Uri("https://photos.example.com/api/server/ping")));
        Assert.False(fake.Handles(new Uri("https://www.example.com/")));   // shares a router with the other fakes
        var router = new FakeCloudRouter(fake);
        var photos = ImmichCloud.Make(demo.Record, demo.Secret, router);
        var l = await photos.LibrariesAsync();
        Assert.Equal("immich", Assert.Single(l).Id);
        var albums = await photos.AlbumsAsync(l[0]);
        Assert.Equal(3, albums.Count(a => a.Kind != PhotoAlbumKind.Smart));
        var all = albums.Single(a => a.IsAllPhotos);
        var assets = await photos.AssetsAsync(all, l[0], null);
        Assert.Equal(19, assets.Count);
        Assert.True(assets.Select(a => (a.Created!.Value.Year, a.Created!.Value.Month)).Distinct().Count() >= 4);
        Assert.True(photos.Capabilities.HasFlag(PhotoCapabilities.ImportFiles));
        Assert.NotNull(await photos.ThumbnailAsync(assets[0], 256));
    }

    [Fact]
    public async Task DemoStateIsKeptOnDisk()
    {
        var dir = TestEnv.TempDir("immich-demo");
        var fake = FakeImmichServer.Demo(dir);
        var demo = fake.DemoAccounts()[0];
        var photos = ImmichCloud.Make(demo.Record, demo.Secret, fake);
        var album = await photos.CreateAlbumAsync("Kept", ImmichPhotos.Library);
        var again = FakeImmichServer.Demo(dir);
        var reloaded = again.S.AlbumNamed("Kept");
        Assert.NotNull(reloaded);
        Assert.Equal("album:" + reloaded!.Id, album.Id);
        Assert.Equal(fake.S.Assets.Count, again.S.Assets.Count);
        var any = fake.S.Assets.Values.First();
        Assert.Equal(any.Data, again.S.Assets[any.Id].Data);
    }
}
