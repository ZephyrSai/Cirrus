using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Cirrus.Core;

// iCloud web session: SRP sign-in against idmsa.apple.com, two-factor, trust, accountLogin,
// Advanced Data Protection (PCS) consent, and an authenticated request helper with re-auth and
// back-off. Port of Sources/CirrusCore/Auth/ICloudSession.swift (protocol from rclone + icloudpd).

public sealed class StoredCookie
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    public string? Domain { get; set; }
    public string? Path { get; set; }
    public DateTimeOffset? Expires { get; set; }
}

public sealed record TrustedPhone(int Id, string Number, string Mode);

public sealed class SessionState
{
    public string AppleID { get; set; } = "";
    public string ClientID { get; set; } = ICloudSession.WidgetKey;
    public string FrameID { get; set; } = Guid.NewGuid().ToString().ToLowerInvariant();
    public string? SessionToken { get; set; }
    public string? Scnt { get; set; }
    public string? SessionID { get; set; }
    public string? AccountCountry { get; set; }
    public string? DomainToUse { get; set; }
    public string? TrustToken { get; set; }
    public string? AuthAttributes { get; set; }
    public List<StoredCookie> Cookies { get; set; } = [];
    public byte[]? AccountInfoData { get; set; }

    public SessionState() { }
    public SessionState(string appleID) { AppleID = appleID.ToLowerInvariant(); }

    [JsonIgnore] public J AccountInfo => J.Parse(AccountInfoData);

    static readonly JsonSerializerOptions Opts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public byte[] Serialize() => JsonSerializer.SerializeToUtf8Bytes(this, Opts);
    public static SessionState? Deserialize(byte[]? data)
    {
        if (data is null) return null;
        try { return JsonSerializer.Deserialize<SessionState>(data, Opts); } catch { return null; }
    }
    public SessionState Clone() => Deserialize(Serialize())!;
}

public enum SessionEvent { StateChanged, NeedsSignIn, WaitingForApproval, ApprovalFinished }

public abstract record SignInOutcome
{
    public sealed record SignedIn : SignInOutcome;
    public sealed record NeedsCode(IReadOnlyList<TrustedPhone> Phones, bool DeviceAvailable) : SignInOutcome;
}

public sealed class ICloudSession : IDisposable
{
    public const string WidgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d";
    public const string UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15";
    /// <summary>A stalled request or download fails fast (and is retried where that's safe), as on the Mac.</summary>
    static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

    readonly record struct Endpoints(string Base, string Setup, string Auth);

    readonly object _lock = new();
    SessionState _state;
    readonly HttpClient _http;
    Task? _reauth;
    readonly Dictionary<string, Task> _pcsTasks = [];

    /// <summary>Called whenever the state should be saved (cookies, tokens, account info). Never log its argument.</summary>
    public Action<SessionState>? Persister { get; set; }
    public event Action<SessionEvent, string?>? Event;
    /// <summary>Supplies the remembered password for silent re-authentication (gated by Windows Hello in the app).</summary>
    public Func<Task<string?>>? PasswordProvider { get; set; }
    /// <summary>Test hook: replaces Task.Delay for back-off and approval polling.</summary>
    internal Func<TimeSpan, CancellationToken, Task> Delay { get; set; } = Task.Delay;

    public bool Needs2FA { get; private set; }

    public ICloudSession(SessionState state, HttpMessageHandler? handler = null)
    {
        _state = state;
        handler ??= new SocketsHttpHandler
        {
            UseCookies = false,                 // Cirrus keeps its own cookie jar
            AllowAutoRedirect = false,          // Apple's 330 / 302 answers are handled by hand
            AutomaticDecompression = DecompressionMethods.All,
            MaxConnectionsPerServer = 12,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromSeconds(30),
        };
        _http = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public void Dispose() => _http.Dispose();

    public SessionState State { get { lock (_lock) return _state.Clone(); } }
    public string AppleID { get { lock (_lock) return _state.AppleID; } }

    Endpoints Ep
    {
        get
        {
            lock (_lock)
            {
                if (string.Equals(_state.DomainToUse, "icloud.com.cn", StringComparison.OrdinalIgnoreCase))
                    return new("https://www.icloud.com.cn", "https://setup.icloud.com.cn/setup/ws/1", "https://idmsa.apple.com.cn/appleauth/auth");
            }
            return new("https://www.icloud.com", "https://setup.icloud.com/setup/ws/1", "https://idmsa.apple.com/appleauth/auth");
        }
    }

    string FrameTag { get { lock (_lock) return "auth-" + _state.FrameID; } }

    // MARK: - Account info

    public J AccountInfo { get { lock (_lock) return _state.AccountInfo; } }
    public string? Dsid => AccountInfo["dsInfo"]["dsid"].Str;
    public string? FullName => AccountInfo["dsInfo"]["fullName"].Str;
    public bool HasSession { get { lock (_lock) return _state.Cookies.Count > 0 && !_state.AccountInfo["webservices"].IsNull; } }

    public string? WebserviceURL(string key)
    {
        var ws = AccountInfo["webservices"][key];
        var url = ws["url"].Str;
        if (url is null) return null;
        var status = ws["status"].Str;
        return status is null || status == "active" ? url : null;
    }

    bool PcsRequired(string key) => AccountInfo["webservices"][key]["pcsRequired"].Bool ?? false;

    // MARK: - Low-level transport

    internal sealed record Response(int Status, byte[] Data, HttpResponseHeaders Headers)
    {
        public J Json => J.Parse(Data);
        public string? Header(string name) => Headers.TryGetValues(name, out var v) ? v.FirstOrDefault() : null;
    }

    sealed record Spec(string Url, string Method, IReadOnlyDictionary<string, string> Headers, byte[]? Body);

    static HttpRequestMessage Build(Spec s)
    {
        var req = new HttpRequestMessage(new HttpMethod(s.Method), s.Url);
        HttpContent? content = null;
        if (s.Body is not null) content = new ByteArrayContent(s.Body);
        else if (s.Method is "POST" or "PUT") content = new ByteArrayContent([]);   // Content-Length: 0
        foreach (var (k, v) in s.Headers)
        {
            if (k.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))
            {
                if (content is not null) content.Headers.TryAddWithoutValidation("Content-Type", v);
                continue;
            }
            req.Headers.TryAddWithoutValidation(k, v);
        }
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        req.Content = content;
        return req;
    }

