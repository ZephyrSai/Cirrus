using System.Globalization;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

// Microsoft Graph transport for OneDrive (port of OneDriveHTTP.swift): token handling (single-flight refresh, refresh-token
// rotation) and requests with back-off. The bearer token only ever goes to graph.microsoft.com over https; download and
// upload-session URLs are pre-authenticated and get no Authorization header. Logs carry the method, host, route shape and
// status only: never tokens, query strings, file names or account names.

/// <summary>Tokens from Microsoft's token endpoint.</summary>
sealed record OneDriveTokenSet(string Access, string? Refresh, DateTimeOffset Expires);

/// <summary>
/// One account's tokens. Microsoft hands out a new refresh token with every refresh (and may stop accepting the old one),
/// so each new one goes to <see cref="OnNewRefreshToken"/> before anyone can refresh again.
/// </summary>
sealed class OneDriveTokens
{
    public string ClientID { get; }
    readonly HttpClient _http;
    readonly object _lock = new();
    string _refreshToken;
    string? _access;
    DateTimeOffset _expires = DateTimeOffset.MinValue;
    Task<string>? _refreshing;
    Action<string>? _onNew;

    public OneDriveTokens(string clientID, string refreshToken, HttpClient http, OneDriveTokenSet? initial = null)
    {
        ClientID = clientID;
        _refreshToken = refreshToken;
        _http = http;
        _access = initial?.Access;
        _expires = initial?.Expires ?? DateTimeOffset.MinValue;
    }

    public string CurrentRefreshToken { get { lock (_lock) return _refreshToken; } }

    public Action<string>? OnNewRefreshToken
    {
        get { lock (_lock) return _onNew; }
        set { lock (_lock) _onNew = value; }
    }

    /// <summary>
    /// A usable access token. <paramref name="stale"/> is one the server just refused (401): it is never handed out again.
    /// Every caller that needs a new token waits on the same refresh.
    /// </summary>
    public async Task<string> AccessTokenAsync(string? stale, CancellationToken ct)
    {
        Task<string> wait;
        lock (_lock)
        {
            if (_access is { } a && a != stale && _expires - DateTimeOffset.UtcNow > TimeSpan.FromSeconds(120)) return a;
            if (_refreshing is null || _refreshing.IsCompleted)
            {
                var rt = _refreshToken;
                // Not tied to the caller's token: one cancelled request must not cancel everyone's refresh.
                _refreshing = Task.Run(() => RunRefreshAsync(rt), CancellationToken.None);
            }
            wait = _refreshing;
        }
        return await wait.WaitAsync(ct).ConfigureAwait(false);
    }

    async Task<string> RunRefreshAsync(string rt)
    {
        try
        {
            var t = await OneDriveAuth.RedeemAsync(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token", ["refresh_token"] = rt, ["scope"] = string.Join(' ', OneDriveCloud.Scopes),
            }, ClientID, _http, signingIn: false, CancellationToken.None).ConfigureAwait(false);
            Action<string>? callback = null;
            lock (_lock)
            {
                _access = t.Access;
                _expires = t.Expires;
                if (t.Refresh is { Length: > 0 } n && n != _refreshToken)
                {
                    _refreshToken = n;
                    callback = _onNew;
                }
            }
            if (callback is not null && t.Refresh is { } fresh)
            {
                try { callback(fresh); } catch (Exception e) { Log.Status("onedrive: saving the new sign-in failed: " + e.GetType().Name); }
            }
            return t.Access;
        }
        finally
        {
            // Cleared only after the new refresh token was handed on, so refreshes (and saves) stay in order.
            lock (_lock) _refreshing = null;
        }
    }
}

/// <summary>What a request carries.</summary>
abstract record OneDriveBody
{
    public sealed record None : OneDriveBody;
    public sealed record Bytes(byte[] Data) : OneDriveBody;
    public sealed record File(string Path) : OneDriveBody;
    public static readonly OneDriveBody Empty = new None();
}

/// <summary>Whether a request may be repeated when its answer was lost.</summary>
enum GraphRetry { Safe, Unsafe }

