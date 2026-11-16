using System.Text;
using System.Text.Json.Nodes;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>The WebDAV / Nextcloud connector against FakeWebDAVServer (port of WebDAVTests.swift; each test has its own fake).</summary>
public class WebDAVTests
{
    sealed class ProgressBox
    {
        readonly object _lock = new();
        (long, long) _last;
        int _calls;
        public void Note(long a, long b) { lock (_lock) { _last = (a, b); _calls++; } }
        public (long Done, long Total) Last { get { lock (_lock) return _last; } }
        public int Calls { get { lock (_lock) return _calls; } }
    }

    static string NFC(string s) => s.Normalize(NormalizationForm.FormC);

    static string File(byte[] data, string name = "upload.bin")
    {
        var p = Path.Combine(TestEnv.TempDir("dav-src"), name);
        System.IO.File.WriteAllBytes(p, data);
        return p;
    }

    static string Dest(string name) => Path.Combine(TestEnv.TempDir("dav-dl"), name);

    static (FakeWebDAVServer Fake, WebDAVDrive Drive) Drive(CloudProvider p, FakeWebDAVServer.State? s = null, string? password = null, string? username = null)
    {
        s ??= FakeWebDAVServer.State.Seeded();
        var fake = new FakeWebDAVServer(s);
        var r = p == CloudProvider.Nextcloud
            ? new CloudAccountRecord(CloudProvider.Nextcloud, "alex@cloud.example.com", "https://cloud.example.com" + s.NextcloudBasePath,
                username ?? s.Nextcloud.LoginName, id: "cloud:nextcloud:test")
            : new CloudAccountRecord(CloudProvider.WebDAV, "alex@dav.example.com", "https://dav.example.com/webdav/", username ?? s.Plain.LoginName, id: "cloud:webdav:test");
        var d = new WebDAVDrive(r, password ?? (p == CloudProvider.Nextcloud ? s.Nextcloud.Password : s.Plain.Password), fake) { RetryBase = 0.001 };
        return (fake, d);
    }

    static async Task<Exception?> Caught(Func<Task> op)
    {
        try { await op(); return null; } catch (Exception e) { return e; }
    }

    static string? Denied(Exception? e) => e is CloudException { Kind: CloudErrorKind.Denied } c ? c.Detail : null;

    static async Task<DriveNode> NodeAsync(WebDAVDrive d, string folder, string name)
    {
        var n = (await d.ListAsync(folder)).FirstOrDefault(x => x.Name == NFC(name));
        Assert.True(n is not null, $"{name} not in {folder}");
        return n!;
    }

    static async Task Eventually(Func<bool> condition, int ms = 3000)
    {
        for (int i = 0; i < ms / 20 && !condition(); i++) await Task.Delay(20);
        Assert.True(condition());
    }

    // MARK: Listing

    [Theory]
    [InlineData(CloudProvider.Nextcloud)]
    [InlineData(CloudProvider.WebDAV)]
    public async Task ListsTheTopFolderAndSubfolders(CloudProvider p)
    {
        var (fake, d) = Drive(p);
        var top = await d.ListAsync(d.RootID);
        Assert.Superset(new HashSet<string> { "Documents", "Photos", "Projects" }, top.Where(n => n.IsFolder).Select(n => n.Name).ToHashSet());
        foreach (var n in top)
        {
            Assert.Equal(d.RootID, n.ParentID);
            Assert.Equal("dav", n.Zone);
            Assert.StartsWith("dav:/", n.Id);
            Assert.Equal(n.IsFolder, n.Id.EndsWith('/'));
            Assert.Equal(n.IsFolder ? "FOLDER" : "FILE", n.Type);
        }
        var docs = top.Single(n => n.Name == "Documents");
        Assert.Equal("dav:/Documents/", docs.Id);
        Assert.Equal(p == CloudProvider.Nextcloud, top.Single(n => n.Name == "Projects").IsShared);
        Assert.False(docs.IsShared);
        var items = await d.ListAsync(docs.Id);
        Assert.NotEmpty(items);
        Assert.All(items, n => Assert.Equal("dav:/Documents/", n.ParentID));
        var pdfName = p == CloudProvider.Nextcloud ? "Project brief.pdf" : "Manual.pdf";
        var pdf = items.Single(n => n.Name == pdfName);
        var server = fake.S.File("/Documents/" + pdfName, plain: p == CloudProvider.WebDAV)!;
        Assert.Equal("dav:/Documents/" + pdfName, pdf.Id);
        Assert.Equal(server.Data.Length, pdf.Size);
        Assert.Equal(server.Modified, pdf.Modified);
        Assert.Equal(server.Etag, pdf.Etag);
        Assert.Equal(p == CloudProvider.Nextcloud ? server.FileID.ToString() : null, pdf.DocID);
        Assert.StartsWith("%PDF-", Encoding.ASCII.GetString(server.Data, 0, 5));
        // Nested folders and ListMany (bounded concurrency) agree with ListAsync.
        var projects = await d.ListAsync("dav:/Projects/");
        var many = await d.ListManyAsync(["dav:/Documents/", "dav:/Projects/", "dav:/Photos/", "dav:/Documents/"]);
        Assert.Equal(new HashSet<string> { "dav:/Documents/", "dav:/Projects/", "dav:/Photos/" }, many.Keys.ToHashSet());
        Assert.Equal(projects.Select(n => n.Id).ToHashSet(), many["dav:/Projects/"].Select(n => n.Id).ToHashSet());
        var all = await d.WalkAsync(d.RootID);
        Assert.Contains(all, x => x.Path == "Documents/" + pdfName);
    }

    static readonly string[] OddNames = ["a b.txt", "hash #1.txt", "100% done.txt", "what?.txt", "c++ & more.txt", "Café ünicode.txt",
        "日本語のファイル.txt", "semi;colon=eq,comma.txt", "it's (1) [x] {y}.txt", "  leading spaces.txt", "plus+sign+.txt", "ends with dot."];

    [Theory]
    [InlineData(FakeWebDAVServer.HrefStyle.Path)]
    [InlineData(FakeWebDAVServer.HrefStyle.AbsoluteURL)]
    [InlineData(FakeWebDAVServer.HrefStyle.Relative)]
    public async Task OddNamesSurviveEveryHrefStyle(FakeWebDAVServer.HrefStyle style)
    {
        foreach (var p in new[] { CloudProvider.Nextcloud, CloudProvider.WebDAV })
        {
            var s = FakeWebDAVServer.State.Seeded();
            s.Hrefs = style;
            s.HrefNFD = style == FakeWebDAVServer.HrefStyle.Relative;   // decomposed Unicode in hrefs, like some servers on Apple file systems
            s.EchoSelf = style != FakeWebDAVServer.HrefStyle.AbsoluteURL; // and one style without the folder echoed back
            const string folder = "Odd #2 & Ünïcode%20 folder";
            foreach (var n in OddNames) s.Add($"/{folder}/" + n, Encoding.UTF8.GetBytes(n), plain: p == CloudProvider.WebDAV);
            var (_, d) = Drive(p, s);
            var top = await d.ListAsync(d.RootID);
            var odd = top.FirstOrDefault(n => n.Name == NFC(folder));
            Assert.True(odd is { IsFolder: true }, $"{p} {style}");
            var items = await d.ListAsync(odd!.Id);
            Assert.Equal(OddNames.Select(NFC).ToHashSet(), items.Select(n => n.Name).ToHashSet());
            foreach (var item in items)
            {
                Assert.Equal(odd.Id, item.ParentID);
                var dest = Dest("f");
                await d.DownloadAsync(item, dest, null);
                Assert.Equal(item.Name, NFC(Encoding.UTF8.GetString(System.IO.File.ReadAllBytes(dest))));
            }
            // Upload, rename and move with odd names too.
            var up = await d.UploadAsync(File("new"u8.ToArray()), "new #?%+&.txt", odd.Id, null, null);
            Assert.Equal("new #?%+&.txt", up.Name);
            var renamed = await d.RenameAsync(up, "renamed ü #2.txt");
            Assert.Contains(await d.ListAsync(odd.Id), x => x.Id == renamed.Id && x.Name == "renamed ü #2.txt");
            var sub = await d.CreateFolderAsync("sub & dir #", odd.Id);
            await d.MoveAsync([renamed], sub.Id);
            Assert.Equal(["renamed ü #2.txt"], (await d.ListAsync(sub.Id)).Select(n => n.Name));
        }
    }

