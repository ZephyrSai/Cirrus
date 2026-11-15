using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>Google → iCloud (port of GoogleImportTests.swift), against the fake Google server.</summary>
public class GoogleImportTests
{
    // MARK: Takeout parsing

    [Theory]
    [InlineData("zip")]
    [InlineData("tgz")]
    [InlineData("folder")]
    public async Task TakeoutSidecarsAlbumsAndPairs(string format)
    {
        var dir = TestEnv.TempDir("takeout-" + format);
        var inputs = TakeoutFixture.Make(dir, format);
        var r = await new TakeoutReader(inputs).ScanAsync(null);
        var byName = r.Items.GroupBy(i => i.FileName).ToDictionary(g => g.Key, g => g.ToList());
        Assert.Equal(11, r.Items.Count);
        Assert.Equal(new HashSet<string> { "IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.HEIC", "IMG_0003.MP4", "IMG_0004.JPG", "IMG_0005.JPG", "IMG_0005-edited.JPG",
            TakeoutFixture.LongName, "NOSIDECAR.PNG", "IMG_0007.JPG" }, byName.Keys.ToHashSet());
        // Every naming style found its sidecar.
        foreach (var (name, date) in TakeoutFixture.Dates.Where(kv => kv.Key != "IMG_0004(1).JPG"))
            Assert.True(byName.GetValueOrDefault(name)?.Any(i => i.Taken == date) == true, "date for " + name);
        Assert.Equal(2, byName["IMG_0004.JPG"].Count);   // "(1)" twin keeps Google's original name but stays a separate photo
        Assert.Contains(byName["IMG_0004.JPG"], i => i.Taken == TakeoutFixture.Dates["IMG_0004(1).JPG"]);
        var one = byName["IMG_0001.JPG"].Single();
        Assert.True(one.Albums.SequenceEqual(["Lisbon trip"]) && one.Favorite && one.Caption == "Tram 28" && one.Latitude == 38.7139);
        Assert.Equal(["Lisbon trip"], byName["IMG_0007.JPG"].Single().Albums);   // album + year copies merged, sidecar from the other part
        Assert.True(byName["IMG_0005-edited.JPG"].Single().IsEdited);
        var live = byName["IMG_0003.MP4"].Single();
        Assert.True(live.IsCompanion && live.Group == byName["IMG_0003.HEIC"].Single().Group && live.Taken == TakeoutFixture.Dates["IMG_0003.HEIC"]);
        Assert.Null(byName["NOSIDECAR.PNG"].Single().Taken);
        Assert.Equal(["clip.avi"], r.Skipped.Select(s => s.Name));
        Assert.DoesNotContain(r.Items, i => i.Path.Replace('\\', '/').Contains("Takeout/Drive/"));   // other products ignored
        Assert.DoesNotContain(r.Items, i => i.FileName == "IMG_0009.JPG");                             // in Google's trash
        Assert.Equal(format == "folder" ? 0 : 2, r.Parts);
    }

    [Fact]
    public void SidecarNamesAcrossGenerations()
    {
        static string? S(string n, params string[] j) => TakeoutReader.SidecarName(n, j.ToHashSet());
        Assert.Equal("IMG_3479.JPG(1).json", S("IMG_3479(1).JPG", "IMG_3479.JPG(1).json", "IMG_3479.JPG.json"));
        Assert.Equal("Scan35.jpg.supplemental-metadata(1).json", S("Scan35(1).jpg", "Scan35.jpg.supplemental-metadata(1).json"));
        Assert.Equal("IMG_1.jpg.json", S("IMG_1-edited.jpg", "IMG_1.jpg.json"));
        Assert.Equal("IMG_1.jpg.supplemental-metadata.json", S("IMG_1-bearbeitet.jpg", "IMG_1.jpg.supplemental-metadata.json"));
        var longName = "20230615_142034_old_phone.jpg";   // sidecar names stop at 46 characters before ".json"
        var cut = (longName + ".supplemental-metadata")[..46] + ".json";
        Assert.Equal(51, cut.Length);
        Assert.Equal(cut, S(longName, cut));
        Assert.Null(S("IMG_2.jpg", "IMG_20.jpg.json"));
    }

    // MARK: Takeout → iCloud Photos

