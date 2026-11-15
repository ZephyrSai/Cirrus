using System.Globalization;
using System.Text;

namespace Cirrus.Core;

public readonly record struct SideEntry(long Size, double Mtime, bool IsDir);   // mtime: seconds since 1970

public interface ISyncSide
{
    string Label { get; }
    long? FreeSpace { get; }
    Task<Dictionary<string, SideEntry>> ScanAsync(Action<int>? progress, CancellationToken ct);
    /// <summary>Returns a local file holding the content; IsTemporary tells the caller to delete its folder after use.</summary>
    Task<(string Path, bool IsTemporary)> FetchAsync(string rel, Action<long, long>? progress, CancellationToken ct);
    Task StoreAsync(string rel, string file, DateTimeOffset mtime, Action<long, long>? progress, CancellationToken ct);
    Task MakeDirAsync(string rel, CancellationToken ct);
    /// <summary>Recoverable removal only: Recycle Bin / .cirrus\Removed locally, Recently Deleted in iCloud.</summary>
    Task TrashAsync(string rel, CancellationToken ct);
}

public enum SyncActionKind { CopyAB, CopyBA, MkdirB, MkdirA, TrashB, TrashA, Conflict, Skip }

public sealed record SyncAction(SyncActionKind Kind, string Path, long Size = 0, bool NewerIsA = false, string? Reason = null)
{
    public static SyncAction CopyAB(string p, long s) => new(SyncActionKind.CopyAB, p, s);
    public static SyncAction CopyBA(string p, long s) => new(SyncActionKind.CopyBA, p, s);
    public static SyncAction MkdirB(string p) => new(SyncActionKind.MkdirB, p);
    public static SyncAction MkdirA(string p) => new(SyncActionKind.MkdirA, p);
    public static SyncAction TrashB(string p) => new(SyncActionKind.TrashB, p);
    public static SyncAction TrashA(string p) => new(SyncActionKind.TrashA, p);
    public static SyncAction ConflictOf(string p, bool newerIsA, long size) => new(SyncActionKind.Conflict, p, size, newerIsA);
    public static SyncAction SkipOf(string p, string reason) => new(SyncActionKind.Skip, p, 0, false, reason);

    public long Bytes => Kind switch { SyncActionKind.CopyAB or SyncActionKind.CopyBA => Size, SyncActionKind.Conflict => Size * 2, _ => 0 };
    public bool IsDestructive => Kind is SyncActionKind.TrashA or SyncActionKind.TrashB;
    public bool IsMkdir => Kind is SyncActionKind.MkdirA or SyncActionKind.MkdirB;
}

public sealed class SyncPlan
{
    public List<SyncAction> Actions { get; init; } = [];
    public int SourceCount { get; init; }
    public int DestinationCount { get; init; }
    public long Bytes => Actions.Sum(a => a.Bytes);
    public int TrashCount => Actions.Count(a => a.IsDestructive);
    public int TransferCount => Actions.Count(a => a.Kind != SyncActionKind.Skip && !a.IsMkdir && !a.IsDestructive);
    public bool IsEmpty => Actions.All(a => a.Kind == SyncActionKind.Skip);
}

public static class SyncPlanner
{
    internal const double Slack = 2.0;   // FAT/exFAT keep 2-second times; iCloud rounds too

    static bool Same(SideEntry a, SideEntry b) => a.Size == b.Size && Math.Abs(a.Mtime - b.Mtime) <= Slack;

