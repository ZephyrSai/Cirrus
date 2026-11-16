#if DEBUG
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A stateful stand-in for an Immich v3 server (photos.example.com, plus LAN addresses), served through URLProtocol.
/// Unit tests use it as the mock server; Debug builds in demo mode use it for the demo Immich account. It is strict
/// about the v3 wire protocol so it catches client mistakes: the `x-api-key` header and the key's permissions
/// (403 "Missing required permission"), unknown or removed request fields (400, e.g. `deviceAssetId` on uploads),
/// the structured search shape of 3.2+ (`filter` / `orderBy` / `cursor`, never mixed with the deprecated flat
/// fields) or the flat one before 3.2, cursor paging, v3 response and error shapes, albums with `albumUsers` roles,
/// favorites, the archive, the trash (and `force` deletes, counted), multipart uploads with SHA-1 duplicate
/// detection, Live Photo linking, thumbnails and originals. Not compiled into release builds.
public final class FakeImmichServer: URLProtocol, @unchecked Sendable {
    public struct User: Codable, Sendable {
        public var id: String
        public var email: String
        public var name: String
    }

    public struct Asset: Codable, Sendable {
        public var id: String
        public var ownerID: String
        public var originalFileName: String
        public var mimeType: String
        /// "IMAGE" or "VIDEO".
        public var type: String
        public var data: Data
        /// The edited render (Immich's non-destructive edits), served for `edited=true`.
        public var editedData: Data?
        public var fileCreatedAt: Date
        public var fileModifiedAt: Date
        public var createdAt: Date
        public var updatedAt: Date
        public var isFavorite = false
        /// "timeline", "archive", "hidden" (a Live Photo's motion part) or "locked".
        public var visibility = "timeline"
        public var deletedAt: Date?
        public var livePhotoVideoID: String?
        public var width: Int?
        public var height: Int?
        public var durationMS: Int?
        public var checksum: String
        public var thumbhash: String
        public var isEdited: Bool { editedData != nil }
        public var isTrashed: Bool { deletedAt != nil }
    }

    public struct Album: Codable, Sendable {
        public var id: String
        public var name: String
        public var ownerID: String
        /// Other users: id → "editor" / "viewer".
        public var members: [String: String] = [:]
        public var assetIDs: [String] = []
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct State: Sendable {
        public var hosts: Set<String> = ["photos.example.com", "192.168.1.20", "immich.local", "localhost"]
        /// Hosts that answer every request with a web page (not Immich).
        public var htmlHosts: Set<String> = ["www.example.com"]
        /// Hosts that redirect every request to another one (old address → new).
        public var redirectHosts: [String: String] = ["old.example.com": "photos.example.com"]
        public var version = ImmichVersion(major: 3, minor: 4, patch: 1)
        public var user = User(id: "8a6f3c2e-5b1d-4e7a-9c3f-2d1e0b9a8c7d", email: "alex@example.com", name: "Alex Morgan")
        public var partner = User(id: "3c9b1d7e-2a4f-4b8c-8e1d-6f5a4b3c2d1e", email: "sam@example.com", name: "Sam Rivera")
        /// The partner shares their library with "show in timeline" on, so Immich's search mixes their photos in.
        public var partnerInTimeline = true
        /// API key → permissions ("all" or Immich permission names).
        public var apiKeys: [String: [String]] = [FakeImmichServer.testAPIKey: ["all"]]
        public var assets: [String: Asset] = [:]
        public var albums: [String: Album] = [:]
        public var trashEnabled = true
        public var latency: Double = 0
        // Fault injection
        /// The next N API requests get 429 with Retry-After: 0.
        public var rateLimitNext = 0
        /// The next N API requests get 503.
        public var unavailableNext = 0
        /// The next N API requests get 500.
        public var failNext = 0
        /// The next N requests lose the connection.
        public var dropNext = 0
        // Statistics for tests
        /// "POST /search/metadata" (paths under /api; ids shown as ":id").
        public var calls: [String] = []
        public var searchBodies: [JSON] = []
        public var deleteBodies: [JSON] = []
        /// Text fields of each upload, in order.
        public var uploadFields: [[String: String]] = []
        public var uploads = 0
        public var forceDeletes = 0
        public var thumbnailRequests: [String] = []
        public var originalRequests = 0
        /// Requests that carried an x-api-key header, per path.
        public var keyedPaths: [String] = []
        public var lastUserAgent: String?

        public init() {}

        public func asset(named name: String) -> Asset? { assets.values.first { $0.originalFileName == name } }
        public func album(named name: String) -> Album? { albums.values.first { $0.name == name } }

        /// The demo content (also a good starting point for tests).
        public static func seeded() -> State {
            var s = State()
            FakeImmichServer.seed(&s)
            return s
        }
    }

    public static let testAPIKey = "test-immich-api-key-0123456789abcdef"
    public static let demoAPIKey = "demo-immich-api-key"

    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var _state = State()
    nonisolated(unsafe) static var persistURL: URL?
    nonisolated(unsafe) static var demoStarted = false

    public static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    public static func reset(_ s: State = State()) { lock.withLock { _state = s; persistURL = nil; demoStarted = false } }
    public static func update(_ f: (inout State) -> Void) { lock.withLock { f(&_state) } }

