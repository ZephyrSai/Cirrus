using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Cirrus.Core;

/// <summary>
/// icloudpd-style photo export: originals (+ Live Photo video, edits, RAW) into a dated folder layout,
/// incremental via a manifest, file dates set to the capture date, optional album folders.
/// Writes only to the destination folder; never changes anything in iCloud.
/// </summary>
public sealed class PhotoExporter
{
    public sealed record PlannedFile(PhotoAsset Asset, PhotoResourceKind Kind, string Rel, long Size);

    public sealed class Evaluation
    {
        public required PhotoLibraryRef Library { get; init; }
        public int AssetCount { get; init; }
        public List<PlannedFile> Files { get; init; } = [];     // everything that should exist
        public List<PlannedFile> Pending { get; init; } = [];   // what still needs downloading
        public Dictionary<string, List<string>> Albums { get; init; } = [];   // album name → relative paths of primary files
        public long TotalBytes => Files.Sum(f => f.Size);
        public long PendingBytes => Pending.Sum(f => f.Size);
        public long LargestFile => Files.Count == 0 ? 0 : Files.Max(f => f.Size);
    }

    internal sealed class Manifest
    {
        public sealed class Entry { public List<string> Files { get; set; } = []; public DateTimeOffset? Created { get; set; } public bool Favorite { get; set; } public bool Hidden { get; set; } }
        public Dictionary<string, Entry> Assets { get; set; } = [];
    }

    readonly IPhotosBackend _backend;
    readonly PhotoLibraryRef _library;
    readonly string _dest;
    readonly SyncOptions _options;
    readonly PhotoAlbum? _albumFilter;

    public PhotoExporter(IPhotosBackend backend, PhotoLibraryRef library, PhotoAlbum? album, string destination, SyncOptions options)
    {
        _backend = backend; _library = library; _dest = destination; _options = options; _albumFilter = album;
    }

    string ManifestPath => Path.Combine(_dest, ".cirrus", "photos-manifest.json");

    Manifest LoadManifest()
    {
        try { return File.Exists(ManifestPath) ? JsonSerializer.Deserialize<Manifest>(File.ReadAllBytes(ManifestPath)) ?? new() : new(); }
        catch { return new(); }
    }

    void SaveManifest(Manifest m) => AtomicFile.Write(ManifestPath, JsonSerializer.SerializeToUtf8Bytes(m));

    public static string Folder(DateTimeOffset? date, string layout)
    {
        if (layout == "flat" || layout.Length == 0) return "";
        if (date is not { } d) return "Unknown Date";
        var local = d.ToLocalTime();
        return layout.Replace("{yyyy}", local.Year.ToString("0000", CultureInfo.InvariantCulture))
            .Replace("{MM}", local.Month.ToString("00", CultureInfo.InvariantCulture))
            .Replace("{dd}", local.Day.ToString("00", CultureInfo.InvariantCulture));
    }

    static long LocalSize(string path) => File.Exists(path) ? new FileInfo(path).Length : -1;

    static string Suffix(string id) => new string(id.Where(char.IsLetterOrDigit).ToArray()) is var s && s.Length > 6 ? s[^6..] : new string(id.Where(char.IsLetterOrDigit).ToArray());

