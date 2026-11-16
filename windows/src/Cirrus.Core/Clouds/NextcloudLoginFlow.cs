using System.Text;

namespace Cirrus.Core;

/// <summary>
/// Nextcloud's browser sign-in (Login Flow v2; port of NextcloudLoginFlow.swift): Cirrus asks the server for a login
/// page, the user signs in there (two-factor and SSO included), and the server hands Cirrus an app password of its own.
/// The user's real password never passes through Cirrus. UI-agnostic: the app opens <see cref="Pending.LoginURL"/> and
/// awaits <see cref="PollAsync"/>.
/// </summary>
public static class NextcloudLoginFlow
{
    /// <summary>A started browser sign-in (Login Flow v2): open <see cref="LoginURL"/>, then poll.</summary>
    /// <param name="Server">The server's base URL (https://cloud.example.com or https://example.com/nextcloud).</param>
    /// <param name="LoginURL">Open this in the browser.</param>
    public sealed record Pending(Uri Server, Uri LoginURL, Uri PollEndpoint, string Token);

    /// <summary>Time between polls (tests set it near zero).</summary>
    internal static TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Accepts what people type: "cloud.example.com", "https://cloud.example.com/", a link to any Nextcloud page
    /// (…/index.php/apps/files, …/remote.php/dav/files/alex/) or a subfolder install (https://example.com/nextcloud).
    /// Returns the base address without a trailing slash; plain http:// is refused except for this device.
    /// </summary>
    public static string BaseURL(string input)
    {
        var s = (input ?? "").Trim();
        if (s.Length == 0) throw CloudException.NotConfigured("Enter your Nextcloud server’s address, like cloud.example.com.");
        if (!s.Contains("://", StringComparison.Ordinal)) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host))
            throw CloudException.NotConfigured($"“{input}” isn’t a server address. Enter an address like cloud.example.com.");
        var path = u.AbsolutePath;
        foreach (var marker in new[] { "/index.php", "/remote.php", "/status.php", "/ocs/", "/apps/", "/login/", "/s/" })
        {
            var i = path.IndexOf(marker, StringComparison.Ordinal);
            if (i >= 0) path = path[..i];
        }
        if (path.EndsWith("/login", StringComparison.Ordinal)) path = path[..^"/login".Length];
        path = path.TrimEnd('/');
        var url = DAVURL.Origin(u) + path;
        DAVURL.Check(u, url);
        return url;
    }

    /// <summary>Starts a sign-in: POST &lt;server&gt;/index.php/login/v2.</summary>
    public static async Task<Pending> BeginAsync(string server, HttpMessageHandler? transport = null, CancellationToken ct = default)
    {
        var @base = BaseURL(server);
        var host = DAVURL.Host(@base);
        var client = new DAVClient(null, null, "Nextcloud", transport);
        var r = await client.SendAsync("POST", @base + "/index.php/login/v2", new Dictionary<string, string> { ["Accept"] = "application/json" },
            retry: DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false);
        if (r.Status != 200)
        {
            if (r.Status is 404 or 405)
                throw CloudException.NotConfigured($"No Nextcloud server answered at {host}. Check the address (for a server in a subfolder, include it, like example.com/nextcloud).");
            if (r.Status is >= 300 and < 400)
                throw CloudException.NotConfigured($"{host} redirected to another address. Enter the address your browser shows when you open Nextcloud.");
            throw CloudException.Server($"{host} couldn’t start the sign-in ({r.Status}).");
        }
        var j = J.Parse(r.Data);
        if (j["poll"]["token"].Str is not { Length: > 0 } token
            || j["poll"]["endpoint"].Str is not { } ep || !Uri.TryCreate(ep, UriKind.Absolute, out var endpoint)
            || j["login"].Str is not { } lg || !Uri.TryCreate(lg, UriKind.Absolute, out var login))
            throw CloudException.Server($"{host} answered the sign-in in a way Cirrus doesn’t understand. Is it a Nextcloud server?");
        // The sign-in page and the token must stay on secure connections.
        DAVURL.Check(endpoint);
        DAVURL.Check(login);
        return new Pending(new Uri(@base), login, endpoint, token);
    }

    /// <summary>
    /// Waits until the user approves Cirrus in the browser (polling the server; 404 means not yet) and returns the
    /// account with its new app password. Throws when <paramref name="timeout"/> (20 minutes by default) passes, or
    /// <see cref="OperationCanceledException"/> when cancelled.
    /// </summary>
    public static async Task<CloudConnection> PollAsync(Pending pending, TimeSpan? timeout = null, HttpMessageHandler? transport = null,
        CancellationToken ct = default)
    {
        var client = new DAVClient(null, null, "Nextcloud", transport);
        var deadline = DateTimeOffset.UtcNow + (timeout ?? TimeSpan.FromMinutes(20));
        var body = Encoding.UTF8.GetBytes("token=" + Uri.EscapeDataString(pending.Token));
        var serverBase = BaseURL(pending.Server.AbsoluteUri);
        var headers = new Dictionary<string, string> { ["Content-Type"] = "application/x-www-form-urlencoded", ["Accept"] = "application/json" };
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            DAVResponse? answer = null;
            // Not retried inside: the first 200 uses up the token, so a lost answer can't be fetched twice.
            try { answer = await client.SendAsync("POST", pending.PollEndpoint.AbsoluteUri, headers, new DAVBody.Bytes(body), DAVRetry.RateLimitOnly, ct: ct).ConfigureAwait(false); }
            catch (CloudException) { }   // network trouble while the user is still in the browser: keep waiting
            if (answer is { Status: 200 } r)
            {
                var j = J.Parse(r.Data);
                if (j["loginName"].Str is not { Length: > 0 } login || j["appPassword"].Str is not { Length: > 0 } password)
                    throw CloudException.Server("Nextcloud finished the sign-in but didn’t send an app password. Try again.");
                var server = serverBase;
                if (j["server"].Str is { } said)
                {
                    try
                    {
                        var u = BaseURL(said);
                        if (string.Equals(DAVURL.Host(u), DAVURL.Host(serverBase), StringComparison.OrdinalIgnoreCase)) server = u;
                    }
                    catch (CloudException) { }
                }
                var record = new CloudAccountRecord(CloudProvider.Nextcloud, WebDAVCloud.Title(login, server), server, login);
                return new CloudConnection(record, new CloudSecret { Password = password });
            }
            // 404: the user hasn't finished yet. Anything else: keep trying until the deadline.
            if (answer is { Status: not 404 } other) Log.Status($"nextcloud login poll → {other.Status}");
            if (DateTimeOffset.UtcNow >= deadline)
                throw CloudException.Denied("The Nextcloud sign-in wasn’t finished in time. Start it again and approve Cirrus in the browser.");
            var wait = PollInterval < TimeSpan.FromMilliseconds(10) ? TimeSpan.FromMilliseconds(10) : PollInterval;
            await Task.Delay(wait, ct).ConfigureAwait(false);
        }
    }
}
