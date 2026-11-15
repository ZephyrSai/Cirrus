import AppKit
import CirrusCore
import UniformTypeIdentifiers

// MARK: - New File, Make Alias, Open in Terminal

extension PaneController {
    /// File › New File: an empty text file here (local folder or iCloud Drive), ready to rename.
    @objc func newFile(_ sender: Any?) {
        guard caps.canCreateFolder, !location.isPhotoGrid, location.localURL != nil || { if case .drive = location { return true }; return false }() else { NSSound.beep(); return }
        let w = view.window
        let taken = Set(shown.map { $0.name.lowercased() })
        let name = Ops.uniqueName("untitled.txt", taken: taken)
        switch location {
        case .local(let p):
            let u = URL(fileURLWithPath: p).appendingPathComponent(name)
            do {
                try SafetyPolicy.checkLocalWrite(u)
                guard FileManager.default.createFile(atPath: u.path, contents: Data()) else { throw CocoaError(.fileWriteNoPermission) }
                selectAndRenameWhenListed(name)
            } catch { Ops.shared.displayError(error, title: "Couldn’t create a file here", window: w) }
        case .drive(let a, let folderID):
            guard let drive = AccountManager.shared.account(id: a)?.drive else { return }
            let loc = location
            Task {
                do {
                    let tmp = Paths.tempFile(named: name)
                    FileManager.default.createFile(atPath: tmp.path, contents: Data())
                    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
                    _ = try await drive.upload(tmp, name: name, into: folderID, modified: Date()) { _, _ in }
                    Ops.shared.refresh(loc)
                    selectAndRenameWhenListed(name)
                } catch { Ops.shared.displayError(error, title: "Couldn’t create a file in iCloud Drive", window: w) }
            }
        default: NSSound.beep()
        }
    }

