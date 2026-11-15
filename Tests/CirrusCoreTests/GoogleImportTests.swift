import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import CirrusCore

/// An iCloud Photos stand-in that records what it receives (and keeps a copy to inspect).
final class RecordingPhotos: PhotosBackend, @unchecked Sendable {
    let dir: URL
    let lock = NSLock()
    var assets: [PhotoAsset] = []
    var albumList: [PhotoAlbum] = []
    var membership: [String: [String]] = [:]
    var importCalls: [[String]] = []
    var stored: [String: URL] = [:]
    let cacheKey = "recording"
    var capabilities: PhotoCapabilities { [.favorite, .importFiles, .albums, .createAlbum] }

    init(dir: URL) { self.dir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func libraries() async throws -> [PhotoLibraryRef] { [PhotoLibraryRef(id: "lib", name: "Personal Library", isShared: false)] }
    func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] { lock.withLock { albumList } }
    func assets(in album: PhotoAlbum, library: PhotoLibraryRef, page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        let list = lock.withLock { album.isAllPhotos ? assets : assets.filter { (membership[album.id] ?? []).contains($0.id) } }
        page(list, list.count)
        return list
    }
    func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? { nil }
    func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        throw ICloudError.notFound
    }
    func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var names = [String]()
        for f in files {
            let id = "R" + UUID().uuidString.prefix(8)
            let copy = dir.appendingPathComponent(id + "-" + f.lastPathComponent)
            try FileManager.default.copyItem(at: f, to: copy)
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int64) ?? 0
            let created = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let a = PhotoAsset(id: id, library: "lib", filename: f.lastPathComponent, size: size, created: created, width: 0, height: 0,
                               isVideo: ["mov", "mp4"].contains(f.pathExtension.lowercased()), isLive: false, isFavorite: false, isHidden: false,
                               resources: [PhotoResource(kind: .original, filename: f.lastPathComponent, size: size, key: "o", recordName: id, url: nil, uti: nil)])
            lock.withLock {
                assets.append(a)
                stored[f.lastPathComponent + "#" + String(size)] = copy
                if let album { membership[album.id, default: []].append(id) }
            }
            names.append(f.lastPathComponent)
        }
        lock.withLock { importCalls.append(names) }
        progress(Int64(files.count), Int64(files.count))
    }
    func add(_ list: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws {
        lock.withLock { for a in list where !(membership[album.id] ?? []).contains(a.id) { membership[album.id, default: []].append(a.id) } }
    }
    func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum {
        let a = PhotoAlbum(id: "album:" + UUID().uuidString.prefix(6), name: name, kind: .album)
        lock.withLock { albumList.append(a) }
        return a
    }
    func setFavorite(_ list: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        lock.withLock { for i in assets.indices where list.contains(where: { $0.id == assets[i].id }) { assets[i].isFavorite = value } }
        return list
    }
    func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { throw ICloudError.server("not used") }
    func delete(_ assets: [PhotoAsset]) async throws { throw ICloudError.server("Cirrus never deletes here") }
    func restore(_ assets: [PhotoAsset]) async throws { throw ICloudError.server("not used") }

    func members(_ name: String) -> [PhotoAsset] {
        lock.withLock {
            guard let a = albumList.first(where: { $0.name == name }) else { return [] }
            let ids = membership[a.id] ?? []
            return assets.filter { ids.contains($0.id) }
        }
    }
    func copy(named name: String) -> URL? { lock.withLock { stored.first { $0.key.hasPrefix(name + "#") }?.value } }
}

final class TrashBin: @unchecked Sendable {
    let dir: URL
    let lock = NSLock()
    var items: [String] = []
    init(_ dir: URL) { self.dir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func trash(_ url: URL, _ root: URL) throws {
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(UUID().uuidString.prefix(4) + "-" + url.lastPathComponent))
        lock.withLock { items.append(url.lastPathComponent) }
    }
}

extension GoogleServerTests {
@Suite struct GoogleImportTests {
    static let everything = GoogleScopes.all + [GoogleScopes.driveReadonly, GoogleScopes.photosPicker]
    let client = GoogleOAuthClient(clientID: "demo-client.apps.googleusercontent.com", clientSecret: "demo-secret")

