import Foundation

// iCloud web session: SRP sign-in against idmsa.apple.com, two-factor, trust, accountLogin,
// Advanced Data Protection (PCS) consent, and an authenticated request helper with re-auth
// and back-off. Protocol details follow rclone's iclouddrive backend and icloudpd.

public struct StoredCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var expires: Date?
}

public struct TrustedPhone: Codable, Hashable, Sendable {
    public var id: Int
    public var number: String
    public var mode: String
}

public struct SessionState: Codable, Sendable {
    public var appleID: String
    public var clientID = ICloudSession.widgetKey
    public var frameID = UUID().uuidString.lowercased()
    public var sessionToken: String?
    public var scnt: String?
    public var sessionID: String?
    public var accountCountry: String?
    public var domainToUse: String?
    public var trustToken: String?
    public var authAttributes: String?
    public var cookies: [StoredCookie] = []
    public var accountInfoData: Data?

    public init(appleID: String) { self.appleID = appleID.lowercased() }

    public var accountInfo: JSON { accountInfoData.flatMap { try? JSON(data: $0) } ?? .null }
}

public enum ICloudError: Error, LocalizedError, Equatable {
    case badCredentials
    case needsSignIn
    case twoFactorRequired
    case http(Int, String?)
    case server(String)
    case webAccessDisabled
    case approvalTimedOut
    case serviceUnavailable(String)
    case notFound
    case conflict
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badCredentials: return "Incorrect Apple ID or password."
        case .needsSignIn: return "Your iCloud session expired. Sign in again to continue."
        case .twoFactorRequired: return "Enter the verification code to finish signing in."
        case .http(let code, let msg): return msg.map { "\($0) (HTTP \(code))" } ?? "iCloud returned HTTP \(code)."
        case .server(let msg): return msg
        case .webAccessDisabled:
            return "Advanced Data Protection is on and web access is off. On your iPhone, open Settings › [your name] › iCloud and turn on “Access iCloud Data on the Web”."
        case .approvalTimedOut: return "Timed out waiting for approval on your Apple device."
        case .serviceUnavailable(let s): return "\(s) isn’t available for this Apple ID."
        case .notFound: return "The item no longer exists in iCloud."
        case .conflict: return "The item changed in iCloud. Refresh and try again."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Events the session needs the UI to know about.
public enum SessionEvent: Sendable {
    case stateChanged
    case needsSignIn
    case waitingForApproval(String)
    case approvalFinished
}

public actor ICloudSession {
    public static let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

    struct Endpoints { let base: String; let setup: String; let auth: String }

    /// Unit tests swap in a mock Apple server (URLProtocol subclasses).
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]?

    public private(set) var state: SessionState
    public private(set) var needs2FA = false
    nonisolated let http: URLSession
    var eventHandler: (@Sendable (SessionEvent) -> Void)?
    var passwordProvider: (@Sendable () async -> String?)?
    var reauthTask: Task<Void, Error>?
    var pcsTasks: [String: Task<Void, Error>] = [:]

