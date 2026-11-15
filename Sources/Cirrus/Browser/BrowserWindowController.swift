import AppKit
import CirrusCore

/// Circular progress + count for the toolbar; click opens the transfers popover.
final class TransferIndicator: NSButton {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var count = 0 { didSet { needsDisplay = true; toolTip = count == 0 ? "No transfers" : "\(count) transfer\(count == 1 ? "" : "s")" } }
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let track = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
        track.lineWidth = 2.5
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        if count > 0 {
            let p = NSBezierPath()
            let c = NSPoint(x: r.midX, y: r.midY)
            p.appendArc(withCenter: c, radius: r.width / 2 - 1.5, startAngle: 90, endAngle: 90 - CGFloat(max(0.03, fraction)) * 360, clockwise: true)
            p.lineWidth = 2.5
            p.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            p.stroke()
        }
        let img = NSImage(systemSymbolName: count > 0 ? "arrow.up.arrow.down" : "arrow.up.arrow.down", accessibilityDescription: "Transfers")!
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))!
        let tinted = img.tinted(count > 0 ? .controlAccentColor : .secondaryLabelColor)
        tinted.draw(in: NSRect(x: r.midX - tinted.size.width / 2, y: r.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let split = NSSplitViewController()
    let paneSplit = NSSplitViewController()
    let sidebar = SidebarController()
    var panes = [PaneController]()
    private(set) weak var activePane: PaneController?
    let navControl = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                                                 NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!],
                                        trackingMode: .momentary, target: nil, action: nil)
    let viewControl = NSSegmentedControl(images: [NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons")!,
                                                  NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                                                  NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns")!],
                                         trackingMode: .selectOne, target: nil, action: nil)
    let preview = PreviewPaneController()
    lazy var previewItem: NSSplitViewItem = {
        let i = NSSplitViewItem(inspectorWithViewController: preview)
        i.minimumThickness = 230
        i.maximumThickness = 440
        i.canCollapse = true
        return i
    }()
    let indicator = TransferIndicator()
    var searchItem: NSSearchToolbarItem?
    lazy var transfersPopover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = TransfersViewController()
        return p
    }()
    var observers = [NSObjectProtocol]()

    var isDualPane: Bool { panes.count > 1 }

    init(location: Location) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 640, height: 420)
        w.tabbingMode = .automatic   // follows System Settings › Desktop & Dock › Prefer tabs; ⌘T always makes a tab
        w.tabbingIdentifier = "CirrusBrowser"
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        super.init(window: w)
        w.delegate = self
        sidebar.browser = self
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 340
        sideItem.canCollapse = true
        sideItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sideItem)
        let pane = makePane(location)
        paneSplit.splitView.isVertical = true
        paneSplit.splitView.dividerStyle = .thin
        paneSplit.addSplitViewItem(NSSplitViewItem(viewController: pane))
        let contentItem = NSSplitViewItem(viewController: paneSplit)
        contentItem.minimumThickness = 400
        split.addSplitViewItem(contentItem)
        previewItem.isCollapsed = !Prefs.showPreviewPane
        split.addSplitViewItem(previewItem)
        split.splitView.autosaveName = "CirrusSidebar"
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1180, height: 740))
        w.setFrameAutosaveName("CirrusBrowser")
        if !w.setFrameUsingName("CirrusBrowser") { w.center() }
        setActivePane(pane)
        let tb = NSToolbar(identifier: "CirrusToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        w.toolbar = tb
        navControl.target = self
        navControl.action = #selector(navClicked(_:))
        navControl.segmentStyle = .separated
        viewControl.target = self
        viewControl.action = #selector(viewClicked(_:))
        indicator.isBordered = false
        indicator.title = ""
        indicator.target = self
        indicator.action = #selector(showTransfers(_:))
        observers.append(NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIndicator() }
        })
        updateIndicator()
    }
    required init?(coder: NSCoder) { fatalError() }

    func makePane(_ loc: Location) -> PaneController {
        let p = PaneController(location: loc)
        p.browser = self
        panes.append(p)
        return p
    }

    func setActivePane(_ p: PaneController) {
        guard activePane !== p else { return }
        let old = activePane
        activePane = p
        for x in panes { x.view.alphaValue = 1 }
        if isDualPane { old?.contentBox.layer?.borderWidth = 0 }
        syncToolbar()
        paneDidNavigate(p)
    }

    func focusOtherPane() {
        guard isDualPane, let a = activePane, let other = panes.first(where: { $0 !== a }) else { return }
        setActivePane(other)
        window?.makeFirstResponder(other.viewMode == .icons ? other.grid : other.table)
    }

    func paneDidNavigate(_ p: PaneController) {
        guard p === activePane else { return }
        window?.title = Catalog.shared.title(p.location)
        window?.subtitle = isDualPane ? "Two panes — Tab switches" : ""
        window?.representedURL = p.location.localURL
        if let u = p.location.localURL { window?.standardWindowButton(.documentIconButton)?.image = NSWorkspace.shared.icon(forFile: u.path) }
        sidebar.select(p.location)
        syncToolbar()
        updatePreview()
        if let d = try? JSONEncoder().encode(p.location) { UserDefaults.standard.set(d, forKey: "lastLocation") }
        if InfoPanel.shared.isVisible { InfoPanel.shared.show(items: p.selectedItems, location: p.location, bringToFront: false) }
    }

    func selectionChanged(in p: PaneController) {
        guard p === activePane else { return }
        updatePreview()
        if InfoPanel.shared.isVisible { InfoPanel.shared.show(items: p.selectedItems, location: p.location, bringToFront: false) }
    }

    func syncToolbar() {
        guard let p = activePane else { return }
        navControl.setEnabled(!p.backStack.isEmpty, forSegment: 0)
        navControl.setEnabled(!p.forwardStack.isEmpty, forSegment: 1)
        viewControl.selectedSegment = p.viewMode.rawValue
        viewControl.setEnabled(!p.location.isPhotoGrid, forSegment: 2)
        if let s = searchItem {
            if s.searchField.stringValue != p.filter { s.searchField.stringValue = p.filter }
            s.searchField.placeholderString = p.searchesSubfolders ? "Search" : "Filter"
            s.searchField.toolTip = p.searchesSubfolders ? "Searches this folder and its subfolders (View › Search Includes Subfolders)" : "Filters what's shown here"
        }
    }

    func updateIndicator() {
        let o = TransferManager.shared.overall
        indicator.count = o.count
        indicator.fraction = o.total > 0 ? Double(o.done) / Double(o.total) : 0
    }

    // MARK: Toolbar

    static let ids: (nav: NSToolbarItem.Identifier, view: NSToolbarItem.Identifier, sort: NSToolbarItem.Identifier, action: NSToolbarItem.Identifier,
                     newFolder: NSToolbarItem.Identifier, transfers: NSToolbarItem.Identifier, dual: NSToolbarItem.Identifier,
                     backup: NSToolbarItem.Identifier, search: NSToolbarItem.Identifier, account: NSToolbarItem.Identifier, upload: NSToolbarItem.Identifier) = (
        .init("nav"), .init("view"), .init("sort"), .init("action"), .init("newFolder"), .init("transfers"), .init("dual"), .init("backup"), .init("search"),
        .init("account"), .init("upload"))

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let i = Self.ids
        return [.toggleSidebar, .sidebarTrackingSeparator, i.nav, .flexibleSpace, i.view, i.sort, i.action, i.newFolder, i.upload, i.dual, .space, i.transfers, i.backup, i.account, i.search]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let i = Self.ids
        switch id {
        case i.nav:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = navControl
            item.label = "Back/Forward"
            item.isNavigational = true
            return item
        case i.view:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = viewControl
            item.label = "View"
            return item
        case i.sort:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down.square", accessibilityDescription: "Sort")
            item.label = "Sort"
            item.toolTip = "Sort and group"
            let m = NSMenu()
            for (k, t) in [(SortKey.name, "Name"), (.date, "Date"), (.size, "Size"), (.kind, "Kind")] {
                let mi = NSMenuItem(title: t, action: #selector(PaneController.sortBy(_:)), keyEquivalent: "")
                mi.identifier = .init(k.rawValue)
                m.addItem(mi)
            }
            m.addItem(.separator())
            m.addItem(withTitle: "Group Photos by Month", action: #selector(toggleGrouping(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Square Photo Grid", action: #selector(toggleSquareGrid(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Keep Folders on Top", action: #selector(toggleFoldersOnTop(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Calculate All Sizes", action: #selector(toggleCalculateSizes(_:)), keyEquivalent: "").target = self
            m.delegate = self
            item.menu = m
            item.showsIndicator = false
            return item
        case i.action:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
            item.label = "Action"
            let m = NSMenu()
            m.delegate = self
            item.menu = m
            item.showsIndicator = false
            return item
        case i.newFolder:
            return button(id, "New Folder", "folder.badge.plus", #selector(PaneController.newFolder(_:)), target: nil)
        case i.upload:
            return button(id, "Upload", "square.and.arrow.up", #selector(PaneController.uploadHere(_:)), target: nil, tip: "Upload or import files into this location")
        case i.dual:
            return button(id, "Two Panes", "rectangle.split.2x1", #selector(toggleDualPane(_:)), target: self, tip: "Show two panes side by side (⌃⌘2)")
        case i.transfers:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = indicator
            item.label = "Transfers"
            item.toolTip = "Transfers"
            return item
        case i.backup:
            return button(id, "Back Up", "externaldrive.badge.icloud", #selector(AppDelegate.showBackup(_:)), target: NSApp.delegate, tip: "Back up iCloud to a drive")
        case i.account:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Accounts")
            item.label = "Accounts"
            let m = NSMenu()
            m.delegate = self
            item.menu = m
            item.showsIndicator = false
            return item
        case i.search:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.delegate = self
            s.searchField.placeholderString = "Filter"
            s.label = "Search"
            searchItem = s
            return s
        default: return nil
        }
    }

    func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector, target: AnyObject?, tip: String? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = tip ?? label
        item.action = action
        item.target = target
        item.isBordered = true
        return item
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSSearchField else { return }
        activePane?.filter = f.stringValue
    }

    // MARK: Actions

    @objc func navClicked(_ s: NSSegmentedControl) { s.selectedSegment == 0 ? activePane?.goBack() : activePane?.goForward() }
    @objc func viewClicked(_ s: NSSegmentedControl) { activePane?.setViewMode(ViewMode(rawValue: s.selectedSegment) ?? .icons) }

    @objc func showTransfers(_ sender: Any?) {
        if transfersPopover.isShown { transfersPopover.close(); return }
        transfersPopover.show(relativeTo: indicator.bounds, of: indicator, preferredEdge: .maxY)
    }

    @objc func toggleGrouping(_ sender: Any?) { Prefs.groupPhotosByMonth.toggle(); for p in panes { p.applyItems(p.allItems, preserve: true) } }
    @objc func toggleSquareGrid(_ sender: Any?) { Prefs.squarePhotoGrid.toggle(); for p in panes { p.reloadViews() } }
    @objc func toggleFoldersOnTop(_ sender: Any?) { Prefs.foldersOnTop.toggle(); for p in panes { p.applyItems(p.allItems, preserve: true) } }
    @objc func toggleHiddenFiles(_ sender: Any?) {
        Prefs.showHidden.toggle()
        Catalog.shared.memory = Catalog.shared.memory.filter { if case .local = $0.key { return false }; return true }
        for p in panes { p.reload() }
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        Prefs.showPreviewPane.toggle()
        previewItem.animator().isCollapsed = !Prefs.showPreviewPane
        updatePreview()
    }

    func updatePreview() {
        guard !previewItem.isCollapsed, let p = activePane else { return }
        preview.show(p.selectedItems, location: p.location)
    }

    @objc func toggleCalculateSizes(_ sender: Any?) {
        Prefs.calculateSizes.toggle()
        for p in panes { p.applyItems(p.allItems, preserve: true) }
    }

    @objc func toggleSearchSubfolders(_ sender: Any?) {
        Prefs.searchSubfolders.toggle()
        syncToolbar()
        activePane?.filterChanged()
    }

    @objc func toggleDualPane(_ sender: Any?) {
        if isDualPane {
            guard let keep = activePane else { return }
            for p in panes where p !== keep {
                if let item = paneSplit.splitViewItems.first(where: { $0.viewController === p }) { paneSplit.removeSplitViewItem(item) }
            }
            panes = [keep]
        } else {
            let start = activePane?.location ?? .home()
            let other = makePane(start)
            paneSplit.addSplitViewItem(NSSplitViewItem(viewController: other))
            paneSplit.splitView.layoutSubtreeIfNeeded()
            paneSplit.splitView.setPosition(paneSplit.splitView.bounds.width / 2, ofDividerAt: 0)
            other.navigate(to: start, record: false)
            setActivePane(other)
        }
        for p in panes { p.contentBox.layer?.borderWidth = 0 }
        paneDidNavigate(activePane!)
    }

    func openInOtherPane(_ loc: Location, from: PaneController) {
        if !isDualPane { toggleDualPane(nil) }
        if let other = panes.first(where: { $0 !== from }) { other.navigate(to: loc); setActivePane(other) }
    }

    func openInNewTab(_ loc: Location) {
        let wc = (NSApp.delegate as? AppDelegate)?.makeWindow(loc)
        if let w = wc?.window { window?.addTabbedWindow(w, ordered: .above); w.makeKeyAndOrderFront(nil) }
    }

    override func newWindowForTab(_ sender: Any?) {
        openInNewTab(activePane?.location ?? .home())
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Ops.shared.checkEditedFiles(window: window)
    }
}

extension BrowserWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let p = activePane else { return }
        if menu.items.contains(where: { $0.action == #selector(PaneController.sortBy(_:)) }) {
            for mi in menu.items {
                if let k = mi.identifier.flatMap({ SortKey(rawValue: $0.rawValue) }) { mi.state = p.sortKey == k ? .on : .off; mi.target = p }
                if mi.action == #selector(toggleGrouping(_:)) { mi.state = Prefs.groupPhotosByMonth ? .on : .off }
                if mi.action == #selector(toggleSquareGrid(_:)) { mi.state = Prefs.squarePhotoGrid ? .on : .off }
                if mi.action == #selector(toggleFoldersOnTop(_:)) { mi.state = Prefs.foldersOnTop ? .on : .off }
                if mi.action == #selector(toggleHiddenFiles(_:)) { mi.state = Prefs.showHidden ? .on : .off }
                if mi.action == #selector(toggleCalculateSizes(_:)) { mi.state = Prefs.calculateSizes ? .on : .off }
            }
            return
        }
        menu.removeAllItems()
        if let tb = window?.toolbar, let accountItem = tb.items.first(where: { $0.itemIdentifier == Self.ids.account }) as? NSMenuToolbarItem, accountItem.menu === menu {
            buildAccountMenu(menu)
            return
        }
        let built = ContextMenu.build(for: p.selectedItems, pane: p)
        for i in built.items { built.removeItem(i); menu.addItem(i) }
    }

    func buildAccountMenu(_ menu: NSMenu) {
        let app = NSApp.delegate as? AppDelegate
        let am = AccountManager.shared
        if let mac = am.macAccount {
            let t = NSMenuItem(title: AccountManager.macSignedInToICloud ? "This Mac’s iCloud (system)" : "This Mac (not signed in to iCloud)", action: nil, keyEquivalent: "")
            t.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            menu.addItem(t)
            _ = mac
        }
        for a in am.accounts where a.kind != .mac {
            let status: String
            switch a.status { case .ready: status = ""; case .needsSignIn: status = " — sign in needed"; case .waitingForApproval: status = " — waiting for approval"; case .error: status = " — error" }
            let mi = NSMenuItem(title: (a.appleID ?? a.title) + status, action: #selector(AppDelegate.showAccountInfoMenu(_:)), keyEquivalent: "")
            mi.representedObject = a.id
            mi.target = app
            mi.image = NSImage(systemSymbolName: a.status == .ready ? "person.crop.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Sign In with Apple ID…", action: #selector(AppDelegate.signInMenu(_:)), keyEquivalent: "")
        add.target = app
        menu.addItem(add)
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePreviewPane(_:)): item.title = previewItem.isCollapsed ? "Show Preview" : "Hide Preview"
        case #selector(toggleCalculateSizes(_:)): item.state = Prefs.calculateSizes ? .on : .off
        case #selector(toggleSearchSubfolders(_:)): item.state = Prefs.searchSubfolders ? .on : .off
        case #selector(toggleHiddenFiles(_:)): item.state = Prefs.showHidden ? .on : .off
        case #selector(toggleGrouping(_:)): item.state = Prefs.groupPhotosByMonth ? .on : .off
        case #selector(toggleSquareGrid(_:)): item.state = Prefs.squarePhotoGrid ? .on : .off
        case #selector(toggleFoldersOnTop(_:)): item.state = Prefs.foldersOnTop ? .on : .off
        case #selector(toggleDualPane(_:)): item.state = isDualPane ? .on : .off
        default: break
        }
        return true
    }
}
