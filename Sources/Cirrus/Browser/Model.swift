import AppKit
import CirrusCore
import UniformTypeIdentifiers

/// Everything a pane can show.
enum Location: Hashable, Codable {
    case computer
    case local(String)
    case drive(String, String)               // account id, folder drivewsid
    case driveTrash(String)
    case photos(String, String, String?)     // account, library, album folder id (nil = library home)
    case album(String, String, String)       // account, library, album id
    case device(String, String?)             // device id, folder key

    var accountID: String? {
        switch self {
        case .drive(let a, _), .driveTrash(let a), .photos(let a, _, _), .album(let a, _, _): return a
        default: return nil
        }
    }
    @MainActor var account: Account? { accountID.flatMap { AccountManager.shared.account(id: $0) } }
    var isPhotoGrid: Bool { if case .album = self { return true }; return false }
    var localURL: URL? { if case .local(let p) = self { return URL(fileURLWithPath: p, isDirectory: true) }; return nil }
    var isRemote: Bool { switch self { case .drive, .driveTrash, .photos, .album: return true; default: return false } }

    static func home() -> Location { .local(FileManager.default.homeDirectoryForCurrentUser.path) }
}

enum CloudState: Equatable { case cloudOnly, downloading, downloaded, uploading, waitingUpload, error }

struct Item: Hashable {
    enum Payload {
        case file(URL)
        case drive(DriveNode)
        case photo(PhotoAsset)
        case album(PhotoAlbum)
        case device(DeviceItem)
        case volume(VolumeInfo)
        case camera(String)
    }

    var key: String
    var name: String
    var isContainer: Bool
    var size: Int64?
    var modified: Date?
    var created: Date?
    var typeID: String?
    var payload: Payload
    var target: Location?
    var cloud: CloudState?
    var count: Int?
    var symbol: String?
    var isHiddenFile = false
    var account: String? = nil

    static func == (a: Item, b: Item) -> Bool {
        a.key == b.key && a.name == b.name && a.size == b.size && a.modified == b.modified && a.cloud == b.cloud
            && a.photo?.isFavorite == b.photo?.isFavorite && a.photo?.isHidden == b.photo?.isHidden && a.count == b.count
    }
    func hash(into h: inout Hasher) { h.combine(key) }

    var localURL: URL? { if case .file(let u) = payload { return u }; return nil }
    var photo: PhotoAsset? { if case .photo(let p) = payload { return p }; return nil }
    var driveNode: DriveNode? { if case .drive(let n) = payload { return n }; return nil }
    var album: PhotoAlbum? { if case .album(let a) = payload { return a }; return nil }
    var deviceItem: DeviceItem? { if case .device(let d) = payload { return d }; return nil }
    var volume: VolumeInfo? { if case .volume(let v) = payload { return v }; return nil }
    var isPhoto: Bool { photo != nil }
    var isVideo: Bool { photo?.isVideo ?? (typeID.flatMap { UTType($0)?.conforms(to: .movie) } ?? false) }

