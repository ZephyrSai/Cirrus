#if DEBUG
import CoreGraphics
import CryptoKit
import Foundation

/// A stateful stand-in for Dropbox's OAuth 2 endpoints and API v2 (api.dropboxapi.com and
/// content.dropboxapi.com), served through URLProtocol. Unit tests use it as the server; Debug builds in demo
/// mode use it so Dropbox can be browsed without an account. It is strict where real clients go wrong: exact
/// redirect URIs, PKCE (S256) for a public client with no secret, one-time codes, `token_access_type=offline`,
/// expiring access tokens, Content-Type rules per endpoint style, ASCII-only `Dropbox-API-Arg` headers, cursor
/// paging with small pages (and cursor resets), upload sessions that insist on the right offset (and say which
/// one), conflicts for mode "add", case-insensitive names, write contention (`too_many_write_operations`) when
/// writes overlap, a deleted state that keeps files restorable, thumbnails, space usage, team spaces
/// (`Dropbox-API-Path-Root`), and 429s you can inject. Like Dropbox, writes create missing parent folders; it
/// counts them so tests can make sure Cirrus never relies on that. Not compiled into release builds.
public final class FakeDropboxServer: URLProtocol, @unchecked Sendable {
    public static let apiHost = "api.dropboxapi.com"
    public static let contentHost = "content.dropboxapi.com"
    public static let wwwHost = "www.dropbox.com"
    public static let hosts: Set<String> = [apiHost, contentHost]
    public static let seedDate = Date(timeIntervalSince1970: 1_788_000_000)
    public static let maxRequestBody = 150 * 1024 * 1024
    static let writeRoutes: Set<String> = ["files/create_folder_v2", "files/move_v2", "files/delete_v2", "files/upload", "files/upload_session/finish"]
    static let thumbnailExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "gif", "webp", "ppm", "bmp"]

    public struct Item: Sendable {
        public var id: String
        public var name: String
        /// The parent folder's id; "" for items at the top.
        public var parent: String
        public var isFolder: Bool
        public var rev: String
        public var clientModified: Date
        public var serverModified: Date
        public var deleted = false
        public var sharedFolderID: String?
        /// False: a Paper doc or other online-only file (`export` only).
        public var downloadable = true
    }

    struct Session: Sendable { var data = Data(); var closed = false }
    struct Code: Sendable { var challenge: String?; var redirect: String?; var scopes: Set<String>; var offline: Bool }
    struct Cursor: Sendable { var ids: [String]; var next: Int }

    /// Everything the server knows. Tests read and tweak it between steps.
    public struct State: Sendable {
        public var appKey = "fk4bq2x9cirrus1"
        /// Redirect URIs registered in the App Console (matched exactly).
        public var redirectURIs: Set<String> = Set(Dropbox.redirectURIs)
        /// Settings › OAuth 2 › Allow public clients (PKCE).
        public var allowPublicClients = true
        /// The permissions ticked in the App Console.
        public var appScopes: Set<String> = Set(Dropbox.scopes)
        /// What the token answer reports as granted (nil: what was asked for).
        public var grantedScopes: Set<String>?
        public var accountID = "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"
        public var displayName = "Alex Morgan"
        public var email = "alex@example.com"
        public var homeNamespace = "3235641"
        /// A team with a team space: its root namespace, which requests must name in Dropbox-API-Path-Root.
        public var teamRootNamespace: String?
        public var allocated: Int64 = 2_199_023_255_552
        /// A team allocation instead of an individual one.
        public var team: (used: Int64, allocated: Int64, memberLimit: Int64)?
        public var accessTTL: Double = 14_400
        /// Entries per listing page at most (small, so clients must follow cursors).
        public var pageSize = 3
        /// Hand out a new refresh token with each refresh (Dropbox normally doesn't).
        public var rotateRefreshTokens = false
        public var latency: Double = 0
        public var items: [String: Item] = [:]
        public var blobs: [String: Data] = [:]
        var counter = 1000
        var codes: [String: Code] = [:]
        var refreshTokens: Set<String> = []
        var accessTokens: [String: Date] = [:]
        var sessions: [String: Session] = [:]
        var cursors: [String: Cursor] = [:]
        var isDemo = false
        var inflightWrites = 0
        var appendCount = 0
        // Statistics for tests
        public var calls: [String] = []
        public var refreshes = 0
        /// Parameter names of each token request (never the values).
        public var tokenRequestKeys: [Set<String>] = []
        /// Every Dropbox-API-Arg header as received.
        public var argHeaders: [String] = []
        public var nonASCIIArgHeaders = 0
        /// API calls made without the Path-Root header while the account has a team space.
        public var missingPathRoot = 0
        public var pathRootHeaders = 0
        public var simpleUploads = 0
        public var sessionsStarted = 0
        public var appends: [(offset: Int64, size: Int)] = []
        public var finishes = 0
        public var lastCommit: JSON = .null
        public var thumbnailArgs: [JSON] = []
        public var maxConcurrentWrites = 0
        public var contentions = 0
        public var autoCreatedFolders = 0
        public var downloads = 0
        // Fault injection
        /// The next N API calls get 429 too_many_requests with Retry-After: 0.
        public var throttleNext = 0
        /// The next N writes get 429 too_many_write_operations.
        public var writeContentionNext = 0
        /// A write that arrives while another is running gets too_many_write_operations, as on Dropbox.
        public var contentionOnConcurrentWrites = true
        /// The Nth append (1-based, all sessions) is stored, then the connection drops before the answer.
        public var loseAppendAnswer: Int?
        /// The Nth append breaks off before Dropbox stores any of it.
        public var dropAppendBeforeStore: Int?
        /// The next N commits (upload, or finish) are stored, but the answer is lost.
        public var loseUploadAnswers = 0
        /// The next N downloads lose their connection.
        public var dropDownloadsNext = 0
        /// The next N list_folder/continue calls answer `reset`.
        public var resetCursorsNext = 0

        public init() {}

        // MARK: Seeding

        mutating func newID() -> String {
            counter += 1
            return "id:FakeDbxAAAAAAAAAA" + String(counter)
        }

        mutating func newRev() -> String {
            counter += 1
            return String(format: "%x", counter) + "0c10ce0dd78"
        }

        @discardableResult
        mutating func add(_ name: String, parent: String, folder: Bool, data: Data? = nil, modified: Date) -> String {
            let id = newID()
            items[id] = Item(id: id, name: name, parent: parent, isFolder: folder, rev: newRev(), clientModified: modified, serverModified: modified)
            if let data { blobs[id] = data }
            return id
        }

        @discardableResult
        public mutating func addFolder(_ name: String, in parent: String = "") -> String {
            add(name, parent: parent, folder: true, modified: FakeDropboxServer.seedDate)
        }

        @discardableResult
        public mutating func addFile(_ name: String, in parent: String = "", data: Data, modified: Date = FakeDropboxServer.seedDate) -> String {
            add(name, parent: parent, folder: false, data: data, modified: modified)
        }

        /// A Dropbox Paper doc: listed, but only exportable.
        @discardableResult
        public mutating func addPaperDoc(_ name: String, in parent: String = "") -> String {
            let id = add(name, parent: parent, folder: false, data: Data(count: 2048), modified: FakeDropboxServer.seedDate)
            items[id]?.downloadable = false
            return id
        }

        public mutating func share(_ folder: String) { items[folder]?.sharedFolderID = "84528192421" }

        /// Generic sample content for demo mode.
        mutating func seedDemo() {
            let docs = addFolder("Documents")
            addFile("Meeting Notes.txt", in: docs, data: Data("Agenda\n- Welcome\n- Project updates\n- Next steps\n".utf8),
                    modified: Date(timeIntervalSince1970: 1_789_200_000))
            addFile("Budget.csv", in: docs, data: Data("Item,Q1,Q2,Q3\nTravel,1200,950,1100\nSoftware,400,400,450\nEvents,0,2500,800\n".utf8),
                    modified: Date(timeIntervalSince1970: 1_789_500_000))
            let photos = addFolder("Photos")
            for (i, pic) in [("Lake", 0.58), ("Market", 0.1)].enumerated() {
                let data = DemoArt.jpeg(width: 640, height: 427, hue: CGFloat(pic.1), label: pic.0) ?? Data(count: 2048)
                addFile(pic.0 + ".jpg", in: photos, data: data, modified: Date(timeIntervalSince1970: 1_788_400_000 + Double(i) * 86_400))
            }
            addFile("Read Me.txt", data: Data("Sample files for trying Cirrus with Dropbox.\n".utf8), modified: Date(timeIntervalSince1970: 1_788_100_000))
        }

        public mutating func issueRefreshToken() -> String {
            let rt = "fake-dbx-refresh-" + UUID().uuidString
            refreshTokens.insert(rt)
            return rt
        }

        // MARK: Queries

        public var validRefreshTokens: [String] { Array(refreshTokens) }
        public mutating func expireAccessTokens() { accessTokens = accessTokens.mapValues { _ in .distantPast } }
        public mutating func revokeRefreshTokens() { refreshTokens = []; accessTokens = [:] }
        public var openUploadSessions: Int { sessions.count }

        /// Deleted itself, or inside a deleted folder.
        func isGone(_ it: Item) -> Bool {
            var cur: Item? = it
            while let c = cur {
                if c.deleted { return true }
                cur = c.parent.isEmpty ? nil : items[c.parent]
            }
            return false
        }

        public func live(_ id: String) -> Item? { items[id].flatMap { isGone($0) ? nil : $0 } }
        public var deletedItems: [Item] { items.values.filter(\.deleted) }
        public func children(of id: String) -> [Item] { items.values.filter { $0.parent == id && !$0.deleted } }

        /// Dropbox names are case-insensitive.
        public func child(named name: String, in parent: String = "") -> Item? {
            items.values.first { $0.parent == parent && !$0.deleted && $0.name.lowercased() == name.lowercased() }
        }

        public func path(of id: String) -> String {
            guard let it = items[id] else { return "" }
            return (it.parent.isEmpty ? "" : path(of: it.parent)) + "/" + it.name
        }

        func isInside(_ id: String, _ ancestor: String) -> Bool {
            var cur = id
            while !cur.isEmpty {
                if cur == ancestor { return true }
                cur = items[cur]?.parent ?? ""
            }
            return false
        }

        public var used: Int64 { items.values.filter { !$0.isFolder && !isGone($0) }.reduce(0) { $0 + Int64(blobs[$1.id]?.count ?? 0) } }
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
    public static func startDemo() -> (appKey: String, refreshToken: String, title: String) {
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
            return (_state.appKey, rt, _state.email)
        }
    }

    // MARK: The browser step

    public enum Authorization: Equatable {
        /// Where the browser goes next: the app's redirect URI with `code` and `state`, or with `error`.
        case redirect(URL)
        /// No redirect URI: Dropbox shows this code for the user to copy.
        case code(String)
        /// Dropbox shows an error page (bad app key, unregistered redirect URI…).
        case errorPage(String)
    }

    /// Plays Dropbox's authorize page for a signed-in user who chooses Allow (or Cancel, with `deny`).
    public static func authorize(_ url: URL, deny: Bool = false) -> Authorization {
        lock.withLock { () -> Authorization in
            let q = query(url)
            guard url.scheme == "https", url.host == wwwHost, url.path == "/oauth2/authorize" else { return .errorPage("Not found") }
            guard q["client_id"] == _state.appKey else { return .errorPage("Invalid client_id.") }
            guard q["response_type"] == "code" else { return .errorPage("Invalid response_type.") }
            let redirect = q["redirect_uri"]
            if let r = redirect, !_state.redirectURIs.contains(r) {
                return .errorPage("Invalid redirect_uri. It must exactly match one of the redirect URIs you’ve pre-configured for your app (including the path).")
            }
            let challenge = q["code_challenge"]
            if challenge != nil {
                guard _state.allowPublicClients else { return .errorPage("This app doesn’t allow PKCE.") }
            }
            func fail(_ error: String, _ desc: String) -> Authorization {
                guard let r = redirect, var back = URLComponents(string: r) else { return .errorPage(desc) }
                var items = [URLQueryItem(name: "error", value: error), URLQueryItem(name: "error_description", value: desc)]
                if let s = q["state"] { items.append(URLQueryItem(name: "state", value: s)) }
                back.queryItems = items
                return .redirect(back.url!)
            }
            if let c = challenge, q["code_challenge_method"] != "S256" || c.count != 43 {
                return fail("invalid_request", "Invalid code_challenge or code_challenge_method.")
            }
            let asked = q["scope"].map { Set($0.split(separator: " ").map(String.init)) }
            if let a = asked, !a.isSubset(of: _state.appScopes) {
                return fail("invalid_scope", "Your app doesn’t have the requested scopes: \(a.subtracting(_state.appScopes).sorted().joined(separator: " ")).")
            }
            if deny { return fail("access_denied", "The user chose not to give your app access to their Dropbox account.") }
            let code = "fake-dbx-code-" + UUID().uuidString
            _state.codes[code] = Code(challenge: challenge, redirect: redirect, scopes: asked ?? _state.appScopes,
                                      offline: q["token_access_type"] == "offline")
            guard let r = redirect, var back = URLComponents(string: r) else { return .code(code) }
            var items = [URLQueryItem(name: "code", value: code)]
            if let s = q["state"] { items.append(URLQueryItem(name: "state", value: s)) }
            back.queryItems = items
            return .redirect(back.url!)
        }
    }

    /// Plays the browser: "signs in" on Dropbox's page and follows the redirect to the app's loopback listener.
    public static func approve(_ url: URL, deny: Bool = false) async {
        guard case .redirect(let target) = authorize(url, deny: deny) else { return }
        await visit(target)
    }

    /// The code Dropbox shows when the sign-in has no redirect URI (nil if it would show an error instead).
    public static func displayedCode(_ url: URL) -> String? {
        if case .code(let c) = authorize(url) { return c }
        return nil
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
        case drop
    }

    override public func startLoading() {
        let req = request
        let body = Self.body(req)
        let route = req.url.map { String($0.path.dropFirst("/2/".count)) } ?? ""
        let isWrite = req.url?.path.hasPrefix("/2/") == true && Self.writeRoutes.contains(route)
        // Dropbox locks the namespace for a write: one arriving while another runs is turned away.
        let busy: Outcome? = Self.lock.withLock {
            guard isWrite else { return nil }
            Self._state.inflightWrites += 1
            Self._state.maxConcurrentWrites = max(Self._state.maxConcurrentWrites, Self._state.inflightWrites)
            if Self._state.contentionOnConcurrentWrites && Self._state.inflightWrites > 1 {
                Self._state.inflightWrites -= 1
                Self._state.contentions += 1
                Self._state.calls.append("POST \(req.url?.host ?? "")\(req.url?.path ?? "")")
                return Self.contention()
            }
            return nil
        }
        if let busy { deliver(busy, for: req); return }
        let latency = Self.lock.withLock { Self._state.latency }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        let outcome = Self.lock.withLock { () -> Outcome in
            defer { if isWrite { Self._state.inflightWrites -= 1 } }
            return Self.handle(req, body: body)
        }
        deliver(outcome, for: req)
    }

    func deliver(_ outcome: Outcome, for req: URLRequest) {
        switch outcome {
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .reply(let status, var headers, let data):
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
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

    static func json(_ status: Int, _ j: JSON, _ headers: [String: String] = [:]) -> Outcome { .reply(status, headers, DropboxHTTP.encode(j)) }

    /// A 400 "bad input" answer: plain text, as Dropbox sends it.
    static func badInput(_ route: String, _ why: String) -> Outcome {
        .reply(400, ["Content-Type": "text/plain; charset=utf-8"], Data("Error in call to API function \"\(route)\": \(why)".utf8))
    }

    /// A route error (409): `tags` is the union path, e.g. ["path", "conflict", "file"]; `extra` goes into the
    /// innermost object (e.g. correct_offset).
    static func routeError(_ tags: [String], _ extra: [String: JSON] = [:]) -> Outcome {
        var inner: [String: JSON] = extra
        inner[".tag"] = .string(tags.last ?? "other")
        var j = JSON.object(inner)
        for t in tags.dropLast().reversed() { j = .object([".tag": .string(t), t: j]) }
        return json(409, ["error_summary": .string(tags.joined(separator: "/") + "/.."), "error": j])
    }

    static func authError(_ tag: String) -> Outcome {
        json(401, ["error_summary": .string(tag + "/.."), "error": [".tag": .string(tag)]], ["WWW-Authenticate": "Bearer"])
    }

    static func rateLimited(_ reason: String) -> Outcome {
        json(429, ["error_summary": .string(reason + "/.."), "error": ["reason": [".tag": .string(reason)], "retry_after": 0]], ["Retry-After": "0"])
    }

    static func contention() -> Outcome { rateLimited("too_many_write_operations") }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: floor(d.timeIntervalSince1970)))
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

    /// Dropbox's content hash, computed independently of the client's.
    static func contentHash(_ d: Data) -> String {
        let block = 4 * 1024 * 1024
        var digests = Data()
        var i = 0
        while i < d.count {
            digests.append(contentsOf: SHA256.hash(data: d[i..<min(i + block, d.count)]))
            i += block
        }
        return SHA256.hash(data: digests).map { String(format: "%02x", $0) }.joined()
    }

    /// Metadata as Dropbox sends it. `tagged`: as a Metadata union (list_folder, get_metadata, move, delete);
    /// otherwise a bare FileMetadata/FolderMetadata struct (upload, create_folder, download's result header).
    static func meta(_ it: Item, tagged: Bool) -> JSON {
        let s = _state
        let path = s.path(of: it.id)
        var o: [String: JSON] = ["name": .string(it.name), "id": .string(it.id), "path_display": .string(path), "path_lower": .string(path.lowercased())]
        if it.isFolder {
            if let sf = it.sharedFolderID {
                o["shared_folder_id"] = .string(sf)
                o["sharing_info"] = ["read_only": false, "shared_folder_id": .string(sf), "traverse_only": false, "no_access": false]
            }
        } else {
            let data = s.blobs[it.id] ?? Data()
            o["client_modified"] = .string(iso(it.clientModified))
            o["server_modified"] = .string(iso(it.serverModified))
            o["rev"] = .string(it.rev)
            o["size"] = .int64(Int64(data.count))
            o["is_downloadable"] = .bool(it.downloadable)
            o["content_hash"] = .string(contentHash(data))
            if !it.downloadable { o["export_info"] = ["export_as": "html", "export_options": ["html", "markdown"]] }
        }
        if tagged { o[".tag"] = .string(it.isFolder ? "folder" : "file") }
        return .object(o)
    }

    enum Lookup { case root, item(Item), notFound, malformed }

    /// "" (the top), "id:…" or "/a/b" (case-insensitive).
    static func lookup(_ path: String) -> Lookup {
        if path.isEmpty { return .root }
        if path.hasPrefix("id:") { return _state.live(path).map { .item($0) } ?? .notFound }
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/") else { return .malformed }
        var parent = ""
        var found: Item?
        for part in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { return .malformed }
            guard let c = _state.child(named: String(part), in: parent) else { return .notFound }
            found = c
            parent = c.id
        }
        return found.map { .item($0) } ?? .notFound
    }

    /// The folder a new item at `path` goes into; missing folders are created on the way, as Dropbox does.
    /// Nil parent: a file is in the way (409 already chosen).
    static func makeParent(_ path: String, route: String) -> (parent: String?, name: String, error: Outcome?) {
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return (nil, "", routeError(["path", "malformed_path"])) }
        var parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = parts.removeLast()
        guard !name.isEmpty, name != ".", name != "..", parts.allSatisfy({ !$0.isEmpty }) else {
            return (nil, name, routeError(["path", "malformed_path"]))
        }
        var parent = ""
        for part in parts {
            if let c = _state.child(named: part, in: parent) {
                guard c.isFolder else { return (nil, name, routeError(["path", "conflict", "file_ancestor"])) }
                parent = c.id
            } else {
                parent = _state.add(part, parent: parent, folder: true, modified: Date())
                _state.autoCreatedFolders += 1
            }
        }
        return (parent, name, nil)
    }

    static func timestampOK(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil
    }

    // MARK: Routing

    static func handle(_ r: URLRequest, body: Data) -> Outcome {
        guard let url = r.url, let host = url.host else { return badInput("", "Bad request") }
        _state.calls.append("POST \(host)\(url.path)")
        guard url.scheme == "https", r.httpMethod == "POST" else { return .reply(405, ["Content-Type": "text/plain"], Data("Method not allowed".utf8)) }
        if host == apiHost && url.path == "/oauth2/token" { return token(body) }
        guard url.path.hasPrefix("/2/") else { return .reply(404, ["Content-Type": "text/plain"], Data("Unknown endpoint".utf8)) }
        let route = String(url.path.dropFirst("/2/".count))
        // Authentication.
        guard let h = r.value(forHTTPHeaderField: "Authorization"), h.hasPrefix("Bearer ") else { return authError("invalid_access_token") }
        guard let exp = _state.accessTokens[String(h.dropFirst(7))] else { return authError("invalid_access_token") }
        guard exp > Date() else { return authError("expired_access_token") }
        // Team spaces: requests name the root namespace.
        if let pr = r.value(forHTTPHeaderField: "Dropbox-API-Path-Root") {
            _state.pathRootHeaders += 1
            let j = (try? JSON(data: Data(pr.utf8))) ?? .null
            guard let ns = _state.teamRootNamespace, j[".tag"].string == "root", j["root"].string == ns else {
                return json(422, ["error_summary": "invalid_root/..", "error": [".tag": "invalid_root", "invalid_root": [".tag": "user", "root_namespace_id": .string(_state.homeNamespace), "home_namespace_id": .string(_state.homeNamespace)]]])
            }
        } else if _state.teamRootNamespace != nil {
            _state.missingPathRoot += 1
        }
        if _state.throttleNext > 0 {
            _state.throttleNext -= 1
            return rateLimited("too_many_requests")
        }
        if writeRoutes.contains(route), _state.writeContentionNext > 0 {
            _state.writeContentionNext -= 1
            _state.contentions += 1
            return contention()
        }
        let contentType = r.value(forHTTPHeaderField: "Content-Type") ?? ""
        if host == apiHost {
            // RPC: JSON in the body, or nothing at all for routes without arguments.
            var arg = JSON.null
            if !body.isEmpty {
                guard contentType.hasPrefix("application/json") else {
                    return badInput(route, "Bad HTTP \"Content-Type\" header: \"\(contentType)\". Expecting one of \"application/json\", \"application/json; charset=utf-8\", \"text/plain; charset=dropbox-cors-hack\".")
                }
                guard let j = try? JSON(data: body) else { return badInput(route, "request body: could not decode input as JSON") }
                arg = j
            } else if !contentType.isEmpty {
                return badInput(route, "request body: could not decode input as JSON")
            }
            return rpc(route, arg)
        }
        // Content: the argument in Dropbox-API-Arg, which must be HTTP-header safe (ASCII).
        guard let raw = r.value(forHTTPHeaderField: "Dropbox-API-Arg") else { return badInput(route, "Missing Dropbox-API-Arg header.") }
        _state.argHeaders.append(raw)
        if raw.unicodeScalars.contains(where: { $0.value >= 0x7F }) {
            _state.nonASCIIArgHeaders += 1
            return badInput(route, "Dropbox-API-Arg header: non-ASCII characters must be escaped as \\uXXXX.")
        }
        guard let arg = try? JSON(data: Data(raw.utf8)), case .object = arg else { return badInput(route, "Dropbox-API-Arg: could not decode input as JSON") }
        switch route {
        case "files/download", "files/get_thumbnail_v2":
            guard body.isEmpty, contentType.isEmpty || contentType.hasPrefix("text/plain") else {
                return badInput(route, "Bad HTTP \"Content-Type\" header: \"\(contentType)\". Expecting one of \"text/plain\", \"text/plain; charset=utf-8\", \"application/octet-stream\", \"application/octet-stream; charset=utf-8\".")
            }
            return route == "files/download" ? download(arg) : thumbnail(arg)
        default:
            guard contentType == "application/octet-stream" else {
                return badInput(route, "Bad HTTP \"Content-Type\" header: \"\(contentType)\". Expecting one of \"application/octet-stream\", \"text/plain; charset=dropbox-cors-hack\".")
            }
            guard body.count <= maxRequestBody else { return .reply(413, ["Content-Type": "text/plain"], Data("Request body too large".utf8)) }
            switch route {
            case "files/upload": return upload(arg, body)
            case "files/upload_session/start": return sessionStart(arg, body)
            case "files/upload_session/append_v2": return sessionAppend(arg, body)
            case "files/upload_session/finish": return sessionFinish(arg, body)
            default: return .reply(404, ["Content-Type": "text/plain"], Data("Unknown endpoint".utf8))
            }
        }
    }

    // MARK: OAuth

    static func token(_ body: Data) -> Outcome {
        let f = form(body)
        _state.tokenRequestKeys.append(Set(f.keys))
        func bad(_ error: String, _ desc: String) -> Outcome { json(400, ["error": .string(error), "error_description": .string(desc)]) }
        guard f["client_id"] == _state.appKey else { return bad("invalid_client", "Invalid client_id or client_secret") }
        // Cirrus is a public client: an app secret must never leave it.
        if f["client_secret"] != nil { return bad("invalid_client", "This test app is a public client: no client_secret expected") }
        switch f["grant_type"] {
        case "authorization_code":
            guard let code = f["code"], let c = _state.codes.removeValue(forKey: code) else { return bad("invalid_grant", "code doesn't exist or has expired") }
            guard f["redirect_uri"] == c.redirect else { return bad("invalid_grant", "redirect_uri mismatch") }
            guard let challenge = c.challenge else { return bad("invalid_request", "No client secret or code verifier provided") }
            guard let v = f["code_verifier"], (43...128).contains(v.count), PKCE(verifier: v).challenge == challenge else {
                return bad("invalid_grant", "invalid code verifier")
            }
            return issue(scopes: c.scopes, refresh: c.offline ? _state.issueRefreshToken() : nil)
        case "refresh_token":
            guard let t = f["refresh_token"], _state.refreshTokens.contains(t) else { return bad("invalid_grant", "refresh token is invalid or revoked") }
            _state.refreshes += 1
            var next: String?
            if _state.rotateRefreshTokens {
                _state.refreshTokens.remove(t)
                next = _state.issueRefreshToken()
            }
            return issue(scopes: _state.appScopes, refresh: next)
        default:
            return bad("unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
        }
    }

    static func issue(scopes: Set<String>, refresh: String?) -> Outcome {
        let access = "sl.fake-dbx-access-" + UUID().uuidString
        _state.accessTokens[access] = Date().addingTimeInterval(_state.accessTTL)
        var out: [String: JSON] = ["access_token": .string(access), "token_type": "bearer", "expires_in": .number(_state.accessTTL),
                                   "scope": .string((_state.grantedScopes ?? scopes).sorted().joined(separator: " ")),
                                   "account_id": .string(_state.accountID), "uid": "1234567"]
        if let refresh { out["refresh_token"] = .string(refresh) }
        return json(200, .object(out))
    }

    // MARK: RPC routes

    static func rpc(_ route: String, _ a: JSON) -> Outcome {
        let s = _state
        switch route {
        case "users/get_current_account":
            guard a.isNull else { return badInput(route, "request body: expected null, got value") }
            let root: JSON = s.teamRootNamespace.map {
                [".tag": "team", "root_namespace_id": .string($0), "home_namespace_id": .string(s.homeNamespace), "home_path": .string("/" + s.displayName)]
            } ?? [".tag": "user", "root_namespace_id": .string(s.homeNamespace), "home_namespace_id": .string(s.homeNamespace)]
            let parts = s.displayName.split(separator: " ").map(String.init)
            return json(200, ["account_id": .string(s.accountID),
                              "name": ["given_name": .string(parts.first ?? ""), "surname": .string(parts.dropFirst().joined(separator: " ")),
                                       "familiar_name": .string(parts.first ?? ""), "display_name": .string(s.displayName),
                                       "abbreviated_name": .string(parts.compactMap(\.first).map(String.init).joined())],
                              "email": .string(s.email), "email_verified": true, "disabled": false, "locale": "en", "country": "US",
                              "referral_link": "https://www.dropbox.com/referrals/fake", "is_paired": false,
                              "account_type": [".tag": .string(s.teamRootNamespace == nil ? "basic" : "business")], "root_info": root])
        case "users/get_space_usage":
            guard a.isNull else { return badInput(route, "request body: expected null, got value") }
            let allocation: JSON
            if let t = s.team {
                allocation = [".tag": "team", "used": .int64(t.used), "allocated": .int64(t.allocated),
                              "user_within_team_space_allocated": .int64(t.memberLimit),
                              "user_within_team_space_limit_type": [".tag": .string(t.memberLimit > 0 ? "stop_sync" : "off")],
                              "user_within_team_space_used_cached": .int64(s.used)]
            } else {
                allocation = [".tag": "individual", "allocated": .int64(s.allocated)]
            }
            return json(200, ["used": .int64(s.used), "allocation": allocation])
        case "files/list_folder": return listFolder(a)
        case "files/list_folder/continue": return listContinue(a)
        case "files/get_metadata":
            guard let p = a["path"].string else { return badInput(route, "missing required field 'path'") }
            if p.isEmpty { return badInput(route, "request body: path: The root folder is unsupported.") }
            switch lookup(p) {
            case .item(let it): return json(200, meta(it, tagged: true))
            case .notFound: return routeError(["path", "not_found"])
            case .malformed, .root: return routeError(["path", "malformed_path"])
            }
        case "files/create_folder_v2": return createFolder(a)
        case "files/move_v2": return move(a)
        case "files/delete_v2": return delete(a)
        default:
            return .reply(404, ["Content-Type": "text/plain"], Data("Unknown endpoint".utf8))
        }
    }

    static func listFolder(_ a: JSON) -> Outcome {
        let route = "files/list_folder"
        guard let p = a["path"].string else { return badInput(route, "missing required field 'path'") }
        if a["recursive"].bool == true { return badInput(route, "recursive listing isn't supported by this fake") }
        if let l = a["limit"].int, !(1...2000).contains(l) { return badInput(route, "limit: value outside range") }
        let folder: String
        switch lookup(p) {
        case .root: folder = ""
        case .item(let it):
            guard it.isFolder else { return routeError(["path", "not_folder"]) }
            folder = it.id
        case .notFound: return routeError(["path", "not_found"])
        case .malformed: return routeError(["path", "malformed_path"])
        }
        let ids = _state.children(of: folder).sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }.map(\.id)
        let size = min(a["limit"].int ?? 2000, _state.pageSize)
        return page(Cursor(ids: ids, next: 0), size: size)
    }

    static func page(_ c: Cursor, size: Int) -> Outcome {
        var c = c
        let slice = Array(c.ids.dropFirst(c.next).prefix(size))
        c.next += slice.count
        let entries = slice.compactMap { _state.live($0) }.map { meta($0, tagged: true) }
        let cursor = "fake-cursor-" + UUID().uuidString
        _state.cursors[cursor] = Cursor(ids: c.ids, next: c.next)
        return json(200, ["entries": .array(entries), "cursor": .string(cursor), "has_more": .bool(c.next < c.ids.count)])
    }

    static func listContinue(_ a: JSON) -> Outcome {
        guard let cursor = a["cursor"].string, let c = _state.cursors[cursor] else { return badInput("files/list_folder/continue", "Invalid \"cursor\" parameter") }
        if _state.resetCursorsNext > 0 {
            _state.resetCursorsNext -= 1
            _state.cursors = [:]
            return routeError(["reset"])
        }
        return page(c, size: _state.pageSize)
    }

    static func createFolder(_ a: JSON) -> Outcome {
        let route = "files/create_folder_v2"
        guard let p = a["path"].string else { return badInput(route, "missing required field 'path'") }
        // WritePath: a path, not an id.
        guard p.hasPrefix("/") else { return badInput(route, "path: '\(p)' did not match pattern '(/(.|[\\r\\n])*)|(ns:[0-9]+(/.*)?)'") }
        let target = makeParent(p, route: route)
        if let e = target.error { return e }
        guard let parent = target.parent else { return routeError(["path", "malformed_path"]) }
        if let clash = _state.child(named: target.name, in: parent) {
            if a["autorename"].bool == true { return badInput(route, "autorename isn't supported by this fake") }
            return routeError(["path", "conflict", clash.isFolder ? "folder" : "file"])
        }
        let id = _state.add(target.name, parent: parent, folder: true, modified: Date())
        return json(200, ["metadata": meta(_state.items[id]!, tagged: false)])
    }

    static func move(_ a: JSON) -> Outcome {
        let route = "files/move_v2"
        guard let from = a["from_path"].string, let to = a["to_path"].string else { return badInput(route, "missing from_path or to_path") }
        guard a["autorename"].bool != true else { return badInput(route, "autorename isn't supported by this fake") }
        let item: Item
        switch lookup(from) {
        case .item(let it): item = it
        case .notFound: return routeError(["from_lookup", "not_found"])
        case .root, .malformed: return routeError(["from_lookup", "malformed_path"])
        }
        guard to.hasPrefix("/") else { return routeError(["to", "malformed_path"]) }
        if _state.path(of: item.id) == to { return routeError(["duplicated_or_nested_paths"]) }
        // Where it would go, without creating anything yet.
        let parentPath = String(to[..<to.lastIndex(of: "/")!])
        if item.isFolder, case .item(let dest) = lookup(parentPath), _state.isInside(dest.id, item.id) {
            return routeError(["cant_move_folder_into_itself"])
        }
        let target = makeParent(to, route: route)
        if let e = target.error { return e }
        guard let parent = target.parent else { return routeError(["to", "malformed_path"]) }
        if let clash = _state.child(named: target.name, in: parent), clash.id != item.id {
            return routeError(["to", "conflict", clash.isFolder ? "folder" : "file"])
        }
        var it = item
        it.parent = parent
        it.name = target.name
        if !it.isFolder { it.rev = _state.newRev(); it.serverModified = Date() }
        _state.items[it.id] = it
        return json(200, ["metadata": meta(it, tagged: true)])
    }

    static func delete(_ a: JSON) -> Outcome {
        guard let p = a["path"].string else { return badInput("files/delete_v2", "missing required field 'path'") }
        switch lookup(p) {
        case .item(let it):
            let m = meta(it, tagged: true)
            _state.items[it.id]?.deleted = true
            return json(200, ["metadata": m])
        case .notFound: return routeError(["path_lookup", "not_found"])
        case .root, .malformed: return routeError(["path_lookup", "malformed_path"])
        }
    }

    // MARK: Content routes

    static func download(_ a: JSON) -> Outcome {
        guard let p = a["path"].string else { return badInput("files/download", "missing required field 'path'") }
        guard case .item(let it) = lookup(p) else { return routeError(["path", "not_found"]) }
        guard !it.isFolder else { return routeError(["path", "not_file"]) }
        guard it.downloadable else { return routeError(["unsupported_file"]) }
        if _state.dropDownloadsNext > 0 {
            _state.dropDownloadsNext -= 1
            return .drop
        }
        _state.downloads += 1
        let data = _state.blobs[it.id] ?? Data()
        return .reply(200, ["Content-Type": "application/octet-stream", "Content-Length": String(data.count),
                            "Dropbox-API-Result": DropboxHTTP.headerSafe(meta(it, tagged: false))], data)
    }

    static func thumbnail(_ a: JSON) -> Outcome {
        let route = "files/get_thumbnail_v2"
        _state.thumbnailArgs.append(a)
        let sizes: Set = ["w32h32", "w64h64", "w128h128", "w256h256", "w480h320", "w640h480", "w960h640", "w1024h768", "w2048h1536"]
        guard a["resource"][".tag"].string == "path", let p = a["resource"]["path"].string else { return badInput(route, "resource: expected path") }
        guard sizes.contains(a["size"].string ?? "w64h64"), ["jpeg", "png"].contains(a["format"].string ?? "jpeg"),
              ["strict", "bestfit", "fitone_bestfit"].contains(a["mode"].string ?? "strict") else { return badInput(route, "unknown size, format or mode") }
        guard case .item(let it) = lookup(p) else { return routeError(["path", "not_found"]) }
        let ext = (it.name as NSString).pathExtension.lowercased()
        guard !it.isFolder, thumbnailExtensions.contains(ext) else { return routeError(["unsupported_extension"]) }
        let data = _state.blobs[it.id] ?? Data()
        let isImage = data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard isImage else { return routeError(["unsupported_image"]) }
        return .reply(200, ["Content-Type": a["format"].string == "png" ? "image/png" : "image/jpeg",
                            "Dropbox-API-Result": DropboxHTTP.headerSafe(meta(it, tagged: false))], data)
    }

    /// Mode "add" (the default), "overwrite" or "update". Returns the stored item, or the error to answer.
    static func commit(_ c: JSON, data: Data, route: String) -> (Item?, Outcome?) {
        guard let p = c["path"].string else { return (nil, badInput(route, "missing required field 'path'")) }
        guard p.hasPrefix("/") else { return (nil, badInput(route, "path: this fake only accepts paths")) }
        let mode = c["mode"].string ?? c["mode"][".tag"].string ?? "add"
        guard ["add", "overwrite"].contains(mode) else { return (nil, badInput(route, "mode: unsupported by this fake")) }
        guard c["autorename"].bool != true else { return (nil, badInput(route, "autorename isn't supported by this fake")) }
        var modified = Date()
        if let cm = c["client_modified"].string {
            guard timestampOK(cm), let d = JSON.string(cm).date else { return (nil, badInput(route, "client_modified: '\(cm)' is not a valid timestamp")) }
            modified = d
        }
        guard _state.used + Int64(data.count) <= (_state.team?.allocated ?? _state.allocated) else {
            return (nil, routeError(["path", "insufficient_space"]))
        }
        let target = makeParent(p, route: route)
        if let e = target.error { return (nil, e) }
        guard let parent = target.parent else { return (nil, routeError(["path", "malformed_path"])) }
        if let clash = _state.child(named: target.name, in: parent) {
            guard !clash.isFolder else { return (nil, routeError(["path", "conflict", "folder"])) }
            if mode == "overwrite" {
                _state.blobs[clash.id] = data
                let rev = _state.newRev()
                _state.items[clash.id]?.rev = rev
                _state.items[clash.id]?.clientModified = modified
                _state.items[clash.id]?.serverModified = Date()
                return (_state.items[clash.id], nil)
            }
            // Without strict_conflict, Dropbox treats the same bytes at the same path as success.
            if c["strict_conflict"].bool != true, _state.blobs[clash.id] == data { return (clash, nil) }
            return (nil, routeError(["path", "conflict", "file"]))
        }
        let id = _state.add(target.name, parent: parent, folder: false, data: data, modified: modified)
        _state.items[id]?.serverModified = Date()
        return (_state.items[id], nil)
    }

    static func upload(_ a: JSON, _ body: Data) -> Outcome {
        _state.lastCommit = a
        let (item, error) = commit(a, data: body, route: "files/upload")
        if let error { return error }
        _state.simpleUploads += 1
        if _state.loseUploadAnswers > 0 { _state.loseUploadAnswers -= 1; return .drop }
        return json(200, meta(item!, tagged: false))
    }

    static func sessionStart(_ a: JSON, _ body: Data) -> Outcome {
        let sid = "fake-session-" + UUID().uuidString
        _state.sessions[sid] = Session(data: body, closed: a["close"].bool == true)
        _state.sessionsStarted += 1
        return json(200, ["session_id": .string(sid)])
    }

    static func sessionAppend(_ a: JSON, _ body: Data) -> Outcome {
        guard let sid = a["cursor"]["session_id"].string, let offset = a["cursor"]["offset"].int64 else {
            return badInput("files/upload_session/append_v2", "missing cursor")
        }
        guard var s = _state.sessions[sid] else { return routeError(["not_found"]) }
        guard !s.closed else { return routeError(["closed"]) }
        guard offset == Int64(s.data.count) else { return routeError(["incorrect_offset"], ["correct_offset": .int64(Int64(s.data.count))]) }
        _state.appendCount += 1
        if _state.dropAppendBeforeStore == _state.appendCount { return .drop }
        s.data.append(body)
        s.closed = a["close"].bool == true
        _state.sessions[sid] = s
        _state.appends.append((offset, body.count))
        if _state.loseAppendAnswer == _state.appendCount { return .drop }
        return json(200, .null)
    }

    static func sessionFinish(_ a: JSON, _ body: Data) -> Outcome {
        let route = "files/upload_session/finish"
        guard let sid = a["cursor"]["session_id"].string, let offset = a["cursor"]["offset"].int64 else { return badInput(route, "missing cursor") }
        _state.lastCommit = a["commit"]
        guard var s = _state.sessions[sid] else { return routeError(["lookup_failed", "not_found"]) }
        guard offset == Int64(s.data.count) else {
            return routeError(["lookup_failed", "incorrect_offset"], ["correct_offset": .int64(Int64(s.data.count))])
        }
        s.data.append(body)
        let (item, error) = commit(a["commit"], data: s.data, route: route)
        if let error { return error }
        _state.sessions[sid] = nil
        _state.finishes += 1
        if _state.loseUploadAnswers > 0 { _state.loseUploadAnswers -= 1; return .drop }
        return json(200, meta(item!, tagged: false))
    }
}
#endif
