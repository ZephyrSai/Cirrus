import Foundation

public struct SideEntry: Equatable, Sendable {
    public var size: Int64
    public var mtime: Double     // seconds since 1970
    public var isDir: Bool
    public init(size: Int64, mtime: Double, isDir: Bool) { self.size = size; self.mtime = mtime; self.isDir = isDir }
}

public protocol SyncSide: AnyObject, Sendable {
    var label: String { get }
    var freeSpace: Int64? { get }
    func scan(progress: (@Sendable (Int) -> Void)?) async throws -> [String: SideEntry]
    /// Returns a local file holding the content; `isTemporary` tells the caller to delete it after use.
    func fetch(_ rel: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (url: URL, isTemporary: Bool)
    func store(_ rel: String, from file: URL, mtime: Date, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func makeDir(_ rel: String) async throws
    func trash(_ rel: String) async throws
}

public enum SyncAction: Equatable, Sendable {
    case copyAB(String, Int64)
    case copyBA(String, Int64)
    case mkdirB(String)
    case mkdirA(String)
    case trashB(String)
    case trashA(String)
    case conflict(String, newerIsA: Bool, size: Int64)
    case skip(String, reason: String)

    public var path: String {
        switch self {
        case .copyAB(let p, _), .copyBA(let p, _), .mkdirA(let p), .mkdirB(let p), .trashA(let p), .trashB(let p), .skip(let p, _): return p
        case .conflict(let p, _, _): return p
        }
    }
    public var bytes: Int64 {
        switch self {
        case .copyAB(_, let s), .copyBA(_, let s): return s
        case .conflict(_, _, let s): return s * 2
        default: return 0
        }
    }
    public var isDestructive: Bool { if case .trashA = self { return true }; if case .trashB = self { return true }; return false }
}

public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    public var sourceCount: Int
    public var destinationCount: Int
    public var bytes: Int64 { actions.reduce(0) { $0 + $1.bytes } }
    public var trashCount: Int { actions.filter(\.isDestructive).count }
    /// Items that would go to the Trash on each side, counting everything inside trashed folders.
    public var trashItemsA = 0
    public var trashItemsB = 0
    public var trashItemCount: Int { trashItemsA + trashItemsB }
    /// The run would empty one side completely — what a disconnected drive or a moved folder looks like.
    public var wipesSide: Bool { (trashItemsB > 0 && trashItemsB >= destinationCount) || (trashItemsA > 0 && trashItemsA >= sourceCount) }
    public var transferCount: Int { actions.filter { if case .skip = $0 { return false }; if case .mkdirA = $0 { return false }; if case .mkdirB = $0 { return false }; return !$0.isDestructive }.count }
    public var isEmpty: Bool { actions.allSatisfy { if case .skip = $0 { return true }; return false } }
}

public enum SyncError: Error, LocalizedError {
    case deleteGuard(Int, Int)
    case notEnoughSpace(need: Int64, free: Int64)
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .deleteGuard(let n, let total): return "Stopped: this run would move \(n) of \(total) items to the Trash. Review the preview and choose “Run Anyway” if that’s intended."
        case .notEnoughSpace(let need, let free): return "Not enough space on the destination: needs \(need.byteString), \(free.byteString) available."
        case .unavailable(let s): return s
        }
    }
}

public enum SyncPlanner {
    static let slack: Double = 2.0

    static func same(_ a: SideEntry, _ b: SideEntry) -> Bool { a.size == b.size && abs(a.mtime - b.mtime) <= slack }

