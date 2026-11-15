import AppKit
import CirrusCore

/// Window tabs as drag targets, like Finder: hovering a drag over another tab switches to it, and releasing
/// it on a tab copies or moves the items into that tab's folder (same rules as any other drop).
@MainActor
enum TabDrag {
    private static var poll: Timer?
    private static var hoverWindow: NSWindow?
    private static var hoverSince = Date.distantFuture
    private static weak var sourceWindow: NSWindow?

    /// The tab buttons of `window`'s tab group, left to right, with the window each one shows (screen coordinates).
    static func tabs(of window: NSWindow) -> [(rect: NSRect, window: NSWindow)] {
        guard let group = window.tabGroup, group.windows.count > 1, group.isTabBarVisible else { return [] }
        let windows = group.windows
        // The tab bar lives in the window's frame view; find its buttons by class name and frame (no private calls).
        var buttons = [NSView]()
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("TabButton") { buttons.append(v); return }
            for s in v.subviews { walk(s) }
        }
        let host = group.selectedWindow ?? window
        if let frameView = host.contentView?.superview { walk(frameView) }
        let rects = buttons.filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .map { $0.window!.convertToScreen($0.convert($0.bounds, to: nil)) }
            .sorted { $0.minX < $1.minX }
        if rects.count == windows.count { return Array(zip(rects, windows)).map { (rect: $0.0, window: $0.1) } }
        // Fallback: equal-width tabs in the strip right above the content area.
        let layout = host.contentLayoutRect
        let bar = host.convertToScreen(NSRect(x: 0, y: layout.maxY, width: host.frame.width, height: 30))
        let w = bar.width / CGFloat(windows.count)
        return windows.enumerated().map { (rect: NSRect(x: bar.minX + CGFloat($0.offset) * w, y: bar.minY, width: w, height: bar.height), window: $0.element) }
    }

    static func tab(at screenPoint: NSPoint, near window: NSWindow) -> NSWindow? {
        tabs(of: window).first { $0.rect.contains(screenPoint) }?.window
    }

    /// A drag of Cirrus items started in `window`: watch the pointer for tab hovers (the drag runs its own event
    /// loop, so the timer is added in common modes).
    static func began(in window: NSWindow?) {
        sourceWindow = window
        showBar(in: window, ownDrag: true)
        poll?.invalidate()
        guard let window, (window.tabGroup?.windows.count ?? 0) > 1 else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { _ in MainActor.assumeIsolated { hover(at: NSEvent.mouseLocation, near: window) } }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    static func hover(at p: NSPoint, near window: NSWindow) {
        guard let target = tab(at: p, near: window), target !== window.tabGroup?.selectedWindow else {
            hoverWindow = nil; hoverSince = .distantFuture; return
        }
        if target !== hoverWindow { hoverWindow = target; hoverSince = Date(); return }
        let delay = UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        let enabled = UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
        if enabled, Date().timeIntervalSince(hoverSince) >= max(0.3, delay + 0.2) {
            window.tabGroup?.selectedWindow = target
            hoverWindow = nil; hoverSince = .distantFuture
        }
    }

    /// The drag ended. If nothing took it and it was released on a tab, deliver the items to that tab's folder.
    static func ended(_ session: NSDraggingSession, at p: NSPoint, operation: NSDragOperation) {
        poll?.invalidate(); poll = nil
        hideBar()
        hoverWindow = nil; hoverSince = .distantFuture
        guard operation.isEmpty, let window = sourceWindow, let target = tab(at: p, near: window),
              let (items, source) = DragRegistry.shared.items(from: session.draggingPasteboard) else { return }
        drop(items, from: source, onto: target)
    }

    @discardableResult
    static func drop(_ items: [Item], from source: Location?, onto tabWindow: NSWindow) -> Bool {
        guard let pane = (tabWindow.windowController as? BrowserWindowController)?.activePane else { return false }
        let loc = pane.location
        let op = DragDrop.operation(items: items, source: source, to: loc)
        guard !op.isEmpty else { NSSound.beep(); return false }
        tabWindow.tabGroup?.selectedWindow = tabWindow
        Task {
            guard let dest = await Ops.shared.destination(for: loc) else { return }
            await Ops.shared.transfer(items, to: dest, move: op == .move, window: tabWindow)
        }
        return true
    }
}

// MARK: - "Drop on a tab" bar

