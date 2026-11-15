import Foundation
import Security

/// Generic-password Keychain storage for session state and (optionally) the Apple ID password.
/// Items are stored in the login keychain, scoped to this Mac (kSecAttrSynchronizable = false).
public enum Keychain {
    public static let sessionService = "Cirrus iCloud Session"
    public static let passwordService = "Cirrus Apple ID Password"

    static var servicePrefix: String {
        ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map { "[\($0)] " } ?? ""
    }

    public static func set(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            add[kSecAttrSynchronizable as String] = false
            let s = SecItemAdd(add as CFDictionary, nil)
            if s != errSecSuccess { Log.error("keychain add failed: \(s)") }
        } else if status != errSecSuccess {
            Log.error("keychain update failed: \(status)")
        }
    }

    public static func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
