import CirrusCore
import Foundation

/// User settings (UserDefaults). Tester builds start in read-only mode, like the Mac app's `TESTER=1` builds.
enum Prefs {
    static let d = UserDefaults.standard

    /// `CIRRUS_TESTER` build setting (scripts/build-ios.sh TESTER=1) → Info.plist `CirrusTesterBuild`.
    static var isTesterBuild: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "CirrusTesterBuild") {
        case let b as Bool: return b
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }

    static func register() {
        d.register(defaults: [
            "readOnlyICloud": isTesterBuild,
            "requireAuthForSavedPassword": true,
            "drivePreviews": true,
            "driveGrid": false,
            "showDemoAccount": false,
            "exportLive": true, "exportEdited": true, "exportRAW": true, "exportManifest": true, "exportLayout": "{yyyy}/{MM}",
            "backupDrive": true, "backupPhotos": true, "backupShared": true, "backupKeepDeleted": true,
        ])
    }

    static var readOnlyICloud: Bool {
        get { d.bool(forKey: "readOnlyICloud") }
        set { d.set(newValue, forKey: "readOnlyICloud"); SafetyPolicy.readOnlyICloud = newValue }
    }
    static var requireFaceID: Bool {
        get { d.bool(forKey: "requireAuthForSavedPassword") }
        set { d.set(newValue, forKey: "requireAuthForSavedPassword") }
    }
    static var drivePreviews: Bool { get { d.bool(forKey: "drivePreviews") } set { d.set(newValue, forKey: "drivePreviews") } }
    static var driveGrid: Bool { get { d.bool(forKey: "driveGrid") } set { d.set(newValue, forKey: "driveGrid") } }
    static var showDemoAccount: Bool { get { d.bool(forKey: "showDemoAccount") } set { d.set(newValue, forKey: "showDemoAccount") } }
}
