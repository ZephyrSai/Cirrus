namespace Cirrus.Core;

/// <summary>Size limits Cirrus enforces before queueing work (port of Preflight.swift's Limits).</summary>
public static class Limits
{
    /// <summary>Apple: iCloud Drive stores files of 50 GB or less (and within your storage plan).</summary>
    public const long ICloudDriveMax = 50_000_000_000;
    /// <summary>Community-reported: uploads through iCloud.com (what web sign-in uses) fail above 10 GB.</summary>
    public const long ICloudWebSoft = 10_000_000_000;
    /// <summary>Community-reported: iCloud.com has refused Photos video uploads over ~100 MB for some accounts.</summary>
    public const long PhotosWebVideoNote = 100_000_000;
    public const long Fat32Max = 4_294_967_295;
    public const int ConfirmFiles = 1000;
    public const long ConfirmBytes = 10_000_000_000;
}

/// <summary>Where a copy, upload or import is going.</summary>
public abstract record Destination
{
    public sealed record Local(string Dir) : Destination;
    public sealed record Drive(Account Account, string FolderID) : Destination;
    public sealed record Photos(Account Account, PhotoLibraryRef Library, PhotoAlbum? Album) : Destination;
}

/// <summary>Something shown in Cirrus that may be downloaded (used for download preflight).</summary>
public sealed record TransferItem(string Name, long? Size, bool IsContainer, DriveNode? Node = null, IDriveBackend? Drive = null,
    PhotoAsset? Photo = null, PhotoAlbum? Album = null);

public sealed record BlockedItem(string Name, long Size, string Reason);

public enum PreflightSeverity { Info, Warning, Critical }

public sealed class PreflightResult
{
    public long Bytes { get; set; }
    public int Files { get; set; }
    public List<BlockedItem> Blocked { get; } = [];
    public List<string> Cautions { get; } = [];
    public long? Available { get; set; }
    public string AvailableLabel { get; set; } = "";
    public long Shortfall => Available is long a ? Math.Max(0, Bytes - a) : 0;
    public HashSet<string> BlockedNames => Blocked.Select(b => b.Name).ToHashSet();
    public bool AllBlocked => Blocked.Count > 0 && Blocked.Count >= Files;
    public bool IsBig => Files >= Limits.ConfirmFiles || Bytes >= Limits.ConfirmBytes;
    /// <summary>Ask the user first when something is off or the batch is large.</summary>
    public bool NeedsConfirmation => Shortfall > 0 || Blocked.Count > 0 || Cautions.Count > 0 || IsBig;

    public sealed record Prompt(PreflightSeverity Severity, string Title, string Body, string[] Buttons, int ProceedButton);

    /// <summary>The dialog to show: title, body and buttons (ProceedButton is -1 when nothing can proceed).</summary>
    public Prompt Describe(string verb, string destination)
    {
        PreflightSeverity sev = PreflightSeverity.Info;
        string title;
        if (Shortfall > 0)
        {
            sev = PreflightSeverity.Critical;
            title = AvailableLabel == "in iCloud" ? "Not enough iCloud storage" : $"Not enough space {AvailableLabel}";
        }
        else if (AllBlocked)
        {
            sev = PreflightSeverity.Warning;
            title = Files == 1 ? $"This item can’t be copied to {destination}" : $"None of these items can be copied to {destination}";
        }
        else title = $"{verb} {Files:N0} item{(Files == 1 ? "" : "s")} ({Bytes.ByteString()}) to {destination}?";
        var lines = new List<string>();
        if (Available is long avail)
            lines.Add($"Needs {Bytes.ByteString()}; {avail.ByteString()} available {AvailableLabel}" + (Shortfall > 0 ? $" — {Shortfall.ByteString()} short." : "."));
        if (Blocked.Count > 0)
        {
            var names = string.Join("\n", Blocked.Take(5).Select(b => $"• {b.Name} ({b.Size.ByteString()}) — {b.Reason}"));
            lines.Add("These will be skipped:\n" + names + (Blocked.Count > 5 ? $"\n• …and {Blocked.Count - 5} more" : ""));
        }
        lines.AddRange(Cautions);
        var body = string.Join("\n\n", lines);
        if (AllBlocked) return new Prompt(sev, title, body, ["OK"], -1);
        if (Shortfall > 0) return new Prompt(sev, title, body, ["Cancel", $"{verb} Anyway"], 1);
        return new Prompt(sev, title, body, [verb, "Cancel"], 0);
    }
}

/// <summary>Size checks before a transfer is queued: per-file limits, free space (minus queued work) and big-batch confirmation.</summary>
public sealed class Preflight
{
    public static Preflight Default { get; set; } = new();

