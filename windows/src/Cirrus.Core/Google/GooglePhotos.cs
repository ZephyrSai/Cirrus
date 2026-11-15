using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// Photos Library API, as limited since 31 March 2025 (port of GooglePhotos.swift): Cirrus can add media and create
/// albums (photoslibrary.appendonly) but can't read the user's library. Items and albums Cirrus creates are the only ones
/// it can put together.
/// </summary>
public sealed class GooglePhotos
{
    public const string Base = "https://photoslibrary.googleapis.com/v1";
    public const int BatchLimit = 50;
    public const int AlbumLimit = 20_000;
    /// <summary>Google Photos: photos up to 200 MB, videos up to 20 GB.</summary>
    public const long MaxPhoto = 200L * 1024 * 1024;
    public const long MaxVideo = 20L * 1024 * 1024 * 1024;
    /// <summary>Files up to this size go up in one request; bigger ones use the resumable protocol.</summary>
    public const long RawLimit = 24 << 20;

    public enum Media { Photo, Video }
    public static readonly HashSet<string> PhotoTypes = new(StringComparer.OrdinalIgnoreCase)
    { "avif", "bmp", "gif", "heic", "heif", "ico", "jpg", "jpeg", "png", "tif", "tiff", "webp", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "pef", "srw", "raw" };
    public static readonly HashSet<string> VideoTypes = new(StringComparer.OrdinalIgnoreCase)
    { "3gp", "3g2", "asf", "avi", "divx", "m2t", "m2ts", "m4v", "mkv", "mmv", "mod", "mov", "mp4", "mpg", "mpeg", "mts", "tod", "wmv" };

    static string Ext(string name) => Path.GetExtension(name).TrimStart('.');

    public static Media? MediaFor(string name)
    {
        var e = Ext(name);
        if (PhotoTypes.Contains(e)) return Media.Photo;
        if (VideoTypes.Contains(e)) return Media.Video;
        return null;
    }

    /// <summary>Why Google Photos would refuse this file, or null when it's fine.</summary>
    public static string? Problem(string name, long size)
    {
        if (MediaFor(name) is not { } m)
        {
            var e = Ext(name);
            return e.Length == 0 ? "Google Photos can’t tell what kind of file this is" : $"Google Photos doesn’t accept .{e} files";
        }
        if (m == Media.Photo && size > MaxPhoto) return "Photos over 200 MB are too big for Google Photos";
        if (m == Media.Video && size > MaxVideo) return "Videos over 20 GB are too big for Google Photos";
        return null;
    }

    public static string MimeType(string name) => Ext(name).ToLowerInvariant() switch
    {
        "jpg" or "jpeg" => "image/jpeg",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "png" => "image/png",
        "gif" => "image/gif",
        "tif" or "tiff" => "image/tiff",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "mov" => "video/quicktime",
        "mp4" or "m4v" => "video/mp4",
        _ => GoogleDrive.MimeType(name),
    };

    public sealed record UploadSession(string Url, long Total, long Granularity, DateTimeOffset Started);
    public sealed record NewItem(string Token, string FileName, string? Description);
    public sealed record Created(string Token, string? MediaItemID, string? Error);

    public GoogleApi Api { get; }
    /// <summary>Bytes per resumable request (rounded down to Google's chunk granularity).</summary>
    public long ChunkSize { get; set; } = 8 << 20;

    public GooglePhotos(GoogleApi api) { Api = api; }

    static GoogleRequest Raw(string url, Dictionary<string, string> headers, GoogleBody body) => new()
    {
        Method = "POST", Url = url, Body = body, Headers = new Dictionary<string, string>(headers, StringComparer.OrdinalIgnoreCase),
    };

    /// <summary>Single-request upload. Returns an upload token (valid for a day).</summary>
    public async Task<string> UploadRawAsync(string file, string name, Action<long, long>? progress, CancellationToken ct = default)
    {
        var size = new FileInfo(file).Length;
        var req = Raw(Base + "/uploads", new()
        {
            ["Content-Type"] = "application/octet-stream", ["X-Goog-Upload-Content-Type"] = MimeType(name), ["X-Goog-Upload-Protocol"] = "raw",
        }, new GoogleBody.File(file));
        // An unused token simply expires, so repeating this is harmless.
        var r = await Api.SendAsync(req, idempotent: true, sent: s => progress?.Invoke(Math.Min(s, size), size), ct: ct).ConfigureAwait(false);
        progress?.Invoke(size, size);
        return Token(r);
    }

