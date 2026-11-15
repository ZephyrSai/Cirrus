using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

/// <summary>HTTP plumbing shared by the Google clients.</summary>
static class GoogleHttp
{
    /// <summary>No answer (or no bytes moving) for this long → the request failed with a network error.</summary>
    public static TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(60);

    public static HttpClient Create(HttpMessageHandler? handler)
    {
        handler ??= new SocketsHttpHandler
        {
            UseCookies = false,                               // Google APIs need no cookies; none are kept
            AllowAutoRedirect = false,                        // Drive's "308 Resume Incomplete" must reach the uploader as is
            AutomaticDecompression = DecompressionMethods.None, // ranged downloads count raw bytes
            MaxConnectionsPerServer = 6,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromSeconds(30),
        };
        return new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>
    /// The access token goes only to Google's own API and content hosts; any other host (a redirect, an odd URL in an
    /// answer) gets the request without it.
    /// </summary>
    public static bool IsGoogleHost(string host)
    {
        host = host.ToLowerInvariant();
        foreach (var d in new[] { "googleapis.com", "googleusercontent.com" })
            if (host == d || host.EndsWith("." + d, StringComparison.Ordinal)) return true;
        return host is "accounts.google.com" or "docs.google.com" or "drive.google.com";
    }

    /// <summary>Failures where the request certainly never reached the server (name lookup, connecting, TLS handshake).</summary>
    public static bool NothingWasSent(Exception e) =>
        e is HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError or HttpRequestError.SecureConnectionError };

    /// <summary>Network failures worth retrying. <paramref name="ambiguousOK"/>: also ones where the server may have acted.</summary>
    public static bool IsTransient(Exception e, bool ambiguousOK)
    {
        if (NothingWasSent(e)) return true;
        if (!ambiguousOK) return false;
        return e switch
        {
            TimeoutException => true,
            HttpRequestException h => h.HttpRequestError is HttpRequestError.ResponseEnded or HttpRequestError.Unknown or HttpRequestError.InvalidResponse
                || h.InnerException is IOException or SocketException,
            HttpIOException => true,
            IOException io => io.InnerException is SocketException,
            TaskCanceledException tc => tc.InnerException is TimeoutException,
            _ => false,
        };
    }
}

/// <summary>Restarts a timer whenever bytes move; fires when they stop for <see cref="GoogleHttp.RequestTimeout"/>.</summary>
sealed class StallWatch : IDisposable
{
    readonly CancellationTokenSource _cts;
    readonly CancellationToken _outer;
    public StallWatch(CancellationToken outer) { _outer = outer; _cts = CancellationTokenSource.CreateLinkedTokenSource(outer); Kick(); }
    public CancellationToken Token => _cts.Token;
    public void Kick() { try { _cts.CancelAfter(GoogleHttp.RequestTimeout); } catch (ObjectDisposedException) { } }
    public bool Stalled => _cts.IsCancellationRequested && !_outer.IsCancellationRequested;
    public void Dispose() => _cts.Dispose();
}

/// <summary>A request body that reports bytes sent (and keeps the stall timer alive).</summary>
sealed class ProgressContent : HttpContent
{
    readonly Func<Stream> _open;
    readonly long _length;
    readonly Action<long>? _sent;
    readonly Action _kick;

    public ProgressContent(Func<Stream> open, long length, Action<long>? sent, Action kick)
    {
        _open = open; _length = length; _sent = sent; _kick = kick;
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context) => await SerializeToStreamAsync(stream, context, default).ConfigureAwait(false);

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct)
    {
        await using var src = _open();
        var buf = new byte[256 * 1024];
        long done = 0;
        while (true)
        {
            var n = await src.ReadAsync(buf, ct).ConfigureAwait(false);
            if (n <= 0) break;
            await stream.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
            done += n;
            _kick();
            _sent?.Invoke(done);
        }
    }

    protected override bool TryComputeLength(out long length) { length = _length; return true; }
}

/// <summary>A request body: none, bytes in memory, or a file.</summary>
public abstract record GoogleBody
{
    public sealed record None : GoogleBody;
    public sealed record Bytes(byte[] Data) : GoogleBody;
    public sealed record File(string Path) : GoogleBody;
    public static readonly GoogleBody Empty = new None();
}

/// <summary>A finished exchange: status, body and headers (content headers included).</summary>
public sealed class GoogleResponse
{
    public int Status { get; }
    public byte[] Data { get; }
    readonly Dictionary<string, string> _headers;

    public GoogleResponse(int status, byte[] data, Dictionary<string, string> headers) { Status = status; Data = data; _headers = headers; }
    public J Json => J.Parse(Data);
    public string? Header(string name) => _headers.TryGetValue(name, out var v) ? v : null;
    public string Text => Encoding.UTF8.GetString(Data);

