import Foundation
import UniformTypeIdentifiers

public struct DriveNode: Hashable, Codable, Sendable {
    public var id: String            // drivewsid: TYPE::zone::docid
    public var docID: String?
    public var zone: String
    public var parentID: String?
    public var name: String          // full name including extension
    public var type: String          // FILE, FOLDER, APP_LIBRARY, APP_CONTAINER
    public var size: Int64
    public var modified: Date?
    public var created: Date?
    public var etag: String?
    public var childCount: Int?
    public var isShared: Bool = false

    public var isFolder: Bool { type != "FILE" }
    public var isAppLibrary: Bool { type == "APP_LIBRARY" || type == "APP_CONTAINER" }

    public init(id: String, docID: String? = nil, zone: String, parentID: String?, name: String, type: String, size: Int64,
                modified: Date?, created: Date?, etag: String?, childCount: Int? = nil) {
        self.id = id; self.docID = docID; self.zone = zone; self.parentID = parentID; self.name = name; self.type = type
        self.size = size; self.modified = modified; self.created = created; self.etag = etag; self.childCount = childCount
    }

    public static func == (a: DriveNode, b: DriveNode) -> Bool { a.id == b.id && a.etag == b.etag && a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct StorageUsage: Sendable {
    public struct Category: Sendable { public var key: String; public var label: String; public var bytes: Int64; public var color: String? }
    public var total: Int64
    public var used: Int64
    public var categories: [Category]
    public var available: Int64 { max(0, total - used) }
}

public protocol DriveBackend: AnyObject, Sendable {
    var rootID: String { get }
    func list(_ folderID: String) async throws -> [DriveNode]
    func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]]
    func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func upload(_ file: URL, name: String, into folderID: String, modified: Date?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode
    func createFolder(_ name: String, in folderID: String) async throws -> DriveNode
    func rename(_ node: DriveNode, to name: String) async throws -> DriveNode
    func move(_ nodes: [DriveNode], to folderID: String) async throws
    func trash(_ nodes: [DriveNode]) async throws
    func listTrash() async throws -> [DriveNode]
    func restore(_ nodes: [DriveNode]) async throws
    func deleteForever(_ nodes: [DriveNode]) async throws
}

public extension DriveBackend {
    /// Recursively walk a folder (breadth-first, batched). Returns relative path → node.
    func walk(_ rootFolderID: String, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [(path: String, node: DriveNode)] {
        var out = [(String, DriveNode)]()
        var frontier: [(id: String, prefix: String)] = [(rootFolderID, "")]
        while !frontier.isEmpty {
            try Task.checkCancellation()
            let batch = Array(frontier.prefix(16))
            frontier.removeFirst(batch.count)
            let listed = try await listMany(batch.map(\.id))
            for (fid, prefix) in batch {
                // A folder missing from the reply would look empty (“everything deleted”): stop instead.
                guard let items = listed[fid] else { throw ICloudError.server("iCloud Drive didn’t list “\(prefix.isEmpty ? "iCloud Drive" : prefix)”. Nothing was changed; try again.") }
                for node in items {
                    let rel = prefix.isEmpty ? node.name : prefix + "/" + node.name
                    out.append((rel, node))
                    if node.isFolder { frontier.append((node.id, rel)) }
                }
            }
            progress?(out.count)
        }
        return out
    }
}

/// iCloud Drive via iCloud.com web services (drivews + docws).
public final class WebDrive: DriveBackend, @unchecked Sendable {
    public let session: ICloudSession
    public let rootID = "FOLDER::com.apple.CloudDocs::root"
    static let pcs = (app: "iclouddrive", ws: "drivews")

    public init(session: ICloudSession) { self.session = session }

    func drivews() async throws -> String {
        guard let u = await session.webserviceURL("drivews") else { throw ICloudError.serviceUnavailable("iCloud Drive") }
        return u
    }

