import Foundation
import UniformTypeIdentifiers

/// An S3 bucket (AWS S3, Backblaze B2, Cloudflare R2, Wasabi, MinIO and other S3-compatible services), browsed
/// like iCloud Drive.
///
/// IDs are `"s3:/" + bucket + "/" + key`, folders ending in "/". With a bucket in the account `rootID` is
/// `"s3:/<bucket>/"`; without one `rootID` is `"s3:/"` and lists the buckets as folders (nothing can be added there).
/// Folders are key prefixes (CommonPrefixes with delimiter "/") and zero-byte "name/" marker objects. Deleted items
/// are moved (copy, then delete) into `.cirrus-deleted/` at the top of the bucket, with the original key in the
/// object's metadata, so nothing is erased until `deleteForever`.
public final class S3Backend: CloudDriveBackend, @unchecked Sendable {
    /// Where deleted items go, at the top of each bucket (hidden from listings).
    public static let trashPrefix = ".cirrus-deleted/"
    static let trashFolderName = ".cirrus-deleted"
    /// The original key of a deleted item (percent-encoded, so it stays ASCII).
    static let originalMeta = "x-amz-meta-cirrus-original"
    static let deletedMeta = "x-amz-meta-cirrus-deleted"
    /// The file's modification date (seconds since 1970), written on upload.
    static let mtimeMeta = "x-amz-meta-mtime"
    static let folderType = "application/x-directory"

    public let provider = CloudProvider.s3
    public let record: CloudAccountRecord
    public let rootID: String
    public var canListTrash: Bool { true }
    /// The bucket the account opens (nil: every bucket the keys can list).
    public let bucket: String?
    let client: S3Client

    private let lock = NSLock()
    private var _conditionalWrites: Bool?
    private var _originals = [String: String]()
    private var _multipartThreshold: Int64 = 32 << 20
    private var _partSize: Int64 = 16 << 20
    private var _maxCopySize: Int64 = 5 << 30
    private var _copyPartSize: Int64 = 512 << 20
    /// Serializes changes to `.cirrus-deleted/` (unique names).
    let trashLock = DAVAsyncLock()
    var concurrency = 6

    /// Files larger than this go up in parts (multipart upload).
    var multipartThreshold: Int64 { get { lock.withLock { _multipartThreshold } } set { lock.withLock { _multipartThreshold = newValue } } }
    /// Bytes per part (at least 8 MiB in the app; tests go lower). Raised as needed to stay within 10,000 parts.
    var partSize: Int64 { get { lock.withLock { _partSize } } set { lock.withLock { _partSize = newValue } } }
    /// Objects larger than this are copied in parts (UploadPartCopy): S3 copies at most 5 GB in one request.
    var maxCopySize: Int64 { get { lock.withLock { _maxCopySize } } set { lock.withLock { _maxCopySize = newValue } } }
    var copyPartSize: Int64 { get { lock.withLock { _copyPartSize } } set { lock.withLock { _copyPartSize = newValue } } }
    var retryBase: Double { get { client.retryBase } set { client.retryBase = newValue } }
    /// Does the service honour If-None-Match: * on writes? nil until a write tells.
    var conditionalWrites: Bool? { get { lock.withLock { _conditionalWrites } } set { lock.withLock { _conditionalWrites = newValue } } }

    public init(record: CloudAccountRecord, secretKey: String, transport: [AnyClass]?) throws {
        guard record.provider == .s3 else { throw CloudError.unsupported("\(record.provider.displayName) isn’t S3 storage.") }
        self.record = record
        let service = record.title.isEmpty ? CloudProvider.s3.displayName : "\(CloudProvider.s3.displayName) (\(record.title))"
        guard let server = record.server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty else {
            throw CloudError.notConfigured("This S3 account has no endpoint address. Remove it and add it again.")
        }
        var (endpoint, path) = try S3Endpoint.parse(server)
        endpoint.basePath = path.isEmpty ? "" : S3Signer.encode(path.hasPrefix("/") ? path : "/" + path, slash: false)
        guard let access = record.username?.trimmingCharacters(in: .whitespacesAndNewlines), !access.isEmpty else {
            throw CloudError.notConfigured("This S3 account has no access key ID. Remove it and add it again.")
        }
        guard !secretKey.isEmpty else { throw CloudError.signInNeeded(service) }
        let opts = record.options ?? [:]
        let b = opts["bucket"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        bucket = (b?.isEmpty ?? true) ? nil : b
        rootID = bucket.map { "s3:/" + $0 + "/" } ?? "s3:/"
        let pathStyle = opts["pathStyle"].map { ["1", "true", "yes"].contains($0.lowercased()) }
        client = S3Client(endpoint: endpoint, accessKey: access, secretKey: secretKey,
                          region: S3Endpoint.signingRegion(opts["region"], host: endpoint.host), pathStyle: pathStyle,
                          serviceName: service, transport: transport)
    }

    var host: String { client.endpoint.host + (client.endpoint.port.map { ":\($0)" } ?? "") }

    // MARK: IDs

    static func id(_ bucket: String, _ key: String) -> String { "s3:/" + bucket + "/" + key }

    /// (bucket, key) of an id; bucket nil for the list of buckets.
    func locate(_ id: String) throws -> (bucket: String?, key: String) {
        guard S3Key.hasPrefix(id, "s3:/") else { throw CloudError.notFound }
        let rest = Array(id.utf8.dropFirst(4))
        if rest.isEmpty {
            if let bucket { return (bucket, "") }
            return (nil, "")
        }
        let b: String, key: String
        if let i = rest.firstIndex(of: UInt8(ascii: "/")) {
            b = String(decoding: rest[..<i], as: UTF8.self)
            key = String(decoding: rest[(i + 1)...], as: UTF8.self)
        } else {
            b = String(decoding: rest, as: UTF8.self)
            key = ""
        }
        guard !b.isEmpty else { throw CloudError.notFound }
        if let bucket, !S3Key.same(b, bucket) { throw CloudError.notFound }
        return (b, key)
    }

    /// "" stays ""; "a" → "a/".
    static func folderKey(_ k: String) -> String { k.isEmpty || S3Key.isFolder(k) ? k : k + "/" }
    static func inTrash(_ k: String) -> Bool { S3Key.hasPrefix(k, trashPrefix) }

    static func cleanETag(_ e: String?) -> String? {
        guard var t = e?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("W/") { t.removeFirst(2) }
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// Whole seconds, so listings (milliseconds) and HEAD (an HTTP date) agree.
    static func seconds(_ d: Date?) -> Date? { d.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) } }