    /// Demo mode: seeded content, kept on disk in `storage` (nil: memory only). Starts once.
    public static func startDemo(storage dir: URL?) {
        lock.withLock {
            guard !demoStarted else { return }
            demoStarted = true
            var s = State.seeded()
            s.apiKeys[demoAPIKey] = ["all"]
            s.latency = ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] != nil ? 0 : 0.02
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("immich-state-v1.json")
                persistURL = url
                if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: d) {
                    s.assets = saved.assets
                    s.albums = saved.albums
                }
            }
            _state = s
            persist()
        }
    }

    public static func demoRecord() -> CloudAccountRecord {
        let email = lock.withLock { _state.user.email }
        return CloudAccountRecord(id: "cloud:immich:demo", provider: .immich, title: email, server: "https://photos.example.com",
                                  username: email, added: Date(timeIntervalSince1970: 1_790_000_000),
                                  options: ["permissions": "all", "version": "3.4.1"])
    }

    struct Saved: Codable { var assets: [String: Asset]; var albums: [String: Album] }

    static func persist() {
        guard let url = persistURL else { return }
        if let d = try? JSONEncoder().encode(Saved(assets: _state.assets, albums: _state.albums)) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Seed

    static func newID() -> String { UUID().uuidString.lowercased() }

    static func sha1(_ d: Data) -> String { Data(Insecure.SHA1.hash(data: d)).base64EncodedString() }

    /// A little fake movie: an MP4/QuickTime file type box and padding (enough for downloads and checksums).
    static func movie(brand: String, bytes: Int, seed: Int) -> Data {
        var d = Data([0, 0, 0, 0x18]) + Data("ftyp".utf8) + Data(brand.utf8) + Data([0, 0, 0, 0]) + Data(brand.utf8) + Data("isom".utf8)
        d += Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
        return d
    }

    static func seed(_ s: inout State) {
        let me = s.user.id, partner = s.partner.id
        let base = Date(timeIntervalSince1970: 1_790_000_000)   // late September 2026
        func add(_ a: Asset) { s.assets[a.id] = a }
        func image(_ name: String, owner: String, seed i: Int, created: Date, portrait: Bool = false) -> Asset {
            let (w, h) = portrait ? (360, 480) : (480, 360)
            let data = DemoArt.scenic(width: w, height: h, seed: i) ?? DemoArt.jpeg(width: w, height: h, hue: CGFloat(i % 12) / 12, label: name) ?? Data([0xff, 0xd8, 0xff, 0xd9])
            return Asset(id: newID(), ownerID: owner, originalFileName: name, mimeType: "image/jpeg", type: "IMAGE", data: data,
                         fileCreatedAt: created, fileModifiedAt: created, createdAt: base, updatedAt: base, width: w, height: h,
                         checksum: sha1(data), thumbhash: newID().prefix(12).description)
        }
        var mine = [Asset]()
        for i in 0..<20 {
            // Spread over four months, newest first.
            let created = base.addingTimeInterval(-Double(i) * 86400 * 6.2 - Double((i * 3571) % 86400))
            var a = image(String(format: "IMG_%04d.JPG", 1000 + i), owner: me, seed: i, created: created, portrait: i % 7 == 0)
            a.isFavorite = [0, 4, 9].contains(i)
            if i == 7 { a.visibility = "archive" }
            if i == 12 { a.deletedAt = base.addingTimeInterval(-3600) }
            if i == 9 { a.editedData = DemoArt.scenic(width: 480, height: 360, seed: 109) }
            mine.append(a)
        }
        // A Live Photo: IMG_1003's motion part is a hidden video asset.
        var motion = Asset(id: newID(), ownerID: me, originalFileName: "IMG_1003.MOV", mimeType: "video/quicktime", type: "VIDEO",
                           data: movie(brand: "qt  ", bytes: 24_000, seed: 3), fileCreatedAt: mine[3].fileCreatedAt,
                           fileModifiedAt: mine[3].fileCreatedAt, createdAt: base, updatedAt: base, visibility: "hidden",
                           width: 480, height: 360, durationMS: 2500, checksum: "", thumbhash: "motion")
        motion.checksum = sha1(motion.data)
        mine[3].livePhotoVideoID = motion.id
        add(motion)
        // A short video.
        var video = Asset(id: newID(), ownerID: me, originalFileName: "VID_2001.MP4", mimeType: "video/mp4", type: "VIDEO",
                          data: movie(brand: "mp42", bytes: 60_000, seed: 7), fileCreatedAt: base.addingTimeInterval(-2 * 86400),
                          fileModifiedAt: base.addingTimeInterval(-2 * 86400), createdAt: base, updatedAt: base,
                          width: 1920, height: 1080, durationMS: 4000, checksum: "", thumbhash: "video")
        video.checksum = sha1(video.data)
        add(video)
        for a in mine { add(a) }
        // The partner's photos (in the timeline through partner sharing, and one in an album shared with Alex).
        let p1 = image("PXL_3001.JPG", owner: partner, seed: 301, created: base.addingTimeInterval(-86400))
        let p2 = image("PXL_3002.JPG", owner: partner, seed: 302, created: base.addingTimeInterval(-40 * 86400))
        add(p1)
        add(p2)
        let trip = Album(id: newID(), name: "Summer Trip", ownerID: me,
                         assetIDs: mine.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.id) + [video.id], createdAt: base, updatedAt: base)
        var family = Album(id: newID(), name: "Family", ownerID: me,
                           assetIDs: mine.enumerated().filter { $0.offset % 5 == 1 }.map(\.element.id), createdAt: base, updatedAt: base)
        family.members[partner] = "editor"
        var garden = Album(id: newID(), name: "Sam’s Garden", ownerID: partner, assetIDs: [p1.id], createdAt: base, updatedAt: base)
        garden.members[me] = "viewer"
        for al in [trip, family, garden] { s.albums[al.id] = al }
    }

    // MARK: URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let h = request.url?.host?.lowercased() else { return false }
        return lock.withLock { _state.hosts.contains(h) || _state.htmlHosts.contains(h) || _state.redirectHosts[h] != nil }
    }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    enum Outcome { case reply(Int, [String: String], Data), drop }

    override public func startLoading() {
        let req = request
        let body = Self.body(req)
        let (outcome, latency) = Self.lock.withLock { () -> (Outcome, Double) in
            let o = Self.handle(req, body: body)
            return (o, Self._state.latency)
        }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        switch outcome {
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .reply(let status, var headers, let data):
            if headers["Content-Length"] == nil { headers["Content-Length"] = String(data.count) }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                var i = 0
                while i < data.count {
                    let n = min(64 * 1024, data.count - i)
                    client?.urlProtocol(self, didLoad: data.subdata(in: i..<(i + n)))
                    i += n
                }
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func body(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    // MARK: Replies

    static func json(_ status: Int, _ j: JSON) -> Outcome {
        .reply(status, ["Content-Type": "application/json; charset=utf-8"], j.data())
    }

    /// v3 error body: a message string, validation problems in `errors`, the correlation id in a header.
    static func error(_ status: Int, _ message: String, errors: [(String, String)] = []) -> Outcome {
        var body: [String: JSON] = ["message": .string(message)]
        if !errors.isEmpty { body["errors"] = .array(errors.map { ["path": .array($0.0.split(separator: ".").map { .string(String($0)) }), "message": .string($0.1)] }) }
        return .reply(status, ["Content-Type": "application/json; charset=utf-8", "X-Correlation-ID": newID()], JSON.object(body).data())
    }

    static func invalid(_ path: String, _ message: String) -> Outcome { error(400, "Validation failed", errors: [(path, message)]) }

    static func date(_ d: Date?) -> JSON { d.map { .string(ImmichDates.string($0)) } ?? .null }

    static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil && s.count == 36
    }

    // MARK: Routing

    static func handle(_ req: URLRequest, body: Data) -> Outcome {
        guard let url = req.url, let host = url.host?.lowercased() else { return .drop }
        let method = req.httpMethod ?? "GET"
        if let target = _state.redirectHosts[host] {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.host = target
            c.scheme = "https"
            c.port = nil
            return .reply(308, ["Location": c.url!.absoluteString], Data())
        }
        if _state.htmlHosts.contains(host) {
            return .reply(200, ["Content-Type": "text/html"], Data("<!doctype html><title>Welcome</title><p>It works!</p>".utf8))
        }
        let path = url.path
        guard path == "/api" || path.hasPrefix("/api/") else {
            // Immich's web app answers every other path with its single page.
            return .reply(200, ["Content-Type": "text/html"], Data("<!doctype html><title>Immich</title><div id=app></div>".utf8))
        }
        if _state.dropNext > 0 { _state.dropNext -= 1; return .drop }
        let sub = String(path.dropFirst(4))
        let segs = sub.split(separator: "/").map(String.init)
        let template = "/" + segs.map { isUUID($0) ? ":id" : $0 }.joined(separator: "/")
        _state.calls.append("\(method) \(template)")
        _state.lastUserAgent = req.value(forHTTPHeaderField: "User-Agent")
        if req.value(forHTTPHeaderField: "x-api-key") != nil { _state.keyedPaths.append(template) }
        if _state.rateLimitNext > 0 { _state.rateLimitNext -= 1; return .reply(429, ["Retry-After": "0", "Content-Type": "text/plain"], Data("Too Many Requests".utf8)) }
        if _state.unavailableNext > 0 { _state.unavailableNext -= 1; return error(503, "Service Unavailable") }
        if _state.failNext > 0 { _state.failNext -= 1; return error(500, "Failed to process the request") }
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { $1 })

        // Public endpoints.
        switch (method, template) {
        case ("GET", "/server/ping"): return json(200, ["res": "pong"])
        case ("GET", "/server/version"):
            let v = _state.version
            return json(200, ["major": .int(v.major), "minor": .int(v.minor), "patch": .int(v.patch), "prerelease": nil])
        case ("GET", "/server/features"):
            return json(200, ["trash": .bool(_state.trashEnabled), "search": true, "map": true, "smartSearch": true, "duplicateDetection": true,
                              "facialRecognition": true, "oauth": false, "oauthAutoLaunch": false, "passwordLogin": true, "sidecar": true,
                              "reverseGeocoding": true, "importFaces": false, "configFile": false, "email": false, "ocr": false,
                              "realtimeTranscoding": false, "backups": false])
        default: break
        }

        // Everything else needs the API key.
        guard let key = req.value(forHTTPHeaderField: "x-api-key") else { return error(401, "Authentication required") }
        guard let perms = _state.apiKeys[key] else { return error(401, "Invalid API key") }
        func allowed(_ p: String) -> Bool { perms.contains("all") || perms.contains(p) }
        func need(_ p: String) -> Outcome? { allowed(p) ? nil : error(403, "Missing required permission: \(p)") }

        let jsonBody: JSON?
        if ["POST", "PUT", "PATCH", "DELETE"].contains(method), template != "/assets" || method != "POST" {
            guard (req.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("application/json") else {
                return error(400, "Content-Type must be application/json")
            }
            guard let j = try? JSON(data: body), case .object = j else { return invalid("", "Expected an object") }
            jsonBody = j
        } else {
            jsonBody = nil
        }
        let outcome: Outcome
        switch (method, template) {
        case ("GET", "/users/me"):
            outcome = need("user.read") ?? json(200, userAdmin(_state.user))
        case ("GET", "/api-keys/me"):
            outcome = json(200, ["id": "5f0e1d2c-3b4a-4596-8877-665544332211", "name": "Cirrus", "permissions": .array(perms.map { .string($0) }),
                                 "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-01T00:00:00.000Z"])
        case ("GET", "/assets/statistics"):
            outcome = need("asset.statistics") ?? statistics(query)
        case ("POST", "/search/metadata"):
            outcome = need("asset.read") ?? search(jsonBody!)
        case ("GET", "/albums"):
            outcome = need("album.read") ?? listAlbums(query)
        case ("POST", "/albums"):
            outcome = need("album.create") ?? createAlbum(jsonBody!)
        case ("PUT", "/albums/:id/assets"):
            outcome = need("albumAsset.create") ?? addToAlbum(segs[1], jsonBody!, canShare: allowed("asset.share"))
        case ("PUT", "/assets"), ("PATCH", "/assets"):
            outcome = need("asset.update") ?? bulkUpdate(jsonBody!)
        case ("DELETE", "/assets"):
            outcome = need("asset.delete") ?? deleteAssets(jsonBody!)
        case ("POST", "/trash/restore/assets"):
            outcome = need("asset.delete") ?? restore(jsonBody!)
        case ("POST", "/assets/bulk-upload-check"):
            outcome = need("asset.upload") ?? bulkUploadCheck(jsonBody!)
        case ("POST", "/assets"):
            outcome = need("asset.upload") ?? upload(req, body, canLink: allowed("asset.update"))
        case ("GET", "/assets/:id/thumbnail"):
            outcome = need("asset.view") ?? thumbnail(segs[1], query)
        case ("GET", "/assets/:id/original"):
            outcome = need("asset.download") ?? original(segs[1], query)
        default:
            outcome = error(404, "Cannot \(method) \(path)")
        }
        if method != "GET" { persist() }
        return outcome
    }

    static func userJSON(_ u: User) -> JSON {
        ["id": .string(u.id), "email": .string(u.email), "name": .string(u.name), "avatarColor": "primary",
         "profileImagePath": "", "profileChangedAt": "2026-07-01T00:00:00.000Z"]
    }

    static func userAdmin(_ u: User) -> JSON {
        var o = userJSON(u).object
        for (k, v) in ["isAdmin": JSON.bool(true), "createdAt": "2026-07-01T00:00:00.000Z", "updatedAt": "2026-07-01T00:00:00.000Z",
                       "deletedAt": nil, "oauthId": "", "quotaSizeInBytes": nil, "quotaUsageInBytes": .int(0), "shouldChangePassword": false,
                       "status": "active", "storageLabel": "admin", "license": nil, "clusterGroupId": nil] {
            o[k] = v
        }
        return .object(o)
    }

    // MARK: Assets

    static func assetJSON(_ a: Asset, withExif: Bool) -> JSON {
        var o: [String: JSON] = [
            "id": .string(a.id), "ownerId": .string(a.ownerID), "type": .string(a.type), "originalFileName": .string(a.originalFileName),
            "originalMimeType": .string(a.mimeType), "originalPath": .string("/data/upload/\(a.ownerID)/\(a.id)"),
            "checksum": .string(a.checksum), "thumbhash": .string(a.thumbhash),
            "fileCreatedAt": date(a.fileCreatedAt), "fileModifiedAt": date(a.fileModifiedAt), "localDateTime": date(a.fileCreatedAt),
            "createdAt": date(a.createdAt), "updatedAt": date(a.updatedAt),
            "isFavorite": .bool(a.isFavorite), "isArchived": .bool(a.visibility == "archive"), "isTrashed": .bool(a.isTrashed),
            "isOffline": false, "isEdited": .bool(a.isEdited), "hasMetadata": true, "visibility": .string(a.visibility),
            "duration": a.durationMS.map { .int($0) } ?? .null, "width": a.width.map { .int($0) } ?? .null, "height": a.height.map { .int($0) } ?? .null,
            "livePhotoVideoId": a.livePhotoVideoID.map { .string($0) } ?? .null, "duplicateId": nil, "libraryId": nil,
        ]
        if withExif {
            o["exifInfo"] = ["fileSizeInByte": .int(a.data.count), "exifImageWidth": a.width.map { .int($0) } ?? .null,
                             "exifImageHeight": a.height.map { .int($0) } ?? .null, "dateTimeOriginal": date(a.fileCreatedAt),
                             "make": nil, "model": nil, "city": nil, "country": nil, "rating": nil]
        }
        return .object(o)
    }

    /// Who may see an asset: its owner, a partner sharing with them, or anyone in an album holding it.
    static func canView(_ a: Asset) -> Bool {
        let me = _state.user.id
        if a.ownerID == me { return a.visibility != "locked" }
        if a.ownerID == _state.partner.id && _state.partnerInTimeline && a.visibility != "locked" { return true }
        return _state.albums.values.contains { al in (al.ownerID == me || al.members[me] != nil) && al.assetIDs.contains(a.id) }
    }

    static func statistics(_ q: [String: String]) -> Outcome {
        for k in q.keys where !["isFavorite", "isTrashed", "visibility"].contains(k) { return invalid(k, "Unrecognized key") }
        if let v = q["visibility"], !["archive", "timeline", "hidden", "locked"].contains(v) { return invalid("visibility", "Invalid option") }
        let trashed = q["isTrashed"] == "true"
        let list = _state.assets.values.filter { a in
            guard a.ownerID == _state.user.id, a.isTrashed == trashed else { return false }
            if let v = q["visibility"] { if a.visibility != v { return false } } else if !(a.visibility == "archive" || a.visibility == "timeline") { return false }
            if let f = q["isFavorite"] { if a.isFavorite != (f == "true") { return false } }
            return true
        }
        let videos = list.filter { $0.type == "VIDEO" }.count
        return json(200, ["images": .int(list.count - videos), "videos": .int(videos), "total": .int(list.count)])
    }

    static let newShapeKeys: Set<String> = ["filter", "orderBy", "cursor"]
    static let sharedSearchKeys: Set<String> = ["size", "withExif", "withPeople", "withStacked"]
    /// The deprecated flat fields this fake implements (the real list is longer; the rest answer 400 here).
    static let legacyKeys: Set<String> = ["page", "order", "visibility", "isFavorite", "withDeleted", "trashedAfter", "trashedBefore",
                                          "albumIds", "type", "updatedAfter"]
    static let filterKeysImplemented: Set<String> = ["visibility", "isFavorite", "trashedAt", "type", "albumIds", "updatedAt"]
    static let filterKeysValid: Set<String> = ["albumIds", "checksum", "city", "country", "createdAt", "description", "encodedVideoPath",
                                               "fileSizeInBytes", "hasAlbums", "hasPeople", "hasTags", "id", "isEncoded", "isFavorite", "isMotion",
                                               "isOffline", "lensModel", "libraryId", "make", "model", "ocr", "or", "originalFileName", "originalPath",
                                               "personIds", "rating", "state", "tagIds", "takenAt", "trashedAt", "type", "updatedAt", "visibility"]

    static func search(_ body: JSON) -> Outcome {
        _state.searchBodies.append(body)
        let o = body.object
        let structured = _state.version.hasStructuredSearch
        let newKeys = o.keys.filter { newShapeKeys.contains($0) }
        for k in o.keys where !newShapeKeys.contains(k) && !sharedSearchKeys.contains(k) && !legacyKeys.contains(k) {
            return invalid(k, "Unrecognized key (or a search field this fake doesn’t implement)")
        }
        let size = o["size"]?.int ?? 250
        if let s = o["size"], s.double.map({ $0 != $0.rounded() }) ?? true { return invalid("size", "Expected integer") }
        guard (1...1000).contains(size) else { return invalid("size", "Number must be between 1 and 1000") }
        let me = _state.user.id
        var list: [Asset]
        if !newKeys.isEmpty {
            guard structured else { return invalid(newKeys[0], "Unrecognized key") }   // before 3.2
            if let old = o.keys.first(where: { legacyKeys.contains($0) }) {
                return invalid(old, "Deprecated field \(old) cannot be combined with \(newKeys.sorted().joined(separator: "/"))")
            }
            let filter = o["filter"] ?? [:]
            guard case .object(let f) = filter else { return invalid("filter", "Expected object") }
            for k in f.keys {
                guard filterKeysValid.contains(k) else { return invalid("filter.\(k)", "Unrecognized key") }
                guard filterKeysImplemented.contains(k) else { return invalid("filter.\(k)", "Not implemented by the fake server") }
            }
            var albumIDs = [String]()
            if let ids = f["albumIds"] {
                for k in ids.object.keys where !["any", "all", "none"].contains(k) { return invalid("filter.albumIds.\(k)", "Unrecognized key") }
                guard ids.object.keys.allSatisfy({ $0 == "any" }) else { return invalid("filter.albumIds", "Only `any` is implemented by the fake server") }
                albumIDs = ids["any"].array.compactMap(\.string)
                guard !albumIDs.isEmpty, albumIDs.allSatisfy(isUUID) else { return invalid("filter.albumIds.any", "Expected non-empty array of uuids") }
            }
            if let v = f["visibility"], let bad = enumFilterProblem(v, ["archive", "timeline", "hidden", "locked"]) { return invalid("filter.visibility", bad) }
            if let v = f["type"], let bad = enumFilterProblem(v, ["IMAGE", "VIDEO", "AUDIO", "OTHER"]) { return invalid("filter.type", bad) }
            if let fav = f["isFavorite"], fav.object.keys.sorted() != ["eq"] || fav["eq"].bool == nil { return invalid("filter.isFavorite", "Expected { eq: boolean }") }
            if let t = f["trashedAt"] {
                for k in t.object.keys where !["eq", "ne", "gt", "gte", "lt", "lte"].contains(k) { return invalid("filter.trashedAt.\(k)", "Unrecognized key") }
            }
            if let ob = o["orderBy"] {
                for k in ob.object.keys where !["field", "direction"].contains(k) { return invalid("orderBy.\(k)", "Unrecognized key") }
                if let fld = ob["field"].string, !["fileCreatedAt", "localDateTime"].contains(fld) { return invalid("orderBy.field", "Invalid option") }
                if let d = ob["direction"].string, !["asc", "desc"].contains(d) { return invalid("orderBy.direction", "Invalid option") }
            }
            if albumIDs.isEmpty {
                list = _state.assets.values.filter { $0.ownerID == me || ($0.ownerID == _state.partner.id && _state.partnerInTimeline) }
            } else {
                for id in albumIDs {
                    guard let al = _state.albums[id], al.ownerID == me || al.members[me] != nil else { return error(400, "Not found or no album.read access") }
                }
                let ids = Set(albumIDs.flatMap { _state.albums[$0]?.assetIDs ?? [] })
                list = _state.assets.values.filter { ids.contains($0.id) }
            }
            list = list.filter { a in
                if let v = f["visibility"], !enumMatches(v, a.visibility) { return false }
                if f["visibility"] == nil && a.visibility == "locked" { return false }
                if let t = f["type"], !enumMatches(t, a.type) { return false }
                if let fav = f["isFavorite"]?["eq"].bool, a.isFavorite != fav { return false }
                if let t = f["trashedAt"] {
                    if case .null = t["eq"], t.object["eq"] != nil, a.deletedAt != nil { return false }
                    if case .null = t["ne"], t.object["ne"] != nil, a.deletedAt == nil { return false }
                }
                if let u = f["updatedAt"]?["gt"].string, let d = ImmichDates.parse(.string(u)), a.updatedAt <= d { return false }
                return true
            }
            let field = o["orderBy"]?["field"].string ?? "fileCreatedAt"
            let asc = o["orderBy"]?["direction"].string == "asc"
            _ = field
            list.sort { a, b in a.fileCreatedAt != b.fileCreatedAt ? (asc ? a.fileCreatedAt < b.fileCreatedAt : a.fileCreatedAt > b.fileCreatedAt) : (asc ? a.id < b.id : a.id > b.id) }
            var offset = 0
            if let c = o["cursor"] {
                guard let s = c.string, let d = fromBase64URL(s), let cj = try? JSON(data: d), let n = cj["offset"].int, n >= 0, cj.object.count == 1 else {
                    return error(400, "Invalid cursor")
                }
                offset = n
            }
            let pageItems = Array(list.dropFirst(offset).prefix(size))
            let more = list.count > offset + size
            let next: JSON = more ? .string(base64URL(Data(#"{"offset":\#(offset + size)}"#.utf8))) : .null
            return json(200, searchResponse(pageItems, withExif: o["withExif"]?.bool == true, nextPage: .null, nextCursor: next))
        }
        // The flat (deprecated) shape.
        if let p = o["page"], (p.int ?? 0) < 1 { return invalid("page", "Number must be greater than or equal to 1") }
        if let v = o["visibility"]?.string, !["archive", "timeline", "hidden", "locked"].contains(v) { return invalid("visibility", "Invalid option") }
        if let v = o["visibility"]?.string, v == "locked" { return error(401, "Elevated permission is required") }
        if let ord = o["order"]?.string, !["asc", "desc"].contains(ord) { return invalid("order", "Invalid option") }
        let page = o["page"]?.int ?? 1
        let albumIDs = o["albumIds"]?.array.compactMap(\.string) ?? []
        if albumIDs.isEmpty {
            list = _state.assets.values.filter { $0.ownerID == me || ($0.ownerID == _state.partner.id && _state.partnerInTimeline) }
        } else {
            for id in albumIDs {
                guard let al = _state.albums[id], al.ownerID == me || al.members[me] != nil else { return error(400, "Not found or no album.read access") }
            }
            let ids = Set(albumIDs.flatMap { _state.albums[$0]?.assetIDs ?? [] })
            list = _state.assets.values.filter { ids.contains($0.id) }
        }
        let trashedAfter = o["trashedAfter"]?.string.flatMap { ImmichDates.parse(.string($0)) }
        let withDeleted = o["withDeleted"]?.bool == true || trashedAfter != nil
        list = list.filter { a in
            if let v = o["visibility"]?.string { if a.visibility != v { return false } } else if a.visibility == "locked" { return false }
            if let fav = o["isFavorite"]?.bool, a.isFavorite != fav { return false }
            if let t = o["type"]?.string, a.type != t { return false }
            if !withDeleted && a.deletedAt != nil { return false }
            if let after = trashedAfter { guard let d = a.deletedAt, d >= after else { return false } }
            return true
        }
        let asc = o["order"]?.string == "asc"
        list.sort { a, b in a.fileCreatedAt != b.fileCreatedAt ? (asc ? a.fileCreatedAt < b.fileCreatedAt : a.fileCreatedAt > b.fileCreatedAt) : (asc ? a.id < b.id : a.id > b.id) }
        let start = (page - 1) * size
        let pageItems = Array(list.dropFirst(start).prefix(size))
        let more = list.count > start + size
        var res = searchResponse(pageItems, withExif: o["withExif"]?.bool == true, nextPage: more ? .string(String(page + 1)) : .null, nextCursor: .null)
        if !structured, case .object(var top) = res, case .object(var a) = top["assets"] {
            a["nextCursor"] = nil   // not in the 3.0–3.1 response
            top["assets"] = .object(a)
            res = .object(top)
        }
        return json(200, res)
    }

    static func enumFilterProblem(_ v: JSON, _ allowed: [String]) -> String? {
        guard case .object(let o) = v, !o.isEmpty else { return "Expected object" }
        for (k, x) in o {
            switch k {
            case "eq", "ne": if !allowed.contains(x.string ?? "") { return "Invalid option for \(k)" }
            case "in", "notIn":
                let items = x.array
                if items.isEmpty || !items.allSatisfy({ allowed.contains($0.string ?? "") }) { return "Invalid options for \(k)" }
            default: return "Unrecognized key \(k)"
            }
        }
        return nil
    }

    static func enumMatches(_ v: JSON, _ value: String) -> Bool {
        if let e = v["eq"].string, e != value { return false }
        if let n = v["ne"].string, n == value { return false }
        if case .array(let a) = v["in"], !a.contains(.string(value)) { return false }
        if case .array(let a) = v["notIn"], a.contains(.string(value)) { return false }
        return true
    }

    static func searchResponse(_ items: [Asset], withExif: Bool, nextPage: JSON, nextCursor: JSON) -> JSON {
        ["albums": ["total": 0, "count": 0, "items": [], "facets": []],
         "assets": ["total": .int(items.count), "count": .int(items.count), "items": .array(items.map { assetJSON($0, withExif: withExif) }),
                    "facets": [], "nextPage": nextPage, "nextCursor": nextCursor]]
    }

    static func idList(_ body: JSON, allowed: Set<String>) -> Result<[String], FakeError> {
        for k in body.object.keys where !allowed.contains(k) { return .failure(FakeError(invalid(k, "Unrecognized key"))) }
        guard case .array(let a) = body["ids"] else { return .failure(FakeError(invalid("ids", "Required"))) }
        let ids = a.compactMap(\.string)
        guard ids.count == a.count, ids.allSatisfy(isUUID) else { return .failure(FakeError(invalid("ids", "Invalid uuid"))) }
        return .success(ids)
    }

    struct FakeError: Error { let outcome: Outcome; init(_ o: Outcome) { outcome = o } }

    static func bulkUpdate(_ body: JSON) -> Outcome {
        let allowed: Set<String> = ["ids", "isFavorite", "visibility", "dateTimeOriginal", "dateTimeRelative", "description", "duplicateId",
                                    "latitude", "longitude", "rating", "timeZone"]
        let ids: [String]
        switch idList(body, allowed: allowed) { case .success(let x): ids = x; case .failure(let e): return e.outcome }
        if let f = body.object["isFavorite"], f.bool == nil || { if case .bool = f { return false }; return true }() { return invalid("isFavorite", "Expected boolean") }
        if let v = body.object["visibility"] {
            guard let s = v.string, ["archive", "timeline", "hidden", "locked"].contains(s) else { return invalid("visibility", "Invalid option") }
            if s == "locked" { return error(401, "Elevated permission is required") }
        }
        for id in ids {
            guard let a = _state.assets[id], a.ownerID == _state.user.id else { return error(400, "Not found or no asset.update access") }
        }
        let now = Date()
        for id in ids {
            if let f = body["isFavorite"].bool { _state.assets[id]?.isFavorite = f }
            if let v = body["visibility"].string { _state.assets[id]?.visibility = v }
            _state.assets[id]?.updatedAt = now
        }
        return .reply(204, [:], Data())
    }

    static func deleteAssets(_ body: JSON) -> Outcome {
        _state.deleteBodies.append(body)
        let ids: [String]
        switch idList(body, allowed: ["ids", "force"]) { case .success(let x): ids = x; case .failure(let e): return e.outcome }
        if let f = body.object["force"], f.bool == nil { return invalid("force", "Expected boolean") }
        for id in ids {
            guard let a = _state.assets[id], a.ownerID == _state.user.id else { return error(400, "Not found or no asset.delete access") }
        }
        let force = body["force"].bool == true
        if force { _state.forceDeletes += 1 }
        for id in ids {
            if force || !_state.trashEnabled {
                // Gone for good (with the trash off, the server's nightly job removes trashed photos at once).
                _state.assets[id] = nil
                for k in _state.albums.keys { _state.albums[k]?.assetIDs.removeAll { $0 == id } }
            } else {
                _state.assets[id]?.deletedAt = Date()
                _state.assets[id]?.updatedAt = Date()
            }
        }
        return .reply(204, [:], Data())
    }

    static func restore(_ body: JSON) -> Outcome {
        let ids: [String]
        switch idList(body, allowed: ["ids"]) { case .success(let x): ids = x; case .failure(let e): return e.outcome }
        for id in ids {
            guard let a = _state.assets[id], a.ownerID == _state.user.id else { return error(400, "Not found or no asset.delete access") }
        }
        var n = 0
        for id in ids where _state.assets[id]?.deletedAt != nil {
            _state.assets[id]?.deletedAt = nil
            _state.assets[id]?.updatedAt = Date()
            n += 1
        }
        return json(200, ["count": .int(n)])
    }

    // MARK: Albums

    static func albumJSON(_ al: Album) -> JSON {
        let me = _state.user.id
        func user(_ id: String) -> User { id == _state.user.id ? _state.user : _state.partner }
        var users: [JSON] = [["user": userJSON(user(al.ownerID)), "role": "owner"]]
        if al.ownerID != me, let r = al.members[me] { users.append(["user": userJSON(_state.user), "role": .string(r)]) }
        for (id, r) in al.members.sorted(by: { $0.key < $1.key }) where id != me { users.append(["user": userJSON(user(id)), "role": .string(r)]) }
        let live = al.assetIDs.compactMap { _state.assets[$0] }.filter { !$0.isTrashed }
        return ["id": .string(al.id), "albumName": .string(al.name), "description": "", "createdAt": date(al.createdAt), "updatedAt": date(al.updatedAt),
                "albumThumbnailAssetId": live.first.map { .string($0.id) } ?? .null, "shared": .bool(!al.members.isEmpty),
                "albumUsers": .array(users), "hasSharedLink": false, "assetCount": .int(live.count), "isActivityEnabled": true, "order": "desc"]
    }

    static func listAlbums(_ q: [String: String]) -> Outcome {
        for k in q.keys where !["id", "name", "isOwned", "isShared", "assetId"].contains(k) { return invalid(k, "Unrecognized key") }
        if q["shared"] != nil { return invalid("shared", "Unrecognized key") }
        let me = _state.user.id
        var list = _state.albums.values.filter { $0.ownerID == me || $0.members[me] != nil }
        if let o = q["isOwned"] { list = list.filter { ($0.ownerID == me) == (o == "true") } }
        if let s = q["isShared"] { list = list.filter { !$0.members.isEmpty == (s == "true") } }
        list.sort { $0.createdAt > $1.createdAt }
        return json(200, .array(list.map(albumJSON)))
    }

    static func createAlbum(_ body: JSON) -> Outcome {
        for k in body.object.keys where !["albumName", "description", "albumUsers", "assetIds"].contains(k) { return invalid(k, "Unrecognized key") }
        guard let name = body["albumName"].string else { return invalid("albumName", "Required") }
        let now = Date()
        var al = Album(id: newID(), name: name, ownerID: _state.user.id, createdAt: now, updatedAt: now)
        for id in body["assetIds"].array.compactMap(\.string) where _state.assets[id]?.ownerID == _state.user.id { al.assetIDs.append(id) }
        _state.albums[al.id] = al
        return json(201, albumJSON(al))
    }

    static func addToAlbum(_ albumID: String, _ body: JSON, canShare: Bool) -> Outcome {
        let me = _state.user.id
        guard var al = _state.albums[albumID], al.ownerID == me || al.members[me] == "editor" else {
            return error(400, "Not found or no albumAsset.create access")
        }
        let ids: [String]
        switch idList(body, allowed: ["ids"]) { case .success(let x): ids = x; case .failure(let e): return e.outcome }
        var results = [JSON]()
        var added = false
        for id in ids {
            if al.assetIDs.contains(id) { results.append(["id": .string(id), "success": false, "error": "duplicate"]); continue }
            guard let a = _state.assets[id] else { results.append(["id": .string(id), "success": false, "error": "not_found"]); continue }
            guard a.ownerID == me, canShare else { results.append(["id": .string(id), "success": false, "error": "no_permission"]); continue }
            al.assetIDs.append(id)
            added = true
            results.append(["id": .string(id), "success": true])
        }
        if added { al.updatedAt = Date() }
        _state.albums[albumID] = al
        return json(200, .array(results))
    }

    // MARK: Uploads

    static let uploadable: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "avif", "tif", "tiff", "dng", "cr2", "cr3", "nef",
                                          "arw", "raf", "rw2", "orf", "mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"]

    static func bulkUploadCheck(_ body: JSON) -> Outcome {
        for k in body.object.keys where k != "assets" { return invalid(k, "Unrecognized key") }
        guard case .array(let items) = body["assets"] else { return invalid("assets", "Required") }
        var results = [JSON]()
        for it in items {
            guard let id = it["id"].string, let sum = it["checksum"].string, it.object.count == 2 else { return invalid("assets", "Expected { id, checksum }") }
            let normalized = sum.count == 40 ? (fromHex(sum)?.base64EncodedString() ?? sum) : sum
            if let a = _state.assets.values.first(where: { $0.ownerID == _state.user.id && $0.checksum == normalized }) {
                results.append(["id": .string(id), "action": "reject", "reason": "duplicate", "assetId": .string(a.id), "isTrashed": .bool(a.isTrashed)])
            } else {
                results.append(["id": .string(id), "action": "accept"])
            }
        }
        return json(200, ["results": .array(results)])
    }

    static func upload(_ req: URLRequest, _ body: Data, canLink: Bool) -> Outcome {
        let me = _state.user.id
        // The checksum header lets Immich answer "duplicate" before reading the file.
        if let sum = req.value(forHTTPHeaderField: "x-immich-checksum"),
           let a = _state.assets.values.first(where: { $0.ownerID == me && $0.checksum == sum }) {
            return json(200, ["id": .string(a.id), "status": "duplicate"])
        }
        let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard ct.hasPrefix("multipart/form-data"), let r = ct.range(of: "boundary=") else { return error(400, "Expected multipart/form-data") }
        let boundary = String(ct[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let parts = parseMultipart(body, boundary: boundary) else { return error(400, "Malformed multipart body") }
        var fields = [String: String]()
        var file: (name: String, data: Data)?
        for p in parts {
            if p.name == "assetData" {
                guard let fn = p.filename else { return invalid("assetData", "Expected a file") }
                file = (fn, p.data)
            } else if p.name == "sidecarData" {
                continue
            } else {
                guard p.filename == nil else { return invalid(p.name, "Unexpected file") }
                fields[p.name] = String(decoding: p.data, as: UTF8.self)
            }
        }
        _state.uploadFields.append(fields)
        let allowed: Set<String> = ["fileCreatedAt", "fileModifiedAt", "duration", "filename", "isFavorite", "visibility", "livePhotoVideoId", "metadata"]
        for k in fields.keys where !allowed.contains(k) {
            // deviceAssetId / deviceId were removed in v3.
            return invalid(k, "Unrecognized key")
        }
        guard let f = file, !f.data.isEmpty else { return error(400, "File is empty: assetData") }
        guard let created = fields["fileCreatedAt"].flatMap({ ImmichDates.parse(.string($0)) }) else { return invalid("fileCreatedAt", "Invalid ISO datetime") }
        guard let modified = fields["fileModifiedAt"].flatMap({ ImmichDates.parse(.string($0)) }) else { return invalid("fileModifiedAt", "Invalid ISO datetime") }
        if let v = fields["visibility"], !["archive", "timeline", "hidden", "locked"].contains(v) { return invalid("visibility", "Invalid option") }
        let name = fields["filename"].flatMap { $0.isEmpty ? nil : $0 } ?? f.name
        let ext = (name as NSString).pathExtension.lowercased()
        guard uploadable.contains(ext) else { return error(400, "Unsupported file type \(name)") }
        if let live = fields["livePhotoVideoId"] {
            guard canLink else { return error(403, "Missing required permission: asset.update") }
            guard isUUID(live), let v = _state.assets[live], v.ownerID == me else { return error(400, "Not found or no asset.update access") }
            guard v.type == "VIDEO" else { return error(400, "Live photo video must be a video") }
            if v.visibility == "timeline" { _state.assets[live]?.visibility = "hidden" }
        }
        let sum = sha1(f.data)
        if let a = _state.assets.values.first(where: { $0.ownerID == me && $0.checksum == sum }) {
            return json(200, ["id": .string(a.id), "status": "duplicate"])
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let isVideo = ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"].contains(ext)
        var (w, h): (Int?, Int?) = (nil, nil)
        if !isVideo, let src = CGImageSourceCreateWithData(f.data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int
            h = props[kCGImagePropertyPixelHeight] as? Int
        }
        let now = Date()
        let a = Asset(id: newID(), ownerID: me, originalFileName: name, mimeType: mime, type: isVideo ? "VIDEO" : "IMAGE", data: f.data,
                      fileCreatedAt: created, fileModifiedAt: modified, createdAt: now, updatedAt: now,
                      isFavorite: fields["isFavorite"] == "true", visibility: fields["visibility"] ?? "timeline",
                      livePhotoVideoID: fields["livePhotoVideoId"], width: w, height: h, durationMS: fields["duration"].flatMap { Int($0) },
                      checksum: sum, thumbhash: String(newID().prefix(12)))
        _state.assets[a.id] = a
        _state.uploads += 1
        return json(201, ["id": .string(a.id), "status": "created"])
    }

    struct Part { var name: String; var filename: String?; var contentType: String?; var data: Data }

    static func parseMultipart(_ body: Data, boundary: String) -> [Part]? {
        let delim = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts = [Part]()
        guard var pos = body.range(of: delim)?.upperBound else { return nil }
        while true {
            // After a delimiter: "--" ends the body, otherwise CRLF then a part.
            if body[pos...].starts(with: Data("--".utf8)) { return parts }
            guard body[pos...].starts(with: crlf) else { return nil }
            pos += 2
            guard let he = body.range(of: headerEnd, in: pos..<body.endIndex) else { return nil }
            let headers = String(decoding: body[pos..<he.lowerBound], as: UTF8.self)
            guard let next = body.range(of: crlf + delim, in: he.upperBound..<body.endIndex) else { return nil }
            let content = body.subdata(in: he.upperBound..<next.lowerBound)
            var part = Part(name: "", filename: nil, contentType: nil, data: content)
            for line in headers.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition:") {
                    part.name = param(line, "name") ?? ""
                    part.filename = param(line, "filename")
                } else if lower.hasPrefix("content-type:") {
                    part.contentType = String(line.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !part.name.isEmpty else { return nil }
            parts.append(part)
            pos = next.upperBound
        }
    }

    static func param(_ header: String, _ key: String) -> String? {
        for piece in header.components(separatedBy: ";").dropFirst() {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            guard kv.hasPrefix(key + "=\"") else { continue }
            return String(kv.dropFirst(key.count + 2).dropLast())
        }
        return nil
    }

    // MARK: Media

    static func thumbnail(_ id: String, _ q: [String: String]) -> Outcome {
        for k in q.keys where !["size", "edited", "c", "key", "slug"].contains(k) { return invalid(k, "Unrecognized key") }
        let size = q["size"] ?? "thumbnail"
        guard ["thumbnail", "preview", "fullsize"].contains(size) else { return invalid("size", "Invalid option") }
        guard let a = _state.assets[id], canView(a) else { return error(400, "Not found or no asset.view access") }
        _state.thumbnailRequests.append(size)
        let px = size == "thumbnail" ? 250 : 1440
        let source = (q["edited"] == "true" ? a.editedData : nil) ?? a.data
        let jpeg: Data
        if a.type == "IMAGE", let cg = PhotoFormats.cgImage(from: source, maxPixel: px), let d = PhotoFormats.jpeg(cg) {
            jpeg = d
        } else {
            // A poster frame for videos.
            jpeg = DemoArt.jpeg(width: min(px, 320), height: min(px, 180), hue: 0.6, label: "▶") ?? Data()
        }
        return .reply(200, ["Content-Type": "image/jpeg", "Cache-Control": "private, max-age=86400"], jpeg)
    }

    static func original(_ id: String, _ q: [String: String]) -> Outcome {
        for k in q.keys where !["edited", "key", "slug"].contains(k) { return invalid(k, "Unrecognized key") }
        guard let a = _state.assets[id], canView(a) else { return error(400, "Not found or no asset.download access") }
        _state.originalRequests += 1
        let data = (q["edited"] == "true" ? a.editedData : nil) ?? a.data
        return .reply(200, ["Content-Type": a.mimeType, "Content-Disposition": "attachment; filename=\"\(a.originalFileName)\""], data)
    }
}

extension FakeImmichServer {
    static func fromBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func fromHex(_ hex: String) -> Data? {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }
}
#endif
