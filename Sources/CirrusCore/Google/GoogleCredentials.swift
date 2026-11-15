import Foundation

/// A connected Google account (no secrets). `id` is Google's stable permission ID for the user.
public struct GoogleAccountInfo: Codable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var scopes: [String]
    public var connected: Date

    public init(id: String, email: String, name: String, scopes: [String], connected: Date = Date()) {
        self.id = id; self.email = email; self.name = name; self.scopes = scopes; self.connected = connected
    }

    public func has(_ scope: String) -> Bool { scopes.contains(scope) }
    public var label: String {
        if email.isEmpty { return name.isEmpty ? "Google account" : name }
        return name.isEmpty || name == email ? email : "\(name) (\(email))"
    }
}

/// Where the OAuth client, account list and refresh tokens live.
public protocol GoogleCredentialStore: AnyObject, Sendable {
    func client() -> GoogleOAuthClient?
    func setClient(_ c: GoogleOAuthClient?)
    func accounts() -> [GoogleAccountInfo]
    func save(_ account: GoogleAccountInfo, refreshToken: String)
    /// Raw read; callers go through `GoogleTokenGate` so Touch ID guards it.
    func refreshToken(_ id: String) -> String?
    func remove(_ id: String)
}

/// Login keychain, this Mac only (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, not synced).
public final class KeychainGoogleStore: GoogleCredentialStore, @unchecked Sendable {
    static let clientService = "Cirrus Google OAuth Client"
    static let accountsService = "Cirrus Google Accounts"
    static let tokenService = "Cirrus Google Refresh Token"
    private let lock = NSLock()

    public init() {}

    public func client() -> GoogleOAuthClient? {
        Keychain.get(service: Self.clientService, account: "default").flatMap { try? JSONDecoder().decode(GoogleOAuthClient.self, from: $0) }
    }

    public func setClient(_ c: GoogleOAuthClient?) {
        if let c, let d = try? JSONEncoder().encode(c) { Keychain.set(d, service: Self.clientService, account: "default") }
        else { Keychain.delete(service: Self.clientService, account: "default") }
    }

    public func accounts() -> [GoogleAccountInfo] {
        lock.withLock { Keychain.get(service: Self.accountsService, account: "index").flatMap { try? JSONDecoder().decode([GoogleAccountInfo].self, from: $0) } ?? [] }
    }

    func writeAccounts(_ list: [GoogleAccountInfo]) {
        if let d = try? JSONEncoder().encode(list) { Keychain.set(d, service: Self.accountsService, account: "index") }
    }

    public func save(_ account: GoogleAccountInfo, refreshToken: String) {
        Keychain.set(Data(refreshToken.utf8), service: Self.tokenService, account: account.id)
        lock.withLock {
            var list = Keychain.get(service: Self.accountsService, account: "index").flatMap { try? JSONDecoder().decode([GoogleAccountInfo].self, from: $0) } ?? []
            list.removeAll { $0.id == account.id }
            list.append(account)
            writeAccounts(list)
        }
    }

    public func refreshToken(_ id: String) -> String? {
        Keychain.get(service: Self.tokenService, account: id).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func remove(_ id: String) {
        Keychain.delete(service: Self.tokenService, account: id)
        lock.withLock {
            var list = Keychain.get(service: Self.accountsService, account: "index").flatMap { try? JSONDecoder().decode([GoogleAccountInfo].self, from: $0) } ?? []
            list.removeAll { $0.id == id }
            writeAccounts(list)
        }
    }
}

/// In-memory store for tests and the demo (nothing reaches the Keychain).
public final class MemoryGoogleStore: GoogleCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _client: GoogleOAuthClient?
    private var list = [GoogleAccountInfo]()
    private var tokens = [String: String]()

    public init(client: GoogleOAuthClient? = nil) { _client = client }
    public func client() -> GoogleOAuthClient? { lock.withLock { _client } }
    public func setClient(_ c: GoogleOAuthClient?) { lock.withLock { _client = c } }
    public func accounts() -> [GoogleAccountInfo] { lock.withLock { list } }
    public func save(_ account: GoogleAccountInfo, refreshToken: String) {
        lock.withLock { list.removeAll { $0.id == account.id }; list.append(account); tokens[account.id] = refreshToken }
    }
    public func refreshToken(_ id: String) -> String? { lock.withLock { tokens[id] } }
    public func remove(_ id: String) { lock.withLock { list.removeAll { $0.id == id }; tokens[id] = nil } }
}

/// Refresh tokens are released only after Touch ID / Apple Watch / the login password — the same
/// rule (and the same Settings switch) as saved Apple ID passwords. Unlocked tokens stay in memory for this run.
public actor GoogleTokenGate {
    let store: GoogleCredentialStore
    let requireAuth: @Sendable () -> Bool
    let authenticate: @Sendable (String) async -> Bool
    private var unlocked = [String: String]()

    /// Defaults: the Settings switch shared with saved passwords, and LocalAuthentication.
    public init(store: GoogleCredentialStore, requireAuth: (@Sendable () -> Bool)? = nil, authenticate: (@Sendable (String) async -> Bool)? = nil) {
        self.store = store
        self.requireAuth = requireAuth ?? { CredentialGate.requireAuth }
        self.authenticate = authenticate ?? { await CredentialGate.authenticate(reason: $0) }
    }

    public func refreshToken(for id: String, reason: String) async -> String? {
        if let t = unlocked[id] { return t }
        guard let t = store.refreshToken(id) else { return nil }
        if requireAuth() { guard await authenticate(reason) else { return nil } }
        unlocked[id] = t
        return t
    }

    /// A token the user just granted doesn't need another Touch ID prompt in this run.
    public func remember(_ id: String, _ token: String) { unlocked[id] = token }
    public func forget(_ id: String) { unlocked[id] = nil }
}
