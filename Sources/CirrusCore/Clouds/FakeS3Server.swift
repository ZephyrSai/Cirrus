#if DEBUG
import CryptoKit
import Foundation

/// A stateful stand-in for S3-compatible services, served through URLProtocol: AWS (virtual-hosted and path-style,
/// buckets in several regions), Backblaze B2, Cloudflare R2 (region "auto"), Wasabi, a MinIO on 127.0.0.1:9000 and the
/// demo endpoint. Unit tests use it as the mock server; Debug builds in demo mode (CIRRUS_DEMO=1) use it for the demo
/// S3 account. It is strict, so it catches client mistakes: it verifies every SigV4 signature with the known secret
/// (canonical URI from the decoded key, canonical query, signed headers incl. every x-amz-* header, body hash, region,
/// 15-minute clock window), answers S3's XML errors, pages ListObjectsV2 (small pages on request), checks multipart
/// uploads (part numbers, ETags, order, minimum part size), copies (size limit, metadata directive) and conditional
/// writes per service, and can inject SlowDown, 500s, dropped connections and failing parts. Every request is answered
/// here: an unknown host fails as "can't find host", so nothing ever reaches the network. Not in release builds.
public final class FakeS3Server: URLProtocol, @unchecked Sendable {
    public enum Flavor: String, Codable, Sendable { case aws, b2, r2, wasabi, minio, generic }
    /// How a service treats If-None-Match: * on writes.
    public enum Conditional: String, Codable, Sendable { case supported, notImplemented, ignored }

    public struct Endpoint: Codable, Sendable {
        public var host: String
        public var port: Int?
        public var flavor: Flavor
        /// The region requests are signed for ("auto" for R2, which also takes us-east-1 and "").
        public var region: String
        public var conditional: Conditional
        /// "<bucket>.<host>" addresses are served too.
        public var virtualHosted: Bool
        public init(host: String, port: Int? = nil, flavor: Flavor, region: String, conditional: Conditional = .supported, virtualHosted: Bool = true) {
            self.host = host; self.port = port; self.flavor = flavor; self.region = region; self.conditional = conditional; self.virtualHosted = virtualHosted
        }
    }

    public struct Object: Codable, Sendable {
        public var key: String
        public var data: Data
        public var contentType: String
        /// "x-amz-meta-…" (lower-cased) → value.
        public var meta: [String: String]
        /// Other kept headers (content-encoding, cache-control…), lower-cased.
        public var extra: [String: String]
        public var modified: Date
        public var etag: String
        public var storageClass: String?
    }

    public struct Bucket: Codable, Sendable {
        public var region: String
        public var created: Date
        /// Keyed by the AWS-encoded key, so keys stay byte-exact (Swift strings compare by canonical equivalence).
        public var objects: [String: Object] = [:]
        public init(region: String, created: Date = Date(timeIntervalSince1970: 1_790_000_000)) { self.region = region; self.created = created }
        public func object(_ key: String) -> Object? { objects[FakeS3Server.enc(key)] }
        public var keys: [String] { objects.values.map(\.key).sorted(by: S3Key.less) }
    }

    public struct Credential: Codable, Sendable {
        public var secret: String
        public var canListBuckets = true
        /// Buckets the key may use (nil: all), like B2's and R2's bucket-scoped keys.
        public var buckets: Set<String>?
        public init(secret: String, canListBuckets: Bool = true, buckets: Set<String>? = nil) {
            self.secret = secret; self.canListBuckets = canListBuckets; self.buckets = buckets
        }
    }

    struct Part { var data: Data; var etag: String }
    struct Upload { var bucket: String; var key: String; var contentType: String; var meta: [String: String]; var parts: [Int: Part] = [:] }

    public static let accessKey = "AKIAFAKES3EXAMPLE001"
    public static let secretKey = "fakeS3/secret+Key/wJalrXUtnFEMI0000000000"

