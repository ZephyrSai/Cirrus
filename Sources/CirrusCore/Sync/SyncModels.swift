import Foundation

public enum SyncEndpoint: Codable, Hashable, Sendable {
    case local(path: String)
    case drive(account: String, folderID: String, path: String)
    case photos(account: String, library: String, album: String?, albumName: String?)
    case account(String)                      // a whole iCloud account (backup source)

    public var title: String {
        switch self {
        case .local(let p): return (p as NSString).abbreviatingWithTildeInPath
        case .drive(_, _, let path): return "iCloud Drive" + (path.isEmpty ? "" : " › " + path.replacingOccurrences(of: "/", with: " › "))
        case .photos(_, _, _, let name): return "Photos" + (name.map { " › " + $0 } ?? " › All Photos")
        case .account(let a): return a
        }
    }

    public var localURL: URL? { if case .local(let p) = self { return URL(fileURLWithPath: p, isDirectory: true) }; return nil }
    public var accountID: String? {
        switch self {
        case .drive(let a, _, _), .photos(let a, _, _, _), .account(let a): return a
        case .local: return nil
        }
    }
}

public struct SyncOptions: Codable, Hashable, Sendable {
    // Folder sync
    public var excludes: [String] = [".DS_Store", "._*", ".Trashes", ".Spotlight-V100", ".fseventsd", "Icon\r", ".cirrus"]
    public var maxDeletePercent: Int = 50
    // Photos export / backup
    public var photoLayout: String = "{yyyy}/{MM}"
    public var includeLive = true
    public var includeEdited = true
    public var includeRAW = true
    public var includeHidden = false
    public var includeSharedLibrary = true
    public var albumFolders = false            // per-album folders made of symlinks (APFS/HFS+ only)
    public var writeManifest = true
    public var keepDeleted = true              // archive: never remove backed-up files when gone from iCloud
    public var verify = true
    public var includeDrive = true
    public var includePhotos = true
    public init() {}
}

public struct SyncJob: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case folderSync, photosExport, photosImport, backup }
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case copy, mirror, twoWay
        public var title: String {
            switch self {
            case .copy: return "Copy new and changed files"
            case .mirror: return "Mirror (remove extras to Trash)"
            case .twoWay: return "Two-way sync"
            }
        }
    }
    public enum Schedule: Codable, Hashable, Sendable {
        case manual
        case every(minutes: Int)
        case daily(hour: Int)
        case whenConnected(volumeUUID: String)
        public var title: String {
            switch self {
            case .manual: return "Manually"
            case .every(let m): return m % 60 == 0 ? "Every \(m / 60) hour\(m == 60 ? "" : "s")" : "Every \(m) minutes"
            case .daily(let h): return "Daily at \(h):00"
            case .whenConnected: return "When the drive is connected"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var mode: Mode = .copy
    public var source: SyncEndpoint
    public var destination: SyncEndpoint
    public var schedule: Schedule = .manual
    public var options = SyncOptions()
    public var enabled = true
    public var lastRun: Date?
    public var lastResult: String?
    public var lastSuccess: Bool?

    public init(name: String, kind: Kind, source: SyncEndpoint, destination: SyncEndpoint) {
        self.name = name; self.kind = kind; self.source = source; self.destination = destination
    }
}

/// Persisted job list.
@MainActor
public final class SyncStore {
    public static let shared = SyncStore()
    public static let changed = Notification.Name("CirrusSyncJobsChanged")
    public private(set) var jobs: [SyncJob] = []
    public var running = Set<UUID>()
    var file: URL { Paths.appSupport.appendingPathComponent("sync-jobs.json") }

    public func load() {
        if let d = try? Data(contentsOf: file), let j = try? JSONDecoder().decode([SyncJob].self, from: d) { jobs = j }
    }

    func save() {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: file, options: .atomic) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func upsert(_ job: SyncJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
        save()
    }

    public func remove(_ job: SyncJob) {
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: SyncState.url(job.id))
        save()
    }

    public func job(_ id: UUID) -> SyncJob? { jobs.first { $0.id == id } }

    public func record(_ id: UUID, success: Bool, message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].lastRun = Date()
        jobs[i].lastResult = message
        jobs[i].lastSuccess = success
        save()
    }
}

/// Two-way sync baseline: what both sides looked like after the last successful run.
public struct SyncState: Codable {
    public struct Entry: Codable, Equatable { public var size: Int64; public var mtimeA: Double; public var mtimeB: Double }
    public var entries: [String: Entry] = [:]
    static func url(_ id: UUID) -> URL { Paths.supportDir("sync-state").appendingPathComponent(id.uuidString + ".json") }
    public static func load(_ id: UUID) -> SyncState {
        (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
    }
    public func save(_ id: UUID) { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url(id), options: .atomic) } }
}

public struct RunProgress: Sendable {
    public var phase: String
    public var filesDone: Int
    public var filesTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
}

public struct RunReport: Sendable {
    public var copied = 0
    public var copiedBack = 0
    public var trashed = 0
    public var conflicts = 0
    public var skipped = 0
    public var failed: [String] = []
    public var bytes: Int64 = 0
    public var summary: String {
        var parts = [String]()
        if copied > 0 { parts.append("\(copied) copied") }
        if copiedBack > 0 { parts.append("\(copiedBack) copied back") }
        if trashed > 0 { parts.append("\(trashed) moved to Trash") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s") kept as copies") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if parts.isEmpty { return "Up to date" }
        return parts.joined(separator: ", ") + (bytes > 0 ? " (\(bytes.byteString))" : "")
    }
}

enum Glob {
    static func matches(_ name: String, _ pattern: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
    static func excluded(_ rel: String, _ patterns: [String]) -> Bool {
        let comps = rel.split(separator: "/").map(String.init)
        return comps.contains { c in patterns.contains { matches(c, $0) } }
    }
}
