import AppKit

@MainActor
enum MainMenu {
    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.keyEquivalentModifierMask = mods
        m.target = target
        return m
    }

    static func build(_ app: AppDelegate) -> NSMenu {
        let main = NSMenu()
        func top(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        let sep = { NSMenuItem.separator() }
        _ = top("Cirrus", [
            item("About Cirrus", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp), sep(),
            item("Settings…", #selector(AppDelegate.showPreferences(_:)), ",", target: app), sep(),
            item("Hide Cirrus", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))), sep(),
            item("Quit Cirrus", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = top("File", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n", target: app),
            item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("New Folder", #selector(PaneController.newFolder(_:)), "n", [.command, .shift]), sep(),
            item("Open", #selector(PaneController.openSelection(_:)), "o"),
            item("Open in New Tab", #selector(PaneController.openInNewTab(_:))),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"), sep(),
            item("Get Info", #selector(PaneController.getInfo(_:)), "i"),
            item("Rename", #selector(PaneController.renameSelection(_:))),
            item("Duplicate", #selector(PaneController.duplicate(_:)), "d"),
            item("Compress", #selector(PaneController.compress(_:))), sep(),
            item("Download", #selector(PaneController.downloadToDownloads(_:)), "s", [.command, .option]),
            item("Download To…", #selector(PaneController.downloadTo(_:)), "s", [.command, .shift]),
            item("Copy To…", #selector(PaneController.copyToPicker(_:)), "c", [.command, .control]),
            item("Move To…", #selector(PaneController.moveToPicker(_:)), "m", [.command, .control]),
            item("Upload or Import Files…", #selector(PaneController.uploadHere(_:)), "u"),
            item("Download Now (iCloud)", #selector(PaneController.downloadNow(_:))),
            item("Remove Download (iCloud)", #selector(PaneController.removeDownload(_:))), sep(),
            item("Quick Look", #selector(PaneController.quickLook(_:)), "y"),
            item("Show in Finder", #selector(PaneController.showInFinder(_:)), "r", [.command, .option]), sep(),
            item("Move to Trash", #selector(PaneController.moveToTrash(_:)), "\u{8}"),
            item("Eject", #selector(PaneController.ejectSelection(_:)), "e"), sep(),
            item("Sign In with Apple ID…", #selector(AppDelegate.signInMenu(_:)), target: app),
        ])
        let editMenu = top("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]), sep(),
            item("Copy", #selector(PaneController.copy(_:)), "c"),
            item("Paste", #selector(PaneController.paste(_:)), "v"),
            item("Move Item Here", #selector(PaneController.pasteMove(_:)), "v", [.command, .option]),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            item("Copy Path", #selector(PaneController.copyPath(_:)), "c", [.command, .option]), sep(),
            item("Favorite", #selector(PaneController.toggleFavorite(_:)), "."),
            item("Hide Photo", #selector(PaneController.toggleHidden(_:)), "l"), sep(),
            item("Filter…", #selector(AppDelegate.focusSearch(_:)), "f", target: app),
        ])
        editMenu.delegate = MenuDeduper.shared
        let view = top("View", [
            item("as Icons", #selector(PaneController.setIconView(_:)), "1"),
            item("as List", #selector(PaneController.setListView(_:)), "2"), sep(),
            item("Two Panes", #selector(BrowserWindowController.toggleDualPane(_:)), "2", [.command, .control]),
            item("Show Hidden Files", #selector(BrowserWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]),
            item("Group Photos by Month", #selector(BrowserWindowController.toggleGrouping(_:))),
            item("Square Photo Grid", #selector(BrowserWindowController.toggleSquareGrid(_:))),
            item("Keep Folders on Top", #selector(BrowserWindowController.toggleFoldersOnTop(_:))), sep(),
            item("Refresh", #selector(PaneController.refresh(_:)), "r"), sep(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        _ = view
        _ = top("Go", [
            item("Back", #selector(PaneController.goBackAction(_:)), "["),
            item("Forward", #selector(PaneController.goForwardAction(_:)), "]"),
            item("Enclosing Folder", #selector(PaneController.goUpAction(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))), sep(),
            item("Home", #selector(AppDelegate.goPlace(_:)), "h", [.command, .shift], target: app).tagged(1),
            item("Desktop", #selector(AppDelegate.goPlace(_:)), "d", [.command, .shift], target: app).tagged(2),
            item("Documents", #selector(AppDelegate.goPlace(_:)), "o", [.command, .shift], target: app).tagged(3),
            item("Downloads", #selector(AppDelegate.goPlace(_:)), "l", [.command, .option], target: app).tagged(4),
            item("iCloud Drive", #selector(AppDelegate.goPlace(_:)), "i", [.command, .shift], target: app).tagged(5),
            item("Photos", #selector(AppDelegate.goPlace(_:)), "p", [.command, .shift], target: app).tagged(6),
            item("This Mac", #selector(AppDelegate.goPlace(_:)), "c", [.command, .shift], target: app).tagged(7), sep(),
            item("Go to Folder…", #selector(AppDelegate.goToFolder(_:)), "g", [.command, .shift], target: app),
        ])
        _ = top("Sync", [
            item("Back Up iCloud…", #selector(AppDelegate.showBackup(_:)), "b", [.command, .shift], target: app),
            item("Move to or from Google…", #selector(AppDelegate.showMigration(_:)), target: app),
            item("Sync Jobs…", #selector(AppDelegate.showSyncMenu(_:)), "j", [.command, .shift], target: app),
            item("Run All Scheduled Jobs Now", #selector(AppDelegate.runAllJobs(_:)), target: app),
        ])
        let window = top("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))), sep(),
            item("Transfers", #selector(AppDelegate.showTransfersWindow(_:)), "t", [.command, .option], target: app),
            item("Info", #selector(PaneController.getInfo(_:)), "i", [.command, .option]), sep(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        let help = top("Help", [item("Cirrus Help", #selector(AppDelegate.showHelp(_:)), target: app)])
        NSApp.helpMenu = help
        return main
    }
}

extension NSMenuItem {
    func tagged(_ t: Int) -> NSMenuItem { tag = t; return self }
}

/// AppKit inserts Dictation / Emoji / AutoFill items into the Edit menu itself and sometimes does it
/// more than once; drop repeated entries whenever the menu opens.
@MainActor
final class MenuDeduper: NSObject, NSMenuDelegate {
    static let shared = MenuDeduper()
    func menuNeedsUpdate(_ menu: NSMenu) {
        var seen = Set<String>()
        var lastWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem {
                if lastWasSeparator { menu.removeItem(item) }
                lastWasSeparator = true
                continue
            }
            lastWasSeparator = false
            let key = item.title + "|" + (item.action.map(NSStringFromSelector) ?? "")
            if !seen.insert(key).inserted { menu.removeItem(item) }
        }
    }
}
