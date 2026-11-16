import CoreGraphics
import Foundation
import Testing
@testable import CirrusCore

final class ImmichPageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _pages = [[PhotoAsset]]()
    private var _totals = [Int?]()
    func note(_ batch: [PhotoAsset], _ total: Int?) { lock.withLock { _pages.append(batch); _totals.append(total) } }
    var pages: [[PhotoAsset]] { lock.withLock { _pages } }
    var totals: [Int?] { lock.withLock { _totals } }
}

final class ImmichProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _values = [(Int64, Int64)]()
    func note(_ a: Int64, _ b: Int64) { lock.withLock { _values.append((a, b)) } }
    var last: (Int64, Int64)? { lock.withLock { _values.last } }
    var values: [(Int64, Int64)] { lock.withLock { _values } }
}

/// The Immich connector against FakeImmichServer (shared state, so one test at a time).
@Suite(.serialized) struct ImmichTests {
    typealias Fake = FakeImmichServer
    static let transport: [AnyClass] = [FakeImmichServer.self]
    let lib = ImmichPhotos.library

    init() { setenv("CIRRUS_PROFILE", "tests", 1) }

    func backend(_ s: Fake.State = .seeded(), key: String = Fake.testAPIKey, options: [String: String]? = nil) throws -> ImmichPhotos {
        Fake.reset(s)
        let r = CloudAccountRecord(id: "cloud:immich:test-" + UUID().uuidString.prefix(8).lowercased(), provider: .immich,
                                   title: "alex@example.com (photos.example.com)", server: "https://photos.example.com",
                                   username: "alex@example.com", options: options)
        let b = try #require(try Immich.make(record: r, secret: CloudSecret(password: key), transport: Self.transport) as? ImmichPhotos)
        b.client.retryBase = 0.001
        return b
    }

    func caught(_ op: () async throws -> Void) async -> Error? {
        do { try await op(); return nil } catch { return error }
    }

    func message(_ e: Error?) -> String { (e as? LocalizedError)?.errorDescription ?? "" }

    func album(_ b: ImmichPhotos, _ id: String) async throws -> PhotoAlbum {
        try #require(try await b.albums(in: lib).first { $0.id == id })
    }

    func list(_ b: ImmichPhotos, _ id: String) async throws -> [PhotoAsset] {
        try await b.assets(in: try await album(b, id), library: lib) { _, _ in }
    }

    func asset(_ b: ImmichPhotos, _ albumID: String, _ name: String) async throws -> PhotoAsset {
        try #require(try await list(b, albumID).first { $0.filename == name })
    }

