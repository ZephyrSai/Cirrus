import AppKit
import CirrusCore

/// Guided, one-time setup of the user's own Google OAuth client ("Desktop app"). Cirrus can't ship
/// a shared client without Google's app verification, so each person uses their own Cloud project.
@MainActor
final class GoogleSetupSheet: NSWindowController, NSTextFieldDelegate {
    struct Step { let title: String; let detail: String; let link: String?; let linkTitle: String }

    static let steps: [Step] = [
        Step(title: "Create a Google Cloud project",
             detail: "Sign in with the Google account you’re moving to. Name the project “Cirrus” (any name works) and select Create.",
             link: "https://console.cloud.google.com/projectcreate", linkTitle: "Open Projects"),
        Step(title: "Turn on the Google Drive API",
             detail: "Check that your new project is selected at the top, then select Enable.",
             link: "https://console.cloud.google.com/apis/library/drive.googleapis.com", linkTitle: "Open Drive API"),
        Step(title: "Turn on the Photos Library API",
             detail: "Select Enable.",
             link: "https://console.cloud.google.com/apis/library/photoslibrary.googleapis.com", linkTitle: "Open Photos API"),
        Step(title: "Only for Google → iCloud: turn on the Photos Picker API",
             detail: "Lets you pick photos in Google Photos to copy into iCloud. Select Enable. (Skip this if you only move to Google.)",
             link: "https://console.cloud.google.com/apis/library/photospicker.googleapis.com", linkTitle: "Open Picker API"),
        Step(title: "Set up the consent screen",
             detail: "Select Get started. App name: Cirrus. User support email: your address. Audience: External. Contact email: your address. Agree to the policy and select Create.",
             link: "https://console.developers.google.com/auth/branding", linkTitle: "Open Branding"),
        Step(title: "Add yourself as a test user",
             detail: "Under Test users, select Add users, enter the Google address you’re moving to, and select Save. Leave the publishing status on Testing.",
             link: "https://console.developers.google.com/auth/audience", linkTitle: "Open Audience"),
        Step(title: "Add the permissions",
             detail: "Select Add or remove scopes. Under “Manually add scopes”, paste these lines, select Add to table, then Update and Save.\n\(GoogleScopes.driveFile)\n\(GoogleScopes.photosAppend)\nTo copy from Google into iCloud too, also add (Google calls reading Drive “restricted” — fine for your own project):\n\(GoogleScopes.driveReadonly)\n\(GoogleScopes.photosPicker)",
             link: "https://console.developers.google.com/auth/scopes", linkTitle: "Open Data Access"),
        Step(title: "Create the client",
             detail: "Select Create client. Application type: Desktop app. Name: Cirrus for Mac. Select Create, then copy the Client ID and Client secret into the boxes below — Google shows the secret in full only this once.",
             link: "https://console.developers.google.com/auth/clients", linkTitle: "Open Clients"),
    ]

    let clientField = NSTextField()
    let secretField = NSSecureTextField()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    let connectButton = NSButton(title: "Save and Connect", target: nil, action: nil)
    var completion: ((_ saved: Bool, _ connect: Bool) -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Set Up Google Access"
        super.init(window: w)
        build()
        if let c = GoogleAccounts.shared.client { clientField.stringValue = c.clientID; secretField.stringValue = c.clientSecret ?? "" }
        validate()
    }
    required init?(coder: NSCoder) { fatalError() }

