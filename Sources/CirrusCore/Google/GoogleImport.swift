import Foundation

/// What to bring from Google into iCloud.
public struct ImportOptions: Codable, Hashable, Sendable {
    public var includeDrive = true
    public var includePhotos = true
    public var docFormat: GoogleDocFormat = .office
    /// Live Photo and motion-photo video parts (a Live Photo is paired again when this Mac's Photos library is the target).
    public var includeLive = true
    public var includeEdited = false
    public var albums = true
    public var favorites = true
    /// Copy files again when they changed in Google (the old iCloud copy goes to the Trash / Recently Deleted).
    public var updateChanged = true
    public var folderName = "From Google Drive"
    public var photosAlbumName = "From Google Photos"
    public var concurrency = 3
    public init() {}
}

/// A photo the user picked with Google Photos' picker (see GooglePicker).
public struct GooglePickedItem: Codable, Sendable, Hashable {
    public var id: String
    public var fileName: String
    public var mimeType: String
    public var baseURL: String
    public var created: Date?
    public var isVideo: Bool
    public init(id: String, fileName: String, mimeType: String, baseURL: String, created: Date?, isVideo: Bool) {
        self.id = id; self.fileName = fileName; self.mimeType = mimeType; self.baseURL = baseURL; self.created = created; self.isVideo = isVideo
    }
}

// MARK: - Manifest

struct ImportManifest: Codable {
    struct DriveFile: Codable, Equatable { var rel: String; var version: String; var size: Int64 }
    struct Photo: Codable, Equatable { var name: String; var size: Int64; var id: String? = nil }   // id: the iCloud asset
    struct Album: Codable, Equatable { var id: String; var title: String; var added: Set<String> }
    var files: [String: DriveFile] = [:]     // Google file id → its copy in iCloud Drive
    var photos: [String: Photo] = [:]        // item key → the file iCloud Photos received
    var albums: [String: Album] = [:]        // Google album title → iCloud album
    var provenance: Album?                   // “From Google Photos”
    var favorited: Set<String> = []
}

enum ImportOp: ManifestOperation {
    typealias Manifest = ImportManifest
    case file(String, ImportManifest.DriveFile)
    case photo(String, ImportManifest.Photo)
    case album(String, ImportManifest.Album)
    case albumAdded(String, [String])
    case provenance(ImportManifest.Album?)
    case provenanceAdded([String])
    case favorited([String])

    func apply(_ m: inout ImportManifest) {
        switch self {
        case .file(let id, let f): m.files[id] = f
        case .photo(let k, let p): m.photos[k] = p
        case .album(let t, let a): m.albums[t] = a
        case .albumAdded(let t, let keys): m.albums[t]?.added.formUnion(keys)
        case .provenance(let a): m.provenance = a
        case .provenanceAdded(let keys): m.provenance?.added.formUnion(keys)
        case .favorited(let keys): m.favorited.formUnion(keys)
        }
    }
}

// MARK: - Engine

/// Google → iCloud: My Drive into a “From Google Drive” folder in iCloud Drive (Docs, Sheets and
/// Slides exported as Office files or PDF), and Google Photos — from a Takeout export or the
/// Google Photos picker — into iCloud Photos with their dates, places, captions, albums and favorites.
/// Only ever adds to iCloud; replaced copies go to the Trash / Recently Deleted. Honors read-only mode.
public final class ImportEngine: @unchecked Sendable {
    public struct Source: Sendable {
        public var api: GoogleAPI
        public var takeout: [URL]
        public var picked: [GooglePickedItem]
        public init(api: GoogleAPI, takeout: [URL] = [], picked: [GooglePickedItem] = []) { self.api = api; self.takeout = takeout; self.picked = picked }
    }

    public struct Target: Sendable {
        public var key: String
        public var title: String
        public var drive: DriveBackend?
        public var nativeDriveRoot: URL?
        public var photos: PhotosBackend?
        public var storage: (@Sendable () async -> StorageUsage?)?
        /// Uploads go through iCloud.com (sign-in inside Cirrus), not this Mac's own iCloud.
        public var isWeb: Bool
        public init(key: String, title: String, drive: DriveBackend?, nativeDriveRoot: URL?, photos: PhotosBackend?,
                    storage: (@Sendable () async -> StorageUsage?)? = nil, isWeb: Bool) {
            self.key = key; self.title = title; self.drive = drive; self.nativeDriveRoot = nativeDriveRoot; self.photos = photos
            self.storage = storage; self.isWeb = isWeb
        }
    }

    public struct DriveItem: Sendable {
        public var id: String
        public var rel: String
        public var size: Int64?          // nil until a Google Doc is exported
        public var export: GoogleDocFormat.Target?
        public var item: GDriveItem
    }

    public enum PhotoSource: Sendable { case takeout(TakeoutItem), picker(GooglePickedItem) }

    public struct PhotoItem: Sendable {
        public var key: String
        public var source: PhotoSource
        public var fileName: String
        public var size: Int64
        public var taken: Date?
        public var isVideo: Bool
        public var group: String
        public var albums: [String]
        public var favorite: Bool
        public var isCompanion: Bool
        /// The picker doesn't tell sizes: until downloaded, a typical size stands in.
        public var sizeIsEstimate = false
    }

    public struct AlbumPlan: Sendable { public var title: String; public var members: [String] }

