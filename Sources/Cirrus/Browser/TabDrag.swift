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
    private var lit = false { didSet { layer?.backgroundColor = (lit ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor.withAlphaComponent(0.5)).cgColor } }

    init(target: NSWindow) {
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        lit = false
        let loc = MainActor.assumeIsolated { (target.windowController as? BrowserWindowController)?.activePane?.location }
        label.stringValue = target.title.isEmpty ? "Tab" : target.title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        let symbol = MainActor.assumeIsolated { loc.map { Catalog.shared.symbolName($0) } } ?? "folder"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        let s = NSStackView(views: [icon, label])
        s.spacing = 5
        s.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 10)
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     widthAnchor.constraint(lessThanOrEqualToConstant: 220)])
        registerForDraggedTypes(DragDrop.acceptedTypes)
        toolTip = "Drop here to put the items in “\(label.stringValue)”, or hover to switch to that tab"
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

extension TabDrag {
    private static var bar: NSView?
    private static var barHide: Timer?
    private static var internalDrag = false
    static var ownDragInProgress: Bool { internalDrag }

    /// Show the bar in `window` (if it has other tabs). Internal drags keep it until they end; drags from
    /// other apps keep it alive while they're over the window.
    static func showBar(in window: NSWindow?, ownDrag: Bool) {
        if ownDrag { internalDrag = true }
        guard let window, let group = window.tabGroup, group.windows.count > 1, let host = window.contentView else { return }
        if let b = bar, b.window === window { keepBarAlive(); return }
        bar?.removeFromSuperview()
        let others = group.windows.filter { $0 !== window }
        let title = NSTextField(labelWithString: "Drop on a tab:")
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title] + others.prefix(8).map { TabChip(target: $0) })
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let fx = NSVisualEffectView()
        fx.material = .popover; fx.blendingMode = .withinWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        fx.shadow = { let s = NSShadow(); s.shadowBlurRadius = 10; s.shadowColor = .black.withAlphaComponent(0.2); return s }()
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        fx.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(fx, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            fx.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            fx.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            fx.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40),
        ])
        bar = fx
        #if DEBUG
        Debug.log("tab bar shown with \(others.count) tab(s)")
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

    static func hideBar() {
        internalDrag = false
        barHide?.invalidate()
        bar?.removeFromSuperview()
        bar = nil
    }
}
