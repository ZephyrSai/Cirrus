import Foundation

/// icloudpd-style photo export: originals (+ Live Photo video, edits, RAW) into a dated folder
/// layout, incremental via a manifest, file dates set to the capture date, optional album folders.
public final class PhotoExporter: @unchecked Sendable {
    public struct PlannedFile: Sendable { public var asset: PhotoAsset; public var kind: PhotoResource.Kind; public var rel: String; public var size: Int64 }
    public struct Evaluation: Sendable {
        public var library: PhotoLibraryRef
        public var assetCount: Int
        public var files: [PlannedFile]          // everything that should exist
        public var pending: [PlannedFile]        // what still needs downloading
        public var albums: [String: [String]]    // album name → relative paths of primary files
        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
        public var pendingBytes: Int64 { pending.reduce(0) { $0 + $1.size } }
        public var largestFile: Int64 { files.map(\.size).max() ?? 0 }
    }

    struct Manifest: Codable {
        struct Entry: Codable { var files: [String]; var created: Date?; var favorite: Bool; var hidden: Bool }
        var assets: [String: Entry] = [:]
    }

    let backend: PhotosBackend
    let library: PhotoLibraryRef
    let dest: URL
    let options: SyncOptions
    let albumFilter: PhotoAlbum?

    public init(backend: PhotosBackend, library: PhotoLibraryRef, album: PhotoAlbum?, destination: URL, options: SyncOptions) {
        self.backend = backend; self.library = library; self.dest = destination; self.options = options; albumFilter = album
    }

    var manifestURL: URL { dest.appendingPathComponent(".cirrus/photos-manifest.json") }

