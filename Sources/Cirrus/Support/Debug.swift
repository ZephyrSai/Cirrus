import AppKit
import CirrusCore

/// Headless automation for QA (no Accessibility or Screen Recording needed):
///   CIRRUS_SCRIPT="open:demo-drive;wait:1;snap:drive;view:list;snap:drive-list;quit"
///   CIRRUS_SNAPSHOT=/path/to/dir   (where snap: writes PNGs)
@MainActor
enum Debug {
    static var dir: URL?
    static var lastWindow: NSWindow?
    /// CIRRUS_HEADLESS=1: no Dock icon, windows parked off-screen, prompts auto-answered — test runs never appear on the user's screen.
    #if DEBUG
    static let headless = ProcessInfo.processInfo.environment["CIRRUS_HEADLESS"] != nil
    #else
    static let headless = false   // release builds ignore all test-automation switches
    #endif
    /// CIRRUS_AUTO_CONFLICT=keepBoth|replace|skip answers “already exists” prompts in tests.
    #if DEBUG
    static let autoConflict = ProcessInfo.processInfo.environment["CIRRUS_AUTO_CONFLICT"] ?? (headless ? "keepBoth" : nil)
    #else
    static let autoConflict: String? = nil
    #endif

    static func offscreen(_ w: NSWindow?) {
        guard headless, let w else { return }
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }

