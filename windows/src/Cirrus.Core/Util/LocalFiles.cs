using System.Globalization;
using Microsoft.Win32;

namespace Cirrus.Core;

/// <summary>Local file helpers. Nothing here ever deletes permanently.</summary>
public static class LocalFiles
{
    // Cloud Files API attributes used by iCloud for Windows placeholders.
    const FileAttributes Pinned = (FileAttributes)0x00080000;
    const FileAttributes Unpinned = (FileAttributes)0x00100000;
    const FileAttributes RecallOnOpen = (FileAttributes)0x00040000;
    const FileAttributes RecallOnDataAccess = (FileAttributes)0x00400000;

    public enum CloudState { NotCloud, CloudOnly, Downloaded, Pinned }

    /// <summary>State of an iCloud for Windows file (placeholder or local copy).</summary>
    public static CloudState GetCloudState(string path)
    {
        try
        {
            var a = File.GetAttributes(path);
            if ((a & Pinned) != 0) return CloudState.Pinned;
            if ((a & (RecallOnDataAccess | RecallOnOpen | FileAttributes.Offline)) != 0) return CloudState.CloudOnly;
            return SafetyPolicy.IsICloudPath(path) ? CloudState.Downloaded : CloudState.NotCloud;
        }
        catch { return CloudState.NotCloud; }
    }

    /// <summary>Like Explorer's "Always keep on this device" (iCloud for Windows then downloads it).</summary>
    public static void Pin(string path)
    {
        var a = File.GetAttributes(path);
        File.SetAttributes(path, (a & ~Unpinned) | Pinned);
    }

    /// <summary>Like Explorer's "Free up space": keeps the file in iCloud, removes the local copy.</summary>
    public static void Unpin(string path)
    {
        var a = File.GetAttributes(path);
        File.SetAttributes(path, (a & ~Pinned) | Unpinned);
    }

    /// <summary>
    /// Materialise an iCloud for Windows placeholder; plain files return immediately.
    /// Reading through the file makes the cloud filter download it.
    /// </summary>
    public static async Task EnsureDownloadedAsync(string path, CancellationToken ct = default)
    {
        if (!File.Exists(path)) return;
        if (GetCloudState(path) != CloudState.CloudOnly) return;
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, useAsync: true);
        var buf = new byte[1 << 20];
        while (await fs.ReadAsync(buf, ct).ConfigureAwait(false) > 0) { }
    }

    /// <summary>Copy via a temp file in the destination folder, then swap in (never leaves half files).</summary>
    public static void AtomicCopy(string src, string dest)
    {
        var dir = Path.GetDirectoryName(dest)!;
        Directory.CreateDirectory(dir);
        var tmp = Path.Combine(dir, ".cirrus-" + Guid.NewGuid().ToString("N")[..8] + "-" + Path.GetFileName(dest));
        try
        {
            File.Copy(src, tmp, overwrite: true);
            File.Move(tmp, dest, overwrite: true);
        }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }   // only our own temp file
    }

    /// <summary>Copies a file or folder tree (folders recursively, files atomically).</summary>
    public static void CopyItem(string src, string dest)
    {
        if (Directory.Exists(src))
        {
            Directory.CreateDirectory(dest);
            foreach (var e in new DirectoryInfo(src).EnumerateFileSystemInfos())
            {
                if (e.LinkTarget is not null) continue;
                CopyItem(e.FullName, Path.Combine(dest, e.Name));
            }
        }
        else
        {
            if (File.Exists(dest)) throw new IOException($"“{Path.GetFileName(dest)}” already exists.");
            AtomicCopy(src, dest);
            try { File.SetLastWriteTimeUtc(dest, File.GetLastWriteTimeUtc(src)); } catch { }
        }
    }

    public static void MoveItem(string src, string dest)
    {
        if (Directory.Exists(src)) Directory.Move(src, dest); else File.Move(src, dest);
    }

    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    /// <summary>Who decides how removals happen. Swappable for tests.</summary>
    public static IRecycler Recycler { get; set; } = OperatingSystem.IsWindows() ? new WindowsRecycleBin() : new QuarantineRecycler();

    /// <summary>
    /// Move to the Recycle Bin; where Windows would delete permanently instead (USB sticks, network shares,
    /// items bigger than the bin, bins set to "don't move files to the Recycle Bin") move it into
    /// &lt;root&gt;\.cirrus\Removed\&lt;date&gt;\ instead. Never deletes.
    /// </summary>
    public static string? SafeTrash(string path, string? root)
    {
        if (!Exists(path)) return null;
        if (Recycler.TryRecycle(path)) return null;      // RemovalDeclinedException propagates: nothing is moved
        return Quarantine(path, root);
    }

    /// <summary>Moves an item into &lt;root or parent&gt;\.cirrus\Removed\&lt;date&gt;\ (same volume, so it's a rename).</summary>
    public static string Quarantine(string path, string? root)
    {
        var baseDir = root ?? Path.GetDirectoryName(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar))!;
        var bin = Path.Combine(baseDir, ".cirrus", "Removed", DateTime.Now.ToString("yyyy-MM-dd HH.mm", CultureInfo.InvariantCulture));
        Directory.CreateDirectory(bin);
        var name = Path.GetFileName(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar));
        var dest = Path.Combine(bin, name);
        if (Exists(dest)) dest = Path.Combine(bin, Guid.NewGuid().ToString("N")[..6] + "-" + name);
        MoveItem(path, dest);
        Log.Status("moved a removed item into .cirrus/Removed (no Recycle Bin on that volume)");
        return dest;
    }

    /// <summary>Bytes in a file or folder tree; long.MaxValue when any part can't be read (so it's never under-counted).</summary>
    public static long TreeSize(string path)
    {
        if (File.Exists(path)) return new FileInfo(path).Length;
        long total = 0;
        try
        {
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = 0 }))
                total += f.Length;
        }
        catch { return long.MaxValue; }
        return total;
    }
}

