import Foundation

// Dropbox API v2 transport: token handling (one shared refresh at a time), the two request styles Dropbox uses
// (RPC calls on api.dropboxapi.com with a JSON body; content calls on content.dropboxapi.com with the argument
// in the `Dropbox-API-Arg` header), back-off on rate limits and write contention, and a gate that keeps
// changes to the user's Dropbox one at a time as Dropbox recommends. The bearer token only ever goes to those
// two hosts over https. Logs carry the route and status only: never tokens, arguments or file names.

/// Tokens from Dropbox's token endpoint.
struct DropboxTokenSet: Sendable {
    var access: String
    var refresh: String?
    var expires: Date
    /// The scopes Dropbox granted (nil when the answer didn't say).
    var scopes: Set<String>?
}

/// One account's tokens. Dropbox's refresh tokens normally stay the same for the life of the sign-in; if a
/// refresh ever hands out a new one, it goes to `onNewRefreshToken` before anyone can refresh again.
final class DropboxTokens: @unchecked Sendable {
    let appKey: String
    let http: URLSession
    private let lock = NSLock()
    private var refreshToken: String
    private var access: String?
    private var expires = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var onNew: (@Sendable (String) -> Void)?

    init(appKey: String, refreshToken: String, http: URLSession, initial: DropboxTokenSet? = nil) {
        self.appKey = appKey
        self.refreshToken = refreshToken
        self.http = http
        access = initial?.access
        expires = initial?.expires ?? .distantPast
    }

    var currentRefreshToken: String { lock.withLock { refreshToken } }

    var onNewRefreshToken: (@Sendable (String) -> Void)? {
        get { lock.withLock { onNew } }
        set { lock.withLock { onNew = newValue } }
    }

    /// A usable access token. `stale` is one the server just refused (401): it is never handed out again.
    /// Every caller that needs a new token waits on the same refresh.
    func accessToken(replacing stale: String? = nil) async throws -> String {
        enum Next { case ready(String), wait(Task<String, Error>) }
        let next: Next = lock.withLock {
            if let a = access, a != stale, expires.timeIntervalSinceNow > 120 { return .ready(a) }
            if let r = refreshing { return .wait(r) }
            let rt = refreshToken
            // Not tied to the caller's task: one cancelled request must not cancel everyone's refresh.
            let r = Task { try await self.runRefresh(rt) }
            refreshing = r
            return .wait(r)
        }
        switch next {
        case .ready(let a): return a
        case .wait(let t): return try await t.value
        }
    }

    private func runRefresh(_ rt: String) async throws -> String {
        defer { lock.withLock { refreshing = nil } }
        let t = try await DropboxAuth.redeem(["grant_type": "refresh_token", "refresh_token": rt], appKey: appKey, http: http, signingIn: false)
        let callback: (@Sendable (String) -> Void)? = lock.withLock {
            access = t.access
            expires = t.expires
            guard let n = t.refresh, !n.isEmpty, n != refreshToken else { return nil }
            refreshToken = n
            return onNew
        }
        if let n = t.refresh, let callback { callback(n) }
        return t.access
    }
}

/// What a request carries.
enum DropboxBody: Sendable { case none, data(Data), file(URL) }

