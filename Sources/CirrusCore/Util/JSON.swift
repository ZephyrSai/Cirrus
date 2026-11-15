import Foundation

/// Small dynamic JSON value used for Apple's loosely-typed responses.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public func data() -> Data { (try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])) ?? Data() }

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .number(let n): return Int64(n)
        case .string(let s): return Int64(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var int: Int? { int64.map { Int($0) } }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }

    public var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Parses Apple's mixed date encodings: ISO-8601 strings or epoch milliseconds.
    public var date: Date? {
        switch self {
        case .number(let n): return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        case .string(let s):
            if let n = Double(s) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            return JSON.parseISO(s)
        default: return nil
        }
    }

    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSON {
    static func int(_ v: Int) -> JSON { .number(Double(v)) }
    static func int64(_ v: Int64) -> JSON { .number(Double(v)) }
}
