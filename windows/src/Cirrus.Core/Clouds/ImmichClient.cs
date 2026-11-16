using System.Globalization;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>
/// <c>Safe</c>: idempotent, retried after 429, 502–504 and dropped connections. <c>RateLimitOnly</c>: may have taken
/// effect, so retried only when the server certainly didn't act (429, never connected).
/// </summary>
enum ImmichRetry { Safe, RateLimitOnly }

/// <summary>A finished exchange: status, body and headers (content headers included).</summary>
sealed class ImmichResponse(int status, byte[] data, Dictionary<string, string> headers)
{
    public int Status { get; } = status;
    public byte[] Data { get; } = data;
    public bool Ok => Status is >= 200 and < 300;
    public string? Header(string name) => headers.TryGetValue(name, out var v) ? v : null;

    internal static ImmichResponse From(HttpResponseMessage r, byte[] data)
    {
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in r.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        foreach (var kv in r.Content.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        return new ImmichResponse((int)r.StatusCode, data, h);
    }
}

/// <summary>
/// The wire layer for Immich (port of ImmichClient.swift): JSON calls under <c>&lt;server&gt;/api</c> with the
/// <c>x-api-key</c> header, retries with back-off (429, 502–504, dropped connections), streaming downloads to disk,
/// streamed multipart uploads from disk, and Immich's error bodies mapped to <see cref="CloudException"/>. Redirects are
/// never followed (the key must not travel to another host). Nothing here logs the API key, a query string or a file name.
/// </summary>
sealed class ImmichClient : IDisposable
{
    public const string UserAgent = "Cirrus (Windows)";

    /// <summary>No answer (or no bytes moving) for this long → the request failed with a network error.</summary>
    public static TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(60);

    public Uri Server { get; }
    public string ApiBase { get; }
    public string? ApiKey { get; }
    /// <summary>For messages: "Immich (alex@example.com)".</summary>
    public string ServiceName { get; }
    readonly HttpClient _http;
    double _retryBase = 0.5;
    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get => Volatile.Read(ref _retryBase); set => Volatile.Write(ref _retryBase, value); }
    public int MaxRetries { get; set; } = 4;

    public ImmichClient(Uri server, string? apiKey, string serviceName, HttpMessageHandler? transport)
    {
        Server = server;
        ApiBase = ImmichCloud.ServerString(server) + "/api";
        ApiKey = apiKey;
        ServiceName = serviceName;
        _http = CloudBackends.Http(transport);
    }

    public void Dispose() => _http.Dispose();

    /// <summary><paramref name="path"/> starts with "/" and may carry its own query ("/assets/x/thumbnail?size=preview").</summary>
    public string Url(string path, IReadOnlyDictionary<string, string>? query = null)
    {
        var u = ApiBase + path;
        if (query is { Count: > 0 })
            u += (u.Contains('?') ? "&" : "?") + string.Join('&', query.OrderBy(k => k.Key, StringComparer.Ordinal)
                .Select(kv => Uri.EscapeDataString(kv.Key) + "=" + Uri.EscapeDataString(kv.Value)));
        return u;
    }

    HttpRequestMessage Build(string method, string url, IReadOnlyDictionary<string, string>? headers, HttpContent? content)
    {
        var req = new HttpRequestMessage(new HttpMethod(method), url) { Content = content };
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        if (headers is not null)
            foreach (var (k, v) in headers)
            {
                if (k.Equals("Accept", StringComparison.OrdinalIgnoreCase)) req.Headers.Remove("Accept");
                if (!req.Headers.TryAddWithoutValidation(k, v))
                {
                    req.Content ??= new ByteArrayContent([]);
                    req.Content.Headers.Remove(k);
                    req.Content.Headers.TryAddWithoutValidation(k, v);
                }
            }
        if (ApiKey is { } key) req.Headers.TryAddWithoutValidation("x-api-key", key);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        return req;
    }

    /// <summary>The path for logs: no query, ids shortened.</summary>
    internal static string LogPath(string path)
    {
        var p = path.Split('?', 2)[0];
        return string.Join('/', p.Split('/').Select(s => s.Length == 36 && s.Count(c => c == '-') == 4 ? "…" : s));
    }

