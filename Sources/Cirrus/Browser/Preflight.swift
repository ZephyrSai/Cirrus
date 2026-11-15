import AppKit
import CirrusCore

/// Size limits Cirrus enforces before queueing work.
enum Limits {
    /// Apple: iCloud Drive stores files of 50 GB or less (and within your storage plan).
    static let iCloudDriveMax: Int64 = 50_000_000_000
    /// Community-reported: uploads through iCloud.com (what web sign-in uses) fail above 10 GB.
    static let iCloudWebSoft: Int64 = 10_000_000_000
    /// Community-reported: iCloud.com has refused Photos video uploads over ~100 MB for some accounts.
    static let photosWebVideoNote: Int64 = 100_000_000
    static let fat32Max: Int64 = 4_294_967_295
    static let confirmFiles = 1000
    static let confirmBytes: Int64 = 10_000_000_000
}

struct PreflightResult {
    var bytes: Int64 = 0
    var files = 0
    var blocked = [(name: String, size: Int64, reason: String)]()
    var cautions = [String]()
    var available: Int64?
    var availableLabel = ""
    var shortfall: Int64 { available.map { max(0, bytes - $0) } ?? 0 }
    var blockedNames: Set<String> { Set(blocked.map(\.name)) }
}

@MainActor
enum Preflight {
    static var storageCache = [String: (Date, StorageUsage)]()

    /// Free iCloud storage for a web account, minus uploads already queued to it.
    static func iCloudFree(_ acct: Account) async -> Int64? {
        guard acct.kind == .web else { return nil }
        var usage: StorageUsage?
        if let (t, u) = storageCache[acct.id], Date().timeIntervalSince(t) < 120 { usage = u } else if let u = await acct.storageUsage() {
            storageCache[acct.id] = (Date(), u)
            usage = u
        }
        guard let u = usage, u.total > 0 else { return nil }
        return max(0, u.available - TransferManager.shared.pendingBytes("icloud:" + acct.id))
    }

    static func volumeKey(_ dir: URL) -> String {
        let v = (try? dir.resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? "/"
        return "vol:" + v
    }

    static func localFree(_ dir: URL) -> Int64? {
        guard let free = VolumeInfo.freeSpace(at: dir) else { return nil }
        return max(0, free - TransferManager.shared.pendingBytes(volumeKey(dir)))
    }

    static func isFAT(_ dir: URL) -> Bool {
        guard let f = VolumeInfo.info(for: dir)?.format?.lowercased() else { return false }
        return f.contains("fat") && !f.contains("exfat")
    }

    static func isNativeICloud(_ dir: URL) -> Bool {
        guard let root = AccountManager.shared.macAccount?.driveRoot else { return false }
        return dir.standardizedFileURL.path.hasPrefix(root.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// Recursively sizes local files/folders off the main thread.
    static func scan(_ urls: [URL]) async -> [(url: URL, size: Int64, isTopLevel: Bool)] {
        await Task.detached(priority: .userInitiated) {
            var out = [(URL, Int64, Bool)]()
            for u in urls {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey])
                if v?.isDirectory == true {
                    let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: { _, _ in true })
                    var n = 0
                    while let f = e?.nextObject() as? URL, n < 500_000 {
                        let fv = try? f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        if fv?.isDirectory == true { continue }
                        out.append((f, Int64(fv?.fileSize ?? 0), false))
                        n += 1
                    }
                } else {
                    out.append((u, Int64(v?.fileSize ?? v?.totalFileSize ?? 0), true))
                }
            }
            return out
        }.value
    }

    static func checkUpload(_ urls: [URL], to dest: Destination, move: Bool) async -> PreflightResult {
        var r = PreflightResult()
        let files = await scan(urls)
        r.files = files.count
        func block(_ f: (url: URL, size: Int64, isTopLevel: Bool), _ reason: String) {
            r.blocked.append((f.url.lastPathComponent, f.size, reason + (f.isTopLevel ? "" : " (inside “\(f.url.deletingLastPathComponent().lastPathComponent)”)")))
        }
        switch dest {
        case .local(let dir):
            let sameVolume = urls.allSatisfy { Ops.sameVolume($0, dir) }
            r.bytes = move && sameVolume ? 0 : files.reduce(0) { $0 + $1.size }
            r.available = localFree(dir)
            r.availableLabel = "on “\(VolumeInfo.info(for: dir)?.name ?? dir.lastPathComponent)”"
            if isFAT(dir) { for f in files where f.size >= Limits.fat32Max { block(f, "over 4 GB, which this drive’s FAT32 format can’t store") } }
            if isNativeICloud(dir) {
                for f in files where f.size > Limits.iCloudDriveMax { block(f, "larger than iCloud Drive’s 50 GB limit") }
                r.cautions.append("Items in iCloud Drive count toward your iCloud storage plan; macOS uploads them in the background.")
            }
        case .drive(let acct, _):
            r.bytes = files.reduce(0) { $0 + $1.size }
            r.available = await iCloudFree(acct)
            r.availableLabel = "in iCloud"
            for f in files where f.size > Limits.iCloudDriveMax { block(f, "larger than iCloud Drive’s 50 GB limit") }
            let risky = files.filter { $0.size > Limits.iCloudWebSoft && $0.size <= Limits.iCloudDriveMax }
            if !risky.isEmpty {
                r.cautions.append("\(risky.count == 1 ? "“\(risky[0].url.lastPathComponent)” is" : "\(risky.count) files are") over 10 GB. iCloud.com has been reported to refuse web uploads that large; Cirrus will try, and a failure will show in Transfers.")
            }
        case .photos(let acct, _, _):
            let media = files.filter { PhotoFormats.importable($0.url) }
            r.bytes = media.reduce(0) { $0 + $1.size }
            let skipped = files.count - media.count
            if skipped > 0 { r.cautions.append("\(skipped) item\(skipped == 1 ? " isn’t a photo or video" : "s aren’t photos or videos") and will be skipped.") }
            r.files = media.count
            if acct.kind == .web {
                r.available = await iCloudFree(acct)
                r.availableLabel = "in iCloud"
                let bigVideos = media.filter { ["mov", "mp4", "m4v"].contains($0.url.pathExtension.lowercased()) && $0.size > Limits.photosWebVideoNote }
                if !bigVideos.isEmpty {
                    r.cautions.append("\(bigVideos.count) video\(bigVideos.count == 1 ? " is" : "s are") over 100 MB. iCloud.com has refused videos that size for some accounts; if it does, put them in iCloud Drive instead.")
                }
            } else {
                r.available = VolumeInfo.freeSpace(at: URL(fileURLWithPath: NSHomeDirectory()))
                r.availableLabel = "on this Mac (the Photos library copies imports)"
            }
        }
        return r
    }

