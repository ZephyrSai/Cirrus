import AppKit
import CirrusCore

/// Layer-backed image view with aspect-fit (icons) or aspect-fill (photos).
final class ThumbView: NSView {
    var fill = false { didSet { layer?.contentsGravity = fill ? .resizeAspectFill : .resizeAspect } }
    var image: NSImage? {
        didSet {
            guard let layer else { return }
            let scale = window?.backingScaleFactor ?? 2
            layer.contents = image.map { $0.layerContents(forContentsScale: scale) }
            layer.contentsScale = scale
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
}

final class IconCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("IconCell")
    let thumb = ThumbView()
    let label = NSTextField(labelWithString: "")
    let badge = NSImageView()
    let favorite = NSImageView()
    let duration = NSTextField(labelWithString: "")
    let selectionBG = NSView()
    var item: Item?
    var photoMode = false
    var loadToken = 0

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        selectionBG.wantsLayer = true
        selectionBG.layer?.cornerRadius = 6
        selectionBG.layer?.cornerCurve = .continuous
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.font = .systemFont(ofSize: 12)
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        badge.imageScaling = .scaleProportionallyUpOrDown
        favorite.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
        favorite.contentTintColor = .white
        favorite.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black.withAlphaComponent(0.6); return s }()
        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        duration.textColor = .white
        duration.shadow = favorite.shadow
        for s in [selectionBG, thumb, label, badge, favorite, duration] { v.addSubview(s) }
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        if photoMode {
            thumb.frame = b.insetBy(dx: 1, dy: 1)
            if !Prefs.squarePhotoGrid, let img = thumb.image, item?.isPhoto == true { DispatchQueue.main.async { self.fitSelectionToImage(img) } }
            thumb.layer?.cornerRadius = 3
            selectionBG.frame = b
            label.isHidden = true
            favorite.frame = NSRect(x: 6, y: 5, width: 14, height: 13)
            duration.sizeToFit()
            duration.frame.origin = NSPoint(x: b.maxX - duration.frame.width - 6, y: 4)
            badge.frame = NSRect(x: b.maxX - 22, y: b.maxY - 22, width: 16, height: 16)
        } else {
            label.isHidden = false
            let labelH: CGFloat = 32
            let side = min(b.width - 16, b.height - labelH - 10)
            thumb.frame = NSRect(x: (b.width - side) / 2, y: labelH + 6, width: side, height: side)
            thumb.layer?.cornerRadius = 4
            selectionBG.frame = thumb.frame.insetBy(dx: -5, dy: -5)
            let fit = label.sizeThatFits(NSSize(width: b.width - 4, height: labelH))
            let w = min(b.width - 4, fit.width + 8)
            label.frame = NSRect(x: (b.width - w) / 2, y: max(0, labelH - fit.height) , width: w, height: min(labelH, fit.height))
            badge.frame = NSRect(x: thumb.frame.maxX - 12, y: thumb.frame.minY - 2, width: 16, height: 16)
            favorite.frame = NSRect(x: thumb.frame.minX + 2, y: thumb.frame.minY + 2, width: 12, height: 11)
            duration.frame = .zero
        }
    }

    func configure(_ item: Item, photoMode: Bool, px: Int) {
        self.item = item
        self.photoMode = photoMode
        label.stringValue = item.name
        let fill = photoMode && item.isPhoto && Prefs.squarePhotoGrid
        thumb.fill = fill
        thumb.image = Thumbnails.shared.image(for: item, px: px)
        favorite.isHidden = !(item.photo?.isFavorite ?? false)
        if let d = item.photo?.duration, d > 0, item.isVideo {
            duration.stringValue = String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
            duration.isHidden = !photoMode
        } else { duration.isHidden = true }
        badge.isHidden = false
        switch item.cloud {
        case .cloudOnly: badge.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "In iCloud"); badge.contentTintColor = .secondaryLabelColor
        case .downloading: badge.image = NSImage(systemSymbolName: "arrow.down.circle.dotted", accessibilityDescription: "Downloading"); badge.contentTintColor = .controlAccentColor
        case .uploading, .waitingUpload: badge.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Uploading"); badge.contentTintColor = .controlAccentColor
        case .error: badge.image = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: "Error"); badge.contentTintColor = .systemRed
        default:
            if item.photo?.isLive == true && photoMode {
                badge.image = NSImage(systemSymbolName: "livephoto", accessibilityDescription: "Live Photo"); badge.contentTintColor = .white
            } else { badge.isHidden = true }
        }
        view.toolTip = item.name
        updateSelection()
        view.needsLayout = true
        loadToken += 1
        let token = loadToken
        if Thumbnails.shared.wantsThumbnail(item) {
            Task { @MainActor in
                if let img = await Thumbnails.shared.load(item, px: px), token == self.loadToken {
                    self.thumb.image = img
                    self.thumb.fill = fill
                    if photoMode && !fill { self.fitSelectionToImage(img) }
                }
            }
        }
    }

    /// Aspect-ratio grid: shrink the thumb frame to the image so the selection ring hugs the photo.
    func fitSelectionToImage(_ img: NSImage) {
        let b = view.bounds.insetBy(dx: 1, dy: 1)
        guard img.size.width > 0, img.size.height > 0 else { return }
        let scale = min(b.width / img.size.width, b.height / img.size.height)
        let w = img.size.width * scale, h = img.size.height * scale
        thumb.frame = NSRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        favorite.frame.origin = NSPoint(x: thumb.frame.minX + 5, y: thumb.frame.minY + 4)
        badge.frame.origin = NSPoint(x: thumb.frame.maxX - 21, y: thumb.frame.maxY - 21)
        duration.frame.origin = NSPoint(x: thumb.frame.maxX - duration.frame.width - 5, y: thumb.frame.minY + 3)
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        let key = view.window?.isKeyWindow ?? true
        let focused = key && (view.window?.firstResponder === collectionView)
        if photoMode {
            selectionBG.layer?.backgroundColor = .clear
            thumb.layer?.borderWidth = on ? 3 : 0
            thumb.layer?.borderColor = (focused ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
            thumb.alphaValue = 1
        } else {
            thumb.layer?.borderWidth = 0
            selectionBG.layer?.backgroundColor = on ? NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor : .clear
            label.layer?.backgroundColor = on ? (focused ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).cgColor : .clear
            label.textColor = on && focused ? .alternateSelectedControlTextColor : .labelColor
        }
        if highlightState == .forDeselection { selectionBG.layer?.backgroundColor = .clear }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadToken += 1
        thumb.image = nil
    }
}

