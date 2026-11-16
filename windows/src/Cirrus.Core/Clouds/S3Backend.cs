using System.Globalization;
using System.Runtime.ExceptionServices;
using System.Text;

namespace Cirrus.Core;

/// <summary>
/// An S3 bucket (AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO and other S3-compatible services), browsed like
/// iCloud Drive (port of S3Backend.swift).
///
/// IDs are <c>"s3:/" + bucket + "/" + key</c>, folders ending in "/". With a bucket in the account <see cref="RootID"/>
/// is <c>"s3:/&lt;bucket&gt;/"</c>; without one it is <c>"s3:/"</c> and lists the buckets as folders (nothing can be
/// added there). Folders are key prefixes (CommonPrefixes with delimiter "/") and zero-byte "name/" marker objects.
/// Deleted items are moved (copy, then delete) into <c>.cirrus-deleted/</c> at the top of the bucket, with the original
/// key in the object's metadata, so nothing is erased until <see cref="DeleteForeverAsync"/>.
/// </summary>
public sealed class S3Backend : ICloudDriveBackend
{
    /// <summary>Where deleted items go, at the top of each bucket (hidden from listings).</summary>
    public const string TrashPrefix = ".cirrus-deleted/";
    internal const string TrashFolderName = ".cirrus-deleted";
    /// <summary>The original key of a deleted item (percent-encoded, so it stays ASCII).</summary>
    public const string OriginalMeta = "x-amz-meta-cirrus-original";
    internal const string DeletedMeta = "x-amz-meta-cirrus-deleted";
    /// <summary>The file's modification date (seconds since 1970), written on upload.</summary>
    public const string MtimeMeta = "x-amz-meta-mtime";
    public const string FolderType = "application/x-directory";

    public CloudProvider Provider => CloudProvider.S3;
    public CloudAccountRecord Record { get; }
    public string RootID { get; }
    public bool CanListTrash => true;
    /// <summary>The bucket the account opens (null: every bucket the keys can list).</summary>
    public string? Bucket { get; }
    internal S3Client Client { get; }

    readonly object _lock = new();
    bool? _conditionalWrites;
    readonly Dictionary<string, string> _originals = new(StringComparer.Ordinal);
    long _multipartThreshold = 32L << 20;
    long _partSize = 16L << 20;
    long _maxCopySize = 5L << 30;
    long _copyPartSize = 512L << 20;
    /// <summary>Serializes changes to <c>.cirrus-deleted/</c> (unique names).</summary>
    readonly SemaphoreSlim _trashLock = new(1, 1);

    internal int Concurrency { get; set; } = 6;
    /// <summary>Files larger than this go up in parts (multipart upload).</summary>
    internal long MultipartThreshold { get { lock (_lock) return _multipartThreshold; } set { lock (_lock) _multipartThreshold = value; } }
    /// <summary>Bytes per part (at least 8 MiB in the app; tests go lower). Raised as needed to stay within 10,000 parts.</summary>
    internal long PartSize { get { lock (_lock) return _partSize; } set { lock (_lock) _partSize = value; } }
    /// <summary>Objects larger than this are copied in parts (UploadPartCopy): S3 copies at most 5 GB in one request.</summary>
    internal long MaxCopySize { get { lock (_lock) return _maxCopySize; } set { lock (_lock) _maxCopySize = value; } }
    internal long CopyPartSize { get { lock (_lock) return _copyPartSize; } set { lock (_lock) _copyPartSize = value; } }
    internal double RetryBase { get => Client.RetryBase; set => Client.RetryBase = value; }
    /// <summary>Does the service honour If-None-Match: * on writes? null until a write tells.</summary>
    internal bool? ConditionalWrites { get { lock (_lock) return _conditionalWrites; } set { lock (_lock) _conditionalWrites = value; } }

    public S3Backend(CloudAccountRecord record, string secretKey, HttpMessageHandler? transport)
    {
        if (record.Provider != CloudProvider.S3) throw CloudException.Unsupported($"{record.Provider.DisplayName()} isn’t S3 storage.");
        Record = record;
        var service = ServiceName(record);
        var server = record.Server?.Trim();
        if (string.IsNullOrEmpty(server)) throw CloudException.NotConfigured("This S3 account has no endpoint address. Remove it and add it again.");
        var (endpoint, path) = S3Endpoint.Parse(server);
        endpoint = endpoint with { BasePath = path.Length == 0 ? "" : S3Signer.Encode(path.StartsWith('/') ? path : "/" + path, slash: false) };
        var access = record.Username?.Trim();
        if (string.IsNullOrEmpty(access)) throw CloudException.NotConfigured("This S3 account has no access key ID. Remove it and add it again.");
        if (string.IsNullOrEmpty(secretKey)) throw CloudException.SignInNeeded(service);
        var b = record.Option("bucket")?.Trim();
        Bucket = string.IsNullOrEmpty(b) ? null : b;
        RootID = Bucket is null ? "s3:/" : "s3:/" + Bucket + "/";
        bool? pathStyle = record.Option("pathStyle") is { } ps ? ps.ToLowerInvariant() is "1" or "true" or "yes" : null;
        Client = new S3Client(endpoint, access, secretKey, S3Endpoint.SigningRegion(record.Option("region"), endpoint.Host), pathStyle, service, transport);
    }

    /// <summary>"S3 Storage (photos @ s3.us-west-004.backblazeb2.com)": the name errors use.</summary>
    internal static string ServiceName(CloudAccountRecord r) =>
        r.Title.Length == 0 ? CloudProvider.S3.DisplayName() : $"{CloudProvider.S3.DisplayName()} ({r.Title})";

    string Host => Client.Endpoint.Authority;

    // MARK: IDs

    internal static string Id(string bucket, string key) => "s3:/" + bucket + "/" + key;

    /// <summary>(bucket, key) of an id; bucket null for the list of buckets.</summary>
    internal (string? Bucket, string Key) Locate(string id)
    {
        if (!S3Key.HasPrefix(id, "s3:/")) throw CloudException.NotFound();
        var rest = id[4..];
        if (rest.Length == 0) return Bucket is { } mine ? (mine, "") : (null, "");
        var i = rest.IndexOf('/');
        var (b, key) = i >= 0 ? (rest[..i], rest[(i + 1)..]) : (rest, "");
        if (b.Length == 0) throw CloudException.NotFound();
        if (Bucket is { } m && !S3Key.Same(b, m)) throw CloudException.NotFound();
        return (b, key);
    }

    /// <summary>"" stays ""; "a" → "a/".</summary>
    internal static string FolderKey(string k) => k.Length == 0 || S3Key.IsFolder(k) ? k : k + "/";
    internal static bool InTrash(string k) => S3Key.HasPrefix(k, TrashPrefix);

    public static string? CleanETag(string? e)
    {
        var t = e?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        if (t.StartsWith("W/", StringComparison.Ordinal)) t = t[2..];
        if (t.Length >= 2 && t[0] == '"' && t[^1] == '"') t = t[1..^1];
        return t;
    }

    /// <summary>Whole seconds, so listings (milliseconds) and HEAD (an HTTP date) agree.</summary>
    internal static DateTimeOffset? Seconds(DateTimeOffset? d) => d is { } v ? DateTimeOffset.FromUnixTimeSeconds(v.ToUnixTimeSeconds()) : null;

    static string Nfc(string s) { try { return s.Normalize(NormalizationForm.FormC); } catch (ArgumentException) { return s; } }

