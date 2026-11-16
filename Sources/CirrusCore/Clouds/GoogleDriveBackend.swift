import Foundation

/// Google Drive (My Drive) as a Cirrus account, over Drive v3 with the full `drive` scope and the user's own
/// OAuth client. Built on the migration's GoogleAPI (tokens, retries, back-off, Google-only redirects) and
/// GoogleDrive (uploads, downloads, exports).
///
/// How Google's items appear:
/// - ids are Drive file ids; `rootID` is "root" (children of My Drive's real root get `parentID == "root"`);
/// - Docs, Sheets, Slides and Drawings are files named with their export extension (“Budget” → “Budget.xlsx”,
///   size 0); downloading exports them (`exportFormat`); renaming leaves that extension off Google's title.
///   Forms, Sites, My Maps… are listed, but downloading them throws `CloudError.unsupported`;
/// - shortcuts keep their own id (renaming, moving or trashing one changes the shortcut, never what it points
///   to). A shortcut to a folder is a folder that shows the target's contents; a shortcut to a file is that file
///   (downloading fetches the target). Items reached through folder shortcuts get ids of the form
///   "<id>~<shortcut>~…" (the shortcuts followed on the way), so a shortcut that leads back into itself shows
///   as empty instead of making a walk go round forever;
/// - My Drive only: shared drives and “Shared with me” aren't listed yet.
///
/// Every node keeps what downloads need: `docID` is the id whose content to fetch (a shortcut's target),
/// `zone` that item's MIME type, `etag` its MD5 (or modified time when Google keeps no MD5).
public final class GoogleDriveBackend: CloudDriveBackend, @unchecked Sendable {
    public let provider = CloudProvider.googleDrive
    public let rootID = "root"
    public let canListTrash = true

    /// What Google lets this account do with an item (from the latest listing).
    public struct Capabilities: Sendable, Equatable {
        public var canDownload: Bool
        public var canRename: Bool
        public var canTrash: Bool
    }

    static let shortcutMime = "application/vnd.google-apps.shortcut"
    static let listFields = "id,name,mimeType,size,modifiedTime,createdTime,parents,md5Checksum,hasThumbnail,thumbnailLink,shared,"
        + "capabilities(canDownload,canRename,canTrash),shortcutDetails(targetId,targetMimeType)"
    static let contentFields = "id,name,mimeType,size,modifiedTime,md5Checksum"
    static let listConcurrency = 6
    static let writeConcurrency = 4
    static let infoCacheLimit = 50_000

    public let api: GoogleAPI
    let drive: GoogleDrive
    let client: GoogleOAuthClient
    private let token: TokenBox
    private let lock = NSLock()
    private var _onNewRefreshToken: (@Sendable (CloudSecret) -> Void)?
    private var _exportFormat = GoogleDocFormat.office
    private var realRoot: String?
    private var shortcuts = [String: (id: String, mime: String)]()
    private var thumbnails = [String: String]()          // file id → thumbnailLink ("" = none)
    private var capabilities = [String: Capabilities]()