    /// <summary>One-way (copy / mirror) or two-way plan from scans of side A (source) and B (destination).</summary>
    public static SyncPlan Plan(SyncMode mode, IReadOnlyDictionary<string, SideEntry> a, IReadOnlyDictionary<string, SideEntry> b, SyncState? state)
    {
        var actions = new List<SyncAction>();
        var keysA = a.Keys.ToList();
        keysA.Sort(PathOrder);
        switch (mode)
        {
            case SyncMode.Copy:
            case SyncMode.Mirror:
                foreach (var rel in keysA)
                {
                    var ea = a[rel];
                    if (ea.IsDir)
                    {
                        if (b.TryGetValue(rel, out var ebd)) { if (!ebd.IsDir) actions.Add(SyncAction.SkipOf(rel, "A file with this name exists on the destination")); }
                        else actions.Add(SyncAction.MkdirB(rel));
                        continue;
                    }
                    if (!b.TryGetValue(rel, out var eb)) { actions.Add(SyncAction.CopyAB(rel, ea.Size)); continue; }
                    if (eb.IsDir) { actions.Add(SyncAction.SkipOf(rel, "A folder with this name exists on the destination")); continue; }
                    if (Same(ea, eb)) continue;
                    if (mode == SyncMode.Copy && eb.Mtime > ea.Mtime + Slack && ea.Size != eb.Size)
                    {
                        actions.Add(SyncAction.SkipOf(rel, "Newer on the destination"));
                        continue;
                    }
                    if (mode == SyncMode.Copy && eb.Mtime > ea.Mtime + Slack) continue;
                    actions.Add(SyncAction.CopyAB(rel, ea.Size));
                }
                if (mode == SyncMode.Mirror)
                {
                    var trashedDirs = new List<string>();
                    var keysB = b.Keys.ToList();
                    keysB.Sort(PathOrder);
                    foreach (var rel in keysB)
                    {
                        if (a.ContainsKey(rel)) continue;
                        if (trashedDirs.Any(d => rel.StartsWith(d + "/", StringComparison.Ordinal))) continue;
                        actions.Add(SyncAction.TrashB(rel));
                        if (b[rel].IsDir) trashedDirs.Add(rel);
                    }
                }
                break;

            case SyncMode.TwoWay:
                var st = state?.Entries ?? [];
                var all = a.Keys.Union(b.Keys).ToList();
                all.Sort(PathOrder);
                var fileActions = new Dictionary<string, SyncAction>();
                foreach (var rel in all)
                {
                    a.TryGetValue(rel, out var xa); var hasA = a.ContainsKey(rel);
                    b.TryGetValue(rel, out var yb); var hasB = b.ContainsKey(rel);
                    if ((hasA && xa.IsDir) || (hasB && yb.IsDir)) continue;
                    st.TryGetValue(rel, out var s);
                    bool changedA = hasA && (s is null || s.Size != xa.Size || Math.Abs(s.MtimeA - xa.Mtime) > Slack);
                    bool changedB = hasB && (s is null || s.Size != yb.Size || Math.Abs(s.MtimeB - yb.Mtime) > Slack);
                    if (hasA && hasB)
                    {
                        if (Same(xa, yb)) continue;
                        if (s is null && xa.Size == yb.Size) continue;   // first run: assume identical
                        if (changedA && !changedB) fileActions[rel] = SyncAction.CopyAB(rel, xa.Size);
                        else if (changedB && !changedA) fileActions[rel] = SyncAction.CopyBA(rel, yb.Size);
                        else if (!changedA && !changedB) continue;
                        else fileActions[rel] = SyncAction.ConflictOf(rel, xa.Mtime >= yb.Mtime, Math.Max(xa.Size, yb.Size));
                    }
                    else if (hasA)
                        fileActions[rel] = s is not null && !changedA ? SyncAction.TrashA(rel) : SyncAction.CopyAB(rel, xa.Size);
                    else if (hasB)
                        fileActions[rel] = s is not null && !changedB ? SyncAction.TrashB(rel) : SyncAction.CopyBA(rel, yb.Size);
                }
                // Folders: create where missing; remove a folder deleted on the other side only when nothing
                // inside it is new or changed.
                var dirActions = new List<SyncAction>();
                var removedDirs = new List<string>();
                foreach (var rel in all)
                {
                    var hasA = a.TryGetValue(rel, out var xa);
                    var hasB = b.TryGetValue(rel, out var yb);
                    var isDir = (hasA && xa.IsDir) || (hasB && yb.IsDir);
                    if (!isDir || hasA == hasB) continue;
                    if (removedDirs.Any(d => rel.StartsWith(d + "/", StringComparison.Ordinal))) continue;
                    var onA = hasA;
                    var wasKnown = st.ContainsKey(rel);
                    var children = fileActions.Where(kv => kv.Key.StartsWith(rel + "/", StringComparison.Ordinal)).Select(kv => kv.Value).ToList();
                    var allTrash = children.All(c => c.Kind == (onA ? SyncActionKind.TrashA : SyncActionKind.TrashB));
                    if (wasKnown && allTrash)
                    {
                        dirActions.Add(onA ? SyncAction.TrashA(rel) : SyncAction.TrashB(rel));
                        removedDirs.Add(rel);
                        foreach (var k in fileActions.Keys.Where(k => k.StartsWith(rel + "/", StringComparison.Ordinal)).ToList()) fileActions.Remove(k);
                    }
                    else dirActions.Add(onA ? SyncAction.MkdirB(rel) : SyncAction.MkdirA(rel));
                }
                var fileKeys = fileActions.Keys.ToList();
                fileKeys.Sort(PathOrder);
                actions = dirActions.Where(d => d.IsMkdir).Concat(fileKeys.Select(k => fileActions[k])).Concat(dirActions.Where(d => d.IsDestructive)).ToList();
                break;
        }
        return new SyncPlan { Actions = actions, SourceCount = a.Count, DestinationCount = b.Count };
    }

