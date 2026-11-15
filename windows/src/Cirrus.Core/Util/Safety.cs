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
                if (Environment.GetEnvironmentVariable(env) is { Length: > 0 } o) roots.Add(o);
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrEmpty(home) && OperatingSystem.IsWindows())
            {
                roots.Add(Path.Combine(home, "iCloudDrive"));
                roots.Add(Path.Combine(home, "Pictures", "iCloud Photos"));
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

    public static void CheckLocalWrite(string path) { if (IsICloudPath(path)) CheckWrite(); }
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
        await drive.TrashAsync([existing], ct).ConfigureAwait(false);
        return await drive.RenameAsync(uploaded, name, ct).ConfigureAwait(false);
    }
}
