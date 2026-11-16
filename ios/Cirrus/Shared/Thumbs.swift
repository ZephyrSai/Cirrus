import CirrusCore
import QuickLookThumbnailing
import SwiftUI
import UIKit
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

/// Thumbnails for photos (the engine's backends and disk cache) and iCloud Drive files. iCloud.com has no
/// Drive thumbnails, so, like the Mac app, small previewable files are fetched once into the Open cache and
/// thumbnailed on the device.
@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, UIImage>()
    private var tasks = [String: Task<UIImage?, Never>]()
    private let remote = AsyncLimiter(12)
    private let previews = AsyncLimiter(3)

    init() { cache.countLimit = 2500 }

    func purgeMemory() { cache.removeAllObjects() }

    func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    static func photoKey(_ account: Account, _ asset: PhotoAsset, px: Int) -> String {
        "p|\(account.id)|\(asset.id)|\(asset.changeTag ?? "")|\(px)"
    }

    static func driveKey(_ account: Account, _ node: DriveNode) -> String {
        "d|\(account.id)|\(node.id)|\(node.etag ?? "")|\(Int(node.modified?.timeIntervalSince1970 ?? 0))"
    }

    func photo(_ account: Account, _ asset: PhotoAsset, px: Int) async -> UIImage? {
        let key = Self.photoKey(account, asset, px: px)
        if let c = cached(key) { return c }
        guard let backend = account.photos else { return nil }
        let limiter = remote
        return await run(key) {
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            guard !Task.isCancelled, let cg = try? await backend.thumbnail(asset, maxPixel: px) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    static func wantsDrivePreview(_ node: DriveNode) -> Bool {
        guard Prefs.drivePreviews, !node.isFolder, node.size > 0, node.size <= Limits.drivePreviewMax,
              let t = UTType(filenameExtension: (node.name as NSString).pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .pdf) || t.conforms(to: .movie) || t.conforms(to: .presentation)
            || t.conforms(to: .spreadsheet) || t.identifier.contains("iwork") || t.conforms(to: .rtf)
            || t.identifier == "org.openxmlformats.wordprocessingml.document"
    }

    func drive(_ account: Account, _ node: DriveNode, px: Int) async -> UIImage? {
        // Services with server thumbnails (OneDrive, Google Drive, Dropbox, Nextcloud) make them for any size.
        if let cloud = account.drive as? CloudDriveBackend, !node.isFolder,
           let t = UTType(filenameExtension: (node.name as NSString).pathExtension),
           t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .pdf) {
            let key = Self.driveKey(account, node) + "|s\(px)"
            if let c = cached(key) { return c }
            let scale = Int(UIScreen.main.scale)
            if let img = await run(key, { (try? await cloud.thumbnail(node, maxPixel: px * scale)).flatMap { UIImage(data: $0) } }) { return img }
        }
        guard Self.wantsDrivePreview(node) else { return nil }
        let key = Self.driveKey(account, node) + "|\(px)"
        if let c = cached(key) { return c }
        let limiter = previews
        let scale = UIScreen.main.scale
        return await run(key) {
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            guard !Task.isCancelled, let u = try? await Ops.localCopy(account, node) else { return nil }
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: px, height: px), scale: scale, representationTypes: .thumbnail)
            return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).uiImage
        }
    }

    private func run(_ key: String, _ work: @escaping @MainActor () async -> UIImage?) async -> UIImage? {
        if let t = tasks[key] { return await t.value }
        let t = Task { await work() }
        tasks[key] = t
        let img = await t.value
        tasks[key] = nil
        if let img { cache.setObject(img, forKey: key as NSString) }
        return img
    }
}

enum FileIcon {
    static func symbol(for node: DriveNode) -> (name: String, color: Color) {
        if node.isAppLibrary { return ("app.badge", .blue) }
        if node.isFolder { return ("folder.fill", .blue) }
        return symbol(forName: node.name)
    }

    static func symbol(forName name: String) -> (name: String, color: Color) {
        guard let t = UTType(filenameExtension: (name as NSString).pathExtension) else { return ("doc", .secondary) }
        if t.conforms(to: .image) { return ("photo", .teal) }
        if t.conforms(to: .pdf) { return ("doc.richtext", .red) }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return ("film", .purple) }
        if t.conforms(to: .audio) { return ("music.note", .pink) }
        if t.conforms(to: .spreadsheet) || t.identifier.contains("numbers") { return ("tablecells", .green) }
        if t.conforms(to: .presentation) || t.identifier.contains("keynote") { return ("rectangle.on.rectangle", .orange) }
        if t.conforms(to: .archive) { return ("doc.zipper", .gray) }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) { return ("chevron.left.forwardslash.chevron.right", .indigo) }
        if t.conforms(to: .text) || t.identifier.contains("pages") || t.identifier.contains("word") { return ("doc.text", .blue) }
        return ("doc", .secondary)
    }
}

/// A Drive item's icon or thumbnail.
struct DriveThumb: View {
    let account: Account
    let node: DriveNode
    var size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.08))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            } else {
                let s = FileIcon.symbol(for: node)
                Image(systemName: s.name).resizable().scaledToFit().foregroundStyle(s.color)
                    .padding(size * (node.isFolder ? 0.08 : 0.16))
            }
        }
        .frame(width: size, height: size)
        .task(id: Thumbs.driveKey(account, node)) {
            if let c = Thumbs.shared.cached(Thumbs.driveKey(account, node) + "|\(Int(size * 2))") { image = c; return }
            image = await Thumbs.shared.drive(account, node, px: Int(size * 2))
        }
    }
}

/// A photo grid cell: square crop, Live Photo / video / favorite badges.
struct PhotoThumb: View {
    let account: Account
    let asset: PhotoAsset
    var px: Int = 256
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: asset.isVideo ? "film" : "photo").foregroundStyle(.tertiary) }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if asset.isLive {
                    Image(systemName: "livephoto").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .shadow(radius: 2).padding(5).accessibilityLabel("Live Photo")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(5)
                        .accessibilityLabel("Favorite")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo, let d = asset.duration {
                    Text(Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                        .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .task(id: Thumbs.photoKey(account, asset, px: px)) {
                if let c = Thumbs.shared.cached(Thumbs.photoKey(account, asset, px: px)) { image = c; return }
                image = await Thumbs.shared.photo(account, asset, px: px)
            }
    }
}
