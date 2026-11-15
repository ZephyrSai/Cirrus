import Foundation

/// What to move from iCloud to Google.
public struct MigrationOptions: Codable, Hashable, Sendable {
    public var includeDrive = true
    public var includePhotos = true
    /// A Live Photo arrives as the still plus a separate short video.
    public var includeLive = true
    public var includeEdited = false
    public var includeRAW = false
    public var includeHidden = false
    public var includeSharedLibrary = true
    public var albums = true
    /// iCloud Favorites become an album (the API can't set Google's own favorite flag).
    public var favoritesAlbum = true
    /// Re-upload files changed in iCloud since the last run (the old Google copy goes to Drive's trash).
    public var updateChanged = true
    public var excludes = SyncOptions().excludes
    public var folderName = "From iCloud"
    /// What Cirrus copied in from Google (Google → iCloud) is left out, so the two directions never loop.
    public var fromGoogleFolder = "From Google Drive"
    public var fromGoogleAlbum = "From Google Photos"
    public var concurrency = 3
    public init() {}
}

// MARK: - Manifest (what's already in Google), with an append-only journal so a crash loses nothing

struct MigrationManifest: Codable {
    struct DriveFile: Codable, Equatable { var id: String; var size: Int64; var mtime: Double }
    struct DriveUpload: Codable, Equatable { var url: String; var total: Int64; var mtime: Double; var started: Date }
    struct Photo: Codable, Equatable { var id: String; var size: Int64; var name: String? = nil }
    struct Token: Codable, Equatable { var token: String; var at: Date; var size: Int64; var description: String? }
    struct Album: Codable, Equatable { var id: String; var title: String; var added: Set<String> }

    var root: String?
    var rootName: String?
    var folders: [String: String] = [:]                          // iCloud path → Drive folder id
    var files: [String: DriveFile] = [:]                         // iCloud path → Drive file
    var driveUploads: [String: DriveUpload] = [:]                // unfinished resumable sessions
    var photos: [String: Photo] = [:]                            // item key → media item
    var photoUploads: [String: GooglePhotos.UploadSession] = [:] // unfinished resumable sessions
    var tokens: [String: Token] = [:]                            // uploaded, not yet turned into media items
    var albums: [String: Album] = [:]                            // iCloud album key → Google album
}

enum ManifestOp: Codable {
    case root(String?, String?)
    case folder(String, String)
    case file(String, MigrationManifest.DriveFile)
    case driveUpload(String, MigrationManifest.DriveUpload?)
    case photo(String, MigrationManifest.Photo)
    case photoUpload(String, GooglePhotos.UploadSession?)
    case token(String, MigrationManifest.Token?)
    case album(String, MigrationManifest.Album)
    case albumAdded(String, [String])
    case resetDrive

    func apply(_ m: inout MigrationManifest) {
        switch self {
        case .root(let id, let name): m.root = id; m.rootName = name
        case .folder(let rel, let id): m.folders[rel] = id
        case .file(let rel, let f): m.files[rel] = f
        case .driveUpload(let rel, let u): m.driveUploads[rel] = u
        case .photo(let k, let p): m.photos[k] = p
        case .photoUpload(let k, let s): m.photoUploads[k] = s
        case .token(let k, let t): m.tokens[k] = t
        case .album(let k, let a): m.albums[k] = a
        case .albumAdded(let k, let keys): m.albums[k]?.added.formUnion(keys)
        case .resetDrive: m.root = nil; m.rootName = nil; m.folders = [:]; m.files = [:]; m.driveUploads = [:]
        }
    }
}

extension ManifestOp: ManifestOperation { typealias Manifest = MigrationManifest }

typealias MigrationStore = JournalStore<ManifestOp>
extension JournalStore where Op == ManifestOp {
    convenience init(dir: URL, name: String) { self.init(dir: dir, name: name, empty: MigrationManifest()) }
}

// MARK: - Engine

/// iCloud → Google: iCloud Drive into a “From iCloud” folder in Google Drive, iCloud Photos into
/// Google Photos with albums. Reads iCloud only (never changes it), streams each file through a
/// small temporary folder, and records every finished item so reruns only send what's new.
public final class MigrationEngine: @unchecked Sendable {
    public struct Sources: Sendable {
        public var key: String                 // stable id of the iCloud account ("web:…", "mac", "demo")
        public var title: String
        public var drive: DriveBackend?
        public var nativeDriveRoot: URL?
        public var photos: PhotosBackend?
        public var storage: (@Sendable () async -> StorageUsage?)?
        public init(key: String, title: String, drive: DriveBackend?, nativeDriveRoot: URL?, photos: PhotosBackend?,
                    storage: (@Sendable () async -> StorageUsage?)? = nil) {
            self.key = key; self.title = title; self.drive = drive; self.nativeDriveRoot = nativeDriveRoot; self.photos = photos; self.storage = storage
        }
    }

    public struct Target: Sendable {
        public var api: GoogleAPI
        public var drive: GoogleDrive
        public var photos: GooglePhotos
        public init(api: GoogleAPI) { self.api = api; drive = GoogleDrive(api: api); photos = GooglePhotos(api: api) }
        public var accountID: String { api.accountID }
    }

