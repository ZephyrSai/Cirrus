#if DEBUG
import CryptoKit
import Foundation

/// A stateful stand-in for Google's OAuth, Drive v3, Photos Library and Photos Picker endpoints,
/// served through URLProtocol. Unit tests use it as the mock Google server; Debug builds in demo
/// mode (CIRRUS_DEMO=1) use it so both directions of the move run without a Google account.
/// It follows the documented wire protocol strictly (PKCE, per-token scopes, 256 KiB chunks,
/// 50-item batches, app-created-only visibility for drive.file) so it catches client mistakes.
/// Not compiled into release builds.
public final class FakeGoogleServer: URLProtocol, @unchecked Sendable {
    public struct File: Codable, Sendable {
        public var id: String
        public var name: String
        public var mimeType: String
        public var parents: [String]
        public var size: Int64
        public var md5: String?
        public var modifiedTime: String?
        public var trashed: Bool
        public var appProperties: [String: String]
        public var byApp: Bool
        public var canDownload = true
        public var exportTooLarge = false
        /// Public properties and description (any client sees them); appProperties belong to `appClient` only.
        public var properties: [String: String]? = nil
        public var description: String? = nil
        public var appClient: String? = nil
        public var createdTime: String? = nil
        /// Shortcuts (mimeType application/vnd.google-apps.shortcut): the file or folder they point to.
        public var shortcutTarget: String? = nil
        public var isNative: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && mimeType != GoogleDrive.folderMime }
        /// Google makes thumbnails for pictures, videos, PDFs and Docs editors files.
        public var hasThumbnail: Bool {
            mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") || mimeType == "application/pdf"
                || ["document", "spreadsheet", "presentation", "drawing"].map { "application/vnd.google-apps." + $0 }.contains(mimeType)
        }
    }
    public struct MediaItem: Codable, Sendable { public var id: String; public var fileName: String; public var description: String?; public var size: Int64; public var md5: String }
    public struct Album: Codable, Sendable { public var id: String; public var title: String; public var items: [String] }
    public struct PickerPhoto: Codable, Sendable {
        public var id: String; public var fileName: String; public var mime: String; public var data: Data; public var created: Date; public var isVideo: Bool
        public init(id: String, fileName: String, mime: String, data: Data, created: Date, isVideo: Bool) {
            self.id = id; self.fileName = fileName; self.mime = mime; self.data = data; self.created = created; self.isVideo = isVideo
        }
    }
    struct Blob: Codable { var md5: String; var size: Int64 }
    struct Code { var challenge: String; var redirect: String; var scopes: [String] }
    struct DriveSession { var meta: JSON; var total: Int64; var data = Data(); var fileID: String?; var client: String? = nil; var keepData = false }
    struct PhotoSession { var total: Int64; var data = Data(); var token: String? }
    struct PickerSession { var items: [String] = []; var set = false }

    public static let rootID = "0AFakeMyDriveRoot"

    /// Everything the server knows. Tests read and tweak it between steps.
    public struct State: Sendable {
        public var clientID = "demo-client.apps.googleusercontent.com"
        public var clientSecret: String? = "demo-secret"
        /// What the user ticks on the consent page (each sign-in gets the requested ones among these).
        public var grantedScopes = GoogleScopes.all + [GoogleScopes.driveReadonly, GoogleScopes.photosPicker, GoogleScopes.drive]
        public var userID = "demo-google-user"
        public var email = "demo.person@gmail.example"
        public var name = "Demo Person"
        public var limit: Int64? = 15_000_000_000
        public var usage: Int64 = 2_300_000_000
        public var accessTTL: Double = 3600
        public var files: [String: File] = [:]
        public var blobs: [String: Data] = [:]          // content of the user's own Drive files
        public var media: [String: MediaItem] = [:]
        public var albums: [String: Album] = [:]
        public var pickerLibrary: [PickerPhoto] = []
        var refreshTokens = [String: [String]]()        // refresh token → scopes
        var refreshClients = [String: String]()         // refresh token → OAuth client
        var accessTokens = [String: (Date, [String], String)]()   // expiry, scopes, client
        var codes = [String: Code]()
        var uploadTokens = [String: Blob]()
        var mediaByHash = [String: String]()
        var driveSessions = [String: DriveSession]()
        var photoSessions = [String: PhotoSession]()
        var pickerSessions = [String: PickerSession]()
        // Statistics for tests
        public var calls: [String] = []
        public var permanentDeletes = 0
        public var batchCreateSizes: [Int] = []
        public var albumAddSizes: [Int] = []
        public var driveSessionsStarted = 0
        public var photoSessionsStarted = 0
        public var statusQueries = 0
        public var refreshes = 0
        public var chunkPuts = 0
        public var rangedGets = 0
        public var exportLinkUses = 0
        public var pickerSessionsDeleted = 0
        /// Pixel sizes asked of the Drive thumbnail endpoint (`…=s<px>`).
        public var thumbnailSizes: [Int] = []
        /// Requests that reached a non-Google host, and whether they carried a bearer token.
        public var foreignRequests: [(host: String, hadToken: Bool)] = []
        // Fault injection
        /// The Nth Drive chunk (1-based) arrives half-way, then the connection drops.
        public var dropDriveChunk: Int?
        /// The Nth Photos resumable chunk drops the same way.
        public var dropPhotoChunk: Int?
        /// After this many Drive chunks, every further chunk gets 503 (simulates Google being down).
        public var failDriveChunksAfter: Int?
        /// The Nth ranged download request loses its connection.
        public var dropDownloadAt: Int?
        /// Downloads (Drive bytes, exports, export links, Photos base URLs) first answer 302 to this host.
        public var redirectDownloadsTo: String?
        /// The next N Drive/Photos API calls get 429 with Retry-After: 0.
        public var rateLimitNext = 0
        /// Photos Library requests left today (nil = unlimited).
        public var photosRequestsLeft: Int?
        /// batchCreate rejects items with these file names.
        public var rejectFileNames: Set<String> = []
        /// Each refresh hands out a new refresh token and retires the old one (Google may rotate them).
        public var rotateRefreshTokens = false
        public var latency: Double = 0
        public init() {}

        public var visibleFiles: [File] { files.values.filter(\.byApp) }
        public func file(named name: String) -> File? { files.values.first { $0.name == name && !$0.trashed } }
        public var refreshTokenList: [String] { Array(refreshTokens.keys) }
        public mutating func revokeAllRefreshTokens() { refreshTokens = [:] }

        // Seeding the user's own Google Drive (files Cirrus didn't create).
        @discardableResult
        public mutating func addUserFolder(_ name: String, parent: String = FakeGoogleServer.rootID) -> String {
            let id = FakeGoogleServer.newID("d")
            files[id] = File(id: id, name: name, mimeType: GoogleDrive.folderMime, parents: [parent], size: 0, md5: nil, modifiedTime: nil,
                             trashed: false, appProperties: [:], byApp: false)
            return id
        }
        @discardableResult
        public mutating func addUserFile(_ name: String, parent: String = FakeGoogleServer.rootID, data: Data, modified: Date = Date(timeIntervalSince1970: 1_700_000_000),
                                         canDownload: Bool = true) -> String {
            let id = FakeGoogleServer.newID("u")
            files[id] = File(id: id, name: name, mimeType: GoogleDrive.mimeType(for: name), parents: [parent], size: Int64(data.count),
                             md5: FakeGoogleServer.md5(data), modifiedTime: GoogleDrive.iso(modified), trashed: false, appProperties: [:], byApp: false,
                             canDownload: canDownload)
            blobs[id] = data
            return id
        }
        @discardableResult
        public mutating func addUserDoc(_ name: String, kind: String = "document", parent: String = FakeGoogleServer.rootID, tooLarge: Bool = false,
                                        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> String {
            let id = FakeGoogleServer.newID("g")
            files[id] = File(id: id, name: name, mimeType: "application/vnd.google-apps." + kind, parents: [parent], size: 0, md5: nil,
                             modifiedTime: GoogleDrive.iso(modified), trashed: false, appProperties: [:], byApp: false, exportTooLarge: tooLarge)
            return id
        }
        /// Simulates editing a file in Google Drive.
        public mutating func changeUserFile(_ id: String, data: Data) {
            blobs[id] = data
            files[id]?.size = Int64(data.count)
            files[id]?.md5 = FakeGoogleServer.md5(data)
            files[id]?.modifiedTime = GoogleDrive.iso(Date())
        }
        /// A Drive shortcut to another file or folder.
        @discardableResult
        public mutating func addUserShortcut(_ name: String, to target: String, parent: String = FakeGoogleServer.rootID,
                                             modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> String {
            let id = FakeGoogleServer.newID("s")
            var f = File(id: id, name: name, mimeType: FakeGoogleServer.shortcutMime, parents: [parent], size: 0, md5: nil,
                         modifiedTime: GoogleDrive.iso(modified), trashed: false, appProperties: [:], byApp: false)
            f.shortcutTarget = target
            files[id] = f
            return id
        }
        /// In the trash itself, or inside a folder that is (as Google reports `trashed`).
        public func isTrashed(_ id: String) -> Bool {
            var seen = Set<String>()
            var cur = files[id]
            while let f = cur {
                if f.trashed { return true }
                guard let p = f.parents.first, seen.insert(p).inserted else { return false }
                cur = files[p]
            }
            return false
        }
        /// Whether `id` is `ancestor` or somewhere inside it.
        func isInside(_ id: String, _ ancestor: String) -> Bool {
            var seen = Set<String>()
            var cur: String? = id
            while let c = cur, seen.insert(c).inserted {
                if c == ancestor { return true }
                cur = files[c]?.parents.first
            }
            return false
        }
    }

    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var _state = State()
    nonisolated(unsafe) static var persistURL: URL?
    public static let hosts: Set<String> = ["oauth2.googleapis.com", "accounts.google.com", "www.googleapis.com", "photoslibrary.googleapis.com",
                                            "docs.google.com", "photospicker.googleapis.com", "lh3.googleusercontent.com",
                                            "doc-0s-docs.googleusercontent.com", "downloads.example.net"]
    /// The OAuth client of the request being handled (set under the lock).
    nonisolated(unsafe) static var requestClient: String?

    public static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    public static func reset(_ s: State = State()) { lock.withLock { _state = s } }
    public static func update(_ f: (inout State) -> Void) { lock.withLock { f(&_state) } }

    /// Demo mode: a persistent fake account with its own Drive files (Cirrus can read them only with
    /// drive.readonly) and a few photos to pick.
    public static func startDemo(storage dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("google-state-v2.json")
        lock.withLock {
            persistURL = url
            var s = State()
            s.latency = 0.01
            if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: d) { saved.restore(into: &s) }
            if !s.files.values.contains(where: { !$0.byApp }) {
                s.addUserFile("Résumé.pdf", data: Data(("%PDF-1.4 demo résumé\n" + String(repeating: "x", count: 18_000)).utf8))
                s.addUserFile("Notes.txt", data: Data("Things to move off Google.\n".utf8))
                let trip = s.addUserFolder("Lisbon Trip")
                s.addUserFile("Itinerary.pdf", parent: trip, data: Data(("%PDF-1.4 itinerary\n" + String(repeating: "y", count: 42_000)).utf8))
                s.addUserFile("Packing list.txt", parent: trip, data: Data("Passport\nCharger\n".utf8))
                s.addUserDoc("Meeting notes")
                s.addUserDoc("Budget 2026", kind: "spreadsheet")
                s.addUserDoc("Pitch deck", kind: "presentation", parent: trip)
                s.addUserDoc("RSVP", kind: "form")
                // Shared with the user but not in My Drive: not part of the copy.
                s.addUserFile("Someone else’s file.pdf", parent: "shared-folder-elsewhere", data: Data("%PDF shared".utf8))
            }
            if s.pickerLibrary.isEmpty {
                for i in 0..<4 {
                    let data = DemoArt.jpeg(width: 900, height: 600, hue: CGFloat(i) / 4 + 0.05, label: "Picked \(i + 1)") ?? Data(count: 1000)
                    s.pickerLibrary.append(PickerPhoto(id: "pk\(i)", fileName: "PXL_2025080\(i)_120000.jpg", mime: "image/jpeg", data: data,
                                                       created: Date(timeIntervalSince1970: 1_754_000_000 + Double(i) * 86_400), isVideo: false))
                }
            }
            _state = s
        }
    }

    struct Saved: Codable {
        var files: [String: File]; var blobs: [String: Data]; var media: [String: MediaItem]; var albums: [String: Album]; var usage: Int64
        var refresh: [String: [String]]; var uploadTokens: [String: Blob]; var mediaByHash: [String: String]
        func restore(into s: inout State) {
            s.files = files; s.blobs = blobs; s.media = media; s.albums = albums; s.usage = usage; s.refreshTokens = refresh
            s.uploadTokens = uploadTokens; s.mediaByHash = mediaByHash
        }
    }

    static func persist() {
        guard let url = persistURL else { return }
        let s = _state
        let saved = Saved(files: s.files, blobs: s.blobs, media: s.media, albums: s.albums, usage: s.usage, refresh: s.refreshTokens,
                          uploadTokens: s.uploadTokens, mediaByHash: s.mediaByHash)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: url, options: .atomic) }
    }

    /// Plays the browser: "approves" the consent page and calls the app's loopback redirect.
    public static func approve(_ url: URL, deny: Bool = false) async {
        var q = [String: String]()
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        guard let redirect = q["redirect_uri"], var back = URLComponents(string: redirect) else { return }
        var items = [URLQueryItem(name: "state", value: q["state"])]
        let known = lock.withLock { q["client_id"] == _state.clientID }
        if deny || !known || q["code_challenge_method"] != "S256" {
            items.append(URLQueryItem(name: "error", value: known ? "access_denied" : "invalid_client"))
        } else {
            let code = "4/fake-" + UUID().uuidString
            let asked = (q["scope"] ?? "").split(separator: " ").map(String.init)
            let scopes = lock.withLock { () -> [String] in
                let granted = asked.filter { _state.grantedScopes.contains($0) }
                _state.codes[code] = Code(challenge: q["code_challenge"] ?? "", redirect: redirect, scopes: granted)
                return granted
            }
            items.append(URLQueryItem(name: "code", value: code))
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        back.queryItems = items
        guard let target = back.url else { return }
        let session = URLSession(configuration: .ephemeral)   // real loopback socket, not intercepted
        _ = try? await session.data(from: target)
        session.finishTasksAndInvalidate()
    }

    /// Plays the user in Google Photos' picker: picks `count` photos (all by default) for that session.
    public static func pick(_ pickerURL: URL, count: Int? = nil) {
        let comps = pickerURL.pathComponents
        guard let i = comps.firstIndex(of: "picker"), comps.count > i + 1 else { return }
        let id = comps[i + 1]
        update { s in
            guard s.pickerSessions[id] != nil else { return }
            s.pickerSessions[id]?.items = s.pickerLibrary.prefix(count ?? s.pickerLibrary.count).map(\.id)
            s.pickerSessions[id]?.set = true
        }
    }

    // MARK: URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host ?? "") }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    enum Outcome {
        case reply(Int, [String: String], Data)
        case redirect(Int, String)
        case drop
    }

    override public func startLoading() { Self.serve(self, driveDemo: false) }

    /// Answers one request from `p`. `driveDemo` serves it from `DriveDemo`'s separate account instead of `state`.
    static func serve(_ p: URLProtocol, driveDemo: Bool) {
        let req = p.request
        let body = Self.body(req)
        let (outcome, latency) = Self.lock.withLock { () -> (Outcome, Double) in
            if driveDemo { DriveDemo.swapIn() }
            defer { if driveDemo { DriveDemo.swapIn() } }
            let o = Self.handle(req, body: body)
            return (o, Self._state.latency)
        }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        switch outcome {
        case .drop:
            p.client?.urlProtocol(p, didFailWithError: URLError(.networkConnectionLost))
        case .redirect(let status, let location):
            // Like a careless HTTP stack: the next request carries every header, the token included.
            var next = req
            next.url = URL(string: location)
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location, "Content-Length": "0"])!
            p.client?.urlProtocol(p, wasRedirectedTo: next, redirectResponse: resp)
            p.client?.urlProtocol(p, didReceive: resp, cacheStoragePolicy: .notAllowed)
            p.client?.urlProtocolDidFinishLoading(p)
        case .reply(let status, var headers, let data):
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json; charset=UTF-8" }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            p.client?.urlProtocol(p, didReceive: resp, cacheStoragePolicy: .notAllowed)
            p.client?.urlProtocol(p, didLoad: data)
            p.client?.urlProtocolDidFinishLoading(p)
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

    // MARK: Helpers

    static func json(_ status: Int, _ j: JSON, _ headers: [String: String] = [:]) -> Outcome { .reply(status, headers, j.data()) }
    static func error(_ status: Int, _ message: String, reason: String? = nil, statusText: String? = nil) -> Outcome {
        var e: [String: JSON] = ["code": .int(status), "message": .string(message)]
        if let r = reason { e["errors"] = [["domain": "global", "reason": .string(r), "message": .string(message)]] }
        if let s = statusText { e["status"] = .string(s) }
        return json(status, ["error": .object(e)])
    }
    /// Drive's md5Checksum: lowercase hex.
    static func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func newID(_ prefix: String) -> String { prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased() }
    static func form(_ d: Data) -> [String: String] {
        var out = [String: String]()
        for pair in (String(data: d, encoding: .utf8) ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
    static func query(_ u: URL) -> [String: String] {
        var q = [String: String]()
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return q
    }
    static let shortcutMime = "application/vnd.google-apps.shortcut"
    static let exportExts = ["docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                             "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                             "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation", "pdf": "application/pdf"]
    static func exportable(_ f: File) -> [String] {
        switch f.mimeType {
        case "application/vnd.google-apps.document": return [exportExts["docx"]!, exportExts["pdf"]!]
        case "application/vnd.google-apps.spreadsheet": return [exportExts["xlsx"]!, exportExts["pdf"]!]
        case "application/vnd.google-apps.presentation": return [exportExts["pptx"]!, exportExts["pdf"]!]
        case "application/vnd.google-apps.drawing", "application/vnd.google-apps.jam": return [exportExts["pdf"]!]
        case "application/vnd.google-apps.script": return ["application/vnd.google-apps.script+json"]
        default: return []
        }
    }
    static func exportBytes(_ f: File, _ mime: String) -> Data {
        var d = Data("FAKE-EXPORT \(mime) of \(f.name) [\(f.modifiedTime ?? "")]\n".utf8)
        d.append(Data(repeating: 0x20, count: 3000))
        return d
    }
    static func fileJSON(_ f: File) -> JSON {
        // appProperties are private to the OAuth client that wrote them.
        let mine = f.appClient == nil || f.appClient == requestClient
        // `trashed` is true inside a trashed folder too; `explicitlyTrashed` only for what was trashed itself.
        var o: [String: JSON] = ["kind": "drive#file", "id": .string(f.id), "name": .string(f.name), "mimeType": .string(f.mimeType),
                                 "parents": .array(f.parents.map { .string($0) }), "trashed": .bool(_state.isTrashed(f.id)),
                                 "explicitlyTrashed": .bool(f.trashed),
                                 "appProperties": .object(mine ? f.appProperties.mapValues { .string($0) } : [:]),
                                 "properties": .object((f.properties ?? [:]).mapValues { .string($0) }),
                                 "capabilities": ["canDownload": .bool(f.canDownload), "canRename": true, "canTrash": true],
                                 "hasThumbnail": .bool(f.hasThumbnail)]
        if let d = f.description { o["description"] = .string(d) }
        if f.mimeType != GoogleDrive.folderMime && !f.isNative { o["size"] = .string(String(f.size)) }
        if let m = f.md5 { o["md5Checksum"] = .string(m) }
        if let t = f.modifiedTime { o["modifiedTime"] = .string(t) }
        if let t = f.createdTime ?? f.modifiedTime { o["createdTime"] = .string(t) }
        if f.hasThumbnail { o["thumbnailLink"] = .string("https://lh3.googleusercontent.com/drive-storage/\(f.id)=s220") }
        if let t = f.shortcutTarget {
            o["shortcutDetails"] = ["targetId": .string(t), "targetMimeType": .string(_state.files[t]?.mimeType ?? "application/octet-stream")]
        }
        let ex = exportable(f)
        if !ex.isEmpty {
            o["exportLinks"] = .object(Dictionary(ex.map { ($0, JSON.string("https://docs.google.com/feeds/download/export?id=\(f.id)&mime=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)")) },
                                                  uniquingKeysWith: { a, _ in a }))
        }
        return .object(o)
    }

    static func bearer(_ r: URLRequest) -> (Date, [String], String)? {
        guard let h = r.value(forHTTPHeaderField: "Authorization"), h.hasPrefix("Bearer ") else { return nil }
        return _state.accessTokens[String(h.dropFirst(7))]
    }
    /// Bearer check: 401 for unknown or expired access tokens.
    static func authorized(_ r: URLRequest) -> Bool { (bearer(r)?.0).map { $0 > Date() } ?? false }
    /// Scopes travel with each access token, as they do at Google.
    static func has(_ scope: String, _ r: URLRequest) -> Bool { bearer(r)?.1.contains(scope) ?? false }
    static func insufficient() -> Outcome { error(403, "Request had insufficient authentication scopes.", reason: "insufficientPermissions", statusText: "PERMISSION_DENIED") }

    // MARK: Routing

    static func isDownload(_ method: String, _ url: URL) -> Bool {
        guard method == "GET" else { return false }
        let q = query(url)
        if url.host == "lh3.googleusercontent.com" || url.host == "docs.google.com" { return q["via"] == nil }
        return url.host == "www.googleapis.com" && q["via"] == nil && (q["alt"] == "media" || url.path.hasSuffix("/export"))
    }

    /// The second hop of a redirected download is served as if it were the original Google URL.
    static func unbounce(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let via = c.queryItems?.first(where: { $0.name == "via" })?.value else { return url }
        c.host = via
        return c.url ?? url
    }

    static func handle(_ r: URLRequest, body: Data) -> Outcome {
        guard let url = r.url, let host = url.host else { return error(400, "Bad request") }
        let method = r.httpMethod ?? "GET"
        _state.calls.append("\(method) \(host)\(url.path)")
        if host == "downloads.example.net" {
            _state.foreignRequests.append((host, r.value(forHTTPHeaderField: "Authorization") != nil))
            return .reply(200, ["Content-Type": "application/octet-stream"], Data("not Google".utf8))
        }
        if host == "oauth2.googleapis.com" { return oauth(url.path, body) }
        requestClient = bearer(r)?.2
        // First hop of a redirected download: bounce to the configured host with the same path and query.
        if let to = _state.redirectDownloadsTo, host != to, isDownload(method, url),
           var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.host = to
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "via", value: host)]
            if let u = c.url { return .redirect(302, u.absoluteString) }
        }
        guard authorized(r) else { return error(401, "Request had invalid authentication credentials.", reason: "authError", statusText: "UNAUTHENTICATED") }
        if _state.rateLimitNext > 0 {
            _state.rateLimitNext -= 1
            return .reply(429, ["Retry-After": "0"], (try? JSONSerialization.data(withJSONObject: ["error": ["code": 429, "message": "Rate Limit Exceeded",
                                                                                                             "errors": [["reason": "rateLimitExceeded"]]]])) ?? Data())
        }
        let out: Outcome
        let served = unbounce(url)
        if served != url { var again = r; again.url = served; return handle(again, body: body) }
        switch host {
        case "photoslibrary.googleapis.com":
            guard has(GoogleScopes.photosAppend, r) else { return insufficient() }
            if let left = _state.photosRequestsLeft {
                if left <= 0 {
                    return error(429, "Quota exceeded for quota metric 'All requests' and limit 'All requests per day' of service 'photoslibrary.googleapis.com'.",
                                 statusText: "RESOURCE_EXHAUSTED")
                }
                _state.photosRequestsLeft = left - 1
            }
            out = photos(method, url, r, body)
        case "photospicker.googleapis.com":
            guard has(GoogleScopes.photosPicker, r) else { return insufficient() }
            out = picker(method, url)
        case "lh3.googleusercontent.com" where url.path.hasPrefix("/drive-storage/"):
            return driveThumbnail(url, r)
        case "lh3.googleusercontent.com":
            guard has(GoogleScopes.photosPicker, r) else { return error(403, "Forbidden") }
            let last = url.lastPathComponent
            let id = last.components(separatedBy: "=").first ?? last
            guard let p = _state.pickerLibrary.first(where: { $0.id == id }) else { return error(404, "Not found") }
            return .reply(200, ["Content-Type": p.mime], p.data)
        case "docs.google.com":
            // exportLinks: works past files.export's 10 MB cap.
            guard has(GoogleScopes.driveReadonly, r) || has(GoogleScopes.drive, r) else { return error(403, "Forbidden") }
            let q = query(url)
            guard let id = q["id"], let f = _state.files[id], let mime = q["mime"], exportable(f).contains(mime) else { return error(404, "Not found") }
            _state.exportLinkUses += 1
            var d = exportBytes(f, mime)
            d.append(Data(repeating: 0x2E, count: 120_000))
            return .reply(200, ["Content-Type": mime], d)
        default:
            guard has(GoogleScopes.driveFile, r) || has(GoogleScopes.driveReadonly, r) || has(GoogleScopes.drive, r) else {
                return error(403, "Insufficient Permission: Request had insufficient authentication scopes.", reason: "insufficientPermissions")
            }
            out = drive(method, url, r, body)
        }
        if method != "GET" { persist() }
        return out
    }

    static func oauth(_ path: String, _ body: Data) -> Outcome {
        let f = form(body)
        func bad(_ e: String, _ d: String) -> Outcome { json(400, ["error": .string(e), "error_description": .string(d)]) }
        if path == "/revoke" {
            if let t = f["token"] { _state.refreshTokens[t] = nil; _state.accessTokens[t] = nil }
            persist()
            return .reply(200, [:], Data())
        }
        guard path == "/token" else { return bad("invalid_request", "Unknown endpoint") }
        guard f["client_id"] == _state.clientID else { return json(401, ["error": "invalid_client", "error_description": "The OAuth client was not found."]) }
        if let secret = _state.clientSecret {
            guard let given = f["client_secret"] else { return bad("invalid_request", "client_secret is missing.") }
            guard given == secret else { return json(401, ["error": "invalid_client", "error_description": "Unauthorized"]) }
        }
        let access = "ya29.fake-" + UUID().uuidString
        switch f["grant_type"] {
        case "authorization_code":
            guard let code = f["code"], let c = _state.codes.removeValue(forKey: code) else { return bad("invalid_grant", "Malformed auth code.") }
            guard f["redirect_uri"] == c.redirect else { return bad("redirect_uri_mismatch", "Bad Request") }
            guard let v = f["code_verifier"], v.count >= 43, v.count <= 128, PKCE(verifier: v).challenge == c.challenge else {
                return bad("invalid_grant", "Invalid code verifier.")
            }
            let refresh = "1//fake-refresh-" + UUID().uuidString
            _state.refreshTokens[refresh] = c.scopes
            _state.refreshClients[refresh] = f["client_id"] ?? ""
            _state.accessTokens[access] = (Date().addingTimeInterval(_state.accessTTL), c.scopes, f["client_id"] ?? "")
            persist()
            return json(200, ["access_token": .string(access), "expires_in": .number(_state.accessTTL), "refresh_token": .string(refresh),
                              "scope": .string(c.scopes.joined(separator: " ")), "token_type": "Bearer"])
        case "refresh_token":
            guard let t = f["refresh_token"], let scopes = _state.refreshTokens[t] else { return bad("invalid_grant", "Token has been expired or revoked.") }
            _state.refreshes += 1
            _state.accessTokens[access] = (Date().addingTimeInterval(_state.accessTTL), scopes, _state.refreshClients[t] ?? f["client_id"] ?? "")
            var reply: [String: JSON] = ["access_token": .string(access), "expires_in": .number(_state.accessTTL),
                                         "scope": .string(scopes.joined(separator: " ")), "token_type": "Bearer"]
            if _state.rotateRefreshTokens {
                let next = "1//fake-refresh-" + UUID().uuidString
                _state.refreshTokens[next] = scopes
                _state.refreshClients[next] = _state.refreshClients[t]
                _state.refreshTokens[t] = nil
                reply["refresh_token"] = .string(next)
                persist()
            }
            return json(200, .object(reply))
        default:
            return bad("unsupported_grant_type", "Invalid grant_type")
        }
    }

    // MARK: Drive

    static func resolve(_ id: String) -> String { id == "root" ? rootID : id }

    /// A folder new items may go into: drive.file only into folders Cirrus made; the full drive scope into any.
    static func folderOK(_ id: String, full: Bool = false) -> Bool {
        let id = resolve(id)
        return id == rootID || (_state.files[id].map { $0.mimeType == GoogleDrive.folderMime && ($0.byApp || full) && !_state.isTrashed($0.id) } ?? false)
    }

    // MARK: Drive search queries (`q`)

    enum QToken: Equatable { case string(String), word(String) }

    /// Splits a query into words and string literals. Inside quotes only \' and \\ are valid escapes;
    /// anything else (a stray quote, a lone backslash) makes the query invalid, as at Google.
    static func tokenize(_ s: String) -> [QToken]? {
        var out = [QToken]()
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == " " { i = s.index(after: i); continue }
            if c == "'" {
                var lit = ""
                var closed = false
                i = s.index(after: i)
                while i < s.endIndex {
                    let d = s[i]
                    if d == "\\" {
                        let n = s.index(after: i)
                        guard n < s.endIndex, s[n] == "'" || s[n] == "\\" else { return nil }
                        lit.append(s[n])
                        i = s.index(after: n)
                        continue
                    }
                    i = s.index(after: i)
                    if d == "'" { closed = true; break }
                    lit.append(d)
                }
                guard closed else { return nil }
                out.append(.string(lit))
                continue
            }
            if c == "=" { out.append(.word("=")); i = s.index(after: i); continue }
            if c == "!" {
                let n = s.index(after: i)
                guard n < s.endIndex, s[n] == "=" else { return nil }
                out.append(.word("!="))
                i = s.index(after: n)
                continue
            }
            var w = ""
            while i < s.endIndex, !" =!'".contains(s[i]) { w.append(s[i]); i = s.index(after: i) }
            out.append(.word(w))
        }
        return out
    }

    /// The `q` subset Cirrus uses, joined with `and`: `'<id>' in parents`, `trashed = true|false`,
    /// `name = | != | contains '<text>'`, `mimeType = | != '<type>'`. nil = invalid (Google answers 400).
    static func filter(_ qs: String) -> ((File) -> Bool)? {
        guard let toks = tokenize(qs) else { return nil }
        var clauses = [[QToken]]()
        var cur = [QToken]()
        for t in toks {
            if t == .word("and") { clauses.append(cur); cur = [] } else { cur.append(t) }
        }
        clauses.append(cur)
        if toks.isEmpty { return { _ in true } }
        var preds = [(File) -> Bool]()
        for c in clauses {
            guard c.count == 3 else { return nil }
            switch (c[0], c[1], c[2]) {
            case (.string(let id), .word("in"), .word("parents")):
                let p = resolve(id)
                preds.append { $0.parents.contains(p) }
            case (.word("trashed"), .word(let op), .word(let v)) where ["=", "!="].contains(op) && ["true", "false"].contains(v):
                let want = (v == "true") == (op == "=")
                preds.append { _state.isTrashed($0.id) == want }
            case (.word("name"), .word("="), .string(let n)): preds.append { $0.name == n }
            case (.word("name"), .word("!="), .string(let n)): preds.append { $0.name != n }
            case (.word("name"), .word("contains"), .string(let n)): preds.append { $0.name.localizedCaseInsensitiveContains(n) }
            case (.word("mimeType"), .word("="), .string(let m)): preds.append { $0.mimeType == m }
            case (.word("mimeType"), .word("!="), .string(let m)): preds.append { $0.mimeType != m }
            default: return nil
            }
        }
        return { f in preds.allSatisfy { $0(f) } }
    }

    /// Removes a file or folder and everything inside it (files.delete on a folder).
    static func deleteTree(_ id: String) {
        let doomed = _state.files.keys.filter { _state.isInside($0, id) }
        for d in doomed {
            if let f = _state.files[d], f.mimeType != GoogleDrive.folderMime, !f.isNative { _state.usage = max(0, _state.usage - f.size) }
            _state.files[d] = nil
            _state.blobs[d] = nil
        }
    }

    /// `thumbnailLink` targets: https://lh3.googleusercontent.com/drive-storage/<id>=s<px>
    static func driveThumbnail(_ url: URL, _ r: URLRequest) -> Outcome {
        let full = has(GoogleScopes.drive, r) || has(GoogleScopes.driveReadonly, r)
        guard full || has(GoogleScopes.driveFile, r) else { return error(403, "Forbidden") }
        let parts = url.lastPathComponent.components(separatedBy: "=")
        let size = parts.count > 1 && parts[1].hasPrefix("s") ? Int(parts[1].dropFirst()) ?? 220 : 220
        guard let f = _state.files[parts[0]], f.byApp || full, f.hasThumbnail else { return error(404, "Not found") }
        _state.thumbnailSizes.append(size)
        if f.mimeType.hasPrefix("image/"), let d = _state.blobs[f.id], !d.isEmpty { return .reply(200, ["Content-Type": f.mimeType], d) }
        let side = max(16, min(size, 1600))
        let hue = CGFloat(abs(f.id.hashValue % 100)) / 100
        let d = DemoArt.jpeg(width: side, height: side * 3 / 4, hue: hue, label: (f.name as NSString).deletingPathExtension) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        return .reply(200, ["Content-Type": "image/jpeg"], d)
    }

    static func drive(_ method: String, _ url: URL, _ r: URLRequest, _ body: Data) -> Outcome {
        let path = url.path
        let q = query(url)
        // drive.file: only what Cirrus created. drive.readonly: read everything. drive: read and change everything.
        let full = has(GoogleScopes.drive, r)
        let readAll = has(GoogleScopes.driveReadonly, r) || full
        let canWrite = has(GoogleScopes.driveFile, r) || full
        func visible(_ f: File) -> Bool { f.byApp || readAll }
        func editable(_ f: File) -> Bool { canWrite && (f.byApp || full) }
        if path == "/drive/v3/about" {
            guard q["fields"] != nil else { return error(400, "The 'fields' parameter is required for this method.", reason: "required") }
            var quota: [String: JSON] = ["usage": .string(String(_state.usage)),
                                         "usageInDrive": .string(String(_state.files.values.reduce(0) { $0 + $1.size })), "usageInDriveTrash": "0"]
            if let l = _state.limit { quota["limit"] = .string(String(l)) }
            return json(200, ["user": ["permissionId": .string(_state.userID), "emailAddress": .string(_state.email), "displayName": .string(_state.name)],
                              "storageQuota": .object(quota)])
        }
        if path == "/drive/v3/files" && method == "GET" {
            guard let matches = filter(q["q"] ?? "") else { return error(400, "Invalid Value", reason: "invalid") }
            var list = _state.files.values.filter(visible).filter(matches)   // drive.file: only what Cirrus created
            list.sort { $0.id < $1.id }
            let size = Int(q["pageSize"] ?? "") ?? 100
            let start = Int(q["pageToken"] ?? "") ?? 0
            let page = Array(list.dropFirst(start).prefix(min(size, 1000)))
            var out: [String: JSON] = ["files": .array(page.map(fileJSON))]
            if start + page.count < list.count { out["nextPageToken"] = .string(String(start + page.count)) }
            return json(200, .object(out))
        }
        if path == "/drive/v3/files" && method == "POST" {
            guard canWrite else { return insufficient() }
            let j = (try? JSON(data: body)) ?? .null
            let parents = j["parents"].array.compactMap(\.string).map(resolve)
            guard parents.count == 1, folderOK(parents[0], full: full) else { return error(404, "File not found: parent.", reason: "notFound") }
            var f = File(id: newID("f"), name: j["name"].string ?? "Untitled", mimeType: j["mimeType"].string ?? "application/octet-stream", parents: parents,
                         size: 0, md5: nil, modifiedTime: j["modifiedTime"].string ?? GoogleDrive.iso(Date()), trashed: false,
                         appProperties: j["appProperties"].object.compactMapValues(\.string), byApp: true)
            f.properties = j["properties"].object.compactMapValues(\.string)
            f.description = j["description"].string
            f.appClient = requestClient
            f.createdTime = GoogleDrive.iso(Date())
            _state.files[f.id] = f
            return json(200, fileJSON(f))
        }
        if (path == "/drive/v3/files/root" || path == "/drive/v3/files/" + rootID) && method == "GET" {
            return json(200, ["id": .string(rootID), "name": "My Drive", "mimeType": .string(GoogleDrive.folderMime), "trashed": false,
                              "parents": [], "capabilities": ["canDownload": true, "canRename": false, "canTrash": false]])
        }
        if path.hasPrefix("/drive/v3/files/") && path.hasSuffix("/export") && method == "GET" {
            let id = String(path.dropFirst("/drive/v3/files/".count).dropLast("/export".count))
            guard let f = _state.files[id], visible(f) else { return error(404, "File not found: \(id).", reason: "notFound") }
            guard let mime = q["mimeType"], exportable(f).contains(mime) else { return error(403, "Export only supports Docs Editors files.", reason: "fileNotExportable") }
            if f.exportTooLarge { return error(400, "This file is too large to be exported.", reason: "badRequest") }
            return .reply(200, ["Content-Type": mime], exportBytes(f, mime))
        }
        if path.hasPrefix("/drive/v3/files/") {
            let id = resolve(String(path.dropFirst("/drive/v3/files/".count)))
            guard var f = _state.files[id], visible(f) else { return error(404, "File not found: \(id).", reason: "notFound") }
            switch method {
            case "GET":
                guard q["alt"] == "media" else { return json(200, fileJSON(f)) }
                if f.isNative { return error(403, "Only files with binary content can be downloaded. Use Export with Docs Editors files.", reason: "fileNotDownloadable") }
                if !f.canDownload { return error(403, "The user doesn't have permission to download this file.", reason: "cannotDownloadFile") }
                let data = _state.blobs[id] ?? Data(count: Int(f.size))
                guard let range = r.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else { return .reply(200, ["Content-Type": f.mimeType], data) }
                _state.rangedGets += 1
                if _state.dropDownloadAt == _state.rangedGets { return .drop }
                let ab = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard let a = ab.first, a < data.count else { return error(416, "Requested range not satisfiable") }
                let b = min(ab.count > 1 ? ab[1] : data.count - 1, data.count - 1)
                return .reply(206, ["Content-Type": f.mimeType, "Content-Range": "bytes \(a)-\(b)/\(data.count)"], data.subdata(in: a..<(b + 1)))
            case "PATCH":
                guard editable(f) else { return insufficient() }
                let j = (try? JSON(data: body)) ?? .null
                if q["addParents"] != nil || q["removeParents"] != nil {
                    // Moving: parents not listed in removeParents stay; a file may have only one parent.
                    var parents = f.parents
                    for p in (q["removeParents"] ?? "").split(separator: ",").map({ resolve(String($0)) }) { parents.removeAll { $0 == p } }
                    for p in (q["addParents"] ?? "").split(separator: ",").map({ resolve(String($0)) }) {
                        guard folderOK(p, full: full) else { return error(404, "File not found: \(p).", reason: "notFound") }
                        if f.mimeType == GoogleDrive.folderMime && _state.isInside(p, id) {
                            return error(403, "A folder can’t be moved into itself or one of its subfolders.", reason: "invalidParent")
                        }
                        if !parents.contains(p) { parents.append(p) }
                    }
                    guard parents.count <= 1 else {
                        return error(403, "Increasing the number of parents is not allowed.", reason: "cannotAddParent")
                    }
                    f.parents = parents
                }
                if let t = j["trashed"].bool { f.trashed = t }
                if let n = j["name"].string { f.name = n }
                if case .object(let props) = j["properties"] { f.properties = (f.properties ?? [:]).merging(props.compactMapValues(\.string)) { $1 } }
                if let d = j["description"].string { f.description = d }
                _state.files[id] = f
                return json(200, fileJSON(f))
            case "DELETE":
                guard editable(f) else { return insufficient() }
                _state.permanentDeletes += 1
                deleteTree(id)
                return .reply(204, [:], Data())
            default: return error(405, "Method not allowed")
            }
        }
        if path == "/upload/drive/v3/files" {
            guard canWrite else { return insufficient() }
            if method == "POST" && q["uploadType"] == "resumable" {
                let meta = (try? JSON(data: body)) ?? .null
                let parents = meta["parents"].array.compactMap(\.string).map(resolve)
                guard parents.count == 1, folderOK(parents[0], full: full) else { return error(404, "File not found: parent.", reason: "notFound") }
                guard let total = r.value(forHTTPHeaderField: "X-Upload-Content-Length").flatMap({ Int64($0) }) else {
                    return error(400, "Cirrus always sends X-Upload-Content-Length", reason: "badRequest")
                }
                if let l = _state.limit, _state.usage + total > l {
                    return error(403, "The user's Drive storage quota has been exceeded.", reason: "storageQuotaExceeded")
                }
                let sid = newID("u")
                var m = meta
                if case .object(var o) = m { o["parents"] = .array(parents.map { .string($0) }); m = .object(o) }
                _state.driveSessions[sid] = DriveSession(meta: m, total: total, client: requestClient, keepData: full)
                _state.driveSessionsStarted += 1
                return .reply(200, ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(sid)"], Data())
            }
            if method == "PUT", let sid = q["upload_id"] {
                return driveChunk(sid, r, body)
            }
        }
        return error(404, "Not found: \(method) \(path)")
    }

    static func rangeHeader(_ n: Int) -> [String: String] { n > 0 ? ["Range": "bytes=0-\(n - 1)"] : [:] }

    static func driveChunk(_ sid: String, _ r: URLRequest, _ body: Data) -> Outcome {
        guard var s = _state.driveSessions[sid] else { return error(404, "Upload session not found", reason: "notFound") }
        let cr = r.value(forHTTPHeaderField: "Content-Range") ?? ""
        func finish() -> Outcome {
            if let id = s.fileID, let f = _state.files[id] { return json(200, fileJSON(f)) }
            let meta = s.meta
            let name = meta["name"].string ?? "Untitled"
            var f = File(id: newID("f"), name: name, mimeType: r.value(forHTTPHeaderField: "X-Upload-Content-Type") ?? GoogleDrive.mimeType(for: name),
                         parents: meta["parents"].array.compactMap(\.string), size: s.total, md5: md5(s.data),
                         modifiedTime: meta["modifiedTime"].string ?? GoogleDrive.iso(Date()), trashed: false,
                         appProperties: meta["appProperties"].object.compactMapValues(\.string), byApp: true)
            f.properties = meta["properties"].object.compactMapValues(\.string)
            f.appClient = s.client
            f.createdTime = GoogleDrive.iso(Date())
            _state.files[f.id] = f
            _state.usage += s.total
            // Kept only for full-drive-scope uploads (Google Drive accounts read them back); the move's uploads
            // are never downloaded, and the migration demo's saved state stays small.
            if s.keepData { _state.blobs[f.id] = s.data }
            s.fileID = f.id
            s.data = Data()
            _state.driveSessions[sid] = s
            return json(200, fileJSON(f))
        }
        if cr.hasPrefix("bytes */") {
            _state.statusQueries += 1
            if s.fileID != nil || (s.total == 0 && cr == "bytes */0") { return finish() }
            return .reply(308, rangeHeader(s.data.count), Data())
        }
        // bytes a-b/total
        let spec = cr.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/")
        let ab = parts.first?.split(separator: "-").compactMap { Int64($0) } ?? []
        guard parts.count == 2, ab.count == 2, Int64(parts[1]) == s.total else { return error(400, "Invalid Content-Range: \(cr)", reason: "badContent") }
        let (a, b) = (ab[0], ab[1])
        guard Int64(body.count) == b - a + 1 else { return error(400, "Content-Range doesn’t match the body length", reason: "badContent") }
        if b + 1 < s.total && (b - a + 1) % 262_144 != 0 { return error(400, "Chunk size must be a multiple of 256 KiB", reason: "badContent") }
        _state.chunkPuts += 1
        let n = _state.chunkPuts
        if let after = _state.failDriveChunksAfter, n > after { return error(503, "Backend Error", reason: "backendError") }
        guard a <= Int64(s.data.count) else { return .reply(308, rangeHeader(s.data.count), Data()) }
        var chunk = body.subdata(in: Int(Int64(s.data.count) - a)..<body.count)
        if _state.dropDriveChunk == n {
            // Only part of the chunk arrived before the connection broke.
            let keep = (chunk.count / 2 / 262_144) * 262_144
            chunk = chunk.prefix(keep)
            s.data.append(chunk)
            _state.driveSessions[sid] = s
            return .drop
        }
        s.data.append(chunk)
        _state.driveSessions[sid] = s
        if Int64(s.data.count) >= s.total { return finish() }
        return .reply(308, rangeHeader(s.data.count), Data())
    }

    // MARK: Photos Picker

    static func pickerSessionJSON(_ id: String, _ s: PickerSession) -> JSON {
        var o: [String: JSON] = ["id": .string(id), "pickerUri": .string("https://photos.google.com/picker/\(id)"), "mediaItemsSet": .bool(s.set),
                                 "expireTime": .string(GoogleDrive.iso(Date().addingTimeInterval(3600)))]
        if !s.set { o["pollingConfig"] = ["pollInterval": "0.05s", "timeoutIn": "120s"] }
        return .object(o)
    }

    static func picker(_ method: String, _ url: URL) -> Outcome {
        let path = url.path
        if path == "/v1/sessions" && method == "POST" {
            let id = newID("ps")
            _state.pickerSessions[id] = PickerSession()
            return json(200, pickerSessionJSON(id, PickerSession()))
        }
        if path.hasPrefix("/v1/sessions/") {
            let id = String(path.dropFirst("/v1/sessions/".count))
            guard let s = _state.pickerSessions[id] else { return error(404, "Session not found", statusText: "NOT_FOUND") }
            if method == "DELETE" { _state.pickerSessions[id] = nil; _state.pickerSessionsDeleted += 1; return json(200, [:]) }
            return json(200, pickerSessionJSON(id, s))
        }
        if path == "/v1/mediaItems" && method == "GET" {
            let q = query(url)
            guard let sid = q["sessionId"], let s = _state.pickerSessions[sid] else { return error(400, "Missing session", statusText: "INVALID_ARGUMENT") }
            guard s.set else { return error(400, "The user hasn’t picked yet.", statusText: "FAILED_PRECONDITION") }
            let size = Int(q["pageSize"] ?? "") ?? 50
            guard size <= 100 else { return error(400, "pageSize must be at most 100", statusText: "INVALID_ARGUMENT") }
            let start = Int(q["pageToken"] ?? "") ?? 0
            let picked = s.items.compactMap { id in _state.pickerLibrary.first { $0.id == id } }
            let page = picked.dropFirst(start).prefix(size)
            var out: [String: JSON] = ["mediaItems": .array(page.map { p in
                ["id": .string(p.id), "createTime": .string(GoogleDrive.iso(p.created)), "type": .string(p.isVideo ? "VIDEO" : "PHOTO"),
                 "mediaFile": ["baseUrl": .string("https://lh3.googleusercontent.com/fake/\(p.id)"), "mimeType": .string(p.mime), "filename": .string(p.fileName),
                               "mediaFileMetadata": p.isVideo ? ["videoMetadata": ["processingStatus": "READY"]] : ["width": 900, "height": 600]]]
            })]
            if start + page.count < picked.count { out["nextPageToken"] = .string(String(start + page.count)) }
            return json(200, .object(out))
        }
        return error(404, "Not found: \(method) \(path)", statusText: "NOT_FOUND")
    }

    // MARK: Photos Library

    static func photos(_ method: String, _ url: URL, _ r: URLRequest, _ body: Data) -> Outcome {
        let path = url.path
        let q = query(url)
        func text(_ status: Int, _ s: String, _ h: [String: String] = [:]) -> Outcome {
            var hh = h; hh["Content-Type"] = "text/plain"
            return .reply(status, hh, Data(s.utf8))
        }
        if path == "/v1/uploads" && method == "POST" {
            if let sid = q["upload_id"] { return photoChunk(sid, r, body) }
            let proto = r.value(forHTTPHeaderField: "X-Goog-Upload-Protocol")
            if proto == "raw" {
                guard r.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" else { return error(400, "Expected application/octet-stream") }
                guard !body.isEmpty else { return error(400, "Empty upload") }
                let token = "upl-" + UUID().uuidString
                _state.uploadTokens[token] = Blob(md5: md5(body), size: Int64(body.count))
                return text(200, token)
            }
            if proto == "resumable", r.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "start" {
                guard let size = r.value(forHTTPHeaderField: "X-Goog-Upload-Raw-Size").flatMap({ Int64($0) }) else { return error(400, "Missing X-Goog-Upload-Raw-Size") }
                let sid = newID("p")
                _state.photoSessions[sid] = PhotoSession(total: size)
                _state.photoSessionsStarted += 1
                return text(200, "", ["X-Goog-Upload-URL": "https://photoslibrary.googleapis.com/v1/uploads?upload_id=\(sid)&upload_protocol=resumable",
                                      "X-Goog-Upload-Chunk-Granularity": "262144", "X-Goog-Upload-Status": "active"])
            }
            return error(400, "Unsupported upload protocol")
        }
        if path == "/v1/mediaItems:batchCreate" && method == "POST" {
            let j = (try? JSON(data: body)) ?? .null
            let items = j["newMediaItems"].array
            guard !items.isEmpty, items.count <= 50 else { return error(400, "Request must contain between 1 and 50 media items.", statusText: "INVALID_ARGUMENT") }
            if let a = j["albumId"].string, _state.albums[a] == nil { return error(400, "Invalid album ID.", statusText: "INVALID_ARGUMENT") }
            _state.batchCreateSizes.append(items.count)
            var results = [JSON]()
            var allOK = true
            for i in items {
                let token = i["simpleMediaItem"]["uploadToken"].string ?? ""
                let name = i["simpleMediaItem"]["fileName"].string ?? "file"
                guard let blob = _state.uploadTokens[token], !_state.rejectFileNames.contains(name) else {
                    allOK = false
                    results.append(["uploadToken": .string(token), "status": ["code": 3, "message": "Failed: There was an error while trying to create this media item."]])
                    continue
                }
                // The same bytes are one media item, whatever token refers to them.
                let id: String
                if let existing = _state.mediaByHash[blob.md5] { id = existing } else {
                    id = newID("m")
                    _state.media[id] = MediaItem(id: id, fileName: name, description: i["description"].string, size: blob.size, md5: blob.md5)
                    _state.mediaByHash[blob.md5] = id
                    _state.usage += blob.size
                }
                if let a = j["albumId"].string { _state.albums[a]?.items.append(id) }
                results.append(["uploadToken": .string(token), "status": ["message": "Success"],
                                "mediaItem": ["id": .string(id), "filename": .string(name)]])
            }
            return json(allOK ? 200 : 207, ["newMediaItemResults": .array(results)])
        }
        if path == "/v1/albums" && method == "POST" {
            let j = (try? JSON(data: body)) ?? .null
            guard let title = j["album"]["title"].string, !title.isEmpty, title.count <= 500 else { return error(400, "Invalid album title", statusText: "INVALID_ARGUMENT") }
            let id = newID("a")
            _state.albums[id] = Album(id: id, title: title, items: [])
            return json(200, ["id": .string(id), "title": .string(title), "isWriteable": true, "productUrl": .string("https://photos.google.com/lr/album/\(id)")])
        }
        if path.hasPrefix("/v1/albums/") && path.hasSuffix(":batchAddMediaItems") && method == "POST" {
            let id = String(path.dropFirst("/v1/albums/".count).dropLast(":batchAddMediaItems".count))
            guard var album = _state.albums[id] else { return error(400, "Invalid album ID.", statusText: "INVALID_ARGUMENT") }
            let ids = ((try? JSON(data: body)) ?? .null)["mediaItemIds"].array.compactMap(\.string)
            guard !ids.isEmpty, ids.count <= 50 else { return error(400, "Request must contain between 1 and 50 media items.", statusText: "INVALID_ARGUMENT") }
            guard ids.allSatisfy({ _state.media[$0] != nil }) else { return error(400, "Request contains an invalid media item id.", statusText: "INVALID_ARGUMENT") }
            guard album.items.count + ids.count <= GooglePhotos.albumLimit else { return error(400, "Album is full", statusText: "INVALID_ARGUMENT") }
            for i in ids where !album.items.contains(i) { album.items.append(i) }
            _state.albums[id] = album
            _state.albumAddSizes.append(ids.count)
            return json(200, [:])
        }
        return error(404, "Not found: \(method) \(path)", statusText: "NOT_FOUND")
    }

    static func photoChunk(_ sid: String, _ r: URLRequest, _ body: Data) -> Outcome {
        guard var s = _state.photoSessions[sid] else { return error(404, "Upload session not found", statusText: "NOT_FOUND") }
        let cmd = (r.value(forHTTPHeaderField: "X-Goog-Upload-Command") ?? "").replacingOccurrences(of: " ", with: "")
        func status(_ code: Int, _ extra: [String: String] = [:], _ d: Data = Data()) -> Outcome {
            var h = extra
            h["X-Goog-Upload-Status"] = s.token == nil ? "active" : "final"
            h["X-Goog-Upload-Size-Received"] = String(s.data.count)
            h["Content-Type"] = "text/plain"
            return .reply(code, h, d)
        }
        if cmd == "query" { return status(200, [:], Data((s.token ?? "").utf8)) }
        guard cmd == "upload" || cmd == "upload,finalize" else { return error(400, "Unknown upload command") }
        guard s.token == nil else { return error(400, "Upload already finalized") }
        guard let offset = r.value(forHTTPHeaderField: "X-Goog-Upload-Offset").flatMap({ Int64($0) }), offset == Int64(s.data.count) else {
            return error(400, "Offset doesn’t match what was received", statusText: "INVALID_ARGUMENT")
        }
        let finalize = cmd == "upload,finalize"
        if !finalize && body.count % 262_144 != 0 { return error(400, "Chunk isn’t a multiple of the granularity", statusText: "INVALID_ARGUMENT") }
        _state.chunkPuts += 1
        if _state.dropPhotoChunk == _state.chunkPuts {
            s.data.append(body.prefix((body.count / 2 / 262_144) * 262_144))
            _state.photoSessions[sid] = s
            return .drop
        }
        s.data.append(body)
        if finalize {
            guard Int64(s.data.count) == s.total else { return error(400, "Size doesn’t match X-Goog-Upload-Raw-Size", statusText: "INVALID_ARGUMENT") }
            let token = "upl-" + UUID().uuidString
            _state.uploadTokens[token] = Blob(md5: md5(s.data), size: s.total)
            s.token = token
            s.data = Data()
            _state.photoSessions[sid] = s
            return status(200, [:], Data(token.utf8))
        }
        _state.photoSessions[sid] = s
        return status(200)
    }
}

