import Foundation

/// Nextcloud's browser sign-in (Login Flow v2): Cirrus asks the server for a login page, the user signs in there
/// (two-factor and SSO included), and the server hands Cirrus an app password of its own. The user's real password
/// never passes through Cirrus. UI-agnostic: the app opens `Pending.loginURL` and awaits `poll`.
public enum NextcloudLoginFlow {
    public struct Pending: Codable, Sendable, Equatable {
        /// The server's base URL (https://cloud.example.com or https://example.com/nextcloud).
        public let server: URL
        /// Open this in the browser.
        public let loginURL: URL
        let pollEndpoint: URL
        let token: String
    }

    /// Seconds between polls (tests set it near zero).
    nonisolated(unsafe) static var pollInterval: Double = 2

    /// Accepts what people type: "cloud.example.com", "https://cloud.example.com/", a link to any Nextcloud page
    /// (…/index.php/apps/files, …/remote.php/dav/files/alex/) or a subfolder install (https://example.com/nextcloud).
    public static func baseURL(from input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw CloudError.notConfigured("Enter your Nextcloud server’s address, like cloud.example.com.") }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s) ?? URL(string: s).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let host = c.host, !host.isEmpty else {
            throw CloudError.notConfigured("“\(input)” isn’t a server address. Enter an address like cloud.example.com.")
        }
        c.scheme = c.scheme?.lowercased()
        c.host = host.lowercased()
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        var path = c.percentEncodedPath
        for marker in ["/index.php", "/remote.php", "/status.php", "/ocs/", "/apps/", "/login/", "/s/"] {
            if let r = path.range(of: marker) { path = String(path[..<r.lowerBound]) }
        }
        if path.hasSuffix("/login") { path.removeLast("/login".count) }
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = path
        guard let url = c.url else { throw CloudError.notConfigured("“\(input)” isn’t a server address.") }
        try DAVURL.check(url)
        return url
    }

    /// Starts a sign-in: POST <server>/index.php/login/v2.
    public static func begin(server: URL, transport: [AnyClass]? = nil) async throws -> Pending {
        let base = try baseURL(from: server.absoluteString)
        let client = DAVClient(username: nil, password: nil, serviceName: "Nextcloud", transport: transport)
        let u = URL(string: base.absoluteString + "/index.php/login/v2")!
        let r = try await client.send("POST", u, headers: ["Accept": "application/json"], retry: .rateLimitOnly)
        guard r.status == 200 else {
            if r.status == 404 || r.status == 405 {
                throw CloudError.notConfigured("No Nextcloud server answered at \(base.host ?? "that address"). Check the address (for a server in a subfolder, include it, like example.com/nextcloud).")
            }
            if (300..<400).contains(r.status) {
                throw CloudError.notConfigured("\(base.host ?? "The server") redirected to another address. Enter the address your browser shows when you open Nextcloud.")
            }
            throw CloudError.server("\(base.host ?? "The server") couldn’t start the sign-in (\(r.status)).")
        }
        let j = (try? JSON(data: r.data)) ?? .null
        guard let token = j["poll"]["token"].string, !token.isEmpty, let endpoint = j["poll"]["endpoint"].string.flatMap(URL.init(string:)),
              let login = j["login"].string.flatMap(URL.init(string:)) else {
            throw CloudError.server("\(base.host ?? "The server") answered the sign-in in a way Cirrus doesn’t understand. Is it a Nextcloud server?")
        }
        // The sign-in page and the token must stay on secure connections.
        try DAVURL.check(endpoint)
        try DAVURL.check(login)
        return Pending(server: base, loginURL: login, pollEndpoint: endpoint, token: token)
    }

    /// Waits until the user approves Cirrus in the browser (polling the server; 404 means not yet).
    /// Throws when `timeout` passes or the task is cancelled.
    public static func poll(_ pending: Pending, timeout: TimeInterval = 20 * 60,
                            transport: [AnyClass]? = nil) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let client = DAVClient(username: nil, password: nil, serviceName: "Nextcloud", transport: transport)
        let deadline = Date().addingTimeInterval(timeout)
        let body = Data(("token=" + (pending.token.addingPercentEncoding(withAllowedCharacters: DAVURL.segmentAllowed) ?? pending.token)).utf8)
        while true {
            try Task.checkCancellation()
            var answer: DAVClient.Response?
            do {
                // Not retried inside: the first 200 uses up the token, so a lost answer can't be fetched twice.
                answer = try await client.send("POST", pending.pollEndpoint,
                                               headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                               body: .data(body), retry: .rateLimitOnly)
            } catch is CloudError {
                // Network trouble while the user is still in the browser: keep waiting.
            }
            if let r = answer, r.status == 200 {
                let j = (try? JSON(data: r.data)) ?? .null
                guard let login = j["loginName"].string, !login.isEmpty, let password = j["appPassword"].string, !password.isEmpty else {
                    throw CloudError.server("Nextcloud finished the sign-in but didn’t send an app password. Try again.")
                }
                var server = pending.server
                if let s = j["server"].string, let u = try? baseURL(from: s), u.host?.lowercased() == pending.server.host?.lowercased() { server = u }
                let record = CloudAccountRecord(provider: .nextcloud, title: WebDAV.title(user: login, server: server),
                                                server: server.absoluteString, username: login)
                return (record, CloudSecret(password: password))
            }
            // 404: the user hasn't finished yet. Anything else: keep trying until the deadline.
            if let r = answer, r.status != 404 { Log.status("nextcloud login poll → \(r.status)") }
            guard Date() < deadline else {
                throw CloudError.denied("The Nextcloud sign-in wasn’t finished in time. Start it again and approve Cirrus in the browser.")
            }
            try await Task.sleep(nanoseconds: UInt64(max(0.01, pollInterval) * 1_000_000_000))
        }
    }
}
