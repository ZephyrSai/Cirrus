using System.Globalization;

namespace Cirrus.Core;

/// <summary>
/// Immich (immich.app), a self-hosted photo library (port of Immich.swift). It plugs into Cirrus's Photos views
/// (timeline, albums, favorites, archive, trash) through <see cref="ImmichPhotos"/>, not the file browser.
/// <para>
/// Wire protocol: the Immich REST API under <c>&lt;server&gt;/api</c>, authenticated with a user-made API key in the
/// <c>x-api-key</c> header. Targets Immich v3 (July 2026): asset listing uses <c>POST /search/metadata</c> with the
/// structured <c>filter</c> / <c>orderBy</c> / <c>cursor</c> shape on 3.2 and later, and the older flat fields on 3.0–3.1.
/// Servers before 3.0 are refused (3.0 removed the upload device fields and moved album ownership).
/// </para>
/// </summary>
public static class ImmichCloud
{
    /// <summary>Oldest server Cirrus connects to.</summary>
    public static readonly ImmichVersion MinimumVersion = new(3, 0, 0);

    /// <summary>API key permissions Cirrus needs to browse and export. A key without them is refused when connecting.</summary>
    public static readonly IReadOnlyList<string> ReadPermissions = ["user.read", "asset.read", "asset.view", "asset.download", "asset.statistics", "album.read"];

    /// <summary>
    /// Permissions for changing the library. A key without some of them still connects; Cirrus then hides those commands
    /// (see <see cref="ImmichPhotos.Capabilities"/>).
    /// </summary>
    public static readonly IReadOnlyList<string> WritePermissions = ["asset.update", "asset.delete", "asset.upload", "asset.share", "album.create", "albumAsset.create"];

