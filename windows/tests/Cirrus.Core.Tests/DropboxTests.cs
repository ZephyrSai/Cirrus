using System.Text;
using System.Text.Json.Nodes;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>Dropbox connector against FakeDropboxServer (port of DropboxTests.swift). Never touches the real network.</summary>
public class DropboxTests
{
    static byte[] Bytes(int n, int seed = 7) => Enumerable.Range(0, n).Select(i => (byte)(((i * 31) ^ (i >> 9)) + seed)).ToArray();

    static string LocalFile(byte[] data, string name = "src.bin")
    {
        var p = Path.Combine(TestEnv.TempDir("dbx"), name);
        File.WriteAllBytes(p, data);
        return p;
    }

    static Dictionary<string, string> Query(Uri u)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in u.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            q[Uri.UnescapeDataString(kv[0])] = kv.Length > 1 ? Uri.UnescapeDataString(kv[1]) : "";
        }
        return q;
    }

    static void SetEqual(IEnumerable<string> expected, IEnumerable<string> actual) =>
        Assert.Equal(expected.Order(StringComparer.Ordinal), actual.Order(StringComparer.Ordinal));

    /// <summary>The browser sign-in through the real loopback listener, as the app runs it.</summary>
    static Task<CloudConnection> SignIn(FakeDropboxServer fake, Func<Uri, Task>? open = null, HttpMessageHandler? transport = null) =>
        DropboxCloud.SignInOnPortsAsync(fake.S.AppKey, open ?? (u => fake.ApproveAsync(u)), transport ?? fake, DropboxCloud.RedirectPorts,
            TimeSpan.FromSeconds(30), CancellationToken.None);

    /// <summary>Signs in with the paste-a-code flow (no sockets) and builds the account's backend.</summary>
    static async Task<(DropboxBackend B, CloudConnection C, FakeDropboxServer F)> Connect(FakeDropboxServer.State? s = null)
    {
        var fake = new FakeDropboxServer(s);
        var pending = DropboxCloud.BeginCodeSignIn(fake.S.AppKey);
        var c = await pending.FinishAsync(fake.DisplayedCode(pending.AuthorizationURL)!, fake);
        var b = DropboxCloud.Backend(c.Record, c.Secret, fake);
        b.RetryBase = 0.001;
        return (b, c, fake);
    }

    static Task<CloudException> Fails(Func<Task> op) => Assert.ThrowsAsync<CloudException>(op);

    static async Task<DriveNode> Named(DropboxBackend b, string name, string folder = "root") =>
        Assert.Single(await b.ListAsync(folder), n => n.Name == name);

    static int CallCount(FakeDropboxServer f, string suffix) => f.S.Calls.Count(c => c.EndsWith(suffix, StringComparison.Ordinal));

    // MARK: Sign-in

    [Fact]
    public async Task SignInRunsPkceThroughAFixedLoopbackPortAndNamesTheAccount()
    {
        var fake = new FakeDropboxServer();
        Uri? seen = null;
        var c = await SignIn(fake, async u => { seen = u; await fake.ApproveAsync(u); });
        Assert.Equal(CloudProvider.Dropbox, c.Record.Provider);
        Assert.Equal("alex@example.com", c.Record.Title);
        Assert.StartsWith("cloud:dropbox:", c.Record.Id);
        Assert.Null(c.Record.Options);   // a personal account: paths start at its own root
        Assert.Equal(fake.S.AppKey, c.Secret.ClientID);
        Assert.Null(c.Secret.ClientSecret);
        Assert.Null(c.Secret.Password);
        Assert.Contains(c.Secret.RefreshToken, fake.S.ValidRefreshTokens);
        Assert.NotNull(seen);
        var q = Query(seen!);
        Assert.Equal("www.dropbox.com", seen!.Host);
        Assert.Equal("/oauth2/authorize", seen.AbsolutePath);
        Assert.Equal("code", q["response_type"]);
        Assert.Equal("offline", q["token_access_type"]);
        Assert.Equal("S256", q["code_challenge_method"]);
        Assert.Equal(43, q["code_challenge"].Length);
        Assert.Equal("http://localhost:47823", q["redirect_uri"]);   // the first registered port, when it's free
        SetEqual(DropboxCloud.Scopes, q["scope"].Split(' '));
        Assert.True(q["state"].Length >= 30);
        Assert.Equal(fake.S.AppKey, q["client_id"]);
        SetEqual(["grant_type", "code", "redirect_uri", "code_verifier", "client_id"], Assert.Single(fake.S.TokenRequestKeys));
        Assert.Contains("POST api.dropboxapi.com/2/users/get_current_account", fake.S.Calls);
        // What the App Console needs, exactly as Cirrus sends it.
        Assert.Equal(["http://localhost:47823", "http://localhost:47824", "http://localhost:47825"], DropboxCloud.RedirectURIs);
        Assert.Contains("http://localhost:47823", DropboxCloud.NotConfiguredMessage);
    }

    [Fact]
    public async Task SignInMovesToTheNextRegisteredPortWhenOneIsTakenAndPointsAtTheCodeWhenAllAre()
    {
        var fake = new FakeDropboxServer();
        using (var first = LoopbackReceiver.TryOpen("Dropbox", DropboxCloud.RedirectPorts[0], localhostName: true))
        {
            Assert.NotNull(first);
            // The port is really held (127.0.0.1 and ::1): a second listener can't have it.
            Assert.Null(LoopbackReceiver.TryOpen("Dropbox", DropboxCloud.RedirectPorts[0], localhostName: true));
            Uri? seen = null;
            await SignIn(fake, async u => { seen = u; await fake.ApproveAsync(u); });
            var redirect = Query(seen!)["redirect_uri"];
            Assert.NotEqual(DropboxCloud.RedirectURIs[0], redirect);
            Assert.Contains(redirect, DropboxCloud.RedirectURIs);

            using var second = LoopbackReceiver.TryOpen("Dropbox", DropboxCloud.RedirectPorts[1], localhostName: true);
            using var third = LoopbackReceiver.TryOpen("Dropbox", DropboxCloud.RedirectPorts[2], localhostName: true);
            Assert.NotNull(second);
            Assert.NotNull(third);
            var opened = false;
            var e = await Fails(() => SignIn(fake, _ => { opened = true; return Task.CompletedTask; }));
            Assert.Equal(CloudErrorKind.NotConfigured, e.Kind);
            Assert.Equal(DropboxCloud.PortsBusyMessage, e.Message);
            Assert.Contains("code", e.Message);
            Assert.False(opened);
        }
        // Free again: the first port is used.
        Uri? again = null;
        await SignIn(fake, async u => { again = u; await fake.ApproveAsync(u); });
        Assert.Equal(DropboxCloud.RedirectURIs[0], Query(again!)["redirect_uri"]);
    }

    [Fact]
    public async Task PasteACodeSignInNeedsNoRedirect()
    {
        var fake = new FakeDropboxServer();
        Uri? shown = null;
        string? code = null;
        var c = await DropboxCloud.SignInWithCodeAsync(fake.S.AppKey, u =>
        {
            shown = u;
            code = fake.DisplayedCode(u);
            return Task.CompletedTask;
        }, _ => Task.FromResult($"  {code}\n"), fake);   // pasted with stray spaces
        Assert.Equal("alex@example.com", c.Record.Title);
        Assert.NotNull(c.Secret.RefreshToken);
        Assert.Equal(fake.S.AppKey, c.Secret.ClientID);
        var q = Query(shown!);
        Assert.False(q.ContainsKey("redirect_uri"));
        Assert.False(q.ContainsKey("state"));
        Assert.Equal("offline", q["token_access_type"]);
        Assert.Equal("S256", q["code_challenge_method"]);
        SetEqual(["grant_type", "code", "code_verifier", "client_id"], Assert.Single(fake.S.TokenRequestKeys));

        // The two-step form, for a dialog with a text field.
        var pending = DropboxCloud.BeginCodeSignIn(fake.S.AppKey);
        Assert.Equal(fake.S.AppKey, pending.AppKey);
        var c1 = fake.DisplayedCode(pending.AuthorizationURL)!;
        var wrong = await Fails(() => pending.FinishAsync("not-the-code", fake));
        Assert.Equal(CloudErrorKind.Denied, wrong.Kind);
        Assert.Contains("code", wrong.Message);
        Assert.Equal("alex@example.com", (await pending.FinishAsync(c1, fake)).Record.Title);
        Assert.Equal(CloudErrorKind.Denied, (await Fails(() => pending.FinishAsync(c1, fake))).Kind);   // a code works once
        var empty = await Fails(() => pending.FinishAsync("  ", fake));
        Assert.Equal("Paste the code Dropbox showed after you chose Allow.", empty.Message);
        // A different code verifier (another sign-in's) doesn't redeem this one's code.
        var other = DropboxCloud.BeginCodeSignIn(fake.S.AppKey);
        var c2 = fake.DisplayedCode(pending.AuthorizationURL)!;
        Assert.Equal(CloudErrorKind.Denied, (await Fails(() => other.FinishAsync(c2, fake))).Kind);
    }

    [Fact]
    public async Task SignInRejectsDeniedConsentForgedStateAndMissingPermissions()
    {
        var fake = new FakeDropboxServer();
        var denied = await Fails(() => SignIn(fake, u => fake.ApproveAsync(u, deny: true)));
        Assert.Equal(CloudErrorKind.Denied, denied.Kind);
        Assert.Contains("Allow", denied.Message);

        var forged = await Fails(() => SignIn(fake, async u =>
        {
            if (fake.Authorize(u) is not FakeDropboxServer.Authorization.Redirect back) return;
            var q = Query(back.Target);
            q["state"] = "forged";
            await FakeDropboxServer.VisitAsync(new Uri(back.Target.GetLeftPart(UriPartial.Path) + "?"
                + string.Join('&', q.Select(kv => kv.Key + "=" + Uri.EscapeDataString(kv.Value)))));
        }));
        Assert.Equal(CloudErrorKind.Denied, forged.Kind);
        Assert.Contains("didn’t match", forged.Message);
        Assert.Empty(fake.S.TokenRequestKeys);   // the code was never redeemed

        // The app in the App Console lacks a permission Cirrus asks for: Dropbox redirects with invalid_scope.
        var noWrite = new FakeDropboxServer.State();
        noWrite.AppScopes.Remove("files.content.write");
        fake.Reset(noWrite);
        var scope = await Fails(() => SignIn(fake));
        Assert.Equal(CloudErrorKind.Denied, scope.Kind);
        Assert.Contains("files.content.write", scope.Message);

        // Dropbox grants fewer scopes than asked: caught before the account is saved.
        fake.Reset(new FakeDropboxServer.State { GrantedScopes = ["account_info.read", "files.metadata.read", "files.content.read"] });
        var granted = await Fails(() => SignIn(fake));
        Assert.Equal(CloudErrorKind.NotConfigured, granted.Kind);
        Assert.Contains("files.metadata.write", granted.Message);
        Assert.Contains("files.content.write", granted.Message);
        Assert.Contains("Permissions", granted.Message);
    }

    [Fact]
    public async Task SignInGivesUpWithASentenceWhenTheBrowserNeverComesBack()
    {
        var fake = new FakeDropboxServer();
        var e = await Fails(() => DropboxCloud.SignInOnPortsAsync(fake.S.AppKey, _ => Task.CompletedTask, fake, DropboxCloud.RedirectPorts,
            TimeSpan.FromMilliseconds(200), CancellationToken.None));
        Assert.Equal("Timed out waiting for you to finish signing in to Dropbox in your browser.", e.Message);
        using var cts = new CancellationTokenSource(200);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => DropboxCloud.SignInAsync(fake.S.AppKey, _ => Task.CompletedTask, fake, cts.Token));
    }

    [Fact]
    public async Task FakeAuthorizeAndTokenEndpointsAreStrict()
    {
        var fake = new FakeDropboxServer();
        var key = fake.S.AppKey;
        var pkce = new Pkce();
        // Redirect URIs must match a registered one exactly (port and trailing slash included).
        foreach (var bad in new[] { "http://localhost:5555", "http://localhost:47823/", "http://127.0.0.1:47823" })
            Assert.IsType<FakeDropboxServer.Authorization.ErrorPage>(fake.Authorize(DropboxAuth.AuthorizationURL(key, bad, pkce, "s")));
        Assert.IsType<FakeDropboxServer.Authorization.ErrorPage>(fake.Authorize(DropboxAuth.AuthorizationURL("someone-else", null, pkce, null)));
        fake.Reset(new FakeDropboxServer.State { AllowPublicClients = false });
        Assert.IsType<FakeDropboxServer.Authorization.ErrorPage>(fake.Authorize(DropboxAuth.AuthorizationURL(key, null, pkce, null)));
        fake.Reset();
        var back = Assert.IsType<FakeDropboxServer.Authorization.Redirect>(fake.Authorize(DropboxAuth.AuthorizationURL(key, "http://localhost:47824", pkce, "s")));
        Assert.StartsWith("http://localhost:47824/?", back.Target.AbsoluteUri);
        var code = Query(back.Target)["code"];
        using var http = CloudBackends.Http(fake);
        var wrong = await Fails(() => DropboxAuth.RedeemAsync(new()
        {
            ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = "http://localhost:47824", ["code_verifier"] = new Pkce().Verifier,
        }, key, http, signingIn: true));
        Assert.Equal(CloudErrorKind.Server, wrong.Kind);
        Assert.Contains("invalid code verifier", wrong.Message);
        // Refreshing with an unknown token: sign in again.
        var refresh = await Fails(() => DropboxAuth.RedeemAsync(new() { ["grant_type"] = "refresh_token", ["refresh_token"] = "nope" }, key, http, signingIn: false));
        Assert.Equal(CloudErrorKind.SignInNeeded, refresh.Kind);
        // Another app key: Cirrus explains what to check.
        var client = await Fails(() => DropboxAuth.RedeemAsync(new() { ["grant_type"] = "refresh_token", ["refresh_token"] = "nope" }, "other", http, signingIn: false));
        Assert.Equal(CloudErrorKind.NotConfigured, client.Kind);
        Assert.Contains("PKCE", client.Message);
        // The authorize page itself, fetched like a browser would: the code to copy.
        using var browser = new HttpClient(fake, disposeHandler: false);
        var page = await browser.GetStringAsync(DropboxCloud.BeginCodeSignIn(key).AuthorizationURL);
        Assert.Contains("Enter this code", page);
        Assert.Empty(fake.S.TokensSentElsewhere);
    }

    [Fact]
    public async Task AppKeyComesFromTheSecretOrTheDefault()
    {
        var saved = DropboxCloud.DefaultAppKey;
        try
        {
            DropboxCloud.DefaultAppKey = "";
            var record = new CloudAccountRecord(CloudProvider.Dropbox, "x");
            var e = Assert.Throws<CloudException>(() => DropboxCloud.Make(record, new CloudSecret { RefreshToken = "rt" }, null));
            Assert.Equal(CloudErrorKind.NotConfigured, e.Kind);
            Assert.Equal(DropboxCloud.NotConfiguredMessage, e.Message);
            var fake = new FakeDropboxServer();
            Assert.Equal(CloudErrorKind.NotConfigured, (await Fails(() => DropboxCloud.SignInAsync("  ", _ => Task.CompletedTask, fake))).Kind);
            Assert.Equal(CloudErrorKind.NotConfigured, Assert.Throws<CloudException>(() => DropboxCloud.BeginCodeSignIn("")).Kind);
            DropboxCloud.DefaultAppKey = "defaultappkey12";
            Assert.Equal("defaultappkey12", DropboxCloud.Backend(record, new CloudSecret { RefreshToken = "rt" }, null).Secret.ClientID);
            Assert.Equal("ownappkey", DropboxCloud.Backend(record, new CloudSecret { RefreshToken = "rt", ClientID = " ownappkey " }, null).Secret.ClientID);
            Assert.Equal(CloudErrorKind.SignInNeeded, Assert.Throws<CloudException>(() => DropboxCloud.Make(record, new CloudSecret(), null)).Kind);
            // Through the app's factory: a token-rotating Dropbox backend.
            var made = CloudBackends.Make(record, new CloudSecret { RefreshToken = "rt" });
            Assert.IsType<DropboxBackend>(made);
            Assert.IsAssignableFrom<ICloudTokenRotating>(made);
            Assert.Equal(CloudProvider.Dropbox, made.Provider);
            Assert.Equal("root", made.RootID);
            Assert.False(made.CanListTrash);
        }
        finally { DropboxCloud.DefaultAppKey = saved; }
    }

    // MARK: Tokens

    [Fact]
    public async Task RefreshIsSharedByConcurrentRequestsAndANewRefreshTokenIsHandedOn()
    {
        var (b, c, fake) = await Connect();
        var saved = new List<string>();
        b.OnNewRefreshToken = rt => { lock (saved) saved.Add(rt); };
        await b.ListAsync("root");                       // no access token yet: refresh #1
        Assert.Equal(1, fake.S.Refreshes);
        fake.Update(s => s.ExpireAccessTokens());
        await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => b.ListAsync("root")));
        Assert.Equal(2, fake.S.Refreshes);              // eight expired tokens, one shared refresh
        Assert.Empty(saved);
        Assert.Equal(c.Secret.RefreshToken, b.Secret.RefreshToken);   // Dropbox keeps the same refresh token

        // Should Dropbox ever rotate it, the new one is handed on and the old one stops working.
        fake.Update(s => { s.RotateRefreshTokens = true; s.ExpireAccessTokens(); });
        await b.ListAsync("root");
        var latest = Assert.Single(saved);
        Assert.Equal(latest, b.Secret.RefreshToken);
        Assert.NotEqual(c.Secret.RefreshToken, latest);
        Assert.Equal([latest], fake.S.ValidRefreshTokens);
        await DropboxCloud.Backend(c.Record, c.Secret with { RefreshToken = latest }, fake).ListAsync("root");
    }

    [Fact]
    public async Task ExpiredTokensRefreshQuietlyAndARevokedSignInAsksToSignInAgain()
    {
        var (b, _, fake) = await Connect();
        await b.ListAsync("root");
        fake.Update(s => s.ExpireAccessTokens());
        await b.ListAsync("root");
        Assert.Equal(2, fake.S.Refreshes);
        Assert.Contains(fake.S.Calls, c => c.EndsWith("list_folder", StringComparison.Ordinal));
        fake.Update(s => s.RevokeRefreshTokens());   // e.g. removed under dropbox.com › Connected apps
        var e = await Fails(() => b.ListAsync("root"));
        Assert.Equal(CloudErrorKind.SignInNeeded, e.Kind);
        Assert.Equal("Dropbox needs you to sign in again.", e.Message);
    }

    [Fact]
    public void ErrorAnswersBecomeSentences()
    {
        static DropboxResponse Resp(int status, JsonNode body) => new(status, Encoding.UTF8.GetBytes(body.ToJsonString()));
        static DropboxResponse Summary(string s) => Resp(409, new JsonObject { ["error_summary"] = s, ["error"] = new JsonObject { [".tag"] = "x" } });
        Assert.Equal("There’s already an item named “A.txt” in that folder on Dropbox.", DropboxHttp.Error(Summary("path/conflict/file/.."), "A.txt").Message);
        Assert.Equal(CloudErrorKind.NotFound, DropboxHttp.Error(Summary("path_lookup/not_found/..")).Kind);
        var full = DropboxHttp.Error(Summary("path/insufficient_space/.."));
        Assert.Equal(CloudErrorKind.QuotaExceeded, full.Kind);
        Assert.Equal("There isn’t enough space in Dropbox.", full.Message);
        Assert.Equal("A folder can’t be moved into itself or into a folder inside it.", DropboxHttp.Error(Summary("cant_move_folder_into_itself/..")).Message);
        Assert.Equal(CloudErrorKind.Unsupported, DropboxHttp.Error(Summary("unsupported_file/.."), "Plan.paper").Kind);
        Assert.Equal("The item isn’t a folder on Dropbox.", DropboxHttp.Error(Summary("path/not_folder/..")).Message);
        var scope = DropboxHttp.Error(Resp(401, new JsonObject
        {
            ["error_summary"] = "missing_scope/..", ["error"] = new JsonObject { [".tag"] = "missing_scope", ["required_scope"] = "files.content.write" },
        }));
        Assert.Equal(CloudErrorKind.Denied, scope.Kind);
        Assert.Contains("“files.content.write” permission", scope.Message);
        Assert.Equal(CloudErrorKind.SignInNeeded, DropboxHttp.Error(Resp(401, new JsonObject { ["error"] = new JsonObject { [".tag"] = "invalid_access_token" } })).Kind);
        Assert.Equal(CloudErrorKind.SignInNeeded, DropboxHttp.Error(Resp(422, new JsonObject { ["error_summary"] = "invalid_root/.." })).Kind);
        Assert.Contains("limiting", DropboxHttp.Error(Resp(429, new JsonObject())).Message);
        Assert.Equal("Dropbox had a problem (HTTP 502). Try again later.", DropboxHttp.Error(Resp(502, new JsonObject())).Message);
    }

    [Fact]
    public async Task RateLimitsAndWriteContentionAreRetried()
    {
        var s = new FakeDropboxServer.State();
        s.AddFile("A.txt", "a"u8.ToArray());
        var (b, _, fake) = await Connect(s);
        fake.Update(x => x.ThrottleNext = 3);
        Assert.Equal(["A.txt"], (await b.ListAsync("root")).Select(n => n.Name));
        Assert.Equal(0, fake.S.ThrottleNext);
        fake.Update(x => x.WriteContentionNext = 3);
        await b.CreateFolderAsync("Busy", "root");
        Assert.Equal(3, fake.S.Contentions);
        Assert.NotNull(fake.S.Child("Busy"));
        fake.Update(x => x.ThrottleNext = 50);
        var e = await Fails(() => b.ListAsync("root"));
        Assert.Equal(CloudErrorKind.Server, e.Kind);
        Assert.Contains("limiting", e.Message);
    }

    [Fact]
    public async Task WritesGoOneAtATime()
    {
        // The gate: one at a time by default, more when allowed, and cancellable while waiting.
        var gate = new DropboxGate(1);
        int running = 0, peak = 0;
        var peakLock = new object();
        Task Burst(int n) => Task.WhenAll(Enumerable.Range(0, n).Select(_ => gate.RunAsync(async () =>
        {
            var now = Interlocked.Increment(ref running);
            lock (peakLock) peak = Math.Max(peak, now);
            await Task.Delay(5);
            Interlocked.Decrement(ref running);
            return 0;
        }, CancellationToken.None)));
        await Burst(8);
        Assert.Equal(1, peak);
        peak = 0;
        gate.Limit = 3;
        await Burst(9);
        Assert.InRange(peak, 2, 3);
        gate.Limit = 1;
        var holder = gate.RunAsync(async () => { await Task.Delay(150); return 0; }, CancellationToken.None);
        await Task.Delay(20);
        using var cts = new CancellationTokenSource();
        var waiter = gate.RunAsync(() => Task.FromResult(1), cts.Token);
        await Task.Delay(20);
        Assert.False(waiter.IsCompleted);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiter);
        await holder;
        Assert.Equal(2, await gate.RunAsync(() => Task.FromResult(2), CancellationToken.None));   // the slot came back

        // Through the backend: concurrent changes reach Dropbox one by one, with no contention.
        var (b, _, fake) = await Connect();
        fake.Update(s => s.Latency = 0.01);   // long enough for overlapping writes to collide
        await Task.WhenAll(Enumerable.Range(0, 6).Select(i => b.CreateFolderAsync($"Folder {i}", "root")));
        Assert.Equal(1, fake.S.MaxConcurrentWrites);
        Assert.Equal(0, fake.S.Contentions);
        Assert.Equal(6, fake.S.Children("").Count);
        Assert.Equal(1, b.WriteConcurrency);
    }

    // MARK: Listing

    [Fact]
    public async Task ListingFollowsCursorsAndNormalizesTheRoot()
    {
        var s = new FakeDropboxServer.State();
        var docs = s.AddFolder("Documents");
        for (int i = 0; i < 7; i++) s.AddFile($"Note {i}.txt", Encoding.UTF8.GetBytes($"note {i}"), docs, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000 + i));
        s.AddFile("Top.txt", "top"u8.ToArray());
        var team = s.AddFolder("Team");
        s.Share(team);
        s.AddPaperDoc("Plan.paper");
        var (b, _, fake) = await Connect(s);
        var root = await b.ListAsync("root");
        SetEqual(["Documents", "Top.txt", "Team", "Plan.paper"], root.Select(n => n.Name));
        Assert.All(root, n =>
        {
            Assert.Equal("root", n.ParentID);
            Assert.Equal("dropbox", n.Zone);
            Assert.StartsWith("id:", n.Id);
            Assert.StartsWith("/", n.DocID);
        });
        var d = root.Single(n => n.Name == "Documents");
        Assert.Equal(docs, d.Id);
        Assert.Equal("FOLDER", d.Type);
        Assert.True(d.IsFolder);
        Assert.Equal(0, d.Size);
        Assert.Equal("/Documents", d.DocID);
        Assert.False(d.IsShared);
        Assert.True(root.Single(n => n.Name == "Team").IsShared);
        var top = root.Single(n => n.Name == "Top.txt");
        Assert.Equal("FILE", top.Type);
        Assert.Equal(3, top.Size);
        Assert.NotNull(top.Etag);
        Assert.Equal(FakeDropboxServer.SeedDate, top.Modified);

        var notes = await b.ListAsync(docs);
        Assert.Equal(7, notes.Count);
        Assert.All(notes, n => { Assert.Equal(docs, n.ParentID); Assert.Equal("FILE", n.Type); });
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_003), notes.Single(n => n.Name == "Note 3.txt").Modified);
        Assert.Equal("/Documents/Note 3.txt", notes.Single(n => n.Name == "Note 3.txt").DocID);
        Assert.Equal(3, fake.S.Calls.Count(c => c == "POST api.dropboxapi.com/2/files/list_folder/continue"));   // root 3+1, docs 3+3+1

        var many = await b.ListManyAsync(["root", docs, "root"]);
        Assert.Equal(2, many.Count);
        Assert.Equal(7, many[docs].Count);
        Assert.Equal(4, many["root"].Count);
        // A folder that can't be listed throws: it must never look empty.
        Assert.Equal(CloudErrorKind.NotFound, (await Fails(() => b.ListManyAsync(["root", "id:FakeDbxAAAAAAAAAA999999"]))).Kind);
        Assert.Equal(CloudErrorKind.Denied, (await Fails(() => b.ListAsync(top.Id))).Kind);

        // Dropbox invalidates a cursor: the folder is listed again from the start, not left half-listed.
        fake.Update(x => x.ResetCursorsNext = 1);
        Assert.Equal(7, (await b.ListAsync(docs)).Count);
        Assert.Equal(4, (await b.ListAsync("")).Count);   // "" is the top too
    }

    // MARK: Uploads

    [Fact]
    public async Task SmallUploadAddsWithTheDateAndRoundTrips()
    {
        var (b, _, fake) = await Connect();
        var data = Bytes(10_000);
        var when = DateTimeOffset.FromUnixTimeMilliseconds(1_750_000_000_750);
        (long, long) last = (0, 0);
        var n = await b.UploadAsync(LocalFile(data), "Report.pdf", "root", when, (done, total) => last = (done, total));
        Assert.Equal("Report.pdf", n.Name);
        Assert.Equal("root", n.ParentID);
        Assert.Equal(10_000, n.Size);
        Assert.Equal("FILE", n.Type);
        Assert.StartsWith("id:", n.Id);
        Assert.True(Math.Abs((n.Modified!.Value - when).TotalSeconds) < 1);
        Assert.Equal((10_000L, 10_000L), last);
        var st = fake.S;
        Assert.Equal(1, st.SimpleUploads);
        Assert.Equal(0, st.SessionsStarted);
        var c = st.LastCommit;
        Assert.Equal("/Report.pdf", c["path"].Str);
        Assert.Equal("add", c["mode"].Str);
        Assert.False(c["autorename"].Bool);
        Assert.True(c["strict_conflict"].Bool);
        Assert.False(c["mute"].Bool);
        Assert.Equal("2025-06-15T15:06:40Z", c["client_modified"].Str);
        Assert.Equal(data, st.Blobs[st.Child("Report.pdf")!.Id]);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_750_000_000), (await Named(b, "Report.pdf")).Modified);

        var folder = await b.CreateFolderAsync("Inbox", "root");
        var empty = await b.UploadAsync(LocalFile([], "e"), "Empty.txt", folder.Id, null, null);
        Assert.Equal(0, empty.Size);
        Assert.Equal(folder.Id, empty.ParentID);
        Assert.Equal("/Inbox/Empty.txt", fake.S.LastCommit["path"].Str);
        Assert.True(fake.S.LastCommit["client_modified"].IsNull);
        Assert.Equal(0, fake.S.AutoCreatedFolders);
    }

    [Fact]
    public async Task SessionUploadResumesFromTheOffsetDropboxReports()
    {
        var s = new FakeDropboxServer.State
        {
            LoseAppendAnswer = 2,        // Dropbox stored chunk 2, but its answer was lost
            DropAppendBeforeStore = 4,   // chunk 4 broke off before Dropbox stored any of it
        };
        var (b, _, fake) = await Connect(s);
        b.SimpleUploadLimit = 100_000;
        b.ChunkSize = 300_000;
        var folder = await b.CreateFolderAsync("Videos", "root");
        var data = Bytes(1_000_000);
        var when = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000);
        (long, long) last = (0, 0);
        var n = await b.UploadAsync(LocalFile(data), "Clip.mov", folder.Id, when, (done, total) => last = (done, total));
        Assert.Equal(1_000_000, n.Size);
        Assert.Equal(folder.Id, n.ParentID);
        Assert.Equal("Clip.mov", n.Name);
        Assert.Equal(when, n.Modified);
        Assert.Equal((1_000_000L, 1_000_000L), last);
        var st = fake.S;
        Assert.Equal(data, st.Blobs[n.Id]);
        // Chunk 2 wasn't sent twice: Dropbox said it already had 600000 bytes.
        Assert.Equal([0L, 300_000L, 600_000L, 900_000L], st.Appends.Select(a => a.Offset));
        Assert.Equal([300_000, 300_000, 300_000, 100_000], st.Appends.Select(a => a.Size));
        Assert.Equal(1, st.SessionsStarted);
        Assert.Equal(1, st.Finishes);
        Assert.Equal(0, st.SimpleUploads);
        Assert.Equal(0, st.OpenUploadSessions);
        Assert.Equal("/Videos/Clip.mov", st.LastCommit["path"].Str);
        Assert.Equal("add", st.LastCommit["mode"].Str);
        Assert.Equal("2025-10-09T08:53:20Z", st.LastCommit["client_modified"].Str);
    }

    [Fact]
    public async Task LostUploadAnswersAreRecognisedByContentHash()
    {
        var (b, _, fake) = await Connect();
        fake.Update(s => s.LoseUploadAnswers = 1);
        var small = await b.UploadAsync(LocalFile(Bytes(5_000)), "Small.bin", "root", null, null);
        Assert.Equal(5_000, small.Size);
        Assert.Equal(1, fake.S.SimpleUploads);

        b.SimpleUploadLimit = 0;
        b.ChunkSize = 300_000;
        fake.Update(s => s.LoseUploadAnswers = 1);
        var big = await b.UploadAsync(LocalFile(Bytes(700_000)), "Big.bin", "root", null, null);
        Assert.Equal(700_000, big.Size);
        Assert.Equal("root", big.ParentID);
        SetEqual(["Big.bin", "Small.bin"], fake.S.Children("").Select(i => i.Name));
        Assert.Equal(1, fake.S.Finishes);
        Assert.Equal(Bytes(700_000), fake.S.Blobs[big.Id]);
        // More than two 4 MiB blocks, each hashed on its own.
        var blocks = Enumerable.Repeat((byte)0xAB, 9_000_000).ToArray();
        blocks[4_194_304] = 1;
        Assert.Equal(FakeDropboxServer.ContentHash(blocks), DropboxBackend.ContentHash(LocalFile(blocks)));
        // Dropbox's documented hash of an empty file: SHA-256 of nothing.
        Assert.Equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", DropboxBackend.ContentHash(LocalFile([])));
    }

    [Fact]
    public async Task NameConflictsFailClearlyInsteadOfReplacing()
    {
        var s = new FakeDropboxServer.State();
        s.AddFile("Taken.txt", "old"u8.ToArray());
        s.AddFolder("Docs");
        var (b, _, fake) = await Connect(s);
        foreach (var limit in new long[] { 8 << 20, 0 })   // one request, then an upload session
        {
            b.SimpleUploadLimit = limit;
            foreach (var content in new[] { "new", "old" })   // the same bytes are a conflict too (strict_conflict)
            {
                var e = await Fails(() => b.UploadAsync(LocalFile(Encoding.UTF8.GetBytes(content)), "taken.txt", "root", null, null));
                Assert.Equal(CloudErrorKind.Denied, e.Kind);
                Assert.Equal("There’s already an item named “taken.txt” in that folder on Dropbox.", e.Message);
            }
        }
        Assert.Equal("old"u8.ToArray(), fake.S.Blobs[fake.S.Child("Taken.txt")!.Id]);
        Assert.Equal(2, fake.S.Children("").Count);

        var folder = await Fails(() => b.CreateFolderAsync("docs", "root"));
        Assert.Equal(CloudErrorKind.Denied, folder.Kind);
        Assert.Contains("“docs”", folder.Message);
        Assert.Equal(CloudErrorKind.Denied, (await Fails(async () => await b.RenameAsync(await Named(b, "Taken.txt"), "Docs"))).Kind);
    }

    [Fact]
    public async Task AFolderDeletedElsewhereIsNeverRecreated()
    {
        var s = new FakeDropboxServer.State();
        var gone = s.AddFolder("Old Project");
        s.AddFile("Keep.txt", "k"u8.ToArray());
        var (b, _, fake) = await Connect(s);
        var target = await Named(b, "Old Project");
        var keep = await Named(b, "Keep.txt");
        fake.Update(x => x.Items[gone].Deleted = true);   // deleted on another device
        Assert.Equal(CloudErrorKind.NotFound, (await Fails(() => b.UploadAsync(LocalFile("x"u8.ToArray()), "New.txt", target.Id, null, null))).Kind);
        Assert.Equal(CloudErrorKind.NotFound, (await Fails(() => b.CreateFolderAsync("Sub", target.Id))).Kind);
        Assert.Equal(CloudErrorKind.NotFound, (await Fails(() => b.MoveAsync([keep], target.Id))).Kind);
        Assert.Equal(0, fake.S.AutoCreatedFolders);
        Assert.Null(fake.S.Child("Old Project"));
        Assert.NotNull(fake.S.Child("Keep.txt"));
    }

    [Fact]
    public async Task UploadIntoAFolderRenamedElsewhereFollowsIt()
    {
        var s = new FakeDropboxServer.State();
        var f = s.AddFolder("Draft");
        var (b, _, fake) = await Connect(s);
        var draft = await Named(b, "Draft");
        fake.Update(x => x.Items[f].Name = "Final");   // renamed on another device
        var n = await b.UploadAsync(LocalFile("x"u8.ToArray()), "Notes.txt", draft.Id, null, null);
        Assert.Equal(draft.Id, n.ParentID);
        Assert.NotNull(fake.S.Child("Notes.txt", f));
        Assert.Equal(0, fake.S.AutoCreatedFolders);
        Assert.Null(fake.S.Child("Draft"));
    }

    [Fact]
    public async Task QuotaForPersonalAndTeamAccountsAndAFullDropbox()
    {
        var s = new FakeDropboxServer.State { Allocated = 1_000_000 };
        s.AddFile("A.bin", new byte[200_000]);
        var gone = s.AddFile("B.bin", new byte[50_000]);
        s.Items[gone].Deleted = true;   // deleted files don't count
        var (b, _, fake) = await Connect(s);
        var u = (await b.QuotaAsync())!;
        Assert.Equal(1_000_000, u.Total);
        Assert.Equal(200_000, u.Used);
        Assert.Equal(800_000, u.Available);
        Assert.Equal(["files"], u.Categories.Select(c => c.Key));
        var full = await Fails(() => b.UploadAsync(LocalFile(new byte[900_000]), "Huge.bin", "root", null, null));
        Assert.Equal(CloudErrorKind.QuotaExceeded, full.Kind);
        Assert.Equal("There isn’t enough space in Dropbox.", full.Message);
        fake.Update(x => x.Team = (5_000_000, 10_000_000, 0));
        var pooled = (await b.QuotaAsync())!;
        Assert.Equal(10_000_000, pooled.Total);
        Assert.Equal(5_000_000, pooled.Used);
        Assert.Equal(["files", "team"], pooled.Categories.Select(c => c.Key));
        Assert.Equal([200_000L, 4_800_000L], pooled.Categories.Select(c => c.Bytes));
        fake.Update(x => x.Team = (5_000_000, 10_000_000, 2_000_000));
        var limited = (await b.QuotaAsync())!;
        Assert.Equal(2_000_000, limited.Total);
        Assert.Equal(200_000, limited.Used);
    }

    // MARK: Downloads

    [Fact]
    public async Task DownloadStreamsTheFileAndSetsItsDate()
    {
        var s = new FakeDropboxServer.State { DropDownloadsNext = 1 };
        var data = Bytes(300_000, seed: 3);
        var when = DateTimeOffset.FromUnixTimeSeconds(1_720_000_000);
        s.AddFile("Photo.jpg", data, modified: when);
        s.AddPaperDoc("Plan.paper");
        var (b, _, fake) = await Connect(s);
        var photo = await Named(b, "Photo.jpg");
        var dir = Path.Combine(TestEnv.TempDir("dbx-dl"), "out");
        var dest = Path.Combine(dir, "Photo.jpg");
        (long, long) last = (0, 0);
        await b.DownloadAsync(photo, dest, (done, total) => last = (done, total));
        Assert.Equal(data, File.ReadAllBytes(dest));
        Assert.Equal(when.UtcDateTime, File.GetLastWriteTimeUtc(dest));
        Assert.Equal((300_000L, 300_000L), last);
        Assert.Equal(2, fake.S.Calls.Count(c => c == "POST content.dropboxapi.com/2/files/download"));   // dropped once, then retried
        Assert.Equal(1, fake.S.Downloads);
        Assert.Equal("{\"path\":\"" + photo.Id + "\"}", fake.S.ArgHeaders[^1]);

        var paper = await Named(b, "Plan.paper");
        var e = await Fails(() => b.DownloadAsync(paper, dest, null));
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
        Assert.Contains("dropbox.com", e.Message);
        Assert.Contains("“Plan.paper”", e.Message);
        Assert.Equal(data, File.ReadAllBytes(dest));   // the earlier download is untouched
        Assert.Equal(["Photo.jpg"], Directory.GetFileSystemEntries(dir).Select(Path.GetFileName));   // no partial files left behind
        var folder = new DriveNode { Id = "id:x", Name = "Folder", Type = "FOLDER" };
        Assert.Equal(CloudErrorKind.Unsupported, Assert.Throws<CloudException>(() => { _ = b.DownloadAsync(folder, dest, null); }).Kind);
    }

    // MARK: Changes

    [Fact]
    public async Task CreateRenameAndMoveIncludingBackToTheTop()
    {
        var s = new FakeDropboxServer.State();
        s.AddFile("Plan.txt", "plan"u8.ToArray());
        var (b, _, fake) = await Connect(s);
        var projects = await b.CreateFolderAsync("Projects", "root");
        Assert.Equal("root", projects.ParentID);
        Assert.Equal("FOLDER", projects.Type);
        Assert.Equal("Projects", projects.Name);
        Assert.StartsWith("id:", projects.Id);
        var year = await b.CreateFolderAsync("2026", projects.Id);
        Assert.Equal(projects.Id, year.ParentID);
        Assert.Equal("/Projects/2026", fake.S.PathOf(year.Id));
        var renamed = await b.RenameAsync(projects, "Projects (old)");
        Assert.Equal(projects.Id, renamed.Id);
        Assert.Equal("Projects (old)", renamed.Name);
        Assert.Equal("root", renamed.ParentID);
        Assert.Equal("/Projects (old)/2026", fake.S.PathOf(year.Id));   // the id still works below it

        // Same name: nothing to do. Only the case changes: a real rename.
        var before = CallCount(fake, "move_v2");
        await b.RenameAsync(year, "2026");
        Assert.Equal(before, CallCount(fake, "move_v2"));
        var plan = await Named(b, "Plan.txt");
        Assert.Equal("PLAN.txt", (await b.RenameAsync(plan, "PLAN.txt")).Name);
        Assert.Equal("PLAN.txt", fake.S.Items[plan.Id].Name);

        await b.MoveAsync([plan], year.Id);
        Assert.Equal(["PLAN.txt"], (await b.ListAsync(year.Id)).Select(n => n.Name));
        Assert.DoesNotContain(await b.ListAsync("root"), n => n.Name == "PLAN.txt");
        await b.MoveAsync([plan], "root");
        Assert.Contains(await b.ListAsync("root"), n => n.Name == "PLAN.txt");
        // Already there: no request.
        var moves = CallCount(fake, "move_v2");
        await b.MoveAsync([plan], "root");
        Assert.Equal(moves, CallCount(fake, "move_v2"));
        // Renamed elsewhere since it was listed: it keeps its current name when moved.
        fake.Update(x => x.Items[plan.Id].Name = "Plan v2.txt");
        await b.MoveAsync([plan], year.Id);
        Assert.Equal("/Projects (old)/2026/Plan v2.txt", fake.S.PathOf(plan.Id));
        // A folder can't go inside itself.
        var e = await Fails(() => b.MoveAsync([renamed], year.Id));
        Assert.Equal(CloudErrorKind.Denied, e.Kind);
        Assert.Equal("A folder can’t be moved into itself or into a folder inside it.", e.Message);
        Assert.Equal(0, fake.S.AutoCreatedFolders);
        var top = new DriveNode { Id = "root", Name = "Dropbox", Type = "FOLDER" };
        Assert.Equal(CloudErrorKind.Denied, Assert.Throws<CloudException>(() => { _ = b.RenameAsync(top, "X"); }).Kind);
    }

    [Fact]
    public async Task TrashKeepsItemsRestorableOnDropboxAndRestoreIsLeftToTheWeb()
    {
        var s = new FakeDropboxServer.State();
        s.AddFile("Old.txt", new byte[1000]);
        var folder = s.AddFolder("Archive");
        s.AddFile("Inside.txt", "i"u8.ToArray(), folder);
        var (b, _, fake) = await Connect(s);
        var old = await Named(b, "Old.txt");
        var archive = await Named(b, "Archive");
        await b.TrashAsync([old, archive]);
        Assert.Empty(await b.ListAsync("root"));
        SetEqual(["Old.txt", "Archive"], fake.S.DeletedItems.Select(i => i.Name));
        Assert.True(fake.S.Blobs.ContainsKey(old.Id));
        Assert.Equal(2, CallCount(fake, "delete_v2"));
        Assert.DoesNotContain(fake.S.Calls, c => c.Contains("permanently_delete", StringComparison.Ordinal));
        await b.TrashAsync([old]);   // already gone: fine
        Assert.False(b.CanListTrash);
        Assert.Empty(await b.ListTrashAsync());
        Assert.Equal(DropboxBackend.DeletedFilesMessage, Assert.Throws<CloudException>(() => { _ = b.RestoreAsync([old]); }).Message);
        // Delete Immediately: refused for items that aren't in the trash (as every backend does), and Dropbox's own
        // Deleted files can't be reached from Cirrus.
        Assert.Throws<InvalidOperationException>(() => { _ = b.DeleteForeverAsync([old]); });
        var listedAsDeleted = old.Copy();
        listedAsDeleted.ParentID = CloudConventions.TrashParent;
        var e = Assert.Throws<CloudException>(() => { _ = b.DeleteForeverAsync([listedAsDeleted]); });
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
        Assert.Equal(DropboxBackend.DeletedFilesMessage, e.Message);
        Assert.Contains("dropbox.com", DropboxBackend.DeletedFilesMessage);
        Assert.Contains("Deleted files", DropboxBackend.DeletedFilesMessage);
        Assert.Equal(3, CallCount(fake, "delete_v2"));   // the two deletions and the one for an item already gone: nothing else
    }

    [Fact]
    public async Task OddNamesTravelAsHeaderSafeJsonAndRoundTrip()
    {
        // Dropbox-API-Arg: 0x7F and everything non-ASCII as backslash-u escapes (UTF-16, so emoji become surrogate pairs).
        Assert.Equal("{\"path\":\"/caf\\u00e9 \\ud83d\\ude00\\u007f\"}", DropboxHttp.HeaderSafe(new JsonObject { ["path"] = "/café \U0001F600\u007F" }));
        Assert.Equal("{\"close\":false,\"cursor\":{\"offset\":5368709120,\"session_id\":\"s\"}}",
            DropboxHttp.HeaderSafe(new JsonObject { ["cursor"] = new JsonObject { ["session_id"] = "s", ["offset"] = 5_368_709_120L }, ["close"] = false }));
        var (b, _, fake) = await Connect();
        var decomposed = "Übeŕ.txt";   // as some file systems hand names over
        string[] names = ["Q&A #1 – 100% + more.txt", "café 日本語 😀.md", "quote\"back\\slash'.txt", "semi;colon=equals,comma@at$!~.txt", decomposed];
        var folder = await b.CreateFolderAsync("50% #done + more 😀", "root");
        Assert.NotNull(fake.S.Child("50% #done + more 😀"));
        for (int i = 0; i < names.Length; i++)
        {
            var data = Encoding.UTF8.GetBytes($"file {i}");
            b.SimpleUploadLimit = i % 2 == 0 ? 8 << 20 : 0;   // both the one-request upload and a session
            var n = await b.UploadAsync(LocalFile(data), names[i], folder.Id, DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), null);
            var want = names[i].Normalize(NormalizationForm.FormC);
            Assert.Equal(want, n.Name);
            var stored = fake.S.Child(want, folder.Id)!;
            Assert.Equal(want, stored.Name);
            Assert.Equal(data, fake.S.Blobs[stored.Id]);
            var dest = Path.Combine(TestEnv.TempDir("dbx-odd"), $"f{i}");
            await b.DownloadAsync(await Named(b, want, folder.Id), dest, null);
            Assert.Equal(data, File.ReadAllBytes(dest));
            Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000).UtcDateTime, File.GetLastWriteTimeUtc(dest));
            Assert.Equal("→ " + want, (await b.RenameAsync(n, "→ " + want)).Name);
        }
        var st = fake.S;
        Assert.Equal(0, st.NonASCIIArgHeaders);
        Assert.NotEmpty(st.ArgHeaders);
        Assert.All(st.ArgHeaders, h => Assert.True(h.All(char.IsAscii)));
        Assert.Contains(st.ArgHeaders, h => h.Contains("\\ud83d\\ude00", StringComparison.Ordinal));
        // Names Dropbox can't take are caught before anything is sent.
        var calls = st.Calls.Count;
        foreach (var bad in new[] { "a/b.txt", "", "..", "tab\there" })
            Assert.Equal(CloudErrorKind.Denied, (await Fails(() => b.UploadAsync(LocalFile("x"u8.ToArray()), bad, "root", null, null))).Kind);
        Assert.Equal(calls, fake.S.Calls.Count);
    }

    // MARK: Extras

    [Fact]
    public async Task ThumbnailsAskForASizeThatCoversTheRequest()
    {
        var s = new FakeDropboxServer.State();
        byte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE0, .. Bytes(600), 0xFF, 0xD9];
        var png = DemoArt.Png(32, 32, 0.6, "I");
        s.AddFile("Pic.JPG", jpeg);
        s.AddFile("Icon.png", png);
        s.AddFile("Notes.txt", "n"u8.ToArray());
        s.AddFile("Broken.jpg", "not an image"u8.ToArray());
        s.AddFolder("Folder");
        var (b, _, fake) = await Connect(s);
        var pic = await Named(b, "Pic.JPG");
        Assert.Equal(jpeg, await b.ThumbnailAsync(pic, 256));
        var a = fake.S.ThumbnailArgs[^1];
        Assert.Equal("w256h256", a["size"].Str);
        Assert.Equal("jpeg", a["format"].Str);
        Assert.Equal("bestfit", a["mode"].Str);
        Assert.Equal("path", a["resource"][".tag"].Str);
        Assert.Equal(pic.Id, a["resource"]["path"].Str);
        foreach (var (px, size) in new[] { (20, "w32h32"), (64, "w64h64"), (300, "w480h320"), (1000, "w1024h768"), (2048, "w2048h1536"), (5000, "w2048h1536") })
        {
            await b.ThumbnailAsync(pic, px);
            Assert.Equal(size, fake.S.ThumbnailArgs[^1]["size"].Str);
        }
        Assert.Equal(png, await b.ThumbnailAsync(await Named(b, "Icon.png"), 128));
        Assert.Equal("png", fake.S.ThumbnailArgs[^1]["format"].Str);
        Assert.Null(await b.ThumbnailAsync(await Named(b, "Broken.jpg"), 128));   // Dropbox can't make one: null
        var notes = await Named(b, "Notes.txt");
        var folder = await Named(b, "Folder");
        var calls = fake.S.Calls.Count;
        Assert.Null(await b.ThumbnailAsync(notes, 256));
        Assert.Null(await b.ThumbnailAsync(folder, 256));
        Assert.Equal(calls, fake.S.Calls.Count);   // no request for types without thumbnails
    }

    [Fact]
    public async Task TeamSpaceAccountsBrowseFromTheTeamRoot()
    {
        var s = new FakeDropboxServer.State { TeamRootNamespace = "7769321" };
        s.AddFolder("Marketing");
        var (b, c, fake) = await Connect(s);
        Assert.Equal("7769321", c.Record.Option("pathRoot"));
        var before = fake.S.MissingPathRoot;   // the sign-in itself reads the account without one
        Assert.Equal(["Marketing"], (await b.ListAsync("root")).Select(n => n.Name));
        await b.CreateFolderAsync("Plans", "root");
        await b.UploadAsync(LocalFile("x"u8.ToArray()), "x.txt", "root", null, null);
        Assert.Equal(before, fake.S.MissingPathRoot);
        Assert.Equal(3, fake.S.PathRootHeaders);
        // The team space changed (e.g. the member left the team): sign in again.
        var moved = c.Record.Copy();
        moved.Options = new() { ["pathRoot"] = "1111" };
        var stale = DropboxCloud.Backend(moved, c.Secret, fake);
        Assert.Equal(CloudErrorKind.SignInNeeded, (await Fails(() => stale.ListAsync("root"))).Kind);
    }

    [Fact]
    public async Task DemoAccountBrowsesGenericSampleContentThroughTheRouter()
    {
        var demo = FakeDropboxServer.Demo();
        var router = new FakeCloudRouter(demo);
        Assert.True(demo.Handles(new Uri("https://api.dropboxapi.com/2/files/list_folder")));
        Assert.True(demo.Handles(new Uri("https://content.dropboxapi.com/2/files/download")));
        Assert.False(demo.Handles(new Uri("https://graph.microsoft.com/v1.0/me")));
        var account = Assert.Single(router.DemoAccounts());
        Assert.Equal("cloud:dropbox:demo", account.Record.Id);
        Assert.Equal(CloudProvider.Dropbox, account.Record.Provider);
        Assert.Equal("alex@example.com", account.Record.Title);
        Assert.Equal(account.Secret.RefreshToken, router.DemoAccounts()[0].Secret.RefreshToken);   // the same account every time
        var b = DropboxCloud.Make(account.Record, account.Secret, router);
        Assert.IsAssignableFrom<ICloudTokenRotating>(b);
        var root = await b.ListAsync(b.RootID);
        SetEqual(["Documents", "Photos", "Read Me.txt"], root.Select(n => n.Name));
        SetEqual(["Meeting Notes.txt", "Budget.csv"], (await b.ListAsync(root.Single(n => n.Name == "Documents").Id)).Select(n => n.Name));
        var photos = await b.ListAsync(root.Single(n => n.Name == "Photos").Id);
        Assert.Equal(2, photos.Count);
        var thumb = (await b.ThumbnailAsync(photos[0], 128))!;
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, thumb[..4]);
        Assert.NotNull(await b.QuotaAsync());

        // Demo mode's sign-ins finish without a browser: the fake plays Dropbox's page.
        var signedIn = await SignIn(demo, u => demo.ApproveAsync(u), router);
        Assert.Equal("alex@example.com", signedIn.Record.Title);
        var pending = DropboxCloud.BeginCodeSignIn(demo.S.AppKey);
        Assert.Equal("alex@example.com", (await pending.FinishAsync(demo.DisplayedCode(pending.AuthorizationURL)!, router)).Record.Title);
    }
}