/// <summary>The user declined a removal in Windows' own dialog; the item was left in place.</summary>
public sealed class RemovalDeclinedException(string name) : IOException($"“{name}” was left in place (removal declined).") { }

public interface IRecycler
{
    /// <summary>Sends an item to the platform's recoverable trash. Returns false when that isn't guaranteed to be recoverable.</summary>
    bool TryRecycle(string path);
}

/// <summary>Non-Windows (tests) and fallback: never recycles, so SafeTrash always quarantines.</summary>
public sealed class QuarantineRecycler : IRecycler
{
    public bool TryRecycle(string path) => false;
}

/// <summary>
/// Windows Recycle Bin via Microsoft.VisualBasic.FileIO.FileSystem (RecycleOption.SendToRecycleBin).
/// Windows silently deletes permanently when an item can't be recycled, so this first checks that the
/// volume has a Recycle Bin, that it isn't set to "remove files immediately", and that the item fits.
/// </summary>
public sealed class WindowsRecycleBin : IRecycler
{
    public bool TryRecycle(string path)
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            var full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\", StringComparison.Ordinal)) return false;          // network share: no Recycle Bin
            var vol = VolumeInfo.Info(full);
            if (vol is null || !vol.IsFixed) return false;                               // USB sticks and card readers: none
            var size = LocalFiles.TreeSize(full);
            if (!BinAccepts(vol.Root, size, vol.Total)) return false;
            if (full.Length >= 248) return false;   // the shell can't recycle long paths reliably
            // AllDialogs = Explorer's own behaviour: no prompt for a normal recycle (unless the user turned on delete
            // confirmations), but Windows asks before anything would be deleted permanently instead of recycled.
            if (Directory.Exists(full))
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(full, Microsoft.VisualBasic.FileIO.UIOption.AllDialogs,
                    Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin, Microsoft.VisualBasic.FileIO.UICancelOption.ThrowException);
            else
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(full, Microsoft.VisualBasic.FileIO.UIOption.AllDialogs,
                    Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin, Microsoft.VisualBasic.FileIO.UICancelOption.ThrowException);
            return true;
        }
        catch (OperationCanceledException)
        {
            // The user said no in Windows' dialog: leave the item exactly where it is.
            throw new RemovalDeclinedException(Path.GetFileName(path));
        }
        catch (Exception e)
        {
            Log.Status("recycle failed, will move aside instead: " + e.GetType().Name);
            return false;
        }
    }

    /// <summary>Reads HKCU\…\Explorer\BitBucket\Volume\{GUID} (MaxCapacity in MB, NukeOnDelete).</summary>
    internal static bool BinAccepts(string root, long size, long volumeTotal)
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            {
                using var policy = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Policies\Explorer");
                if (policy?.GetValue("NoRecycleFiles") is int nr && nr != 0) return false;   // "don't move files to the Recycle Bin" policy
            }
            var guid = VolumeInfo.Win.VolumeGuid(root);
            if (guid is null) return false;
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\" + guid);
            if (key is null)
            {
                // No per-volume settings yet: Windows' default bin is roughly 5 % of the volume. Stay well inside it.
                return size < volumeTotal / 25;
            }
            if (key.GetValue("NukeOnDelete") is int nuke && nuke != 0) return false;
            if (key.GetValue("MaxCapacity") is int mb && mb > 0) return size < (long)mb * 1024 * 1024 * 9 / 10;
            return size < volumeTotal / 25;
        }
        catch { return false; }
    }
}