    static string Token(GoogleResponse r)
    {
        var t = r.Text.Trim();
        if (t.Length == 0 || t.StartsWith('{')) throw GoogleException.BadResponse("Google Photos didn’t return an upload token.");
        return t;
    }

    public async Task<UploadSession> StartResumableAsync(string name, long size, CancellationToken ct = default)
    {
        var req = Raw(Base + "/uploads", new()
        {
            ["X-Goog-Upload-Command"] = "start", ["X-Goog-Upload-Content-Type"] = MimeType(name), ["X-Goog-Upload-Protocol"] = "resumable",
            ["X-Goog-Upload-Raw-Size"] = size.ToString(CultureInfo.InvariantCulture),
        }, GoogleBody.Empty);
        var r = await Api.SendAsync(req, idempotent: true, ct: ct).ConfigureAwait(false);
        if (r.Header("X-Goog-Upload-URL") is not { } url || !Uri.TryCreate(url, UriKind.Absolute, out _)) throw GoogleException.BadResponse("Google Photos didn’t open an upload session.");
        var g = long.TryParse(r.Header("X-Goog-Upload-Chunk-Granularity"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var gg) ? gg : 262_144;
        return new UploadSession(url, size, Math.Max(1, g), DateTimeOffset.UtcNow);
    }

    /// <summary>Bytes Google has for this session, or null if the session is finished or gone.</summary>
    async Task<long?> ReceivedAsync(UploadSession s, CancellationToken ct)
    {
        var r = await Api.SendAsync(Raw(s.Url, new() { ["X-Goog-Upload-Command"] = "query" }, GoogleBody.Empty), idempotent: true, ct: ct).ConfigureAwait(false);
        if (!string.Equals(r.Header("X-Goog-Upload-Status"), "active", StringComparison.OrdinalIgnoreCase)) return null;
        return long.TryParse(r.Header("X-Goog-Upload-Size-Received"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : 0;
    }

    /// <summary>Resumable upload in granularity-sized chunks; the last one finalizes and returns the token.</summary>
    public async Task<string> UploadResumableAsync(string file, UploadSession s, bool resume, Action<long, long>? progress, CancellationToken ct = default)
    {
        long offset = 0;
        if (resume) offset = await ReceivedAsync(s, ct).ConfigureAwait(false) ?? throw GoogleException.UploadExpired();
        var chunk = Math.Max(s.Granularity, ChunkSize / s.Granularity * s.Granularity);
        await using var fh = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        int failures = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Invoke(offset, s.Total);
            var len = Math.Min(chunk, s.Total - offset);
            var last = offset + len >= s.Total;
            if (fh.Length != s.Total) throw GoogleException.BadResponse("The file changed while Cirrus was uploading it.");
            var data = new byte[len];
            fh.Position = offset;
            try { await fh.ReadExactlyAsync(data, ct).ConfigureAwait(false); }
            catch (EndOfStreamException) { throw GoogleException.BadResponse("The file changed while Cirrus was uploading it."); }
            var req = Raw(s.Url, new()
            {
                ["X-Goog-Upload-Command"] = last ? "upload, finalize" : "upload", ["X-Goog-Upload-Offset"] = offset.ToString(CultureInfo.InvariantCulture),
            }, new GoogleBody.Bytes(data));
            var b = offset;
            double? retryAfter = null;
            try
            {
                var r = await Api.PerformAsync(req, sent => progress?.Invoke(b + Math.Min(sent, len), s.Total), ct: ct).ConfigureAwait(false);
                switch (GoogleApi.Classify(r.Status, r.Data, r.Header("Retry-After")))
                {
                    case GoogleApi.Verdict.Ok:
                        if (last) { progress?.Invoke(s.Total, s.Total); return Token(r); }
                        offset += len;
                        failures = 0;
                        continue;
                    case GoogleApi.Verdict.Fail f:
                        if (r.Status is 404 or 410) throw GoogleException.UploadExpired();
                        throw f.Error;
                    case GoogleApi.Verdict.Retry rt: retryAfter = rt.After; break;
                }
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not GoogleException && GoogleHttp.IsTransient(e, true))
            {
                Log.Status($"google photos upload interrupted ({e.GetType().Name}); resuming");
            }
            failures++;
            if (failures > Api.MaxRetries) throw GoogleException.RateLimited();
            await Api.SleepAsync(Api.Delay(failures, retryAfter), ct).ConfigureAwait(false);
            offset = await ReceivedAsync(s, ct).ConfigureAwait(false) ?? throw GoogleException.UploadExpired();
        }
    }

    /// <summary>
    /// Creates up to 50 media items from upload tokens. Per-item failures come back in Error. Only one batchCreate runs at
    /// a time (Google's rule); re-sent bytes map to the same media item.
    /// </summary>
    public async Task<List<Created>> BatchCreateAsync(IReadOnlyList<NewItem> items, string? albumID = null, CancellationToken ct = default)
    {
        if (items.Count > BatchLimit) throw new ArgumentException("batchCreate takes at most 50 items");
        if (items.Count == 0) return [];
        var list = new JsonArray();
        foreach (var i in items)
        {
            var o = new JsonObject { ["simpleMediaItem"] = new JsonObject { ["uploadToken"] = i.Token, ["fileName"] = i.FileName } };
            if (i.Description is { Length: > 0 } d) o["description"] = d.Length > 999 ? d[..999] : d;
            list.Add(o);
        }
        var body = new JsonObject { ["newMediaItems"] = list };
        if (albumID is not null) body["albumId"] = albumID;
        var j = await Api.JsonAsync("POST", Base + "/mediaItems:batchCreate", body: body, idempotent: true, minBackoff: Api.BatchCreateMinBackoff, ct: ct).ConfigureAwait(false);
        var byToken = new Dictionary<string, Created>();
        foreach (var r in j["newMediaItemResults"].Array)
        {
            var token = r["uploadToken"].Str ?? "";
            var code = r["status"]["code"].Int ?? 0;
            var id = r["mediaItem"]["id"].Str;
            byToken[token] = new Created(token, code == 0 ? id : null, code == 0 && id is not null ? null : r["status"]["message"].Str ?? "Google Photos didn’t create this item");
        }
        return items.Select(i => byToken.TryGetValue(i.Token, out var c) ? c : new Created(i.Token, null, "Google Photos didn’t report on this item")).ToList();
    }

    /// <summary>New app-created album; returns its id.</summary>
    public async Task<string> CreateAlbumAsync(string title, CancellationToken ct = default)
    {
        var t = title.Length > 500 ? title[..500] : title;
        var j = await Api.JsonAsync("POST", Base + "/albums", body: new JsonObject { ["album"] = new JsonObject { ["title"] = t } }, idempotent: false, ct: ct).ConfigureAwait(false);
        return j["id"].Str ?? throw GoogleException.BadResponse("Google Photos didn’t create the album.");
    }

    /// <summary>Adds up to 50 app-created items to an app-created album (all or nothing).</summary>
    public async Task AddToAlbumAsync(string albumID, IReadOnlyList<string> mediaItemIDs, CancellationToken ct = default)
    {
        if (mediaItemIDs.Count > BatchLimit) throw new ArgumentException("batchAddMediaItems takes at most 50 items");
        if (mediaItemIDs.Count == 0) return;
        await Api.JsonAsync("POST", Base + "/albums/" + Uri.EscapeDataString(albumID) + ":batchAddMediaItems",
            body: new JsonObject { ["mediaItemIds"] = Jx.Strings(mediaItemIDs) }, ct: ct).ConfigureAwait(false);
    }
}

/// <summary>
/// Does a file carry its own capture date? Google Photos dates items from the file's metadata, so files without one get
/// the date written into the description instead. Read-only probes of the file's own bytes (no codecs needed):
/// EXIF in JPEG, PNG (eXIf), TIFF/DNG and HEIC/HEIF/AVIF, and the movie header of MOV/MP4.
/// </summary>
public static class MediaDates
{
    public static bool HasEmbeddedDate(string path, bool video)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            return video ? MovieHasDate(fs) : ImageHasDate(fs);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    public static string? Description(DateTimeOffset? date) =>
        date is { } d ? "Taken " + d.ToLocalTime().ToString("d MMM yyyy, HH:mm", CultureInfo.InvariantCulture) + " (from iCloud)" : null;

    // MARK: Images

    static bool ImageHasDate(FileStream fs)
    {
        var head = new byte[16];
        var n = fs.Read(head, 0, head.Length);
        if (n < 8) return false;
        fs.Position = 0;
        if (head[0] == 0xFF && head[1] == 0xD8) return JpegHasDate(fs);
        if (head[0] == 0x89 && head[1] == 'P' && head[2] == 'N' && head[3] == 'G') return PngHasDate(fs);
        if ((head[0] == 'I' && head[1] == 'I' && head[2] == 42 && head[3] == 0) || (head[0] == 'M' && head[1] == 'M' && head[2] == 0 && head[3] == 42))
            return TiffHasDate(ReadUpTo(fs, 64 << 20));
        if (n >= 12 && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p') return IsoHasExifDate(fs);
        return false;
    }

    static byte[] ReadUpTo(Stream s, int max)
    {
        var len = (int)Math.Min(max, Math.Max(0, s.Length - s.Position));
        var b = new byte[len];
        var got = 0;
        while (got < len) { var r = s.Read(b, got, len - got); if (r <= 0) break; got += r; }
        return got == len ? b : b[..got];
    }

    static bool JpegHasDate(FileStream fs)
    {
        fs.Position = 2;
        var two = new byte[2];
        while (fs.Position + 4 <= fs.Length)
        {
            if (fs.ReadByte() != 0xFF) return false;
            int marker = fs.ReadByte();
            while (marker == 0xFF) marker = fs.ReadByte();
            if (marker is 0xD9 or 0xDA or < 0) return false;          // end of image / start of scan: no more metadata
            if (marker is >= 0xD0 and <= 0xD7 or 0x01) continue;      // markers without a length
            if (fs.Read(two, 0, 2) < 2) return false;
            int len = (two[0] << 8) | two[1];
            if (len < 2) return false;
            if (marker == 0xE1 && len > 8)
            {
                var seg = ReadUpTo(fs, len - 2);
                if (seg.Length >= 6 && seg[0] == 'E' && seg[1] == 'x' && seg[2] == 'i' && seg[3] == 'f' && seg[4] == 0 && seg[5] == 0 && TiffHasDate(seg.AsSpan(6).ToArray()))
                    return true;
                continue;
            }
            fs.Position += len - 2;
        }
        return false;
    }

    static bool PngHasDate(FileStream fs)
    {
        fs.Position = 8;
        var hdr = new byte[8];
        while (fs.Position + 12 <= fs.Length)
        {
            if (fs.Read(hdr, 0, 8) < 8) return false;
            long len = (uint)((hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3]);
            var type = Encoding.ASCII.GetString(hdr, 4, 4);
            if (type == "eXIf" && len < 16 << 20) return TiffHasDate(ReadUpTo(fs, (int)len));
            if (type is "IDAT" or "IEND") return false;               // Apple and Google write eXIf before the image data
            fs.Position += len + 4;                                    // data + CRC
        }
        return false;
    }

    /// <summary>HEIC/HEIF/AVIF: the Exif item usually sits right after the 'meta' box; look for its TIFF header near the start.</summary>
    static bool IsoHasExifDate(FileStream fs)
    {
        var data = ReadUpTo(fs, 8 << 20);
        var span = data.AsSpan();
        ReadOnlySpan<byte> exif = "Exif\0\0"u8;
        var from = 0;
        while (from < span.Length)
        {
            var i = span[from..].IndexOf(exif);
            if (i < 0) return false;
            var at = from + i + exif.Length;
            if (at + 8 <= span.Length && TiffHasDate(span[at..].ToArray())) return true;
            from = at;
        }
        return false;
    }

    /// <summary>DateTimeOriginal / DateTimeDigitized in the Exif IFD, or DateTime in IFD0.</summary>
    internal static bool TiffHasDate(byte[] t)
    {
        if (t.Length < 8) return false;
        bool le;
        if (t[0] == 'I' && t[1] == 'I') le = true; else if (t[0] == 'M' && t[1] == 'M') le = false; else return false;
        ushort U16(int o) => o + 2 <= t.Length ? (ushort)(le ? t[o] | (t[o + 1] << 8) : (t[o] << 8) | t[o + 1]) : (ushort)0;
        uint U32(int o) => o + 4 <= t.Length ? (le ? (uint)(t[o] | (t[o + 1] << 8) | (t[o + 2] << 16) | (t[o + 3] << 24)) : (uint)((t[o] << 24) | (t[o + 1] << 16) | (t[o + 2] << 8) | t[o + 3])) : 0;
        if (U16(2) != 42) return false;
        bool HasValue(int entry)
        {
            var type = U16(entry + 2);
            var count = U32(entry + 4);
            if (type != 2 || count < 10) return false;                 // ASCII "YYYY:MM:DD HH:MM:SS"
            var off = count <= 4 ? entry + 8 : (int)U32(entry + 8);
            if (off < 0 || off + 4 > t.Length) return false;
            // Cameras without a clock write blanks or zeros.
            return t[off] is >= (byte)'1' and <= (byte)'9';
        }
        (bool Date, uint ExifIFD) Scan(uint ifd)
        {
            if (ifd < 8 || ifd + 2 > t.Length) return (false, 0);
            var count = U16((int)ifd);
            uint exif = 0;
            for (int i = 0; i < count && i < 512; i++)
            {
                var e = (int)ifd + 2 + i * 12;
                if (e + 12 > t.Length) break;
                var tag = U16(e);
                if (tag is 0x9003 or 0x9004 or 0x0132 && HasValue(e)) return (true, 0);
                if (tag == 0x8769) exif = U32(e + 8);
            }
            return (false, exif);
        }
        var (d0, exifIFD) = Scan(U32(4));
        if (d0) return true;
        return exifIFD != 0 && Scan(exifIFD).Date;
    }

    // MARK: Movies

    /// <summary>QuickTime / MP4: a creation time in the movie header ('moov' › 'mvhd') after 1970.</summary>
    static bool MovieHasDate(FileStream fs)
    {
        long pos = 0;
        var hdr = new byte[16];
        while (pos + 8 <= fs.Length)
        {
            fs.Position = pos;
            if (fs.Read(hdr, 0, 8) < 8) return false;
            long size = (uint)((hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3]);
            var type = Encoding.ASCII.GetString(hdr, 4, 4);
            int headerLen = 8;
            if (size == 1)
            {
                if (fs.Read(hdr, 8, 8) < 8) return false;
                size = (long)((ulong)hdr[8] << 56 | (ulong)hdr[9] << 48 | (ulong)hdr[10] << 40 | (ulong)hdr[11] << 32 | (ulong)hdr[12] << 24 | (ulong)hdr[13] << 16 | (ulong)hdr[14] << 8 | hdr[15]);
                headerLen = 16;
            }
            else if (size == 0) size = fs.Length - pos;
            if (size < headerLen) return false;
            if (type == "moov")
            {
                var moov = new byte[(int)Math.Min(size - headerLen, 64 << 20)];
                fs.Position = pos + headerLen;
                var got = fs.Read(moov, 0, moov.Length);
                return MvhdHasDate(moov.AsSpan(0, got));
            }
            pos += size;
        }
        return false;
    }

    static bool MvhdHasDate(ReadOnlySpan<byte> moov)
    {
        int p = 0;
        while (p + 8 <= moov.Length)
        {
            long size = (uint)((moov[p] << 24) | (moov[p + 1] << 16) | (moov[p + 2] << 8) | moov[p + 3]);
            var type = Encoding.ASCII.GetString(moov.Slice(p + 4, 4));
            if (size < 8) return false;
            if (type == "mvhd" && p + 20 <= moov.Length)
            {
                var version = moov[p + 8];
                // Seconds since 1904-01-01 (UTC).
                ulong created = version == 1 && p + 20 <= moov.Length
                    ? (ulong)moov[p + 12] << 56 | (ulong)moov[p + 13] << 48 | (ulong)moov[p + 14] << 40 | (ulong)moov[p + 15] << 32 | (ulong)moov[p + 16] << 24 | (ulong)moov[p + 17] << 16 | (ulong)moov[p + 18] << 8 | moov[p + 19]
                    : (uint)((moov[p + 12] << 24) | (moov[p + 13] << 16) | (moov[p + 14] << 8) | moov[p + 15]);
                return created > 2_082_844_800UL;                     // later than 1970-01-01
            }
            p += (int)Math.Min(size, int.MaxValue);
        }
        return false;
    }
}