    /// <summary>The backend for a saved account: the record's server address and the API key from the secret store.</summary>
    public static IPhotosBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        if (record.Provider != CloudProvider.Immich) throw CloudException.Unsupported($"{record.Provider.DisplayName()} isn’t an Immich account.");
        var key = (secret.Password ?? "").Trim();
        if (key.Length == 0) throw CloudException.SignInNeeded(ServiceName(record.Title));
        if (record.Server is not { } server) throw CloudException.NotConfigured("This Immich account has no server address. Remove it and add it again.");
        return new ImmichPhotos(record, ServerURL(server), key, transport);
    }

    /// <summary>
    /// Checks a server address and API key (Immich 3.0 or later) and returns the account to save: finds the server
    /// (accepts "photos.example.com", with or without https:// and /api), checks it answers as Immich 3.0 or later, then
    /// asks who the key belongs to (the email becomes the account title) and which permissions it has.
    /// </summary>
    public static async Task<CloudConnection> ConnectAsync(string server, string apiKey, HttpMessageHandler? transport = null,
        CancellationToken ct = default)
    {
        var key = (apiKey ?? "").Trim();
        if (key.Length == 0)
            throw CloudException.NotConfigured("Paste an Immich API key. Create one in Immich under Account Settings › API Keys.");
        var baseURL = ServerURL(server);
        var host = DisplayHost(baseURL);
        using var anon = new ImmichClient(baseURL, null, "Immich", transport) { MaxRetries = 2 };

        // 1. Is this an Immich server? (No key sent yet.)
        var ping = await anon.SendAsync("GET", "/server/ping", retry: ImmichRetry.Safe, ct: ct).ConfigureAwait(false);
        if (ping.Status is >= 300 and < 400)
        {
            Uri? to = null;
            if (ping.Header("Location") is { } loc && Uri.TryCreate(new Uri(anon.Url("/server/ping")), loc, out var abs)) to = abs;
            throw CloudException.NotConfigured($"“{host}” sent Cirrus to another address" + (to is null ? "" : $" ({DisplayHost(to)})")
                + ". Enter the address Immich is served from" + (to is null ? "" : $", like {RedirectTarget(to)}") + ".");
        }
        if (ping.Status != 200 || ImmichClient.ParseJson(ping.Data) is not { } pong || pong["res"].Str != "pong")
            throw CloudException.NotConfigured($"There’s no Immich server at “{host}”. Check the address: it’s the one you open Immich at in a browser, like https://photos.example.com.");

        // 2. Version.
        J v;
        try { v = await anon.CallAsync("GET", "/server/version", retry: ImmichRetry.Safe, ct: ct).ConfigureAwait(false); }
        catch (CloudException e) when (e.Kind == CloudErrorKind.NotFound) { v = J.Null; }
        if (ImmichVersion.From(v) is not { } version) throw CloudException.Server($"“{host}” didn’t say which Immich version it runs.");
        if (version < MinimumVersion)
            throw CloudException.Unsupported($"“{host}” runs Immich {version}. Cirrus needs Immich {MinimumVersion.Short} or later: update the server, then try again.");

        // 3. Who the key belongs to.
        using var client = new ImmichClient(baseURL, key, "Immich", transport) { MaxRetries = 2 };
        J me;
        try { me = await client.CallAsync("GET", "/users/me", retry: ImmichRetry.Safe, ct: ct).ConfigureAwait(false); }
        catch (CloudException e) when (e.Kind == CloudErrorKind.SignInNeeded) { throw BadKey(); }
        var email = (me["email"].Str ?? "").Trim();
        var name = (me["name"].Str ?? "").Trim();

        // 4. What the key may do (an older key with no permission list, or a session token, can't be asked: assume all).
        var options = new Dictionary<string, string> { ["version"] = version.ToString() };
        J k = J.Null;
        try { k = await client.CallAsync("GET", "/api-keys/me", retry: ImmichRetry.Safe, ct: ct).ConfigureAwait(false); }
        catch (CloudException) { }
        if (k["permissions"].Node is System.Text.Json.Nodes.JsonArray)
        {
            var perms = k["permissions"].Array.Select(p => p.Str).OfType<string>().ToHashSet(StringComparer.Ordinal);
            if (!perms.Contains("all"))
            {
                var missing = ReadPermissions.Where(p => !perms.Contains(p)).ToList();
                if (missing.Count > 0)
                    throw CloudException.Denied("This API key can’t be used to browse your library: it’s missing the permission"
                        + (missing.Count == 1 ? " " : "s ") + string.Join(", ", missing)
                        + ". In Immich, edit the key under Account Settings › API Keys (or create one with “All” permissions).");
            }
            options["permissions"] = string.Join(",", perms.Order(StringComparer.Ordinal));
        }
        var user = email.Length == 0 ? name : email;
        var record = new CloudAccountRecord(CloudProvider.Immich, Title(user, baseURL), ServerString(baseURL),
            email.Length == 0 ? null : email, options);
        Log.Status($"immich: connected ({version})");
        return new CloudConnection(record, new CloudSecret { Password = key });
    }

    internal const string BadKeyMessage = "Immich didn’t accept that API key. Check that you copied all of it, "
        + "or create a new one in Immich under Account Settings › API Keys.";

    internal static CloudException BadKey() => CloudException.Denied(BadKeyMessage);

    /// <summary>For messages: "Immich (alex@example.com (photos.example.com))".</summary>
    public static string ServiceName(string title) => string.IsNullOrEmpty(title) ? "Immich" : $"Immich ({title})";

    /// <summary>The sidebar title: "alex@example.com (photos.example.com)", "alex@photos.example.com" or the host alone.</summary>
    internal static string Title(string user, Uri server)
    {
        var host = DisplayHost(server);
        if (user.Length == 0) return host;
        return user.Contains('@') ? $"{user} ({host})" : $"{user}@{host}";
    }

    // MARK: Server address

    /// <summary>Immich's own web routes: an address copied from the browser's address bar ends in one of these.</summary>
    static readonly HashSet<string> WebRoutes = new(StringComparer.OrdinalIgnoreCase)
    {
        "photos", "albums", "explore", "favorites", "archive", "trash", "people", "sharing", "search", "map", "places", "user-settings",
        "admin", "auth", "memory", "folders", "tags", "locked", "utilities", "buy", "shared-links", "partners", "duplicates",
    };

    /// <summary>
    /// A server address as typed → the server's base URL (scheme, host, port; no trailing slash, no /api). Without a scheme,
    /// https is assumed, except for a local-network address (Immich's own port 2283 serves http).
    /// </summary>
    public static Uri ServerURL(string input)
    {
        var s = (input ?? "").Trim();
        if (s.Length == 0) throw CloudException.NotConfigured("Enter your Immich server’s address, like https://photos.example.com.");
        var hadScheme = s.Contains("://", StringComparison.Ordinal);
        if (!hadScheme) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host) || u.HostNameType == UriHostNameType.Unknown)
            throw CloudException.NotConfigured($"“{input}” isn’t a server address. Enter an address like https://photos.example.com.");
        var scheme = u.Scheme.ToLowerInvariant();
        var host = u.Host.ToLowerInvariant();   // IPv6 keeps its brackets
        if (!hadScheme && IsLocalNetwork(host)) scheme = "http";
        // Drop an /api suffix (the API base is added later) or anything from an Immich web route onwards. User info,
        // query and fragment are dropped too.
        var segments = u.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        var route = segments.FindIndex(WebRoutes.Contains);
        if (route >= 0) segments = segments[..route];
        while (segments.Count > 0 && segments[^1].Equals("api", StringComparison.OrdinalIgnoreCase)) segments.RemoveAt(segments.Count - 1);
        var port = u.IsDefaultPort ? "" : ":" + u.Port.ToString(CultureInfo.InvariantCulture);
        var text = scheme + "://" + host + port + (segments.Count == 0 ? "" : "/" + string.Join('/', segments));
        if (!Uri.TryCreate(text, UriKind.Absolute, out var url)) throw CloudException.NotConfigured($"“{input}” isn’t a server address.");
        CheckScheme(url);
        return url;
    }

    /// <summary>https everywhere; plain http only to a server on the local network (or this device).</summary>
    internal static void CheckScheme(Uri url)
    {
        var scheme = url.Scheme.ToLowerInvariant();
        if (string.IsNullOrEmpty(url.Host))
            throw CloudException.NotConfigured($"“{url.OriginalString}” isn’t a server address Cirrus can use. Enter an address like https://photos.example.com.");
        switch (scheme)
        {
            case "https": return;
            case "http":
                if (IsLocalNetwork(url.Host)) return;
                throw CloudException.Unsupported("Cirrus connects to Immich over the internet only with https://, so your API key and photos are never sent unencrypted. "
                    + "Use the server’s https:// address. (Plain http:// works for a server on your local network, like 192.168.1.20:2283 or immich.local.)");
            default:
                throw CloudException.Unsupported($"Cirrus can’t connect to “{scheme}://” addresses. Use the server’s https:// address.");
        }
    }

    /// <summary>
    /// This device, a private (RFC 1918 / unique-local / link-local) address, a .local (Bonjour) name or a single-label name
    /// such as "nas": places plain http may go, since that traffic stays on the local network.
    /// </summary>
    public static bool IsLocalNetwork(string rawHost)
    {
        var host = (rawHost ?? "").ToLowerInvariant();
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        if (host.EndsWith('.')) host = host[..^1];
        if (host.Length == 0) return false;
        if (host == "localhost" || host.EndsWith(".localhost", StringComparison.Ordinal) || host.EndsWith(".local", StringComparison.Ordinal)) return true;
        var octets = host.Split('.');
        if (octets.Length == 4 && octets.All(o => o.Length is > 0 and <= 3 && o.All(char.IsAsciiDigit)))
        {
            var o = octets.Select(int.Parse).ToArray();
            if (o.Any(x => x > 255)) return false;
            return (o[0], o[1]) switch
            {
                (10, _) or (127, _) => true,
                (172, >= 16 and <= 31) => true,
                (192, 168) => true,
                (169, 254) => true,
                _ => false,
            };
        }
        if (host.Contains(':'))   // IPv6
        {
            if (host == "::1") return true;
            var first = host.Split(':', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (!ushort.TryParse(first, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var v)) return false;
            return (v & 0xfe00) == 0xfc00 || (v & 0xffc0) == 0xfe80;   // fc00::/7 unique local, fe80::/10 link local
        }
        // A single-label name ("nas", "immich") only resolves on the local network.
        return !host.Contains('.');
    }

    /// <summary>"https://photos.example.com" (no trailing slash): what the record stores.</summary>
    public static string ServerString(Uri url) => url.AbsoluteUri.TrimEnd('/');

    /// <summary>"photos.example.com", "192.168.1.20:2283", "[fd12::5]:2283".</summary>
    internal static string DisplayHost(Uri url) => url.IsDefaultPort ? url.Host : url.Host + ":" + url.Port.ToString(CultureInfo.InvariantCulture);

    /// <summary>The server a redirect points at (its API path dropped), for the message.</summary>
    static string RedirectTarget(Uri to)
    {
        var s = ServerString(to);
        var i = s.IndexOf("/api/", StringComparison.OrdinalIgnoreCase);
        return i > 0 && to.AbsolutePath.StartsWith("/api/", StringComparison.OrdinalIgnoreCase) ? s[..i] : s;
    }
}

