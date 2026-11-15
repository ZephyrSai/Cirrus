import Foundation
import UniformTypeIdentifiers

public struct GoogleUser: Sendable, Equatable {
    public var id: String        // permissionId: stable for the account
    public var email: String
    public var name: String
}

public struct GoogleQuota: Sendable, Equatable {
    public var limit: Int64?     // nil = unlimited
    public var usage: Int64      // Drive + Gmail + Photos
    public var usageInDrive: Int64
    public var usageInTrash: Int64
    public var free: Int64? { limit.map { max(0, $0 - usage) } }

    /// For the storage bar: Drive, Gmail & Photos, and (optionally) what this move adds.
    public func usageBar(adding pending: Int64) -> StorageUsage? {
        guard let limit, limit > 0 else { return nil }
        var cats = [StorageUsage.Category(key: "drive", label: "Google Drive", bytes: usageInDrive, color: "4285F4"),
                    StorageUsage.Category(key: "other", label: "Gmail & Google Photos", bytes: max(0, usage - usageInDrive), color: "FBBC04")]
        if pending > 0 { cats.append(StorageUsage.Category(key: "move", label: "This move", bytes: pending, color: "34A853")) }
        return StorageUsage(total: limit, used: usage + pending, categories: cats)
    }
}

public struct GDriveFile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var size: Int64
    public var modified: Date?
    public var md5: String?
    public var trashed: Bool
    public var appProperties: [String: String]
    public var isFolder: Bool { mimeType == GoogleDrive.folderMime }

    init(_ j: JSON) {
        id = j["id"].string ?? ""
        name = j["name"].string ?? ""
        mimeType = j["mimeType"].string ?? ""
        size = j["size"].int64String ?? 0
        modified = j["modifiedTime"].date
        md5 = j["md5Checksum"].string
        trashed = j["trashed"].bool ?? false
        appProperties = j["appProperties"].object.compactMapValues(\.string)
    }
}

/// A resumable upload session (Drive keeps it for about a week).
public struct DriveUploadSession: Codable, Sendable, Equatable {
    public var url: String
    public var total: Int64
    public var started: Date
}

/// Google Drive v3 over raw HTTP, limited to what the drive.file scope allows: files Cirrus created.
public final class GoogleDrive: @unchecked Sendable {
    public static let base = "https://www.googleapis.com/drive/v3"
    public static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    public static let folderMime = "application/vnd.google-apps.folder"
    /// Google Drive: files up to 5 TB.
    public static let maxFileSize: Int64 = 5 * 1024 * 1024 * 1024 * 1024
    /// Google Drive: about 750 GB of uploads per user per day.
    public static let dailyUploadLimit: Int64 = 750_000_000_000
    static let fileFields = "id,name,mimeType,size,modifiedTime,md5Checksum,trashed,appProperties"

    public let api: GoogleAPI
    /// Bytes per request; must be a multiple of 256 KiB.
    public var chunkSize = 8 << 20
    /// Bytes per ranged download request (tests make it small).
    nonisolated(unsafe) public static var downloadChunk: Int64 = 16 << 20

    public init(api: GoogleAPI) { self.api = api }

    public func about() async throws -> (GoogleUser, GoogleQuota) {
        let j = try await api.json("GET", Self.base + "/about", query: ["fields": "user(displayName,emailAddress,permissionId),storageQuota"], idempotent: true)
        let u = j["user"], q = j["storageQuota"]
        let user = GoogleUser(id: u["permissionId"].string ?? "", email: u["emailAddress"].string ?? "", name: u["displayName"].string ?? "")
        let quota = GoogleQuota(limit: q["limit"].int64String, usage: q["usage"].int64String ?? 0,
                                usageInDrive: q["usageInDrive"].int64String ?? 0, usageInTrash: q["usageInDriveTrash"].int64String ?? 0)
        return (user, quota)
    }

