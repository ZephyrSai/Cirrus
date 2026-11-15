import AppKit
import CirrusCore
import ServiceManagement

/// Sync jobs: list on the left, editor on the right, with a dry-run preview before anything runs.
@MainActor
final class SyncWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let list = NSTableView()
    let nameField = NSTextField()
    let kindPopup = NSPopUpButton()
    let sourceButton = NSPopUpButton()
    let destButton = NSPopUpButton()
    let modePopup = NSPopUpButton()
    let schedulePopup = NSPopUpButton()
    let excludesField = NSTextField()
    let enabledBox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let liveBox = NSButton(checkboxWithTitle: "Include Live Photo videos", target: nil, action: nil)
    let editedBox = NSButton(checkboxWithTitle: "Include edited versions", target: nil, action: nil)
    let layoutPopup = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    var editing: SyncJob?
    var observer: NSObjectProtocol?
    var optionsGrid: NSGridView?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Sync Jobs"
        w.setFrameAutosaveName("CirrusSync")
        super.init(window: w)
        build()
        observer = NotificationCenter.default.addObserver(forName: SyncStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.list.reloadData(); self?.refreshStatus() }
        }
        if !w.setFrameUsingName("CirrusSync") { w.center() }
        if let first = SyncStore.shared.jobs.first { select(first.id) } else { load(nil) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let scroll = NSScrollView()
        list.addTableColumn(NSTableColumn(identifier: .init("job")))
        list.headerView = nil
        list.rowHeight = 40
        list.style = .sourceList
        list.dataSource = self
        list.delegate = self
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New job")!, target: self, action: #selector(newJob(_:)))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete job")!, target: self, action: #selector(deleteJob))
        for b in [add, remove] { b.bezelStyle = .smallSquare }
        let left = NSStackView(views: [scroll, NSStackView(views: [add, remove, NSView()])])
        left.orientation = .vertical
        left.spacing = 0
        left.widthAnchor.constraint(equalToConstant: 250).isActive = true

        kindPopup.addItems(withTitles: ["Folder sync (Mac ⇄ iCloud Drive)", "Export Photos to a folder", "Import a folder into Photos", "Full iCloud backup"])
        kindPopup.target = self; kindPopup.action = #selector(kindChanged)
        for m in SyncJob.Mode.allCases { modePopup.addItem(withTitle: m.title) }
        schedulePopup.addItems(withTitles: ["Manually", "Every 15 minutes", "Every hour", "Every 6 hours", "Daily at 2:00", "When the destination drive is connected"])
        layoutPopup.addItems(withTitles: ["Year / Month", "Year / Month / Day", "Year", "One folder"])
        excludesField.placeholderString = ".DS_Store, *.tmp, node_modules"
        for f in [nameField, excludesField] { f.bezelStyle = .roundedBezel }
        sourceButton.pullsDown = false
        destButton.pullsDown = false
        sourceButton.target = self; sourceButton.action = #selector(endpointPicked(_:))
        destButton.target = self; destButton.action = #selector(endpointPicked(_:))
        let grid = NSGridView(views: [
            [label("Name"), nameField], [label("Type"), kindPopup], [label("From"), sourceButton], [label("To"), destButton],
            [label("Mode"), modePopup], [label("Photos"), layoutPopup], [NSView(), liveBox], [NSView(), editedBox],
            [label("Schedule"), schedulePopup], [label("Skip"), excludesField], [NSView(), enabledBox],
        ])
        optionsGrid = grid
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        for v in [nameField, kindPopup, sourceButton, destButton, modePopup, schedulePopup, excludesField] { v.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true }
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 480
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let preview = NSButton(title: "Preview…", target: self, action: #selector(previewJob))
        let run = NSButton(title: "Run Now", target: self, action: #selector(runJob))
        let save = NSButton(title: "Save", target: self, action: #selector(saveJob))
        save.keyEquivalent = "\r"
        for b in [preview, run, save] { b.bezelStyle = .push }
        let buttons = NSStackView(views: [spinner, NSView(), preview, run, save])
        let right = NSStackView(views: [grid, status, NSView(), buttons])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 14
        right.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: right.widthAnchor, constant: -40).isActive = true
        let root = NSStackView(views: [left, right])
        root.spacing = 0
        root.alignment = .top
        left.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        window?.contentView = root
    }

    func label(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.textColor = .secondaryLabelColor; return t }

    // MARK: Endpoint menus

    struct EndpointChoice { let title: String; let endpoint: SyncEndpoint? ; let action: String? }

    func choices(forSource: Bool) -> [EndpointChoice] {
        var out = [EndpointChoice]()
        let kind = kindIndex
        let am = AccountManager.shared
        let browserLoc = (NSApp.delegate as? AppDelegate)?.activeBrowser?.activePane?.location
        func driveChoices() {
            out.append(.init(title: "Choose an iCloud Drive Folder…", endpoint: nil, action: "pickdrive"))
            if let root = am.macAccount?.driveRoot { out.append(.init(title: "iCloud Drive (this Mac)", endpoint: .local(path: root.path), action: nil)) }
            for a in am.accounts where a.drive != nil && a.kind != .mac {
                out.append(.init(title: "iCloud Drive — \(a.appleID ?? a.title)", endpoint: .drive(account: a.id, folderID: a.drive!.rootID, path: ""), action: nil))
            }
            if case .drive(let a, let id)? = browserLoc {
                let path = Catalog.shared.pathComponents(.drive(a, id)).dropFirst().map(\.0).joined(separator: "/")
                out.append(.init(title: "Folder open in Cirrus: iCloud Drive › \(path.replacingOccurrences(of: "/", with: " › "))", endpoint: .drive(account: a, folderID: id, path: path), action: nil))
            }
        }
        func photoChoices() {
            out.append(.init(title: "Choose a Library or Album…", endpoint: nil, action: "pickalbum"))
            for a in am.accounts where a.photos != nil {
                let lib = SidebarController.libraryID(a)
                out.append(.init(title: "Photos — \(a.kind == .mac ? "This Mac" : (a.appleID ?? a.title)) (All Photos)", endpoint: .photos(account: a.id, library: lib, album: nil, albumName: nil), action: nil))
            }
            if case .album(let a, let lib, let id)? = browserLoc, !id.hasPrefix("smart:") {
                out.append(.init(title: "Album open in Cirrus: \(Catalog.shared.title(browserLoc!))", endpoint: .photos(account: a, library: lib, album: id, albumName: Catalog.shared.title(browserLoc!)), action: nil))
            }
        }
        func localChoice() {
            if case .local(let p)? = browserLoc { out.append(.init(title: "Folder open in Cirrus: \((p as NSString).abbreviatingWithTildeInPath)", endpoint: .local(path: p), action: nil)) }
            out.append(.init(title: "Choose a Folder…", endpoint: nil, action: "choose"))
        }
        switch (kind, forSource) {
        case (0, true): localChoice(); driveChoices()
        case (0, false): driveChoices(); localChoice()
        case (1, true): photoChoices()
        case (1, false), (2, true), (3, false): localChoice()
        case (2, false): photoChoices()
        case (3, true):
            for a in am.accounts where a.hasDrive || a.photos != nil { out.append(.init(title: a.kind == .mac ? "This Mac’s iCloud" : (a.appleID ?? a.title), endpoint: .account(a.id), action: nil)) }
        default: break
        }
        return out
    }

    var kindIndex: Int { max(0, kindPopup.indexOfSelectedItem) }
    var currentSource: SyncEndpoint?
    var currentDest: SyncEndpoint?

    func rebuildEndpointMenus() {
        for (button, isSource) in [(sourceButton, true), (destButton, false)] {
            button.removeAllItems()
            let current = isSource ? currentSource : currentDest
            if let c = current, !choices(forSource: isSource).contains(where: { $0.endpoint == c }) { button.addItem(withTitle: c.title); button.lastItem?.representedObject = EndpointBox(c) }
            for ch in choices(forSource: isSource) {
                button.addItem(withTitle: ch.title)
                button.lastItem?.representedObject = ch.endpoint.map { EndpointBox($0) } ?? ch.action as Any
            }
            if let c = current, let i = button.itemArray.firstIndex(where: { ($0.representedObject as? EndpointBox)?.e == c }) { button.selectItem(at: i) }
            else if isSource && kindIndex == 0 || !isSource && [1, 3].contains(kindIndex) {
                // Folder sources and export destinations: make the user pick deliberately.
                button.insertItem(withTitle: "Choose…", at: 0)
                button.item(at: 0)?.representedObject = nil
                button.selectItem(at: 0)
            }
            else if let i = button.itemArray.firstIndex(where: { $0.representedObject is EndpointBox }) {
                button.selectItem(at: i)
                if isSource { currentSource = (button.itemArray[i].representedObject as? EndpointBox)?.e } else { currentDest = (button.itemArray[i].representedObject as? EndpointBox)?.e }
            }
        }
    }

    @objc func endpointPicked(_ sender: NSPopUpButton) {
        let isSource = sender === sourceButton
        if let action = sender.selectedItem?.representedObject as? String, action == "pickdrive" || action == "pickalbum" {
            Task {
                let loc = await LocationPicker.pick(action == "pickdrive" ? .driveFolder : .album, title: action == "pickdrive" ? "Choose a Folder" : "Choose a Library or Album",
                                                    prompt: action == "pickdrive" ? "Pick the iCloud Drive folder to sync." : "Pick the whole library or one album.", on: window)
                if let e = loc.flatMap(Self.endpoint(for:)) { if isSource { currentSource = e } else { currentDest = e } }
                rebuildEndpointMenus()
            }
            return
        }
        if (sender.selectedItem?.representedObject as? String) == "choose" {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.beginSheetModal(for: window!) { r in
                if r == .OK, let u = p.url { if isSource { self.currentSource = .local(path: u.path) } else { self.currentDest = .local(path: u.path) } }
                self.rebuildEndpointMenus()
            }
            return
        }
        if let e = (sender.selectedItem?.representedObject as? EndpointBox)?.e { if isSource { currentSource = e } else { currentDest = e } }
    }

    static func endpoint(for loc: Location) -> SyncEndpoint? {
        switch loc {
        case .local(let p): return .local(path: p)
        case .drive(let a, let id):
            let path = Catalog.shared.pathComponents(loc).dropFirst().map(\.0).joined(separator: "/")
            return .drive(account: a, folderID: id, path: path)
        case .album(let a, let lib, let id):
            let all = id == "smart:all" || id == "smart:All Photos"
            return .photos(account: a, library: lib, album: all ? nil : id, albumName: all ? nil : Catalog.shared.title(loc))
        case .photos(let a, let lib, nil): return .photos(account: a, library: lib, album: nil, albumName: nil)
        default: return nil
        }
    }

    @objc func kindChanged() {
        currentSource = nil; currentDest = nil
        updateVisibility()
        rebuildEndpointMenus()
    }

    func updateVisibility() {
        let k = kindIndex
        modePopup.isEnabled = k == 0
        layoutPopup.isEnabled = k == 1 || k == 3
        liveBox.isEnabled = k == 1 || k == 3
        editedBox.isEnabled = k == 1 || k == 3
        excludesField.isEnabled = k == 0 || k == 3
        if let g = optionsGrid {
            g.row(at: 4).isHidden = k != 0                       // mode
            for r in 5...7 { g.row(at: r).isHidden = !(k == 1 || k == 3) }   // photo options
            g.row(at: 9).isHidden = !(k == 0 || k == 3)          // skip patterns
        }
    }

    // MARK: Load / save

    func select(_ id: UUID) {
        if let i = SyncStore.shared.jobs.firstIndex(where: { $0.id == id }) { list.selectRowIndexes([i], byExtendingSelection: false) }
        load(SyncStore.shared.job(id))
    }

    @objc func newJob(_ sender: Any?) {
        list.deselectAll(nil)
        load(nil)
        window?.makeFirstResponder(nameField)
    }

    func load(_ job: SyncJob?) {
        editing = job
        let j = job ?? SyncJob(name: "New Sync", kind: .folderSync, source: .local(path: ""), destination: .local(path: ""))
        nameField.stringValue = j.name
        kindPopup.selectItem(at: [.folderSync: 0, .photosExport: 1, .photosImport: 2, .backup: 3][j.kind] ?? 0)
        modePopup.selectItem(at: SyncJob.Mode.allCases.firstIndex(of: j.mode) ?? 0)
        switch j.schedule {
        case .manual: schedulePopup.selectItem(at: 0)
        case .every(let m): schedulePopup.selectItem(at: m <= 15 ? 1 : (m <= 60 ? 2 : 3))
        case .daily: schedulePopup.selectItem(at: 4)
        case .whenConnected: schedulePopup.selectItem(at: 5)
        }
        layoutPopup.selectItem(at: ["{yyyy}/{MM}", "{yyyy}/{MM}/{dd}", "{yyyy}", "flat"].firstIndex(of: j.options.photoLayout) ?? 0)
        liveBox.state = j.options.includeLive ? .on : .off
        editedBox.state = j.options.includeEdited ? .on : .off
        excludesField.stringValue = j.options.excludes.filter { !SyncOptions().excludes.contains($0) }.joined(separator: ", ")
        enabledBox.state = j.enabled ? .on : .off
        currentSource = job == nil ? nil : j.source
        currentDest = job == nil ? nil : j.destination
        updateVisibility()
        rebuildEndpointMenus()
        refreshStatus()
    }

    func refreshStatus() {
        guard let id = editing?.id, let j = SyncStore.shared.job(id) else { status.stringValue = "Choose what to sync and where. Preview shows exactly what will change before anything runs."; return }
        if SyncStore.shared.running.contains(id) { status.stringValue = "Running…"; return }
        if let r = j.lastRun {
            status.stringValue = "Last run \(RelativeDateTimeFormatter().localizedString(for: r, relativeTo: Date())): \(j.lastResult ?? "")"
            status.textColor = j.lastSuccess == false ? .systemRed : .secondaryLabelColor
        } else { status.stringValue = "Never run."; status.textColor = .secondaryLabelColor }
    }

    func buildJob() -> SyncJob? {
        guard let src = currentSource, let dst = currentDest else { status.stringValue = "Pick both a source and a destination."; status.textColor = .systemRed; return nil }
        if src == dst { status.stringValue = "Source and destination are the same."; status.textColor = .systemRed; return nil }
        if let a = src.localURL?.standardizedFileURL.path, let b = dst.localURL?.standardizedFileURL.path, a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
            status.stringValue = "One folder is inside the other; that would sync forever."; status.textColor = .systemRed; return nil
        }
        let kinds: [SyncJob.Kind] = [.folderSync, .photosExport, .photosImport, .backup]
        var j = editing ?? SyncJob(name: "", kind: kinds[kindIndex], source: src, destination: dst)
        j.name = nameField.stringValue.isEmpty ? "\(src.title) → \(dst.title)" : nameField.stringValue
        j.kind = kinds[kindIndex]
        j.source = src
        j.destination = dst
        j.mode = SyncJob.Mode.allCases[max(0, modePopup.indexOfSelectedItem)]
        switch schedulePopup.indexOfSelectedItem {
        case 1: j.schedule = .every(minutes: 15)
        case 2: j.schedule = .every(minutes: 60)
        case 3: j.schedule = .every(minutes: 360)
        case 4: j.schedule = .daily(hour: 2)
        case 5:
            guard let u = dst.localURL ?? src.localURL, let uuid = JobScheduler.uuid(u), VolumeInfo.info(for: u)?.isRoot == false else {
                status.stringValue = "“When connected” needs a destination on an external drive."; status.textColor = .systemRed; return nil
            }
            j.schedule = .whenConnected(volumeUUID: uuid)
        default: j.schedule = .manual
        }
        j.options.photoLayout = ["{yyyy}/{MM}", "{yyyy}/{MM}/{dd}", "{yyyy}", "flat"][max(0, layoutPopup.indexOfSelectedItem)]
        j.options.includeLive = liveBox.state == .on
        j.options.includeEdited = editedBox.state == .on
        j.options.excludes = SyncOptions().excludes + excludesField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        j.enabled = enabledBox.state == .on
        return j
    }

    @objc func saveJob() {
        guard let j = buildJob() else { return }
        SyncStore.shared.upsert(j)
        editing = j
        select(j.id)
    }

    @objc func deleteJob() {
        guard let j = editing else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(j.name)”?"
        a.informativeText = "Only the job is removed. No files are touched."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { r in
            guard r == .alertFirstButtonReturn else { return }
            SyncStore.shared.remove(j)
            self.load(SyncStore.shared.jobs.first)
        }
    }

    @objc func runJob() {
        guard let j = buildJob() else { return }
        SyncStore.shared.upsert(j)
        editing = j
        previewThenRun(j, autoRun: true)
    }

    @objc func previewJob() {
        guard let j = buildJob() else { return }
        previewThenRun(j, autoRun: false)
    }

    func previewThenRun(_ j: SyncJob, autoRun: Bool) {
        spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Scanning…"
        Task {
            defer { spinner.stopAnimation(nil) }
            do {
                let p = try await JobRunner.shared.preview(j) { s in Task { @MainActor in self.status.stringValue = s } }
                status.stringValue = p.summary
                let destructive = (p.plan?.trashCount ?? 0) > 0
                if autoRun && !p.guardTripped && !destructive { JobRunner.shared.run(j, window: window); status.stringValue = "Running… (see Transfers)"; return }
                showPreview(p, job: j)
            } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
        }
    }

    func showPreview(_ p: JobRunner.Preview, job: SyncJob) {
        let a = NSAlert()
        a.messageText = p.guardTripped ? "This run would remove a lot of files" : "Preview: \(job.name)"
        a.informativeText = p.summary + (p.guardTripped ? "\n\nMore than \(job.options.maxDeletePercent)% of the files would move to the Trash. If you just reorganized or emptied the source, that may be intended." : "")
        if let plan = p.plan, !plan.isEmpty {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            var lines = [String]()
            for act in plan.actions.prefix(3000) {
                switch act {
                case .copyAB(let r, let s): lines.append("→ \(r)  \(s.byteString)")
                case .copyBA(let r, let s): lines.append("← \(r)  \(s.byteString)")
                case .mkdirA(let r): lines.append("+ \(r)/ (source)")
                case .mkdirB(let r): lines.append("+ \(r)/")
                case .trashA(let r): lines.append("🗑 \(r)  (source → Trash)")
                case .trashB(let r): lines.append("🗑 \(r)  (→ Trash)")
                case .conflict(let r, _, _): lines.append("⚠︎ \(r)  (changed on both sides — both kept)")
                case .skip(let r, let why): lines.append("· \(r)  skipped: \(why)")
                }
            }
            if plan.actions.count > 3000 { lines.append("… and \(plan.actions.count - 3000) more") }
            tv.string = lines.joined(separator: "\n")
            let s = NSScrollView(frame: tv.frame)
            s.documentView = tv
            s.hasVerticalScroller = true
            a.accessoryView = s
        }
        let canRun = !(p.plan?.isEmpty ?? false) || job.kind != .folderSync
        if canRun { a.addButton(withTitle: p.guardTripped ? "Run Anyway" : "Run Now") }
        a.addButton(withTitle: canRun ? "Cancel" : "OK")
        a.beginSheetModal(for: window!) { r in
            guard canRun, r == .alertFirstButtonReturn else { return }
            SyncStore.shared.upsert(job)
            JobRunner.shared.run(job, window: self.window, force: p.guardTripped)
            self.status.stringValue = "Running… (see Transfers)"
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { SyncStore.shared.jobs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let j = SyncStore.shared.jobs[row]
        let v = NSTableCellView()
        let t = NSTextField(labelWithString: j.name)
        t.lineBreakMode = .byTruncatingTail
        t.font = .systemFont(ofSize: 12.5, weight: .medium)
        let s = NSTextField(labelWithString: (SyncStore.shared.running.contains(j.id) ? "Running" : j.schedule.title) + (j.enabled ? "" : " — off"))
        s.font = .systemFont(ofSize: 10.5)
        s.textColor = j.lastSuccess == false ? .systemRed : .secondaryLabelColor
        let img = NSImageView(image: NSImage(systemSymbolName: j.kind == .backup ? "externaldrive.badge.timemachine" : (j.kind == .folderSync ? "arrow.triangle.2.circlepath" : "photo.on.rectangle"), accessibilityDescription: nil)!)
        let stack = NSStackView(views: [t, s])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        let row = NSStackView(views: [img, stack])
        row.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6), row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     row.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4)])
        return v
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = list.selectedRow
        if r >= 0 && r < SyncStore.shared.jobs.count { load(SyncStore.shared.jobs[r]) }
    }
}