    public struct State: Sendable {
        public var endpoints: [Endpoint] = [
            Endpoint(host: "s3.us-east-1.amazonaws.com", flavor: .aws, region: "us-east-1"),
            Endpoint(host: "s3.eu-west-1.amazonaws.com", flavor: .aws, region: "eu-west-1"),
            Endpoint(host: "s3.amazonaws.com", flavor: .aws, region: "us-east-1"),
            Endpoint(host: "s3.us-west-004.backblazeb2.com", flavor: .b2, region: "us-west-004", conditional: .notImplemented),
            Endpoint(host: "fakeaccount0123.r2.cloudflarestorage.com", flavor: .r2, region: "auto", virtualHosted: false),
            Endpoint(host: "s3.eu-central-1.wasabisys.com", flavor: .wasabi, region: "eu-central-1", conditional: .ignored),
            Endpoint(host: "127.0.0.1", port: 9000, flavor: .minio, region: "us-east-1", virtualHosted: false),
            Endpoint(host: FakeS3Server.demoHost, flavor: .generic, region: "us-east-1", virtualHosted: false),
        ]
        public var credentials: [String: Credential] = [FakeS3Server.accessKey: Credential(secret: FakeS3Server.secretKey)]
        public var buckets: [String: Bucket] = [:]
        /// Most entries one ListObjectsV2 page returns.
        public var pageSize = 1000
        /// Smallest part of a multipart upload, except the last one.
        public var minPartSize = 5 << 20
        public var maxPutSize = 5 << 30
        public var maxCopySize = 5 << 30
        /// The server's clock runs this many seconds ahead of the device's.
        public var skew: TimeInterval = 0
        public var latency: Double = 0
        // Fault injection
        public var slowDownNext = 0
        public var internalErrorNext = 0
        public var dropNext = 0
        /// Part number → how many more times uploading it answers 500 InternalError.
        public var failParts: [Int: Int] = [:]
        /// Part numbers always refused (403 AccessDenied).
        public var forbiddenParts: Set<Int> = []
        /// Copies from these source keys fail with an error inside a 200 answer (as S3 can).
        public var failCopiesIn200: Set<String> = []
        /// Listings of these prefixes come back cut off mid-XML.
        public var truncateListings: Set<String> = []
        /// Listings of these prefixes say "truncated" but give no continuation token.
        public var tokenlessListings: Set<String> = []
        /// Keys that exist but that HEAD and listings don't show yet (another device writing at the same moment).
        public var ghostKeys: Set<String> = []
        // Statistics for tests
        public var calls: [String] = []
        public var signatureFailures = 0
        public var skewRejections = 0
        public var regionRejections = 0
        public var aborted = 0
        public var completed = 0
        public var partPuts = 0
        public var copies = 0
        public var listRequests = 0
        public var lastUserAgent: String?
        /// The host of every request, in order.
        public var hosts: [String] = []
        var uploads: [String: Upload] = [:]
        public var openUploads: Int { uploads.count }

        public init() {}

        public func object(_ bucket: String, _ key: String) -> Object? { buckets[bucket]?.object(key) }

        /// Adds an object (a key ending in "/" is a zero-byte folder marker).
        public mutating func put(_ bucket: String, _ key: String, _ data: Data = Data(), contentType: String? = nil, meta: [String: String] = [:],
                                 modified: Date = Date(timeIntervalSince1970: 1_790_000_000), storageClass: String? = nil) {
            if buckets[bucket] == nil { buckets[bucket] = Bucket(region: "us-east-1") }
            let o = Object(key: key, data: data, contentType: contentType ?? (S3Key.isFolder(key) ? "application/x-directory" : FakeS3Server.mime(key)),
                           meta: meta, extra: [:], modified: modified, etag: FakeS3Server.md5(data), storageClass: storageClass)
            buckets[bucket]!.objects[FakeS3Server.enc(key)] = o
        }

        public mutating func addBucket(_ name: String, region: String = "us-east-1") {
            if buckets[name] == nil { buckets[name] = Bucket(region: region) }
        }

