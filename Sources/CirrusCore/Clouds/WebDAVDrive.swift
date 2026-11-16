import Foundation
import UniformTypeIdentifiers

/// Where an item lives: the user's files, or (Nextcloud) its trash bin.
enum DAVSpace: Sendable { case files, trash }

/// A Nextcloud account or a plain WebDAV folder (ownCloud, OpenCloud, Synology, QNAP, Apache…), browsed like iCloud Drive.
///
/// IDs are `"dav:" + path` relative to the account's DAV root, percent-decoded, folders ending in "/" (`rootID == "dav:/"`).
/// The path keeps the server's own spelling (so requests match byte for byte); `name` is NFC for display and comparison.
/// Items in Nextcloud's trash bin are `"dav-trash:" + path` inside the bin.
public final class WebDAVDrive: CloudDriveBackend, @unchecked Sendable {
    /// Plain WebDAV servers have no trash, so Cirrus keeps deleted items in this top-level folder.
    public static let trashFolderName = "Deleted by Cirrus"
    /// Inside that folder: where each item came from.
    public static let manifestName = ".cirrus-deleted.json"
    static let trashPath = "/" + trashFolderName + "/"

    public let provider: CloudProvider
    public let record: CloudAccountRecord
    public let rootID = "dav:/"
    public var canListTrash: Bool { true }

    let client: DAVClient
    /// Nextcloud: the server's base URL (no trailing slash).
    let base: URL?
    /// Plain WebDAV: the folder URL (ending in "/").
    let plainRoot: URL?
    let loginName: String

    private let lock = NSLock()
    private var uidTask: Task<String, Error>?
    private var _trashbin: Bool?
    private var previews = [String: Bool]()
    /// Serializes changes to the "Deleted by Cirrus" folder and its manifest.
    let manifestLock = DAVAsyncLock()

    // Tuning (tests lower these).
    private var _chunkSize: Int64 = 10 << 20
    private var _chunkThreshold: Int64 = 10 << 20
    /// Nextcloud chunked uploads: bytes per chunk (Nextcloud needs at least 5 MiB except for the last one).
    var chunkSize: Int64 { get { lock.withLock { _chunkSize } } set { lock.withLock { _chunkSize = newValue } } }
    /// Nextcloud: files larger than this are uploaded in chunks.
    var chunkThreshold: Int64 { get { lock.withLock { _chunkThreshold } } set { lock.withLock { _chunkThreshold = newValue } } }
    var listConcurrency = 6
    var retryBase: Double { get { client.retryBase } set { client.retryBase = newValue } }

