import CryptoKit
import Foundation

/// A file or folder in the user's Google Drive, as seen with the drive.readonly scope.
public struct GDriveItem: Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var size: Int64?          // nil for Google Docs/Sheets/Slides (no stored bytes)
    public var modified: Date?
    public var md5: String?
    public var parents: [String]
    public var canDownload: Bool
    public var exportLinks: [String: String]
    /// Set on folders Cirrus made (“From iCloud”); private to this OAuth client.
    public var appProperties: [String: String]
    /// Public properties (any client can read them).
    public var properties: [String: String]
    /// Made by Cirrus's iCloud → Google direction (by any OAuth client).
    public var isCirrusCopy: Bool { appProperties[MigrationEngine.sourceKey] != nil || properties[MigrationEngine.sourceKey] != nil }
    public var isFolder: Bool { mimeType == GoogleDrive.folderMime }
    public var isGoogleNative: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder }
    /// Changes whenever the content does.
    public var version: String { md5 ?? modified.map { String(Int64($0.timeIntervalSince1970)) } ?? "" }

    init(_ j: JSON) {
        id = j["id"].string ?? ""
        name = j["name"].string ?? ""
        mimeType = j["mimeType"].string ?? ""
        size = j["size"].int64String
        modified = j["modifiedTime"].date
        md5 = j["md5Checksum"].string
        parents = j["parents"].array.compactMap(\.string)
        canDownload = j["capabilities"]["canDownload"].bool ?? true
        exportLinks = j["exportLinks"].object.compactMapValues(\.string)
        appProperties = j["appProperties"].object.compactMapValues(\.string)
        properties = j["properties"].object.compactMapValues(\.string)
    }
}

/// How Google Docs, Sheets and Slides come out (they have no file of their own).
public enum GoogleDocFormat: String, Codable, Sendable, CaseIterable {
    case office, pdf

    public struct Target: Sendable, Equatable { public var mime: String; public var ext: String }