    public struct DriveItem: Sendable {
        public var rel: String          // path under the Google folder
        var side: Int
        var sourceRel: String
        public var size: Int64
        public var mtime: Double
    }

    public struct PhotoItem: Sendable {
        public var key: String
        public var asset: PhotoAsset
        public var kind: PhotoResource.Kind
        public var fileName: String
        public var size: Int64
        public var isVideo: Bool
    }

    public struct Skipped: Sendable, Hashable {
        public var name: String
        public var size: Int64
        public var reason: String
    }

    public struct AlbumPlan: Sendable {
        public var key: String
        public var title: String
        public var members: [String]    // photo item keys
    }

    public struct Evaluation: Sendable {
        public var user: GoogleUser?
        public var quota: GoogleQuota?
        public var icloud: StorageUsage?
        public var driveEnabled = false
        public var photosEnabled = false
        public var driveFiles = 0
        public var driveBytes: Int64 = 0
        public var driveItems: [DriveItem] = []
        public var drivePending: [DriveItem] = []
        public var driveFolders: [String] = []
        public var assetCount = 0
        public var photoFiles = 0
        public var photoBytes: Int64 = 0
        public var photoItems: [PhotoItem] = []
        public var photoPending: [PhotoItem] = []
        public var albums: [AlbumPlan] = []
        public var albumAddsPending = 0
        public var skipped: [Skipped] = []
        public var warnings: [String] = []
        public var stagingFree: Int64 = .max
        public var stagingNeeded: Int64 = 0
        var sides: [SyncSide] = []

        public var drivePendingBytes: Int64 { drivePending.reduce(0) { $0 + $1.size } }
        public var photoPendingBytes: Int64 { photoPending.reduce(0) { $0 + $1.size } }
        public var pendingBytes: Int64 { drivePendingBytes + photoPendingBytes }
        /// What the move adds to Google storage, plus 1 % headroom.
        public var requiredGoogle: Int64 { pendingBytes + pendingBytes / 100 }
        public var googleFree: Int64? { quota?.free }
        public var fitsGoogle: Bool { googleFree.map { $0 >= requiredGoogle } ?? true }
        public var fitsStaging: Bool { stagingFree >= stagingNeeded }
        public var fits: Bool { fitsGoogle && fitsStaging }
        public var isUpToDate: Bool { drivePending.isEmpty && photoPending.isEmpty && albumAddsPending == 0 }
        /// Photos Library API calls this run needs (uploads + creates + album work), against 10,000 a day.
        public var photoRequests: Int {
            photoPending.reduce(0) { $0 + ($1.size > GooglePhotos.rawLimit ? 2 + Int($1.size / (8 << 20)) : 1) }
                + (photoPending.count + 49) / 50 + albums.count + (albumAddsPending + 49) / 50
        }
    }

    public struct Report: Sendable {
        public var driveCopied = 0
        public var driveUpdated = 0
        public var driveBytes: Int64 = 0
        public var foldersCreated = 0
        public var resumed = 0
        public var photosCreated = 0
        public var photosBytes: Int64 = 0
        public var albumsCreated = 0
        public var albumAdds = 0
        public var skipped: [Skipped] = []
        public var failed: [String] = []
        public var stopped: String?
        public var driveFolderID: String?
        public var driveFolderURL: URL? { driveFolderID.flatMap { URL(string: "https://drive.google.com/drive/folders/\($0)") } }

        public var summary: String {
            var parts = [String]()
            let d = driveCopied + driveUpdated
            if d > 0 { parts.append("\(d) file\(d == 1 ? "" : "s") to Google Drive" + (driveUpdated > 0 ? ", \(driveUpdated == d ? (d == 1 ? "an update" : "all updates") : "\(driveUpdated) of them updates")" : "")) }
            if photosCreated > 0 { parts.append("\(photosCreated) photo\(photosCreated == 1 ? "" : "s") and video\(photosCreated == 1 ? "" : "s") to Google Photos") }
            if albumsCreated > 0 { parts.append("\(albumsCreated) album\(albumsCreated == 1 ? "" : "s") created") }
            let skip = skipped.isEmpty ? "" : "\(skipped.count) skipped"
            if parts.isEmpty && failed.isEmpty {
                return (stopped == nil ? "Everything was already in Google" : "Nothing was copied") + (skip.isEmpty ? "" : " — " + skip)
            }
            let bytes = driveBytes + photosBytes
            var out = parts.isEmpty ? [] : [parts.joined(separator: ", ") + (bytes > 0 ? " (\(bytes.byteString))" : "")]
            if !failed.isEmpty { out.append("\(failed.count) failed") }
            if !skip.isEmpty { out.append(skip) }
            return out.joined(separator: ", ")
        }
    }

    static let sourceKey = "cirrusSource"

    public let sources: Sources
    public let target: Target
    public let options: MigrationOptions
    let store: MigrationStore
    let stagingDir: URL
    let sourceTag: String

