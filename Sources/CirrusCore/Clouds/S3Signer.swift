import CryptoKit
import Foundation

/// AWS Signature Version 4 (header-based), as S3 and every S3-compatible service uses it.
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
///
/// Pure functions only: the canonical request, the string to sign, the signing key and the Authorization header.
/// The fake S3 server uses the same code to check what clients send, so `S3Tests` pins it to AWS's published vectors.
/// Nothing here logs a key, a canonical request or a signature.
enum S3Signer {
    static let algorithm = "AWS4-HMAC-SHA256"
    /// SHA-256 of an empty body.
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// Allowed by S3 instead of a body hash (Cirrus hashes every body it sends, but the fake accepts it too).
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    struct Signature: Sendable {
        var authorization: String
        var canonicalRequest: String
        var stringToSign: String
        var signature: String
        var signedHeaders: String
    }

    /// Signs one request. `headers` are the headers to sign, including `host` and `x-amz-date` (names in any case);
    /// `canonicalURI` and `canonicalQuery` are already encoded (see `encode` and `canonicalQuery`).
    static func sign(method: String, canonicalURI: String, canonicalQuery: String, headers: [(String, String)], payloadHash: String,
                     amzDate: String, region: String, service: String = "s3", accessKey: String, secretKey: String) -> Signature {
        let (canonHeaders, signed) = canonicalHeaders(headers)
        let creq = [method.uppercased(), canonicalURI.isEmpty ? "/" : canonicalURI, canonicalQuery, canonHeaders, signed, payloadHash]
            .joined(separator: "\n")
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let sts = [algorithm, amzDate, scope, sha256Hex(Data(creq.utf8))].joined(separator: "\n")
        let key = signingKey(secret: secretKey, day: day, region: region, service: service)
        let sig = hex(Data(HMAC<SHA256>.authenticationCode(for: Data(sts.utf8), using: key)))
        let auth = "\(algorithm) Credential=\(accessKey)/\(scope), SignedHeaders=\(signed), Signature=\(sig)"
        return Signature(authorization: auth, canonicalRequest: creq, stringToSign: sts, signature: sig, signedHeaders: signed)
    }

