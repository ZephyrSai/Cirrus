using System.Text;

namespace Cirrus.Core;

// Dropbox through API v2 (port of Dropbox.swift): the signed-in user's whole Dropbox (team accounts: the team space, as
// the Dropbox app shows it).
//
// Sign-in is the OAuth 2 authorization code flow with PKCE (S256) for a public client: no app secret, and
// token_access_type=offline for a long-lived refresh token (access tokens last about four hours). Dropbox matches
// redirect URIs exactly, port included, so Cirrus listens on one of three fixed loopback ports and sends the matching
// http://localhost:<port>. Where a loopback redirect can't work (a port held by another app, a locked-down browser),
// BeginCodeSignIn runs the same flow without a redirect: Dropbox shows a code and the user pastes it into Cirrus.
//
// App Console setup (dropbox.com/developers/apps › Create app):
//   • Choose an API: “Scoped access”. Type of access: “Full Dropbox”.
//   • Settings › OAuth 2 › “Allow public clients (Implicit Grant & PKCE)”: Allow.
//   • Settings › OAuth 2 › Redirect URIs: add each of these exactly (no trailing slash):
//       http://localhost:47823   http://localhost:47824   http://localhost:47825
//     (The paste-a-code sign-in needs no redirect URI.)
//   • Permissions: account_info.read, files.metadata.read, files.metadata.write, files.content.read,
//     files.content.write — then Submit. Nothing else (no sharing, no team scopes).
//   • Never use the App secret: Cirrus is a public client.
//   • A new app is in Development status: up to 500 Dropbox users can link to it before Dropbox's production review
//     (Settings › “Apply for production”).
// Put the app's App key into DropboxCloud.DefaultAppKey.

public static class DropboxCloud
{
    /// <summary>
    /// Cirrus's own Dropbox app (App key). Empty until the project registers one: the user pastes their own App key, which
    /// the account keeps in <see cref="CloudSecret.ClientID"/>.
    /// </summary>
    public static string DefaultAppKey { get; set; } = "";

    /// <summary>What Cirrus asks for: the account's email (for the account title), and reading and changing files.</summary>
    public static readonly IReadOnlyList<string> Scopes =
        ["account_info.read", "files.metadata.read", "files.metadata.write", "files.content.read", "files.content.write"];

    /// <summary>Dropbox needs exact redirect URIs: http://localhost:47823 … 47825 are registered in the app.</summary>
    public static readonly IReadOnlyList<int> RedirectPorts = [47823, 47824, 47825];
    /// <summary>The redirect URIs to register in the App Console, exactly as Cirrus sends them.</summary>
    public static IReadOnlyList<string> RedirectURIs => RedirectPorts.Select(RedirectURI).ToList();

    internal static string RedirectURI(int port) => $"http://localhost:{port}";

    /// <summary>No App key given and none built in: what to set up (shown when signing in, and as the setup help).</summary>
    public const string NotConfiguredMessage = "Dropbox isn’t set up in this copy of Cirrus yet: it needs a Dropbox app key. "
        + "Create a free app at dropbox.com/developers/apps (Scoped access, Full Dropbox), allow public clients, add the redirect URIs "
        + "http://localhost:47823, http://localhost:47824 and http://localhost:47825, turn on the account_info.read, files.metadata and files.content permissions, "
        + "then enter its App key.";

    /// <summary>Every sign-in port is taken (thrown as NotConfigured): the paste-a-code sign-in still works.</summary>
    public const string PortsBusyMessage = "Cirrus couldn’t open its Dropbox sign-in port: another app is using ports 47823–47825. Quit that app and try again, or sign in with a code instead.";

    /// <summary>The App key to use: the given one, or <see cref="DefaultAppKey"/>; NotConfigured when both are empty.</summary>
    internal static string AppKey(string? given)
    {
        var s = (given ?? "").Trim();
        var key = s.Length == 0 ? (DefaultAppKey ?? "").Trim() : s;
        if (key.Length == 0) throw CloudException.NotConfigured(NotConfiguredMessage);
        return key;
    }

    /// <summary>
    /// The backend for a saved account. Dropbox keeps refresh tokens stable, but the backend still reports a new one through
    /// <see cref="ICloudTokenRotating.OnNewRefreshToken"/> should Dropbox ever hand one out.
    /// </summary>
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        Backend(record, secret, transport);