    /// `stateDir` holds the manifest (one per iCloud account + Google account pair); `stagingDir` is scratch space.
    public init(sources: Sources, target: Target, options: MigrationOptions, stateDir: URL, stagingDir: URL) {
        self.sources = sources; self.target = target; self.options = options; self.stagingDir = stagingDir
        sourceTag = String(SHA256Hex.digest("cirrus-source|" + sources.key).prefix(20))
        let name = String(SHA256Hex.digest(sources.key + "→" + target.accountID).prefix(24))
        store = MigrationStore(dir: stateDir, name: name)
    }

    // MARK: Evaluate

    public func evaluate(progress: @escaping @Sendable (String) -> Void) async throws -> Evaluation {
        var ev = Evaluation()
        let api = target.api
        ev.driveEnabled = options.includeDrive && (sources.drive != nil || sources.nativeDriveRoot != nil) && api.has(GoogleScopes.driveFile)
        ev.photosEnabled = options.includePhotos && sources.photos != nil && api.has(GoogleScopes.photosAppend)
        if options.includeDrive && !api.has(GoogleScopes.driveFile) {
            ev.warnings.append("Google Drive access wasn’t granted, so iCloud Drive is left out. Connect Google again and tick the Drive box to include it.")
        }
        if options.includePhotos && !api.has(GoogleScopes.photosAppend) {
            ev.warnings.append("Google Photos access wasn’t granted, so photos are left out. Connect Google again and tick the Photos box to include them.")
        }
        if api.has(GoogleScopes.driveFile) {
            progress("Checking your Google storage…")
            let (user, quota) = try await target.drive.about()
            ev.user = user
            ev.quota = quota
        }
        if let s = sources.storage { progress("Reading iCloud storage…"); ev.icloud = await s() }

        if ev.driveEnabled { try await evaluateDrive(&ev, progress: progress) }
        if ev.photosEnabled, let pb = sources.photos { try await evaluatePhotos(&ev, backend: pb, progress: progress) }

        // Temporary space on this Mac: each file passes through it once, `concurrency` at a time.
        let stagedDrive = sources.drive != nil ? (ev.drivePending.map(\.size).max() ?? 0) : 0
        let largest = max(stagedDrive, ev.photoPending.map(\.size).max() ?? 0)
        ev.stagingNeeded = largest > 0 ? largest * Int64(max(1, options.concurrency)) + (256 << 20) : 0
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        ev.stagingFree = VolumeInfo.freeSpace(at: stagingDir) ?? .max
        addWarnings(&ev)
        return ev
    }

