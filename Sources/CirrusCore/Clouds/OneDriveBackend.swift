import Foundation

/// Where a DriveNode id points. Most items live in the user's own drive and use Graph's driveItem id as is
/// ("root" is the top folder). Folders other people shared, once added to "My files", appear as shortcuts
/// (a driveItem with a `remoteItem` facet): browsing them lists the owner's drive, while renaming, moving or
/// trashing the shortcut must only touch the shortcut — never the owner's folder.
enum OneDriveRef: Equatable {
    /// An item in the signed-in user's drive.
    case own(String)
    /// An item inside someone else's drive (reached through a shortcut).
    case inDrive(drive: String, item: String)
    /// A shortcut in the user's drive (`local`) to an item in another drive.
    case shortcut(local: String, drive: String, item: String)

    init(_ id: String) {
        let p = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if p.count == 3, p[0] == "drive" { self = .inDrive(drive: p[1], item: p[2]) }
        else if p.count == 4, p[0] == "shortcut" { self = .shortcut(local: p[1], drive: p[2], item: p[3]) }
        else { self = .own(id) }
    }

    static func inDriveID(_ drive: String, _ item: String) -> String { "drive|\(drive)|\(item)" }
    static func shortcutID(_ local: String, _ drive: String, _ item: String) -> String { "shortcut|\(local)|\(drive)|\(item)" }

    static let idAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!")
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: idAllowed) ?? s }

    /// The item whose contents this id stands for (a shortcut's target).
    var contentPath: String {
        switch self {
        case .own(let id): return id == "root" ? "/me/drive/root" : "/me/drive/items/" + Self.enc(id)
        case .inDrive(let d, let i), .shortcut(_, let d, let i): return "/drives/\(Self.enc(d))/items/\(Self.enc(i))"
        }
    }

    /// The item itself (for a shortcut: the shortcut in the user's drive).
    var selfPath: String {
        if case .shortcut(let local, _, _) = self { return "/me/drive/items/" + Self.enc(local) }
        return contentPath
    }

    /// The drive that items inside this folder live in (nil: the user's own).
    var contentDrive: String? {
        switch self {
        case .own: return nil
        case .inDrive(let d, _), .shortcut(_, let d, _): return d
        }
    }

    /// The drive this item itself lives in (nil: the user's own; shortcuts live in the user's drive).
    var selfDrive: String? {
        if case .inDrive(let d, _) = self { return d }
        return nil
    }
}

/// OneDrive as Cirrus browses it. See `OneDrive` for sign-in and app registration.
public final class OneDriveBackend: CloudDriveBackend, @unchecked Sendable {
    public let provider = CloudProvider.onedrive
    public let rootID = "root"
    /// OneDrive's recycle bin isn't available through Microsoft Graph for personal accounts, so Cirrus doesn't list it.
    public let canListTrash = false
    public let accountID: String

    let http: OneDriveHTTP
    let tokens: OneDriveTokens
    private let lock = NSLock()
    private var realRoot: String?

    /// Files up to this size go up in one request; larger ones through an upload session.
    public var simpleUploadLimit: Int64 = 4 * 1024 * 1024
    /// Upload-session fragment size, rounded down to a multiple of 320 KiB as Microsoft requires.
    public var chunkSize = 16 * 327_680
    /// Items per listing page.
    public var pageSize = 200
    /// Folders listed at once by `listMany`, and items changed at once by `move` / `trash`.
    public var concurrency = 6

    static let fragmentUnit = 327_680
    static let maxFileSize: Int64 = 250 * 1_000_000_000
    static let select = "id,name,size,folder,file,package,remoteItem,root,parentReference,fileSystemInfo,createdDateTime,lastModifiedDateTime,eTag,cTag,shared"

    init(accountID: String, clientID: String, refreshToken: String, transport: [AnyClass]?, initial: OneDriveTokenSet? = nil) {
        self.accountID = accountID
        let session = OneDriveHTTP.makeSession(transport)
        tokens = OneDriveTokens(clientID: clientID, refreshToken: refreshToken, http: session, initial: initial)
        http = OneDriveHTTP(session: session, tokens: tokens)
    }

    // A URLSession keeps itself (and its delegate) alive until it is invalidated.
    deinit { http.session.finishTasksAndInvalidate() }

    /// Called with every new refresh token Microsoft hands out (they rotate). Save it, e.g. with
    /// `CloudStore.setSecret(record.id, backend.secret)`; the old one may stop working.
    public var onNewRefreshToken: (@Sendable (String) -> Void)? {
        get { tokens.onNewRefreshToken }
        set { tokens.onNewRefreshToken = newValue }
    }

