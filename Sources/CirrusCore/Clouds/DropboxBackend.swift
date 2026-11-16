import Foundation

/// Dropbox as Cirrus browses it. See `Dropbox` for sign-in and the App Console setup.
///
/// Items are addressed by Dropbox's file ids ("id:…"), which survive renames and moves; `rootID` ("root") is the
/// top of the Dropbox (path "" to the API). `DriveNode.docID` carries the item's `path_display` as listed (for
/// display only: paths change when a folder above is renamed). Changes that need a destination path (new
/// folders, uploads, renames, moves) look the folder's current path up first, so a folder renamed or deleted
/// elsewhere is never recreated under its old name. Every change goes through a one-at-a-time gate, as Dropbox
/// recommends, and is retried when Dropbox reports write contention.
public final class DropboxBackend: CloudDriveBackend, CloudTokenRotating, @unchecked Sendable {
    public let provider = CloudProvider.dropbox
    public let rootID = "root"
    /// Dropbox's API can't list deleted files account-wide (only per folder, without dates or ids), so Cirrus
    /// leaves Deleted files to dropbox.com.
    public let canListTrash = false
    public let accountID: String

    let http: DropboxHTTP
    let tokens: DropboxTokens
    let writes: DropboxGate

    /// Files up to this size go up in one request (capped at Dropbox's 150 MB); larger ones through an upload
    /// session that resumes after interruptions.
    public var simpleUploadLimit: Int64 = 8 * 1024 * 1024
    /// Upload-session chunk size (Dropbox recommends multiples of 4 MiB; at most 150 MB).
    public var chunkSize = 16 * 1024 * 1024
    /// Entries per listing page (Dropbox treats it as approximate; 1…2000).
    public var pageSize = 1000
    /// Folders listed at once by `listMany`.
    public var concurrency = 6
    /// Changes (new folders, upload commits, renames, moves, deletions) sent at once. Dropbox locks the namespace
    /// for each one, so more than one mostly produces `too_many_write_operations`.
    public var writeConcurrency: Int {
        get { writes.limit }
        set { writes.limit = newValue }
    }

    static let maxSimpleUpload: Int64 = 150 * 1024 * 1024
    /// Dropbox's limit for a file uploaded through the API (upload sessions).
    static let maxFileSize: Int64 = 350_000_000_000

    init(accountID: String, appKey: String, refreshToken: String, pathRoot: String?, transport: [AnyClass]?, initial: DropboxTokenSet? = nil) {
        self.accountID = accountID
        let session = DropboxHTTP.makeSession(transport)
        tokens = DropboxTokens(appKey: appKey, refreshToken: refreshToken, http: session, initial: initial)
        http = DropboxHTTP(session: session, tokens: tokens, pathRoot: pathRoot)
        writes = DropboxGate(limit: 1)
    }

    // A URLSession keeps itself (and its delegate) alive until it is invalidated.
    deinit { http.session.finishTasksAndInvalidate() }

    /// Called if Dropbox ever hands out a new refresh token (it normally keeps the first one). Save it, e.g. with
    /// `CloudStore.setSecret(record.id, backend.secret)`.
    public var onNewRefreshToken: (@Sendable (String) -> Void)? {
        get { tokens.onNewRefreshToken }
        set { tokens.onNewRefreshToken = newValue }
    }

    /// What to keep in the Keychain for this account right now.
    public var secret: CloudSecret { CloudSecret(refreshToken: tokens.currentRefreshToken, clientID: tokens.appKey) }

    /// Back-off base in seconds (tests make it tiny).
    public var retryBase: Double {
        get { http.retryBase }
        set { http.retryBase = newValue }
    }

    // MARK: Nodes

    /// Dropbox's path for an id ("" is the top of the Dropbox).
    func apiPath(_ id: String) -> String { id == rootID || id.isEmpty ? "" : id }

    /// Names Dropbox can't take, caught before anything is sent (a "/" would address a subfolder).
    static func checkName(_ raw: String) throws -> String {
        let name = raw.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != ".", name != ".." else { throw CloudError.denied("Dropbox needs a name for the item.") }
        if name.contains("/") || name.rangeOfCharacter(from: .controlCharacters) != nil {
            throw CloudError.denied("Dropbox doesn’t allow “/” or control characters in names. Rename “\(name)” and try again.")
        }
        return name
    }

