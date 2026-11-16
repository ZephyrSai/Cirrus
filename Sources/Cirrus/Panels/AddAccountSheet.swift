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
        if let parent, parent.attachedSheet == nil {
            parent.beginSheet(s.window!) { _ in MainActor.assumeIsolated { if AddAccountSheet.current === s { AddAccountSheet.current = nil } } }
        } else { s.window?.center(); s.showWindow(nil) }
    }

    static func reconnect(_ id: String, on parent: NSWindow?) {
        guard let r = AccountManager.shared.account(id: id)?.cloud else { return }
        show(on: parent, reconnecting: r)
    }

    let providers: [CloudProvider] = [.nextcloud, .onedrive, .googleDrive, .dropbox, .immich, .s3, .webdav]
    private(set) var provider: CloudProvider
    let reconnecting: CloudAccountRecord?

    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let info = NSTextField(wrappingLabelWithString: "")
    let serverField = NSTextField()
    let userField = NSTextField()
    let passField = NSSecureTextField()
    let clientField = NSTextField()
    let regionField = NSTextField()
    let bucketField = NSTextField()
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
            serverField.stringValue = r.provider == .nextcloud ? (r.server.flatMap { URL(string: $0)?.host } ?? r.server ?? "") : (r.server ?? "")
            userField.stringValue = r.username ?? ""
            regionField.stringValue = r.options?["region"] ?? ""
            bucketField.stringValue = r.options?["bucket"] ?? ""
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

        for p in providers {
            picker.addItem(withTitle: Self.menuTitle(p))
            picker.lastItem?.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
        }
        picker.target = self
        picker.action = #selector(pickerChanged)

        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = 470
        info.isSelectable = true

        serverField.placeholderString = "cloud.example.com"
        userField.placeholderString = "Name"
        passField.placeholderString = "App password"
        clientField.placeholderString = "00000000-0000-0000-0000-000000000000"
        regionField.placeholderString = "us-east-1 (or auto)"
        bucketField.placeholderString = "Optional: one bucket"
        for f in [serverField, userField, passField, clientField, regionField, bucketField] as [NSTextField] {
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

        let serviceRow = field("Service:", picker)
        let stack = NSStackView(views: [title, sub, serviceRow, info, formStack, statusRow, buttons])
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
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        window?.contentView = content
    }

    static func menuTitle(_ p: CloudProvider) -> String {
        switch p {
        case .webdav: return "Other WebDAV server"
        case .s3: return "S3-compatible storage (B2, R2, Wasabi, MinIO, AWS)"
        case .immich: return "Immich (photos)"
        default: return p.displayName
        }
    }

    func field(_ label: String, _ f: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [l, f])
        row.spacing = 8
        return row
    }

    @objc func pickerChanged() { select(providers[max(0, picker.indexOfSelectedItem)]) }

    func select(_ p: CloudProvider) {
        provider = p
        picker.selectItem(at: providers.firstIndex(of: p) ?? 0)
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
                info.stringValue += "\n\nThis copy of Cirrus has no Microsoft app ID yet. Register a free one at entra.microsoft.com › App registrations › New registration: supported accounts “Accounts in any organizational directory and personal Microsoft accounts”, redirect URI platform “Public client/native (mobile & desktop)” with http://localhost. Then paste its Application (client) ID here. No client secret is needed."
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
            passField.placeholderString = "App password"
            primary.title = "Connect"
        case .dropbox:
            info.stringValue = "Sign in to Dropbox in the browser. Cirrus gets access to your Dropbox files and keeps the sign-in in your Keychain."
            if CloudConnect.dropboxAppKey.isEmpty {
                info.stringValue += "\n\nThis copy of Cirrus has no Dropbox app key yet. Create a free app at dropbox.com/developers/apps: Scoped access, Full Dropbox. Under Settings › OAuth 2, allow public clients and add the redirect URIs http://localhost:47823, http://localhost:47824 and http://localhost:47825. Under Permissions, tick account_info.read and files.metadata/files.content read and write, then Submit. Paste its App key here (no secret needed)."
                clientField.placeholderString = "App key"
                formStack.addArrangedSubview(field("App key:", clientField))
            }
            primary.title = "Sign In with Dropbox"
        case .s3:
            info.stringValue = "Backblaze B2, Cloudflare R2, Wasabi, MinIO, AWS and other S3-compatible storage. Use a key limited to the buckets Cirrus should see. Leave the bucket empty to browse every bucket the key can list."
            serverField.placeholderString = "https://s3.us-west-004.backblazeb2.com"
            formStack.addArrangedSubview(field("Endpoint:", serverField))
            formStack.addArrangedSubview(field("Region:", regionField))
            formStack.addArrangedSubview(field("Bucket:", bucketField))
            formStack.addArrangedSubview(field("Access key ID:", userField))
            passField.placeholderString = "Secret access key"
            formStack.addArrangedSubview(field("Secret key:", passField))
            primary.title = "Connect"
        case .immich:
            info.stringValue = "Your Immich photo library, with its timeline, albums and favorites, in Cirrus’s Photos views. Create an API key in Immich under Account Settings › API Keys and paste it here."
            serverField.placeholderString = "https://photos.example.com"
            formStack.addArrangedSubview(field("Server:", serverField))
            passField.placeholderString = "API key"
            formStack.addArrangedSubview(field("API key:", passField))
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
        case .dropbox: primary.isEnabled = !CloudConnect.dropboxAppKey.isEmpty || clientField.stringValue.trimmingCharacters(in: .whitespaces).count >= 8
        case .s3: primary.isEnabled = !s.isEmpty && !userField.stringValue.isEmpty && !passField.stringValue.isEmpty
        case .immich: primary.isEnabled = !s.isEmpty && !passField.stringValue.isEmpty
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
        } else if let a = added, a.photos != nil {
            (NSApp.delegate as? AppDelegate)?.activeBrowser?.activePane?.navigate(to: .album(a.id, SidebarController.libraryID(a), SidebarController.allPhotosID(a)))
        }
    }

    @objc func primaryClicked() {
        if provider == .googleDrive && !GoogleAccounts.shared.isConfigured { setUpGoogle(); return }
        let p = provider
        let server = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        let client = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = regionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucket = bucketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
                case .dropbox:
                    if !client.isEmpty { CloudConnect.dropboxAppKey = client }
                    self.setStatus("Sign in to Dropbox in your browser. Waiting…", busy: true)
                    result = try await CloudConnect.dropbox(open: open)
                case .s3:
                    self.setStatus("Checking the keys…", busy: true)
                    result = try await CloudConnect.s3(endpoint: server, region: region, bucket: bucket, accessKey: user, secretKey: pass)
                case .immich:
                    self.setStatus("Connecting to Immich…", busy: true)
                    result = try await CloudConnect.immich(server: server, apiKey: pass)
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
    /// OneDrive needs a Microsoft app ID: one the user pasted, or Cirrus's own once it's registered.
    static var oneDriveClientID: String {
        get {
            #if DEBUG
            if AccountManager.shared.demoMode { return FakeGraphServer.state.clientID }
            #endif
            let s = UserDefaults.standard.string(forKey: "oneDriveClientID") ?? ""
            return s.isEmpty ? OneDrive.defaultClientID : s
        }
        set { UserDefaults.standard.set(newValue, forKey: "oneDriveClientID") }
    }

    /// Dropbox needs an app key: one the user pasted, or Cirrus's own once it's registered.
    static var dropboxAppKey: String {
        get {
            #if DEBUG
            if AccountManager.shared.demoMode { return FakeDropboxServer.state.appKey }
            #endif
            let s = UserDefaults.standard.string(forKey: "dropboxAppKey") ?? ""
            return s.isEmpty ? Dropbox.defaultAppKey : s
        }
        set { UserDefaults.standard.set(newValue, forKey: "dropboxAppKey") }
    }

    static func dropbox(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        let key = dropboxAppKey
        guard !key.isEmpty else { throw CloudError.notConfigured("Paste the App key of your Dropbox app first.") }
        var open = open
        #if DEBUG
        if AccountManager.shared.demoMode { open = { url in await FakeDropboxServer.approve(url) } }
        #endif
        let r = try await Dropbox.signIn(appKey: key, transport: CloudBackends.transport, open: open)
        return (r.record, r.secret)
    }

    static func s3(endpoint: String, region: String, bucket: String, accessKey: String, secretKey: String) async throws -> (CloudAccountRecord, CloudSecret) {
        throw CloudError.unsupported("S3 storage isn’t available in this build yet.")
    }

    static func immich(server: String, apiKey: String) async throws -> (CloudAccountRecord, CloudSecret) {
        let r = try await Immich.connect(server: server, apiKey: apiKey, transport: CloudBackends.transport)
        return (r.record, r.secret)
    }

    static func looksLikeClientID(_ s: String) -> Bool {
        UUID(uuidString: s.trimmingCharacters(in: .whitespaces)) != nil
    }

    static func nextcloud(server: String, open: @escaping @Sendable (URL) async -> Void,
                          waiting: @escaping @MainActor () -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        let base = try NextcloudLoginFlow.baseURL(from: server)
        let pending = try await NextcloudLoginFlow.begin(server: base, transport: CloudBackends.transport)
        var demo = false
        #if DEBUG
        demo = AccountManager.shared.demoMode
        if demo { FakeWebDAVServer.approve(pending.loginURL) }
        #endif
        if !demo { await open(pending.loginURL) }
        waiting()
        let r = try await NextcloudLoginFlow.poll(pending, transport: CloudBackends.transport)
        return (r.record, r.secret)
    }

    static func oneDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        let clientID = oneDriveClientID
        guard !clientID.isEmpty else { throw CloudError.notConfigured("Paste the Application (client) ID of your Microsoft app registration first.") }
        var open = open
        #if DEBUG
        if AccountManager.shared.demoMode { open = { url in await FakeGraphServer.approve(url) } }
        #endif
        let r = try await OneDrive.signIn(clientID: clientID, transport: CloudBackends.transport, open: open)
        return (r.record, r.secret)
    }

    static func googleDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        guard let client = GoogleAccounts.shared.client, client.looksValid else {
            throw CloudError.notConfigured("Set up Google sign-in first (your own Google client, the same one “Move to or from Google” uses).")
        }
        var open = open
        #if DEBUG
        if AccountManager.shared.demoMode { open = { url in await FakeGoogleServer.approve(url) } }
        #endif
        let r = try await GoogleDriveCloud.signIn(client: client, transport: GoogleAccounts.shared.transport, open: open)
        return (r.record, r.secret)
    }

    static func webdav(url: String, user: String, password: String) async throws -> (CloudAccountRecord, CloudSecret) {
        let u = try WebDAV.folderURL(from: url)
        let r = try await WebDAV.connect(url: u, username: user, password: password, transport: CloudBackends.transport)
        return (r.record, r.secret)
    }
}