    [Fact]
    public async Task FailedListingsThrowInsteadOfLookingEmpty()
    {
        foreach (var p in new[] { CloudProvider.Nextcloud, CloudProvider.WebDAV })
        {
            var s = FakeWebDAVServer.State.Seeded();
            s.FailPropfind = ["/Documents/"];
            s.TruncatePropfind = ["/Photos/"];
            var (_, d) = Drive(p, s);
            Assert.IsType<CloudException>(await Caught(() => d.ListAsync("dav:/Documents/")));
            var truncated = Assert.IsType<CloudException>(await Caught(() => d.ListAsync("dav:/Photos/")));
            Assert.Equal("The server’s folder listing was incomplete or unreadable, so nothing was shown. Try again.", truncated.Message);
            Assert.NotNull(await Caught(() => d.ListManyAsync(["dav:/Projects/", "dav:/Documents/"])));
            Assert.NotNull(await Caught(() => d.WalkAsync(d.RootID)));
            var missing = Assert.IsType<CloudException>(await Caught(() => d.ListAsync("dav:/No such folder/")));
            Assert.Equal(CloudErrorKind.NotFound, missing.Kind);
            // A file isn't a folder.
            Assert.NotNull(await Caught(() => d.ListAsync("dav:/Projects/Roadmap.md/")));
            // IDs from elsewhere aren't this account's.
            Assert.Equal(CloudErrorKind.NotFound, Assert.IsType<CloudException>(await Caught(() => d.ListAsync("FOLDER::com.apple.CloudDocs::root"))).Kind);
        }
    }

    [Fact]
    public async Task ServerHiccupsAreRetriedButMovesAreNotRepeated()
    {
        var (fake, d) = Drive(CloudProvider.Nextcloud);
        fake.Update(s => s.RateLimitNext = 2);
        Assert.NotEmpty(await d.ListAsync(d.RootID));
        fake.Update(s => s.UnavailableNext = 2);
        Assert.NotEmpty(await d.ListAsync("dav:/Documents/"));
        // A 503 on MOVE might have been processed elsewhere: it is reported, not repeated.
        var notes = await NodeAsync(d, "dav:/Documents/", "Meeting notes.txt");
        fake.Update(s => { s.UnavailableNext = 1; s.Calls.Clear(); });
        Assert.NotNull(await Caught(() => d.RenameAsync(notes, "Other.txt")));
        Assert.Single(fake.S.Calls, c => c.StartsWith("MOVE", StringComparison.Ordinal));
        // A 429 means "not processed": that one is retried.
        fake.Update(s => { s.RateLimitNext = 1; s.Calls.Clear(); });
        var r = await d.RenameAsync(notes, "Other.txt");
        Assert.Equal("Other.txt", r.Name);
        Assert.Equal(2, fake.S.Calls.Count(c => c.StartsWith("MOVE", StringComparison.Ordinal)));
        // A dropped connection: listings are simply asked again…
        fake.Update(s => s.DropNext = 1);
        Assert.NotEmpty(await d.ListAsync("dav:/Documents/"));
        // …a move isn't (the server may have done it), and the error says what happened.
        fake.Update(s => { s.DropNext = 1; s.Calls.Clear(); });
        var e = Assert.IsType<CloudException>(await Caught(() => d.RenameAsync(r, "Third.txt")));
        Assert.Equal("The connection to “cloud.example.com” failed (The network connection was lost.).", e.Message);
        Assert.Single(fake.S.Calls, c => c.StartsWith("MOVE", StringComparison.Ordinal));
        // An upload whose answer got lost finds its own first attempt instead of reporting a clash.
        fake.Update(s => s.DropNext = 1);
        var up = await d.UploadAsync(File(new byte[4321]), "lost answer.bin", "dav:/Documents/", null, null);
        Assert.Equal(4321, up.Size);
        Assert.Equal(2, fake.S.Calls.Count(c => c == "PUT /remote.php/dav/files/alex/Documents/lost answer.bin"));
    }

    // MARK: Transfers