    public async Task<Evaluation> EvaluateAsync(Action<string>? progress, CancellationToken ct = default)
    {
        var albums = await _backend.AlbumsAsync(_library, ct).ConfigureAwait(false);
        var sources = new List<PhotoAlbum>();
        if (_albumFilter is not null) sources.Add(_albumFilter);
        else
        {
            if (albums.FirstOrDefault(a => a.IsAllPhotos || a.Id == "smart:all") is { } all) sources.Add(all);
            if (_options.IncludeHidden && albums.FirstOrDefault(a => a.Id == "smart:Hidden" || (a.Name == "Hidden" && a.Kind == PhotoAlbumKind.Smart)) is { } h) sources.Add(h);
        }
        var assets = new List<PhotoAsset>();
        var seen = new HashSet<string>();
        foreach (var src in sources)
        {
            int count = 0;
            var list = await _backend.AssetsAsync(src, _library, (batch, total) =>
            {
                var c = Interlocked.Add(ref count, batch.Count);
                progress?.Invoke($"Listing {src.Name}… {c}" + (total is int t ? $" of {t}" : ""));
            }, ct).ConfigureAwait(false);
            foreach (var a in list) if (seen.Add(a.Id)) assets.Add(a);
        }
        var manifest = LoadManifest();
        var taken = new Dictionary<string, string>(StringComparer.Ordinal);   // lowercased rel → asset id
        foreach (var (id, e) in manifest.Assets) foreach (var f in e.Files) taken[f.ToLowerInvariant()] = id;
        var files = new List<PlannedFile>();
        var pending = new List<PlannedFile>();
        foreach (var a in assets.OrderBy(x => x.Created ?? DateTimeOffset.MinValue))
        {
            List<PlannedFile> planned;
            if (manifest.Assets.TryGetValue(a.Id, out var me) && me.Files.Count > 0)
            {
                // Reuse the paths chosen on earlier runs.
                var first = me.Files[0];
                var slash = first.LastIndexOf('/');
                var dir = slash >= 0 ? first[..slash] : "";
                var stem = Path.GetFileNameWithoutExtension(slash >= 0 ? first[(slash + 1)..] : first);
                planned = PlannedFiles(a, dir, stem);
                foreach (var p in planned) taken.TryAdd(p.Rel.ToLowerInvariant(), a.Id);
            }
            else
            {
                var dir = Folder(a.Created, _options.PhotoLayout);
                var stem = Path.GetFileNameWithoutExtension(a.Filename);
                // Suffix the name when any of its files (original, Live .MOV, -edited, RAW) would land on a path that
                // belongs to another asset or to a different file that's already there (not ours: keep it).
                bool Clashes(List<PlannedFile> files) => files.Any(p =>
                    (taken.TryGetValue(p.Rel.ToLowerInvariant(), out var owner) && owner != a.Id) ||
                    (!taken.ContainsKey(p.Rel.ToLowerInvariant()) && LocalSize(Paths.Combine(_dest, WinNames.RelToLocal(p.Rel))) is var size && size >= 0 && (p.Size <= 0 || size != p.Size)));
                planned = PlannedFiles(a, dir, stem);
                if (Clashes(planned)) { stem += "-" + Suffix(a.Id); planned = PlannedFiles(a, dir, stem); }
                for (int n = 2; Clashes(planned) && n < 100; n++) planned = PlannedFiles(a, dir, stem + "-" + n);
                foreach (var p in planned) taken[p.Rel.ToLowerInvariant()] = a.Id;
                manifest.Assets[a.Id] = new Manifest.Entry { Files = planned.Select(p => p.Rel).ToList(), Created = a.Created, Favorite = a.IsFavorite, Hidden = a.IsHidden };
            }
            foreach (var p in planned)
            {
                files.Add(p);
                var size = LocalSize(Paths.Combine(_dest, WinNames.RelToLocal(p.Rel)));
                if (size < 0 || (p.Size > 0 && size != p.Size)) pending.Add(p);
            }
        }
        var albumMap = new Dictionary<string, List<string>>();
        if ((_options.WriteManifest || _options.AlbumFolders) && _albumFilter is null)
        {
            var primary = new Dictionary<string, string>();
            foreach (var f in files.Where(f => f.Kind == PhotoResourceKind.Original)) primary.TryAdd(f.Asset.Id, f.Rel);
            foreach (var al in albums.Where(a => a.Kind is PhotoAlbumKind.Album or PhotoAlbumKind.Shared))
            {
                progress?.Invoke($"Reading album “{al.Name}”…");
                List<PhotoAsset> list;
                try { list = await _backend.AssetsAsync(al, _library, null, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { throw; }
                catch { list = []; }
                albumMap[al.Name] = list.Select(x => primary.GetValueOrDefault(x.Id)).OfType<string>().ToList();
            }
        }
        return new Evaluation { Library = _library, AssetCount = assets.Count, Files = files, Pending = pending, Albums = albumMap };
    }

    List<PlannedFile> PlannedFiles(PhotoAsset a, string dir, string stem)
    {
        string Rel(string name) => dir.Length == 0 ? name : dir + "/" + name;
        var ext = Path.GetExtension(a.Filename).TrimStart('.');
        var output = new List<PlannedFile> { new(a, PhotoResourceKind.Original, Rel(stem + (ext.Length == 0 ? "" : "." + ext)), a.Resource(PhotoResourceKind.Original)?.Size ?? a.Size) };
        if (_options.IncludeLive && a.Resource(PhotoResourceKind.LiveVideo) is { } lv) output.Add(new(a, PhotoResourceKind.LiveVideo, Rel(stem + ".MOV"), lv.Size));
        if (_options.IncludeEdited && a.Resource(PhotoResourceKind.Edited) is { } ed)
        {
            var e = Path.GetExtension(ed.Filename).TrimStart('.');
            output.Add(new(a, PhotoResourceKind.Edited, Rel(stem + "-edited" + (e.Length == 0 ? "" : "." + e)), ed.Size));
        }
        if (_options.IncludeRAW && a.Resource(PhotoResourceKind.Alternate) is { } alt)
        {
            var e = Path.GetExtension(alt.Filename).TrimStart('.');
            if (e.Length == 0) e = "dng";
            var name = e.Equals(ext, StringComparison.OrdinalIgnoreCase) ? stem + "-alt." + e : stem + "." + e;
            output.Add(new(a, PhotoResourceKind.Alternate, Rel(name), alt.Size));
        }
        return output;
    }

    public async Task<RunReport> RunAsync(Evaluation eval, int concurrency = 4, Action<RunProgress>? progress = null, CancellationToken ct = default)
    {
        if (SafetyPolicy.IsICloudPath(_dest)) throw SyncException.Unavailable("Exports can’t be written into an iCloud folder. Choose a folder or drive outside iCloud.");
        Directory.CreateDirectory(_dest);
        var total = eval.PendingBytes;
        var report = new RunReport();
        var gate = new object();
        int filesDone = 0;
        long bytesDone = 0;
        var n = eval.Pending.Count;
        using (var sem = new SemaphoreSlim(concurrency))
        {
            var tasks = new List<Task>();
            foreach (var p in eval.Pending)
            {
                await sem.WaitAsync(ct).ConfigureAwait(false);
                tasks.Add(Task.Run(async () =>
                {
                    try
                    {
                        ct.ThrowIfCancellationRequested();
                        var target = Paths.Combine(_dest, WinNames.RelToLocal(p.Rel));
                        var tmp = Path.Combine(Path.GetDirectoryName(target)!, ".cirrus-part-" + Path.GetFileName(target));
                        int attempt = 0;
                        while (true)
                        {
                            long last = 0;
                            try
                            {
                                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                                await _backend.ExportAsync(p.Asset, p.Kind, tmp, (d, _) =>
                                {
                                    long fd; long bd;
                                    lock (gate) { var delta = d - last; last = d; if (delta > 0) bytesDone += delta; fd = filesDone; bd = bytesDone; }
                                    progress?.Invoke(new RunProgress("Downloading " + p.Asset.Filename, (int)fd, n, bd, total));
                                }, ct).ConfigureAwait(false);
                                var got = File.Exists(tmp) ? new FileInfo(tmp).Length : 0;
                                if (_options.Verify && p.Size > 0 && got != p.Size && attempt == 0) { attempt++; continue; }
                                if (File.Exists(target)) LocalFiles.SafeTrash(target, _dest);   // an older or partial copy we're replacing
                                File.Move(tmp, target);
                                if (p.Asset.Created is { } d0) { try { File.SetCreationTimeUtc(target, d0.UtcDateTime); File.SetLastWriteTimeUtc(target, d0.UtcDateTime); } catch { } }
                                lock (gate) { report.Copied++; report.Bytes += got; }
                                break;
                            }
                            catch (OperationCanceledException)
                            {
                                try { File.Delete(tmp); } catch { }
                                throw;
                            }
                            catch (Exception e)
                            {
                                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }   // our own partial download
                                if (attempt < 2) { attempt++; await Task.Delay(1500, ct).ConfigureAwait(false); continue; }
                                Log.Error("photo export failed for an item: " + e.Message);
                                Log.Status("photo export failed for an item: " + e.GetType().Name);
                                lock (gate) report.Failed.Add($"{p.Rel}: {e.Message}");
                                break;
                            }
                        }
                        int f2; long b2;
                        lock (gate) { filesDone++; f2 = filesDone; b2 = bytesDone; }
                        progress?.Invoke(new RunProgress("Downloading photos…", f2, n, b2, total));
                    }
                    finally { sem.Release(); }
                }, ct));
            }
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        WriteManifest(eval);
        if (_options.AlbumFolders) MakeAlbumFolders(eval);
        return report;
    }

    void WriteManifest(Evaluation eval)
    {
        var m = LoadManifest();
        var byAsset = eval.Files.GroupBy(f => f.Asset.Id).ToDictionary(g => g.Key, g => g.Select(x => x.Rel).ToList());
        foreach (var f in eval.Files.Where(f => f.Kind == PhotoResourceKind.Original))
            m.Assets[f.Asset.Id] = new Manifest.Entry { Files = byAsset[f.Asset.Id], Created = f.Asset.Created, Favorite = f.Asset.IsFavorite, Hidden = f.Asset.IsHidden };
        SaveManifest(m);
        if (!_options.WriteManifest) return;
        var csv = new StringBuilder("path,filename,taken,favorite,hidden,width,height,live,edited,albums\n");
        var albumsFor = new Dictionary<string, List<string>>();
        foreach (var (name, rels) in eval.Albums) foreach (var r in rels) { if (!albumsFor.TryGetValue(r, out var l)) albumsFor[r] = l = []; l.Add(name); }
        static string Q(string s) => "\"" + s.Replace("\"", "\"\"") + "\"";
        foreach (var f in eval.Files.Where(f => f.Kind == PhotoResourceKind.Original))
        {
            var a = f.Asset;
            csv.Append(string.Join(",", Q(f.Rel), Q(a.Filename), a.Created is { } c ? c.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) : "",
                a.IsFavorite ? "1" : "0", a.IsHidden ? "1" : "0", a.Width.ToString(CultureInfo.InvariantCulture), a.Height.ToString(CultureInfo.InvariantCulture),
                a.IsLive ? "1" : "0", a.IsEdited ? "1" : "0", Q(string.Join("; ", albumsFor.GetValueOrDefault(f.Rel) ?? [])))).Append('\n');
        }
        AtomicFile.Write(Path.Combine(_dest, "Photos manifest.csv"), Encoding.UTF8.GetBytes(csv.ToString()));
        if (eval.Albums.Count > 0)
        {
            var sorted = new SortedDictionary<string, List<string>>(eval.Albums, StringComparer.Ordinal);
            AtomicFile.Write(Path.Combine(_dest, "Albums.json"), JsonSerializer.SerializeToUtf8Bytes(sorted, Jx.Pretty));
        }
    }

    /// <summary>Albums as folders of relative symbolic links (no extra space). Skipped where links can't be made.</summary>
    void MakeAlbumFolders(Evaluation eval)
    {
        var root = Path.Combine(_dest, "Albums");
        foreach (var (name, rels) in eval.Albums)
        {
            var dir = Path.Combine(root, Paths.SafeName(name));
            Directory.CreateDirectory(dir);
            foreach (var r in rels)
            {
                var local = WinNames.RelToLocal(r);
                var link = Path.Combine(dir, local.Split('/')[^1]);
                if (File.Exists(link) || Directory.Exists(link) || new FileInfo(link).LinkTarget is not null) continue;
                var target = Path.Combine("..", "..", local.Replace('/', Path.DirectorySeparatorChar));
                try { File.CreateSymbolicLink(link, target); }
                catch (Exception e) { Log.Status("album folders skipped: can’t create links here (" + e.GetType().Name + ")"); return; }
            }
        }
    }
}

/// <summary>
/// Full-account backup: evaluate sizes vs destination space, then copy iCloud Drive and every Photos library
/// (originals with companions) into &lt;destination&gt;\Cirrus Backup\&lt;account&gt;\. Never writes to iCloud.
/// </summary>
public sealed class BackupEngine
{
    public sealed record DrivePlan(string Label, SyncPlan Plan, Dictionary<string, SideEntry> A, Dictionary<string, SideEntry> B, ISyncSide Source, ISyncSide Dest);