    /// <summary>Parents before children, then natural (Finder/Explorer-like) order by component.</summary>
    public static int PathOrder(string x, string y)
    {
        var cx = x.Split('/'); var cy = y.Split('/');
        for (int i = 0; i < Math.Min(cx.Length, cy.Length); i++)
        {
            if (cx[i] == cy[i]) continue;
            var c = NaturalComparer.Instance.Compare(cx[i], cy[i]);
            return c != 0 ? c : string.CompareOrdinal(cx[i], cy[i]);
        }
        return cx.Length.CompareTo(cy.Length);
    }

    public static string ConflictName(string rel, string side)
    {
        var slash = rel.LastIndexOf('/');
        var dir = slash >= 0 ? rel[..slash] : "";
        var name = slash >= 0 ? rel[(slash + 1)..] : rel;
        var dot = name.LastIndexOf('.');
        var stem = dot > 0 ? name[..dot] : name;
        var ext = dot > 0 ? name[(dot + 1)..] : "";
        var n = $"{stem} (conflict from {side} {DateTime.Now.ToString("yyyy-MM-dd HHmm", CultureInfo.InvariantCulture)})" + (ext.Length == 0 ? "" : "." + ext);
        return dir.Length == 0 ? n : dir + "/" + n;
    }

    /// <summary>The mirror/two-way delete guard: more than 20 removals and more than MaxDeletePercent of the items.</summary>
    public static bool GuardTripped(SyncPlan plan, SyncMode mode, int maxDeletePercent)
    {
        var n = plan.TrashCount;
        var baseCount = Math.Max(1, mode == SyncMode.TwoWay ? plan.SourceCount + plan.DestinationCount : plan.DestinationCount);
        return n > 20 && n * 100 / baseCount > maxDeletePercent;
    }

    public static string Describe(SyncPlan plan)
    {
        if (plan.IsEmpty) return "Everything is up to date.";
        var parts = new List<string>();
        int copies = plan.Actions.Count(a => a.Kind == SyncActionKind.CopyAB), back = plan.Actions.Count(a => a.Kind == SyncActionKind.CopyBA);
        int conflicts = plan.Actions.Count(a => a.Kind == SyncActionKind.Conflict), skips = plan.Actions.Count(a => a.Kind == SyncActionKind.Skip);
        if (copies > 0) parts.Add($"{copies} to copy");
        if (back > 0) parts.Add($"{back} to copy back");
        if (conflicts > 0) parts.Add($"{conflicts} conflict{(conflicts == 1 ? "" : "s")} (both kept)");
        if (plan.TrashCount > 0) parts.Add($"{plan.TrashCount} to move to the Recycle Bin");
        if (skips > 0) parts.Add($"{skips} skipped");
        return string.Join(", ", parts) + (plan.Bytes > 0 ? " — " + plan.Bytes.ByteString() : "");
    }
}

public sealed class SyncRunner
{
    readonly ISyncSide _a, _b;
    readonly int _concurrency;
    public SyncRunner(ISyncSide a, ISyncSide b, int concurrency = 4) { _a = a; _b = b; _concurrency = concurrency; }

