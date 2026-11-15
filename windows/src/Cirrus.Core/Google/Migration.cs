using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace Cirrus.Core;

/// <summary>An item a move leaves out, and why.</summary>
public sealed record MigrationSkipped(string Name, long Size, string Reason);

/// <summary>What to move from iCloud to Google.</summary>
public sealed class MigrationOptions
{
    public bool IncludeDrive { get; set; } = true;
    public bool IncludePhotos { get; set; } = true;
    /// <summary>A Live Photo arrives as the still plus a separate short video.</summary>
    public bool IncludeLive { get; set; } = true;
    public bool IncludeEdited { get; set; }
    public bool IncludeRAW { get; set; }
    public bool IncludeHidden { get; set; }
    public bool IncludeSharedLibrary { get; set; } = true;
    public bool Albums { get; set; } = true;
    /// <summary>iCloud Favorites become an album (the API can't set Google's own favorite flag).</summary>
    public bool FavoritesAlbum { get; set; } = true;
    /// <summary>Re-upload files changed in iCloud since the last run (the old Google copy goes to Drive's trash).</summary>
    public bool UpdateChanged { get; set; } = true;
    public List<string> Excludes { get; set; } = new SyncOptions().Excludes;
    public string FolderName { get; set; } = "From iCloud";
    /// <summary>What Cirrus copied in from Google (Google → iCloud) is left out, so the two directions never loop.</summary>
    public string FromGoogleFolder { get; set; } = "From Google Drive";
    public string FromGoogleAlbum { get; set; } = "From Google Photos";
    public int Concurrency { get; set; } = 3;
}

// MARK: - Manifest (what's already in Google), with an append-only journal so a crash loses nothing

public sealed class MigrationManifest
{
    public sealed record DriveFile(string Id, long Size, double Mtime);
    public sealed record DriveUpload(string Url, long Total, double Mtime, DateTimeOffset Started);
    public sealed record Photo(string Id, long Size, string? Name = null);
    public sealed record Token(string Value, DateTimeOffset At, long Size, string? Description);
    public sealed class Album { public string Id { get; set; } = ""; public string Title { get; set; } = ""; public HashSet<string> Added { get; set; } = []; }

    public string? Root { get; set; }
    public string? RootName { get; set; }
    public Dictionary<string, string> Folders { get; set; } = [];                          // iCloud path → Drive folder id
    public Dictionary<string, DriveFile> Files { get; set; } = [];                         // iCloud path → Drive file
    public Dictionary<string, DriveUpload> DriveUploads { get; set; } = [];                // unfinished resumable sessions
    public Dictionary<string, Photo> Photos { get; set; } = [];                            // item key → media item
    public Dictionary<string, GooglePhotos.UploadSession> PhotoUploads { get; set; } = []; // unfinished resumable sessions
    public Dictionary<string, Token> Tokens { get; set; } = [];                            // uploaded, not yet turned into media items
    public Dictionary<string, Album> Albums { get; set; } = [];                            // iCloud album key → Google album
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "op")]
[JsonDerivedType(typeof(Root), "root")]
[JsonDerivedType(typeof(Folder), "folder")]
[JsonDerivedType(typeof(File), "file")]
[JsonDerivedType(typeof(DriveUpload), "driveUpload")]
[JsonDerivedType(typeof(Photo), "photo")]
[JsonDerivedType(typeof(PhotoUpload), "photoUpload")]
[JsonDerivedType(typeof(Token), "token")]
[JsonDerivedType(typeof(Album), "album")]
[JsonDerivedType(typeof(AlbumAdded), "albumAdded")]
[JsonDerivedType(typeof(ResetDrive), "resetDrive")]
abstract record MigrationOp : IManifestOp<MigrationManifest>
{
    public abstract void Apply(MigrationManifest m);

    public sealed record Root(string? Id, string? Name) : MigrationOp { public override void Apply(MigrationManifest m) { m.Root = Id; m.RootName = Name; } }
    public sealed record Folder(string Rel, string Id) : MigrationOp { public override void Apply(MigrationManifest m) => m.Folders[Rel] = Id; }
    public sealed record File(string Rel, MigrationManifest.DriveFile Value) : MigrationOp { public override void Apply(MigrationManifest m) => m.Files[Rel] = Value; }
    public sealed record DriveUpload(string Rel, MigrationManifest.DriveUpload? Value) : MigrationOp
    {
        public override void Apply(MigrationManifest m) { if (Value is null) m.DriveUploads.Remove(Rel); else m.DriveUploads[Rel] = Value; }
    }
    public sealed record Photo(string Key, MigrationManifest.Photo Value) : MigrationOp { public override void Apply(MigrationManifest m) => m.Photos[Key] = Value; }
    public sealed record PhotoUpload(string Key, GooglePhotos.UploadSession? Value) : MigrationOp
    {
        public override void Apply(MigrationManifest m) { if (Value is null) m.PhotoUploads.Remove(Key); else m.PhotoUploads[Key] = Value; }
    }
    public sealed record Token(string Key, MigrationManifest.Token? Value) : MigrationOp
    {
        public override void Apply(MigrationManifest m) { if (Value is null) m.Tokens.Remove(Key); else m.Tokens[Key] = Value; }
    }
    public sealed record Album(string Key, string Id, string Title) : MigrationOp
    {
        public override void Apply(MigrationManifest m) => m.Albums[Key] = new MigrationManifest.Album { Id = Id, Title = Title };
    }
    public sealed record AlbumAdded(string Key, List<string> Keys) : MigrationOp
    {
        public override void Apply(MigrationManifest m) { if (m.Albums.TryGetValue(Key, out var a)) a.Added.UnionWith(Keys); }
    }
    public sealed record ResetDrive : MigrationOp
    {
        public override void Apply(MigrationManifest m) { m.Root = null; m.RootName = null; m.Folders.Clear(); m.Files.Clear(); m.DriveUploads.Clear(); }
    }
}

/// <summary>Progress, counters and the first run-stopping error, shared by a run's parallel workers.</summary>
public sealed class MoveRunContext
{
    readonly object _lock = new();
    long _bytes;
    int _files;
    string _phase = "Starting…";
    GoogleException? _stop;
    readonly List<string> _failed = [];
    public int FilesTotal { get; }
    public long BytesTotal { get; }
    readonly Action<RunProgress>? _progress;

    public MoveRunContext(int filesTotal, long bytesTotal, Action<RunProgress>? progress) { FilesTotal = filesTotal; BytesTotal = bytesTotal; _progress = progress; }

    void Emit()
    {
        RunProgress p;
        lock (_lock) p = new RunProgress(_phase, _files, FilesTotal, Math.Min(_bytes, BytesTotal), BytesTotal);
        try { _progress?.Invoke(p); } catch { }
    }
    public void AddBytes(long d) { if (d <= 0) return; lock (_lock) _bytes += d; Emit(); }
    public void DoneFile() { lock (_lock) _files++; Emit(); }
    public void Phase(string s) { lock (_lock) _phase = s; Emit(); }
    public void Fail(string name, Exception e)
    {
        Log.Error($"move failed for {name}: {e.Message}");
        Log.Status("move: an item failed (" + e.GetType().Name + ")");
        lock (_lock) _failed.Add($"{name}: {e.Message}");
    }
    public void Stop(GoogleException e) { lock (_lock) _stop ??= e; }
    public GoogleException? Stopped { get { lock (_lock) return _stop; } }
    public List<string> Failed { get { lock (_lock) return _failed.ToList(); } }
}

