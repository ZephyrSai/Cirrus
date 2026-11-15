using System.Text.Json.Serialization;

namespace Cirrus.Core;

/// <summary>What to bring from Google into iCloud.</summary>
public sealed class ImportOptions
{
    public bool IncludeDrive { get; set; } = true;
    public bool IncludePhotos { get; set; } = true;
    public GoogleDocFormat DocFormat { get; set; } = GoogleDocFormat.Office;
    /// <summary>Live Photo and motion-photo video parts.</summary>
    public bool IncludeLive { get; set; } = true;
    public bool IncludeEdited { get; set; }
    public bool Albums { get; set; } = true;
    public bool Favorites { get; set; } = true;
    /// <summary>Copy files again when they changed in Google (the old iCloud copy goes to the Recycle Bin / Recently Deleted).</summary>
    public bool UpdateChanged { get; set; } = true;
    public string FolderName { get; set; } = "From Google Drive";
    public string PhotosAlbumName { get; set; } = "From Google Photos";
    public int Concurrency { get; set; } = 3;
}

// MARK: - Manifest

public sealed class ImportManifest
{
    public sealed record DriveFile(string Rel, string Version, long Size);
    public sealed record Photo(string Name, long Size);
    public sealed class Album { public string Id { get; set; } = ""; public string Title { get; set; } = ""; public HashSet<string> Added { get; set; } = []; }

    public Dictionary<string, DriveFile> Files { get; set; } = [];   // Google file id → its copy in iCloud Drive
    public Dictionary<string, Photo> Photos { get; set; } = [];      // item key → the file iCloud Photos received
    public Dictionary<string, Album> Albums { get; set; } = [];      // Google album title → iCloud album
    public Album? Provenance { get; set; }                           // "From Google Photos"
    public HashSet<string> Favorited { get; set; } = [];
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "op")]
[JsonDerivedType(typeof(File), "file")]
[JsonDerivedType(typeof(Photo), "photo")]
[JsonDerivedType(typeof(Album), "album")]
[JsonDerivedType(typeof(AlbumAdded), "albumAdded")]
[JsonDerivedType(typeof(Provenance), "provenance")]
[JsonDerivedType(typeof(Favorited), "favorited")]
abstract record ImportOp : IManifestOp<ImportManifest>
{
    public abstract void Apply(ImportManifest m);

    public sealed record File(string Id, ImportManifest.DriveFile Value) : ImportOp { public override void Apply(ImportManifest m) => m.Files[Id] = Value; }
    public sealed record Photo(string Key, ImportManifest.Photo Value) : ImportOp { public override void Apply(ImportManifest m) => m.Photos[Key] = Value; }
    public sealed record Album(string Title, string Id) : ImportOp
    {
        public override void Apply(ImportManifest m) => m.Albums[Title] = new ImportManifest.Album { Id = Id, Title = Title };
    }
    public sealed record AlbumAdded(string Title, List<string> Keys) : ImportOp
    {
        public override void Apply(ImportManifest m) { if (m.Albums.TryGetValue(Title, out var a)) a.Added.UnionWith(Keys); }
    }
    public sealed record Provenance(string? Id, string? Title) : ImportOp
    {
        public override void Apply(ImportManifest m) => m.Provenance = Id is null ? null : new ImportManifest.Album { Id = Id, Title = Title ?? "" };
    }
    public sealed record Favorited(List<string> Keys) : ImportOp { public override void Apply(ImportManifest m) => m.Favorited.UnionWith(Keys); }
}

/// <summary>
/// Google → iCloud (port of GoogleImport.swift): My Drive into a "From Google Drive" folder in iCloud Drive (Docs, Sheets
/// and Slides exported as Office files or PDF), and Google Photos — from a Takeout export or the Google Photos picker —
/// into iCloud Photos with their dates, albums and favorites. Only ever adds to iCloud; replaced copies go to the Recycle
/// Bin / Recently Deleted. Read-only mode stops the run before anything is written.
/// </summary>
public sealed class ImportEngine
{
    public sealed record SourceSpec(GoogleApi Api, IReadOnlyList<string> Takeout, IReadOnlyList<GooglePickedItem> Picked);

    /// <param name="IsWeb">Uploads go through iCloud.com (sign-in inside Cirrus), not iCloud for Windows.</param>
    public sealed record TargetSpec(string Key, string Title, IDriveBackend? Drive, string? NativeDriveRoot, IPhotosBackend? Photos,
        Func<Task<StorageUsage?>>? Storage, bool IsWeb);

    /// <param name="Size">null until a Google Doc is exported.</param>
    public sealed record DriveItem(string Id, string Rel, long? Size, GoogleDocTarget? Export, GDriveItem Item);

    public abstract record PhotoSource
    {
        public sealed record FromTakeout(TakeoutItem Item) : PhotoSource;
        public sealed record FromPicker(GooglePickedItem Item) : PhotoSource;
    }

    /// <param name="SizeIsEstimate">The picker doesn't tell sizes: until downloaded, a typical size stands in.</param>
    public sealed record PhotoItem(string Key, PhotoSource Source, string FileName, long Size, DateTimeOffset? Taken, bool IsVideo, string Group,
        List<string> Albums, bool Favorite, bool IsCompanion, bool SizeIsEstimate = false);

    public sealed record AlbumPlan(string Title, List<string> Members);

    public sealed class Evaluation
    {
        public GoogleUser? User { get; set; }
        public StorageUsage? ICloud { get; set; }
        public bool DriveEnabled { get; set; }
        public bool PhotosEnabled { get; set; }
        public bool ReadOnly { get; set; }
        public int DriveFiles { get; set; }
        public long DriveBytes { get; set; }
        public int Docs { get; set; }
        public List<DriveItem> DriveItems { get; set; } = [];
        public List<DriveItem> DrivePending { get; set; } = [];
        public List<string> DriveFolders { get; set; } = [];
        public List<PhotoItem> PhotoItems { get; set; } = [];
        public List<PhotoItem> PhotoPending { get; set; } = [];
        public List<AlbumPlan> Albums { get; set; } = [];
        public int AlbumAddsPending { get; set; }
        public int FavoritesPending { get; set; }
        public int TakeoutParts { get; set; }
        public int TakeoutItems { get; set; }
        public int PickedItems { get; set; }
        public bool SizesEstimated => DrivePending.Any(d => d.Export is not null) || PhotoPending.Any(p => p.SizeIsEstimate);
        public List<MigrationSkipped> Skipped { get; set; } = [];
        public List<string> Warnings { get; set; } = [];
        public long StagingFree { get; set; } = long.MaxValue;
        public long StagingNeeded { get; set; }
        /// <summary>iCloud for Windows target: what this copy writes into that folder must fit on its drive.</summary>
        public long TargetNeeded { get; set; }
        public long TargetFree { get; set; } = long.MaxValue;