    public init(state: SessionState) {
        self.state = state
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30   // a stalled connection fails fast and is retried
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpMaximumConnectionsPerHost = 8
        if let mocks = ICloudSession.testProtocolClasses { config.protocolClasses = mocks }
        http = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func setEventHandler(_ h: @escaping @Sendable (SessionEvent) -> Void) { eventHandler = h }
    public func setPasswordProvider(_ p: @escaping @Sendable () async -> String?) { passwordProvider = p }

    var endpoints: Endpoints {
        if state.domainToUse?.lowercased() == "icloud.com.cn" {
            return Endpoints(base: "https://www.icloud.com.cn", setup: "https://setup.icloud.com.cn/setup/ws/1", auth: "https://idmsa.apple.com.cn/appleauth/auth")
        }
        return Endpoints(base: "https://www.icloud.com", setup: "https://setup.icloud.com/setup/ws/1", auth: "https://idmsa.apple.com/appleauth/auth")
    }

    var frameTag: String { "auth-" + state.frameID }

    // MARK: - Account info

    public var accountInfo: JSON { state.accountInfo }
    public var dsid: String? { state.accountInfo["dsInfo"]["dsid"].string }
    public var fullName: String? { state.accountInfo["dsInfo"]["fullName"].string }
    public var hasSession: Bool { !state.cookies.isEmpty && !state.accountInfo["webservices"].isNull }

    public func webserviceURL(_ key: String) -> String? {
        let ws = state.accountInfo["webservices"][key]
        guard let url = ws["url"].string, ws["status"].string.map({ $0 == "active" }) ?? true else { return nil }
        return url
    }

    func pcsRequired(_ key: String) -> Bool { state.accountInfo["webservices"][key]["pcsRequired"].bool ?? false }

    // MARK: - Low-level transport

    struct Response { let data: Data; let http: HTTPURLResponse; var json: JSON { (try? JSON(data: data)) ?? .null } }

    func send(_ request: URLRequest, retryNetwork: Bool? = nil) async throws -> Response {
        var req = request
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp): (Data, URLResponse)
        let started = Date()
        let session = http
        do {
            // A dropped/stale connection (“The network connection was lost”) is retried for safe calls.
            if retryNetwork ?? (req.httpMethod == "GET") {
                (data, resp) = try await Self.withNetworkRetry { try await session.data(for: req) }
            } else {
                (data, resp) = try await session.data(for: req)
            }
        } catch let e as URLError where e.code == .cancelled {
            throw ICloudError.cancelled
        }
        let secs = Date().timeIntervalSince(started)
        if secs > 2 { Log.status("slow \(req.httpMethod ?? "GET") \(req.url?.host ?? "")\(req.url?.path ?? "") \(String(format: "%.1f", secs))s") }
        guard let h = resp as? HTTPURLResponse else { throw ICloudError.http(0, "No response") }
        absorb(h)
        let line = "\(req.httpMethod ?? "GET") \(req.url?.host ?? "")\(req.url?.path ?? "") → \(h.statusCode)"
        // Status lines only (no query, headers, cookies or bodies) so live problems can be diagnosed safely.
        if (200..<300).contains(h.statusCode) { Log.debug(line + String(format: " (%.2fs)", secs)) } else { Log.status("http " + line) }
        return Response(data: data, http: h)
    }

