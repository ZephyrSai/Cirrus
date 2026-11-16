using System.Globalization;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cirrus.Core;

// Dropbox API v2 transport (port of DropboxHTTP.swift): token handling (one shared refresh at a time), the two request
// styles Dropbox uses (RPC calls on api.dropboxapi.com with a JSON body; content calls on content.dropboxapi.com with the
// argument in the Dropbox-API-Arg header), back-off on rate limits and write contention, and a gate that keeps changes
// to the user's Dropbox one at a time as Dropbox recommends. The bearer token only ever goes to those two hosts over
// https. Logs carry the route and status only: never tokens, arguments or file names.

/// <summary>Tokens from Dropbox's token endpoint.</summary>
sealed record DropboxTokenSet(string Access, string? Refresh, DateTimeOffset Expires, IReadOnlySet<string>? Scopes);

/// <summary>
/// One account's tokens. Dropbox's refresh tokens normally stay the same for the life of the sign-in; if a refresh ever
/// hands out a new one, it goes to <see cref="OnNewRefreshToken"/> before anyone can refresh again.
/// </summary>
sealed class DropboxTokens
{
    public string AppKey { get; }
    readonly HttpClient _http;
    readonly object _lock = new();
    string _refreshToken;
    string? _access;
    DateTimeOffset _expires = DateTimeOffset.MinValue;
    Task<string>? _refreshing;
    Action<string>? _onNew;

    public DropboxTokens(string appKey, string refreshToken, HttpClient http, DropboxTokenSet? initial = null)
    {
        AppKey = appKey;
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
    /// A usable access token. <paramref name="stale"/> is one the server just refused (401): it is never handed out
    /// again. Every caller that needs a new token waits on the same refresh.
    /// </summary>
    public async Task<string> AccessTokenAsync(string? stale, CancellationToken ct)
    {
        Task<string> task;
        lock (_lock)
        {
            if (_access is { } a && a != stale && _expires - DateTimeOffset.UtcNow > TimeSpan.FromSeconds(120)) return a;
            // Not tied to the caller's token: one cancelled request must not cancel everyone's refresh.
            if (_refreshing is null) { var rt = _refreshToken; _refreshing = Task.Run(() => RunRefreshAsync(rt)); }
            task = _refreshing;
        }
        return await task.WaitAsync(ct).ConfigureAwait(false);
    }

    async Task<string> RunRefreshAsync(string rt)
    {
        try
        {
            var t = await DropboxAuth.RedeemAsync(new() { ["grant_type"] = "refresh_token", ["refresh_token"] = rt }, AppKey, _http,
                signingIn: false, ct: CancellationToken.None).ConfigureAwait(false);
            Action<string>? callback = null;
            string? fresh = null;
            lock (_lock)
            {
                _access = t.Access;
                _expires = t.Expires;
                if (t.Refresh is { Length: > 0 } n && n != _refreshToken) { _refreshToken = n; fresh = n; callback = _onNew; }
            }
            if (fresh is not null) callback?.Invoke(fresh);
            return t.Access;
        }
        finally { lock (_lock) _refreshing = null; }
    }
}

/// <summary>What a request carries.</summary>
abstract record DropboxBody
{
    public sealed record None : DropboxBody;
    public sealed record Bytes(byte[] Data) : DropboxBody;
    public sealed record File(string Path) : DropboxBody;
    public static readonly DropboxBody Empty = new None();
}

/// <summary>A request description; a fresh HttpRequestMessage is built for every attempt.</summary>
sealed record DropboxRequest(string Url, IReadOnlyDictionary<string, string> Headers, string? ContentType, DropboxBody Body)
{
    public DropboxRequest WithBody(DropboxBody body) => this with { Body = body };
}

enum DropboxRetry { Safe, Unsafe }

/// <summary>A finished request. Downloads streamed to a file carry no body here.</summary>
sealed class DropboxResponse
{
    public int Status { get; }
    public byte[] Data { get; }
    readonly Dictionary<string, string> _headers;

