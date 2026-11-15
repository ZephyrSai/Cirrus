import AppKit
import CirrusCore
import UserNotifications

/// Runs sync / export / import / backup jobs as one Transfer row each.
@MainActor
final class JobRunner {
    static let shared = JobRunner()

    struct Preview {
        var plan: SyncPlan?
        var backup: BackupEngine.Evaluation?
        var photos: PhotoExporter.Evaluation?
        var importCount = 0
        var importBytes: Int64 = 0
        var summary: String
        var guardTripped: Bool
    }

    func side(_ e: SyncEndpoint, excludes: [String]) throws -> SyncSide {
        switch e {
        case .local(let p): return LocalSide(root: URL(fileURLWithPath: p, isDirectory: true), excludes: excludes)
        case .drive(let a, let fid, let path):
            guard let acct = AccountManager.shared.account(id: a), let d = acct.drive else { throw ICloudError.needsSignIn }
            return DriveSide(drive: d, rootID: fid, label: path.isEmpty ? "iCloud Drive" : (path as NSString).lastPathComponent, excludes: excludes)
        default: throw SyncError.unavailable("This endpoint can’t be used for folder sync.")
        }
    }

    func backupEngine(_ job: SyncJob) throws -> BackupEngine {
        guard case .account(let id) = job.source, let acct = AccountManager.shared.account(id: id) else { throw SyncError.unavailable("Choose an iCloud account to back up.") }
        guard let dest = job.destination.localURL else { throw SyncError.unavailable("Choose a destination folder or drive.") }
        if acct.status == .needsSignIn { throw ICloudError.needsSignIn }
        var storage: (@Sendable () async -> StorageUsage?)?
        if acct.session != nil { storage = { await acct.storageUsage() } }
        let sources = BackupEngine.Sources(accountTitle: acct.appleID ?? acct.title, drive: acct.drive, nativeDriveRoot: acct.driveRoot, photos: acct.photos,
                                           storage: storage)
        return BackupEngine(sources: sources, destination: dest, options: job.options)
    }

    func photosContext(_ e: SyncEndpoint) async throws -> (PhotosBackend, PhotoLibraryRef, PhotoAlbum?) {
        guard case .photos(let a, let lib, let albumID, _) = e, let acct = AccountManager.shared.account(id: a), let photos = acct.photos else {
            throw SyncError.unavailable("Choose a Photos library.")
        }
        let l = try await Catalog.shared.library(account: a, id: lib)
        var album: PhotoAlbum?
        if let albumID { album = try await Catalog.shared.album(account: a, library: lib, id: albumID) }
        return (photos, l, album)
    }

    /// Scan and plan without changing anything.
    func preview(_ job: SyncJob, progress: @escaping @Sendable (String) -> Void) async throws -> Preview {
        switch job.kind {
        case .folderSync:
            let a = try side(job.source, excludes: job.options.excludes), b = try side(job.destination, excludes: job.options.excludes)
            let runner = SyncRunner(a: a, b: b)
            let (sa, sb) = try await runner.scan { p in progress(p.phase) }
            let plan = SyncPlanner.plan(mode: job.mode, a: sa, b: sb, state: job.mode == .twoWay ? SyncState.load(job.id) : nil)
            return Preview(plan: plan, summary: Self.describe(plan), guardTripped: Self.guardTripped(plan, job))
        case .photosExport:
            let (pb, lib, album) = try await photosContext(job.source)
            guard let dest = job.destination.localURL else { throw SyncError.unavailable("Choose a destination folder.") }
            let ev = try await PhotoExporter(backend: pb, library: lib, album: album, destination: dest, options: job.options).evaluate(progress: progress)
            return Preview(photos: ev, summary: "\(ev.assetCount) items in iCloud; \(ev.pending.count) files (\(ev.pendingBytes.byteString)) to download, \(ev.files.count - ev.pending.count) already exported.", guardTripped: false)
        case .photosImport:
            let (files, bytes) = try importCandidates(job)
            return Preview(importCount: files.count, importBytes: bytes, summary: files.isEmpty ? "Nothing new to import." : "\(files.count) new photos and videos (\(bytes.byteString)) will be imported.", guardTripped: false)
        case .backup:
            let ev = try await backupEngine(job).evaluate(progress: progress)
            return Preview(backup: ev, summary: "Needs \(ev.pendingBytes.byteString) of \(ev.totalBytes.byteString); \(ev.free.byteString) free.", guardTripped: false)
        }
    }

    nonisolated static func guardTripped(_ plan: SyncPlan, _ job: SyncJob) -> Bool {
        let n = plan.trashCount
        let base = max(1, job.mode == .twoWay ? plan.sourceCount + plan.destinationCount : plan.destinationCount)
        return n > 20 && n * 100 / base > job.options.maxDeletePercent
    }

