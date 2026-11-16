using System.Globalization;
using System.Net.NetworkInformation;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace Cirrus.Core;

// The wire layer shared by the Nextcloud and plain WebDAV flavours (port of WebDAVClient.swift): URL rules, path
// encoding, an HTTP client with Basic auth, retries and streaming transfers, and a namespace-aware PROPFIND
// (207 Multi-Status) parser. Nothing here logs a password, an Authorization header or a file path.
// URLs are kept as fully percent-encoded strings: System.Uri is only built at the last moment for the request, and
// never turned back into text with ToString() (which would unescape it).

// MARK: - URL rules and path encoding

static class DAVURL
{
    static readonly HashSet<string> LoopbackHosts = new(StringComparer.OrdinalIgnoreCase) { "localhost", "127.0.0.1", "::1", "[::1]" };

    public static bool IsLoopback(string host) => LoopbackHosts.Contains(host);

    /// <summary>https everywhere; plain http only to this device itself (a test server on localhost).</summary>
    public static void Check(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host))
            throw CloudException.NotConfigured($"“{url}” isn’t a server address Cirrus can use. Enter an address like https://cloud.example.com.");
        Check(u, url);
    }

    public static void Check(Uri url, string? text = null)
    {
        if (!url.IsAbsoluteUri || string.IsNullOrEmpty(url.Host) || string.IsNullOrEmpty(url.Scheme))
            throw CloudException.NotConfigured($"“{text ?? url.OriginalString}” isn’t a server address Cirrus can use. Enter an address like https://cloud.example.com.");
        var scheme = url.Scheme.ToLowerInvariant();
        if (scheme == "https") return;
        if (scheme == "http")
        {
            if (IsLoopback(url.Host)) return;
            throw CloudException.Unsupported("Cirrus connects only over https://, so your password and files are never sent unencrypted. "
                + "Use the server’s https:// address (plain http:// works only for a server on this device, such as localhost).");
        }
        throw CloudException.Unsupported($"Cirrus can’t connect to “{scheme}://” addresses. Use the server’s https:// address.");
    }

    /// <summary>
    /// RFC 3986 unreserved characters (ASCII letters, digits, - . _ ~) stay; everything else in a name is
    /// percent-encoded as UTF-8, including + &amp; ; = which some servers would otherwise read as something else.
    /// </summary>
    public static string EncodeSegment(string s) => Uri.EscapeDataString(s);

    /// <summary>"/a b/c#1/" → "/a%20b/c%231/" (keeps the leading and trailing slashes).</summary>
    public static string EncodePath(string path) => string.Join('/', path.Split('/').Select(EncodeSegment));

    public static string Decode(string s) => s.Contains('%') ? Uri.UnescapeDataString(s) : s;

    /// <summary><paramref name="baseURL"/> should end with "/"; <paramref name="path"/> is a decoded path starting with "/".</summary>
    public static string Join(string baseURL, string path)
    {
        var s = baseURL.EndsWith('/') ? baseURL : baseURL + "/";
        return s + EncodePath(path.TrimStart('/'));
    }

    /// <summary>The still-encoded path of a URL string ("/remote.php/dav/files/alex/"), without query or fragment.</summary>
    public static string EncodedPath(string url)
    {
        var s = url;
        var scheme = s.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0)
        {
            var slash = s.IndexOf('/', scheme + 3);
            s = slash < 0 ? "/" : s[slash..];
        }
        var q = s.IndexOfAny(['?', '#']);
        if (q >= 0) s = s[..q];
        return s.Length == 0 ? "/" : s;
    }

    /// <summary>The decoded path of a URL, keeping a trailing slash.</summary>
    public static string DecodedPath(string url) => Decode(EncodedPath(url));

    /// <summary>Collapses "//" and makes sure the path starts with "/".</summary>
    public static string Clean(string path)
    {
        var p = path;
        while (p.Contains("//", StringComparison.Ordinal)) p = p.Replace("//", "/", StringComparison.Ordinal);
        return p.StartsWith('/') ? p : "/" + p;
    }

    /// <summary>"/a/b" → "/a/b/" (cleaned).</summary>
    public static string FolderPathClean(string p)
    {
        var c = Clean(p);
        return c.EndsWith('/') ? c : c + "/";
    }

    public static string? Parent(string path)
    {
        if (path == "/") return null;
        var p = path.EndsWith('/') ? path[..^1] : path;
        var i = p.LastIndexOf('/');
        return i < 0 ? "/" : p[..(i + 1)];
    }

    public static string LastSegment(string path)
    {
        var p = path.EndsWith('/') ? path[..^1] : path;
        var i = p.LastIndexOf('/');
        return i < 0 ? p : p[(i + 1)..];
    }

    public static string TrimmedSlash(string path)
    {
        var p = path;
        while (p.Length > 1 && p.EndsWith('/')) p = p[..^1];
        return p;
    }

    /// <summary>Scheme, host and (explicit) port: "https://cloud.example.com:8443".</summary>
    public static string Origin(Uri u) =>
        u.Scheme.ToLowerInvariant() + "://" + u.Host.ToLowerInvariant() + (u.IsDefaultPort ? "" : ":" + u.Port.ToString(CultureInfo.InvariantCulture));

    public static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : "";

    /// <summary>Precomposed Unicode (how names are shown and compared; paths keep the server's own spelling).</summary>
    public static string NFC(string s)
    {
        try { return s.IsNormalized(NormalizationForm.FormC) ? s : s.Normalize(NormalizationForm.FormC); }
        catch (ArgumentException) { return s; }   // invalid UTF-16 (a lone surrogate): keep as is
    }
}

