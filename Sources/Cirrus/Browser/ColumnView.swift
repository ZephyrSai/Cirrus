import AppKit
import CirrusCore

/// One entry in the column view; containers load their children on demand.
@MainActor
final class ColumnNode: NSObject {
    let item: Item?
    let location: Location          // for containers: the folder it opens; otherwise the folder it's in
    var children: [ColumnNode]?
    var loading = false
    init(item: Item?, location: Location) { self.item = item; self.location = location }
    var isFolder: Bool { item == nil || (item?.isContainer == true && item?.target != nil) }
}

final class CirrusBrowser: NSBrowser {
    weak var host: ColumnController?
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        var row = -1, col = -1
        if getRow(&row, column: &col, for: p), row >= 0, col >= 0 {
            if !(selectedRowIndexes(inColumn: col)?.contains(row) ?? false) { selectRow(row, inColumn: col) }
            MainActor.assumeIsolated { host?.selectionChanged() }
        }
        return MainActor.assumeIsolated { host?.menu() }
    }
    override func keyDown(with event: NSEvent) {
        if MainActor.assumeIsolated({ host?.pane?.itemViewKey(event) }) == true { return }
        super.keyDown(with: event)
    }
}

/// Finder's column view, driven by the same listings (and caches) as the icon and list views.
@MainActor
final class ColumnController: NSObject, NSBrowserDelegate {
    weak var pane: PaneController?
    let browser = CirrusBrowser()
    private(set) var root: ColumnNode
    var nodes = [Location: ColumnNode]()
    let preview = PreviewPaneController()

    init(pane: PaneController, location: Location) {
        self.pane = pane
        root = ColumnNode(item: nil, location: location)
        super.init()
        browser.host = self
        browser.delegate = self
        browser.target = self
        browser.action = #selector(clicked)
        browser.doubleAction = #selector(doubleClicked)
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.columnResizingType = .userColumnResizing
        browser.setDefaultColumnWidth(230)
        browser.minColumnWidth = 140
        browser.registerForDraggedTypes(DragDrop.acceptedTypes)
        browser.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        browser.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        NotificationCenter.default.addObserver(forName: .cirrusLocationChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let l = n.object as? Location { self?.refresh(l) } }
        }
    }

    func setRoot(_ loc: Location) {
        guard loc != root.location || root.children == nil else { return }
        root = ColumnNode(item: nil, location: loc)
        nodes = [loc: root]
        browser.loadColumnZero()
    }

    func refresh(_ loc: Location) {
        guard let n = nodes[loc], n.children != nil else { return }
        let keys = Set(selectedItems.map(\.key))
        n.children = nil
        load(n) { [weak self] in self?.reselect(keys, in: n) }
    }

    // MARK: Data

    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        let n = (item as? ColumnNode) ?? root
        if let c = n.children { return c.count }
        if n.isFolder { load(n) }
        return 0
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let n = (item as? ColumnNode) ?? root
        return n.children?[index] ?? ColumnNode(item: nil, location: n.location)
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool { !((item as? ColumnNode)?.isFolder ?? true) }
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? { (item as? ColumnNode)?.item?.name ?? "" }
    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool { false }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let n = sender.item(atRow: row, inColumn: column) as? ColumnNode, let it = n.item else { return }
        let src = Thumbnails.shared.image(for: it, px: 32)
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in src.draw(in: r); return true }
        cell.image = img
        cell.isLeaf = !n.isFolder
        cell.font = .systemFont(ofSize: 13)
    }

    func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? { preview }
    func browser(_ browser: NSBrowser, headerViewControllerForItem item: Any?) -> NSViewController? { nil }

    func load(_ n: ColumnNode, then: (() -> Void)? = nil) {
        guard !n.loading else { return }
        n.loading = true
        nodes[n.location] = n
        Task {
            let items = (try? await Catalog.shared.list(n.location) { _ in }) ?? []
            let order = pane?.comparator() ?? { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            n.children = items.sorted(by: order).map { ColumnNode(item: $0, location: $0.target ?? n.location) }
            n.loading = false
            if let col = column(of: n) { browser.reloadColumn(col) }
            then?()
        }
    }

    /// The column that shows `n`'s children.
    func column(of n: ColumnNode) -> Int? {
        if n === root { return 0 }
        guard browser.lastColumn >= 0 else { return nil }
        for c in 0...browser.lastColumn where (browser.parentForItems(inColumn: c) as? ColumnNode) === n { return c }
        return nil
    }

    func reselect(_ keys: Set<String>, in n: ColumnNode) {
        guard let col = column(of: n), let kids = n.children else { return }
        let rows = IndexSet(kids.indices.filter { kids[$0].item.map { keys.contains($0.key) } ?? false })
        if !rows.isEmpty { browser.selectRowIndexes(rows, inColumn: col) }
    }

    func select(keys: Set<String>) {
        guard let pane, let n = nodes[pane.location] else { return }
        reselect(keys, in: n)
        selectionChanged()
    }

    // MARK: Selection

    var selectedNodes: [ColumnNode] {
        let col = browser.selectedColumn
        guard col >= 0, let rows = browser.selectedRowIndexes(inColumn: col) else { return [] }
        return rows.compactMap { browser.item(atRow: $0, inColumn: col) as? ColumnNode }
    }
    var selectedItems: [Item] { selectedNodes.compactMap(\.item) }

    /// The folder whose column holds the selection (where New Folder, Paste and drops go).
    var currentFolder: Location {
        let col = browser.selectedColumn
        if col >= 0, let parent = browser.parentForItems(inColumn: col) as? ColumnNode { return parent.location }
        return root.location
    }

    @objc func clicked() { selectionChanged() }

    func selectionChanged() {
        guard let pane else { return }
        pane.columnFolderChanged(currentFolder)
        pane.itemViewSelectionChanged()
    }

    @objc func doubleClicked() {
        guard let pane, let n = selectedNodes.first, selectedNodes.count == 1, let it = n.item else { return }
        if it.isContainer, let t = it.target { pane.navigate(to: t); return }
        pane.activate([it])
    }

    func menu() -> NSMenu? {
        guard let pane else { return nil }
        pane.browser?.setActivePane(pane)
        return ContextMenu.build(for: selectedItems, pane: pane)
    }

    // MARK: Drag and drop

    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool { true }

    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        guard let pane else { return false }
        let items = rowIndexes.compactMap { (browser.item(atRow: $0, inColumn: column) as? ColumnNode)?.item }
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items.map { pane.writer($0) })
    }

    func target(row: Int, column: Int, on: Bool) -> Location {
        if on, row >= 0, let n = browser.item(atRow: row, inColumn: column) as? ColumnNode, n.isFolder, n.item != nil { return n.location }
        return (browser.parentForItems(inColumn: column) as? ColumnNode)?.location ?? root.location
    }

    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>,
                 column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
        let op = DragDrop.operation(info, to: target(row: row.pointee, column: column.pointee, on: dropOperation.pointee == .on))
        if op.isEmpty, dropOperation.pointee == .on { dropOperation.pointee = .above; row.pointee = -1 }
        return op.isEmpty ? DragDrop.operation(info, to: target(row: -1, column: column.pointee, on: false)) : op
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int, dropOperation: NSBrowser.DropOperation) -> Bool {
        DragDrop.perform(info, to: target(row: row, column: column, on: dropOperation == .on), window: browser.window)
    }
}
