namespace Cirrus.Core.Tests;

/// <summary>Regression tests for data-safety issues found in review of the Windows port.</summary>
public class AuditRegressionTests
{
    static SideEntry E(long size, double t, bool dir = false) => new(size, t, dir);

    [Fact]
    public void CaseOnlyRenameIsNotADeletion()
    {
        var st = new SyncState();
        st.Entries["report.docx"] = new SyncState.Entry(10, 100, 100);
        var a = new Dictionary<string, SideEntry> { ["Report.docx"] = E(10, 100) };   // renamed on A (case only)
        var b = new Dictionary<string, SideEntry> { ["report.docx"] = E(10, 100) };
        var two = SyncPlanner.Plan(SyncMode.TwoWay, a, b, st);
        Assert.Equal(0, two.TrashCount);
        Assert.True(two.IsEmpty);
        var mirror = SyncPlanner.Plan(SyncMode.Mirror, a, b, null);
        Assert.Equal(0, mirror.TrashCount);
    }

    [Fact]
    public void DeleteGuardCountsEverythingInsideRemovedFolders()
    {
        var a = new Dictionary<string, SideEntry> { ["keep.txt"] = E(1, 1) };
        var b = new Dictionary<string, SideEntry> { ["keep.txt"] = E(1, 1), ["Photos"] = E(0, 0, true) };
        for (int i = 0; i < 300; i++) b[$"Photos/IMG_{i}.jpg"] = E(1, 1);
        var p = SyncPlanner.Plan(SyncMode.Mirror, a, b, null);
        Assert.Equal(1, p.TrashCount);            // one action…
        Assert.Equal(301, p.RemovedItems);        // …that removes 301 items
        Assert.True(SyncPlanner.GuardTripped(p, SyncMode.Mirror, 50));
    }

    [Fact]
    public void TwoWaySideThatVanishedTripsTheGuard()
    {
        var st = new SyncState();
        for (int i = 0; i < 5; i++) st.Entries[$"f{i}.txt"] = new SyncState.Entry(1, 1, 1);
        var a = Enumerable.Range(0, 5).ToDictionary(i => $"f{i}.txt", _ => E(1, 1));
        var p = SyncPlanner.Plan(SyncMode.TwoWay, a, new Dictionary<string, SideEntry>(), st);
        Assert.True(p.SideVanished);
        Assert.True(SyncPlanner.GuardTripped(p, SyncMode.TwoWay, 50));   // only 5 removals, but one side is suddenly empty
    }

    [Fact]
    public async Task UnreadableFolderStopsTheScan()
    {
        if (OperatingSystem.IsWindows()) return;   // chmod-based; Windows ACLs are covered by the same code path
        var root = TestEnv.TempDir("unreadable");
        TestEnv.Write("x", Path.Combine(root, "locked", "a.txt"));
        File.SetUnixFileMode(Path.Combine(root, "locked"), UnixFileMode.None);
        try
        {
            var e = await Assert.ThrowsAsync<SyncException>(() => new LocalSide(root, []).ScanAsync(null, default));
            Assert.Contains("Couldn’t read", e.Message);
        }
        finally { File.SetUnixFileMode(Path.Combine(root, "locked"), UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); }
    }

    [Fact]
    public async Task IncompleteDriveListingStopsTheWalk()
    {
        var drive = new PartialDrive();
        var e = await Assert.ThrowsAsync<ICloudException>(() => drive.WalkAsync(drive.RootID));
        Assert.Contains("didn’t list", e.Message);
    }

    [Fact]
    public async Task StoreLeavesFilesEditedSinceTheScanAlone()
    {
        var dst = TestEnv.TempDir("edited");
        TestEnv.Write("original", Path.Combine(dst, "doc.txt"), 1_000);
        var side = new LocalSide(dst, []);
        await side.ScanAsync(null, default);
        TestEnv.Write("edited after scan!", Path.Combine(dst, "doc.txt"), 2_000);   // the user edits it mid-run
        var src = Path.Combine(TestEnv.TempDir("newer"), "doc.txt");
        File.WriteAllText(src, "incoming");
        await Assert.ThrowsAsync<SyncException>(() => side.StoreAsync("doc.txt", src, DateTimeOffset.Now, null, default));
        Assert.Equal("edited after scan!", File.ReadAllText(Path.Combine(dst, "doc.txt")));
    }

