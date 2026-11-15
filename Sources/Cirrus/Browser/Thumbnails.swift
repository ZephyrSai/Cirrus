import AppKit
import CirrusCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor AsyncLimiter {
    let limit: Int
    var running = 0
    var waiters = [CheckedContinuation<Void, Never>]()
    init(_ limit: Int) { self.limit = limit }
    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() } else { running -= 1 }
    }
}

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    let cache = NSCache<NSString, NSImage>()
    let iconCache = NSCache<NSString, NSImage>()
    var tasks = [String: Task<NSImage?, Never>]()
    let remoteLimiter = AsyncLimiter(12)
    let previewLimiter = AsyncLimiter(3)
    static let drivePreviewMax: Int64 = 25_000_000
    static var drivePreviews: Bool { UserDefaults.standard.object(forKey: "drivePreviews") as? Bool ?? true }
    let localLimiter = AsyncLimiter(4)

    init() { cache.countLimit = 3000; iconCache.countLimit = 600 }

    func symbol(_ name: String, size: CGFloat, color: NSColor = .controlAccentColor) -> NSImage {
        let key = "sym:\(name):\(Int(size)):\(color.hashValue)" as NSString
        if let i = iconCache.object(forKey: key) { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .regular).applying(.init(paletteColors: [color]))
        let img = (NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)!)
            .withSymbolConfiguration(cfg) ?? NSImage()
        iconCache.setObject(img, forKey: key)
        return img
    }

    func typeIcon(_ t: UTType?) -> NSImage {
        let key = "type:" + (t?.identifier ?? "data") as NSString
        if let i = iconCache.object(forKey: key) { return i }
        let i = NSWorkspace.shared.icon(for: t ?? .data)
        iconCache.setObject(i, forKey: key)
        return i
    }

    /// Immediate image: a cached thumbnail if we have one, else the type/symbol icon.
    func image(for item: Item, px: Int) -> NSImage {
        if let c = cache.object(forKey: thumbKey(item, px: px) as NSString) { return c }
        return placeholder(item, size: CGFloat(px))
    }

    func placeholder(_ item: Item, size: CGFloat) -> NSImage {
        switch item.payload {
        case .album(let a):
            if a.kind == .folder { return typeIcon(.folder) }
            return symbol(a.symbol, size: size, color: a.kind == .smart ? .systemBlue : .systemOrange)
        case .camera, .volume:
            if let v = item.volume { return NSWorkspace.shared.icon(forFile: v.url.path) }
            return symbol(item.symbol ?? "camera", size: size, color: .secondaryLabelColor)
        case .file(let u):
            if let s = item.symbol { return symbol(s, size: size, color: .systemBlue) }
            if item.cloud == .cloudOnly && !FileManager.default.fileExists(atPath: u.path) { return item.isContainer ? typeIcon(.folder) : typeIcon(item.utType) }
            let key = "file:" + u.path as NSString
            if let i = iconCache.object(forKey: key) { return i }
            let i = NSWorkspace.shared.icon(forFile: u.path)
            iconCache.setObject(i, forKey: key)
            return i
        case .drive(let n):
            if n.isAppLibrary { return symbol("app.badge", size: size, color: .systemBlue) }
            return n.isFolder ? typeIcon(.folder) : typeIcon(item.utType)
        case .photo(let p):
            return p.isVideo ? typeIcon(.movie) : typeIcon(.image)
        case .device(let d):
            return d.isFolder ? typeIcon(.folder) : typeIcon(item.utType)
        }
    }

    func thumbKey(_ item: Item, px: Int) -> String { item.key + "@" + String(px <= 256 ? 256 : 1024) + (item.modified.map { "-\(Int($0.timeIntervalSince1970))" } ?? "") }

    func wantsThumbnail(_ item: Item) -> Bool {
        switch item.payload {
        case .photo: return true
        case .device(let d): return !d.isFolder
        case .drive(let n):
            // iCloud.com's API has no thumbnails: fetch small previewable files once and thumbnail them locally.
            guard Self.drivePreviews, !n.isFolder, n.size > 0, n.size <= Self.drivePreviewMax, let t = item.utType else { return false }
            return t.conforms(to: .image) || t.conforms(to: .pdf) || t.conforms(to: .movie) || t.conforms(to: .presentation)
                || t.conforms(to: .spreadsheet) || t.identifier.contains("iwork") || t.conforms(to: .rtf) || t.identifier == "com.microsoft.word.doc"
                || t.identifier == "org.openxmlformats.wordprocessingml.document"
        case .file:
            guard !item.isContainer, item.cloud != .cloudOnly, let t = item.utType else { return false }
            return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .pdf) || t.conforms(to: .presentation)
                || t.conforms(to: .spreadsheet) || t.identifier.contains("iwork") || t.conforms(to: .font) || t.conforms(to: .rtf)
        default: return false
        }
    }

    func load(_ item: Item, px: Int) async -> NSImage? {
        guard wantsThumbnail(item) else { return nil }
        let key = thumbKey(item, px: px)
        if let c = cache.object(forKey: key as NSString) { return c }
        if let t = tasks[key] { return await t.value }
        let backend: PhotosBackend? = item.account.flatMap { AccountManager.shared.account(id: $0)?.photos }
        let target = px <= 256 ? 256 : 1024
        let limiterRemote = remoteLimiter, limiterLocal = localLimiter, previewLimit = previewLimiter
        let task = Task<NSImage?, Never> {
            switch item.payload {
            case .photo(let p):
                guard let backend else { return nil }
                await limiterRemote.acquire()
                defer { Task { await limiterRemote.release() } }
                guard let cg = try? await backend.thumbnail(p, maxPixel: target) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            case .device(let d):
                guard let cg = await DeviceManager.shared.thumbnail(d) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            case .drive:
                await previewLimit.acquire()
                defer { Task { await previewLimit.release() } }
                guard let u = try? await Ops.shared.localCopy(item, cache: "Open", progressTitle: nil) else { return nil }
                let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: target / 2, height: target / 2), scale: 2, representationTypes: .thumbnail)
                guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
                return rep.nsImage
            case .file(let u):
                await limiterLocal.acquire()
                defer { Task { await limiterLocal.release() } }
                let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: target / 2, height: target / 2), scale: 2, representationTypes: .thumbnail)
                guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
                return rep.nsImage
            default: return nil
            }
        }
        tasks[key] = task
        let img = await task.value
        tasks[key] = nil
        if let img { cache.setObject(img, forKey: key as NSString) }
        return img
    }
}
