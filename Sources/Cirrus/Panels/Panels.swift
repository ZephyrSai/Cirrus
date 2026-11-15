import AppKit
import CirrusCore

// MARK: - Transfers

@MainActor
final class TransfersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let summary = NSTextField(labelWithString: "")
    var rows = [Transfer]()
    var observer: NSObjectProtocol?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))
        let scroll = NSScrollView()
        table.headerView = nil
        table.rowHeight = 54
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.addTableColumn(NSTableColumn(identifier: .init("t")))
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let clear = NSButton(title: "Clear Finished", target: self, action: #selector(clearDone))
        let stop = NSButton(title: "Stop All", target: self, action: #selector(stopAll))
        for b in [clear, stop] { b.controlSize = .small; b.bezelStyle = .push }
        let bar = NSStackView(views: [summary, NSView(), stop, clear])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 34),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 420), root.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        view = root
        preferredContentSize = NSSize(width: 460, height: 380)
        observer = NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let all = TransferManager.shared.transfers
        let newRows = all.filter { !$0.isFinished } + all.filter(\.isFinished).reversed()
        if newRows.map(\.id) == rows.map(\.id) {
            rows = newRows
            for r in 0..<rows.count { (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? TransferRow)?.update(rows[r]) }
        } else {
            rows = newRows
            table.reloadData()
        }
        let o = TransferManager.shared.overall
        summary.stringValue = o.count == 0 ? (rows.isEmpty ? "No transfers" : "All done") : "\(o.count) active — \(o.done.byteString) of \(o.total.byteString)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(rows.count, 1) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if rows.isEmpty {
            let t = NSTextField(labelWithString: "Downloads, uploads, exports and backups show up here.")
            t.textColor = .tertiaryLabelColor
            t.alignment = .center
            return t
        }
        let v = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? TransferRow) ?? TransferRow()
        v.identifier = .init("row")
        v.update(rows[row])
        return v
    }

    @objc func clearDone() { TransferManager.shared.clearAllFinished() }
    @objc func stopAll() { TransferManager.shared.cancelAll() }
}

final class TransferRow: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let button = NSButton()
    weak var transfer: Transfer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0; bar.maxValue = 1
        button.isBordered = false
        button.target = self
        button.action = #selector(act)
        let text = NSStackView(views: [title, bar, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.detachesHiddenViews = true
        for v in [icon, text, button] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor), title.widthAnchor.constraint(equalTo: text.widthAnchor),
            detail.widthAnchor.constraint(equalTo: text.widthAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 20), button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ t: Transfer) {
        transfer = t
        title.stringValue = t.title
        let sym: String
        switch t.direction { case .download: sym = "arrow.down.circle"; case .upload: sym = "arrow.up.circle"; case .copy: sym = "doc.on.doc"; case .other: sym = "gearshape" }
        icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        bar.isHidden = t.isFinished
        bar.isIndeterminate = t.total <= 0 && t.state == .running
        if bar.isIndeterminate { bar.startAnimation(nil) } else { bar.stopAnimation(nil); bar.doubleValue = t.fraction }
        var d: String
        switch t.state {
        case .queued: d = "Waiting… " + t.detail; icon.contentTintColor = .tertiaryLabelColor
        case .running:
            d = t.total > 0 ? "\(t.completed.byteString) of \(t.total.byteString)" : t.detail
            if t.speed > 1 { d += " — \(Int64(t.speed).byteString)/s" }
            if let eta = t.etaText { d += " — \(eta)" }
            if t.total > 0 && !t.detail.isEmpty { d += " — " + t.detail }
            icon.contentTintColor = .controlAccentColor
        case .done: d = "Done" + (t.total > 0 ? " — \(t.total.byteString)" : ""); icon.contentTintColor = .systemGreen
        case .failed(let m): d = m; icon.contentTintColor = .systemRed
        case .cancelled: d = "Stopped"; icon.contentTintColor = .secondaryLabelColor
        }
        detail.stringValue = d
        detail.toolTip = d
        switch t.state {
        case .queued, .running: button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop"); button.contentTintColor = .tertiaryLabelColor; button.isHidden = false
        case .failed, .cancelled: button.image = NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: "Retry"); button.contentTintColor = .controlAccentColor; button.isHidden = false
        case .done: button.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Show"); button.contentTintColor = .secondaryLabelColor; button.isHidden = t.resultURL == nil
        }
    }

    @objc func act() {
        guard let t = transfer else { return }
        MainActor.assumeIsolated {
            switch t.state {
            case .queued, .running: TransferManager.shared.cancel(t)
            case .failed, .cancelled: TransferManager.shared.retry(t)
            case .done: if let u = t.resultURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
        }
    }
}

// MARK: - Get Info

