import Foundation

/// S3-compatible storage: AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO and others. See `S3Backend`.
///
/// A record holds the endpoint (`server`, https://…), the access key ID (`username`) and, in `options`,
/// "region" (us-east-1, us-west-004, "auto" for R2…), "bucket" (optional: without one the top level lists the
/// buckets) and "pathStyle" ("1" path-style, "0" virtual-hosted; default virtual-hosted on AWS, path-style elsewhere).
/// The secret access key is the secret's `password`.
public enum S3Storage {
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        guard record.provider == .s3 else { throw CloudError.unsupported("\(record.provider.displayName) isn’t S3 storage.") }
        guard let key = secret.password, !key.isEmpty else {
            throw CloudError.signInNeeded(record.title.isEmpty ? CloudProvider.s3.displayName : "\(CloudProvider.s3.displayName) (\(record.title))")
        }
        return try S3Backend(record: record, secretKey: key, transport: transport)
    }

    /// Checks an endpoint, region, bucket and key pair and returns the account to save.
    ///
    /// The endpoint may come without a scheme ("s3.us-west-004.backblazeb2.com"); https is assumed, and plain http is
    /// accepted only for this device (a MinIO on localhost). A bucket written into the address of a well-known service
    /// ("photos.s3.us-west-2.amazonaws.com", "https://<account>.r2.cloudflarestorage.com/photos") is taken from there.
    /// An empty region (or "auto") is read from the host name where it's there, "auto" for R2, else us-east-1.
    /// Validates with ListObjectsV2 (one key) on the bucket, or ListBuckets without one; a bucket that turns out to be
    /// in another region is saved with that region.
    public static func connect(endpoint: String, region: String, bucket: String?, accessKey: String, secretKey: String,
                               transport: [AnyClass]?) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let access = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretValue = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var (ep, path) = try S3Endpoint.parse(endpoint)
        guard !access.isEmpty else { throw CloudError.notConfigured("Enter the access key ID (on B2 it’s the application key’s keyID).") }
        guard !secretValue.isEmpty else { throw CloudError.notConfigured("Enter the secret access key (on B2 it’s the application key).") }
        var bucketName = bucket?.trimmingCharacters(in: .whitespacesAndNewlines)
        if bucketName?.isEmpty == true { bucketName = nil }
        if let (b, h) = S3Endpoint.splitBucketHost(ep.host) {
            ep.host = h
            if bucketName == nil { bucketName = b }
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmed.isEmpty {
            if ep.knownService {
                guard !trimmed.contains("/") else {
                    throw CloudError.notConfigured("Enter only the endpoint (like https://\(ep.host)) and put the bucket’s name in the Bucket field.")
                }
                if bucketName == nil { bucketName = trimmed }
            } else {
                ep.basePath = S3Signer.encode("/" + trimmed, slash: false)   // an S3 service behind a proxy path
            }
        }
        if let b = bucketName {
            guard !b.contains("/"), !b.contains("\\") else { throw CloudError.notConfigured("Enter only the bucket’s name, without “/”.") }
            guard b.utf8.count <= 255 else { throw CloudError.notConfigured("That isn’t a bucket name.") }
        }
        let entered = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let storedRegion = entered.isEmpty ? (S3Endpoint.inferredRegion(host: ep.host) ?? "us-east-1") : entered
        var options = ["region": storedRegion]
        if let b = bucketName {
            options["bucket"] = b
            options["pathStyle"] = ep.isAWS && S3Endpoint.virtualHostable(b) ? "0" : "1"
        }
        let host = ep.host + (ep.port.map { ":\($0)" } ?? "")
        var record = CloudAccountRecord(provider: .s3, title: "\(bucketName ?? access) @ \(host)", server: ep.string, username: access, options: options)
        let backend = try S3Backend(record: record, secretKey: secretValue, transport: transport)
        backend.client.maxRetries = 1   // a mistyped address should say so quickly
        try await backend.validate()
        // The bucket answered from another region: remember that one.
        if let b = bucketName {
            let learned = backend.client.region(for: b)
            if learned != backend.client.defaultRegion { record.options?["region"] = learned }
        }
        return (record, CloudSecret(password: secretValue))
    }

    #if DEBUG
    /// The demo account (CIRRUS_DEMO=1), backed by FakeS3Server: a bucket with documents and photos.
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        FakeS3Server.startDemo(storage: Paths.cacheDir("demo").appendingPathComponent("s3", isDirectory: true))
        let (record, secret) = FakeS3Server.demoAccount()
        guard let b = try? S3Backend(record: record, secretKey: secret, transport: [FakeS3Server.self]) else { return nil }
        return (record, b)
    }
    #endif
}
