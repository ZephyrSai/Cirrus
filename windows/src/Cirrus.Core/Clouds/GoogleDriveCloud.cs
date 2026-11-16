namespace Cirrus.Core;

// STUB (contract): replaced by the Google Drive port of GoogleDriveCloud.swift and GoogleDriveBackend.swift.

public static class GoogleDriveCloud
{
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>Browser sign-in with the user's own Google OAuth client and the full <see cref="GoogleScopes.Drive"/> scope.</summary>
    public static Task<CloudConnection> SignInAsync(GoogleOAuthClient client, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        string? loginHint = null, CancellationToken ct = default) => throw new NotImplementedException();
}