    func selectAndRenameWhenListed(_ name: String) {
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let item = shown.first(where: { $0.name == name }) { select(keys: [item.key]); if viewMode != .columns { beginRename(item) }; return }
            }
        }
    }

    /// File › Make Alias: Finder aliases (bookmark files) next to each selected local item.
    @objc func makeAlias(_ sender: Any?) {
        let urls = selectedItems.compactMap(\.localURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        var made = [String]()
        for u in urls {
            let dir = u.deletingLastPathComponent()
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
            let name = Ops.uniqueName(u.lastPathComponent + " alias", taken: taken)
            let alias = dir.appendingPathComponent(name)
            do {
                try SafetyPolicy.checkLocalWrite(alias)
                let data = try u.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: alias)
                made.append(name)
            } catch { Ops.shared.displayError(error, title: "Couldn’t make an alias of “\(u.lastPathComponent)”", window: view.window) }
        }
        reload()
        if let first = made.first { selectAndRenameWhenListed(first) }
    }

    /// Opens Terminal at the selected folder, or at this folder.
    @objc func openInTerminal(_ sender: Any?) {
        let folder = selectedItems.first(where: { $0.isContainer && $0.localURL != nil })?.localURL ?? location.localURL
        guard let folder, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { NSSound.beep(); return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Tags

    @objc func toggleTag(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let items = selectedItems.filter { $0.localURL != nil }
        let all = items.allSatisfy { $0.tags.contains { $0.name == tag } }
        applyTags(items) { names in all ? names.filter { $0 != tag } : (names.contains(tag) ? names : names + [tag]) }
    }

    @objc func editTags(_ sender: Any?) {
        let items = selectedItems.filter { $0.localURL != nil }
        guard !items.isEmpty, let w = view.window else { NSSound.beep(); return }
        let common = items.dropFirst().reduce(Set(items[0].tags.map(\.name))) { $0.intersection($1.tags.map(\.name)) }
        let field = NSTokenField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.objectValue = Array(common).sorted()
        field.placeholderString = "Add tags, separated by commas"
        let a = NSAlert()
        a.messageText = items.count == 1 ? "Tags for “\(items[0].name)”" : "Tags for \(items.count) items"
        a.informativeText = "Tags you type here replace the shared tags. Other tags on individual items are kept."
        a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        Task {
            guard await a.present(w) == .alertFirstButtonReturn else { return }
            let wanted = ((field.objectValue as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.applyTags(items) { names in names.filter { !common.contains($0) } + wanted.filter { !names.contains($0) || common.contains($0) } }
        }
    }

    func applyTags(_ items: [Item], _ transform: ([String]) -> [String]) {
        for it in items {
            guard let u = it.localURL else { continue }
            do { try FinderTag.set(transform(it.tags.map(\.name)), on: u) }
            catch { Ops.shared.displayError(error, title: "Couldn’t change the tags of “\(it.name)”", window: view.window); return }
        }
        if searchResults != nil { rerunSearch() } else { reload() }
    }

    /// Sidebar › Tags: every file on this Mac with that tag (Spotlight), shown in this pane.
    func showTag(_ tag: String) {
        endSearch(reloadList: false)
        tagQuery = tag
        searchStatus = "Searching for files tagged “\(tag)”…"
        updateStatus()
        let gen = loadGeneration
        Task {
            let items = await SpotlightTags.files(tagged: tag, showHidden: Prefs.showHidden)
            guard gen == loadGeneration, tagQuery == tag else { return }
            searchWhere = Dictionary(items.compactMap { it in it.localURL.map { (it.key, Self.abbreviate($0.deletingLastPathComponent().path)) } }, uniquingKeysWith: { a, _ in a })
            searchResults = items
            searchStatus = nil
            showResultsAsList()
            applyItems(allItems, preserve: false)
            rebuildPathBar()
            view.window?.title = "Tagged “\(tag)”"
        }
    }

    nonisolated static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Subfolder search

    /// The search field searches this folder and everything inside it (Finder's “search this folder”),
    /// or only filters what's listed here.
    var searchesSubfolders: Bool {
        guard Prefs.searchSubfolders else { return false }
        switch location { case .local, .drive: return true; default: return false }
    }

    func filterChanged() {
        searchDebounce?.invalidate()
        guard searchesSubfolders, filter.count >= 2 else {
            if searchResults != nil || searchTask != nil { endSearch(reloadList: false) }
            applyItems(allItems, preserve: true)
            return
        }
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rerunSearch() }
        }
    }

    func rerunSearch() {
        if let t = tagQuery { showTag(t); return }
        guard searchesSubfolders, filter.count >= 2 else { return }
        searchTask?.cancel()
        let q = filter, base = location, gen = loadGeneration
        searchStatus = "Searching “\(q)” in this folder and its subfolders…"
        updateStatus()
        searchTask = Task {
            do {
                let found = try await SubfolderSearch.run(base: base, query: q, showHidden: Prefs.showHidden)
                guard !Task.isCancelled, gen == loadGeneration, filter == q, location == base else { return }
                searchWhere = Dictionary(found.map { ($0.item.key, $0.where) }, uniquingKeysWith: { a, _ in a })
                searchResults = found.map(\.item)
                searchStatus = found.count >= SubfolderSearch.limit ? "Showing the first \(SubfolderSearch.limit) results" : nil
                searchTask = nil
                showResultsAsList()
                applyItems(allItems, preserve: true)
            } catch {
                guard !(error is CancellationError) else { return }
                searchTask = nil
                searchStatus = "Search stopped: \(error.localizedDescription)"
                updateStatus()
            }
        }
    }

    /// Results come from many folders, so the column view can't show them: use the list (not saved as a preference).
    func showResultsAsList() {
        guard viewMode == .columns else { return }
        modeBeforeSearch = .columns
        viewMode = .list
        showMode()
    }

    func endSearch(reloadList: Bool = true) {
        searchDebounce?.invalidate()
        searchTask?.cancel(); searchTask = nil
        let was = searchResults != nil || tagQuery != nil
        let hadTag = tagQuery != nil
        searchResults = nil; searchWhere = [:]; searchStatus = nil; tagQuery = nil
        if hadTag { rebuildPathBar() }
        if let m = modeBeforeSearch { modeBeforeSearch = nil; viewMode = m; showMode(); reloadViews() }
        if was && reloadList { applyItems(allItems, preserve: false) }
    }

    // MARK: Folder sizes

    func folderSizeText(_ item: Item) -> String {
        guard Prefs.calculateSizes, item.isContainer else { return item.count.map { "\($0) item\($0 == 1 ? "" : "s")" } ?? "--" }
        if let b = FolderSizer.shared.cached(item) { return b.byteString }
        FolderSizer.shared.request(item) { [weak self] in self?.folderSizeArrived(item.key) }
        return item.count.map { "\($0) item\($0 == 1 ? "" : "s")" } ?? "Calculating…"
    }

    func folderSizeArrived(_ key: String) {
        if sortKey == .size {
            sizeResort?.invalidate()
            sizeResort = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.applyItems(self.allItems, preserve: true) }
            }
        } else if let row = shown.firstIndex(where: { $0.key == key }), let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }) {
            table.reloadData(forRowIndexes: [row], columnIndexes: [col])
        }
        if InfoPanel.shared.isVisible, isActive { InfoPanel.shared.show(items: selectedItems, location: location, bringToFront: false) }
    }

    func sortSize(_ i: Item) -> Int64 { i.size ?? (Prefs.calculateSizes ? FolderSizer.shared.cached(i) ?? -1 : -1) }

    // MARK: Spring-loaded folders

    /// Hovering a drag over a folder opens it after the system's spring-loading delay.
    func springHover(_ index: Int?) {
        let enabled = UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
        guard enabled, let index, index < shown.count, shown[index].isContainer, let target = shown[index].target, !caps.isTrash else {
            springTimer?.invalidate(); springTimer = nil; springKey = nil; return
        }
        let key = shown[index].key
        if springKey == key { return }
        springTimer?.invalidate()
        springKey = key
        let delay = UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        springTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, delay + 0.25), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.springKey == key else { return }
                self.springKey = nil
                // Only while the drag is still over that same folder.
                guard NSEvent.pressedMouseButtons & 1 != 0, let i = self.itemIndexUnderMouse(), i < self.shown.count, self.shown[i].key == key else { return }
                self.view.window?.makeKeyAndOrderFront(nil)
                self.navigate(to: target)
            }
        }
    }

    func itemIndexUnderMouse() -> Int? {
        guard let w = view.window else { return nil }
        let pw = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        if viewMode == .icons {
            let p = grid.convert(pw, from: nil)
            return grid.indexPathForItem(at: p).flatMap { flat($0) }
        }
        let r = table.row(at: table.convert(pw, from: nil))
        return r >= 0 ? r : nil
    }

    /// Rename without an inline field (column view).
    func renameWithAlert(_ item: Item) {
        guard let w = view.window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = item.name
        let a = NSAlert()
        a.messageText = "Rename “\(item.name)”"
        a.accessoryView = field
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        let loc = location
        Task {
            guard await a.present(w) == .alertFirstButtonReturn, field.stringValue != item.name else { return }
            await Ops.shared.rename(item, to: field.stringValue, in: loc, window: w)
        }
    }

    // MARK: Batch rename

    @objc func batchRename(_ sender: Any?) {
        let items = selectedItems.filter { canRename($0) }
        guard items.count > 1, let w = view.window else { renameSelection(sender); return }
        BatchRenameSheet.present(items: items, on: w) { [weak self] plan in
            guard let self else { return }
            let loc = self.location
            Task { await Ops.shared.batchRename(plan, in: loc, window: w) }
        }
    }
}

