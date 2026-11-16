using System.Text;

namespace Cirrus.Core;

/// <summary>
/// S3-compatible storage: AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO and others (port of S3Storage.swift). See
/// <see cref="S3Backend"/>.
///
/// A record holds the endpoint (<c>Server</c>, https://…), the access key ID (<c>Username</c>) and, in <c>Options</c>,
/// "region" (us-east-1, us-west-004, "auto" for R2…), "bucket" (optional: without one the top level lists the buckets)
/// and "pathStyle" ("1" path-style, "0" virtual-hosted; default virtual-hosted on AWS, path-style elsewhere). The secret
/// access key is the secret's <c>Password</c>.
/// </summary>
public static class S3Cloud
{
    /// <summary>What "Add Account…" shows above the S3 fields.</summary>
    public const string Info = "Backblaze B2, Cloudflare R2, Wasabi, MinIO, AWS and other S3-compatible storage. Use a key limited to the buckets Cirrus should see. "
        + "Leave the bucket empty to browse every bucket the key can list.";
    public const string EndpointPlaceholder = "https://s3.us-west-004.backblazeb2.com";
    public const string RegionPlaceholder = "us-east-1 (or auto)";
    public const string BucketPlaceholder = "Optional: one bucket";

    public static ICloudDriveBackend Make(CloudAccountRecord record, CloudSecret secret, HttpMessageHandler? transport)
    {
        if (record.Provider != CloudProvider.S3) throw CloudException.Unsupported($"{record.Provider.DisplayName()} isn’t S3 storage.");
        if (string.IsNullOrEmpty(secret.Password)) throw CloudException.SignInNeeded(S3Backend.ServiceName(record));
        return new S3Backend(record, secret.Password, transport);
    }

    /// <summary>
    /// Checks an endpoint, region, optional bucket and access key, and returns the account to save.
    ///
    /// The endpoint may come without a scheme ("s3.us-west-004.backblazeb2.com"); https is assumed, and plain http is
    /// accepted only for this device (a MinIO on localhost). A bucket written into the address of a well-known service
    /// ("photos.s3.us-west-2.amazonaws.com", "https://&lt;account&gt;.r2.cloudflarestorage.com/photos") is taken from there.
    /// An empty region (or "auto") is read from the host name where it's there, "auto" for R2, else us-east-1. Validates
    /// with ListObjectsV2 (one key) on the bucket, or ListBuckets without one; a bucket that turns out to be in another
    /// region is saved with that region.
    /// </summary>
    public static async Task<CloudConnection> ConnectAsync(string endpoint, string region, string? bucket, string accessKey, string secretKey,
        HttpMessageHandler? transport = null, CancellationToken ct = default)
    {
        var access = (accessKey ?? "").Trim();
        var secretValue = (secretKey ?? "").Trim();
        var (ep, path) = S3Endpoint.Parse(endpoint ?? "");
        if (access.Length == 0) throw CloudException.NotConfigured("Enter the access key ID (on B2 it’s the application key’s keyID).");
        if (secretValue.Length == 0) throw CloudException.NotConfigured("Enter the secret access key (on B2 it’s the application key).");
        var bucketName = bucket?.Trim();
        if (string.IsNullOrEmpty(bucketName)) bucketName = null;
        if (S3Endpoint.SplitBucketHost(ep.Host) is { } split)
        {
            ep = ep with { Host = split.Host };
            bucketName ??= split.Bucket;
        }
        var trimmed = path.Trim('/');
        if (trimmed.Length > 0)
        {
            if (ep.KnownService)
            {
                if (trimmed.Contains('/'))
                    throw CloudException.NotConfigured($"Enter only the endpoint (like https://{ep.Host}) and put the bucket’s name in the Bucket field.");
                bucketName ??= trimmed;
            }
            else ep = ep with { BasePath = S3Signer.Encode("/" + trimmed, slash: false) };   // an S3 service behind a proxy path
        }
        if (bucketName is not null)
        {
            if (bucketName.Contains('/') || bucketName.Contains('\\')) throw CloudException.NotConfigured("Enter only the bucket’s name, without “/”.");
            if (Encoding.UTF8.GetByteCount(bucketName) > 255) throw CloudException.NotConfigured("That isn’t a bucket name.");
        }
        var entered = (region ?? "").Trim().ToLowerInvariant();
        var storedRegion = entered.Length == 0 ? S3Endpoint.InferredRegion(ep.Host) ?? "us-east-1" : entered;
        var options = new Dictionary<string, string> { ["region"] = storedRegion };
        if (bucketName is not null)
        {
            options["bucket"] = bucketName;
            options["pathStyle"] = ep.IsAWS && S3Endpoint.VirtualHostable(bucketName) ? "0" : "1";
        }
        var record = new CloudAccountRecord(CloudProvider.S3, $"{bucketName ?? access} @ {ep.Authority}", ep.Address, access, options);
        var backend = new S3Backend(record, secretValue, transport);
        backend.Client.MaxRetries = 1;   // a mistyped address should say so quickly
        await backend.ValidateAsync(ct).ConfigureAwait(false);
        // The bucket answered from another region: remember that one.
        if (bucketName is not null)
        {
            var learned = backend.Client.Region(bucketName);
            if (learned != backend.Client.DefaultRegion) options["region"] = learned;
        }
        return new CloudConnection(record, new CloudSecret { Password = secretValue });
    }
}
