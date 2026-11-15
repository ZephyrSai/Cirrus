import Foundation
import Testing
@testable import CirrusCore

private func e(_ size: Int64, _ t: Double, dir: Bool = false) -> SideEntry { SideEntry(size: size, mtime: t, isDir: dir) }

@Test func copyPlanCopiesMissingAndChanged() {
    let a = ["d": e(0, 0, dir: true), "d/x.txt": e(10, 100), "y.txt": e(5, 100), "same.txt": e(3, 50)]
    let b = ["same.txt": e(3, 51), "y.txt": e(4, 90)]
    let p = SyncPlanner.plan(mode: .copy, a: a, b: b, state: nil)
    #expect(p.actions.contains(.mkdirB("d")))
    #expect(p.actions.contains(.copyAB("d/x.txt", 10)))
    #expect(p.actions.contains(.copyAB("y.txt", 5)))
    #expect(!p.actions.contains { $0.path == "same.txt" })
    #expect(p.trashCount == 0)
    // parent folders are created before their children
    let order = p.actions.map(\.path)
    #expect(order.firstIndex(of: "d")! < order.firstIndex(of: "d/x.txt")!)
}

@Test func copyPlanDoesNotClobberNewerDestination() {
    let p = SyncPlanner.plan(mode: .copy, a: ["f": e(1, 10)], b: ["f": e(2, 500)], state: nil)
    #expect(p.actions == [.skip("f", reason: "Newer on the destination")])
}

@Test func mirrorTrashesTopmostExtrasOnly() {
    let a = ["keep.txt": e(1, 1)]
    let b = ["keep.txt": e(1, 1), "old": e(0, 0, dir: true), "old/a": e(1, 1), "old/b": e(1, 1), "stray.txt": e(1, 1)]
    let p = SyncPlanner.plan(mode: .mirror, a: a, b: b, state: nil)
    #expect(p.actions.contains(.trashB("old")))
    #expect(p.actions.contains(.trashB("stray.txt")))
    #expect(!p.actions.contains(.trashB("old/a")))
}

@Test func twoWayUsesBaseline() {
    var st = SyncState()
    st.entries["both.txt"] = .init(size: 1, mtimeA: 10, mtimeB: 10)
    st.entries["goneB.txt"] = .init(size: 1, mtimeA: 10, mtimeB: 10)
    st.entries["editA.txt"] = .init(size: 1, mtimeA: 10, mtimeB: 10)
    st.entries["clash.txt"] = .init(size: 1, mtimeA: 10, mtimeB: 10)
    let a = ["both.txt": e(1, 10), "goneB.txt": e(1, 10), "editA.txt": e(2, 99), "clash.txt": e(3, 200), "newA.txt": e(4, 5)]
    let b = ["both.txt": e(1, 10), "editA.txt": e(1, 10), "clash.txt": e(5, 300), "newB.txt": e(6, 5)]
    let p = SyncPlanner.plan(mode: .twoWay, a: a, b: b, state: st)
    #expect(p.actions.contains(.trashA("goneB.txt")))
    #expect(p.actions.contains(.copyAB("editA.txt", 2)))
    #expect(p.actions.contains(.copyAB("newA.txt", 4)))
    #expect(p.actions.contains(.copyBA("newB.txt", 6)))
    #expect(p.actions.contains(.conflict("clash.txt", newerIsA: false, size: 5)))
    #expect(!p.actions.contains { $0.path == "both.txt" })
}

@Test func twoWayKeepsFolderWithNewContent() {
    var st = SyncState()
    st.entries["dir"] = .init(size: -1, mtimeA: 0, mtimeB: 0)
    st.entries["dir/old.txt"] = .init(size: 1, mtimeA: 1, mtimeB: 1)
    let a = ["dir": e(0, 0, dir: true), "dir/old.txt": e(1, 1), "dir/new.txt": e(2, 2)]
    let p = SyncPlanner.plan(mode: .twoWay, a: a, b: [:], state: st)
    #expect(p.actions.contains(.mkdirB("dir")))
    #expect(p.actions.contains(.copyAB("dir/new.txt", 2)))
    #expect(!p.actions.contains(.trashA("dir")))
}

private func tempDir(_ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-test-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func write(_ s: String, _ u: URL, mtime: Double? = nil) {
    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(s.utf8).write(to: u)
    if let m = mtime { try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: m)], ofItemAtPath: u.path) }
}

