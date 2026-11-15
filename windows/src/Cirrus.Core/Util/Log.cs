using System.Text;
using System.Text.RegularExpressions;

namespace Cirrus.Core;

/// <summary>
/// Logging. Never pass passwords, cookies, tokens or Apple IDs here; as a second line of defence every
/// message is also scrubbed by <see cref="Redact"/> before it is written anywhere.
/// Writes to %LOCALAPPDATA%\Cirrus\Logs\cirrus.log (rotated at 4 MB) and to stderr when CIRRUS_DEBUG is set.
/// </summary>
public static partial class Log
{
    public static bool Verbose { get; set; } = Environment.GetEnvironmentVariable("CIRRUS_DEBUG") is not null;
    static readonly object Gate = new();
    const long MaxBytes = 4 << 20;

    /// <summary>Optional sink (the app shows recent lines in Settings › About). Receives redacted text only.</summary>
    public static event Action<string>? Line;

    public static void Info(string message) => Write("INFO", message, alwaysToFile: true);
    public static void Debug(string message) { if (Verbose) Write("DEBUG", message, alwaysToFile: false); }
    public static void Error(string message) => Write("ERROR", message, alwaysToFile: true);

    static void Write(string level, string message, bool alwaysToFile)
    {
        var safe = Redact(message);
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {safe}";
        if (Verbose) { try { Console.Error.WriteLine("[cirrus] " + line); } catch { } }
        if (alwaysToFile || Verbose)
        {
            try
            {
                lock (Gate)
                {
                    var dir = Paths.SupportDir("Logs");
                    var file = Path.Combine(dir, "cirrus.log");
                    var fi = new FileInfo(file);
                    if (fi.Exists && fi.Length > MaxBytes)
                    {
                        var old = Path.Combine(dir, "cirrus.1.log");
                        File.Move(file, old, overwrite: true);
                    }
                    File.AppendAllText(file, line + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch { /* logging must never break the app */ }
        }
        Line?.Invoke(line);
    }

    [GeneratedRegex(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")]
    private static partial Regex EmailRx();

    [GeneratedRegex(@"(?i)\b(password|passwd|pwd|cookie|set-cookie|token|trusttoken|sessiontoken|dswebauthtoken|scnt|session-id|authorization|x-apple-[a-z0-9\-]+)\b\s*[:=]\s*(""[^""]*""|[^\s;,&]+)")]
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
