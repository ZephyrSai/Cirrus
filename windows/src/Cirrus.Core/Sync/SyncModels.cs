using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cirrus.Core;

public enum EndpointKind { Local, Drive, Photos, Account }

/// <summary>One side of a job: a local folder, an iCloud Drive folder, a Photos library/album, or a whole account (backup source).</summary>
public sealed class SyncEndpoint : IEquatable<SyncEndpoint>
{
    public EndpointKind Kind { get; set; }
    public string? Path { get; set; }          // Local: folder path. Drive: display path inside iCloud Drive.
    public string? Account { get; set; }
    public string? FolderID { get; set; }
    public string? Library { get; set; }
    public string? Album { get; set; }
    public string? AlbumName { get; set; }

    public static SyncEndpoint Local(string path) => new() { Kind = EndpointKind.Local, Path = path };
    public static SyncEndpoint Drive(string account, string folderID, string path) => new() { Kind = EndpointKind.Drive, Account = account, FolderID = folderID, Path = path };
    public static SyncEndpoint Photos(string account, string library, string? album, string? albumName) =>
        new() { Kind = EndpointKind.Photos, Account = account, Library = library, Album = album, AlbumName = albumName };
    public static SyncEndpoint ForAccount(string id) => new() { Kind = EndpointKind.Account, Account = id };

    [JsonIgnore]
    public string Title => Kind switch
    {
        EndpointKind.Local => Path ?? "",
        EndpointKind.Drive => "iCloud Drive" + (string.IsNullOrEmpty(Path) ? "" : " › " + Path.Replace("/", " › ")),
        EndpointKind.Photos => "Photos" + (AlbumName is { } n ? " › " + n : " › All Photos"),
        _ => Account ?? "",
    };

    [JsonIgnore] public string? LocalPath => Kind == EndpointKind.Local ? Path : null;
    [JsonIgnore] public string? AccountID => Kind == EndpointKind.Local ? null : Account;

    public bool Equals(SyncEndpoint? o) => o is not null && Kind == o.Kind && Path == o.Path && Account == o.Account && FolderID == o.FolderID
        && Library == o.Library && Album == o.Album;
    public override bool Equals(object? obj) => Equals(obj as SyncEndpoint);
    public override int GetHashCode() => HashCode.Combine(Kind, Path, Account, FolderID, Library, Album);
}

public sealed class SyncOptions
{
    // Folder sync
    public List<string> Excludes { get; set; } =
    [
        ".DS_Store", "._*", ".Trashes", ".Spotlight-V100", ".fseventsd", "Icon\r", ".cirrus",
        "desktop.ini", "Thumbs.db", "$RECYCLE.BIN", "System Volume Information", ".cirrus-*",
    ];
    public int MaxDeletePercent { get; set; } = 50;
    // Photos export / backup
    public string PhotoLayout { get; set; } = "{yyyy}/{MM}";
    public bool IncludeLive { get; set; } = true;
    public bool IncludeEdited { get; set; } = true;
    public bool IncludeRAW { get; set; } = true;
    public bool IncludeHidden { get; set; }
    public bool IncludeSharedLibrary { get; set; } = true;
    /// <summary>Per-album folders made of symbolic links (NTFS only; Windows needs Developer Mode or admin rights).</summary>
    public bool AlbumFolders { get; set; }
    public bool WriteManifest { get; set; } = true;
    /// <summary>Archive: never remove backed-up files when they're gone from iCloud.</summary>
    public bool KeepDeleted { get; set; } = true;
    public bool Verify { get; set; } = true;
    public bool IncludeDrive { get; set; } = true;
    public bool IncludePhotos { get; set; } = true;

    public SyncOptions Clone() => JsonSerializer.Deserialize<SyncOptions>(JsonSerializer.Serialize(this))!;
}

public enum JobKind { FolderSync, PhotosExport, PhotosImport, Backup }
public enum SyncMode { Copy, Mirror, TwoWay }
public enum ScheduleKind { Manual, Every, Daily, WhenConnected }

public sealed class JobSchedule
{
    public ScheduleKind Kind { get; set; } = ScheduleKind.Manual;
    public int Minutes { get; set; } = 60;
    public int Hour { get; set; } = 2;
    public string? VolumeID { get; set; }

    public static JobSchedule Manual => new();
    public static JobSchedule Every(int minutes) => new() { Kind = ScheduleKind.Every, Minutes = minutes };
    public static JobSchedule Daily(int hour) => new() { Kind = ScheduleKind.Daily, Hour = hour };
    public static JobSchedule WhenConnected(string volumeID) => new() { Kind = ScheduleKind.WhenConnected, VolumeID = volumeID };

    [JsonIgnore]
    public string Title => Kind switch
    {
        ScheduleKind.Manual => "Manually",
        ScheduleKind.Every => Minutes % 60 == 0 ? $"Every {Minutes / 60} hour{(Minutes == 60 ? "" : "s")}" : $"Every {Minutes} minutes",
        ScheduleKind.Daily => $"Daily at {Hour}:00",
        _ => "When the drive is connected",
    };
}

public static class SyncModeText
{
    public static string Title(this SyncMode m) => m switch
    {
        SyncMode.Copy => "Copy new and changed files",
        SyncMode.Mirror => "Mirror (remove extras to the Recycle Bin)",
        _ => "Two-way sync",
    };
}

