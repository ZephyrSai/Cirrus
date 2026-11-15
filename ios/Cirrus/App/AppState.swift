import CirrusCore
import Observation
import SwiftUI
import UIKit

/// Where the sidebar points.
enum Destination: Hashable {
    case drive(String)            // account id
    case driveTrash(String)
    case photos(String)           // All Photos of an account (or this device)
    case albums(String)
    case backup
    case transfers
    case accounts
    case settings
}

/// App-wide state the views observe: accounts, transfer activity, the sidebar selection and sheets.
@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var accounts: [Account] = []
    /// Bumped when an account's status changes (Account is a class, so SwiftUI needs a nudge).
    var accountsVersion = 0
    var selection: Destination?
    var signIn: SignInRequest?
    var readOnly = SafetyPolicy.readOnlyICloud
    /// Active (queued or running) transfers, refreshed on TransferManager.changed (throttled there).
    var activeTransfers = 0
    var transfersVersion = 0
    /// A one-line message shown at the bottom of the screen ("Moved 3 items to Recently Deleted").
    var toast: String?

    struct SignInRequest: Identifiable { let id = UUID(); var appleID: String? }

    private var observers: [NSObjectProtocol] = []

    var webAccounts: [Account] { accounts.filter { $0.kind == .web || $0.kind == .demo } }
    var deviceAccount: Account? { accounts.first { $0.kind == .mac } }

    func start() {
        reloadAccounts()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AccountManager.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.reloadAccounts() }
        })
        observers.append(nc.addObserver(forName: TransferManager.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = AppState.shared
                s.activeTransfers = TransferManager.shared.active.count
                s.transfersVersion &+= 1
                LongRun.keepAliveWhileBusy(s.activeTransfers > 0)
            }
        })
    }

    func reloadAccounts() {
        accounts = AccountManager.shared.accounts
        if let device = deviceAccount {
            device.title = UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        }
        accountsVersion &+= 1
        // A selection that points at an account that's gone (signed out) falls back to the account list.
        if let sel = selection, let id = sel.accountID, account(id) == nil { selection = .accounts }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    func setReadOnly(_ on: Bool) {
        Prefs.readOnlyICloud = on
        readOnly = on
    }

    func show(_ message: String) {
        toast = message
        let m = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if AppState.shared.toast == m { AppState.shared.toast = nil }
        }
    }

    /// Passwords unlocked with Face ID stay in memory only while needed: dropped when the setting changes,
    /// and when Cirrus goes to the background with nothing running (a running job may need to sign in again).
    func forgetUnlockedPasswords() {
        let ids = accounts.compactMap { $0.kind == .web ? $0.appleID : nil }
        Task { for id in ids { await CredentialGate.shared.forget(id) } }
    }

    /// Turns on or off the built-in demo account (a fake iCloud on this device; never touches real accounts).
    func setDemo(_ on: Bool) {
        Prefs.showDemoAccount = on
        AccountManager.shared.demoMode = on || ProcessInfo.processInfo.environment["CIRRUS_DEMO"] != nil
        AccountManager.shared.load()
    }
}

extension Destination {
    var accountID: String? {
        switch self {
        case .drive(let a), .driveTrash(let a), .photos(let a), .albums(let a): return a
        default: return nil
        }
    }
}

extension Account {
    var isDevice: Bool { kind == .mac }
    var displayTitle: String { kind == .demo ? "Demo iCloud" : title }
    var subtitle: String? {
        switch kind {
        case .web: return appleID != title ? appleID : nil
        case .demo: return "Sample data on this device"
        case .mac: return "Photos on this device"
        }
    }
    var needsSignIn: Bool { if case .needsSignIn = status { return true }; return false }
}
