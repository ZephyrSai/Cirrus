import CirrusCore
import SwiftUI

/// Apple IDs signed in to Cirrus (any number of them), their storage, and sign-out.
struct AccountsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmSignOut: Account?

    var body: some View {
        let _ = state.accountsVersion
        List {
            ForEach(state.webAccounts, id: \.id) { AccountRow(account: $0, onSignOut: { confirmSignOut = $0 }) }
            Section {
                Button { state.signIn = .init() } label: { Label("Add Apple ID", systemImage: "person.crop.circle.badge.plus") }
            } footer: {
                Text("Each Apple ID gets its own iCloud Drive, Photos and Recently Deleted in the sidebar, even ones that aren’t the Apple ID this device is signed in to.")
            }
            if let device = state.deviceAccount {
                Section(device.title) {
                    Label("Photos library on this device", systemImage: "photo.on.rectangle.angled")
                }
            }
        }
        .navigationTitle("Accounts")
        .confirmationDialog("Sign out of \(confirmSignOut?.displayTitle ?? "")?", isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
                            titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                if let a = confirmSignOut { signOut(a) }
            }
        } message: {
            Text("Removes the session, any saved password, and this account’s cached listings, thumbnails and previews from this device. Nothing in iCloud changes, and files you saved to Files stay where they are.")
        }
    }

    func signOut(_ a: Account) {
        if state.selection?.accountID == a.id { state.selection = .accounts }
        // Like the Mac app: the engine deletes the keychain items and this account's caches.
        AccountManager.shared.signOut(a)
        PhotoCatalog.libraries[a.id] = nil
        DriveFolderModel.memory = DriveFolderModel.memory.filter { !$0.key.hasPrefix(a.id + "|") }
        AlbumModel.memory = AlbumModel.memory.filter { !$0.key.hasPrefix(a.id + "|") }
        Thumbs.shared.purgeMemory()
        state.show("Signed out of \(a.displayTitle)")
    }
}

private struct AccountRow: View {
    let account: Account
    let onSignOut: (Account) -> Void
    @Environment(AppState.self) private var state
    @State private var usage: StorageUsage?
    @State private var saved = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: account.kind == .demo ? "sparkles" : "person.crop.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(account.displayTitle).font(.headline)
                    if let s = account.subtitle { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                    statusText
                }
            }
            if let u = usage, u.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(u.used), total: Double(u.total))
                    Text("\(u.used.byteString) of \(u.total.byteString) used · \(u.available.byteString) free").font(.caption).foregroundStyle(.secondary)
                }
            }
            if account.needsSignIn {
                Button { state.signIn = .init(appleID: account.appleID) } label: { Label("Sign In Again", systemImage: "arrow.clockwise") }
            }
            if account.kind == .web {
                if saved {
                    Button {
                        if let id = account.appleID {
                            Keychain.delete(service: Keychain.passwordService, account: id)
                            Task { await CredentialGate.shared.forget(id) }
                        }
                        saved = false
                    } label: { Label("Forget Saved Password", systemImage: "key.slash") }
                }
                Button(role: .destructive) { onSignOut(account) } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
            } else if account.kind == .demo {
                Button { state.setDemo(false) } label: { Label("Hide Demo Account", systemImage: "eye.slash") }
            }
        }
        .task {
            saved = account.appleID.map { account.kind == .web && CredentialGate.hasSavedPassword($0) } ?? false
            usage = await account.storageUsage()
        }
    }

    @ViewBuilder var statusText: some View {
        switch account.status {
        case .ready: Text("Signed in").font(.caption).foregroundStyle(.green)
        case .needsSignIn: Text("Session expired").font(.caption).foregroundStyle(.orange)
        case .waitingForApproval: Text("Waiting for approval on your Apple device").font(.caption).foregroundStyle(.orange)
        case .error(let m): Text(m).font(.caption).foregroundStyle(.red)
        }
    }
}
