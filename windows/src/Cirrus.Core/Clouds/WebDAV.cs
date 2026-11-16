namespace Cirrus.Core;

// Nextcloud and plain WebDAV accounts (ownCloud, OpenCloud, Synology, QNAP, Apache…): port of WebDAV.swift. The backend
// is WebDAVDrive (WebDAVDrive.cs), the wire layer DAVClient (WebDAVClient.cs) and the browser sign-in
// NextcloudLoginFlow (NextcloudLoginFlow.cs).

public static class WebDAVCloud
{
    /// <summary>
    /// The backend for a saved account. Nextcloud records hold the server's base URL and the login name; WebDAV records
    /// hold the folder URL. The secret's password is the (app) password.
    /// </summary>
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        if (record.Provider is not (CloudProvider.Nextcloud or CloudProvider.WebDAV))
            throw CloudException.Unsupported($"{record.Provider.DisplayName()} isn’t a WebDAV service.");
        if (record.Provider == CloudProvider.Nextcloud && string.IsNullOrEmpty(secret.Password))
            throw CloudException.SignInNeeded(record.Title.Length == 0 ? "Nextcloud" : $"Nextcloud ({record.Title})");
        return new WebDAVDrive(record, secret.Password, transport);
    }

    /// <summary>
    /// Checks a WebDAV folder address, user name and password and returns the account to save. A Nextcloud server is set up
    /// as Nextcloud instead (trash, thumbnails, chunked uploads); an ownCloud base address becomes its WebDAV folder.
    /// </summary>
    /// <remarks>
    /// Nextcloud is recognised by its status.php (asked without credentials), or, when that page is hidden, by a folder under
    /// remote.php that answers Nextcloud's own properties. A folder that moved on the same server (often just a missing
    /// trailing slash) is followed.
    /// </remarks>
    public static async Task<CloudConnection> ConnectAsync(string folderURL, string username, string password,
        HttpMessageHandler? transport = null, CancellationToken ct = default)
    {
        var folder = FolderURL(folderURL);
        var user = (username ?? "").Trim();
        var secret = new CloudSecret { Password = password };
        var @base = NextcloudBase(folder);
        switch (await ServerProductAsync(@base, transport, ct).ConfigureAwait(false))
        {
            case Product.Nextcloud:
                return new CloudConnection(await ConnectNextcloudAsync(@base, user, password, transport, ct).ConfigureAwait(false), secret);
            case Product.OwnCloud when !folder.Contains("/remote.php/", StringComparison.Ordinal):
                folder = @base + "/remote.php/webdav/";
                break;
        }
        var client = new DAVClient(user, password, "WebDAV", transport);
        var body = WebDAVDrive.PropfindBody(["resourcetype"], nc: ["has-preview"]);
        var hops = 0;
        while (true)
        {
            DAVResponse r;
            try
            {
                r = await client.SendAsync("PROPFIND", folder, WebDAVDrive.PropfindHeaders("0"), new DAVBody.Bytes(body), DAVRetry.Safe, ct: ct).ConfigureAwait(false);
            }
            catch (CloudException e) when (e.Kind == CloudErrorKind.SignInNeeded) { throw BadPassword(); }
            // A folder moved on the same server (often just a missing trailing slash): follow it.
            if (r.Status is 301 or 302 or 303 or 307 or 308 && hops < 3 && r.Header("Location") is { } loc && FollowedRedirect(folder, loc) is { } next)
            {
                folder = FolderURL(next);
                hops++;
                continue;
            }
            if (r.Status != 207)
            {
                throw r.Status switch
                {
                    404 or 409 => CloudException.NotConfigured("There’s no WebDAV folder at that address. Check the path (it often ends in /webdav, /dav or /remote.php/webdav)."),
                    403 => CloudException.Denied("The server didn’t allow access to that folder."),
                    200 or 405 or 501 => CloudException.NotConfigured("That address is a web page, not a WebDAV folder. Check the path (it often ends in /webdav, /dav or /remote.php/webdav)."),
                    _ => CloudException.Server($"The server couldn’t open that folder ({r.Status}{DAVErrorBody.Suffix(r.Data)})."),
                };
            }
            var first = DAVMultistatus.Parse(r.Data, folder).FirstOrDefault(x => (x.Status ?? 200) == 200)
                ?? throw CloudException.Server("The server answered, but not with a folder Cirrus can open.");
            if (!first.IsCollection) throw CloudException.NotConfigured("That address is a file, not a folder.");
            // Only Nextcloud answers its own properties: a Nextcloud whose status page is hidden.
            if (first.HasPreview is not null && folder.Contains("/remote.php/", StringComparison.Ordinal))
                return new CloudConnection(await ConnectNextcloudAsync(@base, user, password, transport, ct).ConfigureAwait(false), secret);
            break;
        }
        var record = new CloudAccountRecord(CloudProvider.WebDAV, Title(user, folder), folder, user.Length == 0 ? null : user);
        return new CloudConnection(record, secret);
    }

    /// <summary>A redirect to the same host (and an address Cirrus may use), or null.</summary>
    static string? FollowedRedirect(string from, string location)
    {
        if (!Uri.TryCreate(new Uri(from), location, out var next) || !next.IsAbsoluteUri) return null;
        if (!string.Equals(next.Host, DAVURL.Host(from), StringComparison.OrdinalIgnoreCase)) return null;
        try { DAVURL.Check(next); } catch (CloudException) { return null; }
        return next.AbsoluteUri;
    }

    internal static CloudException BadPassword() => CloudException.Denied("The server didn’t accept that user name and password. If the account uses two-step sign-in, "
        + "create an app password in the server’s security settings and use that.");

    static async Task<CloudAccountRecord> ConnectNextcloudAsync(string @base, string user, string password, HttpMessageHandler? transport, CancellationToken ct)
    {
        if (user.Length == 0) throw CloudException.NotConfigured("Enter your Nextcloud user name.");
        var record = new CloudAccountRecord(CloudProvider.Nextcloud, Title(user, @base), @base, user);
        var drive = new WebDAVDrive(record, password, transport);
        try { await drive.ValidateAsync(ct).ConfigureAwait(false); }
        catch (CloudException e) when (e.Kind == CloudErrorKind.SignInNeeded) { throw BadPassword(); }
        return record;
    }

    enum Product { Nextcloud, OwnCloud, Unknown }

    /// <summary>The part before /remote.php/ (or the folder itself): where a Nextcloud or ownCloud keeps status.php.</summary>
    internal static string NextcloudBase(string folder)
    {
        var i = folder.IndexOf("/remote.php/", StringComparison.Ordinal);
        return i >= 0 ? folder[..i] : folder.TrimEnd('/');
    }

    /// <summary>Asks status.php (no credentials sent) which server this is.</summary>
    static async Task<Product> ServerProductAsync(string @base, HttpMessageHandler? transport, CancellationToken ct)
    {
        var anon = new DAVClient(null, null, "WebDAV", transport) { MaxRetries = 1 };
        try
        {
            var r = await anon.SendAsync("GET", @base + "/status.php", new Dictionary<string, string> { ["Accept"] = "application/json" }, retry: DAVRetry.Safe, ct: ct)
                .ConfigureAwait(false);
            if (r.Status != 200) return Product.Unknown;
            var j = J.Parse(r.Data);
            if (j["installed"].IsNull) return Product.Unknown;
            var name = (j["productname"].Str ?? "").ToLowerInvariant();
            if (name.Contains("nextcloud", StringComparison.Ordinal) || !j["extendedSupport"].IsNull) return Product.Nextcloud;
            if (name.Contains("owncloud", StringComparison.Ordinal) || !j["product"].IsNull) return Product.OwnCloud;
            return Product.Unknown;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { return Product.Unknown; }
    }

    /// <summary>
    /// A WebDAV folder address as typed (scheme optional) → https URL ending in "/", without credentials, query or
    /// fragment. Plain http:// is refused except for this device (localhost).
    /// </summary>
    public static string FolderURL(string input)
    {
        var s = (input ?? "").Trim();
        if (s.Length == 0) throw CloudException.NotConfigured("Enter the WebDAV folder’s address, like https://nas.example.com/webdav.");
        if (!s.Contains("://", StringComparison.Ordinal)) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host))
            throw CloudException.NotConfigured($"“{input}” isn’t a server address. Enter an address like https://nas.example.com/webdav.");
        var path = u.AbsolutePath;
        if (!path.EndsWith('/')) path += "/";
        var url = DAVURL.Origin(u) + path;
        DAVURL.Check(u, url);
        return url;
    }

    /// <summary>"alex@cloud.example.com"; an email-style login keeps the server apart: "alex@example.com (cloud.example.com)".</summary>
    internal static string Title(string user, string server)
    {
        var host = server;
        if (Uri.TryCreate(server, UriKind.Absolute, out var u))
            host = u.Host + (u.IsDefaultPort ? "" : ":" + u.Port.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (user.Length == 0) return host;
        return user.Contains('@') ? $"{user} ({host})" : $"{user}@{host}";
    }
}
