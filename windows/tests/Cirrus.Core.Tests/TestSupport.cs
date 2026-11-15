using System.Runtime.CompilerServices;
using System.Text;

// Tests share process-wide switches (read-only mode, demo backends, name mapping), so run them one at a time.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Cirrus.Core.Tests;

static class TestEnv
{
    public static readonly string Root = Path.Combine(Path.GetTempPath(), "cirrus-dotnet-tests-" + Guid.NewGuid().ToString("N")[..8]);

    /// <summary>Runs before any test: keep every Cirrus file (settings, caches, demo store) in a temp folder.</summary>
    [ModuleInitializer]
    internal static void Init()
    {
        Directory.CreateDirectory(Root);
        Environment.SetEnvironmentVariable("CIRRUS_DATA_DIR", Path.Combine(Root, "data"));
        Environment.SetEnvironmentVariable("CIRRUS_PROFILE", "tests");
        Environment.SetEnvironmentVariable("CIRRUS_DEMO_FAST", "1");
        Environment.SetEnvironmentVariable("CIRRUS_DEMO_PHOTOS", "30");
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_DRIVE", null);
        Environment.SetEnvironmentVariable("CIRRUS_NATIVE_PHOTOS", null);
        LocalFiles.Recycler = new QuarantineRecycler();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => { try { Directory.Delete(Root, true); } catch { } };   // test scratch only
    }

    public static string TempDir(string name)
    {
        var d = Path.Combine(Root, $"{name}-{Guid.NewGuid().ToString("N")[..6]}");
        Directory.CreateDirectory(d);
        return d;
    }

    public static void Write(string text, string path, double? mtime = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
        if (mtime is double m) File.SetLastWriteTimeUtc(path, DateTimeOffset.FromUnixTimeMilliseconds((long)(m * 1000)).UtcDateTime);
    }

    public static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    public static byte[] Hex(string s) => Convert.FromHexString(s.Length % 2 == 1 ? "0" + s : s);

    /// <summary>Every file below a folder, as relative paths with forward slashes.</summary>
    public static HashSet<string> Tree(string root) =>
        Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories)
            .Select(p => Path.GetRelativePath(root, p).Replace('\\', '/')).ToHashSet();
}

/// <summary>Test-only protector (XOR with the entropy); the real app uses DPAPI.</summary>
sealed class XorProtector : ISecretProtector
{
    public byte[] Protect(byte[] data, byte[] entropy) => data.Select((b, i) => (byte)(b ^ entropy[i % entropy.Length] ^ 0x5A)).ToArray();
    public byte[] Unprotect(byte[] data, byte[] entropy) => Protect(data, entropy);
}

/// <summary>Collects every log line written while it's alive.</summary>
sealed class LogCapture : IDisposable
{
    readonly StringBuilder _sb = new();
    readonly bool _verbose;
    public LogCapture() { _verbose = Log.Verbose; Log.Verbose = true; Log.Line += OnLine; }
    void OnLine(string l) { lock (_sb) _sb.AppendLine(l); }
    public string Text { get { lock (_sb) return _sb.ToString(); } }
    public void Dispose() { Log.Line -= OnLine; Log.Verbose = _verbose; }
}