    func loadManifest() -> Manifest {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) } ?? Manifest()
    }

    func saveManifest(_ m: Manifest) {
        try? FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: manifestURL, options: .atomic) }
    }

    static func folder(for date: Date?, layout: String) -> String {
        guard layout != "flat", !layout.isEmpty else { return "" }
        guard let date else { return "Unknown Date" }
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return layout.replacingOccurrences(of: "{yyyy}", with: String(format: "%04d", c.year ?? 0))
            .replacingOccurrences(of: "{MM}", with: String(format: "%02d", c.month ?? 0))
            .replacingOccurrences(of: "{dd}", with: String(format: "%02d", c.day ?? 0))
    }

    public func evaluate(progress: @escaping @Sendable (String) -> Void) async throws -> Evaluation {
        let albums = try await backend.albums(in: library)
        var sources = [PhotoAlbum]()
        if let a = albumFilter { sources = [a] } else {
            if let all = albums.first(where: { $0.isAllPhotos || $0.id == "smart:all" }) { sources.append(all) }
            if options.includeHidden, let h = albums.first(where: { $0.id == "smart:Hidden" || $0.name == "Hidden" && $0.kind == .smart }) { sources.append(h) }
        }
        var assets = [PhotoAsset]()
        var seen = Set<String>()
        for src in sources {
            let label = src.name
            let counter = Counter()
            let list = try await backend.assets(in: src, library: library) { batch, total in
                counter.add(files: batch.count)
                progress("Listing \(label)… \(counter.snapshot().files)\(total.map { " of \($0)" } ?? "")")
            }
            for a in list where seen.insert(a.id).inserted { assets.append(a) }
        }
        var manifest = loadManifest()
        var taken = [String: String]()   // lowercased rel → asset id
        for (id, e) in manifest.assets { for f in e.files { taken[f.lowercased()] = id } }
        var files = [PlannedFile]()
        var pending = [PlannedFile]()
        let fm = FileManager.default
        for a in assets.sorted(by: { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }) {
            var planned = [PlannedFile]()
            if let e = manifest.assets[a.id], let first = e.files.first {
                // Reuse the paths chosen on earlier runs.
                let stem = ((first as NSString).lastPathComponent as NSString).deletingPathExtension
                let dir = (first as NSString).deletingLastPathComponent
                planned = plannedFiles(a, dir: dir, stem: stem)
                for p in planned where taken[p.rel.lowercased()] == nil { taken[p.rel.lowercased()] = a.id }
            } else {
                let dir = Self.folder(for: a.created, layout: options.photoLayout)
                var stem = (a.filename as NSString).deletingPathExtension
                let ext = (a.filename as NSString).pathExtension
                func rel(_ s: String) -> String { let n = s + (ext.isEmpty ? "" : "." + ext); return dir.isEmpty ? n : dir + "/" + n }
                if let owner = taken[rel(stem).lowercased()], owner != a.id {
                    stem += "-" + String(a.id.filter { $0.isLetter || $0.isNumber }.suffix(6))
                } else if taken[rel(stem).lowercased()] == nil, let size = (try? fm.attributesOfItem(atPath: dest.appendingPathComponent(rel(stem)).path)[.size] as? Int64),
                          size != a.size, a.size > 0 {
                    // Different file already sits at this path (not ours): keep it, suffix ours.
                    stem += "-" + String(a.id.filter { $0.isLetter || $0.isNumber }.suffix(6))
                }
                planned = plannedFiles(a, dir: dir, stem: stem)
                for p in planned { taken[p.rel.lowercased()] = a.id }
                manifest.assets[a.id] = Manifest.Entry(files: planned.map(\.rel), created: a.created, favorite: a.isFavorite, hidden: a.isHidden)
            }
            for p in planned {
                files.append(p)
                let size = (try? fm.attributesOfItem(atPath: dest.appendingPathComponent(p.rel).path)[.size] as? Int64) ?? -1
                if size < 0 || (p.size > 0 && size != p.size) { pending.append(p) }
            }
        }
        _ = manifest
        var albumMap = [String: [String]]()
        if (options.writeManifest || options.albumFolders) && albumFilter == nil {
            let primary = Dictionary(files.filter { $0.kind == .original }.map { ($0.asset.id, $0.rel) }, uniquingKeysWith: { a, _ in a })
            for al in albums where al.kind == .album || al.kind == .shared {
                progress("Reading album “\(al.name)”…")
                let list = (try? await backend.assets(in: al, library: library) { _, _ in }) ?? []
                albumMap[al.name] = list.compactMap { primary[$0.id] }
            }
        }
        return Evaluation(library: library, assetCount: assets.count, files: files, pending: pending, albums: albumMap)
    }

    func plannedFiles(_ a: PhotoAsset, dir: String, stem: String) -> [PlannedFile] {
        func rel(_ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }
        let ext = (a.filename as NSString).pathExtension
        var out = [PlannedFile(asset: a, kind: .original, rel: rel(stem + (ext.isEmpty ? "" : "." + ext)), size: a.resource(.original)?.size ?? a.size)]
        if options.includeLive, let r = a.resource(.liveVideo) { out.append(PlannedFile(asset: a, kind: .liveVideo, rel: rel(stem + ".MOV"), size: r.size)) }
        if options.includeEdited, let r = a.resource(.edited) {
            let e = (r.filename as NSString).pathExtension
            out.append(PlannedFile(asset: a, kind: .edited, rel: rel(stem + "-edited" + (e.isEmpty ? "" : "." + e)), size: r.size))
        }
        if options.includeRAW, let r = a.resource(.alternate) {
            var e = (r.filename as NSString).pathExtension
            if e.isEmpty { e = "dng" }
            let name = e.lowercased() == ext.lowercased() ? stem + "-alt." + e : stem + "." + e
            out.append(PlannedFile(asset: a, kind: .alternate, rel: rel(name), size: r.size))
        }
        return out
    }

    public func run(_ eval: Evaluation, concurrency: Int = 4, progress: @escaping @Sendable (RunProgress) -> Void) async throws -> RunReport {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let total = eval.pendingBytes
        let counter = Counter()
        let report = ReportBox()
        let n = eval.pending.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = eval.pending.makeIterator()
            var inFlight = 0
            func next() -> Bool {
                guard let p = it.next() else { return false }
                inFlight += 1
                group.addTask {
                    try Task.checkCancellation()
                    let target = self.dest.appendingPathComponent(p.rel)
                    let tmp = target.deletingLastPathComponent().appendingPathComponent(".cirrus-part-" + target.lastPathComponent)
                    let mark = ByteMark()
                    var attempt = 0
                    while true {
                        do {
                            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try await self.backend.export(p.asset, resource: p.kind, to: tmp) { d, _ in
                                let delta = mark.advance(to: d)
                                if delta > 0 { counter.add(bytes: delta) }
                                let c = counter.snapshot()
                                progress(RunProgress(phase: "Downloading \(p.asset.filename)", filesDone: c.files, filesTotal: n, bytesDone: c.bytes, bytesTotal: total))
                            }
                            let got = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
                            if self.options.verify, p.size > 0, got != p.size, attempt == 0 {
                                attempt += 1
                                continue
                            }
                            try? fm.removeItem(at: target)
                            try fm.moveItem(at: tmp, to: target)
                            if let d = p.asset.created { try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: target.path) }
                            report.mutate { $0.copied += 1; $0.bytes += got }
                            break
                        } catch is CancellationError {
                            try? fm.removeItem(at: tmp)
                            throw CancellationError()
                        } catch {
                            try? fm.removeItem(at: tmp)
                            if attempt < 2 { attempt += 1; try? await Task.sleep(nanoseconds: 1_500_000_000); continue }
                            report.fail(p.rel, error)
                            break
                        }
                    }
                    counter.add(files: 1)
                    let c = counter.snapshot()
                    progress(RunProgress(phase: "Downloading photos…", filesDone: c.files, filesTotal: n, bytesDone: c.bytes, bytesTotal: total))
                }
                return true
            }
            while inFlight < concurrency && next() {}
            while try await group.next() != nil {
                inFlight -= 1
                while inFlight < concurrency && next() {}
            }
        }
        writeManifest(eval)
        if options.albumFolders { makeAlbumFolders(eval) }
        return report.value
    }

    func writeManifest(_ eval: Evaluation) {
        var m = loadManifest()
        for f in eval.files where f.kind == .original {
            let all = eval.files.filter { $0.asset.id == f.asset.id }.map(\.rel)
            m.assets[f.asset.id] = Manifest.Entry(files: all, created: f.asset.created, favorite: f.asset.isFavorite, hidden: f.asset.isHidden)
        }
        saveManifest(m)
        guard options.writeManifest else { return }
        var csv = "path,filename,taken,favorite,hidden,width,height,live,edited,albums\n"
        var albumsFor = [String: [String]]()
        for (name, rels) in eval.albums { for r in rels { albumsFor[r, default: []].append(name) } }
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for f in eval.files where f.kind == .original {
            let a = f.asset
            csv += [q(f.rel), q(a.filename), a.created.map { iso.string(from: $0) } ?? "", a.isFavorite ? "1" : "0", a.isHidden ? "1" : "0",
                    String(a.width), String(a.height), a.isLive ? "1" : "0", a.isEdited ? "1" : "0", q((albumsFor[f.rel] ?? []).joined(separator: "; "))].joined(separator: ",") + "\n"
        }
        try? Data(csv.utf8).write(to: dest.appendingPathComponent("Photos manifest.csv"), options: .atomic)
        if !eval.albums.isEmpty, let d = try? JSONSerialization.data(withJSONObject: eval.albums, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dest.appendingPathComponent("Albums.json"), options: .atomic)
        }
    }

    /// Albums as folders of relative symlinks (no extra space). Skipped on volumes without symlinks.
    func makeAlbumFolders(_ eval: Evaluation) {
        let fm = FileManager.default
        let root = dest.appendingPathComponent("Albums", isDirectory: true)
        for (name, rels) in eval.albums {
            let dir = root.appendingPathComponent(Paths.safeName(name), isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for r in rels {
                let link = dir.appendingPathComponent((r as NSString).lastPathComponent)
                if fm.fileExists(atPath: link.path) { continue }
                do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../" + r) } catch { return }
            }
        }
    }
}