    /// What to keep in the Keychain for this account right now (the latest refresh token).
    public var secret: CloudSecret { CloudSecret(refreshToken: tokens.currentRefreshToken, clientID: tokens.clientID) }

    /// Back-off base in seconds (tests make it tiny).
    public var retryBase: Double {
        get { http.retryBase }
        set { http.retryBase = newValue }
    }

    // MARK: Nodes

    static let invalidNameCharacters = CharacterSet(charactersIn: "\"*:<>?/\\|").union(.controlCharacters)

    /// OneDrive's naming rules, checked before anything is sent (a "/" would otherwise address a subfolder).
    static func checkName(_ raw: String) throws -> String {
        let name = raw.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != ".", name != ".." else { throw CloudError.denied("OneDrive needs a name for the item.") }
        if name.rangeOfCharacter(from: invalidNameCharacters) != nil {
            throw CloudError.denied("OneDrive doesn’t allow these characters in names: \" * : < > ? / \\ |. Rename “\(name)” and try again.")
        }
        return name
    }

    static let nameAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// One path segment for Graph's `items/{parent}:/{name}:` addressing: everything but unreserved ASCII is
    /// percent-encoded (UTF-8), so #, %, ?, +, spaces and non-Latin names reach OneDrive intact.
    static func encodeName(_ name: String) -> String { name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? name }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// "root" for the real root's id (Graph reports the top folder by its real id).
    func normalize(_ id: String) -> String {
        lock.withLock { id == realRoot } ? rootID : id
    }

    func realRootID() async throws -> String {
        if let r = lock.withLock({ realRoot }) { return r }
        let j = try await http.json("GET", "/me/drive/root", query: [("$select", "id")], retry: .safe)
        guard let id = j["id"].string, !id.isEmpty else { throw CloudError.server("OneDrive didn’t say which folder is the top of your drive.") }
        lock.withLock { realRoot = id }
        return id
    }

    /// A driveItem as a DriveNode inside `folderID`.
    func node(_ j: JSON, in folderID: String) -> DriveNode? {
        guard let raw = j["id"].string, !raw.isEmpty, let rawName = j["name"].string else { return nil }
        if !j["root"].isNull {
            lock.withLock { if realRoot == nil { realRoot = raw } }
        }
        let remote = j["remoteItem"]
        var id = OneDriveRef(folderID).contentDrive.map { OneDriveRef.inDriveID($0, raw) } ?? raw
        var isFolder = !j["folder"].isNull || !j["root"].isNull
        var childCount = j["folder"]["childCount"].int
        if !remote.isNull, OneDriveRef(folderID).contentDrive == nil,
           let rid = remote["id"].string, let rdrive = remote["parentReference"]["driveId"].string {
            id = OneDriveRef.shortcutID(raw, rdrive, rid)
            isFolder = !remote["folder"].isNull || isFolder
            childCount = remote["folder"]["childCount"].int ?? childCount
        }
        // Packages (OneNote notebooks…) are shown as files: OneDrive can't list or zip their insides.
        let fs = j["fileSystemInfo"]
        var n = DriveNode(id: id, docID: nil, zone: "onedrive", parentID: normalize(folderID),
                          name: rawName.precomposedStringWithCanonicalMapping, type: isFolder ? "FOLDER" : "FILE",
                          size: isFolder ? 0 : (j["size"].int64 ?? remote["size"].int64 ?? 0),
                          modified: fs["lastModifiedDateTime"].date ?? j["lastModifiedDateTime"].date,
                          created: fs["createdDateTime"].date ?? j["createdDateTime"].date,
                          etag: j["eTag"].string ?? j["cTag"].string, childCount: isFolder ? childCount : nil)
        n.isShared = !j["shared"].isNull || !remote.isNull
        return n
    }

    // MARK: Listing

    public func list(_ folderID: String) async throws -> [DriveNode] {
        try await OneDriveHTTP.guarded {
            var out = [DriveNode]()
            var url = OneDriveHTTP.graph + OneDriveRef(folderID).contentPath + "/children"
            var query: [(String, String)] = [("$top", String(pageSize)), ("$select", Self.select)]
            while true {
                try Task.checkCancellation()
                let j = try await http.json("GET", url, query: query, retry: .safe)
                // A page without its item list would look like an empty folder ("everything deleted"): stop instead.
                guard case .array(let items) = j["value"] else {
                    throw CloudError.server("OneDrive didn’t list a folder completely. Nothing was changed; try again.")
                }
                out += items.compactMap { node($0, in: folderID) }
                guard let next = j["@odata.nextLink"].string else { return out }
                guard OneDriveHTTP.isGraph(URL(string: next)) else {
                    throw CloudError.server("OneDrive’s next page pointed somewhere other than Microsoft Graph, so Cirrus stopped listing.")
                }
                url = next
                query = []   // the next link already carries the query
            }
        }
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        var unique = [String]()
        for id in folderIDs where !unique.contains(id) { unique.append(id) }
        guard !unique.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(of: (String, [DriveNode]).self) { group in
            var out = [String: [DriveNode]]()
            var pending = unique.makeIterator()
            for _ in 0..<max(1, min(concurrency, unique.count)) {
                guard let id = pending.next() else { break }
                group.addTask { (id, try await self.list(id)) }
            }
            // Any failed folder throws (and cancels the rest): a missing folder must never look empty.
            while let (id, nodes) = try await group.next() {
                out[id] = nodes
                if let more = pending.next() { group.addTask { (more, try await self.list(more)) } }
            }
            return out
        }
    }

