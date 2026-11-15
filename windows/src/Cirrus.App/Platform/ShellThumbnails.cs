using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Cirrus.Core;

namespace Cirrus.App.Platform;

/// <summary>
/// Explorer's thumbnails (IShellItemImageFactory): PDFs, videos, and images WPF can't decode itself, through whatever
/// thumbnail handlers Windows has. The Windows counterpart of the Mac app's Quick Look thumbnails. Runs on its own
/// STA thread because some thumbnail handlers require one.
/// </summary>
static class ShellThumbnails
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SIZE { public int cx, cy; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);

    const int SIIGBF_BIGGERSIZEOK = 0x1, SIIGBF_THUMBNAILONLY = 0x8;

    public static Task<ImageSource?> GetAsync(string path, int px)
    {
        if (!OperatingSystem.IsWindows()) return Task.FromResult<ImageSource?>(null);
        var tcs = new TaskCompletionSource<ImageSource?>();
        var t = new Thread(() =>
        {
            try { tcs.SetResult(Get(path, px)); }
            catch (Exception e) { Log.Debug("shell thumbnail failed: " + e.GetType().Name); tcs.TrySetResult(null); }
        }) { IsBackground = true, Name = "Cirrus thumbnail" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        return tcs.Task;
    }

    static ImageSource? Get(string path, int px)
    {
        SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out var factory);
        try
        {
            if (factory.GetImage(new SIZE { cx = px, cy = px }, SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK, out var hbm) != 0 || hbm == IntPtr.Zero) return null;
            try
            {
                var bs = Imaging.CreateBitmapSourceFromHBitmap(hbm, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                bs.Freeze();
                return bs;
            }
            finally { DeleteObject(hbm); }
        }
        finally { Marshal.ReleaseComObject(factory); }
    }
}