/// Full-account backup: evaluate sizes vs destination space, then copy iCloud Drive and every
/// Photos library (originals with companions) into <destination>/Cirrus Backup/<account>/.
public final class BackupEngine: @unchecked Sendable {
    public struct Evaluation: Sendable {
        public var storage: StorageUsage?
        public var driveFiles = 0
        public var driveBytes: Int64 = 0
        public var drivePendingBytes: Int64 = 0
        public var drivePlans: [(label: String, plan: SyncPlan, a: [String: SideEntry], b: [String: SideEntry], source: SyncSide, dest: SyncSide)] = []
        public var photos: [PhotoExporter.Evaluation] = []
        public var exporters: [PhotoExporter] = []
        public var free: Int64 = 0
        public var volume: VolumeInfo?
        public var warnings: [String] = []
        public var photosBytes: Int64 { photos.reduce(0) { $0 + $1.totalBytes } }
        public var photosPendingBytes: Int64 { photos.reduce(0) { $0 + $1.pendingBytes } }
        public var photoCount: Int { photos.reduce(0) { $0 + $1.assetCount } }
        public var totalBytes: Int64 { driveBytes + photosBytes }
        public var pendingBytes: Int64 { drivePendingBytes + photosPendingBytes }
        /// Free space must cover what's left plus 2 % and 1 GB of headroom.
        public var requiredFree: Int64 { pendingBytes + pendingBytes / 50 + (pendingBytes > 0 ? 1 << 30 : 0) }
        public var fits: Bool { free >= requiredFree }
    }