    [Fact]
    public async Task TakeoutImportKeepsDatesAlbumsFavoritesAndIsIncremental()
    {
        var (_, api) = await G.Connect(scopes: GoogleScopes.Import);
        var dir = TestEnv.TempDir("import");
        var parts = TakeoutFixture.Make(dir, "zip");
        var rec = new RecordingPhotos(Path.Combine(dir, "icloud"));
        var state = Path.Combine(dir, "state");
        var o = new ImportOptions { IncludeDrive = false };
        var e = G.Import(api, state, parts, photos: rec, options: o);
        var ev = await e.EvaluateAsync(null);
        Assert.Equal(10, ev.PhotoPending.Count);                       // the edited copy is left out by default
        Assert.True(ev.Albums.Select(a => a.Title).SequenceEqual(["Lisbon trip"]) && ev.FavoritesPending == 1);
        Assert.Contains(ev.Warnings, w => w.Contains("captions and places from Google aren’t written"));
        var r = await e.RunAsync(ev, null);
        Assert.True(r.PhotosImported == 10 && r.Failed.Count == 0, string.Join("; ", r.Failed));
        Assert.True(r.AlbumsCreated == 1 && r.AlbumAdds == 2 && r.FavoritesSet == 1);
        // Google's capture date travels as the file date (what iCloud.com's upload takes when a file has none of its own).
        Assert.Equal(TakeoutFixture.Dates["IMG_0001.JPG"].UtcDateTime, rec.ReceivedMtime["IMG_0001.JPG"]);
        Assert.Equal(TakeoutFixture.Dates[TakeoutFixture.LongName].UtcDateTime, rec.ReceivedMtime[TakeoutFixture.LongName]);
        // The copy holds the export's bytes unchanged.
        Assert.Equal(DemoArt.Png(240, 160, 0.05, "Tram 28"), File.ReadAllBytes(rec.Copy("IMG_0001.JPG")!));
        // Live Photo halves go to iCloud together.
        Assert.Contains(rec.ImportCalls, c => c.ToHashSet().SetEquals(["IMG_0003.HEIC", "IMG_0003.MP4"]));
        Assert.Equal(10, rec.Members("From Google Photos").Count);
        Assert.Equal(new HashSet<string> { "IMG_0001.JPG", "IMG_0007.JPG" }, rec.Members("Lisbon trip").Select(a => a.Filename).ToHashSet());
        Assert.Equal(["IMG_0001.JPG"], rec.Assets.Where(a => a.IsFavorite).Select(a => a.Filename));
        Assert.False(Directory.Exists(Path.Combine(state, "staging")));   // temporary space released
        // The same items from a fresh export (here as .tgz) are recognised: nothing is copied twice.
        var again = TakeoutFixture.Make(Path.Combine(dir, "second"), "tgz");
        var e2 = G.Import(api, state, again, photos: rec, options: o);
        var ev2 = await e2.EvaluateAsync(null);
        Assert.True(ev2.IsUpToDate);
        var calls = rec.ImportCalls.Count;
        var r2 = await e2.RunAsync(ev2, null);
        Assert.Equal("Everything was already in iCloud — 1 skipped", r2.Summary);
        Assert.Equal(calls, rec.ImportCalls.Count);
        // The export itself was only read.
        Assert.All(again.Concat(parts), p => Assert.True(File.Exists(p)));
    }

    [Fact]
    public async Task ReadOnlyModeStopsBeforeAnythingIsWritten()
    {
        var (g, api) = await G.Connect(scopes: GoogleScopes.Import);
        var dir = TestEnv.TempDir("ro");
        var parts = TakeoutFixture.Make(dir, "zip");
        var rec = new RecordingPhotos(Path.Combine(dir, "icloud"));
        var icloud = TestEnv.TempDir("ro-drive");
        g.Update(s => s.AddUserFile("budget.xlsx", Encoding.UTF8.GetBytes("numbers")));
        var e = G.Import(api, Path.Combine(dir, "state"), parts, driveRoot: icloud, photos: rec, readOnly: true);
        var ev = await e.EvaluateAsync(null);
        Assert.True(ev.ReadOnly && !ev.Fits);
        Assert.Contains(ev.Warnings, w => w.StartsWith("Read-only mode is on"));
        await Assert.ThrowsAsync<ReadOnlyException>(() => e.RunAsync(ev, null));
        Assert.True(rec.ImportCalls.Count == 0 && rec.AlbumList.Count == 0);
        Assert.Empty(Directory.EnumerateFileSystemEntries(icloud));
        // The global switch is enforced inside the engine and the backends as well.
        SafetyPolicy.ReadOnlyICloud = true;
        try
        {
            var e2 = G.Import(api, Path.Combine(dir, "state2"), parts, driveRoot: icloud, photos: rec, readOnly: false);
            var ev2 = await e2.EvaluateAsync(null);
            var r2 = await e2.RunAsync(ev2, null);
            Assert.True(r2.Stopped is not null || r2.Failed.Count > 0);
            Assert.True(rec.ImportCalls.Count == 0 && rec.AlbumList.Count == 0);
        }
        catch (ReadOnlyException) { }
        finally { SafetyPolicy.ReadOnlyICloud = false; }
        Assert.True(rec.ImportCalls.Count == 0 && rec.AlbumList.Count == 0);
    }

