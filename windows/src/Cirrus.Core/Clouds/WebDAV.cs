namespace Cirrus.Core;

// STUB (contract): replaced by the WebDAV / Nextcloud port of WebDAV.swift, WebDAVClient.swift, WebDAVDrive.swift and
// NextcloudLoginFlow.swift.

public static class WebDAVCloud
{
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>
    /// Checks a WebDAV folder address, user name and password and returns the account to save. A Nextcloud server is set up
    /// as Nextcloud instead (trash, thumbnails, chunked uploads); an ownCloud base address becomes its WebDAV folder.
    /// </summary>
    public static Task<CloudConnection> ConnectAsync(string folderURL, string username, string password,
        HttpMessageHandler? transport = null, CancellationToken ct = default) => throw new NotImplementedException();
}

public static class NextcloudLoginFlow
{
    /// <summary>A started browser sign-in (Login Flow v2): open <see cref="LoginURL"/>, then poll.</summary>
    public sealed record Pending(Uri Server, Uri LoginURL, Uri PollEndpoint, string Token);

    /// <summary>Starts a sign-in: POST &lt;server&gt;/index.php/login/v2.</summary>
    public static Task<Pending> BeginAsync(string server, HttpMessageHandler? transport = null, CancellationToken ct = default) =>
        throw new NotImplementedException();

    /// <summary>Waits until the user approves Cirrus in the browser; returns the account (with its new app password).</summary>
    public static Task<CloudConnection> PollAsync(Pending pending, TimeSpan? timeout = null, HttpMessageHandler? transport = null,
        CancellationToken ct = default) => throw new NotImplementedException();
}
