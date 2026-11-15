import AppKit
import CoreGraphics
import Foundation

// Demo iCloud (CIRRUS_DEMO=1): a disk-backed fake Drive + Photos library so the UI, drag and drop,
// transfers, sync and backup can be exercised without an Apple ID. Never touches real accounts.

enum DemoArt {
    static func jpeg(width: Int, height: Int, hue: CGFloat, label: String) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c1 = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let c2 = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55, alpha: 1).cgColor
        if let g = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
        for i in 0..<5 {
            let r = CGFloat(height) * (0.15 + 0.08 * CGFloat(i))
            ctx.fillEllipse(in: CGRect(x: CGFloat(width) * (0.15 * CGFloat(i)), y: CGFloat(height) * 0.2, width: r, height: r))
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        // Centered so square thumbnails (center crop) never clip the caption.
        let shadow = NSShadow(); shadow.shadowBlurRadius = CGFloat(height) / 60; shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(min(width, height)) / 10, weight: .bold),
                                                    .foregroundColor: NSColor.white, .shadow: shadow]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        text.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2, y: CGFloat(height) * 0.40 - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

public final class DemoDrive: DriveBackend, @unchecked Sendable {
    public static let shared = DemoDrive()
    public let rootID = "FOLDER::demo::"
    let root: URL
    let trashDir: URL
    let delay: UInt64

