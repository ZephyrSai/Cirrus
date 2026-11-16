using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// An Immich photo library as an <see cref="IPhotosBackend"/> (port of ImmichPhotos.swift): one library ("immich"), smart
/// albums for the timeline, favorites, videos, the archive (Cirrus's Hidden slot) and the trash (Recently Deleted), plus
/// the user's own albums and albums others shared with them.
/// <para>
/// Ids: assets use Immich's asset id; albums are "album:&lt;Immich album id&gt;" and the smart ones "smart:All Photos",
/// "smart:Favorites", "smart:Videos", "smart:Hidden" (Immich's archive, named "Archive") and "smart:Recently Deleted"
/// (Immich's trash, named "Trash"). A Live Photo's motion part (a hidden video asset in Immich) is the still's
/// <see cref="PhotoResourceKind.LiveVideo"/> resource.
/// </para>
/// <para>
/// Rules: listing goes newest first in pages (<c>POST /search/metadata</c>); the smart albums show only the user's own
/// assets (a partner's photos that Immich mixes into the timeline are theirs to manage); deleting always uses Immich's
/// trash (never <c>force</c>) and is refused when the server has its trash turned off; uploads are checked against the
/// library by SHA-1 first, so a photo already there is never sent twice. Safe from any thread.
/// </para>
/// </summary>
public sealed class ImmichPhotos : IPhotosBackend
{
    public const string LibraryID = "immich";

    /// <summary>The one library (a fresh copy: <see cref="PhotoLibraryRef"/> is mutable).</summary>
    public static PhotoLibraryRef Library => new(LibraryID, "Immich", false);

    /// <summary>The smart albums: id, name (Immich's own words for the archive and the trash), symbol.</summary>
    internal enum Smart { AllPhotos, Favorites, Videos, Archive, Trash }

    internal static readonly (Smart Kind, string Id, string Name, string Symbol)[] SmartAlbums =
    [
        (Smart.AllPhotos, "smart:All Photos", "All Photos", "photos"),
        (Smart.Favorites, "smart:Favorites", "Favorites", "heart"),
        (Smart.Videos, "smart:Videos", "Videos", "video"),
        (Smart.Archive, "smart:Hidden", "Archive", "archive"),
        (Smart.Trash, "smart:Recently Deleted", "Trash", "trash"),
    ];

    /// <summary>What an album id lists: a smart album or an Immich album.</summary>
    internal readonly record struct Scope(Smart? SmartKind, string? AlbumID);

    public CloudAccountRecord Record { get; }
    public string CacheKey { get; }
    internal ImmichClient Client { get; }
    readonly object _lock = new();
    HashSet<string>? _permissions;
    string? _userID;
    ImmichVersion? _version;
    (bool Enabled, DateTimeOffset Checked)? _trash;
    /// <summary>Asset id → owner, from listings: edits to someone else's photo are refused before asking the server.</summary>
    readonly Dictionary<string, string> _owners = [];
    int _firstPageSize = 200, _pageSize = 1000;
    /// <summary>A small first page so the grid fills fast, then big ones (Immich allows up to 1000). Tests lower them.</summary>
    internal int FirstPageSize { get { lock (_lock) return _firstPageSize; } set { lock (_lock) _firstPageSize = value; } }
    internal int PageSize { get { lock (_lock) return _pageSize; } set { lock (_lock) _pageSize = value; } }

