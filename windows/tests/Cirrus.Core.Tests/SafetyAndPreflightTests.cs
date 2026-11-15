namespace Cirrus.Core.Tests;

public class SafetyTests
{
    [Fact]
    public void SafeTrashNeverDeletesFilesOrFolders()
    {
        var root = TestEnv.TempDir("trash");
        TestEnv.Write("keep me", Path.Combine(root, "a.txt"));
        TestEnv.Write("inner", Path.Combine(root, "folder", "b.txt"));
        LocalFiles.SafeTrash(Path.Combine(root, "a.txt"), root);
        LocalFiles.SafeTrash(Path.Combine(root, "folder"), root);
        // Same name again: kept side by side, nothing overwritten.
        TestEnv.Write("second", Path.Combine(root, "a.txt"));
        LocalFiles.SafeTrash(Path.Combine(root, "a.txt"), root);
        Assert.False(File.Exists(Path.Combine(root, "a.txt")));
        var bin = TestEnv.Tree(Path.Combine(root, ".cirrus", "Removed"));
        Assert.Equal(2, bin.Count(p => p.EndsWith("a.txt")));
        Assert.Contains(bin, p => p.EndsWith("folder/b.txt"));
        var contents = Directory.GetFiles(Path.Combine(root, ".cirrus", "Removed"), "*a.txt", SearchOption.AllDirectories).Select(File.ReadAllText).ToHashSet();
        Assert.Equal(new HashSet<string> { "keep me", "second" }, contents);
        // Without a root the item is moved aside next to where it was.
        TestEnv.Write("loose", Path.Combine(root, "sub", "c.txt"));
        LocalFiles.SafeTrash(Path.Combine(root, "sub", "c.txt"), null);
        Assert.Single(Directory.GetFiles(Path.Combine(root, "sub", ".cirrus", "Removed"), "c.txt", SearchOption.AllDirectories));
    }

    [Fact]
    public void RecyclerIsOnlyTrustedWhenItCanRecover()
    {
        // Off Windows the Recycle Bin path must refuse, so SafeTrash falls back to moving the item aside.
        Assert.False(new WindowsRecycleBin().TryRecycle(Path.Combine(TestEnv.Root, "nothing-here.txt")));
        Assert.False(new QuarantineRecycler().TryRecycle("x"));
    }

    [Fact]
    public void NativeICloudFoldersCountAsICloud()
    {
        var native = TestEnv.TempDir("iCloudDrive");
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", native);
        try
        {
            Assert.True(SafetyPolicy.IsICloudPath(native));
            Assert.True(SafetyPolicy.IsICloudPath(Path.Combine(native, "Docs", "a.txt")));
            Assert.False(SafetyPolicy.IsICloudPath(native + "-other"));
            Assert.False(SafetyPolicy.IsICloudPath(TestEnv.Root));
            SafetyPolicy.ReadOnlyICloud = true;
            Assert.Throws<ReadOnlyException>(() => SafetyPolicy.CheckLocalWrite(Path.Combine(native, "x")));
            SafetyPolicy.CheckLocalWrite(Path.Combine(TestEnv.Root, "x"));   // outside iCloud: fine
        }
        finally
        {
            SafetyPolicy.ReadOnlyICloud = false;
            Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", null);
        }
    }

    [Fact]
    public void TesterBuildsDefaultToReadOnlyUntilChanged()
    {
        var s = Settings.Load(testerBuild: true);
        try
        {
            Assert.True(s.ReadOnlyICloud);
            Assert.True(SafetyPolicy.ReadOnlyICloud);
            s.ReadOnlyICloud = false;
            Assert.False(SafetyPolicy.ReadOnlyICloud);
            Assert.False(Settings.Load(testerBuild: true).ReadOnlyICloud);   // the tester's choice sticks
            var regular = Settings.Load(testerBuild: false);
            regular.ReadOnlyICloudSetting = null;
            Assert.False(regular.ReadOnlyICloud);
        }
        finally
        {
            var reset = Settings.Load(false);
            reset.ReadOnlyICloudSetting = null;
            reset.Save();
            SafetyPolicy.ReadOnlyICloud = false;
        }
    }
}

public class PreflightTests
{
    sealed class FakeAccount
    {
        public static Account Web(long total, long used) => new("web:t@example.com", AccountKind.Web, "t") { AppleID = "t@example.com" };
    }

    static Preflight Make(long volumeFree = 1L << 40, bool fat = false, StorageUsage? storage = null, TransferManager? tm = null) => new()
    {
        Transfers = tm ?? new TransferManager(),
        VolumeFree = _ => volumeFree,
        IsFat = _ => fat,
        VolumeName = _ => "Test Drive",
        IsNativeICloud = _ => false,
        Storage = _ => Task.FromResult(storage),
    };

    /// <summary>Sparse files: report a large size without using disk space.</summary>
    static string Sparse(string dir, string name, long size)
    {
        var p = Path.Combine(dir, name);
        using (var fs = File.Create(p)) fs.SetLength(size);
        return p;
    }