    public struct Sources: Sendable {
        public var accountTitle: String
        public var drive: DriveBackend?
        public var nativeDriveRoot: URL?
        public var photos: PhotosBackend?
        public var storage: (@Sendable () async -> StorageUsage?)?
        public init(accountTitle: String, drive: DriveBackend?, nativeDriveRoot: URL?, photos: PhotosBackend?, storage: (@Sendable () async -> StorageUsage?)?) {
            self.accountTitle = accountTitle; self.drive = drive; self.nativeDriveRoot = nativeDriveRoot; self.photos = photos; self.storage = storage
        }
    }

    let sources: Sources
    let destination: URL
    let options: SyncOptions

    public init(sources: Sources, destination: URL, options: SyncOptions) {
        self.sources = sources; self.destination = destination; self.options = options
    }

    public var accountRoot: URL {
        destination.appendingPathComponent("Cirrus Backup", isDirectory: true).appendingPathComponent(Paths.safeName(sources.accountTitle), isDirectory: true)
    }

    public func evaluate(progress: @escaping @Sendable (String) -> Void) async throws -> Evaluation {
        var ev = Evaluation()
        progress("Checking the destination…")
        ev.volume = VolumeInfo.info(for: destination)
        ev.free = VolumeInfo.freeSpace(at: destination) ?? 0
        if let s = sources.storage { progress("Reading iCloud storage…"); ev.storage = await s() }
        let driveDest = accountRoot.appendingPathComponent("iCloud Drive", isDirectory: true)
        if options.includeDrive {
            var pairs = [(String, SyncSide, SyncSide)]()
            if let d = sources.drive {
                pairs.append(("iCloud Drive", DriveSide(drive: d, rootID: d.rootID, label: "iCloud Drive", excludes: options.excludes),
                              LocalSide(root: driveDest, excludes: options.excludes, createIfMissing: true)))
            } else if let root = sources.nativeDriveRoot {
                pairs.append(("iCloud Drive", LocalSide(root: root, excludes: options.excludes), LocalSide(root: driveDest, excludes: options.excludes, createIfMissing: true)))
                for c in NativeICloud.appContainers(root: root) {
                    pairs.append((c.name, LocalSide(root: c.url, excludes: options.excludes),
                                  LocalSide(root: driveDest.appendingPathComponent(Paths.safeName(c.name), isDirectory: true), excludes: options.excludes, createIfMissing: true)))
                }
            }
            for (label, src, dst) in pairs {
                progress("Scanning \(label)…")
                let a = try await src.scan { n in progress("Scanning \(label)… \(n) items") }
                let b = try await dst.scan(progress: nil)
                var plan = SyncPlanner.plan(mode: options.keepDeleted ? .copy : .mirror, a: a, b: b, state: nil)
                // Backups never lose what they hold because iCloud briefly answered with an empty or partial list.
                if plan.wipesSide || (plan.trashItemsB > 20 && plan.trashItemsB * 2 > b.count) {
                    plan.actions.removeAll(where: \.isDestructive)
                    ev.warnings.append("\(label): this run would have removed \(plan.trashItemsB) of \(b.count) backed-up items. They were kept; if you really deleted them in iCloud, remove them from the backup yourself.")
                    plan.trashItemsB = 0
                }
                ev.driveFiles += a.values.filter { !$0.isDir }.count
                ev.driveBytes += a.values.filter { !$0.isDir }.reduce(0) { $0 + $1.size }
                ev.drivePendingBytes += plan.bytes
                ev.drivePlans.append((label, plan, a, b, src, dst))
            }
        }
        if options.includePhotos, let pb = sources.photos {
            let libs = try await pb.libraries()
            for lib in libs where !lib.isShared || options.includeSharedLibrary {
                let dir = accountRoot.appendingPathComponent("Photos", isDirectory: true).appendingPathComponent(Paths.safeName(lib.name), isDirectory: true)
                let ex = PhotoExporter(backend: pb, library: lib, album: nil, destination: dir, options: options)
                let e = try await ex.evaluate(progress: progress)
                ev.photos.append(e)
                ev.exporters.append(ex)
            }
        }
        // Warnings
        if let v = ev.volume, let fmt = v.format?.lowercased(), fmt.contains("fat") && !fmt.contains("exfat") {
            let big = ev.photos.contains { $0.largestFile >= 4_294_967_295 } || ev.drivePlans.contains { $0.a.values.contains { $0.size >= 4_294_967_295 } }
            ev.warnings.append("“\(v.name)” is formatted as \(v.format ?? "FAT32"), which can’t hold files over 4 GB" + (big ? " — some of your files are larger and will fail. Reformat as APFS or exFAT." : "."))
        }
        if options.albumFolders, let fmt = ev.volume?.format?.lowercased(), fmt.contains("fat") {
            ev.warnings.append("Album folders use symbolic links, which this drive’s format doesn’t support; they’ll be skipped.")
        }
        if !ev.fits {
            ev.warnings.append("Not enough space: this backup needs \(ev.requiredFree.byteString) free (including headroom) but only \(ev.free.byteString) is available.")
        }
        if let s = ev.storage, s.used > 0 {
            let other = s.categories.filter { !["photos", "docs", "documents"].contains($0.key.lowercased()) }.reduce(0) { $0 + $1.bytes }
            if other > 0 { ev.warnings.append("\(other.byteString) of your iCloud storage (device backups, Mail, Messages and app data) can’t be downloaded through iCloud.com and isn’t included.") }
        }
        #if os(macOS)
        let encryptHint = "use an encrypted APFS drive (Disk Utility › Erase › APFS (Encrypted))"
        let internalWarning = "The destination is this Mac’s startup disk. For a real backup, choose an external drive."
        #else
        let encryptHint = "use a drive formatted as APFS (Encrypted) on a Mac"
        let internalWarning = "The destination is this device’s own storage. For a real backup, choose a USB drive or a folder on another device."
        #endif
        if let v = ev.volume, !v.isRoot, (try? v.url.resourceValues(forKeys: [.volumeIsEncryptedKey]).volumeIsEncrypted) == false {
            ev.warnings.append("“\(v.name)” isn’t encrypted, so anyone with the drive can read this backup. For private data, \(encryptHint).")
        }
        if ev.volume?.isRoot == true {
            ev.warnings.append(internalWarning)
        }
        return ev
    }