// MARK: - HTTP client

/// <summary>A request body: none, bytes, a file, or a part of a file (a chunk).</summary>
abstract record DAVBody
{
    public sealed record None : DAVBody;
    public sealed record Bytes(byte[] Data) : DAVBody;
    public sealed record File(string Path) : DAVBody;
    public sealed record FileRange(string Path, long Offset, long Length) : DAVBody;
    public static readonly DAVBody Empty = new None();
}

/// <summary><c>Safe</c>: idempotent, retried after 429, 502–504 and dropped connections. <c>RateLimitOnly</c>: may have
/// taken effect, so retried only when the server certainly didn't act (429, never connected).</summary>
enum DAVRetry { Safe, RateLimitOnly }

sealed class DAVResponse
{
    public int Status { get; }
    public byte[] Data { get; }
    /// <summary>True when this answer came after a retry (the first attempt may have reached the server).</summary>
    public bool Retried { get; }
    readonly Dictionary<string, string> _headers;

    public DAVResponse(int status, byte[] data, Dictionary<string, string> headers, bool retried)
    {
        Status = status; Data = data; _headers = headers; Retried = retried;
    }

    public string? Header(string name) => _headers.TryGetValue(name, out var v) ? v : null;
    public bool Ok => Status is >= 200 and < 300;

    internal static Dictionary<string, string> Headers(HttpResponseMessage r)
    {
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in r.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        foreach (var kv in r.Content.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        return h;
    }
}

/// <summary>Restarts a timer whenever bytes move; fires when they stop for the request's timeout.</summary>
sealed class DAVStall : IDisposable
{
    readonly CancellationTokenSource _cts;
    readonly CancellationToken _outer;
    readonly TimeSpan _timeout;
    public DAVStall(TimeSpan timeout, CancellationToken outer)
    {
        _outer = outer; _timeout = timeout;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(outer);
        Kick();
    }
    public CancellationToken Token => _cts.Token;
    public void Kick() { try { _cts.CancelAfter(_timeout); } catch (ObjectDisposedException) { } }
    public bool Stalled => _cts.IsCancellationRequested && !_outer.IsCancellationRequested;
    public void Dispose() => _cts.Dispose();
}

/// <summary>A read-only window on a file (one chunk of a chunked upload).</summary>
sealed class DAVRangeStream : Stream
{
    readonly FileStream _fs;
    readonly long _length;
    long _read;

