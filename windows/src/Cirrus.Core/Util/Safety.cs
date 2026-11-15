namespace Cirrus.Core;

/// <summary>
/// Global safety switches enforced inside the engine (not just the UI), so no code path can bypass them.
/// </summary>
public static class SafetyPolicy
{
    static volatile bool _readOnly;

    /// <summary>
    /// When on, nothing in iCloud (Drive, Photos, or the iCloud for Windows folders) is changed:
    /// browsing, downloading, exporting and backing up still work. TESTER builds start with it on.
    /// </summary>
    public static bool ReadOnlyICloud { get => _readOnly; set => _readOnly = value; }

    /// <summary>Throws when iCloud writes are blocked.</summary>
    public static void CheckWrite() { if (_readOnly) throw new ReadOnlyException(); }

    /// <summary>iCloud for Windows keeps iCloud Drive and iCloud Photos in local folders; those are iCloud too.</summary>
    public static IReadOnlyList<string> NativeICloudRoots
    {
        get
        {
            var roots = new List<string>();
            foreach (var env in new[] { "CIRRUS_NATIVE_DRIVE", "CIRRUS_NATIVE_PHOTOS" })
                if (Env.Get(env) is { } o) roots.Add(o);
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrEmpty(home) && OperatingSystem.IsWindows())
            {
                roots.Add(Path.Combine(home, "iCloudDrive"));
                roots.Add(Path.Combine(home, "Pictures", "iCloud Photos"));
                // Pictures may be redirected (OneDrive, another drive): protect the folder Cirrus actually shows.
                if (Environment.GetFolderPath(Environment.SpecialFolder.MyPictures) is { Length: > 0 } pics) roots.Add(Path.Combine(pics, "iCloud Photos"));
            }
            if (ExtraNativeRoot is { Length: > 0 } x) roots.Add(x);
            return roots;
        }
    }

    /// <summary>A user-chosen iCloud Photos folder (Settings) that also counts as iCloud.</summary>
    public static string? ExtraNativeRoot { get; set; }

    public static bool IsICloudPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return false;
        string p;
        try { p = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); } catch { return false; }
        var cmp = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        foreach (var r in NativeICloudRoots)
        {
            string root;
            try { root = Path.GetFullPath(r).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); } catch { continue; }
            if (p.Equals(root, cmp) || p.StartsWith(root + Path.DirectorySeparatorChar, cmp)) return true;
        }
        return false;
    }

    /// <summary>
    /// True when a local path is inside iCloud or contains an iCloud folder (removing, moving or renaming
    /// C:\Users\me\Pictures would take "iCloud Photos" with it).
    /// </summary>
    public static bool TouchesICloud(string path)
    {
        if (IsICloudPath(path)) return true;
        string p;
        try { p = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar; } catch { return false; }
        var cmp = OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        foreach (var r in NativeICloudRoots)
        {
            try { if (Path.GetFullPath(r).StartsWith(p, cmp)) return true; } catch { }
        }
        return false;
    }

    /// <summary>Throws in read-only mode when a local write, move, rename or removal would reach iCloud.</summary>
    public static void CheckLocalWrite(string path) { if (_readOnly && TouchesICloud(path)) throw new ReadOnlyException(); }
}

public sealed class ReadOnlyException : InvalidOperationException
{
    public ReadOnlyException() : base(
        "Read-only mode is on, so Cirrus won’t change anything in iCloud. Turn it off in Settings › Safety if you want to upload, rename or delete.") { }
}

public static class DriveSafetyExtensions
{
    /// <summary>
    /// Replace a file without a window where only the old copy exists in Recently Deleted:
    /// upload under a temporary name, then trash the old file, then rename the new one into place.
    /// </summary>
    public static async Task<DriveNode> SafeReplaceAsync(this IDriveBackend drive, string file, string name, string folderID, DriveNode? existing,
        DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (existing is null || existing.IsFolder)
            return await drive.UploadAsync(file, name, folderID, modified, progress, ct).ConfigureAwait(false);
        var temp = ".cirrus-upload-" + Guid.NewGuid().ToString("N")[..8] + "-" + name;
        var uploaded = await drive.UploadAsync(file, temp, folderID, modified, progress, ct).ConfigureAwait(false);
        // Once the new copy is in iCloud, finish the swap even if the run is being cancelled: stopping here would leave a
        // hidden full-size temporary copy behind.
        await drive.TrashAsync([existing], CancellationToken.None).ConfigureAwait(false);
        return await drive.RenameAsync(uploaded, name, CancellationToken.None).ConfigureAwait(false);
    }
}