    public sealed class Evaluation
    {
        public StorageUsage? Storage { get; set; }
        public int DriveFiles { get; set; }
        public long DriveBytes { get; set; }
        public long DrivePendingBytes { get; set; }
        public List<DrivePlan> DrivePlans { get; } = [];
        public List<PhotoExporter.Evaluation> Photos { get; } = [];
        public List<PhotoExporter> Exporters { get; } = [];
        public long Free { get; set; }
        public VolumeInfo? Volume { get; set; }
        public List<string> Warnings { get; } = [];
        public long PhotosBytes => Photos.Sum(p => p.TotalBytes);
        public long PhotosPendingBytes => Photos.Sum(p => p.PendingBytes);
        public int PhotoCount => Photos.Sum(p => p.AssetCount);
        public long TotalBytes => DriveBytes + PhotosBytes;
        public long PendingBytes => DrivePendingBytes + PhotosPendingBytes;
        /// <summary>Free space must cover what's left plus 2 % and 1 GB of headroom.</summary>
        public long RequiredFree => PendingBytes + PendingBytes / 50 + (PendingBytes > 0 ? 1L << 30 : 0);
        public bool Fits => Free >= RequiredFree;
        public bool DestinationIsICloud { get; set; }
    }

    public sealed record Sources(string AccountTitle, IDriveBackend? Drive, string? NativeDriveRoot, IPhotosBackend? Photos,
        Func<Task<StorageUsage?>>? Storage, string? NativePhotosRoot = null);

