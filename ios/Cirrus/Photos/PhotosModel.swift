import CirrusCore
import Foundation
import Observation
import Photos

struct AlbumRef: Hashable {
    var accountID: String
    var library: PhotoLibraryRef
    var album: PhotoAlbum
}

enum PhotoTarget: Hashable {
    case allPhotos
    case album(PhotoAlbum, PhotoLibraryRef)
}

/// Photos listings with the Mac app's caching rules (web accounts only on disk):
/// libraries 1 day, album lists 10 minutes, album contents 5 minutes and then a CloudKit change-token check.
@MainActor
enum PhotoCatalog {
    static var libraries = [String: [PhotoLibraryRef]]()
    static var albums = [String: (at: Date, list: [PhotoAlbum])]()
    static let albumFreshFor: TimeInterval = 300

    static func libraries(_ account: Account) async throws -> [PhotoLibraryRef] {
        if let l = libraries[account.id] { return l }
        guard let photos = account.photos else { throw ICloudError.needsSignIn }
        let file = ListingCache.file(account: account.id, library: "_", album: "_libraries")
        if account.kind == .web, let cached = ListingCache.read([PhotoLibraryRef].self, file), !cached.isEmpty {
            libraries[account.id] = cached
            photos.remember(cached)
            if ListingCache.age(file) < 86_400 { return cached }
            Task { @MainActor in
                if let fresh = try? await photos.libraries(), photos.librariesComplete() {
                    libraries[account.id] = fresh
                    ListingCache.write(fresh, file)
                }
            }
            return cached
        }
        let libs = try await photos.libraries()
        // A list missing the Shared Library (it timed out) is used now but never cached.
        if photos.librariesComplete() {
            libraries[account.id] = libs
            if account.kind == .web { ListingCache.write(libs, file) }
        }
        return libs
    }

    static func albums(_ account: Account, _ library: PhotoLibraryRef, refresh: Bool = false) async throws -> [PhotoAlbum] {
        let key = account.id + "|" + library.id
        if !refresh, let m = albums[key], Date().timeIntervalSince(m.at) < 600 { return m.list }
        guard let photos = account.photos else { throw ICloudError.needsSignIn }
        let file = ListingCache.file(account: account.id, library: library.id, album: "_albums")
        if !refresh, account.kind == .web, let cached = ListingCache.read([PhotoAlbum].self, file), ListingCache.age(file) < 600 {
            albums[key] = (Date(), cached)
            return cached
        }
        let list = try await photos.albums(in: library)
        albums[key] = (Date(), list)
        if account.kind == .web { ListingCache.write(list, file) }
        return list
    }

    static func allPhotosAlbum(_ list: [PhotoAlbum]) -> PhotoAlbum? {
        list.first { $0.isAllPhotos || $0.id == "smart:all" }
    }

    /// After our own edits (favorite, delete, restore): patch every cached listing of that library in place,
    /// like the Mac app's `patchPhotos`. Favorites, Hidden and Recently Deleted change membership, so those
    /// are re-listed instead.
    static func patch(_ account: Account, library: String, updated: [PhotoAsset], removed: Set<String> = []) {
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let membership = ["smart:Recently Deleted", "smart:Favorites", "smart:Hidden"]
        let prefix = account.id + "|" + library + "|"
        for (k, v) in AlbumModel.memory where k.hasPrefix(prefix) {
            if membership.contains(where: { k.hasSuffix("|" + $0) }) { AlbumModel.memory[k] = nil; continue }
            AlbumModel.memory[k] = (v.at, v.assets.filter { !removed.contains($0.id) }.map { byID[$0.id] ?? $0 })
        }
        albums[account.id + "|" + library] = nil      // counts changed
        if account.kind == .web {
            let dir = ListingCache.file(account: account.id, library: "x", album: "x").deletingLastPathComponent()
            let filePrefix = (library + "-").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix(filePrefix) {
                guard var c = ListingCache.read(ListingCache.AlbumCache.self, f) else { continue }
                let name = f.lastPathComponent
                if name.contains("Recently Deleted") || name.contains("Favorites") || name.contains("Hidden") {
                    c.savedAt = .distantPast; c.token = nil
                } else {
                    c.assets = c.assets.filter { !removed.contains($0.id) }.map { byID[$0.id] ?? $0 }
                }
                ListingCache.write(c, f)
            }
            try? FileManager.default.removeItem(at: file(account.id, library, "_albums"))
        }
        NotificationCenter.default.post(name: .cirrusPhotosChanged, object: account.id)
    }

    private static func file(_ a: String, _ l: String, _ al: String) -> URL { ListingCache.file(account: a, library: l, album: al) }

    /// The device's own library: a friendly reason when Cirrus can't read it.
    static var deviceAccessProblem: String? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted: return "Cirrus doesn’t have access to your photos. Allow it in Settings › Privacy & Security › Photos › Cirrus."
        default: return nil
        }
    }
}