    public DAVRangeStream(string path, long offset, long length)
    {
        _fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        _fs.Seek(offset, SeekOrigin.Begin);
        _length = length;
    }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => _length;
    public override long Position { get => _read; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    public override int Read(byte[] buffer, int offset, int count)
    {
        var n = _fs.Read(buffer, offset, (int)Math.Min(count, _length - _read));
        _read += n;
        return n;
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
    {
        var want = (int)Math.Min(buffer.Length, _length - _read);
        if (want <= 0) return 0;
        var n = await _fs.ReadAsync(buffer[..want], ct).ConfigureAwait(false);
        _read += n;
        return n;
    }

    protected override void Dispose(bool disposing) { if (disposing) _fs.Dispose(); base.Dispose(disposing); }
}

sealed class DAVClient
{
    public static string UserAgent => "Cirrus (Windows)";
    /// <summary>No answer (or no bytes moving) for this long: the request failed with a network error.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(60);

    readonly HttpClient _http;
    readonly string? _authorization;
    readonly object _lock = new();
    double _retryBase = 0.5;

    /// <summary>For error messages: "Nextcloud (alex@cloud.example.com)".</summary>
    public string ServiceName { get; }
    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get { lock (_lock) return _retryBase; } set { lock (_lock) _retryBase = value; } }
    public int MaxRetries { get; set; } = 4;

    public DAVClient(string? username, string? password, string serviceName, HttpMessageHandler? transport)
    {
        if (!string.IsNullOrEmpty(username))
            _authorization = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(username + ":" + (password ?? "")));
        ServiceName = serviceName;
        _http = CloudBackends.Http(transport);
    }

    HttpRequestMessage Build(string method, string url, IReadOnlyDictionary<string, string>? headers, DAVBody body, Action<long>? sent, Action kick)
    {
        var req = new HttpRequestMessage(new HttpMethod(method), new Uri(url, UriKind.Absolute));
        req.Content = body switch
        {
            DAVBody.Bytes b => new ProgressContent(() => new MemoryStream(b.Data, writable: false), b.Data.Length, sent, kick),
            DAVBody.File f => new ProgressContent(() => new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true),
                new FileInfo(f.Path).Length, sent, kick),
            DAVBody.FileRange r => new ProgressContent(() => new DAVRangeStream(r.Path, r.Offset, r.Length), r.Length, sent, kick),
            _ => null,
        };
        if (headers is not null)
            foreach (var (k, v) in headers)
            {
                if (req.Headers.TryAddWithoutValidation(k, v)) continue;
                if (req.Content is null) continue;     // a content header on a request without a body
                req.Content.Headers.Remove(k);
                req.Content.Headers.TryAddWithoutValidation(k, v);
            }
        if (_authorization is not null) req.Headers.TryAddWithoutValidation("Authorization", _authorization);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        return req;
    }

    static long BodyLength(DAVBody body) => body switch
    {
        DAVBody.Bytes b => b.Data.Length,
        DAVBody.File f => new FileInfo(f.Path).Length,
        DAVBody.FileRange r => r.Length,
        _ => 0,
    };

    static async Task<byte[]> ReadAllAsync(HttpContent content, DAVStall stall, long limit = long.MaxValue)
    {
        await using var src = await content.ReadAsStreamAsync(stall.Token).ConfigureAwait(false);
        using var ms = new MemoryStream();
        var buf = new byte[1 << 16];
        while (ms.Length < limit)
        {
            var n = await src.ReadAsync(buf, stall.Token).ConfigureAwait(false);
            if (n <= 0) break;
            ms.Write(buf, 0, n);
            stall.Kick();
        }
        return ms.ToArray();
    }