// MARK: - Search engines

enum SubfolderSearch {
    static let limit = 2000

    /// Name search below `base`. Runs off the main thread for local folders; walks iCloud Drive folders.
    static func run(base: Location, query: String, showHidden: Bool) async throws -> [(item: Item, where: String)] {
        switch base {
        case .local(let p):
            let root = URL(fileURLWithPath: p, isDirectory: true)
            return try await Task.detached(priority: .userInitiated) { () throws -> [(item: Item, where: String)] in
                var out = [(item: Item, where: String)]()
                let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Catalog.localKeys, options: opts) else { return [] }
                var n = 0
                while let u = e.nextObject() as? URL {
                    n += 1
                    if n % 2000 == 0 { try Task.checkCancellation() }
                    guard u.lastPathComponent.localizedCaseInsensitiveContains(query), let item = Catalog.localItem(u, showHidden: showHidden) else { continue }
                    out.append((item, PaneController.abbreviate(u.deletingLastPathComponent().path)))
                    if out.count >= limit { break }
                }
                return out
            }.value
        case .drive(let a, let folderID):
            guard let acct = await MainActor.run(body: { AccountManager.shared.account(id: a) }), let drive = acct.drive else { throw ICloudError.needsSignIn }
            let all = try await drive.walk(folderID)
            return await MainActor.run {
                var out = [(item: Item, where: String)]()
                let base = Catalog.shared.title(.drive(a, folderID))
                for (path, node) in all {
                    if node.isFolder { Catalog.shared.driveNames[a + "|" + node.id] = (node.name, node.parentID) }
                    guard node.name.localizedCaseInsensitiveContains(query), out.count < limit else { continue }
                    let parent = (path as NSString).deletingLastPathComponent
                    out.append((Catalog.shared.driveItem(node, account: a), parent.isEmpty ? base : base + "/" + parent))
                }
                return out
            }
        default:
            return []
        }
    }
}

