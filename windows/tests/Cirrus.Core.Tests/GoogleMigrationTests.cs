using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>iCloud → Google (port of GoogleMigrationTests.swift), against the fake Google server.</summary>
public class GoogleMigrationTests
{
    static Dictionary<string, string> Query(Uri u) => LoopbackReceiver.ParseQuery(u.PathAndQuery);

    // MARK: OAuth

    [Fact]
    public async Task SignInUsesLoopbackPkceAndGetsRefreshToken()
    {
        var g = new FakeGoogle();
        var oauth = new GoogleOAuth(G.Client, g);
        Uri? seen = null;
        var tokens = await oauth.AuthorizeAsync(u => { seen = u; return g.ApproveAsync(u); });
        Assert.StartsWith("1//fake-refresh-", tokens.RefreshToken);
        Assert.True(tokens.Has(GoogleScopes.DriveFile) && tokens.Has(GoogleScopes.PhotosAppend));
        Assert.NotNull(seen);
        var q = Query(seen!);
        Assert.Equal("accounts.google.com", seen!.Host);
        Assert.Equal("S256", q["code_challenge_method"]);
        Assert.Equal(43, q["code_challenge"].Length);
        Assert.StartsWith("http://127.0.0.1:", q["redirect_uri"]);
        Assert.Equal(string.Join(' ', GoogleScopes.All), q["scope"]);
        Assert.True(q["access_type"] == "offline" && q["response_type"] == "code" && q["state"].Length >= 30);
        Assert.Contains("POST oauth2.googleapis.com/token", g.S.Calls);
    }

    [Fact]
    public async Task DeniedConsentAndForgedStateAreRejected()
    {
        var g = new FakeGoogle();
        var oauth = new GoogleOAuth(G.Client, g);
        var denied = await Assert.ThrowsAsync<GoogleException>(() => oauth.AuthorizeAsync(u => g.ApproveAsync(u, deny: true)));
        Assert.Equal(GoogleErrorKind.AccessDenied, denied.Kind);
        // A redirect carrying someone else's state must be ignored.
        var forged = await Assert.ThrowsAsync<GoogleException>(() => oauth.AuthorizeAsync(u =>
        {
            var q = Query(u);
            q["state"] = "forged";
            return g.ApproveAsync(new Uri(GoogleOAuth.AuthorizeURL + "?" + string.Join('&', q.Select(kv => Uri.EscapeDataString(kv.Key) + "=" + Uri.EscapeDataString(kv.Value)))));
        }));
        Assert.Equal(GoogleErrorKind.StateMismatch, forged.Kind);
    }

    [Fact]
    public async Task MissingSecretIsExplained()
    {
        var g = new FakeGoogle();
        var oauth = new GoogleOAuth(new GoogleOAuthClient(G.Client.ClientID, null), g) { Delay = (_, _) => Task.CompletedTask };
        var e = await Assert.ThrowsAsync<GoogleException>(() => oauth.AuthorizeAsync(u => g.ApproveAsync(u)));
        Assert.Contains("client secret", e.Message);
    }

    [Fact]
    public async Task ExpiredAccessTokenIsRefreshedOnceAndRevokedOneAsksToReconnect()
    {
        var (g, api) = await G.Connect(new FakeGoogle.State { AccessTTL = 1 });   // < 90 s: every call refreshes first
        await new GoogleDrive(api).AboutAsync();
        Assert.Equal(1, g.S.Refreshes);
        // A 401 on a token we thought was fine: refresh and retry once.
        var stale = new GoogleTokens { AccessToken = "ya29.unknown", ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(3000), Scopes = [.. GoogleScopes.All] };
        g.Update(s => s.AccessTTL = 3600);
        var refresh = g.S.RefreshTokenList[0];
        var api2 = new GoogleApi("x", new GoogleOAuth(G.Client, g), GoogleScopes.All, _ => Task.FromResult(refresh), g, stale);
        await new GoogleDrive(api2).AboutAsync();
        Assert.Equal(2, g.S.Refreshes);
        // Revoked (or a Testing project's 7 days are up): tell the user to reconnect.
        g.Update(s => s.RevokeAllRefreshTokens());
        var api3 = new GoogleApi("x", new GoogleOAuth(G.Client, g), GoogleScopes.All, _ => Task.FromResult(refresh), g);
        var e = await Assert.ThrowsAsync<GoogleException>(() => new GoogleDrive(api3).AboutAsync());
        Assert.Equal(GoogleErrorKind.Reconnect, e.Kind);
    }