    public struct Evaluation: Sendable {
        public var user: GoogleUser?
        public var icloud: StorageUsage?
        public var driveEnabled = false
        public var photosEnabled = false
        public var readOnly = false
        public var driveFiles = 0
        public var driveBytes: Int64 = 0
        public var docs = 0
        public var driveItems: [DriveItem] = []
        public var drivePending: [DriveItem] = []
        public var driveFolders: [String] = []
        public var photoItems: [PhotoItem] = []
        public var photoPending: [PhotoItem] = []
        public var albums: [AlbumPlan] = []
        public var albumAddsPending = 0
        public var favoritesPending = 0
        public var takeoutParts = 0
        public var takeoutItems = 0
        public var pickedItems = 0
        public var sizesEstimated: Bool { drivePending.contains { $0.export != nil } || photoPending.contains(where: \.sizeIsEstimate) }
        public var skipped: [MigrationEngine.Skipped] = []
        public var warnings: [String] = []
        public var stagingFree: Int64 = .max
        public var stagingNeeded: Int64 = 0

        /// Google Docs have no size until exported; count 2 MB each for the space check.
        public static let docEstimate: Int64 = 2 << 20
        public var drivePendingBytes: Int64 { drivePending.reduce(0) { $0 + ($1.size ?? Self.docEstimate) } }
        public var photoPendingBytes: Int64 { photoPending.reduce(0) { $0 + $1.size } }
        public var pendingBytes: Int64 { drivePendingBytes + photoPendingBytes }
        public var requiredICloud: Int64 { pendingBytes + pendingBytes / 100 }
        public var icloudFree: Int64? { icloud.flatMap { $0.total > 0 ? $0.available : nil } }
        public var fitsICloud: Bool { icloudFree.map { $0 >= requiredICloud } ?? true }
        public var fitsStaging: Bool { stagingFree >= stagingNeeded }
        public var fits: Bool { fitsICloud && fitsStaging && !readOnly }
        public var isUpToDate: Bool { drivePending.isEmpty && photoPending.isEmpty && albumAddsPending == 0 && favoritesPending == 0 }
    }

    public struct Report: Sendable {
        public var driveCopied = 0
        public var driveUpdated = 0
        public var docsExported = 0
        public var driveBytes: Int64 = 0
        public var photosImported = 0
        public var photosBytes: Int64 = 0
        public var albumsCreated = 0
        public var albumAdds = 0
        public var favoritesSet = 0
        public var unmatched = 0
        public var skipped: [MigrationEngine.Skipped] = []
        public var failed: [String] = []
        public var stopped: String?

        public var summary: String {
            var parts = [String]()
            let d = driveCopied + driveUpdated
            if d > 0 { parts.append("\(d) file\(d == 1 ? "" : "s") to iCloud Drive" + (docsExported > 0 ? " (\(docsExported) Google Doc\(docsExported == 1 ? "" : "s") exported)" : "")) }
            if photosImported > 0 { parts.append("\(photosImported) photo\(photosImported == 1 ? "" : "s") and video\(photosImported == 1 ? "" : "s") to iCloud Photos") }
            if albumsCreated > 0 { parts.append("\(albumsCreated) album\(albumsCreated == 1 ? "" : "s") created") }
            if favoritesSet > 0 { parts.append("\(favoritesSet) favorite\(favoritesSet == 1 ? "" : "s") marked") }
            let skip = skipped.isEmpty ? "" : "\(skipped.count) skipped"
            if parts.isEmpty && failed.isEmpty {
                return (stopped == nil ? "Everything was already in iCloud" : "Nothing was copied") + (skip.isEmpty ? "" : " — " + skip)
            }
            let bytes = driveBytes + photosBytes
            var out = parts.isEmpty ? [] : [parts.joined(separator: ", ") + (bytes > 0 ? " (\(bytes.byteString))" : "")]
            if !failed.isEmpty { out.append("\(failed.count) failed") }
            if !skip.isEmpty { out.append(skip) }
            return out.joined(separator: ", ")
        }
    }

    /// Apple: iCloud Drive files up to 50 GB. iCloud.com uploads above ~10 GB have failed for people (same note as Preflight).
    public static let iCloudDriveMax: Int64 = 50_000_000_000
    public static let iCloudWebSoft: Int64 = 10_000_000_000

    public let source: Source
    public let target: Target
    public let options: ImportOptions
    let store: JournalStore<ImportOp>
    let stagingDir: URL
    let stateDir: URL
    let isReadOnly: @Sendable () -> Bool
    let trash: @Sendable (URL, URL) throws -> Void

    /// `readOnly` and `trash` are injectable for tests (defaults: Settings › Safety, and the Trash).
    public init(source: Source, target: Target, options: ImportOptions, stateDir: URL, stagingDir: URL,
                readOnly: (@Sendable () -> Bool)? = nil, trash: (@Sendable (URL, URL) throws -> Void)? = nil) {
        self.source = source; self.target = target; self.options = options; self.stagingDir = stagingDir; self.stateDir = stateDir
        isReadOnly = readOnly ?? { SafetyPolicy.readOnlyICloud }
        self.trash = trash ?? { url, root in try LocalFiles.safeTrash(url, root: root) }
        let name = "import-" + String(SHA256Hex.digest(source.api.accountID + "→" + target.key).prefix(24))
        store = JournalStore<ImportOp>(dir: stateDir, name: name, empty: ImportManifest())
    }

    // MARK: Evaluate