        /// <summary>Google Docs have no size until exported; count 2 MB each for the space check.</summary>
        public const long DocEstimate = 2 << 20;
        public long DrivePendingBytes => DrivePending.Sum(d => d.Size ?? DocEstimate);
        public long PhotoPendingBytes => PhotoPending.Sum(p => p.Size);
        public long PendingBytes => DrivePendingBytes + PhotoPendingBytes;
        public long RequiredICloud => PendingBytes + PendingBytes / 100;
        public long? ICloudFree => ICloud is { Total: > 0 } u ? u.Available : null;
        public bool FitsICloud => ICloudFree is not { } f || f >= RequiredICloud;
        public bool FitsStaging => StagingFree >= StagingNeeded;
        public bool FitsTarget => TargetFree >= TargetNeeded;
        public bool Fits => FitsICloud && FitsStaging && FitsTarget && !ReadOnly;
        public bool IsUpToDate => DrivePending.Count == 0 && PhotoPending.Count == 0 && AlbumAddsPending == 0 && FavoritesPending == 0;
    }

    public sealed class Report
    {
        public int DriveCopied { get; set; }
        public int DriveUpdated { get; set; }
        public int DocsExported { get; set; }
        public long DriveBytes { get; set; }
        public int PhotosImported { get; set; }
        public long PhotosBytes { get; set; }
        public int AlbumsCreated { get; set; }
        public int AlbumAdds { get; set; }
        public int FavoritesSet { get; set; }
        public int Unmatched { get; set; }
        public List<MigrationSkipped> Skipped { get; set; } = [];
        public List<string> Failed { get; set; } = [];
        public string? Stopped { get; set; }

        static string S(int n) => n == 1 ? "" : "s";

        public string Summary
        {
            get
            {
                var parts = new List<string>();
                var d = DriveCopied + DriveUpdated;
                if (d > 0) parts.Add($"{d} file{S(d)} to iCloud Drive" + (DocsExported > 0 ? $" ({DocsExported} Google Doc{S(DocsExported)} exported)" : ""));
                if (PhotosImported > 0) parts.Add($"{PhotosImported} photo{S(PhotosImported)} and video{S(PhotosImported)} to iCloud Photos");
                if (AlbumsCreated > 0) parts.Add($"{AlbumsCreated} album{S(AlbumsCreated)} created");
                if (FavoritesSet > 0) parts.Add($"{FavoritesSet} favorite{S(FavoritesSet)} marked");
                var skip = Skipped.Count == 0 ? "" : $"{Skipped.Count} skipped";
                if (parts.Count == 0 && Failed.Count == 0)
                    return (Stopped is null ? "Everything was already in iCloud" : "Nothing was copied") + (skip.Length == 0 ? "" : " — " + skip);
                var bytes = DriveBytes + PhotosBytes;
                var output = new List<string>();
                if (parts.Count > 0) output.Add(string.Join(", ", parts) + (bytes > 0 ? $" ({bytes.ByteString()})" : ""));
                if (Failed.Count > 0) output.Add($"{Failed.Count} failed");
                if (skip.Length > 0) output.Add(skip);
                return string.Join(", ", output);
            }
        }
    }

    /// <summary>Apple: iCloud Drive files up to 50 GB. iCloud.com uploads above ~10 GB have failed for people (same note as Preflight).</summary>
    public const long ICloudDriveMax = 50_000_000_000;
    public const long ICloudWebSoft = 10_000_000_000;

    public SourceSpec Source { get; }
    public TargetSpec Target { get; }
    public ImportOptions Options { get; }
    internal JournalStore<ImportManifest, ImportOp> Store { get; }
    readonly string _staging;
    readonly string _stateDir;
    readonly Func<bool> _isReadOnly;
    readonly Action<string, string> _trash;
    readonly object _statsLock = new();
    /// <summary>Identifies this account pair's runs (one at a time).</summary>
    public string RunKey => Store.BasePath;
    public bool IsRunning => MoveRuns.IsRunning(RunKey);
    /// <summary>Test hook.</summary>
    internal Func<string, long?> FreeSpace { get; set; } = VolumeInfo.FreeSpace;

    internal static string StoreName(string googleID, string icloudKey) => "import-" + MigrationEngine.Hex(googleID + "→" + icloudKey)[..24];

    /// <summary><paramref name="readOnly"/> and <paramref name="trash"/> are injectable for tests (defaults: Settings › Safety, and the Recycle Bin).</summary>
    public ImportEngine(SourceSpec source, TargetSpec target, ImportOptions options, string stateDir, string stagingDir,
        Func<bool>? readOnly = null, Action<string, string>? trash = null)
    {
        Source = source; Target = target; Options = options; _stateDir = stateDir;
        _isReadOnly = readOnly ?? (() => SafetyPolicy.ReadOnlyICloud);
        _trash = trash ?? ((path, root) => LocalFiles.SafeTrash(path, root));
        var name = StoreName(source.Api.AccountID, target.Key);
        Store = JournalStores.Get<ImportManifest, ImportOp>(stateDir, name);
        _staging = Path.Combine(stagingDir, name);   // per pair: runs for other pairs never clear each other's files
    }

    static string Dir(string p) { var i = p.LastIndexOf('/'); return i < 0 ? "" : p[..i]; }
    static string Last(string p) { var i = p.LastIndexOf('/'); return i < 0 ? p : p[(i + 1)..]; }
    static string S(int n) => n == 1 ? "" : "s";
    void Mutate(Report r, Action<Report> f) { lock (_statsLock) f(r); }

    // MARK: Evaluate