    /// nil = Google can't export this kind (Forms, Sites, My Maps, shortcuts…).
    public func target(for mime: String) -> Target? {
        let pdf = Target(mime: "application/pdf", ext: "pdf")
        switch mime {
        case "application/vnd.google-apps.document":
            return self == .pdf ? pdf : Target(mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", ext: "docx")
        case "application/vnd.google-apps.spreadsheet":
            return self == .pdf ? pdf : Target(mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ext: "xlsx")
        case "application/vnd.google-apps.presentation":
            return self == .pdf ? pdf : Target(mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation", ext: "pptx")
        case "application/vnd.google-apps.drawing", "application/vnd.google-apps.jam": return pdf
        case "application/vnd.google-apps.script": return Target(mime: "application/vnd.google-apps.script+json", ext: "json")
        default: return nil
        }
    }

    public static func kindName(_ mime: String) -> String {
        switch mime {
        case "application/vnd.google-apps.form": return "Google Forms"
        case "application/vnd.google-apps.site": return "Google Sites"
        case "application/vnd.google-apps.map": return "Google My Maps"
        case "application/vnd.google-apps.shortcut": return "Shortcuts"
        case "application/vnd.google-apps.fusiontable": return "Fusion Tables"
        case "application/vnd.google-apps.vid": return "Google Vids videos"
        default: return "This kind of Google file"
        }
    }
}

public extension GoogleDrive {
    static let readFields = "id,name,mimeType,size,modifiedTime,md5Checksum,parents,capabilities/canDownload,exportLinks,appProperties,properties"
    /// Google exports Docs editors files up to 10 MB through files.export; bigger ones go through exportLinks.
    static let exportLimit: Int64 = 10 * 1024 * 1024

    /// The real id of My Drive's root folder.
    func rootFolderID() async throws -> String {
        try await api.json("GET", Self.base + "/files/root", query: ["fields": "id"], idempotent: true)["id"].string ?? "root"
    }

    /// Everything in My Drive (not in the trash), one paged listing. Items shared with the user but not
    /// added to My Drive have no parent inside it and are left out by the caller.
    func listAll(progress: (@Sendable (Int) -> Void)? = nil) async throws -> [GDriveItem] {
        var out = [GDriveItem]()
        var token: String?
        repeat {
            try Task.checkCancellation()
            var q = ["q": "trashed = false", "fields": "nextPageToken,files(\(Self.readFields))", "pageSize": "1000", "spaces": "drive"]
            if let t = token { q["pageToken"] = t }
            let j = try await api.json("GET", Self.base + "/files", query: q, idempotent: true)
            out += j["files"].array.map(GDriveItem.init)
            token = j["nextPageToken"].string
            progress?(out.count)
        } while token != nil
        return out
    }

    /// Downloads a file's bytes in ranged chunks; a dropped connection continues from what's on disk.
    /// Checks the MD5 Google reports when there is one.
    func download(_ item: GDriveItem, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) { fm.createFile(atPath: dest.path, contents: nil) }
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }
        let total = item.size ?? -1
        var have = Int64(try fh.seekToEnd())
        var failures = 0
        while total < 0 || have < total {
            try Task.checkCancellation()
            let end = total < 0 ? have + Self.downloadChunk - 1 : min(total, have + Self.downloadChunk) - 1
            let req = try api.request("GET", Self.base + "/files/" + item.id, query: ["alt": "media"], headers: ["Range": "bytes=\(have)-\(end)", "Accept": "*/*"])
            let r: GoogleAPI.Response
            do { r = try await api.send(req, idempotent: true, followRedirects: true) } catch let e as URLError where GoogleAPI.isTransient(e, ambiguousOK: true) && failures < api.maxRetries {
                failures += 1
                try await api.sleep(api.delay(attempt: failures, retryAfter: nil))
                continue
            }
            if r.status == 200 {
                // Range ignored: this is the whole file.
                try fh.truncate(atOffset: 0)
                try fh.write(contentsOf: r.data)
                have = Int64(r.data.count)
                progress(have, max(have, total))
                break
            }
            guard r.status == 206 else { throw GoogleError.http(r.status, "Unexpected download answer.") }
            try fh.write(contentsOf: r.data)
            have += Int64(r.data.count)
            progress(have, total)
            if total < 0 && Int64(r.data.count) < Self.downloadChunk { break }
            if r.data.isEmpty { throw GoogleError.badResponse("Google sent no data for \(item.name).") }
        }
        try fh.synchronize()
        if let want = item.md5, !want.isEmpty {
            let got = try Self.md5Hex(dest)
            guard got == want.lowercased() else {
                try? fh.truncate(atOffset: 0)
                throw GoogleError.badResponse("The download didn’t match Google’s checksum; it will be tried again on the next run.")
            }
        }
    }

    /// Exports a Google Docs/Sheets/Slides file. Returns the bytes written.
    func export(_ item: GDriveItem, as target: GoogleDocFormat.Target, to dest: URL) async throws -> Int64 {
        let req = try api.request("GET", Self.base + "/files/\(item.id)/export", query: ["mimeType": target.mime], headers: ["Accept": "*/*"])
        var data: Data
        do {
            data = try await api.send(req, idempotent: true, followRedirects: true).data
        } catch let e as GoogleError {
            // Too big for files.export: use the document's export link instead.
            guard case .http(let code, let msg) = e, [400, 403, 413].contains(code),
                  msg.lowercased().contains("too large") || msg.lowercased().contains("exportsizelimit"),
                  let link = item.exportLinks[target.mime], let u = URL(string: link) else { throw e }
            // Export links come from Google's answer; still, the token only goes to Google's own hosts.
            guard GoogleRedirects.allowed(u) else { throw GoogleError.badResponse("The export link for \(item.name) isn’t a Google address, so Cirrus didn’t use it.") }
            var big = URLRequest(url: u)
            big.setValue("*/*", forHTTPHeaderField: "Accept")
            data = try await api.send(big, idempotent: true, followRedirects: true).data
        }
        try data.write(to: dest)
        return Int64(data.count)
    }

    static func md5Hex(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = Insecure.MD5()
        while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
