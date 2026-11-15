import AppKit
import CirrusCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var windows = [BrowserWindowController]()
    var statusItem: NSStatusItem?
    var signIn: SignInController?
    var syncWindow: SyncWindowController?
    var backupWindow: BackupWindowController?
    var prefsWindow: PreferencesWindowController?
    var transfersWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        SafetyPolicy.readOnlyICloud = Prefs.readOnlyICloud || ProcessInfo.processInfo.environment["CIRRUS_READ_ONLY"] != nil
        NSApp.setActivationPolicy(Debug.headless ? .accessory : .regular)
        #if DEBUG
        if let a = ProcessInfo.processInfo.environment["CIRRUS_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
        #endif
        NSApp.mainMenu = MainMenu.build(self)
        TransferNotice.start()
        Paths.cleanCaches()
        AccountManager.shared.load()
        SyncStore.shared.load()
        DeviceManager.shared.start()
        TransferManager.shared.maxConcurrent = max(1, UserDefaults.standard.integer(forKey: "maxTransfers"))
        var start = Location.home()
        if let d = UserDefaults.standard.data(forKey: "lastLocation"), let l = try? JSONDecoder().decode(Location.self, from: d) {
            if case .device = l {} else if l.accountID == nil || AccountManager.shared.account(id: l.accountID!) != nil { start = l }
        }
        if case .local(let p) = start, !FileManager.default.fileExists(atPath: p) { start = .home() }
        let wc = makeWindow(start)
        wc.showWindow(nil)
        if !Debug.headless { NSApp.activate() }
        JobScheduler.shared.start()
        updateStatusItem()
        NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.refreshStatusTitle() } }
        Debug.run(self)
    }

    @discardableResult
    func makeWindow(_ loc: Location) -> BrowserWindowController {
        let wc = BrowserWindowController(location: loc)
        Debug.offscreen(wc.window)
        windows.append(wc)
        return wc
    }

    func windowClosed(_ wc: BrowserWindowController) {
        windows.removeAll { $0 === wc }
    }

    var activeBrowser: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? (NSApp.mainWindow?.windowController as? BrowserWindowController) ?? windows.last
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let scheduled = SyncStore.shared.jobs.contains { $0.enabled && $0.schedule != .manual }
        return !(scheduled && Prefs.menuBarIcon) && TransferManager.shared.active.isEmpty
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = TransferManager.shared.active.count
        guard active > 0, ProcessInfo.processInfo.environment["CIRRUS_SNAPSHOT"] == nil else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "\(active) transfer\(active == 1 ? " is" : "s are") still in progress."
        a.informativeText = "Quitting stops them. Backups and syncs pick up where they left off next time; single downloads and uploads start over."
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        TransferManager.shared.cancelAll()
        SingleInstance.release()
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) {
        let loc = activeBrowser?.activePane?.location ?? .home()
        makeWindow(loc).showWindow(nil)
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let b = activeBrowser, let s = b.searchItem else { return }
        b.window?.makeFirstResponder(s.searchField)
    }

    @objc func goPlace(_ sender: NSMenuItem) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var loc: Location?
        switch sender.tag {
        case 1: loc = .local(home.path)
        case 2: loc = .local(home.appendingPathComponent("Desktop").path)
        case 3: loc = .local(home.appendingPathComponent("Documents").path)
        case 4: loc = .local(home.appendingPathComponent("Downloads").path)
        case 5:
            if let root = AccountManager.shared.macAccount?.driveRoot { loc = .local(root.path) }
            else if let a = AccountManager.shared.accounts.first(where: { $0.drive != nil }) { loc = .drive(a.id, a.drive!.rootID) }
            else { signIn(appleID: nil, window: activeBrowser?.window) }
        case 6:
            if let a = AccountManager.shared.accounts.first(where: { $0.kind != .mac && $0.photos != nil }) ?? AccountManager.shared.macAccount, a.photos != nil {
                loc = .album(a.id, SidebarController.libraryID(a), SidebarController.allPhotosID(a))
            }
        case 7: loc = .computer
        default: break
        }
        if let loc { activeBrowser?.activePane?.navigate(to: loc) }
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let w = activeBrowser?.window else { return }
        let a = NSAlert()
        a.messageText = "Go to Folder"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "~/Documents or /Volumes/Backup"
        a.accessoryView = f
        a.addButton(withTitle: "Go"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            let path = (f.stringValue as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { self.activeBrowser?.activePane?.navigate(to: .local(path)) } else { NSSound.beep() }
        }
    }

    @objc func signInMenu(_ sender: Any?) { signIn(appleID: nil, window: activeBrowser?.window) }

    func signIn(appleID: String?, window: NSWindow?) {
        if let s = signIn, s.window?.isVisible == true { s.window?.makeKeyAndOrderFront(nil); return }
        let s = SignInController(appleID: appleID)
        signIn = s
        s.onFinish = { [weak self] id in
            self?.signIn = nil
            guard let id, let acct = AccountManager.shared.account(id: "web:" + id) else { return }
            self?.activeBrowser?.activePane?.navigate(to: .drive(acct.id, acct.drive!.rootID))
        }
        if let window { window.beginSheet(s.window!) } else { s.showWindow(nil) }
    }

    @objc func showAccountInfoMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { showAccountInfo(id) } }

    func showAccountInfo(_ id: String) {
        guard let a = AccountManager.shared.account(id: id) else { return }
        AccountInfo.show(a, window: activeBrowser?.window)
    }

    @objc func showBackup(_ sender: Any?) {
        if backupWindow == nil { backupWindow = BackupWindowController() }
        backupWindow?.showWindow(nil)
        backupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSyncMenu(_ sender: Any?) { showSync(nil) }

    func showSync(_ id: UUID?) {
        if syncWindow == nil { syncWindow = SyncWindowController() }
        syncWindow?.showWindow(nil)
        syncWindow?.window?.makeKeyAndOrderFront(nil)
        if let id { syncWindow?.select(id) } else if SyncStore.shared.jobs.isEmpty { syncWindow?.newJob(nil) }
    }

    @objc func runAllJobs(_ sender: Any?) { for j in SyncStore.shared.jobs where j.enabled { JobRunner.shared.run(j, window: nil) } }

    @objc func showPreferences(_ sender: Any?) {
        if prefsWindow == nil { prefsWindow = PreferencesWindowController() }
        prefsWindow?.showWindow(nil)
        prefsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showTransfersWindow(_ sender: Any?) {
        if transfersWindow == nil {
            let w = NSWindow(contentViewController: TransfersViewController())
            w.title = "Transfers"
            w.setContentSize(NSSize(width: 520, height: 420))
            w.setFrameAutosaveName("CirrusTransfers")
            transfersWindow = NSWindowController(window: w)
        }
        transfersWindow?.showWindow(nil)
    }

    @objc func showHelp(_ sender: Any?) { HelpWindow.show() }

    // MARK: Menu bar

    func updateStatusItem() {
        if Prefs.menuBarIcon && statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            s.button?.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Cirrus")
            let m = NSMenu()
            m.delegate = self
            s.menu = m
            statusItem = s
            refreshStatusTitle()
        } else if !Prefs.menuBarIcon, let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
            statusItem = nil
        }
    }

    func refreshStatusTitle() {
        guard let b = statusItem?.button else { return }
        let o = TransferManager.shared.overall
        b.image = NSImage(systemSymbolName: o.count > 0 ? "arrow.triangle.2.circlepath.icloud" : "icloud", accessibilityDescription: "Cirrus")
        b.title = o.count > 0 && o.total > 0 ? " \(Int(Double(o.done) / Double(o.total) * 100))%" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        let o = TransferManager.shared.overall
        menu.addItem(withTitle: o.count == 0 ? "No transfers" : "\(o.count) transfer\(o.count == 1 ? "" : "s") — \(o.done.byteString) of \(o.total.byteString)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Show Transfers", action: #selector(showTransfersWindow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for j in SyncStore.shared.jobs {
            let running = SyncStore.shared.running.contains(j.id)
            let mi = NSMenuItem(title: j.name + (running ? " — running" : j.lastRun.map { " — " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? ""), action: #selector(runJobFromMenu(_:)), keyEquivalent: "")
            mi.representedObject = j.id
            mi.target = self
            mi.image = NSImage(systemSymbolName: j.lastSuccess == false ? "exclamationmark.circle" : (j.kind == .backup ? "externaldrive.badge.timemachine" : "arrow.triangle.2.circlepath"), accessibilityDescription: nil)
            menu.addItem(mi)
        }
        if !SyncStore.shared.jobs.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Back Up iCloud…", action: #selector(showBackup(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Cirrus", action: #selector(openFromMenu(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cirrus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func runJobFromMenu(_ s: NSMenuItem) { if let id = s.representedObject as? UUID, let j = SyncStore.shared.job(id) { JobRunner.shared.run(j, window: nil) } }
    @objc func openFromMenu(_ s: Any?) { NSApp.activate(); if windows.isEmpty { newWindow(nil) } else { windows.last?.window?.makeKeyAndOrderFront(nil) } }

    static func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { Log.error("launch at login: \(error.localizedDescription)") }
    }
}

/// One Cirrus per user (two instances would race on the same transfers and sync state).
enum SingleInstance {
    nonisolated(unsafe) static var fd: Int32 = -1
    /// Every Cirrus build (release, tester, QA) shares this bundle ID prefix.
    static let family = "io.github.zephyrsai.cirrus"

    /// One lock per user, shared by every build and profile (it doesn't live in a profile folder), plus a check
    /// for any running Cirrus copy in case one was started from somewhere else.
    static func claim() -> Bool {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Cirrus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fd = open(dir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        let lockHeldElsewhere = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && ($0.bundleIdentifier?.hasPrefix(family) ?? false)
        }
        guard lockHeldElsewhere || !others.isEmpty else { return true }
        FileHandle.standardError.write(Data("Cirrus is already running; bringing it to the front.\n".utf8))
        // A real second launch brings the open one forward; a headless test launch just leaves quietly.
        if ProcessInfo.processInfo.environment["CIRRUS_HEADLESS"] == nil { others.first?.activate() }
        if fd >= 0 { close(fd); fd = -1 }
        return false
    }
    static func release() { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
}