    // MARK: Google Drive → iCloud Drive

    [Fact]
    public async Task DriveCopiesMyDriveExportsDocsAndReplacesViaTrash()
    {
        var s = new FakeGoogle.State();
        var notes = s.AddUserFile("notes.txt", Encoding.UTF8.GetBytes("first"));
        s.AddUserFile("notes.txt", Encoding.UTF8.GetBytes("a different file with the same name"));
        var trip = s.AddUserFolder("Trip");
        var plan = Enumerable.Range(0, 300_000).Select(i => (byte)(i % 239)).ToArray();
        s.AddUserFile("plan.pdf", plan, trip);
        s.AddUserDoc("Meeting notes");
        s.AddUserDoc("Annual report", "document", trip, tooLarge: true);
        s.AddUserDoc("Budget", "spreadsheet");
        s.AddUserDoc("RSVP", "form");
        s.AddUserFile("locked.pdf", Encoding.UTF8.GetBytes("x"), canDownload: false);
        s.AddUserFile("not mine.pdf", Encoding.UTF8.GetBytes("shared"), "someone-elses-folder");
        s.DropDownloadAt = 2;
        var (g, api) = await G.Connect(s, GoogleScopes.Import);
        var old = GoogleDrive.DownloadChunk;
        GoogleDrive.DownloadChunk = 64 * 1024;
        try
        {
            var icloud = TestEnv.TempDir("icloud-drive");
            var state = TestEnv.TempDir("drive-state");
            var bin = new TrashBin(TestEnv.TempDir("bin"));
            var o = new ImportOptions { IncludePhotos = false };
            var e = G.Import(api, state, driveRoot: icloud, options: o, bin: bin);
            var ev = await e.EvaluateAsync(null);
            Assert.True(ev.DriveEnabled && ev.Docs == 3);
            Assert.Equal(new HashSet<string> { "RSVP", "locked.pdf" }, ev.Skipped.Select(x => x.Name).ToHashSet());
            Assert.Contains(ev.Warnings, w => w.Contains("exported as Word, Excel and PowerPoint files"));
            var r = await e.RunAsync(ev, null);
            Assert.True(r.Failed.Count == 0, string.Join("; ", r.Failed));
            Assert.True(r.DriveCopied == 6 && r.DocsExported == 3);
            var root = Path.Combine(icloud, "From Google Drive");
            Assert.Equal(new HashSet<string> { "notes.txt", "notes (2).txt", "Trip", "Trip/plan.pdf", "Meeting notes.docx", "Trip/Annual report.docx", "Budget.xlsx" }, TestEnv.Tree(root));
            Assert.Equal(plan, File.ReadAllBytes(Path.Combine(root, "Trip", "plan.pdf")));   // ranged download survived a dropped connection
            Assert.Equal(1, g.S.ExportLinkUses);                                            // the big Doc went through its export link
            Assert.StartsWith("FAKE-EXPORT", Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(root, "Budget.xlsx"))[..11]));
            // Rerun: nothing. Then a change in Google: only that file, and the old copy goes to the Recycle Bin.
            Assert.True((await G.Import(api, state, driveRoot: icloud, options: o, bin: bin).EvaluateAsync(null)).IsUpToDate);
            g.Update(x => x.ChangeUserFile(notes, Encoding.UTF8.GetBytes("second version")));
            var e3 = G.Import(api, state, driveRoot: icloud, options: o, bin: bin);
            var ev3 = await e3.EvaluateAsync(null);
            var rel = ev3.DrivePending.Single().Rel;
            Assert.Contains(rel, new[] { "notes.txt", "notes (2).txt" });   // which twin gets " (2)" is stable but arbitrary
            var r3 = await e3.RunAsync(ev3, null);
            Assert.True(r3.DriveUpdated == 1 && bin.Items.SequenceEqual([rel]), string.Join("; ", r3.Failed));
            Assert.Equal("second version", File.ReadAllText(Path.Combine(root, rel)));
            Assert.Equal(0, g.S.PermanentDeletes);
        }
        finally { GoogleDrive.DownloadChunk = old; }
    }

    [Fact]
    public async Task DriveNeedsTheReadPermission()
    {
        var (_, api) = await G.Connect(scopes: GoogleScopes.All);
        var e = G.Import(api, TestEnv.TempDir("noperm-state"), driveRoot: TestEnv.TempDir("noperm"), options: new ImportOptions { IncludePhotos = false });
        var ev = await e.EvaluateAsync(null);
        Assert.False(ev.DriveEnabled);
        Assert.Contains(ev.Warnings, w => w.Contains("Allow Reading Google Drive"));
    }

    // MARK: Both directions

    [Fact]
    public async Task TheTwoDirectionsNeverFeedEachOther()
    {
        var (g, api) = await G.Connect(scopes: GoogleScopes.Import);
        var dir = TestEnv.TempDir("loop");
        var state = Path.Combine(dir, "state");
        // iCloud already holds what an earlier Google → iCloud copy brought in.
        var icloud = Path.Combine(dir, "iCloud Drive");
        TestEnv.Write("mine", Path.Combine(icloud, "Docs", "a.txt"));
        TestEnv.Write("came from Google", Path.Combine(icloud, "From Google Drive", "old.txt"));
        var lib = new TestPhotos
        {
            Assets = [TestPhotos.Asset(1), TestPhotos.Asset(2)],
            UserAlbums = [new("album:fromgoogle", "From Google Photos", PhotoAlbumKind.Album)],
            Membership = new() { ["album:fromgoogle"] = ["A0002"] },
        };
        var fwd = G.Engine(api, state, icloud, lib);
        var fev = await fwd.EvaluateAsync(null);
        Assert.Equal(["Docs/a.txt"], fev.DrivePending.Select(d => d.Rel));
        Assert.Equal(["IMG_0001.HEIC"], fev.PhotoPending.Select(p => p.FileName));
        Assert.Contains(fev.Warnings, w => w.Contains("“From Google Drive” (1 file) is left out"));
        var fr = await fwd.RunAsync(fev, null);
        Assert.True(fr.DriveCopied == 1 && fr.PhotosCreated == 1);
        // Google → iCloud: Cirrus's "From iCloud" folder and the photo it uploaded aren't brought back.
        g.Update(s => s.AddUserFile("budget.xlsx", Encoding.UTF8.GetBytes("numbers")));
        var export = Path.Combine(dir, "export", "Takeout", "Google Photos", "Photos from 2023");
        Directory.CreateDirectory(export);
        File.WriteAllBytes(Path.Combine(export, "IMG_0001.HEIC"), TestPhotos.Bytes(lib.Assets[0], PhotoResourceKind.Original));
        File.WriteAllBytes(Path.Combine(export, "IMG_0042.JPG"), DemoArt.Png(200, 100, 0.3, "new"));
        var rec = new RecordingPhotos(Path.Combine(dir, "photos"));
        var back = G.Import(api, state, [Path.Combine(dir, "export")], driveRoot: icloud, photos: rec);
        var bev = await back.EvaluateAsync(null);
        Assert.Equal(["budget.xlsx"], bev.DrivePending.Select(d => d.Rel));
        Assert.Contains(bev.Warnings, w => w.Contains("“From iCloud” in Google Drive is left out"));
        Assert.Equal(["IMG_0042.JPG"], bev.PhotoPending.Select(p => p.FileName));
        Assert.Contains(bev.Warnings, w => w.Contains("came from this iCloud account through Cirrus"));
    }

    // MARK: Google Photos picker

    [Fact]
    public async Task PickedPhotosArriveWithTheirDates()
    {
        var s = new FakeGoogle.State();
        for (int i = 0; i < 3; i++)
            s.PickerLibrary.Add(new($"p{i}", $"PXL_{i}.png", "image/png", DemoArt.Png(300, 200, i / 3.0, $"P{i}"), DateTimeOffset.FromUnixTimeSeconds(1_750_000_000 + i * 3600L), false));
        var (g, api) = await G.Connect(s, GoogleScopes.Import);
        var picker = new GooglePicker(api);
        var session = await picker.CreateAsync();
        g.Pick(GooglePicker.BrowserURL(session), 2);
        var done = await picker.WaitForPickAsync(session);
        Assert.True(done.ItemsSet);
        var items = await picker.ItemsAsync(session.Id);
        Assert.Equal(["PXL_0.png", "PXL_1.png"], items.Select(i => i.FileName));
        var dir = TestEnv.TempDir("picker");
        var rec = new RecordingPhotos(Path.Combine(dir, "icloud"));
        var e = G.Import(api, Path.Combine(dir, "state"), picked: items, photos: rec, options: new ImportOptions { IncludeDrive = false });
        var r = await e.RunAsync(await e.EvaluateAsync(null), null);
        Assert.Equal(2, r.PhotosImported);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_750_003_600).UtcDateTime, rec.ReceivedMtime["PXL_1.png"]);
        Assert.Equal(s.PickerLibrary[1].Data, File.ReadAllBytes(rec.Copy("PXL_1.png")!));
        await picker.DeleteAsync(session.Id);
        Assert.Equal(1, g.S.PickerSessionsDeleted);
    }
}