    [Fact]
    public async Task ReadOnlyProtectsFoldersThatContainICloud()
    {
        var pictures = TestEnv.TempDir("Pictures");
        var icloud = Path.Combine(pictures, "iCloud Photos");
        TestEnv.Write("photo", Path.Combine(icloud, "IMG_1.jpg"));
        TestEnv.Write("other", Path.Combine(pictures, "holiday.jpg"));
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_PHOTOS", icloud);
        SafetyPolicy.ReadOnlyICloud = true;
        try
        {
            Assert.True(SafetyPolicy.TouchesICloud(pictures));
            Assert.False(SafetyPolicy.TouchesICloud(Path.Combine(pictures, "holiday.jpg")));
            Assert.Throws<ReadOnlyException>(() => SafetyPolicy.CheckLocalWrite(pictures));
            // A mirror into Pictures may not remove the iCloud Photos folder, but other items are still handled.
            var side = new LocalSide(pictures, []);
            await side.ScanAsync(null, default);
            await Assert.ThrowsAsync<ReadOnlyException>(() => side.TrashAsync("iCloud Photos", default));
            Assert.True(Directory.Exists(icloud));
            await side.TrashAsync("holiday.jpg", default);
            Assert.False(File.Exists(Path.Combine(pictures, "holiday.jpg")));
        }
        finally
        {
            SafetyPolicy.ReadOnlyICloud = false;
            Environment.SetEnvironmentVariable("CIRRUS_NATIVE_PHOTOS", null);
        }
    }

    [Fact]
    public async Task ExportGivesLivePhotoVideosTheirOwnNames()
    {
        // Two different photos called IMG_0001 (HEIC and JPG) taken the same month, both Live: their .MOV files must not collide.
        var when = new DateTimeOffset(2025, 6, 10, 12, 0, 0, TimeSpan.Zero);
        var backend = new FakePhotos(
            Live("A1", "IMG_0001.HEIC", when), Live("B2", "IMG_0001.JPG", when.AddHours(1)));
        var dest = TestEnv.TempDir("live-clash");
        var ev = await new PhotoExporter(backend, new PhotoLibraryRef("lib", "Lib", false), null, dest, new SyncOptions { WriteManifest = false })
            .EvaluateAsync(null);
        var movs = ev.Files.Where(f => f.Kind == PhotoResourceKind.LiveVideo).Select(f => f.Rel.ToLowerInvariant()).ToList();
        Assert.Equal(2, movs.Count);
        Assert.Equal(2, movs.Distinct().Count());
        Assert.Equal(ev.Files.Count, ev.Files.Select(f => f.Rel.ToLowerInvariant()).Distinct().Count());
    }

    static PhotoAsset Live(string id, string name, DateTimeOffset created) => new()
    {
        Id = id, MasterID = id, Library = "lib", Filename = name, Size = 100, Created = created, IsLive = true,
        Resources =
        [
            new PhotoResource { Kind = PhotoResourceKind.Original, Filename = name, Size = 100 },
            new PhotoResource { Kind = PhotoResourceKind.LiveVideo, Filename = Path.GetFileNameWithoutExtension(name) + ".MOV", Size = 50 },
        ],
    };