    public func run(_ ev: Evaluation, progress: @escaping @Sendable (RunProgress) -> Void) async throws -> RunReport {
        guard ev.fits else { throw SyncError.notEnoughSpace(need: ev.requiredFree, free: ev.free) }
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        var total = RunReport()
        let overall = ev.pendingBytes
        let base = Counter()
        for p in ev.drivePlans {
            try Task.checkCancellation()
            let runner = SyncRunner(a: p.source, b: p.dest)
            let before = base.snapshot().bytes
            let (r, _) = try await runner.run(p.plan, a: p.a, b: p.b) { rp in
                progress(RunProgress(phase: "\(p.label): \(rp.phase)", filesDone: rp.filesDone, filesTotal: rp.filesTotal, bytesDone: before + rp.bytesDone, bytesTotal: overall))
            }
            base.add(bytes: p.plan.bytes)
            total.copied += r.copied; total.bytes += r.bytes; total.trashed += r.trashed; total.failed += r.failed; total.skipped += r.skipped
        }
        for (i, e) in ev.photos.enumerated() {
            try Task.checkCancellation()
            let before = base.snapshot().bytes
            let r = try await ev.exporters[i].run(e) { rp in
                progress(RunProgress(phase: "Photos (\(e.library.name)): \(rp.phase)", filesDone: rp.filesDone, filesTotal: rp.filesTotal, bytesDone: before + rp.bytesDone, bytesTotal: overall))
            }
            base.add(bytes: e.pendingBytes)
            total.copied += r.copied; total.bytes += r.bytes; total.failed += r.failed
        }
        writeInfo(ev, report: total)
        return total
    }