    /// <summary>
    /// One HTTP exchange. A dropped or stale connection ("the network connection was lost", timeouts) is retried for
    /// safe calls: GETs by default, and any call the caller marks idempotent.
    /// </summary>
    async Task<Response> Send(Spec spec, CancellationToken ct, bool? retryNetwork = null)
    {
        var started = DateTimeOffset.UtcNow;
        async Task<Response> Once()
        {
            using var req = Build(spec);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(RequestTimeout);
            HttpResponseMessage resp;
            try { resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("iCloud didn’t answer in time."); }
            using (resp)
            {
                byte[] data;
                try { data = await resp.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("iCloud didn’t answer in time."); }
                Absorb(resp);
                return new Response((int)resp.StatusCode, data, resp.Headers);
            }
        }
        var r = retryNetwork ?? spec.Method == "GET" ? await WithNetworkRetry(Once, ct).ConfigureAwait(false) : await Once().ConfigureAwait(false);
        var uri = new Uri(spec.Url);
        var secs = (DateTimeOffset.UtcNow - started).TotalSeconds;
        // Status lines only (method, host, path, code, time: no query, headers, cookies or bodies) so live problems can be
        // diagnosed safely. Service paths never contain file names.
        var line = $"{spec.Method} {uri.Host}{uri.AbsolutePath} → {r.Status}";
        if (r.Status is >= 200 and < 300) { if (secs > 2) Log.Status($"slow {line} {secs:0.0}s"); else Log.Debug($"{line} ({secs:0.00}s)"); }
        else Log.Status("http " + line);
        return r;
    }

    void Absorb(HttpResponseMessage h)
    {
        string? Hv(string k) => h.Headers.TryGetValues(k, out var v) && v.FirstOrDefault() is { Length: > 0 } s ? s : null;
        lock (_lock)
        {
            if (Hv("X-Apple-ID-Account-Country") is { } c) _state.AccountCountry = c;
            if (Hv("X-Apple-ID-Session-Id") is { } sid) _state.SessionID = sid;
            if (Hv("X-Apple-Session-Token") is { } tok) _state.SessionToken = tok;
            if (Hv("X-Apple-TwoSV-Trust-Token") is { } tt) _state.TrustToken = tt;
            if (Hv("scnt") is { } scnt) _state.Scnt = scnt;
            if (Hv("X-Apple-Auth-Attributes") is { } aa) _state.AuthAttributes = aa;
        }
        if (h.Headers.TryGetValues("Set-Cookie", out var cookies))
            MergeCookies(cookies.Select(c => ParseSetCookie(c, h.RequestMessage?.RequestUri)).OfType<StoredCookie>().ToList());
    }

    /// <summary>Parses one Set-Cookie header value (name=value; Domain=; Path=; Expires=; Max-Age=).</summary>
    internal static StoredCookie? ParseSetCookie(string header, Uri? uri)
    {
        var parts = header.Split(';');
        var nv = parts[0];
        var eq = nv.IndexOf('=');
        if (eq <= 0) return null;
        var c = new StoredCookie { Name = nv[..eq].Trim(), Value = nv[(eq + 1)..].Trim(), Domain = uri?.Host, Path = "/" };
        foreach (var raw in parts.Skip(1))
        {
            var p = raw.Trim();
            var i = p.IndexOf('=');
            var key = (i < 0 ? p : p[..i]).Trim().ToLowerInvariant();
            var val = i < 0 ? "" : p[(i + 1)..].Trim();
            switch (key)
            {
                case "domain": c.Domain = val.TrimStart('.'); break;
                case "path": c.Path = val; break;
                case "expires": if (c.Expires is null && ParseCookieDate(val) is { } d) c.Expires = d; break;
                case "max-age": if (long.TryParse(val, out var secs)) c.Expires = DateTimeOffset.UtcNow.AddSeconds(secs); break;
            }
        }
        return c;
    }

    static readonly string[] CookieDateFormats =
    [
        "ddd, dd MMM yyyy HH:mm:ss 'GMT'", "ddd, dd-MMM-yyyy HH:mm:ss 'GMT'", "ddd, dd-MMM-yy HH:mm:ss 'GMT'",
        "dddd, dd-MMM-yy HH:mm:ss 'GMT'", "ddd MMM d HH:mm:ss yyyy", "ddd, d MMM yyyy HH:mm:ss 'GMT'", "ddd, d-MMM-yyyy HH:mm:ss 'GMT'",
    ];