    func fileNode(_ b: String, _ key: String, size: Int64, modified: Date?, etag: String?) -> DriveNode {
        DriveNode(id: Self.id(b, key), zone: "s3", parentID: Self.id(b, S3Key.parent(key)),
                  name: S3Key.lastSegment(key).precomposedStringWithCanonicalMapping, type: "FILE", size: size,
                  modified: Self.seconds(modified), created: nil, etag: Self.cleanETag(etag))
    }

    func folderNode(_ b: String, _ prefix: String, modified: Date? = nil) -> DriveNode {
        DriveNode(id: Self.id(b, prefix), zone: "s3", parentID: Self.id(b, S3Key.parent(prefix)),
                  name: S3Key.lastSegment(prefix).precomposedStringWithCanonicalMapping, type: "FOLDER", size: 0,
                  modified: Self.seconds(modified), created: nil, etag: nil)
    }

    func display(_ b: String?, _ key: String) -> String {
        if key.isEmpty { return b ?? (record.title.isEmpty ? provider.displayName : record.title) }
        return S3Key.lastSegment(key).precomposedStringWithCanonicalMapping
    }

    // MARK: Listing

    struct Object: Sendable { var key: String; var size: Int64; var modified: Date?; var etag: String? }
    struct Listing: Sendable { var objects: [Object] = []; var prefixes: [String] = [] }

    /// Every key under `prefix` (all pages). With delimiter "/", deeper keys come back grouped as prefixes.
    func listAll(_ b: String, prefix: String, delimiter: String?, limit: Int? = nil) async throws -> Listing {
        var out = Listing()
        var token: String?
        var seen = Set<String>()
        var urlEncoding = false
        let what = "list “\(display(b, prefix))”"
        while true {
            try Task.checkCancellation()
            var q: [(String, String?)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(min(limit ?? 1000, 1000)))]
            if let delimiter { q.append(("delimiter", delimiter)) }
            if let token { q.append(("continuation-token", token)) }
            if urlEncoding { q.append(("encoding-type", "url")) }
            let r = try await client.send(.init(method: "GET", bucket: b, query: q))
            guard r.status == 200 else { throw failure(r, what, bucket: b) }
            guard let root = S3XML.parse(r.data), root.name == "ListBucketResult" else {
                // Keys with characters XML can't carry: ask for them URL-encoded.
                if !urlEncoding { urlEncoding = true; continue }
                throw CloudError.server("\(host)’s listing of “\(display(b, prefix))” was unreadable, so Cirrus didn’t show it. Try again.")
            }
            let encoded = root.value("EncodingType")?.lowercased() == "url"
            func dec(_ s: String) -> String { encoded ? (S3Signer.decode(s.replacingOccurrences(of: "+", with: " ")) ?? s) : s }
            for c in root.all("Contents") {
                guard let rawKey = c.value("Key") else { throw unreadable(b, prefix) }
                let key = dec(rawKey)
                guard S3Key.hasPrefix(key, prefix) else { throw unreadable(b, prefix) }
                out.objects.append(Object(key: key, size: Int64(c.value("Size")?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0,
                                          modified: c.value("LastModified").flatMap(S3Dates.iso8601), etag: c.value("ETag")))
            }
            for p in root.all("CommonPrefixes") {
                guard let raw = p.value("Prefix") else { throw unreadable(b, prefix) }
                let k = dec(raw)
                guard S3Key.hasPrefix(k, prefix) else { throw unreadable(b, prefix) }
                out.prefixes.append(k)
            }
            if let limit, out.objects.count + out.prefixes.count >= limit { return out }
            let truncated = root.value("IsTruncated")?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
            guard truncated else { return out }
            // A listing that's cut short can't be shown as if it were whole.
            guard let next = root.value("NextContinuationToken"), !next.isEmpty, seen.insert(next).inserted else {
                throw CloudError.server("\(host) cut the listing of “\(display(b, prefix))” short without a way to continue, so Cirrus didn’t show it.")
            }
            token = next
        }
    }

    func unreadable(_ b: String, _ prefix: String) -> CloudError {
        .server("\(host) listed “\(display(b, prefix))” in a way Cirrus couldn’t read, so it wasn’t shown. Try again.")
    }

    public func list(_ folderID: String) async throws -> [DriveNode] {
        let (b, raw) = try locate(folderID)
        guard let b else {
            return try await listBuckets().map {
                DriveNode(id: Self.id($0.name, ""), zone: "s3", parentID: rootID, name: $0.name.precomposedStringWithCanonicalMapping, type: "FOLDER",
                          size: 0, modified: Self.seconds($0.created), created: Self.seconds($0.created), etag: nil)
            }
        }
        let prefix = Self.folderKey(raw)
        let l = try await listAll(b, prefix: prefix, delimiter: "/")
        var out = [DriveNode]()
        var sawSelf = false
        for p in l.prefixes {
            if prefix.isEmpty && S3Key.same(p, Self.trashPrefix) { continue }
            guard !S3Key.lastSegment(p).isEmpty else { continue }
            out.append(folderNode(b, p))
        }
        for o in l.objects {
            if S3Key.same(o.key, prefix) { sawSelf = true; continue }      // the folder's own marker
            if S3Key.isFolder(o.key) {                                    // a marker S3 didn't group
                if !S3Key.lastSegment(o.key).isEmpty, !out.contains(where: { S3Key.same($0.id, Self.id(b, o.key)) }) {
                    out.append(folderNode(b, o.key, modified: o.modified))
                }
                continue
            }
            out.append(fileNode(b, o.key, size: o.size, modified: o.modified, etag: o.etag))
        }
        // A folder is its keys: no marker and nothing inside means it's gone (not "empty").
        if !prefix.isEmpty && out.isEmpty && !sawSelf { throw CloudError.notFound }
        let parent = Self.id(b, prefix)
        for i in out.indices { out[i].parentID = parent }
        return out
    }