    public async Task<(Dictionary<string, SideEntry> A, Dictionary<string, SideEntry> B)> ScanAsync(Action<RunProgress>? progress, CancellationToken ct = default)
    {
        progress?.Invoke(new RunProgress($"Scanning {_a.Label}…", 0, 0, 0, 0));
        var sa = await _a.ScanAsync(n => progress?.Invoke(new RunProgress($"Scanning {_a.Label}… {n} items", 0, 0, 0, 0)), ct).ConfigureAwait(false);
        progress?.Invoke(new RunProgress($"Scanning {_b.Label}…", 0, 0, 0, 0));
        var sb = await _b.ScanAsync(n => progress?.Invoke(new RunProgress($"Scanning {_b.Label}… {n} items", 0, 0, 0, 0)), ct).ConfigureAwait(false);
        return (sa, sb);
    }

    async Task Copy(ISyncSide src, string rel, ISyncSide dst, string? dstRel, double? mtime, Action<long> onBytes, CancellationToken ct)
    {
        var fetched = await src.FetchAsync(rel, (d, _) => onBytes(d), ct).ConfigureAwait(false);
        try
        {
            var m = mtime is double t ? DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(t * 1000)) : new DateTimeOffset(File.GetLastWriteTimeUtc(fetched.Path), TimeSpan.Zero);
            await dst.StoreAsync(dstRel ?? rel, fetched.Path, m, null, ct).ConfigureAwait(false);
        }
        finally
        {
            if (fetched.IsTemporary) { try { Directory.Delete(Path.GetDirectoryName(fetched.Path)!, true); } catch { } }   // our own scratch folder
        }
    }

    /// <summary>Executes a plan. Returns the report and (for two-way) the new baseline.</summary>
    public async Task<(RunReport Report, SyncState State)> RunAsync(SyncPlan plan, IReadOnlyDictionary<string, SideEntry> sa, IReadOnlyDictionary<string, SideEntry> sb,
        Action<RunProgress>? progress, CancellationToken ct = default)
    {
        var total = plan.Bytes;
        var files = plan.Actions.Count;
        var report = new RunReport();
        var gate = new object();
        int filesDone = 0;
        long bytesDone = 0;
        var finalA = new Dictionary<string, SideEntry>(sa);
        var finalB = new Dictionary<string, SideEntry>(sb);
        void Tick(string phase) { int f; long b; lock (gate) { f = filesDone; b = bytesDone; } progress?.Invoke(new RunProgress(phase, f, files, b, total)); }
        void Fail(string path, Exception e)
        {
            Log.Error($"sync failed for an item: {e.Message}");
            lock (gate) report.Failed.Add($"{path}: {e.Message}");
        }
        void SetA(string k, IReadOnlyDictionary<string, SideEntry> from) { lock (gate) { if (from.TryGetValue(k, out var v)) finalA[k] = v; else finalA.Remove(k); } }
        void SetB(string k, IReadOnlyDictionary<string, SideEntry> from) { lock (gate) { if (from.TryGetValue(k, out var v)) finalB[k] = v; else finalB.Remove(k); } }
        static void RemoveTree(Dictionary<string, SideEntry> m, string k) { m.Remove(k); foreach (var x in m.Keys.Where(x => x.StartsWith(k + "/", StringComparison.Ordinal)).ToList()) m.Remove(x); }

        // Folder creation first, sequentially.
        foreach (var act in plan.Actions)
        {
            ct.ThrowIfCancellationRequested();
            switch (act.Kind)
            {
                case SyncActionKind.MkdirB:
                    try { await _b.MakeDirAsync(act.Path, ct).ConfigureAwait(false); SetB(act.Path, sa); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception e) { Fail(act.Path, e); }
                    lock (gate) filesDone++;
                    break;
                case SyncActionKind.MkdirA:
                    try { await _a.MakeDirAsync(act.Path, ct).ConfigureAwait(false); SetA(act.Path, sb); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception e) { Fail(act.Path, e); }
                    lock (gate) filesDone++;
                    break;
                case SyncActionKind.Skip:
                    lock (gate) { filesDone++; report.Skipped++; }
                    break;
            }
        }
        Tick("Copying…");
        var transfers = plan.Actions.Where(x => x.Kind is SyncActionKind.CopyAB or SyncActionKind.CopyBA or SyncActionKind.Conflict).ToList();
        using (var sem = new SemaphoreSlim(_concurrency))
        {
            var tasks = new List<Task>();
            foreach (var act in transfers)
            {
                await sem.WaitAsync(ct).ConfigureAwait(false);
                tasks.Add(Task.Run(async () =>
                {
                    try
                    {
                        ct.ThrowIfCancellationRequested();
                        long last = 0;
                        void OnBytes(long d)
                        {
                            long delta;
                            lock (gate) { delta = d - last; last = d; if (delta > 0) bytesDone += delta; }
                            Tick("Copying " + act.Path.Split('/')[^1]);
                        }
                        try
                        {
                            switch (act.Kind)
                            {
                                case SyncActionKind.CopyAB:
                                    await Copy(_a, act.Path, _b, null, sa.TryGetValue(act.Path, out var ea) ? ea.Mtime : null, OnBytes, ct).ConfigureAwait(false);
                                    SetB(act.Path, sa);
                                    lock (gate) { report.Copied++; report.Bytes += act.Size; }
                                    break;
                                case SyncActionKind.CopyBA:
                                    await Copy(_b, act.Path, _a, null, sb.TryGetValue(act.Path, out var eb) ? eb.Mtime : null, OnBytes, ct).ConfigureAwait(false);
                                    SetA(act.Path, sb);
                                    lock (gate) { report.CopiedBack++; report.Bytes += act.Size; }
                                    break;
                                case SyncActionKind.Conflict:
                                    // Keep both: the older side's version is saved under a "(conflict from …)" name on both sides,
                                    // then the newer version takes the original name everywhere.
                                    var (newer, older) = act.NewerIsA ? (_a, _b) : (_b, _a);
                                    var cname = SyncPlanner.ConflictName(act.Path, older.Label);
                                    last = 0; await Copy(older, act.Path, older, cname, null, OnBytes, ct).ConfigureAwait(false);
                                    last = 0; await Copy(older, cname, newer, null, null, OnBytes, ct).ConfigureAwait(false);
                                    var src = act.NewerIsA ? sa : sb;
                                    last = 0; await Copy(newer, act.Path, older, null, src.TryGetValue(act.Path, out var en) ? en.Mtime : null, OnBytes, ct).ConfigureAwait(false);
                                    if (act.NewerIsA) SetB(act.Path, sa); else SetA(act.Path, sb);
                                    lock (gate) report.Conflicts++;
                                    break;
                            }
                        }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception e) { Fail(act.Path, e); }
                        lock (gate) filesDone++;
                    }
                    finally { sem.Release(); }
                }, ct));
            }
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        // Removals last (children were already skipped by the planner when a parent folder goes).
        foreach (var act in plan.Actions.Where(x => x.IsDestructive))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                if (act.Kind == SyncActionKind.TrashA) { await _a.TrashAsync(act.Path, ct).ConfigureAwait(false); lock (gate) RemoveTree(finalA, act.Path); }
                else { await _b.TrashAsync(act.Path, ct).ConfigureAwait(false); lock (gate) RemoveTree(finalB, act.Path); }
                lock (gate) report.Trashed++;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception e) { Fail(act.Path, e); }
            lock (gate) filesDone++;
            Tick("Moving removed items to the Recycle Bin…");
        }
        var state = new SyncState();
        foreach (var (rel, ea) in finalA)
            if (finalB.TryGetValue(rel, out var eb)) state.Entries[rel] = new SyncState.Entry(ea.IsDir ? -1 : ea.Size, ea.Mtime, eb.Mtime);
        return (report, state);
    }
}

