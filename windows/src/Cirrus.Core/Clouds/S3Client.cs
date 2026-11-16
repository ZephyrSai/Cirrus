using System.Globalization;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Xml;

namespace Cirrus.Core;

// The wire layer of the S3 connector (port of S3Client.swift): endpoints and addressing (virtual-hosted or path-style),
// SigV4-signed requests with retries and back-off, clock-skew and bucket-region correction, streamed downloads, and the
// XML S3 answers in. Nothing here logs a key, a signature, an object key or a bucket name.

// MARK: - Endpoint

/// <summary>Where an S3 service lives. <see cref="BasePath"/> is "" or "/prefix" (a service behind a proxy path), never ending in "/".</summary>
sealed record S3Endpoint(string Scheme, string Host, int? Port, string BasePath)
{
    static readonly HashSet<string> LoopbackHosts = new(StringComparer.OrdinalIgnoreCase) { "localhost", "127.0.0.1", "::1", "[::1]" };

    public bool IsAWS => Host.EndsWith(".amazonaws.com", StringComparison.Ordinal) || Host.EndsWith(".amazonaws.com.cn", StringComparison.Ordinal);
    public bool IsR2 => Host.EndsWith(".r2.cloudflarestorage.com", StringComparison.Ordinal);
    public bool IsLoopback => IsLoopbackHost(Host);
    public static bool IsLoopbackHost(string host) => LoopbackHosts.Contains(host);

    /// <summary>"https://host[:port][/base]".</summary>
    public string Address => Scheme + "://" + Authority + BasePath;
    /// <summary>"host[:port]": the Host header of the service itself.</summary>
    public string Authority => Host + (Port is int p ? ":" + p.ToString(CultureInfo.InvariantCulture) : "");