    struct BucketInfo: Sendable { var name: String; var created: Date? }

    func listBuckets() async throws -> [BucketInfo] {
        var out = [BucketInfo]()
        var token: String?
        while true {
            try Task.checkCancellation()
            var q: [(String, String?)] = []
            if let token { q.append(("continuation-token", token)) }
            let r = try await client.send(.init(method: "GET", bucket: nil, query: q))
            guard r.status == 200 else { throw failure(r, "list the buckets") }
            guard let root = S3XML.parse(r.data), root.name == "ListAllMyBucketsResult" else {
                throw CloudError.server("\(host)’s list of buckets was unreadable. Try again.")
            }
            for b in root.child("Buckets")?.all("Bucket") ?? [] {
                guard let n = b.value("Name"), !n.isEmpty else { continue }
                out.append(BucketInfo(name: n, created: b.value("CreationDate").flatMap(S3Dates.iso8601)))
            }
            guard let next = root.value("ContinuationToken"), !next.isEmpty, next != token else { return out }
            token = next
        }
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        var unique = [String]()
        var set = Set<String>()
        for id in folderIDs where set.insert(id).inserted { unique.append(id) }
        let pairs = try await concurrentMap(unique) { id in (id, try await self.list(id)) }
        return Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    }

    /// Runs `op` on every item, at most `concurrency` at a time; the first error cancels the rest.
    func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], _ op: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        let limit = max(1, concurrency)
        return try await withThrowingTaskGroup(of: (Int, R).self) { g in
            var out = [R?](repeating: nil, count: items.count)
            var next = 0
            func add() {
                let i = next
                next += 1
                let item = items[i]
                g.addTask { (i, try await op(item)) }
            }
            while next < items.count && next < limit { add() }
            while let (i, r) = try await g.next() {
                out[i] = r
                if next < items.count { add() }
            }
            return out.compactMap { $0 }
        }
    }

    // MARK: Objects

    struct Head: Sendable {
        var size: Int64
        var modified: Date?
        var etag: String?
        /// Lower-cased names of the headers worth keeping on a copy (Content-Type…, x-amz-meta-*, storage class).
        var keep: [String: String]
        var meta: [String: String]
    }

    static let keptHeaders: Set<String> = ["content-type", "content-encoding", "content-disposition", "content-language", "cache-control",
                                           "expires", "x-amz-storage-class", "x-amz-website-redirect-location"]

    /// HEAD of one object; nil when there's none.
    func head(_ b: String, _ key: String) async throws -> Head? {
        let r = try await client.send(.init(method: "HEAD", bucket: b, key: key))
        if r.status == 404 { return nil }
        guard r.ok else { throw failure(r, "read “\(display(b, key))”", bucket: b) }
        var keep = [String: String](), meta = [String: String]()
        for (k, v) in r.http.allHeaderFields {
            guard let name = (k as? String)?.lowercased(), let value = v as? String else { continue }
            if name.hasPrefix("x-amz-meta-") { meta[name] = value; keep[name] = value }
            else if Self.keptHeaders.contains(name) { keep[name] = value }
        }
        let size = Int64(r.header("Content-Length") ?? "") ?? max(0, r.http.expectedContentLength)
        return Head(size: size, modified: r.header("Last-Modified").flatMap(DAVDates.http), etag: Self.cleanETag(r.header("ETag")), keep: keep, meta: meta)
    }

    /// Is there anything under `prefix` ("name/")?
    func prefixExists(_ b: String, _ prefix: String) async throws -> Bool {
        let l = try await listAll(b, prefix: prefix, delimiter: "/", limit: 1)
        return !l.objects.isEmpty || !l.prefixes.isEmpty
    }

    /// Is `base` taken, as a file ("base") or a folder ("base/…")?
    func taken(_ b: String, _ base: String) async throws -> Bool {
        async let file = head(b, base)
        async let folder = prefixExists(b, base + "/")
        let (f, d) = try await (file, folder)
        return f != nil || d
    }

    func ensureFree(_ b: String, _ base: String) async throws {
        if try await taken(b, base) { throw nameTaken(S3Key.lastSegment(base), in: S3Key.parent(base), bucket: b) }
    }

    func deleteObject(_ b: String, _ key: String) async throws {
        let r = try await client.send(.init(method: "DELETE", bucket: b, key: key))
        guard r.ok || r.status == 404 else { throw failure(r, "delete “\(display(b, key))”", bucket: b) }
    }

    /// Keeps a folder showing after its last item leaves (S3 folders are only their keys): writes its marker.
    func ensureMarker(_ b: String, _ prefix: String) async throws {
        guard !prefix.isEmpty, !Self.inTrash(prefix) else { return }
        if try await head(b, prefix) != nil { return }
        let r = try await client.send(.init(method: "PUT", bucket: b, key: prefix, headers: ["Content-Type": Self.folderType]))
        guard r.ok else { throw failure(r, "keep the folder “\(display(b, prefix))”", bucket: b) }
    }

    /// The x-amz-copy-source value: "/bucket/key", URL-encoded.
    static func copySource(_ b: String, _ key: String) -> String { "/" + S3Signer.encode(b, slash: true) + "/" + S3Signer.encode(key, slash: false) }

    /// Server-side copy. `replace`: the metadata for the copy (headers as in `Head.keep`); nil keeps the source's.
    func copyObject(_ sb: String, _ sk: String, to db: String, _ dk: String, size: Int64, replace: [String: String]?) async throws {
        if size > maxCopySize { return try await multipartCopy(sb, sk, to: db, dk, size: size, metadata: replace) }
        var h = ["x-amz-copy-source": Self.copySource(sb, sk)]
        if let replace {
            h["x-amz-metadata-directive"] = "REPLACE"
            h.merge(replace) { $1 }
        }
        let what = "copy “\(display(sb, sk))”"
        var attempt = 0
        while true {
            let r = try await client.send(.init(method: "PUT", bucket: db, key: dk, headers: h, timeout: 600))
            guard r.ok else {
                if r.status == 404 && r.code != "NoSuchBucket" { throw CloudError.notFound }
                throw failure(r, what, bucket: db)
            }
            // A copy can fail after "200 OK": the error is then in the body (S3 asks for a retry).
            guard let root = S3XML.parse(r.data), root.name == "Error" else { return }
            let e = S3ErrorBody.parse(r.data)
            if Self.retriable(e?.code), attempt < client.maxRetries {
                attempt += 1
                try await client.pause(client.delay(attempt: attempt, retryAfter: nil))
                continue
            }
            throw failure(S3Client.Response(status: 500, data: r.data, http: r.http, retried: r.retried, error: e), what, bucket: db)
        }
    }

    /// Copies an object larger than 5 GB in parts (UploadPartCopy).
    func multipartCopy(_ sb: String, _ sk: String, to db: String, _ dk: String, size: Int64, metadata: [String: String]?) async throws {
        var meta = metadata
        if meta == nil {
            guard let h = try await head(sb, sk) else { throw CloudError.notFound }
            meta = h.keep
        }
        let what = "copy “\(display(sb, sk))”"
        let uploadID = try await createMultipart(db, dk, headers: meta ?? [:], what: what)
        var finished = false
        defer { if !finished { abortMultipart(db, dk, uploadID) } }
        let part = max(copyPartSize, (size + 9_999) / 10_000)
        var parts = [(Int, String)]()
        var offset: Int64 = 0
        var n = 1
        while offset < size {
            try Task.checkCancellation()
            let end = min(offset + part, size) - 1
            let r = try await client.send(.init(method: "PUT", bucket: db, key: dk, query: [("partNumber", String(n)), ("uploadId", uploadID)],
                                                headers: ["x-amz-copy-source": Self.copySource(sb, sk), "x-amz-copy-source-range": "bytes=\(offset)-\(end)"],
                                                timeout: 600))
            guard r.ok, let root = S3XML.parse(r.data), root.name == "CopyPartResult", let etag = root.value("ETag") else {
                throw failure(r.ok ? S3Client.Response(status: 500, data: r.data, http: r.http, retried: r.retried, error: S3ErrorBody.parse(r.data)) : r,
                              what, bucket: db)
            }
            parts.append((n, etag))
            offset = end + 1
            n += 1
        }
        try await completeMultipart(db, dk, uploadID, parts: parts, size: size, conditional: false, what: what)
        finished = true
    }

    // MARK: Errors

    func failure(_ r: S3Client.Response, _ what: String, bucket b: String? = nil) -> CloudError {
        let code = r.code ?? ""
        let message = (r.error?.message ?? "").lowercased()
        switch code {
        case "NoSuchKey", "NoSuchUpload": return .notFound
        case "NoSuchBucket":
            return .notConfigured("There’s no bucket “\(b ?? bucket ?? "")” at \(host) any more. Check the bucket in the account, or remove the account and add it again.")
        case "InvalidAccessKeyId": return .signInNeeded(client.serviceName)
        case "SignatureDoesNotMatch":
            return .denied("\(host) didn’t accept the secret access key for “\(client.accessKey)” (the signature didn’t match). "
                + "Remove the account and add it again with the right secret key.")
        case "InvalidObjectState":
            return .denied("Cirrus couldn’t \(what): the item is archived (for example in Glacier) and must be restored in the service’s console first.")
        case "EntityTooLarge", "MaxMessageLengthExceeded":
            return .denied("\(host) doesn’t accept an item this large in one piece.")
        case "KeyTooLongError":
            return .denied("The name or folder path is too long for \(host) (at most 1,024 bytes).")
        case "QuotaExceeded", "StorageQuotaExceeded", "ServiceQuotaExceeded", "InsufficientStorage", "XMinioStorageFull":
            return .quotaExceeded(client.serviceName)
        case "RequestTimeTooSkewed":
            return .server("This device’s clock is too far off for \(host). Set the date and time automatically in Settings, then try again.")
        case "XAmzContentSHA256Mismatch", "BadDigest", "IncompleteBody":
            return .server("The file changed or was cut short while it was being uploaded. Try again.")
        case "PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException":
            return .notConfigured("The bucket is in a different region than the account says (\(client.defaultRegion)"
                + "\(r.error?.region.map { "; the service says \($0)" } ?? "")). Remove the account and add it again with the bucket’s region.")
        default: break
        }
        if message.contains("cap exceeded") || message.contains("quota") { return .quotaExceeded(client.serviceName) }
        switch r.status {
        case 403: return .denied("\(host) didn’t allow Cirrus to \(what). The access key may not have permission for this.")
        case 404, 410: return .notFound
        case 405, 501: return .unsupported("\(host) doesn’t support this (it couldn’t \(what)).")
        case 300..<400: return .server("\(host) answered with a redirect (\(r.status)) instead of doing it. Check the endpoint and region in the account.")
        default: return .server("\(host) couldn’t \(what) (\(r.status)\(code.isEmpty ? "" : " " + code)).")
        }
    }

    func nameTaken(_ name: String, in folder: String, bucket b: String) -> CloudError {
        .denied("There’s already an item named “\(name.precomposedStringWithCanonicalMapping)” in “\(display(b, folder))”. Choose a different name.")
    }

    static func checkName(_ name: String, top: Bool) throws {
        guard !name.isEmpty, name != ".", name != ".." else { throw CloudError.denied("“\(name)” can’t be used as a name.") }
        guard !name.contains("/"), !name.contains("\0") else { throw CloudError.denied("Names in S3 storage can’t contain “/”.") }
        guard name.utf8.count <= 1000 else { throw CloudError.denied("“\(name.prefix(40))…” is too long a name for S3 storage.") }
        if top && name == trashFolderName { throw CloudError.denied("“\(name)” is where Cirrus keeps deleted items. Choose a different name.") }
    }

    var topReadOnly: CloudError {
        .unsupported("Open a bucket first: nothing can be added next to the buckets of \(record.title.isEmpty ? host : record.title).")
    }

    /// The bucket and folder key items can be added to.
    func writableFolder(_ folderID: String) throws -> (bucket: String, folder: String) {
        let (b, raw) = try locate(folderID)
        guard let b else { throw topReadOnly }
        let folder = Self.folderKey(raw)
        guard !Self.inTrash(folder) else { throw CloudError.unsupported("Items can’t be added to \(provider.deletedTitle).") }
        return (b, folder)
    }

    func checkKey(_ key: String) throws {
        guard key.utf8.count <= 1024 else { throw CloudError.denied("The name or folder path is too long for S3 storage (at most 1,024 bytes).") }
    }

    // MARK: Download

    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !node.isFolder else { throw CloudError.unsupported("“\(node.name)” is a folder; download the items in it instead.") }
        let (b, key) = try locate(node.id)
        guard let b, !key.isEmpty, !S3Key.isFolder(key) else { throw CloudError.notFound }
        let r = try await client.send(.init(method: "GET", bucket: b, key: key, headers: ["Accept-Encoding": "identity"], timeout: 120),
                                      mode: .download(destination, expected: node.size), progress: progress)
        guard r.ok else { throw failure(r, "download “\(node.name)”", bucket: b) }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? node.size
        progress(size, max(size, node.size))
        let mtime = r.header(Self.mtimeMeta).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { Date(timeIntervalSince1970: $0) }
        if let m = mtime ?? r.header("Last-Modified").flatMap(DAVDates.http) ?? node.modified {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: destination.path)
        }
    }

    // MARK: Upload

    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        let (b, folder) = try writableFolder(folderID)
        try Self.checkName(name, top: folder.isEmpty)
        let key = folder + name
        try checkKey(key)
        // Never replace an existing item: replacing goes through the app's safe replace (upload, then trash the old one).
        try await ensureFree(b, key)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = modified ?? (attrs?[.modificationDate] as? Date) ?? Date()
        var headers = ["Content-Type": UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                       Self.mtimeMeta: String(Int64(mtime.timeIntervalSince1970.rounded(.down)))]
        if size > multipartThreshold {
            try await multipartUpload(file, size: size, bucket: b, key: key, headers: headers, progress: progress)
        } else {
            let d = try S3Hash.file(file)
            guard d.bytes == size else { throw CloudError.server("“\(name)” changed while it was being uploaded. Try again.") }
            while true {
                let cond = conditionalWrites != false
                if cond { headers["If-None-Match"] = "*" } else { headers["If-None-Match"] = nil }
                let r = try await client.send(.init(method: "PUT", bucket: b, key: key, headers: headers, body: .file(file), payloadHash: d.sha256, timeout: 300),
                                              progress: progress, total: size)
                if r.ok { if cond { conditionalWrites = true }; break }
                if cond && conditionalUnsupported(r) { conditionalWrites = false; continue }
                if r.status == 412 {
                    // A retried PUT can meet its own first attempt.
                    if r.retried, let h = try? await head(b, key), h.size == size, h.etag?.lowercased() == d.md5 { break }
                    throw nameTaken(name, in: folder, bucket: b)
                }
                throw failure(r, "upload “\(name)”", bucket: b)
            }
        }
        progress(size, size)
        if let h = try? await head(b, key) { return fileNode(b, key, size: h.size, modified: h.modified, etag: h.etag) }
        return fileNode(b, key, size: size, modified: Date(), etag: nil)
    }

    /// Services that don't do conditional writes say so with 501 NotImplemented (or a 400 naming the header).
    func conditionalUnsupported(_ r: S3Client.Response) -> Bool {
        if r.status == 501 || r.code == "NotImplemented" { return true }
        if r.status == 400, (r.error?.message ?? "").lowercased().contains("if-none-match") { return true }
        return false
    }

    func createMultipart(_ b: String, _ key: String, headers: [String: String], what: String) async throws -> String {
        let r = try await client.send(.init(method: "POST", bucket: b, key: key, query: [("uploads", nil)], headers: headers))
        guard r.ok, let root = S3XML.parse(r.data), root.name == "InitiateMultipartUploadResult",
              let id = root.value("UploadId"), !id.isEmpty else {
            throw failure(r.ok ? S3Client.Response(status: 500, data: r.data, http: r.http, retried: r.retried, error: S3ErrorBody.parse(r.data)) : r,
                          what, bucket: b)
        }
        return id
    }

    /// Leaves no unfinished upload behind (best effort, outside the cancelled task).
    func abortMultipart(_ b: String, _ key: String, _ uploadID: String) {
        let c = client
        Task.detached {
            _ = try? await c.send(.init(method: "DELETE", bucket: b, key: key, query: [("uploadId", uploadID)]))
        }
    }

    func completeMultipart(_ b: String, _ key: String, _ uploadID: String, parts: [(Int, String)], size: Int64, conditional: Bool, what: String) async throws {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        for (n, etag) in parts { xml += "<Part><PartNumber>\(n)</PartNumber><ETag>\(S3XML.escape(etag))</ETag></Part>" }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)
        while true {
            var h = ["Content-Type": "application/xml"]
            let cond = conditional && conditionalWrites != false
            if cond { h["If-None-Match"] = "*" }
            // Putting a big file together can take the service a while.
            let r = try await client.send(.init(method: "POST", bucket: b, key: key, query: [("uploadId", uploadID)], headers: h, body: .data(body),
                                                payloadHash: S3Signer.sha256Hex(body), timeout: 30 * 60))
            if r.ok {
                // CompleteMultipartUpload can fail after "200 OK": the error is then in the body.
                if let root = S3XML.parse(r.data), root.name == "Error" {
                    let e = S3ErrorBody.parse(r.data)
                    if Self.retriable(e?.code) { try await client.pause(client.delay(attempt: 1, retryAfter: nil)); continue }
                    throw failure(S3Client.Response(status: 500, data: r.data, http: r.http, retried: r.retried, error: e), what, bucket: b)
                }
                if cond { conditionalWrites = true }
                return
            }
            if cond && conditionalUnsupported(r) { conditionalWrites = false; continue }
            if r.status == 412 { throw nameTaken(S3Key.lastSegment(key), in: S3Key.parent(key), bucket: b) }
            // The answer to a first attempt got lost: if the object is there at its full size, it worked.
            if r.code == "NoSuchUpload", r.retried, let h = try? await head(b, key), h.size == size { return }
            throw failure(r, what, bucket: b)
        }
    }

    static func retriable(_ code: String?) -> Bool { code.map { S3Client.retryCodes.contains($0) } ?? false }

    /// CreateMultipartUpload, parts streamed from the file (each hashed and signed), CompleteMultipartUpload;
    /// the upload is aborted on any failure or cancellation.
    func multipartUpload(_ file: URL, size: Int64, bucket b: String, key: String, headers: [String: String],
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let name = S3Key.lastSegment(key)
        let what = "upload “\(name)”"
        let uploadID = try await createMultipart(b, key, headers: headers, what: what)
        var finished = false
        defer { if !finished { abortMultipart(b, key, uploadID) } }
        // At most 10,000 parts.
        let part = max(partSize, (size + 9_999) / 10_000)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var parts = [(Int, String)]()
        var offset: Int64 = 0
        var n = 1
        while offset < size {
            try Task.checkCancellation()
            let len = min(part, size - offset)
            let (tmp, d) = try S3Hash.slice(fh, offset: offset, length: len)
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            guard d.bytes == len else { throw CloudError.server("“\(name)” changed while it was being uploaded. Try again.") }
            let done = offset
            let r = try await client.send(.init(method: "PUT", bucket: b, key: key, query: [("partNumber", String(n)), ("uploadId", uploadID)],
                                                body: .file(tmp), payloadHash: d.sha256, timeout: 600),
                                          progress: { sent, _ in progress(done + sent, size) }, total: len)
            guard r.ok, let etag = r.header("ETag"), !etag.isEmpty else { throw failure(r, what, bucket: b) }
            parts.append((n, etag))
            offset += len
            n += 1
            progress(offset, size)
        }
        try Task.checkCancellation()
        try await completeMultipart(b, key, uploadID, parts: parts, size: size, conditional: true, what: what)
        finished = true
    }

    // MARK: Folders

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        let (b, folder) = try writableFolder(folderID)
        try Self.checkName(name, top: folder.isEmpty)
        let key = folder + name + "/"
        try checkKey(key)
        try await ensureFree(b, folder + name)
        while true {
            var h = ["Content-Type": Self.folderType]
            let cond = conditionalWrites != false
            if cond { h["If-None-Match"] = "*" }
            let r = try await client.send(.init(method: "PUT", bucket: b, key: key, headers: h))
            if r.ok { if cond { conditionalWrites = true }; break }
            if cond && conditionalUnsupported(r) { conditionalWrites = false; continue }
            if r.status == 412 {
                if r.retried { break }   // our own first attempt
                throw nameTaken(name, in: folder, bucket: b)
            }
            throw failure(r, "make the folder “\(name)”", bucket: b)
        }
        return folderNode(b, key, modified: Date())
    }

    // MARK: Rename and move

    /// Copies one object, then deletes the original (only once the copy is there).
    func moveObject(_ sb: String, _ sk: String, to db: String, _ dk: String, size: Int64, keepParent: Bool) async throws {
        try await copyObject(sb, sk, to: db, dk, size: size, replace: nil)
        if keepParent { try await ensureMarker(sb, S3Key.parent(sk)) }
        try await deleteObject(sb, sk)
    }

    /// Copies every key under a prefix to another prefix; deletes the originals only when every copy worked
    /// (a failed copy removes the copies made so far and leaves the originals as they were).
    func movePrefix(_ sb: String, _ sp: String, to db: String, _ dp: String, keepParent: Bool,
                    marker: (key: String, headers: [String: String])? = nil, skipSourceMarker: Bool = false) async throws {
        let all = try await listAll(sb, prefix: sp, delimiter: nil)
        guard !all.objects.isEmpty else { throw CloudError.notFound }
        let objects = all.objects.filter { !(skipSourceMarker && S3Key.same($0.key, sp)) }
        do {
            if let marker {
                let r = try await client.send(.init(method: "PUT", bucket: db, key: marker.key, headers: marker.headers))
                guard r.ok else { throw failure(r, "move “\(display(sb, sp))”", bucket: db) }
            }
            _ = try await concurrentMap(objects) { o in
                try await self.copyObject(sb, o.key, to: db, dp + S3Key.dropPrefix(o.key, sp), size: o.size, replace: nil)
            }
        } catch {
            // Leave things as they were: remove every copy (the destination was checked to be free; the originals
            // were never touched). Copies cut off mid-way may still have landed, so all of them, not only the finished.
            let undo = objects.map { dp + S3Key.dropPrefix($0.key, sp) } + (marker.map { [$0.key] } ?? [])
            let c = client
            Task.detached { for k in undo { _ = try? await c.send(.init(method: "DELETE", bucket: db, key: k)) } }
            throw error
        }
        if keepParent { try await ensureMarker(sb, S3Key.parent(sp)) }
        do {
            _ = try await concurrentMap(all.objects) { o in try await self.deleteObject(sb, o.key) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudError.server("“\(display(sb, sp))” was copied, but some of the originals couldn’t be removed (\(error.localizedDescription)). Both copies are kept.")
        }
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        let (b, key) = try locate(node.id)
        guard let b, !key.isEmpty, !Self.inTrash(key) else { throw CloudError.unsupported("“\(node.name)” can’t be renamed.") }
        let folder = S3Key.parent(key)
        try Self.checkName(name, top: folder.isEmpty)
        let isFolder = node.isFolder || S3Key.isFolder(key)
        let base = folder + name
        let newKey = base + (isFolder ? "/" : "")
        if S3Key.same(newKey, key) { return node }
        try checkKey(newKey)
        try await ensureFree(b, base)
        if isFolder {
            try await movePrefix(b, Self.folderKey(key), to: b, newKey, keepParent: false)
            return folderNode(b, newKey, modified: node.modified)
        }
        let size = try await head(b, key)?.size ?? node.size
        try await moveObject(b, key, to: b, newKey, size: size, keepParent: false)
        if let h = try? await head(b, newKey) { return fileNode(b, newKey, size: h.size, modified: h.modified, etag: h.etag) }
        var n = node
        n.id = Self.id(b, newKey)
        n.name = name.precomposedStringWithCanonicalMapping
        n.parentID = Self.id(b, folder)
        return n
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        let (db, raw) = try locate(folderID)
        guard let db else { throw topReadOnly }
        let dest = Self.folderKey(raw)
        guard !Self.inTrash(dest) else { throw CloudError.unsupported("Use Delete to put items in \(provider.deletedTitle).") }
        for n in nodes {
            try Task.checkCancellation()
            let (sb, key) = try locate(n.id)
            guard let sb, !key.isEmpty, !Self.inTrash(key) else { throw CloudError.unsupported("“\(n.name)” can’t be moved.") }
            if S3Key.same(sb, db) && S3Key.same(S3Key.parent(key), dest) { continue }
            let isFolder = n.isFolder || S3Key.isFolder(key)
            let seg = S3Key.lastSegment(key)
            if isFolder && S3Key.same(sb, db) && S3Key.hasPrefix(dest, Self.folderKey(key)) {
                throw CloudError.denied("“\(n.name)” can’t be moved into itself.")
            }
            if dest.isEmpty && seg == Self.trashFolderName { throw CloudError.denied("“\(seg)” can’t be moved to the top of the bucket.") }
            let base = dest + seg
            try checkKey(base + "/")
            try await ensureFree(db, base)
            if isFolder {
                try await movePrefix(sb, Self.folderKey(key), to: db, base + "/", keepParent: true)
            } else {
                let size = try await head(sb, key)?.size ?? n.size
                try await moveObject(sb, key, to: db, base, size: size, keepParent: true)
            }
        }
    }

    // MARK: Trash (.cirrus-deleted/)

    static func numbered(_ name: String, _ n: Int, folder: Bool) -> String { WebDAVDrive.numbered(name, n, folder: folder) }

    /// The headers to put on a copy whose metadata changes: what the original had, minus Cirrus's trash notes.
    static func carried(_ h: Head) -> [String: String] {
        h.keep.filter { $0.key != originalMeta && $0.key != deletedMeta }
    }

    static func trashNote(_ originalKey: String) -> [String: String] {
        [originalMeta: S3Signer.encode(originalKey, slash: false), deletedMeta: String(Int64(Date().timeIntervalSince1970))]
    }

    public func trash(_ nodes: [DriveNode]) async throws {
        guard !nodes.isEmpty else { return }
        var byBucket = [String: [(DriveNode, String)]]()
        var order = [String]()
        for n in nodes {
            let (b, key) = try locate(n.id)
            guard let b, !key.isEmpty else { throw CloudError.unsupported("“\(n.name)” can’t be deleted from Cirrus.") }
            guard !Self.inTrash(key) else { throw CloudError.unsupported("“\(n.name)” is already in \(provider.deletedTitle).") }
            if byBucket[b] == nil { order.append(b) }
            byBucket[b, default: []].append((n, key))
        }
        try await trashLock.withLock {
            for b in order {
                let current = try await listAll(b, prefix: Self.trashPrefix, delimiter: "/")
                var taken = Set((current.objects.map(\.key) + current.prefixes).map { S3Key.lastSegment($0) })
                for (n, key) in byBucket[b] ?? [] {
                    try Task.checkCancellation()
                    let isFolder = n.isFolder || S3Key.isFolder(key)
                    let seg = S3Key.lastSegment(key)
                    var candidate = seg
                    var k = 2
                    while taken.contains(candidate) {
                        candidate = Self.numbered(seg, k, folder: isFolder)
                        k += 1
                    }
                    do {
                        if isFolder {
                            let prefix = Self.folderKey(key)
                            var mh = Self.trashNote(prefix)
                            mh["Content-Type"] = Self.folderType
                            try await movePrefix(b, prefix, to: b, Self.trashPrefix + candidate + "/", keepParent: true,
                                                 marker: (Self.trashPrefix + candidate + "/", mh), skipSourceMarker: true)
                        } else {
                            guard let h = try await head(b, key) else { continue }   // already gone
                            var meta = Self.carried(h)
                            meta.merge(Self.trashNote(key)) { $1 }
                            try await copyObject(b, key, to: b, Self.trashPrefix + candidate, size: h.size, replace: meta)
                            try await ensureMarker(b, S3Key.parent(key))
                            try await deleteObject(b, key)
                        }
                    } catch CloudError.notFound {
                        continue   // already gone
                    }
                    taken.insert(candidate)
                }
            }
        }
    }

    /// The original key a deleted item came from (nil: unknown, e.g. put there by another app).
    func originalKey(_ b: String, _ trashKey: String, etag: String?, modified: Date?) async throws -> String? {
        let cacheKey = Self.id(b, trashKey) + "|" + (etag ?? "") + "|" + String(modified?.timeIntervalSince1970 ?? 0)
        if let v = lock.withLock({ _originals[cacheKey] }) { return v.isEmpty ? nil : v }
        let h = try await head(b, trashKey)
        let v = h?.meta[Self.originalMeta].flatMap { S3Signer.decode($0) } ?? ""
        lock.withLock {
            if _originals.count > 20_000 { _originals.removeAll() }
            _originals[cacheKey] = v
        }
        return v.isEmpty ? nil : v
    }

    public func listTrash() async throws -> [DriveNode] {
        let buckets: [String]
        if let bucket { buckets = [bucket] } else { buckets = try await listBuckets().map(\.name) }
        let perBucket = try await concurrentMap(buckets) { b -> [DriveNode] in
            do { return try await self.trashEntries(b) } catch let e as CloudError where self.bucket == nil {
                // Without a bucket in the account, skip buckets these keys can't read.
                if case .denied = e { return [] }
                if case .notConfigured = e { return [] }
                throw e
            }
        }
        return perBucket.flatMap { $0 }
    }

    func trashEntries(_ b: String) async throws -> [DriveNode] {
        let l = try await listAll(b, prefix: Self.trashPrefix, delimiter: "/")
        var entries: [(key: String, folder: Bool, size: Int64, modified: Date?, etag: String?)] = []
        for p in l.prefixes where !S3Key.lastSegment(p).isEmpty { entries.append((p, true, 0, nil, nil)) }
        for o in l.objects where !S3Key.same(o.key, Self.trashPrefix) && !S3Key.lastSegment(o.key).isEmpty {
            entries.append((o.key, S3Key.isFolder(o.key), o.size, o.modified, o.etag))
        }
        let parent = Self.id(b, Self.trashPrefix)
        return try await concurrentMap(entries) { e in
            let original = try await self.originalKey(b, e.key, etag: e.etag, modified: e.modified)
            var n = e.folder ? self.folderNode(b, e.key, modified: e.modified) : self.fileNode(b, e.key, size: e.size, modified: e.modified, etag: e.etag)
            if let original, !S3Key.lastSegment(original).isEmpty { n.name = S3Key.lastSegment(original).precomposedStringWithCanonicalMapping }
            n.parentID = parent
            return n
        }
    }

    /// Items directly inside `.cirrus-deleted/` (bucket, key). Anything else is refused.
    func trashItems(_ nodes: [DriveNode], what: String) throws -> [(DriveNode, String, String)] {
        try nodes.map { n in
            let (b, key) = try locate(n.id)
            guard let b, Self.inTrash(key), !S3Key.same(key, Self.trashPrefix), S3Key.same(S3Key.parent(key), Self.trashPrefix) else {
                throw CloudError.unsupported("“\(n.name)” isn’t in \(provider.deletedTitle), so it can’t be \(what).")
            }
            return (n, b, key)
        }
    }

    public func restore(_ nodes: [DriveNode]) async throws {
        let items = try trashItems(nodes, what: "recovered")
        try await trashLock.withLock {
            var failure: Error?
            for (n, b, key) in items {
                do {
                    try Task.checkCancellation()
                    let isFolder = n.isFolder || S3Key.isFolder(key)
                    let h = try await head(b, key)
                    if !isFolder && h == nil { throw CloudError.notFound }
                    var original = h?.meta[Self.originalMeta].flatMap { S3Signer.decode($0) } ?? ""
                    if S3Key.isFolder(original) { original = String(decoding: original.utf8.dropLast(), as: UTF8.self) }
                    // Unknown or odd origin: put it back at the top of the bucket under its name in the trash.
                    if original.isEmpty || Self.inTrash(original) { original = S3Key.lastSegment(key) }
                    let folder = S3Key.parent(original)
                    let name = S3Key.lastSegment(original)
                    var candidate = name
                    var k = 2
                    // Something new has the name meanwhile: keep both, like Finder ("Report 2.txt").
                    while try await taken(b, folder + candidate) {
                        guard k < 500 else { throw nameTaken(name, in: folder, bucket: b) }
                        candidate = Self.numbered(name, k, folder: isFolder)
                        k += 1
                    }
                    let dest = folder + candidate
                    if isFolder {
                        try await movePrefix(b, key, to: b, dest + "/", keepParent: false,
                                             marker: (dest + "/", ["Content-Type": Self.folderType]), skipSourceMarker: true)
                    } else if let h {
                        try await copyObject(b, key, to: b, dest, size: h.size, replace: Self.carried(h))
                        try await deleteObject(b, key)
                    }
                } catch CloudError.notFound {
                    failure = failure ?? CloudError.notFound
                } catch {
                    failure = error
                    break
                }
            }
            if let failure { throw failure }
        }
    }

    public func deleteForever(_ nodes: [DriveNode]) async throws {
        let items = try trashItems(nodes, what: "deleted")
        try await trashLock.withLock {
            for (n, b, key) in items {
                try Task.checkCancellation()
                if n.isFolder || S3Key.isFolder(key) {
                    let all = try await listAll(b, prefix: Self.folderKey(key), delimiter: nil)
                    _ = try await concurrentMap(all.objects) { o in try await self.deleteObject(b, o.key) }
                } else {
                    try await deleteObject(b, key)
                }
            }
        }
    }

    // MARK: Quota, thumbnails, validation

    public func quota() async throws -> StorageUsage? { nil }
    public func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data? { nil }

    /// Checks the keys against the bucket (ListObjectsV2, one key) or the account (ListBuckets).
    func validate() async throws {
        if let b = bucket {
            let r = try await client.send(.init(method: "GET", bucket: b, query: [("list-type", "2"), ("max-keys", "1")]))
            guard r.status == 200 else { throw connectFailure(r) }
            guard S3XML.parse(r.data)?.name == "ListBucketResult" else {
                throw CloudError.notConfigured("\(host) answered, but not like an S3 service. Check the endpoint address.")
            }
        } else {
            let r = try await client.send(.init(method: "GET", bucket: nil))
            guard r.status == 200 else { throw connectFailure(r) }
            guard S3XML.parse(r.data)?.name == "ListAllMyBucketsResult" else {
                throw CloudError.notConfigured("\(host) answered, but not like an S3 service. Check the endpoint address.")
            }
        }
    }

    func connectFailure(_ r: S3Client.Response) -> CloudError {
        switch r.code ?? "" {
        case "InvalidAccessKeyId":
            return .denied("\(host) doesn’t know the access key ID “\(client.accessKey)”. Check that it’s copied in full and belongs to this service and region.")
        case "SignatureDoesNotMatch":
            return .denied("The secret access key doesn’t match the access key ID. Check that the secret key is copied in full, with nothing added.")
        case "AccessDenied", "AllAccessDisabled":
            if let b = bucket {
                return .denied("These keys aren’t allowed to list the bucket “\(b)”. Give the key read and write access to it, then try again.")
            }
            return .denied("These keys can’t list the account’s buckets. Enter the name of the bucket to open.")
        case "NoSuchBucket":
            return .notConfigured("There’s no bucket named “\(bucket ?? "")” at \(host). Check the name (bucket names are case-sensitive).")
        case "AuthorizationHeaderMalformed", "PermanentRedirect", "IllegalLocationConstraintException":
            return .notConfigured("\(host) expects a different region\(r.error?.region.map { " (\($0))" } ?? ""). Check the region.")
        default:
            break
        }
        switch r.status {
        case 403: return .denied("\(host) refused these keys. Check the access key ID and secret access key.")
        case 404: return bucket == nil ? .notConfigured("\(host) isn’t an S3 endpoint. Check the address.")
                                       : .notConfigured("There’s no bucket named “\(bucket!)” at \(host). Check the name.")
        case 301, 307: return .notConfigured("The bucket is in a different region. Enter the bucket’s region and try again.")
        default: return failure(r, bucket == nil ? "list the buckets" : "open the bucket")
        }
    }
}
