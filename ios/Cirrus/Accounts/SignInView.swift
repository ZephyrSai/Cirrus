import CirrusCore
import SwiftUI

/// Signs in to an Apple ID the way iCloud.com does (the engine's SRP flow), with two-factor codes and the
/// Advanced Data Protection approval. Password and code fields use AutoFill (Passwords, SMS codes).
struct SignInView: View {
    var prefill: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state

    enum Step { case credentials, code, approval }
    enum Field { case appleID, password, code }

    @State private var step = Step.credentials
    @State private var appleID = ""
    @State private var password = ""
    @State private var remember = true
    @State private var code = ""
    @State private var phones: [TrustedPhone] = []
    @State private var deviceCode = true
    @State private var smsPhone: TrustedPhone?
    @State private var session: ICloudSession?
    @State private var busy: String?
    @State private var message: String?
    @State private var failed = false
    @FocusState private var focus: Field?

    var normalizedID: String { appleID.trimmingCharacters(in: .whitespaces).lowercased() }
    var hasSaved: Bool { !normalizedID.isEmpty && CredentialGate.hasSavedPassword(normalizedID) }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .credentials: credentials
                case .code: codeStep
                case .approval: approval
                }
                if let message {
                    Section { Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(failed ? .red : .secondary) }
                }
            }
            .navigationTitle(step == .code ? "Verification" : step == .approval ? "Approve Access" : "Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy != nil { ProgressView() }
                    else if step == .credentials { Button("Sign In") { Task { await signIn() } }.bold().disabled(normalizedID.isEmpty || password.isEmpty) }
                    else if step == .code { Button("Verify") { Task { await verify() } }.bold().disabled(code.filter(\.isNumber).count != 6) }
                }
            }
            .interactiveDismissDisabled(busy != nil)
            .onDisappear { forgetAbandonedSession() }
            .onAppear {
                if let prefill { appleID = prefill } else if let last = AccountManager.knownAppleIDs.first, state.webAccounts.isEmpty { appleID = last }
                focus = appleID.isEmpty ? .appleID : .password
                #if DEBUG
                if DebugScreens.signInStep == "code" {
                    phones = [try? JSONDecoder().decode(TrustedPhone.self, from: Data(#"{"id":1,"number":"(•••) •••-••42","mode":"sms"}"#.utf8))].compactMap { $0 }
                    step = .code; focus = nil
                }
                if DebugScreens.signInStep != nil { focus = nil; DebugScreens.signInStep = nil }
                #endif
            }
        }
    }

    // MARK: Steps

    @ViewBuilder var credentials: some View {
        Section {
            TextField("Apple ID (email or phone)", text: $appleID)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .appleID)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signIn() } }
        } footer: {
            Text("Cirrus signs in like iCloud.com and talks only to Apple. Your password goes to Apple, and is kept on this device only if you choose to save it below.")
        }
        Section {
            Toggle("Save password on this device", isOn: $remember)
        } footer: {
            Text(Prefs.requireFaceID ? "Saved passwords stay in this device’s keychain and are unlocked with Face ID, Touch ID or your passcode when iCloud asks Cirrus to sign in again."
                                     : "Saved passwords stay in this device’s keychain. Turn on Face ID in Settings to require it before they’re used.")
        }
        if hasSaved {
            Section {
                Button { Task { await signInWithSaved() } } label: { Label("Sign In with Saved Password", systemImage: "faceid") }
            }
        }
    }

    @ViewBuilder var codeStep: some View {
        Section {
            TextField("6-digit code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.title2.monospacedDigit())
                .focused($focus, equals: .code)
                .onChange(of: code) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(6))
                    if digits != v { code = digits }
                    if digits.count == 6, busy == nil { Task { await verify() } }
                }
        } header: {
            Text(smsPhone != nil ? "Code sent to \(smsPhone!.number)" : deviceCode ? "Enter the code shown on your iPhone, iPad or Mac" : "Choose a phone number to get a code")
        }
        if !phones.isEmpty {
            Section("Didn’t get a code?") {
                ForEach(phones, id: \.id) { p in
                    Button { Task { await sendSMS(p) } } label: { Label("Text \(p.number)", systemImage: "message") }
                }
            }
        }
    }

    @ViewBuilder var approval: some View {
        Section {
            HStack(spacing: 14) {
                ProgressView()
                Text("This Apple ID uses Advanced Data Protection. On your iPhone, iPad or Mac, approve the request to let Cirrus read your iCloud data.")
            }
        }
    }

    // MARK: Flow

    func signIn() async {
        guard !normalizedID.isEmpty, !password.isEmpty, busy == nil else { return }
        let s = AccountManager.shared.pendingSession(appleID: normalizedID)
        session = s
        await run("Signing in…") {
            switch try await s.signIn(password: password) {
            case .signedIn: await finish()
            case .needsCode(let phones, let device):
                self.phones = phones
                self.deviceCode = device
                step = .code
                focus = .code
                if !device, let first = phones.first, phones.count == 1 { await sendSMS(first) }
            }
        }
    }

    func signInWithSaved() async {
        guard let pw = await CredentialGate.shared.password(for: normalizedID, reason: "sign in to iCloud as \(normalizedID)") else {
            show("The saved password wasn’t unlocked.", failed: true); return
        }
        password = pw
        remember = true
        await signIn()
    }

    func sendSMS(_ phone: TrustedPhone) async {
        guard let s = session else { return }
        await run("Sending a code…") {
            try await s.requestSMS(phone: phone)
            smsPhone = phone
            code = ""
            show("Code sent to \(phone.number).", failed: false)
            focus = .code
        }
    }

    func verify() async {
        let c = code.filter(\.isNumber)
        guard c.count == 6, let s = session, busy == nil else { return }
        await run("Verifying…") {
            if let p = smsPhone { try await s.submitSMSCode(c, phone: p) } else { try await s.submitCode(c) }
            await finish()
        }
        if failed { code = "" }
    }

    func finish() async {
        guard let s = session else { return }
        let id = await s.state.appleID
        await AccountManager.shared.finishSignIn(appleID: id, session: s, rememberPassword: remember ? password : nil)
        password = ""
        if let acct = AccountManager.shared.account(id: "web:" + id), let live = acct.session {
            // Advanced Data Protection: get consent now so browsing doesn't stall later.
            let info = await live.accountInfo
            let needsPCS = info["webservices"]["drivews"]["pcsRequired"].bool == true || info["webservices"]["ckdatabasews"]["pcsRequired"].bool == true
            if needsPCS {
                step = .approval
                do {
                    try await live.ensurePCS(app: "iclouddrive", webservice: "drivews")
                    try await live.ensurePCS(app: "photos", webservice: "ckdatabasews")
                } catch {
                    show(error.localizedDescription + " You can approve later; Cirrus asks again when you open Drive or Photos.", failed: true)
                }
            }
            state.selection = .drive(acct.id)
        }
        dismiss()
    }

    /// A sign-in abandoned halfway (e.g. at the code step) has already stored a partial session for an
    /// Apple ID that was never added: remove it, unless that Apple ID is an existing account being renewed.
    func cancel() {
        password = ""
        dismiss()
    }

    func forgetAbandonedSession() {
        password = ""
        if session != nil, !normalizedID.isEmpty, AccountManager.shared.account(id: "web:" + normalizedID) == nil {
            Keychain.delete(service: Keychain.sessionService, account: normalizedID)
        }
    }

    func run(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        message = label
        failed = false
        do { try await work(); if message == label { message = nil } }
        catch { show(error.localizedDescription, failed: true) }
        busy = nil
    }

    func show(_ m: String, failed: Bool) { message = m; self.failed = failed }
}