    func connect(_ s: FakeGoogleServer.State = FakeGoogleServer.State(), scopes: [String] = GoogleImportTests.everything) async throws -> GoogleAPI {
        FakeGoogleServer.reset(s)
        let oauth = GoogleOAuth(client: client, transport: [FakeGoogleServer.self])
        let tokens = try await oauth.authorize(scopes: scopes) { url in await FakeGoogleServer.approve(url) }
        let refresh = try #require(tokens.refreshToken)
        let api = GoogleAPI(accountID: FakeGoogleServer.state.userID, oauth: oauth, scopes: tokens.scopes, transport: [FakeGoogleServer.self],
                            initialTokens: tokens, refreshToken: { refresh })
        api.retryBase = 0.001
        api.batchCreateMinBackoff = 0
        return api
    }

    func engine(_ api: GoogleAPI, takeout: [URL] = [], picked: [GooglePickedItem] = [], driveRoot: URL? = nil, photos: PhotosBackend? = nil,
                state: URL, options: ImportOptions = ImportOptions(), readOnly: Bool = false, bin: TrashBin? = nil) -> ImportEngine {
        let target = ImportEngine.Target(key: "test:icloud", title: "Test iCloud", drive: nil, nativeDriveRoot: driveRoot, photos: photos, isWeb: false)
        return ImportEngine(source: .init(api: api, takeout: takeout, picked: picked), target: target, options: options, stateDir: state,
                            stagingDir: state.appendingPathComponent("staging"), readOnly: { readOnly },
                            trash: { u, r in try (bin ?? TrashBin(state.appendingPathComponent("trash"))).trash(u, r) })
    }

    static func exifDate(_ u: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let s = (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    // MARK: Takeout parsing

    @Test(arguments: ["zip", "tgz", "folder"])
    func takeoutSidecarsAlbumsAndPairs(format: String) async throws {
        let dir = GoogleMigrationTests.tempDir("takeout-\(format)")
        let inputs = try await TakeoutFixture.make(in: dir, format: format)
        let r = try await TakeoutReader(inputs: inputs, workDir: dir.appendingPathComponent("work")).scan { _ in }
        let byName = Dictionary(grouping: r.items, by: \.fileName)
        #expect(r.items.count == 11)
        #expect(Set(byName.keys) == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.HEIC", "IMG_0003.MP4", "IMG_0004.JPG", "IMG_0005.JPG", "IMG_0005-edited.JPG",
                                     "Screenshot_20230701_a_very_long_camera_file_name.png", "NOSIDECAR.PNG", "IMG_0007.JPG"])
        // Every naming style found its sidecar.
        for (name, date) in TakeoutFixture.dates where name != "IMG_0004(1).JPG" {
            #expect(byName[name]?.contains { $0.taken == date } == true, "date for \(name)")
        }
        #expect(byName["IMG_0004.JPG"]?.count == 2)   // "(1)" twin keeps Google's original name but stays a separate photo
        #expect(byName["IMG_0004.JPG"]?.contains { $0.taken == TakeoutFixture.dates["IMG_0004(1).JPG"] } == true)
        let one = try #require(byName["IMG_0001.JPG"]?.first)
        #expect(one.albums == ["Lisbon trip"] && one.favorite && one.caption == "Tram 28" && one.latitude == 38.7139)
        #expect(byName["IMG_0007.JPG"]?.first?.albums == ["Lisbon trip"])          // album + year copies merged, sidecar from the other part
        #expect(byName["IMG_0005-edited.JPG"]?.first?.isEdited == true)
        let live = try #require(byName["IMG_0003.MP4"]?.first)
        #expect(live.isCompanion && live.group == byName["IMG_0003.HEIC"]?.first?.group && live.taken == TakeoutFixture.dates["IMG_0003.HEIC"])
        #expect(byName["NOSIDECAR.PNG"]?.first?.taken == nil)
        #expect(r.skipped.map(\.name) == ["clip.avi"])
        #expect(!r.items.contains { $0.path.contains("Takeout/Drive/") })          // other products ignored
        #expect(!r.items.contains { $0.fileName == "IMG_0009.JPG" })               // in Google's trash
    }

    @Test func sidecarNamesAcrossGenerations() {
        let s = TakeoutReader.sidecarName
        #expect(s("IMG_3479(1).JPG", ["IMG_3479.JPG(1).json", "IMG_3479.JPG.json"]) == "IMG_3479.JPG(1).json")
        #expect(s("Scan35(1).jpg", ["Scan35.jpg.supplemental-metadata(1).json"]) == "Scan35.jpg.supplemental-metadata(1).json")
        #expect(s("IMG_1-edited.jpg", ["IMG_1.jpg.json"]) == "IMG_1.jpg.json")
        #expect(s("IMG_1-bearbeitet.jpg", ["IMG_1.jpg.supplemental-metadata.json"]) == "IMG_1.jpg.supplemental-metadata.json")
        let long = "20230615_142034_old_phone.jpg"   // sidecar names stop at 46 characters before ".json"
        let cut = String((long + ".supplemental-metadata").prefix(46)) + ".json"
        #expect(cut.count == 51 && s(long, [cut]) == cut)
        #expect(s("IMG_2.jpg", ["IMG_20.jpg.json"]) == nil)
    }