    func writeInfo(_ ev: Evaluation, report: RunReport) {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short
        var s = "Cirrus backup of \(sources.accountTitle)\nLast run: \(f.string(from: Date()))\n\n"
        s += "iCloud Drive: \(ev.driveFiles) files, \(ev.driveBytes.byteString)\n"
        for p in ev.photos { s += "Photos — \(p.library.name): \(p.assetCount) items, \(p.totalBytes.byteString)\n" }
        s += "\nThis run: \(report.summary)\n"
        if !report.failed.isEmpty { s += "\nProblems:\n" + report.failed.prefix(200).map { "  • " + $0 }.joined(separator: "\n") + "\n" }
        s += "\nLayout:\n  iCloud Drive/ — your iCloud Drive files and folders\n  Photos/<library>/YYYY/MM/ — originals, Live Photo videos (.MOV), edits (-edited) and RAW files, dated by capture time\n  Photos/<library>/Photos manifest.csv — favorites, hidden flags and album membership\n"
        s += "\nFiles are only ever added or updated here; nothing is deleted from iCloud.\n"
        try? Data(s.utf8).write(to: accountRoot.appendingPathComponent("Backup Info.txt"), options: .atomic)
    }
}

/// Native iCloud Drive helpers (Mac signed in to iCloud).
public enum NativeICloud {
    public struct Container { public var name: String; public var url: URL }

    /// App folders shown at the top level of iCloud Drive (Pages, Numbers, Shortcuts…).
    public static func appContainers(root: URL) -> [Container] {
        let mobile = root.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mobile.path) else { return [] }
        var out = [Container]()
        for n in names where n != root.lastPathComponent && !n.hasPrefix(".") {
            let docs = mobile.appendingPathComponent(n).appendingPathComponent("Documents", isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let display = FileManager.default.displayName(atPath: mobile.appendingPathComponent(n).path)
            let name = display.contains("~") ? (n.split(separator: "~").last.map(String.init) ?? n) : display
            out.append(Container(name: name, url: docs))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
