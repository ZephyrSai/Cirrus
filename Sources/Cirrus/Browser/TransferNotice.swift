import AppKit
import CirrusCore

/// A small notice at the bottom of the window that confirms what just happened with a drop, paste or
/// Copy To / Upload / Download: "Preparing…" right away (while space and name checks run), then
/// "Added to the upload queue" once the transfers are queued. Clicking it opens Transfers.
@MainActor
final class TransferNotice {
    static let shared = TransferNotice()
    private var known = Set<UUID>()
    private var fresh = [Transfer]()
    private var flush: Timer?
    private var hideTimer: Timer?
    private weak var view: NoticeView?
    private var preparingSince: Date?
    private var preparingDepth = 0

    private init() {
        known = Set(TransferManager.shared.transfers.map(\.id))
        NotificationCenter.default.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TransferNotice.shared.queueChanged() }
        }
    }

    static func start() { _ = shared }

    // MARK: Preparing

    /// Shown the moment an action starts; replaced when its transfers are queued, removed if nothing was queued.
    func preparing(_ count: Int, to dest: Destination, move: Bool, window: NSWindow?) {
        preparingDepth += 1
        if preparingSince == nil { preparingSince = Date() }
        let what = count == 1 ? "1 item" : "\(count) items"
        let text: String
        switch dest {
        case .drive(let acct, _):
            text = "Checking \(acct.isICloud ? "iCloud" : (acct.provider?.displayName ?? "")) space and names, then uploading \(what) to “\(dest.title)”…"
        case .photos: text = "Preparing to import \(what) into \(dest.title)…"
        case .local: text = "Preparing to \(move ? "move" : "copy") \(what) to “\(dest.title)”…"
        }
        show(text, symbol: nil, spinning: true, window: window, hideAfter: 30)
    }

    func preparingDownload(_ count: Int, to dir: URL, window: NSWindow?) {
        preparingDepth += 1
        if preparingSince == nil { preparingSince = Date() }
        show("Preparing to download \(count == 1 ? "1 item" : "\(count) items") to “\(FileManager.default.displayName(atPath: dir.path))”…",
             symbol: nil, spinning: true, window: window, hideAfter: 30)
    }

    /// The action finished its checks. If it queued nothing (cancelled, skipped, blocked), drop the notice.
    func donePreparing(queuedAnything: Bool) {
        preparingDepth = max(0, preparingDepth - 1)
        guard preparingDepth == 0 else { return }
        preparingSince = nil
        if !queuedAnything && fresh.isEmpty, view?.spinning == true { hide() }
    }

    // MARK: Queue

    private func queueChanged() {
        let all = TransferManager.shared.transfers
        let new = all.filter { !known.contains($0.id) }
        known.formUnion(new.map(\.id))
        known = known.intersection(all.map(\.id))
        guard !new.isEmpty else { return }
        fresh += new
        flush?.invalidate()
        flush = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in MainActor.assumeIsolated { TransferNotice.shared.announce() } }
    }

    private func announce() {
        let batch = fresh
        fresh = []
        guard !batch.isEmpty else { return }
        let ups = batch.filter { $0.direction == .upload }.count, downs = batch.filter { $0.direction == .download }.count
        let copies = batch.filter { $0.direction == .copy }.count, other = batch.count - ups - downs - copies
        let (queue, symbol): (String, String) = ups >= max(downs, copies, other) ? ("upload", "icloud.and.arrow.up") :
            downs >= max(copies, other) ? ("download", "icloud.and.arrow.down") : copies >= other ? ("copy", "doc.on.doc") : ("transfer", "arrow.left.arrow.right")
        let text = batch.count == 1 ? "“\(batch[0].title)” added to the \(queue) queue" : "\(batch.count) items added to the \(queue) queue"
        show(text, symbol: symbol, spinning: false, window: nil, hideAfter: 3.5, link: "Show Transfers")
    }

    // MARK: View

    private func browserWindow(_ preferred: NSWindow?) -> NSWindow? {
        if let w = preferred, w.windowController is BrowserWindowController { return w.tabGroup?.selectedWindow ?? w }
        if let w = NSApp.keyWindow, w.windowController is BrowserWindowController { return w }
        return NSApp.orderedWindows.first { $0.windowController is BrowserWindowController && $0.isVisible }
            ?? NSApp.windows.first { $0.windowController is BrowserWindowController }
    }

    private func show(_ text: String, symbol: String?, spinning: Bool, window: NSWindow?, hideAfter: TimeInterval, link: String? = nil) {
        guard let w = browserWindow(window), let host = w.contentView else { return }
        let v: NoticeView
        if let existing = view, existing.window === w { v = existing } else {
            view?.removeFromSuperview()
            v = NoticeView()
            v.onClick = { [weak w] in (w?.windowController as? BrowserWindowController)?.showTransfers(nil) }
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                v.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -60),
                v.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40),
            ])
            view = v
            v.alphaValue = 0
        }
        v.set(text, symbol: symbol, spinning: spinning, link: link)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; v.animator().alphaValue = 1 }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { _ in MainActor.assumeIsolated { TransferNotice.shared.hide() } }
        #if DEBUG
        Debug.log("notice: \(text)")
        #endif
    }

    func hide() {
        hideTimer?.invalidate()
        guard let v = view else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; v.animator().alphaValue = 0 }) { MainActor.assumeIsolated { v.removeFromSuperview() } }
        view = nil
    }
}

final class NoticeView: NSVisualEffectView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let linkLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private(set) var spinning = false

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = { let s = NSShadow(); s.shadowBlurRadius = 12; s.shadowOffset = NSSize(width: 0, height: -3); s.shadowColor = .black.withAlphaComponent(0.25); return s }()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        linkLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        linkLabel.textColor = .linkColor
        let stack = NSStackView(views: [spinner, icon, label, linkLabel])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, symbol: String?, spinning: Bool, link: String?) {
        self.spinning = spinning
        label.stringValue = text
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.isHidden = symbol == nil
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        linkLabel.isHidden = link == nil
        linkLabel.stringValue = link ?? ""
        setAccessibilityLabel(text)
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