extension FakeGoogleServer {
    /// A second, independent fake Google account for Google Drive browsing (demo mode's "Google Drive"
    /// account). Same wire protocol, its own files and tokens, so neither the migration demo
    /// (`startDemo`) nor tests that reset `FakeGoogleServer.state` disturb it. Use `[DriveDemo.self]` as the transport.
    public final class DriveDemo: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var other = State()
        nonisolated(unsafe) static var otherPersistURL: URL?
        nonisolated(unsafe) static var started = false
        /// The demo account's long-lived sign-in (the fake knows it; no browser round trip).
        public static let refreshToken = "1//fake-drive-demo-refresh"

        public static var state: State {
            get { FakeGoogleServer.lock.withLock { other } }
            set { FakeGoogleServer.lock.withLock { other = newValue } }
        }
        public static func update(_ f: (inout State) -> Void) { FakeGoogleServer.lock.withLock { f(&other) } }

        /// Swaps the demo account in for `FakeGoogleServer`'s own (and back again). Call under the lock.
        static func swapIn() {
            swap(&FakeGoogleServer._state, &other)
            swap(&FakeGoogleServer.persistURL, &otherPersistURL)
        }

        /// Seeds the demo account once per run (folders, a Doc, a Sheet, pictures, a PDF, a shortcut, a Form and
        /// something in the trash) and returns it. With `storage`, changes are kept across launches.
        @discardableResult
        public static func start(storage dir: URL?, latency: Double = 0.02) -> State {
            FakeGoogleServer.lock.withLock {
                if started { return other }
                started = true
                var s = State()
                s.latency = latency
                s.userID = "demo-drive-user"
                s.email = "alex@example.com"
                s.name = "Alex Morgan"
                s.usage = 3_400_000_000
                s.grantedScopes = [GoogleScopes.drive]
                var url: URL?
                if let dir {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    url = dir.appendingPathComponent("google-drive-demo-v1.json")
                    if let u = url, let d = try? Data(contentsOf: u), let saved = try? JSONDecoder().decode(Saved.self, from: d) { saved.restore(into: &s) }
                }
                if s.files.isEmpty { seed(&s) }
                s.refreshTokens[refreshToken] = [GoogleScopes.drive]
                s.refreshClients[refreshToken] = s.clientID
                other = s
                otherPersistURL = url
                return s
            }
        }