enum SpotlightTags {
    /// Files in the home folder with a Finder tag, via Spotlight.
    @MainActor static func files(tagged tag: String, showHidden: Bool) async -> [Item] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Item], Never>) in
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "%K == %@", "kMDItemUserTags", tag)
            q.searchScopes = [NSMetadataQueryUserHomeScope]
            var token: NSObjectProtocol?
            var finished = false
            func finish() {
                guard !finished else { return }
                finished = true
                q.stop()
                if let token { NotificationCenter.default.removeObserver(token) }
                let urls = (0..<min(q.resultCount, 5000)).compactMap { (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
                cont.resume(returning: urls.compactMap { Catalog.localItem(URL(fileURLWithPath: $0), showHidden: showHidden) })
            }
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            }
            if !q.start() { finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { MainActor.assumeIsolated { finish() } }
        }
    }
}

// MARK: - Folder sizes

@MainActor
final class FolderSizer {
    static let shared = FolderSizer()
    private var cache = [String: (bytes: Int64, at: Date)]()
    private var waiting = [String: [() -> Void]]()
    private var queue = [Item]()
    private var running = 0

    func cached(_ item: Item) -> Int64? {
        guard let c = cache[item.key], Date().timeIntervalSince(c.at) < 300 else { return nil }
        return c.bytes
    }

    func forget(_ key: String) { cache[key] = nil }

    func request(_ item: Item, done: @escaping () -> Void) {
        guard item.localURL != nil || item.driveNode != nil else { return }
        if waiting[item.key] != nil { waiting[item.key]!.append(done); return }
        waiting[item.key] = [done]
        queue.append(item)
        pump()
    }

    private func pump() {
        while running < 3, !queue.isEmpty {
            let item = queue.removeFirst()
            running += 1
            Task {
                let bytes = await Self.measure(item)
                running -= 1
                if let bytes { cache[item.key] = (bytes, Date()) }
                for d in waiting.removeValue(forKey: item.key) ?? [] { d() }
                pump()
            }
        }
    }

    static func measure(_ item: Item) async -> Int64? {
        if let u = item.localURL {
            return await Task.detached(priority: .utility) { () -> Int64? in
                guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return nil }
                var total: Int64 = 0
                var n = 0
                while let f = e.nextObject() as? URL {
                    n += 1
                    if n > 3_000_000 { break }
                    if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
                }
                return total
            }.value
        }
        if let node = item.driveNode, let a = item.account, let drive = AccountManager.shared.account(id: a)?.drive {
            guard let all = try? await drive.walk(node.id) else { return nil }
            return all.reduce(Int64(0)) { $0 + ($1.node.isFolder ? 0 : $1.node.size) }
        }
        return nil
    }
}

// MARK: - Batch rename

struct BatchRenameOptions {
    enum Mode: Int { case replace, add, format }
    enum Format: Int { case index, counter, date }
    var mode: Mode = .replace
    var find = "", replaceWith = ""
    var addText = "", addBefore = false
    var format: Format = .index, formatBefore = false, customFormat = "", startAt = 1

