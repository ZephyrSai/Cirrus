import Foundation
import Testing
@testable import CirrusCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

private func hexBytes(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var chars = Array(s)
    if chars.count % 2 == 1 { chars.insert("0", at: 0) }
    var i = 0
    while i < chars.count { out.append(UInt8(String(chars[i...i + 1]), radix: 16)!); i += 2 }
    return out
}

@Test func bigIntArithmeticMatchesPython() throws {
    for line in try fixture("bigint-vectors.txt").split(separator: "\n") {
        let f = line.split(separator: " ").map(String.init)
        let a = BigUInt(hex: f[0])!, b = BigUInt(hex: f[1])!, m = BigUInt(hex: f[2])!
        #expect((a * b).description == BigUInt(hex: f[3])!.description, "mul \(line)")
        let (q, r) = BigUInt.divMod(a, b)
        #expect(q.description == BigUInt(hex: f[4])!.description, "div \(line)")
        #expect(r.description == BigUInt(hex: f[5])!.description, "mod \(line)")
        #expect(((q * b) + r) == a)
        if m > BigUInt(1) {
            #expect(a.power(b, modulus: m).description == BigUInt(hex: f[6])!.description, "pow \(line)")
        }
    }
}

@Test func bigIntBytesRoundTrip() {
    let bytes: [UInt8] = [0, 0, 1, 2, 3, 4, 5, 255]
    let v = BigUInt(bytes: bytes)
    #expect(v.serialize() == [1, 2, 3, 4, 5, 255])
    #expect(v.serialize(paddedTo: 8) == bytes)
    #expect(BigUInt(bytes: []).isZero)
    #expect(BigUInt(5) - BigUInt(5) == BigUInt())
}

@Test func srpMatchesIndependentImplementation() throws {
    let secret = Array<UInt8>(1...32)
    let salt = hexBytes("a1b2c3d4e5f60718293a4b5c6d7e8f90")
    for line in try fixture("srp-vectors.txt").split(separator: "\n") {
        let parts = line.split(separator: " ").map(String.init)
        let proto = parts[0]
        var kv = [String: String]()
        for p in parts.dropFirst() {
            let s = p.split(separator: "=", maxSplits: 1).map(String.init)
            kv[s[0]] = s[1]
        }
        let key = try AppleSRPClient.derivePassword("correct horse battery staple", salt: salt, iterations: 20000, protocol: proto)
        #expect(key == hexBytes(kv["key"]!), "derived key \(proto)")
        var client = AppleSRPClient(secret: secret)
        #expect(client.aBytes == hexBytes(kv["A"]!))
        try client.processChallenge(username: "someone@example.com", derivedKey: key, salt: salt, serverB: hexBytes(kv["B"]!))
        #expect(client.M1 == hexBytes(kv["M1"]!), "M1 \(proto)")
        #expect(client.M2 == hexBytes(kv["M2"]!), "M2 \(proto)")
    }
}

@Test func srpRejectsBadServerValue() {
    var client = AppleSRPClient(secret: Array(repeating: 7, count: 32))
    #expect(throws: AppleSRPClient.SRPError.self) {
        try client.processChallenge(username: "x", derivedKey: [1], salt: [1], serverB: [0])
    }
    #expect(throws: AppleSRPClient.SRPError.self) {
        try client.processChallenge(username: "x", derivedKey: [1], salt: [1], serverB: AppleSRPClient.N.serialize())
    }
}
