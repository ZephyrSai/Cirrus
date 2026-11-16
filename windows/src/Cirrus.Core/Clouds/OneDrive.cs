using System.Text;

namespace Cirrus.Core;

// OneDrive (personal, work and school) through Microsoft Graph v1.0: the signed-in user's own drive (port of OneDrive.swift).
//
// Sign-in is the OAuth 2.0 authorization code flow with PKCE (S256) for a public client: no client secret. The default
// browser shows Microsoft's sign-in page and Microsoft redirects to a one-shot listener on this PC. App registration
// (Microsoft Entra admin center › App registrations › New registration):
//   • Supported account types: "Accounts in any organizational directory and personal Microsoft accounts"
//     (the `common` authority below needs this).
//   • Platform: "Mobile and desktop applications", custom redirect URI `http://localhost` (no port, no path). Microsoft
//     ignores the port of loopback redirect URIs, so Cirrus's random port matches it.
//   • API permissions (Microsoft Graph, delegated): Files.ReadWrite.All, offline_access, User.Read. None of them needs
//     admin consent.
//   • No client secret or certificate. If Microsoft ever answers AADSTS7000218 ("client_secret required"), check that the
//     redirect URI is under "Mobile and desktop applications" (or turn on Authentication › "Allow public client flows").
// Put the registration's Application (client) ID into `OneDriveCloud.DefaultClientID`.

public static class OneDriveCloud
{
    /// <summary>Cirrus's own Microsoft app registration (empty until registered: the user pastes their own client ID).</summary>
    public static string DefaultClientID { get; set; } = "";

    /// <summary>
    /// What Cirrus asks for: read and write the user's files (Files.ReadWrite.All also covers folders others shared with
    /// them), stay signed in (offline_access → refresh token), and the user's name.
    /// </summary>
    public static readonly IReadOnlyList<string> Scopes = ["Files.ReadWrite.All", "offline_access", "User.Read"];

    public const string NotConfiguredMessage = "OneDrive isn’t set up in this copy of Cirrus yet: it needs a Microsoft app (client) ID. "
        + "Register a free app in the Microsoft Entra admin center (Mobile and desktop, redirect URI http://localhost) and enter its client ID.";

    /// <summary>"Add Account…" text for OneDrive (the Mac app's, with the Windows secret store named).</summary>
    public const string SignInInfo = "Sign in with your Microsoft account in the browser (personal, work or school). Cirrus gets access to your OneDrive files, nothing else, and keeps the sign-in encrypted for your Windows account on this PC.";

    /// <summary>Added to <see cref="SignInInfo"/> when there is no client ID yet (the form then asks for one).</summary>
    public const string SetUpInfo = "This copy of Cirrus has no Microsoft app ID yet. Register a free one at entra.microsoft.com › App registrations › New registration: supported accounts “Accounts in any organizational directory and personal Microsoft accounts”, redirect URI platform “Public client/native (mobile & desktop)” with http://localhost. Then paste its Application (client) ID here. No client secret is needed.";

    /// <summary>An Application (client) ID is a GUID ("11111111-2222-…").</summary>
    public static bool LooksLikeClientID(string? s) => Guid.TryParse((s ?? "").Trim(), out _);

    internal static string ClientID(string? given)
    {
        var s = (given ?? "").Trim();
        var id = s.Length == 0 ? (DefaultClientID ?? "").Trim() : s;
        if (id.Length == 0) throw CloudException.NotConfigured(NotConfiguredMessage);
        return id;
    }

    /// <summary>The backend for a saved account. Set its <see cref="ICloudTokenRotating.OnNewRefreshToken"/> to keep the account signed in.</summary>
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        Backend(record, secret, transport);

    /// <summary>
    /// Same as <see cref="Make"/>, typed, so the app can save each rotated refresh token, e.g.
    /// <c>b.OnNewRefreshToken = rt => CloudStore.SetSecret(record.Id, secret with { RefreshToken = rt });</c>
    /// </summary>
    public static OneDriveBackend Backend(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        var id = ClientID(secret.ClientID);
        if (string.IsNullOrEmpty(secret.RefreshToken)) throw CloudException.SignInNeeded("OneDrive");
        return new OneDriveBackend(record.Id, id, secret.RefreshToken, transport);
    }

    /// <summary>Browser sign-in (PKCE, loopback redirect on http://localhost:&lt;port&gt;). <paramref name="clientID"/> null or empty: DefaultClientID.</summary>
    public static Task<CloudConnection> SignInAsync(string? clientID, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        CancellationToken ct = default) => SignInAsync(clientID, open, transport, TimeSpan.FromSeconds(600), ct);

