using System.Text;
using Cirrus.Fakes;

namespace Cirrus.Core.Tests;

/// <summary>
/// Tests that change process-wide cloud state (CloudBackends.Transport, CloudStore.Store, AccountManager.Shared) run one at a
/// time, so one test's fake server never answers another's requests.
/// </summary>
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class CloudGlobals
{
    public const string Name = "Cloud globals";
}

/// <summary>
/// Every cloud through the same steps the app takes (browse, upload, download, rename, move, trash, restore, delete for good),
/// on the demo content of its fake server; plus copying between clouds with the sync engine and the account manager's
/// handling of cloud accounts.
/// </summary>
[Collection(CloudGlobals.Name)]
public class CloudContractTests
{
    static FakeCloudRouter NewRouter() => new(FakeGraphServer.Demo(), FakeGoogle.DriveDemo(null, 0), FakeDropboxServer.Demo(),
        FakeWebDAVServer.Demo(), FakeS3Server.Demo(), FakeImmichServer.Demo());

    public static IEnumerable<object[]> DriveProviders =>
        new[] { CloudProvider.OneDrive, CloudProvider.GoogleDrive, CloudProvider.Dropbox, CloudProvider.Nextcloud, CloudProvider.WebDAV, CloudProvider.S3 }
            .Select(p => new object[] { p });

    static async Task WithTransport(FakeCloudRouter router, Func<Task> body)
    {
        var saved = CloudBackends.Transport;
        CloudBackends.Transport = router;
        try { await body(); } finally { CloudBackends.Transport = saved; }
    }

    static ICloudDriveBackend Drive(FakeCloudRouter router, CloudProvider p)
    {
        var c = router.DemoAccounts().Single(x => x.Record.Provider == p);
        return CloudBackends.Make(c.Record, c.Secret);
    }