    readonly Sources _sources;
    readonly string _destination;
    readonly SyncOptions _options;

    public BackupEngine(Sources sources, string destination, SyncOptions options) { _sources = sources; _destination = destination; _options = options; }

    public string AccountRoot => Path.Combine(_destination, "Cirrus Backup", Paths.SafeName(_sources.AccountTitle));

    public async Task<Evaluation> EvaluateAsync(Action<string>? progress, CancellationToken ct = default)
    {
        var ev = new Evaluation();
        progress?.Invoke("Checking the destination…");
        ev.Volume = VolumeInfo.Info(_destination);
        ev.Free = VolumeInfo.FreeSpace(_destination) ?? 0;
        ev.DestinationIsICloud = SafetyPolicy.IsICloudPath(_destination);
        if (_sources.Storage is { } s) { progress?.Invoke("Reading iCloud storage…"); try { ev.Storage = await s().ConfigureAwait(false); } catch { } }
        var driveDest = Path.Combine(AccountRoot, "iCloud Drive");
        if (_options.IncludeDrive)
        {
            var pairs = new List<(string, ISyncSide, ISyncSide)>();
            if (_sources.Drive is { } d)
                pairs.Add(("iCloud Drive", new DriveSide(d, d.RootID, "iCloud Drive", _options.Excludes), new LocalSide(driveDest, _options.Excludes, allowMissing: true)));
            else if (_sources.NativeDriveRoot is { } root)
                pairs.Add(("iCloud Drive", new LocalSide(root, _options.Excludes), new LocalSide(driveDest, _options.Excludes, allowMissing: true)));
            if (_sources.Drive is null && _sources.NativePhotosRoot is { } pr && _options.IncludePhotos)
                pairs.Add(("iCloud Photos", new LocalSide(pr, _options.Excludes), new LocalSide(Path.Combine(AccountRoot, "Photos", "iCloud Photos"), _options.Excludes, allowMissing: true)));
            foreach (var (label, src, dst) in pairs)
            {
                progress?.Invoke($"Scanning {label}…");
                var a = await src.ScanAsync(n => progress?.Invoke($"Scanning {label}… {n} items"), ct).ConfigureAwait(false);
                var b = await dst.ScanAsync(null, ct).ConfigureAwait(false);
                var plan = SyncPlanner.Plan(_options.KeepDeleted ? SyncMode.Copy : SyncMode.Mirror, a, b, null);
                // A backup never loses what it holds because iCloud briefly answered with an empty or partial list.
                if (plan.WipesSide || (plan.TrashItemsB > 20 && (long)plan.TrashItemsB * 2 > b.Count))
                {
                    ev.Warnings.Add($"{label}: this run would have removed {plan.TrashItemsB} of {b.Count} backed-up items. They were kept; if you really deleted them in iCloud, remove them from the backup yourself.");
                    plan = new SyncPlan
                    {
                        Actions = plan.Actions.Where(x => !x.IsDestructive).ToList(), SourceCount = plan.SourceCount, DestinationCount = plan.DestinationCount,
                        TrashItemsA = plan.TrashItemsA, TrashItemsB = 0, RemovedItems = plan.TrashItemsA,
                    };
                }
                ev.DriveFiles += a.Values.Count(x => !x.IsDir);
                ev.DriveBytes += a.Values.Where(x => !x.IsDir).Sum(x => x.Size);
                ev.DrivePendingBytes += plan.Bytes;
                ev.DrivePlans.Add(new DrivePlan(label, plan, a, b, src, dst));
            }
        }
        if (_options.IncludePhotos && _sources.Photos is { } pb)
        {
            var libs = await pb.LibrariesAsync(ct).ConfigureAwait(false);
            if (_options.IncludeSharedLibrary && pb is WebPhotos { SharedLookupFailed: true })
                ev.Warnings.Add("iCloud didn’t answer about a Shared Library in time, so any Shared Library isn’t part of this backup. Check Space again later to include it.");
            foreach (var lib in libs.Where(l => !l.IsShared || _options.IncludeSharedLibrary))
            {
                var dir = Path.Combine(AccountRoot, "Photos", Paths.SafeName(lib.Name));
                var ex = new PhotoExporter(pb, lib, null, dir, _options);
                ev.Photos.Add(await ex.EvaluateAsync(progress, ct).ConfigureAwait(false));
                ev.Exporters.Add(ex);
            }
        }
        // Warnings
        if (ev.DestinationIsICloud)
            ev.Warnings.Add("The destination is inside an iCloud folder. A backup must live outside iCloud; choose another folder or an external drive.");
        if (ev.Volume is { IsFat32: true } v)
        {
            var big = ev.Photos.Any(p => p.LargestFile >= Limits.Fat32Max) || ev.DrivePlans.Any(p => p.A.Values.Any(x => x.Size >= Limits.Fat32Max));
            ev.Warnings.Add($"“{v.DisplayName}” is formatted as {v.Format ?? "FAT32"}, which can’t hold files over 4 GB" +
                (big ? " — some of your files are larger and will fail. Reformat it as NTFS or exFAT." : "."));
        }
        if (_options.AlbumFolders)
        {
            if (ev.Volume?.Format is { } fmt && fmt.Contains("fat", StringComparison.OrdinalIgnoreCase))
                ev.Warnings.Add("Album folders use symbolic links, which this drive’s format doesn’t support; they’ll be skipped.");
            else if (OperatingSystem.IsWindows())
                ev.Warnings.Add("Album folders use symbolic links, which Windows only allows with Developer Mode on (or when Cirrus runs as administrator); otherwise they’re skipped.");
        }
        if (!ev.Fits)
            ev.Warnings.Add($"Not enough space: this backup needs {ev.RequiredFree.ByteString()} free (including headroom) but only {ev.Free.ByteString()} is available.");
        if (ev.Storage is { Used: > 0 } st)
        {
            var other = st.Categories.Where(c => c.Key.ToLowerInvariant() is not ("photos" or "docs" or "documents")).Sum(c => c.Bytes);
            if (other > 0) ev.Warnings.Add($"{other.ByteString()} of your iCloud storage (device backups, Mail, Messages and app data) can’t be downloaded through iCloud.com and isn’t included.");
        }
        if (ev.Volume?.IsRoot == true)
            ev.Warnings.Add($"The destination is this PC’s system drive ({ev.Volume.Root.TrimEnd('\\', '/')}). For a real backup, choose an external drive.");
        return ev;
    }

