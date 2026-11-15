using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// iCloud Photos through CloudKit web services (ckdatabasews). Listing follows rclone's photos backend;
/// record edits follow icloudpd (soft delete via isDeleted on CPLAsset). Port of WebPhotos.swift.
/// </summary>
public sealed class WebPhotos : IPhotosBackend
{
    public ICloudSession Session { get; }
    public string CacheKey { get; }
    public PhotoCapabilities Capabilities => PhotoCapabilities.Favorite | PhotoCapabilities.Hide | PhotoCapabilities.Delete | PhotoCapabilities.Restore
        | PhotoCapabilities.ImportFiles | PhotoCapabilities.Albums | PhotoCapabilities.CreateAlbum;
    static readonly (string app, string ws) Pcs = ("photos", "ckdatabasews");
    internal const int PageLimit = 200;
    readonly object _lock = new();
    readonly Dictionary<string, PhotoLibraryRef> _libs = [];
    readonly Dictionary<string, string> _tokens = [];   // library → latest CloudKit syncToken seen
    /// <summary>How long the optional shared-library lookup may take before Cirrus goes on without it.</summary>
    internal TimeSpan SharedZoneTimeout { get; set; } = TimeSpan.FromSeconds(6);

    /// <summary>The last library lookup couldn't reach the shared database: the list may be missing a Shared Library.</summary>
    public bool SharedLookupFailed { get; private set; }

    /// <summary>Libraries known from an earlier run (disk cache): needed to address shared zones correctly.</summary>
    public void Remember(IEnumerable<PhotoLibraryRef> libs) { lock (_lock) foreach (var l in libs) _libs.TryAdd(l.Id, l); }

    void NoteToken(J r, string library)
    {
        if (r["syncToken"].Str is { Length: > 0 } t) lock (_lock) _tokens[library] = t;
    }

    public string? SyncToken(PhotoLibraryRef library) { lock (_lock) return _tokens.TryGetValue(library.Id, out var t) ? t : null; }

    /// <summary>CloudKit change feed: no records since <paramref name="token"/> means every cached listing of the library is current.</summary>
    public async Task<(bool Changed, string? Token)> HasChangesAsync(string token, PhotoLibraryRef library, CancellationToken ct = default)
    {
        var lib = Library(library.Id);
        var body = new JsonObject
        {
            ["zones"] = new JsonArray(new JsonObject { ["zoneID"] = ZoneID(lib), ["syncToken"] = token, ["desiredKeys"] = new JsonArray("isDeleted") }),
        };
        var r = await Call(lib.Area, "changes/zone", body, ct: ct).ConfigureAwait(false);
        var zone = r["zones"][0];
        var newToken = zone["syncToken"].Str;
        if (newToken is not null) lock (_lock) _tokens[library.Id] = newToken;
        var unchanged = !zone.IsNull && zone["records"].Array.Count == 0 && zone["moreComing"].Bool != true && zone["serverErrorCode"].IsNull;
        return (!unchanged, newToken);
    }