    readonly Dictionary<string, (DateTimeOffset At, StorageUsage Usage)> _storageCache = [];
    readonly object _lock = new();

    public TransferManager Transfers { get; init; } = TransferManager.Shared;
    /// <summary>Free bytes on the volume holding a folder (before subtracting queued work).</summary>
    public Func<string, long?> VolumeFree { get; init; } = VolumeInfo.FreeSpace;
    public Func<string, bool> IsFat { get; init; } = d => VolumeInfo.Info(d)?.IsFat32 ?? false;
    public Func<string, string> VolumeName { get; init; } = d => VolumeInfo.Info(d)?.DisplayName ?? Path.GetFileName(d);
    public Func<string, bool> IsNativeICloud { get; init; } = SafetyPolicy.IsICloudPath;
    public Func<Account, Task<StorageUsage?>> Storage { get; init; } = a => a.StorageUsageAsync();

    public static string VolumeKey(string dir) => "vol:" + (VolumeInfo.Info(dir)?.Root ?? Path.GetPathRoot(Path.GetFullPath(dir)) ?? "/").ToLowerInvariant();
    public static string ICloudKey(Account a) => "icloud:" + a.Id;

    /// <summary>The largest file a drive account takes, and how a blocked item is explained.</summary>
    public static (long? Max, string Reason) DriveLimit(Account a)
    {
        if (a.Kind != AccountKind.Cloud) return (Limits.ICloudDriveMax, "larger than iCloud Drive’s 50 GB limit");
        var p = a.Provider!.Value;
        return p.MaxFileSize() is long m ? (m, $"larger than {p.DisplayName()}’s {m.ByteString()} limit") : (null, "");
    }

    /// <summary>"in iCloud", "in OneDrive"…: where an upload's free space was measured.</summary>
    public static string SpaceLabel(Account a) => a.IsICloud ? "in iCloud" : "in " + a.DriveTitle;

    /// <summary>Free storage for an iCloud web account or another cloud, minus uploads already queued to it.</summary>
    public async Task<long?> ICloudFree(Account acct)
    {
        if (acct.Kind is not (AccountKind.Web or AccountKind.Cloud)) return null;
        StorageUsage? usage = null;
        lock (_lock)
            if (_storageCache.TryGetValue(acct.Id, out var c) && DateTimeOffset.UtcNow - c.At < TimeSpan.FromSeconds(120)) usage = c.Usage;
        if (usage is null && await Storage(acct).ConfigureAwait(false) is { } u)
        {
            lock (_lock) _storageCache[acct.Id] = (DateTimeOffset.UtcNow, u);
            usage = u;
        }
        if (usage is not { Total: > 0 } us) return null;
        return Math.Max(0, us.Available - Transfers.PendingBytes(ICloudKey(acct)));
    }

    public long? LocalFree(string dir) => VolumeFree(dir) is long f ? Math.Max(0, f - Transfers.PendingBytes(VolumeKey(dir))) : null;

