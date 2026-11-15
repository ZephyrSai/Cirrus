import AppKit
import CirrusCore
import UniformTypeIdentifiers

/// Where dropped / pasted items should end up.
@MainActor
enum Destination {
    case local(URL)
    case drive(Account, String)
    case photos(Account, PhotoLibraryRef, PhotoAlbum?)

    var title: String {
        switch self {
        case .local(let u): return FileManager.default.displayName(atPath: u.path)
        case .drive(let a, let id): return Catalog.shared.title(.drive(a.id, id))
        case .photos(_, _, let al): return al?.name ?? "Photos"
        }
    }
}

enum ConflictChoice { case replace, keepBoth, skip, stop }

@MainActor
final class Ops {
    static let shared = Ops()
    var openedFiles = [(url: URL, item: Item, mtime: Date)]()

    // MARK: Destinations

    func destination(for loc: Location) async -> Destination? {
        switch loc {
        case .local(let p): return Catalog.shared.caps(loc).acceptsDrops ? .local(URL(fileURLWithPath: p, isDirectory: true)) : nil
        case .drive(let a, let id): return AccountManager.shared.account(id: a).map { .drive($0, id) }
        case .photos(let a, let lib, _):
            guard let acct = AccountManager.shared.account(id: a), let l = try? await Catalog.shared.library(account: a, id: lib) else { return nil }
            return .photos(acct, l, nil)
        case .album(let a, let lib, let id):
            guard let acct = AccountManager.shared.account(id: a), let l = try? await Catalog.shared.library(account: a, id: lib),
                  let al = try? await Catalog.shared.album(account: a, library: lib, id: id) else { return nil }
            return .photos(acct, l, al.kind == .album ? al : nil)
        default: return nil
        }
    }

    func destination(forItem item: Item) async -> Destination? {
        guard item.isContainer, let t = item.target else { return nil }
        if case .album(let a) = item.payload, a.kind == .smart, !a.isAllPhotos, a.id != "smart:all" { return nil }
        return await destination(for: t)
    }

    func refresh(_ loc: Location) {
        Catalog.shared.invalidate(loc)
        NotificationCenter.default.post(name: .cirrusLocationChanged, object: loc)
    }

    func refresh(_ d: Destination) {
        switch d {
        case .local(let u): refresh(.local(u.path))
        case .drive(let a, let id): refresh(.drive(a.id, id))
        case .photos(let a, let l, let al):
            if let al { refresh(.album(a.id, l.id, al.id)) }
            refresh(.album(a.id, l.id, "smart:All Photos")); refresh(.album(a.id, l.id, "smart:all")); refresh(.photos(a.id, l.id, nil))
        }
    }

    // MARK: Conflicts

    func existingNames(_ dest: Destination) async -> Set<String> {
        switch dest {
        case .local(let u): return Set(((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).map { $0.lowercased() })
        case .drive(let a, let id): return Set(((try? await a.drive?.list(id)) ?? []).map { $0.name.lowercased() })
        case .photos: return []
        }
    }

    nonisolated static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        var n = name
        while taken.contains(n.lowercased()) {
            n = "\(stem) \(i)" + (ext.isEmpty ? "" : "." + ext)
            i += 1
        }
        return n
    }

    /// Asks once per clash (with “Apply to All”). Returns the final name or nil to skip.
    func resolveNames(_ names: [String], in dest: Destination, window: NSWindow?) async -> [String: String?]? {
        var taken = await existingNames(dest)
        var out = [String: String?]()
        var applyAll: ConflictChoice?
        for n in names {
            if !taken.contains(n.lowercased()) { out[n] = n; taken.insert(n.lowercased()); continue }
            let choice: ConflictChoice
            if let a = applyAll { choice = a } else { choice = await askConflict(n, dest: dest, window: window, remaining: names.count > 1) }
            switch choice {
            case .stop: return nil
            case .skip: out[n] = .some(nil)
            case .replace: out[n] = "!replace:" + n
            case .keepBoth:
                let u = Self.uniqueName(n, taken: taken)
                taken.insert(u.lowercased())
                out[n] = u
            }
            if conflictApplyAll { applyAll = choice }
        }
        return out
    }

    var conflictApplyAll = false