    static func run(_ app: AppDelegate) {
        #if !DEBUG
        return   // no scripting in release builds: another process can't drive a signed-in Cirrus
        #endif
        let env = ProcessInfo.processInfo.environment
        if let d = env["CIRRUS_SNAPSHOT"] { dir = URL(fileURLWithPath: d, isDirectory: true); try? FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true) }
        guard let script = env["CIRRUS_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for s in steps { await step(String(s), app) }
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("[script] \(s)\n".utf8)) }

    static func location(_ spec: String) -> Location? {
        let am = AccountManager.shared
        let demo = am.account(id: "demo")
        switch spec {
        case "home": return .home()
        case "computer": return .computer
        case "demo-drive": return demo.map { .drive($0.id, DemoDrive.shared.rootID) }
        case "demo-photos": return demo.map { .album($0.id, "demo", "smart:All Photos") }
        case "demo-albums": return demo.map { .photos($0.id, "demo", nil) }
        case "demo-trash": return demo.map { .driveTrash($0.id) }
        case "demo-deleted": return demo.map { .album($0.id, "demo", "smart:Recently Deleted") }
        case "web-drive": return am.webAccounts.first.flatMap { a in a.drive.map { .drive(a.id, $0.rootID) } }
        case "web-photos": return am.webAccounts.first.map { .album($0.id, "PrimarySync", "smart:All Photos") }
        case "web-albums": return am.webAccounts.first.map { .photos($0.id, "PrimarySync", nil) }
        case "mac-photos": return .album("mac", "local", "smart:all")
        case "mac-albums": return .photos("mac", "local", nil)
        default:
            if spec.hasPrefix("local:") { return .local((String(spec.dropFirst(6)) as NSString).expandingTildeInPath) }
            if spec.hasPrefix("drive:"), let demo { return .drive(demo.id, "FOLDER::demo::" + spec.dropFirst(6)) }
            return nil
        }
    }

    static func step(_ s: String, _ app: AppDelegate) async {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        let cmd = parts[0], arg = parts.count > 1 ? parts[1] : ""
        let b = app.activeBrowser ?? app.windows.last
        let pane = b?.activePane
        log(s)
        switch cmd {
        case "open":
            let t0 = Date()
            if let l = location(arg) { pane?.navigate(to: l); await waitLoaded(pane); log("open \(arg): \(String(format: "%.1f", Date().timeIntervalSince(t0) - 0.7))s") } else { log("unknown location \(arg)") }
        case "view": pane?.setViewMode(arg == "list" ? .list : .icons)
        case "dual": b?.toggleDualPane(nil); await waitLoaded(b?.activePane)
        case "focus": b?.focusOtherPane()
        case "select":
            if let p = pane {
                let idx = arg.split(separator: ",").compactMap { Int($0) }.filter { $0 < p.shown.count }
                p.select(keys: Set(idx.map { p.shown[$0].key }))
                p.itemViewSelectionChanged()
            }
        case "selectname":
            if let p = pane, let it = p.shown.first(where: { $0.name == arg }) { p.select(keys: [it.key]); p.itemViewSelectionChanged() }
        case "info": pane?.getInfo(nil); lastWindow = InfoPanel.shared.panel; offscreen(lastWindow)
        case "window":
            switch arg {
            case "backup": app.showBackup(nil); lastWindow = app.backupWindow?.window; offscreen(lastWindow)
            case "sync": app.showSync(nil); lastWindow = app.syncWindow?.window; offscreen(lastWindow)
            case "transfers": app.showTransfersWindow(nil); lastWindow = app.transfersWindow?.window; offscreen(lastWindow)
            case "prefs": app.showPreferences(nil); lastWindow = app.prefsWindow?.window; offscreen(lastWindow)
            case "signin": app.signIn(appleID: nil, window: nil); lastWindow = app.signIn?.window; offscreen(lastWindow)
            case "help": HelpWindow.show(); lastWindow = HelpWindow.window; offscreen(lastWindow)
            case "main": lastWindow = nil; b?.window?.makeKeyAndOrderFront(nil)
            default: break
            }
        case "evaluate": app.backupWindow?.evaluate(); while app.backupWindow?.evalTask != nil && !(app.backupWindow?.checkButton.isEnabled ?? true) { try? await Task.sleep(nanoseconds: 200_000_000) }
        case "backupdest":
            if let w = app.backupWindow, let i = w.destinations.firstIndex(where: { $0.path == (arg as NSString).expandingTildeInPath }) { w.destPopup.selectItem(at: i); w.destChanged() }
            else if let w = app.backupWindow { UserDefaults.standard.set((arg as NSString).expandingTildeInPath, forKey: "backupCustomDest"); w.reloadDestinations(); if let i = w.destinations.firstIndex(where: { $0.path == (arg as NSString).expandingTildeInPath }) { w.destPopup.selectItem(at: i) }; w.optionsChanged() }
        case "backupaccount":
            if let w = app.backupWindow, let i = w.accounts.firstIndex(where: { $0.id == arg }) { w.accountPopup.selectItem(at: i); w.optionsChanged() }
        case "backuprun":
            app.backupWindow?.runNow()
        case "upload":
            if let p = pane, let d = await Ops.shared.destination(for: p.location) {
                await Ops.shared.deliver(files: arg.split(separator: ",").map { URL(fileURLWithPath: String($0)) }, to: d, move: false, window: p.view.window)
            }
        case "download":
            let a = arg.split(separator: ">", maxSplits: 1).map(String.init)
            if let p = pane, a.count == 2 {
                let idx = a[0].split(separator: ",").compactMap { Int($0) }.filter { $0 < p.shown.count }
                await Ops.shared.transfer(idx.map { p.shown[$0] }, to: .local(URL(fileURLWithPath: a[1])), move: false, window: p.view.window)
            }
        case "copyto":   // copyto:0,1>demo-drive  (cross-location transfer)
            let a = arg.split(separator: ">", maxSplits: 1).map(String.init)
            if let p = pane, a.count == 2, let l = location(a[1]), let d = await Ops.shared.destination(for: l) {
                let idx = a[0].split(separator: ",").compactMap { Int($0) }.filter { $0 < p.shown.count }
                await Ops.shared.transfer(idx.map { p.shown[$0] }, to: d, move: false, window: p.view.window)
            }
        case "favorite": pane?.toggleFavorite(nil)
        case "trash": pane?.moveToTrash(nil)
        case "restore": pane?.restoreSelection(nil)
        case "newfolder": pane?.newFolder(nil)
        case "rename": if let p = pane, let it = p.selectedItems.first { await Ops.shared.rename(it, to: arg, in: p.location, window: p.view.window) }
        case "filter": pane?.filter = arg
        case "size": UserDefaults.standard.set(Double(arg) ?? 96, forKey: pane?.location.isPhotoGrid == true ? "photoSize" : "iconSize"); pane?.reloadViews()
        case "waittransfers":
            while !TransferManager.shared.active.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            for t in TransferManager.shared.transfers { log("transfer \(t.title): \(t.state) \(t.detail)") }
        case "counts":   // counts and timings only — no names (safe for real accounts)
            if let p = pane {
                let files = p.shown.filter { !$0.isContainer }
                log("counts: kind=\(Catalog.kindName(p.location)) items=\(p.shown.count) files=\(files.count) folders=\(p.shown.count - files.count) loading=\(p.isLoading) error=\(p.lastError.map { String(describing: $0) } ?? "none")")
            }
        case "albumcounts":   // smart album ids + counts, user albums only as a total (no personal names)
            if let a = AccountManager.shared.webAccounts.first, let albums = Catalog.shared.albumIndex[a.id + "|PrimarySync"] {
                let smart = albums.filter { $0.kind == .smart }.map { "\($0.id.replacingOccurrences(of: "smart:", with: ""))=\($0.count.map(String.init) ?? "?")" }
                let user = albums.filter { $0.kind != .smart }
                log("albums: \(smart.joined(separator: ", ")); user albums/folders=\(user.count) items=\(user.compactMap(\.count).reduce(0, +))")
            } else { log("albums: none cached") }
            if let a = AccountManager.shared.webAccounts.first { log("libraries: \((Catalog.shared.libraryIndex[a.id] ?? []).map { $0.isShared ? "shared" : "personal" })") }
        case "fetchsmallest":   // fetchsmallest:<dir> — download the smallest non-empty file here, report time, delete it
            if let p = pane, let item = p.shown.filter({ !$0.isContainer && ($0.size ?? 0) > 0 }).min(by: { ($0.size ?? 0) < ($1.size ?? 0) }) {
                let dir = URL(fileURLWithPath: arg).appendingPathComponent(UUID().uuidString)
                let t0 = Date()
                do {
                    let u = try await Ops.materialize(item, into: dir, exportLive: false, nameOverride: "probe") { _, _ in }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
                    log("fetch: \(bytes) bytes in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
                } catch { log("fetch failed after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error)") }
                try? FileManager.default.removeItem(at: dir)
            }
        case "fetchsize":   // fetchsize:<bytes>:<dir> — download the file closest to that size (e.g. a ~6 MB one)
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if let p = pane, parts.count == 2, let target = Int64(parts[0]),
               let item = p.shown.filter({ !$0.isContainer && ($0.size ?? 0) > 0 }).min(by: { abs(($0.size ?? 0) - target) < abs(($1.size ?? 0) - target) }) {
                let dir = URL(fileURLWithPath: parts[1]).appendingPathComponent(UUID().uuidString)
                let t0 = Date()
                do {
                    let u = try await Ops.materialize(item, into: dir, exportLive: false, nameOverride: "probe") { _, _ in }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
                    log("fetch: \(bytes) bytes in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
                } catch { log("fetch failed after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error)") }
                try? FileManager.default.removeItem(at: dir)
            }
        case "dumptransfers": for t in TransferManager.shared.transfers { log("transfer \(t.title): \(t.state) \(t.completed)/\(t.total) \(t.detail)") }
        case "dump":
            if let p = pane { log("location=\(Catalog.shared.title(p.location)) items=\(p.shown.count) status=\(p.statusLabel.stringValue) first=\(p.shown.prefix(6).map(\.name))") }
        case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1e9))
        case "waitload":
            let t0 = Date()
            if let p = pane { for _ in 0..<1200 { if !p.isLoading { break }; try? await Task.sleep(nanoseconds: 100_000_000) } }
            log("loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        case "snap": snapshot(arg, window: lastWindow ?? b?.window)
        case "dismiss":
            for w in NSApp.windows where w.isSheet || w.className.contains("Alert") { w.sheetParent?.endSheet(w) ; w.orderOut(nil) }
        case "alertbutton":   // click a button in the frontmost sheet/alert by title
            for w in NSApp.windows where w.isSheet || w.isVisible {
                if let btn = findButton(w.contentView, title: arg) { btn.performClick(nil); break }
            }
        case "picker":
            let mode: LocationPicker.Mode = arg == "album" ? .album : (arg == "drive" ? .driveFolder : .destination)
            Task { _ = await LocationPicker.pick(mode, title: "Copy To", prompt: "Choose where to copy 2 items. Use “On This Mac…” for any folder or drive.", on: nil) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let w = NSApp.windows.first(where: { $0.windowController is LocationPicker }), let p = w.windowController as? LocationPicker {
                offscreen(w)
                for r in p.roots { p.outline.expandItem(r) }
                try? await Task.sleep(nanoseconds: 900_000_000)
                p.outline.selectRowIndexes([1], byExtendingSelection: false)
                lastWindow = w
            }
        case "newtab":
            b?.newWindowForTab(nil)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let nb = app.activeBrowser { offscreen(nb.window); if let l = location(arg) { nb.activePane?.navigate(to: l); await waitLoaded(nb.activePane) } }
        case "tabs":
            let w = (app.activeBrowser ?? app.windows.last)?.window
            log("tabs=\(w?.tabbedWindows?.count ?? 1) windows=\(app.windows.count) titles=\((w?.tabbedWindows ?? [w].compactMap { $0 }).map(\.title))")
        case "dumpmenu":
            for top in NSApp.mainMenu?.items ?? [] where arg.isEmpty || top.title == arg {
                top.submenu?.update()
                if let sm = top.submenu { sm.delegate?.menuNeedsUpdate?(sm) }
                log("menu \(top.title): " + (top.submenu?.items.map { i in i.isSeparatorItem ? "—" : (i.title + (i.submenu != nil ? " ▸[" + (i.submenu!.items.map(\.title).joined(separator: ", ")) + "]" : "")) }.joined(separator: " | ") ?? ""))
            }
        case "quit": NSApp.terminate(nil)
        default: log("unknown step \(cmd)")
        }
    }

    static func findButton(_ v: NSView?, title: String) -> NSButton? {
        guard let v else { return nil }
        if let b = v as? NSButton, b.title == title { return b }
        for s in v.subviews { if let f = findButton(s, title: title) { return f } }
        return nil
    }

    static func waitLoaded(_ pane: PaneController?) async {
        guard let pane else { return }
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !pane.isLoading { break }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)   // thumbnails
    }

    /// Window-only rendering (includes the title bar + toolbar), no Screen Recording permission needed.
    static func snapshot(_ name: String, window: NSWindow?) {
        guard let dir, let w = window, let frameView = w.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        if let sheet = w.attachedSheet, let sv = sheet.contentView?.superview, let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: srep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            let composite = NSImage(size: bounds.size, flipped: false) { r in
                NSImage(cgImage: rep.cgImage!, size: bounds.size).draw(in: r)
                let sz = sv.bounds.size
                NSImage(cgImage: srep.cgImage!, size: sz).draw(in: NSRect(x: (r.width - sz.width) / 2, y: r.height - sz.height - 52, width: sz.width, height: sz.height))
                return true
            }
            if let tiff = composite.tiffRepresentation, let b = NSBitmapImageRep(data: tiff), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png")); return
            }
        }
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(name + ".png")) }
    }
}