// MARK: - Sides

/// <summary>A local folder. On Windows, names iCloud allows but NTFS doesn't are mapped (see <see cref="WinNames"/>).</summary>
public sealed class LocalSide : ISyncSide
{
    public string Root { get; }
    public IReadOnlyList<string> Excludes { get; }
    readonly object _lock = new();
    Dictionary<string, string> _actual = [];   // NFC logical key → on-disk relative path

    /// <summary>
    /// Destinations may not exist yet (first run). Sources must: a missing source folder (unplugged drive,
    /// renamed folder) must never look like "everything was deleted".
    /// </summary>
    public bool AllowMissing { get; init; }

    public LocalSide(string root, IReadOnlyList<string> excludes, bool allowMissing = false)
    {
        Root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        if (Root.Length == 0 || Root.EndsWith(':')) Root += Path.DirectorySeparatorChar;
        Excludes = excludes;
        AllowMissing = allowMissing;
    }

    public string Label { get { var n = Path.GetFileName(Root); return string.IsNullOrEmpty(n) ? Root : n; } }
    public long? FreeSpace => VolumeInfo.FreeSpace(Root);

    string PathOf(string rel)
    {
        string? onDisk;
        lock (_lock) _actual.TryGetValue(rel, out onDisk);
        return Paths.Combine(Root, onDisk ?? WinNames.RelToLocal(rel));
    }

