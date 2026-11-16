import Foundation

// The wire layer shared by the Nextcloud and plain WebDAV flavours: URL rules, path encoding, an HTTP client
// with Basic auth, retries and streaming transfers, and a namespace-aware PROPFIND (207 Multi-Status) parser.
// Nothing here logs a password, an Authorization header or a file path.

// MARK: - URL rules and path encoding

enum DAVURL {
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    static func isLoopback(_ host: String) -> Bool { loopbackHosts.contains(host.lowercased()) }

    /// https everywhere; plain http only to this device itself (a test server on localhost).
    static func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw CloudError.notConfigured("“\(url.absoluteString)” isn’t a server address Cirrus can use. Enter an address like https://cloud.example.com.")
        }
        if scheme == "https" { return }
        if scheme == "http" {
            if isLoopback(host) { return }
            throw CloudError.unsupported("Cirrus connects only over https://, so your password and files are never sent unencrypted. "
                + "Use the server’s https:// address (plain http:// works only for a server on this device, such as localhost).")
        }
        throw CloudError.unsupported("Cirrus can’t connect to “\(scheme)://” addresses. Use the server’s https:// address.")
    }

    /// RFC 3986 unreserved characters (ASCII letters, digits, - . _ ~): everything else in a name is percent-encoded,
    /// including + & ; = which some servers would otherwise read as something else.
    static let segmentAllowed: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s
    }()

    static func encodeSegment(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? s }

    /// "/a b/c#1/" → "/a%20b/c%231/" (keeps the leading and trailing slashes).
    static func encodePath(_ path: String) -> String {
        path.components(separatedBy: "/").map(encodeSegment).joined(separator: "/")
    }

    static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }

    /// `base` must end with "/"; `path` is a decoded path starting with "/".
    static func join(_ base: URL, _ path: String) -> URL {
        var s = base.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        let rel = encodePath(String(path.drop { $0 == "/" }))
        return URL(string: s + rel) ?? base
    }

    /// The decoded path of a URL, keeping a trailing slash.
    static func decodedPath(_ url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        return decode(p.isEmpty ? "/" : p)
    }

    /// Collapses "//" and makes sure the path starts with "/".
    static func clean(_ path: String) -> String {
        var p = path
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        return p.hasPrefix("/") ? p : "/" + p
    }

    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let i = p.lastIndex(of: "/") else { return "/" }
        return String(p[...i])
    }

    static func lastSegment(_ path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        return p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    static func trimmedSlash(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: - HTTP client

final class DAVClient: @unchecked Sendable {
    struct Response: @unchecked Sendable {
        let status: Int
        let data: Data
        let http: HTTPURLResponse
        /// True when this answer came after a retry (the first attempt may have reached the server).
        let retried: Bool
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        var ok: Bool { (200..<300).contains(status) }
    }

    enum Body { case none, data(Data), file(URL) }

    /// `.safe`: idempotent, retried after 429, 502–504 and dropped connections.
    /// `.rateLimitOnly`: may have taken effect, so retried only when the server certainly didn't act (429, never connected).
    enum Retry { case safe, rateLimitOnly }

    static var userAgent: String {
        #if os(macOS)
        return "Cirrus (Mac)"
        #else
        return "Cirrus (iOS)"
        #endif
    }

    let session: URLSession
    let delegate: DAVSessionDelegate
    let authorization: String?
    /// For error messages: "Nextcloud (alex@cloud.example.com)".
    let serviceName: String
    private let lock = NSLock()
    private var _retryBase = 0.5
    /// Base back-off in seconds (tests set it near zero).
    var retryBase: Double { get { lock.withLock { _retryBase } } set { lock.withLock { _retryBase = newValue } } }
    var maxRetries = 4

    init(username: String?, password: String?, serviceName: String, transport: [AnyClass]?) {
        if let u = username, !u.isEmpty {
            let raw = Data((u + ":" + (password ?? "")).utf8).base64EncodedString()
            authorization = "Basic " + raw
        } else {
            authorization = nil
        }
        self.serviceName = serviceName
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24 * 2
        c.httpMaximumConnectionsPerHost = 6
        if let t = transport { c.protocolClasses = t }
        delegate = DAVSessionDelegate()
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    static let transientCodes: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                                                     .dnsLookupFailed, .cannotFindHost, .internationalRoamingOff, .resourceUnavailable]
    /// Failures where the request certainly never reached the server.
    static let notSentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
                                                   .internationalRoamingOff]

    func makeRequest(_ method: String, _ url: URL, headers: [String: String], timeout: TimeInterval?) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout ?? 60)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let a = authorization { req.setValue(a, forHTTPHeaderField: "Authorization") }
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// One request with retries. 401 → signInNeeded, 423 → denied (locked), 507 → quotaExceeded;
    /// every other status comes back to the caller, who knows what it means for that operation.
    func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Body = .none, retry: Retry,
              timeout: TimeInterval? = nil, progress: (@Sendable (Int64, Int64) -> Void)? = nil, total: Int64 = 0) async throws -> Response {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let req = makeRequest(method, url, headers: headers, timeout: timeout)
            let started = Date()
            let data: Data, resp: URLResponse
            let d = DAVTaskDelegate(progress: progress, total: total)
            do {
                switch body {
                case .none: (data, resp) = try await session.data(for: req, delegate: d)
                case .data(let b): (data, resp) = try await session.upload(for: req, from: b, delegate: d)
                case .file(let f): (data, resp) = try await session.upload(for: req, fromFile: f, delegate: d)
                }
            } catch let e as URLError {
                if e.code == .cancelled && d.authRejected && !Task.isCancelled { throw CloudError.signInNeeded(serviceName) }
                if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
                let again = retry == .safe ? Self.transientCodes.contains(e.code) : Self.notSentCodes.contains(e.code)
                guard again, attempt < maxRetries else { throw Self.networkError(e, host: url.host) }
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: nil))
                continue
            } catch is CancellationError {
                throw CancellationError()
            }
            guard let h = resp as? HTTPURLResponse else { throw CloudError.server("The server sent an answer Cirrus couldn’t read.") }
            let status = h.statusCode
            let line = "dav \(method) \(url.host ?? "") → \(status)"
            if (200..<400).contains(status) || status == 404 { Log.debug(line + String(format: " (%.2fs)", Date().timeIntervalSince(started))) } else { Log.status(line) }
            if status == 429 || (retry == .safe && [502, 503, 504].contains(status)) {
                if attempt < maxRetries {
                    attempt += 1
                    let d = delay(attempt: attempt, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                    Log.status("dav back-off \(String(format: "%.1f", d))s after \(status)")
                    try await pause(d)
                    continue
                }
                throw CloudError.server("The server is busy (\(status)\(DAVErrorBody.suffix(data))). Try again in a few minutes.")
            }
            let r = Response(status: status, data: data, http: h, retried: attempt > 0)
            try Self.checkCommon(r, serviceName: serviceName)
            return r
        }
    }

    static func checkCommon(_ r: Response, serviceName: String) throws {
        switch r.status {
        case 401: throw CloudError.signInNeeded(serviceName)
        case 423: throw CloudError.denied("The item is locked on the server (it may be open in another app). Try again later.")
        case 507: throw CloudError.quotaExceeded(serviceName)
        default: break
        }
    }

    /// Streams a GET into a file (never held in memory). On success the file is moved to `destination`.
    func download(_ url: URL, to destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Response {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let req = makeRequest("GET", url, headers: ["Accept-Encoding": "identity"], timeout: nil)
            let file: URL, h: HTTPURLResponse
            do {
                (file, h) = try await delegate.run(session.downloadTask(with: req), expected: expected, progress: progress)
            } catch is DAVAuthRejected {
                throw CloudError.signInNeeded(serviceName)
            } catch let e as URLError {
                if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard Self.transientCodes.contains(e.code), attempt < maxRetries else { throw Self.networkError(e, host: url.host) }
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            let status = h.statusCode
            Log.debug("dav GET (download) \(url.host ?? "") → \(status)")
            if (200..<300).contains(status) {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: file, to: destination)
                try? fm.removeItem(at: file.deletingLastPathComponent())
                return Response(status: status, data: Data(), http: h, retried: attempt > 0)
            }
            // An error page: keep a little of it for the message.
            let head = (try? FileHandle(forReadingFrom: file)).flatMap { fh -> Data? in defer { try? fh.close() }; return try? fh.read(upToCount: 64 * 1024) } ?? Data()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            if status == 429 || [502, 503, 504].contains(status), attempt < maxRetries {
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: h.value(forHTTPHeaderField: "Retry-After")))
                continue
            }
            let r = Response(status: status, data: head, http: h, retried: attempt > 0)
            try Self.checkCommon(r, serviceName: serviceName)
            return r
        }
    }

    func delay(attempt: Int, retryAfter: String?) -> Double {
        if let ra = retryAfter?.trimmingCharacters(in: .whitespaces), !ra.isEmpty {
            if let secs = Double(ra) { return max(0, min(secs, 120)) }
            if let date = DAVDates.http(ra) { return max(0, min(date.timeIntervalSinceNow, 120)) }
        }
        let base = retryBase
        return min(base * pow(2, Double(attempt - 1)), 30) + Double.random(in: 0...max(base, 0.0001)) * 0.5
    }

    func pause(_ seconds: Double) async throws {
        guard seconds > 0 else { try Task.checkCancellation(); return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func networkError(_ e: URLError, host: String?) -> CloudError {
        let h = host ?? "the server"
        switch e.code {
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return .server("This device is offline. Connect to the internet and try again.")
        case .cannotFindHost, .dnsLookupFailed:
            return .server("Cirrus couldn’t find the server “\(h)”. Check the address.")
        case .cannotConnectToHost:
            return .server("“\(h)” didn’t accept a connection. Check that the server is running and the address is right.")
        case .timedOut:
            return .server("“\(h)” took too long to answer. Try again.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
            return .server("The secure connection to “\(h)” failed: its certificate isn’t trusted by this device. Check the server’s https setup.")
        case .appTransportSecurityRequiresSecureConnection:
            return .unsupported("Cirrus connects only over https://.")
        default:
            return .server("The connection to “\(h)” failed (\(e.localizedDescription)).")
        }
    }
}

/// Per-task delegate: upload progress, and no redirects (Basic credentials must never follow a redirect elsewhere).
final class DAVTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (@Sendable (Int64, Int64) -> Void)?
    let total: Int64
    private let lock = NSLock()
    private var _authRejected = false
    /// The server refused the credentials Cirrus sent (see `DAVSessionDelegate.answer`).
    var authRejected: Bool { lock.withLock { _authRejected } }
    init(progress: (@Sendable (Int64, Int64) -> Void)?, total: Int64) { self.progress = progress; self.total = total }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let a = DAVSessionDelegate.answer(challenge)
        if a.0 == .cancelAuthenticationChallenge { lock.withLock { _authRejected = true } }
        return a
    }
}

