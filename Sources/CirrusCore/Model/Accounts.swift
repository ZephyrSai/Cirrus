import Foundation

extension ICloudSession {
    /// iCloud storage plan usage, broken down by category (Photos, Backups, Documents, Mail…).
    public func storageUsage() async throws -> StorageUsage {
        let j = try await request(endpoints.setup + "/storageUsageInfo", query: setupParams())
        let info = j["storageUsageInfo"]
        let cats = j["storageUsageByMedia"].array.map {
            StorageUsage.Category(key: $0["mediaKey"].string ?? "", label: $0["displayLabel"].string ?? ($0["mediaKey"].string ?? ""),
                                  bytes: $0["usageInBytes"].int64 ?? 0, color: $0["displayColor"].string)
        }
        return StorageUsage(total: info["totalStorageInBytes"].int64 ?? 0, used: info["usedStorageInBytes"].int64 ?? 0, categories: cats)
    }
}

/// One place Cirrus reads from: the Mac's own iCloud (native folders + PhotoKit), an Apple ID signed in
/// inside Cirrus (web services), the built-in demo, or another cloud service (OneDrive, Nextcloud…).
public final class Account: Hashable, @unchecked Sendable {
    public enum Kind: String, Sendable { case mac, web, demo, cloud }
    public enum Status: Equatable, Sendable { case ready, needsSignIn, waitingForApproval(String), error(String) }

    public let id: String
    public let kind: Kind
    public var appleID: String?
    public var title: String
    /// Native iCloud Drive root (Mac account): ~/Library/Mobile Documents/com~apple~CloudDocs.
    public var driveRoot: URL?
    public var drive: DriveBackend?
    public var photos: PhotosBackend?
    public var session: ICloudSession?
    public var status: Status = .ready
    /// Another cloud service (kind == .cloud).
    public var cloud: CloudAccountRecord?
    public var provider: CloudProvider? { cloud?.provider }
    public var isICloud: Bool { kind != .cloud }
    /// What the top folder of `drive` is called: "iCloud Drive", "OneDrive", "Nextcloud"…
    public var driveTitle: String { cloud?.provider.displayName ?? "iCloud Drive" }
    /// Where deleted items go.
    public var deletedTitle: String { cloud?.provider.deletedTitle ?? "Recently Deleted" }
    /// Can deleted items be listed and restored in Cirrus?
    public var canListTrash: Bool { (drive as? CloudDriveBackend)?.canListTrash ?? (drive != nil) }

    init(id: String, kind: Kind, title: String) { self.id = id; self.kind = kind; self.title = title }

    public static func == (a: Account, b: Account) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var hasDrive: Bool { drive != nil || driveRoot != nil }

    public func storageUsage() async -> StorageUsage? {
        if let c = drive as? CloudDriveBackend { return try? await c.quota() }
        guard let session else { return nil }
        return try? await session.storageUsage()
    }
}

@MainActor
public final class AccountManager {
    public static let shared = AccountManager()
    public static let changed = Notification.Name("CirrusAccountsChanged")
    public private(set) var accounts: [Account] = []
    let defaultsKey = "webAccounts"
    public var demoMode = ProcessInfo.processInfo.environment["CIRRUS_DEMO"] != nil

    public var macAccount: Account? { accounts.first { $0.kind == .mac } }
    public var webAccounts: [Account] { accounts.filter { $0.kind == .web } }
    public var cloudAccounts: [Account] { accounts.filter { $0.kind == .cloud } }

