import AppKit
import CirrusCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let cirrusItems = NSPasteboard.PasteboardType("io.github.zephyrsai.cirrus.items")
}

/// In-process registry for items being dragged or copied, keyed by a token on the pasteboard.
@MainActor
final class DragRegistry {
    static let shared = DragRegistry()
    var sessions = [String: (items: [Item], source: Location?)]()
    func register(_ items: [Item], source: Location?) -> String {
        let token = UUID().uuidString
        sessions[token] = (items, source)
        if sessions.count > 40 { sessions.removeValue(forKey: sessions.keys.first!) }
        return token
    }
    func items(from pb: NSPasteboard) -> (items: [Item], source: Location?)? {
        var all = [Item]()
        var source: Location?
        for pi in pb.pasteboardItems ?? [] {
            guard let t = pi.string(forType: .cirrusItems), let s = sessions[t] else { continue }
            for i in s.items where !all.contains(where: { $0.key == i.key }) { all.append(i) }
            source = s.source
        }
        return all.isEmpty ? nil : (all, source)
    }
}

final class CirrusPromiseProvider: NSFilePromiseProvider {
    var token = ""
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.cirrusItems]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .cirrusItems ? token : super.pasteboardPropertyList(forType: type)
    }
}

final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let queue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInitiated; q.maxConcurrentOperationCount = 4; return q }()
    let item: Item
    init(item: Item) { self.item = item }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { Ops.outputName(item) }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let item = self.item
        let live = Prefs.exportLive
        let done = DispatchSemaphore(value: 0)
        let box = TransferBox()
        Task { @MainActor in
            box.transfer = TransferManager.shared.enqueue(url.lastPathComponent, detail: "Saving to \(url.deletingLastPathComponent().lastPathComponent)", direction: .download, total: item.transferSize) { t in
                let staging = Paths.cacheDir("tmp").appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging); done.signal() }
                do {
                    let got = try await Ops.materialize(item, into: staging, exportLive: live, nameOverride: url.lastPathComponent) { d, tot in t.report(d, tot) }
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: got, to: url)
                    for extra in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                        let dst = url.deletingLastPathComponent().appendingPathComponent(extra.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.moveItem(at: extra, to: dst) }
                    }
                    t.resultURL = url
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                    throw error
                }
            }
        }
        while done.wait(timeout: .now() + 1) == .timedOut {
            if let t = box.transfer, t.isFinished, t.state != .done {   // cancelled before it started
                completionHandler(ICloudError.cancelled)
                return
            }
        }
    }
}

final class TransferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _t: Transfer?
    var transfer: Transfer? { get { lock.withLock { _t } } set { lock.withLock { _t = newValue } } }
}

@MainActor
enum DragDrop {
    static var delegates = [PromiseDelegate]()

    static func writer(for item: Item, token: String) -> NSPasteboardWriting {
        if let u = item.localURL, item.cloud != .cloudOnly || FileManager.default.fileExists(atPath: u.path) {
            let pi = NSPasteboardItem()
            pi.setString(u.absoluteString, forType: .fileURL)
            pi.setString(token, forType: .cirrusItems)
            return pi
        }
        if item.volume != nil || item.target != nil && item.album == nil && item.driveNode == nil && item.deviceItem == nil {
            let pi = NSPasteboardItem()
            pi.setString(token, forType: .cirrusItems)
            return pi
        }
        let type = item.isContainer ? UTType.folder.identifier : (item.utType?.identifier ?? UTType.data.identifier)
        let d = PromiseDelegate(item: item)
        delegates.append(d)
        if delegates.count > 300 { delegates.removeFirst(100) }
        let p = CirrusPromiseProvider(fileType: type, delegate: d)
        p.token = token
        return p
    }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.cirrusItems, .fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// The drag operation Cirrus will perform (shown as the cursor badge).
    static func operation(_ info: NSDraggingInfo, to target: Location) -> NSDragOperation {
        let caps = Catalog.shared.caps(target)
        let pb = info.draggingPasteboard
        let mods = NSEvent.modifierFlags
        if let (items, source) = DragRegistry.shared.items(from: pb) { return operation(items: items, source: source, to: target, mods: mods) }
        guard caps.acceptsDrops else { return [] }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if case .local(let p) = target {
                if urls.contains(where: { $0.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: p).standardizedFileURL.path }) && !mods.contains(.option) { return [] }
                if mods.contains(.option) { return .copy }
                if mods.contains(.command) { return .move }
                return Ops.sameVolume(urls[0], URL(fileURLWithPath: p)) ? .move : .copy
            }
            return mods.contains(.command) ? .move : .copy
        }
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return .copy }
        return []
    }

    /// Copy or move for Cirrus's own items (same rules as Finder: same volume or same iCloud account moves).
    static func operation(items: [Item], source: Location?, to target: Location, mods: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSDragOperation {
        let caps = Catalog.shared.caps(target)
        do {
            if case .album(let a, _, let id) = target {
                guard id.hasPrefix("album:") || id == "smart:All Photos" || id == "smart:all" else { return [] }
                if items.allSatisfy({ $0.photo != nil && $0.account == a }) { return id.hasPrefix("album:") && source != target ? .link : [] }
                return caps.acceptsDrops ? .copy : []
            }
            guard caps.acceptsDrops else { return [] }
            if source == target { return [] }
            if items.contains(where: { $0.target == target }) { return [] }
            if case .drive(let a, _) = target, items.allSatisfy({ $0.driveNode != nil && $0.account == a }) { return mods.contains(.option) ? .copy : .move }
            if case .local(let p) = target, items.allSatisfy({ $0.localURL != nil }) {
                if mods.contains(.option) { return .copy }
                if mods.contains(.command) { return .move }
                return Ops.sameVolume(items[0].localURL!, URL(fileURLWithPath: p)) ? .move : .copy
            }
            return mods.contains(.command) && items.allSatisfy({ $0.localURL != nil || $0.driveNode != nil }) ? .move : .copy
        }
    }

    static func perform(_ info: NSDraggingInfo, to target: Location, window: NSWindow?) -> Bool {
        let op = operation(info, to: target)
        guard !op.isEmpty else { return false }
        let pb = info.draggingPasteboard
        let internalItems = DragRegistry.shared.items(from: pb)
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        Task { @MainActor in
            guard let dest = await Ops.shared.destination(for: target) else { return }
            if let (items, _) = internalItems {
                await Ops.shared.transfer(items, to: dest, move: op == .move, window: window)
            } else if !urls.isEmpty {
                await Ops.shared.deliver(files: urls, to: dest, move: op == .move, window: window)
            } else if !promises.isEmpty {
                await receive(promises, to: dest, window: window)
            }
        }
        return true
    }

    /// File promises (Photos.app, Mail, browsers…): receive into a temp folder, then deliver.
    static func receive(_ promises: [NSFilePromiseReceiver], to dest: Destination, window: NSWindow?) async {
        let dir: URL
        if case .local(let u) = dest { dir = u } else {
            dir = Paths.cacheDir("relay").appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var received = [URL]()
        for p in promises {
            let urls: [URL] = await withCheckedContinuation { cont in
                var got = [URL]()
                var remaining = max(1, p.fileNames.count)
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: PromiseDelegate.queue) { url, _ in
                    DispatchQueue.main.async {
                        got.append(url)
                        remaining -= 1
                        if remaining == 0 { cont.resume(returning: got) }
                    }
                }
            }
            received += urls
        }
        if case .local = dest { Ops.shared.refresh(dest); return }
        await Ops.shared.deliver(files: received, to: dest, move: false, window: window, cleanupTemp: dir)
    }
}
