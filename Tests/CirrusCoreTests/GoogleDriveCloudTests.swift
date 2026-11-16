import CryptoKit
import Foundation
import Testing
@testable import CirrusCore

/// Google Drive as a browsable account (full `drive` scope), against FakeGoogleServer.
extension GoogleServerTests {
@Suite struct GoogleDriveCloudTests {
    let client = GoogleOAuthClient(clientID: "demo-client.apps.googleusercontent.com", clientSecret: "demo-secret")
    let fake: [AnyClass] = [FakeGoogleServer.self]

    /// Signs in through the real loopback listener and returns a fast-retrying backend.
    func connect(_ s: FakeGoogleServer.State = FakeGoogleServer.State()) async throws -> (record: CloudAccountRecord, secret: CloudSecret, drive: GoogleDriveBackend) {
        FakeGoogleServer.reset(s)
        let (record, secret) = try await GoogleDriveCloud.signIn(client: client, transport: fake) { url in await FakeGoogleServer.approve(url) }
        let b = try GoogleDriveCloud.makeBackend(record: record, secret: secret, transport: fake)
        b.api.retryBase = 0.001
        return (record, secret, b)
    }

    static func tempDir(_ name: String) -> URL { GoogleMigrationTests.tempDir("gdrive-" + name) }
    static func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ n: Int, seed: Int = 7) -> Data { Data((0..<n).map { UInt8(($0 * 31 + seed) % 251) }) }
    static func write(_ d: Data, _ name: String, in dir: URL) throws -> URL {
        let u = dir.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + name)
        try d.write(to: u)
        return u
    }
    static func mtime(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }

    // MARK: Sign-in

    @Test func signInAsksForTheFullDriveScopeAndUsesTheEmail() async throws {
        var s = FakeGoogleServer.State()
        s.email = "alex@example.com"
        s.name = "Alex Morgan"
        FakeGoogleServer.reset(s)
        let seen = URLBox()
        let (record, secret) = try await GoogleDriveCloud.signIn(client: client, transport: fake) { url in
            seen.url = url
            await FakeGoogleServer.approve(url)
        }
        var q = [String: String]()
        for i in URLComponents(url: try #require(seen.url), resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value }
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive" && GoogleScopes.drive == q["scope"])
        #expect(q["code_challenge_method"] == "S256" && q["access_type"] == "offline" && q["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(record.provider == .googleDrive && record.title == "alex@example.com" && record.id.hasPrefix("cloud:googleDrive:"))
        #expect(secret.refreshToken?.hasPrefix("1//fake-refresh-") == true)
        #expect(secret.clientID == client.clientID && secret.clientSecret == client.clientSecret && secret.password == nil)
        #expect(FakeGoogleServer.state.refreshTokens[secret.refreshToken ?? ""] == [GoogleScopes.drive])

        // Refused on Google's page, Drive box unticked, or no client set up: each says what to do.
        await #expect(throws: CloudError.self) {
            _ = try await GoogleDriveCloud.signIn(client: client, transport: fake) { url in await FakeGoogleServer.approve(url, deny: true) }
        }
        FakeGoogleServer.update { $0.grantedScopes = GoogleScopes.all }
        do {
            _ = try await GoogleDriveCloud.signIn(client: client, transport: fake) { url in await FakeGoogleServer.approve(url) }
            Issue.record("expected denied")
        } catch let e as CloudError {
            guard case .denied(let m) = e else { Issue.record("expected denied, got \(e)"); return }
            #expect(m.contains("tick"))
        }
        await #expect(throws: CloudError.notConfigured(GoogleDriveCloud.notConfiguredMessage)) {
            _ = try await GoogleDriveCloud.signIn(client: GoogleOAuthClient(clientID: "not-a-client", clientSecret: nil), transport: fake) { _ in }
        }
    }

    @Test func savedSignInProblemsAreSignInNeededOrNotConfigured() async throws {
        let (record, secret, drive) = try await connect()
        _ = try await drive.list(drive.rootID)
        #expect(throws: CloudError.notConfigured(GoogleDriveCloud.notConfiguredMessage)) {
            _ = try GoogleDriveCloud.make(record: record, secret: CloudSecret(refreshToken: secret.refreshToken), transport: fake)
        }
        #expect(throws: CloudError.signInNeeded("Google Drive")) {
            _ = try GoogleDriveCloud.make(record: record, secret: CloudSecret(clientID: secret.clientID, clientSecret: secret.clientSecret), transport: fake)
        }
        // Revoked at Google (or the Testing project's 7 days ran out): invalid_grant → sign in again.
        FakeGoogleServer.update { $0.revokeAllRefreshTokens(); $0.accessTokens = [:] }
        let again = try GoogleDriveCloud.make(record: record, secret: secret, transport: fake)
        await #expect(throws: CloudError.signInNeeded("Google Drive")) { _ = try await again.list(again.rootID) }
        // An access token Google stopped accepting mid-session is the same.
        await #expect(throws: CloudError.signInNeeded("Google Drive")) { _ = try await drive.quota() }
    }

    @Test func aRotatedRefreshTokenIsUsedAndHandedToTheApp() async throws {
        var s = FakeGoogleServer.State()
        s.accessTTL = 1   // < 90 s: every call refreshes first
        let (_, secret, drive) = try await connect(s)
        FakeGoogleServer.update { $0.rotateRefreshTokens = true }
        let saved = SecretBox()
        drive.onNewRefreshToken = { saved.value = $0 }
        _ = try await drive.list(drive.rootID)
        let first = try #require(saved.value)
        #expect(first.refreshToken != secret.refreshToken && first.clientID == secret.clientID && first.clientSecret == secret.clientSecret)
        #expect(drive.secret == first)
        // The old token no longer works at the fake; the next refresh must use the new one.
        _ = try await drive.list(drive.rootID)
        #expect(saved.value?.refreshToken != first.refreshToken)
        #expect(FakeGoogleServer.state.refreshTokenList == [saved.value?.refreshToken ?? ""])
    }

    // MARK: Listing

    @Test func listingPagesNormalizesTheRootAndNeverTurnsFailuresIntoEmptyFolders() async throws {
        var s = FakeGoogleServer.State()
        let big = s.addUserFolder("Big")
        for i in 0..<1205 { s.addUserFile(String(format: "f%04d.txt", i), parent: big, data: Data("\(i)".utf8)) }
        let pics = s.addUserFolder("Pictures")
        let jpg = s.addUserFile("Lake.jpg", parent: pics, data: Self.bytes(5000), modified: Date(timeIntervalSince1970: 1_750_000_000))
        s.addUserFolder("Empty")
        s.addUserFile("Readme.txt", data: Data("hi".utf8))
        s.addUserFile("Elsewhere.pdf", parent: "shared-folder-elsewhere", data: Data("%PDF".utf8))   // shared with the user, not in My Drive
        let (_, _, drive) = try await connect(s)

        let root = try await drive.list(drive.rootID)
        #expect(Set(root.map(\.name)) == ["Big", "Pictures", "Empty", "Readme.txt"])
        #expect(root.allSatisfy { $0.parentID == "root" })
        #expect(root.first { $0.name == "Big" }?.type == "FOLDER" && root.first { $0.name == "Readme.txt" }?.type == "FILE")
        // The real root id lists the same, still normalized to "root".
        let viaReal = try await drive.list(FakeGoogleServer.rootID)
        #expect(Set(viaReal.map(\.id)) == Set(root.map(\.id)) && viaReal.allSatisfy { $0.parentID == "root" })

        let calls = FakeGoogleServer.state.calls.count
        let many = try await drive.list(big)
        #expect(many.count == 1205 && Set(many.map(\.name)).count == 1205 && many.allSatisfy { $0.parentID == big })
        #expect(FakeGoogleServer.state.calls.dropFirst(calls).filter { $0 == "GET www.googleapis.com/drive/v3/files" }.count == 2)   // two pages

        let lake = try #require(try await drive.list(pics).first)
        #expect(lake.id == jpg && lake.size == 5000 && lake.etag == Self.md5(Self.bytes(5000)) && lake.modified == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(lake.created != nil && lake.zone == "image/jpeg" && lake.docID == jpg)

        let both = try await drive.listMany([big, pics, drive.rootID, "root"])
        #expect(both.count == 3 && both[big]?.count == 1205 && both[pics]?.count == 1 && both["root"]?.count == 4)

        // An empty folder is empty; one that's gone or in the trash is an error, never “empty”.
        #expect(try await drive.list(try #require(root.first { $0.name == "Empty" }).id).isEmpty)
        await #expect(throws: CloudError.notFound) { _ = try await drive.list("no-such-folder") }
        FakeGoogleServer.update { $0.files[pics]?.trashed = true }
        await #expect(throws: CloudError.notFound) { _ = try await drive.list(pics) }
        // Rate limits are waited out; a server that keeps failing makes the listing fail.
        FakeGoogleServer.update { $0.rateLimitNext = 2 }
        #expect(try await drive.list(drive.rootID).count == 3)
        drive.api.maxRetries = 1
        FakeGoogleServer.update { $0.rateLimitNext = 5 }
        await #expect(throws: CloudError.self) { _ = try await drive.list(big) }
        await #expect(throws: CloudError.self) { _ = try await drive.listMany([big, drive.rootID]) }
    }

    // MARK: Google Docs, Sheets, Slides

    @Test func googleDocsAreExportedFilesAndRenamingKeepsTheirTitlesClean() async throws {
        var s = FakeGoogleServer.State()
        let doc = s.addUserDoc("Project plan", modified: Date(timeIntervalSince1970: 1_760_000_000))
        let sheet = s.addUserDoc("Budget", kind: "spreadsheet")
        s.addUserDoc("Deck", kind: "presentation")
        s.addUserDoc("Sketch", kind: "drawing")
        s.addUserDoc("data.xlsx", kind: "spreadsheet")       // a converted upload keeps its extension
        let form = s.addUserDoc("Survey", kind: "form")
        let big = s.addUserDoc("Annual report", tooLarge: true)
        let (_, _, drive) = try await connect(s)
        let dir = Self.tempDir("natives")

        let root = try await drive.list(drive.rootID)
        #expect(Set(root.map(\.name)) == ["Project plan.docx", "Budget.xlsx", "Deck.pptx", "Sketch.pdf", "data.xlsx", "Survey", "Annual report.docx"])
        #expect(root.allSatisfy { $0.size == 0 && $0.type == "FILE" })

        let plan = try #require(root.first { $0.id == doc })
        let out = dir.appendingPathComponent("Project plan.docx")
        let seen = ProgressBox()
        try await drive.download(plan, to: out) { done, total in seen.add(done, total) }
        let text = String(decoding: try Data(contentsOf: out).prefix(120), as: UTF8.self)
        #expect(text.hasPrefix("FAKE-EXPORT application/vnd.openxmlformats-officedocument.wordprocessingml.document of Project plan"))
        #expect(Self.mtime(out) == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(seen.last.0 > 0 && seen.last.0 == seen.last.1)
        // Over files.export's 10 MB: through the file's export link instead.
        try await drive.download(try #require(root.first { $0.id == big }), to: dir.appendingPathComponent("big.docx")) { _, _ in }
        #expect(FakeGoogleServer.state.exportLinkUses == 1)
        // Forms and the like are listed but can't be downloaded.
        do {
            try await drive.download(try #require(root.first { $0.id == form }), to: dir.appendingPathComponent("Survey")) { _, _ in }
            Issue.record("expected unsupported")
        } catch let e as CloudError {
            guard case .unsupported(let m) = e else { Issue.record("expected unsupported, got \(e)"); return }
            #expect(m.contains("Survey") && m.contains("Google Forms"))
        }

        // Renaming: the extension Cirrus shows isn't written into Google's title.
        let budget = try #require(root.first { $0.id == sheet })
        let renamed = try await drive.rename(budget, to: "Budget 2027.xlsx")
        #expect(FakeGoogleServer.state.files[sheet]?.name == "Budget 2027" && renamed.name == "Budget 2027.xlsx" && renamed.parentID == "root")
        let plain = try await drive.rename(renamed, to: "Spending")
        #expect(FakeGoogleServer.state.files[sheet]?.name == "Spending" && plain.name == "Spending.xlsx")
        let odd = try await drive.rename(plan, to: ".docx")      // nothing left once the extension is off: kept as typed
        #expect(FakeGoogleServer.state.files[doc]?.name == ".docx" && odd.name == ".docx")

        // PDF exports instead of Office files.
        drive.exportFormat = .pdf
        let asPDF = try await drive.list(drive.rootID)
        #expect(asPDF.contains { $0.name == "Spending.pdf" } && asPDF.contains { $0.name == "Deck.pdf" })
        try await drive.download(try #require(asPDF.first { $0.name == "Deck.pdf" }), to: dir.appendingPathComponent("Deck.pdf")) { _, _ in }
        #expect(String(decoding: try Data(contentsOf: dir.appendingPathComponent("Deck.pdf")).prefix(40), as: UTF8.self).hasPrefix("FAKE-EXPORT application/pdf"))
    }

    // MARK: Shortcuts

    @Test func shortcutsOpenTheirTargetsWithoutEverLoopingAndChangeOnlyThemselves() async throws {
        var s = FakeGoogleServer.State()
        let team = s.addUserFolder("Team")
        let a = s.addUserFile("a.txt", parent: team, data: Data("alpha".utf8))
        let loop = s.addUserShortcut("Back to Team", to: team, parent: team)          // a shortcut inside its own target
        let link = s.addUserShortcut("Team link", to: team)
        let reportBytes = Self.bytes(70_000)
        let report = s.addUserFile("report.bin", parent: team, data: reportBytes, modified: Date(timeIntervalSince1970: 1_740_000_000))
        let toFile = s.addUserShortcut("Latest report", to: report, modified: Date(timeIntervalSince1970: 1_700_000_000))
        let doc = s.addUserDoc("Plan", parent: team)
        s.addUserShortcut("Plan", to: doc)
        let (_, _, drive) = try await connect(s)
        let dir = Self.tempDir("shortcuts")

        let root = try await drive.list(drive.rootID)
        let teamLink = try #require(root.first { $0.id == link })
        #expect(teamLink.isFolder && teamLink.name == "Team link" && teamLink.docID == team)
        let latest = try #require(root.first { $0.id == toFile })
        #expect(!latest.isFolder && latest.name == "Latest report" && latest.docID == report)
        #expect(root.first { $0.docID == doc }?.name == "Plan.docx")

        // A folder shortcut shows the target's items, under the shortcut.
        let inside = try await drive.list(teamLink.id)
        #expect(Set(inside.map(\.name)) == ["a.txt", "Back to Team", "report.bin", "Plan.docx"])
        #expect(inside.allSatisfy { $0.parentID == teamLink.id })
        let aViaLink = try #require(inside.first { $0.name == "a.txt" })
        #expect(aViaLink.id == "\(a)~\(link)" && aViaLink.docID == a)
        try await drive.download(aViaLink, to: dir.appendingPathComponent("a.txt")) { _, _ in }
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("alpha".utf8))

        // A shortcut that leads back into itself is followed once, then shows as empty, so a full walk ends.
        let back = try #require(inside.first { $0.name == "Back to Team" })
        let again = try await drive.list(back.id)
        #expect(again.count == 4)
        let backAgain = try #require(again.first { $0.name == "Back to Team" })
        #expect(try await drive.list(backAgain.id).isEmpty)
        let all = try await drive.walk(drive.rootID)
        #expect(all.count < 40 && all.contains { $0.path == "Team link/Back to Team/a.txt" })
        #expect(all.contains { $0.path == "Team/Back to Team/Back to Team" } && !all.contains { $0.path.hasPrefix("Team/Back to Team/Back to Team/") })

        // A file shortcut downloads what it points to, with the target's date.
        let out = dir.appendingPathComponent("Latest report")
        try await drive.download(latest, to: out) { _, _ in }
        #expect(try Data(contentsOf: out) == reportBytes && Self.mtime(out) == Date(timeIntervalSince1970: 1_740_000_000))
        // …and a shortcut to a Doc exports the Doc.
        let planOut = dir.appendingPathComponent("Plan.docx")
        try await drive.download(try #require(root.first { $0.docID == doc }), to: planOut) { _, _ in }
        #expect(String(decoding: try Data(contentsOf: planOut).prefix(30), as: UTF8.self).hasPrefix("FAKE-EXPORT"))

        // Renaming, trashing or uploading through a shortcut: the shortcut changes, the target only gets the upload.
        _ = try await drive.rename(latest, to: "Old report")
        #expect(FakeGoogleServer.state.files[toFile]?.name == "Old report" && FakeGoogleServer.state.files[report]?.name == "report.bin")
        let up = try Self.write(Data("new".utf8), "new.txt", in: dir)
        let added = try await drive.upload(up, name: "new.txt", into: teamLink.id, modified: nil) { _, _ in }
        #expect(FakeGoogleServer.state.files[added.docID ?? ""]?.parents == [team] && added.parentID == teamLink.id && added.id.hasSuffix("~\(link)"))
        try await drive.trash([latest, teamLink])
        #expect(FakeGoogleServer.state.files[toFile]?.trashed == true && FakeGoogleServer.state.files[link]?.trashed == true)
        #expect(FakeGoogleServer.state.files[report]?.trashed == false && !FakeGoogleServer.state.isTrashed(team))
        #expect(try await drive.list(team).count == 5)
        _ = loop
    }

    // MARK: Transfers

    @Test func uploadsAndDownloadsRoundTripWithDatesProgressAndStaleListings() async throws {
        var s = FakeGoogleServer.State()
        let folder = s.addUserFolder("Inbox")
        let changing = s.addUserFile("notes.txt", parent: folder, data: Data("first version".utf8))
        let (_, _, drive) = try await connect(s)
        drive.drive.chunkSize = 256 * 1024
        let saved = GoogleDrive.downloadChunk
        GoogleDrive.downloadChunk = 256 * 1024
        defer { GoogleDrive.downloadChunk = saved }
        let dir = Self.tempDir("transfers")

        let data = Self.bytes(700_000, seed: 3)
        let when = Date(timeIntervalSince1970: 1_720_000_000)
        let src = try Self.write(data, "video.mov", in: dir)
        let sent = ProgressBox()
        let node = try await drive.upload(src, name: "video.mov", into: folder, modified: when) { done, total in sent.add(done, total) }
        #expect(node.name == "video.mov" && node.size == 700_000 && node.parentID == folder && node.type == "FILE" && node.modified == when)
        #expect(node.etag == Self.md5(data) && sent.last == (700_000, 700_000))
        #expect(FakeGoogleServer.state.chunkPuts == 3)   // 256 KiB chunks
        let listed = try #require(try await drive.list(folder).first { $0.id == node.id })
        #expect(listed.modified == when && listed.size == 700_000 && listed.etag == node.etag)

        let out = dir.appendingPathComponent("down/video.mov")
        let got = ProgressBox()
        try await drive.download(listed, to: out) { done, total in got.add(done, total) }
        #expect(try Data(contentsOf: out) == data && Self.mtime(out) == when)
        #expect(got.count >= 3 && got.last == (700_000, 700_000) && FakeGoogleServer.state.rangedGets == 3)
        // Downloading over an existing file replaces it.
        try await drive.download(listed, to: out) { _, _ in }
        #expect(try Data(contentsOf: out) == data)

        // Into My Drive itself, and an empty file.
        let empty = try Self.write(Data(), "empty.txt", in: dir)
        let e = try await drive.upload(empty, name: "empty.txt", into: drive.rootID, modified: nil) { _, _ in }
        #expect(e.parentID == "root" && e.size == 0 && FakeGoogleServer.state.files[e.id]?.parents == [FakeGoogleServer.rootID])
        try await drive.download(e, to: dir.appendingPathComponent("e.txt")) { _, _ in }
        #expect(try Data(contentsOf: dir.appendingPathComponent("e.txt")).isEmpty)

        // The file changed after it was listed: the download notices and fetches the current version.
        let stale = try #require(try await drive.list(folder).first { $0.id == changing })
        FakeGoogleServer.update { $0.changeUserFile(changing, data: Data("second, longer version".utf8)) }
        try await drive.download(stale, to: dir.appendingPathComponent("notes.txt")) { _, _ in }
        #expect(try Data(contentsOf: dir.appendingPathComponent("notes.txt")) == Data("second, longer version".utf8))

        // A dropped connection mid-upload resumes; storage that's full is said plainly.
        FakeGoogleServer.update { $0.dropDriveChunk = $0.chunkPuts + 2 }
        let resumed = try await drive.upload(src, name: "again.mov", into: folder, modified: nil) { _, _ in }
        #expect(FakeGoogleServer.state.files[resumed.id]?.md5 == Self.md5(data))
        FakeGoogleServer.update { $0.limit = $0.usage + 10 }
        await #expect(throws: CloudError.quotaExceeded("Google Drive")) {
            _ = try await drive.upload(src, name: "too big.mov", into: folder, modified: nil) { _, _ in }
        }
        let inbox = try #require(try await drive.list(drive.rootID).first { $0.name == "Inbox" })
        await #expect(throws: CloudError.self) { try await drive.download(inbox, to: dir.appendingPathComponent("x")) { _, _ in } }
    }

    // MARK: Changes

    @Test func createRenameAndMoveFoldersAndFiles() async throws {
        var s = FakeGoogleServer.State()
        let old = s.addUserFolder("Old stuff")
        let file = s.addUserFile("a.txt", parent: old, data: Data("a".utf8))
        let (_, _, drive) = try await connect(s)

        let projects = try await drive.createFolder("Projects", in: drive.rootID)
        #expect(projects.isFolder && projects.parentID == "root" && FakeGoogleServer.state.files[projects.id]?.parents == [FakeGoogleServer.rootID])
        let year = try await drive.createFolder("2026", in: projects.id)
        #expect(year.parentID == projects.id && FakeGoogleServer.state.files[year.id]?.mimeType == GoogleDrive.folderMime)
        let renamed = try await drive.rename(year, to: "2026 – Q1")
        #expect(renamed.name == "2026 – Q1" && renamed.id == year.id && renamed.parentID == projects.id)

        let a = try #require(try await drive.list(old).first)
        try await drive.move([a], to: renamed.id)
        #expect(FakeGoogleServer.state.files[file]?.parents == [year.id])
        #expect(try await drive.list(old).isEmpty)
        #expect(try await drive.list(year.id).map(\.id) == [file])
        // Moving uses Google's current parents, not the (now stale) listing.
        try await drive.move([a], to: drive.rootID)
        #expect(FakeGoogleServer.state.files[file]?.parents == [FakeGoogleServer.rootID])
        try await drive.move([a], to: drive.rootID)   // already there: nothing to do
        // A folder can't go inside itself.
        await #expect(throws: CloudError.self) { try await drive.move([projects], to: year.id) }
        await #expect(throws: CloudError.self) { try await drive.move([projects], to: projects.id) }
        try await drive.move([projects], to: old)
        #expect(FakeGoogleServer.state.files[projects.id]?.parents == [old])
        await #expect(throws: CloudError.notFound) { _ = try await drive.createFolder("x", in: "no-such-folder") }
    }

    @Test func trashIsRecoverableAndOnlyDeleteForeverDeletes() async throws {
        var s = FakeGoogleServer.State()
        let folder = s.addUserFolder("Old")
        let inside = s.addUserFile("inside.txt", parent: folder, data: Data("x".utf8))
        let loose = s.addUserFile("loose.txt", data: Data("y".utf8))
        let keep = s.addUserFile("keep.txt", data: Data("z".utf8))
        let (_, _, drive) = try await connect(s)

        let root = try await drive.list(drive.rootID)
        try await drive.trash(root.filter { $0.id == folder || $0.id == loose })
        #expect(try await drive.list(drive.rootID).map(\.id) == [keep])
        #expect(FakeGoogleServer.state.permanentDeletes == 0 && !FakeGoogleServer.state.calls.contains { $0.hasPrefix("DELETE") })
        await #expect(throws: CloudError.notFound) { _ = try await drive.list(folder) }

        // Only what was trashed itself, as in Google Drive's Trash (not inside.txt).
        let trash = try await drive.listTrash()
        #expect(Set(trash.map(\.id)) == [folder, loose] && trash.allSatisfy { $0.parentID == "root" })
        #expect(trash.first { $0.id == folder }?.isFolder == true)

        try await drive.restore(trash.filter { $0.id == folder })
        #expect(try await drive.list(folder).map(\.id) == [inside])
        #expect(try await drive.listTrash().map(\.id) == [loose])

        try await drive.deleteForever(try await drive.listTrash())
        #expect(FakeGoogleServer.state.files[loose] == nil && FakeGoogleServer.state.permanentDeletes == 1)
        #expect(try await drive.listTrash().isEmpty)
        // A folder deleted for good takes its contents along; a repeat finds nothing and is fine.
        let f = try #require(try await drive.list(drive.rootID).first { $0.id == folder })
        try await drive.deleteForever([f])
        try await drive.deleteForever([f])
        #expect(FakeGoogleServer.state.files[inside] == nil && FakeGoogleServer.state.files[folder] == nil)
    }

    // MARK: Quota and thumbnails

    @Test func quotaComesFromAboutAndAnUnlimitedPlanHasNoTotal() async throws {
        var s = FakeGoogleServer.State()
        s.limit = 100_000_000_000
        s.usage = 40_000_000_000
        s.addUserFile("big.bin", data: Data(count: 4096))
        let (_, _, drive) = try await connect(s)
        let q = try #require(try await drive.quota())
        #expect(q.total == 100_000_000_000 && q.used == 40_000_000_000 && q.available == 60_000_000_000)
        #expect(q.categories.first { $0.key == "drive" }?.bytes == 4096)
        FakeGoogleServer.update { $0.limit = nil }
        let unlimited = try #require(try await drive.quota())
        #expect(unlimited.total == 0 && unlimited.used == 40_000_000_000)
    }

    @Test func thumbnailsComeFromGoogleAtTheAskedSizeAndOnlyFromGoogle() async throws {
        var s = FakeGoogleServer.State()
        let pic = DemoArt.jpeg(width: 300, height: 200, hue: 0.3, label: "P") ?? Data([0xFF, 0xD8])
        let jpg = s.addUserFile("Pic.jpg", data: pic)
        let pdf = s.addUserFile("Doc.pdf", data: Data("%PDF-1.4".utf8))
        s.addUserFile("Plain.txt", data: Data("t".utf8))
        let sheet = s.addUserDoc("Sheet", kind: "spreadsheet")
        let (_, _, drive) = try await connect(s)
        let root = try await drive.list(drive.rootID)
        func n(_ name: String) throws -> DriveNode { try #require(root.first { $0.name == name }) }

        #expect(try await drive.thumbnail(try n("Pic.jpg"), maxPixel: 256) == pic)
        #expect(FakeGoogleServer.state.calls.contains("GET lh3.googleusercontent.com/drive-storage/\(jpg)=s256"))
        let pdfThumb = try #require(try await drive.thumbnail(try n("Doc.pdf"), maxPixel: 128))
        #expect(pdfThumb.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try await drive.thumbnail(try n("Sheet.xlsx"), maxPixel: 64) != nil)
        let before = FakeGoogleServer.state.calls.count
        #expect(try await drive.thumbnail(try n("Plain.txt"), maxPixel: 256) == nil)      // Google has none: no request
        #expect(FakeGoogleServer.state.calls.count == before)
        #expect(FakeGoogleServer.state.thumbnailSizes == [256, 128, 64])

        // An expired link is renewed once; a link to anywhere but Google is never called with the sign-in.
        drive.rememberThumbnailLink(pdf, "https://lh3.googleusercontent.com/drive-storage/expired-link=s220")
        #expect(try await drive.thumbnail(try n("Doc.pdf"), maxPixel: 200) != nil)
        drive.rememberThumbnailLink(jpg, "https://downloads.example.net/thumb=s220")
        #expect(try await drive.thumbnail(try n("Pic.jpg"), maxPixel: 200) == nil)
        drive.rememberThumbnailLink(jpg, "http://lh3.googleusercontent.com/drive-storage/\(jpg)=s220")
        #expect(try await drive.thumbnail(try n("Pic.jpg"), maxPixel: 200) == nil)
        FakeGoogleServer.update { $0.redirectDownloadsTo = "downloads.example.net" }
        await #expect(throws: CloudError.self) { _ = try await drive.thumbnail(try n("Sheet.xlsx"), maxPixel: 64) }
        #expect(FakeGoogleServer.state.foreignRequests.isEmpty)
        _ = sheet

        #expect(GoogleDriveBackend.sizedThumbnail("https://lh3.googleusercontent.com/drive-storage/AbC-1=s220", maxPixel: 512)?.absoluteString
                == "https://lh3.googleusercontent.com/drive-storage/AbC-1=s512")
        #expect(GoogleDriveBackend.sizedThumbnail("https://docs.google.com/feeds/vt?gd=true&id=x&sz=s220", maxPixel: 96)?.absoluteString
                == "https://docs.google.com/feeds/vt?gd=true&id=x&sz=s96")
    }

    // MARK: Names

    @Test func oddNamesSurviveSearchQueriesAndURLs() async throws {
        var s = FakeGoogleServer.State()
        s.addUserDoc("Q3 'plan' #2")
        let (_, _, drive) = try await connect(s)
        let dir = Self.tempDir("names")
        let names = ["a b#c%d.txt", "it's \"quoted\".txt", #"back\slash\'mix.txt"#, "plus+and&amp=eq?.txt", "Ünïcødé ñ — 100%.txt", "' or name contains '.txt"]

        let folder = try await drive.createFolder("50% off #1 'sale' \\", in: drive.rootID)
        #expect(folder.name == "50% off #1 'sale' \\")
        for (i, name) in names.enumerated() {
            let u = try Self.write(Data("file \(i)".utf8), "f\(i).txt", in: dir)
            let up = try await drive.upload(u, name: name, into: folder.id, modified: nil) { _, _ in }
            #expect(up.name == name)
        }
        let listed = try await drive.list(folder.id)
        #expect(Set(listed.map(\.name)) == Set(names))
        for (i, name) in names.enumerated() {
            let hits = try await drive.items(named: name, in: folder.id)
            #expect(hits.count == 1 && hits.first?.name == name, "\(name)")
            let out = dir.appendingPathComponent("out-\(i)")
            try await drive.download(try #require(hits.first), to: out) { _, _ in }
            #expect(try Data(contentsOf: out) == Data("file \(i)".utf8))
        }
        #expect(try await drive.items(named: "a b#c%d", in: folder.id).isEmpty)
        #expect(try await drive.items(named: "Q3 'plan' #2.docx", in: drive.rootID).map(\.name) == ["Q3 'plan' #2.docx"])
        #expect(try await drive.items(named: "it's \"quoted\".txt", in: drive.rootID).isEmpty)
        let r = try await drive.rename(try #require(listed.first { $0.name == names[0] }), to: "new 'name' \\ #%.txt")
        #expect(try await drive.items(named: "new 'name' \\ #%.txt", in: folder.id).map(\.id) == [r.id])
        // A query the fake can't parse is refused, as at Google: escaping mistakes can't hide.
        let bad = try drive.api.request("GET", GoogleDrive.base + "/files", query: ["q": "name = 'it's' and trashed = false", "fields": "files(id)"])
        await #expect(throws: GoogleError.self) { _ = try await drive.api.send(bad, idempotent: true) }
    }

    // MARK: Cancellation and demo

    @Test func cancellingStopsWork() async throws {
        let (_, _, drive) = try await connect()
        _ = try await drive.list(drive.rootID)
        FakeGoogleServer.update { $0.latency = 1.5 }
        defer { FakeGoogleServer.update { $0.latency = 0 } }
        let t = Task { try await drive.list(drive.rootID) }
        try await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        let started = Date()
        do { _ = try await t.value; Issue.record("expected cancellation") } catch {
            #expect(error is CancellationError || (error as? CloudError) == .cancelled)
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func demoAccountHasItsOwnSeededDrive() async throws {
        let (record, backend) = try #require(GoogleDriveCloud.demo(storage: nil, latency: 0))
        #expect(record.id == "cloud:googleDrive:demo" && record.provider == .googleDrive && record.title == "alex@example.com")
        #expect(backend.provider == .googleDrive && backend.canListTrash)
        // Tests (and the migration demo) resetting FakeGoogleServer don't touch it.
        FakeGoogleServer.reset()
        let root = try await backend.list(backend.rootID)
        #expect(Set(root.map(\.name)) == ["Documents", "Photos", "Projects", "Welcome.txt", "Team survey"])
        let docs = try await backend.list(try #require(root.first { $0.name == "Documents" }).id)
        #expect(Set(docs.map(\.name)) == ["Budget 2026.xlsx", "Quarterly report.pdf"])
        let photos = try await backend.list(try #require(root.first { $0.name == "Photos" }).id)
        #expect(photos.count == 3 && photos.allSatisfy { $0.name.hasSuffix(".jpg") && $0.size > 10_000 })
        #expect(try await backend.thumbnail(photos[0], maxPixel: 128) != nil)
        let projects = try await backend.list(try #require(root.first { $0.name == "Projects" }).id)
        #expect(Set(projects.map(\.name)) == ["Website refresh", "Project plan.docx", "Budget 2026.xlsx"])
        #expect(try await backend.listTrash().map(\.name) == ["Old draft.txt"])
        let all = try await backend.walk(backend.rootID)
        #expect(all.contains { $0.path == "Projects/Website refresh/Photos/Harbor at dawn.jpg" })
        let q = try #require(try await backend.quota())
        #expect(q.total == 15_000_000_000 && q.used == 3_400_000_000)
        #expect(FakeGoogleServer.state.files.isEmpty)
        #expect(GoogleDriveCloud.demo(storage: nil)?.record == record)
    }
}
}

final class SecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: CloudSecret?
    var value: CloudSecret? { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int64, Int64)] = []
    func add(_ a: Int64, _ b: Int64) { lock.withLock { calls.append((a, b)) } }
    var count: Int { lock.withLock { calls.count } }
    var last: (Int64, Int64) { lock.withLock { calls.last ?? (0, 0) } }
}
