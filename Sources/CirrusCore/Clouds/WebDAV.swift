import Foundation

/// STUB: replaced by the WebDAV connector.
public enum WebDAV {
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        throw CloudError.unsupported("\(record.provider.displayName) isn’t available yet.")
    }
    #if DEBUG
    public static func demo(_ p: CloudProvider) -> (record: CloudAccountRecord, backend: CloudDriveBackend)? { nil }
    #endif
}
