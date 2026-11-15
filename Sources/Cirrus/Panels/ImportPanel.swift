import AppKit
import CirrusCore
import UniformTypeIdentifiers

/// The “Google → iCloud” options in the Move window: Google Drive, and Google Photos from a Takeout
/// export or the Google Photos picker.
@MainActor
final class ImportPanel: NSObject {
    let drive = NSButton(checkboxWithTitle: "Google Drive (My Drive) → iCloud Drive, into a “From Google Drive” folder", target: nil, action: nil)
    let docFormat = NSPopUpButton()
    let driveAccessText = NSTextField(wrappingLabelWithString: "Reading your Google Drive needs one more permission from Google.")
    let allowDrive = NSButton(title: "Allow Reading Google Drive…", target: nil, action: nil)
    let photos = NSButton(checkboxWithTitle: "Google Photos → iCloud Photos, into a “From Google Photos” album", target: nil, action: nil)
    let chooseTakeout = NSButton(title: "Choose Takeout Export…", target: nil, action: nil)
    let takeoutLabel = NSTextField(labelWithString: "")
    let getTakeout = NSButton(title: "Get an Export…", target: nil, action: nil)
    let pick = NSButton(title: "Pick in Google Photos…", target: nil, action: nil)
    let pickLabel = NSTextField(labelWithString: "")
    let albums = NSButton(checkboxWithTitle: "Recreate my albums", target: nil, action: nil)
    let favorites = NSButton(checkboxWithTitle: "Mark my Google favorites as favorites", target: nil, action: nil)
    let live = NSButton(checkboxWithTitle: "Live Photo and motion-photo videos too", target: nil, action: nil)
    let edited = NSButton(checkboxWithTitle: "Edited copies too, as separate photos", target: nil, action: nil)
    let update = NSButton(checkboxWithTitle: "Update files changed in Google since the last run (the old iCloud copy goes to the Trash)", target: nil, action: nil)
    var view: NSStackView!
    var driveAccessRow: NSStackView!

    var takeout: [URL] = [] { didSet { refreshLabels() } }
    var picked: [GooglePickedItem] = [] { didSet { refreshLabels() } }
    var pickerSession: String?
    var pickedAt: Date?
    weak var owner: MigrationWindowController?

    func label(_ s: String, bold: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        return t
    }

    func indented(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = spacing
        s.alignment = .centerY
        s.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        return s
    }

