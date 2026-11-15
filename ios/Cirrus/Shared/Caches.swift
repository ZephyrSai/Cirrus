import CirrusCore
import Foundation

/// The same on-disk cache layout as the Mac app (Sources/Cirrus/Browser/Model.swift `Catalog`), so the
/// engine's sign-out wipe and cache cleanup find everything:
/// - listings: `Caches/Cirrus/listings/<account>/<library>-<album>.json` (web accounts only)
/// - opened/previewed copies: `Caches/Cirrus/{Open,Preview}/acct-<hash>/<stable key>/<name>`
/// - photo thumbnails: the engine's `ThumbnailDiskCache` (hashed names, one folder per account)
enum ListingCache {
    struct DriveCache: Codable { var nodes: [DriveNode]; var savedAt: Date }
    struct AlbumCache: Codable { var assets: [PhotoAsset]; var token: String?; var savedAt: Date }

    static func file(account: String, library: String, album: String) -> URL {
        let dir = Paths.cacheDir("listings").appendingPathComponent(account.replacingOccurrences(of: ":", with: "_"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent((library + "-" + album).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".json")
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func write<T: Encodable>(_ value: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    static func age(_ url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// Mac `Ops.stableKey`: FNV-1a, base 36.
    static func stableKey(_ s: String) -> String {
        String(s.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 36)
    }

    /// Bytes used by Cirrus's caches (thumbnails, listings, opened copies, partial downloads).
    static func size() -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: Paths.caches, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        while let u = e?.nextObject() as? URL {
            if u.pathComponents.contains("demo") { continue }
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Settings › Clear Caches. Keeps the demo account's sample data and anything a running transfer is using.
    @MainActor static func clearAll() {
        let fm = FileManager.default
        for name in ["thumbs", "listings", "Preview", "relay"] { try? fm.removeItem(at: Paths.caches.appendingPathComponent(name)) }
        // Opened copies: the engine's rule (edited copies are kept, the rest removed).
        for u in Paths.itemDirs(in: Paths.caches.appendingPathComponent("Open")) { Paths.retireOpenCopy(u) }
        if TransferManager.shared.active.isEmpty { try? fm.removeItem(at: Paths.caches.appendingPathComponent("tmp")) }
        DriveFolderModel.memory.removeAll()
        Thumbs.shared.purgeMemory()
    }
}
