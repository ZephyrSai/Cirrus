import CryptoKit
import Foundation
import Testing
@testable import CirrusCore

/// The S3 connector: SigV4 against AWS's published vectors, then everything against FakeS3Server (shared state, so
/// one test at a time).
@Suite(.serialized) struct S3Tests {
    typealias Fake = FakeS3Server
    static let transport: [AnyClass] = [FakeS3Server.self]

    // MARK: Helpers

    static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-s3-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func file(_ data: Data, _ name: String = "upload.bin") throws -> URL {
        let u = tempDir("src").appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    static func bytes(_ n: Int, seed: Int = 7) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* seed &+ ($0 >> 8)) }) }

    /// A bucket "cirrus-test": Documents/ (with a marker), Photos/ (no marker, only keys), Readme.txt, and a nested folder.
    static func testState(pageSize: Int = 2) -> Fake.State {
        var s = Fake.State()
        s.pageSize = pageSize
        s.minPartSize = 64 * 1024
        let b = "cirrus-test"
        s.addBucket(b)
        s.put(b, "Readme.txt", Data("hello\n".utf8))
        s.put(b, "Documents/")
        s.put(b, "Documents/a.txt", Data("a".utf8))
        s.put(b, "Documents/b.txt", Data("bb".utf8))
        s.put(b, "Documents/c.csv", Data("c,c\n".utf8))
        s.put(b, "Documents/Sub/deep.txt", Data("deep".utf8))
        s.put(b, "Photos/one.jpg", Data(count: 300))
        s.put(b, "Photos/two.jpg", Data(count: 400))
        s.addBucket("other-bucket")
        s.put("other-bucket", "note.txt", Data("other".utf8))
        s.addBucket("ireland", region: "eu-west-1")
        s.put("ireland", "dublin.txt", Data("eu".utf8))
        return s
    }

    static func record(endpoint: String = "https://s3.us-east-1.amazonaws.com", bucket: String? = "cirrus-test", region: String = "us-east-1",
                       pathStyle: String? = nil, key: String = Fake.accessKey) -> CloudAccountRecord {
        var o = ["region": region]
        if let bucket { o["bucket"] = bucket }
        if let pathStyle { o["pathStyle"] = pathStyle }
        return CloudAccountRecord(id: "cloud:s3:test", provider: .s3, title: "\(bucket ?? key) @ test", server: endpoint, username: key, options: o)
    }

    func backend(_ s: Fake.State = S3Tests.testState(), _ r: CloudAccountRecord = S3Tests.record(), secret: String = Fake.secretKey) throws -> S3Backend {
        Fake.reset(s)
        let b = try S3Backend(record: r, secretKey: secret, transport: Self.transport)
        b.retryBase = 0.001
        b.concurrency = 3
        return b
    }

    func caught(_ op: () async throws -> Void) async -> Error? {
        do { try await op(); return nil } catch { return error }
    }

    func message(_ e: Error?) -> String { (e as? LocalizedError)?.errorDescription ?? String(describing: e) }

    func deniedMessage(_ e: Error?) -> String? {
        if case .denied(let m)? = e as? CloudError { return m }
        return nil
    }

    func node(_ d: S3Backend, _ folder: String, _ name: String) async throws -> DriveNode {
        try #require(try await d.list(folder).first { $0.name == name.precomposedStringWithCanonicalMapping }, "\(name) in \(folder)")
    }

    func waitFor(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: SigV4 (AWS's published vectors)

    /// From AWS's SigV4 test suite (aws-sig-v4-test-suite / aws-c-auth): AKIDEXAMPLE, us-east-1, service "service",
    /// 2015-08-30T12:36:00Z, unsigned-body hashes of the empty body unless noted.
    @Test func sigV4TestSuiteVectors() {
        let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        let date = "20150830T123600Z"
        func sig(_ method: String, _ path: String, _ query: [(String, String?)] = [], extra: [(String, String)] = []) -> S3Signer.Signature {
            S3Signer.sign(method: method, canonicalURI: S3Signer.encode(path, slash: false), canonicalQuery: S3Signer.canonicalQuery(query),
                          headers: [("Host", "example.amazonaws.com"), ("X-Amz-Date", date)] + extra, payloadHash: S3Signer.emptyHash,
                          amzDate: date, region: "us-east-1", service: "service", accessKey: "AKIDEXAMPLE", secretKey: secret)
        }
        let vanilla = sig("GET", "/")
        #expect(vanilla.signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        #expect(vanilla.authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        #expect(vanilla.canonicalRequest == "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" + S3Signer.emptyHash)
        #expect(vanilla.stringToSign == "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n"
                + "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
        // get-vanilla-query-order-key-case: parameters sorted by name.
        #expect(sig("GET", "/", [("Param2", "value2"), ("Param1", "value1")]).signature == "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
        #expect(sig("POST", "/").signature == "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")
        // get-utf8: the path's UTF-8 bytes percent-encoded once.
        let utf8 = sig("GET", "/ሴ")
        #expect(utf8.canonicalRequest.split(separator: "\n", omittingEmptySubsequences: false)[1] == "/%E1%88%B4")
        #expect(utf8.signature == "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85")
        #expect(sig("GET", "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").signature
                == "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f")
        #expect(sig("GET", "/", [("ሴ", "bar")]).signature == "2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04")
        // get-header-value-trim: values trimmed, inner runs of spaces collapsed (even inside quotes).
        let trim = sig("GET", "/", extra: [("My-Header1", " value1"), ("My-Header2", " \"a   b   c\"")])
        #expect(trim.canonicalRequest == "GET\n/\n\nhost:example.amazonaws.com\nmy-header1:value1\nmy-header2:\"a b c\"\nx-amz-date:20150830T123600Z\n\n"
                + "host;my-header1;my-header2;x-amz-date\n" + S3Signer.emptyHash)
        #expect(trim.signature == "acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736")
        // The signing-key example from AWS's documentation (IAM, 2012-02-15).
        let key = S3Signer.signingKey(secret: secret, day: "20120215", region: "us-east-1", service: "iam")
        #expect(key.withUnsafeBytes { S3Signer.hex(Data($0)) } == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    /// The four worked examples in S3's "Signature Calculations for the Authorization Header (single chunk)":
    /// AKIAIOSFODNN7EXAMPLE, us-east-1, 2013-05-24, bucket "examplebucket" (virtual-hosted).
    @Test func sigV4S3DocumentationExamples() {
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let date = "20130524T000000Z"
        func sig(_ method: String, _ key: String, _ query: [(String, String?)] = [], extra: [(String, String)] = [], hash: String = S3Signer.emptyHash) -> S3Signer.Signature {
            S3Signer.sign(method: method, canonicalURI: "/" + S3Signer.encode(key, slash: false), canonicalQuery: S3Signer.canonicalQuery(query),
                          headers: [("Host", "examplebucket.s3.amazonaws.com"), ("x-amz-date", date), ("x-amz-content-sha256", hash)] + extra,
                          payloadHash: hash, amzDate: date, region: "us-east-1", accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: secret)
        }
        // GET Object with a Range header.
        let get = sig("GET", "test.txt", extra: [("Range", "bytes=0-9")])
        #expect(S3Signer.sha256Hex(Data(get.canonicalRequest.utf8)) == "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        #expect(get.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        // PUT Object: "$" in the key, a Date header, a storage class, and the body's hash.
        let body = Data("Welcome to Amazon S3.".utf8)
        let hash = S3Signer.sha256Hex(body)
        #expect(hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let put = sig("PUT", "test$file.text", extra: [("Date", "Fri, 24 May 2013 00:00:00 GMT"), ("x-amz-storage-class", "REDUCED_REDUNDANCY")], hash: hash)
        #expect(put.canonicalRequest.hasPrefix("PUT\n/test%24file.text\n\n"))
        #expect(put.signedHeaders == "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class")
        #expect(put.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
        // GET Bucket lifecycle: a sub-resource without a value is "lifecycle=".
        let lifecycle = sig("GET", "", [("lifecycle", nil)])
        #expect(lifecycle.canonicalRequest.hasPrefix("GET\n/\nlifecycle=\n"))
        #expect(lifecycle.signature == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        // GET Bucket (list objects).
        #expect(sig("GET", "", [("prefix", "J"), ("max-keys", "2")]).signature == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func uriEncodingAndQueryRules() {
        #expect(S3Signer.encode("a b/c+d%~é", slash: false) == "a%20b/c%2Bd%25~%C3%A9")
        #expect(S3Signer.encode("a/b", slash: true) == "a%2Fb")
        #expect(S3Signer.encode("#?&=;:@!$'()*,", slash: false) == "%23%3F%26%3D%3B%3A%40%21%24%27%28%29%2A%2C")
        #expect(S3Signer.canonicalQuery([("uploads", nil)]) == "uploads=")
        #expect(S3Signer.canonicalQuery([("prefix", "a b/"), ("list-type", "2"), ("b", "2"), ("b", "1")]) == "b=1&b=2&list-type=2&prefix=a%20b%2F")
        #expect(S3Signer.decode("a%20b%2Bc+d") == "a b+c+d")
        #expect(S3Signer.queryItems("uploads&x=a%2Fb&y=") .map { "\($0.0)=\($0.1 ?? "nil")" } == ["uploads=nil", "x=a/b", "y="])
        #expect(S3Signer.amzDate(Date(timeIntervalSince1970: 1_440_938_160)) == "20150830T123600Z")
        #expect(S3Signer.parseAmzDate("20150830T123600Z") == Date(timeIntervalSince1970: 1_440_938_160))
        let p = S3Signer.parse(authorization: "AWS4-HMAC-SHA256 Credential=AK/20150830/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=abc")
        #expect(p?.accessKey == "AK" && p?.region == "us-east-1" && p?.signedHeaders == ["host", "x-amz-date"] && p?.signature == "abc")
        // Keys are compared as bytes: a decomposed "é" isn't a precomposed one, and "/" + combining mark still splits.
        #expect(!S3Key.same("Caf\u{E9}", "Cafe\u{301}"))
        #expect(S3Key.hasPrefix("Cafe\u{301}/x", "Cafe"))
        #expect(S3Key.lastSegment("a/\u{301}b/") == "\u{301}b" && S3Key.parent("a/\u{301}b/") == "a/")
        #expect(S3Key.childPrefix("a/b/c", after: "a/") == "a/b/" && S3Key.childPrefix("a/b", after: "a/") == nil)
    }

    @Test func endpointsAndRegions() throws {
        let b2 = try S3Endpoint.parse("s3.us-west-004.backblazeb2.com")
        #expect(b2.endpoint.string == "https://s3.us-west-004.backblazeb2.com" && b2.path == "")
        #expect(try S3Endpoint.parse("HTTPS://S3.Example.com:443/").endpoint.string == "https://s3.example.com")
        #expect(try S3Endpoint.parse("http://localhost:9000").endpoint.string == "http://localhost:9000")
        #expect(throws: CloudError.self) { _ = try S3Endpoint.parse("http://minio.example.com:9000") }
        #expect(throws: CloudError.self) { _ = try S3Endpoint.parse("ftp://x.example.com") }
        #expect(throws: CloudError.self) { _ = try S3Endpoint.parse("  ") }
        let regions: [(String, String?)] = [
            ("s3.amazonaws.com", "us-east-1"), ("s3.us-west-2.amazonaws.com", "us-west-2"), ("s3-eu-west-1.amazonaws.com", "eu-west-1"),
            ("s3.dualstack.ap-south-1.amazonaws.com", "ap-south-1"), ("photos.s3.eu-central-1.amazonaws.com", "eu-central-1"),
            ("s3-external-1.amazonaws.com", "us-east-1"), ("s3.us-west-004.backblazeb2.com", "us-west-004"),
            ("s3.eu-central-1.wasabisys.com", "eu-central-1"), ("s3.wasabisys.com", "us-east-1"), ("s3.fr-par.scw.cloud", "fr-par"),
            ("abc123.r2.cloudflarestorage.com", "auto"), ("abc123.eu.r2.cloudflarestorage.com", "auto"), ("minio.local", nil),
        ]
        for (host, want) in regions { #expect(S3Endpoint.inferredRegion(host: host) == want, "\(host)") }
        #expect(S3Endpoint.signingRegion("auto", host: "abc.r2.cloudflarestorage.com") == "auto")
        #expect(S3Endpoint.signingRegion("auto", host: "127.0.0.1") == "us-east-1")
        #expect(S3Endpoint.signingRegion("", host: "s3.eu-west-1.amazonaws.com") == "eu-west-1")
        #expect(S3Endpoint.signingRegion(" EU-West-3 ", host: "s3.amazonaws.com") == "eu-west-3")
        #expect(S3Endpoint.splitBucketHost("photos.s3.us-west-2.amazonaws.com")! == ("photos", "s3.us-west-2.amazonaws.com"))
        #expect(S3Endpoint.splitBucketHost("my.dotted.bucket.s3.amazonaws.com")! == ("my.dotted.bucket", "s3.amazonaws.com"))
        #expect(S3Endpoint.splitBucketHost("s3.us-west-2.amazonaws.com") == nil)
        #expect(S3Endpoint.splitBucketHost("bucket.minio.local") == nil)
        #expect(S3Endpoint.virtualHostable("photos-2026") && !S3Endpoint.virtualHostable("my.bucket") && !S3Endpoint.virtualHostable("Upper"))
    }

    // MARK: Connect

    @Test func connectAWSStyleUsesVirtualHostedAddresses() async throws {
        Fake.reset(Self.testState())
        let (record, secret) = try await S3Storage.connect(endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "cirrus-test",
                                                           accessKey: " \(Fake.accessKey) ", secretKey: Fake.secretKey, transport: Self.transport)
        #expect(record.provider == .s3)
        #expect(record.title == "cirrus-test @ s3.us-east-1.amazonaws.com")
        #expect(record.server == "https://s3.us-east-1.amazonaws.com")
        #expect(record.username == Fake.accessKey)
        #expect(record.options == ["region": "us-east-1", "bucket": "cirrus-test", "pathStyle": "0"])
        #expect(secret == CloudSecret(password: Fake.secretKey))
        #expect(Fake.state.hosts.last == "cirrus-test.s3.us-east-1.amazonaws.com")
        #expect(Fake.state.calls.last?.hasPrefix("GET cirrus-test ?") == true)
        let d = try #require(try S3Storage.make(record: record, secret: secret, transport: Self.transport) as? S3Backend)
        #expect(d.rootID == "s3:/cirrus-test/")
        #expect(try await d.list(d.rootID).contains { $0.name == "Readme.txt" })
        #expect(Fake.state.hosts.last == "cirrus-test.s3.us-east-1.amazonaws.com")
        // The bucket written into the address, and no bucket at all (ListBuckets).
        let fromHost = try await S3Storage.connect(endpoint: "cirrus-test.s3.us-east-1.amazonaws.com", region: "", bucket: nil,
                                                   accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(fromHost.record.options?["bucket"] == "cirrus-test" && fromHost.record.server == "https://s3.us-east-1.amazonaws.com")
        #expect(fromHost.record.options?["region"] == "us-east-1")
        let all = try await S3Storage.connect(endpoint: "s3.us-east-1.amazonaws.com", region: "", bucket: "  ", accessKey: Fake.accessKey,
                                              secretKey: Fake.secretKey, transport: Self.transport)
        #expect(all.record.options == ["region": "us-east-1"])
        #expect(all.record.title == "\(Fake.accessKey) @ s3.us-east-1.amazonaws.com")
        #expect(Fake.state.calls.last == "GET - ")
        // A bucket in another region: found, and saved with its region.
        let ireland = try await S3Storage.connect(endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "ireland",
                                                  accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(ireland.record.options?["region"] == "eu-west-1")
        #expect(Fake.state.hosts.last == "ireland.s3.eu-west-1.amazonaws.com")
        let id = try #require(try S3Storage.make(record: ireland.record, secret: ireland.secret, transport: Self.transport) as? S3Backend)
        #expect(try await id.list(id.rootID).map(\.name) == ["dublin.txt"])
    }

    @Test func connectB2R2WasabiAndMinIOStyleEndpoints() async throws {
        var s = Self.testState()
        for b in ["b2-bucket", "r2-bucket", "wasabi-bucket", "minio-bucket"] { s.put(b, "hello.txt", Data(b.utf8)) }
        Fake.reset(s)
        // Backblaze B2: no scheme typed, region from the host, path-style.
        let b2 = try await S3Storage.connect(endpoint: "s3.us-west-004.backblazeb2.com", region: "", bucket: "b2-bucket",
                                             accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(b2.record.server == "https://s3.us-west-004.backblazeb2.com")
        #expect(b2.record.options == ["region": "us-west-004", "bucket": "b2-bucket", "pathStyle": "1"])
        #expect(b2.record.title == "b2-bucket @ s3.us-west-004.backblazeb2.com")
        #expect(Fake.state.hosts.last == "s3.us-west-004.backblazeb2.com")
        // Cloudflare R2: the address its dashboard shows (bucket in the path), region "auto".
        let r2 = try await S3Storage.connect(endpoint: "https://fakeaccount0123.r2.cloudflarestorage.com/r2-bucket", region: "auto", bucket: nil,
                                             accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(r2.record.server == "https://fakeaccount0123.r2.cloudflarestorage.com")
        #expect(r2.record.options == ["region": "auto", "bucket": "r2-bucket", "pathStyle": "1"])
        // Wasabi and a MinIO on this Mac (plain http is fine for localhost).
        let wasabi = try await S3Storage.connect(endpoint: "https://s3.eu-central-1.wasabisys.com", region: "eu-central-1", bucket: "wasabi-bucket",
                                                 accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(wasabi.record.options?["pathStyle"] == "1")
        let minio = try await S3Storage.connect(endpoint: "http://127.0.0.1:9000/", region: "", bucket: "minio-bucket",
                                                accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(minio.record.server == "http://127.0.0.1:9000")
        #expect(minio.record.title == "minio-bucket @ 127.0.0.1:9000")
        #expect(minio.record.options?["region"] == "us-east-1")
        for (rec, sec, name) in [(b2.record, b2.secret, "b2-bucket"), (r2.record, r2.secret, "r2-bucket"), (wasabi.record, wasabi.secret, "wasabi-bucket"),
                                 (minio.record, minio.secret, "minio-bucket")] {
            let d = try S3Storage.make(record: rec, secret: sec, transport: Self.transport)
            let hello = try #require(try await d.list(d.rootID).first { $0.name == "hello.txt" }, "\(name)")
            let dest = Self.tempDir("conn").appendingPathComponent("h")
            try await d.download(hello, to: dest) { _, _ in }
            #expect(try Data(contentsOf: dest) == Data(name.utf8))
        }
        #expect(Fake.state.signatureFailures == 0 && Fake.state.regionRejections == 0)
    }

    @Test func connectGivesClearErrors() async throws {
        var s = Self.testState()
        s.credentials["SCOPEDKEY"] = Fake.Credential(secret: "scoped-secret", canListBuckets: false, buckets: ["cirrus-test"])
        Fake.reset(s)
        func connect(_ bucket: String?, key: String = Fake.accessKey, secret: String = Fake.secretKey, endpoint: String = "https://s3.us-east-1.amazonaws.com") async -> Error? {
            await caught { _ = try await S3Storage.connect(endpoint: endpoint, region: "us-east-1", bucket: bucket, accessKey: key, secretKey: secret,
                                                           transport: Self.transport) }
        }
        let badSecret = await connect("cirrus-test", secret: "wrong")
        #expect(deniedMessage(badSecret)?.contains("secret access key doesn’t match") == true, "\(message(badSecret))")
        let badKey = await connect("cirrus-test", key: "AKIANOTKNOWN")
        #expect(deniedMessage(badKey)?.contains("doesn’t know the access key ID “AKIANOTKNOWN”") == true, "\(message(badKey))")
        let noBucket = await connect("no-such-bucket")
        if case .notConfigured(let m)? = noBucket as? CloudError { #expect(m.contains("no bucket named “no-such-bucket”")) } else { Issue.record("\(message(noBucket))") }
        let cantList = await connect(nil, key: "SCOPEDKEY", secret: "scoped-secret")
        #expect(deniedMessage(cantList)?.contains("Enter the name of the bucket") == true, "\(message(cantList))")
        #expect(await connect("cirrus-test", key: "SCOPEDKEY", secret: "scoped-secret") == nil)
        let notAllowed = await connect("other-bucket", key: "SCOPEDKEY", secret: "scoped-secret")
        #expect(deniedMessage(notAllowed)?.contains("aren’t allowed to list the bucket “other-bucket”") == true, "\(message(notAllowed))")
        #expect(await connect("cirrus-test", key: " ") as? CloudError != nil)
        #expect(await connect("a/b") as? CloudError != nil)
        // Unknown hosts fail without leaving the fake; plain http elsewhere is refused before any request.
        #expect(await connect("cirrus-test", endpoint: "https://s3.nowhere.invalid") != nil)
        Fake.update { $0.calls = [] }
        #expect(await connect("cirrus-test", endpoint: "http://s3.us-east-1.amazonaws.com") != nil)
        #expect(Fake.state.calls.isEmpty)
        #expect(Fake.state.signatureFailures == 1)
    }


    // MARK: Listing

    @Test func listingShowsPrefixesMarkersAndPages() async throws {
        let d = try backend()
        let top = try await d.list(d.rootID)
        #expect(Set(top.map(\.name)) == ["Documents", "Photos", "Readme.txt"])
        for n in top {
            #expect(n.parentID == d.rootID)
            #expect(n.zone == "s3")
            #expect(n.isFolder == n.id.hasSuffix("/"))
            #expect(n.type == (n.isFolder ? "FOLDER" : "FILE"))
        }
        let readme = try #require(top.first { $0.name == "Readme.txt" })
        let server = try #require(Fake.state.object("cirrus-test", "Readme.txt"))
        #expect(readme.id == "s3:/cirrus-test/Readme.txt")
        #expect(readme.size == 6)
        #expect(readme.etag == server.etag)
        #expect(readme.modified == Date(timeIntervalSince1970: server.modified.timeIntervalSince1970.rounded(.down)))
        // Documents has a marker (hidden as a file), Photos only keys; pages of two entries.
        let docs = try await d.list("s3:/cirrus-test/Documents/")
        #expect(Set(docs.map(\.name)) == ["a.txt", "b.txt", "c.csv", "Sub"])
        #expect(docs.allSatisfy { $0.parentID == "s3:/cirrus-test/Documents/" })
        #expect(docs.first { $0.name == "Sub" }?.id == "s3:/cirrus-test/Documents/Sub/")
        #expect(Set(try await d.list("s3:/cirrus-test/Photos/").map(\.name)) == ["one.jpg", "two.jpg"])
        #expect(Fake.state.listRequests >= 4)
        let many = try await d.listMany(["s3:/cirrus-test/Documents/", "s3:/cirrus-test/Photos/", "s3:/cirrus-test/Documents/"])
        #expect(Set(many.keys) == ["s3:/cirrus-test/Documents/", "s3:/cirrus-test/Photos/"])
        let all = try await d.walk(d.rootID)
        #expect(Set(all.map(\.path)) == ["Documents", "Documents/a.txt", "Documents/b.txt", "Documents/c.csv", "Documents/Sub", "Documents/Sub/deep.txt",
                                         "Photos", "Photos/one.jpg", "Photos/two.jpg", "Readme.txt"])
        // A folder with only its marker is empty; a folder with nothing at all is gone.
        Fake.update { $0.put("cirrus-test", "Empty/") }
        #expect(try await d.list("s3:/cirrus-test/Empty/").isEmpty)
        #expect(await caught { _ = try await d.list("s3:/cirrus-test/Nothing/") } as? CloudError == .notFound)
        // The deleted-items folder never shows in the bucket.
        Fake.update { $0.put("cirrus-test", ".cirrus-deleted/x.txt", Data("x".utf8)) }
        #expect(!(try await d.list(d.rootID)).contains { $0.name == ".cirrus-deleted" })
        // IDs of another bucket aren't this account's.
        #expect(await caught { _ = try await d.list("s3:/other-bucket/") } as? CloudError == .notFound)
    }

    static let oddNames = ["a b.txt", "hash #1.txt", "100% done.txt", "what?.txt", "c++ & more.txt", "Cafe\u{301} u\u{308}nicode.txt", "Caf\u{E9} nfc.txt",
                           "日本語のファイル.txt", "semi;colon=eq,comma.txt", "it's (1) [x] {y}.txt", "  leading spaces.txt", "plus+sign+.txt",
                           "trailing dot.", "emoji 🎉.txt", "tab\there.txt", "back\\slash.txt", "<angle> \"quotes\".txt"]

    @Test func oddKeysSurviveEveryStep() async throws {
        for (endpoint, ps) in [("https://s3.us-east-1.amazonaws.com", nil), ("https://s3.us-east-1.amazonaws.com", "1"), ("http://127.0.0.1:9000", nil)] {
            var s = Self.testState(pageSize: 3)
            let folder = "Odd #2 & Ünïcode%20 +folder?"
            for n in Self.oddNames { s.put("cirrus-test", folder + "/" + n, Data(n.utf8)) }
            let d = try backend(s, Self.record(endpoint: endpoint, pathStyle: ps))
            let odd = try await node(d, d.rootID, folder)
            let items = try await d.list(odd.id)
            #expect(Set(items.map(\.name)) == Set(Self.oddNames.map(\.precomposedStringWithCanonicalMapping)), "\(endpoint)")
            #expect(items.count == Self.oddNames.count)
            for item in items {
                #expect(item.parentID == odd.id)
                let dest = Self.tempDir("odd").appendingPathComponent("f")
                try await d.download(item, to: dest) { _, _ in }
                #expect(S3Key.same(String(decoding: try Data(contentsOf: dest), as: UTF8.self), S3Key.lastSegment(String(item.id.dropFirst("s3:/cirrus-test/".count)))))
            }
            let up = try await d.upload(try Self.file(Data("new".utf8)), name: "new #?%+&=.txt", into: odd.id, modified: nil) { _, _ in }
            #expect(up.name == "new #?%+&=.txt")
            #expect(Fake.state.object("cirrus-test", folder + "/new #?%+&=.txt")?.data == Data("new".utf8))
            let renamed = try await d.rename(up, to: "renamed ü #2+.txt")
            #expect(try await d.list(odd.id).contains { $0.id == renamed.id && $0.name == "renamed ü #2+.txt" })
            let sub = try await d.createFolder("sub & dir # +", in: odd.id)
            try await d.move([renamed], to: sub.id)
            #expect(try await d.list(sub.id).map(\.name) == ["renamed ü #2+.txt"])
            #expect(Fake.state.signatureFailures == 0, "\(endpoint)")
        }
    }

    @Test func keysXMLCannotCarryComeURLEncoded() async throws {
        var s = Self.testState()
        s.put("cirrus-test", "Weird/bell\u{7}.txt", Data("ding".utf8))
        s.put("cirrus-test", "Weird/plus+ and space.txt", Data("p".utf8))
        let d = try backend(s)
        let items = try await d.list("s3:/cirrus-test/Weird/")
        #expect(Set(items.map(\.name)) == ["bell\u{7}.txt", "plus+ and space.txt"])
        #expect(Fake.state.calls.contains { $0.contains("encoding-type") })
        let bell = try #require(items.first { $0.name.hasPrefix("bell") })
        let dest = Self.tempDir("bell").appendingPathComponent("b")
        try await d.download(bell, to: dest) { _, _ in }
        #expect(try Data(contentsOf: dest) == Data("ding".utf8))
    }

    @Test func failedListingsThrowInsteadOfLookingEmpty() async throws {
        var s = Self.testState(pageSize: 1)
        s.truncateListings = ["Documents/"]
        s.tokenlessListings = ["Photos/"]
        let d = try backend(s)
        #expect(await caught { _ = try await d.list("s3:/cirrus-test/Documents/") } != nil)
        let cut = await caught { _ = try await d.list("s3:/cirrus-test/Photos/") }
        #expect(message(cut).contains("short"))
        #expect(await caught { _ = try await d.listMany([d.rootID, "s3:/cirrus-test/Photos/"]) } != nil)
        #expect(await caught { _ = try await d.walk(d.rootID) } != nil)
        Fake.update { $0.internalErrorNext = 100 }
        let busy = await caught { _ = try await d.list(d.rootID) }
        #expect(message(busy).contains("busy"))
        Fake.update { $0.internalErrorNext = 0 }
    }

    @Test func busyServersAndDroppedConnectionsAreRetried() async throws {
        let d = try backend()
        Fake.update { $0.slowDownNext = 2; $0.internalErrorNext = 1; $0.dropNext = 1 }
        #expect(try await d.list(d.rootID).count == 3)
        Fake.update { $0.slowDownNext = 1; $0.dropNext = 1 }
        let up = try await d.upload(try Self.file(Data("retry".utf8)), name: "retried.txt", into: d.rootID, modified: nil) { _, _ in }
        #expect(up.size == 5)
        #expect(Fake.state.object("cirrus-test", "retried.txt")?.data == Data("retry".utf8))
    }

    // MARK: Transfers

    @Test func smallUploadAndDownloadKeepTheDate() async throws {
        let d = try backend()
        let data = Self.bytes(70_000)
        let mtime = Date(timeIntervalSince1970: 1_700_000_123)
        let progress = DAVProgressBox()
        let up = try await d.upload(try Self.file(data), name: "photo.jpg", into: "s3:/cirrus-test/Photos/", modified: mtime) { a, b in progress.note(a, b) }
        #expect(up.id == "s3:/cirrus-test/Photos/photo.jpg")
        #expect(up.parentID == "s3:/cirrus-test/Photos/")
        #expect(up.size == 70_000)
        #expect(progress.last.0 == 70_000)
        let o = try #require(Fake.state.object("cirrus-test", "Photos/photo.jpg"))
        #expect(o.data == data)
        #expect(o.contentType == "image/jpeg")
        #expect(o.meta["x-amz-meta-mtime"] == "1700000123")
        #expect(up.etag == o.etag)
        #expect(Fake.state.lastUserAgent?.hasPrefix("Cirrus") == true)
        // The node it returns matches what a listing says.
        let listed = try await node(d, "s3:/cirrus-test/Photos/", "photo.jpg")
        #expect(listed.id == up.id && listed.size == up.size && listed.etag == up.etag && listed.modified == up.modified)
        let dest = Self.tempDir("dl").appendingPathComponent("photo.jpg")
        let dp = DAVProgressBox()
        try await d.download(listed, to: dest) { a, b in dp.note(a, b) }
        #expect(try Data(contentsOf: dest) == data)
        #expect(dp.last.0 == 70_000)
        let m = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(m == mtime)
        // Without the note, the object's Last-Modified.
        let readme = try await node(d, d.rootID, "Readme.txt")
        let rd = Self.tempDir("dl").appendingPathComponent("r")
        try await d.download(readme, to: rd) { _, _ in }
        let rm = try FileManager.default.attributesOfItem(atPath: rd.path)[.modificationDate] as? Date
        #expect(rm == Date(timeIntervalSince1970: 1_790_000_000))
        // A missing object is notFound; a folder can't be downloaded.
        var gone = readme
        gone.id = "s3:/cirrus-test/gone.txt"
        #expect(await caught { try await d.download(gone, to: rd) { _, _ in } } as? CloudError == .notFound)
        #expect(await caught { try await d.download(try await self.node(d, d.rootID, "Documents"), to: rd) { _, _ in } } != nil)
        // Empty files work both ways.
        let e = try await d.upload(try Self.file(Data()), name: "empty.txt", into: d.rootID, modified: nil) { _, _ in }
        #expect(e.size == 0)
        let ed = Self.tempDir("dl").appendingPathComponent("e")
        try await d.download(e, to: ed) { _, _ in }
        #expect(try Data(contentsOf: ed).isEmpty)
    }

    @Test func bigUploadsGoInPartsAndRetryAPart() async throws {
        var s = Self.testState()
        s.minPartSize = 256 * 1024
        s.maxPutSize = 300 * 1024    // a single PUT this big would be refused
        s.failParts = [2: 1]
        let d = try backend(s)
        d.multipartThreshold = 300 * 1024
        d.partSize = 256 * 1024
        let data = Self.bytes(1_100_000, seed: 13)
        let mtime = Date(timeIntervalSince1970: 1_750_000_000)
        let progress = DAVProgressBox()
        let up = try await d.upload(try Self.file(data, "big.bin"), name: "big.bin", into: "s3:/cirrus-test/Documents/", modified: mtime) { a, b in progress.note(a, b) }
        #expect(up.size == 1_100_000)
        let o = try #require(Fake.state.object("cirrus-test", "Documents/big.bin"))
        #expect(o.data == data)
        #expect(o.etag.hasSuffix("-5"))
        #expect(o.meta["x-amz-meta-mtime"] == "1750000000")
        #expect(!o.contentType.isEmpty)
        #expect(Fake.state.completed == 1 && Fake.state.partPuts == 5 && Fake.state.openUploads == 0)
        #expect(Fake.state.failParts[2] == 0)          // part 2 failed once and was sent again
        #expect(progress.last.0 == 1_100_000)
        let dest = Self.tempDir("big").appendingPathComponent("b")
        try await d.download(up, to: dest) { _, _ in }
        #expect(try Data(contentsOf: dest) == data)
        #expect(try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date == mtime)
        // No overwrite at the end either: Complete carries If-None-Match.
        Fake.update { $0.ghostKeys = ["Documents/big2.bin"]; $0.put("cirrus-test", "Documents/big2.bin", Data("someone else's".utf8)) }
        let clash = await caught { _ = try await d.upload(try Self.file(data, "big2.bin"), name: "big2.bin", into: "s3:/cirrus-test/Documents/", modified: nil) { _, _ in } }
        #expect(deniedMessage(clash)?.contains("already") == true, "\(message(clash))")
        await waitFor { Fake.state.openUploads == 0 }
        #expect(Fake.state.openUploads == 0 && Fake.state.aborted == 1)
        #expect(Fake.state.object("cirrus-test", "Documents/big2.bin")?.data == Data("someone else's".utf8))
    }

    @Test func failedOrCancelledMultipartUploadsAreAborted() async throws {
        var s = Self.testState()
        s.minPartSize = 1
        s.forbiddenParts = [2]
        let d = try backend(s)
        d.multipartThreshold = 100_000
        d.partSize = 1 << 20
        let data = Self.bytes(3 << 20)
        let e = await caught { _ = try await d.upload(try Self.file(data), name: "denied.bin", into: d.rootID, modified: nil) { _, _ in } }
        #expect(deniedMessage(e) != nil, "\(message(e))")
        await waitFor { Fake.state.openUploads == 0 }
        #expect(Fake.state.openUploads == 0 && Fake.state.aborted == 1)
        #expect(Fake.state.object("cirrus-test", "denied.bin") == nil)
        // Cancelled half-way.
        Fake.update { $0.forbiddenParts = []; $0.latency = 0.15; $0.partPuts = 0 }
        let src = try Self.file(data)
        let t = Task { try await d.upload(src, name: "cancelled.bin", into: d.rootID, modified: nil) { _, _ in } }
        await waitFor { Fake.state.partPuts >= 1 }
        t.cancel()
        let ce = await caught { _ = try await t.value }
        #expect(ce is CancellationError, "\(String(describing: ce))")
        Fake.update { $0.latency = 0 }
        await waitFor { Fake.state.openUploads == 0 }
        #expect(Fake.state.openUploads == 0 && Fake.state.aborted == 2)
        #expect(Fake.state.object("cirrus-test", "cancelled.bin") == nil)
        #expect(Fake.state.completed == 0)
    }

    @Test func cancellingADownloadStopsIt() async throws {
        let d = try backend()
        let readme = try await node(d, d.rootID, "Readme.txt")
        Fake.update { $0.latency = 0.5 }
        let t = Task { try await d.download(readme, to: Self.tempDir("cancel").appendingPathComponent("r")) { _, _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        t.cancel()
        #expect(await caught { try await t.value } is CancellationError)
        Fake.update { $0.latency = 0 }
    }

    // MARK: Never overwrite

    @Test func uploadsAndFoldersNeverReplaceAnything() async throws {
        let d = try backend()
        _ = try await d.createFolder("Fine", in: d.rootID)
        let file = try Self.file(Data("x".utf8))
        let e1 = await caught { _ = try await d.upload(file, name: "Readme.txt", into: d.rootID, modified: nil) { _, _ in } }
        #expect(deniedMessage(e1)?.contains("already an item named “Readme.txt”") == true)
        #expect(Fake.state.object("cirrus-test", "Readme.txt")?.data == Data("hello\n".utf8))
        // A file named like a folder (and the other way round).
        #expect(deniedMessage(await caught { _ = try await d.upload(file, name: "Photos", into: d.rootID, modified: nil) { _, _ in } }) != nil)
        #expect(deniedMessage(await caught { _ = try await d.createFolder("Readme.txt", in: d.rootID) }) != nil)
        #expect(deniedMessage(await caught { _ = try await d.createFolder("Documents", in: d.rootID) }) != nil)
        #expect(deniedMessage(await caught { _ = try await d.createFolder(".cirrus-deleted", in: d.rootID) }) != nil)
        #expect(await caught { _ = try await d.createFolder("a/b", in: d.rootID) } != nil)
        // Someone else writes the same name between the check and the upload: If-None-Match stops it.
        Fake.update { $0.ghostKeys = ["late.txt"]; $0.put("cirrus-test", "late.txt", Data("theirs".utf8)) }
        let e2 = await caught { _ = try await d.upload(file, name: "late.txt", into: d.rootID, modified: nil) { _, _ in } }
        #expect(deniedMessage(e2)?.contains("already") == true)
        #expect(Fake.state.object("cirrus-test", "late.txt")?.data == Data("theirs".utf8))
        #expect(d.conditionalWrites == true)
    }

    @Test func servicesWithoutConditionalWritesStillNeverOverwrite() async throws {
        // B2 answers 501 NotImplemented to If-None-Match: Cirrus drops the header and relies on its check.
        var s = Self.testState()
        s.put("b2-bucket", "have.txt", Data("old".utf8))
        let b2 = try backend(s, Self.record(endpoint: "https://s3.us-west-004.backblazeb2.com", bucket: "b2-bucket", region: "us-west-004"))
        let up = try await b2.upload(try Self.file(Data("new".utf8)), name: "new.txt", into: b2.rootID, modified: nil) { _, _ in }
        #expect(up.size == 3)
        #expect(b2.conditionalWrites == false)
        _ = try await b2.createFolder("Folder", in: b2.rootID)
        #expect(deniedMessage(await caught { _ = try await b2.upload(try Self.file(Data("x".utf8)), name: "have.txt", into: b2.rootID, modified: nil) { _, _ in } }) != nil)
        #expect(Fake.state.object("b2-bucket", "have.txt")?.data == Data("old".utf8))
        // Wasabi-style: the header is ignored, the existence check still holds.
        var w = Self.testState()
        w.put("wasabi-bucket", "have.txt", Data("old".utf8))
        let wa = try backend(w, Self.record(endpoint: "https://s3.eu-central-1.wasabisys.com", bucket: "wasabi-bucket", region: "eu-central-1"))
        #expect(deniedMessage(await caught { _ = try await wa.upload(try Self.file(Data("x".utf8)), name: "have.txt", into: wa.rootID, modified: nil) { _, _ in } }) != nil)
        #expect(Fake.state.object("wasabi-bucket", "have.txt")?.data == Data("old".utf8))
    }

    // MARK: Folders, rename, move

    @Test func createFolderWritesAMarker() async throws {
        let d = try backend()
        let f = try await d.createFolder("New Folder", in: d.rootID)
        #expect(f.id == "s3:/cirrus-test/New Folder/" && f.isFolder && f.parentID == d.rootID && f.name == "New Folder")
        let marker = try #require(Fake.state.object("cirrus-test", "New Folder/"))
        #expect(marker.data.isEmpty && marker.contentType == "application/x-directory")
        #expect(try await d.list(d.rootID).contains { $0.id == f.id })
        #expect(try await d.list(f.id).isEmpty)
        // Inside a folder that is only keys.
        let inner = try await d.createFolder("Inner", in: "s3:/cirrus-test/Photos/")
        #expect(inner.id == "s3:/cirrus-test/Photos/Inner/" && inner.parentID == "s3:/cirrus-test/Photos/")
        #expect(Set(try await d.list("s3:/cirrus-test/Photos/").map(\.name)) == ["Inner", "one.jpg", "two.jpg"])
        // Nothing can be added to the deleted items.
        #expect(await caught { _ = try await d.createFolder("x", in: "s3:/cirrus-test/.cirrus-deleted/") } != nil)
    }

    @Test func renameAndMoveFiles() async throws {
        let d = try backend()
        let a = try await node(d, "s3:/cirrus-test/Documents/", "a.txt")
        let renamed = try await d.rename(a, to: "A renamed.txt")
        #expect(renamed.id == "s3:/cirrus-test/Documents/A renamed.txt" && renamed.name == "A renamed.txt" && renamed.parentID == "s3:/cirrus-test/Documents/")
        #expect(Fake.state.object("cirrus-test", "Documents/a.txt") == nil)
        #expect(Fake.state.object("cirrus-test", "Documents/A renamed.txt")?.data == Data("a".utf8))
        // Case-only renames are real renames in S3.
        let lower = try await d.rename(renamed, to: "a renamed.txt")
        #expect(lower.name == "a renamed.txt" && Fake.state.object("cirrus-test", "Documents/A renamed.txt") == nil)
        // Clashes are refused and change nothing.
        let b = try await node(d, "s3:/cirrus-test/Documents/", "b.txt")
        #expect(deniedMessage(await caught { _ = try await d.rename(b, to: "c.csv") })?.contains("already") == true)
        #expect(deniedMessage(await caught { _ = try await d.rename(b, to: "Sub") })?.contains("already") == true)
        #expect(Fake.state.object("cirrus-test", "Documents/b.txt") != nil)
        // Metadata (the date note) survives.
        let up = try await d.upload(try Self.file(Data("m".utf8)), name: "dated.txt", into: d.rootID, modified: Date(timeIntervalSince1970: 1_600_000_000)) { _, _ in }
        try await d.move([up], to: "s3:/cirrus-test/Photos/")
        #expect(Fake.state.object("cirrus-test", "Photos/dated.txt")?.meta["x-amz-meta-mtime"] == "1600000000")
        #expect(Fake.state.object("cirrus-test", "dated.txt") == nil)
        // Moving the last items out of a folder that is only keys keeps the folder (a marker is written).
        let one = try await node(d, "s3:/cirrus-test/Photos/", "one.jpg")
        let two = try await node(d, "s3:/cirrus-test/Photos/", "two.jpg")
        let dated = try await node(d, "s3:/cirrus-test/Photos/", "dated.txt")
        try await d.move([one, two, dated], to: d.rootID)
        #expect(try await d.list("s3:/cirrus-test/Photos/").isEmpty)
        #expect(Fake.state.object("cirrus-test", "Photos/") != nil)
        #expect(Set(try await d.list(d.rootID).map(\.name)).isSuperset(of: ["one.jpg", "two.jpg", "dated.txt", "Photos"]))
        // Same folder: nothing to do. A clash: refused.
        let oneTop = try await node(d, d.rootID, "one.jpg")
        let copies = Fake.state.copies
        try await d.move([oneTop], to: d.rootID)
        #expect(Fake.state.copies == copies)
        Fake.update { $0.put("cirrus-test", "Photos/one.jpg", Data("another".utf8)) }
        #expect(deniedMessage(await caught { try await d.move([oneTop], to: "s3:/cirrus-test/Photos/") })?.contains("already") == true)
        #expect(Fake.state.object("cirrus-test", "one.jpg") != nil)
    }

    @Test func renameAndMoveFoldersMoveEveryKey() async throws {
        var s = Self.testState(pageSize: 2)
        for i in 0..<7 { s.put("cirrus-test", "Documents/Sub/more/\(i).txt", Data("\(i)".utf8)) }
        let d = try backend(s)
        let docs = try await node(d, d.rootID, "Documents")
        let before = Fake.state.buckets["cirrus-test"]!.keys.filter { $0.hasPrefix("Documents/") }
        let renamed = try await d.rename(docs, to: "Papers")
        #expect(renamed.id == "s3:/cirrus-test/Papers/" && renamed.name == "Papers" && renamed.isFolder)
        let after = Fake.state.buckets["cirrus-test"]!.keys
        #expect(!after.contains { $0.hasPrefix("Documents/") })
        #expect(Set(after.filter { $0.hasPrefix("Papers/") }) == Set(before.map { "Papers/" + $0.dropFirst("Documents/".count) }))
        #expect(Fake.state.object("cirrus-test", "Papers/Sub/more/6.txt")?.data == Data("6".utf8))
        // Into another folder, and never into itself.
        let sub = try await node(d, renamed.id, "Sub")
        try await d.move([sub], to: "s3:/cirrus-test/Photos/")
        #expect(Set(try await d.list("s3:/cirrus-test/Photos/Sub/").map(\.name)) == ["deep.txt", "more"])
        #expect(try await d.list("s3:/cirrus-test/Photos/Sub/more/").count == 7)
        let photos = try await node(d, d.rootID, "Photos")
        #expect(deniedMessage(await caught { try await d.move([photos], to: "s3:/cirrus-test/Photos/Sub/") })?.contains("into itself") == true)
        // A copy that fails (inside a 200 answer) leaves the originals and no half copy.
        Fake.update { $0.failCopiesIn200 = ["Photos/Sub/more/3.txt"] }
        let keysBefore = Fake.state.buckets["cirrus-test"]!.keys
        let e = await caught { _ = try await d.rename(photos, to: "Pictures") }
        #expect(e != nil)
        await waitFor { !Fake.state.buckets["cirrus-test"]!.keys.contains { $0.hasPrefix("Pictures/") } }
        #expect(Fake.state.buckets["cirrus-test"]!.keys == keysBefore)
    }

    @Test func objectsOver5GBAreCopiedInParts() async throws {
        var s = Self.testState()
        s.maxCopySize = 100_000
        s.minPartSize = 1
        let data = Self.bytes(250_000, seed: 3)
        s.put("cirrus-test", "huge.bin", data, meta: ["x-amz-meta-mtime": "1234567890"])
        let d = try backend(s)
        d.maxCopySize = 100_000
        d.copyPartSize = 64_000
        let huge = try await node(d, d.rootID, "huge.bin")
        _ = try await d.rename(huge, to: "huge renamed.bin")
        let o = try #require(Fake.state.object("cirrus-test", "huge renamed.bin"))
        #expect(o.data == data)
        #expect(o.etag.hasSuffix("-4"))
        #expect(o.meta["x-amz-meta-mtime"] == "1234567890")
        #expect(Fake.state.copies == 0 && Fake.state.completed == 1)
        #expect(Fake.state.object("cirrus-test", "huge.bin") == nil)
        // And into the trash and back.
        try await d.trash([try await node(d, d.rootID, "huge renamed.bin")])
        let t = try await d.listTrash()
        #expect(t.map(\.name) == ["huge renamed.bin"])
        try await d.restore(t)
        #expect(Fake.state.object("cirrus-test", "huge renamed.bin")?.data == data)
        #expect(Fake.state.object("cirrus-test", "huge renamed.bin")?.meta["x-amz-meta-cirrus-original"] == nil)
    }

    // MARK: Trash

    @Test func trashListRestoreAndDeleteForever() async throws {
        let d = try backend()
        let readme = try await node(d, d.rootID, "Readme.txt")
        let a = try await node(d, "s3:/cirrus-test/Documents/", "a.txt")
        let sub = try await node(d, "s3:/cirrus-test/Documents/", "Sub")
        try await d.trash([readme, a, sub])
        #expect(!(try await d.list(d.rootID)).contains { $0.name == "Readme.txt" || $0.name == ".cirrus-deleted" })
        #expect(!(try await d.list("s3:/cirrus-test/Documents/")).contains { $0.name == "a.txt" || $0.name == "Sub" })
        // Moved, never erased: the original key is noted on the object.
        let kept = try #require(Fake.state.object("cirrus-test", ".cirrus-deleted/Readme.txt"))
        #expect(kept.data == Data("hello\n".utf8))
        #expect(kept.meta["x-amz-meta-cirrus-original"] == "Readme.txt")
        #expect(Fake.state.object("cirrus-test", ".cirrus-deleted/Sub/deep.txt")?.data == Data("deep".utf8))
        #expect(Fake.state.object("cirrus-test", ".cirrus-deleted/Sub/")?.meta["x-amz-meta-cirrus-original"] == "Documents/Sub/")
        // A second item with a name already in the trash gets its own name there, but shows its real one.
        let b = try await node(d, "s3:/cirrus-test/Documents/", "b.txt")
        let b2 = try await d.rename(b, to: "a.txt")
        try await d.trash([b2])
        #expect(Fake.state.object("cirrus-test", ".cirrus-deleted/a 2.txt") != nil)
        let bin = try await d.listTrash()
        #expect(bin.map(\.name).sorted() == ["Readme.txt", "Sub", "a.txt", "a.txt"])
        #expect(bin.allSatisfy { $0.parentID == "s3:/cirrus-test/.cirrus-deleted/" })
        #expect(bin.first { $0.name == "Sub" }?.isFolder == true)
        // Trash of deleted items, and recovering items that aren't deleted, are refused.
        #expect(await caught { try await d.trash([bin[0]]) } != nil)
        #expect(await caught { try await d.restore([try await self.node(d, "s3:/cirrus-test/Documents/", "c.csv")]) } != nil)
        #expect(await caught { try await d.deleteForever([try await self.node(d, "s3:/cirrus-test/Documents/", "c.csv")]) } != nil)
        // Restore puts things back where they were; something new with the name meanwhile: keep both.
        _ = try await d.upload(try Self.file(Data("new readme".utf8)), name: "Readme.txt", into: d.rootID, modified: nil) { _, _ in }
        try await d.restore(bin.filter { $0.name == "Readme.txt" || $0.name == "Sub" || $0.id.hasSuffix("/a.txt") })
        #expect(Fake.state.object("cirrus-test", "Readme 2.txt")?.data == Data("hello\n".utf8))
        #expect(Fake.state.object("cirrus-test", "Readme.txt")?.data == Data("new readme".utf8))
        #expect(Fake.state.object("cirrus-test", "Readme 2.txt")?.meta["x-amz-meta-cirrus-original"] == nil)
        #expect(Fake.state.object("cirrus-test", "Documents/Sub/deep.txt")?.data == Data("deep".utf8))
        #expect(Fake.state.object("cirrus-test", "Documents/a.txt")?.data == Data("a".utf8))
        #expect(Set(try await d.list("s3:/cirrus-test/Documents/").map(\.name)).isSuperset(of: ["a.txt", "Sub"]))
        let left = try await d.listTrash()
        #expect(left.map(\.name) == ["a.txt"])
        #expect(left[0].id == "s3:/cirrus-test/.cirrus-deleted/a 2.txt")
        // The item's origin is still there and taken: it comes back as "a 2.txt".
        try await d.restore(left)
        #expect(Fake.state.object("cirrus-test", "Documents/a 2.txt")?.data == Data("bb".utf8))
        #expect(try await d.listTrash().isEmpty)
        // Delete forever erases, only from the trash.
        try await d.trash([try await node(d, "s3:/cirrus-test/Documents/", "Sub"), try await node(d, "s3:/cirrus-test/Documents/", "c.csv")])
        let again = try await d.listTrash()
        #expect(Set(again.map(\.name)) == ["Sub", "c.csv"])
        try await d.deleteForever(again)
        #expect(try await d.listTrash().isEmpty)
        #expect(!Fake.state.buckets["cirrus-test"]!.keys.contains { $0.hasPrefix(".cirrus-deleted/") && $0 != ".cirrus-deleted/" })
        // Trashing what's already gone is fine.
        var ghost = readme
        ghost.id = "s3:/cirrus-test/never-there.txt"
        try await d.trash([ghost])
    }

    @Test func itemsOfUnknownOriginRestoreToTheTop() async throws {
        var s = Self.testState()
        s.put("cirrus-test", ".cirrus-deleted/stray.txt", Data("s".utf8))
        let d = try backend(s)
        let bin = try await d.listTrash()
        #expect(bin.map(\.name) == ["stray.txt"])
        try await d.restore(bin)
        #expect(Fake.state.object("cirrus-test", "stray.txt")?.data == Data("s".utf8))
    }

    // MARK: Without a bucket

    @Test func withoutABucketTheTopListsBuckets() async throws {
        var s = Self.testState()
        s.put("other-bucket", ".cirrus-deleted/old.txt", Data("o".utf8), meta: ["x-amz-meta-cirrus-original": "Notes/old.txt"])
        let d = try backend(s, Self.record(bucket: nil))
        #expect(d.rootID == "s3:/")
        let top = try await d.list(d.rootID)
        #expect(top.map(\.name) == ["cirrus-test", "ireland", "other-bucket"])
        #expect(top.allSatisfy { $0.isFolder && $0.parentID == "s3:/" && $0.id == "s3:/" + $0.name + "/" })
        #expect(try await d.list("s3:/other-bucket/").map(\.name) == ["note.txt"])
        #expect(try await d.list("s3:/other-bucket/").first?.parentID == "s3:/other-bucket/")
        // A bucket in another region is found there.
        #expect(try await d.list("s3:/ireland/").map(\.name) == ["dublin.txt"])
        // Nothing can be added, renamed or deleted at the top.
        let up = await caught { _ = try await d.upload(try Self.file(Data("x".utf8)), name: "x.txt", into: d.rootID, modified: nil) { _, _ in } }
        if case .unsupported(let m)? = up as? CloudError { #expect(m.contains("Open a bucket first")) } else { Issue.record("\(message(up))") }
        #expect(await caught { _ = try await d.createFolder("x", in: d.rootID) } as? CloudError != nil)
        #expect(await caught { _ = try await d.rename(top[0], to: "y") } as? CloudError != nil)
        #expect(await caught { try await d.trash([top[0]]) } as? CloudError != nil)
        // Inside a bucket everything works, across buckets too.
        let n = try await d.upload(try Self.file(Data("in".utf8)), name: "in.txt", into: "s3:/other-bucket/", modified: nil) { _, _ in }
        try await d.move([n], to: "s3:/cirrus-test/Documents/")
        #expect(Fake.state.object("cirrus-test", "Documents/in.txt")?.data == Data("in".utf8))
        #expect(Fake.state.object("other-bucket", "in.txt") == nil)
        // Deleted items from every bucket.
        try await d.trash([try await node(d, "s3:/cirrus-test/", "Readme.txt")])
        let bin = try await d.listTrash()
        #expect(Set(bin.map(\.id)) == ["s3:/cirrus-test/.cirrus-deleted/Readme.txt", "s3:/other-bucket/.cirrus-deleted/old.txt"])
        #expect(bin.first { $0.id.hasPrefix("s3:/other-bucket/") }?.name == "old.txt")
        try await d.restore(bin.filter { $0.id.hasPrefix("s3:/other-bucket/") })
        #expect(Fake.state.object("other-bucket", "Notes/old.txt") != nil)
    }

    // MARK: Errors

    @Test func wrongKeysAndOtherRefusalsGiveClearErrors() async throws {
        let wrong = try backend(Self.testState(), Self.record(), secret: "not-the-secret")
        let e = await caught { _ = try await wrong.list(wrong.rootID) }
        #expect(deniedMessage(e)?.contains("secret access key") == true, "\(message(e))")
        #expect(Fake.state.signatureFailures == 1)    // not retried
        let unknown = try backend(Self.testState(), Self.record(key: "AKIAREVOKED"))
        #expect(await caught { _ = try await unknown.list(unknown.rootID) } as? CloudError == .signInNeeded("S3 Storage (cirrus-test @ test)"))
        var s = Self.testState()
        s.put("cirrus-test", "Archive/cold.bin", Data("brr".utf8), storageClass: "GLACIER")
        let d = try backend(s)
        let cold = try await node(d, "s3:/cirrus-test/Archive/", "cold.bin")
        let ce = await caught { try await d.download(cold, to: Self.tempDir("cold").appendingPathComponent("c")) { _, _ in } }
        #expect(deniedMessage(ce)?.contains("archived") == true, "\(message(ce))")
        let gone = try backend(Self.testState(), Self.record(bucket: "deleted-bucket"))
        if case .notConfigured? = await caught({ _ = try await gone.list(gone.rootID) }) as? CloudError {} else { Issue.record("expected notConfigured") }
        // make() needs the secret.
        #expect(throws: CloudError.self) { _ = try S3Storage.make(record: Self.record(), secret: CloudSecret(), transport: Self.transport) }
        var other = Self.record()
        other.provider = .webdav
        #expect(throws: CloudError.self) { _ = try S3Storage.make(record: other, secret: CloudSecret(password: "x"), transport: Self.transport) }
        #expect(throws: CloudError.self) { _ = try CloudBackends.make(CloudAccountRecord(provider: .s3, title: "x", server: nil, username: "k"),
                                                                       secret: CloudSecret(password: "x")) }
    }

    @Test func aSkewedClockIsCorrectedOnce() async throws {
        var s = Self.testState()
        s.skew = 3 * 3600    // the server is three hours ahead
        let d = try backend(s)
        #expect(try await d.list(d.rootID).count == 3)
        #expect(Fake.state.skewRejections == 1)
        #expect(abs(d.client.clockOffset - 3 * 3600) < 5)
        _ = try await d.upload(try Self.file(Data("t".utf8)), name: "timed.txt", into: d.rootID, modified: nil) { _, _ in }
        #expect(Fake.state.skewRejections == 1)
        // The other way round, at connect.
        Fake.update { $0.skew = -2 * 3600 }
        _ = try await S3Storage.connect(endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: "cirrus-test",
                                        accessKey: Fake.accessKey, secretKey: Fake.secretKey, transport: Self.transport)
        #expect(Fake.state.skewRejections == 2)
    }

    // MARK: Demo

    @Test func demoAccountWorks() async throws {
        Fake.reset()
        Fake.startDemo(storage: nil)
        Fake.update { $0.latency = 0 }
        let demo = try #require(S3Storage.demo())
        #expect(demo.record.id == "cloud:s3:demo")
        #expect(demo.record.provider == .s3)
        #expect(demo.record.title == "demo-files @ s3.example.com")
        #expect(demo.backend.provider == .s3 && demo.backend.canListTrash)
        let top = try await demo.backend.list(demo.backend.rootID)
        #expect(Set(top.map(\.name)) == ["Archive", "Backups", "Documents", "Photos", "Readme.txt"])
        #expect(try await demo.backend.listTrash().map(\.name) == ["Old draft.txt"])
        #expect(try await demo.backend.quota() == nil)
        let photos = try await demo.backend.list("s3:/demo-files/Photos/")
        #expect(photos.count == 3)
        #expect(try await demo.backend.thumbnail(photos[0], maxPixel: 256) == nil)
        let dest = Self.tempDir("demo").appendingPathComponent("p.jpg")
        try await demo.backend.download(photos[0], to: dest) { _, _ in }
        #expect(try Data(contentsOf: dest).prefix(2) == Data([0xFF, 0xD8]))
        let all = try await demo.backend.walk(demo.backend.rootID)
        #expect(all.count > 8)
        #expect(CloudBackends.demo(.s3)?.record.id == "cloud:s3:demo")
    }

    // MARK: A real server

    /// Against a real S3-compatible server (e.g. a MinIO on 127.0.0.1:9000 with a scratch bucket). Runs only when
    /// CIRRUS_S3_REAL_ENDPOINT, _BUCKET, _KEY and _SECRET are set (and _REGION if not us-east-1). Leaves the bucket as it was.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CIRRUS_S3_REAL_ENDPOINT"] != nil))
    func realServerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let (record, secret) = try await S3Storage.connect(endpoint: env["CIRRUS_S3_REAL_ENDPOINT"]!, region: env["CIRRUS_S3_REAL_REGION"] ?? "",
                                                           bucket: env["CIRRUS_S3_REAL_BUCKET"], accessKey: env["CIRRUS_S3_REAL_KEY"] ?? "",
                                                           secretKey: env["CIRRUS_S3_REAL_SECRET"] ?? "", transport: nil)
        let d = try #require(try S3Storage.make(record: record, secret: secret, transport: nil) as? S3Backend)
        d.multipartThreshold = 6 << 20
        d.partSize = 5 << 20
        let top = "Cirrus test \(UUID().uuidString.prefix(6)) #1 & ü+"
        let base = try await d.createFolder(top, in: d.rootID)
        for n in Self.oddNames { _ = try await d.upload(try Self.file(Data(n.utf8)), name: n, into: base.id, modified: nil) { _, _ in } }
        let listed = try await d.list(base.id)
        #expect(Set(listed.map(\.name)) == Set(Self.oddNames.map(\.precomposedStringWithCanonicalMapping)))
        for item in listed {
            let dest = Self.tempDir("real").appendingPathComponent("f")
            try await d.download(item, to: dest) { _, _ in }
            #expect(S3Key.same(String(decoding: try Data(contentsOf: dest), as: UTF8.self), S3Key.lastSegment(String(item.id.dropFirst(base.id.count)))))
        }
        let big = Self.bytes(13 << 20)
        let bn = try await d.upload(try Self.file(big), name: "big file.bin", into: base.id, modified: Date(timeIntervalSince1970: 1_700_000_000)) { _, _ in }
        let bd = Self.tempDir("real").appendingPathComponent("big")
        try await d.download(bn, to: bd) { _, _ in }
        #expect(try Data(contentsOf: bd) == big)
        #expect(try FileManager.default.attributesOfItem(atPath: bd.path)[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(deniedMessage(await caught { _ = try await d.upload(try Self.file(Data("x".utf8)), name: "a b.txt", into: base.id, modified: nil) { _, _ in } }) != nil)
        let sub = try await d.createFolder("sub folder %", in: base.id)
        let first = try #require(listed.first { $0.name == "a b.txt" })
        let renamed = try await d.rename(first, to: "renamed + more.txt")
        try await d.move([renamed], to: sub.id)
        #expect(try await d.list(sub.id).map(\.name) == ["renamed + more.txt"])
        try await d.trash([sub])
        let bin = try await d.listTrash()
        #expect(bin.contains { $0.name == "sub folder %" })
        try await d.restore(bin.filter { $0.name == "sub folder %" })
        #expect(try await d.list(base.id).contains { $0.name == "sub folder %" })
        try await d.trash([try await node(d, d.rootID, top)])
        try await d.deleteForever(try await d.listTrash().filter { $0.name == top })
        #expect(!(try await d.list(d.rootID)).contains { $0.name == top })
    }
}
