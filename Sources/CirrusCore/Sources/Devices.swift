#if os(macOS)
import AppKit
import ImageCaptureCore
#endif
import Foundation

public struct VolumeInfo: Hashable, Sendable {
    public var url: URL
    public var name: String
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isRoot: Bool
    public var available: Int64
    public var total: Int64
    public var format: String?

    public static func info(for url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeIsRootFileSystemKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                         .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeURLKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        var name = v.volumeName ?? url.lastPathComponent
        #if DEBUG
        if ProcessInfo.processInfo.environment["CIRRUS_SCREENSHOT"] != nil && (v.volumeIsRootFileSystem ?? false) { name = "Macintosh HD" }
        #endif
        return VolumeInfo(url: v.volume ?? url, name: name, isInternal: v.volumeIsInternal ?? false,
                          isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
                          isRoot: v.volumeIsRootFileSystem ?? false, available: avail, total: Int64(v.volumeTotalCapacity ?? 0),
                          format: v.volumeLocalizedFormatDescription)
    }

    /// Free space at an arbitrary folder (resolves the containing volume).
    public static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        return info(for: u)?.available
    }
}

#if os(macOS)
public struct DeviceItem: Hashable, Sendable {
    public var deviceID: String
    public var itemID: String
    public var name: String
    public var isFolder: Bool
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var uti: String?
}

/// External drives (mount/unmount) and Image Capture devices: iPhone, iPad, cameras, card readers,
/// and Android phones in PTP ("Transfer photos") mode.
@MainActor
public final class DeviceManager: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    public static let shared = DeviceManager()
    public static let changed = Notification.Name("CirrusDevicesChanged")
    public static let volumeMounted = Notification.Name("CirrusVolumeMounted")
    public private(set) var volumes: [VolumeInfo] = []
    public private(set) var cameras: [ICCameraDevice] = []
    let browser = ICDeviceBrowser()
    var ready = Set<String>()
    var started = false

    public func start() {
        guard !started else { return }
        started = true
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.refreshVolumes()
                    if note.name == NSWorkspace.didMountNotification, let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                        NotificationCenter.default.post(name: Self.volumeMounted, object: url)
                    }
                }
            }
        }
        guard ProcessInfo.processInfo.environment["CIRRUS_NO_DEVICES"] == nil else { return }
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    public func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard (try? u.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) ?? true else { return nil }
            return VolumeInfo.info(for: u)
        }.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func eject(_ v: VolumeInfo) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
    }

    // MARK: Cameras

    public func camera(_ id: String) -> ICCameraDevice? { cameras.first { deviceID($0) == id } }
    public func deviceID(_ d: ICDevice) -> String { d.uuidString ?? d.name ?? "device" }
    public func isReady(_ d: ICCameraDevice) -> Bool { ready.contains(deviceID(d)) }

    public func symbol(for d: ICDevice) -> String {
        let p = (d.productKind ?? d.name ?? "").lowercased()
        if p.contains("iphone") { return "iphone" }
        if p.contains("ipad") { return "ipad" }
        if p.contains("android") || p.contains("phone") { return "smartphone" }
        return "camera"
    }

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            guard let cam = device as? ICCameraDevice else { return }
            cam.delegate = self
            if !cameras.contains(cam) { cameras.append(cam) }
            cam.requestOpenSession()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    public nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            cameras.removeAll { $0 == device }
            ready.remove(deviceID(device))
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    func post() { NotificationCenter.default.post(name: Self.changed, object: self) }

    public nonisolated func didRemove(_ device: ICDevice) { MainActor.assumeIsolated { cameras.removeAll { $0 == device }; post() } }
    public nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { MainActor.assumeIsolated { post() } }
    public nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { MainActor.assumeIsolated { post() } }
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { MainActor.assumeIsolated { post() } }
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { MainActor.assumeIsolated { post() } }
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated { ready.insert(deviceID(device)); post() }
    }
    public nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { MainActor.assumeIsolated { post() } }
    public nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { MainActor.assumeIsolated { post() } }

    public func items(device id: String, folder: String?) -> [DeviceItem] {
        guard let cam = camera(id) else { return [] }
        let list: [ICCameraItem]
        if let folder, let f = find(folder, in: cam.contents ?? []) as? ICCameraFolder { list = f.contents ?? [] } else { list = cam.contents ?? [] }
        return list.map { describe($0, device: id) }
    }

    func key(_ item: ICCameraItem) -> String {
        var parts = [String]()
        var cur: ICCameraItem? = item
        while let c = cur { parts.insert(c.name ?? "?", at: 0); cur = c.parentFolder }
        return parts.joined(separator: "/")
    }

    func find(_ key: String, in items: [ICCameraItem]) -> ICCameraItem? {
        for i in items {
            if self.key(i) == key { return i }
            if let f = i as? ICCameraFolder, key.hasPrefix(self.key(f) + "/"), let found = find(key, in: f.contents ?? []) { return found }
        }
        return nil
    }

    func describe(_ i: ICCameraItem, device: String) -> DeviceItem {
        let file = i as? ICCameraFile
        return DeviceItem(deviceID: device, itemID: key(i), name: i.name ?? "Item", isFolder: i is ICCameraFolder,
                          size: file.map { Int64($0.fileSize) } ?? 0, created: file?.fileCreationDate ?? i.creationDate,
                          modified: file?.fileModificationDate ?? i.modificationDate, uti: i.uti)
    }

    public func allFiles(device id: String) -> [DeviceItem] {
        guard let cam = camera(id) else { return [] }
        return (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.map { describe($0, device: id) }
    }

    public func thumbnail(_ item: DeviceItem) async -> CGImage? {
        guard let cam = camera(item.deviceID), let f = find(item.itemID, in: cam.contents ?? []) as? ICCameraFile else { return nil }
        return await withCheckedContinuation { cont in
            f.requestThumbnailData(options: [:]) { data, _ in
                cont.resume(returning: data.flatMap { PhotoFormats.cgImage(from: $0, maxPixel: 360) })
            }
        }
    }

    public func download(_ item: DeviceItem, to destination: URL) async throws {
        guard let cam = camera(item.deviceID), let f = find(item.itemID, in: cam.contents ?? []) as? ICCameraFile else { throw ICloudError.notFound }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opts: [ICDownloadOption: Any] = [.downloadsDirectoryURL: destination.deletingLastPathComponent(),
                                             .saveAsFilename: destination.lastPathComponent, .overwrite: true]
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            f.requestDownload(options: opts) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        if let d = item.created { try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: item.modified ?? d], ofItemAtPath: destination.path) }
    }

    public func delete(_ items: [DeviceItem]) async throws {
        guard let first = items.first, let cam = camera(first.deviceID) else { return }
        let files = items.compactMap { find($0.itemID, in: cam.contents ?? []) as? ICCameraFile }
        guard cam.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) || cam.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteAllFiles.rawValue) else {
            throw ICloudError.server("\(cam.name ?? "This device") doesn’t allow deleting files.")
        }
        _ = cam.requestDeleteFiles(files)
    }

    public func eject(camera id: String) { camera(id)?.requestEject() }
}
#endif
