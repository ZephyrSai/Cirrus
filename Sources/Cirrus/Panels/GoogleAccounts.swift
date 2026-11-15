import AppKit
import CirrusCore

/// Connected Google accounts. Client ID/secret, the account list and refresh tokens live in the
/// login keychain (this Mac only); refresh tokens are released through Touch ID like saved passwords.
/// Debug builds in demo mode (CIRRUS_DEMO=1) talk to a built-in fake Google instead.
@MainActor
final class GoogleAccounts {
    static let shared = GoogleAccounts()
    static let changed = Notification.Name("CirrusGoogleAccountsChanged")

    let store: GoogleCredentialStore
    let gate: GoogleTokenGate
    let transport: [AnyClass]?
    let isDemo: Bool
    private var apis = [String: GoogleAPI]()

    private init() {
        #if DEBUG
        if AccountManager.shared.demoMode {
            FakeGoogleServer.startDemo(storage: Paths.cacheDir("demo").appendingPathComponent("google", isDirectory: true))
            let st = FakeGoogleServer.state
            store = MemoryGoogleStore(client: GoogleOAuthClient(clientID: st.clientID, clientSecret: st.clientSecret))
            transport = [FakeGoogleServer.self]
            gate = GoogleTokenGate(store: store, requireAuth: { false })
            isDemo = true
            return
        }
        #endif
        store = KeychainGoogleStore()
        transport = nil
        gate = GoogleTokenGate(store: store)
        isDemo = false
    }

    var client: GoogleOAuthClient? { store.client() }
    var isConfigured: Bool { client?.looksValid ?? false }
    var accounts: [GoogleAccountInfo] { store.accounts().sorted { $0.connected < $1.connected } }

    func setClient(_ c: GoogleOAuthClient?) {
        store.setClient(c)
        apis = [:]
        post()
    }

    func post() { NotificationCenter.default.post(name: Self.changed, object: self) }

    /// Opens Google's consent page in the default browser and waits for the answer.
    /// What “Google → iCloud” asks for (one consent screen: Google doesn't add scopes to a desktop app's grant later).
    static let importScopes = GoogleScopes.all + [GoogleScopes.driveReadonly, GoogleScopes.photosPicker]

    func connect(scopes: [String] = GoogleScopes.all, loginHint: String? = nil) async throws -> GoogleAccountInfo {
        guard let c = client, c.looksValid else { throw GoogleError.notConfigured }
        let oauth = GoogleOAuth(client: c, transport: transport)
        let demo = isDemo
        let tokens = try await oauth.authorize(scopes: scopes, loginHint: loginHint) { url in
            #if DEBUG
            if demo { await FakeGoogleServer.approve(url); return }
            #endif
            _ = demo
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        guard let refresh = tokens.refreshToken else {
            throw GoogleError.badResponse("Google didn’t give Cirrus lasting access. Remove Cirrus under myaccount.google.com › Security › Your connections to third-party apps, then connect again.")
        }
        let probe = GoogleAPI(accountID: "new", oauth: oauth, scopes: tokens.scopes, transport: transport, initialTokens: tokens, refreshToken: { refresh })
        var info: GoogleAccountInfo
        if tokens.has(GoogleScopes.driveFile) || tokens.has(GoogleScopes.driveReadonly) {
            let (user, _) = try await GoogleDrive(api: probe).about()
            info = GoogleAccountInfo(id: user.id.isEmpty ? "google-" + PKCE.random(9) : user.id, email: user.email, name: user.name, scopes: tokens.scopes)
        } else {
            info = GoogleAccountInfo(id: "google-" + PKCE.random(9), email: "", name: "Google Photos only", scopes: tokens.scopes)
        }
        // Reconnecting replaces the saved token. The old one isn't revoked: revoking ends the whole grant,
        // which would cut off the new token too. Google retires unused tokens on its own.
        store.save(info, refreshToken: refresh)
        await gate.remember(info.id, refresh)
        apis[info.id] = nil
        post()
        return info
    }

    /// API client for a connected account; the first call in a run asks for Touch ID.
    func api(for id: String) throws -> GoogleAPI {
        if let a = apis[id] { return a }
        guard let c = client, c.looksValid else { throw GoogleError.notConfigured }
        guard let info = accounts.first(where: { $0.id == id }) else { throw GoogleError.reconnect("Connect your Google account again.") }
        let gate = self.gate
        let label = info.email.isEmpty ? "your Google account" : info.email
        let a = GoogleAPI(accountID: id, oauth: GoogleOAuth(client: c, transport: transport), scopes: info.scopes, transport: transport) {
            guard let t = await gate.refreshToken(for: id, reason: "use the saved Google access for \(label)") else {
                throw GoogleError.reconnect("Cirrus needs Touch ID or your password to use the saved Google access. Try again, or connect Google again.")
            }
            return t
        }
        let store = self.store
        a.onNewRefreshToken = { t in store.save(info, refreshToken: t) }
        apis[id] = a
        return a
    }

    /// Revokes Cirrus's access at Google and forgets the account (nothing in Google is removed).
    func disconnect(_ id: String) async {
        if let c = client, let t = store.refreshToken(id) { await GoogleOAuth(client: c, transport: transport).revoke(t) }
        store.remove(id)
        await gate.forget(id)
        apis[id] = nil
        post()
    }
}
