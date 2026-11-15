import AppKit
import CirrusCore

/// Sheet for choosing an iCloud location (Drive folder or Photos album) — the iCloud counterpart
/// of NSOpenPanel. “On This Mac…” hands off to the standard folder chooser.
@MainActor
final class LocationPicker: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode { case driveFolder, album, destination }

    final class Node: NSObject {
        let title: String
        let symbol: String
        let location: Location?
        var children: [Node]?
        let expandable: Bool
        let canPick: Bool
        init(_ title: String, _ symbol: String, _ location: Location?, expandable: Bool, canPick: Bool) {
            self.title = title; self.symbol = symbol; self.location = location; self.expandable = expandable; self.canPick = canPick
        }
    }

    let mode: Mode
    let outline = NSOutlineView()
    let pathLabel = NSTextField(labelWithString: "")
    let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    let newFolderButton = NSButton(title: "New Folder", target: nil, action: nil)
    let localButton = NSButton(title: "On This Mac…", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    var roots = [Node]()
    var completion: ((Location?) -> Void)?
    var excluded = Set<Location>()

    init(mode: Mode, title: String, prompt: String) {
        self.mode = mode
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.minSize = NSSize(width: 420, height: 320)
        super.init(window: w)
        build(prompt: prompt)
        loadRoots()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Runs as a sheet on `window` (or as a window) and returns the chosen location.
    static func pick(_ mode: Mode, title: String, prompt: String, on window: NSWindow?, excluding: Set<Location> = []) async -> Location? {
        let p = LocationPicker(mode: mode, title: title, prompt: prompt)
        p.excluded = excluding
        return await withCheckedContinuation { cont in
            p.completion = { loc in cont.resume(returning: loc) }
            if let window { window.beginSheet(p.window!) } else { p.window?.center(); p.showWindow(nil) }
            objc_setAssociatedObject(p.window!, &Self.key, p, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    nonisolated(unsafe) static var key = 0

    func build(prompt: String) {
        let message = NSTextField(wrappingLabelWithString: prompt)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(doubleClicked)
        outline.target = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        chooseButton.keyEquivalent = "\r"
        chooseButton.target = self; chooseButton.action = #selector(choose)
        chooseButton.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        newFolderButton.target = self; newFolderButton.action = #selector(newFolder)
        newFolderButton.title = mode == .album ? "New Album" : "New Folder"
        newFolderButton.isEnabled = false
        localButton.target = self; localButton.action = #selector(chooseLocal)
        localButton.isHidden = mode == .album
        for b in [chooseButton, cancel, newFolderButton, localButton] { b.bezelStyle = .push }
        let buttons = NSStackView(views: [newFolderButton, localButton, spinner, NSView(), cancel, chooseButton])
        let root = NSStackView(views: [message, scroll, pathLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for v in [scroll, buttons, pathLabel, message] as [NSView] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        window?.contentView = root
    }

    func loadRoots() {
        let am = AccountManager.shared
        var out = [Node]()
        if mode != .album {
            if let root = am.macAccount?.driveRoot {
                out.append(Node("iCloud Drive (this Mac)", "icloud", .local(root.path), expandable: true, canPick: true))
            }
            for a in am.accounts where a.drive != nil && a.kind != .mac {
                out.append(Node("iCloud Drive — \(a.kind == .demo ? "Demo" : (a.appleID ?? a.title))", "icloud", .drive(a.id, a.drive!.rootID), expandable: true, canPick: true))
            }
        }
        if mode != .driveFolder {
            for a in am.accounts where a.photos != nil {
                let lib = SidebarController.libraryID(a)
                let name = a.kind == .mac ? (AccountManager.macSignedInToICloud ? "Photos (this Mac)" : "Photos Library (this Mac)") : "Photos — \(a.kind == .demo ? "Demo" : (a.appleID ?? a.title))"
                out.append(Node(name, "photo.on.rectangle.angled", .photos(a.id, lib, nil), expandable: true, canPick: mode == .destination))
            }
        }
        roots = out
        outline.reloadData()
        if out.count == 1 { outline.expandItem(out[0]) }
        if out.isEmpty { pathLabel.stringValue = "No iCloud account is available. Sign in first (File › Sign In with Apple ID…)." }
    }

    func loadChildren(_ node: Node) {
        guard node.children == nil, let loc = node.location else { return }
        node.children = []
        spinner.startAnimation(nil)
        Task {
            defer { spinner.stopAnimation(nil) }
            var kids = [Node]()
            do {
                switch loc {
                case .local(let p):
                    let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
                    for u in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                        if v?.isDirectory == true && v?.isPackage != true { kids.append(Node(u.lastPathComponent, "folder", .local(u.path), expandable: true, canPick: true)) }
                    }
                    if let root = AccountManager.shared.macAccount?.driveRoot, p == root.path {
                        for c in NativeICloud.appContainers(root: root) { kids.append(Node(c.name, "app.badge", .local(c.url.path), expandable: true, canPick: true)) }
                    }
                case .drive(let a, let id):
                    let nodes = try await AccountManager.shared.account(id: a)?.drive?.list(id) ?? []
                    for n in nodes where n.isFolder {
                        Catalog.shared.driveNames[a + "|" + n.id] = (n.name, id)
                        kids.append(Node(n.name, n.isAppLibrary ? "app.badge" : "folder", .drive(a, n.id), expandable: true, canPick: true))
                    }
                case .photos(let a, let lib, let folder):
                    let albums = try await Catalog.shared.albums(account: a, library: lib)
                    for al in albums where al.parentID == folder {
                        switch al.kind {
                        case .folder: kids.append(Node(al.name, "folder", .photos(a, lib, al.id), expandable: true, canPick: false))
                        case .album: kids.append(Node(al.name, "rectangle.stack", .album(a, lib, al.id), expandable: false, canPick: true))
                        case .smart where al.isAllPhotos || al.id == "smart:all":
                            kids.insert(Node("Library (All Photos)", "photo.on.rectangle", .album(a, lib, al.id), expandable: false, canPick: true), at: 0)
                        default: break
                        }
                    }
                default: break
                }
            } catch {
                pathLabel.stringValue = error.localizedDescription
            }
            node.children = kids.sorted { ($0.symbol == "photo.on.rectangle" ? 0 : 1, $0.title.lowercased()) < ($1.symbol == "photo.on.rectangle" ? 0 : 1, $1.title.lowercased()) }
            outline.reloadItem(node, reloadChildren: true)
        }
    }

    var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }

    // MARK: Outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? Node else { return roots.count }
        return n.children?.count ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children?[index] ?? roots[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.expandable ?? false }
    func outlineViewItemWillExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? Node { loadChildren(n) }
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let v = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: n.symbol, accessibilityDescription: nil)!)
        img.contentTintColor = n.symbol == "icloud" ? .systemBlue : (n.symbol.hasPrefix("photo") || n.symbol == "rectangle.stack" ? .systemOrange : .secondaryLabelColor)
        let t = NSTextField(labelWithString: n.title)
        t.lineBreakMode = .byTruncatingTail
        if !n.canPick { t.textColor = .secondaryLabelColor }
        if let l = n.location, excluded.contains(l) { t.textColor = .tertiaryLabelColor }
        for x in [img, t] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        v.imageView = img; v.textField = t
        NSLayoutConstraint.activate([img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     img.widthAnchor.constraint(equalToConstant: 18),
                                     t.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6), t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                     t.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor)])
        return v
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = selectedNode, let l = n.location else { chooseButton.isEnabled = false; newFolderButton.isEnabled = false; return }
        chooseButton.isEnabled = n.canPick && !excluded.contains(l)
        pathLabel.stringValue = Catalog.shared.pathComponents(l).map(\.0).joined(separator: " › ")
        switch l {
        case .drive, .local: newFolderButton.isEnabled = mode != .album
        case .photos(let a, _, nil): newFolderButton.isEnabled = AccountManager.shared.account(id: a)?.photos?.capabilities.contains(.createAlbum) == true && mode != .driveFolder
        default: newFolderButton.isEnabled = false
        }
    }

    @objc func doubleClicked() {
        guard let n = selectedNode else { return }
        if n.expandable { outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n) } else if n.canPick { choose() }
    }

    // MARK: Actions

    func finish(_ l: Location?) {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) } else { window?.close() }
        completion?(l)
        completion = nil
    }

    @objc func choose() { if let l = selectedNode?.location, selectedNode?.canPick == true { finish(l) } }
    @objc func cancel() { finish(nil) }

    @objc func chooseLocal() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"
        p.beginSheetModal(for: window!) { r in
            if r == .OK, let u = p.url { self.finish(.local(u.path)) }
        }
    }

    @objc func newFolder() {
        guard let node = selectedNode, let loc = node.location else { return }
        let a = NSAlert()
        a.messageText = mode == .album || { if case .photos = loc { return true }; return false }() ? "New Album" : "New Folder"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = a.messageText == "New Album" ? "Untitled Album" : "untitled folder"
        a.accessoryView = f
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: window!) { r in
            guard r == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
            let name = f.stringValue
            Task {
                do {
                    switch loc {
                    case .local(let p): try FileManager.default.createDirectory(at: URL(fileURLWithPath: p).appendingPathComponent(name), withIntermediateDirectories: false)
                    case .drive(let acct, let id): _ = try await AccountManager.shared.account(id: acct)?.drive?.createFolder(name, in: id)
                    case .photos(let acct, let lib, _):
                        if let photos = AccountManager.shared.account(id: acct)?.photos {
                            _ = try await photos.createAlbum(name, in: try await Catalog.shared.library(account: acct, id: lib))
                            _ = try? await Catalog.shared.albums(account: acct, library: lib, refresh: true)
                        }
                    default: break
                    }
                    node.children = nil
                    self.loadChildren(node)
                    self.outline.expandItem(node)
                    Ops.shared.refresh(loc)
                } catch { self.pathLabel.stringValue = error.localizedDescription }
            }
        }
    }
}