    internal static GoogleResponse From(HttpResponseMessage r, byte[] data)
    {
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in r.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        foreach (var kv in r.Content.Headers) h[kv.Key] = string.Join(", ", kv.Value);
        return new GoogleResponse((int)r.StatusCode, data, h);
    }
}

/// <summary>A request description; a fresh <see cref="HttpRequestMessage"/> is built for every attempt.</summary>
public sealed class GoogleRequest
{
    public string Method { get; init; } = "GET";
    public string Url { get; init; } = "";
    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public GoogleBody Body { get; init; } = GoogleBody.Empty;

    internal HttpRequestMessage Build(string? accessToken, Action<long>? sent, Action kick)
    {
        var req = new HttpRequestMessage(new HttpMethod(Method), Url);
        HttpContent? content = Body switch
        {
            GoogleBody.Bytes b => new ProgressContent(() => new MemoryStream(b.Data, writable: false), b.Data.Length, sent, kick),
            GoogleBody.File f => new ProgressContent(() => new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true),
                new FileInfo(f.Path).Length, sent, kick),
            _ => Method is "POST" or "PUT" or "PATCH" ? new ByteArrayContent([]) : null,
        };
        req.Content = content;
        foreach (var (k, v) in Headers)
        {
            if (k.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;   // comes from the body
            if (!req.Headers.TryAddWithoutValidation(k, v))
            {
                req.Content ??= new ByteArrayContent([]);
                req.Content.Headers.Remove(k);
                req.Content.Headers.TryAddWithoutValidation(k, v);
            }
        }
        if (accessToken is not null && GoogleHttp.IsGoogleHost(req.RequestUri!.Host)) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        return req;
    }
}

