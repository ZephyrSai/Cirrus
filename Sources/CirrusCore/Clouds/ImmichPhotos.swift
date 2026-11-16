import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// An Immich photo library as a `PhotosBackend`: one library ("immich"), smart albums for the timeline,
/// favorites, videos, the archive (Cirrus's Hidden) and the trash (Recently Deleted), plus the user's own
/// albums and albums others shared with them.
///
/// Ids: assets use Immich's asset id; albums are "album:<Immich album id>" and the smart ones "smart:All Photos",
/// "smart:Favorites", "smart:Videos", "smart:Hidden" (Immich's archive) and "smart:Recently Deleted" (Immich's trash).
/// A Live Photo's motion part (a hidden video asset in Immich) is the still's `.liveVideo` resource.
///
/// Rules: listing goes newest first in pages (`POST /search/metadata`); the smart albums show only the user's own
/// assets (a partner's photos that Immich mixes into the timeline are theirs to manage); deleting always uses
/// Immich's trash (never `force`) and is refused when the server has its trash turned off; uploads are checked
/// against the library by SHA-1 first, so a photo already there is never sent twice. Safe from any thread.
public final class ImmichPhotos: PhotosBackend, @unchecked Sendable {
    public static let library = PhotoLibraryRef(id: "immich", name: "Immich", isShared: false)

    /// The smart albums. Raw values are the album ids.
    enum Smart: String, CaseIterable {
        case allPhotos = "smart:All Photos"
        case favorites = "smart:Favorites"
        case videos = "smart:Videos"
        case archive = "smart:Hidden"
        case trash = "smart:Recently Deleted"

        /// Immich's own words for the archive and the trash.
        var name: String {
            switch self {
            case .allPhotos: return "All Photos"
            case .favorites: return "Favorites"
            case .videos: return "Videos"
            case .archive: return "Archive"
            case .trash: return "Trash"
            }
        }

        var symbol: String {
            switch self {
            case .allPhotos: return "photo.on.rectangle"
            case .favorites: return "heart"
            case .videos: return "video"
            case .archive: return "archivebox"
            case .trash: return "trash"
            }
        }
    }

    enum Scope: Equatable { case smart(Smart), album(String) }

    public let record: CloudAccountRecord
    public let cacheKey: String
    let client: ImmichClient
    private let lock = NSLock()
    private var _permissions: Set<String>?
    private var _userID: String?
    private var _version: ImmichVersion?
    private var _trash: (enabled: Bool, checked: Date)?
    /// Asset id → owner, from listings: edits to someone else's photo are refused before asking the server.
    private var owners = [String: String]()
    private var _firstPageSize = 200
    private var _pageSize = 1000
    /// A small first page so the grid fills fast, then big ones (Immich allows up to 1000). Tests lower them.
    var firstPageSize: Int { get { lock.withLock { _firstPageSize } } set { lock.withLock { _firstPageSize = newValue } } }
    var pageSize: Int { get { lock.withLock { _pageSize } } set { lock.withLock { _pageSize = newValue } } }

    init(record: CloudAccountRecord, server: URL, apiKey: String, transport: [AnyClass]?) {
        self.record = record
        cacheKey = "immich-" + record.id
        client = ImmichClient(server: server, apiKey: apiKey, serviceName: Immich.serviceName(record.title), transport: transport)
        if let p = record.options?["permissions"], !p.isEmpty { _permissions = Set(p.split(separator: ",").map(String.init)) }
    }

    // MARK: Capabilities

    func has(_ permission: String) -> Bool {
        guard let p = lock.withLock({ _permissions }) else { return true }
        return p.contains("all") || p.contains(permission)
    }

    /// What the API key may do (refreshed from `GET /api-keys/me` with each `libraries()`).
    public var capabilities: PhotoCapabilities {
        var c: PhotoCapabilities = []
        if has("asset.update") { c.formUnion([.favorite, .hide]) }
        if has("asset.delete") { c.formUnion([.delete, .restore]) }
        if has("asset.upload") { c.insert(.importFiles) }
        if has("album.read") { c.insert(.albums) }
        if has("album.create") { c.insert(.createAlbum) }
        return c
    }