    init() {
        root = Paths.cacheDir("demo").appendingPathComponent("drive", isDirectory: true)
        trashDir = Paths.cacheDir("demo").appendingPathComponent("drive-trash", isDirectory: true)
        delay = ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] != nil ? 0 : 120_000_000
        seed()
    }

    func seed() {
        let fm = FileManager.default
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: root.path) else { return }
        let files: [(String, String)] = [
            ("Documents/Budget 2026.csv", "Month,Income,Spend\nJan,4200,3100\nFeb,4200,2950\n"),
            ("Documents/Notes/Ideas.txt", "Cirrus demo notes.\n"),
            ("Documents/Notes/Trip checklist.md", "# Trip\n- Passport\n- Charger\n"),
            ("Projects/Cirrus/README.md", "# Cirrus\nA Finder for iCloud.\n"),
            ("Projects/Cirrus/roadmap.txt", "v1: browse, transfer, sync, backup\n"),
            ("Desktop/todo.txt", "Back up photos\n"),
            ("Recipe.txt", "Pancakes: flour, milk, eggs.\n"),
        ]
        for (p, s) in files {
            let u = root.appendingPathComponent(p)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(s.utf8).write(to: u)
        }
        for i in 0..<6 {
            let u = root.appendingPathComponent("Pictures/Wallpaper \(i + 1).jpg")
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? DemoArt.jpeg(width: 1600, height: 1000, hue: CGFloat(i) / 6, label: "Wallpaper \(i + 1)")?.write(to: u)
        }
        let big = root.appendingPathComponent("Archives/Big download.bin")
        try? fm.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: 24 << 20).write(to: big)
    }

    func rel(_ id: String) -> String { id.components(separatedBy: "::").dropFirst(2).joined(separator: "::") }
    func url(_ id: String) -> URL { rel(id).isEmpty ? root : root.appendingPathComponent(rel(id)) }

    func node(_ u: URL, base: URL? = nil) -> DriveNode {
        let base = base ?? root
        let r = String(u.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let dir = v?.isDirectory ?? false
        let parentRel = (r as NSString).deletingLastPathComponent
        let mtime = v?.contentModificationDate ?? Date()
        return DriveNode(id: (dir ? "FOLDER" : "FILE") + "::demo::" + r, docID: r, zone: "demo", parentID: "FOLDER::demo::" + parentRel,
                         name: u.lastPathComponent, type: dir ? "FOLDER" : "FILE", size: Int64(v?.fileSize ?? 0),
                         modified: mtime, created: v?.creationDate, etag: String(Int(mtime.timeIntervalSince1970)),
                         childCount: dir ? (try? FileManager.default.contentsOfDirectory(atPath: u.path).filter { !$0.hasPrefix(".") }.count) : nil)
    }

    func pause() async { if delay > 0 { try? await Task.sleep(nanoseconds: delay) } }

    public func list(_ folderID: String) async throws -> [DriveNode] {
        await pause()
        let u = url(folderID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { throw ICloudError.notFound }
        return names.filter { !$0.hasPrefix(".") }.map { node(u.appendingPathComponent($0)) }
    }

    public func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        var out = [String: [DriveNode]]()
        for f in folderIDs { out[f] = try await list(f) }
        return out
    }

    public func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let src = url(node.id)
        let total = node.size
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if delay > 0 && total > 1 << 20 {
            let steps = 12
            for s in 1...steps { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 90_000_000); progress(total * Int64(s) / Int64(steps), total) }
        }
        try FileManager.default.copyItem(at: src, to: destination)
        progress(total, total)
        if let m = node.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: destination.path) }
    }

    public func upload(_ file: URL, name: String, into folderID: String, modified: Date?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        await pause()
        let dest = url(folderID).appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if delay > 0 && size > 1 << 20 {
            for s in 1...10 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 80_000_000); progress(size * Int64(s) / 10, size) }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: file, to: dest)
        if let m = modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: dest.path) }
        progress(size, size)
        return node(dest)
    }

    public func createFolder(_ name: String, in folderID: String) async throws -> DriveNode {
        await pause()
        let u = url(folderID).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        return node(u)
    }

    public func rename(_ n: DriveNode, to name: String) async throws -> DriveNode {
        await pause()
        let src = url(n.id)
        let dst = src.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: src, to: dst)
        return node(dst)
    }

    public func move(_ nodes: [DriveNode], to folderID: String) async throws {
        await pause()
        for n in nodes {
            let src = url(n.id)
            try FileManager.default.moveItem(at: src, to: url(folderID).appendingPathComponent(src.lastPathComponent))
        }
    }

    public func trash(_ nodes: [DriveNode]) async throws {
        await pause()
        for n in nodes {
            let src = url(n.id)
            var dst = trashDir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) { dst = trashDir.appendingPathComponent(UUID().uuidString.prefix(6) + " " + src.lastPathComponent) }
            try FileManager.default.moveItem(at: src, to: dst)
            try? Data(rel(n.id).utf8).write(to: trashDir.appendingPathComponent("." + dst.lastPathComponent + ".origin"))
        }
    }

    public func listTrash() async throws -> [DriveNode] {
        await pause()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trashDir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { n in
            var d = node(trashDir.appendingPathComponent(n), base: trashDir)
            d.id = "TRASH::demo::" + n
            return d
        }
    }

    public func restore(_ nodes: [DriveNode]) async throws {
        for n in nodes {
            let name = rel(n.id)
            let src = trashDir.appendingPathComponent(name)
            let originFile = trashDir.appendingPathComponent("." + name + ".origin")
            let origin = (try? String(contentsOf: originFile, encoding: .utf8)) ?? name
            let dst = root.appendingPathComponent(origin)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: dst)
            try? FileManager.default.removeItem(at: originFile)
        }
    }

    public func deleteForever(_ nodes: [DriveNode]) async throws {
        for n in nodes {
            let name = rel(n.id)
            try? FileManager.default.removeItem(at: trashDir.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: trashDir.appendingPathComponent("." + name + ".origin"))
        }
    }
}

public final class DemoPhotos: PhotosBackend, @unchecked Sendable {
    public static let shared = DemoPhotos()
    public let cacheKey = "demo"
    public var capabilities: PhotoCapabilities { [.favorite, .hide, .delete, .restore, .importFiles, .albums, .createAlbum] }

    struct Store: Codable {
        var assets: [PhotoAsset]
        var albums: [PhotoAlbum]
        var membership: [String: [String]]   // album id → asset ids
    }

    let dir: URL
    let lock = NSLock()
    var store: Store

    static let artVersion = 2

    init() {
        dir = Paths.cacheDir("demo").appendingPathComponent("photos", isDirectory: true)
        let marker = dir.appendingPathComponent("art-v\(Self.artVersion)")
        if !FileManager.default.fileExists(atPath: marker.path) { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let file = dir.appendingPathComponent("store.json")
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Store.self, from: d) { store = s; return }
        store = Store(assets: [], albums: [], membership: [:])
        seed()
    }

    func save() {
        if let d = try? JSONEncoder().encode(store) { try? d.write(to: dir.appendingPathComponent("store.json"), options: .atomic) }
    }