    // MARK: Takeout → iCloud Photos

    @Test func takeoutImportKeepsDatesAlbumsFavoritesAndIsIncremental() async throws {
        let api = try await connect()
        let dir = GoogleMigrationTests.tempDir("import")
        let parts = try await TakeoutFixture.make(in: dir, format: "zip")
        let rec = RecordingPhotos(dir: dir.appendingPathComponent("icloud"))
        let state = dir.appendingPathComponent("state")
        var o = ImportOptions(); o.includeDrive = false
        let e = engine(api, takeout: parts, photos: rec, state: state, options: o)
        let ev = try await e.evaluate { _ in }
        #expect(ev.photoPending.count == 10)                       // the edited copy is left out by default
        #expect(ev.albums.map(\.title) == ["Lisbon trip"] && ev.favoritesPending == 1)
        let r = try await e.run(ev) { _ in }
        #expect(r.photosImported == 10 && r.failed.isEmpty, "\(r.failed)")
        #expect(r.albumsCreated == 1 && r.albumAdds == 2 && r.favoritesSet == 1)
        // Dates (and place and caption) written into the copies that lacked them.
        let tram = try #require(rec.copy(named: "IMG_0001.JPG"))
        #expect(Self.exifDate(tram) == TakeoutFixture.dates["IMG_0001.JPG"])
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(tram as CFURL, nil)!, 0, nil) as? [CFString: Any]
        #expect(abs(((props?[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 38.7139) < 0.0001)
        #expect((props?[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCaptionAbstract] as? String == "Tram 28")
        #expect(Self.exifDate(try #require(rec.copy(named: "Screenshot_20230701_a_very_long_camera_file_name.png"))) == TakeoutFixture.dates["Screenshot_20230701_a_very_long_camera_file_name.png"])
        // Live Photo halves go to iCloud together.
        #expect(rec.importCalls.contains { Set($0) == ["IMG_0003.HEIC", "IMG_0003.MP4"] })
        #expect(rec.members("From Google Photos").count == 10)
        #expect(Set(rec.members("Lisbon trip").map(\.filename)) == ["IMG_0001.JPG", "IMG_0007.JPG"])
        #expect(rec.assets.filter(\.isFavorite).map(\.filename) == ["IMG_0001.JPG"])
        #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("staging").path))   // temporary space released
        // The same items from a fresh export (here as .tgz) are recognised: nothing is copied twice.
        let again = try await TakeoutFixture.make(in: dir.appendingPathComponent("second"), format: "tgz")
        let e2 = engine(api, takeout: again, photos: rec, state: state, options: o)
        let ev2 = try await e2.evaluate { _ in }
        #expect(ev2.isUpToDate)
        let calls = rec.importCalls.count
        let r2 = try await e2.run(ev2) { _ in }
        #expect(r2.summary == "Everything was already in iCloud — 1 skipped" && rec.importCalls.count == calls)
    }

    @Test func readOnlyModeStopsBeforeAnythingIsWritten() async throws {
        let api = try await connect()
        let dir = GoogleMigrationTests.tempDir("ro")
        let parts = try await TakeoutFixture.make(in: dir, format: "zip")
        let rec = RecordingPhotos(dir: dir.appendingPathComponent("icloud"))
        let e = engine(api, takeout: parts, photos: rec, state: dir.appendingPathComponent("state"), readOnly: true)
        let ev = try await e.evaluate { _ in }
        #expect(ev.readOnly && !ev.fits)
        #expect(ev.warnings.contains { $0.hasPrefix("Read-only mode is on") })
        await #expect(throws: SafetyPolicy.ReadOnlyError.self) { _ = try await e.run(ev) { _ in } }
        #expect(rec.importCalls.isEmpty && rec.albumList.isEmpty)
    }

    // MARK: Google Drive → iCloud Drive

