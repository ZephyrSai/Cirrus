import Foundation
import Testing
@testable import CirrusCore

final class DAVProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: (Int64, Int64) = (0, 0)
    private var _calls = 0
    func note(_ a: Int64, _ b: Int64) { lock.withLock { _last = (a, b); _calls += 1 } }
    var last: (Int64, Int64) { lock.withLock { _last } }
    var calls: Int { lock.withLock { _calls } }
}

/// The WebDAV / Nextcloud connector against FakeWebDAVServer (shared state, so one test at a time).
@Suite(.serialized) struct WebDAVTests {
    typealias Fake = FakeWebDAVServer
    static let transport: [AnyClass] = [FakeWebDAVServer.self]

    static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-dav-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func file(_ data: Data, _ name: String = "upload.bin") throws -> URL {
        let u = tempDir("src").appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    func drive(_ p: CloudProvider, _ s: Fake.State = .seeded(), password: String? = nil, username: String? = nil) throws -> WebDAVDrive {
        Fake.reset(s)
        let r: CloudAccountRecord
        if p == .nextcloud {
            r = CloudAccountRecord(id: "cloud:nextcloud:test", provider: .nextcloud, title: "alex@cloud.example.com",
                                   server: "https://cloud.example.com", username: username ?? s.nextcloud.loginName)
        } else {
            r = CloudAccountRecord(id: "cloud:webdav:test", provider: .webdav, title: "alex@dav.example.com",
                                   server: "https://dav.example.com/webdav/", username: username ?? s.plain.loginName)
        }
        let d = try WebDAVDrive(record: r, password: password ?? (p == .nextcloud ? s.nextcloud.password : s.plain.password), transport: Self.transport)
        d.retryBase = 0.001
        return d
    }

    func caught(_ op: () async throws -> Void) async -> Error? {
        do { try await op(); return nil } catch { return error }
    }

    func deniedMessage(_ e: Error?) -> String? {
        if case .denied(let m)? = e as? CloudError { return m }
        return nil
    }

    func node(_ d: WebDAVDrive, _ folder: String, _ name: String) async throws -> DriveNode {
        try #require(try await d.list(folder).first { $0.name == name.precomposedStringWithCanonicalMapping })
    }

    // MARK: Listing

    @Test(arguments: [CloudProvider.nextcloud, .webdav])
    func listsTheTopFolderAndSubfolders(_ p: CloudProvider) async throws {
        let d = try drive(p)
        let top = try await d.list(d.rootID)
        #expect(Set(top.filter(\.isFolder).map(\.name)).isSuperset(of: ["Documents", "Photos", "Projects"]))
        for n in top {
            #expect(n.parentID == d.rootID)
            #expect(n.zone == "dav")
            #expect(n.id.hasPrefix("dav:/"))
            #expect(n.isFolder == n.id.hasSuffix("/"))
            #expect(n.type == (n.isFolder ? "FOLDER" : "FILE"))
        }
        let docs = try #require(top.first { $0.name == "Documents" })
        #expect(docs.id == "dav:/Documents/")
        #expect(top.first { $0.name == "Projects" }?.isShared == (p == .nextcloud))
        #expect(!docs.isShared)
        let items = try await d.list(docs.id)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.parentID == "dav:/Documents/" })
        let pdfName = p == .nextcloud ? "Project brief.pdf" : "Manual.pdf"
        let pdf = try #require(items.first { $0.name == pdfName })
        let server = try #require(Fake.state.file("/Documents/" + pdfName, plain: p == .webdav))
        #expect(pdf.id == "dav:/Documents/" + pdfName)
        #expect(pdf.size == Int64(server.data.count))
        #expect(pdf.modified == server.modified)
        #expect(pdf.etag == server.etag)
        if p == .nextcloud { #expect(pdf.docID == String(server.fileID)) } else { #expect(pdf.docID == nil) }
        // Nested folders and listMany (bounded concurrency) agree with list.
        let projects = try await d.list("dav:/Projects/")
        let many = try await d.listMany(["dav:/Documents/", "dav:/Projects/", "dav:/Photos/", "dav:/Documents/"])
        #expect(Set(many.keys) == ["dav:/Documents/", "dav:/Projects/", "dav:/Photos/"])
        #expect(Set(many["dav:/Projects/"]!.map(\.id)) == Set(projects.map(\.id)))
        let all = try await d.walk(d.rootID)
        #expect(all.contains { $0.path == "Documents/" + pdfName })
    }

    static let oddNames = ["a b.txt", "hash #1.txt", "100% done.txt", "what?.txt", "c++ & more.txt", "Cafe\u{301} u\u{308}nicode.txt",
                           "日本語のファイル.txt", "semi;colon=eq,comma.txt", "it's (1) [x] {y}.txt", "  leading spaces.txt", "plus+sign+.txt"]