    public async Task<Evaluation> EvaluateAsync(Action<string>? progress, CancellationToken ct = default)
    {
        var ev = new Evaluation();
        var api = Source.Api;
        ev.ReadOnly = _isReadOnly();
        if (ev.ReadOnly) ev.Warnings.Add("Read-only mode is on, so Cirrus won’t add anything to iCloud. Turn it off in Settings › Safety to copy from Google.");
        var hasICloudDrive = Target.Drive is not null || Target.NativeDriveRoot is not null;
        if (Options.IncludeDrive)
        {
            if (!hasICloudDrive) ev.Warnings.Add("This iCloud account has no iCloud Drive here, so Google Drive is left out.");
            else if (!api.Has(GoogleScopes.DriveReadonly)) ev.Warnings.Add("Cirrus doesn’t have permission to read your Google Drive yet. Select Allow Reading Google Drive… to include it.");
            else ev.DriveEnabled = true;
        }
        ev.PhotosEnabled = Options.IncludePhotos && Target.Photos is not null && (Source.Takeout.Count > 0 || Source.Picked.Count > 0);
        if (Options.IncludePhotos && Target.Photos is null)
            ev.Warnings.Add("This iCloud account has no iCloud Photos here (sign in with your Apple ID inside Cirrus to copy photos), so Google Photos is left out.");
        else if (Options.IncludePhotos && Source.Takeout.Count == 0 && Source.Picked.Count == 0)
            ev.Warnings.Add("For Google Photos, choose a Takeout export (or pick photos in Google Photos). Google doesn’t let apps read your whole library any more.");
        if (api.Has(GoogleScopes.DriveFile) || api.Has(GoogleScopes.DriveReadonly))
        {
            progress?.Invoke("Checking your Google account…");
            try { ev.User = (await new GoogleDrive(api).AboutAsync(ct).ConfigureAwait(false)).User; } catch (Exception e) when (!MigrationEngine.IsCancel(e)) { }
        }
        if (Target.Storage is { } s) { progress?.Invoke("Reading iCloud storage…"); try { ev.ICloud = await s().ConfigureAwait(false); } catch { } }
        if (ev.DriveEnabled) await EvaluateDriveAsync(ev, progress, ct).ConfigureAwait(false);
        if (ev.PhotosEnabled) await EvaluatePhotosAsync(ev, progress, ct).ConfigureAwait(false);

        var largestDrive = ev.DrivePending.Count > 0 ? ev.DrivePending.Max(d => d.Size ?? Evaluation.DocEstimate) : 0;
        var largestPhoto = ev.PhotoPending.Count > 0 ? ev.PhotoPending.Max(p => p.Size) : 0;
        var batch = ev.TakeoutParts > 0 ? BatchBudget(largestPhoto) : 0;
        ev.StagingNeeded = Math.Max(Math.Max(largestDrive * Math.Max(1, Options.Concurrency), largestPhoto * 2), batch) + (ev.IsUpToDate ? 0 : 256L << 20);
        Directory.CreateDirectory(_staging);
        ev.StagingFree = FreeSpace(_staging) ?? long.MaxValue;
        MeasureTarget(ev);
        AddWarnings(ev);
        return ev;
    }

    /// <summary>
    /// iCloud for Windows target: the files land in its folder on this PC first (and stay until iCloud for Windows or
    /// Storage Sense frees them), so they must fit on that drive, with the staging space when it's the same drive.
    /// </summary>
    void MeasureTarget(Evaluation ev)
    {
        ev.TargetNeeded = 0;
        ev.TargetFree = long.MaxValue;
        if (!ev.DriveEnabled || Target.Drive is not null || Target.NativeDriveRoot is not { } root || ev.DrivePending.Count == 0) return;
        var bytes = ev.DrivePendingBytes;
        bool same;
        try { same = string.Equals(Path.GetPathRoot(Path.GetFullPath(root)), Path.GetPathRoot(Path.GetFullPath(_staging)), StringComparison.OrdinalIgnoreCase); } catch { same = false; }
        ev.TargetNeeded = bytes + bytes / 100 + (same ? ev.StagingNeeded : 0);
        ev.TargetFree = FreeSpace(root) ?? long.MaxValue;
    }

    /// <summary>How much of a Takeout part to unpack at once.</summary>
    internal static long BatchBudget(long largest) => Math.Max(largest, 1L << 30);

    async Task EvaluateDriveAsync(Evaluation ev, Action<string>? progress, CancellationToken ct)
    {
        var drive = new GoogleDrive(Source.Api);
        progress?.Invoke("Listing your Google Drive…");
        var rootID = await drive.RootFolderIDAsync(ct).ConfigureAwait(false);
        var all = await drive.ListAllAsync(n => progress?.Invoke($"Listing your Google Drive… {n} items"), ct).ConfigureAwait(false);
        var children = new Dictionary<string, List<GDriveItem>>(StringComparer.Ordinal);
        foreach (var i in all)
            foreach (var p in i.Parents)
            {
                if (!children.TryGetValue(p, out var l)) children[p] = l = [];
                l.Add(i);
            }
        var m = Store.Snapshot();
        // Walk from My Drive's root; things only "shared with me" have no path here and stay out.
        var frontier = new Stack<(string Id, string Prefix)>();
        frontier.Push((rootID, ""));
        var visited = new HashSet<string>(StringComparer.Ordinal);
        while (frontier.Count > 0)
        {
            var (id, prefix) = frontier.Pop();
            if (!visited.Add(id)) continue;   // a folder reachable twice (several parents) is copied once
            var used = new HashSet<string>(StringComparer.Ordinal);
            var kids = (children.GetValueOrDefault(id) ?? []).OrderBy(k => k.Name, StringComparer.Ordinal).ThenBy(k => k.Id, StringComparer.Ordinal).ToList();
            foreach (var k in kids)
            {
                // Cirrus's own copy of iCloud (iCloud → Google) isn't brought back.
                if (k.IsFolder && (k.AppProperties.ContainsKey(MigrationEngine.SourceKey) || k.Properties.GetValueOrDefault(MigrationEngine.RoleKey) == MigrationEngine.RoleFromICloud))
                {
                    ev.Warnings.Add($"“{k.Name}” in Google Drive is left out: it’s Cirrus’s copy of iCloud Drive.");
                    continue;
                }
                // Made by Cirrus through another Google Cloud project (another computer): its private tag can't be read here.
                if (k.IsFolder && prefix.Length == 0 && (k.Name == "From iCloud" || k.Name.StartsWith("From iCloud (", StringComparison.Ordinal)))
                {
                    ev.Warnings.Add($"“{k.Name}” in Google Drive is left out: it looks like Cirrus’s copy of iCloud Drive made on another computer. Rename it in Google Drive to include it.");
                    continue;
                }
                var name = SafeName(k.Name);
                GoogleDocTarget? export = null;
                if (k.IsGoogleNative)
                {
                    if (Options.DocFormat.Target(k.MimeType) is not { } t)
                    {
                        ev.Skipped.Add(new MigrationSkipped(prefix + k.Name, 0, $"{GoogleDocFormats.KindName(k.MimeType)} can’t be downloaded from Google"));
                        continue;
                    }
                    export = t;
                    if (!Path.GetExtension(name).TrimStart('.').Equals(t.Ext, StringComparison.OrdinalIgnoreCase)) name += "." + t.Ext;
                }
                // Google allows twins in one folder; iCloud doesn't.
                var unique = name; var n = 2;
                while (used.Contains(unique.ToLowerInvariant()))
                {
                    var stem = Path.GetFileNameWithoutExtension(name); var ext = Path.GetExtension(name).TrimStart('.');
                    unique = $"{stem} ({n})" + (ext.Length == 0 || k.IsFolder ? "" : "." + ext);
                    n++;
                }
                used.Add(unique.ToLowerInvariant());
                var rel = prefix.Length == 0 ? unique : prefix + "/" + unique;
                if (k.IsFolder) { ev.DriveFolders.Add(rel); frontier.Push((k.Id, rel)); continue; }
                if (!k.CanDownload)
                {
                    ev.Skipped.Add(new MigrationSkipped(rel, k.Size ?? 0, "The owner turned off downloading for this file"));
                    continue;
                }
                if (k.Size is { } sz && sz > ICloudDriveMax)
                {
                    ev.Skipped.Add(new MigrationSkipped(rel, sz, "Larger than iCloud Drive’s 50 GB limit"));
                    continue;
                }
                var item = new DriveItem(k.Id, rel, export is null ? k.Size ?? 0 : null, export, k);
                ev.DriveFiles++;
                ev.DriveBytes += k.Size ?? 0;
                if (export is not null) ev.Docs++;
                ev.DriveItems.Add(item);
                if (m.Files.TryGetValue(k.Id, out var done) && done.Rel == rel && (done.Version == k.Version || !Options.UpdateChanged)) continue;
                ev.DrivePending.Add(item);
            }
        }
        ev.DriveFolders.Sort(SyncPlanner.PathOrder);
        ev.DrivePending.Sort((a, b) => SyncPlanner.PathOrder(a.Rel, b.Rel));
    }

