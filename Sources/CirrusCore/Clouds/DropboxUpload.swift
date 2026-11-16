import CryptoKit
import Foundation

// Uploads: small files in one `files/upload` request; larger ones through an upload session (start, append
// chunks, finish), resumed after interruptions from the offset Dropbox reports (`incorrect_offset` carries
// `correct_offset`). Always mode "add" with autorename off and strict conflicts: Cirrus chooses free names itself,
// so Dropbox must never replace, rename, or quietly reuse an identical file behind its back. The commit (the
// one-request upload, or `finish`) goes through the write gate; appending data doesn't need to.

extension DropboxBackend {
    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        let name = try Self.checkName(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard size >= 0 else { throw CloudError.server("Cirrus couldn’t read “\(name)” to upload it.") }
        guard size <= Self.maxFileSize else {
            throw CloudError.denied("“\(name)” is \(size.byteString), larger than the 350 GB Dropbox accepts from apps.")
        }
        return try await DropboxHTTP.guarded {
            let parent = try await folderPath(folderID)
            let path = parent.display + "/" + name
            var commit: [String: JSON] = ["path": .string(path), "mode": "add", "autorename": false, "mute": false, "strict_conflict": true]
            if let m = modified { commit["client_modified"] = .string(Self.timestamp(m)) }
            let limit = min(max(simpleUploadLimit, 0), Self.maxSimpleUpload)
            let j = size <= limit
                ? try await simpleUpload(file, name: name, size: size, commit: .object(commit), progress: progress)
                : try await sessionUpload(file, name: name, size: size, commit: .object(commit), progress: progress)
            guard let n = node(j, in: folderID, tag: "file") else { throw CloudError.server("Dropbox didn’t confirm the upload of “\(name)”.") }
            progress(size, size)
            return n
        }
    }