    func seed() {
        let count = Int(ProcessInfo.processInfo.environment["CIRRUS_DEMO_PHOTOS"] ?? "") ?? 96
        let names = ["Beach", "Hike", "City", "Dinner", "Sunset", "Garden", "Snow", "Lake", "Market", "Concert", "Bridge", "Cafe"]
        var assets = [PhotoAsset]()
        let now = Date()
        for i in 0..<count {
            let id = String(format: "DEMO-%04d", i)
            let fname = String(format: "IMG_%04d.JPG", 1000 + i)
            let w = i % 7 == 0 ? 900 : 1200, h = i % 7 == 0 ? 1200 : 900
            let label = names[i % names.count] + " \(i + 1)"
            guard let data = DemoArt.jpeg(width: w, height: h, hue: CGFloat((i * 37) % 100) / 100, label: label) else { continue }
            let f = dir.appendingPathComponent(id + ".jpg")
            try? data.write(to: f)
            let created = now.addingTimeInterval(-Double(i) * 86400 * 9.5 - Double((i * 7919) % 86400))
            var res = [PhotoResource(kind: .original, filename: fname, size: Int64(data.count), key: "file", recordName: id, url: nil, uti: "public.jpeg")]
            if i % 9 == 4 {
                let mov = dir.appendingPathComponent(id + ".mov")
                try? Data(count: 180_000).write(to: mov)
                res.append(PhotoResource(kind: .liveVideo, filename: (fname as NSString).deletingPathExtension + ".MOV", size: 180_000, key: "mov", recordName: id, url: nil, uti: "com.apple.quicktime-movie"))
            }
            assets.append(PhotoAsset(id: id, masterID: id, changeTag: "1", library: "demo", filename: fname, size: Int64(data.count), created: created,
                                     added: created, width: w, height: h, duration: nil, isVideo: false, isLive: i % 9 == 4,
                                     isFavorite: i % 11 == 0, isHidden: i == 5, isDeleted: false, isEdited: false, uti: "public.jpeg", resources: res))
        }
        store.assets = assets
        store.albums = [
            PhotoAlbum(id: "folder:trips", name: "Trips", kind: .folder, symbol: "folder"),
            PhotoAlbum(id: "album:travel", name: "Travel", kind: .album, parentID: "folder:trips"),
            PhotoAlbum(id: "album:family", name: "Family", kind: .album),
            PhotoAlbum(id: "album:food", name: "Food", kind: .album),
        ]
        store.membership = [
            "album:travel": assets.enumerated().filter { $0.offset % 4 == 0 }.map(\.element.id),
            "album:family": assets.enumerated().filter { $0.offset % 5 == 1 }.map(\.element.id),
            "album:food": assets.enumerated().filter { $0.offset % 12 == 3 }.map(\.element.id),
        ]
        save()
    }

    public func libraries() async throws -> [PhotoLibraryRef] { [PhotoLibraryRef(id: "demo", name: "Personal Library", isShared: false)] }

    func members(_ album: PhotoAlbum) -> [PhotoAsset] {
        lock.lock(); defer { lock.unlock() }
        let live = store.assets.filter { !$0.isDeleted }
        switch album.id {
        case "smart:All Photos": return live.filter { !$0.isHidden }
        case "smart:Favorites": return live.filter { $0.isFavorite && !$0.isHidden }
        case "smart:Live": return live.filter { $0.isLive && !$0.isHidden }
        case "smart:Hidden": return live.filter { $0.isHidden }
        case "smart:Recently Deleted": return store.assets.filter { $0.isDeleted }
        default:
            let ids = Set(store.membership[album.id] ?? [])
            return live.filter { ids.contains($0.id) }
        }
    }