    internal static async Task<CloudConnection> SignInAsync(string? given, Func<Uri, Task> open, HttpMessageHandler? transport, TimeSpan timeout,
        CancellationToken ct)
    {
        var clientID = ClientID(given);
        using var http = CloudBackends.Http(transport);
        LoopbackReceiver rx;
        try { rx = new LoopbackReceiver("OneDrive", 0, localhostName: true); }
        catch (GoogleException) { throw CloudException.Server("Cirrus couldn’t open a local port for the Microsoft sign-in."); }
        using (rx)
        {
            // Entra matches loopback redirect URIs without their port, so `http://localhost` registered once accepts any port.
            var redirect = rx.RedirectURI;
            var pkce = new Pkce();
            var state = Pkce.Random(24);
            var url = OneDriveAuth.AuthorizationURL(clientID, redirect, pkce, state);
            Dictionary<string, string> query;
            try
            {
                // The listener is already accepting connections, so opening the page can't race it.
                var wait = rx.WaitForRedirectAsync(timeout, ct);
                _ = Task.Run(async () =>
                {
                    try { await open(url).ConfigureAwait(false); }
                    catch (Exception e) { Log.Status("couldn’t open the Microsoft sign-in page: " + e.GetType().Name); }
                }, CancellationToken.None);
                query = await wait.ConfigureAwait(false);
            }
            catch (GoogleException e)   // LoopbackReceiver's own errors
            {
                if (ct.IsCancellationRequested) throw new OperationCanceledException(ct);
                throw e.Kind switch
                {
                    GoogleErrorKind.Cancelled => CloudException.Cancelled(),
                    GoogleErrorKind.TimedOut => CloudException.Server("Timed out waiting for you to finish signing in to Microsoft in your browser."),
                    GoogleErrorKind.AccessDenied => CloudException.Denied(AccessDeniedMessage),
                    _ => CloudException.Server(e.Message),
                };
            }
            ct.ThrowIfCancellationRequested();
            if (query.TryGetValue("error", out var err))
            {
                if (err == "access_denied") throw CloudException.Denied(AccessDeniedMessage);
                var why = OneDriveAuth.FirstLine(query.GetValueOrDefault("error_description") ?? "");
                throw CloudException.Denied($"Microsoft didn’t connect OneDrive ({(why.Length == 0 ? err : why)}).");
            }
            if (!query.TryGetValue("state", out var st) || st != state)
                throw CloudException.Denied("The answer from Microsoft didn’t match this sign-in, so Cirrus ignored it. Try adding the account again.");
            if (!query.TryGetValue("code", out var code) || code.Length == 0) throw CloudException.Server("Microsoft didn’t send a sign-in code. Try again.");
            var t = await OneDriveAuth.RedeemAsync(new Dictionary<string, string>
            {
                ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = redirect, ["code_verifier"] = pkce.Verifier,
                ["scope"] = string.Join(' ', Scopes),
            }, clientID, http, signingIn: true, ct).ConfigureAwait(false);
            if (string.IsNullOrEmpty(t.Refresh))
                throw CloudException.Server("Microsoft didn’t let Cirrus stay signed in to OneDrive. Try again and accept every permission Microsoft asks for.");
            var tokens = new OneDriveTokens(clientID, t.Refresh, http, t);
            var api = new OneDriveHttp(http, tokens);
            var me = await OneDriveHttp.Guarded(() => api.JsonAsync("GET", "/me", [("$select", "id,displayName,mail,userPrincipalName")], null,
                GraphRetry.Safe, ct: ct)).ConfigureAwait(false);
            // A work account without a OneDrive licence, or one never opened, has no drive yet.
            var drive = await OneDriveHttp.Guarded(() => api.SendAsync(GraphRequest.Make("GET", OneDriveHttp.Graph + "/me/drive", [("$select", "id,driveType")]),
                retry: GraphRetry.Safe, ct: ct)).ConfigureAwait(false);
            if (drive.Status is 404 or 403)
                throw CloudException.Denied("This Microsoft account doesn’t have a OneDrive yet. Open OneDrive on the web once (work and school accounts also need a OneDrive licence), then try again.");
            if (drive.Status is < 200 or >= 300) throw OneDriveHttp.Error(drive);
            var title = new[] { me["mail"].Str, me["userPrincipalName"].Str, me["displayName"].Str }
                .Select(s => s?.Trim()).FirstOrDefault(s => !string.IsNullOrEmpty(s)) ?? "OneDrive";
            var record = new CloudAccountRecord(CloudProvider.OneDrive, title);
            return new CloudConnection(record, new CloudSecret { RefreshToken = tokens.CurrentRefreshToken, ClientID = clientID });
        }
    }

    const string AccessDeniedMessage = "OneDrive access wasn’t allowed. Select Add Account again and choose Accept on Microsoft’s page.";
}

/// <summary>Microsoft identity platform endpoints (v2.0, <c>common</c> authority: personal and work/school accounts).</summary>
static class OneDriveAuth
{
    public const string AuthorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
    public const string TokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token";

