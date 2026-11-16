namespace Cirrus.Core;

// STUB (contract): replaced by the Immich port of Immich.swift, ImmichClient.swift and ImmichPhotos.swift.

public static class ImmichCloud
{
    public static IPhotosBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>Checks a server address and API key (Immich 3.0 or later) and returns the account to save.</summary>
    public static Task<CloudConnection> ConnectAsync(string server, string apiKey, HttpMessageHandler? transport = null,
        CancellationToken ct = default) => throw new NotImplementedException();
}