    func evaluateDrive(_ ev: inout Evaluation, progress: @escaping @Sendable (String) -> Void) async throws {
        if let id = store.value.root {
            progress("Checking the Google Drive folder…")
            let f = try await target.drive.get(id)
            if f == nil || f?.trashed == true {
                store.apply(.resetDrive)
                ev.warnings.append("The Google Drive folder from an earlier move was removed or is in Google Drive’s trash, so iCloud Drive will be copied again into a new “\(options.folderName)” folder.")
            }
        }
        if store.value.root == nil {
            // The local record can be missing (another Mac, cleared data): adopt this account's folder if Cirrus made one.
            let mine = try await target.drive.children("root").filter { $0.isFolder && $0.appProperties[Self.sourceKey] == sourceTag }
            if let f = mine.first {
                progress("Matching files already in Google Drive…")
                try await reconcile(root: f)
            }
        }
        var sides = [(String, SyncSide)]()
        if let d = sources.drive {
            sides.append(("", DriveSide(drive: d, rootID: d.rootID, label: "iCloud Drive", excludes: options.excludes)))
        } else if let root = sources.nativeDriveRoot {
            sides.append(("", LocalSide(root: root, excludes: options.excludes)))
            for c in NativeICloud.appContainers(root: root) {
                sides.append((Paths.safeName(c.name) + "/", LocalSide(root: c.url, excludes: options.excludes)))
            }
        }
        let m = store.value
        var folders = Set<String>()
        var fromGoogle = 0
        for (i, (prefix, side)) in sides.enumerated() {
            progress("Scanning iCloud Drive…")
            let entries = try await side.scan { n in progress("Scanning iCloud Drive… \(n) items") }
            if !prefix.isEmpty { folders.insert(String(prefix.dropLast())) }
            for (rel, e) in entries {
                let full = prefix + rel
                if prefix.isEmpty, rel == options.fromGoogleFolder || rel.hasPrefix(options.fromGoogleFolder + "/") {
                    if !e.isDir { fromGoogle += 1 }
                    continue
                }
                if e.isDir { folders.insert(full); continue }
                ev.driveFiles += 1
                ev.driveBytes += e.size
                if e.size > GoogleDrive.maxFileSize {
                    ev.skipped.append(Skipped(name: full, size: e.size, reason: "Larger than Google Drive’s 5 TB limit"))
                    continue
                }
                var dir = (full as NSString).deletingLastPathComponent
                while !dir.isEmpty { folders.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
                let item = DriveItem(rel: full, side: i, sourceRel: rel, size: e.size, mtime: e.mtime)
                ev.driveItems.append(item)
                if needsUpload(item, m) { ev.drivePending.append(item) }
            }
        }
        if fromGoogle > 0 {
            ev.warnings.append("“\(options.fromGoogleFolder)” (\(fromGoogle) file\(fromGoogle == 1 ? "" : "s")) is left out: Cirrus copied it from Google, so it’s there already.")
        }
        ev.sides = sides.map(\.1)
        ev.driveFolders = folders.sorted(by: SyncPlanner.pathOrder)
        ev.driveItems.sort { SyncPlanner.pathOrder($0.rel, $1.rel) }
        ev.drivePending.sort { SyncPlanner.pathOrder($0.rel, $1.rel) }
    }

    func needsUpload(_ item: DriveItem, _ m: MigrationManifest) -> Bool {
        guard let done = m.files[item.rel] else { return true }
        if done.size == item.size && abs(done.mtime - item.mtime) <= 2 { return false }
        return options.updateChanged
    }

    /// Rebuilds the record from what Cirrus's folder already holds in Google Drive.
    func reconcile(root: GDriveFile) async throws {
        store.apply(.root(root.id, root.name))
        var frontier = [(root.id, "")]
        while let (id, prefix) = frontier.popLast() {
            try Task.checkCancellation()
            for f in try await target.drive.children(id) {
                let rel = prefix.isEmpty ? f.name : prefix + "/" + f.name
                if f.isFolder { store.apply(.folder(rel, f.id)); frontier.append((f.id, rel)) }
                else { store.apply(.file(rel, .init(id: f.id, size: f.size, mtime: f.modified?.timeIntervalSince1970 ?? 0))) }
            }
        }
        store.compact()
    }

    func photoFiles(_ a: PhotoAsset) -> [(PhotoResource.Kind, String, Int64)] {
        let stem = (a.filename as NSString).deletingPathExtension
        func ext(_ r: PhotoResource, _ fallback: String) -> String {
            let e = (r.filename as NSString).pathExtension
            return e.isEmpty ? fallback : e
        }
        var out: [(PhotoResource.Kind, String, Int64)] = [(.original, a.filename, a.resource(.original)?.size ?? a.size)]
        if options.includeLive, let r = a.resource(.liveVideo) { out.append((.liveVideo, stem + "." + ext(r, "MOV"), r.size)) }
        if options.includeEdited, let r = a.resource(.edited) { out.append((.edited, stem + "-edited." + ext(r, "JPG"), r.size)) }
        if options.includeRAW, let r = a.resource(.alternate) {
            let e = ext(r, "DNG")
            let name = e.lowercased() == (a.filename as NSString).pathExtension.lowercased() ? stem + "-alt." + e : stem + "." + e
            out.append((.alternate, name, r.size))
        }
        return out
    }

    func evaluatePhotos(_ ev: inout Evaluation, backend pb: PhotosBackend, progress: @escaping @Sendable (String) -> Void) async throws {
        let m = store.value
        var titles = Set<String>()
        func unique(_ t: String) -> String {
            var name = t, n = 2
            while titles.contains(name.lowercased()) { name = "\(t) (\(n))"; n += 1 }
            titles.insert(name.lowercased())
            return name
        }
        for lib in try await pb.libraries() where !lib.isShared || options.includeSharedLibrary {
            let albums = try await pb.albums(in: lib)
            var sourcesList = [PhotoAlbum]()
            if let all = albums.first(where: { $0.isAllPhotos || $0.id == "smart:all" }) { sourcesList.append(all) }
            if options.includeHidden, let h = albums.first(where: { $0.id == "smart:Hidden" || ($0.name == "Hidden" && $0.kind == .smart) }) { sourcesList.append(h) }
            var assets = [PhotoAsset]()
            var seen = Set<String>()
            for src in sourcesList {
                let label = src.name
                let counter = Counter()
                let list = try await pb.assets(in: src, library: lib) { batch, total in
                    counter.add(files: batch.count)
                    progress("Listing \(label)… \(counter.snapshot().files)\(total.map { " of \($0)" } ?? "")")
                }
                for a in list where seen.insert(a.id).inserted { assets.append(a) }
            }
            // Photos Cirrus brought in from Google Photos aren't sent back.
            if let back = albums.first(where: { $0.kind == .album && $0.name == options.fromGoogleAlbum }) {
                let ids = Set(((try? await pb.assets(in: back, library: lib) { _, _ in }) ?? []).map(\.id))
                let before = assets.count
                assets.removeAll { ids.contains($0.id) }
                if before > assets.count {
                    ev.warnings.append("\(before - assets.count) photo\(before - assets.count == 1 ? "" : "s") in “\(options.fromGoogleAlbum)” \(before - assets.count == 1 ? "is" : "are") left out: \(before - assets.count == 1 ? "it" : "they") came from Google Photos.")
                }
            }
            ev.assetCount += assets.count
            var primary = [String: String]()   // asset id → key of its main file
            for a in assets.sorted(by: { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }) {
                for (kind, name, size) in photoFiles(a) {
                    if let why = GooglePhotos.problem(name: name, size: size) {
                        ev.skipped.append(Skipped(name: name, size: size, reason: why))
                        continue
                    }
                    let key = "\(lib.id)|\(a.id)|\(kind.rawValue)"
                    if primary[a.id] == nil { primary[a.id] = key }
                    ev.photoFiles += 1
                    ev.photoBytes += size
                    let item = PhotoItem(key: key, asset: a, kind: kind, fileName: name, size: size, isVideo: GooglePhotos.media(for: name) == .video)
                    ev.photoItems.append(item)
                    if m.photos[key] == nil { ev.photoPending.append(item) }
                }
            }
            let suffix = lib.isShared ? " (Shared Library)" : ""
            func addPlan(_ key: String, _ title: String, _ members: [String]) {
                guard !members.isEmpty else { return }
                // Google albums hold 20,000 items at most.
                for (i, part) in members.chunked(GooglePhotos.albumLimit).enumerated() {
                    ev.albums.append(AlbumPlan(key: i == 0 ? key : "\(key)#\(i + 1)", title: unique(i == 0 ? title : "\(title) (part \(i + 1))"), members: part))
                }
            }
            if options.albums {
                for al in albums where al.kind == .album {
                    progress("Reading album “\(al.name)”…")
                    let list = (try? await pb.assets(in: al, library: lib) { _, _ in }) ?? []
                    addPlan("\(lib.id)|\(al.id)", al.name + suffix, list.compactMap { primary[$0.id] })
                }
            }
            if options.favoritesAlbum {
                addPlan("\(lib.id)|favorites", "Favorites from iCloud" + suffix, assets.filter(\.isFavorite).compactMap { primary[$0.id] })
            }
        }
        for plan in ev.albums {
            let added = m.albums[plan.key]?.added ?? []
            ev.albumAddsPending += plan.members.filter { !added.contains($0) }.count
        }
    }

    func addWarnings(_ ev: inout Evaluation) {
        if !ev.fitsGoogle, let free = ev.googleFree {
            ev.warnings.append("Not enough Google storage: this move needs \(ev.requiredGoogle.byteString) (with 1 % headroom) but your Google account has \(free.byteString) free — Drive, Gmail and Photos share it. Free up space, add Google storage, or leave something out.")
        }
        if !ev.fitsStaging {
            ev.warnings.append("Cirrus passes each file through a temporary folder on this Mac and needs \(ev.stagingNeeded.byteString) free there; only \(ev.stagingFree.byteString) is available.")
        }
        if ev.drivePendingBytes > GoogleDrive.dailyUploadLimit {
            ev.warnings.append("Google accepts about 750 GB of uploads a day. This move is bigger, so it pauses when Google says so; run it again the next day and it continues where it stopped.")
        }
        let requests = ev.photoRequests
        if requests > 9_000 {
            ev.warnings.append("Google Photos allows 10,000 API requests a day per Google Cloud project, and this move needs about \(requests.formatted()). It will take about \((requests + 9_499) / 9_500) days: run it once a day and it continues each time.")
        }
        let live = ev.photoPending.filter { $0.kind == .liveVideo }.count
        if live > 0 { ev.warnings.append("Live Photos become a still photo plus a separate short video in Google Photos (\(live) video\(live == 1 ? "" : "s")).") }
        if options.includeHidden && ev.photosEnabled {
            ev.warnings.append("Hidden photos will be visible in Google Photos: Google’s Locked Folder can’t be filled by other apps.")
        }
        if ev.photosEnabled && !ev.photoPending.isEmpty {
            ev.warnings.append("Google Photos stores these at original quality, so they count toward your Google storage.")
        }
        if !ev.skipped.isEmpty {
            ev.warnings.append("\(ev.skipped.count) file\(ev.skipped.count == 1 ? " is" : "s are") skipped because Google can’t store \(ev.skipped.count == 1 ? "it" : "them") (listed below).")
        }
    }

    // MARK: Run

    final class RunContext: @unchecked Sendable {
        private let lock = NSLock()
        private var report = Report()
        private var bytes: Int64 = 0
        private var files = 0
        private var phaseText = "Starting…"
        private var stopError: GoogleError?
        let filesTotal: Int
        let bytesTotal: Int64
        let progress: @Sendable (RunProgress) -> Void

        init(filesTotal: Int, bytesTotal: Int64, progress: @escaping @Sendable (RunProgress) -> Void) {
            self.filesTotal = filesTotal; self.bytesTotal = bytesTotal; self.progress = progress
        }

        func emit() {
            let p = lock.withLock { RunProgress(phase: phaseText, filesDone: files, filesTotal: filesTotal, bytesDone: min(bytes, bytesTotal), bytesTotal: bytesTotal) }
            progress(p)
        }
        func addBytes(_ d: Int64) { guard d > 0 else { return }; lock.withLock { bytes += d }; emit() }
        func doneFile() { lock.withLock { files += 1 }; emit() }
        func phase(_ s: String) { lock.withLock { phaseText = s }; emit() }
        func mutate(_ f: (inout Report) -> Void) { lock.withLock { f(&report) } }
        func fail(_ name: String, _ e: Error) {
            Log.error("migration failed for \(name): \(e.localizedDescription)")
            mutate { $0.failed.append("\(name): \(e.localizedDescription)") }
        }
        func stop(_ e: GoogleError) { lock.withLock { if stopError == nil { stopError = e } } }
        var stopped: GoogleError? { lock.withLock { stopError } }
        var value: Report { lock.withLock { var r = report; r.stopped = stopError?.localizedDescription; return r } }
    }

    final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items = [String: GooglePhotos.NewItem]()
        func set(_ k: String, _ v: GooglePhotos.NewItem) { lock.withLock { items[k] = v } }
        func get(_ k: String) -> GooglePhotos.NewItem? { lock.withLock { items[k] } }
    }

