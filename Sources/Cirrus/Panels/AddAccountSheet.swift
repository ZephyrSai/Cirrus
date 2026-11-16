import AppKit
import CirrusCore

/// "Add Account…": connect another cloud beside iCloud (Nextcloud, OneDrive, Google Drive, any WebDAV server).
/// Sign-ins happen in the browser wherever the service allows it, so Cirrus never sees those passwords.
@MainActor
final class AddAccountSheet: NSWindowController, NSTextFieldDelegate {
    private static var current: AddAccountSheet?

    static func show(on parent: NSWindow?, provider: CloudProvider? = nil, reconnecting: CloudAccountRecord? = nil) {
        if let c = current { c.window?.makeKeyAndOrderFront(nil); return }
        let s = AddAccountSheet(provider: provider ?? reconnecting?.provider ?? .nextcloud, reconnecting: reconnecting)
        current = s
        if let parent, parent.attachedSheet == nil { parent.beginSheet(s.window!) } else { s.window?.center(); s.showWindow(nil) }
    }

    static func reconnect(_ id: String, on parent: NSWindow?) {
        guard let r = AccountManager.shared.account(id: id)?.cloud else { return }
        show(on: parent, reconnecting: r)
    }

    let providers: [CloudProvider] = [.nextcloud, .onedrive, .googleDrive, .webdav]
    private(set) var provider: CloudProvider
    let reconnecting: CloudAccountRecord?