    public DropboxResponse(int status, byte[] data, Dictionary<string, string>? headers = null)
    {
        Status = status;
        Data = data;
        _headers = headers ?? new(StringComparer.OrdinalIgnoreCase);
    }

    public bool Ok => Status is >= 200 and < 300;
    public J Json => J.Parse(Data);
    public string? Header(string name) => _headers.TryGetValue(name, out var v) ? v : null;
    /// <summary>Dropbox's machine-readable error path, e.g. "path/conflict/file/.." ("" when there is none).</summary>
    public string Summary => Json["error_summary"].Str ?? "";

    /// <summary>Seconds to wait, from the Retry-After header or a RateLimitError body.</summary>
    public double? RetryAfter
    {
        get
        {
            if (Header("Retry-After") is { } h && double.TryParse(h.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var s)) return s;
            return Json["error"]["retry_after"].Double;
        }
    }
}

/// <summary>Restarts a timer whenever bytes move; fires when they stop for <see cref="DropboxHttp.RequestTimeout"/>.</summary>
sealed class DropboxStallWatch : IDisposable
{
    readonly CancellationTokenSource _cts;
    readonly CancellationToken _outer;
    public DropboxStallWatch(CancellationToken outer) { _outer = outer; _cts = CancellationTokenSource.CreateLinkedTokenSource(outer); Kick(); }
    public CancellationToken Token => _cts.Token;
    public void Kick() { try { _cts.CancelAfter(DropboxHttp.RequestTimeout); } catch (ObjectDisposedException) { } }
    public bool Stalled => _cts.IsCancellationRequested && !_outer.IsCancellationRequested;
    public void Dispose() => _cts.Dispose();
}

sealed class DropboxHttp
{
    public const string ApiHost = "api.dropboxapi.com";
    public const string ContentHost = "content.dropboxapi.com";
    public const string Api = "https://api.dropboxapi.com/2/";
    public const string Content = "https://content.dropboxapi.com/2/";

    /// <summary>No answer (or no bytes moving) for this long → the request failed with a network error.</summary>
    public static TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(90);

    public HttpClient Client { get; }
    public DropboxTokens Tokens { get; }
    /// <summary>Team accounts with a team space: the root namespace every path is relative to (Dropbox-API-Path-Root).</summary>
    public string? PathRoot { get; }
    /// <summary>Base back-off in seconds (tests set it near zero).</summary>
    public double RetryBase { get; set; } = 1;
    public int MaxRetries { get; set; } = 5;
    /// <summary>Longest wait Cirrus accepts from a Retry-After before giving up with a clear error.</summary>
    public double MaxRetryAfter { get; set; } = 120;

    public DropboxHttp(HttpClient client, DropboxTokens tokens, string? pathRoot)
    {
        Client = client;
        Tokens = tokens;
        PathRoot = string.IsNullOrEmpty(pathRoot) ? null : pathRoot;
    }

    public static bool IsDropbox(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps
        && u.Host.ToLowerInvariant() is ApiHost or ContentHost;

    // MARK: JSON arguments

    /// <summary>Compact JSON with sorted keys and unescaped slashes (non-ASCII kept as is).</summary>
    public static string Encode(JsonNode? node)
    {
        var sb = new StringBuilder();
        Write(sb, node);
        return sb.ToString();
    }

    static void Write(StringBuilder sb, JsonNode? node)
    {
        switch (node)
        {
            case null: sb.Append("null"); break;
            case JsonObject o:
                sb.Append('{');
                var first = true;
                foreach (var (k, v) in o.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, k);
                    sb.Append(':');
                    Write(sb, v);
                }
                sb.Append('}');
                break;
            case JsonArray a:
                sb.Append('[');
                for (int i = 0; i < a.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    Write(sb, a[i]);
                }
                sb.Append(']');
                break;
            case JsonValue v:
                if (v.GetValueKind() == JsonValueKind.String) WriteString(sb, v.GetValue<string>());
                else sb.Append(v.ToJsonString());
                break;
        }
    }