    func absorb(_ h: HTTPURLResponse) {
        func hv(_ k: String) -> String? { let v = h.value(forHTTPHeaderField: k); return (v?.isEmpty ?? true) ? nil : v }
        if let v = hv("X-Apple-ID-Account-Country") { state.accountCountry = v }
        if let v = hv("X-Apple-ID-Session-Id") { state.sessionID = v }
        if let v = hv("X-Apple-Session-Token") { state.sessionToken = v }
        if let v = hv("X-Apple-TwoSV-Trust-Token") { state.trustToken = v }
        if let v = hv("scnt") { state.scnt = v }
        if let v = hv("X-Apple-Auth-Attributes") { state.authAttributes = v }
        if let url = h.url {
            var fields = [String: String]()
            for (k, v) in h.allHeaderFields { if let ks = k as? String, let vs = v as? String { fields[ks] = vs } }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            mergeCookies(cookies.map { StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate) })
        }
    }

    func mergeCookies(_ incoming: [StoredCookie]) {
        guard !incoming.isEmpty else { return }
        let now = Date()
        for c in incoming {
            state.cookies.removeAll { $0.name == c.name }
            if c.value.isEmpty || (c.expires.map { $0 < now } ?? false) { continue }
            state.cookies.append(c)
        }
    }

    public func hasCookies(_ names: [String]) -> Bool {
        names.allSatisfy { n in state.cookies.contains { $0.name == n } }
    }

    var cookieHeader: String {
        let now = Date()
        return state.cookies.filter { !$0.value.isEmpty && ($0.expires.map { $0 > now } ?? true) }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func jsonBody(_ j: JSON) -> Data { j.data() }

    func authHeaders() -> [String: String] {
        let origin = endpoints.auth.replacingOccurrences(of: "/appleauth/auth", with: "")
        var h: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": origin,
            "Referer": origin + "/",
            "X-Apple-Widget-Key": state.clientID,
            "X-Apple-OAuth-Client-Id": state.clientID,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Redirect-URI": endpoints.base,
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-OAuth-Response-Mode": "web_message",
            "X-Apple-OAuth-Response-Type": "code",
            "X-Apple-OAuth-State": frameTag,
            "X-Apple-Frame-Id": frameTag,
            "X-Requested-With": "XMLHttpRequest",
            "X-Apple-Mandate-Security-Upgrade": "0",
            "X-Apple-I-Require-UE": "true",
            "X-Apple-I-FD-Client-Info": #"{"U":"\#(Self.userAgent)","L":"en-US","Z":"GMT-05:00","V":"1.1","F":""}"#,
        ]
        if let v = state.authAttributes { h["X-Apple-Auth-Attributes"] = v }
        if let v = state.scnt { h["scnt"] = v }
        if let v = state.sessionID { h["X-Apple-ID-Session-Id"] = v }
        return h
    }

    func serviceHeaders(contentType: String = "application/json", cookies: Bool = true) -> [String: String] {
        var h = ["Content-Type": contentType, "Origin": endpoints.base, "Referer": endpoints.base + "/"]
        if cookies { h["Cookie"] = cookieHeader }
        return h
    }

    func makeRequest(_ urlString: String, method: String, query: [String: String] = [:], headers: [String: String], body: Data? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: urlString) else { throw ICloudError.http(0, "Bad URL") }
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw ICloudError.http(0, "Bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        if body == nil && (method == "POST" || method == "PUT") { req.setValue("0", forHTTPHeaderField: "Content-Length") }
        return req
    }

    func setupParams() -> [String: String] {
        var p = ["clientBuildNumber": "2522Project44", "clientMasteringNumber": "2522B2", "clientId": frameTag]
        if let d = dsid { p["dsid"] = d }
        return p
    }

    static func errorMessage(_ j: JSON) -> String? {
        if let m = j["serviceErrors"][0]["message"].string { return m }
        if let m = j["errorMessage"].string { return m }
        if let m = j["error"].string, !m.isEmpty { return m }
        if let m = j["reason"].string { return m }
        return nil
    }

    func notify(_ e: SessionEvent) { eventHandler?(e) }

    // MARK: - Sign in

    public enum SignInOutcome: Sendable { case signedIn, needsCode(phones: [TrustedPhone], deviceAvailable: Bool) }

    /// Full SRP sign-in. If Apple wants a second factor, returns `.needsCode` and the UI calls
    /// `submitCode` / `requestSMS` / `submitSMSCode`. Otherwise completes accountLogin.
    public func signIn(password: String, forceFresh: Bool = false) async throws -> SignInOutcome {
        if forceFresh { state.trustToken = nil }
        needs2FA = false
        let appleID = state.appleID
        try await authStart()
        try await authFederate(appleID)
        var client = AppleSRPClient()
        let initResp = try await send(makeRequest(endpoints.auth + "/signin/init", method: "POST", headers: authHeaders(),
            body: jsonBody(["a": .string(Data(client.aBytes).base64EncodedString()), "accountName": .string(appleID), "protocols": ["s2k", "s2k_fo"]])))
        guard initResp.http.statusCode == 200 else {
            if initResp.http.statusCode == 401 || initResp.http.statusCode == 403 { throw ICloudError.badCredentials }
            throw ICloudError.http(initResp.http.statusCode, Self.errorMessage(initResp.json))
        }
        let j = initResp.json
        guard let b64B = j["b"].string, let b = Data(base64Encoded: b64B), let s64 = j["salt"].string, let salt = Data(base64Encoded: s64),
              let iterations = j["iteration"].int, let proto = j["protocol"].string, let c = j["c"].string else {
            throw ICloudError.server("Apple returned an unexpected sign-in challenge.")
        }
        let key = try AppleSRPClient.derivePassword(password, salt: Array(salt), iterations: iterations, protocol: proto)
        try client.processChallenge(username: appleID, derivedKey: key, salt: Array(salt), serverB: Array(b))
        let complete = try await send(makeRequest(endpoints.auth + "/signin/complete", method: "POST", query: ["isRememberMeEnabled": "true"], headers: authHeaders(),
            body: jsonBody(["accountName": .string(appleID), "m1": .string(Data(client.M1).base64EncodedString()),
                            "m2": .string(Data(client.M2).base64EncodedString()), "c": .string(c), "rememberMe": true,
                            "trustTokens": .array(state.trustToken.map { [JSON.string($0)] } ?? [])])))
        Log.status("auth: signin/complete → \(complete.http.statusCode)")
        switch complete.http.statusCode {
        case 200, 204:
            break
        case 409:
            needs2FA = true
        case 412:
            // Password accepted; Apple wants the "repair" acknowledgement (terms / account notices) before continuing.
            let r = try await send(makeRequest(endpoints.auth + "/repair/complete", method: "POST", headers: authHeaders(), body: jsonBody([:])))
            guard (200..<300).contains(r.http.statusCode) else {
                throw ICloudError.http(r.http.statusCode, Self.errorMessage(r.json) ?? "Apple asked to update this account; sign in once at icloud.com, then try again.")
            }
            Log.status("auth: repair acknowledged (\(r.http.statusCode))")
        case 401, 403:
            throw ICloudError.badCredentials
        default:
            throw ICloudError.http(complete.http.statusCode, Self.errorMessage(complete.json))
        }
        if !needs2FA {
            do {
                try await accountLogin()
                return .signedIn
            } catch ICloudError.twoFactorRequired {
                needs2FA = true   // e.g. after the 412 repair path, Apple still wants a code
            }
        }
        if needs2FA {
            let auth = try? await authState()
            if let auth, auth.noTrustedDevices, !auth.phones.isEmpty {
                return .needsCode(phones: auth.phones, deviceAvailable: false)
            }
            _ = try? await send(makeRequest(endpoints.auth + "/verify/trusteddevice/securitycode", method: "PUT", headers: authHeaders()))
            persist()
            return .needsCode(phones: auth?.phones ?? [], deviceAvailable: true)
        }
        return .signedIn
    }

    func authStart() async throws {
        let q = ["frame_id": frameTag, "language": "en_US", "skVersion": "7", "iframeId": frameTag, "client_id": state.clientID,
                 "redirect_uri": endpoints.base, "response_type": "code", "response_mode": "web_message", "state": frameTag, "authVersion": "latest"]
        let r = try await send(makeRequest(endpoints.auth + "/authorize/signin", method: "GET", query: q, headers: ["Accept": "*/*"]))
        guard (200..<300).contains(r.http.statusCode) else { throw ICloudError.http(r.http.statusCode, "Couldn’t reach Apple’s sign-in service.") }
    }

    func authFederate(_ accountName: String) async throws {
        let r = try await send(makeRequest(endpoints.auth + "/federate", method: "POST", query: ["isRememberMeEnabled": "true"], headers: authHeaders(),
                                           body: jsonBody(["accountName": .string(accountName), "rememberMe": true])))
        guard (200..<300).contains(r.http.statusCode) else { throw ICloudError.http(r.http.statusCode, Self.errorMessage(r.json) ?? "Apple didn’t accept this Apple ID.") }
    }

    struct AuthStateInfo { var phones: [TrustedPhone]; var noTrustedDevices: Bool }

    func authState() async throws -> AuthStateInfo {
        let r = try await send(makeRequest(endpoints.auth, method: "GET", headers: authHeaders()))
        var j = r.json
        if !j["phoneNumberVerification"].isNull && j["authenticationType"].isNull { j = j["phoneNumberVerification"] }
        var phones = j["trustedPhoneNumbers"].array
        if phones.isEmpty, !j["trustedPhoneNumber"].isNull { phones = [j["trustedPhoneNumber"]] }
        let list = phones.compactMap { p -> TrustedPhone? in
            guard let id = p["id"].int else { return nil }
            return TrustedPhone(id: id, number: p["numberWithDialCode"].string ?? p["obfuscatedNumber"].string ?? "Phone \(id)",
                                mode: p["pushMode"].string ?? "sms")
        }
        return AuthStateInfo(phones: list, noTrustedDevices: j["noTrustedDevices"].bool ?? false)
    }

    /// Code shown on a trusted Apple device.
    public func submitCode(_ code: String) async throws {
        let r = try await send(makeRequest(endpoints.auth + "/verify/trusteddevice/securitycode", method: "POST", headers: authHeaders(),
                                           body: jsonBody(["securityCode": ["code": .string(code)]])))
        try check2FAResponse(r)
        try await trustAndLogin()
    }

    public func requestSMS(phone: TrustedPhone) async throws {
        let r = try await send(makeRequest(endpoints.auth + "/verify/phone", method: "PUT", headers: authHeaders(),
                                           body: jsonBody(["phoneNumber": ["id": .int(phone.id)], "mode": .string(phone.mode)])))
        guard (200..<300).contains(r.http.statusCode) else { throw ICloudError.http(r.http.statusCode, Self.errorMessage(r.json) ?? "Couldn’t send a text message.") }
    }

    public func submitSMSCode(_ code: String, phone: TrustedPhone) async throws {
        let r = try await send(makeRequest(endpoints.auth + "/verify/phone/securitycode", method: "POST", headers: authHeaders(),
                                           body: jsonBody(["securityCode": ["code": .string(code)], "phoneNumber": ["id": .int(phone.id)], "mode": .string(phone.mode)])))
        try check2FAResponse(r)
        try await trustAndLogin()
    }

    func check2FAResponse(_ r: Response) throws {
        let code = r.http.statusCode
        if (200..<300).contains(code) { return }
        // Since mid-2026 idmsa can answer 409 even for an accepted code; a session token means success.
        if code == 409, r.http.value(forHTTPHeaderField: "X-Apple-Session-Token") != nil { return }
        if code == 400 || code == 401 || code == 403 { throw ICloudError.server(Self.errorMessage(r.json) ?? "That code isn’t right. Try again.") }
        throw ICloudError.http(code, Self.errorMessage(r.json))
    }

    func trustAndLogin() async throws {
        let r = try await send(makeRequest(endpoints.auth + "/2sv/trust", method: "GET", headers: authHeaders()))
        guard (200..<300).contains(r.http.statusCode) else { throw ICloudError.http(r.http.statusCode, "Apple didn’t trust this session.") }
        needs2FA = false
        try await accountLogin()
    }

    func accountLogin() async throws {
        for _ in 0..<2 {
            let body: JSON = ["accountCountryCode": .string(state.accountCountry ?? ""), "dsWebAuthToken": .string(state.sessionToken ?? ""),
                              "extended_login": true, "trustToken": .string(state.trustToken ?? "")]
            let r = try await send(makeRequest(endpoints.setup + "/accountLogin", method: "POST", headers: serviceHeaders(cookies: false), body: jsonBody(body)))
            switch r.http.statusCode {
            case 200:
                state.accountInfoData = r.data
                if state.accountInfo["hsaChallengeRequired"].bool == true && state.accountInfo["dsInfo"]["hsaVersion"].int == 2 {
                    needs2FA = true
                    throw ICloudError.twoFactorRequired
                }
                persist()
                return
            case 302:
                let domain = r.json["domainToUse"].string ?? ""
                guard domain.lowercased() == "icloud.com.cn", state.domainToUse?.lowercased() != "icloud.com.cn" else {
                    throw ICloudError.server("Unsupported iCloud region “\(domain)”.")
                }
                state.domainToUse = "iCloud.com.cn"
                throw ICloudError.needsSignIn // China accounts must start over on the .cn endpoints
            case 401, 421:
                throw ICloudError.needsSignIn
            default:
                throw ICloudError.http(r.http.statusCode, Self.errorMessage(r.json))
            }
        }
    }

    /// Re-validate an existing cookie session.
    public func validate() async throws {
        let r = try await send(makeRequest(endpoints.setup + "/validate", method: "POST", query: setupParams(), headers: serviceHeaders()))
        guard r.http.statusCode == 200 else { throw ICloudError.needsSignIn }
        state.accountInfoData = r.data
        persist()
    }

    public func signOut() {
        state.cookies = []
        state.sessionToken = nil
        state.accountInfoData = nil
        persist()
    }

    func persist() {
        if let data = try? JSONEncoder().encode(state) { Keychain.set(data, service: Keychain.sessionService, account: state.appleID) }
        notify(.stateChanged)
    }

    /// Silent re-authentication: accountLogin with stored tokens, then SRP with the remembered
    /// password and trust token. Throws `.needsSignIn` when a human is required.
    func reauthenticate() async throws {
        if let t = reauthTask { return try await t.value }
        let task = Task<Void, Error> {
            if self.state.sessionToken != nil {
                do { try await self.accountLogin(); return } catch ICloudError.twoFactorRequired { throw ICloudError.needsSignIn } catch {}
            }
            if let pw = await self.passwordProvider?() {
                let outcome = try await self.signIn(password: pw)
                if case .needsCode = outcome { self.notify(.needsSignIn); throw ICloudError.needsSignIn }
                return
            }
            self.notify(.needsSignIn)
            throw ICloudError.needsSignIn
        }
        reauthTask = task
        defer { reauthTask = nil }
        try await task.value
    }

    // MARK: - Advanced Data Protection

    static let pcsCookies: [String: [String]] = [
        "photos": ["X-APPLE-WEBAUTH-PCS-Photos", "X-APPLE-WEBAUTH-PCS-Sharing"],
        "iclouddrive": ["X-APPLE-WEBAUTH-PCS-Documents"],
    ]

    /// Ensures PCS cookies exist for a service on ADP accounts (may wait for device approval).
    public func ensurePCS(app: String, webservice: String) async throws {
        guard pcsRequired(webservice), let names = Self.pcsCookies[app], !hasCookies(names) else { return }
        if let t = pcsTasks[app] { return try await t.value }
        let task = Task<Void, Error> { try await self.acquirePCS(app: app, names: names) }
        pcsTasks[app] = task
        defer { pcsTasks[app] = nil }
        try await task.value
    }

    func setupCall(_ name: String, method: String = "POST", body: JSON?) async throws -> JSON {
        let r = try await send(makeRequest(endpoints.setup + "/" + name, method: method, query: setupParams(),
                                           headers: serviceHeaders(contentType: "text/plain;charset=UTF-8"), body: body.map { jsonBody($0) }))
        if r.http.statusCode == 401 || r.http.statusCode == 421 { throw ICloudError.needsSignIn }
        guard (200..<300).contains(r.http.statusCode) else { throw ICloudError.http(r.http.statusCode, Self.errorMessage(r.json)) }
        return r.json
    }

    func acquirePCS(app: String, names: [String]) async throws {
        notify(.waitingForApproval(app))
        defer { notify(.approvalFinished) }
        let workflow = UUID().uuidString.uppercased()
        let wf: JSON = ["workflowUuid": .string(workflow)]
        var usedConsentFlow = false
        if var st = try? await setupCall("requestWebAccessState", body: wf) {
            usedConsentFlow = true
            if st["isWebAccessAllowed"].bool == false { throw ICloudError.webAccessDisabled }
            if st["isDeviceConsentedForPCS"].bool != true {
                _ = try await setupCall("enableDeviceConsentForPCS", body: wf)
                let deadline = Date().addingTimeInterval(5 * 60)
                while st["isDeviceConsentedForPCS"].bool != true {
                    if Date() > deadline { throw ICloudError.approvalTimedOut }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    st = try await setupCall("requestWebAccessState", body: wf)
                }
            }
            _ = try? await setupCall("generateSessionIdToken", method: "GET", body: nil)
        }
        for attempt in 0..<40 {
            var body: JSON = ["appName": .string(app), "derivedFromUserAction": .bool(attempt == 0)]
            if usedConsentFlow { body = ["appName": .string(app), "derivedFromUserAction": .bool(attempt == 0), "isFinalAttempt": false, "workflowUuid": .string(workflow)] }
            let r = try await setupCall("requestPCS", body: body)
            if r["status"].string == "success" {
                if hasCookies(names) { persist(); return }
                throw ICloudError.server("iCloud approved web access but didn’t return the keys. Try again in a minute.")
            }
            try await Task.sleep(nanoseconds: (attempt < 10 ? 3 : 8) * 1_000_000_000)
        }
        throw ICloudError.approvalTimedOut
    }

    // MARK: - Authenticated service requests

    /// JSON request to an iCloud web service with re-auth (401/421), ADP consent (423) and
    /// back-off on 429/5xx for idempotent calls.
    public func request(_ url: String, method: String = "POST", query: [String: String] = [:], json body: JSON? = nil,
                        rawBody: Data? = nil, contentType: String = "application/json", pcs: (app: String, ws: String)? = nil,
                        idempotent: Bool = true) async throws -> JSON {
        if let pcs { try await ensurePCS(app: pcs.app, webservice: pcs.ws) }
        var reauthed = false
        var pcsRetried = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let req = try makeRequest(url, method: method, query: query, headers: serviceHeaders(contentType: contentType), body: rawBody ?? body.map { jsonBody($0) })
            let r = try await send(req, retryNetwork: idempotent)
            let code = r.http.statusCode
            if (200..<300).contains(code) { return r.json }
            if (code == 401 || code == 421) && !reauthed {
                reauthed = true
                try await reauthenticate()
                continue
            }
            if code == 423 || (code == 403 && String(data: r.data, encoding: .utf8)?.contains("PCS") == true), let pcs, !pcsRetried {
                pcsRetried = true
                state.cookies.removeAll { (Self.pcsCookies[pcs.app] ?? []).contains($0.name) }
                try await ensurePCS(app: pcs.app, webservice: pcs.ws)
                continue
            }
            if (code == 429 || code == 503 || code == 502 || code == 504 || (code >= 500 && idempotent)) && attempt < 5 {
                attempt += 1
                let retryAfter = r.http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt)) * 0.5
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
                continue
            }
            if code == 404 { throw ICloudError.notFound }
            if code == 409 { throw ICloudError.conflict }
            throw ICloudError.http(code, Self.errorMessage(r.json) ?? String(data: r.data.prefix(200), encoding: .utf8))
        }
    }

    /// Download a content URL to a file with progress. Follows Apple's odd 330 redirects.
    public nonisolated func download(from urlString: String, to destination: URL, expectedSize: Int64?,
                                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let headers = await serviceHeaders(contentType: "application/octet-stream")
        var current = urlString.replacingOccurrences(of: "${f}", with: "file")
        for _ in 0..<5 {
            guard let url = URL(string: current) else { throw ICloudError.http(0, "Bad download URL") }
            var req = URLRequest(url: url)
            for (k, v) in headers where k != "Content-Type" { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let started = Date()
            let (tmp, h) = try await Self.withNetworkRetry { try await ContentDownloader.shared.fetch(req, expected: expectedSize ?? 0, progress: progress) }
            if [301, 302, 303, 307, 308, 330].contains(h.statusCode), let loc = h.value(forHTTPHeaderField: "Location") {
                try? FileManager.default.removeItem(at: tmp)
                current = loc
                continue
            }
            guard (200..<300).contains(h.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                if h.statusCode == 401 || h.statusCode == 403 || h.statusCode == 410 { throw ICloudError.http(h.statusCode, "Download link expired") }
                throw ICloudError.http(h.statusCode, "Download failed")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmp, to: destination)
            try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
            let secs = Date().timeIntervalSince(started)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            if secs > 1.5 { Log.status("download \(bytes.byteString) in \(String(format: "%.1f", secs))s (\(Int64(Double(bytes) / max(secs, 0.01)).byteString)/s)") }
            return
        }
        throw ICloudError.http(0, "Too many redirects")
    }

    /// Upload a body (file or bytes) with progress; returns parsed JSON.
    public func upload(to urlString: String, query: [String: String] = [:], file: URL, multipartName: String?, contentType: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> JSON {
        var reauthed = false
        while true {
            var req = try makeRequest(urlString, method: "POST", query: query, headers: serviceHeaders(contentType: contentType))
            let bodyFile: URL
            var cleanup = false
            if let name = multipartName {
                let boundary = "CirrusBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                bodyFile = try Multipart.write(file: file, fieldName: name, filename: name, mime: contentType, boundary: boundary)
                cleanup = true
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            } else {
                bodyFile = file
            }
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64) ?? 0
            let delegate = ProgressDelegate(expected: size, progress: progress)
            defer { if cleanup { try? FileManager.default.removeItem(at: bodyFile) } }
            let (data, resp) = try await Self.withNetworkRetry { try await self.http.upload(for: req, fromFile: bodyFile, delegate: delegate) }
            guard let h = resp as? HTTPURLResponse else { throw ICloudError.http(0, "No response") }
            absorb(h)
            if (h.statusCode == 401 || h.statusCode == 421) && !reauthed { reauthed = true; try await reauthenticate(); continue }
            let json = (try? JSON(data: data)) ?? .null
            guard (200..<300).contains(h.statusCode) else { throw ICloudError.http(h.statusCode, Self.errorMessage(json) ?? "Upload failed") }
            return json
        }
    }
}

