import AppKit
import CirrusCore

final class SidebarNode: NSObject {
    enum Kind { case section, location(Location), action(String), job(UUID) }
    let kind: Kind
    var title: String
    var symbol: String
    var tint: NSColor?
    var children = [SidebarNode]()
    var accessory: String?        // "eject", "warning", "spinner"
    var volume: VolumeInfo?
    var cameraID: String?
    var isFavorite = false
    init(_ kind: Kind, _ title: String, _ symbol: String = "folder", tint: NSColor? = nil) { self.kind = kind; self.title = title; self.symbol = symbol; self.tint = tint }
    var location: Location? { if case .location(let l) = kind { return l }; return nil }
    var isSection: Bool { if case .section = kind { return true }; return false }
}

@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var browser: BrowserWindowController?
    let outline = NSOutlineView()
    var roots = [SidebarNode]()
    var suppressAction = false
    var observers = [NSObjectProtocol]()

    override func loadView() {
        let scroll = NSScrollView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default      // follows System Settings › Appearance › Sidebar icon size
        outline.indentationPerLevel = 12
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes(DragDrop.acceptedTypes)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        view = scroll
        rebuild()
        let nc = NotificationCenter.default
        observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name("NSTableViewDefaultSizeModeChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outline.reloadData(); self?.rebuild() }
        })
        for n in [AccountManager.changed, DeviceManager.changed, SyncStore.changed, TransferManager.changed] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == TransferManager.changed { self?.refreshJobSpinners() } else { self?.rebuild() }
                }
            })
        }
    }

    static func libraryID(_ a: Account) -> String { a.kind == .mac ? "local" : (a.kind == .demo ? "demo" : "PrimarySync") }
    static func allPhotosID(_ a: Account) -> String { a.kind == .mac ? "smart:all" : "smart:All Photos" }

    func rebuild() {
        var out = [SidebarNode]()
        let am = AccountManager.shared
        let fav = SidebarNode(.section, "Favorites")
        for p in Prefs.favorites where FileManager.default.fileExists(atPath: p) {
            let loc = Location.local(p)
            let n = SidebarNode(.location(loc), Catalog.shared.title(loc), Catalog.shared.symbolName(loc))
            n.isFavorite = true
            fav.children.append(n)
        }
        out.append(fav)

        let signedInMac = AccountManager.macSignedInToICloud
        if let mac = am.macAccount, signedInMac {
            let s = SidebarNode(.section, "iCloud")
            if let root = mac.driveRoot { s.children.append(SidebarNode(.location(.local(root.path)), "iCloud Drive", "icloud", tint: .systemBlue)) }
            if mac.photos != nil {
                s.children.append(SidebarNode(.location(.album(mac.id, "local", "smart:all")), "Photos", "photo.on.rectangle.angled", tint: .systemOrange))
                s.children.append(SidebarNode(.location(.photos(mac.id, "local", nil)), "Albums", "rectangle.stack", tint: .systemOrange))
            }
            out.append(s)
        }
        for a in am.accounts where a.kind == .web || a.kind == .demo {
            let s = SidebarNode(.section, a.kind == .demo ? "Demo iCloud" : (a.title == a.appleID ? "iCloud — \(a.title)" : "iCloud — \(a.title)"))
            if a.status == .needsSignIn {
                let n = SidebarNode(.action("signin:" + (a.appleID ?? "")), "Sign In Again…", "exclamationmark.triangle.fill", tint: .systemYellow)
                s.children.append(n)
            }
            if a.drive != nil {
                s.children.append(SidebarNode(.location(.drive(a.id, a.drive!.rootID)), "iCloud Drive", "icloud", tint: .systemBlue))
            }
            if a.photos != nil {
                let lib = Self.libraryID(a)
                s.children.append(SidebarNode(.location(.album(a.id, lib, Self.allPhotosID(a))), "Photos", "photo.on.rectangle.angled", tint: .systemOrange))
                s.children.append(SidebarNode(.location(.photos(a.id, lib, nil)), "Albums", "rectangle.stack", tint: .systemOrange))
                for l in Catalog.shared.libraryIndex[a.id] ?? [] where l.isShared {
                    s.children.append(SidebarNode(.location(.album(a.id, l.id, "smart:All Photos")), l.name, "person.2.fill", tint: .systemOrange))
                }
            }
            if a.drive != nil { s.children.append(SidebarNode(.location(.driveTrash(a.id)), "Recently Deleted", "trash", tint: .secondaryLabelColor)) }
            out.append(s)
        }
        if am.webAccounts.isEmpty {
            let s = out.first { $0.title == "iCloud" } ?? { let x = SidebarNode(.section, "iCloud"); out.append(x); return x }()
            s.children.append(SidebarNode(.action("signin"), signedInMac ? "Add Another Apple ID…" : "Sign In to iCloud…", "person.crop.circle.badge.plus", tint: .systemBlue))
        }
        if let mac = am.macAccount, !signedInMac, mac.photos != nil {
            let s = SidebarNode(.section, "This Mac")
            s.children.append(SidebarNode(.location(.album(mac.id, "local", "smart:all")), "Photos Library", "photo.on.rectangle.angled", tint: .systemOrange))
            s.children.append(SidebarNode(.location(.photos(mac.id, "local", nil)), "Library Albums", "rectangle.stack", tint: .systemOrange))
            out.append(s)
        }

        let locs = SidebarNode(.section, "Locations")
        locs.children.append(SidebarNode(.location(.computer), Catalog.shared.title(.computer), "desktopcomputer"))
        for v in DeviceManager.shared.volumes where !v.isRoot {
            let n = SidebarNode(.location(.local(v.url.path)), v.name, v.isInternal ? "internaldrive" : "externaldrive")
            n.volume = v
            if v.isEjectable || v.isRemovable { n.accessory = "eject" }
            locs.children.append(n)
        }
        for cam in DeviceManager.shared.cameras {
            let id = DeviceManager.shared.deviceID(cam)
            let n = SidebarNode(.location(.device(id, nil)), cam.name ?? "Device", DeviceManager.shared.symbol(for: cam))
            n.cameraID = id
            n.accessory = "eject"
            locs.children.append(n)
        }
        out.append(locs)

        let sync = SidebarNode(.section, "Sync & Backup")
        sync.children.append(SidebarNode(.action("backup"), "Back Up iCloud…", "externaldrive.badge.icloud", tint: .systemGreen))
        for j in SyncStore.shared.jobs {
            let n = SidebarNode(.job(j.id), j.name, j.kind == .backup ? "externaldrive.badge.timemachine" : (j.mode == .twoWay ? "arrow.triangle.2.circlepath" : "arrow.right.circle"),
                                tint: j.lastSuccess == false ? .systemRed : .secondaryLabelColor)
            if SyncStore.shared.running.contains(j.id) { n.accessory = "spinner" } else if j.lastSuccess == false { n.accessory = "warning" }
            sync.children.append(n)
        }
        sync.children.append(SidebarNode(.action("newsync"), "New Sync…", "plus.circle", tint: .secondaryLabelColor))
        out.append(sync)

        let selectedLoc = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.location ?? browser?.activePane?.location
        roots = out
        outline.reloadData()
        for r in roots { outline.expandItem(r) }
        if let l = selectedLoc { select(l) }
    }

    func refreshJobSpinners() {
        let running = SyncStore.shared.running
        guard let sync = roots.last else { return }
        var changed = false
        for n in sync.children {
            if case .job(let id) = n.kind {
                let want: String? = running.contains(id) ? "spinner" : (SyncStore.shared.job(id)?.lastSuccess == false ? "warning" : nil)
                if n.accessory != want { n.accessory = want; changed = true }
            }
        }
        if changed { outline.reloadItem(sync, reloadChildren: true) }
    }

    func select(_ loc: Location) {
        suppressAction = true
        defer { suppressAction = false }
        for r in roots { for c in r.children where c.location == loc {
            let row = outline.row(forItem: c)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            return
        } }
        outline.deselectAll(nil)
    }

    // MARK: Data source

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SidebarNode)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SidebarNode)?.children[index] ?? roots[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarNode)?.isSection ?? false }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode)?.isSection ?? false }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? SidebarNode)?.isSection ?? true) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isSection {
            let v = NSTableCellView()
            let t = NSTextField(labelWithString: node.title)
            t.font = .systemFont(ofSize: 11, weight: .semibold)
            t.textColor = .secondaryLabelColor
            t.lineBreakMode = .byTruncatingTail
            v.addSubview(t); v.textField = t
            t.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), t.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
                                         t.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        }
        let v = NSTableCellView()
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        img.contentTintColor = node.tint ?? .controlAccentColor
        let metrics = Self.metrics(for: o.effectiveRowSizeStyle)
        img.symbolConfiguration = .init(pointSize: metrics.symbol, weight: .regular)
        let t = NSTextField(labelWithString: node.title)
        t.font = .systemFont(ofSize: metrics.font)
        t.lineBreakMode = .byTruncatingTail
        v.addSubview(img); v.addSubview(t)
        v.imageView = img; v.textField = t
        for x in [img, t] { x.translatesAutoresizingMaskIntoConstraints = false }
        var trailing: NSView?
        switch node.accessory {
        case "eject":
            let b = NSButton(image: NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")!, target: self, action: #selector(eject(_:)))
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.identifier = .init(node.title)
            trailing = b
        case "spinner":
            let s = NSProgressIndicator(); s.style = .spinning; s.controlSize = .small; s.startAnimation(nil); trailing = s
        case "warning":
            let i = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failed")!); i.contentTintColor = .systemRed; trailing = i
        default: break
        }
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: metrics.iconWidth),
            t.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6), t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(trailing)
            NSLayoutConstraint.activate([trailing.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4), trailing.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                         trailing.widthAnchor.constraint(equalToConstant: 16), trailing.heightAnchor.constraint(equalToConstant: 16),
                                         t.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -4)])
        } else {
            t.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4).isActive = true
        }
        return v
    }

    /// Matches Finder's sidebar for the system “Sidebar icon size” (small / medium / large).
    static func metrics(for style: NSTableView.RowSizeStyle) -> (symbol: CGFloat, font: CGFloat, iconWidth: CGFloat) {
        switch style {
        case .small: return (12, 11, 18)
        case .large: return (17, 15, 24)
        default: return (14, 13, 20)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressAction else { return }
        activate(outline.item(atRow: outline.selectedRow) as? SidebarNode)
    }

    @objc func clicked() {
        // Re-clicking an action row should fire again.
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        if case .action = n.kind { activate(n) }
        if case .job = n.kind { activate(n) }
    }

    func activate(_ node: SidebarNode?) {
        guard let node else { return }
        let app = NSApp.delegate as? AppDelegate
        switch node.kind {
        case .location(let l): browser?.activePane?.navigate(to: l)
        case .action(let a):
            outline.deselectAll(nil)
            if a == "backup" { app?.showBackup(nil) }
            else if a == "newsync" { app?.showSync(nil) }
            else if a.hasPrefix("signin") { app?.signIn(appleID: a.hasPrefix("signin:") ? String(a.dropFirst(7)) : nil, window: view.window) }
        case .job(let id):
            app?.showSync(id)
        case .section: break
        }
    }

    @objc func eject(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard let n = outline.item(atRow: row) as? SidebarNode else { return }
        if let v = n.volume {
            do { try DeviceManager.shared.eject(v) } catch { Ops.shared.displayError(error, title: "Couldn’t eject “\(v.name)”", window: view.window) }
        }
        if let c = n.cameraID { DeviceManager.shared.eject(camera: c) }
    }

    // MARK: Drops

    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let n = item as? SidebarNode, n.isSection, n.title == "Favorites" {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty, urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { return .link }
            return []
        }
        guard let n = item as? SidebarNode, let loc = n.location, index == NSOutlineViewDropOnItemIndex else { return [] }
        return DragDrop.operation(info, to: loc)
    }

    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let n = item as? SidebarNode, n.isSection, n.title == "Favorites" {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            var favs = Prefs.favorites
            for u in urls where !favs.contains(u.path) { favs.insert(u.path, at: max(0, min(index, favs.count))) }
            Prefs.favorites = favs
            rebuild()
            return true
        }
        guard let n = item as? SidebarNode, let loc = n.location else { return false }
        return DragDrop.perform(info, to: loc, window: view.window)
    }
}

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        if let loc = n.location {
            menu.addItem(withTitle: "Open in New Tab", action: #selector(openNewTab(_:)), keyEquivalent: "").representedObject = loc
            if browser?.isDualPane == true { menu.addItem(withTitle: "Open in Other Pane", action: #selector(openOtherPane(_:)), keyEquivalent: "").representedObject = loc }
        }
        if n.isFavorite { menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeFavorite(_:)), keyEquivalent: "").representedObject = n.location }
        if case .location(let l) = n.kind, let acct = l.account, acct.kind == .web {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Account Info…", action: #selector(accountInfo(_:)), keyEquivalent: "").representedObject = acct.id
            menu.addItem(withTitle: "Sign Out of \(acct.appleID ?? acct.title)…", action: #selector(signOut(_:)), keyEquivalent: "").representedObject = acct.id
        }
        if case .job(let id) = n.kind {
            menu.addItem(withTitle: "Run Now", action: #selector(runJob(_:)), keyEquivalent: "").representedObject = id
            menu.addItem(withTitle: "Edit…", action: #selector(editJob(_:)), keyEquivalent: "").representedObject = id
        }
        for i in menu.items { i.target = self }
    }

    @objc func openNewTab(_ s: NSMenuItem) { if let l = s.representedObject as? Location { browser?.openInNewTab(l) } }
    @objc func openOtherPane(_ s: NSMenuItem) { if let l = s.representedObject as? Location, let p = browser?.activePane { browser?.openInOtherPane(l, from: p) } }
    @objc func removeFavorite(_ s: NSMenuItem) {
        guard case .local(let p)? = s.representedObject as? Location else { return }
        Prefs.favorites = Prefs.favorites.filter { $0 != p }
        rebuild()
    }
    @objc func signOut(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let a = AccountManager.shared.account(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of \(a.appleID ?? a.title)?"
        alert.informativeText = "Cirrus forgets the session and any saved password for this Apple ID. Nothing is deleted from iCloud."
        alert.addButton(withTitle: "Sign Out"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { AccountManager.shared.signOut(a); browser?.activePane?.navigate(to: .home()) }
    }
    @objc func accountInfo(_ s: NSMenuItem) { if let id = s.representedObject as? String { (NSApp.delegate as? AppDelegate)?.showAccountInfo(id) } }
    @objc func runJob(_ s: NSMenuItem) { if let id = s.representedObject as? UUID, let j = SyncStore.shared.job(id) { JobRunner.shared.run(j, window: view.window) } }
    @objc func editJob(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { (NSApp.delegate as? AppDelegate)?.showSync(id) } }
}