    static func describe(_ plan: SyncPlan) -> String {
        if plan.isEmpty { return "Everything is up to date." }
        var parts = [String]()
        let copies = plan.actions.filter { if case .copyAB = $0 { return true }; return false }.count
        let back = plan.actions.filter { if case .copyBA = $0 { return true }; return false }.count
        let conflicts = plan.actions.filter { if case .conflict = $0 { return true }; return false }.count
        let skips = plan.actions.filter { if case .skip = $0 { return true }; return false }.count
        if copies > 0 { parts.append("\(copies) to copy") }
        if back > 0 { parts.append("\(back) to copy back") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s") (both kept)") }
        if plan.trashCount > 0 { parts.append("\(plan.trashCount) to move to the Trash") }
        if skips > 0 { parts.append("\(skips) skipped") }
        return parts.joined(separator: ", ") + (plan.bytes > 0 ? " — \(plan.bytes.byteString)" : "")
    }

    struct ImportState: Codable { var done = Set<String>() }

    func importCandidates(_ job: SyncJob) throws -> ([URL], Int64) {
        guard let root = job.source.localURL else { throw SyncError.unavailable("Choose a folder to import from.") }
        let st = (try? Data(contentsOf: SyncState.urlForImport(job.id))).flatMap { try? JSONDecoder().decode(ImportState.self, from: $0) } ?? ImportState()
        var out = [URL]()
        var bytes: Int64 = 0
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            guard PhotoFormats.importable(u) else { continue }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let key = "\(u.path.dropFirst(root.path.count))|\(v?.fileSize ?? 0)"
            if st.done.contains(key) { continue }
            out.append(u)
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (out, bytes)
    }

    func run(_ job: SyncJob, window: NSWindow?, force: Bool = false) {
        guard !SyncStore.shared.running.contains(job.id) else { return }
        SyncStore.shared.running.insert(job.id)
        TransferManager.shared.runningJobs.insert(job.id)
        NotificationCenter.default.post(name: SyncStore.changed, object: nil)
        let jobID = job.id
        TransferManager.shared.enqueue(job.name, detail: "Starting…", direction: job.kind == .photosImport ? .upload : .download, group: "job:" + job.id.uuidString) { t in
            var success = false
            var message = ""
            defer {
                let s = success, m = message
                Task { @MainActor in JobRunner.shared.finished(jobID, success: s, message: m) }
            }
            do {
                let report = try await self.execute(job, force: force, transfer: t)
                success = report.failed.isEmpty
                message = report.summary + (report.failed.isEmpty ? "" : " — " + (report.failed.first ?? ""))
                t.setDetail(message)
                if !report.failed.isEmpty { throw ICloudError.server("\(report.failed.count) item\(report.failed.count == 1 ? "" : "s") failed: \(report.failed.first ?? "")") }
            } catch {
                if message.isEmpty { message = error.localizedDescription }
                throw error
            }
        }
    }

    nonisolated func execute(_ job: SyncJob, force: Bool, transfer t: Transfer) async throws -> RunReport {
        let report: @Sendable (RunProgress) -> Void = { p in
            t.report(p.bytesDone, p.bytesTotal)
            t.setDetail(p.filesTotal > 0 ? "\(p.phase) — \(p.filesDone) of \(p.filesTotal)" : p.phase)
        }
        switch job.kind {
        case .folderSync:
            let (a, b) = try await MainActor.run { (try self.side(job.source, excludes: job.options.excludes), try self.side(job.destination, excludes: job.options.excludes)) }
            let runner = SyncRunner(a: a, b: b)
            let (sa, sb) = try await runner.scan(progress: report)
            let plan = SyncPlanner.plan(mode: job.mode, a: sa, b: sb, state: job.mode == .twoWay ? SyncState.load(job.id) : nil)
            if !force && Self.guardTripped(plan, job) { throw SyncError.deleteGuard(plan.trashCount, max(plan.destinationCount, plan.sourceCount)) }
            for (side, label) in [(b, "destination"), (a, "source")] where job.mode == .twoWay || label == "destination" {
                if let free = side.freeSpace, free < plan.bytes { throw SyncError.notEnoughSpace(need: plan.bytes, free: free) }
            }
            let (rep, state) = try await runner.run(plan, a: sa, b: sb, progress: report)
            if job.mode == .twoWay && rep.failed.isEmpty { state.save(job.id) }
            return rep
        case .photosExport:
            let (pb, lib, album) = try await photosContext(job.source)
            guard let dest = job.destination.localURL else { throw SyncError.unavailable("Choose a destination folder.") }
            let ex = PhotoExporter(backend: pb, library: lib, album: album, destination: dest, options: job.options)
            let ev = try await ex.evaluate { s in t.setDetail(s) }
            if let free = VolumeInfo.freeSpace(at: dest), free < ev.pendingBytes { throw SyncError.notEnoughSpace(need: ev.pendingBytes, free: free) }
            return try await ex.run(ev, progress: report)
        case .photosImport:
            let (pb, lib, album) = try await photosContext(job.destination)
            let (files, bytes) = try await MainActor.run { try self.importCandidates(job) }
            guard !files.isEmpty, let root = job.source.localURL else { return RunReport() }
            var st = (try? Data(contentsOf: SyncState.urlForImport(job.id))).flatMap { try? JSONDecoder().decode(ImportState.self, from: $0) } ?? ImportState()
            var rep = RunReport()
            var done: Int64 = 0
            for chunk in files.chunked(25) {
                try Task.checkCancellation()
                do {
                    try await pb.importFiles(chunk, into: album, library: lib) { _, _ in }
                    for u in chunk {
                        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        st.done.insert("\(u.path.dropFirst(root.path.count))|\(size)")
                        done += Int64(size)
                        rep.copied += 1
                    }
                    rep.bytes = done
                    if let d = try? JSONEncoder().encode(st) { try? d.write(to: SyncState.urlForImport(job.id), options: .atomic) }
                } catch { rep.failed.append("\(chunk.first?.lastPathComponent ?? "") …: \(error.localizedDescription)") }
                report(RunProgress(phase: "Importing", filesDone: rep.copied, filesTotal: files.count, bytesDone: done, bytesTotal: bytes))
            }
            return rep
        case .backup:
            let engine = try await MainActor.run { try self.backupEngine(job) }
            let ev = try await engine.evaluate { s in t.setDetail(s) }
            return try await engine.run(ev, progress: report)
        }
    }

    func finished(_ id: UUID, success: Bool, message: String) {
        SyncStore.shared.running.remove(id)
        TransferManager.shared.runningJobs.remove(id)
        SyncStore.shared.record(id, success: success, message: message)
        guard let job = SyncStore.shared.job(id) else { return }
        let c = UNMutableNotificationContent()
        c.title = success ? "\(job.name) finished" : "\(job.name) needs attention"
        c.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: c, trigger: nil))
    }
}

