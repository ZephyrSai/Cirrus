namespace Cirrus.Core.Tests;

public class SyncPlannerTests
{
    static SideEntry E(long size, double t, bool dir = false) => new(size, t, dir);

    [Fact]
    public void CopyPlanCopiesMissingAndChanged()
    {
        var a = new Dictionary<string, SideEntry> { ["d"] = E(0, 0, true), ["d/x.txt"] = E(10, 100), ["y.txt"] = E(5, 100), ["same.txt"] = E(3, 50) };
        var b = new Dictionary<string, SideEntry> { ["same.txt"] = E(3, 51), ["y.txt"] = E(4, 90) };
        var p = SyncPlanner.Plan(SyncMode.Copy, a, b, null);
        Assert.Contains(SyncAction.MkdirB("d"), p.Actions);
        Assert.Contains(SyncAction.CopyAB("d/x.txt", 10), p.Actions);
        Assert.Contains(SyncAction.CopyAB("y.txt", 5), p.Actions);
        Assert.DoesNotContain(p.Actions, x => x.Path == "same.txt");
        Assert.Equal(0, p.TrashCount);
        // parent folders are created before their children
        var order = p.Actions.Select(x => x.Path).ToList();
        Assert.True(order.IndexOf("d") < order.IndexOf("d/x.txt"));
    }

    [Fact]
    public void CopyPlanDoesNotClobberNewerDestination()
    {
        var p = SyncPlanner.Plan(SyncMode.Copy, new Dictionary<string, SideEntry> { ["f"] = E(1, 10) }, new Dictionary<string, SideEntry> { ["f"] = E(2, 500) }, null);
        Assert.Equal([SyncAction.SkipOf("f", "Newer on the destination")], p.Actions);
        // Same size but newer on the destination: silently left alone.
        var q = SyncPlanner.Plan(SyncMode.Copy, new Dictionary<string, SideEntry> { ["f"] = E(2, 10) }, new Dictionary<string, SideEntry> { ["f"] = E(2, 500) }, null);
        Assert.True(q.IsEmpty);
    }

    [Fact]
    public void CopyNeverRemovesAndMirrorTrashesTopmostExtrasOnly()
    {
        var a = new Dictionary<string, SideEntry> { ["keep.txt"] = E(1, 1) };
        var b = new Dictionary<string, SideEntry> { ["keep.txt"] = E(1, 1), ["old"] = E(0, 0, true), ["old/a"] = E(1, 1), ["old/b"] = E(1, 1), ["stray.txt"] = E(1, 1) };
        Assert.Equal(0, SyncPlanner.Plan(SyncMode.Copy, a, b, null).TrashCount);
        var p = SyncPlanner.Plan(SyncMode.Mirror, a, b, null);
        Assert.Contains(SyncAction.TrashB("old"), p.Actions);
        Assert.Contains(SyncAction.TrashB("stray.txt"), p.Actions);
        Assert.DoesNotContain(SyncAction.TrashB("old/a"), p.Actions);
        Assert.Equal(2, p.TrashCount);
        Assert.DoesNotContain(p.Actions, x => x.Kind == SyncActionKind.TrashA);   // the source is never touched
    }

    [Fact]
    public void TwoWayUsesBaseline()
    {
        var st = new SyncState();
        foreach (var k in new[] { "both.txt", "goneB.txt", "editA.txt", "clash.txt" }) st.Entries[k] = new SyncState.Entry(1, 10, 10);
        var a = new Dictionary<string, SideEntry> { ["both.txt"] = E(1, 10), ["goneB.txt"] = E(1, 10), ["editA.txt"] = E(2, 99), ["clash.txt"] = E(3, 200), ["newA.txt"] = E(4, 5) };
        var b = new Dictionary<string, SideEntry> { ["both.txt"] = E(1, 10), ["editA.txt"] = E(1, 10), ["clash.txt"] = E(5, 300), ["newB.txt"] = E(6, 5) };
        var p = SyncPlanner.Plan(SyncMode.TwoWay, a, b, st);
        Assert.Contains(SyncAction.TrashA("goneB.txt"), p.Actions);
        Assert.Contains(SyncAction.CopyAB("editA.txt", 2), p.Actions);
        Assert.Contains(SyncAction.CopyAB("newA.txt", 4), p.Actions);
        Assert.Contains(SyncAction.CopyBA("newB.txt", 6), p.Actions);
        Assert.Contains(SyncAction.ConflictOf("clash.txt", false, 5), p.Actions);
        Assert.DoesNotContain(p.Actions, x => x.Path == "both.txt");
    }