/// A download whose credentials the server refused.
struct DAVAuthRejected: Error {}

/// Session delegate: streaming downloads to disk with progress (like ContentDownloader), no redirects.
final class DAVSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    final class Job {
        let progress: @Sendable (Int64, Int64) -> Void
        let expected: Int64
        var file: URL?
        var moveError: Error?
        var authRejected = false
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
        init(progress: @escaping @Sendable (Int64, Int64) -> Void, expected: Int64) { self.progress = progress; self.expected = expected }
    }

    private let lock = NSLock()
    private var jobs = [ObjectIdentifier: Job]()

    func run(_ task: URLSessionDownloadTask, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        let job = Job(progress: progress, expected: expected)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                job.continuation = cont
                lock.withLock { jobs[ObjectIdentifier(task)] = job }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func job(_ task: URLSessionTask) -> Job? { lock.withLock { jobs[ObjectIdentifier(task)] } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let j = job(downloadTask) else { return }
        j.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : j.expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let j = job(downloadTask) else { return }
        // The system deletes `location` when this returns, so claim it now.
        let keep = Paths.tempFile(named: "download")
        do { try FileManager.default.moveItem(at: location, to: keep); j.file = keep } catch { j.moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let j = lock.withLock({ jobs.removeValue(forKey: ObjectIdentifier(task)) }), let cont = j.continuation else { return }
        if let error {
            if let f = j.file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
            cont.resume(throwing: lock.withLock { j.authRejected } ? DAVAuthRejected() : error)
        } else if let e = j.moveError {
            cont.resume(throwing: e)
        } else if let f = j.file, let h = task.response as? HTTPURLResponse {
            cont.resume(returning: (f, h))
        } else if let h = task.response as? HTTPURLResponse {
            // An empty body (a zero-byte file): make an empty file.
            let keep = Paths.tempFile(named: "download")
            FileManager.default.createFile(atPath: keep.path, contents: Data())
            cont.resume(returning: (keep, h))
        } else {
            cont.resume(throwing: CloudError.server("The server didn’t send the file."))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let a = Self.answer(challenge)
        if a.0 == .cancelAuthenticationChallenge, let j = job(task) { lock.withLock { j.authRejected = true } }
        return a
    }

    /// Certificates: the system's normal checks. HTTP auth: Cirrus already sent its Basic credentials, so the challenge
    /// that comes with a 401 means they were refused. Any other answer makes URLSession send the request a second time
    /// (doubling failed sign-ins on servers that throttle them), so the task stops here and the caller reports a 401.
    static func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { return (.performDefaultHandling, nil) }
        return (.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Dates

enum DAVDates {
    private static let lock = NSLock()
    private static let rfc1123: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz",
                                                   "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"].map { f in
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "GMT")
        d.dateFormat = f
        return d
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// RFC 1123 (getlastmodified, Last-Modified, Retry-After), with the older RFC 850 / asctime forms as fallbacks.
    static func http(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return lock.withLock { rfc1123.lazy.compactMap { $0.date(from: t) }.first }
    }

    static func httpString(_ d: Date) -> String { lock.withLock { rfc1123[0].string(from: d) } }

    /// RFC 3339 (creationdate).
    static func iso8601(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return lock.withLock { iso.date(from: t) ?? isoFrac.date(from: t) } ?? http(t)
    }

    static func isoString(_ d: Date) -> String { lock.withLock { iso.string(from: d) } }
}

// MARK: - Multi-Status parsing

enum DAVNS {
    static let dav = "DAV:"
    static let oc = "http://owncloud.org/ns"
    static let nc = "http://nextcloud.org/ns"
}

/// One <response> of a 207 Multi-Status reply.
struct DAVResource: Sendable {
    var href: String
    /// Props from the 200 propstat(s), keyed "namespace local" (e.g. "DAV: getetag").
    var props: [String: String] = [:]
    var isCollection = false
    /// The <status> directly inside <response> (when the whole response failed, e.g. 404).
    var status: Int?
    /// Resolved, percent-decoded path (set by `DAVMultistatus.parse`).
    var path = ""

    func prop(_ ns: String, _ name: String) -> String? { props[ns + " " + name] }
    func dav(_ name: String) -> String? { prop(DAVNS.dav, name) }
    func oc(_ name: String) -> String? { prop(DAVNS.oc, name) }
    func nc(_ name: String) -> String? { prop(DAVNS.nc, name) }

    var size: Int64 { dav("getcontentlength").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? oc("size").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0 }
    var modified: Date? { dav("getlastmodified").flatMap(DAVDates.http) }
    var created: Date? { dav("creationdate").flatMap(DAVDates.iso8601) }
    var etag: String? {
        guard var e = dav("getetag")?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        if e.hasPrefix("W/") { e.removeFirst(2) }
        if e.count >= 2, e.hasPrefix("\""), e.hasSuffix("\"") { e = String(e.dropFirst().dropLast()) }
        return e
    }
    var fileID: String? { oc("fileid")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyDAV }
    var hasPreview: Bool? { nc("has-preview").map { $0.trimmingCharacters(in: .whitespaces).lowercased() == "true" } }
    var isShared: Bool { !(oc("share-types")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

extension String {
    var nilIfEmptyDAV: String? { isEmpty ? nil : self }
}

final class DAVMultistatus: NSObject, XMLParserDelegate {
    private var responses: [DAVResource] = []
    private var current: DAVResource?
    private var stack: [(ns: String, name: String)] = []
    private var text = ""
    private var propstatProps: [String: String] = [:]
    private var propstatCollection = false
    private var propstatStatus: Int?
    private var inPropstat = false
    private var propKey: String?
    private var propDepth = 0
    private var propNestedHref: String?
    /// Text of child elements (e.g. <oc:share-types><oc:share-type>3</oc:share-type></oc:share-types>), comma-joined.
    private var propNestedText: [String] = []
    private var sawMultistatus = false

    static func ns(_ uri: String?) -> String { (uri?.isEmpty ?? true) ? DAVNS.dav : uri! }

    /// Parses a 207 body; throws when it isn't a complete Multi-Status document. `requestURL` resolves relative hrefs.
    static func parse(_ data: Data, requestURL: URL) throws -> [DAVResource] {
        let p = DAVMultistatus()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = p
        guard parser.parse(), p.sawMultistatus else {
            throw CloudError.server("The server’s folder listing was incomplete or unreadable, so nothing was shown. Try again.")
        }
        return p.responses.map { r in
            var r = r
            r.path = resolve(r.href, against: requestURL)
            return r
        }
    }

    /// Absolute URL, absolute path or relative reference → percent-decoded, NFC-free (server form) path.
    static func resolve(_ href: String, against base: URL) -> String {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        var encodedPath: String?
        if let u = URL(string: h, relativeTo: base)?.absoluteURL, let c = URLComponents(url: u, resolvingAgainstBaseURL: true) {
            encodedPath = c.percentEncodedPath
        } else if h.hasPrefix("/") {
            encodedPath = h
        } else if let r = h.range(of: "://"), let slash = h[r.upperBound...].firstIndex(of: "/") {
            encodedPath = String(h[slash...])
        }
        let decoded = DAVURL.decode(encodedPath ?? h)
        // Resolve "." and ".." segments, keep a trailing slash.
        let trailing = decoded.hasSuffix("/")
        var out = [String]()
        for seg in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." { _ = out.popLast(); continue }
            out.append(String(seg))
        }
        let joined = "/" + out.joined(separator: "/")
        return trailing && joined != "/" ? joined + "/" : joined
    }

    static func statusCode(_ line: String) -> Int? {
        // "HTTP/1.1 200 OK"
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let ns = Self.ns(namespaceURI)
        stack.append((ns, elementName))
        text = ""
        if ns == DAVNS.dav && elementName == "multistatus" { sawMultistatus = true }
        if ns == DAVNS.dav && elementName == "response" && propKey == nil {
            current = DAVResource(href: "")
            return
        }
        guard current != nil else { return }
        if propKey != nil {
            propDepth += 1
            if ns == DAVNS.dav && elementName == "collection" { propstatCollection = true }
            return
        }
        if ns == DAVNS.dav && elementName == "propstat" {
            inPropstat = true
            propstatProps = [:]
            propstatCollection = false
            propstatStatus = nil
            return
        }
        // A direct child of <prop> is a property.
        if inPropstat, stack.count >= 2, stack[stack.count - 2].ns == DAVNS.dav, stack[stack.count - 2].name == "prop" {
            propKey = ns + " " + elementName
            propDepth = 0
            propNestedHref = nil
            propNestedText = []
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let ns = Self.ns(namespaceURI)
        defer { if !stack.isEmpty { stack.removeLast() } }
        guard current != nil else { text = ""; return }
        if let key = propKey {
            if propDepth > 0 {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if ns == DAVNS.dav && elementName == "href" { propNestedHref = t } else if !t.isEmpty { propNestedText.append(t) }
                propDepth -= 1
                text = ""
                return
            }
            // The property itself ends.
            propstatProps[key] = propNestedHref ?? (propNestedText.isEmpty ? text : propNestedText.joined(separator: ","))
            propKey = nil
            text = ""
            return
        }
        if ns == DAVNS.dav {
            switch elementName {
            case "href" where !inPropstat:
                current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "status" where inPropstat:
                propstatStatus = Self.statusCode(text)
            case "status" where !inPropstat:
                current?.status = Self.statusCode(text)
            case "propstat":
                inPropstat = false
                if (propstatStatus ?? 200) == 200 {
                    current?.props.merge(propstatProps) { $1 }
                    if propstatCollection { current?.isCollection = true }
                }
            case "response":
                if let c = current { responses.append(c) }
                current = nil
            default: break
            }
        }
        text = ""
    }
}

/// Sabre/Nextcloud error bodies: <d:error><s:message>…</s:message></d:error>.
enum DAVErrorBody {
    static func message(_ data: Data) -> String? {
        guard !data.isEmpty, data.count < 256 * 1024 else { return nil }
        let p = MessageFinder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = p
        _ = parser.parse()
        let m = p.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m, !m.isEmpty else { return nil }
        return String(m.prefix(300))
    }

    static func suffix(_ data: Data) -> String { message(data).map { ": " + $0 } ?? "" }

    final class MessageFinder: NSObject, XMLParserDelegate {
        var message: String?
        var inMessage = false
        var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if elementName == "message" { inMessage = true; text = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inMessage { text += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "message" { inMessage = false; if message == nil { message = text } }
        }
    }
}

/// A FIFO lock for async code (an actor alone would let calls interleave at every await).
final class DAVAsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ op: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let run: Bool = lock.withLock {
                if !busy { busy = true; return true }
                waiters.append(c)
                return false
            }
            if run { c.resume() }
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