    /// <summary>
    /// One request with retries. 401 → sign in again, 423 → denied (locked), 507 → quota exceeded; every other status
    /// comes back to the caller, who knows what it means for that operation.
    /// </summary>
    public async Task<DAVResponse> SendAsync(string method, string url, IReadOnlyDictionary<string, string>? headers = null, DAVBody? body = null,
        DAVRetry retry = DAVRetry.Safe, TimeSpan? timeout = null, Action<long, long>? progress = null, long total = 0, CancellationToken ct = default)
    {
        body ??= DAVBody.Empty;
        var host = DAVURL.Host(url);
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var started = DateTimeOffset.UtcNow;
            DAVResponse r;
            using (var stall = new DAVStall(timeout ?? DefaultTimeout, ct))
            {
                try
                {
                    var length = progress is null ? 0 : BodyLength(body);
                    Action<long>? sent = progress is null ? null : done => progress(done, length > 0 ? length : total);
                    using var req = Build(method, url, headers, body, sent, stall.Kick);
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false);
                    stall.Kick();
                    var data = await ReadAllAsync(resp.Content, stall).ConfigureAwait(false);
                    r = new DAVResponse((int)resp.StatusCode, data, DAVResponse.Headers(resp), attempt > 0);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is not CloudException)
                {
                    var err = e is OperationCanceledException && stall.Stalled ? new TimeoutException("The server didn’t answer in time.") : e;
                    if (!GoogleHttp.IsTransient(err, ambiguousOK: retry == DAVRetry.Safe) || attempt >= MaxRetries) throw NetworkError(err, host);
                    attempt++;
                    await PauseAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
            }
            var status = r.Status;
            var line = $"dav {method} {host} → {status}";
            if (status is >= 200 and < 400 or 404) Log.Debug(line + $" ({(DateTimeOffset.UtcNow - started).TotalSeconds:0.00}s)"); else Log.Status(line);
            if (status == 429 || (retry == DAVRetry.Safe && status is 502 or 503 or 504))
            {
                if (attempt < MaxRetries)
                {
                    attempt++;
                    var d = Delay(attempt, r.Header("Retry-After"));
                    Log.Status($"dav back-off {d.ToString("0.0", CultureInfo.InvariantCulture)}s after {status}");
                    await PauseAsync(d, ct).ConfigureAwait(false);
                    continue;
                }
                throw CloudException.Server($"The server is busy ({status}{DAVErrorBody.Suffix(r.Data)}). Try again in a few minutes.");
            }
            CheckCommon(r, ServiceName);
            return r;
        }
    }

    public static void CheckCommon(DAVResponse r, string serviceName)
    {
        switch (r.Status)
        {
            case 401: throw CloudException.SignInNeeded(serviceName);
            case 423: throw CloudException.Denied("The item is locked on the server (it may be open in another app). Try again later.");
            case 507: throw CloudException.QuotaExceeded(serviceName);
        }
    }

    /// <summary>
    /// Streams a GET into a temporary file next to <paramref name="destination"/> (never held in memory) and moves it
    /// into place when complete. Error answers come back with the first 64 KB of their body.
    /// </summary>
    public async Task<DAVResponse> DownloadAsync(string url, string destination, long expected, Action<long, long>? progress, CancellationToken ct)
    {
        var host = DAVURL.Host(url);
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            DAVResponse r;
            using (var stall = new DAVStall(DefaultTimeout, ct))
            {
                try
                {
                    using var req = Build("GET", url, new Dictionary<string, string> { ["Accept-Encoding"] = "identity" }, DAVBody.Empty, null, stall.Kick);
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false);
                    stall.Kick();
                    var status = (int)resp.StatusCode;
                    Log.Debug($"dav GET (download) {host} → {status}");
                    if (status is >= 200 and < 300)
                    {
                        var total = resp.Content.Headers.ContentLength is long cl && cl > 0 ? cl : expected;
                        var dir = Path.GetDirectoryName(Path.GetFullPath(destination))!;
                        Directory.CreateDirectory(dir);
                        var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
                        try
                        {
                            await using (var src = await resp.Content.ReadAsStreamAsync(stall.Token).ConfigureAwait(false))
                            await using (var dst = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                            {
                                var buf = new byte[1 << 20];
                                long done = 0;
                                while (true)
                                {
                                    var n = await src.ReadAsync(buf, stall.Token).ConfigureAwait(false);
                                    if (n <= 0) break;
                                    await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                                    stall.Kick();
                                    done += n;
                                    progress?.Invoke(done, total > 0 ? total : done);
                                }
                            }
                            File.Move(part, destination, overwrite: true);
                        }
                        finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }
                        return new DAVResponse(status, [], DAVResponse.Headers(resp), attempt > 0);
                    }
                    // An error page: keep a little of it for the message.
                    r = new DAVResponse(status, await ReadAllAsync(resp.Content, stall, 64 * 1024).ConfigureAwait(false), DAVResponse.Headers(resp), attempt > 0);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is not CloudException)
                {
                    var err = e is OperationCanceledException && stall.Stalled ? new TimeoutException("The download stalled.") : e;
                    if (!GoogleHttp.IsTransient(err, ambiguousOK: true) || attempt >= MaxRetries) throw NetworkError(err, host);
                    attempt++;
                    await PauseAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
            }
            if (r.Status is 429 or 502 or 503 or 504 && attempt < MaxRetries)
            {
                attempt++;
                await PauseAsync(Delay(attempt, r.Header("Retry-After")), ct).ConfigureAwait(false);
                continue;
            }
            Log.Status($"dav GET (download) {host} → {r.Status}");
            CheckCommon(r, ServiceName);
            return r;
        }
    }

    public double Delay(int attempt, string? retryAfter)
    {
        if (retryAfter?.Trim() is { Length: > 0 } ra)
        {
            if (double.TryParse(ra, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs)) return Math.Max(0, Math.Min(secs, 120));
            if (DAVDates.Http(ra) is { } date) return Math.Max(0, Math.Min((date - DateTimeOffset.UtcNow).TotalSeconds, 120));
        }
        var b = RetryBase;
        return Math.Min(b * Math.Pow(2, attempt - 1), 30) + System.Random.Shared.NextDouble() * Math.Max(b, 0.0001) * 0.5;
    }

    static Task PauseAsync(double seconds, CancellationToken ct)
    {
        if (seconds <= 0) { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        return Task.Delay(TimeSpan.FromSeconds(seconds), ct);
    }

    /// <summary>A network failure, in words a user can act on.</summary>
    public static CloudException NetworkError(Exception e, string? host)
    {
        var h = string.IsNullOrEmpty(host) ? "the server" : host;
        if (e is TimeoutException) return CloudException.Server($"“{h}” took too long to answer. Try again.");
        if (e is HttpRequestException hr)
        {
            bool offline = false;
            try { offline = !NetworkInterface.GetIsNetworkAvailable(); } catch { }
            switch (hr.HttpRequestError)
            {
                case HttpRequestError.NameResolutionError:
                    return offline ? Offline() : CloudException.Server($"Cirrus couldn’t find the server “{h}”. Check the address.");
                case HttpRequestError.ConnectionError:
                    return offline ? Offline() : CloudException.Server($"“{h}” didn’t accept a connection. Check that the server is running and the address is right.");
                case HttpRequestError.SecureConnectionError:
                    return CloudException.Server($"The secure connection to “{h}” failed: its certificate isn’t trusted by this device. Check the server’s https setup.");
            }
        }
        return CloudException.Server($"The connection to “{h}” failed ({e.Message}).");

        static CloudException Offline() => CloudException.Server("This device is offline. Connect to the internet and try again.");
    }
}

