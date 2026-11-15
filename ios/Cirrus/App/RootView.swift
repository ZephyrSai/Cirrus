import CirrusCore
import SwiftUI

struct RootView: View {
    @Bindable var state = AppState.shared
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
        } detail: {
            DetailView(selection: state.selection)
                .id(state.selection)
        }
        .sheet(item: $state.signIn) { req in
            SignInView(prefill: req.appleID)
        }
        .overlay(alignment: .bottom) {
            if let t = state.toast {
                Text(t)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { state.toast = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: state.toast)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, TransferManager.shared.active.isEmpty { state.forgetUnlockedPasswords() }
        }
    }
}

struct SidebarView: View {
    @Bindable var state = AppState.shared

    var body: some View {
        let _ = state.accountsVersion
        List(selection: $state.selection) {
            if state.readOnly {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read-only mode")
                        Text("Nothing in iCloud will be changed.").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                .tag(Destination.settings)
            }
            if state.webAccounts.isEmpty {
                Section("iCloud") {
                    Button { state.signIn = .init() } label: {
                        Label("Sign In with Apple ID", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            ForEach(state.webAccounts, id: \.id) { acct in
                Section {
                    if acct.needsSignIn {
                        Button { state.signIn = .init(appleID: acct.appleID) } label: {
                            Label("Sign In Again", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if case .waitingForApproval = acct.status {
                        Label("Approve on your Apple device", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    Label("iCloud Drive", systemImage: "icloud").tag(Destination.drive(acct.id))
                    Label("Photos", systemImage: "photo.on.rectangle").tag(Destination.photos(acct.id))
                    Label("Albums", systemImage: "rectangle.stack").tag(Destination.albums(acct.id))
                    Label("Recently Deleted", systemImage: "trash").tag(Destination.driveTrash(acct.id))
                } header: {
                    Text(acct.displayTitle)
                }
            }
            if let device = state.deviceAccount, device.photos != nil {
                Section("On \(device.title)") {
                    Label("Photos", systemImage: "photo.on.rectangle.angled").tag(Destination.photos(device.id))
                    Label("Albums", systemImage: "rectangle.stack.badge.person.crop").tag(Destination.albums(device.id))
                }
            }
            Section("Cirrus") {
                Label("Back Up iCloud", systemImage: "externaldrive.badge.icloud").tag(Destination.backup)
                Label {
                    HStack {
                        Text("Transfers")
                        Spacer()
                        if state.activeTransfers > 0 {
                            Text("\(state.activeTransfers)").font(.caption.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                } icon: { Image(systemName: "arrow.up.arrow.down.circle") }
                .tag(Destination.transfers)
                Label("Accounts", systemImage: "person.2.crop.square.stack").tag(Destination.accounts)
                Label("Settings", systemImage: "gearshape").tag(Destination.settings)
            }
        }
        .navigationTitle("Cirrus")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.signIn = .init() } label: { Image(systemName: "person.crop.circle.badge.plus") }
                    .accessibilityLabel("Add Apple ID")
            }
        }
    }
}

struct DetailView: View {
    let selection: Destination?
    @Environment(AppState.self) private var state
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .onAppear {
                    #if DEBUG
                    if !DebugScreens.initialPath.isEmpty { path = DebugScreens.initialPath; DebugScreens.initialPath = NavigationPath() }
                    #endif
                }
                .navigationDestination(for: DriveFolderRef.self) { ref in
                    if let acct = state.account(ref.accountID) { DriveFolderView(account: acct, folderID: ref.folderID, title: ref.title) }
                }
                .navigationDestination(for: AlbumRef.self) { ref in
                    if let acct = state.account(ref.accountID) { PhotoGridView(account: acct, target: .album(ref.album, ref.library)) }
                }
        }
    }

    @ViewBuilder var content: some View {
        switch selection {
        case .drive(let id):
            if let a = state.account(id), let drive = a.drive { DriveFolderView(account: a, folderID: drive.rootID, title: "iCloud Drive") } else { missing }
        case .driveTrash(let id):
            if let a = state.account(id) { DriveTrashView(account: a) } else { missing }
        case .photos(let id):
            if let a = state.account(id) { PhotoGridView(account: a, target: .allPhotos) } else { missing }
        case .albums(let id):
            if let a = state.account(id) { AlbumsView(account: a) } else { missing }
        case .backup: BackupView()
        case .transfers: TransfersView()
        case .accounts: AccountsView()
        case .settings: SettingsView()
        case nil:
            ContentUnavailableView("Cirrus", systemImage: "icloud", description: Text("Choose iCloud Drive, Photos or a tool in the sidebar."))
        }
    }

    var missing: some View {
        ContentUnavailableView("Not available", systemImage: "icloud.slash", description: Text("This account was signed out."))
    }
}