        public static func seeded() -> State {
            var s = State()
            FakeS3Server.seed(&s)
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

    // MARK: Demo

    public static let demoHost = "s3.example.com"
    public static let demoBucket = "demo-files"
    public static let demoAccessKey = "DEMOAKIAEXAMPLE00001"
    public static let demoSecret = "demo/secret+key/for/the/cirrus/fake/s3"

    /// Demo mode: the seeded bucket, kept on disk in `storage` (nil: in memory only). Starts once.
    public static func startDemo(storage dir: URL?) {
        lock.withLock {
            guard !demoStarted else { return }
            demoStarted = true
            var s = State.seeded()
            s.latency = ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] != nil ? 0 : 0.02
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("s3-state-v1.json")
                persistURL = url
                if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Bucket].self, from: d), saved[demoBucket] != nil {
                    s.buckets = saved
                }
            }
            s.credentials[demoAccessKey] = Credential(secret: demoSecret)
            _state = s
        }
    }

    /// The demo account record (stable id) and its secret access key.
    public static func demoAccount() -> (record: CloudAccountRecord, secret: String) {
        (CloudAccountRecord(id: "cloud:s3:demo", provider: .s3, title: "\(demoBucket) @ \(demoHost)", server: "https://\(demoHost)",
                            username: demoAccessKey, added: Date(timeIntervalSince1970: 1_790_000_000),
                            options: ["region": "us-east-1", "bucket": demoBucket, "pathStyle": "1"]), demoSecret)
    }

    static func persist() {
        guard let url = persistURL else { return }
        if let d = try? JSONEncoder().encode(_state.buckets) { try? d.write(to: url, options: .atomic) }
    }

    static func seed(_ s: inout State) {
        let day = 86_400.0
        func d(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + n * day) }
        func m(_ n: Double) -> [String: String] { ["x-amz-meta-mtime": String(Int64(d(n).timeIntervalSince1970))] }
        let b = demoBucket
        s.addBucket(b)
        s.put(b, "Readme.txt", Data("Welcome to the demo S3 bucket.\n\nNothing here is real; files you add stay on this Mac.\n".utf8), meta: m(30), modified: d(30))
        s.put(b, "Documents/", modified: d(5))
        s.put(b, "Documents/Budget 2026.csv", Data("Month,Income,Expenses\nJanuary,4200,3100\nFebruary,4200,2950\nMarch,4350,3300\n".utf8), meta: m(12), modified: d(12))
        s.put(b, "Documents/Meeting notes.txt", Data("Agenda\n- Roadmap review\n- Launch checklist\n- Next steps\n".utf8), meta: m(20), modified: d(20))
        s.put(b, "Documents/Project brief.pdf", DemoArt.pdf(title: "Project brief", lines: ["Goals", "Scope", "Timeline"], hue: 0.35), meta: m(8), modified: d(8))
        s.put(b, "Photos/Harbor at dusk.jpg", DemoArt.scenic(width: 480, height: 320, seed: 2) ?? Data(count: 1000), meta: m(3), modified: d(3))
        s.put(b, "Photos/Mountain lake.jpg", DemoArt.scenic(width: 480, height: 320, seed: 3) ?? Data(count: 1000), meta: m(4), modified: d(4))
        s.put(b, "Photos/Beach.jpg", DemoArt.scenic(width: 480, height: 320, seed: 1) ?? Data(count: 1000), meta: m(2), modified: d(2))
        s.put(b, "Backups/settings-backup.json", Data("{\"theme\": \"dark\", \"version\": 3}\n".utf8), meta: m(14), modified: d(14))
        s.put(b, "Archive/", modified: d(1))
        s.put(b, S3Backend.trashPrefix + "Old draft.txt", Data("An older draft.\n".utf8),
              meta: ["x-amz-meta-cirrus-original": S3Signer.encode("Documents/Old draft.txt", slash: false), "x-amz-meta-cirrus-deleted": "1791000000"],
              modified: d(20))
    }

    // MARK: URLProtocol

    /// Every request of a session that uses this class is answered here (unknown hosts fail), so nothing leaves the Mac.
    override public class func canInit(with request: URLRequest) -> Bool { request.url?.host != nil }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override public func stopLoading() {}

    enum Outcome { case reply(Int, [String: String], Data), fail(URLError.Code) }

    override public func startLoading() {
        let req = request
        let body = Self.body(req)
        let (outcome, latency) = Self.lock.withLock { () -> (Outcome, Double) in
            let o = Self.handle(req, body: body)
            return (o, Self._state.latency)
        }
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        switch outcome {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .reply(let status, var headers, let data):
            if headers["Content-Length"] == nil { headers["Content-Length"] = String(data.count) }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if req.httpMethod != "HEAD" && !data.isEmpty {
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

    static func enc(_ key: String) -> String { S3Signer.encode(key, slash: false) }
    static func md5(_ d: Data) -> String { S3Signer.hex(Data(Insecure.MD5.hash(data: d))) }
    static func mime(_ key: String) -> String {
        switch (key as NSString).pathExtension.lowercased() {
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "binary/octet-stream"
        }
    }

    static func now() -> Date { Date().addingTimeInterval(_state.skew) }
    static func requestID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)) }

    static func baseHeaders() -> [String: String] {
        ["Date": DAVDates.httpString(now()), "x-amz-request-id": requestID(), "Server": "FakeS3"]
    }

    static func error(_ status: Int, _ code: String, _ message: String, extra: [String: String] = [:], headers: [String: String] = [:]) -> Outcome {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n<Error><Code>\(code)</Code><Message>\(S3XML.escape(message))</Message>"
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { xml += "<\(k)>\(S3XML.escape(v))</\(k)>" }
        xml += "<RequestId>\(requestID())</RequestId></Error>"
        var h = baseHeaders()
        h["Content-Type"] = "application/xml"
        h.merge(headers) { $1 }
        return .reply(status, h, Data(xml.utf8))
    }

    static func xmlReply(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Outcome {
        var h = baseHeaders()
        h["Content-Type"] = "application/xml"
        h.merge(headers) { $1 }
        return .reply(status, h, Data((#"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + body).utf8))
    }

    static func empty(_ status: Int, headers: [String: String] = [:]) -> Outcome {
        var h = baseHeaders()
        h.merge(headers) { $1 }
        return .reply(status, h, Data())
    }

    static func iso(_ d: Date) -> String { S3Dates.isoString(d) }

    /// AWS's encoding-type=url: percent-encoding with "+" for spaces.
    static func urlEncode(_ s: String) -> String { S3Signer.encode(s, slash: false).replacingOccurrences(of: "%20", with: "+") }

    /// Keys as raw XML text: & < > escaped, but characters XML can't carry are written as they are (like S3).
    static func rawXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func header(_ r: URLRequest, _ name: String) -> String? { r.value(forHTTPHeaderField: name) }

    // MARK: Request handling

    static func handle(_ req: URLRequest, body: Data) -> Outcome {
        guard let url = req.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host?.lowercased() else {
            return .fail(.badURL)
        }
        let method = req.httpMethod ?? "GET"
        // Which service, and is the bucket in the host name?
        var endpoint: Endpoint?
        var hostBucket: String?
        for ep in _state.endpoints where ep.port == comps.port {
            if host == ep.host { endpoint = ep; break }
            if ep.virtualHosted, host.hasSuffix("." + ep.host) {
                endpoint = ep
                hostBucket = String(host.dropLast(ep.host.count + 1))
                break
            }
        }
        guard let ep = endpoint else { return .fail(.cannotFindHost) }
        if _state.dropNext > 0 { _state.dropNext -= 1; return .fail(.networkConnectionLost) }
        _state.lastUserAgent = header(req, "User-Agent")
        _state.hosts.append(host + (comps.port.map { ":\($0)" } ?? ""))

        // Bucket and key from the (decoded) path.
        guard let path = S3Signer.decode(comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath) else {
            return error(400, "InvalidURI", "Couldn't parse the specified URI.")
        }
        var bucketName = hostBucket
        var key = ""
        if bucketName == nil {
            let rest = S3Key.dropPrefix(path, "/")
            if !rest.isEmpty {
                let bytes = Array(rest.utf8)
                if let i = bytes.firstIndex(of: UInt8(ascii: "/")) {
                    bucketName = String(decoding: bytes[..<i], as: UTF8.self)
                    key = String(decoding: bytes[(i + 1)...], as: UTF8.self)
                } else {
                    bucketName = rest
                }
            }
        } else {
            key = S3Key.dropPrefix(path, "/")
        }
        let query = S3Signer.queryItems(comps.percentEncodedQuery)
        var q = [String: String]()
        for (k, v) in query { q[k] = v ?? "" }
        _state.calls.append("\(method) \(bucketName ?? "-") \(key)\(query.isEmpty ? "" : "?" + query.map { $0.0 }.sorted().joined(separator: "&"))")

        // Signature Version 4, checked like S3 does.
        guard let auth = header(req, "Authorization") else { return error(403, "AccessDenied", "Access Denied") }
        guard let p = S3Signer.parse(authorization: auth) else {
            return error(400, "AuthorizationHeaderMalformed", "The authorization header is malformed.")
        }
        guard let cred = _state.credentials[p.accessKey] else {
            return error(403, "InvalidAccessKeyId", "The AWS Access Key Id you provided does not exist in our records.", extra: ["AWSAccessKeyId": p.accessKey])
        }
        guard let amz = header(req, "x-amz-date"), let reqDate = S3Signer.parseAmzDate(amz) else {
            return error(403, "AccessDenied", "AWS authentication requires a valid Date or x-amz-date header")
        }
        if abs(reqDate.timeIntervalSince(now())) > 15 * 60 {
            _state.skewRejections += 1
            return error(403, "RequestTimeTooSkewed", "The difference between the request time and the current time is too large.",
                         extra: ["RequestTime": amz, "ServerTime": iso(now()), "MaxAllowedSkewMilliseconds": "900000"])
        }
        guard p.day == String(amz.prefix(8)), p.service == "s3" else {
            return error(400, "AuthorizationHeaderMalformed", "The authorization header is malformed; the credential scope is wrong.")
        }
        let bucket = bucketName.flatMap { _state.buckets[$0] }
        // Region: AWS buckets live in one region; R2 takes "auto" (or us-east-1 / empty); the others their endpoint's.
        let expected: String
        switch ep.flavor {
        case .aws: expected = bucket?.region ?? ep.region
        case .r2: expected = ["auto", "us-east-1", ""].contains(p.region) ? p.region : "auto"
        default: expected = ep.region
        }
        if p.region != expected {
            _state.regionRejections += 1
            return error(400, "AuthorizationHeaderMalformed", "The authorization header is malformed; the region '\(p.region)' is wrong; expecting '\(expected)'",
                         extra: ["Region": expected], headers: bucket != nil ? ["x-amz-bucket-region": expected] : [:])
        }
        guard let payloadHash = header(req, "x-amz-content-sha256") else {
            return error(400, "InvalidRequest", "Missing required header for this request: x-amz-content-sha256")
        }
        let signed = Set(p.signedHeaders)
        guard signed.contains("host"), signed.contains("x-amz-date") else {
            return error(403, "AccessDenied", "Host and x-amz-date must be signed.")
        }
        for name in (req.allHTTPHeaderFields ?? [:]).keys.map({ $0.lowercased() }) where name.hasPrefix("x-amz-") && !signed.contains(name) {
            return error(403, "AccessDenied", "There were headers present in the request which were not signed", extra: ["HeadersNotSigned": name])
        }
        var toSign = [(String, String)]()
        for name in p.signedHeaders {
            if name == "host" {
                toSign.append(("host", host + (comps.port.map { ":\($0)" } ?? "")))
            } else if let v = header(req, name) {
                toSign.append((name, v))
            } else {
                _state.signatureFailures += 1
                return error(403, "SignatureDoesNotMatch", "A signed header is missing from the request.")
            }
        }
        let canonicalURI = S3Signer.encode(path, slash: false)
        let sig = S3Signer.sign(method: method, canonicalURI: canonicalURI, canonicalQuery: S3Signer.canonicalQuery(query), headers: toSign,
                                payloadHash: payloadHash, amzDate: amz, region: p.region, accessKey: p.accessKey, secretKey: cred.secret)
        guard sig.signature == p.signature else {
            _state.signatureFailures += 1
            return error(403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided. Check your key and signing method.",
                         extra: ["AWSAccessKeyId": p.accessKey])
        }
        if payloadHash != S3Signer.unsignedPayload && payloadHash != S3Signer.sha256Hex(body) {
            return error(400, "XAmzContentSHA256Mismatch", "The provided 'x-amz-content-sha256' header does not match what was computed.")
        }

        // Injected trouble (after authentication, like a real service under load).
        if _state.slowDownNext > 0 { _state.slowDownNext -= 1; return error(503, "SlowDown", "Please reduce your request rate.", headers: ["Retry-After": "0"]) }
        if _state.internalErrorNext > 0 { _state.internalErrorNext -= 1; return error(500, "InternalError", "We encountered an internal error. Please try again.") }

        guard let bucketName else {
            guard method == "GET" else { return error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.") }
            guard cred.canListBuckets else { return error(403, "AccessDenied", "Access Denied") }
            return listBuckets(cred)
        }
        guard let b = bucket else { return error(404, "NoSuchBucket", "The specified bucket does not exist", extra: ["BucketName": bucketName]) }
        // An AWS bucket is served by its own region's endpoint.
        if ep.flavor == .aws, ep.region != b.region {
            return error(301, "PermanentRedirect", "The bucket you are attempting to access must be addressed using the specified endpoint.",
                         extra: ["Endpoint": "s3.\(b.region).amazonaws.com", "Bucket": bucketName], headers: ["x-amz-bucket-region": b.region])
        }
        if let allowed = cred.buckets, !allowed.contains(bucketName) { return error(403, "AccessDenied", "Access Denied") }
        let outcome = route(method, ep: ep, bucketName: bucketName, key: key, q: q, req: req, body: body)
        if case .reply(let s, _, _) = outcome, (200..<300).contains(s), method != "GET", method != "HEAD" { persist() }
        return outcome
    }

    static func route(_ method: String, ep: Endpoint, bucketName: String, key: String, q: [String: String], req: URLRequest, body: Data) -> Outcome {
        if key.isEmpty {
            switch method {
            case "GET" where q["list-type"] == "2": return listObjects(bucketName, q)
            case "GET" where q["location"] != nil:
                return xmlReply("<LocationConstraint xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(_state.buckets[bucketName]!.region)</LocationConstraint>")
            case "GET": return error(400, "InvalidRequest", "This fake serves ListObjectsV2 only (list-type=2).")
            case "HEAD": return empty(200, headers: ["x-amz-bucket-region": _state.buckets[bucketName]!.region])
            default: return error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.")
            }
        }
        switch method {
        case "GET", "HEAD": return getObject(bucketName, key, head: method == "HEAD")
        case "PUT":
            if let n = q["partNumber"], let id = q["uploadId"] { return uploadPart(bucketName, key, n, id, req: req, body: body) }
            if header(req, "x-amz-copy-source") != nil { return copyObject(bucketName, key, req: req) }
            return putObject(ep, bucketName, key, req: req, body: body)
        case "POST":
            if q["uploads"] != nil { return createUpload(bucketName, key, req: req) }
            if let id = q["uploadId"] { return completeUpload(ep, bucketName, key, id, req: req, body: body) }
            return error(400, "InvalidRequest", "Unsupported POST.")
        case "DELETE":
            if let id = q["uploadId"] {
                guard let u = _state.uploads[id], u.bucket == bucketName, S3Key.same(u.key, key) else {
                    return error(404, "NoSuchUpload", "The specified upload does not exist.")
                }
                _state.uploads[id] = nil
                _state.aborted += 1
                return empty(204)
            }
            _state.buckets[bucketName]!.objects[enc(key)] = nil
            return empty(204)
        default:
            return error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.")
        }
    }

    static func listBuckets(_ cred: Credential) -> Outcome {
        var xml = "<ListAllMyBucketsResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Owner><ID>fake</ID><DisplayName>fake</DisplayName></Owner><Buckets>"
        for name in _state.buckets.keys.sorted() where cred.buckets?.contains(name) ?? true {
            xml += "<Bucket><Name>\(S3XML.escape(name))</Name><CreationDate>\(iso(_state.buckets[name]!.created))</CreationDate></Bucket>"
        }
        xml += "</Buckets></ListAllMyBucketsResult>"
        return xmlReply(xml)
    }

    static func listObjects(_ bucketName: String, _ q: [String: String]) -> Outcome {
        _state.listRequests += 1
        let prefix = q["prefix"] ?? ""
        let delimiter = q["delimiter"].flatMap { $0.isEmpty ? nil : $0 }
        guard delimiter == nil || delimiter == "/" else { return error(400, "InvalidArgument", "This fake supports the delimiter \"/\" only.") }
        let maxKeys = min(Int(q["max-keys"] ?? "1000") ?? 1000, 1000, _state.pageSize)
        let urlEnc = q["encoding-type"] == "url"
        if let e = q["encoding-type"], e != "url" { return error(400, "InvalidArgument", "Invalid Encoding Method specified in Request") }
        var startAfter = q["start-after"]
        if let t = q["continuation-token"] {
            guard let d = Data(base64Encoded: t), let s = String(data: d, encoding: .utf8) else {
                return error(400, "InvalidArgument", "The continuation token provided is incorrect")
            }
            startAfter = s
        }
        // Every entry in byte order: objects and, with a delimiter, the prefixes they group into.
        var entries: [(key: String, prefix: Bool)] = []
        for k in _state.buckets[bucketName]!.keys where S3Key.hasPrefix(k, prefix) && !_state.ghostKeys.contains(k) {
            if delimiter != nil, let cp = S3Key.childPrefix(k, after: prefix) {
                if let last = entries.last, last.prefix, S3Key.same(last.key, cp) { continue }
                entries.append((cp, true))
            } else {
                entries.append((k, false))
            }
        }
        if let sa = startAfter { entries = entries.filter { S3Key.less(sa, $0.key) } }
        let page = Array(entries.prefix(maxKeys))
        let truncated = entries.count > page.count
        let e: (String) -> String = urlEnc ? urlEncode : rawXML
        var xml = "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(S3XML.escape(bucketName))</Name>"
        xml += "<Prefix>\(e(prefix))</Prefix><KeyCount>\(page.count)</KeyCount><MaxKeys>\(maxKeys)</MaxKeys>"
        if let delimiter { xml += "<Delimiter>\(e(delimiter))</Delimiter>" }
        if urlEnc { xml += "<EncodingType>url</EncodingType>" }
        if let t = q["continuation-token"] { xml += "<ContinuationToken>\(S3XML.escape(t))</ContinuationToken>" }
        xml += "<IsTruncated>\(truncated)</IsTruncated>"
        if truncated, let last = page.last, !_state.tokenlessListings.contains(prefix) {
            xml += "<NextContinuationToken>\(Data(last.key.utf8).base64EncodedString())</NextContinuationToken>"
        }
        for entry in page {
            if entry.prefix {
                xml += "<CommonPrefixes><Prefix>\(e(entry.key))</Prefix></CommonPrefixes>"
            } else {
                let o = _state.buckets[bucketName]!.object(entry.key)!
                xml += "<Contents><Key>\(e(o.key))</Key><LastModified>\(iso(o.modified))</LastModified><ETag>&quot;\(o.etag)&quot;</ETag>"
                xml += "<Size>\(o.data.count)</Size><StorageClass>\(o.storageClass ?? "STANDARD")</StorageClass></Contents>"
            }
        }
        xml += "</ListBucketResult>"
        if _state.truncateListings.contains(prefix) {
            var h = baseHeaders()
            h["Content-Type"] = "application/xml"
            return .reply(200, h, Data(xml.utf8.prefix(xml.utf8.count / 2)))
        }
        return xmlReply(xml)
    }

    static func objectHeaders(_ o: Object) -> [String: String] {
        var h = baseHeaders()
        h["Content-Type"] = o.contentType
        h["ETag"] = "\"\(o.etag)\""
        h["Last-Modified"] = DAVDates.httpString(o.modified)
        h["Content-Length"] = String(o.data.count)
        h["Accept-Ranges"] = "bytes"
        for (k, v) in o.meta { h[k] = v }
        for (k, v) in o.extra { h[k] = v }
        if let sc = o.storageClass, sc != "STANDARD" { h["x-amz-storage-class"] = sc }
        return h
    }

    static func getObject(_ bucketName: String, _ key: String, head: Bool) -> Outcome {
        guard let o = _state.buckets[bucketName]!.object(key), !(head && _state.ghostKeys.contains(key)) else {
            return head ? empty(404) : error(404, "NoSuchKey", "The specified key does not exist.", extra: ["Key": key])
        }
        if !head, ["GLACIER", "DEEP_ARCHIVE"].contains(o.storageClass ?? "") {
            return error(403, "InvalidObjectState", "The operation is not valid for the object's storage class")
        }
        return .reply(200, objectHeaders(o), head ? Data() : o.data)
    }

    /// x-amz-meta-* and the other kept headers of a request.
    static func metadata(_ req: URLRequest) -> (meta: [String: String], extra: [String: String], storageClass: String?)? {
        var meta = [String: String](), extra = [String: String]()
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            let name = k.lowercased()
            if name.hasPrefix("x-amz-meta-") {
                // Header values must be ASCII (S3 would mangle anything else).
                guard v.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
                meta[name] = v
            } else if ["content-encoding", "content-disposition", "content-language", "cache-control", "expires"].contains(name) {
                extra[name] = v
            }
        }
        return (meta, extra, header(req, "x-amz-storage-class"))
    }

    /// If-None-Match: * on a write, as the service treats it. Nil: go ahead.
    static func conditional(_ ep: Endpoint, _ req: URLRequest, exists: Bool) -> Outcome? {
        guard let inm = header(req, "If-None-Match") else { return nil }
        switch ep.conditional {
        case .notImplemented:
            return error(501, "NotImplemented", "A header you provided implies functionality that is not implemented", extra: ["Header": "If-None-Match"])
        case .ignored:
            return nil
        case .supported:
            guard inm == "*" else { return error(501, "NotImplemented", "If-None-Match supports only *") }
            return exists ? error(412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold", extra: ["Condition": "If-None-Match"]) : nil
        }
    }

    static func putObject(_ ep: Endpoint, _ bucketName: String, _ key: String, req: URLRequest, body: Data) -> Outcome {
        guard key.utf8.count <= 1024 else { return error(400, "KeyTooLongError", "Your key is too long") }
        if let c = conditional(ep, req, exists: _state.buckets[bucketName]!.object(key) != nil) { return c }
        guard body.count <= _state.maxPutSize else { return error(400, "EntityTooLarge", "Your proposed upload exceeds the maximum allowed size") }
        if let md5 = header(req, "Content-MD5"), Data(base64Encoded: md5).map(S3Signer.hex) != md5Hex(body) {
            return error(400, "BadDigest", "The Content-MD5 you specified did not match what we received.")
        }
        guard let m = metadata(req) else { return error(400, "InvalidArgument", "Metadata values must be US-ASCII.") }
        let o = Object(key: key, data: body, contentType: header(req, "Content-Type") ?? "binary/octet-stream", meta: m.meta, extra: m.extra,
                       modified: now(), etag: md5(body), storageClass: m.storageClass)
        _state.buckets[bucketName]!.objects[enc(key)] = o
        return empty(200, headers: ["ETag": "\"\(o.etag)\""])
    }

    static func md5Hex(_ d: Data) -> String { md5(d) }

    /// "/bucket/key" (URL-encoded) → (bucket, key).
    static func copySource(_ req: URLRequest) -> (String, String)? {
        guard var s = header(req, "x-amz-copy-source") else { return nil }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        guard let d = S3Signer.decode(s) else { return nil }
        let rest = Array(S3Key.dropPrefix(d, d.hasPrefix("/") ? "/" : "").utf8)
        guard let i = rest.firstIndex(of: UInt8(ascii: "/")) else { return nil }
        return (String(decoding: rest[..<i], as: UTF8.self), String(decoding: rest[(i + 1)...], as: UTF8.self))
    }

    static func copyObject(_ bucketName: String, _ key: String, req: URLRequest) -> Outcome {
        guard let (sb, sk) = copySource(req) else { return error(400, "InvalidArgument", "Copy Source must mention the source bucket and key: sourcebucket/sourcekey") }
        guard let src = _state.buckets[sb]?.object(sk) else { return error(404, "NoSuchKey", "The specified key does not exist.", extra: ["Key": sk]) }
        guard src.data.count <= _state.maxCopySize else {
            return error(400, "InvalidRequest", "The specified copy source is larger than the maximum allowable size for a copy source: \(_state.maxCopySize)")
        }
        if ["GLACIER", "DEEP_ARCHIVE"].contains(src.storageClass ?? "") {
            return error(403, "InvalidObjectState", "The operation is not valid for the object's storage class")
        }
        let directive = (header(req, "x-amz-metadata-directive") ?? "COPY").uppercased()
        guard directive == "COPY" || directive == "REPLACE" else { return error(400, "InvalidArgument", "Unknown metadata directive.") }
        if sb == bucketName && S3Key.same(sk, key) && directive == "COPY" {
            return error(400, "InvalidRequest", "This copy request is illegal because it is trying to copy an object to itself without changing the object's metadata.")
        }
        if _state.failCopiesIn200.contains(sk) {
            return xmlReply("<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>")
        }
        var o = src
        o.key = key
        o.modified = now()
        if directive == "REPLACE" {
            guard let m = metadata(req) else { return error(400, "InvalidArgument", "Metadata values must be US-ASCII.") }
            o.meta = m.meta
            o.extra = m.extra
            o.storageClass = m.storageClass
            o.contentType = header(req, "Content-Type") ?? "binary/octet-stream"
        }
        _state.buckets[bucketName]!.objects[enc(key)] = o
        _state.copies += 1
        return xmlReply("<CopyObjectResult><LastModified>\(iso(o.modified))</LastModified><ETag>&quot;\(o.etag)&quot;</ETag></CopyObjectResult>")
    }

    static func createUpload(_ bucketName: String, _ key: String, req: URLRequest) -> Outcome {
        guard let m = metadata(req) else { return error(400, "InvalidArgument", "Metadata values must be US-ASCII.") }
        let id = "upload-" + UUID().uuidString.lowercased()
        _state.uploads[id] = Upload(bucket: bucketName, key: key, contentType: header(req, "Content-Type") ?? "binary/octet-stream", meta: m.meta)
        return xmlReply("<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>\(S3XML.escape(bucketName))</Bucket>"
            + "<Key>\(rawXML(key))</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
    }

    static func uploadPart(_ bucketName: String, _ key: String, _ n: String, _ id: String, req: URLRequest, body: Data) -> Outcome {
        guard let u = _state.uploads[id], u.bucket == bucketName, S3Key.same(u.key, key) else {
            return error(404, "NoSuchUpload", "The specified upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.")
        }
        guard let num = Int(n), (1...10_000).contains(num) else {
            return error(400, "InvalidArgument", "Part number must be an integer between 1 and 10000, inclusive")
        }
        if _state.forbiddenParts.contains(num) { return error(403, "AccessDenied", "Access Denied") }
        if let left = _state.failParts[num], left > 0 {
            _state.failParts[num] = left - 1
            return error(500, "InternalError", "We encountered an internal error. Please try again.")
        }
        var data = body
        if header(req, "x-amz-copy-source") != nil {
            guard let (sb, sk) = copySource(req), let src = _state.buckets[sb]?.object(sk) else {
                return error(404, "NoSuchKey", "The specified key does not exist.")
            }
            data = src.data
            if let range = header(req, "x-amz-copy-source-range") {
                let nums = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
                guard nums.count == 2, nums[0] <= nums[1], nums[1] < src.data.count else {
                    return error(400, "InvalidArgument", "The x-amz-copy-source-range value must be of the form bytes=first-last where first and last are the zero-based offsets of the first and last bytes to copy")
                }
                data = src.data.subdata(in: nums[0]..<(nums[1] + 1))
            }
        }
        let etag = md5(data)
        _state.uploads[id]!.parts[num] = Part(data: data, etag: etag)
        _state.partPuts += 1
        if header(req, "x-amz-copy-source") != nil {
            return xmlReply("<CopyPartResult><LastModified>\(iso(now()))</LastModified><ETag>&quot;\(etag)&quot;</ETag></CopyPartResult>")
        }
        return empty(200, headers: ["ETag": "\"\(etag)\""])
    }

    static func completeUpload(_ ep: Endpoint, _ bucketName: String, _ key: String, _ id: String, req: URLRequest, body: Data) -> Outcome {
        guard let u = _state.uploads[id], u.bucket == bucketName, S3Key.same(u.key, key) else {
            return error(404, "NoSuchUpload", "The specified upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.")
        }
        guard let root = S3XML.parse(body), root.name == "CompleteMultipartUpload" else {
            return error(400, "MalformedXML", "The XML you provided was not well-formed or did not validate against our published schema")
        }
        let listed = root.all("Part").map { (Int($0.value("PartNumber") ?? "") ?? 0, S3Backend.cleanETag($0.value("ETag")) ?? "") }
        guard !listed.isEmpty else { return error(400, "MalformedXML", "You must specify at least one part") }
        for i in 1..<max(1, listed.count) where listed[i].0 <= listed[i - 1].0 {
            return error(400, "InvalidPartOrder", "The list of parts was not in ascending order. Parts must be ordered by part number.")
        }
        var data = Data()
        var md5s = Data()
        for (i, (num, etag)) in listed.enumerated() {
            guard let part = u.parts[num], part.etag == etag else {
                return error(400, "InvalidPart", "One or more of the specified parts could not be found. The part may not have been uploaded, or the specified entity tag may not match the part's entity tag.")
            }
            if i < listed.count - 1 && part.data.count < _state.minPartSize {
                return error(400, "EntityTooSmall", "Your proposed upload is smaller than the minimum allowed size", extra: ["PartNumber": String(num)])
            }
            data.append(part.data)
            md5s.append(Data(Insecure.MD5.hash(data: part.data)))
        }
        if let c = conditional(ep, req, exists: _state.buckets[bucketName]!.object(key) != nil) { return c }
        let etag = md5(md5s) + "-\(listed.count)"
        _state.buckets[bucketName]!.objects[enc(key)] = Object(key: key, data: data, contentType: u.contentType, meta: u.meta, extra: [:],
                                                              modified: now(), etag: etag, storageClass: nil)
        _state.uploads[id] = nil
        _state.completed += 1
        return xmlReply("<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Bucket>\(S3XML.escape(bucketName))</Bucket>"
            + "<Key>\(rawXML(key))</Key><ETag>&quot;\(etag)&quot;</ETag></CompleteMultipartUploadResult>")
    }
}
#endif