    /// <summary>A JSON body (a fresh content for every attempt).</summary>
    static Func<Action<long>, Action, HttpContent> JsonBody(JsonNode json)
    {
        var bytes = Jx.Bytes(json);
        return (_, _) =>
        {
            var c = new ByteArrayContent(bytes);
            c.Headers.TryAddWithoutValidation("Content-Type", "application/json");
            return c;
        };
    }

    /// <summary>
    /// One request with retries. Every status comes back to the caller except the retried ones that ran out.
    /// <paramref name="body"/> builds the request body for each attempt (bytes-sent callback, keep-alive callback).
    /// </summary>
    public async Task<ImmichResponse> SendAsync(string method, string path, IReadOnlyDictionary<string, string>? query = null, JsonNode? json = null,
        Func<Action<long>, Action, HttpContent>? body = null, IReadOnlyDictionary<string, string>? headers = null, ImmichRetry retry = ImmichRetry.Safe,
        Action<long>? sent = null, CancellationToken ct = default)
    {
        if (json is not null) body = JsonBody(json);
        var url = Url(path, query);
        var attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var started = DateTimeOffset.UtcNow;
            ImmichResponse r;
            using (var watch = new ImmichStall(ct))
            {
                // Built outside the network handling: a local file problem (gone, unreadable) is not a connection failure.
                using var req = Build(method, url, headers, body?.Invoke(n => sent?.Invoke(n), watch.Kick));
                try
                {
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
                    watch.Kick();
                    r = ImmichResponse.From(resp, await resp.Content.ReadAsByteArrayAsync(watch.Token).ConfigureAwait(false));
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is not CloudException)
                {
                    var failure = watch.Stalled ? new TimeoutException("Immich didn’t answer in time.") : e;
                    var again = retry == ImmichRetry.Safe ? GoogleHttp.IsTransient(failure, ambiguousOK: true) : GoogleHttp.NothingWasSent(failure);
                    if (!again || attempt >= MaxRetries) throw NetworkError(failure, new Uri(url).Host);
                    attempt++;
                    await PauseAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
            }
            var status = r.Status;
            var line = $"immich {method} {LogPath(path)} → {status}";
            if (status < 400 || status == 404) Log.Debug(line + $" ({(DateTimeOffset.UtcNow - started).TotalSeconds:0.00}s)"); else Log.Status(line);
            if (status == 401 && r.Header("WWW-Authenticate") is not null) throw ProxySignIn();
            if (status == 429 || (retry == ImmichRetry.Safe && status is 502 or 503 or 504))
            {
                if (attempt < MaxRetries)
                {
                    attempt++;
                    var wait = Delay(attempt, r.Header("Retry-After"));
                    Log.Status($"immich back-off {wait:0.0}s after {status}");
                    await PauseAsync(wait, ct).ConfigureAwait(false);
                    continue;
                }
                throw CloudException.Server($"The Immich server is busy ({status}). Try again in a few minutes.");
            }
            return r;
        }
    }

    /// <summary>The body as JSON (null for an empty body); null when it isn't JSON.</summary>
    internal static J? ParseJson(byte[] data)
    {
        if (data.Length == 0) return J.Null;
        try { return new J(JsonNode.Parse(data)); } catch (JsonException) { return null; }
    }

