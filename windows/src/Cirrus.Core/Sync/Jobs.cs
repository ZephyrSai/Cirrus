using System.Text.Json;

namespace Cirrus.Core;

/// <summary>Scans, previews and runs sync / export / import / backup jobs (port of JobRunner in Jobs.swift).</summary>
public sealed class JobEngine
{
    public static JobEngine Shared { get; } = new();

    public sealed class Preview
    {
        public SyncPlan? Plan { get; init; }
        public BackupEngine.Evaluation? Backup { get; init; }
        public PhotoExporter.Evaluation? Photos { get; init; }
        public int ImportCount { get; init; }
        public long ImportBytes { get; init; }
        public required string Summary { get; init; }
        public bool GuardTripped { get; init; }
    }

    /// <summary>Raised when a job finishes: (job id, success, message).</summary>
    public event Action<Guid, bool, string>? Finished;

    static AccountManager Accounts => AccountManager.Shared;

    ISyncSide Side(SyncEndpoint e, IReadOnlyList<string> excludes, bool isDestination)
    {
        switch (e.Kind)
        {
            case EndpointKind.Local: return new LocalSide(e.Path!, excludes, allowMissing: isDestination);
            case EndpointKind.Drive:
                var acct = Accounts.Account(e.Account) ?? throw ICloudException.NeedsSignIn();
                if (acct.Drive is null) throw ICloudException.NeedsSignIn();
                var path = e.Path ?? "";
                return new DriveSide(acct.Drive, e.FolderID!, path.Length == 0 ? "iCloud Drive" : path.Split('/')[^1], excludes);
            default: throw SyncException.Unavailable("This endpoint can’t be used for folder sync.");
        }
    }

    BackupEngine BackupEngineFor(SyncJob job)
    {
        if (job.Source.Kind != EndpointKind.Account || Accounts.Account(job.Source.Account) is not { } acct)
            throw SyncException.Unavailable("Choose an iCloud account to back up.");
        var dest = job.Destination.LocalPath ?? throw SyncException.Unavailable("Choose a destination folder or drive.");
        if (acct.Status == AccountStatus.NeedsSignIn) throw ICloudException.NeedsSignIn();
        Func<Task<StorageUsage?>>? storage = acct.Session is not null ? acct.StorageUsageAsync : null;
        var sources = new BackupEngine.Sources(acct.AppleID ?? acct.Title, acct.Drive, acct.DriveRoot, acct.Photos, storage, acct.PhotosRoot);
        return new BackupEngine(sources, dest, job.Options);
    }

    static async Task<(IPhotosBackend, PhotoLibraryRef, PhotoAlbum?)> PhotosContext(SyncEndpoint e, CancellationToken ct)
    {
        if (e.Kind != EndpointKind.Photos || Accounts.Account(e.Account) is not { Photos: { } photos })
            throw SyncException.Unavailable("Choose a Photos library.");
        var libs = await photos.LibrariesAsync(ct).ConfigureAwait(false);
        var lib = libs.FirstOrDefault(l => l.Id == e.Library) ?? libs.FirstOrDefault() ?? throw SyncException.Unavailable("That Photos library isn’t available.");
        PhotoAlbum? album = null;
        if (e.Album is { } albumID)
            album = (await photos.AlbumsAsync(lib, ct).ConfigureAwait(false)).FirstOrDefault(a => a.Id == albumID)
                ?? throw SyncException.Unavailable($"The album “{e.AlbumName ?? albumID}” no longer exists.");
        return (photos, lib, album);
    }

    /// <summary>Scan and plan without changing anything.</summary>
    public async Task<Preview> PreviewAsync(SyncJob job, Action<string>? progress, CancellationToken ct = default)
    {
        switch (job.Kind)
        {
            case JobKind.FolderSync:
            {
                var a = Side(job.Source, job.Options.Excludes, false); var b = Side(job.Destination, job.Options.Excludes, true);
                var (sa, sb) = await new SyncRunner(a, b).ScanAsync(p => progress?.Invoke(p.Phase), ct).ConfigureAwait(false);
                var plan = SyncPlanner.Plan(job.Mode, sa, sb, job.Mode == SyncMode.TwoWay ? SyncState.Load(job.Id) : null);
                return new Preview { Plan = plan, Summary = SyncPlanner.Describe(plan), GuardTripped = SyncPlanner.GuardTripped(plan, job.Mode, job.Options.MaxDeletePercent) };
            }
            case JobKind.PhotosExport:
            {
                var (pb, lib, album) = await PhotosContext(job.Source, ct).ConfigureAwait(false);
                var dest = job.Destination.LocalPath ?? throw SyncException.Unavailable("Choose a destination folder.");
                var ev = await new PhotoExporter(pb, lib, album, dest, job.Options).EvaluateAsync(progress, ct).ConfigureAwait(false);
                return new Preview
                {
                    Photos = ev,
                    Summary = $"{ev.AssetCount} items in iCloud; {ev.Pending.Count} files ({ev.PendingBytes.ByteString()}) to download, {ev.Files.Count - ev.Pending.Count} already exported.",
                };
            }
            case JobKind.PhotosImport:
            {
                var (files, bytes) = ImportCandidates(job);
                return new Preview
                {
                    ImportCount = files.Count, ImportBytes = bytes,
                    Summary = files.Count == 0 ? "Nothing new to import." : $"{files.Count} new photos and videos ({bytes.ByteString()}) will be imported.",
                };
            }
            default:
            {
                var ev = await BackupEngineFor(job).EvaluateAsync(progress, ct).ConfigureAwait(false);
                return new Preview { Backup = ev, Summary = $"Needs {ev.PendingBytes.ByteString()} of {ev.TotalBytes.ByteString()}; {ev.Free.ByteString()} free." };
            }
        }
    }

