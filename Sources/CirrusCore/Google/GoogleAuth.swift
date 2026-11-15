import CryptoKit
import Foundation
import Security

// Google sign-in for installed apps: the system browser shows Google's consent page, Google
// redirects to a one-shot listener on http://127.0.0.1:<random port>, and the code is exchanged
// with PKCE (S256). Bring-your-own client: the user creates a "Desktop app" OAuth client in
// their own Google Cloud project. See https://developers.google.com/identity/protocols/oauth2/native-app

public enum GoogleScopes {
    /// Only files and folders Cirrus creates (non-sensitive).
    public static let driveFile = "https://www.googleapis.com/auth/drive.file"
    /// Add photos and videos to the library and create albums (no read access to the library).
    public static let photosAppend = "https://www.googleapis.com/auth/photoslibrary.appendonly"
    public static let all = [driveFile, photosAppend]
    /// Google → iCloud only: read all of My Drive (asked for when the user starts that direction).
    public static let driveReadonly = "https://www.googleapis.com/auth/drive.readonly"
    /// Google → iCloud only: photos the user picks in Google Photos' own picker.
    public static let photosPicker = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
}

/// The user's own OAuth client ("Desktop app" type). Google treats desktop clients as public:
/// the secret isn't confidential, but Cirrus still keeps it in the Keychain.
public struct GoogleOAuthClient: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = (s?.isEmpty ?? true) ? nil : s
    }

    /// Desktop client IDs look like `1234-abc.apps.googleusercontent.com`.
    public var looksValid: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && clientID.count > ".apps.googleusercontent.com".count + 3 && !clientID.contains(" ")
    }
}

public struct GoogleTokens: Codable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String?
    public var scopes: [String]
    public func has(_ scope: String) -> Bool { scopes.contains(scope) }
}

public enum GoogleError: Error, LocalizedError, Equatable {
    case notConfigured
    case accessDenied
    case stateMismatch
    case timedOut
    case reconnect(String)
    case missingScope(String)
    case http(Int, String)
    case storageFull
    case dailyLimit(String)
    case rateLimited
    case uploadExpired
    case cancelled
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up Google access first: Cirrus needs the client ID from your Google Cloud project."
        case .accessDenied: return "Google access wasn’t allowed. Select Connect Google again and choose Continue/Allow on Google’s page."
        case .stateMismatch: return "The answer from Google didn’t match this sign-in, so Cirrus ignored it. Try connecting again."
        case .timedOut: return "Timed out waiting for you to finish signing in to Google in your browser."
        case .reconnect(let why): return why
        case .missingScope(let what): return "Google didn’t give Cirrus access to \(what). Connect again and tick every box on Google’s page."
        case .http(let code, let msg): return msg.isEmpty ? "Google returned HTTP \(code)." : "\(msg) (HTTP \(code))"
        case .storageFull: return "Your Google storage is full. Free up space or buy more storage, then run the move again — it continues where it stopped."
        case .dailyLimit(let what): return what
        case .rateLimited: return "Google is limiting how fast Cirrus can upload. Wait a while and run the move again; finished items are kept."
        case .uploadExpired: return "Google ended the upload session; Cirrus starts that file again."
        case .cancelled: return "Cancelled."
        case .badResponse(let s): return s
        }
    }
}

