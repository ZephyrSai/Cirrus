import AppKit
import CirrusCore

/// Headless QA steps for “Move to Google” (Debug builds only), used from CIRRUS_SCRIPT:
///   migrate                    open the window (off-screen when headless)
///   migrateaccount:<id>        pick the iCloud account (e.g. demo)
///   migrateopts:drive=0,live=1 set checkboxes (drive, photos, albums, favorites, live, edited, raw, hidden, shared, update)
///   googlesetup / googlesetupclose   show or dismiss the guided setup sheet (for snapshots)
///   googleconnect              connect Google (demo: the built-in fake Google approves)
///   migrateevaluate            Check Space and wait
///   migraterun / migratewait   start the move / wait for it to finish
///   migratedump                print the window's summary, warnings and report
///   googlestate                print what the fake Google holds (demo)
@MainActor
enum MigrationDebug {
    static func step(_ cmd: String, _ arg: String, _ app: AppDelegate) async -> Bool {
        #if DEBUG
        let w = MigrationWindowController.shared
        switch cmd {
        case "migrate":
            app.showMigration(nil)
            Debug.lastWindow = MigrationWindowController.shared?.window
            Debug.offscreen(Debug.lastWindow)
        case "migrateaccount":
            if let w, let i = w.accounts.firstIndex(where: { $0.id == arg }) { w.accountPopup.selectItem(at: i); w.optionsChanged() }
            else { Debug.log("no iCloud account \(arg)") }
        case "migrateopts":
            guard let w else { break }
            let boxes: [String: NSButton] = ["drive": w.includeDrive, "photos": w.includePhotos, "albums": w.albums, "favorites": w.favorites, "live": w.live,
                                             "edited": w.edited, "raw": w.raw, "hidden": w.hidden, "shared": w.shared, "update": w.updateChanged]
            for kv in arg.split(separator: ",") {
                let p = kv.split(separator: "=").map(String.init)
                if p.count == 2, let b = boxes[p[0]] { b.state = p[1] == "1" ? .on : .off }
            }
            w.optionsChanged()
        case "googlesetup":
            w?.showSetup(nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
        case "googlesetupclose":
            w?.setupSheet?.cancel(nil)
        case "googleconnect":
            guard let w else { break }
            w.connectGoogle(nil)
            for _ in 0..<600 where w.connectTask != nil || w.setupSheet != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            Debug.log("google: \(GoogleAccounts.shared.accounts.count) account(s); \(w.summary.stringValue)")
        case "migrateevaluate":
            guard let w else { break }
            w.evaluate()
            try? await Task.sleep(nanoseconds: 100_000_000)
            for _ in 0..<3000 where w.evalTask != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            Debug.log("evaluate: runEnabled=\(w.runButton.isEnabled) button=\(w.runButton.title)")
        case "migraterun":
            w?.runNow()
        case "migratewait":
            guard let w else { break }
            let t0 = Date()
            for _ in 0..<6000 where w.runningTransfer != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            Debug.log("move finished in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        case "migratedump":
            guard let w else { break }
            Debug.log("summary: \(w.summary.stringValue.replacingOccurrences(of: "\n", with: " | "))" + (w.progress.isHidden ? "" : " [progress bar \(Int(w.progress.doubleValue * 100))%]"))
            if !w.warnings.stringValue.isEmpty { Debug.log("warnings: \(w.warnings.stringValue.replacingOccurrences(of: "\n", with: " | "))") }
            if let r = w.lastImportReport {
                Debug.log("import report: drive=\(r.driveCopied)+\(r.driveUpdated) updated (docs \(r.docsExported)), photos=\(r.photosImported), albums=\(r.albumsCreated) (+\(r.albumAdds) adds), favorites=\(r.favoritesSet), failed=\(r.failed.count), skipped=\(r.skipped.count), stopped=\(r.stopped ?? "no")")
                for f in r.failed.prefix(5) { Debug.log("  failed: \(f)") }
            }
            if let r = w.lastReport {
                Debug.log("report: drive=\(r.driveCopied)+\(r.driveUpdated) updated, photos=\(r.photosCreated), albums=\(r.albumsCreated) (+\(r.albumAdds) adds), folders=\(r.foldersCreated), resumed=\(r.resumed), failed=\(r.failed.count), skipped=\(r.skipped.count), stopped=\(r.stopped ?? "no")")
            }
        case "migratedirection":
            guard let w else { break }
            w.directionControl.selectedSegment = arg == "import" ? 1 : 0
            w.directionChanged(nil)
        case "importopts":   // importopts:drive=1,photos=1,albums=1,favorites=1,live=1,edited=0,update=1,pdf=0
            guard let w else { break }
            let p = w.importPanel
            let boxes: [String: NSButton] = ["drive": p.drive, "photos": p.photos, "albums": p.albums, "favorites": p.favorites, "live": p.live,
                                             "edited": p.edited, "update": p.update]
            for kv in arg.split(separator: ",") {
                let x = kv.split(separator: "=").map(String.init)
                guard x.count == 2 else { continue }
                if x[0] == "pdf" { p.docFormat.selectItem(at: x[1] == "1" ? 1 : 0) } else { boxes[x[0]]?.state = x[1] == "1" ? .on : .off }
            }
            w.optionsChanged()
        case "takeout":   // takeout:demo (a synthetic export) or takeout:/path/a.zip,/path/b.zip
            guard let w else { break }
            if arg == "demo" {
                let dir = Paths.cacheDir("demo").appendingPathComponent("takeout", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let existing = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "zip" }
                w.importPanel.takeout = existing.count == 2 ? existing.sorted { $0.path < $1.path } : ((try? await TakeoutFixture.make(in: dir, format: "zip")) ?? [])
            } else {
                w.importPanel.takeout = arg.split(separator: ",").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
            }
            w.optionsChanged()
            Debug.log("takeout: \(w.importPanel.takeoutLabel.stringValue)")
        case "googleallow":
            guard let w else { break }
            w.startConnect(scopes: GoogleAccounts.importScopes, hint: w.selectedGoogle?.email)
            for _ in 0..<600 where w.connectTask != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            Debug.log("google scopes: \(w.selectedGoogle?.scopes.map { ($0 as NSString).lastPathComponent } ?? [])")
        case "googlepick":
            guard let w else { break }
            w.startPicking()
            try? await Task.sleep(nanoseconds: 200_000_000)
            for _ in 0..<600 where w.pickTask != nil || w.connectTask != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            Debug.log("picked: \(w.importPanel.picked.count)")
        case "icloudstate":   // what the demo iCloud holds after a Google → iCloud copy
            guard let a = AccountManager.shared.account(id: "demo"), let photos = a.photos, let drive = a.drive else { break }
            let lib = (try? await photos.libraries())?.first ?? PhotoLibraryRef(id: "demo", name: "", isShared: false)
            let albums = (try? await photos.albums(in: lib)) ?? []
            var counts = [String]()
            for al in albums where al.kind == .album { counts.append("\(al.name)(\((try? await photos.assets(in: al, library: lib) { _, _ in })?.count ?? 0))") }
            let favs = ((try? await photos.assets(in: PhotoAlbum(id: "smart:Favorites", name: "Favorites", kind: .smart), library: lib) { _, _ in }) ?? []).count
            let folder = (try? await drive.list(drive.rootID))?.first { $0.name == "From Google Drive" }
            var files = [String]()
            if let f = folder { files = ((try? await drive.walk(f.id)) ?? []).map(\.path).sorted() }
            Debug.log("demo icloud: albums=\(counts.sorted()) favorites=\(favs) fromGoogleDrive=\(files)")
        case "googlestate":
            let s = FakeGoogleServer.state
            let mine = s.visibleFiles
            Debug.log("fake google: files=\(mine.filter { $0.mimeType != GoogleDrive.folderMime && !$0.trashed }.count) folders=\(mine.filter { $0.mimeType == GoogleDrive.folderMime }.count) trashed=\(mine.filter(\.trashed).count) permanentDeletes=\(s.permanentDeletes) media=\(s.media.count) albums=\(s.albums.values.map { "\($0.title)(\($0.items.count))" }.sorted()) batchCreates=\(s.batchCreateSizes) driveSessions=\(s.driveSessionsStarted) usage=\(s.usage.byteString)")
        default:
            return false
        }
        return true
        #else
        return false
        #endif
    }
}
