#if DEBUG
import CoreGraphics
import Foundation

/// A stateful stand-in for Microsoft's identity platform and Microsoft Graph's OneDrive endpoints, served
/// through URLProtocol. Unit tests use it as the server; Debug builds in demo mode use it so OneDrive can be
/// browsed without an account. It is strict where real clients go wrong: PKCE at the token endpoint, the
/// loopback redirect form, refresh-token rotation (the old one stops working), access-token expiry, small
/// listing pages, 302 downloads to a separate host that refuses Authorization headers, upload sessions that
/// insist on 320 KiB fragments, contiguous ranges and the declared size, conflictBehavior, OneDrive's naming
/// rules, a recycle bin behind DELETE, thumbnails, quota and /me. Not compiled into release builds.
public final class FakeGraphServer: URLProtocol, @unchecked Sendable {
    public static let graphHost = "graph.microsoft.com"
    public static let loginHost = "login.microsoftonline.com"
    /// Pre-authenticated download, thumbnail and upload-session URLs live here.
    public static let contentHost = "content.onedrive.example"
    public static let hosts: Set<String> = [graphHost, loginHost, contentHost]
    public static let fragmentUnit = 327_680
    public static let simpleUploadLimit = 4 * 1024 * 1024
    /// The drive behind the shared folder that `addSharedFolder` puts in the user's root.
    public static let sharedDriveID = "f0e1d2c3b4a59687"
    public static let seedDate = Date(timeIntervalSince1970: 1_788_000_000)

    public struct Item: Sendable {
        public var id: String
        public var drive: String
        public var name: String
        public var parent: String?
        public var isFolder: Bool
        public var package: String?
        public var mime: String?
        public var created: Date
        public var modified: Date
        public var fsCreated: Date
        public var fsModified: Date
        public var version = 1
        public var deleted = false
        /// A shortcut to an item in another drive ("Add to My files").
        public var remoteDrive: String?
        public var remoteID: String?
        public var hasThumbnail = false
    }

    struct UploadSession: Sendable {
        var parent: String
        var name: String
        var total: Int64?
        var data = Data()
        var behavior: String
        var fsModified: Date?
        var expires: Date
    }
    struct Code: Sendable { var challenge: String; var redirect: String; var scope: String }
    struct Link: Sendable { var item: String; var thumbnail: Bool }

    /// Everything the server knows. Tests read and tweak it between steps.
    public struct State: Sendable {
        public var clientID = "11111111-2222-4333-8444-555555555555"
        public var displayName = "Alex Morgan"
        public var mail: String? = "alex@example.com"
        public var userPrincipalName = "alex@example.com"
        public var userID = "a1b2c3d4e5f60708"
        public let driveID = "a1b2c3d4e5f60708"
        /// False: a work account without a OneDrive (GET /me/drive → 404).
        public var hasDrive = true
        public var total: Int64 = 5_368_709_120
        public var accessTTL: Double = 3600
        /// Listing page size cap (small, so clients must follow @odata.nextLink).
        public var pageSize = 3
        /// False: only the named thumbnail sizes (small, medium, large…) are offered.
        public var customThumbnails = true
        public var latency: Double = 0
        public var items: [String: Item] = [:]
        public var blobs: [String: Data] = [:]
        public private(set) var rootID = ""
        var counter = 100
        var roots: [String: String] = [:]
        var codes: [String: Code] = [:]
        var refreshTokens: [String: String] = [:]
        var accessTokens: [String: Date] = [:]
        var sessions: [String: UploadSession] = [:]
        var links: [String: Link] = [:]
        var isDemo = false
        // Statistics for tests
        public var calls: [String] = []
        public var refreshes = 0
        /// Parameter names of each token request (never the values).
        public var tokenRequestKeys: [Set<String>] = []
        /// Requests to the pre-authenticated host and whether they carried an Authorization header.
        public var contentRequests: [(path: String, hadAuth: Bool)] = []
        public var authLeaks = 0
        public var simpleUploads = 0
        public var sessionsCreated = 0
        public var sessionsCancelled = 0
        public var sessionStatusQueries = 0
        public var chunkSizes: [Int] = []
        public var lastSessionItem: JSON = .null
        public var thumbnailSizes: [String] = []
        public var patches: [JSON] = []
        var chunkPuts = 0
        // Fault injection
        /// The Nth upload-session fragment (1-based, all sessions) arrives partly, then the connection drops.
        public var dropChunk: Int?
        /// The next N Graph API calls get 429 with Retry-After: 0.
        public var throttleNext = 0
        /// The next N pre-authenticated downloads lose their connection.
        public var dropDownloadsNext = 0
        /// The next N finished uploads (simple PUT or last fragment) are stored, but the answer is lost.
        public var loseUploadAnswers = 0

        public init() { rootID = makeRoot(driveID) }

        // MARK: Seeding

        mutating func newID(_ drive: String) -> String {
            counter += 1
            return drive.uppercased() + "!" + String(counter)
        }