    /// <summary>Same as <see cref="Make"/>, typed (for <see cref="DropboxBackend.Secret"/> and the tuning knobs).</summary>
    public static DropboxBackend Backend(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        var key = AppKey(secret.ClientID);
        if (secret.RefreshToken is not { Length: > 0 } rt) throw CloudException.SignInNeeded("Dropbox");
        return new DropboxBackend(record.Id, key, rt, record.Option("pathRoot"), transport);
    }

    // MARK: Browser sign-in (loopback redirect)

    /// <summary>
    /// Browser sign-in (PKCE) on the first free redirect port: <paramref name="open"/> shows the URL in the default browser,
    /// then the account's email becomes the account title. Throws NotConfigured when no App key is set, or when none of the
    /// ports is free (<see cref="PortsBusyMessage"/>: use the code sign-in). Errors are CloudException (or
    /// OperationCanceledException).
    /// </summary>
    public static Task<CloudConnection> SignInAsync(string? appKey, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        CancellationToken ct = default) =>
        SignInOnPortsAsync(appKey, open, transport, RedirectPorts, TimeSpan.FromSeconds(600), ct);

    internal static async Task<CloudConnection> SignInOnPortsAsync(string? given, Func<Uri, Task> open, HttpMessageHandler? transport,
        IReadOnlyList<int> ports, TimeSpan timeout, CancellationToken ct)
    {
        var appKey = AppKey(given);
        using var rx = OpenLoopback(ports) ?? throw CloudException.NotConfigured(PortsBusyMessage);
        using var http = CloudBackends.Http(transport);
        var redirect = RedirectURI(rx.Port);
        var pkce = new Pkce();
        var state = Pkce.Random(24);
        var url = DropboxAuth.AuthorizationURL(appKey, redirect, pkce, state);
        // The listener is already accepting connections, so opening the page can't race it.
        var wait = rx.WaitForRedirectAsync(timeout, ct);
        _ = Task.Run(async () =>
        {
            try { await open(url).ConfigureAwait(false); }
            catch (Exception e) { Log.Status("couldn’t open the Dropbox sign-in page: " + e.GetType().Name); }
        }, CancellationToken.None);
        Dictionary<string, string> query;
        try { query = await wait.ConfigureAwait(false); }
        catch (GoogleException e) when (e.Kind == GoogleErrorKind.TimedOut)
        {
            throw CloudException.Server("Timed out waiting for you to finish signing in to Dropbox in your browser.");
        }
        catch (GoogleException)
        {
            ct.ThrowIfCancellationRequested();
            throw CloudException.Cancelled();
        }
        ct.ThrowIfCancellationRequested();
        if (query.TryGetValue("error", out var error))
        {
            if (error == "access_denied")
                throw CloudException.Denied("Dropbox access wasn’t allowed. Select Add Account again and choose Allow on Dropbox’s page.");
            var why = (query.GetValueOrDefault("error_description") ?? "").Trim();
            throw CloudException.Denied($"Dropbox didn’t connect ({(why.Length == 0 ? error : why)}).");
        }
        if (query.GetValueOrDefault("state") != state)
            throw CloudException.Denied("The answer from Dropbox didn’t match this sign-in, so Cirrus ignored it. Try adding the account again.");
        if (query.GetValueOrDefault("code") is not { Length: > 0 } code) throw CloudException.Server("Dropbox didn’t send a sign-in code. Try again.");
        var t = await DropboxAuth.RedeemAsync(new()
        {
            ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = redirect, ["code_verifier"] = pkce.Verifier,
        }, appKey, http, signingIn: true, ct: ct).ConfigureAwait(false);
        return await FinishSignInAsync(t, appKey, http, ct).ConfigureAwait(false);
    }

    /// <summary>The first of <paramref name="ports"/> that is free (127.0.0.1 and ::1 both held), or null.</summary>
    internal static LoopbackReceiver? OpenLoopback(IReadOnlyList<int> ports)
    {
        foreach (var p in ports)
            if (LoopbackReceiver.TryOpen("Dropbox", p, localhostName: true) is { } rx) return rx;
        return null;
    }

    // MARK: Paste-a-code sign-in (no redirect)

    /// <summary>
    /// The fallback: starts the sign-in without a redirect. Open <see cref="DropboxCodeSignIn.AuthorizationURL"/> in a browser;
    /// once the user allows access, Dropbox shows a code, which goes to <see cref="DropboxCodeSignIn.FinishAsync"/>.
    /// </summary>
    public static DropboxCodeSignIn BeginCodeSignIn(string? appKey)
    {
        var key = AppKey(appKey);
        var pkce = new Pkce();
        return new DropboxCodeSignIn
        {
            AuthorizationURL = DropboxAuth.AuthorizationURL(key, null, pkce, null), AppKey = key, Verifier = pkce.Verifier,
        };
    }

