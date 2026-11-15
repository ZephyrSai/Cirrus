import CoreGraphics
import Foundation
import ImageIO
import CryptoKit

enum SHA256Hex {
    static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct PhotoLibraryRef: Hashable, Codable, Sendable {
    public var id: String           // CloudKit zone (PrimarySync, SharedSync-…) or "local"
    public var name: String
    public var isShared: Bool
    public var area: String = "private"
    public var ownerRecordName: String?
    public var zoneType: String?
    public init(id: String, name: String, isShared: Bool) { self.id = id; self.name = name; self.isShared = isShared }
}

public struct PhotoAlbum: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case smart, album, folder, shared }
    public var id: String            // stable within a library: "smart:All Photos", "album:<record>", "folder:<record>"
    public var name: String
    public var kind: Kind
    public var parentID: String?
    public var count: Int?
    public var symbol: String
    public var isDeletedBin: Bool { id == "smart:Recently Deleted" }
    public var isAllPhotos: Bool { id == "smart:All Photos" }
    public init(id: String, name: String, kind: Kind, parentID: String? = nil, count: Int? = nil, symbol: String = "rectangle.stack") {
        self.id = id; self.name = name; self.kind = kind; self.parentID = parentID; self.count = count; self.symbol = symbol
    }
}

public struct PhotoResource: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case original, liveVideo, edited, alternate, thumbnail, medium }
    public var kind: Kind
    public var filename: String
    public var size: Int64
    public var key: String           // CloudKit field name (web) or PHAssetResourceType raw value (native)
    public var recordName: String    // record that owns the field (web)
    public var url: String?          // signed download URL (web, expires)
    public var uti: String?
}

public struct PhotoAsset: Hashable, Codable, Sendable {
    public var id: String            // CPLAsset record name (web) / PHAsset localIdentifier (native)
    public var masterID: String?
    public var changeTag: String?
    public var library: String
    public var filename: String
    public var size: Int64
    public var created: Date?
    public var added: Date?
    public var width: Int
    public var height: Int
    public var duration: Double?
    public var isVideo: Bool
    public var isLive: Bool
    public var isFavorite: Bool
    public var isHidden: Bool
    public var isDeleted: Bool = false
    public var isEdited: Bool = false
    public var uti: String?
    public var resources: [PhotoResource]

    public static func == (a: PhotoAsset, b: PhotoAsset) -> Bool {
        a.id == b.id && a.isFavorite == b.isFavorite && a.isHidden == b.isHidden && a.changeTag == b.changeTag
    }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public func resource(_ kind: PhotoResource.Kind) -> PhotoResource? { resources.first { $0.kind == kind } }

    /// Bytes for a full-fidelity export (original + live video + alternate RAW + edited if requested).
    public func exportSize(includeLive: Bool, includeEdited: Bool, includeRAW: Bool) -> Int64 {
        var s = resource(.original)?.size ?? size
        if includeLive { s += resource(.liveVideo)?.size ?? 0 }
        if includeEdited { s += resource(.edited)?.size ?? 0 }
        if includeRAW { s += resource(.alternate)?.size ?? 0 }
        return s
    }
}

public struct PhotoCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let favorite = PhotoCapabilities(rawValue: 1)
    public static let hide = PhotoCapabilities(rawValue: 2)
    public static let delete = PhotoCapabilities(rawValue: 4)
    public static let restore = PhotoCapabilities(rawValue: 8)
    public static let importFiles = PhotoCapabilities(rawValue: 16)
    public static let albums = PhotoCapabilities(rawValue: 32)
    public static let createAlbum = PhotoCapabilities(rawValue: 64)
}

