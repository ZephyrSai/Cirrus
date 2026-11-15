import CirrusCore
import Security
import SwiftUI
import UIKit

@main
struct CirrusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppState.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            #if !DEBUG
            // Release builds honour only the user-facing switches (like the Mac app's lock-down).
            for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CIRRUS_") && key != "CIRRUS_DEMO" && key != "CIRRUS_PROFILE" {
                unsetenv(key)
            }
            Log.verbose = false
            #endif
            Self.forgetPreviousInstall()
            Prefs.register()
            SafetyPolicy.readOnlyICloud = Prefs.readOnlyICloud
            // Large downloads keep going in the system's background session while Cirrus is in the background.
            ContentDownloader.shared.enableBackgroundDownloads(identifier: (Bundle.main.bundleIdentifier ?? "cirrus") + ".downloads")
            Paths.cleanCaches()
            AccountManager.shared.demoMode = Prefs.showDemoAccount || ProcessInfo.processInfo.environment["CIRRUS_DEMO"] != nil
            AccountManager.shared.load()
            TransferManager.shared.maxConcurrent = 4
            AppState.shared.start()
            #if DEBUG
            DebugScreens.apply()
            #endif
        }
        return true
    }

    /// iOS keeps keychain items after an app is deleted. Settings live in UserDefaults, which is deleted with
    /// the app, so a missing marker means a fresh install: remove sessions and saved passwords left from before.
    static func forgetPreviousInstall() {
        let marker = "installMarker"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword] as CFDictionary)
        UserDefaults.standard.set(true, forKey: marker)
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        ContentDownloader.shared.setBackgroundEventsCompletion(completionHandler)
    }
}