    [Fact]
    public async Task DriveUploadsBlockOver50GBAndCautionOver10GB()
    {
        var dir = TestEnv.TempDir("pre-drive");
        try
        {
            var huge = Sparse(dir, "huge.bin", 51_000_000_000);
            var big = Sparse(dir, "big.bin", 11_000_000_000);
            var small = Sparse(dir, "small.txt", 1000);
            var acct = FakeAccount.Web(0, 0);
            var pre = Make(storage: new StorageUsage(200_000_000_000, 100_000_000_000, []));
            var r = await pre.CheckUpload([huge, big, small], new Destination.Drive(acct, "FOLDER::x::root"), move: false);
            Assert.Equal(3, r.Files);
            Assert.Equal(["huge.bin"], r.Blocked.Select(b => b.Name).ToList());
            Assert.Contains("50 GB", r.Blocked[0].Reason);
            Assert.Contains(r.Cautions, c => c.Contains("big.bin") && c.Contains("10 GB"));
            Assert.Equal(100_000_000_000, r.Available);
            Assert.Equal(0, r.Shortfall);
            Assert.True(r.NeedsConfirmation);
            var prompt = r.Describe("Upload", "“iCloud Drive”");
            Assert.Equal(0, prompt.ProceedButton);
            Assert.Contains("These will be skipped", prompt.Body);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task ICloudFreeSpaceSubtractsQueuedUploads()
    {
        var dir = TestEnv.TempDir("pre-quota");
        try
        {
            var f = Sparse(dir, "video.mov", 6_000_000_000);
            var acct = FakeAccount.Web(0, 0);
            var tm = new TransferManager { MaxConcurrent = 1 };
            var gate = new TaskCompletionSource();
            // Something already queued that will write 5 GB into this iCloud account.
            tm.Enqueue("queued", async (t, ct) => { t.Report(0, 5_000_000_000); await gate.Task; }, total: 5_000_000_000, quotaKey: Preflight.ICloudKey(acct));
            var pre = Make(storage: new StorageUsage(50_000_000_000, 40_000_000_000, []), tm: tm);
            var r = await pre.CheckUpload([f], new Destination.Drive(acct, "root"), false);
            Assert.Equal(5_000_000_000, r.Available);
            Assert.Equal(1_000_000_000, r.Shortfall);
            var prompt = r.Describe("Upload", "“iCloud Drive”");
            Assert.Equal("Not enough iCloud storage", prompt.Title);
            Assert.Equal(PreflightSeverity.Critical, prompt.Severity);
            Assert.Equal(["Cancel", "Upload Anyway"], prompt.Buttons);
            gate.SetResult();
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task Fat32DestinationsBlockFilesOver4GB()
    {
        var dir = TestEnv.TempDir("pre-fat");
        try
        {
            var f = Sparse(dir, "movie.mkv", 5_000_000_000);
            var r = await Make(fat: true).CheckUpload([f], new Destination.Local(TestEnv.TempDir("usb")), false);
            Assert.True(r.AllBlocked);
            Assert.Contains("FAT32", r.Blocked[0].Reason);
            var prompt = r.Describe("Copy", "“USB”");
            Assert.Equal(-1, prompt.ProceedButton);
            Assert.Equal(["OK"], prompt.Buttons);
            // Downloads to FAT32 are checked too (photos count their Live video when it's exported).
            var asset = new PhotoAsset { Id = "p", Filename = "long.mov", Size = 4_300_000_000,
                Resources = [new PhotoResource { Kind = PhotoResourceKind.Original, Size = 4_300_000_000 }] };
            var d = await Make(fat: true).CheckDownload([new TransferItem("long.mov", 4_300_000_000, false, Photo: asset)], dir, true, false);
            Assert.Single(d.Blocked);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task DownloadsCheckDestinationFreeSpace()
    {
        var items = new[] { new TransferItem("a.zip", 3_000_000_000, false), new TransferItem("b.zip", 3_000_000_000, false) };
        var r = await Make(volumeFree: 5_000_000_000).CheckDownload(items, TestEnv.Root, false, false);
        Assert.Equal(6_000_000_000, r.Bytes);
        Assert.Equal(1_000_000_000, r.Shortfall);
        Assert.StartsWith("Not enough space on “Test Drive”", r.Describe("Download", "“Downloads”").Title);
    }

    [Fact]
    public async Task LargeBatchesNeedConfirmationAndSmallOnesDont()
    {
        var dir = TestEnv.TempDir("pre-batch");
        try
        {
            var small = await Make().CheckUpload([Sparse(dir, "one.txt", 10)], new Destination.Local(TestEnv.TempDir("to")), false);
            Assert.False(small.NeedsConfirmation);
            var bigOne = await Make().CheckUpload([Sparse(dir, "big.iso", 12_000_000_000)], new Destination.Local(TestEnv.TempDir("to2")), false);
            Assert.True(bigOne.IsBig);
            Assert.True(bigOne.NeedsConfirmation);
            var photos = new Destination.Photos(FakeAccount.Web(0, 0), new PhotoLibraryRef("PrimarySync", "Personal Library", false), null);
            var mixed = await Make(storage: new StorageUsage(10_000_000_000, 0, [])).CheckUpload([Sparse(dir, "a.jpg", 100), Sparse(dir, "notes.txt", 5)], photos, false);
            Assert.Equal(1, mixed.Files);
            Assert.Contains(mixed.Cautions, c => c.Contains("isn’t a photo or video"));
        }
        finally { Directory.Delete(dir, true); }
    }
}
