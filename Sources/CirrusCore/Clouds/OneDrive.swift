import Foundation

/// STUB: replaced by the OneDrive connector.
public enum OneDrive {
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        throw CloudError.unsupported("\(record.provider.displayName) isn’t available yet.")
    }
    #if DEBUG
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? { nil }
    #endif
}
