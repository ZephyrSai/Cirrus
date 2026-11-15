import Foundation

/// Google Photos Picker API: the user picks photos in Google's own picker (in the browser); Cirrus
/// then reads just those. The way to get specific Google Photos items since the 2025 API changes.
public final class GooglePicker: @unchecked Sendable {
    public static let base = "https://photospicker.googleapis.com/v1"

    public struct Session: Sendable {
        public var id: String
        public var pickerURL: URL
        public var pollInterval: Double
        public var timeout: Double
        public var itemsSet: Bool
    }

    let api: GoogleAPI
    public init(api: GoogleAPI) { self.api = api }

    /// "5s" / "1800.5s" → seconds.
    static func seconds(_ j: JSON) -> Double? { j.string.flatMap { Double($0.replacingOccurrences(of: "s", with: "")) } ?? j.double }

    static func session(_ j: JSON) throws -> Session {
        guard let id = j["id"].string, let uri = j["pickerUri"].string, let u = URL(string: uri) else {
            throw GoogleError.badResponse("Google Photos didn’t open a picker.")
        }
        return Session(id: id, pickerURL: u, pollInterval: seconds(j["pollingConfig"]["pollInterval"]) ?? 5,
                       timeout: seconds(j["pollingConfig"]["timeoutIn"]) ?? 1800, itemsSet: j["mediaItemsSet"].bool ?? false)
    }

    public func create(maxItems: Int = 2000) async throws -> Session {
        try Self.session(try await api.json("POST", Self.base + "/sessions", body: ["pickingConfig": ["maxItemCount": .string(String(maxItems))]], idempotent: false))
    }

    public func get(_ id: String) async throws -> Session {
        try Self.session(try await api.json("GET", Self.base + "/sessions/" + id, idempotent: true))
    }

    public func delete(_ id: String) async {
        if let req = try? api.request("DELETE", Self.base + "/sessions/" + id) { _ = try? await api.send(req, idempotent: true) }
    }

    /// The picker page; "/autoclose" closes it once the user is done.
    public static func browserURL(_ s: Session) -> URL { s.pickerURL.appendingPathComponent("autoclose") }

    /// Polls (at Google's suggested interval) until the user finished picking, or the session timed out.
    public func waitForPick(_ s: Session) async throws -> Session {
        let deadline = Date().addingTimeInterval(s.timeout)
        var cur = s
        while !cur.itemsSet {
            try Task.checkCancellation()
            guard Date() < deadline else { throw GoogleError.timedOut }
            try await Task.sleep(nanoseconds: UInt64(max(0.05, cur.pollInterval) * 1_000_000_000))
            cur = try await get(s.id)
        }
        return cur
    }

    public func items(_ sessionID: String) async throws -> [GooglePickedItem] {
        var out = [GooglePickedItem]()
        var token: String?
        repeat {
            var q = ["sessionId": sessionID, "pageSize": "100"]
            if let t = token { q["pageToken"] = t }
            let j = try await api.json("GET", Self.base + "/mediaItems", query: q, idempotent: true)
            for i in j["mediaItems"].array {
                guard let id = i["id"].string, let url = i["mediaFile"]["baseUrl"].string else { continue }
                // Videos are transcoded by Google; skip ones still processing (pick them again later).
                if let st = i["mediaFile"]["mediaFileMetadata"]["videoMetadata"]["processingStatus"].string, st != "READY" { continue }
                let mime = i["mediaFile"]["mimeType"].string ?? ""
                let video = i["type"].string == "VIDEO" || mime.hasPrefix("video/")
                out.append(GooglePickedItem(id: id, fileName: i["mediaFile"]["filename"].string ?? (id + (video ? ".mp4" : ".jpg")), mimeType: mime,
                                            baseURL: url, created: i["createTime"].date, isVideo: video))
            }
            token = j["nextPageToken"].string
        } while token != nil
        return out
    }

    /// "=d": the photo with its metadata (Google removes the location). "=dv": Google's high-quality
    /// transcode of a video, not the original. Base URLs last about an hour and need the access token.
    public func download(_ item: GooglePickedItem, to dest: URL) async throws {
        guard let u = URL(string: item.baseURL + (item.isVideo ? "=dv" : "=d")), GoogleRedirects.allowed(u) else {
            throw GoogleError.badResponse("Google Photos gave a download link that isn’t a Google address, so Cirrus didn’t use it.")
        }
        var req = URLRequest(url: u)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let r = try await api.send(req, idempotent: true, followRedirects: true)
        try r.data.write(to: dest)
    }
}