    public func evaluate(progress: @escaping @Sendable (String) -> Void) async throws -> Evaluation {
        var ev = Evaluation()
        let api = source.api
        ev.readOnly = isReadOnly()
        if ev.readOnly {
            ev.warnings.append("Read-only mode is on, so Cirrus won’t add anything to iCloud. Turn it off in Settings › Safety to copy from Google.")
        }
        let hasICloudDrive = target.drive != nil || target.nativeDriveRoot != nil
        if options.includeDrive {
            if !hasICloudDrive { ev.warnings.append("This iCloud account has no iCloud Drive here, so Google Drive is left out.") }
            else if !api.has(GoogleScopes.driveReadonly) {
                ev.warnings.append("Cirrus doesn’t have permission to read your Google Drive yet. Select Allow Reading Google Drive… to include it.")
            } else { ev.driveEnabled = true }
        }
        ev.photosEnabled = options.includePhotos && target.photos != nil && (!source.takeout.isEmpty || !source.picked.isEmpty)
        if options.includePhotos && source.takeout.isEmpty && source.picked.isEmpty {
            ev.warnings.append("For Google Photos, choose a Takeout export (or pick photos in Google Photos). Google doesn’t let apps read your whole library any more.")
        }
        if api.has(GoogleScopes.driveFile) || api.has(GoogleScopes.driveReadonly) {
            progress("Checking your Google account…")
            ev.user = try? await GoogleDrive(api: api).about().0
        }
        if let s = target.storage { progress("Reading iCloud storage…"); ev.icloud = await s() }
        if ev.driveEnabled { try await evaluateDrive(&ev, progress: progress) }
        if ev.photosEnabled { try await evaluatePhotos(&ev, progress: progress) }

        let largestDrive = ev.drivePending.map { $0.size ?? Evaluation.docEstimate }.max() ?? 0
        let largestPhoto = ev.photoPending.map(\.size).max() ?? 0
        let batch = ev.takeoutParts > 0 ? Self.batchBudget(largest: largestPhoto) : 0
        ev.stagingNeeded = max(largestDrive * Int64(max(1, options.concurrency)), largestPhoto * 2, batch) + (ev.isUpToDate ? 0 : 256 << 20)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        ev.stagingFree = VolumeInfo.freeSpace(at: stagingDir) ?? .max
        addWarnings(&ev)
        return ev
    }

    /// How much of a Takeout part to unpack at once.
    static func batchBudget(largest: Int64) -> Int64 { max(largest, 1 << 30) }

    func evaluateDrive(_ ev: inout Evaluation, progress: @escaping @Sendable (String) -> Void) async throws {
        let drive = GoogleDrive(api: source.api)
        progress("Listing your Google Drive…")
        let rootID = try await drive.rootFolderID()
        let all = try await drive.listAll { n in progress("Listing your Google Drive… \(n) items") }
        var children = [String: [GDriveItem]]()
        for i in all { for p in i.parents { children[p, default: []].append(i) } }
        let m = store.value
        // Walk from My Drive's root; things only “shared with me” have no path here and stay out.
        var frontier = [(rootID, "")]
        var cirrusFiles = 0
        defer {
            if cirrusFiles > 0 { ev.warnings.append("\(cirrusFiles) file\(cirrusFiles == 1 ? "" : "s") Cirrus copied from iCloud (moved out of “From iCloud”) \(cirrusFiles == 1 ? "is" : "are") left out.") }
        }
        while let (id, prefix) = frontier.popLast() {
            var used = Set<String>()
            let kids = (children[id] ?? []).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            for k in kids {
                // Cirrus's own copy of iCloud (iCloud → Google) isn't brought back.
                if k.isCirrusCopy {
                    if k.isFolder { ev.warnings.append("“\(k.name)” in Google Drive is left out: it’s Cirrus’s copy of iCloud Drive.") } else { cirrusFiles += 1 }
                    continue
                }
                var name = Self.safeName(k.name)
                var export: GoogleDocFormat.Target?
                if k.isGoogleNative {
                    guard let t = options.docFormat.target(for: k.mimeType) else {
                        ev.skipped.append(.init(name: prefix + k.name, size: 0, reason: "\(GoogleDocFormat.kindName(k.mimeType)) can’t be downloaded from Google"))
                        continue
                    }
                    export = t
                    if (name as NSString).pathExtension.lowercased() != t.ext { name += "." + t.ext }
                }
                // Google allows twins in one folder; iCloud doesn't.
                var unique = name, n = 2
                while used.contains(unique.lowercased()) {
                    let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                    unique = "\(stem) (\(n))" + (ext.isEmpty || k.isFolder ? "" : "." + ext); n += 1
                }
                used.insert(unique.lowercased())
                let rel = prefix.isEmpty ? unique : prefix + "/" + unique
                if k.isFolder { ev.driveFolders.append(rel); frontier.append((k.id, rel)); continue }
                if !k.canDownload {
                    ev.skipped.append(.init(name: rel, size: k.size ?? 0, reason: "The owner turned off downloading for this file"))
                    continue
                }
                if let s = k.size, s > Self.iCloudDriveMax {
                    ev.skipped.append(.init(name: rel, size: s, reason: "Larger than iCloud Drive’s 50 GB limit"))
                    continue
                }
                let item = DriveItem(id: k.id, rel: rel, size: export == nil ? (k.size ?? 0) : nil, export: export, item: k)
                ev.driveFiles += 1
                ev.driveBytes += k.size ?? 0
                if export != nil { ev.docs += 1 }
                ev.driveItems.append(item)
                if let done = m.files[k.id], done.rel == rel, done.version == k.version || !options.updateChanged { continue }
                ev.drivePending.append(item)
            }
        }
        ev.driveFolders.sort(by: SyncPlanner.pathOrder)
        ev.drivePending.sort { SyncPlanner.pathOrder($0.rel, $1.rel) }
    }