    /// <summary>name|size of every photo the iCloud → Google direction uploaded for this pair of accounts.</summary>
    HashSet<string> SentToGoogle()
    {
        var forward = JournalStores.Get<MigrationManifest, MigrationOp>(_stateDir, MigrationEngine.StoreName(Target.Key, Source.Api.AccountID));
        return forward.Read(m => m.Photos.Values.Where(p => p.Name is not null).Select(p => $"{p.Name!.ToLowerInvariant()}|{p.Size}").ToHashSet(StringComparer.Ordinal));
    }

    internal static string SafeName(string s)
    {
        // NFC like the scans' keys, so a name decomposed on one side still finds its earlier copy.
        var n = s.Normalize(System.Text.NormalizationForm.FormC).Replace("/", "-").Replace("\0", "").Trim();
        if (n.Length == 0 || n == "." || n == "..") n = "Untitled";
        if (n.StartsWith('.')) n = "_" + n[1..];   // a leading dot would hide it
        return n;
    }

    async Task EvaluatePhotosAsync(Evaluation ev, Action<string>? progress, CancellationToken ct)
    {
        var items = new List<PhotoItem>();
        int cameFromICloud = 0;
        if (Source.Takeout.Count > 0)
        {
            var r = await new TakeoutReader(Source.Takeout).ScanAsync(progress, ct).ConfigureAwait(false);
            ev.TakeoutParts = r.Parts;
            ev.Skipped.AddRange(r.Skipped);
            ev.Warnings.AddRange(r.Warnings);
            // Photos Cirrus itself sent from this iCloud account to this Google account aren't brought back.
            var sent = SentToGoogle();
            foreach (var t in r.Items)
            {
                if (sent.Contains($"{t.FileName.ToLowerInvariant()}|{t.Size}")) { cameFromICloud++; continue; }
                if (t.IsEdited && !Options.IncludeEdited) continue;
                if (t.IsCompanion && !Options.IncludeLive) continue;
                items.Add(new PhotoItem(t.Key, new PhotoSource.FromTakeout(t), t.FileName, t.Size, t.Taken, t.IsVideo, t.Group, t.Albums.ToList(), t.Favorite, t.IsCompanion));
                ev.TakeoutItems++;
            }
        }
        if (cameFromICloud > 0)
            ev.Warnings.Add($"{cameFromICloud} photo{S(cameFromICloud)} in the export came from this iCloud account through Cirrus, so {(cameFromICloud == 1 ? "it’s" : "they’re")} left out.");
        if (Source.Picked.Any(p => p.IsVideo))
            ev.Warnings.Add("Videos picked in Google Photos come as Google’s high-quality copy, not the original file. For originals, use a Takeout export.");
        foreach (var p in Source.Picked)
        {
            items.Add(new PhotoItem("picker:" + p.Id, new PhotoSource.FromPicker(p), p.FileName, p.IsVideo ? 60L << 20 : 4L << 20, p.Created, p.IsVideo,
                "picker:" + p.Id, [], false, false, SizeIsEstimate: true));
            ev.PickedItems++;
        }
        var m = Store.Snapshot();
        ev.PhotoItems = items;
        ev.PhotoPending = items.Where(i => !m.Photos.ContainsKey(i.Key)).ToList();
        if (Options.Albums)
        {
            var plans = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            var order = new List<string>();
            foreach (var i in items.Where(i => !i.IsCompanion))
                foreach (var a in i.Albums)
                {
                    if (!plans.TryGetValue(a, out var l)) { plans[a] = l = []; order.Add(a); }
                    l.Add(i.Key);
                }
            ev.Albums = order.Select(t => new AlbumPlan(t, plans[t])).ToList();
            foreach (var p in ev.Albums)
            {
                var added = m.Albums.TryGetValue(p.Title, out var al) ? al.Added : [];
                ev.AlbumAddsPending += p.Members.Count(k => !added.Contains(k));
            }
        }
        if (Options.Favorites) ev.FavoritesPending = items.Count(i => i.Favorite && !i.IsCompanion && !m.Favorited.Contains(i.Key));
        if (!Target.IsWeb && Target.Photos is { } photos && !photos.Capabilities.HasFlag(PhotoCapabilities.CreateAlbum))
            ev.Warnings.Add("This Photos library can’t make albums from Cirrus, so photos arrive without their Google albums.");
        if (ev.PhotoPending.Any(p => p.Source is PhotoSource.FromTakeout { Item: { Caption: not null } or { Latitude: not null } }))
            ev.Warnings.Add("Dates come along (iCloud files each photo under the day Google says it was taken), but captions and places from Google aren’t written into the copies on Windows.");
    }