    var utType: UTType? {
        if let t = typeID, let u = UTType(t) { return u }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    var kindText: String {
        if case .album(let a) = payload { return a.kind == .folder ? "Album Folder" : (a.kind == .smart ? "Smart Album" : "Album") }
        if case .volume(let v) = payload { return v.isInternal ? "Internal Disk" : "External Disk" }
        if case .camera = payload { return "Device" }
        if isContainer { return "Folder" }
        return utType?.localizedDescription?.capitalizedFirst ?? "Document"
    }

    /// Bytes a full copy of this item needs (folders unknown).
    var transferSize: Int64 { size ?? 0 }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct LocationCaps {
    var canCreateFolder = false
    var newFolderTitle = "New Folder"
    var acceptsDrops = false
    var canRename = false
    var canTrash = false
    var isTrash = false
    var readOnly = true
}

/// Lists locations and knows their names, icons and paths.
@MainActor
final class Catalog {
    static let shared = Catalog()
    var driveNames = [String: (name: String, parent: String?)]()     // "acct|id"
    var albumIndex = [String: [PhotoAlbum]]()                         // "acct|lib"
    var libraryIndex = [String: [PhotoLibraryRef]]()                  // acct
    var memory = [Location: [Item]]() { didSet { } }
    var memoryAt = [Location: Date]()
    var forceNext = Set<Location>()

    /// How long an in-memory listing is trusted before re-checking the server (our own edits invalidate sooner).
    func ttl(_ loc: Location) -> TimeInterval {
        switch loc {
        case .drive, .driveTrash: return 60
        case .photos: return 300
        case .album: return 0          // listAlbum does its own token-based freshness check
        default: return 0              // local / devices are cheap and watched
        }
    }

    struct AlbumCache: Codable { var assets: [PhotoAsset]; var token: String?; var savedAt: Date }
    struct DriveCache: Codable { var nodes: [DriveNode]; var savedAt: Date }
    #if DEBUG
    static let albumFreshFor: TimeInterval = Double(ProcessInfo.processInfo.environment["CIRRUS_ALBUM_TTL"] ?? "") ?? 300
    #else
    static let albumFreshFor: TimeInterval = 300
    #endif
    var showHidden: Bool { UserDefaults.standard.bool(forKey: "showHidden") }

    // MARK: Titles & icons

    func title(_ loc: Location) -> String {
        switch loc {
        case .computer: return Debug.screenshotMode ? "MacBook Pro" : (Host.current().localizedName ?? "This Mac")
        case .local(let p):
            let url = URL(fileURLWithPath: p)
            if let root = AccountManager.shared.macAccount?.driveRoot, url.standardizedFileURL.path == root.standardizedFileURL.path { return "iCloud Drive" }
            if p == "/" { return VolumeInfo.info(for: url)?.name ?? "Macintosh HD" }
            if let c = nativeContainer(for: url), c.url.standardizedFileURL.path == url.standardizedFileURL.path { return c.name }
            return FileManager.default.displayName(atPath: p)
        case .drive(let a, let id):
            if id.hasSuffix("::root") || id == DemoDrive.shared.rootID { return "iCloud Drive" }
            return driveNames[a + "|" + id]?.name ?? "Folder"
        case .driveTrash: return "Recently Deleted"
        case .photos(let a, let lib, let folder):
            if let folder { return albumIndex[a + "|" + lib]?.first { $0.id == folder }?.name ?? "Folder" }
            let libs = libraryIndex[a] ?? []
            if libs.count > 1, let l = libs.first(where: { $0.id == lib }) { return l.name }
            return "Photos"
        case .album(let a, let lib, let id):
            return albumIndex[a + "|" + lib]?.first { $0.id == id }?.name ?? (id.hasPrefix("smart:") ? String(id.dropFirst(6)) : "Album")
        case .device(let d, let folder):
            if let folder { return (folder as NSString).lastPathComponent }
            return DeviceManager.shared.camera(d)?.name ?? "Device"
        }
    }

    func symbolName(_ loc: Location) -> String {
        switch loc {
        case .computer: return "desktopcomputer"
        case .local(let p):
            if let root = AccountManager.shared.macAccount?.driveRoot, p.hasPrefix(root.path) { return p == root.path ? "icloud" : "folder" }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            switch p {
            case home: return "house"
            case home + "/Desktop": return "menubar.dock.rectangle"
            case home + "/Documents": return "doc"
            case home + "/Downloads": return "arrow.down.circle"
            case home + "/Pictures": return "photo"
            case home + "/Movies": return "film"
            case home + "/Music": return "music.note"
            case "/Applications": return "app.dashed"
            case "/": return "internaldrive"
            default: return p.hasPrefix("/Volumes/") && p.split(separator: "/").count == 2 ? "externaldrive" : "folder"
            }
        case .drive: return "icloud"
        case .driveTrash: return "trash"
        case .photos: return "photo.on.rectangle.angled"
        case .album(let a, let lib, let id): return albumIndex[a + "|" + lib]?.first { $0.id == id }?.symbol ?? "rectangle.stack"
        case .device(let d, _): return DeviceManager.shared.camera(d).map { DeviceManager.shared.symbol(for: $0) } ?? "camera"
        }
    }

    func caps(_ loc: Location) -> LocationCaps {
        var c = LocationCaps()
        switch loc {
        case .local(let p):
            let writable = FileManager.default.isWritableFile(atPath: p)
            c.canCreateFolder = writable; c.acceptsDrops = writable; c.canRename = writable; c.canTrash = writable; c.readOnly = !writable
        case .drive:
            c.canCreateFolder = true; c.acceptsDrops = true; c.canRename = true; c.canTrash = true; c.readOnly = false
        case .driveTrash:
            c.isTrash = true
        case .photos(let a, _, let folder):
            let cap = AccountManager.shared.account(id: a)?.photos?.capabilities ?? []
            c.canCreateFolder = folder == nil && cap.contains(.createAlbum); c.newFolderTitle = "New Album"
            c.acceptsDrops = cap.contains(.importFiles); c.readOnly = false
        case .album(let a, _, let id):
            let cap = AccountManager.shared.account(id: a)?.photos?.capabilities ?? []
            c.isTrash = id == "smart:Recently Deleted"
            c.acceptsDrops = cap.contains(.importFiles) && (id.hasPrefix("album:") || id == "smart:All Photos" || id == "smart:all")
            c.canTrash = cap.contains(.delete) && !c.isTrash
            c.readOnly = false
        case .device:
            c.canTrash = true
        case .computer:
            break
        }
        if SafetyPolicy.readOnlyICloud && isICloud(loc) {
            c.canCreateFolder = false; c.acceptsDrops = false; c.canRename = false; c.canTrash = false; c.readOnly = true
        }
        return c
    }

    func isICloud(_ loc: Location) -> Bool {
        switch loc {
        case .drive, .driveTrash, .photos, .album: return true
        case .local(let p): return SafetyPolicy.isICloudPath(URL(fileURLWithPath: p))
        default: return false
        }
    }

    // MARK: Path

    func pathComponents(_ loc: Location) -> [(String, Location)] {
        switch loc {
        case .local(let p):
            let url = URL(fileURLWithPath: p).standardizedFileURL
            if let root = AccountManager.shared.macAccount?.driveRoot?.standardizedFileURL {
                if url.path.hasPrefix(root.path) {
                    var out = [("iCloud Drive", Location.local(root.path))]
                    var cur = root
                    for comp in url.path.dropFirst(root.path.count).split(separator: "/") {
                        cur.appendPathComponent(String(comp))
                        out.append((String(comp), .local(cur.path)))
                    }
                    return out
                }
                if let c = nativeContainer(for: url) {
                    var out = [("iCloud Drive", Location.local(root.path)), (c.name, Location.local(c.url.path))]
                    var cur = c.url.standardizedFileURL
                    for comp in url.path.dropFirst(cur.path.count).split(separator: "/") {
                        cur.appendPathComponent(String(comp))
                        out.append((String(comp), .local(cur.path)))
                    }
                    return out
                }
            }
            var out = [(String, Location)]()
            var cur = url
            while true {
                out.insert((title(.local(cur.path)), .local(cur.path)), at: 0)
                if cur.path == "/" { break }
                if let vol = try? cur.resourceValues(forKeys: [.volumeURLKey]).volume, vol.standardizedFileURL.path == cur.path, cur.path != "/" { break }
                cur.deleteLastPathComponent()
            }
            return out
        case .drive(let a, let id):
            var out = [(String, Location)]()
            var cur: String? = id
            var guardCount = 0
            while let c = cur, guardCount < 64 {
                out.insert((title(.drive(a, c)), .drive(a, c)), at: 0)
                if c.hasSuffix("::root") || c == DemoDrive.shared.rootID { break }
                cur = driveNames[a + "|" + c]?.parent
                guardCount += 1
            }
            if let first = out.first, case .drive(_, let fid) = first.1, !(fid.hasSuffix("::root") || fid == DemoDrive.shared.rootID),
               let acct = AccountManager.shared.account(id: a), let d = acct.drive {
                out.insert(("iCloud Drive", .drive(a, d.rootID)), at: 0)
            }
            return out
        case .driveTrash(let a):
            let root = AccountManager.shared.account(id: a)?.drive?.rootID ?? ""
            return [("iCloud Drive", .drive(a, root)), ("Recently Deleted", loc)]
        case .photos(let a, let lib, let folder):
            var out = [(title(.photos(a, lib, nil)), Location.photos(a, lib, nil))]
            var chain = [String]()
            var cur = folder
            let albums = albumIndex[a + "|" + lib] ?? []
            while let c = cur { chain.insert(c, at: 0); cur = albums.first { $0.id == c }?.parentID }
            for c in chain { out.append((title(.photos(a, lib, c)), .photos(a, lib, c))) }
            return out
        case .album(let a, let lib, let id):
            let parent = albumIndex[a + "|" + lib]?.first { $0.id == id }?.parentID
            return pathComponents(.photos(a, lib, parent)) + [(title(loc), loc)]
        case .device(let d, let folder):
            var out = [(title(.device(d, nil)), Location.device(d, nil))]
            if let folder {
                var acc = ""
                for comp in folder.split(separator: "/") {
                    acc = acc.isEmpty ? String(comp) : acc + "/" + comp
                    out.append((String(comp), .device(d, acc)))
                }
            }
            return out
        case .computer:
            return [(title(.computer), .computer)]
        }
    }

    func parent(of loc: Location) -> Location? {
        let comps = pathComponents(loc)
        if comps.count >= 2 { return comps[comps.count - 2].1 }
        if case .local(let p) = loc, p != "/" { return .local((p as NSString).deletingLastPathComponent) }
        if case .local = loc { return .computer }
        return nil
    }

    func nativeContainer(for url: URL) -> NativeICloud.Container? {
        guard let root = AccountManager.shared.macAccount?.driveRoot else { return nil }
        let p = url.standardizedFileURL.path
        return NativeICloud.appContainers(root: root).first { p == $0.url.standardizedFileURL.path || p.hasPrefix($0.url.standardizedFileURL.path + "/") }
    }

    // MARK: Listing

    func list(_ loc: Location, partial: @escaping @MainActor ([Item]) -> Void) async throws -> [Item] {
        let forced = forceNext.remove(loc) != nil
        if !forced, let m = memory[loc], let t = memoryAt[loc], Date().timeIntervalSince(t) < ttl(loc) { return m }
        let started = Date()
        defer {
            let secs = Date().timeIntervalSince(started)
            if secs > 1 { Log.status("list \(Self.kindName(loc)) \(memory[loc]?.count ?? 0) items in \(String(format: "%.1f", secs))s") }
        }
        let items: [Item]
        switch loc {
        case .computer:
            items = computerItems()
        case .local(let p):
            let url = URL(fileURLWithPath: p, isDirectory: true)
            let hidden = showHidden
            items = try await Task.detached(priority: .userInitiated) { try Self.listLocal(url, showHidden: hidden) }.value
                + rootExtras(url)
        case .drive(let a, let id):
            guard let acct = AccountManager.shared.account(id: a), let drive = acct.drive else { throw ICloudError.needsSignIn }
            let file = cacheFile(account: a, library: "drive", album: Ops.stableKey(id))
            if memory[loc] == nil, let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(DriveCache.self, from: d) {
                partial(c.nodes.map { driveItem($0, account: a) })
            }
            let nodes = try await drive.list(id)
            if acct.kind == .web, let d = try? JSONEncoder().encode(DriveCache(nodes: nodes, savedAt: Date())) { try? d.write(to: file, options: .atomic) }
            for n in nodes where n.isFolder { driveNames[a + "|" + n.id] = (n.name, id) }
            items = nodes.map { driveItem($0, account: a) }
        case .driveTrash(let a):
            guard let drive = AccountManager.shared.account(id: a)?.drive else { throw ICloudError.needsSignIn }
            items = try await drive.listTrash().map { var i = driveItem($0, account: a); i.target = nil; i.isContainer = $0.isFolder; return i }
        case .photos(let a, let lib, let folder):
            let albums = try await albums(account: a, library: lib)
            items = albums.filter { $0.parentID == folder && !(folder == nil && $0.kind == .smart && $0.count == 0 && !$0.isAllPhotos && $0.id != "smart:Favorites") }
                .map { albumItem($0, account: a, library: lib) }
        case .album(let a, let lib, let id):
            items = try await listAlbum(account: a, library: lib, albumID: id, forced: forced, partial: partial)
        case .device(let d, let folder):
            items = DeviceManager.shared.items(device: d, folder: folder).map { deviceItem($0) }
        }
        memory[loc] = items
        return items
    }

    static func kindName(_ loc: Location) -> String {
        switch loc {
        case .computer: return "computer"
        case .local: return "local"
        case .drive: return "drive"
        case .driveTrash: return "drive-trash"
        case .photos: return "albums"
        case .album: return "photos"
        case .device: return "device"
        }
    }

    func computerItems() -> [Item] {
        var out = DeviceManager.shared.volumes.map { v in
            Item(key: "vol:" + v.url.path, name: v.name, isContainer: true, size: v.total, modified: nil, created: nil, typeID: nil,
                 payload: .volume(v), target: .local(v.url.path), symbol: v.isInternal ? "internaldrive" : "externaldrive")
        }
        for cam in DeviceManager.shared.cameras {
            let id = DeviceManager.shared.deviceID(cam)
            out.append(Item(key: "cam:" + id, name: cam.name ?? "Device", isContainer: true, size: nil, modified: nil, created: nil, typeID: nil,
                            payload: .camera(id), target: .device(id, nil), symbol: DeviceManager.shared.symbol(for: cam)))
        }
        return out
    }

    /// iCloud Drive root on a signed-in Mac also shows the app folders (Pages, Numbers…).
    func rootExtras(_ url: URL) -> [Item] {
        guard let root = AccountManager.shared.macAccount?.driveRoot, url.standardizedFileURL.path == root.standardizedFileURL.path else { return [] }
        return NativeICloud.appContainers(root: root).map { c in
            Item(key: "file:" + c.url.path, name: c.name, isContainer: true, size: nil,
                 modified: (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate), created: nil,
                 typeID: UTType.folder.identifier, payload: .file(c.url), target: .local(c.url.path), symbol: "app.badge")
        }
    }

    nonisolated static let localKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey,
        .isHiddenKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .isSymbolicLinkKey, .localizedNameKey,
    ]

    nonisolated static func listLocal(_ dir: URL, showHidden: Bool) throws -> [Item] {
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: localKeys, options: [])
        return urls.compactMap { localItem($0, showHidden: showHidden) }
    }

