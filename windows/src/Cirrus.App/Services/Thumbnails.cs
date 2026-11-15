using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Cirrus.App.Model;
using Cirrus.App.Platform;
using Cirrus.Core;

namespace Cirrus.App.Services;

/// <summary>Loads type icons and thumbnails (photos, local images) with bounded concurrency and a small memory cache.</summary>
static class Thumbnails
{
    static readonly SemaphoreSlim Gate = new(6);
    static readonly object Lock = new();
    static readonly Dictionary<string, ImageSource> Memory = [];
    static readonly LinkedList<string> Order = new();
    const int MaxEntries = 800;
    static readonly HashSet<string> Decodable = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".ico", ".heic", ".heif", ".webp", ".jxr", ".wdp" };

    /// <summary>Sets Icon right away (UI thread) and fills Thumbnail later for photos and images.</summary>
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

    public static async Task Load(Item item, int px, CancellationToken ct)
    {
        if (item.Thumbnail is not null) return;
        var key = item.Key + "@" + px;
        lock (Lock) if (Memory.TryGetValue(key, out var hit)) { item.Thumbnail = hit; return; }
        if (!(item.Photo is not null || (item.LocalPath is { } lp && !item.IsContainer && Decodable.Contains(Path.GetExtension(lp)) && (item.Size ?? 0) < 60_000_000
              && item.Cloud != LocalFiles.CloudState.CloudOnly))) return;
        await Gate.WaitAsync(ct);
        try
        {
            ct.ThrowIfCancellationRequested();
            ImageSource? img = null;
            if (item.Photo is { } asset && AccountManager.Shared.Account(item.AccountID)?.Photos is { } backend)
            {
                var data = await backend.ThumbnailAsync(asset, px, ct);
                if (data is not null) img = await Task.Run(() => Decode(new MemoryStream(data), px), ct);
            }
            else if (item.LocalPath is { } path)
                img = await Task.Run(() => { using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); return Decode(fs, px); }, ct);
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
        finally { Gate.Release(); }
    }

    /// <summary>Decodes at reduced size and applies the EXIF orientation. Frozen, so any thread can use it.</summary>
    public static ImageSource? Decode(Stream s, int px)
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
}
