namespace Cirrus.Core.Tests;

/// <summary>Tests that use the shared demo backends or the global safety switch.</summary>
public class DemoBackendTests
{
    static readonly PhotoAlbum AllPhotos = new("smart:All Photos", "All Photos", PhotoAlbumKind.Smart);

    [Fact]
    public async Task DriveSideMirrorThroughDemoBackend()
    {
        var drive = DemoDrive.Shared;
        var src = TestEnv.TempDir("src");
        TestEnv.Write("hello", Path.Combine(src, "Sub", "hello.txt"), 1_500_000);
        TestEnv.Write("x", Path.Combine(src, "top.txt"), 1_500_000);
        var folder = await drive.CreateFolderAsync("SyncTest-" + Guid.NewGuid().ToString("N")[..5], drive.RootID);
        var a = new LocalSide(src, []);
        var b = new DriveSide(drive, folder.Id, "iCloud Drive", []);
        var runner = new SyncRunner(a, b);
        var (ma, mb) = await runner.ScanAsync(null);
        var (rep, _) = await runner.RunAsync(SyncPlanner.Plan(SyncMode.Mirror, ma, mb, null), ma, mb, null);
        Assert.True(rep.Copied == 2 && rep.Failed.Count == 0, string.Join(";", rep.Failed));
        var listed = await drive.WalkAsync(folder.Id);
        Assert.Equal(new HashSet<string> { "Sub", "Sub/hello.txt", "top.txt" }, listed.Select(l => l.Path).ToHashSet());
        var hello = listed.First(l => l.Path == "Sub/hello.txt").Node;
        Assert.True(Math.Abs(hello.Modified!.Value.ToUnixTimeSeconds() - 1_500_000) < 2);
        // Second run: nothing to do.
        (ma, mb) = await runner.ScanAsync(null);
        Assert.True(SyncPlanner.Plan(SyncMode.Mirror, ma, mb, null).IsEmpty);
        // Removing locally moves it to iCloud's Recently Deleted (not gone).
        File.Delete(Path.Combine(src, "top.txt"));
        (ma, mb) = await runner.ScanAsync(null);
        (rep, _) = await runner.RunAsync(SyncPlanner.Plan(SyncMode.Mirror, ma, mb, null), ma, mb, null);
        Assert.Equal(1, rep.Trashed);
        Assert.Contains(await drive.ListTrashAsync(), n => n.Name == "top.txt");
        // Changing a file re-uploads it with SafeReplace: the old version goes to Recently Deleted.
        TestEnv.Write("hello again", Path.Combine(src, "Sub", "hello.txt"), 1_600_000);
        (ma, mb) = await runner.ScanAsync(null);
        (rep, _) = await runner.RunAsync(SyncPlanner.Plan(SyncMode.Mirror, ma, mb, null), ma, mb, null);
        Assert.Equal(1, rep.Copied);
        var after = await drive.WalkAsync(folder.Id);
        Assert.Equal(11, after.First(l => l.Path == "Sub/hello.txt").Node.Size);
        Assert.DoesNotContain(after, l => l.Node.Name.StartsWith(".cirrus-upload-"));
        await drive.TrashAsync([folder]);
    }

