import CirrusCore
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

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        ContentDownloader.shared.setBackgroundEventsCompletion(completionHandler)
    }
}