    internal static DateTimeOffset? ParseCookieDate(string s)
    {
        if (DateTimeOffset.TryParseExact(s, CookieDateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d)) return d;
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out d)) return d;
        return null;
    }

    internal void MergeCookies(IReadOnlyList<StoredCookie> incoming)
    {
        if (incoming.Count == 0) return;
        var now = DateTimeOffset.UtcNow;
        lock (_lock)
        {
            foreach (var c in incoming)
            {
                _state.Cookies.RemoveAll(x => x.Name == c.Name);
                if (c.Value.Length == 0 || c.Value == "\"\"" || (c.Expires is { } e && e < now)) continue;
                _state.Cookies.Add(c);
            }
        }
    }

    public bool HasCookies(IEnumerable<string> names)
    {
        lock (_lock) return names.All(n => _state.Cookies.Any(c => c.Name == n));
    }

    string CookieHeader
    {
        get
        {
            var now = DateTimeOffset.UtcNow;
            lock (_lock)
                return string.Join("; ", _state.Cookies.Where(c => c.Value.Length > 0 && (c.Expires is not { } e || e > now)).Select(c => $"{c.Name}={c.Value}"));
        }
    }

    internal Dictionary<string, string> AuthHeaders()
    {
        var ep = Ep;
        var origin = ep.Auth.Replace("/appleauth/auth", "");
        string clientID, frame = FrameTag;
        lock (_lock) clientID = _state.ClientID;
        var h = new Dictionary<string, string>
        {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["Origin"] = origin,
            ["Referer"] = origin + "/",
            ["X-Apple-Widget-Key"] = clientID,
            ["X-Apple-OAuth-Client-Id"] = clientID,
            ["X-Apple-OAuth-Client-Type"] = "firstPartyAuth",
            ["X-Apple-OAuth-Redirect-URI"] = ep.Base,
            ["X-Apple-OAuth-Require-Grant-Code"] = "true",
            ["X-Apple-OAuth-Response-Mode"] = "web_message",
            ["X-Apple-OAuth-Response-Type"] = "code",
            ["X-Apple-OAuth-State"] = frame,
            ["X-Apple-Frame-Id"] = frame,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["X-Apple-Mandate-Security-Upgrade"] = "0",
            ["X-Apple-I-Require-UE"] = "true",
            ["X-Apple-I-FD-Client-Info"] = "{\"U\":\"" + UserAgent + "\",\"L\":\"en-US\",\"Z\":\"GMT-05:00\",\"V\":\"1.1\",\"F\":\"\"}",
        };
        lock (_lock)
        {
            if (_state.AuthAttributes is { } a) h["X-Apple-Auth-Attributes"] = a;
            if (_state.Scnt is { } s) h["scnt"] = s;
            if (_state.SessionID is { } sid) h["X-Apple-ID-Session-Id"] = sid;
        }
        return h;
    }

    Dictionary<string, string> ServiceHeaders(string contentType = "application/json", bool cookies = true)
    {
        var ep = Ep;
        var h = new Dictionary<string, string> { ["Content-Type"] = contentType, ["Origin"] = ep.Base, ["Referer"] = ep.Base + "/" };
        if (cookies) h["Cookie"] = CookieHeader;
        return h;
    }

    static Spec MakeRequest(string url, string method, IReadOnlyDictionary<string, string>? query, Dictionary<string, string> headers, byte[]? body = null)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out _)) throw ICloudException.Http(0, "Bad URL");
        if (query is { Count: > 0 })
        {
            var q = string.Join("&", query.OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => Uri.EscapeDataString(kv.Key) + "=" + Uri.EscapeDataString(kv.Value)));
            url += (url.Contains('?') ? "&" : "?") + q;
        }
        return new Spec(url, method, headers, body);
    }

    Dictionary<string, string> SetupParams()
    {
        var p = new Dictionary<string, string> { ["clientBuildNumber"] = "2522Project44", ["clientMasteringNumber"] = "2522B2", ["clientId"] = FrameTag };
        if (Dsid is { } d) p["dsid"] = d;
        return p;
    }

    internal static string? ErrorMessage(J j)
    {
        if (j["serviceErrors"][0]["message"].Str is { } m1) return m1;
        if (j["errorMessage"].Str is { } m2) return m2;
        if (j["error"].Str is { Length: > 0 } m3) return m3;
        if (j["reason"].Str is { } m4) return m4;
        return null;
    }

    void Notify(SessionEvent e, string? detail = null) { try { Event?.Invoke(e, detail); } catch { } }

    void Persist()
    {
        SessionState snapshot;
        lock (_lock) snapshot = _state.Clone();
        try { Persister?.Invoke(snapshot); } catch (Exception e) { Log.Status("couldn’t save session: " + e.GetType().Name); }
        Notify(SessionEvent.StateChanged);
    }

    // MARK: - Sign in

    /// <summary>
    /// Full SRP sign-in. If Apple wants a second factor, returns NeedsCode and the UI calls
    /// SubmitCode / RequestSMS / SubmitSMSCode. Otherwise completes accountLogin.
    /// </summary>
    public async Task<SignInOutcome> SignInAsync(string password, bool forceFresh = false, CancellationToken ct = default)
    {
        string appleID;
        lock (_lock) { if (forceFresh) _state.TrustToken = null; appleID = _state.AppleID; }
        Needs2FA = false;
        await AuthStart(ct).ConfigureAwait(false);
        await AuthFederate(appleID, ct).ConfigureAwait(false);
        var client = new AppleSRPClient();
        var ep = Ep;
        var init = await Send(MakeRequest(ep.Auth + "/signin/init", "POST", null, AuthHeaders(), Jx.Bytes(new JsonObject
        {
            ["a"] = Convert.ToBase64String(client.ABytes),
            ["accountName"] = appleID,
            ["protocols"] = new JsonArray("s2k", "s2k_fo"),
        })), ct).ConfigureAwait(false);
        if (init.Status != 200)
        {
            if (init.Status is 401 or 403) throw new ICloudException(ICloudErrorKind.BadCredentials);
            throw ICloudException.Http(init.Status, ErrorMessage(init.Json));
        }
        var j = init.Json;
        byte[] b, salt;
        try
        {
            b = Convert.FromBase64String(j["b"].Str ?? throw new FormatException());
            salt = Convert.FromBase64String(j["salt"].Str ?? throw new FormatException());
        }
        catch (FormatException) { throw ICloudException.Server("Apple returned an unexpected sign-in challenge."); }
        if (j["iteration"].Int is not int iterations || j["protocol"].Str is not string proto || j["c"].Str is not string c)
            throw ICloudException.Server("Apple returned an unexpected sign-in challenge.");
        var key = AppleSRPClient.DerivePassword(password, salt, iterations, proto);
        client.ProcessChallenge(appleID, key, salt, b);
        string? trust;
        lock (_lock) trust = _state.TrustToken;
        var trustTokens = new JsonArray();
        if (trust is not null) trustTokens.Add(trust);
        var complete = await Send(MakeRequest(ep.Auth + "/signin/complete", "POST", new Dictionary<string, string> { ["isRememberMeEnabled"] = "true" }, AuthHeaders(),
            Jx.Bytes(new JsonObject
            {
                ["accountName"] = appleID,
                ["m1"] = Convert.ToBase64String(client.M1),
                ["m2"] = Convert.ToBase64String(client.M2),
                ["c"] = c,
                ["rememberMe"] = true,
                ["trustTokens"] = trustTokens,
            })), ct).ConfigureAwait(false);
        switch (complete.Status)
        {
            case 200: break;
            case 409: Needs2FA = true; break;
            case 412:
                var r = await Send(MakeRequest(ep.Auth + "/repair/complete", "POST", null, AuthHeaders(), Jx.Bytes(new JsonObject())), ct).ConfigureAwait(false);
                if (r.Status != 200) throw ICloudException.Http(r.Status, "Apple asked to repair this account; sign in once at icloud.com.");
                break;
            case 401: case 403: throw new ICloudException(ICloudErrorKind.BadCredentials);
            default: throw ICloudException.Http(complete.Status, ErrorMessage(complete.Json));
        }
        if (Needs2FA)
        {
            AuthStateInfo? auth = null;
            try { auth = await AuthState(ct).ConfigureAwait(false); } catch (OperationCanceledException) { throw; } catch { }
            if (auth is { NoTrustedDevices: true, Phones.Count: > 0 }) return new SignInOutcome.NeedsCode(auth.Phones, false);
            // Ask Apple to push the code to trusted devices.
            try { await Send(MakeRequest(ep.Auth + "/verify/trusteddevice/securitycode", "PUT", null, AuthHeaders()), ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { throw; } catch { }
            Persist();
            return new SignInOutcome.NeedsCode(auth?.Phones ?? [], true);
        }
        await AccountLogin(ct).ConfigureAwait(false);
        return new SignInOutcome.SignedIn();
    }

    async Task AuthStart(CancellationToken ct)
    {
        var ep = Ep;
        string clientID;
        lock (_lock) clientID = _state.ClientID;
        var frame = FrameTag;
        var q = new Dictionary<string, string>
        {
            ["frame_id"] = frame, ["language"] = "en_US", ["skVersion"] = "7", ["iframeId"] = frame, ["client_id"] = clientID,
            ["redirect_uri"] = ep.Base, ["response_type"] = "code", ["response_mode"] = "web_message", ["state"] = frame, ["authVersion"] = "latest",
        };
        var r = await Send(MakeRequest(ep.Auth + "/authorize/signin", "GET", q, new Dictionary<string, string> { ["Accept"] = "*/*" }), ct).ConfigureAwait(false);
        if (r.Status != 200) throw ICloudException.Http(r.Status, "Couldn’t reach Apple’s sign-in service.");
    }

    async Task AuthFederate(string accountName, CancellationToken ct)
    {
        var r = await Send(MakeRequest(Ep.Auth + "/federate", "POST", new Dictionary<string, string> { ["isRememberMeEnabled"] = "true" }, AuthHeaders(),
            Jx.Bytes(new JsonObject { ["accountName"] = accountName, ["rememberMe"] = true })), ct).ConfigureAwait(false);
        if (r.Status != 200) throw ICloudException.Http(r.Status, ErrorMessage(r.Json) ?? "Apple didn’t accept this Apple ID.");
    }

    sealed record AuthStateInfo(List<TrustedPhone> Phones, bool NoTrustedDevices);

    async Task<AuthStateInfo> AuthState(CancellationToken ct)
    {
        var r = await Send(MakeRequest(Ep.Auth, "GET", null, AuthHeaders()), ct).ConfigureAwait(false);
        var j = r.Json;
        if (!j["phoneNumberVerification"].IsNull && j["authenticationType"].IsNull) j = j["phoneNumberVerification"];
        var phones = j["trustedPhoneNumbers"].Array.ToList();
        if (phones.Count == 0 && !j["trustedPhoneNumber"].IsNull) phones = [j["trustedPhoneNumber"]];
        var list = new List<TrustedPhone>();
        foreach (var p in phones)
        {
            if (p["id"].Int is not int id) continue;
            list.Add(new TrustedPhone(id, p["numberWithDialCode"].Str ?? p["obfuscatedNumber"].Str ?? $"Phone {id}", p["pushMode"].Str ?? "sms"));
        }
        return new AuthStateInfo(list, j["noTrustedDevices"].Bool ?? false);
    }

    /// <summary>Code shown on a trusted Apple device.</summary>
    public async Task SubmitCodeAsync(string code, CancellationToken ct = default)
    {
        var r = await Send(MakeRequest(Ep.Auth + "/verify/trusteddevice/securitycode", "POST", null, AuthHeaders(),
            Jx.Bytes(new JsonObject { ["securityCode"] = new JsonObject { ["code"] = code } })), ct).ConfigureAwait(false);
        Check2FAResponse(r);
        await TrustAndLogin(ct).ConfigureAwait(false);
    }

    public async Task RequestSmsAsync(TrustedPhone phone, CancellationToken ct = default)
    {
        var r = await Send(MakeRequest(Ep.Auth + "/verify/phone", "PUT", null, AuthHeaders(),
            Jx.Bytes(new JsonObject { ["phoneNumber"] = new JsonObject { ["id"] = phone.Id }, ["mode"] = phone.Mode })), ct).ConfigureAwait(false);
        if (r.Status is < 200 or >= 300) throw ICloudException.Http(r.Status, ErrorMessage(r.Json) ?? "Couldn’t send a text message.");
    }

    public async Task SubmitSmsCodeAsync(string code, TrustedPhone phone, CancellationToken ct = default)
    {
        var r = await Send(MakeRequest(Ep.Auth + "/verify/phone/securitycode", "POST", null, AuthHeaders(),
            Jx.Bytes(new JsonObject
            {
                ["securityCode"] = new JsonObject { ["code"] = code },
                ["phoneNumber"] = new JsonObject { ["id"] = phone.Id },
                ["mode"] = phone.Mode,
            })), ct).ConfigureAwait(false);
        Check2FAResponse(r);
        await TrustAndLogin(ct).ConfigureAwait(false);
    }

    static void Check2FAResponse(Response r)
    {
        var code = r.Status;
        if (code is >= 200 and < 300) return;
        // Since mid-2026 idmsa can answer 409 even for an accepted code; a session token means success.
        if (code == 409 && r.Header("X-Apple-Session-Token") is not null) return;
        if (code is 400 or 401 or 403) throw ICloudException.Server(ErrorMessage(r.Json) ?? "That code isn’t right. Try again.");
        throw ICloudException.Http(code, ErrorMessage(r.Json));
    }

    async Task TrustAndLogin(CancellationToken ct)
    {
        var r = await Send(MakeRequest(Ep.Auth + "/2sv/trust", "GET", null, AuthHeaders()), ct).ConfigureAwait(false);
        if (r.Status is < 200 or >= 300) throw ICloudException.Http(r.Status, "Apple didn’t trust this session.");
        Needs2FA = false;
        await AccountLogin(ct).ConfigureAwait(false);
    }

    async Task AccountLogin(CancellationToken ct)
    {
        JsonObject body;
        lock (_lock)
            body = new JsonObject
            {
                ["accountCountryCode"] = _state.AccountCountry ?? "",
                ["dsWebAuthToken"] = _state.SessionToken ?? "",
                ["extended_login"] = true,
                ["trustToken"] = _state.TrustToken ?? "",
            };
        var r = await Send(MakeRequest(Ep.Setup + "/accountLogin", "POST", null, ServiceHeaders(cookies: false), Jx.Bytes(body)), ct).ConfigureAwait(false);
        switch (r.Status)
        {
            case 200:
                lock (_lock) _state.AccountInfoData = r.Data;
                var info = AccountInfo;
                if (info["hsaChallengeRequired"].Bool == true && info["dsInfo"]["hsaVersion"].Int == 2)
                {
                    Needs2FA = true;
                    throw new ICloudException(ICloudErrorKind.TwoFactorRequired);
                }
                Persist();
                return;
            case 302:
                var domain = r.Json["domainToUse"].Str ?? "";
                bool alreadyCn;
                lock (_lock) alreadyCn = string.Equals(_state.DomainToUse, "icloud.com.cn", StringComparison.OrdinalIgnoreCase);
                if (!domain.Equals("icloud.com.cn", StringComparison.OrdinalIgnoreCase) || alreadyCn)
                    throw ICloudException.Server($"Unsupported iCloud region “{domain}”.");
                lock (_lock) _state.DomainToUse = "iCloud.com.cn";
                throw ICloudException.NeedsSignIn();   // China accounts must start over on the .cn endpoints
            case 401: case 421:
                throw ICloudException.NeedsSignIn();
            default:
                throw ICloudException.Http(r.Status, ErrorMessage(r.Json));
        }
    }

    /// <summary>Re-validate an existing cookie session.</summary>
    public async Task ValidateAsync(CancellationToken ct = default)
    {
        var r = await Send(MakeRequest(Ep.Setup + "/validate", "POST", SetupParams(), ServiceHeaders()), ct).ConfigureAwait(false);
        if (r.Status != 200) throw ICloudException.NeedsSignIn();
        lock (_lock) _state.AccountInfoData = r.Data;
        Persist();
    }

    public void SignOut()
    {
        lock (_lock) { _state.Cookies = []; _state.SessionToken = null; _state.AccountInfoData = null; }
        Persist();
    }

    /// <summary>
    /// Silent re-authentication: accountLogin with stored tokens, then SRP with the remembered password
    /// and trust token. Throws NeedsSignIn when a human is required. Concurrent callers share one attempt.
    /// </summary>
    internal Task Reauthenticate(CancellationToken ct)
    {
        lock (_lock)
        {
            if (_reauth is { IsCompleted: false } t) return t;
            _reauth = Task.Run(() => DoReauth(ct), CancellationToken.None);
            return _reauth;
        }
    }

    async Task DoReauth(CancellationToken ct)
    {
        bool hasToken;
        lock (_lock) hasToken = _state.SessionToken is not null;
        if (hasToken)
        {
            try { await AccountLogin(ct).ConfigureAwait(false); return; }
            catch (ICloudException e) when (e.Kind == ICloudErrorKind.TwoFactorRequired) { throw ICloudException.NeedsSignIn(); }
            catch (OperationCanceledException) { throw; }
            catch { }
        }
        if (PasswordProvider is { } provider && await provider().ConfigureAwait(false) is { } pw)
        {
            var outcome = await SignInAsync(pw, ct: ct).ConfigureAwait(false);
            if (outcome is SignInOutcome.NeedsCode) { Notify(SessionEvent.NeedsSignIn); throw ICloudException.NeedsSignIn(); }
            return;
        }
        Notify(SessionEvent.NeedsSignIn);
        throw ICloudException.NeedsSignIn();
    }

    // MARK: - Advanced Data Protection

    internal static readonly Dictionary<string, string[]> PcsCookies = new()
    {
        ["photos"] = ["X-APPLE-WEBAUTH-PCS-Photos", "X-APPLE-WEBAUTH-PCS-Sharing"],
        ["iclouddrive"] = ["X-APPLE-WEBAUTH-PCS-Documents"],
    };

    /// <summary>Ensures PCS cookies exist for a service on ADP accounts (may wait for device approval).</summary>
    public Task EnsurePcsAsync(string app, string webservice, CancellationToken ct = default)
    {
        if (!PcsRequired(webservice) || !PcsCookies.TryGetValue(app, out var names) || HasCookies(names)) return Task.CompletedTask;
        lock (_lock)
        {
            if (_pcsTasks.TryGetValue(app, out var t) && !t.IsCompleted) return t;
            var task = Task.Run(() => AcquirePcs(app, names, ct), CancellationToken.None);
            _pcsTasks[app] = task;
            return task;
        }
    }

    async Task<J> SetupCall(string name, string method, JsonNode? body, CancellationToken ct)
    {
        var r = await Send(MakeRequest(Ep.Setup + "/" + name, method, SetupParams(), ServiceHeaders("text/plain;charset=UTF-8"),
            body is null ? null : Jx.Bytes(body)), ct).ConfigureAwait(false);
        if (r.Status is 401 or 421) throw ICloudException.NeedsSignIn();
        if (r.Status is < 200 or >= 300) throw ICloudException.Http(r.Status, ErrorMessage(r.Json));
        return r.Json;
    }

    async Task AcquirePcs(string app, string[] names, CancellationToken ct)
    {
        Notify(SessionEvent.WaitingForApproval, app);
        try
        {
            var workflow = Guid.NewGuid().ToString().ToUpperInvariant();
            JsonObject Wf() => new() { ["workflowUuid"] = workflow };
            bool usedConsentFlow = false;
            J st = J.Null;
            bool gotState;
            try { st = await SetupCall("requestWebAccessState", "POST", Wf(), ct).ConfigureAwait(false); gotState = true; }
            catch (OperationCanceledException) { throw; }
            catch { gotState = false; }
            if (gotState)
            {
                usedConsentFlow = true;
                if (st["isWebAccessAllowed"].Bool == false) throw new ICloudException(ICloudErrorKind.WebAccessDisabled);
                if (st["isDeviceConsentedForPCS"].Bool != true)
                {
                    await SetupCall("enableDeviceConsentForPCS", "POST", Wf(), ct).ConfigureAwait(false);
                    var deadline = DateTimeOffset.UtcNow.AddMinutes(5);
                    while (st["isDeviceConsentedForPCS"].Bool != true)
                    {
                        if (DateTimeOffset.UtcNow > deadline) throw new ICloudException(ICloudErrorKind.ApprovalTimedOut);
                        await Delay(TimeSpan.FromSeconds(3), ct).ConfigureAwait(false);
                        st = await SetupCall("requestWebAccessState", "POST", Wf(), ct).ConfigureAwait(false);
                    }
                }
                try { await SetupCall("generateSessionIdToken", "GET", null, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { throw; } catch { }
            }
            for (int attempt = 0; attempt < 40; attempt++)
            {
                var body = new JsonObject { ["appName"] = app, ["derivedFromUserAction"] = attempt == 0 };
                if (usedConsentFlow) { body["isFinalAttempt"] = false; body["workflowUuid"] = workflow; }
                var r = await SetupCall("requestPCS", "POST", body, ct).ConfigureAwait(false);
                if (r["status"].Str == "success")
                {
                    if (HasCookies(names)) { Persist(); return; }
                    throw ICloudException.Server("iCloud approved web access but didn’t return the keys. Try again in a minute.");
                }
                await Delay(TimeSpan.FromSeconds(attempt < 10 ? 3 : 8), ct).ConfigureAwait(false);
            }
            throw new ICloudException(ICloudErrorKind.ApprovalTimedOut);
        }
        finally { Notify(SessionEvent.ApprovalFinished, app); }
    }

    // MARK: - Authenticated service requests

    /// <summary>
    /// JSON request to an iCloud web service with re-auth (401/421), ADP consent (423) and back-off on
    /// 429/5xx for idempotent calls.
    /// </summary>
    public async Task<J> RequestAsync(string url, string method = "POST", IReadOnlyDictionary<string, string>? query = null, JsonNode? json = null,
        byte[]? rawBody = null, string contentType = "application/json", (string app, string ws)? pcs = null, bool idempotent = true, CancellationToken ct = default)
    {
        if (pcs is { } p0) await EnsurePcsAsync(p0.app, p0.ws, ct).ConfigureAwait(false);
        var body = rawBody ?? (json is null ? null : Jx.Bytes(json));
        bool reauthed = false, pcsRetried = false;
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var r = await Send(MakeRequest(url, method, query, ServiceHeaders(contentType), body), ct, retryNetwork: idempotent).ConfigureAwait(false);
            var code = r.Status;
            if (code is >= 200 and < 300) return r.Json;
            if (code is 401 or 421 && !reauthed)
            {
                reauthed = true;
                await Reauthenticate(ct).ConfigureAwait(false);
                continue;
            }
            if ((code == 423 || (code == 403 && Encoding.UTF8.GetString(r.Data).Contains("PCS"))) && pcs is { } p && !pcsRetried)
            {
                pcsRetried = true;
                lock (_lock) _state.Cookies.RemoveAll(c => PcsCookies.TryGetValue(p.app, out var n) && n.Contains(c.Name));
                await EnsurePcsAsync(p.app, p.ws, ct).ConfigureAwait(false);
                continue;
            }
            // 429 means "not processed, slow down": always safe to repeat. A 5xx may come after the change was applied,
            // so only idempotent calls (listings, lookups) are repeated on those.
            if ((code == 429 || (code >= 500 && idempotent)) && attempt < 5)
            {
                attempt++;
                var retryAfter = r.Header("Retry-After") is { } ra && double.TryParse(ra, NumberStyles.Float, CultureInfo.InvariantCulture, out var s) ? s : Math.Pow(2, attempt) * 0.5;
                await Delay(TimeSpan.FromSeconds(Math.Min(retryAfter, 30)), ct).ConfigureAwait(false);
                continue;
            }
            if (code == 404) throw ICloudException.NotFound();
            if (code == 409) throw ICloudException.Conflict();
            throw ICloudException.Http(code, ErrorMessage(r.Json) ?? Encoding.UTF8.GetString(r.Data, 0, Math.Min(200, r.Data.Length)));
        }
    }

    /// <summary>Download a content URL to a file with progress. Follows Apple's odd 330 redirects by hand.</summary>
    public async Task DownloadAsync(string urlString, string destination, long? expectedSize, Action<long, long>? progress, CancellationToken ct = default)
    {
        var headers = ServiceHeaders("application/octet-stream");
        headers.Remove("Content-Type");
        var current = urlString.Replace("${f}", "file");
        for (int hop = 0; hop < 5; hop++)
        {
            if (!Uri.TryCreate(current, UriKind.Absolute, out var uri)) throw ICloudException.Http(0, "Bad download URL");
            // iCloud cookies go only to Apple's own hosts, never to a host a URL or redirect happens to name.
            var hopHeaders = new Dictionary<string, string>(headers);
            if (!IsAppleHost(uri.Host)) hopHeaders.Remove("Cookie");
            var next = await WithNetworkRetry(async () =>
            {
                using var req = Build(new Spec(uri.ToString(), "GET", hopHeaders, null));
                using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                var code = (int)resp.StatusCode;
                if (code is 301 or 302 or 303 or 307 or 308 or 330 && resp.Headers.Location is { } loc)
                    return loc.IsAbsoluteUri ? loc.ToString() : new Uri(uri, loc).ToString();
                if (code is < 200 or >= 300)
                {
                    Log.Status($"download from {uri.Host} → {code}");   // content URLs can carry names: host only
                    if (code is 401 or 403 or 410) throw ICloudException.Http(code, "Download link expired");
                    throw ICloudException.Http(code, "Download failed");
                }
                var dlStarted = DateTimeOffset.UtcNow;
                var total = resp.Content.Headers.ContentLength is long cl && cl > 0 ? cl : expectedSize ?? 0;
                var dir = Path.GetDirectoryName(destination)!;
                Directory.CreateDirectory(dir);
                var part = Path.Combine(dir, ".cirrus-dl-" + Guid.NewGuid().ToString("N")[..8]);
                try
                {
                    await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
                    await using (var dst = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                        await CopyWithProgress(src, dst, total, progress, ct).ConfigureAwait(false);
                    File.Move(part, destination, overwrite: true);
                    var secs = (DateTimeOffset.UtcNow - dlStarted).TotalSeconds;
                    var bytes = new FileInfo(destination).Length;
                    if (secs > 1.5) Log.Status($"download {bytes.ByteString()} in {secs:0.0}s ({((long)(bytes / Math.Max(secs, 0.01))).ByteString()}/s)");
                }
                finally { try { if (File.Exists(part)) File.Delete(part); } catch { } }
                return (string?)null;
            }, ct).ConfigureAwait(false);
            if (next is null) return;
            current = next;
        }
        throw ICloudException.Http(0, "Too many redirects");
    }

    /// <summary>Streams with stall detection (no bytes for 90 s → network error, retried by the caller).</summary>
    static async Task CopyWithProgress(Stream src, Stream dst, long total, Action<long, long>? progress, CancellationToken ct)
    {
        var buf = new byte[1 << 20];
        long done = 0;
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        while (true)
        {
            stall.CancelAfter(StallTimeout);
            int n;
            try { n = await src.ReadAsync(buf, stall.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("The download stalled."); }
            if (n == 0) break;
            await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
            done += n;
            progress?.Invoke(done, Math.Max(total, done));
        }
        progress?.Invoke(done, Math.Max(total, done));
    }

    /// <summary>Upload a file (raw body, or a streamed multipart/form-data body) with progress; returns parsed JSON.</summary>
    public async Task<J> UploadAsync(string urlString, IReadOnlyDictionary<string, string>? query, string file, string? multipartName, string contentType,
        Action<long, long>? progress, CancellationToken ct = default)
    {
        bool reauthed = false;
        while (true)
        {
            var spec = MakeRequest(urlString, "POST", query, ServiceHeaders(contentType));
            var (status, data) = await WithNetworkRetry(async () =>
            {
                using var req = Build(spec with { Body = null, Method = "GET" });   // headers only; body set below
                req.Method = HttpMethod.Post;
                HttpContent content = multipartName is not null
                    ? new MultipartFileContent(file, multipartName, multipartName, contentType, progress)
                    : new FileUploadContent(file, contentType, progress);
                req.Content = content;
                using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
                Absorb(resp);
                var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
                var u = req.RequestUri!;
                Log.Status($"upload to {u.Host} → {(int)resp.StatusCode}");
                return ((int)resp.StatusCode, bytes);
            }, ct, NothingWasSent).ConfigureAwait(false);   // an upload is repeated only when it certainly never reached the server
            if (status is 401 or 421 && !reauthed) { reauthed = true; await Reauthenticate(ct).ConfigureAwait(false); continue; }
            var json = J.Parse(data);
            if (status is < 200 or >= 300) throw ICloudException.Http(status, ErrorMessage(json) ?? "Upload failed");
            return json;
        }
    }

    /// <summary>
    /// Retries transient network failures (Wi-Fi drop, sleep/resume, timeouts, stalls) with back-off. Only for safe
    /// calls; <paramref name="retryable"/> narrows which failures may be repeated (uploads: only before anything was sent).
    /// </summary>
    internal async Task<T> WithNetworkRetry<T>(Func<Task<T>> op, CancellationToken ct, Func<Exception, bool>? retryable = null)
    {
        int attempt = 0;
        while (true)
        {
            try { return await op().ConfigureAwait(false); }
            catch (Exception e) when (!ct.IsCancellationRequested && (retryable ?? IsTransient)(e) && attempt < 4)
            {
                attempt++;
                Log.Status($"network hiccup ({e.GetType().Name}), retry {attempt} of 4");
                await Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt - 1) * 0.5), ct).ConfigureAwait(false);   // 0.5, 1, 2, 4 s
            }
        }
    }

    /// <summary>Failures that happen before a request leaves this PC (name lookup, TLS handshake).</summary>
    internal static bool NothingWasSent(Exception e) =>
        e is HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError or HttpRequestError.SecureConnectionError };

    internal static bool IsAppleHost(string host)
    {
        host = host.ToLowerInvariant();
        foreach (var d in new[] { "icloud.com", "icloud-content.com", "apple.com", "icloud.com.cn", "icloud-content.com.cn", "apple.com.cn" })
            if (host == d || host.EndsWith("." + d, StringComparison.Ordinal)) return true;
        return false;
    }

    internal static bool IsTransient(Exception e) => e switch
    {
        TimeoutException => true,
        HttpRequestException h => h.HttpRequestError is HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError
            or HttpRequestError.SecureConnectionError or HttpRequestError.ResponseEnded or HttpRequestError.Unknown || h.InnerException is IOException or SocketException,
        IOException io => io.InnerException is SocketException || io is HttpIOException,
        TaskCanceledException tc => tc.InnerException is TimeoutException,
        _ => false,
    };

    // MARK: - Storage

    /// <summary>iCloud storage plan usage, broken down by category (Photos, Backups, Documents, Mail…).</summary>
    public async Task<StorageUsage> StorageUsageAsync(CancellationToken ct = default)
    {
        var j = await RequestAsync(Ep.Setup + "/storageUsageInfo", query: SetupParams(), ct: ct).ConfigureAwait(false);
        var info = j["storageUsageInfo"];
        var cats = j["storageUsageByMedia"].Array.Select(c => new StorageUsage.Category(
            c["mediaKey"].Str ?? "", c["displayLabel"].Str ?? c["mediaKey"].Str ?? "", c["usageInBytes"].Int64 ?? 0, c["displayColor"].Str)).ToList();
        return new StorageUsage(info["totalStorageInBytes"].Int64 ?? 0, info["usedStorageInBytes"].Int64 ?? 0, cats);
    }
}

