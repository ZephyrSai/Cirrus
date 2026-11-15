using System.Text.Json.Serialization;

namespace Cirrus.Core;

public sealed class PhotoLibraryRef
{
    public string Id { get; set; } = "";             // CloudKit zone (PrimarySync, SharedSync-…) or "demo"
    public string Name { get; set; } = "";
    public bool IsShared { get; set; }
    public string Area { get; set; } = "private";
    public string? OwnerRecordName { get; set; }
    public string? ZoneType { get; set; }
    public PhotoLibraryRef() { }
    public PhotoLibraryRef(string id, string name, bool isShared) { Id = id; Name = name; IsShared = isShared; }
}

public enum PhotoAlbumKind { Smart, Album, Folder, Shared }

public sealed class PhotoAlbum : IEquatable<PhotoAlbum>
{
    public string Id { get; set; } = "";             // "smart:All Photos", "album:<record>", "folder:<record>"
    public string Name { get; set; } = "";
    public PhotoAlbumKind Kind { get; set; }
    public string? ParentID { get; set; }
    public int? Count { get; set; }
    public string Symbol { get; set; } = "album";
    [JsonIgnore] public bool IsDeletedBin => Id == "smart:Recently Deleted";
    [JsonIgnore] public bool IsAllPhotos => Id == "smart:All Photos";
    public PhotoAlbum() { }
    public PhotoAlbum(string id, string name, PhotoAlbumKind kind, string? parentID = null, int? count = null, string symbol = "album")
    { Id = id; Name = name; Kind = kind; ParentID = parentID; Count = count; Symbol = symbol; }
    public bool Equals(PhotoAlbum? o) => o is not null && Id == o.Id;
    public override bool Equals(object? obj) => Equals(obj as PhotoAlbum);
    public override int GetHashCode() => Id.GetHashCode();
}

public enum PhotoResourceKind { Original, LiveVideo, Edited, Alternate, Thumbnail, Medium }

public sealed class PhotoResource
{
    public PhotoResourceKind Kind { get; set; }
    public string Filename { get; set; } = "";
    public long Size { get; set; }
    public string Key { get; set; } = "";            // CloudKit field name
    public string RecordName { get; set; } = "";     // record that owns the field
    public string? Url { get; set; }                 // signed download URL (expires)
    public string? Uti { get; set; }
    public PhotoResource Copy() => (PhotoResource)MemberwiseClone();
}

public sealed class PhotoAsset : IEquatable<PhotoAsset>
{
    public string Id { get; set; } = "";             // CPLAsset record name
    public string? MasterID { get; set; }
    public string? ChangeTag { get; set; }
    public string Library { get; set; } = "";
    public string Filename { get; set; } = "";
    public long Size { get; set; }
    public DateTimeOffset? Created { get; set; }
    public DateTimeOffset? Added { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public double? Duration { get; set; }
    public bool IsVideo { get; set; }
    public bool IsLive { get; set; }
    public bool IsFavorite { get; set; }
    public bool IsHidden { get; set; }
    public bool IsDeleted { get; set; }
    public bool IsEdited { get; set; }
    public string? Uti { get; set; }
    public List<PhotoResource> Resources { get; set; } = [];

    public PhotoResource? Resource(PhotoResourceKind kind) => Resources.FirstOrDefault(r => r.Kind == kind);

    /// <summary>Bytes for a full-fidelity export (original + live video + alternate RAW + edited if requested).</summary>
    public long ExportSize(bool includeLive, bool includeEdited, bool includeRAW)
    {
        var s = Resource(PhotoResourceKind.Original)?.Size ?? Size;
        if (includeLive) s += Resource(PhotoResourceKind.LiveVideo)?.Size ?? 0;
        if (includeEdited) s += Resource(PhotoResourceKind.Edited)?.Size ?? 0;
        if (includeRAW) s += Resource(PhotoResourceKind.Alternate)?.Size ?? 0;
        return s;
    }

    public PhotoAsset Copy()
    {
        var c = (PhotoAsset)MemberwiseClone();
        c.Resources = Resources.Select(r => r.Copy()).ToList();
        return c;
    }

    public bool Equals(PhotoAsset? o) => o is not null && Id == o.Id && IsFavorite == o.IsFavorite && IsHidden == o.IsHidden && ChangeTag == o.ChangeTag;
    public override bool Equals(object? obj) => Equals(obj as PhotoAsset);
    public override int GetHashCode() => Id.GetHashCode();
}

[Flags]
public enum PhotoCapabilities { None = 0, Favorite = 1, Hide = 2, Delete = 4, Restore = 8, ImportFiles = 16, Albums = 32, CreateAlbum = 64 }

public interface IPhotosBackend
{
    PhotoCapabilities Capabilities { get; }
    /// <summary>Stable key used for caches and sync state (e.g. "web-appleid" / "demo").</summary>
    string CacheKey { get; }
    Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default);
    Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default);
    /// <summary>Streams pages (newest pages first where possible) and returns the complete list.</summary>
    Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default);
    /// <summary>Encoded image bytes (JPEG/PNG) for a thumbnail; the app decodes and scales.</summary>
    Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default);
    Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default);
    Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default);
    Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default);
    /// <summary>Moves to Recently Deleted (recoverable for 30 days). Never removes permanently.</summary>
    Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default);
    Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default);
    Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default);
    /// <summary>
    /// Like <see cref="ImportFilesAsync"/>, but reports each file (with its new asset id when the backend knows it) as soon
    /// as it is in the library, so a failure later in the call (the album add, the next file, a cancel) never makes the
    /// caller send it again.
    /// </summary>
    async Task ImportFilesEachAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress,
        Action<string, string?> imported, CancellationToken ct = default)
    {
        await ImportFilesAsync(files, album, library, progress, ct).ConfigureAwait(false);
        foreach (var f in files) imported(f, null);
    }
    Task AddAsync(IReadOnlyList<PhotoAsset> assets, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default);
    Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default);
    /// <summary>Opaque "as of" marker for a library after the last listing (null = the backend can't tell).</summary>
    string? SyncToken(PhotoLibraryRef library);
    /// <summary>Whether anything in the library changed since <paramref name="token"/>, with the newer token.</summary>
    Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default);
}