/// One album's photos, grouped by month (newest first).
@MainActor @Observable
final class AlbumModel {
    static var memory = [String: (at: Date, assets: [PhotoAsset])]()

    struct Month: Identifiable { let id: String; let title: String; let assets: [PhotoAsset] }

    let account: Account
    var library: PhotoLibraryRef?
    var album: PhotoAlbum?
    var assets: [PhotoAsset] = [] { didSet { regroup() } }
    var months: [Month] = []
    var loading = false
    var loaded = false
    var error: String?
    var expected: Int?

    init(account: Account) { self.account = account }

    var key: String { account.id + "|" + (library?.id ?? "") + "|" + (album?.id ?? "") }
    var isRecentlyDeleted: Bool { album?.isDeletedBin == true }

    func resolve(_ target: PhotoTarget, preferredLibrary: String?) async throws {
        switch target {
        case .album(let a, let lib):
            library = lib; album = a
        case .allPhotos:
            let libs = try await PhotoCatalog.libraries(account)
            let lib = libs.first { $0.id == preferredLibrary } ?? libs.first { !$0.isShared } ?? libs.first
            guard let lib else { throw ICloudError.serviceUnavailable("iCloud Photos") }
            library = lib
            album = PhotoCatalog.allPhotosAlbum(try await PhotoCatalog.albums(account, lib))
            if album == nil { throw ICloudError.serviceUnavailable("All Photos") }
        }
    }

    func load(force: Bool = false) async {
        guard let photos = account.photos, let lib = library, let album else { return }
        if !force, let m = Self.memory[key], Date().timeIntervalSince(m.at) < PhotoCatalog.albumFreshFor, !isRecentlyDeleted {
            assets = m.assets; loaded = true; return
        }
        loading = true
        defer { loading = false }
        let cacheURL = ListingCache.file(account: account.id, library: lib.id, album: album.id)
        let disk = account.kind == .web && !isRecentlyDeleted
        do {
            var cache: ListingCache.AlbumCache?
            if disk { cache = ListingCache.read(ListingCache.AlbumCache.self, cacheURL) }
            if let c = cache, !force {
                assets = c.assets; loaded = true
                if Date().timeIntervalSince(c.savedAt) < PhotoCatalog.albumFreshFor { Self.memory[key] = (Date(), c.assets); return }
                // Ask CloudKit whether anything changed since this listing; if not, keep it.
                if let token = c.token, let (changed, newToken) = try? await photos.hasChanges(since: token, library: lib), !changed {
                    ListingCache.write(ListingCache.AlbumCache(assets: c.assets, token: newToken ?? token, savedAt: Date()), cacheURL)
                    Self.memory[key] = (Date(), c.assets)
                    return
                }
            }
            let hadItems = !assets.isEmpty
            // The change token must date from before the listing (see the Mac app's Catalog.listAlbum).
            let tokenBefore = photos.syncToken(library: lib)
            let box = PageBox()
            let list = try await photos.assets(in: album, library: lib) { batch, total in
                let all = box.append(batch)
                Task { @MainActor [weak self] in
                    guard let self, !hadItems else { return }
                    self.expected = total
                    self.assets = all
                    self.loaded = true
                }
            }
            assets = list
            loaded = true
            error = nil
            Self.memory[key] = (Date(), list)
            if disk { ListingCache.write(ListingCache.AlbumCache(assets: list, token: tokenBefore, savedAt: Date()), cacheURL) }
        } catch {
            self.error = (account.isDevice ? PhotoCatalog.deviceAccessProblem : nil) ?? error.localizedDescription
            loaded = true
        }
    }

    private func regroup() {
        let cal = Calendar.current
        let sorted = assets.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        var out = [Month]()
        var current: (key: String, title: String, items: [PhotoAsset])?
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        for a in sorted {
            let key: String, title: String
            if let d = a.created {
                let c = cal.dateComponents([.year, .month], from: d)
                key = "\(c.year ?? 0)-\(c.month ?? 0)"
                title = f.string(from: d)
            } else { key = "unknown"; title = "Unknown Date" }
            if current?.key != key {
                if let c = current { out.append(Month(id: c.key, title: c.title, assets: c.items)) }
                current = (key, title, [])
            }
            current?.items.append(a)
        }
        if let c = current { out.append(Month(id: c.key, title: c.title, assets: c.items)) }
        months = out
    }

    /// Apply our own edit to this listing (and its disk cache) without a reload.
    func patch(_ updated: [PhotoAsset], removed: Set<String> = []) {
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        assets = assets.filter { !removed.contains($0.id) }.map { byID[$0.id] ?? $0 }
        Self.memory[key] = (Date(), assets)
    }
}

final class PageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [PhotoAsset]()
    func append(_ b: [PhotoAsset]) -> [PhotoAsset] { lock.withLock { items += b; return items } }
}
