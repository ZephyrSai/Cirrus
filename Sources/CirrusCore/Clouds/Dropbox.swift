import Foundation

// Dropbox through API v2: the signed-in user's whole Dropbox (team accounts: the team space, as the Dropbox
// app shows it).
//
// Sign-in is the OAuth 2 authorization code flow with PKCE (S256) for a public client: no app secret, and
// `token_access_type=offline` for a long-lived refresh token (access tokens last about four hours). Dropbox
// matches redirect URIs exactly, port included, so Cirrus listens on one of three fixed loopback ports and
// sends the matching `http://localhost:<port>`. Where a loopback redirect can't work (iOS, a port held by
// another app, a locked-down browser), `signInWithCode` / `beginCodeSignIn` run the same flow without a
// redirect: Dropbox shows a code and the user pastes it into Cirrus.
//
// App Console setup (dropbox.com/developers/apps › Create app):
//   • Choose an API: “Scoped access”. Type of access: “Full Dropbox”.
//   • Settings › OAuth 2 › “Allow public clients (Implicit Grant & PKCE)”: Allow.
//   • Settings › OAuth 2 › Redirect URIs: add each of these exactly (no trailing slash):
//       http://localhost:47823   http://localhost:47824   http://localhost:47825
//     (The paste-a-code sign-in needs no redirect URI.)
//   • Permissions: account_info.read, files.metadata.read, files.metadata.write, files.content.read,
//     files.content.write — then Submit. Nothing else (no sharing, no team scopes).
//   • Never use the App secret: Cirrus is a public client.
//   • A new app is in Development status: up to 500 Dropbox users can link to it before Dropbox's
//     production review (Settings › “Apply for production”).
// Put the app's App key into `Dropbox.defaultAppKey`.

public enum Dropbox {
    /// Cirrus's own Dropbox app (App key). Empty until the project registers one; accounts can also carry their
    /// own App key in `CloudSecret.clientID`.
    nonisolated(unsafe) public static var defaultAppKey = ""

    /// What Cirrus asks for: the account's email (for the account title), and reading and changing files.
    public static let scopes = ["account_info.read", "files.metadata.read", "files.metadata.write", "files.content.read", "files.content.write"]

    /// The loopback ports the browser sign-in can use, in order (Dropbox needs each redirect URI registered).
    public static let redirectPorts: [UInt16] = [47823, 47824, 47825]

    /// The redirect URIs to register in the App Console, exactly as Cirrus sends them.
    public static var redirectURIs: [String] { redirectPorts.map(redirectURI) }

    static func redirectURI(_ port: UInt16) -> String { "http://localhost:\(port)" }

    static let notConfiguredMessage = "Dropbox isn’t set up in this copy of Cirrus yet: it needs a Dropbox app key. "
        + "Create a free app at dropbox.com/developers/apps (Scoped access, Full Dropbox), allow public clients, add the redirect URIs "
        + "http://localhost:47823, http://localhost:47824 and http://localhost:47825, turn on the account_info.read, files.metadata and files.content permissions, "
        + "then enter its App key."

    static func appKey(_ given: String?) throws -> String {
        let s = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = s.isEmpty ? defaultAppKey.trimmingCharacters(in: .whitespacesAndNewlines) : s
        guard !key.isEmpty else { throw CloudError.notConfigured(notConfiguredMessage) }
        return key
    }

