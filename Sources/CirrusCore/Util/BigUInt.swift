import Foundation

/// Minimal arbitrary-precision unsigned integer, just enough for SRP-6a
/// (2048-bit modular exponentiation). Little-endian 32-bit limbs, always normalized
/// (no trailing zero limbs; zero is the empty array).
public struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    var limbs: [UInt32]

    public init() { limbs = [] }

    public init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    /// Big-endian bytes.
    public init<C: Collection>(bytes: C) where C.Element == UInt8 {
        let arr = Array(bytes)
        var out = [UInt32]()
        out.reserveCapacity(arr.count / 4 + 1)
        var i = arr.count
        while i > 0 {
            var limb: UInt32 = 0
            let start = max(0, i - 4)
            for j in start..<i { limb = (limb << 8) | UInt32(arr[j]) }
            out.append(limb)
            i = start
        }
        limbs = out
        normalize()
    }

    public init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard !clean.isEmpty else { return nil }
        var bytes = [UInt8]()
        var chars = Array(clean)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        var idx = 0
        while idx < chars.count {
            guard let b = UInt8(String(chars[idx...idx + 1]), radix: 16) else { return nil }
            bytes.append(b)
            idx += 2
        }
        self.init(bytes: bytes)
    }

    public var isZero: Bool { limbs.isEmpty }

    mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    /// Minimal big-endian bytes (empty for zero).
    public func serialize() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        if let first = out.firstIndex(where: { $0 != 0 }) { return Array(out[first...]) }
        return []
    }

    /// Big-endian bytes left-padded with zeros to `length`.
    public func serialize(paddedTo length: Int) -> [UInt8] {
        let raw = serialize()
        if raw.count >= length { return raw }
        return [UInt8](repeating: 0, count: length - raw.count) + raw
    }

    public var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let li = i / 32
        guard li < limbs.count else { return false }
        return (limbs[li] >> UInt32(i % 32)) & 1 == 1
    }

    public var description: String {
        let bytes = serialize()
        return bytes.isEmpty ? "0" : bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a.limbs, b.limbs) < 0 }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var out = [UInt32](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        out[n] = UInt32(carry)
        var r = BigUInt(); r.limbs = out; r.normalize(); return r
    }

    /// Requires a >= b.
    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(!(a < b), "BigUInt subtraction underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var d = Int64(out[i]) - borrow - Int64(i < b.limbs.count ? b.limbs[i] : 0)
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            out[i] = UInt32(d)
        }
        var r = BigUInt(); r.limbs = out; r.normalize(); return r
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            if ai == 0 { continue }
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.limbs.count
            while carry != 0 {
                let t = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        var r = BigUInt(); r.limbs = out; r.normalize(); return r
    }

    public static func % (a: BigUInt, m: BigUInt) -> BigUInt { divMod(a, m).remainder }
    public static func / (a: BigUInt, m: BigUInt) -> BigUInt { divMod(a, m).quotient }

    /// Knuth algorithm D (Hacker's Delight divmnu, 32-bit digits).
    public static func divMod(_ u: BigUInt, _ v: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!v.isZero, "division by zero")
        if u < v { return (BigUInt(), u) }
        let n = v.limbs.count
        let m = u.limbs.count
        if n == 1 {
            let d = UInt64(v.limbs[0])
            var q = [UInt32](repeating: 0, count: m)
            var rem: UInt64 = 0
            var i = m - 1
            while i >= 0 {
                let cur = (rem << 32) | UInt64(u.limbs[i])
                q[i] = UInt32(cur / d)
                rem = cur % d
                i -= 1
            }
            var qq = BigUInt(); qq.limbs = q; qq.normalize()
            return (qq, BigUInt(rem))
        }
        let s = UInt32(v.limbs[n - 1].leadingZeroBitCount)
        var vn = [UInt32](repeating: 0, count: n)
        for i in stride(from: n - 1, to: 0, by: -1) {
            vn[i] = (v.limbs[i] << s) | (s == 0 ? 0 : v.limbs[i - 1] >> (32 - s))
        }
        vn[0] = v.limbs[0] << s
        var un = [UInt32](repeating: 0, count: m + 1)
        un[m] = s == 0 ? 0 : u.limbs[m - 1] >> (32 - s)
        for i in stride(from: m - 1, to: 0, by: -1) {
            un[i] = (u.limbs[i] << s) | (s == 0 ? 0 : u.limbs[i - 1] >> (32 - s))
        }
        un[0] = u.limbs[0] << s

        let b: UInt64 = 1 << 32
        var q = [UInt32](repeating: 0, count: m - n + 1)
        var j = m - n
        while j >= 0 {
            let num = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = num / UInt64(vn[n - 1])
            var rhat = num % UInt64(vn[n - 1])
            while qhat >= b || qhat * UInt64(vn[n - 2]) > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                if rhat >= b { break }
            }
            var k: Int64 = 0
            var t: Int64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(vn[i])
                t = Int64(un[i + j]) - k - Int64(p & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                k = Int64(p >> 32) - (t >> 32)
            }
            t = Int64(un[j + n]) - k
            un[j + n] = UInt32(truncatingIfNeeded: t)
            q[j] = UInt32(truncatingIfNeeded: qhat)
            if t < 0 {
                q[j] = q[j] &- 1
                k = 0
                for i in 0..<n {
                    t = Int64(un[i + j]) + Int64(vn[i]) + k
                    un[i + j] = UInt32(truncatingIfNeeded: t)
                    k = t >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: Int64(un[j + n]) + k)
            }
            j -= 1
        }
        var r = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            r[i] = (un[i] >> s) | (s == 0 ? 0 : un[i + 1] << (32 - s))
        }
        var qq = BigUInt(); qq.limbs = q; qq.normalize()
        var rr = BigUInt(); rr.limbs = r; rr.normalize()
        return (qq, rr)
    }

    /// self^exponent mod modulus (left-to-right square and multiply).
    public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero)
        if modulus == BigUInt(1) { return BigUInt() }
        var result = BigUInt(1)
        let base = self % modulus
        let bits = exponent.bitWidth
        if bits == 0 { return result }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            if exponent.bit(i) { result = (result * base) % modulus }
        }
        return result
    }
}
