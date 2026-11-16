import Foundation

/// STUB: replaced by the S3Storage connector.
public enum S3Storage {
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        throw CloudError.unsupported("\(record.provider.displayName) isn’t available yet.")
    }
    #if DEBUG
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? { nil }
    #endif
}
