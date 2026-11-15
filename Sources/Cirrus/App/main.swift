import AppKit

// One Cirrus at a time, whatever the build, profile or copy: a second launch brings the running one
// forward and quits before it shows a Dock icon, menu bar item or window. There is no override.
guard SingleInstance.claim() else { exit(0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
