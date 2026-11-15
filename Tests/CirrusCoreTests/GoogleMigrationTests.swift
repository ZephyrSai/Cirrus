import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import CirrusCore

/// A read-only Photos library for migration tests: every write is counted and refused.
final class TestPhotos: PhotosBackend, @unchecked Sendable {
    let lock = NSLock()
    var assets: [PhotoAsset] = []
    var userAlbums: [PhotoAlbum] = []
    var membership: [String: [String]] = [:]
    var writes = 0
    var failListing: Set<String> = []
    let cacheKey = "test"
    var capabilities: PhotoCapabilities { [] }

    static func asset(_ i: Int, video: Bool = false, live: Bool = false, favorite: Bool = false, size: Int64 = 40_000, name: String? = nil) -> PhotoAsset {
        let id = String(format: "A%04d", i)
        let fname = name ?? String(format: video ? "IMG_%04d.MOV" : "IMG_%04d.HEIC", i)
        var res = [PhotoResource(kind: .original, filename: fname, size: size, key: "o", recordName: id, url: nil, uti: nil)]
        if live { res.append(PhotoResource(kind: .liveVideo, filename: String(format: "IMG_%04d.MOV", i), size: 30_000, key: "v", recordName: id, url: nil, uti: nil)) }
        return PhotoAsset(id: id, masterID: id, changeTag: "1", library: "lib", filename: fname, size: size, created: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3600),
                          added: nil, width: 100, height: 100, duration: nil, isVideo: video, isLive: live, isFavorite: favorite, isHidden: false, resources: res)
    }

    func libraries() async throws -> [PhotoLibraryRef] { [PhotoLibraryRef(id: "lib", name: "Personal Library", isShared: false)] }
    func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] {
        [PhotoAlbum(id: "smart:All Photos", name: "All Photos", kind: .smart)] + lock.withLock { userAlbums }
    }
    func assets(in album: PhotoAlbum, library: PhotoLibraryRef, page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        if lock.withLock({ failListing.contains(album.id) }) { throw ICloudError.http(503, "iCloud is busy (test)") }
        let list = lock.withLock { album.isAllPhotos ? assets : assets.filter { (membership[album.id] ?? []).contains($0.id) } }
        page(list, list.count)
        return list
    }
    func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? { nil }
    /// Deterministic bytes: a per-item header makes every file's MD5 different.
    func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let size = Int(asset.resource(resource)?.size ?? asset.size)
        var d = Data(SHA256.hash(data: Data("\(asset.id)|\(resource.rawValue)|\(asset.changeTag ?? "")".utf8)))
        d.append(Data(count: max(0, size - d.count)))
        try d.prefix(size).write(to: destination)
        progress(Int64(size), Int64(size))
    }
    func refuse() throws -> Never { lock.withLock { writes += 1 }; throw ICloudError.server("tests never write to iCloud") }
    func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { try refuse() }
    func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { try refuse() }
    func delete(_ assets: [PhotoAsset]) async throws { try refuse() }
    func restore(_ assets: [PhotoAsset]) async throws { try refuse() }
    func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws { try refuse() }
    func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws { try refuse() }
    func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum { try refuse() }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _url: URL?
    var url: URL? { get { lock.withLock { _url } } set { lock.withLock { _url = newValue } } }
}

/// Both Google suites share FakeGoogleServer's state, so they run one test at a time under this parent.
@Suite(.serialized) struct GoogleServerTests {}

extension GoogleServerTests {
@Suite struct GoogleMigrationTests {
    let client = GoogleOAuthClient(clientID: "demo-client.apps.googleusercontent.com", clientSecret: "demo-secret")

    static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-tests-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func md5(_ u: URL) -> String { Insecure.MD5.hash(data: (try? Data(contentsOf: u)) ?? Data()).map { String(format: "%02x", $0) }.joined() }

    /// Signs in through the real loopback listener and returns a fast-retrying API client.
    func connect(_ s: FakeGoogleServer.State = FakeGoogleServer.State()) async throws -> GoogleAPI {
        FakeGoogleServer.reset(s)
        let oauth = GoogleOAuth(client: client, transport: [FakeGoogleServer.self])
        let tokens = try await oauth.authorize { url in await FakeGoogleServer.approve(url) }
        let refresh = try #require(tokens.refreshToken)
        let api = GoogleAPI(accountID: FakeGoogleServer.state.userID, oauth: oauth, scopes: tokens.scopes, transport: [FakeGoogleServer.self],
                            initialTokens: tokens, refreshToken: { refresh })
        api.retryBase = 0.001
        api.batchCreateMinBackoff = 0
        return api
    }