    func docws() async throws -> String {
        guard let u = await session.webserviceURL("docws") else { throw ICloudError.serviceUnavailable("iCloud Drive") }
        return u
    }

    static func parts(_ drivewsid: String) -> (type: String, zone: String, doc: String) {
        let s = drivewsid.components(separatedBy: "::")
        if s.count >= 3 { return (s[0], s[1], s[2...].joined(separator: "::")) }
        return ("", "com.apple.CloudDocs", drivewsid)
    }

    static func node(_ j: JSON, parent: String?) -> DriveNode? {
        guard let id = j["drivewsid"].string else { return nil }
        let type = j["type"].string ?? (id.hasPrefix("FILE") ? "FILE" : "FOLDER")
        var name = (j["name"].string ?? "").precomposedStringWithCanonicalMapping
        if let ext = j["extension"].string, !ext.isEmpty, type == "FILE" { name += "." + ext.precomposedStringWithCanonicalMapping }
        let p = parts(id)
        var n = DriveNode(id: id, docID: j["docwsid"].string ?? p.doc, zone: j["zone"].string ?? p.zone, parentID: j["parentId"].string ?? parent,
                          name: name, type: type, size: j["size"].int64 ?? 0, modified: j["dateModified"].date ?? j["dateChanged"].date,
                          created: j["dateCreated"].date, etag: j["etag"].string,
                          childCount: j["directChildrenCount"].int ?? j["numberOfItems"].int)
        n.isShared = (j["shareCount"].int ?? 0) > 0 || (j["shareAliasCount"].int ?? 0) > 0
        return n
    }

