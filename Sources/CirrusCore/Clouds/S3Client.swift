import CryptoKit
import Foundation

// The wire layer of the S3 connector: endpoints and addressing (virtual-hosted or path-style), SigV4-signed requests
// with retries and back-off, clock-skew and bucket-region correction, streamed downloads, and the XML S3 answers in.
// Nothing here logs a key, a signature, an object key or a bucket name.

// MARK: - Endpoint

struct S3Endpoint: Sendable, Equatable {
    var scheme: String
    var host: String
    var port: Int?
    /// "" or "/prefix" (an S3 service behind a proxy path). Never ends in "/".
    var basePath: String

    var isAWS: Bool { host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") }
    var isR2: Bool { host.hasSuffix(".r2.cloudflarestorage.com") }
    var isLoopback: Bool { DAVURL.isLoopback(host) }

    /// "https://host[:port][/base]".
    var string: String {
        var s = scheme + "://" + host
        if let port { s += ":\(port)" }
        return s + basePath
    }

    /// Parses what the user typed ("s3.us-west-004.backblazeb2.com", "https://minio.local:9000/") into an endpoint
    /// (https unless http:// was typed for this device) and the path the address carried ("" or "/bucket" …).
    static func parse(_ input: String) throws -> (endpoint: S3Endpoint, path: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            throw CloudError.notConfigured("Enter the service’s endpoint, like s3.us-west-004.backblazeb2.com or https://s3.eu-central-1.amazonaws.com.")
        }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let rawHost = c.host, !rawHost.isEmpty, let scheme = c.scheme?.lowercased() else {
            throw CloudError.notConfigured("“\(input)” isn’t an endpoint address. Enter one like https://s3.us-east-1.amazonaws.com.")
        }
        let host = rawHost.lowercased()
        var port = c.port
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { port = nil }
        var check = URLComponents()
        check.scheme = scheme
        check.host = host
        guard let u = check.url else { throw CloudError.notConfigured("“\(input)” isn’t an endpoint address.") }
        try DAVURL.check(u)
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return (S3Endpoint(scheme: scheme, host: host, port: port, basePath: ""), S3Signer.decode(path) ?? path)
    }

    /// Hosts whose region is in their name: AWS (s3.us-west-2.amazonaws.com, s3-us-west-2…, s3.dualstack.…),
    /// Backblaze B2 (s3.us-west-004.backblazeb2.com), Wasabi (s3.eu-central-1.wasabisys.com), Scaleway
    /// (s3.fr-par.scw.cloud); Cloudflare R2 signs with "auto".
    static func inferredRegion(host: String) -> String? {
        if host.hasSuffix(".r2.cloudflarestorage.com") { return "auto" }
        let labels = host.split(separator: ".").map(String.init)
        func after(_ i: Int) -> String? {
            var j = i + 1
            if j < labels.count, labels[j] == "dualstack" { j += 1 }
            return j < labels.count ? labels[j] : nil
        }
        if host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") {
            guard let i = labels.lastIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) else { return nil }
            if labels[i].hasPrefix("s3-") {
                let r = String(labels[i].dropFirst(3))
                return r == "external-1" ? "us-east-1" : r
            }
            guard let r = after(i), r != "amazonaws" else { return "us-east-1" }
            return r
        }
        for suffix in [".backblazeb2.com", ".wasabisys.com", ".scw.cloud"] where host.hasSuffix(suffix) {
            guard let i = labels.lastIndex(of: "s3"), let r = after(i), !suffix.contains(r) else { return suffix == ".wasabisys.com" ? "us-east-1" : nil }
            return r
        }
        return nil
    }

    /// The region Cirrus signs with: what the user entered, or (empty or "auto") the one the host names, R2's
    /// own "auto", or us-east-1 (MinIO's and most other servers' default).
    static func signingRegion(_ entered: String?, host: String) -> String {
        let r = (entered ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !r.isEmpty && r != "auto" { return r }
        return inferredRegion(host: host) ?? "us-east-1"
    }

    /// The well-known services, which take a bucket in the address ("bucket.s3.…" or "…/bucket").
    var knownService: Bool {
        isAWS || isR2 || host.hasSuffix(".backblazeb2.com") || host.hasSuffix(".wasabisys.com") || host.hasSuffix(".scw.cloud")
    }

    /// "photos.s3.us-west-2.amazonaws.com" → ("photos", "s3.us-west-2.amazonaws.com") for the known services.
    static func splitBucketHost(_ host: String) -> (bucket: String, host: String)? {
        let known = [".amazonaws.com", ".amazonaws.com.cn", ".backblazeb2.com", ".wasabisys.com", ".scw.cloud"]
        guard known.contains(where: { host.hasSuffix($0) }) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard let i = labels.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }), i > 0 else { return nil }
        return (labels[..<i].joined(separator: "."), labels[i...].joined(separator: "."))
    }

    /// Names a bucket can have as a host name label (no dots, so https certificates still match).
    static func virtualHostable(_ bucket: String) -> Bool {
        guard (3...63).contains(bucket.utf8.count), let f = bucket.utf8.first, let l = bucket.utf8.last,
              f != UInt8(ascii: "-"), l != UInt8(ascii: "-") else { return false }
        return bucket.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == UInt8(ascii: "-") }
    }
}