    /// <param name="force">Run even when "keep deleted" is off and the mirror would remove a large share of the backup.</param>
    public async Task<RunReport> RunAsync(Evaluation ev, Action<RunProgress>? progress, CancellationToken ct = default, bool force = false)
    {
        if (ev.DestinationIsICloud || SafetyPolicy.IsICloudPath(_destination))
            throw SyncException.Unavailable("Backups can’t be written into an iCloud folder. Choose a folder or drive outside iCloud.");
        if (!ev.Fits) throw SyncException.NotEnoughSpace(ev.RequiredFree, ev.Free);
        if (!force && !_options.KeepDeleted)
            foreach (var p in ev.DrivePlans)
                if (SyncPlanner.GuardTripped(p.Plan, SyncMode.Mirror, _options.MaxDeletePercent))
                    throw SyncException.DeleteGuard(p.Plan.RemovedItems, Math.Max(1, p.Plan.DestinationCount));
        Directory.CreateDirectory(AccountRoot);
        var total = new RunReport();
        var overall = ev.PendingBytes;
        long baseBytes = 0;
        foreach (var p in ev.DrivePlans)
        {
            ct.ThrowIfCancellationRequested();
            var runner = new SyncRunner(p.Source, p.Dest);
            var before = baseBytes;
            var (r, _) = await runner.RunAsync(p.Plan, p.A, p.B, rp =>
                progress?.Invoke(new RunProgress($"{p.Label}: {rp.Phase}", rp.FilesDone, rp.FilesTotal, before + rp.BytesDone, overall)), ct).ConfigureAwait(false);
            baseBytes += p.Plan.Bytes;
            total.Copied += r.Copied; total.Bytes += r.Bytes; total.Trashed += r.Trashed; total.Failed.AddRange(r.Failed); total.Skipped += r.Skipped;
        }
        for (int i = 0; i < ev.Photos.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var e = ev.Photos[i];
            var before = baseBytes;
            var r = await ev.Exporters[i].RunAsync(e, 4, rp =>
                progress?.Invoke(new RunProgress($"Photos ({e.Library.Name}): {rp.Phase}", rp.FilesDone, rp.FilesTotal, before + rp.BytesDone, overall)), ct).ConfigureAwait(false);
            baseBytes += e.PendingBytes;
            total.Copied += r.Copied; total.Bytes += r.Bytes; total.Failed.AddRange(r.Failed);
        }
        WriteInfo(ev, total);
        return total;
    }