    static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    /// <summary>
    /// JSON that is safe in an HTTP header, as Dropbox asks for Dropbox-API-Arg: 0x7F and every non-ASCII character
    /// become "\uXXXX" escapes (UTF-16 code units, so emoji become surrogate pairs).
    /// </summary>
    public static string HeaderSafe(JsonNode? node)
    {
        var s = Encode(node);
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if (c >= 0x7F) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
            else sb.Append(c);
        }
        return sb.ToString();
    }

    static readonly IReadOnlyDictionary<string, string> NoHeaders = new Dictionary<string, string>();

    /// <summary>An RPC call: the argument as the JSON body, or no body (and no Content-Type) for routes without one.</summary>
    public static DropboxRequest RpcRequest(string route, JsonNode? arg) =>
        arg is null
            ? new DropboxRequest(Api + route, NoHeaders, null, DropboxBody.Empty)
            : new DropboxRequest(Api + route, NoHeaders, "application/json", new DropboxBody.Bytes(Encoding.UTF8.GetBytes(Encode(arg))));

    /// <summary>A content call: the argument in Dropbox-API-Arg; uploads send raw bytes, downloads send no body.</summary>
    public static DropboxRequest ContentRequest(string route, JsonNode arg, bool upload, DropboxBody? body = null) =>
        new(Content + route, new Dictionary<string, string> { ["Dropbox-API-Arg"] = HeaderSafe(arg) }, upload ? "application/octet-stream" : null,
            body ?? (upload ? new DropboxBody.Bytes([]) : DropboxBody.Empty));

    // MARK: Errors

    /// <summary>Exceptions that mean the network (not the local disk) failed.</summary>
    public static bool IsNetwork(Exception e) =>
        e is HttpRequestException or HttpIOException or TimeoutException or SocketException || e is IOException { InnerException: SocketException };

    public static CloudException NetworkError(Exception e)
    {
        bool online;
        try { online = NetworkInterface.GetIsNetworkAvailable(); } catch { online = true; }
        if (!online) return CloudException.Server("Cirrus can’t reach Dropbox: this device is offline.");
        var why = e.Message.Trim().TrimEnd('.');
        return CloudException.Server($"Cirrus couldn’t reach Dropbox ({(why.Length == 0 ? e.GetType().Name : why)}). Try again.");
    }

    /// <summary>Turns network failures into CloudException (cancellation stays OperationCanceledException).</summary>
    public static async Task<T> Guarded<T>(Func<Task<T>> op)
    {
        try { return await op().ConfigureAwait(false); }
        catch (Exception e) when (e is not CloudException && e is not OperationCanceledException && IsNetwork(e)) { throw NetworkError(e); }
    }

    public static async Task Guarded(Func<Task> op)
    {
        try { await op().ConfigureAwait(false); }
        catch (Exception e) when (e is not CloudException && e is not OperationCanceledException && IsNetwork(e)) { throw NetworkError(e); }
    }

