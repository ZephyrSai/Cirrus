import CoreGraphics
import Foundation
import Testing
@testable import CirrusCore

final class DBXBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

/// FakeDropboxServer's state is global (and the sign-in ports are fixed), so these run one at a time.
@Suite(.serialized) struct DropboxTests {
    static let transport: [AnyClass] = [FakeDropboxServer.self]

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-dropbox-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    static var appKey: String { FakeDropboxServer.state.appKey }

    static func signIn(open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        try await Dropbox.signIn(appKey: appKey, transport: transport, ports: Dropbox.redirectPorts, timeout: 30, open: open)
    }

    /// Signs in through the real loopback listener (as the app does) and builds the account's backend.
    func connect(_ s: FakeDropboxServer.State = FakeDropboxServer.State()) async throws -> (backend: DropboxBackend, record: CloudAccountRecord, secret: CloudSecret) {
        FakeDropboxServer.reset(s)
        let r = try await Self.signIn { url in await FakeDropboxServer.approve(url) }
        let b = try Dropbox.backend(record: r.record, secret: r.secret, transport: Self.transport)
        b.retryBase = 0.001
        return (b, r.record, r.secret)
    }

    func cloudError(_ op: () async throws -> Void) async -> CloudError? {
        do { try await op(); return nil } catch let e as CloudError { return e } catch {
            Issue.record("expected a CloudError, got \(error)")
            return nil
        }
    }

    func node(_ b: DropboxBackend, _ name: String, in folder: String = "root") async throws -> DriveNode {
        try #require(try await b.list(folder).first { $0.name == name })
    }

    // MARK: Sign-in

    @Test func signInRunsPKCEThroughAFixedLoopbackPortAndNamesTheAccount() async throws {
        FakeDropboxServer.reset()
        let seen = DBXBox<URL?>(nil)
        let (record, secret) = try await Self.signIn { url in seen.value = url; await FakeDropboxServer.approve(url) }
        #expect(record.provider == .dropbox && record.title == "alex@example.com" && record.id.hasPrefix("cloud:dropbox:"))
        #expect(record.options == nil)   // a personal account: paths start at its own root
        #expect(secret.clientID == Self.appKey && secret.clientSecret == nil && secret.password == nil)
        #expect(secret.refreshToken.map { FakeDropboxServer.state.validRefreshTokens.contains($0) } == true)
        let url = try #require(seen.value)
        let q = Self.query(url)
        #expect(url.host == "www.dropbox.com" && url.path == "/oauth2/authorize")
        #expect(q["response_type"] == "code" && q["token_access_type"] == "offline")
        #expect(q["code_challenge_method"] == "S256" && q["code_challenge"]?.count == 43)
        #expect(q["redirect_uri"].map { Dropbox.redirectURIs.contains($0) } == true)
        #expect(Set((q["scope"] ?? "").split(separator: " ").map(String.init)) == Set(Dropbox.scopes))
        #expect((q["state"] ?? "").count >= 30 && q["client_id"] == Self.appKey)
        let keys = FakeDropboxServer.state.tokenRequestKeys
        #expect(keys == [["grant_type", "code", "redirect_uri", "code_verifier", "client_id"]])
        #expect(FakeDropboxServer.state.calls.contains("POST api.dropboxapi.com/2/users/get_current_account"))
        // What the App Console needs, exactly as Cirrus sends it.
        #expect(Dropbox.redirectURIs == ["http://localhost:47823", "http://localhost:47824", "http://localhost:47825"])
        #expect(Dropbox.notConfiguredMessage.contains("http://localhost:47823"))
    }

    @Test func signInMovesToTheNextRegisteredPortWhenOneIsTaken() async throws {
        FakeDropboxServer.reset()
        let first = try DropboxLoopback(ports: [Dropbox.redirectPorts[0]])
        defer { first.close() }
        // The port is really held (127.0.0.1 and ::1): a second listener can't have it.
        #expect(throws: CloudError.server(DropboxLoopback.portsBusyMessage)) { _ = try DropboxLoopback(ports: [Dropbox.redirectPorts[0]]) }
        let seen = DBXBox<URL?>(nil)
        _ = try await Self.signIn { url in seen.value = url; await FakeDropboxServer.approve(url) }
        let redirect = try #require(seen.value.flatMap { Self.query($0)["redirect_uri"] })
        #expect(redirect != Dropbox.redirectURIs[0] && Dropbox.redirectURIs.contains(redirect))

        let others = try Dropbox.redirectPorts.dropFirst().map { try DropboxLoopback(ports: [$0]) }
        defer { others.forEach { $0.close() } }
        let e = await cloudError { _ = try await Self.signIn { _ in } }
        #expect(e == .server(DropboxLoopback.portsBusyMessage))
        #expect(DropboxLoopback.portsBusyMessage.contains("code"))
    }