        mutating func makeRoot(_ drive: String) -> String {
            let id = newID(drive)
            items[id] = Item(id: id, drive: drive, name: "root", parent: nil, isFolder: true, package: nil, mime: nil,
                             created: FakeGraphServer.seedDate, modified: FakeGraphServer.seedDate,
                             fsCreated: FakeGraphServer.seedDate, fsModified: FakeGraphServer.seedDate)
            roots[drive] = id
            return id
        }

        @discardableResult
        mutating func add(_ name: String, parent: String, folder: Bool, data: Data? = nil, at date: Date, fsModified: Date? = nil,
                          package: String? = nil) -> String {
            let drive = items[parent]?.drive ?? driveID
            let id = newID(drive)
            let mime = folder || package != nil ? nil : GoogleDrive.mimeType(for: name)
            var it = Item(id: id, drive: drive, name: name, parent: parent, isFolder: folder, package: package, mime: mime,
                          created: date, modified: date, fsCreated: fsModified ?? date, fsModified: fsModified ?? date)
            it.hasThumbnail = mime?.hasPrefix("image/") ?? false
            items[id] = it
            if let data { blobs[id] = data }
            return id
        }

        @discardableResult
        public mutating func addFolder(_ name: String, in parent: String? = nil) -> String {
            add(name, parent: parent ?? rootID, folder: true, at: FakeGraphServer.seedDate)
        }

        @discardableResult
        public mutating func addFile(_ name: String, in parent: String? = nil, data: Data, modified: Date = FakeGraphServer.seedDate) -> String {
            add(name, parent: parent ?? rootID, folder: false, data: data, at: FakeGraphServer.seedDate, fsModified: modified)
        }

        /// A OneNote notebook: a package, not a folder or a downloadable file.
        @discardableResult
        public mutating func addPackage(_ name: String, in parent: String? = nil) -> String {
            add(name, parent: parent ?? rootID, folder: false, data: Data(count: 4096), at: FakeGraphServer.seedDate, package: "oneNote")
        }

        /// A folder in someone else's drive, added to the user's root as a shortcut.
        @discardableResult
        public mutating func addSharedFolder(_ name: String, files: [(String, Data)]) -> (shortcut: String, folder: String) {
            let shared = FakeGraphServer.sharedDriveID
            let sharedRoot = roots[shared] ?? makeRoot(shared)
            let folder = add(name, parent: sharedRoot, folder: true, at: FakeGraphServer.seedDate)
            for (n, d) in files { add(n, parent: folder, folder: false, data: d, at: FakeGraphServer.seedDate) }
            let shortcut = newID(driveID)
            items[shortcut] = Item(id: shortcut, drive: driveID, name: name, parent: rootID, isFolder: false, package: nil, mime: nil,
                                   created: FakeGraphServer.seedDate, modified: FakeGraphServer.seedDate,
                                   fsCreated: FakeGraphServer.seedDate, fsModified: FakeGraphServer.seedDate,
                                   remoteDrive: shared, remoteID: folder)
            return (shortcut, folder)
        }

        /// Generic sample content for demo mode.
        mutating func seedDemo() {
            let docs = addFolder("Documents")
            addFile("Meeting Notes.txt", in: docs, data: Data("Agenda\n- Welcome\n- Project updates\n- Next steps\n".utf8),
                    modified: Date(timeIntervalSince1970: 1_789_200_000))
            addFile("Budget.csv", in: docs, data: Data("Item,Q1,Q2,Q3\nTravel,1200,950,1100\nSoftware,400,400,450\nEvents,0,2500,800\n".utf8),
                    modified: Date(timeIntervalSince1970: 1_789_500_000))
            let pics = addFolder("Pictures")
            for (i, pic) in [("Sunrise", 0.08), ("Harbor", 0.55)].enumerated() {
                let data = DemoArt.jpeg(width: 800, height: 533, hue: CGFloat(pic.1), label: pic.0) ?? Data(count: 2048)
                addFile(pic.0 + ".jpg", in: pics, data: data, modified: Date(timeIntervalSince1970: 1_788_400_000 + Double(i) * 86_400))
            }
            addFile("Read Me.txt", data: Data("Sample files for trying Cirrus with OneDrive.\n".utf8), modified: Date(timeIntervalSince1970: 1_788_100_000))
        }

        public mutating func issueRefreshToken() -> String {
            let rt = "M.C540_BAY.fake-refresh-" + UUID().uuidString
            refreshTokens[rt] = clientID
            return rt
        }

        // MARK: Queries

        public var validRefreshTokens: [String] { Array(refreshTokens.keys) }
        public mutating func expireAccessTokens() { accessTokens = accessTokens.mapValues { _ in .distantPast } }
        public mutating func revokeRefreshTokens() { refreshTokens = [:] }
        public var openUploadSessions: Int { sessions.count }

        /// In the recycle bin itself or inside a folder that is.
        func isGone(_ it: Item) -> Bool {
            var cur: Item? = it
            while let c = cur {
                if c.deleted { return true }
                cur = c.parent.flatMap { items[$0] }
            }
            return false
        }

        public func live(_ id: String) -> Item? { items[id].flatMap { isGone($0) ? nil : $0 } }
        public var recycleBin: [Item] { items.values.filter(\.deleted) }

        public func children(of id: String) -> [Item] { items.values.filter { $0.parent == id && !$0.deleted } }