    let picker = NSSegmentedControl()
    let info = NSTextField(wrappingLabelWithString: "")
    let serverField = NSTextField()
    let userField = NSTextField()
    let passField = NSSecureTextField()
    let clientField = NSTextField()
    var rows = [CloudFormRow]()
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let primary = NSButton(title: "Continue", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var work: Task<Void, Never>?
    var googleSetup: GoogleSetupSheet?

    enum CloudFormRow { case server, user, password, clientID }

    init(provider: CloudProvider, reconnecting: CloudAccountRecord?) {
        self.provider = provider
        self.reconnecting = reconnecting
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Add Account"
        super.init(window: w)
        build()
        if let r = reconnecting {
            serverField.stringValue = r.provider == .webdav ? (r.server ?? "") : (r.server.flatMap { URL(string: $0)?.host } ?? r.server ?? "")
            userField.stringValue = r.username ?? ""
            picker.isEnabled = false
        }
        select(provider)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    var formStack = NSStackView()

    func build() {
        let title = NSTextField(labelWithString: reconnecting == nil ? "Add an Account" : "Sign In Again")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: reconnecting == nil
            ? "Browse, move, sync and copy between your other clouds the same way as iCloud. Nothing changes on a service until you move files there."
            : "Reconnect \(reconnecting!.provider.displayName) (\(reconnecting!.title)). Your files and Cirrus’s jobs stay as they are.")
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 470

        picker.segmentCount = providers.count
        for (i, p) in providers.enumerated() {
            picker.setLabel(p == .webdav ? "Other WebDAV" : p.displayName, forSegment: i)
            picker.setImage(NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil), forSegment: i)
            picker.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        picker.trackingMode = .selectOne
        picker.segmentDistribution = .fillEqually
        picker.target = self
        picker.action = #selector(pickerChanged)

        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = 470
        info.isSelectable = true

        serverField.placeholderString = "cloud.example.com"
        userField.placeholderString = "Name"
        passField.placeholderString = "App password"
        clientField.placeholderString = "00000000-0000-0000-0000-000000000000"
        for f in [serverField, userField, passField, clientField] as [NSTextField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 340).isActive = true
            f.lineBreakMode = .byTruncatingMiddle
        }
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 8

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.preferredMaxLayoutWidth = 440
        status.font = .systemFont(ofSize: 12)
        let statusRow = NSStackView(views: [spinner, status])
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        cancelButton.target = self; cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        primary.target = self; primary.action = #selector(primaryClicked)
        primary.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, primary])
        buttons.spacing = 10

        let stack = NSStackView(views: [title, sub, picker, info, formStack, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
            picker.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        window?.contentView = content
    }

    func field(_ label: String, _ f: NSTextField) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [l, f])
        row.spacing = 8
        return row
    }

    @objc func pickerChanged() { select(providers[max(0, picker.selectedSegment)]) }

    func select(_ p: CloudProvider) {
        provider = p
        picker.selectedSegment = providers.firstIndex(of: p) ?? 0
        for v in formStack.arrangedSubviews { formStack.removeArrangedSubview(v); v.removeFromSuperview() }
        setStatus(nil)
        switch p {
        case .nextcloud:
            info.stringValue = "Cirrus opens your Nextcloud in the browser. Approve Cirrus there and it gets an app password of its own, which you can revoke any time under Settings › Security. Cirrus never sees your Nextcloud password."
            serverField.placeholderString = "cloud.example.com"
            formStack.addArrangedSubview(field("Server:", serverField))
            primary.title = "Continue in Browser"
        case .onedrive:
            info.stringValue = "Sign in with your Microsoft account in the browser (personal, work or school). Cirrus gets access to your OneDrive files, nothing else, and keeps the sign-in in your Keychain."
            if CloudConnect.oneDriveClientID.isEmpty {
                info.stringValue += "\n\nThis copy of Cirrus has no Microsoft app ID yet. Register a free app at entra.microsoft.com (App registrations › New registration, “Personal Microsoft accounts and work or school accounts”, redirect “Mobile and desktop” http://localhost) and paste its Application (client) ID."
                formStack.addArrangedSubview(field("App (client) ID:", clientField))
            }
            primary.title = "Sign In with Microsoft"
        case .googleDrive:
            info.stringValue = "Uses your own Google sign-in setup, the same one “Move to or from Google” uses, so it’s free and private to you. Google warns that the app isn’t verified because it’s your own setup: choose Continue."
            primary.title = GoogleAccounts.shared.isConfigured ? "Sign In with Google" : "Set Up Google Sign-In…"
        case .webdav:
            info.stringValue = "For ownCloud, OpenCloud, Synology, QNAP, Apache and other WebDAV servers. Use an app password if your server offers them. Cirrus keeps it in your Keychain. (Nextcloud servers are detected and connected as Nextcloud.)"
            serverField.placeholderString = "https://files.example.com/remote.php/webdav/"
            formStack.addArrangedSubview(field("WebDAV address:", serverField))
            formStack.addArrangedSubview(field("User name:", userField))
            formStack.addArrangedSubview(field("Password:", passField))
            primary.title = "Connect"
        }
        validate()
        window?.recalculateKeyViewLoop()
        if let f = formStack.arrangedSubviews.first?.subviews.last as? NSTextField, f.stringValue.isEmpty { window?.makeFirstResponder(f) }
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    func validate() {
        guard work == nil else { primary.isEnabled = false; return }
        let s = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        switch provider {
        case .nextcloud: primary.isEnabled = !s.isEmpty
        case .webdav: primary.isEnabled = !s.isEmpty && !userField.stringValue.isEmpty && !passField.stringValue.isEmpty
        case .onedrive: primary.isEnabled = !CloudConnect.oneDriveClientID.isEmpty || CloudConnect.looksLikeClientID(clientField.stringValue)
        case .googleDrive: primary.isEnabled = true
        }
    }

    func setStatus(_ text: String?, busy: Bool = false, error: Bool = false) {
        status.stringValue = text ?? ""
        status.textColor = error ? .systemRed : .secondaryLabelColor
        status.isHidden = text == nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Actions

    @objc func cancelClicked() {
        if let w = work { w.cancel(); work = nil; setStatus(nil); validate(); picker.isEnabled = reconnecting == nil; return }
        close(nil)
    }

    func close(_ added: Account?) {
        work?.cancel()
        if let w = window { if let p = w.sheetParent { p.endSheet(w) } else { w.orderOut(nil) } }
        AddAccountSheet.current = nil
        if let a = added, let d = a.drive {
            (NSApp.delegate as? AppDelegate)?.activeBrowser?.activePane?.navigate(to: .drive(a.id, d.rootID))
        }
    }

    @objc func primaryClicked() {
        if provider == .googleDrive && !GoogleAccounts.shared.isConfigured { setUpGoogle(); return }
        let p = provider
        let server = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        let client = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        picker.isEnabled = false
        let open: @Sendable (URL) async -> Void = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: (CloudAccountRecord, CloudSecret)
                switch p {
                case .nextcloud:
                    self.setStatus("Opening \(server) in your browser…", busy: true)
                    result = try await CloudConnect.nextcloud(server: server, open: open) { [weak self] in
                        self?.setStatus("Approve Cirrus in the browser window that just opened. Waiting…", busy: true)
                    }
                case .onedrive:
                    if !client.isEmpty { CloudConnect.oneDriveClientID = client }
                    self.setStatus("Sign in with Microsoft in your browser. Waiting…", busy: true)
                    result = try await CloudConnect.oneDrive(open: open)
                case .googleDrive:
                    self.setStatus("Sign in with Google in your browser. Waiting…", busy: true)
                    result = try await CloudConnect.googleDrive(open: open)
                case .webdav:
                    self.setStatus("Connecting to the server…", busy: true)
                    result = try await CloudConnect.webdav(url: server, user: user, password: pass)
                }
                try Task.checkCancellation()
                var (record, secret) = result
                if let r = self.reconnecting { record.id = r.id }
                else if let existing = AccountManager.shared.existingCloud(matching: record) { record.id = existing.id }
                let a = AccountManager.shared.addCloud(record, secret: secret)
                NSApp.activate(ignoringOtherApps: true)
                self.work = nil
                self.close(a)
            } catch is CancellationError {
                self.work = nil
            } catch {
                self.work = nil
                self.picker.isEnabled = self.reconnecting == nil
                self.setStatus(error.localizedDescription, error: true)
                self.validate()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        validate()
    }

    func setUpGoogle() {
        guard let w = window, w.attachedSheet == nil else { return }
        let s = GoogleSetupSheet()
        s.completion = { [weak self] saved, connect in
            self?.googleSetup = nil
            self?.select(.googleDrive)
            if saved && connect { self?.primaryClicked() }
        }
        googleSetup = s
        w.beginSheet(s.window!)
    }
}

/// The app's side of each service's sign-in. Kept apart from the sheet so tests and the debug script can use it.
@MainActor
enum CloudConnect {
    /// OneDrive needs a Microsoft app ID: Cirrus's own (once registered) or one the user pastes.
    static var oneDriveClientID: String {
        get { UserDefaults.standard.string(forKey: "oneDriveClientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "oneDriveClientID") }
    }

    static func looksLikeClientID(_ s: String) -> Bool {
        UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) != nil
    }

    static func nextcloud(server: String, open: @escaping @Sendable (URL) async -> Void,
                          waiting: @escaping @MainActor () -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        throw CloudError.unsupported("Nextcloud isn’t available in this build yet.")
    }

    static func oneDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        throw CloudError.unsupported("OneDrive isn’t available in this build yet.")
    }

    static func googleDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        throw CloudError.unsupported("Google Drive isn’t available in this build yet.")
    }

    static func webdav(url: String, user: String, password: String) async throws -> (CloudAccountRecord, CloudSecret) {
        throw CloudError.unsupported("WebDAV isn’t available in this build yet.")
    }
}
