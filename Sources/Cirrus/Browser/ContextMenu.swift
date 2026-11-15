import AppKit
import CirrusCore

@MainActor
enum ContextMenu {
    static func item(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.keyEquivalentModifierMask = mods
        if let symbol { m.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return m
    }

    static func build(for items: [Item], pane: PaneController) -> NSMenu {
        let menu = NSMenu()
        let loc = pane.location
        let caps = pane.caps
        func add(_ i: NSMenuItem) { i.target = pane; menu.addItem(i) }
        func sep() { if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) } }

        if items.isEmpty {
            if caps.canCreateFolder { add(item(caps.newFolderTitle, #selector(PaneController.newFolder(_:)), symbol: caps.newFolderTitle == "New Album" ? "rectangle.stack.badge.plus" : "folder.badge.plus")) }
            if caps.acceptsDrops {
                let isPhotos: Bool = { switch loc { case .photos, .album: return true; default: return false } }()
                if loc.isRemote { add(item(isPhotos ? "Import Photos and Videos…" : "Upload Files…", #selector(PaneController.uploadHere(_:)), symbol: "square.and.arrow.up")) }
                add(item("Paste", #selector(PaneController.paste(_:)), symbol: "doc.on.clipboard"))
            }
            sep()
            add(item("Refresh", #selector(PaneController.refresh(_:)), symbol: "arrow.clockwise"))
            add(item("Get Info", #selector(PaneController.getInfo(_:)), symbol: "info.circle"))
            if loc.localURL != nil { add(item("Show in Finder", #selector(PaneController.showInFinder(_:)), symbol: "folder")) }
            sep()
            let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (t, s) in [("as Icons", #selector(PaneController.setIconView(_:))), ("as List", #selector(PaneController.setListView(_:)))] {
                let m = NSMenuItem(title: t, action: s, keyEquivalent: ""); m.target = pane; m.state = (s == #selector(PaneController.setIconView(_:))) == (pane.viewMode == .icons) ? .on : .off; sub.addItem(m)
            }
            sub.addItem(.separator())
            for (k, t) in [(SortKey.name, "Name"), (.date, "Date"), (.size, "Size"), (.kind, "Kind")] {
                let m = NSMenuItem(title: "Sort by " + t, action: #selector(PaneController.sortBy(_:)), keyEquivalent: "")
                m.identifier = .init(k.rawValue); m.target = pane; m.state = pane.sortKey == k ? .on : .off
                sub.addItem(m)
            }
            view.submenu = sub
            menu.addItem(view)
            return menu
        }

        let containers = items.filter(\.isContainer)
        let files = items.filter { !$0.isContainer }
        let isTrash = caps.isTrash
        if isTrash {
            add(item("Put Back", #selector(PaneController.restoreSelection(_:)), symbol: "arrow.uturn.backward"))
            if case .driveTrash = loc { add(item("Delete Immediately…", #selector(PaneController.deleteImmediately(_:)), symbol: "trash.slash")) }
            sep()
            add(item("Get Info", #selector(PaneController.getInfo(_:)), symbol: "info.circle", key: "i"))
            return menu
        }
        add(item("Open", #selector(PaneController.openSelection(_:)), symbol: nil, key: "o"))
        if !containers.isEmpty && containers.allSatisfy({ $0.target != nil }) {
            add(item("Open in New Tab", #selector(PaneController.openInNewTab(_:)), symbol: "plus.rectangle.on.rectangle"))
            if pane.browser?.isDualPane == true { add(item("Open in Other Pane", #selector(PaneController.openInOtherPane(_:)), symbol: "rectangle.split.2x1")) }
        }
        if let u = files.first?.localURL, files.count == 1 { menu.addItem(openWith(u)) }
        if !files.isEmpty { add(item("Quick Look", #selector(PaneController.quickLook(_:)), symbol: "eye", key: "y")) }
        sep()

        // Moving data around
        let remote = items.contains { $0.localURL == nil && $0.volume == nil }
        if remote {
            add(item(items.allSatisfy(\.isPhoto) ? "Export to Downloads" : "Download", #selector(PaneController.downloadToDownloads(_:)), symbol: "arrow.down.circle"))
            add(item(items.allSatisfy(\.isPhoto) ? "Export Originals To…" : "Download To…", #selector(PaneController.downloadTo(_:)), symbol: "square.and.arrow.down.on.square"))
        }
        add(item("Copy To…", #selector(PaneController.copyToPicker(_:)), symbol: "doc.on.doc"))
        if items.allSatisfy({ $0.localURL != nil || $0.driveNode != nil }) && !caps.readOnly {
            add(item("Move To…", #selector(PaneController.moveToPicker(_:)), symbol: "folder.badge.arrow.forward"))
        }
        // Native iCloud Drive (Mac signed in)
        if items.contains(where: { $0.cloud == .cloudOnly }) { add(item("Download Now", #selector(PaneController.downloadNow(_:)), symbol: "icloud.and.arrow.down")) }
        if items.contains(where: { $0.cloud == .downloaded }) || (containers.contains { $0.localURL.map { isInNativeDrive($0) } ?? false }) {
            add(item("Remove Download", #selector(PaneController.removeDownload(_:)), symbol: "icloud.slash"))
        }
        // Photos
        if items.contains(where: \.isPhoto), let photos = loc.account?.photos {
            sep()
            if photos.capabilities.contains(.favorite) {
                let allFav = items.filter(\.isPhoto).allSatisfy { $0.photo?.isFavorite == true }
                add(item(allFav ? "Unfavorite" : "Favorite", #selector(PaneController.toggleFavorite(_:)), symbol: allFav ? "heart.slash" : "heart", key: "."))
            }
            if photos.capabilities.contains(.hide) {
                let allHidden = items.filter(\.isPhoto).allSatisfy { $0.photo?.isHidden == true }
                add(item(allHidden ? "Unhide" : "Hide", #selector(PaneController.toggleHidden(_:)), symbol: allHidden ? "eye" : "eye.slash", key: "l"))
            }
            if photos.capabilities.contains(.albums), case .album(let a, let lib, _) = loc {
                let albums = (Catalog.shared.albumIndex[a + "|" + lib] ?? []).filter { $0.kind == .album }
                let addTo = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
                addTo.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
                let sub = NSMenu()
                for al in albums.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    let m = NSMenuItem(title: al.name, action: #selector(PaneController.addToAlbum(_:)), keyEquivalent: "")
                    m.representedObject = al; m.target = pane
                    sub.addItem(m)
                }
                if albums.isEmpty { sub.addItem(NSMenuItem(title: "No Albums", action: nil, keyEquivalent: "")) }
                sub.addItem(.separator())
                let n = NSMenuItem(title: "New Album…", action: #selector(PaneController.newAlbumWithSelection(_:)), keyEquivalent: ""); n.target = pane
                sub.addItem(n)
                addTo.submenu = sub
                menu.addItem(addTo)
            }
        }
        if items.contains(where: { it in
            if case .camera = it.payload { return true }
            return it.volume?.isEjectable == true
        }) {
            add(item("Eject", #selector(PaneController.ejectSelection(_:)), symbol: "eject", key: "e"))
        }
        sep()
        if items.count == 1 && pane.canRename(items[0]) { add(item("Rename", #selector(PaneController.renameSelection(_:)), symbol: "pencil")) }
        if items.contains(where: { $0.localURL != nil }) && caps.canCreateFolder {
            add(item("Duplicate", #selector(PaneController.duplicate(_:)), symbol: "plus.square.on.square", key: "d"))
            add(item(items.count == 1 ? "Compress “\(items[0].name)”" : "Compress \(items.count) Items", #selector(PaneController.compress(_:)), symbol: "archivebox"))
        }
        if caps.canTrash || items.contains(where: \.isPhoto) {
            let title: String
            switch loc {
            case .drive: title = "Move to Recently Deleted"
            case .album: title = "Delete"
            case .device: title = "Delete from Device…"
            default: title = "Move to Trash"
            }
            let t = item(title, #selector(PaneController.moveToTrash(_:)), symbol: "trash", key: "\u{8}")
            menu.addItem(.separator())
            add(t)
        }
        sep()
        add(item("Get Info", #selector(PaneController.getInfo(_:)), symbol: "info.circle", key: "i"))
        add(item("Copy", #selector(PaneController.copy(_:)), symbol: "doc.on.doc", key: "c"))
        if items.contains(where: { $0.localURL != nil }) {
            add(item("Copy Path", #selector(PaneController.copyPath(_:)), symbol: "link", key: "c", mods: [.command, .option]))
            add(item("Show in Finder", #selector(PaneController.showInFinder(_:)), symbol: "folder", key: "r"))
        }
        if let urls = Optional(items.compactMap(\.localURL)), !urls.isEmpty {
            let share = NSMenuItem(title: "Share…", action: nil, keyEquivalent: "")
            share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            let sub = NSMenu()
            for s in NSSharingService.sharingServices(forItems: urls) {
                let m = NSMenuItem(title: s.menuItemTitle, action: #selector(ShareTarget.share(_:)), keyEquivalent: "")
                m.image = s.image; m.representedObject = (s, urls); m.target = ShareTarget.shared
                sub.addItem(m)
            }
            share.submenu = sub
            menu.addItem(share)
        }
        return menu
    }

    static func isInNativeDrive(_ u: URL) -> Bool {
        guard let root = AccountManager.shared.macAccount?.driveRoot else { return false }
        return u.standardizedFileURL.path.hasPrefix(root.deletingLastPathComponent().standardizedFileURL.path)
    }

    static func openWith(_ url: URL) -> NSMenuItem {
        let m = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let def = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(20) {
            let i = NSMenuItem(title: FileManager.default.displayName(atPath: app.path) + (app == def ? " (default)" : ""), action: #selector(ShareTarget.openWith(_:)), keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            i.image = icon
            i.representedObject = (app, url)
            i.target = ShareTarget.shared
            sub.addItem(i)
        }
        m.submenu = sub
        return m
    }
}

@MainActor
final class ShareTarget: NSObject {
    static let shared = ShareTarget()
    @objc func share(_ sender: NSMenuItem) {
        guard let (s, urls) = sender.representedObject as? (NSSharingService, [URL]) else { return }
        s.perform(withItems: urls)
    }
    @objc func openWith(_ sender: NSMenuItem) {
        guard let (app, url) = sender.representedObject as? (URL, URL) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