// MARK: - Dates

static class DAVDates
{
    static readonly string[] Formats =
    [
        "dd MMM yyyy HH:mm:ss", "d MMM yyyy HH:mm:ss", "dd-MMM-yy HH:mm:ss", "d-MMM-yy HH:mm:ss", "dd-MMM-yyyy HH:mm:ss", "MMM d HH:mm:ss yyyy",
    ];

    /// <summary>
    /// RFC 1123 (getlastmodified, Last-Modified, Retry-After), with the older RFC 850 / asctime forms as fallbacks.
    /// The weekday is ignored (some servers get it wrong).
    /// </summary>
    public static DateTimeOffset? Http(string? s)
    {
        var t = string.Join(' ', (s ?? "").Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries));
        if (t.Length == 0) return null;
        // "Sun, 06 Nov 1994 …" / "Sunday, 06-Nov-94 …" / "Sun Nov  6 08:49:37 1994".
        var comma = t.IndexOf(',');
        if (comma > 0 && t[..comma].All(char.IsAsciiLetter)) t = t[(comma + 1)..].TrimStart();
        else if (t.Length > 4 && t[3] == ' ' && t[..3].All(char.IsAsciiLetter) && char.IsAsciiLetter(t[4])) t = t[4..];
        var offset = TimeSpan.Zero;
        var parts = t.Split(' ');
        var last = parts[^1];
        if (last is "GMT" or "UTC" or "UT" or "Z") t = string.Join(' ', parts[..^1]);
        else if (last.Length == 5 && last[0] is '+' or '-' && last[1..].All(char.IsAsciiDigit))
        {
            var mins = int.Parse(last[1..3], CultureInfo.InvariantCulture) * 60 + int.Parse(last[3..], CultureInfo.InvariantCulture);
            offset = TimeSpan.FromMinutes(last[0] == '-' ? -mins : mins);
            t = string.Join(' ', parts[..^1]);
        }
        if (!DateTime.TryParseExact(t, Formats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var d)) return null;
        return new DateTimeOffset(DateTime.SpecifyKind(d, DateTimeKind.Unspecified), offset).ToUniversalTime();
    }

    public static string HttpString(DateTimeOffset d) => d.UtcDateTime.ToString("r", CultureInfo.InvariantCulture);

    /// <summary>RFC 3339 (creationdate).</summary>
    public static DateTimeOffset? Iso8601(string? s)
    {
        var t = (s ?? "").Trim();
        if (t.Length == 0) return null;
        if (t.Length >= 10 && char.IsAsciiDigit(t[0]) && t[4] == '-'
            && DateTimeOffset.TryParse(t, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d))
            return d;
        return Http(t);
    }

    /// <summary>"2026-09-21T14:13:20Z": whole seconds, which the Mac app's decoder also reads.</summary>
    public static string IsoString(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}