public static class PhotoFormats
{
    public static readonly Dictionary<string, string> UtiExtensions = new()
    {
        ["public.jpeg"] = "jpg", ["public.png"] = "png", ["public.heic"] = "heic", ["public.heif"] = "heif", ["public.tiff"] = "tiff",
        ["public.mpeg-4"] = "mp4", ["com.apple.quicktime-movie"] = "mov", ["com.compuserve.gif"] = "gif", ["com.adobe.raw-image"] = "dng",
        ["com.canon.cr2-raw-image"] = "cr2", ["com.canon.cr3-raw-image"] = "cr3", ["com.nikon.raw-image"] = "nef", ["com.sony.arw-raw-image"] = "arw",
        ["public.avif"] = "avif", ["org.webmproject.webp"] = "webp", ["com.apple.m4v-video"] = "m4v", ["public.avi"] = "avi",
        ["com.fuji.raw-image"] = "raf", ["com.panasonic.rw2-raw-image"] = "rw2", ["com.olympus.raw-image"] = "orf", ["com.pentax.raw-image"] = "pef",
        ["com.nikon.nrw-raw-image"] = "nrw", ["com.canon.crw-raw-image"] = "crw", ["public.image"] = "heic",
    };

    public static readonly HashSet<string> VideoUTIs = ["public.mpeg-4", "com.apple.quicktime-movie", "com.apple.m4v-video", "public.avi", "public.mpeg-2-video"];

    static readonly HashSet<string> Importable = new(StringComparer.OrdinalIgnoreCase)
    { "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "webp", "avif", "mov", "mp4", "m4v" };

    public static bool IsImportable(string path) => Importable.Contains(Path.GetExtension(path).TrimStart('.'));

    /// <summary>Best-guess UTI for a file extension (inverse of <see cref="UtiExtensions"/>).</summary>
    public static string UtiFor(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext == "jpeg") ext = "jpg";
        if (ext == "tif") ext = "tiff";
        foreach (var (uti, e) in UtiExtensions) if (e == ext && uti != "public.image") return uti;
        return "";
    }

    public static bool IsVideoFile(string path) => VideoUTIs.Contains(UtiFor(path));
}

/// <summary>
/// Small on-disk cache for remote thumbnails: one folder per account and cache version, file names hashed (no
/// Apple IDs or photo IDs on disk). Bump <see cref="Version"/> to drop everything written by older code.
/// </summary>
public static class ThumbnailDiskCache
{
    /// <summary>v2: new layout (per account, hashed) and nothing kept from before the download fixes.</summary>
    public const string Version = "v2";

