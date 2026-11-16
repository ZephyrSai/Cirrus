import Foundation

// Uploads: small files in one PUT, larger ones through an upload session (fragments that are multiples of
// 320 KiB, resumed from the session's nextExpectedRanges after failures). Always conflictBehavior=fail:
// Cirrus chooses free names itself, so OneDrive must never replace or rename behind its back.

extension OneDriveBackend {
    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        let name = try Self.checkName(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0 else { throw CloudError.server("Cirrus couldn’t read “\(name)” to upload it.") }
        guard size <= Self.maxFileSize else {
            throw CloudError.denied("“\(name)” is \(size.byteString), larger than OneDrive’s 250 GB file limit.")
        }
        let target = OneDriveRef(folderID).contentPath + ":/" + Self.encodeName(name)
        return try await OneDriveHTTP.guarded {
            if size <= simpleUploadLimit {
                let n = try await simpleUpload(file, name: name, size: size, target: target, folderID: folderID, progress: progress)
                // A one-request upload can't carry the file's date; set it afterwards (best effort: the file is there).
                guard let m = modified else { return n }
                do { return try await setModified(n, m) } catch is CancellationError { throw CancellationError() } catch {
                    Log.status("onedrive: couldn’t set the modification date after upload")
                    return n
                }
            }
            return try await sessionUpload(file, name: name, size: size, target: target, folderID: folderID, modified: modified, progress: progress)
        }
    }

    func setModified(_ n: DriveNode, _ date: Date) async throws -> DriveNode {
        let j = try await http.json("PATCH", OneDriveRef(n.id).selfPath, body: ["fileSystemInfo": ["lastModifiedDateTime": .string(Self.iso(date))]],
                                    retry: .safe, name: n.name)
        var out = n
        out.modified = j["fileSystemInfo"]["lastModifiedDateTime"].date ?? date
        out.etag = j["eTag"].string ?? n.etag
        return out
    }

    func simpleUpload(_ file: URL, name: String, size: Int64, target: String, folderID: String,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        let started = Date()
        var req = try http.request("PUT", OneDriveHTTP.graph + target + ":/content", query: [("@microsoft.graph.conflictBehavior", "fail")])
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var failures = 0
        var ambiguous = false
        while true {
            try Task.checkCancellation()
            progress(0, size)
            let r: GraphResponse
            do {
                r = try await http.send(req, body: .file(file), retry: .unsafe, sent: { progress(min($0, size), size) })
            } catch let e as URLError where e.code != .cancelled && OneDriveHTTP.retryable(e, ambiguousOK: true) && failures < http.maxRetries {
                // The answer was lost, but the file may have landed: look before sending it again.
                failures += 1
                ambiguous = true
                try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                if let n = try await landed(target, size: size, since: started, folderID: folderID) { progress(size, size); return n }
                continue
            }
            if r.status == 409, ambiguous, let n = try await landed(target, size: size, since: started, folderID: folderID) {
                progress(size, size)
                return n
            }
            guard (200..<300).contains(r.status) else { throw OneDriveHTTP.error(r, name: name) }
            guard let n = node(r.json, in: folderID) else { throw CloudError.server("OneDrive didn’t confirm the upload of “\(name)”.") }
            progress(size, size)
            return n
        }
    }

    /// After a lost answer: did the upload land anyway? Same name, same size, created since this upload began.
    /// (With conflictBehavior=fail nothing of that name existed when it began, or the first try had failed.)
    func landed(_ target: String, size: Int64, since: Date, folderID: String) async throws -> DriveNode? {
        let r = try await http.send(try http.request("GET", OneDriveHTTP.graph + target, query: [("$select", Self.select)]), retry: .safe)
        guard r.status == 200, let n = node(r.json, in: folderID), !n.isFolder, n.size == size,
              let created = r.json["createdDateTime"].date, created >= since.addingTimeInterval(-300) else { return nil }
        return n
    }

    enum SessionStatus { case next(Int64), gone }

    /// Where an upload session wants the next byte (no Authorization header: the URL is pre-authenticated).
    func sessionStatus(_ url: URL) async throws -> SessionStatus {
        let r = try await http.send(URLRequest(url: url), auth: false, retry: .safe)
        if r.status == 404 || r.status == 410 { return .gone }
        guard (200..<300).contains(r.status) else { throw OneDriveHTTP.error(r) }
        return Self.nextOffset(r.json).map { .next($0) } ?? .gone
    }

    /// The start of the first missing range, from `nextExpectedRanges` (["12345-"] or ["0-999", "2000-"]).
    static func nextOffset(_ j: JSON) -> Int64? {
        guard let first = j["nextExpectedRanges"][0].string, let dash = first.firstIndex(of: "-") else { return nil }
        return Int64(first[..<dash])
    }