    // MARK: Session facts

    func version() async throws -> ImmichVersion {
        if let v = lock.withLock({ _version }) { return v }
        let j = try await client.call("GET", "/server/version", retry: .safe)
        guard let v = ImmichVersion(j) else { throw CloudError.server("The Immich server didn’t say which version it runs.") }
        lock.withLock { _version = v }
        return v
    }

    func userID() async throws -> String {
        if let u = lock.withLock({ _userID }) { return u }
        let me = try await client.call("GET", "/users/me", retry: .safe)
        guard let id = me["id"].string else { throw CloudError.server("Immich didn’t say who the API key belongs to.") }
        lock.withLock { _userID = id }
        return id
    }

    func refreshPermissions() async {
        guard let k = try? await client.call("GET", "/api-keys/me", retry: .safe), case .array(let list) = k["permissions"] else { return }
        lock.withLock { _permissions = Set(list.compactMap(\.string)) }
    }

    /// Whether the server keeps deleted photos in its trash (nil: couldn't tell). Checked at most every 10 minutes.
    func trashEnabled() async -> Bool? {
        if let t = lock.withLock({ _trash }), Date().timeIntervalSince(t.checked) < 600 { return t.enabled }
        guard let f = try? await client.call("GET", "/server/features", retry: .safe), let on = f["trash"].bool else { return nil }
        lock.withLock { _trash = (on, Date()) }
        return on
    }

    // MARK: Libraries & albums

    public func libraries() async throws -> [PhotoLibraryRef] {
        async let perms: Void = refreshPermissions()
        async let v: ImmichVersion? = try? await version()
        lock.withLock { _userID = nil }   // re-ask: also checks the key still works (401 → sign in again)
        _ = try await userID()
        _ = await v
        await perms
        return [Self.library]
    }