    public WebPhotos(ICloudSession session, string appleID)
    {
        Session = session;
        CacheKey = "web-" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(appleID.ToLowerInvariant())))[..16];
    }

    internal sealed record Smart(string Key, string Name, string ObjectType, string ListType, string Direction, string? Filter, string Symbol);

    internal static readonly Smart[] SmartAlbums =
    [
        new("All Photos", "All Photos", "CPLAssetByAssetDateWithoutHiddenOrDeleted", "CPLAssetAndMasterByAssetDateWithoutHiddenOrDeleted", "ASCENDING", null, "photos"),
        new("Favorites", "Favorites", "CPLAssetInSmartAlbumByAssetDate:Favorite", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "FAVORITE", "heart"),
        new("Videos", "Videos", "CPLAssetInSmartAlbumByAssetDate:Video", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "VIDEO", "video"),
        new("Live", "Live Photos", "CPLAssetInSmartAlbumByAssetDate:Live", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "LIVE", "live"),
        new("Screenshots", "Screenshots", "CPLAssetInSmartAlbumByAssetDate:Screenshot", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "SCREENSHOT", "screenshot"),
        new("Portrait", "Portrait", "CPLAssetInSmartAlbumByAssetDate:Depth", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "DEPTH", "portrait"),
        new("Panoramas", "Panoramas", "CPLAssetInSmartAlbumByAssetDate:Panorama", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "PANORAMA", "pano"),
        new("Slo-mo", "Slo-mo", "CPLAssetInSmartAlbumByAssetDate:Slomo", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "SLOMO", "slomo"),
        new("Time-lapse", "Time-lapse", "CPLAssetInSmartAlbumByAssetDate:Timelapse", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "TIMELAPSE", "timelapse"),
        new("Long Exposure", "Long Exposure", "CPLAssetInSmartAlbumByAssetDate:Exposure", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "EXPOSURE", "exposure"),
        new("Animated", "Animated", "CPLAssetInSmartAlbumByAssetDate:Animated", "CPLAssetAndMasterInSmartAlbumByAssetDate", "ASCENDING", "ANIMATED", "animated"),
        new("Bursts", "Bursts", "CPLAssetBurstStackAssetByAssetDate", "CPLBurstStackAssetAndMasterByAssetDate", "ASCENDING", null, "bursts"),
        new("Hidden", "Hidden", "CPLAssetHiddenByAssetDate", "CPLAssetAndMasterHiddenByAssetDate", "ASCENDING", null, "hidden"),
        new("Recently Deleted", "Recently Deleted", "CPLAssetDeletedByExpungedDate", "CPLAssetAndMasterDeletedByExpungedDate", "DESCENDING", null, "trash"),
    ];

    static readonly string[] DesiredKeys =
    [
        "resOriginalRes", "resOriginalVidComplRes", "resOriginalFileType", "resOriginalWidth", "resOriginalHeight",
        "resOriginalAltRes", "resOriginalAltFileType", "resJPEGThumbRes", "resJPEGMedRes", "resJPEGThumbFileType",
        "filenameEnc", "itemType", "assetDate", "addedDate", "masterRef", "isFavorite", "isHidden", "isDeleted",
        "assetSubtype", "assetSubtypeV2", "burstId", "adjustmentRenderType", "adjustmentType", "duration",
        "resJPEGFullRes", "resJPEGFullFileType", "resVidFullRes", "resVidFullFileType", "resVidSmallRes",
    ];

    string Endpoint(string area, string op)
    {
        var b = Session.WebserviceURL("ckdatabasews") ?? throw ICloudException.Unavailable("iCloud Photos");
        return $"{b}/database/1/com.apple.photos.cloud/production/{area}/{op}";
    }

    Task<J> Call(string area, string op, JsonNode body, bool idempotent = true, CancellationToken ct = default) =>
        Session.RequestAsync(Endpoint(area, op), query: new Dictionary<string, string> { ["remapEnums"] = "true", ["getCurrentSyncToken"] = "true" },
            json: body, contentType: "text/plain", pcs: Pcs, idempotent: idempotent, ct: ct);

    static JsonObject ZoneID(PhotoLibraryRef lib)
    {
        var z = new JsonObject { ["zoneName"] = lib.Id };
        if (lib.OwnerRecordName is { } o) z["ownerRecordName"] = o;
        if (lib.ZoneType is { } t) z["zoneType"] = t;
        return z;
    }

    PhotoLibraryRef Library(string id)
    {
        lock (_lock) return _libs.TryGetValue(id, out var l) ? l : new PhotoLibraryRef(id, id, id != "PrimarySync");
    }

    // MARK: Libraries & albums

    public async Task<List<PhotoLibraryRef>> LibrariesAsync(CancellationToken ct = default)
    {
        // Private and shared databases in parallel; the shared one is optional and gets a short leash.
        var privateTask = Call("private", "changes/database", new JsonObject(), ct: ct);
        using var sharedCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        sharedCts.CancelAfter(SharedZoneTimeout);
        var sharedTask = Task.Run(async () =>
        {
            try { return (J?)await Call("shared", "changes/database", new JsonObject(), ct: sharedCts.Token).ConfigureAwait(false); }
            catch (Exception e) { Log.Status("photos: shared libraries unavailable (" + e.GetType().Name + ")"); return null; }
        }, CancellationToken.None);
        var priv = await privateTask.ConfigureAwait(false);
        var sharedOrNull = await sharedTask.ConfigureAwait(false);
        SharedLookupFailed = sharedOrNull is null;
        var shared = sharedOrNull ?? J.Null;
        var found = new List<PhotoLibraryRef>();
        foreach (var (area, r) in new[] { ("private", priv), ("shared", shared) })
        {
            foreach (var z in r["zones"].Array)
            {
                if (z["deleted"].Bool == true) continue;
                var name = z["zoneID"]["zoneName"].Str ?? "";
                if (!(name == "PrimarySync" || name.StartsWith("SharedSync", StringComparison.Ordinal)) || found.Any(f => f.Id == name)) continue;
                found.Add(new PhotoLibraryRef(name, name == "PrimarySync" ? "Personal Library" : "Shared Library", name != "PrimarySync")
                {
                    Area = area, OwnerRecordName = z["zoneID"]["ownerRecordName"].Str, ZoneType = z["zoneID"]["zoneType"].Str,
                });
            }
        }
        if (found.Count == 0) found.Add(new PhotoLibraryRef("PrimarySync", "Personal Library", false));
        found = found.OrderBy(l => l.IsShared ? 1 : 0).ToList();
        lock (_lock) foreach (var l in found) _libs[l.Id] = l;
        return found;
    }

    public async Task<List<PhotoAlbum>> AlbumsAsync(PhotoLibraryRef library, CancellationToken ct = default)
    {
        var albums = SmartAlbums.Select(s => new PhotoAlbum("smart:" + s.Key, s.Name, PhotoAlbumKind.Smart, symbol: s.Symbol)).ToList();
        string? marker = null;
        var records = new List<J>();
        do
        {
            var q = new JsonObject
            {
                ["query"] = new JsonObject { ["recordType"] = "CPLAlbumByPositionLive" },
                ["zoneID"] = ZoneID(library),
                ["desiredKeys"] = Jx.Strings(["albumNameEnc", "albumType", "parentId", "isDeleted"]),
            };
            if (marker is not null) q["continuationMarker"] = marker;
            J r;
            try { r = await Call(library.Area, "records/query", q, ct: ct).ConfigureAwait(false); }
            catch (Exception) when (library.IsShared && !ct.IsCancellationRequested) { break; }  // shared libraries have no album index
            records.AddRange(r["records"].Array);
            marker = r["continuationMarker"].Str;
        } while (marker is not null);
        foreach (var rec in records)
        {
            var f = rec["fields"];
            if (rec["recordName"].Str is not string name || name is "----Root-Folder----" or "----Project-Root-Folder----"
                || f["isDeleted"]["value"].Bool == true || f["albumNameEnc"]["value"].Str is not string enc) continue;
            string title;
            try { title = Encoding.UTF8.GetString(Convert.FromBase64String(enc)); } catch { title = enc; }
            title = title.Normalize(NormalizationForm.FormC);
            var isFolder = f["albumType"]["value"].Int == 3;
            var parent = f["parentId"]["value"].Str;
            if (parent == "----Root-Folder----") parent = null;
            albums.Add(new PhotoAlbum((isFolder ? "folder:" : "album:") + name, title, isFolder ? PhotoAlbumKind.Folder : PhotoAlbumKind.Album,
                parent is null ? null : "folder:" + parent, symbol: isFolder ? "folder" : "album"));
        }
        // Counts in one batch.
        var countable = albums.Where(a => a.Kind != PhotoAlbumKind.Folder).ToList();
        var batch = new JsonArray();
        foreach (var a in countable) batch.Add(CountQuery(ObjectType(a), library));
        try
        {
            var r = await Call(library.Area, "internal/records/query/batch", new JsonObject { ["batch"] = batch }, ct: ct).ConfigureAwait(false);
            for (int i = 0; i < countable.Count; i++)
                if (r["batch"][i]["records"][0]["fields"]["itemCount"]["value"].Int is int n) countable[i].Count = n;
        }
        catch (OperationCanceledException) { throw; }
        catch { }
        return albums;
    }

    static JsonObject CountQuery(string objectType, PhotoLibraryRef lib) => new()
    {
        ["resultsLimit"] = 1, ["zoneWide"] = true, ["zoneID"] = ZoneID(lib),
        ["query"] = new JsonObject
        {
            ["recordType"] = "HyperionIndexCountLookup",
            ["filterBy"] = new JsonObject
            {
                ["fieldName"] = "indexCountID", ["comparator"] = "IN",
                ["fieldValue"] = new JsonObject { ["type"] = "STRING_LIST", ["value"] = new JsonArray(objectType) },
            },
        },
    };

    static string ObjectType(PhotoAlbum album)
    {
        if (album.Kind == PhotoAlbumKind.Smart && SmartAlbums.FirstOrDefault(s => "smart:" + s.Key == album.Id) is { } s) return s.ObjectType;
        return "CPLContainerRelationNotDeletedByAssetDate:" + album.Id.Replace("album:", "");
    }

    internal static JsonObject ListQuery(PhotoAlbum album, PhotoLibraryRef lib, int startRank)
    {
        var listType = "CPLContainerRelationLiveByAssetDate";
        var direction = "ASCENDING";
        var filters = new List<JsonObject>();
        static JsonObject F(string field, string type, JsonNode value) => new()
        {
            ["fieldName"] = field, ["comparator"] = "EQUALS", ["fieldValue"] = new JsonObject { ["type"] = type, ["value"] = value },
        };
        if (album.Kind == PhotoAlbumKind.Smart && SmartAlbums.FirstOrDefault(s => "smart:" + s.Key == album.Id) is { } s)
        {
            listType = s.ListType;
            direction = s.Direction;
            if (s.Filter is { } f) filters.Add(F("smartAlbum", "STRING", f));
        }
        else filters.Add(F("parentId", "STRING", album.Id.Replace("album:", "")));
        var all = new JsonArray(F("startRank", "INT64", startRank), F("direction", "STRING", direction));
        foreach (var f in filters) all.Add(f);
        return new JsonObject
        {
            ["query"] = new JsonObject { ["recordType"] = listType, ["filterBy"] = all },
            ["resultsLimit"] = PageLimit, ["desiredKeys"] = Jx.Strings(DesiredKeys), ["zoneID"] = ZoneID(lib),
        };
    }

    // MARK: Assets

    public async Task<List<PhotoAsset>> AssetsAsync(PhotoAlbum album, PhotoLibraryRef library, Action<IReadOnlyList<PhotoAsset>, int?>? page, CancellationToken ct = default)
    {
        if (album.Kind == PhotoAlbumKind.Folder) return [];
        var lib = Library(library.Id).OwnerRecordName is null ? library : Library(library.Id);
        var total = album.Count;
        if (total is null)
        {
            try
            {
                var r = await Call(lib.Area, "records/query", CountQuery(ObjectType(album), lib), ct: ct).ConfigureAwait(false);
                total = r["records"][0]["fields"]["itemCount"]["value"].Int;
            }
            catch (OperationCanceledException) { throw; }
            catch { }
        }
        // Partitions of 100 assets each (a full page always holds >= 100 assets), fetched in parallel
        // from the newest end, de-duplicated by asset record name.
        const int stride = PageLimit / 2;
        var partitions = Math.Max(1, ((total ?? 0) + stride - 1) / stride);
        var results = new SortedDictionary<int, List<PhotoAsset>>();
        bool lastFull = false;
        var pageLock = new object();
        using (var gate = new SemaphoreSlim(6))
        {
            var tasks = new List<Task>();
            for (int idx = partitions - 1; idx >= 0; idx--)
            {
                await gate.WaitAsync(ct).ConfigureAwait(false);
                var i = idx;
                tasks.Add(Task.Run(async () =>
                {
                    try
                    {
                        var r = await Call(lib.Area, "records/query", ListQuery(album, lib, i * stride), ct: ct).ConfigureAwait(false);
                        NoteToken(r, lib.Id);
                        var recs = r["records"].Array;
                        var batch = Parse(recs, lib.Id);
                        lock (pageLock)
                        {
                            results[i] = batch;
                            if (i == partitions - 1) lastFull = recs.Count >= PageLimit;
                            page?.Invoke(batch, total);
                        }
                    }
                    finally { gate.Release(); }
                }, ct));
            }
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        // Tail pages if the count was stale.
        var rank = partitions * stride;
        var more = lastFull || total is null;
        var tailIndex = partitions;
        while (more)
        {
            ct.ThrowIfCancellationRequested();
            var r = await Call(lib.Area, "records/query", ListQuery(album, lib, rank), ct: ct).ConfigureAwait(false);
            var recs = r["records"].Array;
            var batch = Parse(recs, lib.Id);
            results[tailIndex] = batch;
            if (batch.Count > 0) page?.Invoke(batch, null);
            more = recs.Count >= PageLimit && batch.Count > 0;
            rank += stride;
            tailIndex++;
        }
        var seen = new HashSet<string>();
        var output = new List<PhotoAsset>();
        foreach (var (_, list) in results)
            foreach (var a in list)
                if (seen.Add(a.Id)) output.Add(a);
        return output;
    }

    internal static List<PhotoAsset> Parse(IReadOnlyList<J> records, string library)
    {
        var masters = new Dictionary<string, J>();
        var assets = new List<J>();
        foreach (var r in records)
        {
            switch (r["recordType"].Str)
            {
                case "CPLMaster": if (r["recordName"].Str is { } n) masters[n] = r; break;
                case "CPLAsset": assets.Add(r); break;
            }
        }
        var output = new List<PhotoAsset>();
        foreach (var a in assets)
        {
            if (a["fields"]["masterRef"]["value"]["recordName"].Str is not string mid || !masters.TryGetValue(mid, out var m)) continue;
            if (Build(m, a, library) is { } built) output.Add(built);
        }
        return output;
    }

    internal static PhotoAsset? Build(J m, J a, string library)
    {
        J mf = m["fields"], af = a["fields"];
        if (a["recordName"].Str is not string assetID || m["recordName"].Str is not string masterID) return null;
        var filename = "";
        var fe = mf["filenameEnc"];
        if (fe["value"].Str is { } v)
        {
            if (fe["type"].Str == "STRING") filename = v;
            else { try { filename = Encoding.UTF8.GetString(Convert.FromBase64String(v)); } catch { filename = v; } }
        }
        var uti = mf["resOriginalFileType"]["value"].Str ?? mf["itemType"]["value"].Str;
        if (filename.Length == 0) filename = masterID + "." + (uti is not null && PhotoFormats.UtiExtensions.TryGetValue(uti, out var e0) ? e0 : "jpg");
        filename = Paths.SafeName(filename.Normalize(NormalizationForm.FormC));
        var stem = Path.GetFileNameWithoutExtension(filename);
        var ext = Path.GetExtension(filename).TrimStart('.');
        PhotoResource? Res(J fields, string key, PhotoResourceKind kind, string owner, string name, string? utiKey = null)
        {
            var val = fields[key]["value"];
            if (val["downloadURL"].Str is not string url) return null;
            return new PhotoResource { Kind = kind, Filename = name, Size = val["size"].Int64 ?? 0, Key = key, RecordName = owner, Url = url,
                Uti = utiKey is null ? null : fields[utiKey]["value"].Str };
        }
        var resources = new List<PhotoResource>();
        if (Res(mf, "resOriginalRes", PhotoResourceKind.Original, masterID, filename, "resOriginalFileType") is not { } original) return null;
        resources.Add(original);
        if (Res(mf, "resOriginalVidComplRes", PhotoResourceKind.LiveVideo, masterID, stem + ".MOV") is { } live) resources.Add(live);
        var adjustment = af["adjustmentType"]["value"].Str ?? "";
        if (adjustment.Length > 0 && adjustment != "com.apple.video.slomo")
        {
            var ed = Res(af, "resJPEGFullRes", PhotoResourceKind.Edited, assetID, "", "resJPEGFullFileType")
                  ?? Res(af, "resVidFullRes", PhotoResourceKind.Edited, assetID, "", "resVidFullFileType");
            if (ed is not null)
            {
                var eext = ed.Uti is not null && PhotoFormats.UtiExtensions.TryGetValue(ed.Uti, out var x) ? x : ext;
                ed.Filename = stem + "-edited." + eext;
                resources.Add(ed);
            }
        }
        if (Res(mf, "resOriginalAltRes", PhotoResourceKind.Alternate, masterID, "", "resOriginalAltFileType") is { } alt)
        {
            var aext = alt.Uti is not null && PhotoFormats.UtiExtensions.TryGetValue(alt.Uti, out var y) ? y : "dng";
            alt.Filename = aext.Equals(ext, StringComparison.OrdinalIgnoreCase) ? stem + "-alt." + aext : stem + "." + aext;
            resources.Add(alt);
        }
        if (Res(mf, "resJPEGThumbRes", PhotoResourceKind.Thumbnail, masterID, stem + "-thumb.jpg") is { } t) resources.Add(t);
        if (Res(mf, "resJPEGMedRes", PhotoResourceKind.Medium, masterID, stem + "-medium.jpg") is { } md) resources.Add(md);
        return new PhotoAsset
        {
            Id = assetID, MasterID = masterID, ChangeTag = a["recordChangeTag"].Str, Library = library, Filename = filename,
            Size = original.Size, Created = af["assetDate"]["value"].Date, Added = af["addedDate"]["value"].Date,
            Width = mf["resOriginalWidth"]["value"].Int ?? 0, Height = mf["resOriginalHeight"]["value"].Int ?? 0,
            Duration = af["duration"]["value"].Double, IsVideo = uti is not null && PhotoFormats.VideoUTIs.Contains(uti),
            IsLive = resources.Any(r => r.Kind == PhotoResourceKind.LiveVideo),
            IsFavorite = af["isFavorite"]["value"].Int == 1, IsHidden = af["isHidden"]["value"].Int == 1,
            IsDeleted = af["isDeleted"]["value"].Int == 1, IsEdited = resources.Any(r => r.Kind == PhotoResourceKind.Edited),
            Uti = uti, Resources = resources,
        };
    }

    // MARK: Content

    async Task<string> FreshURL(PhotoResource r, string library, CancellationToken ct)
    {
        var lib = Library(library);
        var resp = await Call(lib.Area, "records/lookup", new JsonObject
        {
            ["records"] = new JsonArray(new JsonObject { ["recordName"] = r.RecordName }), ["zoneID"] = ZoneID(lib),
        }, ct: ct).ConfigureAwait(false);
        return resp["records"][0]["fields"][r.Key]["value"]["downloadURL"].Str ?? throw ICloudException.NotFound();
    }

    async Task Fetch(PhotoResource r, string library, string dest, Action<long, long>? progress, CancellationToken ct)
    {
        if (r.Url is { } url)
        {
            try { await Session.DownloadAsync(url, dest, r.Size, progress, ct).ConfigureAwait(false); return; }
            catch (ICloudException e) when (e.Kind == ICloudErrorKind.Http && e.StatusCode is 401 or 403 or 404 or 410) { }
        }
        await Session.DownloadAsync(await FreshURL(r, library, ct).ConfigureAwait(false), dest, r.Size, progress, ct).ConfigureAwait(false);
    }

    public async Task<byte[]?> ThumbnailAsync(PhotoAsset asset, int maxPixel, CancellationToken ct = default)
    {
        var kind = maxPixel > 400 ? PhotoResourceKind.Medium : PhotoResourceKind.Thumbnail;
        var px = kind == PhotoResourceKind.Medium ? 1024 : 360;
        if (ThumbnailDiskCache.Read(CacheKey, asset.Id, px) is { } cached) return cached;
        // No medium rendition (common for uploads): use the original for big previews when it's small enough.
        var r = asset.Resource(kind);
        if (r is null && kind == PhotoResourceKind.Medium && asset.Resource(PhotoResourceKind.Original) is { Size: > 0 and <= 20_000_000 } o && !asset.IsVideo) r = o;
        r ??= asset.Resource(PhotoResourceKind.Thumbnail);
        if (r is null) return null;
        var tmp = Paths.TempFile("t.img");
        try
        {
            await Fetch(r, asset.Library, tmp, null, ct).ConfigureAwait(false);
            var data = await File.ReadAllBytesAsync(tmp, ct).ConfigureAwait(false);
            if (r.Kind == PhotoResourceKind.Original)
            {
                // Keep a JPEG preview, not a copy of the original, in the cache.
                if (ImageReencoder.ToJpeg?.Invoke(data, px) is not { Length: > 0 } jpeg) return data;
                data = jpeg;
            }
            ThumbnailDiskCache.Write(data, CacheKey, asset.Id, px);
            return data;
        }
        finally { try { Directory.Delete(Path.GetDirectoryName(tmp)!, true); } catch { } }   // our own scratch folder
    }

    public async Task ExportAsync(PhotoAsset asset, PhotoResourceKind resource, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        var r = asset.Resource(resource) ?? throw ICloudException.NotFound();
        await Fetch(r, asset.Library, destination, progress, ct).ConfigureAwait(false);
        if (asset.Created is { } d) { try { File.SetLastWriteTimeUtc(destination, d.UtcDateTime); File.SetCreationTimeUtc(destination, d.UtcDateTime); } catch { } }
    }

    // MARK: Edits

    async Task<List<PhotoAsset>> ModifyAssets(IReadOnlyList<PhotoAsset> assets, Dictionary<string, int> fields, CancellationToken ct)
    {
        var updated = assets.Select(a => a.Copy()).ToList();
        foreach (var group in Enumerable.Range(0, assets.Count).GroupBy(i => assets[i].Library))
        {
            var lib = Library(group.Key);
            foreach (var chunk in group.Chunk(100))
            {
                var ops = new JsonArray();
                foreach (var i in chunk)
                {
                    var f = new JsonObject();
                    foreach (var (k, v) in fields) f[k] = new JsonObject { ["value"] = v };
                    ops.Add(new JsonObject
                    {
                        ["operationType"] = "update",
                        ["record"] = new JsonObject
                        {
                            ["recordName"] = assets[i].Id, ["recordType"] = "CPLAsset", ["recordChangeTag"] = assets[i].ChangeTag ?? "", ["fields"] = f,
                        },
                    });
                }
                var r = await Call(lib.Area, "records/modify", new JsonObject
                {
                    ["atomic"] = false, ["operations"] = ops, ["zoneID"] = ZoneID(lib), ["desiredKeys"] = Jx.Strings(fields.Keys),
                }, idempotent: false, ct: ct).ConfigureAwait(false);
                foreach (var rec in r["records"].Array)
                {
                    if ((rec["reason"].Str ?? rec["serverErrorCode"].Str) is { } reason) throw ICloudException.Server("iCloud Photos refused the change: " + reason);
                    if (rec["recordName"].Str is { } name && chunk.FirstOrDefault(i => assets[i].Id == name, -1) is int idx && idx >= 0)
                    {
                        updated[idx].ChangeTag = rec["recordChangeTag"].Str ?? updated[idx].ChangeTag;
                        if (fields.TryGetValue("isFavorite", out var fv)) updated[idx].IsFavorite = fv == 1;
                        if (fields.TryGetValue("isHidden", out var hv)) updated[idx].IsHidden = hv == 1;
                        if (fields.TryGetValue("isDeleted", out var dv)) updated[idx].IsDeleted = dv == 1;
                    }
                }
            }
        }
        return updated;
    }

    public Task<List<PhotoAsset>> SetFavoriteAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        return ModifyAssets(assets, new() { ["isFavorite"] = value ? 1 : 0 }, ct);
    }

    public Task<List<PhotoAsset>> SetHiddenAsync(IReadOnlyList<PhotoAsset> assets, bool value, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        return ModifyAssets(assets, new() { ["isHidden"] = value ? 1 : 0 }, ct);
    }

    /// <summary>Moves to Recently Deleted (recoverable for 30 days), like icloudpd's delete.</summary>
    public async Task DeleteAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await ModifyAssets(assets, new() { ["isDeleted"] = 1 }, ct).ConfigureAwait(false);
    }

    public async Task RestoreAsync(IReadOnlyList<PhotoAsset> assets, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        await ModifyAssets(assets, new() { ["isDeleted"] = 0 }, ct).ConfigureAwait(false);
    }

    public Task ImportFilesAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress, CancellationToken ct = default) =>
        ImportFilesEachAsync(files, album, library, progress, (_, _) => { }, ct);

    public async Task ImportFilesEachAsync(IReadOnlyList<string> files, PhotoAlbum? album, PhotoLibraryRef library, Action<long, long>? progress,
        Action<string, string?> imported, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        if (Session.WebserviceURL("uploadimagews") is not string b || Session.Dsid is not string dsid) throw ICloudException.Unavailable("iCloud Photos upload");
        await Session.EnsurePcsAsync("photos", "ckdatabasews", ct).ConfigureAwait(false);
        var created = new List<string>();
        long total = files.Sum(f => new FileInfo(f).Length), before = 0;
        foreach (var file in files)
        {
            var mod = File.GetLastWriteTimeUtc(file);
            var size = new FileInfo(file).Length;
            var r = await Session.UploadAsync(b + "/upload", new Dictionary<string, string>
            {
                ["filename"] = Path.GetFileName(file), ["dsid"] = dsid,
                ["lastModDate"] = new DateTimeOffset(mod, TimeSpan.Zero).ToUnixTimeMilliseconds().ToString(),
                ["timezoneOffset"] = ((int)TimeZoneInfo.Local.GetUtcOffset(DateTime.Now).TotalMinutes).ToString(),
            }, file, null, "application/octet-stream", (d, _) => progress?.Invoke(before + d, total), ct).ConfigureAwait(false);
            if ((r["errors"][0]["errorMessage"].Str ?? r["errors"][0]["message"].Str) is { } err) throw ICloudException.Server(err);
            var ids = r["records"].Array.Where(x => x["recordType"].Str == "CPLAsset").Select(x => x["recordName"].Str).OfType<string>().ToList();
            created.AddRange(ids);
            before += size;
            imported(file, ids.FirstOrDefault());   // in iCloud now, whatever happens next
        }
        if (album is { Kind: PhotoAlbumKind.Album } && created.Count > 0)
            await AddAsync(created.Select(id => new PhotoAsset { Id = id, Library = library.Id }).ToList(), album, library, ct).ConfigureAwait(false);
    }

    public async Task AddAsync(IReadOnlyList<PhotoAsset> assets, PhotoAlbum album, PhotoLibraryRef library, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        if (album.Kind != PhotoAlbumKind.Album) throw ICloudException.Server("Photos can only be added to regular albums.");
        var lib = Library(library.Id);
        var albumRecord = album.Id.Replace("album:", "");
        foreach (var chunk in assets.Chunk(100))
        {
            var ops = new JsonArray();
            for (int i = 0; i < chunk.Length; i++)
            {
                var a = chunk[i];
                ops.Add(new JsonObject
                {
                    ["operationType"] = "create",
                    ["record"] = new JsonObject
                    {
                        ["recordName"] = $"{a.Id}-IN-{albumRecord}", ["recordType"] = "CPLContainerRelation",
                        ["fields"] = new JsonObject
                        {
                            ["itemId"] = new JsonObject { ["value"] = a.Id }, ["containerId"] = new JsonObject { ["value"] = albumRecord },
                            ["position"] = new JsonObject { ["value"] = 1024 * (i + 1) },
                        },
                    },
                });
            }
            var r = await Call(lib.Area, "records/modify", new JsonObject { ["atomic"] = false, ["operations"] = ops, ["zoneID"] = ZoneID(lib) }, idempotent: false, ct: ct).ConfigureAwait(false);
            foreach (var rec in r["records"].Array)
                if (rec["serverErrorCode"].Str is { } code && code != "CONFLICT")
                    throw ICloudException.Server("Couldn’t add to album: " + (rec["reason"].Str ?? code));
        }
    }

    public async Task<PhotoAlbum> CreateAlbumAsync(string name, PhotoLibraryRef library, CancellationToken ct = default)
    {
        SafetyPolicy.CheckWrite();
        var lib = Library(library.Id);
        var record = Guid.NewGuid().ToString().ToUpperInvariant();
        var op = new JsonObject
        {
            ["operationType"] = "create",
            ["record"] = new JsonObject
            {
                ["recordName"] = record, ["recordType"] = "CPLAlbum",
                ["fields"] = new JsonObject
                {
                    ["albumNameEnc"] = new JsonObject { ["value"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(name)), ["type"] = "ENCRYPTED_BYTES" },
                    ["albumType"] = new JsonObject { ["value"] = 0 },
                    ["position"] = new JsonObject { ["value"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() },
                    ["parentId"] = new JsonObject { ["value"] = "----Root-Folder----" },
                    ["sortAscending"] = new JsonObject { ["value"] = 1 },
                    ["sortType"] = new JsonObject { ["value"] = 0 },
                },
            },
        };
        var r = await Call(lib.Area, "records/modify", new JsonObject { ["atomic"] = true, ["operations"] = new JsonArray(op), ["zoneID"] = ZoneID(lib) }, idempotent: false, ct: ct).ConfigureAwait(false);
        if (r["records"][0]["reason"].Str is { } reason) throw ICloudException.Server("Couldn’t create album: " + reason);
        return new PhotoAlbum("album:" + record, name, PhotoAlbumKind.Album, count: 0);
    }
}