/// <summary>An Immich server version ("3.4.1").</summary>
public readonly record struct ImmichVersion(int Major, int Minor, int Patch) : IComparable<ImmichVersion>
{
    /// <summary>From <c>GET /server/version</c>.</summary>
    public static ImmichVersion? From(J j) =>
        j["major"].Int is int ma && j["minor"].Int is int mi ? new ImmichVersion(ma, mi, j["patch"].Int ?? 0) : null;

    /// <summary>"3.4.1" or "v3.4.1".</summary>
    public static ImmichVersion? Parse(string? s)
    {
        var parts = (s ?? "").Trim('v', ' ').Split('.').Select(p =>
        {
            var digits = new string(p.TakeWhile(char.IsAsciiDigit).ToArray());
            return int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : (int?)null;
        }).ToList();
        if (parts.Count < 2 || parts[0] is not int ma || parts[1] is not int mi) return null;
        return new ImmichVersion(ma, mi, parts.Count > 2 ? parts[2] ?? 0 : 0);
    }

    public int CompareTo(ImmichVersion o) => Major != o.Major ? Major.CompareTo(o.Major) : Minor != o.Minor ? Minor.CompareTo(o.Minor) : Patch.CompareTo(o.Patch);
    public static bool operator <(ImmichVersion a, ImmichVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(ImmichVersion a, ImmichVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(ImmichVersion a, ImmichVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(ImmichVersion a, ImmichVersion b) => a.CompareTo(b) >= 0;

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
    public string Short => $"{Major}.{Minor}";

    /// <summary><c>POST /search/metadata</c> takes <c>filter</c> / <c>orderBy</c> / <c>cursor</c> from 3.2 (the flat fields are deprecated there).</summary>
    public bool HasStructuredSearch => this >= new ImmichVersion(3, 2, 0);
}