    public func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] {
        var out = [
            PhotoAlbum(id: "smart:All Photos", name: "All Photos", kind: .smart, symbol: "photo.on.rectangle"),
            PhotoAlbum(id: "smart:Favorites", name: "Favorites", kind: .smart, symbol: "heart"),
            PhotoAlbum(id: "smart:Live", name: "Live Photos", kind: .smart, symbol: "livephoto"),
            PhotoAlbum(id: "smart:Hidden", name: "Hidden", kind: .smart, symbol: "eye.slash"),
            PhotoAlbum(id: "smart:Recently Deleted", name: "Recently Deleted", kind: .smart, symbol: "trash"),
        ]
        out += lock.withLock { store.albums }
        for i in out.indices where out[i].kind != .folder { out[i].count = members(out[i]).count }
        return out
    }

    public func assets(in album: PhotoAlbum, library: PhotoLibraryRef, page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        let all = members(album)
        for chunk in all.chunked(40) {
            if ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] == nil { try await Task.sleep(nanoseconds: 60_000_000) }
            page(chunk, all.count)
        }
        return all
    }

    func file(_ asset: PhotoAsset, _ kind: PhotoResource.Kind) -> URL {
        let base = asset.masterID ?? asset.id
        if kind == .liveVideo { return dir.appendingPathComponent(base + ".mov") }
        let ext = (asset.resource(.original)?.filename as NSString?)?.pathExtension.lowercased() ?? "jpg"
        let f = dir.appendingPathComponent(base + "." + ext)
        return FileManager.default.fileExists(atPath: f.path) ? f : dir.appendingPathComponent(base + ".jpg")
    }

    public func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? {
        guard let d = try? Data(contentsOf: file(asset, .original)) else { return nil }
        return PhotoFormats.cgImage(from: d, maxPixel: maxPixel)
    }

    public func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard asset.resource(resource) != nil else { throw ICloudError.notFound }
        if ProcessInfo.processInfo.environment["CIRRUS_DEMO_FAST"] == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file(asset, resource), to: destination)
        if let d = asset.created { try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: destination.path) }
        let s = asset.resource(resource)?.size ?? 0
        progress(s, s)
    }

    func mutate(_ assets: [PhotoAsset], _ f: (inout PhotoAsset) -> Void) -> [PhotoAsset] {
        lock.lock(); defer { lock.unlock(); save() }
        let ids = Set(assets.map(\.id))
        for i in store.assets.indices where ids.contains(store.assets[i].id) { f(&store.assets[i]) }
        return store.assets.filter { ids.contains($0.id) }
    }

    public func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { mutate(assets) { $0.isFavorite = value } }
    public func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { mutate(assets) { $0.isHidden = value } }
    public func delete(_ assets: [PhotoAsset]) async throws { _ = mutate(assets) { $0.isDeleted = true } }
    public func restore(_ assets: [PhotoAsset]) async throws { _ = mutate(assets) { $0.isDeleted = false } }

    public func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var n: Int64 = 0
        for g in LivePairing.group(files) {
            let id = "DEMO-" + UUID().uuidString.prefix(8)
            let ext = g.primary.pathExtension.lowercased()
            let dst = dir.appendingPathComponent(id + "." + (ext.isEmpty ? "jpg" : ext))
            try FileManager.default.copyItem(at: g.primary, to: dst)
            let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64) ?? 0
            var res = [PhotoResource(kind: .original, filename: g.primary.lastPathComponent, size: size, key: "file", recordName: id, url: nil, uti: nil)]
            if let v = g.pairedVideo {
                try? FileManager.default.copyItem(at: v, to: dir.appendingPathComponent(id + ".mov"))
                res.append(PhotoResource(kind: .liveVideo, filename: v.lastPathComponent, size: 0, key: "mov", recordName: id, url: nil, uti: nil))
            }
            let created = (try? g.primary.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let img = NSImage(contentsOf: dst)
            let a = PhotoAsset(id: id, masterID: id, changeTag: "1", library: "demo", filename: g.primary.lastPathComponent, size: size, created: created,
                               added: Date(), width: Int(img?.size.width ?? 0), height: Int(img?.size.height ?? 0), duration: nil,
                               isVideo: PhotoFormats.videoUTIs.contains(UTTypeHelper.identifier(for: g.primary)), isLive: g.pairedVideo != nil,
                               isFavorite: false, isHidden: false, isDeleted: false, isEdited: false, uti: nil, resources: res)
            lock.withLock {
                store.assets.insert(a, at: 0)
                if let album, album.kind == .album { store.membership[album.id, default: []].append(id) }
            }
            n += 1
            progress(n, Int64(files.count))
        }
        save()
    }

    public func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws {
        lock.withLock {
            var ids = store.membership[album.id] ?? []
            for a in assets where !ids.contains(a.id) { ids.append(a.id) }
            store.membership[album.id] = ids
        }
        save()
    }

    public func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum {
        let a = PhotoAlbum(id: "album:" + UUID().uuidString.prefix(8), name: name, kind: .album, count: 0)
        lock.withLock { store.albums.append(a) }
        save()
        return a
    }
}