    /// <summary>A sentence for a Dropbox error answer. <paramref name="name"/> is the item the request was about, if any.</summary>
    public static CloudException Error(DropboxResponse r, string? name = null)
    {
        var s = r.Summary;
        var what = name is null ? "the item" : $"“{name}”";
        var What = char.ToUpperInvariant(what[0]) + what[1..];
        bool Has(string k) => s.Contains(k, StringComparison.Ordinal);
        switch (r.Status)
        {
            case 401:
            {
                var tag = r.Json["error"][".tag"].Str ?? "";
                if (tag == "missing_scope")
                {
                    // A union variant holding a struct: its fields sit beside ".tag".
                    var scope = r.Json["error"]["required_scope"].Str ?? "a permission";
                    return CloudException.Denied($"Dropbox didn’t give Cirrus the “{scope}” permission. Sign in to Dropbox again; if that doesn’t help, the Dropbox app this copy of Cirrus uses needs that permission turned on in the App Console.");
                }
                if (tag == "user_suspended") return CloudException.Denied("This Dropbox account is suspended.");
                return CloudException.SignInNeeded("Dropbox");
            }
            case 409:
                if (Has("too_many_write_operations")) return CloudException.Server("Dropbox is busy with other changes to your files. Try again in a minute.");
                if (Has("insufficient_space") || Has("insufficient_quota")) return CloudException.QuotaExceeded("Dropbox");
                if (Has("not_found")) return CloudException.NotFound();
                if (Has("not_folder")) return CloudException.Denied($"{What} isn’t a folder on Dropbox.");
                if (Has("not_file")) return CloudException.Denied($"{What} is a folder on Dropbox, not a file.");
                if (Has("conflict")) return CloudException.Denied($"There’s already an item named {what} in that folder on Dropbox.");
                if (Has("no_write_permission") || Has("access_denied") || Has("restricted_content"))
                    return CloudException.Denied($"Dropbox didn’t allow changing {what}. It may be in a folder someone shared with you to view only.");
                if (Has("disallowed_name")) return CloudException.Denied($"Dropbox doesn’t allow the name {what}.");
                if (Has("malformed_path")) return CloudException.Denied($"Dropbox can’t use the name {what}. Rename it and try again.");
                if (Has("cant_move_folder_into_itself") || Has("duplicated_or_nested_paths"))
                    return CloudException.Denied("A folder can’t be moved into itself or into a folder inside it.");
                if (Has("cant_nest_shared_folder")) return CloudException.Denied("Dropbox can’t put a shared folder inside another shared folder.");
                if (Has("cant_move_shared_folder") || Has("cant_transfer_ownership") || Has("cant_move_into_vault"))
                    return CloudException.Denied($"Dropbox didn’t allow moving {what} there.");
                if (Has("team_folder")) return CloudException.Denied("Dropbox doesn’t allow this change to a team folder.");
                if (Has("too_many_files")) return CloudException.Denied($"{What} holds too many files for Dropbox to do this in one step.");
                if (Has("unsupported_file"))
                    return CloudException.Unsupported($"{What} is a Dropbox Paper document or another online-only file that Dropbox can’t download as a file. Open it on dropbox.com.");
                if (Has("too_large") || Has("payload_too_large")) return CloudException.Denied($"{What} is too large for Dropbox.");
                if (Has("operation_suppressed")) return CloudException.Denied($"Dropbox didn’t allow this change to {what}.");
                if (Has("reset")) return CloudException.Server("Dropbox restarted listing a folder. Try again.");
                var first = s.Split('/')[0];
                return CloudException.Server(first.Length == 0 ? "Dropbox couldn’t do this (HTTP 409)." : $"Dropbox couldn’t do this ({first}).");
            case 403:
                return CloudException.Denied($"Dropbox didn’t allow this change to {what}.");
            case 400:
                // A plain-text answer that may quote the request (names): never shown or logged in full.
                return CloudException.Server($"Dropbox didn’t accept Cirrus’s request for {what} (HTTP 400). Try again; if it keeps happening, update Cirrus.");
            case 422:
                // The team space this account was set up with changed (Dropbox-API-Path-Root no longer valid).
                return CloudException.SignInNeeded("Dropbox");
            case 429 or 503:
                return CloudException.Server("Dropbox is limiting how fast Cirrus can work right now. Try again in a few minutes.");
            default:
                if (r.Status >= 500) return CloudException.Server($"Dropbox had a problem (HTTP {r.Status}). Try again later.");
                return CloudException.Server($"Dropbox answered HTTP {r.Status}.");
        }
    }

    // MARK: Requests

    /// <summary>Route shape for logs: host and route, nothing else.</summary>
    static string Describe(Uri u)
    {
        var host = u.Host == ContentHost ? "content" : u.Host == ApiHost ? "api" : u.Host;
        return host + u.AbsolutePath;
    }

