import CirrusCore
import Foundation

enum Prefs {
    static let d = UserDefaults.standard
    static func register() {
        d.register(defaults: [
            "showHidden": false, "foldersOnTop": true, "exportLive": true, "exportEdited": false, "iconSize": 64.0, "photoSize": 120.0,
            "maxTransfers": 4, "groupPhotosByMonth": true, "showStatusBar": true, "showPathBar": true, "menuBarIcon": true,
            "openRemoteEdits": true, "squarePhotoGrid": true, "drivePreviews": true,
            "searchSubfolders": true, "calculateSizes": false, "showPreviewPane": false,
            // Tester builds (TESTER=1) start in read-only mode so nothing in iCloud can be changed until the tester opts in.
            "readOnlyICloud": (Bundle.main.object(forInfoDictionaryKey: "CirrusTesterBuild") as? Bool) ?? false,
        ])
    }
    static var showHidden: Bool { get { d.bool(forKey: "showHidden") } set { d.set(newValue, forKey: "showHidden") } }
    static var foldersOnTop: Bool { get { d.bool(forKey: "foldersOnTop") } set { d.set(newValue, forKey: "foldersOnTop") } }
    static var exportLive: Bool { get { d.bool(forKey: "exportLive") } set { d.set(newValue, forKey: "exportLive") } }
    static var exportEdited: Bool { get { d.bool(forKey: "exportEdited") } set { d.set(newValue, forKey: "exportEdited") } }
    static var groupPhotosByMonth: Bool { get { d.bool(forKey: "groupPhotosByMonth") } set { d.set(newValue, forKey: "groupPhotosByMonth") } }
    static var squarePhotoGrid: Bool { get { d.bool(forKey: "squarePhotoGrid") } set { d.set(newValue, forKey: "squarePhotoGrid") } }
    static var readOnlyICloud: Bool {
        get { d.bool(forKey: "readOnlyICloud") }
        set { d.set(newValue, forKey: "readOnlyICloud"); SafetyPolicy.readOnlyICloud = newValue }
    }
    static var searchSubfolders: Bool { get { d.bool(forKey: "searchSubfolders") } set { d.set(newValue, forKey: "searchSubfolders") } }
    static var calculateSizes: Bool { get { d.bool(forKey: "calculateSizes") } set { d.set(newValue, forKey: "calculateSizes") } }
    static var showPreviewPane: Bool { get { d.bool(forKey: "showPreviewPane") } set { d.set(newValue, forKey: "showPreviewPane") } }
    static var menuBarIcon: Bool { get { d.bool(forKey: "menuBarIcon") } set { d.set(newValue, forKey: "menuBarIcon") } }
    static var favorites: [String] {
        get {
            let h = FileManager.default.homeDirectoryForCurrentUser.path
            if Debug.screenshotMode { return ["/Applications", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures"] }
            if let f = d.stringArray(forKey: "sidebarFavorites") { return f }
            return ["/Applications", h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures"]
        }
        set { d.set(newValue, forKey: "sidebarFavorites") }
    }
}