final class EndpointBox: NSObject { let e: SyncEndpoint; init(_ e: SyncEndpoint) { self.e = e } }

// MARK: - Preferences

@MainActor
final class PreferencesWindowController: NSWindowController {
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Cirrus Settings"
        super.init(window: w)
        let d = UserDefaults.standard
        func box(_ title: String, _ key: String, _ action: Selector? = nil) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: action ?? #selector(toggled(_:)))
            b.identifier = .init(key)
            b.state = d.bool(forKey: key) ? .on : .off
            return b
        }
        let concurrency = NSPopUpButton()
        concurrency.addItems(withTitles: ["1", "2", "3", "4", "6", "8"])
        concurrency.selectItem(withTitle: String(d.integer(forKey: "maxTransfers")))
        concurrency.target = self
        concurrency.action = #selector(concurrencyChanged(_:))
        let login = NSButton(checkboxWithTitle: "Open Cirrus at login (for scheduled syncs and backups)", target: self, action: #selector(loginToggled(_:)))
        login.state = SMAppServiceStatus.isEnabled ? .on : .off
        let readOnly = NSButton(checkboxWithTitle: "Read-only iCloud: never change anything in iCloud (browse, download and back up only)", target: self, action: #selector(readOnlyToggled(_:)))
        readOnly.state = Prefs.readOnlyICloud ? .on : .off
        let views: [NSView] = [
            header("Safety"),
            readOnly,
            note("Deletions always go to the Trash or iCloud’s Recently Deleted, never straight to deletion. Read-only mode also blocks uploads, renames, moves and photo edits."),
            { () -> NSButton in
                let b = NSButton(checkboxWithTitle: "Require Touch ID or Mac password before using a saved Apple ID password", target: self, action: #selector(authToggled(_:)))
                b.state = CredentialGate.requireAuth ? .on : .off
                return b
            }(),
            header("General"),
            box("Show hidden files", "showHidden"),
            box("Keep folders on top when sorting by name", "foldersOnTop"),
            box("Show Cirrus in the menu bar", "menuBarIcon", #selector(menuBarToggled(_:))),
            login,
            header("Photos"),
            box("Include the Live Photo video (.MOV) when dragging or exporting photos", "exportLive"),
            box("Export the edited version instead of the original when one exists", "exportEdited"),
            box("Group photo grids by month", "groupPhotosByMonth"),
            header("Transfers"),
            NSStackView(views: [NSTextField(labelWithString: "Simultaneous transfers:"), concurrency]),
            header("Privacy"),
            note("Apple ID sessions are kept in your login Keychain on this Mac only. Passwords are saved only if you ask, and only go to Apple. Thumbnails and listings are cached in ~/Library/Caches/Cirrus."),
            NSButton(title: "Clear Caches", target: self, action: #selector(clearCaches)),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        w.contentView = stack
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func header(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 13, weight: .semibold); return t }
    func note(_ s: String) -> NSTextField { let t = NSTextField(wrappingLabelWithString: s); t.font = .systemFont(ofSize: 11); t.textColor = .secondaryLabelColor; t.preferredMaxLayoutWidth = 470; return t }

    @objc func toggled(_ b: NSButton) {
        guard let k = b.identifier?.rawValue else { return }
        UserDefaults.standard.set(b.state == .on, forKey: k)
        if k == "showHidden" { Catalog.shared.memory.removeAll() }
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] { for p in wc.panes { p.reload() } }
    }
    @objc func authToggled(_ b: NSButton) { UserDefaults.standard.set(b.state == .on, forKey: "requireAuthForSavedPassword") }

    @objc func readOnlyToggled(_ b: NSButton) {
        if b.state == .off {
            let a = NSAlert()
            a.messageText = "Allow Cirrus to change iCloud?"
            a.informativeText = "Uploads, renames, moves, deletions (to Recently Deleted) and photo edits will be allowed. Backups and downloads work either way."
            a.addButton(withTitle: "Allow Changes"); a.addButton(withTitle: "Keep Read-Only")
            if a.runModal() != .alertFirstButtonReturn { b.state = .on; return }
        }
        Prefs.readOnlyICloud = b.state == .on
        Catalog.shared.memory.removeAll()
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] { for p in wc.panes { p.reload() } }
    }

    @objc func menuBarToggled(_ b: NSButton) { UserDefaults.standard.set(b.state == .on, forKey: "menuBarIcon"); (NSApp.delegate as? AppDelegate)?.updateStatusItem() }
    @objc func loginToggled(_ b: NSButton) { AppDelegate.setLaunchAtLogin(b.state == .on) }
    @objc func concurrencyChanged(_ p: NSPopUpButton) {
        let n = Int(p.titleOfSelectedItem ?? "4") ?? 4
        UserDefaults.standard.set(n, forKey: "maxTransfers")
        TransferManager.shared.maxConcurrent = n
    }
    @objc func clearCaches() {
        for d in ["thumbs", "listings", "Preview", "Open", "relay", "tmp"] { try? FileManager.default.removeItem(at: Paths.caches.appendingPathComponent(d)) }
        Thumbnails.shared.cache.removeAllObjects()
        Catalog.shared.memory.removeAll()
    }
}

enum SMAppServiceStatus { static var isEnabled: Bool { SMAppService.mainApp.status == .enabled } }