    void WriteInfo(Evaluation ev, RunReport report)
    {
        var s = new StringBuilder();
        s.Append($"Cirrus backup of {_sources.AccountTitle}\r\nLast run: {DateTime.Now.ToString("f", CultureInfo.CurrentCulture)}\r\n\r\n");
        s.Append($"iCloud Drive: {ev.DriveFiles} files, {ev.DriveBytes.ByteString()}\r\n");
        foreach (var p in ev.Photos) s.Append($"Photos — {p.Library.Name}: {p.AssetCount} items, {p.TotalBytes.ByteString()}\r\n");
        s.Append($"\r\nThis run: {report.Summary}\r\n");
        if (report.Failed.Count > 0) s.Append("\r\nProblems:\r\n" + string.Join("\r\n", report.Failed.Take(200).Select(f => "  • " + f)) + "\r\n");
        s.Append("\r\nLayout:\r\n  iCloud Drive\\ — your iCloud Drive files and folders\r\n  Photos\\<library>\\YYYY\\MM\\ — originals, Live Photo videos (.MOV), edits (-edited) and RAW files, dated by capture time\r\n  Photos\\<library>\\Photos manifest.csv — favorites, hidden flags and album membership\r\n");
        s.Append("\r\nFiles are only ever added or updated here; nothing is deleted from iCloud.\r\n");
        AtomicFile.Write(Path.Combine(AccountRoot, "Backup Info.txt"), Encoding.UTF8.GetBytes(s.ToString()));
    }
}