    /// <summary>A Drive whose listing silently leaves out a folder that was asked for.</summary>
    sealed class PartialDrive : IDriveBackend
    {
        public string RootID => "FOLDER::z::root";
        public Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default) => Task.FromResult(new List<DriveNode>());
        public Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> ids, CancellationToken ct = default)
        {
            var o = new Dictionary<string, List<DriveNode>>();
            if (ids.Contains(RootID)) o[RootID] = [new DriveNode { Id = "FOLDER::z::sub", Name = "Sub", Type = "FOLDER" }];
            return Task.FromResult(o);   // "Sub" is never answered
        }
        public Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default) => throw new NotSupportedException();
        public Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default) => throw new NotSupportedException();
        public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default) => throw new NotSupportedException();
        public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => throw new NotSupportedException();
        public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => throw new NotSupportedException();
    }

    sealed class FakePhotos(params PhotoAsset[] assets) : IPhotosBackend
    {
        public PhotoCapabilities Capabilities => PhotoCapabilities.None;
        public string CacheKey => "fake";
        public Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default) => Task.FromResult(new List<PhotoLibraryRef> { new("lib", "Lib", false) });
        public Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default) =>
            Task.FromResult(new List<PhotoAlbum> { new("smart:All Photos", "All Photos", PhotoAlbumKind.Smart) });
        public Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default) =>
            Task.FromResult(assets.ToList());
        public Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);
        public Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> a, bool value, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> a, bool value, CancellationToken ct = default) => throw new NotSupportedException();
        public Task DeleteAsync(IReadOnlyList<PhotoAsset> a, CancellationToken ct = default) => throw new NotSupportedException();
        public Task RestoreAsync(IReadOnlyList<PhotoAsset> a, CancellationToken ct = default) => throw new NotSupportedException();
        public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) => throw new NotSupportedException();
        public Task AddAsync(IReadOnlyList<PhotoAsset> a, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default) => throw new NotSupportedException();
        public Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default) => throw new NotSupportedException();
        public string? SyncToken(PhotoLibraryRef library) => null;
        public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default) => Task.FromResult((true, (string?)null));
    }
}

/// <summary>Backup and Drive-listing safety rules shared with the Swift engine.</summary>
public class BackupMirrorSafetyTests
{
    [Fact]
    public async Task BackupMirrorNeverRemovesMostOfABackupBecauseOfOneListing()
    {
        // Keep-deleted off (mirror). The backup holds 30 items that iCloud's listing doesn't show this time.
        var dest = TestEnv.TempDir("backup-mirror");
        var driveDir = Path.Combine(dest, "Cirrus Backup", "demo@example.com", "iCloud Drive");
        for (int i = 0; i < 30; i++) TestEnv.Write("kept", Path.Combine(driveDir, "Old", $"file{i}.txt"));
        var engine = new BackupEngine(new BackupEngine.Sources("demo@example.com", DemoDrive.Shared, null, null, null), dest,
            new SyncOptions { KeepDeleted = false, IncludePhotos = false });
        var ev = await engine.EvaluateAsync(null);
        Assert.Contains(ev.Warnings, w => w.Contains("would have removed") && w.Contains("They were kept"));
        Assert.All(ev.DrivePlans, p => Assert.Equal(0, p.Plan.TrashCount));
        var rep = await engine.RunAsync(ev, null);
        Assert.Equal(0, rep.Trashed);
        Assert.Equal(30, Directory.GetFiles(Path.Combine(driveDir, "Old")).Length);
    }

    sealed class DriveReply(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json") });
    }

    static WebDrive Drive(string reply)
    {
        var state = new SessionState("x@example.com")
        {
            AccountInfoData = System.Text.Encoding.UTF8.GetBytes("{\"webservices\":{\"drivews\":{\"url\":\"https://p01-drivews.icloud.com\"}}}"),
            Cookies = [new StoredCookie { Name = "X-APPLE-WEBAUTH-USER", Value = "x" }],
        };
        return new WebDrive(new ICloudSession(state, new DriveReply(reply)));
    }

    [Theory]
    [InlineData("[{\"drivewsid\":\"FOLDER::com.apple.CloudDocs::root\",\"errorCode\":\"ITEM_NOT_FOUND\"}]")]
    [InlineData("[{\"drivewsid\":\"FOLDER::com.apple.CloudDocs::root\",\"numberOfItems\":12}]")]
    [InlineData("[{\"drivewsid\":\"FOLDER::com.apple.CloudDocs::root\",\"status\":\"UNKNOWN_ERROR\",\"items\":[]}]")]
    public async Task FolderErrorsInADriveListingStopInsteadOfLookingEmpty(string reply)
    {
        var drive = Drive(reply);
        await Assert.ThrowsAsync<ICloudException>(() => drive.WalkAsync(drive.RootID));
    }

    [Fact]
    public async Task AnEmptyFolderIsStillEmpty()
    {
        var drive = Drive("[{\"drivewsid\":\"FOLDER::com.apple.CloudDocs::root\",\"status\":\"OK\",\"items\":[],\"numberOfItems\":0}]");
        Assert.Empty(await drive.WalkAsync(drive.RootID));
    }
}
