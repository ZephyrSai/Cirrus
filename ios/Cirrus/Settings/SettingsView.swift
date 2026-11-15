import CirrusCore
import LocalAuthentication
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var faceID = Prefs.requireFaceID
    @State private var previews = Prefs.drivePreviews
    @State private var demo = Prefs.showDemoAccount
    @State private var cacheSize: Int64?
    @State private var confirmWrite = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { state.readOnly }, set: { on in if on { state.setReadOnly(true) } else { confirmWrite = true } })) {
                    Label("Read-only iCloud", systemImage: "lock")
                }
            } header: { Text("Safety") } footer: {
                Text("When on, Cirrus never changes anything in iCloud: browsing, downloading, exporting and backing up still work. "
                     + (Prefs.isTesterBuild ? "This tester build starts with it on. " : "")
                     + "Even with it off, removals only go to Recently Deleted, and replacing a file uploads the new copy before the old one is moved there.")
            }
            Section {
                Toggle(isOn: Binding(get: { faceID }, set: { on in setFaceID(on) })) {
                    Label("Face ID for saved passwords", systemImage: "faceid")
                }
            } footer: {
                Text("Saved Apple ID passwords stay in this device’s keychain (never synced) and need Face ID, Touch ID or your passcode before Cirrus uses them to sign in again.")
            }
            Section {
                Toggle(isOn: Binding(get: { previews }, set: { previews = $0; Prefs.drivePreviews = $0; Thumbs.shared.purgeMemory() })) {
                    Label("iCloud Drive previews", systemImage: "photo.on.rectangle")
                }
                Button {
                    ListingCache.clearAll()
                    cacheSize = nil
                    Task { cacheSize = await Task.detached { ListingCache.size() }.value }
                    state.show("Caches cleared")
                } label: {
                    LabeledContent { Text(cacheSize.map { $0.byteString } ?? "…") } label: { Label("Clear Caches", systemImage: "trash.circle") }
                }
            } header: { Text("Storage") } footer: {
                Text("Previews download images, PDFs and documents up to 25 MB to show thumbnails. Caches (thumbnails, folder listings, previews) stay on this device, are readable only by Cirrus, and are removed when you sign out.")
            }
            Section {
                ForEach(state.webAccounts.filter { $0.kind == .web }, id: \.id) { a in
                    NavigationLink { AccountsView() } label: { LabeledContent(a.displayTitle, value: a.needsSignIn ? "Signed out" : "Signed in") }
                }
                Button { state.signIn = .init() } label: { Label("Add Apple ID", systemImage: "person.crop.circle.badge.plus") }
            } header: { Text("Accounts") } footer: { Text("Signing out wipes that account’s caches from this device.") }
            Section {
                Toggle(isOn: Binding(get: { demo }, set: { demo = $0; state.setDemo($0) })) {
                    Label("Demo account", systemImage: "sparkles")
                }
            } footer: { Text("A pretend iCloud with sample files and photos, stored only on this device. Try Cirrus without an Apple ID.") }
            Section("About") {
                LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")" + (Prefs.isTesterBuild ? " · tester" : ""))
                LabeledContent("License", value: "GPL-3.0-or-later")
                Text("Cirrus signs in the way iCloud.com does and talks only to Apple. It has no analytics, ads or servers of its own. Inspired by rclone and icloudpd.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear { faceID = Prefs.requireFaceID }
        .task { cacheSize = await Task.detached { ListingCache.size() }.value }
        .alert("Allow changes to iCloud?", isPresented: $confirmWrite) {
            Button("Allow Changes", role: .destructive) { state.setReadOnly(false) }
            Button("Stay Read-only", role: .cancel) {}
        } message: {
            Text("Cirrus will be able to upload, rename, create folders and move items to Recently Deleted in iCloud.")
        }
    }

    /// Turning protection off needs the device owner (Face ID, Touch ID or passcode); either change drops
    /// passwords already unlocked in memory, so the new setting applies at once.
    func setFaceID(_ on: Bool) {
        if on {
            faceID = true; Prefs.requireFaceID = true
            state.forgetUnlockedPasswords()
            return
        }
        Task {
            let ctx = LAContext()
            var err: NSError?
            let ok: Bool
            if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
                ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "turn off Face ID for saved Apple ID passwords")) ?? false
            } else {
                ok = false   // no passcode on this device: nothing to protect them with, so keep the setting on
            }
            if ok { faceID = false; Prefs.requireFaceID = false; state.forgetUnlockedPasswords() } else { faceID = true }
        }
    }
}