    // MARK: Download

    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !node.isFolder else { throw CloudError.unsupported("“\(node.name)” is a folder; Cirrus downloads the files inside it one by one.") }
        let ref = OneDriveRef(node.id)
        try await OneDriveHTTP.guarded {
            var linkFailures = 0
            while true {
                try Task.checkCancellation()
                let expected = node.size
                let report: @Sendable (Int64, Int64) -> Void = { got, total in progress(got, total > 0 ? total : expected) }
                // Graph answers 302 with a short-lived pre-authenticated URL on another host.
                let first = try await http.send(try http.request("GET", OneDriveHTTP.graph + ref.contentPath + "/content"),
                                                retry: .safe, toFile: true, received: report)
                var final = first
                if [301, 302, 303, 307, 308].contains(first.status) {
                    first.discard()
                    guard let loc = first.header("Location"), let u = URL(string: loc), u.scheme?.lowercased() == "https" else {
                        throw CloudError.server("OneDrive didn’t give a usable download address for “\(node.name)”.")
                    }
                    var req = URLRequest(url: u)
                    req.setValue("*/*", forHTTPHeaderField: "Accept")
                    // No Authorization header: the URL itself carries the permission.
                    final = try await http.send(req, auth: false, retry: .safe, toFile: true, received: report)
                    if [401, 403, 410].contains(final.status), linkFailures < 2 {
                        // The link expired (they last minutes): ask Graph for a fresh one.
                        final.discard()
                        linkFailures += 1
                        continue
                    }
                }
                guard (200..<300).contains(final.status), let file = final.file else {
                    final.discard()
                    if final.http.url.map({ !OneDriveHTTP.isGraph($0) }) == true, [401, 403, 410].contains(final.status) {
                        throw CloudError.server("OneDrive’s download link for “\(node.name)” stopped working. Try again.")
                    }
                    if final.status != 401, final.status != 404, (400..<500).contains(final.status), try await isPackage(ref) {
                        throw CloudError.unsupported("“\(node.name)” is a OneNote notebook or another package that OneDrive can’t download as a file. Open it on onedrive.com.")
                    }
                    throw OneDriveHTTP.error(final, name: node.name)
                }
                let fm = FileManager.default
                try? fm.removeItem(at: destination)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: destination)
                try? fm.removeItem(at: file.deletingLastPathComponent())
                let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                progress(size, max(size, expected))
                if let m = node.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: destination.path) }
                return
            }
        }
    }

    func isPackage(_ ref: OneDriveRef) async throws -> Bool {
        guard let j = try? await http.json("GET", ref.contentPath, query: [("$select", "id,package")], retry: .safe) else { return false }
        return !j["package"].isNull
    }

    // MARK: Changes

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        let name = try Self.checkName(name)
        return try await OneDriveHTTP.guarded {
            // conflictBehavior fail: Cirrus picks free names itself, so a clash is an error, never a silent rename.
            let body: JSON = ["name": .string(name), "folder": [:], "@microsoft.graph.conflictBehavior": "fail"]
            let j = try await http.json("POST", OneDriveRef(folderID).contentPath + "/children", body: body, retry: .unsafe, name: name)
            guard let n = node(j, in: folderID) else { throw CloudError.server("OneDrive didn’t confirm the new folder “\(name)”.") }
            return n
        }
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        let name = try Self.checkName(name)
        return try await OneDriveHTTP.guarded {
            let j = try await http.json("PATCH", OneDriveRef(node.id).selfPath, query: [("@microsoft.graph.conflictBehavior", "fail")],
                                        body: ["name": .string(name)], retry: .safe, name: name)
            var n = node
            n.name = (j["name"].string ?? name).precomposedStringWithCanonicalMapping
            n.etag = j["eTag"].string ?? n.etag
            n.modified = j["fileSystemInfo"]["lastModifiedDateTime"].date ?? n.modified
            return n
        }
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        guard !nodes.isEmpty else { return }
        let target = OneDriveRef(folderID)
        for n in nodes where OneDriveRef(n.id).selfDrive != target.contentDrive {
            throw CloudError.unsupported("OneDrive can’t move “\(n.name)” between your files and a folder someone shared with you. Copy it instead.")
        }
        try await OneDriveHTTP.guarded {
            let parent: JSON
            switch target {
            case .own(let id): parent = ["id": .string(id == rootID ? try await realRootID() : id)]
            case .inDrive(let d, let i), .shortcut(_, let d, let i): parent = ["driveId": .string(d), "id": .string(i)]
            }
            let body: JSON = ["parentReference": parent]
            try await forEach(nodes) { n in
                _ = try await self.http.json("PATCH", OneDriveRef(n.id).selfPath, query: [("@microsoft.graph.conflictBehavior", "fail")],
                                             body: body, retry: .safe, name: n.name)
            }
        }
    }

    /// OneDrive's DELETE moves items to its recycle bin (kept 30 days personal, 93 days work/school).
    public func trash(_ nodes: [DriveNode]) async throws {
        try await OneDriveHTTP.guarded {
            try await forEach(nodes) { n in
                let r = try await self.http.send(try self.http.request("DELETE", OneDriveHTTP.graph + OneDriveRef(n.id).selfPath), retry: .safe)
                // 404: already gone (or an earlier attempt whose answer was lost got there first).
                guard (200..<300).contains(r.status) || r.status == 404 else { throw OneDriveHTTP.error(r, name: n.name) }
            }
        }
    }

    public func listTrash() async throws -> [DriveNode] { [] }

    static let recycleBinMessage = "Cirrus can’t open OneDrive’s Recycle Bin. To restore or permanently delete items, use the Recycle Bin on onedrive.com."

    public func restore(_ nodes: [DriveNode]) async throws { throw CloudError.unsupported(Self.recycleBinMessage) }

    public func deleteForever(_ nodes: [DriveNode]) async throws { throw CloudError.unsupported(Self.recycleBinMessage) }

    /// Runs `op` for each node, a few at a time; the first failure is thrown once the others finish.
    func forEach(_ nodes: [DriveNode], _ op: @escaping @Sendable (DriveNode) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = nodes.makeIterator()
            for _ in 0..<max(1, min(concurrency, nodes.count)) {
                guard let n = pending.next() else { break }
                group.addTask { try await op(n) }
            }
            while try await group.next() != nil {
                if let n = pending.next() { group.addTask { try await op(n) } }
            }
        }
    }

    // MARK: Extras

    public func quota() async throws -> StorageUsage? {
        try await OneDriveHTTP.guarded {
            let q = try await http.json("GET", "/me/drive", query: [("$select", "quota")], retry: .safe)["quota"]
            guard let total = q["total"].int64, total > 0 else { return nil }
            let used = q["used"].int64 ?? max(0, total - (q["remaining"].int64 ?? total))
            var cats = [StorageUsage.Category]()
            if let deleted = q["deleted"].int64, deleted > 0 {
                cats.append(StorageUsage.Category(key: "files", label: "Files", bytes: max(0, used - deleted), color: "0078D4"))
                cats.append(StorageUsage.Category(key: "deleted", label: "Recycle Bin", bytes: deleted, color: "8A8886"))
            } else {
                cats.append(StorageUsage.Category(key: "files", label: "Files", bytes: used, color: "0078D4"))
            }
            return StorageUsage(total: total, used: used, categories: cats)
        }
    }

    public func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data? {
        guard !node.isFolder else { return nil }
        let px = max(16, min(maxPixel, 1600))
        let named = px <= 96 ? "small" : px <= 176 ? "medium" : "large"
        let base = OneDriveHTTP.graph + OneDriveRef(node.id).contentPath + "/thumbnails/0/"
        return try await OneDriveHTTP.guarded {
            // c{w}x{h}: fits in the box, aspect ratio kept. Accounts without custom sizes get the nearest named one.
            for size in ["c\(px)x\(px)", named] {
                var r = try await http.send(try http.request("GET", base + size + "/content"), retry: .safe)
                if [301, 302, 303, 307, 308].contains(r.status) {
                    guard let loc = r.header("Location"), let u = URL(string: loc) else { return nil }
                    r = try await http.send(URLRequest(url: u), auth: false, retry: .safe)
                }
                switch r.status {
                case 200..<300: return r.data.isEmpty ? nil : r.data
                case 404: return nil
                case 400, 406, 415: continue   // this size (or a thumbnail for this type) isn't offered
                default: throw OneDriveHTTP.error(r, name: node.name)
                }
            }
            return nil
        }
    }
}