    /// Is this Mac signed in to iCloud with iCloud Drive on?
    public static var nativeDriveRoot: URL? {
        if let o = ProcessInfo.processInfo.environment["CIRRUS_NATIVE_DRIVE"] { return URL(fileURLWithPath: o, isDirectory: true) }
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        #else
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        #endif
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    public static var macSignedInToICloud: Bool { nativeDriveRoot != nil || FileManager.default.ubiquityIdentityToken != nil }

    public func load() {
        var list = [Account]()
        let mac = Account(id: "mac", kind: .mac, title: Self.macSignedInToICloud ? "iCloud (This Mac)" : "This Mac")
        mac.driveRoot = Self.nativeDriveRoot
        if ProcessInfo.processInfo.environment["CIRRUS_NO_PHOTOKIT"] == nil { mac.photos = NativePhotos() }
        list.append(mac)
        for appleID in UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] {
            list.append(makeWebAccount(appleID: appleID, state: loadState(appleID)))
        }
        if demoMode {
            let demo = Account(id: "demo", kind: .demo, title: "Demo iCloud")
            demo.appleID = "demo@example.com"
            demo.drive = DemoDrive.shared
            demo.photos = DemoPhotos.shared
            list.append(demo)
        }
        #if DEBUG
        if demoMode {
            CloudStore.inMemory = true
            // Accounts added from the sheet in demo mode talk to the fake servers too.
            CloudBackends.transport = [FakeGoogleServer.self]
        }
        #endif
        for r in CloudStore.records() { list.append(makeCloudAccount(r, secret: CloudStore.secret(r.id))) }
        #if DEBUG
        if demoMode && ProcessInfo.processInfo.environment["CIRRUS_NO_DEMO_CLOUDS"] == nil {
            for p in [CloudProvider.onedrive, .googleDrive, .nextcloud, .webdav] {
                guard let (r, backend) = CloudBackends.demo(p) else { continue }
                let a = Account(id: r.id, kind: .cloud, title: r.title)
                a.cloud = r
                a.drive = backend
                list.append(a)
            }
        }
        #endif
        accounts = list
        ThumbnailDiskCache.pruneOldVersions(keeping: list.compactMap { $0.photos?.cacheKey })
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func loadState(_ appleID: String) -> SessionState {
        if let d = Keychain.get(service: Keychain.sessionService, account: appleID.lowercased()),
           let s = try? JSONDecoder().decode(SessionState.self, from: d) { return s }
        return SessionState(appleID: appleID)
    }

    func makeWebAccount(appleID: String, state: SessionState) -> Account {
        let a = Account(id: "web:" + appleID.lowercased(), kind: .web, title: appleID)
        a.appleID = appleID.lowercased()
        let session = ICloudSession(state: state)
        a.session = session
        a.drive = WebDrive(session: session)
        a.photos = WebPhotos(session: session, appleID: appleID)
        if let name = state.accountInfo["dsInfo"]["fullName"].string?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !name.isEmpty { a.title = name }
        if state.cookies.isEmpty { a.status = .needsSignIn }
        let id = appleID.lowercased()
        Task {
            await session.setPasswordProvider {
                await CredentialGate.shared.password(for: id, reason: "sign back in to iCloud as \(id) with your saved password")
            }
            await session.setEventHandler { [weak a] event in
                DispatchQueue.main.async {
                    guard let a else { return }
                    switch event {
                    case .needsSignIn: a.status = .needsSignIn
                    case .waitingForApproval(let app): a.status = .waitingForApproval(app)
                    case .approvalFinished, .stateChanged: if case .waitingForApproval = a.status { a.status = .ready }
                    }
                    NotificationCenter.default.post(name: AccountManager.changed, object: a)
                }
            }
        }
        return a
    }

    /// A fresh session for the sign-in sheet (not yet listed as an account).
    public func pendingSession(appleID: String) -> ICloudSession {
        var state = loadState(appleID)
        state.cookies = []
        return ICloudSession(state: state)
    }

    /// Called by the sign-in sheet once Apple accepted the login.
    public func finishSignIn(appleID: String, session: ICloudSession, rememberPassword: String?) async {
        let id = appleID.lowercased()
        Self.rememberAppleID(id)
        if let pw = rememberPassword { Keychain.set(Data(pw.utf8), service: Keychain.passwordService, account: id) }
        else { Keychain.delete(service: Keychain.passwordService, account: id) }
        let state = await session.state
        if let data = try? JSONEncoder().encode(state) { Keychain.set(data, service: Keychain.sessionService, account: id) }
        var ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if !ids.contains(id) { ids.append(id); UserDefaults.standard.set(ids, forKey: defaultsKey) }
        accounts.removeAll { $0.id == "web:" + id }
        let account = makeWebAccount(appleID: id, state: state)
        account.status = .ready
        if let i = accounts.firstIndex(where: { $0.kind == .demo }) { accounts.insert(account, at: i) } else { accounts.append(account) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func signOut(_ account: Account) {
        guard account.kind == .web, let id = account.appleID else { return }
        // Stop the live session, so work still running can't sign in again and store it back. A
        // re-authentication that finished just before may already have stored it: remove it again after.
        if let s = account.session {
            let accountID = account.id
            Task { @MainActor in
                await s.signOut()
                if AccountManager.shared.account(id: accountID) == nil { Keychain.delete(service: Keychain.sessionService, account: id) }
            }
        }
        Keychain.delete(service: Keychain.sessionService, account: id)
        Keychain.delete(service: Keychain.passwordService, account: id)
        Task { await CredentialGate.shared.forget(id) }
        var ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        ids.removeAll { $0 == id }
        UserDefaults.standard.set(ids, forKey: defaultsKey)
        accounts.removeAll { $0 == account }
        // Forget everything cached for this account: listings, thumbnails, opened/preview copies.
        try? FileManager.default.removeItem(at: Paths.cacheDir("listings").appendingPathComponent(account.id.replacingOccurrences(of: ":", with: "_")))
        if let photos = account.photos { try? FileManager.default.removeItem(at: ThumbnailDiskCache.accountDir(photos.cacheKey)) }
        let mine = Paths.accountCacheName(account.id)
        try? FileManager.default.removeItem(at: Paths.caches.appendingPathComponent("Preview").appendingPathComponent(mine))
        let opened = Paths.caches.appendingPathComponent("Open").appendingPathComponent(mine)
        for u in (try? FileManager.default.contentsOfDirectory(at: opened, includingPropertiesForKeys: nil)) ?? [] { Paths.retireOpenCopy(u) }
        if ((try? FileManager.default.contentsOfDirectory(atPath: opened.path)) ?? []).isEmpty { try? FileManager.default.removeItem(at: opened) }
        var known = Self.knownAppleIDs; known.removeAll { $0 == id }; UserDefaults.standard.set(known, forKey: "knownAppleIDs")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func account(id: String) -> Account? { accounts.first { $0.id == id } }

    // MARK: Other clouds

    func makeCloudAccount(_ r: CloudAccountRecord, secret: CloudSecret?) -> Account {
        let a = Account(id: r.id, kind: .cloud, title: r.title)
        a.cloud = r
        guard let secret else { a.status = .needsSignIn; return a }
        do {
            let backend = try CloudBackends.make(r, secret: secret)
            // OAuth services hand out new refresh tokens now and then: keep the newest in the Keychain.
            if let rot = backend as? CloudTokenRotating {
                let id = r.id
                rot.onNewRefreshToken = { token in
                    guard var s = CloudStore.secret(id) else { return }
                    s.refreshToken = token
                    CloudStore.setSecret(id, s)
                }
            }
            a.drive = backend
        } catch let e as CloudError {
            if case .signInNeeded = e { a.status = .needsSignIn } else { a.status = .error(e.localizedDescription) }
        } catch {
            a.status = .error(error.localizedDescription)
        }
        return a
    }

    /// A newly connected cloud account (from the Add Account sheet). Replaces one with the same id.
    @discardableResult
    public func addCloud(_ r: CloudAccountRecord, secret: CloudSecret) -> Account {
        CloudStore.save(r, secret: secret)
        let a = makeCloudAccount(r, secret: secret)
        if let i = accounts.firstIndex(where: { $0.id == r.id }) { accounts[i] = a } else { accounts.append(a) }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return a
    }

    /// The same service and login already connected (so a second sign-in updates it instead of adding a twin).
    public func existingCloud(matching r: CloudAccountRecord) -> CloudAccountRecord? {
        CloudStore.records().first {
            $0.provider == r.provider && $0.title.caseInsensitiveCompare(r.title) == .orderedSame && ($0.server ?? "") == (r.server ?? "")
        }
    }

    /// Forget a cloud account: its sign-in and everything Cirrus cached for it. Nothing changes on the service.
    public func removeCloud(_ account: Account) {
        guard account.kind == .cloud else { return }
        CloudStore.remove(account.id)
        accounts.removeAll { $0 == account }
        try? FileManager.default.removeItem(at: Paths.cacheDir("listings").appendingPathComponent(account.id.replacingOccurrences(of: ":", with: "_")))
        let mine = Paths.accountCacheName(account.id)
        try? FileManager.default.removeItem(at: Paths.caches.appendingPathComponent("Preview").appendingPathComponent(mine))
        let opened = Paths.caches.appendingPathComponent("Open").appendingPathComponent(mine)
        for u in (try? FileManager.default.contentsOfDirectory(at: opened, includingPropertiesForKeys: nil)) ?? [] { Paths.retireOpenCopy(u) }
        if ((try? FileManager.default.contentsOfDirectory(atPath: opened.path)) ?? []).isEmpty { try? FileManager.default.removeItem(at: opened) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Apple IDs used on this Mac (most recent first) for the sign-in suggestions.
    public static var knownAppleIDs: [String] { UserDefaults.standard.stringArray(forKey: "knownAppleIDs") ?? [] }
    static func rememberAppleID(_ id: String) {
        var list = knownAppleIDs.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "knownAppleIDs")
    }
}
