using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Cirrus.App.Model;
using Cirrus.App.Platform;
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>
/// Type icons and thumbnails: photos (iCloud renditions), local images, PDFs and videos (Explorer's own thumbnails),
/// and iCloud Drive images and PDFs up to 25 MB, which are fetched once into the preview cache because iCloud.com has
/// no thumbnail API. Bounded concurrency and a small memory cache.
/// </summary>
static class Thumbnails
{
    static readonly SemaphoreSlim PhotoGate = new(12);       // iCloud Photos renditions (small, many)
    static readonly SemaphoreSlim LocalGate = new(4);
    static readonly SemaphoreSlim PreviewGate = new(3);      // whole-file downloads for iCloud Drive previews
    static readonly object Lock = new();
    static readonly Dictionary<string, ImageSource> Memory = [];
    static readonly LinkedList<string> Order = new();
    const int MaxEntries = 1500;
    public const long DrivePreviewMax = 25_000_000;
    static readonly HashSet<string> Decodable = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".ico", ".heic", ".heif", ".webp", ".jxr", ".wdp" };
    static readonly HashSet<string> ShellPreviewable = new(StringComparer.OrdinalIgnoreCase) { ".pdf", ".mp4", ".mov", ".m4v", ".avi", ".wmv", ".mkv" };

    /// <summary>Sets Icon right away (UI thread) and fills Thumbnail later for photos and previewable files.</summary>
    public static void Attach(Item item, bool large)
    {
        if (item.Icon is null)
        {
            if (item.LocalPath is { } p && (item.Volume is not null || item.Key.StartsWith("native")))
                item.Icon = ShellIcons.ForPath(p, large);
            else if (item.Album is null && item.Photo is null)
                item.Icon = ShellIcons.ForName(item.Name, item.IsContainer, large);
        }
    }

    static bool DrivePreviewable(Item item) =>
        item.Node is { IsFolder: false } n && Settings.Current.DrivePreviews && n.Size is > 0 and <= DrivePreviewMax
        && (Decodable.Contains(Path.GetExtension(n.Name)) || Path.GetExtension(n.Name).Equals(".pdf", StringComparison.OrdinalIgnoreCase));

    static bool LocalPreviewable(Item item) =>
        item.LocalPath is { } lp && !item.IsContainer && item.Cloud != LocalFiles.CloudState.CloudOnly
        && ((Decodable.Contains(Path.GetExtension(lp)) && (item.Size ?? 0) < 60_000_000) || ShellPreviewable.Contains(Path.GetExtension(lp)));

    public static bool CanPreview(Item item) => item.Photo is not null || DrivePreviewable(item) || LocalPreviewable(item);

    public static async Task Load(Item item, int px, CancellationToken ct)
    {
        if (item.Thumbnail is not null || !CanPreview(item)) return;
        var key = item.Key + "|" + (item.Node?.Etag ?? item.Modified?.ToUnixTimeSeconds().ToString() ?? "") + "@" + px;
        lock (Lock) if (Memory.TryGetValue(key, out var hit)) { item.Thumbnail = hit; return; }
        var gate = item.Photo is not null ? PhotoGate : item.Node is not null ? PreviewGate : LocalGate;
        await gate.WaitAsync(ct);
        try
        {
            ct.ThrowIfCancellationRequested();
            ImageSource? img = null;
            if (item.Photo is { } asset && AccountManager.Shared.Account(item.AccountID)?.Photos is { } backend)
            {
                var data = await backend.ThumbnailAsync(asset, px, ct);
                if (data is not null) img = await Task.Run(() => Decode(new MemoryStream(data), px), ct);
            }
            else if (item.Node is { } node && AccountManager.Shared.Account(item.AccountID)?.Drive is { } drive)
            {
                // Read-only: the file is downloaded once into Cirrus' preview cache (keyed by item and version, cleared after a day).
                var dir = Paths.AccountCacheDir("preview", item.AccountID ?? "");
                Directory.CreateDirectory(dir);
                var cached = Path.Combine(dir, Hash(item.Key + "|" + node.Etag + "|" + node.Size) + Path.GetExtension(node.Name).ToLowerInvariant());
                if (!File.Exists(cached))
                {
                    var tmp = Paths.TempFile("preview" + Path.GetExtension(node.Name));
                    try
                    {
                        await drive.DownloadAsync(node, tmp, null, ct);
                        File.Move(tmp, cached, overwrite: true);
                    }
                    finally { try { Directory.Delete(Path.GetDirectoryName(tmp)!, true); } catch { } }   // our own scratch folder
                }
                img = await FromFile(cached, px, ct);
            }
            else if (item.LocalPath is { } path)
                img = await FromFile(path, px, ct);
            if (img is null) return;
            lock (Lock)
            {
                Memory[key] = img;
                Order.AddLast(key);
                while (Order.Count > MaxEntries) { Memory.Remove(Order.First!.Value); Order.RemoveFirst(); }
            }
            item.Thumbnail = img;
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Debug("thumbnail failed: " + e.GetType().Name); }
        finally { gate.Release(); }
    }

    static async Task<ImageSource?> FromFile(string path, int px, CancellationToken ct)
    {
        if (Decodable.Contains(Path.GetExtension(path)))
        {
            var img = await Task.Run(() => { using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); return Decode(fs, px); }, ct);
            if (img is not null) return img;
        }
        return await ShellThumbnails.GetAsync(path, px);   // PDFs, videos, and images WPF can't decode (e.g. HEIC without the codec)
    }

    /// <summary>Sign-out: drop that account's thumbnails from memory.</summary>
    public static void Forget(string accountID)
    {
        lock (Lock)
            foreach (var k in Memory.Keys.Where(k => k.Contains(":" + accountID + "|", StringComparison.Ordinal)).ToList())
            {
                Memory.Remove(k);
                Order.Remove(k);
            }
    }

    static string Hash(string s) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(s)))[..24];

    /// <summary>Decodes at reduced size and applies the EXIF orientation. Frozen, so any thread can use it.</summary>
    public static BitmapSource? Decode(Stream s, int px)
    {
        try
        {
            var bytes = new MemoryStream();
            s.CopyTo(bytes);
            bytes.Position = 0;
            var frame = BitmapFrame.Create(bytes, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
            int orientation = 1;
            try { if (frame.Metadata is BitmapMetadata md && md.GetQuery("System.Photo.Orientation") is ushort o) orientation = o; } catch { }
            bytes.Position = 0;
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            if (frame.PixelWidth >= frame.PixelHeight) bi.DecodePixelWidth = Math.Min(px, Math.Max(1, frame.PixelWidth));
            else bi.DecodePixelHeight = Math.Min(px, Math.Max(1, frame.PixelHeight));
            bi.StreamSource = bytes;
            bi.EndInit();
            bi.Freeze();
            BitmapSource result = bi;
            var angle = orientation switch { 3 => 180, 6 => 90, 8 => 270, _ => 0 };
            if (angle != 0)
            {
                var tb = new TransformedBitmap(bi, new RotateTransform(angle));
                tb.Freeze();
                result = tb;
            }
            return result;
        }
        catch { return null; }
    }

    /// <summary>Core hook: originals used as large previews are cached as JPEGs (≤ maxPixel), like the Mac app.</summary>
    public static byte[]? ToJpeg(byte[] data, int maxPixel)
    {
        try
        {
            if (Decode(new MemoryStream(data), maxPixel) is not { } bmp) return null;
            var enc = new JpegBitmapEncoder { QualityLevel = 85 };
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }
        catch { return null; }
    }
}
