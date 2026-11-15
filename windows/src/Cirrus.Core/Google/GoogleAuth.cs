using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Cirrus.Core;

// Google sign-in for installed apps (port of GoogleAuth.swift): the default browser shows Google's consent page, Google
// redirects to a one-shot listener on http://127.0.0.1:<random port>, and the code is exchanged with PKCE (S256).
// Bring-your-own client: the user creates a "Desktop app" OAuth client in their own Google Cloud project.
// See https://developers.google.com/identity/protocols/oauth2/native-app

public static class GoogleScopes
{
    /// <summary>Only files and folders Cirrus creates (non-sensitive).</summary>
    public const string DriveFile = "https://www.googleapis.com/auth/drive.file";
    /// <summary>Add photos and videos to the library and create albums (no read access to the library).</summary>
    public const string PhotosAppend = "https://www.googleapis.com/auth/photoslibrary.appendonly";
    public static readonly IReadOnlyList<string> All = [DriveFile, PhotosAppend];
    /// <summary>Google → iCloud only: read all of My Drive (asked for when the user starts that direction).</summary>
    public const string DriveReadonly = "https://www.googleapis.com/auth/drive.readonly";
    /// <summary>Google → iCloud only: photos the user picks in Google Photos' own picker.</summary>
    public const string PhotosPicker = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly";
    /// <summary>What "Google → iCloud" asks for (one consent screen: Google doesn't add scopes to a desktop app's grant later).</summary>
    public static readonly IReadOnlyList<string> Import = [DriveFile, PhotosAppend, DriveReadonly, PhotosPicker];
}

/// <summary>
/// The user's own OAuth client ("Desktop app" type). Google treats desktop clients as public: the secret isn't
/// confidential, but Cirrus still keeps it DPAPI-encrypted.
/// </summary>
public sealed record GoogleOAuthClient
{
    public string ClientID { get; init; }
    public string? ClientSecret { get; init; }

    public GoogleOAuthClient(string clientID, string? clientSecret)
    {
        ClientID = (clientID ?? "").Trim();
        var s = clientSecret?.Trim();
        ClientSecret = string.IsNullOrEmpty(s) ? null : s;
    }

    const string Suffix = ".apps.googleusercontent.com";

    /// <summary>Desktop client IDs look like <c>1234-abc.apps.googleusercontent.com</c>.</summary>
    public bool LooksValid => ClientID.EndsWith(Suffix, StringComparison.Ordinal) && ClientID.Length > Suffix.Length + 3 && !ClientID.Contains(' ');
}

public sealed class GoogleTokens
{
    public string AccessToken { get; set; } = "";
    public DateTimeOffset ExpiresAt { get; set; }
    public string? RefreshToken { get; set; }
    public List<string> Scopes { get; set; } = [];
    public bool Has(string scope) => Scopes.Contains(scope);
}

public enum GoogleErrorKind
{
    NotConfigured, AccessDenied, StateMismatch, TimedOut, Reconnect, MissingScope, Http, StorageFull, DailyLimit, RateLimited,
    UploadExpired, Cancelled, BadResponse,
}

/// <summary>Errors from Google sign-in and APIs, with the same wording as the Mac app.</summary>
public sealed class GoogleException : Exception
{
    public GoogleErrorKind Kind { get; }
    public int Status { get; }
    public string Detail { get; }

    public GoogleException(GoogleErrorKind kind, string detail = "", int status = 0) : base(Describe(kind, detail, status))
    {
        Kind = kind; Detail = detail; Status = status;
    }