    void AddWarnings(Evaluation ev)
    {
        if (!ev.FitsICloud && ev.ICloudFree is { } free)
            ev.Warnings.Add($"Not enough iCloud storage: this copy needs {ev.RequiredICloud.ByteString()} (with 1 % headroom) but iCloud has {free.ByteString()} free. Free up iCloud storage, upgrade your plan, or leave something out.");
        if (ev.ICloud is null && !ev.IsUpToDate)
            ev.Warnings.Add($"iCloud didn’t report free storage for this account, so make sure there’s room for {ev.PendingBytes.ByteString()}.");
        if (!ev.FitsStaging)
            ev.Warnings.Add($"Cirrus passes each file through a temporary folder on this PC and needs {ev.StagingNeeded.ByteString()} free there; only {ev.StagingFree.ByteString()} is available.");
        if (!ev.FitsTarget)
            ev.Warnings.Add($"Not enough space on this PC: this copy writes {ev.TargetNeeded.ByteString()} into the iCloud for Windows folder, whose drive has only {ev.TargetFree.ByteString()} free. iCloud for Windows keeps the files on this PC until it has uploaded them. Free up space, or sign in with your Apple ID in Cirrus and copy into that account instead (it goes straight to iCloud.com).");
        if (ev.Docs > 0)
        {
            var what = Options.DocFormat == GoogleDocFormat.Office ? "Word, Excel and PowerPoint files" : "PDFs";
            ev.Warnings.Add($"{ev.Docs} Google Doc{S(ev.Docs)}, Sheet{S(ev.Docs)} and Slides can’t be copied as they are; they’re exported as {what}. Comments, version history and live sharing stay in Google.");
        }
        if (Target.IsWeb)
        {
            var big = ev.DrivePending.Count(d => (d.Size ?? 0) > ICloudWebSoft);
            if (big > 0) ev.Warnings.Add($"{big} file{(big == 1 ? " is" : "s are")} over 10 GB; uploads that big through iCloud.com have failed for some people.");
            var videos = ev.PhotoPending.Count(p => p.IsVideo && p.Size > 100_000_000);
            if (videos > 0) ev.Warnings.Add($"{videos} video{(videos == 1 ? " is" : "s are")} over 100 MB; iCloud.com has refused videos that size for some accounts.");
        }
        var live = ev.PhotoPending.Count(p => p.IsCompanion);
        if (live > 0) ev.Warnings.Add($"Live Photos and motion photos arrive as a photo plus a separate short video ({live}): Google’s export doesn’t keep what pairs them.");
        if (ev.Skipped.Count > 0) ev.Warnings.Add($"{ev.Skipped.Count} item{(ev.Skipped.Count == 1 ? " is" : "s are")} skipped (listed below).");
    }

    // MARK: Run

    /// <summary>Errors that end the run rather than one item.</summary>
    internal static GoogleException? Stops(Exception e)
    {
        if (MigrationEngine.Stops(e) is { } g) return g;
        if (e is ReadOnlyException) return GoogleException.BadResponse(e.Message);
        if (e is ICloudException { Kind: ICloudErrorKind.NeedsSignIn or ICloudErrorKind.WebAccessDisabled or ICloudErrorKind.ServiceUnavailable } i)
            return GoogleException.Reconnect(i.Message);
        return null;
    }

    public async Task<Report> RunAsync(Evaluation ev, Action<RunProgress>? progress, CancellationToken ct = default)
    {
        if (_isReadOnly()) throw new ReadOnlyException();
        if (!MoveRuns.TryBegin(RunKey)) throw MoveRuns.Busy();
        try { return await RunLockedAsync(ev, progress, ct).ConfigureAwait(false); }
        finally { MoveRuns.End(RunKey); }
    }

    async Task<Report> RunLockedAsync(Evaluation ev, Action<RunProgress>? progress, CancellationToken ct)
    {
        // The limits are checked again against what's still left (a Retry reuses an older check).
        var m = Store.Snapshot();
        var drive = ev.DriveEnabled
            ? ev.DriveItems.Where(i => !(m.Files.TryGetValue(i.Id, out var d) && d.Rel == i.Rel) || (m.Files[i.Id].Version != i.Item.Version && Options.UpdateChanged)).ToList()
            : [];
        var photos = ev.PhotosEnabled ? ev.PhotoItems.Where(p => !m.Photos.ContainsKey(p.Key)).ToList() : [];
        var remaining = drive.Sum(d => d.Size ?? Evaluation.DocEstimate) + photos.Sum(p => p.Size);
        if (Target.Storage is { } st && remaining > 0) { try { ev.ICloud = await st().ConfigureAwait(false) ?? ev.ICloud; } catch { } }
        if (ev.ICloudFree is { } free && free < remaining + remaining / 100)
            throw SyncException.Unavailable($"Not enough iCloud storage for this copy: it needs {(remaining + remaining / 100).ByteString()}, {free.ByteString()} is free.");
        Directory.CreateDirectory(_staging);
        ev.StagingFree = FreeSpace(_staging) ?? long.MaxValue;
        if (!ev.FitsStaging) throw SyncException.NotEnoughSpace(ev.StagingNeeded, ev.StagingFree);
        MeasureTarget(ev);
        if (!ev.FitsTarget) throw SyncException.NotEnoughSpace(ev.TargetNeeded, ev.TargetFree);
        MigrationEngine.ResetStaging(_staging);
        try
        {
            var bytes = (drive.Sum(d => d.Size ?? Evaluation.DocEstimate) + photos.Sum(p => p.Size)) * 2;
            var ctx = new MoveRunContext(drive.Count + photos.Count, bytes, progress);
            var report = new Report { Skipped = ev.Skipped.ToList() };
            if (ev.DriveEnabled)
            {
                try { await RunDriveAsync(ev, drive, ctx, report, ct).ConfigureAwait(false); }
                catch (Exception e) when (!MigrationEngine.IsCancel(e) && Stops(e) is { } s) { ctx.Stop(s); }
            }
            if (ev.PhotosEnabled && ctx.Stopped is null)
            {
                try
                {
                    await RunPhotosAsync(photos, ctx, report, ct).ConfigureAwait(false);
                    if (ctx.Stopped is null) await OrganizeAsync(ev, ctx, report, ct).ConfigureAwait(false);
                }
                catch (Exception e) when (!MigrationEngine.IsCancel(e) && Stops(e) is { } s) { ctx.Stop(s); }
            }
            report.Failed = ctx.Failed;
            report.Stopped = ctx.Stopped?.Message;
            ctx.Phase("Finished");
            return report;
        }
        catch (Exception e) when (MigrationEngine.IsCancel(e)) { throw new OperationCanceledException("The copy was stopped.", e, ct); }
        finally
        {
            MigrationEngine.RemoveStaging(_staging);
            Store.Compact();
        }
    }