    sealed class ImportState { public HashSet<string> Done { get; set; } = []; }

    static ImportState LoadImport(Guid id)
    {
        try { var f = SyncState.ImportFilePath(id); return File.Exists(f) ? JsonSerializer.Deserialize<ImportState>(File.ReadAllBytes(f)) ?? new() : new(); }
        catch { return new(); }
    }

    static string ImportKey(string root, string file) => Path.GetRelativePath(root, file).Replace('\\', '/') + "|" + new FileInfo(file).Length;

    public static (List<string> Files, long Bytes) ImportCandidates(SyncJob job)
    {
        var root = job.Source.LocalPath ?? throw SyncException.Unavailable("Choose a folder to import from.");
        var st = LoadImport(job.Id);
        var output = new List<string>();
        long bytes = 0;
        if (!Directory.Exists(root)) return (output, 0);
        foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }))
        {
            if (!PhotoFormats.IsImportable(f.FullName)) continue;
            if (st.Done.Contains(ImportKey(root, f.FullName))) continue;
            output.Add(f.FullName);
            bytes += f.Length;
        }
        return (output, bytes);
    }

    /// <summary>Queues a job as one Transfer row. Returns null if it's already running.</summary>
    public Transfer? Run(SyncJob job, bool force = false)
    {
        if (!SyncStore.Shared.MarkRunning(job.Id)) return null;
        TransferManager.Shared.JobStarted(job.Id);
        return TransferManager.Shared.Enqueue(job.Name, async (t, ct) =>
        {
            bool success = false;
            string message = "";
            try
            {
                var report = await ExecuteAsync(job, force, t, ct).ConfigureAwait(false);
                success = report.Failed.Count == 0;
                message = report.Summary + (report.Failed.Count == 0 ? "" : " — " + report.Failed[0]);
                t.SetDetail(message);
                if (report.Failed.Count > 0) throw ICloudException.Server($"{report.Failed.Count} item{(report.Failed.Count == 1 ? "" : "s")} failed: {report.Failed[0]}");
            }
            catch (Exception e)
            {
                if (message.Length == 0) message = e is OperationCanceledException ? "Cancelled." : e.Message;
                throw;
            }
            finally
            {
                SyncStore.Shared.MarkStopped(job.Id);
                TransferManager.Shared.JobFinished(job.Id);
                SyncStore.Shared.Record(job.Id, success, message);
                Finished?.Invoke(job.Id, success, message);
            }
        }, "Starting…", job.Kind == JobKind.PhotosImport ? TransferDirection.Upload : TransferDirection.Download, group: "job:" + job.Id);
    }

    public async Task<RunReport> ExecuteAsync(SyncJob job, bool force, Transfer? t, CancellationToken ct)
    {
        void Report(RunProgress p)
        {
            t?.Report(p.BytesDone, p.BytesTotal);
            t?.SetDetail(p.FilesTotal > 0 ? $"{p.Phase} — {p.FilesDone} of {p.FilesTotal}" : p.Phase);
        }
        switch (job.Kind)
        {
            case JobKind.FolderSync:
            {
                var a = Side(job.Source, job.Options.Excludes, false); var b = Side(job.Destination, job.Options.Excludes, true);
                var runner = new SyncRunner(a, b);
                var (sa, sb) = await runner.ScanAsync(Report, ct).ConfigureAwait(false);
                var plan = SyncPlanner.Plan(job.Mode, sa, sb, job.Mode == SyncMode.TwoWay ? SyncState.Load(job.Id) : null);
                if (!force && SyncPlanner.GuardTripped(plan, job.Mode, job.Options.MaxDeletePercent))
                    throw SyncException.DeleteGuard(plan.TrashCount, Math.Max(plan.DestinationCount, plan.SourceCount));
                foreach (var (side, label) in new[] { (b, "destination"), (a, "source") })
                {
                    if (job.Mode != SyncMode.TwoWay && label == "source") continue;
                    if (side.FreeSpace is long free && free < plan.Bytes) throw SyncException.NotEnoughSpace(plan.Bytes, free);
                }
                var (rep, state) = await runner.RunAsync(plan, sa, sb, Report, ct).ConfigureAwait(false);
                if (job.Mode == SyncMode.TwoWay && rep.Failed.Count == 0) state.Save(job.Id);
                return rep;
            }
            case JobKind.PhotosExport:
            {
                var (pb, lib, album) = await PhotosContext(job.Source, ct).ConfigureAwait(false);
                var dest = job.Destination.LocalPath ?? throw SyncException.Unavailable("Choose a destination folder.");
                var ex = new PhotoExporter(pb, lib, album, dest, job.Options);
                var ev = await ex.EvaluateAsync(s => t?.SetDetail(s), ct).ConfigureAwait(false);
                if (VolumeInfo.FreeSpace(dest) is long free && free < ev.PendingBytes) throw SyncException.NotEnoughSpace(ev.PendingBytes, free);
                return await ex.RunAsync(ev, 4, Report, ct).ConfigureAwait(false);
            }
            case JobKind.PhotosImport:
            {
                var (pb, lib, album) = await PhotosContext(job.Destination, ct).ConfigureAwait(false);
                var (files, bytes) = ImportCandidates(job);
                var root = job.Source.LocalPath;
                if (files.Count == 0 || root is null) return new RunReport();
                var st = LoadImport(job.Id);
                var rep = new RunReport();
                long done = 0;
                foreach (var chunk in files.Chunk(25))
                {
                    ct.ThrowIfCancellationRequested();
                    try
                    {
                        foreach (var f in chunk) await LocalFiles.EnsureDownloadedAsync(f, ct).ConfigureAwait(false);
                        await pb.ImportFilesAsync(chunk, album, lib, null, ct).ConfigureAwait(false);
                        foreach (var u in chunk)
                        {
                            st.Done.Add(ImportKey(root, u));
                            done += new FileInfo(u).Length;
                            rep.Copied++;
                        }
                        rep.Bytes = done;
                        AtomicFile.Write(SyncState.ImportFilePath(job.Id), JsonSerializer.SerializeToUtf8Bytes(st));
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception e) { rep.Failed.Add($"{Path.GetFileName(chunk[0])} …: {e.Message}"); }
                    Report(new RunProgress("Importing", rep.Copied, files.Count, done, bytes));
                }
                return rep;
            }
            default:
            {
                var engine = BackupEngineFor(job);
                var ev = await engine.EvaluateAsync(s => t?.SetDetail(s), ct).ConfigureAwait(false);
                return await engine.RunAsync(ev, Report, ct).ConfigureAwait(false);
            }
        }
    }
}

