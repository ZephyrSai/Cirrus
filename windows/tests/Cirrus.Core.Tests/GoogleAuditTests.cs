using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>Regression tests for the independent audit of the Windows Google move.</summary>
public class GoogleAuditTests
{
    [Fact]
    public async Task OneRunPerAccountPairAndStagingNeverShared()
    {
        var (_, api) = await G.Connect();
        var src = TestEnv.TempDir("pair-src");
        TestEnv.Write("hello", Path.Combine(src, "a.txt"));
        var state = TestEnv.TempDir("pair-state");
        var e = G.Engine(api, state, src);
        var ev = await e.EvaluateAsync(null);
        // Another pair's staging folder (a run for another iCloud account) must survive this pair's run.
        var other = Path.Combine(state, "staging", MigrationEngine.StoreName("other:icloud", api.AccountID));
        TestEnv.Write("in flight", Path.Combine(other, "x", "photo.heic"));
        Assert.True(MoveRuns.TryBegin(e.RunKey));
        try
        {
            await Assert.ThrowsAsync<SyncException>(() => e.RunAsync(ev, null));
            var again = G.Engine(api, state, src);
            Assert.True(again.IsRunning);
            Assert.Same(e.Store, again.Store);   // one journal per pair in this process
        }
        finally { MoveRuns.End(e.RunKey); }
        var r = await e.RunAsync(ev, null);
        Assert.Equal(1, r.DriveCopied);
        Assert.False(e.IsRunning);
        Assert.True(File.Exists(Path.Combine(other, "x", "photo.heic")));
    }

    [Fact]
    public async Task ICloudForWindowsTargetMustFitOnThisPC()
    {
        var s = new FakeGoogle.State();
        s.AddUserFile("big.bin", new byte[200_000]);
        var (_, api) = await G.Connect(s, GoogleScopes.Import);
        var icloud = TestEnv.TempDir("small-disk");
        var e = G.Import(api, TestEnv.TempDir("small-state"), driveRoot: icloud, options: new ImportOptions { IncludePhotos = false });
        e.FreeSpace = p => p.StartsWith(icloud, StringComparison.Ordinal) ? 10_000 : null;
        var ev = await e.EvaluateAsync(null);
        Assert.True(ev.TargetNeeded >= 200_000 && !ev.FitsTarget && !ev.Fits);
        Assert.Contains(ev.Warnings, w => w.StartsWith("Not enough space on this PC"));
        await Assert.ThrowsAsync<SyncException>(() => e.RunAsync(ev, null));
        Assert.Empty(Directory.EnumerateFileSystemEntries(icloud));
    }

    [Fact]
    public async Task CloudOnlyFilesInICloudForWindowsCountAgainstThisPC()
    {
        var (_, api) = await G.Connect();
        var src = TestEnv.TempDir("cloud-only");
        File.WriteAllBytes(Path.Combine(src, "movie.mov"), new byte[300_000]);
        TestEnv.Write("local", Path.Combine(src, "notes.txt"));
        var e = G.Engine(api, TestEnv.TempDir("cloud-only-state"), src);
        e.IsCloudOnly = p => p.EndsWith("movie.mov", StringComparison.Ordinal);
        e.FreeSpace = p => p.StartsWith(src, StringComparison.Ordinal) ? 100_000 : null;
        var ev = await e.EvaluateAsync(null);
        Assert.True(ev.CloudOnlyFiles == 1 && ev.LocalNeeded >= 300_000 && !ev.Fits);
        Assert.Contains(ev.Warnings, w => w.StartsWith("Not enough space on this PC"));
        await Assert.ThrowsAsync<SyncException>(() => e.RunAsync(ev, null));
        e.FreeSpace = _ => null;
        var ev2 = await e.EvaluateAsync(null);
        Assert.True(ev2.Fits);
        Assert.Contains(ev2.Warnings, w => w.Contains("only in iCloud: iCloud for Windows downloads it"));
    }

    [Fact]
    public async Task CopiesOfICloudMadeElsewhereAreNotBroughtBack()
    {
        var s = new FakeGoogle.State();
        s.AddUserFolder("From iCloud");                                                   // the Mac's folder: its private tag is unreadable here
        var marked = s.AddUserFolder("Old iPhone", properties: new() { ["cirrusRole"] = "from-icloud" });
        s.AddUserFile("inside.txt", Encoding.UTF8.GetBytes("x"), marked);
        var mine = s.AddUserFolder("Projects");
        s.AddUserFile("plan.txt", Encoding.UTF8.GetBytes("plan"), mine);
        var (g, api) = await G.Connect(s, GoogleScopes.Import);
        var icloud = TestEnv.TempDir("elsewhere");
        var e = G.Import(api, TestEnv.TempDir("elsewhere-state"), driveRoot: icloud, options: new ImportOptions { IncludePhotos = false });
        var ev = await e.EvaluateAsync(null);
        Assert.Equal(["Projects/plan.txt"], ev.DrivePending.Select(d => d.Rel));
        Assert.Contains(ev.Warnings, w => w.Contains("“From iCloud” in Google Drive is left out: it looks like Cirrus’s copy"));
        Assert.Contains(ev.Warnings, w => w.Contains("“Old iPhone” in Google Drive is left out: it’s Cirrus’s copy"));
        // And the folder this PC makes carries the public marker.
        var src = TestEnv.TempDir("elsewhere-src");
        TestEnv.Write("hi", Path.Combine(src, "a.txt"));
        var fwd = G.Engine(api, TestEnv.TempDir("elsewhere-fwd"), src, key: "other:icloud");
        await fwd.RunAsync(await fwd.EvaluateAsync(null), null);
        Assert.Contains(g.S.Files.Values, f => f.ByApp && f.IsNative == false && f.Properties.GetValueOrDefault("cirrusRole") == "from-icloud");
    }