/// <summary>Case-insensitive fnmatch-style wildcards (* ? [abc]) for exclude lists.</summary>
public static class Glob
{
    public static bool Matches(string name, string pattern) => Match(name, 0, pattern, 0);

    static bool Match(string s, int si, string p, int pi)
    {
        while (pi < p.Length)
        {
            var c = p[pi];
            if (c == '*')
            {
                while (pi < p.Length && p[pi] == '*') pi++;
                if (pi == p.Length) return true;
                for (int k = si; k <= s.Length; k++) if (Match(s, k, p, pi)) return true;
                return false;
            }
            if (si >= s.Length) return false;
            if (c == '?') { si++; pi++; continue; }
            if (c == '[')
            {
                var end = p.IndexOf(']', pi + 1);
                if (end > pi)
                {
                    var set = p[(pi + 1)..end];
                    bool neg = set.StartsWith('!') || set.StartsWith('^');
                    if (neg) set = set[1..];
                    bool hit = false;
                    for (int k = 0; k < set.Length; k++)
                    {
                        if (k + 2 < set.Length && set[k + 1] == '-') { if (char.ToLowerInvariant(s[si]) >= char.ToLowerInvariant(set[k]) && char.ToLowerInvariant(s[si]) <= char.ToLowerInvariant(set[k + 2])) hit = true; k += 2; }
                        else if (char.ToLowerInvariant(set[k]) == char.ToLowerInvariant(s[si])) hit = true;
                    }
                    if (hit == neg) return false;
                    si++; pi = end + 1; continue;
                }
            }
            if (char.ToLowerInvariant(c) != char.ToLowerInvariant(s[si])) return false;
            si++; pi++;
        }
        return si == s.Length;
    }

    /// <summary>True when any path component matches any pattern.</summary>
    public static bool Excluded(string rel, IReadOnlyList<string> patterns)
    {
        if (patterns.Count == 0) return false;
        foreach (var comp in rel.Split('/', StringSplitOptions.RemoveEmptyEntries))
            foreach (var pat in patterns)
                if (Matches(comp, pat)) return true;
        return false;
    }
}

/// <summary>Finder-like ordering: case-insensitive, numbers compared by value ("file 2" &lt; "file 10").</summary>
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y)) return 0;
        if (x is null) return -1;
        if (y is null) return 1;
        int i = 0, j = 0;
        while (i < x.Length && j < y.Length)
        {
            if (char.IsDigit(x[i]) && char.IsDigit(y[j]))
            {
                int si = i, sj = j;
                while (i < x.Length && char.IsDigit(x[i])) i++;
                while (j < y.Length && char.IsDigit(y[j])) j++;
                var a = x[si..i].TrimStart('0'); var b = y[sj..j].TrimStart('0');
                if (a.Length != b.Length) return a.Length.CompareTo(b.Length);
                var c = string.CompareOrdinal(a, b);
                if (c != 0) return c;
                continue;
            }
            var r = string.Compare(x, i, y, j, 1, CultureInfo.CurrentCulture, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace);
            if (r != 0) return r;
            i++; j++;
        }
        return (x.Length - i).CompareTo(y.Length - j);
    }
}