    /// One-way (copy / mirror) or two-way plan from scans of side A (source) and B (destination).
    public static func plan(mode: SyncJob.Mode, a: [String: SideEntry], b: [String: SideEntry], state: SyncState?) -> SyncPlan {
        var actions = [SyncAction]()
        let keysA = a.keys.sorted(by: pathOrder)
        switch mode {
        case .copy, .mirror:
            for rel in keysA {
                let ea = a[rel]!
                if ea.isDir {
                    if let eb = b[rel] { if !eb.isDir { actions.append(.skip(rel, reason: "A file with this name exists on the destination")) } }
                    else { actions.append(.mkdirB(rel)) }
                    continue
                }
                guard let eb = b[rel] else { actions.append(.copyAB(rel, ea.size)); continue }
                if eb.isDir { actions.append(.skip(rel, reason: "A folder with this name exists on the destination")); continue }
                if same(ea, eb) { continue }
                if mode == .copy && eb.mtime > ea.mtime + slack && ea.size != eb.size {
                    actions.append(.skip(rel, reason: "Newer on the destination"))
                    continue
                }
                if mode == .copy && eb.mtime > ea.mtime + slack { continue }
                actions.append(.copyAB(rel, ea.size))
            }
            if mode == .mirror {
                var trashedDirs = [String]()
                for rel in b.keys.sorted(by: pathOrder) where a[rel] == nil {
                    if trashedDirs.contains(where: { rel.hasPrefix($0 + "/") }) { continue }
                    actions.append(.trashB(rel))
                    if b[rel]!.isDir { trashedDirs.append(rel) }
                }
            }
        case .twoWay:
            let st = state?.entries ?? [:]
            let all = Set(a.keys).union(b.keys).sorted(by: pathOrder)
            var fileActions = [String: SyncAction]()
            for rel in all {
                let ea = a[rel], eb = b[rel]
                if (ea?.isDir ?? false) || (eb?.isDir ?? false) { continue }
                let s = st[rel]
                let changedA = ea.map { e in s.map { $0.size != e.size || abs($0.mtimeA - e.mtime) > slack } ?? true } ?? false
                let changedB = eb.map { e in s.map { $0.size != e.size || abs($0.mtimeB - e.mtime) > slack } ?? true } ?? false
                switch (ea, eb) {
                case let (x?, y?):
                    if same(x, y) { continue }
                    if s == nil && x.size == y.size { continue } // first run: assume identical
                    if changedA && !changedB { fileActions[rel] = .copyAB(rel, x.size) }
                    else if changedB && !changedA { fileActions[rel] = .copyBA(rel, y.size) }
                    else if !changedA && !changedB { continue }
                    else { fileActions[rel] = .conflict(rel, newerIsA: x.mtime >= y.mtime, size: max(x.size, y.size)) }
                case let (x?, nil):
                    fileActions[rel] = (s != nil && !changedA) ? .trashA(rel) : .copyAB(rel, x.size)
                case let (nil, y?):
                    fileActions[rel] = (s != nil && !changedB) ? .trashB(rel) : .copyBA(rel, y.size)
                default: break
                }
            }
            // Folders: create where missing; remove a folder deleted on the other side only when
            // nothing inside it is new or changed.
            var dirActions = [SyncAction]()
            var removedDirs = [String]()
            for rel in all {
                let ea = a[rel], eb = b[rel]
                let isDir = (ea?.isDir ?? false) || (eb?.isDir ?? false)
                guard isDir, (ea == nil) != (eb == nil) else { continue }
                if removedDirs.contains(where: { rel.hasPrefix($0 + "/") }) { continue }
                let onA = ea != nil
                let wasKnown = st[rel] != nil
                let children = fileActions.filter { $0.key.hasPrefix(rel + "/") }.map(\.value)
                let allTrash = children.allSatisfy { onA ? $0 == .trashA($0.path) : $0 == .trashB($0.path) }
                if wasKnown && allTrash {
                    dirActions.append(onA ? .trashA(rel) : .trashB(rel))
                    removedDirs.append(rel)
                    for k in fileActions.keys where k.hasPrefix(rel + "/") { fileActions[k] = nil }
                } else {
                    dirActions.append(onA ? .mkdirB(rel) : .mkdirA(rel))
                }
            }
            actions = dirActions.filter { if case .mkdirA = $0 { return true }; if case .mkdirB = $0 { return true }; return false }
                + fileActions.keys.sorted(by: pathOrder).map { fileActions[$0]! }
                + dirActions.filter(\.isDestructive)
        }
        var plan = SyncPlan(actions: dropCaseOnlyTrash(actions), sourceCount: a.count, destinationCount: b.count)
        plan.trashItemsA = removedCount(plan.actions, a, sideA: true)
        plan.trashItemsB = removedCount(plan.actions, b, sideA: false)
        return plan
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive], locale: nil) }

    /// A file or folder renamed only by case (“Photo.jpg” → “photo.jpg”) shows up as one new and one missing
    /// path. On case-insensitive disks (and iCloud Drive) both names are the same item, so trashing the “old”
    /// one would trash the new copy too. Never trash a path that something is being copied onto.
    static func dropCaseOnlyTrash(_ actions: [SyncAction]) -> [SyncAction] {
        var intoA = Set<String>(), intoB = Set<String>()
        func add(_ p: String, _ set: inout Set<String>) {
            var x = Substring(fold(p))
            while true { set.insert(String(x)); guard let i = x.lastIndex(of: "/") else { break }; x = x[..<i] }
        }
        for act in actions {
            switch act {
            case .copyAB(let p, _), .mkdirB(let p): add(p, &intoB)
            case .copyBA(let p, _), .mkdirA(let p): add(p, &intoA)
            case .conflict(let p, _, _): add(p, &intoA); add(p, &intoB)
            default: break
            }
        }
        guard !intoA.isEmpty || !intoB.isEmpty else { return actions }
        return actions.filter { act in
            switch act {
            case .trashB(let p): return !intoB.contains(fold(p))
            case .trashA(let p): return !intoA.contains(fold(p))
            default: return true
            }
        }
    }

    /// How many scanned items the plan's trash actions remove from one side, including folder contents.
    static func removedCount(_ actions: [SyncAction], _ side: [String: SideEntry], sideA: Bool) -> Int {
        let trashed = Set(actions.compactMap { act -> String? in
            switch act { case .trashA(let p) where sideA: return p; case .trashB(let p) where !sideA: return p; default: return nil }
        })
        guard !trashed.isEmpty else { return 0 }
        var n = 0
        for k in side.keys {
            var p = Substring(k)
            while true {
                if trashed.contains(String(p)) { n += 1; break }
                guard let i = p.lastIndex(of: "/") else { break }
                p = p[..<i]
            }
        }
        return n
    }

    /// Source files a one-way plan leaves without an identical copy on the destination (skipped, or newer
    /// there). A move must keep its original while this isn't empty.
    public static func notCopied(_ plan: SyncPlan, a: [String: SideEntry], b: [String: SideEntry]) -> [String] {
        let copying = Set(plan.actions.compactMap { act -> String? in if case .copyAB(let p, _) = act { return p }; return nil })
        return a.compactMap { k, e in
            if e.isDir || copying.contains(k) { return nil }
            if let eb = b[k], !eb.isDir, same(e, eb) { return nil }
            return k
        }.sorted()
    }

    /// Parents before children, then alphabetical by component.
    static func pathOrder(_ x: String, _ y: String) -> Bool {
        let cx = x.split(separator: "/"), cy = y.split(separator: "/")
        for (p, q) in zip(cx, cy) where p != q { return String(p).localizedStandardCompare(String(q)) == .orderedAscending }
        return cx.count < cy.count
    }

    static func conflictName(_ rel: String, side: String) -> String {
        let dir = (rel as NSString).deletingLastPathComponent
        let name = (rel as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let n = "\(stem) (conflict from \(side) \(f.string(from: Date())))" + (ext.isEmpty ? "" : "." + ext)
        return dir.isEmpty ? n : dir + "/" + n
    }
}