    /// <summary>
    /// The paste-a-code sign-in in one call: <paramref name="open"/> shows Dropbox's page, <paramref name="code"/> asks the
    /// user for the code Dropbox showed (throw OperationCanceledException from it to stop).
    /// </summary>
    public static async Task<CloudConnection> SignInWithCodeAsync(string? appKey, Func<Uri, Task> open, Func<CancellationToken, Task<string>> code,
        HttpMessageHandler? transport = null, CancellationToken ct = default)
    {
        var pending = BeginCodeSignIn(appKey);
        await open(pending.AuthorizationURL).ConfigureAwait(false);
        var typed = await code(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return await pending.FinishAsync(typed, transport, ct).ConfigureAwait(false);
    }

    // MARK: After the code

    /// <summary>Checks what Dropbox granted, reads the account, and builds the record and secret.</summary>
    internal static async Task<CloudConnection> FinishSignInAsync(DropboxTokenSet t, string appKey, HttpClient http, CancellationToken ct)
    {
        if (t.Refresh is not { Length: > 0 } rt) throw CloudException.Server("Dropbox didn’t let Cirrus stay signed in (no refresh token). Try again.");
        if (t.Scopes is { } granted)
        {
            var missing = Scopes.Where(s => !granted.Contains(s)).ToList();
            if (missing.Count > 0)
                throw CloudException.NotConfigured($"The Dropbox app this copy of Cirrus uses doesn’t have these permissions: {string.Join(", ", missing)}. "
                    + "Turn them on in the App Console’s Permissions tab, choose Submit, then add the account again.");
        }
        var tokens = new DropboxTokens(appKey, rt, http, t);
        var api = new DropboxHttp(http, tokens, null);
        var me = await DropboxHttp.Guarded(() => api.RpcAsync("users/get_current_account", null, DropboxRetry.Safe, ct: ct)).ConfigureAwait(false);
        var title = new[] { me["email"].Str, me["name"]["display_name"].Str }.Select(s => s?.Trim()).FirstOrDefault(s => !string.IsNullOrEmpty(s)) ?? "Dropbox";
        // A team with a team space: paths start at the team's root namespace (team folders plus the member's own folder),
        // as the Dropbox app shows them; otherwise they would start in the member folder only.
        Dictionary<string, string>? options = null;
        var root = me["root_info"];
        if (root[".tag"].Str == "team" && root["root_namespace_id"].Str is { Length: > 0 } ns && ns != root["home_namespace_id"].Str)
            options = new() { ["pathRoot"] = ns };
        var record = new CloudAccountRecord(CloudProvider.Dropbox, title, options: options);
        return new CloudConnection(record, new CloudSecret { RefreshToken = tokens.CurrentRefreshToken, ClientID = appKey });
    }
}

/// <summary>A paste-a-code sign-in in progress (see <see cref="DropboxCloud.BeginCodeSignIn"/>).</summary>
public sealed class DropboxCodeSignIn
{
    /// <summary>Dropbox's page; after the user allows access it shows the code to paste.</summary>
    public Uri AuthorizationURL { get; init; } = new("https://www.dropbox.com/oauth2/authorize");
    public string AppKey { get; init; } = "";
    internal string Verifier { get; init; } = "";

    /// <summary>Exchanges the code the user pasted (spaces and line breaks around it are ignored). A code works once and for a few minutes.</summary>
    public async Task<CloudConnection> FinishAsync(string code, HttpMessageHandler? transport = null, CancellationToken ct = default)
    {
        code = (code ?? "").Trim();
        if (code.Length == 0) throw CloudException.Denied("Paste the code Dropbox showed after you chose Allow.");
        using var http = CloudBackends.Http(transport);
        var t = await DropboxAuth.RedeemAsync(new() { ["grant_type"] = "authorization_code", ["code"] = code, ["code_verifier"] = Verifier },
            AppKey, http, signingIn: true, pastedCode: true, ct: ct).ConfigureAwait(false);
        return await DropboxCloud.FinishSignInAsync(t, AppKey, http, ct).ConfigureAwait(false);
    }
}

/// <summary>Dropbox's OAuth 2 endpoints.</summary>
static class DropboxAuth
{
    public const string AuthorizeURL = "https://www.dropbox.com/oauth2/authorize";
    public const string TokenURL = "https://api.dropboxapi.com/oauth2/token";