/// <summary>Remembers a byte position so progress callbacks only ever add what's new.</summary>
sealed class ByteMark
{
    long _last;
    public long Advance(long to) { lock (this) { var d = to - _last; if (d > 0) _last = to; return Math.Max(0, d); } }
}

/// <summary>
/// iCloud → Google (port of Migration.swift): iCloud Drive into a "From iCloud" folder in Google Drive, iCloud Photos
/// into Google Photos with albums. Reads iCloud only (never changes it), streams each file through a small temporary
/// folder, and records every finished item so reruns only send what's new.
/// </summary>
public sealed class MigrationEngine
{
    /// <param name="Key">Stable id of the iCloud account ("web:…", "native", "demo").</param>
    public sealed record Sources(string Key, string Title, IDriveBackend? Drive, string? NativeDriveRoot, IPhotosBackend? Photos,
        Func<Task<StorageUsage?>>? Storage = null);

    public sealed class Target
    {
        public GoogleApi Api { get; }
        public GoogleDrive Drive { get; }
        public GooglePhotos Photos { get; }
        public Target(GoogleApi api) { Api = api; Drive = new GoogleDrive(api); Photos = new GooglePhotos(api); }
        public string AccountID => Api.AccountID;
    }

    /// <param name="Rel">Path under the Google folder.</param>
    public sealed record DriveItem(string Rel, int Side, string SourceRel, long Size, double Mtime);
    public sealed record PhotoItem(string Key, PhotoAsset Asset, PhotoResourceKind Kind, string FileName, long Size, bool IsVideo);
    /// <param name="Members">Photo item keys.</param>
    public sealed record AlbumPlan(string Key, string Title, List<string> Members);

    public sealed class Evaluation
    {
        public GoogleUser? User { get; set; }
        public GoogleQuota? Quota { get; set; }
        public StorageUsage? ICloud { get; set; }
        public bool DriveEnabled { get; set; }
        public bool PhotosEnabled { get; set; }
        public int DriveFiles { get; set; }
        public long DriveBytes { get; set; }
        public List<DriveItem> DriveItems { get; set; } = [];
        public List<DriveItem> DrivePending { get; set; } = [];
        public List<string> DriveFolders { get; set; } = [];
        public int AssetCount { get; set; }
        public int PhotoFiles { get; set; }
        public long PhotoBytes { get; set; }
        public List<PhotoItem> PhotoItems { get; set; } = [];
        public List<PhotoItem> PhotoPending { get; set; } = [];
        public List<AlbumPlan> Albums { get; set; } = [];
        public int AlbumAddsPending { get; set; }
        public List<MigrationSkipped> Skipped { get; set; } = [];
        public List<string> Warnings { get; set; } = [];
        public long StagingFree { get; set; } = long.MaxValue;
        public long StagingNeeded { get; set; }
        /// <summary>iCloud for Windows source: files that are only in iCloud get downloaded to this PC to be sent (and stay).</summary>
        public int CloudOnlyFiles { get; set; }
        public long LocalNeeded { get; set; }
        public long LocalFree { get; set; } = long.MaxValue;
        internal List<ISyncSide> Sides { get; set; } = [];

        public long DrivePendingBytes => DrivePending.Sum(i => i.Size);
        public long PhotoPendingBytes => PhotoPending.Sum(i => i.Size);
        public long PendingBytes => DrivePendingBytes + PhotoPendingBytes;
        /// <summary>What the move adds to Google storage, plus 1 % headroom.</summary>
        public long RequiredGoogle => PendingBytes + PendingBytes / 100;
        public long? GoogleFree => Quota?.Free;
        public bool FitsGoogle => GoogleFree is not { } f || f >= RequiredGoogle;
        public bool FitsStaging => StagingFree >= StagingNeeded;
        public bool FitsLocal => LocalFree >= LocalNeeded;
        public bool Fits => FitsGoogle && FitsStaging && FitsLocal;
        public bool IsUpToDate => DrivePending.Count == 0 && PhotoPending.Count == 0 && AlbumAddsPending == 0;
        /// <summary>Photos Library API calls this run needs (uploads + creates + album work), against 10,000 a day.</summary>
        public int PhotoRequests =>
            PhotoPending.Sum(p => p.Size > GooglePhotos.RawLimit ? 2 + (int)(p.Size / (8 << 20)) : 1) + (PhotoPending.Count + 49) / 50 + Albums.Count + (AlbumAddsPending + 49) / 50;
    }

    public sealed class Report
    {
        public int DriveCopied { get; set; }
        public int DriveUpdated { get; set; }
        public long DriveBytes { get; set; }
        public int FoldersCreated { get; set; }
        public int Resumed { get; set; }
        public int PhotosCreated { get; set; }
        public long PhotosBytes { get; set; }
        public int AlbumsCreated { get; set; }
        public int AlbumAdds { get; set; }
        public List<MigrationSkipped> Skipped { get; set; } = [];
        public List<string> Failed { get; set; } = [];
        public string? Stopped { get; set; }
        public string? DriveFolderID { get; set; }
        public Uri? DriveFolderURL => DriveFolderID is { } id ? new Uri("https://drive.google.com/drive/folders/" + Uri.EscapeDataString(id)) : null;

        static string S(int n) => n == 1 ? "" : "s";

        public string Summary
        {
            get
            {
                var parts = new List<string>();
                var d = DriveCopied + DriveUpdated;
                if (d > 0)
                    parts.Add($"{d} file{S(d)} to Google Drive" + (DriveUpdated > 0 ? ", " + (DriveUpdated == d ? (d == 1 ? "an update" : "all updates") : $"{DriveUpdated} of them updates") : ""));
                if (PhotosCreated > 0) parts.Add($"{PhotosCreated} photo{S(PhotosCreated)} and video{S(PhotosCreated)} to Google Photos");
                if (AlbumsCreated > 0) parts.Add($"{AlbumsCreated} album{S(AlbumsCreated)} created");
                var skip = Skipped.Count == 0 ? "" : $"{Skipped.Count} skipped";
                if (parts.Count == 0 && Failed.Count == 0)
                    return (Stopped is null ? "Everything was already in Google" : "Nothing was copied") + (skip.Length == 0 ? "" : " — " + skip);
                var bytes = DriveBytes + PhotosBytes;
                var output = new List<string>();
                if (parts.Count > 0) output.Add(string.Join(", ", parts) + (bytes > 0 ? $" ({bytes.ByteString()})" : ""));
                if (Failed.Count > 0) output.Add($"{Failed.Count} failed");
                if (skip.Length > 0) output.Add(skip);
                return string.Join(", ", output);
            }
        }
    }

