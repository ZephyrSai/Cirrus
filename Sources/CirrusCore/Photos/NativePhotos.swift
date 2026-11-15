#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Photos

/// The Mac's own Photos library through PhotoKit. When the Mac is signed in to iCloud with
/// iCloud Photos on, this *is* iCloud Photos (originals download on demand).
public final class NativePhotos: NSObject, PhotosBackend, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    public static let changedNotification = Notification.Name("CirrusNativePhotosChanged")
    public let cacheKey = "native"
    public var capabilities: PhotoCapabilities { [.favorite, .hide, .delete, .importFiles, .albums, .createAlbum] }
    let imageManager = PHCachingImageManager()
    private var observing = false
    private let lock = NSLock()
    private var assetCache = [String: PHAsset]()

    public static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    public func ensureAuthorized() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            throw ICloudError.server("Cirrus doesn’t have access to Photos. Allow it in System Settings › Privacy & Security › Photos.")
        }
        let shouldRegister: Bool = lock.withLock { let r = !observing; observing = true; return r }
        if shouldRegister { PHPhotoLibrary.shared().register(self) }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
    }

    public func libraries() async throws -> [PhotoLibraryRef] {
        [PhotoLibraryRef(id: "local", name: "Photos Library", isShared: false)]
    }

    static let smartOrder: [(PHAssetCollectionSubtype, String)] = [
        (.smartAlbumFavorites, "heart"), (.smartAlbumRecentlyAdded, "clock"), (.smartAlbumVideos, "video"),
        (.smartAlbumLivePhotos, "livephoto"), (.smartAlbumScreenshots, "camera.viewfinder"), (.smartAlbumSelfPortraits, "person.crop.square"),
        (.smartAlbumDepthEffect, "cube"), (.smartAlbumPanoramas, "pano"), (.smartAlbumSlomoVideos, "slowmo"),
        (.smartAlbumTimelapses, "timelapse"), (.smartAlbumBursts, "square.stack.3d.down.right"), (.smartAlbumRAW, "camera.aperture"),
        (.smartAlbumLongExposures, "plusminus.circle"), (.smartAlbumAnimated, "square.stack.3d.forward.dottedline"),
        (.smartAlbumScreenRecordings, "record.circle"), (.smartAlbumAllHidden, "eye.slash"),
    ]

    public func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] {
        try await ensureAuthorized()
        var out = [PhotoAlbum]()
        let all = PHAsset.fetchAssets(with: Self.baseOptions())
        out.append(PhotoAlbum(id: "smart:all", name: "All Photos", kind: .smart, count: all.count, symbol: "photo.on.rectangle"))
        for (sub, symbol) in Self.smartOrder {
            let r = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: sub, options: nil)
            r.enumerateObjects { c, _, _ in
                let count = PHAsset.fetchAssets(in: c, options: sub == .smartAlbumAllHidden ? nil : Self.baseOptions()).count
                if count > 0 || sub == .smartAlbumFavorites {
                    out.append(PhotoAlbum(id: "smart:" + c.localIdentifier, name: c.localizedTitle ?? "Album", kind: .smart, count: count, symbol: symbol))
                }
            }
        }
        func walk(_ list: PHFetchResult<PHCollection>, parent: String?) {
            list.enumerateObjects { col, _, _ in
                if let folder = col as? PHCollectionList {
                    let id = "folder:" + folder.localIdentifier
                    out.append(PhotoAlbum(id: id, name: folder.localizedTitle ?? "Folder", kind: .folder, parentID: parent, symbol: "folder"))
                    walk(PHCollection.fetchCollections(in: folder, options: nil), parent: id)
                } else if let album = col as? PHAssetCollection {
                    out.append(PhotoAlbum(id: "album:" + album.localIdentifier, name: album.localizedTitle ?? "Album", kind: .album, parentID: parent,
                                          count: PHAsset.fetchAssets(in: album, options: nil).count, symbol: "rectangle.stack"))
                }
            }
        }
        walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), parent: nil)
        let shared = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
        shared.enumerateObjects { c, _, _ in
            out.append(PhotoAlbum(id: "album:" + c.localIdentifier, name: c.localizedTitle ?? "Shared Album", kind: .shared,
                                  count: PHAsset.fetchAssets(in: c, options: nil).count, symbol: "person.2.crop.square.stack"))
        }
        return out
    }

    static func baseOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    func collection(_ album: PhotoAlbum) -> PHAssetCollection? {
        let id = album.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    public func assets(in album: PhotoAlbum, library: PhotoLibraryRef,
                       page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        try await ensureAuthorized()
        let fetch: PHFetchResult<PHAsset>
        if album.id == "smart:all" {
            fetch = PHAsset.fetchAssets(with: Self.baseOptions())
        } else if let c = collection(album) {
            fetch = PHAsset.fetchAssets(in: c, options: c.assetCollectionSubtype == .smartAlbumAllHidden ? nil : Self.baseOptions())
        } else {
            return []
        }
        let total = fetch.count
        var out = [PhotoAsset]()
        out.reserveCapacity(total)
        var batch = [PhotoAsset]()
        var cache = [String: PHAsset]()
        for i in 0..<total {
            if i % 256 == 0 { try Task.checkCancellation() }
            let a = fetch.object(at: i)
            cache[a.localIdentifier] = a
            let p = Self.convert(a)
            out.append(p)
            batch.append(p)
            if batch.count == 500 { page(batch, total); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { page(batch, total) }
        lock.withLock { assetCache.merge(cache) { $1 } }
        return out
    }

    static func fileSize(_ r: PHAssetResource) -> Int64 {
        guard r.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    static func convert(_ a: PHAsset) -> PhotoAsset {
        let res = PHAssetResource.assetResources(for: a)
        var resources = [PhotoResource]()
        var filename = ""
        var uti: String?
        for r in res {
            let kind: PhotoResource.Kind?
            switch r.type {
            case .photo, .video, .audio: kind = .original
            case .pairedVideo: kind = .liveVideo
            case .fullSizePhoto, .fullSizeVideo: kind = .edited
            case .alternatePhoto: kind = .alternate
            default: kind = nil
            }
            guard let k = kind, !resources.contains(where: { $0.kind == k }) else { continue }
            if k == .original { filename = r.originalFilename; uti = r.uniformTypeIdentifier }
            var name = r.originalFilename
            if k == .edited {
                let stem = ((filename.isEmpty ? name : filename) as NSString).deletingPathExtension
                name = stem + "-edited." + (name as NSString).pathExtension
            }
            resources.append(PhotoResource(kind: k, filename: name, size: fileSize(r), key: String(r.type.rawValue), recordName: a.localIdentifier, url: nil, uti: r.uniformTypeIdentifier))
        }
        if filename.isEmpty { filename = a.localIdentifier.replacingOccurrences(of: "/", with: "_") + (a.mediaType == .video ? ".mov" : ".jpg") }
        return PhotoAsset(id: a.localIdentifier, masterID: nil, changeTag: nil, library: "local", filename: Paths.safeName(filename),
                          size: resources.first { $0.kind == .original }?.size ?? 0, created: a.creationDate, added: a.creationDate,
                          width: a.pixelWidth, height: a.pixelHeight, duration: a.mediaType == .video ? a.duration : nil,
                          isVideo: a.mediaType == .video, isLive: a.mediaSubtypes.contains(.photoLive), isFavorite: a.isFavorite,
                          isHidden: a.isHidden, isDeleted: false, isEdited: resources.contains { $0.kind == .edited }, uti: uti, resources: resources)
    }

    func phAsset(_ id: String) -> PHAsset? {
        lock.lock()
        if let a = assetCache[id] { lock.unlock(); return a }
        lock.unlock()
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    public func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? {
        guard let a = phAsset(asset.id) else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        let size = CGSize(width: maxPixel, height: maxPixel)
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            var done = false
            imageManager.requestImage(for: a, targetSize: size, contentMode: .aspectFill, options: opts) { img, info in
                if done { return }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                done = true
                #if os(macOS)
                cont.resume(returning: img?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #else
                cont.resume(returning: img?.cgImage)
                #endif
            }
        }
    }

    public func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let a = phAsset(asset.id) else { throw ICloudError.notFound }
        let all = PHAssetResource.assetResources(for: a)
        let pick: PHAssetResource?
        switch resource {
        case .original: pick = all.first { [.photo, .video, .audio].contains($0.type) }
        case .liveVideo: pick = all.first { $0.type == .pairedVideo }
        case .edited: pick = all.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
        case .alternate: pick = all.first { $0.type == .alternatePhoto }
        case .thumbnail, .medium: pick = nil
        }
        guard let r = pick else { throw ICloudError.notFound }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        let total = max(Self.fileSize(r), 1)
        opts.progressHandler = { p in progress(Int64(Double(total) * p), total) }
        try await PHAssetResourceManager.default().writeData(for: r, toFile: destination, options: opts)
        if let d = asset.created { try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: destination.path) }
    }

    func change(_ block: @escaping () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(block)
    }

    func phAssets(_ assets: [PhotoAsset]) -> [PHAsset] {
        let r = PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
        var out = [PHAsset]()
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    public func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        try SafetyPolicy.checkWrite()
        let phs = phAssets(assets)
        try await change { for a in phs { PHAssetChangeRequest(for: a).isFavorite = value } }
        return assets.map { var x = $0; x.isFavorite = value; return x }
    }

    public func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        try SafetyPolicy.checkWrite()
        let phs = phAssets(assets)
        try await change { for a in phs { PHAssetChangeRequest(for: a).isHidden = value } }
        return assets.map { var x = $0; x.isHidden = value; return x }
    }

    /// macOS shows its own confirmation; deleted items go to Recently Deleted in Photos.
    public func delete(_ assets: [PhotoAsset]) async throws {
        try SafetyPolicy.checkWrite()
        let phs = phAssets(assets)
        try await change { PHAssetChangeRequest.deleteAssets(phs as NSArray) }
    }

    public func restore(_ assets: [PhotoAsset]) async throws {
        throw ICloudError.server("Use the Photos app to recover items from Recently Deleted.")
    }

    public func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef,
                            progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try SafetyPolicy.checkWrite()
        try await ensureAuthorized()
        let groups = LivePairing.group(files)
        let col = album.flatMap { collection($0) }
        var done: Int64 = 0
        for g in groups {
            try Task.checkCancellation()
            try await change {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = g.primary.lastPathComponent
                let isVideo = PhotoFormats.videoUTIs.contains(UTTypeHelper.identifier(for: g.primary))
                req.addResource(with: isVideo ? .video : .photo, fileURL: g.primary, options: opts)
                if let v = g.pairedVideo {
                    let vo = PHAssetResourceCreationOptions()
                    vo.originalFilename = v.lastPathComponent
                    req.addResource(with: .pairedVideo, fileURL: v, options: vo)
                }
                if let col, let ph = req.placeholderForCreatedAsset { PHAssetCollectionChangeRequest(for: col)?.addAssets([ph] as NSArray) }
            }
            done += 1
            progress(done, Int64(groups.count))
        }
    }

    public func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws {
        try SafetyPolicy.checkWrite()
        guard let col = collection(album) else { throw ICloudError.notFound }
        let phs = phAssets(assets)
        try await change { PHAssetCollectionChangeRequest(for: col)?.addAssets(phs as NSArray) }
    }

    public func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum {
        try SafetyPolicy.checkWrite()
        var placeholder: String?
        try await change { placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection.localIdentifier }
        guard let id = placeholder else { throw ICloudError.server("Couldn’t create the album.") }
        return PhotoAlbum(id: "album:" + id, name: name, kind: .album, count: 0)
    }
}

/// Pairs Live Photo stills with their .MOV (same stem), the way icloudpd names them.
public enum LivePairing {
    public struct Group { public var primary: URL; public var pairedVideo: URL? }
    public static func group(_ files: [URL]) -> [Group] {
        let byStem = Dictionary(grouping: files) { $0.deletingPathExtension().path.lowercased() }
        var out = [Group]()
        for (_, urls) in byStem {
            let stills = urls.filter { !["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            let movies = urls.filter { ["mov"].contains($0.pathExtension.lowercased()) }
            if stills.count == 1, movies.count == 1 {
                out.append(Group(primary: stills[0], pairedVideo: movies[0]))
            } else {
                out += urls.map { Group(primary: $0, pairedVideo: nil) }
            }
        }
        return out.sorted { $0.primary.lastPathComponent < $1.primary.lastPathComponent }
    }
}

enum UTTypeHelper {
    static func identifier(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? ""
    }
}
