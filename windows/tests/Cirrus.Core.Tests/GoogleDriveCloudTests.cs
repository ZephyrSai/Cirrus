using System.Diagnostics;
using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>Google Drive as a browsable account (full <c>drive</c> scope), against FakeGoogle (port of GoogleDriveCloudTests.swift).</summary>
public class GoogleDriveCloudTests
{
    static readonly GoogleOAuthClient Client = G.Client;

    /// <summary>Signs in through the real loopback listener and returns a fast-retrying backend.</summary>
    static async Task<(FakeGoogle Fake, CloudConnection Conn, GoogleDriveBackend Drive)> Connect(FakeGoogle.State? s = null)
    {
        var g = new FakeGoogle(s);
        var conn = await GoogleDriveCloud.SignInAsync(Client, u => g.ApproveAsync(u), g);
        var b = GoogleDriveCloud.MakeBackend(conn.Record, conn.Secret, g);
        b.Api.RetryBase = 0.001;
        b.Api.OAuth.Delay = (_, _) => Task.CompletedTask;
        return (g, conn, b);
    }

    static byte[] Bytes(int n, int seed = 7) => Enumerable.Range(0, n).Select(i => (byte)((i * 31 + seed) % 251)).ToArray();
    static string Md5(byte[] d) => FakeGoogle.Md5(d);
    static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);
    static DateTimeOffset At(long secs) => DateTimeOffset.FromUnixTimeSeconds(secs);
    static string Write(byte[] d, string name, string dir)
    {
        var p = Path.Combine(dir, Guid.NewGuid().ToString("N")[..6] + "-" + name);
        File.WriteAllBytes(p, d);
        return p;
    }

    sealed class ProgressLog
    {
        readonly List<(long Done, long Total)> _calls = [];
        public void Add(long a, long b) { lock (_calls) _calls.Add((a, b)); }
        public int Count { get { lock (_calls) return _calls.Count; } }
        public (long Done, long Total) Last { get { lock (_calls) return _calls.Count == 0 ? (0, 0) : _calls[^1]; } }
    }

    // MARK: Sign-in

    [Fact]
    public async Task SignInAsksForTheFullDriveScopeAndUsesTheEmail()
    {
        var g = new FakeGoogle(new FakeGoogle.State { Email = "alex@example.com", Name = "Alex Morgan" });
        Uri? seen = null;
        var (record, secret) = await GoogleDriveCloud.SignInAsync(Client, u => { seen = u; return g.ApproveAsync(u); }, g);
        var q = LoopbackReceiver.ParseQuery(seen!.PathAndQuery);
        Assert.Equal("https://www.googleapis.com/auth/drive", q["scope"]);
        Assert.Equal(GoogleScopes.Drive, q["scope"]);
        Assert.True(q["code_challenge_method"] == "S256" && q["access_type"] == "offline" && q["redirect_uri"].StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
        Assert.True(record.Provider == CloudProvider.GoogleDrive && record.Title == "alex@example.com" && record.Id.StartsWith("cloud:googleDrive:", StringComparison.Ordinal));
        Assert.StartsWith("1//fake-refresh-", secret.RefreshToken);
        Assert.True(secret.ClientID == Client.ClientID && secret.ClientSecret == Client.ClientSecret && secret.Password is null);
        Assert.Equal([GoogleScopes.Drive], g.S.RefreshTokens[secret.RefreshToken!]);

        // Refused on Google's page, Drive box unticked, or no client set up: each says what to do.
        var denied = await Assert.ThrowsAsync<CloudException>(() => GoogleDriveCloud.SignInAsync(Client, u => g.ApproveAsync(u, deny: true), g));
        Assert.Equal(CloudErrorKind.Denied, denied.Kind);
        Assert.Contains("choose Allow", denied.Message);
        g.Update(s => s.GrantedScopes = [.. GoogleScopes.All]);
        var unticked = await Assert.ThrowsAsync<CloudException>(() => GoogleDriveCloud.SignInAsync(Client, u => g.ApproveAsync(u), g));
        Assert.Equal(CloudErrorKind.Denied, unticked.Kind);
        Assert.Contains("tick", unticked.Message);
        var none = await Assert.ThrowsAsync<CloudException>(() => GoogleDriveCloud.SignInAsync(new GoogleOAuthClient("not-a-client", null), _ => Task.CompletedTask, g));
        Assert.Equal(CloudErrorKind.NotConfigured, none.Kind);
        Assert.Equal(GoogleDriveCloud.NotConfiguredMessage, none.Message);
    }

    [Fact]
    public async Task SavedSignInProblemsAreSignInNeededOrNotConfigured()
    {
        var (g, (record, secret), drive) = await Connect();
        await drive.ListAsync(drive.RootID);
        var noClient = Assert.Throws<CloudException>(() => GoogleDriveCloud.Make(record, new CloudSecret { RefreshToken = secret.RefreshToken }, g));
        Assert.Equal(CloudErrorKind.NotConfigured, noClient.Kind);
        var noToken = Assert.Throws<CloudException>(() => GoogleDriveCloud.Make(record, new CloudSecret { ClientID = secret.ClientID, ClientSecret = secret.ClientSecret }, g));
        Assert.True(noToken.Kind == CloudErrorKind.SignInNeeded && noToken.Message == "Google Drive needs you to sign in again.");
        var wrong = Assert.Throws<CloudException>(() => GoogleDriveCloud.Make(new CloudAccountRecord(CloudProvider.Dropbox, "x"), secret, g));
        Assert.Equal(CloudErrorKind.Unsupported, wrong.Kind);

        // Revoked at Google (or the Testing project's 7 days ran out): invalid_grant → sign in again.
        g.Update(s => { s.RevokeAllRefreshTokens(); s.AccessTokens.Clear(); });
        var again = GoogleDriveCloud.Make(record, secret, g);
        var e1 = await Assert.ThrowsAsync<CloudException>(() => again.ListAsync(again.RootID));
        Assert.True(e1.Kind == CloudErrorKind.SignInNeeded && e1.Detail == "Google Drive");
        // An access token Google stopped accepting mid-session is the same.
        var e2 = await Assert.ThrowsAsync<CloudException>(() => drive.QuotaAsync());
        Assert.True(e2.Kind == CloudErrorKind.SignInNeeded && e2.Detail == "Google Drive");
    }

    [Fact]
    public async Task ARotatedRefreshTokenIsUsedAndHandedToTheApp()
    {
        var (g, (_, secret), drive) = await Connect(new FakeGoogle.State { AccessTTL = 1 });   // < 90 s: every call refreshes first
        g.Update(s => s.RotateRefreshTokens = true);
        string? saved = null;
        Assert.IsAssignableFrom<ICloudTokenRotating>(drive);
        drive.OnNewRefreshToken = t => saved = t;
        await drive.ListAsync(drive.RootID);
        var first = saved;
        Assert.True(first is not null && first != secret.RefreshToken);
        Assert.Equal(secret with { RefreshToken = first }, drive.Secret);
        // The old token no longer works at the fake; the next refresh must use the new one.
        await drive.ListAsync(drive.RootID);
        Assert.NotEqual(first, saved);
        Assert.Equal([saved!], g.S.RefreshTokenList);
    }

    // MARK: Listing

    [Fact]
    public async Task ListingPagesNormalizesTheRootAndNeverTurnsFailuresIntoEmptyFolders()
    {
        var s = new FakeGoogle.State();
        var big = s.AddUserFolder("Big");
        for (int i = 0; i < 1205; i++) s.AddUserFile($"f{i:0000}.txt", Utf8(i.ToString()), big);
        var pics = s.AddUserFolder("Pictures");
        var jpg = s.AddUserFile("Lake.jpg", Bytes(5000), pics, At(1_750_000_000));
        s.AddUserFolder("Empty");
        var readme = s.AddUserFile("Readme.txt", Utf8("hi"), canDownload: false);
        s.AddUserFile("Elsewhere.pdf", Utf8("%PDF"), "shared-folder-elsewhere");   // shared with the user, not in My Drive
        var (g, _, drive) = await Connect(s);

        var root = await drive.ListAsync(drive.RootID);
        Assert.Equal(["Big", "Empty", "Pictures", "Readme.txt"], root.Select(n => n.Name).Order());
        Assert.All(root, n => Assert.Equal("root", n.ParentID));
        Assert.True(root.Single(n => n.Name == "Big").Type == "FOLDER" && root.Single(n => n.Name == "Readme.txt").Type == "FILE");
        Assert.False(drive.CapabilitiesOf(root.Single(n => n.Id == readme))!.CanDownload);
        // The real root id lists the same, still normalized to "root".
        var viaReal = await drive.ListAsync(FakeGoogle.RootID);
        Assert.Equal(root.Select(n => n.Id).Order(), viaReal.Select(n => n.Id).Order());
        Assert.All(viaReal, n => Assert.Equal("root", n.ParentID));

        var calls = g.S.Calls.Count;
        var many = await drive.ListAsync(big);
        Assert.True(many.Count == 1205 && many.Select(n => n.Name).Distinct().Count() == 1205 && many.All(n => n.ParentID == big));
        Assert.Equal(2, g.S.Calls.Skip(calls).Count(c => c == "GET www.googleapis.com/drive/v3/files"));   // two pages

        var lake = Assert.Single(await drive.ListAsync(pics));
        Assert.True(lake.Id == jpg && lake.Size == 5000 && lake.Etag == Md5(Bytes(5000)) && lake.Modified == At(1_750_000_000));
        Assert.True(lake.Created is not null && lake.Zone == "image/jpeg" && lake.DocID == jpg && !lake.IsGoogleNative());

        var both = await drive.ListManyAsync([big, pics, drive.RootID, "root"]);
        Assert.True(both.Count == 3 && both[big].Count == 1205 && both[pics].Count == 1 && both["root"].Count == 4);

        // An empty folder is empty; one that's gone or in the trash is an error, never “empty”.
        Assert.Empty(await drive.ListAsync(root.Single(n => n.Name == "Empty").Id));
        Assert.Equal(CloudErrorKind.NotFound, (await Assert.ThrowsAsync<CloudException>(() => drive.ListAsync("no-such-folder"))).Kind);
        g.Update(st => st.Files[pics].Trashed = true);
        Assert.Equal(CloudErrorKind.NotFound, (await Assert.ThrowsAsync<CloudException>(() => drive.ListAsync(pics))).Kind);
        // Rate limits are waited out; a server that keeps failing makes the listing fail.
        g.Update(st => st.RateLimitNext = 2);
        Assert.Equal(3, (await drive.ListAsync(drive.RootID)).Count);
        drive.Api.MaxRetries = 1;
        g.Update(st => st.RateLimitNext = 5);
        var limited = await Assert.ThrowsAsync<CloudException>(() => drive.ListAsync(big));
        Assert.Equal("Google Drive is limiting how fast Cirrus can work. Wait a few minutes, then try again.", limited.Message);
        await Assert.ThrowsAsync<CloudException>(() => drive.ListManyAsync([big, drive.RootID]));
    }

    // MARK: Google Docs, Sheets, Slides

    [Fact]
    public async Task GoogleDocsAreExportedFilesAndRenamingKeepsTheirTitlesClean()
    {
        var s = new FakeGoogle.State();
        var doc = s.AddUserDoc("Project plan", modified: At(1_760_000_000));
        var sheet = s.AddUserDoc("Budget", "spreadsheet");
        s.AddUserDoc("Deck", "presentation");
        s.AddUserDoc("Sketch", "drawing");
        s.AddUserDoc("data.xlsx", "spreadsheet");       // a converted upload keeps its extension
        var form = s.AddUserDoc("Survey", "form");
        var big = s.AddUserDoc("Annual report", tooLarge: true);
        var (g, _, drive) = await Connect(s);
        var dir = TestEnv.TempDir("gdrive-natives");

        var root = await drive.ListAsync(drive.RootID);
        Assert.Equal(["Annual report.docx", "Budget.xlsx", "Deck.pptx", "Project plan.docx", "Sketch.pdf", "Survey", "data.xlsx"],
            root.Select(n => n.Name).Order(StringComparer.Ordinal));
        Assert.All(root, n => Assert.True(n.Size == 0 && n.Type == "FILE" && n.IsGoogleNative()));
        Assert.Equal("application/vnd.google-apps.document", root.Single(n => n.Id == doc).Zone);

        var plan = root.Single(n => n.Id == doc);
        var output = Path.Combine(dir, "Project plan.docx");
        var seen = new ProgressLog();
        await drive.DownloadAsync(plan, output, seen.Add);
        Assert.StartsWith("FAKE-EXPORT application/vnd.openxmlformats-officedocument.wordprocessingml.document of Project plan", File.ReadAllText(output));
        Assert.Equal(At(1_760_000_000).UtcDateTime, File.GetLastWriteTimeUtc(output));
        Assert.True(seen.Last.Done > 0 && seen.Last.Done == seen.Last.Total);
        Assert.Single(Directory.GetFiles(dir));   // no temp file left behind
        // Over files.export's 10 MB: through the file's export link instead.
        await drive.DownloadAsync(root.Single(n => n.Id == big), Path.Combine(dir, "big.docx"), null);
        Assert.Equal(1, g.S.ExportLinkUses);
        // Forms and the like are listed but can't be downloaded.
        var unsupported = await Assert.ThrowsAsync<CloudException>(() => drive.DownloadAsync(root.Single(n => n.Id == form), Path.Combine(dir, "Survey"), null));
        Assert.True(unsupported.Kind == CloudErrorKind.Unsupported && unsupported.Message.Contains("Survey") && unsupported.Message.Contains("Google Forms"));
        Assert.False(File.Exists(Path.Combine(dir, "Survey")));

        // Renaming: the extension Cirrus shows isn't written into Google's title.
        var budget = root.Single(n => n.Id == sheet);
        var renamed = await drive.RenameAsync(budget, "Budget 2027.xlsx");
        Assert.True(g.S.Files[sheet].Name == "Budget 2027" && renamed.Name == "Budget 2027.xlsx" && renamed.ParentID == "root");
        var plain = await drive.RenameAsync(renamed, "Spending");
        Assert.True(g.S.Files[sheet].Name == "Spending" && plain.Name == "Spending.xlsx");
        var odd = await drive.RenameAsync(plan, ".docx");      // nothing left once the extension is off: kept as typed
        Assert.True(g.S.Files[doc].Name == ".docx" && odd.Name == ".docx");

        // PDF exports instead of Office files.
        drive.ExportFormat = GoogleDocFormat.Pdf;
        var asPDF = await drive.ListAsync(drive.RootID);
        Assert.Contains(asPDF, n => n.Name == "Spending.pdf");
        Assert.Contains(asPDF, n => n.Name == "Deck.pdf");
        await drive.DownloadAsync(asPDF.Single(n => n.Name == "Deck.pdf"), Path.Combine(dir, "Deck.pdf"), null);
        Assert.StartsWith("FAKE-EXPORT application/pdf", File.ReadAllText(Path.Combine(dir, "Deck.pdf")));
    }

    // MARK: Shortcuts

    [Fact]
    public async Task ShortcutsOpenTheirTargetsWithoutEverLoopingAndChangeOnlyThemselves()
    {
        var s = new FakeGoogle.State();
        var team = s.AddUserFolder("Team");
        var a = s.AddUserFile("a.txt", Utf8("alpha"), team);
        s.AddUserShortcut("Back to Team", team, team);          // a shortcut inside its own target
        var link = s.AddUserShortcut("Team link", team);
        var reportBytes = Bytes(70_000);
        var report = s.AddUserFile("report.bin", reportBytes, team, At(1_740_000_000));
        var toFile = s.AddUserShortcut("Latest report", report, modified: At(1_700_000_000));
        var doc = s.AddUserDoc("Plan", parent: team);
        s.AddUserShortcut("Plan", doc);
        var (g, _, drive) = await Connect(s);
        var dir = TestEnv.TempDir("gdrive-shortcuts");

        var root = await drive.ListAsync(drive.RootID);
        var teamLink = root.Single(n => n.Id == link);
        Assert.True(teamLink.IsFolder && teamLink.Name == "Team link" && teamLink.DocID == team);
        var latest = root.Single(n => n.Id == toFile);
        Assert.True(!latest.IsFolder && latest.Name == "Latest report" && latest.DocID == report && latest.Size == 0);
        Assert.Equal("Plan.docx", root.Single(n => n.DocID == doc).Name);

        // A folder shortcut shows the target's items, under the shortcut.
        var inside = await drive.ListAsync(teamLink.Id);
        Assert.Equal(["Back to Team", "Plan.docx", "a.txt", "report.bin"], inside.Select(n => n.Name).Order(StringComparer.Ordinal));
        Assert.All(inside, n => Assert.Equal(teamLink.Id, n.ParentID));
        var aViaLink = inside.Single(n => n.Name == "a.txt");
        Assert.True(aViaLink.Id == $"{a}~{link}" && aViaLink.DocID == a);
        await drive.DownloadAsync(aViaLink, Path.Combine(dir, "a.txt"), null);
        Assert.Equal(Utf8("alpha"), File.ReadAllBytes(Path.Combine(dir, "a.txt")));

        // A shortcut that leads back into itself is followed once, then shows as empty, so a full walk ends.
        var back = inside.Single(n => n.Name == "Back to Team");
        var again = await drive.ListAsync(back.Id);
        Assert.Equal(4, again.Count);
        Assert.Empty(await drive.ListAsync(again.Single(n => n.Name == "Back to Team").Id));
        var all = await drive.WalkAsync(drive.RootID);
        Assert.True(all.Count < 40);
        Assert.Contains(all, x => x.Path == "Team link/Back to Team/a.txt");
        Assert.Contains(all, x => x.Path == "Team/Back to Team/Back to Team");
        Assert.DoesNotContain(all, x => x.Path.StartsWith("Team/Back to Team/Back to Team/", StringComparison.Ordinal));

        // A file shortcut downloads what it points to, with the target's date…
        var output = Path.Combine(dir, "Latest report");
        await drive.DownloadAsync(latest, output, null);
        Assert.Equal(reportBytes, File.ReadAllBytes(output));
        Assert.Equal(At(1_740_000_000).UtcDateTime, File.GetLastWriteTimeUtc(output));
        // …and a shortcut to a Doc exports the Doc.
        var planOut = Path.Combine(dir, "Plan.docx");
        await drive.DownloadAsync(root.Single(n => n.DocID == doc), planOut, null);
        Assert.StartsWith("FAKE-EXPORT", File.ReadAllText(planOut));

        // Renaming, trashing or uploading through a shortcut: the shortcut changes, the target only gets the upload.
        await drive.RenameAsync(latest, "Old report");
        Assert.True(g.S.Files[toFile].Name == "Old report" && g.S.Files[report].Name == "report.bin");
        var up = Write(Utf8("new"), "new.txt", dir);
        var added = await drive.UploadAsync(up, "new.txt", teamLink.Id, null, null);
        Assert.Equal([team], g.S.Files[added.DocID!].Parents);
        Assert.True(added.ParentID == teamLink.Id && added.Id.EndsWith("~" + link, StringComparison.Ordinal));
        await drive.TrashAsync([latest, teamLink]);
        Assert.True(g.S.Files[toFile].Trashed && g.S.Files[link].Trashed);
        Assert.True(!g.S.Files[report].Trashed && !g.S.IsTrashed(team));
        Assert.Equal(5, (await drive.ListAsync(team)).Count);
    }

    // MARK: Transfers

    [Fact]
    public async Task UploadsAndDownloadsRoundTripWithDatesProgressAndStaleListings()
    {
        var s = new FakeGoogle.State();
        var folder = s.AddUserFolder("Inbox");
        var changing = s.AddUserFile("notes.txt", Utf8("first version"), folder);
        var (g, _, drive) = await Connect(s);
        drive.Drive.ChunkSize = 256 * 1024;
        var savedChunk = GoogleDrive.DownloadChunk;
        GoogleDrive.DownloadChunk = 256 * 1024;
        try
        {
            var dir = TestEnv.TempDir("gdrive-transfers");
            var data = Bytes(700_000, seed: 3);
            var when = At(1_720_000_000);
            var src = Write(data, "video.mov", dir);
            var sent = new ProgressLog();
            var node = await drive.UploadAsync(src, "video.mov", folder, when, sent.Add);
            Assert.True(node.Name == "video.mov" && node.Size == 700_000 && node.ParentID == folder && node.Type == "FILE" && node.Modified == when);
            Assert.True(node.Etag == Md5(data) && sent.Last == (700_000, 700_000));
            Assert.Equal(3, g.S.ChunkPuts);   // 256 KiB chunks
            var listed = (await drive.ListAsync(folder)).Single(n => n.Id == node.Id);
            Assert.True(listed.Modified == when && listed.Size == 700_000 && listed.Etag == node.Etag);

            var output = Path.Combine(dir, "down", "video.mov");
            var got = new ProgressLog();
            await drive.DownloadAsync(listed, output, got.Add);
            Assert.Equal(data, File.ReadAllBytes(output));
            Assert.Equal(when.UtcDateTime, File.GetLastWriteTimeUtc(output));
            Assert.True(got.Count >= 3 && got.Last == (700_000, 700_000) && g.S.RangedGets == 3);
            // Downloading over an existing file replaces it.
            File.WriteAllText(output, "something else");
            await drive.DownloadAsync(listed, output, null);
            Assert.Equal(data, File.ReadAllBytes(output));
            Assert.Equal(["video.mov"], Directory.GetFiles(Path.Combine(dir, "down")).Select(p => Path.GetFileName(p)));

            // Into My Drive itself, and an empty file.
            var empty = Write([], "empty.txt", dir);
            var e = await drive.UploadAsync(empty, "empty.txt", drive.RootID, null, null);
            Assert.True(e.ParentID == "root" && e.Size == 0);
            Assert.Equal([FakeGoogle.RootID], g.S.Files[e.Id].Parents);
            await drive.DownloadAsync(e, Path.Combine(dir, "e.txt"), null);
            Assert.Empty(File.ReadAllBytes(Path.Combine(dir, "e.txt")));

            // The file changed after it was listed: the download notices and fetches the current version.
            var stale = (await drive.ListAsync(folder)).Single(n => n.Id == changing);
            g.Update(st => st.ChangeUserFile(changing, Utf8("second, longer version")));
            await drive.DownloadAsync(stale, Path.Combine(dir, "notes.txt"), null);
            Assert.Equal("second, longer version", File.ReadAllText(Path.Combine(dir, "notes.txt")));

            // A dropped connection mid-upload resumes; storage that's full is said plainly.
            g.Update(st => st.DropDriveChunk = st.ChunkPuts + 2);
            var resumed = await drive.UploadAsync(src, "again.mov", folder, null, null);
            Assert.Equal(Md5(data), g.S.Files[resumed.Id].Md5);
            g.Update(st => st.Limit = st.Usage + 10);
            var full = await Assert.ThrowsAsync<CloudException>(() => drive.UploadAsync(src, "too big.mov", folder, null, null));
            Assert.True(full.Kind == CloudErrorKind.QuotaExceeded && full.Detail == "Google Drive");
            var inbox = (await drive.ListAsync(drive.RootID)).Single(n => n.Name == "Inbox");
            Assert.Equal(CloudErrorKind.Unsupported, (await Assert.ThrowsAsync<CloudException>(() => drive.DownloadAsync(inbox, Path.Combine(dir, "x"), null))).Kind);
        }
        finally { GoogleDrive.DownloadChunk = savedChunk; }
    }

    // MARK: Changes

    [Fact]
    public async Task CreateRenameAndMoveFoldersAndFiles()
    {
        var s = new FakeGoogle.State();
        var old = s.AddUserFolder("Old stuff");
        var file = s.AddUserFile("a.txt", Utf8("a"), old);
        var (g, _, drive) = await Connect(s);

        var projects = await drive.CreateFolderAsync("Projects", drive.RootID);
        Assert.True(projects.IsFolder && projects.ParentID == "root");
        Assert.Equal([FakeGoogle.RootID], g.S.Files[projects.Id].Parents);
        var year = await drive.CreateFolderAsync("2026", projects.Id);
        Assert.True(year.ParentID == projects.Id && g.S.Files[year.Id].MimeType == GoogleDrive.FolderMime);
        var renamed = await drive.RenameAsync(year, "2026 – Q1");
        Assert.True(renamed.Name == "2026 – Q1" && renamed.Id == year.Id && renamed.ParentID == projects.Id && renamed.IsFolder);

        var a = Assert.Single(await drive.ListAsync(old));
        await drive.MoveAsync([a], renamed.Id);
        Assert.Equal([year.Id], g.S.Files[file].Parents);
        Assert.Empty(await drive.ListAsync(old));
        Assert.Equal([file], (await drive.ListAsync(year.Id)).Select(n => n.Id));
        // Moving uses Google's current parents, not the (now stale) listing.
        await drive.MoveAsync([a], drive.RootID);
        Assert.Equal([FakeGoogle.RootID], g.S.Files[file].Parents);
        await drive.MoveAsync([a], drive.RootID);   // already there: nothing to do
        // A folder can't go inside itself.
        Assert.Equal(CloudErrorKind.Denied, (await Assert.ThrowsAsync<CloudException>(() => drive.MoveAsync([projects], year.Id))).Kind);
        Assert.Equal(CloudErrorKind.Denied, (await Assert.ThrowsAsync<CloudException>(() => drive.MoveAsync([projects], projects.Id))).Kind);
        await drive.MoveAsync([projects], old);
        Assert.Equal([old], g.S.Files[projects.Id].Parents);
        Assert.Equal(CloudErrorKind.NotFound, (await Assert.ThrowsAsync<CloudException>(() => drive.CreateFolderAsync("x", "no-such-folder"))).Kind);
    }

    [Fact]
    public async Task TrashIsRecoverableAndOnlyDeleteForeverDeletes()
    {
        var s = new FakeGoogle.State();
        var folder = s.AddUserFolder("Old");
        var inside = s.AddUserFile("inside.txt", Utf8("x"), folder);
        var loose = s.AddUserFile("loose.txt", Utf8("y"));
        var keep = s.AddUserFile("keep.txt", Utf8("z"));
        var (g, _, drive) = await Connect(s);
        Assert.True(drive.CanListTrash);

        var root = await drive.ListAsync(drive.RootID);
        await drive.TrashAsync(root.Where(n => n.Id == folder || n.Id == loose).ToList());
        Assert.Equal([keep], (await drive.ListAsync(drive.RootID)).Select(n => n.Id));
        Assert.True(g.S.PermanentDeletes == 0 && !g.S.Calls.Any(c => c.StartsWith("DELETE", StringComparison.Ordinal)));
        Assert.Equal(CloudErrorKind.NotFound, (await Assert.ThrowsAsync<CloudException>(() => drive.ListAsync(folder))).Kind);

        // Only what was trashed itself, as in Google Drive's Trash (not inside.txt).
        var trash = await drive.ListTrashAsync();
        Assert.Equal(new[] { folder, loose }.Order(), trash.Select(n => n.Id).Order());
        Assert.All(trash, n => Assert.True(n.ParentID == CloudConventions.TrashParent && n.IsInTrash));
        Assert.True(trash.Single(n => n.Id == folder).IsFolder);

        await drive.RestoreAsync(trash.Where(n => n.Id == folder).ToList());
        Assert.Equal([inside], (await drive.ListAsync(folder)).Select(n => n.Id));
        Assert.Equal([loose], (await drive.ListTrashAsync()).Select(n => n.Id));

        // Delete Immediately only for what's in the trash.
        var restored = (await drive.ListAsync(drive.RootID)).Single(n => n.Id == folder);
        await Assert.ThrowsAsync<InvalidOperationException>(() => drive.DeleteForeverAsync([restored]));
        Assert.Equal(0, g.S.PermanentDeletes);

        await drive.DeleteForeverAsync(await drive.ListTrashAsync());
        Assert.True(!g.S.Files.ContainsKey(loose) && g.S.PermanentDeletes == 1);
        Assert.Empty(await drive.ListTrashAsync());
        // A folder deleted for good takes its contents along; a repeat finds nothing and is fine.
        await drive.TrashAsync([restored]);
        var trashedFolder = Assert.Single(await drive.ListTrashAsync());
        await drive.DeleteForeverAsync([trashedFolder]);
        await drive.DeleteForeverAsync([trashedFolder]);
        Assert.True(!g.S.Files.ContainsKey(inside) && !g.S.Files.ContainsKey(folder) && g.S.Files.ContainsKey(keep));
    }

    // MARK: Quota and thumbnails

    [Fact]
    public async Task QuotaComesFromAboutAndAnUnlimitedPlanHasNoTotal()
    {
        var s = new FakeGoogle.State { Limit = 100_000_000_000, Usage = 40_000_000_000 };
        s.AddUserFile("big.bin", new byte[4096]);
        var (g, _, drive) = await Connect(s);
        var q = await drive.QuotaAsync();
        Assert.True(q is { Total: 100_000_000_000, Used: 40_000_000_000, Available: 60_000_000_000 });
        Assert.Equal(4096, q!.Categories.Single(c => c.Key == "drive").Bytes);
        g.Update(st => st.Limit = null);
        var unlimited = await drive.QuotaAsync();
        Assert.True(unlimited is { Total: 0, Used: 40_000_000_000 });
    }

    [Fact]
    public async Task ThumbnailsComeFromGoogleAtTheAskedSizeAndOnlyFromGoogle()
    {
        var s = new FakeGoogle.State();
        var pic = DemoArt.Png(300, 200, 0.3, "P");
        var png = s.AddUserFile("Pic.png", pic);
        var pdf = s.AddUserFile("Doc.pdf", Utf8("%PDF-1.4"));
        s.AddUserFile("Plain.txt", Utf8("t"));
        s.AddUserDoc("Sheet", "spreadsheet");
        var (g, _, drive) = await Connect(s);
        var root = await drive.ListAsync(drive.RootID);
        DriveNode N(string name) => root.Single(n => n.Name == name);

        Assert.Equal(pic, await drive.ThumbnailAsync(N("Pic.png"), 256));
        Assert.Contains($"GET lh3.googleusercontent.com/drive-storage/{png}=s256", g.S.Calls);
        var pdfThumb = await drive.ThumbnailAsync(N("Doc.pdf"), 128);
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, pdfThumb![..4]);
        Assert.NotNull(await drive.ThumbnailAsync(N("Sheet.xlsx"), 64));
        var before = g.S.Calls.Count;
        Assert.Null(await drive.ThumbnailAsync(N("Plain.txt"), 256));      // Google has none: no request
        Assert.Equal(before, g.S.Calls.Count);
        Assert.Equal([256, 128, 64], g.S.ThumbnailSizes);

        // An expired link is renewed once; a link to anywhere but Google, or not over https, is never called with the sign-in.
        drive.RememberThumbnailLink(pdf, "https://lh3.googleusercontent.com/drive-storage/expired-link=s220");
        Assert.NotNull(await drive.ThumbnailAsync(N("Doc.pdf"), 200));
        drive.RememberThumbnailLink(png, "https://downloads.example.net/thumb=s220");
        Assert.Null(await drive.ThumbnailAsync(N("Pic.png"), 200));
        drive.RememberThumbnailLink(png, $"http://lh3.googleusercontent.com/drive-storage/{png}=s220");
        Assert.Null(await drive.ThumbnailAsync(N("Pic.png"), 200));
        Assert.DoesNotContain(g.S.Calls, c => c.Contains("downloads.example.net", StringComparison.Ordinal));
        Assert.Empty(g.S.TokensSentElsewhere);

        Assert.Equal("https://lh3.googleusercontent.com/drive-storage/AbC-1=s512",
            GoogleDriveBackend.SizedThumbnail("https://lh3.googleusercontent.com/drive-storage/AbC-1=s220", 512)?.AbsoluteUri);
        Assert.Equal("https://lh3.googleusercontent.com/drive-storage/AbC-1=s2048",
            GoogleDriveBackend.SizedThumbnail("https://lh3.googleusercontent.com/drive-storage/AbC-1=s220-c-k", 9000)?.AbsoluteUri);
        Assert.Equal("https://docs.google.com/feeds/vt?gd=true&id=x&sz=s96",
            GoogleDriveBackend.SizedThumbnail("https://docs.google.com/feeds/vt?gd=true&id=x&sz=s220", 96)?.AbsoluteUri);
        Assert.Null(GoogleDriveBackend.SizedThumbnail("", 96));
    }

    // MARK: Names

    [Fact]
    public async Task OddNamesSurviveSearchQueriesAndURLs()
    {
        var s = new FakeGoogle.State();
        s.AddUserDoc("Q3 'plan' #2");
        var (_, _, drive) = await Connect(s);
        var dir = TestEnv.TempDir("gdrive-names");
        string[] names = ["a b#c%d.txt", "it's \"quoted\".txt", @"back\slash\'mix.txt", "plus+and&amp=eq?.txt", "Ünïcødé ñ — 100%.txt", "' or name contains '.txt"];

        var folder = await drive.CreateFolderAsync("50% off #1 'sale' \\", drive.RootID);
        Assert.Equal("50% off #1 'sale' \\", folder.Name);
        for (int i = 0; i < names.Length; i++)
        {
            var up = await drive.UploadAsync(Write(Utf8($"file {i}"), $"f{i}.txt", dir), names[i], folder.Id, null, null);
            Assert.Equal(names[i], up.Name);
        }
        var listed = await drive.ListAsync(folder.Id);
        Assert.Equal(names.Order(StringComparer.Ordinal), listed.Select(n => n.Name).Order(StringComparer.Ordinal));
        for (int i = 0; i < names.Length; i++)
        {
            var hit = Assert.Single(await drive.ItemsNamedAsync(names[i], folder.Id));
            Assert.Equal(names[i], hit.Name);
            var output = Path.Combine(dir, $"out-{i}");
            await drive.DownloadAsync(hit, output, null);
            Assert.Equal($"file {i}", File.ReadAllText(output));
        }
        Assert.Empty(await drive.ItemsNamedAsync("a b#c%d", folder.Id));
        Assert.Equal(["Q3 'plan' #2.docx"], (await drive.ItemsNamedAsync("Q3 'plan' #2.docx", drive.RootID)).Select(n => n.Name));
        Assert.Empty(await drive.ItemsNamedAsync("it's \"quoted\".txt", drive.RootID));
        var r = await drive.RenameAsync(listed.Single(n => n.Name == names[0]), "new 'name' \\ #%.txt");
        Assert.Equal([r.Id], (await drive.ItemsNamedAsync("new 'name' \\ #%.txt", folder.Id)).Select(n => n.Id));
        // A query the fake can't parse is refused, as at Google: escaping mistakes can't hide.
        await Assert.ThrowsAsync<GoogleException>(() => drive.Api.JsonAsync("GET", GoogleDrive.Base + "/files",
            new Dictionary<string, string> { ["q"] = "name = 'it's' and trashed = false", ["fields"] = "files(id)" }));
    }

    // MARK: Errors, cancellation and demo

    [Fact]
    public void GoogleErrorsBecomeCloudErrorsWithTheMacAppsSentences()
    {
        CloudException Map(GoogleException e) => Assert.IsType<CloudException>(GoogleDriveCloud.CloudError(e));
        Assert.True(Map(GoogleException.Reconnect("x")) is { Kind: CloudErrorKind.SignInNeeded, Message: "Google Drive needs you to sign in again." });
        Assert.Equal(CloudErrorKind.SignInNeeded, Map(GoogleException.MissingScope("Google Drive")).Kind);
        Assert.True(Map(GoogleException.StorageFull()) is { Kind: CloudErrorKind.QuotaExceeded, Message: "There isn’t enough space in Google Drive." });
        Assert.True(Map(GoogleException.NotConfigured()) is { Kind: CloudErrorKind.NotConfigured, Message: GoogleDriveCloud.NotConfiguredMessage });
        Assert.Equal("Google Drive’s daily upload limit (about 750 GB a day) has been reached. Try again tomorrow.", Map(GoogleException.DailyLimit("x")).Message);
        Assert.Equal("Google Drive ended the upload before it finished. Try again.", Map(GoogleException.UploadExpired()).Message);
        Assert.Equal(CloudErrorKind.NotFound, Map(GoogleException.Http(404, "File not found")).Kind);
        Assert.True(Map(GoogleException.Http(403, "Locked")) is { Kind: CloudErrorKind.Denied, Message: "Locked" });
        Assert.Equal("Google Drive didn’t allow that.", Map(GoogleException.Http(403, "")).Message);
        Assert.Equal(CloudErrorKind.Cancelled, Map(GoogleException.Cancelled()).Kind);
        Assert.Equal(CloudErrorKind.NotConfigured, Map(GoogleException.BadResponse("Google didn’t accept the client ID or secret. Check them.")).Kind);
        Assert.Equal(CloudErrorKind.Server, Map(GoogleException.Http(500, "Backend Error")).Kind);
        Assert.StartsWith("Couldn’t reach Google Drive: ", Assert.IsType<CloudException>(GoogleDriveCloud.CloudError(new HttpRequestException("offline"))).Message);
        var cancel = new OperationCanceledException();
        Assert.Same(cancel, GoogleDriveCloud.CloudError(cancel));
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.IsType<OperationCanceledException>(GoogleDriveCloud.CloudError(GoogleException.Cancelled(), cts.Token));
    }

    [Fact]
    public async Task CancellingStopsWork()
    {
        var (g, _, drive) = await Connect();
        await drive.ListAsync(drive.RootID);
        g.Update(s => s.Latency = 1.5);
        using var cts = new CancellationTokenSource();
        var t = drive.ListAsync(drive.RootID, cts.Token);
        await Task.Delay(50);
        cts.Cancel();
        var started = Stopwatch.StartNew();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => t);
        Assert.True(started.Elapsed < TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task DemoAccountHasItsOwnSeededDrive()
    {
        Assert.Empty(new FakeGoogle().DemoAccounts());   // only a seeded Drive demo lists an account
        var demo = FakeGoogle.DriveDemo(latency: 0);
        var router = new FakeCloudRouter(demo);
        Assert.True(demo.Handles(new Uri("https://www.googleapis.com/drive/v3/files")) && !demo.Handles(new Uri("https://graph.microsoft.com/v1.0/me")));
        var (record, secret) = Assert.Single(router.DemoAccounts());
        Assert.True(record.Id == FakeGoogle.DriveDemoAccountID && record.Provider == CloudProvider.GoogleDrive && record.Title == "alex@example.com");
        Assert.True(secret.RefreshToken == FakeGoogle.DriveDemoRefreshToken && secret.ClientID == demo.S.ClientID);

        ICloudDriveBackend backend;
        var saved = CloudBackends.Transport;
        CloudBackends.Transport = router;
        try { backend = CloudBackends.Make(record, secret); }
        finally { CloudBackends.Transport = saved; }
        Assert.True(backend.Provider == CloudProvider.GoogleDrive && backend.CanListTrash);
        // The migration demo's fake Google is a separate account: it doesn't see or change this one.
        var migration = new FakeGoogle();
        migration.Reset();
        Assert.Empty(migration.S.Files);

        var root = await backend.ListAsync(backend.RootID);
        Assert.Equal(["Documents", "Photos", "Projects", "Team survey", "Welcome.txt"], root.Select(n => n.Name).Order(StringComparer.Ordinal));
        var docs = await backend.ListAsync(root.Single(n => n.Name == "Documents").Id);
        Assert.Equal(["Budget 2026.xlsx", "Quarterly report.pdf"], docs.Select(n => n.Name).Order(StringComparer.Ordinal));
        var report = Path.Combine(TestEnv.TempDir("gdrive-demo"), "report.pdf");
        await backend.DownloadAsync(docs.Single(n => n.Name == "Quarterly report.pdf"), report, null);
        var pdfText = File.ReadAllText(report);
        Assert.True(pdfText.StartsWith("%PDF-1.4", StringComparison.Ordinal) && pdfText.TrimEnd().EndsWith("%%EOF", StringComparison.Ordinal) && pdfText.Contains("Quarterly Report"));
        var photos = await backend.ListAsync(root.Single(n => n.Name == "Photos").Id);
        Assert.True(photos.Count == 3 && photos.All(n => n.Name.EndsWith(".png", StringComparison.Ordinal) && n.Size > 10_000));
        Assert.NotNull(await backend.ThumbnailAsync(photos[0], 128));
        var projects = await backend.ListAsync(root.Single(n => n.Name == "Projects").Id);
        Assert.Equal(["Budget 2026.xlsx", "Project plan.docx", "Website refresh"], projects.Select(n => n.Name).Order(StringComparer.Ordinal));
        Assert.Equal(["Old draft.txt"], (await backend.ListTrashAsync()).Select(n => n.Name));
        var all = await backend.WalkAsync(backend.RootID);
        Assert.Contains(all, x => x.Path == "Projects/Website refresh/Photos/Harbor at dawn.png");
        var q = await backend.QuotaAsync();
        Assert.True(q is { Total: 15_000_000_000, Used: 3_400_000_000 });
        // Changes work and stay in this account.
        var made = await backend.CreateFolderAsync("New folder", backend.RootID);
        Assert.Equal("New folder", demo.S.Files[made.Id].Name);
        Assert.Empty(migration.S.Files);

        // With a folder, the demo account's changes are kept across launches.
        var store = TestEnv.TempDir("gdrive-demo-store");
        var first = FakeGoogle.DriveDemo(store, latency: 0);
        var conn = Assert.Single(first.DemoAccounts());
        var kept = await GoogleDriveCloud.Make(conn.Record, conn.Secret, first).CreateFolderAsync("Kept", "root");
        var relaunched = FakeGoogle.DriveDemo(store, latency: 0);
        Assert.Equal("Kept", relaunched.S.Files[kept.Id].Name);
        var again = GoogleDriveCloud.Make(conn.Record, conn.Secret, relaunched);
        var keptRoot = await again.ListAsync(again.RootID);
        Assert.Contains(keptRoot, n => n.Name == "Kept");
        Assert.Equal(3, (await again.ListAsync(keptRoot.Single(n => n.Name == "Photos").Id)).Count);
    }
}
