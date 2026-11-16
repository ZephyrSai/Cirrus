import Foundation

/// Immich (immich.app), a self-hosted photo library. It plugs into Cirrus's Photos model (timeline, albums,
/// favorites, archive, trash) through `ImmichPhotos`, not the file browser.
///
/// Wire protocol: the Immich REST API under `<server>/api`, authenticated with a user-made API key in the
/// `x-api-key` header. Targets Immich v3 (July 2026): asset listing uses `POST /search/metadata` with the
/// structured `filter` / `orderBy` / `cursor` shape on 3.2 and later, and the older flat fields on 3.0–3.1.
/// Servers before 3.0 are refused (3.0 removed the upload device fields and moved album ownership).
public enum Immich {
    /// Oldest server Cirrus connects to.
    public static let minimumVersion = ImmichVersion(major: 3, minor: 0, patch: 0)

    /// API key permissions Cirrus needs to browse and export. A key without them is refused when connecting.
    public static let readPermissions = ["user.read", "asset.read", "asset.view", "asset.download", "asset.statistics", "album.read"]
    /// Permissions for changing the library. A key without some of them still connects; Cirrus then hides
    /// those commands (see `ImmichPhotos.capabilities`).
    public static let writePermissions = ["asset.update", "asset.delete", "asset.upload", "asset.share", "album.create", "albumAsset.create"]

    /// The backend for a saved account: the record's server address and the API key from the Keychain.
    public static func make(record: CloudAccountRecord, secret: CloudSecret, transport: [AnyClass]?) throws -> PhotosBackend {
        guard record.provider == .immich else { throw CloudError.unsupported("\(record.provider.displayName) isn’t an Immich account.") }
        let key = (secret.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CloudError.signInNeeded(serviceName(record.title)) }
        guard let server = record.server else { throw CloudError.notConfigured("This Immich account has no server address. Remove it and add it again.") }
        return ImmichPhotos(record: record, server: try serverURL(from: server), apiKey: key, transport: transport)
    }