    public static bool SameVolume(string a, string b)
    {
        try
        {
            var ra = VolumeInfo.Info(a)?.Root; var rb = VolumeInfo.Info(b)?.Root;
            return ra is not null && string.Equals(ra, rb, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    /// <summary>Recursively sizes local files/folders (off the UI thread).</summary>
    public static Task<List<(string Path, long Size, bool IsTopLevel)>> Scan(IEnumerable<string> paths, CancellationToken ct = default) => Task.Run(() =>
    {
        var output = new List<(string, long, bool)>();
        foreach (var u in paths)
        {
            if (Directory.Exists(u))
            {
                int n = 0;
                foreach (var f in new DirectoryInfo(u).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = 0 }))
                {
                    if (n++ >= 500_000) break;
                    ct.ThrowIfCancellationRequested();
                    output.Add((f.FullName, f.Length, false));
                }
            }
            else if (File.Exists(u)) output.Add((u, new FileInfo(u).Length, true));
        }
        return output;
    }, ct);

    public async Task<PreflightResult> CheckUpload(IReadOnlyList<string> paths, Destination dest, bool move, CancellationToken ct = default)
    {
        var r = new PreflightResult();
        var files = await Scan(paths, ct).ConfigureAwait(false);
        r.Files = files.Count;
        void Block((string Path, long Size, bool IsTopLevel) f, string reason) =>
            r.Blocked.Add(new BlockedItem(System.IO.Path.GetFileName(f.Path), f.Size,
                reason + (f.IsTopLevel ? "" : $" (inside “{System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(f.Path))}”)")));
        switch (dest)
        {
            case Destination.Local l:
                var sameVolume = paths.All(p => SameVolume(p, l.Dir));
                r.Bytes = move && sameVolume ? 0 : files.Sum(f => f.Size);
                r.Available = LocalFree(l.Dir);
                r.AvailableLabel = $"on “{VolumeName(l.Dir)}”";
                if (IsFat(l.Dir)) foreach (var f in files.Where(f => f.Size >= Limits.Fat32Max)) Block(f, "over 4 GB, which this drive’s FAT32 format can’t store");
                if (IsNativeICloud(l.Dir))
                {
                    foreach (var f in files.Where(f => f.Size > Limits.ICloudDriveMax)) Block(f, "larger than iCloud Drive’s 50 GB limit");
                    r.Cautions.Add("Items in iCloud Drive count toward your iCloud storage plan; iCloud for Windows uploads them in the background.");
                }
                break;
            case Destination.Drive d:
                r.Bytes = files.Sum(f => f.Size);
                r.Available = await ICloudFree(d.Account).ConfigureAwait(false);
                r.AvailableLabel = SpaceLabel(d.Account);
                var (max, reason) = DriveLimit(d.Account);
                if (max is long mx) foreach (var f in files.Where(f => f.Size > mx)) Block(f, reason);
                var risky = d.Account.IsICloud ? files.Where(f => f.Size > Limits.ICloudWebSoft && f.Size <= Limits.ICloudDriveMax).ToList() : [];
                if (risky.Count > 0)
                    r.Cautions.Add((risky.Count == 1 ? $"“{System.IO.Path.GetFileName(risky[0].Path)}” is" : $"{risky.Count} files are") +
                        " over 10 GB. iCloud.com has been reported to refuse web uploads that large; Cirrus will try, and a failure will show in Transfers.");
                break;
            case Destination.Photos p:
                var media = files.Where(f => PhotoFormats.IsImportable(f.Path)).ToList();
                r.Bytes = media.Sum(f => f.Size);
                var skipped = files.Count - media.Count;
                if (skipped > 0) r.Cautions.Add($"{skipped} item{(skipped == 1 ? " isn’t a photo or video" : "s aren’t photos or videos")} and will be skipped.");
                r.Files = media.Count;
                if (p.Account.Kind == AccountKind.Cloud)
                {
                    r.Available = await ICloudFree(p.Account).ConfigureAwait(false);
                    r.AvailableLabel = SpaceLabel(p.Account);
                }
                if (p.Account.Kind == AccountKind.Web)
                {
                    r.Available = await ICloudFree(p.Account).ConfigureAwait(false);
                    r.AvailableLabel = "in iCloud";
                    var bigVideos = media.Count(f => System.IO.Path.GetExtension(f.Path).ToLowerInvariant() is ".mov" or ".mp4" or ".m4v" && f.Size > Limits.PhotosWebVideoNote);
                    if (bigVideos > 0)
                        r.Cautions.Add($"{bigVideos} video{(bigVideos == 1 ? " is" : "s are")} over 100 MB. iCloud.com has refused videos that size for some accounts; if it does, put them in iCloud Drive instead.");
                }
                break;
        }
        return r;
    }

    public async Task<PreflightResult> CheckDownload(IReadOnlyList<TransferItem> items, string dir, bool exportLive, bool exportEdited, CancellationToken ct = default)
    {
        var r = new PreflightResult { Available = LocalFree(dir), AvailableLabel = $"on “{VolumeName(dir)}”" };
        var fat = IsFat(dir);
        const string fatReason = "over 4 GB, which this drive’s FAT32 format can’t store";
        foreach (var item in items)
        {
            var size = item.Size ?? 0;
            if (item.Photo is { } p) size = p.ExportSize(exportLive, exportEdited, false);
            if (item.Node is { IsFolder: true } n && item.Drive is { } drive)
            {
                List<(string Path, DriveNode Node)>? walked = null;
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(15));
                try { walked = await drive.WalkAsync(n.Id, null, cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
                catch (Exception) { }
                if (walked is not null)
                {
                    size = walked.Sum(w => w.Node.Size);
                    r.Files += walked.Count(w => !w.Node.IsFolder);
                    if (fat) foreach (var w in walked.Where(w => w.Node.Size >= Limits.Fat32Max)) r.Blocked.Add(new BlockedItem(w.Node.Name, w.Node.Size, fatReason));
                }
                else r.Cautions.Add($"Couldn’t measure “{n.Name}” in time; its size isn’t included.");
            }
            else if (item.Album is { Count: int c } a) r.Cautions.Add($"“{a.Name}” has {c} items; its size is estimated as they download.");
            else r.Files++;
            if (fat && size >= Limits.Fat32Max && !item.IsContainer) r.Blocked.Add(new BlockedItem(item.Name, size, fatReason));
            r.Bytes += size;
        }
        return r;
    }

    public void ForgetStorage(string accountID) { lock (_lock) _storageCache.Remove(accountID); }
}
