import Foundation

/// Google Drive as a browsable account beside iCloud. Each user signs in with their own OAuth client
/// ("Desktop app" client in their Google Cloud project, the same one the iCloud ⇄ Google move uses) and grants
/// the full `drive` scope; Cirrus ships no client, so it needs no restricted-scope review from Google.
public enum GoogleDriveCloud {
    /// What a Google Drive account asks for on Google's consent page.
    public static let scopes = [GoogleScopes.drive]
    static let serviceName = CloudProvider.googleDrive.displayName
    static let notConfiguredMessage = "Google Drive needs the client ID from your own Google Cloud project. Set up Google access, then sign in to Google Drive again."

    /// Opens Google's consent page (through `open`, e.g. the default browser), waits for the loopback redirect and
    /// returns the new account (titled with the Google account's email) and its secret (refresh token + client).
    /// `loginHint` (an email) preselects the account when signing in again.
    public static func signIn(client: GoogleOAuthClient, transport: [AnyClass]?, loginHint: String? = nil,
                              open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        guard client.looksValid else { throw CloudError.notConfigured(notConfiguredMessage) }
        do {
            let oauth = GoogleOAuth(client: client, transport: transport)
            let tokens = try await oauth.authorize(scopes: scopes, loginHint: loginHint, open: open)
            guard tokens.has(GoogleScopes.drive) else {
                throw CloudError.denied("Google didn’t give Cirrus access to your files. Sign in again and tick “See, edit, create and delete all of your Google Drive files” on Google’s page.")
            }
            guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
                throw CloudError.server("Google didn’t give Cirrus lasting access. Remove Cirrus under myaccount.google.com › Security › Your connections to third-party apps, then sign in again.")
            }
            let probe = GoogleAPI(accountID: "new", oauth: oauth, scopes: tokens.scopes, transport: transport, initialTokens: tokens, refreshToken: { refresh })
            let (user, _) = try await GoogleDrive(api: probe).about()
            let title = !user.email.isEmpty ? user.email : (!user.name.isEmpty ? user.name : serviceName)
            return (CloudAccountRecord(provider: .googleDrive, title: title),
                    CloudSecret(refreshToken: refresh, clientID: client.clientID, clientSecret: client.clientSecret))
        } catch {
            throw cloudError(error)
        }
    }

    /// The backend for a saved account. For real accounts (no `transport`), a refresh token Google rotates is
    /// saved back to the Keychain while the account is still saved; set `onNewRefreshToken` to handle it yourself.
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        try makeBackend(record: record, secret: secret, transport: transport)
    }

    /// `make`, typed: for `onNewRefreshToken`, `exportFormat`, `capabilities(of:)` and `items(named:in:)`.
    public static func makeBackend(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> GoogleDriveBackend {
        guard record.provider == .googleDrive else { throw CloudError.unsupported("This account isn’t a Google Drive account.") }
        guard let id = secret.clientID, !id.isEmpty else { throw CloudError.notConfigured(notConfiguredMessage) }
        let client = GoogleOAuthClient(clientID: id, clientSecret: secret.clientSecret)
        guard client.looksValid else { throw CloudError.notConfigured(notConfiguredMessage) }
        guard let refresh = secret.refreshToken, !refresh.isEmpty else { throw CloudError.signInNeeded(serviceName) }
        let backend = GoogleDriveBackend(accountID: record.id, client: client, refreshToken: refresh, transport: transport)
        if transport == nil {
            let accountID = record.id
            backend.onNewRefreshToken = { s in
                if CloudStore.secret(accountID) != nil { CloudStore.setSecret(accountID, s) }
            }
        }
        return backend
    }

    #if DEBUG
    static let demoLock = NSLock()
    nonisolated(unsafe) static var demoAccount: (record: CloudAccountRecord, backend: CloudDriveBackend)?

    /// Demo mode's Google Drive account (Alex Morgan, alex@example.com), backed by `FakeGoogleServer.DriveDemo`.
    /// Changes last for this run (the fake keeps uploads in memory; saving them on every chunk would be slow).
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        demo(storage: nil)
    }

    static func demo(storage: URL?, latency: Double = 0.02) -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        demoLock.withLock {
            if let d = demoAccount { return d }
            let st = FakeGoogleServer.DriveDemo.start(storage: storage, latency: latency)
            let record = CloudAccountRecord(id: "cloud:googleDrive:demo", provider: .googleDrive, title: st.email,
                                            added: Date(timeIntervalSince1970: 1_760_000_000))
            let secret = CloudSecret(refreshToken: FakeGoogleServer.DriveDemo.refreshToken, clientID: st.clientID, clientSecret: st.clientSecret)
            guard let backend = try? makeBackend(record: record, secret: secret, transport: [FakeGoogleServer.DriveDemo.self]) else { return nil }
            demoAccount = (record, backend)
            return demoAccount
        }
    }
    #endif

    /// Google's errors as `CloudError`s (cancellation stays `CancellationError` when the task was cancelled).
    static func cloudError(_ error: Error) -> Error {
        switch error {
        case is CloudError, is CancellationError:
            return error
        case let e as GoogleError:
            switch e {
            case .reconnect, .missingScope:
                return CloudError.signInNeeded(serviceName)
            case .notConfigured:
                return CloudError.notConfigured(notConfiguredMessage)
            case .accessDenied:
                return CloudError.denied("Google Drive access wasn’t allowed. Sign in again and choose Allow on Google’s page.")
            case .storageFull:
                return CloudError.quotaExceeded(serviceName)
            case .dailyLimit:
                return CloudError.denied("Google Drive’s daily upload limit (about 750 GB a day) has been reached. Try again tomorrow.")
            case .rateLimited:
                return CloudError.server("Google Drive is limiting how fast Cirrus can work. Wait a few minutes, then try again.")
            case .cancelled:
                return Task.isCancelled ? CancellationError() : CloudError.cancelled
            case .http(404, _):
                return CloudError.notFound
            case .http(403, let m):
                return CloudError.denied(m.isEmpty ? "Google Drive didn’t allow that." : m)
            case .uploadExpired:
                return CloudError.server("Google Drive ended the upload before it finished. Try again.")
            case .badResponse(let m) where m.contains("client ID or secret") || m.contains("client secret"):
                return CloudError.notConfigured(m)
            default:
                return CloudError.server(e.errorDescription ?? "Google Drive didn’t answer as expected.")
            }
        case let e as URLError:
            if e.code == .cancelled { return Task.isCancelled ? CancellationError() : CloudError.cancelled }
            return CloudError.server("Couldn’t reach Google Drive: \(e.localizedDescription)")
        default:
            return CloudError.server(error.localizedDescription)
        }
    }
}