// MARK: - Multi-Status parsing

static class DAVNS
{
    public const string Dav = "DAV:";
    public const string OC = "http://owncloud.org/ns";
    public const string NC = "http://nextcloud.org/ns";
}

/// <summary>One &lt;response&gt; of a 207 Multi-Status reply.</summary>
sealed class DAVResource
{
    public string Href { get; set; } = "";
    /// <summary>Props from the 200 propstat(s), keyed "namespace local" (e.g. "DAV: getetag").</summary>
    public Dictionary<string, string> Props { get; } = new(StringComparer.Ordinal);
    public bool IsCollection { get; set; }
    /// <summary>The &lt;status&gt; directly inside &lt;response&gt; (when the whole response failed, e.g. 404).</summary>
    public int? Status { get; set; }
    /// <summary>Resolved, percent-decoded path (set by <see cref="DAVMultistatus.Parse"/>).</summary>
    public string Path { get; set; } = "";

    public string? Prop(string ns, string name) => Props.TryGetValue(ns + " " + name, out var v) ? v : null;
    public string? Dav(string name) => Prop(DAVNS.Dav, name);
    public string? OC(string name) => Prop(DAVNS.OC, name);
    public string? NC(string name) => Prop(DAVNS.NC, name);

    static long? Long(string? s) => long.TryParse(s?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null;

    public long Size => Long(Dav("getcontentlength")) ?? Long(OC("size")) ?? 0;
    public DateTimeOffset? Modified => DAVDates.Http(Dav("getlastmodified"));
    public DateTimeOffset? Created => Dav("creationdate") is { } c ? DAVDates.Iso8601(c) : null;
    public string? Etag
    {
        get
        {
            var e = Dav("getetag")?.Trim();
            if (string.IsNullOrEmpty(e)) return null;
            if (e.StartsWith("W/", StringComparison.Ordinal)) e = e[2..];
            if (e.Length >= 2 && e[0] == '"' && e[^1] == '"') e = e[1..^1];
            return e;
        }
    }
    public string? FileID => OC("fileid")?.Trim() is { Length: > 0 } f ? f : null;
    public bool? HasPreview => NC("has-preview") is { } p ? p.Trim().Equals("true", StringComparison.OrdinalIgnoreCase) : null;
    public bool IsShared => !string.IsNullOrWhiteSpace(OC("share-types"));
}

static class DAVMultistatus
{
    internal static XmlReaderSettings ReaderSettings => new()
    {
        DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, IgnoreComments = true, IgnoreProcessingInstructions = true, CloseInput = true,
    };

    /// <summary>The element's namespace, with "no namespace" read as DAV: (like the Mac app).</summary>
    static string NS(XElement e) => e.Name.NamespaceName.Length == 0 ? DAVNS.Dav : e.Name.NamespaceName;

    static bool IsDav(XElement e, string local) => e.Name.LocalName == local && NS(e) == DAVNS.Dav;

    public static int? StatusCode(string line)
    {
        // "HTTP/1.1 200 OK"
        var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var s) ? s : null;
    }

    static string TrailingText(XElement e)
    {
        var sb = new StringBuilder();
        for (var n = e.LastNode; n is XText t; n = n.PreviousNode) sb.Insert(0, t.Value);
        return sb.ToString();
    }

    /// <summary>
    /// A property's value: its text, or for structured ones the nested &lt;href&gt; (current-user-principal) or the
    /// nested texts comma-joined (&lt;oc:share-types&gt;&lt;oc:share-type&gt;3&lt;/oc:share-type&gt;&lt;/oc:share-types&gt;).
    /// </summary>
    static string Value(XElement p)
    {
        if (!p.HasElements) return p.Value;
        string? href = null;
        var texts = new List<string>();
        foreach (var d in p.Descendants())
        {
            if (d.HasElements) continue;
            var t = d.Value.Trim();
            if (IsDav(d, "href")) href = t;
            else if (t.Length > 0) texts.Add(t);
        }
        return href ?? (texts.Count == 0 ? TrailingText(p) : string.Join(',', texts));
    }

