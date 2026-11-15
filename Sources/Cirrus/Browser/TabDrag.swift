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
