import Foundation

/// Authenticated Google API transport: access-token caching with single-flight refresh, one
/// retry after a 401, and exponential back-off (with Retry-After) on rate limits and 5xx.
/// Logs carry method, host, path and status only — never tokens, bodies or account names.
public final class GoogleAPI: @unchecked Sendable {
    public struct Response: Sendable {
        public let data: Data
        public let http: HTTPURLResponse
        public var json: JSON { (try? JSON(data: data)) ?? .null }
        public var status: Int { http.statusCode }
        public func header(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
    }

    public enum Body: Sendable { case none, data(Data), file(URL) }

    public let accountID: String
    let oauth: GoogleOAuth
    let http: URLSession
    let refreshTokenProvider: @Sendable () async throws -> String
    private let lock = NSLock()
    private var access: GoogleTokens?
    private var refreshing: Task<GoogleTokens, Error>?
    private var _scopes: [String]

    /// Base back-off in seconds (tests set it near zero).
    public var retryBase: Double = 1.0
    public var maxRetries = 6
    /// Google asks for at least 30 s between retries of a rate-limited mediaItems:batchCreate.
    public var batchCreateMinBackoff: Double = 30
    /// Called when Google hands out a new refresh token (rare) so it can be saved.
    public var onNewRefreshToken: (@Sendable (String) -> Void)?

    public init(accountID: String, oauth: GoogleOAuth, scopes: [String], transport: [AnyClass]? = nil, initialTokens: GoogleTokens? = nil,
                refreshToken: @escaping @Sendable () async throws -> String) {
        self.accountID = accountID
        self.oauth = oauth
        _scopes = scopes
        access = initialTokens
        refreshTokenProvider = refreshToken
        http = Self.makeSession(transport)
    }

    public var scopes: [String] { lock.withLock { _scopes } }
    public func has(_ scope: String) -> Bool { scopes.contains(scope) }

    static func makeSession(_ transport: [AnyClass]?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.httpMaximumConnectionsPerHost = 6
        if let t = transport { c.protocolClasses = t }
        // No automatic redirects: Drive's "308 Resume Incomplete" must reach the uploader as is.
        return URLSession(configuration: c, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: Tokens

    func accessToken(force: Bool = false) async throws -> String {
        if !force, let a = lock.withLock({ access }), a.expiresAt.timeIntervalSinceNow > 90 { return a.accessToken }
        let task: Task<GoogleTokens, Error> = lock.withLock {
            if let r = refreshing { return r }
            let r = Task { [oauth, refreshTokenProvider] in try await oauth.refresh(try await refreshTokenProvider()) }
            refreshing = r
            return r
        }
        do {
            let t = try await task.value
            lock.withLock {
                access = t
                refreshing = nil
                if !t.scopes.isEmpty { _scopes = t.scopes }
            }
            if let r = t.refreshToken { onNewRefreshToken?(r) }
            return t.accessToken
        } catch {
            lock.withLock { refreshing = nil }
            throw error
        }
    }

    // MARK: Transport

    static let transientCodes: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                                                     .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .internationalRoamingOff,
                                                     .resourceUnavailable, .badServerResponse]
    /// Failures where the request certainly never reached the server.
    static let notSentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff]

    static func isTransient(_ e: URLError, ambiguousOK: Bool) -> Bool {
        ambiguousOK ? transientCodes.contains(e.code) : notSentCodes.contains(e.code)
    }