// MARK: - XML

/// A small element tree of an S3 XML answer (namespaces dropped; text kept exactly, spaces included).
final class S3XML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func all(_ n: String) -> [Node] { children.filter { $0.name == n } }
        func value(_ n: String) -> String? { child(n)?.text }
    }

    private var stack: [Node] = []
    private(set) var root: Node?

    static func parse(_ data: Data) -> Node? {
        guard !data.isEmpty else { return nil }
        let p = S3XML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = p
        guard parser.parse() else { return nil }
        return p.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let n = Node(elementName)
        if let top = stack.last { top.children.append(n) } else if root == nil { root = n }
        stack.append(n)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\r": out += "&#13;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

/// An S3 error answer: <Error><Code>NoSuchKey</Code><Message>…</Message>…</Error>.
struct S3ErrorBody: Sendable, Equatable {
    var code: String
    var message: String?
    var region: String?
    var serverTime: String?

    static func parse(_ data: Data) -> S3ErrorBody? {
        guard !data.isEmpty, data.count < 512 * 1024, let root = S3XML.parse(data), root.name == "Error",
              let code = root.value("Code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        return S3ErrorBody(code: code, message: root.value("Message")?.trimmingCharacters(in: .whitespacesAndNewlines),
                           region: root.value("Region")?.trimmingCharacters(in: .whitespacesAndNewlines),
                           serverTime: root.value("ServerTime")?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum S3Dates {
    private static let lock = NSLock()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "2026-11-16T09:30:00.000Z" (listings) or without fractions.
    static func iso8601(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return lock.withLock { isoFrac.date(from: t) ?? iso.date(from: t) }
    }

    static func isoString(_ d: Date) -> String { lock.withLock { isoFrac.string(from: d) } }
}

// MARK: - Client

final class S3Client: @unchecked Sendable {
    struct Response: @unchecked Sendable {
        let status: Int
        let data: Data
        let http: HTTPURLResponse
        /// True when this answer came after a retry (the first attempt may have reached the server).
        let retried: Bool
        let error: S3ErrorBody?
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        var ok: Bool { (200..<300).contains(status) }
        var code: String? { error?.code }
    }

    enum Body { case empty, data(Data), file(URL) }

    /// One request: the bucket (nil: the service itself), the object key ("" for the bucket), query and headers.
    struct Request {
        var method: String
        var bucket: String?
        var key: String = ""
        var query: [(String, String?)] = []
        var headers: [String: String] = [:]
        var body: Body = .empty
        /// SHA-256 (hex) of the body, or `S3Signer.unsignedPayload`.
        var payloadHash: String = S3Signer.emptyHash
        var timeout: TimeInterval? = nil
    }

    let endpoint: S3Endpoint
    let accessKey: String
    private let secretKey: String
    let defaultRegion: String
    /// nil: virtual-hosted on AWS (when the bucket name allows), path-style elsewhere.
    let pathStyle: Bool?
    /// For error messages: "S3 Storage (photos @ s3.us-west-004.backblazeb2.com)".
    let serviceName: String

    let session: URLSession
    let delegate: DAVSessionDelegate
    private let lock = NSLock()
    private var _clockOffset: TimeInterval = 0
    private var _bucketRegions = [String: String]()
    private var _retryBase = 0.5
    var retryBase: Double { get { lock.withLock { _retryBase } } set { lock.withLock { _retryBase = newValue } } }
    var maxRetries = 5
    /// Seconds to add to this device's clock (learned from RequestTimeTooSkewed).
    var clockOffset: TimeInterval { get { lock.withLock { _clockOffset } } set { lock.withLock { _clockOffset = newValue } } }

    static var userAgent: String { DAVClient.userAgent }

    init(endpoint: S3Endpoint, accessKey: String, secretKey: String, region: String, pathStyle: Bool?, serviceName: String, transport: [AnyClass]?) {
        self.endpoint = endpoint
        self.accessKey = accessKey
        self.secretKey = secretKey
        defaultRegion = region
        self.pathStyle = pathStyle
        self.serviceName = serviceName
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60 * 24 * 2
        c.httpMaximumConnectionsPerHost = 8
        if let t = transport { c.protocolClasses = t }
        delegate = DAVSessionDelegate()
        session = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    func region(for bucket: String?) -> String {
        guard let bucket else { return defaultRegion }
        return lock.withLock { _bucketRegions[bucket] } ?? defaultRegion
    }

    func setRegion(_ r: String, for bucket: String) { lock.withLock { _bucketRegions[bucket] = r } }

    func usesPathStyle(_ bucket: String) -> Bool {
        if let p = pathStyle { return p || !S3Endpoint.virtualHostable(bucket) }
        return !(endpoint.isAWS && S3Endpoint.virtualHostable(bucket))
    }

    /// Where a request goes: URL, Host header value, and the canonical URI and query it's signed with.
    func target(_ r: Request, region: String) -> (url: URL, host: String, uri: String, query: String) {
        var host = endpoint.host
        // A bucket in another AWS region is served from that region's endpoint.
        if endpoint.isAWS, r.bucket != nil, region != (S3Endpoint.inferredRegion(host: host) ?? defaultRegion), let i = host.range(of: "amazonaws.com") {
            host = "s3." + region + "." + host[i.lowerBound...]
        }
        var path = endpoint.basePath
        let encodedKey = S3Signer.encode(r.key, slash: false)
        if let b = r.bucket {
            if usesPathStyle(b) {
                path += "/" + S3Signer.encode(b, slash: true) + (r.key.isEmpty ? "" : "/" + encodedKey)
            } else {
                host = b + "." + host
                path += "/" + encodedKey
            }
        }
        if path.isEmpty { path = "/" }
        let query = S3Signer.canonicalQuery(r.query)
        var c = URLComponents()
        c.scheme = endpoint.scheme
        c.host = host
        c.port = endpoint.port
        c.percentEncodedPath = path
        if !query.isEmpty { c.percentEncodedQuery = query }
        let url = c.url ?? URL(string: endpoint.string)!
        return (url, host + (endpoint.port.map { ":\($0)" } ?? ""), path, query)
    }

    /// Headers the transport may change or add: never signed.
    static let unsignedHeaders: Set<String> = ["user-agent", "accept-encoding", "content-length", "connection", "expect", "authorization", "accept"]

    func makeRequest(_ r: Request, region: String) -> URLRequest {
        let t = target(r, region: region)
        // One spelling per header (lower-case), so what is signed is exactly what is sent.
        var headers = [String: String]()
        for (k, v) in r.headers { headers[k.lowercased()] = v }
        headers["x-amz-date"] = S3Signer.amzDate(Date().addingTimeInterval(clockOffset))
        headers["x-amz-content-sha256"] = r.payloadHash
        var toSign = [("host", t.host)]
        for (k, v) in headers where !Self.unsignedHeaders.contains(k.lowercased()) { toSign.append((k, v)) }
        let sig = S3Signer.sign(method: r.method, canonicalURI: t.uri, canonicalQuery: t.query, headers: toSign, payloadHash: r.payloadHash,
                                amzDate: headers["x-amz-date"]!, region: region, accessKey: accessKey, secretKey: secretKey)
        var req = URLRequest(url: t.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: r.timeout ?? 60)
        req.httpMethod = r.method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(sig.authorization, forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    static let transientCodes: Set<URLError.Code> = DAVClient.transientCodes
    static let retryCodes: Set<String> = ["SlowDown", "InternalError", "ServiceUnavailable", "RequestTimeout", "Throttling", "ThrottlingException",
                                          "RequestLimitExceeded", "TooManyRequests", "OperationAborted"]

    enum Mode { case data, download(URL, expected: Int64) }

    /// One request with retries: dropped connections, 429/500/502/503/504 and SlowDown back off and try again; a
    /// skewed clock or a bucket in another region is corrected once. Every other answer comes back to the caller.
    /// All S3 requests Cirrus sends are safe to repeat (writes are guarded by existence checks or If-None-Match).
    func send(_ r: Request, mode: Mode = .data, progress: (@Sendable (Int64, Int64) -> Void)? = nil, total: Int64 = 0) async throws -> Response {
        var attempt = 0
        var skewFixed = false
        var regionFixed = false
        while true {
            try Task.checkCancellation()
            let region = region(for: r.bucket)
            let req = makeRequest(r, region: region)
            let started = Date()
            var data = Data()
            let h: HTTPURLResponse
            do {
                switch mode {
                case .data:
                    let d = DAVTaskDelegate(progress: progress, total: total)
                    let resp: URLResponse
                    switch r.body {
                    case .empty where r.method == "PUT" || r.method == "POST": (data, resp) = try await session.upload(for: req, from: Data(), delegate: d)
                    case .empty: (data, resp) = try await session.data(for: req, delegate: d)
                    case .data(let b): (data, resp) = try await session.upload(for: req, from: b, delegate: d)
                    case .file(let f): (data, resp) = try await session.upload(for: req, fromFile: f, delegate: d)
                    }
                    guard let hh = resp as? HTTPURLResponse else { throw CloudError.server("The server sent an answer Cirrus couldn’t read.") }
                    h = hh
                case .download(let dest, let expected):
                    let (file, hh) = try await delegate.run(session.downloadTask(with: req), expected: expected, progress: progress ?? { _, _ in })
                    h = hh
                    if (200..<300).contains(hh.statusCode) {
                        let fm = FileManager.default
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: file, to: dest)
                        try? fm.removeItem(at: file.deletingLastPathComponent())
                    } else {
                        data = (try? FileHandle(forReadingFrom: file)).flatMap { fh -> Data? in defer { try? fh.close() }; return try? fh.read(upToCount: 64 * 1024) } ?? Data()
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    }
                }
            } catch is DAVAuthRejected {
                throw CloudError.signInNeeded(serviceName)
            } catch let e as URLError {
                if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard Self.transientCodes.contains(e.code), attempt < maxRetries else { throw DAVClient.networkError(e, host: req.url?.host) }
                attempt += 1
                try await pause(delay(attempt: attempt, retryAfter: nil))
                continue
            }
            let status = h.statusCode
            let err = status >= 300 ? S3ErrorBody.parse(data) : nil
            let line = "s3 \(r.method) \(endpoint.host) → \(status)\(err.map { " " + $0.code } ?? "")"
            if (200..<300).contains(status) || status == 404 { Log.debug(line + String(format: " (%.2fs)", Date().timeIntervalSince(started))) } else { Log.status(line) }

            // This device's clock is off by more than 15 minutes: sign with the server's time instead (once).
            if status == 403, err?.code == "RequestTimeTooSkewed" || err?.code == "RequestExpired", !skewFixed {
                let server = err?.serverTime.flatMap(S3Dates.iso8601) ?? h.value(forHTTPHeaderField: "Date").flatMap(DAVDates.http)
                if let server {
                    clockOffset = server.timeIntervalSince(Date())
                    Log.status(String(format: "s3 clock offset %.0fs", clockOffset))
                    skewFixed = true
                    continue
                }
            }
            // The bucket lives in another region: sign for that region (once).
            if let b = r.bucket, !regionFixed, status == 301 || status == 400,
               let other = (h.value(forHTTPHeaderField: "x-amz-bucket-region") ?? err?.region)?.trimmingCharacters(in: .whitespaces),
               !other.isEmpty, other != region {
                setRegion(other, for: b)
                regionFixed = true
                continue
            }
            let busy = status == 429 || status == 503 || status == 500 || status == 502 || status == 504
                || (err.map { Self.retryCodes.contains($0.code) } ?? false)
            if busy {
                if attempt < maxRetries {
                    attempt += 1
                    let d = delay(attempt: attempt, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                    Log.status("s3 back-off \(String(format: "%.1f", d))s after \(status)")
                    try await pause(d)
                    continue
                }
                throw CloudError.server("\(endpoint.host) is busy (\(status)\(err.map { " " + $0.code } ?? "")). Try again in a few minutes.")
            }
            return Response(status: status, data: data, http: h, retried: attempt > 0, error: err)
        }
    }

    func delay(attempt: Int, retryAfter: String?) -> Double {
        if let ra = retryAfter?.trimmingCharacters(in: .whitespaces), !ra.isEmpty {
            if let secs = Double(ra) { return max(0, min(secs, 60)) }
            if let date = DAVDates.http(ra) { return max(0, min(date.timeIntervalSinceNow, 60)) }
        }
        let base = retryBase
        return min(base * pow(2, Double(attempt - 1)), 20) + Double.random(in: 0...max(base, 0.0001)) * 0.5
    }

    func pause(_ seconds: Double) async throws {
        guard seconds > 0 else { try Task.checkCancellation(); return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// SHA-256 and MD5 of a file or a slice of one, read 1 MiB at a time (never the whole file in memory).
enum S3Hash {
    struct Digests { var sha256: String; var md5: String; var bytes: Int64 }

    static func file(_ url: URL) throws -> Digests {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var sha = SHA256(), md5 = Insecure.MD5()
        var n: Int64 = 0
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty {
            sha.update(data: d); md5.update(data: d); n += Int64(d.count)
        }
        return Digests(sha256: S3Signer.hex(Data(sha.finalize())), md5: S3Signer.hex(Data(md5.finalize())), bytes: n)
    }

    /// Copies `length` bytes at `offset` of `source` into a new temporary file, hashing them on the way.
    static func slice(_ source: FileHandle, offset: Int64, length: Int64) throws -> (url: URL, digests: Digests) {
        let out = Paths.tempFile(named: "s3-part")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        try source.seek(toOffset: UInt64(offset))
        var sha = SHA256(), md5 = Insecure.MD5()
        var left = length
        while left > 0 {
            try Task.checkCancellation()
            guard let d = try source.read(upToCount: Int(min(left, 1 << 20))), !d.isEmpty else { break }
            sha.update(data: d); md5.update(data: d)
            try w.write(contentsOf: d)
            left -= Int64(d.count)
        }
        return (out, Digests(sha256: S3Signer.hex(Data(sha.finalize())), md5: S3Signer.hex(Data(md5.finalize())), bytes: length - left))
    }
}
