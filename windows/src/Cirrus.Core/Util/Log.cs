using System.Text;
using System.Text.RegularExpressions;

namespace Cirrus.Core;

/// <summary>
/// Logging, split like the Mac app's:
/// <list type="bullet">
/// <item><see cref="Status"/>: diagnostics with no user content (HTTP status lines, timings, counts, error types). The
/// only level written to %LOCALAPPDATA%\Cirrus\Logs\cirrus.log (rotated at 4 MB).</item>
/// <item><see cref="Info"/>, <see cref="Error"/>, <see cref="Debug"/>: may mention file names or other user content, so
/// they are never written to disk; with CIRRUS_DEBUG (Debug builds only) they go to stderr.</item>
/// </list>
/// Never pass passwords, cookies, tokens or Apple IDs to any of them; as a second line of defence every message is
/// scrubbed by <see cref="Redact"/> as well.
/// </summary>
public static partial class Log
{
    static bool? _verbose;
    public static bool Verbose { get => _verbose ?? Env.Flag("CIRRUS_DEBUG"); set => _verbose = value; }
    static readonly object Gate = new();
    const long MaxBytes = 4 << 20;

    /// <summary>Receives every redacted line (tests). Not persisted.</summary>
    public static event Action<string>? Line;

    /// <summary>Content-free diagnostics: the only level kept in the log file.</summary>
    public static void Status(string message) => Write("STATUS", message, persist: true);
    /// <summary>May mention file names: never written to disk.</summary>
    public static void Info(string message) => Write("INFO", message, persist: false);
    public static void Debug(string message) { if (Verbose) Write("DEBUG", message, persist: false); }
    /// <summary>May mention file names: never written to disk. Pair with a content-free <see cref="Status"/> if it matters.</summary>
    public static void Error(string message) => Write("ERROR", message, persist: false);

    /// <summary>Where <see cref="Status"/> lines go.</summary>
    public static string FilePath => Path.Combine(Paths.SupportDir("Logs"), "cirrus.log");

    static void Write(string level, string message, bool persist)
    {
        var safe = Redact(message);
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {safe}";
        if (Verbose) { try { Console.Error.WriteLine("[cirrus] " + line); } catch { } }
        if (persist)
        {
            try
            {
                lock (Gate)
                {
                    var file = FilePath;
                    var fi = new FileInfo(file);
                    if (fi.Exists && fi.Length > MaxBytes) File.Move(file, Path.Combine(Path.GetDirectoryName(file)!, "cirrus.1.log"), overwrite: true);
                    File.AppendAllText(file, line + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch { /* logging must never break the app */ }
        }
        Line?.Invoke(line);
    }

    [GeneratedRegex(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")]
    private static partial Regex EmailRx();

    [GeneratedRegex(@"(?i)""?\b(password|passwd|pwd|cookie|set-cookie|token|trusttoken|trusttokens|sessiontoken|dswebauthtoken|scnt|session-id|authorization|m1|m2|accountname|appleid|x-apple-[a-z0-9\-]+)\b""?\s*[:=]\s*(""[^""]*""|\[[^\]]*\]|[^\s;,&}]+)")]
    private static partial Regex SecretKvRx();

    [GeneratedRegex(@"\+\d[\d \-().]{6,}\d|\b\d{10,15}\b")]
    private static partial Regex PhoneRx();

    [GeneratedRegex(@"(?=[A-Za-z0-9+/_\-]*\d)(?=[A-Za-z0-9+/_\-]*[A-Z])(?=[A-Za-z0-9+/_\-]*[a-z])[A-Za-z0-9+/_\-]{40,}={0,2}")]
    private static partial Regex LongTokenRx();

    /// <summary>
    /// Removes anything that looks like an Apple ID (email or phone number), a key=value secret
    /// (password, cookie, token, scnt, X-Apple-* headers) or a long opaque token.
    /// </summary>
    public static string Redact(string message)
    {
        if (string.IsNullOrEmpty(message)) return message;
        var s = SecretKvRx().Replace(message, m => m.Groups[1].Value + "=<redacted>");
        s = EmailRx().Replace(s, "<apple-id>");
        s = LongTokenRx().Replace(s, "<token>");
        s = PhoneRx().Replace(s, "<phone>");
        return s;
    }
}
