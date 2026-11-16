using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cirrus.Core;

namespace Cirrus.Fakes;

/// <summary>
/// A stateful stand-in for S3-compatible services, served as an HttpMessageHandler (port of FakeS3Server.swift): AWS
/// (virtual-hosted and path-style, buckets in several regions), Backblaze B2, Cloudflare R2 (region "auto"), Wasabi, a
/// MinIO on 127.0.0.1:9000 and the demo endpoint. Unit tests use it as the mock server; Debug builds in demo mode use it
/// for the demo S3 account. It is strict, so it catches client mistakes: it verifies every SigV4 signature with the
/// known secret (canonical URI from the decoded key, canonical query, signed headers incl. every x-amz-* header, body
/// hash, region, 15-minute clock window), answers S3's XML errors, pages ListObjectsV2 (small pages on request), checks
/// multipart uploads (part numbers, ETags, order, minimum part size), copies (size limit, metadata directive) and
/// conditional writes per service, and can inject SlowDown, 500s, dropped connections and failing parts. An unknown host
/// fails as "no such host", so nothing ever reaches the network. Never part of a Release build.
/// </summary>
public sealed class FakeS3Server : HttpMessageHandler, IFakeCloud
{
    public enum Flavor { Aws, B2, R2, Wasabi, Minio, Generic }
    /// <summary>How a service treats If-None-Match: * on writes.</summary>
    public enum Conditional { Supported, NotImplemented, Ignored }

    /// <summary>One service. <paramref name="Region"/> is what requests are signed for ("auto" for R2, which also takes us-east-1 and "").</summary>
    public sealed record Endpoint(string Host, int? Port, Flavor Flavor, string Region, Conditional Conditional = Conditional.Supported, bool VirtualHosted = true);

    public sealed class StoredObject
    {
        public string Key { get; set; } = "";
        public byte[] Data { get; set; } = [];
        public string ContentType { get; set; } = "binary/octet-stream";
        /// <summary>"x-amz-meta-…" (lower-cased) → value.</summary>
        public Dictionary<string, string> Meta { get; set; } = [];
        /// <summary>Other kept headers (content-encoding, cache-control…), lower-cased.</summary>
        public Dictionary<string, string> Extra { get; set; } = [];
        public DateTimeOffset Modified { get; set; }
        public string Etag { get; set; } = "";
        public string? StorageClass { get; set; }
        public StoredObject Clone() => new()
        {
            Key = Key, Data = Data, ContentType = ContentType, Meta = new(Meta), Extra = new(Extra), Modified = Modified, Etag = Etag, StorageClass = StorageClass,
        };
    }

    public sealed class Bucket
    {
        public string Region { get; set; } = "us-east-1";
        public DateTimeOffset Created { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        /// <summary>Keyed by the exact key (ordinal, so keys stay byte-exact).</summary>
        public Dictionary<string, StoredObject> Objects { get; set; } = new(StringComparer.Ordinal);
        public StoredObject? Object(string key) => Objects.GetValueOrDefault(key);
        /// <summary>Every key in S3's order (UTF-8 bytes).</summary>
        public List<string> Keys => Objects.Keys.OrderBy(k => k, Comparer<string>.Create(S3Key.Compare)).ToList();
    }

    public sealed record Credential(string Secret, bool CanListBuckets = true, HashSet<string>? Buckets = null);

    internal sealed record Part(byte[] Data, string Etag);
    internal sealed class Upload
    {
        public string Bucket = "", Key = "", ContentType = "";
        public Dictionary<string, string> Meta = [];
        public Dictionary<int, Part> Parts = [];
    }

    public const string AccessKey = "AKIAFAKES3EXAMPLE001";
    public const string SecretKey = "fakeS3/secret+Key/wJalrXUtnFEMI0000000000";

    public const string DemoHost = "s3.example.com";
    public const string DemoBucket = "demo-files";
    public const string DemoAccessKey = "DEMOAKIAEXAMPLE00001";
    public const string DemoSecret = "demo/secret+key/for/the/cirrus/fake/s3";

    /// <summary>Everything the server knows. Tests read and tweak it between steps (through <see cref="Update"/> and <see cref="Read"/>).</summary>
    public sealed class State
    {
        public List<Endpoint> Endpoints =
        [
            new("s3.us-east-1.amazonaws.com", null, Flavor.Aws, "us-east-1"),
            new("s3.eu-west-1.amazonaws.com", null, Flavor.Aws, "eu-west-1"),
            new("s3.amazonaws.com", null, Flavor.Aws, "us-east-1"),
            new("s3.us-west-004.backblazeb2.com", null, Flavor.B2, "us-west-004", Conditional.NotImplemented),
            new("fakeaccount0123.r2.cloudflarestorage.com", null, Flavor.R2, "auto", VirtualHosted: false),
            new("s3.eu-central-1.wasabisys.com", null, Flavor.Wasabi, "eu-central-1", Conditional.Ignored),
            new("127.0.0.1", 9000, Flavor.Minio, "us-east-1", VirtualHosted: false),
            new(DemoHost, null, Flavor.Generic, "us-east-1", VirtualHosted: false),
        ];
        public Dictionary<string, Credential> Credentials = new(StringComparer.Ordinal) { [AccessKey] = new Credential(SecretKey) };
        public Dictionary<string, Bucket> Buckets = new(StringComparer.Ordinal);
        /// <summary>Most entries one ListObjectsV2 page returns.</summary>
        public int PageSize = 1000;
        /// <summary>Smallest part of a multipart upload, except the last one.</summary>
        public long MinPartSize = 5 << 20;
        public long MaxPutSize = 5L << 30;
        public long MaxCopySize = 5L << 30;
        /// <summary>The server's clock runs this many seconds ahead of the device's.</summary>
        public double Skew;
        /// <summary>Seconds each answer takes.</summary>
        public double Latency;
        // Fault injection
        public int SlowDownNext, InternalErrorNext, DropNext;
        /// <summary>Part number → how many more times uploading it answers 500 InternalError.</summary>
        public Dictionary<int, int> FailParts = [];
        /// <summary>Part numbers always refused (403 AccessDenied).</summary>
        public HashSet<int> ForbiddenParts = [];
        /// <summary>Copies from these source keys fail with an error inside a 200 answer (as S3 can).</summary>
        public HashSet<string> FailCopiesIn200 = new(StringComparer.Ordinal);
        /// <summary>Listings of these prefixes come back cut off mid-XML.</summary>
        public HashSet<string> TruncateListings = new(StringComparer.Ordinal);
        /// <summary>Listings of these prefixes say "truncated" but give no continuation token.</summary>
        public HashSet<string> TokenlessListings = new(StringComparer.Ordinal);
        /// <summary>Keys that exist but that HEAD and listings don't show yet (another device writing at the same moment).</summary>
        public HashSet<string> GhostKeys = new(StringComparer.Ordinal);
        // Statistics for tests
        public List<string> Calls = [];
        public int SignatureFailures, SkewRejections, RegionRejections, Aborted, Completed, PartPuts, Copies, ListRequests;
        public string? LastUserAgent;
        /// <summary>The host of every request, in order.</summary>
        public List<string> Hosts = [];
        internal Dictionary<string, Upload> Uploads = new(StringComparer.Ordinal);
        public int OpenUploads => Uploads.Count;