    public func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] {
        let me = try await userID()
        async let timeline = stats(["visibility": "timeline", "isTrashed": "false"])
        async let favorites = stats(["visibility": "timeline", "isTrashed": "false", "isFavorite": "true"])
        async let archived = stats(["visibility": "archive", "isTrashed": "false"])
        async let trashed = stats(["isTrashed": "true"])
        var list = [JSON]()
        do {
            list = try await client.call("GET", "/albums", retry: .safe).array
        } catch CloudError.denied {
            // A key without album.read: the smart albums still work.
        }
        let (t, f, a, tr) = await (timeline, favorites, archived, trashed)
        var out = Smart.allCases.map { s -> PhotoAlbum in
            let count: Int?
            switch s {
            case .allPhotos: count = t?.total
            case .favorites: count = f?.total
            case .videos: count = t?.videos
            case .archive: count = a?.total
            case .trash: count = tr?.total
            }
            return PhotoAlbum(id: s.rawValue, name: s.name, kind: .smart, count: count, symbol: s.symbol)
        }
        let user = list.compactMap { Self.album($0, me: me) }.sorted {
            if ($0.kind == .album) != ($1.kind == .album) { return $0.kind == .album }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        out += user
        return out
    }

    func stats(_ query: [String: String]) async -> (total: Int, videos: Int)? {
        guard let j = try? await client.call("GET", "/assets/statistics", query: query, retry: .safe), let total = j["total"].int else { return nil }
        return (total, j["videos"].int ?? 0)
    }

    func count(_ s: Smart) async -> Int? {
        switch s {
        case .allPhotos: return await stats(["visibility": "timeline", "isTrashed": "false"])?.total
        case .favorites: return await stats(["visibility": "timeline", "isTrashed": "false", "isFavorite": "true"])?.total
        case .videos: return await stats(["visibility": "timeline", "isTrashed": "false"])?.videos
        case .archive: return await stats(["visibility": "archive", "isTrashed": "false"])?.total
        case .trash: return await stats(["isTrashed": "true"])?.total
        }
    }

    /// An `AlbumResponseDto` → album. v3 names the owner in `albumUsers` (role "owner"); older servers had `ownerId`.
    static func album(_ j: JSON, me: String) -> PhotoAlbum? {
        guard let id = j["id"].string, !id.isEmpty else { return nil }
        var name = (j["albumName"].string ?? "").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        let owner = j["albumUsers"].array.first { $0["role"].string == "owner" }?["user"]["id"].string
            ?? j["ownerId"].string ?? j["owner"]["id"].string
        let mine = owner == nil || owner == me
        let shared = j["shared"].bool ?? false
        return PhotoAlbum(id: "album:" + id, name: name, kind: mine ? .album : .shared, count: j["assetCount"].int,
                          symbol: mine ? (shared ? "rectangle.stack.badge.person.crop" : "rectangle.stack") : "person.2")
    }

    func scope(_ album: PhotoAlbum) throws -> Scope {
        if let s = Smart(rawValue: album.id) { return .smart(s) }
        if album.id.hasPrefix("album:"), album.id.count > 6 { return .album(String(album.id.dropFirst(6))) }
        throw CloudError.notFound
    }

    // MARK: Listing

    /// Immich 3.2+: the structured filter.
    static func filter(_ s: Scope) -> JSON {
        let notTrashed: JSON = ["eq": nil]
        let shown: JSON = ["in": ["timeline", "archive"]]
        switch s {
        case .smart(.allPhotos): return ["visibility": ["eq": "timeline"], "trashedAt": notTrashed]
        case .smart(.favorites): return ["visibility": ["eq": "timeline"], "trashedAt": notTrashed, "isFavorite": ["eq": true]]
        case .smart(.videos): return ["visibility": ["eq": "timeline"], "trashedAt": notTrashed, "type": ["eq": "VIDEO"]]
        case .smart(.archive): return ["visibility": ["eq": "archive"], "trashedAt": notTrashed]
        case .smart(.trash): return ["visibility": shown, "trashedAt": ["ne": nil]]
        case .album(let id): return ["albumIds": ["any": [.string(id)]], "visibility": shown, "trashedAt": notTrashed]
        }
    }

    /// Immich 3.0–3.1: the flat fields (deprecated from 3.2). They can't say "timeline or archive", so the album
    /// and trash listings ask for any visibility and `belongs` drops Live Photo motion parts.
    static func legacyFields(_ s: Scope) -> [String: JSON] {
        switch s {
        case .smart(.allPhotos): return ["visibility": "timeline"]
        case .smart(.favorites): return ["visibility": "timeline", "isFavorite": true]
        case .smart(.videos): return ["visibility": "timeline", "type": "VIDEO"]
        case .smart(.archive): return ["visibility": "archive"]
        case .smart(.trash): return ["withDeleted": true, "trashedAfter": "1970-01-01T00:00:00.000Z"]
        case .album(let id): return ["albumIds": [.string(id)]]
        }
    }

    /// Double-checks each answer (and keeps the smart albums to the user's own photos).
    static func belongs(_ a: JSON, to s: Scope, me: String) -> Bool {
        let vis = a["visibility"].string ?? (a["isArchived"].bool == true ? "archive" : "timeline")
        let trashed = a["isTrashed"].bool ?? false
        let shown = vis == "timeline" || vis == "archive"
        switch s {
        case .smart(let k):
            guard a["ownerId"].string.map({ $0 == me }) ?? true else { return false }
            switch k {
            case .allPhotos: return vis == "timeline" && !trashed
            case .favorites: return vis == "timeline" && !trashed && a["isFavorite"].bool == true
            case .videos: return vis == "timeline" && !trashed && a["type"].string == "VIDEO"
            case .archive: return vis == "archive" && !trashed
            case .trash: return trashed && shown
            }
        case .album:
            return !trashed && shown
        }
    }

    public func assets(in album: PhotoAlbum, library: PhotoLibraryRef,
                       page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        guard album.kind != .folder else { return [] }
        let scope = try scope(album)
        let me = try await userID()
        let v = try await version()
        var total = album.count
        if total == nil, case .smart(let s) = scope { total = await count(s) }
        let structured = v.hasStructuredSearch
        var out = [PhotoAsset]()
        var seen = Set<String>()
        var listedOwners = [String: String]()
        var cursor: String?
        var pageNumber = 1
        var size = structured ? firstPageSize : pageSize
        while true {
            try Task.checkCancellation()
            var body: [String: JSON] = ["size": .int(size), "withExif": true]
            if structured {
                body["filter"] = Self.filter(scope)
                body["orderBy"] = ["field": "fileCreatedAt", "direction": "desc"]
                if let c = cursor { body["cursor"] = .string(c) }
            } else {
                body.merge(Self.legacyFields(scope)) { $1 }
                body["order"] = "desc"
                body["page"] = .int(pageNumber)
            }
            let r = try await client.call("POST", "/search/metadata", json: .object(body), retry: .safe)
            let res = r["assets"]
            let items = res["items"].array
            var batch = [PhotoAsset]()
            for j in items where Self.belongs(j, to: scope, me: me) {
                guard let a = Self.asset(j), seen.insert(a.id).inserted else { continue }
                if let o = j["ownerId"].string { listedOwners[a.id] = o }
                batch.append(a)
            }
            if !batch.isEmpty {
                out += batch
                page(batch, total)
            }
            let next = structured ? res["nextCursor"].string : res["nextPage"].string
            guard let n = next, !n.isEmpty, !items.isEmpty else { break }
            if structured { cursor = n } else { pageNumber = Int(n) ?? pageNumber + 1 }
            if structured { size = pageSize }
        }
        lock.withLock { owners.merge(listedOwners) { $1 } }
        return out
    }

    /// An `AssetResponseDto` → asset.
    static func asset(_ j: JSON) -> PhotoAsset? {
        guard let id = j["id"].string, !id.isEmpty else { return nil }
        let exif = j["exifInfo"]
        var name = (j["originalFileName"].string ?? "").precomposedStringWithCanonicalMapping
        var uti = j["originalMimeType"].string.flatMap { UTType(mimeType: $0)?.identifier }
        if uti == nil, !name.isEmpty { uti = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier }
        if name.isEmpty { name = id + "." + (uti.flatMap { PhotoFormats.utiExtensions[$0] } ?? "jpg") }
        name = Paths.safeName(name)
        let stem = (name as NSString).deletingPathExtension
        let isVideo = j["type"].string == "VIDEO"
        let size = exif["fileSizeInByte"].int64 ?? 0
        let edited = j["isEdited"].bool == true
        let live = j["livePhotoVideoId"].string.flatMap { $0.isEmpty ? nil : $0 }
        var res = [PhotoResource(kind: .original, filename: name, size: size, key: "original", recordName: id, url: nil, uti: uti)]
        if let live {
            res.append(PhotoResource(kind: .liveVideo, filename: stem + ".MOV", size: 0, key: "original", recordName: live, url: nil,
                                     uti: "com.apple.quicktime-movie"))
        }
        if edited && !isVideo {
            res.append(PhotoResource(kind: .edited, filename: stem + "-edited.jpg", size: 0, key: "edited", recordName: id, url: nil, uti: "public.jpeg"))
        }
        // Server-made renditions; `c` is Immich's own cache-buster (the thumbhash), so a new edit gets a new cache entry.
        let buster = (j["thumbhash"].string ?? j["updatedAt"].string ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        for (kind, sizeName) in [(PhotoResource.Kind.thumbnail, "thumbnail"), (.medium, "preview")] {
            var q = "size=" + sizeName
            if edited { q += "&edited=true" }
            if !buster.isEmpty { q += "&c=" + buster }
            res.append(PhotoResource(kind: kind, filename: stem + (kind == .thumbnail ? "-thumbnail" : "-preview"), size: 0, key: sizeName,
                                     recordName: id, url: "/assets/\(id)/thumbnail?" + q, uti: nil))
        }
        let vis = j["visibility"].string ?? (j["isArchived"].bool == true ? "archive" : "timeline")
        return PhotoAsset(id: id, masterID: id, changeTag: j["updatedAt"].string, library: library.id, filename: name, size: size,
                          created: ImmichDates.parse(j["fileCreatedAt"]) ?? ImmichDates.parse(j["localDateTime"]),
                          added: ImmichDates.parse(j["createdAt"]),
                          width: j["width"].int ?? exif["exifImageWidth"].int ?? 0, height: j["height"].int ?? exif["exifImageHeight"].int ?? 0,
                          duration: duration(j["duration"]), isVideo: isVideo, isLive: live != nil, isFavorite: j["isFavorite"].bool == true,
                          isHidden: vis == "archive", isDeleted: j["isTrashed"].bool == true, isEdited: edited, uti: uti, resources: res)
    }

    /// Seconds: v3 sends milliseconds (or null); older servers sent "H:MM:SS.ffffff".
    static func duration(_ j: JSON) -> Double? {
        switch j {
        case .number(let ms): return ms > 0 ? ms / 1000 : nil
        case .string(let s):
            if let ms = Double(s) { return ms > 0 ? ms / 1000 : nil }
            let parts = s.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            let secs = parts[0] * 3600 + parts[1] * 60 + parts[2]
            return secs > 0 ? secs : nil
        default: return nil
        }
    }

    // MARK: Content

    public func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? {
        let kind: PhotoResource.Kind = maxPixel > 300 ? .medium : .thumbnail
        let px = kind == .medium ? 1440 : 250
        let path = asset.resource(kind)?.url ?? "/assets/\(asset.id)/thumbnail?size=" + (kind == .medium ? "preview" : "thumbnail")
        if let d = ThumbnailDiskCache.read(cacheKey, path, px), let cg = PhotoFormats.cgImage(from: d, maxPixel: maxPixel) { return cg }
        let data: Data
        do { data = try await client.fetch(path) } catch CloudError.notFound { return nil }
        guard let cg = PhotoFormats.cgImage(from: data, maxPixel: maxPixel) else { return nil }
        ThumbnailDiskCache.write(data, cacheKey, path, px)
        return cg
    }

    public func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let r = asset.resource(resource) else { throw CloudError.notFound }
        let path: String
        switch r.kind {
        case .thumbnail, .medium: path = r.url ?? "/assets/\(r.recordName)/thumbnail?size=\(r.key)"
        case .edited: path = "/assets/\(r.recordName)/original?edited=true"
        default: path = "/assets/\(r.recordName)/original"
        }
        try await client.download(path, to: destination, expected: r.size, progress: progress)
        if let d = asset.created {
            try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: destination.path)
        }
    }

    // MARK: Edits

    /// The ids to change; refuses (before asking the server) when some belong to someone who shared them.
    func ownIDs(_ assets: [PhotoAsset], _ verb: String) async throws -> [String] {
        let me = try await userID()
        let others = lock.withLock { assets.filter { owners[$0.id].map { $0 != me } ?? false } }.count
        if others > 0 {
            throw CloudError.denied((others == 1 ? "One of these photos belongs" : "\(others) of these photos belong")
                + " to someone who shared \(others == 1 ? "it" : "them") with you, so only they can \(verb) \(others == 1 ? "it" : "them") in Immich.")
        }
        var seen = Set<String>()
        return assets.map(\.id).filter { seen.insert($0).inserted }
    }

    static func ids(_ list: [String]) -> JSON { .array(list.map { .string($0) }) }

    public func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        let ids = try await ownIDs(assets, value ? "favorite" : "unfavorite")
        for chunk in ids.chunked(500) {
            try await client.call("PUT", "/assets", json: ["ids": Self.ids(chunk), "isFavorite": .bool(value)], retry: .safe)
        }
        return assets.map { var a = $0; a.isFavorite = value; return a }
    }

    /// Hidden = Immich's archive (out of the timeline, still in albums and search).
    public func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        let ids = try await ownIDs(assets, value ? "archive" : "unarchive")
        for chunk in ids.chunked(500) {
            try await client.call("PUT", "/assets", json: ["ids": Self.ids(chunk), "visibility": .string(value ? "archive" : "timeline")], retry: .safe)
        }
        return assets.map { var a = $0; a.isHidden = value; return a }
    }

    static let trashOff = CloudError.denied("This Immich server has its trash turned off, so deleting would remove photos for good. "
        + "Cirrus only moves photos to the trash: turn the trash on in Immich (Administration › Settings › Trash Settings), or delete them in Immich itself.")

    /// To Immich's trash (restorable until the server empties it). Never `force`.
    public func delete(_ assets: [PhotoAsset]) async throws {
        guard !assets.isEmpty else { return }
        let ids = try await ownIDs(assets, "delete")
        if await trashEnabled() == false { throw Self.trashOff }
        for chunk in ids.chunked(500) {
            try await client.call("DELETE", "/assets", json: ["ids": Self.ids(chunk)], retry: .safe)
        }
    }

    public func restore(_ assets: [PhotoAsset]) async throws {
        guard !assets.isEmpty else { return }
        let ids = try await ownIDs(assets, "restore")
        try await restore(ids: ids)
    }

    func restore(ids: [String]) async throws {
        for chunk in ids.chunked(500) {
            try await client.call("POST", "/trash/restore/assets", json: ["ids": Self.ids(chunk)], retry: .safe)
        }
    }

    public func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CloudError.notConfigured("Enter a name for the album.") }
        let j = try await client.call("POST", "/albums", json: ["albumName": .string(title)], retry: .rateLimitOnly)
        guard let id = j["id"].string else { throw CloudError.server("Immich didn’t say which album it created.") }
        return PhotoAlbum(id: "album:" + id, name: (j["albumName"].string ?? title).precomposedStringWithCanonicalMapping, kind: .album,
                          count: 0, symbol: "rectangle.stack")
    }

    public func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws {
        guard album.id.hasPrefix("album:"), album.kind == .album || album.kind == .shared else {
            throw CloudError.unsupported("Photos can only be added to albums, not to “\(album.name)”.")
        }
        try await add(ids: assets.map(\.id), toAlbum: String(album.id.dropFirst(6)))
    }

    func add(ids: [String], toAlbum albumID: String) async throws {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var failed = 0
        for chunk in unique.chunked(500) {
            let r = try await client.call("PUT", "/albums/\(albumID)/assets", json: ["ids": Self.ids(chunk)], retry: .safe)
            // "duplicate" = already in the album: fine.
            failed += r.array.filter { $0["success"].bool != true && $0["error"].string != "duplicate" }.count
        }
        if failed > 0 {
            throw CloudError.denied("Immich couldn’t add \(failed == 1 ? "one photo" : "\(failed) photos") to the album: "
                + "\(failed == 1 ? "it belongs" : "they belong") to someone else or no longer exist.")
        }
    }

    // MARK: Import

    public func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef,
                            progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let ids = try await importReturningIDs(files, library: library, progress: progress)
        if let album, album.id.hasPrefix("album:"), album.kind == .album || album.kind == .shared, !ids.isEmpty {
            try await add(ids: ids, toAlbum: String(album.id.dropFirst(6)))
        }
    }

    /// Uploads each photo (a Live Photo's still and .MOV together, linked as one) and returns their ids. A photo
    /// already in the library isn't sent again: its existing id comes back (restored first if it was in the trash).
    public func importReturningIDs(_ files: [URL], library: PhotoLibraryRef,
                                   progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let groups = LivePairing.group(files)
        let total = files.reduce(Int64(0)) { $0 + Self.fileSize($1) }
        var done: Int64 = 0
        var ids = [String]()
        progress(0, total)
        for g in groups {
            try Task.checkCancellation()
            let stillSize = Self.fileSize(g.primary), videoSize = g.pairedVideo.map(Self.fileSize) ?? 0
            let stillSum = try ImmichUpload.sha1(g.primary)
            if let existing = try await existing(stillSum) {
                ids.append(existing)
                done += stillSize + videoSize
                progress(done, total)
                continue
            }
            var videoID: String?
            if let v = g.pairedVideo {
                let sum = try ImmichUpload.sha1(v)
                if let existing = try await existing(sum) {
                    videoID = existing
                } else {
                    videoID = try await upload(v, checksum: sum, livePhotoVideoID: nil, base: done, total: total, progress: progress)
                }
                done += videoSize
                progress(done, total)
            }
            // Linking needs asset.update on the video; without it Immich still pairs them from their metadata.
            let link = has("asset.update") ? videoID : nil
            let id = try await upload(g.primary, checksum: stillSum, livePhotoVideoID: link, base: done, total: total, progress: progress)
            ids.append(id)
            done += stillSize
            progress(done, total)
        }
        return ids
    }

    static func fileSize(_ u: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// The id of the user's asset with this checksum, if Immich has it (brought back from the trash if needed).
    func existing(_ checksum: String) async throws -> String? {
        let r = try await client.call("POST", "/assets/bulk-upload-check",
                                      json: ["assets": [["id": "0", "checksum": .string(checksum)]]], retry: .safe)
        let res = r["results"].array.first { $0["id"].string == "0" } ?? r["results"][0]
        guard res["action"].string == "reject" else { return nil }
        if res["reason"].string == "unsupported-format" {
            throw CloudError.unsupported("Immich doesn’t accept one of these files: its format isn’t supported.")
        }
        guard let id = res["assetId"].string else { return nil }
        if res["isTrashed"].bool == true {
            do { try await restore(ids: [id]) } catch {
                throw CloudError.denied("One of these photos is already in Immich’s trash, and Cirrus couldn’t restore it "
                    + "(\(error.localizedDescription)). Restore it in Immich, then try again.")
            }
        }
        return id
    }

    func upload(_ file: URL, checksum: String, livePhotoVideoID: String?, base: Int64, total: Int64,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attrs?[.modificationDate] as? Date ?? Date()
        let created = min(attrs?[.creationDate] as? Date ?? modified, modified)
        let name = file.lastPathComponent.precomposedStringWithCanonicalMapping
        var fields = [("fileCreatedAt", ImmichDates.string(created)), ("fileModifiedAt", ImmichDates.string(modified)), ("filename", name)]
        if let l = livePhotoVideoID { fields.append(("livePhotoVideoId", l)) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let boundary = "CirrusImmich" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let body = try ImmichUpload.multipart(fields: fields, fileField: "assetData", file: file, filename: name, mime: mime, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body.deletingLastPathComponent()) }
        let size = Self.fileSize(file)
        // Idempotent: a retried upload that already landed comes back as a duplicate of the same asset.
        let r = try await client.send("POST", "/assets", body: .file(body),
                                      headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)", "x-immich-checksum": checksum],
                                      retry: .safe, progress: { sent, _ in progress(base + min(sent, size), total) }, total: size)
        guard r.ok else { throw client.failure(r) }
        guard let j = try? JSON(data: r.data), let id = j["id"].string else { throw CloudError.server("Immich didn’t say which photo it created.") }
        return id
    }
}

/// Immich's timestamps ("2026-07-01T10:00:00.000Z"), parsed with shared formatters (listings parse thousands).
enum ImmichDates {
    private static let lock = NSLock()
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ j: JSON) -> Date? {
        guard let s = j.string, !s.isEmpty else { return nil }
        return lock.withLock { frac.date(from: s) ?? plain.date(from: s) }
    }

    static func string(_ d: Date) -> String { lock.withLock { frac.string(from: d) } }
}