    /// <summary>
    /// Parses what the user typed ("s3.us-west-004.backblazeb2.com", "https://minio.local:9000/") into an endpoint (https
    /// unless http:// was typed for this device) and the path the address carried ("" or "/bucket" …), decoded.
    /// </summary>
    public static (S3Endpoint Endpoint, string Path) Parse(string input)
    {
        var s = input.Trim();
        if (s.Length == 0)
            throw CloudException.NotConfigured("Enter the service’s endpoint, like s3.us-west-004.backblazeb2.com or https://s3.eu-central-1.amazonaws.com.");
        if (!s.Contains("://", StringComparison.Ordinal)) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host) || string.IsNullOrEmpty(u.Scheme))
            throw CloudException.NotConfigured($"“{input}” isn’t an endpoint address. Enter one like https://s3.us-east-1.amazonaws.com.");
        var scheme = u.Scheme.ToLowerInvariant();
        var host = (u.HostNameType == UriHostNameType.Dns ? u.IdnHost : u.Host).ToLowerInvariant();
        int? port = u.IsDefaultPort ? null : u.Port;
        if ((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) port = null;
        Check(scheme, host);
        var path = u.AbsolutePath;
        while (path.EndsWith('/')) path = path[..^1];
        return (new S3Endpoint(scheme, host, port, ""), S3Signer.Decode(path) ?? path);
    }

    /// <summary>https everywhere; plain http only to this device itself (a MinIO on localhost).</summary>
    public static void Check(string scheme, string host)
    {
        if (scheme == "https") return;
        if (scheme == "http")
        {
            if (IsLoopbackHost(host)) return;
            throw CloudException.Unsupported("Cirrus connects only over https://, so your password and files are never sent unencrypted. "
                + "Use the server’s https:// address (plain http:// works only for a server on this device, such as localhost).");
        }
        throw CloudException.Unsupported($"Cirrus can’t connect to “{scheme}://” addresses. Use the server’s https:// address.");
    }

    /// <summary>
    /// Hosts whose region is in their name: AWS (s3.us-west-2.amazonaws.com, s3-us-west-2…, s3.dualstack.…), Backblaze B2
    /// (s3.us-west-004.backblazeb2.com), Wasabi (s3.eu-central-1.wasabisys.com), Scaleway (s3.fr-par.scw.cloud);
    /// Cloudflare R2 signs with "auto".
    /// </summary>
    public static string? InferredRegion(string host)
    {
        if (host.EndsWith(".r2.cloudflarestorage.com", StringComparison.Ordinal)) return "auto";
        var labels = host.Split('.', StringSplitOptions.RemoveEmptyEntries);
        string? After(int i)
        {
            var j = i + 1;
            if (j < labels.Length && labels[j] == "dualstack") j++;
            return j < labels.Length ? labels[j] : null;
        }
        if (host.EndsWith(".amazonaws.com", StringComparison.Ordinal) || host.EndsWith(".amazonaws.com.cn", StringComparison.Ordinal))
        {
            var i = Array.FindLastIndex(labels, l => l == "s3" || l.StartsWith("s3-", StringComparison.Ordinal));
            if (i < 0) return null;
            if (labels[i].StartsWith("s3-", StringComparison.Ordinal))
            {
                var r = labels[i][3..];
                return r == "external-1" ? "us-east-1" : r;
            }
            var a = After(i);
            return a is null || a == "amazonaws" ? "us-east-1" : a;
        }
        foreach (var suffix in new[] { ".backblazeb2.com", ".wasabisys.com", ".scw.cloud" })
        {
            if (!host.EndsWith(suffix, StringComparison.Ordinal)) continue;
            var i = Array.LastIndexOf(labels, "s3");
            var r = i >= 0 ? After(i) : null;
            if (r is null || suffix.Contains(r, StringComparison.Ordinal)) return suffix == ".wasabisys.com" ? "us-east-1" : null;
            return r;
        }
        return null;
    }

    /// <summary>
    /// The region Cirrus signs with: what the user entered, or (empty or "auto") the one the host names, R2's own
    /// "auto", or us-east-1 (MinIO's and most other servers' default).
    /// </summary>
    public static string SigningRegion(string? entered, string host)
    {
        var r = (entered ?? "").Trim().ToLowerInvariant();
        if (r.Length > 0 && r != "auto") return r;
        return InferredRegion(host) ?? "us-east-1";
    }

    /// <summary>The well-known services, which take a bucket in the address ("bucket.s3.…" or "…/bucket").</summary>
    public bool KnownService => IsAWS || IsR2 || Host.EndsWith(".backblazeb2.com", StringComparison.Ordinal)
        || Host.EndsWith(".wasabisys.com", StringComparison.Ordinal) || Host.EndsWith(".scw.cloud", StringComparison.Ordinal);

    /// <summary>"photos.s3.us-west-2.amazonaws.com" → ("photos", "s3.us-west-2.amazonaws.com") for the known services.</summary>
    public static (string Bucket, string Host)? SplitBucketHost(string host)
    {
        string[] known = [".amazonaws.com", ".amazonaws.com.cn", ".backblazeb2.com", ".wasabisys.com", ".scw.cloud"];
        if (!known.Any(k => host.EndsWith(k, StringComparison.Ordinal))) return null;
        var labels = host.Split('.');
        var i = Array.FindIndex(labels, l => l == "s3" || l.StartsWith("s3-", StringComparison.Ordinal));
        if (i <= 0) return null;
        return (string.Join('.', labels[..i]), string.Join('.', labels[i..]));
    }

    /// <summary>Names a bucket can have as a host name label (no dots, so https certificates still match).</summary>
    public static bool VirtualHostable(string bucket)
    {
        if (bucket.Length is < 3 or > 63 || bucket[0] == '-' || bucket[^1] == '-') return false;
        return bucket.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');
    }
}

// MARK: - XML