        public StoredObject? Object(string bucket, string key) => Buckets.GetValueOrDefault(bucket)?.Object(key);

        /// <summary>Adds an object (a key ending in "/" is a zero-byte folder marker).</summary>
        public void Put(string bucket, string key, byte[]? data = null, string? contentType = null, Dictionary<string, string>? meta = null,
            DateTimeOffset? modified = null, string? storageClass = null)
        {
            AddBucket(bucket);
            data ??= [];
            Buckets[bucket].Objects[key] = new StoredObject
            {
                Key = key, Data = data, ContentType = contentType ?? (S3Key.IsFolder(key) ? S3Backend.FolderType : Mime(key)), Meta = meta ?? [],
                Modified = modified ?? DateTimeOffset.FromUnixTimeSeconds(1_790_000_000), Etag = Md5(data), StorageClass = storageClass,
            };
        }

        public void AddBucket(string name, string region = "us-east-1")
        {
            if (!Buckets.ContainsKey(name)) Buckets[name] = new Bucket { Region = region };
        }

        public static State Seeded()
        {
            var s = new State();
            Seed(s);
            return s;
        }
    }

    readonly object _lock = new();
    State _state;
    string? _persistPath;

    public FakeS3Server(State? s = null) { _state = s ?? new State(); }

    /// <summary>The live state (read it when no request is in flight; change it through <see cref="Update"/>).</summary>
    public State S { get { lock (_lock) return _state; } }
    public void Reset(State? s = null) { lock (_lock) _state = s ?? new State(); }
    public void Update(Action<State> f) { lock (_lock) f(_state); }
    /// <summary>A consistent look at the state while requests may be in flight.</summary>
    public T Read<T>(Func<State, T> f) { lock (_lock) return f(_state); }

    // MARK: Demo

    /// <summary>
    /// Demo mode: the seeded bucket, with a little latency (none with CIRRUS_DEMO_FAST). With <paramref name="storageDir"/>,
    /// the buckets are kept on disk there, so files added in the demo are still there next time.
    /// </summary>
    public static FakeS3Server Demo(string? storageDir = null)
    {
        var s = State.Seeded();
        s.Latency = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CIRRUS_DEMO_FAST")) ? 0.02 : 0;
        s.Credentials[DemoAccessKey] = new Credential(DemoSecret);
        var fake = new FakeS3Server(s);
        if (storageDir is not null)
        {
            Directory.CreateDirectory(storageDir);
            fake._persistPath = Path.Combine(storageDir, "s3-state-v1.json");
            try
            {
                if (File.Exists(fake._persistPath) && JsonSerializer.Deserialize<Dictionary<string, Bucket>>(File.ReadAllBytes(fake._persistPath)) is { } saved
                    && saved.ContainsKey(DemoBucket))
                {
                    foreach (var b in saved.Values) b.Objects = new Dictionary<string, StoredObject>(b.Objects, StringComparer.Ordinal);
                    s.Buckets = new Dictionary<string, Bucket>(saved, StringComparer.Ordinal);
                }
            }
            catch { }
        }
        return fake;
    }

    /// <summary>The demo account: the seeded bucket on the demo endpoint, with a key this server accepts.</summary>
    public IReadOnlyList<CloudConnection> DemoAccounts()
    {
        var record = new CloudAccountRecord(CloudProvider.S3, $"{DemoBucket} @ {DemoHost}", "https://" + DemoHost, DemoAccessKey,
            new Dictionary<string, string> { ["region"] = "us-east-1", ["bucket"] = DemoBucket, ["pathStyle"] = "1" }, "cloud:s3:demo")
        {
            Added = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000),
        };
        return [new CloudConnection(record, new CloudSecret { Password = DemoSecret })];
    }

    void Persist()
    {
        if (_persistPath is null) return;
        try
        {
            var tmp = _persistPath + ".tmp";
            File.WriteAllBytes(tmp, JsonSerializer.SerializeToUtf8Bytes(_state.Buckets));
            File.Move(tmp, _persistPath, overwrite: true);
        }
        catch { }
    }

