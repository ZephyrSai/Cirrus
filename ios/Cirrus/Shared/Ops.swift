import CirrusCore
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    /// object: "<account id>|<folder id>" of a Drive folder whose contents changed.
    static let cirrusDriveChanged = Notification.Name("CirrusDriveChanged")
    /// object: account id whose photos changed (favorites, deletions, restores).
    static let cirrusPhotosChanged = Notification.Name("CirrusPhotosChanged")
}

/// Size limits checked before queueing work (same numbers as the Mac app's `Limits`).
enum Limits {
    static let iCloudDriveMax: Int64 = 50_000_000_000
    static let iCloudWebSoft: Int64 = 10_000_000_000
    static let fat32Max: Int64 = 4_294_967_295
    static let drivePreviewMax: Int64 = 25_000_000
}

struct OpsError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// File operations shared by the Drive, Photos, Export and Backup screens. Every iCloud write goes through
/// the engine, which enforces read-only mode; removals only ever go to iCloud's Recently Deleted.
@MainActor
enum Ops {
    // MARK: Opened copies (Quick Look, share, thumbnails)

    static var inFlight = [String: Task<URL, Error>]()

    static func driveKey(_ account: Account, _ node: DriveNode) -> String { "drive:" + account.id + ":" + node.id }
    static func photoKey(_ account: Account, _ asset: PhotoAsset) -> String { "photo:" + account.id + ":" + asset.id }

