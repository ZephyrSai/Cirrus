import CommonCrypto
import CryptoKit
import Foundation

/// Client side of Apple's SRP-6a variant used by idmsa.apple.com
/// (RFC 5054 2048-bit group, SHA-256, username omitted from x, s2k / s2k_fo password derivation).
/// Mirrors rclone's backend/iclouddrive/api/srp.go so the math can be cross-checked.
public struct AppleSRPClient {
    public static let N = BigUInt(hex:
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050" +
        "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50" +
        "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8" +
        "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B" +
        "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748" +
        "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861602790" +
        "04E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8" +
        "E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
        "9E4AFF73")!
    public static let g = BigUInt(2)
    static let nLen = 256

    public enum SRPError: Error, LocalizedError {
        case invalidServerValue, zeroU, unsupportedProtocol(String), derivationFailed
        public var errorDescription: String? {
            switch self {
            case .invalidServerValue: return "Apple returned an invalid sign-in challenge."
            case .zeroU: return "Sign-in challenge failed a safety check."
            case .unsupportedProtocol(let p): return "Unsupported password protocol \"\(p)\"."
            case .derivationFailed: return "Password key derivation failed."
            }
        }
    }

    let a: BigUInt
    public let A: BigUInt
    public private(set) var M1 = [UInt8]()
    public private(set) var M2 = [UInt8]()
    public private(set) var K = [UInt8]()

    public init(secret: [UInt8]? = nil) {
        var bytes = secret ?? [UInt8](repeating: 0, count: 32)
        if secret == nil { _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) }
        a = BigUInt(bytes: bytes)
        A = Self.g.power(a, modulus: Self.N)
    }

    public var aBytes: [UInt8] { A.serialize(paddedTo: Self.nLen) }

    static func H(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    static func pad(_ v: BigUInt) -> [UInt8] { v.serialize(paddedTo: nLen) }

    static var k: BigUInt { BigUInt(bytes: H(N.serialize(), pad(g))) }

    public static func derivePassword(_ password: String, salt: [UInt8], iterations: Int, protocol proto: String) throws -> [UInt8] {
        let digest = Array(SHA256.hash(data: Data(password.utf8)))
        let input: [UInt8]
        switch proto {
        case "s2k": input = digest
        case "s2k_fo": input = Array(digest.map { String(format: "%02x", $0) }.joined().utf8)
        default: throw SRPError.unsupportedProtocol(proto)
        }
        var out = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeBytes { pw in
            salt.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress?.assumingMemoryBound(to: CChar.self), input.count,
                                     s.baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw SRPError.derivationFailed }
        return out
    }

    /// username must already be lowercased.
    public mutating func processChallenge(username: String, derivedKey: [UInt8], salt: [UInt8], serverB: [UInt8]) throws {
        let N = Self.N
        let B = BigUInt(bytes: serverB)
        guard !B.isZero, B < N else { throw SRPError.invalidServerValue }
        let x = BigUInt(bytes: Self.H(salt, Self.H(Array(":".utf8), derivedKey)))
        let u = BigUInt(bytes: Self.H(Self.pad(A), Self.pad(B)))
        guard !u.isZero else { throw SRPError.zeroU }
        let gx = Self.g.power(x, modulus: N)
        let kgx = (Self.k * gx) % N
        let base = ((B + N) - kgx) % N
        let exp = a + u * x
        let S = base.power(exp, modulus: N)
        K = Self.H(Self.pad(S))
        let hg = Self.H(Self.pad(Self.g))
        let hn = Self.H(N.serialize())
        let hxor = zip(hg, hn).map { $0 ^ $1 }
        let hi = Self.H(Array(username.utf8))
        M1 = Self.H(hxor, hi, salt, Self.pad(A), Self.pad(B), K)
        M2 = Self.H(Self.pad(A), M1, K)
    }
}
