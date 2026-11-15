import Foundation
import Testing
@testable import CirrusCore

/// Regressions from the iOS audit: a photo export must never replace a file it didn't write.
@Suite(.serialized) struct ExportSafetyTests {
    func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-export-\(UUID().uuidString.prefix(8))/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func companionFilesNeverReplaceTheUsersFiles() async throws {
        setenv("CIRRUS_DEMO_FAST", "1", 1)
        setenv("CIRRUS_PROFILE", "tests", 1)
        let photos = DemoPhotos.shared
        let lib = try await photos.libraries()[0]
        let live = try await photos.albums(in: lib).first { $0.id == "smart:Live" }!
        let assets = try await photos.assets(in: live, library: lib) { _, _ in }
        let a = try #require(assets.first)
        let stem = (a.filename as NSString).deletingPathExtension
        let dest = tempDir("flat")
        // The user's own files with the names Cirrus would pick for the Live Photo's video and the original.
        let mine = Data("my own video".utf8), myPhoto = Data("my own photo".utf8)
        try mine.write(to: dest.appendingPathComponent(stem + ".MOV"))
        try myPhoto.write(to: dest.appendingPathComponent("unrelated.txt"))
        var opts = SyncOptions()
        opts.photoLayout = "flat"
        opts.writeManifest = false
        let ex = PhotoExporter(backend: photos, library: lib, album: live, destination: dest, options: opts)
        let ev = try await ex.evaluate { _ in }
        let mineFiles = ev.files.filter { $0.asset.id == a.id }
        #expect(mineFiles.count >= 2)
        #expect(!mineFiles.contains { $0.rel == stem + ".MOV" }, "the Live Photo video must not take the user's file name")
        #expect(Set(ev.files.map { $0.rel.lowercased() }).count == ev.files.count, "no two planned files share a path")
        let rep = try await ex.run(ev) { _ in }
        #expect(rep.failed.isEmpty)
        #expect(try Data(contentsOf: dest.appendingPathComponent(stem + ".MOV")) == mine)
        #expect(try Data(contentsOf: dest.appendingPathComponent("unrelated.txt")) == myPhoto)
        for f in mineFiles { #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(f.rel).path)) }
        // A second run keeps the same names and has nothing to do.
        let ev2 = try await PhotoExporter(backend: photos, library: lib, album: live, destination: dest, options: opts).evaluate { _ in }
        #expect(ev2.pending.isEmpty)
        #expect(Set(ev2.files.map(\.rel)) == Set(ev.files.map(\.rel)))
    }

    @Test func manifestPathsCantLeaveTheExportFolder() {
        #expect(PhotoExporter.isSafeRelative("2026/11/IMG_1.JPG"))
        #expect(!PhotoExporter.isSafeRelative("../outside.JPG"))
        #expect(!PhotoExporter.isSafeRelative("2026/../../x.JPG"))
        #expect(!PhotoExporter.isSafeRelative("/etc/x"))
        #expect(!PhotoExporter.isSafeRelative(""))
    }
}
