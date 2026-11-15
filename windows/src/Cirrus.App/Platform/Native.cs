using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Cirrus.Core;
using Windows.Security.Credentials.UI;

namespace Cirrus.App.Platform;

/// <summary>
/// Windows Hello (UserConsentVerifier) first; when Hello isn't set up, the Windows account password through
/// the standard credential prompt, verified with LogonUser and checked to belong to the signed-in user.
/// </summary>
sealed class WindowsPresence : IUserPresence
{
    public async Task<bool> VerifyAsync(string reason, CancellationToken ct)
    {
        var hwnd = await Application.Current.Dispatcher.InvokeAsync(MainHandle);
        try
        {
            var availability = await UserConsentVerifier.CheckAvailabilityAsync().AsTask(ct);
            if (availability == UserConsentVerifierAvailability.Available)
            {
                var result = hwnd != IntPtr.Zero
                    ? await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, reason).AsTask(ct)
                    : await UserConsentVerifier.RequestVerificationAsync(reason).AsTask(ct);
                Log.Status("Windows Hello: " + result);
                return result == UserConsentVerificationResult.Verified;
            }
            Log.Status("Windows Hello unavailable (" + availability + "); asking for the Windows password");
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { Log.Status("Windows Hello failed: " + e.GetType().Name); }
        return await Application.Current.Dispatcher.InvokeAsync(() => WindowsPassword.Verify(hwnd, reason));
    }

    static IntPtr MainHandle()
    {
        var w = Application.Current.Windows.OfType<Window>().FirstOrDefault(x => x.IsActive) ?? Application.Current.MainWindow;
        return w is null ? IntPtr.Zero : new WindowInteropHelper(w).Handle;
    }
}

static class WindowsPassword
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDUI_INFO
    {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    const int CREDUIWIN_ENUMERATE_CURRENT_USER = 0x200;

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    static extern int CredUIPromptForWindowsCredentials(ref CREDUI_INFO info, int authError, ref uint authPackage, IntPtr inBuf, uint inBufSize,
        out IntPtr outBuf, out uint outBufSize, ref bool save, int flags);

    [DllImport("credui.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredUnPackAuthenticationBuffer(int flags, IntPtr buf, uint size, StringBuilder user, ref int maxUser, StringBuilder domain, ref int maxDomain,
        StringBuilder password, ref int maxPassword);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUser(string user, string? domain, string password, int logonType, int provider, out IntPtr token);

    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);

    /// <summary>Shows Windows' own credential prompt for the current user and checks the password with LogonUser.</summary>
    public static bool Verify(IntPtr owner, string reason)
    {
        var info = new CREDUI_INFO { cbSize = Marshal.SizeOf<CREDUI_INFO>(), hwndParent = owner, pszCaptionText = "Cirrus", pszMessageText = reason };
        uint package = 0;
        bool save = false;
        var rc = CredUIPromptForWindowsCredentials(ref info, 0, ref package, IntPtr.Zero, 0, out var buf, out var size, ref save, CREDUIWIN_ENUMERATE_CURRENT_USER);
        if (rc != 0) return false;   // cancelled
        var user = new StringBuilder(514); var domain = new StringBuilder(338); var pw = new StringBuilder(256);
        int mu = user.Capacity, md = domain.Capacity, mp = pw.Capacity;
        try
        {
            if (!CredUnPackAuthenticationBuffer(0, buf, size, user, ref mu, domain, ref md, pw, ref mp)) return false;
            var u = user.ToString();
            string? d = domain.Length > 0 ? domain.ToString() : null;
            var slash = u.IndexOf('\\');
            if (d is null && slash > 0) { d = u[..slash]; u = u[(slash + 1)..]; }
            if (!LogonUser(u, d, pw.ToString(), 2 /* interactive */, 0, out var token)) return false;
            try
            {
                using var who = new WindowsIdentity(token);
                return who.User is not null && who.User == WindowsIdentity.GetCurrent().User;   // must be the signed-in user
            }
            finally { CloseHandle(token); }
        }
        finally
        {
            pw.Clear(); pw.Append('\0', pw.Capacity); pw.Clear();
            if (buf != IntPtr.Zero)
            {
                for (int i = 0; i < size; i++) Marshal.WriteByte(buf, i, 0);
                CoTaskMemFree(buf);
            }
        }
    }
}

/// <summary>Keeps the PC from idle-sleeping while transfers or jobs run.</summary>
static class KeepAwake
{
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x00000001;
    static bool _on;

    public static void Set(bool busy)
    {
        if (busy == _on) return;
        _on = busy;
        SetThreadExecutionState(busy ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
    }
}

/// <summary>Explorer's icons for files, folders and drives (SHGetFileInfo), cached by type.</summary>
static class ShellIcons
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon; public int iIcon; public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attrs, ref SHFILEINFO info, uint size, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

    const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0, SHGFI_SMALLICON = 0x1, SHGFI_USEFILEATTRIBUTES = 0x10, SHGFI_TYPENAME = 0x400;
    const uint FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_NORMAL = 0x80;
    static readonly Dictionary<string, ImageSource?> Cache = [];
    static readonly Dictionary<string, string> Types = [];

    public static ImageSource? ForName(string name, bool folder, bool large)
    {
        var ext = folder ? "<folder>" : Path.GetExtension(name).ToLowerInvariant();
        // .exe/.ico/.lnk carry their own icons; use the generic one for names that aren't on disk.
        return Get((large ? "L" : "S") + ext, folder ? "folder" : "x" + ext, folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL, true, large);
    }

    public static ImageSource? ForPath(string path, bool large)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        var own = ext is ".exe" or ".ico" or ".lnk" or ".url" || Path.GetPathRoot(path) == path;
        if (!own) return ForName(path, Directory.Exists(path), large);
        return Get((large ? "L" : "S") + path.ToLowerInvariant(), path, 0, false, large);
    }

    static ImageSource? Get(string key, string path, uint attrs, bool useAttrs, bool large)
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (Cache.TryGetValue(key, out var hit)) return hit;
        ImageSource? img = null;
        try
        {
            var info = new SHFILEINFO();
            var flags = SHGFI_ICON | (large ? SHGFI_LARGEICON : SHGFI_SMALLICON) | (useAttrs ? SHGFI_USEFILEATTRIBUTES : 0);
            if (SHGetFileInfo(path, attrs, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), flags) != IntPtr.Zero && info.hIcon != IntPtr.Zero)
            {
                var bs = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                bs.Freeze();
                img = bs;
                DestroyIcon(info.hIcon);
            }
        }
        catch { }
        if (Cache.Count > 2000) Cache.Clear();
        Cache[key] = img;
        return img;
    }

    /// <summary>Explorer's type name ("Text Document", "JPEG image"…).</summary>
    public static string TypeName(string name, bool folder)
    {
        if (folder) return "File folder";
        var ext = Path.GetExtension(name).ToLowerInvariant();
        if (Types.TryGetValue(ext, out var t)) return t;
        var s = "";
        if (OperatingSystem.IsWindows())
        {
            try
            {
                var info = new SHFILEINFO();
                SHGetFileInfo("x" + ext, FILE_ATTRIBUTE_NORMAL, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_TYPENAME | SHGFI_USEFILEATTRIBUTES);
                s = info.szTypeName ?? "";
            }
            catch { }
        }
        if (s.Length == 0) s = ext.Length > 1 ? ext[1..].ToUpperInvariant() + " File" : "File";
        Types[ext] = s;
        return s;
    }
}