    public static GoogleException NotConfigured() => new(GoogleErrorKind.NotConfigured);
    public static GoogleException AccessDenied() => new(GoogleErrorKind.AccessDenied);
    public static GoogleException StateMismatch() => new(GoogleErrorKind.StateMismatch);
    public static GoogleException TimedOut() => new(GoogleErrorKind.TimedOut);
    public static GoogleException Reconnect(string why) => new(GoogleErrorKind.Reconnect, why);
    public static GoogleException MissingScope(string what) => new(GoogleErrorKind.MissingScope, what);
    public static GoogleException Http(int code, string message) => new(GoogleErrorKind.Http, message, code);
    public static GoogleException StorageFull() => new(GoogleErrorKind.StorageFull);
    public static GoogleException DailyLimit(string what) => new(GoogleErrorKind.DailyLimit, what);
    public static GoogleException RateLimited() => new(GoogleErrorKind.RateLimited);
    public static GoogleException UploadExpired() => new(GoogleErrorKind.UploadExpired);
    public static GoogleException Cancelled() => new(GoogleErrorKind.Cancelled);
    public static GoogleException BadResponse(string s) => new(GoogleErrorKind.BadResponse, s);

    static string Describe(GoogleErrorKind kind, string detail, int status) => kind switch
    {
        GoogleErrorKind.NotConfigured => "Set up Google access first: Cirrus needs the client ID from your Google Cloud project.",
        GoogleErrorKind.AccessDenied => "Google access wasn’t allowed. Select Connect Google again and choose Continue/Allow on Google’s page.",
        GoogleErrorKind.StateMismatch => "The answer from Google didn’t match this sign-in, so Cirrus ignored it. Try connecting again.",
        GoogleErrorKind.TimedOut => "Timed out waiting for you to finish signing in to Google in your browser.",
        GoogleErrorKind.Reconnect => detail,
        GoogleErrorKind.MissingScope => $"Google didn’t give Cirrus access to {detail}. Connect again and tick every box on Google’s page.",
        GoogleErrorKind.Http => string.IsNullOrEmpty(detail) ? $"Google returned HTTP {status}." : $"{detail} (HTTP {status})",
        GoogleErrorKind.StorageFull => "Your Google storage is full. Free up space or buy more storage, then run the move again — it continues where it stopped.",
        GoogleErrorKind.DailyLimit => detail,
        GoogleErrorKind.RateLimited => "Google is limiting how fast Cirrus can upload. Wait a while and run the move again; finished items are kept.",
        GoogleErrorKind.UploadExpired => "Google ended the upload session; Cirrus starts that file again.",
        GoogleErrorKind.Cancelled => "Cancelled.",
        GoogleErrorKind.BadResponse => detail,
        _ => "Google error.",
    };
}

/// <summary>Proof Key for Code Exchange (RFC 7636), S256.</summary>
public sealed class Pkce
{
    public string Verifier { get; }
    public string Challenge { get; }

    public Pkce() : this(Random(48)) { }   // 64 characters
    public Pkce(string verifier)
    {
        Verifier = verifier;
        Challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
    }

    public static string Random(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));

    public static string Base64Url(byte[] d) => Convert.ToBase64String(d).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

/// <summary>
/// One-shot HTTP listener on 127.0.0.1 (never other interfaces) for the OAuth redirect. On Windows the port is bound
/// exclusively, so no other program can listen on it as well.
/// </summary>
sealed class LoopbackReceiver : IDisposable
{
    readonly TcpListener _listener;
    public int Port { get; }

    public LoopbackReceiver()
    {
        try
        {
            _listener = new TcpListener(IPAddress.Loopback, 0);
            if (OperatingSystem.IsWindows()) _listener.ExclusiveAddressUse = true;
            _listener.Start(8);
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        }
        catch (SocketException) { throw GoogleException.BadResponse("Couldn’t open a local port for the Google sign-in."); }
    }

    public string RedirectURI => $"http://127.0.0.1:{Port}";

    public void Dispose() { try { _listener.Stop(); } catch { } }

