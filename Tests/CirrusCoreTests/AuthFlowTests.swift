import Foundation
import Testing
@testable import CirrusCore

/// A scripted stand-in for idmsa.apple.com / setup.icloud.com so the sign-in state machine
/// can be tested without a real Apple ID.
final class MockApple: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var json: Any? = nil }
    nonisolated(unsafe) static var routes: [String: Reply] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()

    static func reset(_ r: [String: Reply]) { lock.withLock { routes = r; calls = [] } }
    static var log: [String] { lock.withLock { calls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "cvws.example.com" { serveContent(); return }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let reply: Reply = MockApple.lock.withLock {
            MockApple.calls.append(key)
            return MockApple.routes[key] ?? Reply(status: 404)
        }
        let body = reply.json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// Content host for downloader tests: the body is the first path component, after a random delay.
    func serveContent() {
        let name = request.url?.pathComponents.dropFirst().first ?? "?"
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 1...40))) {
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(name.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite(.serialized) struct AuthFlowTests {
    static var initReply: MockApple.Reply {
        let B = AppleSRPClient.g.power(BigUInt(12345), modulus: AppleSRPClient.N).serialize(paddedTo: 256)
        return .init(status: 200, json: ["b": Data(B).base64EncodedString(), "salt": Data([1, 2, 3, 4, 5, 6, 7, 8]).base64EncodedString(),
                                         "iteration": 1000, "protocol": "s2k", "c": "challenge"])
    }
    static let base: [String: MockApple.Reply] = [
        "GET /appleauth/auth/authorize/signin": .init(status: 200, headers: ["scnt": "s1", "X-Apple-ID-Session-Id": "sess"]),
        "POST /appleauth/auth/federate": .init(status: 200),
        "POST /appleauth/auth/signin/init": initReply,
    ]
    static let loginOK: MockApple.Reply = .init(status: 200, headers: ["Set-Cookie": "X-APPLE-WEBAUTH-TOKEN=abc; Domain=.icloud.com; Path=/; Secure"],
                                                json: ["dsInfo": ["dsid": "123", "hsaVersion": 2, "fullName": "Test User"], "hsaChallengeRequired": false,
                                                       "webservices": ["drivews": ["url": "https://p1-drivews.icloud.com", "status": "active"]]])
    static let loginNeeds2FA: MockApple.Reply = .init(status: 200, json: ["dsInfo": ["dsid": "123", "hsaVersion": 2], "hsaChallengeRequired": true, "webservices": [:]])

    func session() -> ICloudSession {
        ICloudSession.testProtocolClasses = [MockApple.self]
        return ICloudSession(state: SessionState(appleID: "Someone@Example.com"))
    }

    @Test func repair412With204ThenSignsIn() async throws {
        var r = Self.base
        r["POST /appleauth/auth/signin/complete"] = .init(status: 412, headers: ["X-Apple-Session-Token": "tok"])
        r["POST /appleauth/auth/repair/complete"] = .init(status: 204)
        r["POST /setup/ws/1/accountLogin"] = Self.loginOK
        MockApple.reset(r)
        let s = session()
        let outcome = try await s.signIn(password: "pw")
        guard case .signedIn = outcome else { Issue.record("expected signedIn, got \(outcome)"); return }
        #expect(MockApple.log.contains("POST /appleauth/auth/repair/complete"))
        #expect(MockApple.log.last == "POST /setup/ws/1/accountLogin")
        #expect(await s.dsid == "123")
        #expect(await s.hasCookies(["X-APPLE-WEBAUTH-TOKEN"]))
    }

    @Test func repair412ThenStillNeedsCode() async throws {
        var r = Self.base
        r["POST /appleauth/auth/signin/complete"] = .init(status: 412, headers: ["X-Apple-Session-Token": "tok"])
        r["POST /appleauth/auth/repair/complete"] = .init(status: 204)
        r["POST /setup/ws/1/accountLogin"] = Self.loginNeeds2FA
        r["GET /appleauth/auth"] = .init(status: 200, json: ["trustedPhoneNumbers": [["id": 1, "numberWithDialCode": "+1 (•••) •••-••12", "pushMode": "sms"]]])
        r["PUT /appleauth/auth/verify/trusteddevice/securitycode"] = .init(status: 202)
        MockApple.reset(r)
        let outcome = try await session().signIn(password: "pw")
        guard case .needsCode(let phones, let device) = outcome else { Issue.record("expected needsCode, got \(outcome)"); return }
        #expect(device && phones.count == 1)
        #expect(MockApple.log.contains("PUT /appleauth/auth/verify/trusteddevice/securitycode"))
    }

    @Test func twoFactorThenTrustAndLogin() async throws {
        var r = Self.base
        r["POST /appleauth/auth/signin/complete"] = .init(status: 409, headers: ["X-Apple-Session-Token": "tok"])
        r["GET /appleauth/auth"] = .init(status: 200, json: ["trustedPhoneNumbers": []])
        r["PUT /appleauth/auth/verify/trusteddevice/securitycode"] = .init(status: 202)
        // mid-2026 behaviour: accepted codes can come back as 409 with a session token
        r["POST /appleauth/auth/verify/trusteddevice/securitycode"] = .init(status: 409, headers: ["X-Apple-Session-Token": "tok2"])
        r["GET /appleauth/auth/2sv/trust"] = .init(status: 204, headers: ["X-Apple-TwoSV-Trust-Token": "trust"])
        r["POST /setup/ws/1/accountLogin"] = Self.loginOK
        MockApple.reset(r)
        let s = session()
        guard case .needsCode = try await s.signIn(password: "pw") else { Issue.record("expected code step"); return }
        try await s.submitCode("123456")
        #expect(await s.state.trustToken == "trust")
        #expect(await s.dsid == "123")
    }

    @Test func wrongPasswordIsReported() async throws {
        var r = Self.base
        r["POST /appleauth/auth/signin/complete"] = .init(status: 401, json: ["serviceErrors": [["code": "-20101", "message": "Your Apple ID or password was incorrect."]]])
        MockApple.reset(r)
        await #expect(throws: ICloudError.badCredentials) { _ = try await session().signIn(password: "nope") }
    }
}

/// Regression: concurrent first downloads must each get their own bytes.
@Suite(.serialized) struct DownloaderTests {
    @Test func concurrentDownloadsNeverCross() async throws {
        ICloudSession.testProtocolClasses = [MockApple.self]
        let s = ICloudSession(state: SessionState(appleID: "x@example.com"))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<24 {
                g.addTask {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
                    try await s.download(from: "https://cvws.example.com/item\(i)/${f}?k=\(i)", to: dest, expectedSize: nil) { _, _ in }
                    let body = try String(contentsOf: dest, encoding: .utf8)
                    #expect(body == "item\(i)", "download \(i) got \(body)")
                    try? FileManager.default.removeItem(at: dest)
                }
            }
            try await g.waitForAll()
        }
    }
}
