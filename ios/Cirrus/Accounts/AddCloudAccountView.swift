import AuthenticationServices
import CirrusCore
import SwiftUI

/// "Add Account" for other clouds (OneDrive, Google Drive, Dropbox, Nextcloud, Immich, S3 storage, WebDAV).
/// Browser sign-ins open in the system's secure web sheet, inside Cirrus; Cirrus never sees those passwords.
struct AddCloudAccountView: View {
    let reconnect: CloudAccountRecord?
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var provider: CloudProvider = .nextcloud
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var client = ""
    @State private var clientSecret = ""
    @State private var region = ""
    @State private var bucket = ""
    @State private var status: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var web = WebSignInSheet()

    static let providers: [CloudProvider] = [.nextcloud, .onedrive, .googleDrive, .dropbox, .immich, .s3, .webdav]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Service", selection: $provider) {
                        ForEach(Self.providers, id: \.self) { p in Label(Self.title(p), systemImage: p.symbol).tag(p) }
                    }
                    .disabled(reconnect != nil || task != nil)
                } footer: {
                    Text(info)
                }
                fields
                if let status {
                    Section { HStack(spacing: 10) { ProgressView(); Text(status).foregroundStyle(.secondary) } }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(reconnect == nil ? "Add Account" : "Sign In Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if task != nil { cancelWork() } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { start() }.disabled(!valid || task != nil)
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: provider) { _, _ in error = nil }
        }
    }

    static func title(_ p: CloudProvider) -> String {
        switch p {
        case .webdav: return "Other WebDAV Server"
        case .s3: return "S3 Storage"
        case .immich: return "Immich (Photos)"
        default: return p.displayName
        }
    }

    var info: String {
        switch provider {
        case .nextcloud: return "Approve Cirrus on your Nextcloud’s page. It gets an app password of its own, which you can revoke under Settings › Security."
        case .onedrive: return "Sign in with your Microsoft account (personal, work or school)." + (CloudSignIn.oneDriveClientID.isEmpty ? " This copy of Cirrus needs a Microsoft app ID: register a free app at entra.microsoft.com (any organization and personal accounts, “Mobile and desktop” redirect http://localhost) and paste its Application (client) ID." : "")
        case .googleDrive: return "Uses your own Google Cloud “Desktop app” client (free), the same kind “Move to or from Google” uses on the Mac. Google warns that the app isn’t verified: choose Continue."
        case .dropbox: return "Sign in to Dropbox." + (CloudSignIn.dropboxAppKey.isEmpty ? " This copy of Cirrus needs a Dropbox app key: create a free app at dropbox.com/developers/apps (Scoped access, Full Dropbox; allow public clients; redirect URIs http://localhost:47823, :47824 and :47825; account_info.read and files read/write permissions) and paste its App key." : "")
        case .immich: return "Create an API key in Immich under Account Settings › API Keys and paste it here. Your timeline, albums and favorites appear in Cirrus’s Photos views."
        case .s3: return "Backblaze B2, Cloudflare R2, Wasabi, MinIO, AWS and other S3-compatible storage. Leave the bucket empty to see every bucket the key can list."
        case .webdav: return "ownCloud, OpenCloud, Synology, QNAP and other WebDAV servers. Use an app password if your server has them."
        }
    }

    @ViewBuilder var fields: some View {
        switch provider {
        case .nextcloud:
            Section { TextField("cloud.example.com", text: $server).textContentType(.URL).keyboardType(.URL).noAutocaps() } header: { Text("Server") }
        case .onedrive:
            if CloudSignIn.oneDriveClientID.isEmpty {
                Section { TextField("Application (client) ID", text: $client).noAutocaps() } header: { Text("Microsoft app") }
            }
        case .googleDrive:
            if !CloudSignIn.hasGoogleClient {
                Section {
                    TextField("Client ID", text: $client).noAutocaps()
                    SecureField("Client secret", text: $clientSecret)
                } header: { Text("Your Google client") }
            }
        case .dropbox:
            if CloudSignIn.dropboxAppKey.isEmpty {
                Section { TextField("App key", text: $client).noAutocaps() } header: { Text("Dropbox app") }
            }
        case .immich:
            Section {
                TextField("https://photos.example.com", text: $server).textContentType(.URL).keyboardType(.URL).noAutocaps()
                SecureField("API key", text: $pass)
            } header: { Text("Server") }
        case .s3:
            Section {
                TextField("https://s3.us-west-004.backblazeb2.com", text: $server).keyboardType(.URL).noAutocaps()
                TextField("Region (us-east-1, auto…)", text: $region).noAutocaps()
                TextField("Bucket (optional)", text: $bucket).noAutocaps()
            } header: { Text("Endpoint") }
            Section {
                TextField("Access key ID", text: $user).noAutocaps()
                SecureField("Secret access key", text: $pass)
            } header: { Text("Key") }
        case .webdav:
            Section {
                TextField("https://files.example.com/remote.php/webdav/", text: $server).keyboardType(.URL).noAutocaps()
                TextField("User name", text: $user).textContentType(.username).noAutocaps()
                SecureField("Password or app password", text: $pass).textContentType(.password)
            } header: { Text("Server") }
        }
    }

    var actionTitle: String {
        switch provider {
        case .onedrive, .googleDrive, .dropbox, .nextcloud: return "Sign In"
        default: return "Connect"
        }
    }

    var valid: Bool {
        let s = server.trimmingCharacters(in: .whitespaces)
        switch provider {
        case .nextcloud: return !s.isEmpty
        case .onedrive: return !CloudSignIn.oneDriveClientID.isEmpty || UUID(uuidString: client.trimmingCharacters(in: .whitespaces)) != nil
        case .googleDrive: return CloudSignIn.hasGoogleClient || client.hasSuffix(".apps.googleusercontent.com")
        case .dropbox: return !CloudSignIn.dropboxAppKey.isEmpty || client.trimmingCharacters(in: .whitespaces).count >= 8
        case .immich: return !s.isEmpty && !pass.isEmpty
        case .s3, .webdav: return !s.isEmpty && !user.isEmpty && !pass.isEmpty
        }
    }

    func prefill() {
        guard let r = reconnect else { return }
        provider = r.provider
        server = r.provider == .nextcloud ? (r.server.flatMap { URL(string: $0)?.host } ?? r.server ?? "") : (r.server ?? "")
        user = r.username ?? ""
        region = r.options?["region"] ?? ""
        bucket = r.options?["bucket"] ?? ""
    }

    func cancelWork() {
        task?.cancel(); task = nil
        web.close()
        status = nil
    }

    func start() {
        error = nil
        let p = provider, s = server.trimmingCharacters(in: .whitespacesAndNewlines), u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = pass, c = client.trimmingCharacters(in: .whitespacesAndNewlines), cs = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let rg = region.trimmingCharacters(in: .whitespacesAndNewlines), bk = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = web
        sheet.onCancel = { task?.cancel(); task = nil; status = nil }
        let open: @Sendable (URL) async -> Void = { url in await MainActor.run { sheet.open(url) } }
        task = Task { @MainActor in
            do {
                let result: (CloudAccountRecord, CloudSecret)
                switch p {
                case .nextcloud:
                    status = "Waiting for you to approve Cirrus…"
                    result = try await CloudSignIn.nextcloud(server: s, open: open)
                case .onedrive:
                    if !c.isEmpty { CloudSignIn.oneDriveClientID = c }
                    status = "Sign in with Microsoft…"
                    result = try await CloudSignIn.oneDrive(open: open)
                case .googleDrive:
                    if !c.isEmpty { CloudSignIn.setGoogleClient(id: c, secret: cs.isEmpty ? nil : cs) }
                    status = "Sign in with Google…"
                    result = try await CloudSignIn.googleDrive(open: open)
                case .dropbox:
                    if !c.isEmpty { CloudSignIn.dropboxAppKey = c }
                    status = "Sign in to Dropbox…"
                    result = try await CloudSignIn.dropbox(open: open)
                case .immich:
                    status = "Connecting to Immich…"
                    result = try await CloudSignIn.immich(server: s, apiKey: pw)
                case .s3:
                    status = "Checking the key…"
                    result = try await CloudSignIn.s3(endpoint: s, region: rg, bucket: bk, accessKey: u, secretKey: pw)
                case .webdav:
                    status = "Connecting…"
                    result = try await CloudSignIn.webdav(url: s, user: u, password: pw)
                }
                sheet.onCancel = nil
                sheet.close()
                try Task.checkCancellation()
                var (record, secret) = result
                if let r = reconnect { record.id = r.id } else if let e = AccountManager.shared.existingCloud(matching: record) { record.id = e.id }
                let a = AccountManager.shared.addCloud(record, secret: secret)
                DriveFolderModel.memory = DriveFolderModel.memory.filter { !$0.key.hasPrefix(a.id + "|") }
                state.selection = a.photos != nil ? .photos(a.id) : .drive(a.id)
                state.show(reconnect == nil ? "Added \(record.provider.displayName)" : "Signed in again")
                task = nil
                dismiss()
            } catch is CancellationError {
                sheet.close()
            } catch {
                sheet.onCancel = nil
                sheet.close()
                self.error = error.localizedDescription
                status = nil
                task = nil
            }
        }
    }
}