/// Proof Key for Code Exchange (RFC 7636), S256.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() { self.init(verifier: Self.random(48)) }   // 64 characters
    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &b) != errSecSuccess { b = (0..<bytes).map { _ in UInt8.random(in: 0...255) } }
        return base64url(Data(b))
    }

    public static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 (never other interfaces) for the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw GoogleError.badResponse("Couldn’t open a local port for the Google sign-in.") }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                               // the kernel picks a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(s, 8) == 0 else { Darwin.close(s); throw GoogleError.badResponse("Couldn’t open a local port for the Google sign-in.") }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: out.sin_port)
    }

    deinit { close() }

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    func cancel() { lock.withLock { cancelled = true } }

    func close() {
        let shouldClose: Bool = lock.withLock { if closed { return false }; closed = true; return true }
        if shouldClose { Darwin.close(fd) }
    }

    /// Blocks (call off the main thread) until the browser delivers Google's redirect.
    func waitForRedirect(timeout: TimeInterval) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if lock.withLock({ cancelled || closed }) { throw GoogleError.cancelled }
            if Date() > deadline { throw GoogleError.timedOut }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 250) > 0 else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            defer { Darwin.close(c) }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let target = Self.readRequestTarget(c) else { continue }
            var q = [String: String]()
            for i in URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
            guard q["code"] != nil || q["error"] != nil else {   // e.g. /favicon.ico
                Self.respond(c, status: "404 Not Found", body: "Not found")
                continue
            }
            let ok = q["code"] != nil
            Self.respond(c, status: "200 OK", body: Self.page(ok))
            return q
        }
    }

    static func readRequestTarget(_ c: Int32) -> String? {
        var buf = [UInt8]()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        // Read the whole header block so closing the socket doesn't reset the connection.
        while buf.count < 32_768 && Date() < deadline {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 300) > 0 else { continue }
            let n = read(c, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(contentsOf: tmp[0..<n])
            if buf.count >= 4, buf.suffix(4) == [13, 10, 13, 10] { break }
        }
        guard let s = String(bytes: buf, encoding: .utf8), let line = s.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    static func respond(_ c: Int32, status: String, body: String) {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        let all = Data(head.utf8) + b
        all.withUnsafeBytes { raw in
            var off = 0
            while off < all.count {
                let n = write(c, raw.baseAddress!.advanced(by: off), all.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    static func page(_ ok: Bool) -> String {
        let title = ok ? "Cirrus is connected to Google" : "Cirrus wasn’t connected"
        let text = ok ? "You can close this tab and go back to Cirrus." : "Google access wasn’t allowed. Go back to Cirrus to try again."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#222}
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#eee}}h1{font-size:1.4em}</style></head>
        <body><h1>\(title)</h1><p>\(text)</p></body></html>
        """
    }
}

/// Authorization-code + PKCE flow, token refresh and revocation.
public final class GoogleOAuth: @unchecked Sendable {
    public static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenURL = "https://oauth2.googleapis.com/token"
    public static let revokeURL = "https://oauth2.googleapis.com/revoke"

    public let client: GoogleOAuthClient
    let http: URLSession

    /// `transport` swaps in URLProtocol classes (mock Google server in tests and the demo).
    public init(client: GoogleOAuthClient, transport: [AnyClass]? = nil) {
        self.client = client
        http = GoogleAPI.makeSession(transport)
    }

    public func authorizationURL(redirectURI: String, pkce: PKCE, state: String, scopes: [String] = GoogleScopes.all, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: Self.authorizeURL)!
        var q = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let h = loginHint, !h.isEmpty { q.append(URLQueryItem(name: "login_hint", value: h)) }
        c.queryItems = q
        // URLComponents leaves "+" alone; Google reads it as a space, so encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// Opens Google's consent page (through `open`) and waits for the redirect, then exchanges the code.
    public func authorize(scopes: [String] = GoogleScopes.all, loginHint: String? = nil, timeout: TimeInterval = 600,
                          open: @escaping @Sendable (URL) async -> Void) async throws -> GoogleTokens {
        guard client.looksValid else { throw GoogleError.notConfigured }
        let rx = try LoopbackReceiver()
        defer { rx.close() }
        let pkce = PKCE()
        let state = PKCE.random(24)
        let url = authorizationURL(redirectURI: rx.redirectURI, pkce: pkce, state: state, scopes: scopes, loginHint: loginHint)
        let query: [String: String] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                // The listener is already accepting connections, so the order of these two doesn't matter.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try rx.waitForRedirect(timeout: timeout)) } catch { cont.resume(throwing: error) }
                }
                Task { await open(url) }
            }
        } onCancel: { rx.cancel() }
        if let e = query["error"] { throw e == "access_denied" ? GoogleError.accessDenied : GoogleError.badResponse("Google sign-in failed (\(e)).") }
        guard query["state"] == state else { throw GoogleError.stateMismatch }
        guard let code = query["code"], !code.isEmpty else { throw GoogleError.badResponse("Google didn’t send a sign-in code.") }
        return try await exchange(code: code, verifier: pkce.verifier, redirectURI: rx.redirectURI, requested: scopes)
    }

    func exchange(code: String, verifier: String, redirectURI: String, requested: [String]) async throws -> GoogleTokens {
        var form = ["code": code, "client_id": client.clientID, "code_verifier": verifier,
                    "grant_type": "authorization_code", "redirect_uri": redirectURI]
        if let s = client.clientSecret { form["client_secret"] = s }
        // A code works once, so only retry when the request never reached Google.
        let j = try await post(form, retryAmbiguous: false)
        return try tokens(j, requested: requested)
    }

    /// New access token from a refresh token. The refresh token itself usually stays the same.
    public func refresh(_ refreshToken: String) async throws -> GoogleTokens {
        var form = ["client_id": client.clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        if let s = client.clientSecret { form["client_secret"] = s }
        return try tokens(try await post(form, retryAmbiguous: true), requested: nil)
    }

    /// Revoking the refresh token ends Cirrus's access (best effort).
    public func revoke(_ token: String) async {
        var req = URLRequest(url: URL(string: Self.revokeURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(["token": token])
        if let (_, r) = try? await http.data(for: req), let h = r as? HTTPURLResponse { Log.status("google revoke → \(h.statusCode)") }
    }

    func tokens(_ j: JSON, requested: [String]?) throws -> GoogleTokens {
        guard let access = j["access_token"].string, !access.isEmpty else { throw GoogleError.badResponse("Google’s answer had no access token.") }
        let scopes = j["scope"].string.map { $0.split(separator: " ").map(String.init) } ?? requested ?? []
        return GoogleTokens(accessToken: access, expiresAt: Date().addingTimeInterval(j["expires_in"].double ?? 3600),
                            refreshToken: j["refresh_token"].string, scopes: scopes)
    }

    func post(_ form: [String: String], retryAmbiguous: Bool) async throws -> JSON {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.formEncode(form)
        var attempt = 0
        while true {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await http.data(for: req) } catch let e as URLError {
                if e.code == .cancelled { throw GoogleError.cancelled }
                guard attempt < 3, GoogleAPI.isTransient(e, ambiguousOK: retryAmbiguous) else { throw e }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 250_000_000))
                continue
            }
            guard let h = resp as? HTTPURLResponse else { throw GoogleError.badResponse("No response from Google.") }
            Log.status("google token → \(h.statusCode)")   // never the body: it holds tokens
            let j = (try? JSON(data: data)) ?? .null
            if h.statusCode == 200 { return j }
            if (h.statusCode >= 500 || h.statusCode == 429), attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 500_000_000))
                continue
            }
            switch j["error"].string ?? "" {
            case "invalid_grant":
                throw GoogleError.reconnect("Google ended Cirrus’s access (it was revoked, the password changed, or — while your Google Cloud project is in Testing — 7 days passed). Select Connect Google to continue; the move picks up where it stopped.")
            case "invalid_client", "unauthorized_client":
                throw GoogleError.badResponse("Google didn’t accept the client ID or secret. Check them in Set Up Google Access…")
            case "invalid_request" where (j["error_description"].string ?? "").contains("client_secret"):
                throw GoogleError.badResponse("Google needs the client secret too. Paste it in Set Up Google Access…")
            default:
                throw GoogleError.http(h.statusCode, j["error_description"].string ?? (j["error"].string ?? "Google didn’t accept the sign-in."))
            }
        }
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = form.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }
}