    static void Seed(State s)
    {
        static DateTimeOffset D(double n) => DateTimeOffset.FromUnixTimeSeconds(1_790_000_000 + (long)(n * 86_400));
        static Dictionary<string, string> M(double n) => new() { ["x-amz-meta-mtime"] = D(n).ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture) };
        static byte[] U(string t) => Encoding.UTF8.GetBytes(t);
        const string b = DemoBucket;
        s.AddBucket(b);
        s.Put(b, "Readme.txt", U("Welcome to the demo S3 bucket.\n\nNothing here is real; files you add stay on this PC.\n"), meta: M(30), modified: D(30));
        s.Put(b, "Documents/", modified: D(5));
        s.Put(b, "Documents/Budget 2026.csv", U("Month,Income,Expenses\nJanuary,4200,3100\nFebruary,4200,2950\nMarch,4350,3300\n"), meta: M(12), modified: D(12));
        s.Put(b, "Documents/Meeting notes.txt", U("Agenda\n- Roadmap review\n- Launch checklist\n- Next steps\n"), meta: M(20), modified: D(20));
        s.Put(b, "Documents/Project brief.pdf", Pdf("Project brief", ["Goals", "Scope", "Timeline"]), meta: M(8), modified: D(8));
        s.Put(b, "Photos/Harbor at dusk.png", DemoArt.Png(480, 320, 0.58, "Harbor at dusk"), meta: M(3), modified: D(3));
        s.Put(b, "Photos/Mountain lake.png", DemoArt.Png(480, 320, 0.33, "Mountain lake"), meta: M(4), modified: D(4));
        s.Put(b, "Photos/Beach.png", DemoArt.Png(480, 320, 0.12, "Beach"), meta: M(2), modified: D(2));
        s.Put(b, "Backups/settings-backup.json", U("{\"theme\": \"dark\", \"version\": 3}\n"), meta: M(14), modified: D(14));
        s.Put(b, "Archive/", modified: D(1));
        s.Put(b, S3Backend.TrashPrefix + "Old draft.txt", U("An older draft.\n"),
            meta: new() { [S3Backend.OriginalMeta] = S3Signer.Encode("Documents/Old draft.txt", slash: false), ["x-amz-meta-cirrus-deleted"] = "1791000000" },
            modified: D(20));
    }

    /// <summary>A one-page PDF with a title and a few lines (Helvetica, no images).</summary>
    static byte[] Pdf(string title, string[] lines)
    {
        static string Esc(string t) => t.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)");
        var text = new StringBuilder($"BT /F1 28 Tf 72 700 Td ({Esc(title)}) Tj ET\n");
        for (int i = 0; i < lines.Length; i++) text.Append(CultureInfo.InvariantCulture, $"BT /F1 14 Tf 72 {650 - i * 24} Td ({Esc(lines[i])}) Tj ET\n");
        var stream = text.ToString();
        string[] objects =
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            $"<< /Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ];
        var sb = new StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Length; i++)
        {
            offsets.Add(Encoding.ASCII.GetByteCount(sb.ToString()));
            sb.Append(CultureInfo.InvariantCulture, $"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = Encoding.ASCII.GetByteCount(sb.ToString());
        sb.Append(CultureInfo.InvariantCulture, $"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var o in offsets) sb.Append(CultureInfo.InvariantCulture, $"{o:0000000000} 00000 n \n");
        sb.Append(CultureInfo.InvariantCulture, $"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    // MARK: IFakeCloud

    static (string Host, int? Port) HostOf(Uri u) => (u.Host.ToLowerInvariant(), u.IsDefaultPort ? null : u.Port);

    Endpoint? EndpointFor(string host, int? port, out string? hostBucket)
    {
        hostBucket = null;
        foreach (var ep in _state.Endpoints)
        {
            if (ep.Port != port) continue;
            if (host == ep.Host) return ep;
            if (ep.VirtualHosted && host.EndsWith("." + ep.Host, StringComparison.Ordinal))
            {
                hostBucket = host[..^(ep.Host.Length + 1)];
                return ep;
            }
        }
        return null;
    }

    public bool Handles(Uri uri)
    {
        var (host, port) = HostOf(uri);
        lock (_lock) return EndpointFor(host, port, out _) is not null;
    }

    // MARK: HttpMessageHandler

    sealed record Outcome(int Status, Dictionary<string, string> Headers, byte[] Data, Exception? Failure = null);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        Outcome o;
        double latency;
        lock (_lock) { o = Handle(request, body); latency = _state.Latency; }
        if (latency > 0) await Task.Delay(TimeSpan.FromSeconds(latency), ct).ConfigureAwait(false);
        if (o.Failure is { } f) throw f;
        var head = request.Method == HttpMethod.Head;
        var resp = new HttpResponseMessage((HttpStatusCode)o.Status) { RequestMessage = request, Content = new ByteArrayContent(head ? [] : o.Data) };
        var headers = new Dictionary<string, string>(o.Headers, StringComparer.OrdinalIgnoreCase);
        if (!headers.ContainsKey("Content-Length")) headers["Content-Length"] = o.Data.Length.ToString(CultureInfo.InvariantCulture);
        foreach (var (k, v) in headers)
        {
            if (k.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) resp.Content.Headers.ContentLength = long.Parse(v, CultureInfo.InvariantCulture);
            else if (!resp.Headers.TryAddWithoutValidation(k, v)) resp.Content.Headers.TryAddWithoutValidation(k, v);
        }
        return resp;
    }

    static string? H(HttpRequestMessage r, string name)
    {
        if (r.Headers.TryGetValues(name, out var v)) return string.Join(",", v);
        if (r.Content?.Headers.TryGetValues(name, out var cv) == true) return string.Join(",", cv);
        return null;
    }

    static IEnumerable<KeyValuePair<string, string>> AllHeaders(HttpRequestMessage r)
    {
        foreach (var kv in r.Headers) yield return new(kv.Key, string.Join(",", kv.Value));
        if (r.Content is not null) foreach (var kv in r.Content.Headers) yield return new(kv.Key, string.Join(",", kv.Value));
    }

    // MARK: Helpers

    public static string Md5(byte[] d) => Convert.ToHexStringLower(MD5.HashData(d));

    static string Mime(string key) => Path.GetExtension(key).TrimStart('.').ToLowerInvariant() switch
    {
        "txt" or "md" => "text/plain",
        "csv" => "text/csv",
        "json" => "application/json",
        "pdf" => "application/pdf",
        "jpg" or "jpeg" => "image/jpeg",
        "png" => "image/png",
        _ => "binary/octet-stream",
    };

    DateTimeOffset Now() => DateTimeOffset.UtcNow.AddSeconds(_state.Skew);
    static string RequestID() => Guid.NewGuid().ToString("N")[..16].ToUpperInvariant();
    static string Iso(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    static string HttpDate(DateTimeOffset d) => d.UtcDateTime.ToString("r", CultureInfo.InvariantCulture);

    Dictionary<string, string> BaseHeaders() => new(StringComparer.OrdinalIgnoreCase) { ["Date"] = HttpDate(Now()), ["x-amz-request-id"] = RequestID(), ["Server"] = "FakeS3" };

    Outcome Error(int status, string code, string message, Dictionary<string, string>? extra = null, Dictionary<string, string>? headers = null)
    {
        var xml = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>" + code + "</Code><Message>" + S3Xml.Escape(message) + "</Message>");
        foreach (var (k, v) in (extra ?? []).OrderBy(kv => kv.Key, StringComparer.Ordinal)) xml.Append('<').Append(k).Append('>').Append(S3Xml.Escape(v)).Append("</").Append(k).Append('>');
        xml.Append("<RequestId>").Append(RequestID()).Append("</RequestId></Error>");
        var h = BaseHeaders();
        h["Content-Type"] = "application/xml";
        foreach (var (k, v) in headers ?? []) h[k] = v;
        return new Outcome(status, h, Encoding.UTF8.GetBytes(xml.ToString()));
    }

    Outcome XmlReply(string body, int status = 200, Dictionary<string, string>? headers = null)
    {
        var h = BaseHeaders();
        h["Content-Type"] = "application/xml";
        foreach (var (k, v) in headers ?? []) h[k] = v;
        return new Outcome(status, h, Encoding.UTF8.GetBytes("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body));
    }

    Outcome Empty(int status, Dictionary<string, string>? headers = null)
    {
        var h = BaseHeaders();
        foreach (var (k, v) in headers ?? []) h[k] = v;
        return new Outcome(status, h, []);
    }

    static Outcome Fail(Exception e) => new(0, [], [], e);

    /// <summary>AWS's encoding-type=url: percent-encoding with "+" for spaces.</summary>
    static string UrlEncode(string s) => S3Signer.Encode(s, slash: false).Replace("%20", "+");

    /// <summary>Keys as raw XML text: &amp; &lt; &gt; escaped, but characters XML can't carry are written as they are (like S3).</summary>
    static string RawXml(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    // MARK: Request handling

    Outcome Handle(HttpRequestMessage req, byte[] body)
    {
        if (req.RequestUri is not { IsAbsoluteUri: true } url) return Fail(new HttpRequestException("Bad URL."));
        var (host, port) = HostOf(url);
        var method = req.Method.Method;
        // Which service, and is the bucket in the host name?
        if (EndpointFor(host, port, out var hostBucket) is not { } ep)
            return Fail(new HttpRequestException(HttpRequestError.NameResolutionError, $"No such host is known ({host})."));
        if (_state.DropNext > 0)
        {
            _state.DropNext--;
            return Fail(new HttpRequestException(HttpRequestError.ResponseEnded, "The network connection was lost.", new IOException("connection lost")));
        }
        _state.LastUserAgent = H(req, "User-Agent");
        var authority = host + (port is int p ? ":" + p.ToString(CultureInfo.InvariantCulture) : "");
        _state.Hosts.Add(authority);

        // Bucket and key from the (decoded) path, exactly as it would go over the wire.
        var pq = url.PathAndQuery;
        var qi = pq.IndexOf('?');
        var rawPath = qi >= 0 ? pq[..qi] : pq;
        var rawQuery = qi >= 0 ? pq[(qi + 1)..] : "";
        if (S3Signer.Decode(rawPath.Length == 0 ? "/" : rawPath) is not { } path) return Error(400, "InvalidURI", "Couldn't parse the specified URI.");
        var bucketName = hostBucket;
        var key = "";
        if (bucketName is null)
        {
            var rest = S3Key.DropPrefix(path, "/");
            if (rest.Length > 0)
            {
                var i = rest.IndexOf('/');
                if (i >= 0) { bucketName = rest[..i]; key = rest[(i + 1)..]; }
                else bucketName = rest;
            }
        }
        else key = S3Key.DropPrefix(path, "/");
        var query = S3Signer.QueryItems(rawQuery);
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in query) q[k] = v ?? "";
        _state.Calls.Add($"{method} {bucketName ?? "-"} {key}{(query.Count == 0 ? "" : "?" + string.Join("&", query.Select(x => x.Name).Order(StringComparer.Ordinal)))}");

        // Signature Version 4, checked like S3 does.
        if (H(req, "Authorization") is not { } auth) return Error(403, "AccessDenied", "Access Denied");
        if (S3Signer.Parse(auth) is not { } sp) return Error(400, "AuthorizationHeaderMalformed", "The authorization header is malformed.");
        if (!_state.Credentials.TryGetValue(sp.AccessKey, out var cred))
            return Error(403, "InvalidAccessKeyId", "The AWS Access Key Id you provided does not exist in our records.", new() { ["AWSAccessKeyId"] = sp.AccessKey });
        if (H(req, "x-amz-date") is not { } amz || S3Signer.ParseAmzDate(amz) is not { } reqDate)
            return Error(403, "AccessDenied", "AWS authentication requires a valid Date or x-amz-date header");
        if (Math.Abs((reqDate - Now()).TotalSeconds) > 15 * 60)
        {
            _state.SkewRejections++;
            return Error(403, "RequestTimeTooSkewed", "The difference between the request time and the current time is too large.",
                new() { ["RequestTime"] = amz, ["ServerTime"] = Iso(Now()), ["MaxAllowedSkewMilliseconds"] = "900000" });
        }
        if (sp.Day != amz[..8] || sp.Service != "s3")
            return Error(400, "AuthorizationHeaderMalformed", "The authorization header is malformed; the credential scope is wrong.");
        var bucket = bucketName is null ? null : _state.Buckets.GetValueOrDefault(bucketName);
        // Region: AWS buckets live in one region; R2 takes "auto" (or us-east-1 / empty); the others their endpoint's.
        var expected = ep.Flavor switch
        {
            Flavor.Aws => bucket?.Region ?? ep.Region,
            Flavor.R2 => sp.Region is "auto" or "us-east-1" or "" ? sp.Region : "auto",
            _ => ep.Region,
        };
        if (sp.Region != expected)
        {
            _state.RegionRejections++;
            return Error(400, "AuthorizationHeaderMalformed", $"The authorization header is malformed; the region '{sp.Region}' is wrong; expecting '{expected}'",
                new() { ["Region"] = expected }, bucket is not null ? new() { ["x-amz-bucket-region"] = expected } : null);
        }
        if (H(req, "x-amz-content-sha256") is not { } payloadHash)
            return Error(400, "InvalidRequest", "Missing required header for this request: x-amz-content-sha256");
        var signed = sp.SignedHeaders.ToHashSet(StringComparer.Ordinal);
        if (!signed.Contains("host") || !signed.Contains("x-amz-date")) return Error(403, "AccessDenied", "Host and x-amz-date must be signed.");
        foreach (var (name, _) in AllHeaders(req))
        {
            var lower = name.ToLowerInvariant();
            if (lower.StartsWith("x-amz-", StringComparison.Ordinal) && !signed.Contains(lower))
                return Error(403, "AccessDenied", "There were headers present in the request which were not signed", new() { ["HeadersNotSigned"] = lower });
        }
        var toSign = new List<(string, string)>();
        foreach (var name in sp.SignedHeaders)
        {
            if (name == "host") toSign.Add(("host", authority));
            else if (H(req, name) is { } v) toSign.Add((name, v));
            else
            {
                _state.SignatureFailures++;
                return Error(403, "SignatureDoesNotMatch", "A signed header is missing from the request.");
            }
        }
        var sig = S3Signer.Sign(method, S3Signer.Encode(path, slash: false), S3Signer.CanonicalQuery(query), toSign, payloadHash, amz, sp.Region, "s3", sp.AccessKey, cred.Secret);
        if (sig.Signature != sp.Signature)
        {
            _state.SignatureFailures++;
            return Error(403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided. Check your key and signing method.",
                new() { ["AWSAccessKeyId"] = sp.AccessKey });
        }
        if (payloadHash != S3Signer.UnsignedPayload && payloadHash != S3Signer.Sha256Hex(body))
            return Error(400, "XAmzContentSHA256Mismatch", "The provided 'x-amz-content-sha256' header does not match what was computed.");

        // Injected trouble (after authentication, like a real service under load).
        if (_state.SlowDownNext > 0) { _state.SlowDownNext--; return Error(503, "SlowDown", "Please reduce your request rate.", headers: new() { ["Retry-After"] = "0" }); }
        if (_state.InternalErrorNext > 0) { _state.InternalErrorNext--; return Error(500, "InternalError", "We encountered an internal error. Please try again."); }

        if (bucketName is null)
        {
            if (method != "GET") return Error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.");
            if (!cred.CanListBuckets) return Error(403, "AccessDenied", "Access Denied");
            return ListBuckets(cred);
        }
        if (bucket is null) return Error(404, "NoSuchBucket", "The specified bucket does not exist", new() { ["BucketName"] = bucketName });
        // An AWS bucket is served by its own region's endpoint.
        if (ep.Flavor == Flavor.Aws && ep.Region != bucket.Region)
            return Error(301, "PermanentRedirect", "The bucket you are attempting to access must be addressed using the specified endpoint.",
                new() { ["Endpoint"] = $"s3.{bucket.Region}.amazonaws.com", ["Bucket"] = bucketName }, new() { ["x-amz-bucket-region"] = bucket.Region });
        if (cred.Buckets is { } allowed && !allowed.Contains(bucketName)) return Error(403, "AccessDenied", "Access Denied");
        var outcome = Route(method, ep, bucketName, bucket, key, q, req, body);
        if (outcome.Status is >= 200 and < 300 && method is not "GET" and not "HEAD") Persist();
        return outcome;
    }

    Outcome Route(string method, Endpoint ep, string bucketName, Bucket bucket, string key, Dictionary<string, string> q, HttpRequestMessage req, byte[] body)
    {
        if (key.Length == 0)
        {
            return method switch
            {
                "GET" when q.GetValueOrDefault("list-type") == "2" => ListObjects(bucketName, bucket, q),
                "GET" when q.ContainsKey("location") => XmlReply($"<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">{bucket.Region}</LocationConstraint>"),
                "GET" => Error(400, "InvalidRequest", "This fake serves ListObjectsV2 only (list-type=2)."),
                "HEAD" => Empty(200, new() { ["x-amz-bucket-region"] = bucket.Region }),
                _ => Error(405, "MethodNotAllowed", "The specified method is not allowed against this resource."),
            };
        }
        switch (method)
        {
            case "GET" or "HEAD": return GetObject(bucket, key, head: method == "HEAD");
            case "PUT":
                if (q.TryGetValue("partNumber", out var n) && q.TryGetValue("uploadId", out var id)) return UploadPart(bucketName, key, n, id, req, body);
                if (H(req, "x-amz-copy-source") is not null) return CopyObject(bucketName, bucket, key, req);
                return PutObject(ep, bucket, key, req, body);
            case "POST":
                if (q.ContainsKey("uploads")) return CreateUpload(bucketName, key, req);
                if (q.TryGetValue("uploadId", out var cid)) return CompleteUpload(ep, bucketName, bucket, key, cid, body, req);
                return Error(400, "InvalidRequest", "Unsupported POST.");
            case "DELETE":
                if (q.TryGetValue("uploadId", out var did))
                {
                    if (!_state.Uploads.TryGetValue(did, out var u) || u.Bucket != bucketName || !S3Key.Same(u.Key, key))
                        return Error(404, "NoSuchUpload", "The specified upload does not exist.");
                    _state.Uploads.Remove(did);
                    _state.Aborted++;
                    return Empty(204);
                }
                bucket.Objects.Remove(key);
                return Empty(204);
            default:
                return Error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.");
        }
    }

    Outcome ListBuckets(Credential cred)
    {
        var xml = new StringBuilder("<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Owner><ID>fake</ID><DisplayName>fake</DisplayName></Owner><Buckets>");
        foreach (var name in _state.Buckets.Keys.Order(StringComparer.Ordinal))
        {
            if (cred.Buckets is { } allowed && !allowed.Contains(name)) continue;
            xml.Append("<Bucket><Name>").Append(S3Xml.Escape(name)).Append("</Name><CreationDate>").Append(Iso(_state.Buckets[name].Created)).Append("</CreationDate></Bucket>");
        }
        xml.Append("</Buckets></ListAllMyBucketsResult>");
        return XmlReply(xml.ToString());
    }

    Outcome ListObjects(string bucketName, Bucket bucket, Dictionary<string, string> q)
    {
        _state.ListRequests++;
        var prefix = q.GetValueOrDefault("prefix") ?? "";
        var delimiter = q.GetValueOrDefault("delimiter") is { Length: > 0 } dl ? dl : null;
        if (delimiter is not null && delimiter != "/") return Error(400, "InvalidArgument", "This fake supports the delimiter \"/\" only.");
        var maxKeys = Math.Min(Math.Min(int.TryParse(q.GetValueOrDefault("max-keys") ?? "1000", NumberStyles.Integer, CultureInfo.InvariantCulture, out var mk) ? mk : 1000, 1000), _state.PageSize);
        var urlEnc = q.GetValueOrDefault("encoding-type") == "url";
        if (q.TryGetValue("encoding-type", out var et) && et != "url") return Error(400, "InvalidArgument", "Invalid Encoding Method specified in Request");
        var startAfter = q.GetValueOrDefault("start-after");
        if (q.TryGetValue("continuation-token", out var token))
        {
            try { startAfter = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(token)); }
            catch (Exception ex) when (ex is FormatException or ArgumentException) { return Error(400, "InvalidArgument", "The continuation token provided is incorrect"); }
        }
        // Every entry in byte order: objects and, with a delimiter, the prefixes they group into.
        var entries = new List<(string Key, bool Prefix)>();
        foreach (var k in bucket.Keys)
        {
            if (!S3Key.HasPrefix(k, prefix) || _state.GhostKeys.Contains(k)) continue;
            if (delimiter is not null && S3Key.ChildPrefix(k, prefix) is { } cp)
            {
                if (entries.Count > 0 && entries[^1].Prefix && S3Key.Same(entries[^1].Key, cp)) continue;
                entries.Add((cp, true));
            }
            else entries.Add((k, false));
        }
        if (startAfter is not null) entries = entries.Where(e => S3Key.Less(startAfter, e.Key)).ToList();
        var page = entries.Take(maxKeys).ToList();
        var truncated = entries.Count > page.Count;
        Func<string, string> e = urlEnc ? UrlEncode : RawXml;
        var xml = new StringBuilder("<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>").Append(S3Xml.Escape(bucketName)).Append("</Name>");
        xml.Append("<Prefix>").Append(e(prefix)).Append("</Prefix><KeyCount>").Append(page.Count).Append("</KeyCount><MaxKeys>").Append(maxKeys).Append("</MaxKeys>");
        if (delimiter is not null) xml.Append("<Delimiter>").Append(e(delimiter)).Append("</Delimiter>");
        if (urlEnc) xml.Append("<EncodingType>url</EncodingType>");
        if (token is not null) xml.Append("<ContinuationToken>").Append(S3Xml.Escape(token)).Append("</ContinuationToken>");
        xml.Append("<IsTruncated>").Append(truncated ? "true" : "false").Append("</IsTruncated>");
        if (truncated && page.Count > 0 && !_state.TokenlessListings.Contains(prefix))
            xml.Append("<NextContinuationToken>").Append(Convert.ToBase64String(Encoding.UTF8.GetBytes(page[^1].Key))).Append("</NextContinuationToken>");
        foreach (var entry in page)
        {
            if (entry.Prefix)
            {
                xml.Append("<CommonPrefixes><Prefix>").Append(e(entry.Key)).Append("</Prefix></CommonPrefixes>");
                continue;
            }
            var o = bucket.Object(entry.Key)!;
            xml.Append("<Contents><Key>").Append(e(o.Key)).Append("</Key><LastModified>").Append(Iso(o.Modified)).Append("</LastModified><ETag>&quot;")
                .Append(o.Etag).Append("&quot;</ETag><Size>").Append(o.Data.Length).Append("</Size><StorageClass>").Append(o.StorageClass ?? "STANDARD")
                .Append("</StorageClass></Contents>");
        }
        xml.Append("</ListBucketResult>");
        if (_state.TruncateListings.Contains(prefix))
        {
            var h = BaseHeaders();
            h["Content-Type"] = "application/xml";
            var all = Encoding.UTF8.GetBytes(xml.ToString());
            return new Outcome(200, h, all[..(all.Length / 2)]);
        }
        return XmlReply(xml.ToString());
    }

    Dictionary<string, string> ObjectHeaders(StoredObject o)
    {
        var h = BaseHeaders();
        h["Content-Type"] = o.ContentType;
        h["ETag"] = "\"" + o.Etag + "\"";
        h["Last-Modified"] = HttpDate(o.Modified);
        h["Content-Length"] = o.Data.Length.ToString(CultureInfo.InvariantCulture);
        h["Accept-Ranges"] = "bytes";
        foreach (var (k, v) in o.Meta) h[k] = v;
        foreach (var (k, v) in o.Extra) h[k] = v;
        if (o.StorageClass is { } sc && sc != "STANDARD") h["x-amz-storage-class"] = sc;
        return h;
    }

    Outcome GetObject(Bucket bucket, string key, bool head)
    {
        if (bucket.Object(key) is not { } o || (head && _state.GhostKeys.Contains(key)))
            return head ? Empty(404) : Error(404, "NoSuchKey", "The specified key does not exist.", new() { ["Key"] = key });
        if (!head && o.StorageClass is "GLACIER" or "DEEP_ARCHIVE") return Error(403, "InvalidObjectState", "The operation is not valid for the object's storage class");
        return new Outcome(200, ObjectHeaders(o), head ? [] : o.Data);
    }

    /// <summary>x-amz-meta-* and the other kept headers of a request; null when a metadata value isn't ASCII.</summary>
    static (Dictionary<string, string> Meta, Dictionary<string, string> Extra, string? StorageClass)? Metadata(HttpRequestMessage req)
    {
        var meta = new Dictionary<string, string>(StringComparer.Ordinal);
        var extra = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in AllHeaders(req))
        {
            var name = k.ToLowerInvariant();
            if (name.StartsWith("x-amz-meta-", StringComparison.Ordinal))
            {
                // Header values must be ASCII (S3 would mangle anything else).
                if (!v.All(char.IsAscii)) return null;
                meta[name] = v;
            }
            else if (name is "content-encoding" or "content-disposition" or "content-language" or "cache-control" or "expires") extra[name] = v;
        }
        return (meta, extra, H(req, "x-amz-storage-class"));
    }

    /// <summary>If-None-Match: * on a write, as the service treats it. Null: go ahead.</summary>
    Outcome? ConditionalCheck(Endpoint ep, HttpRequestMessage req, bool exists)
    {
        if (H(req, "If-None-Match") is not { } inm) return null;
        return ep.Conditional switch
        {
            Conditional.NotImplemented => Error(501, "NotImplemented", "A header you provided implies functionality that is not implemented", new() { ["Header"] = "If-None-Match" }),
            Conditional.Ignored => null,
            _ when inm != "*" => Error(501, "NotImplemented", "If-None-Match supports only *"),
            _ => exists ? Error(412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold", new() { ["Condition"] = "If-None-Match" }) : null,
        };
    }

    Outcome PutObject(Endpoint ep, Bucket bucket, string key, HttpRequestMessage req, byte[] body)
    {
        if (Encoding.UTF8.GetByteCount(key) > 1024) return Error(400, "KeyTooLongError", "Your key is too long");
        if (ConditionalCheck(ep, req, bucket.Object(key) is not null) is { } c) return c;
        if (body.Length > _state.MaxPutSize) return Error(400, "EntityTooLarge", "Your proposed upload exceeds the maximum allowed size");
        if (H(req, "Content-MD5") is { } md5)
        {
            string? given;
            try { given = Convert.ToHexStringLower(Convert.FromBase64String(md5)); } catch (FormatException) { given = null; }
            if (given != Md5(body)) return Error(400, "BadDigest", "The Content-MD5 you specified did not match what we received.");
        }
        if (Metadata(req) is not { } m) return Error(400, "InvalidArgument", "Metadata values must be US-ASCII.");
        var o = new StoredObject
        {
            Key = key, Data = body, ContentType = H(req, "Content-Type") ?? "binary/octet-stream", Meta = m.Meta, Extra = m.Extra, Modified = Now(),
            Etag = Md5(body), StorageClass = m.StorageClass,
        };
        bucket.Objects[key] = o;
        return Empty(200, new() { ["ETag"] = "\"" + o.Etag + "\"" });
    }

    /// <summary>"/bucket/key" (URL-encoded) → (bucket, key).</summary>
    static (string Bucket, string Key)? CopySource(HttpRequestMessage req)
    {
        if (H(req, "x-amz-copy-source") is not { } s) return null;
        var qm = s.IndexOf('?');
        if (qm >= 0) s = s[..qm];
        if (S3Signer.Decode(s) is not { } d) return null;
        var rest = S3Key.DropPrefix(d, d.StartsWith('/') ? "/" : "");
        var i = rest.IndexOf('/');
        if (i < 0) return null;
        return (rest[..i], rest[(i + 1)..]);
    }

    Outcome CopyObject(string bucketName, Bucket bucket, string key, HttpRequestMessage req)
    {
        if (CopySource(req) is not { } source) return Error(400, "InvalidArgument", "Copy Source must mention the source bucket and key: sourcebucket/sourcekey");
        var (sb, sk) = source;
        if (_state.Buckets.GetValueOrDefault(sb)?.Object(sk) is not { } src) return Error(404, "NoSuchKey", "The specified key does not exist.", new() { ["Key"] = sk });
        if (src.Data.Length > _state.MaxCopySize)
            return Error(400, "InvalidRequest", $"The specified copy source is larger than the maximum allowable size for a copy source: {_state.MaxCopySize}");
        if (src.StorageClass is "GLACIER" or "DEEP_ARCHIVE") return Error(403, "InvalidObjectState", "The operation is not valid for the object's storage class");
        var directive = (H(req, "x-amz-metadata-directive") ?? "COPY").ToUpperInvariant();
        if (directive is not "COPY" and not "REPLACE") return Error(400, "InvalidArgument", "Unknown metadata directive.");
        if (sb == bucketName && S3Key.Same(sk, key) && directive == "COPY")
            return Error(400, "InvalidRequest", "This copy request is illegal because it is trying to copy an object to itself without changing the object's metadata.");
        if (_state.FailCopiesIn200.Contains(sk))
            return XmlReply("<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>");
        var o = src.Clone();
        o.Key = key;
        o.Modified = Now();
        if (directive == "REPLACE")
        {
            if (Metadata(req) is not { } m) return Error(400, "InvalidArgument", "Metadata values must be US-ASCII.");
            o.Meta = m.Meta;
            o.Extra = m.Extra;
            o.StorageClass = m.StorageClass;
            o.ContentType = H(req, "Content-Type") ?? "binary/octet-stream";
        }
        bucket.Objects[key] = o;
        _state.Copies++;
        return XmlReply($"<CopyObjectResult><LastModified>{Iso(o.Modified)}</LastModified><ETag>&quot;{o.Etag}&quot;</ETag></CopyObjectResult>");
    }

    Outcome CreateUpload(string bucketName, string key, HttpRequestMessage req)
    {
        if (Metadata(req) is not { } m) return Error(400, "InvalidArgument", "Metadata values must be US-ASCII.");
        var id = "upload-" + Guid.NewGuid().ToString().ToLowerInvariant();
        _state.Uploads[id] = new Upload { Bucket = bucketName, Key = key, ContentType = H(req, "Content-Type") ?? "binary/octet-stream", Meta = m.Meta };
        return XmlReply($"<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>{S3Xml.Escape(bucketName)}</Bucket>"
            + $"<Key>{RawXml(key)}</Key><UploadId>{id}</UploadId></InitiateMultipartUploadResult>");
    }

    Outcome UploadPart(string bucketName, string key, string n, string id, HttpRequestMessage req, byte[] body)
    {
        if (!_state.Uploads.TryGetValue(id, out var u) || u.Bucket != bucketName || !S3Key.Same(u.Key, key))
            return Error(404, "NoSuchUpload", "The specified upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.");
        if (!int.TryParse(n, NumberStyles.None, CultureInfo.InvariantCulture, out var num) || num is < 1 or > 10_000)
            return Error(400, "InvalidArgument", "Part number must be an integer between 1 and 10000, inclusive");
        if (_state.ForbiddenParts.Contains(num)) return Error(403, "AccessDenied", "Access Denied");
        if (_state.FailParts.TryGetValue(num, out var left) && left > 0)
        {
            _state.FailParts[num] = left - 1;
            return Error(500, "InternalError", "We encountered an internal error. Please try again.");
        }
        var data = body;
        var isCopy = H(req, "x-amz-copy-source") is not null;
        if (isCopy)
        {
            if (CopySource(req) is not { } source || _state.Buckets.GetValueOrDefault(source.Bucket)?.Object(source.Key) is not { } src)
                return Error(404, "NoSuchKey", "The specified key does not exist.");
            data = src.Data;
            if (H(req, "x-amz-copy-source-range") is { } range)
            {
                var nums = range.Replace("bytes=", "").Split('-').Select(x => long.TryParse(x, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : -1).ToArray();
                if (nums.Length != 2 || nums[0] < 0 || nums[0] > nums[1] || nums[1] >= src.Data.Length)
                    return Error(400, "InvalidArgument", "The x-amz-copy-source-range value must be of the form bytes=first-last where first and last are the zero-based offsets of the first and last bytes to copy");
                data = src.Data[(int)nums[0]..(int)(nums[1] + 1)];
            }
        }
        var etag = Md5(data);
        u.Parts[num] = new Part(data, etag);
        _state.PartPuts++;
        if (isCopy) return XmlReply($"<CopyPartResult><LastModified>{Iso(Now())}</LastModified><ETag>&quot;{etag}&quot;</ETag></CopyPartResult>");
        return Empty(200, new() { ["ETag"] = "\"" + etag + "\"" });
    }

    Outcome CompleteUpload(Endpoint ep, string bucketName, Bucket bucket, string key, string id, byte[] body, HttpRequestMessage req)
    {
        if (!_state.Uploads.TryGetValue(id, out var u) || u.Bucket != bucketName || !S3Key.Same(u.Key, key))
            return Error(404, "NoSuchUpload", "The specified upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.");
        if (S3Xml.Parse(body) is not { Name: "CompleteMultipartUpload" } root)
            return Error(400, "MalformedXML", "The XML you provided was not well-formed or did not validate against our published schema");
        var listed = root.All("Part").Select(x => (N: int.TryParse(x.Value("PartNumber"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0,
            ETag: S3Backend.CleanETag(x.Value("ETag")) ?? "")).ToList();
        if (listed.Count == 0) return Error(400, "MalformedXML", "You must specify at least one part");
        for (int i = 1; i < listed.Count; i++)
            if (listed[i].N <= listed[i - 1].N) return Error(400, "InvalidPartOrder", "The list of parts was not in ascending order. Parts must be ordered by part number.");
        using var data = new MemoryStream();
        using var md5s = new MemoryStream();
        for (int i = 0; i < listed.Count; i++)
        {
            var (num, etag) = listed[i];
            if (!u.Parts.TryGetValue(num, out var part) || part.Etag != etag)
                return Error(400, "InvalidPart", "One or more of the specified parts could not be found. The part may not have been uploaded, or the specified entity tag may not match the part's entity tag.");
            if (i < listed.Count - 1 && part.Data.Length < _state.MinPartSize)
                return Error(400, "EntityTooSmall", "Your proposed upload is smaller than the minimum allowed size", new() { ["PartNumber"] = num.ToString(CultureInfo.InvariantCulture) });
            data.Write(part.Data);
            md5s.Write(MD5.HashData(part.Data));
        }
        if (ConditionalCheck(ep, req, bucket.Object(key) is not null) is { } c) return c;
        var etagAll = Md5(md5s.ToArray()) + "-" + listed.Count.ToString(CultureInfo.InvariantCulture);
        bucket.Objects[key] = new StoredObject { Key = key, Data = data.ToArray(), ContentType = u.ContentType, Meta = u.Meta, Modified = Now(), Etag = etagAll };
        _state.Uploads.Remove(id);
        _state.Completed++;
        return XmlReply($"<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>{S3Xml.Escape(bucketName)}</Bucket>"
            + $"<Key>{RawXml(key)}</Key><ETag>&quot;{etagAll}&quot;</ETag></CompleteMultipartUploadResult>");
    }
}
