import Foundation

// Microsoft Graph transport for OneDrive: token handling (single-flight refresh, refresh-token rotation) and
// requests with back-off. The bearer token only ever goes to graph.microsoft.com over https; download and
// upload-session URLs are pre-authenticated and get no Authorization header. Logs carry the method, host,
// route shape and status only: never tokens, query strings, file names or account names.

/// Tokens from Microsoft's token endpoint.
struct OneDriveTokenSet: Sendable {
    var access: String
    var refresh: String?
    var expires: Date
}

/// One account's tokens. Microsoft hands out a new refresh token with every refresh (and may stop
/// accepting the old one), so each new one goes to `onNewRefreshToken` before anyone can refresh again.
final class OneDriveTokens: @unchecked Sendable {
    let clientID: String
    let http: URLSession
    private let lock = NSLock()
    private var refreshToken: String
    private var access: String?
    private var expires = Date.distantPast
    private var refreshing: Task<String, Error>?
    private var onNew: (@Sendable (String) -> Void)?

    init(clientID: String, refreshToken: String, http: URLSession, initial: OneDriveTokenSet? = nil) {
        self.clientID = clientID
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
        // Cleared only after the new refresh token was handed on, so refreshes (and saves) stay in order.
        defer { lock.withLock { refreshing = nil } }
        let t = try await OneDriveAuth.redeem(["grant_type": "refresh_token", "refresh_token": rt, "scope": OneDrive.scopes.joined(separator: " ")],
                                              clientID: clientID, http: http, signingIn: false)
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
enum OneDriveBody: Sendable { case none, data(Data), file(URL) }

/// A finished request. Downloads (`toFile`) land in `file`; the caller moves or deletes it.
struct GraphResponse: Sendable {
    let status: Int
    let http: HTTPURLResponse
    let data: Data
    let file: URL?
    var json: JSON { (try? JSON(data: data)) ?? .null }
    func header(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
    var retryAfter: Double? { header("Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    /// Deletes a downloaded body and the one-off folder `Paths.tempFile` made for it.
    func discard() { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
}

final class OneDriveHTTP: @unchecked Sendable {
    static let graph = "https://graph.microsoft.com/v1.0"
    static let graphHost = "graph.microsoft.com"

    let session: URLSession
    let tokens: OneDriveTokens
    /// Base back-off in seconds (tests set it near zero).
    var retryBase: Double = 1
    var maxRetries = 5
    /// Longest wait Cirrus accepts from a Retry-After header before giving up with a clear error.
    var maxRetryAfter: Double = 120

    init(session: URLSession, tokens: OneDriveTokens) {
        self.session = session
        self.tokens = tokens
    }

    static func makeSession(_ transport: [AnyClass]?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpMaximumConnectionsPerHost = 6
        if let t = transport { c.protocolClasses = t }
        // Redirects are never followed automatically: the 302 from /content leads to a pre-authenticated
        // host that must not see the token, so Cirrus makes that hop itself.
        return URLSession(configuration: c, delegate: OneDriveTaskDelegate(), delegateQueue: nil)
    }

    static func isGraph(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return url.host?.lowercased() == graphHost
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
        case .notConnectedToInternet: return .server("Cirrus can’t reach OneDrive: this device is offline.")
        default: return .server("Cirrus couldn’t reach OneDrive (\(e.localizedDescription)). Try again.")
        }
    }

    /// A sentence for a Graph error answer. `name` is the item the request was about, if any.
    static func error(_ r: GraphResponse, name: String? = nil) -> CloudError {
        let j = r.json
        let code = j["error"]["code"].string ?? ""
        let inner = j["error"]["innerError"]["code"].string ?? j["error"]["innererror"]["code"].string ?? ""
        let message = j["error"]["message"].string ?? ""
        let what = name.map { "“\($0)”" } ?? "the item"
        switch r.status {
        case 401:
            return .signInNeeded("OneDrive")
        case 404:
            return .notFound
        case 409:
            if code == "nameAlreadyExists" || inner == "nameAlreadyExists" || message.lowercased().contains("same name") {
                return .denied("There’s already an item named \(what) in that folder on OneDrive.")
            }
            return .denied(message.isEmpty ? "OneDrive refused to change \(what) because it changed in the meantime. Try again." : message)
        case 423:
            return .denied("\(what.prefix(1).uppercased() + what.dropFirst()) is locked on OneDrive (it may be open or checked out in another app).")
        case 413:
            return .denied("\(what.prefix(1).uppercased() + what.dropFirst()) is too large for OneDrive.")
        case 507:
            return .quotaExceeded("OneDrive")
        case 403:
            if code == "quotaLimitReached" || inner == "quotaLimitReached" { return .quotaExceeded("OneDrive") }
            return .denied(message.isEmpty ? "OneDrive didn’t allow this change to \(what)." : "OneDrive didn’t allow this: \(message)")
        case 400:
            return .denied(message.isEmpty ? "OneDrive didn’t accept the request for \(what)." : "OneDrive didn’t accept this: \(message)")
        case 429, 503, 509:
            return .server("OneDrive is limiting how fast Cirrus can work right now. Try again in a few minutes.")
        default:
            if r.status >= 500 { return .server("OneDrive had a problem (HTTP \(r.status)). Try again later.") }
            return .server(message.isEmpty ? "OneDrive answered HTTP \(r.status)." : "\(message) (HTTP \(r.status))")
        }
    }

    // MARK: Requests

    /// Turns network failures into CloudError (and cancellation into CancellationError).
    static func guarded<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw networkError(e)
        }
    }

    func request(_ method: String, _ url: String, query: [(String, String)] = [], json body: JSON? = nil) throws -> URLRequest {
        guard var c = URLComponents(string: url) else { throw CloudError.server("Cirrus built a bad OneDrive address.") }
        if !query.isEmpty {
            c.queryItems = (c.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let u = c.url else { throw CloudError.server("Cirrus built a bad OneDrive address.") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data()
        }
        return req
    }

    /// Route shape for logs: no query strings, and path-addressed names cut off.
    static func describe(_ u: URL?) -> String {
        guard let u else { return "?" }
        guard isGraph(u) else { return (u.host ?? "?") + " (pre-authenticated)" }
        var p = u.path
        if let r = p.range(of: ":/") { p = String(p[..<r.lowerBound]) + ":/…" }
        return "graph" + p
    }

    /// One HTTP exchange, no retries; network failures come back as URLError. Callers set or strip auth.
    func transport(_ req: URLRequest, body: OneDriveBody = .none, toFile: Bool = false,
                   sent: (@Sendable (Int64) -> Void)? = nil, received: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> GraphResponse {
        let delegate = OneDriveTaskDelegate(sent: sent, received: received)
        let started = Date()
        let response: GraphResponse
        if toFile {
            let (tmp, resp) = try await session.download(for: req, delegate: delegate)
            guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let mine = Paths.tempFile(named: "onedrive.download")
            try? FileManager.default.removeItem(at: mine)
            try FileManager.default.moveItem(at: tmp, to: mine)
            var data = Data()
            if !(200..<300).contains(h.statusCode), let size = (try? FileManager.default.attributesOfItem(atPath: mine.path)[.size] as? NSNumber)?.intValue,
               size < 256 * 1024 {
                data = (try? Data(contentsOf: mine)) ?? Data()   // an error answer: keep it for the message
            }
            response = GraphResponse(status: h.statusCode, http: h, data: data, file: mine)
        } else {
            let data: Data, resp: URLResponse
            switch body {
            case .none: (data, resp) = try await session.data(for: req, delegate: delegate)
            case .data(let d): (data, resp) = try await session.upload(for: req, from: d, delegate: delegate)
            case .file(let u): (data, resp) = try await session.upload(for: req, fromFile: u, delegate: delegate)
            }
            guard let h = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            response = GraphResponse(status: h.statusCode, http: h, data: data, file: nil)
        }
        let line = "onedrive \(req.httpMethod ?? "GET") \(Self.describe(req.url)) → \(response.status)"
        if (200..<400).contains(response.status) { Log.debug(line + String(format: " (%.2fs)", Date().timeIntervalSince(started))) } else { Log.status(line) }
        return response
    }

    enum Retry { case safe, unsafe }

    /// A request with the account's token (when `auth`), one refresh-and-retry after a 401, and back-off on
    /// throttling (429/503/509, honouring Retry-After) and — for `.safe` requests — on 5xx answers and dropped
    /// connections. `.unsafe` requests are retried only when they certainly never reached the server or the
    /// server said it didn't process them. Every other status comes back as is. Network failures throw URLError.
    func send(_ request: URLRequest, body: OneDriveBody = .none, auth: Bool = true, retry: Retry, toFile: Bool = false,
              sent: (@Sendable (Int64) -> Void)? = nil, received: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> GraphResponse {
        var attempt = 0
        var stale: String?
        var reauthed = false
        while true {
            try Task.checkCancellation()
            var req = request
            var token: String?
            if auth {
                guard Self.isGraph(req.url) else {
                    throw CloudError.server("OneDrive pointed Cirrus at a server that isn’t Microsoft Graph, so Cirrus didn’t send your sign-in there.")
                }
                let t = try await tokens.accessToken(replacing: stale)
                token = t
                req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
            } else {
                guard req.url?.scheme?.lowercased() == "https" else { throw CloudError.server("OneDrive gave Cirrus an address that isn’t secure (https), so Cirrus didn’t use it.") }
                req.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            let r: GraphResponse
            do {
                r = try await transport(req, body: body, toFile: toFile, sent: sent, received: received)
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                guard Self.retryable(e, ambiguousOK: retry == .safe), attempt < maxRetries else { throw e }
                attempt += 1
                Log.status("onedrive \(req.httpMethod ?? "GET") \(Self.describe(req.url)) failed (\(e.code.rawValue)); retrying")
                try await sleep(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            if r.status == 401 && auth {
                r.discard()
                if !reauthed { reauthed = true; stale = token; continue }
                throw CloudError.signInNeeded("OneDrive")
            }
            let throttled = [429, 503, 509].contains(r.status)
            let serverError = [500, 502, 504].contains(r.status) && retry == .safe
            if (throttled || serverError) && attempt < maxRetries {
                if let after = r.retryAfter, after > maxRetryAfter { return r }   // too long to wait here: the caller reports it
                attempt += 1
                let d = delay(attempt: attempt, retryAfter: r.retryAfter)
                Log.status("onedrive back-off \(String(format: "%.1f", d))s after \(r.status)")
                r.discard()
                try await sleep(d)
                continue
            }
            return r
        }
    }

    /// GET/POST/PATCH/DELETE on a Graph path (or a full nextLink URL) that must answer 2xx with JSON.
    func json(_ method: String, _ path: String, query: [(String, String)] = [], body: JSON? = nil, retry: Retry, name: String? = nil) async throws -> JSON {
        let url = path.hasPrefix("https://") ? path : Self.graph + path
        let r = try await send(try request(method, url, query: query, json: body), retry: retry)
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

/// Per-request delegate: upload and download progress, and no automatic redirects (see `makeSession`).
final class OneDriveTaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
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