    DriveNode FileNode(string b, string key, long size, DateTimeOffset? modified, string? etag) => new()
    {
        Id = Id(b, key), Zone = "s3", ParentID = Id(b, S3Key.Parent(key)), Name = Nfc(S3Key.LastSegment(key)), Type = "FILE", Size = size,
        Modified = Seconds(modified), Etag = CleanETag(etag),
    };

    DriveNode FolderNode(string b, string prefix, DateTimeOffset? modified = null) => new()
    {
        Id = Id(b, prefix), Zone = "s3", ParentID = Id(b, S3Key.Parent(prefix)), Name = Nfc(S3Key.LastSegment(prefix)), Type = "FOLDER", Size = 0,
        Modified = Seconds(modified),
    };

    string Display(string? b, string key)
    {
        if (key.Length == 0) return b ?? (Record.Title.Length == 0 ? Provider.DisplayName() : Record.Title);
        return Nfc(S3Key.LastSegment(key));
    }

    // MARK: Listing

    internal sealed record S3Object(string Key, long Size, DateTimeOffset? Modified, string? Etag);
    internal sealed class Listing { public List<S3Object> Objects { get; } = []; public List<string> Prefixes { get; } = []; }

    /// <summary>Every key under <paramref name="prefix"/> (all pages). With delimiter "/", deeper keys come back grouped as prefixes.</summary>
    internal async Task<Listing> ListAllAsync(string b, string prefix, string? delimiter, int? limit, CancellationToken ct)
    {
        var output = new Listing();
        string? token = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var urlEncoding = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var q = new List<(string, string?)> { ("list-type", "2"), ("prefix", prefix), ("max-keys", Math.Min(limit ?? 1000, 1000).ToString(CultureInfo.InvariantCulture)) };
            if (delimiter is not null) q.Add(("delimiter", delimiter));
            if (token is not null) q.Add(("continuation-token", token));
            if (urlEncoding) q.Add(("encoding-type", "url"));
            var r = await Client.SendAsync(new S3Request { Method = "GET", Bucket = b, Query = q }, ct: ct).ConfigureAwait(false);
            if (r.Status != 200) throw Failure(r, $"list “{Display(b, prefix)}”", b);
            if (S3Xml.Parse(r.Data) is not { Name: "ListBucketResult" } root)
            {
                // Keys with characters XML can't carry: ask for them URL-encoded.
                if (!urlEncoding) { urlEncoding = true; continue; }
                throw CloudException.Server($"{Host}’s listing of “{Display(b, prefix)}” was unreadable, so Cirrus didn’t show it. Try again.");
            }
            var encoded = root.Value("EncodingType")?.ToLowerInvariant() == "url";
            string Dec(string s) => encoded ? S3Signer.Decode(s.Replace('+', ' ')) ?? s : s;
            foreach (var c in root.All("Contents"))
            {
                if (c.Value("Key") is not { } rawKey) throw Unreadable(b, prefix);
                var key = Dec(rawKey);
                if (!S3Key.HasPrefix(key, prefix)) throw Unreadable(b, prefix);
                output.Objects.Add(new S3Object(key, long.TryParse(c.Value("Size")?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var size) ? size : 0,
                    S3Dates.Iso8601(c.Value("LastModified")), c.Value("ETag")));
            }
            foreach (var p in root.All("CommonPrefixes"))
            {
                if (p.Value("Prefix") is not { } raw) throw Unreadable(b, prefix);
                var k = Dec(raw);
                if (!S3Key.HasPrefix(k, prefix)) throw Unreadable(b, prefix);
                output.Prefixes.Add(k);
            }
            if (limit is int l && output.Objects.Count + output.Prefixes.Count >= l) return output;
            var truncated = root.Value("IsTruncated")?.Trim().ToLowerInvariant() == "true";
            if (!truncated) return output;
            // A listing that's cut short can't be shown as if it were whole.
            if (root.Value("NextContinuationToken") is not { Length: > 0 } next || !seen.Add(next))
                throw CloudException.Server($"{Host} cut the listing of “{Display(b, prefix)}” short without a way to continue, so Cirrus didn’t show it.");
            token = next;
        }
    }

    CloudException Unreadable(string b, string prefix) =>
        CloudException.Server($"{Host} listed “{Display(b, prefix)}” in a way Cirrus couldn’t read, so it wasn’t shown. Try again.");

    public async Task<List<DriveNode>> ListAsync(string folderID, CancellationToken ct = default)
    {
        var (b, raw) = Locate(folderID);
        if (b is null)
        {
            return (await ListBucketsAsync(ct).ConfigureAwait(false)).Select(x => new DriveNode
            {
                Id = Id(x.Name, ""), Zone = "s3", ParentID = RootID, Name = Nfc(x.Name), Type = "FOLDER", Size = 0,
                Modified = Seconds(x.Created), Created = Seconds(x.Created),
            }).ToList();
        }
        var prefix = FolderKey(raw);
        var l = await ListAllAsync(b, prefix, "/", null, ct).ConfigureAwait(false);
        var output = new List<DriveNode>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var sawSelf = false;
        foreach (var p in l.Prefixes)
        {
            if (prefix.Length == 0 && S3Key.Same(p, TrashPrefix)) continue;
            if (S3Key.LastSegment(p).Length == 0) continue;
            if (ids.Add(Id(b, p))) output.Add(FolderNode(b, p));
        }
        foreach (var o in l.Objects)
        {
            if (S3Key.Same(o.Key, prefix)) { sawSelf = true; continue; }       // the folder's own marker
            if (prefix.Length == 0 && InTrash(o.Key)) continue;                // deleted items stay out of sight
            if (S3Key.IsFolder(o.Key))                                         // a marker S3 didn't group
            {
                if (S3Key.LastSegment(o.Key).Length > 0 && ids.Add(Id(b, o.Key))) output.Add(FolderNode(b, o.Key, o.Modified));
                continue;
            }
            output.Add(FileNode(b, o.Key, o.Size, o.Modified, o.Etag));
        }
        // A folder is its keys: no marker and nothing inside means it's gone (not "empty").
        if (prefix.Length > 0 && output.Count == 0 && !sawSelf) throw CloudException.NotFound();
        var parent = Id(b, prefix);
        foreach (var n in output) n.ParentID = parent;
        return output;
    }

    internal sealed record BucketInfo(string Name, DateTimeOffset? Created);

    internal async Task<List<BucketInfo>> ListBucketsAsync(CancellationToken ct)
    {
        var output = new List<BucketInfo>();
        string? token = null;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var q = new List<(string, string?)>();
            if (token is not null) q.Add(("continuation-token", token));
            var r = await Client.SendAsync(new S3Request { Method = "GET", Query = q }, ct: ct).ConfigureAwait(false);
            if (r.Status != 200) throw Failure(r, "list the buckets");
            if (S3Xml.Parse(r.Data) is not { Name: "ListAllMyBucketsResult" } root) throw CloudException.Server($"{Host}’s list of buckets was unreadable. Try again.");
            foreach (var x in root.Child("Buckets")?.All("Bucket") ?? [])
                if (x.Value("Name") is { Length: > 0 } n) output.Add(new BucketInfo(n, S3Dates.Iso8601(x.Value("CreationDate"))));
            if (root.Value("ContinuationToken") is not { Length: > 0 } next || next == token) return output;
            token = next;
        }
    }

    public async Task<Dictionary<string, List<DriveNode>>> ListManyAsync(IReadOnlyList<string> folderIDs, CancellationToken ct = default)
    {
        var unique = folderIDs.Distinct(StringComparer.Ordinal).ToList();
        var pairs = await ConcurrentMap(unique, async (id, t) => (id, await ListAsync(id, t).ConfigureAwait(false)), ct).ConfigureAwait(false);
        var output = new Dictionary<string, List<DriveNode>>(StringComparer.Ordinal);
        foreach (var (id, items) in pairs) output.TryAdd(id, items);
        return output;
    }

    /// <summary>Runs <paramref name="op"/> on every item, at most <see cref="Concurrency"/> at a time; the first error cancels the rest.</summary>
    internal async Task<List<R>> ConcurrentMap<T, R>(IReadOnlyList<T> items, Func<T, CancellationToken, Task<R>> op, CancellationToken ct)
    {
        if (items.Count == 0) return [];
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var results = new R[items.Count];
        var next = -1;
        ExceptionDispatchInfo? first = null;
        async Task Worker()
        {
            while (true)
            {
                var i = Interlocked.Increment(ref next);
                if (i >= items.Count || cts.IsCancellationRequested) return;
                try { results[i] = await op(items[i], cts.Token).ConfigureAwait(false); }
                catch (Exception e)
                {
                    Interlocked.CompareExchange(ref first, ExceptionDispatchInfo.Capture(e), null);
                    try { cts.Cancel(); } catch (ObjectDisposedException) { }
                    return;
                }
            }
        }
        await Task.WhenAll(Enumerable.Range(0, Math.Min(Math.Max(1, Concurrency), items.Count)).Select(_ => Task.Run(Worker, CancellationToken.None))).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        first?.Throw();
        return [.. results];
    }

    Task ConcurrentForEach<T>(IReadOnlyList<T> items, Func<T, CancellationToken, Task> op, CancellationToken ct) =>
        ConcurrentMap(items, async (x, t) => { await op(x, t).ConfigureAwait(false); return true; }, ct);

    // MARK: Objects

    internal sealed record HeadInfo(long Size, DateTimeOffset? Modified, string? Etag, Dictionary<string, string> Keep, Dictionary<string, string> Meta);

    static readonly HashSet<string> KeptHeaders = ["content-type", "content-encoding", "content-disposition", "content-language", "cache-control",
        "expires", "x-amz-storage-class", "x-amz-website-redirect-location"];

    /// <summary>HEAD of one object; null when there's none.</summary>
    internal async Task<HeadInfo?> HeadAsync(string b, string key, CancellationToken ct)
    {
        var r = await Client.SendAsync(new S3Request { Method = "HEAD", Bucket = b, Key = key }, ct: ct).ConfigureAwait(false);
        if (r.Status == 404) return null;
        if (!r.Ok) throw Failure(r, $"read “{Display(b, key)}”", b);
        var keep = new Dictionary<string, string>(StringComparer.Ordinal);
        var meta = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in r.Headers)
        {
            var name = k.ToLowerInvariant();
            if (name.StartsWith("x-amz-meta-", StringComparison.Ordinal)) { meta[name] = v; keep[name] = v; }
            else if (KeptHeaders.Contains(name)) keep[name] = v;
        }
        var size = long.TryParse(r.Header("Content-Length"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s) ? s : 0;
        return new HeadInfo(size, S3Dates.Http(r.Header("Last-Modified")), CleanETag(r.Header("ETag")), keep, meta);
    }

    async Task<HeadInfo?> TryHeadAsync(string b, string key, CancellationToken ct)
    {
        try { return await HeadAsync(b, key, ct).ConfigureAwait(false); } catch (CloudException) { return null; }
    }

    /// <summary>Is there anything under <paramref name="prefix"/> ("name/")?</summary>
    async Task<bool> PrefixExistsAsync(string b, string prefix, CancellationToken ct)
    {
        var l = await ListAllAsync(b, prefix, "/", 1, ct).ConfigureAwait(false);
        return l.Objects.Count > 0 || l.Prefixes.Count > 0;
    }

    /// <summary>Is <paramref name="baseKey"/> taken, as a file ("base") or a folder ("base/…")?</summary>
    async Task<bool> TakenAsync(string b, string baseKey, CancellationToken ct)
    {
        var file = HeadAsync(b, baseKey, ct);
        var folder = PrefixExistsAsync(b, baseKey + "/", ct);
        await Task.WhenAll(file, folder).ConfigureAwait(false);
        return await file.ConfigureAwait(false) is not null || await folder.ConfigureAwait(false);
    }

    async Task EnsureFreeAsync(string b, string baseKey, CancellationToken ct)
    {
        if (await TakenAsync(b, baseKey, ct).ConfigureAwait(false)) throw NameTaken(S3Key.LastSegment(baseKey), S3Key.Parent(baseKey), b);
    }

    async Task DeleteObjectAsync(string b, string key, CancellationToken ct)
    {
        var r = await Client.SendAsync(new S3Request { Method = "DELETE", Bucket = b, Key = key }, ct: ct).ConfigureAwait(false);
        if (!r.Ok && r.Status != 404) throw Failure(r, $"delete “{Display(b, key)}”", b);
    }

    /// <summary>Keeps a folder showing after its last item leaves (S3 folders are only their keys): writes its marker.</summary>
    async Task EnsureMarkerAsync(string b, string prefix, CancellationToken ct)
    {
        if (prefix.Length == 0 || InTrash(prefix)) return;
        if (await HeadAsync(b, prefix, ct).ConfigureAwait(false) is not null) return;
        var r = await Client.SendAsync(new S3Request { Method = "PUT", Bucket = b, Key = prefix, Headers = { ["Content-Type"] = FolderType } }, ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Failure(r, $"keep the folder “{Display(b, prefix)}”", b);
    }

    /// <summary>The x-amz-copy-source value: "/bucket/key", URL-encoded.</summary>
    internal static string CopySource(string b, string key) => "/" + S3Signer.Encode(b, slash: true) + "/" + S3Signer.Encode(key, slash: false);

    /// <summary>Server-side copy. <paramref name="replace"/>: the metadata for the copy (headers as in <see cref="HeadInfo.Keep"/>); null keeps the source's.</summary>
    async Task CopyObjectAsync(string sb, string sk, string db, string dk, long size, Dictionary<string, string>? replace, CancellationToken ct)
    {
        if (size > MaxCopySize) { await MultipartCopyAsync(sb, sk, db, dk, size, replace, ct).ConfigureAwait(false); return; }
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["x-amz-copy-source"] = CopySource(sb, sk) };
        if (replace is not null)
        {
            h["x-amz-metadata-directive"] = "REPLACE";
            foreach (var (k, v) in replace) h[k] = v;
        }
        var what = $"copy “{Display(sb, sk)}”";
        var attempt = 0;
        while (true)
        {
            var r = await Client.SendAsync(new S3Request { Method = "PUT", Bucket = db, Key = dk, Headers = new(h, StringComparer.OrdinalIgnoreCase), Timeout = TimeSpan.FromSeconds(600) },
                ct: ct).ConfigureAwait(false);
            if (!r.Ok)
            {
                if (r.Status == 404 && r.Code != "NoSuchBucket") throw CloudException.NotFound();
                throw Failure(r, what, db);
            }
            // A copy can fail after "200 OK": the error is then in the body (S3 asks for a retry).
            if (S3Xml.Parse(r.Data) is not { Name: "Error" }) return;
            var e = S3ErrorBody.Parse(r.Data);
            if (Retriable(e?.Code) && attempt < Client.MaxRetries)
            {
                attempt++;
                await S3Client.PauseAsync(Client.Delay(attempt, null), ct).ConfigureAwait(false);
                continue;
            }
            throw Failure(r.AsFailure(), what, db);
        }
    }

    /// <summary>Copies an object larger than 5 GB in parts (UploadPartCopy).</summary>
    async Task MultipartCopyAsync(string sb, string sk, string db, string dk, long size, Dictionary<string, string>? metadata, CancellationToken ct)
    {
        var meta = metadata;
        if (meta is null)
        {
            var h = await HeadAsync(sb, sk, ct).ConfigureAwait(false) ?? throw CloudException.NotFound();
            meta = h.Keep;
        }
        var what = $"copy “{Display(sb, sk)}”";
        var uploadID = await CreateMultipartAsync(db, dk, meta, what, ct).ConfigureAwait(false);
        var finished = false;
        try
        {
            var part = Math.Max(CopyPartSize, (size + 9_999) / 10_000);
            var parts = new List<(int, string)>();
            long offset = 0;
            var n = 1;
            while (offset < size)
            {
                ct.ThrowIfCancellationRequested();
                var end = Math.Min(offset + part, size) - 1;
                var r = await Client.SendAsync(new S3Request
                {
                    Method = "PUT", Bucket = db, Key = dk, Query = [("partNumber", n.ToString(CultureInfo.InvariantCulture)), ("uploadId", uploadID)],
                    Headers = { ["x-amz-copy-source"] = CopySource(sb, sk), ["x-amz-copy-source-range"] = $"bytes={offset}-{end}" },
                    Timeout = TimeSpan.FromSeconds(600),
                }, ct: ct).ConfigureAwait(false);
                if (!r.Ok || S3Xml.Parse(r.Data) is not { Name: "CopyPartResult" } root || root.Value("ETag") is not { } etag)
                    throw Failure(r.Ok ? r.AsFailure() : r, what, db);
                parts.Add((n, etag));
                offset = end + 1;
                n++;
            }
            await CompleteMultipartAsync(db, dk, uploadID, parts, size, conditional: false, what, ct).ConfigureAwait(false);
            finished = true;
        }
        finally { if (!finished) AbortMultipart(db, dk, uploadID); }
    }

    // MARK: Errors

    CloudException Failure(S3Response r, string what, string? b = null)
    {
        var code = r.Code ?? "";
        var message = (r.Error?.Message ?? "").ToLowerInvariant();
        switch (code)
        {
            case "NoSuchKey" or "NoSuchUpload": return CloudException.NotFound();
            case "NoSuchBucket":
                return CloudException.NotConfigured($"There’s no bucket “{b ?? Bucket ?? ""}” at {Host} any more. Check the bucket in the account, or remove the account and add it again.");
            case "InvalidAccessKeyId": return CloudException.SignInNeeded(Client.ServiceName);
            case "SignatureDoesNotMatch":
                return CloudException.Denied($"{Host} didn’t accept the secret access key for “{Client.AccessKey}” (the signature didn’t match). "
                    + "Remove the account and add it again with the right secret key.");
            case "InvalidObjectState":
                return CloudException.Denied($"Cirrus couldn’t {what}: the item is archived (for example in Glacier) and must be restored in the service’s console first.");
            case "EntityTooLarge" or "MaxMessageLengthExceeded":
                return CloudException.Denied($"{Host} doesn’t accept an item this large in one piece.");
            case "KeyTooLongError":
                return CloudException.Denied($"The name or folder path is too long for {Host} (at most 1,024 bytes).");
            case "QuotaExceeded" or "StorageQuotaExceeded" or "ServiceQuotaExceeded" or "InsufficientStorage" or "XMinioStorageFull":
                return CloudException.QuotaExceeded(Client.ServiceName);
            case "RequestTimeTooSkewed":
                return CloudException.Server($"This device’s clock is too far off for {Host}. Set the date and time automatically in Settings, then try again.");
            case "XAmzContentSHA256Mismatch" or "BadDigest" or "IncompleteBody":
                return CloudException.Server("The file changed or was cut short while it was being uploaded. Try again.");
            case "PermanentRedirect" or "AuthorizationHeaderMalformed" or "IllegalLocationConstraintException":
                return CloudException.NotConfigured($"The bucket is in a different region than the account says ({Client.DefaultRegion}"
                    + $"{(r.Error?.Region is { } reg ? "; the service says " + reg : "")}). Remove the account and add it again with the bucket’s region.");
        }
        if (message.Contains("cap exceeded", StringComparison.Ordinal) || message.Contains("quota", StringComparison.Ordinal)) return CloudException.QuotaExceeded(Client.ServiceName);
        return r.Status switch
        {
            403 => CloudException.Denied($"{Host} didn’t allow Cirrus to {what}. The access key may not have permission for this."),
            404 or 410 => CloudException.NotFound(),
            405 or 501 => CloudException.Unsupported($"{Host} doesn’t support this (it couldn’t {what})."),
            >= 300 and < 400 => CloudException.Server($"{Host} answered with a redirect ({r.Status}) instead of doing it. Check the endpoint and region in the account."),
            _ => CloudException.Server($"{Host} couldn’t {what} ({r.Status}{(code.Length == 0 ? "" : " " + code)})."),
        };
    }

    CloudException NameTaken(string name, string folder, string b) =>
        CloudException.Denied($"There’s already an item named “{Nfc(name)}” in “{Display(b, folder)}”. Choose a different name.");

    internal static void CheckName(string name, bool top)
    {
        if (name.Length == 0 || name == "." || name == "..") throw CloudException.Denied($"“{name}” can’t be used as a name.");
        if (name.Contains('/') || name.Contains('\0')) throw CloudException.Denied("Names in S3 storage can’t contain “/”.");
        if (Encoding.UTF8.GetByteCount(name) > 1000) throw CloudException.Denied($"“{name[..Math.Min(40, name.Length)]}…” is too long a name for S3 storage.");
        if (top && name == TrashFolderName) throw CloudException.Denied($"“{name}” is where Cirrus keeps deleted items. Choose a different name.");
    }

    CloudException TopReadOnly =>
        CloudException.Unsupported($"Open a bucket first: nothing can be added next to the buckets of {(Record.Title.Length == 0 ? Host : Record.Title)}.");

    /// <summary>The bucket and folder key items can be added to.</summary>
    (string Bucket, string Folder) WritableFolder(string folderID)
    {
        var (b, raw) = Locate(folderID);
        if (b is null) throw TopReadOnly;
        var folder = FolderKey(raw);
        if (InTrash(folder)) throw CloudException.Unsupported($"Items can’t be added to {Provider.DeletedTitle()}.");
        return (b, folder);
    }

    static void CheckKey(string key)
    {
        if (Encoding.UTF8.GetByteCount(key) > 1024) throw CloudException.Denied("The name or folder path is too long for S3 storage (at most 1,024 bytes).");
    }

    // MARK: Download

    public async Task DownloadAsync(DriveNode node, string destination, Action<long, long>? progress, CancellationToken ct = default)
    {
        if (node.IsFolder) throw CloudException.Unsupported($"“{node.Name}” is a folder; download the items in it instead.");
        var (b, key) = Locate(node.Id);
        if (b is null || key.Length == 0 || S3Key.IsFolder(key)) throw CloudException.NotFound();
        var r = await Client.SendAsync(new S3Request { Method = "GET", Bucket = b, Key = key, Headers = { ["Accept-Encoding"] = "identity" }, Timeout = TimeSpan.FromSeconds(120) },
            new S3Download(destination, node.Size), progress, ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Failure(r, $"download “{node.Name}”", b);
        var size = File.Exists(destination) ? new FileInfo(destination).Length : node.Size;
        progress?.Invoke(size, Math.Max(size, node.Size));
        DateTimeOffset? mtime = double.TryParse(r.Header(MtimeMeta)?.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var secs)
            && secs is > -62_135_596_800 and < 253_402_300_799 ? DateTimeOffset.UnixEpoch.AddSeconds(secs) : null;
        if ((mtime ?? S3Dates.Http(r.Header("Last-Modified")) ?? node.Modified) is { } m && File.Exists(destination))
        {
            try { File.SetLastWriteTimeUtc(destination, m.UtcDateTime); } catch { }
        }
    }

    // MARK: Upload

    public async Task<DriveNode> UploadAsync(string file, string name, string folderID, DateTimeOffset? modified, Action<long, long>? progress, CancellationToken ct = default)
    {
        var (b, folder) = WritableFolder(folderID);
        CheckName(name, top: folder.Length == 0);
        var key = folder + name;
        CheckKey(key);
        // Never replace an existing item: replacing goes through the app's safe replace (upload, then trash the old one).
        await EnsureFreeAsync(b, key, ct).ConfigureAwait(false);
        var info = new FileInfo(file);
        var size = info.Exists ? info.Length : 0;
        var mtime = modified ?? (info.Exists ? new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero) : DateTimeOffset.UtcNow);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["Content-Type"] = Mime.ForName(name), [MtimeMeta] = mtime.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
        };
        if (size > MultipartThreshold)
        {
            await MultipartUploadAsync(file, size, b, key, headers, progress, ct).ConfigureAwait(false);
        }
        else
        {
            var d = await S3Hash.FileAsync(file, ct).ConfigureAwait(false);
            if (d.Bytes != size) throw CloudException.Server($"“{name}” changed while it was being uploaded. Try again.");
            while (true)
            {
                var cond = ConditionalWrites != false;
                if (cond) headers["If-None-Match"] = "*"; else headers.Remove("If-None-Match");
                var r = await Client.SendAsync(new S3Request
                {
                    Method = "PUT", Bucket = b, Key = key, Headers = new(headers, StringComparer.OrdinalIgnoreCase), Body = new S3Body.File(file),
                    PayloadHash = d.Sha256, Timeout = TimeSpan.FromSeconds(300),
                }, progress: progress, total: size, ct: ct).ConfigureAwait(false);
                if (r.Ok) { if (cond) ConditionalWrites = true; break; }
                if (cond && ConditionalUnsupported(r)) { ConditionalWrites = false; continue; }
                if (r.Status == 412)
                {
                    // A retried PUT can meet its own first attempt.
                    if (r.Retried && await TryHeadAsync(b, key, ct).ConfigureAwait(false) is { } h && h.Size == size && h.Etag?.ToLowerInvariant() == d.Md5) break;
                    throw NameTaken(name, folder, b);
                }
                throw Failure(r, $"upload “{name}”", b);
            }
        }
        progress?.Invoke(size, size);
        try
        {
            if (await HeadAsync(b, key, ct).ConfigureAwait(false) is { } h) return FileNode(b, key, h.Size, h.Modified, h.Etag);
        }
        catch { }   // it's uploaded: describe it from what was sent
        return FileNode(b, key, size, DateTimeOffset.UtcNow, null);
    }

    /// <summary>Services that don't do conditional writes say so with 501 NotImplemented (or a 400 naming the header).</summary>
    static bool ConditionalUnsupported(S3Response r)
    {
        if (r.Status == 501 || r.Code == "NotImplemented") return true;
        return r.Status == 400 && (r.Error?.Message ?? "").Contains("if-none-match", StringComparison.OrdinalIgnoreCase);
    }

    async Task<string> CreateMultipartAsync(string b, string key, Dictionary<string, string> headers, string what, CancellationToken ct)
    {
        var r = await Client.SendAsync(new S3Request
        {
            Method = "POST", Bucket = b, Key = key, Query = [("uploads", null)], Headers = new(headers, StringComparer.OrdinalIgnoreCase),
        }, ct: ct).ConfigureAwait(false);
        if (r.Ok && S3Xml.Parse(r.Data) is { Name: "InitiateMultipartUploadResult" } root && root.Value("UploadId") is { Length: > 0 } id) return id;
        throw Failure(r.Ok ? r.AsFailure() : r, what, b);
    }

    /// <summary>Leaves no unfinished upload behind (best effort, outside the cancelled task).</summary>
    void AbortMultipart(string b, string key, string uploadID)
    {
        var c = Client;
        _ = Task.Run(async () =>
        {
            try { await c.SendAsync(new S3Request { Method = "DELETE", Bucket = b, Key = key, Query = [("uploadId", uploadID)] }).ConfigureAwait(false); }
            catch { }
        });
    }

    async Task CompleteMultipartAsync(string b, string key, string uploadID, List<(int N, string ETag)> parts, long size, bool conditional, string what, CancellationToken ct)
    {
        var xml = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">");
        foreach (var (n, etag) in parts) xml.Append(CultureInfo.InvariantCulture, $"<Part><PartNumber>{n}</PartNumber><ETag>{S3Xml.Escape(etag)}</ETag></Part>");
        xml.Append("</CompleteMultipartUpload>");
        var body = Encoding.UTF8.GetBytes(xml.ToString());
        var attempt = 0;
        while (true)
        {
            var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/xml" };
            var cond = conditional && ConditionalWrites != false;
            if (cond) h["If-None-Match"] = "*";
            // Putting a big file together can take the service a while.
            var r = await Client.SendAsync(new S3Request
            {
                Method = "POST", Bucket = b, Key = key, Query = [("uploadId", uploadID)], Headers = h, Body = new S3Body.Bytes(body),
                PayloadHash = S3Signer.Sha256Hex(body), Timeout = TimeSpan.FromMinutes(30),
            }, ct: ct).ConfigureAwait(false);
            if (r.Ok)
            {
                // CompleteMultipartUpload can fail after "200 OK": the error is then in the body.
                if (S3Xml.Parse(r.Data) is { Name: "Error" })
                {
                    var e = S3ErrorBody.Parse(r.Data);
                    if (Retriable(e?.Code) && attempt < Client.MaxRetries)
                    {
                        attempt++;
                        await S3Client.PauseAsync(Client.Delay(attempt, null), ct).ConfigureAwait(false);
                        continue;
                    }
                    throw Failure(r.AsFailure(), what, b);
                }
                if (cond) ConditionalWrites = true;
                return;
            }
            if (cond && ConditionalUnsupported(r)) { ConditionalWrites = false; continue; }
            if (r.Status == 412) throw NameTaken(S3Key.LastSegment(key), S3Key.Parent(key), b);
            // The answer to a first attempt got lost: if the object is there at its full size, it worked.
            if (r.Code == "NoSuchUpload" && r.Retried && await TryHeadAsync(b, key, ct).ConfigureAwait(false) is { } hh && hh.Size == size) return;
            throw Failure(r, what, b);
        }
    }

    static bool Retriable(string? code) => code is not null && S3Client.RetryCodes.Contains(code);

    /// <summary>
    /// CreateMultipartUpload, parts streamed from the file (each hashed and signed), CompleteMultipartUpload; the upload
    /// is aborted on any failure or cancellation.
    /// </summary>
    async Task MultipartUploadAsync(string file, long size, string b, string key, Dictionary<string, string> headers, Action<long, long>? progress, CancellationToken ct)
    {
        var name = S3Key.LastSegment(key);
        var what = $"upload “{name}”";
        var uploadID = await CreateMultipartAsync(b, key, headers, what, ct).ConfigureAwait(false);
        var finished = false;
        try
        {
            // At most 10,000 parts.
            var part = Math.Max(PartSize, (size + 9_999) / 10_000);
            await using var fh = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
            var parts = new List<(int, string)>();
            long offset = 0;
            var n = 1;
            while (offset < size)
            {
                ct.ThrowIfCancellationRequested();
                var len = Math.Min(part, size - offset);
                var (tmp, d) = await S3Hash.SliceAsync(fh, offset, len, ct).ConfigureAwait(false);
                try
                {
                    if (d.Bytes != len) throw CloudException.Server($"“{name}” changed while it was being uploaded. Try again.");
                    var done = offset;
                    var r = await Client.SendAsync(new S3Request
                    {
                        Method = "PUT", Bucket = b, Key = key, Query = [("partNumber", n.ToString(CultureInfo.InvariantCulture)), ("uploadId", uploadID)],
                        Body = new S3Body.File(tmp), PayloadHash = d.Sha256, Timeout = TimeSpan.FromSeconds(600),
                    }, progress: (sent, _) => progress?.Invoke(done + sent, size), total: len, ct: ct).ConfigureAwait(false);
                    if (!r.Ok || r.Header("ETag") is not { Length: > 0 } etag) throw Failure(r, what, b);
                    parts.Add((n, etag));
                }
                finally { S3Hash.RemoveTemp(tmp); }
                offset += len;
                n++;
                progress?.Invoke(offset, size);
            }
            ct.ThrowIfCancellationRequested();
            await CompleteMultipartAsync(b, key, uploadID, parts, size, conditional: true, what, ct).ConfigureAwait(false);
            finished = true;
        }
        finally { if (!finished) AbortMultipart(b, key, uploadID); }
    }

    // MARK: Folders

    public async Task<DriveNode> CreateFolderAsync(string name, string folderID, CancellationToken ct = default)
    {
        var (b, folder) = WritableFolder(folderID);
        CheckName(name, top: folder.Length == 0);
        var key = folder + name + "/";
        CheckKey(key);
        await EnsureFreeAsync(b, folder + name, ct).ConfigureAwait(false);
        while (true)
        {
            var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = FolderType };
            var cond = ConditionalWrites != false;
            if (cond) h["If-None-Match"] = "*";
            var r = await Client.SendAsync(new S3Request { Method = "PUT", Bucket = b, Key = key, Headers = h }, ct: ct).ConfigureAwait(false);
            if (r.Ok) { if (cond) ConditionalWrites = true; break; }
            if (cond && ConditionalUnsupported(r)) { ConditionalWrites = false; continue; }
            if (r.Status == 412)
            {
                if (r.Retried) break;   // our own first attempt
                throw NameTaken(name, folder, b);
            }
            throw Failure(r, $"make the folder “{name}”", b);
        }
        return FolderNode(b, key, DateTimeOffset.UtcNow);
    }

    // MARK: Rename and move

    /// <summary>Copies one object, then deletes the original (only once the copy is there).</summary>
    async Task MoveObjectAsync(string sb, string sk, string db, string dk, long size, bool keepParent, CancellationToken ct)
    {
        await CopyObjectAsync(sb, sk, db, dk, size, null, ct).ConfigureAwait(false);
        if (keepParent) await EnsureMarkerAsync(sb, S3Key.Parent(sk), ct).ConfigureAwait(false);
        await DeleteObjectAsync(sb, sk, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Copies every key under a prefix to another prefix; deletes the originals only when every copy worked (a failed
    /// copy removes the copies made so far and leaves the originals as they were).
    /// </summary>
    async Task MovePrefixAsync(string sb, string sp, string db, string dp, bool keepParent, (string Key, Dictionary<string, string> Headers)? marker,
        bool skipSourceMarker, CancellationToken ct)
    {
        var all = await ListAllAsync(sb, sp, null, null, ct).ConfigureAwait(false);
        if (all.Objects.Count == 0) throw CloudException.NotFound();
        var objects = all.Objects.Where(o => !(skipSourceMarker && S3Key.Same(o.Key, sp))).ToList();
        try
        {
            if (marker is { } m)
            {
                var r = await Client.SendAsync(new S3Request { Method = "PUT", Bucket = db, Key = m.Key, Headers = new(m.Headers, StringComparer.OrdinalIgnoreCase) },
                    ct: ct).ConfigureAwait(false);
                if (!r.Ok) throw Failure(r, $"move “{Display(sb, sp)}”", db);
            }
            await ConcurrentForEach(objects, (o, t) => CopyObjectAsync(sb, o.Key, db, dp + S3Key.DropPrefix(o.Key, sp), o.Size, null, t), ct).ConfigureAwait(false);
        }
        catch
        {
            // Leave things as they were: remove every copy (the destination was checked to be free; the originals were
            // never touched). Copies cut off mid-way may still have landed, so all of them, not only the finished.
            var undo = objects.Select(o => dp + S3Key.DropPrefix(o.Key, sp)).ToList();
            if (marker is { } mk) undo.Add(mk.Key);
            var c = Client;
            _ = Task.Run(async () =>
            {
                foreach (var k in undo)
                {
                    try { await c.SendAsync(new S3Request { Method = "DELETE", Bucket = db, Key = k }).ConfigureAwait(false); } catch { }
                }
            });
            throw;
        }
        if (keepParent) await EnsureMarkerAsync(sb, S3Key.Parent(sp), ct).ConfigureAwait(false);
        try
        {
            await ConcurrentForEach(all.Objects, (o, t) => DeleteObjectAsync(sb, o.Key, t), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e)
        {
            throw CloudException.Server($"“{Display(sb, sp)}” was copied, but some of the originals couldn’t be removed ({e.Message}). Both copies are kept.");
        }
    }

    public async Task<DriveNode> RenameAsync(DriveNode node, string name, CancellationToken ct = default)
    {
        var (b, key) = Locate(node.Id);
        if (b is null || key.Length == 0 || InTrash(key)) throw CloudException.Unsupported($"“{node.Name}” can’t be renamed.");
        var folder = S3Key.Parent(key);
        CheckName(name, top: folder.Length == 0);
        var isFolder = node.IsFolder || S3Key.IsFolder(key);
        var baseKey = folder + name;
        var newKey = baseKey + (isFolder ? "/" : "");
        if (S3Key.Same(newKey, key)) return node;
        CheckKey(newKey);
        await EnsureFreeAsync(b, baseKey, ct).ConfigureAwait(false);
        if (isFolder)
        {
            await MovePrefixAsync(b, FolderKey(key), b, newKey, keepParent: false, marker: null, skipSourceMarker: false, ct).ConfigureAwait(false);
            return FolderNode(b, newKey, node.Modified);
        }
        var size = (await HeadAsync(b, key, ct).ConfigureAwait(false))?.Size ?? node.Size;
        await MoveObjectAsync(b, key, b, newKey, size, keepParent: false, ct).ConfigureAwait(false);
        if (await TryHeadAsync(b, newKey, ct).ConfigureAwait(false) is { } h) return FileNode(b, newKey, h.Size, h.Modified, h.Etag);
        var n = node.Copy();
        n.Id = Id(b, newKey);
        n.Name = Nfc(name);
        n.ParentID = Id(b, folder);
        return n;
    }

    public async Task MoveAsync(IReadOnlyList<DriveNode> nodes, string folderID, CancellationToken ct = default)
    {
        var (db, raw) = Locate(folderID);
        if (db is null) throw TopReadOnly;
        var dest = FolderKey(raw);
        if (InTrash(dest)) throw CloudException.Unsupported($"Use Delete to put items in {Provider.DeletedTitle()}.");
        foreach (var n in nodes)
        {
            ct.ThrowIfCancellationRequested();
            var (sb, key) = Locate(n.Id);
            if (sb is null || key.Length == 0 || InTrash(key)) throw CloudException.Unsupported($"“{n.Name}” can’t be moved.");
            if (S3Key.Same(sb, db) && S3Key.Same(S3Key.Parent(key), dest)) continue;
            var isFolder = n.IsFolder || S3Key.IsFolder(key);
            var seg = S3Key.LastSegment(key);
            if (isFolder && S3Key.Same(sb, db) && S3Key.HasPrefix(dest, FolderKey(key))) throw CloudException.Denied($"“{n.Name}” can’t be moved into itself.");
            if (dest.Length == 0 && seg == TrashFolderName) throw CloudException.Denied($"“{seg}” can’t be moved to the top of the bucket.");
            var baseKey = dest + seg;
            CheckKey(baseKey + "/");
            await EnsureFreeAsync(db, baseKey, ct).ConfigureAwait(false);
            if (isFolder) await MovePrefixAsync(sb, FolderKey(key), db, baseKey + "/", keepParent: true, marker: null, skipSourceMarker: false, ct).ConfigureAwait(false);
            else
            {
                var size = (await HeadAsync(sb, key, ct).ConfigureAwait(false))?.Size ?? n.Size;
                await MoveObjectAsync(sb, key, db, baseKey, size, keepParent: true, ct).ConfigureAwait(false);
            }
        }
    }

    // MARK: Trash (.cirrus-deleted/)

    /// <summary>"Report.txt", 2 → "Report 2.txt"; folders and names without an extension get " 2" at the end.</summary>
    internal static string Numbered(string name, int n, bool folder)
    {
        var dot = name.LastIndexOf('.');
        if (folder || dot <= 0 || dot == name.Length - 1) return $"{name} {n}";
        return $"{name[..dot]} {n}{name[dot..]}";
    }

    /// <summary>The headers to put on a copy whose metadata changes: what the original had, minus Cirrus's trash notes.</summary>
    static Dictionary<string, string> Carried(HeadInfo h) =>
        h.Keep.Where(kv => kv.Key != OriginalMeta && kv.Key != DeletedMeta).ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.OrdinalIgnoreCase);

    static Dictionary<string, string> TrashNote(string originalKey) => new(StringComparer.OrdinalIgnoreCase)
    {
        [OriginalMeta] = S3Signer.Encode(originalKey, slash: false),
        [DeletedMeta] = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
    };

    public async Task TrashAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        if (nodes.Count == 0) return;
        var byBucket = new Dictionary<string, List<(DriveNode Node, string Key)>>(StringComparer.Ordinal);
        var order = new List<string>();
        foreach (var n in nodes)
        {
            var (b, key) = Locate(n.Id);
            if (b is null || key.Length == 0) throw CloudException.Unsupported($"“{n.Name}” can’t be deleted from Cirrus.");
            if (InTrash(key)) throw CloudException.Unsupported($"“{n.Name}” is already in {Provider.DeletedTitle()}.");
            if (!byBucket.TryGetValue(b, out var list)) { byBucket[b] = list = []; order.Add(b); }
            list.Add((n, key));
        }
        await _trashLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            foreach (var b in order)
            {
                var current = await ListAllAsync(b, TrashPrefix, "/", null, ct).ConfigureAwait(false);
                var taken = current.Objects.Select(o => o.Key).Concat(current.Prefixes).Select(S3Key.LastSegment).ToHashSet(StringComparer.Ordinal);
                foreach (var (n, key) in byBucket[b])
                {
                    ct.ThrowIfCancellationRequested();
                    var isFolder = n.IsFolder || S3Key.IsFolder(key);
                    var seg = S3Key.LastSegment(key);
                    var candidate = seg;
                    var k = 2;
                    while (taken.Contains(candidate)) candidate = Numbered(seg, k++, isFolder);
                    try
                    {
                        if (isFolder)
                        {
                            var prefix = FolderKey(key);
                            var mh = TrashNote(prefix);
                            mh["Content-Type"] = FolderType;
                            await MovePrefixAsync(b, prefix, b, TrashPrefix + candidate + "/", keepParent: true, marker: (TrashPrefix + candidate + "/", mh),
                                skipSourceMarker: true, ct).ConfigureAwait(false);
                        }
                        else
                        {
                            if (await HeadAsync(b, key, ct).ConfigureAwait(false) is not { } h) continue;   // already gone
                            var meta = Carried(h);
                            foreach (var (mk, mv) in TrashNote(key)) meta[mk] = mv;
                            await CopyObjectAsync(b, key, b, TrashPrefix + candidate, h.Size, meta, ct).ConfigureAwait(false);
                            await EnsureMarkerAsync(b, S3Key.Parent(key), ct).ConfigureAwait(false);
                            await DeleteObjectAsync(b, key, ct).ConfigureAwait(false);
                        }
                    }
                    catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { continue; }   // already gone
                    taken.Add(candidate);
                }
            }
        }
        finally { _trashLock.Release(); }
    }

    /// <summary>The original key a deleted item came from (null: unknown, e.g. put there by another app).</summary>
    async Task<string?> OriginalKeyAsync(string b, string trashKey, string? etag, DateTimeOffset? modified, CancellationToken ct)
    {
        var cacheKey = Id(b, trashKey) + "|" + (etag ?? "") + "|" + (modified?.ToUnixTimeMilliseconds() ?? 0).ToString(CultureInfo.InvariantCulture);
        lock (_lock) if (_originals.TryGetValue(cacheKey, out var v)) return v.Length == 0 ? null : v;
        var h = await HeadAsync(b, trashKey, ct).ConfigureAwait(false);
        var value = h?.Meta.GetValueOrDefault(OriginalMeta) is { } enc ? S3Signer.Decode(enc) ?? "" : "";
        lock (_lock)
        {
            if (_originals.Count > 20_000) _originals.Clear();
            _originals[cacheKey] = value;
        }
        return value.Length == 0 ? null : value;
    }

    public async Task<List<DriveNode>> ListTrashAsync(CancellationToken ct = default)
    {
        List<string> buckets = Bucket is { } mine ? [mine] : (await ListBucketsAsync(ct).ConfigureAwait(false)).Select(x => x.Name).ToList();
        var perBucket = await ConcurrentMap<string, List<DriveNode>>(buckets, async (b, t) =>
        {
            try { return await TrashEntriesAsync(b, t).ConfigureAwait(false); }
            // Without a bucket in the account, skip buckets these keys can't read.
            catch (CloudException e) when (Bucket is null && e.Kind is CloudErrorKind.Denied or CloudErrorKind.NotConfigured) { return []; }
        }, ct).ConfigureAwait(false);
        return perBucket.SelectMany(x => x).ToList();
    }

    async Task<List<DriveNode>> TrashEntriesAsync(string b, CancellationToken ct)
    {
        var l = await ListAllAsync(b, TrashPrefix, "/", null, ct).ConfigureAwait(false);
        var entries = new List<(string Key, bool Folder, long Size, DateTimeOffset? Modified, string? Etag)>();
        foreach (var p in l.Prefixes) if (S3Key.LastSegment(p).Length > 0) entries.Add((p, true, 0, null, null));
        foreach (var o in l.Objects)
            if (!S3Key.Same(o.Key, TrashPrefix) && S3Key.LastSegment(o.Key).Length > 0) entries.Add((o.Key, S3Key.IsFolder(o.Key), o.Size, o.Modified, o.Etag));
        return await ConcurrentMap(entries, async (e, t) =>
        {
            var original = await OriginalKeyAsync(b, e.Key, e.Etag, e.Modified, t).ConfigureAwait(false);
            var n = e.Folder ? FolderNode(b, e.Key, e.Modified) : FileNode(b, e.Key, e.Size, e.Modified, e.Etag);
            if (original is not null && S3Key.LastSegment(original).Length > 0) n.Name = Nfc(S3Key.LastSegment(original));
            n.ParentID = CloudConventions.TrashParent;
            return n;
        }, ct).ConfigureAwait(false);
    }

    /// <summary>Items directly inside <c>.cirrus-deleted/</c> (node, bucket, key). Anything else is refused.</summary>
    List<(DriveNode Node, string Bucket, string Key)> TrashItems(IReadOnlyList<DriveNode> nodes, string what) => nodes.Select(n =>
    {
        var (b, key) = Locate(n.Id);
        if (b is null || !InTrash(key) || S3Key.Same(key, TrashPrefix) || !S3Key.Same(S3Key.Parent(key), TrashPrefix))
            throw CloudException.Unsupported($"“{n.Name}” isn’t in {Provider.DeletedTitle()}, so it can’t be {what}.");
        return (n, b, key);
    }).ToList();

    public async Task RestoreAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        var items = TrashItems(nodes, "recovered");
        await _trashLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            Exception? failure = null;
            foreach (var (n, b, key) in items)
            {
                try
                {
                    ct.ThrowIfCancellationRequested();
                    var isFolder = n.IsFolder || S3Key.IsFolder(key);
                    var h = await HeadAsync(b, key, ct).ConfigureAwait(false);
                    if (!isFolder && h is null) throw CloudException.NotFound();
                    var original = h?.Meta.GetValueOrDefault(OriginalMeta) is { } enc ? S3Signer.Decode(enc) ?? "" : "";
                    if (S3Key.IsFolder(original)) original = original[..^1];
                    // Unknown or odd origin: put it back at the top of the bucket under its name in the trash.
                    if (original.Length == 0 || InTrash(original)) original = S3Key.LastSegment(key);
                    var folder = S3Key.Parent(original);
                    var name = S3Key.LastSegment(original);
                    var candidate = name;
                    var k = 2;
                    // Something new has the name meanwhile: keep both, like Explorer ("Report 2.txt").
                    while (await TakenAsync(b, folder + candidate, ct).ConfigureAwait(false))
                    {
                        if (k >= 500) throw NameTaken(name, folder, b);
                        candidate = Numbered(name, k++, isFolder);
                    }
                    var dest = folder + candidate;
                    if (isFolder)
                    {
                        await MovePrefixAsync(b, key, b, dest + "/", keepParent: false,
                            marker: (dest + "/", new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = FolderType }),
                            skipSourceMarker: true, ct).ConfigureAwait(false);
                    }
                    else if (h is not null)
                    {
                        await CopyObjectAsync(b, key, b, dest, h.Size, Carried(h), ct).ConfigureAwait(false);
                        await DeleteObjectAsync(b, key, ct).ConfigureAwait(false);
                    }
                }
                catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { failure ??= e; }
                catch (Exception e) { failure = e; break; }
            }
            if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
        }
        finally { _trashLock.Release(); }
    }

    public async Task DeleteForeverAsync(IReadOnlyList<DriveNode> nodes, CancellationToken ct = default)
    {
        DriveBackendExtensions.GuardTrashOnly(nodes);
        var items = TrashItems(nodes, "deleted");
        await _trashLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            foreach (var (n, b, key) in items)
            {
                ct.ThrowIfCancellationRequested();
                if (n.IsFolder || S3Key.IsFolder(key))
                {
                    var all = await ListAllAsync(b, FolderKey(key), null, null, ct).ConfigureAwait(false);
                    await ConcurrentForEach(all.Objects, (o, t) => DeleteObjectAsync(b, o.Key, t), ct).ConfigureAwait(false);
                }
                else await DeleteObjectAsync(b, key, ct).ConfigureAwait(false);
            }
        }
        finally { _trashLock.Release(); }
    }

    // MARK: Quota, thumbnails, validation

    /// <summary>S3 has no account quota to show.</summary>
    public Task<StorageUsage?> QuotaAsync(CancellationToken ct = default) => Task.FromResult<StorageUsage?>(null);
    /// <summary>S3 makes no thumbnails.</summary>
    public Task<byte[]?> ThumbnailAsync(DriveNode node, int maxPixel, CancellationToken ct = default) => Task.FromResult<byte[]?>(null);

    /// <summary>Checks the keys against the bucket (ListObjectsV2, one key) or the account (ListBuckets).</summary>
    internal async Task ValidateAsync(CancellationToken ct)
    {
        if (Bucket is { } b)
        {
            var r = await Client.SendAsync(new S3Request { Method = "GET", Bucket = b, Query = [("list-type", "2"), ("max-keys", "1")] }, ct: ct).ConfigureAwait(false);
            if (r.Status != 200) throw ConnectFailure(r);
            if (S3Xml.Parse(r.Data)?.Name != "ListBucketResult") throw CloudException.NotConfigured($"{Host} answered, but not like an S3 service. Check the endpoint address.");
        }
        else
        {
            var r = await Client.SendAsync(new S3Request { Method = "GET" }, ct: ct).ConfigureAwait(false);
            if (r.Status != 200) throw ConnectFailure(r);
            if (S3Xml.Parse(r.Data)?.Name != "ListAllMyBucketsResult") throw CloudException.NotConfigured($"{Host} answered, but not like an S3 service. Check the endpoint address.");
        }
    }

    CloudException ConnectFailure(S3Response r)
    {
        switch (r.Code ?? "")
        {
            case "InvalidAccessKeyId":
                return CloudException.Denied($"{Host} doesn’t know the access key ID “{Client.AccessKey}”. Check that it’s copied in full and belongs to this service and region.");
            case "SignatureDoesNotMatch":
                return CloudException.Denied("The secret access key doesn’t match the access key ID. Check that the secret key is copied in full, with nothing added.");
            case "AccessDenied" or "AllAccessDisabled":
                if (Bucket is { } b) return CloudException.Denied($"These keys aren’t allowed to list the bucket “{b}”. Give the key read and write access to it, then try again.");
                return CloudException.Denied("These keys can’t list the account’s buckets. Enter the name of the bucket to open.");
            case "NoSuchBucket":
                return CloudException.NotConfigured($"There’s no bucket named “{Bucket ?? ""}” at {Host}. Check the name (bucket names are case-sensitive).");
            case "AuthorizationHeaderMalformed" or "PermanentRedirect" or "IllegalLocationConstraintException":
                return CloudException.NotConfigured($"{Host} expects a different region{(r.Error?.Region is { } reg ? " (" + reg + ")" : "")}. Check the region.");
        }
        return r.Status switch
        {
            403 => CloudException.Denied($"{Host} refused these keys. Check the access key ID and secret access key."),
            404 => Bucket is null ? CloudException.NotConfigured($"{Host} isn’t an S3 endpoint. Check the address.")
                                  : CloudException.NotConfigured($"There’s no bucket named “{Bucket}” at {Host}. Check the name."),
            301 or 307 => CloudException.NotConfigured("The bucket is in a different region. Enter the bucket’s region and try again."),
            _ => Failure(r, Bucket is null ? "list the buckets" : "open the bucket"),
        };
    }
}
