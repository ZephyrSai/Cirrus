namespace Cirrus.Core;

// STUB (contract): replaced by the S3-compatible port of S3Storage.swift, S3Signer.swift, S3Client.swift and S3Backend.swift.

public static class S3Cloud
{
    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport) =>
        throw new NotImplementedException();

    /// <summary>Checks an endpoint, region, optional bucket and access key, and returns the account to save.</summary>
    public static Task<CloudConnection> ConnectAsync(string endpoint, string region, string? bucket, string accessKey, string secretKey,
        HttpMessageHandler? transport = null, CancellationToken ct = default) => throw new NotImplementedException();
}