    /// <summary>Test hook: replaces Task.Delay for back-off at the token endpoint.</summary>
    internal static Func<TimeSpan, CancellationToken, Task> Delay { get; set; } = Task.Delay;

    public static Uri AuthorizationURL(string clientID, string redirectURI, Pkce pkce, string state)
    {
        var q = new List<(string, string)>
        {
            ("client_id", clientID), ("response_type", "code"), ("redirect_uri", redirectURI), ("response_mode", "query"),
            ("scope", string.Join(' ', OneDriveCloud.Scopes)), ("state", state), ("code_challenge", pkce.Challenge), ("code_challenge_method", "S256"),
            // Lets someone with several Microsoft accounts pick which one to add.
            ("prompt", "select_account"),
        };
        return new Uri(AuthorizeURL + "?" + OneDriveHttp.QueryString(q));
    }

    /// <summary>Microsoft's error descriptions carry trace and correlation IDs on later lines.</summary>
    public static string FirstLine(string s) => s.Split(['\r', '\n'])[0].Trim();

    /// <summary>
    /// POSTs to the token endpoint. A sign-in code works once, so it's retried only when it never left; a refresh is
    /// retried after dropped connections too.
    /// </summary>
    public static async Task<OneDriveTokenSet> RedeemAsync(Dictionary<string, string> form, string clientID, HttpClient http, bool signingIn,
        CancellationToken ct)
    {
        form = new Dictionary<string, string>(form) { ["client_id"] = clientID };
        var body = Encoding.UTF8.GetBytes(GoogleOAuth.FormEncode(form));
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int status;
            byte[] data;
            string? retryAfter;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, TokenURL) { Content = new ByteArrayContent(body) };
                req.Content.Headers.TryAddWithoutValidation("Content-Type", "application/x-www-form-urlencoded");
                req.Headers.TryAddWithoutValidation("Accept", "application/json");
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(GoogleHttp.RequestTimeout);
                try
                {
                    using var r = await http.SendAsync(req, cts.Token).ConfigureAwait(false);
                    status = (int)r.StatusCode;
                    retryAfter = r.Headers.TryGetValues("Retry-After", out var ra) ? ra.FirstOrDefault() : null;
                    data = await r.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("The request timed out."); }
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not OperationCanceledException && OneDriveHttp.IsNetwork(e))
            {
                if (attempt >= 3 || !GoogleHttp.IsTransient(e, ambiguousOK: !signingIn)) throw OneDriveHttp.NetworkError(e);
                attempt++;
                await Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt) * 0.25), ct).ConfigureAwait(false);
                continue;
            }
            Log.Status($"onedrive token → {status}");   // never the body: it holds tokens
            var j = J.Parse(data);
            if (status == 200)
            {
                if (j["access_token"].Str is not { Length: > 0 } access) throw CloudException.Server("Microsoft’s answer had no access token. Try again.");
                return new OneDriveTokenSet(access, j["refresh_token"].Str, DateTimeOffset.UtcNow.AddSeconds(j["expires_in"].Double ?? 3600));
            }
            if ((status >= 500 || status == 429) && attempt < 3)
            {
                attempt++;
                var after = OneDriveHttp.ParseSeconds(retryAfter);
                await Delay(TimeSpan.FromSeconds(Math.Min(after ?? Math.Pow(2, attempt) * 0.5, 30)), ct).ConfigureAwait(false);
                continue;
            }
            throw TokenError(j, status, signingIn);
        }
    }

    public static CloudException TokenError(J j, int status, bool signingIn)
    {
        var error = j["error"].Str ?? "";
        var why = FirstLine(j["error_description"].Str ?? "");
        switch (error)
        {
            case "invalid_grant" when signingIn:
                return CloudException.Server($"Microsoft didn’t accept the sign-in ({(why.Length == 0 ? error : why)}). Try again.");
            case "invalid_grant" or "interaction_required" or "login_required" or "consent_required":
                // Revoked, expired after 90 days unused, password changed, or new consent needed.
                return CloudException.SignInNeeded("OneDrive");
            case "invalid_client" or "unauthorized_client":
                if (why.Contains("AADSTS7000218", StringComparison.Ordinal))
                    return CloudException.NotConfigured("Microsoft treats Cirrus’s app registration as a confidential client. In the Entra admin center, put the redirect URI http://localhost under “Mobile and desktop applications” (or turn on “Allow public client flows”).");
                return CloudException.NotConfigured($"Microsoft doesn’t accept Cirrus’s OneDrive app ID ({(why.Length == 0 ? error : why)}).");
            default:
                return CloudException.Server($"Microsoft sign-in failed ({(why.Length > 0 ? why : error.Length > 0 ? error : $"HTTP {status}")}).");
        }
    }
}