    // MARK: Drive → iCloud Drive

    async Task<ISyncSide> DestinationAsync(CancellationToken ct)
    {
        SafetyPolicy.CheckWrite();
        if (Target.Drive is { } d)
        {
            var folder = (await d.ListAsync(d.RootID, ct).ConfigureAwait(false)).FirstOrDefault(n => n.IsFolder && n.Name == Options.FolderName)
                ?? await d.CreateFolderAsync(Options.FolderName, d.RootID, ct).ConfigureAwait(false);
            return new DriveSide(d, folder.Id, Options.FolderName, []);
        }
        if (Target.NativeDriveRoot is not { } root) throw SyncException.Unavailable("This iCloud account has no iCloud Drive here.");
        var dest = Path.Combine(root, Options.FolderName);
        if (!Directory.Exists(dest))
        {
            SafetyPolicy.CheckLocalWrite(dest);
            Directory.CreateDirectory(dest);
        }
        return new LocalSide(dest, [], allowMissing: true);
    }

    async Task RunDriveAsync(Evaluation ev, List<DriveItem> items, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        if (items.Count == 0 && ev.DriveFolders.Count == 0) return;
        ctx.Phase("Preparing iCloud Drive…");
        var side = await DestinationAsync(ct).ConfigureAwait(false);
        var existing = await side.ScanAsync(null, ct).ConfigureAwait(false);
        foreach (var f in ev.DriveFolders)
        {
            ct.ThrowIfCancellationRequested();
            if (!existing.ContainsKey(f)) await side.MakeDirAsync(f, ct).ConfigureAwait(false);
        }
        var drive = new GoogleDrive(Source.Api);
        await MigrationEngine.ForEachAsync(items, Options.Concurrency, ct, async (item, t) =>
        {
            if (ctx.Stopped is not null) return;
            try { await CopyDriveItemAsync(item, drive, side, existing, ctx, report, t).ConfigureAwait(false); }
            catch (Exception e) when (!MigrationEngine.IsCancel(e))
            {
                if (Stops(e) is { } s) { ctx.Stop(s); return; }
                ctx.Fail(item.Rel, e);
            }
            ctx.DoneFile();
        }).ConfigureAwait(false);
    }