    [Fact]
    public async Task AnEarlierCopyIsRecycledByItsOnDiskNameNeverOverwritten()
    {
        Assert.Equal("Café.txt", ImportEngine.SafeName("Café.txt"));   // names are compared composed (NFC)
        var s = new FakeGoogle.State();
        s.AddUserFile("Café.txt", Encoding.UTF8.GetBytes("from google"));
        var (_, api) = await G.Connect(s, GoogleScopes.Import);
        var icloud = TestEnv.TempDir("nfc");
        TestEnv.Write("my own edits", Path.Combine(icloud, "From Google Drive", "Café.txt"));
        var bin = new TrashBin(TestEnv.TempDir("nfc-bin"));
        var e = G.Import(api, TestEnv.TempDir("nfc-state"), driveRoot: icloud, options: new ImportOptions { IncludePhotos = false }, bin: bin);
        var r = await e.RunAsync(await e.EvaluateAsync(null), null);
        Assert.True(r.DriveUpdated == 1 && r.Failed.Count == 0, string.Join("; ", r.Failed));
        Assert.Equal(["Café.txt"], bin.Items.Select(i => i.Normalize(NormalizationForm.FormC)));
        Assert.Equal("from google", File.ReadAllText(Path.Combine(icloud, "From Google Drive", "Café.txt")));
    }

    [Fact]
    public async Task UnreadableFromGooglePhotosAlbumStopsTheCheck()
    {
        var (_, api) = await G.Connect();
        var lib = new TestPhotos
        {
            Assets = [TestPhotos.Asset(1)], UserAlbums = [new("album:fromgoogle", "From Google Photos", PhotoAlbumKind.Album)],
            FailingAlbums = ["album:fromgoogle"],
        };
        var e = G.Engine(api, TestEnv.TempDir("album-fail"), photos: lib, options: new MigrationOptions { IncludeDrive = false });
        var ex = await Assert.ThrowsAsync<SyncException>(() => e.EvaluateAsync(null));
        Assert.Contains("can’t tell which photos came from Google", ex.Message);
    }

    [Fact]
    public async Task PhotosAreRecordedOneByOneAndAGoneAlbumIsMadeAgain()
    {
        var (_, api) = await G.Connect(scopes: GoogleScopes.Import);
        var dir = TestEnv.TempDir("per-file");
        var parts = TakeoutFixture.Make(dir, "zip");
        var rec = new RecordingPhotos(Path.Combine(dir, "icloud")) { FailOnName = "IMG_0003.MP4" };
        var state = Path.Combine(dir, "state");
        var o = new ImportOptions { IncludeDrive = false };
        var r1 = await G.Import(api, state, parts, photos: rec, options: o).RunAsync(await G.Import(api, state, parts, photos: rec, options: o).EvaluateAsync(null), null);
        Assert.Equal(9, r1.PhotosImported);
        Assert.Single(r1.Failed, f => f.StartsWith("IMG_0003.MP4"));
        // The user deletes "From Google Photos"; the next run makes it again instead of failing every add.
        rec.AlbumList.RemoveAll(a => a.Name == "From Google Photos");
        rec.FailOnName = null;
        var e2 = G.Import(api, state, parts, photos: rec, options: o);
        var ev2 = await e2.EvaluateAsync(null);
        Assert.Equal(["IMG_0003.MP4"], ev2.PhotoPending.Select(p => p.FileName));   // the still that went in isn't sent again
        var r2 = await e2.RunAsync(ev2, null);
        Assert.True(r2.PhotosImported == 1, string.Join("; ", r2.Failed));
        Assert.Single(rec.Assets, a => a.Filename == "IMG_0003.HEIC");
        Assert.Contains(rec.Members("From Google Photos"), a => a.Filename == "IMG_0003.MP4");
        // The iCloud → Google direction leaves out what came from Google even outside that album.
        var heic = rec.Assets.Single(a => a.Filename == "IMG_0002.JPG");
        var lib = new TestPhotos { Assets = [TestPhotos.Asset(7, name: "IMG_0002.JPG", size: heic.Size), TestPhotos.Asset(8)] };
        var fev = await G.Engine(api, state, photos: lib, options: new MigrationOptions { IncludeDrive = false }).EvaluateAsync(null);
        Assert.Equal(["IMG_0008.HEIC"], fev.PhotoPending.Select(p => p.FileName));
        Assert.Contains(fev.Warnings, w => w.Contains("that Cirrus copied from Google Photos"));
    }
}
