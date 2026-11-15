import AppKit
import CirrusCore
import Quartz
import UniformTypeIdentifiers

enum ViewMode: Int { case icons, list, columns }
enum SortKey: String { case name, date, size, kind }

final class NoGapFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { nil }
}

/// One browser pane: location, history, listing, icon/list views, path bar and status bar.
@MainActor
final class PaneController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout,
    NSTableViewDataSource, NSTableViewDelegate, ItemViewHost, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSTextFieldDelegate {

    weak var browser: BrowserWindowController?
    private(set) var location: Location
    var backStack = [Location]()
    var forwardStack = [Location]()
    var allItems = [Item]()
    var shown = [Item]()
    var sections = [(title: String, subtitle: String, range: Range<Int>)]()
    var viewMode: ViewMode = .icons
    var sortKey: SortKey = .name
    var ascending = true
    var filter = "" { didSet { if filter != oldValue { filterChanged() } } }
    // Subfolder / tag search (results replace the listing until the search ends)
    var searchResults: [Item]?
    var searchWhere = [String: String]()
    var searchStatus: String?
    var searchTask: Task<Void, Never>?
    var searchDebounce: Timer?
    var tagQuery: String?
    var sizeResort: Timer?
    // Spring-loaded folders
    var springTimer: Timer?
    var springKey: String?
    /// Search and tag results show as a list; the column view comes back when the search ends.
    var modeBeforeSearch: ViewMode?
    var loadGeneration = 0
    var loadTask: Task<Void, Never>?
    var isLoading = false
    var lastError: Error?
    var watcher: DispatchSourceFileSystemObject?
    var pollTimer: Timer?
    var qlURLs = [URL]()
    var renameField: NSTextField?
    var renamingItem: Item?
    var typeSelectBuffer = ""
    var typeSelectTime = Date.distantPast
    var observers = [NSObjectProtocol]()

    let grid = GridCollectionView()
    let gridScroll = NSScrollView()
    let table = ListTableView()
    let tableScroll = NSScrollView()
    let layout = NoGapFlowLayout()
    let pathBar = NSStackView()
    let statusLabel = NSTextField(labelWithString: "")
    let sizeSlider = NSSlider(value: 96, minValue: 48, maxValue: 256, target: nil, action: nil)
    let banner = NSStackView()
    let bannerText = NSTextField(wrappingLabelWithString: "")
    let bannerButton = NSButton(title: "", target: nil, action: nil)
    let emptyLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let contentBox = NSView()
    var columns: ColumnController!

    init(location: Location) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    var isActive: Bool { browser?.activePane === self }
    var caps: LocationCaps { Catalog.shared.caps(location) }
    var iconPx: Int { location.isPhotoGrid ? Int(photoSize * 2) : Int(iconSize * 2) }
    var iconSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: "iconSize")) }
    var photoSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: "photoSize")) }

    // MARK: View

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        // Grid
        layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.dataSource = self
        grid.delegate = self
        grid.host = self
        grid.backgroundColors = [.clear]
        grid.register(IconCell.self, forItemWithIdentifier: IconCell.id)
        grid.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.id)
        grid.registerForDraggedTypes(DragDrop.acceptedTypes)
        grid.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        grid.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        grid.flatIndex = { [weak self] ip in self?.flat(ip) }
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.automaticallyAdjustsContentInsets = false   // we already sit below the toolbar (safe area)
        // Table
        table.host = self
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowHeight = 22
        table.doubleAction = #selector(tableDoubleClick)
        table.target = self
        table.registerForDraggedTypes(DragDrop.acceptedTypes)
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.autosaveName = "CirrusList"
        table.autosaveTableColumns = true
        for (id, title, width) in [("name", "Name", 300.0), ("date", "Date Modified", 170.0), ("size", "Size", 90.0), ("kind", "Kind", 150.0), ("where", "Where", 220.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 60
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "date")
            if id == "size" { c.headerCell.alignment = .right }
            if id == "where" { c.sortDescriptorPrototype = nil; c.isHidden = true }
            table.addTableColumn(c)
        }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.automaticallyAdjustsContentInsets = false
        // Banner
        banner.orientation = .horizontal
        banner.spacing = 10
        banner.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        bannerText.font = .systemFont(ofSize: 12)
        bannerButton.bezelStyle = .push
        bannerButton.controlSize = .small
        bannerButton.target = self
        bannerButton.action = #selector(bannerAction)
        banner.addArrangedSubview(NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!))
        banner.addArrangedSubview(bannerText)
        banner.addArrangedSubview(bannerButton)
        banner.isHidden = true
        bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Path & status bars
        pathBar.orientation = .horizontal
        pathBar.spacing = 2
        pathBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        sizeSlider.controlSize = .mini
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        let statusBar = NSStackView(views: [statusLabel, sizeSlider])
        statusBar.orientation = .horizontal
        statusBar.distribution = .fill
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 90, bottom: 0, right: 10)
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        sizeSlider.setContentHuggingPriority(.required, for: .horizontal)
        sizeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        // Empty / loading
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let divider1 = NSBox(); divider1.boxType = .separator
        let divider2 = NSBox(); divider2.boxType = .separator
        for v in [banner, contentBox, divider1, pathBar, divider2, statusBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        columns = ColumnController(pane: self, location: location)
        for v in [gridScroll, tableScroll, columns.browser, emptyLabel, spinner] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; contentBox.addSubview(v) }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor), banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentBox.topAnchor.constraint(equalTo: banner.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: root.leadingAnchor), contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider1.topAnchor.constraint(equalTo: contentBox.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: root.leadingAnchor), divider1.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.topAnchor.constraint(equalTo: divider1.bottomAnchor), pathBar.heightAnchor.constraint(equalToConstant: 24),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), pathBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            divider2.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: root.leadingAnchor), divider2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: divider2.bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for s in [gridScroll, tableScroll, columns.browser] as [NSView] {
            NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo: contentBox.topAnchor), s.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
                                         s.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor), s.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor)])
        }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: contentBox.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: contentBox.centerXAnchor), spinner.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 8),
        ])
        view = root
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked))
        click.delaysPrimaryMouseButtonEvents = false
        root.addGestureRecognizer(click)
        observe()
    }

    func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .cirrusLocationChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let l = n.object as? Location, l == self?.location { self?.reload() } }
        })
        observers.append(nc.addObserver(forName: AccountManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.location.isRemote, self.lastError != nil || self.allItems.isEmpty { self.reload() } else { self.updateBanner() }
            }
        })
        observers.append(nc.addObserver(forName: DeviceManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.location { case .computer, .device: self.reload(); default: break }
            }
        })
        observers.append(nc.addObserver(forName: NativePhotos.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.location.accountID == "mac" else { return }
                Catalog.shared.albumIndex["mac|local"] = nil
                self.reload()
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.grid.refreshSelection() }
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if allItems.isEmpty && !isLoading { navigate(to: location, record: false) }
    }

    // MARK: Navigation

    func navigate(to loc: Location, record: Bool = true) {
        if record && loc != location { backStack.append(location); forwardStack.removeAll() }
        let changed = loc != location
        endSearch(reloadList: false)
        location = loc
        filter = ""
        endRename(commit: false)
        configureForLocation(changed: changed)
        reload(scrollTop: true)
        browser?.paneDidNavigate(self)
    }

    func configureForLocation(changed: Bool) {
        let photo = location.isPhotoGrid
        let savedMode = UserDefaults.standard.object(forKey: "viewMode-" + modeKey) as? Int
        viewMode = ViewMode(rawValue: savedMode ?? (photo ? 0 : 0)) ?? .icons
        if photo && viewMode == .columns { viewMode = .icons }
        if photo { sortKey = .date; ascending = false } else if changed {
            sortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "name") ?? .name
            ascending = UserDefaults.standard.object(forKey: "sortAscending") as? Bool ?? true
        }
        sizeSlider.minValue = photo ? 70 : 32
        sizeSlider.maxValue = photo ? 360 : 256
        sizeSlider.doubleValue = Double(photo ? photoSize : iconSize)
        table.tableColumns.first { $0.identifier.rawValue == "date" }?.title = photo ? "Date Taken" : "Date Modified"
        updateLayout()
        showMode()
        rebuildPathBar()
        watchLocalFolder()
    }

    var modeKey: String {
        switch location {
        case .album: return "photos"
        case .photos: return "albums"
        case .drive, .driveTrash: return "drive"
        case .device: return "device"
        default: return "local"
        }
    }

    func showMode() {
        gridScroll.isHidden = viewMode != .icons
        tableScroll.isHidden = viewMode != .list
        columns.browser.isHidden = viewMode != .columns
        if viewMode == .columns { columns.setRoot(location) }
        browser?.syncToolbar()
    }

    /// Column view: clicking into a column makes that folder the current one (title, path bar, New Folder,
    /// Paste) without rebuilding the columns.
    func columnFolderChanged(_ loc: Location) {
        guard loc != location else { return }
        location = loc
        rebuildPathBar()
        watchLocalFolder()
        reload()
        browser?.paneDidNavigate(self)
    }

    func setViewMode(_ m: ViewMode) {
        if m == .columns && location.isPhotoGrid { NSSound.beep(); browser?.syncToolbar(); return }
        modeBeforeSearch = nil
        let keys = selectedKeys
        viewMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "viewMode-" + modeKey)
        showMode()
        reloadViews()
        if m != .columns { select(keys: keys) }
        view.window?.makeFirstResponder(m == .icons ? grid : (m == .list ? table : columns.browser))
    }

    func goBack() { guard let l = backStack.popLast() else { return }; forwardStack.append(location); navigate(to: l, record: false) }
    func goForward() { guard let l = forwardStack.popLast() else { return }; backStack.append(location); navigate(to: l, record: false) }
    func goUp() { if let p = Catalog.shared.parent(of: location) { let from = location; navigate(to: p); select(keys: [key(forLocation: from)]) } }

    func key(forLocation loc: Location) -> String {
        switch loc {
        case .local(let p): return "file:" + p
        case .drive(let a, let id): return "drive:" + a + ":" + id
        default: return ""
        }
    }

    func rebuildPathBar() {
        for v in pathBar.arrangedSubviews { pathBar.removeArrangedSubview(v); v.removeFromSuperview() }
        if let t = tagQuery {
            let l = NSTextField(labelWithString: "Files tagged “\(t)” in your home folder")
            l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
            pathBar.addArrangedSubview(l)
            return
        }
        let comps = Catalog.shared.pathComponents(location)
        for (i, c) in comps.enumerated() {
            let b = NSButton(title: c.0, target: self, action: #selector(pathClicked(_:)))
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.image = Thumbnails.shared.symbol(Catalog.shared.symbolName(c.1), size: 22, color: .secondaryLabelColor)
            b.imagePosition = .imageLeading
            b.imageScaling = .scaleProportionallyDown
            b.tag = i
            b.lineBreakMode = .byTruncatingMiddle
            b.setContentCompressionResistancePriority(.defaultLow - Float(comps.count - i), for: .horizontal)
            pathBar.addArrangedSubview(b)
            if i < comps.count - 1 {
                let sep = NSTextField(labelWithString: "›")
                sep.textColor = .tertiaryLabelColor
                sep.font = .systemFont(ofSize: 11)
                pathBar.addArrangedSubview(sep)
            }
        }
    }

    @objc func pathClicked(_ sender: NSButton) {
        let comps = Catalog.shared.pathComponents(location)
        guard sender.tag < comps.count else { return }
        navigate(to: comps[sender.tag].1)
    }

    // MARK: Loading

    func reload(scrollTop: Bool = false) {
        loadGeneration += 1
        let gen = loadGeneration
        loadTask?.cancel()
        lastError = nil
        let loc = location
        if let cached = Catalog.shared.memory[loc] { if cached != allItems || shown.isEmpty { applyItems(cached, preserve: !scrollTop) } }
        else if scrollTop { applyItems([], preserve: false) }
        isLoading = true
        updateEmptyState()
        loadTask = Task { [weak self] in
            do {
                let items = try await Catalog.shared.list(loc) { partial in
                    guard let self, gen == self.loadGeneration else { return }
                    if partial != self.allItems || self.shown.isEmpty { self.applyItems(partial, preserve: true) }
                }
                guard let self, gen == self.loadGeneration else { return }
                self.isLoading = false
                // Same as what's on screen (the usual case when reopening): keep it, no redraw or thumbnail flash.
                if items != self.allItems || self.shown.isEmpty || self.searchResults != nil { self.applyItems(items, preserve: true) }
                else { self.updateEmptyState(); self.updateStatus() }
                if self.searchResults != nil { self.rerunSearch() }
                self.rebuildPathBar()
                self.browser?.paneDidNavigate(self)
                if scrollTop { self.scrollToTop() }
            } catch {
                guard let self, gen == self.loadGeneration else { return }
                self.isLoading = false
                if error is CancellationError || (error as? ICloudError) == .cancelled { return }
                self.lastError = error
                self.updateEmptyState()
                self.updateBanner()
            }
        }
    }

    func scrollToTop() {
        gridScroll.contentView.scroll(to: .zero)
        // A table's top sits above y = 0 (under its header): scrolling to zero hid the first row.
        if table.numberOfRows > 0 { table.scrollRowToVisible(0) }
        else { tableScroll.contentView.scroll(to: NSPoint(x: 0, y: -(table.headerView?.frame.height ?? 0))) }
        tableScroll.reflectScrolledClipView(tableScroll.contentView)
    }

    func applyItems(_ items: [Item], preserve: Bool) {
        let keys = preserve ? selectedKeys : []
        allItems = items
        var list = searchResults ?? items
        if searchResults == nil, !filter.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        table.tableColumns.first { $0.identifier.rawValue == "where" }?.isHidden = searchResults == nil
        list.sort(by: comparator())
        shown = list
        buildSections()
        reloadViews()
        if !keys.isEmpty && viewMode != .columns { select(keys: keys) }
        updateEmptyState()
        updateStatus()
        updateBanner()
        schedulePolling()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible, isActive { QLPreviewPanel.shared().reloadData() }
    }

    func comparator() -> (Item, Item) -> Bool {
        let key = sortKey, asc = ascending, foldersOnTop = Prefs.foldersOnTop && !location.isPhotoGrid
        let sizes = Dictionary(uniqueKeysWithValues: (key == .size ? (searchResults ?? allItems) : []).map { ($0.key, sortSize($0)) })
        let sizeOf = { (i: Item) -> Int64 in sizes[i.key] ?? i.size ?? -1 }
        return { a, b in
            if foldersOnTop && a.isContainer != b.isContainer { return a.isContainer }
            var r: ComparisonResult
            switch key {
            case .name: r = a.name.localizedStandardCompare(b.name)
            case .date: r = (a.modified ?? .distantPast) == (b.modified ?? .distantPast) ? .orderedSame : ((a.modified ?? .distantPast) < (b.modified ?? .distantPast) ? .orderedAscending : .orderedDescending)
            case .size: let sa = sizeOf(a), sb = sizeOf(b); r = sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
            case .kind: r = a.kindText.localizedStandardCompare(b.kindText)
            }
            if r == .orderedSame { r = a.name.localizedStandardCompare(b.name); return r == .orderedAscending }
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
    }

    func buildSections() {
        sections = []
        if location.isPhotoGrid && Prefs.groupPhotosByMonth && sortKey == .date && filter.isEmpty && !shown.isEmpty {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            let cal = Calendar.current
            var start = 0
            var current: DateComponents?
            for (i, it) in shown.enumerated() {
                let c = it.modified.map { cal.dateComponents([.year, .month], from: $0) }
                if i == 0 { current = c; continue }
                if c != current {
                    sections.append((current.flatMap { cal.date(from: $0) }.map { f.string(from: $0) } ?? "Undated", "", start..<i))
                    start = i
                    current = c
                }
            }
            sections.append((current.flatMap { cal.date(from: $0) }.map { f.string(from: $0) } ?? "Undated", "", start..<shown.count))
            for i in sections.indices {
                let r = sections[i].range
                let videos = shown[r].filter(\.isVideo).count
                let photos = r.count - videos
                sections[i].subtitle = [photos > 0 ? "\(photos) photo\(photos == 1 ? "" : "s")" : nil, videos > 0 ? "\(videos) video\(videos == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
            }
        } else {
            sections = [("", "", 0..<shown.count)]
        }
    }

    func flat(_ ip: IndexPath) -> Int? {
        guard ip.section < sections.count else { return nil }
        let i = sections[ip.section].range.lowerBound + ip.item
        return i < shown.count ? i : nil
    }

    func indexPath(forFlat i: Int) -> IndexPath? {
        for (s, sec) in sections.enumerated() where sec.range.contains(i) { return IndexPath(item: i - sec.range.lowerBound, section: s) }
        return nil
    }

    func reloadViews() {
        updateLayout()
        grid.reloadData()
        // Lay out now: otherwise items added at the end (a new upload) may not appear until you scroll.
        if viewMode == .icons { grid.collectionViewLayout?.invalidateLayout(); grid.layoutSubtreeIfNeeded() }
        table.reloadData()
        if let d = table.sortDescriptors.first, d.key != sortKey.rawValue || d.ascending != ascending {
            table.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        }
    }

    func updateLayout() {
        if location.isPhotoGrid {
            let s = photoSize
            layout.itemSize = NSSize(width: s, height: s)
            layout.minimumInteritemSpacing = 3
            layout.minimumLineSpacing = 3
            layout.headerReferenceSize = sections.count > 1 || (sections.first?.title.isEmpty == false) ? NSSize(width: 100, height: 40) : .zero
            layout.sectionInset = NSEdgeInsets(top: 4, left: 10, bottom: 14, right: 10)
        } else {
            let s = iconSize
            layout.itemSize = NSSize(width: max(s + 44, 96), height: s + 44)
            layout.minimumInteritemSpacing = 4
            layout.minimumLineSpacing = 8
            layout.headerReferenceSize = .zero
            layout.sectionInset = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        }
        layout.invalidateLayout()
    }

    @objc func sizeChanged() {
        let key = location.isPhotoGrid ? "photoSize" : "iconSize"
        UserDefaults.standard.set(sizeSlider.doubleValue, forKey: key)
        updateLayout()
        if viewMode == .icons {
            for case let cell as IconCell in grid.visibleItems() { cell.view.needsLayout = true }
        }
    }

    func updateEmptyState() {
        if viewMode == .columns { emptyLabel.isHidden = true; spinner.stopAnimation(nil); return }
        if isLoading && shown.isEmpty { emptyLabel.stringValue = "Loading…"; spinner.startAnimation(nil); emptyLabel.isHidden = false; return }
        spinner.stopAnimation(nil)
        if let e = lastError, shown.isEmpty { emptyLabel.stringValue = (e as? LocalizedError)?.errorDescription.map { _ in "Couldn’t load this location" } ?? "Couldn’t load"; emptyLabel.isHidden = false; return }
        emptyLabel.isHidden = !shown.isEmpty
        if let t = tagQuery { emptyLabel.stringValue = searchResults == nil ? "Searching…" : "No files tagged “\(t)”"; return }
        if searchTask != nil && shown.isEmpty { emptyLabel.stringValue = "Searching…"; emptyLabel.isHidden = false; return }
        emptyLabel.stringValue = filter.isEmpty ? (caps.isTrash ? "Recently Deleted is empty" : "No items") : "No results for “\(filter)”"
    }

    func updateBanner() {
        var text: String?
        var button: String?
        if let acct = location.account {
            switch acct.status {
            case .needsSignIn: text = "Your iCloud session for \(acct.appleID ?? acct.title) needs you to sign in again."; button = "Sign In…"
            case .waitingForApproval: text = "Advanced Data Protection: approve iCloud web access on your iPhone, iPad or Mac to continue."; button = nil
            case .error(let m): text = m; button = "Retry"
            case .ready: break
            }
        }
        if text == nil, let e = lastError {
            if case ICloudError.needsSignIn = e { text = e.localizedDescription; button = "Sign In…" }
            else { text = e.localizedDescription; button = "Retry" }
        }
        if text == nil, location.accountID == "mac", location.isPhotoGrid || { if case .photos = location { return true }; return false }(), NativePhotos.authorization == .denied {
            text = "Cirrus can’t read your Photos library. Allow access in System Settings › Privacy & Security › Photos."; button = "Open Settings"
        }
        if text == nil, SafetyPolicy.readOnlyICloud, Catalog.shared.isICloud(location) {
            text = "Read-only mode: you can browse, download and back up, but Cirrus won’t change anything in iCloud."
            button = "Settings…"
        }
        banner.isHidden = text == nil
        bannerText.stringValue = text ?? ""
        bannerButton.title = button ?? ""
        bannerButton.isHidden = button == nil
    }

    @objc func bannerAction() {
        switch bannerButton.title {
        case "Sign In…": (NSApp.delegate as? AppDelegate)?.signIn(appleID: location.account?.appleID, window: view.window)
        case "Open Settings": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
        case "Settings…": (NSApp.delegate as? AppDelegate)?.showPreferences(nil)
        default: reload()
        }
    }

    func updateStatus() {
        let sel = selectedItems
        let f = NumberFormatter(); f.numberStyle = .decimal
        var s: String
        if location.isPhotoGrid {
            let videos = shown.filter(\.isVideo).count
            s = [shown.count - videos > 0 ? "\(f.string(from: NSNumber(value: shown.count - videos))!) photos" : nil, videos > 0 ? "\(f.string(from: NSNumber(value: videos))!) videos" : nil].compactMap { $0 }.joined(separator: ", ")
            if s.isEmpty { s = isLoading ? "Loading…" : "No items" }
            if isLoading && !shown.isEmpty { s += " — loading…" }
        } else {
            s = "\(f.string(from: NSNumber(value: shown.count))!) item\(shown.count == 1 ? "" : "s")"
        }
        if !sel.isEmpty {
            let bytes = sel.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            s = "\(sel.count) of \(shown.count) selected" + (bytes > 0 ? ", \(bytes.byteString)" : "")
        } else if case .local(let p) = location, let free = VolumeInfo.freeSpace(at: URL(fileURLWithPath: p)) {
            s += ", \(free.byteString) available"
        }
        if let t = tagQuery, searchResults != nil { s = "\(shown.count) file\(shown.count == 1 ? "" : "s") tagged “\(t)”" + (sel.isEmpty ? "" : " — \(sel.count) selected") }
        else if searchResults != nil && sel.isEmpty { s = "\(shown.count) result\(shown.count == 1 ? "" : "s") in this folder and subfolders" }
        if let st = searchStatus { s = st + (searchResults != nil ? " — " + s : "") }
        statusLabel.stringValue = s
    }

    func watchLocalFolder() {
        watcher?.cancel()
        watcher = nil
        guard case .local(let p) = location else { return }
        let fd = open(p, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        var pending = false
        src.setEventHandler { [weak self] in
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pending = false; MainActor.assumeIsolated { self?.reload() } }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    /// Native iCloud items in flight don't touch the folder; poll their state while any are moving.
    func schedulePolling() {
        let busy = allItems.contains { $0.cloud == .downloading || $0.cloud == .uploading || $0.cloud == .waitingUpload }
        if busy && pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        } else if !busy { pollTimer?.invalidate(); pollTimer = nil }
    }

    // MARK: Selection

    var selectedIndexes: IndexSet {
        viewMode == .icons ? IndexSet(grid.selectionIndexPaths.compactMap { flat($0) }) : table.selectedRowIndexes
    }
    var selectedItems: [Item] { viewMode == .columns ? columns.selectedItems : selectedIndexes.compactMap { $0 < shown.count ? shown[$0] : nil } }
    var selectedKeys: Set<String> { Set(selectedItems.map(\.key)) }

    func select(keys: Set<String>) {
        if viewMode == .columns { columns.select(keys: keys); return }
        let idx = IndexSet(shown.indices.filter { keys.contains(shown[$0].key) })
        grid.selectionIndexPaths = Set(idx.compactMap { indexPath(forFlat: $0) })
        table.selectRowIndexes(idx, byExtendingSelection: false)
        if let first = idx.first {
            if viewMode == .icons, let ip = indexPath(forFlat: first) { grid.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge) }
            else { table.scrollRowToVisible(first) }
        }
        updateStatus()
    }

    func itemViewSelectionChanged() {
        updateStatus()
        browser?.selectionChanged(in: self)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { prepareQuickLook(show: false) }
    }

    @objc func paneClicked() { browser?.setActivePane(self) }

    // MARK: Collection view

    func numberOfSections(in collectionView: NSCollectionView) -> Int { max(1, sections.count) }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { section < sections.count ? sections[section].range.count : 0 }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: IconCell.id, for: ip) as! IconCell
        if let i = flat(ip) { cell.configure(shown[i], photoMode: location.isPhotoGrid, px: iconPx) }
        return cell
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at ip: IndexPath) -> NSView {
        let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.id, for: ip) as! SectionHeader
        if ip.section < sections.count { h.title.stringValue = sections[ip.section].title; h.subtitle.stringValue = sections[ip.section].subtitle }
        h.needsLayout = true
        return h
    }

    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        location.isPhotoGrid && sections.count > 0 && !(sections.first?.title.isEmpty ?? true) ? NSSize(width: cv.bounds.width, height: 40) : .zero
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) { browser?.setActivePane(self); itemViewSelectionChanged() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) { itemViewSelectionChanged() }

    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { renameField == nil }

    // Window tabs as drop targets (hover to switch, release on a tab to deliver there).
    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        TabDrag.began(in: view.window)
    }
    func collectionView(_ cv: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        TabDrag.ended(session, at: screenPoint, operation: operation)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        TabDrag.began(in: view.window)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        TabDrag.ended(session, at: screenPoint, operation: operation)
    }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        guard let i = flat(ip) else { return nil }
        return writer(shown[i])
    }

    func writer(_ item: Item) -> NSPasteboardWriting {
        let token = DragRegistry.shared.register([item], source: location)
        return DragDrop.writer(for: item, token: token)
    }

    func dropTarget(forFlat i: Int?) -> Location {
        if let i, i < shown.count, shown[i].isContainer, let t = shown[i].target, !caps.isTrash { return t }
        return location
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath ipPtr: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation opPtr: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let ip = ipPtr.pointee as IndexPath
        var target = location
        springHover(opPtr.pointee == .on ? flat(ip) : nil)
        TabDrag.showBar(in: view.window, ownDrag: false)
        if opPtr.pointee == .on, let i = flat(ip), shown[i].isContainer {
            target = dropTarget(forFlat: i)
            let op = DragDrop.operation(info, to: target)
            if !op.isEmpty { return op }
        }
        opPtr.pointee = .before
        target = location
        return DragDrop.operation(info, to: target)
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let target = dropOperation == .on ? dropTarget(forFlat: flat(indexPath)) : location
        return DragDrop.perform(info, to: target, window: view.window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count, let id = col?.identifier.rawValue else { return nil }
        let item = shown[row]
        if id == "name" {
            let v = (tableView.makeView(withIdentifier: .init("nameCell"), owner: nil) as? NameCellView) ?? {
                let n = NameCellView(); n.identifier = .init("nameCell"); return n
            }()
            v.configure(item)
            return v
        }
        let tf = (tableView.makeView(withIdentifier: .init("textCell"), owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: ""); t.identifier = .init("textCell"); t.lineBreakMode = .byTruncatingTail; t.font = .systemFont(ofSize: 12); return t
        }()
        tf.textColor = .secondaryLabelColor
        tf.alignment = id == "size" ? .right : .left
        switch id {
        case "date": tf.stringValue = item.modified.map { Self.dateText($0) } ?? "--"
        case "size": tf.stringValue = item.isContainer ? folderSizeText(item) : (item.size.map { $0.byteString } ?? "--")
        case "kind": tf.stringValue = item.kindText
        case "where": tf.stringValue = searchWhere[item.key] ?? ""
        default: break
        }
        return tf
    }

    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        let t = DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
        if cal.isDateInToday(d) { return "Today at \(t)" }
        if cal.isDateInYesterday(d) { return "Yesterday at \(t)" }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { browser?.setActivePane(self); itemViewSelectionChanged() }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key, let key = SortKey(rawValue: k) else { return }
        if key == sortKey && d.ascending == ascending { return }
        setSort(key, ascending: d.ascending)
    }

    func setSort(_ key: SortKey, ascending asc: Bool) {
        sortKey = key
        ascending = asc
        if !location.isPhotoGrid { UserDefaults.standard.set(key.rawValue, forKey: "sortKey"); UserDefaults.standard.set(asc, forKey: "sortAscending") }
        applyItems(allItems, preserve: true)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { row < shown.count ? writer(shown[row]) : nil }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        springHover(op == .on && row >= 0 ? row : nil)
        TabDrag.showBar(in: view.window, ownDrag: false)
        if op == .on, row < shown.count, shown[row].isContainer {
            let o = DragDrop.operation(info, to: dropTarget(forFlat: row))
            if !o.isEmpty { return o }
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return DragDrop.operation(info, to: location)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let target = row >= 0 && dropOperation == .on ? dropTarget(forFlat: row) : location
        return DragDrop.perform(info, to: target, window: view.window)
    }

    @objc func tableDoubleClick() { if table.clickedRow >= 0 { itemView(doubleClicked: table.clickedRow) } }

    // MARK: Item view host

    func itemView(doubleClicked index: Int) {
        guard index < shown.count else { return }
        activate([shown[index]], newTab: NSEvent.modifierFlags.contains(.command))
    }

    func activate(_ items: [Item], newTab: Bool = false) {
        guard let first = items.first else { return }
        if items.count == 1, first.isContainer, let t = first.target, !caps.isTrash {
            if newTab { browser?.openInNewTab(t) } else { navigate(to: t) }
            return
        }
        if caps.isTrash { NSSound.beep(); return }
        Ops.shared.open(items.filter { !$0.isContainer }, window: view.window)
        for c in items where c.isContainer { if let t = c.target { browser?.openInNewTab(t) } }
    }

    func itemViewKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36 where mods.isEmpty, 76 where mods.isEmpty: renameSelection(nil); return true
        case 49 where mods.isEmpty: quickLook(nil); return true                    // Space
        case 48 where mods.isEmpty && browser?.isDualPane == true: browser?.focusOtherPane(); return true   // Tab
        case 51 where mods == [.command], 117 where mods == [.command]: moveToTrash(nil); return true
        default: break
        }
        if viewMode == .columns { return false }
        if mods.isEmpty || mods == [.shift], let chars = event.characters, chars.count == 1, let c = chars.first, c.isLetter || c.isNumber {
            if Date().timeIntervalSince(typeSelectTime) > 1 { typeSelectBuffer = "" }
            typeSelectBuffer += String(c).lowercased()
            typeSelectTime = Date()
            if let i = shown.firstIndex(where: { $0.name.lowercased().hasPrefix(typeSelectBuffer) }) { select(keys: [shown[i].key]); itemViewSelectionChanged() }
            return viewMode == .icons
        }
        return false
    }

    func itemViewMenu(for indexes: IndexSet) -> NSMenu? {
        browser?.setActivePane(self)
        return ContextMenu.build(for: indexes.compactMap { $0 < shown.count ? shown[$0] : nil }, pane: self)
    }

    // MARK: Actions (responder chain)

    @objc func openSelection(_ sender: Any?) { activate(selectedItems) }
    @objc func openInNewTab(_ sender: Any?) { for i in selectedItems where i.isContainer { if let t = i.target { browser?.openInNewTab(t) } } }
    @objc func openInNewWindow(_ sender: Any?) {
        let folders = selectedItems.compactMap { $0.isContainer ? $0.target : nil }
        for t in folders.isEmpty ? [location] : folders { (NSApp.delegate as? AppDelegate)?.openWindow(t) }
    }
    @objc func openInOtherPane(_ sender: Any?) { if let t = selectedItems.first(where: \.isContainer)?.target { browser?.openInOtherPane(t, from: self) } }
    @objc func goBackAction(_ sender: Any?) { goBack() }
    @objc func goForwardAction(_ sender: Any?) { goForward() }
    @objc func goUpAction(_ sender: Any?) { goUp() }
    /// ⌘R: skip every cache for this view (album list included) and ask the server.
    @objc func refresh(_ sender: Any?) {
        Catalog.shared.invalidate(location)
        if viewMode == .columns { Catalog.shared.invalidate(columns.root.location); columns.refresh(location) }
        var acctLib: (String, String)?
        if case .photos(let a, let lib, _) = location { acctLib = (a, lib) }
        if case .album(let a, let lib, _) = location { acctLib = (a, lib) }
        guard let (a, lib) = acctLib else { reload(); return }
        Task {
            _ = try? await Catalog.shared.albums(account: a, library: lib, refresh: true)
            reload()
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard caps.canCreateFolder else { NSSound.beep(); return }
        Task {
            if let name = await Ops.shared.newFolder(in: location, window: view.window) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let item = shown.first(where: { $0.name == name }) { select(keys: [item.key]); beginRename(item) }
                else { pendingRename = name }
            }
        }
    }
    var pendingRename: String?

    @objc func renameSelection(_ sender: Any?) {
        if selectedItems.count > 1 && selectedItems.allSatisfy({ canRename($0) }) { batchRename(sender); return }
        guard let item = selectedItems.first, selectedItems.count == 1, canRename(item) else { NSSound.beep(); return }
        beginRename(item)
    }

    func canRename(_ item: Item) -> Bool {
        guard caps.canRename else { return false }
        switch item.payload { case .file, .drive: return true; default: return false }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let items = selectedItems
        guard !items.isEmpty, caps.canTrash || items.contains(where: { $0.photo != nil }) && !caps.isTrash else { NSSound.beep(); return }
        Task { await Ops.shared.trash(items, in: location, window: view.window) }
    }

    @objc func restoreSelection(_ sender: Any?) { let i = selectedItems; Task { await Ops.shared.restore(i, in: location, window: view.window) } }
    @objc func deleteImmediately(_ sender: Any?) { let i = selectedItems; Task { await Ops.shared.deleteForever(i, in: location, window: view.window) } }
    @objc func toggleFavorite(_ sender: Any?) {
        let items = selectedItems.filter(\.isPhoto)
        let value = !items.allSatisfy { $0.photo?.isFavorite == true }
        Task { await Ops.shared.setFavorite(items, value, in: location, window: view.window) }
    }
    @objc func toggleHidden(_ sender: Any?) {
        let items = selectedItems.filter(\.isPhoto)
        let value = !items.allSatisfy { $0.photo?.isHidden == true }
        Task { await Ops.shared.setHidden(items, value, in: location, window: view.window) }
    }
    @objc func downloadNow(_ sender: Any?) { Ops.shared.downloadNow(selectedItems); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reload() } }
    @objc func removeDownload(_ sender: Any?) { Ops.shared.removeDownload(selectedItems, window: view.window); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reload() } }

    @objc func downloadToDownloads(_ sender: Any?) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let items = selectedItems
        Task { await Ops.shared.transfer(items, to: .local(dir), move: false, window: view.window) }
    }

    @objc func downloadTo(_ sender: Any?) {
        let items = selectedItems
        guard !items.isEmpty, let w = view.window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Download Here"
        p.message = "Choose where to save \(items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items")."
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let u = p.url else { return }
            Task { await Ops.shared.transfer(items, to: .local(u), move: false, window: w) }
        }
    }

    /// Copy To… / Move To…: any destination (iCloud Drive folder, album, or a Mac folder).
    @objc func copyToPicker(_ sender: Any?) { transferWithPicker(move: false) }
    @objc func moveToPicker(_ sender: Any?) { transferWithPicker(move: true) }

    func transferWithPicker(move: Bool) {
        let items = selectedItems
        guard !items.isEmpty, let w = view.window else { NSSound.beep(); return }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        Task {
            guard let target = await LocationPicker.pick(.destination, title: move ? "Move To" : "Copy To",
                                                        prompt: "Choose where to \(move ? "move" : "copy") \(what). Use “On This Mac…” for any folder or drive.",
                                                        on: w, excluding: [location]),
                  let dest = await Ops.shared.destination(for: target) else { return }
            await Ops.shared.transfer(items, to: dest, move: move, window: w)
        }
    }

    @objc func uploadHere(_ sender: Any?) {
        guard caps.acceptsDrops, let w = view.window else { NSSound.beep(); return }
        let p = NSOpenPanel()
        p.canChooseDirectories = !location.isPhotoGrid; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.prompt = location.isPhotoGrid || { if case .photos = location { return true }; return false }() ? "Import" : "Upload"
        p.beginSheetModal(for: w) { r in
            guard r == .OK else { return }
            let urls = p.urls
            Task { if let d = await Ops.shared.destination(for: self.location) { await Ops.shared.deliver(files: urls, to: d, move: false, window: w) } }
        }
    }

    @objc func copy(_ sender: Any?) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { item -> NSPasteboardWriting in
            let token = DragRegistry.shared.register([item], source: location)
            let pi = NSPasteboardItem()
            pi.setString(token, forType: .cirrusItems)
            if let u = item.localURL { pi.setString(u.absoluteString, forType: .fileURL) }
            pi.setString(item.name, forType: .string)
            return pi
        })
    }

    @objc func paste(_ sender: Any?) { pasteItems(move: false) }
    @objc func pasteMove(_ sender: Any?) { pasteItems(move: true) }

    func pasteItems(move: Bool) {
        let pb = NSPasteboard.general
        let w = view.window
        Task {
            guard let dest = await Ops.shared.destination(for: location) else { NSSound.beep(); return }
            if let (items, _) = DragRegistry.shared.items(from: pb) { await Ops.shared.transfer(items, to: dest, move: move, window: w) }
            else if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                await Ops.shared.deliver(files: urls, to: dest, move: move, window: w)
            }
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedItems.compactMap(\.localURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        for u in urls {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)) ?? []).map { $0.lowercased() })
            let stem = u.deletingPathExtension().lastPathComponent + " copy"
            let n = Ops.uniqueName(stem + (u.pathExtension.isEmpty ? "" : "." + u.pathExtension), taken: taken)
            try? FileManager.default.copyItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent(n))
        }
        reload()
    }

    @objc func compress(_ sender: Any?) {
        let urls = selectedItems.compactMap(\.localURL)
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        let out = dir.appendingPathComponent(Ops.uniqueName(name, taken: taken))
        TransferManager.shared.enqueue(out.lastPathComponent, detail: "Compressing", direction: .other) { t in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = urls.count == 1 ? ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path] : ["-c", "-k", "--sequesterRsrc"] + urls.map(\.path) + [out.path]
            if urls.count > 1 {
                let staging = Paths.tempFile(named: "Archive")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                for u in urls { try FileManager.default.copyItem(at: u, to: staging.appendingPathComponent(u.lastPathComponent)) }
                p.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, out.path]
            }
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw ICloudError.server("Compression failed.") }
            t.resultURL = out
            await MainActor.run { Ops.shared.refresh(.local(dir.path)) }
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedItems.compactMap(\.localURL)
        if urls.isEmpty, let u = location.localURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = selectedItems.compactMap(\.localURL).map(\.path)
        let text = paths.isEmpty ? Catalog.shared.pathComponents(location).map(\.0).joined(separator: "/") : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func getInfo(_ sender: Any?) { InfoPanel.shared.show(items: selectedItems, location: location) }
    @objc func ejectSelection(_ sender: Any?) {
        for i in selectedItems {
            if let v = i.volume { try? DeviceManager.shared.eject(v) }
            if case .camera(let id) = i.payload { DeviceManager.shared.eject(camera: id) }
        }
    }

    @objc func newAlbumWithSelection(_ sender: Any?) {
        guard case .album(let a, let lib, _) = location, let photos = location.account?.photos else { return }
        let assets = selectedItems.compactMap(\.photo)
        let alert = NSAlert()
        alert.messageText = "New Album"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Album name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let w = view.window else { return }
        alert.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            Task {
                do {
                    let l = try await Catalog.shared.library(account: a, id: lib)
                    let album = try await photos.createAlbum(field.stringValue, in: l)
                    if !assets.isEmpty { try await photos.add(assets, to: album, library: l) }
                    _ = try? await Catalog.shared.albums(account: a, library: lib, refresh: true)
                    NotificationCenter.default.post(name: AccountManager.changed, object: nil)
                } catch { Ops.shared.displayError(error, title: "Couldn’t create the album", window: w) }
            }
        }
    }

    @objc func addToAlbum(_ sender: NSMenuItem) {
        guard let album = sender.representedObject as? PhotoAlbum, case .album(let a, let lib, _) = location else { return }
        let assets = selectedItems.compactMap(\.photo)
        Task {
            guard let dest = await Ops.shared.destination(for: .album(a, lib, album.id)) else { return }
            await Ops.shared.transfer(selectedItems.filter(\.isPhoto), to: dest, move: false, window: view.window)
            _ = assets
        }
    }

    @objc func setIconView(_ sender: Any?) { setViewMode(.icons) }
    @objc func setListView(_ sender: Any?) { setViewMode(.list) }
    @objc func setColumnView(_ sender: Any?) { setViewMode(.columns) }
    @objc func sortBy(_ sender: NSMenuItem) {
        guard let k = SortKey(rawValue: sender.identifier?.rawValue ?? "") else { return }
        setSort(k, ascending: k == sortKey ? !ascending : k != .date)
    }

    override func selectAll(_ sender: Any?) {
        if viewMode == .columns {
            let col = max(0, columns.browser.selectedColumn)
            if let n = columns.browser.parentForItems(inColumn: col) as? ColumnNode, let c = n.children { columns.browser.selectRowIndexes(IndexSet(c.indices), inColumn: col) }
            itemViewSelectionChanged(); return
        }
        grid.selectionIndexPaths = Set(shown.indices.compactMap { indexPath(forFlat: $0) })
        table.selectAll(nil)
        itemViewSelectionChanged()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let sel = selectedItems
        switch item.action {
        case #selector(openSelection(_:)), #selector(getInfo(_:)): return !sel.isEmpty || item.action == #selector(getInfo(_:))
        case #selector(goBackAction(_:)): return !backStack.isEmpty
        case #selector(goForwardAction(_:)): return !forwardStack.isEmpty
        case #selector(goUpAction(_:)): return Catalog.shared.parent(of: location) != nil
        case #selector(newFolder(_:)): item.title = caps.newFolderTitle; return caps.canCreateFolder
        case #selector(renameSelection(_:)):
            item.title = sel.count > 1 ? "Rename \(sel.count) Items…" : "Rename"
            return !sel.isEmpty && sel.allSatisfy { canRename($0) }
        case #selector(batchRename(_:)): return sel.count > 1 && sel.allSatisfy { canRename($0) }
        case #selector(newFile(_:)): return caps.canCreateFolder && (location.localURL != nil || { if case .drive = location { return true }; return false }())
        case #selector(makeAlias(_:)): return sel.contains { $0.localURL != nil } && caps.canCreateFolder
        case #selector(openInTerminal(_:)): return location.localURL != nil || sel.contains { $0.isContainer && $0.localURL != nil }
        case #selector(editTags(_:)), #selector(toggleTag(_:)): return sel.contains { $0.localURL != nil }
        case #selector(moveToTrash(_:)): return !sel.isEmpty && !caps.isTrash && (caps.canTrash || sel.contains { $0.isPhoto })
        case #selector(copy(_:)): return !sel.isEmpty
        case #selector(paste(_:)), #selector(pasteMove(_:)): return caps.acceptsDrops
        case #selector(duplicate(_:)), #selector(compress(_:)): return sel.contains { $0.localURL != nil } && caps.canCreateFolder
        case #selector(downloadTo(_:)), #selector(downloadToDownloads(_:)), #selector(copyToPicker(_:)): return !sel.isEmpty
        case #selector(moveToPicker(_:)): return !sel.isEmpty && sel.allSatisfy { $0.localURL != nil || $0.driveNode != nil } && !caps.readOnly
        case #selector(uploadHere(_:)): return caps.acceptsDrops
        case #selector(toggleFavorite(_:)):
            item.title = sel.allSatisfy { $0.photo?.isFavorite == true } && !sel.isEmpty ? "Unfavorite" : "Favorite"
            return sel.contains(where: \.isPhoto)
        case #selector(setIconView(_:)): item.state = viewMode == .icons ? .on : .off; return true
        case #selector(setListView(_:)): item.state = viewMode == .list ? .on : .off; return true
        case #selector(setColumnView(_:)): item.state = viewMode == .columns ? .on : .off; return !location.isPhotoGrid
        case #selector(selectAll(_:)): return !shown.isEmpty
        case #selector(showInFinder(_:)), #selector(copyPath(_:)): return location.localURL != nil || sel.contains { $0.localURL != nil }
        default: return true
        }
    }

    // MARK: Rename

    func beginRename(_ item: Item) {
        endRename(commit: false)
        if viewMode == .columns { renameWithAlert(item); return }
        guard let i = shown.firstIndex(of: item) else { return }
        var frame: NSRect
        var host: NSView
        if viewMode == .icons, let ip = indexPath(forFlat: i), let cell = grid.item(at: ip) as? IconCell {
            grid.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
            host = grid
            frame = cell.view.convert(cell.label.frame, to: grid).insetBy(dx: -8, dy: -2)
            frame.size.width = max(frame.width, 140)
            frame.origin.x = cell.view.frame.midX - frame.width / 2
        } else {
            table.scrollRowToVisible(i)
            host = table
            let r = table.frameOfCell(atColumn: 0, row: i)
            frame = NSRect(x: r.minX + 24, y: r.minY, width: r.width - 24, height: r.height)
        }
        let f = NSTextField(frame: frame)
        f.stringValue = item.name
        f.font = .systemFont(ofSize: viewMode == .icons ? 12 : 13)
        f.alignment = viewMode == .icons ? .center : .left
        f.focusRingType = .exterior
        f.delegate = self
        f.isBordered = true
        f.bezelStyle = .squareBezel
        host.addSubview(f)
        view.window?.makeFirstResponder(f)
        let ext = (item.name as NSString).pathExtension
        if let editor = f.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (item.isContainer || ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension).utf16.count)
        }
        renameField = f
        renamingItem = item
    }

    func endRename(commit: Bool) {
        guard let f = renameField, let item = renamingItem else { return }
        renameField = nil
        renamingItem = nil
        let name = f.stringValue
        f.removeFromSuperview()
        view.window?.makeFirstResponder(viewMode == .icons ? grid : table)
        if commit && name != item.name { Task { await Ops.shared.rename(item, to: name, in: location, window: view.window) } }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { if renameField != nil { endRename(commit: true) } }

    // MARK: Quick Look

    @objc func quickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil); return }
        prepareQuickLook(show: true)
    }

    func prepareQuickLook(show: Bool) {
        let items = Array(selectedItems.filter { !$0.isContainer || $0.localURL != nil }.prefix(60))
        guard !items.isEmpty else { return }
        Task {
            var urls = [URL]()
            for it in items {
                if let u = try? await Ops.shared.localCopy(it, cache: "Preview", progressTitle: it.localURL == nil && (it.size ?? 0) > 8 << 20 ? it.name : nil) { urls.append(u) }
            }
            qlURLs = urls
            guard !urls.isEmpty else { return }
            let panel = QLPreviewPanel.shared()!
            if show { panel.makeKeyAndOrderFront(nil) }
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { qlURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { qlURLs[index] as NSURL }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) {
            (viewMode == .icons ? grid as NSView : (viewMode == .list ? table : columns.browser)).keyDown(with: event)
            return true
        }
        return false
    }
}
