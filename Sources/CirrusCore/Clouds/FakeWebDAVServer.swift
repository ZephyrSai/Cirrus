#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A stateful stand-in for a Nextcloud server (cloud.example.com) and a plain Apache-style WebDAV server
/// (dav.example.com), served through URLProtocol. Unit tests use it as the mock server; Debug builds in demo mode
/// (CIRRUS_DEMO=1) use it for the demo Nextcloud and WebDAV accounts. It is strict about the wire protocol so it
/// catches client mistakes: Depth headers, 207 Multi-Status XML with 404 propstats for unknown properties, ETags,
/// Destination/Overwrite on MOVE, If-None-Match on PUT, Nextcloud's chunked upload v2 (Destination on every request,
/// numbered chunks of at least 5 MiB, OC-Total-Length), Login Flow v2, the trash bin, the preview endpoint, quota
/// properties, and Basic auth with 401. Not compiled into release builds.
public final class FakeWebDAVServer: URLProtocol, @unchecked Sendable {
    public struct Item: Codable, Sendable {
        public var isFolder: Bool
        public var data: Data
        public var modified: Date
        public var created: Date
        public var etag: String
        public var fileID: Int
        public var contentType: String
    }

    /// One entry of Nextcloud's trash bin: the deleted item and (for a folder) what was inside it.
    public struct TrashEntry: Codable, Sendable {
        public var name: String
        /// The original parent folder, relative to the user's files ("Documents", or "" for the top).
        public var location: String
        public var deleted: Int
        /// "" is the deleted item itself; "sub/" and "sub/x.txt" are its contents.
        public var items: [String: Item]
        public var isFolder: Bool { items[""]?.isFolder ?? false }
    }

    public struct Account: Codable, Sendable {
        public var loginName: String
        public var uid: String
        public var password: String
        public var appPasswords: [String] = []
        /// "/" is the top folder; folders end in "/". Keys are NFC.
        public var files: [String: Item] = [:]
        public var trash: [String: TrashEntry] = [:]
        /// Bytes; nil = unlimited.
        public var quota: Int64?
        public var displayName = "Alex Morgan"

        public init(loginName: String, uid: String, password: String) {
            self.loginName = loginName; self.uid = uid; self.password = password
            files["/"] = Item(isFolder: true, data: Data(), modified: Date(timeIntervalSince1970: 1_790_000_000),
                              created: Date(timeIntervalSince1970: 1_790_000_000), etag: FakeWebDAVServer.newETag(), fileID: 1, contentType: "")
        }

        public func item(_ path: String) -> Item? { files[path.precomposedStringWithCanonicalMapping] }
        public var usedBytes: Int64 { files.values.reduce(0) { $0 + ($1.isFolder ? 0 : Int64($1.data.count)) } }
    }

    public enum HrefStyle: String, Codable, Sendable { case path, absoluteURL, relative }

    struct Upload { var destination: String; var chunks: [Int: Data] = [:] }
    struct Flow { var loginID: String; var polls = 0; var approved = false }

    public struct State: Sendable {
        public var nextcloudHost = "cloud.example.com"
        /// For a Nextcloud installed in a subfolder ("/nextcloud").
        public var nextcloudBasePath = ""
        public var davHost = "dav.example.com"
        /// The plain server's WebDAV folder.
        public var davRootPath = "/webdav/"
        public var nextcloud = Account(loginName: "alex", uid: "alex", password: "nextcloud-password")
        public var plain = Account(loginName: "alex", uid: "alex", password: "webdav-password")
        public var trashbinEnabled = true
        /// status.php answers 404 (some hosts block it).
        public var hideStatusPage = false
        public var hrefStyle: HrefStyle = .path
        /// Hrefs spell names in decomposed Unicode (as some servers on Apple file systems do).
        public var hrefNFD = false
        /// Depth-1 listings include the folder itself (RFC 4918; on by default).
        public var echoSelf = true
        /// The plain server reports quota properties.
        public var plainHasQuota = false
        /// The plain server's file system ignores case (Apache on APFS).
        public var plainCaseInsensitive = false
        /// Login Flow v2: the user approves in the browser after this many polls (nil: only via `approve`).
        public var approveAfterPolls: Int? = 2
        /// Smallest chunk Nextcloud accepts in a chunked upload, except the last one.
        public var minChunkSize = 5 * 1024 * 1024
        public var latency: Double = 0
        // Fault injection
        /// PROPFIND on these paths (relative to the user's files, e.g. "/Documents/") answers 500.
        public var failPropfind: Set<String> = []
        /// PROPFIND on these paths answers 207 with a cut-off body.
        public var truncatePropfind: Set<String> = []
        /// The next N requests get 429 with Retry-After: 0.
        public var rateLimitNext = 0
        /// The next N requests get 503 with Retry-After: 0.
        public var unavailableNext = 0
        /// Nextcloud: paths shared with others (oc:share-types lists a link share).
        public var sharedPaths: Set<String> = []
        /// Paths (relative to the user's files) that are locked (423).
        public var lockedPaths: Set<String> = []
        // Statistics for tests
        public var calls: [String] = []
        public var permanentDeletes = 0
        public var chunkPuts = 0
        public var chunkAssemblies = 0
        public var previewRequests = 0
        public var loginPolls = 0
        public var unauthorized = 0
        public var lastUserAgent: String?
        var uploads: [String: Upload] = [:]
        var flows: [String: Flow] = [:]
        var nextFileID = 100

        public init() {}

        public func file(_ path: String, plain: Bool = false) -> Item? { (plain ? self.plain : nextcloud).item(path) }

        /// Adds a file (and its folders) to an account. `path` like "/Documents/a.txt".
        public mutating func add(_ path: String, _ data: Data, plain: Bool = false, modified: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
            let kp: WritableKeyPath<State, Account> = plain ? \.plain : \.nextcloud
            let p = path.precomposedStringWithCanonicalMapping
            var folder = "/"
            for seg in p.split(separator: "/").dropLast() {
                folder += seg + "/"
                if self[keyPath: kp].files[folder] == nil { let it = newItem(folder: true, modified: modified); self[keyPath: kp].files[folder] = it }
            }
            if p.hasSuffix("/") {
                if self[keyPath: kp].files[p] == nil { let it = newItem(folder: true, modified: modified); self[keyPath: kp].files[p] = it }
            } else {
                var it = newItem(folder: false, modified: modified)
                it.data = data
                it.contentType = FakeWebDAVServer.mime(p)
                self[keyPath: kp].files[p] = it
            }
        }

        public mutating func addFolder(_ path: String, plain: Bool = false) { add(path.hasSuffix("/") ? path : path + "/", Data(), plain: plain) }

