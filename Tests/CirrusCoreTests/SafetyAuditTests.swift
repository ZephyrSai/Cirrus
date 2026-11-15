import Foundation
import Testing
@testable import CirrusCore

/// Regressions for the data-loss paths found by the cross-platform safety audit.
@Suite(.serialized) struct SafetyAuditTests {
    func e(_ size: Int64, _ t: Double, dir: Bool = false) -> SideEntry { SideEntry(size: size, mtime: t, isDir: dir) }

    func tmp(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-audit-\(UUID().uuidString.prefix(8))/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func put(_ s: String, _ u: URL, mtime: Double = 1_000_000) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(s.utf8).write(to: u)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: u.path)
    }

    // A folder on an unplugged drive (or one that was moved) must stop the job, not read as “everything deleted”.
    @Test func missingFolderStopsInsteadOfLookingEmpty() async throws {
        let gone = tmp("x").appendingPathComponent("not-here", isDirectory: true)
        await #expect(throws: SyncError.self) { _ = try await LocalSide(root: gone, excludes: []).scan(progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        // Destinations may be created.
        _ = try await LocalSide(root: gone, excludes: [], createIfMissing: true).scan(progress: nil)
        #expect(FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func unreadableFolderStopsTheScan() async throws {
        let root = tmp("r")
        put("x", root.appendingPathComponent("locked/inside.txt"))
        let locked = root.appendingPathComponent("locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        await #expect(throws: SyncError.self) { _ = try await LocalSide(root: root, excludes: []).scan(progress: nil) }
    }

    // The guard used to count a trashed folder as one item, whatever was inside.
    @Test func deleteGuardCountsFolderContents() {
        var b: [String: SideEntry] = ["keep.txt": e(1, 1), "Old": e(0, 0, dir: true)]
        for i in 0..<30 { b["Old/\(i).txt"] = e(1, 1) }
        let p = SyncPlanner.plan(mode: .mirror, a: ["keep.txt": e(1, 1)], b: b, state: nil)
        #expect(p.trashCount == 1)
        #expect(p.trashItemCount == 31)
        #expect(!p.wipesSide)
    }

    @Test func emptiedSideIsFlagged() {
        let full: [String: SideEntry] = ["a.txt": e(1, 1), "d": e(0, 0, dir: true), "d/b.txt": e(1, 1)]
        // Mirror from an empty source.
        #expect(SyncPlanner.plan(mode: .mirror, a: [:], b: full, state: nil).wipesSide)
        // Two-way where one side vanished after a run.
        var st = SyncState()
        for (k, v) in full { st.entries[k] = .init(size: v.isDir ? -1 : v.size, mtimeA: v.mtime, mtimeB: v.mtime) }
        let p = SyncPlanner.plan(mode: .twoWay, a: [:], b: full, state: st)
        #expect(p.wipesSide && p.trashItemsB == 3)
    }

    @Test func caseOnlyRenameIsNeverTrashed() {
        var st = SyncState()
        st.entries["Photo.jpg"] = .init(size: 5, mtimeA: 10, mtimeB: 10)
        let p = SyncPlanner.plan(mode: .twoWay, a: ["photo.jpg": e(5, 10)], b: ["Photo.jpg": e(5, 10)], state: st)
        #expect(!p.actions.contains { $0.isDestructive })
        let m = SyncPlanner.plan(mode: .mirror, a: ["photos": e(0, 0, dir: true), "photos/x": e(1, 1)],
                                 b: ["Photos": e(0, 0, dir: true), "Photos/x": e(1, 1)], state: nil)
        #expect(!m.actions.contains { $0.isDestructive })
    }

    // End to end on this Mac's (case-insensitive) disk: rename by case, sync three times, the file survives on both sides.
    @Test func caseOnlyRenameSurvivesRepeatedTwoWayRuns() async throws {
        let A = tmp("A"), B = tmp("B")
        put("hello", A.appendingPathComponent("Note.txt"))
        let job = UUID()
        defer { try? FileManager.default.removeItem(at: SyncState.url(job)) }
        func once() async throws {
            let r = SyncRunner(a: LocalSide(root: A, excludes: []), b: LocalSide(root: B, excludes: []))
            let (ma, mb) = try await r.scan { _ in }
            let plan = SyncPlanner.plan(mode: .twoWay, a: ma, b: mb, state: SyncState.load(job))
            #expect(!plan.actions.contains { $0.isDestructive }, "run planned a trash: \(plan.actions)")
            let (_, state) = try await r.run(plan, a: ma, b: mb) { _ in }
            state.save(job)
        }
        try await once()
        try FileManager.default.moveItem(at: A.appendingPathComponent("Note.txt"), to: A.appendingPathComponent("note.txt"))
        for _ in 0..<3 { try await once() }
        for side in [A, B] {
            let names = try FileManager.default.contentsOfDirectory(atPath: side.path).filter { !$0.hasPrefix(".") }
            #expect(names.count == 1, "\(side.lastPathComponent): \(names)")
            #expect(try String(contentsOf: side.appendingPathComponent(names[0]), encoding: .utf8) == "hello")
        }
    }

    @Test func moveKeepsOriginalWhenSomethingWasNotCopied() {
        let a = ["d": e(0, 0, dir: true), "d/new.txt": e(3, 10), "d/clash.txt": e(4, 10), "d/same.txt": e(2, 10)]
        let b = ["d": e(0, 0, dir: true), "d/clash.txt": e(9, 500), "d/same.txt": e(2, 10)]
        let p = SyncPlanner.plan(mode: .copy, a: a, b: b, state: nil)
        #expect(SyncPlanner.notCopied(p, a: a, b: b) == ["d/clash.txt"])
    }

    @Test func swapInLeavesTheOldCopyWhenTheNewOneIsMissing() throws {
        let dir = tmp("s")
        let dest = dir.appendingPathComponent("report.pdf")
        put("old", dest)
        #expect(throws: (any Error).self) { try LocalFiles.swapIn(dir.appendingPathComponent("nope.pdf"), at: dest, move: true) }
        #expect(try String(contentsOf: dest, encoding: .utf8) == "old")
    }

    // A folder the server left out of a batched listing must not read as an empty folder.
    @Test func driveWalkFailsWhenAFolderIsMissingFromTheReply() async throws {
        let d = DropsFolderDrive()
        await #expect(throws: (any Error).self) { _ = try await d.walk("root") }
    }

    @Test func profileNamesCanNotBePaths() {
        #expect(Paths.profileName("../../Library") == "Library")
        #expect(Paths.profileName("qa-1_x") == "qa-1_x")
        #expect(Paths.profileName("/") == "invalid")
        #expect(Paths.profileName(String(repeating: "a", count: 99)).count == 32)
    }

    // Opened copies: untouched downloads are disposable, edited ones are not.
    @Test func editedOpenedCopiesAreDetected() throws {
        let dir = tmp("open").appendingPathComponent("acct-x/key", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        put("v1", dir.appendingPathComponent("Report.pages"), mtime: 1_000_000)   // iCloud's older date
        Paths.markFetched(dir)
        #expect(!Paths.wasEditedLocally(dir))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: dir.appendingPathComponent("Report.pages").path)
        #expect(Paths.wasEditedLocally(dir))
        // Unedited copies are simply removed when retired.
        let clean = tmp("open2").appendingPathComponent("k", isDirectory: true)
        put("v1", clean.appendingPathComponent("a.txt"), mtime: 1_000_000)
        Paths.markFetched(clean)
        Paths.retireOpenCopy(clean)
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(Paths.itemDirs(in: dir.deletingLastPathComponent().deletingLastPathComponent()).map(\.lastPathComponent) == ["key"])
    }

    @Test func readOnlyCoversFoldersThatContainICloud() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SafetyPolicy.touchesICloud(home.appendingPathComponent("Library")))
        #expect(SafetyPolicy.touchesICloud(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x.txt")))
        #expect(!SafetyPolicy.touchesICloud(FileManager.default.temporaryDirectory.appendingPathComponent("plain")))
    }
}