    func build(owner: MigrationWindowController) -> NSStackView {
        self.owner = owner
        let o = ImportOptions()
        for b in [drive, photos, albums, favorites, live, edited, update] { b.target = owner; b.action = #selector(MigrationWindowController.optionsChanged) }
        drive.state = o.includeDrive ? .on : .off
        photos.state = o.includePhotos ? .on : .off
        albums.state = o.albums ? .on : .off
        favorites.state = o.favorites ? .on : .off
        live.state = o.includeLive ? .on : .off
        edited.state = o.includeEdited ? .on : .off
        update.state = o.updateChanged ? .on : .off
        docFormat.addItems(withTitles: ["Word, Excel and PowerPoint files", "PDF files"])
        docFormat.target = owner; docFormat.action = #selector(MigrationWindowController.optionsChanged)
        docFormat.controlSize = .small
        driveAccessText.font = .systemFont(ofSize: 11.5)
        driveAccessText.textColor = .secondaryLabelColor
        driveAccessText.preferredMaxLayoutWidth = 330
        for b in [allowDrive, chooseTakeout, getTakeout, pick] { b.bezelStyle = .push; b.controlSize = .small; b.target = self }
        allowDrive.action = #selector(allowDriveAccess(_:))
        chooseTakeout.action = #selector(chooseExport(_:))
        getTakeout.action = #selector(openTakeout(_:))
        pick.action = #selector(pickPhotos(_:))
        for l in [takeoutLabel, pickLabel] { l.font = .systemFont(ofSize: 11.5); l.textColor = .secondaryLabelColor; l.lineBreakMode = .byTruncatingMiddle }
        takeoutLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let docsRow = indented([label("Google Docs, Sheets and Slides as:"), docFormat])
        driveAccessRow = indented([driveAccessText, allowDrive])
        let takeoutRow = indented([chooseTakeout, takeoutLabel, getTakeout])
        let pickRow = indented([pick, pickLabel])
        let subs = NSStackView(views: [albums, favorites, live, edited])
        subs.orientation = .vertical; subs.alignment = .leading; subs.spacing = 4
        subs.edgeInsets = NSEdgeInsets(top: 2, left: 22, bottom: 0, right: 0)
        let include = label("Include", bold: true), opts = label("Options", bold: true)
        let v = NSStackView(views: [include, drive, docsRow, driveAccessRow, photos, takeoutRow, pickRow, subs, opts, update])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.setCustomSpacing(3, after: include)
        v.setCustomSpacing(3, after: opts)
        v.setCustomSpacing(14, after: driveAccessRow)
        v.setCustomSpacing(14, after: subs)
        view = v
        refreshLabels()
        return v
    }

    var options: ImportOptions {
        var o = ImportOptions()
        o.includeDrive = drive.state == .on
        o.includePhotos = photos.state == .on
        o.docFormat = docFormat.indexOfSelectedItem == 1 ? .pdf : .office
        o.albums = albums.state == .on
        o.favorites = favorites.state == .on
        o.includeLive = live.state == .on
        o.includeEdited = edited.state == .on
        o.updateChanged = update.state == .on
        return o
    }

    func refresh(for account: GoogleAccountInfo?) {
        let canRead = account?.has(GoogleScopes.driveReadonly) ?? false
        driveAccessRow.isHidden = canRead || account == nil
        let photosOn = photos.state == .on
        for b in [chooseTakeout, getTakeout, pick, albums, favorites, live, edited] { b.isEnabled = photosOn }
        docFormat.isEnabled = drive.state == .on
        allowDrive.isEnabled = drive.state == .on
        refreshLabels()
    }

    func refreshLabels() {
        if takeout.isEmpty {
            takeoutLabel.stringValue = "No export chosen"
        } else if takeout.count == 1, (try? takeout[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            takeoutLabel.stringValue = "Folder “\(takeout[0].lastPathComponent)”"
        } else {
            let bytes = takeout.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            takeoutLabel.stringValue = "\(takeout.count) part\(takeout.count == 1 ? "" : "s"), \(bytes.byteString)"
        }
        takeoutLabel.toolTip = takeout.map(\.path).joined(separator: "\n")
        pickLabel.stringValue = picked.isEmpty ? "For a few photos without an export" : "\(picked.count) picked"
    }

    @objc func chooseExport(_ sender: Any?) {
        guard let w = owner?.window else { return }
        let p = NSOpenPanel()
        p.message = "Choose every part of your Google Takeout export (.zip or .tgz), or the folder you unpacked it into."
        p.prompt = "Use Export"
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.zip, .gzip, .archive, .folder, UTType(filenameExtension: "tgz") ?? .gzip]
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated {
                self?.takeout = p.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                self?.owner?.optionsChanged()
            }
        }
    }

    @objc func openTakeout(_ sender: Any?) {
        guard let u = URL(string: "https://takeout.google.com/settings/takeout/custom/photos") else { return }
        if Debug.headless { Debug.log("would open \(u.absoluteString)"); return }
        let a = NSAlert()
        a.messageText = "Get your Google Photos from Google Takeout"
        a.informativeText = "On the page that opens, keep only Google Photos selected, choose Next step, pick “Export once”, .zip, and a part size (2 GB is fine), then Create export. Google emails you when it’s ready — download every part, then come back and choose Choose Takeout Export…. Download links expire after about a week."
        a.addButton(withTitle: "Open Google Takeout")
        a.addButton(withTitle: "Cancel")
        if let w = owner?.window {
            a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { NSWorkspace.shared.open(u) } }
        }
    }

    @objc func allowDriveAccess(_ sender: Any?) {
        let email = owner?.selectedGoogle?.email
        owner?.startConnect(scopes: GoogleAccounts.importScopes, hint: email?.isEmpty == false ? email : nil)
    }

    @objc func pickPhotos(_ sender: Any?) { owner?.startPicking() }
}