        mutating func newItem(folder: Bool, modified: Date = Date()) -> Item {
            nextFileID += 1
            return Item(isFolder: folder, data: Data(), modified: modified, created: modified, etag: FakeWebDAVServer.newETag(), fileID: nextFileID,
                        contentType: folder ? "" : "application/octet-stream")
        }

        /// The demo content (also a good starting point for tests).
        public static func seeded() -> State {
            var s = State()
            FakeWebDAVServer.seed(&s)
            return s
        }
    }

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

    public static let demoNextcloudPassword = "demo-app-password-nextcloud"
    public static let demoWebDAVPassword = "demo-password"

    /// Demo mode: seeded accounts, kept on disk in `storage` (nil: in memory only). Starts once.
    public static func startDemo(storage dir: URL?) {
        lock.withLock {
            guard !demoStarted else { return }
            demoStarted = true
            var s = State.seeded()
            s.latency = ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] != nil ? 0 : 0.02
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("webdav-state-v1.json")
                persistURL = url
                if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: d) {
                    s.nextcloud = saved.nextcloud
                    s.plain = saved.plain
                    s.nextFileID = max(s.nextFileID, saved.nextFileID)
                }
            }
            if !s.nextcloud.appPasswords.contains(demoNextcloudPassword) { s.nextcloud.appPasswords.append(demoNextcloudPassword) }
            s.plain.password = demoWebDAVPassword
            _state = s
        }
    }

    /// The demo account records (stable ids) and their passwords.
    public static func demoAccount(_ p: CloudProvider) -> (record: CloudAccountRecord, password: String) {
        let (ncHost, davHost, base, root, ncUser, davUser) = lock.withLock {
            (_state.nextcloudHost, _state.davHost, _state.nextcloudBasePath, _state.davRootPath, _state.nextcloud.loginName, _state.plain.loginName)
        }
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        if p == .nextcloud {
            return (CloudAccountRecord(id: "cloud:nextcloud:demo", provider: .nextcloud, title: "\(ncUser)@\(ncHost)",
                                       server: "https://\(ncHost)\(base)", username: ncUser, added: added), demoNextcloudPassword)
        }
        return (CloudAccountRecord(id: "cloud:webdav:demo", provider: .webdav, title: "\(davUser)@\(davHost)",
                                   server: "https://\(davHost)\(encodeLoose(root))", username: davUser, added: added), demoWebDAVPassword)
    }

    struct Saved: Codable { var nextcloud: Account; var plain: Account; var nextFileID: Int }

    static func persist() {
        guard let url = persistURL else { return }
        let saved = Saved(nextcloud: _state.nextcloud, plain: _state.plain, nextFileID: _state.nextFileID)
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: url, options: .atomic) }
    }

    /// Plays the user approving Cirrus on the login page the app opened.
    public static func approve(_ loginURL: URL) {
        let id = loginURL.lastPathComponent
        update { s in
            for (k, f) in s.flows where f.loginID == id { s.flows[k]?.approved = true }
        }
    }

    // MARK: URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let h = request.url?.host?.lowercased() else { return false }
        return lock.withLock { h == _state.nextcloudHost || h == _state.davHost }
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
            if req.httpMethod != "HEAD" && !data.isEmpty {
                // In pieces, like a network, so download progress gets reported.
                var i = 0
                while i < data.count {
                    let n = min(256 * 1024, data.count - i)
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

    // MARK: Helpers

    static func newETag() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }

    static func mime(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func previewable(_ it: Item) -> Bool {
        !it.isFolder && (it.contentType.hasPrefix("image/") || it.contentType == "application/pdf" || it.contentType.hasPrefix("text/"))
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Like PHP's rawurlencode (Sabre/Nextcloud).
    static func encodeStrict(_ path: String) -> String { DAVURL.encodePath(path) }

    /// Like Apache: only what must be encoded (keeps & + ' ( ) = , ; @ …).
    static func encodeLoose(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        // CharacterSet.urlPathAllowed includes non-ASCII letters; keep only ASCII raw.
        return path.unicodeScalars.map { u -> String in
            if u.isASCII && allowed.contains(u) { return String(u) }
            return String(u).addingPercentEncoding(withAllowedCharacters: CharacterSet()) ?? String(u)
        }.joined()
    }

    static func basic(_ r: URLRequest) -> (String, String)? {
        guard let h = r.value(forHTTPHeaderField: "Authorization"), h.hasPrefix("Basic "),
              let d = Data(base64Encoded: String(h.dropFirst(6))), let s = String(data: d, encoding: .utf8),
              let i = s.firstIndex(of: ":") else { return nil }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    static func authorized(_ r: URLRequest, _ a: Account, nextcloud: Bool) -> Bool {
        guard let (u, p) = basic(r), u == a.loginName else { return false }
        return p == a.password || (nextcloud && a.appPasswords.contains(p))
    }

    static func sabreError(_ status: Int, _ exception: String, _ message: String) -> Outcome {
        let body = #"<?xml version="1.0" encoding="utf-8"?>"# + "\n"
            + #"<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">"#
            + "<s:exception>Sabre\\DAV\\Exception\\\(exception)</s:exception><s:message>\(xml(message))</s:message></d:error>"
        return .reply(status, ["Content-Type": "application/xml; charset=utf-8"], Data(body.utf8))
    }

    static func apacheError(_ status: Int, _ title: String) -> Outcome {
        let body = "<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n<html><head><title>\(status) \(title)</title></head><body><h1>\(title)</h1></body></html>\n"
        return .reply(status, ["Content-Type": "text/html; charset=iso-8859-1"], Data(body.utf8))
    }

    static func fail(_ status: Int, _ message: String, plain: Bool) -> Outcome {
        if plain { return apacheError(status, message) }
        let ex: String
        switch status {
        case 400: ex = "BadRequest"
        case 401: ex = "NotAuthenticated"
        case 403: ex = "Forbidden"
        case 404: ex = "NotFound"
        case 405: ex = "MethodNotAllowed"
        case 409: ex = "Conflict"
        case 412: ex = "PreconditionFailed"
        case 415: ex = "UnsupportedMediaType"
        case 423: ex = "Locked"
        case 507: ex = "InsufficientStorage"
        default: ex = "ServiceUnavailable"
        }
        return sabreError(status, ex, message)
    }

    static func unauthorized(plain: Bool) -> Outcome {
        _state.unauthorized += 1
        let realm = plain ? "WebDAV" : "Nextcloud"
        if case .reply(_, var h, let d) = fail(401, "No public access to this resource., No 'Authorization: Basic' header found.", plain: plain) {
            h["WWW-Authenticate"] = "Basic realm=\"\(realm)\", charset=\"UTF-8\""
            return .reply(401, h, d)
        }
        return .reply(401, [:], Data())
    }

    static func json(_ status: Int, _ j: JSON) -> Outcome { .reply(status, ["Content-Type": "application/json; charset=utf-8"], j.data()) }

    static func query(_ u: URL) -> [String: String] {
        var q = [String: String]()
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return q
    }

    static func form(_ d: Data) -> [String: String] {
        var out = [String: String]()
        for pair in (String(data: d, encoding: .utf8) ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    // MARK: Routing

    struct Ctx {
        var plain: Bool
        var host: String
        /// Encoded path of the files root as it appears in hrefs ("/remote.php/dav/files/alex/").
        var rootHref: String
        /// Encoded path of this request.
        var requestPath: String
        var account: WritableKeyPath<State, Account>
    }

    static func handle(_ r: URLRequest, body: Data) -> Outcome {
        guard let url = r.url, let host = url.host?.lowercased() else { return apacheError(400, "Bad Request") }
        let method = r.httpMethod ?? "GET"
        let encPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = encPath.removingPercentEncoding ?? encPath
        if _state.calls.count > 20_000 { _state.calls.removeFirst(10_000) }   // demo sessions run long
        _state.calls.append("\(method) \(path)")
        _state.lastUserAgent = r.value(forHTTPHeaderField: "User-Agent")
        if _state.rateLimitNext > 0 {
            _state.rateLimitNext -= 1
            return .reply(429, ["Retry-After": "0", "Content-Type": "text/plain"], Data("Too Many Requests".utf8))
        }
        if _state.unavailableNext > 0 {
            _state.unavailableNext -= 1
            return .reply(503, ["Retry-After": "0", "Content-Type": "text/plain"], Data("Service Unavailable".utf8))
        }
        let out: Outcome
        if host == _state.nextcloudHost {
            out = nextcloud(method, url, path, encPath, r, body)
        } else {
            out = plainServer(method, path, encPath, r, body)
        }
        if ["PUT", "MKCOL", "MOVE", "DELETE", "COPY"].contains(method) { persist() }
        return out
    }

    static func plainServer(_ method: String, _ path: String, _ encPath: String, _ r: URLRequest, _ body: Data) -> Outcome {
        let root = _state.davRootPath
        if path == "/status.php" { return apacheError(404, "Not Found") }
        let rootNoSlash = String(root.dropLast())
        guard path.hasPrefix(root) || path == rootNoSlash else { return apacheError(404, "Not Found") }
        guard authorized(r, _state.plain, nextcloud: false) else { return unauthorized(plain: true) }
        if path == rootNoSlash { return .reply(301, ["Location": "https://\(_state.davHost)\(encodeLoose(root))"], Data()) }
        let rel = "/" + path.dropFirst(root.count)
        let ctx = Ctx(plain: true, host: _state.davHost, rootHref: encodeLoose(root), requestPath: encPath, account: \.plain)
        return files(method, rel, r, body, ctx)
    }

    static func nextcloud(_ method: String, _ url: URL, _ fullPath: String, _ encPath: String, _ r: URLRequest, _ body: Data) -> Outcome {
        let base = _state.nextcloudBasePath
        guard fullPath.hasPrefix(base) else { return fail(404, "Not found", plain: false) }
        let path = String(fullPath.dropFirst(base.count))
        let uid = _state.nextcloud.uid
        let host = _state.nextcloudHost
        if path == "/status.php" {
            if _state.hideStatusPage { return fail(404, "Not found", plain: false) }
            return json(200, ["installed": true, "maintenance": false, "needsDbUpgrade": false, "version": "30.0.2.2", "versionstring": "30.0.2",
                              "edition": "", "productname": "Nextcloud", "extendedSupport": false])
        }
        if path == "/index.php/login/v2" {
            guard method == "POST" else { return fail(405, "Method not allowed", plain: false) }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let loginID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            _state.flows[token] = Flow(loginID: loginID)
            return json(200, ["poll": ["token": .string(token), "endpoint": .string("https://\(host)\(base)/login/v2/poll")],
                              "login": .string("https://\(host)\(base)/login/v2/flow/\(loginID)")])
        }
        if path == "/login/v2/poll" || path == "/index.php/login/v2/poll" {
            guard method == "POST" else { return fail(405, "Method not allowed", plain: false) }
            _state.loginPolls += 1
            guard let token = form(body)["token"], var f = _state.flows[token] else { return json(404, [:]) }
            f.polls += 1
            if !f.approved, let n = _state.approveAfterPolls, f.polls >= n { f.approved = true }
            guard f.approved else { _state.flows[token] = f; return json(404, [:]) }
            _state.flows[token] = nil    // a token works once
            let app = "app-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            _state.nextcloud.appPasswords.append(app)
            return json(200, ["server": .string("https://\(host)\(base)"), "loginName": .string(_state.nextcloud.loginName), "appPassword": .string(app)])
        }
        if path.hasPrefix("/login/v2/flow/") { return .reply(200, ["Content-Type": "text/html"], Data("<html>Connect to your account</html>".utf8)) }
        if path == "/index.php/core/preview" { return preview(method, url, r) }

        guard path.hasPrefix("/remote.php/") else { return fail(404, "Not found", plain: false) }
        guard authorized(r, _state.nextcloud, nextcloud: true) else { return unauthorized(plain: false) }
        let encBase = encodeStrict(base)
        if path == "/remote.php/dav" || path == "/remote.php/dav/" {
            guard method == "PROPFIND" else { return fail(405, "Method not allowed", plain: false) }
            guard r.value(forHTTPHeaderField: "Depth") != nil else { return fail(400, "Cirrus always sends a Depth header", plain: false) }
            let href = xml(encBase + "/remote.php/dav/")
            let principal = xml(encBase + "/remote.php/dav/principals/users/" + encodeStrict(uid) + "/")
            let x = multistatusHead(plain: false) + "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>"
                + "<d:current-user-principal><d:href>\(principal)</d:href></d:current-user-principal></d:prop>"
                + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
            return .reply(207, ["Content-Type": "application/xml; charset=utf-8"], Data(x.utf8))
        }
        let filesPrefix = "/remote.php/dav/files/"
        if path.hasPrefix(filesPrefix) {
            let rest = path.dropFirst(filesPrefix.count)
            let user = rest.prefix { $0 != "/" }
            guard String(user) == uid else { return fail(404, "Principal with name \(user) not found", plain: false) }
            let rel = rest.dropFirst(user.count)
            let ctx = Ctx(plain: false, host: host, rootHref: encBase + filesPrefix + encodeStrict(uid) + "/", requestPath: encPath, account: \.nextcloud)
            return files(method, rel.isEmpty ? "/" : String(rel), r, body, ctx)
        }
        if path.hasPrefix("/remote.php/webdav") {
            let rel = path.dropFirst("/remote.php/webdav".count)
            let ctx = Ctx(plain: false, host: host, rootHref: encBase + "/remote.php/webdav/", requestPath: encPath, account: \.nextcloud)
            return files(method, rel.isEmpty ? "/" : String(rel), r, body, ctx)
        }
        let trashPrefix = "/remote.php/dav/trashbin/" + uid + "/trash"
        if path.hasPrefix("/remote.php/dav/trashbin/") {
            guard _state.trashbinEnabled else { return fail(404, "File with name trashbin could not be located", plain: false) }
            guard path.hasPrefix(trashPrefix) else { return fail(404, "Not found", plain: false) }
            let rel = path.dropFirst(trashPrefix.count)
            return trashbin(method, rel.isEmpty ? "/" : String(rel), r, body, encPath, encBase)
        }
        let uploadsPrefix = "/remote.php/dav/uploads/" + uid + "/"
        if path.hasPrefix(uploadsPrefix) { return uploads(method, String(path.dropFirst(uploadsPrefix.count)), r, body) }
        return fail(404, "Not found", plain: false)
    }

    // MARK: Files

    static func find(_ files: [String: Item], _ path: String, ci: Bool) -> String? {
        let p = nfc(path)
        if files[p] != nil { return p }
        if !p.hasSuffix("/"), files[p + "/"] != nil { return p + "/" }
        if p.hasSuffix("/"), p != "/", files[String(p.dropLast())] != nil { return nil }
        guard ci else { return nil }
        let l = p.lowercased(), lf = (p.hasSuffix("/") ? p : p + "/").lowercased()
        return files.keys.first { $0.lowercased() == l || $0.lowercased() == lf }
    }

    static func children(_ files: [String: Item], of folder: String) -> [String] {
        files.keys.filter { k in
            guard k != folder, k.hasPrefix(folder) else { return false }
            let rest = k.dropFirst(folder.count)
            let trimmed = rest.hasSuffix("/") ? rest.dropLast() : rest
            return !trimmed.isEmpty && !trimmed.contains("/")
        }.sorted()
    }

    static func subtree(_ files: [String: Item], _ key: String) -> [String] {
        key.hasSuffix("/") ? files.keys.filter { $0.hasPrefix(key) } : [key]
    }

    static func parentKey(_ p: String) -> String { DAVURL.parent(of: p) ?? "/" }

    static func isLocked(_ key: String) -> Bool {
        _state.lockedPaths.contains { nfc($0) == key || nfc($0) + "/" == key }
    }

    static func href(_ ctx: Ctx, _ key: String, isFolder: Bool) -> String {
        var k = key
        if _state.hrefNFD { k = k.decomposedStringWithCanonicalMapping }
        if isFolder && !k.hasSuffix("/") { k += "/" }
        let rel = String(k.dropFirst())
        let encRel = ctx.plain ? encodeLoose(rel) : encodeStrict(rel)
        let full = ctx.rootHref + encRel
        switch _state.hrefStyle {
        case .path: return full
        case .absoluteURL: return "https://\(ctx.host)" + full
        case .relative:
            // Relative to the folder of the request (RFC 3986 reference).
            let reqDir = ctx.requestPath.hasSuffix("/") ? ctx.requestPath : String(ctx.requestPath[...(ctx.requestPath.lastIndex(of: "/")!)])
            if full.hasPrefix(reqDir) {
                let r = String(full.dropFirst(reqDir.count))
                return r.isEmpty ? "./" : r
            }
            return full
        }
    }

    static func multistatusHead(plain: Bool) -> String {
        plain
            ? #"<?xml version="1.0" encoding="utf-8"?>"# + "\n" + #"<D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">"#
            : #"<?xml version="1.0"?>"# + "\n" + #"<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">"#
    }

    /// The properties a PROPFIND asked for (nil: allprop / empty body). Throws on malformed XML.
    final class PropRequest: NSObject, XMLParserDelegate {
        var props: [(ns: String, name: String)] = []
        var all = false
        var depth = 0
        var inProp = false
        var sawRoot = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth == 1 { sawRoot = elementName == "propfind" }
            if elementName == "allprop" { all = true }
            if inProp && depth == 3 { props.append((namespaceURI ?? "", elementName)) }
            if elementName == "prop" && depth == 2 { inProp = true }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "prop" && depth == 2 { inProp = false }
            depth -= 1
        }
    }

    static func requestedProps(_ body: Data) -> (ok: Bool, props: [(ns: String, name: String)]?) {
        if body.isEmpty { return (true, nil) }
        let p = PropRequest()
        let x = XMLParser(data: body)
        x.shouldProcessNamespaces = true
        x.delegate = p
        guard x.parse(), p.sawRoot else { return (false, nil) }
        return (true, p.all ? nil : p.props)
    }

    static let defaultProps: [(ns: String, name: String)] = [("DAV:", "resourcetype"), ("DAV:", "getcontentlength"), ("DAV:", "getlastmodified"),
                                                             ("DAV:", "getetag"), ("DAV:", "getcontenttype"), ("DAV:", "creationdate")]

    /// Property values (inner XML) for one item.
    static func values(_ it: Item, key: String, ctx: Ctx, isTop: Bool, trash: (name: String, location: String, deleted: Int)? = nil) -> [String: String] {
        let D = ctx.plain ? "D:" : "d:"
        var v: [String: String] = [
            "DAV: resourcetype": it.isFolder ? "<\(D)collection/>" : "",
            "DAV: getlastmodified": DAVDates.httpString(it.modified),
            "DAV: getetag": xml("\"\(it.etag)\""),
            "DAV: creationdate": DAVDates.isoString(it.created),
        ]
        if !it.isFolder {
            v["DAV: getcontentlength"] = String(it.data.count)
            v["DAV: getcontenttype"] = xml(it.contentType)
        }
        let acct = _state[keyPath: ctx.account]
        if it.isFolder && (!ctx.plain || _state.plainHasQuota) && trash == nil {
            let used = acct.usedBytes
            v["DAV: quota-used-bytes"] = String(used)
            v["DAV: quota-available-bytes"] = acct.quota.map { String(max(0, $0 - used)) } ?? "-3"
        }
        if !ctx.plain {
            let size = it.isFolder ? acct.files.filter { $0.key.hasPrefix(key) && !$0.value.isFolder }.reduce(0) { $0 + $1.value.data.count } : it.data.count
            v["http://owncloud.org/ns fileid"] = String(it.fileID)
            v["http://owncloud.org/ns id"] = String(format: "%08docfake", it.fileID)
            v["http://owncloud.org/ns size"] = String(size)
            v["http://owncloud.org/ns permissions"] = it.isFolder ? "RGDNVCK" : "RGDNVW"
            v["http://owncloud.org/ns share-types"] = _state.sharedPaths.contains { nfc($0) == key } ? "<oc:share-type>3</oc:share-type>" : ""
            v["http://nextcloud.org/ns has-preview"] = previewable(it) ? "true" : "false"
            if let t = trash {
                v["http://nextcloud.org/ns trashbin-filename"] = xml(t.name)
                v["http://nextcloud.org/ns trashbin-original-location"] = xml(t.location.isEmpty ? t.name : t.location + "/" + t.name)
                v["http://nextcloud.org/ns trashbin-deletion-time"] = String(t.deleted)
            }
        }
        return v
    }

    static func responseXML(_ href: String, _ values: [String: String], requested: [(ns: String, name: String)]?, plain: Bool) -> String {
        let want = requested ?? defaultProps
        var found = [String](), missing = [String]()
        let prefixes = ["DAV:": plain ? "lp1" : "d", "http://owncloud.org/ns": "oc", "http://nextcloud.org/ns": "nc"]
        for (ns, name) in want {
            let known = plain ? (ns == "DAV:" ? "lp1" : nil) : prefixes[ns]
            let open: String, close: String, empty: String
            if let p = known {
                open = "<\(p):\(name)>"; close = "</\(p):\(name)>"; empty = "<\(p):\(name)/>"
            } else {
                open = "<x:\(name) xmlns:x=\"\(xml(ns))\">"; close = "</x:\(name)>"; empty = "<x:\(name) xmlns:x=\"\(xml(ns))\"/>"
            }
            if let val = values[ns + " " + name] { found.append(val.isEmpty ? empty : open + val + close) } else { missing.append(empty) }
        }
        let D = plain ? "D" : "d"
        var s = plain ? "<D:response xmlns:lp1=\"DAV:\" xmlns:lp2=\"http://apache.org/dav/props/\">" : "<d:response>"
        s += "<\(D):href>\(xml(href))</\(D):href>"
        if !found.isEmpty { s += "<\(D):propstat><\(D):prop>" + found.joined() + "</\(D):prop><\(D):status>HTTP/1.1 200 OK</\(D):status></\(D):propstat>" }
        if !missing.isEmpty { s += "<\(D):propstat><\(D):prop>" + missing.joined() + "</\(D):prop><\(D):status>HTTP/1.1 404 Not Found</\(D):status></\(D):propstat>" }
        s += "</\(D):response>"
        return s
    }

    enum Destination { case files(String), restore, other }

    static func destination(_ r: URLRequest, ctx: Ctx) -> (Destination, ok: Bool) {
        guard let d = r.value(forHTTPHeaderField: "Destination"), let u = URL(string: d) else { return (.other, false) }
        if let h = u.host?.lowercased(), h != ctx.host { return (.other, false) }
        let enc = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? u.path
        let p = enc.removingPercentEncoding ?? enc
        let rootDecoded = ctx.rootHref.removingPercentEncoding ?? ctx.rootHref
        if p.hasPrefix(rootDecoded) { return (.files("/" + p.dropFirst(rootDecoded.count)), true) }
        if !ctx.plain {
            let base = _state.nextcloudBasePath
            if p.hasPrefix(base + "/remote.php/dav/files/" + _state.nextcloud.uid + "/") {
                return (.files("/" + p.dropFirst((base + "/remote.php/dav/files/" + _state.nextcloud.uid + "/").count)), true)
            }
            if p.hasPrefix(base + "/remote.php/dav/trashbin/" + _state.nextcloud.uid + "/restore/") { return (.restore, true) }
        }
        return (.other, true)
    }

    static func files(_ method: String, _ rel: String, _ r: URLRequest, _ body: Data, _ ctx: Ctx) -> Outcome {
        let a = ctx.account
        let plain = ctx.plain
        let ci = plain && _state.plainCaseInsensitive
        let found = find(_state[keyPath: a].files, rel, ci: ci)
        switch method {
        case "OPTIONS":
            return .reply(200, ["DAV": "1, 2, 3", "Allow": "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, MKCOL"], Data())
        case "PROPFIND":
            guard let depth = r.value(forHTTPHeaderField: "Depth") else { return fail(400, "Cirrus always sends a Depth header", plain: plain) }
            guard depth == "0" || depth == "1" else { return fail(403, "Depth infinity is not allowed", plain: plain) }
            guard let k = found else { return fail(404, "File with name \(rel) could not be located", plain: plain) }
            let it = _state[keyPath: a].files[k]!
            if plain && it.isFolder && !rel.hasSuffix("/") {
                return .reply(301, ["Location": "https://\(ctx.host)" + href(ctx, k, isFolder: true)], Data())
            }
            if _state.failPropfind.contains(where: { nfc($0) == k }) { return fail(500, "Internal Server Error", plain: plain) }
            let req = requestedProps(body)
            guard req.ok else { return fail(400, "The request body is not valid XML", plain: plain) }
            var keys = [k]
            if depth == "1" && it.isFolder {
                keys += children(_state[keyPath: a].files, of: k)
                if !_state.echoSelf { keys.removeFirst() }
            }
            var x = multistatusHead(plain: plain)
            for key in keys {
                let item = _state[keyPath: a].files[key]!
                x += responseXML(href(ctx, key, isFolder: item.isFolder), values(item, key: key, ctx: ctx, isTop: key == "/"), requested: req.props, plain: plain)
            }
            x += plain ? "</D:multistatus>" : "</d:multistatus>"
            var data = Data(x.utf8)
            if _state.truncatePropfind.contains(where: { nfc($0) == k }) { data = data.prefix(data.count / 2) }
            return .reply(207, ["Content-Type": "application/xml; charset=utf-8"], data)
        case "GET", "HEAD":
            guard let k = found else { return fail(404, "File not found", plain: plain) }
            let it = _state[keyPath: a].files[k]!
            if it.isFolder { return plain ? .reply(200, ["Content-Type": "text/html"], Data("<html>Index</html>".utf8)) : fail(501, "GET is not implemented on this endpoint", plain: false) }
            return .reply(200, ["Content-Type": it.contentType, "ETag": "\"\(it.etag)\"", "Last-Modified": DAVDates.httpString(it.modified)], it.data)
        case "PUT":
            if rel.hasSuffix("/") { return fail(409, "PUT is not allowed on a collection", plain: plain) }
            if isLocked(nfc(rel)) || found.map(isLocked) == true { return fail(423, "The resource you tried to edit is locked", plain: plain) }
            guard let parent = find(_state[keyPath: a].files, parentKey(nfc(rel)), ci: ci), _state[keyPath: a].files[parent]?.isFolder == true else {
                return fail(409, "Parent folder doesn't exist", plain: plain)
            }
            if let k = found, _state[keyPath: a].files[k]!.isFolder { return fail(405, "A folder with this name exists", plain: plain) }
            if r.value(forHTTPHeaderField: "If-None-Match") == "*" && found != nil { return fail(412, "An If-None-Match header was specified, but the ETag matched", plain: plain) }
            let acct = _state[keyPath: a]
            if let q = acct.quota, acct.usedBytes - Int64(found.flatMap { acct.files[$0]?.data.count } ?? 0) + Int64(body.count) > q {
                return fail(507, "Insufficient space in \(rel)", plain: plain)
            }
            let key = found ?? parent + DAVURL.lastSegment(nfc(rel))
            return store(key, body, r, ctx: ctx, created: found == nil)
        case "MKCOL":
            if !body.isEmpty { return fail(415, "The request body for the MKCOL request must have an xml Content-Type", plain: plain) }
            if found != nil { return fail(405, "The resource you tried to create already exists", plain: plain) }
            guard let parent = find(_state[keyPath: a].files, parentKey(nfc(rel)), ci: ci), _state[keyPath: a].files[parent]?.isFolder == true else {
                return fail(409, "Parent node does not exist", plain: plain)
            }
            let key = parent + DAVURL.lastSegment(nfc(rel)) + "/"
            let made = _state.newItem(folder: true)
            _state[keyPath: a].files[key] = made
            return .reply(201, plain ? [:] : ["Content-Length": "0"], Data())
        case "DELETE":
            guard let k = found else { return fail(404, "File not found", plain: plain) }
            if k == "/" { return fail(403, "The top folder can't be deleted", plain: plain) }
            if isLocked(k) { return fail(423, "Locked", plain: plain) }
            if !plain && _state.trashbinEnabled {
                moveToTrash(k)
            } else {
                for key in subtree(_state[keyPath: a].files, k) { _state[keyPath: a].files[key] = nil }
                _state.permanentDeletes += 1
            }
            return .reply(204, [:], Data())
        case "MOVE":
            guard let k = found else { return fail(404, "File not found", plain: plain) }
            if k == "/" { return fail(403, "The top folder can't be moved", plain: plain) }
            let (dest, ok) = destination(r, ctx: ctx)
            guard ok else { return fail(plain ? 400 : 502, "The destination header is missing or points to another server", plain: plain) }
            guard case .files(let destRaw) = dest else { return fail(403, "Destination is outside this account", plain: plain) }
            let overwrite = (r.value(forHTTPHeaderField: "Overwrite") ?? "T").uppercased() != "F"
            let isFolder = _state[keyPath: a].files[k]!.isFolder
            let destRel = nfc(destRaw)
            if isLocked(k) || isLocked(destRel) { return fail(423, "Locked", plain: plain) }
            guard let parent = find(_state[keyPath: a].files, parentKey(destRel), ci: ci), _state[keyPath: a].files[parent]?.isFolder == true else {
                return fail(409, "The destination node is not found", plain: plain)
            }
            let newKey = parent + DAVURL.lastSegment(destRel) + (isFolder ? "/" : "")
            if newKey == k { return fail(403, "Source and destination uri are identical.", plain: plain) }
            if isFolder && newKey.hasPrefix(k) { return fail(409, "Cannot move a node into its own child", plain: plain) }
            let existing = find(_state[keyPath: a].files, destRel, ci: ci)
            if existing != nil && !overwrite { return fail(412, "The destination node already exists, and the overwrite header is set to false", plain: plain) }
            if let e = existing, e != k {
                for key in subtree(_state[keyPath: a].files, e) { _state[keyPath: a].files[key] = nil }
            }
            let moving = subtree(_state[keyPath: a].files, k)
            var moved = [String: Item]()
            for key in moving { moved[newKey + key.dropFirst(k.count)] = _state[keyPath: a].files[key]; _state[keyPath: a].files[key] = nil }
            for (key, it) in moved { _state[keyPath: a].files[key] = it }
            return .reply(existing == nil || existing == k ? 201 : 204, [:], Data())
        default:
            return fail(405, "Method \(method) is not allowed", plain: plain)
        }
    }

    /// PUT or the end of a chunked upload: writes a file and answers like Nextcloud / Apache.
    static func store(_ key: String, _ data: Data, _ r: URLRequest, ctx: Ctx, created: Bool) -> Outcome {
        let a = ctx.account
        let old = _state[keyPath: a].files[key]
        var it: Item
        if let old { it = old } else { it = _state.newItem(folder: false) }
        it.isFolder = false
        it.data = data
        it.etag = newETag()
        it.contentType = r.value(forHTTPHeaderField: "Content-Type").flatMap { $0 == "application/octet-stream" ? nil : $0 } ?? mime(key)
        var headers = ["ETag": "\"\(it.etag)\""]
        it.modified = Date()
        if !ctx.plain, let m = r.value(forHTTPHeaderField: "X-OC-Mtime"), let secs = Double(m) {
            it.modified = Date(timeIntervalSince1970: secs)
            headers["X-OC-MTime"] = "accepted"
        }
        if old == nil { it.created = it.modified }
        _state[keyPath: a].files[key] = it
        if !ctx.plain {
            headers["OC-ETag"] = "\"\(it.etag)\""
            headers["OC-FileId"] = String(format: "%08docfake", it.fileID)
        }
        return .reply(created ? 201 : 204, headers, Data())
    }

    // MARK: Nextcloud trash bin

    static func moveToTrash(_ key: String) {
        let files = _state.nextcloud.files
        let seg = DAVURL.lastSegment(key)
        var ts = Int(Date().timeIntervalSince1970)
        while _state.nextcloud.trash["\(seg).d\(ts)"] != nil { ts += 1 }
        var items = [String: Item]()
        for k in subtree(files, key) {
            items[k == key ? "" : String(k.dropFirst(key.count))] = files[k]
            _state.nextcloud.files[k] = nil
        }
        var location = parentKey(key)
        location = String(location.dropFirst())
        if location.hasSuffix("/") { location.removeLast() }
        _state.nextcloud.trash["\(seg).d\(ts)"] = TrashEntry(name: seg, location: location, deleted: ts, items: items)
    }

    static func trashbin(_ method: String, _ rel: String, _ r: URLRequest, _ body: Data, _ encPath: String, _ encBase: String) -> Outcome {
        let uid = _state.nextcloud.uid
        let rootHref = encBase + "/remote.php/dav/trashbin/" + encodeStrict(uid) + "/trash/"
        let ctx = Ctx(plain: false, host: _state.nextcloudHost, rootHref: rootHref, requestPath: encPath, account: \.nextcloud)
        let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)
        let top = parts.first.map(nfc)
        let inner = parts.count > 1 ? nfc(parts[1]) : ""
        switch method {
        case "PROPFIND":
            guard let depth = r.value(forHTTPHeaderField: "Depth") else { return fail(400, "Cirrus always sends a Depth header", plain: false) }
            guard depth == "0" || depth == "1" else { return fail(403, "Depth infinity is not allowed", plain: false) }
            let req = requestedProps(body)
            var x = multistatusHead(plain: false)
            let rootItem = Item(isFolder: true, data: Data(), modified: Date(), created: Date(), etag: "trash", fileID: 0, contentType: "")
            guard let t = top else {
                if _state.echoSelf || depth == "0" { x += responseXML(href(ctx, "/", isFolder: true), values(rootItem, key: "/", ctx: ctx, isTop: true, trash: nil), requested: req.props, plain: false) }
                if depth == "1" {
                    for (name, e) in _state.nextcloud.trash.sorted(by: { $0.key < $1.key }) {
                        guard let it = e.items[""] else { continue }
                        x += responseXML(href(ctx, "/" + name, isFolder: it.isFolder), values(it, key: "/" + name + "/", ctx: ctx, isTop: false,
                                                                                            trash: (e.name, e.location, e.deleted)), requested: req.props, plain: false)
                    }
                }
                return .reply(207, ["Content-Type": "application/xml; charset=utf-8"], Data((x + "</d:multistatus>").utf8))
            }
            guard let e = _state.nextcloud.trash[t] else { return fail(404, "Not found", plain: false) }
            let innerKey = inner.hasSuffix("/") || inner.isEmpty ? inner : (e.items[inner] != nil ? inner : inner + "/")
            guard let it = e.items[innerKey] else { return fail(404, "Not found", plain: false) }
            let selfKey = innerKey.isEmpty ? "/" + t : "/" + t + "/" + innerKey
            x += responseXML(href(ctx, selfKey, isFolder: it.isFolder),
                             values(it, key: selfKey, ctx: ctx, isTop: false, trash: innerKey.isEmpty ? (e.name, e.location, e.deleted) : nil),
                             requested: req.props, plain: false)
            if depth == "1" && it.isFolder {
                for (k, child) in e.items.sorted(by: { $0.key < $1.key }) where !k.isEmpty && k != innerKey && k.hasPrefix(innerKey) {
                    let rest = k.dropFirst(innerKey.count)
                    let trimmed = rest.hasSuffix("/") ? rest.dropLast() : rest
                    guard !trimmed.contains("/") else { continue }
                    x += responseXML(href(ctx, "/" + t + "/" + k, isFolder: child.isFolder), values(child, key: "/" + t + "/" + k, ctx: ctx, isTop: false, trash: nil),
                                     requested: req.props, plain: false)
                }
            }
            return .reply(207, ["Content-Type": "application/xml; charset=utf-8"], Data((x + "</d:multistatus>").utf8))
        case "GET":
            guard let t = top, let e = _state.nextcloud.trash[t], let it = e.items[inner], !it.isFolder else { return fail(404, "Not found", plain: false) }
            return .reply(200, ["Content-Type": it.contentType, "ETag": "\"\(it.etag)\""], it.data)
        case "DELETE":
            guard let t = top else {
                _state.permanentDeletes += _state.nextcloud.trash.count
                _state.nextcloud.trash = [:]
                return .reply(204, [:], Data())
            }
            guard _state.nextcloud.trash[t] != nil else { return fail(404, "Not found", plain: false) }
            if inner.isEmpty {
                _state.nextcloud.trash[t] = nil
            } else {
                for k in _state.nextcloud.trash[t]!.items.keys where k == inner || k.hasPrefix(inner.hasSuffix("/") ? inner : inner + "/") || k == inner + "/" {
                    _state.nextcloud.trash[t]!.items[k] = nil
                }
            }
            _state.permanentDeletes += 1
            return .reply(204, [:], Data())
        case "MOVE":
            guard let t = top else { return fail(403, "Only deleted items can be restored", plain: false) }
            guard inner.isEmpty, let e = _state.nextcloud.trash[t] else { return fail(404, "Only deleted items can be restored", plain: false) }
            let (dest, ok) = destination(r, ctx: Ctx(plain: false, host: _state.nextcloudHost, rootHref: "/-none-/", requestPath: encPath, account: \.nextcloud))
            guard ok, case .restore = dest else { return fail(403, "Deleted items can only be moved to the restore folder", plain: false) }
            var folder = e.location.isEmpty ? "/" : "/" + e.location + "/"
            if _state.nextcloud.files[folder]?.isFolder != true { folder = "/" }
            var name = e.name
            if _state.nextcloud.files[folder + name] != nil || _state.nextcloud.files[folder + name + "/"] != nil {
                let ext = (e.name as NSString).pathExtension
                let stem = (e.name as NSString).deletingPathExtension
                name = e.isFolder || ext.isEmpty ? "\(e.name) (restored)" : "\(stem) (restored).\(ext)"
            }
            let newKey = folder + name + (e.isFolder ? "/" : "")
            for (k, it) in e.items { _state.nextcloud.files[newKey + k] = it }
            _state.nextcloud.trash[t] = nil
            return .reply(201, [:], Data())
        default:
            return fail(405, "Method not allowed", plain: false)
        }
    }

    // MARK: Chunked upload v2

    static func uploads(_ method: String, _ rel: String, _ r: URLRequest, _ body: Data) -> Outcome {
        let parts = rel.split(separator: "/").map(String.init)
        guard let id = parts.first else { return fail(403, "Not allowed", plain: false) }
        let ctx = Ctx(plain: false, host: _state.nextcloudHost, rootHref: "/-none-/", requestPath: "", account: \.nextcloud)
        func dest() -> String? {
            let (d, ok) = destination(r, ctx: ctx)
            if ok, case .files(let p) = d { return nfc(p) }
            return nil
        }
        switch (method, parts.count) {
        case ("MKCOL", 1):
            guard let d = dest() else { return fail(400, "Chunked upload v2 needs a Destination header on MKCOL", plain: false) }
            guard _state.uploads[id] == nil else { return fail(405, "The upload folder already exists", plain: false) }
            _state.uploads[id] = Upload(destination: d)
            return .reply(201, [:], Data())
        case ("PUT", 2):
            guard var u = _state.uploads[id] else { return fail(404, "Upload not found", plain: false) }
            guard let d = dest(), d == u.destination else { return fail(400, "Each chunk needs the same Destination header as the MKCOL", plain: false) }
            guard let n = Int(parts[1]), (1...10_000).contains(n) else { return fail(400, "Chunk names must be numbers from 1 to 10000", plain: false) }
            u.chunks[n] = body
            _state.uploads[id] = u
            _state.chunkPuts += 1
            return .reply(201, ["ETag": "\"\(newETag())\""], Data())
        case ("MOVE", 2) where parts[1] == ".file":
            guard let u = _state.uploads[id] else { return fail(404, "Upload not found", plain: false) }
            guard let d = dest(), d == u.destination else { return fail(400, "The final MOVE must go to the upload's Destination", plain: false) }
            let numbers = u.chunks.keys.sorted()
            guard !numbers.isEmpty, numbers == Array(1...numbers.count) else { return fail(400, "Chunks are missing", plain: false) }
            for n in numbers.dropLast() where u.chunks[n]!.count < _state.minChunkSize {
                return fail(400, "Chunk \(n) is smaller than the 5 MiB minimum", plain: false)
            }
            var data = Data()
            for n in numbers { data.append(u.chunks[n]!) }
            guard let total = r.value(forHTTPHeaderField: "OC-Total-Length").flatMap({ Int($0) }), total == data.count else {
                return fail(400, "OC-Total-Length is missing or doesn't match the chunks", plain: false)
            }
            let fctx = Ctx(plain: false, host: _state.nextcloudHost, rootHref: "/", requestPath: "", account: \.nextcloud)
            let existing = find(_state.nextcloud.files, d, ci: false)
            if existing != nil && (r.value(forHTTPHeaderField: "Overwrite") ?? "T").uppercased() == "F" {
                return fail(412, "The destination node already exists, and the overwrite header is set to false", plain: false)
            }
            guard let parent = find(_state.nextcloud.files, parentKey(d), ci: false), _state.nextcloud.files[parent]?.isFolder == true else {
                return fail(409, "Parent folder doesn't exist", plain: false)
            }
            if let q = _state.nextcloud.quota, _state.nextcloud.usedBytes + Int64(data.count) > q { return fail(507, "Insufficient space", plain: false) }
            _state.uploads[id] = nil
            _state.chunkAssemblies += 1
            return store(existing ?? parent + DAVURL.lastSegment(d), data, r, ctx: fctx, created: existing == nil)
        case ("DELETE", _):
            _state.uploads[id] = nil
            return .reply(204, [:], Data())
        default:
            return fail(405, "Method not allowed", plain: false)
        }
    }

    // MARK: Previews

    static func preview(_ method: String, _ url: URL, _ r: URLRequest) -> Outcome {
        guard method == "GET" else { return fail(405, "Method not allowed", plain: false) }
        guard authorized(r, _state.nextcloud, nextcloud: true) else { return .reply(401, ["Content-Type": "application/json"], Data("{}".utf8)) }
        _state.previewRequests += 1
        let q = query(url)
        guard let id = q["fileId"].flatMap({ Int($0) }), let x = q["x"].flatMap({ Int($0) }), let y = q["y"].flatMap({ Int($0) }), x > 0, y > 0 else {
            return .reply(400, ["Content-Type": "application/json"], Data("{}".utf8))
        }
        guard let it = _state.nextcloud.files.values.first(where: { $0.fileID == id }), previewable(it) else {
            return .reply(404, ["Content-Type": "application/json"], Data("[]".utf8))
        }
        return .reply(200, ["Content-Type": "image/png"], png(width: min(x, 64), height: min(y, 64), hue: CGFloat(id % 10) / 10))
    }

    static func png(width: Int, height: Int, hue: CGFloat) -> Data {
        guard let ctx = DemoArt.bitmap(width, height) else { return Data() }
        ctx.setFillColor(DemoArt.hsb(hue, 0.5, 0.9))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(DemoArt.white(1, 0.35))
        ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let img = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }

    // MARK: Demo content

    static func seed(_ s: inout State) {
        s.nextcloud.quota = 10_000_000_000
        let day = 86_400.0
        func d(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + n * day) }
        // Nextcloud
        s.add("/Readme.md", Data("# Welcome\n\nThis is a demo Nextcloud account for Cirrus. Nothing here is real.\n".utf8), modified: d(30))
        s.add("/Documents/Budget 2026.csv", Data("Month,Income,Expenses\nJanuary,4200,3100\nFebruary,4200,2950\nMarch,4350,3300\n".utf8), modified: d(12))
        s.add("/Documents/Meeting notes.txt", Data("Agenda\n- Roadmap review\n- Launch checklist\n- Next steps\n".utf8), modified: d(20))
        s.add("/Documents/Project brief.pdf", DemoArt.pdf(title: "Project brief", lines: ["Goals", "Scope", "Timeline", "Owner: Alex Morgan"], hue: 0.58), modified: d(8))
        s.add("/Documents/Q&A #1 (draft).md", Data("Questions and answers, first draft.\n".utf8), modified: d(25))
        s.add("/Photos/Harbor at dusk.jpg", DemoArt.scenic(width: 960, height: 640, seed: 2) ?? Data(count: 2000), modified: d(3))
        s.add("/Photos/Mountain lake.jpg", DemoArt.scenic(width: 960, height: 640, seed: 3) ?? Data(count: 2000), modified: d(4))
        s.add("/Photos/Logo.png", png(width: 128, height: 128, hue: 0.6), modified: d(5))
        s.add("/Projects/Roadmap.md", Data("# Roadmap\n\n1. Prototype\n2. Beta\n3. Launch\n".utf8), modified: d(18))
        s.add("/Projects/Website/index.html", Data("<!doctype html><title>Demo</title><h1>Hello</h1>\n".utf8), modified: d(15))
        s.add("/Projects/Website/style.css", Data("body { font-family: system-ui; }\n".utf8), modified: d(15))
        s.add("/Projects/Tasks.csv", Data("Task,Owner,Done\nWireframes,Alex Morgan,yes\nCopy,Alex Morgan,no\n".utf8), modified: d(22))
        s.sharedPaths = ["/Projects/"]
        s.nextcloud.trash["Old draft.txt.d1791000000"] = TrashEntry(
            name: "Old draft.txt", location: "Documents", deleted: 1_791_000_000,
            items: ["": Item(isFolder: false, data: Data("An older draft.\n".utf8), modified: d(1), created: d(1), etag: newETag(), fileID: 90, contentType: "text/plain")])
        // Plain WebDAV
        s.add("/Documents/Notes.txt", Data("Shopping list\n- Coffee\n- Bread\n".utf8), plain: true, modified: d(10))
        s.add("/Documents/Inventory.csv", Data("Item,Count\nCables,12\nAdapters,4\n".utf8), plain: true, modified: d(11))
        s.add("/Documents/Manual.pdf", DemoArt.pdf(title: "User manual", lines: ["Setup", "Daily use", "Troubleshooting"], hue: 0.1), plain: true, modified: d(6))
        s.add("/Photos/Beach.jpg", DemoArt.scenic(width: 960, height: 640, seed: 1) ?? Data(count: 2000), plain: true, modified: d(2))
        s.add("/Photos/Forest.jpg", DemoArt.scenic(width: 960, height: 640, seed: 4) ?? Data(count: 2000), plain: true, modified: d(2))
        s.add("/Backups/settings-backup.json", Data("{\"theme\": \"dark\", \"version\": 3}\n".utf8), plain: true, modified: d(14))
        s.add("/Projects/Garden plan.md", Data("# Garden plan\n\nTomatoes by the fence, herbs by the door.\n".utf8), plain: true, modified: d(16))
    }
}
#endif