public sealed class SyncJob
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public JobKind Kind { get; set; }
    public SyncMode Mode { get; set; } = SyncMode.Copy;
    public SyncEndpoint Source { get; set; } = new();
    public SyncEndpoint Destination { get; set; } = new();
    public JobSchedule Schedule { get; set; } = new();
    public SyncOptions Options { get; set; } = new();
    public bool Enabled { get; set; } = true;
    public DateTimeOffset? LastRun { get; set; }
    public string? LastResult { get; set; }
    public bool? LastSuccess { get; set; }

    public SyncJob() { }
    public SyncJob(string name, JobKind kind, SyncEndpoint source, SyncEndpoint destination) { Name = name; Kind = kind; Source = source; Destination = destination; }
    public SyncJob Clone() => JsonSerializer.Deserialize<SyncJob>(JsonSerializer.Serialize(this, SyncStore.Json), SyncStore.Json)!;
}

/// <summary>Persisted job list (jobs.json in the Cirrus data folder).</summary>
public sealed class SyncStore
{
    public static SyncStore Shared { get; } = new();
    internal static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    readonly object _lock = new();
    List<SyncJob> _jobs = [];
    readonly HashSet<Guid> _running = [];
    public event Action? Changed;

    static string FilePath => System.IO.Path.Combine(Paths.AppSupport, "sync-jobs.json");

    public IReadOnlyList<SyncJob> Jobs { get { lock (_lock) return _jobs.Select(j => j.Clone()).ToList(); } }
    public bool IsRunning(Guid id) { lock (_lock) return _running.Contains(id); }
    public bool MarkRunning(Guid id) { lock (_lock) return _running.Add(id); }
    public void MarkStopped(Guid id) { lock (_lock) _running.Remove(id); Changed?.Invoke(); }

    public void Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<List<SyncJob>>(File.ReadAllBytes(FilePath), Json) is { } j)
                lock (_lock) _jobs = j;
        }
        catch (Exception e) { Log.Status("couldn’t read sync jobs: " + e.GetType().Name); }
        Changed?.Invoke();
    }

    void Save()
    {
        byte[] data;
        lock (_lock) data = JsonSerializer.SerializeToUtf8Bytes(_jobs, Json);
        AtomicFile.Write(FilePath, data);
        Changed?.Invoke();
    }

    public void Upsert(SyncJob job)
    {
        lock (_lock)
        {
            var i = _jobs.FindIndex(j => j.Id == job.Id);
            if (i >= 0) _jobs[i] = job.Clone(); else _jobs.Add(job.Clone());
        }
        Save();
    }

    public void Remove(SyncJob job)
    {
        lock (_lock) _jobs.RemoveAll(j => j.Id == job.Id);
        try { File.Delete(SyncState.FilePath(job.Id)); File.Delete(SyncState.ImportFilePath(job.Id)); } catch { }   // Cirrus' own bookkeeping
        Save();
    }

    public SyncJob? Job(Guid id) { lock (_lock) return _jobs.FirstOrDefault(j => j.Id == id)?.Clone(); }

    public void Record(Guid id, bool success, string message)
    {
        lock (_lock)
        {
            var j = _jobs.FirstOrDefault(x => x.Id == id);
            if (j is null) return;
            j.LastRun = DateTimeOffset.Now; j.LastResult = message; j.LastSuccess = success;
        }
        Save();
    }
}

/// <summary>Two-way sync baseline: what both sides looked like after the last successful run.</summary>
public sealed class SyncState
{
    public sealed record Entry(long Size, double MtimeA, double MtimeB);
    public Dictionary<string, Entry> Entries { get; set; } = [];

    internal static string FilePath(Guid id) => System.IO.Path.Combine(Paths.SupportDir("sync-state"), id.ToString().ToUpperInvariant() + ".json");
    internal static string ImportFilePath(Guid id) => System.IO.Path.Combine(Paths.SupportDir("sync-state"), id.ToString().ToUpperInvariant() + "-import.json");

    public static SyncState Load(Guid id)
    {
        try { return File.Exists(FilePath(id)) ? JsonSerializer.Deserialize<SyncState>(File.ReadAllBytes(FilePath(id))) ?? new() : new(); }
        catch { return new(); }
    }

    public void Save(Guid id) => AtomicFile.Write(FilePath(id), JsonSerializer.SerializeToUtf8Bytes(this));
    public static void Forget(Guid id) { try { File.Delete(FilePath(id)); } catch { } }
}

public readonly record struct RunProgress(string Phase, int FilesDone, int FilesTotal, long BytesDone, long BytesTotal);

public sealed class RunReport
{
    public int Copied { get; set; }
    public int CopiedBack { get; set; }
    public int Trashed { get; set; }
    public int Conflicts { get; set; }
    public int Skipped { get; set; }
    public List<string> Failed { get; set; } = [];
    public long Bytes { get; set; }

    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (Copied > 0) parts.Add($"{Copied} copied");
            if (CopiedBack > 0) parts.Add($"{CopiedBack} copied back");
            if (Trashed > 0) parts.Add($"{Trashed} moved to the Recycle Bin");
            if (Conflicts > 0) parts.Add($"{Conflicts} conflict{(Conflicts == 1 ? "" : "s")} kept as copies");
            if (Failed.Count > 0) parts.Add($"{Failed.Count} failed");
            if (parts.Count == 0) return "Up to date";
            return string.Join(", ", parts) + (Bytes > 0 ? $" ({Bytes.ByteString()})" : "");
        }
    }

    public void Add(RunReport r)
    {
        Copied += r.Copied; CopiedBack += r.CopiedBack; Trashed += r.Trashed; Conflicts += r.Conflicts; Skipped += r.Skipped;
        Failed.AddRange(r.Failed); Bytes += r.Bytes;
    }
}

/// <summary>Writes via a temp file then renames, so a crash never leaves a half-written settings file.</summary>
public static class AtomicFile
{
    public static void Write(string path, byte[] data)
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp-" + Guid.NewGuid().ToString("N")[..6];
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) { Log.Status("couldn’t write a Cirrus data file (" + System.IO.Path.GetFileName(path) + ")" + ": " + e.GetType().Name); }
    }
}