/// <summary>
/// Authenticated Google API transport (port of GoogleAPI.swift): access-token caching with single-flight refresh, one
/// retry after a 401, and exponential back-off (with Retry-After) on rate limits and 5xx. Logs carry method, host, path
/// and status only — never tokens, bodies or account names.
/// </summary>
public sealed class GoogleApi
{
    public string AccountID { get; }
    internal GoogleOAuth OAuth { get; }
    readonly HttpClient _http;
    readonly Func<CancellationToken, Task<string>> _refreshTokenProvider;
    readonly object _lock = new();
    GoogleTokens? _access;
    Task<GoogleTokens>? _refreshing;
    List<string> _scopes;

    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get; set; } = 1.0;
    public int MaxRetries { get; set; } = 6;
    /// <summary>Google asks for at least 30 s between retries of a rate-limited mediaItems:batchCreate.</summary>
    public double BatchCreateMinBackoff { get; set; } = 30;
    /// <summary>Called when Google hands out a new refresh token (rare) so it can be saved.</summary>
    public Action<string>? OnNewRefreshToken { get; set; }
    /// <summary>Test hook.</summary>
    internal Func<TimeSpan, CancellationToken, Task> SleepImpl { get; set; } = Task.Delay;

    public GoogleApi(string accountID, GoogleOAuth oauth, IEnumerable<string> scopes, Func<CancellationToken, Task<string>> refreshToken,
        HttpMessageHandler? handler = null, GoogleTokens? initialTokens = null)
    {
        AccountID = accountID;
        OAuth = oauth;
        _scopes = scopes.ToList();
        _access = initialTokens;
        _refreshTokenProvider = refreshToken;
        _http = GoogleHttp.Create(handler);
    }

    public IReadOnlyList<string> Scopes { get { lock (_lock) return _scopes.ToList(); } }
    public bool Has(string scope) { lock (_lock) return _scopes.Contains(scope); }

    // MARK: Tokens

    internal async Task<string> AccessTokenAsync(bool force, CancellationToken ct)
    {
        Task<GoogleTokens> task;
        lock (_lock)
        {
            if (!force && _access is { } a && a.ExpiresAt - DateTimeOffset.UtcNow > TimeSpan.FromSeconds(90)) return a.AccessToken;
            task = _refreshing ??= Task.Run(async () => await OAuth.RefreshAsync(await _refreshTokenProvider(CancellationToken.None).ConfigureAwait(false)).ConfigureAwait(false));
        }
        try
        {
            var t = await task.WaitAsync(ct).ConfigureAwait(false);
            lock (_lock)
            {
                _access = t;
                if (ReferenceEquals(_refreshing, task)) _refreshing = null;
                if (t.Scopes.Count > 0) _scopes = t.Scopes.ToList();
            }
            if (t.RefreshToken is { } r) OnNewRefreshToken?.Invoke(r);
            return t.AccessToken;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch
        {
            lock (_lock) if (ReferenceEquals(_refreshing, task)) _refreshing = null;
            throw;
        }
    }

    // MARK: Transport

    /// <summary>
    /// One request with auth; refreshes and retries once on 401. Every status comes back as a response. With
    /// <paramref name="sink"/>, a 2xx body is streamed into it instead of memory.
    /// </summary>
    internal async Task<GoogleResponse> PerformAsync(GoogleRequest request, Action<long>? sent = null, Stream? sink = null, Action<long>? received = null,
        CancellationToken ct = default)
    {
        bool authRetry = false;
        int redirects = 0;
        while (true)
        {
            var token = await AccessTokenAsync(authRetry, ct).ConfigureAwait(false);
            var started = DateTimeOffset.UtcNow;
            using var watch = new StallWatch(ct);
            using var req = request.Build(token, sent, watch.Kick);
            GoogleResponse resp;
            try
            {
                using var r = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
                watch.Kick();
                var status = (int)r.StatusCode;
                if (sink is not null && status is >= 200 and < 300)
                {
                    await using var body = await r.Content.ReadAsStreamAsync(watch.Token).ConfigureAwait(false);
                    var buf = new byte[1 << 20];
                    long done = 0;
                    while (true)
                    {
                        var n = await body.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        await sink.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                        watch.Kick();
                        done += n;
                        received?.Invoke(done);
                    }
                    resp = GoogleResponse.From(r, []);
                }
                else resp = GoogleResponse.From(r, await r.Content.ReadAsByteArrayAsync(watch.Token).ConfigureAwait(false));
            }
            catch (OperationCanceledException) when (watch.Stalled) { throw new TimeoutException("Google didn’t answer in time."); }
            var secs = (DateTimeOffset.UtcNow - started).TotalSeconds;
            var uri = req.RequestUri!;
            var line = $"google {request.Method} {uri.Host}{uri.AbsolutePath} → {resp.Status}";
            if (resp.Status is >= 200 and < 300 or 308) Log.Debug(line + $" ({secs:0.00}s)"); else Log.Status(line);
            if (resp.Status == 401 && !authRetry) { authRetry = true; continue; }
            // Downloads (export links, picked photos) may be redirected to Google's content servers. Only GETs follow,
            // only to https, at most a few hops; the token goes along only to Google's own hosts (see Build).
            if (request.Method == "GET" && resp.Status is 301 or 302 or 303 or 307 && redirects < 3
                && resp.Header("Location") is { } loc && Uri.TryCreate(uri, loc, out var next) && next.Scheme == Uri.UriSchemeHttps)
            {
                redirects++;
                request = new GoogleRequest { Method = "GET", Url = next.AbsoluteUri, Headers = request.Headers, Body = GoogleBody.Empty };
                continue;
            }
            return resp;
        }
    }

    internal abstract record Verdict
    {
        public sealed record Ok : Verdict;
        public sealed record Retry(double? After) : Verdict;
        public sealed record Fail(GoogleException Error) : Verdict;
    }

    /// <summary>How to treat a status. Rate limits and server errors are retried; daily caps and full storage stop the run.</summary>
    internal static Verdict Classify(int status, byte[] data, string? retryAfter)
    {
        if (status is >= 200 and < 300 or 308) return new Verdict.Ok();
        var j = J.Parse(data);
        var err = j["error"];
        var message = err["message"].Str ?? err.Str ?? "";
        var reasons = err["errors"].Array.Select(e => e["reason"].Str).Concat(err["details"].Array.Select(e => e["reason"].Str)).OfType<string>().ToList();
        double? after = double.TryParse(retryAfter, NumberStyles.Float, CultureInfo.InvariantCulture, out var ra) ? ra : null;
        var lower = message.ToLowerInvariant();
        var daily = reasons.Any(r => r is "dailyLimitExceeded" or "dailyLimitExceededUnreg" or "uploadLimitExceeded" or "quotaExceeded")
            || lower.Contains("per day") || lower.Contains("daily limit");
        switch (status)
        {
            case 401:
                return new Verdict.Fail(GoogleException.Reconnect("Google no longer accepts Cirrus’s sign-in. Select Connect Google to continue; the move picks up where it stopped."));
            case 403:
                if (reasons.Contains("storageQuotaExceeded") || lower.Contains("storage quota")) return new Verdict.Fail(GoogleException.StorageFull());
                if (daily) return new Verdict.Fail(GoogleException.DailyLimit(DailyMessage(message)));
                if (reasons.Any(r => r is "rateLimitExceeded" or "userRateLimitExceeded")) return new Verdict.Retry(after);
                if (reasons.Contains("insufficientPermissions") || lower.Contains("insufficient authentication scopes") || lower.Contains("insufficient permission"))
                    return new Verdict.Fail(GoogleException.MissingScope(lower.Contains("photos") ? "Google Photos" : "Google Drive"));
                if (lower.Contains("has not been used in project") || lower.Contains("is disabled") || reasons.Contains("accessNotConfigured"))
                    return new Verdict.Fail(GoogleException.BadResponse($"An API Cirrus needs is turned off in your Google Cloud project. In Set Up Google Access…, open the Drive API and Photos Library API pages and select Enable. ({message})"));
                return new Verdict.Fail(GoogleException.Http(403, message));
            case 429:
                if (daily) return new Verdict.Fail(GoogleException.DailyLimit(DailyMessage(message)));
                return new Verdict.Retry(after);
            case 500 or 502 or 503 or 504:
                return new Verdict.Retry(after);
            default:
                return new Verdict.Fail(GoogleException.Http(status, message));
        }
    }

    internal static string DailyMessage(string raw) => raw.Contains("photos", StringComparison.OrdinalIgnoreCase)
        ? "Google Photos’ daily limit for your Google Cloud project (10,000 requests) is used up. Run the move again tomorrow — it continues where it stopped."
        : "Google’s daily upload limit was reached (about 750 GB a day). Run the move again tomorrow — it continues where it stopped.";

    internal double Delay(int attempt, double? retryAfter, double minimum = 0)
    {
        if (retryAfter is { } r) return Math.Max(minimum, Math.Min(r, 120));
        var b = Math.Min(RetryBase * Math.Pow(2, attempt), 32 * Math.Max(RetryBase, 0.001));
        return Math.Max(minimum, b + System.Random.Shared.NextDouble() * Math.Max(RetryBase, 0.001));
    }

    internal Task SleepAsync(double seconds, CancellationToken ct) => seconds <= 0 ? Task.CompletedTask : SleepImpl(TimeSpan.FromSeconds(seconds), ct);

    /// <summary>Request with retries. <paramref name="idempotent"/> allows retrying after an ambiguous network failure.</summary>
    internal async Task<GoogleResponse> SendAsync(GoogleRequest request, bool idempotent, double minBackoff = 0, Action<long>? sent = null, Stream? sink = null,
        CancellationToken ct = default)
    {
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            GoogleResponse r;
            try { r = await PerformAsync(request, sent, sink, null, ct).ConfigureAwait(false); }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not GoogleException && GoogleHttp.IsTransient(e, idempotent) && attempt < MaxRetries
                                      && (sink is null || sink.CanSeek))
            {
                attempt++;
                if (sink is { CanSeek: true }) { sink.SetLength(0); sink.Position = 0; }
                await SleepAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                continue;
            }
            switch (Classify(r.Status, r.Data, r.Header("Retry-After")))
            {
                case Verdict.Ok: return r;
                case Verdict.Fail f: throw f.Error;
                case Verdict.Retry rt:
                    if (attempt >= MaxRetries)
                        throw r.Status is 429 or 403 ? GoogleException.RateLimited() : GoogleException.Http(r.Status, "Google kept failing; try again later.");
                    attempt++;
                    var d = Delay(attempt, rt.After, r.Status == 429 ? minBackoff : 0);
                    Log.Status($"google back-off {d:0.0}s after {r.Status}");
                    await SleepAsync(d, ct).ConfigureAwait(false);
                    break;
            }
        }
    }

    // MARK: JSON helpers

    static string Enc(string s) => Uri.EscapeDataString(s);

    /// <summary>Builds a request; query keys are sorted and every reserved character (including "+") is percent-encoded.</summary>
    internal static GoogleRequest Request(string method, string url, IReadOnlyDictionary<string, string>? query = null, JsonNode? json = null,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        var u = url;
        if (query is { Count: > 0 })
            u += (u.Contains('?') ? "&" : "?") + string.Join('&', query.OrderBy(k => k.Key, StringComparer.Ordinal).Select(kv => Enc(kv.Key) + "=" + Enc(kv.Value)));
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Accept"] = "application/json" };
        GoogleBody body = GoogleBody.Empty;
        if (json is not null)
        {
            h["Content-Type"] = "application/json; charset=UTF-8";
            body = new GoogleBody.Bytes(Jx.Bytes(json));
        }
        if (headers is not null) foreach (var (k, v) in headers) h[k] = v;
        return new GoogleRequest { Method = method, Url = u, Headers = h, Body = body };
    }

    internal async Task<J> JsonAsync(string method, string url, IReadOnlyDictionary<string, string>? query = null, JsonNode? body = null, bool idempotent = true,
        double minBackoff = 0, CancellationToken ct = default) =>
        (await SendAsync(Request(method, url, query, body), idempotent, minBackoff, ct: ct).ConfigureAwait(false)).Json;
}
