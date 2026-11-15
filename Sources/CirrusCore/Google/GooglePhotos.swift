import AVFoundation
import Foundation
import ImageIO

/// Photos Library API, as limited since 31 March 2025: Cirrus can add media and create albums
/// (photoslibrary.appendonly) but can't read the user's library. Items and albums Cirrus creates
/// are the only ones it can put together.
public final class GooglePhotos: @unchecked Sendable {
    public static let base = "https://photoslibrary.googleapis.com/v1"
    public static let batchLimit = 50
    public static let albumLimit = 20_000
    /// Google Photos: photos up to 200 MB, videos up to 20 GB.
    public static let maxPhoto: Int64 = 200 * 1024 * 1024
    public static let maxVideo: Int64 = 20 * 1024 * 1024 * 1024
    /// Files up to this size go up in one request; bigger ones use the resumable protocol.
    public static let rawLimit: Int64 = 24 << 20

    public enum Media: Sendable { case photo, video }
    public static let photoTypes: Set<String> = ["avif", "bmp", "gif", "heic", "heif", "ico", "jpg", "jpeg", "png", "tif", "tiff", "webp",
                                                 "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "pef", "srw", "raw"]
    public static let videoTypes: Set<String> = ["3gp", "3g2", "asf", "avi", "divx", "m2t", "m2ts", "m4v", "mkv", "mmv", "mod", "mov", "mp4",
                                                 "mpg", "mpeg", "mts", "tod", "wmv"]

    public static func media(for name: String) -> Media? {
        let e = (name as NSString).pathExtension.lowercased()
        if photoTypes.contains(e) { return .photo }
        if videoTypes.contains(e) { return .video }
        return nil
    }

    /// Why Google Photos would refuse this file, or nil when it's fine.
    public static func problem(name: String, size: Int64) -> String? {
        guard let m = media(for: name) else {
            let e = (name as NSString).pathExtension
            return e.isEmpty ? "Google Photos can’t tell what kind of file this is" : "Google Photos doesn’t accept .\(e) files"
        }
        if m == .photo && size > maxPhoto { return "Photos over 200 MB are too big for Google Photos" }
        if m == .video && size > maxVideo { return "Videos over 20 GB are too big for Google Photos" }
        return nil
    }

    public static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        default: return GoogleDrive.mimeType(for: name)
        }
    }

    public struct UploadSession: Codable, Sendable, Equatable {
        public var url: String
        public var total: Int64
        public var granularity: Int64
        public var started: Date
    }

    public struct NewItem: Sendable, Equatable {
        public var token: String
        public var fileName: String
        public var description: String?
        public init(token: String, fileName: String, description: String?) { self.token = token; self.fileName = fileName; self.description = description }
    }

    public struct Created: Sendable, Equatable {
        public var token: String
        public var mediaItemID: String?
        public var error: String?
    }

    public let api: GoogleAPI
    /// Bytes per resumable request (rounded down to Google's chunk granularity).
    public var chunkSize: Int64 = 8 << 20

    public init(api: GoogleAPI) { self.api = api }

    /// Single-request upload. Returns an upload token (valid for a day).
    public func uploadRaw(_ file: URL, name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var req = URLRequest(url: URL(string: Self.base + "/uploads")!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.mimeType(for: name), forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        req.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        // An unused token simply expires, so repeating this is harmless.
        let r = try await api.send(req, body: .file(file), idempotent: true) { sent in progress(min(sent, size), size) }
        progress(size, size)
        return try Self.token(r)
    }

    static func token(_ r: GoogleAPI.Response) throws -> String {
        let t = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty, !t.hasPrefix("{") else { throw GoogleError.badResponse("Google Photos didn’t return an upload token.") }
        return t
    }

    public func startResumable(name: String, size: Int64) async throws -> UploadSession {
        var req = URLRequest(url: URL(string: Self.base + "/uploads")!)
        req.httpMethod = "POST"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        req.setValue(Self.mimeType(for: name), forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        req.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        req.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Raw-Size")
        let r = try await api.send(req, idempotent: true)
        guard let url = r.header("X-Goog-Upload-URL"), URL(string: url) != nil else { throw GoogleError.badResponse("Google Photos didn’t open an upload session.") }
        let g = r.header("X-Goog-Upload-Chunk-Granularity").flatMap { Int64($0) } ?? 262_144
        return UploadSession(url: url, total: size, granularity: max(1, g), started: Date())
    }

    /// Bytes Google has for this session, or nil if the session is finished or gone.
    func received(_ s: UploadSession) async throws -> Int64? {
        var req = URLRequest(url: URL(string: s.url)!)
        req.httpMethod = "POST"
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue("query", forHTTPHeaderField: "X-Goog-Upload-Command")
        let r = try await api.send(req, idempotent: true)
        guard r.header("X-Goog-Upload-Status")?.lowercased() == "active" else { return nil }
        return r.header("X-Goog-Upload-Size-Received").flatMap { Int64($0) } ?? 0
    }

    /// Resumable upload in granularity-sized chunks; the last one finalizes and returns the token.
    public func uploadResumable(_ file: URL, session s: UploadSession, resume: Bool,
                                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> String {
        var offset: Int64 = 0
        if resume {
            guard let got = try await received(s) else { throw GoogleError.uploadExpired }
            offset = got
        }
        let chunk = max(s.granularity, (chunkSize / s.granularity) * s.granularity)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var failures = 0
        while true {
            try Task.checkCancellation()
            progress(offset, s.total)
            let len = min(chunk, s.total - offset)
            let last = offset + len >= s.total
            try fh.seek(toOffset: UInt64(offset))
            let data = len > 0 ? (try fh.read(upToCount: Int(len)) ?? Data()) : Data()
            guard Int64(data.count) == len else { throw GoogleError.badResponse("The file changed while Cirrus was uploading it.") }
            var req = URLRequest(url: URL(string: s.url)!)
            req.httpMethod = "POST"
            req.setValue(last ? "upload, finalize" : "upload", forHTTPHeaderField: "X-Goog-Upload-Command")
            req.setValue(String(offset), forHTTPHeaderField: "X-Goog-Upload-Offset")
            req.setValue(String(len), forHTTPHeaderField: "Content-Length")
            let base = offset
            var retryAfter: Double?
            do {
                let r = try await api.perform(req, body: .data(data)) { sent in progress(base + min(sent, len), s.total) }
                switch GoogleAPI.classify(r.status, r.data, retryAfter: r.header("Retry-After")) {
                case .ok:
                    if last { progress(s.total, s.total); return try Self.token(r) }
                    offset += len
                    failures = 0
                    continue
                case .fail(let e):
                    if r.status == 404 || r.status == 410 { throw GoogleError.uploadExpired }
                    throw e
                case .retry(let a): retryAfter = a
                }
            } catch let e as URLError where GoogleAPI.isTransient(e, ambiguousOK: true) {
                Log.status("google photos upload interrupted (\(e.code.rawValue)); resuming")
            }
            failures += 1
            guard failures <= api.maxRetries else { throw GoogleError.rateLimited }
            try await api.sleep(api.delay(attempt: failures, retryAfter: retryAfter))
            guard let got = try await received(s) else { throw GoogleError.uploadExpired }
            offset = got
        }
    }

    /// Creates up to 50 media items from upload tokens. Per-item failures come back in `error`.
    /// Only one batchCreate runs at a time (Google's rule); re-sent bytes map to the same media item.
    public func batchCreate(_ items: [NewItem], albumID: String? = nil) async throws -> [Created] {
        precondition(items.count <= Self.batchLimit, "batchCreate takes at most 50 items")
        guard !items.isEmpty else { return [] }
        var body: [String: JSON] = ["newMediaItems": .array(items.map { i in
            var o: [String: JSON] = ["simpleMediaItem": ["uploadToken": .string(i.token), "fileName": .string(i.fileName)]]
            if let d = i.description, !d.isEmpty { o["description"] = .string(String(d.prefix(999))) }
            return .object(o)
        })]
        if let a = albumID { body["albumId"] = .string(a) }
        let j = try await api.json("POST", Self.base + "/mediaItems:batchCreate", body: .object(body), idempotent: true, minBackoff: api.batchCreateMinBackoff)
        var byToken = [String: Created]()
        for r in j["newMediaItemResults"].array {
            let token = r["uploadToken"].string ?? ""
            let code = r["status"]["code"].int ?? 0
            let id = r["mediaItem"]["id"].string
            byToken[token] = Created(token: token, mediaItemID: code == 0 ? id : nil,
                                     error: code == 0 && id != nil ? nil : (r["status"]["message"].string ?? "Google Photos didn’t create this item"))
        }
        return items.map { byToken[$0.token] ?? Created(token: $0.token, mediaItemID: nil, error: "Google Photos didn’t report on this item") }
    }

    /// New app-created album; returns its id.
    public func createAlbum(_ title: String) async throws -> String {
        let j = try await api.json("POST", Self.base + "/albums", body: ["album": ["title": .string(String(title.prefix(500)))]], idempotent: false)
        guard let id = j["id"].string else { throw GoogleError.badResponse("Google Photos didn’t create the album.") }
        return id
    }

    /// Adds up to 50 app-created items to an app-created album (all or nothing).
    public func addToAlbum(_ albumID: String, _ mediaItemIDs: [String]) async throws {
        precondition(mediaItemIDs.count <= Self.batchLimit, "batchAddMediaItems takes at most 50 items")
        guard !mediaItemIDs.isEmpty else { return }
        _ = try await api.json("POST", Self.base + "/albums/\(albumID):batchAddMediaItems",
                               body: ["mediaItemIds": .array(mediaItemIDs.map { .string($0) })], idempotent: true)
    }
}

/// Does a file carry its own capture date? Google Photos dates items from the file's metadata,
/// so files without one get the date written into the description instead.
public enum MediaDates {
    public static func hasEmbeddedDate(_ url: URL, video: Bool) async -> Bool {
        if video {
            let asset = AVURLAsset(url: url)
            if let item = try? await asset.load(.creationDate), (try? await item.load(.dateValue)) != nil { return true }
            return false
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifDateTimeDigitized] != nil { return true }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFDateTime] != nil { return true }
        return false
    }

    public static func description(for date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return "Taken \(f.string(from: date)) (from iCloud)"
    }
}