public final class SyncRunner: @unchecked Sendable {
    let a: SyncSide
    let b: SyncSide
    let concurrency: Int
    public init(a: SyncSide, b: SyncSide, concurrency: Int = 4) { self.a = a; self.b = b; self.concurrency = concurrency }

    public func scan(progress: @escaping @Sendable (RunProgress) -> Void) async throws -> ([String: SideEntry], [String: SideEntry]) {
        progress(RunProgress(phase: "Scanning \(a.label)…", filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))
        let sa = try await a.scan { n in progress(RunProgress(phase: "Scanning \(self.a.label)… \(n) items", filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0)) }
        progress(RunProgress(phase: "Scanning \(b.label)…", filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))
        let sb = try await b.scan { n in progress(RunProgress(phase: "Scanning \(self.b.label)… \(n) items", filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0)) }
        return (sa, sb)
    }

    func copy(from src: SyncSide, _ rel: String, to dst: SyncSide, as dstRel: String? = nil, mtime: Double?, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let fetched = try await src.fetch(rel) { d, _ in onBytes(d) }
        defer { if fetched.isTemporary { try? FileManager.default.removeItem(at: fetched.url.deletingLastPathComponent()) } }
        let m = mtime.map { Date(timeIntervalSince1970: $0) }
            ?? ((try? fetched.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        try await dst.store(dstRel ?? rel, from: fetched.url, mtime: m) { _, _ in }
    }

    /// Executes a plan. Returns the report and (for two-way) the new baseline.
    public func run(_ plan: SyncPlan, a sa: [String: SideEntry], b sb: [String: SideEntry],
                    progress: @escaping @Sendable (RunProgress) -> Void) async throws -> (RunReport, SyncState) {
        let total = plan.bytes
        let files = plan.actions.count
        let counter = Counter()
        let report = ReportBox()
        let finals = FinalMaps(a: sa, b: sb)
        let tick: @Sendable (String) -> Void = { phase in
            let c = counter.snapshot()
            progress(RunProgress(phase: phase, filesDone: c.files, filesTotal: files, bytesDone: c.bytes, bytesTotal: total))
        }

        // Folder creation first, sequentially.
        for act in plan.actions {
            try Task.checkCancellation()
            switch act {
            case .mkdirB(let rel): do { try await b.makeDir(rel); finals.setB(rel, sa[rel]) } catch { report.fail(rel, error) }; counter.add(files: 1)
            case .mkdirA(let rel): do { try await a.makeDir(rel); finals.setA(rel, sb[rel]) } catch { report.fail(rel, error) }; counter.add(files: 1)
            case .skip: counter.add(files: 1); report.mutate { $0.skipped += 1 }
            default: continue
            }
        }
        tick("Copying…")
        let transfers = plan.actions.filter {
            switch $0 { case .copyAB, .copyBA, .conflict: return true; default: return false }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = transfers.makeIterator()
            var inFlight = 0
            func next() -> Bool {
                guard let act = it.next() else { return false }
                inFlight += 1
                group.addTask {
                    try Task.checkCancellation()
                    let last = ByteMark()
                    let onBytes: @Sendable (Int64) -> Void = { d in
                        let delta = last.advance(to: d)
                        if delta > 0 { counter.add(bytes: delta) }
                        tick("Copying \((act.path as NSString).lastPathComponent)")
                    }
                    do {
                        switch act {
                        case .copyAB(let rel, let size):
                            try await self.copy(from: self.a, rel, to: self.b, mtime: sa[rel]?.mtime, onBytes: onBytes)
                            finals.setB(rel, sa[rel])
                            report.mutate { $0.copied += 1; $0.bytes += size }
                        case .copyBA(let rel, let size):
                            try await self.copy(from: self.b, rel, to: self.a, mtime: sb[rel]?.mtime, onBytes: onBytes)
                            finals.setA(rel, sb[rel])
                            report.mutate { $0.copiedBack += 1; $0.bytes += size }
                        case .conflict(let rel, let newerIsA, _):
                            let (newer, older) = newerIsA ? (self.a, self.b) : (self.b, self.a)
                            let cname = SyncPlanner.conflictName(rel, side: older.label)
                            try await self.copy(from: older, rel, to: older, as: cname, mtime: nil, onBytes: onBytes)
                            try await self.copy(from: older, cname, to: newer, mtime: nil, onBytes: onBytes)
                            try await self.copy(from: newer, rel, to: older, mtime: (newerIsA ? sa : sb)[rel]?.mtime, onBytes: onBytes)
                            if newerIsA { finals.setB(rel, sa[rel]) } else { finals.setA(rel, sb[rel]) }
                            report.mutate { $0.conflicts += 1 }
                        default: break
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        report.fail(act.path, error)
                    }
                    counter.add(files: 1)
                }
                return true
            }
            while inFlight < concurrency && next() {}
            while try await group.next() != nil {
                inFlight -= 1
                while inFlight < concurrency && next() {}
            }
        }
        // Trash last (children were already skipped by the planner when a parent folder goes).
        for act in plan.actions where act.isDestructive {
            try Task.checkCancellation()
            do {
                switch act {
                case .trashA(let rel): try await a.trash(rel); finals.removeA(rel)
                case .trashB(let rel): try await b.trash(rel); finals.removeB(rel)
                default: break
                }
                report.mutate { $0.trashed += 1 }
            } catch { report.fail(act.path, error) }
            counter.add(files: 1)
            tick("Moving removed items to the Trash…")
        }
        var state = SyncState()
        let (finalA, finalB) = finals.maps
        for (rel, ea) in finalA {
            guard let eb = finalB[rel] else { continue }
            state.entries[rel] = SyncState.Entry(size: ea.isDir ? -1 : ea.size, mtimeA: ea.mtime, mtimeB: eb.mtime)
        }
        return (report.value, state)
    }
}

final class FinalMaps: @unchecked Sendable {
    private let lock = NSLock()
    private var a: [String: SideEntry]
    private var b: [String: SideEntry]
    init(a: [String: SideEntry], b: [String: SideEntry]) { self.a = a; self.b = b }
    func setA(_ k: String, _ v: SideEntry?) { lock.withLock { a[k] = v } }
    func setB(_ k: String, _ v: SideEntry?) { lock.withLock { b[k] = v } }
    func removeA(_ k: String) { lock.withLock { a[k] = nil; for x in a.keys where x.hasPrefix(k + "/") { a[x] = nil } } }
    func removeB(_ k: String) { lock.withLock { b[k] = nil; for x in b.keys where x.hasPrefix(k + "/") { b[x] = nil } } }
    var maps: ([String: SideEntry], [String: SideEntry]) { lock.withLock { (a, b) } }
}

final class ByteMark: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func advance(to v: Int64) -> Int64 { lock.withLock { let d = v - last; last = v; return d } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    func add(files f: Int = 0, bytes b: Int64 = 0) { lock.withLock { files += f; bytes += b } }
    func snapshot() -> (files: Int, bytes: Int64) { lock.withLock { (files, bytes) } }
}

final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report = RunReport()
    func mutate(_ f: (inout RunReport) -> Void) { lock.withLock { f(&report) } }
    func fail(_ path: String, _ error: Error) {
        Log.error("sync failed for \(path): \(error.localizedDescription)")
        mutate { $0.failed.append("\(path): \(error.localizedDescription)") }
    }
    var value: RunReport { lock.withLock { report } }
}

// MARK: - Sides

public final class LocalSide: SyncSide, @unchecked Sendable {
    public let root: URL
    public let excludes: [String]
    public var label: String { root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent }
    private let lock = NSLock()
    private var actual = [String: String]()   // NFC key → on-disk relative path

    /// Create the folder when it doesn't exist (destinations). Sources and two-way sides with history must
    /// already exist: a missing folder (unplugged drive, moved folder) would otherwise look like “everything deleted”.
    public let createIfMissing: Bool

    public init(root: URL, excludes: [String], createIfMissing: Bool = false) {
        self.root = root.standardizedFileURL; self.excludes = excludes; self.createIfMissing = createIfMissing
    }

    public var freeSpace: Int64? { VolumeInfo.freeSpace(at: root) }

    func url(_ rel: String) -> URL { root.appendingPathComponent(lock.withLock { actual[rel] } ?? rel) }

    public func scan(progress: (@Sendable (Int) -> Void)?) async throws -> [String: SideEntry] {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) {
            guard createIfMissing else { throw SyncError.unavailable("“\(label)” isn’t available. Connect the drive it’s on, or choose the folder again. Nothing was changed.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else if !isDir.boolValue {
            throw SyncError.unavailable("“\(label)” is a file, not a folder. Nothing was changed.")
        }
        var out = [String: SideEntry]()
        var map = [String: String]()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        // A folder that can't be read would look empty, i.e. “everything inside was deleted”: stop instead.
        let unreadable = UnreadableBox()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { u, err in
            unreadable.note(u, err); return true
        }) else { throw SyncError.unavailable("Couldn’t read “\(label)”. Nothing was changed.") }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var n = 0
        while let u = e.nextObject() as? URL {
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count))
            let name = u.lastPathComponent
            var placeholder = false
            var logical = rel
            if name.hasPrefix(".") && name.hasSuffix(".icloud") {   // pre-Sonoma iCloud placeholder
                placeholder = true
                logical = ((rel as NSString).deletingLastPathComponent as NSString).appendingPathComponent(String(name.dropFirst().dropLast(7)))
                if logical.hasPrefix("/") { logical.removeFirst() }
            }
            if !placeholder && Glob.excluded(rel, excludes) { if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }; continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            let key = logical.precomposedStringWithCanonicalMapping
            map[key] = logical
            if placeholder {
                let size = (NSDictionary(contentsOf: u)?["NSURLFileSizeKey"] as? NSNumber)?.int64Value ?? 0
                out[key] = SideEntry(size: size, mtime: (v?.contentModificationDate ?? Date()).timeIntervalSince1970, isDir: false)
            } else {
                out[key] = SideEntry(size: Int64(v?.fileSize ?? 0), mtime: (v?.contentModificationDate ?? Date()).timeIntervalSince1970, isDir: v?.isDirectory ?? false)
            }
            n += 1
            if n % 500 == 0 { progress?(n); try Task.checkCancellation() }
        }
        if let (u, err) = unreadable.first {
            throw SyncError.unavailable("Couldn’t read “\(u.lastPathComponent)” (\(err.localizedDescription)). Nothing was changed — fix its permissions or exclude it.")
        }
        lock.withLock { actual = map }
        return out
    }

