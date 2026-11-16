import Foundation

// OneDrive (personal, work and school) through Microsoft Graph v1.0: the signed-in user's own drive.
//
// Sign-in is the OAuth 2.0 authorization code flow with PKCE (S256) for a public client: no client secret.
// The system browser shows Microsoft's sign-in page and Microsoft redirects to a one-shot listener on this
// device. App registration (Microsoft Entra admin center › App registrations › New registration):
//   • Supported account types: "Accounts in any organizational directory and personal Microsoft accounts"
//     (the `common` authority below needs this).
//   • Platform: "Mobile and desktop applications", custom redirect URI `http://localhost` (no port, no
//     path). Microsoft ignores the port of loopback redirect URIs, so Cirrus's random port matches it.
//   • API permissions (Microsoft Graph, delegated): Files.ReadWrite.All, offline_access, User.Read.
//     None of them needs admin consent.
//   • No client secret or certificate. If Microsoft ever answers AADSTS7000218 ("client_secret required"),
//     check that the redirect URI is under "Mobile and desktop applications" (or turn on Authentication ›
//     "Allow public client flows").
// Put the registration's Application (client) ID into `OneDrive.defaultClientID`.

public enum OneDrive {
    /// Cirrus's own Microsoft app registration (Application (client) ID). Empty until the project registers one;
    /// accounts can also carry their own client ID in `CloudSecret.clientID`.
    nonisolated(unsafe) public static var defaultClientID = ""

    /// What Cirrus asks for: read and write the user's files (Files.ReadWrite.All also covers folders
    /// others shared with them), stay signed in (offline_access → refresh token), and the user's name.
    public static let scopes = ["Files.ReadWrite.All", "offline_access", "User.Read"]

    static let notConfiguredMessage = "OneDrive isn’t set up in this copy of Cirrus yet: it needs a Microsoft app (client) ID. "
        + "Register a free app in the Microsoft Entra admin center (Mobile and desktop, redirect URI http://localhost) and enter its client ID."

    static func clientID(_ given: String?) throws -> String {
        let s = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = s.isEmpty ? defaultClientID.trimmingCharacters(in: .whitespacesAndNewlines) : s
        guard !id.isEmpty else { throw CloudError.notConfigured(notConfiguredMessage) }
        return id
    }

    /// The backend for a saved account. To keep the account signed in across launches, set its
    /// `onNewRefreshToken` (Microsoft rotates refresh tokens) — `backend(record:secret:transport:)` returns the
    /// concrete type for that.
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        try backend(record: record, secret: secret, transport: transport)
    }

    /// Same as `make`, typed, so the app can set `onNewRefreshToken`, e.g.
    /// `b.onNewRefreshToken = { rt in var s = secret; s.refreshToken = rt; CloudStore.setSecret(record.id, s) }`.
    public static func backend(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> OneDriveBackend {
        let id = try clientID(secret.clientID)
        guard let rt = secret.refreshToken, !rt.isEmpty else { throw CloudError.signInNeeded("OneDrive") }
        return OneDriveBackend(accountID: record.id, clientID: id, refreshToken: rt, transport: transport)
    }

    /// Runs the browser sign-in (`open` shows the URL in the system browser), then reads the user's name for
    /// the account title. Returns what `CloudStore.save` needs. Errors are CloudError (or CancellationError).
    public static func signIn(clientID: String, transport: [AnyClass]?,
                              open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        try await signIn(clientID: clientID, transport: transport, timeout: 600, open: open)
    }

    static func signIn(clientID given: String, transport: [AnyClass]?, timeout: TimeInterval,
                       open: @escaping @Sendable (URL) async -> Void) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let clientID = try clientID(given)
        let http = OneDriveHTTP.makeSession(transport)
        defer { http.finishTasksAndInvalidate() }
        let rx: LoopbackReceiver
        do { rx = try LoopbackReceiver(service: "OneDrive") } catch {
            throw CloudError.server("Cirrus couldn’t open a local port for the Microsoft sign-in.")
        }
        defer { rx.close() }
        // Entra matches loopback redirect URIs without their port, so `http://localhost` registered once
        // accepts any port. The listener is on 127.0.0.1 (browsers fall back to it when ::1 refuses).
        let redirect = "http://localhost:\(rx.port)"
        let pkce = PKCE()
        let state = PKCE.random(24)
        let url = OneDriveAuth.authorizationURL(clientID: clientID, redirectURI: redirect, pkce: pkce, state: state)
        let query: [String: String]
        do {
            query = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                    // The listener is already accepting connections, so the order of these two doesn't matter.
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { cont.resume(returning: try rx.waitForRedirect(timeout: timeout)) } catch { cont.resume(throwing: error) }
                    }
                    Task { await open(url) }
                }
            } onCancel: { rx.cancel() }
        } catch let e as GoogleError {   // LoopbackReceiver's own errors
            switch e {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CloudError.server("Timed out waiting for you to finish signing in to Microsoft in your browser.")
            default: throw CloudError.server(e.localizedDescription)
            }
        }
        try Task.checkCancellation()
        if let e = query["error"] {
            if e == "access_denied" {
                throw CloudError.denied("OneDrive access wasn’t allowed. Select Add Account again and choose Accept on Microsoft’s page.")
            }
            let why = OneDriveAuth.firstLine(query["error_description"] ?? "")
            throw CloudError.denied("Microsoft didn’t connect OneDrive (\(why.isEmpty ? e : why)).")
        }
        guard query["state"] == state else {
            throw CloudError.denied("The answer from Microsoft didn’t match this sign-in, so Cirrus ignored it. Try adding the account again.")
        }
        guard let code = query["code"], !code.isEmpty else { throw CloudError.server("Microsoft didn’t send a sign-in code. Try again.") }
        let t = try await OneDriveAuth.redeem(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                               "code_verifier": pkce.verifier, "scope": scopes.joined(separator: " ")],
                                              clientID: clientID, http: http, signingIn: true)
        guard let rt = t.refresh, !rt.isEmpty else {
            throw CloudError.server("Microsoft didn’t let Cirrus stay signed in to OneDrive. Try again and accept every permission Microsoft asks for.")
        }
        let tokens = OneDriveTokens(clientID: clientID, refreshToken: rt, http: http, initial: t)
        let api = OneDriveHTTP(session: http, tokens: tokens)
        let me = try await OneDriveHTTP.guarded {
            try await api.json("GET", "/me", query: [("$select", "id,displayName,mail,userPrincipalName")], retry: .safe)
        }
        // A work account without a OneDrive licence, or one never opened, has no drive yet.
        let drive = try await OneDriveHTTP.guarded {
            try await api.send(try api.request("GET", OneDriveHTTP.graph + "/me/drive", query: [("$select", "id,driveType")]), retry: .safe)
        }
        if drive.status == 404 || drive.status == 403 {
            throw CloudError.denied("This Microsoft account doesn’t have a OneDrive yet. Open OneDrive on the web once (work and school accounts also need a OneDrive licence), then try again.")
        }
        guard (200..<300).contains(drive.status) else { throw OneDriveHTTP.error(drive) }
        let title = [me["mail"].string, me["userPrincipalName"].string, me["displayName"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "OneDrive"
        let record = CloudAccountRecord(provider: .onedrive, title: title)
        return (record, CloudSecret(refreshToken: tokens.currentRefreshToken, clientID: clientID))
    }

    #if DEBUG
    /// Demo mode: an account backed by FakeGraphServer (generic sample content, no network).
    public static func demo() -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        let seed = FakeGraphServer.startDemo()
        let record = CloudAccountRecord(id: "cloud:onedrive:demo", provider: .onedrive, title: seed.title,
                                        added: Date(timeIntervalSince1970: 1_790_000_000))
        let backend = OneDriveBackend(accountID: record.id, clientID: seed.clientID, refreshToken: seed.refreshToken,
                                      transport: [FakeGraphServer.self])
        return (record, backend)
    }
    #endif
}

