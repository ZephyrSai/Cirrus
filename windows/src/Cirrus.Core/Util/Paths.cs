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
            var baseDir = Env.Get("CIRRUS_DATA_DIR");
            if (string.IsNullOrEmpty(baseDir)) baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            var profile = Env.Get("CIRRUS_PROFILE");
            // A profile is only a short label: never a path that could turn another folder into Cirrus' data folder.
            if (profile is not null && (profile.Length > 32 || !profile.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'))) profile = null;
            var dir = Path.Combine(baseDir, string.IsNullOrEmpty(profile) ? "Cirrus" : "Cirrus-" + profile);
            PrivateDir(dir);
            return dir;
        }
    }

    static readonly HashSet<string> Secured = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Owner-only, so other accounts on this PC can't read cached iCloud content: on Windows the folder stops
    /// inheriting permissions and grants only the current user (and SYSTEM); elsewhere it's mode 0700.
    /// Everything Cirrus stores (settings, secrets, caches, logs) lives below it.
    /// </summary>
    internal static void PrivateDir(string dir)
    {
        var created = !Directory.Exists(dir);
        Directory.CreateDirectory(dir);
        lock (Secured) { if (!Secured.Add(dir) && !created) return; }
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var info = new DirectoryInfo(dir);
                var sec = new System.Security.AccessControl.DirectorySecurity();
                sec.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
                var inherit = System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit;
                var me = System.Security.Principal.WindowsIdentity.GetCurrent().User!;
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(me, System.Security.AccessControl.FileSystemRights.FullControl,
                    inherit, System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
                sec.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(new System.Security.Principal.SecurityIdentifier(System.Security.Principal.WellKnownSidType.LocalSystemSid, null),
                    System.Security.AccessControl.FileSystemRights.FullControl, inherit, System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
                info.SetAccessControl(sec);
            }
            else File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        catch (Exception e) { Log.Status("couldn’t restrict the Cirrus data folder: " + e.GetType().Name); }
    }

    static bool IsAccountDir(string name) => name.Length == 16 && name.All(char.IsAsciiHexDigitLower);

    /// <summary>The newest modification time of a file, or of a folder and anything inside it.</summary>
    static DateTime LatestWrite(string path)
    {
        if (File.Exists(path)) return File.GetLastWriteTimeUtc(path);
        var latest = Directory.GetLastWriteTimeUtc(path);
        foreach (var f in Directory.EnumerateFileSystemEntries(path, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = 0 }))
        {
            var m = File.GetLastWriteTimeUtc(f);
            if (m > latest) latest = m;
        }
        return latest;
    }

    public static string Caches
    {
        get { var d = Path.Combine(AppSupport, "Cache"); Directory.CreateDirectory(d); return d; }
    }

    public static string CacheDir(string name) { var d = Path.Combine(Caches, name); Directory.CreateDirectory(d); return d; }

    /// <summary>A cache folder for one account (hashed name), so sign-out can clear exactly that account's copies.</summary>
    public static string AccountCacheDir(string name, string accountID) =>
        Path.Combine(CacheDir(name), Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(accountID ?? "")))[..16]);
    public static string SupportDir(string name) { var d = Path.Combine(AppSupport, name); Directory.CreateDirectory(d); return d; }

    /// <summary>Cache folders holding temporary copies, with how long their entries may live.</summary>
    public static readonly (string Name, TimeSpan MaxAge)[] ScratchCaches =
    [
        ("preview", TimeSpan.FromDays(1)), ("relay", TimeSpan.FromDays(1)), ("tmp", TimeSpan.FromDays(1)), ("dragout", TimeSpan.FromDays(1)),
        ("open", TimeSpan.FromDays(14)),
    ];

    /// <summary>
    /// Removes temporary copies (previews, relays, partial downloads) after a day, drag-out copies after a day and
    /// copies of iCloud files that were opened after two weeks, counted from the last time anything inside changed.
    /// Opened and dragged-out copies may hold the user's edits (apps often open a dropped file in place), so they go to
    /// the Recycle Bin (or .cirrus\Removed) instead of being deleted; the rest is Cirrus' own scratch data.
    /// </summary>
    public static void CleanCaches(DateTimeOffset? now = null)
    {
        var t = (now ?? DateTimeOffset.UtcNow).UtcDateTime;
        foreach (var (name, maxAge) in ScratchCaches)
        {
            string dir;
            try { dir = CacheDir(name); } catch { continue; }
            List<string> entries;
            try { entries = Directory.EnumerateFileSystemEntries(dir).Where(e => Path.GetFileName(e) != ".cirrus").ToList(); } catch { continue; }
            // Opened and preview copies are grouped per account: age each copy, not the whole account folder.
            if (name is "open" or "preview")
                entries = entries.SelectMany(e => Directory.Exists(e) && IsAccountDir(Path.GetFileName(e))
                    ? Directory.EnumerateFileSystemEntries(e).Where(x => Path.GetFileName(x) != ".cirrus") : [e]).ToList();
            foreach (var e in entries)
            {
                try
                {
                    if (t - LatestWrite(e) <= maxAge) continue;
                    if (name is "open" or "dragout") LocalFiles.SafeTrash(e, dir);
                    else if (Directory.Exists(e)) Directory.Delete(e, true);
                    else File.Delete(e);
                }
                catch { }
            }
        }
    }

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
        s = WinNames.MapsLocally ? WinNames.ToLocal(s) : s.Replace("/", ":");
        if (s == "." || s == ".." || s.Length == 0) s = "_" + s;
        return s;
    }

    public static string Combine(string root, string rel) =>
        string.IsNullOrEmpty(rel) ? root : Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar));
}

