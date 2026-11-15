#if DEBUG
import CirrusCore
import Foundation
import SwiftUI

/// Debug builds only (compiled out of Release): opens a given screen at launch so screenshots of the demo
/// account can be taken headlessly in the Simulator, e.g.
///   SIMCTL_CHILD_CIRRUS_DEMO=1 SIMCTL_CHILD_CIRRUS_SCREEN=photos xcrun simctl launch booted <bundle id>
/// Screens: sidebar, drive, drive-grid, drive-folder, quicklook, trash, photos, albums, album, photo, export,
/// device-photos, transfers, backup, accounts, settings, signin, code.
@MainActor
enum DebugScreens {
    static let env = ProcessInfo.processInfo.environment
    static var screen: String? { env["CIRRUS_SCREEN"] }
    static var initialPath = NavigationPath()
    static var quickLookName: String?
    static var openFirstPhoto = false
    static var openExport = false
    static var autoFolder: URL?
    static var signInStep: String?

    static func apply() {
        guard let screen else { return }
        let s = AppState.shared
        if env["CIRRUS_READ_ONLY"] == "0" { s.setReadOnly(false) } else if env["CIRRUS_READ_ONLY"] == "1" { s.setReadOnly(true) }
        Prefs.driveGrid = screen == "drive-grid"
        let demo = "demo"
        switch screen {
        case "drive", "drive-grid": s.selection = .drive(demo)
        case "drive-folder":
            s.selection = .drive(demo)
            initialPath.append(DriveFolderRef(accountID: demo, folderID: "FOLDER::demo::Pictures", title: "Pictures"))
        case "quicklook":
            s.selection = .drive(demo)
            quickLookName = "Lisbon Itinerary.pdf"
        case "trash": s.selection = .driveTrash(demo)
        case "photos": s.selection = .photos(demo)
        case "photo": s.selection = .photos(demo); openFirstPhoto = true
        case "albums": s.selection = .albums(demo)
        case "album":
            s.selection = .albums(demo)
            initialPath.append(AlbumRef(accountID: demo, library: PhotoLibraryRef(id: "demo", name: "Personal Library", isShared: false),
                                        album: PhotoAlbum(id: "album:travel", name: "Travel", kind: .album)))
        case "export":
            s.selection = .photos(demo); openExport = true
            autoFolder = folder("Exports")
        case "device-photos": s.selection = .photos("mac")
        case "transfers": s.selection = .transfers; fakeTransfers()
        case "backup":
            s.selection = .backup
            autoFolder = folder("Backup Drive")
        case "accounts": s.selection = .accounts
        case "settings": s.selection = .settings
        case "signin", "code": s.signIn = .init(appleID: "taylor@example.com"); signInStep = screen
        default: break
        }
    }

    static func folder(_ name: String) -> URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Sample queue entries so the Transfers screen can be captured mid-flight. Nothing is transferred.
    static func fakeTransfers() {
        let tm = TransferManager.shared
        tm.enqueue("Big download.bin", detail: "", direction: .download, total: 24 << 20) { t in
            t.report(0, 24 << 20); try await Task.sleep(nanoseconds: 300_000_000); t.report(24 << 20, 24 << 20)
        }
        tm.enqueue("Failed upload.mov", detail: "To iCloud Drive", direction: .upload, total: 180_000_000) { t in
            t.report(40_000_000, 180_000_000)
            throw ICloudError.http(503, "iCloud is busy")
        }
        tm.enqueue("Back Up Demo iCloud", detail: "Backup Drive", direction: .download, total: 2_400_000_000) { t in
            var done: Int64 = 0
            while done < 1_450_000_000 { done += 60_000_000; t.report(done, 2_400_000_000); t.setDetail("Photos (Personal Library): Downloading IMG_10\(done % 97).JPG"); try await Task.sleep(nanoseconds: 120_000_000) }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        tm.enqueue("Lisbon Trip.mov", detail: "To iCloud Drive", direction: .upload, total: 620_000_000) { t in
            var done: Int64 = 0
            while done < 210_000_000 { done += 15_000_000; t.report(done, 620_000_000); try await Task.sleep(nanoseconds: 150_000_000) }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        tm.enqueue("Export: All Photos — Personal Library", detail: "Exports", direction: .download, total: 96_000_000) { t in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}
#endif