    public func fetch(_ rel: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (url: URL, isTemporary: Bool) {
        let u = url(rel)
        try await LocalFiles.ensureDownloaded(u)
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(size, size)
        return (u, false)
    }

    public func store(_ rel: String, from file: URL, mtime: Date, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let dest = url(rel)
        try SafetyPolicy.checkLocalWrite(root); try SafetyPolicy.checkLocalWrite(dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalFiles.atomicCopy(file, to: dest)
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: dest.path)
        lock.withLock { actual[rel] = rel }
    }

    public func makeDir(_ rel: String) async throws {
        try SafetyPolicy.checkLocalWrite(root); try SafetyPolicy.checkLocalWrite(url(rel))
        try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true)
        lock.withLock { actual[rel] = rel }
    }

    public func trash(_ rel: String) async throws {
        let u = url(rel)
        try SafetyPolicy.checkLocalWrite(root); try SafetyPolicy.checkLocalWrite(u)
        // On a case-insensitive disk “Photo.jpg” also opens “photo.jpg”. Only trash an entry whose on-disk
        // name is exactly this one, so a case-only rename can never take the renamed file with it.
        let name = u.lastPathComponent.precomposedStringWithCanonicalMapping
        let names = (try? FileManager.default.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)) ?? []
        guard names.contains(where: { $0.precomposedStringWithCanonicalMapping == name }) else { return }
        try LocalFiles.safeTrash(u, root: root)
    }
}

