import CryptoKit
import Foundation

/// The wire layer for Immich: JSON calls under `<server>/api` with the `x-api-key` header, retries with back-off
/// (429, 502–504, dropped connections), streaming downloads to disk, multipart uploads from disk, and Immich's
/// error bodies mapped to `CloudError`. Redirects are never followed (the key must not travel to another host).
/// Nothing here logs the API key, a query string or a file name.
final class ImmichClient: @unchecked Sendable {
    struct Response: @unchecked Sendable {
        let status: Int
        let data: Data
        let http: HTTPURLResponse
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        var ok: Bool { (200..<300).contains(status) }
    }

    /// `.safe`: idempotent, retried after 429, 502–504 and dropped connections.
    /// `.rateLimitOnly`: may have taken effect, so retried only when the server certainly didn't act.
    enum Retry { case safe, rateLimitOnly }

    let server: URL
    let apiBase: String
    let apiKey: String?
    /// For messages: "Immich (alex@example.com)".
    let serviceName: String
    let session: URLSession
    let delegate: DAVSessionDelegate
    private let lock = NSLock()
    private var _retryBase = 0.5
    /// Base back-off in seconds (tests set it near zero).
    var retryBase: Double { get { lock.withLock { _retryBase } } set { lock.withLock { _retryBase = newValue } } }
    var maxRetries = 4