    /// A local copy of an iCloud Drive file in the Open cache (the Mac app's layout), reused while it's current.
    static func localCopy(_ account: Account, _ node: DriveNode, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let key = driveKey(account, node)
        if let t = inFlight[key] { return try await t.value }
        guard let drive = account.drive else { throw ICloudError.needsSignIn }
        let task = Task<URL, Error> {
            var dir = Paths.cacheDir("Open").appendingPathComponent(Paths.accountCacheName(account.id), isDirectory: true)
                .appendingPathComponent(ListingCache.stableKey(key), isDirectory: true)
            let name = Paths.safeName(node.name)
            let target = dir.appendingPathComponent(name)
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: target.path), let size = attrs[.size] as? Int64, size == node.size {
                let m = attrs[.modificationDate] as? Date
                if node.modified == nil || m == nil || abs(m!.timeIntervalSince(node.modified!)) < 2 { return target }
            }
            // An outdated copy. On iOS opened copies are never edited (Quick Look editing is off; the share
            // sheet hands out copies), so it is simply replaced.
            if fm.fileExists(atPath: dir.path) { try? fm.removeItem(at: dir) }
            if fm.fileExists(atPath: dir.path) {
                dir = dir.deletingLastPathComponent().appendingPathComponent(ListingCache.stableKey(key) + "-" + UUID().uuidString.prefix(6), isDirectory: true)
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let fresh = dir.appendingPathComponent(name)
            try await drive.download(node, to: fresh) { d, t in progress?(d, t) }
            Paths.markFetched(dir)
            return fresh
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// An original photo or video in the Preview cache, for Quick Look and sharing.
    static func photoCopy(_ account: Account, _ asset: PhotoAsset, kind: PhotoResource.Kind = .original,
                          progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        guard let backend = account.photos else { throw ICloudError.needsSignIn }
        let key = photoKey(account, asset) + ":" + kind.rawValue
        if let t = inFlight[key] { return try await t.value }
        let task = Task<URL, Error> {
            let dir = Paths.cacheDir("Preview").appendingPathComponent(Paths.accountCacheName(account.id), isDirectory: true)
                .appendingPathComponent(ListingCache.stableKey(key), isDirectory: true)
            let res = asset.resource(kind)
            var name = Paths.safeName(res?.filename ?? asset.filename)
            if kind == .liveVideo { name = (Paths.safeName(asset.filename) as NSString).deletingPathExtension + ".MOV" }
            let target = dir.appendingPathComponent(name)
            if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64, size > 0,
               (res?.size ?? 0) <= 0 || size == res?.size { return target }
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await backend.export(asset, resource: kind, to: target) { d, t in progress?(d, t) }
            return target
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    // MARK: Destinations

    /// `name`, or "name 2", "name 3"… so nothing at the destination is ever overwritten.
    nonisolated static func uniqueURL(in dir: URL, name: String, isDirectory: Bool = false) -> URL {
        let fm = FileManager.default
        var u = dir.appendingPathComponent(name, isDirectory: isDirectory)
        guard fm.fileExists(atPath: u.path) else { return u }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            u = dir.appendingPathComponent(isDirectory || ext.isEmpty ? "\(name) \(n)" : "\(stem) \(n).\(ext)", isDirectory: isDirectory)
            n += 1
        } while fm.fileExists(atPath: u.path)
        return u
    }

    nonisolated static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let lower = Set(taken.map { $0.lowercased() })
        guard lower.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let c = ext.isEmpty ? "\(name) \(n)" : "\(stem) \(n).\(ext)"
            if !lower.contains(c.lowercased()) { return c }
            n += 1
        }
    }

    /// Transfers are tagged with their account so signing out can stop them (and their Retry).
    static func group(_ account: Account) -> String { "acct:" + account.id }

    /// Stops this account's previews and opened-copy downloads (sign-out) and returns them to wait on.
    static func cancelInFlight(account: String) -> [Task<URL, Error>] {
        let mine = inFlight.filter { $0.key.hasPrefix("drive:" + account + ":") || $0.key.hasPrefix("photo:" + account + ":") }
        for t in mine.values { t.cancel() }
        return Array(mine.values)
    }

    /// Downloads are staged in Cirrus's caches on this device before they move to their destination, and
    /// uploads are staged as one request body: the device itself needs room for the largest file.
    static func internalSpaceProblem(largest: Int64, copies: Int64 = 1) -> String? {
        guard largest > 0, let free = VolumeInfo.freeSpace(at: Paths.caches) else { return nil }
        let need = largest * copies + 200_000_000
        guard need > free else { return nil }
        return "This device needs about \(need.byteString) free to stage the largest file (\(largest.byteString)), and \(free.byteString) is free. Free up space on this device first."
    }

    static func volumeKey(_ dir: URL) -> String {
        "vol:" + ((try? dir.resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? "/")
    }

    /// Free space at a folder minus what queued transfers will still write there.
    static func localFree(_ dir: URL) -> Int64? {
        guard let free = VolumeInfo.freeSpace(at: dir) else { return nil }
        return max(0, free - TransferManager.shared.pendingBytes(volumeKey(dir)))
    }

    static func isFAT(_ dir: URL) -> Bool {
        guard let f = VolumeInfo.info(for: dir)?.format?.lowercased() else { return false }
        return f.contains("fat") && !f.contains("exfat")
    }

    /// Free iCloud storage for a web account minus uploads already queued to it (nil when unknown).
    static func iCloudFree(_ account: Account) async -> Int64? {
        guard account.kind == .web || account.kind == .cloud, let u = await account.storageUsage(), u.total > 0 else { return nil }
        return max(0, u.available - TransferManager.shared.pendingBytes("icloud:" + account.id))
    }

    // MARK: Downloads to Files

    /// Checks space, then queues one transfer per selected item into `folder` (a security-scoped folder from
    /// the document picker). Folders keep their structure. Existing files are never replaced.
    static func download(_ nodes: [DriveNode], account: Account, to folder: URL) async throws {
        guard let drive = account.drive else { throw ICloudError.needsSignIn }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if SafetyPolicy.readOnlyICloud, SafetyPolicy.touchesICloud(folder) { throw SafetyPolicy.ReadOnlyError() }
        // Size everything first (folders are walked) so the space check is real.
        var plans = [(node: DriveNode, files: [(rel: String, node: DriveNode)], bytes: Int64)]()
        for n in nodes {
            if n.isFolder {
                let all = try await drive.walk(n.id)
                let files = all.filter { !$0.node.isFolder }.map { (rel: $0.path, node: $0.node) }
                plans.append((n, files, files.reduce(0) { $0 + $1.node.size }))
            } else {
                plans.append((n, [(rel: "", node: n)], n.size))
            }
        }
        let total = plans.reduce(0) { $0 + $1.bytes }
        if let free = localFree(folder), total + 50_000_000 > free {
            throw OpsError(message: "Not enough space: this needs \(total.byteString) and \(free.byteString) is free at the destination. Nothing was downloaded.")
        }
        if isFAT(folder), let big = plans.flatMap(\.files).first(where: { $0.node.size > Limits.fat32Max }) {
            throw OpsError(message: "“\(big.node.name)” is larger than 4 GB, which this drive’s FAT format can’t hold. Nothing was downloaded.")
        }
        // Packages (Pages, Keynote…) need room for the zip and the unpacked copy.
        if let p = internalSpaceProblem(largest: plans.flatMap(\.files).map(\.node.size).max() ?? 0, copies: 2) { throw OpsError(message: p) }
        let vol = volumeKey(folder)
        for p in plans {
            // The top-level name is fixed now, so a retry continues in the same place.
            let root = uniqueURL(in: folder, name: Paths.safeName(p.node.name), isDirectory: p.node.isFolder)
            let files = p.files
            TransferManager.shared.enqueue(p.node.name, detail: p.node.isFolder ? "\(files.count) files" : "", direction: .download,
                                           total: p.bytes, group: group(account), quotaKey: vol) { t in
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                // Checked again here: read-only mode may have been turned on before this ran (or a Retry).
                try SafetyPolicy.checkLocalWrite(folder)
                let fm = FileManager.default
                var done: Int64 = 0
                var failures = [String]()
                for f in files {
                    try Task.checkCancellation()
                    let target = f.rel.isEmpty ? root : f.rel.split(separator: "/").map { Paths.safeName(String($0)) }
                        .reduce(root) { $0.appendingPathComponent($1) }
                    // Already here from an earlier attempt (same size): skip.
                    if let s = try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64, s == f.node.size {
                        done += f.node.size; t.report(done, p.bytes); continue
                    }
                    if p.node.isFolder { t.setDetail(f.rel) }
                    do {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let part = target.deletingLastPathComponent().appendingPathComponent(".cirrus-part-" + target.lastPathComponent)
                        try? fm.removeItem(at: part)
                        let base = done
                        try await drive.download(f.node, to: part) { d, _ in t.report(base + d, p.bytes) }
                        var source = part, name = target.lastPathComponent
                        // A package that couldn't be unpacked arrives as its zip: keep that, under a visible name.
                        let zip = part.appendingPathExtension("zip")
                        if !fm.fileExists(atPath: part.path), fm.fileExists(atPath: zip.path) { source = zip; name += ".zip" }
                        let final = fm.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent(name).path)
                            ? uniqueURL(in: target.deletingLastPathComponent(), name: name) : target.deletingLastPathComponent().appendingPathComponent(name)
                        try fm.moveItem(at: source, to: final)
                        done += f.node.size
                        t.report(done, p.bytes)
                    } catch let e where e is CancellationError || (e as? ICloudError) == .cancelled {
                        throw e
                    } catch {
                        if !p.node.isFolder { throw error }
                        failures.append(f.rel)
                    }
                }
                if !failures.isEmpty {
                    throw OpsError(message: "\(failures.count) of \(files.count) files didn’t download. Retry continues with those.")
                }
                t.setDetail(p.node.isFolder ? "\(files.count) files" : "")
            }
        }
    }

    // MARK: Uploads to iCloud Drive

    struct UploadFile { var url: URL; var name: String; var size: Int64; var modified: Date?; var isTemporary: Bool; var scoped: Bool }

    struct UploadCheck {
        var files: [UploadFile]
        var bytes: Int64
        var blocked: [String]          // over the 50 GB iCloud Drive limit
        var cautions: [String]
        var conflicts: [String]        // names that already exist in the folder
        var iCloudFree: Int64?
        var fits: Bool { iCloudFree.map { bytes <= $0 } ?? true }
    }

    static func inspect(_ urls: [URL], scoped: Bool, temporary: Bool) -> [UploadFile] {
        urls.map { u in
            let s = scoped && u.startAccessingSecurityScopedResource()
            defer { if s { u.stopAccessingSecurityScopedResource() } }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            return UploadFile(url: u, name: u.lastPathComponent.precomposedStringWithCanonicalMapping, size: Int64(v?.fileSize ?? 0),
                              modified: v?.contentModificationDate, isTemporary: temporary, scoped: scoped)
        }
    }

    static func checkUpload(_ files: [UploadFile], account: Account, existing: [DriveNode]) async -> UploadCheck {
        let names = Set(existing.map { $0.name.lowercased() })
        var blocked = [String](), cautions = [String]()
        let limit = account.isICloud ? Limits.iCloudDriveMax : (account.provider?.maxFileSize ?? .max)
        for f in files where f.size > limit {
            blocked.append("“\(f.name)” is \(f.size.byteString), over \(account.driveTitle)’s \(limit.byteString) file limit.")
        }
        let ok = files.filter { $0.size <= limit }
        if account.kind == .web, let big = ok.first(where: { $0.size > Limits.iCloudWebSoft }) {
            cautions.append("“\(big.name)” is over 10 GB. Uploads that large through iCloud.com often fail; the Files app on a device signed in to this Apple ID is more reliable for it.")
        }
        let conflicts = ok.filter { names.contains($0.name.lowercased()) }.map(\.name)
        // The engine writes each upload's request body to a temporary file on this device first.
        if let p = internalSpaceProblem(largest: ok.map(\.size).max() ?? 0) { blocked.append(p); return UploadCheck(files: [], bytes: 0, blocked: blocked, cautions: cautions, conflicts: [], iCloudFree: nil) }
        return UploadCheck(files: ok, bytes: ok.reduce(0) { $0 + $1.size }, blocked: blocked, cautions: cautions, conflicts: conflicts,
                           iCloudFree: await iCloudFree(account))
    }

    /// Queues uploads. With `replace`, an existing file of the same name is replaced the safe way (new copy
    /// uploaded first, old one moved to Recently Deleted); otherwise the new file gets a " 2" name.
    static func upload(_ check: UploadCheck, account: Account, folderID: String, existing: [DriveNode], replace: Bool) {
        guard let drive = account.drive else { return }
        let byName = Dictionary(existing.filter { !$0.isFolder }.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var taken = Set(existing.map(\.name))
        let changedKey = account.id + "|" + folderID
        for f in check.files {
            let old = byName[f.name.lowercased()]
            let name: String
            if old != nil && replace { name = old!.name } else { name = uniqueName(f.name, taken: taken) }
            taken.insert(name)
            let target = replace ? old : nil
            TransferManager.shared.enqueue(name, detail: "To iCloud Drive", direction: .upload, total: f.size, group: group(account),
                                           quotaKey: "icloud:" + account.id) { t in
                let s = f.scoped && f.url.startAccessingSecurityScopedResource()
                defer { if s { f.url.stopAccessingSecurityScopedResource() } }
                if let target {
                    _ = try await drive.safeReplace(f.url, name: name, in: folderID, existing: target, modified: f.modified) { d, tot in t.report(d, tot) }
                } else {
                    _ = try await drive.upload(f.url, name: name, into: folderID, modified: f.modified) { d, tot in t.report(d, tot) }
                }
                // Our own staging copy (from the Photos picker) is no longer needed; never touch anything else.
                let staging = f.url.deletingLastPathComponent()
                if f.isTemporary, staging.standardizedFileURL.path.hasPrefix(Paths.cacheDir("tmp").standardizedFileURL.path + "/") {
                    try? FileManager.default.removeItem(at: staging)
                }
                await MainActor.run {
                    DriveFolderModel.memory[changedKey] = nil
                    NotificationCenter.default.post(name: .cirrusDriveChanged, object: changedKey)
                }
            }
        }
    }
}