    static string TempDir()
    {
        var d = Path.Combine(Path.GetTempPath(), "cirrus-contract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        return d;
    }

    [Theory, MemberData(nameof(DriveProviders))]
    public async Task EveryDriveFollowsTheContract(CloudProvider p)
    {
        var router = NewRouter();
        await WithTransport(router, async () =>
        {
            var drive = Drive(router, p);
            Assert.Equal(p, drive.Provider);

            var root = await drive.ListAsync(drive.RootID);
            Assert.NotEmpty(root);
            Assert.All(root, n => Assert.Equal(drive.RootID, n.ParentID));
            Assert.All(root, n => Assert.True(n.Type is "FILE" or "FOLDER", n.Type));

            var folder = await drive.CreateFolderAsync("Contract " + p, drive.RootID);
            Assert.True(folder.IsFolder);
            Assert.Contains(await drive.ListAsync(drive.RootID), n => n.Id == folder.Id && n.IsFolder);

            var tmp = TempDir();
            try
            {
                var bytes = Encoding.UTF8.GetBytes("Hello from the contract test — ünïcødé ✓ " + p);
                var src = Path.Combine(tmp, "notes.txt");
                File.WriteAllBytes(src, bytes);
                long reported = 0;
                var up = await drive.UploadAsync(src, "Notes é.txt", folder.Id, DateTimeOffset.UtcNow.AddDays(-2), (d, _) => reported = Math.Max(reported, d));
                Assert.Equal("Notes é.txt", up.Name);
                Assert.Equal(bytes.Length, up.Size);
                Assert.Equal(bytes.Length, reported);

                var listed = Assert.Single(await drive.ListAsync(folder.Id));
                Assert.Equal(up.Id, listed.Id);
                Assert.Equal(folder.Id, listed.ParentID);
                Assert.Equal(bytes.Length, listed.Size);

                var down = Path.Combine(tmp, "down.txt");
                long got = 0;
                await drive.DownloadAsync(listed, down, (d, _) => got = Math.Max(got, d));
                Assert.Equal(bytes, File.ReadAllBytes(down));

                var renamed = await drive.RenameAsync(listed, "Renamed notes.txt");
                Assert.Equal("Renamed notes.txt", renamed.Name);
                Assert.Equal("Renamed notes.txt", Assert.Single(await drive.ListAsync(folder.Id)).Name);

                await drive.MoveAsync([renamed], drive.RootID);
                Assert.Empty(await drive.ListAsync(folder.Id));
                var moved = (await drive.ListAsync(drive.RootID)).Single(n => n.Name == "Renamed notes.txt");

                // Delete Immediately only ever applies to items in the trash.
                await Assert.ThrowsAsync<InvalidOperationException>(() => drive.DeleteForeverAsync([moved]));

                await drive.TrashAsync([moved]);
                Assert.DoesNotContain(await drive.ListAsync(drive.RootID), n => n.Name == "Renamed notes.txt");
                if (drive.CanListTrash)
                {
                    var t = (await drive.ListTrashAsync()).Single(n => n.Name == "Renamed notes.txt");
                    Assert.Equal(CloudConventions.TrashParent, t.ParentID);
                    Assert.True(t.IsInTrash);
                    await drive.RestoreAsync([t]);
                    var back = (await drive.ListAsync(drive.RootID)).Single(n => n.Name == "Renamed notes.txt");
                    Assert.Equal(bytes.Length, back.Size);

                    await drive.TrashAsync([back]);
                    var t2 = (await drive.ListTrashAsync()).Single(n => n.Name == "Renamed notes.txt");
                    await drive.DeleteForeverAsync([t2]);
                    Assert.DoesNotContain(await drive.ListTrashAsync(), n => n.Name == "Renamed notes.txt");
                }
                else
                {
                    Assert.Empty(await drive.ListTrashAsync());
                    await Assert.ThrowsAsync<CloudException>(() => drive.RestoreAsync([moved]));
                }

                await drive.TrashAsync([folder]);
                Assert.DoesNotContain(await drive.ListAsync(drive.RootID), n => n.Id == folder.Id);
                _ = await drive.QuotaAsync();   // optional, but never an error on the demo account
            }
            finally { Directory.Delete(tmp, true); }
        });
    }

    [Theory]
    [InlineData(CloudProvider.OneDrive, CloudProvider.S3)]
    [InlineData(CloudProvider.Dropbox, CloudProvider.Nextcloud)]
    [InlineData(CloudProvider.GoogleDrive, CloudProvider.WebDAV)]
    [InlineData(CloudProvider.S3, CloudProvider.Dropbox)]
    public async Task SyncCopiesAFolderTreeBetweenClouds(CloudProvider from, CloudProvider to)
    {
        var router = NewRouter();
        await WithTransport(router, async () =>
        {
            var a = Drive(router, from);
            var b = Drive(router, to);
            var tmp = TempDir();
            try
            {
                var srcFolder = await a.CreateFolderAsync("Trip " + from, a.RootID);
                var sub = await a.CreateFolderAsync("Day 1", srcFolder.Id);
                var files = new Dictionary<string, byte[]>
                {
                    ["plan.txt"] = Encoding.UTF8.GetBytes("Plan for " + from),
                    ["Day 1/photo.bin"] = Enumerable.Range(0, 70_000).Select(i => (byte)(i * 7)).ToArray(),
                };
                foreach (var (rel, data) in files)
                {
                    var f = Path.Combine(tmp, Path.GetFileName(rel));
                    File.WriteAllBytes(f, data);
                    await a.UploadAsync(f, Path.GetFileName(rel), rel.Contains('/') ? sub.Id : srcFolder.Id, null, null);
                }
                var dstFolder = await b.CreateFolderAsync("Copy of trip", b.RootID);

                var runner = new SyncRunner(new DriveSide(a, srcFolder.Id, srcFolder.Name, []), new DriveSide(b, dstFolder.Id, dstFolder.Name, []));
                var (sa, sb) = await runner.ScanAsync(null);
                var plan = SyncPlanner.Plan(SyncMode.Copy, sa, sb, null);
                var (report, _) = await runner.RunAsync(plan, sa, sb, null);
                Assert.Empty(report.Failed);

                var copied = await b.WalkAsync(dstFolder.Id);
                foreach (var (rel, data) in files)
                {
                    var node = copied.Single(x => x.Path == rel).Node;
                    Assert.Equal(data.Length, node.Size);
                    var check = Path.Combine(tmp, "check-" + Guid.NewGuid().ToString("N"));
                    await b.DownloadAsync(node, check, null);
                    Assert.Equal(data, File.ReadAllBytes(check));
                }
                Assert.Contains(copied, x => x.Path == "Day 1" && x.Node.IsFolder);
            }
            finally { Directory.Delete(tmp, true); }
        });
    }

    [Fact]
    public async Task DemoModeShowsEveryCloudWithoutSavingAnything()
    {
        var router = NewRouter();
        var savedStore = CloudStore.Store;
        await WithTransport(router, () =>
        {
            var store = new MemorySecretStore();
            var am = new AccountManager(store, null) { DemoMode = true, DemoClouds = router.DemoAccounts };
            am.Load();
            var clouds = am.CloudAccounts;
            Assert.Equal(7, clouds.Count);
            Assert.All(clouds, c => Assert.Equal(AccountStatus.Ready, c.Status));
            Assert.All(clouds.Where(c => !c.Provider!.Value.IsPhotoLibrary()), c => Assert.IsAssignableFrom<ICloudDriveBackend>(c.Drive));
            var immich = clouds.Single(c => c.Provider == CloudProvider.Immich);
            Assert.NotNull(immich.Photos);
            Assert.Null(immich.Drive);
            Assert.Equal(ImmichPhotos.LibraryID, immich.PrimaryLibraryID);
            Assert.Equal("Trash", immich.DeletedTitle);
            Assert.False(immich.IsICloud);
            // Demo accounts never reach the real secret store.
            Assert.Null(store.Get(CloudStore.RecordsService, "list"));
            Assert.All(clouds, c => Assert.Null(store.Get(CloudStore.SecretService, c.Id)));
            // A second load keeps the same live accounts (transfers may be using them).
            var before = clouds.ToDictionary(c => c.Id);
            am.Load();
            Assert.All(am.CloudAccounts, c => Assert.Same(before[c.Id], c));
            return Task.CompletedTask;
        });
        CloudStore.Store = savedStore;
    }

    [Fact]
    public async Task AccountsAreSavedApartFromTheirSecretsAndForgottenOnRemove()
    {
        var router = NewRouter();
        var savedStore = CloudStore.Store;
        await WithTransport(router, async () =>
        {
            var store = new MemorySecretStore();
            var am = new AccountManager(store, null) { DemoMode = false };
            am.Load();
            var conn = router.DemoAccounts().Single(c => c.Record.Provider == CloudProvider.OneDrive);
            var a = am.AddCloud(conn);
            Assert.Equal(AccountStatus.Ready, a.Status);
            Assert.Equal("OneDrive", a.DriveTitle);
            Assert.Equal("Recycle Bin", a.DeletedTitle);
            Assert.False(a.CanListTrash);

            // Records hold no secrets; the secret sits under its own entry.
            var records = Encoding.UTF8.GetString(store.Get(CloudStore.RecordsService, "list")!);
            Assert.Contains(conn.Record.Id, records);
            Assert.DoesNotContain(conn.Secret.RefreshToken!, records);
            Assert.Equal(conn.Secret.RefreshToken, CloudStore.Secret(conn.Record.Id)!.RefreshToken);

            // Signing in to the same login again updates it instead of adding a twin.
            var twin = conn.Record.Copy();
            twin.Id = CloudAccountRecord.NewID(CloudProvider.OneDrive);
            Assert.Equal(conn.Record.Id, am.ExistingCloud(twin)?.Id);

            // A rotated refresh token is kept.
            var rot = Assert.IsAssignableFrom<ICloudTokenRotating>(a.Drive);
            rot.OnNewRefreshToken!("rotated-token");
            Assert.Equal("rotated-token", CloudStore.Secret(conn.Record.Id)!.RefreshToken);

            // A fresh start finds it again; a missing secret means signing in again, not an error.
            var am2 = new AccountManager(store, null) { DemoMode = false };
            am2.Load();
            Assert.Single(am2.CloudAccounts);
            store.Delete(CloudStore.SecretService, conn.Record.Id);
            var am3 = new AccountManager(store, null) { DemoMode = false };
            am3.Load();
            Assert.Equal(AccountStatus.NeedsSignIn, Assert.Single(am3.CloudAccounts).Status);

            am.RemoveCloud(a);
            Assert.Empty(am.CloudAccounts);
            Assert.Empty(CloudStore.Records());
            Assert.Null(CloudStore.Secret(conn.Record.Id));
            await Task.CompletedTask;
        });
        CloudStore.Store = savedStore;
    }

    [Fact]
    public void ProvidersKeepTheMacRawValues()
    {
        Assert.Equal(["nextcloud", "webdav", "onedrive", "googleDrive", "dropbox", "s3", "immich"], Enum.GetValues<CloudProvider>().Select(p => p.Raw()));
        foreach (var p in Enum.GetValues<CloudProvider>()) Assert.Equal(p, CloudProviders.FromRaw(p.Raw()));
        var r = new CloudAccountRecord(CloudProvider.GoogleDrive, "alex@example.com");
        Assert.StartsWith("cloud:googleDrive:", r.Id);
        var json = System.Text.Json.JsonSerializer.Serialize(r);
        Assert.Contains("\"provider\":\"googleDrive\"", json);
        Assert.Equal(CloudProvider.GoogleDrive, System.Text.Json.JsonSerializer.Deserialize<CloudAccountRecord>(json)!.Provider);
    }
}