        /// OneDrive names are case-insensitive.
        public func child(named name: String, in parent: String? = nil) -> Item? {
            let p = parent ?? rootID
            return items.values.first { $0.parent == p && !$0.deleted && $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
        }

        func size(of it: Item) -> Int64 {
            if it.remoteID != nil { return 0 }
            if !it.isFolder { return Int64(blobs[it.id]?.count ?? 0) }
            return children(of: it.id).reduce(0) { $0 + size(of: $1) }
        }

        public var used: Int64 { items.values.filter { $0.drive == driveID && !$0.isFolder }.reduce(0) { $0 + Int64(blobs[$1.id]?.count ?? 0) } }
        public var deletedBytes: Int64 {
            items.values.filter { $0.drive == driveID && !$0.isFolder && isGone($0) }.reduce(0) { $0 + Int64(blobs[$1.id]?.count ?? 0) }
        }

        func isInside(_ id: String, _ ancestor: String) -> Bool {
            var cur: String? = id
            while let c = cur {
                if c == ancestor { return true }
                cur = items[c]?.parent
            }
            return false
        }

        func freeName(_ name: String, in parent: String) -> String {
            let ext = (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            var i = 1
            while true {
                let candidate = "\(stem) \(i)" + (ext.isEmpty ? "" : "." + ext)
                if child(named: candidate, in: parent) == nil { return candidate }
                i += 1
            }
        }
    }

    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var _state = State()

    public static var state: State {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    public static func reset(_ s: State = State()) { lock.withLock { _state = s } }
    public static func update(_ f: (inout State) -> Void) { lock.withLock { f(&_state) } }

    /// Demo mode: sample content (kept for the life of the process) and a fresh refresh token for the account.
    public static func startDemo() -> (clientID: String, refreshToken: String, title: String) {
        lock.withLock {
            if !_state.isDemo {
                var s = State()
                s.isDemo = true
                s.latency = 0.01
                s.pageSize = 100
                s.seedDemo()
                _state = s
            }
            let rt = _state.issueRefreshToken()
            return (_state.clientID, rt, _state.mail ?? _state.userPrincipalName)
        }
    }

    // MARK: The browser step

    /// Plays Microsoft's authorize page: checks the request as Entra does for a public client with the
    /// redirect URI `http://localhost` (any port), then returns where the browser would be sent — the loopback
    /// redirect with `code` and `state`, or with `error`. Nil when Microsoft would show an error page instead.
    public static func authorize(_ url: URL, deny: Bool = false) -> URL? {
        lock.withLock { () -> URL? in
            let q = query(url)
            guard url.host == loginHost, url.path == "/common/oauth2/v2.0/authorize" else { return nil }
            guard q["client_id"] == _state.clientID else { return nil }                       // AADSTS700016
            guard let redirect = q["redirect_uri"], var back = URLComponents(string: redirect), back.scheme == "http",
                  back.host == "localhost", back.port != nil, back.path.isEmpty || back.path == "/", back.query == nil else { return nil }   // AADSTS50011
            let scopes = Set((q["scope"] ?? "").split(separator: " ").map(String.init))
            var items: [URLQueryItem]
            if deny {
                items = [URLQueryItem(name: "error", value: "access_denied"),
                         URLQueryItem(name: "error_description", value: "AADSTS65004: User declined to consent to access the app.")]
            } else if q["response_type"] != "code" || q["code_challenge_method"] != "S256" || (q["code_challenge"] ?? "").count != 43 {
                items = [URLQueryItem(name: "error", value: "invalid_request"),
                         URLQueryItem(name: "error_description", value: "AADSTS9002325: Proof Key for Code Exchange (S256) is required.")]
            } else if !scopes.isSuperset(of: ["Files.ReadWrite.All", "User.Read", "offline_access"]) {
                items = [URLQueryItem(name: "error", value: "invalid_scope"),
                         URLQueryItem(name: "error_description", value: "AADSTS70011: The provided request must include the needed scopes.")]
            } else {
                let code = "M.C540_BAY.fake-code-" + UUID().uuidString
                _state.codes[code] = Code(challenge: q["code_challenge"] ?? "", redirect: redirect, scope: q["scope"] ?? "")
                items = [URLQueryItem(name: "code", value: code)]
            }
            items.append(URLQueryItem(name: "state", value: q["state"]))
            if back.path.isEmpty { back.path = "/" }
            back.queryItems = items
            return back.url
        }
    }

    /// Plays the browser: "signs in" on Microsoft's page and follows the redirect to the app's loopback listener.
    public static func approve(_ url: URL, deny: Bool = false) async {
        guard let target = authorize(url, deny: deny) else { return }
        await visit(target)
    }

    /// A GET over the real network stack (the loopback socket isn't intercepted).
    public static func visit(_ url: URL) async {
        let session = URLSession(configuration: .ephemeral)
        _ = try? await session.data(from: url)
        session.finishTasksAndInvalidate()
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

    override public func startLoading() {
        let req = request
        let body = Self.body(req)
        let (outcome, latency) = Self.lock.withLock { (Self.handle(req, body: body), Self._state.latency) }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        switch outcome {
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .redirect(let status, let location):
            // Like a careless HTTP stack: the next request would carry every header, the token included.
            var next = req
            next.url = URL(string: location)
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location, "Content-Length": "0"])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: resp)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .reply(let status, var headers, let data):
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json; odata.metadata=minimal; charset=utf-8" }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
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

    // MARK: Helpers

    static func json(_ status: Int, _ j: JSON, _ headers: [String: String] = [:]) -> Outcome { .reply(status, headers, j.data()) }

    static func gerr(_ status: Int, _ code: String, _ message: String, _ headers: [String: String] = [:]) -> Outcome {
        json(status, ["error": ["code": .string(code), "message": .string(message),
                                "innerError": ["date": .string(iso(Date())), "request-id": .string(UUID().uuidString.lowercased())]]], headers)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

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

    /// OneDrive's naming rules.
    static let invalidName = CharacterSet(charactersIn: "\"*:<>?/\\|").union(.controlCharacters)
    static func badName(_ n: String) -> Bool { n.isEmpty || n == "." || n == ".." || n.rangeOfCharacter(from: invalidName) != nil }

    static func itemJSON(_ it: Item, _ select: Set<String>? = nil) -> JSON {
        let s = _state
        var o: [String: JSON] = [
            "id": .string(it.id), "name": .string(it.name),
            "eTag": .string("\"{\(it.id)},\(it.version)\""), "cTag": .string("\"c:{\(it.id)},\(it.version)\""),
            "createdDateTime": .string(iso(it.created)), "lastModifiedDateTime": .string(iso(it.modified)),
            "fileSystemInfo": ["createdDateTime": .string(iso(it.fsCreated)), "lastModifiedDateTime": .string(iso(it.fsModified))],
            "size": .int64(s.size(of: it)),
        ]
        var parent: [String: JSON] = ["driveId": .string(it.drive), "driveType": "personal"]
        if let p = it.parent { parent["id"] = .string(p) } else { o["root"] = [:] }
        o["parentReference"] = .object(parent)
        if let rd = it.remoteDrive, let rid = it.remoteID, let target = s.items[rid] {
            var r: [String: JSON] = ["id": .string(rid), "name": .string(target.name), "size": .int64(s.size(of: target)),
                                     "parentReference": ["driveId": .string(rd), "driveType": "personal"]]
            if target.isFolder { r["folder"] = ["childCount": .int(s.children(of: rid).count)] }
            else { r["file"] = ["mimeType": .string(target.mime ?? "application/octet-stream")] }
            o["remoteItem"] = .object(r)
            o["shared"] = ["scope": "users"]
        } else if it.isFolder {
            o["folder"] = ["childCount": .int(s.children(of: it.id).count)]
        } else if let pk = it.package {
            o["package"] = ["type": .string(pk)]
        } else {
            o["file"] = ["mimeType": .string(it.mime ?? "application/octet-stream")]
            if it.hasThumbnail { o["image"] = [:] }
        }
        if let sel = select { o = o.filter { sel.contains($0.key) } }
        return .object(o)
    }

    // MARK: Routing

    static func handle(_ r: URLRequest, body: Data) -> Outcome {
        guard let url = r.url, let host = url.host else { return gerr(400, "invalidRequest", "Bad request") }
        let method = r.httpMethod ?? "GET"
        let hadAuth = r.value(forHTTPHeaderField: "Authorization") != nil
        _state.calls.append("\(method) \(host)\(url.path)")
        guard url.scheme == "https" else { return gerr(400, "invalidRequest", "https only") }
        switch host {
        case loginHost:
            return token(method, url.path, body)
        case contentHost:
            _state.contentRequests.append((url.path, hadAuth))
            // Real OneDrive answers 401 when a pre-authenticated URL also gets a bearer token.
            if hadAuth { _state.authLeaks += 1; return gerr(401, "unauthenticated", "Pre-authenticated URLs must not get an Authorization header.") }
            return contentHostRequest(method, url, r, body)
        default:
            return graph(method, url, r, body)
        }
    }

    // MARK: Identity platform

    static func token(_ method: String, _ path: String, _ body: Data) -> Outcome {
        guard method == "POST", path == "/common/oauth2/v2.0/token" else { return .reply(404, [:], Data()) }
        let f = form(body)
        _state.tokenRequestKeys.append(Set(f.keys))
        func bad(_ status: Int, _ error: String, _ desc: String) -> Outcome {
            let code = Int(desc.dropFirst("AADSTS".count).prefix { $0.isNumber }) ?? 0
            return json(status, ["error": .string(error), "error_codes": [.int(code)],
                                 "error_description": .string(desc + "\r\nTrace ID: \(UUID().uuidString.lowercased())\r\nCorrelation ID: \(UUID().uuidString.lowercased())\r\nTimestamp: \(iso(Date()))")])
        }
        guard f["client_id"] == _state.clientID else {
            return bad(400, "unauthorized_client", "AADSTS700016: Application with identifier '\(f["client_id"] ?? "")' was not found in the directory.")
        }
        if f["client_secret"] != nil || f["client_assertion"] != nil {
            return bad(401, "invalid_client", "AADSTS700025: Client is public so neither 'client_assertion' nor 'client_secret' should be presented.")
        }
        switch f["grant_type"] {
        case "authorization_code":
            guard let code = f["code"], let c = _state.codes.removeValue(forKey: code) else {
                return bad(400, "invalid_grant", "AADSTS70000: The provided authorization code is invalid or has expired.")
            }
            guard f["redirect_uri"] == c.redirect else {
                return bad(400, "invalid_grant", "AADSTS70000: The redirect URI doesn't match the one the code was issued for.")
            }
            guard let v = f["code_verifier"], (43...128).contains(v.count), PKCE(verifier: v).challenge == c.challenge else {
                return bad(400, "invalid_grant", "AADSTS501481: The Code_Verifier does not match the code_challenge supplied in the authorization request.")
            }
            return issue(scope: c.scope)
        case "refresh_token":
            // Rotation, strictly: a refresh token works once.
            guard let t = f["refresh_token"], _state.refreshTokens.removeValue(forKey: t) != nil else {
                return bad(400, "invalid_grant", "AADSTS70000: The provided value for the input parameter 'refresh_token' or 'assertion' is not valid.")
            }
            _state.refreshes += 1
            return issue(scope: f["scope"] ?? "")
        default:
            return bad(400, "unsupported_grant_type", "AADSTS70003: The app requested an unsupported grant type.")
        }
    }

    static func issue(scope: String) -> Outcome {
        let access = "EwB4A8l6BAAU.fake-access-" + UUID().uuidString
        _state.accessTokens[access] = Date().addingTimeInterval(_state.accessTTL)
        var out: [String: JSON] = ["token_type": "Bearer", "scope": "Files.ReadWrite.All User.Read", "access_token": .string(access),
                                   "expires_in": .number(_state.accessTTL), "ext_expires_in": .number(_state.accessTTL)]
        if scope.split(separator: " ").contains("offline_access") { out["refresh_token"] = .string(_state.issueRefreshToken()) }
        return json(200, .object(out))
    }

    // MARK: Graph

    static func graph(_ method: String, _ url: URL, _ r: URLRequest, _ body: Data) -> Outcome {
        guard let h = r.value(forHTTPHeaderField: "Authorization"), h.hasPrefix("Bearer "),
              let exp = _state.accessTokens[String(h.dropFirst(7))], exp > Date() else {
            return gerr(401, "InvalidAuthenticationToken", "Access token has expired or is not yet valid.", ["WWW-Authenticate": "Bearer error=\"invalid_token\""])
        }
        if _state.throttleNext > 0 {
            _state.throttleNext -= 1
            return gerr(429, "activityLimitReached", "The request has been throttled", ["Retry-After": "0"])
        }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard raw.hasPrefix("/v1.0/") else { return gerr(404, "itemNotFound", "Unknown API version.") }
        var p = String(raw.dropFirst("/v1.0".count))
        let q = query(url)
        let select = q["$select"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let s = _state
        if p == "/me" {
            guard method == "GET" else { return gerr(405, "invalidRequest", "Method not allowed.") }
            var o: [String: JSON] = ["id": .string(s.userID), "displayName": .string(s.displayName), "userPrincipalName": .string(s.userPrincipalName),
                                     "mail": s.mail.map { .string($0) } ?? .null]
            if let sel = select { o = o.filter { sel.contains($0.key) } }
            return json(200, .object(o))
        }
        guard s.hasDrive else { return gerr(404, "itemNotFound", "User's mysite not found.") }
        if p == "/me/drive" {
            var o: [String: JSON] = ["id": .string(s.driveID), "driveType": "personal", "owner": ["user": ["displayName": .string(s.displayName)]],
                                     "quota": ["total": .int64(s.total), "used": .int64(s.used), "remaining": .int64(max(0, s.total - s.used)),
                                               "deleted": .int64(s.deletedBytes), "state": "normal"]]
            if let sel = select { o = o.filter { sel.contains($0.key) } }
            return json(200, .object(o))
        }
        var drive = s.driveID
        if p.hasPrefix("/me/drive/") {
            p = String(p.dropFirst("/me/drive".count))
        } else if p.hasPrefix("/drives/") {
            let rest = p.dropFirst("/drives/".count)
            guard let slash = rest.firstIndex(of: "/") else { return gerr(400, "invalidRequest", "Bad drive path.") }
            drive = String(rest[..<slash]).removingPercentEncoding ?? ""
            p = String(rest[slash...])
        } else {
            return gerr(400, "BadRequest", "Unsupported segment.")
        }
        let itemID: String
        if p.hasPrefix("/root") {
            guard let root = s.roots[drive] else { return gerr(404, "itemNotFound", "Drive not found.") }
            itemID = root
            p = String(p.dropFirst("/root".count))
        } else if p.hasPrefix("/items/") {
            let rest = p.dropFirst("/items/".count)
            let end = rest.firstIndex { $0 == "/" || $0 == ":" } ?? rest.endIndex
            itemID = String(rest[..<end]).removingPercentEncoding ?? ""
            p = String(rest[end...])
        } else {
            return gerr(400, "BadRequest", "Unsupported segment.")
        }
        // Path addressing: "{item}:/{name}" then nothing, ":", ":/content" or ":/createUploadSession".
        var name: String?
        if p.hasPrefix(":/") {
            let rest = p.dropFirst(2)
            let end = rest.firstIndex(of: ":") ?? rest.endIndex
            let encoded = String(rest[..<end])
            guard !encoded.contains("/"), let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else {
                return gerr(400, "invalidRequest", "Only one name segment is supported here.")
            }
            name = decoded
            p = String(rest[end...])
            if p == ":" { p = "" } else if p.hasPrefix(":/") { p = String(p.dropFirst()) } else if !p.isEmpty { return gerr(400, "invalidRequest", "Bad path.") }
        }
        guard let base = s.live(itemID), base.drive == drive else { return gerr(404, "itemNotFound", "The resource could not be found.") }
        if let name {
            guard base.isFolder, base.remoteID == nil else { return gerr(400, "invalidRequest", "The parent isn't a folder.") }
            switch (method, p) {
            case ("GET", ""):
                guard let c = s.child(named: name, in: base.id) else { return gerr(404, "itemNotFound", "The resource could not be found.") }
                return json(200, itemJSON(c, select))
            case ("PUT", "/content"): return simpleUpload(base, name, q, body)
            case ("POST", "/createUploadSession"): return createSession(base, name, body)
            default: return gerr(400, "invalidRequest", "Unsupported request.")
            }
        }
        switch (method, p) {
        case ("GET", ""): return json(200, itemJSON(base, select))
        case ("GET", "/children"): return listChildren(base, url, q, select)
        case ("POST", "/children"): return createFolder(base, body)
        case ("PATCH", ""): return patch(base, q, body)
        case ("DELETE", ""): return remove(base)
        case ("GET", "/content"): return downloadRedirect(base)
        case ("GET", _) where p.hasPrefix("/thumbnails/"): return thumbnail(base, p)
        default: return gerr(400, "invalidRequest", "Unsupported request: \(method) \(p)")
        }
    }

    static func listChildren(_ base: Item, _ url: URL, _ q: [String: String], _ select: Set<String>?) -> Outcome {
        guard base.remoteID == nil else { return gerr(400, "invalidRequest", "A shortcut's contents are listed in the drive it points to.") }
        let all = _state.children(of: base.id).sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        let top = Int(q["$top"] ?? "") ?? 200
        guard (1...999).contains(top) else { return gerr(400, "invalidRequest", "$top must be between 1 and 999.") }
        let size = min(top, _state.pageSize)
        let skip = Int(q["$skiptoken"] ?? "") ?? 0
        let page = Array(all.dropFirst(skip).prefix(size))
        var out: [String: JSON] = ["value": .array(page.map { itemJSON($0, select) })]
        if skip + page.count < all.count, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = (c.queryItems ?? []).filter { $0.name != "$skiptoken" } + [URLQueryItem(name: "$skiptoken", value: String(skip + page.count))]
            if let next = c.url { out["@odata.nextLink"] = .string(next.absoluteString) }
        }
        return json(200, .object(out))
    }

    static func createFolder(_ base: Item, _ body: Data) -> Outcome {
        let j = (try? JSON(data: body)) ?? .null
        guard base.isFolder, base.remoteID == nil else { return gerr(400, "invalidRequest", "The parent isn't a folder.") }
        guard let name = j["name"].string, case .object = j["folder"] else { return gerr(400, "invalidRequest", "name and folder are required.") }
        guard !badName(name) else { return gerr(400, "invalidRequest", "The name contains invalid characters.") }
        var finalName = name
        if let existing = _state.child(named: name, in: base.id) {
            switch j["@microsoft.graph.conflictBehavior"].string ?? "fail" {
            case "rename": finalName = _state.freeName(name, in: base.id)
            case "replace": _state.items[existing.id]?.deleted = true
            default: return gerr(409, "nameAlreadyExists", "An item with the same name already exists under the parent.")
            }
        }
        let id = _state.add(finalName, parent: base.id, folder: true, at: Date())
        return json(201, itemJSON(_state.items[id]!))
    }

    static func patch(_ base: Item, _ q: [String: String], _ body: Data) -> Outcome {
        guard base.parent != nil else { return gerr(403, "accessDenied", "The root folder can't be changed.") }
        let j = (try? JSON(data: body)) ?? .null
        guard case .object(let o) = j, !o.isEmpty else { return gerr(400, "invalidRequest", "Empty update.") }
        _state.patches.append(j)
        var it = base
        if case .object(let pr) = j["parentReference"] {
            guard let pid = pr["id"]?.string else { return gerr(400, "invalidRequest", "parentReference.id is required.") }
            if let d = pr["driveId"]?.string, d != it.drive { return gerr(400, "invalidRequest", "Moving items between drives isn't supported.") }
            guard let target = _state.live(pid), target.drive == it.drive, target.isFolder, target.remoteID == nil else {
                return gerr(400, "invalidRequest", "parentReference.id must be the id of a folder in this drive.")
            }
            guard !_state.isInside(target.id, it.id) else { return gerr(400, "invalidRequest", "A folder can't be moved into itself.") }
            it.parent = pid
        }
        if let n = j["name"].string {
            guard !badName(n) else { return gerr(400, "invalidRequest", "The name contains invalid characters.") }
            it.name = n
        }
        if it.parent != base.parent || it.name != base.name, let clash = _state.child(named: it.name, in: it.parent), clash.id != it.id {
            guard q["@microsoft.graph.conflictBehavior"] == "replace" else {
                return gerr(409, "nameAlreadyExists", "An item with the same name already exists under the parent.")
            }
            _state.items[clash.id]?.deleted = true
        }
        if let d = j["fileSystemInfo"]["lastModifiedDateTime"].date { it.fsModified = d }
        if let d = j["fileSystemInfo"]["createdDateTime"].date { it.fsCreated = d }
        it.version += 1
        it.modified = Date()
        _state.items[it.id] = it
        return json(200, itemJSON(it))
    }

    /// DELETE moves the item to the recycle bin (a shortcut: only the shortcut).
    static func remove(_ base: Item) -> Outcome {
        guard base.parent != nil else { return gerr(403, "accessDenied", "The root folder can't be deleted.") }
        _state.items[base.id]?.deleted = true
        return .reply(204, [:], Data())
    }

    static func downloadRedirect(_ base: Item) -> Outcome {
        guard !base.isFolder, base.remoteID == nil else { return gerr(400, "invalidRequest", "Folders have no content.") }
        if base.package != nil { return gerr(406, "notSupported", "Packages can't be downloaded as a file.") }
        let token = UUID().uuidString.lowercased()
        _state.links[token] = Link(item: base.id, thumbnail: false)
        return .redirect(302, "https://\(contentHost)/dl/\(token)?tempauth=fake-\(token.prefix(8))")
    }

    static func thumbnail(_ base: Item, _ p: String) -> Outcome {
        let parts = p.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "thumbnails", parts[1] == "0", parts[3] == "content" else {
            return gerr(400, "invalidRequest", "Bad thumbnail path.")
        }
        let size = parts[2]
        _state.thumbnailSizes.append(size)
        let named: Set = ["small", "medium", "large", "smallSquare", "mediumSquare", "largeSquare"]
        let custom = size.range(of: #"^c[1-9][0-9]{0,4}x[1-9][0-9]{0,4}(_crop)?$"#, options: .regularExpression) != nil
        guard named.contains(size) || (custom && _state.customThumbnails) else { return gerr(400, "invalidRequest", "Invalid thumbnail size.") }
        guard base.hasThumbnail, _state.blobs[base.id] != nil else { return gerr(404, "itemNotFound", "The item has no thumbnail.") }
        let token = UUID().uuidString.lowercased()
        _state.links[token] = Link(item: base.id, thumbnail: true)
        return .redirect(302, "https://\(contentHost)/thumb/\(token)?tempauth=fake-\(token.prefix(8))")
    }

    static func simpleUpload(_ parent: Item, _ name: String, _ q: [String: String], _ body: Data) -> Outcome {
        guard !badName(name) else { return gerr(400, "invalidRequest", "The name contains invalid characters.") }
        guard body.count <= simpleUploadLimit else { return gerr(413, "requestTooLarge", "Use an upload session for files over 4 MB.") }
        var finalName = name
        if let existing = _state.child(named: name, in: parent.id) {
            switch q["@microsoft.graph.conflictBehavior"] ?? "replace" {
            case "fail": return gerr(409, "nameAlreadyExists", "The specified item name already exists.")
            case "rename": finalName = _state.freeName(name, in: parent.id)
            default:
                guard !existing.isFolder else { return gerr(409, "nameAlreadyExists", "A folder with that name exists.") }
                _state.blobs[existing.id] = body
                _state.items[existing.id]?.version += 1
                _state.items[existing.id]?.modified = Date()
                _state.items[existing.id]?.fsModified = Date()
                _state.simpleUploads += 1
                return json(200, itemJSON(_state.items[existing.id]!))
            }
        }
        guard _state.used + Int64(body.count) <= _state.total else { return gerr(507, "quotaLimitReached", "Insufficient Space Available") }
        let id = _state.add(finalName, parent: parent.id, folder: false, data: body, at: Date())
        _state.simpleUploads += 1
        if _state.loseUploadAnswers > 0 { _state.loseUploadAnswers -= 1; return .drop }
        return json(201, itemJSON(_state.items[id]!))
    }

    static func createSession(_ parent: Item, _ name: String, _ body: Data) -> Outcome {
        guard !badName(name) else { return gerr(400, "invalidRequest", "The name contains invalid characters.") }
        let item = ((try? JSON(data: body)) ?? .null)["item"]
        if let n = item["name"].string, n != name { return gerr(400, "invalidRequest", "The name in the body doesn't match the path.") }
        let behavior = item["@microsoft.graph.conflictBehavior"].string ?? "replace"
        if behavior == "fail", _state.child(named: name, in: parent.id) != nil {
            return gerr(409, "nameAlreadyExists", "The specified item name already exists.")
        }
        let total = item["fileSize"].int64
        if let t = total, _state.used + t > _state.total { return gerr(507, "quotaLimitReached", "Insufficient Space Available") }
        let sid = UUID().uuidString.lowercased()
        let expires = Date().addingTimeInterval(3600)
        _state.sessions[sid] = UploadSession(parent: parent.id, name: name, total: total, behavior: behavior,
                                             fsModified: item["fileSystemInfo"]["lastModifiedDateTime"].date, expires: expires)
        _state.sessionsCreated += 1
        _state.lastSessionItem = item
        return json(200, ["uploadUrl": .string("https://\(contentHost)/up/\(sid)?tempauth=fake-\(sid.prefix(8))"),
                          "expirationDateTime": .string(iso(expires)), "nextExpectedRanges": ["0-"]])
    }

    // MARK: Pre-authenticated host

    static func contentHostRequest(_ method: String, _ url: URL, _ r: URLRequest, _ body: Data) -> Outcome {
        let parts = url.pathComponents   // ["/", kind, token]
        guard parts.count == 3 else { return gerr(404, "itemNotFound", "Not found.") }
        let token = parts[2]
        switch parts[1] {
        case "dl", "thumb":
            guard method == "GET", let link = _state.links[token], link.thumbnail == (parts[1] == "thumb"),
                  let data = _state.blobs[link.item], _state.items[link.item] != nil else { return gerr(404, "itemNotFound", "The link expired.") }
            if !link.thumbnail && _state.dropDownloadsNext > 0 {
                _state.dropDownloadsNext -= 1
                return .drop
            }
            let mime = link.thumbnail ? "image/jpeg" : (_state.items[link.item]?.mime ?? "application/octet-stream")
            return .reply(200, ["Content-Type": mime, "Content-Length": String(data.count)], data)
        case "up":
            return sessionRequest(method, token, r, body)
        default:
            return gerr(404, "itemNotFound", "Not found.")
        }
    }

    static func sessionRequest(_ method: String, _ sid: String, _ r: URLRequest, _ body: Data) -> Outcome {
        guard var s = _state.sessions[sid] else { return gerr(404, "itemNotFound", "The upload session was not found.") }
        func status() -> JSON { ["expirationDateTime": .string(iso(s.expires)), "nextExpectedRanges": [.string("\(s.data.count)-")]] }
        switch method {
        case "GET":
            _state.sessionStatusQueries += 1
            return json(200, status())
        case "DELETE":
            _state.sessions[sid] = nil
            _state.sessionsCancelled += 1
            return .reply(204, [:], Data())
        case "PUT":
            break
        default:
            return gerr(405, "invalidRequest", "Method not allowed.")
        }
        let cr = r.value(forHTTPHeaderField: "Content-Range") ?? ""
        let spec = cr.hasPrefix("bytes ") ? cr.dropFirst("bytes ".count).split(separator: "/") : []
        let ab = spec.first?.split(separator: "-").compactMap { Int64($0) } ?? []
        guard spec.count == 2, ab.count == 2, let total = Int64(spec[1]), ab[0] <= ab[1], ab[1] < total else {
            return gerr(400, "invalidRequest", "Invalid Content-Range.")
        }
        let (a, b) = (ab[0], ab[1])
        let len = b - a + 1
        guard Int64(body.count) == len else { return gerr(400, "invalidRequest", "Content-Range doesn't match the body length.") }
        if let t = s.total, t != total { return gerr(400, "invalidRequest", "The file size doesn't match the size given for this upload.") }
        s.total = total
        guard a == Int64(s.data.count) else { return gerr(416, "invalidRange", "Expected the fragment to start at \(s.data.count).") }
        let last = b + 1 == total
        guard last || len % Int64(fragmentUnit) == 0 else { return gerr(400, "invalidRequest", "Fragments must be a multiple of 320 KiB.") }
        guard len <= 60 * 1024 * 1024 else { return gerr(413, "requestTooLarge", "Fragments must be at most 60 MiB.") }
        _state.chunkPuts += 1
        _state.chunkSizes.append(Int(len))
        if _state.dropChunk == _state.chunkPuts {
            // Only part of the fragment arrived before the connection broke.
            s.data.append(body.prefix(Int(len) / 2 / fragmentUnit * fragmentUnit))
            _state.sessions[sid] = s
            return .drop
        }
        s.data.append(body)
        guard last else {
            _state.sessions[sid] = s
            return json(202, status())
        }
        _state.sessions[sid] = nil
        var name = s.name
        if let existing = _state.child(named: s.name, in: s.parent) {
            switch s.behavior {
            case "fail": return gerr(409, "nameAlreadyExists", "The specified item name already exists.")
            case "rename": name = _state.freeName(s.name, in: s.parent)
            default: _state.items[existing.id]?.deleted = true
            }
        }
        guard _state.used + total <= _state.total else { return gerr(507, "quotaLimitReached", "Insufficient Space Available") }
        let id = _state.add(name, parent: s.parent, folder: false, data: s.data, at: Date(), fsModified: s.fsModified)
        if _state.loseUploadAnswers > 0 { _state.loseUploadAnswers -= 1; return .drop }
        return json(201, itemJSON(_state.items[id]!))
    }
}
#endif