private extension View {
    func noAutocaps() -> some View { textInputAutocapitalization(.never).autocorrectionDisabled() }
}

/// The system's secure web sheet for a sign-in page. The sign-in itself finishes elsewhere (the loopback listener
/// or Nextcloud's poll), and then Cirrus closes the sheet.
@MainActor
final class WebSignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    var onCancel: (() -> Void)?

    func open(_ url: URL) {
        #if DEBUG
        if AccountManager.shared.demoMode { return }   // the demo's fake servers approve on their own
        #endif
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            MainActor.assumeIsolated {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { self?.onCancel?() }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func close() {
        let s = session
        session = nil
        s?.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// Each service's sign-in, the iPhone side (the Mac's is CloudConnect).
@MainActor
enum CloudSignIn {
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

    static var googleClient: GoogleOAuthClient? {
        #if DEBUG
        if AccountManager.shared.demoMode {
            FakeGoogleServer.startDemo(storage: Paths.cacheDir("demo").appendingPathComponent("google", isDirectory: true))
            let st = FakeGoogleServer.state
            return GoogleOAuthClient(clientID: st.clientID, clientSecret: st.clientSecret)
        }
        #endif
        return KeychainGoogleStore().client()
    }
    static var hasGoogleClient: Bool { googleClient?.looksValid ?? false }
    static func setGoogleClient(id: String, secret: String?) { KeychainGoogleStore().setClient(GoogleOAuthClient(clientID: id, clientSecret: secret)) }

    static var demo: Bool {
        #if DEBUG
        return AccountManager.shared.demoMode
        #else
        return false
        #endif
    }

    static func nextcloud(server: String, open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        let base = try NextcloudLoginFlow.baseURL(from: server)
        let pending = try await NextcloudLoginFlow.begin(server: base, transport: CloudBackends.transport)
        #if DEBUG
        if demo { FakeWebDAVServer.approve(pending.loginURL) }
        #endif
        await open(pending.loginURL)
        let r = try await NextcloudLoginFlow.poll(pending, transport: CloudBackends.transport)
        return (r.record, r.secret)
    }

    static func webdav(url: String, user: String, password: String) async throws -> (CloudAccountRecord, CloudSecret) {
        let r = try await WebDAV.connect(url: try WebDAV.folderURL(from: url), username: user, password: password, transport: CloudBackends.transport)
        return (r.record, r.secret)
    }

    static func oneDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        let id = oneDriveClientID
        guard !id.isEmpty else { throw CloudError.notConfigured("Paste the Application (client) ID of your Microsoft app registration first.") }
        var open = open
        #if DEBUG
        if demo { open = { url in await FakeGraphServer.approve(url) } }
        #endif
        let r = try await OneDrive.signIn(clientID: id, transport: CloudBackends.transport, open: open)
        return (r.record, r.secret)
    }

    static func googleDrive(open: @escaping @Sendable (URL) async -> Void) async throws -> (CloudAccountRecord, CloudSecret) {
        guard let client = googleClient, client.looksValid else { throw CloudError.notConfigured("Enter your Google client ID first.") }
        var open = open
        var transport = CloudBackends.transport
        #if DEBUG
        if demo { open = { url in await FakeGoogleServer.approve(url) }; transport = [FakeGoogleServer.self] }
        #endif
        let r = try await GoogleDriveCloud.signIn(client: client, transport: transport, open: open)
        return (r.record, r.secret)
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
}