/// <summary>A small element tree of an S3 XML answer (namespaces dropped; text kept exactly, spaces included).</summary>
public static class S3Xml
{
    public sealed class Node(string name)
    {
        readonly StringBuilder _text = new();
        public string Name { get; } = name;
        public string Text => _text.ToString();
        public List<Node> Children { get; } = [];
        public Node? Child(string n) => Children.FirstOrDefault(c => c.Name == n);
        public IEnumerable<Node> All(string n) => Children.Where(c => c.Name == n);
        public string? Value(string n) => Child(n)?.Text;
        internal void Append(string s) => _text.Append(s);
    }

    static readonly XmlReaderSettings Settings = new()
    {
        DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, IgnoreComments = true, IgnoreProcessingInstructions = true, IgnoreWhitespace = false,
    };

    /// <summary>The root element, or null for an empty or malformed document (characters XML can't carry included).</summary>
    public static Node? Parse(byte[]? data)
    {
        if (data is null || data.Length == 0) return null;
        try
        {
            using var r = XmlReader.Create(new MemoryStream(data, writable: false), Settings);
            Node? root = null;
            var stack = new Stack<Node>();
            while (r.Read())
            {
                switch (r.NodeType)
                {
                    case XmlNodeType.Element:
                        var n = new Node(r.LocalName);
                        if (stack.Count > 0) stack.Peek().Children.Add(n);
                        else if (root is null) root = n;
                        if (!r.IsEmptyElement) stack.Push(n);
                        break;
                    case XmlNodeType.EndElement:
                        if (stack.Count > 0) stack.Pop();
                        break;
                    case XmlNodeType.Text or XmlNodeType.CDATA or XmlNodeType.Whitespace or XmlNodeType.SignificantWhitespace:
                        if (stack.Count > 0) stack.Peek().Append(r.Value);
                        break;
                }
            }
            return root;
        }
        catch (XmlException) { return null; }
    }

    public static string Escape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '&': sb.Append("&amp;"); break;
                case '<': sb.Append("&lt;"); break;
                case '>': sb.Append("&gt;"); break;
                case '"': sb.Append("&quot;"); break;
                case '\'': sb.Append("&apos;"); break;
                case '\r': sb.Append("&#13;"); break;
                default: sb.Append(ch); break;
            }
        }
        return sb.ToString();
    }
}

/// <summary>An S3 error answer: &lt;Error&gt;&lt;Code&gt;NoSuchKey&lt;/Code&gt;&lt;Message&gt;…&lt;/Message&gt;…&lt;/Error&gt;.</summary>
sealed record S3ErrorBody(string Code, string? Message, string? Region, string? ServerTime)
{
    public static S3ErrorBody? Parse(byte[] data)
    {
        if (data.Length == 0 || data.Length >= 512 * 1024 || S3Xml.Parse(data) is not { Name: "Error" } root) return null;
        var code = root.Value("Code")?.Trim();
        if (string.IsNullOrEmpty(code)) return null;
        return new S3ErrorBody(code, root.Value("Message")?.Trim(), root.Value("Region")?.Trim(), root.Value("ServerTime")?.Trim());
    }
}

static class S3Dates
{
    /// <summary>"2026-11-16T09:30:00.000Z" (listings) or without fractions.</summary>
    public static DateTimeOffset? Iso8601(string? s)
    {
        var t = s?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        return DateTimeOffset.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d) ? d : null;
    }

    public static string IsoString(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    static readonly string[] HttpFormats = ["r", "dddd, dd-MMM-yy HH:mm:ss 'GMT'", "ddd MMM d HH:mm:ss yyyy", "ddd MMM dd HH:mm:ss yyyy"];

    /// <summary>An HTTP date (RFC 1123, RFC 850 or asctime).</summary>
    public static DateTimeOffset? Http(string? s)
    {
        var t = s?.Trim();
        if (string.IsNullOrEmpty(t)) return null;
        if (DateTimeOffset.TryParseExact(t, HttpFormats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d)) return d;
        return DateTimeOffset.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d) ? d : null;
    }

    public static string HttpString(DateTimeOffset d) => d.UtcDateTime.ToString("r", CultureInfo.InvariantCulture);
}