    /// The backend for a saved account. Dropbox keeps refresh tokens stable, but the backend still reports a new
    /// one through `onNewRefreshToken` (CloudTokenRotating) should Dropbox ever hand one out.
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        try backend(record: record, secret: secret, transport: transport)
    }

    /// Same as `make`, typed (for `onNewRefreshToken`, `secret` and the tuning knobs).
    public static func backend(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> DropboxBackend {
        let key = try Self.appKey(secret.clientID)
        guard let rt = secret.refreshToken, !rt.isEmpty else { throw CloudError.signInNeeded("Dropbox") }
        return DropboxBackend(accountID: record.id, appKey: key, refreshToken: rt, pathRoot: record.options?["pathRoot"], transport: transport)
    }

    // MARK: Browser sign-in (loopback redirect)

    /// Runs the browser sign-in (`open` shows the URL in the system browser), then reads the account's email for
    /// the account title. Returns what `CloudStore.save` needs: the secret holds the refresh token and the App key.
    /// Errors are CloudError (or CancellationError).
    public static func signIn(appKey: String, transport: [AnyClass]?,
                              open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        try await signIn(appKey: appKey, transport: transport, ports: redirectPorts, timeout: 600, open: open)
    }

    static func signIn(appKey given: String, transport: [AnyClass]?, ports: [UInt16], timeout: TimeInterval,
                       open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let appKey = try Self.appKey(given)
        let http = DropboxHTTP.makeSession(transport)
        defer { http.finishTasksAndInvalidate() }
        let rx = try DropboxLoopback(ports: ports)
        defer { rx.close() }
        let redirect = redirectURI(rx.port)
        let pkce = PKCE()
        let state = PKCE.random(24)
        let url = DropboxAuth.authorizationURL(appKey: appKey, redirectURI: redirect, pkce: pkce, state: state)
        let query: [String: String] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                // The listener is already accepting connections, so the order of these two doesn't matter.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try rx.waitForRedirect(timeout: timeout)) } catch { cont.resume(throwing: error) }
                }
                Task { await open(url) }
            }
        } onCancel: { rx.cancel() }
        try Task.checkCancellation()
        if let e = query["error"] {
            if e == "access_denied" {
                throw CloudError.denied("Dropbox access wasn’t allowed. Select Add Account again and choose Allow on Dropbox’s page.")
            }
            let why = (query["error_description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw CloudError.denied("Dropbox didn’t connect (\(why.isEmpty ? e : why)).")
        }
        guard query["state"] == state else {
            throw CloudError.denied("The answer from Dropbox didn’t match this sign-in, so Cirrus ignored it. Try adding the account again.")
        }
        guard let code = query["code"], !code.isEmpty else { throw CloudError.server("Dropbox didn’t send a sign-in code. Try again.") }
        let t = try await DropboxAuth.redeem(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                              "code_verifier": pkce.verifier], appKey: appKey, http: http, signingIn: true)
        return try await finishSignIn(t, appKey: appKey, http: http)
    }

    // MARK: Paste-a-code sign-in (no redirect)

    /// Starts the sign-in without a redirect: open `url` in a browser; once the user allows access, Dropbox shows
    /// a code, which goes to `finish(code:transport:)`. Works anywhere a browser does (iOS included).
    public static func beginCodeSignIn(appKey: String) throws -> DropboxCodeSignIn {
        let key = try Self.appKey(appKey)
        let pkce = PKCE()
        return DropboxCodeSignIn(url: DropboxAuth.authorizationURL(appKey: key, redirectURI: nil, pkce: pkce, state: nil),
                                 appKey: key, verifier: pkce.verifier)
    }

    /// The paste-a-code sign-in in one call: `open` shows Dropbox's page, `code` asks the user for the code
    /// Dropbox showed (throw CancellationError from it to stop).
    public static func signInWithCode(appKey: String, transport: [AnyClass]?, open: @escaping @Sendable (URL) async -> Void,
                                      code: @escaping @Sendable () async throws -> String) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let pending = try beginCodeSignIn(appKey: appKey)
        await open(pending.url)
        let typed = try await code()
        try Task.checkCancellation()
        return try await pending.finish(code: typed, transport: transport)
    }

    // MARK: After the code

    /// Checks what Dropbox granted, reads the account, and builds the record and secret.
    static func finishSignIn(_ t: DropboxTokenSet, appKey: String, http: URLSession) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        guard let rt = t.refresh, !rt.isEmpty else {
            throw CloudError.server("Dropbox didn’t let Cirrus stay signed in (no refresh token). Try again.")
        }
        if let granted = t.scopes {
            let missing = scopes.filter { !granted.contains($0) }
            if !missing.isEmpty {
                throw CloudError.notConfigured("The Dropbox app this copy of Cirrus uses doesn’t have these permissions: \(missing.joined(separator: ", ")). "
                    + "Turn them on in the App Console’s Permissions tab, choose Submit, then add the account again.")
            }
        }
        let tokens = DropboxTokens(appKey: appKey, refreshToken: rt, http: http, initial: t)
        let api = DropboxHTTP(session: http, tokens: tokens, pathRoot: nil)
        let me = try await DropboxHTTP.guarded { try await api.rpc("users/get_current_account", nil, retry: .safe) }
        let title = [me["email"].string, me["name"]["display_name"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Dropbox"
        // A team with a team space: paths start at the team's root namespace (team folders plus the member's own
        // folder), as the Dropbox app shows them; otherwise they would start in the member folder only.
        var options: [String: String]?
        let root = me["root_info"]
        if root[".tag"].string == "team", let ns = root["root_namespace_id"].string, !ns.isEmpty, ns != root["home_namespace_id"].string {
            options = ["pathRoot": ns]
        }
        let record = CloudAccountRecord(provider: .dropbox, title: title, options: options)
        return (record, CloudSecret(refreshToken: tokens.currentRefreshToken, clientID: appKey))
    }

    #if DEBUG
    /// Demo mode: an account backed by FakeDropboxServer (generic sample content, no network).
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        let seed = FakeDropboxServer.startDemo()
        let record = CloudAccountRecord(id: "cloud:dropbox:demo", provider: .dropbox, title: seed.title,
                                        added: Date(timeIntervalSince1970: 1_790_000_000))
        let backend = DropboxBackend(accountID: record.id, appKey: seed.appKey, refreshToken: seed.refreshToken, pathRoot: nil,
                                     transport: [FakeDropboxServer.self])
        return (record, backend)
    }
    #endif
}