    @Test func driveCopiesMyDriveExportsDocsAndReplacesViaTrash() async throws {
        var s = FakeGoogleServer.State()
        let notes = s.addUserFile("notes.txt", data: Data("first".utf8))
        s.addUserFile("notes.txt", data: Data("a different file with the same name".utf8))
        let trip = s.addUserFolder("Trip")
        let plan = Data((0..<300_000).map { UInt8($0 % 239) })
        s.addUserFile("plan.pdf", parent: trip, data: plan)
        s.addUserDoc("Meeting notes")
        s.addUserDoc("Annual report", kind: "document", parent: trip, tooLarge: true)
        s.addUserDoc("Budget", kind: "spreadsheet")
        s.addUserDoc("RSVP", kind: "form")
        s.addUserFile("locked.pdf", data: Data("x".utf8), canDownload: false)
        s.addUserFile("not mine.pdf", parent: "someone-elses-folder", data: Data("shared".utf8))
        s.dropDownloadAt = 2
        let api = try await connect(s)
        let old = GoogleDrive.downloadChunk
        GoogleDrive.downloadChunk = 64 * 1024
        defer { GoogleDrive.downloadChunk = old }
        let icloud = GoogleMigrationTests.tempDir("icloud-drive")
        let state = GoogleMigrationTests.tempDir("drive-state")
        let bin = TrashBin(GoogleMigrationTests.tempDir("bin"))
        var o = ImportOptions(); o.includePhotos = false
        let e = engine(api, driveRoot: icloud, state: state, options: o, bin: bin)
        let ev = try await e.evaluate { _ in }
        #expect(ev.driveEnabled && ev.docs == 3)
        #expect(Set(ev.skipped.map(\.name)) == ["RSVP", "locked.pdf"])
        #expect(ev.warnings.contains { $0.contains("exported as Word, Excel and PowerPoint files") })
        let r = try await e.run(ev) { _ in }
        #expect(r.failed.isEmpty, "\(r.failed)")
        #expect(r.driveCopied == 6 && r.docsExported == 3)
        let root = icloud.appendingPathComponent("From Google Drive")
        let got = Set(try FileManager.default.subpathsOfDirectory(atPath: root.path))
        #expect(got == ["notes.txt", "notes (2).txt", "Trip", "Trip/plan.pdf", "Meeting notes.docx", "Trip/Annual report.docx", "Budget.xlsx"])
        #expect(try Data(contentsOf: root.appendingPathComponent("Trip/plan.pdf")) == plan)     // ranged download survived a dropped connection
        #expect(FakeGoogleServer.state.exportLinkUses == 1)                                    // the big Doc went through its export link
        #expect(String(decoding: try Data(contentsOf: root.appendingPathComponent("Budget.xlsx")).prefix(11), as: UTF8.self) == "FAKE-EXPORT")
        // Rerun: nothing. Then a change in Google: only that file, and the old copy goes to the Trash.
        let e2 = engine(api, driveRoot: icloud, state: state, options: o, bin: bin)
        #expect(try await e2.evaluate { _ in }.isUpToDate)
        FakeGoogleServer.update { $0.changeUserFile(notes, data: Data("second version".utf8)) }
        let e3 = engine(api, driveRoot: icloud, state: state, options: o, bin: bin)
        let ev3 = try await e3.evaluate { _ in }
        let rel = try #require(ev3.drivePending.first?.rel)
        #expect(ev3.drivePending.count == 1 && ["notes.txt", "notes (2).txt"].contains(rel))   // which twin gets " (2)" is stable but arbitrary
        let r3 = try await e3.run(ev3) { _ in }
        #expect(r3.driveUpdated == 1 && bin.items == [rel])
        #expect(try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) == "second version")
        #expect(FakeGoogleServer.state.permanentDeletes == 0)
    }

    @Test func driveNeedsTheReadPermission() async throws {
        let api = try await connect(scopes: GoogleScopes.all)
        var o = ImportOptions(); o.includePhotos = false
        let e = engine(api, driveRoot: GoogleMigrationTests.tempDir("noperm"), state: GoogleMigrationTests.tempDir("noperm-state"), options: o)
        let ev = try await e.evaluate { _ in }
        #expect(!ev.driveEnabled)
        #expect(ev.warnings.contains { $0.contains("Allow Reading Google Drive") })
    }

    // MARK: Both directions