// MARK: - Requests

/// <summary>A request body: none, bytes in memory, or a file.</summary>
abstract record S3Body
{
    public sealed record None : S3Body;
    public sealed record Bytes(byte[] Data) : S3Body;
    public sealed record File(string Path) : S3Body;
    public static readonly S3Body Empty = new None();
}

/// <summary>One request: the bucket (null: the service itself), the object key ("" for the bucket), query and headers.</summary>
sealed class S3Request
{
    public string Method { get; init; } = "GET";
    public string? Bucket { get; init; }
    public string Key { get; init; } = "";
    public List<(string Name, string? Value)> Query { get; init; } = [];
    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public S3Body Body { get; init; } = S3Body.Empty;
    /// <summary>SHA-256 (hex) of the body, or <see cref="S3Signer.UnsignedPayload"/>.</summary>
    public string PayloadHash { get; init; } = S3Signer.EmptyHash;
    /// <summary>How long the request may go without bytes moving (default 60 s).</summary>
    public TimeSpan? Timeout { get; init; }
}

/// <summary>A finished exchange: status, body (or the start of an error body after a download), headers.</summary>
sealed class S3Response(int status, byte[] data, Dictionary<string, string> headers, bool retried, S3ErrorBody? error)
{
    public int Status { get; } = status;
    public byte[] Data { get; } = data;
    public Dictionary<string, string> Headers { get; } = headers;
    /// <summary>True when this answer came after a retry (the first attempt may have reached the server).</summary>
    public bool Retried { get; } = retried;
    public S3ErrorBody? Error { get; } = error;
    public string? Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
    public bool Ok => Status is >= 200 and < 300;
    public string? Code => Error?.Code;

    /// <summary>The same answer as a failure (S3 can put an error inside "200 OK").</summary>
    public S3Response AsFailure() => new(500, Data, Headers, Retried, S3ErrorBody.Parse(Data));
}

/// <summary>Where a download goes, and the size it's expected to have (for progress).</summary>
sealed record S3Download(string Destination, long Expected);

/// <summary>Restarts a timer whenever bytes move; fires when they stop for the request's timeout.</summary>
sealed class S3Stall : IDisposable
{
    readonly CancellationTokenSource _cts;
    readonly CancellationToken _outer;
    readonly TimeSpan _timeout;
    public S3Stall(CancellationToken outer, TimeSpan timeout) { _outer = outer; _timeout = timeout; _cts = CancellationTokenSource.CreateLinkedTokenSource(outer); Kick(); }
    public CancellationToken Token => _cts.Token;
    public void Kick() { try { _cts.CancelAfter(_timeout); } catch (ObjectDisposedException) { } }
    public bool Stalled => _cts.IsCancellationRequested && !_outer.IsCancellationRequested;
    public void Dispose() => _cts.Dispose();
}

// MARK: - Client

sealed class S3Client
{
    public const string UserAgent = "Cirrus (Windows)";
    /// <summary>Headers the transport may change or add: never signed.</summary>
    static readonly HashSet<string> UnsignedHeaders = ["user-agent", "accept-encoding", "content-length", "connection", "expect", "authorization", "accept"];
    public static readonly HashSet<string> RetryCodes = ["SlowDown", "InternalError", "ServiceUnavailable", "RequestTimeout", "Throttling", "ThrottlingException",
        "RequestLimitExceeded", "TooManyRequests", "OperationAborted"];

    public S3Endpoint Endpoint { get; }
    public string AccessKey { get; }
    readonly string _secretKey;
    public string DefaultRegion { get; }
    /// <summary>null: virtual-hosted on AWS (when the bucket name allows), path-style elsewhere.</summary>
    public bool? PathStyle { get; }
    /// <summary>For error messages: "S3 Storage (photos @ s3.us-west-004.backblazeb2.com)".</summary>
    public string ServiceName { get; }