    /// The new name for the `i`-th item (0-based). Extensions are kept unless Replace Text touches them.
    func newName(_ name: String, index i: Int, date: Date = Date()) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let dotExt = ext.isEmpty ? "" : "." + ext
        switch mode {
        case .replace:
            guard !find.isEmpty else { return name }
            return name.replacingOccurrences(of: find, with: replaceWith, options: [.caseInsensitive])
        case .add:
            return (addBefore ? addText + stem : stem + addText) + dotExt
        case .format:
            let n = startAt + i
            let mark: String
            switch format {
            case .index: mark = String(n)
            case .counter: mark = String(format: "%05d", n)
            case .date:
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                mark = f.string(from: date) + (i > 0 ? " \(i + 1)" : "")
            }
            let sep = customFormat.isEmpty || format == .date ? (customFormat.isEmpty ? "" : " ") : ""
            return (formatBefore ? mark + sep + customFormat : customFormat + sep + mark) + dotExt
        }
    }
}

@MainActor
final class BatchRenameSheet: NSObject, NSTextFieldDelegate {
    let items: [Item]
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
    let mode = NSPopUpButton()
    let find = NSTextField(), replaceWith = NSTextField()
    let addText = NSTextField(), addWhere = NSPopUpButton()
    let format = NSPopUpButton(), formatWhere = NSPopUpButton(), custom = NSTextField(), startAt = NSTextField()
    let example = NSTextField(labelWithString: "")
    let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    var rows = [[NSView]]()
    let grid = NSGridView()
    var onDone: (([(Item, String)]) -> Void)?
    static var current: BatchRenameSheet?

    init(items: [Item]) { self.items = items; super.init() }

    static func present(items: [Item], on window: NSWindow, done: @escaping ([(Item, String)]) -> Void) {
        let s = BatchRenameSheet(items: items)
        s.onDone = done
        current = s
        s.build()
        window.beginSheet(s.panel)
        Debug.lastWindow = s.panel
    }

