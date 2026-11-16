import Foundation

/// Nextcloud and plain WebDAV accounts (ownCloud, OpenCloud, Synology, QNAP, Apache…). See `WebDAVDrive`.
public enum WebDAV {
    /// The backend for a saved account. Nextcloud records hold the server's base URL and the login name;
    /// WebDAV records hold the folder URL. The secret's password is the (app) password.
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> CloudDriveBackend {
        guard record.provider == .nextcloud || record.provider == .webdav else {
            throw CloudError.unsupported("\(record.provider.displayName) isn’t a WebDAV service.")
        }
        if record.provider == .nextcloud && (secret.password ?? "").isEmpty {
            throw CloudError.signInNeeded(record.title.isEmpty ? "Nextcloud" : "Nextcloud (\(record.title))")
        }
        return try WebDAVDrive(record: record, password: secret.password, transport: transport)
    }

    /// Checks a WebDAV folder address, user name and password (with a PROPFIND) and returns the account to save.
    /// When the address belongs to a Nextcloud server (its status.php says so, or the folder is under remote.php/dav
    /// and answers Nextcloud properties), the account is set up as Nextcloud instead, with trash, thumbnails and
    /// chunked uploads. An ownCloud server's base address is turned into its WebDAV folder (remote.php/webdav).
    public static func connect(url: URL, username: String, password: String,
                               transport: [AnyClass]? = nil) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        var folder = try folderURL(from: url.absoluteString)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = CloudSecret(password: password)
        let base = try nextcloudBase(of: folder)
        switch await serverProduct(base: base, transport: transport) {
        case .nextcloud:
            return (try await connectNextcloud(base: base, user: user, password: password, transport: transport), secret)
        case .owncloud where !folder.absoluteString.contains("/remote.php/"):
            folder = URL(string: base.absoluteString + "/remote.php/webdav/")!
        default:
            break
        }
        let client = DAVClient(username: user, password: password, serviceName: "WebDAV", transport: transport)
        let body = WebDAVDrive.propfindBody(dav: ["resourcetype"], nc: ["has-preview"])
        var hops = 0
        while true {
            let r: DAVClient.Response
            do {
                r = try await client.send("PROPFIND", folder, headers: WebDAVDrive.propfindHeaders("0"), body: .data(body), retry: .safe)
            } catch CloudError.signInNeeded {
                throw badPassword
            }
            // A folder moved on the same server (often just a missing trailing slash): follow it.
            if [301, 302, 303, 307, 308].contains(r.status), hops < 3, let loc = r.header("Location"),
               let next = URL(string: loc, relativeTo: folder)?.absoluteURL, next.host?.lowercased() == folder.host?.lowercased(),
               (try? DAVURL.check(next)) != nil {
                folder = try folderURL(from: next.absoluteString)
                hops += 1
                continue
            }
            guard r.status == 207 else {
                switch r.status {
                case 404, 409:
                    throw CloudError.notConfigured("There’s no WebDAV folder at that address. Check the path (it often ends in /webdav, /dav or /remote.php/webdav).")
                case 403:
                    throw CloudError.denied("The server didn’t allow access to that folder.")
                case 200, 405, 501:
                    throw CloudError.notConfigured("That address is a web page, not a WebDAV folder. Check the path (it often ends in /webdav, /dav or /remote.php/webdav).")
                default:
                    throw CloudError.server("The server couldn’t open that folder (\(r.status)\(DAVErrorBody.suffix(r.data))).")
                }
            }
            let res = try DAVMultistatus.parse(r.data, requestURL: folder)
            guard let first = res.first(where: { ($0.status ?? 200) == 200 }) else {
                throw CloudError.server("The server answered, but not with a folder Cirrus can open.")
            }
            guard first.isCollection else { throw CloudError.notConfigured("That address is a file, not a folder.") }
            // Only Nextcloud answers its own properties: a Nextcloud whose status page is hidden.
            if first.hasPreview != nil && folder.absoluteString.contains("/remote.php/") {
                return (try await connectNextcloud(base: base, user: user, password: password, transport: transport), secret)
            }
            break
        }
        let record = CloudAccountRecord(provider: .webdav, title: title(user: user, server: folder), server: folder.absoluteString,
                                        username: user.isEmpty ? nil : user)
        return (record, secret)
    }

    static let badPassword = CloudError.denied("The server didn’t accept that user name and password. If the account uses two-step sign-in, "
        + "create an app password in the server’s security settings and use that.")

    static func connectNextcloud(base: URL, user: String, password: String, transport: [AnyClass]?) async throws -> CloudAccountRecord {
        guard !user.isEmpty else { throw CloudError.notConfigured("Enter your Nextcloud user name.") }
        let record = CloudAccountRecord(provider: .nextcloud, title: title(user: user, server: base), server: base.absoluteString, username: user)
        let drive = try WebDAVDrive(record: record, password: password, transport: transport)
        do { try await drive.validate() } catch CloudError.signInNeeded { throw badPassword }
        return record
    }

    enum Product { case nextcloud, owncloud, unknown }

    /// The part before /remote.php/ (or the folder itself): where a Nextcloud or ownCloud keeps status.php.
    static func nextcloudBase(of folder: URL) throws -> URL {
        let s = folder.absoluteString
        if let r = s.range(of: "/remote.php/") { return URL(string: String(s[..<r.lowerBound])) ?? folder }
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return URL(string: t) ?? folder
    }

    /// Asks status.php (no credentials sent) which server this is.
    static func serverProduct(base: URL, transport: [AnyClass]?) async -> Product {
        let anon = DAVClient(username: nil, password: nil, serviceName: "WebDAV", transport: transport)
        anon.maxRetries = 1
        guard let u = URL(string: base.absoluteString + "/status.php"),
              let r = try? await anon.send("GET", u, headers: ["Accept": "application/json"], retry: .safe), r.status == 200,
              let j = try? JSON(data: r.data), j["installed"] != .null else { return .unknown }
        let name = (j["productname"].string ?? "").lowercased()
        if name.contains("nextcloud") || j["extendedSupport"] != .null { return .nextcloud }
        if name.contains("owncloud") || j["product"] != .null { return .owncloud }
        return .unknown
    }

    /// A WebDAV folder address as typed (scheme optional) → https URL ending in "/", without credentials, query or fragment.
    public static func folderURL(from input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw CloudError.notConfigured("Enter the WebDAV folder’s address, like https://nas.example.com/webdav.") }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s) ?? URL(string: s).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let host = c.host, !host.isEmpty else {
            throw CloudError.notConfigured("“\(input)” isn’t a server address. Enter an address like https://nas.example.com/webdav.")
        }
        c.scheme = c.scheme?.lowercased()
        c.host = host.lowercased()
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        if !c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath += "/" }
        guard let u = c.url else { throw CloudError.notConfigured("“\(input)” isn’t a server address.") }
        try DAVURL.check(u)
        return u
    }

    /// "alex@cloud.example.com"; an email-style login keeps the server apart: "alex@example.com (cloud.example.com)".
    static func title(user: String, server: URL) -> String {
        var host = server.host ?? server.absoluteString
        if let p = server.port { host += ":\(p)" }
        if user.isEmpty { return host }
        return user.contains("@") ? "\(user) (\(host))" : "\(user)@\(host)"
    }

    #if DEBUG
    /// Demo accounts (CIRRUS_DEMO=1) backed by FakeWebDAVServer: a Nextcloud and a plain WebDAV server.
    public static func demo(_ p: CloudProvider) -> (record: CloudAccountRecord, backend: CloudDriveBackend)? {
        guard p == .nextcloud || p == .webdav else { return nil }
        FakeWebDAVServer.startDemo(storage: Paths.cacheDir("demo").appendingPathComponent("webdav", isDirectory: true))
        let (record, password) = FakeWebDAVServer.demoAccount(p)
        guard let b = try? WebDAVDrive(record: record, password: password, transport: [FakeWebDAVServer.self]) else { return nil }
        return (record, b)
    }
    #endif
}
