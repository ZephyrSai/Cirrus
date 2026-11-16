import AppKit
import CirrusCore

/// “Back Up iCloud”: pick an account and a drive, measure everything against free space, then
/// download it all (incrementally) — optionally every time that drive is connected.
@MainActor
final class BackupWindowController: NSWindowController {
    let accountPopup = NSPopUpButton()
    let destPopup = NSPopUpButton()
    let includeDrive = NSButton(checkboxWithTitle: "iCloud Drive — all files and folders", target: nil, action: nil)
    let includePhotos = NSButton(checkboxWithTitle: "Photos and videos — original files", target: nil, action: nil)
    let live = NSButton(checkboxWithTitle: "Live Photo videos (.MOV)", target: nil, action: nil)
    let edited = NSButton(checkboxWithTitle: "Edited versions too (-edited)", target: nil, action: nil)
    let raw = NSButton(checkboxWithTitle: "RAW files of RAW+JPEG pairs", target: nil, action: nil)
    let hidden = NSButton(checkboxWithTitle: "Hidden album", target: nil, action: nil)
    let shared = NSButton(checkboxWithTitle: "Shared Library", target: nil, action: nil)
    let albums = NSButton(checkboxWithTitle: "Album folders (links, no extra space)", target: nil, action: nil)
    let layoutPopup = NSPopUpButton()
    let archive = NSButton(checkboxWithTitle: "Keep files that were deleted from iCloud (recommended)", target: nil, action: nil)
    let verify = NSButton(checkboxWithTitle: "Verify each download’s size", target: nil, action: nil)
    let schedulePopup = NSPopUpButton()
    let bar = StorageBar(frame: NSRect(x: 0, y: 0, width: 520, height: 62))
    let summary = NSTextField(wrappingLabelWithString: "Choose what to back up and where, then select Check Space.")
    let warnings = NSTextField(wrappingLabelWithString: "")
    let fitIcon = NSImageView()
    let spinner = NSProgressIndicator()
    let progress = NSProgressIndicator()
    let checkButton = NSButton(title: "Check Space", target: nil, action: nil)
    let runButton = NSButton(title: "Back Up Now", target: nil, action: nil)
    let saveButton = NSButton(title: "Save as Automatic Backup", target: nil, action: nil)
    var accounts = [Account]()
    var destinations = [URL]()
    var evaluation: BackupEngine.Evaluation?
    var evalTask: Task<Void, Never>?
    var runningTransfer: Transfer?
    var observers = [NSObjectProtocol]()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Back Up iCloud"
        w.setFrameAutosaveName("CirrusBackup")
        super.init(window: w)
        build()
        reloadAccounts()
        reloadDestinations()
        for n in [AccountManager.changed, DeviceManager.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { if note.name == DeviceManager.changed { self?.reloadDestinations() } else { self?.reloadAccounts() } }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunProgress() }
        })
        if w.frameAutosaveName.isEmpty || !w.setFrameUsingName("CirrusBackup") { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func label(_ s: String, bold: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        return t
    }

    func build() {
        let intro = NSTextField(wrappingLabelWithString: "Cirrus downloads your iCloud Drive and full-resolution photos to a drive you choose — a real, browsable copy, not an opaque backup file. Later runs only fetch what’s new. Nothing is ever deleted from iCloud.")
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 540
        for b in [includeDrive, includePhotos, live, edited, raw, hidden, shared, albums, archive, verify] { b.target = self; b.action = #selector(optionsChanged) }
        let o = SyncOptions()
        includeDrive.state = .on; includePhotos.state = .on
        live.state = o.includeLive ? .on : .off; edited.state = o.includeEdited ? .on : .off; raw.state = o.includeRAW ? .on : .off
        hidden.state = .off; shared.state = .on; albums.state = .off; archive.state = .on; verify.state = .on
        layoutPopup.addItems(withTitles: ["Year / Month (2026/11)", "Year / Month / Day", "Year", "One folder"])
        layoutPopup.target = self; layoutPopup.action = #selector(optionsChanged)
        schedulePopup.addItems(withTitles: ["Only when I click Back Up Now", "Automatically when this drive is connected", "Every day at 2:00", "Every 6 hours"])
        accountPopup.target = self; accountPopup.action = #selector(optionsChanged)
        destPopup.target = self; destPopup.action = #selector(destChanged)
        let sub = NSStackView(views: [live, edited, raw, hidden, shared, albums])
        sub.orientation = .vertical; sub.alignment = .leading; sub.spacing = 4
        sub.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        let layoutRow = NSStackView(views: [label("Photo folders:"), layoutPopup])
        layoutRow.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        let grid = NSGridView(views: [[label("Back up:", bold: true), accountPopup], [label("To:", bold: true), destPopup], [label("Schedule:", bold: true), schedulePopup]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        for p in [accountPopup, destPopup, schedulePopup] {
            p.widthAnchor.constraint(equalToConstant: 420).isActive = true
            (p.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 62).isActive = true
        bar.isHidden = true
        bar.widthAnchor.constraint(equalToConstant: 540).isActive = true
        summary.preferredMaxLayoutWidth = 520
        summary.font = .systemFont(ofSize: 12)
        warnings.preferredMaxLayoutWidth = 540
        warnings.font = .systemFont(ofSize: 11.5)
        warnings.textColor = .systemOrange
        fitIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        let sumRow = NSStackView(views: [fitIcon, summary])
        sumRow.alignment = .top
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 540).isActive = true
        for b in [checkButton, runButton, saveButton] { b.bezelStyle = .push; b.target = self }
        checkButton.action = #selector(evaluate)
        runButton.action = #selector(runNow)
        runButton.keyEquivalent = "\r"
        runButton.isEnabled = false
        saveButton.action = #selector(saveJob)
        let buttons = NSStackView(views: [spinner, NSView(), saveButton, checkButton, runButton])
        buttons.widthAnchor.constraint(equalToConstant: 540).isActive = true
        let whatLabel = label("Include", bold: true)
        let optsLabel = label("Options", bold: true)
        let usageLabel = label("Space", bold: true)
        let root = NSStackView(views: [intro, grid, whatLabel, includeDrive, includePhotos, sub, layoutRow, optsLabel, archive, verify, usageLabel, bar, sumRow, warnings, progress, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 20, right: 28)
        for v in [whatLabel, optsLabel, usageLabel] { root.setCustomSpacing(4, after: v) }
        root.setCustomSpacing(16, after: intro)
        root.setCustomSpacing(16, after: grid)
        root.setCustomSpacing(14, after: layoutRow)
        root.setCustomSpacing(14, after: verify)
        let scroll = NSScrollView()
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(root)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        window?.contentView = scroll
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.topAnchor.constraint(equalTo: doc.topAnchor), root.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: doc.trailingAnchor), root.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    func reloadAccounts() {
        let previous = accountPopup.indexOfSelectedItem >= 0 && accountPopup.indexOfSelectedItem < accounts.count ? accounts[accountPopup.indexOfSelectedItem].id : nil
        accounts = AccountManager.shared.accounts.filter { $0.isICloud && ($0.hasDrive || $0.photos != nil) }
        accountPopup.removeAllItems()
        for a in accounts {
            let t: String
            switch a.kind {
            case .mac: t = AccountManager.macSignedInToICloud ? "This Mac’s iCloud (iCloud Drive folder + Photos library)" : "This Mac’s Photos library"
            case .web: t = "\(a.appleID ?? a.title)" + (a.status == .needsSignIn ? " — sign in needed" : "")
            case .demo: t = Debug.screenshotMode ? "alex@example.com" : "Demo iCloud"
            case .cloud: t = a.title
            }
            accountPopup.addItem(withTitle: t)
        }
        if accounts.isEmpty { accountPopup.addItem(withTitle: "No iCloud account — sign in first") }
        if let p = previous, let i = accounts.firstIndex(where: { $0.id == p }) { accountPopup.selectItem(at: i) }
        else if let i = accounts.firstIndex(where: { $0.kind == .web }) { accountPopup.selectItem(at: i) }
        optionsChanged()
    }

    func reloadDestinations() {
        let prev = destPopup.indexOfSelectedItem >= 0 && destPopup.indexOfSelectedItem < destinations.count ? destinations[destPopup.indexOfSelectedItem] : nil
        destinations = []
        destPopup.removeAllItems()
        let externals = DeviceManager.shared.volumes.filter { !$0.isRoot }
        for v in externals {
            destinations.append(v.url)
            destPopup.addItem(withTitle: "\(v.name) — \(v.available.byteString) free" + (v.format.map { " (\($0))" } ?? ""))
            destPopup.lastItem?.image = NSWorkspace.shared.icon(forFile: v.url.path).resized(16)
        }
        if let root = DeviceManager.shared.volumes.first(where: \.isRoot) {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("iCloud Backup", isDirectory: true)
            destinations.append(dir)
            destPopup.addItem(withTitle: "This Mac — ~/iCloud Backup — \(root.available.byteString) free")
            destPopup.lastItem?.image = NSWorkspace.shared.icon(forFile: "/").resized(16)
        }
        if let custom = UserDefaults.standard.string(forKey: "backupCustomDest"), !destinations.contains(URL(fileURLWithPath: custom)) {
            destinations.append(URL(fileURLWithPath: custom, isDirectory: true))
            let vol = VolumeInfo.info(for: URL(fileURLWithPath: custom))
            destPopup.addItem(withTitle: "\((custom as NSString).lastPathComponent) on \(vol?.name ?? "disk") — \((VolumeInfo.freeSpace(at: URL(fileURLWithPath: custom)) ?? 0).byteString) free")
            destPopup.lastItem?.toolTip = custom
        }
        destPopup.menu?.addItem(.separator())
        destPopup.addItem(withTitle: "Choose a Folder…")
        if let p = prev, let i = destinations.firstIndex(of: p) { destPopup.selectItem(at: i) } else { destPopup.selectItem(at: 0) }
        updateScheduleAvailability()
    }

    var selectedAccount: Account? { accountPopup.indexOfSelectedItem < accounts.count && accountPopup.indexOfSelectedItem >= 0 ? accounts[accountPopup.indexOfSelectedItem] : nil }
    var selectedDest: URL? { destPopup.indexOfSelectedItem >= 0 && destPopup.indexOfSelectedItem < destinations.count ? destinations[destPopup.indexOfSelectedItem] : nil }

    @objc func destChanged() {
        if destPopup.titleOfSelectedItem == "Choose a Folder…" {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Back Up Here"
            p.beginSheetModal(for: window!) { r in
                if r == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "backupCustomDest") }
                self.reloadDestinations()
                if let u = p.url, let i = self.destinations.firstIndex(of: u) { self.destPopup.selectItem(at: i) }
                self.optionsChanged()
            }
            return
        }
        updateScheduleAvailability()
        optionsChanged()
    }

    func updateScheduleAvailability() {
        let external = selectedDest.flatMap { VolumeInfo.info(for: $0) }.map { !$0.isRoot } ?? false
        schedulePopup.item(at: 1)?.isEnabled = external
        schedulePopup.autoenablesItems = false
        if !external && schedulePopup.indexOfSelectedItem == 1 { schedulePopup.selectItem(at: 0) }
    }

    @objc func optionsChanged() {
        let photosOn = includePhotos.state == .on
        for b in [live, edited, raw, hidden, shared, albums] { b.isEnabled = photosOn }
        layoutPopup.isEnabled = photosOn
        shared.isEnabled = photosOn && selectedAccount?.kind == .web
        evaluation = nil
        runButton.isEnabled = false
        fitIcon.image = nil
        if !(evalTask.map { !$0.isCancelled } ?? false) { summary.stringValue = "Choose what to back up and where, then select Check Space." }
        warnings.stringValue = ""
    }

    var options: SyncOptions {
        var o = SyncOptions()
        o.includeDrive = includeDrive.state == .on
        o.includePhotos = includePhotos.state == .on
        o.includeLive = live.state == .on
        o.includeEdited = edited.state == .on
        o.includeRAW = raw.state == .on
        o.includeHidden = hidden.state == .on
        o.includeSharedLibrary = shared.state == .on
        o.albumFolders = albums.state == .on
        o.photoLayout = ["{yyyy}/{MM}", "{yyyy}/{MM}/{dd}", "{yyyy}", "flat"][max(0, layoutPopup.indexOfSelectedItem)]
        o.keepDeleted = archive.state == .on
        o.verify = verify.state == .on
        return o
    }

    func makeJob() -> SyncJob? {
        guard let a = selectedAccount, let d = selectedDest else { return nil }
        var j = SyncJob(name: "Back up \(a.kind == .mac ? "This Mac’s iCloud" : (a.appleID ?? a.title)) to \(VolumeInfo.info(for: d)?.name ?? d.lastPathComponent)",
                        kind: .backup, source: .account(a.id), destination: .local(path: d.path))
        j.options = options
        switch schedulePopup.indexOfSelectedItem {
        case 1: j.schedule = JobScheduler.uuid(d).map { .whenConnected(volumeUUID: $0) } ?? .manual
        case 2: j.schedule = .daily(hour: 2)
        case 3: j.schedule = .every(minutes: 360)
        default: j.schedule = .manual
        }
        return j
    }

    @objc func evaluate() {
        guard let job = makeJob() else { summary.stringValue = "Sign in to an iCloud account first (File › Sign In with Apple ID…)."; return }
        guard options.includeDrive || options.includePhotos else { summary.stringValue = "Pick at least one thing to back up."; return }
        evalTask?.cancel()
        spinner.startAnimation(nil)
        checkButton.isEnabled = false
        fitIcon.image = nil
        warnings.stringValue = ""
        bar.usage = nil
        summary.stringValue = "Measuring…"
        evalTask = Task {
            defer { spinner.stopAnimation(nil); checkButton.isEnabled = true }
            do {
                let engine = try JobRunner.shared.backupEngine(job)
                let ev = try await engine.evaluate { s in Task { @MainActor in self.summary.stringValue = s } }
                guard !Task.isCancelled else { return }
                show(ev)
            } catch {
                summary.stringValue = error.localizedDescription
                fitIcon.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
                fitIcon.contentTintColor = .systemRed
            }
        }
    }

    func show(_ ev: BackupEngine.Evaluation) {
        evaluation = ev
        bar.usage = ev.storage
        bar.isHidden = ev.storage == nil
        func left(_ b: Int64) -> String { b == 0 ? "already backed up" : "\(b.byteString) still to download" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        var lines = [String]()
        if let s = ev.storage { lines.append("iCloud storage: \(s.used.byteString) used of \(s.total.byteString).") }
        else { lines.append(selectedAccount?.kind == .mac ? "iCloud storage: managed by macOS for this Mac’s account." : "iCloud storage: not reported for this account.") }
        if options.includeDrive { lines.append("iCloud Drive: \(f.string(from: NSNumber(value: ev.driveFiles))!) files, \(ev.driveBytes.byteString) — \(left(ev.drivePendingBytes)).") }
        if options.includePhotos {
            for p in ev.photos {
                lines.append("Photos (\(p.library.name)): \(f.string(from: NSNumber(value: p.assetCount))!) items, \(p.totalBytes.byteString) — \(left(p.pendingBytes)).")
            }
        }
        lines.append(ev.pendingBytes == 0 ? "Destination: \(ev.free.byteString) free; nothing new to download." : "Destination: \(ev.free.byteString) free; this run needs \(ev.requiredFree.byteString) including headroom.")
        summary.stringValue = lines.joined(separator: "\n")
        warnings.stringValue = ev.warnings.map { "⚠︎ " + $0 }.joined(separator: "\n")
        fitIcon.image = NSImage(systemSymbolName: ev.fits ? "checkmark.circle.fill" : "xmark.octagon.fill", accessibilityDescription: nil)
        fitIcon.contentTintColor = ev.fits ? .systemGreen : .systemRed
        runButton.isEnabled = ev.fits && ev.pendingBytes >= 0
        runButton.title = ev.pendingBytes == 0 ? "Back Up Now (up to date)" : "Back Up \(ev.pendingBytes.byteString) Now"
    }

    @objc func runNow() {
        guard var job = makeJob() else { return }
        // Reuse a saved job for the same account + destination so its history and schedule stay together.
        if let existing = SyncStore.shared.jobs.first(where: { $0.kind == .backup && $0.source == job.source && $0.destination == job.destination }) {
            job.id = existing.id; job.schedule = existing.schedule; job.lastRun = existing.lastRun
            SyncStore.shared.upsert(job)
        }
        JobRunner.shared.run(job, window: window)
        runningTransfer = TransferManager.shared.transfers.last { $0.group == "job:" + job.id.uuidString }
        if !SyncStore.shared.jobs.contains(where: { $0.id == job.id }) { tempJobs.insert(job.id) }
        progress.isHidden = false
        runButton.isEnabled = false
    }
    var tempJobs = Set<UUID>()

    func updateRunProgress() {
        guard let t = runningTransfer else { return }
        progress.doubleValue = t.fraction
        if t.isFinished {
            progress.isHidden = true
            switch t.state {
            case .done: summary.stringValue = "Backup finished: \(t.detail). Open the folder from Transfers or Finder."
            case .failed(let m): summary.stringValue = "Backup stopped: \(m)"
            default: summary.stringValue = "Backup stopped."
            }
            runningTransfer = nil
            runButton.isEnabled = true
        } else {
            summary.stringValue = t.detail + (t.total > 0 ? "\n\(t.completed.byteString) of \(t.total.byteString)" + (t.etaText.map { " — " + $0 } ?? "") : "")
        }
    }

    @objc func saveJob() {
        guard let job = makeJob() else { return }
        if let existing = SyncStore.shared.jobs.first(where: { $0.kind == .backup && $0.source == job.source && $0.destination == job.destination }) {
            var j = job; j.id = existing.id; j.lastRun = existing.lastRun
            SyncStore.shared.upsert(j)
        } else { SyncStore.shared.upsert(job) }
        let a = NSAlert()
        a.messageText = "Automatic backup saved"
        a.informativeText = "“\(job.name)” runs \(job.schedule.title.lowercased()). Keep Cirrus running (it can live in the menu bar) for scheduled backups. Find it under Sync & Backup in the sidebar."
        a.beginSheetModal(for: window!)
    }
}

extension NSImage {
    func resized(_ side: CGFloat) -> NSImage { let i = copy() as! NSImage; i.size = NSSize(width: side, height: side); return i }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