    /// <summary>Waits until the browser delivers Google's redirect; answers other requests (favicon…) with 404.</summary>
    public async Task<Dictionary<string, string>> WaitForRedirectAsync(TimeSpan timeout, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        while (true)
        {
            TcpClient c;
            try { c = await _listener.AcceptTcpClientAsync(deadline.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw GoogleException.TimedOut(); }
            catch (OperationCanceledException) { throw GoogleException.Cancelled(); }
            catch (ObjectDisposedException) { throw GoogleException.Cancelled(); }
            using (c)
            {
                Dictionary<string, string>? q = null;
                try
                {
                    var stream = c.GetStream();
                    var target = await ReadRequestTargetAsync(stream, deadline.Token).ConfigureAwait(false);
                    if (target is null) continue;
                    var parsed = ParseQuery(target);
                    if (!parsed.ContainsKey("code") && !parsed.ContainsKey("error"))
                    {
                        await RespondAsync(stream, "404 Not Found", "Not found").ConfigureAwait(false);
                        continue;
                    }
                    await RespondAsync(stream, "200 OK", Page(parsed.ContainsKey("code"))).ConfigureAwait(false);
                    q = parsed;
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested && deadline.IsCancellationRequested) { throw GoogleException.TimedOut(); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw GoogleException.Cancelled(); }
                catch (IOException) { continue; }
                if (q is not null) return q;
            }
        }
    }

    /// <summary>Reads the whole header block (so closing doesn't reset the connection) and returns the request target.</summary>
    static async Task<string?> ReadRequestTargetAsync(NetworkStream s, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(5));
        var buf = new List<byte>();
        var tmp = new byte[4096];
        try
        {
            while (buf.Count < 32_768)
            {
                var n = await s.ReadAsync(tmp, cts.Token).ConfigureAwait(false);
                if (n <= 0) break;
                buf.AddRange(tmp.AsSpan(0, n).ToArray());
                if (buf.Count >= 4 && buf[^4] == 13 && buf[^3] == 10 && buf[^2] == 13 && buf[^1] == 10) break;
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
        var text = Encoding.UTF8.GetString(buf.ToArray());
        var line = text.Split("\r\n")[0];
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts[0] != "GET" || !parts[1].StartsWith('/')) return null;
        return parts[1];
    }

    internal static Dictionary<string, string> ParseQuery(string target)
    {
        var q = new Dictionary<string, string>(StringComparer.Ordinal);
        var i = target.IndexOf('?');
        if (i < 0) return q;
        foreach (var pair in target[(i + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            static string D(string s) { try { return Uri.UnescapeDataString(s.Replace('+', ' ')); } catch { return s; } }
            q[D(kv[0])] = kv.Length > 1 ? D(kv[1]) : "";
        }
        return q;
    }

    static async Task RespondAsync(NetworkStream s, string status, string body)
    {
        var b = Encoding.UTF8.GetBytes(body);
        var head = $"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {b.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(head)).ConfigureAwait(false);
        await s.WriteAsync(b).ConfigureAwait(false);
        await s.FlushAsync().ConfigureAwait(false);
    }

    static string Page(bool ok)
    {
        var title = ok ? "Cirrus is connected to Google" : "Cirrus wasn’t connected";
        var text = ok ? "You can close this tab and go back to Cirrus." : "Google access wasn’t allowed. Go back to Cirrus to try again.";
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>" + title + "</title>"
            + "<style>body{font:16px 'Segoe UI',system-ui,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#222}"
            + "@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}h1{font-size:1.4em}</style></head>"
            + "<body><h1>" + title + "</h1><p>" + text + "</p></body></html>";
    }
}

/// <summary>Authorization-code + PKCE flow, token refresh and revocation.</summary>
public sealed class GoogleOAuth
{
    public const string AuthorizeURL = "https://accounts.google.com/o/oauth2/v2/auth";
    public const string TokenURL = "https://oauth2.googleapis.com/token";
    public const string RevokeURL = "https://oauth2.googleapis.com/revoke";

    public GoogleOAuthClient Client { get; }
    internal HttpClient Http { get; }
    /// <summary>Test hook: replaces Task.Delay for back-off.</summary>
    internal Func<TimeSpan, CancellationToken, Task> Delay { get; set; } = Task.Delay;

    /// <summary><paramref name="handler"/> swaps in a fake Google (tests and Debug demo builds).</summary>
    public GoogleOAuth(GoogleOAuthClient client, HttpMessageHandler? handler = null)
    {
        Client = client;
        Http = GoogleHttp.Create(handler);
    }

    static string Enc(string s) => Uri.EscapeDataString(s);

    public Uri AuthorizationURL(string redirectURI, Pkce pkce, string state, IEnumerable<string>? scopes = null, string? loginHint = null)
    {
        var q = new List<(string, string)>
        {
            ("client_id", Client.ClientID), ("redirect_uri", redirectURI), ("response_type", "code"),
            ("scope", string.Join(' ', scopes ?? GoogleScopes.All)), ("code_challenge", pkce.Challenge), ("code_challenge_method", "S256"),
            ("state", state), ("access_type", "offline"), ("prompt", "consent"),
        };
        if (!string.IsNullOrEmpty(loginHint)) q.Add(("login_hint", loginHint));
        return new Uri(AuthorizeURL + "?" + string.Join('&', q.Select(p => Enc(p.Item1) + "=" + Enc(p.Item2))));
    }

    /// <summary>Opens Google's consent page (through <paramref name="open"/>) and waits for the redirect, then exchanges the code.</summary>
    public async Task<GoogleTokens> AuthorizeAsync(Func<Uri, Task> open, IEnumerable<string>? scopes = null, string? loginHint = null, TimeSpan? timeout = null,
        CancellationToken ct = default)
    {
        if (!Client.LooksValid) throw GoogleException.NotConfigured();
        var wanted = (scopes ?? GoogleScopes.All).ToList();
        using var rx = new LoopbackReceiver();
        var pkce = new Pkce();
        var state = Pkce.Random(24);
        var url = AuthorizationURL(rx.RedirectURI, pkce, state, wanted, loginHint);
        // The listener is already accepting connections, so opening the page can't race it.
        var wait = rx.WaitForRedirectAsync(timeout ?? TimeSpan.FromSeconds(600), ct);
        _ = Task.Run(async () =>
        {
            try { await open(url).ConfigureAwait(false); }
            catch (Exception e) { Log.Status("couldn’t open the Google sign-in page: " + e.GetType().Name); }
        }, CancellationToken.None);
        var query = await wait.ConfigureAwait(false);
        if (query.TryGetValue("error", out var err))
            throw err == "access_denied" ? GoogleException.AccessDenied() : GoogleException.BadResponse($"Google sign-in failed ({err}).");
        if (!query.TryGetValue("state", out var st) || st != state) throw GoogleException.StateMismatch();
        if (!query.TryGetValue("code", out var code) || code.Length == 0) throw GoogleException.BadResponse("Google didn’t send a sign-in code.");
        return await ExchangeAsync(code, pkce.Verifier, rx.RedirectURI, wanted, ct).ConfigureAwait(false);
    }

    internal async Task<GoogleTokens> ExchangeAsync(string code, string verifier, string redirectURI, List<string> requested, CancellationToken ct)
    {
        var form = new Dictionary<string, string>
        {
            ["code"] = code, ["client_id"] = Client.ClientID, ["code_verifier"] = verifier, ["grant_type"] = "authorization_code", ["redirect_uri"] = redirectURI,
        };
        if (Client.ClientSecret is { } s) form["client_secret"] = s;
        // A code works once, so only retry when the request never reached Google.
        return Tokens(await PostAsync(form, retryAmbiguous: false, ct).ConfigureAwait(false), requested);
    }

    /// <summary>New access token from a refresh token. The refresh token itself usually stays the same.</summary>
    public async Task<GoogleTokens> RefreshAsync(string refreshToken, CancellationToken ct = default)
    {
        var form = new Dictionary<string, string> { ["client_id"] = Client.ClientID, ["refresh_token"] = refreshToken, ["grant_type"] = "refresh_token" };
        if (Client.ClientSecret is { } s) form["client_secret"] = s;
        return Tokens(await PostAsync(form, retryAmbiguous: true, ct).ConfigureAwait(false), null);
    }

    /// <summary>
    /// Revoking a refresh token ends Cirrus's whole grant (best effort). Used only for Disconnect, never on reconnect:
    /// it would cut off the new token too.
    /// </summary>
    public async Task RevokeAsync(string token, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, RevokeURL) { Content = FormContent(new() { ["token"] = token }) };
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(30));
            using var r = await Http.SendAsync(req, cts.Token).ConfigureAwait(false);
            Log.Status($"google revoke → {(int)r.StatusCode}");
        }
        catch (Exception e) { Log.Status("google revoke failed: " + e.GetType().Name); }
    }

