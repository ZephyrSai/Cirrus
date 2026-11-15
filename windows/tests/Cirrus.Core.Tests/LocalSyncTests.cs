namespace Cirrus.Core.Tests;

public class LocalSyncTests
{
    [Fact]
    public async Task LocalTwoWayRoundTrip()
    {
        string A = TestEnv.TempDir("A"), B = TestEnv.TempDir("B");
        TestEnv.Write("one", Path.Combine(A, "docs", "one.txt"), 1_000_000);
        TestEnv.Write("two", Path.Combine(B, "two.txt"), 1_000_000);
        TestEnv.Write("skip", Path.Combine(A, ".DS_Store"));
        TestEnv.Write("skip", Path.Combine(A, "desktop.ini"));
        var job = Guid.NewGuid();
        var excludes = new SyncOptions().Excludes;
        async Task<RunReport> Once()
        {
            var sa = new LocalSide(A, excludes); var sb = new LocalSide(B, excludes);
            var r = new SyncRunner(sa, sb);
            var (ma, mb) = await r.ScanAsync(null);
            var plan = SyncPlanner.Plan(SyncMode.TwoWay, ma, mb, SyncState.Load(job));
            var (rep, state) = await r.RunAsync(plan, ma, mb, null);
            state.Save(job);
            return rep;
        }
        var r1 = await Once();
        Assert.True(r1.Copied == 1 && r1.CopiedBack == 1 && r1.Failed.Count == 0, r1.Summary + string.Join(";", r1.Failed));
        Assert.True(File.Exists(Path.Combine(B, "docs", "one.txt")));
        Assert.True(File.Exists(Path.Combine(A, "two.txt")));
        Assert.False(File.Exists(Path.Combine(B, ".DS_Store")));
        Assert.False(File.Exists(Path.Combine(B, "desktop.ini")));
        Assert.Equal(1_000_000, new DateTimeOffset(File.GetLastWriteTimeUtc(Path.Combine(B, "docs", "one.txt"))).ToUnixTimeSeconds());
        // Second run is a no-op.
        Assert.Equal("Up to date", (await Once()).Summary);
        // Delete on B → removed on A too, but only moved aside (never deleted).
        File.Delete(Path.Combine(B, "two.txt"));
        var r3 = await Once();
        Assert.Equal(1, r3.Trashed);
        Assert.False(File.Exists(Path.Combine(A, "two.txt")));
        var removed = Directory.GetFiles(Path.Combine(A, ".cirrus", "Removed"), "two.txt", SearchOption.AllDirectories);
        Assert.Single(removed);
        Assert.Equal("two", File.ReadAllText(removed[0]));
        // Conflict: both edited → both versions kept on both sides.
        TestEnv.Write("A edit!", Path.Combine(A, "docs", "one.txt"), 2_000_000);
        TestEnv.Write("B edit", Path.Combine(B, "docs", "one.txt"), 2_000_100);
        var r4 = await Once();
        Assert.Equal(1, r4.Conflicts);
        Assert.Equal("B edit", File.ReadAllText(Path.Combine(A, "docs", "one.txt")));
        var aConflict = Directory.GetFiles(Path.Combine(A, "docs")).Where(f => f.Contains("conflict")).ToList();
        var bConflict = Directory.GetFiles(Path.Combine(B, "docs")).Where(f => f.Contains("conflict")).ToList();
        Assert.Single(aConflict);
        Assert.Single(bConflict);
        Assert.Equal("A edit!", File.ReadAllText(aConflict[0]));
        Assert.Equal("A edit!", File.ReadAllText(bConflict[0]));
        // And the run after that is quiet again.
        Assert.Equal("Up to date", (await Once()).Summary);
        SyncState.Forget(job);
    }

    [Fact]
    public async Task MirrorMovesExtrasAsideAndCopyNeverRemoves()
    {
        string src = TestEnv.TempDir("msrc"), dst = TestEnv.TempDir("mdst");
        TestEnv.Write("keep", Path.Combine(src, "keep.txt"), 1_000);
        TestEnv.Write("extra", Path.Combine(dst, "extra.txt"), 1_000);
        TestEnv.Write("old", Path.Combine(dst, "old", "inside.txt"), 1_000);
        var ex = new SyncOptions().Excludes;
        var runner = new SyncRunner(new LocalSide(src, ex), new LocalSide(dst, ex));
        var (a, b) = await runner.ScanAsync(null);
        var (copyRep, _) = await runner.RunAsync(SyncPlanner.Plan(SyncMode.Copy, a, b, null), a, b, null);
        Assert.Equal(0, copyRep.Trashed);
        Assert.True(File.Exists(Path.Combine(dst, "extra.txt")));
        (a, b) = await runner.ScanAsync(null);
        var (mirrorRep, _) = await runner.RunAsync(SyncPlanner.Plan(SyncMode.Mirror, a, b, null), a, b, null);
        Assert.Equal(2, mirrorRep.Trashed);
        Assert.False(File.Exists(Path.Combine(dst, "extra.txt")));
        var tree = TestEnv.Tree(Path.Combine(dst, ".cirrus", "Removed"));
        Assert.Contains(tree, p => p.EndsWith("/extra.txt"));
        Assert.Contains(tree, p => p.EndsWith("/old/inside.txt"));
        Assert.Equal("keep", File.ReadAllText(Path.Combine(dst, "keep.txt")));
    }

    [Fact]
    public async Task WindowsNameMappingKeepsSyncStable()
    {
        var was = WinNames.MapsLocally;
        WinNames.MapsLocally = true;
        try
        {
            Assert.Equal("Notes 10：30.txt", WinNames.ToLocal("Notes 10:30.txt"));
            foreach (var n in new[] { "a:b*c?.txt", "trailing. ", "CON", "con.txt", "Icon\r", "q\"<>|\\.md", "plain.txt" })
                Assert.Equal(n, WinNames.FromLocal(WinNames.ToLocal(n)));
            Assert.Equal("CON＿", WinNames.ToLocal("CON"));
            // A Drive-side name with a colon lands as a full-width colon locally and maps back on the next scan.
            string src = TestEnv.TempDir("wsrc"), dst = TestEnv.TempDir("wdst");
            TestEnv.Write("x", Path.Combine(src, WinNames.ToLocal("Meeting 10:30.txt")), 5_000);
            var side = new LocalSide(src, []);
            var scan = await side.ScanAsync(null, default);
            Assert.True(scan.ContainsKey("Meeting 10:30.txt"));
            var runner = new SyncRunner(side, new LocalSide(dst, []));
            var (a, b) = await runner.ScanAsync(null);
            await runner.RunAsync(SyncPlanner.Plan(SyncMode.Mirror, a, b, null), a, b, null);
            (a, b) = await runner.ScanAsync(null);
            Assert.True(SyncPlanner.Plan(SyncMode.Mirror, a, b, null).IsEmpty);
        }
        finally { WinNames.MapsLocally = was; }
    }
}