@MainActor
final class InfoPanel: NSObject {
    static let shared = InfoPanel()
    lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520), styleMask: [.titled, .closable, .utilityWindow, .resizable],
                        backing: .buffered, defer: false)
        p.title = "Info"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.setFrameAutosaveName("CirrusInfo")
        p.contentView = stack
        return p
    }()
    let stack = NSStackView()
    let preview = ThumbView()
    var token = 0
    var isVisible: Bool { panel.isVisible }

    func show(items: [Item], location: Location, bringToFront: Bool = true) {
        if bringToFront { panel.orderFront(nil) }
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 268).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(preview)
        var rows = [(String, String)]()
        let item = items.count == 1 ? items[0] : nil
        if let item {
            preview.fill = false
            preview.image = Thumbnails.shared.image(for: item, px: 512)
            token += 1
            let t = token
            if Thumbnails.shared.wantsThumbnail(item) {
                Task { if let img = await Thumbnails.shared.load(item, px: 1024), t == self.token { self.preview.image = img } }
            }
            panel.title = item.name
            add(title: item.name)
            rows.append(("Kind", item.kindText))
            if let s = item.size, !item.isContainer { rows.append(("Size", "\(s.byteString) (\(NumberFormatter.localizedString(from: NSNumber(value: s), number: .decimal)) bytes)")) }
            if let c = item.count { rows.append(("Contains", "\(c) item\(c == 1 ? "" : "s")")) }
            rows.append(("Where", Catalog.shared.pathComponents(location).map(\.0).joined(separator: " › ")))
            if let p = item.photo {
                if let d = p.created { rows.append(("Taken", DateFormatter.localizedString(from: d, dateStyle: .full, timeStyle: .short))) }
                if let d = p.added { rows.append(("Added", DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short))) }
                if p.width > 0 { rows.append(("Dimensions", "\(p.width) × \(p.height) (\(String(format: "%.1f", Double(p.width * p.height) / 1e6)) MP)")) }
                if let d = p.duration, d > 0 { rows.append(("Duration", String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))) }
                var flags = [String]()
                if p.isLive { flags.append("Live Photo") }
                if p.isFavorite { flags.append("Favorite") }
                if p.isHidden { flags.append("Hidden") }
                if p.isEdited { flags.append("Edited") }
                if p.resource(.alternate) != nil { flags.append("RAW + JPEG") }
                if !flags.isEmpty { rows.append(("Details", flags.joined(separator: ", "))) }
                let res = p.resources.filter { ![.thumbnail, .medium].contains($0.kind) }.map { "\($0.filename) — \($0.size.byteString)" }
                if !res.isEmpty { rows.append(("Files", res.joined(separator: "\n"))) }
            } else {
                if let d = item.created { rows.append(("Created", DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short))) }
                if let d = item.modified { rows.append(("Modified", DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short))) }
            }
            if let c = item.cloud {
                let s: String
                switch c { case .cloudOnly: s = "In iCloud only (not downloaded)"; case .downloading: s = "Downloading"; case .downloaded: s = "Downloaded"; case .uploading: s = "Uploading"; case .waitingUpload: s = "Waiting to upload"; case .error: s = "Sync error" }
                rows.append(("iCloud", s))
            }
            if let v = item.volume {
                rows.append(("Capacity", v.total.byteString)); rows.append(("Available", v.available.byteString)); rows.append(("Format", v.format ?? "—"))
            }
            if let u = item.localURL { rows.append(("Path", u.path)) }
        } else if items.isEmpty {
            panel.title = Catalog.shared.title(location)
            preview.image = Thumbnails.shared.symbol(Catalog.shared.symbolName(location), size: 160, color: .systemBlue)
            add(title: Catalog.shared.title(location))
            rows.append(("Where", Catalog.shared.pathComponents(location).map(\.0).joined(separator: " › ")))
            if let u = location.localURL, let v = VolumeInfo.info(for: u) { rows.append(("Volume", "\(v.name) — \(v.available.byteString) free of \(v.total.byteString)")) }
        } else {
            panel.title = "\(items.count) items"
            preview.image = Thumbnails.shared.symbol("square.stack.3d.up", size: 160, color: .secondaryLabelColor)
            add(title: "\(items.count) items")
            let bytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            rows.append(("Size", bytes.byteString))
            let photos = items.filter(\.isPhoto).count
            if photos > 0 { rows.append(("Photos", "\(photos)")) }
        }
        for (k, v) in rows {
            let key = NSTextField(labelWithString: k)
            key.font = .systemFont(ofSize: 11, weight: .semibold)
            key.textColor = .secondaryLabelColor
            let val = NSTextField(wrappingLabelWithString: v)
            val.font = .systemFont(ofSize: 12)
            val.isSelectable = true
            val.preferredMaxLayoutWidth = 268
            stack.addArrangedSubview(key)
            stack.addArrangedSubview(val)
            stack.setCustomSpacing(10, after: val)
        }
    }

    func add(title: String) {
        let t = NSTextField(wrappingLabelWithString: title)
        t.font = .systemFont(ofSize: 15, weight: .semibold)
        t.preferredMaxLayoutWidth = 268
        stack.addArrangedSubview(t)
        stack.setCustomSpacing(12, after: t)
    }
}

// MARK: - Account info