    func askConflict(_ name: String, dest: Destination, window: NSWindow?, remaining: Bool) async -> ConflictChoice {
        if let auto = Debug.autoConflict {
            conflictApplyAll = true
            return ["replace": .replace, "skip": .skip, "stop": .stop][auto] ?? .keepBoth
        }
        let alert = NSAlert()
        alert.messageText = "An item named “\(name)” already exists in “\(dest.title)”."
        alert.informativeText = "Replace moves the existing item to the Trash first."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        if remaining { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Apply to all" }
        let resp = await alert.present(window)
        conflictApplyAll = alert.suppressionButton?.state == .on
        switch resp {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return .stop
        }
    }

    func displayError(_ error: Error, title: String, window: NSWindow?) {
        if case ICloudError.cancelled = error { return }
        if error is CancellationError { return }
        if Debug.headless { Debug.log("error alert: \(title): \(error.localizedDescription)"); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = error.localizedDescription
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    // MARK: Transfers (the copy/move matrix)

    /// Local files (from Finder, another app, or this app's local panes) into a destination.
    func deliver(files: [URL], to dest: Destination, move: Bool, window: NSWindow?, cleanupTemp: URL? = nil) async {
        guard !files.isEmpty else { return }
        var files = files
        if cleanupTemp == nil {
            let verb: String
            switch dest { case .local: verb = move ? "Move" : "Copy"; case .drive: verb = "Upload"; case .photos: verb = "Import" }
            let pre = await Preflight.checkUpload(files, to: dest, move: move)
            guard await Preflight.confirm(pre, verb: verb, destination: "“\(dest.title)”", window: window) else { return }
            let blocked = pre.blockedNames
            files = files.filter { !blocked.contains($0.lastPathComponent) }
            guard !files.isEmpty else { return }
        }
        if move && cleanupTemp == nil {
            do { for f in files { try SafetyPolicy.checkLocalWrite(f) } } catch { displayError(error, title: "iCloud is read-only", window: window); return }
        }
        let group = cleanupTemp.map { "relay:" + $0.lastPathComponent }
        defer {
            if let c = cleanupTemp, let g = group {
                Task { @MainActor in await TransferManager.shared.waitForGroup(g); try? FileManager.default.removeItem(at: c) }
            }
        }
        switch dest {
        case .local(let dir):
            do { try SafetyPolicy.checkLocalWrite(dir) } catch { displayError(error, title: "iCloud is read-only", window: window); return }
            guard let names = await resolveNames(files.map(\.lastPathComponent), in: dest, window: window) else { return }
            for f in files {
                guard let entry = names[f.lastPathComponent], let target = entry else { continue }
                let replace = target.hasPrefix("!replace:")
                let finalName = replace ? String(target.dropFirst(9)) : target
                let dst = dir.appendingPathComponent(finalName)
                if f.standardizedFileURL == dst.standardizedFileURL { continue }
                let sameVolume = Self.sameVolume(f, dir)
                let isMove = move || cleanupTemp != nil
                TransferManager.shared.enqueue(f.lastPathComponent, detail: (isMove && sameVolume ? "Moving to " : "Copying to ") + dest.title,
                                               direction: .copy, total: (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0, group: group,
                                               quotaKey: isMove && sameVolume ? nil : Preflight.volumeKey(dir)) { t in
                    try await LocalFiles.ensureDownloaded(f)
                    if replace {
                        // New copy goes in beside the old one first; the old one is retired only after that worked.
                        try LocalFiles.swapIn(f, at: dst, move: isMove && sameVolume)
                        if move && !sameVolume { try? LocalFiles.safeTrash(f, root: nil) }
                    } else if isMove && sameVolume { try FileManager.default.moveItem(at: f, to: dst) }
                    else {
                        try FileManager.default.copyItem(at: f, to: dst)
                        if move { try? LocalFiles.safeTrash(f, root: nil) }
                    }
                    t.resultURL = dst
                    await MainActor.run { Ops.shared.refresh(dest); if move { Ops.shared.refresh(.local(f.deletingLastPathComponent().path)) } }
                }
            }
        case .drive(let acct, let folderID):
            guard let drive = acct.drive else { return }
            guard let names = await resolveNames(files.map(\.lastPathComponent), in: dest, window: window) else { return }
            let existing = (try? await drive.list(folderID)) ?? []
            for f in files {
                guard let entry = names[f.lastPathComponent], let target = entry else { continue }
                let replace = target.hasPrefix("!replace:")
                let finalName = replace ? String(target.dropFirst(9)) : target
                let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { ($0.isDirectory ?? false) && !($0.isPackage ?? false) } ?? false
                let old = existing.first { $0.name.lowercased() == finalName.lowercased() }
                if isDir {
                    TransferManager.shared.enqueue(finalName, detail: "Uploading folder to \(dest.title)", direction: .upload, group: group, quotaKey: "icloud:" + acct.id) { t in
                        let folder: DriveNode
                        var retire: DriveNode?
                        if let old, old.isFolder, !replace { folder = old } else if replace, let old {
                            // Build the replacement beside the old folder; retire the old one only after it uploads.
                            folder = try await drive.createFolder(".cirrus-upload-\(UUID().uuidString.prefix(8))-" + finalName, in: folderID)
                            retire = old
                        } else {
                            folder = try await drive.createFolder(finalName, in: folderID)
                        }
                        let runner = SyncRunner(a: LocalSide(root: f, excludes: SyncOptions().excludes), b: DriveSide(drive: drive, rootID: folder.id, label: finalName, excludes: []))
                        let (sa, sb) = try await runner.scan { p in t.setDetail(p.phase) }
                        let plan = SyncPlanner.plan(mode: .copy, a: sa, b: sb, state: nil)
                        t.report(0, plan.bytes)
                        let (rep, _) = try await runner.run(plan, a: sa, b: sb) { p in t.report(p.bytesDone, p.bytesTotal); t.setDetail("\(p.filesDone) of \(p.filesTotal) items") }
                        if !rep.failed.isEmpty { throw ICloudError.server("\(rep.failed.count) items failed: \(rep.failed.first ?? "")") }
                        if let retire {
                            try await drive.trash([retire])
                            _ = try await drive.rename(folder, to: finalName)
                        }
                        if move {
                            let left = SyncPlanner.notCopied(plan, a: sa, b: sb)
                            if left.isEmpty { try? LocalFiles.safeTrash(f, root: nil) }
                            else { throw ICloudError.server("Uploaded, but kept the original folder: \(left.count) item\(left.count == 1 ? "" : "s") in iCloud differ (e.g. “\(left[0])”).") }
                        }
                        await MainActor.run { Ops.shared.refresh(dest) }
                    }
                } else {
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    TransferManager.shared.enqueue(finalName, detail: "Uploading to \(dest.title)", direction: .upload, total: size, group: group, quotaKey: "icloud:" + acct.id) { t in
                        try await LocalFiles.ensureDownloaded(f)
                        let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        // Upload first; only then retire the old copy (safeReplace).
                        _ = try await drive.safeReplace(f, name: finalName, in: folderID, existing: replace ? old : nil, modified: mtime) { d, tot in t.report(d, tot) }
                        if move { try? LocalFiles.safeTrash(f, root: nil) }
                        await MainActor.run { Ops.shared.refresh(dest) }
                    }
                }
            }
        case .photos(let acct, let lib, let album):
            guard let photos = acct.photos else { return }
            var all = [URL]()
            for f in files { all += Self.importableFiles(f) }
            guard !all.isEmpty else {
                displayError(ICloudError.server("None of these files are photos or videos."), title: "Nothing to import", window: window)
                return
            }
            let total = all.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
            TransferManager.shared.enqueue("Importing \(all.count) item\(all.count == 1 ? "" : "s")", detail: "To \(album?.name ?? "Photos")", direction: .upload, total: total, group: group, quotaKey: "icloud:" + acct.id) { t in
                for f in all { try await LocalFiles.ensureDownloaded(f) }
                try await photos.importFiles(all, into: album, library: lib) { d, tot in t.report(d, tot) }
                await MainActor.run { Ops.shared.refresh(dest) }
            }
        }
    }

    static func importableFiles(_ url: URL) -> [URL] {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDir { return PhotoFormats.importable(url) ? [url] : [] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var out = [URL]()
        while let u = e?.nextObject() as? URL { if PhotoFormats.importable(u) { out.append(u) } }
        return out
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        return va != nil && va == vb
    }

    /// Items shown in Cirrus (any source) into a destination.
    func transfer(_ items: [Item], to dest: Destination, move: Bool, window: NSWindow?) async {
        let local = items.compactMap(\.localURL)
        if !local.isEmpty { await deliver(files: local, to: dest, move: move, window: window) }
        let remote = items.filter { $0.localURL == nil }
        guard !remote.isEmpty else { return }
        // Same-service fast paths.
        if case .drive(let acct, let folderID) = dest, let drive = acct.drive {
            let same = remote.filter { $0.driveNode != nil && $0.account == acct.id }
            if !same.isEmpty && !NSEvent.modifierFlags.contains(.option) {
                let nodes = same.compactMap(\.driveNode).filter { $0.id != folderID && $0.parentID != folderID }
                if !nodes.isEmpty {
                    TransferManager.shared.enqueue(nodes.count == 1 ? nodes[0].name : "\(nodes.count) items", detail: "Moving to \(dest.title)", direction: .other) { _ in
                        try await drive.move(nodes, to: folderID)
                        await MainActor.run {
                            Ops.shared.refresh(dest)
                            for p in Set(nodes.compactMap(\.parentID)) { Ops.shared.refresh(.drive(acct.id, p)) }
                        }
                    }
                }
                let rest = remote.filter { !same.contains($0) }
                if !rest.isEmpty { await viaTemp(rest, to: dest, window: window) }
                return
            }
        }
        if case .photos(let acct, let lib, let album) = dest, let photos = acct.photos {
            let same = remote.filter { $0.photo != nil && $0.account == acct.id }
            if !same.isEmpty {
                if let album {
                    let assets = same.compactMap(\.photo)
                    TransferManager.shared.enqueue("Adding \(assets.count) to “\(album.name)”", direction: .other) { _ in
                        try await photos.add(assets, to: album, library: lib)
                        await MainActor.run { Ops.shared.refresh(dest) }
                    }
                }
                let rest = remote.filter { !same.contains($0) }
                if !rest.isEmpty { await viaTemp(rest, to: dest, window: window) }
                return
            }
        }
        if case .local(let dir) = dest {
            await download(remote, to: dir, window: window, moveSource: move)
            return
        }
        await viaTemp(remote, to: dest, window: window)
    }

    /// Remote → remote across services: materialize into a temp folder, then deliver.
    func viaTemp(_ items: [Item], to dest: Destination, window: NSWindow?) async {
        var items = items
        var pre = PreflightResult()
        pre.files = items.count
        pre.bytes = items.reduce(0) { $0 + $1.transferSize }
        switch dest {
        case .drive(let acct, _):
            pre.available = await Preflight.iCloudFree(acct); pre.availableLabel = "in iCloud"
            for i in items where i.transferSize > Limits.iCloudDriveMax { pre.blocked.append((i.name, i.transferSize, "larger than iCloud Drive’s 50 GB limit")) }
        case .photos(let acct, _, _):
            if acct.kind == .web { pre.available = await Preflight.iCloudFree(acct); pre.availableLabel = "in iCloud" }
        case .local: break
        }
        guard await Preflight.confirm(pre, verb: "Copy", destination: "“\(dest.title)”", window: window) else { return }
        let blocked = pre.blockedNames
        items = items.filter { !blocked.contains($0.name) }
        guard !items.isEmpty else { return }
        let tmp = Paths.cacheDir("relay").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let t = TransferManager.shared.enqueue("Preparing \(items.count) item\(items.count == 1 ? "" : "s")", detail: "Downloading before sending to \(dest.title)", direction: .download, total: items.reduce(0) { $0 + $1.transferSize }) { t in
            let done = Counter2()
            for item in items {
                let base = done.value
                _ = try await Ops.materialize(item, into: tmp, exportLive: Prefs.exportLive) { d, _ in t.report(base + d, 0) }
                done.add(item.transferSize)
            }
        }
        Task { @MainActor in
            while !t.isFinished { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard t.state == .done else { try? FileManager.default.removeItem(at: tmp); return }
            let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            await self.deliver(files: files, to: dest, move: false, window: window, cleanupTemp: tmp)
        }
    }

    /// Remote items (Drive, Photos, devices, albums) into a local folder, with conflict handling.
    func download(_ items: [Item], to dir: URL, window: NSWindow?, moveSource: Bool = false) async {
        let dest = Destination.local(dir)
        let pre = await Preflight.checkDownload(items, to: dir)
        guard await Preflight.confirm(pre, verb: "Download", destination: "“\(dest.title)”", window: window) else { return }
        let blocked = pre.blockedNames
        let items = items.filter { !blocked.contains($0.name) }
        guard !items.isEmpty else { return }
        let vol = Preflight.volumeKey(dir)
        guard let names = await resolveNames(items.map { Ops.outputName($0) }, in: dest, window: window) else { return }
        let exportLive = Prefs.exportLive
        var photoBatch = [(PhotoAsset, String, Bool, Account)]()
        for item in items {
            guard let entry = names[Ops.outputName(item)], let target = entry else { continue }
            let replace = target.hasPrefix("!replace:")
            let finalName = replace ? String(target.dropFirst(9)) : target
            if let p = item.photo, let acct = item.account.flatMap({ AccountManager.shared.account(id: $0) }) {
                photoBatch.append((p, finalName, replace, acct))
                continue
            }
            TransferManager.shared.enqueue(finalName, detail: "Downloading to \(dest.title)", direction: .download, total: item.transferSize, quotaKey: vol) { t in
                let staging = Paths.cacheDir("tmp").appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let got = try await Ops.materialize(item, into: staging, exportLive: exportLive, nameOverride: finalName) { d, tot in t.report(d, tot) }
                let target = dir.appendingPathComponent(finalName)
                for f in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [got] {
                    let dst = dir.appendingPathComponent(f.lastPathComponent)
                    if f.lastPathComponent == finalName && replace { try LocalFiles.swapIn(f, at: dst, move: true); continue }
                    if FileManager.default.fileExists(atPath: dst.path) { continue }
                    try FileManager.default.moveItem(at: f, to: dst)
                }
                t.resultURL = target
                if moveSource, let n = item.driveNode {
                    let drive = await MainActor.run { item.account.flatMap { AccountManager.shared.account(id: $0) }?.drive }
                    try await drive?.trash([n])
                }
                await MainActor.run { Ops.shared.refresh(dest) }
            }
        }
        if !photoBatch.isEmpty {
            let total = photoBatch.reduce(Int64(0)) { $0 + $1.0.exportSize(includeLive: exportLive, includeEdited: Prefs.exportEdited, includeRAW: false) }
            let edited = Prefs.exportEdited
            TransferManager.shared.enqueue(photoBatch.count == 1 ? photoBatch[0].1 : "Exporting \(photoBatch.count) photos", detail: "To \(dest.title)", direction: .download, total: total, quotaKey: vol) { t in
                let done = Counter2()
                try await withThrowingTaskGroup(of: Void.self) { g in
                    var it = photoBatch.makeIterator()
                    var n = 0
                    func next() -> Bool {
                        guard let (p, name, replace, acct) = it.next(), let backend = acct.photos else { return false }
                        n += 1
                        g.addTask {
                            let target = dir.appendingPathComponent(name)
                            let kind: PhotoResource.Kind = edited && p.resource(.edited) != nil ? .edited : .original
                            let base = done.value
                            if replace {
                                let staged = dir.appendingPathComponent(".cirrus-\(UUID().uuidString.prefix(8))-" + name)
                                do { try await backend.export(p, resource: kind, to: staged) { d, _ in t.report(base + d, 0) } }
                                catch { try? FileManager.default.removeItem(at: staged); throw error }
                                try LocalFiles.swapIn(staged, at: target, move: true)
                            } else {
                                try await backend.export(p, resource: kind, to: target) { d, _ in t.report(base + d, 0) }
                            }
                            done.add(p.resource(kind)?.size ?? p.size)
                            if exportLive, p.resource(.liveVideo) != nil {
                                let mov = dir.appendingPathComponent((name as NSString).deletingPathExtension + ".MOV")
                                if !FileManager.default.fileExists(atPath: mov.path) {
                                    try await backend.export(p, resource: .liveVideo, to: mov) { _, _ in }
                                    done.add(p.resource(.liveVideo)?.size ?? 0)
                                }
                            }
                            t.report(done.value, 0)
                            t.resultURL = target
                        }
                        return true
                    }
                    while n < 3 && next() {}
                    while try await g.next() != nil { _ = next() }
                }
                await MainActor.run { Ops.shared.refresh(dest) }
            }
        }
    }

    static func outputName(_ item: Item) -> String {
        if let p = item.photo {
            if Prefs.exportEdited, let e = p.resource(.edited) { return e.filename }
            return p.filename
        }
        return Paths.safeName(item.name)
    }

    /// Produce a local copy of any item inside `dir`. Returns the main file/folder.
    nonisolated static func materialize(_ item: Item, into dir: URL, exportLive: Bool, nameOverride: String? = nil,
                                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = nameOverride ?? Paths.safeName(item.name)
        let target = dir.appendingPathComponent(name)
        let account = await MainActor.run { item.account.flatMap { AccountManager.shared.account(id: $0) } }
        switch item.payload {
        case .file(let u):
            try await LocalFiles.ensureDownloaded(u)
            try FileManager.default.copyItem(at: u, to: target)
            return target
        case .drive(let n):
            guard let drive = account?.drive else { throw ICloudError.needsSignIn }
            if n.isFolder {
                let runner = SyncRunner(a: DriveSide(drive: drive, rootID: n.id, label: n.name, excludes: []), b: LocalSide(root: target, excludes: [], createIfMissing: true))
                let (a, b) = try await runner.scan { _ in }
                let plan = SyncPlanner.plan(mode: .copy, a: a, b: b, state: nil)
                let (rep, _) = try await runner.run(plan, a: a, b: b) { p in progress(p.bytesDone, p.bytesTotal) }
                if !rep.failed.isEmpty { throw ICloudError.server("\(rep.failed.count) files couldn’t be downloaded.") }
            } else {
                try await drive.download(n, to: target, progress: progress)
            }
            return target
        case .photo(let p):
            guard let photos = account?.photos else { throw ICloudError.needsSignIn }
            try await photos.export(p, resource: .original, to: target, progress: progress)
            if exportLive, p.resource(.liveVideo) != nil {
                try await photos.export(p, resource: .liveVideo, to: dir.appendingPathComponent((name as NSString).deletingPathExtension + ".MOV")) { _, _ in }
            }
            return target
        case .album(let al):
            guard let photos = account?.photos, case .album(_, let libID, _)? = item.target else { throw ICloudError.notFound }
            let lib = try await photos.libraries().first { $0.id == libID } ?? PhotoLibraryRef(id: libID, name: libID, isShared: false)
            let assets = try await photos.assets(in: al, library: lib) { _, _ in }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var taken = Set<String>()
            let total = assets.reduce(Int64(0)) { $0 + $1.size }
            var done: Int64 = 0
            for a in assets {
                try Task.checkCancellation()
                let n = Ops.uniqueName(a.filename, taken: taken)
                taken.insert(n.lowercased())
                try await photos.export(a, resource: .original, to: target.appendingPathComponent(n)) { _, _ in }
                if exportLive, a.resource(.liveVideo) != nil {
                    try? await photos.export(a, resource: .liveVideo, to: target.appendingPathComponent((n as NSString).deletingPathExtension + ".MOV")) { _, _ in }
                }
                done += a.size
                progress(done, total)
            }
            return target
        case .device(let d):
            if d.isFolder {
                let files = await MainActor.run { DeviceManager.shared.allFiles(device: d.deviceID).filter { $0.itemID.hasPrefix(d.itemID + "/") } }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                var done: Int64 = 0
                let total = files.reduce(Int64(0)) { $0 + $1.size }
                for f in files {
                    try await DeviceManager.shared.download(f, to: target.appendingPathComponent(f.name))
                    done += f.size
                    progress(done, total)
                }
            } else {
                try await DeviceManager.shared.download(d, to: target)
                progress(d.size, d.size)
            }
            return target
        case .volume, .camera:
            throw ICloudError.server("Can’t copy a whole device this way.")
        }
    }

    // MARK: Open & preview

    static func stableKey(_ s: String) -> String {
        String(s.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 36)
    }

    /// A local URL for opening/previewing, downloading into a cache when needed.
    func localCopy(_ item: Item, cache: String, progressTitle: String?) async throws -> URL {
        if let u = item.localURL { try await LocalFiles.ensureDownloaded(u); return u }
        let dir = Paths.cacheDir(cache).appendingPathComponent(Self.stableKey(item.key), isDirectory: true)
        let name = Paths.safeName(item.name)
        let target = dir.appendingPathComponent(name)
        // Reuse a cached copy if it's the same version (size and modified date match).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path), let size = attrs[.size] as? Int64,
           item.size == nil || size == item.size || item.isPhoto {
            let m = attrs[.modificationDate] as? Date
            if item.modified == nil || m == nil || abs(m!.timeIntervalSince(item.modified!)) < 2 || item.isPhoto { return target }
        }
        try? FileManager.default.removeItem(at: dir)
        if let progressTitle {
            let t = TransferManager.shared.enqueue(progressTitle, detail: "Downloading to open", direction: .download, total: item.transferSize) { t in
                _ = try await Ops.materialize(item, into: dir, exportLive: false) { d, tot in t.report(d, tot) }
            }
            while !t.isFinished { try await Task.sleep(nanoseconds: 150_000_000) }
            if case .failed(let m) = t.state { throw ICloudError.server(m) }
            if t.state == .cancelled { throw ICloudError.cancelled }
            return target
        }
        return try await Ops.materialize(item, into: dir, exportLive: false) { _, _ in }
    }

    func open(_ items: [Item], window: NSWindow?) {
        for item in items {
            if let u = item.localURL { NSWorkspace.shared.open(u); continue }
            Task {
                do {
                    let u = try await localCopy(item, cache: "Open", progressTitle: item.name)
                    let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    if item.driveNode != nil { openedFiles.removeAll { $0.url == u }; openedFiles.append((u, item, m)) }
                    NSWorkspace.shared.open(u)
                } catch { displayError(error, title: "Couldn’t open “\(item.name)”", window: window) }
            }
        }
    }

    /// Offer to upload edits to files opened from iCloud Drive (checked when Cirrus becomes active).
    func checkEditedFiles(window: NSWindow?) {
        for (i, entry) in openedFiles.enumerated().reversed() {
            guard let m = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > entry.mtime.addingTimeInterval(1),
                  let node = entry.item.driveNode, let acct = entry.item.account.flatMap({ AccountManager.shared.account(id: $0) }), let drive = acct.drive else { continue }
            openedFiles[i].mtime = m
            let a = NSAlert()
            a.messageText = "Save your changes to “\(entry.item.name)” in iCloud Drive?"
            a.informativeText = "You edited the copy Cirrus opened. The current iCloud version will go to Recently Deleted."
            a.addButton(withTitle: "Upload Changes")
            a.addButton(withTitle: "Not Now")
            let handle: (NSApplication.ModalResponse) -> Void = { r in
                guard r == .alertFirstButtonReturn else { return }
                let parent = node.parentID ?? drive.rootID
                TransferManager.shared.enqueue(node.name, detail: "Uploading changes", direction: .upload, total: (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) { t in
                    let n = try await drive.safeReplace(entry.url, name: node.name, in: parent, existing: node, modified: m) { d, tot in t.report(d, tot) }
                    await MainActor.run {
                        if let idx = Ops.shared.openedFiles.firstIndex(where: { $0.url == entry.url }) {
                            var it = Ops.shared.openedFiles[idx].item
                            it.payload = .drive(n)
                            Ops.shared.openedFiles[idx].item = it
                        }
                        Ops.shared.refresh(.drive(acct.id, parent))
                    }
                }
            }
            if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
        }
    }

    // MARK: Mutations

    func newFolder(in loc: Location, window: NSWindow?) async -> String? {
        switch loc {
        case .local(let p):
            do { try SafetyPolicy.checkLocalWrite(URL(fileURLWithPath: p)) } catch { displayError(error, title: "iCloud is read-only", window: window); return nil }
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).map { $0.lowercased() })
            let name = Self.uniqueName("untitled folder", taken: taken)
            do { try FileManager.default.createDirectory(at: URL(fileURLWithPath: p).appendingPathComponent(name), withIntermediateDirectories: false); refresh(loc); return name }
            catch { displayError(error, title: "Couldn’t create the folder", window: window) }
        case .drive(let a, let id):
            guard let drive = AccountManager.shared.account(id: a)?.drive else { return nil }
            let taken = Set(((try? await drive.list(id)) ?? []).map { $0.name.lowercased() })
            let name = Self.uniqueName("untitled folder", taken: taken)
            do { _ = try await drive.createFolder(name, in: id); refresh(loc); return name }
            catch { displayError(error, title: "Couldn’t create the folder", window: window) }
        case .photos(let a, let lib, _):
            guard let photos = AccountManager.shared.account(id: a)?.photos, let l = try? await Catalog.shared.library(account: a, id: lib) else { return nil }
            let taken = Set((Catalog.shared.albumIndex[a + "|" + lib] ?? []).map { $0.name.lowercased() })
            let name = Self.uniqueName("Untitled Album", taken: taken)
            do {
                _ = try await photos.createAlbum(name, in: l)
                _ = try? await Catalog.shared.albums(account: a, library: lib, refresh: true)
                refresh(loc)
                NotificationCenter.default.post(name: AccountManager.changed, object: nil)
                return name
            } catch { displayError(error, title: "Couldn’t create the album", window: window) }
        default: break
        }
        return nil
    }

    func rename(_ item: Item, to newName: String, in loc: Location, window: NSWindow?) async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name, !name.contains("/") else { return }
        do {
            switch item.payload {
            case .file(let u):
                try SafetyPolicy.checkLocalWrite(u)
                let dst = u.deletingLastPathComponent().appendingPathComponent(name)
                try FileManager.default.moveItem(at: u, to: dst)
                let undo = window?.undoManager
                undo?.registerUndo(withTarget: self) { _ in try? FileManager.default.moveItem(at: dst, to: u); Ops.shared.refresh(loc) }
                undo?.setActionName("Rename")
            case .drive(let n):
                guard let drive = item.account.flatMap({ AccountManager.shared.account(id: $0) })?.drive else { return }
                _ = try await drive.rename(n, to: name)
            default:
                return
            }
            refresh(loc)
        } catch { displayError(error, title: "Couldn’t rename “\(item.name)”", window: window) }
    }

    func trash(_ items: [Item], in loc: Location, window: NSWindow?) async {
        guard !items.isEmpty else { return }
        let local = items.compactMap(\.localURL)
        do { for u in local { try SafetyPolicy.checkLocalWrite(u) } } catch {
            displayError(error, title: "iCloud is read-only", window: window); return
        }
        if !local.isEmpty {
            var moved = [(URL, URL)]()
            for u in local {
                var result: NSURL?
                do { try FileManager.default.trashItem(at: u, resultingItemURL: &result); if let r = result as URL? { moved.append((u, r)) } }
                catch { displayError(error, title: "Couldn’t move “\(u.lastPathComponent)” to the Trash", window: window) }
            }
            if let undo = window?.undoManager, !moved.isEmpty {
                undo.registerUndo(withTarget: self) { _ in for (orig, t) in moved { try? FileManager.default.moveItem(at: t, to: orig) }; Ops.shared.refresh(loc) }
                undo.setActionName("Move to Trash")
            }
            refresh(loc)
        }
        let nodes = items.compactMap(\.driveNode)
        if !nodes.isEmpty, let drive = loc.account?.drive {
            do { try await drive.trash(nodes); refresh(loc); refresh(.driveTrash(loc.accountID ?? "")) }
            catch { displayError(error, title: "Couldn’t move to Recently Deleted", window: window) }
        }
        let assets = items.compactMap(\.photo)
        if !assets.isEmpty, let acct = loc.account, let photos = acct.photos {
            if acct.kind != .mac {
                let a = NSAlert()
                a.messageText = assets.count == 1 ? "Delete this photo?" : "Delete \(assets.count) photos?"
                a.informativeText = "They’ll move to Recently Deleted in iCloud Photos, on all your devices, and can be recovered for 30 days."
                a.addButton(withTitle: "Delete")
                a.addButton(withTitle: "Cancel")
                a.buttons[0].hasDestructiveAction = true
                let r = await a.present(window)
                guard r == .alertFirstButtonReturn else { return }
            }
            do {
                try await photos.delete(assets)
                patchAndShow(loc, updated: [], removed: Set(assets.map(\.id)))
            } catch { displayError(error, title: "Couldn’t delete", window: window) }
        }
        let dev = items.compactMap(\.deviceItem)
        if !dev.isEmpty {
            let a = NSAlert()
            a.messageText = "Delete \(dev.count) item\(dev.count == 1 ? "" : "s") from the device?"
            a.informativeText = "This can’t be undone."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
            a.buttons[0].hasDestructiveAction = true
            let r = await a.present(window)
            guard r == .alertFirstButtonReturn else { return }
            do { try await DeviceManager.shared.delete(dev); refresh(loc) } catch { displayError(error, title: "Couldn’t delete", window: window) }
        }
    }

    func restore(_ items: [Item], in loc: Location, window: NSWindow?) async {
        do {
            if case .driveTrash(let a) = loc, let drive = AccountManager.shared.account(id: a)?.drive {
                try await drive.restore(items.compactMap(\.driveNode))
            } else if let photos = loc.account?.photos {
                try await photos.restore(items.compactMap(\.photo))
                if case .album(let a, let lib, _) = loc { refresh(.album(a, lib, "smart:All Photos")) }
            }
            refresh(loc)
        } catch { displayError(error, title: "Couldn’t recover", window: window) }
    }

    func deleteForever(_ items: [Item], in loc: Location, window: NSWindow?) async {
        guard case .driveTrash(let a) = loc, let drive = AccountManager.shared.account(id: a)?.drive else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(items.count) item\(items.count == 1 ? "" : "s") immediately?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        let r = await alert.present(window)
        guard r == .alertFirstButtonReturn else { return }
        do { try await drive.deleteForever(items.compactMap(\.driveNode)); refresh(loc) }
        catch { displayError(error, title: "Couldn’t delete", window: window) }
    }

    func setFavorite(_ items: [Item], _ value: Bool, in loc: Location, window: NSWindow?) async {
        guard let photos = loc.account?.photos ?? items.first?.account.flatMap({ AccountManager.shared.account(id: $0)?.photos }) else { return }
        do {
            let updated = try await photos.setFavorite(items.compactMap(\.photo), value)
            patchAndShow(loc, updated: updated)
        } catch { displayError(error, title: "Couldn’t update favorites", window: window) }
    }

    func setHidden(_ items: [Item], _ value: Bool, in loc: Location, window: NSWindow?) async {
        guard let photos = loc.account?.photos else { return }
        do {
            let updated = try await photos.setHidden(items.compactMap(\.photo), value)
            patchAndShow(loc, updated: updated, removed: Set(updated.map(\.id)))
        } catch { displayError(error, title: "Couldn’t update", window: window) }
    }

    /// Reflect photo edits in every cached view without re-downloading listings.
    func patchAndShow(_ loc: Location, updated: [PhotoAsset], removed: Set<String> = []) {
        guard case .album(let a, let lib, _) = loc else { refresh(loc); return }
        Catalog.shared.patchPhotos(account: a, library: lib, updated: updated, removed: removed)
        NotificationCenter.default.post(name: .cirrusLocationChanged, object: loc)
        for id in ["smart:Recently Deleted", "smart:Favorites", "smart:Hidden"] where Location.album(a, lib, id) != loc {
            NotificationCenter.default.post(name: .cirrusLocationChanged, object: Location.album(a, lib, id))
        }
    }

    // Native iCloud Drive (Mac signed in)
    func downloadNow(_ items: [Item]) {
        for u in items.compactMap(\.localURL) { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
    }

    func removeDownload(_ items: [Item], window: NSWindow?) {
        for u in items.compactMap(\.localURL) {
            do { try FileManager.default.evictUbiquitousItem(at: u) } catch { displayError(error, title: "Couldn’t remove the download", window: window) }
        }
    }
}

final class Counter2: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64 = 0
    func add(_ n: Int64) { lock.withLock { v += n } }
    var value: Int64 { lock.withLock { v } }
}

extension Notification.Name {
    static let cirrusLocationChanged = Notification.Name("CirrusLocationChanged")
}