    readonly HttpClient _http;
    readonly object _lock = new();
    TimeSpan _clockOffset;
    readonly Dictionary<string, string> _bucketRegions = new(StringComparer.Ordinal);
    double _retryBase = 0.5;
    int _maxRetries = 5;

    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get { lock (_lock) return _retryBase; } set { lock (_lock) _retryBase = value; } }
    public int MaxRetries { get { lock (_lock) return _maxRetries; } set { lock (_lock) _maxRetries = value; } }
    /// <summary>Time to add to this device's clock (learned from RequestTimeTooSkewed).</summary>
    public TimeSpan ClockOffset { get { lock (_lock) return _clockOffset; } set { lock (_lock) _clockOffset = value; } }

    public S3Client(S3Endpoint endpoint, string accessKey, string secretKey, string region, bool? pathStyle, string serviceName, HttpMessageHandler? transport)
    {
        Endpoint = endpoint;
        AccessKey = accessKey;
        _secretKey = secretKey;
        DefaultRegion = region;
        PathStyle = pathStyle;
        ServiceName = serviceName;
        _http = CloudBackends.Http(transport);
    }

    public string Region(string? bucket)
    {
        if (bucket is null) return DefaultRegion;
        lock (_lock) return _bucketRegions.TryGetValue(bucket, out var r) ? r : DefaultRegion;
    }

    public void SetRegion(string region, string bucket) { lock (_lock) _bucketRegions[bucket] = region; }

    public bool UsesPathStyle(string bucket)
    {
        if (PathStyle is bool p) return p || !S3Endpoint.VirtualHostable(bucket);
        return !(Endpoint.IsAWS && S3Endpoint.VirtualHostable(bucket));
    }

    static readonly UriCreationOptions RawUri = new() { DangerousDisablePathAndQueryCanonicalization = true };

    /// <summary>Where a request goes: URL, Host header value, and the canonical URI and query it's signed with.</summary>
    public (Uri Url, string Host, string Path, string Query) Target(S3Request r, string region)
    {
        var host = Endpoint.Host;
        // A bucket in another AWS region is served from that region's endpoint.
        if (Endpoint.IsAWS && r.Bucket is not null && region != (S3Endpoint.InferredRegion(host) ?? DefaultRegion))
        {
            var i = host.IndexOf("amazonaws.com", StringComparison.Ordinal);
            if (i >= 0) host = "s3." + region + "." + host[i..];
        }
        var path = Endpoint.BasePath;
        var encodedKey = S3Signer.Encode(r.Key, slash: false);
        if (r.Bucket is { } b)
        {
            if (UsesPathStyle(b)) path += "/" + S3Signer.Encode(b, slash: true) + (r.Key.Length == 0 ? "" : "/" + encodedKey);
            else
            {
                host = b + "." + host;
                path += "/" + encodedKey;
            }
        }
        if (path.Length == 0) path = "/";
        var query = S3Signer.CanonicalQuery(r.Query);
        var authority = host + (Endpoint.Port is int p ? ":" + p.ToString(CultureInfo.InvariantCulture) : "");
        // S3 paths are taken exactly as encoded: no ".." folding or re-escaping on the way out (that would break the signature).
        var url = new Uri(Endpoint.Scheme + "://" + authority + path + (query.Length == 0 ? "" : "?" + query), RawUri);
        return (url, authority, path, query);
    }

    HttpRequestMessage MakeRequest(S3Request r, string region, Action<long>? sent, Action kick)
    {
        var t = Target(r, region);
        // One spelling per header (lower-case), so what is signed is exactly what is sent.
        var headers = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in r.Headers) headers[k.ToLowerInvariant()] = v;
        headers["x-amz-date"] = S3Signer.AmzDate(DateTimeOffset.UtcNow + ClockOffset);
        headers["x-amz-content-sha256"] = r.PayloadHash;
        var toSign = new List<(string, string)> { ("host", t.Host) };
        foreach (var (k, v) in headers) if (!UnsignedHeaders.Contains(k)) toSign.Add((k, v));
        var sig = S3Signer.Sign(r.Method, t.Path, t.Query, toSign, r.PayloadHash, headers["x-amz-date"], region, "s3", AccessKey, _secretKey);

        var req = new HttpRequestMessage(new HttpMethod(r.Method), t.Url);
        req.Content = r.Body switch
        {
            S3Body.Bytes b => new ProgressContent(() => new MemoryStream(b.Data, writable: false), b.Data.Length, sent, kick),
            S3Body.File f => new ProgressContent(() => new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true),
                new FileInfo(f.Path).Length, sent, kick),
            _ => r.Method is "PUT" or "POST" ? new ByteArrayContent([]) : null,
        };
        foreach (var (k, v) in headers)
        {
            if (k == "content-length") continue;   // comes from the body
            if (!req.Headers.TryAddWithoutValidation(k, v))
            {
                req.Content ??= new ByteArrayContent([]);
                req.Content.Headers.Remove(k);
                req.Content.Headers.TryAddWithoutValidation(k, v);
            }
        }
        req.Headers.TryAddWithoutValidation("Authorization", sig.Authorization);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        return req;
    }

    static Dictionary<string, string> HeadersOf(HttpResponseMessage r)
    {
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in r.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        foreach (var kv in r.Content.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        return h;
    }

    /// <summary>
    /// One request with retries: dropped connections, 429/500/502/503/504 and SlowDown back off and try again; a skewed
    /// clock or a bucket in another region is corrected once. Every other answer comes back to the caller. All S3 requests
    /// Cirrus sends are safe to repeat (writes are guarded by existence checks or If-None-Match). With
    /// <paramref name="download"/>, a 2xx body is streamed into a temporary file next to the destination, then moved there.
    /// </summary>
    public async Task<S3Response> SendAsync(S3Request r, S3Download? download = null, Action<long, long>? progress = null, long total = 0,
        CancellationToken ct = default)
    {
        int attempt = 0;
        bool skewFixed = false, regionFixed = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var region = Region(r.Bucket);
            var started = DateTimeOffset.UtcNow;
            int status;
            byte[] data = [];
            Dictionary<string, string> headers;
            string? host = null;
            using (var watch = new S3Stall(ct, r.Timeout ?? TimeSpan.FromSeconds(60)))
            {
                using var req = MakeRequest(r, region, progress is null ? null : done => progress(done, total), watch.Kick);
                host = req.RequestUri!.Host;
                try
                {
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
                    watch.Kick();
                    status = (int)resp.StatusCode;
                    headers = HeadersOf(resp);
                    if (download is not null && status is >= 200 and < 300) await SaveAsync(resp, download, progress, watch).ConfigureAwait(false);
                    else if (download is not null) data = await ReadSomeAsync(resp, 64 * 1024, watch.Token).ConfigureAwait(false);
                    else data = await resp.Content.ReadAsByteArrayAsync(watch.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is not CloudException)
                {
                    if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                    var failure = watch.Stalled ? new TimeoutException("The request stalled.") : e;
                    if (!IsTransient(failure) || attempt >= MaxRetries) throw NetworkError(failure, host);
                    attempt++;
                    await PauseAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
            }
            var err = status >= 300 ? S3ErrorBody.Parse(data) : null;
            var line = $"s3 {r.Method} {Endpoint.Host} → {status}{(err is null ? "" : " " + err.Code)}";
            if (status is >= 200 and < 300 or 404) Log.Debug(line + $" ({(DateTimeOffset.UtcNow - started).TotalSeconds:0.00}s)"); else Log.Status(line);

            // This device's clock is off by more than 15 minutes: sign with the server's time instead (once).
            if (status == 403 && err?.Code is "RequestTimeTooSkewed" or "RequestExpired" && !skewFixed)
            {
                var server = S3Dates.Iso8601(err.ServerTime) ?? S3Dates.Http(headers.GetValueOrDefault("Date"));
                if (server is { } s)
                {
                    ClockOffset = s - DateTimeOffset.UtcNow;
                    Log.Status($"s3 clock offset {ClockOffset.TotalSeconds:0}s");
                    skewFixed = true;
                    continue;
                }
            }
            // The bucket lives in another region: sign for that region (once).
            if (r.Bucket is { } b && !regionFixed && status is 301 or 400
                && (headers.GetValueOrDefault("x-amz-bucket-region") ?? err?.Region)?.Trim() is { Length: > 0 } other && other != region)
            {
                SetRegion(other, b);
                regionFixed = true;
                continue;
            }
            var busy = status is 429 or 503 or 500 or 502 or 504 || (err is not null && RetryCodes.Contains(err.Code));
            if (busy)
            {
                if (attempt < MaxRetries)
                {
                    attempt++;
                    var d = Delay(attempt, headers.GetValueOrDefault("Retry-After"));
                    Log.Status($"s3 back-off {d:0.0}s after {status}");
                    await PauseAsync(d, ct).ConfigureAwait(false);
                    continue;
                }
                throw CloudException.Server($"{Endpoint.Host} is busy ({status}{(err is null ? "" : " " + err.Code)}). Try again in a few minutes.");
            }
            return new S3Response(status, data, headers, attempt > 0, err);
        }
    }

    static async Task SaveAsync(HttpResponseMessage resp, S3Download download, Action<long, long>? progress, S3Stall watch)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(download.Destination))!;
        Directory.CreateDirectory(dir);
        var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
        var total = resp.Content.Headers.ContentLength is long cl && cl > 0 ? cl : download.Expected;
        try
        {
            await using (var src = await resp.Content.ReadAsStreamAsync(watch.Token).ConfigureAwait(false))
            await using (var dst = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            {
                var buf = new byte[1 << 20];
                long done = 0;
                while (true)
                {
                    var n = await src.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                    if (n <= 0) break;
                    await dst.WriteAsync(buf.AsMemory(0, n), watch.Token).ConfigureAwait(false);
                    watch.Kick();
                    done += n;
                    progress?.Invoke(done, Math.Max(total, done));
                }
            }
            File.Move(part, download.Destination, overwrite: true);
        }
        finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }
    }

    static async Task<byte[]> ReadSomeAsync(HttpResponseMessage resp, int max, CancellationToken ct)
    {
        await using var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var buf = new byte[max];
        int n = 0;
        while (n < max)
        {
            var k = await src.ReadAsync(buf.AsMemory(n), ct).ConfigureAwait(false);
            if (k <= 0) break;
            n += k;
        }
        return buf[..n];
    }

    /// <summary>Dropped connections, unreachable hosts and stalls: worth another try (every S3 request Cirrus sends is safe to repeat).</summary>
    internal static bool IsTransient(Exception e) => e switch
    {
        TimeoutException => true,
        HttpRequestException h => h.HttpRequestError is HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError or HttpRequestError.ResponseEnded
            || (h.HttpRequestError is HttpRequestError.Unknown && h.InnerException is IOException or SocketException),
        HttpIOException => true,
        IOException io => io.InnerException is SocketException,
        _ => false,
    };

    static bool Offline() { try { return !NetworkInterface.GetIsNetworkAvailable(); } catch { return false; } }

    /// <summary>A network failure as a sentence (same wording as the Mac app).</summary>
    internal static CloudException NetworkError(Exception e, string? host)
    {
        var h = string.IsNullOrEmpty(host) ? "the server" : host;
        if (e is TimeoutException) return CloudException.Server($"“{h}” took too long to answer. Try again.");
        if (e is HttpRequestException hr)
        {
            switch (hr.HttpRequestError)
            {
                case HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError when Offline():
                    return CloudException.Server("This device is offline. Connect to the internet and try again.");
                case HttpRequestError.NameResolutionError:
                    return CloudException.Server($"Cirrus couldn’t find the server “{h}”. Check the address.");
                case HttpRequestError.ConnectionError:
                    return CloudException.Server($"“{h}” didn’t accept a connection. Check that the server is running and the address is right.");
                case HttpRequestError.SecureConnectionError:
                    return CloudException.Server($"The secure connection to “{h}” failed: its certificate isn’t trusted by this device. Check the server’s https setup.");
            }
        }
        return CloudException.Server($"The connection to “{h}” failed ({e.Message}).");
    }

    public double Delay(int attempt, string? retryAfter)
    {
        if (retryAfter?.Trim() is { Length: > 0 } ra)
        {
            if (double.TryParse(ra, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs)) return Math.Max(0, Math.Min(secs, 60));
            if (S3Dates.Http(ra) is { } date) return Math.Max(0, Math.Min((date - DateTimeOffset.UtcNow).TotalSeconds, 60));
        }
        var b = RetryBase;
        return Math.Min(b * Math.Pow(2, attempt - 1), 20) + System.Random.Shared.NextDouble() * Math.Max(b, 0.0001) * 0.5;
    }

    public static Task PauseAsync(double seconds, CancellationToken ct)
    {
        if (seconds <= 0) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        return Task.Delay(TimeSpan.FromSeconds(seconds), ct);
    }
}