@Test func localTwoWayRoundTrip() async throws {
    let A = tempDir("A"), B = tempDir("B")
    write("one", A.appendingPathComponent("docs/one.txt"), mtime: 1_000_000)
    write("two", B.appendingPathComponent("two.txt"), mtime: 1_000_000)
    write("skip", A.appendingPathComponent(".DS_Store"))
    let job = UUID()
    let excludes = SyncOptions().excludes
    func once() async throws -> RunReport {
        let sa = LocalSide(root: A, excludes: excludes), sb = LocalSide(root: B, excludes: excludes)
        let r = SyncRunner(a: sa, b: sb)
        let (ma, mb) = try await r.scan { _ in }
        let plan = SyncPlanner.plan(mode: .twoWay, a: ma, b: mb, state: SyncState.load(job))
        let (rep, state) = try await r.run(plan, a: ma, b: mb) { _ in }
        state.save(job)
        return rep
    }
    let r1 = try await once()
    #expect(r1.copied == 1 && r1.copiedBack == 1 && r1.failed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: B.appendingPathComponent("docs/one.txt").path))
    #expect(FileManager.default.fileExists(atPath: A.appendingPathComponent("two.txt").path))
    #expect(!FileManager.default.fileExists(atPath: B.appendingPathComponent(".DS_Store").path))
    // Second run is a no-op.
    let r2 = try await once()
    #expect(r2.summary == "Up to date")
    // Delete on B → goes to Trash on A (not deleted).
    try FileManager.default.removeItem(at: B.appendingPathComponent("two.txt"))
    let r3 = try await once()
    #expect(r3.trashed == 1)
    #expect(!FileManager.default.fileExists(atPath: A.appendingPathComponent("two.txt").path))
    // Conflict: both edited.
    write("A edit!", A.appendingPathComponent("docs/one.txt"), mtime: 2_000_000)
    write("B edit", B.appendingPathComponent("docs/one.txt"), mtime: 2_000_100)
    let r4 = try await once()
    #expect(r4.conflicts == 1)
    #expect(try String(contentsOf: A.appendingPathComponent("docs/one.txt"), encoding: .utf8) == "B edit")
    let aFiles = try FileManager.default.contentsOfDirectory(atPath: A.appendingPathComponent("docs").path)
    let bFiles = try FileManager.default.contentsOfDirectory(atPath: B.appendingPathComponent("docs").path)
    #expect(aFiles.contains { $0.contains("conflict") } && bFiles.contains { $0.contains("conflict") })
    try? FileManager.default.removeItem(at: SyncState.url(job))
}

@Test func driveSideMirrorThroughDemoBackend() async throws {
    setenv("CIRRUS_DEMO_FAST", "1", 1)
    setenv("CIRRUS_PROFILE", "tests", 1)
    let drive = DemoDrive.shared
    let src = tempDir("src")
    write("hello", src.appendingPathComponent("Sub/hello.txt"), mtime: 1_500_000)
    write("x", src.appendingPathComponent("top.txt"), mtime: 1_500_000)
    let folder = try await drive.createFolder("SyncTest-\(UUID().uuidString.prefix(5))", in: drive.rootID)
    let a = LocalSide(root: src, excludes: [])
    let b = DriveSide(drive: drive, rootID: folder.id, label: "iCloud Drive", excludes: [])
    let runner = SyncRunner(a: a, b: b)
    var (ma, mb) = try await runner.scan { _ in }
    var (rep, _) = try await runner.run(SyncPlanner.plan(mode: .mirror, a: ma, b: mb, state: nil), a: ma, b: mb) { _ in }
    #expect(rep.copied == 2 && rep.failed.isEmpty)
    let listed = try await drive.walk(folder.id)
    #expect(Set(listed.map(\.path)) == ["Sub", "Sub/hello.txt", "top.txt"])
    #expect(listed.first { $0.path == "Sub/hello.txt" }?.node.modified.map { abs($0.timeIntervalSince1970 - 1_500_000) < 2 } == true)
    try FileManager.default.removeItem(at: src.appendingPathComponent("top.txt"))
    (ma, mb) = try await runner.scan { _ in }
    (rep, _) = try await runner.run(SyncPlanner.plan(mode: .mirror, a: ma, b: mb, state: nil), a: ma, b: mb) { _ in }
    #expect(rep.trashed == 1)
    let trash = try await drive.listTrash()
    #expect(trash.contains { $0.name == "top.txt" })
    try await drive.trash([folder])
}

@Test func photoExportIsIncrementalAndDated() async throws {
    setenv("CIRRUS_DEMO_FAST", "1", 1)
    setenv("CIRRUS_PROFILE", "tests", 1)
    let photos = DemoPhotos.shared
    let lib = try await photos.libraries()[0]
    let dest = tempDir("export")
    var opts = SyncOptions()
    opts.albumFolders = true
    let ex = PhotoExporter(backend: photos, library: lib, album: nil, destination: dest, options: opts)
    let ev = try await ex.evaluate { _ in }
    #expect(ev.assetCount > 10)
    #expect(ev.pending.count == ev.files.count)
    let rep = try await ex.run(ev) { _ in }
    #expect(rep.failed.isEmpty)
    let first = ev.files.first { $0.kind == .original }!
    let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(first.rel).path)
    #expect(abs((attrs[.modificationDate] as! Date).timeIntervalSince(first.asset.created!)) < 2)
    #expect(ev.files.contains { $0.kind == .liveVideo && $0.rel.hasSuffix(".MOV") })
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Photos manifest.csv").path))
    #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Albums/Travel").path))
    let ev2 = try await PhotoExporter(backend: photos, library: lib, album: nil, destination: dest, options: opts).evaluate { _ in }
    #expect(ev2.pending.isEmpty)
    #expect(Set(ev2.files.map(\.rel)) == Set(ev.files.map(\.rel)))
}
