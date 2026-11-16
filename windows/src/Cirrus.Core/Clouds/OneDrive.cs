namespace Cirrus.Core;

// STUB (contract): replaced by the OneDrive port of OneDrive.swift, OneDriveHTTP.swift, OneDriveBackend.swift and
// OneDriveUpload.swift.

public static class OneDriveCloud
{
    /// <summary>Cirrus's own Microsoft app registration (empty until registered: the user pastes their own client ID).</summary>
    public static string DefaultClientID { get; set; } = "";

    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>Browser sign-in (PKCE, loopback redirect on http://localhost:&lt;port&gt;). <paramref name="clientID"/> null or empty: DefaultClientID.</summary>
    public static Task<CloudConnection> SignInAsync(string? clientID, Func<Uri, Task> open, HttpMessageHandler? transport = null,
        CancellationToken ct = default) => throw new NotImplementedException();
}