    [Fact]
    public async Task RateLimitsBackOffAndDailyCapsStop()
    {
        var (g, api) = await G.Connect();
        g.Update(s => s.RateLimitNext = 3);
        var (user, quota) = await new GoogleDrive(api).AboutAsync();
        Assert.True(user.Email == "demo.person@gmail.example" && quota.Limit == 15_000_000_000);
        Assert.Equal(4, g.S.Calls.Count(c => c == "GET www.googleapis.com/drive/v3/about"));
        static byte[] B(string s) => System.Text.Encoding.UTF8.GetBytes(s);
        var daily = GoogleApi.Classify(429, B("""{"error":{"code":429,"message":"Quota exceeded for quota metric 'All requests' and limit 'All requests per day' of service 'photoslibrary.googleapis.com'","status":"RESOURCE_EXHAUSTED"}}"""), null);
        Assert.True(daily is GoogleApi.Verdict.Fail { Error.Kind: GoogleErrorKind.DailyLimit } f && f.Error.Message == GoogleApi.DailyMessage("photos"));
        Assert.True(GoogleApi.Classify(403, B("""{"error":{"errors":[{"reason":"storageQuotaExceeded"}],"message":"The user's Drive storage quota has been exceeded."}}"""), null)
            is GoogleApi.Verdict.Fail { Error.Kind: GoogleErrorKind.StorageFull });
        Assert.Equal(new GoogleApi.Verdict.Retry(2), GoogleApi.Classify(403, B("""{"error":{"errors":[{"reason":"userRateLimitExceeded"}],"message":"User rate limit exceeded"}}"""), "2"));
        Assert.Equal(new GoogleApi.Verdict.Retry(null), GoogleApi.Classify(503, [], null));
    }

    // MARK: Drive resumable uploads