        static func seed(_ s: inout State) {
            func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_760_000_000 + n * 86_400) }
            let documents = s.addUserFolder("Documents")
            let photos = s.addUserFolder("Photos")
            let projects = s.addUserFolder("Projects")
            let website = s.addUserFolder("Website refresh", parent: projects)
            s.addUserFile("Welcome.txt", data: Data("Welcome to the Google Drive demo.\nEverything here lives in a pretend account.\n".utf8), modified: day(1))
            s.addUserDoc("Project plan", parent: projects, modified: day(12))
            let budget = s.addUserDoc("Budget 2026", kind: "spreadsheet", parent: documents, modified: day(20))
            s.addUserFile("Quarterly report.pdf", parent: documents,
                          data: DemoArt.pdf(title: "Quarterly Report", lines: ["Revenue up 12%", "Two new regions", "Hiring plan"], hue: 0.36), modified: day(18))
            for (i, name) in ["Harbor at dawn", "Mountain trail", "City lights"].enumerated() {
                let jpg = DemoArt.scenic(width: 960, height: 640, seed: i + 7) ?? DemoArt.jpeg(width: 960, height: 640, hue: 0.1 * CGFloat(i), label: name) ?? Data()
                s.addUserFile(name + ".jpg", parent: photos, data: jpg, modified: day(Double(5 + i)))
            }
            s.addUserFile("Notes.md", parent: website, data: Data("# Website refresh\n- New colors\n- Faster pages\n".utf8), modified: day(22))
            s.addUserShortcut("Photos", to: photos, parent: website, modified: day(23))
            s.addUserShortcut("Budget 2026", to: budget, parent: projects, modified: day(21))
            s.addUserDoc("Team survey", kind: "form", modified: day(15))
            let old = s.addUserFile("Old draft.txt", data: Data("An earlier draft.\n".utf8), modified: day(2))
            s.files[old]?.trashed = true
            for (id, var f) in s.files {
                if f.modifiedTime == nil { f.modifiedTime = GoogleDrive.iso(day(0)) }
                f.createdTime = f.modifiedTime
                s.files[id] = f
            }
        }

        override public class func canInit(with request: URLRequest) -> Bool { FakeGoogleServer.hosts.contains(request.url?.host ?? "") }
        override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override public func startLoading() { FakeGoogleServer.serve(self, driveDemo: true) }
        override public func stopLoading() {}
    }
}
#endif