    @Test(arguments: [Fake.HrefStyle.path, .absoluteURL, .relative])
    func oddNamesSurviveEveryHrefStyle(_ style: Fake.HrefStyle) async throws {
        for p in [CloudProvider.nextcloud, .webdav] {
            var s = Fake.State.seeded()
            s.hrefStyle = style
            s.hrefNFD = style == .relative     // decomposed Unicode in hrefs, like some servers on Apple file systems
            s.echoSelf = style != .absoluteURL // and one style without the folder echoed back
            let folder = "Odd #2 & Ünïcode%20 folder"
            for n in Self.oddNames { s.add("/\(folder)/" + n, Data(n.utf8), plain: p == .webdav) }
            let d = try drive(p, s)
            let top = try await d.list(d.rootID)
            let odd = try #require(top.first { $0.name == folder.precomposedStringWithCanonicalMapping }, "\(p) \(style)")
            #expect(odd.isFolder)
            let items = try await d.list(odd.id)
            #expect(Set(items.map(\.name)) == Set(Self.oddNames.map(\.precomposedStringWithCanonicalMapping)), "\(p) \(style)")
            for item in items {
                #expect(item.parentID == odd.id)
                let dest = Self.tempDir("odd").appendingPathComponent("f")
                try await d.download(item, to: dest) { _, _ in }
                #expect(String(decoding: try Data(contentsOf: dest), as: UTF8.self).precomposedStringWithCanonicalMapping == item.name)
            }
            // Upload, rename and move with odd names too.
            let up = try await d.upload(try Self.file(Data("new".utf8)), name: "new #?%+&.txt", into: odd.id, modified: nil) { _, _ in }
            #expect(up.name == "new #?%+&.txt")
            let renamed = try await d.rename(up, to: "renamed ü #2.txt")
            #expect(try await d.list(odd.id).contains { $0.id == renamed.id && $0.name == "renamed ü #2.txt" })
            let sub = try await d.createFolder("sub & dir #", in: odd.id)
            try await d.move([renamed], to: sub.id)
            #expect(try await d.list(sub.id).map(\.name) == ["renamed ü #2.txt"])
        }
    }

    @Test func failedListingsThrowInsteadOfLookingEmpty() async throws {
        for p in [CloudProvider.nextcloud, .webdav] {
            var s = Fake.State.seeded()
            s.failPropfind = ["/Documents/"]
            s.truncatePropfind = ["/Photos/"]
            let d = try drive(p, s)
            #expect(await caught { _ = try await d.list("dav:/Documents/") } != nil)
            #expect(await caught { _ = try await d.list("dav:/Photos/") } != nil)
            #expect(await caught { _ = try await d.listMany(["dav:/Projects/", "dav:/Documents/"]) } != nil)
            #expect(await caught { _ = try await d.walk(d.rootID) } != nil)
            let missing = await caught { _ = try await d.list("dav:/No such folder/") }
            #expect(missing as? CloudError == .notFound)
            // A file isn't a folder.
            #expect(await caught { _ = try await d.list("dav:/Projects/Roadmap.md/") } != nil || p == .webdav)
        }
    }

    @Test func serverHiccupsAreRetriedButMovesAreNotRepeated() async throws {
        let d = try drive(.nextcloud)
        Fake.update { $0.rateLimitNext = 2 }
        #expect(try await d.list(d.rootID).count > 0)
        Fake.update { $0.unavailableNext = 2 }
        #expect(try await d.list("dav:/Documents/").count > 0)
        // A 503 on MOVE might have been processed elsewhere: it is reported, not repeated.
        let notes = try await node(d, "dav:/Documents/", "Meeting notes.txt")
        Fake.update { $0.unavailableNext = 1; $0.calls = [] }
        #expect(await caught { _ = try await d.rename(notes, to: "Other.txt") } != nil)
        #expect(Fake.state.calls.filter { $0.hasPrefix("MOVE") }.count == 1)
        // A 429 means "not processed": that one is retried.
        Fake.update { $0.rateLimitNext = 1; $0.calls = [] }
        let r = try await d.rename(notes, to: "Other.txt")
        #expect(r.name == "Other.txt")
        #expect(Fake.state.calls.filter { $0.hasPrefix("MOVE") }.count == 2)
    }

    // MARK: Transfers

    @Test(arguments: [CloudProvider.nextcloud, .webdav])
    func uploadAndDownloadKeepContentAndDates(_ p: CloudProvider) async throws {
        let d = try drive(p)
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let mtime = Date(timeIntervalSince1970: 1_700_000_123)
        let box = DAVProgressBox()
        let n = try await d.upload(try Self.file(bytes), name: "Report 2026.bin", into: "dav:/Documents/", modified: mtime) { a, b in box.note(a, b) }
        #expect(n.id == "dav:/Documents/Report 2026.bin")
        #expect(n.parentID == "dav:/Documents/")
        #expect(n.size == 300_000)
        #expect(n.type == "FILE")
        #expect(box.last.0 == 300_000 && box.last.1 == 300_000)
        let server = try #require(Fake.state.file("/Documents/Report 2026.bin", plain: p == .webdav))
        #expect(server.data == bytes)
        if p == .nextcloud {
            #expect(server.modified == mtime)     // X-OC-Mtime
            #expect(n.modified == mtime)
            #expect(n.docID == String(server.fileID))
        }
        let dest = Self.tempDir("dl").appendingPathComponent("Report 2026.bin")
        let dbox = DAVProgressBox()
        try await d.download(n, to: dest) { a, b in dbox.note(a, b) }
        #expect(try Data(contentsOf: dest) == bytes)
        #expect(dbox.last.0 == 300_000)
        let fileDate = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(fileDate.map { abs($0.timeIntervalSince(n.modified!)) < 1 } == true)
        // An upload never replaces an existing item by accident.
        let e = await caught { _ = try await d.upload(try Self.file(Data("other".utf8)), name: "Report 2026.bin", into: "dav:/Documents/", modified: nil) { _, _ in } }
        #expect(deniedMessage(e)?.contains("already") == true)
        #expect(Fake.state.file("/Documents/Report 2026.bin", plain: p == .webdav)?.data == bytes)
        // Empty files work too.
        let empty = try await d.upload(try Self.file(Data()), name: "empty.txt", into: d.rootID, modified: nil) { _, _ in }
        #expect(empty.size == 0)
        let ed = Self.tempDir("dl").appendingPathComponent("empty.txt")
        try await d.download(empty, to: ed) { _, _ in }
        #expect(try Data(contentsOf: ed).isEmpty)
    }

