import AppKit
import CirrusCore

/// A Finder tag on a local file. `color` is Finder's label index (0 none, 1 gray, 2 green, 3 purple,
/// 4 blue, 5 yellow, 6 red, 7 orange).
struct FinderTag: Hashable, Sendable {
    var name: String
    var color: Int

    static let standard: [FinderTag] = [
        .init(name: "Red", color: 6), .init(name: "Orange", color: 7), .init(name: "Yellow", color: 5), .init(name: "Green", color: 2),
        .init(name: "Blue", color: 4), .init(name: "Purple", color: 3), .init(name: "Gray", color: 1),
    ]

    var nsColor: NSColor? {
        switch color {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return nil
        }
    }

    /// Finder's own tag attribute: a property list of "Name\nColourIndex" strings (one syscall when absent).
    nonisolated static func read(_ url: URL) -> [FinderTag] {
        let attr = "com.apple.metadata:_kMDItemUserTags"
        let len = getxattr(url.path, attr, nil, 0, 0, XATTR_NOFOLLOW)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let n = data.withUnsafeMutableBytes { getxattr(url.path, attr, $0.baseAddress, len, 0, XATTR_NOFOLLOW) }
        guard n > 0, let list = try? PropertyListSerialization.propertyList(from: data.prefix(n), format: nil) as? [String] else { return [] }
        return list.compactMap { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1)
            guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
            let color = parts.count == 2 ? Int(parts[1]) : nil
            return FinderTag(name: name, color: color ?? standard.first { $0.name == name }?.color ?? 0)
        }
    }

    /// Replace a file's tags. Tags on iCloud files sync, so read-only mode applies.
    static func set(_ names: [String], on url: URL) throws {
        try SafetyPolicy.checkLocalWrite(url)
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }
}

/// Up to three overlapping tag dots, like Finder's.
final class TagDotsView: NSView {
    var colors: [NSColor] = [] { didSet { isHidden = colors.isEmpty; needsDisplay = true; invalidateIntrinsicContentSize() } }
    let dot: CGFloat = 9
    override var intrinsicContentSize: NSSize { NSSize(width: colors.isEmpty ? 0 : dot + CGFloat(min(colors.count, 3) - 1) * 5 + 2, height: dot + 2) }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shown = Array(colors.prefix(3))
        for (i, c) in shown.enumerated() {
            let r = NSRect(x: 1 + CGFloat(i) * 5, y: (bounds.height - dot) / 2, width: dot, height: dot)
            let p = NSBezierPath(ovalIn: r)
            c.setFill(); p.fill()
            NSColor.windowBackgroundColor.setStroke(); p.lineWidth = 1.2; p.stroke()
        }
    }
}
