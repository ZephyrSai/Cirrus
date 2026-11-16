using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>OneDrive through the fake Graph server (port of OneDriveTests.swift). Sign-in goes through the real loopback listener.</summary>
public class OneDriveTests
{
    static byte[] Bytes(int n, int seed = 7) => Enumerable.Range(0, n).Select(i => unchecked((byte)(((i * 31) ^ (i >> 9)) + seed))).ToArray();

    static string FileWith(byte[] data, string name = "src.bin")
    {
        var path = Path.Combine(TestEnv.TempDir("onedrive"), name);
        File.WriteAllBytes(path, data);
        return path;
    }

    static Task<CloudConnection> SignIn(FakeGraphServer fake, Func<Uri, Task> open) =>
        OneDriveCloud.SignInAsync(fake.ClientID, open, fake, TimeSpan.FromSeconds(30), CancellationToken.None);

    /// <summary>Signs in through the real loopback listener (as the app does) and builds the account's backend.</summary>
    static async Task<(FakeGraphServer Fake, OneDriveBackend B, CloudConnection C)> Connect(FakeGraphServer.State? s = null)
    {
        var fake = new FakeGraphServer(s);
        var c = await SignIn(fake, url => fake.ApproveAsync(url));
        var b = OneDriveCloud.Backend(c.Record, c.Secret, fake);
        b.RetryBase = 0.001;
        return (fake, b, c);
    }

    static async Task<DriveNode> Node(OneDriveBackend b, string name, string folder = "root") =>
        (await b.ListAsync(folder)).Single(n => n.Name == name);

    static async Task<CloudException> Fails(CloudErrorKind kind, Func<Task> op)
    {
        var e = await Assert.ThrowsAsync<CloudException>(op);
        Assert.Equal(kind, e.Kind);
        return e;
    }

    static void Near(DateTimeOffset expected, DateTimeOffset? actual) =>
        Assert.True(actual is { } a && Math.Abs((a - expected).TotalSeconds) < 1, $"expected {expected:O}, got {actual:O}");

    // MARK: Sign-in

    [Fact]
    public async Task SignInRunsPKCEThroughLoopbackAndNamesTheAccount()
    {
        var fake = new FakeGraphServer();
        Uri? seen = null;
        using var log = new LogCapture();
        var c = await SignIn(fake, url => { seen = url; return fake.ApproveAsync(url); });
        Assert.Equal(CloudProvider.OneDrive, c.Record.Provider);
        Assert.Equal("alex@example.com", c.Record.Title);
        Assert.StartsWith("cloud:onedrive:", c.Record.Id);
        Assert.Equal(fake.ClientID, c.Secret.ClientID);
        Assert.Null(c.Secret.ClientSecret);
        Assert.Null(c.Secret.Password);
        Assert.Contains(c.Secret.RefreshToken, fake.S.ValidRefreshTokens);

        var url = Assert.IsType<Uri>(seen);
        var q = LoopbackReceiver.ParseQuery(url.PathAndQuery);
        Assert.Equal(("login.microsoftonline.com", "/common/oauth2/v2.0/authorize"), (url.Host, url.AbsolutePath));
        Assert.Equal("code", q["response_type"]);
        Assert.Equal("S256", q["code_challenge_method"]);
        Assert.Equal(43, q["code_challenge"].Length);
        Assert.StartsWith("http://localhost:", q["redirect_uri"]);
        Assert.Equal(["Files.ReadWrite.All", "User.Read", "offline_access"], q["scope"].Split(' ').Order(StringComparer.Ordinal).ToArray());
        Assert.True(q["state"].Length >= 30);
        Assert.Equal(fake.ClientID, q["client_id"]);

        var keys = Assert.Single(fake.S.TokenRequestKeys);
        Assert.Contains("code_verifier", keys);
        Assert.Contains("redirect_uri", keys);
        Assert.DoesNotContain("client_secret", keys);
        Assert.Contains("GET graph.microsoft.com/v1.0/me", fake.S.Calls);
        Assert.Contains("GET graph.microsoft.com/v1.0/me/drive", fake.S.Calls);
        // Logs carry status lines only: no tokens, codes or pre-authenticated links.
        Assert.Contains("onedrive token → 200", log.Text);
        foreach (var secret in new[] { "fake-refresh-", "fake-access-", "fake-code-", "tempauth" }) Assert.DoesNotContain(secret, log.Text);
    }