    static func forEach<T: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = items.makeIterator()
            var inFlight = 0
            while inFlight < max(1, limit), let x = it.next() { group.addTask { try await body(x) }; inFlight += 1 }
            while try await group.next() != nil {
                if let x = it.next() { group.addTask { try await body(x) } }
            }
        }
    }

    public static func isCancel(_ e: Error) -> Bool {
        e is CancellationError || (e as? GoogleError) == .cancelled || (e as? ICloudError) == .cancelled || (e as? URLError)?.code == .cancelled
    }

    static func stops(_ e: Error) -> GoogleError? {
        guard let g = e as? GoogleError else { return nil }
        switch g {
        case .storageFull, .dailyLimit, .reconnect, .missingScope, .rateLimited, .notConfigured: return g
        default: return nil
        }
    }

    public func run(_ ev: Evaluation, progress: @escaping @Sendable (RunProgress) -> Void) async throws -> Report {
        guard ev.fitsGoogle else { throw SyncError.unavailable("Not enough Google storage for this move: it needs \(ev.requiredGoogle.byteString), \((ev.googleFree ?? 0).byteString) is free.") }
        guard ev.fitsStaging else { throw SyncError.notEnoughSpace(need: ev.stagingNeeded, free: ev.stagingFree) }
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)   // leftovers of an interrupted run (Cirrus's own temporary copies)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stagingDir); store.compact() }

        let m = store.value
        let drive = ev.driveEnabled ? ev.driveItems.filter { needsUpload($0, m) } : []
        let photos = ev.photosEnabled ? ev.photoItems.filter { m.photos[$0.key] == nil } : []
        // Each byte is counted twice: once coming down from iCloud, once going up to Google.
        let bytes = (drive.reduce(0) { $0 + $1.size } + photos.reduce(0) { $0 + $1.size }) * 2
        let ctx = RunContext(filesTotal: drive.count + photos.count, bytesTotal: bytes, progress: progress)
        ctx.mutate { $0.skipped = ev.skipped }

        if ev.driveEnabled {
            do { try await runDrive(ev, items: drive, ctx: ctx) } catch {
                if Self.isCancel(error) { throw CancellationError() }
                guard let s = Self.stops(error) else { throw error }
                ctx.stop(s)
            }
        }
        if ev.photosEnabled && ctx.stopped != .storageFull && ctx.stopped.map({ if case .reconnect = $0 { return false }; return true }) ?? true {
            // Drive's daily cap doesn't apply to Photos, so a Drive stop for that reason still lets Photos run.
            let driveStop = ctx.stopped
            let photoCtx = driveStop == nil ? ctx : RunContext(filesTotal: photos.count, bytesTotal: photos.reduce(0) { $0 + $1.size } * 2, progress: progress)
            do {
                try await runPhotos(items: photos, ctx: photoCtx)
                if photoCtx.stopped == nil { try await runAlbums(ev, ctx: photoCtx) }
            } catch {
                if Self.isCancel(error) { throw CancellationError() }
                guard let s = Self.stops(error) else { throw error }
                photoCtx.stop(s)
            }
            if photoCtx !== ctx {
                let p = photoCtx.value
                ctx.mutate { r in
                    r.photosCreated = p.photosCreated; r.photosBytes = p.photosBytes; r.albumsCreated = p.albumsCreated; r.albumAdds = p.albumAdds
                    r.failed += p.failed
                }
                if let s = photoCtx.stopped { ctx.mutate { $0.failed.append("Google Photos: \(s.localizedDescription)") } }
            }
        }
        ctx.mutate { $0.driveFolderID = self.store.value.root }
        ctx.phase("Finished")
        return ctx.value
    }

    // MARK: Drive

    func ensureRoot(_ ctx: RunContext) async throws -> String {
        if let id = store.value.root { return id }
        let tagged = try await target.drive.children("root").filter { $0.isFolder && $0.appProperties[Self.sourceKey] != nil }
        if let mine = tagged.first(where: { $0.appProperties[Self.sourceKey] == sourceTag }) {
            store.apply(.root(mine.id, mine.name))
            return mine.id
        }
        var name = options.folderName
        if tagged.contains(where: { $0.name == name }) { name += " (\(sources.title))" }
        let f = try await target.drive.createFolder(name, parent: "root", appProperties: [Self.sourceKey: sourceTag])
        store.apply(.root(f.id, f.name))
        ctx.mutate { $0.foldersCreated += 1 }
        return f.id
    }

    /// Creates missing folders parents-first (sequentially, so none is made twice).
    func ensureFolders(_ rels: [String], root: String, ctx: RunContext) async throws {
        var listed = [String: [GDriveFile]]()
        var createdHere = Set<String>()
        for rel in rels.sorted(by: SyncPlanner.pathOrder) {
            try Task.checkCancellation()
            if store.value.folders[rel] != nil { continue }
            let parentRel = (rel as NSString).deletingLastPathComponent
            guard let parent = parentRel.isEmpty ? root : store.value.folders[parentRel] else { continue }
            let name = (rel as NSString).lastPathComponent
            // A folder made just before a crash isn't in the record yet; reuse it instead of making a twin.
            if !createdHere.contains(parentRel) {
                if listed[parent] == nil { listed[parent] = try await target.drive.children(parent) }
                if let existing = listed[parent]?.first(where: { $0.isFolder && $0.name == name }) {
                    store.apply(.folder(rel, existing.id))
                    continue
                }
            }
            ctx.phase("Creating folder \(name)…")
            let f = try await target.drive.createFolder(name, parent: parent)
            store.apply(.folder(rel, f.id))
            createdHere.insert(rel)
            ctx.mutate { $0.foldersCreated += 1 }
        }
    }

    func runDrive(_ ev: Evaluation, items: [DriveItem], ctx: RunContext) async throws {
        ctx.phase("Preparing Google Drive…")
        let root = try await ensureRoot(ctx)
        ctx.mutate { $0.driveFolderID = root }
        var needed = Set(ev.driveFolders)
        for i in items {
            var dir = (i.rel as NSString).deletingLastPathComponent
            while !dir.isEmpty { needed.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        try await ensureFolders(Array(needed), root: root, ctx: ctx)
        try await Self.forEach(items, limit: options.concurrency) { item in
            if ctx.stopped != nil { return }
            do { try await self.uploadDriveItem(item, ev: ev, root: root, ctx: ctx) } catch {
                if Self.isCancel(error) { throw CancellationError() }
                if let s = Self.stops(error) { ctx.stop(s); return }
                ctx.fail(item.rel, error)
            }
            ctx.doneFile()
        }
    }

    static func size(_ u: URL) -> Int64? { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }

    func uploadDriveItem(_ item: DriveItem, ev: Evaluation, root: String, ctx: RunContext) async throws {
        let parentRel = (item.rel as NSString).deletingLastPathComponent
        guard let parent = parentRel.isEmpty ? root : store.value.folders[parentRel] else {
            throw SyncError.unavailable("Its folder couldn’t be created in Google Drive.")
        }
        let name = (item.rel as NSString).lastPathComponent
        ctx.phase("Downloading \(name) from iCloud…")
        let side = ev.sides[item.side]
        let down = ByteMark()
        let local: URL, temporary: Bool
        if let ds = side as? DriveSide, let node = ds.node(item.sourceRel) {
            let dir = stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            local = dir.appendingPathComponent(Paths.safeName(node.name))
            temporary = true
            do {
                try await ds.drive.download(node, to: local) { d, _ in ctx.addBytes(down.advance(to: d)) }
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        } else {
            let r = try await side.fetch(item.sourceRel) { d, _ in ctx.addBytes(down.advance(to: d)) }
            local = r.url
            temporary = r.isTemporary
        }
        defer { if temporary { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) } }
        ctx.addBytes(down.advance(to: item.size))   // top up (native files report no download progress)
        let size = Self.size(local) ?? item.size
        let up = ByteMark()
        let onUp: @Sendable (Int64, Int64) -> Void = { d, _ in ctx.addBytes(up.advance(to: d)) }
        let mtime = Date(timeIntervalSince1970: item.mtime)
        ctx.phase("Uploading \(name) to Google Drive…")

        func fresh() async throws -> GDriveFile {
            let s = try await target.drive.startUpload(name: name, parent: parent, size: size, modified: mtime)
            store.apply(.driveUpload(item.rel, .init(url: s.url, total: size, mtime: item.mtime, started: s.started)))
            return try await target.drive.upload(local, session: s, resume: false, progress: onUp)
        }
        var file: GDriveFile
        if let u = store.value.driveUploads[item.rel], u.total == size, abs(u.mtime - item.mtime) <= 2, Date().timeIntervalSince(u.started) < 6 * 86_400 {
            do {
                file = try await target.drive.upload(local, session: .init(url: u.url, total: u.total, started: u.started), resume: true, progress: onUp)
                ctx.mutate { $0.resumed += 1 }
            } catch GoogleError.uploadExpired { file = try await fresh() }
        } else {
            do { file = try await fresh() } catch GoogleError.uploadExpired { file = try await fresh() }
        }
        let old = store.value.files[item.rel]
        store.apply(.file(item.rel, .init(id: file.id, size: size, mtime: item.mtime)))
        store.apply(.driveUpload(item.rel, nil))
        if let old, old.id != file.id {
            // Upload-then-replace: the earlier copy goes to Google Drive's trash, never deleted.
            do { try await target.drive.trash(old.id) } catch { Log.error("couldn’t move the previous copy to Drive’s trash: \(error.localizedDescription)") }
            ctx.mutate { $0.driveUpdated += 1; $0.driveBytes += size }
        } else {
            ctx.mutate { $0.driveCopied += 1; $0.driveBytes += size }
        }
    }

    // MARK: Photos

    func runPhotos(items: [PhotoItem], ctx: RunContext) async throws {
        guard !items.isEmpty else { return }
        for chunk in items.chunked(GooglePhotos.batchLimit) {
            try Task.checkCancellation()
            if ctx.stopped != nil { return }
            let ready = TokenBox()
            try await Self.forEach(chunk, limit: options.concurrency) { item in
                if ctx.stopped != nil { return }
                do { ready.set(item.key, try await self.uploadPhoto(item, ctx: ctx)) } catch {
                    if Self.isCancel(error) { throw CancellationError() }
                    if let s = Self.stops(error) { ctx.stop(s); return }
                    ctx.fail(item.fileName, error)
                    ctx.doneFile()
                }
            }
            if ctx.stopped != nil { return }   // uploaded tokens stay recorded for the next run
            let batch = chunk.compactMap { i in ready.get(i.key).map { (i, $0) } }
            guard !batch.isEmpty else { continue }
            ctx.phase("Adding \(batch.count) item\(batch.count == 1 ? "" : "s") to Google Photos…")
            let results: [GooglePhotos.Created]
            do { results = try await target.photos.batchCreate(batch.map(\.1)) } catch {
                if Self.isCancel(error) { throw CancellationError() }
                if let s = Self.stops(error) { ctx.stop(s); return }
                // The upload tokens stay valid for a day, so the next run retries without uploading again.
                for (i, _) in batch { ctx.fail(i.fileName, error); ctx.doneFile() }
                continue
            }
            for ((item, _), r) in zip(batch, results) {
                store.apply(.token(item.key, nil))
                if let id = r.mediaItemID {
                    store.apply(.photo(item.key, .init(id: id, size: item.size, name: item.fileName)))
                    ctx.mutate { $0.photosCreated += 1; $0.photosBytes += item.size }
                } else {
                    ctx.fail(item.fileName, GoogleError.badResponse(r.error ?? "Google Photos didn’t create this item."))
                }
                ctx.doneFile()
            }
        }
    }

    func uploadPhoto(_ item: PhotoItem, ctx: RunContext) async throws -> GooglePhotos.NewItem {
        if let t = store.value.tokens[item.key], t.size == item.size, Date().timeIntervalSince(t.at) < 20 * 3600 {
            ctx.addBytes(item.size * 2)
            return GooglePhotos.NewItem(token: t.token, fileName: item.fileName, description: t.description)
        }
        guard let backend = sources.photos else { throw SyncError.unavailable("Photos isn’t available.") }
        let dir = stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(Paths.safeName(item.fileName))
        ctx.phase("Downloading \(item.fileName) from iCloud…")
        let down = ByteMark()
        try await backend.export(item.asset, resource: item.kind, to: file) { d, _ in ctx.addBytes(down.advance(to: min(d, item.size))) }
        ctx.addBytes(down.advance(to: item.size))
        let size = Self.size(file) ?? item.size
        let dated = await MediaDates.hasEmbeddedDate(file, video: item.isVideo)
        let desc = dated ? nil : MediaDates.description(for: item.asset.created)
        ctx.phase("Uploading \(item.fileName) to Google Photos…")
        let up = ByteMark()
        let onUp: @Sendable (Int64, Int64) -> Void = { d, _ in ctx.addBytes(up.advance(to: min(d, item.size))) }
        var token: String?
        if size <= GooglePhotos.rawLimit {
            token = try await target.photos.uploadRaw(file, name: item.fileName, progress: onUp)
        } else {
            if let s = store.value.photoUploads[item.key], s.total == size, Date().timeIntervalSince(s.started) < 6 * 86_400 {
                do { token = try await target.photos.uploadResumable(file, session: s, resume: true, progress: onUp); ctx.mutate { $0.resumed += 1 } }
                catch GoogleError.uploadExpired { token = nil }
            }
            if token == nil {
                let s = try await target.photos.startResumable(name: item.fileName, size: size)
                store.apply(.photoUpload(item.key, s))
                token = try await target.photos.uploadResumable(file, session: s, resume: false, progress: onUp)
            }
            store.apply(.photoUpload(item.key, nil))
        }
        let t = token ?? ""
        store.apply(.token(item.key, .init(token: t, at: Date(), size: item.size, description: desc)))
        return GooglePhotos.NewItem(token: t, fileName: item.fileName, description: desc)
    }

    func runAlbums(_ ev: Evaluation, ctx: RunContext) async throws {
        for plan in ev.albums {
            try Task.checkCancellation()
            let m = store.value
            let existing = m.albums[plan.key]
            let toAdd = plan.members.filter { m.photos[$0] != nil && !(existing?.added.contains($0) ?? false) }
            guard !toAdd.isEmpty else { continue }
            ctx.phase("Album “\(plan.title)”…")
            var album = existing
            if album == nil {
                let id = try await target.photos.createAlbum(plan.title)
                album = MigrationManifest.Album(id: id, title: plan.title, added: [])
                store.apply(.album(plan.key, album!))
                ctx.mutate { $0.albumsCreated += 1 }
            }
            for part in toAdd.chunked(GooglePhotos.batchLimit) {
                let ids = part.compactMap { m.photos[$0]?.id }
                do {
                    try await target.photos.addToAlbum(album!.id, ids)
                    store.apply(.albumAdded(plan.key, part))
                    ctx.mutate { $0.albumAdds += part.count }
                } catch {
                    if Self.isCancel(error) || Self.stops(error) != nil { throw error }
                    ctx.fail("Album “\(plan.title)”", error)
                    break
                }
            }
        }
    }
}