    static GoogleTokens Tokens(J j, List<string>? requested)
    {
        if (j["access_token"].Str is not { Length: > 0 } access) throw GoogleException.BadResponse("Google’s answer had no access token.");
        var scopes = j["scope"].Str is { } s ? s.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList() : requested ?? [];
        return new GoogleTokens
        {
            AccessToken = access, ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(j["expires_in"].Double ?? 3600), RefreshToken = j["refresh_token"].Str, Scopes = scopes,
        };
    }

    internal static string FormEncode(Dictionary<string, string> form) =>
        string.Join('&', form.OrderBy(k => k.Key, StringComparer.Ordinal).Select(kv => Enc(kv.Key) + "=" + Enc(kv.Value)));

    static ByteArrayContent FormContent(Dictionary<string, string> form)
    {
        var c = new ByteArrayContent(Encoding.UTF8.GetBytes(FormEncode(form)));
        c.Headers.TryAddWithoutValidation("Content-Type", "application/x-www-form-urlencoded");
        return c;
    }

    async Task<J> PostAsync(Dictionary<string, string> form, bool retryAmbiguous, CancellationToken ct)
    {
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int status;
            byte[] data;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, TokenURL) { Content = FormContent(form) };
                req.Headers.TryAddWithoutValidation("Accept", "application/json");
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(GoogleHttp.RequestTimeout);
                try
                {
                    using var r = await Http.SendAsync(req, cts.Token).ConfigureAwait(false);
                    status = (int)r.StatusCode;
                    data = await r.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("Google didn’t answer in time."); }
            }
            catch (Exception e) when (!ct.IsCancellationRequested && attempt < 3 && GoogleHttp.IsTransient(e, retryAmbiguous))
            {
                attempt++;
                await Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt) * 0.25), ct).ConfigureAwait(false);
                continue;
            }
            Log.Status($"google token → {status}");   // never the body: it holds tokens
            var j = J.Parse(data);
            if (status == 200) return j;
            if ((status >= 500 || status == 429) && attempt < 3)
            {
                attempt++;
                await Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt) * 0.5), ct).ConfigureAwait(false);
                continue;
            }
            switch (j["error"].Str ?? "")
            {
                case "invalid_grant":
                    throw GoogleException.Reconnect("Google ended Cirrus’s access (it was revoked, the password changed, or — while your Google Cloud project is in Testing — 7 days passed). Select Connect Google to continue; the move picks up where it stopped.");
                case "invalid_client":
                case "unauthorized_client":
                    throw GoogleException.BadResponse("Google didn’t accept the client ID or secret. Check them in Set Up Google Access…");
                case "invalid_request" when (j["error_description"].Str ?? "").Contains("client_secret", StringComparison.Ordinal):
                    throw GoogleException.BadResponse("Google needs the client secret too. Paste it in Set Up Google Access…");
                default:
                    throw GoogleException.Http(status, j["error_description"].Str ?? j["error"].Str ?? "Google didn’t accept the sign-in.");
            }
        }
    }
}
