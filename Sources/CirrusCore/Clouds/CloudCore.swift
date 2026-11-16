import Foundation

// Other cloud services beside iCloud. Each one is a `CloudDriveBackend`: the same `DriveBackend` that iCloud
// Drive uses (so browsing, the transfer queue, drag and drop, sync and copy between services all work as they do
// for iCloud), plus a few optional extras. iCloud stays the main account; these are added from "Add Account…".

/// The services Cirrus can connect to beside iCloud.
public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case nextcloud, webdav, onedrive, googleDrive

    public var displayName: String {
        switch self {
        case .nextcloud: return "Nextcloud"
        case .webdav: return "WebDAV"
        case .onedrive: return "OneDrive"
        case .googleDrive: return "Google Drive"
        }
    }

    /// SF Symbol for the sidebar and path bar (no brand artwork).
    public var symbol: String {
        switch self {
        case .nextcloud: return "cloud.circle"
        case .webdav: return "server.rack"
        case .onedrive: return "cloud"
        case .googleDrive: return "triangle"
        }
    }

    /// What the service calls the place deleted items go.
    public var deletedTitle: String {
        switch self {
        case .nextcloud: return "Deleted Files"
        case .webdav: return "Deleted Items"
        case .onedrive: return "Recycle Bin"
        case .googleDrive: return "Trash"
        }
    }
}

/// One connected account (no secrets: those live in the Keychain as a `CloudSecret`).
public struct CloudAccountRecord: Codable, Hashable, Sendable {
    public var id: String                 // "cloud:<provider>:<uuid>"
    public var provider: CloudProvider
    /// Shown in the sidebar: the email or user name, plus the server for self-hosted ones.
    public var title: String
    /// Nextcloud: the server's base URL (https://cloud.example.com). WebDAV: the full WebDAV folder URL.
    public var server: String?
    /// Nextcloud / WebDAV login name.
    public var username: String?
    public var added: Date

    public init(id: String = "", provider: CloudProvider, title: String, server: String? = nil, username: String? = nil, added: Date = Date()) {
        self.id = id.isEmpty ? Self.newID(provider) : id
        self.provider = provider; self.title = title; self.server = server; self.username = username; self.added = added
    }

    public static func newID(_ p: CloudProvider) -> String { "cloud:" + p.rawValue + ":" + UUID().uuidString.lowercased() }
}

/// What a cloud account needs to sign back in. Kept only in the Keychain.
public struct CloudSecret: Codable, Sendable, Equatable {
    /// Nextcloud / WebDAV: an app password (Nextcloud's browser login creates one; WebDAV: what the user typed).
    public var password: String?
    /// OAuth services (OneDrive, Google Drive).
    public var refreshToken: String?
    /// The OAuth client the account signed in with (Google: the user's own client; OneDrive: Cirrus's or the user's).
    public var clientID: String?
    public var clientSecret: String?

    public init(password: String? = nil, refreshToken: String? = nil, clientID: String? = nil, clientSecret: String? = nil) {
        self.password = password; self.refreshToken = refreshToken; self.clientID = clientID; self.clientSecret = clientSecret
    }
}

/// Saved cloud accounts: records in preferences, secrets in the Keychain.
public enum CloudStore {
    static let defaultsKey = "cloudAccounts"
    public static let keychainService = "Cirrus Cloud Account"
    /// Demo mode and tests: keep accounts in memory only (never the Keychain or preferences).
    nonisolated(unsafe) public static var inMemory = false
    nonisolated(unsafe) static var memRecords = [CloudAccountRecord]()
    nonisolated(unsafe) static var memSecrets = [String: CloudSecret]()