/// A paste-a-code sign-in in progress (see `Dropbox.beginCodeSignIn`).
public struct DropboxCodeSignIn: Sendable {
    /// Dropbox's page; after the user allows access it shows the code to paste.
    public let url: URL
    public let appKey: String
    let verifier: String

    /// Exchanges the code the user pasted. A code works once and for a few minutes.
    public func finish(code: String, transport: [AnyClass]?) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw CloudError.denied("Paste the code Dropbox showed after you chose Allow.") }
        let http = DropboxHTTP.makeSession(transport)
        defer { http.finishTasksAndInvalidate() }
        let t = try await DropboxAuth.redeem(["grant_type": "authorization_code", "code": code, "code_verifier": verifier],
                                             appKey: appKey, http: http, signingIn: true, pastedCode: true)
        return try await Dropbox.finishSignIn(t, appKey: appKey, http: http)
    }
}

/// Dropbox's OAuth 2 endpoints.
enum DropboxAuth {
    static let authorizeURL = "https://www.dropbox.com/oauth2/authorize"
    static let tokenURL = "https://api.dropboxapi.com/oauth2/token"

    /// `redirectURI` nil: Dropbox shows the code instead of redirecting.
    static func authorizationURL(appKey: String, redirectURI: String?, pkce: PKCE, state: String?) -> URL {
        var c = URLComponents(string: authorizeURL)!
        var q = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "scope", value: Dropbox.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let redirectURI { q.append(URLQueryItem(name: "redirect_uri", value: redirectURI)) }
        if let state { q.append(URLQueryItem(name: "state", value: state)) }
        c.queryItems = q
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// POSTs to the token endpoint (public client: the App key, never a secret). A sign-in code works once, so
    /// it's retried only when it never left; a refresh is retried after dropped connections too.
    static func redeem(_ form: [String: String], appKey: String, http: URLSession, signingIn: Bool, pastedCode: Bool = false) async throws -> DropboxTokenSet {
        var form = form
        form["client_id"] = appKey
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = GoogleOAuth.formEncode(form)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data, resp: URLResponse
            do { (data, resp) = try await http.data(for: req) } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                guard attempt < 3, DropboxHTTP.retryable(e, ambiguousOK: !signingIn) else { throw DropboxHTTP.networkError(e) }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 250_000_000))
                continue
            }
            guard let h = resp as? HTTPURLResponse else { throw CloudError.server("No answer from Dropbox’s sign-in service.") }
            Log.status("dropbox token → \(h.statusCode)")   // never the body: it holds tokens
            let j = (try? JSON(data: data)) ?? .null
            if h.statusCode == 200 {
                guard let access = j["access_token"].string, !access.isEmpty else { throw CloudError.server("Dropbox’s answer had no access token. Try again.") }
                let scopes = j["scope"].string.map { Set($0.split(separator: " ").map(String.init)) }
                return DropboxTokenSet(access: access, refresh: j["refresh_token"].string,
                                       expires: Date().addingTimeInterval(j["expires_in"].double ?? 14_400), scopes: scopes)
            }
            if (h.statusCode >= 500 || h.statusCode == 429), attempt < 3 {
                attempt += 1
                let after = h.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(nanoseconds: UInt64(min(after ?? pow(2, Double(attempt)) * 0.5, 30) * 1_000_000_000))
                continue
            }
            throw tokenError(j, status: h.statusCode, signingIn: signingIn, pastedCode: pastedCode)
        }
    }

    static func tokenError(_ j: JSON, status: Int, signingIn: Bool, pastedCode: Bool = false) -> CloudError {
        let error = j["error"].string ?? ""
        let why = (j["error_description"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch error {
        case "invalid_grant" where pastedCode:
            return .denied("Dropbox didn’t accept that code. A code works once and only for a few minutes: start the sign-in again for a new one.")
        case "invalid_grant" where signingIn:
            return .server("Dropbox didn’t accept the sign-in (\(why.isEmpty ? error : why)). Try again.")
        case "invalid_grant":
            // Revoked from dropbox.com › Settings › Connected apps, or the app was unlinked.
            return .signInNeeded("Dropbox")
        case "invalid_client", "unauthorized_client":
            return .notConfigured("Dropbox doesn’t accept Cirrus’s app key (\(why.isEmpty ? error : why)). Check the App key and that the app allows public clients (PKCE).")
        default:
            return .server("Dropbox sign-in failed (\(why.isEmpty ? (error.isEmpty ? "HTTP \(status)" : error) : why)).")
        }
    }
}

/// One-shot HTTP listener for Dropbox's redirect on a fixed port (Dropbox matches redirect URIs exactly, port
/// included). It holds the port on both 127.0.0.1 and ::1 (when the system has IPv6), so whichever one the
/// browser picks for "localhost" reaches Cirrus and never another app. Never other interfaces.
final class DropboxLoopback: @unchecked Sendable {
    private let fds: [Int32]
    let port: UInt16
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    static let portsBusyMessage = "Cirrus couldn’t open its Dropbox sign-in port: another app is using ports 47823–47825. Quit that app and try again, or sign in with a code instead."

    /// Listens on the first of `ports` that is free (0: any free port, for tests).
    init(ports: [UInt16]) throws {
        guard let (fds, port) = Self.open(ports) else { throw CloudError.server(Self.portsBusyMessage) }
        self.fds = fds
        self.port = port
    }

    static func open(_ ports: [UInt16]) -> ([Int32], UInt16)? {
        for p in ports {
            guard let (v4, bound) = bind4(p) else { continue }
            switch bind6(bound) {
            case .bound(let v6): return ([v4, v6], bound)
            case .unavailable: return ([v4], bound)
            case .busy: Darwin.close(v4)
            }
        }
        return nil
    }

    deinit { close() }

    static func bind4(_ port: UInt16) -> (Int32, UInt16)? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, listen(s, 8) == 0 else { Darwin.close(s); return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return (s, UInt16(bigEndian: out.sin_port))
    }

    enum Bind6 { case bound(Int32), busy, unavailable }

    static func bind6(_ port: UInt16) -> Bind6 {
        let s = socket(AF_INET6, SOCK_STREAM, 0)
        guard s >= 0 else { return .unavailable }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        if ok != 0 {
            let err = errno
            Darwin.close(s)
            return err == EADDRINUSE ? .busy : .unavailable
        }
        guard listen(s, 8) == 0 else { Darwin.close(s); return .busy }
        return .bound(s)
    }

    func cancel() { lock.withLock { cancelled = true } }

    func close() {
        let shouldClose: Bool = lock.withLock { if closed { return false }; closed = true; return true }
        if shouldClose { fds.forEach { _ = Darwin.close($0) } }
    }

    /// Blocks (call off the main thread) until the browser delivers Dropbox's redirect.
    func waitForRedirect(timeout: TimeInterval) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if lock.withLock({ cancelled || closed }) { throw CancellationError() }
            if Date() > deadline { throw CloudError.server("Timed out waiting for you to finish signing in to Dropbox in your browser.") }
            var polls = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&polls, nfds_t(polls.count), 250) > 0, let ready = polls.first(where: { $0.revents & Int16(POLLIN) != 0 }) else { continue }
            let c = accept(ready.fd, nil, nil)
            guard c >= 0 else { continue }
            defer { Darwin.close(c) }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let target = LoopbackReceiver.readRequestTarget(c) else { continue }
            var q = [String: String]()
            for i in URLComponents(string: "http://localhost" + target)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
            guard q["code"] != nil || q["error"] != nil else {   // e.g. /favicon.ico
                LoopbackReceiver.respond(c, status: "404 Not Found", body: "Not found")
                continue
            }
            LoopbackReceiver.respond(c, status: "200 OK", body: LoopbackReceiver.page(q["code"] != nil, service: "Dropbox"))
            return q
        }
    }
}