    public init(record: CloudAccountRecord, password: String?, transport: [AnyClass]?) throws {
        guard record.provider == .nextcloud || record.provider == .webdav else {
            throw CloudError.unsupported("\(record.provider.displayName) isn’t a WebDAV service.")
        }
        self.record = record
        provider = record.provider
        loginName = record.username ?? ""
        guard let s = record.server?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw CloudError.notConfigured("This \(record.provider.displayName) account has no server address. Remove it and add it again.")
        }
        switch record.provider {
        case .nextcloud:
            guard !loginName.isEmpty else { throw CloudError.notConfigured("This Nextcloud account has no user name. Sign in again.") }
            base = try NextcloudLoginFlow.baseURL(from: s)
            plainRoot = nil
        default:
            plainRoot = try WebDAV.folderURL(from: s)
            base = nil
        }
        listBody = record.provider == .nextcloud
            ? Self.propfindBody(dav: Self.davProps, oc: ["fileid", "size", "share-types"], nc: ["has-preview"])
            : Self.propfindBody(dav: Self.davProps)
        let service = record.title.isEmpty ? record.provider.displayName : "\(record.provider.displayName) (\(record.title))"
        client = DAVClient(username: record.username, password: password, serviceName: service, transport: transport)
    }

    // MARK: IDs and URLs

    static func id(_ space: DAVSpace, _ path: String) -> String { (space == .trash ? "dav-trash:" : "dav:") + path }

    func locate(_ id: String) throws -> (space: DAVSpace, path: String) {
        let space: DAVSpace, path: String
        if id.hasPrefix("dav-trash:") { space = .trash; path = String(id.dropFirst("dav-trash:".count)) }
        else if id.hasPrefix("dav:") { space = .files; path = String(id.dropFirst("dav:".count)) }
        else { throw CloudError.notFound }
        guard path.hasPrefix("/") else { throw CloudError.notFound }
        if space == .trash && provider != .nextcloud { throw CloudError.notFound }
        return (space, path)
    }

    static func folderPath(_ p: String) -> String { p.hasSuffix("/") ? p : p + "/" }

    var davBase: URL { URL(string: base!.absoluteString + "/remote.php/dav/")! }

    func root(_ space: DAVSpace) async throws -> URL {
        if provider != .nextcloud {
            guard space == .files, let r = plainRoot else { throw CloudError.notFound }
            return r
        }
        let uid = DAVURL.encodeSegment(try await userID())
        let b = base!.absoluteString
        switch space {
        case .files: return URL(string: b + "/remote.php/dav/files/" + uid + "/")!
        case .trash: return URL(string: b + "/remote.php/dav/trashbin/" + uid + "/trash/")!
        }
    }

    func url(_ space: DAVSpace, _ path: String) async throws -> URL { DAVURL.join(try await root(space), path) }

    /// Nextcloud's file paths use the user ID, which can differ from the login name (email logins, LDAP):
    /// ask the server once (current-user-principal).
    func userID() async throws -> String {
        guard provider == .nextcloud else { return loginName }
        let task: Task<String, Error> = lock.withLock {
            if let t = uidTask { return t }
            let t = Task { try await self.discoverUserID() }
            uidTask = t
            return t
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if uidTask == task { uidTask = nil } }
            throw error
        }
    }

    private func discoverUserID() async throws -> String {
        let u = davBase
        let body = Data(#"<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>"#.utf8)
        let r = try await client.send("PROPFIND", u, headers: Self.propfindHeaders("0"), body: .data(body), retry: .safe)
        if r.status == 207, let res = try? DAVMultistatus.parse(r.data, requestURL: u),
           let href = res.first(where: { $0.dav("current-user-principal") != nil })?.dav("current-user-principal"), !href.isEmpty {
            let p = DAVMultistatus.resolve(href, against: u)
            let uid = DAVURL.lastSegment(p)
            if !uid.isEmpty && p.contains("/principals/") { return uid }
        }
        if r.status == 404 || r.status == 405 || r.status == 501 {
            throw CloudError.notConfigured("\(base?.host ?? "The server") doesn’t look like a Nextcloud server (it has no remote.php/dav). Check the address.")
        }
        if r.status >= 400 && r.status != 403 { throw failure(r, "sign in") }
        return loginName
    }

    static func propfindHeaders(_ depth: String) -> [String: String] {
        ["Depth": depth, "Content-Type": "application/xml; charset=utf-8", "Accept": "application/xml, text/xml"]
    }

    // MARK: PROPFIND

    static func propfindBody(dav: [String], oc: [String] = [], nc: [String] = []) -> Data {
        var s = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        s += #"<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"><d:prop>"#
        for p in dav { s += "<d:\(p)/>" }
        for p in oc { s += "<oc:\(p)/>" }
        for p in nc { s += "<nc:\(p)/>" }
        s += "</d:prop></d:propfind>"
        return Data(s.utf8)
    }

    static let davProps = ["resourcetype", "getcontentlength", "getlastmodified", "getetag", "getcontenttype", "creationdate"]
    /// What a listing asks for (Nextcloud adds its file id, size, sharing and preview properties).
    let listBody: Data
    static let trashBody = propfindBody(dav: davProps, oc: ["fileid", "size"],
                                        nc: ["trashbin-filename", "trashbin-original-location", "trashbin-deletion-time"])
    static let quotaBody = propfindBody(dav: ["resourcetype", "quota-used-bytes", "quota-available-bytes"])

    func propfind(_ url: URL, depth: String, body: Data, what: String) async throws -> [DAVResource] {
        let r = try await client.send("PROPFIND", url, headers: Self.propfindHeaders(depth), body: .data(body), retry: .safe)
        guard r.status == 207 else { throw failure(r, what) }
        return try DAVMultistatus.parse(r.data, requestURL: url)
    }

    /// The account-relative path of a resolved href, or nil when it isn't inside `rootPath`.
    static func relative(_ path: String, root rootPath: String) -> String? {
        let p = DAVURL.clean(path)
        let root = DAVURL.folderPathClean(rootPath)
        if p.hasPrefix(root) { return "/" + p.dropFirst(root.count) }
        if DAVURL.trimmedSlash(p) == DAVURL.trimmedSlash(root) { return "/" }
        // Some servers change the case or Unicode form of the folder part.
        let pc = p.precomposedStringWithCanonicalMapping, rc = root.precomposedStringWithCanonicalMapping
        if let r = pc.range(of: rc, options: [.anchored, .caseInsensitive]) { return "/" + pc[r.upperBound...] }
        if pc.compare(DAVURL.trimmedSlash(rc), options: .caseInsensitive) == .orderedSame { return "/" }
        return nil
    }

    func node(_ r: DAVResource, space: DAVSpace, path: String, parentID: String?) -> DriveNode {
        let folder = r.isCollection
        var p = path
        if folder && !p.hasSuffix("/") { p += "/" }
        if !folder && p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        var raw = DAVURL.lastSegment(p)
        if space == .trash, p.split(separator: "/").count == 1, let tn = r.nc("trashbin-filename"), !tn.isEmpty { raw = tn }
        var n = DriveNode(id: Self.id(space, p), docID: r.fileID, zone: "dav", parentID: parentID, name: raw.precomposedStringWithCanonicalMapping,
                          type: folder ? "FOLDER" : "FILE", size: folder ? 0 : r.size, modified: r.modified, created: r.created, etag: r.etag)
        n.isShared = r.isShared
        if let hp = r.hasPreview, !folder { notePreview(n.id, hp) }
        return n
    }

    func notePreview(_ id: String, _ has: Bool) {
        lock.withLock {
            if previews.count > 50_000 { previews.removeAll() }
            previews[id] = has
        }
    }

    /// Hidden from listings: the "Deleted by Cirrus" folder at the top (plain WebDAV, or Nextcloud without its trash
    /// app) and the manifest inside it.
    func hidden(_ space: DAVSpace, folder: String, name: String) -> Bool {
        guard space == .files else { return false }
        if folder == "/" && name == Self.trashFolderName { return usesFolderTrash }
        if folder == Self.trashPath && name == Self.manifestName { return true }
        return false
    }

    var usesFolderTrash: Bool { provider != .nextcloud || lock.withLock { _trashbin == false } }

    // MARK: Listing

    public func list(_ folderID: String) async throws -> [DriveNode] {
        let (space, raw) = try locate(folderID)
        let path = Self.folderPath(raw)
        let rootURL = try await root(space)
        let url = DAVURL.join(rootURL, path)
        let what = "list “\(display(path, space: space))”"
        let res = try await propfind(url, depth: "1", body: space == .trash ? Self.trashBody : listBody, what: what)
        let rootPath = DAVURL.decodedPath(rootURL)
        let want = DAVURL.trimmedSlash(path).precomposedStringWithCanonicalMapping
        let parentID = Self.id(space, path)
        // Nextcloud keeps a "Deleted by Cirrus" folder only when its trash app is off: find out before hiding one.
        if provider == .nextcloud, space == .files, path == "/", lock.withLock({ _trashbin == nil }),
           res.contains(where: { DAVURL.lastSegment($0.path) == Self.trashFolderName && $0.isCollection }) {
            _ = try? await trashbinAvailable()
        }
        var out = [DriveNode]()
        var seen = Set<String>()
        for r in res {
            if let s = r.status, s != 200 {
                if s == 404 { continue }          // vanished while listing
                throw CloudError.server("The server couldn’t read part of “\(display(path, space: space))” (\(s)). Nothing was changed; try again.")
            }
            guard let rel = Self.relative(r.path, root: rootPath) else {
                // A listing we can't place would look like an empty or changed folder: stop instead.
                throw CloudError.server("The server listed “\(display(path, space: space))” at an unexpected address, so Cirrus didn’t show it. "
                    + "If the server is behind a proxy, check that the address in the account matches the server’s own.")
            }
            let relTrim = DAVURL.trimmedSlash(rel)
            if relTrim.precomposedStringWithCanonicalMapping == want {
                if !r.isCollection && space == .files { throw CloudError.unsupported("“\(display(path, space: space))” is a file, not a folder.") }
                continue
            }
            guard let par = DAVURL.parent(of: relTrim), DAVURL.trimmedSlash(par).precomposedStringWithCanonicalMapping == want else { continue }
            let seg = DAVURL.lastSegment(relTrim)
            guard !seg.isEmpty, !hidden(space, folder: path, name: seg) else { continue }
            let child = path + seg + (r.isCollection ? "/" : "")
            guard seen.insert(child).inserted else { continue }
            out.append(node(r, space: space, path: child, parentID: parentID))
        }
        return out
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        var unique = [String]()
        var set = Set<String>()
        for id in folderIDs where set.insert(id).inserted { unique.append(id) }
        guard !unique.isEmpty else { return [:] }
        let limit = max(1, listConcurrency)
        return try await withThrowingTaskGroup(of: (String, [DriveNode]).self) { g in
            var out = [String: [DriveNode]]()
            var next = 0
            func add() {
                let id = unique[next]
                next += 1
                g.addTask { (id, try await self.list(id)) }
            }
            while next < unique.count && next < limit { add() }
            while let (id, nodes) = try await g.next() {
                out[id] = nodes
                if next < unique.count { add() }
            }
            return out
        }
    }

    func display(_ path: String, space: DAVSpace = .files) -> String {
        if path == "/" { return space == .trash ? provider.deletedTitle : record.title.isEmpty ? provider.displayName : record.title }
        return DAVURL.lastSegment(path).precomposedStringWithCanonicalMapping
    }

    /// One item's current properties, or nil if it doesn't exist.
    func stat(_ space: DAVSpace, _ path: String, parentID: String?) async throws -> DriveNode? {
        let u = try await url(space, path)
        let r = try await client.send("PROPFIND", u, headers: Self.propfindHeaders("0"), body: .data(space == .trash ? Self.trashBody : listBody), retry: .safe)
        if r.status == 404 || r.status == 409 { return nil }
        guard r.status == 207 else { throw failure(r, "read “\(display(path, space: space))”") }
        let res = try DAVMultistatus.parse(r.data, requestURL: u)
        guard let first = res.first(where: { ($0.status ?? 200) == 200 }) else { return nil }
        return node(first, space: space, path: path, parentID: parentID)
    }

    /// Checks the sign-in and that the top folder is a folder (used when connecting).
    @discardableResult
    func validate() async throws -> DAVResource {
        let u = try await root(.files)
        let r = try await client.send("PROPFIND", u, headers: Self.propfindHeaders("0"), body: .data(listBody), retry: .safe)
        guard r.status == 207 else {
            if r.status == 404 { throw CloudError.notConfigured("There’s no WebDAV folder at \(u.host ?? "that address"). Check the address.") }
            throw failure(r, "open the folder")
        }
        let res = try DAVMultistatus.parse(r.data, requestURL: u)
        guard let first = res.first(where: { ($0.status ?? 200) == 200 }) else {
            throw CloudError.server("The server answered, but not with a folder Cirrus can open.")
        }
        guard first.isCollection else { throw CloudError.notConfigured("That address is a file, not a folder.") }
        return first
    }

    // MARK: Errors

    func failure(_ r: DAVClient.Response, _ what: String) -> CloudError {
        let msg = DAVErrorBody.message(r.data)
        let suffix = msg.map { ": " + $0 } ?? ""
        switch r.status {
        case 403: return .denied("The server didn’t allow Cirrus to \(what)\(suffix).")
        case 404, 410: return .notFound
        case 409: return .notFound      // a folder on the way is gone
        case 413: return .denied("The server doesn’t accept a file this large. Its administrator can raise the upload limit.")
        case 414: return .denied("The name or folder path is too long for the server.")
        case 300..<400:
            return .server("The server answered with a redirect (\(r.status)) instead of doing it. Check the server address in the account.")
        default: return .server("The server couldn’t \(what) (\(r.status)\(suffix)).")
        }
    }

    func nameTaken(_ name: String, in folder: String) -> CloudError {
        .denied("There’s already an item named “\(name.precomposedStringWithCanonicalMapping)” in “\(display(folder))”. Choose a different name.")
    }

    static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != ".." else { throw CloudError.denied("“\(name)” can’t be used as a name.") }
        guard !name.contains("/"), !name.contains("\0") else { throw CloudError.denied("Names on the server can’t contain “/”.") }
        guard name.utf8.count <= 250 else { throw CloudError.denied("“\(name.prefix(40))…” is too long a name for the server.") }
    }

    // MARK: Download

    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !node.isFolder else { throw CloudError.unsupported("“\(node.name)” is a folder; download the items in it instead.") }
        let (space, path) = try locate(node.id)
        let u = try await url(space, path)
        let r = try await client.download(u, to: destination, expected: node.size, progress: progress)
        guard r.ok else { throw failure(r, "download “\(node.name)”") }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? node.size
        progress(size, max(size, node.size))
        if let m = node.modified ?? r.header("Last-Modified").flatMap(DAVDates.http) {
            try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: destination.path)
        }
    }

    // MARK: Upload

    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        try Self.checkName(name)
        let (space, raw) = try locate(folderID)
        guard space == .files else { throw CloudError.unsupported("Items can’t be uploaded into \(provider.deletedTitle).") }
        let folder = Self.folderPath(raw)
        let path = folder + name
        let parentID = Self.id(.files, folder)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let dest = try await url(.files, path)
        var headers = ["Content-Type": UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"]
        if let m = modified { headers["X-OC-Mtime"] = String(Int64(m.timeIntervalSince1970.rounded(.down))) }
        var fromHeaders: (etag: String?, fileID: String?) = (nil, nil)
        if provider == .nextcloud && size > chunkThreshold {
            fromHeaders = try await chunkedUpload(file, size: size, to: dest, path: path, folder: folder, name: name, headers: headers, progress: progress)
        } else {
            // Never replace an existing item by accident: replacing goes through safeReplace (upload, then trash the old one).
            headers["If-None-Match"] = "*"
            let r = try await client.send("PUT", dest, headers: headers, body: .file(file), retry: .safe, timeout: 300, progress: progress, total: size)
            switch r.status {
            case 200, 201, 204: break
            case 412:
                // A retried PUT can find its own first attempt: that's not a clash if the sizes match.
                if r.retried, let n = try? await stat(.files, path, parentID: parentID), !n.isFolder, n.size == size { return n }
                throw nameTaken(name, in: folder)
            case 405: throw nameTaken(name, in: folder)
            default: throw failure(r, "upload “\(name)”")
            }
            fromHeaders = (r.header("OC-ETag") ?? r.header("ETag"), r.header("OC-FileId"))
        }
        progress(size, size)
        if let n = try? await stat(.files, path, parentID: parentID) { return n }
        var etag = fromHeaders.etag
        if let e = etag, e.count >= 2, e.hasPrefix("\""), e.hasSuffix("\"") { etag = String(e.dropFirst().dropLast()) }
        return DriveNode(id: Self.id(.files, path), docID: fromHeaders.fileID.flatMap(Self.numericFileID), zone: "dav", parentID: parentID,
                         name: name.precomposedStringWithCanonicalMapping, type: "FILE", size: size, modified: modified ?? Date(), created: Date(), etag: etag)
    }

    /// OC-FileId is "00000042ocabcdef" (id + instance); oc:fileid and the preview endpoint use the number.
    static func numericFileID(_ s: String) -> String? {
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard let n = Int64(digits) else { return nil }
        return String(n)
    }

    /// Nextcloud chunked upload v2: MKCOL uploads/<user>/<id>, PUT numbered chunks, MOVE .file into place.
    private func chunkedUpload(_ file: URL, size: Int64, to dest: URL, path: String, folder: String, name: String, headers: [String: String],
                               progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (etag: String?, fileID: String?) {
        // MOVE .file must not replace an existing item either.
        if try await stat(.files, path, parentID: nil) != nil { throw nameTaken(name, in: folder) }
        let uid = DAVURL.encodeSegment(try await userID())
        let dir = URL(string: base!.absoluteString + "/remote.php/dav/uploads/" + uid + "/cirrus-" + UUID().uuidString.lowercased() + "/")!
        let common = ["Destination": dest.absoluteString, "OC-Total-Length": String(size)]
        let mk = try await client.send("MKCOL", dir, headers: common, retry: .rateLimitOnly)
        guard mk.status == 201 || mk.status == 405 else { throw failure(mk, "start uploading “\(name)”") }
        var finished = false
        defer {
            if !finished {
                // Leave no half-finished upload on the server (best effort, outside the cancelled task).
                let c = client
                Task.detached { _ = try? await c.send("DELETE", dir, retry: .rateLimitOnly) }
            }
        }
        // At most 10,000 chunks.
        let chunk = min(max(chunkSize, (size + 9_999) / 10_000), 5 << 30)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var offset: Int64 = 0
        var index = 1
        while offset < size {
            try Task.checkCancellation()
            try fh.seek(toOffset: UInt64(offset))
            let data = try fh.read(upToCount: Int(min(chunk, size - offset))) ?? Data()
            guard !data.isEmpty else { throw CloudError.server("“\(name)” changed while it was being uploaded. Try again.") }
            let done = offset
            let part = DAVURL.join(dir, String(format: "/%05d", index))
            let r = try await client.send("PUT", part, headers: common.merging(["Content-Type": "application/octet-stream"]) { $1 },
                                          body: .data(data), retry: .safe, timeout: 300,
                                          progress: { sent, _ in progress(done + sent, size) }, total: Int64(data.count))
            guard r.ok else { throw failure(r, "upload “\(name)”") }
            offset += Int64(data.count)
            index += 1
            progress(offset, size)
        }
        var mh = headers.filter { $0.key == "X-OC-Mtime" }
        mh.merge(common) { $1 }
        mh["Overwrite"] = "F"
        let final = DAVURL.join(dir, "/.file")
        let r: DAVClient.Response
        do {
            // Putting a big file together can take the server a while.
            r = try await client.send("MOVE", final, headers: mh, retry: .rateLimitOnly, timeout: 30 * 60)
        } catch let e as CloudError {
            // The answer got lost: if the file is there at its full size, the upload worked.
            if let n = try? await stat(.files, path, parentID: nil), n.size == size { finished = true; return (n.etag, n.docID) }
            throw e
        }
        switch r.status {
        case 200, 201, 204:
            finished = true
            return (r.header("OC-ETag") ?? r.header("ETag"), r.header("OC-FileId"))
        case 412: throw nameTaken(name, in: folder)
        default: throw failure(r, "finish uploading “\(name)”")
        }
    }

    // MARK: Folders, rename, move

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        try Self.checkName(name)
        let (space, raw) = try locate(folderID)
        guard space == .files else { throw CloudError.unsupported("Folders can’t be made in \(provider.deletedTitle).") }
        let folder = Self.folderPath(raw)
        let path = folder + name + "/"
        let parentID = Self.id(.files, folder)
        let r = try await client.send("MKCOL", try await url(.files, path), retry: .rateLimitOnly)
        switch r.status {
        case 201: break
        case 405: throw nameTaken(name, in: folder)
        default: throw failure(r, "make the folder “\(name)”")
        }
        if let n = try? await stat(.files, path, parentID: parentID) { return n }
        return DriveNode(id: Self.id(.files, path), zone: "dav", parentID: parentID, name: name.precomposedStringWithCanonicalMapping,
                         type: "FOLDER", size: 0, modified: Date(), created: Date(), etag: nil)
    }

    /// MOVE without replacing anything at the destination. False when the name is taken there (412).
    func tryMove(_ from: String, to: String) async throws -> Bool {
        let src = try await url(.files, from)
        let dst = try await url(.files, to)
        let r = try await client.send("MOVE", src, headers: ["Destination": dst.absoluteString, "Overwrite": "F"], retry: .rateLimitOnly)
        switch r.status {
        case 200, 201, 204: return true
        case 412: return false
        default: throw failure(r, "move “\(display(from))”")
        }
    }

    func moveItem(_ from: String, to: String) async throws {
        guard try await tryMove(from, to: to) else { throw nameTaken(DAVURL.lastSegment(to), in: DAVURL.parent(of: to) ?? "/") }
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        try Self.checkName(name)
        let (space, path) = try locate(node.id)
        guard space == .files, path != "/" else { throw CloudError.unsupported("This item can’t be renamed.") }
        let folder = DAVURL.parent(of: path) ?? "/"
        let newPath = folder + name + (node.isFolder || path.hasSuffix("/") ? "/" : "")
        if newPath == path { return node }
        let parentID = Self.id(.files, folder)
        if name.compare(DAVURL.lastSegment(path), options: [.caseInsensitive]) == .orderedSame {
            // Only the case (or Unicode form) changes: case-insensitive servers see that as the same name, so go via a temporary one.
            let temp = folder + ".cirrus-rename-\(UUID().uuidString.prefix(8))-" + name + (newPath.hasSuffix("/") ? "/" : "")
            try await moveItem(path, to: temp)
            do { try await moveItem(temp, to: newPath) } catch {
                try? await moveItem(temp, to: path)
                throw error
            }
        } else {
            try await moveItem(path, to: newPath)
        }
        if let n = try? await stat(.files, newPath, parentID: parentID) { return n }
        var n = node
        n.id = Self.id(.files, newPath)
        n.name = name.precomposedStringWithCanonicalMapping
        n.parentID = parentID
        return n
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        let (space, raw) = try locate(folderID)
        guard space == .files else { throw CloudError.unsupported("Use Delete to put items in \(provider.deletedTitle).") }
        let dest = Self.folderPath(raw)
        for n in nodes {
            try Task.checkCancellation()
            let (s, path) = try locate(n.id)
            guard s == .files, path != "/" else { throw CloudError.unsupported("“\(n.name)” can’t be moved.") }
            if DAVURL.parent(of: path) == dest { continue }
            if path.hasSuffix("/") && dest.hasPrefix(path) { throw CloudError.denied("“\(n.name)” can’t be moved into itself.") }
            try await moveItem(path, to: dest + DAVURL.lastSegment(path) + (path.hasSuffix("/") ? "/" : ""))
        }
    }

    // MARK: Trash

    /// Whether Nextcloud's trash bin (the files_trashbin app) is there. Without it DELETE would erase for good,
    /// so Cirrus then uses the "Deleted by Cirrus" folder instead.
    func trashbinAvailable() async throws -> Bool {
        guard provider == .nextcloud else { return false }
        if let v = lock.withLock({ _trashbin }) { return v }
        let u = try await root(.trash)
        let r = try await client.send("PROPFIND", u, headers: Self.propfindHeaders("0"), body: .data(Self.propfindBody(dav: ["resourcetype"])), retry: .safe)
        let v: Bool
        switch r.status {
        case 207: v = true
        case 404, 405, 501: v = false
        default: throw failure(r, "open \(provider.deletedTitle)")
        }
        lock.withLock { _trashbin = v }
        return v
    }

    public func trash(_ nodes: [DriveNode]) async throws {
        guard !nodes.isEmpty else { return }
        for n in nodes {
            let (s, p) = try locate(n.id)
            guard s == .files, p != "/" else { throw CloudError.unsupported("“\(n.name)” is already in \(provider.deletedTitle).") }
        }
        guard try await trashbinAvailable() else { return try await folderTrash(nodes) }
        let filesRoot = try await root(.files)
        for n in nodes {
            try Task.checkCancellation()
            let path = try locate(n.id).path
            // Nextcloud moves deleted items to its trash bin.
            let r = try await client.send("DELETE", DAVURL.join(filesRoot, path), retry: .rateLimitOnly)
            if r.ok || r.status == 404 { continue }   // 404: already gone
            throw failure(r, "move “\(n.name)” to \(provider.deletedTitle)")
        }
    }

    public func listTrash() async throws -> [DriveNode] {
        if try await trashbinAvailable() { return try await list(Self.id(.trash, "/")) }
        return try await folderListTrash()
    }

    public func restore(_ nodes: [DriveNode]) async throws {
        let (bin, folder) = try splitTrash(nodes)
        if !bin.isEmpty {
            let uid = DAVURL.encodeSegment(try await userID())
            let restoreRoot = base!.absoluteString + "/remote.php/dav/trashbin/" + uid + "/restore/"
            for (n, path) in bin {
                try Task.checkCancellation()
                let dest = URL(string: restoreRoot + DAVURL.encodeSegment(DAVURL.lastSegment(path)))!
                let r = try await client.send("MOVE", try await url(.trash, path), headers: ["Destination": dest.absoluteString], retry: .rateLimitOnly)
                guard r.ok else { throw failure(r, "recover “\(n.name)”") }
            }
        }
        if !folder.isEmpty { try await folderRestore(folder) }
    }

    public func deleteForever(_ nodes: [DriveNode]) async throws {
        let (bin, folder) = try splitTrash(nodes)
        for (n, path) in bin {
            try Task.checkCancellation()
            let r = try await client.send("DELETE", try await url(.trash, path), retry: .rateLimitOnly)
            if r.ok || r.status == 404 { continue }
            throw failure(r, "delete “\(n.name)”")
        }
        if !folder.isEmpty { try await folderDeleteForever(folder) }
    }

    /// Items in Nextcloud's trash bin, and items in the "Deleted by Cirrus" folder. Anything else is refused:
    /// only deleted items can be recovered or erased.
    private func splitTrash(_ nodes: [DriveNode]) throws -> (bin: [(DriveNode, String)], folder: [(DriveNode, String)]) {
        var bin = [(DriveNode, String)](), folder = [(DriveNode, String)]()
        for n in nodes {
            let (s, p) = try locate(n.id)
            if s == .trash { bin.append((n, p)); continue }
            guard p.hasPrefix(Self.trashPath), p != Self.trashPath, DAVURL.lastSegment(p) != Self.manifestName else {
                throw CloudError.unsupported("“\(n.name)” isn’t in \(provider.deletedTitle). Delete it first.")
            }
            folder.append((n, p))
        }
        return (bin, folder)
    }

    // MARK: "Deleted by Cirrus" (servers without a trash)

    struct Manifest: Codable {
        struct Entry: Codable {
            var name: String       // the original name
            var from: String       // the original parent folder ("/Documents/")
            var deleted: Date
        }
        var version = 1
        var items: [String: Entry] = [:]   // name inside the trash folder → entry
    }

    func readManifest() async throws -> Manifest {
        let u = try await url(.files, Self.trashPath + Self.manifestName)
        let r = try await client.send("GET", u, headers: ["Accept": "application/json"], retry: .safe)
        if r.status == 404 { return Manifest() }
        guard r.ok else { throw failure(r, "read the list of deleted items") }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(Manifest.self, from: r.data)) ?? Manifest()
    }

    func writeManifest(_ m: Manifest) async {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(m), let u = try? await url(.files, Self.trashPath + Self.manifestName) else { return }
        do {
            let r = try await client.send("PUT", u, headers: ["Content-Type": "application/json"], body: .data(data), retry: .safe)
            if !r.ok { Log.status("dav trash manifest not saved (\(r.status))") }
        } catch {
            Log.status("dav trash manifest not saved")
        }
    }

    func ensureTrashFolder() async throws {
        let r = try await client.send("MKCOL", try await url(.files, Self.trashPath), retry: .rateLimitOnly)
        guard r.status == 201 || r.status == 405 else { throw failure(r, "make the “\(Self.trashFolderName)” folder") }
    }

    /// "Report.txt" → "Report 2.txt"; folders and names without an extension get " 2" at the end.
    static func numbered(_ name: String, _ n: Int, folder: Bool) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        if folder || ext.isEmpty || stem.isEmpty { return "\(name) \(n)" }
        return "\(stem) \(n).\(ext)"
    }

    func folderTrash(_ nodes: [DriveNode]) async throws {
        try await manifestLock.withLock {
            try await ensureTrashFolder()
            var manifest = try await readManifest()
            let current = try await list(Self.id(.files, Self.trashPath))
            var taken = Set(current.compactMap { n in (try? locate(n.id)).map { DAVURL.lastSegment($0.path).precomposedStringWithCanonicalMapping.lowercased() } })
            taken.formUnion(manifest.items.keys.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
            taken.insert(Self.manifestName.lowercased())
            var failure: Error?
            for n in nodes {
                do {
                    try Task.checkCancellation()
                    let path = try locate(n.id).path
                    let folder = path.hasSuffix("/")
                    let seg = DAVURL.lastSegment(path)
                    var candidate = seg
                    var k = 2
                    while true {
                        while taken.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
                            candidate = Self.numbered(seg, k, folder: folder)
                            k += 1
                        }
                        if try await tryMove(path, to: Self.trashPath + candidate + (folder ? "/" : "")) { break }
                        // Taken after all (someone else just deleted something): try the next name.
                        taken.insert(candidate.precomposedStringWithCanonicalMapping.lowercased())
                        guard k < 500 else { throw nameTaken(candidate, in: Self.trashPath) }
                    }
                    taken.insert(candidate.precomposedStringWithCanonicalMapping.lowercased())
                    manifest.items[candidate] = Manifest.Entry(name: seg, from: DAVURL.parent(of: path) ?? "/", deleted: Date())
                } catch CloudError.notFound {
                    continue   // already gone
                } catch {
                    failure = error
                    break
                }
            }
            await writeManifest(manifest)
            if let failure { throw failure }
        }
    }

    func folderListTrash() async throws -> [DriveNode] {
        let nodes: [DriveNode]
        do { nodes = try await list(Self.id(.files, Self.trashPath)) } catch CloudError.notFound { return [] }
        let m = (try? await readManifest()) ?? Manifest()
        return nodes.map { n in
            var n = n
            if let path = try? locate(n.id).path, let e = m.items[DAVURL.lastSegment(path)] { n.name = e.name.precomposedStringWithCanonicalMapping }
            return n
        }
    }

    func folderRestore(_ items: [(DriveNode, String)]) async throws {
        try await manifestLock.withLock {
            var manifest = try await readManifest()
            var failure: Error?
            for (_, path) in items {
                do {
                    try Task.checkCancellation()
                    let seg = DAVURL.lastSegment(path)
                    let isFolder = path.hasSuffix("/")
                    let entry = manifest.items[seg]
                    var dest = entry?.from ?? "/"
                    // The original folder is gone (or is itself deleted): put it back at the top.
                    if dest != "/" {
                        let there = dest.hasPrefix(Self.trashPath) ? nil : try await stat(.files, dest, parentID: nil)
                        if there == nil || there?.isFolder == false { dest = "/" }
                    }
                    let original = entry?.name ?? seg
                    var candidate = original
                    var k = 2
                    // Something new has the name meanwhile: keep both, like Finder ("Report 2.txt").
                    while try await !tryMove(path, to: dest + candidate + (isFolder ? "/" : "")) {
                        guard k < 500 else { throw nameTaken(original, in: dest) }
                        candidate = Self.numbered(original, k, folder: isFolder)
                        k += 1
                    }
                    manifest.items[seg] = nil
                } catch CloudError.notFound {
                    manifest.items[DAVURL.lastSegment(path)] = nil
                    failure = failure ?? CloudError.notFound
                } catch {
                    failure = error
                    break
                }
            }
            await writeManifest(manifest)
            if let failure { throw failure }
        }
    }

    func folderDeleteForever(_ items: [(DriveNode, String)]) async throws {
        try await manifestLock.withLock {
            var manifest = try await readManifest()
            var failure: Error?
            for (n, path) in items {
                do {
                    try Task.checkCancellation()
                    let r = try await client.send("DELETE", try await url(.files, path), retry: .rateLimitOnly)
                    guard r.ok || r.status == 404 else { throw self.failure(r, "delete “\(n.name)”") }
                    manifest.items[DAVURL.lastSegment(path)] = nil
                } catch {
                    failure = error
                    break
                }
            }
            await writeManifest(manifest)
            if let failure { throw failure }
        }
    }

    // MARK: Quota and thumbnails

    public func quota() async throws -> StorageUsage? {
        let u = try await root(.files)
        let res = try await propfind(u, depth: "0", body: Self.quotaBody, what: "read the storage use")
        guard let r = res.first(where: { ($0.status ?? 200) == 200 }) else { return nil }
        func num(_ s: String?) -> Int64? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return Int64(t) ?? Double(t).map { Int64($0) }
        }
        guard let used = num(r.dav("quota-used-bytes")), let avail = num(r.dav("quota-available-bytes")), used >= 0, avail >= 0 else { return nil }
        return StorageUsage(total: used + avail, used: used, categories: [])
    }

    public func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data? {
        guard provider == .nextcloud, !node.isFolder, let id = node.docID, let base else { return nil }
        if lock.withLock({ previews[node.id] }) == false { return nil }
        let px = max(16, min(maxPixel, 2048))
        guard var c = URLComponents(string: base.absoluteString + "/index.php/core/preview") else { return nil }
        c.queryItems = [URLQueryItem(name: "fileId", value: id), URLQueryItem(name: "x", value: String(px)), URLQueryItem(name: "y", value: String(px)),
                        URLQueryItem(name: "a", value: "1"), URLQueryItem(name: "forceIcon", value: "0")]
        guard let u = c.url else { return nil }
        let r = try await client.send("GET", u, headers: ["Accept": "image/*"], retry: .safe)
        guard r.status == 200, !r.data.isEmpty else { return nil }
        if let type = r.header("Content-Type")?.lowercased(), !type.hasPrefix("image/") { return nil }
        return r.data
    }
}

extension DAVURL {
    /// "/a/b" → "/a/b/" (cleaned).
    static func folderPathClean(_ p: String) -> String {
        let c = clean(p)
        return c.hasSuffix("/") ? c : c + "/"
    }
}