/// <summary>Fires scheduled jobs: every N minutes, daily, or when a backup drive is plugged in.</summary>
public sealed class JobScheduler : IDisposable
{
    public static JobScheduler Shared { get; } = new();
    Timer? _timer;
    HashSet<string> _seenVolumes = [];

    public void Start()
    {
        _seenVolumes = VolumeInfo.All().Select(v => v.Id ?? v.Root).ToHashSet();
        _timer = new Timer(_ => { try { Tick(); } catch (Exception e) { Log.Error("scheduler tick failed: " + e.GetType().Name); } },
            null, TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(60));
    }

    static bool Eligible(SyncJob j)
    {
        if (!j.Enabled || SyncStore.Shared.IsRunning(j.Id)) return false;
        foreach (var id in new[] { j.Source.AccountID, j.Destination.AccountID })
            if (id is not null && AccountManager.Shared.Account(id)?.Status == AccountStatus.NeedsSignIn) return false;
        if (j.Destination.LocalPath is { } dest && Path.GetDirectoryName(Path.GetFullPath(dest)) is { } parent && !Directory.Exists(parent)) return false;
        return true;
    }

    void Tick()
    {
        var now = DateTimeOffset.Now;
        var volumes = VolumeInfo.All();
        var ids = volumes.Select(v => v.Id ?? v.Root).ToHashSet();
        var newlyMounted = ids.Except(_seenVolumes).ToHashSet();
        _seenVolumes = ids;
        foreach (var j in SyncStore.Shared.Jobs.Where(Eligible))
        {
            switch (j.Schedule.Kind)
            {
                case ScheduleKind.Every:
                    if (j.LastRun is not { } last || (now - last).TotalMinutes >= j.Schedule.Minutes) JobEngine.Shared.Run(j);
                    break;
                case ScheduleKind.Daily:
                    if (now.Hour >= j.Schedule.Hour && !(j.LastRun is { } lr && lr.LocalDateTime.Date == now.Date && lr.LocalDateTime.Hour >= j.Schedule.Hour))
                        JobEngine.Shared.Run(j);
                    break;
                case ScheduleKind.WhenConnected:
                    if (j.Schedule.VolumeID is { } vid && ids.Contains(vid) && (newlyMounted.Contains(vid) || j.LastRun is not { } l2 || (now - l2).TotalHours > 12))
                        JobEngine.Shared.Run(j);
                    break;
            }
        }
    }

    public void Dispose() => _timer?.Dispose();
}