/// Real drop targets for the other tabs, shown under the toolbar while something is dragged in a window
/// with several tabs. Hovering one switches to that tab (spring-loading); releasing on it delivers there.
final class TabChip: NSView {
    weak var target: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var spring: Timer?
    private var lit = false { didSet { paint() } }
    private func paint() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(lit ? 1 : 0.88).cgColor
        layer?.borderWidth = lit ? 2 : 0
    }

    init(target: NSWindow) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        shadow = { let sh = NSShadow(); sh.shadowBlurRadius = 8; sh.shadowOffset = NSSize(width: 0, height: -2); sh.shadowColor = .black.withAlphaComponent(0.3); return sh }()
        paint()   // (property observers don't run during init)
        let loc = MainActor.assumeIsolated { (target.windowController as? BrowserWindowController)?.activePane?.location }
        label.stringValue = target.title.isEmpty ? "This tab" : target.title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        _ = loc
        let symbol = "tray.and.arrow.down.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .white
        let s = NSStackView(views: [icon, label])
        s.spacing = 5
        s.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     widthAnchor.constraint(lessThanOrEqualToConstant: 240)])
        registerForDraggedTypes(DragDrop.acceptedTypes)
        toolTip = "Drop here to put the items in that tab’s folder, or hover to switch to it"
    }
    required init?(coder: NSCoder) { fatalError() }

    private var location: Location? { MainActor.assumeIsolated { (target?.windowController as? BrowserWindowController)?.activePane?.location } }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { TabDrag.keepBarAlive() }
        guard let loc = location else { return [] }
        return MainActor.assumeIsolated { DragDrop.operation(info, to: loc) }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        lit = true
        spring?.invalidate()
        let delay = UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        spring = Timer.scheduledTimer(withTimeInterval: max(0.35, delay + 0.25), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let t = self?.target else { return }
                t.tabGroup?.selectedWindow = t
                TabDrag.showBar(in: t, ownDrag: TabDrag.ownDragInProgress)   // the bar follows, so you can hop again
            }
        }
        RunLoop.main.add(spring!, forMode: .common)
        return operation(info)
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { operation(info) }
    override func draggingExited(_ info: NSDraggingInfo?) { lit = false; spring?.invalidate() }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        spring?.invalidate()
        guard let t = target, let loc = location else { return false }
        return MainActor.assumeIsolated {
            t.tabGroup?.selectedWindow = t
            return DragDrop.perform(info, to: loc, window: t)
        }
    }
    override func concludeDragOperation(_ info: NSDraggingInfo?) { lit = false; MainActor.assumeIsolated { TabDrag.hideBar() } }
}

/// The little pointer from a drop zone up to its tab.
final class CalloutArrow: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: bounds.minX, y: bounds.minY)); p.line(to: NSPoint(x: bounds.midX, y: bounds.maxY)); p.line(to: NSPoint(x: bounds.maxX, y: bounds.minY)); p.close()
        color.setFill(); p.fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension TabDrag {
    private static var barViews = [NSView]()
    private static weak var barWindow: NSWindow?
    private static var barHide: Timer?
    private static var internalDrag = false
    static var ownDragInProgress: Bool { internalDrag }

    /// Where each tab sits, in `host` coordinates: tabs share the strip above the browser content (the sidebar
    /// and the “+” button aren't part of it) in equal widths.
    static func tabCenters(in window: NSWindow, host: NSView) -> [CGFloat] {
        guard let group = window.tabGroup else { return [] }
        let n = group.windows.count
        var strip = host.bounds
        if let wc = window.windowController as? BrowserWindowController {
            let v = wc.paneSplit.view
            strip = v.convert(v.bounds, to: host)
        }
        let w = max(60, (strip.width - 28) / CGFloat(n))
        return (0..<n).map { strip.minX + (CGFloat($0) + 0.5) * w }
    }

    /// A drop zone under each other tab while something is dragged in a window with several tabs. Hovering one
    /// switches to that tab; releasing on it delivers there. Own drags keep them until the drag ends; drags from
    /// other apps keep them while they're over the window.
    static func showBar(in window: NSWindow?, ownDrag: Bool) {
        if ownDrag { internalDrag = true }
        guard let window, let group = window.tabGroup, group.windows.count > 1, let host = window.contentView else { return }
        if barWindow === window, !barViews.isEmpty { keepBarAlive(); return }
        removeBarViews()
        let centers = tabCenters(in: window, host: host)
        let n = group.windows.count
        let zoneWidth = min(230, max(110, (centers.count > 1 ? centers[1] - centers[0] : 200) - 18))
        for (i, tab) in group.windows.enumerated() where tab !== window && i < centers.count {
            let chip = TabChip(target: tab)
            let arrow = CalloutArrow()
            arrow.color = NSColor.controlAccentColor.withAlphaComponent(0.85)
            for v in [arrow, chip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(v, positioned: .above, relativeTo: nil) }
            NSLayoutConstraint.activate([
                arrow.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 2),
                arrow.centerXAnchor.constraint(equalTo: host.leadingAnchor, constant: centers[i]),
                arrow.widthAnchor.constraint(equalToConstant: 16), arrow.heightAnchor.constraint(equalToConstant: 8),
                chip.topAnchor.constraint(equalTo: arrow.bottomAnchor),
                chip.centerXAnchor.constraint(equalTo: arrow.centerXAnchor),
                chip.widthAnchor.constraint(equalToConstant: zoneWidth),
            ])
            barViews += [arrow, chip]
        }
        barWindow = window
        #if DEBUG
        Debug.log("tab drop zones shown under \(n - 1) tab(s)")
        #endif
        keepBarAlive()
    }

    static func keepBarAlive() {
        barHide?.invalidate()
        guard !internalDrag else { return }
        let t = Timer(timeInterval: 1.5, repeats: false) { _ in MainActor.assumeIsolated { TabDrag.hideBar() } }
        RunLoop.main.add(t, forMode: .common)
        barHide = t
    }

    private static func removeBarViews() { for v in barViews { v.removeFromSuperview() }; barViews = [] }

    static func hideBar() {
        internalDrag = false
        barHide?.invalidate()
        removeBarViews()
        barWindow = nil
    }
}