    func sessionUpload(_ file: URL, name: String, size: Int64, target: String, folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        let started = Date()
        var item: [String: JSON] = ["@microsoft.graph.conflictBehavior": "fail", "name": .string(name), "fileSize": .int64(size)]
        if let m = modified { item["fileSystemInfo"] = ["lastModifiedDateTime": .string(Self.iso(m))] }
        // A lost answer here only leaves an unused session behind (it expires), so this is safe to retry.
        let created = try await http.json("POST", target + ":/createUploadSession", body: ["item": .object(item)], retry: .safe, name: name)
        guard let link = created["uploadUrl"].string, let url = URL(string: link), url.scheme?.lowercased() == "https" else {
            throw CloudError.server("OneDrive didn’t open an upload for “\(name)”. Try again.")
        }
        let unit = Int64(Self.fragmentUnit)
        let fragment = max(unit, Int64(chunkSize) / unit * unit)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var offset = Self.nextOffset(created) ?? 0
        var failures = 0
        do {
            while true {
                try Task.checkCancellation()
                let len = min(fragment, size - offset)
                guard len > 0 else { throw CloudError.server("OneDrive’s upload of “\(name)” got out of step. Try again.") }
                try fh.seek(toOffset: UInt64(offset))
                let data = try fh.read(upToCount: Int(len)) ?? Data()
                guard Int64(data.count) == len else { throw CloudError.server("“\(name)” changed while Cirrus was uploading it. Try again.") }
                var req = URLRequest(url: url)
                req.httpMethod = "PUT"
                req.setValue(String(len), forHTTPHeaderField: "Content-Length")
                req.setValue("bytes \(offset)-\(offset + len - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                let base = offset
                let isLast = offset + len == size
                progress(base, size)
                let r: GraphResponse
                do {
                    // Pre-authenticated: never with the Authorization header (OneDrive answers 401 to it).
                    r = try await http.transport(req, body: .data(data), sent: { progress(base + min($0, len), size) })
                } catch let e as URLError where e.code != .cancelled && OneDriveHTTP.retryable(e, ambiguousOK: true) {
                    failures += 1
                    guard failures <= http.maxRetries else { throw e }
                    Log.status("onedrive upload interrupted (\(e.code.rawValue)); resuming")
                    try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                    if let n = try await resume(url, &offset, isLast: isLast, target: target, size: size, since: started, folderID: folderID, name: name) {
                        progress(size, size)
                        return n
                    }
                    continue
                }
                switch r.status {
                case 200, 201:
                    guard let n = node(r.json, in: folderID) else { throw CloudError.server("OneDrive didn’t confirm the upload of “\(name)”.") }
                    progress(size, size)
                    return n
                case 202:
                    let next = Self.nextOffset(r.json) ?? (offset + len)
                    if next > offset { failures = 0 }
                    offset = next
                case 416, 429, 500, 502, 503, 504, 509:
                    // 416: OneDrive already has (part of) this range. Otherwise busy: wait, then ask where to go on.
                    failures += 1
                    guard failures <= http.maxRetries else { throw OneDriveHTTP.error(r, name: name) }
                    if r.status != 416 { try await http.sleep(http.delay(attempt: failures, retryAfter: r.retryAfter)) }
                    if let n = try await resume(url, &offset, isLast: isLast, target: target, size: size, since: started, folderID: folderID, name: name) {
                        progress(size, size)
                        return n
                    }
                case 401, 403, 404, 410:
                    // The session is gone (finished, expired, or its pre-authenticated URL no longer valid).
                    if isLast, let n = try await landed(target, size: size, since: started, folderID: folderID) { progress(size, size); return n }
                    throw CloudError.server("OneDrive ended the upload of “\(name)” before it finished. Try again.")
                default:
                    throw OneDriveHTTP.error(r, name: name)
                }
            }
        } catch {
            // Free the half-finished upload on OneDrive (best effort, never with the sign-in). Detached so a
            // cancelled transfer still gets to clean up.
            let session = http
            _ = await Task.detached { await Self.cancelSession(url, session) }.value
            throw error
        }
    }

    /// Continues from where the session says it is; returns the item if the last fragment had in fact landed.
    func resume(_ url: URL, _ offset: inout Int64, isLast: Bool, target: String, size: Int64, since: Date, folderID: String, name: String) async throws -> DriveNode? {
        switch try await sessionStatus(url) {
        case .next(let o): offset = o; return nil
        case .gone:
            if isLast, let n = try await landed(target, size: size, since: since, folderID: folderID) { return n }
            throw CloudError.server("OneDrive ended the upload of “\(name)” before it finished. Try again.")
        }
    }

    static func cancelSession(_ url: URL, _ http: OneDriveHTTP) async {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await http.transport(req)
    }
}