    @Test func bigNextcloudUploadsGoInChunks() async throws {
        let d = try drive(.nextcloud)
        d.chunkSize = 5 << 20
        d.chunkThreshold = 5 << 20
        let bytes = Data((0..<(12 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 12)) })
        let mtime = Date(timeIntervalSince1970: 1_750_000_000)
        let box = DAVProgressBox()
        let n = try await d.upload(try Self.file(bytes), name: "Big video.mov", into: "dav:/Photos/", modified: mtime) { a, b in box.note(a, b) }
        let s = Fake.state
        #expect(s.chunkPuts == 3)
        #expect(s.chunkAssemblies == 1)
        #expect(s.calls.contains { $0.hasPrefix("MKCOL /remote.php/dav/uploads/alex/cirrus-") })
        #expect(s.calls.contains { $0.hasPrefix("MOVE /remote.php/dav/uploads/alex/cirrus-") && $0.hasSuffix("/.file") })
        #expect(!s.calls.contains { $0.hasPrefix("PUT /remote.php/dav/files/") })
        let server = try #require(s.file("/Photos/Big video.mov"))
        #expect(server.data == bytes)
        #expect(server.modified == mtime)
        #expect(n.size == Int64(bytes.count))
        #expect(n.docID == String(server.fileID))
        #expect(box.last.0 == Int64(bytes.count))
        // The same name again is refused before anything is sent.
        Fake.update { $0.calls = [] }
        let e = await caught { _ = try await d.upload(try Self.file(bytes), name: "Big video.mov", into: "dav:/Photos/", modified: nil) { _, _ in } }
        #expect(deniedMessage(e)?.contains("already") == true)
        #expect(!Fake.state.calls.contains { $0.hasPrefix("MKCOL") })
        // Chunks the server finds too small: a clear failure, and the upload folder is cleaned up.
        d.chunkSize = 1 << 20
        let e2 = await caught { _ = try await d.upload(try Self.file(bytes), name: "Too small chunks.mov", into: "dav:/Photos/", modified: nil) { _, _ in } }
        #expect(e2 != nil)
        #expect(Fake.state.file("/Photos/Too small chunks.mov") == nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(Fake.state.calls.contains { $0.hasPrefix("DELETE /remote.php/dav/uploads/alex/cirrus-") })
    }

    @Test func safeReplaceSwapsTheFileAndKeepsTheOldOneDeleted() async throws {
        for p in [CloudProvider.nextcloud, .webdav] {
            let d = try drive(p)
            let docs = "dav:/Documents/"
            let name = p == .nextcloud ? "Meeting notes.txt" : "Notes.txt"
            let old = try await node(d, docs, name)
            let n = try await d.safeReplace(try Self.file(Data("new content".utf8)), name: name, in: docs, existing: old, modified: nil) { _, _ in }
            #expect(n.name == name)
            #expect(Fake.state.file("/Documents/" + name, plain: p == .webdav)?.data == Data("new content".utf8))
            #expect(try await d.listTrash().contains { $0.name == name })
            #expect(Fake.state.permanentDeletes == 0)
        }
    }

    // MARK: Folders, rename, move

    @Test(arguments: [CloudProvider.nextcloud, .webdav])
    func foldersRenameMoveAndNameClashes(_ p: CloudProvider) async throws {
        let d = try drive(p)
        let f = try await d.createFolder("New Folder", in: d.rootID)
        #expect(f.id == "dav:/New Folder/")
        #expect(f.isFolder && f.parentID == d.rootID)
        #expect(deniedMessage(await caught { _ = try await d.createFolder("New Folder", in: d.rootID) })?.contains("already") == true)
        let renamed = try await d.rename(f, to: "Archive 2026")
        #expect(renamed.id == "dav:/Archive 2026/" && renamed.name == "Archive 2026")
        #expect(try await d.list(d.rootID).contains { $0.id == "dav:/Archive 2026/" })
        #expect(try await d.list(d.rootID).contains { $0.id == "dav:/New Folder/" } == false)

        let docs = try await d.list("dav:/Documents/")
        let files = docs.filter { !$0.isFolder }
        #expect(files.count >= 2)
        // Rename onto an existing sibling: refused, nothing changed.
        let e = await caught { _ = try await d.rename(files[0], to: files[1].name) }
        #expect(deniedMessage(e)?.contains("already") == true)
        #expect(Set(try await d.list("dav:/Documents/").map(\.id)) == Set(docs.map(\.id)))

        // Move, then a clash in the target, then a folder into itself.
        try await d.move([files[0]], to: renamed.id)
        #expect(try await d.list(renamed.id).map(\.name) == [files[0].name])
        _ = try await d.upload(try Self.file(Data("x".utf8)), name: files[1].name, into: renamed.id, modified: nil) { _, _ in }
        #expect(deniedMessage(await caught { try await d.move([files[1]], to: renamed.id) })?.contains("already") == true)
        #expect(try await d.list("dav:/Documents/").contains { $0.id == files[1].id })
        let inner = try await d.createFolder("Inner", in: renamed.id)
        #expect(await caught { try await d.move([renamed], to: inner.id) } != nil)
        // Moving whole folders keeps their contents.
        try await d.move([renamed], to: "dav:/Projects/")
        #expect(try await d.list("dav:/Projects/Archive 2026/").count == 3)
        // Names that can't exist on a server.
        #expect(await caught { _ = try await d.createFolder("a/b", in: d.rootID) } != nil)
        #expect(await caught { _ = try await d.rename(inner, to: "..") } != nil)
    }

    @Test func caseOnlyRenameWorksOnCaseInsensitiveServers() async throws {
        var s = Fake.State.seeded()
        s.plainCaseInsensitive = true
        let d = try drive(.webdav, s)
        let notes = try await node(d, "dav:/Documents/", "Notes.txt")
        let r = try await d.rename(notes, to: "NOTES.txt")
        #expect(r.name == "NOTES.txt" && r.id == "dav:/Documents/NOTES.txt")
        #expect(try await d.list("dav:/Documents/").filter { $0.name.lowercased() == "notes.txt" }.map(\.name) == ["NOTES.txt"])
        // A real clash is still refused.
        let inv = try await node(d, "dav:/Documents/", "Inventory.csv")
        #expect(deniedMessage(await caught { _ = try await d.rename(inv, to: "notes.TXT") })?.contains("already") == true)
    }

    @Test func lockedFilesAndFullStorageGiveClearErrors() async throws {
        var s = Fake.State.seeded()
        s.lockedPaths = ["/Documents/Meeting notes.txt"]
        s.nextcloud.quota = s.nextcloud.usedBytes + 10
        let d = try drive(.nextcloud, s)
        let notes = try await node(d, "dav:/Documents/", "Meeting notes.txt")
        #expect(deniedMessage(await caught { _ = try await d.rename(notes, to: "x.txt") })?.contains("locked") == true)
        let e = await caught { _ = try await d.upload(try Self.file(Data(count: 1000)), name: "big.bin", into: d.rootID, modified: nil) { _, _ in } }
        #expect(e as? CloudError == .quotaExceeded("Nextcloud (alex@cloud.example.com)"))
    }

    // MARK: Trash

    @Test func nextcloudTrashBinRoundTrip() async throws {
        let d = try drive(.nextcloud)
        let notes = try await node(d, "dav:/Documents/", "Meeting notes.txt")
        let website = try await node(d, "dav:/Projects/", "Website")
        try await d.trash([notes, website])
        #expect(Fake.state.permanentDeletes == 0)
        #expect(Fake.state.nextcloud.trash.count == 3)
        #expect(try await d.list("dav:/Documents/").contains { $0.name == "Meeting notes.txt" } == false)

        let bin = try await d.listTrash()
        #expect(Set(bin.map(\.name)) == ["Meeting notes.txt", "Website", "Old draft.txt"])
        #expect(bin.allSatisfy { $0.id.hasPrefix("dav-trash:/") && $0.parentID == "dav-trash:/" })
        let w = try #require(bin.first { $0.name == "Website" })
        #expect(w.isFolder)
        #expect(Set(try await d.list(w.id).map(\.name)) == ["index.html", "style.css"])
        let n = try #require(bin.first { $0.name == "Meeting notes.txt" })
        let dest = Self.tempDir("bin").appendingPathComponent("n.txt")
        try await d.download(n, to: dest) { _, _ in }
        #expect(String(decoding: try Data(contentsOf: dest), as: UTF8.self).contains("Agenda"))

        try await d.restore([n])
        #expect(try await d.list("dav:/Documents/").contains { $0.name == "Meeting notes.txt" })
        #expect(Fake.state.file("/Documents/Meeting notes.txt")?.data.isEmpty == false)

        // Only items in the trash can be erased.
        let live = try await node(d, "dav:/Documents/", "Meeting notes.txt")
        #expect(await caught { try await d.deleteForever([live]) } != nil)
        #expect(await caught { try await d.restore([live]) } != nil)
        #expect(Fake.state.permanentDeletes == 0)

        try await d.deleteForever([w])
        #expect(Fake.state.permanentDeletes == 1)
        #expect(Set(try await d.listTrash().map(\.name)) == ["Old draft.txt"])
        // Restoring when the original folder is gone puts it at the top.
        let draft = try #require(try await d.listTrash().first)
        Fake.update { s in for k in s.nextcloud.files.keys where k.hasPrefix("/Documents/") { s.nextcloud.files[k] = nil } }
        try await d.restore([draft])
        #expect(try await d.list(d.rootID).contains { $0.name == "Old draft.txt" })
    }

    @Test func plainWebDAVTrashUsesDeletedByCirrus() async throws {
        let d = try drive(.webdav)
        let notes = try await node(d, "dav:/Documents/", "Notes.txt")
        let photos = try await node(d, d.rootID, "Photos")
        try await d.trash([notes, photos])
        #expect(Fake.state.permanentDeletes == 0)
        let s = Fake.state
        #expect(s.file("/Deleted by Cirrus/Notes.txt", plain: true) != nil)
        #expect(s.file("/Deleted by Cirrus/Photos/Beach.jpg", plain: true) != nil)
        let manifest = try #require(s.file("/Deleted by Cirrus/.cirrus-deleted.json", plain: true))
        #expect(String(decoding: manifest.data, as: UTF8.self).contains("/Documents/"))
        // The folder is Cirrus's trash: not shown among the files.
        #expect(try await d.list(d.rootID).contains { $0.name == WebDAVDrive.trashFolderName } == false)
        var bin = try await d.listTrash()
        #expect(Set(bin.map(\.name)) == ["Notes.txt", "Photos"])

        // A second "Notes.txt" gets its own name inside the folder but shows its real name.
        _ = try await d.upload(try Self.file(Data("project notes".utf8)), name: "Notes.txt", into: "dav:/Projects/", modified: nil) { _, _ in }
        try await d.trash([try await node(d, "dav:/Projects/", "Notes.txt")])
        #expect(Fake.state.file("/Deleted by Cirrus/Notes 2.txt", plain: true)?.data == Data("project notes".utf8))
        bin = try await d.listTrash()
        #expect(bin.filter { $0.name == "Notes.txt" }.count == 2)

        // Restore goes back where each item came from.
        let projectNotes = try #require(bin.first { $0.id == "dav:/Deleted by Cirrus/Notes 2.txt" })
        try await d.restore([projectNotes])
        #expect(Fake.state.file("/Projects/Notes.txt", plain: true)?.data == Data("project notes".utf8))
        // …or to the top when the original folder is gone.
        Fake.update { s in for k in s.plain.files.keys where k.hasPrefix("/Documents/") { s.plain.files[k] = nil } }
        let docNotes = try #require(try await d.listTrash().first { $0.name == "Notes.txt" })
        try await d.restore([docNotes])
        #expect(Fake.state.file("/Notes.txt", plain: true) != nil)

        // Only items in the trash can be erased.
        let live = try await node(d, d.rootID, "Notes.txt")
        #expect(await caught { try await d.deleteForever([live]) } != nil)
        #expect(Fake.state.permanentDeletes == 0)
        let p = try #require(try await d.listTrash().first { $0.name == "Photos" })
        try await d.deleteForever([p])
        #expect(Fake.state.permanentDeletes == 1)
        #expect(try await d.listTrash().isEmpty)
        let left = String(decoding: Fake.state.file("/Deleted by Cirrus/.cirrus-deleted.json", plain: true)?.data ?? Data(), as: UTF8.self)
        #expect(!left.contains("Photos"))
    }

    @Test func nextcloudWithoutItsTrashAppNeverErases() async throws {
        var s = Fake.State.seeded()
        s.trashbinEnabled = false
        let d = try drive(.nextcloud, s)
        let notes = try await node(d, "dav:/Documents/", "Meeting notes.txt")
        try await d.trash([notes])
        #expect(Fake.state.permanentDeletes == 0)
        #expect(Fake.state.file("/Deleted by Cirrus/Meeting notes.txt") != nil)
        #expect(try await d.listTrash().map(\.name) == ["Meeting notes.txt"])
        #expect(try await d.list(d.rootID).contains { $0.name == WebDAVDrive.trashFolderName } == false)
        // A fresh connection (trash app state unknown) still hides the folder.
        let again = try WebDAVDrive(record: d.record, password: s.nextcloud.password, transport: Self.transport)
        #expect(try await again.list(again.rootID).contains { $0.name == WebDAVDrive.trashFolderName } == false)
        try await d.restore(try await d.listTrash())
        #expect(Fake.state.file("/Documents/Meeting notes.txt") != nil)
        // With the trash app on, a folder of that name is just a folder.
        Fake.update { $0.trashbinEnabled = true }
        let on = try WebDAVDrive(record: d.record, password: s.nextcloud.password, transport: Self.transport)
        #expect(try await on.list(on.rootID).contains { $0.name == WebDAVDrive.trashFolderName })
    }

    // MARK: Quota, thumbnails, sign-in

    @Test func quotaComesFromTheServerWhenItSays() async throws {
        let nc = try drive(.nextcloud)
        let q = try #require(try await nc.quota())
        let used = Fake.state.nextcloud.usedBytes
        #expect(q.used == used && q.total == 10_000_000_000)
        var s = Fake.State.seeded()
        s.nextcloud.quota = nil      // unlimited: Nextcloud says -3
        #expect(try await drive(.nextcloud, s).quota() == nil)
        #expect(try await drive(.webdav).quota() == nil)
        s = .seeded()
        s.plainHasQuota = true
        s.plain.quota = 5_000_000
        let pq = try #require(try await drive(.webdav, s).quota())
        #expect(pq.total == 5_000_000 && pq.used == s.plain.usedBytes)
    }

    @Test func thumbnailsComeFromNextcloudsPreviewService() async throws {
        let d = try drive(.nextcloud)
        let photos = try await d.list("dav:/Photos/")
        let jpg = try #require(photos.first { $0.name == "Harbor at dusk.jpg" })
        let png = try #require(try await d.thumbnail(jpg, maxPixel: 256))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(Fake.state.previewRequests == 1)
        // Nextcloud said there's no preview for this one: no request at all.
        let bin = try await d.upload(try Self.file(Data(count: 10)), name: "data.bin", into: "dav:/Photos/", modified: nil) { _, _ in }
        _ = try await d.list("dav:/Photos/")
        #expect(try await d.thumbnail(bin, maxPixel: 256) == nil)
        #expect(Fake.state.previewRequests == 1)
        // Unknown to the listing and not previewable: 404 → nil.
        var unknown = bin
        unknown.id = "dav:/Photos/unlisted.bin"
        #expect(try await d.thumbnail(unknown, maxPixel: 64) == nil)
        #expect(try await d.thumbnail(try await node(d, d.rootID, "Photos"), maxPixel: 64) == nil)
        let plain = try drive(.webdav)
        let beach = try await node(plain, "dav:/Photos/", "Beach.jpg")
        #expect(try await plain.thumbnail(beach, maxPixel: 128) == nil)
    }

    @Test func wrongPasswordMeansSignInNeeded() async throws {
        let nc = try drive(.nextcloud, password: "revoked-app-password")
        #expect(await caught { _ = try await nc.list(nc.rootID) } as? CloudError == .signInNeeded("Nextcloud (alex@cloud.example.com)"))
        let plain = try drive(.webdav, password: "wrong")
        #expect(await caught { _ = try await plain.list(plain.rootID) } as? CloudError == .signInNeeded("WebDAV (alex@dav.example.com)"))
        #expect(Fake.state.unauthorized >= 1)
        let readme = DriveNode(id: "dav:/Readme.md", zone: "dav", parentID: "dav:/", name: "Readme.md", type: "FILE", size: 10, modified: nil, created: nil, etag: nil)
        #expect(await caught { try await nc.download(readme, to: Self.tempDir("auth").appendingPathComponent("r")) { _, _ in } } as? CloudError
                == .signInNeeded("Nextcloud (alex@cloud.example.com)"))
        // No password saved for a Nextcloud account: sign in again.
        let r = CloudAccountRecord(provider: .nextcloud, title: "alex@cloud.example.com", server: "https://cloud.example.com", username: "alex")
        #expect(throws: CloudError.self) { _ = try WebDAV.make(record: r, secret: CloudSecret(), transport: Self.transport) }
    }

    @Test func nextcloudUserIDCanDifferFromTheLoginName() async throws {
        var s = Fake.State.seeded()
        s.nextcloud.loginName = "alex@example.com"
        let d = try drive(.nextcloud, s)
        #expect(try await d.list(d.rootID).contains { $0.name == "Documents" })
        #expect(Fake.state.calls.contains { $0.hasPrefix("PROPFIND /remote.php/dav/files/alex/") })
        #expect(!Fake.state.calls.contains { $0.contains("files/alex@example.com") })
    }

    @Test func plainHTTPIsRefusedExceptOnThisDevice() throws {
        #expect(throws: CloudError.self) { _ = try WebDAV.folderURL(from: "http://dav.example.com/webdav") }
        #expect(throws: CloudError.self) { _ = try NextcloudLoginFlow.baseURL(from: "http://cloud.example.com") }
        #expect(try WebDAV.folderURL(from: "http://localhost:8080/dav").absoluteString == "http://localhost:8080/dav/")
        #expect(try WebDAV.folderURL(from: "http://127.0.0.1:18080/dav/").absoluteString == "http://127.0.0.1:18080/dav/")
        let r = CloudAccountRecord(provider: .webdav, title: "x", server: "http://nas.example.com/dav/", username: "alex")
        #expect(throws: CloudError.self) { _ = try WebDAV.make(record: r, secret: CloudSecret(password: "p"), transport: Self.transport) }
        do {
            _ = try WebDAV.folderURL(from: "http://dav.example.com")
            Issue.record("http:// should be refused")
        } catch CloudError.unsupported(let m) {
            #expect(m.contains("https://"))
        } catch {
            Issue.record("http:// should be refused with an explanation, got \(error)")
        }
    }

    @Test func serverAddressesAreNormalized() throws {
        let cases = ["cloud.example.com": "https://cloud.example.com",
                     "https://cloud.example.com/": "https://cloud.example.com",
                     " https://Cloud.Example.com/index.php/apps/files/?dir=/Photos ": "https://cloud.example.com",
                     "https://example.com/nextcloud/index.php": "https://example.com/nextcloud",
                     "https://example.com/nextcloud/remote.php/dav/files/alex/": "https://example.com/nextcloud",
                     "example.com:8443/nc/login": "https://example.com:8443/nc",
                     "http://localhost:8080": "http://localhost:8080"]
        for (input, want) in cases { #expect(try NextcloudLoginFlow.baseURL(from: input).absoluteString == want, "\(input)") }
        #expect(try WebDAV.folderURL(from: "dav.example.com/webdav").absoluteString == "https://dav.example.com/webdav/")
        #expect(try WebDAV.folderURL(from: "https://user:secret@nas.example.com/dav?x=1#f").absoluteString == "https://nas.example.com/dav/")
        #expect(throws: CloudError.self) { _ = try NextcloudLoginFlow.baseURL(from: "  ") }
        #expect(throws: CloudError.self) { _ = try WebDAV.folderURL(from: "ftp://nas.example.com/") }
    }

    // MARK: Sign-in helpers

    @Test func loginFlowV2() async throws {
        var s = Fake.State.seeded()
        s.approveAfterPolls = 3
        Fake.reset(s)
        NextcloudLoginFlow.pollInterval = 0.01
        let pending = try await NextcloudLoginFlow.begin(server: URL(string: "cloud.example.com")!, transport: Self.transport)
        #expect(pending.server.absoluteString == "https://cloud.example.com")
        #expect(pending.loginURL.absoluteString.hasPrefix("https://cloud.example.com/login/v2/flow/"))
        let (record, secret) = try await NextcloudLoginFlow.poll(pending, timeout: 10, transport: Self.transport)
        #expect(record.provider == .nextcloud)
        #expect(record.server == "https://cloud.example.com")
        #expect(record.username == "alex")
        #expect(record.title == "alex@cloud.example.com")
        #expect(record.id.hasPrefix("cloud:nextcloud:"))
        let app = try #require(secret.password)
        #expect(Fake.state.nextcloud.appPasswords.contains(app))
        #expect(app != Fake.state.nextcloud.password)
        #expect(Fake.state.loginPolls == 3)
        #expect(Fake.state.lastUserAgent?.hasPrefix("Cirrus") == true)
        // The new account works.
        let backend = try makeBackend(record, secret)
        #expect(try await backend.list(backend.rootID).contains { $0.name == "Documents" })
        // A token works once.
        #expect(await caught { _ = try await NextcloudLoginFlow.poll(pending, timeout: 0.1, transport: Self.transport) } != nil)

        // The user approves on the page (and never otherwise): poll returns then.
        Fake.update { $0.approveAfterPolls = nil }
        let p2 = try await NextcloudLoginFlow.begin(server: URL(string: "https://cloud.example.com/index.php/apps/files")!, transport: Self.transport)
        let waiting = Task { try await NextcloudLoginFlow.poll(p2, timeout: 10, transport: Self.transport) }
        try await Task.sleep(nanoseconds: 100_000_000)
        Fake.approve(p2.loginURL)
        #expect(try await waiting.value.record.username == "alex")

        // Never approved: a timeout, or cancellation.
        let p3 = try await NextcloudLoginFlow.begin(server: URL(string: "https://cloud.example.com")!, transport: Self.transport)
        #expect(deniedMessage(await caught { _ = try await NextcloudLoginFlow.poll(p3, timeout: 0.1, transport: Self.transport) }) != nil)
        let cancelled = Task { try await NextcloudLoginFlow.poll(p3, timeout: 30, transport: Self.transport) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        let ce = await caught { _ = try await cancelled.value }
        #expect(ce is CancellationError)
        // Not a Nextcloud.
        #expect(await caught { _ = try await NextcloudLoginFlow.begin(server: URL(string: "https://dav.example.com")!, transport: Self.transport) } != nil)
    }

    func makeBackend(_ r: CloudAccountRecord, _ s: CloudSecret) throws -> CloudDriveBackend {
        try WebDAV.make(record: r, secret: s, transport: Self.transport)
    }

    @Test func connectDetectsNextcloud() async throws {
        Fake.reset(.seeded())
        let pw = Fake.state.nextcloud.password
        // A Nextcloud WebDAV address, or just the server: both become a Nextcloud account.
        for url in ["https://cloud.example.com/remote.php/dav/files/alex/", "https://cloud.example.com", "https://cloud.example.com/remote.php/webdav"] {
            let (r, secret) = try await WebDAV.connect(url: URL(string: url)!, username: "alex", password: pw, transport: Self.transport)
            #expect(r.provider == .nextcloud, "\(url)")
            #expect(r.server == "https://cloud.example.com")
            #expect(r.username == "alex" && r.title == "alex@cloud.example.com")
            #expect(secret.password == pw)
        }
        // Even when status.php is hidden, Nextcloud's own properties give it away.
        Fake.update { $0.hideStatusPage = true }
        let (hidden, _) = try await WebDAV.connect(url: URL(string: "https://cloud.example.com/remote.php/dav/files/alex/")!, username: "alex",
                                                   password: pw, transport: Self.transport)
        #expect(hidden.provider == .nextcloud)
        Fake.update { $0.hideStatusPage = false }

        // A plain WebDAV folder (the missing trailing slash is fine).
        let (plain, ps) = try await WebDAV.connect(url: URL(string: "https://dav.example.com/webdav")!, username: "alex",
                                                   password: Fake.state.plain.password, transport: Self.transport)
        #expect(plain.provider == .webdav)
        #expect(plain.server == "https://dav.example.com/webdav/")
        #expect(plain.title == "alex@dav.example.com")
        let backend = try WebDAV.make(record: plain, secret: ps, transport: Self.transport)
        #expect(try await backend.list(backend.rootID).contains { $0.name == "Backups" })

        // Wrong password, wrong path, and http://.
        #expect(deniedMessage(await caught { _ = try await WebDAV.connect(url: URL(string: "https://dav.example.com/webdav/")!, username: "alex",
                                                                         password: "nope", transport: Self.transport) }) != nil)
        #expect(deniedMessage(await caught { _ = try await WebDAV.connect(url: URL(string: "https://cloud.example.com")!, username: "alex",
                                                                         password: "nope", transport: Self.transport) }) != nil)
        let wrongPath = await caught { _ = try await WebDAV.connect(url: URL(string: "https://dav.example.com/elsewhere/")!, username: "alex",
                                                                   password: Fake.state.plain.password, transport: Self.transport) }
        if case .notConfigured? = wrongPath as? CloudError {} else { Issue.record("expected notConfigured, got \(String(describing: wrongPath))") }
        Fake.update { $0.calls = [] }
        #expect(await caught { _ = try await WebDAV.connect(url: URL(string: "http://dav.example.com/webdav/")!, username: "alex",
                                                           password: "p", transport: Self.transport) } != nil)
        #expect(Fake.state.calls.isEmpty)
    }

    @Test func demoAccountsWork() async throws {
        Fake.reset()
        Fake.startDemo(storage: nil)
        Fake.update { $0.latency = 0 }
        let nc = try #require(WebDAV.demo(.nextcloud))
        #expect(nc.record.id == "cloud:nextcloud:demo")
        #expect(nc.record.title == "alex@cloud.example.com")
        #expect(nc.backend.provider == .nextcloud)
        #expect(try await nc.backend.list(nc.backend.rootID).contains { $0.name == "Documents" })
        #expect(try await nc.backend.listTrash().contains { $0.name == "Old draft.txt" })
        #expect(try await nc.backend.quota() != nil)
        let dv = try #require(WebDAV.demo(.webdav))
        #expect(dv.record.id == "cloud:webdav:demo")
        #expect(dv.record.title == "alex@dav.example.com")
        #expect(try await dv.backend.list(dv.backend.rootID).contains { $0.name == "Backups" })
        #expect(WebDAV.demo(.onedrive) == nil)
        #expect(CloudBackends.demo(.nextcloud) != nil)
        // The demo content is generic.
        let all = try await nc.backend.walk(nc.backend.rootID)
        #expect(all.count > 8)
    }

    /// Against a real server (e.g. Apache mod_dav on 127.0.0.1). Runs only when CIRRUS_DAV_REAL_URL, _USER and _PASS are set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CIRRUS_DAV_REAL_URL"] != nil))
    func realServerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = try #require(env["CIRRUS_DAV_REAL_URL"].flatMap(URL.init(string:)))
        let user = env["CIRRUS_DAV_REAL_USER"] ?? "", pass = env["CIRRUS_DAV_REAL_PASS"] ?? ""
        let (record, secret) = try await WebDAV.connect(url: url, username: user, password: pass, transport: nil)
        #expect(record.provider == .webdav)
        let d = try #require(try WebDAV.make(record: record, secret: secret, transport: nil) as? WebDAVDrive)
        let top = "Cirrus test \(UUID().uuidString.prefix(6)) #1 & ü"
        let base = try await d.createFolder(top, in: d.rootID)
        #expect(try await d.list(d.rootID).contains { $0.id == base.id && $0.name == top })
        // Odd names, upload and download.
        var uploaded = [DriveNode]()
        for n in Self.oddNames {
            uploaded.append(try await d.upload(try Self.file(Data(n.utf8)), name: n, into: base.id, modified: nil) { _, _ in })
        }
        let listed = try await d.list(base.id)
        #expect(Set(listed.map(\.name)) == Set(Self.oddNames.map(\.precomposedStringWithCanonicalMapping)))
        for item in listed {
            let dest = Self.tempDir("real").appendingPathComponent("f")
            try await d.download(item, to: dest) { _, _ in }
            #expect(String(decoding: try Data(contentsOf: dest), as: UTF8.self).precomposedStringWithCanonicalMapping == item.name, "\(item.name)")
        }
        // A bigger file, streamed both ways.
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let box = DAVProgressBox()
        let bn = try await d.upload(try Self.file(big), name: "big file.bin", into: base.id, modified: nil) { a, b in box.note(a, b) }
        #expect(bn.size == Int64(big.count) && box.last.0 == Int64(big.count))
        let bd = Self.tempDir("real").appendingPathComponent("big")
        try await d.download(bn, to: bd) { _, _ in }
        #expect(try Data(contentsOf: bd) == big)
        // No accidental overwrite; folders, rename, move and clashes.
        #expect(deniedMessage(await caught { _ = try await d.upload(try Self.file(Data("x".utf8)), name: "a b.txt", into: base.id, modified: nil) { _, _ in } })?.contains("already") == true)
        let sub = try await d.createFolder("sub folder %", in: base.id)
        #expect(deniedMessage(await caught { _ = try await d.createFolder("sub folder %", in: base.id) })?.contains("already") == true)
        let first = try #require(listed.first { $0.name == "a b.txt" })
        let renamed = try await d.rename(first, to: "renamed + more.txt")
        #expect(renamed.name == "renamed + more.txt")
        let hash = try #require(listed.first { $0.name == "hash #1.txt" })
        #expect(deniedMessage(await caught { _ = try await d.rename(hash, to: "renamed + more.txt") })?.contains("already") == true)
        let caseOnly = try await d.rename(renamed, to: "RENAMED + more.txt")
        #expect(caseOnly.name == "RENAMED + more.txt")
        try await d.move([caseOnly, hash], to: sub.id)
        #expect(Set(try await d.list(sub.id).map(\.name)) == ["RENAMED + more.txt", "hash #1.txt"])
        _ = try await d.upload(try Self.file(Data("y".utf8)), name: "what?.txt", into: sub.id, modified: nil) { _, _ in }
        let what = try #require(listed.first { $0.name == "what?.txt" })
        #expect(deniedMessage(await caught { try await d.move([what], to: sub.id) })?.contains("already") == true)
        #expect(await caught { try await d.move([base], to: sub.id) } != nil)
        // Trash goes to "Deleted by Cirrus", never erased until asked.
        try await d.trash([what, sub])
        #expect(try await d.list(d.rootID).contains { $0.name == WebDAVDrive.trashFolderName } == false)
        let bin = try await d.listTrash()
        #expect(bin.contains { $0.name == "what?.txt" } && bin.contains { $0.name == "sub folder %" })
        try await d.restore(bin.filter { $0.name == "what?.txt" })
        #expect(try await d.list(base.id).contains { $0.name == "what?.txt" })
        try await d.deleteForever(try await d.listTrash().filter { $0.name == "sub folder %" })
        #expect(try await d.listTrash().contains { $0.name == "sub folder %" } == false)
        #expect(try await d.quota() == nil || true)
        // Wrong password.
        let bad = try WebDAV.make(record: record, secret: CloudSecret(password: "wrong"), transport: nil)
        #expect(await caught { _ = try await bad.list(bad.rootID) } as? CloudError == .signInNeeded("WebDAV (\(record.title))"))
        #expect(await caught { try await bad.download(bn, to: Self.tempDir("real").appendingPathComponent("x")) { _, _ in } } as? CloudError
                == .signInNeeded("WebDAV (\(record.title))"))
        // The same name twice in the trash, and recovering both next to a new file of that name: all three are kept.
        for text in ["one", "two"] {
            try await d.trash([try await d.upload(try Self.file(Data(text.utf8)), name: "same.txt", into: base.id, modified: nil) { _, _ in }])
        }
        let sames = try await d.listTrash().filter { $0.name == "same.txt" }
        #expect(sames.count == 2)
        _ = try await d.upload(try Self.file(Data("three".utf8)), name: "same.txt", into: base.id, modified: nil) { _, _ in }
        try await d.restore(sames)
        #expect(Set(try await d.list(base.id).map(\.name)).isSuperset(of: ["same.txt", "same 2.txt", "same 3.txt"]))
        // Downloads carry the server's modification date.
        let three = try await node(d, base.id, "same.txt")
        let td = Self.tempDir("real").appendingPathComponent("three")
        try await d.download(three, to: td) { _, _ in }
        let mdate = try FileManager.default.attributesOfItem(atPath: td.path)[.modificationDate] as? Date
        #expect(three.modified != nil && mdate.map { abs($0.timeIntervalSince(three.modified!)) < 1 } == true)
        // Clean up.
        try await d.trash([base])
        try await d.deleteForever(try await d.listTrash())
        #expect(try await d.list(d.rootID).contains { $0.id == base.id } == false)
    }

    @Test func cancellingADownloadStopsIt() async throws {
        var s = Fake.State.seeded()
        s.latency = 0.5
        let d = try drive(.nextcloud, s)
        let n = DriveNode(id: "dav:/Readme.md", zone: "dav", parentID: "dav:/", name: "Readme.md", type: "FILE", size: 10, modified: nil, created: nil, etag: nil)
        Fake.update { $0.latency = 0 }
        _ = try await d.userID()
        Fake.update { $0.latency = 0.5 }
        let t = Task { try await d.download(n, to: Self.tempDir("cancel").appendingPathComponent("r.md")) { _, _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        t.cancel()
        let e = await caught { try await t.value }
        #expect(e is CancellationError)
        Fake.update { $0.latency = 0 }
    }
}