final class UnreadableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (URL, Error)?
    func note(_ u: URL, _ e: Error) { lock.withLock { if value == nil { value = (u, e) } } }
    var first: (URL, Error)? { lock.withLock { value } }
}

public final class DriveSide: SyncSide, @unchecked Sendable {
    let drive: DriveBackend
    let rootID: String
    let excludes: [String]
    public let label: String
    private let lock = NSLock()
    private var nodes = [String: DriveNode]()

    public init(drive: DriveBackend, rootID: String, label: String, excludes: [String]) {
        self.drive = drive; self.rootID = rootID; self.label = label; self.excludes = excludes
    }

    public var freeSpace: Int64? { nil }

    public func scan(progress: (@Sendable (Int) -> Void)?) async throws -> [String: SideEntry] {
        let all = try await drive.walk(rootID, progress: progress)
        var out = [String: SideEntry]()
        var map = [String: DriveNode]()
        for (rel, node) in all where !Glob.excluded(rel, excludes) {
            out[rel] = SideEntry(size: node.size, mtime: (node.modified ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970, isDir: node.isFolder)
            map[rel] = node
        }
        lock.withLock { nodes = map }
        return out
    }

    func node(_ rel: String) -> DriveNode? { lock.withLock { nodes[rel] } }
    /// iCloud Drive names are case-insensitive: “photo.jpg” and “Photo.jpg” are the same item there.
    func nodeIgnoringCase(_ rel: String) -> DriveNode? {
        lock.withLock {
            if let n = nodes[rel] { return n }
            let f = SyncPlanner.fold(rel)
            return nodes.first { SyncPlanner.fold($0.key) == f }?.value
        }
    }

    func folderID(_ rel: String) async throws -> String {
        if rel.isEmpty || rel == "." { return rootID }
        if let n = nodeIgnoringCase(rel), n.isFolder { return n.id }
        try await makeDir(rel)
        guard let n = nodeIgnoringCase(rel) else { throw SyncError.unavailable("Couldn’t create folder \(rel) in iCloud Drive.") }
        return n.id
    }

    public func fetch(_ rel: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (url: URL, isTemporary: Bool) {
        guard let n = node(rel) else { throw ICloudError.notFound }
        let tmp = Paths.tempFile(named: n.name)
        try await drive.download(n, to: tmp, progress: progress)
        return (tmp, true)
    }

    public func store(_ rel: String, from file: URL, mtime: Date, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let parent = (rel as NSString).deletingLastPathComponent
        let fid = try await folderID(parent)
        let existing = nodeIgnoringCase(rel)
        let n = try await drive.safeReplace(file, name: (rel as NSString).lastPathComponent, in: fid, existing: existing?.isFolder == false ? existing : nil,
                                            modified: mtime, progress: progress)
        lock.withLock { nodes[rel] = n }
    }

    public func makeDir(_ rel: String) async throws {
        if let n = nodeIgnoringCase(rel), n.isFolder { lock.withLock { nodes[rel] = n }; return }
        let parent = (rel as NSString).deletingLastPathComponent
        let pid = try await folderID(parent)
        let name = (rel as NSString).lastPathComponent
        do {
            let n = try await drive.createFolder(name, in: pid)
            lock.withLock { nodes[rel] = n }
        } catch {
            // Someone else may have created it meanwhile.
            if let found = try? await drive.list(pid).first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { lock.withLock { nodes[rel] = found } } else { throw error }
        }
    }

    public func trash(_ rel: String) async throws {
        guard let n = node(rel) else { return }
        try await drive.trash([n])
        lock.withLock { nodes[rel] = nil }
    }
}

public enum LocalFiles {
    /// Materialize an iCloud (native) file that may be dataless; plain files return immediately.
    public static func ensureDownloaded(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true, v.ubiquitousItemDownloadingStatus != .current else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                var coordError: NSError?
                var inner: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { _ in
                    // Reading through the coordinator forces the file provider to download it.
                    do { _ = try FileHandle(forReadingFrom: url).close() } catch { inner = error }
                }
                if let e = coordError ?? inner { cont.resume(throwing: e) } else { cont.resume() }
            }
        }
    }