    func text(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, selectable: Bool = false, width: CGFloat = 410) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.isSelectable = selectable
        t.preferredMaxLayoutWidth = width
        return t
    }

    func build() {
        let title = text("Connect Cirrus to Google", size: 17, weight: .semibold, width: 580)
        let intro = text("Google lets apps like Cirrus copy into your account only through a “client” you create in your own Google Cloud project. It’s free and takes about five minutes, once. Each button opens the right page in your browser.",
                         color: .secondaryLabelColor)
        intro.preferredMaxLayoutWidth = 580
        var rows: [NSView] = [title, intro]
        for (i, s) in Self.steps.enumerated() {
            let num = NSTextField(labelWithString: "\(i + 1)")
            num.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            num.alignment = .center
            num.textColor = .white
            num.wantsLayer = true
            num.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            num.layer?.cornerRadius = 11
            num.translatesAutoresizingMaskIntoConstraints = false
            num.widthAnchor.constraint(equalToConstant: 22).isActive = true
            num.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let body = NSStackView(views: [text(s.title, size: 13, weight: .semibold), text(s.detail, color: .secondaryLabelColor, selectable: true)])
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 2
            // A fixed width keeps the wrapped text's height right (otherwise long steps get cut off).
            body.translatesAutoresizingMaskIntoConstraints = false
            body.widthAnchor.constraint(equalToConstant: 410).isActive = true
            body.setContentCompressionResistancePriority(.required, for: .vertical)
            let open = NSButton(title: s.linkTitle, target: self, action: #selector(openLink(_:)))
            open.bezelStyle = .push
            open.controlSize = .small
            open.tag = i
            open.setContentHuggingPriority(.required, for: .horizontal)
            open.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [num, body, NSView(), open])
            row.alignment = .top
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 584).isActive = true
            rows.append(row)
        }
        clientField.placeholderString = "1234567890-abcdefg.apps.googleusercontent.com"
        secretField.placeholderString = "GOCSPX-…"
        for f in [clientField, secretField] as [NSTextField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 440).isActive = true
            f.lineBreakMode = .byTruncatingMiddle
        }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Client ID:"), clientField], [NSTextField(labelWithString: "Client secret:"), secretField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.preferredMaxLayoutWidth = 580
        errorLabel.isHidden = true
        let note = text("While the project is in Testing, Google ends Cirrus’s access after 7 days; select Connect Google again when asked and the move continues where it stopped. Cirrus asks only to add files it creates in your Drive and to add photos to your library — it can’t read anything else in your Google account. The client ID and secret stay in this Mac’s keychain.",
                        size: 11, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = 580
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self; saveButton.action = #selector(save(_:))
        connectButton.target = self; connectButton.action = #selector(saveAndConnect(_:))
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, saveButton, connectButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 584).isActive = true
        rows += [grid, errorLabel, note, buttons]
        let root = NSStackView(views: rows)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.setCustomSpacing(6, after: title)
        root.setCustomSpacing(18, after: intro)
        root.setCustomSpacing(18, after: rows[Self.steps.count + 1])
        root.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 20, right: 28)
        window?.contentView = root
        window?.setContentSize(root.fittingSize)
    }

    @objc func openLink(_ b: NSButton) {
        guard let s = Self.steps[safe: b.tag]?.link, let u = URL(string: s) else { return }
        if Debug.headless { Debug.log("would open \(s)"); return }
        NSWorkspace.shared.open(u)
    }

    var entered: GoogleOAuthClient { GoogleOAuthClient(clientID: clientField.stringValue, clientSecret: secretField.stringValue) }

    func controlTextDidChange(_ obj: Notification) { validate() }

    @discardableResult
    func validate() -> Bool {
        let c = entered
        let ok = c.looksValid
        errorLabel.stringValue = c.clientID.isEmpty || ok ? "" : "That doesn’t look like a client ID: it ends in “.apps.googleusercontent.com”."
        if ok && c.clientSecret == nil { errorLabel.stringValue = "Paste the client secret too — Google asks desktop apps for it when connecting." }
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        saveButton.isEnabled = ok
        connectButton.isEnabled = ok
        return ok
    }

    func finish(saved: Bool, connect: Bool) {
        if saved { GoogleAccounts.shared.setClient(entered) }
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) } else { window?.orderOut(nil) }
        completion?(saved, connect)
        completion = nil
    }

    @objc func cancel(_ s: Any?) { finish(saved: false, connect: false) }
    @objc func save(_ s: Any?) { if validate() { finish(saved: true, connect: false) } }
    @objc func saveAndConnect(_ s: Any?) { if validate() { finish(saved: true, connect: true) } }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