    /// <summary>A JSON call: 2xx → the parsed body (<see cref="J.Null"/> when empty), anything else → a <see cref="CloudException"/>.</summary>
    public async Task<J> CallAsync(string method, string path, IReadOnlyDictionary<string, string>? query = null, JsonNode? json = null,
        ImmichRetry retry = ImmichRetry.Safe, CancellationToken ct = default)
    {
        var r = await SendAsync(method, path, query, json, retry: retry, ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Failure(r);
        return ParseJson(r.Data) ?? throw CloudException.Server("Immich sent an answer Cirrus couldn’t read.");
    }

    /// <summary>Bytes of a small GET (thumbnails).</summary>
    public async Task<byte[]> FetchAsync(string path, CancellationToken ct = default)
    {
        var r = await SendAsync("GET", path, retry: ImmichRetry.Safe, ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Failure(r);
        return r.Data;
    }

    /// <summary>
    /// Streams a GET into <paramref name="destination"/> (never held in memory): into a temp file next to it, then moved
    /// into place, replacing what's there. Progress is (bytes done, total).
    /// </summary>
    public async Task DownloadAsync(string path, string destination, long expected, Action<long, long>? progress, CancellationToken ct = default)
    {
        var url = Url(path);
        var host = new Uri(url).Host;
        var attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var headers = new Dictionary<string, string> { ["Accept"] = "*/*", ["Accept-Encoding"] = "identity" };
            ImmichResponse? failed = null;
            using (var watch = new ImmichStall(ct))
            {
                var dir = Path.GetDirectoryName(Path.GetFullPath(destination))!;
                var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
                try
                {
                    using var req = Build("GET", url, headers, null);
                    using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
                    watch.Kick();
                    var status = (int)resp.StatusCode;
                    Log.Debug($"immich GET (download) {LogPath(path)} → {status}");
                    if (status is >= 200 and < 300)
                    {
                        var total = resp.Content.Headers.ContentLength is long cl && cl > 0 ? cl : expected;
                        Directory.CreateDirectory(dir);
                        await using (var src = await resp.Content.ReadAsStreamAsync(watch.Token).ConfigureAwait(false))
                        await using (var dst = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                        {
                            var buf = new byte[1 << 20];
                            long done = 0;
                            progress?.Invoke(0, total);
                            while (true)
                            {
                                var n = await src.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                                if (n <= 0) break;
                                await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                                watch.Kick();
                                done += n;
                                progress?.Invoke(done, Math.Max(total, done));
                            }
                        }
                        File.Move(part, destination, overwrite: true);
                        return;
                    }
                    // An error page: keep a little of it for the message.
                    var head = await resp.Content.ReadAsByteArrayAsync(watch.Token).ConfigureAwait(false);
                    failed = ImmichResponse.From(resp, head.Length > 64 * 1024 ? head[..(64 * 1024)] : head);
                    if (status == 401 && failed.Header("WWW-Authenticate") is not null) throw ProxySignIn();
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e) when (e is not CloudException and not UnauthorizedAccessException && (e is not IOException || e is HttpIOException || e.InnerException is System.Net.Sockets.SocketException))
                {
                    var failure = watch.Stalled ? new TimeoutException("Immich didn’t answer in time.") : e;
                    if (!GoogleHttp.IsTransient(failure, ambiguousOK: true) || attempt >= MaxRetries) throw NetworkError(failure, host);
                    attempt++;
                    await PauseAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                    continue;
                }
                finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }   // our own partial download
            }
            if (failed.Status is 429 or 502 or 503 or 504 && attempt < MaxRetries)
            {
                attempt++;
                await PauseAsync(Delay(attempt, failed.Header("Retry-After")), ct).ConfigureAwait(false);
                continue;
            }
            throw Failure(failed);
        }
    }

    // MARK: Errors

    /// <summary>An HTTP auth challenge: Immich itself never sends one, so it's a proxy in front of it.</summary>
    internal static CloudException ProxySignIn() => CloudException.Denied("The server in front of Immich asks for its own password, which Cirrus can’t answer. "
        + "Connect to Immich directly, or let the API path (/api) through the proxy without a sign-in.");

    /// <summary>A network failure → a sentence naming the host (never the path, query or key).</summary>
    internal static CloudException NetworkError(Exception e, string? host)
    {
        var h = string.IsNullOrEmpty(host) ? "the server" : host;
        if (e is TimeoutException || e is TaskCanceledException { InnerException: TimeoutException })
            return CloudException.Server($"“{h}” took too long to answer. Try again.");
        if (e is HttpRequestException hre)
        {
            switch (hre.HttpRequestError)
            {
                case HttpRequestError.NameResolutionError:
                    return Offline() ? CloudException.Server("This device is offline. Connect to the internet and try again.")
                        : CloudException.Server($"Cirrus couldn’t find the server “{h}”. Check the address.");
                case HttpRequestError.ConnectionError:
                    return Offline() ? CloudException.Server("This device is offline. Connect to the internet and try again.")
                        : CloudException.Server($"“{h}” didn’t accept a connection. Check that the server is running and the address is right.");
                case HttpRequestError.SecureConnectionError:
                    return CloudException.Server($"The secure connection to “{h}” failed: its certificate isn’t trusted by this device. Check the server’s https setup.");
            }
        }
        return CloudException.Server($"The connection to “{h}” failed ({e.Message}).");
    }

    static bool Offline()
    {
        try { return !NetworkInterface.GetIsNetworkAvailable(); } catch { return false; }
    }

    /// <summary>
    /// The message of an Immich error body: v3 <c>{"message": "…", "errors": [{"path", "message"}]}</c>, or the older
    /// <c>{"message": ["…"], "error": "Bad Request", "statusCode": 400}</c>.
    /// </summary>
    internal static string? Message(byte[] data)
    {
        if (ParseJson(data) is not { } j || j.IsNull) return null;
        var parts = new List<string>();
        var m = j["message"];
        if (m.Node is JsonArray) parts.AddRange(m.Array.Select(x => x.Node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? x.Str : null).OfType<string>());
        else if (m.Node is JsonValue mv && mv.GetValueKind() == JsonValueKind.String && m.Str is { } s) parts.Add(s);
        var details = j["errors"].Array.Select(e =>
        {
            if (e["message"].Str is not { } msg) return null;
            var p = e["path"];
            var path = p.Node is JsonArray ? string.Join('.', p.Array.Select(x => x.Str).OfType<string>()) : p.Node is JsonValue ? p.Str ?? "" : "";
            return path.Length == 0 ? msg : $"{path}: {msg}";
        }).OfType<string>().ToList();
        if (details.Count > 0) parts.Add(string.Join("; ", details.Take(3)));
        var text = string.Join(" — ", parts).Trim();
        return text.Length == 0 ? null : text.Length > 300 ? text[..300] : text;
    }

    public CloudException Failure(ImmichResponse r) => Failure(r.Status, r.Data, ServiceName);

    internal static CloudException Failure(int status, byte[] data, string serviceName)
    {
        var msg = Message(data);
        switch (status)
        {
            case 401:
                return CloudException.SignInNeeded(serviceName);
            case 403:
                if (msg is not null && msg.IndexOf("Missing required permission: ", StringComparison.Ordinal) is var i and >= 0)
                {
                    var perm = msg[(i + "Missing required permission: ".Length)..].Trim().Trim('.').Trim();
                    return CloudException.Denied($"The Immich API key isn’t allowed to do that: it’s missing the “{perm}” permission. "
                        + "In Immich, edit the key under Account Settings › API Keys to add it.");
                }
                return CloudException.Denied("Immich didn’t allow that" + (msg is null ? "" : $" ({msg})") + ".");
            case 404:
                return CloudException.NotFound();
            case 400:
                if (msg is not null && msg.Contains("quota", StringComparison.OrdinalIgnoreCase)) return CloudException.QuotaExceeded(serviceName);
                // "Unsupported file type <name>": keep the file name out of the message (and so out of any log).
                if (msg is not null && msg.StartsWith("Unsupported file type", StringComparison.Ordinal))
                    return CloudException.Unsupported("Immich doesn’t accept one of these files: its type isn’t supported.");
                if (msg is not null && msg.StartsWith("Not found or no ", StringComparison.Ordinal))
                    return CloudException.Denied("Immich couldn’t find that item, or the API key isn’t allowed to change it (it may belong to someone else).");
                return CloudException.Server("Immich refused the request" + (msg is null ? "" : $": {msg}") + ".");
            case 413:
                return CloudException.Server("The file is too large for the Immich server (or a proxy in front of it).");
            case >= 300 and < 400:
                return CloudException.Server($"The Immich server redirected Cirrus elsewhere ({status}). Check the server address in the account.");
            case >= 500 and < 600:
                return CloudException.Server($"The Immich server had a problem ({status}" + (msg is null ? "" : $": {msg}") + "). Try again later.");
            default:
                return CloudException.Server($"Immich answered {status}" + (msg is null ? "" : $": {msg}") + ".");
        }
    }

    // MARK: Back-off

    internal double Delay(int attempt, string? retryAfter)
    {
        if (retryAfter?.Trim() is { Length: > 0 } ra)
        {
            if (double.TryParse(ra, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs)) return Math.Max(0, Math.Min(secs, 120));
            if (DateTimeOffset.TryParse(ra, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date))
                return Math.Max(0, Math.Min((date - DateTimeOffset.UtcNow).TotalSeconds, 120));
        }
        var b = RetryBase;
        return Math.Min(b * Math.Pow(2, attempt - 1), 30) + Random.Shared.NextDouble() * Math.Max(b, 0.0001) * 0.5;
    }

    static Task PauseAsync(double seconds, CancellationToken ct) =>
        seconds <= 0 ? (ct.IsCancellationRequested ? Task.FromCanceled(ct) : Task.CompletedTask) : Task.Delay(TimeSpan.FromSeconds(seconds), ct);
}

/// <summary>Restarts a timer whenever bytes move; fires when they stop for <see cref="ImmichClient.RequestTimeout"/>.</summary>
sealed class ImmichStall : IDisposable
{
    readonly CancellationTokenSource _cts;
    readonly CancellationToken _outer;
    public ImmichStall(CancellationToken outer) { _outer = outer; _cts = CancellationTokenSource.CreateLinkedTokenSource(outer); Kick(); }
    public CancellationToken Token => _cts.Token;
    public void Kick() { try { _cts.CancelAfter(ImmichClient.RequestTimeout); } catch (ObjectDisposedException) { } }
    public bool Stalled => _cts.IsCancellationRequested && !_outer.IsCancellationRequested;
    public void Dispose() => _cts.Dispose();
}

/// <summary>Immich uploads: the SHA-1 checksum it dedupes by, and a streamed multipart/form-data body.</summary>
static class ImmichUpload
{
    /// <summary>SHA-1 of a file, base64 (Immich's checksum), read in pieces.</summary>
    public static async Task<string> Sha1Async(string file, CancellationToken ct)
    {
        await using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        var buf = new byte[4 << 20];
        while (true)
        {
            var n = await fs.ReadAsync(buf, ct).ConfigureAwait(false);
            if (n <= 0) break;
            sha.AppendData(buf, 0, n);
        }
        return Convert.ToBase64String(sha.GetHashAndReset());
    }