    static func checkDownload(_ items: [Item], to dir: URL) async -> PreflightResult {
        var r = PreflightResult()
        r.available = localFree(dir)
        r.availableLabel = "on “\(VolumeInfo.info(for: dir)?.name ?? dir.lastPathComponent)”"
        let fat = isFAT(dir)
        let live = Prefs.exportLive, edited = Prefs.exportEdited
        for item in items {
            var size = item.size ?? 0
            if let p = item.photo { size = p.exportSize(includeLive: live, includeEdited: edited, includeRAW: false) }
            if let n = item.driveNode, n.isFolder, let drive = item.account.flatMap({ AccountManager.shared.account(id: $0) })?.drive {
                let walked: [(path: String, node: DriveNode)]? = try? await withTimeout(15) { try await drive.walk(n.id) }
                if let walked {
                    size = walked.reduce(0) { $0 + $1.node.size }
                    r.files += walked.filter { !$0.node.isFolder }.count
                    if fat { for w in walked where w.node.size >= Limits.fat32Max { r.blocked.append((w.node.name, w.node.size, "over 4 GB, which this drive’s FAT32 format can’t store")) } }
                } else { r.cautions.append("Couldn’t measure “\(n.name)” in time; its size isn’t included.") }
            } else if case .album(let a) = item.payload, let c = a.count {
                r.cautions.append("“\(a.name)” has \(c) items; its size is estimated as they download.")
            } else {
                r.files += 1
            }
            if fat && size >= Limits.fat32Max && !item.isContainer { r.blocked.append((item.name, size, "over 4 GB, which this drive’s FAT32 format can’t store")) }
            r.bytes += size
        }
        return r
    }

    /// Shows a summary when something is off or the batch is large. Returns false to cancel.
    static func confirm(_ r: PreflightResult, verb: String, destination: String, window: NSWindow?) async -> Bool {
        let big = r.files >= Limits.confirmFiles || r.bytes >= Limits.confirmBytes
        if Debug.headless { return r.blocked.count < max(1, r.files) }
        guard r.shortfall > 0 || !r.blocked.isEmpty || !r.cautions.isEmpty || big else { return true }
        let f = NumberFormatter(); f.numberStyle = .decimal
        let a = NSAlert()
        let count = f.string(from: NSNumber(value: r.files)) ?? "\(r.files)"
        if r.shortfall > 0 {
            a.alertStyle = .critical
            a.messageText = r.availableLabel == "in iCloud" ? "Not enough iCloud storage" : "Not enough space \(r.availableLabel)"
        } else if !r.blocked.isEmpty && r.blocked.count >= r.files {
            a.alertStyle = .warning
            a.messageText = r.files == 1 ? "This item can’t be copied to \(destination)" : "None of these items can be copied to \(destination)"
        } else {
            a.messageText = "\(verb) \(count) item\(r.files == 1 ? "" : "s") (\(r.bytes.byteString)) to \(destination)?"
        }
        var lines = [String]()
        if let avail = r.available { lines.append("Needs \(r.bytes.byteString); \(avail.byteString) available \(r.availableLabel)" + (r.shortfall > 0 ? " — \(r.shortfall.byteString) short." : ".")) }
        if !r.blocked.isEmpty {
            let names = r.blocked.prefix(5).map { "• \($0.name) (\($0.size.byteString)) — \($0.reason)" }.joined(separator: "\n")
            lines.append("These will be skipped:\n" + names + (r.blocked.count > 5 ? "\n• …and \(r.blocked.count - 5) more" : ""))
        }
        lines += r.cautions
        a.informativeText = lines.joined(separator: "\n\n")
        let allBlocked = !r.blocked.isEmpty && r.blocked.count >= r.files
        if allBlocked {
            a.addButton(withTitle: "OK")
        } else if r.shortfall > 0 {
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "\(verb) Anyway")
        } else {
            a.addButton(withTitle: verb)
            a.addButton(withTitle: "Cancel")
        }
        let resp = await a.present(window)
        if allBlocked { return false }
        if r.shortfall > 0 { return resp == .alertSecondButtonReturn }
        return resp == .alertFirstButtonReturn
    }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); throw CancellationError() }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

extension NSAlert {
    /// Sheet on a window when there is one, app-modal otherwise.
    func present(_ window: NSWindow?) async -> NSApplication.ModalResponse {
        if Debug.headless { Debug.log("auto-answered alert: \(messageText)"); return .alertFirstButtonReturn }
        if let window { return await beginSheetModal(for: window) }
        return runModal()
    }
}