    public static func records() -> [CloudAccountRecord] {
        if inMemory { return memRecords }
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CloudAccountRecord].self, from: d)) ?? []
    }

    static func write(_ list: [CloudAccountRecord]) {
        if inMemory { memRecords = list; return }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }

    public static func save(_ r: CloudAccountRecord, secret: CloudSecret) {
        setSecret(r.id, secret)
        var list = records().filter { $0.id != r.id }
        list.append(r)
        write(list)
    }

    public static func update(_ r: CloudAccountRecord) {
        write(records().map { $0.id == r.id ? r : $0 })
    }

    public static func secret(_ id: String) -> CloudSecret? {
        if inMemory { return memSecrets[id] }
        guard let d = Keychain.get(service: keychainService, account: id) else { return nil }
        return try? JSONDecoder().decode(CloudSecret.self, from: d)
    }

    public static func setSecret(_ id: String, _ s: CloudSecret) {
        if inMemory { memSecrets[id] = s; return }
        if let d = try? JSONEncoder().encode(s) { Keychain.set(d, service: keychainService, account: id) }
    }

    public static func remove(_ id: String) {
        if inMemory { memSecrets[id] = nil; write(records().filter { $0.id != id }); return }
        Keychain.delete(service: keychainService, account: id)
        write(records().filter { $0.id != id })
    }
}

public enum CloudError: Error, LocalizedError, Equatable {
    /// The saved sign-in no longer works (token revoked, app password deleted…). Associated: service name.
    case signInNeeded(String)
    /// The service refused (permissions, locked file…). Associated: a sentence for the user.
    case denied(String)
    case server(String)
    case notFound
    case quotaExceeded(String)
    case unsupported(String)
    case notConfigured(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .signInNeeded(let s): return "\(s) needs you to sign in again."
        case .denied(let m), .server(let m), .unsupported(let m), .notConfigured(let m): return m
        case .notFound: return "The item no longer exists on the server."
        case .quotaExceeded(let s): return "There isn’t enough space in \(s)."
        case .cancelled: return "Cancelled."
        }
    }
}

/// A connected cloud's files, as Cirrus browses them. Rules every implementation follows:
/// - folders have `type == "FOLDER"`, files `"FILE"`; sizes in bytes, dates as the server reports them;
/// - children of the top folder have `parentID == rootID` (normalize server aliases such as "root");
/// - `trash` never deletes permanently: it uses the service's own trash / recycle bin, or (plain WebDAV
///   servers without one) a "Deleted by Cirrus" folder; only `deleteForever` deletes for good;
/// - safe to call from any thread and from many tasks at once;
/// - errors are `CloudError` (or `CancellationError`), with sentences a user can act on.
public protocol CloudDriveBackend: DriveBackend {
    var provider: CloudProvider { get }
    /// Can deleted items be listed (and restored) from Cirrus? OneDrive's recycle bin, for one, can't be listed.
    var canListTrash: Bool { get }
    /// Space used and available, if the service tells.
    func quota() async throws -> StorageUsage?
    /// A server-made thumbnail (JPEG/PNG bytes), or nil when the service has none for this file.
    func thumbnail(_ node: DriveNode, maxPixel: Int) async throws -> Data?
}

/// OAuth backends whose refresh token can change (Microsoft rotates them): the app stores each new one.
public protocol CloudTokenRotating: AnyObject {
    var onNewRefreshToken: (@Sendable (String) -> Void)? { get set }
}

extension OneDriveBackend: CloudTokenRotating {}

/// Builds the backend for a saved account. `transport` swaps in URLProtocol fakes (tests, demo mode).
public enum CloudBackends {
    nonisolated(unsafe) public static var transport: [AnyClass]? = nil

    public static func make(_ r: CloudAccountRecord, secret: CloudSecret) throws -> CloudDriveBackend {
        switch r.provider {
        case .nextcloud, .webdav: return try WebDAV.make(record: r, secret: secret, transport: transport)
        case .onedrive: return try OneDrive.make(record: r, secret: secret, transport: transport)
        case .googleDrive: return try GoogleDriveCloud.make(record: r, secret: secret, transport: transport)
        }
    }

    #if DEBUG
    /// Demo-mode accounts (CIRRUS_DEMO=1), each backed by its fake server. Nil while a service has no demo.
    public static func demo(_ p: CloudProvider) -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        switch p {
        case .nextcloud, .webdav: return WebDAV.demo(p)
        case .onedrive: return OneDrive.demo()
        case .googleDrive: return GoogleDriveCloud.demo()
        }
    }
    #endif
}