    @Test func theTwoDirectionsNeverFeedEachOther() async throws {
        let api = try await connect()
        let dir = GoogleMigrationTests.tempDir("loop")
        let state = dir.appendingPathComponent("state")
        // iCloud already holds what an earlier Google → iCloud copy brought in.
        let icloud = dir.appendingPathComponent("iCloud Drive")
        try FileManager.default.createDirectory(at: icloud.appendingPathComponent("From Google Drive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icloud.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: icloud.appendingPathComponent("Docs/a.txt"))
        try Data("came from Google".utf8).write(to: icloud.appendingPathComponent("From Google Drive/old.txt"))
        let lib = TestPhotos()
        lib.assets = [TestPhotos.asset(1), TestPhotos.asset(2)]
        lib.userAlbums = [PhotoAlbum(id: "album:fromgoogle", name: "From Google Photos", kind: .album)]
        lib.membership = ["album:fromgoogle": ["A0002"]]
        let fwdTarget = MigrationEngine.Target(api: api)
        let fwd = MigrationEngine(sources: .init(key: "test:icloud", title: "Test iCloud", drive: nil, nativeDriveRoot: icloud, photos: lib),
                                  target: fwdTarget, options: MigrationOptions(), stateDir: state, stagingDir: state.appendingPathComponent("staging"))
        let fev = try await fwd.evaluate { _ in }
        #expect(fev.drivePending.map(\.rel) == ["Docs/a.txt"])
        #expect(fev.photoPending.map(\.fileName) == ["IMG_0001.HEIC"])
        #expect(fev.warnings.contains { $0.contains("“From Google Drive” (1 file) is left out") })
        let fr = try await fwd.run(fev) { _ in }
        #expect(fr.driveCopied == 1 && fr.photosCreated == 1)
        // Google → iCloud: Cirrus's “From iCloud” folder and the photo it uploaded aren't brought back.
        FakeGoogleServer.update { $0.addUserFile("budget.xlsx", data: Data("numbers".utf8)) }
        let export = dir.appendingPathComponent("export/Takeout/Google Photos/Photos from 2023")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        var sent = Data(SHA256.hash(data: Data("A0001|original|1".utf8)))
        sent.append(Data(count: 40_000 - sent.count))
        try sent.write(to: export.appendingPathComponent("IMG_0001.HEIC"))
        try (DemoArt.jpeg(width: 200, height: 100, hue: 0.3, label: "new") ?? Data()).write(to: export.appendingPathComponent("IMG_0042.JPG"))
        let rec = RecordingPhotos(dir: dir.appendingPathComponent("photos"))
        let back = engine(api, takeout: [dir.appendingPathComponent("export")], driveRoot: icloud, photos: rec, state: state)
        let bev = try await back.evaluate { _ in }
        #expect(bev.drivePending.map(\.rel) == ["budget.xlsx"])
        #expect(bev.warnings.contains { $0.contains("“From iCloud” in Google Drive is left out") })
        #expect(bev.photoPending.map(\.fileName) == ["IMG_0042.JPG"])
        #expect(bev.warnings.contains { $0.contains("came from this iCloud account through Cirrus") })
    }

    // MARK: Google Photos picker

    @Test func pickedPhotosArriveWithTheirDates() async throws {
        var s = FakeGoogleServer.State()
        for i in 0..<3 {
            let data = DemoArt.jpeg(width: 300, height: 200, hue: CGFloat(i) / 3, label: "P\(i)") ?? Data()
            s.pickerLibrary.append(.init(id: "p\(i)", fileName: "PXL_\(i).jpg", mime: "image/jpeg", data: data,
                                         created: Date(timeIntervalSince1970: 1_750_000_000 + Double(i) * 3600), isVideo: false))
        }
        let api = try await connect(s)
        let picker = GooglePicker(api: api)
        let session = try await picker.create()
        FakeGoogleServer.pick(GooglePicker.browserURL(session), count: 2)
        let done = try await picker.waitForPick(session)
        #expect(done.itemsSet)
        let items = try await picker.items(session.id)
        #expect(items.map(\.fileName) == ["PXL_0.jpg", "PXL_1.jpg"])
        let dir = GoogleMigrationTests.tempDir("picker")
        let rec = RecordingPhotos(dir: dir.appendingPathComponent("icloud"))
        var o = ImportOptions(); o.includeDrive = false
        let e = engine(api, picked: items, photos: rec, state: dir.appendingPathComponent("state"), options: o)
        let r = try await e.run(try await e.evaluate { _ in }) { _ in }
        #expect(r.photosImported == 2)
        #expect(Self.exifDate(try #require(rec.copy(named: "PXL_1.jpg"))) == Date(timeIntervalSince1970: 1_750_003_600))
        await picker.delete(session.id)
        #expect(FakeGoogleServer.state.pickerSessionsDeleted == 1)
    }
}
}