extension ICloudSession {
    /// Retries transient network failures (Wi-Fi drop, sleep/wake, timeouts) with back-off.
    static func withNetworkRetry<T>(_ op: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await op() } catch let e as URLError {
                let transient: Set<URLError.Code> = [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                                                     .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .internationalRoamingOff]
                if e.code == .cancelled { throw ICloudError.cancelled }
                guard transient.contains(e.code), attempt < 4 else { throw e }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt - 1)) * 500_000_000))
            }
        }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let expected: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    init(expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.expected = expected; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : expected)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

enum Multipart {
    /// Streams a multipart/form-data body into a temp file without loading the source into memory.
    static func write(file: URL, fieldName: String, filename: String, mime: String, boundary: String) throws -> URL {
        let out = Paths.tempFile(named: "upload.multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        let esc = filename.replacingOccurrences(of: "\"", with: "%22")
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName.replacingOccurrences(of: "\"", with: "%22"))\"; filename=\"\(esc)\"\r\nContent-Type: \(mime)\r\n\r\n"
        try h.write(contentsOf: Data(head.utf8))
        let src = try FileHandle(forReadingFrom: file)
        defer { try? src.close() }
        while let chunk = try src.read(upToCount: 4 << 20), !chunk.isEmpty { try h.write(contentsOf: chunk) }
        try h.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}