    /// Checks a server address and API key and returns the account to save: finds the server (accepts
    /// "photos.example.com", with or without https:// and /api), checks it answers as Immich 3.0 or later,
    /// then asks who the key belongs to (the email becomes the account title) and which permissions it has.
    public static func connect(server: String, apiKey: String,
                               transport: [AnyClass]? = nil) async throws -> (record: CloudAccountRecord, secret: CloudSecret) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw CloudError.notConfigured("Paste an Immich API key. Create one in Immich under Account Settings › API Keys.")
        }
        let base = try serverURL(from: server)
        let host = displayHost(base)
        let anon = ImmichClient(server: base, apiKey: nil, serviceName: "Immich", transport: transport)
        anon.maxRetries = 2

        // 1. Is this an Immich server? (No key sent yet.)
        let ping = try await anon.send("GET", "/server/ping", retry: .safe)
        if (300..<400).contains(ping.status) {
            let to = ping.header("Location").flatMap { URL(string: $0, relativeTo: ping.http.url)?.absoluteURL }
            throw CloudError.notConfigured("“\(host)” sent Cirrus to another address" + (to.map { " (\(displayHost($0)))" } ?? "")
                + ". Enter the address Immich is served from" + (to.map { ", like \(serverString($0))" } ?? "") + ".")
        }
        guard ping.status == 200, let pong = try? JSON(data: ping.data), pong["res"].string == "pong" else {
            throw CloudError.notConfigured("There’s no Immich server at “\(host)”. Check the address: it’s the one you open Immich at in a browser, like https://photos.example.com.")
        }

        // 2. Version.
        let v: JSON
        do { v = try await anon.call("GET", "/server/version", retry: .safe) } catch CloudError.notFound { v = .null }
        guard let version = ImmichVersion(v) else { throw CloudError.server("“\(host)” didn’t say which Immich version it runs.") }
        guard version >= minimumVersion else {
            throw CloudError.unsupported("“\(host)” runs Immich \(version). Cirrus needs Immich \(minimumVersion.short) or later: update the server, then try again.")
        }

        // 3. Who the key belongs to.
        let client = ImmichClient(server: base, apiKey: key, serviceName: "Immich", transport: transport)
        client.maxRetries = 2
        let me: JSON
        do {
            me = try await client.call("GET", "/users/me", retry: .safe)
        } catch CloudError.signInNeeded {
            throw badKey
        }
        let email = (me["email"].string ?? "").trimmingCharacters(in: .whitespaces)
        let name = (me["name"].string ?? "").trimmingCharacters(in: .whitespaces)

        // 4. What the key may do (an older key with no permission list, or a session token, can't be asked: assume all).
        var options: [String: String] = ["version": version.description]
        if let k = try? await client.call("GET", "/api-keys/me", retry: .safe), case .array(let list) = k["permissions"] {
            let perms = Set(list.compactMap(\.string))
            if !perms.contains("all") {
                let missing = readPermissions.filter { !perms.contains($0) }
                if !missing.isEmpty {
                    throw CloudError.denied("This API key can’t be used to browse your library: it’s missing the permission"
                        + (missing.count == 1 ? " " : "s ") + missing.joined(separator: ", ")
                        + ". In Immich, edit the key under Account Settings › API Keys (or create one with “All” permissions).")
                }
            }
            options["permissions"] = perms.sorted().joined(separator: ",")
        }
        let user = email.isEmpty ? name : email
        let record = CloudAccountRecord(provider: .immich, title: WebDAV.title(user: user, server: base), server: serverString(base),
                                        username: email.isEmpty ? nil : email, options: options)
        Log.status("immich: connected (\(version))")
        return (record, CloudSecret(password: key))
    }

    static let badKey = CloudError.denied("Immich didn’t accept that API key. Check that you copied all of it, "
        + "or create a new one in Immich under Account Settings › API Keys.")

    static func serviceName(_ title: String) -> String { title.isEmpty ? "Immich" : "Immich (\(title))" }

    // MARK: Server address

    /// Immich's own web routes: an address copied from the browser's address bar ends in one of these.
    static let webRoutes: Set<String> = ["photos", "albums", "explore", "favorites", "archive", "trash", "people", "sharing",
                                         "search", "map", "places", "user-settings", "admin", "auth", "memory", "folders",
                                         "tags", "locked", "utilities", "buy", "shared-links", "partners", "duplicates"]

    /// A server address as typed → the server's base URL (scheme, host, port; no trailing slash, no /api).
    /// Without a scheme, https is assumed, except for a local-network address (Immich's own port 2283 serves http).
    public static func serverURL(from input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw CloudError.notConfigured("Enter your Immich server’s address, like https://photos.example.com.") }
        let hadScheme = s.contains("://")
        if !hadScheme { s = "https://" + s }
        guard var c = URLComponents(string: s), let rawHost = c.host, !rawHost.isEmpty else {
            throw CloudError.notConfigured("“\(input)” isn’t a server address. Enter an address like https://photos.example.com.")
        }
        let host = rawHost.lowercased()
        c.scheme = c.scheme?.lowercased()
        if !hadScheme && isLocalNetwork(host) { c.scheme = "http" }
        c.host = host
        c.user = nil
        c.password = nil
        c.query = nil
        c.fragment = nil
        var segments = c.percentEncodedPath.split(separator: "/").map(String.init)
        // Drop an /api suffix (the API base is added later) or anything from an Immich web route onwards.
        if let i = segments.firstIndex(where: { webRoutes.contains($0.lowercased()) }) { segments = Array(segments[..<i]) }
        while let last = segments.last, last.lowercased() == "api" { segments.removeLast() }
        c.percentEncodedPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let url = c.url else { throw CloudError.notConfigured("“\(input)” isn’t a server address.") }
        try checkScheme(url)
        return url
    }

    /// https everywhere; plain http only to a server on the local network (or this device).
    static func checkScheme(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw CloudError.notConfigured("“\(url.absoluteString)” isn’t a server address Cirrus can use. Enter an address like https://photos.example.com.")
        }
        switch scheme {
        case "https": return
        case "http":
            if isLocalNetwork(host) { return }
            throw CloudError.unsupported("Cirrus connects to Immich over the internet only with https://, so your API key and photos are never sent unencrypted. "
                + "Use the server’s https:// address. (Plain http:// works for a server on your local network, like 192.168.1.20:2283 or immich.local.)")
        default:
            throw CloudError.unsupported("Cirrus can’t connect to “\(scheme)://” addresses. Use the server’s https:// address.")
        }
    }

    /// This device, a private (RFC 1918 / unique-local / link-local) address, a .local (Bonjour) name or a
    /// single-label name such as "nas": places plain http may go, since that traffic stays on the local network.
    public static func isLocalNetwork(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) {
            let o = octets.compactMap { Int($0) }
            guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return false }
            switch (o[0], o[1]) {
            case (10, _), (127, _): return true
            case (172, 16...31): return true
            case (192, 168): return true
            case (169, 254): return true
            default: return false
            }
        }
        if host.contains(":") {   // IPv6
            if host == "::1" { return true }
            let first = host.split(separator: ":", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            guard let v = UInt16(first, radix: 16) else { return false }
            return (v & 0xfe00) == 0xfc00 || (v & 0xffc0) == 0xfe80   // fc00::/7 unique local, fe80::/10 link local
        }
        // A single-label name ("nas", "immich") only resolves on the local network.
        return !host.contains(".")
    }

    /// "https://photos.example.com" (no trailing slash): what the record stores.
    static func serverString(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func displayHost(_ url: URL) -> String {
        var h = url.host ?? url.absoluteString
        if let p = url.port { h += ":\(p)" }
        return h
    }

    #if DEBUG
    /// The demo account (CIRRUS_DEMO=1), backed by FakeImmichServer.
    public static func demo() -> (record: CloudAccountRecord, photos: PhotosBackend)? {
        FakeImmichServer.startDemo(storage: Paths.cacheDir("demo").appendingPathComponent("immich", isDirectory: true))
        let record = FakeImmichServer.demoRecord()
        guard let photos = try? make(record: record, secret: CloudSecret(password: FakeImmichServer.demoAPIKey),
                                     transport: [FakeImmichServer.self]) else { return nil }
        return (record, photos)
    }
    #endif
}

/// An Immich server version ("3.4.1").
public struct ImmichVersion: Comparable, Sendable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    /// From `GET /server/version`.
    init?(_ j: JSON) {
        guard let ma = j["major"].int, let mi = j["minor"].int else { return nil }
        self.init(major: ma, minor: mi, patch: j["patch"].int ?? 0)
    }

    /// "3.4.1" or "v3.4.1".
    init?(string: String) {
        let parts = string.trimmingCharacters(in: CharacterSet(charactersIn: "v ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 2, let ma = parts[0], let mi = parts[1] else { return nil }
        self.init(major: ma, minor: mi, patch: parts.count > 2 ? (parts[2] ?? 0) : 0)
    }

    public static func < (a: ImmichVersion, b: ImmichVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    public var description: String { "\(major).\(minor).\(patch)" }
    var short: String { "\(major).\(minor)" }

    /// `POST /search/metadata` takes `filter` / `orderBy` / `cursor` from 3.2 (the flat fields are deprecated there).
    var hasStructuredSearch: Bool { self >= ImmichVersion(major: 3, minor: 2, patch: 0) }
}
