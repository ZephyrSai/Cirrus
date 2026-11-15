// Renders Resources/AppIcon.icns (+ AppIcon-1024.png): glossy sky squircle, shaded 3D cloud,
// a tilted photo print and a folder tucked in front, soft shadows and a glass rim.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cirrus.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

func cloudPath(in r: NSRect) -> NSBezierPath {
    // Built from overlapping circles + a rounded base, unioned by filling (non-zero winding).
    let p = NSBezierPath()
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    p.append(NSBezierPath(roundedRect: NSRect(x: x + w * 0.04, y: y, width: w * 0.92, height: h * 0.46), xRadius: h * 0.23, yRadius: h * 0.23))
    p.append(NSBezierPath(ovalIn: NSRect(x: x + w * 0.06, y: y + h * 0.10, width: w * 0.40, height: h * 0.56)))
    p.append(NSBezierPath(ovalIn: NSRect(x: x + w * 0.26, y: y + h * 0.20, width: w * 0.52, height: h * 0.80)))
    p.append(NSBezierPath(ovalIn: NSRect(x: x + w * 0.58, y: y + h * 0.08, width: w * 0.38, height: h * 0.50)))
    p.windingRule = .nonZero
    return p
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, color: NSColor = .black) -> NSShadow {
    let s = NSShadow()
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: -dy)
    s.shadowColor = color.withAlphaComponent(alpha)
    return s
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high
    let ctx = gctx.cgContext

    // Tile
    let inset = s * 0.085
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    shadow(s * 0.028, s * 0.014, 0.38).set()
    rgb(20, 80, 200).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [rgb(118, 214, 255), rgb(46, 140, 255), rgb(24, 70, 214), rgb(40, 40, 150)],
               atLocations: [0, 0.38, 0.78, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
    // Sunlit glow top-left, deep glow bottom-right
    NSGradient(colors: [rgb(255, 255, 255, 0.35), rgb(255, 255, 255, 0)])!
        .draw(fromCenter: NSPoint(x: tile.minX + tile.width * 0.22, y: tile.maxY - tile.height * 0.14), radius: 0,
              toCenter: NSPoint(x: tile.minX + tile.width * 0.22, y: tile.maxY - tile.height * 0.14), radius: tile.width * 0.62, options: [])
    NSGradient(colors: [rgb(140, 90, 255, 0.45), rgb(140, 90, 255, 0)])!
        .draw(fromCenter: NSPoint(x: tile.maxX, y: tile.minY), radius: 0, toCenter: NSPoint(x: tile.maxX, y: tile.minY), radius: tile.width * 0.7, options: [])
    // Orbit ring behind the cloud
    ctx.saveGState()
    let ringRect = NSRect(x: tile.minX + tile.width * 0.08, y: tile.minY + tile.height * 0.30, width: tile.width * 0.84, height: tile.height * 0.40)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = s * 0.012
    rgb(255, 255, 255, 0.22).setStroke()
    ring.stroke()
    ctx.restoreGState()

    // Cloud with soft depth
    let cloudRect = NSRect(x: tile.minX + tile.width * 0.13, y: tile.minY + tile.height * 0.40, width: tile.width * 0.74, height: tile.height * 0.40)
    let cloud = cloudPath(in: cloudRect)
    NSGraphicsContext.saveGraphicsState()
    shadow(s * 0.045, s * 0.03, 0.35, color: rgb(10, 30, 110)).set()
    rgb(255, 255, 255).setFill()
    cloud.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    cloud.addClip()
    NSGradient(colors: [rgb(255, 255, 255), rgb(236, 244, 255), rgb(196, 218, 252)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: cloudRect, angle: -90)
    // Inner shading toward the bottom, highlight on top lobes
    NSGradient(colors: [rgb(120, 160, 230, 0.0), rgb(120, 160, 230, 0.35)])!.draw(in: NSRect(x: cloudRect.minX, y: cloudRect.minY, width: cloudRect.width, height: cloudRect.height * 0.35), angle: -90)
    NSGradient(colors: [rgb(255, 255, 255, 0.9), rgb(255, 255, 255, 0)])!
        .draw(fromCenter: NSPoint(x: cloudRect.midX - cloudRect.width * 0.08, y: cloudRect.maxY - cloudRect.height * 0.18), radius: 0,
              toCenter: NSPoint(x: cloudRect.midX - cloudRect.width * 0.08, y: cloudRect.maxY - cloudRect.height * 0.18), radius: cloudRect.width * 0.35, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Photo print (tilted left) — warm sunset scene
    func card(center: NSPoint, size: NSSize, angle: CGFloat, draw: (NSRect) -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        let r = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        draw(r)
        ctx.restoreGState()
    }
    let cardW = tile.width * 0.33, cardH = tile.width * 0.27
    card(center: NSPoint(x: tile.minX + tile.width * 0.36, y: tile.minY + tile.height * 0.30), size: NSSize(width: cardW, height: cardH), angle: 8) { r in
        let frame = NSBezierPath(roundedRect: r, xRadius: s * 0.022, yRadius: s * 0.022)
        NSGraphicsContext.saveGraphicsState()
        shadow(s * 0.03, s * 0.016, 0.42).set()
        rgb(255, 255, 255).setFill(); frame.fill()
        NSGraphicsContext.restoreGraphicsState()
        let pic = r.insetBy(dx: r.width * 0.07, dy: r.height * 0.08)
        let picPath = NSBezierPath(roundedRect: pic, xRadius: s * 0.012, yRadius: s * 0.012)
        NSGraphicsContext.saveGraphicsState()
        picPath.addClip()
        NSGradient(colors: [rgb(255, 214, 120), rgb(255, 128, 92), rgb(214, 66, 120)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: pic, angle: -90)
        rgb(255, 246, 200).setFill()
        NSBezierPath(ovalIn: NSRect(x: pic.minX + pic.width * 0.62, y: pic.minY + pic.height * 0.52, width: pic.width * 0.2, height: pic.width * 0.2)).fill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: pic.minX, y: pic.minY))
        hills.line(to: NSPoint(x: pic.minX, y: pic.minY + pic.height * 0.35))
        hills.curve(to: NSPoint(x: pic.minX + pic.width * 0.45, y: pic.minY + pic.height * 0.42),
                    controlPoint1: NSPoint(x: pic.minX + pic.width * 0.15, y: pic.minY + pic.height * 0.62),
                    controlPoint2: NSPoint(x: pic.minX + pic.width * 0.30, y: pic.minY + pic.height * 0.62))
        hills.curve(to: NSPoint(x: pic.maxX, y: pic.minY + pic.height * 0.30),
                    controlPoint1: NSPoint(x: pic.minX + pic.width * 0.62, y: pic.minY + pic.height * 0.24),
                    controlPoint2: NSPoint(x: pic.minX + pic.width * 0.80, y: pic.minY + pic.height * 0.52))
        hills.line(to: NSPoint(x: pic.maxX, y: pic.minY)); hills.close()
        rgb(92, 40, 120, 0.85).setFill(); hills.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // Folder (tilted right), in front
    card(center: NSPoint(x: tile.minX + tile.width * 0.64, y: tile.minY + tile.height * 0.27), size: NSSize(width: cardW * 1.05, height: cardH * 0.92), angle: -7) { r in
        let tabW = r.width * 0.42, tabH = r.height * 0.16
        let back = NSBezierPath()
        back.move(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.1))
        back.line(to: NSPoint(x: r.minX, y: r.maxY + tabH * 0.2))
        back.line(to: NSPoint(x: r.minX + tabW * 0.85, y: r.maxY + tabH * 0.2))
        back.line(to: NSPoint(x: r.minX + tabW, y: r.maxY - tabH * 0.4))
        back.line(to: NSPoint(x: r.maxX, y: r.maxY - tabH * 0.4))
        back.line(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        back.close()
        NSGraphicsContext.saveGraphicsState()
        shadow(s * 0.03, s * 0.016, 0.42).set()
        rgb(44, 110, 230).setFill(); back.fill()
        NSGraphicsContext.restoreGraphicsState()
        let front = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.82), xRadius: s * 0.02, yRadius: s * 0.02)
        NSGraphicsContext.saveGraphicsState()
        front.addClip()
        NSGradient(colors: [rgb(128, 200, 255), rgb(64, 150, 250)])!.draw(in: front.bounds, angle: -90)
        rgb(255, 255, 255, 0.35).setFill()
        NSRect(x: r.minX, y: r.minY + r.height * 0.78, width: r.width, height: s * 0.004).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Glass rim + top sheen
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: radius, yRadius: radius)
    rim.lineWidth = s * 0.008
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    // Soft top sheen that fades to nothing (no hard edge)
    NSGradient(colors: [rgb(255, 255, 255, 0.38), rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: tile.minX, y: tile.maxY - tile.height * 0.55, width: tile.width, height: tile.height * 0.55), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    rgb(255, 255, 255, 0.35).setStroke()
    rim.stroke()

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
try! render(64).write(to: URL(fileURLWithPath: out + "/AppIcon-64.png"))
print("wrote \(out)/AppIcon.icns")