    public Task<Dictionary<string, SideEntry>> ScanAsync(Action<int>? progress, CancellationToken ct) => Task.Run(() =>
    {
        var output = new Dictionary<string, SideEntry>();
        var map = new Dictionary<string, string>();
        if (!Directory.Exists(Root))
        {
            // Scanning never creates anything; folders are made only when something is stored.
            if (AllowMissing) return output;
            throw SyncException.Unavailable($"“{Root}” isn’t available. Connect the drive or choose the folder again.");
        }
        var stack = new Stack<(DirectoryInfo Dir, string Rel)>();
        stack.Push((new DirectoryInfo(Root), ""));
        int n = 0;
        var opts = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0, RecurseSubdirectories = false, ReturnSpecialDirectories = false };
        while (stack.Count > 0)
        {
            var (dir, prefix) = stack.Pop();
            IEnumerable<FileSystemInfo> entries;
            try { entries = dir.EnumerateFileSystemInfos("*", opts).ToList(); } catch { continue; }
            foreach (var e in entries)
            {
                var diskRel = prefix.Length == 0 ? e.Name : prefix + "/" + e.Name;
                var logical = WinNames.RelFromLocal(diskRel).Normalize(NormalizationForm.FormC);
                if (Glob.Excluded(logical, Excludes)) continue;
                if (e.LinkTarget is not null) continue;   // symbolic links and junctions (cloud placeholders are not links)
                var isDir = (e.Attributes & FileAttributes.Directory) != 0;
                map[logical] = diskRel;
                var mtime = e.LastWriteTimeUtc;
                output[logical] = new SideEntry(isDir ? 0 : ((FileInfo)e).Length, new DateTimeOffset(mtime, TimeSpan.Zero).ToUnixTimeMilliseconds() / 1000.0, isDir);
                if (isDir) stack.Push(((DirectoryInfo)e, diskRel));
                n++;
                if (n % 500 == 0) { progress?.Invoke(n); ct.ThrowIfCancellationRequested(); }
            }
        }
        lock (_lock) _actual = map;
        return output;
    }, ct);

    public async Task<(string Path, bool IsTemporary)> FetchAsync(string rel, Action<long, long>? progress, CancellationToken ct)
    {
        var p = PathOf(rel);
        await LocalFiles.EnsureDownloadedAsync(p, ct).ConfigureAwait(false);
        var size = File.Exists(p) ? new FileInfo(p).Length : 0;
        progress?.Invoke(size, size);
        return (p, false);
    }

    public Task StoreAsync(string rel, string file, DateTimeOffset mtime, Action<long, long>? progress, CancellationToken ct) => Task.Run(() =>
    {
        SafetyPolicy.CheckLocalWrite(Root);
        var dest = PathOf(rel);
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        LocalFiles.AtomicCopy(file, dest);
        try { File.SetLastWriteTimeUtc(dest, mtime.UtcDateTime); } catch { }
        lock (_lock) _actual[rel] = Path.GetRelativePath(Root, dest).Replace(Path.DirectorySeparatorChar, '/');
    }, ct);

    public Task MakeDirAsync(string rel, CancellationToken ct)
    {
        SafetyPolicy.CheckLocalWrite(Root);
        var p = PathOf(rel);
        Directory.CreateDirectory(p);
        lock (_lock) _actual[rel] = Path.GetRelativePath(Root, p).Replace(Path.DirectorySeparatorChar, '/');
        return Task.CompletedTask;
    }

    public Task TrashAsync(string rel, CancellationToken ct)
    {
        SafetyPolicy.CheckLocalWrite(Root);
        LocalFiles.SafeTrash(PathOf(rel), Root);
        return Task.CompletedTask;
    }
}