    /// <summary><paramref name="redirectURI"/> null: Dropbox shows the code instead of redirecting.</summary>
    public static Uri AuthorizationURL(string appKey, string? redirectURI, Pkce pkce, string? state)
    {
        var q = new List<(string, string)>
        {
            ("client_id", appKey), ("response_type", "code"), ("token_access_type", "offline"), ("scope", string.Join(' ', DropboxCloud.Scopes)),
            ("code_challenge", pkce.Challenge), ("code_challenge_method", "S256"),
        };
        if (redirectURI is not null) q.Add(("redirect_uri", redirectURI));
        if (state is not null) q.Add(("state", state));
        return new Uri(AuthorizeURL + "?" + string.Join('&', q.Select(p => Uri.EscapeDataString(p.Item1) + "=" + Uri.EscapeDataString(p.Item2))));
    }

    /// <summary>
    /// POSTs to the token endpoint (public client: the App key, never a secret). A sign-in code works once, so it's retried
    /// only when it never left; a refresh is retried after dropped connections too.
    /// </summary>
    public static async Task<DropboxTokenSet> RedeemAsync(Dictionary<string, string> form, string appKey, HttpClient http, bool signingIn,
        bool pastedCode = false, CancellationToken ct = default)
    {
        form["client_id"] = appKey;
        var body = Encoding.UTF8.GetBytes(GoogleOAuth.FormEncode(form));
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int status;
            byte[] data;
            string? retryAfter = null;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, TokenURL) { Content = new ByteArrayContent(body) };
                req.Content.Headers.TryAddWithoutValidation("Content-Type", "application/x-www-form-urlencoded");
                req.Headers.TryAddWithoutValidation("Accept", "application/json");
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(DropboxHttp.RequestTimeout);
                try
                {
                    using var r = await http.SendAsync(req, cts.Token).ConfigureAwait(false);
                    status = (int)r.StatusCode;
                    if (r.Headers.TryGetValues("Retry-After", out var ra)) retryAfter = string.Join(",", ra);
                    data = await r.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("Dropbox didn’t answer in time."); }
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is not CloudException && DropboxHttp.IsNetwork(e))
            {
                if (attempt < 3 && GoogleHttp.IsTransient(e, ambiguousOK: !signingIn))
                {
                    attempt++;
                    await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt) * 0.25), ct).ConfigureAwait(false);
                    continue;
                }
                throw DropboxHttp.NetworkError(e);
            }
            Log.Status($"dropbox token → {status}");   // never the body: it holds tokens
            var j = J.Parse(data);
            if (status == 200)
            {
                if (j["access_token"].Str is not { Length: > 0 } access) throw CloudException.Server("Dropbox’s answer had no access token. Try again.");
                IReadOnlySet<string>? scopes = j["scope"].Str is { } s ? s.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal) : null;
                return new DropboxTokenSet(access, j["refresh_token"].Str, DateTimeOffset.UtcNow.AddSeconds(j["expires_in"].Double ?? 14_400), scopes);
            }
            if ((status >= 500 || status == 429) && attempt < 3)
            {
                attempt++;
                double? after = double.TryParse(retryAfter, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var a) ? a : null;
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(after ?? Math.Pow(2, attempt) * 0.5, 30)), ct).ConfigureAwait(false);
                continue;
            }
            throw TokenError(j, status, signingIn, pastedCode);
        }
    }

    public static CloudException TokenError(J j, int status, bool signingIn, bool pastedCode = false)
    {
        var error = j["error"].Str ?? "";
        var why = (j["error_description"].Str ?? "").Trim();
        switch (error)
        {
            case "invalid_grant" when pastedCode:
                return CloudException.Denied("Dropbox didn’t accept that code. A code works once and only for a few minutes: start the sign-in again for a new one.");
            case "invalid_grant" when signingIn:
                return CloudException.Server($"Dropbox didn’t accept the sign-in ({(why.Length == 0 ? error : why)}). Try again.");
            case "invalid_grant":
                // Revoked from dropbox.com › Settings › Connected apps, or the app was unlinked.
                return CloudException.SignInNeeded("Dropbox");
            case "invalid_client" or "unauthorized_client":
                return CloudException.NotConfigured($"Dropbox doesn’t accept Cirrus’s app key ({(why.Length == 0 ? error : why)}). Check the App key and that the app allows public clients (PKCE).");
            default:
                return CloudException.Server($"Dropbox sign-in failed ({(why.Length > 0 ? why : error.Length > 0 ? error : $"HTTP {status}")}).");
        }
    }
}
