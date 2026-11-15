// Renders Resources/AppIcon.icns: sky gradient squircle, white cloud, folder + photo badges.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cirrus.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.white.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.70, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.10, green: 0.38, blue: 0.92, alpha: 1)])!.draw(in: rect, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular).applying(.init(paletteColors: [.white]))
    if let cloud = NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = cloud.size
        cloud.draw(in: NSRect(x: (s - sz.width) / 2, y: s * 0.40, width: sz.width, height: sz.height))
    }
    let badge = NSImage.SymbolConfiguration(pointSize: s * 0.15, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.10, green: 0.38, blue: 0.92, alpha: 1)]))
    for (name, x) in [("folder.fill", 0.27), ("photo.fill", 0.52)] {
        let r = NSRect(x: s * x, y: s * 0.20, width: s * 0.21, height: s * 0.17)
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: s * 0.04, yRadius: s * 0.04).fill()
        if let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(badge) {
            i.draw(in: NSRect(x: r.midX - i.size.width / 2, y: r.midY - i.size.height / 2, width: i.size.width, height: i.size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out + "/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: out + "/AppIcon-1024.png"))
print("wrote \(out)/AppIcon.icns")