    internal const string SourceKey = "cirrusSource";
    /// <summary>
    /// A public marker on the "From iCloud" folder. appProperties are private to the Google Cloud project that wrote them,
    /// so a Cirrus on another computer (another project) can still tell the folder is Cirrus's copy of iCloud Drive.
    /// </summary>
    internal const string RoleKey = "cirrusRole", RoleFromICloud = "from-icloud";

    public Sources Source { get; }
    public Target To { get; }
    public MigrationOptions Options { get; }
    internal JournalStore<MigrationManifest, MigrationOp> Store { get; }
    readonly string _staging;
    readonly string _stateDir;
    readonly string _sourceTag;
    readonly object _statsLock = new();
    /// <summary>Identifies this account pair's runs (one at a time).</summary>
    public string RunKey => Store.BasePath;
    public bool IsRunning => MoveRuns.IsRunning(RunKey);
    /// <summary>Test hooks.</summary>
    internal Func<string, long?> FreeSpace { get; set; } = VolumeInfo.FreeSpace;
    internal Func<string, bool> IsCloudOnly { get; set; } = p => LocalFiles.GetCloudState(p) == LocalFiles.CloudState.CloudOnly;

    internal static string Hex(string s) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(s)));
    internal static string StoreName(string icloudKey, string googleID) => Hex(icloudKey + "→" + googleID)[..24];

    /// <summary><paramref name="stateDir"/> holds the manifest (one per iCloud account + Google account pair); <paramref name="stagingDir"/> is scratch space.</summary>
    public MigrationEngine(Sources sources, Target target, MigrationOptions options, string stateDir, string stagingDir)
    {
        Source = sources; To = target; Options = options; _stateDir = stateDir;
        _sourceTag = Hex("cirrus-source|" + sources.Key)[..20];
        var name = StoreName(sources.Key, target.AccountID);
        Store = JournalStores.Get<MigrationManifest, MigrationOp>(stateDir, name);
        _staging = Path.Combine(stagingDir, name);   // per pair: runs for other pairs never clear each other's files
    }

    static string Dir(string p) { var i = p.LastIndexOf('/'); return i < 0 ? "" : p[..i]; }
    static string Last(string p) { var i = p.LastIndexOf('/'); return i < 0 ? p : p[(i + 1)..]; }
    static string S(int n) => n == 1 ? "" : "s";

    // MARK: Evaluate

    public async Task<Evaluation> EvaluateAsync(Action<string>? progress, CancellationToken ct = default)
    {
        var ev = new Evaluation();
        var api = To.Api;
        ev.DriveEnabled = Options.IncludeDrive && (Source.Drive is not null || Source.NativeDriveRoot is not null) && api.Has(GoogleScopes.DriveFile);
        ev.PhotosEnabled = Options.IncludePhotos && Source.Photos is not null && api.Has(GoogleScopes.PhotosAppend);
        if (Options.IncludeDrive && !api.Has(GoogleScopes.DriveFile))
            ev.Warnings.Add("Google Drive access wasn’t granted, so iCloud Drive is left out. Connect Google again and tick the Drive box to include it.");
        if (Options.IncludePhotos && !api.Has(GoogleScopes.PhotosAppend))
            ev.Warnings.Add("Google Photos access wasn’t granted, so photos are left out. Connect Google again and tick the Photos box to include them.");
        if (api.Has(GoogleScopes.DriveFile))
        {
            progress?.Invoke("Checking your Google storage…");
            var (user, quota) = await To.Drive.AboutAsync(ct).ConfigureAwait(false);
            ev.User = user;
            ev.Quota = quota;
        }
        if (Source.Storage is { } s) { progress?.Invoke("Reading iCloud storage…"); try { ev.ICloud = await s().ConfigureAwait(false); } catch { } }
        if (ev.DriveEnabled) await EvaluateDriveAsync(ev, progress, ct).ConfigureAwait(false);
        if (ev.PhotosEnabled && Source.Photos is { } pb) await EvaluatePhotosAsync(ev, pb, progress, ct).ConfigureAwait(false);

        // Temporary space on this PC: each file passes through it once, Concurrency at a time.
        var stagedDrive = Source.Drive is not null && ev.DrivePending.Count > 0 ? ev.DrivePending.Max(i => i.Size) : 0;
        var largest = Math.Max(stagedDrive, ev.PhotoPending.Count > 0 ? ev.PhotoPending.Max(i => i.Size) : 0);
        ev.StagingNeeded = largest > 0 ? largest * Math.Max(1, Options.Concurrency) + (256L << 20) : 0;
        Directory.CreateDirectory(_staging);
        ev.StagingFree = FreeSpace(_staging) ?? long.MaxValue;
        MeasureLocal(ev);
        AddWarnings(ev);
        return ev;
    }

    static bool SameVolume(string a, string b)
    {
        try { return string.Equals(Path.GetPathRoot(Path.GetFullPath(a)), Path.GetPathRoot(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }

    /// <summary>
    /// iCloud for Windows source: reading a file that is only in iCloud makes iCloud for Windows download it to this PC,
    /// where it stays. Those bytes must fit on that drive (with the staging space when it's the same drive).
    /// </summary>
    void MeasureLocal(Evaluation ev)
    {
        ev.LocalNeeded = 0;
        ev.LocalFree = long.MaxValue;
        if (Source.Drive is not null || Source.NativeDriveRoot is not { } root || ev.CloudOnlyFiles == 0) return;
        long bytes = 0;
        foreach (var i in ev.DrivePending) if (ev.Sides.ElementAtOrDefault(i.Side) is LocalSide ls && IsCloudOnly(ls.PathFor(i.SourceRel))) bytes += i.Size;
        ev.LocalNeeded = bytes + bytes / 100 + (SameVolume(root, _staging) ? ev.StagingNeeded : 0);
        ev.LocalFree = FreeSpace(root) ?? long.MaxValue;
    }

    async Task EvaluateDriveAsync(Evaluation ev, Action<string>? progress, CancellationToken ct)
    {
        if (Store.Read(m => m.Root) is { } id)
        {
            progress?.Invoke("Checking the Google Drive folder…");
            var f = await To.Drive.GetAsync(id, ct).ConfigureAwait(false);
            if (f is null || f.Trashed)
            {
                Store.Apply(new MigrationOp.ResetDrive());
                ev.Warnings.Add($"The Google Drive folder from an earlier move was removed or is in Google Drive’s trash, so iCloud Drive will be copied again into a new “{Options.FolderName}” folder.");
            }
        }
        if (Store.Read(m => m.Root) is null)
        {
            // The local record can be missing (another PC, cleared data): adopt this account's folder if Cirrus made one.
            var mine = (await To.Drive.ChildrenAsync("root", ct).ConfigureAwait(false))
                .Where(f => f.IsFolder && f.AppProperties.GetValueOrDefault(SourceKey) == _sourceTag).ToList();
            if (mine.Count > 0)
            {
                progress?.Invoke("Matching files already in Google Drive…");
                await ReconcileAsync(mine[0], ct).ConfigureAwait(false);
            }
        }
        var sides = new List<ISyncSide>();
        if (Source.Drive is { } d) sides.Add(new DriveSide(d, d.RootID, "iCloud Drive", Options.Excludes));
        else if (Source.NativeDriveRoot is { } root) sides.Add(new LocalSide(root, Options.Excludes));
        var m = Store.Snapshot();
        var folders = new HashSet<string>(StringComparer.Ordinal);
        int fromGoogle = 0;
        for (int i = 0; i < sides.Count; i++)
        {
            progress?.Invoke("Scanning iCloud Drive…");
            var entries = await sides[i].ScanAsync(n => progress?.Invoke($"Scanning iCloud Drive… {n} items"), ct).ConfigureAwait(false);
            foreach (var (rel, e) in entries)
            {
                if (rel.Equals(Options.FromGoogleFolder, StringComparison.OrdinalIgnoreCase) || rel.StartsWith(Options.FromGoogleFolder + "/", StringComparison.OrdinalIgnoreCase))
                {
                    if (!e.IsDir) fromGoogle++;
                    continue;
                }
                if (e.IsDir) { folders.Add(rel); continue; }
                ev.DriveFiles++;
                ev.DriveBytes += e.Size;
                if (e.Size > GoogleDrive.MaxFileSize)
                {
                    ev.Skipped.Add(new MigrationSkipped(rel, e.Size, "Larger than Google Drive’s 5 TB limit"));
                    continue;
                }
                for (var dir = Dir(rel); dir.Length > 0; dir = Dir(dir)) folders.Add(dir);
                var item = new DriveItem(rel, i, rel, e.Size, e.Mtime);
                ev.DriveItems.Add(item);
                if (NeedsUpload(item, m)) ev.DrivePending.Add(item);
            }
        }
        if (fromGoogle > 0)
            ev.Warnings.Add($"“{Options.FromGoogleFolder}” ({fromGoogle} file{S(fromGoogle)}) is left out: Cirrus copied it from Google, so it’s there already.");
        ev.Sides = sides;
        ev.CloudOnlyFiles = 0;
        foreach (var i in ev.DrivePending) if (sides.ElementAtOrDefault(i.Side) is LocalSide ls && IsCloudOnly(ls.PathFor(i.SourceRel))) ev.CloudOnlyFiles++;
        ev.DriveFolders = folders.ToList();
        ev.DriveFolders.Sort(SyncPlanner.PathOrder);
        ev.DriveItems.Sort((a, b) => SyncPlanner.PathOrder(a.Rel, b.Rel));
        ev.DrivePending.Sort((a, b) => SyncPlanner.PathOrder(a.Rel, b.Rel));
    }

    bool NeedsUpload(DriveItem item, MigrationManifest m)
    {
        if (!m.Files.TryGetValue(item.Rel, out var done)) return true;
        if (done.Size == item.Size && Math.Abs(done.Mtime - item.Mtime) <= 2) return false;
        return Options.UpdateChanged;
    }

    /// <summary>Rebuilds the record from what Cirrus's folder already holds in Google Drive.</summary>
    async Task ReconcileAsync(GDriveFile root, CancellationToken ct)
    {
        Store.Apply(new MigrationOp.Root(root.Id, root.Name));
        var frontier = new Stack<(string Id, string Prefix)>();
        frontier.Push((root.Id, ""));
        while (frontier.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var (id, prefix) = frontier.Pop();
            foreach (var f in await To.Drive.ChildrenAsync(id, ct).ConfigureAwait(false))
            {
                var rel = prefix.Length == 0 ? f.Name : prefix + "/" + f.Name;
                if (f.IsFolder) { Store.Apply(new MigrationOp.Folder(rel, f.Id)); frontier.Push((f.Id, rel)); }
                else Store.Apply(new MigrationOp.File(rel, new(f.Id, f.Size, f.Modified is { } mod ? mod.ToUnixTimeMilliseconds() / 1000.0 : 0)));
            }
        }
        Store.Compact();
    }

    /// <summary>name|size of every photo the Google → iCloud direction copied for this pair of accounts.</summary>
    HashSet<string> ReceivedFromGoogle()
    {
        var back = JournalStores.Get<ImportManifest, ImportOp>(_stateDir, ImportEngine.StoreName(To.AccountID, Source.Key));
        return back.Read(m => m.Photos.Values.Select(p => $"{p.Name.ToLowerInvariant()}|{p.Size}").ToHashSet(StringComparer.Ordinal));
    }

    List<(PhotoResourceKind Kind, string Name, long Size)> PhotoFiles(PhotoAsset a)
    {
        var stem = Path.GetFileNameWithoutExtension(a.Filename);
        static string Ext(PhotoResource r, string fallback) { var e = Path.GetExtension(r.Filename).TrimStart('.'); return e.Length == 0 ? fallback : e; }
        var output = new List<(PhotoResourceKind, string, long)> { (PhotoResourceKind.Original, a.Filename, a.Resource(PhotoResourceKind.Original)?.Size ?? a.Size) };
        if (Options.IncludeLive && a.Resource(PhotoResourceKind.LiveVideo) is { } lv) output.Add((PhotoResourceKind.LiveVideo, stem + "." + Ext(lv, "MOV"), lv.Size));
        if (Options.IncludeEdited && a.Resource(PhotoResourceKind.Edited) is { } ed) output.Add((PhotoResourceKind.Edited, stem + "-edited." + Ext(ed, "JPG"), ed.Size));
        if (Options.IncludeRAW && a.Resource(PhotoResourceKind.Alternate) is { } alt)
        {
            var e = Ext(alt, "DNG");
            var name = e.Equals(Path.GetExtension(a.Filename).TrimStart('.'), StringComparison.OrdinalIgnoreCase) ? stem + "-alt." + e : stem + "." + e;
            output.Add((PhotoResourceKind.Alternate, name, alt.Size));
        }
        return output;
    }

    async Task EvaluatePhotosAsync(Evaluation ev, IPhotosBackend pb, Action<string>? progress, CancellationToken ct)
    {
        var m = Store.Snapshot();
        var titles = new HashSet<string>(StringComparer.Ordinal);
        string Unique(string t)
        {
            var name = t; var n = 2;
            while (titles.Contains(name.ToLowerInvariant())) { name = $"{t} ({n})"; n++; }
            titles.Add(name.ToLowerInvariant());
            return name;
        }
        foreach (var lib in await pb.LibrariesAsync(ct).ConfigureAwait(false))
        {
            if (lib.IsShared && !Options.IncludeSharedLibrary) continue;
            var albums = await pb.AlbumsAsync(lib, ct).ConfigureAwait(false);
            var sourcesList = new List<PhotoAlbum>();
            if (albums.FirstOrDefault(a => a.IsAllPhotos || a.Id == "smart:all") is { } all) sourcesList.Add(all);
            if (Options.IncludeHidden && albums.FirstOrDefault(a => a.Id == "smart:Hidden" || (a.Name == "Hidden" && a.Kind == PhotoAlbumKind.Smart)) is { } h) sourcesList.Add(h);
            var assets = new List<PhotoAsset>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var src in sourcesList)
            {
                var label = src.Name;
                int count = 0;
                var list = await pb.AssetsAsync(src, lib, (batch, total) =>
                {
                    var c = Interlocked.Add(ref count, batch.Count);
                    progress?.Invoke($"Listing {label}… {c}" + (total is { } t ? $" of {t}" : ""));
                }, ct).ConfigureAwait(false);
                foreach (var a in list) if (seen.Add(a.Id)) assets.Add(a);
            }
            // Photos Cirrus brought in from Google Photos aren't sent back.
            // Every album of that name counts (an older run, or the user, may have made a second one).
            var backs = albums.Where(a => a.Kind == PhotoAlbumKind.Album && a.Name == Options.FromGoogleAlbum).ToList();
            if (backs.Count > 0)
            {
                var ids = new HashSet<string>(StringComparer.Ordinal);
                try { foreach (var back in backs) ids.UnionWith((await pb.AssetsAsync(back, lib, null, ct).ConfigureAwait(false)).Select(a => a.Id)); }
                catch (Exception e) when (!IsCancel(e))
                {
                    // Without it Cirrus can't tell which photos came from Google: never guess (they'd be sent back).
                    throw SyncException.Unavailable($"Couldn’t read the “{Options.FromGoogleAlbum}” album ({e.Message}), so Cirrus can’t tell which photos came from Google. Select Check Space again.");
                }
                var before = assets.Count;
                assets.RemoveAll(a => ids.Contains(a.Id));
                var n = before - assets.Count;
                if (n > 0) ev.Warnings.Add($"{n} photo{S(n)} in “{Options.FromGoogleAlbum}” {(n == 1 ? "is" : "are")} left out: {(n == 1 ? "it" : "they")} came from Google Photos.");
            }
            // Photos the Google → iCloud direction brought in (by name and size), even when they're not in that album.
            var received = ReceivedFromGoogle();
            if (received.Count > 0)
            {
                var n = assets.RemoveAll(a => received.Contains($"{a.Filename.ToLowerInvariant()}|{a.Resource(PhotoResourceKind.Original)?.Size ?? a.Size}"));
                if (n > 0) ev.Warnings.Add($"{n} photo{S(n)} that Cirrus copied from Google Photos {(n == 1 ? "is" : "are")} left out.");
            }
            ev.AssetCount += assets.Count;
            var primary = new Dictionary<string, string>(StringComparer.Ordinal);   // asset id → key of its main file
            foreach (var a in assets.OrderBy(a => a.Created ?? DateTimeOffset.MinValue))
            {
                foreach (var (kind, name, size) in PhotoFiles(a))
                {
                    if (GooglePhotos.Problem(name, size) is { } why) { ev.Skipped.Add(new MigrationSkipped(name, size, why)); continue; }
                    var key = $"{lib.Id}|{a.Id}|{kind}";
                    primary.TryAdd(a.Id, key);
                    ev.PhotoFiles++;
                    ev.PhotoBytes += size;
                    var item = new PhotoItem(key, a, kind, name, size, GooglePhotos.MediaFor(name) == GooglePhotos.Media.Video);
                    ev.PhotoItems.Add(item);
                    if (!m.Photos.ContainsKey(key)) ev.PhotoPending.Add(item);
                }
            }
            var suffix = lib.IsShared ? " (Shared Library)" : "";
            void AddPlan(string key, string title, List<string> members)
            {
                if (members.Count == 0) return;
                // Google albums hold 20,000 items at most.
                var parts = members.Chunk(GooglePhotos.AlbumLimit).ToList();
                for (int i = 0; i < parts.Count; i++)
                    ev.Albums.Add(new AlbumPlan(i == 0 ? key : $"{key}#{i + 1}", Unique(i == 0 ? title : $"{title} (part {i + 1})"), parts[i].ToList()));
            }
            if (Options.Albums)
                foreach (var al in albums.Where(a => a.Kind == PhotoAlbumKind.Album))
                {
                    progress?.Invoke($"Reading album “{al.Name}”…");
                    List<PhotoAsset> list;
                    try { list = await pb.AssetsAsync(al, lib, null, ct).ConfigureAwait(false); }
                    catch (OperationCanceledException) { throw; }
                    catch { list = []; }
                    AddPlan($"{lib.Id}|{al.Id}", al.Name + suffix, list.Select(x => primary.GetValueOrDefault(x.Id)).OfType<string>().ToList());
                }
            if (Options.FavoritesAlbum)
                AddPlan($"{lib.Id}|favorites", "Favorites from iCloud" + suffix, assets.Where(a => a.IsFavorite).Select(x => primary.GetValueOrDefault(x.Id)).OfType<string>().ToList());
        }
        foreach (var plan in ev.Albums)
        {
            var added = m.Albums.TryGetValue(plan.Key, out var al) ? al.Added : [];
            ev.AlbumAddsPending += plan.Members.Count(k => !added.Contains(k));
        }
    }

    void AddWarnings(Evaluation ev)
    {
        if (!ev.FitsGoogle && ev.GoogleFree is { } free)
            ev.Warnings.Add($"Not enough Google storage: this move needs {ev.RequiredGoogle.ByteString()} (with 1 % headroom) but your Google account has {free.ByteString()} free — Drive, Gmail and Photos share it. Free up space, add Google storage, or leave something out.");
        if (!ev.FitsStaging)
            ev.Warnings.Add($"Cirrus passes each file through a temporary folder on this PC and needs {ev.StagingNeeded.ByteString()} free there; only {ev.StagingFree.ByteString()} is available.");
        if (ev.CloudOnlyFiles > 0)
            ev.Warnings.Add(ev.FitsLocal
                ? $"{ev.CloudOnlyFiles:N0} file{S(ev.CloudOnlyFiles)} {(ev.CloudOnlyFiles == 1 ? "is" : "are")} only in iCloud: iCloud for Windows downloads {(ev.CloudOnlyFiles == 1 ? "it" : "them")} to this PC to send {(ev.CloudOnlyFiles == 1 ? "it" : "them")}, and keeps {(ev.CloudOnlyFiles == 1 ? "it" : "them")} there (Free Up Space in Explorer releases {(ev.CloudOnlyFiles == 1 ? "it" : "them")} again)."
                : $"Not enough space on this PC: {ev.CloudOnlyFiles:N0} file{S(ev.CloudOnlyFiles)} {(ev.CloudOnlyFiles == 1 ? "is" : "are")} only in iCloud and iCloud for Windows would download {ev.LocalNeeded.ByteString()} to send {(ev.CloudOnlyFiles == 1 ? "it" : "them")}, but only {ev.LocalFree.ByteString()} is free. Free up space, or sign in with your Apple ID in Cirrus and move from that account instead (nothing is downloaded to this PC then).");
        if (ev.DrivePendingBytes > GoogleDrive.DailyUploadLimit)
            ev.Warnings.Add("Google accepts about 750 GB of uploads a day. This move is bigger, so it pauses when Google says so; run it again the next day and it continues where it stopped.");
        var requests = ev.PhotoRequests;
        if (requests > 9_000)
            ev.Warnings.Add($"Google Photos allows 10,000 API requests a day per Google Cloud project, and this move needs about {requests:N0}. It will take about {(requests + 9_499) / 9_500} days: run it once a day and it continues each time.");
        var live = ev.PhotoPending.Count(p => p.Kind == PhotoResourceKind.LiveVideo);
        if (live > 0) ev.Warnings.Add($"Live Photos become a still photo plus a separate short video in Google Photos ({live} video{S(live)}).");
        if (Options.IncludeHidden && ev.PhotosEnabled)
            ev.Warnings.Add("Hidden photos will be visible in Google Photos: Google’s Locked Folder can’t be filled by other apps.");
        if (ev.PhotosEnabled && ev.PhotoPending.Count > 0)
            ev.Warnings.Add("Google Photos stores these at original quality, so they count toward your Google storage.");
        if (ev.Skipped.Count > 0)
            ev.Warnings.Add($"{ev.Skipped.Count} file{(ev.Skipped.Count == 1 ? " is" : "s are")} skipped because Google can’t store {(ev.Skipped.Count == 1 ? "it" : "them")} (listed below).");
    }

    // MARK: Run

    public static bool IsCancel(Exception e) =>
        e is OperationCanceledException || e is GoogleException { Kind: GoogleErrorKind.Cancelled } || e is ICloudException { Kind: ICloudErrorKind.Cancelled };

    internal static GoogleException? Stops(Exception e) => e is GoogleException
    {
        Kind: GoogleErrorKind.StorageFull or GoogleErrorKind.DailyLimit or GoogleErrorKind.Reconnect or GoogleErrorKind.MissingScope or GoogleErrorKind.RateLimited or GoogleErrorKind.NotConfigured,
    } g ? g : null;

    internal static Task ForEachAsync<T>(IEnumerable<T> items, int limit, CancellationToken ct, Func<T, CancellationToken, Task> body) =>
        Parallel.ForEachAsync(items, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, limit), CancellationToken = ct }, async (x, t) => await body(x, t).ConfigureAwait(false));

    internal static void ResetStaging(string dir)
    {
        // Leftovers of an interrupted run: Cirrus's own temporary copies.
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch (Exception e) { Log.Status("couldn’t clear the move’s temporary folder: " + e.GetType().Name); }
        Paths.PrivateDir(dir);
    }

    internal static void RemoveStaging(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
        // The shared parent goes too once no other pair uses it (non-recursive: only when empty).
        try { if (Path.GetDirectoryName(dir) is { } parent && Directory.Exists(parent) && !Directory.EnumerateFileSystemEntries(parent).Any()) Directory.Delete(parent); } catch { }
    }

    void Mutate(Report r, Action<Report> f) { lock (_statsLock) f(r); }

    public async Task<Report> RunAsync(Evaluation ev, Action<RunProgress>? progress, CancellationToken ct = default)
    {
        if (!MoveRuns.TryBegin(RunKey)) throw MoveRuns.Busy();
        try { return await RunLockedAsync(ev, progress, ct).ConfigureAwait(false); }
        finally { MoveRuns.End(RunKey); }
    }

    async Task<Report> RunLockedAsync(Evaluation ev, Action<RunProgress>? progress, CancellationToken ct)
    {
        // The limits are checked again against what's still left (a Retry reuses an older check).
        var m = Store.Snapshot();
        var drive = ev.DriveEnabled ? ev.DriveItems.Where(i => NeedsUpload(i, m)).ToList() : [];
        var photos = ev.PhotosEnabled ? ev.PhotoItems.Where(p => !m.Photos.ContainsKey(p.Key)).ToList() : [];
        var remaining = drive.Sum(i => i.Size) + photos.Sum(p => p.Size);
        if (To.Api.Has(GoogleScopes.DriveFile) && remaining > 0)
        {
            try { ev.Quota = (await To.Drive.AboutAsync(ct).ConfigureAwait(false)).Quota; }
            catch (Exception e) when (!IsCancel(e) && Stops(e) is null) { Log.Status("move: storage re-check failed (" + e.GetType().Name + ")"); }
        }
        if (ev.GoogleFree is { } gfree && gfree < remaining + remaining / 100)
            throw SyncException.Unavailable($"Not enough Google storage for this move: it needs {(remaining + remaining / 100).ByteString()}, {gfree.ByteString()} is free.");
        Directory.CreateDirectory(_staging);
        ev.StagingFree = FreeSpace(_staging) ?? long.MaxValue;
        if (!ev.FitsStaging) throw SyncException.NotEnoughSpace(ev.StagingNeeded, ev.StagingFree);
        MeasureLocal(ev);
        if (!ev.FitsLocal) throw SyncException.NotEnoughSpace(ev.LocalNeeded, ev.LocalFree);
        ResetStaging(_staging);
        var report = new Report { Skipped = ev.Skipped.ToList() };
        try
        {
            // Each byte is counted twice: once coming down from iCloud, once going up to Google.
            var bytes = (drive.Sum(i => i.Size) + photos.Sum(p => p.Size)) * 2;
            var ctx = new MoveRunContext(drive.Count + photos.Count, bytes, progress);
            if (ev.DriveEnabled)
            {
                try { await RunDriveAsync(ev, drive, ctx, report, ct).ConfigureAwait(false); }
                catch (Exception e) when (!IsCancel(e) && Stops(e) is { } s) { ctx.Stop(s); }
            }
            var failed = ctx.Failed;
            var stopped = ctx.Stopped;
            if (ev.PhotosEnabled && stopped is not { Kind: GoogleErrorKind.StorageFull or GoogleErrorKind.Reconnect })
            {
                // Drive's daily cap doesn't apply to Photos, so a Drive stop for that reason still lets Photos run.
                var photoCtx = stopped is null ? ctx : new MoveRunContext(photos.Count, photos.Sum(p => p.Size) * 2, progress);
                try
                {
                    await RunPhotosAsync(photos, photoCtx, report, ct).ConfigureAwait(false);
                    if (photoCtx.Stopped is null) await RunAlbumsAsync(ev, photoCtx, report, ct).ConfigureAwait(false);
                }
                catch (Exception e) when (!IsCancel(e) && Stops(e) is { } s) { photoCtx.Stop(s); }
                if (!ReferenceEquals(photoCtx, ctx))
                {
                    failed.AddRange(photoCtx.Failed);
                    if (photoCtx.Stopped is { } ps) failed.Add("Google Photos: " + ps.Message);
                }
                else { failed = ctx.Failed; stopped = ctx.Stopped; }
            }
            report.Failed = failed;
            report.Stopped = stopped?.Message;
            report.DriveFolderID = Store.Read(x => x.Root);
            ctx.Phase("Finished");
            return report;
        }
        catch (Exception e) when (IsCancel(e)) { throw new OperationCanceledException("The move was stopped.", e, ct); }
        finally
        {
            RemoveStaging(_staging);
            Store.Compact();
        }
    }

    // MARK: Drive

    async Task<string> EnsureRootAsync(Report report, CancellationToken ct)
    {
        if (Store.Read(m => m.Root) is { } id) return id;
        var tagged = (await To.Drive.ChildrenAsync("root", ct).ConfigureAwait(false)).Where(f => f.IsFolder && f.AppProperties.ContainsKey(SourceKey)).ToList();
        if (tagged.FirstOrDefault(f => f.AppProperties[SourceKey] == _sourceTag) is { } mine)
        {
            Store.Apply(new MigrationOp.Root(mine.Id, mine.Name));
            return mine.Id;
        }
        var name = Options.FolderName;
        if (tagged.Any(f => f.Name == name)) name += $" ({Source.Title})";
        var created = await To.Drive.CreateFolderAsync(name, "root", new Dictionary<string, string> { [SourceKey] = _sourceTag }, ct,
            properties: new Dictionary<string, string> { [RoleKey] = RoleFromICloud }).ConfigureAwait(false);
        Store.Apply(new MigrationOp.Root(created.Id, created.Name));
        Mutate(report, r => r.FoldersCreated++);
        return created.Id;
    }

    /// <summary>Creates missing folders parents-first (sequentially, so none is made twice).</summary>
    async Task EnsureFoldersAsync(IEnumerable<string> rels, string root, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        var listed = new Dictionary<string, List<GDriveFile>>(StringComparer.Ordinal);
        var createdHere = new HashSet<string>(StringComparer.Ordinal);
        var sorted = rels.ToList();
        sorted.Sort(SyncPlanner.PathOrder);
        foreach (var rel in sorted)
        {
            ct.ThrowIfCancellationRequested();
            if (Store.Read(m => m.Folders.ContainsKey(rel))) continue;
            var parentRel = Dir(rel);
            var parent = parentRel.Length == 0 ? root : Store.Read(m => m.Folders.GetValueOrDefault(parentRel));
            if (parent is null) continue;
            var name = Last(rel);
            // A folder made just before a crash isn't in the record yet; reuse it instead of making a twin.
            if (!createdHere.Contains(parentRel))
            {
                if (!listed.TryGetValue(parent, out var kids)) listed[parent] = kids = await To.Drive.ChildrenAsync(parent, ct).ConfigureAwait(false);
                if (kids.FirstOrDefault(f => f.IsFolder && f.Name == name) is { } existing) { Store.Apply(new MigrationOp.Folder(rel, existing.Id)); continue; }
            }
            ctx.Phase($"Creating folder {name}…");
            var f = await To.Drive.CreateFolderAsync(name, parent, ct: ct).ConfigureAwait(false);
            Store.Apply(new MigrationOp.Folder(rel, f.Id));
            createdHere.Add(rel);
            Mutate(report, r => r.FoldersCreated++);
        }
    }

    async Task RunDriveAsync(Evaluation ev, List<DriveItem> items, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        ctx.Phase("Preparing Google Drive…");
        var root = await EnsureRootAsync(report, ct).ConfigureAwait(false);
        report.DriveFolderID = root;
        var needed = new HashSet<string>(ev.DriveFolders, StringComparer.Ordinal);
        foreach (var i in items) for (var d = Dir(i.Rel); d.Length > 0; d = Dir(d)) needed.Add(d);
        await EnsureFoldersAsync(needed, root, ctx, report, ct).ConfigureAwait(false);
        await ForEachAsync(items, Options.Concurrency, ct, async (item, t) =>
        {
            if (ctx.Stopped is not null) return;
            try { await UploadDriveItemAsync(item, ev, root, ctx, report, t).ConfigureAwait(false); }
            catch (Exception e) when (!IsCancel(e))
            {
                if (Stops(e) is { } s) { ctx.Stop(s); return; }
                ctx.Fail(item.Rel, e);
            }
            ctx.DoneFile();
        }).ConfigureAwait(false);
    }

    async Task UploadDriveItemAsync(DriveItem item, Evaluation ev, string root, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        var parentRel = Dir(item.Rel);
        var parent = (parentRel.Length == 0 ? root : Store.Read(m => m.Folders.GetValueOrDefault(parentRel)))
            ?? throw SyncException.Unavailable("Its folder couldn’t be created in Google Drive.");
        var name = Last(item.Rel);
        ctx.Phase($"Downloading {name} from iCloud…");
        var side = ev.Sides[item.Side];
        var down = new ByteMark();
        string local;
        bool temporary;
        if (side is DriveSide ds && ds.Node(item.SourceRel) is { } node)
        {
            var dir = Path.Combine(_staging, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            local = Path.Combine(dir, Paths.SafeName(node.Name));
            temporary = true;
            try { await ds.Backend.DownloadAsync(node, local, (d, _) => ctx.AddBytes(down.Advance(d)), ct).ConfigureAwait(false); }
            catch { try { Directory.Delete(dir, true); } catch { } throw; }
        }
        else
        {
            var r = await side.FetchAsync(item.SourceRel, (d, _) => ctx.AddBytes(down.Advance(d)), ct).ConfigureAwait(false);
            local = r.Path;
            temporary = r.IsTemporary;
        }
        try
        {
            ctx.AddBytes(down.Advance(item.Size));   // top up (local files report no download progress)
            var size = new FileInfo(local).Length;
            var up = new ByteMark();
            void OnUp(long d, long _) => ctx.AddBytes(up.Advance(d));
            var mtime = DateTimeOffset.FromUnixTimeMilliseconds((long)(item.Mtime * 1000));
            ctx.Phase($"Uploading {name} to Google Drive…");
            async Task<GDriveFile> Fresh()
            {
                var s = await To.Drive.StartUploadAsync(name, parent, size, mtime, ct: ct).ConfigureAwait(false);
                Store.Apply(new MigrationOp.DriveUpload(item.Rel, new(s.Url, size, item.Mtime, s.Started)));
                return await To.Drive.UploadAsync(local, s, resume: false, OnUp, ct).ConfigureAwait(false);
            }
            GDriveFile file;
            var u = Store.Read(m => m.DriveUploads.GetValueOrDefault(item.Rel));
            if (u is not null && u.Total == size && Math.Abs(u.Mtime - item.Mtime) <= 2 && DateTimeOffset.UtcNow - u.Started < TimeSpan.FromDays(6))
            {
                try
                {
                    file = await To.Drive.UploadAsync(local, new DriveUploadSession(u.Url, u.Total, u.Started), resume: true, OnUp, ct).ConfigureAwait(false);
                    Mutate(report, r => r.Resumed++);
                }
                catch (GoogleException e) when (e.Kind == GoogleErrorKind.UploadExpired) { file = await Fresh().ConfigureAwait(false); }
            }
            else
            {
                try { file = await Fresh().ConfigureAwait(false); }
                catch (GoogleException e) when (e.Kind == GoogleErrorKind.UploadExpired) { file = await Fresh().ConfigureAwait(false); }
            }
            var old = Store.Read(m => m.Files.GetValueOrDefault(item.Rel));
            Store.Apply(new MigrationOp.File(item.Rel, new(file.Id, size, item.Mtime)));
            Store.Apply(new MigrationOp.DriveUpload(item.Rel, null));
            if (old is not null && old.Id != file.Id)
            {
                // Upload-then-replace: the earlier copy goes to Google Drive's trash, never deleted.
                try { await To.Drive.TrashAsync(old.Id, ct).ConfigureAwait(false); }
                catch (Exception e) when (!IsCancel(e)) { Log.Status("couldn’t move the previous copy to Google Drive’s trash: " + e.GetType().Name); }
                Mutate(report, r => { r.DriveUpdated++; r.DriveBytes += size; });
            }
            else Mutate(report, r => { r.DriveCopied++; r.DriveBytes += size; });
        }
        finally
        {
            if (temporary) { try { Directory.Delete(Path.GetDirectoryName(local)!, true); } catch { } }   // Cirrus's own staging folder
        }
    }

    // MARK: Photos

    async Task RunPhotosAsync(List<PhotoItem> items, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        if (items.Count == 0) return;
        foreach (var chunk in items.Chunk(GooglePhotos.BatchLimit))
        {
            ct.ThrowIfCancellationRequested();
            if (ctx.Stopped is not null) return;
            var ready = new System.Collections.Concurrent.ConcurrentDictionary<string, GooglePhotos.NewItem>(StringComparer.Ordinal);
            await ForEachAsync(chunk, Options.Concurrency, ct, async (item, t) =>
            {
                if (ctx.Stopped is not null) return;
                try { ready[item.Key] = await UploadPhotoAsync(item, ctx, report, t).ConfigureAwait(false); }
                catch (Exception e) when (!IsCancel(e))
                {
                    if (Stops(e) is { } s) { ctx.Stop(s); return; }
                    ctx.Fail(item.FileName, e);
                    ctx.DoneFile();
                }
            }).ConfigureAwait(false);
            if (ctx.Stopped is not null) return;   // uploaded tokens stay recorded for the next run
            var batch = chunk.Where(i => ready.ContainsKey(i.Key)).Select(i => (Item: i, New: ready[i.Key])).ToList();
            if (batch.Count == 0) continue;
            ctx.Phase($"Adding {batch.Count} item{S(batch.Count)} to Google Photos…");
            List<GooglePhotos.Created> results;
            try { results = await To.Photos.BatchCreateAsync(batch.Select(b => b.New).ToList(), ct: ct).ConfigureAwait(false); }
            catch (Exception e) when (!IsCancel(e))
            {
                if (Stops(e) is { } s) { ctx.Stop(s); return; }
                // The upload tokens stay valid for a day, so the next run retries without uploading again.
                foreach (var (i, _) in batch) { ctx.Fail(i.FileName, e); ctx.DoneFile(); }
                continue;
            }
            for (int k = 0; k < batch.Count && k < results.Count; k++)
            {
                var (item, _) = batch[k];
                var r = results[k];
                Store.Apply(new MigrationOp.Token(item.Key, null));
                if (r.MediaItemID is { } id)
                {
                    Store.Apply(new MigrationOp.Photo(item.Key, new(id, item.Size, item.FileName)));
                    Mutate(report, x => { x.PhotosCreated++; x.PhotosBytes += item.Size; });
                }
                else ctx.Fail(item.FileName, GoogleException.BadResponse(r.Error ?? "Google Photos didn’t create this item."));
                ctx.DoneFile();
            }
        }
    }

    async Task<GooglePhotos.NewItem> UploadPhotoAsync(PhotoItem item, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        var known = Store.Read(m => m.Tokens.GetValueOrDefault(item.Key));
        if (known is not null && known.Size == item.Size && DateTimeOffset.UtcNow - known.At < TimeSpan.FromHours(20))
        {
            ctx.AddBytes(item.Size * 2);
            return new GooglePhotos.NewItem(known.Value, item.FileName, known.Description);
        }
        var backend = Source.Photos ?? throw SyncException.Unavailable("Photos isn’t available.");
        var dir = Path.Combine(_staging, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, Paths.SafeName(item.FileName));
            ctx.Phase($"Downloading {item.FileName} from iCloud…");
            var down = new ByteMark();
            await backend.ExportAsync(item.Asset, item.Kind, file, (d, _) => ctx.AddBytes(down.Advance(Math.Min(d, item.Size))), ct).ConfigureAwait(false);
            ctx.AddBytes(down.Advance(item.Size));
            var size = new FileInfo(file).Length;
            var dated = MediaDates.HasEmbeddedDate(file, item.IsVideo);
            var desc = dated ? null : MediaDates.Description(item.Asset.Created);
            ctx.Phase($"Uploading {item.FileName} to Google Photos…");
            var up = new ByteMark();
            void OnUp(long d, long _) => ctx.AddBytes(up.Advance(Math.Min(d, item.Size)));
            string? token = null;
            if (size <= GooglePhotos.RawLimit) token = await To.Photos.UploadRawAsync(file, item.FileName, OnUp, ct).ConfigureAwait(false);
            else
            {
                var s = Store.Read(m => m.PhotoUploads.GetValueOrDefault(item.Key));
                if (s is not null && s.Total == size && DateTimeOffset.UtcNow - s.Started < TimeSpan.FromDays(6))
                {
                    try
                    {
                        token = await To.Photos.UploadResumableAsync(file, s, resume: true, OnUp, ct).ConfigureAwait(false);
                        Mutate(report, r => r.Resumed++);
                    }
                    catch (GoogleException e) when (e.Kind == GoogleErrorKind.UploadExpired) { token = null; }
                }
                if (token is null)
                {
                    var fresh = await To.Photos.StartResumableAsync(item.FileName, size, ct).ConfigureAwait(false);
                    Store.Apply(new MigrationOp.PhotoUpload(item.Key, fresh));
                    token = await To.Photos.UploadResumableAsync(file, fresh, resume: false, OnUp, ct).ConfigureAwait(false);
                }
                Store.Apply(new MigrationOp.PhotoUpload(item.Key, null));
            }
            Store.Apply(new MigrationOp.Token(item.Key, new(token, DateTimeOffset.UtcNow, item.Size, desc)));
            return new GooglePhotos.NewItem(token, item.FileName, desc);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }   // Cirrus's own staging copy
    }

    async Task RunAlbumsAsync(Evaluation ev, MoveRunContext ctx, Report report, CancellationToken ct)
    {
        foreach (var plan in ev.Albums)
        {
            ct.ThrowIfCancellationRequested();
            var m = Store.Snapshot();
            m.Albums.TryGetValue(plan.Key, out var existing);
            var toAdd = plan.Members.Where(k => m.Photos.ContainsKey(k) && !(existing?.Added.Contains(k) ?? false)).ToList();
            if (toAdd.Count == 0) continue;
            ctx.Phase($"Album “{plan.Title}”…");
            var albumID = existing?.Id;
            if (albumID is null)
            {
                albumID = await To.Photos.CreateAlbumAsync(plan.Title, ct).ConfigureAwait(false);
                Store.Apply(new MigrationOp.Album(plan.Key, albumID, plan.Title));
                Mutate(report, r => r.AlbumsCreated++);
            }
            foreach (var part in toAdd.Chunk(GooglePhotos.BatchLimit))
            {
                var ids = part.Select(k => m.Photos[k].Id).ToList();
                try
                {
                    await To.Photos.AddToAlbumAsync(albumID, ids, ct).ConfigureAwait(false);
                    Store.Apply(new MigrationOp.AlbumAdded(plan.Key, part.ToList()));
                    Mutate(report, r => r.AlbumAdds += part.Length);
                }
                catch (Exception e) when (!IsCancel(e) && Stops(e) is null)
                {
                    ctx.Fail($"Album “{plan.Title}”", e);
                    break;
                }
            }
        }
    }
}