/// Lists the root with one subfolder, then “forgets” that subfolder in the next batch reply.
final class DropsFolderDrive: DriveBackend, @unchecked Sendable {
    let rootID = "root"
    func node(_ id: String, _ name: String, folder: Bool, parent: String) -> DriveNode {
        DriveNode(id: id, zone: "z", parentID: parent, name: name, type: folder ? "FOLDER" : "FILE", size: folder ? 0 : 1, modified: nil, created: nil, etag: nil)
    }
    func list(_ folderID: String) async throws -> [DriveNode] { try await listMany([folderID])[folderID] ?? [] }
    func listMany(_ folderIDs: [String]) async throws -> [String: [DriveNode]] {
        var out = [String: [DriveNode]]()
        for f in folderIDs where f == "root" { out[f] = [node("sub", "Sub", folder: true, parent: "root"), node("f", "a.txt", folder: false, parent: "root")] }
        return out
    }
    func download(_ node: DriveNode, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func upload(_ file: URL, name: String, into folderID: String, modified: Date?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode { throw ICloudError.notFound }
    func createFolder(_ name: String, in folderID: String) async throws -> DriveNode { throw ICloudError.notFound }
    func rename(_ node: DriveNode, to name: String) async throws -> DriveNode { throw ICloudError.notFound }
    func move(_ nodes: [DriveNode], to folderID: String) async throws {}
    func trash(_ nodes: [DriveNode]) async throws {}
    func listTrash() async throws -> [DriveNode] { [] }
    func restore(_ nodes: [DriveNode]) async throws {}
    func deleteForever(_ nodes: [DriveNode]) async throws {}
}