    func build() {
        mode.addItems(withTitles: ["Replace Text", "Add Text", "Format"])
        addWhere.addItems(withTitles: ["after name", "before name"])
        format.addItems(withTitles: ["Name and Index", "Name and Counter", "Name and Date"])
        formatWhere.addItems(withTitles: ["after name", "before name"])
        startAt.stringValue = "1"
        custom.placeholderString = "Name"
        for f in [find, replaceWith, addText, custom, startAt] { f.delegate = self; f.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true }
        startAt.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for p in [mode, addWhere, format, formatWhere] { p.target = self; p.action = #selector(changed) }
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        rows = [
            [label("Find:"), find], [label("Replace with:"), replaceWith],
            [label("Text:"), addText], [label("Where:"), addWhere],
            [label("Name Format:"), format], [label("Where:"), formatWhere], [label("Custom Format:"), custom], [label("Start numbers at:"), startAt],
        ]
        grid.addRow(with: [label("Rename \(items.count) items:"), mode])
        for r in rows { grid.addRow(with: r) }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        example.textColor = .secondaryLabelColor
        example.lineBreakMode = .byTruncatingMiddle
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.target = self; renameButton.action = #selector(apply); renameButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, renameButton])
        let stack = NSStackView(views: [grid, example, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        changed()
    }

    var options: BatchRenameOptions {
        var o = BatchRenameOptions()
        o.mode = BatchRenameOptions.Mode(rawValue: mode.indexOfSelectedItem) ?? .replace
        o.find = find.stringValue; o.replaceWith = replaceWith.stringValue
        o.addText = addText.stringValue; o.addBefore = addWhere.indexOfSelectedItem == 1
        o.format = BatchRenameOptions.Format(rawValue: format.indexOfSelectedItem) ?? .index
        o.formatBefore = formatWhere.indexOfSelectedItem == 1
        o.customFormat = custom.stringValue
        o.startAt = Int(startAt.stringValue) ?? 1
        return o
    }

    @objc func changed() {
        let m = mode.indexOfSelectedItem
        for (i, r) in rows.enumerated() {
            let visible = (m == 0 && i < 2) || (m == 1 && (2...3).contains(i)) || (m == 2 && i >= 4)
            grid.row(at: i + 1).isHidden = !visible
            _ = r
        }
        let first = items[0].name
        example.stringValue = "Example: " + options.newName(first, index: 0)
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    func controlTextDidChange(_ obj: Notification) { changed() }

    @objc func cancel() { close() }

    @objc func apply() {
        let o = options
        let now = Date()
        let plan = items.enumerated().map { ($0.element, o.newName($0.element.name, index: $0.offset, date: now)) }.filter { $0.0.name != $0.1 }
        close()
        if !plan.isEmpty { onDone?(plan) }
    }

    func close() {
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        Self.current = nil
    }
}

extension Ops {
    /// Renames many items at once. Every new name is checked first (no clashes inside the batch or with
    /// other items in the folder), so a batch either fully applies or doesn't start.
    func batchRename(_ plan: [(Item, String)], in loc: Location, window: NSWindow?) async {
        guard !plan.isEmpty else { return }
        let others = Set(((Catalog.shared.memory[loc]) ?? []).map(\.key)).subtracting(plan.map(\.0.key))
        let otherNames = Set((Catalog.shared.memory[loc] ?? []).filter { others.contains($0.key) }.map { $0.name.lowercased() })
        var seen = Set<String>()
        for (item, name) in plan {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let problem: String? = n.isEmpty ? "A new name would be empty." : n.contains("/") || n.contains(":") ? "Names can’t contain “/” or “:”." :
                n.hasPrefix(".") && !item.name.hasPrefix(".") ? "A new name would start with a dot (hidden)." :
                otherNames.contains(n.lowercased()) ? "“\(n)” is already used in this folder." :
                !seen.insert(n.lowercased()).inserted ? "Two items would both be named “\(n)”." : nil
            if let problem { displayError(ICloudError.server(problem + " Nothing was renamed."), title: "Can’t rename these items", window: window); return }
        }
        // A target that is another item's current name needs a two-step rename.
        let current = Set(plan.map { $0.0.name.lowercased() })
        let twoStep = plan.contains { current.contains($0.1.lowercased()) && $0.1.lowercased() != $0.0.name.lowercased() }
        var done = [(URL, URL)]()
        do {
            let local = plan.compactMap { p -> (URL, String)? in p.0.localURL.map { ($0, p.1) } }
            for (u, _) in local { try SafetyPolicy.checkLocalWrite(u) }
            var staged = [(URL, URL)]()   // (temporary, final)
            for (u, name) in local {
                let dst = u.deletingLastPathComponent().appendingPathComponent(name)
                let caseOnly = dst.lastPathComponent.lowercased() == u.lastPathComponent.lowercased()
                if twoStep || caseOnly {
                    let tmp = u.deletingLastPathComponent().appendingPathComponent(".cirrus-rename-\(UUID().uuidString.prefix(8))")
                    try FileManager.default.moveItem(at: u, to: tmp)
                    done.append((u, tmp)); staged.append((tmp, dst))
                } else {
                    try FileManager.default.moveItem(at: u, to: dst)
                    done.append((u, dst))
                }
            }
            for (tmp, dst) in staged {
                try FileManager.default.moveItem(at: tmp, to: dst)
                if let i = done.firstIndex(where: { $0.1 == tmp }) { done[i].1 = dst }
            }
            var driveStaged = [(DriveNode, String, DriveBackend)]()
            for (item, name) in plan where item.driveNode != nil {
                guard let n = item.driveNode, let drive = item.account.flatMap({ AccountManager.shared.account(id: $0) })?.drive else { continue }
                if twoStep { driveStaged.append((try await drive.rename(n, to: ".cirrus-rename-\(UUID().uuidString.prefix(8))"), name, drive)) }
                else { _ = try await drive.rename(n, to: name) }
            }
            for (n, name, drive) in driveStaged { _ = try await drive.rename(n, to: name) }
        } catch {
            displayError(error, title: "Renaming stopped", window: window)
        }
        if let undo = window?.undoManager, !done.isEmpty {
            let pairs = done
            undo.registerUndo(withTarget: self) { _ in
                for (orig, now) in pairs.reversed() { try? FileManager.default.moveItem(at: now, to: orig) }
                Ops.shared.refresh(loc)
            }
            undo.setActionName("Rename \(done.count) Items")
        }
        refresh(loc)
    }
}