extension SyncState {
    static func urlForImport(_ id: UUID) -> URL { Paths.supportDir("sync-state").appendingPathComponent(id.uuidString + "-import.json") }
}

/// Fires scheduled jobs: every N minutes, daily, or when a backup drive is plugged in.
@MainActor
final class JobScheduler {
    static let shared = JobScheduler()
    var timer: Timer?

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { JobScheduler.shared.tick() } }
        NotificationCenter.default.addObserver(forName: DeviceManager.volumeMounted, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let u = n.object as? URL { JobScheduler.shared.mounted(u) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.tick() }
    }

    func eligible(_ j: SyncJob) -> Bool {
        guard j.enabled, !SyncStore.shared.running.contains(j.id) else { return false }
        for id in [j.source.accountID, j.destination.accountID].compactMap({ $0 }) {
            if AccountManager.shared.account(id: id)?.status == .needsSignIn { return false }
        }
        if let dest = j.destination.localURL, !FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().path) { return false }
        return true
    }

    func tick() {
        let now = Date()
        for j in SyncStore.shared.jobs where eligible(j) {
            switch j.schedule {
            case .every(let m):
                if j.lastRun.map({ now.timeIntervalSince($0) >= Double(m * 60) }) ?? true { JobRunner.shared.run(j, window: nil) }
            case .daily(let h):
                let cal = Calendar.current
                if cal.component(.hour, from: now) >= h, !(j.lastRun.map { cal.isDateInToday($0) && cal.component(.hour, from: $0) >= h } ?? false) {
                    JobRunner.shared.run(j, window: nil)
                }
            case .whenConnected(let uuid):
                // Also catch drives that were already plugged in when Cirrus started.
                if let v = DeviceManager.shared.volumes.first(where: { Self.uuid($0.url) == uuid }), j.lastRun.map({ now.timeIntervalSince($0) > 12 * 3600 }) ?? true {
                    _ = v
                    JobRunner.shared.run(j, window: nil)
                }
            case .manual: break
            }
        }
    }

    func mounted(_ url: URL) {
        guard let uuid = Self.uuid(url) else { return }
        for j in SyncStore.shared.jobs where eligible(j) {
            if case .whenConnected(let u) = j.schedule, u == uuid {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { JobRunner.shared.run(j, window: nil) }
            }
        }
    }

    static func uuid(_ url: URL) -> String? { try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
}