/// <summary>SHA-256 and MD5 of a file or a slice of one, read 1 MiB at a time (never the whole file in memory).</summary>
static class S3Hash
{
    public sealed record Digests(string Sha256, string Md5, long Bytes);

    public static async Task<Digests> FileAsync(string path, CancellationToken ct)
    {
        await using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        var buf = new byte[1 << 20];
        long n = 0;
        while (true)
        {
            var k = await fs.ReadAsync(buf, ct).ConfigureAwait(false);
            if (k <= 0) break;
            sha.AppendData(buf, 0, k); md5.AppendData(buf, 0, k);
            n += k;
        }
        return new Digests(S3Signer.Hex(sha.GetHashAndReset()), S3Signer.Hex(md5.GetHashAndReset()), n);
    }

    /// <summary>Copies <paramref name="length"/> bytes at <paramref name="offset"/> of <paramref name="source"/> into a new temporary file, hashing them on the way.</summary>
    public static async Task<(string Path, Digests Digests)> SliceAsync(FileStream source, long offset, long length, CancellationToken ct)
    {
        var output = Paths.TempFile("s3-part");
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        var left = length;
        try
        {
            await using var w = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
            source.Seek(offset, SeekOrigin.Begin);
            var buf = new byte[1 << 20];
            while (left > 0)
            {
                ct.ThrowIfCancellationRequested();
                var k = await source.ReadAsync(buf.AsMemory(0, (int)Math.Min(left, buf.Length)), ct).ConfigureAwait(false);
                if (k <= 0) break;
                sha.AppendData(buf, 0, k); md5.AppendData(buf, 0, k);
                await w.WriteAsync(buf.AsMemory(0, k), ct).ConfigureAwait(false);
                left -= k;
            }
        }
        catch { RemoveTemp(output); throw; }
        return (output, new Digests(S3Signer.Hex(sha.GetHashAndReset()), S3Signer.Hex(md5.GetHashAndReset()), length - left));
    }

    /// <summary>Removes a <see cref="Paths.TempFile"/> and its own folder.</summary>
    public static void RemoveTemp(string path)
    {
        try { Directory.Delete(Path.GetDirectoryName(path)!, recursive: true); } catch { }
    }
}