public protocol PhotosBackend: AnyObject, Sendable {
    var capabilities: PhotoCapabilities { get }
    /// Stable key used for caches and sync state (e.g. "web:appleid" / "native").
    var cacheKey: String { get }
    func libraries() async throws -> [PhotoLibraryRef]
    func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum]
    /// Streams pages (newest pages first where possible) and returns the complete list.
    func assets(in album: PhotoAlbum, library: PhotoLibraryRef,
                page: @escaping @Sendable (_ batch: [PhotoAsset], _ expectedTotal: Int?) -> Void) async throws -> [PhotoAsset]
    func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage?
    func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset]
    func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset]
    func delete(_ assets: [PhotoAsset]) async throws
    func restore(_ assets: [PhotoAsset]) async throws
    func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws
    func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum
    /// Requirements (not just extension methods) so calls through `any PhotosBackend` reach the real implementation.
    func syncToken(library: PhotoLibraryRef) -> String?
    func hasChanges(since token: String, library: PhotoLibraryRef) async throws -> (changed: Bool, token: String?)
    /// Libraries served from a disk cache, so later calls address the right database and zone.
    func remember(_ libraries: [PhotoLibraryRef])
    /// False when the last `libraries()` couldn't reach every database (e.g. the Shared Library timed out).
    func librariesComplete() -> Bool
}

public extension PhotosBackend {
    /// Opaque “as of” marker for a library after the last listing (nil = backend can't tell).
    func syncToken(library: PhotoLibraryRef) -> String? { nil }
    /// Whether anything changed since `token`; returns the newer token. Default: assume it did.
    func hasChanges(since token: String, library: PhotoLibraryRef) async throws -> (changed: Bool, token: String?) { (true, nil) }
    func remember(_ libraries: [PhotoLibraryRef]) {}
    func librariesComplete() -> Bool { true }
}

public enum PhotoFormats {
    public static let utiExtensions: [String: String] = [
        "public.jpeg": "jpg", "public.png": "png", "public.heic": "heic", "public.heif": "heif", "public.tiff": "tiff",
        "public.mpeg-4": "mp4", "com.apple.quicktime-movie": "mov", "com.compuserve.gif": "gif", "com.adobe.raw-image": "dng",
        "com.canon.cr2-raw-image": "cr2", "com.canon.cr3-raw-image": "cr3", "com.nikon.raw-image": "nef", "com.sony.arw-raw-image": "arw",
        "public.avif": "avif", "org.webmproject.webp": "webp", "com.apple.m4v-video": "m4v", "public.avi": "avi",
        "com.fuji.raw-image": "raf", "com.panasonic.rw2-raw-image": "rw2", "com.olympus.raw-image": "orf", "com.pentax.raw-image": "pef",
        "com.nikon.nrw-raw-image": "nrw", "com.canon.crw-raw-image": "crw", "public.image": "heic",
    ]
    public static let videoUTIs: Set<String> = ["public.mpeg-4", "com.apple.quicktime-movie", "com.apple.m4v-video", "public.avi", "public.mpeg-2-video"]

    public static func importable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf",
                "webp", "avif", "mov", "mp4", "m4v"].contains(ext)
    }

    public static func jpeg(_ cg: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    public static func cgImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Small on-disk cache for remote thumbnails.
public enum ThumbnailDiskCache {
    static let queue = DispatchQueue(label: "cirrus.thumbcache", attributes: .concurrent)
    /// Hashed names (no Apple IDs or photo IDs on disk), one folder per account.
    /// Bump to invalidate every cached thumbnail (v2: drop entries written by the downloader race).
    static let version = "v2"
    public static func accountDir(_ backend: String) -> URL {
        Paths.cacheDir("thumbs").appendingPathComponent(hash(version + backend), isDirectory: true)
    }
    /// Removes thumbnail folders from older cache versions.
    public static func pruneOldVersions(keeping backends: [String]) {
        let keep = Set(backends.map { hash(version + $0) })
        let root = Paths.cacheDir("thumbs")
        for u in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(u.lastPathComponent) {
            try? FileManager.default.removeItem(at: u)
        }
    }
    public static func url(_ backend: String, _ id: String, _ px: Int) -> URL {
        let dir = accountDir(backend).appendingPathComponent(String(hash(id).prefix(2)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash(id))-\(px).jpg")
    }
    static func hash(_ s: String) -> String {
        let d = SHA256Hex.digest(s)
        return String(d.prefix(24))
    }
    public static func read(_ backend: String, _ id: String, _ px: Int) -> Data? { try? Data(contentsOf: url(backend, id, px)) }
    public static func write(_ data: Data, _ backend: String, _ id: String, _ px: Int) { try? data.write(to: url(backend, id, px), options: .atomic) }
}