/// <summary>
/// iCloud names may contain characters Windows can't store (: * ? " &lt; &gt; | \ /, control characters, trailing dots
/// or spaces, device names like CON). Cirrus stores each such character as U+F000 + its code (the private-use mapping
/// WSL and Cygwin use) and maps it back when talking to iCloud. The mapping is exactly reversible: real names
/// (including full-width CJK punctuation such as ： ？) never change, so a sync between iCloud Drive and an
/// NTFS folder stays stable — no re-copies, no false deletes.
/// </summary>
public static class WinNames
{
    /// <summary>On by default on Windows; tests can switch it on elsewhere.</summary>
    public static bool MapsLocally { get; set; } = OperatingSystem.IsWindows();

    const int Base = 0xF000;
    const string Invalid = ":*?\"<>|\\/";

    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    static char Escape(char c) => (char)(Base + c);
    static bool IsEscaped(char c) => c >= Base && c < Base + 0x80;

    /// <summary>iCloud name → name safe to create on NTFS/FAT/exFAT.</summary>
    public static string ToLocal(string name)
    {
        if (string.IsNullOrEmpty(name)) return name;
        var chars = name.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
            if (chars[i] < 32 || Invalid.Contains(chars[i])) chars[i] = Escape(chars[i]);
        int end = chars.Length;
        while (end > 0 && (chars[end - 1] == '.' || chars[end - 1] == ' ')) end--;
        for (int i = end; i < chars.Length; i++) chars[i] = Escape(chars[i]);
        var s = new string(chars);
        var dot = s.IndexOf('.');
        var stem = dot < 0 ? s : s[..dot];
        if (Reserved.Contains(stem)) s = stem[..^1] + Escape(stem[^1]) + s[stem.Length..];
        return s;
    }

    /// <summary>On-disk name → the name iCloud should see (exact inverse of <see cref="ToLocal"/>).</summary>
    public static string FromLocal(string name)
    {
        if (string.IsNullOrEmpty(name)) return name;
        var chars = name.ToCharArray();
        for (int i = 0; i < chars.Length; i++) if (IsEscaped(chars[i])) chars[i] = (char)(chars[i] - Base);
        return new string(chars);
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