    /// name|size of every photo the iCloud → Google direction uploaded for this pair of accounts.
    func sentToGoogle() -> Set<String> {
        let forward = JournalStore<ManifestOp>(dir: stateDir, name: String(SHA256Hex.digest(target.key + "→" + source.api.accountID).prefix(24)),
                                               empty: MigrationManifest())
        return Set(forward.value.photos.values.compactMap { p in p.name.map { "\($0.lowercased())|\(p.size)" } })
    }

    static func safeName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "." || n == ".." { n = "Untitled" }
        if n.hasPrefix(".") { n = "_" + n.dropFirst() }   // a leading dot would hide it
        return n
    }

    func evaluatePhotos(_ ev: inout Evaluation, progress: @escaping @Sendable (String) -> Void) async throws {
        var items = [PhotoItem]()
        var cameFromICloud = 0
        if !source.takeout.isEmpty {
            let reader = TakeoutReader(inputs: source.takeout, workDir: stagingDir.appendingPathComponent("takeout-index", isDirectory: true))
            let r = try await reader.scan(progress: progress)
            ev.takeoutParts = r.parts
            ev.skipped += r.skipped
            ev.warnings += r.warnings
            // Photos Cirrus itself sent from this iCloud account to this Google account aren't brought back.
            let sent = sentToGoogle()
            for t in r.items {
                if sent.contains("\(t.fileName.lowercased())|\(t.size)") { cameFromICloud += 1; continue }
                if t.isEdited && !options.includeEdited { continue }
                if t.isCompanion && !options.includeLive { continue }
                items.append(PhotoItem(key: t.key, source: .takeout(t), fileName: t.fileName, size: t.size, taken: t.taken, isVideo: t.isVideo,
                                       group: t.group, albums: t.albums, favorite: t.favorite, isCompanion: t.isCompanion))
                ev.takeoutItems += 1
            }
        }
        if cameFromICloud > 0 {
            ev.warnings.append("\(cameFromICloud) photo\(cameFromICloud == 1 ? "" : "s") in the export came from this iCloud account through Cirrus, so \(cameFromICloud == 1 ? "it’s" : "they’re") left out.")
        }
        if source.picked.contains(where: \.isVideo) {
            ev.warnings.append("Videos picked in Google Photos come as Google’s high-quality copy, not the original file. For originals, use a Takeout export.")
        }
        for p in source.picked {
            items.append(PhotoItem(key: "picker:" + p.id, source: .picker(p), fileName: p.fileName, size: p.isVideo ? 60 << 20 : 4 << 20, taken: p.created,
                                   isVideo: p.isVideo, group: "picker:" + p.id, albums: [], favorite: false, isCompanion: false, sizeIsEstimate: true))
            ev.pickedItems += 1
        }
        let m = store.value
        ev.photoItems = items
        ev.photoPending = items.filter { m.photos[$0.key] == nil }
        if options.albums {
            var plans = [String: [String]]()
            var order = [String]()
            for i in items where !i.isCompanion {
                for a in i.albums {
                    if plans[a] == nil { order.append(a) }
                    plans[a, default: []].append(i.key)
                }
            }
            ev.albums = order.map { AlbumPlan(title: $0, members: plans[$0]!) }
            for p in ev.albums {
                let added = m.albums[p.title]?.added ?? []
                ev.albumAddsPending += p.members.filter { !added.contains($0) }.count
            }
        }
        if options.favorites {
            ev.favoritesPending = items.filter { $0.favorite && !$0.isCompanion && !m.favorited.contains($0.key) }.count
        }
        if !target.isWeb, let photos = target.photos, !photos.capabilities.contains(.createAlbum) {
            ev.warnings.append("This Photos library can’t make albums from Cirrus, so photos arrive without their Google albums.")
        }
    }

    func addWarnings(_ ev: inout Evaluation) {
        if !ev.fitsICloud, let free = ev.icloudFree {
            ev.warnings.append("Not enough iCloud storage: this copy needs \(ev.requiredICloud.byteString) (with 1 % headroom) but iCloud has \(free.byteString) free. Free up iCloud storage, upgrade your plan, or leave something out.")
        }
        if ev.icloud == nil && !ev.isUpToDate {
            ev.warnings.append("iCloud didn’t report free storage for this account, so make sure there’s room for \(ev.pendingBytes.byteString).")
        }
        if !ev.fitsStaging {
            ev.warnings.append("Cirrus passes each file through a temporary folder on this Mac and needs \(ev.stagingNeeded.byteString) free there; only \(ev.stagingFree.byteString) is available.")
        }
        if ev.docs > 0 {
            let what = options.docFormat == .office ? "Word, Excel and PowerPoint files" : "PDFs"
            ev.warnings.append("\(ev.docs) Google Doc\(ev.docs == 1 ? "" : "s"), Sheet\(ev.docs == 1 ? "" : "s") and Slides can’t be copied as they are; they’re exported as \(what). Comments, version history and live sharing stay in Google.")
        }
        if target.isWeb {
            let big = ev.drivePending.filter { ($0.size ?? 0) > Self.iCloudWebSoft }
            if !big.isEmpty { ev.warnings.append("\(big.count) file\(big.count == 1 ? " is" : "s are") over 10 GB; uploads that big through iCloud.com have failed for some people.") }
            let videos = ev.photoPending.filter { $0.isVideo && $0.size > 100_000_000 }
            if !videos.isEmpty { ev.warnings.append("\(videos.count) video\(videos.count == 1 ? " is" : "s are") over 100 MB; iCloud.com has refused videos that size for some accounts. Signing this Mac in to iCloud avoids that.") }
        }
        let live = ev.photoPending.filter(\.isCompanion).count
        if live > 0 {
            ev.warnings.append("Live Photos and motion photos arrive as a photo plus a separate short video (\(live)): Google’s export doesn’t keep what pairs them.")
        }
        if !ev.skipped.isEmpty {
            ev.warnings.append("\(ev.skipped.count) item\(ev.skipped.count == 1 ? " is" : "s are") skipped (listed below).")
        }
    }

    // MARK: Run

    public func run(_ ev: Evaluation, progress: @escaping @Sendable (RunProgress) -> Void) async throws -> Report {
        if isReadOnly() { throw SafetyPolicy.ReadOnlyError() }
        guard ev.fitsICloud else { throw SyncError.unavailable("Not enough iCloud storage for this copy: it needs \(ev.requiredICloud.byteString), \((ev.icloudFree ?? 0).byteString) is free.") }
        guard ev.fitsStaging else { throw SyncError.notEnoughSpace(need: ev.stagingNeeded, free: ev.stagingFree) }
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)   // leftovers of an interrupted run (Cirrus's own temporary copies)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stagingDir); store.compact() }

        let m = store.value
        let drive = ev.driveEnabled ? ev.driveItems.filter { i in
            guard let d = m.files[i.id], d.rel == i.rel else { return true }
            return d.version != i.item.version && options.updateChanged
        } : []
        let photos = ev.photosEnabled ? ev.photoItems.filter { m.photos[$0.key] == nil } : []
        let bytes = (drive.reduce(0) { $0 + ($1.size ?? Evaluation.docEstimate) } + photos.reduce(0) { $0 + $1.size }) * 2
        let ctx = MigrationEngine.RunContext(filesTotal: drive.count + photos.count, bytesTotal: bytes, progress: progress)
        var report = Report()
        report.skipped = ev.skipped
        let stats = ImportStats()

        if ev.driveEnabled {
            do { try await runDrive(ev, items: drive, ctx: ctx, stats: stats) } catch {
                if MigrationEngine.isCancel(error) { throw CancellationError() }
                guard let s = Self.stops(error) else { throw error }
                ctx.stop(s)
            }
        }
        if ev.photosEnabled && ctx.stopped == nil {
            do {
                try await runPhotos(items: photos, ctx: ctx, stats: stats)
                if ctx.stopped == nil { try await organize(ev, ctx: ctx, stats: stats) }
            } catch {
                if MigrationEngine.isCancel(error) { throw CancellationError() }
                guard let s = Self.stops(error) else { throw error }
                ctx.stop(s)
            }
        }
        let base = ctx.value
        report.failed = base.failed
        report.stopped = base.stopped
        stats.fill(&report)
        ctx.phase("Finished")
        return report
    }

    /// Errors that end the run rather than one item.
    static func stops(_ e: Error) -> GoogleError? {
        if let g = MigrationEngine.stops(e) { return g }
        if e is SafetyPolicy.ReadOnlyError { return .badResponse(e.localizedDescription) }
        if let i = e as? ICloudError {
            switch i {
            case .needsSignIn, .webAccessDisabled, .serviceUnavailable: return .reconnect(i.localizedDescription)
            default: return nil
            }
        }
        return nil
    }

    final class ImportStats: @unchecked Sendable {
        private let lock = NSLock()
        private var r = Report()
        func mutate(_ f: (inout Report) -> Void) { lock.withLock { f(&r) } }
        func fill(_ out: inout Report) {
            lock.withLock {
                out.driveCopied = r.driveCopied; out.driveUpdated = r.driveUpdated; out.docsExported = r.docsExported; out.driveBytes = r.driveBytes
                out.photosImported = r.photosImported; out.photosBytes = r.photosBytes; out.albumsCreated = r.albumsCreated
                out.albumAdds = r.albumAdds; out.favoritesSet = r.favoritesSet; out.unmatched = r.unmatched
            }
        }
    }

    // MARK: Drive → iCloud Drive

    func destination() async throws -> SyncSide {
        if let d = target.drive {
            var folder = try await d.list(d.rootID).first { $0.isFolder && $0.name == options.folderName }
            if folder == nil { folder = try await d.createFolder(options.folderName, in: d.rootID) }
            guard let folder else { throw SyncError.unavailable("Couldn’t make the “\(options.folderName)” folder in iCloud Drive.") }
            return DriveSide(drive: d, rootID: folder.id, label: options.folderName, excludes: [])
        }
        guard let root = target.nativeDriveRoot else { throw SyncError.unavailable("This iCloud account has no iCloud Drive here.") }
        let dest = root.appendingPathComponent(options.folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try SafetyPolicy.checkLocalWrite(dest)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }
        return LocalSide(root: dest, excludes: [])
    }

    func runDrive(_ ev: Evaluation, items: [DriveItem], ctx: MigrationEngine.RunContext, stats: ImportStats) async throws {
        guard !items.isEmpty || !ev.driveFolders.isEmpty else { return }
        ctx.phase("Preparing iCloud Drive…")
        let side = try await destination()
        let existing = try await side.scan(progress: nil)
        for f in ev.driveFolders where existing[f] == nil {
            try Task.checkCancellation()
            try await side.makeDir(f)
        }
        let drive = GoogleDrive(api: source.api)
        try await MigrationEngine.forEach(items, limit: options.concurrency) { item in
            if ctx.stopped != nil { return }
            do { try await self.copyDriveItem(item, drive: drive, side: side, existing: existing, ctx: ctx, stats: stats) } catch {
                if MigrationEngine.isCancel(error) { throw CancellationError() }
                if let s = Self.stops(error) { ctx.stop(s); return }
                ctx.fail(item.rel, error)
            }
            ctx.doneFile()
        }
    }

    func copyDriveItem(_ item: DriveItem, drive: GoogleDrive, side: SyncSide, existing: [String: SideEntry], ctx: MigrationEngine.RunContext, stats: ImportStats) async throws {
        let name = (item.rel as NSString).lastPathComponent
        let dir = stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        let down = ByteMark()
        let expected = item.size ?? Evaluation.docEstimate
        if let t = item.export {
            ctx.phase("Exporting \(name) from Google…")
            _ = try await drive.export(item.item, as: t, to: file)
        } else {
            ctx.phase("Downloading \(name) from Google Drive…")
            try await drive.download(item.item, to: file) { d, _ in ctx.addBytes(down.advance(to: min(d, expected))) }
        }
        ctx.addBytes(down.advance(to: expected))
        let size = MigrationEngine.size(file) ?? 0
        if let m = item.item.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: file.path) }
        ctx.phase("Uploading \(name) to iCloud Drive…")
        let replacing = existing[item.rel] != nil || store.value.files[item.id] != nil
        if let local = side as? LocalSide, existing[item.rel] != nil {
            // Native iCloud Drive folder: the previous copy goes to the Trash first, never overwritten in place.
            try trash(local.root.appendingPathComponent(item.rel), local.root)
        }
        let up = ByteMark()
        try await side.store(item.rel, from: file, mtime: item.item.modified ?? Date()) { d, _ in ctx.addBytes(up.advance(to: min(d, expected))) }
        ctx.addBytes(up.advance(to: expected))
        store.apply(.file(item.id, .init(rel: item.rel, version: item.item.version, size: size)))
        stats.mutate {
            if replacing { $0.driveUpdated += 1 } else { $0.driveCopied += 1 }
            if item.export != nil { $0.docsExported += 1 }
            $0.driveBytes += size
        }
    }

    // MARK: Photos → iCloud Photos

    func provenanceAlbum(_ backend: PhotosBackend, library: PhotoLibraryRef) async throws -> PhotoAlbum? {
        if let p = store.value.provenance { return PhotoAlbum(id: p.id, name: p.title, kind: .album) }
        guard target.isWeb || backend.capabilities.contains(.createAlbum) else { return nil }
        if let found = try await backend.albums(in: library).first(where: { $0.kind == .album && $0.name == options.photosAlbumName }) {
            store.apply(.provenance(.init(id: found.id, title: found.name, added: [])))
            return found
        }
        let a = try await backend.createAlbum(options.photosAlbumName, in: library)
        store.apply(.provenance(.init(id: a.id, title: a.name, added: [])))
        return a
    }

    func runPhotos(items: [PhotoItem], ctx: MigrationEngine.RunContext, stats: ImportStats) async throws {
        guard !items.isEmpty, let backend = target.photos else { return }
        ctx.phase("Preparing iCloud Photos…")
        let libs = try await backend.libraries()
        guard let library = libs.first(where: { !$0.isShared }) ?? libs.first else { throw SyncError.unavailable("No Photos library to copy into.") }
        let album = try await provenanceAlbum(backend, library: library)
        let reader = TakeoutReader(inputs: source.takeout, workDir: stagingDir.appendingPathComponent("unused", isDirectory: true))
        // Takeout parts are unpacked a batch at a time (Live Photo halves stay together) so disk use stays bounded.
        var groups = [[PhotoItem]]()
        var index = [String: Int]()
        for i in items {
            if let g = index[i.group] { groups[g].append(i) } else { index[i.group] = groups.count; groups.append([i]) }
        }
        let largest = items.map(\.size).max() ?? 0
        let budget = Self.batchBudget(largest: largest)
        var batch = [[PhotoItem]]()
        var batchBytes: Int64 = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let current = batch
            batch = []
            batchBytes = 0
            try await importBatch(current, backend: backend, library: library, album: album, reader: reader, ctx: ctx, stats: stats)
        }
        for g in groups {
            try Task.checkCancellation()
            if ctx.stopped != nil { break }
            let size = g.reduce(0) { $0 + $1.size }
            if batchBytes + size > budget || batch.count >= 200 { try await flush() }
            batch.append(g)
            batchBytes += size
        }
        if ctx.stopped == nil { try await flush() }
    }

    func importBatch(_ groups: [[PhotoItem]], backend: PhotosBackend, library: PhotoLibraryRef, album: PhotoAlbum?, reader: TakeoutReader,
                     ctx: MigrationEngine.RunContext, stats: ImportStats) async throws {
        let dir = stagingDir.appendingPathComponent("batch-" + UUID().uuidString.prefix(8), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let takeoutItems = groups.flatMap { $0 }.compactMap { i -> TakeoutItem? in if case .takeout(let t) = i.source { return t }; return nil }
        var files = [String: URL]()
        if !takeoutItems.isEmpty {
            ctx.phase("Unpacking \(takeoutItems.count) item\(takeoutItems.count == 1 ? "" : "s") from the Takeout export…")
            files = try await reader.extract(takeoutItems, into: dir.appendingPathComponent("raw", isDirectory: true))
        }
        let picker = GooglePicker(api: source.api)
        let extracted = files
        let placed = PlacedBox()
        try await MigrationEngine.forEach(groups, limit: min(2, max(1, options.concurrency))) { group in
            if ctx.stopped != nil { return }
            var recorded = Set<String>()
            do {
                // Each group (a photo, or a Live Photo's two halves) gets its own folder so iCloud sees the original names.
                let gdir = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: gdir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: gdir) }
                var ready = [(PhotoItem, URL)]()
                for item in group {
                    let dest = gdir.appendingPathComponent(Paths.safeName(item.fileName))
                    switch item.source {
                    case .takeout:
                        guard let f = extracted[item.key] else { throw SyncError.unavailable("It couldn’t be unpacked from the Takeout export.") }
                        try FileManager.default.moveItem(at: f, to: dest)
                        ctx.addBytes(item.size)
                    case .picker(let p):
                        ctx.phase("Downloading \(item.fileName) from Google Photos…")
                        try await picker.download(p, to: dest)
                        ctx.addBytes(MigrationEngine.size(dest) ?? 0)
                    }
                    if case .takeout(let t) = item.source {
                        await MediaMetadataWriter.fill(dest, isVideo: item.isVideo, taken: t.taken, latitude: t.latitude, longitude: t.longitude, caption: t.caption)
                    } else {
                        await MediaMetadataWriter.fill(dest, isVideo: item.isVideo, taken: item.taken, latitude: nil, longitude: nil, caption: nil)
                    }
                    ready.append((item, dest))
                }
                // iCloud.com takes one file per upload, so each is recorded the moment it lands; this Mac's library
                // (and the demo) create a Live Photo's two halves in one atomic step.
                let calls: [[(PhotoItem, URL)]] = self.target.isWeb ? ready.map { [$0] } : [ready]
                for call in calls {
                    ctx.phase("Adding \(call[0].0.fileName) to iCloud Photos…")
                    let up = ByteMark()
                    let total = call.reduce(0) { $0 + (MigrationEngine.size($1.1) ?? 0) }
                    let ids = try await backend.importReturningIDs(call.map(\.1), library: library) { d, t in
                        // Backends report bytes or file counts; scale either onto this call's bytes.
                        let frac = t > 0 ? Double(d) / Double(t) : 0
                        ctx.addBytes(up.advance(to: Int64(frac * Double(total))))
                    }
                    ctx.addBytes(up.advance(to: total))
                    for (i, (item, f)) in call.enumerated() {
                        let id = ids.count == call.count ? ids[i] : ids.first   // a Live Photo's halves become one asset
                        let size = MigrationEngine.size(f) ?? item.size
                        self.store.apply(.photo(item.key, .init(name: f.lastPathComponent, size: size, id: id)))
                        recorded.insert(item.key)
                        if let id { placed.add(item.key, id) }
                        stats.mutate { $0.photosImported += 1; $0.photosBytes += size }
                    }
                }
            } catch {
                if MigrationEngine.isCancel(error) { throw CancellationError() }
                if let s = Self.stops(error) { ctx.stop(s); return }
                for item in group where !recorded.contains(item.key) { ctx.fail(item.fileName, error) }
            }
            for _ in group { ctx.doneFile() }
        }
        // Then into “From Google Photos”. If that fails, the photos stay recorded and only this step is retried.
        if let album { try await addToProvenance(placed.all, album: album, backend: backend, library: library, ctx: ctx) }
    }

    final class PlacedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list = [(key: String, id: String)]()
        func add(_ k: String, _ id: String) { lock.withLock { list.append((k, id)) } }
        var all: [(key: String, id: String)] { lock.withLock { list } }
    }

    /// Enough of an asset for album adds, which need only its id.
    static func stub(_ id: String, _ library: PhotoLibraryRef) -> PhotoAsset {
        PhotoAsset(id: id, library: library.id, filename: "", size: 0, width: 0, height: 0, isVideo: false, isLive: false, isFavorite: false, isHidden: false, resources: [])
    }

    func addToProvenance(_ pairs: [(key: String, id: String)], album: PhotoAlbum, backend: PhotosBackend, library: PhotoLibraryRef,
                         ctx: MigrationEngine.RunContext) async throws {
        for chunk in pairs.chunked(100) {
            var seen = Set<String>()
            let ids = chunk.map(\.id).filter { seen.insert($0).inserted }
            do {
                try await backend.add(ids.map { Self.stub($0, library) }, to: album, library: library)
                store.apply(.provenanceAdded(chunk.map(\.key)))
            } catch {
                if MigrationEngine.isCancel(error) || Self.stops(error) != nil { throw error }
                ctx.fail("“\(album.name)” album", SyncError.unavailable("\(error.localizedDescription) The photos are in your library; the next run adds them to the album."))
                return
            }
        }
    }

    /// Finishes what imports left: “From Google Photos” for anything an earlier add missed, then albums and favorites.
    /// Uses the asset ids recorded at import (older records fall back to name and size inside “From Google Photos”).
    func organize(_ ev: Evaluation, ctx: MigrationEngine.RunContext, stats: ImportStats) async throws {
        guard let backend = target.photos, ev.photosEnabled, let prov = store.value.provenance else { return }
        let libs = try await backend.libraries()
        guard let library = libs.first(where: { !$0.isShared }) ?? libs.first else { return }
        let provAlbum = PhotoAlbum(id: prov.id, name: prov.title, kind: .album)
        let m0 = store.value
        let notInProvenance = m0.photos.compactMap { k, p in p.id.map { (key: k, id: $0) } }.filter { !(m0.provenance?.added.contains($0.key) ?? false) }
        if !notInProvenance.isEmpty {
            ctx.phase("Adding photos to “\(prov.title)”…")
            try await addToProvenance(notInProvenance.sorted { $0.key < $1.key }, album: provAlbum, backend: backend, library: library, ctx: ctx)
        }
        let m1 = store.value
        let pendingAlbums = ev.albums.filter { p in p.members.contains { m1.photos[$0] != nil && !(m1.albums[p.title]?.added.contains($0) ?? false) } }
        let pendingFavs = options.favorites ? ev.photoItems.filter { $0.favorite && !$0.isCompanion && m1.photos[$0.key] != nil && !m1.favorited.contains($0.key) } : []
        guard !pendingAlbums.isEmpty || !pendingFavs.isEmpty else { return }
        ctx.phase("Organizing albums…")
        // Favorites need iCloud's own copy of each asset (with its change tag); so do records from before ids were kept.
        let needsListing = !pendingFavs.isEmpty || m1.photos.values.contains { $0.id == nil }
        var byID = [String: PhotoAsset]()
        var byName = [String: [PhotoAsset]]()
        if needsListing {
            do {
                for a in try await backend.assets(in: provAlbum, library: library, page: { _, _ in }) {
                    byID[a.id] = a
                    byName[a.filename.lowercased(), default: []].append(a)
                }
            } catch {
                if MigrationEngine.isCancel(error) || Self.stops(error) != nil { throw error }
                ctx.fail("Albums", SyncError.unavailable("Couldn’t read “\(prov.title)” (\(error.localizedDescription)); albums and favorites are finished on the next run."))
                return
            }
        }
        func find(_ key: String, real: Bool) -> PhotoAsset? {
            guard let p = store.value.photos[key] else { return nil }
            if let id = p.id { return byID[id] ?? (real ? nil : Self.stub(id, library)) }
            let candidates = byName[p.name.lowercased()] ?? []
            return candidates.first { ($0.resource(.original)?.size ?? $0.size) == p.size } ?? (candidates.count == 1 ? candidates[0] : nil)
        }
        var unmatched = Set<String>()
        var existingAlbums: [PhotoAlbum]?
        for plan in pendingAlbums {
            try Task.checkCancellation()
            let m = store.value
            let keys = plan.members.filter { m.photos[$0] != nil && !(m.albums[plan.title]?.added.contains($0) ?? false) }
            var assets = [PhotoAsset]()
            var found = [String]()
            var seen = Set<String>()
            for k in keys {
                guard let a = find(k, real: false) else { unmatched.insert(k); continue }
                found.append(k)
                if seen.insert(a.id).inserted { assets.append(a) }
            }
            guard !assets.isEmpty else { continue }
            var entry = m.albums[plan.title]
            if entry == nil {
                // Reuse an album of that name; if the albums can't be read, stop rather than make a second one.
                do { if existingAlbums == nil { existingAlbums = try await backend.albums(in: library) } } catch {
                    if MigrationEngine.isCancel(error) || Self.stops(error) != nil { throw error }
                    ctx.fail("Albums", SyncError.unavailable("Couldn’t read your iCloud albums (\(error.localizedDescription)); albums are finished on the next run."))
                    return
                }
                var a = existingAlbums?.first { $0.kind == .album && $0.name == plan.title }
                if a == nil {
                    a = try await backend.createAlbum(plan.title, in: library)
                    existingAlbums?.append(a!)
                    stats.mutate { $0.albumsCreated += 1 }
                }
                entry = .init(id: a!.id, title: plan.title, added: [])
                store.apply(.album(plan.title, entry!))
            }
            let album = PhotoAlbum(id: entry!.id, name: plan.title, kind: .album)
            do {
                for part in assets.chunked(100) { try await backend.add(part, to: album, library: library) }
                store.apply(.albumAdded(plan.title, found))
                stats.mutate { $0.albumAdds += found.count }
            } catch {
                if MigrationEngine.isCancel(error) || Self.stops(error) != nil { throw error }
                ctx.fail("Album “\(plan.title)”", error)
            }
        }
        if !pendingFavs.isEmpty && backend.capabilities.contains(.favorite) {
            var assets = [PhotoAsset](), keys = [String]()
            for i in pendingFavs { if let a = find(i.key, real: true) { assets.append(a); keys.append(i.key) } else { unmatched.insert(i.key) } }
            for (part, partKeys) in zip(assets.chunked(100), keys.chunked(100)) {
                do {
                    _ = try await backend.setFavorite(part, true)
                    store.apply(.favorited(partKeys))
                    stats.mutate { $0.favoritesSet += part.count }
                } catch {
                    if MigrationEngine.isCancel(error) || Self.stops(error) != nil { throw error }
                    ctx.fail("Favorites", error)
                    break
                }
            }
        }
        if !unmatched.isEmpty {
            stats.mutate { $0.unmatched = unmatched.count }
            ctx.fail("Albums", SyncError.unavailable("\(unmatched.count) photo\(unmatched.count == 1 ? "" : "s") couldn’t be found in “\(prov.title)” yet to add to albums or favorites; the next run tries again."))
        }
    }
}

public extension StorageUsage {
    /// The same usage with `bytes` more, shown as its own segment (for "after this copy" bars).
    func adding(_ bytes: Int64, label: String, color: String = "34C759") -> StorageUsage {
        guard bytes > 0 else { return self }
        return StorageUsage(total: total, used: used + bytes, categories: categories + [Category(key: "added", label: label, bytes: bytes, color: color)])
    }
}
