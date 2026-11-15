using System.Text;
using System.Text.Json;

namespace Cirrus.Core;

/// <summary>A change to a manifest that can be replayed from the journal.</summary>
interface IManifestOp<in TManifest>
{
    void Apply(TManifest m);
}

/// <summary>
/// A manifest file plus an append-only journal of changes since it was written (port of JournalStore.swift), so a crash
/// or quit mid-run loses nothing: every finished item is one JSON line. <see cref="Compact"/> folds the journal back into
/// the manifest. A half-written last line (crash mid-write) is skipped on load. Both files are Cirrus' own state.
/// </summary>
sealed class JournalStore<TManifest, TOp> where TManifest : class, new() where TOp : class, IManifestOp<TManifest>
{
    public string BasePath { get; }
    public string JournalPath { get; }
    readonly object _lock = new();
    TManifest _m;
    static readonly JsonSerializerOptions Opts = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public JournalStore(string dir, string name)
    {
        Directory.CreateDirectory(dir);
        BasePath = Path.Combine(dir, name + ".json");
        JournalPath = Path.Combine(dir, name + ".journal");
        TManifest m;
        try { m = File.Exists(BasePath) ? JsonSerializer.Deserialize<TManifest>(File.ReadAllBytes(BasePath), Opts) ?? new() : new(); }
        catch (Exception e) { Log.Status("a move record couldn’t be read (" + e.GetType().Name + "); starting a new one"); m = new(); }
        if (File.Exists(JournalPath))
        {
            try
            {
                foreach (var line in File.ReadAllLines(JournalPath, Encoding.UTF8))
                {
                    if (line.Length == 0) continue;
                    TOp? op = null;
                    try { op = JsonSerializer.Deserialize<TOp>(line, Opts); } catch (JsonException) { }   // a torn line
                    op?.Apply(m);
                }
            }
            catch (IOException e) { Log.Status("a move journal couldn’t be read: " + e.GetType().Name); }
        }
        _m = m;
    }

    /// <summary>Reads under the lock (point lookups during a run).</summary>
    public T Read<T>(Func<TManifest, T> f) { lock (_lock) return f(_m); }

    /// <summary>A deep copy (evaluate and run starts).</summary>
    public TManifest Snapshot()
    {
        lock (_lock) return JsonSerializer.Deserialize<TManifest>(JsonSerializer.SerializeToUtf8Bytes(_m, Opts), Opts) ?? new();
    }

    public void Apply(TOp op)
    {
        lock (_lock)
        {
            op.Apply(_m);
            try
            {
                var line = JsonSerializer.Serialize(op, Opts) + "\n";
                // Opened per change so two engines for the same pair never write over each other's lines.
                using var fs = new FileStream(JournalPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                var bytes = Encoding.UTF8.GetBytes(line);
                fs.Write(bytes);
            }
            catch (Exception e) { Log.Status("a move journal line couldn’t be written: " + e.GetType().Name); }
        }
    }

    public void Compact()
    {
        lock (_lock)
        {
            try
            {
                var data = JsonSerializer.SerializeToUtf8Bytes(_m, Opts);
                var tmp = BasePath + ".tmp-" + Guid.NewGuid().ToString("N")[..6];
                File.WriteAllBytes(tmp, data);
                File.Move(tmp, BasePath, overwrite: true);
                if (File.Exists(JournalPath)) File.Delete(JournalPath);   // folded into the manifest just written
            }
            catch (Exception e) { Log.Status("a move record couldn’t be saved: " + e.GetType().Name); }
        }
    }
}

/// <summary>
/// One store per manifest file in this process, so an evaluation (Check Space) and a run for the same account pair
/// always share one view and one journal: a second instance compacting would otherwise drop the other's lines.
/// </summary>
static class JournalStores
{
    static readonly Dictionary<string, object> Open = new(StringComparer.OrdinalIgnoreCase);

    public static JournalStore<TManifest, TOp> Get<TManifest, TOp>(string dir, string name) where TManifest : class, new() where TOp : class, IManifestOp<TManifest>
    {
        var key = Path.GetFullPath(Path.Combine(dir, name + ".json"));
        lock (Open)
        {
            if (Open.TryGetValue(key, out var o) && o is JournalStore<TManifest, TOp> s) return s;
            var n = new JournalStore<TManifest, TOp>(dir, name);
            Open[key] = n;
            return n;
        }
    }
}

/// <summary>At most one run per account pair and direction at a time (a reopened window or a Retry can't start a second).</summary>
static class MoveRuns
{
    static readonly HashSet<string> Running = new(StringComparer.OrdinalIgnoreCase);
    public static bool TryBegin(string key) { lock (Running) return Running.Add(key); }
    public static void End(string key) { lock (Running) Running.Remove(key); }
    public static bool IsRunning(string key) { lock (Running) return Running.Contains(key); }

    public static SyncException Busy() => SyncException.Unavailable(
        "A move between these two accounts is already running. Follow it in Transfers; when it’s done, select Check Space to see what’s left.");
}
