namespace Cirrus.Core;

// STUB (contract): replaced by the Dropbox port of Dropbox.swift, DropboxHTTP.swift, DropboxBackend.swift and
// DropboxUpload.swift.

public static class DropboxCloud
{
    /// <summary>Cirrus's own Dropbox app (empty until registered: the user pastes their own app key).</summary>
    public static string DefaultAppKey { get; set; } = "";
    /// <summary>Dropbox needs exact redirect URIs: http://localhost:47823 … 47825 are registered in the app.</summary>
    public static readonly IReadOnlyList<int> RedirectPorts = [47823, 47824, 47825];
    public static IReadOnlyList<string> RedirectURIs => RedirectPorts.Select(p => $"http://localhost:{p}").ToList();

    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>Browser sign-in (PKCE) on the first free redirect port. Throws NotConfigured when none is free (use the code sign-in).</summary>
    public static Task<CloudConnection> SignInAsync(string? appKey, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        CancellationToken ct = default) => throw new NotImplementedException();

    /// <summary>The fallback: Dropbox shows a code the user pastes into Cirrus.</summary>
    public static DropboxCodeSignIn BeginCodeSignIn(string? appKey) => throw new NotImplementedException();
}

public sealed class DropboxCodeSignIn
{
    public Uri AuthorizationURL { get; init; } = new("https://www.dropbox.com/oauth2/authorize");
    public Task<CloudConnection> FinishAsync(string code, HttpMessageHandler? transport = null, CancellationToken ct = default) =>
        throw new NotImplementedException();
}