    [Fact]
    public void TwoWayFirstRunNeverDeletes()
    {
        var a = new Dictionary<string, SideEntry> { ["onlyA.txt"] = E(1, 1), ["same.txt"] = E(3, 5) };
        var b = new Dictionary<string, SideEntry> { ["onlyB.txt"] = E(2, 2), ["same.txt"] = E(3, 900) };
        var p = SyncPlanner.Plan(SyncMode.TwoWay, a, b, new SyncState());
        Assert.Equal(0, p.TrashCount);
        Assert.Contains(SyncAction.CopyAB("onlyA.txt", 1), p.Actions);
        Assert.Contains(SyncAction.CopyBA("onlyB.txt", 2), p.Actions);
        Assert.DoesNotContain(p.Actions, x => x.Path == "same.txt");   // first run: same size → assumed identical
    }

    [Fact]
    public void TwoWayKeepsFolderWithNewContent()
    {
        var st = new SyncState();
        st.Entries["dir"] = new SyncState.Entry(-1, 0, 0);
        st.Entries["dir/old.txt"] = new SyncState.Entry(1, 1, 1);
        var a = new Dictionary<string, SideEntry> { ["dir"] = E(0, 0, true), ["dir/old.txt"] = E(1, 1), ["dir/new.txt"] = E(2, 2) };
        var p = SyncPlanner.Plan(SyncMode.TwoWay, a, new Dictionary<string, SideEntry>(), st);
        Assert.Contains(SyncAction.MkdirB("dir"), p.Actions);
        Assert.Contains(SyncAction.CopyAB("dir/new.txt", 2), p.Actions);
        Assert.DoesNotContain(SyncAction.TrashA("dir"), p.Actions);
    }

    [Fact]
    public void TwoWayRemovesFolderDeletedOnOtherSideAsOneItem()
    {
        var st = new SyncState();
        st.Entries["dir"] = new SyncState.Entry(-1, 0, 0);
        st.Entries["dir/a.txt"] = new SyncState.Entry(1, 1, 1);
        st.Entries["dir/b.txt"] = new SyncState.Entry(1, 1, 1);
        var a = new Dictionary<string, SideEntry> { ["dir"] = E(0, 0, true), ["dir/a.txt"] = E(1, 1), ["dir/b.txt"] = E(1, 1) };
        var p = SyncPlanner.Plan(SyncMode.TwoWay, a, new Dictionary<string, SideEntry>(), st);
        Assert.Equal([SyncAction.TrashA("dir")], p.Actions);
    }

    [Fact]
    public void DeleteGuardTripsOnMassRemoval()
    {
        var a = new Dictionary<string, SideEntry>();
        var b = Enumerable.Range(0, 40).ToDictionary(i => $"f{i}.txt", _ => E(1, 1));
        var p = SyncPlanner.Plan(SyncMode.Mirror, a, b, null);
        Assert.Equal(40, p.TrashCount);
        Assert.True(SyncPlanner.GuardTripped(p, SyncMode.Mirror, 50));
        // A handful of removals (≤ 20) never trips it.
        var small = SyncPlanner.Plan(SyncMode.Mirror, a, b.Take(10).ToDictionary(), null);
        Assert.False(SyncPlanner.GuardTripped(small, SyncMode.Mirror, 50));
    }

    [Fact]
    public void PathOrderPutsParentsFirstAndSortsNaturally()
    {
        var list = new List<string> { "b/x", "a10", "a2", "b", "a2/z", "A3" };
        list.Sort(SyncPlanner.PathOrder);
        Assert.Equal(["a2", "a2/z", "A3", "a10", "b", "b/x"], list);
        var name = SyncPlanner.ConflictName("dir/report.final.docx", "iCloud Drive");
        Assert.StartsWith("dir/report.final (conflict from iCloud Drive ", name);
        Assert.EndsWith(").docx", name);
    }
}