    static string Hash(string s) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(s)))[..24];

    public static string AccountDir(string backend) => Path.Combine(Paths.CacheDir("thumbs"), Hash(Version + backend));

    public static string PathFor(string backend, string id, int px)
    {
        var h = Hash(id);
        var dir = Path.Combine(AccountDir(backend), h[..2]);
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, $"{h}-{px}.img");
    }

    public static byte[]? Read(string backend, string id, int px)
    {
        try { var p = PathFor(backend, id, px); return File.Exists(p) ? File.ReadAllBytes(p) : null; } catch { return null; }
    }

    public static void Write(byte[] data, string backend, string id, int px)
    {
        try
        {
            var p = PathFor(backend, id, px);
            var tmp = p + ".tmp" + Guid.NewGuid().ToString("N")[..6];
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, p, overwrite: true);
        }
        catch { }
    }

    /// <summary>Removes thumbnail folders from older cache versions and from accounts that are gone (Cirrus' own cache).</summary>
    public static void PruneOldVersions(IEnumerable<string> keepingBackends)
    {
        var keep = keepingBackends.Select(b => Hash(Version + b)).ToHashSet();
        try
        {
            foreach (var e in Directory.EnumerateFileSystemEntries(Paths.CacheDir("thumbs")))
            {
                if (keep.Contains(Path.GetFileName(e))) continue;
                try { if (Directory.Exists(e)) Directory.Delete(e, true); else File.Delete(e); } catch { }
            }
        }
        catch { }
    }

    /// <summary>Forgets every thumbnail of one account (sign-out).</summary>
    public static void Wipe(string backend)
    {
        try { var d = AccountDir(backend); if (Directory.Exists(d)) Directory.Delete(d, true); } catch { }
    }
}

/// <summary>Platform hook: re-encode an image to a JPEG of at most <c>maxPixel</c> (the Windows app uses WPF/WIC).</summary>
public static class ImageReencoder
{
    public static Func<byte[], int, byte[]?>? ToJpeg { get; set; }
}

/// <summary>Pairs a still with its Live Photo .MOV (same name stem) for imports.</summary>
public static class LivePairing
{
    public sealed record Group(string Primary, string? PairedVideo);

    public static List<Group> GroupFiles(IEnumerable<string> files)
    {
        var output = new List<Group>();
        foreach (var g in files.GroupBy(f => Path.Combine(Path.GetDirectoryName(f) ?? "", Path.GetFileNameWithoutExtension(f)).ToLowerInvariant()))
        {
            var urls = g.ToList();
            var stills = urls.Where(u => Path.GetExtension(u).ToLowerInvariant() is not (".mov" or ".mp4")).ToList();
            var movies = urls.Where(u => Path.GetExtension(u).Equals(".mov", StringComparison.OrdinalIgnoreCase)).ToList();
            if (stills.Count == 1 && movies.Count == 1) output.Add(new Group(stills[0], movies[0]));
            else output.AddRange(urls.Select(u => new Group(u, null)));
        }
        return output.OrderBy(g => Path.GetFileName(g.Primary), StringComparer.Ordinal).ToList();
    }
}

/// <summary>Reads pixel dimensions from PNG and JPEG headers without decoding.</summary>
public static class ImageInfo
{
    public static (int Width, int Height)? Size(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            var head = new byte[26];
            if (fs.Read(head, 0, head.Length) < 24) return null;
            if (head[0] == 0x89 && head[1] == 'P' && head[2] == 'N' && head[3] == 'G')
                return (BE32(head, 16), BE32(head, 20));
            if (head[0] == 0xFF && head[1] == 0xD8)
            {
                fs.Position = 2;
                while (fs.Position < fs.Length)
                {
                    if (fs.ReadByte() != 0xFF) return null;
                    int marker = fs.ReadByte();
                    while (marker == 0xFF) marker = fs.ReadByte();
                    var lenBytes = new byte[2];
                    if (fs.Read(lenBytes, 0, 2) < 2) return null;
                    int len = (lenBytes[0] << 8) | lenBytes[1];
                    if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                    {
                        var sof = new byte[5];
                        if (fs.Read(sof, 0, 5) < 5) return null;
                        return ((sof[3] << 8) | sof[4], (sof[1] << 8) | sof[2]);
                    }
                    fs.Position += len - 2;
                }
            }
        }
        catch { }
        return null;
    }

    static int BE32(byte[] b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}