    [Fact]
    public async Task SignInRejectsDeniedConsentForgedStateAndAccountsWithoutADrive()
    {
        var fake = new FakeGraphServer();
        var denied = await Fails(CloudErrorKind.Denied, () => SignIn(fake, url => fake.ApproveAsync(url, deny: true)));
        Assert.Contains("Accept", denied.Message);

        var forged = await Fails(CloudErrorKind.Denied, () => SignIn(fake, async url =>
        {
            if (fake.Authorize(url) is not { } back) return;
            var tampered = back.AbsoluteUri.Split('?')[0] + "?" + string.Join('&', back.Query.TrimStart('?').Split('&')
                .Select(p => p.StartsWith("state=", StringComparison.Ordinal) ? "state=forged" : p));
            await FakeGraphServer.VisitAsync(new Uri(tampered));
        }));
        Assert.Contains("didn’t match", forged.Message);
        Assert.Empty(fake.S.TokenRequestKeys);   // the code was never redeemed

        var noDrive = new FakeGraphServer(new FakeGraphServer.State { HasDrive = false });
        var missing = await Fails(CloudErrorKind.Denied, () => SignIn(noDrive, url => noDrive.ApproveAsync(url)));
        Assert.Contains("doesn’t have a OneDrive", missing.Message);

        // Personal accounts often have no `mail`: the sign-in name is the title then.
        var noMail = new FakeGraphServer(new FakeGraphServer.State { Mail = null, UserPrincipalName = "alex.upn@example.com" });
        Assert.Equal("alex.upn@example.com", (await SignIn(noMail, url => noMail.ApproveAsync(url))).Record.Title);
    }