/// A finished request. Downloads (`toFile`) land in `file`; the caller moves or deletes it.
struct DropboxResponse: Sendable {
    let status: Int
    let http: HTTPURLResponse
    let data: Data
    let file: URL?
    var json: JSON { (try? JSON(data: data)) ?? .null }
    func header(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
    /// Dropbox's machine-readable error path, e.g. "path/conflict/file/.." ("" when there is none).
    var summary: String { json["error_summary"].string ?? "" }
    /// Seconds to wait, from the Retry-After header or a RateLimitError body.
    var retryAfter: Double? {
        if let h = header("Retry-After"), let s = Double(h.trimmingCharacters(in: .whitespaces)) { return s }
        return json["error"]["retry_after"].double
    }
    /// Deletes a downloaded body and the one-off folder `Paths.tempFile` made for it.
    func discard() { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}

final class DropboxHTTP: @unchecked Sendable {
    static let apiHost = "api.dropboxapi.com"
    static let contentHost = "content.dropboxapi.com"
    static let api = "https://api.dropboxapi.com/2/"
    static let content = "https://content.dropboxapi.com/2/"

    let session: URLSession
    let tokens: DropboxTokens
    /// Team accounts with a team space: the root namespace every path is relative to (`Dropbox-API-Path-Root`).
    let pathRoot: String?
    /// Base back-off in seconds (tests set it near zero).
    var retryBase: Double = 1
    var maxRetries = 5
    /// Longest wait Cirrus accepts from a Retry-After before giving up with a clear error.
    var maxRetryAfter: Double = 120

    init(session: URLSession, tokens: DropboxTokens, pathRoot: String?) {
        self.session = session
        self.tokens = tokens
        self.pathRoot = pathRoot
    }

    static func makeSession(_ transport: [AnyClass]?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpMaximumConnectionsPerHost = 6
        if let t = transport { c.protocolClasses = t }
        // Dropbox doesn't redirect API calls; if anything ever does, it must not carry the token elsewhere.
        return URLSession(configuration: c, delegate: DropboxTaskDelegate(), delegateQueue: nil)
    }

    static func isDropbox(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let h = url.host?.lowercased() else { return false }
        return h == apiHost || h == contentHost
    }

    // MARK: JSON arguments

    /// Compact JSON with sorted keys and unescaped slashes.
    static func encode(_ j: JSON) -> Data {
        (try? JSONSerialization.data(withJSONObject: j.any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    /// JSON that is safe in an HTTP header, as Dropbox asks for `Dropbox-API-Arg`: 0x7F and every non-ASCII
    /// character become "\uXXXX" escapes (UTF-16 code units, so emoji become surrogate pairs).
    static func headerSafe(_ j: JSON) -> String {
        let s = String(decoding: encode(j), as: UTF8.self)
        var out = ""
        out.reserveCapacity(s.utf16.count)
        for u in s.utf16 {
            if u >= 0x7F { out += String(format: "\\u%04x", u) } else { out.unicodeScalars.append(Unicode.Scalar(u)!) }
        }
        return out
    }

    /// An RPC call: the argument as the JSON body, or no body (and no Content-Type) for routes without one.
    func rpcRequest(_ route: String, _ arg: JSON?) -> URLRequest {
        var req = URLRequest(url: URL(string: Self.api + route)!)
        req.httpMethod = "POST"
        if let arg {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.encode(arg)
        }
        return req
    }

    /// A content call: the argument in `Dropbox-API-Arg`; uploads send raw bytes, downloads send no body.
    func contentRequest(_ route: String, _ arg: JSON, upload: Bool) -> URLRequest {
        var req = URLRequest(url: URL(string: Self.content + route)!)
        req.httpMethod = "POST"
        req.setValue(Self.headerSafe(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        if upload { req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        return req
    }

    // MARK: Errors

    static let transientCodes: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                                                     .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .internationalRoamingOff,
                                                     .resourceUnavailable, .badServerResponse]
    /// Failures where the request certainly never reached the server.
    static let notSentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
                                                   .internationalRoamingOff, .secureConnectionFailed]

    static func retryable(_ e: URLError, ambiguousOK: Bool) -> Bool {
        ambiguousOK ? transientCodes.contains(e.code) : notSentCodes.contains(e.code)
    }

    static func networkError(_ e: URLError) -> CloudError {
        switch e.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet: return .server("Cirrus can’t reach Dropbox: this device is offline.")
        default: return .server("Cirrus couldn’t reach Dropbox (\(e.localizedDescription)). Try again.")
        }
    }

    /// Turns network failures into CloudError (and cancellation into CancellationError).
    static func guarded<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw networkError(e)
        }
    }

    /// A sentence for a Dropbox error answer. `name` is the item the request was about, if any.
    static func error(_ r: DropboxResponse, name: String? = nil) -> CloudError {
        let s = r.summary
        let what = name.map { "“\($0)”" } ?? "the item"
        let What = what.prefix(1).uppercased() + what.dropFirst()
        func has(_ k: String) -> Bool { s.contains(k) }
        switch r.status {
        case 401:
            let tag = r.json["error"][".tag"].string ?? ""
            if tag == "missing_scope" {
                // A union variant holding a struct: its fields sit beside ".tag".
                let scope = r.json["error"]["required_scope"].string ?? "a permission"
                return .denied("Dropbox didn’t give Cirrus the “\(scope)” permission. Sign in to Dropbox again; if that doesn’t help, the Dropbox app this copy of Cirrus uses needs that permission turned on in the App Console.")
            }
            if tag == "user_suspended" { return .denied("This Dropbox account is suspended.") }
            return .signInNeeded("Dropbox")
        case 409:
            if has("too_many_write_operations") {
                return .server("Dropbox is busy with other changes to your files. Try again in a minute.")
            }
            if has("insufficient_space") || has("insufficient_quota") { return .quotaExceeded("Dropbox") }
            if has("not_found") { return .notFound }
            if has("not_folder") { return .denied("\(What) isn’t a folder on Dropbox.") }
            if has("not_file") { return .denied("\(What) is a folder on Dropbox, not a file.") }
            if has("conflict") { return .denied("There’s already an item named \(what) in that folder on Dropbox.") }
            if has("no_write_permission") || has("access_denied") || has("restricted_content") {
                return .denied("Dropbox didn’t allow changing \(what). It may be in a folder someone shared with you to view only.")
            }
            if has("disallowed_name") { return .denied("Dropbox doesn’t allow the name \(what).") }
            if has("malformed_path") { return .denied("Dropbox can’t use the name \(what). Rename it and try again.") }
            if has("cant_move_folder_into_itself") || has("duplicated_or_nested_paths") {
                return .denied("A folder can’t be moved into itself or into a folder inside it.")
            }
            if has("cant_nest_shared_folder") { return .denied("Dropbox can’t put a shared folder inside another shared folder.") }
            if has("cant_move_shared_folder") || has("cant_transfer_ownership") || has("cant_move_into_vault") {
                return .denied("Dropbox didn’t allow moving \(what) there.")
            }
            if has("team_folder") { return .denied("Dropbox doesn’t allow this change to a team folder.") }
            if has("too_many_files") { return .denied("\(What) holds too many files for Dropbox to do this in one step.") }
            if has("unsupported_file") {
                return .unsupported("\(What) is a Dropbox Paper document or another online-only file that Dropbox can’t download as a file. Open it on dropbox.com.")
            }
            if has("too_large") || has("payload_too_large") { return .denied("\(What) is too large for Dropbox.") }
            if has("operation_suppressed") { return .denied("Dropbox didn’t allow this change to \(what).") }
            if has("reset") { return .server("Dropbox restarted listing a folder. Try again.") }
            let first = s.split(separator: "/").first.map(String.init) ?? ""
            return .server(first.isEmpty ? "Dropbox couldn’t do this (HTTP 409)." : "Dropbox couldn’t do this (\(first)).")
        case 403:
            return .denied("Dropbox didn’t allow this change to \(what).")
        case 400:
            // A plain-text answer that may quote the request (names): never shown or logged in full.
            return .server("Dropbox didn’t accept Cirrus’s request for \(what) (HTTP 400). Try again; if it keeps happening, update Cirrus.")
        case 422:
            // The team space this account was set up with changed (Dropbox-API-Path-Root no longer valid).
            return .signInNeeded("Dropbox")
        case 429, 503:
            return .server("Dropbox is limiting how fast Cirrus can work right now. Try again in a few minutes.")
        default:
            if r.status >= 500 { return .server("Dropbox had a problem (HTTP \(r.status)). Try again later.") }
            return .server("Dropbox answered HTTP \(r.status).")
        }
    }

    // MARK: Requests

    /// Route shape for logs: host and route, nothing else.
    static func describe(_ u: URL?) -> String {
        guard let u else { return "?" }
        let host = u.host == contentHost ? "content" : (u.host == apiHost ? "api" : (u.host ?? "?"))
        return host + u.path
    }

    /// One HTTP exchange, no retries; network failures come back as URLError.
    func transport(_ req: URLRequest, body: DropboxBody = .none, toFile: Bool = false,
                   sent: (@Sendable (Int64) -> Void)? = nil, received: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> DropboxResponse {
        let delegate = DropboxTaskDelegate(sent: sent, received: received)
        let started = Date()
        let response: DropboxResponse
        if toFile {
            let (tmp, resp) = try await session.download(for: req, delegate: delegate)
            guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let mine = Paths.tempFile(named: "dropbox.download")
            try? FileManager.default.removeItem(at: mine)
            try FileManager.default.moveItem(at: tmp, to: mine)
            var data = Data()
            if !(200..<300).contains(h.statusCode), let size = (try? FileManager.default.attributesOfItem(atPath: mine.path)[.size] as? NSNumber)?.intValue,
               size < 256 * 1024 {
                data = (try? Data(contentsOf: mine)) ?? Data()   // an error answer: keep it for the message
            }
            response = DropboxResponse(status: h.statusCode, http: h, data: data, file: mine)
        } else {
            let data: Data, resp: URLResponse
            switch body {
            case .none: (data, resp) = try await session.data(for: req, delegate: delegate)
            case .data(let d): (data, resp) = try await session.upload(for: req, from: d, delegate: delegate)
            case .file(let u): (data, resp) = try await session.upload(for: req, fromFile: u, delegate: delegate)
            }
            guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            response = DropboxResponse(status: h.statusCode, http: h, data: data, file: nil)
        }
        let line = "dropbox \(Self.describe(req.url)) → \(response.status)"
        if (200..<300).contains(response.status) { Log.debug(line + String(format: " (%.2fs)", Date().timeIntervalSince(started))) } else { Log.status(line) }
        return response
    }

    enum Retry { case safe, unsafe }

    /// A request with the account's token, one refresh-and-retry after an expired or invalid token, and
    /// back-off on rate limits (429, or 503 with Retry-After) and write contention (`too_many_write_operations`),
    /// which Dropbox answers before doing anything. `.safe` requests (reads, and changes whose repeat is
    /// harmless) are also retried after 5xx answers and dropped connections; `.unsafe` ones only when they
    /// certainly never reached Dropbox. Every other status comes back as is. Network failures throw URLError.
    func send(_ request: URLRequest, body: DropboxBody = .none, retry: Retry, toFile: Bool = false,
              sent: (@Sendable (Int64) -> Void)? = nil, received: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> DropboxResponse {
        guard Self.isDropbox(request.url) else {
            throw CloudError.server("Cirrus was about to send your Dropbox sign-in to a server that isn’t Dropbox, so it stopped.")
        }
        var attempt = 0
        var stale: String?
        var reauthed = false
        while true {
            try Task.checkCancellation()
            var req = request
            let token = try await tokens.accessToken(replacing: stale)
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let pathRoot {
                req.setValue(Self.headerSafe([".tag": "root", "root": .string(pathRoot)]), forHTTPHeaderField: "Dropbox-API-Path-Root")
            }
            let r: DropboxResponse
            do {
                r = try await transport(req, body: body, toFile: toFile, sent: sent, received: received)
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                guard Self.retryable(e, ambiguousOK: retry == .safe), attempt < maxRetries else { throw e }
                attempt += 1
                Log.status("dropbox \(Self.describe(req.url)) failed (\(e.code.rawValue)); retrying")
                try await sleep(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            if r.status == 401 {
                let tag = r.json["error"][".tag"].string
                if tag == nil || tag == "expired_access_token" || tag == "invalid_access_token" {
                    r.discard()
                    if !reauthed { reauthed = true; stale = token; continue }
                    throw CloudError.signInNeeded("Dropbox")
                }
                return r   // missing_scope, user_suspended…: the caller explains
            }
            // Another change held the namespace: Dropbox did nothing, so any request may go again.
            let contention = (r.status == 429 || r.status == 409) && r.summary.contains("too_many_write_operations")
            let busy = contention || r.status == 429 || (r.status == 503 && r.header("Retry-After") != nil)
            let serverError = (500...599).contains(r.status) && retry == .safe
            if (busy || serverError) && attempt < maxRetries {
                if let after = r.retryAfter, after > maxRetryAfter { return r }   // too long to wait here: the caller reports it
                attempt += 1
                // Contention clears when the other change finishes: back off even when Retry-After says 0.
                let d = contention ? max(r.retryAfter ?? 0, delay(attempt: attempt, retryAfter: nil))
                    : delay(attempt: attempt, retryAfter: busy ? r.retryAfter : nil)
                Log.status("dropbox back-off \(String(format: "%.1f", d))s after \(r.status)")
                r.discard()
                try await sleep(d)
                continue
            }
            return r
        }
    }

    /// An RPC call that must answer 2xx with JSON.
    func rpc(_ route: String, _ arg: JSON?, retry: Retry, name: String? = nil) async throws -> JSON {
        let r = try await send(rpcRequest(route, arg), retry: retry)
        guard (200..<300).contains(r.status) else { throw Self.error(r, name: name) }
        return r.json
    }

    func delay(attempt: Int, retryAfter: Double?) -> Double {
        if let r = retryAfter { return max(0, min(r, maxRetryAfter)) }
        let base = min(retryBase * pow(2, Double(attempt - 1)), 32 * max(retryBase, 0.001))
        return base + Double.random(in: 0...max(retryBase, 0.001) / 2)
    }

    func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Keeps changes to one Dropbox account one at a time (or a few): Dropbox locks a namespace for each write,
/// and concurrent writes there end in `too_many_write_operations`. Waiting is FIFO and cancellable.
final class DropboxGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _limit: Int
    private var active = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { _limit = max(1, limit) }

    var limit: Int {
        get { lock.withLock { _limit } }
        set {
            let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
                _limit = max(1, newValue)
                var out = [CheckedContinuation<Void, Error>]()
                while active < _limit, !waiters.isEmpty { active += 1; out.append(waiters.removeFirst().cont) }
                return out
            }
            ready.forEach { $0.resume() }
        }
    }

    func run<T>(_ op: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                enum Now { case go, wait, cancelled }
                let now: Now = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if active < _limit { active += 1; return .go }
                    waiters.append((id, cont))
                    return .wait
                }
                switch now {
                case .go: cont.resume()
                case .cancelled: cont.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let i = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: i).cont
            }
            c?.resume(throwing: CancellationError())
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            if active <= _limit, !waiters.isEmpty { return waiters.removeFirst().cont }   // hand the slot on
            active -= 1
            return nil
        }
        next?.resume()
    }
}

/// Per-request delegate: upload and download progress, and no automatic redirects.
final class DropboxTaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let sent: (@Sendable (Int64) -> Void)?
    let received: (@Sendable (Int64, Int64) -> Void)?

    init(sent: (@Sendable (Int64) -> Void)? = nil, received: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.sent = sent
        self.received = received
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        sent?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        received?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
