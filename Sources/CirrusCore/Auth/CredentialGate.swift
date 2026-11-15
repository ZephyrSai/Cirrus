import Foundation
import LocalAuthentication

/// Saved Apple ID passwords are only released after Touch ID / Apple Watch / the Mac login password
/// (LocalAuthentication .deviceOwnerAuthentication). Unlocked passwords stay in memory for this run only.
public actor CredentialGate {
    public static let shared = CredentialGate()
    private var unlocked = [String: String]()

    public static var requireAuth: Bool {
        UserDefaults.standard.object(forKey: "requireAuthForSavedPassword") as? Bool ?? true
    }

    public static func hasSavedPassword(_ appleID: String) -> Bool {
        Keychain.get(service: Keychain.passwordService, account: appleID.lowercased()) != nil
    }

    /// Returns the saved password after the user authenticates (or nil if none / declined / timed out).
    public func password(for appleID: String, reason: String) async -> String? {
        let id = appleID.lowercased()
        if let p = unlocked[id] { return p }
        guard let data = Keychain.get(service: Keychain.passwordService, account: id), let pw = String(data: data, encoding: .utf8) else { return nil }
        if Self.requireAuth {
            guard await Self.authenticate(reason: reason) else { return nil }
        }
        unlocked[id] = pw
        return pw
    }

    public func forget(_ appleID: String) { unlocked[appleID.lowercased()] = nil }

    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        // Don't hang an unattended (scheduled) run forever waiting for a fingerprint.
        return await withTaskGroup(of: Bool.self) { g in
            g.addTask { (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false }
            g.addTask { try? await Task.sleep(nanoseconds: 120_000_000_000); ctx.invalidate(); return false }
            let r = await g.next() ?? false
            g.cancelAll()
            return r
        }
    }
}