    HttpRequestMessage Build(DropboxRequest request, string token, Action<long>? sent, Action kick)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, request.Url);
        HttpContent? content = request.Body switch
        {
            DropboxBody.Bytes b => new ProgressContent(() => new MemoryStream(b.Data, writable: false), b.Data.Length, sent, kick),
            DropboxBody.File f => new ProgressContent(() => new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true),
                new FileInfo(f.Path).Length, sent, kick),
            _ => null,
        };
        if (content is not null && request.ContentType is { } type) content.Headers.ContentType = MediaTypeHeaderValue.Parse(type);
        req.Content = content;
        foreach (var (k, v) in request.Headers) req.Headers.TryAddWithoutValidation(k, v);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (PathRoot is { } root)
            req.Headers.TryAddWithoutValidation("Dropbox-API-Path-Root", HeaderSafe(new JsonObject { [".tag"] = "root", ["root"] = root }));
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
    /// One HTTP exchange, no retries; network failures throw. With <paramref name="sinkPath"/>, a 2xx body is streamed
    /// into that file (replacing it) instead of memory.
    /// </summary>
    async Task<DropboxResponse> TransportAsync(DropboxRequest request, string token, string? sinkPath, Action<long>? sent,
        Action<long, long>? received, CancellationToken ct)
    {
        var started = DateTimeOffset.UtcNow;
        using var watch = new DropboxStallWatch(ct);
        using var req = Build(request, token, sent, watch.Kick);
        DropboxResponse resp;
        try
        {
            using var r = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, watch.Token).ConfigureAwait(false);
            watch.Kick();
            var status = (int)r.StatusCode;
            var headers = HeadersOf(r);
            if (sinkPath is not null && status is >= 200 and < 300)
            {
                var total = r.Content.Headers.ContentLength ?? -1;
                await using (var body = await r.Content.ReadAsStreamAsync(watch.Token).ConfigureAwait(false))
                await using (var dst = new FileStream(sinkPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                {
                    var buf = new byte[1 << 20];
                    long done = 0;
                    while (true)
                    {
                        var n = await body.ReadAsync(buf, watch.Token).ConfigureAwait(false);
                        if (n <= 0) break;
                        await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                        watch.Kick();
                        done += n;
                        received?.Invoke(done, total);
                    }
                }
                resp = new DropboxResponse(status, [], headers);
            }
            else resp = new DropboxResponse(status, await r.Content.ReadAsByteArrayAsync(watch.Token).ConfigureAwait(false), headers);
        }
        catch (OperationCanceledException) when (watch.Stalled) { throw new TimeoutException("Dropbox didn’t answer in time."); }
        var line = $"dropbox {Describe(req.RequestUri!)} → {resp.Status}";
        if (resp.Ok) Log.Debug(line + $" ({(DateTimeOffset.UtcNow - started).TotalSeconds:0.00}s)"); else Log.Status(line);
        return resp;
    }

    /// <summary>
    /// A request with the account's token, one refresh-and-retry after an expired or invalid token, and back-off on
    /// rate limits (429, or 503 with Retry-After) and write contention (too_many_write_operations), which Dropbox answers
    /// before doing anything. Safe requests (reads, and changes whose repeat is harmless) are also retried after 5xx
    /// answers and dropped connections; unsafe ones only when they certainly never reached Dropbox. Every other status
    /// comes back as is. Network failures throw.
    /// </summary>
    public async Task<DropboxResponse> SendAsync(DropboxRequest request, DropboxRetry retry, string? sinkPath = null, Action<long>? sent = null,
        Action<long, long>? received = null, CancellationToken ct = default)
    {
        if (!IsDropbox(request.Url))
            throw CloudException.Server("Cirrus was about to send your Dropbox sign-in to a server that isn’t Dropbox, so it stopped.");
        int attempt = 0;
        string? stale = null;
        bool reauthed = false;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var token = await Tokens.AccessTokenAsync(stale, ct).ConfigureAwait(false);
            DropboxResponse r;
            try
            {
                r = await TransportAsync(request, token, sinkPath, sent, received, ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && GoogleHttp.IsTransient(e, retry == DropboxRetry.Safe)
                                      && attempt < MaxRetries)
            {
                attempt++;
                Log.Status($"dropbox {Describe(new Uri(request.Url))} failed ({e.GetType().Name}); retrying");
                await SleepAsync(Delay(attempt, null), ct).ConfigureAwait(false);
                continue;
            }
            if (r.Status == 401)
            {
                var tag = r.Json["error"][".tag"].Str;
                if (tag is null or "expired_access_token" or "invalid_access_token")
                {
                    if (!reauthed) { reauthed = true; stale = token; continue; }
                    throw CloudException.SignInNeeded("Dropbox");
                }
                return r;   // missing_scope, user_suspended…: the caller explains
            }
            // Another change held the namespace: Dropbox did nothing, so any request may go again.
            var contention = r.Status is 429 or 409 && r.Summary.Contains("too_many_write_operations", StringComparison.Ordinal);
            var busy = contention || r.Status == 429 || (r.Status == 503 && r.Header("Retry-After") is not null);
            var serverError = r.Status is >= 500 and <= 599 && retry == DropboxRetry.Safe;
            if ((busy || serverError) && attempt < MaxRetries)
            {
                if (r.RetryAfter is { } after && after > MaxRetryAfter) return r;   // too long to wait here: the caller reports it
                attempt++;
                // Contention clears when the other change finishes: back off even when Retry-After says 0.
                var d = contention ? Math.Max(r.RetryAfter ?? 0, Delay(attempt, null)) : Delay(attempt, busy ? r.RetryAfter : null);
                Log.Status($"dropbox back-off {d.ToString("0.0", CultureInfo.InvariantCulture)}s after {r.Status}");
                await SleepAsync(d, ct).ConfigureAwait(false);
                continue;
            }
            return r;
        }
    }

    /// <summary>An RPC call that must answer 2xx with JSON.</summary>
    public async Task<J> RpcAsync(string route, JsonNode? arg, DropboxRetry retry, string? name = null, CancellationToken ct = default)
    {
        var r = await SendAsync(RpcRequest(route, arg), retry, ct: ct).ConfigureAwait(false);
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

/// <summary>
/// Keeps changes to one Dropbox account one at a time (or a few): Dropbox locks a namespace for each write, and
/// concurrent writes there end in too_many_write_operations. Waiting is FIFO and cancellable.
/// </summary>
sealed class DropboxGate
{
    readonly object _lock = new();
    readonly LinkedList<TaskCompletionSource> _waiters = new();
    int _limit;
    int _active;

    public DropboxGate(int limit) { _limit = Math.Max(1, limit); }

    public int Limit
    {
        get { lock (_lock) return _limit; }
        set
        {
            var ready = new List<TaskCompletionSource>();
            lock (_lock)
            {
                _limit = Math.Max(1, value);
                while (_active < _limit && _waiters.First is { } w) { _waiters.RemoveFirst(); _active++; ready.Add(w.Value); }
            }
            foreach (var t in ready) t.TrySetResult();
        }
    }

    public async Task<T> RunAsync<T>(Func<Task<T>> op, CancellationToken ct)
    {
        await AcquireAsync(ct).ConfigureAwait(false);
        try { return await op().ConfigureAwait(false); }
        finally { Release(); }
    }

    async Task AcquireAsync(CancellationToken ct)
    {
        TaskCompletionSource tcs;
        LinkedListNode<TaskCompletionSource> node;
        lock (_lock)
        {
            ct.ThrowIfCancellationRequested();
            if (_active < _limit) { _active++; return; }
            tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            node = _waiters.AddLast(tcs);
        }
        using (ct.Register(() =>
        {
            bool removed;
            lock (_lock)
            {
                removed = node.List is not null;
                if (removed) _waiters.Remove(node);
            }
            if (removed) tcs.TrySetCanceled(ct);
        }))
        {
            await tcs.Task.ConfigureAwait(false);
        }
    }

    void Release()
    {
        TaskCompletionSource? next = null;
        lock (_lock)
        {
            if (_active <= _limit && _waiters.First is { } w) { _waiters.RemoveFirst(); next = w.Value; }   // hand the slot on
            else _active--;
        }
        next?.TrySetResult();
    }
}