    nonisolated static func localItem(_ u: URL, showHidden: Bool) -> Item? {
        let v = try? u.resourceValues(forKeys: Set(localKeys))
        var name = u.lastPathComponent
        var cloud: CloudState?
        var url = u
        if name.hasPrefix(".") && name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(7))
            url = u.deletingLastPathComponent().appendingPathComponent(name)
            cloud = .cloudOnly
        } else if v?.isHidden == true || name.hasPrefix(".") {
            if !showHidden || name == ".DS_Store" || name == ".localized" { return nil }
        }
        let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        if cloud == nil, v?.isUbiquitousItem == true {
            if v?.ubiquitousItemIsDownloading == true { cloud = .downloading }
            else if v?.ubiquitousItemIsUploading == true { cloud = .uploading }
            else if v?.ubiquitousItemIsUploaded == false && !isDir { cloud = .waitingUpload }
            else if !isDir {
                switch v?.ubiquitousItemDownloadingStatus {
                case .some(.notDownloaded): cloud = .cloudOnly
                case .some(.current), .some(.downloaded): cloud = .downloaded
                default: break
                }
            }
        }
        var size: Int64? = isDir ? nil : Int64(v?.fileSize ?? 0)
        if cloud == .cloudOnly && u != url, let n = NSDictionary(contentsOf: u)?["NSURLFileSizeKey"] as? NSNumber { size = n.int64Value }
        return Item(key: "file:" + url.path, name: isDir ? (v?.localizedName ?? name) : name, isContainer: isDir, size: size,
                    modified: v?.contentModificationDate, created: v?.creationDate, typeID: v?.typeIdentifier, payload: .file(url),
                    target: isDir ? .local(url.path) : nil, cloud: cloud, isHiddenFile: name.hasPrefix(".") || v?.isHidden == true)
    }

    func driveItem(_ n: DriveNode, account: String) -> Item {
        Item(key: "drive:" + account + ":" + n.id, name: n.name, isContainer: n.isFolder, size: n.isFolder ? nil : n.size, modified: n.modified,
             created: n.created, typeID: n.isFolder ? UTType.folder.identifier : UTType(filenameExtension: (n.name as NSString).pathExtension)?.identifier,
             payload: .drive(n), target: n.isFolder ? .drive(account, n.id) : nil, count: n.childCount, symbol: n.isAppLibrary ? "app.badge" : nil,
             account: account)
    }

    func albumItem(_ a: PhotoAlbum, account: String, library: String) -> Item {
        Item(key: "album:" + account + ":" + library + ":" + a.id, name: a.name, isContainer: true, size: nil, modified: nil, created: nil,
             typeID: nil, payload: .album(a), target: a.kind == .folder ? .photos(account, library, a.id) : .album(account, library, a.id),
             count: a.count, symbol: a.symbol, account: account)
    }

    func photoItem(_ p: PhotoAsset, account: String) -> Item {
        Item(key: "photo:" + account + ":" + p.id, name: p.filename, isContainer: false, size: p.size, modified: p.created, created: p.added,
             typeID: p.uti ?? UTType(filenameExtension: (p.filename as NSString).pathExtension)?.identifier, payload: .photo(p), target: nil,
             account: account)
    }

    func deviceItem(_ d: DeviceItem) -> Item {
        Item(key: "dev:" + d.deviceID + ":" + d.itemID, name: d.name, isContainer: d.isFolder, size: d.isFolder ? nil : d.size, modified: d.modified,
             created: d.created, typeID: d.uti, payload: .device(d), target: d.isFolder ? .device(d.deviceID, d.itemID) : nil)
    }

    func libraries(account: String) async throws -> [PhotoLibraryRef] {
        if let l = libraryIndex[account] { return l }
        guard let photos = AccountManager.shared.account(id: account)?.photos else { throw ICloudError.needsSignIn }
        let file = cacheFile(account: account, library: "_", album: "_libraries")
        if AccountManager.shared.account(id: account)?.kind == .web, let d = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([PhotoLibraryRef].self, from: d), !cached.isEmpty {
            libraryIndex[account] = cached
            photos.remember(cached)
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
            if age < 86_400 { return cached }
            Task { @MainActor in
                if let fresh = try? await photos.libraries(), photos.librariesComplete() {
                    Catalog.shared.libraryIndex[account] = fresh
                    if let d = try? JSONEncoder().encode(fresh) { try? d.write(to: file, options: .atomic) }
                }
            }
            return cached
        }
        let libs = try await photos.libraries()
        // A list missing the Shared Library (it timed out) is used now but never cached.
        if photos.librariesComplete() {
            libraryIndex[account] = libs
            if let d = try? JSONEncoder().encode(libs) { try? d.write(to: file, options: .atomic) }
        }
        return libs
    }

    func library(account: String, id: String) async throws -> PhotoLibraryRef {
        if let l = try await libraries(account: account).first(where: { $0.id == id }) { return l }
        // Never substitute another library (a job could export or import the wrong one).
        throw ICloudError.server(id.hasPrefix("SharedSync") ? "The Shared Library didn’t respond. Try again in a moment." : "That Photos library isn’t available.")
    }

    func albums(account: String, library: String, refresh: Bool = false) async throws -> [PhotoAlbum] {
        let key = account + "|" + library
        if !refresh, let a = albumIndex[key] { return a }
        // Last known album list on disk: show it now, refresh quietly.
        let file = cacheFile(account: account, library: library, album: "_albums")
        if !refresh, AccountManager.shared.account(id: account)?.kind == .web,
           let d = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([PhotoAlbum].self, from: d) {
            albumIndex[key] = cached
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
            if age < 600 { return cached }
            Task { @MainActor in
                if let fresh = try? await Catalog.shared.albums(account: account, library: library, refresh: true), fresh != cached {
                    NotificationCenter.default.post(name: .cirrusLocationChanged, object: Location.photos(account, library, nil))
                }
            }
            return cached
        }
        guard let photos = AccountManager.shared.account(id: account)?.photos else { throw ICloudError.needsSignIn }
        let lib = try await self.library(account: account, id: library)
        let albums = try await photos.albums(in: lib)
        albumIndex[key] = albums
        if AccountManager.shared.account(id: account)?.kind == .web, let d = try? JSONEncoder().encode(albums) { try? d.write(to: file, options: .atomic) }
        return albums
    }

    func album(account: String, library: String, id: String) async throws -> PhotoAlbum {
        if let a = try await albums(account: account, library: library).first(where: { $0.id == id }) { return a }
        throw ICloudError.notFound
    }

    func cacheFile(account: String, library: String, album: String) -> URL {
        let dir = Paths.cacheDir("listings").appendingPathComponent(account.replacingOccurrences(of: ":", with: "_"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent((library + "-" + album).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".json")
    }

    func listAlbum(account: String, library: String, albumID: String, forced: Bool = false,
                   partial: @escaping @MainActor ([Item]) -> Void) async throws -> [Item] {
        guard let acct = AccountManager.shared.account(id: account), let photos = acct.photos else { throw ICloudError.needsSignIn }
        let lib = try await self.library(account: account, id: library)
        let album = try await self.album(account: account, library: library, id: albumID)
        let cacheURL = cacheFile(account: account, library: library, album: albumID)
        let useDiskCache = acct.kind == .web
        var cache: AlbumCache?
        if useDiskCache, let d = try? Data(contentsOf: cacheURL) {
            cache = (try? JSONDecoder().decode(AlbumCache.self, from: d))
                ?? (try? JSONDecoder().decode([PhotoAsset].self, from: d)).map { AlbumCache(assets: $0, token: nil, savedAt: .distantPast) }
        }
        if let c = cache, !forced {
            let items = c.assets.map { photoItem($0, account: account) }
            // Fresh enough: no network at all.
            if Date().timeIntervalSince(c.savedAt) < Self.albumFreshFor { return items }
            partial(items)
            // Ask CloudKit whether anything changed since this listing; if not, keep it.
            if let token = c.token, let (changed, newToken) = try? await photos.hasChanges(since: token, library: lib), !changed {
                save(AlbumCache(assets: c.assets, token: newToken ?? token, savedAt: Date()), to: cacheURL)
                Log.status("photos: album unchanged, served from cache (\(c.assets.count) items)")
                return items
            }
        }
        let hadCache = cache != nil
        // The change token must date from *before* the listing: one taken after it could hide changes
        // made while it ran, and the cache would then look current forever. No token yet = no shortcut.
        let tokenBefore = photos.syncToken(library: lib)
        let box = PartialBox()
        let assets = try await photos.assets(in: album, library: lib) { batch, _ in
            guard !hadCache else { return }
            let all = box.append(batch)
            Task { @MainActor in partial(all.map { Catalog.shared.photoItem($0, account: account) }) }
        }
        if useDiskCache { save(AlbumCache(assets: assets, token: tokenBefore, savedAt: Date()), to: cacheURL) }
        return assets.map { photoItem($0, account: account) }
    }

    func save(_ c: AlbumCache, to url: URL) { if let d = try? JSONEncoder().encode(c) { try? d.write(to: url, options: .atomic) } }

    /// Apply our own photo edits to every cached listing of that library (no re-download).
    func patchPhotos(account: String, library: String, updated: [PhotoAsset], removed: Set<String> = []) {
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for loc in Array(memory.keys) {
            guard case .album(let a, let l, let id) = loc, a == account, l == library, var items = memory[loc] else { continue }
            if id == "smart:Recently Deleted" || id == "smart:Favorites" || id == "smart:Hidden" { memory[loc] = nil; forceNext.insert(loc); continue }
            items.removeAll { $0.photo.map { removed.contains($0.id) } ?? false }
            items = items.map { it in
                guard let p = it.photo, let u = byID[p.id] else { return it }
                return photoItem(u, account: account)
            }
            memory[loc] = items
        }
        let dir = cacheFile(account: account, library: library, album: "x").deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard f.lastPathComponent.hasPrefix((library + "-").replacingOccurrences(of: ":", with: "_")),
                  let d = try? Data(contentsOf: f), var c = try? JSONDecoder().decode(AlbumCache.self, from: d) else { continue }
            let name = f.lastPathComponent
            if name.contains("Recently Deleted") || name.contains("Favorites") || name.contains("Hidden") { c.savedAt = .distantPast; save(c, to: f); continue }
            c.assets.removeAll { removed.contains($0.id) }
            c.assets = c.assets.map { byID[$0.id] ?? $0 }
            save(c, to: f)
        }
    }

    /// Our own change (or ⌘R): the next listing goes to the server, skipping caches.
    func invalidate(_ loc: Location) {
        memory[loc] = nil
        memoryAt[loc] = nil
        forceNext.insert(loc)
    }
}

final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [PhotoAsset]()
    func append(_ b: [PhotoAsset]) -> [PhotoAsset] { lock.withLock { items += b; return items } }
}