/// <summary>Raw file request body with upload progress.</summary>
sealed class FileUploadContent : HttpContent
{
    readonly string _path;
    readonly Action<long, long>? _progress;
    public FileUploadContent(string path, string contentType, Action<long, long>? progress)
    {
        _path = path; _progress = progress;
        Headers.TryAddWithoutValidation("Content-Type", contentType);
    }
    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context) => await SerializeToStreamAsync(stream, context, CancellationToken.None);
    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct)
    {
        await using var fs = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true);
        var total = fs.Length;
        var buf = new byte[1 << 20];
        long done = 0;
        int n;
        while ((n = await fs.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
        {
            await stream.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
            done += n;
            _progress?.Invoke(done, total);
        }
    }
    protected override bool TryComputeLength(out long length) { length = new FileInfo(_path).Length; return true; }
}

/// <summary>
/// multipart/form-data with one file part, streamed from disk (no temp copy, so a 40 GB upload doesn't need
/// another 40 GB free). Same bytes on the wire as the Mac app's Multipart.write.
/// </summary>
sealed class MultipartFileContent : HttpContent
{
    readonly string _path;
    readonly byte[] _head, _tail;
    readonly Action<long, long>? _progress;

    public MultipartFileContent(string path, string fieldName, string filename, string mime, Action<long, long>? progress)
    {
        _path = path; _progress = progress;
        var boundary = "CirrusBoundary" + Guid.NewGuid().ToString("N");
        var esc = filename.Replace("\"", "%22");
        _head = Encoding.UTF8.GetBytes($"--{boundary}\r\nContent-Disposition: form-data; name=\"{fieldName.Replace("\"", "%22")}\"; filename=\"{esc}\"\r\nContent-Type: {mime}\r\n\r\n");
        _tail = Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");
        Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");
    }

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context) => await SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct)
    {
        await stream.WriteAsync(_head, ct).ConfigureAwait(false);
        await using (var fs = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true))
        {
            var total = fs.Length;
            var buf = new byte[1 << 20];
            long done = 0;
            int n;
            while ((n = await fs.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
            {
                await stream.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                done += n;
                _progress?.Invoke(done, total);
            }
        }
        await stream.WriteAsync(_tail, ct).ConfigureAwait(false);
    }

    protected override bool TryComputeLength(out long length) { length = _head.Length + new FileInfo(_path).Length + _tail.Length; return true; }
}

public sealed record StorageUsage(long Total, long Used, IReadOnlyList<StorageUsage.Category> Categories)
{
    public sealed record Category(string Key, string Label, long Bytes, string? Color);
    public long Available => Math.Max(0, Total - Used);
}