@MainActor
enum AccountInfo {
    static func show(_ a: Account, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = a.appleID ?? a.title
        alert.informativeText = "Loading iCloud storage…"
        alert.addButton(withTitle: "Done")
        if a.kind == .web { alert.addButton(withTitle: "Sign Out…") }
        let bar = StorageBar(frame: NSRect(x: 0, y: 0, width: 360, height: 88))
        alert.accessoryView = bar
        Task {
            if let u = await a.storageUsage() {
                bar.usage = u
                alert.informativeText = "\(u.used.byteString) of \(u.total.byteString) used — \(u.available.byteString) available"
            } else {
                alert.informativeText = a.kind == .mac ? "This Mac’s iCloud is managed by macOS (System Settings › Apple Account)." : "Storage information isn’t available right now."
            }
        }
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertSecondButtonReturn {
                AccountManager.shared.signOut(a)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

final class StorageBar: NSView {
    var usage: StorageUsage? { didSet { needsDisplay = true } }
    static let palette: [NSColor] = [.systemYellow, .systemPurple, .systemOrange, .systemBlue, .systemGreen, .systemTeal, .systemPink, .systemIndigo]
    override func draw(_ dirtyRect: NSRect) {
        let barRect = NSRect(x: 0, y: bounds.height - 22, width: bounds.width, height: 14)
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).addClip()
        NSColor.quaternaryLabelColor.setFill()
        barRect.fill()
        guard let u = usage, u.total > 0 else { return }
        var x = barRect.minX
        for (i, c) in u.categories.enumerated() where c.bytes > 0 {
            let w = barRect.width * CGFloat(Double(c.bytes) / Double(u.total))
            Self.color(c, i).setFill()
            NSRect(x: x, y: barRect.minY, width: max(1, w), height: barRect.height).fill()
            x += w
        }
        NSGraphicsContext.current?.cgContext.resetClip()
        var lx: CGFloat = 0, ly = bounds.height - 42
        for (i, c) in u.categories.enumerated() where c.bytes > 0 {
            let s = NSAttributedString(string: "\(c.label) \(c.bytes.byteString)", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor])
            let w = s.size().width + 22
            if lx + w > bounds.width { lx = 0; ly -= 16 }
            Self.color(c, i).setFill()
            NSBezierPath(ovalIn: NSRect(x: lx, y: ly + 3, width: 8, height: 8)).fill()
            s.draw(at: NSPoint(x: lx + 11, y: ly))
            lx += w
        }
    }
    static func color(_ c: StorageUsage.Category, _ i: Int) -> NSColor {
        if let hex = c.color, hex.count == 6, let v = UInt32(hex, radix: 16) {
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return palette[i % palette.count]
    }
}

// MARK: - Help

@MainActor
enum HelpWindow {
    static var window: NSWindow?
    static func show() {
        if window == nil {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 18, height: 18)
            tv.string = """
            Cirrus — a Finder for iCloud

            Where your iCloud comes from
            • If this Mac is signed in to iCloud, Cirrus uses it directly: iCloud Drive is the real folder macOS syncs, and Photos is your system Photos library (iCloud Photos when it’s on).
            • You can also sign in to any Apple ID inside Cirrus (File › Sign In with Apple ID…). Cirrus talks to iCloud’s web services the way icloud.com does; your password goes only to Apple, with two-factor authentication. Sessions last about 30 days.
            • Advanced Data Protection: turn on “Access iCloud Data on the Web” on your iPhone, then approve the prompt Cirrus triggers.

            Moving things
            • Drag between panes, windows, the sidebar and Finder. Dragging out of iCloud downloads on drop; dragging in uploads or imports.
            • ⌥ copies, ⌘ moves. Two panes: View › Two Panes (⌃⌘2); Tab switches panes.
            • Before anything is queued Cirrus checks sizes against free space in iCloud or on the disk, skips files over iCloud Drive’s 50 GB limit (or FAT32’s 4 GB), and asks before very large batches.

            Sync & Backup
            • Back Up iCloud… measures your iCloud Drive and Photos against the drive you pick, then downloads everything: originals, Live Photo videos, edits and RAW files, dated by capture time, with a manifest of favorites and albums. Later runs only fetch what’s new. Set it to run whenever that drive is connected.
            • Sync Jobs keep a folder copied, mirrored or two-way synced between your disk and iCloud Drive, or export/import Photos. Removed files always go to the Trash or Recently Deleted, never straight to deletion, and a preview shows exactly what will happen.

            Keyboard
            Space Quick Look · Return Rename · ⌘↓ Open · ⌘↑ Enclosing folder · ⌘[ ⌘] Back/Forward · ⌘⌫ Trash · ⌘I Info · ⌘1/⌘2 Icons/List · ⇧⌘N New folder · ⌘U Upload · ⇧⌘B Back up
            """
            let scroll = NSScrollView(frame: tv.frame)
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            let w = NSWindow(contentRect: tv.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Cirrus Help"
            w.contentView = scroll
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