    [Theory]
    [InlineData(CloudProvider.Nextcloud)]
    [InlineData(CloudProvider.WebDAV)]
    public async Task UploadAndDownloadKeepContentAndDates(CloudProvider p)
    {
        var (fake, d) = Drive(p);
        var bytes = Enumerable.Range(0, 300_000).Select(i => (byte)(i % 251)).ToArray();
        var mtime = DateTimeOffset.FromUnixTimeSeconds(1_700_000_123);
        var box = new ProgressBox();
        var n = await d.UploadAsync(File(bytes), "Report 2026.bin", "dav:/Documents/", mtime, box.Note);
        Assert.Equal("dav:/Documents/Report 2026.bin", n.Id);
        Assert.Equal("dav:/Documents/", n.ParentID);
        Assert.Equal(300_000, n.Size);
        Assert.Equal("FILE", n.Type);
        Assert.Equal((300_000L, 300_000L), box.Last);
        var server = fake.S.File("/Documents/Report 2026.bin", plain: p == CloudProvider.WebDAV)!;
        Assert.Equal(bytes, server.Data);
        if (p == CloudProvider.Nextcloud)
        {
            Assert.Equal(mtime, server.Modified);     // X-OC-Mtime
            Assert.Equal(mtime, n.Modified);
            Assert.Equal(server.FileID.ToString(), n.DocID);
        }
        var dest = Dest("Report 2026.bin");
        var dbox = new ProgressBox();
        await d.DownloadAsync(n, dest, dbox.Note);
        Assert.Equal(bytes, System.IO.File.ReadAllBytes(dest));
        Assert.Equal(300_000, dbox.Last.Done);
        Assert.True(Math.Abs((System.IO.File.GetLastWriteTimeUtc(dest) - n.Modified!.Value.UtcDateTime).TotalSeconds) < 1);
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(dest)!, ".cirrus-dl-*"));
        // An upload never replaces an existing item by accident.
        var e = await Caught(() => d.UploadAsync(File("other"u8.ToArray()), "Report 2026.bin", "dav:/Documents/", null, null));
        Assert.Equal("There’s already an item named “Report 2026.bin” in “Documents”. Choose a different name.", Denied(e));
        Assert.Equal(bytes, fake.S.File("/Documents/Report 2026.bin", plain: p == CloudProvider.WebDAV)!.Data);
        // Empty files work too.
        var empty = await d.UploadAsync(File([]), "empty.txt", d.RootID, null, null);
        Assert.Equal(0, empty.Size);
        var ed = Dest("empty.txt");
        await d.DownloadAsync(empty, ed, null);
        Assert.Empty(System.IO.File.ReadAllBytes(ed));
        // A download that fails leaves nothing behind.
        var gone = n.Copy();
        gone.Id = "dav:/Documents/gone.bin";
        var gd = Dest("gone.bin");
        Assert.Equal(CloudErrorKind.NotFound, Assert.IsType<CloudException>(await Caught(() => d.DownloadAsync(gone, gd, null))).Kind);
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(gd)!));
    }

    [Fact]
    public async Task BigNextcloudUploadsGoInChunks()
    {
        var (fake, d) = Drive(CloudProvider.Nextcloud);
        d.ChunkSize = 5 << 20;
        d.ChunkThreshold = 5 << 20;
        var bytes = new byte[12 << 20];
        for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i * 31 + (i >> 12));
        var mtime = DateTimeOffset.FromUnixTimeSeconds(1_750_000_000);
        var box = new ProgressBox();
        var n = await d.UploadAsync(File(bytes), "Big video.mov", "dav:/Photos/", mtime, box.Note);
        var s = fake.S;
        Assert.Equal(3, s.ChunkPuts);
        Assert.Equal(1, s.ChunkAssemblies);
        Assert.Contains(s.Calls, c => c.StartsWith("MKCOL /remote.php/dav/uploads/alex/cirrus-", StringComparison.Ordinal));
        Assert.Contains(s.Calls, c => c.StartsWith("PUT /remote.php/dav/uploads/alex/cirrus-", StringComparison.Ordinal) && c.EndsWith("/00003", StringComparison.Ordinal));
        Assert.Contains(s.Calls, c => c.StartsWith("MOVE /remote.php/dav/uploads/alex/cirrus-", StringComparison.Ordinal) && c.EndsWith("/.file", StringComparison.Ordinal));
        Assert.DoesNotContain(s.Calls, c => c.StartsWith("PUT /remote.php/dav/files/", StringComparison.Ordinal));
        var server = s.File("/Photos/Big video.mov")!;
        Assert.Equal(bytes, server.Data);
        Assert.Equal(mtime, server.Modified);
        Assert.Equal(bytes.Length, n.Size);
        Assert.Equal(server.FileID.ToString(), n.DocID);
        Assert.Equal(bytes.Length, box.Last.Done);
        Assert.True(box.Calls > 3);
        // The same name again is refused before anything is sent.
        fake.Update(st => st.Calls.Clear());
        var e = await Caught(() => d.UploadAsync(File(bytes), "Big video.mov", "dav:/Photos/", null, null));
        Assert.Contains("already", Denied(e));
        Assert.DoesNotContain(fake.S.Calls, c => c.StartsWith("MKCOL", StringComparison.Ordinal));
        // Chunks the server finds too small: a clear failure, and the upload folder is cleaned up.
        d.ChunkSize = 1 << 20;
        var e2 = Assert.IsType<CloudException>(await Caught(() => d.UploadAsync(File(bytes), "Too small chunks.mov", "dav:/Photos/", null, null)));
        Assert.Equal("The server couldn’t finish uploading “Too small chunks.mov” (400: Chunk 1 is smaller than the 5 MiB minimum).", e2.Message);
        Assert.Null(fake.S.File("/Photos/Too small chunks.mov"));
        await Eventually(() => fake.S.Calls.ToList().Any(c => c.StartsWith("DELETE /remote.php/dav/uploads/alex/cirrus-", StringComparison.Ordinal)));
    }

    // MARK: Folders, rename, move

    [Theory]
    [InlineData(CloudProvider.Nextcloud)]
    [InlineData(CloudProvider.WebDAV)]
    public async Task FoldersRenameMoveAndNameClashes(CloudProvider p)
    {
        var (_, d) = Drive(p);
        var f = await d.CreateFolderAsync("New Folder", d.RootID);
        Assert.Equal("dav:/New Folder/", f.Id);
        Assert.True(f.IsFolder && f.ParentID == d.RootID);
        Assert.Contains("already", Denied(await Caught(() => d.CreateFolderAsync("New Folder", d.RootID))));
        var renamed = await d.RenameAsync(f, "Archive 2026");
        Assert.True(renamed.Id == "dav:/Archive 2026/" && renamed.Name == "Archive 2026");
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Id == "dav:/Archive 2026/");
        Assert.DoesNotContain(await d.ListAsync(d.RootID), n => n.Id == "dav:/New Folder/");

        var docs = await d.ListAsync("dav:/Documents/");
        var files = docs.Where(n => !n.IsFolder).ToList();
        Assert.True(files.Count >= 2);
        // Rename onto an existing sibling: refused, nothing changed.
        Assert.Contains("already", Denied(await Caught(() => d.RenameAsync(files[0], files[1].Name))));
        Assert.Equal(docs.Select(n => n.Id).ToHashSet(), (await d.ListAsync("dav:/Documents/")).Select(n => n.Id).ToHashSet());

        // Move, then a clash in the target, then a folder into itself.
        await d.MoveAsync([files[0]], renamed.Id);
        Assert.Equal([files[0].Name], (await d.ListAsync(renamed.Id)).Select(n => n.Name));
        await d.UploadAsync(File("x"u8.ToArray()), files[1].Name, renamed.Id, null, null);
        Assert.Contains("already", Denied(await Caught(() => d.MoveAsync([files[1]], renamed.Id))));
        Assert.Contains(await d.ListAsync("dav:/Documents/"), n => n.Id == files[1].Id);
        var inner = await d.CreateFolderAsync("Inner", renamed.Id);
        Assert.Equal("“Archive 2026” can’t be moved into itself.", Denied(await Caught(() => d.MoveAsync([renamed], inner.Id))));
        // Moving whole folders keeps their contents.
        await d.MoveAsync([renamed], "dav:/Projects/");
        Assert.Equal(3, (await d.ListAsync("dav:/Projects/Archive 2026/")).Count);
        // Names that can't exist on a server.
        Assert.Equal("Names on the server can’t contain “/”.", Denied(await Caught(() => d.CreateFolderAsync("a/b", d.RootID))));
        Assert.Equal("“..” can’t be used as a name.", Denied(await Caught(() => d.RenameAsync(inner, ".."))));
        Assert.EndsWith("is too long a name for the server.", Denied(await Caught(() => d.CreateFolderAsync(new string('x', 251), d.RootID))));
        // Nothing goes into the trash this way.
        var bin = (await d.ListTrashAsync()).FirstOrDefault();
        if (bin is not null) Assert.IsType<CloudException>(await Caught(() => d.MoveAsync([files[1]], bin.Id)));
    }

    [Fact]
    public async Task CaseOnlyRenameWorksOnCaseInsensitiveServers()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.PlainCaseInsensitive = true;
        var (_, d) = Drive(CloudProvider.WebDAV, s);
        var notes = await NodeAsync(d, "dav:/Documents/", "Notes.txt");
        var r = await d.RenameAsync(notes, "NOTES.txt");
        Assert.True(r.Name == "NOTES.txt" && r.Id == "dav:/Documents/NOTES.txt");
        Assert.Equal(["NOTES.txt"], (await d.ListAsync("dav:/Documents/")).Where(n => n.Name.Equals("notes.txt", StringComparison.OrdinalIgnoreCase)).Select(n => n.Name));
        // A real clash is still refused.
        var inv = await NodeAsync(d, "dav:/Documents/", "Inventory.csv");
        Assert.Contains("already", Denied(await Caught(() => d.RenameAsync(inv, "notes.TXT"))));
    }

    [Fact]
    public async Task LockedFilesAndFullStorageGiveClearErrors()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.LockedPaths = ["/Documents/Meeting notes.txt"];
        s.Nextcloud.Quota = s.Nextcloud.UsedBytes + 10;
        var (_, d) = Drive(CloudProvider.Nextcloud, s);
        var notes = await NodeAsync(d, "dav:/Documents/", "Meeting notes.txt");
        Assert.Equal("The item is locked on the server (it may be open in another app). Try again later.", Denied(await Caught(() => d.RenameAsync(notes, "x.txt"))));
        var e = Assert.IsType<CloudException>(await Caught(() => d.UploadAsync(File(new byte[1000]), "big.bin", d.RootID, null, null)));
        Assert.Equal(CloudErrorKind.QuotaExceeded, e.Kind);
        Assert.Equal("There isn’t enough space in Nextcloud (alex@cloud.example.com).", e.Message);
    }

    // MARK: Trash

    [Fact]
    public async Task NextcloudTrashBinRoundTrip()
    {
        var (fake, d) = Drive(CloudProvider.Nextcloud);
        var notes = await NodeAsync(d, "dav:/Documents/", "Meeting notes.txt");
        var website = await NodeAsync(d, "dav:/Projects/", "Website");
        await d.TrashAsync([notes, website]);
        Assert.Equal(0, fake.S.PermanentDeletes);
        Assert.Equal(3, fake.S.Nextcloud.Trash.Count);
        Assert.DoesNotContain(await d.ListAsync("dav:/Documents/"), n => n.Name == "Meeting notes.txt");

        var bin = await d.ListTrashAsync();
        Assert.Equal(new HashSet<string> { "Meeting notes.txt", "Website", "Old draft.txt" }, bin.Select(n => n.Name).ToHashSet());
        Assert.All(bin, n =>
        {
            Assert.StartsWith("dav-trash:/", n.Id);
            Assert.Equal(CloudConventions.TrashParent, n.ParentID);
            Assert.True(n.IsInTrash);
        });
        Assert.True(d.CanListTrash);
        var w = bin.Single(n => n.Name == "Website");
        Assert.True(w.IsFolder);
        Assert.Equal(new HashSet<string> { "index.html", "style.css" }, (await d.ListAsync(w.Id)).Select(n => n.Name).ToHashSet());
        var n = bin.Single(x => x.Name == "Meeting notes.txt");
        var dest = Dest("n.txt");
        await d.DownloadAsync(n, dest, null);
        Assert.Contains("Agenda", System.IO.File.ReadAllText(dest));

        await d.RestoreAsync([n]);
        Assert.Contains(await d.ListAsync("dav:/Documents/"), x => x.Name == "Meeting notes.txt");
        Assert.NotEmpty(fake.S.File("/Documents/Meeting notes.txt")!.Data);

        // Only items in the trash can be erased or recovered.
        var live = await NodeAsync(d, "dav:/Documents/", "Meeting notes.txt");
        Assert.IsType<InvalidOperationException>(await Caught(() => d.DeleteForeverAsync([live])));
        Assert.Equal("“Meeting notes.txt” isn’t in Deleted Files. Delete it first.",
            Assert.IsType<CloudException>(await Caught(() => d.RestoreAsync([live]))).Message);
        Assert.Equal("“Website” is already in Deleted Files.", Assert.IsType<CloudException>(await Caught(() => d.TrashAsync([w]))).Message);
        Assert.Equal(0, fake.S.PermanentDeletes);

        await d.DeleteForeverAsync([w]);
        Assert.Equal(1, fake.S.PermanentDeletes);
        Assert.Equal(["Old draft.txt"], (await d.ListTrashAsync()).Select(x => x.Name));
        // Restoring when the original folder is gone puts it at the top.
        var draft = (await d.ListTrashAsync()).Single();
        fake.Update(s => { foreach (var k in s.Nextcloud.Files.Keys.Where(k => k.StartsWith("/Documents/", StringComparison.Ordinal)).ToList()) s.Nextcloud.Files.Remove(k); });
        await d.RestoreAsync([draft]);
        Assert.Contains(await d.ListAsync(d.RootID), x => x.Name == "Old draft.txt");
    }

    [Fact]
    public async Task PlainWebDAVTrashUsesDeletedByCirrus()
    {
        var (fake, d) = Drive(CloudProvider.WebDAV);
        var notes = await NodeAsync(d, "dav:/Documents/", "Notes.txt");
        var photos = await NodeAsync(d, d.RootID, "Photos");
        fake.Update(s => s.Calls.Clear());
        await d.TrashAsync([notes, photos]);
        Assert.DoesNotContain(fake.S.Calls, c => c.StartsWith("DELETE", StringComparison.Ordinal));   // never an erase
        Assert.Equal(0, fake.S.PermanentDeletes);
        var s = fake.S;
        Assert.NotNull(s.File("/Deleted by Cirrus/Notes.txt", plain: true));
        Assert.NotNull(s.File("/Deleted by Cirrus/Photos/Beach.jpg", plain: true));
        var manifest = JsonNode.Parse(s.File("/Deleted by Cirrus/.cirrus-deleted.json", plain: true)!.Data)!;
        Assert.Equal("/Documents/", (string?)manifest["items"]!["Notes.txt"]!["from"]);
        Assert.Equal(1, (int?)manifest["version"]);
        // The folder is Cirrus's trash: not shown among the files.
        Assert.DoesNotContain(await d.ListAsync(d.RootID), n => n.Name == WebDAVDrive.TrashFolderName);
        var bin = await d.ListTrashAsync();
        Assert.Equal(new HashSet<string> { "Notes.txt", "Photos" }, bin.Select(n => n.Name).ToHashSet());
        Assert.All(bin, n => Assert.True(n.IsInTrash));

        // A second "Notes.txt" gets its own name inside the folder but shows its real name.
        await d.UploadAsync(File("project notes"u8.ToArray()), "Notes.txt", "dav:/Projects/", null, null);
        await d.TrashAsync([await NodeAsync(d, "dav:/Projects/", "Notes.txt")]);
        Assert.Equal("project notes"u8.ToArray(), fake.S.File("/Deleted by Cirrus/Notes 2.txt", plain: true)!.Data);
        bin = await d.ListTrashAsync();
        Assert.Equal(2, bin.Count(n => n.Name == "Notes.txt"));

        // Restore goes back where each item came from.
        await d.RestoreAsync([bin.Single(n => n.Id == "dav:/Deleted by Cirrus/Notes 2.txt")]);
        Assert.Equal("project notes"u8.ToArray(), fake.S.File("/Projects/Notes.txt", plain: true)!.Data);
        // …or to the top when the original folder is gone.
        fake.Update(st => { foreach (var k in st.Plain.Files.Keys.Where(k => k.StartsWith("/Documents/", StringComparison.Ordinal)).ToList()) st.Plain.Files.Remove(k); });
        await d.RestoreAsync([(await d.ListTrashAsync()).Single(n => n.Name == "Notes.txt")]);
        Assert.NotNull(fake.S.File("/Notes.txt", plain: true));

        // Only items in the trash can be erased.
        var live = await NodeAsync(d, d.RootID, "Notes.txt");
        Assert.IsType<InvalidOperationException>(await Caught(() => d.DeleteForeverAsync([live])));
        var liveInTrashParent = live.Copy();
        liveInTrashParent.ParentID = CloudConventions.TrashParent;   // even when it claims to be
        Assert.IsType<CloudException>(await Caught(() => d.DeleteForeverAsync([liveInTrashParent])));
        Assert.Equal(0, fake.S.PermanentDeletes);
        await d.DeleteForeverAsync([(await d.ListTrashAsync()).Single(n => n.Name == "Photos")]);
        Assert.Equal(1, fake.S.PermanentDeletes);
        Assert.Empty(await d.ListTrashAsync());
        Assert.DoesNotContain("Photos", Encoding.UTF8.GetString(fake.S.File("/Deleted by Cirrus/.cirrus-deleted.json", plain: true)!.Data));
    }

    [Fact]
    public async Task NextcloudWithoutItsTrashAppNeverErases()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.TrashbinEnabled = false;
        var (fake, d) = Drive(CloudProvider.Nextcloud, s);
        var notes = await NodeAsync(d, "dav:/Documents/", "Meeting notes.txt");
        await d.TrashAsync([notes]);
        Assert.Equal(0, fake.S.PermanentDeletes);
        Assert.NotNull(fake.S.File("/Deleted by Cirrus/Meeting notes.txt"));
        Assert.Equal(["Meeting notes.txt"], (await d.ListTrashAsync()).Select(n => n.Name));
        Assert.DoesNotContain(await d.ListAsync(d.RootID), n => n.Name == WebDAVDrive.TrashFolderName);
        // A fresh connection (trash app state unknown) still hides the folder.
        var again = new WebDAVDrive(d.Record, s.Nextcloud.Password, fake);
        Assert.DoesNotContain(await again.ListAsync(again.RootID), n => n.Name == WebDAVDrive.TrashFolderName);
        await d.RestoreAsync(await d.ListTrashAsync());
        Assert.NotNull(fake.S.File("/Documents/Meeting notes.txt"));
        // With the trash app on, a folder of that name is just a folder.
        fake.Update(st => st.TrashbinEnabled = true);
        var on = new WebDAVDrive(d.Record, s.Nextcloud.Password, fake);
        Assert.Contains(await on.ListAsync(on.RootID), n => n.Name == WebDAVDrive.TrashFolderName);
    }

    [Fact]
    public void TrashManifestIsTheMacAppsFormat()
    {
        var m = new WebDAVDrive.Manifest();
        m.Items["Notes 2.txt"] = new("Notes.txt", "/Projects/", DateTimeOffset.FromUnixTimeMilliseconds(1_790_000_000_123));
        var text = Encoding.UTF8.GetString(m.Bytes());
        var j = JsonNode.Parse(text)!;
        Assert.Equal(1, (int?)j["version"]);
        Assert.Equal("2026-09-21T14:13:20Z", (string?)j["items"]!["Notes 2.txt"]!["deleted"]);   // whole seconds: the Mac app's decoder needs that
        Assert.Contains("\"/Projects/\"", text);                                                 // slashes unescaped
        // What the Mac app writes (pretty-printed, sorted keys).
        var mac = """
            {
              "items" : {
                "Café.txt" : {
                  "deleted" : "2026-09-21T14:13:20Z",
                  "from" : "/Documents/",
                  "name" : "Café.txt"
                }
              },
              "version" : 1
            }
            """;
        var parsed = WebDAVDrive.Manifest.Parse(Encoding.UTF8.GetBytes(mac));
        Assert.Equal("/Documents/", parsed.Items["Café.txt"].From);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_790_000_000), parsed.Items["Café.txt"].Deleted);
        Assert.Equal("Café.txt", parsed.KeyFor("Café.txt"));
        Assert.Empty(WebDAVDrive.Manifest.Parse("not json"u8.ToArray()).Items);
        Assert.Equal("Report 2.txt", WebDAVDrive.Numbered("Report.txt", 2, folder: false));
        Assert.Equal("Archive.v1 3", WebDAVDrive.Numbered("Archive.v1", 3, folder: true));
        Assert.Equal(".bashrc 2", WebDAVDrive.Numbered(".bashrc", 2, folder: false));
        Assert.Equal("a.b 2.c", WebDAVDrive.Numbered("a.b.c", 2, folder: false));
    }

    // MARK: Quota, thumbnails, sign-in

    [Fact]
    public async Task QuotaComesFromTheServerWhenItSays()
    {
        var (fake, nc) = Drive(CloudProvider.Nextcloud);
        var q = await nc.QuotaAsync();
        Assert.NotNull(q);
        Assert.Equal(fake.S.Nextcloud.UsedBytes, q!.Used);
        Assert.Equal(10_000_000_000, q.Total);
        Assert.Empty(q.Categories);
        var s = FakeWebDAVServer.State.Seeded();
        s.Nextcloud.Quota = null;      // unlimited: Nextcloud says -3
        Assert.Null(await Drive(CloudProvider.Nextcloud, s).Drive.QuotaAsync());
        Assert.Null(await Drive(CloudProvider.WebDAV).Drive.QuotaAsync());
        s = FakeWebDAVServer.State.Seeded();
        s.PlainHasQuota = true;
        s.Plain.Quota = 5_000_000;
        var pq = await Drive(CloudProvider.WebDAV, s).Drive.QuotaAsync();
        Assert.NotNull(pq);
        Assert.Equal(5_000_000, pq!.Total);
        Assert.Equal(s.Plain.UsedBytes, pq.Used);
    }

    [Fact]
    public async Task ThumbnailsComeFromNextcloudsPreviewService()
    {
        var (fake, d) = Drive(CloudProvider.Nextcloud);
        var photos = await d.ListAsync("dav:/Photos/");
        var jpg = photos.Single(n => n.Name == "Harbor at dusk.jpg");
        var png = await d.ThumbnailAsync(jpg, 256);
        Assert.NotNull(png);
        Assert.Equal(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, png![..4]);
        Assert.Equal(1, fake.S.PreviewRequests);
        Assert.Contains(fake.S.Calls, c => c == "GET /index.php/core/preview");
        // Nextcloud said there's no preview for this one: no request at all.
        var bin = await d.UploadAsync(File(new byte[10]), "data.bin", "dav:/Photos/", null, null);
        await d.ListAsync("dav:/Photos/");
        Assert.Null(await d.ThumbnailAsync(bin, 256));
        Assert.Equal(1, fake.S.PreviewRequests);
        // Unknown to the listing and not previewable: 404 → null.
        var unknown = bin.Copy();
        unknown.Id = "dav:/Photos/unlisted.bin";
        Assert.Null(await d.ThumbnailAsync(unknown, 64));
        Assert.Null(await d.ThumbnailAsync(await NodeAsync(d, d.RootID, "Photos"), 64));
        var (_, plain) = Drive(CloudProvider.WebDAV);
        Assert.Null(await plain.ThumbnailAsync(await NodeAsync(plain, "dav:/Photos/", "Beach.jpg"), 128));
    }

    [Fact]
    public async Task WrongPasswordMeansSignInNeeded()
    {
        var (fake, nc) = Drive(CloudProvider.Nextcloud, password: "revoked-app-password");
        var e = Assert.IsType<CloudException>(await Caught(() => nc.ListAsync(nc.RootID)));
        Assert.Equal(CloudErrorKind.SignInNeeded, e.Kind);
        Assert.Equal("Nextcloud (alex@cloud.example.com)", e.Detail);
        Assert.Equal("Nextcloud (alex@cloud.example.com) needs you to sign in again.", e.Message);
        var (pfake, plain) = Drive(CloudProvider.WebDAV, password: "wrong");
        var pe = Assert.IsType<CloudException>(await Caught(() => plain.ListAsync(plain.RootID)));
        Assert.Equal("WebDAV (alex@dav.example.com) needs you to sign in again.", pe.Message);
        Assert.True(pfake.S.Unauthorized >= 1);
        Assert.Single(pfake.S.Calls);   // a refused password isn't sent again
        var readme = new DriveNode { Id = "dav:/Readme.md", Zone = "dav", ParentID = "dav:/", Name = "Readme.md", Type = "FILE", Size = 10 };
        var de = Assert.IsType<CloudException>(await Caught(() => nc.DownloadAsync(readme, Dest("r"), null)));
        Assert.Equal(CloudErrorKind.SignInNeeded, de.Kind);
        // No password saved for a Nextcloud account: sign in again.
        var r = new CloudAccountRecord(CloudProvider.Nextcloud, "alex@cloud.example.com", "https://cloud.example.com", "alex");
        var me = Assert.Throws<CloudException>(() => WebDAVCloud.Make(r, new CloudSecret(), fake));
        Assert.Equal("Nextcloud (alex@cloud.example.com) needs you to sign in again.", me.Message);
        // Only WebDAV services.
        var od = new CloudAccountRecord(CloudProvider.OneDrive, "alex@example.com");
        Assert.Equal("OneDrive isn’t a WebDAV service.", Assert.Throws<CloudException>(() => WebDAVCloud.Make(od, new CloudSecret { Password = "x" }, fake)).Message);
    }

    [Fact]
    public async Task NextcloudUserIDCanDifferFromTheLoginName()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.Nextcloud.LoginName = "alex@example.com";
        var (fake, d) = Drive(CloudProvider.Nextcloud, s);
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Name == "Documents");
        Assert.Contains(fake.S.Calls, c => c.StartsWith("PROPFIND /remote.php/dav/files/alex/", StringComparison.Ordinal));
        Assert.DoesNotContain(fake.S.Calls, c => c.Contains("files/alex@example.com", StringComparison.Ordinal));
        // Asked once, even by many callers at the same time.
        var fresh = new WebDAVDrive(d.Record, s.Nextcloud.Password, fake);
        fake.Update(st => st.Calls.Clear());
        await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => fresh.ListAsync(fresh.RootID)));
        Assert.Single(fake.S.Calls, c => c == "PROPFIND /remote.php/dav/");
    }

    [Fact]
    public async Task NextcloudInASubfolderWorks()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.NextcloudBasePath = "/nextcloud";
        var (fake, d) = Drive(CloudProvider.Nextcloud, s);
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Name == "Documents");
        Assert.All(fake.S.Calls, c => Assert.Contains(" /nextcloud/", c));
        var up = await d.UploadAsync(File("hello"u8.ToArray()), "hello.txt", "dav:/Documents/", null, null);
        Assert.Equal("hello"u8.ToArray(), fake.S.File("/Documents/hello.txt")!.Data);
        Assert.NotNull(await d.ThumbnailAsync(up, 64));
        await d.TrashAsync([up]);
        var bin = await d.ListTrashAsync();
        await d.RestoreAsync([bin.Single(n => n.Name == "hello.txt")]);
        Assert.NotNull(fake.S.File("/Documents/hello.txt"));
        var c = await WebDAVCloud.ConnectAsync("cloud.example.com/nextcloud/", "alex", s.Nextcloud.Password, fake);
        Assert.Equal(CloudProvider.Nextcloud, c.Record.Provider);
        Assert.Equal("https://cloud.example.com/nextcloud", c.Record.Server);
        Assert.Equal("https://cloud.example.com/nextcloud", fake.DemoAccounts()[0].Record.Server);
    }

    [Fact]
    public void PlainHTTPIsRefusedExceptOnThisDevice()
    {
        Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("http://dav.example.com/webdav"));
        Assert.Throws<CloudException>(() => NextcloudLoginFlow.BaseURL("http://cloud.example.com"));
        Assert.Equal("http://localhost:8080/dav/", WebDAVCloud.FolderURL("http://localhost:8080/dav"));
        Assert.Equal("http://127.0.0.1:18080/dav/", WebDAVCloud.FolderURL("http://127.0.0.1:18080/dav/"));
        Assert.Equal("http://[::1]:8080/dav/", WebDAVCloud.FolderURL("http://[::1]:8080/dav"));
        var r = new CloudAccountRecord(CloudProvider.WebDAV, "x", "http://nas.example.com/dav/", "alex");
        Assert.Throws<CloudException>(() => WebDAVCloud.Make(r, new CloudSecret { Password = "p" }, new FakeWebDAVServer()));
        var e = Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("http://dav.example.com"));
        Assert.Equal(CloudErrorKind.Unsupported, e.Kind);
        Assert.Equal("Cirrus connects only over https://, so your password and files are never sent unencrypted. "
            + "Use the server’s https:// address (plain http:// works only for a server on this device, such as localhost).", e.Message);
        Assert.Equal("Cirrus can’t connect to “ftp://” addresses. Use the server’s https:// address.",
            Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("ftp://nas.example.com/")).Message);
    }

    [Fact]
    public void ServerAddressesAreNormalized()
    {
        var cases = new Dictionary<string, string>
        {
            ["cloud.example.com"] = "https://cloud.example.com",
            ["https://cloud.example.com/"] = "https://cloud.example.com",
            [" https://Cloud.Example.com/index.php/apps/files/?dir=/Photos "] = "https://cloud.example.com",
            ["https://example.com/nextcloud/index.php"] = "https://example.com/nextcloud",
            ["https://example.com/nextcloud/remote.php/dav/files/alex/"] = "https://example.com/nextcloud",
            ["example.com:8443/nc/login"] = "https://example.com:8443/nc",
            ["http://localhost:8080"] = "http://localhost:8080",
        };
        foreach (var (input, want) in cases) Assert.Equal(want, NextcloudLoginFlow.BaseURL(input));
        Assert.Equal("https://dav.example.com/webdav/", WebDAVCloud.FolderURL("dav.example.com/webdav"));
        Assert.Equal("https://nas.example.com/dav/", WebDAVCloud.FolderURL("https://user:secret@nas.example.com/dav?x=1#f"));
        Assert.Equal("https://nas.example.com:5006/my%20files/", WebDAVCloud.FolderURL("nas.example.com:5006/my files"));
        Assert.Equal("Enter your Nextcloud server’s address, like cloud.example.com.", Assert.Throws<CloudException>(() => NextcloudLoginFlow.BaseURL("  ")).Message);
        Assert.Equal("Enter the WebDAV folder’s address, like https://nas.example.com/webdav.", Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("")).Message);
        Assert.Equal("“https://” isn’t a server address. Enter an address like https://nas.example.com/webdav.",
            Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("https://")).Message);
        Assert.Throws<CloudException>(() => WebDAVCloud.FolderURL("ftp://nas.example.com/"));
        Assert.Equal("alex@cloud.example.com", WebDAVCloud.Title("alex", "https://cloud.example.com"));
        Assert.Equal("alex@example.com (cloud.example.com:8443)", WebDAVCloud.Title("alex@example.com", "https://cloud.example.com:8443/nc"));
        Assert.Equal("nas.example.com", WebDAVCloud.Title("", "https://nas.example.com/dav/"));
    }

    // MARK: Sign-in

    [Fact]
    public async Task LoginFlowV2()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.ApproveAfterPolls = 3;
        var fake = new FakeWebDAVServer(s);
        var interval = NextcloudLoginFlow.PollInterval;
        NextcloudLoginFlow.PollInterval = TimeSpan.FromMilliseconds(10);
        try
        {
            var pending = await NextcloudLoginFlow.BeginAsync("cloud.example.com", fake);
            Assert.Equal("cloud.example.com", pending.Server.Host);
            Assert.StartsWith("https://cloud.example.com/login/v2/flow/", pending.LoginURL.AbsoluteUri);
            var c = await NextcloudLoginFlow.PollAsync(pending, TimeSpan.FromSeconds(10), fake);
            Assert.Equal(CloudProvider.Nextcloud, c.Record.Provider);
            Assert.Equal("https://cloud.example.com", c.Record.Server);
            Assert.Equal("alex", c.Record.Username);
            Assert.Equal("alex@cloud.example.com", c.Record.Title);
            Assert.StartsWith("cloud:nextcloud:", c.Record.Id);
            var app = c.Secret.Password!;
            Assert.Contains(app, fake.S.Nextcloud.AppPasswords);
            Assert.NotEqual(fake.S.Nextcloud.Password, app);
            Assert.Equal(3, fake.S.LoginPolls);
            Assert.StartsWith("Cirrus", fake.S.LastUserAgent);
            // The new account works.
            var backend = WebDAVCloud.Make(c.Record, c.Secret, fake);
            Assert.Contains(await backend.ListAsync(backend.RootID), n => n.Name == "Documents");
            // A token works once.
            Assert.NotNull(await Caught(() => NextcloudLoginFlow.PollAsync(pending, TimeSpan.FromMilliseconds(100), fake)));

            // The user approves on the page (and never otherwise): the poll returns then.
            fake.Update(st => st.ApproveAfterPolls = null);
            var p2 = await NextcloudLoginFlow.BeginAsync("https://cloud.example.com/index.php/apps/files", fake);
            var waiting = NextcloudLoginFlow.PollAsync(p2, TimeSpan.FromSeconds(10), fake);
            await Task.Delay(100);
            Assert.False(waiting.IsCompleted);
            fake.Approve(p2.LoginURL);
            Assert.Equal("alex", (await waiting).Record.Username);

            // Never approved: a timeout, or cancellation.
            var p3 = await NextcloudLoginFlow.BeginAsync("https://cloud.example.com", fake);
            Assert.Equal("The Nextcloud sign-in wasn’t finished in time. Start it again and approve Cirrus in the browser.",
                Denied(await Caught(() => NextcloudLoginFlow.PollAsync(p3, TimeSpan.FromMilliseconds(100), fake))));
            using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
            Assert.IsAssignableFrom<OperationCanceledException>(await Caught(() => NextcloudLoginFlow.PollAsync(p3, TimeSpan.FromSeconds(30), fake, cts.Token)));
            // Not a Nextcloud.
            var notNC = Assert.IsType<CloudException>(await Caught(() => NextcloudLoginFlow.BeginAsync("https://dav.example.com", fake)));
            Assert.Equal("No Nextcloud server answered at dav.example.com. Check the address (for a server in a subfolder, include it, like example.com/nextcloud).", notNC.Message);
        }
        finally { NextcloudLoginFlow.PollInterval = interval; }
    }

    [Fact]
    public async Task ConnectDetectsNextcloud()
    {
        var fake = new FakeWebDAVServer(FakeWebDAVServer.State.Seeded());
        var pw = fake.S.Nextcloud.Password;
        // A Nextcloud WebDAV address, or just the server: both become a Nextcloud account.
        foreach (var url in new[] { "https://cloud.example.com/remote.php/dav/files/alex/", "https://cloud.example.com", "https://cloud.example.com/remote.php/webdav" })
        {
            var c = await WebDAVCloud.ConnectAsync(url, " alex ", pw, fake);
            Assert.Equal(CloudProvider.Nextcloud, c.Record.Provider);
            Assert.Equal("https://cloud.example.com", c.Record.Server);
            Assert.Equal("alex", c.Record.Username);
            Assert.Equal("alex@cloud.example.com", c.Record.Title);
            Assert.Equal(pw, c.Secret.Password);
        }
        // Even when status.php is hidden, Nextcloud's own properties give it away.
        fake.Update(s => s.HideStatusPage = true);
        Assert.Equal(CloudProvider.Nextcloud, (await WebDAVCloud.ConnectAsync("https://cloud.example.com/remote.php/dav/files/alex/", "alex", pw, fake)).Record.Provider);
        fake.Update(s => s.HideStatusPage = false);

        // A plain WebDAV folder (the missing trailing slash is fine).
        var plain = await WebDAVCloud.ConnectAsync("https://dav.example.com/webdav", "alex", fake.S.Plain.Password, fake);
        Assert.Equal(CloudProvider.WebDAV, plain.Record.Provider);
        Assert.Equal("https://dav.example.com/webdav/", plain.Record.Server);
        Assert.Equal("alex@dav.example.com", plain.Record.Title);
        Assert.StartsWith("cloud:webdav:", plain.Record.Id);
        var backend = WebDAVCloud.Make(plain.Record, plain.Secret, fake);
        Assert.Equal(CloudProvider.WebDAV, backend.Provider);
        Assert.Contains(await backend.ListAsync(backend.RootID), n => n.Name == "Backups");

        // Wrong password, wrong path, a file, and http://.
        const string bad = "The server didn’t accept that user name and password. If the account uses two-step sign-in, "
            + "create an app password in the server’s security settings and use that.";
        Assert.Equal(bad, Denied(await Caught(() => WebDAVCloud.ConnectAsync("https://dav.example.com/webdav/", "alex", "nope", fake))));
        Assert.Equal(bad, Denied(await Caught(() => WebDAVCloud.ConnectAsync("https://cloud.example.com", "alex", "nope", fake))));
        Assert.Equal("Enter your Nextcloud user name.", Assert.IsType<CloudException>(await Caught(() => WebDAVCloud.ConnectAsync("https://cloud.example.com", "", pw, fake))).Message);
        var wrongPath = Assert.IsType<CloudException>(await Caught(() => WebDAVCloud.ConnectAsync("https://dav.example.com/elsewhere/", "alex", fake.S.Plain.Password, fake)));
        Assert.Equal(CloudErrorKind.NotConfigured, wrongPath.Kind);
        Assert.Equal("There’s no WebDAV folder at that address. Check the path (it often ends in /webdav, /dav or /remote.php/webdav).", wrongPath.Message);
        Assert.Equal(CloudErrorKind.NotConfigured,
            Assert.IsType<CloudException>(await Caught(() => WebDAVCloud.ConnectAsync("https://dav.example.com/webdav/Backups/settings-backup.json", "alex", fake.S.Plain.Password, fake))).Kind);
        // A web page where the folder should be.
        Assert.Equal("That address is a web page, not a WebDAV folder. Check the path (it often ends in /webdav, /dav or /remote.php/webdav).",
            Assert.IsType<CloudException>(await Caught(() => WebDAVCloud.ConnectAsync("https://cloud.example.com/login/v2/flow/page", "alex", pw, fake))).Message);
        fake.Update(s => s.Calls.Clear());
        Assert.NotNull(await Caught(() => WebDAVCloud.ConnectAsync("http://dav.example.com/webdav/", "alex", "p", fake)));
        Assert.Empty(fake.S.Calls);
    }

    [Fact]
    public async Task ConnectTurnsAnOwnCloudAddressIntoItsWebDAVFolder()
    {
        var s = FakeWebDAVServer.State.Seeded();
        s.OwnCloud = true;
        var fake = new FakeWebDAVServer(s);
        var c = await WebDAVCloud.ConnectAsync("cloud.example.com", "alex", s.Nextcloud.Password, fake);
        Assert.Equal(CloudProvider.WebDAV, c.Record.Provider);
        Assert.Equal("https://cloud.example.com/remote.php/webdav/", c.Record.Server);
        Assert.Equal("alex@cloud.example.com", c.Record.Title);
        var d = WebDAVCloud.Make(c.Record, c.Secret, fake);
        Assert.Contains(await d.ListAsync(d.RootID), n => n.Name == "Documents");
        // Its trash is Cirrus's own folder (plain WebDAV never sends DELETE to trash).
        fake.Update(st => st.Calls.Clear());
        await d.TrashAsync([await NodeAsync((WebDAVDrive)d, d.RootID, "Readme.md")]);
        Assert.DoesNotContain(fake.S.Calls, x => x.StartsWith("DELETE", StringComparison.Ordinal));
        Assert.NotNull(fake.S.File("/Deleted by Cirrus/Readme.md"));
    }

    [Fact]
    public async Task DemoAccountsWork()
    {
        var fake = FakeWebDAVServer.Demo();
        fake.Update(s => s.Latency = 0);
        var accounts = fake.DemoAccounts();
        Assert.Equal(2, accounts.Count);
        var nc = accounts.Single(a => a.Record.Provider == CloudProvider.Nextcloud);
        Assert.Equal("cloud:nextcloud:demo", nc.Record.Id);
        Assert.Equal("alex@cloud.example.com", nc.Record.Title);
        var router = new FakeCloudRouter(fake);
        Assert.True(fake.Handles(new Uri("https://cloud.example.com/status.php")));
        Assert.False(fake.Handles(new Uri("https://graph.microsoft.com/v1.0/me")));
        var ncb = WebDAVCloud.Make(nc.Record, nc.Secret, router);
        Assert.Equal(CloudProvider.Nextcloud, ncb.Provider);
        Assert.Contains(await ncb.ListAsync(ncb.RootID), n => n.Name == "Documents");
        Assert.Contains(await ncb.ListTrashAsync(), n => n.Name == "Old draft.txt");
        Assert.NotNull(await ncb.QuotaAsync());
        var dv = accounts.Single(a => a.Record.Provider == CloudProvider.WebDAV);
        Assert.Equal("cloud:webdav:demo", dv.Record.Id);
        Assert.Equal("alex@dav.example.com", dv.Record.Title);
        var previous = CloudBackends.Transport;
        CloudBackends.Transport = router;
        try
        {
            var dvb = CloudBackends.Make(dv.Record, dv.Secret);
            Assert.Contains(await dvb.ListAsync(dvb.RootID), n => n.Name == "Backups");
        }
        finally { CloudBackends.Transport = previous; }
        // The demo content is generic.
        var all = await ncb.WalkAsync(ncb.RootID);
        Assert.True(all.Count > 8);
        // Demo state can be kept on disk between runs.
        var dir = TestEnv.TempDir("dav-demo");
        var kept = FakeWebDAVServer.Demo(dir);
        kept.Update(s => s.Latency = 0);
        var kc = kept.DemoAccounts()[0];
        var kb = WebDAVCloud.Make(kc.Record, kc.Secret, kept);
        await kb.CreateFolderAsync("Kept", kb.RootID);
        var reopened = FakeWebDAVServer.Demo(dir);
        Assert.NotNull(reopened.S.File("/Kept/"));
    }

    [Fact]
    public async Task CancellingADownloadStopsIt()
    {
        var (fake, d) = Drive(CloudProvider.Nextcloud);
        await d.UserIDAsync();
        fake.Update(s => s.Latency = 0.5);
        var n = new DriveNode { Id = "dav:/Readme.md", Zone = "dav", ParentID = "dav:/", Name = "Readme.md", Type = "FILE", Size = 10 };
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var dest = Dest("r.md");
        Assert.IsAssignableFrom<OperationCanceledException>(await Caught(() => d.DownloadAsync(n, dest, null, cts.Token)));
        Assert.False(System.IO.File.Exists(dest));
    }

    // MARK: Wire details

    [Fact]
    public void MultistatusParserReadsWhatServersSend()
    {
        const string xml = """
            <?xml version="1.0"?>
            <D:multistatus xmlns:D="DAV:" xmlns:o="http://owncloud.org/ns" xmlns:n="http://nextcloud.org/ns">
             <D:response>
              <D:href>/dav/Folder%20A/</D:href>
              <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getetag>W/"abc"</D:getetag>
                <o:share-types><o:share-type>0</o:share-type><o:share-type>3</o:share-type></o:share-types></D:prop>
                <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
              <D:propstat><D:prop><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
             </D:response>
             <D:response><D:href>https://h.example.com/dav/Folder%20A/a%26b.txt</D:href><D:propstat><D:prop>
               <D:getcontentlength>12</D:getcontentlength><D:getlastmodified>Mon, 21 Sep 2026 14:13:20 GMT</D:getlastmodified>
               <n:has-preview>true</n:has-preview><D:displayname><![CDATA[a&b]]></D:displayname></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
             </D:response>
             <D:response><D:href>gone%20file.txt</D:href><D:status>HTTP/1.1 404 Not Found</D:status></D:response>
             <D:response><D:href>../Folder%20A/./sub/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
               <D:current-user-principal><D:href>/principals/users/alex/</D:href></D:current-user-principal></D:prop>
               <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            </D:multistatus>
            """;
        var res = DAVMultistatus.Parse(Encoding.UTF8.GetBytes(xml), "https://h.example.com/dav/Folder%20A/");
        Assert.Equal(4, res.Count);
        Assert.Equal("/dav/Folder A/", res[0].Path);
        Assert.True(res[0].IsCollection);
        Assert.Equal("abc", res[0].Etag);
        Assert.True(res[0].IsShared);
        Assert.Equal("0,3", res[0].OC("share-types"));
        Assert.Null(res[0].Dav("getcontentlength"));      // only from 200 propstats
        Assert.Equal("/dav/Folder A/a&b.txt", res[1].Path);
        Assert.False(res[1].IsCollection);
        Assert.Equal(12, res[1].Size);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_790_000_000), res[1].Modified);
        Assert.True(res[1].HasPreview);
        Assert.Equal("a&b", res[1].Dav("displayname"));
        Assert.Equal(404, res[2].Status);
        Assert.Equal("/dav/Folder A/gone file.txt", res[2].Path);
        Assert.Equal("/dav/Folder A/sub/", res[3].Path);
        Assert.Equal("/principals/users/alex/", res[3].Dav("current-user-principal"));
        Assert.Null(res[3].HasPreview);
        // Default namespaces, and (leniently) no namespace at all.
        var plainNS = DAVMultistatus.Parse(Encoding.UTF8.GetBytes(
            "<multistatus xmlns=\"DAV:\"><response><href>/x/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"),
            "https://h.example.com/x/");
        Assert.True(Assert.Single(plainNS).IsCollection);
        var noNS = DAVMultistatus.Parse(Encoding.UTF8.GetBytes("<multistatus><response><href>/x/y</href></response></multistatus>"), "https://h.example.com/x/");
        Assert.Equal("/x/y", Assert.Single(noNS).Path);
        // Cut off, empty, or a web page: an error, never an empty folder.
        foreach (var bad in new[] { xml[..(xml.Length / 2)], "", "<!DOCTYPE html><html><body>Login</body></html>", "<d:error xmlns:d=\"DAV:\"/>" })
            Assert.Equal("The server’s folder listing was incomplete or unreadable, so nothing was shown. Try again.",
                Assert.Throws<CloudException>(() => DAVMultistatus.Parse(Encoding.UTF8.GetBytes(bad), "https://h.example.com/")).Message);
    }

    [Fact]
    public void HttpDatesParseInEveryForm()
    {
        var want = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        Assert.Equal(want, DAVDates.Http("Mon, 21 Sep 2026 14:13:20 GMT"));
        Assert.Equal(want, DAVDates.Http("Sat, 21 Sep 2026 14:13:20 GMT"));    // a wrong weekday is ignored
        Assert.Equal(want, DAVDates.Http("Monday, 21-Sep-26 14:13:20 GMT"));   // RFC 850
        Assert.Equal(want, DAVDates.Http("Mon Sep 21 14:13:20 2026"));          // asctime
        Assert.Equal(want, DAVDates.Http("Mon, 21 Sep 2026 16:13:20 +0200"));
        Assert.Equal("Mon, 21 Sep 2026 14:13:20 GMT", DAVDates.HttpString(want));
        Assert.Null(DAVDates.Http("yesterday"));
        Assert.Null(DAVDates.Http(""));
        Assert.Equal(want, DAVDates.Iso8601("2026-09-21T14:13:20Z"));
        Assert.Equal(want.AddMilliseconds(500), DAVDates.Iso8601("2026-09-21T16:13:20.5+02:00"));
        Assert.Equal(want, DAVDates.Iso8601("Mon, 21 Sep 2026 14:13:20 GMT"));
        Assert.Equal("2026-09-21T14:13:20Z", DAVDates.IsoString(want.AddMilliseconds(123)));
    }

    [Fact]
    public void ErrorsAreSentencesAUserCanActOn()
    {
        static DAVResponse R(int status, string body = "") => new(status, Encoding.UTF8.GetBytes(body), [], false);
        const string sabre = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<d:error xmlns:d=\"DAV:\" xmlns:s=\"http://sabredav.org/ns\">"
            + "<s:exception>Sabre\\DAV\\Exception\\Forbidden</s:exception><s:message>Not allowed here</s:message></d:error>";
        Assert.Equal("The server didn’t allow Cirrus to upload “a.txt”: Not allowed here.", WebDAVDrive.Failure(R(403, sabre), "upload “a.txt”").Message);
        Assert.Equal("The server didn’t allow Cirrus to upload “a.txt”.", WebDAVDrive.Failure(R(403, "<html>nope</html>"), "upload “a.txt”").Message);
        Assert.Equal(CloudErrorKind.NotFound, WebDAVDrive.Failure(R(404), "x").Kind);
        Assert.Equal(CloudErrorKind.NotFound, WebDAVDrive.Failure(R(409), "x").Kind);
        Assert.Equal("The item no longer exists on the server.", WebDAVDrive.Failure(R(410), "x").Message);
        Assert.Equal("The server doesn’t accept a file this large. Its administrator can raise the upload limit.", WebDAVDrive.Failure(R(413), "x").Message);
        Assert.Equal("The name or folder path is too long for the server.", WebDAVDrive.Failure(R(414), "x").Message);
        Assert.Equal("The server answered with a redirect (302) instead of doing it. Check the server address in the account.", WebDAVDrive.Failure(R(302), "x").Message);
        Assert.Equal("The server couldn’t list “Documents” (500: Not allowed here).", WebDAVDrive.Failure(R(500, sabre), "list “Documents”").Message);
        Assert.Equal("Not allowed here", DAVErrorBody.Message(Encoding.UTF8.GetBytes(sabre)));
        Assert.Null(DAVErrorBody.Message(Encoding.UTF8.GetBytes("<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n<html><body>x</body></html>")));
        // Network failures.
        Assert.Equal("“nas.example.com” took too long to answer. Try again.", DAVClient.NetworkError(new TimeoutException(), "nas.example.com").Message);
        Assert.Equal("The secure connection to “nas.example.com” failed: its certificate isn’t trusted by this device. Check the server’s https setup.",
            DAVClient.NetworkError(new HttpRequestException(HttpRequestError.SecureConnectionError, "tls"), "nas.example.com").Message);
        Assert.Contains(DAVClient.NetworkError(new HttpRequestException(HttpRequestError.NameResolutionError, "dns"), "nas.example.com").Message,
            new[] { "Cirrus couldn’t find the server “nas.example.com”. Check the address.", "This device is offline. Connect to the internet and try again." });
        Assert.Contains(DAVClient.NetworkError(new HttpRequestException(HttpRequestError.ConnectionError, "refused"), "nas.example.com").Message,
            new[] { "“nas.example.com” didn’t accept a connection. Check that the server is running and the address is right.", "This device is offline. Connect to the internet and try again." });
        // The numeric part of Nextcloud's OC-FileId.
        Assert.Equal("42", WebDAVDrive.NumericFileID("00000042ocabcdef"));
        Assert.Null(WebDAVDrive.NumericFileID("ocabcdef"));
    }

    [Fact]
    public async Task RequestsCarryCredentialsOnlyAsBasicAuthAndNeverLogThem()
    {
        var (fake, d) = Drive(CloudProvider.WebDAV);
        using var log = new LogCapture();
        await d.ListAsync(d.RootID);
        await d.DownloadAsync(await NodeAsync(d, "dav:/Documents/", "Notes.txt"), Dest("n.txt"), null);
        Assert.DoesNotContain(fake.S.Plain.Password, log.Text);
        Assert.DoesNotContain("Notes.txt", log.Text);
        Assert.DoesNotContain("Basic ", log.Text);
        Assert.Contains("dav PROPFIND dav.example.com → 207", log.Text);
        Assert.Equal("Cirrus (Windows)", fake.S.LastUserAgent);
    }
}