    /// kSigning = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, day), region), service), "aws4_request").
    static func signingKey(secret: String, day: String, region: String, service: String) -> SymmetricKey {
        var k = SymmetricKey(data: Data(("AWS4" + secret).utf8))
        for part in [day, region, service, "aws4_request"] {
            k = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: k)))
        }
        return k
    }

    /// Lower-case names, values trimmed with inner runs of spaces collapsed, repeated names joined by commas,
    /// sorted by name. Returns the canonical header block (each line ending in "\n") and the signed-headers list.
    static func canonicalHeaders(_ headers: [(String, String)]) -> (canonical: String, signed: String) {
        var merged = [String: [String]]()
        for (name, value) in headers {
            merged[name.lowercased().trimmingCharacters(in: .whitespaces), default: []].append(trimValue(value))
        }
        let names = merged.keys.sorted()
        let canonical = names.map { "\($0):\(merged[$0]!.joined(separator: ","))\n" }.joined()
        return (canonical, names.joined(separator: ";"))
    }

    static func trimValue(_ v: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in v.trimmingCharacters(in: .whitespacesAndNewlines) {
            let space = ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
            if space { if !lastSpace { out.append(" ") } } else { out.append(ch) }
            lastSpace = space
        }
        return out
    }

    /// Query parameters: names and values URI-encoded (every byte but A–Z a–z 0–9 - _ . ~, "/" included), sorted by
    /// name then value, a missing value written as "name=".
    static func canonicalQuery(_ items: [(String, String?)]) -> String {
        let pairs: [(name: String, value: String)] = items.map { (encode($0.0, slash: true), encode($0.1 ?? "", slash: true)) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { p in p.name + "=" + p.value }.joined(separator: "&")
    }

    /// AWS's URI encoding: each UTF-8 byte other than the unreserved characters becomes %XX (upper-case hex).
    /// `slash: false` keeps "/" (object keys in paths); S3 paths are encoded once and never normalized.
    static func encode(_ s: String, slash: Bool) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if unreserved(b) || (b == 0x2F && !slash) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out += "%"
                out += hexDigits[Int(b >> 4)]
                out += hexDigits[Int(b & 0xF)]
            }
        }
        return out
    }

    /// A–Z a–z 0–9 - _ . ~
    static func unreserved(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x7E
    }

    private static let hexDigits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]

    /// Percent-decoding of raw bytes ("+" stays "+"); nil when the escapes don't make UTF-8.
    static func decode(_ s: String) -> String? {
        guard s.contains("%") else { return s }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.utf8.count)
        var it = Array(s.utf8)[...]
        while let b = it.popFirst() {
            if b == UInt8(ascii: "%"), it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(v)
                it = it.dropFirst(2)
            } else {
                bytes.append(b)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The raw query of a URL ("a=1&b") → decoded pairs, as a server reads them.
    static func queryItems(_ raw: String?) -> [(String, String?)] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: "&", omittingEmptySubsequences: true).map { part in
            if let eq = part.firstIndex(of: "=") {
                return (decode(String(part[..<eq])) ?? String(part[..<eq]), decode(String(part[part.index(after: eq)...])) ?? "")
            }
            return (decode(String(part)) ?? String(part), nil)
        }
    }

    static func sha256Hex(_ d: Data) -> String { hex(Data(SHA256.hash(data: d))) }

    static func hex(_ d: Data) -> String {
        var s = ""
        s.reserveCapacity(d.count * 2)
        for b in d { s += String(format: "%02x", b) }
        return s
    }

    /// "20150830T123600Z" (UTC).
    static func amzDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func parseAmzDate(_ s: String) -> Date? {
        guard s.count == 16, s.hasSuffix("Z"), s.dropFirst(8).first == "T" else { return nil }
        let digits = s.filter(\.isNumber)
        guard digits.count == 14 else { return nil }
        func n(_ a: Int, _ len: Int) -> Int? { Int(digits.dropFirst(a).prefix(len)) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: n(0, 4), month: n(4, 2), day: n(6, 2), hour: n(8, 2), minute: n(10, 2), second: n(12, 2)))
    }

    /// The parts of an Authorization header ("AWS4-HMAC-SHA256 Credential=…, SignedHeaders=…, Signature=…").
    struct Parsed: Sendable {
        var accessKey: String
        var day: String
        var region: String
        var service: String
        var signedHeaders: [String]
        var signature: String
    }

    static func parse(authorization h: String) -> Parsed? {
        guard h.hasPrefix(algorithm + " ") else { return nil }
        var fields = [String: String]()
        for part in h.dropFirst(algorithm.count + 1).split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            fields[String(t[..<eq])] = String(t[t.index(after: eq)...])
        }
        guard let cred = fields["Credential"], let sh = fields["SignedHeaders"], let sig = fields["Signature"] else { return nil }
        let c = cred.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard c.count == 5, c[4] == "aws4_request" else { return nil }
        return Parsed(accessKey: c[0], day: c[1], region: c[2], service: c[3], signedHeaders: sh.split(separator: ";").map(String.init), signature: sig)
    }
}

/// Byte-exact operations on object keys. Swift's String comparisons treat canonically equivalent spellings as equal
/// and work on grapheme clusters ("/" followed by a combining mark isn't a "/"), but S3 keys are UTF-8 byte strings.
enum S3Key {
    static func hasPrefix(_ s: String, _ p: String) -> Bool { s.utf8.starts(with: p.utf8) }
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func dropPrefix(_ s: String, _ p: String) -> String { String(decoding: s.utf8.dropFirst(p.utf8.count), as: UTF8.self) }
    static func isFolder(_ k: String) -> Bool { k.utf8.last == UInt8(ascii: "/") }

    /// "a/b/c.txt" → "c.txt", "a/b/" → "b".
    static func lastSegment(_ k: String) -> String {
        var b = Array(k.utf8)
        if b.last == UInt8(ascii: "/") { b.removeLast() }
        if let i = b.lastIndex(of: UInt8(ascii: "/")) { b = Array(b[(i + 1)...]) }
        return String(decoding: b, as: UTF8.self)
    }

    /// "a/b/c.txt" → "a/b/", "a/" → "", "x" → "".
    static func parent(_ k: String) -> String {
        var b = Array(k.utf8)
        if b.last == UInt8(ascii: "/") { b.removeLast() }
        guard let i = b.lastIndex(of: UInt8(ascii: "/")) else { return "" }
        return String(decoding: b[...i], as: UTF8.self)
    }

    /// The first "/"-separated piece after `prefix` (with its "/" when there is one): what a delimiter listing groups by.
    static func childPrefix(_ k: String, after prefix: String) -> String? {
        let rest = Array(k.utf8.dropFirst(prefix.utf8.count))
        guard let i = rest.firstIndex(of: UInt8(ascii: "/")) else { return nil }
        return prefix + String(decoding: rest[...i], as: UTF8.self)
    }
}