    /// Dropbox timestamps: UTC, whole seconds ("2026-11-16T09:30:00Z").
    static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: floor(d.timeIntervalSince1970)))
    }

    /// The folder part of a Dropbox path ("" for items at the top).
    static func parentPath(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// A file or folder entry as a DriveNode inside `folderID`. `tag` for answers that are a FileMetadata or
    /// FolderMetadata struct (no ".tag"); deleted entries are skipped.
    func node(_ j: JSON, in folderID: String, tag: String? = nil) -> DriveNode? {
        let kind = j[".tag"].string ?? tag
        guard kind == "file" || kind == "folder", let id = j["id"].string, !id.isEmpty, let rawName = j["name"].string else { return nil }
        let isFolder = kind == "folder"
        var n = DriveNode(id: id, docID: j["path_display"].string, zone: "dropbox", parentID: folderID.isEmpty ? rootID : folderID,
                          name: rawName.precomposedStringWithCanonicalMapping, type: isFolder ? "FOLDER" : "FILE",
                          size: isFolder ? 0 : (j["size"].int64 ?? 0),
                          modified: isFolder ? nil : (j["client_modified"].date ?? j["server_modified"].date),
                          created: nil, etag: isFolder ? nil : j["rev"].string, childCount: nil)
        n.isShared = isFolder && (!j["sharing_info"]["shared_folder_id"].isNull || !j["shared_folder_id"].isNull)
        return n
    }

    /// `files/get_metadata`; nil when there's nothing at `path` (deleted items count as nothing).
    func metadata(_ path: String) async throws -> JSON? {
        let r = try await http.send(http.rpcRequest("files/get_metadata", ["path": .string(path), "include_deleted": false]), retry: .safe)
        if r.status == 409, r.summary.contains("not_found") { return nil }
        guard (200..<300).contains(r.status) else { throw DropboxHTTP.error(r) }
        return r.json
    }

    /// A folder's current path, looked up by id (paths change when folders above are renamed or moved).
    func folderPath(_ id: String) async throws -> (display: String, lower: String) {
        if id == rootID || id.isEmpty { return ("", "") }
        guard let m = try await metadata(id) else { throw CloudError.notFound }
        guard m[".tag"].string == "folder" else { throw CloudError.denied("That item isn’t a folder on Dropbox.") }
        guard let display = m["path_display"].string, let lower = m["path_lower"].string else {
            throw CloudError.server("Dropbox didn’t say where that folder is. Try again.")
        }
        return (display, lower)
    }

    // MARK: Listing

    public func list(_ folderID: String) async throws -> [DriveNode] {
        let folder = folderID.isEmpty ? rootID : folderID
        return try await DropboxHTTP.guarded {
            var restarts = 0
            listing: while true {
                var out = [DriveNode]()
                var j = try await http.rpc("files/list_folder", ["path": .string(apiPath(folder)), "recursive": false, "include_deleted": false,
                                                                 "include_mounted_folders": true, "include_non_downloadable_files": true,
                                                                 "limit": .int(max(1, min(pageSize, 2000)))], retry: .safe)
                while true {
                    try Task.checkCancellation()
                    // A page without its entries would look like an empty folder ("everything deleted"): stop instead.
                    guard case .array(let entries) = j["entries"] else {
                        throw CloudError.server("Dropbox didn’t list a folder completely. Nothing was changed; try again.")
                    }
                    out += entries.compactMap { node($0, in: folder) }
                    guard j["has_more"].bool == true else { return out }
                    guard let cursor = j["cursor"].string, !cursor.isEmpty else {
                        throw CloudError.server("Dropbox didn’t list a folder completely. Nothing was changed; try again.")
                    }
                    let r = try await http.send(http.rpcRequest("files/list_folder/continue", ["cursor": .string(cursor)]), retry: .safe)
                    if r.status == 409, r.summary.hasPrefix("reset"), restarts < 2 {
                        // Dropbox invalidated the cursor: list the folder again from the start.
                        restarts += 1
                        continue listing
                    }
                    guard (200..<300).contains(r.status) else { throw DropboxHTTP.error(r) }
                    j = r.json
                }
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
        try await DropboxHTTP.guarded {
            let expected = node.size
            let report: @Sendable (Int64, Int64) -> Void = { got, total in progress(got, total > 0 ? total : expected) }
            let r = try await http.send(http.contentRequest("files/download", ["path": .string(apiPath(node.id))], upload: false),
                                        retry: .safe, toFile: true, received: report)
            guard (200..<300).contains(r.status), let file = r.file else {
                r.discard()
                throw DropboxHTTP.error(r, name: node.name)
            }
            let fm = FileManager.default
            let meta = r.header("Dropbox-API-Result").flatMap { try? JSON(data: Data($0.utf8)) } ?? .null
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let want = meta["size"].int64, want != size {
                r.discard()
                throw CloudError.server("The download of “\(node.name)” from Dropbox was incomplete. Try again.")
            }
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: destination)
            try? fm.removeItem(at: file.deletingLastPathComponent())
            progress(size, max(size, expected))
            if let m = meta["client_modified"].date ?? node.modified {
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: destination.path)
            }
        }
    }

    // MARK: Changes

    /// One change through the write gate. Dropbox's "busy" answers are retried inside `send`; after a lost answer
    /// (or a 5xx, where the change may or may not have happened) it is sent again, and if Dropbox then refuses
    /// it (409), `landed` decides whether the first attempt did it after all.
    func write(_ route: String, _ arg: JSON, name: String?, landed: (() async throws -> JSON?)? = nil) async throws -> JSON {
        var failures = 0
        var ambiguous = false
        while true {
            try Task.checkCancellation()
            let r: DropboxResponse
            do {
                r = try await writes.run { try await http.send(http.rpcRequest(route, arg), retry: .unsafe) }
            } catch let e as URLError where e.code != .cancelled && DropboxHTTP.retryable(e, ambiguousOK: true) && failures < http.maxRetries {
                failures += 1
                ambiguous = true
                try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                continue
            }
            if (200..<300).contains(r.status) { return r.json }
            if (500...599).contains(r.status), failures < http.maxRetries {
                failures += 1
                ambiguous = true
                try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                continue
            }
            if ambiguous, r.status == 409, let landed, let j = try await landed() { return j }
            throw DropboxHTTP.error(r, name: name)
        }
    }

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        let name = try Self.checkName(name)
        return try await DropboxHTTP.guarded {
            let parent = try await folderPath(folderID)
            let path = parent.display + "/" + name
            // autorename false: Cirrus picks free names itself, so a clash is an error, never a silent rename.
            let j = try await write("files/create_folder_v2", ["path": .string(path), "autorename": false], name: name) {
                guard let m = try await self.metadata(path), m[".tag"].string == "folder" else { return nil }
                return ["metadata": m]
            }
            guard let n = node(j["metadata"], in: folderID, tag: "folder") else {
                throw CloudError.server("Dropbox didn’t confirm the new folder “\(name)”.")
            }
            return n
        }
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        let name = try Self.checkName(name)
        guard node.id != rootID else { throw CloudError.denied("The top of your Dropbox can’t be renamed.") }
        return try await DropboxHTTP.guarded {
            guard let current = try await metadata(node.id), let path = current["path_display"].string else { throw CloudError.notFound }
            let parentID = node.parentID ?? rootID
            if current["name"].string == name, let same = self.node(current, in: parentID) { return same }
            let to = Self.parentPath(path) + "/" + name
            let j = try await write("files/move_v2", ["from_path": .string(node.id), "to_path": .string(to), "autorename": false,
                                                      "allow_ownership_transfer": false], name: name) {
                guard let m = try await self.metadata(node.id), m["name"].string == name,
                      Self.parentPath(m["path_lower"].string ?? "") == Self.parentPath(current["path_lower"].string ?? "") else { return nil }
                return ["metadata": m]
            }
            guard let n = self.node(j["metadata"], in: parentID) else { throw CloudError.server("Dropbox didn’t confirm renaming “\(name)”.") }
            return n
        }
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        guard !nodes.isEmpty else { return }
        try await DropboxHTTP.guarded {
            let target = try await folderPath(folderID)
            // One at a time: Dropbox does one change per namespace at a time anyway.
            for n in nodes {
                try Task.checkCancellation()
                guard n.id != rootID else { throw CloudError.denied("The top of your Dropbox can’t be moved.") }
                // The item's current name (it may have been renamed elsewhere since it was listed).
                guard let m = try await metadata(n.id), let name = m["name"].string, let lower = m["path_lower"].string else { throw CloudError.notFound }
                if Self.parentPath(lower) == target.lower { continue }   // already there
                _ = try await write("files/move_v2", ["from_path": .string(n.id), "to_path": .string(target.display + "/" + name),
                                                      "autorename": false, "allow_ownership_transfer": false], name: name) {
                    guard let now = try await self.metadata(n.id), Self.parentPath(now["path_lower"].string ?? "") == target.lower else { return nil }
                    return ["metadata": now]
                }
            }
        }
    }

    /// Dropbox keeps deleted files and folders restorable (30 days or more, depending on the plan) under
    /// Deleted files on dropbox.com. Never `permanently_delete`.
    public func trash(_ nodes: [DriveNode]) async throws {
        try await DropboxHTTP.guarded {
            for n in nodes {
                try Task.checkCancellation()
                guard n.id != rootID else { throw CloudError.denied("The top of your Dropbox can’t be deleted.") }
                do {
                    _ = try await write("files/delete_v2", ["path": .string(apiPath(n.id))], name: n.name)
                } catch CloudError.notFound {
                    continue   // already gone (or an earlier attempt whose answer was lost got there first)
                }
            }
        }
    }

    public func listTrash() async throws -> [DriveNode] { [] }

    static let deletedFilesMessage = "Cirrus can’t open Dropbox’s deleted files. To restore or permanently delete items, use Deleted files on dropbox.com."

    public func restore(_ nodes: [DriveNode]) async throws { throw CloudError.unsupported(Self.deletedFilesMessage) }

    public func deleteForever(_ nodes: [DriveNode]) async throws { throw CloudError.unsupported(Self.deletedFilesMessage) }

    // MARK: Extras

    public func quota() async throws -> StorageUsage? {
        try await DropboxHTTP.guarded {
            let j = try await http.rpc("users/get_space_usage", nil, retry: .safe)
            let mine = j["used"].int64 ?? 0
            let a = j["allocation"]
            switch a[".tag"].string {
            case "individual":
                guard let total = a["allocated"].int64, total > 0 else { return nil }
                return StorageUsage(total: total, used: mine, categories: [.init(key: "files", label: "Files", bytes: mine, color: "0061FE")])
            case "team":
                // A member limit, when the team set one, is what this user can fill; otherwise the team's pool.
                if let limit = a["user_within_team_space_allocated"].int64, limit > 0 {
                    return StorageUsage(total: limit, used: mine, categories: [.init(key: "files", label: "Files", bytes: mine, color: "0061FE")])
                }
                guard let total = a["allocated"].int64, total > 0 else { return nil }
                let team = max(a["used"].int64 ?? mine, mine)
                var cats: [StorageUsage.Category] = [.init(key: "files", label: "Your Files", bytes: mine, color: "0061FE")]
                if team > mine { cats.append(.init(key: "team", label: "Rest of Team", bytes: team - mine, color: "8A8886")) }
                return StorageUsage(total: total, used: team, categories: cats)
            default:
                return nil
            }
        }
    }

    /// The file types Dropbox makes thumbnails for (larger photos, over 20 MB, it doesn't).
    static let thumbnailExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "gif", "webp", "ppm", "bmp", "heic", "heif"]
    static let thumbnailSizes: [(name: String, side: Int)] = [("w32h32", 32), ("w64h64", 64), ("w128h128", 128), ("w256h256", 256),
                                                               ("w480h320", 480), ("w640h480", 640), ("w960h640", 960), ("w1024h768", 1024),
                                                               ("w2048h1536", 2048)]

    /// The smallest size whose longer side covers `maxPixel` (mode bestfit turns it for portrait images).
    static func thumbnailSize(for maxPixel: Int) -> String {
        thumbnailSizes.first { $0.side >= maxPixel }?.name ?? "w2048h1536"
    }

    public func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data? {
        guard !node.isFolder else { return nil }
        let ext = (node.name as NSString).pathExtension.lowercased()
        guard Self.thumbnailExtensions.contains(ext) else { return nil }
        let arg: JSON = ["resource": [".tag": "path", "path": .string(apiPath(node.id))],
                         "format": .string(ext == "png" || ext == "gif" ? "png" : "jpeg"),
                         "size": .string(Self.thumbnailSize(for: maxPixel)), "mode": "bestfit"]
        return try await DropboxHTTP.guarded {
            let r = try await http.send(http.contentRequest("files/get_thumbnail_v2", arg, upload: false), retry: .safe)
            switch r.status {
            case 200..<300: return r.data.isEmpty ? nil : r.data
            case 409: return nil   // unsupported_extension, unsupported_image, conversion_error, or gone
            default: throw DropboxHTTP.error(r, name: node.name)
            }
        }
    }
}