/// <summary>A request description; a fresh <see cref="HttpRequestMessage"/> is built for every attempt.</summary>
sealed class GraphRequest
{
    public string Method { get; init; } = "GET";
    public string Url { get; init; } = "";
    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public OneDriveBody Body { get; init; } = OneDriveBody.Empty;

    /// <summary>A Graph request: <paramref name="query"/> is percent-encoded as Swift's URLComponents does ("$select", "@microsoft…" stay readable).</summary>
    public static GraphRequest Make(string method, string url, IReadOnlyList<(string, string)>? query = null, JsonNode? json = null)
    {
        var u = url;
        if (query is { Count: > 0 }) u += (u.Contains('?') ? "&" : "?") + OneDriveHttp.QueryString(query);
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "application/json" };
        OneDriveBody body = OneDriveBody.Empty;
        if (json is not null)
        {
            h["Content-Type"] = "application/json";
            body = new OneDriveBody.Bytes(Jx.Bytes(json));
        }
        return new GraphRequest { Method = method, Url = u, Headers = h, Body = body };
    }

    public GraphRequest With(OneDriveBody body, IReadOnlyDictionary<string, string>? headers = null)
    {
        var h = new Dictionary<string, string>(Headers, StringComparer.OrdinalIgnoreCase);
        if (headers is not null) foreach (var (k, v) in headers) h[k] = v;
        return new GraphRequest { Method = Method, Url = Url, Headers = h, Body = body };
    }

    internal HttpRequestMessage Build(string? accessToken, Action<long>? sent, Action kick)
    {
        var req = new HttpRequestMessage(new HttpMethod(Method), new Uri(Url));
        req.Content = Body switch
        {
            OneDriveBody.Bytes b => new ProgressContent(() => new MemoryStream(b.Data, writable: false), b.Data.Length, sent, kick),
            OneDriveBody.File f => new ProgressContent(() => new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true),
                new FileInfo(f.Path).Length, sent, kick),
            _ => Method is "POST" or "PUT" or "PATCH" ? new ByteArrayContent([]) : null,
        };
        foreach (var (k, v) in Headers)
        {
            if (k.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) || k.Equals("Authorization", StringComparison.OrdinalIgnoreCase)) continue;
            if (!req.Headers.TryAddWithoutValidation(k, v))
            {
                req.Content ??= new ByteArrayContent([]);
                req.Content.Headers.Remove(k);
                req.Content.Headers.TryAddWithoutValidation(k, v);
            }
        }
        if (accessToken is not null) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        return req;
    }
}

/// <summary>A finished exchange. Downloads (<c>toFile</c>) land in <see cref="File"/>; the caller moves or deletes it.</summary>
sealed class GraphResponse
{
    public int Status { get; }
    public Uri Url { get; }
    public byte[] Data { get; }
    public string? File { get; }
    readonly Dictionary<string, string> _headers;

    public GraphResponse(int status, Uri url, byte[] data, Dictionary<string, string> headers, string? file)
    {
        Status = status; Url = url; Data = data; _headers = headers; File = file;
    }

    public J Json => J.Parse(Data);
    public string? Header(string name) => _headers.TryGetValue(name, out var v) ? v : null;
    public double? RetryAfter => OneDriveHttp.ParseSeconds(Header("Retry-After"));
    public bool Ok => Status is >= 200 and < 300;

    /// <summary>Deletes a downloaded body.</summary>
    public void Discard()
    {
        if (File is { } f) { try { System.IO.File.Delete(f); } catch { } }
    }
}

sealed class OneDriveHttp
{
    public const string Graph = "https://graph.microsoft.com/v1.0";
    public const string GraphHost = "graph.microsoft.com";

