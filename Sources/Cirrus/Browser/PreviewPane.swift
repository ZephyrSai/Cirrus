import AppKit
import CirrusCore
import Quartz

/// Finder-style Preview: a large preview of the selection with its details. Used docked on the right of
/// a window (View › Show Preview) and as the last column of the column view.
@MainActor
final class PreviewPaneController: NSViewController {
    let ql: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)!
    let imageView = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let kindLabel = NSTextField(labelWithString: "")
    let infoGrid = NSGridView()
    let infoHeader = NSTextField(labelWithString: "Information")
    let spinner = NSProgressIndicator()
    var token = 0
    var previewHeight: NSLayoutConstraint?
    var location: Location?
    /// The column view sizes its preview by frame (inside a scroll view) and needs a real starting height.
    /// Everywhere else (the docked pane, Gallery) Auto Layout sizes it: a fixed frame there would pin the
    /// whole window's size.
    let inColumn: Bool

    init(inColumn: Bool = false) { self.inColumn = inColumn; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        // Never a fixed size: in the docked pane it fills whatever space it's given (a fixed frame here pinned the
        // whole window's size); in the column view it keeps its own height without forcing the column to it.
        root.autoresizingMask = inColumn ? [.width, .minYMargin, .maxYMargin] : [.width, .height]
        ql.shouldCloseWithWindow = false
        ql.autostarts = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Never let a large image size the pane: the box decides, the image scales into it.
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.init(1), for: o)
            imageView.setContentHuggingPriority(.init(1), for: o)
            ql.setContentCompressionResistancePriority(.init(1), for: o)
        }
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        let box = NSView()
        for v in [ql, imageView, spinner] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        NSLayoutConstraint.activate([
            ql.topAnchor.constraint(equalTo: box.topAnchor), ql.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ql.leadingAnchor.constraint(equalTo: box.leadingAnchor), ql.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: box.topAnchor), imageView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: box.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.alignment = .left
        kindLabel.font = .systemFont(ofSize: 12)
        kindLabel.textColor = .secondaryLabelColor
        infoHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        infoGrid.rowSpacing = 5
        infoGrid.columnSpacing = 10
        let sep = NSBox(); sep.boxType = .separator
        let stack = NSStackView(views: [box, titleLabel, kindLabel, sep, infoHeader, infoGrid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: box)
        stack.setCustomSpacing(12, after: kindLabel)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        // A preference only: it must rank below window resizing (500), or the 380-pt cap below would also cap
        // the window's width (this is what stopped the window growing and going full screen).
        let h = box.heightAnchor.constraint(equalTo: box.widthAnchor, multiplier: 0.8)
        h.priority = .defaultLow
        h.isActive = true
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        box.heightAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        view = root
        clear()
    }

    /// The column view hands the selected leaf over here.
    override var representedObject: Any? {
        didSet { if let n = representedObject as? ColumnNode, let it = n.item { show([it], location: n.location) } }
    }

    func clear() {
        ql.previewItem = nil
        ql.isHidden = true
        imageView.image = nil
        titleLabel.stringValue = ""
        kindLabel.stringValue = ""
        infoHeader.isHidden = true
        setInfo([])
    }

    func show(_ items: [Item], location loc: Location) {
        token += 1
        let t = token
        location = loc
        spinner.stopAnimation(nil)
        ql.previewItem = nil
        ql.isHidden = true
        imageView.isHidden = false
        guard let item = items.first else {
            imageView.image = Thumbnails.shared.symbol(Catalog.shared.symbolName(loc), size: 160, color: .tertiaryLabelColor)
            titleLabel.stringValue = Catalog.shared.title(loc)
            kindLabel.stringValue = "No selection"
            infoHeader.isHidden = true
            setInfo([])
            return
        }
        if items.count > 1 {
            imageView.image = Thumbnails.shared.symbol("square.stack.3d.up", size: 160, color: .tertiaryLabelColor)
            titleLabel.stringValue = "\(items.count) items"
            let bytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            kindLabel.stringValue = bytes > 0 ? bytes.byteString : ""
            infoHeader.isHidden = true
            setInfo([])
            return
        }
        titleLabel.stringValue = item.name
        let sizeText: String? = item.isContainer ? (Prefs.calculateSizes ? FolderSizer.shared.cached(item)?.byteString : nil) ?? item.count.map { "\($0) items" } : item.size.map { $0.byteString }
        kindLabel.stringValue = [item.kindText, sizeText].compactMap { $0 }.joined(separator: " — ")
        infoHeader.isHidden = false
        setInfo(rows(for: item))
        imageView.image = Thumbnails.shared.image(for: item, px: 512)

        if item.isPhoto {
            // Photos: the medium rendition is plenty and never downloads the original.
            Task { if let img = await Thumbnails.shared.load(item, px: 1024), t == token { imageView.image = img } }
            return
        }
        if item.isContainer { return }
        if let u = item.localURL { present(u, item: item); return }
        if Thumbnails.shared.wantsThumbnail(item) {
            Task { if let img = await Thumbnails.shared.load(item, px: 512), t == token { imageView.image = img } }
        }
        // iCloud Drive files: a real preview for smaller files, fetched once into the preview cache.
        guard item.driveNode != nil, Thumbnails.drivePreviews, (item.size ?? .max) <= 25 << 20 else { return }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)   // don't download while arrowing through a list
            guard t == token else { return }
            spinner.startAnimation(nil)
            let u = try? await Ops.shared.localCopy(item, cache: "Preview", progressTitle: nil)
            guard t == token else { return }
            spinner.stopAnimation(nil)
            if let u { present(u, item: item) }
        }
    }

    /// Images are drawn directly (sharp, instant); everything else goes through Quick Look.
    func present(_ u: URL, item: Item) {
        if item.utType?.conforms(to: .image) == true, let img = NSImage(contentsOf: u) {
            imageView.image = img
            imageView.isHidden = false
            ql.isHidden = true
            return
        }
        ql.previewItem = u as NSURL
        ql.isHidden = false
        imageView.isHidden = true
    }

    func rows(for item: Item) -> [(String, String)] {
        var out = [(String, String)]()
        let df: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
        if let p = item.photo {
            if let c = p.created { out.append(("Taken", df(c))) }
            if let a = p.added { out.append(("Added", df(a))) }
            if p.width > 0 { out.append(("Dimensions", "\(p.width) × \(p.height)")) }
            if let d = p.duration, d > 0 { out.append(("Duration", String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))) }
            if p.isLive { out.append(("Live Photo", "Yes")) }
        } else {
            if let c = item.created { out.append(("Created", df(c))) }
            if let m = item.modified { out.append(("Modified", df(m))) }
        }
        if !item.tags.isEmpty { out.append(("Tags", item.tags.map(\.name).joined(separator: ", "))) }
        if let u = item.localURL { out.append(("Where", PaneController.abbreviate(u.deletingLastPathComponent().path))) }
        else if let loc = location { out.append(("Where", Catalog.shared.pathComponents(loc).map(\.0).joined(separator: " › "))) }
        return out
    }

    func setInfo(_ rows: [(String, String)]) {
        // removeRow leaves the row's views behind, so take them out too (they'd draw over the new rows).
        while infoGrid.numberOfRows > 0 {
            let r = infoGrid.row(at: 0)
            for c in 0..<r.numberOfCells { r.cell(at: c).contentView?.removeFromSuperview() }
            infoGrid.removeRow(at: 0)
        }
        for (k, v) in rows {
            let key = NSTextField(labelWithString: k)
            key.font = .systemFont(ofSize: 11); key.textColor = .secondaryLabelColor; key.alignment = .left
            let val = NSTextField(wrappingLabelWithString: v)
            val.font = .systemFont(ofSize: 11)
            val.maximumNumberOfLines = 3
            val.lineBreakMode = .byTruncatingMiddle
            val.preferredMaxLayoutWidth = 200
            infoGrid.addRow(with: [key, val])
        }
        if infoGrid.numberOfColumns > 0 { infoGrid.column(at: 0).xPlacement = .leading }
    }
}