    async Task CopyDriveItemAsync(DriveItem item, GoogleDrive drive, ISyncSide side, Dictionary<string, SideEntry> existing, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        var name = Last(item.Rel);
        var dir = Path.Combine(_staging, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, Paths.SafeName(name));
            var down = new ByteMark();
            var expected = item.Size ?? Evaluation.DocEstimate;
            if (item.Export is { } t)
            {
                ctx.Phase($"Exporting {name} from Google…");
                await drive.ExportAsync(item.Item, t, file, ct).ConfigureAwait(false);
            }
            else
            {
                ctx.Phase($"Downloading {name} from Google Drive…");
                await drive.DownloadAsync(item.Item, file, (d, _) => ctx.AddBytes(down.Advance(Math.Min(d, expected))), ct).ConfigureAwait(false);
            }
            ctx.AddBytes(down.Advance(expected));
            var size = new FileInfo(file).Length;
            if (item.Item.Modified is { } mod) { try { File.SetLastWriteTimeUtc(file, mod.UtcDateTime); } catch { } }
            ctx.Phase($"Uploading {name} to iCloud Drive…");
            var replacing = existing.ContainsKey(item.Rel) || Store.Read(m => m.Files.ContainsKey(item.Id));
            if (side is LocalSide local && existing.ContainsKey(item.Rel))
            {
                // iCloud for Windows folder: the previous copy goes to the Recycle Bin first, never overwritten in place.
                // The path is the one the scan found on disk (its exact spelling), the same one StoreAsync writes.
                var path = local.PathFor(item.Rel);
                SafetyPolicy.CheckLocalWrite(path);
                if (File.Exists(path)) _trash(path, local.Root);
                if (File.Exists(path)) throw SyncException.Unavailable($"The earlier copy of “{name}” couldn’t be moved to the Recycle Bin, so it was left as it is.");
            }
            var up = new ByteMark();
            await side.StoreAsync(item.Rel, file, item.Item.Modified ?? DateTimeOffset.UtcNow, (d, _) => ctx.AddBytes(up.Advance(Math.Min(d, expected))), ct).ConfigureAwait(false);
            ctx.AddBytes(up.Advance(expected));
            Store.Apply(new ImportOp.File(item.Id, new(item.Rel, item.Item.Version, size)));
            Mutate(report, r =>
            {
                if (replacing) r.DriveUpdated++; else r.DriveCopied++;
                if (item.Export is not null) r.DocsExported++;
                r.DriveBytes += size;
            });
        }
        finally { try { Directory.Delete(dir, true); } catch { } }   // Cirrus's own staging copy
    }

    // MARK: Photos → iCloud Photos

    async Task<PhotoAlbum?> ProvenanceAlbumAsync(IPhotosBackend backend, PhotoLibraryRef library, CancellationToken ct)
    {
        if (!Target.IsWeb && !backend.Capabilities.HasFlag(PhotoCapabilities.CreateAlbum)) return null;
        List<PhotoAlbum>? albums = null;
        try { albums = await backend.AlbumsAsync(library, ct).ConfigureAwait(false); }
        catch (Exception e) when (!MigrationEngine.IsCancel(e)) { Log.Status("import: album list failed (" + e.GetType().Name + ")"); }
        if (Store.Read(m => m.Provenance) is { } p)
        {
            // Still there? (The user may have deleted the album: adding to it would then fail for every photo.)
            if (albums is null || albums.Any(a => a.Id == p.Id)) return new PhotoAlbum(p.Id, p.Title, PhotoAlbumKind.Album);
            Store.Apply(new ImportOp.Provenance(null, null));
        }
        // Without the album list Cirrus can't tell whether the album exists; making a second one would split the record
        // of what came from Google.
        if (albums is null) throw SyncException.Unavailable("Couldn’t read the albums in iCloud Photos. Try again in a moment.");
        var found = albums.FirstOrDefault(a => a.Kind == PhotoAlbumKind.Album && a.Name == Options.PhotosAlbumName);
        if (found is not null)
        {
            Store.Apply(new ImportOp.Provenance(found.Id, found.Name));
            return found;
        }
        var a = await backend.CreateAlbumAsync(Options.PhotosAlbumName, library, ct).ConfigureAwait(false);
        Store.Apply(new ImportOp.Provenance(a.Id, a.Name));
        return a;
    }

    static async Task<PhotoLibraryRef> MainLibraryAsync(IPhotosBackend backend, CancellationToken ct)
    {
        var libs = await backend.LibrariesAsync(ct).ConfigureAwait(false);
        return libs.FirstOrDefault(l => !l.IsShared) ?? libs.FirstOrDefault() ?? throw SyncException.Unavailable("No Photos library to copy into.");
    }

    async Task RunPhotosAsync(List<PhotoItem> items, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        if (items.Count == 0 || Target.Photos is not { } backend) return;
        ctx.Phase("Preparing iCloud Photos…");
        SafetyPolicy.CheckWrite();
        var library = await MainLibraryAsync(backend, ct).ConfigureAwait(false);
        var album = await ProvenanceAlbumAsync(backend, library, ct).ConfigureAwait(false);
        var reader = new TakeoutReader(Source.Takeout);
        // Takeout parts are unpacked a batch at a time (Live Photo halves stay together) so disk use stays bounded.
        var groups = new List<List<PhotoItem>>();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var i in items)
        {
            if (index.TryGetValue(i.Group, out var g)) groups[g].Add(i);
            else { index[i.Group] = groups.Count; groups.Add([i]); }
        }
        var budget = BatchBudget(items.Max(i => i.Size));
        var batch = new List<List<PhotoItem>>();
        long batchBytes = 0;
        async Task Flush()
        {
            if (batch.Count == 0) return;
            var current = batch;
            batch = [];
            batchBytes = 0;
            await ImportBatchAsync(current, backend, library, album, reader, ctx, report, ct).ConfigureAwait(false);
        }
        foreach (var g in groups)
        {
            ct.ThrowIfCancellationRequested();
            if (ctx.Stopped is not null) break;
            var size = g.Sum(i => i.Size);
            if (batchBytes + size > budget || batch.Count >= 200) await Flush().ConfigureAwait(false);
            batch.Add(g);
            batchBytes += size;
        }
        if (ctx.Stopped is null) await Flush().ConfigureAwait(false);
    }

    async Task ImportBatchAsync(List<List<PhotoItem>> groups, IPhotosBackend backend, PhotoLibraryRef library, PhotoAlbum? album, TakeoutReader reader,
        MoveRunContext ctx, Report report, CancellationToken ct)
    {
        var dir = Path.Combine(_staging, "batch-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            var takeoutItems = groups.SelectMany(g => g).Select(i => i.Source).OfType<PhotoSource.FromTakeout>().Select(t => t.Item).ToList();
            var files = new Dictionary<string, string>(StringComparer.Ordinal);
            if (takeoutItems.Count > 0)
            {
                ctx.Phase($"Unpacking {takeoutItems.Count} item{S(takeoutItems.Count)} from the Takeout export…");
                files = await reader.ExtractAsync(takeoutItems, Path.Combine(dir, "raw"), ct).ConfigureAwait(false);
            }
            var picker = new GooglePicker(Source.Api);
            await MigrationEngine.ForEachAsync(groups, Math.Min(2, Math.Max(1, Options.Concurrency)), ct, async (group, t) =>
            {
                if (ctx.Stopped is not null) return;
                var recorded = new HashSet<string>(StringComparer.Ordinal);
                try
                {
                    // Each group (a photo, or a Live Photo's two halves) gets its own folder so iCloud sees the original names.
                    var gdir = Path.Combine(dir, Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(gdir);
                    var ready = new List<(PhotoItem Item, string File)>();
                    foreach (var item in group)
                    {
                        var dest = Path.Combine(gdir, Paths.SafeName(item.FileName));
                        switch (item.Source)
                        {
                            case PhotoSource.FromTakeout:
                                if (!files.TryGetValue(item.Key, out var f)) throw SyncException.Unavailable("It couldn’t be unpacked from the Takeout export.");
                                File.Move(f, dest);
                                ctx.AddBytes(item.Size);
                                break;
                            case PhotoSource.FromPicker p:
                                ctx.Phase($"Downloading {item.FileName} from Google Photos…");
                                await picker.DownloadAsync(p.Item, dest, t).ConfigureAwait(false);
                                ctx.AddBytes(new FileInfo(dest).Length);
                                break;
                        }
                        // iCloud dates a file without its own capture date by its modification time (iCloud.com's lastModDate).
                        if (item.Taken is { } taken) { try { File.SetLastWriteTimeUtc(dest, taken.UtcDateTime); File.SetCreationTimeUtc(dest, taken.UtcDateTime); } catch { } }
                        ready.Add((item, dest));
                    }
                    ctx.Phase($"Adding {group[0].FileName} to iCloud Photos…");
                    var up = new ByteMark();
                    var total = ready.Sum(r => new FileInfo(r.File).Length);
                    var byPath = ready.ToDictionary(r => r.File, r => r.Item, StringComparer.Ordinal);
                    // Each file is recorded the moment iCloud has it, so a failure later in the group (the other half of a
                    // Live Photo, the album add, a cancel) never sends it again.
                    await backend.ImportFilesEachAsync(ready.Select(r => r.File).ToList(), album, library, (d, tt) =>
                    {
                        // Backends report bytes or file counts; scale either onto this group's bytes.
                        var frac = tt > 0 ? (double)d / tt : 0;
                        ctx.AddBytes(up.Advance((long)(frac * total)));
                    }, (f, _) =>
                    {
                        if (!byPath.TryGetValue(f, out var item) || !recorded.Add(item.Key)) return;
                        var size = new FileInfo(f).Length;
                        Store.Apply(new ImportOp.Photo(item.Key, new(Path.GetFileName(f), size)));
                        Mutate(report, r => { r.PhotosImported++; r.PhotosBytes += size; });
                    }, t).ConfigureAwait(false);
                    ctx.AddBytes(up.Advance(total));
                    try { Directory.Delete(gdir, true); } catch { }
                }
                catch (Exception e) when (!MigrationEngine.IsCancel(e))
                {
                    if (Stops(e) is { } s) { ctx.Stop(s); return; }
                    foreach (var item in group.Where(i => !recorded.Contains(i.Key))) ctx.Fail(item.FileName, e);
                    if (group.Any(i => recorded.Contains(i.Key)))
                        ctx.Fail(group[0].FileName, SyncException.Unavailable($"It’s in iCloud Photos but couldn’t be added to “{Options.PhotosAlbumName}” ({e.Message})."));
                }
                foreach (var _ in group) ctx.DoneFile();
            }).ConfigureAwait(false);
        }
        finally { try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { } }   // Cirrus's own staging folder
    }

    /// <summary>Albums and favorites: find what was imported (by name and size in "From Google Photos") and organize it.</summary>
    async Task OrganizeAsync(Evaluation ev, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        if (Target.Photos is not { } backend || !ev.PhotosEnabled) return;
        var m0 = Store.Snapshot();
        var pendingAlbums = ev.Albums.Where(p => p.Members.Any(k => m0.Photos.ContainsKey(k) && !(m0.Albums.TryGetValue(p.Title, out var a) && a.Added.Contains(k)))).ToList();
        var pendingFavs = Options.Favorites ? ev.PhotoItems.Where(i => i.Favorite && !i.IsCompanion && m0.Photos.ContainsKey(i.Key) && !m0.Favorited.Contains(i.Key)).ToList() : [];
        if ((pendingAlbums.Count == 0 && pendingFavs.Count == 0) || m0.Provenance is not { } prov) return;
        ctx.Phase("Organizing albums…");
        var library = await MainLibraryAsync(backend, ct).ConfigureAwait(false);
        var listed = await backend.AssetsAsync(new PhotoAlbum(prov.Id, prov.Title, PhotoAlbumKind.Album), library, null, ct).ConfigureAwait(false);
        var byName = listed.GroupBy(a => a.Filename.ToLowerInvariant()).ToDictionary(g => g.Key, g => g.ToList());
        PhotoAsset? Find(string key)
        {
            if (Store.Read(m => m.Photos.GetValueOrDefault(key)) is not { } p) return null;
            var candidates = byName.GetValueOrDefault(p.Name.ToLowerInvariant()) ?? [];
            return candidates.FirstOrDefault(a => (a.Resource(PhotoResourceKind.Original)?.Size ?? a.Size) == p.Size) ?? (candidates.Count == 1 ? candidates[0] : null);
        }
        var unmatched = new HashSet<string>(StringComparer.Ordinal);
        foreach (var plan in pendingAlbums)
        {
            ct.ThrowIfCancellationRequested();
            var m = Store.Snapshot();
            m.Albums.TryGetValue(plan.Title, out var entry);
            var keys = plan.Members.Where(k => m.Photos.ContainsKey(k) && !(entry?.Added.Contains(k) ?? false)).ToList();
            var assets = new List<PhotoAsset>();
            var found = new List<string>();
            foreach (var k in keys) { if (Find(k) is { } a) { assets.Add(a); found.Add(k); } else unmatched.Add(k); }
            if (assets.Count == 0) continue;
            if (entry is null)
            {
                PhotoAlbum? a = null;
                try { a = (await backend.AlbumsAsync(library, ct).ConfigureAwait(false)).FirstOrDefault(x => x.Kind == PhotoAlbumKind.Album && x.Name == plan.Title); }
                catch (Exception e) when (!MigrationEngine.IsCancel(e)) { }
                if (a is null)
                {
                    a = await backend.CreateAlbumAsync(plan.Title, library, ct).ConfigureAwait(false);
                    Mutate(report, r => r.AlbumsCreated++);
                }
                Store.Apply(new ImportOp.Album(plan.Title, a.Id));
                entry = new ImportManifest.Album { Id = a.Id, Title = plan.Title };
            }
            var target = new PhotoAlbum(entry.Id, plan.Title, PhotoAlbumKind.Album);
            for (int i = 0; i < assets.Count; i += 100)
            {
                var part = assets.Skip(i).Take(100).ToList();
                var partKeys = found.Skip(i).Take(100).ToList();
                try
                {
                    await backend.AddAsync(part, target, library, ct).ConfigureAwait(false);
                    Store.Apply(new ImportOp.AlbumAdded(plan.Title, partKeys));
                    Mutate(report, r => r.AlbumAdds += part.Count);
                }
                catch (Exception e) when (!MigrationEngine.IsCancel(e) && Stops(e) is null)
                {
                    ctx.Fail($"Album “{plan.Title}”", e);
                    break;
                }
            }
        }
        if (pendingFavs.Count > 0 && backend.Capabilities.HasFlag(PhotoCapabilities.Favorite))
        {
            var assets = new List<PhotoAsset>();
            var keys = new List<string>();
            foreach (var i in pendingFavs) { if (Find(i.Key) is { } a) { assets.Add(a); keys.Add(i.Key); } else unmatched.Add(i.Key); }
            for (int i = 0; i < assets.Count; i += 100)
            {
                var part = assets.Skip(i).Take(100).ToList();
                var partKeys = keys.Skip(i).Take(100).ToList();
                try
                {
                    await backend.SetFavoriteAsync(part, true, ct).ConfigureAwait(false);
                    Store.Apply(new ImportOp.Favorited(partKeys));
                    Mutate(report, r => r.FavoritesSet += part.Count);
                }
                catch (Exception e) when (!MigrationEngine.IsCancel(e) && Stops(e) is null)
                {
                    ctx.Fail("Favorites", e);
                    break;
                }
            }
        }
        if (unmatched.Count > 0)
        {
            Mutate(report, r => r.Unmatched = unmatched.Count);
            ctx.Fail("Albums", SyncException.Unavailable($"{unmatched.Count} photo{S(unmatched.Count)} couldn’t be found again in “{prov.Title}” to add to albums; they’re in your library."));
        }
    }
}