    [Fact]
    public async Task PhotoExportIsIncrementalAndDated()
    {
        var photos = DemoPhotos.Shared;
        var lib = (await photos.LibrariesAsync())[0];
        var dest = TestEnv.TempDir("export");
        var opts = new SyncOptions { AlbumFolders = true };
        var ex = new PhotoExporter(photos, lib, null, dest, opts);
        var ev = await ex.EvaluateAsync(null);
        Assert.True(ev.AssetCount > 10);
        Assert.Equal(ev.Files.Count, ev.Pending.Count);
        var rep = await ex.RunAsync(ev);
        Assert.Empty(rep.Failed);
        var first = ev.Files.First(f => f.Kind == PhotoResourceKind.Original);
        var path = Paths.Combine(dest, first.Rel);
        Assert.True(Math.Abs((File.GetLastWriteTimeUtc(path) - first.Asset.Created!.Value.UtcDateTime).TotalSeconds) < 2);
        // YYYY/MM layout from the capture date.
        var local = first.Asset.Created!.Value.ToLocalTime();
        Assert.StartsWith($"{local.Year:0000}/{local.Month:00}/", first.Rel);
        Assert.Contains(ev.Files, f => f.Kind == PhotoResourceKind.LiveVideo && f.Rel.EndsWith(".MOV"));
        Assert.True(File.Exists(Path.Combine(dest, "Photos manifest.csv")));
        Assert.StartsWith("path,filename,taken,favorite,hidden", File.ReadAllLines(Path.Combine(dest, "Photos manifest.csv"))[0]);
        Assert.True(File.Exists(Path.Combine(dest, "Albums.json")));
        Assert.True(Directory.Exists(Path.Combine(dest, "Albums", "Travel")));
        Assert.NotEmpty(Directory.GetFileSystemEntries(Path.Combine(dest, "Albums", "Travel")));
        // A second evaluation finds nothing to download and keeps the same paths.
        var ev2 = await new PhotoExporter(photos, lib, null, dest, opts).EvaluateAsync(null);
        Assert.Empty(ev2.Pending);
        Assert.Equal(ev.Files.Select(f => f.Rel).ToHashSet(), ev2.Files.Select(f => f.Rel).ToHashSet());
    }

