import Foundation

/// STUB: replaced by the Immich connector.
public enum Immich {
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> PhotosBackend {
        throw CloudError.unsupported("Immich isn’t available yet.")
    }
    #if DEBUG
    public static func demo() -> (record: CloudAccountRecord, photos: PhotosBackend)? { nil }
    #endif
}