    init(server: URL, apiKey: String?, serviceName: String, transport: [AnyClass]?) {
        self.server = server
        apiBase = Immich.serverString(server) + "/api"
        self.apiKey = apiKey
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

    /// `path` starts with "/" and may carry its own query ("/assets/x/thumbnail?size=preview").
    func url(_ path: String, query: [String: String] = [:]) -> URL {
        guard var c = URLComponents(string: apiBase + path) else { return URL(string: apiBase)! }
        if !query.isEmpty {
            var items = c.queryItems ?? []
            items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            c.queryItems = items
        }
        return c.url ?? URL(string: apiBase)!
    }

    func makeRequest(_ method: String, _ url: URL, headers: [String: String], timeout: TimeInterval?) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout ?? 60)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let k = apiKey { req.setValue(k, forHTTPHeaderField: "x-api-key") }
        req.setValue(DAVClient.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// The path for logs: no query, ids shortened.
    static func logPath(_ path: String) -> String {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return p.split(separator: "/").map { $0.count == 36 && $0.filter({ $0 == "-" }).count == 4 ? "…" : String($0) }.joined(separator: "/")
    }

    /// One request with retries. Every status comes back to the caller except the retried ones that ran out.
    func send(_ method: String, _ path: String, query: [String: String] = [:], json: JSON? = nil, body: DAVClient.Body = .none,
              headers: [String: String] = [:], retry: Retry, progress: (@Sendable (Int64, Int64) -> Void)? = nil,
              total: Int64 = 0) async throws -> Response {
        var hdrs = headers
        var payload = body
        if let json {
            payload = .data(json.data())
            hdrs["Content-Type"] = "application/json"
        }
        let url = url(path, query: query)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let req = makeRequest(method, url, headers: hdrs, timeout: nil)
            let started = Date()
            let data: Data, resp: URLResponse
            let d = DAVTaskDelegate(progress: progress, total: total)
            do {
                switch payload {
                case .none: (data, resp) = try await session.data(for: req, delegate: d)
                case .data(let b): (data, resp) = try await session.upload(for: req, from: b, delegate: d)
                case .file(let f): (data, resp) = try await session.upload(for: req, fromFile: f, delegate: d)
                }
            } catch let e as URLError {
                if e.code == .cancelled && d.authRejected && !Task.isCancelled { throw Self.proxySignIn }
                if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
                let again = retry == .safe ? DAVClient.transientCodes.contains(e.code) : DAVClient.notSentCodes.contains(e.code)
                guard again, attempt < maxRetries else { throw DAVClient.networkError(e, host: url.host) }
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: nil))
                continue
            } catch is CancellationError {
                throw CancellationError()
            }
            guard let h = resp as? HTTPURLResponse else { throw CloudError.server("The server sent an answer Cirrus couldn’t read.") }
            let status = h.statusCode
            let line = "immich \(method) \(Self.logPath(path)) → \(status)"
            if status < 400 || status == 404 { Log.debug(line + String(format: " (%.2fs)", Date().timeIntervalSince(started))) } else { Log.status(line) }
            if status == 429 || (retry == .safe && [502, 503, 504].contains(status)) {
                if attempt < maxRetries {
                    attempt += 1
                    let wait = delay(attempt: attempt, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                    Log.status("immich back-off \(String(format: "%.1f", wait))s after \(status)")
                    try await pause(wait)
                    continue
                }
                throw CloudError.server("The Immich server is busy (\(status)). Try again in a few minutes.")
            }
            return Response(status: status, data: data, http: h)
        }
    }

    /// A JSON call: 2xx → the parsed body (`.null` when empty), anything else → a `CloudError`.
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], json: JSON? = nil, retry: Retry) async throws -> JSON {
        let r = try await send(method, path, query: query, json: json, retry: retry)
        guard r.ok else { throw failure(r) }
        if r.data.isEmpty { return .null }
        guard let j = try? JSON(data: r.data) else { throw CloudError.server("Immich sent an answer Cirrus couldn’t read.") }
        return j
    }

    /// Bytes of a small GET (thumbnails).
    func fetch(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let r = try await send("GET", path, query: query, retry: .safe)
        guard r.ok else { throw failure(r) }
        return r.data
    }

    /// Streams a GET into `destination` (never held in memory), replacing what's there.
    func download(_ path: String, query: [String: String] = [:], to destination: URL, expected: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let url = url(path, query: query)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let req = makeRequest("GET", url, headers: ["Accept": "*/*", "Accept-Encoding": "identity"], timeout: nil)
            let file: URL, h: HTTPURLResponse
            do {
                (file, h) = try await delegate.run(session.downloadTask(with: req), expected: expected, progress: progress)
            } catch is DAVAuthRejected {
                throw Self.proxySignIn
            } catch let e as URLError {
                if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard DAVClient.transientCodes.contains(e.code), attempt < maxRetries else { throw DAVClient.networkError(e, host: url.host) }
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            let status = h.statusCode
            Log.debug("immich GET (download) \(Self.logPath(path)) → \(status)")
            if (200..<300).contains(status) {
                let fm = FileManager.default
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: file, to: destination)
                } catch {
                    try? fm.removeItem(at: file.deletingLastPathComponent())
                    throw error
                }
                try? fm.removeItem(at: file.deletingLastPathComponent())
                return
            }
            let head = (try? FileHandle(forReadingFrom: file)).flatMap { fh -> Data? in defer { try? fh.close() }; return try? fh.read(upToCount: 64 * 1024) } ?? Data()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            if status == 429 || [502, 503, 504].contains(status), attempt < maxRetries {
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: h.value(forHTTPHeaderField: "Retry-After")))
                continue
            }
            throw failure(Response(status: status, data: head, http: h))
        }
    }

    // MARK: Errors

    /// An HTTP auth challenge: Immich itself never sends one, so it's a proxy in front of it.
    static let proxySignIn = CloudError.denied("The server in front of Immich asks for its own password, which Cirrus can’t answer. "
        + "Connect to Immich directly, or let the API path (/api) through the proxy without a sign-in.")

    /// The message of an Immich error body: v3 `{"message": "…", "errors": [{"path", "message"}]}`, or the older
    /// `{"message": ["…"], "error": "Bad Request", "statusCode": 400}`.
    static func message(_ data: Data) -> String? {
        guard let j = try? JSON(data: data) else { return nil }
        var parts = [String]()
        switch j["message"] {
        case .string(let s): parts.append(s)
        case .array(let a): parts += a.compactMap(\.string)
        default: break
        }
        let details = j["errors"].array.compactMap { e -> String? in
            guard let m = e["message"].string else { return nil }
            let path: String
            switch e["path"] {
            case .array(let p): path = p.compactMap(\.string).joined(separator: ".")
            case .string(let p): path = p
            default: path = ""
            }
            return path.isEmpty ? m : "\(path): \(m)"
        }
        if !details.isEmpty { parts.append(details.prefix(3).joined(separator: "; ")) }
        let s = parts.joined(separator: " — ").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(300))
    }

    func failure(_ r: Response) -> CloudError { Self.failure(status: r.status, data: r.data, serviceName: serviceName) }

    static func failure(status: Int, data: Data, serviceName: String) -> CloudError {
        let msg = message(data)
        switch status {
        case 401:
            return .signInNeeded(serviceName)
        case 403:
            if let m = msg, let r = m.range(of: "Missing required permission: ") {
                let perm = m[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
                return .denied("The Immich API key isn’t allowed to do that: it’s missing the “\(perm)” permission. "
                    + "In Immich, edit the key under Account Settings › API Keys to add it.")
            }
            return .denied("Immich didn’t allow that" + (msg.map { " (\($0))" } ?? "") + ".")
        case 404:
            return .notFound
        case 400:
            if let m = msg, m.localizedCaseInsensitiveContains("quota") { return .quotaExceeded(serviceName) }
            // "Unsupported file type <name>": keep the file name out of the message (and so out of any log).
            if let m = msg, m.hasPrefix("Unsupported file type") {
                return .unsupported("Immich doesn’t accept one of these files: its type isn’t supported.")
            }
            if let m = msg, m.hasPrefix("Not found or no ") {
                return .denied("Immich couldn’t find that item, or the API key isn’t allowed to change it (it may belong to someone else).")
            }
            return .server("Immich refused the request" + (msg.map { ": \($0)" } ?? "") + ".")
        case 413:
            return .server("The file is too large for the Immich server (or a proxy in front of it).")
        case 300..<400:
            return .server("The Immich server redirected Cirrus elsewhere (\(status)). Check the server address in the account.")
        case 500..<600:
            return .server("The Immich server had a problem (\(status)" + (msg.map { ": \($0)" } ?? "") + "). Try again later.")
        default:
            return .server("Immich answered \(status)" + (msg.map { ": \($0)" } ?? "") + ".")
        }
    }

    // MARK: Back-off

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
}

// MARK: - Uploads

enum ImmichUpload {
    /// SHA-1 of a file, base64 (Immich's checksum), read in pieces.
    static func sha1(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while true {
            try Task.checkCancellation()
            guard let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    /// Streams a multipart/form-data body (text fields first, then the file) into a temp file.
    static func multipart(fields: [(String, String)], fileField: String, file: URL, filename: String, mime: String,
                          boundary: String) throws -> URL {
        let out = Paths.tempFile(named: "immich-upload.multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        func quoted(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "%22")
        }
        for (k, v) in fields {
            try w.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(k))\"\r\n\r\n\(v)\r\n".utf8))
        }
        try w.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(fileField))\"; filename=\"\(quoted(filename))\"\r\n"
            + "Content-Type: \(mime)\r\n\r\n").utf8))
        let r = try FileHandle(forReadingFrom: file)
        defer { try? r.close() }
        while true {
            try Task.checkCancellation()
            guard let chunk = try r.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            try w.write(contentsOf: chunk)
        }
        try w.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}