    /// <summary>Parses a 207 body; throws when it isn't a complete Multi-Status document. <paramref name="requestURL"/> resolves relative hrefs.</summary>
    public static List<DAVResource> Parse(byte[] data, string requestURL)
    {
        XDocument doc;
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(data, writable: false), ReaderSettings);
            doc = XDocument.Load(reader);
        }
        catch (XmlException) { doc = new XDocument(); }
        var ms = doc.Root is { } root ? root.DescendantsAndSelf().FirstOrDefault(e => IsDav(e, "multistatus")) : null;
        if (ms is null) throw CloudException.Server("The server’s folder listing was incomplete or unreadable, so nothing was shown. Try again.");
        var output = new List<DAVResource>();
        foreach (var resp in ms.Elements().Where(e => IsDav(e, "response")))
        {
            var r = new DAVResource();
            foreach (var child in resp.Elements())
            {
                if (IsDav(child, "href")) r.Href = child.Value.Trim();
                else if (IsDav(child, "status")) r.Status = StatusCode(child.Value);
                else if (IsDav(child, "propstat"))
                {
                    var st = child.Elements().FirstOrDefault(e => IsDav(e, "status")) is { } s ? StatusCode(s.Value) : null;
                    if ((st ?? 200) != 200) continue;
                    foreach (var prop in child.Elements().Where(e => IsDav(e, "prop")))
                        foreach (var p in prop.Elements())
                        {
                            r.Props[NS(p) + " " + p.Name.LocalName] = Value(p);
                            if (p.Descendants().Any(d => IsDav(d, "collection"))) r.IsCollection = true;
                        }
                }
            }
            r.Path = Resolve(r.Href, requestURL);
            output.Add(r);
        }
        return output;
    }

    /// <summary>Absolute URL, absolute path or relative reference → percent-decoded path (server form, not normalized).</summary>
    public static string Resolve(string href, string baseURL)
    {
        var h = href.Trim();
        string encoded;
        var scheme = h.IndexOf("://", StringComparison.Ordinal);
        if (scheme > 0 && h[..scheme].All(c => char.IsAsciiLetterOrDigit(c) || c is '+' or '-' or '.'))
        {
            var slash = h.IndexOf('/', scheme + 3);
            encoded = slash < 0 ? "/" : h[slash..];
        }
        else if (h.StartsWith("//", StringComparison.Ordinal))
        {
            var slash = h.IndexOf('/', 2);
            encoded = slash < 0 ? "/" : h[slash..];
        }
        else if (h.StartsWith('/')) encoded = h;
        else
        {
            var bp = DAVURL.EncodedPath(baseURL);
            encoded = bp[..(bp.LastIndexOf('/') + 1)] + h;
        }
        var q = encoded.IndexOfAny(['?', '#']);
        if (q >= 0) encoded = encoded[..q];
        var decoded = DAVURL.Decode(encoded);
        // Resolve "." and ".." segments, keep a trailing slash.
        var trailing = decoded.EndsWith('/');
        var output = new List<string>();
        foreach (var seg in decoded.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (seg == ".") continue;
            if (seg == "..") { if (output.Count > 0) output.RemoveAt(output.Count - 1); continue; }
            output.Add(seg);
        }
        var joined = "/" + string.Join('/', output);
        return trailing && joined != "/" ? joined + "/" : joined;
    }
}

/// <summary>Sabre/Nextcloud error bodies: &lt;d:error&gt;&lt;s:message&gt;…&lt;/s:message&gt;&lt;/d:error&gt;.</summary>
static class DAVErrorBody
{
    public static string? Message(byte[] data)
    {
        if (data.Length == 0 || data.Length >= 256 * 1024) return null;
        string? message = null;
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(data, writable: false), DAVMultistatus.ReaderSettings);
            while (message is null && reader.Read())
                if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "message")
                    message = reader.IsEmptyElement ? "" : (XNode.ReadFrom(reader) as XElement)?.Value;
        }
        catch (XmlException) { }
        var m = message?.Trim();
        if (string.IsNullOrEmpty(m)) return null;
        return m.Length > 300 ? m[..300] : m;
    }

    public static string Suffix(byte[] data) => Message(data) is { } m ? ": " + m : "";
}