    func engine(_ api: GoogleAPI, driveRoot: URL? = nil, photos: PhotosBackend? = nil, state: URL, options: MigrationOptions = MigrationOptions(),
                chunk: Int = 256 * 1024) -> MigrationEngine {
        let target = MigrationEngine.Target(api: api)
        target.drive.chunkSize = chunk
        target.photos.chunkSize = Int64(chunk)
        let src = MigrationEngine.Sources(key: "test:icloud", title: "Test iCloud", drive: nil, nativeDriveRoot: driveRoot, photos: photos)
        return MigrationEngine(sources: src, target: target, options: options, stateDir: state, stagingDir: state.appendingPathComponent("staging"))
    }

    // MARK: OAuth

    @Test func signInUsesLoopbackPKCEAndGetsRefreshToken() async throws {
        FakeGoogleServer.reset()
        let oauth = GoogleOAuth(client: client, transport: [FakeGoogleServer.self])
        let seen = URLBox()
        let tokens = try await oauth.authorize { url in seen.url = url; await FakeGoogleServer.approve(url) }
        #expect(tokens.refreshToken?.hasPrefix("1//fake-refresh-") == true)
        #expect(tokens.has(GoogleScopes.driveFile) && tokens.has(GoogleScopes.photosAppend))
        var q = [String: String]()
        for i in URLComponents(url: try #require(seen.url), resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value }
        #expect(seen.url?.host == "accounts.google.com")
        #expect(q["code_challenge_method"] == "S256")
        #expect((q["code_challenge"] ?? "").count == 43)
        #expect(q["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(q["scope"] == GoogleScopes.all.joined(separator: " "))
        #expect(q["access_type"] == "offline" && q["response_type"] == "code" && (q["state"] ?? "").count >= 30)
        #expect(FakeGoogleServer.state.calls.contains("POST oauth2.googleapis.com/token"))
    }

    @Test func deniedConsentAndForgedStateAreRejected() async throws {
        FakeGoogleServer.reset()
        let oauth = GoogleOAuth(client: client, transport: [FakeGoogleServer.self])
        await #expect(throws: GoogleError.accessDenied) { _ = try await oauth.authorize { url in await FakeGoogleServer.approve(url, deny: true) } }
        // A redirect carrying someone else's state must be ignored.
        await #expect(throws: GoogleError.stateMismatch) {
            _ = try await oauth.authorize { url in
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                c.queryItems = c.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: "forged") : $0 }
                await FakeGoogleServer.approve(c.url!)
            }
        }
    }

    @Test func missingSecretIsExplained() async throws {
        FakeGoogleServer.reset()
        let oauth = GoogleOAuth(client: GoogleOAuthClient(clientID: client.clientID, clientSecret: nil), transport: [FakeGoogleServer.self])
        do {
            _ = try await oauth.authorize { url in await FakeGoogleServer.approve(url) }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("client secret"))
        }
    }

    @Test func expiredAccessTokenIsRefreshedOnceAndRevokedOneAsksToReconnect() async throws {
        var s = FakeGoogleServer.State()
        s.accessTTL = 1   // < 90 s: every call refreshes first
        let api = try await connect(s)
        _ = try await GoogleDrive(api: api).about()
        #expect(FakeGoogleServer.state.refreshes == 1)
        // A 401 on a token we thought was fine: refresh and retry once.
        let stale = GoogleTokens(accessToken: "ya29.unknown", expiresAt: Date().addingTimeInterval(3000), refreshToken: nil, scopes: GoogleScopes.all)
        FakeGoogleServer.update { $0.accessTTL = 3600 }
        let refresh = try #require(FakeGoogleServer.state.refreshTokenList.first)
        let api2 = GoogleAPI(accountID: "x", oauth: GoogleOAuth(client: client, transport: [FakeGoogleServer.self]), scopes: GoogleScopes.all,
                             transport: [FakeGoogleServer.self], initialTokens: stale, refreshToken: { refresh })
        _ = try await GoogleDrive(api: api2).about()
        #expect(FakeGoogleServer.state.refreshes == 2)
        // Revoked (or a Testing project's 7 days are up): tell the user to reconnect.
        FakeGoogleServer.update { $0.revokeAllRefreshTokens() }
        let api3 = GoogleAPI(accountID: "x", oauth: GoogleOAuth(client: client, transport: [FakeGoogleServer.self]), scopes: GoogleScopes.all,
                             transport: [FakeGoogleServer.self], refreshToken: { refresh })
        do { _ = try await GoogleDrive(api: api3).about(); Issue.record("expected reconnect") } catch let e as GoogleError {
            if case .reconnect = e {} else { Issue.record("expected reconnect, got \(e)") }
        }
    }

    @Test func rateLimitsBackOffAndDailyCapsStop() async throws {
        let api = try await connect()
        FakeGoogleServer.update { $0.rateLimitNext = 3 }
        let (user, quota) = try await GoogleDrive(api: api).about()
        #expect(user.email == "demo.person@gmail.example" && quota.limit == 15_000_000_000)
        #expect(FakeGoogleServer.state.calls.filter { $0 == "GET www.googleapis.com/drive/v3/about" }.count == 4)
        #expect(GoogleAPI.classify(429, Data(#"{"error":{"code":429,"message":"Quota exceeded for quota metric 'All requests' and limit 'All requests per day' of service 'photoslibrary.googleapis.com'","status":"RESOURCE_EXHAUSTED"}}"#.utf8), retryAfter: nil)
                == .fail(.dailyLimit(GoogleAPI.dailyMessage("photos"))))
        #expect(GoogleAPI.classify(403, Data(#"{"error":{"errors":[{"reason":"storageQuotaExceeded"}],"message":"The user's Drive storage quota has been exceeded."}}"#.utf8), retryAfter: nil) == .fail(.storageFull))
        #expect(GoogleAPI.classify(403, Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}],"message":"User rate limit exceeded"}}"#.utf8), retryAfter: "2") == .retry(2))
        #expect(GoogleAPI.classify(503, Data(), retryAfter: nil) == .retry(nil))
    }

    // MARK: Drive resumable uploads

    @Test func resumableUploadRecoversFromADroppedConnection() async throws {
        let api = try await connect()
        let drive = GoogleDrive(api: api)
        drive.chunkSize = 512 * 1024   // the dropped chunk keeps its first 256 KiB
        let dir = Self.tempDir("drop")
        let file = dir.appendingPathComponent("big.bin")
        var bytes = Data((0..<(1_500_000)).map { UInt8($0 % 251) })
        bytes[0] = 7
        try bytes.write(to: file)
        FakeGoogleServer.update { $0.dropDriveChunk = 3 }
        let folder = try await drive.createFolder("From iCloud", parent: "root")
        let s = try await drive.startUpload(name: "big.bin", parent: folder.id, size: Int64(bytes.count), modified: Date(timeIntervalSince1970: 1_600_000_000))
        let f = try await drive.upload(file, session: s, resume: false) { _, _ in }
        let st = FakeGoogleServer.state
        #expect(f.size == Int64(bytes.count))
        #expect(f.md5 == Self.md5(file))
        #expect(st.statusQueries >= 1)          // asked Google where it stopped
        #expect(st.driveSessionsStarted == 1)    // and resumed the same session
        #expect(f.modified == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test func emptyFilesUpload() async throws {
        let api = try await connect()
        let drive = GoogleDrive(api: api)
        let dir = Self.tempDir("empty")
        let file = dir.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        let s = try await drive.startUpload(name: "empty.txt", parent: "root", size: 0, modified: nil)
        let f = try await drive.upload(file, session: s, resume: false) { _, _ in }
        #expect(f.size == 0 && f.name == "empty.txt")
    }

    @Test func interruptedMoveResumesTheSameUploadOnTheNextRun() async throws {
        let api = try await connect()
        let src = Self.tempDir("src")
        let state = Self.tempDir("state")
        try Data((0..<2_000_000).map { UInt8($0 % 241) }).write(to: src.appendingPathComponent("Movie.mov"))
        // Google stops answering after 3 chunks: the run stops cleanly and remembers the session.
        FakeGoogleServer.update { $0.failDriveChunksAfter = 3 }
        let e1 = engine(api, driveRoot: src, state: state, options: { var o = MigrationOptions(); o.concurrency = 1; return o }())
        let r1 = try await e1.run(try await e1.evaluate { _ in }) { _ in }
        #expect(r1.driveCopied == 0)
        #expect(r1.stopped != nil)
        let sessionsBefore = FakeGoogleServer.state.driveSessionsStarted
        FakeGoogleServer.update { $0.failDriveChunksAfter = nil }
        let e2 = engine(api, driveRoot: src, state: state)
        let r2 = try await e2.run(try await e2.evaluate { _ in }) { _ in }
        #expect(r2.driveCopied == 1 && r2.resumed == 1 && r2.stopped == nil)
        #expect(FakeGoogleServer.state.driveSessionsStarted == sessionsBefore)   // no new session
        let uploaded = try #require(FakeGoogleServer.state.file(named: "Movie.mov"))
        #expect(uploaded.md5 == Self.md5(src.appendingPathComponent("Movie.mov")))
    }

    // MARK: Photos

    @Test func photosAreCreatedFiftyAtATimeWithAlbums() async throws {
        let api = try await connect()
        let lib = TestPhotos()
        lib.assets = (0..<118).map { TestPhotos.asset($0, favorite: $0 % 10 == 0) }
            + [TestPhotos.asset(500, live: true), TestPhotos.asset(501, video: true),
               TestPhotos.asset(502, name: "Layered.psd"), TestPhotos.asset(503, video: true, size: 21 * 1024 * 1024 * 1024)]
        lib.userAlbums = [PhotoAlbum(id: "album:trips", name: "Trips", kind: .album), PhotoAlbum(id: "album:empty", name: "Empty", kind: .album)]
        lib.membership = ["album:trips": (0..<60).map { String(format: "A%04d", $0) }]
        FakeGoogleServer.update { $0.rejectFileNames = ["IMG_0007.HEIC"] }
        var o = MigrationOptions(); o.includeDrive = false
        let state = Self.tempDir("photos")
        let e = engine(api, photos: lib, state: state, options: o)
        let ev = try await e.evaluate { _ in }
        // 118 + Live still + Live video + one video = 121 items; the .psd and the 21 GB video are listed and skipped.
        #expect(ev.photoPending.count == 121)
        #expect(Set(ev.skipped.map(\.name)) == ["Layered.psd", "IMG_0503.MOV"])
        #expect(ev.photoPending.contains { $0.fileName == "IMG_0500.MOV" && $0.kind == .liveVideo })
        let r = try await e.run(ev) { _ in }
        let st = FakeGoogleServer.state
        #expect(st.batchCreateSizes == [50, 50, 21])
        #expect(r.photosCreated == 120 && r.failed.count == 1 && r.failed[0].contains("IMG_0007.HEIC"))
        #expect(Set(st.albums.values.map(\.title)) == ["Trips", "Favorites from iCloud"])
        #expect(st.albums.values.first { $0.title == "Trips" }?.items.count == 59)   // IMG_0007 wasn't created
        #expect(st.albumAddSizes.allSatisfy { $0 <= 50 })
        #expect(st.media.values.contains { $0.description?.hasPrefix("Taken ") == true })   // no embedded date → kept in the description
        #expect(lib.writes == 0)
        // Next run: only the rejected photo is retried, and it joins its album.
        FakeGoogleServer.update { $0.rejectFileNames = [] }
        let e2 = engine(api, photos: lib, state: state, options: o)
        let ev2 = try await e2.evaluate { _ in }
        #expect(ev2.photoPending.map(\.fileName) == ["IMG_0007.HEIC"])
        let r2 = try await e2.run(ev2) { _ in }
        #expect(r2.photosCreated == 1 && r2.albumsCreated == 0)
        #expect(FakeGoogleServer.state.albums.values.first { $0.title == "Trips" }?.items.count == 60)
    }

    @Test func bigVideosUseResumableUploadsAndSurviveDrops() async throws {
        let api = try await connect()
        let lib = TestPhotos()
        lib.assets = [TestPhotos.asset(1, video: true, size: Int64(GooglePhotos.rawLimit) + 700_000)]
        FakeGoogleServer.update { $0.dropPhotoChunk = 4 }
        var o = MigrationOptions(); o.includeDrive = false
        let e = engine(api, photos: lib, state: Self.tempDir("video"), options: o, chunk: 4 << 20)
        let r = try await e.run(try await e.evaluate { _ in }) { _ in }
        let st = FakeGoogleServer.state
        #expect(r.photosCreated == 1 && r.failed.isEmpty)
        #expect(st.photoSessionsStarted == 1)
        #expect(st.media.values.first?.size == Int64(GooglePhotos.rawLimit) + 700_000)
    }

    @Test func photosDailyQuotaStopsAndTheNextRunFinishes() async throws {
        let api = try await connect()
        let lib = TestPhotos()
        lib.assets = (0..<70).map { TestPhotos.asset($0) }
        FakeGoogleServer.update { $0.photosRequestsLeft = 55 }
        var o = MigrationOptions(); o.includeDrive = false
        let state = Self.tempDir("quota")
        let e = engine(api, photos: lib, state: state, options: o)
        let r = try await e.run(try await e.evaluate { _ in }) { _ in }
        #expect(r.photosCreated == 50)
        #expect(r.stopped?.contains("daily limit") == true)
        FakeGoogleServer.update { $0.photosRequestsLeft = nil }
        let e2 = engine(api, photos: lib, state: state, options: o)
        let r2 = try await e2.run(try await e2.evaluate { _ in }) { _ in }
        #expect(r2.photosCreated == 20)
        #expect(FakeGoogleServer.state.media.count == 70)
    }

    // MARK: Whole migration

    @Test func rerunsAreIncrementalAndNeverDeleteOrTouchICloud() async throws {
        let api = try await connect()
        let src = Self.tempDir("icloud")
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("Docs/Old"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("Empty folder"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("Docs/a.txt"))
        try Data("notes".utf8).write(to: src.appendingPathComponent("Docs/Old/b.txt"))
        try Data(count: 600_000).write(to: src.appendingPathComponent("photo.raw"))
        try Data("junk".utf8).write(to: src.appendingPathComponent(".DS_Store"))
        let before = try fm.subpathsOfDirectory(atPath: src.path).sorted()
        let lib = TestPhotos()
        lib.assets = (0..<5).map { TestPhotos.asset($0) }
        let state = Self.tempDir("state")

        let e1 = engine(api, driveRoot: src, photos: lib, state: state)
        let ev1 = try await e1.evaluate { _ in }
        #expect(ev1.drivePending.count == 3 && ev1.photoPending.count == 5)
        #expect(ev1.fits && ev1.quota?.free == 15_000_000_000 - 2_300_000_000)
        let r1 = try await e1.run(ev1) { _ in }
        #expect(r1.driveCopied == 3 && r1.photosCreated == 5 && r1.failed.isEmpty)
        var st = FakeGoogleServer.state
        let root = try #require(st.files.values.first { $0.name == "From iCloud" && $0.parents == [FakeGoogleServer.rootID] })
        #expect(st.files.values.contains { $0.name == "Empty folder" && $0.parents == [root.id] })
        #expect(!st.files.values.contains { $0.name == ".DS_Store" })
        let sessions = st.driveSessionsStarted, creates = st.batchCreateSizes.count

        // Second run: nothing to do, nothing sent.
        let e2 = engine(api, driveRoot: src, photos: lib, state: state)
        let ev2 = try await e2.evaluate { _ in }
        #expect(ev2.isUpToDate)
        let r2 = try await e2.run(ev2) { _ in }
        #expect(r2.summary == "Everything was already in Google")
        #expect(FakeGoogleServer.state.driveSessionsStarted == sessions && FakeGoogleServer.state.batchCreateSizes.count == creates)

        // A changed file and a new photo: exactly those go up; the old copy goes to Drive's trash.
        try Data("hello, again".utf8).write(to: src.appendingPathComponent("Docs/a.txt"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: src.appendingPathComponent("Docs/a.txt").path)
        lib.assets.append(TestPhotos.asset(99))
        let e3 = engine(api, driveRoot: src, photos: lib, state: state)
        let ev3 = try await e3.evaluate { _ in }
        #expect(ev3.drivePending.map(\.rel) == ["Docs/a.txt"] && ev3.photoPending.count == 1)
        let r3 = try await e3.run(ev3) { _ in }
        #expect(r3.driveUpdated == 1 && r3.photosCreated == 1)
        st = FakeGoogleServer.state
        #expect(st.driveSessionsStarted == sessions + 1)
        #expect(st.files.values.filter { $0.name == "a.txt" && $0.trashed }.count == 1)
        #expect(st.permanentDeletes == 0)

        // The local record is lost (new Mac): Cirrus finds its folder again instead of copying twice.
        let fresh = engine(api, driveRoot: src, photos: lib, state: Self.tempDir("lost"))
        let ev4 = try await fresh.evaluate { _ in }
        #expect(ev4.drivePending.isEmpty)

        // iCloud side untouched.
        #expect(try fm.subpathsOfDirectory(atPath: src.path).sorted() == before)
        #expect(lib.writes == 0)
        // Google files Cirrus didn't create stay invisible to it.
        #expect(try await GoogleDrive(api: api).children("root").allSatisfy { $0.appProperties["cirrusSource"] != nil })
    }

    @Test func unreadableFromGooglePhotosAlbumStopsTheMove() async throws {
        // Without that album's list, photos that came from Google would look new and be sent back.
        let api = try await connect()
        let lib = TestPhotos()
        lib.assets = [TestPhotos.asset(1), TestPhotos.asset(2)]
        lib.userAlbums = [PhotoAlbum(id: "album:fromgoogle", name: "From Google Photos", kind: .album)]
        lib.membership = ["album:fromgoogle": ["A0002"]]
        lib.failListing = ["album:fromgoogle"]
        var o = MigrationOptions(); o.includeDrive = false
        let e = engine(api, photos: lib, state: Self.tempDir("failclosed"), options: o)
        do {
            _ = try await e.evaluate { _ in }
            Issue.record("expected Check Space to stop")
        } catch {
            #expect(error.localizedDescription.contains("“From Google Photos”") && error.localizedDescription.contains("Nothing was sent"))
        }
        #expect(FakeGoogleServer.state.batchCreateSizes.isEmpty && FakeGoogleServer.state.photoSessionsStarted == 0)
        // Any other album that can't be read is only left out, with a note.
        lib.failListing = ["album:trips"]
        lib.userAlbums.append(PhotoAlbum(id: "album:trips", name: "Trips", kind: .album))
        let ev = try await engine(api, photos: lib, state: Self.tempDir("failclosed2"), options: o).evaluate { _ in }
        #expect(ev.warnings.contains { $0.contains("Couldn’t read the album “Trips”") })
    }

    @Test func notEnoughGoogleStorageBlocksTheRun() async throws {
        var s = FakeGoogleServer.State()
        s.limit = 2_300_000_000 + 1_000
        let api = try await connect(s)
        let src = Self.tempDir("full")
        try Data(count: 50_000).write(to: src.appendingPathComponent("f.bin"))
        let e = engine(api, driveRoot: src, state: Self.tempDir("fullstate"))
        let ev = try await e.evaluate { _ in }
        #expect(!ev.fitsGoogle)
        #expect(ev.warnings.contains { $0.hasPrefix("Not enough Google storage") })
        await #expect(throws: (any Error).self) { _ = try await e.run(ev) { _ in } }
        #expect(FakeGoogleServer.state.driveSessionsStarted == 0)
    }

    @Test func photosOnlyGrantSkipsDrive() async throws {
        var s = FakeGoogleServer.State()
        s.grantedScopes = [GoogleScopes.photosAppend]
        let api = try await connect(s)
        #expect(!api.has(GoogleScopes.driveFile))
        let src = Self.tempDir("nodrive")
        try Data("x".utf8).write(to: src.appendingPathComponent("x.txt"))
        let lib = TestPhotos()
        lib.assets = [TestPhotos.asset(1)]
        let e = engine(api, driveRoot: src, photos: lib, state: Self.tempDir("nodrivestate"))
        let ev = try await e.evaluate { _ in }
        #expect(!ev.driveEnabled && ev.photosEnabled)
        #expect(ev.warnings.contains { $0.contains("Google Drive access wasn’t granted") })
        let r = try await e.run(ev) { _ in }
        #expect(r.photosCreated == 1 && r.driveCopied == 0)
    }

    @Test func manifestJournalSurvivesACrash() throws {
        let dir = Self.tempDir("journal")
        let s1 = MigrationStore(dir: dir, name: "m")
        s1.apply(.root("r1", "From iCloud"))
        s1.apply(.file("a.txt", .init(id: "f1", size: 3, mtime: 10)))
        s1.apply(.photo("lib|A|original", .init(id: "m1", size: 9)))
        // No compact(): as if Cirrus quit. Add a torn last line too.
        let h = try FileHandle(forWritingTo: s1.journal)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"file\":{\"_0\":\"b".utf8)); try h.close()
        let s2 = MigrationStore(dir: dir, name: "m")
        #expect(s2.value.root == "r1" && s2.value.files["a.txt"]?.id == "f1" && s2.value.photos.count == 1)
        s2.compact()
        #expect(!FileManager.default.fileExists(atPath: s2.journal.path))
        #expect(MigrationStore(dir: dir, name: "m").value.files.count == 1)
    }
}
}