    static string Quoted(string s) => s.Replace("\r", " ").Replace("\n", " ").Replace("\"", "%22");

    /// <summary>
    /// A multipart/form-data body (text fields first, then the file) streamed from disk with a known length. Reports file
    /// bytes sent and keeps the stall timer alive.
    /// </summary>
    public sealed class MultipartContent : HttpContent
    {
        readonly byte[] _head, _tail;
        readonly string _file;
        readonly long _fileLength;
        readonly Action<long>? _sent;
        readonly Action _kick;

        public MultipartContent(IReadOnlyList<(string Name, string Value)> fields, string fileField, string file, string filename, string mime,
            string boundary, Action<long>? sent, Action kick)
        {
            var sb = new StringBuilder();
            foreach (var (k, v) in fields) sb.Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{Quoted(k)}\"\r\n\r\n{v}\r\n");
            sb.Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{Quoted(fileField)}\"; filename=\"{Quoted(filename)}\"\r\nContent-Type: {mime}\r\n\r\n");
            _head = Encoding.UTF8.GetBytes(sb.ToString());
            _tail = Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");
            _file = file;
            _fileLength = new FileInfo(file).Length;
            _sent = sent;
            _kick = kick;
            Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");
        }

        protected override Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) => SerializeToStreamAsync(stream, context, default);

        protected override async Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context, CancellationToken ct)
        {
            await stream.WriteAsync(_head, ct).ConfigureAwait(false);
            await using (var src = new FileStream(_file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true))
            {
                var buf = new byte[256 * 1024];
                long done = 0;
                while (true)
                {
                    var n = await src.ReadAsync(buf, ct).ConfigureAwait(false);
                    if (n <= 0) break;
                    await stream.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                    done += n;
                    _kick();
                    _sent?.Invoke(Math.Min(done, _fileLength));
                }
            }
            await stream.WriteAsync(_tail, ct).ConfigureAwait(false);
        }

        protected override bool TryComputeLength(out long length) { length = _head.Length + _fileLength + _tail.Length; return true; }
    }
}

/// <summary>Immich's timestamps ("2026-07-01T10:00:00.000Z").</summary>
static class ImmichDates
{
    public static DateTimeOffset? Parse(J j) => j.Str is { Length: > 0 } s && j.Node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? J.ParseIso(s) : null;

    public static string String(DateTimeOffset d) => d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
}