    /// Copy via a temp file in the destination folder, then swap in (never leaves half files).
    public static func atomicCopy(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".cirrus-\(UUID().uuidString.prefix(8))-" + dest.lastPathComponent)
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }

    /// Put `source` at `dest`, replacing what's there without a moment where only the old copy is gone:
    /// the new copy lands beside it under a temporary name, then the old one goes to the Trash, then a rename.
    /// `move` moves `source` instead of copying it.
    public static func swapIn(_ source: URL, at dest: URL, move: Bool) throws {
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".cirrus-\(UUID().uuidString.prefix(8))-" + dest.lastPathComponent)
        if move { try fm.moveItem(at: source, to: tmp) } else { try fm.copyItem(at: source, to: tmp) }
        do {
            try safeTrash(dest, root: nil)
        } catch {
            // Couldn't retire the old copy: leave everything as it was.
            if move { try? fm.moveItem(at: tmp, to: source) } else { try? fm.removeItem(at: tmp) }
            throw error
        }
        try fm.moveItem(at: tmp, to: dest)
    }

    /// Move to the Trash; on volumes without one, into <root>/.cirrus/Removed/<date>/ instead. Never deletes.
    public static func safeTrash(_ url: URL, root: URL?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            guard let root else { throw error }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
            let bin = root.appendingPathComponent(".cirrus/Removed/" + f.string(from: Date()), isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            var dest = bin.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { dest = bin.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + url.lastPathComponent) }
            try FileManager.default.moveItem(at: url, to: dest)
        }
    }
}
