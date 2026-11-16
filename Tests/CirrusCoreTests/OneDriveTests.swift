import CoreGraphics
import Foundation
import Testing
@testable import CirrusCore

final class ODBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

/// FakeGraphServer's state is global, so these run one at a time.
@Suite(.serialized) struct OneDriveTests {
    static let transport: [AnyClass] = [FakeGraphServer.self]

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-onedrive-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func bytes(_ n: Int, seed: Int = 7) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 9) &+ seed) })
    }

    static func file(_ data: Data, named name: String = "src.bin") throws -> URL {
        let u = tempDir().appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    static func query(_ u: URL) -> [String: String] {
        var q = [String: String]()
        for i in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return q
    }

    static func signIn(open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        try await OneDrive.signIn(clientID: FakeGraphServer.state.clientID, transport: transport, timeout: 30, open: open)
    }

    /// Signs in through the real loopback listener (as the app does) and builds the account's backend.
    func connect(_ s: FakeGraphServer.State = FakeGraphServer.State()) async throws -> (backend: OneDriveBackend, record: CloudAccountRecord, secret: CloudSecret) {
        FakeGraphServer.reset(s)
        let r = try await Self.signIn { url in await FakeGraphServer.approve(url) }
        let b = try OneDrive.backend(record: r.record, secret: r.secret, transport: Self.transport)
        b.retryBase = 0.001
        return (b, r.record, r.secret)
    }

    func cloudError(_ op: () async throws -> Void) async -> CloudError? {
        do { try await op(); return nil } catch let e as CloudError { return e } catch {
            Issue.record("expected a CloudError, got \(error)")
            return nil
        }
    }

    func node(_ b: OneDriveBackend, _ name: String, in folder: String = "root") async throws -> DriveNode {
        try #require(try await b.list(folder).first { $0.name == name })
    }

    // MARK: Sign-in

    @Test func signInRunsPKCEThroughLoopbackAndNamesTheAccount() async throws {
        FakeGraphServer.reset()
        let seen = ODBox<URL?>(nil)
        let (record, secret) = try await Self.signIn { url in seen.value = url; await FakeGraphServer.approve(url) }
        #expect(record.provider == .onedrive && record.title == "alex@example.com" && record.id.hasPrefix("cloud:onedrive:"))
        #expect(secret.clientID == FakeGraphServer.state.clientID && secret.clientSecret == nil && secret.password == nil)
        #expect(secret.refreshToken.map { FakeGraphServer.state.validRefreshTokens.contains($0) } == true)
        let url = try #require(seen.value)
        let q = Self.query(url)
        #expect(url.host == "login.microsoftonline.com" && url.path == "/common/oauth2/v2.0/authorize")
        #expect(q["response_type"] == "code" && q["code_challenge_method"] == "S256" && q["code_challenge"]?.count == 43)
        #expect(q["redirect_uri"]?.hasPrefix("http://localhost:") == true)
        #expect(Set((q["scope"] ?? "").split(separator: " ").map(String.init)) == ["Files.ReadWrite.All", "offline_access", "User.Read"])
        #expect((q["state"] ?? "").count >= 30 && q["client_id"] == FakeGraphServer.state.clientID)
        let keys = FakeGraphServer.state.tokenRequestKeys
        #expect(keys.count == 1)
        #expect(keys.first.map { $0.contains("code_verifier") && $0.contains("redirect_uri") && !$0.contains("client_secret") } == true)
        #expect(FakeGraphServer.state.calls.contains("GET graph.microsoft.com/v1.0/me"))
        #expect(FakeGraphServer.state.calls.contains("GET graph.microsoft.com/v1.0/me/drive"))
    }

    @Test func signInRejectsDeniedConsentForgedStateAndAccountsWithoutADrive() async throws {
        FakeGraphServer.reset()
        let denied = await cloudError { _ = try await Self.signIn { url in await FakeGraphServer.approve(url, deny: true) } }
        guard case .denied(let m1)? = denied else { Issue.record("expected denied, got \(String(describing: denied))"); return }
        #expect(m1.contains("Accept"))

        let forged = await cloudError {
            _ = try await Self.signIn { url in
                guard let back = FakeGraphServer.authorize(url), var c = URLComponents(url: back, resolvingAgainstBaseURL: false) else { return }
                c.queryItems = (c.queryItems ?? []).map { $0.name == "state" ? URLQueryItem(name: "state", value: "forged") : $0 }
                await FakeGraphServer.visit(c.url!)
            }
        }
        guard case .denied(let m2)? = forged else { Issue.record("expected denied, got \(String(describing: forged))"); return }
        #expect(m2.contains("didn’t match"))
        #expect(FakeGraphServer.state.tokenRequestKeys.isEmpty)   // the code was never redeemed

        var noDrive = FakeGraphServer.State()
        noDrive.hasDrive = false
        FakeGraphServer.reset(noDrive)
        let missing = await cloudError { _ = try await Self.signIn { url in await FakeGraphServer.approve(url) } }
        guard case .denied(let m3)? = missing else { Issue.record("expected denied, got \(String(describing: missing))"); return }
        #expect(m3.contains("doesn’t have a OneDrive"))

        // Personal accounts often have no `mail`: the sign-in name is the title then.
        var noMail = FakeGraphServer.State()
        noMail.mail = nil
        noMail.userPrincipalName = "alex.upn@example.com"
        FakeGraphServer.reset(noMail)
        let (record, _) = try await Self.signIn { url in await FakeGraphServer.approve(url) }
        #expect(record.title == "alex.upn@example.com")
    }

    @Test func fakeTokenEndpointIsStrictAboutPKCEAndRedirect() async throws {
        FakeGraphServer.reset()
        let clientID = FakeGraphServer.state.clientID
        let pkce = PKCE()
        let url = OneDriveAuth.authorizationURL(clientID: clientID, redirectURI: "http://localhost:5555", pkce: pkce, state: "s")
        let back = try #require(FakeGraphServer.authorize(url))
        #expect(back.absoluteString.hasPrefix("http://localhost:5555/?"))
        let code = try #require(Self.query(back)["code"])
        let http = OneDriveHTTP.makeSession(Self.transport)
        let wrong = await cloudError {
            _ = try await OneDriveAuth.redeem(["grant_type": "authorization_code", "code": code, "redirect_uri": "http://localhost:5555",
                                               "code_verifier": PKCE().verifier], clientID: clientID, http: http, signingIn: true)
        }
        guard case .server(let m)? = wrong else { Issue.record("expected server error, got \(String(describing: wrong))"); return }
        #expect(m.contains("AADSTS501481") && !m.contains("Trace ID"))
        // Entra only redirects to the registered form, http://localhost with any port.
        #expect(FakeGraphServer.authorize(OneDriveAuth.authorizationURL(clientID: clientID, redirectURI: "http://127.0.0.1:5555", pkce: pkce, state: "s")) == nil)
        #expect(FakeGraphServer.authorize(OneDriveAuth.authorizationURL(clientID: "someone-else", redirectURI: "http://localhost:5555", pkce: pkce, state: "s")) == nil)
    }

    @Test func clientIDComesFromTheSecretOrTheDefault() async throws {
        let saved = OneDrive.defaultClientID
        defer { OneDrive.defaultClientID = saved }
        OneDrive.defaultClientID = ""
        let record = CloudAccountRecord(provider: .onedrive, title: "x")
        #expect(throws: CloudError.notConfigured(OneDrive.notConfiguredMessage)) {
            _ = try OneDrive.make(record: record, secret: CloudSecret(refreshToken: "rt"), transport: nil)
        }
        await #expect(throws: CloudError.notConfigured(OneDrive.notConfiguredMessage)) {
            _ = try await OneDrive.signIn(clientID: "  ", transport: Self.transport) { _ in }
        }
        #expect(OneDrive.notConfiguredMessage.contains("http://localhost"))
        OneDrive.defaultClientID = "default-app-id"
        #expect(try OneDrive.backend(record: record, secret: CloudSecret(refreshToken: "rt"), transport: nil).secret.clientID == "default-app-id")
        #expect(try OneDrive.backend(record: record, secret: CloudSecret(refreshToken: "rt", clientID: "own-app-id"), transport: nil).secret.clientID == "own-app-id")
        #expect(throws: CloudError.signInNeeded("OneDrive")) { _ = try OneDrive.make(record: record, secret: CloudSecret(), transport: nil) }
    }

    // MARK: Tokens

    @Test func refreshRotatesOnceForConcurrentRequestsAndHandsOnEachNewToken() async throws {
        let (b, record, secret) = try await connect()
        let saved = ODBox<[String]>([])
        b.onNewRefreshToken = { rt in saved.mutate { $0.append(rt) } }
        _ = try await b.list("root")                       // no access token yet: refresh #1
        #expect(saved.value.count == 1)
        let before = FakeGraphServer.state.refreshes
        FakeGraphServer.update { $0.expireAccessTokens() }
        try await withThrowingTaskGroup(of: Int.self) { g in
            for _ in 0..<8 { g.addTask { try await b.list("root").count } }
            for try await _ in g {}
        }
        #expect(FakeGraphServer.state.refreshes == before + 1)   // eight 401s, one shared refresh
        #expect(saved.value.count == 2)
        let latest = try #require(saved.value.last)
        #expect(b.secret.refreshToken == latest && latest != secret.refreshToken)
        #expect(FakeGraphServer.state.validRefreshTokens == [latest])   // every older one stopped working
        // What the app saved keeps working after a relaunch; the first one from sign-in doesn't.
        var restored = secret
        restored.refreshToken = latest
        _ = try await OneDrive.backend(record: record, secret: restored, transport: Self.transport).list("root")
        let stale = try OneDrive.backend(record: record, secret: secret, transport: Self.transport)
        await #expect(throws: CloudError.signInNeeded("OneDrive")) { _ = try await stale.list("root") }
    }

    @Test func revokedRefreshTokenAsksToSignInAgain() async throws {
        let (b, _, _) = try await connect()
        _ = try await b.list("root")
        FakeGraphServer.update { $0.revokeRefreshTokens(); $0.expireAccessTokens() }
        await #expect(throws: CloudError.signInNeeded("OneDrive")) { _ = try await b.list("root") }
        #expect(CloudError.signInNeeded("OneDrive").errorDescription == "OneDrive needs you to sign in again.")
    }

    @Test func throttlingIsRetriedAfterRetryAfter() async throws {
        var s = FakeGraphServer.State()
        s.addFile("A.txt", data: Data("a".utf8))
        let (b, _, _) = try await connect(s)
        FakeGraphServer.update { $0.throttleNext = 3 }
        #expect(try await b.list("root").map(\.name) == ["A.txt"])
        #expect(FakeGraphServer.state.throttleNext == 0)
        FakeGraphServer.update { $0.throttleNext = 50 }
        let e = await cloudError { _ = try await b.list("root") }
        guard case .server(let m)? = e else { Issue.record("expected server error, got \(String(describing: e))"); return }
        #expect(m.contains("limiting"))
    }

    // MARK: Listing

    @Test func listingFollowsNextLinksAndNormalizesTheRoot() async throws {
        var s = FakeGraphServer.State()
        let docs = s.addFolder("Documents")
        for i in 0..<7 { s.addFile("Note \(i).txt", in: docs, data: Data("note \(i)".utf8), modified: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))) }
        s.addFile("Top.txt", data: Data("top".utf8))
        s.addPackage("Class Notebook")
        let (b, _, _) = try await connect(s)
        let root = try await b.list("root")
        #expect(Set(root.map(\.name)) == ["Documents", "Top.txt", "Class Notebook"])
        #expect(root.allSatisfy { $0.parentID == "root" && $0.zone == "onedrive" && $0.etag != nil })
        let d = try #require(root.first { $0.name == "Documents" })
        #expect(d.id == docs && d.type == "FOLDER" && d.isFolder && d.childCount == 7 && d.size == 0)
        #expect(root.first { $0.name == "Class Notebook" }?.type == "FILE")
        #expect(root.first { $0.name == "Top.txt" }.map { $0.type == "FILE" && $0.size == 3 } == true)

        let notes = try await b.list(docs)
        #expect(notes.count == 7 && notes.allSatisfy { $0.parentID == docs && $0.type == "FILE" })
        #expect(notes.first { $0.name == "Note 3.txt" }?.modified == Date(timeIntervalSince1970: 1_700_000_003))
        let pages = FakeGraphServer.state.calls.filter { $0 == "GET graph.microsoft.com/v1.0/me/drive/items/\(docs)/children" }.count
        #expect(pages == 3)   // 3 + 3 + 1: every @odata.nextLink followed

        let many = try await b.listMany(["root", docs, "root"])
        #expect(many.count == 2 && many[docs]?.count == 7 && many["root"]?.count == 3)
        // A folder that can't be listed throws: it must never look empty.
        await #expect(throws: CloudError.notFound) { _ = try await b.listMany(["root", FakeGraphServer.state.driveID.uppercased() + "!9999"]) }

        // Graph's real id for the top folder is reported as "root".
        let realRoot = try await b.realRootID()
        #expect(realRoot == FakeGraphServer.state.rootID)
        #expect(try await b.list(realRoot).allSatisfy { $0.parentID == "root" })
    }

    // MARK: Uploads

    @Test func smallUploadSetsTheDateAndRoundTrips() async throws {
        let (b, _, _) = try await connect()
        let data = Self.bytes(10_000)
        let src = try Self.file(data)
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        let last = ODBox<(Int64, Int64)>((0, 0))
        let n = try await b.upload(src, name: "Report.pdf", into: "root", modified: when) { done, total in last.value = (done, total) }
        #expect(n.name == "Report.pdf" && n.parentID == "root" && n.size == 10_000 && n.type == "FILE")
        #expect(abs((n.modified ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(last.value == (10_000, 10_000))
        let st = FakeGraphServer.state
        #expect(st.simpleUploads == 1 && st.sessionsCreated == 0)
        let stored = try #require(st.child(named: "Report.pdf"))
        #expect(st.blobs[stored.id] == data && abs(stored.fsModified.timeIntervalSince(when)) < 1)
        let listed = try await node(b, "Report.pdf")
        #expect(abs((listed.modified ?? .distantPast).timeIntervalSince(when)) < 1)

        let empty = try await b.upload(try Self.file(Data(), named: "e"), name: "Empty.txt", into: "root", modified: nil) { _, _ in }
        #expect(empty.size == 0 && FakeGraphServer.state.child(named: "Empty.txt") != nil)
    }

    @Test func chunkedUploadUsesFragmentsOf320KiBAndResumesWhereOneDriveSays() async throws {
        var s = FakeGraphServer.State()
        s.dropChunk = 2
        let (b, _, _) = try await connect(s)
        b.simpleUploadLimit = 100_000
        b.chunkSize = 2 * 327_680 + 1000   // rounded down to 640 KiB
        let folder = try await b.createFolder("Videos", in: "root")
        let data = Self.bytes(2_000_000)
        let src = try Self.file(data)
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let last = ODBox<(Int64, Int64)>((0, 0))
        let n = try await b.upload(src, name: "Clip.mov", into: folder.id, modified: when) { done, total in last.value = (done, total) }
        #expect(n.size == 2_000_000 && n.parentID == folder.id && n.name == "Clip.mov")
        #expect(abs((n.modified ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(last.value == (2_000_000, 2_000_000))
        let st = FakeGraphServer.state
        #expect(st.blobs[n.id] == data)
        // The second fragment broke after 320 KiB had arrived: Cirrus asked and went on from 983040, not 655360.
        #expect(st.chunkSizes == [655_360, 655_360, 655_360, 361_600])
        #expect(st.sessionsCreated == 1 && st.sessionStatusQueries == 1 && st.simpleUploads == 0 && st.openUploadSessions == 0)
        #expect(st.lastSessionItem["@microsoft.graph.conflictBehavior"].string == "fail")
        #expect(st.lastSessionItem["fileSize"].int64 == 2_000_000)
        #expect(abs((st.lastSessionItem["fileSystemInfo"]["lastModifiedDateTime"].date ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(st.authLeaks == 0 && !st.contentRequests.isEmpty && st.contentRequests.allSatisfy { !$0.hadAuth })
    }

    @Test func lostUploadAnswersDontFailOrDuplicate() async throws {
        let (b, _, _) = try await connect()
        FakeGraphServer.update { $0.loseUploadAnswers = 1 }
        let small = try await b.upload(try Self.file(Self.bytes(5_000)), name: "Small.bin", into: "root", modified: nil) { _, _ in }
        #expect(small.size == 5_000 && FakeGraphServer.state.simpleUploads == 1)

        b.simpleUploadLimit = 0
        b.chunkSize = 327_680
        FakeGraphServer.update { $0.loseUploadAnswers = 1 }
        let big = try await b.upload(try Self.file(Self.bytes(400_000)), name: "Big.bin", into: "root", modified: nil) { _, _ in }
        #expect(big.size == 400_000 && big.parentID == "root")
        let st = FakeGraphServer.state
        #expect(st.children(of: st.rootID).map(\.name).sorted() == ["Big.bin", "Small.bin"])
        #expect(st.blobs[big.id] == Self.bytes(400_000))
    }

    @Test func nameConflictsFailClearlyInsteadOfReplacing() async throws {
        var s = FakeGraphServer.State()
        s.addFile("Taken.txt", data: Data("old".utf8))
        s.addFolder("Docs")
        let (b, _, _) = try await connect(s)
        let src = try Self.file(Data("new".utf8))
        for limit in [Int64(4 << 20), 0] {   // simple upload, then upload session
            b.simpleUploadLimit = limit
            let e = await cloudError { _ = try await b.upload(src, name: "taken.txt", into: "root", modified: nil) { _, _ in } }
            guard case .denied(let m)? = e else { Issue.record("expected denied, got \(String(describing: e))"); return }
            #expect(m.contains("already") && m.contains("“taken.txt”"))
        }
        let taken = try #require(FakeGraphServer.state.child(named: "Taken.txt"))
        #expect(FakeGraphServer.state.blobs[taken.id] == Data("old".utf8))

        let folder = await cloudError { _ = try await b.createFolder("Docs", in: "root") }
        guard case .denied(let m2)? = folder else { Issue.record("expected denied, got \(String(describing: folder))"); return }
        #expect(m2.contains("“Docs”"))
        let rename = await cloudError { _ = try await b.rename(try await node(b, "Taken.txt"), to: "Docs") }
        guard case .denied? = rename else { Issue.record("expected denied, got \(String(describing: rename))"); return }
        #expect(FakeGraphServer.state.openUploadSessions == 0)
    }

    @Test func quotaAndFullDrive() async throws {
        var s = FakeGraphServer.State()
        s.total = 1_000_000
        s.addFile("A.bin", data: Data(count: 200_000))
        let gone = s.addFile("B.bin", data: Data(count: 50_000))
        s.items[gone]?.deleted = true
        let (b, _, _) = try await connect(s)
        let u = try #require(try await b.quota())
        #expect(u.total == 1_000_000 && u.used == 250_000 && u.available == 750_000)
        #expect(u.categories.map(\.key) == ["files", "deleted"] && u.categories.map(\.bytes) == [200_000, 50_000])
        await #expect(throws: CloudError.quotaExceeded("OneDrive")) {
            _ = try await b.upload(try Self.file(Data(count: 800_000)), name: "Huge.bin", into: "root", modified: nil) { _, _ in }
        }
    }

    // MARK: Downloads

    @Test func downloadFollowsTheRedirectWithoutTheToken() async throws {
        var s = FakeGraphServer.State()
        let data = Self.bytes(300_000, seed: 3)
        let when = Date(timeIntervalSince1970: 1_720_000_000)
        s.addFile("Photo.jpg", data: data, modified: when)
        s.addPackage("Notebook")
        s.dropDownloadsNext = 1
        let (b, _, _) = try await connect(s)
        let photo = try await node(b, "Photo.jpg")
        let dest = Self.tempDir().appendingPathComponent("out/Photo.jpg")
        let last = ODBox<(Int64, Int64)>((0, 0))
        try await b.download(photo, to: dest) { done, total in last.value = (done, total) }
        #expect(try Data(contentsOf: dest) == data)
        let mtime = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(mtime.map { abs($0.timeIntervalSince(when)) < 1 } == true)
        #expect(last.value == (300_000, 300_000))
        let st = FakeGraphServer.state
        #expect(st.contentRequests.filter { $0.path.hasPrefix("/dl/") }.count == 2)   // dropped once, then retried
        #expect(st.authLeaks == 0 && st.contentRequests.allSatisfy { !$0.hadAuth })
        #expect(st.calls.contains("GET graph.microsoft.com/v1.0/me/drive/items/\(photo.id)/content"))

        let notebook = try await node(b, "Notebook")
        let e = await cloudError { try await b.download(notebook, to: dest) { _, _ in } }
        guard case .unsupported(let m)? = e else { Issue.record("expected unsupported, got \(String(describing: e))"); return }
        #expect(m.contains("OneNote") && m.contains("“Notebook”"))
    }

    // MARK: Changes

    @Test func createRenameAndMoveIncludingBackToTheTop() async throws {
        var s = FakeGraphServer.State()
        s.addFile("Plan.txt", data: Data("plan".utf8))
        let (b, _, _) = try await connect(s)
        let projects = try await b.createFolder("Projects", in: "root")
        #expect(projects.parentID == "root" && projects.type == "FOLDER" && projects.name == "Projects")
        let year = try await b.createFolder("2026", in: projects.id)
        #expect(year.parentID == projects.id)
        let renamed = try await b.rename(projects, to: "Projects (old)")
        #expect(renamed.id == projects.id && renamed.name == "Projects (old)" && renamed.parentID == "root")
        #expect(FakeGraphServer.state.child(named: "Projects (old)")?.id == projects.id)

        let plan = try await node(b, "Plan.txt")
        try await b.move([plan], to: year.id)
        #expect(try await b.list(year.id).map(\.name) == ["Plan.txt"])
        #expect(try await b.list("root").contains { $0.name == "Plan.txt" } == false)
        try await b.move([try await node(b, "Plan.txt", in: year.id)], to: "root")
        #expect(try await b.list("root").contains { $0.name == "Plan.txt" })
        // OneDrive wants the top folder's real id; "root" is Cirrus's name for it.
        #expect(FakeGraphServer.state.patches.last?["parentReference"]["id"].string == FakeGraphServer.state.rootID)
        // A folder can't go inside itself.
        let e = await cloudError { try await b.move([renamed], to: year.id) }
        guard case .denied? = e else { Issue.record("expected denied, got \(String(describing: e))"); return }
    }

    @Test func trashUsesTheRecycleBinAndRestoreIsLeftToOneDriveOnTheWeb() async throws {
        var s = FakeGraphServer.State()
        s.addFile("Old.txt", data: Data(count: 1000))
        let (b, _, _) = try await connect(s)
        let old = try await node(b, "Old.txt")
        try await b.trash([old])
        #expect(try await b.list("root").isEmpty)
        let st = FakeGraphServer.state
        #expect(st.recycleBin.map(\.name) == ["Old.txt"] && st.blobs[old.id] != nil)
        try await b.trash([old])   // already gone: fine
        #expect(b.canListTrash == false)
        #expect(try await b.listTrash().isEmpty)
        await #expect(throws: CloudError.unsupported(OneDriveBackend.recycleBinMessage)) { try await b.restore([old]) }
        await #expect(throws: CloudError.unsupported(OneDriveBackend.recycleBinMessage)) { try await b.deleteForever([old]) }
        #expect(OneDriveBackend.recycleBinMessage.contains("onedrive.com"))
    }

    @Test func oddNamesArePercentEncodedAndRoundTrip() async throws {
        #expect(OneDriveBackend.encodeName("a?b#c%d+e f/é") == "a%3Fb%23c%25d%2Be%20f%2F%C3%A9")
        let (b, _, _) = try await connect()
        let decomposed = "U\u{308}ber\u{301}.txt"   // as macOS file names often arrive
        let names = ["Q&A #1 – 100% + more.txt", "café 日本語 😀.md", "semi;colon=equals'quote,comma@at$!~.txt", decomposed]
        for (i, name) in names.enumerated() {
            let data = Data("file \(i)".utf8)
            let n = try await b.upload(try Self.file(data), name: name, into: "root", modified: nil) { _, _ in }
            let want = name.precomposedStringWithCanonicalMapping
            #expect(n.name == want)
            let stored = try #require(FakeGraphServer.state.child(named: want))
            #expect(stored.name == want && FakeGraphServer.state.blobs[stored.id] == data)
            let dest = Self.tempDir().appendingPathComponent("f\(i)")
            try await b.download(try await node(b, want), to: dest) { _, _ in }
            #expect(try Data(contentsOf: dest) == data)
        }
    }

    @Test func namesOneDriveRefusesAreCaughtBeforeSending() async throws {
        let (b, _, _) = try await connect()
        let src = try Self.file(Data("x".utf8))
        let before = FakeGraphServer.state.calls.count
        for bad in ["what?.txt", "a/b.txt", "co:lon.txt", "star*.txt", "pipe|.txt", "", ".."] {
            let e = await cloudError { _ = try await b.upload(src, name: bad, into: "root", modified: nil) { _, _ in } }
            guard case .denied? = e else { Issue.record("\(bad): expected denied, got \(String(describing: e))"); continue }
        }
        let e = await cloudError { _ = try await b.createFolder("a/b", in: "root") }
        guard case .denied? = e else { Issue.record("expected denied, got \(String(describing: e))"); return }
        #expect(FakeGraphServer.state.calls.count == before)
        // Odd but valid folder names work, also for upload sessions addressed by name.
        let folder = try await b.createFolder("50% #done + more", in: "root")
        b.simpleUploadLimit = 0
        let n = try await b.upload(try Self.file(Self.bytes(1000)), name: "#1 report + 100%.bin", into: folder.id, modified: nil) { _, _ in }
        #expect(n.name == "#1 report + 100%.bin" && n.parentID == folder.id)
        #expect(FakeGraphServer.state.child(named: "#1 report + 100%.bin", in: folder.id) != nil)
    }

    // MARK: Extras

    @Test func thumbnailsComeFromThePreAuthenticatedHost() async throws {
        var s = FakeGraphServer.State()
        let img = try #require(DemoArt.jpeg(width: 64, height: 48, hue: 0.3, label: "T"))
        s.addFile("Pic.jpg", data: img)
        s.addFile("Notes.txt", data: Data("n".utf8))
        s.addFolder("Folder")
        let (b, _, _) = try await connect(s)
        let pic = try await node(b, "Pic.jpg")
        #expect(try await b.thumbnail(pic, maxPixel: 256) == img)
        #expect(FakeGraphServer.state.thumbnailSizes == ["c256x256"])
        #expect(try await b.thumbnail(try await node(b, "Notes.txt"), maxPixel: 256) == nil)
        let calls = FakeGraphServer.state.calls.count
        #expect(try await b.thumbnail(try await node(b, "Folder"), maxPixel: 256) == nil)
        #expect(FakeGraphServer.state.calls.count == calls + 1)   // only the listing, no thumbnail request
        // Without custom sizes, the nearest named size.
        FakeGraphServer.update { $0.customThumbnails = false; $0.thumbnailSizes = [] }
        #expect(try await b.thumbnail(pic, maxPixel: 120) == img)
        #expect(FakeGraphServer.state.thumbnailSizes == ["c120x120", "medium"])
        #expect(FakeGraphServer.state.authLeaks == 0)
    }

    @Test func sharedFolderShortcutsBrowseTheOwnersDriveAndTrashOnlyTheShortcut() async throws {
        var s = FakeGraphServer.State()
        let shared = s.addSharedFolder("Team Trip", files: [("Itinerary.txt", Data("Day 1".utf8))])
        s.addFile("Mine.txt", data: Data("mine".utf8))
        let (b, _, _) = try await connect(s)
        let trip = try await node(b, "Team Trip")
        #expect(trip.isFolder && trip.isShared && trip.parentID == "root" && trip.childCount == 1)
        let inside = try await b.list(trip.id)
        #expect(inside.map(\.name) == ["Itinerary.txt"] && inside[0].parentID == trip.id)
        let dest = Self.tempDir().appendingPathComponent("it.txt")
        try await b.download(inside[0], to: dest) { _, _ in }
        #expect(try String(contentsOf: dest, encoding: .utf8) == "Day 1")
        let added = try await b.upload(try Self.file(Data("notes".utf8)), name: "Notes.txt", into: trip.id, modified: nil) { _, _ in }
        #expect(added.parentID == trip.id && FakeGraphServer.state.child(named: "Notes.txt", in: shared.folder) != nil)
        #expect(try await b.list(trip.id).count == 2)
        let e = await cloudError { try await b.move([try await node(b, "Mine.txt")], to: trip.id) }
        guard case .unsupported? = e else { Issue.record("expected unsupported, got \(String(describing: e))"); return }
        try await b.trash([trip])
        let st = FakeGraphServer.state
        #expect(st.live(shared.shortcut) == nil && st.live(shared.folder) != nil)   // the owner's folder is untouched
    }

    @Test func demoAccountBrowsesGenericSampleContent() async throws {
        FakeGraphServer.reset()
        defer { FakeGraphServer.reset() }
        let demo = try #require(OneDrive.demo())
        #expect(demo.record.id == "cloud:onedrive:demo" && demo.record.provider == .onedrive && demo.record.title == "alex@example.com")
        let b = demo.backend
        #expect(b.provider == .onedrive && b.rootID == "root")
        let root = try await b.list(b.rootID)
        #expect(Set(root.map(\.name)) == ["Documents", "Pictures", "Read Me.txt"])
        let docs = try await b.list(try #require(root.first { $0.name == "Documents" }).id)
        #expect(Set(docs.map(\.name)) == ["Meeting Notes.txt", "Budget.csv"])
        let pics = try await b.list(try #require(root.first { $0.name == "Pictures" }).id)
        #expect(pics.count == 2)
        let thumb = try #require(try await b.thumbnail(pics[0], maxPixel: 128))
        #expect(thumb.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try await b.quota() != nil)
        // Asking again keeps the same content (with a token of its own).
        let again = try #require(OneDrive.demo())
        #expect(try await again.backend.list("root").count == 3)
    }
}
