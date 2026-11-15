using System.Globalization;
using System.Text;

namespace Cirrus.Core;

/// <summary>Where Cirrus keeps settings, secrets, caches and scratch files.</summary>
public static class Paths
{
    /// <summary>
    /// %LOCALAPPDATA%\Cirrus (or Cirrus-&lt;CIRRUS_PROFILE&gt;). CIRRUS_DATA_DIR overrides the base folder
    /// (the unit tests point it at a temp folder so they never touch real settings).
    /// </summary>
    public static string AppSupport
    {
        get
        {
            var baseDir = Environment.GetEnvironmentVariable("CIRRUS_DATA_DIR");
            if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            var profile = Environment.GetEnvironmentVariable("CIRRUS_PROFILE");
            var dir = Path.Combine(baseDir, string.IsNullOrEmpty(profile) ? "Cirrus" : "Cirrus-" + profile);
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string Caches
    {
        get { var d = Path.Combine(AppSupport, "Cache"); Directory.CreateDirectory(d); return d; }
    }

    public static string CacheDir(string name) { var d = Path.Combine(Caches, name); Directory.CreateDirectory(d); return d; }
    public static string SupportDir(string name) { var d = Path.Combine(AppSupport, name); Directory.CreateDirectory(d); return d; }

    /// <summary>A unique scratch file location (its own folder) for downloads in flight.</summary>
    public static string TempFile(string name)
    {
        var dir = Path.Combine(CacheDir("tmp"), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, string.IsNullOrEmpty(name) ? "file" : SafeName(name));
    }

    /// <summary>File-system-safe version of a name coming from the network (reversible on Windows, see <see cref="WinNames"/>).</summary>
    public static string SafeName(string name)
    {
        var s = (name ?? "").Replace("\0", "");
        s = s.Replace("/", WinNames.MapsLocally ? "／" : ":");
        if (WinNames.MapsLocally) s = WinNames.ToLocal(s);
        if (s == "." || s == ".." || s.Length == 0) s = "_" + s;
        return s;
    }

    public static string Combine(string root, string rel) =>
        string.IsNullOrEmpty(rel) ? root : Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar));
}

/// <summary>
/// iCloud names may contain characters Windows can't store (: * ? " &lt; &gt; | \ and trailing dots or spaces).
/// Cirrus maps them to look-alike full-width characters on disk and back again when talking to iCloud,
/// so a sync between iCloud Drive and an NTFS folder stays stable (no re-copies, no false deletes).
/// </summary>
public static class WinNames
{
    /// <summary>On by default on Windows; tests can switch it on elsewhere.</summary>
    public static bool MapsLocally { get; set; } = OperatingSystem.IsWindows();

    static readonly (char ascii, char wide)[] Map =
    [
        (':', '：'), ('*', '＊'), ('?', '？'), ('"', '＂'), ('<', '＜'), ('>', '＞'), ('|', '｜'), ('\\', '＼'),
    ];

    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };
    const char ReservedMark = '＿';   // full-width low line
    const char TrailingDot = '．';
    const char TrailingSpace = ' ';

    /// <summary>iCloud name → name safe to create on NTFS/FAT/exFAT.</summary>
    public static string ToLocal(string name)
    {
        if (string.IsNullOrEmpty(name)) return name;
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
        {
            if (c < 32) { sb.Append((char)(0x2400 + c)); continue; }    // control pictures (e.g. "Icon\r")
            var m = Array.FindIndex(Map, p => p.ascii == c);
            sb.Append(m >= 0 ? Map[m].wide : c);
        }
        int end = sb.Length;
        while (end > 0 && (sb[end - 1] == '.' || sb[end - 1] == ' ')) end--;
        for (int i = end; i < sb.Length; i++) sb[i] = sb[i] == '.' ? TrailingDot : TrailingSpace;
        var s = sb.ToString();
        var stem = s.Split('.')[0];
        if (Reserved.Contains(stem)) s = stem + ReservedMark + s[stem.Length..];
        return s;
    }

    /// <summary>On-disk name → the name iCloud should see.</summary>
    public static string FromLocal(string name)
    {
        if (string.IsNullOrEmpty(name)) return name;
        var stemEnd = name.IndexOf('.');
        var stem = stemEnd < 0 ? name : name[..stemEnd];
        if (stem.Length > 1 && stem[^1] == ReservedMark && Reserved.Contains(stem[..^1])) name = stem[..^1] + name[stem.Length..];
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
        {
            if (c >= 0x2400 && c < 0x2420) { sb.Append((char)(c - 0x2400)); continue; }
            var m = Array.FindIndex(Map, p => p.wide == c);
            sb.Append(m >= 0 ? Map[m].ascii : c);
        }
        int k = sb.Length;
        while (k > 0 && (sb[k - 1] == TrailingDot || sb[k - 1] == TrailingSpace)) k--;
        for (int i = k; i < sb.Length; i++) sb[i] = sb[i] == TrailingDot ? '.' : ' ';
        return sb.ToString();
    }

    public static string RelToLocal(string rel) => MapsLocally ? string.Join('/', rel.Split('/').Select(ToLocal)) : rel;
    public static string RelFromLocal(string rel) => MapsLocally ? string.Join('/', rel.Split('/').Select(FromLocal)) : rel;
}

public static class ByteFormat
{
    /// <summary>Decimal units like Apple's storage figures: "512 bytes", "12 KB", "3.4 MB", "1.25 GB".</summary>
    public static string ByteString(this long bytes)
    {
        var ci = CultureInfo.CurrentCulture;
        if (bytes == 0) return "Zero bytes";
        var neg = bytes < 0 ? "-" : "";
        double b = Math.Abs((double)bytes);
        if (b < 1000) return neg + (b == 1 ? "1 byte" : $"{b:0} bytes");
        string[] units = ["KB", "MB", "GB", "TB", "PB"];
        int u = -1;
        while (b >= 1000 && u < units.Length - 1) { b /= 1000; u++; }
        var fmt = u switch { 0 => "0", 1 => "0.#", _ => "0.##" };
        return neg + b.ToString(fmt, ci) + " " + units[u];
    }

    public static string ByteString(this int bytes) => ((long)bytes).ByteString();
}