/// Microsoft identity platform endpoints (v2.0, `common` authority: personal and work/school accounts).
enum OneDriveAuth {
    static let authorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

    static func authorizationURL(clientID: String, redirectURI: String, pkce: PKCE, state: String) -> URL {
        var c = URLComponents(string: authorizeURL)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: OneDrive.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Lets someone with several Microsoft accounts pick which one to add.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// Microsoft's error descriptions carry trace and correlation IDs on later lines.
    static func firstLine(_ s: String) -> String {
        s.components(separatedBy: CharacterSet.newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// POSTs to the token endpoint. A sign-in code works once, so it's retried only when it never left;
    /// a refresh is retried after dropped connections too.
    static func redeem(_ form: [String: String], clientID: String, http: URLSession, signingIn: Bool) async throws -> OneDriveTokenSet {
        var form = form
        form["client_id"] = clientID
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
                guard attempt < 3, OneDriveHTTP.retryable(e, ambiguousOK: !signingIn) else { throw OneDriveHTTP.networkError(e) }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 250_000_000))
                continue
            }
            guard let h = resp as? HTTPURLResponse else { throw CloudError.server("No answer from Microsoft’s sign-in service.") }
            Log.status("onedrive token → \(h.statusCode)")   // never the body: it holds tokens
            let j = (try? JSON(data: data)) ?? .null
            if h.statusCode == 200 {
                guard let access = j["access_token"].string, !access.isEmpty else { throw CloudError.server("Microsoft’s answer had no access token. Try again.") }
                return OneDriveTokenSet(access: access, refresh: j["refresh_token"].string,
                                        expires: Date().addingTimeInterval(j["expires_in"].double ?? 3600))
            }
            if (h.statusCode >= 500 || h.statusCode == 429), attempt < 3 {
                attempt += 1
                let after = h.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(nanoseconds: UInt64(min(after ?? pow(2, Double(attempt)) * 0.5, 30) * 1_000_000_000))
                continue
            }
            throw tokenError(j, status: h.statusCode, signingIn: signingIn)
        }
    }

    static func tokenError(_ j: JSON, status: Int, signingIn: Bool) -> CloudError {
        let error = j["error"].string ?? ""
        let why = firstLine(j["error_description"].string ?? "")
        switch error {
        case "invalid_grant" where signingIn:
            return .server("Microsoft didn’t accept the sign-in (\(why.isEmpty ? error : why)). Try again.")
        case "invalid_grant", "interaction_required", "login_required", "consent_required":
            // Revoked, expired after 90 days unused, password changed, or new consent needed.
            return .signInNeeded("OneDrive")
        case "invalid_client", "unauthorized_client":
            if why.contains("AADSTS7000218") {
                return .notConfigured("Microsoft treats Cirrus’s app registration as a confidential client. In the Entra admin center, put the redirect URI http://localhost under “Mobile and desktop applications” (or turn on “Allow public client flows”).")
            }
            return .notConfigured("Microsoft doesn’t accept Cirrus’s OneDrive app ID (\(why.isEmpty ? error : why)).")
        default:
            return .server("Microsoft sign-in failed (\(why.isEmpty ? (error.isEmpty ? "HTTP \(status)" : error) : why)).")
        }
    }
}