    final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String
        init(_ v: String) { value = v }
        var current: String { lock.withLock { value } }
        /// true when it changed.
        func set(_ v: String) -> Bool { lock.withLock { if v == value { return false }; value = v; return true } }
    }

    /// `accountID` is only for logs and Google's per-account bookkeeping (the record id).
    public init(accountID: String, client: GoogleOAuthClient, refreshToken: String, transport: [AnyClass]? = nil) {
        self.client = client
        let box = TokenBox(refreshToken)
        token = box
        let oauth = GoogleOAuth(client: client, transport: transport)
        api = GoogleAPI(accountID: accountID, oauth: oauth, scopes: [GoogleScopes.drive], transport: transport, refreshToken: { box.current })
        drive = GoogleDrive(api: api)
        api.onNewRefreshToken = { [weak self] t in self?.rotated(t) }
    }

    /// What the account needs to sign back in (changes only when Google hands out a new refresh token).
    public var secret: CloudSecret {
        CloudSecret(refreshToken: token.current, clientID: client.clientID, clientSecret: client.clientSecret)
    }

    /// Called with the updated secret when Google hands out a new refresh token, so it can be saved
    /// (`CloudStore.setSecret(record.id, $0)`). Google rarely does; the old token may stop working when it does.
    public var onNewRefreshToken: (@Sendable (CloudSecret) -> Void)? {
        get { lock.withLock { _onNewRefreshToken } }
        set { lock.withLock { _onNewRefreshToken = newValue } }
    }

    /// How Docs, Sheets and Slides are named and downloaded (Office files by default, or PDF).
    public var exportFormat: GoogleDocFormat {
        get { lock.withLock { _exportFormat } }
        set { lock.withLock { _exportFormat = newValue } }
    }

    func rotated(_ t: String) {
        guard !t.isEmpty, token.set(t) else { return }
        Log.status("google drive: new refresh token")
        onNewRefreshToken?(secret)
    }

    /// Can-download/rename/trash for an item listed earlier (nil when not listed in this run).
    public func capabilities(of node: DriveNode) -> Capabilities? {
        lock.withLock { capabilities[Ref(node.id).real] }
    }

    // MARK: Ids

    /// A node id: the Drive id, then the folder shortcuts followed to reach it ("<id>~<shortcut>~…").
    struct Ref {
        var real: String
        var via: [String]
        init(_ id: String) {
            let p = id.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            real = p.first ?? id
            via = Array(p.dropFirst())
        }
        static func id(_ real: String, via: [String]) -> String { via.isEmpty ? real : ([real] + via).joined(separator: "~") }
    }

    static let exportableKinds = ["document", "spreadsheet", "presentation", "drawing", "script", "jam"].map { "application/vnd.google-apps." + $0 }

    static func isNative(_ mime: String) -> Bool {
        mime.hasPrefix("application/vnd.google-apps.") && mime != GoogleDrive.folderMime && mime != shortcutMime
    }

    static func isMD5(_ s: String) -> Bool { s.count == 32 && s.allSatisfy(\.isHexDigit) }

    static func fileURL(_ id: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-_.")
        return GoogleDrive.base + "/files/" + (id.addingPercentEncoding(withAllowedCharacters: ok) ?? id)
    }

    /// My Drive's real root id (fetched once).
    func myDriveRoot() async throws -> String {
        if let r = lock.withLock({ realRoot }) { return r }
        let r = try await drive.rootFolderID()
        lock.withLock { realRoot = r }
        return r
    }

    func shortcut(_ id: String) -> (id: String, mime: String)? { lock.withLock { shortcuts[id] } }

    func metadata(_ id: String, fields: String) async throws -> JSON {
        try await api.json("GET", Self.fileURL(id), query: ["fields": fields], idempotent: true)
    }

    /// The real folder new items go into: a folder shortcut leads to its target, "root" to My Drive.
    func destination(_ folderID: String) async throws -> String {
        let ref = Ref(folderID)
        if ref.real == rootID { return try await myDriveRoot() }
        if let t = shortcut(ref.real) {
            guard t.mime == GoogleDrive.folderMime else { throw CloudError.unsupported("That shortcut points to a file, not a folder.") }
            return t.id
        }
        return ref.real
    }

    /// The shortcuts followed to reach items inside `folderID`.
    func viaForChildren(_ folderID: String) -> [String] {
        let ref = Ref(folderID)
        if let t = shortcut(ref.real), t.mime == GoogleDrive.folderMime { return ref.via + [ref.real] }
        return ref.via
    }

    // MARK: Nodes

    /// Drive file resources → nodes, remembering shortcut targets, thumbnail links and capabilities.
    func nodes(_ files: [JSON], via: [String], parent: (JSON) -> String?) -> [DriveNode] {
        let format = exportFormat
        var out = [DriveNode]()
        var found = [(String, (id: String, mime: String))]()
        var thumbs = [(String, String)]()
        var caps = [(String, Capabilities)]()
        for j in files {
            guard let id = j["id"].string, !id.isEmpty else { continue }
            let mime = j["mimeType"].string ?? ""
            var contentID = id, contentMime = mime
            if mime == Self.shortcutMime, let t = j["shortcutDetails"]["targetId"].string, !t.isEmpty {
                contentID = t
                contentMime = j["shortcutDetails"]["targetMimeType"].string ?? ""
                found.append((id, (t, contentMime)))
            }
            let isFolder = contentMime == GoogleDrive.folderMime
            var name = (j["name"].string ?? "").precomposedStringWithCanonicalMapping
            var size = j["size"].int64String ?? 0
            if Self.isNative(contentMime) {
                size = 0
                if let ext = format.target(for: contentMime)?.ext, !name.lowercased().hasSuffix("." + ext) { name += "." + ext }
            }
            if contentID != id { size = 0 }      // a shortcut: the target's size isn't in the listing
            var n = DriveNode(id: Ref.id(id, via: via), docID: contentID, zone: contentMime, parentID: parent(j), name: name,
                              type: isFolder ? "FOLDER" : "FILE", size: size, modified: j["modifiedTime"].date, created: j["createdTime"].date,
                              etag: j["md5Checksum"].string ?? j["modifiedTime"].string)
            n.isShared = j["shared"].bool ?? false
            out.append(n)
            if contentID == id && !isFolder {
                thumbs.append((id, j["hasThumbnail"].bool == true ? (j["thumbnailLink"].string ?? "") : ""))
            }
            let c = j["capabilities"]
            caps.append((id, Capabilities(canDownload: c["canDownload"].bool ?? true, canRename: c["canRename"].bool ?? true, canTrash: c["canTrash"].bool ?? true)))
        }
        lock.withLock {
            for (k, v) in found { shortcuts[k] = v }
            if thumbnails.count > Self.infoCacheLimit { thumbnails = [:] }
            if capabilities.count > Self.infoCacheLimit { capabilities = [:] }
            for (k, v) in thumbs { thumbnails[k] = v }
            for (k, v) in caps { capabilities[k] = v }
        }
        return out
    }

    /// Node for a file Cirrus just uploaded or created.
    func node(_ f: GDriveFile, parentID: String, via: [String], fallbackModified: Date?) -> DriveNode {
        let folder = f.mimeType == GoogleDrive.folderMime
        let modified = f.modified ?? fallbackModified ?? Date()
        return DriveNode(id: Ref.id(f.id, via: via), docID: f.id, zone: f.mimeType, parentID: parentID, name: f.name.precomposedStringWithCanonicalMapping,
                         type: folder ? "FOLDER" : "FILE", size: folder ? 0 : f.size, modified: modified, created: Date(),
                         etag: f.md5 ?? GoogleDrive.iso(modified))
    }

    // MARK: Listing

    static let incomplete = CloudError.server("Google Drive sent an incomplete folder listing. Nothing was changed; try again.")

    /// One folder's children (every page). A failed or partial page throws; it never looks like an empty folder.
    func children(of parent: String, parentID: String, via: [String]) async throws -> [DriveNode] {
        var out = [DriveNode]()
        var page: String?
        repeat {
            try Task.checkCancellation()
            var q = ["q": "\(GoogleDrive.quote(parent)) in parents and trashed = false",
                     "fields": "nextPageToken,incompleteSearch,files(\(Self.listFields))", "pageSize": "1000", "spaces": "drive"]
            if let page { q["pageToken"] = page }
            let j = try await api.json("GET", GoogleDrive.base + "/files", query: q, idempotent: true)
            guard case .array(let files) = j["files"], j["incompleteSearch"].bool != true else { throw Self.incomplete }
            out += nodes(files, via: via) { _ in parentID }
            page = j["nextPageToken"].string
        } while page != nil
        return out
    }

    func listFolder(_ folderID: String) async throws -> [DriveNode] {
        let ref = Ref(folderID)
        if let t = shortcut(ref.real) { return try await listShortcut(ref, target: t, folderID: folderID) }
        var parentID = folderID
        if ref.real != rootID, ref.via.isEmpty, try await myDriveRoot() == ref.real { parentID = rootID }
        let items = try await children(of: ref.real, parentID: parentID, via: ref.via)
        if !items.isEmpty || parentID == rootID { return items }
        // Google lists nothing for a folder that's gone or in the trash, and for a shortcut: check before saying “empty”.
        let meta = try await metadata(ref.real, fields: "id,mimeType,trashed,shortcutDetails(targetId,targetMimeType)")
        if meta["trashed"].bool == true { throw CloudError.notFound }
        let mime = meta["mimeType"].string ?? ""
        if mime == Self.shortcutMime, let target = meta["shortcutDetails"]["targetId"].string {
            let t = (id: target, mime: meta["shortcutDetails"]["targetMimeType"].string ?? "")
            lock.withLock { shortcuts[ref.real] = t }
            return try await listShortcut(ref, target: t, folderID: folderID)
        }
        guard mime == GoogleDrive.folderMime else { throw CloudError.notFound }
        return []
    }

    func listShortcut(_ ref: Ref, target: (id: String, mime: String), folderID: String) async throws -> [DriveNode] {
        guard target.mime == GoogleDrive.folderMime else { throw CloudError.notFound }   // a shortcut to a file isn't a folder
        // Followed on the way here already: it leads back into itself, and following it again would never end.
        if ref.via.contains(ref.real) { return [] }
        return try await children(of: target.id, parentID: folderID, via: ref.via + [ref.real])
    }

    public func list(_ folderID: String) async throws -> [DriveNode] {
        try await mapped { try await self.listFolder(folderID) }
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        try await mapped {
            var out = [String: [DriveNode]]()
            let ids = Array(Set(folderIDs))
            try await withThrowingTaskGroup(of: (String, [DriveNode]).self) { g in
                var next = ids.makeIterator()
                for _ in 0..<min(Self.listConcurrency, ids.count) {
                    if let id = next.next() { g.addTask { (id, try await self.listFolder(id)) } }
                }
                while let (id, items) = try await g.next() {
                    out[id] = items
                    if let id = next.next() { g.addTask { (id, try await self.listFolder(id)) } }
                }
            }
            return out
        }
    }

    /// Items called `name` in a folder (Google Drive allows several). Docs, Sheets and Slides match by their
    /// listed name, export extension included.
    public func items(named name: String, in folderID: String) async throws -> [DriveNode] {
        try await mapped {
            let parent = try await self.destination(folderID)
            let via = self.viaForChildren(folderID)
            var titles = [name]
            let ext = (name as NSString).pathExtension.lowercased()
            let stem = (name as NSString).deletingPathExtension
            let format = self.exportFormat
            let exportExts = Set(Self.exportableKinds.compactMap { format.target(for: $0)?.ext })
            if !stem.isEmpty, exportExts.contains(ext) { titles.append(stem) }   // a Doc/Sheet/Slides is titled without it
            var out = [DriveNode]()
            for title in titles {
                var page: String?
                repeat {
                    var q = ["q": "name = \(GoogleDrive.quote(title)) and \(GoogleDrive.quote(parent)) in parents and trashed = false",
                             "fields": "nextPageToken,incompleteSearch,files(\(Self.listFields))", "pageSize": "1000", "spaces": "drive"]
                    if let page { q["pageToken"] = page }
                    let j = try await self.api.json("GET", GoogleDrive.base + "/files", query: q, idempotent: true)
                    guard case .array(let files) = j["files"], j["incompleteSearch"].bool != true else { throw Self.incomplete }
                    out += self.nodes(files, via: via) { _ in folderID }
                    page = j["nextPageToken"].string
                } while page != nil
            }
            let want = name.precomposedStringWithCanonicalMapping
            var seen = Set<String>()
            return out.filter { $0.name == want && seen.insert($0.id).inserted }
        }
    }

    // MARK: Transfers

    /// Downloads a file (or exports a Doc/Sheet/Slides) and sets its modification date.
    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await mapped {
            guard !node.isFolder else { throw CloudError.unsupported("“\(node.name)” is a folder; download what's inside it instead.") }
            let ref = Ref(node.id)
            let contentID = node.docID ?? ref.real
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            var modified = node.modified
            if contentID != ref.real {
                // A shortcut: what it points to isn't in the listing, so ask for it.
                let meta = try await self.metadata(contentID, fields: Self.contentFields)
                if meta["mimeType"].string == GoogleDrive.folderMime { throw CloudError.unsupported("“\(node.name)” is a shortcut to a folder.") }
                modified = meta["modifiedTime"].date ?? modified
                try await self.fetch(GDriveItem(meta), name: node.name, to: destination, progress: progress)
            } else {
                var o: [String: JSON] = ["id": .string(contentID), "name": .string(node.name), "mimeType": .string(node.zone)]
                if !Self.isNative(node.zone) { o["size"] = .string(String(node.size)) }
                if let e = node.etag, Self.isMD5(e) { o["md5Checksum"] = .string(e.lowercased()) }
                try await self.fetch(GDriveItem(.object(o)), name: node.name, to: destination, progress: progress)
            }
            if let m = modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: destination.path) }
        }
    }

    static func tooLargeToExport(_ e: GoogleError) -> Bool {
        guard case .http(let code, let msg) = e, [400, 403, 413].contains(code) else { return false }
        return msg.lowercased().contains("too large") || msg.lowercased().contains("exportsizelimit")
    }

    /// The listing was out of date (the file changed since): sizes or checksums no longer match.
    static func staleListing(_ e: GoogleError) -> Bool {
        switch e {
        case .http(416, _): return true
        case .badResponse(let m): return m.contains("checksum") || m.contains("sent no data")
        default: return false
        }
    }

    func fetch(_ item: GDriveItem, name: String, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if item.isGoogleNative {
            guard let target = exportFormat.target(for: item.mimeType) else {
                throw CloudError.unsupported("“\(name)” can’t be downloaded: \(GoogleDocFormat.kindName(item.mimeType)) can’t be exported from Google Drive. Open it in Google Drive on the web.")
            }
            let n: Int64
            do {
                n = try await drive.export(item, as: target, to: dest)
            } catch let e as GoogleError where item.exportLinks.isEmpty && Self.tooLargeToExport(e) {
                // Over files.export's 10 MB: the file's export links take bigger ones.
                n = try await drive.export(GDriveItem(try await metadata(item.id, fields: "id,name,mimeType,exportLinks")), as: target, to: dest)
            }
            progress(n, n)
            return
        }
        do {
            try await drive.download(item, to: dest, progress: progress)
        } catch let e as GoogleError where Self.staleListing(e) {
            let fresh = GDriveItem(try await metadata(item.id, fields: Self.contentFields))
            try? FileManager.default.removeItem(at: dest)
            try await drive.download(fresh, to: dest, progress: progress)
        }
    }

    /// Uploads a new file (resumable, in chunks) with its modification date. Google Drive keeps same-named
    /// files side by side; replacing one is the caller's choice (`safeReplace`).
    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        try await mapped {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            guard size <= GoogleDrive.maxFileSize else {
                throw CloudError.denied("“\(name)” is \(size.byteString), larger than Google Drive’s 5 TB file limit.")
            }
            let parent = try await self.destination(folderID)
            var restarted = false
            while true {
                let session = try await self.drive.startUpload(name: name, parent: parent, size: size, modified: modified)
                do {
                    let f = try await self.drive.upload(file, session: session, resume: false, progress: progress)
                    return self.node(f, parentID: folderID, via: self.viaForChildren(folderID), fallbackModified: modified)
                } catch GoogleError.uploadExpired where !restarted {
                    restarted = true   // Google dropped the session: start over once
                }
            }
        }
    }

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        try await mapped {
            let f = try await self.drive.createFolder(name, parent: try await self.destination(folderID))
            return self.node(f, parentID: folderID, via: self.viaForChildren(folderID), fallbackModified: nil)
        }
    }

    // MARK: Changes

    /// Renames on Google. For Docs/Sheets/Slides the export extension Cirrus shows isn't part of Google's title.
    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        try await mapped {
            let ref = Ref(node.id)
            var title = name
            if !node.isFolder, Self.isNative(node.zone), let ext = self.exportFormat.target(for: node.zone)?.ext,
               title.lowercased().hasSuffix("." + ext), title.count > ext.count + 1 {
                title = String(title.dropLast(ext.count + 1))
            }
            let j = try await self.api.json("PATCH", Self.fileURL(ref.real), query: ["fields": Self.listFields], body: ["name": .string(title)], idempotent: true)
            guard let n = self.nodes([j], via: ref.via, parent: { _ in node.parentID }).first else {
                throw CloudError.server("Google Drive didn’t confirm the new name of “\(node.name)”.")
            }
            return n
        }
    }

    /// Runs `body` for each node, a few at a time.
    func each(_ nodes: [DriveNode], _ body: @escaping @Sendable (DriveNode) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = nodes.makeIterator()
            for _ in 0..<min(Self.writeConcurrency, nodes.count) {
                if let n = next.next() { g.addTask { try await body(n) } }
            }
            while try await g.next() != nil {
                if let n = next.next() { g.addTask { try await body(n) } }
            }
        }
    }

    /// Moves items into `folderID` (from wherever they are now: Google's own parents, not the listing's).
    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        try await mapped {
            let dest = try await self.destination(folderID)
            try await self.each(nodes) { n in
                let id = Ref(n.id).real
                guard id != dest else { throw CloudError.denied("“\(n.name)” can’t be moved into itself.") }
                let parents = try await self.metadata(id, fields: "id,parents")["parents"].array.compactMap(\.string)
                if parents == [dest] { return }
                var q = ["addParents": dest, "fields": "id,parents"]
                if !parents.isEmpty { q["removeParents"] = parents.joined(separator: ",") }
                _ = try await self.api.json("PATCH", Self.fileURL(id), query: q, body: .object([:]), idempotent: true)
            }
        }
    }

    func setTrashed(_ nodes: [DriveNode], _ trashed: Bool) async throws {
        try await each(nodes) { n in
            _ = try await self.api.json("PATCH", Self.fileURL(Ref(n.id).real), query: ["fields": "id,trashed"], body: ["trashed": .bool(trashed)], idempotent: true)
        }
    }

    /// Moves items to Google Drive's trash (kept there 30 days). Never deletes.
    public func trash(_ nodes: [DriveNode]) async throws {
        try await mapped { try await self.setTrashed(nodes, true) }
    }

    /// What's in Google Drive's trash: the items trashed themselves, not everything inside a trashed folder.
    public func listTrash() async throws -> [DriveNode] {
        try await mapped {
            let root = try await self.myDriveRoot()
            var out = [DriveNode]()
            var page: String?
            repeat {
                try Task.checkCancellation()
                var q = ["q": "trashed = true", "fields": "nextPageToken,incompleteSearch,files(\(Self.listFields),explicitlyTrashed)",
                         "pageSize": "1000", "spaces": "drive"]
                if let page { q["pageToken"] = page }
                let j = try await self.api.json("GET", GoogleDrive.base + "/files", query: q, idempotent: true)
                guard case .array(let files) = j["files"], j["incompleteSearch"].bool != true else { throw Self.incomplete }
                out += self.nodes(files.filter { $0["explicitlyTrashed"].bool ?? true }, via: []) { f in
                    f["parents"][0].string.map { $0 == root ? self.rootID : $0 }
                }
                page = j["nextPageToken"].string
            } while page != nil
            return out
        }
    }

    public func restore(_ nodes: [DriveNode]) async throws {
        try await mapped { try await self.setTrashed(nodes, false) }
    }

    /// Deletes for good (folders with everything inside). Only for items the user chose to delete permanently.
    public func deleteForever(_ nodes: [DriveNode]) async throws {
        try await mapped {
            try await self.each(nodes) { n in
                let req = try self.api.request("DELETE", Self.fileURL(Ref(n.id).real))
                do { _ = try await self.api.send(req, idempotent: true) } catch GoogleError.http(404, _) {
                    // Already gone (a retried request that went through the first time).
                }
            }
        }
    }

    // MARK: Extras

    /// Space used and the plan's limit. With no limit (some Workspace plans) `total` is 0: used is known, free isn't.
    public func quota() async throws -> StorageUsage? {
        try await mapped {
            let (_, q) = try await self.drive.about()
            if let bar = q.usageBar(adding: 0) { return bar }
            return StorageUsage(total: 0, used: q.usage, categories: [
                .init(key: "drive", label: "Google Drive", bytes: q.usageInDrive, color: "4285F4"),
                .init(key: "other", label: "Gmail & Google Photos", bytes: max(0, q.usage - q.usageInDrive), color: "FBBC04"),
            ])
        }
    }

    /// Google's own thumbnail, sized to `maxPixel` (`=s<px>`), or nil when it has none. The sign-in goes only to
    /// Google's hosts; a thumbnail link anywhere else is ignored.
    public func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data? {
        guard !node.isFolder else { return nil }
        return try await mapped {
            let id = node.docID ?? Ref(node.id).real
            var link = self.lock.withLock { self.thumbnails[id] }
            if link == nil { link = try await self.thumbnailLink(id) }
            guard let l = link, let url = Self.sizedThumbnail(l, maxPixel: maxPixel), GoogleRedirects.allowed(url) else { return nil }
            do {
                return try await self.thumbnailBytes(url)
            } catch GoogleError.http(let code, _) where code == 403 || code == 404 {
                // Thumbnail links last a few hours: get a fresh one and try once more.
                guard let fresh = try await self.thumbnailLink(id), let u = Self.sizedThumbnail(fresh, maxPixel: maxPixel), u != url,
                      GoogleRedirects.allowed(u) else { return nil }
                return try await self.thumbnailBytes(u)
            }
        }
    }

    /// Remembers a thumbnail link as if a listing had sent it (tests).
    func rememberThumbnailLink(_ id: String, _ link: String) { lock.withLock { thumbnails[id] = link } }

    func thumbnailLink(_ id: String) async throws -> String? {
        let j = try await metadata(id, fields: "id,hasThumbnail,thumbnailLink")
        let link = j["hasThumbnail"].bool == true ? (j["thumbnailLink"].string ?? "") : ""
        lock.withLock { thumbnails[id] = link }
        return link.isEmpty ? nil : link
    }

    func thumbnailBytes(_ url: URL) async throws -> Data? {
        var req = URLRequest(url: url)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        let r = try await api.send(req, idempotent: true, followRedirects: true)
        let type = (r.header("Content-Type") ?? "").lowercased()
        guard !r.data.isEmpty, type.isEmpty || type.hasPrefix("image/") else { return nil }
        return r.data
    }

    /// thumbnailLink with the size asked for: lh3 links end in "=s220", older ones carry "sz=s220".
    static func sizedThumbnail(_ link: String, maxPixel: Int) -> URL? {
        guard !link.isEmpty, var c = URLComponents(string: link) else { return nil }
        let px = max(16, min(maxPixel, 2048))
        if var items = c.queryItems, let i = items.firstIndex(where: { $0.name == "sz" }) {
            items[i].value = "s\(px)"
            c.queryItems = items
        } else if let r = c.percentEncodedPath.range(of: #"=s\d+(-[A-Za-z0-9-]*)?$"#, options: .regularExpression) {
            c.percentEncodedPath.replaceSubrange(r, with: "=s\(px)")
        }
        return c.url
    }

    /// Runs `body`, turning Google's errors into `CloudError`s.
    func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw GoogleDriveCloud.cloudError(error) }
    }
}