    @Test func pasteACodeSignInNeedsNoRedirect() async throws {
        FakeDropboxServer.reset()
        let shown = DBXBox<URL?>(nil)
        let code = DBXBox<String?>(nil)
        let (record, secret) = try await Dropbox.signInWithCode(appKey: Self.appKey, transport: Self.transport, open: { url in
            shown.value = url
            code.value = FakeDropboxServer.displayedCode(url)
        }, code: { "  \(code.value ?? "")\n" })   // pasted with stray spaces
        #expect(record.title == "alex@example.com" && secret.refreshToken != nil && secret.clientID == Self.appKey)
        let q = Self.query(try #require(shown.value))
        #expect(q["redirect_uri"] == nil && q["state"] == nil && q["token_access_type"] == "offline" && q["code_challenge_method"] == "S256")
        #expect(FakeDropboxServer.state.tokenRequestKeys == [["grant_type", "code", "code_verifier", "client_id"]])

        // The two-step form, for a sheet with a text field.
        let pending = try Dropbox.beginCodeSignIn(appKey: Self.appKey)
        let c = try #require(FakeDropboxServer.displayedCode(pending.url))
        let wrong = await cloudError { _ = try await pending.finish(code: "not-the-code", transport: Self.transport) }
        guard case .denied(let m)? = wrong else { Issue.record("expected denied, got \(String(describing: wrong))"); return }
        #expect(m.contains("code"))
        #expect(try await pending.finish(code: c, transport: Self.transport).record.title == "alex@example.com")
        let reused = await cloudError { _ = try await pending.finish(code: c, transport: Self.transport) }
        guard case .denied? = reused else { Issue.record("a code works once; got \(String(describing: reused))"); return }
        let empty = await cloudError { _ = try await pending.finish(code: "  ", transport: Self.transport) }
        guard case .denied? = empty else { Issue.record("expected denied, got \(String(describing: empty))"); return }
        // A different code verifier (another sign-in's) doesn't redeem this one's code.
        let other = try Dropbox.beginCodeSignIn(appKey: Self.appKey)
        let c2 = try #require(FakeDropboxServer.displayedCode(pending.url))
        let mismatched = await cloudError { _ = try await other.finish(code: c2, transport: Self.transport) }
        guard case .denied? = mismatched else { Issue.record("expected denied, got \(String(describing: mismatched))"); return }
    }

    @Test func signInRejectsDeniedConsentForgedStateAndMissingPermissions() async throws {
        FakeDropboxServer.reset()
        let denied = await cloudError { _ = try await Self.signIn { url in await FakeDropboxServer.approve(url, deny: true) } }
        guard case .denied(let m1)? = denied else { Issue.record("expected denied, got \(String(describing: denied))"); return }
        #expect(m1.contains("Allow"))

        let forged = await cloudError {
            _ = try await Self.signIn { url in
                guard case .redirect(let back) = FakeDropboxServer.authorize(url), var c = URLComponents(url: back, resolvingAgainstBaseURL: false) else { return }
                c.queryItems = (c.queryItems ?? []).map { $0.name == "state" ? URLQueryItem(name: "state", value: "forged") : $0 }
                await FakeDropboxServer.visit(c.url!)
            }
        }
        guard case .denied(let m2)? = forged else { Issue.record("expected denied, got \(String(describing: forged))"); return }
        #expect(m2.contains("didn’t match"))
        #expect(FakeDropboxServer.state.tokenRequestKeys.isEmpty)   // the code was never redeemed

        // The app in the App Console lacks a permission Cirrus asks for: Dropbox redirects with invalid_scope.
        var noWrite = FakeDropboxServer.State()
        noWrite.appScopes.remove("files.content.write")
        FakeDropboxServer.reset(noWrite)
        let scope = await cloudError { _ = try await Self.signIn { url in await FakeDropboxServer.approve(url) } }
        guard case .denied(let m3)? = scope else { Issue.record("expected denied, got \(String(describing: scope))"); return }
        #expect(m3.contains("files.content.write"))

        // Dropbox grants fewer scopes than asked: caught before the account is saved.
        var fewer = FakeDropboxServer.State()
        fewer.grantedScopes = ["account_info.read", "files.metadata.read", "files.content.read"]
        FakeDropboxServer.reset(fewer)
        let granted = await cloudError { _ = try await Self.signIn { url in await FakeDropboxServer.approve(url) } }
        guard case .notConfigured(let m4)? = granted else { Issue.record("expected notConfigured, got \(String(describing: granted))"); return }
        #expect(m4.contains("files.metadata.write") && m4.contains("files.content.write") && m4.contains("Permissions"))
    }

    @Test func fakeAuthorizeAndTokenEndpointsAreStrict() async throws {
        FakeDropboxServer.reset()
        let pkce = PKCE()
        // Redirect URIs must match a registered one exactly (port and trailing slash included).
        for bad in ["http://localhost:5555", "http://localhost:47823/", "http://127.0.0.1:47823"] {
            let u = DropboxAuth.authorizationURL(appKey: Self.appKey, redirectURI: bad, pkce: pkce, state: "s")
            guard case .errorPage = FakeDropboxServer.authorize(u) else { Issue.record("\(bad) should be refused"); continue }
        }
        guard case .errorPage = FakeDropboxServer.authorize(DropboxAuth.authorizationURL(appKey: "someone-else", redirectURI: nil, pkce: pkce, state: nil)) else {
            Issue.record("unknown app keys get an error page"); return
        }
        var noPKCE = FakeDropboxServer.State()
        noPKCE.allowPublicClients = false
        FakeDropboxServer.reset(noPKCE)
        guard case .errorPage = FakeDropboxServer.authorize(DropboxAuth.authorizationURL(appKey: Self.appKey, redirectURI: nil, pkce: pkce, state: nil)) else {
            Issue.record("PKCE needs “Allow public clients”"); return
        }
        FakeDropboxServer.reset()
        let u = DropboxAuth.authorizationURL(appKey: Self.appKey, redirectURI: "http://localhost:47824", pkce: pkce, state: "s")
        guard case .redirect(let back) = FakeDropboxServer.authorize(u) else { Issue.record("expected a redirect"); return }
        #expect(back.absoluteString.hasPrefix("http://localhost:47824?"))
        let code = try #require(Self.query(back)["code"])
        let http = DropboxHTTP.makeSession(Self.transport)
        defer { http.finishTasksAndInvalidate() }
        let wrong = await cloudError {
            _ = try await DropboxAuth.redeem(["grant_type": "authorization_code", "code": code, "redirect_uri": "http://localhost:47824",
                                              "code_verifier": PKCE().verifier], appKey: Self.appKey, http: http, signingIn: true)
        }
        guard case .server(let m)? = wrong else { Issue.record("expected server error, got \(String(describing: wrong))"); return }
        #expect(m.contains("invalid code verifier"))
        // Refreshing with an unknown token: sign in again.
        let refresh = await cloudError {
            _ = try await DropboxAuth.redeem(["grant_type": "refresh_token", "refresh_token": "nope"], appKey: Self.appKey, http: http, signingIn: false)
        }
        #expect(refresh == .signInNeeded("Dropbox"))
    }

    @Test func appKeyComesFromTheSecretOrTheDefault() async throws {
        let saved = Dropbox.defaultAppKey
        defer { Dropbox.defaultAppKey = saved }
        Dropbox.defaultAppKey = ""
        let record = CloudAccountRecord(provider: .dropbox, title: "x")
        #expect(throws: CloudError.notConfigured(Dropbox.notConfiguredMessage)) {
            _ = try Dropbox.make(record: record, secret: CloudSecret(refreshToken: "rt"), transport: nil)
        }
        await #expect(throws: CloudError.notConfigured(Dropbox.notConfiguredMessage)) {
            _ = try await Dropbox.signIn(appKey: "  ", transport: Self.transport) { _ in }
        }
        #expect(throws: CloudError.notConfigured(Dropbox.notConfiguredMessage)) { _ = try Dropbox.beginCodeSignIn(appKey: "") }
        Dropbox.defaultAppKey = "defaultappkey12"
        #expect(try Dropbox.backend(record: record, secret: CloudSecret(refreshToken: "rt"), transport: nil).secret.clientID == "defaultappkey12")
        #expect(try Dropbox.backend(record: record, secret: CloudSecret(refreshToken: "rt", clientID: "ownappkey"), transport: nil).secret.clientID == "ownappkey")
        #expect(throws: CloudError.signInNeeded("Dropbox")) { _ = try Dropbox.make(record: record, secret: CloudSecret(), transport: nil) }
        // Through the app's factory: a token-rotating Dropbox backend.
        let made = try CloudBackends.make(record, secret: CloudSecret(refreshToken: "rt"))
        #expect(made is DropboxBackend && made is CloudTokenRotating && made.provider == .dropbox && made.rootID == "root")
    }

    // MARK: Tokens

    @Test func refreshIsSharedByConcurrentRequestsAndANewRefreshTokenIsHandedOn() async throws {
        let (b, record, secret) = try await connect()
        let saved = DBXBox<[String]>([])
        b.onNewRefreshToken = { rt in saved.mutate { $0.append(rt) } }
        _ = try await b.list("root")                     // no access token yet: refresh #1
        #expect(FakeDropboxServer.state.refreshes == 1)
        FakeDropboxServer.update { $0.expireAccessTokens() }
        try await withThrowingTaskGroup(of: Int.self) { g in
            for _ in 0..<8 { g.addTask { try await b.list("root").count } }
            for try await _ in g {}
        }
        #expect(FakeDropboxServer.state.refreshes == 2)   // eight expired tokens, one shared refresh
        #expect(saved.value.isEmpty && b.secret.refreshToken == secret.refreshToken)   // Dropbox keeps the same refresh token

        // Should Dropbox ever rotate it, the new one is handed on and the old one stops working.
        FakeDropboxServer.update { $0.rotateRefreshTokens = true; $0.expireAccessTokens() }
        _ = try await b.list("root")
        let latest = try #require(saved.value.last)
        #expect(saved.value.count == 1 && b.secret.refreshToken == latest && latest != secret.refreshToken)
        #expect(FakeDropboxServer.state.validRefreshTokens == [latest])
        var restored = secret
        restored.refreshToken = latest
        _ = try await Dropbox.backend(record: record, secret: restored, transport: Self.transport).list("root")
    }

    @Test func revokedSignInAsksToSignInAgain() async throws {
        let (b, _, _) = try await connect()
        _ = try await b.list("root")
        FakeDropboxServer.update { $0.revokeRefreshTokens() }   // e.g. removed under dropbox.com › Connected apps
        await #expect(throws: CloudError.signInNeeded("Dropbox")) { _ = try await b.list("root") }
        #expect(CloudError.signInNeeded("Dropbox").errorDescription == "Dropbox needs you to sign in again.")
    }

    @Test func errorAnswersBecomeSentences() throws {
        func resp(_ status: Int, _ body: JSON) -> DropboxResponse {
            DropboxResponse(status: status, http: HTTPURLResponse(url: URL(string: "https://api.dropboxapi.com/2/x")!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            data: DropboxHTTP.encode(body), file: nil)
        }
        func summary(_ s: String) -> DropboxResponse { resp(409, ["error_summary": .string(s), "error": [".tag": "x"]]) }
        #expect(DropboxHTTP.error(summary("path/conflict/file/.."), name: "A.txt") == .denied("There’s already an item named “A.txt” in that folder on Dropbox."))
        #expect(DropboxHTTP.error(summary("path_lookup/not_found/..")) == .notFound)
        #expect(DropboxHTTP.error(summary("path/insufficient_space/..")) == .quotaExceeded("Dropbox"))
        #expect(DropboxHTTP.error(summary("cant_move_folder_into_itself/..")) == .denied("A folder can’t be moved into itself or into a folder inside it."))
        guard case .unsupported? = Optional(DropboxHTTP.error(summary("unsupported_file/.."), name: "Plan.paper")) else { Issue.record("unsupported_file"); return }
        guard case .denied(let scope) = DropboxHTTP.error(resp(401, ["error_summary": "missing_scope/..",
                                                                      "error": [".tag": "missing_scope", "required_scope": "files.content.write"]])) else {
            Issue.record("missing_scope"); return
        }
        #expect(scope.contains("“files.content.write” permission"))
        #expect(DropboxHTTP.error(resp(401, ["error_summary": "invalid_access_token/..", "error": [".tag": "invalid_access_token"]])) == .signInNeeded("Dropbox"))
        #expect(DropboxHTTP.error(resp(422, ["error_summary": "invalid_root/.."])) == .signInNeeded("Dropbox"))
    }

    @Test func rateLimitsAndWriteContentionAreRetried() async throws {
        var s = FakeDropboxServer.State()
        s.addFile("A.txt", data: Data("a".utf8))
        let (b, _, _) = try await connect(s)
        FakeDropboxServer.update { $0.throttleNext = 3 }
        #expect(try await b.list("root").map(\.name) == ["A.txt"])
        #expect(FakeDropboxServer.state.throttleNext == 0)
        FakeDropboxServer.update { $0.writeContentionNext = 3 }
        _ = try await b.createFolder("Busy", in: "root")
        #expect(FakeDropboxServer.state.contentions == 3 && FakeDropboxServer.state.child(named: "Busy") != nil)
        FakeDropboxServer.update { $0.throttleNext = 50 }
        let e = await cloudError { _ = try await b.list("root") }
        guard case .server(let m)? = e else { Issue.record("expected server error, got \(String(describing: e))"); return }
        #expect(m.contains("limiting"))
    }

    @Test func writesGoOneAtATime() async throws {
        // The gate: one at a time by default, more when allowed, and cancellable while waiting.
        let gate = DropboxGate(limit: 1)
        let running = DBXBox(0)
        let peak = DBXBox(0)
        @Sendable func burst(_ n: Int) async throws {
            try await withThrowingTaskGroup(of: Void.self) { g in
                for _ in 0..<n {
                    g.addTask {
                        try await gate.run {
                            running.mutate { $0 += 1 }
                            let now = running.value
                            peak.mutate { $0 = max($0, now) }
                            try await Task.sleep(nanoseconds: 5_000_000)
                            running.mutate { $0 -= 1 }
                        }
                    }
                }
                for try await _ in g {}
            }
        }
        try await burst(8)
        #expect(peak.value == 1)
        peak.value = 0
        gate.limit = 3
        try await burst(9)
        #expect(peak.value > 1 && peak.value <= 3)
        gate.limit = 1
        let holder = Task { try await gate.run { try await Task.sleep(nanoseconds: 150_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await gate.run { 1 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        try await holder.value
        #expect(try await gate.run { 2 } == 2)   // the slot came back

        // Through the backend: concurrent changes reach Dropbox one by one, with no contention.
        let (b, _, _) = try await connect()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<6 { g.addTask { _ = try await b.createFolder("Folder \(i)", in: "root") } }
            for try await _ in g {}
        }
        #expect(FakeDropboxServer.state.maxConcurrentWrites == 1 && FakeDropboxServer.state.contentions == 0)
        #expect(FakeDropboxServer.state.children(of: "").count == 6 && b.writeConcurrency == 1)
    }

    // MARK: Listing

    @Test func listingFollowsCursorsAndNormalizesTheRoot() async throws {
        var s = FakeDropboxServer.State()
        let docs = s.addFolder("Documents")
        for i in 0..<7 { s.addFile("Note \(i).txt", in: docs, data: Data("note \(i)".utf8), modified: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))) }
        s.addFile("Top.txt", data: Data("top".utf8))
        let team = s.addFolder("Team")
        s.share(team)
        s.addPaperDoc("Plan.paper")
        let (b, _, _) = try await connect(s)
        let root = try await b.list("root")
        #expect(Set(root.map(\.name)) == ["Documents", "Top.txt", "Team", "Plan.paper"])
        #expect(root.allSatisfy { $0.parentID == "root" && $0.zone == "dropbox" && $0.id.hasPrefix("id:") && $0.docID?.hasPrefix("/") == true })
        let d = try #require(root.first { $0.name == "Documents" })
        #expect(d.id == docs && d.type == "FOLDER" && d.isFolder && d.size == 0 && d.docID == "/Documents" && !d.isShared)
        #expect(root.first { $0.name == "Team" }?.isShared == true)
        let top = try #require(root.first { $0.name == "Top.txt" })
        #expect(top.type == "FILE" && top.size == 3 && top.etag != nil && top.modified == FakeDropboxServer.seedDate)

        let notes = try await b.list(docs)
        #expect(notes.count == 7 && notes.allSatisfy { $0.parentID == docs && $0.type == "FILE" })
        #expect(notes.first { $0.name == "Note 3.txt" }?.modified == Date(timeIntervalSince1970: 1_700_000_003))
        #expect(notes.first { $0.name == "Note 3.txt" }?.docID == "/Documents/Note 3.txt")
        let calls = FakeDropboxServer.state.calls
        #expect(calls.filter { $0 == "POST api.dropboxapi.com/2/files/list_folder/continue" }.count == 3)   // root 3+1, docs 3+3+1

        let many = try await b.listMany(["root", docs, "root"])
        #expect(many.count == 2 && many[docs]?.count == 7 && many["root"]?.count == 4)
        // A folder that can't be listed throws: it must never look empty.
        await #expect(throws: CloudError.notFound) { _ = try await b.listMany(["root", "id:FakeDbxAAAAAAAAAA999999"]) }
        let notFolder = await cloudError { _ = try await b.list(top.id) }
        guard case .denied? = notFolder else { Issue.record("expected denied, got \(String(describing: notFolder))"); return }

        // Dropbox invalidates a cursor: the folder is listed again from the start, not left half-listed.
        FakeDropboxServer.update { $0.resetCursorsNext = 1 }
        #expect(try await b.list(docs).count == 7)
        #expect(try await b.list("").count == 4)   // "" is the top too
    }

    // MARK: Uploads

    @Test func smallUploadAddsWithTheDateAndRoundTrips() async throws {
        let (b, _, _) = try await connect()
        let data = Self.bytes(10_000)
        let when = Date(timeIntervalSince1970: 1_750_000_000.75)
        let last = DBXBox<(Int64, Int64)>((0, 0))
        let n = try await b.upload(try Self.file(data), name: "Report.pdf", into: "root", modified: when) { done, total in last.value = (done, total) }
        #expect(n.name == "Report.pdf" && n.parentID == "root" && n.size == 10_000 && n.type == "FILE" && n.id.hasPrefix("id:"))
        #expect(abs((n.modified ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(last.value == (10_000, 10_000))
        let st = FakeDropboxServer.state
        #expect(st.simpleUploads == 1 && st.sessionsStarted == 0)
        let c = st.lastCommit
        #expect(c["path"].string == "/Report.pdf" && c["mode"].string == "add" && c["autorename"].bool == false)
        #expect(c["strict_conflict"].bool == true && c["mute"].bool == false && c["client_modified"].string == "2025-06-15T15:06:40Z")
        let stored = try #require(st.child(named: "Report.pdf"))
        #expect(st.blobs[stored.id] == data)
        #expect(try await node(b, "Report.pdf").modified == Date(timeIntervalSince1970: 1_750_000_000))

        let folder = try await b.createFolder("Inbox", in: "root")
        let empty = try await b.upload(try Self.file(Data(), named: "e"), name: "Empty.txt", into: folder.id, modified: nil) { _, _ in }
        #expect(empty.size == 0 && empty.parentID == folder.id && FakeDropboxServer.state.lastCommit["path"].string == "/Inbox/Empty.txt")
        #expect(FakeDropboxServer.state.lastCommit["client_modified"].isNull)
        #expect(FakeDropboxServer.state.autoCreatedFolders == 0)
    }

    @Test func sessionUploadResumesFromTheOffsetDropboxReports() async throws {
        var s = FakeDropboxServer.State()
        s.loseAppendAnswer = 2        // Dropbox stored chunk 2, but its answer was lost
        s.dropAppendBeforeStore = 4   // chunk 4 broke off before Dropbox stored any of it
        let (b, _, _) = try await connect(s)
        b.simpleUploadLimit = 100_000
        b.chunkSize = 300_000
        let folder = try await b.createFolder("Videos", in: "root")
        let data = Self.bytes(1_000_000)
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let last = DBXBox<(Int64, Int64)>((0, 0))
        let n = try await b.upload(try Self.file(data), name: "Clip.mov", into: folder.id, modified: when) { done, total in last.value = (done, total) }
        #expect(n.size == 1_000_000 && n.parentID == folder.id && n.name == "Clip.mov" && n.modified == when)
        #expect(last.value == (1_000_000, 1_000_000))
        let st = FakeDropboxServer.state
        #expect(st.blobs[n.id] == data)
        // Chunk 2 wasn't sent twice: Dropbox said it already had 600000 bytes.
        #expect(st.appends.map(\.offset) == [0, 300_000, 600_000, 900_000] && st.appends.map(\.size) == [300_000, 300_000, 300_000, 100_000])
        #expect(st.sessionsStarted == 1 && st.finishes == 1 && st.simpleUploads == 0 && st.openUploadSessions == 0)
        let c = st.lastCommit
        #expect(c["path"].string == "/Videos/Clip.mov" && c["mode"].string == "add" && c["autorename"].bool == false && c["client_modified"].string == "2025-10-09T08:53:20Z")
    }

    @Test func lostUploadAnswersAreRecognisedByContentHash() async throws {
        let (b, _, _) = try await connect()
        FakeDropboxServer.update { $0.loseUploadAnswers = 1 }
        let small = try await b.upload(try Self.file(Self.bytes(5_000)), name: "Small.bin", into: "root", modified: nil) { _, _ in }
        #expect(small.size == 5_000 && FakeDropboxServer.state.simpleUploads == 1)

        b.simpleUploadLimit = 0
        b.chunkSize = 300_000
        FakeDropboxServer.update { $0.loseUploadAnswers = 1 }
        let big = try await b.upload(try Self.file(Self.bytes(700_000)), name: "Big.bin", into: "root", modified: nil) { _, _ in }
        #expect(big.size == 700_000 && big.parentID == "root")
        let st = FakeDropboxServer.state
        #expect(st.children(of: "").map(\.name).sorted() == ["Big.bin", "Small.bin"] && st.finishes == 1)
        #expect(st.blobs[big.id] == Self.bytes(700_000))
        // More than two 4 MiB blocks, each hashed on its own.
        var blocks = Data(repeating: 0xAB, count: 9_000_000)
        blocks[4_194_304] = 1
        #expect(try DropboxBackend.contentHash(try Self.file(blocks)) == FakeDropboxServer.contentHash(blocks))
        // Dropbox's documented hash of an empty file: SHA-256 of nothing.
        #expect(try DropboxBackend.contentHash(try Self.file(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func nameConflictsFailClearlyInsteadOfReplacing() async throws {
        var s = FakeDropboxServer.State()
        s.addFile("Taken.txt", data: Data("old".utf8))
        s.addFolder("Docs")
        let (b, _, _) = try await connect(s)
        for limit in [Int64(8 << 20), 0] {   // one request, then an upload session
            b.simpleUploadLimit = limit
            for content in ["new", "old"] {   // the same bytes are a conflict too (strict_conflict)
                let e = await cloudError { _ = try await b.upload(try Self.file(Data(content.utf8)), name: "taken.txt", into: "root", modified: nil) { _, _ in } }
                guard case .denied(let m)? = e else { Issue.record("expected denied, got \(String(describing: e))"); return }
                #expect(m.contains("already") && m.contains("“taken.txt”"))
            }
        }
        let taken = try #require(FakeDropboxServer.state.child(named: "Taken.txt"))
        #expect(FakeDropboxServer.state.blobs[taken.id] == Data("old".utf8) && FakeDropboxServer.state.children(of: "").count == 2)

        let folder = await cloudError { _ = try await b.createFolder("docs", in: "root") }
        guard case .denied(let m2)? = folder else { Issue.record("expected denied, got \(String(describing: folder))"); return }
        #expect(m2.contains("“docs”"))
        let rename = await cloudError { _ = try await b.rename(try await node(b, "Taken.txt"), to: "Docs") }
        guard case .denied? = rename else { Issue.record("expected denied, got \(String(describing: rename))"); return }
    }

    @Test func aFolderDeletedElsewhereIsNeverRecreated() async throws {
        var s = FakeDropboxServer.State()
        let gone = s.addFolder("Old Project")
        s.addFile("Keep.txt", data: Data("k".utf8))
        let (b, _, _) = try await connect(s)
        let target = try await node(b, "Old Project")
        let keep = try await node(b, "Keep.txt")
        FakeDropboxServer.update { $0.items[gone]?.deleted = true }   // deleted on another device
        await #expect(throws: CloudError.notFound) {
            _ = try await b.upload(try Self.file(Data("x".utf8)), name: "New.txt", into: target.id, modified: nil) { _, _ in }
        }
        await #expect(throws: CloudError.notFound) { _ = try await b.createFolder("Sub", in: target.id) }
        await #expect(throws: CloudError.notFound) { try await b.move([keep], to: target.id) }
        let st = FakeDropboxServer.state
        #expect(st.autoCreatedFolders == 0 && st.child(named: "Old Project") == nil && st.child(named: "Keep.txt") != nil)
    }

    @Test func uploadIntoAFolderRenamedElsewhereFollowsIt() async throws {
        var s = FakeDropboxServer.State()
        let f = s.addFolder("Draft")
        let (b, _, _) = try await connect(s)
        let draft = try await node(b, "Draft")
        FakeDropboxServer.update { $0.items[f]?.name = "Final" }   // renamed on another device
        let n = try await b.upload(try Self.file(Data("x".utf8)), name: "Notes.txt", into: draft.id, modified: nil) { _, _ in }
        #expect(n.parentID == draft.id && FakeDropboxServer.state.child(named: "Notes.txt", in: f) != nil)
        #expect(FakeDropboxServer.state.autoCreatedFolders == 0 && FakeDropboxServer.state.child(named: "Draft") == nil)
    }

    @Test func quotaForPersonalAndTeamAccountsAndAFullDropbox() async throws {
        var s = FakeDropboxServer.State()
        s.allocated = 1_000_000
        s.addFile("A.bin", data: Data(count: 200_000))
        let gone = s.addFile("B.bin", data: Data(count: 50_000))
        s.items[gone]?.deleted = true   // deleted files don't count
        let (b, _, _) = try await connect(s)
        let u = try #require(try await b.quota())
        #expect(u.total == 1_000_000 && u.used == 200_000 && u.available == 800_000 && u.categories.map(\.key) == ["files"])
        await #expect(throws: CloudError.quotaExceeded("Dropbox")) {
            _ = try await b.upload(try Self.file(Data(count: 900_000)), name: "Huge.bin", into: "root", modified: nil) { _, _ in }
        }
        FakeDropboxServer.update { $0.team = (used: 5_000_000, allocated: 10_000_000, memberLimit: 0) }
        let pooled = try #require(try await b.quota())
        #expect(pooled.total == 10_000_000 && pooled.used == 5_000_000)
        #expect(pooled.categories.map(\.key) == ["files", "team"] && pooled.categories.map(\.bytes) == [200_000, 4_800_000])
        FakeDropboxServer.update { $0.team = (used: 5_000_000, allocated: 10_000_000, memberLimit: 2_000_000) }
        let limited = try #require(try await b.quota())
        #expect(limited.total == 2_000_000 && limited.used == 200_000)
    }

    // MARK: Downloads

    @Test func downloadStreamsTheFileAndSetsItsDate() async throws {
        var s = FakeDropboxServer.State()
        let data = Self.bytes(300_000, seed: 3)
        let when = Date(timeIntervalSince1970: 1_720_000_000)
        s.addFile("Photo.jpg", data: data, modified: when)
        s.addPaperDoc("Plan.paper")
        s.dropDownloadsNext = 1
        let (b, _, _) = try await connect(s)
        let photo = try await node(b, "Photo.jpg")
        let dest = Self.tempDir().appendingPathComponent("out/Photo.jpg")
        let last = DBXBox<(Int64, Int64)>((0, 0))
        try await b.download(photo, to: dest) { done, total in last.value = (done, total) }
        #expect(try Data(contentsOf: dest) == data)
        let mtime = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(mtime == when)
        #expect(last.value == (300_000, 300_000))
        let st = FakeDropboxServer.state
        #expect(st.calls.filter { $0 == "POST content.dropboxapi.com/2/files/download" }.count == 2 && st.downloads == 1)   // dropped once, then retried
        #expect(st.argHeaders.last == "{\"path\":\"\(photo.id)\"}")

        let paper = try await node(b, "Plan.paper")
        let e = await cloudError { try await b.download(paper, to: dest) { _, _ in } }
        guard case .unsupported(let m)? = e else { Issue.record("expected unsupported, got \(String(describing: e))"); return }
        #expect(m.contains("dropbox.com") && m.contains("“Plan.paper”"))
        #expect(try Data(contentsOf: dest) == data)   // the earlier download is untouched
    }

    // MARK: Changes

    @Test func createRenameAndMoveIncludingBackToTheTop() async throws {
        var s = FakeDropboxServer.State()
        s.addFile("Plan.txt", data: Data("plan".utf8))
        let (b, _, _) = try await connect(s)
        let projects = try await b.createFolder("Projects", in: "root")
        #expect(projects.parentID == "root" && projects.type == "FOLDER" && projects.name == "Projects" && projects.id.hasPrefix("id:"))
        let year = try await b.createFolder("2026", in: projects.id)
        #expect(year.parentID == projects.id && FakeDropboxServer.state.path(of: year.id) == "/Projects/2026")
        let renamed = try await b.rename(projects, to: "Projects (old)")
        #expect(renamed.id == projects.id && renamed.name == "Projects (old)" && renamed.parentID == "root")
        #expect(FakeDropboxServer.state.path(of: year.id) == "/Projects (old)/2026")   // the id still works below it

        // Same name: nothing to do. Only the case changes: a real rename.
        let before = FakeDropboxServer.state.calls.filter { $0.hasSuffix("move_v2") }.count
        _ = try await b.rename(year, to: "2026")
        #expect(FakeDropboxServer.state.calls.filter { $0.hasSuffix("move_v2") }.count == before)
        let plan = try await node(b, "Plan.txt")
        #expect(try await b.rename(plan, to: "PLAN.txt").name == "PLAN.txt")
        #expect(FakeDropboxServer.state.items[plan.id]?.name == "PLAN.txt")

        try await b.move([plan], to: year.id)
        #expect(try await b.list(year.id).map(\.name) == ["PLAN.txt"])
        #expect(try await b.list("root").contains { $0.name == "PLAN.txt" } == false)
        try await b.move([plan], to: "root")
        #expect(try await b.list("root").contains { $0.name == "PLAN.txt" })
        // Already there: no request.
        let moves = FakeDropboxServer.state.calls.filter { $0.hasSuffix("move_v2") }.count
        try await b.move([plan], to: "root")
        #expect(FakeDropboxServer.state.calls.filter { $0.hasSuffix("move_v2") }.count == moves)
        // Renamed elsewhere since it was listed: it keeps its current name when moved.
        FakeDropboxServer.update { $0.items[plan.id]?.name = "Plan v2.txt" }
        try await b.move([plan], to: year.id)
        #expect(FakeDropboxServer.state.path(of: plan.id) == "/Projects (old)/2026/Plan v2.txt")
        // A folder can't go inside itself.
        let e = await cloudError { try await b.move([renamed], to: year.id) }
        guard case .denied? = e else { Issue.record("expected denied, got \(String(describing: e))"); return }
        #expect(FakeDropboxServer.state.autoCreatedFolders == 0)
    }

    @Test func trashKeepsItemsRestorableOnDropboxAndRestoreIsLeftToTheWeb() async throws {
        var s = FakeDropboxServer.State()
        s.addFile("Old.txt", data: Data(count: 1000))
        let folder = s.addFolder("Archive")
        s.addFile("Inside.txt", in: folder, data: Data("i".utf8))
        let (b, _, _) = try await connect(s)
        let old = try await node(b, "Old.txt")
        let archive = try await node(b, "Archive")
        try await b.trash([old, archive])
        #expect(try await b.list("root").isEmpty)
        let st = FakeDropboxServer.state
        #expect(Set(st.deletedItems.map(\.name)) == ["Old.txt", "Archive"] && st.blobs[old.id] != nil)
        #expect(st.calls.filter { $0.hasSuffix("delete_v2") }.count == 2 && !st.calls.contains { $0.contains("permanently_delete") })
        try await b.trash([old])   // already gone: fine
        #expect(b.canListTrash == false)
        #expect(try await b.listTrash().isEmpty)
        await #expect(throws: CloudError.unsupported(DropboxBackend.deletedFilesMessage)) { try await b.restore([old]) }
        await #expect(throws: CloudError.unsupported(DropboxBackend.deletedFilesMessage)) { try await b.deleteForever([old]) }
        #expect(DropboxBackend.deletedFilesMessage.contains("dropbox.com") && DropboxBackend.deletedFilesMessage.contains("Deleted files"))
    }

    @Test func oddNamesTravelAsHeaderSafeJSONAndRoundTrip() async throws {
        // Dropbox-API-Arg: 0x7F and everything non-ASCII as backslash-u escapes (UTF-16, so emoji become surrogate pairs).
        let u = "\u{5C}u"   // backslash, u
        #expect(DropboxHTTP.headerSafe(["path": "/caf\u{E9} \u{1F600}\u{7F}"]) == "{\"path\":\"/caf" + u + "00e9 " + u + "d83d" + u + "de00" + u + "007f\"}")
        #expect(DropboxHTTP.headerSafe(["cursor": ["offset": .int64(5_368_709_120), "session_id": "s"], "close": false])
                == #"{"close":false,"cursor":{"offset":5368709120,"session_id":"s"}}"#)
        let (b, _, _) = try await connect()
        let decomposed = "U\u{308}ber\u{301}.txt"   // as macOS file names often arrive
        let names = ["Q&A #1 – 100% + more.txt", "café 日本語 😀.md", "quote\"back\\slash'.txt", "semi;colon=equals,comma@at$!~.txt", decomposed]
        let folder = try await b.createFolder("50% #done + more 😀", in: "root")
        #expect(FakeDropboxServer.state.child(named: "50% #done + more 😀") != nil)
        for (i, name) in names.enumerated() {
            let data = Data("file \(i)".utf8)
            b.simpleUploadLimit = i % 2 == 0 ? 8 << 20 : 0   // both the one-request upload and a session
            let n = try await b.upload(try Self.file(data), name: name, into: folder.id, modified: Date(timeIntervalSince1970: 1_700_000_000)) { _, _ in }
            let want = name.precomposedStringWithCanonicalMapping
            #expect(n.name == want)
            let stored = try #require(FakeDropboxServer.state.child(named: want, in: folder.id))
            #expect(stored.name == want && FakeDropboxServer.state.blobs[stored.id] == data)
            let dest = Self.tempDir().appendingPathComponent("f\(i)")
            try await b.download(try await node(b, want, in: folder.id), to: dest) { _, _ in }
            #expect(try Data(contentsOf: dest) == data)
            let mtime = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
            #expect(mtime == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(try await b.rename(n, to: "→ " + want).name == "→ " + want)
        }
        let st = FakeDropboxServer.state
        #expect(st.nonASCIIArgHeaders == 0 && !st.argHeaders.isEmpty && st.argHeaders.allSatisfy { $0.allSatisfy(\.isASCII) })
        #expect(st.argHeaders.contains { $0.contains(u + "d83d" + u + "de00") })
        // Names Dropbox can't take are caught before anything is sent.
        let calls = st.calls.count
        for bad in ["a/b.txt", "", "..", "tab\there"] {
            let e = await cloudError { _ = try await b.upload(try Self.file(Data("x".utf8)), name: bad, into: "root", modified: nil) { _, _ in } }
            guard case .denied? = e else { Issue.record("\(bad): expected denied, got \(String(describing: e))"); continue }
        }
        #expect(FakeDropboxServer.state.calls.count == calls)
    }

    // MARK: Extras

    @Test func thumbnailsAskForASizeThatCoversTheRequest() async throws {
        var s = FakeDropboxServer.State()
        let img = try #require(DemoArt.jpeg(width: 64, height: 48, hue: 0.3, label: "T"))
        let png = FakeWebDAVServer.png(width: 32, height: 32, hue: 0.6)
        s.addFile("Pic.JPG", data: img)
        s.addFile("Icon.png", data: png)
        s.addFile("Notes.txt", data: Data("n".utf8))
        s.addFile("Broken.jpg", data: Data("not an image".utf8))
        s.addFolder("Folder")
        let (b, _, _) = try await connect(s)
        let pic = try await node(b, "Pic.JPG")
        #expect(try await b.thumbnail(pic, maxPixel: 256) == img)
        let a = try #require(FakeDropboxServer.state.thumbnailArgs.last)
        #expect(a["size"].string == "w256h256" && a["format"].string == "jpeg" && a["mode"].string == "bestfit")
        #expect(a["resource"][".tag"].string == "path" && a["resource"]["path"].string == pic.id)
        for (px, size) in [(20, "w32h32"), (64, "w64h64"), (300, "w480h320"), (1000, "w1024h768"), (2048, "w2048h1536"), (5000, "w2048h1536")] {
            _ = try await b.thumbnail(pic, maxPixel: px)
            #expect(FakeDropboxServer.state.thumbnailArgs.last?["size"].string == size)
        }
        #expect(try await b.thumbnail(try await node(b, "Icon.png"), maxPixel: 128) == png)
        #expect(FakeDropboxServer.state.thumbnailArgs.last?["format"].string == "png")
        #expect(try await b.thumbnail(try await node(b, "Broken.jpg"), maxPixel: 128) == nil)   // Dropbox can't make one: nil
        let notes = try await node(b, "Notes.txt")
        let folder = try await node(b, "Folder")
        let calls = FakeDropboxServer.state.calls.count
        #expect(try await b.thumbnail(notes, maxPixel: 256) == nil)
        #expect(try await b.thumbnail(folder, maxPixel: 256) == nil)
        #expect(FakeDropboxServer.state.calls.count == calls)   // no request for types without thumbnails
    }

    @Test func teamSpaceAccountsBrowseFromTheTeamRoot() async throws {
        var s = FakeDropboxServer.State()
        s.teamRootNamespace = "7769321"
        s.addFolder("Marketing")
        let (b, record, secret) = try await connect(s)
        #expect(record.options == ["pathRoot": "7769321"])
        let before = FakeDropboxServer.state.missingPathRoot   // the sign-in itself reads the account without one
        #expect(try await b.list("root").map(\.name) == ["Marketing"])
        _ = try await b.createFolder("Plans", in: "root")
        _ = try await b.upload(try Self.file(Data("x".utf8)), name: "x.txt", into: "root", modified: nil) { _, _ in }
        #expect(FakeDropboxServer.state.missingPathRoot == before && FakeDropboxServer.state.pathRootHeaders == 3)
        // The team space changed (e.g. the member left the team): sign in again.
        var moved = record
        moved.options = ["pathRoot": "1111"]
        let stale = try Dropbox.backend(record: moved, secret: secret, transport: Self.transport)
        await #expect(throws: CloudError.signInNeeded("Dropbox")) { _ = try await stale.list("root") }
    }

    @Test func demoAccountBrowsesGenericSampleContent() async throws {
        FakeDropboxServer.reset()
        defer { FakeDropboxServer.reset() }
        let demo = try #require(Dropbox.demo())
        #expect(demo.record.id == "cloud:dropbox:demo" && demo.record.provider == .dropbox && demo.record.title == "alex@example.com")
        let b = demo.backend
        #expect(b.provider == .dropbox && b.rootID == "root" && b is CloudTokenRotating)
        let root = try await b.list(b.rootID)
        #expect(Set(root.map(\.name)) == ["Documents", "Photos", "Read Me.txt"])
        let docs = try await b.list(try #require(root.first { $0.name == "Documents" }).id)
        #expect(Set(docs.map(\.name)) == ["Meeting Notes.txt", "Budget.csv"])
        let photos = try await b.list(try #require(root.first { $0.name == "Photos" }).id)
        #expect(photos.count == 2)
        let thumb = try #require(try await b.thumbnail(photos[0], maxPixel: 128))
        #expect(thumb.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try await b.quota() != nil)
        let again = try #require(Dropbox.demo())
        #expect(try await again.backend.list("root").count == 3)
        #expect(CloudBackends.demo(.dropbox)?.record.id == "cloud:dropbox:demo")
    }
}
