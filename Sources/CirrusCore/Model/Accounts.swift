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

/// One place Cirrus reads iCloud from: the Mac's own iCloud (native folders + PhotoKit),
/// an Apple ID signed in inside Cirrus (web services), or the built-in demo.
public final class Account: Hashable, @unchecked Sendable {
    public enum Kind: String, Sendable { case mac, web, demo }
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

    init(id: String, kind: Kind, title: String) { self.id = id; self.kind = kind; self.title = title }

    public static func == (a: Account, b: Account) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var hasDrive: Bool { drive != nil || driveRoot != nil }

    public func storageUsage() async -> StorageUsage? {
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

    /// Is this Mac signed in to iCloud with iCloud Drive on?
    public static var nativeDriveRoot: URL? {
        if let o = ProcessInfo.processInfo.environment["CIRRUS_NATIVE_DRIVE"] { return URL(fileURLWithPath: o, isDirectory: true) }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
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
        accounts = list
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
        if let name = state.accountInfo["dsInfo"]["fullName"].string, !name.isEmpty { a.title = name }
        if state.cookies.isEmpty { a.status = .needsSignIn }
        let id = appleID.lowercased()
        Task {
            await session.setPasswordProvider { Keychain.get(service: Keychain.passwordService, account: id).flatMap { String(data: $0, encoding: .utf8) } }
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
        Keychain.delete(service: Keychain.sessionService, account: id)
        Keychain.delete(service: Keychain.passwordService, account: id)
        var ids = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        ids.removeAll { $0 == id }
        UserDefaults.standard.set(ids, forKey: defaultsKey)
        accounts.removeAll { $0 == account }
        try? FileManager.default.removeItem(at: Paths.cacheDir("listings").appendingPathComponent(account.id.replacingOccurrences(of: ":", with: "_")))
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func account(id: String) -> Account? { accounts.first { $0.id == id } }
}