    [Fact]
    public async Task ReadOnlyModeBlocksEveryICloudWrite()
    {
        var drive = DemoDrive.Shared; var photos = DemoPhotos.Shared;
        var before = (await drive.ListAsync(drive.RootID)).Count;
        var lib = (await photos.LibrariesAsync())[0];
        var asset = (await photos.AssetsAsync(AllPhotos, lib, null))[0];
        var any = (await drive.ListAsync(drive.RootID))[0];
        var f = Path.Combine(TestEnv.TempDir("ro"), "x.txt");
        File.WriteAllText(f, "x");
        var native = TestEnv.TempDir("native-icloud");
        SafetyPolicy.ReadOnlyICloud = true;
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", native);
        try
        {
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.UploadAsync(f, "nope.txt", drive.RootID, null, null));
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.CreateFolderAsync("nope", drive.RootID));
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.TrashAsync([any]));
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.RenameAsync(any, "renamed"));
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.MoveAsync([any], drive.RootID));
            await Assert.ThrowsAsync<ReadOnlyException>(() => drive.SafeReplaceAsync(f, any.Name, drive.RootID, any, null, null));
            await Assert.ThrowsAsync<ReadOnlyException>(() => photos.DeleteAsync([asset]));
            await Assert.ThrowsAsync<ReadOnlyException>(() => photos.SetFavoriteAsync([asset], true));
            await Assert.ThrowsAsync<ReadOnlyException>(() => photos.SetHiddenAsync([asset], true));
            await Assert.ThrowsAsync<ReadOnlyException>(() => photos.ImportFilesAsync([f], null, lib, null));
            await Assert.ThrowsAsync<ReadOnlyException>(() => photos.CreateAlbumAsync("nope", lib));
            // The iCloud for Windows folder is iCloud too.
            var nativeSide = new LocalSide(native, []);
            await Assert.ThrowsAsync<ReadOnlyException>(() => nativeSide.StoreAsync("x.txt", f, DateTimeOffset.Now, null, default));
            await Assert.ThrowsAsync<ReadOnlyException>(() => nativeSide.MakeDirAsync("dir", default));
            // Reads, exports and backups still work.
            Assert.Equal(before, (await drive.ListAsync(drive.RootID)).Count);
            var output = TestEnv.TempDir("ro-export");
            await photos.ExportAsync(asset, PhotoResourceKind.Original, Path.Combine(output, "a.png"), null);
            Assert.True(File.Exists(Path.Combine(output, "a.png")));
            var bk = new BackupEngine(new BackupEngine.Sources("demo@example.com", drive, null, photos, null), TestEnv.TempDir("ro-backup"),
                new SyncOptions { IncludePhotos = false });
            var ev = await bk.EvaluateAsync(null);
            var r = await bk.RunAsync(ev, null);
            Assert.Empty(r.Failed);
        }
        finally
        {
            SafetyPolicy.ReadOnlyICloud = false;
            Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", null);
        }
    }

    [Fact]
    public async Task SafeReplaceUploadsBeforeRetiringOldCopy()
    {
        var drive = DemoDrive.Shared;
        var folder = await drive.CreateFolderAsync("Replace-" + Guid.NewGuid().ToString("N")[..5], drive.RootID);
        var dir = TestEnv.TempDir("replace");
        string v1 = Path.Combine(dir, "v1.txt"), v2 = Path.Combine(dir, "v2.txt");
        File.WriteAllText(v1, "old"); File.WriteAllText(v2, "new!");
        var old = await drive.UploadAsync(v1, "doc.txt", folder.Id, null, null);
        var calls = new List<string>();
        var spy = new SpyDrive(drive, calls);
        var updated = await spy.SafeReplaceAsync(v2, "doc.txt", folder.Id, old, null, null);
        Assert.Equal("doc.txt", updated.Name);
        Assert.Equal(4, updated.Size);
        Assert.Equal(["upload", "trash", "rename"], calls);   // the old copy is retired only after the new one is safely up
        Assert.Equal(["doc.txt"], (await drive.ListAsync(folder.Id)).Select(n => n.Name).ToList());
        Assert.Contains(await drive.ListTrashAsync(), n => n.Name == "doc.txt" && n.Size == 3);
        await drive.TrashAsync([folder]);
    }

    [Fact]
    public async Task DeleteImmediatelyOnlyWorksInRecentlyDeleted()
    {
        var drive = DemoDrive.Shared;
        var dir = TestEnv.TempDir("del");
        var f = Path.Combine(dir, "gone.txt");
        File.WriteAllText(f, "bye");
        var node = await drive.UploadAsync(f, "gone-" + Guid.NewGuid().ToString("N")[..5] + ".txt", drive.RootID, null, null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => drive.DeleteForeverAsync([node]));
        Assert.Contains(await drive.ListAsync(drive.RootID), n => n.Name == node.Name);
        await drive.TrashAsync([node]);
        var inTrash = (await drive.ListTrashAsync()).First(n => n.Name == node.Name);
        Assert.True(inTrash.IsInTrash);
        await drive.DeleteForeverAsync([inTrash]);
        Assert.DoesNotContain(await drive.ListTrashAsync(), n => n.Name == node.Name);
    }

    [Fact]
    public async Task PhotoDeleteGoesToRecentlyDeletedAndRestores()
    {
        var photos = DemoPhotos.Shared;
        var lib = (await photos.LibrariesAsync())[0];
        var asset = (await photos.AssetsAsync(AllPhotos, lib, null)).Last();
        await photos.DeleteAsync([asset]);
        var bin = new PhotoAlbum("smart:Recently Deleted", "Recently Deleted", PhotoAlbumKind.Smart);
        Assert.Contains(await photos.AssetsAsync(bin, lib, null), a => a.Id == asset.Id);
        await photos.RestoreAsync([asset]);
        Assert.Contains(await photos.AssetsAsync(AllPhotos, lib, null), a => a.Id == asset.Id);
    }

    [Fact]
    public async Task BackupCopiesDriveAndPhotosAndRefusesICloudDestination()
    {
        var dest = TestEnv.TempDir("backup");
        var sources = new BackupEngine.Sources("demo@example.com", DemoDrive.Shared, null, DemoPhotos.Shared,
            () => Task.FromResult<StorageUsage?>(new StorageUsage(5_000_000_000, 2_000_000_000,
                [new("photos", "Photos", 1_000_000_000, null), new("backup", "Backups", 900_000_000, null)])));
        var engine = new BackupEngine(sources, dest, new SyncOptions());
        var ev = await engine.EvaluateAsync(null);
        Assert.True(ev.Fits);
        Assert.True(ev.DriveFiles > 5);
        Assert.True(ev.PhotoCount > 10);
        Assert.Contains(ev.Warnings, w => w.Contains("can’t be downloaded through iCloud.com"));
        var rep = await engine.RunAsync(ev, null);
        Assert.Empty(rep.Failed);
        var root = Path.Combine(dest, "Cirrus Backup", "demo@example.com");
        Assert.True(File.Exists(Path.Combine(root, "Backup Info.txt")));
        Assert.True(File.Exists(Path.Combine(root, "iCloud Drive", "Recipe.txt")));
        Assert.True(File.Exists(Path.Combine(root, "Photos", "Personal Library", "Photos manifest.csv")));
        // Incremental: a second evaluation has nothing left to copy.
        var ev2 = await new BackupEngine(sources, dest, new SyncOptions()).EvaluateAsync(null);
        Assert.Equal(0, ev2.PendingBytes);

        // A destination inside an iCloud folder is refused.
        var native = TestEnv.TempDir("icloud-for-windows");
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", native);
        try
        {
            var bad = new BackupEngine(sources, Path.Combine(native, "Backups"), new SyncOptions { IncludePhotos = false });
            var bev = await bad.EvaluateAsync(null);
            Assert.True(bev.DestinationIsICloud);
            Assert.Contains(bev.Warnings, w => w.Contains("inside an iCloud folder"));
            await Assert.ThrowsAsync<SyncException>(() => bad.RunAsync(bev, null));
            Assert.False(Directory.Exists(Path.Combine(native, "Backups", "Cirrus Backup")));
        }
        finally { Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", null); }
    }

    [Fact]
    public async Task BackupRefusesToStartWithoutEnoughSpace()
    {
        var engine = new BackupEngine(new BackupEngine.Sources("demo@example.com", DemoDrive.Shared, null, null, null), TestEnv.TempDir("nospace"), new SyncOptions());
        var ev = await engine.EvaluateAsync(null);
        ev.Free = 1000;   // pretend the drive is nearly full
        Assert.False(ev.Fits);
        var e = await Assert.ThrowsAsync<SyncException>(() => engine.RunAsync(ev, null));
        Assert.Equal(SyncErrorKind.NotEnoughSpace, e.Kind);
    }

    /// <summary>Records the order of Drive calls made by SafeReplace.</summary>
    sealed class SpyDrive(IDriveBackend inner, List<string> calls) : IDriveBackend
    {
        public string RootID => inner.RootID;
        public Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default) => inner.ListAsync(folderID, ct);
        public Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> ids, CancellationToken ct = default) => inner.ListManyAsync(ids, ct);
        public Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default) => inner.DownloadAsync(node, destination, progress, ct);
        public Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default)
        { calls.Add("upload"); Assert.StartsWith(".cirrus-upload-", name); return inner.UploadAsync(file, name, folderID, modified, progress, ct); }
        public Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default) => inner.CreateFolderAsync(name, folderID, ct);
        public Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default) { calls.Add("rename"); return inner.RenameAsync(node, name, ct); }
        public Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default) => inner.MoveAsync(nodes, folderID, ct);
        public Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) { calls.Add("trash"); return inner.TrashAsync(nodes, ct); }
        public Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default) => inner.ListTrashAsync(ct);
        public Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => inner.RestoreAsync(nodes, ct);
        public Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default) => inner.DeleteForeverAsync(nodes, ct);
    }
}