    [Fact]
    public async Task ResumableUploadRecoversFromADroppedConnection()
    {
        var (g, api) = await G.Connect();
        var drive = new GoogleDrive(api) { ChunkSize = 512 * 1024 };   // the dropped chunk keeps its first 256 KiB
        var dir = TestEnv.TempDir("drop");
        var file = Path.Combine(dir, "big.bin");
        var bytes = Enumerable.Range(0, 1_500_000).Select(i => (byte)(i % 251)).ToArray();
        bytes[0] = 7;
        File.WriteAllBytes(file, bytes);
        g.Update(s => s.DropDriveChunk = 3);
        var folder = await drive.CreateFolderAsync("From iCloud", "root");
        var session = await drive.StartUploadAsync("big.bin", folder.Id, bytes.Length, DateTimeOffset.FromUnixTimeSeconds(1_600_000_000));
        var f = await drive.UploadAsync(file, session, resume: false, null);
        Assert.Equal(bytes.Length, f.Size);
        Assert.Equal(G.Md5(file), f.Md5);
        Assert.True(g.S.StatusQueries >= 1);           // asked Google where it stopped
        Assert.Equal(1, g.S.DriveSessionsStarted);     // and resumed the same session
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_600_000_000), f.Modified);
    }

    [Fact]
    public async Task EmptyFilesUpload()
    {
        var (_, api) = await G.Connect();
        var drive = new GoogleDrive(api);
        var file = Path.Combine(TestEnv.TempDir("empty"), "empty.txt");
        File.WriteAllBytes(file, []);
        var s = await drive.StartUploadAsync("empty.txt", "root", 0, null);
        var f = await drive.UploadAsync(file, s, resume: false, null);
        Assert.True(f.Size == 0 && f.Name == "empty.txt");
    }

    [Fact]
    public async Task InterruptedMoveResumesTheSameUploadOnTheNextRun()
    {
        var (g, api) = await G.Connect();
        var src = TestEnv.TempDir("src");
        var state = TestEnv.TempDir("state");
        File.WriteAllBytes(Path.Combine(src, "Movie.mov"), Enumerable.Range(0, 2_000_000).Select(i => (byte)(i % 241)).ToArray());
        // Google stops answering after 3 chunks: the run stops cleanly and remembers the session.
        g.Update(s => s.FailDriveChunksAfter = 3);
        var e1 = G.Engine(api, state, src, options: new MigrationOptions { Concurrency = 1 });
        var r1 = await e1.RunAsync(await e1.EvaluateAsync(null), null);
        Assert.Equal(0, r1.DriveCopied);
        Assert.NotNull(r1.Stopped);
        var sessionsBefore = g.S.DriveSessionsStarted;
        g.Update(s => s.FailDriveChunksAfter = null);
        var e2 = G.Engine(api, state, src);
        var r2 = await e2.RunAsync(await e2.EvaluateAsync(null), null);
        Assert.True(r2.DriveCopied == 1 && r2.Resumed == 1 && r2.Stopped is null);
        Assert.Equal(sessionsBefore, g.S.DriveSessionsStarted);   // no new session
        Assert.Equal(G.Md5(Path.Combine(src, "Movie.mov")), g.S.FileNamed("Movie.mov")!.Md5);
    }

    // MARK: Photos

    [Fact]
    public async Task PhotosAreCreatedFiftyAtATimeWithAlbums()
    {
        var (g, api) = await G.Connect();
        var lib = new TestPhotos();
        lib.Assets = Enumerable.Range(0, 118).Select(i => TestPhotos.Asset(i, favorite: i % 10 == 0)).ToList();
        lib.Assets.AddRange([TestPhotos.Asset(500, live: true), TestPhotos.Asset(501, video: true), TestPhotos.Asset(502, name: "Layered.psd"), TestPhotos.Asset(503, video: true, size: 21L * 1024 * 1024 * 1024)]);
        lib.UserAlbums = [new("album:trips", "Trips", PhotoAlbumKind.Album), new("album:empty", "Empty", PhotoAlbumKind.Album)];
        lib.Membership = new() { ["album:trips"] = Enumerable.Range(0, 60).Select(i => $"A{i:0000}").ToList() };
        g.Update(s => s.RejectFileNames = ["IMG_0007.HEIC"]);
        var o = new MigrationOptions { IncludeDrive = false };
        var state = TestEnv.TempDir("photos");
        var e = G.Engine(api, state, photos: lib, options: o);
        var ev = await e.EvaluateAsync(null);
        // 118 + Live still + Live video + one video = 121 items; the .psd and the 21 GB video are listed and skipped.
        Assert.Equal(121, ev.PhotoPending.Count);
        Assert.Equal(new HashSet<string> { "Layered.psd", "IMG_0503.MOV" }, ev.Skipped.Select(x => x.Name).ToHashSet());
        Assert.Contains(ev.PhotoPending, p => p.FileName == "IMG_0500.MOV" && p.Kind == PhotoResourceKind.LiveVideo);
        var r = await e.RunAsync(ev, null);
        Assert.Equal([50, 50, 21], g.S.BatchCreateSizes);
        Assert.True(r.PhotosCreated == 120 && r.Failed.Count == 1 && r.Failed[0].Contains("IMG_0007.HEIC"), string.Join("; ", r.Failed));
        Assert.Equal(new HashSet<string> { "Trips", "Favorites from iCloud" }, g.S.Albums.Values.Select(a => a.Title).ToHashSet());
        Assert.Equal(59, g.S.Albums.Values.First(a => a.Title == "Trips").Items.Count);   // IMG_0007 wasn't created
        Assert.All(g.S.AlbumAddSizes, n => Assert.True(n <= 50));
        Assert.Contains(g.S.Media.Values, m => m.Description?.StartsWith("Taken ") == true);   // no embedded date → kept in the description
        Assert.Equal(0, lib.Writes);
        // Next run: only the rejected photo is retried, and it joins its album.
        g.Update(s => s.RejectFileNames = []);
        var e2 = G.Engine(api, state, photos: lib, options: o);
        var ev2 = await e2.EvaluateAsync(null);
        Assert.Equal(["IMG_0007.HEIC"], ev2.PhotoPending.Select(p => p.FileName));
        var r2 = await e2.RunAsync(ev2, null);
        Assert.True(r2.PhotosCreated == 1 && r2.AlbumsCreated == 0);
        Assert.Equal(60, g.S.Albums.Values.First(a => a.Title == "Trips").Items.Count);
    }

    [Fact]
    public async Task BigVideosUseResumableUploadsAndSurviveDrops()
    {
        var (g, api) = await G.Connect();
        var lib = new TestPhotos { Assets = [TestPhotos.Asset(1, video: true, size: GooglePhotos.RawLimit + 700_000)] };
        g.Update(s => s.DropPhotoChunk = 4);
        var e = G.Engine(api, TestEnv.TempDir("video"), photos: lib, options: new MigrationOptions { IncludeDrive = false }, chunk: 4 << 20);
        var r = await e.RunAsync(await e.EvaluateAsync(null), null);
        Assert.True(r.PhotosCreated == 1 && r.Failed.Count == 0, string.Join("; ", r.Failed));
        Assert.Equal(1, g.S.PhotoSessionsStarted);
        Assert.Equal(GooglePhotos.RawLimit + 700_000, g.S.Media.Values.First().Size);
    }

    [Fact]
    public async Task PhotosDailyQuotaStopsAndTheNextRunFinishes()
    {
        var (g, api) = await G.Connect();
        var lib = new TestPhotos { Assets = Enumerable.Range(0, 70).Select(i => TestPhotos.Asset(i)).ToList() };
        g.Update(s => s.PhotosRequestsLeft = 55);
        var o = new MigrationOptions { IncludeDrive = false };
        var state = TestEnv.TempDir("quota");
        var e = G.Engine(api, state, photos: lib, options: o);
        var r = await e.RunAsync(await e.EvaluateAsync(null), null);
        Assert.Equal(50, r.PhotosCreated);
        Assert.Contains("daily limit", r.Stopped ?? "");
        g.Update(s => s.PhotosRequestsLeft = null);
        var e2 = G.Engine(api, state, photos: lib, options: o);
        var r2 = await e2.RunAsync(await e2.EvaluateAsync(null), null);
        Assert.Equal(20, r2.PhotosCreated);
        Assert.Equal(70, g.S.Media.Count);
    }

    // MARK: Whole migration

    [Fact]
    public async Task RerunsAreIncrementalAndNeverDeleteOrTouchICloud()
    {
        var (g, api) = await G.Connect();
        var src = TestEnv.TempDir("icloud");
        Directory.CreateDirectory(Path.Combine(src, "Docs", "Old"));
        Directory.CreateDirectory(Path.Combine(src, "Empty folder"));
        TestEnv.Write("hello", Path.Combine(src, "Docs", "a.txt"));
        TestEnv.Write("notes", Path.Combine(src, "Docs", "Old", "b.txt"));
        File.WriteAllBytes(Path.Combine(src, "photo.raw"), new byte[600_000]);
        TestEnv.Write("junk", Path.Combine(src, ".DS_Store"));
        var before = TestEnv.Tree(src);
        var lib = new TestPhotos { Assets = Enumerable.Range(0, 5).Select(i => TestPhotos.Asset(i)).ToList() };
        var state = TestEnv.TempDir("state");

        var e1 = G.Engine(api, state, src, lib);
        var ev1 = await e1.EvaluateAsync(null);
        Assert.True(ev1.DrivePending.Count == 3 && ev1.PhotoPending.Count == 5);
        Assert.True(ev1.Fits && ev1.Quota?.Free == 15_000_000_000 - 2_300_000_000);
        var r1 = await e1.RunAsync(ev1, null);
        Assert.True(r1.DriveCopied == 3 && r1.PhotosCreated == 5 && r1.Failed.Count == 0, string.Join("; ", r1.Failed));
        var root = g.S.Files.Values.Single(f => f.Name == "From iCloud" && f.Parents.SequenceEqual([FakeGoogle.RootID]));
        Assert.Contains(g.S.Files.Values, f => f.Name == "Empty folder" && f.Parents.SequenceEqual([root.Id]));
        Assert.DoesNotContain(g.S.Files.Values, f => f.Name == ".DS_Store");
        var sessions = g.S.DriveSessionsStarted;
        var creates = g.S.BatchCreateSizes.Count;

        // Second run: nothing to do, nothing sent.
        var e2 = G.Engine(api, state, src, lib);
        var ev2 = await e2.EvaluateAsync(null);
        Assert.True(ev2.IsUpToDate);
        var r2 = await e2.RunAsync(ev2, null);
        Assert.Equal("Everything was already in Google", r2.Summary);
        Assert.True(g.S.DriveSessionsStarted == sessions && g.S.BatchCreateSizes.Count == creates);

        // A changed file and a new photo: exactly those go up; the old copy goes to Drive's trash.
        TestEnv.Write("hello, again", Path.Combine(src, "Docs", "a.txt"));
        File.SetLastWriteTimeUtc(Path.Combine(src, "Docs", "a.txt"), DateTime.UtcNow.AddSeconds(60));
        lib.Assets.Add(TestPhotos.Asset(99));
        var e3 = G.Engine(api, state, src, lib);
        var ev3 = await e3.EvaluateAsync(null);
        Assert.Equal(["Docs/a.txt"], ev3.DrivePending.Select(d => d.Rel));
        Assert.Single(ev3.PhotoPending);
        var r3 = await e3.RunAsync(ev3, null);
        Assert.True(r3.DriveUpdated == 1 && r3.PhotosCreated == 1);
        Assert.Equal(sessions + 1, g.S.DriveSessionsStarted);
        Assert.Single(g.S.Files.Values, f => f.Name == "a.txt" && f.Trashed);
        Assert.Equal(0, g.S.PermanentDeletes);

        // The local record is lost (new PC): Cirrus finds its folder again instead of copying twice.
        var fresh = G.Engine(api, TestEnv.TempDir("lost"), src, lib);
        var ev4 = await fresh.EvaluateAsync(null);
        Assert.Empty(ev4.DrivePending);

        // iCloud side untouched.
        Assert.Equal(before, TestEnv.Tree(src));
        Assert.Equal(0, lib.Writes);
        // Google files Cirrus didn't create stay invisible to it.
        Assert.All(await new GoogleDrive(api).ChildrenAsync("root"), f => Assert.True(f.AppProperties.ContainsKey("cirrusSource")));
    }

    [Fact]
    public async Task NotEnoughGoogleStorageBlocksTheRun()
    {
        var (g, api) = await G.Connect(new FakeGoogle.State { Limit = 2_300_000_000 + 1_000 });
        var src = TestEnv.TempDir("full");
        File.WriteAllBytes(Path.Combine(src, "f.bin"), new byte[50_000]);
        var e = G.Engine(api, TestEnv.TempDir("fullstate"), src);
        var ev = await e.EvaluateAsync(null);
        Assert.False(ev.FitsGoogle);
        Assert.Contains(ev.Warnings, w => w.StartsWith("Not enough Google storage"));
        await Assert.ThrowsAsync<SyncException>(() => e.RunAsync(ev, null));
        Assert.Equal(0, g.S.DriveSessionsStarted);
    }

    [Fact]
    public async Task PhotosOnlyGrantSkipsDrive()
    {
        var (_, api) = await G.Connect(new FakeGoogle.State { GrantedScopes = [GoogleScopes.PhotosAppend] });
        Assert.False(api.Has(GoogleScopes.DriveFile));
        var src = TestEnv.TempDir("nodrive");
        TestEnv.Write("x", Path.Combine(src, "x.txt"));
        var lib = new TestPhotos { Assets = [TestPhotos.Asset(1)] };
        var e = G.Engine(api, TestEnv.TempDir("nodrivestate"), src, lib);
        var ev = await e.EvaluateAsync(null);
        Assert.True(!ev.DriveEnabled && ev.PhotosEnabled);
        Assert.Contains(ev.Warnings, w => w.Contains("Google Drive access wasn’t granted"));
        var r = await e.RunAsync(ev, null);
        Assert.True(r.PhotosCreated == 1 && r.DriveCopied == 0);
    }

    [Fact]
    public void ManifestJournalSurvivesACrash()
    {
        var dir = TestEnv.TempDir("journal");
        var s1 = new JournalStore<MigrationManifest, MigrationOp>(dir, "m");
        s1.Apply(new MigrationOp.Root("r1", "From iCloud"));
        s1.Apply(new MigrationOp.File("a.txt", new("f1", 3, 10)));
        s1.Apply(new MigrationOp.Photo("lib|A|Original", new("m1", 9)));
        // No Compact(): as if Cirrus quit. Add a torn last line too.
        File.AppendAllText(s1.JournalPath, "{\"op\":\"file\",\"Rel\":\"b");
        var s2 = new JournalStore<MigrationManifest, MigrationOp>(dir, "m");
        Assert.True(s2.Read(m => m.Root) == "r1" && s2.Read(m => m.Files["a.txt"].Id) == "f1" && s2.Read(m => m.Photos.Count) == 1);
        s2.Compact();
        Assert.False(File.Exists(s2.JournalPath));
        Assert.Single(new JournalStore<MigrationManifest, MigrationOp>(dir, "m").Read(m => m.Files));
    }
}
