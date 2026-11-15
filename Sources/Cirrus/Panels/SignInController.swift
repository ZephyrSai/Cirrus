import AppKit
import CirrusCore

/// Apple ID sign-in sheet: password (SRP — the password never leaves this Mac except to Apple),
/// two-factor code (device or SMS), then Advanced Data Protection approval if the account needs it.
@MainActor
final class SignInController: NSWindowController, NSTextFieldDelegate {
    var onFinish: ((String?) -> Void)?
    let appleField = NSTextField()
    let passField = NSSecureTextField()
    let remember = NSButton(checkboxWithTitle: "Remember password (unlocks with Touch ID when the session expires)", target: nil, action: nil)
    let codeField = NSTextField()
    let phonePopup = NSPopUpButton()
    let smsButton = NSButton(title: "Text Me a Code Instead", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let primary = NSButton(title: "Sign In", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let credsBox = NSStackView()
    let codeBox = NSStackView()
    let headline = NSTextField(labelWithString: "Sign in to iCloud")
    let blurb = NSTextField(wrappingLabelWithString: "")
    var session: ICloudSession?
    var phones = [TrustedPhone]()
    var smsPhone: TrustedPhone?
    enum Step { case creds, code, approval }
    var step = Step.creds
    var busy = false

    init(appleID: String?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Sign In"
        super.init(window: w)
        build()
        appleField.stringValue = appleID ?? ""
        if appleID != nil { w.initialFirstResponder = passField } else { w.initialFirstResponder = appleField }
        remember.state = .on
        if let id = appleID, CredentialGate.hasSavedPassword(id) {
            savedButton.isHidden = false
            savedButton.title = "Sign In with Saved Password"
            w.initialFirstResponder = savedButton
        }
    }

    let savedButton = NSButton(title: "", target: nil, action: nil)
    let fillButton = NSButton(title: "Fill from Passwords…", target: nil, action: nil)

    /// Opens the system Passwords AutoFill picker for the Apple ID field. macOS only suggests
    /// logins inline for apps tied to the website, so this triggers Edit › AutoFill › Passwords… directly.
    @objc func fillFromPasswords() {
        window?.makeFirstResponder(appleField.stringValue.isEmpty ? appleField : passField)
        func find(_ menu: NSMenu?) -> (NSMenu, Int)? {
            guard let menu else { return nil }
            for (i, item) in menu.items.enumerated() {
                if item.title.hasPrefix("Passwords"), menu.supermenu != nil, item.action != nil { return (menu, i) }
                if let r = find(item.submenu) { return r }
            }
            return nil
        }
        NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.update()
        if let (menu, i) = find(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu) {
            menu.performActionForItem(at: i)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.open(app)
            status.textColor = .secondaryLabelColor
            status.stringValue = "Copy your Apple ID password from the Passwords app, then paste it here."
        }
    }

    /// Re-sign-in using the password saved in Keychain, released by Touch ID / Mac password.
    @objc func useSaved() {
        let id = appleField.stringValue.lowercased()
        Task {
            guard let pw = await CredentialGate.shared.password(for: id, reason: "sign in to iCloud as \(id)") else {
                status.textColor = .systemRed; status.stringValue = "Couldn’t unlock the saved password."; return
            }
            passField.stringValue = pw
            startSignIn()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = .systemBlue
        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.stringValue = AccountManager.macSignedInToICloud
            ? "This Mac is already signed in to iCloud, and Cirrus uses that automatically. Sign in here only to browse another Apple ID."
            : "Cirrus signs in the way iCloud.com does. Your password goes only to Apple, and two-factor authentication still applies. Your saved password from the Passwords app can fill the fields."
        blurb.preferredMaxLayoutWidth = 400
        appleField.placeholderString = "Apple ID (email or phone)"
        passField.placeholderString = "Password"
        // AutoFill from the Passwords app (key icon / Edit › AutoFill › Passwords…).
        appleField.contentType = .username
        passField.contentType = .password
        for f in [appleField, passField, codeField] { f.delegate = self; f.font = .systemFont(ofSize: 13); f.bezelStyle = .roundedBezel }
        remember.font = .systemFont(ofSize: 11)
        credsBox.orientation = .vertical
        credsBox.alignment = .leading
        credsBox.spacing = 8
        fillButton.bezelStyle = .push
        fillButton.controlSize = .small
        fillButton.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        fillButton.imagePosition = .imageLeading
        fillButton.target = self
        fillButton.action = #selector(fillFromPasswords)
        fillButton.toolTip = "Pick your Apple ID login from the Passwords app (same as Edit › AutoFill › Passwords…)"
        for v in [appleField, passField, NSStackView(views: [fillButton, NSView()]), remember] as [NSView] { credsBox.addArrangedSubview(v) }
        for f in [appleField, passField] { f.widthAnchor.constraint(equalToConstant: 400).isActive = true }
        codeField.placeholderString = "6-digit code"
        codeField.contentType = .oneTimeCode   // codes texted to this Mac's Messages appear as an AutoFill suggestion
        codeField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        codeField.alignment = .center
        codeField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        smsButton.bezelStyle = .inline
        smsButton.target = self
        smsButton.action = #selector(sendSMS)
        phonePopup.isHidden = true
        codeBox.orientation = .vertical
        codeBox.alignment = .centerX
        codeBox.spacing = 10
        for v in [codeField, phonePopup, smsButton] as [NSView] { codeBox.addArrangedSubview(v) }
        codeBox.isHidden = true
        status.font = .systemFont(ofSize: 12)
        status.preferredMaxLayoutWidth = 400
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        primary.keyEquivalent = "\r"
        primary.bezelStyle = .push
        primary.target = self
        primary.action = #selector(primaryAction)
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .push
        cancel.target = self
        cancel.action = #selector(cancelAction)
        savedButton.bezelStyle = .push
        savedButton.target = self
        savedButton.action = #selector(useSaved)
        savedButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        savedButton.imagePosition = .imageLeading
        savedButton.isHidden = true
        let buttons = NSStackView(views: [spinner, savedButton, NSView(), cancel, primary])
        buttons.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let head = NSStackView(views: [icon, headline])
        head.spacing = 10
        let root = NSStackView(views: [head, blurb, credsBox, codeBox, status, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 30, bottom: 20, right: 30)
        root.setCustomSpacing(18, after: blurb)
        codeBox.widthAnchor.constraint(equalToConstant: 400).isActive = true
        window?.contentView = root
        window?.setContentSize(root.fittingSize)
    }

    func refit() { if let root = window?.contentView { window?.setContentSize(root.fittingSize) } }

    func setBusy(_ b: Bool, _ msg: String = "") {
        busy = b
        if b { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        primary.isEnabled = !b
        status.textColor = .secondaryLabelColor
        status.stringValue = msg
    }

    func fail(_ e: Error) {
        setBusy(false)
        status.textColor = .systemRed
        status.stringValue = e.localizedDescription
    }

    @objc func primaryAction() {
        guard !busy else { return }
        switch step {
        case .creds: startSignIn()
        case .code: submitCode()
        case .approval: break
        }
    }

    @objc func cancelAction() {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) } else { window?.close() }
        onFinish?(nil)
    }

    func close(with id: String?) {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) } else { window?.close() }
        onFinish?(id)
    }

    func startSignIn() {
        let appleID = appleField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let pw = passField.stringValue
        guard !appleID.isEmpty, !pw.isEmpty else { status.textColor = .systemRed; status.stringValue = "Enter your Apple ID and password."; return }
        setBusy(true, "Signing in…")
        let s = AccountManager.shared.pendingSession(appleID: appleID)
        session = s
        Task {
            do {
                switch try await s.signIn(password: pw) {
                case .signedIn: await finish()
                case .needsCode(let phones, let device):
                    self.phones = phones
                    showCodeStep(device: device)
                }
            } catch { fail(error) }
        }
    }

    func showCodeStep(device: Bool) {
        setBusy(false)
        step = .code
        credsBox.isHidden = true
        codeBox.isHidden = false
        headline.stringValue = "Two-Factor Authentication"
        blurb.stringValue = device ? "Enter the verification code shown on your iPhone, iPad or Mac." : "Choose a phone number and Cirrus will text you a code."
        primary.title = "Verify"
        smsButton.isHidden = phones.isEmpty
        refit()
        if !device && !phones.isEmpty { sendSMS() }
        window?.makeFirstResponder(codeField)
    }

    @objc func sendSMS() {
        guard let s = session, !phones.isEmpty else { return }
        if phones.count > 1 && phonePopup.isHidden {
            phonePopup.removeAllItems()
            phonePopup.addItems(withTitles: phones.map(\.number))
            phonePopup.isHidden = false
            smsButton.title = "Send Text Message"
            return
        }
        let phone = phones[phones.count > 1 ? max(0, phonePopup.indexOfSelectedItem) : 0]
        smsPhone = phone
        setBusy(true, "Sending a code to \(phone.number)…")
        Task {
            do { try await s.requestSMS(phone: phone); setBusy(false, "Code sent to \(phone.number)."); window?.makeFirstResponder(codeField) }
            catch { fail(error) }
        }
    }

    func submitCode() {
        let code = codeField.stringValue.filter(\.isNumber)
        guard code.count == 6, let s = session else { status.textColor = .systemRed; status.stringValue = "Enter the 6-digit code."; return }
        setBusy(true, "Verifying…")
        Task {
            do {
                if let p = smsPhone { try await s.submitSMSCode(code, phone: p) } else { try await s.submitCode(code) }
                await finish()
            } catch { fail(error); codeField.stringValue = "" }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if step == .code, (obj.object as? NSTextField) === codeField, codeField.stringValue.filter(\.isNumber).count == 6 { submitCode() }
    }

    func finish() async {
        guard let s = session else { return }
        let appleID = await s.state.appleID
        await AccountManager.shared.finishSignIn(appleID: appleID, session: s, rememberPassword: remember.state == .on ? passField.stringValue : nil)
        passField.stringValue = ""
        guard let acct = AccountManager.shared.account(id: "web:" + appleID), let live = acct.session else { close(with: appleID); return }
        // Advanced Data Protection: get consent now so browsing doesn't stall later.
        let info = await live.accountInfo
        let needsPCS = info["webservices"]["drivews"]["pcsRequired"].bool == true || info["webservices"]["ckdatabasews"]["pcsRequired"].bool == true
        if needsPCS {
            step = .approval
            codeBox.isHidden = true
            credsBox.isHidden = true
            headline.stringValue = "Approve Web Access"
            blurb.stringValue = "This Apple ID uses Advanced Data Protection. Check your iPhone, iPad or Mac and approve the request to let Cirrus read your iCloud data."
            primary.isHidden = true
            setBusy(true, "Waiting for approval…")
            do {
                try await live.ensurePCS(app: "iclouddrive", webservice: "drivews")
                try await live.ensurePCS(app: "photos", webservice: "ckdatabasews")
            } catch {
                fail(error)
                primary.isHidden = false
                primary.title = "Continue"
                step = .approval
                primary.action = #selector(closeAnyway)
                return
            }
        }
        setBusy(false)
        close(with: appleID)
    }

    @objc func closeAnyway() { close(with: appleField.stringValue.lowercased()) }
}