/// <summary>A folder in iCloud Drive (any backend).</summary>
public sealed class DriveSide : ISyncSide
{
    readonly IDriveBackend _drive;
    readonly string _rootID;
    readonly IReadOnlyList<string> _excludes;
    public string Label { get; }
    readonly object _lock = new();
    Dictionary<string, DriveNode> _nodes = [];

    public DriveSide(IDriveBackend drive, string rootID, string label, IReadOnlyList<string> excludes)
    {
        _drive = drive; _rootID = rootID; Label = label; _excludes = excludes;
    }

    public long? FreeSpace => null;

    public async Task<Dictionary<string, SideEntry>> ScanAsync(Action<int>? progress, CancellationToken ct)
    {
        var all = await _drive.WalkAsync(_rootID, progress, ct).ConfigureAwait(false);
        var output = new Dictionary<string, SideEntry>();
        var map = new Dictionary<string, DriveNode>();
        foreach (var (rel, node) in all)
        {
            if (Glob.Excluded(rel, _excludes)) continue;
            output[rel] = new SideEntry(node.Size, (node.Modified ?? DateTimeOffset.UnixEpoch).ToUnixTimeMilliseconds() / 1000.0, node.IsFolder);
            map[rel] = node;
        }
        lock (_lock) _nodes = map;
        return output;
    }

    DriveNode? Node(string rel) { lock (_lock) return _nodes.TryGetValue(rel, out var n) ? n : null; }

    async Task<string> FolderID(string rel, CancellationToken ct)
    {
        if (rel.Length == 0 || rel == ".") return _rootID;
        if (Node(rel) is { IsFolder: true } n) return n.Id;
        await MakeDirAsync(rel, ct).ConfigureAwait(false);
        return Node(rel)?.Id ?? throw SyncException.Unavailable($"Couldn’t create folder {rel} in iCloud Drive.");
    }

    static (string Parent, string Name) Split(string rel)
    {
        var i = rel.LastIndexOf('/');
        return i < 0 ? ("", rel) : (rel[..i], rel[(i + 1)..]);
    }

    public async Task<(string Path, bool IsTemporary)> FetchAsync(string rel, Action<long, long>? progress, CancellationToken ct)
    {
        var n = Node(rel) ?? throw ICloudException.NotFound();
        var tmp = Paths.TempFile(n.Name);
        await _drive.DownloadAsync(n, tmp, progress, ct).ConfigureAwait(false);
        return (tmp, true);
    }

    public async Task StoreAsync(string rel, string file, DateTimeOffset mtime, Action<long, long>? progress, CancellationToken ct)
    {
        var (parent, name) = Split(rel);
        var fid = await FolderID(parent, ct).ConfigureAwait(false);
        var existing = Node(rel);
        var n = await _drive.SafeReplaceAsync(file, name, fid, existing is { IsFolder: false } ? existing : null, mtime, progress, ct).ConfigureAwait(false);
        lock (_lock) _nodes[rel] = n;
    }

    public async Task MakeDirAsync(string rel, CancellationToken ct)
    {
        if (Node(rel) is { IsFolder: true }) return;
        var (parent, name) = Split(rel);
        var pid = await FolderID(parent, ct).ConfigureAwait(false);
        try
        {
            var n = await _drive.CreateFolderAsync(name, pid, ct).ConfigureAwait(false);
            lock (_lock) _nodes[rel] = n;
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            // Someone else may have created it meanwhile.
            List<DriveNode>? listed = null;
            try { listed = await _drive.ListAsync(pid, ct).ConfigureAwait(false); } catch { }
            if (listed?.FirstOrDefault(x => x.Name == name && x.IsFolder) is { } found) { lock (_lock) _nodes[rel] = found; }
            else throw;
        }
    }

    public async Task TrashAsync(string rel, CancellationToken ct)
    {
        if (Node(rel) is not { } n) return;
        await _drive.TrashAsync([n], ct).ConfigureAwait(false);
        lock (_lock) _nodes.Remove(rel);
    }
}