    func simpleUpload(_ file: URL, name: String, size: Int64, commit: JSON,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> JSON {
        let req = http.contentRequest("files/upload", commit, upload: true)
        let path = commit["path"].string ?? ""
        var failures = 0
        var ambiguous = false
        while true {
            try Task.checkCancellation()
            progress(0, size)
            let r: DropboxResponse
            do {
                r = try await writes.run {
                    try await http.send(req, body: .file(file), retry: .unsafe, sent: { progress(min($0, size), size) })
                }
            } catch let e as URLError where e.code != .cancelled && DropboxHTTP.retryable(e, ambiguousOK: true) && failures < http.maxRetries {
                // The answer was lost, but the file may have landed: look before sending it again.
                failures += 1
                ambiguous = true
                try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                if let j = try await landed(path, file: file, size: size) { return j }
                continue
            }
            if (200..<300).contains(r.status) { return r.json }
            if (500...599).contains(r.status), failures < http.maxRetries {
                failures += 1
                ambiguous = true
                try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
                if let j = try await landed(path, file: file, size: size) { return j }
                continue
            }
            if r.status == 409, ambiguous, let j = try await landed(path, file: file, size: size) { return j }
            throw DropboxHTTP.error(r, name: name)
        }
    }

    /// After a lost answer: did the upload land anyway? A file at the path with the same size and the same
    /// Dropbox content hash is this upload (or one byte-for-byte equal to it).
    func landed(_ path: String, file: URL, size: Int64) async throws -> JSON? {
        guard let m = try await metadata(path), m[".tag"].string == "file", m["size"].int64 == size,
              let remote = m["content_hash"].string else { return nil }
        guard remote == (try Self.contentHash(file)) else { return nil }
        return m
    }

    /// Dropbox's content hash: SHA-256 of the concatenated SHA-256 digests of each 4 MiB block, as hex.
    static func contentHash(_ file: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        let block = 4 * 1024 * 1024
        var digests = Data()
        while true {
            let d = try fh.read(upToCount: block) ?? Data()
            if d.isEmpty { break }
            digests.append(contentsOf: SHA256.hash(data: d))
            if d.count < block { break }
        }
        return SHA256.hash(data: digests).map { String(format: "%02x", $0) }.joined()
    }

    /// Where Dropbox says the session is, from an `incorrect_offset` error (append_v2, or finish's lookup_failed).
    static func correctOffset(_ j: JSON) -> Int64? {
        let e = j["error"]
        if e[".tag"].string == "incorrect_offset" { return e["correct_offset"].int64 }
        if e[".tag"].string == "lookup_failed", e["lookup_failed"][".tag"].string == "incorrect_offset" {
            return e["lookup_failed"]["correct_offset"].int64
        }
        return nil
    }

    func sessionUpload(_ file: URL, name: String, size: Int64, commit: JSON,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> JSON {
        let path = commit["path"].string ?? ""
        // A lost answer here only leaves an unused session behind (they expire), so this is safe to retry.
        let started = try await http.send(http.contentRequest("files/upload_session/start", ["close": false], upload: true),
                                          body: .data(Data()), retry: .safe)
        guard (200..<300).contains(started.status) else { throw DropboxHTTP.error(started, name: name) }
        guard let sid = started.json["session_id"].string, !sid.isEmpty else {
            throw CloudError.server("Dropbox didn’t open an upload for “\(name)”. Try again.")
        }
        let chunk = Int64(max(4096, min(Int64(chunkSize), Self.maxSimpleUpload)))
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var offset: Int64 = 0
        var failures = 0
        func backOff(_ e: Error) async throws {
            failures += 1
            guard failures <= http.maxRetries else { throw e }
            try await http.sleep(http.delay(attempt: failures, retryAfter: nil))
        }
        while offset < size {
            try Task.checkCancellation()
            let len = min(chunk, size - offset)
            try fh.seek(toOffset: UInt64(offset))
            let data = try fh.read(upToCount: Int(len)) ?? Data()
            guard Int64(data.count) == len else { throw CloudError.server("“\(name)” changed while Cirrus was uploading it. Try again.") }
            let base = offset
            progress(base, size)
            let arg: JSON = ["cursor": ["session_id": .string(sid), "offset": .int64(offset)], "close": false]
            let r: DropboxResponse
            do {
                r = try await http.send(http.contentRequest("files/upload_session/append_v2", arg, upload: true), body: .data(data), retry: .unsafe,
                                        sent: { progress(base + min($0, len), size) })
            } catch let e as URLError where e.code != .cancelled && DropboxHTTP.retryable(e, ambiguousOK: true) {
                // Send the same chunk again: if Dropbox did get it, it answers with the offset it has.
                Log.status("dropbox upload interrupted (\(e.code.rawValue)); resuming")
                try await backOff(e)
                continue
            }
            switch r.status {
            case 200..<300:
                offset += len
                failures = 0
            case 409:
                guard let correct = Self.correctOffset(r.json) else {
                    if r.summary.contains("not_found") {
                        throw CloudError.server("Dropbox ended the upload of “\(name)” before it finished. Try again.")
                    }
                    throw DropboxHTTP.error(r, name: name)
                }
                guard (0...size).contains(correct) else { throw CloudError.server("Dropbox’s upload of “\(name)” got out of step. Try again.") }
                if correct <= offset { try await backOff(DropboxHTTP.error(r, name: name)) }   // no progress: don't loop forever
                offset = correct
            case 500...599:
                try await backOff(DropboxHTTP.error(r, name: name))
            default:
                throw DropboxHTTP.error(r, name: name)
            }
        }
        progress(size, size)
        // Every byte is there: finishing only commits it.
        let arg: JSON = ["cursor": ["session_id": .string(sid), "offset": .int64(size)], "commit": commit]
        let req = http.contentRequest("files/upload_session/finish", arg, upload: true)
        var ambiguous = false
        failures = 0
        while true {
            try Task.checkCancellation()
            let r: DropboxResponse
            do {
                r = try await writes.run { try await http.send(req, body: .data(Data()), retry: .unsafe) }
            } catch let e as URLError where e.code != .cancelled && DropboxHTTP.retryable(e, ambiguousOK: true) {
                ambiguous = true
                try await backOff(e)
                if let j = try await landed(path, file: file, size: size) { return j }
                continue
            }
            if (200..<300).contains(r.status) { return r.json }
            if (500...599).contains(r.status) {
                ambiguous = true
                try await backOff(DropboxHTTP.error(r, name: name))
                if let j = try await landed(path, file: file, size: size) { return j }
                continue
            }
            if r.status == 409 {
                if ambiguous, let j = try await landed(path, file: file, size: size) { return j }
                if let correct = Self.correctOffset(r.json), correct != size {
                    throw CloudError.server("Dropbox’s upload of “\(name)” got out of step. Try again.")
                }
            }
            throw DropboxHTTP.error(r, name: name)
        }
    }
}