    /// What All Photos should hold: the user's own timeline photos, newest first.
    static func expectedTimeline(_ s: Fake.State) -> [String] {
        s.assets.values.filter { $0.ownerID == s.user.id && $0.visibility == "timeline" && !$0.isTrashed }
            .sorted { $0.fileCreatedAt != $1.fileCreatedAt ? $0.fileCreatedAt > $1.fileCreatedAt : $0.id > $1.id }.map(\.id)
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-immich-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func photoFile(_ name: String, seed: Int, date: Date, in dir: URL? = nil) throws -> URL {
        let u = (dir ?? tempDir()).appendingPathComponent(name)
        try #require(DemoArt.scenic(width: 160, height: 120, seed: seed)).write(to: u)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: u.path)
        return u
    }

    // MARK: Server address

    @Test func serverAddressesAreNormalized() throws {
        #expect(try Immich.serverURL(from: "photos.example.com").absoluteString == "https://photos.example.com")
        #expect(try Immich.serverURL(from: "  https://Photos.Example.com/api/ ").absoluteString == "https://photos.example.com")
        #expect(try Immich.serverURL(from: "https://photos.example.com/api/api").absoluteString == "https://photos.example.com")
        #expect(try Immich.serverURL(from: "HTTPS://photos.example.com:8443/photos/abc?x=1#y").absoluteString == "https://photos.example.com:8443")
        #expect(try Immich.serverURL(from: "https://example.com/immich/albums").absoluteString == "https://example.com/immich")
        #expect(try Immich.serverURL(from: "https://user:pw@photos.example.com").absoluteString == "https://photos.example.com")
        // No scheme on the local network: Immich's own port serves plain http.
        #expect(try Immich.serverURL(from: "192.168.1.20:2283").absoluteString == "http://192.168.1.20:2283")
        #expect(try Immich.serverURL(from: "immich.local:2283/api").absoluteString == "http://immich.local:2283")
        #expect(try Immich.serverURL(from: "https://192.168.1.20").absoluteString == "https://192.168.1.20")
        #expect(throws: CloudError.self) { try Immich.serverURL(from: "") }
        #expect(throws: CloudError.self) { try Immich.serverURL(from: "ftp://photos.example.com") }
    }

    @Test func plainHTTPOnlyOnTheLocalNetwork() throws {
        for ok in ["http://192.168.1.20:2283", "http://10.0.0.5", "http://172.16.0.9", "http://172.31.255.1", "http://127.0.0.1:2283",
                   "http://localhost:2283", "http://immich.local", "http://nas:2283", "http://[fd12:3456::1]:2283", "http://[::1]", "http://169.254.10.2"] {
            #expect((try? Immich.serverURL(from: ok)) != nil, "\(ok) should be allowed")
        }
        for bad in ["http://photos.example.com", "http://172.32.0.1", "http://8.8.8.8", "http://192.169.1.1", "http://100.64.0.1",
                    "http://[2001:db8::1]", "http://11.0.0.1"] {
            let e = #expect(throws: CloudError.self, "\(bad) should be refused") { try Immich.serverURL(from: bad) }
            if case .unsupported(let m)? = e { #expect(m.contains("https://")) } else { Issue.record("expected .unsupported for \(bad)") }
        }
        #expect(try Immich.serverURL(from: "http://[fd12:3456::1]:2283/api").absoluteString == "http://[fd12:3456::1]:2283")
        #expect(try Immich.serverURL(from: "[fd12::5]:2283").absoluteString == "http://[fd12::5]:2283")
        #expect(Immich.isLocalNetwork("192.168.0.1"))
        #expect(!Immich.isLocalNetwork("192.168.0.256"))
        #expect(!Immich.isLocalNetwork("photos.example.com"))
        #expect(Immich.isLocalNetwork("[FE80::1]"))
    }

    // MARK: Connect

    @Test func connectChecksServerVersionAndKey() async throws {
        Fake.reset(.seeded())
        let (record, secret) = try await Immich.connect(server: "photos.example.com/api/", apiKey: " \(Fake.testAPIKey)\n", transport: Self.transport)
        #expect(record.provider == .immich)
        #expect(record.id.hasPrefix("cloud:immich:"))
        #expect(record.title == "alex@example.com (photos.example.com)")
        #expect(record.username == "alex@example.com")
        #expect(record.server == "https://photos.example.com")
        #expect(record.options?["permissions"] == "all")
        #expect(record.options?["version"] == "3.4.1")
        #expect(secret == CloudSecret(password: Fake.testAPIKey))
        let s = Fake.state
        #expect(Array(s.calls.prefix(3)) == ["GET /server/ping", "GET /server/version", "GET /users/me"])
        #expect(!s.keyedPaths.contains("/server/ping"), "the key isn't sent before the server is known to be Immich")
        #expect(s.keyedPaths.contains("/users/me"))
        #expect(s.lastUserAgent?.hasPrefix("Cirrus") == true)
        // The saved account works.
        let photos = try CloudBackends.makePhotos(record, secret: secret)
        _ = photos
    }

    @Test func connectOnTheLocalNetwork() async throws {
        Fake.reset(.seeded())
        let lan = try await Immich.connect(server: "192.168.1.20:2283", apiKey: Fake.testAPIKey, transport: Self.transport)
        #expect(lan.record.server == "http://192.168.1.20:2283")
        #expect(lan.record.title == "alex@example.com (192.168.1.20:2283)")
        let local = try await Immich.connect(server: "immich.local", apiKey: Fake.testAPIKey, transport: Self.transport)
        #expect(local.record.server == "http://immich.local")
        let e = await caught { _ = try await Immich.connect(server: "http://photos.example.com", apiKey: Fake.testAPIKey, transport: Self.transport) }
        guard case .unsupported? = e as? CloudError else { Issue.record("plain http to the internet must be refused, got \(String(describing: e))"); return }
    }

    @Test func connectRefusesBadKeysOldServersAndOtherSites() async throws {
        Fake.reset(.seeded())
        var e = await caught { _ = try await Immich.connect(server: "photos.example.com", apiKey: "wrong-key", transport: Self.transport) }
        #expect(e as? CloudError == Immich.badKey)
        e = await caught { _ = try await Immich.connect(server: "photos.example.com", apiKey: "   ", transport: Self.transport) }
        guard case .notConfigured? = e as? CloudError else { Issue.record("empty key"); return }

        Fake.update { $0.version = ImmichVersion(major: 2, minor: 7, patch: 5) }
        e = await caught { _ = try await Immich.connect(server: "photos.example.com", apiKey: Fake.testAPIKey, transport: Self.transport) }
        guard case .unsupported(let m)? = e as? CloudError else { Issue.record("old server"); return }
        #expect(m.contains("2.7.5") && m.contains("3.0"))

        Fake.reset(.seeded())
        e = await caught { _ = try await Immich.connect(server: "www.example.com", apiKey: Fake.testAPIKey, transport: Self.transport) }
        guard case .notConfigured(let m2)? = e as? CloudError else { Issue.record("not Immich"); return }
        #expect(m2.contains("no Immich server"))
        #expect(Fake.state.keyedPaths.isEmpty, "no key sent to a server that isn't Immich")

        e = await caught { _ = try await Immich.connect(server: "old.example.com", apiKey: Fake.testAPIKey, transport: Self.transport) }
        guard case .notConfigured(let m3)? = e as? CloudError else { Issue.record("redirect"); return }
        #expect(m3.contains("photos.example.com"))
    }

    @Test func connectChecksTheKeysPermissions() async throws {
        var s = Fake.State.seeded()
        s.apiKeys["limited"] = ["user.read", "asset.read"]
        s.apiKeys["readonly"] = Immich.readPermissions
        Fake.reset(s)
        let e = await caught { _ = try await Immich.connect(server: "photos.example.com", apiKey: "limited", transport: Self.transport) }
        guard case .denied(let m)? = e as? CloudError else { Issue.record("missing read permissions"); return }
        #expect(m.contains("album.read") && m.contains("asset.view") && !m.contains("user.read"))

        let (record, secret) = try await Immich.connect(server: "photos.example.com", apiKey: "readonly", transport: Self.transport)
        #expect(record.options?["permissions"] == Immich.readPermissions.sorted().joined(separator: ","))
        let b = try #require(try Immich.make(record: record, secret: secret, transport: Self.transport) as? ImmichPhotos)
        #expect(b.capabilities == [.albums])
        Fake.update { $0.apiKeys["readonly"] = ["all"] }
        _ = try await b.libraries()   // refreshes the permissions
        #expect(b.capabilities == [.favorite, .hide, .delete, .restore, .importFiles, .albums, .createAlbum])
    }

    @Test func makeNeedsAKeyAndAServer() throws {
        let r = CloudAccountRecord(provider: .immich, title: "alex@example.com", server: "https://photos.example.com")
        #expect(throws: CloudError.signInNeeded("Immich (alex@example.com)")) { try Immich.make(record: r, secret: CloudSecret(), transport: nil) }
        var bad = r
        bad.server = "http://photos.example.com"
        #expect(throws: CloudError.self) { try Immich.make(record: bad, secret: CloudSecret(password: "k"), transport: nil) }
        let other = CloudAccountRecord(provider: .nextcloud, title: "x")
        #expect(throws: CloudError.self) { try Immich.make(record: other, secret: CloudSecret(password: "k"), transport: nil) }
        #expect(throws: CloudError.self) { try CloudBackends.make(r, secret: CloudSecret(password: "k")) }
    }

    // MARK: Libraries & albums

    @Test func oneLibraryWithSmartAndUserAlbums() async throws {
        let b = try backend()
        #expect(try await b.libraries() == [ImmichPhotos.library])
        #expect(ImmichPhotos.library.id == "immich" && ImmichPhotos.library.name == "Immich")
        let albums = try await b.albums(in: lib)
        let s = Fake.state
        let me = s.user.id
        let own = s.assets.values.filter { $0.ownerID == me }
        #expect(albums.prefix(5).map(\.id) == ["smart:All Photos", "smart:Favorites", "smart:Videos", "smart:Hidden", "smart:Recently Deleted"])
        #expect(albums.prefix(5).allSatisfy { $0.kind == .smart })
        #expect(albums[0].isAllPhotos && albums[4].isDeletedBin)
        #expect(albums[0].count == Self.expectedTimeline(s).count)
        #expect(albums[1].count == own.filter { $0.isFavorite && $0.visibility == "timeline" && !$0.isTrashed }.count)
        #expect(albums[2].count == 1)
        #expect(albums[3].count == 1 && albums[3].name == "Archive")
        #expect(albums[4].count == 1 && albums[4].name == "Trash")
        let user = albums.dropFirst(5)
        #expect(user.map(\.name) == ["Family", "Summer Trip", "Sam’s Garden"])
        let family = try #require(user.first { $0.name == "Family" })
        let fake = try #require(s.album(named: "Family"))
        #expect(family.id == "album:" + fake.id)
        #expect(family.kind == .album && family.symbol == "rectangle.stack.badge.person.crop")
        #expect(family.count == fake.assetIDs.count)
        let garden = try #require(user.first { $0.name == "Sam’s Garden" })
        #expect(garden.kind == .shared && garden.count == 1)
    }

    @Test func allPhotosIsPagedNewestFirst() async throws {
        let b = try backend()
        b.firstPageSize = 3
        b.pageSize = 5
        let all = try await album(b, "smart:All Photos")
        Fake.update { $0.searchBodies = [] }
        let log = ImmichPageLog()
        let assets = try await b.assets(in: all, library: lib) { log.note($0, $1) }
        let s = Fake.state
        #expect(assets.map(\.id) == Self.expectedTimeline(s))
        #expect(log.pages.count >= 4)
        #expect(log.pages.flatMap { $0 }.map(\.id) == assets.map(\.id))
        #expect(log.totals.allSatisfy { $0 == all.count })
        #expect(zip(assets, assets.dropFirst()).allSatisfy { ($0.created ?? .distantPast) >= ($1.created ?? .distantPast) })
        // The partner's photos, the archive, the trash and Live Photo motion parts stay out.
        let names = Set(assets.map(\.filename))
        for n in ["PXL_3001.JPG", "PXL_3002.JPG", "IMG_1007.JPG", "IMG_1012.JPG", "IMG_1003.MOV"] { #expect(!names.contains(n), "\(n)") }
        #expect(names.contains("VID_2001.MP4"))
        // v3.2+ request shape: structured filter, cursor paging, no deprecated fields.
        let bodies = s.searchBodies
        #expect(bodies.count >= 4)
        #expect(bodies[0]["size"].int == 3 && bodies[0].object["cursor"] == nil)
        #expect(bodies[1]["size"].int == 5 && bodies[1]["cursor"].string != nil)
        #expect(bodies[0]["filter"] == ["visibility": ["eq": "timeline"], "trashedAt": ["eq": nil]])
        #expect(bodies[0]["orderBy"] == ["field": "fileCreatedAt", "direction": "desc"])
        #expect(bodies.allSatisfy { $0.object["page"] == nil && $0.object["visibility"] == nil && $0["withExif"].bool == true })
    }

    @Test func olderServersGetTheFlatSearchFields() async throws {
        var s = Fake.State.seeded()
        s.version = ImmichVersion(major: 3, minor: 1, patch: 2)
        let b = try backend(s)
        b.pageSize = 4
        let log = ImmichPageLog()
        let assets = try await b.assets(in: try await album(b, "smart:All Photos"), library: lib) { log.note($0, $1) }
        #expect(assets.map(\.id) == Self.expectedTimeline(Fake.state))
        let bodies = Fake.state.searchBodies
        #expect(bodies.allSatisfy { $0.object["filter"] == nil && $0.object["cursor"] == nil && $0["visibility"].string == "timeline" })
        #expect(bodies.map { $0["page"].int ?? 0 } == Array(1...bodies.count))
        #expect(bodies.allSatisfy { $0["size"].int == 4 })
        let trash = try await list(b, "smart:Recently Deleted")
        #expect(trash.map(\.filename) == ["IMG_1012.JPG"])
        let trip = try await list(b, "album:" + (try #require(Fake.state.album(named: "Summer Trip"))).id)
        #expect(!trip.isEmpty && trip.allSatisfy { !$0.isDeleted })
    }

    @Test func smartAlbumsAndAlbumsHoldTheRightPhotos() async throws {
        let b = try backend()
        let s = Fake.state
        #expect(Set(try await list(b, "smart:Favorites").map(\.filename)) == ["IMG_1000.JPG", "IMG_1004.JPG", "IMG_1009.JPG"])
        #expect(try await list(b, "smart:Videos").map(\.filename) == ["VID_2001.MP4"])
        let archived = try await list(b, "smart:Hidden")
        #expect(archived.map(\.filename) == ["IMG_1007.JPG"] && archived[0].isHidden)
        let trashed = try await list(b, "smart:Recently Deleted")
        #expect(trashed.map(\.filename) == ["IMG_1012.JPG"] && trashed[0].isDeleted)
        let trip = try #require(s.album(named: "Summer Trip"))
        let tripAssets = try await list(b, "album:" + trip.id)
        let expected = trip.assetIDs.compactMap { s.assets[$0] }.filter { !$0.isTrashed }.sorted { $0.fileCreatedAt > $1.fileCreatedAt }.map(\.id)
        #expect(tripAssets.map(\.id) == expected)
        // An album someone shared holds their photos.
        let garden = try #require(s.album(named: "Sam’s Garden"))
        #expect(try await list(b, "album:" + garden.id).map(\.filename) == ["PXL_3001.JPG"])
        // Unknown albums.
        let e = await caught { _ = try await b.assets(in: PhotoAlbum(id: "smart:Nope", name: "x", kind: .smart), library: lib) { _, _ in } }
        #expect(e as? CloudError == .notFound)
        #expect(try await b.assets(in: PhotoAlbum(id: "folder:x", name: "x", kind: .folder), library: lib) { _, _ in }.isEmpty)
    }

    @Test func assetFieldsLivePhotosAndVideos() async throws {
        let b = try backend()
        let s = Fake.state
        let all = try await list(b, "smart:All Photos")
        let still = try #require(all.first { $0.filename == "IMG_1003.JPG" })
        let fakeStill = try #require(s.asset(named: "IMG_1003.JPG"))
        let motion = try #require(s.asset(named: "IMG_1003.MOV"))
        #expect(still.id == fakeStill.id && still.library == "immich")
        #expect(still.isLive && !still.isVideo)
        let live = try #require(still.resource(.liveVideo))
        #expect(live.recordName == motion.id && live.filename == "IMG_1003.MOV")
        #expect(still.size == Int64(fakeStill.data.count) && still.resource(.original)?.size == still.size)
        #expect(still.width == 480 && still.height == 360)
        #expect(still.uti == "public.jpeg")
        #expect(abs((still.created ?? .distantPast).timeIntervalSince(fakeStill.fileCreatedAt)) < 0.01)
        #expect(still.added != nil && still.changeTag != nil)
        let video = try #require(all.first { $0.filename == "VID_2001.MP4" })
        #expect(video.isVideo && video.duration == 4.0 && !video.isLive && video.width == 1920)
        #expect(still.duration == nil)
        let edited = try #require(all.first { $0.filename == "IMG_1009.JPG" })
        #expect(edited.isEdited && edited.resource(.edited) != nil && edited.isFavorite)
        #expect(edited.resource(.thumbnail)?.url?.contains("edited=true") == true)
        #expect(ImmichPhotos.duration(.string("0:01:02.500000")) == 62.5)
        #expect(ImmichPhotos.duration(.number(0)) == nil && ImmichPhotos.duration(.null) == nil)
    }

    // MARK: Content

    @Test func thumbnailsUseServerRenditionsAndTheDiskCache() async throws {
        let b = try backend()
        let a = try await asset(b, "smart:All Photos", "IMG_1001.JPG")
        Fake.update { $0.thumbnailRequests = [] }
        let small = try #require(try await b.thumbnail(a, maxPixel: 256))
        #expect(max(small.width, small.height) <= 256)
        #expect(Fake.state.thumbnailRequests == ["thumbnail"])
        _ = try #require(try await b.thumbnail(a, maxPixel: 256))
        #expect(Fake.state.thumbnailRequests == ["thumbnail"], "second request served from the disk cache")
        let big = try #require(try await b.thumbnail(a, maxPixel: 1024))
        #expect(max(big.width, big.height) <= 1024)
        #expect(Fake.state.thumbnailRequests == ["thumbnail", "preview"])
        // A video gets its poster frame.
        let v = try await asset(b, "smart:Videos", "VID_2001.MP4")
        #expect(try await b.thumbnail(v, maxPixel: 256) != nil)
    }

    @Test func exportsOriginalsLiveVideosAndEditsWithTheCaptureDate() async throws {
        let b = try backend()
        let s = Fake.state
        let dir = Self.tempDir()
        let still = try await asset(b, "smart:All Photos", "IMG_1003.JPG")
        let p = ImmichProgress()
        let dest = dir.appendingPathComponent(still.filename)
        try Data("old".utf8).write(to: dest)
        try await b.export(still, resource: .original, to: dest) { p.note($0, $1) }
        let fake = try #require(s.asset(named: "IMG_1003.JPG"))
        #expect(try Data(contentsOf: dest) == fake.data)
        let mod = try #require(try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date)
        #expect(abs(mod.timeIntervalSince(fake.fileCreatedAt)) < 1)
        #expect(p.last.map { $0.0 == Int64(fake.data.count) } == true)
        let mov = dir.appendingPathComponent("IMG_1003.MOV")
        try await b.export(still, resource: .liveVideo, to: mov) { _, _ in }
        #expect(try Data(contentsOf: mov) == s.asset(named: "IMG_1003.MOV")?.data)
        let edited = try await asset(b, "smart:All Photos", "IMG_1009.JPG")
        let e1 = dir.appendingPathComponent("edited.jpg"), e0 = dir.appendingPathComponent("orig.jpg")
        try await b.export(edited, resource: .edited, to: e1) { _, _ in }
        try await b.export(edited, resource: .original, to: e0) { _, _ in }
        #expect(try Data(contentsOf: e1) == s.asset(named: "IMG_1009.JPG")?.editedData)
        #expect(try Data(contentsOf: e0) == s.asset(named: "IMG_1009.JPG")?.data)
        // No such resource.
        let plain = try await asset(b, "smart:All Photos", "IMG_1001.JPG")
        let e = await caught { try await b.export(plain, resource: .liveVideo, to: dir.appendingPathComponent("x.mov")) { _, _ in } }
        #expect(e as? CloudError == .notFound)
    }

    // MARK: Edits

    @Test func favoritesAndArchive() async throws {
        let b = try backend()
        let all = try await list(b, "smart:All Photos")
        let two = all.filter { ["IMG_1001.JPG", "IMG_1002.JPG"].contains($0.filename) }
        #expect(two.count == 2)
        let fav = try await b.setFavorite(two, true)
        #expect(fav.allSatisfy(\.isFavorite) && fav.map(\.id) == two.map(\.id))
        #expect(two.allSatisfy { Fake.state.assets[$0.id]?.isFavorite == true })
        #expect(Set(try await list(b, "smart:Favorites").map(\.filename)).isSuperset(of: ["IMG_1001.JPG", "IMG_1002.JPG"]))
        _ = try await b.setFavorite([fav[0]], false)
        #expect(Fake.state.assets[fav[0].id]?.isFavorite == false)

        let hidden = try await b.setHidden([two[1]], true)
        #expect(hidden[0].isHidden && Fake.state.assets[two[1].id]?.visibility == "archive")
        #expect(!(try await list(b, "smart:All Photos")).contains { $0.id == two[1].id })
        #expect(try await list(b, "smart:Hidden").contains { $0.id == two[1].id })
        _ = try await b.setHidden(hidden, false)
        #expect(Fake.state.assets[two[1].id]?.visibility == "timeline")
        #expect(Fake.state.calls.filter { $0 == "PUT /assets" }.count == 4)
    }

    @Test func deleteGoesToTheTrashAndRestores() async throws {
        let b = try backend()
        let a = try await asset(b, "smart:All Photos", "IMG_1005.JPG")
        try await b.delete([a])
        #expect(Fake.state.assets[a.id]?.isTrashed == true)
        #expect(Fake.state.forceDeletes == 0)
        #expect(!(try await list(b, "smart:All Photos")).contains { $0.id == a.id })
        let trash = try await list(b, "smart:Recently Deleted")
        let t = try #require(trash.first { $0.id == a.id })
        #expect(t.isDeleted)
        #expect(try await album(b, "smart:Recently Deleted").count == 2)
        try await b.restore([t])
        #expect(Fake.state.assets[a.id]?.isTrashed == false)
        #expect(try await list(b, "smart:All Photos").contains { $0.id == a.id })
        #expect(!Fake.state.deleteBodies.isEmpty && Fake.state.deleteBodies.allSatisfy { $0.object["force"] == nil })
    }

    @Test func deleteIsRefusedWhenTheServersTrashIsOff() async throws {
        var s = Fake.State.seeded()
        s.trashEnabled = false
        let b = try backend(s)
        let a = try await asset(b, "smart:All Photos", "IMG_1005.JPG")
        let e = await caught { try await b.delete([a]) }
        #expect(e as? CloudError == ImmichPhotos.trashOff)
        #expect(Fake.state.assets[a.id] != nil && Fake.state.assets[a.id]?.isTrashed == false)
        #expect(!Fake.state.calls.contains("DELETE /assets"))
    }

    @Test func someoneElsesPhotosAreLeftAlone() async throws {
        let b = try backend()
        let garden = try #require(Fake.state.album(named: "Sam’s Garden"))
        let theirs = try #require(try await list(b, "album:" + garden.id).first)
        let calls = Fake.state.calls.count
        for op in [{ _ = try await b.setFavorite([theirs], true) }, { _ = try await b.setHidden([theirs], true) }, { try await b.delete([theirs]) }] {
            let e = await caught(op)
            guard case .denied(let m)? = e as? CloudError else { Issue.record("expected denied, got \(String(describing: e))"); continue }
            #expect(m.contains("shared it with you"))
        }
        #expect(Fake.state.calls.count == calls, "refused before asking the server")
        // A viewer can't add to the album.
        let mine = try await asset(b, "smart:All Photos", "IMG_1001.JPG")
        let e = await caught { try await b.add([mine], to: try await album(b, "album:" + garden.id), library: lib) }
        guard case .denied? = e as? CloudError else { Issue.record("viewer add"); return }
    }

    @Test func createAlbumAndAddPhotos() async throws {
        let b = try backend()
        let new = try await b.createAlbum("  Road Trip ", in: lib)
        #expect(new.id.hasPrefix("album:") && new.kind == .album && new.name == "Road Trip" && new.count == 0)
        let fake = try #require(Fake.state.album(named: "Road Trip"))
        #expect(new.id == "album:" + fake.id)
        let three = Array(try await list(b, "smart:All Photos").prefix(3))
        try await b.add(three, to: new, library: lib)
        try await b.add([three[0]], to: new, library: lib)   // already there: fine
        #expect(Fake.state.album(named: "Road Trip")?.assetIDs == three.map(\.id))
        #expect(try await album(b, new.id).count == 3)
        #expect(try await list(b, new.id).map(\.id) == three.map(\.id))
        let e = await caught { try await b.add(three, to: try await album(b, "smart:Favorites"), library: lib) }
        guard case .unsupported? = e as? CloudError else { Issue.record("add to a smart album"); return }
        let blank = await caught { _ = try await b.createAlbum("  ", in: lib) }
        guard case .notConfigured? = blank as? CloudError else { Issue.record("blank album name"); return }
    }

    // MARK: Import

    @Test func importUploadsOnceAndDetectsDuplicates() async throws {
        let b = try backend()
        let dir = Self.tempDir()
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let a = try Self.photoFile("Beach day.jpg", seed: 501, date: date, in: dir)
        let c = try Self.photoFile("Café.jpg", seed: 502, date: date.addingTimeInterval(60), in: dir)
        let p = ImmichProgress()
        let ids = try await b.importReturningIDs([a, c], library: lib) { p.note($0, $1) }
        #expect(ids.count == 2)
        let s = Fake.state
        #expect(s.uploads == 2)
        let up = try #require(s.assets[ids[0]])
        #expect(up.originalFileName == "Beach day.jpg" && up.ownerID == s.user.id && up.type == "IMAGE")
        #expect(abs(up.fileCreatedAt.timeIntervalSince(date)) < 0.01)
        #expect(s.assets[ids[1]]?.originalFileName == "Café.jpg")
        #expect(s.uploadFields.allSatisfy { Set($0.keys) == ["fileCreatedAt", "fileModifiedAt", "filename"] })
        let total = Int64(try Data(contentsOf: a).count + Data(contentsOf: c).count)
        #expect(p.last.map { $0 == (total, total) } == true)
        // Again: nothing is sent, the same ids come back.
        let again = try await b.importReturningIDs([a, c], library: lib) { _, _ in }
        #expect(again == ids)
        #expect(Fake.state.uploads == 2)
        #expect(Fake.state.calls.filter { $0 == "POST /assets/bulk-upload-check" }.count == 4)
        #expect(Fake.state.calls.filter { $0 == "POST /assets" }.count == 2)
        // A copy of a photo in the trash brings that photo back.
        let trashed = try #require(Fake.state.asset(named: "IMG_1012.JPG"))
        let copy = dir.appendingPathComponent("copy.jpg")
        try trashed.data.write(to: copy)
        #expect(try await b.importReturningIDs([copy], library: lib) { _, _ in } == [trashed.id])
        #expect(Fake.state.assets[trashed.id]?.isTrashed == false)
        #expect(Fake.state.uploads == 2)
        // Into an album.
        let fam = try await album(b, "album:" + (try #require(Fake.state.album(named: "Family"))).id)
        let d = try Self.photoFile("Dinner.jpg", seed: 503, date: date, in: dir)
        try await b.importFiles([d], into: fam, library: lib) { _, _ in }
        let dinner = try #require(Fake.state.asset(named: "Dinner.jpg"))
        #expect(Fake.state.album(named: "Family")?.assetIDs.contains(dinner.id) == true)
    }

    @Test func importLinksLivePhotos() async throws {
        let b = try backend()
        let dir = Self.tempDir()
        let date = Date(timeIntervalSince1970: 1_781_000_000)
        let still = try Self.photoFile("IMG_5000.JPG", seed: 600, date: date, in: dir)
        let mov = dir.appendingPathComponent("IMG_5000.MOV")
        try Fake.movie(brand: "qt  ", bytes: 5000, seed: 9).write(to: mov)
        let ids = try await b.importReturningIDs([still, mov], library: lib) { _, _ in }
        #expect(ids.count == 1)
        let s = Fake.state
        let photo = try #require(s.assets[ids[0]])
        let videoID = try #require(photo.livePhotoVideoID)
        let video = try #require(s.assets[videoID])
        #expect(photo.originalFileName == "IMG_5000.JPG" && video.originalFileName == "IMG_5000.MOV")
        #expect(video.type == "VIDEO" && video.visibility == "hidden")
        #expect(s.uploadFields.count == 2)
        #expect(s.uploadFields[0]["livePhotoVideoId"] == nil && s.uploadFields[1]["livePhotoVideoId"] == video.id)
        let listed = try await asset(b, "smart:All Photos", "IMG_5000.JPG")
        #expect(listed.isLive && listed.resource(.liveVideo)?.recordName == video.id)
        #expect(!(try await list(b, "smart:All Photos")).contains { $0.filename == "IMG_5000.MOV" })
        // Importing the pair again sends nothing.
        #expect(try await b.importReturningIDs([still, mov], library: lib) { _, _ in } == ids)
        #expect(Fake.state.uploads == 2)
    }

    @Test func unsupportedFilesAreRefusedWithAMessage() async throws {
        let b = try backend()
        let f = Self.tempDir().appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: f)
        let e = await caught { _ = try await b.importReturningIDs([f], library: lib) { _, _ in } }
        guard case .unsupported(let m)? = e as? CloudError else { Issue.record("expected .unsupported, got \(String(describing: e))"); return }
        #expect(m.contains("isn’t supported") && !m.contains("notes.txt"))
    }

    // MARK: Errors

    @Test func errorsMapToCloudErrors() async throws {
        let b = try backend()
        _ = try await b.libraries()
        // Revoked key.
        Fake.update { $0.apiKeys = [:] }
        let e1 = await caught { _ = try await b.libraries() }
        #expect(e1 as? CloudError == .signInNeeded("Immich (alex@example.com (photos.example.com))"))
        // A key without a permission.
        Fake.update { $0.apiKeys[Fake.testAPIKey] = Immich.readPermissions }
        let a = try await asset(b, "smart:All Photos", "IMG_1001.JPG")
        let e2 = await caught { _ = try await b.setFavorite([a], true) }
        guard case .denied(let m)? = e2 as? CloudError else { Issue.record("403"); return }
        #expect(m.contains("asset.update"))
        // Server errors and messages (v3 and older bodies).
        #expect(ImmichClient.message(Data(#"{"message":"Validation failed","errors":[{"path":["filter","size"],"message":"Too big"}]}"#.utf8))
            == "Validation failed — filter.size: Too big")
        #expect(ImmichClient.message(Data(#"{"message":["size must be an integer"],"error":"Bad Request","statusCode":400}"#.utf8))
            == "size must be an integer")
        #expect(ImmichClient.failure(status: 404, data: Data(), serviceName: "Immich") == .notFound)
        #expect(ImmichClient.failure(status: 400, data: Data(#"{"message":"Quota has been exceeded!"}"#.utf8), serviceName: "Immich") == .quotaExceeded("Immich"))
        guard case .server(let m500) = ImmichClient.failure(status: 500, data: Data(#"{"message":"Failed to upload"}"#.utf8), serviceName: "Immich") else {
            Issue.record("500"); return
        }
        #expect(m500.contains("500") && m500.contains("Failed to upload"))
        // A photo deleted on the server meanwhile.
        Fake.update { $0.apiKeys[Fake.testAPIKey] = ["all"]; $0.assets[a.id] = nil }
        let e3 = await caught { try await b.export(a, resource: .original, to: Self.tempDir().appendingPathComponent("x.jpg")) { _, _ in } }
        guard case .denied(let m3)? = e3 as? CloudError else { Issue.record("gone"); return }
        #expect(m3.contains("couldn’t find"))
    }

    @Test func busyServersAreRetried() async throws {
        let b = try backend()
        Fake.update { $0.rateLimitNext = 2; $0.unavailableNext = 1 }
        let albums = try await b.albums(in: lib)
        #expect(albums.count == 8)
        Fake.update { $0.dropNext = 1 }
        #expect(!(try await list(b, "smart:Videos")).isEmpty)
        Fake.update { $0.failNext = 1 }
        let e = await caught { _ = try await b.createAlbum("X", in: lib) }
        guard case .server? = e as? CloudError else { Issue.record("500 is not retried"); return }
        Fake.update { $0.rateLimitNext = 10 }
        let busy = await caught { _ = try await b.createAlbum("Y", in: lib) }
        guard case .server(let m)? = busy as? CloudError else { Issue.record("gives up"); return }
        #expect(m.contains("busy"))
    }

    @Test func listingCanBeCancelled() async throws {
        let b = try backend()
        _ = try await b.libraries()
        b.firstPageSize = 1
        b.pageSize = 1
        Fake.update { $0.latency = 0.15 }
        let task = Task { try await b.assets(in: PhotoAlbum(id: "smart:All Photos", name: "All Photos", kind: .smart, count: 19), library: lib) { _, _ in } }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        let result = await task.result
        Fake.update { $0.latency = 0 }
        guard case .failure(let e) = result else { Issue.record("listing finished despite cancellation"); return }
        #expect(e is CancellationError)
        #expect(Fake.state.searchBodies.count < 19)
    }

    // MARK: Demo

    @Test func demoAccount() async throws {
        Fake.reset()
        Fake.startDemo(storage: nil)   // in memory: the demo below reuses it
        let demo = try #require(Immich.demo())
        #expect(demo.record.id == "cloud:immich:demo" && demo.record.provider == .immich && demo.record.title == "alex@example.com")
        #expect(CloudBackends.demoPhotos(.immich)?.record.id == "cloud:immich:demo")
        let photos = demo.photos
        let l = try await photos.libraries()
        #expect(l == [ImmichPhotos.library])
        let albums = try await photos.albums(in: l[0])
        #expect(albums.filter { $0.kind != .smart }.count == 3)
        let all = try #require(albums.first { $0.isAllPhotos })
        let assets = try await photos.assets(in: all, library: l[0]) { _, _ in }
        #expect(assets.count == 19)
        #expect(Set(assets.map { Calendar(identifier: .gregorian).component(.month, from: $0.created ?? .distantPast) }).count >= 4)
        #expect(photos.capabilities.contains(.importFiles))
        Fake.reset()
    }
}