final class SectionHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("SectionHeader")
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        addSubview(title); addSubview(subtitle)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        title.sizeToFit(); subtitle.sizeToFit()
        title.frame.origin = NSPoint(x: 12, y: (bounds.height - title.frame.height) / 2)
        subtitle.frame.origin = NSPoint(x: title.frame.maxX + 8, y: (bounds.height - subtitle.frame.height) / 2 - 1)
    }
}

protocol ItemViewHost: AnyObject {
    func itemView(doubleClicked index: Int)
    func itemViewMenu(for indexes: IndexSet) -> NSMenu?
    func itemViewKey(_ event: NSEvent) -> Bool
    func itemViewSelectionChanged()
}

final class GridCollectionView: NSCollectionView {
    weak var host: ItemViewHost?
    var flatIndex: ((IndexPath) -> Int?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            if let ip = indexPathForItem(at: p), let i = flatIndex?(ip) { host?.itemView(doubleClicked: i) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p), !selectionIndexPaths.contains(ip) {
            deselectAll(nil)
            selectionIndexPaths = [ip]
            delegate?.collectionView?(self, didSelectItemsAt: [ip])
        } else if indexPathForItem(at: p) == nil {
            deselectAll(nil)
            host?.itemViewSelectionChanged()
        }
        let flat = IndexSet(selectionIndexPaths.compactMap { flatIndex?($0) })
        return host?.itemViewMenu(for: flat)
    }

    override func keyDown(with event: NSEvent) {
        if host?.itemViewKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); refreshSelection(); return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); refreshSelection(); return r }
    func refreshSelection() { for i in visibleItems() { (i as? IconCell)?.updateSelection() } }
}

final class ListTableView: NSTableView {
    weak var host: ItemViewHost?
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        return host?.itemViewMenu(for: selectedRowIndexes)
    }
    override func keyDown(with event: NSEvent) {
        if host?.itemViewKey(event) == true { return }
        super.keyDown(with: event)
    }
}

final class NameCellView: NSTableCellView {
    let icon = ThumbView()
    let name = NSTextField(labelWithString: "")
    let status = NSImageView()
    var token = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 13)
        addSubview(icon); addSubview(name); addSubview(status)
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: (h - 18) / 2, width: 18, height: 18)
        status.frame = NSRect(x: bounds.width - 18, y: (h - 14) / 2, width: 14, height: 14)
        let nh = name.intrinsicContentSize.height
        name.frame = NSRect(x: 26, y: (h - nh) / 2, width: bounds.width - 26 - (status.isHidden ? 2 : 22), height: nh)
    }
    func configure(_ item: Item) {
        name.stringValue = item.name
        icon.fill = item.isPhoto
        icon.layer?.cornerRadius = item.isPhoto ? 2 : 0
        icon.image = Thumbnails.shared.image(for: item, px: 64)
        status.isHidden = item.cloud == nil || item.cloud == .downloaded
        switch item.cloud {
        case .cloudOnly: status.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil); status.contentTintColor = .secondaryLabelColor
        case .downloading: status.image = NSImage(systemSymbolName: "arrow.down.circle.dotted", accessibilityDescription: nil); status.contentTintColor = .controlAccentColor
        case .uploading, .waitingUpload: status.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil); status.contentTintColor = .controlAccentColor
        case .error: status.image = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: nil); status.contentTintColor = .systemRed
        default: break
        }
        if item.photo?.isFavorite == true { status.isHidden = false; status.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil); status.contentTintColor = .systemPink }
        needsLayout = true
        token += 1
        let t = token
        if item.isPhoto {
            Task { @MainActor in if let img = await Thumbnails.shared.load(item, px: 64), t == self.token { self.icon.image = img } }
        }
    }
}