    internal ImmichPhotos(CloudAccountRecord record, Uri server, string apiKey, HttpMessageHandler? transport)
    {
        Record = record;
        CacheKey = "immich-" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(record.Id)))[..16];
        Client = new ImmichClient(server, apiKey, ImmichCloud.ServiceName(record.Title), transport);
        if (record.Option("permissions") is { Length: > 0 } p) _permissions = p.Split(',').ToHashSet(StringComparer.Ordinal);
    }

    // MARK: Capabilities

    bool Has(string permission)
    {
        lock (_lock) return _permissions is not { } p || p.Contains("all") || p.Contains(permission);
    }

    /// <summary>What the API key may do (refreshed from <c>GET /api-keys/me</c> with each <see cref="LibrariesAsync"/>).</summary>
    public PhotoCapabilities Capabilities
    {
        get
        {
            var c = PhotoCapabilities.None;
            if (Has("asset.update")) c |= PhotoCapabilities.Favorite | PhotoCapabilities.Hide;
            if (Has("asset.delete")) c |= PhotoCapabilities.Delete | PhotoCapabilities.Restore;
            if (Has("asset.upload")) c |= PhotoCapabilities.ImportFiles;
            if (Has("album.read")) c |= PhotoCapabilities.Albums;
            if (Has("album.create")) c |= PhotoCapabilities.CreateAlbum;
            return c;
        }
    }

    // MARK: Session facts

    async Task<ImmichVersion> VersionAsync(CancellationToken ct)
    {
        lock (_lock) if (_version is { } cached) return cached;
        var j = await Client.CallAsync("GET", "/server/version", ct: ct).ConfigureAwait(false);
        var v = ImmichVersion.From(j) ?? throw CloudException.Server("The Immich server didn’t say which version it runs.");
        lock (_lock) _version = v;
        return v;
    }

    async Task<string> UserIDAsync(CancellationToken ct)
    {
        lock (_lock) if (_userID is { } cached) return cached;
        var me = await Client.CallAsync("GET", "/users/me", ct: ct).ConfigureAwait(false);
        var id = me["id"].Str ?? throw CloudException.Server("Immich didn’t say who the API key belongs to.");
        lock (_lock) _userID = id;
        return id;
    }

    async Task RefreshPermissionsAsync(CancellationToken ct)
    {
        try
        {
            var k = await Client.CallAsync("GET", "/api-keys/me", ct: ct).ConfigureAwait(false);
            if (k["permissions"].Node is not JsonArray) return;
            var set = k["permissions"].Array.Select(p => p.Str).OfType<string>().ToHashSet(StringComparer.Ordinal);
            lock (_lock) _permissions = set;
        }
        catch (CloudException) { }
    }

    /// <summary>Whether the server keeps deleted photos in its trash (null: couldn't tell). Checked at most every 10 minutes.</summary>
    async Task<bool?> TrashEnabledAsync(CancellationToken ct)
    {
        lock (_lock) if (_trash is { } t && DateTimeOffset.UtcNow - t.Checked < TimeSpan.FromMinutes(10)) return t.Enabled;
        J f;
        try { f = await Client.CallAsync("GET", "/server/features", ct: ct).ConfigureAwait(false); }
        catch (CloudException) { return null; }
        if (f["trash"].Node is not JsonValue v || v.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)) return null;
        var on = f["trash"].Bool == true;
        lock (_lock) _trash = (on, DateTimeOffset.UtcNow);
        return on;
    }

    // MARK: Libraries & albums

    public async Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default)
    {
        var perms = RefreshPermissionsAsync(ct);
        var version = Task.Run(async () => { try { await VersionAsync(ct).ConfigureAwait(false); } catch (CloudException) { } }, CancellationToken.None);
        lock (_lock) _userID = null;   // re-ask: also checks the key still works (401 → sign in again)
        try { await UserIDAsync(ct).ConfigureAwait(false); }
        finally
        {
            try { await Task.WhenAll(perms, version).ConfigureAwait(false); } catch (OperationCanceledException) { }
        }
        return [Library];
    }

    public async Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default)
    {
        var me = await UserIDAsync(ct).ConfigureAwait(false);
        var timeline = StatsAsync(new() { ["visibility"] = "timeline", ["isTrashed"] = "false" }, ct);
        var favorites = StatsAsync(new() { ["visibility"] = "timeline", ["isTrashed"] = "false", ["isFavorite"] = "true" }, ct);
        var archived = StatsAsync(new() { ["visibility"] = "archive", ["isTrashed"] = "false" }, ct);
        var trashed = StatsAsync(new() { ["isTrashed"] = "true" }, ct);
        IReadOnlyList<J> list = [];
        try { list = (await Client.CallAsync("GET", "/albums", ct: ct).ConfigureAwait(false)).Array; }
        catch (CloudException e) when (e.Kind == CloudErrorKind.Denied) { }   // a key without album.read: the smart albums still work
        var (t, f, a, tr) = (await timeline.ConfigureAwait(false), await favorites.ConfigureAwait(false), await archived.ConfigureAwait(false), await trashed.ConfigureAwait(false));
        var output = SmartAlbums.Select(s => new PhotoAlbum(s.Id, s.Name, PhotoAlbumKind.Smart, count: s.Kind switch
        {
            Smart.AllPhotos => t?.Total,
            Smart.Favorites => f?.Total,
            Smart.Videos => t?.Videos,
            Smart.Archive => a?.Total,
            _ => tr?.Total,
        }, symbol: s.Symbol)).ToList();
        output.AddRange(list.Select(j => Album(j, me)).OfType<PhotoAlbum>()
            .OrderBy(x => x.Kind == PhotoAlbumKind.Album ? 0 : 1).ThenBy(x => x.Name, NaturalComparer.Instance));
        return output;
    }

    async Task<(int Total, int Videos)?> StatsAsync(Dictionary<string, string> query, CancellationToken ct)
    {
        try
        {
            var j = await Client.CallAsync("GET", "/assets/statistics", query, ct: ct).ConfigureAwait(false);
            return j["total"].Int is int total ? (total, j["videos"].Int ?? 0) : null;
        }
        catch (CloudException) { return null; }
    }

    Task<(int Total, int Videos)?> CountQuery(Smart s, CancellationToken ct) => s switch
    {
        Smart.AllPhotos or Smart.Videos => StatsAsync(new() { ["visibility"] = "timeline", ["isTrashed"] = "false" }, ct),
        Smart.Favorites => StatsAsync(new() { ["visibility"] = "timeline", ["isTrashed"] = "false", ["isFavorite"] = "true" }, ct),
        Smart.Archive => StatsAsync(new() { ["visibility"] = "archive", ["isTrashed"] = "false" }, ct),
        _ => StatsAsync(new() { ["isTrashed"] = "true" }, ct),
    };

    async Task<int?> CountAsync(Smart s, CancellationToken ct)
    {
        var r = await CountQuery(s, ct).ConfigureAwait(false);
        return s == Smart.Videos ? r?.Videos : r?.Total;
    }

    /// <summary>An <c>AlbumResponseDto</c> → album. v3 names the owner in <c>albumUsers</c> (role "owner"); older servers had <c>ownerId</c>.</summary>
    internal static PhotoAlbum? Album(J j, string me)
    {
        if (j["id"].Str is not { Length: > 0 } id) return null;
        var name = (j["albumName"].Str ?? "").Normalize(NormalizationForm.FormC).Trim();
        if (name.Length == 0) name = "Untitled";
        var owner = j["albumUsers"].Array.FirstOrDefault(u => u["role"].Str == "owner")["user"]["id"].Str
            ?? j["ownerId"].Str ?? j["owner"]["id"].Str;
        var mine = owner is null || owner == me;
        var shared = j["shared"].Bool ?? false;
        return new PhotoAlbum("album:" + id, name, mine ? PhotoAlbumKind.Album : PhotoAlbumKind.Shared, count: j["assetCount"].Int,
            symbol: mine ? (shared ? "album.shared" : "album") : "shared");
    }

    static Scope ScopeOf(PhotoAlbum album)
    {
        foreach (var s in SmartAlbums) if (s.Id == album.Id) return new Scope(s.Kind, null);
        if (album.Id.StartsWith("album:", StringComparison.Ordinal) && album.Id.Length > 6) return new Scope(null, album.Id[6..]);
        throw CloudException.NotFound();
    }

    // MARK: Listing

    /// <summary>Immich 3.2+: the structured filter.</summary>
    internal static JsonObject Filter(Scope s)
    {
        JsonObject NotTrashed() => new() { ["eq"] = null };
        JsonObject Shown() => new() { ["in"] = new JsonArray("timeline", "archive") };
        if (s.AlbumID is { } id)
            return new() { ["albumIds"] = new JsonObject { ["any"] = new JsonArray(id) }, ["visibility"] = Shown(), ["trashedAt"] = NotTrashed() };
        return s.SmartKind switch
        {
            Smart.AllPhotos => new() { ["visibility"] = new JsonObject { ["eq"] = "timeline" }, ["trashedAt"] = NotTrashed() },
            Smart.Favorites => new() { ["visibility"] = new JsonObject { ["eq"] = "timeline" }, ["trashedAt"] = NotTrashed(), ["isFavorite"] = new JsonObject { ["eq"] = true } },
            Smart.Videos => new() { ["visibility"] = new JsonObject { ["eq"] = "timeline" }, ["trashedAt"] = NotTrashed(), ["type"] = new JsonObject { ["eq"] = "VIDEO" } },
            Smart.Archive => new() { ["visibility"] = new JsonObject { ["eq"] = "archive" }, ["trashedAt"] = NotTrashed() },
            _ => new() { ["visibility"] = Shown(), ["trashedAt"] = new JsonObject { ["ne"] = null } },
        };
    }

    /// <summary>
    /// Immich 3.0–3.1: the flat fields (deprecated from 3.2). They can't say "timeline or archive", so the album and trash
    /// listings ask for any visibility and <see cref="Belongs"/> drops Live Photo motion parts.
    /// </summary>
    internal static Dictionary<string, JsonNode?> LegacyFields(Scope s)
    {
        if (s.AlbumID is { } id) return new() { ["albumIds"] = new JsonArray(id) };
        return s.SmartKind switch
        {
            Smart.AllPhotos => new() { ["visibility"] = "timeline" },
            Smart.Favorites => new() { ["visibility"] = "timeline", ["isFavorite"] = true },
            Smart.Videos => new() { ["visibility"] = "timeline", ["type"] = "VIDEO" },
            Smart.Archive => new() { ["visibility"] = "archive" },
            _ => new() { ["withDeleted"] = true, ["trashedAfter"] = "1970-01-01T00:00:00.000Z" },
        };
    }

    /// <summary>Double-checks each answer (and keeps the smart albums to the user's own photos).</summary>
    internal static bool Belongs(J a, Scope s, string me)
    {
        var vis = a["visibility"].Str ?? (a["isArchived"].Bool == true ? "archive" : "timeline");
        var trashed = a["isTrashed"].Bool ?? false;
        var shown = vis is "timeline" or "archive";
        if (s.AlbumID is not null) return !trashed && shown;
        if (a["ownerId"].Str is { } owner && owner != me) return false;
        return s.SmartKind switch
        {
            Smart.AllPhotos => vis == "timeline" && !trashed,
            Smart.Favorites => vis == "timeline" && !trashed && a["isFavorite"].Bool == true,
            Smart.Videos => vis == "timeline" && !trashed && a["type"].Str == "VIDEO",
            Smart.Archive => vis == "archive" && !trashed,
            _ => trashed && shown,
        };
    }

    public async Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page,
        CancellationToken ct = default)
    {
        if (album.Kind == PhotoAlbumKind.Folder) return [];
        var scope = ScopeOf(album);
        var me = await UserIDAsync(ct).ConfigureAwait(false);
        var v = await VersionAsync(ct).ConfigureAwait(false);
        var total = album.Count;
        if (total is null && scope.SmartKind is { } sk) total = await CountAsync(sk, ct).ConfigureAwait(false);
        var structured = v.HasStructuredSearch;
        var output = new List<PhotoAsset>();
        var seen = new HashSet<string>();
        var listedOwners = new Dictionary<string, string>();
        string? cursor = null;
        var pageNumber = 1;
        var size = structured ? FirstPageSize : PageSize;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var body = new JsonObject { ["size"] = size, ["withExif"] = true };
            if (structured)
            {
                body["filter"] = Filter(scope);
                body["orderBy"] = new JsonObject { ["field"] = "fileCreatedAt", ["direction"] = "desc" };
                if (cursor is not null) body["cursor"] = cursor;
            }
            else
            {
                foreach (var (k, val) in LegacyFields(scope)) body[k] = val;
                body["order"] = "desc";
                body["page"] = pageNumber;
            }
            var r = await Client.CallAsync("POST", "/search/metadata", json: body, ct: ct).ConfigureAwait(false);
            var res = r["assets"];
            var items = res["items"].Array;
            var batch = new List<PhotoAsset>();
            foreach (var j in items)
            {
                if (!Belongs(j, scope, me) || Asset(j) is not { } a || !seen.Add(a.Id)) continue;
                if (j["ownerId"].Str is { } o) listedOwners[a.Id] = o;
                batch.Add(a);
            }
            if (batch.Count > 0)
            {
                output.AddRange(batch);
                page?.Invoke(batch, total);
            }
            var next = structured ? res["nextCursor"].Str : res["nextPage"].Str;
            if (string.IsNullOrEmpty(next) || items.Count == 0) break;
            if (structured) { cursor = next; size = PageSize; }
            else pageNumber = int.TryParse(next, out var n) ? n : pageNumber + 1;
        }
        lock (_lock) foreach (var (id, o) in listedOwners) _owners[id] = o;
        return output;
    }

    static readonly Dictionary<string, string> MimeUTIs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["image/jpeg"] = "public.jpeg", ["image/png"] = "public.png", ["image/heic"] = "public.heic", ["image/heif"] = "public.heif",
        ["image/tiff"] = "public.tiff", ["image/gif"] = "com.compuserve.gif", ["image/webp"] = "org.webmproject.webp", ["image/avif"] = "public.avif",
        ["image/dng"] = "com.adobe.raw-image", ["image/x-adobe-dng"] = "com.adobe.raw-image", ["image/x-canon-cr2"] = "com.canon.cr2-raw-image",
        ["image/x-canon-cr3"] = "com.canon.cr3-raw-image", ["image/x-nikon-nef"] = "com.nikon.raw-image", ["image/x-sony-arw"] = "com.sony.arw-raw-image",
        ["image/x-fuji-raf"] = "com.fuji.raw-image", ["image/x-panasonic-rw2"] = "com.panasonic.rw2-raw-image", ["image/x-olympus-orf"] = "com.olympus.raw-image",
        ["video/mp4"] = "public.mpeg-4", ["video/quicktime"] = "com.apple.quicktime-movie", ["video/x-m4v"] = "com.apple.m4v-video",
        ["video/x-msvideo"] = "public.avi", ["video/avi"] = "public.avi", ["video/mpeg"] = "public.mpeg-2-video",
    };

    /// <summary>Only letters and digits stay as they are (like Swift's <c>.alphanumerics</c> set).</summary>
    static string EncodeStrict(string s)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
            if (b is >= (byte)'a' and <= (byte)'z' or >= (byte)'A' and <= (byte)'Z' or >= (byte)'0' and <= (byte)'9') sb.Append((char)b);
            else sb.Append('%').Append(b.ToString("X2"));
        return sb.ToString();
    }

    /// <summary>An <c>AssetResponseDto</c> → asset.</summary>
    internal static PhotoAsset? Asset(J j)
    {
        if (j["id"].Str is not { Length: > 0 } id) return null;
        var exif = j["exifInfo"];
        var name = (j["originalFileName"].Str ?? "").Normalize(NormalizationForm.FormC);
        string? uti = j["originalMimeType"].Str is { } mime && MimeUTIs.TryGetValue(mime, out var u) ? u : null;
        if (uti is null && name.Length > 0 && PhotoFormats.UtiFor(name) is { Length: > 0 } fromExt) uti = fromExt;
        if (name.Length == 0) name = id + "." + (uti is not null && PhotoFormats.UtiExtensions.TryGetValue(uti, out var ext) ? ext : "jpg");
        name = Paths.SafeName(name);
        var stem = Path.GetFileNameWithoutExtension(name);
        var isVideo = j["type"].Str == "VIDEO";
        var size = exif["fileSizeInByte"].Int64 ?? 0;
        var edited = j["isEdited"].Bool == true;
        var live = j["livePhotoVideoId"].Str is { Length: > 0 } l ? l : null;
        var res = new List<PhotoResource>
        {
            new() { Kind = PhotoResourceKind.Original, Filename = name, Size = size, Key = "original", RecordName = id, Uti = uti },
        };
        if (live is not null)
            res.Add(new PhotoResource { Kind = PhotoResourceKind.LiveVideo, Filename = stem + ".MOV", Size = 0, Key = "original", RecordName = live, Uti = "com.apple.quicktime-movie" });
        if (edited && !isVideo)
            res.Add(new PhotoResource { Kind = PhotoResourceKind.Edited, Filename = stem + "-edited.jpg", Size = 0, Key = "edited", RecordName = id, Uti = "public.jpeg" });
        // Server-made renditions; `c` is Immich's own cache-buster (the thumbhash), so a new edit gets a new cache entry.
        var buster = EncodeStrict(j["thumbhash"].Str ?? j["updatedAt"].Str ?? "");
        foreach (var (kind, sizeName) in new[] { (PhotoResourceKind.Thumbnail, "thumbnail"), (PhotoResourceKind.Medium, "preview") })
        {
            var q = "size=" + sizeName;
            if (edited) q += "&edited=true";
            if (buster.Length > 0) q += "&c=" + buster;
            res.Add(new PhotoResource
            {
                Kind = kind, Filename = stem + (kind == PhotoResourceKind.Thumbnail ? "-thumbnail" : "-preview"), Size = 0, Key = sizeName,
                RecordName = id, Url = $"/assets/{id}/thumbnail?" + q,
            });
        }
        var vis = j["visibility"].Str ?? (j["isArchived"].Bool == true ? "archive" : "timeline");
        return new PhotoAsset
        {
            Id = id, MasterID = id, ChangeTag = j["updatedAt"].Str, Library = LibraryID, Filename = name, Size = size,
            Created = ImmichDates.Parse(j["fileCreatedAt"]) ?? ImmichDates.Parse(j["localDateTime"]), Added = ImmichDates.Parse(j["createdAt"]),
            Width = j["width"].Int ?? exif["exifImageWidth"].Int ?? 0, Height = j["height"].Int ?? exif["exifImageHeight"].Int ?? 0,
            Duration = Duration(j["duration"]), IsVideo = isVideo, IsLive = live is not null, IsFavorite = j["isFavorite"].Bool == true,
            IsHidden = vis == "archive", IsDeleted = j["isTrashed"].Bool == true, IsEdited = edited, Uti = uti, Resources = res,
        };
    }

    /// <summary>Seconds: v3 sends milliseconds (or null); older servers sent "H:MM:SS.ffffff".</summary>
    internal static double? Duration(J j)
    {
        if (j.Node is not JsonValue v) return null;
        switch (v.GetValueKind())
        {
            case JsonValueKind.Number:
                return j.Double is double ms && ms > 0 ? ms / 1000 : null;
            case JsonValueKind.String:
                var s = j.Str ?? "";
                if (double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n)) return n > 0 ? n / 1000 : null;
                var parts = s.Split(':').Select(p => double.TryParse(p, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var x) ? x : (double?)null)
                    .OfType<double>().ToList();
                if (parts.Count != 3) return null;
                var secs = parts[0] * 3600 + parts[1] * 60 + parts[2];
                return secs > 0 ? secs : null;
            default:
                return null;
        }
    }

    // MARK: Content

    /// <summary>
    /// Immich's own renditions: its thumbnail (about 250 px) for small tiles, its preview (about 1440 px) above 300 px.
    /// Kept in the thumbnail disk cache, keyed by the rendition's address (which changes with each edit).
    /// </summary>
    public async Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default)
    {
        var kind = maxPixel > 300 ? PhotoResourceKind.Medium : PhotoResourceKind.Thumbnail;
        var px = kind == PhotoResourceKind.Medium ? 1440 : 250;
        var path = asset.Resource(kind)?.Url ?? $"/assets/{asset.Id}/thumbnail?size=" + (kind == PhotoResourceKind.Medium ? "preview" : "thumbnail");
        if (ThumbnailDiskCache.Read(CacheKey, path, px) is { Length: > 0 } cached) return cached;
        byte[] data;
        try { data = await Client.FetchAsync(path, ct).ConfigureAwait(false); }
        catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { return null; }
        if (data.Length == 0) return null;
        ThumbnailDiskCache.Write(data, CacheKey, path, px);
        return data;
    }

    public async Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        var r = asset.Resource(resource) ?? throw CloudException.NotFound();
        var path = r.Kind switch
        {
            PhotoResourceKind.Thumbnail or PhotoResourceKind.Medium => r.Url ?? $"/assets/{r.RecordName}/thumbnail?size={r.Key}",
            PhotoResourceKind.Edited => $"/assets/{r.RecordName}/original?edited=true",
            _ => $"/assets/{r.RecordName}/original",
        };
        await Client.DownloadAsync(path, destination, r.Size, progress, ct).ConfigureAwait(false);
        if (asset.Created is { } d) { try { File.SetLastWriteTimeUtc(destination, d.UtcDateTime); File.SetCreationTimeUtc(destination, d.UtcDateTime); } catch { } }
    }

    // MARK: Edits

    /// <summary>The ids to change; refuses (before asking the server) when some belong to someone who shared them.</summary>
    async Task<List<string>> OwnIDsAsync(IReadOnlyList<PhotoAsset> assets, string verb, CancellationToken ct)
    {
        var me = await UserIDAsync(ct).ConfigureAwait(false);
        int others;
        lock (_lock) others = assets.Count(a => _owners.TryGetValue(a.Id, out var o) && o != me);
        if (others > 0)
            throw CloudException.Denied((others == 1 ? "One of these photos belongs" : $"{others} of these photos belong")
                + $" to someone who shared {(others == 1 ? "it" : "them")} with you, so only they can {verb} {(others == 1 ? "it" : "them")} in Immich.");
        return assets.Select(a => a.Id).Distinct().ToList();
    }

    static JsonArray IDs(IEnumerable<string> list) => Jx.Strings(list);

    public async Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default)
    {
        var ids = await OwnIDsAsync(assets, value ? "favorite" : "unfavorite", ct).ConfigureAwait(false);
        foreach (var chunk in ids.Chunk(500))
            await Client.CallAsync("PUT", "/assets", json: new JsonObject { ["ids"] = IDs(chunk), ["isFavorite"] = value }, ct: ct).ConfigureAwait(false);
        return assets.Select(a => { var c = a.Copy(); c.IsFavorite = value; return c; }).ToList();
    }

    /// <summary>Hidden = Immich's archive (out of the timeline, still in albums and search).</summary>
    public async Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default)
    {
        var ids = await OwnIDsAsync(assets, value ? "archive" : "unarchive", ct).ConfigureAwait(false);
        foreach (var chunk in ids.Chunk(500))
            await Client.CallAsync("PUT", "/assets", json: new JsonObject { ["ids"] = IDs(chunk), ["visibility"] = value ? "archive" : "timeline" }, ct: ct).ConfigureAwait(false);
        return assets.Select(a => { var c = a.Copy(); c.IsHidden = value; return c; }).ToList();
    }

    internal const string TrashOffMessage = "This Immich server has its trash turned off, so deleting would remove photos for good. "
        + "Cirrus only moves photos to the trash: turn the trash on in Immich (Administration › Settings › Trash Settings), or delete them in Immich itself.";

    internal static CloudException TrashOff() => CloudException.Denied(TrashOffMessage);

    /// <summary>To Immich's trash (restorable until the server empties it). Never <c>force</c>.</summary>
    public async Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default)
    {
        if (assets.Count == 0) return;
        var ids = await OwnIDsAsync(assets, "delete", ct).ConfigureAwait(false);
        if (await TrashEnabledAsync(ct).ConfigureAwait(false) == false) throw TrashOff();
        foreach (var chunk in ids.Chunk(500))
            await Client.CallAsync("DELETE", "/assets", json: new JsonObject { ["ids"] = IDs(chunk) }, ct: ct).ConfigureAwait(false);
    }

    public async Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default)
    {
        if (assets.Count == 0) return;
        var ids = await OwnIDsAsync(assets, "restore", ct).ConfigureAwait(false);
        await RestoreIDsAsync(ids, ct).ConfigureAwait(false);
    }

    async Task RestoreIDsAsync(IReadOnlyList<string> ids, CancellationToken ct)
    {
        foreach (var chunk in ids.Chunk(500))
            await Client.CallAsync("POST", "/trash/restore/assets", json: new JsonObject { ["ids"] = IDs(chunk) }, ct: ct).ConfigureAwait(false);
    }

    public async Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default)
    {
        var title = (name ?? "").Trim();
        if (title.Length == 0) throw CloudException.NotConfigured("Enter a name for the album.");
        var j = await Client.CallAsync("POST", "/albums", json: new JsonObject { ["albumName"] = title }, retry: ImmichRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
        var id = j["id"].Str ?? throw CloudException.Server("Immich didn’t say which album it created.");
        return new PhotoAlbum("album:" + id, (j["albumName"].Str ?? title).Normalize(NormalizationForm.FormC), PhotoAlbumKind.Album, count: 0, symbol: "album");
    }

    public async Task AddAsync(IReadOnlyList<PhotoAsset> assets, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default)
    {
        if (!album.Id.StartsWith("album:", StringComparison.Ordinal) || album.Kind is not (PhotoAlbumKind.Album or PhotoAlbumKind.Shared))
            throw CloudException.Unsupported($"Photos can only be added to albums, not to “{album.Name}”.");
        await AddIDsAsync(assets.Select(a => a.Id).ToList(), album.Id[6..], ct).ConfigureAwait(false);
    }

    async Task AddIDsAsync(IReadOnlyList<string> ids, string albumID, CancellationToken ct)
    {
        var failed = 0;
        foreach (var chunk in ids.Distinct().Chunk(500))
        {
            var r = await Client.CallAsync("PUT", $"/albums/{albumID}/assets", json: new JsonObject { ["ids"] = IDs(chunk) }, ct: ct).ConfigureAwait(false);
            // "duplicate" = already in the album: fine.
            failed += r.Array.Count(x => x["success"].Bool != true && x["error"].Str != "duplicate");
        }
        if (failed > 0)
            throw CloudException.Denied($"Immich couldn’t add {(failed == 1 ? "one photo" : $"{failed} photos")} to the album: "
                + $"{(failed == 1 ? "it belongs" : "they belong")} to someone else or no longer exist.");
    }

    // MARK: Import

    public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) =>
        ImportFilesEachAsync(files, album, library, progress, (_, _) => { }, ct);

    public async Task ImportFilesEachAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress,
        Action<string, string?> imported, CancellationToken ct = default)
    {
        var ids = await ImportReturningIDsAsync(files, progress, imported, ct).ConfigureAwait(false);
        if (album is { Kind: PhotoAlbumKind.Album or PhotoAlbumKind.Shared } && album.Id.StartsWith("album:", StringComparison.Ordinal) && ids.Count > 0)
            await AddIDsAsync(ids, album.Id[6..], ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Uploads each photo (a Live Photo's still and .MOV together, linked as one) and returns their ids. A photo already in
    /// the library isn't sent again: its existing id comes back (restored first if it was in the trash). Each file is
    /// reported to <paramref name="imported"/> as soon as it is in the library.
    /// </summary>
    public async Task<List<string>> ImportReturningIDsAsync(IReadOnlyList<string> files, Action<long, long>? progress,
        Action<string, string?>? imported = null, CancellationToken ct = default)
    {
        if (files.Count == 0) return [];
        var groups = LivePairing.GroupFiles(files);
        var total = files.Sum(FileSize);
        long done = 0;
        var ids = new List<string>();
        progress?.Invoke(0, total);
        foreach (var g in groups)
        {
            ct.ThrowIfCancellationRequested();
            long stillSize = FileSize(g.Primary), videoSize = g.PairedVideo is { } pv ? FileSize(pv) : 0;
            var stillSum = await ImmichUpload.Sha1Async(g.Primary, ct).ConfigureAwait(false);
            if (await ExistingAsync(stillSum, ct).ConfigureAwait(false) is { } existing)
            {
                ids.Add(existing);
                done += stillSize + videoSize;
                progress?.Invoke(done, total);
                Report(g, existing);
                continue;
            }
            string? videoID = null;
            if (g.PairedVideo is { } v)
            {
                var sum = await ImmichUpload.Sha1Async(v, ct).ConfigureAwait(false);
                videoID = await ExistingAsync(sum, ct).ConfigureAwait(false)
                    ?? await UploadAsync(v, sum, null, done, total, progress, ct).ConfigureAwait(false);
                done += videoSize;
                progress?.Invoke(done, total);
            }
            // Linking needs asset.update on the video; without it Immich still pairs them from their metadata.
            var link = Has("asset.update") ? videoID : null;
            var id = await UploadAsync(g.Primary, stillSum, link, done, total, progress, ct).ConfigureAwait(false);
            ids.Add(id);
            done += stillSize;
            progress?.Invoke(done, total);
            Report(g, id);
        }
        return ids;

        void Report(LivePairing.Group g, string id)
        {
            imported?.Invoke(g.Primary, id);
            if (g.PairedVideo is { } pv) imported?.Invoke(pv, id);
        }
    }

    static long FileSize(string f)
    {
        try { return new FileInfo(f).Length; } catch { return 0; }
    }

    /// <summary>The id of the user's asset with this checksum, if Immich has it (brought back from the trash if needed).</summary>
    async Task<string?> ExistingAsync(string checksum, CancellationToken ct)
    {
        var r = await Client.CallAsync("POST", "/assets/bulk-upload-check", json: new JsonObject
        {
            ["assets"] = new JsonArray(new JsonObject { ["id"] = "0", ["checksum"] = checksum }),
        }, ct: ct).ConfigureAwait(false);
        var results = r["results"].Array;
        var res = results.FirstOrDefault(x => x["id"].Str == "0");
        if (res.IsNull) res = r["results"][0];
        if (res["action"].Str != "reject") return null;
        if (res["reason"].Str == "unsupported-format")
            throw CloudException.Unsupported("Immich doesn’t accept one of these files: its format isn’t supported.");
        if (res["assetId"].Str is not { } id) return null;
        if (res["isTrashed"].Bool == true)
        {
            try { await RestoreIDsAsync([id], ct).ConfigureAwait(false); }
            catch (CloudException e)
            {
                throw CloudException.Denied("One of these photos is already in Immich’s trash, and Cirrus couldn’t restore it "
                    + $"({e.Message}). Restore it in Immich, then try again.");
            }
        }
        return id;
    }

    async Task<string> UploadAsync(string file, string checksum, string? livePhotoVideoID, long baseDone, long total, Action<long, long>? progress, CancellationToken ct)
    {
        var modified = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero);
        var created = new DateTimeOffset(File.GetCreationTimeUtc(file), TimeSpan.Zero);
        if (created > modified || created.Year < 1971) created = modified;
        var local = Path.GetFileName(file);
        var name = (WinNames.MapsLocally ? WinNames.FromLocal(local) : local).Normalize(NormalizationForm.FormC);
        var fields = new List<(string, string)>
        {
            ("fileCreatedAt", ImmichDates.String(created)), ("fileModifiedAt", ImmichDates.String(modified)), ("filename", name),
        };
        if (livePhotoVideoID is not null) fields.Add(("livePhotoVideoId", livePhotoVideoID));
        var mime = Mime.ForName(name);
        var boundary = "CirrusImmich" + Guid.NewGuid().ToString("N");
        // Idempotent: a retried upload that already landed comes back as a duplicate of the same asset.
        var r = await Client.SendAsync("POST", "/assets",
            body: (sent, kick) => new ImmichUpload.MultipartContent(fields, "assetData", file, name, mime, boundary, sent, kick),
            headers: new Dictionary<string, string> { ["x-immich-checksum"] = checksum },
            retry: ImmichRetry.Safe, sent: n => progress?.Invoke(baseDone + n, total), ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Client.Failure(r);
        return ImmichClient.ParseJson(r.Data) is { } j && j["id"].Str is { } id ? id : throw CloudException.Server("Immich didn’t say which photo it created.");
    }

    // MARK: Change tracking

    /// <summary>Immich has no change feed Cirrus uses: every listing asks the server.</summary>
    public string? SyncToken(PhotoLibraryRef library) => null;

    public Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default) =>
        Task.FromResult<(bool, string?)>((true, null));
}