    readonly HttpClient _http;
    public OneDriveTokens Tokens { get; }
    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get; set; } = 1;
    public int MaxRetries { get; set; } = 5;
    /// <summary>Longest wait Cirrus accepts from a Retry-After header before giving up with a clear error.</summary>
    public double MaxRetryAfter { get; set; } = 120;

    public OneDriveHttp(HttpClient http, OneDriveTokens tokens)
    {
        _http = http;
        Tokens = tokens;
    }

    public static bool IsGraph(Uri? url) =>
        url is not null && url.IsAbsoluteUri && url.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)
        && url.Host.Equals(GraphHost, StringComparison.OrdinalIgnoreCase);

    public static bool IsGraph(string? url) => Uri.TryCreate(url, UriKind.Absolute, out var u) && IsGraph(u);

    // MARK: Encoding

    const string Unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

    /// <summary>Percent-encodes UTF-8 bytes of <paramref name="s"/> except unreserved ASCII and <paramref name="extra"/>.</summary>
    public static string Encode(string s, string extra = "")
    {
        var sb = new StringBuilder(s.Length + 8);
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (b < 0x80 && (Unreserved.Contains(c) || extra.Contains(c))) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// <summary>Query items as URLComponents writes them: sub-delimiters stay, "&amp;", "=", "+", "#" and "%" are encoded.</summary>
    public static string QueryString(IEnumerable<(string Key, string Value)> items) =>
        string.Join('&', items.Select(i => Encode(i.Key, QueryExtra) + "=" + Encode(i.Value, QueryExtra)));

    const string QueryExtra = "!$'()*,;:@/?";

    public static double? ParseSeconds(string? s) =>
        double.TryParse((s ?? "").Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;

    // MARK: Errors

    /// <summary>Network failures (as opposed to local file errors or Cirrus's own).</summary>
    public static bool IsNetwork(Exception e) => e switch
    {
        HttpRequestException or HttpIOException or TimeoutException or SocketException => true,
        IOException io => io.InnerException is SocketException or HttpIOException,
        _ => false,
    };

    public static CloudException NetworkError(Exception e)
    {
        if (e is HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError } && !Online())
            return CloudException.Server("Cirrus can’t reach OneDrive: this device is offline.");
        var why = e is TimeoutException ? "The request timed out." : e.Message.TrimEnd('.') + ".";
        return CloudException.Server($"Cirrus couldn’t reach OneDrive ({why}). Try again.");
    }

    static bool Online()
    {
        try { return NetworkInterface.GetIsNetworkAvailable(); } catch { return true; }
    }

    static string Capitalized(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    /// <summary>A sentence for a Graph error answer. <paramref name="name"/> is the item the request was about, if any.</summary>
    public static CloudException Error(GraphResponse r, string? name = null)
    {
        var j = r.Json;
        var code = j["error"]["code"].Str ?? "";
        var inner = j["error"]["innerError"]["code"].Str ?? j["error"]["innererror"]["code"].Str ?? "";
        var message = j["error"]["message"].Str ?? "";
        var what = name is null ? "the item" : $"“{name}”";
        switch (r.Status)
        {
            case 401:
                return CloudException.SignInNeeded("OneDrive");
            case 404:
                return CloudException.NotFound();
            case 409:
                if (code == "nameAlreadyExists" || inner == "nameAlreadyExists" || message.Contains("same name", StringComparison.OrdinalIgnoreCase))
                    return CloudException.Denied($"There’s already an item named {what} in that folder on OneDrive.");
                return CloudException.Denied(message.Length == 0 ? $"OneDrive refused to change {what} because it changed in the meantime. Try again." : message);
            case 423:
                return CloudException.Denied($"{Capitalized(what)} is locked on OneDrive (it may be open or checked out in another app).");
            case 413:
                return CloudException.Denied($"{Capitalized(what)} is too large for OneDrive.");
            case 507:
                return CloudException.QuotaExceeded("OneDrive");
            case 403:
                if (code == "quotaLimitReached" || inner == "quotaLimitReached") return CloudException.QuotaExceeded("OneDrive");
                return CloudException.Denied(message.Length == 0 ? $"OneDrive didn’t allow this change to {what}." : $"OneDrive didn’t allow this: {message}");
            case 400:
                return CloudException.Denied(message.Length == 0 ? $"OneDrive didn’t accept the request for {what}." : $"OneDrive didn’t accept this: {message}");
            case 429 or 503 or 509:
                return CloudException.Server("OneDrive is limiting how fast Cirrus can work right now. Try again in a few minutes.");
            default:
                if (r.Status >= 500) return CloudException.Server($"OneDrive had a problem (HTTP {r.Status}). Try again later.");
                return CloudException.Server(message.Length == 0 ? $"OneDrive answered HTTP {r.Status}." : $"{message} (HTTP {r.Status})");
        }
    }

    /// <summary>Turns network failures into <see cref="CloudException"/> (cancellation stays <see cref="OperationCanceledException"/>).</summary>
    public static async Task<T> Guarded<T>(Func<Task<T>> op)
    {
        try { return await op().ConfigureAwait(false); }
        catch (Exception e) when (e is not OperationCanceledException && e is not CloudException && IsNetwork(e)) { throw NetworkError(e); }
    }

    public static async Task Guarded(Func<Task> op)
    {
        try { await op().ConfigureAwait(false); }
        catch (Exception e) when (e is not OperationCanceledException && e is not CloudException && IsNetwork(e)) { throw NetworkError(e); }
    }

    // MARK: Requests

    /// <summary>Route shape for logs: no query strings, and path-addressed names cut off.</summary>
    public static string Describe(Uri? u)
    {
        if (u is null) return "?";
        if (!IsGraph(u)) return u.Host + " (pre-authenticated)";
        var p = u.AbsolutePath;
        var i = p.IndexOf(":/", StringComparison.Ordinal);
        if (i >= 0) p = p[..i] + ":/…";
        return "graph" + p;
    }

    /// <summary>
    /// One HTTP exchange, no retries; network failures come back as exceptions (a stall as <see cref="TimeoutException"/>).
    /// With <paramref name="toFile"/>, a 2xx body is streamed into that file (created or truncated) instead of memory.
    /// </summary>
    public async Task<GraphResponse> TransportAsync(GraphRequest request, string? accessToken = null, string? toFile = null, Action<long>? sent = null,
        Action<long, long>? received = null, CancellationToken ct = default)
    {
        var started = DateTimeOffset.UtcNow;
        using var watch = new StallWatch(ct);
        using var req = request.Build(accessToken, sent, watch.Kick);
        GraphResponse response;
        try
        {
            using var r = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
            watch.Kick();
            var status = (int)r.StatusCode;
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in r.Headers) headers[kv.Key] = string.Join(", ", kv.Value);
            foreach (var kv in r.Content.Headers) headers[kv.Key] = string.Join(", ", kv.Value);
            await using var body = await r.Content.ReadAsStreamAsync(watch.Token).ConfigureAwait(false);
            var buf = new byte[1 << 20];
            if (toFile is not null && status is >= 200 and < 300)
            {
                var total = r.Content.Headers.ContentLength ?? -1;
                long done = 0;
                await using (var fs = new FileStream(toFile, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                {
                    while (true)
                    {
                        var n = await body.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        await fs.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                        watch.Kick();
                        done += n;
                        received?.Invoke(done, total);
                    }
                }
                response = new GraphResponse(status, req.RequestUri!, [], headers, toFile);
            }
            else
            {
                // Error answers and JSON are small; a server that sends more than 64 MiB here is cut off.
                using var ms = new MemoryStream();
                while (true)
                {
                    var n = await body.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                    if (n <= 0) break;
                    ms.Write(buf, 0, n);
                    watch.Kick();
                    if (ms.Length > 64L << 20) break;
                }
                response = new GraphResponse(status, req.RequestUri!, ms.ToArray(), headers, null);
            }
        }
        catch (OperationCanceledException) when (watch.Stalled) { throw new TimeoutException("The request timed out."); }
        var line = $"onedrive {request.Method} {Describe(req.RequestUri)} → {response.Status}";
        if (response.Status is >= 200 and < 400) Log.Debug(line + $" ({(DateTimeOffset.UtcNow - started).TotalSeconds:0.00}s)"); else Log.Status(line);
        return response;
    }

    /// <summary>
    /// A request with the account's token (when <paramref name="auth"/>), one refresh-and-retry after a 401, and back-off on
    /// throttling (429/503/509, honouring Retry-After) and — for <see cref="GraphRetry.Safe"/> requests — on 5xx answers and
    /// dropped connections. Unsafe requests are retried only when they certainly never reached the server. Every other status
    /// comes back as is. Network failures throw (see <see cref="Guarded{T}"/>).
    /// </summary>
    public async Task<GraphResponse> SendAsync(GraphRequest request, bool auth = true, GraphRetry retry = GraphRetry.Safe, string? toFile = null,
        Action<long>? sent = null, Action<long, long>? received = null, CancellationToken ct = default)
    {
        int attempt = 0;
        string? stale = null;
        bool reauthed = false;
        var url = new Uri(request.Url);
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            string? token = null;
            if (auth)
            {
                if (!IsGraph(url))
                    throw CloudException.Server("OneDrive pointed Cirrus at a server that isn’t Microsoft Graph, so Cirrus didn’t send your sign-in there.");
                token = await Tokens.AccessTokenAsync(stale, ct).ConfigureAwait(false);
            }
            else if (!url.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase))
                throw CloudException.Server("OneDrive gave Cirrus an address that isn’t secure (https), so Cirrus didn’t use it.");
            GraphResponse r;
            try
            {
                r = await TransportAsync(request, token, toFile, sent, received, ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not OperationCanceledException && IsNetwork(e)
                                      && GoogleHttp.IsTransient(e, retry == GraphRetry.Safe) && attempt < MaxRetries)
            {
                attempt++;
                Log.Status($"onedrive {request.Method} {Describe(url)} failed ({e.GetType().Name}); retrying");
                await SleepAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                continue;
            }
            if (r.Status == 401 && auth)
            {
                r.Discard();
                if (!reauthed) { reauthed = true; stale = token; continue; }
                throw CloudException.SignInNeeded("OneDrive");
            }
            var throttled = r.Status is 429 or 503 or 509;
            var serverError = r.Status is 500 or 502 or 504 && retry == GraphRetry.Safe;
            if ((throttled || serverError) && attempt < MaxRetries)
            {
                if (r.RetryAfter is { } after && after > MaxRetryAfter) return r;   // too long to wait here: the caller reports it
                attempt++;
                var d = Delay(attempt, r.RetryAfter);
                Log.Status($"onedrive back-off {d:0.0}s after {r.Status}");
                r.Discard();
                await SleepAsync(d, ct).ConfigureAwait(false);
                continue;
            }
            return r;
        }
    }

    /// <summary>GET/POST/PATCH/DELETE on a Graph path (or a full nextLink URL) that must answer 2xx with JSON.</summary>
    public async Task<J> JsonAsync(string method, string path, IReadOnlyList<(string, string)>? query = null, JsonNode? body = null,
        GraphRetry retry = GraphRetry.Safe, string? name = null, CancellationToken ct = default)
    {
        var url = path.StartsWith("https://", StringComparison.Ordinal) ? path : Graph + path;
        var r = await SendAsync(GraphRequest.Make(method, url, query, body), retry: retry, ct: ct).ConfigureAwait(false);
        if (!r.Ok) throw Error(r, name);
        return r.Json;
    }

    public double Delay(int attempt, double? retryAfter)
    {
        if (retryAfter is { } ra) return Math.Max(0, Math.Min(ra, MaxRetryAfter));
        var b = Math.Min(RetryBase * Math.Pow(2, attempt - 1), 32 * Math.Max(RetryBase, 0.001));
        return b + Random.Shared.NextDouble() * Math.Max(RetryBase, 0.001) / 2;
    }

    public static Task SleepAsync(double seconds, CancellationToken ct) =>
        seconds <= 0 ? Task.CompletedTask : Task.Delay(TimeSpan.FromSeconds(seconds), ct);
}
