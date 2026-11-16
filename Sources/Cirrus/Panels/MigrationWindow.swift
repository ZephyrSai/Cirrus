import AppKit
import CirrusCore

extension AppDelegate {
    @objc func showMigration(_ sender: Any?) { MigrationWindowController.show() }
}

/// “Move to Google”: copy iCloud Drive into a “From iCloud” folder in Google Drive and iCloud Photos
/// into Google Photos (with albums). Check Space first; runs are incremental and iCloud isn't changed.
@MainActor
final class MigrationWindowController: NSWindowController {
    static var shared: MigrationWindowController?

    static func show() {
        if shared == nil { shared = MigrationWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    let accountPopup = NSPopUpButton()
    let googlePopup = NSPopUpButton()
    let connectButton = NSButton(title: "Connect Google…", target: nil, action: nil)
    let setupButton = NSButton(title: "Set Up Google Access…", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let includeDrive = NSButton(checkboxWithTitle: "iCloud Drive → Google Drive, into a “From iCloud” folder", target: nil, action: nil)
    let includePhotos = NSButton(checkboxWithTitle: "Photos and videos → Google Photos (original files)", target: nil, action: nil)
    let albums = NSButton(checkboxWithTitle: "Recreate my albums", target: nil, action: nil)
    let favorites = NSButton(checkboxWithTitle: "Favorites as an album (“Favorites from iCloud”)", target: nil, action: nil)
    let live = NSButton(checkboxWithTitle: "Live Photos: the video part too, as a separate clip", target: nil, action: nil)
    let edited = NSButton(checkboxWithTitle: "Edited versions too, as separate photos", target: nil, action: nil)
    let raw = NSButton(checkboxWithTitle: "RAW files of RAW+JPEG pairs", target: nil, action: nil)
    let hidden = NSButton(checkboxWithTitle: "Hidden photos (they won’t be hidden in Google Photos)", target: nil, action: nil)
    let shared = NSButton(checkboxWithTitle: "Shared Library", target: nil, action: nil)
    let updateChanged = NSButton(checkboxWithTitle: "Update files changed in iCloud since the last run (the old copy goes to Google Drive’s trash)", target: nil, action: nil)
    let icloudBar = StorageBar(frame: NSRect(x: 0, y: 0, width: 520, height: 62))
    let googleBar = StorageBar(frame: NSRect(x: 0, y: 0, width: 520, height: 62))
    let icloudBarLabel = NSTextField(labelWithString: "iCloud")
    let googleBarLabel = NSTextField(labelWithString: "Google")
    let summary = NSTextField(wrappingLabelWithString: "")
    let warnings = NSTextField(wrappingLabelWithString: "")
    let fitIcon = NSImageView()
    let detailsLabel = NSTextField(labelWithString: "")
    let detailsScroll = NSScrollView()
    let detailsText = NSTextView()
    let spinner = NSProgressIndicator()
    let progress = NSProgressIndicator()
    let checkButton = NSButton(title: "Check Space", target: nil, action: nil)
    let runButton = NSButton(title: "Move to Google", target: nil, action: nil)
    let openDrive = NSButton(title: "Open in Google Drive", target: nil, action: nil)
    let openPhotos = NSButton(title: "Open Google Photos", target: nil, action: nil)
    let directionControl = NSSegmentedControl(labels: ["iCloud → Google", "Google → iCloud"], trackingMode: .selectOne, target: nil, action: nil)
    let introLabel = NSTextField(wrappingLabelWithString: "")
    let importPanel = ImportPanel()
    var forwardViews = [NSView]()
    var importEvaluation: ImportEngine.Evaluation?
    var importEngine: ImportEngine?
    var lastImportReport: ImportEngine.Report?
    var runningIsImport = false
    var pickTask: Task<Void, Never>?
    static let forwardIntro = "Cirrus copies your iCloud Drive into a “From iCloud” folder in Google Drive, and your photos and videos — original files, with their albums — into Google Photos. iCloud isn’t changed, and later runs only send what’s new."

    var accounts = [Account]()
    var googleAccounts = [GoogleAccountInfo]()
    var evaluation: MigrationEngine.Evaluation?
    var engine: MigrationEngine?
    var evalTask: Task<Void, Never>?
    var connectTask: Task<Void, Never>?
    var runningTransfer: Transfer?
    var lastReport: MigrationEngine.Report?
    var setupSheet: GoogleSetupSheet?
    var waitSheet: NSWindow?
    var observers = [NSObjectProtocol]()
    let idleText = "Choose what to move, then select Check Space. Nothing in iCloud is changed."

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Move to Google"
        super.init(window: w)
        if Debug.headless { w.setFrameOrigin(NSPoint(x: -30000, y: -30000)) } else {
            w.setFrameAutosaveName("CirrusMigration")
            if !w.setFrameUsingName("CirrusMigration") { w.center() }
        }
        build()
        applyDirection()
        reloadAccounts()
        reloadGoogle()
        observers.append(NotificationCenter.default.addObserver(forName: AccountManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAccounts() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: GoogleAccounts.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadGoogle() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunProgress() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    func label(_ s: String, bold: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        return t
    }

    func build() {
        let intro = introLabel
        intro.stringValue = Self.forwardIntro
        directionControl.selectedSegment = 0
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))
        let dirRow = NSStackView(views: [label("Direction:", bold: true), directionControl])
        dirRow.spacing = 10
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 560
        let o = MigrationOptions()
        for b in [includeDrive, includePhotos, albums, favorites, live, edited, raw, hidden, shared, updateChanged] { b.target = self; b.action = #selector(optionsChanged) }
        includeDrive.state = o.includeDrive ? .on : .off
        includePhotos.state = o.includePhotos ? .on : .off
        albums.state = o.albums ? .on : .off
        favorites.state = o.favoritesAlbum ? .on : .off
        live.state = o.includeLive ? .on : .off
        edited.state = o.includeEdited ? .on : .off
        raw.state = o.includeRAW ? .on : .off
        hidden.state = o.includeHidden ? .on : .off
        shared.state = o.includeSharedLibrary ? .on : .off
        updateChanged.state = o.updateChanged ? .on : .off
        accountPopup.target = self; accountPopup.action = #selector(optionsChanged)
        googlePopup.target = self; googlePopup.action = #selector(googleChanged)
        for p in [accountPopup, googlePopup] {
            p.widthAnchor.constraint(equalToConstant: 440).isActive = true
            (p.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        for b in [connectButton, setupButton, disconnectButton] { b.bezelStyle = .push; b.controlSize = .small; b.target = self }
        connectButton.action = #selector(connectGoogle(_:))
        setupButton.action = #selector(showSetup(_:))
        disconnectButton.action = #selector(disconnectGoogle(_:))
        let googleButtons = NSStackView(views: [connectButton, setupButton, disconnectButton])
        googleButtons.spacing = 6
        let grid = NSGridView(views: [[label("iCloud:", bold: true), accountPopup], [label("Google:", bold: true), googlePopup], [NSGridCell.emptyContentView, googleButtons]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        let sub = NSStackView(views: [albums, favorites, live, edited, raw, hidden, shared])
        sub.orientation = .vertical; sub.alignment = .leading; sub.spacing = 4
        sub.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        for (bar, l) in [(icloudBar, icloudBarLabel), (googleBar, googleBarLabel)] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 62).isActive = true
            bar.widthAnchor.constraint(equalToConstant: 560).isActive = true
            bar.isHidden = true
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.isHidden = true
        }
        summary.preferredMaxLayoutWidth = 530
        summary.font = .systemFont(ofSize: 12)
        summary.stringValue = idleText
        warnings.preferredMaxLayoutWidth = 560
        warnings.font = .systemFont(ofSize: 11.5)
        warnings.textColor = .systemOrange
        fitIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        let sumRow = NSStackView(views: [fitIcon, summary])
        sumRow.alignment = .top
        detailsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        detailsLabel.isHidden = true
        detailsText.isEditable = false
        detailsText.isSelectable = true
        detailsText.font = .systemFont(ofSize: 11)
        detailsText.textColor = .secondaryLabelColor
        detailsText.drawsBackground = false
        detailsText.textContainerInset = NSSize(width: 4, height: 4)
        detailsScroll.documentView = detailsText
        detailsScroll.hasVerticalScroller = true
        detailsScroll.borderType = .bezelBorder
        detailsScroll.translatesAutoresizingMaskIntoConstraints = false
        detailsScroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        detailsScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        detailsText.autoresizingMask = [.width]
        detailsText.frame = NSRect(x: 0, y: 0, width: 556, height: 96)
        detailsScroll.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 560).isActive = true
        for b in [checkButton, runButton, openDrive, openPhotos] { b.bezelStyle = .push; b.target = self }
        checkButton.action = #selector(evaluate)
        runButton.action = #selector(runNow)
        runButton.keyEquivalent = "\r"
        runButton.isEnabled = false
        openDrive.action = #selector(openDriveFolder(_:))
        openPhotos.action = #selector(openGooglePhotos(_:))
        openDrive.isHidden = true
        openPhotos.isHidden = true
        let buttons = NSStackView(views: [spinner, NSView(), openDrive, openPhotos, checkButton, runButton])
        buttons.widthAnchor.constraint(equalToConstant: 560).isActive = true
        let whatLabel = label("Include", bold: true), optsLabel = label("Options", bold: true), spaceLabel = label("Space", bold: true)
        let importView = importPanel.build(owner: self)
        forwardViews = [whatLabel, includeDrive, includePhotos, sub, optsLabel, updateChanged]
        let root = NSStackView(views: [intro, dirRow, grid, whatLabel, includeDrive, includePhotos, sub, optsLabel, updateChanged, importView, spaceLabel,
                                       icloudBarLabel, icloudBar, googleBarLabel, googleBar, sumRow, warnings, detailsLabel, detailsScroll, progress, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 20, left: 28, bottom: 20, right: 28)
        for v in [whatLabel, optsLabel, spaceLabel, icloudBarLabel, googleBarLabel, detailsLabel] { root.setCustomSpacing(3, after: v) }
        root.setCustomSpacing(16, after: intro)
        root.setCustomSpacing(14, after: dirRow)
        root.setCustomSpacing(14, after: importView)
        root.setCustomSpacing(16, after: grid)
        root.setCustomSpacing(14, after: sub)
        root.setCustomSpacing(14, after: updateChanged)
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

    // MARK: Accounts

    func reloadAccounts() {
        let previous = selectedAccount?.id
        accounts = AccountManager.shared.accounts.filter { $0.isICloud && ($0.hasDrive || $0.photos != nil) }
        accountPopup.removeAllItems()
        for a in accounts {
            switch a.kind {
            case .mac: accountPopup.addItem(withTitle: AccountManager.macSignedInToICloud ? "This Mac’s iCloud (iCloud Drive folder + Photos library)" : "This Mac’s Photos library")
            case .web: accountPopup.addItem(withTitle: (a.appleID ?? a.title) + (a.status == .needsSignIn ? " — sign in needed" : ""))
            case .demo: accountPopup.addItem(withTitle: "Demo iCloud")
            case .cloud: accountPopup.addItem(withTitle: a.title)
            }
        }
        if accounts.isEmpty { accountPopup.addItem(withTitle: "No iCloud account — sign in first") }
        if let p = previous, let i = accounts.firstIndex(where: { $0.id == p }) { accountPopup.selectItem(at: i) }
        else if let i = accounts.firstIndex(where: { $0.kind == .web || $0.kind == .demo }) { accountPopup.selectItem(at: i) }
        optionsChanged()
    }

    func reloadGoogle(select id: String? = nil) {
        let previous = id ?? selectedGoogle?.id
        googleAccounts = GoogleAccounts.shared.accounts
        googlePopup.removeAllItems()
        for g in googleAccounts {
            var t = g.label
            if !g.has(GoogleScopes.driveFile) { t += " — Photos only" } else if !g.has(GoogleScopes.photosAppend) { t += " — Drive only" }
            googlePopup.addItem(withTitle: t)
            googlePopup.lastItem?.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        }
        if googleAccounts.isEmpty {
            googlePopup.addItem(withTitle: GoogleAccounts.shared.isConfigured ? "No Google account connected" : "Google access isn’t set up yet")
        }
        if let p = previous, let i = googleAccounts.firstIndex(where: { $0.id == p }) { googlePopup.selectItem(at: i) }
        let configured = GoogleAccounts.shared.isConfigured
        connectButton.title = googleAccounts.isEmpty ? "Connect Google…" : "Connect Another…"
        connectButton.isEnabled = connectTask == nil
        setupButton.title = configured ? "Google Client…" : "Set Up Google Access…"
        disconnectButton.isEnabled = selectedGoogle != nil
        optionsChanged()
    }

    var selectedAccount: Account? { accounts.indices.contains(accountPopup.indexOfSelectedItem) ? accounts[accountPopup.indexOfSelectedItem] : nil }
    var selectedGoogle: GoogleAccountInfo? { googleAccounts.indices.contains(googlePopup.indexOfSelectedItem) ? googleAccounts[googlePopup.indexOfSelectedItem] : nil }

    @objc func googleChanged() { disconnectButton.isEnabled = selectedGoogle != nil; optionsChanged() }

    @objc func optionsChanged() {
        let photosOn = includePhotos.state == .on
        for b in [albums, favorites, live, edited, raw, hidden, shared] { b.isEnabled = photosOn }
        shared.isEnabled = photosOn && selectedAccount?.kind == .web
        favorites.isEnabled = photosOn && albums.state == .on
        evaluation = nil
        engine = nil
        importEvaluation = nil
        importEngine = nil
        importPanel.refresh(for: selectedGoogle)
        runButton.isEnabled = false
        runButton.title = isImport ? "Copy to iCloud" : "Move to Google"
        fitIcon.image = nil
        warnings.stringValue = ""
        if !(evalTask.map { !$0.isCancelled } ?? false) && runningTransfer == nil {
            summary.stringValue = selectedGoogle == nil
                ? (GoogleAccounts.shared.isConfigured ? "Connect a Google account to \(isImport ? "copy from" : "move to")." : "First, set up Google access (about five minutes, once), then connect your Google account.")
                : (isImport ? importIdleText : idleText)
        }
    }

    var options: MigrationOptions {
        var o = MigrationOptions()
        o.includeDrive = includeDrive.state == .on
        o.includePhotos = includePhotos.state == .on
        o.albums = albums.state == .on
        o.favoritesAlbum = favorites.state == .on && albums.state == .on
        o.includeLive = live.state == .on
        o.includeEdited = edited.state == .on
        o.includeRAW = raw.state == .on
        o.includeHidden = hidden.state == .on
        o.includeSharedLibrary = shared.state == .on
        o.updateChanged = updateChanged.state == .on
        return o
    }

    // MARK: Google setup and sign-in

    @objc func showSetup(_ sender: Any?) { presentSetup(thenConnect: false) }

    func presentSetup(thenConnect: Bool) {
        guard let w = window, w.attachedSheet == nil else { return }
        let s = GoogleSetupSheet()
        s.completion = { [weak self] saved, connect in
            self?.setupSheet = nil
            self?.reloadGoogle()
            if saved && (connect || thenConnect) { self?.startConnect(scopes: self?.isImport == true ? GoogleAccounts.importScopes : GoogleScopes.all) }
        }
        setupSheet = s
        w.beginSheet(s.window!)
    }

    @objc func connectGoogle(_ sender: Any?) {
        if !GoogleAccounts.shared.isConfigured { presentSetup(thenConnect: true); return }
        startConnect(scopes: isImport ? GoogleAccounts.importScopes : GoogleScopes.all)
    }

    /// Signs in (again) asking for `scopes`; reconnecting the selected account adds permissions to it.
    func startConnect(scopes: [String], hint: String? = nil, then: (() -> Void)? = nil) {
        guard connectTask == nil, let w = window, w.attachedSheet == nil else { return }
        let sheet = makeWaitSheet(title: "Finish in your browser",
                                  text: "Google’s page opened in your browser. Choose your account, select Continue on the “Google hasn’t verified this app” page (it’s your own project), and tick every permission Cirrus asks for.")
        waitSheet = sheet
        w.beginSheet(sheet)
        connectButton.isEnabled = false
        connectTask = Task {
            defer {
                connectTask = nil
                if let s = waitSheet { w.endSheet(s); waitSheet = nil }
                connectButton.isEnabled = true
            }
            do {
                let info = try await GoogleAccounts.shared.connect(scopes: scopes, loginHint: hint)
                reloadGoogle(select: info.id)
                let names = [GoogleScopes.driveFile: "adding to Google Drive", GoogleScopes.photosAppend: "adding to Google Photos",
                             GoogleScopes.driveReadonly: "reading Google Drive", GoogleScopes.photosPicker: "picking from Google Photos"]
                let missing = scopes.filter { !info.has($0) }.compactMap { names[$0] }
                if !missing.isEmpty {
                    summary.stringValue = "Connected, but Google didn’t allow \(missing.joined(separator: " or ")). Connect again and tick every box on Google’s page to include it."
                } else { then?() }
            } catch GoogleError.cancelled {
                summary.stringValue = "Connecting to Google was cancelled."
            } catch {
                summary.stringValue = error.localizedDescription
                fitIcon.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
                fitIcon.contentTintColor = .systemRed
            }
        }
    }

    func makeWaitSheet(title titleText: String, text textText: String) -> NSWindow {
        let s = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: textText)
        text.preferredMaxLayoutWidth = 370
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        let spin = NSProgressIndicator()
        spin.style = .spinning; spin.controlSize = .small
        spin.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelConnect(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [spin, NSView(), cancel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 370).isActive = true
        let v = NSStackView(views: [title, text, row])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 16, right: 24)
        s.contentView = v
        return s
    }

    @objc func cancelConnect(_ sender: Any?) { connectTask?.cancel(); pickTask?.cancel() }

    @objc func disconnectGoogle(_ sender: Any?) {
        guard let g = selectedGoogle, let w = window else { return }
        let a = NSAlert()
        a.messageText = "Disconnect \(g.email.isEmpty ? "this Google account" : g.email)?"
        a.informativeText = "Cirrus’s access is revoked at Google and its saved sign-in is removed from this Mac. Nothing in Google Drive or Google Photos is removed, and connecting again later continues where the move stopped."
        a.addButton(withTitle: "Disconnect")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            Task { @MainActor in await GoogleAccounts.shared.disconnect(g.id) }
        }
    }

    // MARK: Evaluate and run

    func makeEngine() throws -> MigrationEngine {
        guard let a = selectedAccount else { throw SyncError.unavailable("Sign in to an iCloud account first (File › Sign In with Apple ID…).") }
        if a.status == .needsSignIn { throw ICloudError.needsSignIn }
        guard let g = selectedGoogle else { throw GoogleAccounts.shared.isConfigured ? GoogleError.reconnect("Connect a Google account first.") : GoogleError.notConfigured }
        let api = try GoogleAccounts.shared.api(for: g.id)
        var storage: (@Sendable () async -> StorageUsage?)?
        if a.session != nil { storage = { await a.storageUsage() } }
        let src = MigrationEngine.Sources(key: a.id, title: a.kind == .mac ? "This Mac" : (a.appleID ?? a.title), drive: a.drive,
                                          nativeDriveRoot: a.drive == nil ? a.driveRoot : nil, photos: a.photos, storage: storage)
        return MigrationEngine(sources: src, target: MigrationEngine.Target(api: api), options: options,
                               stateDir: Paths.supportDir("migration"), stagingDir: Paths.cacheDir("migration-staging"))
    }

    @objc func evaluate() {
        if isImport { evaluateImport(); return }
        guard options.includeDrive || options.includePhotos else { summary.stringValue = "Pick at least one thing to move."; return }
        let e: MigrationEngine
        do { e = try makeEngine() } catch {
            summary.stringValue = error.localizedDescription
            if (error as? GoogleError) == .notConfigured { presentSetup(thenConnect: true) }
            return
        }
        evalTask?.cancel()
        spinner.startAnimation(nil)
        checkButton.isEnabled = false
        fitIcon.image = nil
        warnings.stringValue = ""
        showDetails(nil, [])
        summary.stringValue = "Measuring…"
        openDrive.isHidden = true
        openPhotos.isHidden = true
        evalTask = Task {
            defer { spinner.stopAnimation(nil); checkButton.isEnabled = true; evalTask = nil }
            do {
                let ev = try await e.evaluate { s in Task { @MainActor in self.summary.stringValue = s } }
                guard !Task.isCancelled else { return }
                engine = e
                show(ev)
            } catch {
                summary.stringValue = error.localizedDescription
                fitIcon.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
                fitIcon.contentTintColor = .systemRed
            }
        }
    }

    func show(_ ev: MigrationEngine.Evaluation) {
        evaluation = ev
        icloudBar.usage = ev.icloud
        icloudBar.isHidden = ev.icloud == nil
        icloudBarLabel.isHidden = ev.icloud == nil
        let gu = ev.quota?.usageBar(adding: ev.pendingBytes)
        googleBar.usage = gu
        googleBar.isHidden = gu == nil
        googleBarLabel.isHidden = gu == nil
        googleBarLabel.stringValue = "Google (\(ev.user?.email ?? "storage")) — after this move"
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ i: Int) -> String { f.string(from: NSNumber(value: i)) ?? String(i) }
        func left(_ count: Int, _ b: Int64) -> String { count == 0 ? "already in Google" : "\(n(count)) to send (\(b.byteString))" }
        var lines = [String]()
        if ev.driveEnabled { lines.append("iCloud Drive: \(n(ev.driveFiles)) files, \(ev.driveBytes.byteString) — \(left(ev.drivePending.count, ev.drivePendingBytes)).") }
        if ev.photosEnabled {
            lines.append("Photos: \(n(ev.assetCount)) items (\(n(ev.photoFiles)) files, \(ev.photoBytes.byteString)) — \(left(ev.photoPending.count, ev.photoPendingBytes)).")
            if !ev.albums.isEmpty {
                lines.append(ev.albumAddsPending > 0 ? "Albums: \(ev.albums.count), with \(n(ev.albumAddsPending)) photo\(ev.albumAddsPending == 1 ? "" : "s") to add."
                                                     : "Albums: \(ev.albums.count) — already in Google.")
            }
        }
        if let q = ev.quota {
            if let free = q.free {
                lines.append(ev.pendingBytes == 0 ? "Google storage: \(free.byteString) free." : "Google storage: \(free.byteString) free; this move needs \(ev.requiredGoogle.byteString) with headroom.")
            } else { lines.append("Google storage: unlimited.") }
        } else if ev.photosEnabled { lines.append("Google storage: not reported (Drive access wasn’t granted) — make sure your Google account has room.") }
        summary.stringValue = lines.joined(separator: "\n")
        warnings.stringValue = ev.warnings.map { "⚠︎ " + $0 }.joined(separator: "\n")
        showDetails(ev.skipped.isEmpty ? nil : "Skipped — Google can’t store these", ev.skipped.map { "\($0.name) (\($0.size.byteString)): \($0.reason)" })
        fitIcon.image = NSImage(systemSymbolName: ev.fits ? "checkmark.circle.fill" : "xmark.octagon.fill", accessibilityDescription: nil)
        fitIcon.contentTintColor = ev.fits ? .systemGreen : .systemRed
        runButton.isEnabled = ev.fits && runningTransfer == nil
        runButton.title = ev.isUpToDate ? "Move to Google (up to date)" : "Move \(ev.pendingBytes.byteString) to Google"
    }

    func showDetails(_ title: String?, _ lines: [String]) {
        detailsLabel.isHidden = title == nil
        detailsScroll.isHidden = title == nil
        detailsLabel.stringValue = title ?? ""
        let shown = lines.prefix(2000)
        detailsText.string = shown.joined(separator: "\n") + (lines.count > shown.count ? "\n… and \(lines.count - shown.count) more" : "")
    }

    @objc func runNow() {
        if isImport { runImport(); return }
        runningIsImport = false
        guard let ev = evaluation, let e = engine, ev.fits, runningTransfer == nil else { return }
        let title = "Move \(e.sources.title) to Google"
        let total = ev.pendingBytes * 2
        runButton.isEnabled = false
        checkButton.isEnabled = false
        progress.doubleValue = 0
        progress.isHidden = false
        lastReport = nil
        runningTransfer = TransferManager.shared.enqueue(title, detail: "Starting…", direction: .upload, total: total, group: "migration") { t in
            let report = try await e.run(ev) { p in
                t.report(p.bytesDone, p.bytesTotal)
                t.setDetail(p.filesTotal > 0 ? "\(p.phase) — \(p.filesDone) of \(p.filesTotal)" : p.phase)
            }
            await MainActor.run { MigrationWindowController.shared?.lastReport = report }
            t.setDetail(report.summary)
            if let s = report.stopped { throw GoogleError.badResponse("Stopped: \(s)") }
            if !report.failed.isEmpty { throw GoogleError.badResponse("\(report.failed.count) item\(report.failed.count == 1 ? "" : "s") failed: \(report.failed.first ?? "")") }
        }
        updateRunProgress()
    }

    func updateRunProgress() {
        guard let t = runningTransfer else { return }
        progress.doubleValue = t.fraction
        guard t.isFinished else {
            summary.stringValue = t.detail + (t.total > 0 ? "\n\(t.completed.byteString) of \(t.total.byteString) moved through this Mac" + (t.etaText.map { " — " + $0 } ?? "") : "")
            return
        }
        if runningIsImport { finishImport(t); return }
        progress.isHidden = true
        runningTransfer = nil
        checkButton.isEnabled = true
        runButton.isEnabled = false
        runButton.title = "Move to Google"
        let r = lastReport
        var lines = [String]()
        switch t.state {
        case .cancelled: lines.append("The move was stopped. Select Check Space and Move to Google to continue where it stopped.")
        default:
            if let r {
                lines.append((r.stopped == nil && r.failed.isEmpty ? "Done: " : "Finished with problems: ") + r.summary + ".")
                if r.foldersCreated > 0 { lines.append("\(r.foldersCreated) folder\(r.foldersCreated == 1 ? "" : "s") created in Google Drive.") }
                if r.albumAdds > 0 { lines.append("\(r.albumAdds) photo\(r.albumAdds == 1 ? "" : "s") added to albums.") }
                if r.resumed > 0 { lines.append("\(r.resumed) interrupted upload\(r.resumed == 1 ? "" : "s") resumed.") }
                if let s = r.stopped { lines.append("Stopped early: \(s)") }
                lines.append("Run it again any time: only new and changed items are sent.")
            } else if case .failed(let m) = t.state { lines.append("The move stopped: \(m)") }
        }
        summary.stringValue = lines.joined(separator: "\n")
        let ok = r != nil && r!.stopped == nil && r!.failed.isEmpty
        fitIcon.image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        fitIcon.contentTintColor = ok ? .systemGreen : .systemOrange
        warnings.stringValue = ""
        if let r {
            showDetails(r.failed.isEmpty && r.skipped.isEmpty ? nil : "Report", r.failed.map { "Failed — " + $0 } + r.skipped.map { "Skipped — \($0.name): \($0.reason)" })
            openDrive.isHidden = r.driveFolderURL == nil
            openPhotos.isHidden = r.photosCreated == 0 && r.albumsCreated == 0
        }
        evaluation = nil
        engine = nil
    }

    @objc func openDriveFolder(_ sender: Any?) {
        guard let u = lastReport?.driveFolderURL else { return }
        if Debug.headless { Debug.log("would open \(u.absoluteString)"); return }
        NSWorkspace.shared.open(u)
    }

    @objc func openGooglePhotos(_ sender: Any?) {
        let u = URL(string: "https://photos.google.com/albums")!
        if Debug.headless { Debug.log("would open \(u.absoluteString)"); return }
        NSWorkspace.shared.open(u)
    }
}