    /// nil when the file doesn't exist (or Cirrus can no longer see it).
    public func get(_ id: String) async throws -> GDriveFile? {
        let req = try api.request("GET", Self.base + "/files/" + id, query: ["fields": Self.fileFields])
        do {
            return GDriveFile(try await api.send(req, idempotent: true).json)
        } catch GoogleError.http(let code, _) where code == 404 {
            return nil
        }
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Children of a folder that aren't in the trash ("root" = My Drive).
    public func children(_ parentID: String) async throws -> [GDriveFile] {
        var out = [GDriveFile]()
        var token: String?
        repeat {
            var q = ["q": "\(Self.quote(parentID)) in parents and trashed = false", "fields": "nextPageToken,files(\(Self.fileFields))",
                     "pageSize": "1000", "spaces": "drive"]
            if let t = token { q["pageToken"] = t }
            let j = try await api.json("GET", Self.base + "/files", query: q, idempotent: true)
            out += j["files"].array.map(GDriveFile.init)
            token = j["nextPageToken"].string
        } while token != nil
        return out
    }

    public func createFolder(_ name: String, parent: String, appProperties: [String: String] = [:]) async throws -> GDriveFile {
        var body: [String: JSON] = ["name": .string(name), "mimeType": .string(Self.folderMime), "parents": .array([.string(parent)])]
        if !appProperties.isEmpty { body["appProperties"] = .object(appProperties.mapValues { .string($0) }) }
        return GDriveFile(try await api.json("POST", Self.base + "/files", query: ["fields": Self.fileFields], body: .object(body), idempotent: false))
    }

    /// Moves a file Cirrus created to Google Drive's trash (recoverable for 30 days). Cirrus never deletes permanently.
    public func trash(_ id: String) async throws {
        _ = try await api.json("PATCH", Self.base + "/files/" + id, query: ["fields": "id,trashed"], body: ["trashed": true], idempotent: true)
    }

    public static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Opens a resumable upload session for a new file.
    public func startUpload(name: String, parent: String, size: Int64, modified: Date?, appProperties: [String: String] = [:]) async throws -> DriveUploadSession {
        var meta: [String: JSON] = ["name": .string(name), "parents": .array([.string(parent)])]
        if let m = modified { meta["modifiedTime"] = .string(Self.iso(m)) }
        if !appProperties.isEmpty { meta["appProperties"] = .object(appProperties.mapValues { .string($0) }) }
        let req = try api.request("POST", Self.uploadBase + "/files", query: ["uploadType": "resumable", "fields": Self.fileFields], json: .object(meta),
                                  headers: ["X-Upload-Content-Type": Self.mimeType(for: name), "X-Upload-Content-Length": String(size)])
        // A lost response only leaves an unused session behind, so this is safe to retry.
        let r = try await api.send(req, idempotent: true)
        guard let loc = r.header("Location"), URL(string: loc) != nil else { throw GoogleError.badResponse("Google didn’t open an upload session.") }
        return DriveUploadSession(url: loc, total: size, started: Date())
    }

    public enum UploadStatus: Sendable, Equatable { case incomplete(Int64), complete(GDriveFile), expired }

    /// Next byte Google expects, from a 308's `Range: bytes=0-N` (no header = nothing stored yet).
    static func nextOffset(_ r: GoogleAPI.Response) -> Int64 {
        guard let range = r.header("Range"), let dash = range.lastIndex(of: "-"), let end = Int64(range[range.index(after: dash)...]) else { return 0 }
        return end + 1
    }

    /// Asks Google how much of an interrupted upload it already has.
    public func status(_ s: DriveUploadSession) async throws -> UploadStatus {
        var attempt = 0
        while true {
            var req = URLRequest(url: URL(string: s.url)!)
            req.httpMethod = "PUT"
            req.setValue("bytes */\(s.total)", forHTTPHeaderField: "Content-Range")
            req.setValue("0", forHTTPHeaderField: "Content-Length")
            let r: GoogleAPI.Response
            do { r = try await api.perform(req, body: .data(Data())) } catch let e as URLError where GoogleAPI.isTransient(e, ambiguousOK: true) && attempt < api.maxRetries {
                attempt += 1
                try await api.sleep(api.delay(attempt: attempt, retryAfter: nil))
                continue
            }
            switch r.status {
            case 200, 201: return .complete(GDriveFile(r.json))
            case 308: return .incomplete(Self.nextOffset(r))
            case 404, 410: return .expired
            default:
                if case .retry(let after) = GoogleAPI.classify(r.status, r.data, retryAfter: r.header("Retry-After")), attempt < api.maxRetries {
                    attempt += 1
                    try await api.sleep(api.delay(attempt: attempt, retryAfter: after))
                    continue
                }
                if case .fail(let e) = GoogleAPI.classify(r.status, r.data, retryAfter: nil) { throw e }
                throw GoogleError.http(r.status, "Couldn’t check the upload.")
            }
        }
    }

    /// Sends the file in chunks. With `resume`, first asks Google where an earlier attempt stopped.
    /// Network drops and 5xx/429 answers resume from Google's last stored byte; a gone session throws `.uploadExpired`.
    public func upload(_ file: URL, session s: DriveUploadSession, resume: Bool,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> GDriveFile {
        precondition(chunkSize % (256 * 1024) == 0, "Drive chunks must be multiples of 256 KiB")
        var offset: Int64 = 0
        if resume {
            switch try await status(s) {
            case .complete(let f): progress(s.total, s.total); return f
            case .incomplete(let o): offset = o
            case .expired: throw GoogleError.uploadExpired
            }
        }
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var failures = 0
        func recover(_ after: Double?) async throws -> GDriveFile? {
            failures += 1
            guard failures <= api.maxRetries else { throw GoogleError.rateLimited }
            try await api.sleep(api.delay(attempt: failures, retryAfter: after))
            switch try await status(s) {
            case .complete(let f): return f
            case .incomplete(let o): offset = o; return nil
            case .expired: throw GoogleError.uploadExpired
            }
        }
        while true {
            try Task.checkCancellation()
            progress(offset, s.total)
            let len = Int(min(Int64(chunkSize), s.total - offset))
            try fh.seek(toOffset: UInt64(offset))
            let data = len > 0 ? (try fh.read(upToCount: len) ?? Data()) : Data()
            guard data.count == len else { throw GoogleError.badResponse("The file changed while Cirrus was uploading it.") }
            var req = URLRequest(url: URL(string: s.url)!)
            req.httpMethod = "PUT"
            req.setValue(len > 0 ? "bytes \(offset)-\(offset + Int64(len) - 1)/\(s.total)" : "bytes */\(s.total)", forHTTPHeaderField: "Content-Range")
            req.setValue(String(len), forHTTPHeaderField: "Content-Length")
            let base = offset
            let r: GoogleAPI.Response
            do {
                r = try await api.perform(req, body: .data(data)) { sent in progress(base + min(sent, Int64(len)), s.total) }
            } catch let e as URLError where GoogleAPI.isTransient(e, ambiguousOK: true) {
                Log.status("google upload interrupted (\(e.code.rawValue)); resuming")
                if let f = try await recover(nil) { return f }
                continue
            }
            switch r.status {
            case 200, 201:
                progress(s.total, s.total)
                return GDriveFile(r.json)
            case 308:
                let next = Self.nextOffset(r)
                if next > offset { failures = 0 }
                offset = next
            case 404, 410:
                throw GoogleError.uploadExpired
            default:
                switch GoogleAPI.classify(r.status, r.data, retryAfter: r.header("Retry-After")) {
                case .retry(let after): if let f = try await recover(after) { return f }
                case .fail(let e): throw e
                case .ok: throw GoogleError.badResponse("Unexpected answer from Google (\(r.status)).")
                }
            }
        }
    }
}