    /// One request with auth; refreshes and retries once on 401. Every status comes back as a Response.
    /// `followRedirects` (downloads only) follows 3xx to Google's own hosts over https; anything else is refused.
    func perform(_ request: URLRequest, body: Body = .none, followRedirects: Bool = false,
                 progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Response {
        // The bearer token only ever goes to Google.
        guard let target = request.url, GoogleRedirects.allowed(target) else {
            throw GoogleError.badResponse("Google pointed Cirrus at a server that isn’t Google’s, so Cirrus didn’t send your sign-in there.")
        }
        var authRetry = false
        while true {
            var req = request
            req.setValue("Bearer " + (try await accessToken(force: authRetry)), forHTTPHeaderField: "Authorization")
            let started = Date()
            let data: Data, resp: URLResponse
            do {
                let delegate = GoogleTaskDelegate(followRedirects: followRedirects, progress: progress)
                switch body {
                case .none: (data, resp) = try await http.data(for: req, delegate: delegate)
                case .data(let d): (data, resp) = try await http.upload(for: req, from: d, delegate: delegate)
                case .file(let u): (data, resp) = try await http.upload(for: req, fromFile: u, delegate: delegate)
                }
            } catch let e as URLError where e.code == .cancelled {
                throw GoogleError.cancelled
            }
            guard let h = resp as? HTTPURLResponse else { throw GoogleError.badResponse("No response from Google.") }
            let secs = Date().timeIntervalSince(started)
            let line = "google \(req.httpMethod ?? "GET") \(req.url?.host ?? "")\(req.url?.path ?? "") → \(h.statusCode)"
            if (200..<300).contains(h.statusCode) || h.statusCode == 308 { Log.debug(line + String(format: " (%.2fs)", secs)) } else { Log.status(line) }
            if h.statusCode == 401 && !authRetry { authRetry = true; continue }
            if [301, 302, 303, 307].contains(h.statusCode) {
                // A redirect we didn't follow: not to an https Google host, or not a download.
                throw GoogleError.badResponse("Google redirected Cirrus somewhere it doesn’t trust, so the download stopped.")
            }
            return Response(data: data, http: h)
        }
    }

    enum Verdict: Equatable { case ok, retry(Double?), fail(GoogleError) }

    /// How to treat a status. Rate limits and server errors are retried; daily caps and full storage stop the run.
    static func classify(_ status: Int, _ data: Data, retryAfter: String?) -> Verdict {
        if (200..<300).contains(status) || status == 308 { return .ok }
        let j = (try? JSON(data: data)) ?? .null
        let err = j["error"]
        let message = err["message"].string ?? err.string ?? ""
        let reasons = err["errors"].array.compactMap { $0["reason"].string } + err["details"].array.compactMap { $0["reason"].string }
        let after = retryAfter.flatMap(Double.init)
        let lower = message.lowercased()
        let daily = reasons.contains { ["dailyLimitExceeded", "dailyLimitExceededUnreg", "uploadLimitExceeded", "quotaExceeded"].contains($0) }
            || lower.contains("per day") || lower.contains("daily limit")
        switch status {
        case 401:
            return .fail(.reconnect("Google no longer accepts Cirrus’s sign-in. Select Connect Google to continue; the move picks up where it stopped."))
        case 403:
            if reasons.contains("storageQuotaExceeded") || lower.contains("storage quota") { return .fail(.storageFull) }
            if daily { return .fail(.dailyLimit(dailyMessage(message))) }
            if reasons.contains(where: { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }) { return .retry(after) }
            if reasons.contains("insufficientPermissions") || lower.contains("insufficient authentication scopes") || lower.contains("insufficient permission") {
                return .fail(.missingScope(lower.contains("photos") ? "Google Photos" : "Google Drive"))
            }
            if lower.contains("has not been used in project") || lower.contains("is disabled") || reasons.contains("accessNotConfigured") {
                return .fail(.badResponse("An API Cirrus needs is turned off in your Google Cloud project. In Set Up Google Access…, open the Drive API and Photos Library API pages and select Enable. (\(message))"))
            }
            return .fail(.http(403, message))
        case 429:
            if daily { return .fail(.dailyLimit(dailyMessage(message))) }
            return .retry(after)
        case 500, 502, 503, 504:
            return .retry(after)
        default:
            return .fail(.http(status, message))
        }
    }

    static func dailyMessage(_ raw: String) -> String {
        if raw.lowercased().contains("photos") {
            return "Google Photos’ daily limit for your Google Cloud project (10,000 requests) is used up. Run the move again tomorrow — it continues where it stopped."
        }
        return "Google’s daily upload limit was reached (about 750 GB a day). Run the move again tomorrow — it continues where it stopped."
    }

    func delay(attempt: Int, retryAfter: Double?, minimum: Double = 0) -> Double {
        if let r = retryAfter { return max(minimum, min(r, 120)) }
        let base = min(retryBase * pow(2, Double(attempt)), 32 * max(retryBase, 0.001))
        return max(minimum, base + Double.random(in: 0...max(retryBase, 0.001)))
    }

    func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Request with retries. `idempotent` allows retrying after an ambiguous network failure.
    func send(_ request: URLRequest, body: Body = .none, idempotent: Bool, minBackoff: Double = 0, followRedirects: Bool = false,
              progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Response {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let r: Response
            do { r = try await perform(request, body: body, followRedirects: followRedirects, progress: progress) } catch let e as URLError {
                guard Self.isTransient(e, ambiguousOK: idempotent), attempt < maxRetries else { throw e }
                attempt += 1
                try await sleep(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            switch Self.classify(r.status, r.data, retryAfter: r.header("Retry-After")) {
            case .ok: return r
            case .fail(let e): throw e
            case .retry(let after):
                guard attempt < maxRetries else { throw r.status == 429 || r.status == 403 ? GoogleError.rateLimited : GoogleError.http(r.status, "Google kept failing; try again later.") }
                attempt += 1
                let d = delay(attempt: attempt, retryAfter: after, minimum: r.status == 429 ? minBackoff : 0)
                Log.status("google back-off \(String(format: "%.1f", d))s after \(r.status)")
                try await sleep(d)
            }
        }
    }

    // MARK: JSON helpers

    func request(_ method: String, _ url: String, query: [String: String] = [:], json body: JSON? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        guard var c = URLComponents(string: url) else { throw GoogleError.badResponse("Bad URL") }
        if !query.isEmpty {
            c.queryItems = (c.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let u = c.url else { throw GoogleError.badResponse("Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data()
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func json(_ method: String, _ url: String, query: [String: String] = [:], body: JSON? = nil, idempotent: Bool, minBackoff: Double = 0) async throws -> JSON {
        try await send(try request(method, url, query: query, json: body), idempotent: idempotent, minBackoff: minBackoff).json
    }
}

/// Where a bearer token may go: Google's own hosts, over https.
public enum GoogleRedirects {
    static let suffixes = ["googleapis.com", "google.com", "googleusercontent.com"]
    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Per-request delegate: upload progress, and the redirect policy. Downloads may follow 3xx to Google hosts
/// (export links and Photos base URLs can bounce between them); nothing else is followed — Drive's
/// "308 Resume Incomplete" must reach the uploader, and a redirect elsewhere would carry the token away.
final class GoogleTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followRedirects: Bool
    let progress: (@Sendable (Int64) -> Void)?
    init(followRedirects: Bool, progress: (@Sendable (Int64) -> Void)?) { self.followRedirects = followRedirects; self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard followRedirects, let url = request.url, GoogleRedirects.allowed(url) else {
            Log.status("google redirect refused (\(response.statusCode) to \(request.url?.host ?? "?"))")
            return nil
        }
        var next = request
        // The download still needs the token at Google's other host; URLSession may have dropped it.
        if next.value(forHTTPHeaderField: "Authorization") == nil, let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            next.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return next
    }
}

extension JSON {
    /// Drive returns 64-bit numbers as strings.
    var int64String: Int64? { string.flatMap { Int64($0) } ?? int64 }
}