    [Fact]
    public async Task SignInTimesOutAndCancelsCleanly()
    {
        var fake = new FakeGraphServer();
        var timedOut = await Assert.ThrowsAsync<CloudException>(() =>
            OneDriveCloud.SignInAsync(fake.ClientID, _ => Task.CompletedTask, fake, TimeSpan.FromMilliseconds(200), CancellationToken.None));
        Assert.Equal(CloudErrorKind.Server, timedOut.Kind);
        Assert.Contains("Timed out waiting for you to finish signing in to Microsoft", timedOut.Message);

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            OneDriveCloud.SignInAsync(fake.ClientID, _ => Task.CompletedTask, fake, TimeSpan.FromSeconds(30), cts.Token));
        Assert.Empty(fake.S.TokenRequestKeys);
    }

    [Fact]
    public async Task FakeTokenEndpointIsStrictAboutPKCEAndRedirect()
    {
        var fake = new FakeGraphServer();
        var pkce = new Pkce();
        var url = OneDriveAuth.AuthorizationURL(fake.ClientID, "http://localhost:5555", pkce, "s");
        var back = Assert.IsType<Uri>(fake.Authorize(url));
        Assert.StartsWith("http://localhost:5555/?", back.AbsoluteUri);
        var code = LoopbackReceiver.ParseQuery(back.PathAndQuery)["code"];
        using var http = CloudBackends.Http(fake);
        var wrong = await Fails(CloudErrorKind.Server, () => OneDriveAuth.RedeemAsync(new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = "http://localhost:5555", ["code_verifier"] = new Pkce().Verifier,
        }, fake.ClientID, http, signingIn: true, CancellationToken.None));
        Assert.Contains("AADSTS501481", wrong.Message);
        Assert.DoesNotContain("Trace ID", wrong.Message);
        // Entra only redirects to the registered form, http://localhost with any port.
        Assert.Null(fake.Authorize(OneDriveAuth.AuthorizationURL(fake.ClientID, "http://127.0.0.1:5555", pkce, "s")));
        Assert.Null(fake.Authorize(OneDriveAuth.AuthorizationURL("someone-else", "http://localhost:5555", pkce, "s")));
    }

    [Fact]
    public async Task ClientIDComesFromTheSecretOrTheDefault()
    {
        var saved = OneDriveCloud.DefaultClientID;
        var fake = new FakeGraphServer();
        try
        {
            OneDriveCloud.DefaultClientID = "";
            var record = new CloudAccountRecord(CloudProvider.OneDrive, "x");
            var e1 = Assert.Throws<CloudException>(() => OneDriveCloud.Make(record, new CloudSecret { RefreshToken = "rt" }, fake));
            Assert.Equal((CloudErrorKind.NotConfigured, OneDriveCloud.NotConfiguredMessage), (e1.Kind, e1.Message));
            var e2 = await Fails(CloudErrorKind.NotConfigured, () => OneDriveCloud.SignInAsync("  ", _ => Task.CompletedTask, fake));
            Assert.Equal(OneDriveCloud.NotConfiguredMessage, e2.Message);
            Assert.Contains("http://localhost", OneDriveCloud.NotConfiguredMessage);
            OneDriveCloud.DefaultClientID = "default-app-id";
            Assert.Equal("default-app-id", OneDriveCloud.Backend(record, new CloudSecret { RefreshToken = "rt" }, fake).Secret.ClientID);
            Assert.Equal("own-app-id", OneDriveCloud.Backend(record, new CloudSecret { RefreshToken = "rt", ClientID = "own-app-id" }, fake).Secret.ClientID);
            var e3 = Assert.Throws<CloudException>(() => OneDriveCloud.Make(record, new CloudSecret(), fake));
            Assert.Equal((CloudErrorKind.SignInNeeded, "OneDrive needs you to sign in again."), (e3.Kind, e3.Message));
            Assert.True(OneDriveCloud.LooksLikeClientID(" " + FakeGraphServer.DemoClientID + " "));
            Assert.False(OneDriveCloud.LooksLikeClientID("my-app"));
        }
        finally { OneDriveCloud.DefaultClientID = saved; }
    }

    // MARK: Tokens

    [Fact]
    public async Task RefreshRotatesOnceForConcurrentRequestsAndHandsOnEachNewToken()
    {
        var (fake, b, c) = await Connect();
        var saved = new List<string>();
        Assert.IsAssignableFrom<ICloudTokenRotating>(b).OnNewRefreshToken = rt => { lock (saved) saved.Add(rt); };
        await b.ListAsync("root");                       // no access token yet: refresh #1
        Assert.Single(saved);
        var before = fake.S.Refreshes;
        fake.Update(s => s.ExpireAccessTokens());
        await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(() => b.ListAsync("root"))));
        Assert.Equal(before + 1, fake.S.Refreshes);      // eight 401s, one shared refresh
        Assert.Equal(2, saved.Count);
        var latest = saved[^1];
        Assert.Equal(latest, b.Secret.RefreshToken);
        Assert.NotEqual(c.Secret.RefreshToken, latest);
        Assert.Equal([latest], fake.S.ValidRefreshTokens);   // every older one stopped working
        // What the app saved keeps working after a relaunch; the first one from sign-in doesn't.
        await OneDriveCloud.Make(c.Record, c.Secret with { RefreshToken = latest }, fake).ListAsync("root");
        var stale = OneDriveCloud.Make(c.Record, c.Secret, fake);
        await Fails(CloudErrorKind.SignInNeeded, () => stale.ListAsync("root"));
    }

    [Fact]
    public async Task RevokedRefreshTokenOrRepeated401AsksToSignInAgain()
    {
        var (fake, b, _) = await Connect();
        await b.ListAsync("root");
        // Graph refuses a token that should still work: one refresh, then sign-in needed if it refuses again.
        fake.Update(s => s.UnauthorizedNext = 1);
        await b.ListAsync("root");
        fake.Update(s => s.UnauthorizedNext = 2);
        var e = await Fails(CloudErrorKind.SignInNeeded, () => b.ListAsync("root"));
        Assert.Equal("OneDrive needs you to sign in again.", e.Message);
        fake.Update(s => { s.RevokeRefreshTokens(); s.ExpireAccessTokens(); });
        await Fails(CloudErrorKind.SignInNeeded, () => b.ListAsync("root"));
    }

    [Fact]
    public async Task ThrottlingIsRetriedAfterRetryAfter()
    {
        var s = new FakeGraphServer.State();
        s.AddFile("A.txt", "a"u8.ToArray());
        var (fake, b, _) = await Connect(s);
        fake.Update(x => x.ThrottleNext = 3);
        Assert.Equal(["A.txt"], (await b.ListAsync("root")).Select(n => n.Name));
        Assert.Equal(0, fake.S.ThrottleNext);
        fake.Update(x => x.ThrottleNext = 50);
        var e = await Fails(CloudErrorKind.Server, () => b.ListAsync("root"));
        Assert.Contains("limiting", e.Message);
    }

    // MARK: Listing

    [Fact]
    public async Task ListingFollowsNextLinksAndNormalizesTheRoot()
    {
        var s = new FakeGraphServer.State();
        var docs = s.AddFolder("Documents");
        for (int i = 0; i < 7; i++) s.AddFile($"Note {i}.txt", Encoding.UTF8.GetBytes($"note {i}"), docs, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));
        s.AddFile("Top.txt", "top"u8.ToArray());
        s.AddPackage("Class Notebook");
        var (fake, b, _) = await Connect(s);
        var root = await b.ListAsync("root");
        Assert.Equal(["Class Notebook", "Documents", "Top.txt"], root.Select(n => n.Name).Order());
        Assert.All(root, n => Assert.True(n.ParentID == "root" && n.Zone == "onedrive" && n.Etag is not null));
        var d = root.Single(n => n.Name == "Documents");
        Assert.True(d.Id == docs && d.Type == "FOLDER" && d.IsFolder && d.ChildCount == 7 && d.Size == 0);
        Assert.Equal("FILE", root.Single(n => n.Name == "Class Notebook").Type);
        Assert.True(root.Single(n => n.Name == "Top.txt") is { Type: "FILE", Size: 3 });

        var notes = await b.ListAsync(docs);
        Assert.Equal(7, notes.Count);
        Assert.All(notes, n => Assert.True(n.ParentID == docs && n.Type == "FILE"));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_003), notes.Single(n => n.Name == "Note 3.txt").Modified);
        Assert.Equal(3, fake.S.Calls.Count(c => c == $"GET graph.microsoft.com/v1.0/me/drive/items/{docs}/children"));   // 3 + 3 + 1: every @odata.nextLink followed

        var many = await b.ListManyAsync(["root", docs, "root"]);
        Assert.Equal(2, many.Count);
        Assert.Equal(7, many[docs].Count);
        Assert.Equal(3, many["root"].Count);
        // A folder that can't be listed throws: it must never look empty.
        await Fails(CloudErrorKind.NotFound, () => b.ListManyAsync(["root", fake.S.DriveID.ToUpperInvariant() + "!9999"]));

        // Graph's real id for the top folder is reported as "root".
        var realRoot = await b.RealRootIDAsync(CancellationToken.None);
        Assert.Equal(fake.S.RootID, realRoot);
        Assert.All(await b.ListAsync(realRoot), n => Assert.Equal("root", n.ParentID));
    }

    // MARK: Uploads

    [Fact]
    public async Task SmallUploadSetsTheDateAndRoundTrips()
    {
        var (fake, b, _) = await Connect();
        var data = Bytes(10_000);
        var when = DateTimeOffset.FromUnixTimeSeconds(1_750_000_000);
        (long, long) last = default;
        var n = await b.UploadAsync(FileWith(data), "Report.pdf", "root", when, (done, total) => last = (done, total));
        Assert.True(n is { Name: "Report.pdf", ParentID: "root", Size: 10_000, Type: "FILE" });
        Near(when, n.Modified);
        Assert.Equal((10_000L, 10_000L), last);
        var st = fake.S;
        Assert.Equal((1, 0), (st.SimpleUploads, st.SessionsCreated));
        var stored = st.Child("Report.pdf")!;
        Assert.Equal(data, st.Blobs[stored.Id]);
        Near(when, stored.FsModified);
        Near(when, (await Node(b, "Report.pdf")).Modified);

        var empty = await b.UploadAsync(FileWith([], "e"), "Empty.txt", "root", null, null);
        Assert.Equal(0, empty.Size);
        Assert.NotNull(fake.S.Child("Empty.txt"));
    }

    [Fact]
    public async Task ChunkedUploadUsesFragmentsOf320KiBAndResumesWhereOneDriveSays()
    {
        var (fake, b, _) = await Connect(new FakeGraphServer.State { DropChunk = 2 });
        b.SimpleUploadLimit = 100_000;
        b.ChunkSize = 2 * 327_680 + 1000;   // rounded down to 640 KiB
        var folder = await b.CreateFolderAsync("Videos", "root");
        var data = Bytes(2_000_000);
        var when = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000);
        (long, long) last = default;
        var n = await b.UploadAsync(FileWith(data), "Clip.mov", folder.Id, when, (done, total) => last = (done, total));
        Assert.True(n.Size == 2_000_000 && n.ParentID == folder.Id && n.Name == "Clip.mov");
        Near(when, n.Modified);
        Assert.Equal((2_000_000L, 2_000_000L), last);
        var st = fake.S;
        Assert.Equal(data, st.Blobs[n.Id]);
        // The second fragment broke after 320 KiB had arrived: Cirrus asked and went on from 983040, not 655360.
        Assert.Equal([655_360, 655_360, 655_360, 361_600], st.ChunkSizes);
        Assert.Equal((1, 1, 0, 0), (st.SessionsCreated, st.SessionStatusQueries, st.SimpleUploads, st.OpenUploadSessions));
        Assert.Equal("fail", st.LastSessionItem["@microsoft.graph.conflictBehavior"].Str);
        Assert.Equal(2_000_000, st.LastSessionItem["fileSize"].Int64);
        Near(when, st.LastSessionItem["fileSystemInfo"]["lastModifiedDateTime"].Date);
        Assert.Equal(0, st.AuthLeaks);
        Assert.NotEmpty(st.ContentRequests);
        Assert.All(st.ContentRequests, r => Assert.False(r.HadAuth));
    }

    [Fact]
    public async Task FailedSessionUploadsAreCancelledOnOneDrive()
    {
        var (fake, b, _) = await Connect();
        b.SimpleUploadLimit = 0;
        b.ChunkSize = FakeGraphServer.FragmentUnit;
        using var cts = new CancellationTokenSource();
        var src = FileWith(Bytes(1_000_000));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            b.UploadAsync(src, "Big.bin", "root", null, (done, _) => { if (done >= FakeGraphServer.FragmentUnit) cts.Cancel(); }, cts.Token));
        Assert.Equal((1, 1, 0), (fake.S.SessionsCreated, fake.S.SessionsCancelled, fake.S.OpenUploadSessions));
        Assert.Null(fake.S.Child("Big.bin"));
    }

    [Fact]
    public async Task LostUploadAnswersDontFailOrDuplicate()
    {
        var (fake, b, _) = await Connect();
        fake.Update(s => s.LoseUploadAnswers = 1);
        var small = await b.UploadAsync(FileWith(Bytes(5_000)), "Small.bin", "root", null, null);
        Assert.Equal(5_000, small.Size);
        Assert.Equal(1, fake.S.SimpleUploads);

        b.SimpleUploadLimit = 0;
        b.ChunkSize = 327_680;
        fake.Update(s => s.LoseUploadAnswers = 1);
        var big = await b.UploadAsync(FileWith(Bytes(400_000)), "Big.bin", "root", null, null);
        Assert.True(big.Size == 400_000 && big.ParentID == "root");
        var st = fake.S;
        Assert.Equal(["Big.bin", "Small.bin"], st.Children(st.RootID).Select(i => i.Name).Order());
        Assert.Equal(Bytes(400_000), st.Blobs[big.Id]);
    }

    [Fact]
    public async Task NameConflictsFailClearlyInsteadOfReplacing()
    {
        var s = new FakeGraphServer.State();
        s.AddFile("Taken.txt", "old"u8.ToArray());
        s.AddFolder("Docs");
        var (fake, b, _) = await Connect(s);
        var src = FileWith("new"u8.ToArray());
        foreach (var limit in new long[] { 4 << 20, 0 })   // simple upload, then upload session
        {
            b.SimpleUploadLimit = limit;
            var e = await Fails(CloudErrorKind.Denied, () => b.UploadAsync(src, "taken.txt", "root", null, null));
            Assert.Contains("already", e.Message);
            Assert.Contains("“taken.txt”", e.Message);
        }
        Assert.Equal("old"u8.ToArray(), fake.S.Blobs[fake.S.Child("Taken.txt")!.Id]);
        var folder = await Fails(CloudErrorKind.Denied, () => b.CreateFolderAsync("Docs", "root"));
        Assert.Contains("“Docs”", folder.Message);
        var taken = await Node(b, "Taken.txt");
        await Fails(CloudErrorKind.Denied, () => b.RenameAsync(taken, "Docs"));
        Assert.Equal(0, fake.S.OpenUploadSessions);
    }

    [Fact]
    public async Task QuotaAndFullDrive()
    {
        var s = new FakeGraphServer.State { Total = 1_000_000 };
        s.AddFile("A.bin", new byte[200_000]);
        var gone = s.AddFile("B.bin", new byte[50_000]);
        s.Items[gone].Deleted = true;
        var (_, b, _) = await Connect(s);
        var u = Assert.IsType<StorageUsage>(await b.QuotaAsync());
        Assert.Equal((1_000_000L, 250_000L, 750_000L), (u.Total, u.Used, u.Available));
        Assert.Equal(["files", "deleted"], u.Categories.Select(c => c.Key));
        Assert.Equal([200_000L, 50_000L], u.Categories.Select(c => c.Bytes));
        var e = await Fails(CloudErrorKind.QuotaExceeded, () => b.UploadAsync(FileWith(new byte[800_000]), "Huge.bin", "root", null, null));
        Assert.Equal("There isn’t enough space in OneDrive.", e.Message);
    }

    // MARK: Downloads

    [Fact]
    public async Task DownloadFollowsTheRedirectWithoutTheToken()
    {
        var s = new FakeGraphServer.State { DropDownloadsNext = 1 };
        var data = Bytes(300_000, seed: 3);
        var when = DateTimeOffset.FromUnixTimeSeconds(1_720_000_000);
        s.AddFile("Photo.jpg", data, modified: when);
        s.AddPackage("Notebook");
        var (fake, b, _) = await Connect(s);
        var photo = await Node(b, "Photo.jpg");
        var dir = Path.Combine(TestEnv.TempDir("onedrive"), "out");
        var dest = Path.Combine(dir, "Photo.jpg");
        (long, long) last = default;
        await b.DownloadAsync(photo, dest, (done, total) => last = (done, total));
        Assert.Equal(data, File.ReadAllBytes(dest));
        Near(when, new DateTimeOffset(File.GetLastWriteTimeUtc(dest), TimeSpan.Zero));
        Assert.Equal((300_000L, 300_000L), last);
        var st = fake.S;
        Assert.Equal(2, st.ContentRequests.Count(r => r.Path.StartsWith("/dl/", StringComparison.Ordinal)));   // dropped once, then retried
        Assert.Equal(0, st.AuthLeaks);
        Assert.All(st.ContentRequests, r => Assert.False(r.HadAuth));
        Assert.Contains($"GET graph.microsoft.com/v1.0/me/drive/items/{photo.Id}/content", st.Calls);
        Assert.Equal(["Photo.jpg"], Directory.GetFiles(dir).Select(Path.GetFileName));   // no partial download left behind

        var notebook = await Node(b, "Notebook");
        var e = await Fails(CloudErrorKind.Unsupported, () => b.DownloadAsync(notebook, Path.Combine(dir, "Notebook"), null));
        Assert.Contains("OneNote", e.Message);
        Assert.Contains("“Notebook”", e.Message);
        Assert.Equal(["Photo.jpg"], Directory.GetFiles(dir).Select(Path.GetFileName));
    }

    // MARK: Changes

    [Fact]
    public async Task CreateRenameAndMoveIncludingBackToTheTop()
    {
        var s = new FakeGraphServer.State();
        s.AddFile("Plan.txt", "plan"u8.ToArray());
        var (fake, b, _) = await Connect(s);
        var projects = await b.CreateFolderAsync("Projects", "root");
        Assert.True(projects is { ParentID: "root", Type: "FOLDER", Name: "Projects" });
        var year = await b.CreateFolderAsync("2026", projects.Id);
        Assert.Equal(projects.Id, year.ParentID);
        var renamed = await b.RenameAsync(projects, "Projects (old)");
        Assert.True(renamed.Id == projects.Id && renamed.Name == "Projects (old)" && renamed.ParentID == "root");
        Assert.Equal(projects.Id, fake.S.Child("Projects (old)")?.Id);

        await b.MoveAsync([await Node(b, "Plan.txt")], year.Id);
        Assert.Equal(["Plan.txt"], (await b.ListAsync(year.Id)).Select(n => n.Name));
        Assert.DoesNotContain(await b.ListAsync("root"), n => n.Name == "Plan.txt");
        await b.MoveAsync([await Node(b, "Plan.txt", year.Id)], "root");
        Assert.Contains(await b.ListAsync("root"), n => n.Name == "Plan.txt");
        // OneDrive wants the top folder's real id; "root" is Cirrus's name for it.
        Assert.Equal(fake.S.RootID, fake.S.Patches[^1]["parentReference"]["id"].Str);
        // A folder can't go inside itself.
        await Fails(CloudErrorKind.Denied, () => b.MoveAsync([renamed], year.Id));
    }

    [Fact]
    public async Task TrashUsesTheRecycleBinAndRestoreIsLeftToOneDriveOnTheWeb()
    {
        var s = new FakeGraphServer.State();
        s.AddFile("Old.txt", new byte[1000]);
        var (fake, b, _) = await Connect(s);
        var old = await Node(b, "Old.txt");
        await b.TrashAsync([old]);
        Assert.Empty(await b.ListAsync("root"));
        Assert.Equal(["Old.txt"], fake.S.RecycleBin.Select(i => i.Name));
        Assert.True(fake.S.Blobs.ContainsKey(old.Id));
        await b.TrashAsync([old]);   // already gone: fine
        Assert.False(b.CanListTrash);
        Assert.Empty(await b.ListTrashAsync());
        var e = await Fails(CloudErrorKind.Unsupported, () => b.RestoreAsync([old]));
        Assert.Equal(OneDriveBackend.RecycleBinMessage, e.Message);
        Assert.Contains("onedrive.com", OneDriveBackend.RecycleBinMessage);
        // Delete Immediately is refused outright for items that aren't in a trash listing…
        await Assert.ThrowsAsync<InvalidOperationException>(() => b.DeleteForeverAsync([old]));
        // …and for anything that claims to be, Cirrus points to onedrive.com.
        var binned = old.Copy();
        binned.ParentID = CloudConventions.TrashParent;
        Assert.Equal(OneDriveBackend.RecycleBinMessage, (await Fails(CloudErrorKind.Unsupported, () => b.DeleteForeverAsync([binned]))).Message);
        Assert.Single(fake.S.RecycleBin);
    }

    [Fact]
    public async Task OddNamesArePercentEncodedAndRoundTrip()
    {
        Assert.Equal("a%3Fb%23c%25d%2Be%20f%2F%C3%A9", OneDriveBackend.EncodeName("a?b#c%d+e f/é"));
        var (fake, b, _) = await Connect();
        var decomposed = "Übeŕ.txt";   // as macOS file names often arrive
        string[] names = ["Q&A #1 – 100% + more.txt", "café 日本語 😀.md", "semi;colon=equals'quote,comma@at$!~.txt", decomposed];
        var dir = TestEnv.TempDir("onedrive");
        for (int i = 0; i < names.Length; i++)
        {
            var data = Encoding.UTF8.GetBytes($"file {i}");
            var n = await b.UploadAsync(FileWith(data), names[i], "root", null, null);
            var want = names[i].Normalize(NormalizationForm.FormC);
            Assert.Equal(want, n.Name);
            var stored = fake.S.Child(want)!;
            Assert.Equal(want, stored.Name);
            Assert.Equal(data, fake.S.Blobs[stored.Id]);
            var dest = Path.Combine(dir, $"f{i}");
            await b.DownloadAsync(await Node(b, want), dest, null);
            Assert.Equal(data, File.ReadAllBytes(dest));
        }
    }

    [Fact]
    public async Task NamesOneDriveRefusesAreCaughtBeforeSending()
    {
        var (fake, b, _) = await Connect();
        var src = FileWith("x"u8.ToArray());
        var before = fake.S.Calls.Count;
        foreach (var bad in new[] { "what?.txt", "a/b.txt", "co:lon.txt", "star*.txt", "pipe|.txt", "tab\t.txt", "", ".." })
            await Fails(CloudErrorKind.Denied, () => b.UploadAsync(src, bad, "root", null, null));
        await Fails(CloudErrorKind.Denied, () => b.CreateFolderAsync("a/b", "root"));
        await Fails(CloudErrorKind.Denied, () => b.CreateFolderAsync("zero\u200Bwidth", "root"));
        Assert.Equal(before, fake.S.Calls.Count);   // nothing was sent
        // Odd but valid folder names work, also for upload sessions addressed by name.
        var odd = await b.CreateFolderAsync("50% #done + more", "root");
        b.SimpleUploadLimit = 0;
        var n = await b.UploadAsync(FileWith(Bytes(1000)), "#1 report + 100%.bin", odd.Id, null, null);
        Assert.True(n.Name == "#1 report + 100%.bin" && n.ParentID == odd.Id);
        Assert.NotNull(fake.S.Child("#1 report + 100%.bin", odd.Id));
    }

    // MARK: Extras

    [Fact]
    public async Task ThumbnailsComeFromThePreAuthenticatedHost()
    {
        var s = new FakeGraphServer.State();
        var img = DemoArt.Png(64, 48, 0.3, "T");
        s.AddFile("Pic.png", img);
        s.AddFile("Notes.txt", "n"u8.ToArray());
        s.AddFolder("Folder");
        var (fake, b, _) = await Connect(s);
        var pic = await Node(b, "Pic.png");
        Assert.Equal(img, await b.ThumbnailAsync(pic, 256));
        Assert.Equal(["c256x256"], fake.S.ThumbnailSizes);
        Assert.Null(await b.ThumbnailAsync(await Node(b, "Notes.txt"), 256));
        var folder = await Node(b, "Folder");
        var calls = fake.S.Calls.Count;
        Assert.Null(await b.ThumbnailAsync(folder, 256));
        Assert.Equal(calls, fake.S.Calls.Count);   // no thumbnail request for a folder
        // Without custom sizes, the nearest named size.
        fake.Update(x => { x.CustomThumbnails = false; x.ThumbnailSizes.Clear(); });
        Assert.Equal(img, await b.ThumbnailAsync(pic, 120));
        Assert.Equal(["c120x120", "medium"], fake.S.ThumbnailSizes);
        Assert.Equal(0, fake.S.AuthLeaks);
    }

    [Fact]
    public async Task SharedFolderShortcutsBrowseTheOwnersDriveAndTrashOnlyTheShortcut()
    {
        var s = new FakeGraphServer.State();
        var shared = s.AddSharedFolder("Team Trip", [("Itinerary.txt", "Day 1"u8.ToArray())]);
        s.AddFile("Mine.txt", "mine"u8.ToArray());
        var (fake, b, _) = await Connect(s);
        var trip = await Node(b, "Team Trip");
        Assert.True(trip is { IsFolder: true, IsShared: true, ParentID: "root", ChildCount: 1 });
        var inside = await b.ListAsync(trip.Id);
        Assert.Equal(["Itinerary.txt"], inside.Select(n => n.Name));
        Assert.Equal(trip.Id, inside[0].ParentID);
        var dest = Path.Combine(TestEnv.TempDir("onedrive"), "it.txt");
        await b.DownloadAsync(inside[0], dest, null);
        Assert.Equal("Day 1", File.ReadAllText(dest));
        var added = await b.UploadAsync(FileWith("notes"u8.ToArray()), "Notes.txt", trip.Id, null, null);
        Assert.Equal(trip.Id, added.ParentID);
        Assert.NotNull(fake.S.Child("Notes.txt", shared.Folder));
        Assert.Equal(2, (await b.ListAsync(trip.Id)).Count);
        var mine = await Node(b, "Mine.txt");
        await Fails(CloudErrorKind.Unsupported, () => b.MoveAsync([mine], trip.Id));
        await b.TrashAsync([trip]);
        Assert.Null(fake.S.Live(shared.Shortcut));
        Assert.NotNull(fake.S.Live(shared.Folder));   // the owner's folder is untouched
    }

    [Fact]
    public async Task DemoAccountBrowsesGenericSampleContentThroughTheRouter()
    {
        var fake = FakeGraphServer.Demo();
        var router = new FakeCloudRouter(fake);
        var demo = Assert.Single(router.DemoAccounts());
        Assert.Equal(("cloud:onedrive:demo", CloudProvider.OneDrive, "alex@example.com"), (demo.Record.Id, demo.Record.Provider, demo.Record.Title));
        var b = OneDriveCloud.Make(demo.Record, demo.Secret, router);
        Assert.Equal((CloudProvider.OneDrive, "root"), (b.Provider, b.RootID));
        var saved = new List<string>();
        ((ICloudTokenRotating)b).OnNewRefreshToken = saved.Add;
        var root = await b.ListAsync(b.RootID);
        Assert.Equal(["Documents", "Pictures", "Read Me.txt"], root.Select(n => n.Name).Order());
        Assert.Single(saved);
        var docs = await b.ListAsync(root.Single(n => n.Name == "Documents").Id);
        Assert.Equal(["Budget.csv", "Meeting Notes.txt"], docs.Select(n => n.Name).Order());
        var pics = await b.ListAsync(root.Single(n => n.Name == "Pictures").Id);
        Assert.Equal(2, pics.Count);
        var thumb = Assert.IsType<byte[]>(await b.ThumbnailAsync(pics[0], 128));
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, thumb[..4]);
        Assert.NotNull(await b.QuotaAsync());
        // Asking again gives the same content (with a token of its own), and a browser sign-in works without a browser.
        var again = Assert.Single(router.DemoAccounts());
        Assert.Equal(3, (await OneDriveCloud.Make(again.Record, again.Secret, router).ListAsync("root")).Count);
        var signedIn = await OneDriveCloud.SignInAsync(fake.ClientID, url => fake.ApproveAsync(url), router);
        Assert.Equal("alex@example.com", signedIn.Record.Title);
        Assert.Equal(3, (await OneDriveCloud.Make(signedIn.Record, signedIn.Secret, router).ListAsync("root")).Count);
    }

    [Fact]
    public async Task CloudBackendsBuildOneDriveThroughTheSharedTransport()
    {
        var fake = FakeGraphServer.Demo();
        var saved = CloudBackends.Transport;
        try
        {
            CloudBackends.Transport = new FakeCloudRouter(fake);
            var demo = Assert.Single(fake.DemoAccounts());
            var b = Assert.IsType<OneDriveBackend>(CloudBackends.Make(demo.Record, demo.Secret));
            Assert.Equal(3, (await b.ListAsync("root")).Count);
        }
        finally { CloudBackends.Transport = saved; }
    }
}