    public func list(_ folderID: String) async throws -> [DriveNode] {
        try await listMany([folderID])[folderID] ?? []
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        guard !folderIDs.isEmpty else { return [:] }
        let body = JSON.array(folderIDs.map { ["drivewsid": .string($0), "partialData": false, "includeHierarchy": false] })
        let resp = try await session.request(try await drivews() + "/retrieveItemDetailsInFolders", json: body, pcs: Self.pcs)
        var out = [String: [DriveNode]]()
        for (i, folder) in resp.array.enumerated() {
            let fid = folder["drivewsid"].string ?? (i < folderIDs.count ? folderIDs[i] : "")
            if folder["status"].string == "NOT_FOUND" { throw ICloudError.notFound }
            // An error entry has no item list; treating it as an empty folder would be dangerous for sync.
            if folder["items"].isNull && (folder["numberOfItems"].int64 ?? 0) > 0 || folder["errorCode"].string != nil {
                throw ICloudError.server("iCloud Drive couldn’t list a folder. Nothing was changed; try again.")
            }
            out[fid] = folder["items"].array.compactMap { Self.node($0, parent: fid) }
        }
        return out
    }

    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let p = Self.parts(node.id)
        let info = try await session.request(try await docws() + "/ws/\(node.zone.isEmpty ? p.zone : node.zone)/download/by_id",
                                             method: "GET", query: ["document_id": node.docID ?? p.doc], pcs: Self.pcs)
        if let url = info["data_token"]["url"].string {
            try await session.download(from: url, to: destination, expectedSize: node.size, progress: progress)
        } else if let url = info["package_token"]["url"].string {
            // Packages (Pages/Keynote bundles…) come as a zip of the bundle.
            let zip = Paths.tempFile(named: node.name + ".zip")
            try await session.download(from: url, to: zip, expectedSize: node.size, progress: progress)
            try Unzip.expandPackage(zip: zip, to: destination)
        } else if node.size == 0 {
            FileManager.default.createFile(atPath: destination.path, contents: Data())
        } else {
            throw ICloudError.server("iCloud didn’t return a download link for “\(node.name)”.")
        }
        if let m = node.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: destination.path) }
    }

    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        try SafetyPolicy.checkWrite()
        let zone = Self.parts(folderID).zone
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if size > 50_000_000_000 { throw ICloudError.server("“\(name)” is \(size.byteString), larger than iCloud Drive’s 50 GB file limit.") }
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let docs = try await docws()
        let create = try await session.request(docs + "/ws/\(zone)/upload/web",
            json: ["filename": .string(name), "type": "FILE", "size": .string(String(size)), "content_type": .string(mime)],
            pcs: Self.pcs, idempotent: false)
        guard let uploadURL = create[0]["url"].string, let documentID = create[0]["document_id"].string else {
            throw ICloudError.server("iCloud didn’t accept the upload of “\(name)”.")
        }
        let sent = try await session.upload(to: uploadURL, file: file, multipartName: name, contentType: mime, progress: progress)
        let single = sent["singleFile"]
        let mtime = Int64((modified ?? Date()).timeIntervalSince1970 * 1000)
        var data: [String: JSON] = ["size": .int64(single["size"].int64 ?? size)]
        if let v = single["receipt"].string { data["receipt"] = .string(v) }
        if let v = single["fileChecksum"].string { data["signature"] = .string(v) }
        if let v = single["referenceChecksum"].string { data["reference_signature"] = .string(v) }
        if let v = single["wrappingKey"].string { data["wrapping_key"] = .string(v) }
        let update: JSON = [
            "allow_conflict": true, "btime": .int64(mtime), "command": "add_file", "create_short_guid": true,
            "data": .object(data), "document_id": .string(documentID),
            "file_flags": ["is_executable": true, "is_hidden": false, "is_writable": true], // matches rclone's known-good payload
            "mtime": .int64(mtime),
            "path": ["path": .string(name), "starting_document_id": .string(Self.parts(folderID).doc)],
        ]
        let result = try await session.request(docs + "/ws/\(zone)/update/documents", json: update, pcs: Self.pcs, idempotent: false)
        let doc = result["results"][0]["document"]
        let docID = doc["document_id"].string ?? documentID
        return DriveNode(id: "FILE::\(zone)::\(docID)", docID: docID, zone: zone, parentID: folderID, name: doc["name"].string.map { n in
            if let ext = doc["extension"].string, !ext.isEmpty, !n.hasSuffix("." + ext) { return n + "." + ext }
            return n
        } ?? name, type: "FILE", size: doc["size"].int64 ?? size, modified: modified ?? Date(), created: Date(), etag: doc["etag"].string)
    }

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        try SafetyPolicy.checkWrite()
        let r = try await session.request(try await drivews() + "/createFolders",
            json: ["destinationDrivewsId": .string(folderID),
                   "folders": [["clientId": .string("FOLDER::UNKNOWN_ZONE::TempId-" + UUID().uuidString), "name": .string(name)]]],
            pcs: Self.pcs, idempotent: false)
        let f = r["folders"][0]
        if let s = f["status"].string, s != "OK" { throw ICloudError.server("Couldn’t create folder (\(s)).") }
        guard let node = Self.node(f, parent: folderID) else { throw ICloudError.server("Couldn’t create folder.") }
        return node
    }

    func itemOp(_ path: String, items: [DriveNode], extra: [String: JSON] = [:], itemExtra: (DriveNode) -> [String: JSON] = { _ in [:] }) async throws -> JSON {
        var body = extra
        body["items"] = .array(items.map { n in
            var o: [String: JSON] = ["drivewsid": .string(n.id), "etag": .string(n.etag ?? ""), "clientId": .string(n.id)]
            o.merge(itemExtra(n)) { $1 }
            return .object(o)
        })
        return try await session.request(try await drivews() + path, json: .object(body), pcs: Self.pcs, idempotent: false)
    }

    func checkStatuses(_ r: JSON, retry: ([String: String]) async throws -> Void) async throws {
        var conflicts = [String: String]()
        for item in r["items"].array {
            guard let s = item["status"].string, s != "OK" else { continue }
            if s == "ETAG_CONFLICT", let id = item["drivewsid"].string, let etag = item["etag"].string { conflicts[id] = etag; continue }
            throw ICloudError.server("iCloud Drive refused the change (\(s)).")
        }
        if !conflicts.isEmpty { try await retry(conflicts) }
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        try SafetyPolicy.checkWrite()
        var target = node
        for attempt in 0..<2 {
            let r = try await itemOp("/renameItems", items: [target], itemExtra: { _ in ["name": .string(name)] })
            let item = r["items"][0]
            if item["status"].string == "ETAG_CONFLICT", attempt == 0, let e = item["etag"].string { target.etag = e; continue }
            if let s = item["status"].string, s != "OK" { throw ICloudError.server("Couldn’t rename (\(s)).") }
            return Self.node(item, parent: node.parentID) ?? { var n = node; n.name = name; return n }()
        }
        throw ICloudError.conflict
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        try SafetyPolicy.checkWrite()
        let r = try await itemOp("/moveItems", items: nodes, extra: ["destinationDrivewsId": .string(folderID)])
        try await checkStatuses(r) { conflicts in
            let fixed = nodes.compactMap { n -> DriveNode? in guard let e = conflicts[n.id] else { return nil }; var m = n; m.etag = e; return m }
            let r2 = try await self.itemOp("/moveItems", items: fixed, extra: ["destinationDrivewsId": .string(folderID)])
            try await self.checkStatuses(r2) { _ in throw ICloudError.conflict }
        }
    }

    public func trash(_ nodes: [DriveNode]) async throws {
        try SafetyPolicy.checkWrite()
        let r = try await itemOp("/moveItemsToTrash", items: nodes)
        try await checkStatuses(r) { conflicts in
            let fixed = nodes.compactMap { n -> DriveNode? in guard let e = conflicts[n.id] else { return nil }; var m = n; m.etag = e; return m }
            let r2 = try await self.itemOp("/moveItemsToTrash", items: fixed)
            try await self.checkStatuses(r2) { _ in throw ICloudError.conflict }
        }
    }

    public func listTrash() async throws -> [DriveNode] {
        let body: JSON = [["drivewsid": "TRASH_ROOT", "partialData": false, "includeHierarchy": false]]
        let r = try await session.request(try await drivews() + "/retrieveItemDetailsInFolders", json: body, pcs: Self.pcs)
        return r[0]["items"].array.compactMap { Self.node($0, parent: "TRASH_ROOT") }
    }

    public func restore(_ nodes: [DriveNode]) async throws {
        try SafetyPolicy.checkWrite()
        let r = try await itemOp("/putBackItemsFromTrash", items: nodes)
        try await checkStatuses(r) { _ in throw ICloudError.conflict }
    }

    public func deleteForever(_ nodes: [DriveNode]) async throws {
        try SafetyPolicy.checkWrite()
        let r = try await itemOp("/deleteItems", items: nodes)
        try await checkStatuses(r) { _ in throw ICloudError.conflict }
    }
}

enum Unzip {
    static func expandPackage(zip: URL, to destination: URL) throws {
        let staging = Paths.tempFile(named: "pkg")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, staging.path]
        try p.run()
        p.waitUntilExit()
        let ok = p.terminationStatus == 0
        #else
        // No ditto on iOS: extract in-process (refuses unsafe paths, checks CRCs).
        let ok = (try? ZipReader.extract(zip, into: staging)) != nil
        #endif
        defer { try? FileManager.default.removeItem(at: zip) }
        let items = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        try? FileManager.default.removeItem(at: destination)
        if ok, items.count == 1 {
            try FileManager.default.moveItem(at: items[0], to: destination)
        } else if ok {
            try FileManager.default.moveItem(at: staging, to: destination)
        } else {
            try FileManager.default.moveItem(at: zip, to: destination.appendingPathExtension("zip"))
        }
    }
}
