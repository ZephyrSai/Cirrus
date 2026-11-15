import CirrusCore
import Photos
import SwiftUI

/// A photo grid grouped by month: All Photos of an account, or one album.
struct PhotoGridView: View {
    let account: Account
    let target: PhotoTarget
    @Environment(AppState.self) private var state
    @State private var model: AlbumModel
    @State private var libraries: [PhotoLibraryRef] = []
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var detail: PhotoDetailRef?
    @State private var export: ExportRequest?
    @State private var share: IdentifiedURLs?
    @State private var busy: String?
    @State private var alert: AlertInfo?
    @State private var confirmDelete: [PhotoAsset]?
    @AppStorage("photoLibrary") private var preferredLibrary = ""

    init(account: Account, target: PhotoTarget) {
        self.account = account
        self.target = target
        _model = State(initialValue: AlbumModel(account: account))
    }

    var title: String {
        if case .album(let a, _) = target { return a.name }
        return account.isDevice ? "Photos" : (libraries.count > 1 ? (model.library?.name ?? "Photos") : "Photos")
    }

    var selectedAssets: [PhotoAsset] { model.assets.filter { selected.contains($0.id) } }
    var canEdit: Bool { !state.readOnly }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await start() }
            .refreshable { await model.load(force: true) }
            .onReceive(NotificationCenter.default.publisher(for: NativePhotos.changedNotification)) { _ in
                if account.isDevice { Task { await model.load(force: true) } }
            }
            .overlay { if let busy { BusyBadge(text: busy) } }
            .fullScreenCover(item: $detail) { ref in
                PhotoDetailView(account: account, assets: model.months.flatMap(\.assets), startID: ref.id, library: model.library,
                                inRecentlyDeleted: model.isRecentlyDeleted) { updated, removed in apply(updated, removed: removed) }
            }
            .sheet(item: $export) { ExportView(request: $0) }
            .sheet(item: $share) { ShareSheet(items: $0.urls).presentationDetents([.medium, .large]) }
            .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) { if let a = confirmDelete { Task { await delete(a) } } }
            } message: {
                Text(account.isDevice ? "They stay in Recently Deleted in the Photos app for 30 days." : "They stay in Recently Deleted for 30 days, on every device that uses this iCloud Photos library.")
            }
    }

    @ViewBuilder var content: some View {
        if model.assets.isEmpty, let e = model.error {
            ContentUnavailableView {
                Label("Couldn’t Load Photos", systemImage: "photo.badge.exclamationmark")
            } description: { Text(e) } actions: {
                if account.isDevice, PhotoCatalog.deviceAccessProblem != nil {
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                } else {
                    Button("Try Again") { Task { await start(force: true) } }
                }
            }
        } else if model.assets.isEmpty && model.loaded && !model.loading {
            ContentUnavailableView(model.isRecentlyDeleted ? "No Recently Deleted Photos" : "No Photos", systemImage: "photo.on.rectangle")
        } else if model.assets.isEmpty {
            ProgressView(model.expected.map { "Loading \($0) photos…" } ?? "Loading…")
        } else {
            grid
        }
    }

    var grid: some View {
        ScrollView {
            if account.isDevice, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                Label("Cirrus can see only the photos you allowed. Change it in Settings › Privacy & Security › Photos.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 180), spacing: 2)], spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(model.months) { month in
                    Section {
                        ForEach(month.assets, id: \.id) { a in cell(a) }
                    } header: {
                        HStack {
                            Text(month.title).font(.headline)
                            Spacer()
                            Text("\(month.assets.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                    }
                }
            }
            Text(summary).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 20)
        }
    }

    var summary: String {
        let photos = model.assets.filter { !$0.isVideo }.count, videos = model.assets.count - photos
        var s = [photos == 1 ? "1 photo" : "\(photos) photos"]
        if videos > 0 { s.append(videos == 1 ? "1 video" : "\(videos) videos") }
        return s.joined(separator: ", ") + (model.loading ? " — loading…" : "")
    }

    func cell(_ a: PhotoAsset) -> some View {
        PhotoThumb(account: account, asset: a)
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected.contains(a.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected.contains(a.id) ? Color.accentColor : .black.opacity(0.25))
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting { if selected.contains(a.id) { selected.remove(a.id) } else { selected.insert(a.id) } }
                else { detail = PhotoDetailRef(id: a.id) }
            }
            .contextMenu { menu([a]) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a.filename + (a.isLive ? ", Live Photo" : "") + (a.isFavorite ? ", favorite" : ""))
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder func menu(_ assets: [PhotoAsset]) -> some View {
        Button { Task { await shareOriginals(assets) } } label: { Label("Share Originals…", systemImage: "square.and.arrow.up") }
        Button { exportSelection(assets) } label: { Label("Export Originals…", systemImage: "square.and.arrow.down.on.square") }
        if account.photos?.capabilities.contains(.favorite) == true, !model.isRecentlyDeleted {
            let fav = !assets.allSatisfy(\.isFavorite)
            Button { Task { await favorite(assets, fav) } } label: { Label(fav ? "Favorite" : "Unfavorite", systemImage: fav ? "heart" : "heart.slash") }
                .disabled(!canEdit)
        }
        Divider()
        if model.isRecentlyDeleted {
            Button { Task { await restore(assets) } } label: { Label("Recover", systemImage: "arrow.uturn.backward") }.disabled(!canEdit)
        } else if account.photos?.capabilities.contains(.delete) == true {
            Button(role: .destructive) { confirmDelete = assets } label: { Label("Delete", systemImage: "trash") }.disabled(!canEdit)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selecting {
                Button(selected.count == model.assets.count ? "Deselect All" : "Select All") {
                    selected = selected.count == model.assets.count ? [] : Set(model.assets.map(\.id))
                }
                Button("Done") { selecting = false; selected.removeAll() }.bold()
            } else {
                Button("Select") { selecting = true }.disabled(model.assets.isEmpty)
                Menu {
                    if case .allPhotos = target, libraries.count > 1 {
                        Picker("Library", selection: Binding(get: { model.library?.id ?? "" }, set: { id in
                            preferredLibrary = id
                            Task { await start(force: false, library: id) }
                        })) {
                            ForEach(libraries, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                    if let album = model.album, let lib = model.library {
                        Button { export = ExportRequest(account: account, library: lib, source: .album(album)) } label: {
                            Label(album.isAllPhotos || album.id == "smart:all" ? "Export All Originals…" : "Export Album…", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                    Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let list = selectedAssets
                Button { Task { await shareOriginals(list) } } label: { Image(systemName: "square.and.arrow.up") }.disabled(list.isEmpty)
                Spacer()
                Text(list.isEmpty ? "Select Items" : "\(list.count) Selected").font(.subheadline)
                Spacer()
                Button { exportSelection(list) } label: { Image(systemName: "square.and.arrow.down.on.square") }.disabled(list.isEmpty)
                if model.isRecentlyDeleted {
                    Button("Recover") { Task { await restore(list) } }.disabled(list.isEmpty || !canEdit)
                } else {
                    Button { Task { await favorite(list, !list.allSatisfy(\.isFavorite)) } } label: {
                        Image(systemName: !list.isEmpty && list.allSatisfy(\.isFavorite) ? "heart.slash" : "heart")
                    }.disabled(list.isEmpty || !canEdit || account.photos?.capabilities.contains(.favorite) != true)
                    Button(role: .destructive) { confirmDelete = list } label: { Image(systemName: "trash") }
                        .disabled(list.isEmpty || !canEdit || account.photos?.capabilities.contains(.delete) != true)
                }
            }
        }
    }

    var deleteTitle: String {
        let n = confirmDelete?.count ?? 0
        return n == 1 ? "Delete this item?" : "Delete \(n) items?"
    }

    // MARK: Actions

    func start(force: Bool = false, library: String? = nil) async {
        do {
            libraries = (try? await PhotoCatalog.libraries(account)) ?? []
            try await model.resolve(target, preferredLibrary: library ?? (preferredLibrary.isEmpty ? nil : preferredLibrary))
            await model.load(force: force)
            #if DEBUG
            if DebugScreens.openFirstPhoto, let a = model.months.flatMap(\.assets).first(where: \.isLive) ?? model.months.first?.assets.first {
                DebugScreens.openFirstPhoto = false; detail = PhotoDetailRef(id: a.id)
            }
            if DebugScreens.openExport, let al = model.album, let lib = model.library {
                DebugScreens.openExport = false; export = ExportRequest(account: account, library: lib, source: .album(al))
            }
            #endif
        } catch {
            model.error = (account.isDevice ? PhotoCatalog.deviceAccessProblem : nil) ?? error.localizedDescription
            model.loaded = true
        }
    }

    func apply(_ updated: [PhotoAsset], removed: Set<String>) {
        guard let lib = model.library else { return }
        PhotoCatalog.patch(account, library: lib.id, updated: updated, removed: removed)
        model.patch(updated, removed: removed)
    }

    func favorite(_ list: [PhotoAsset], _ value: Bool) async {
        guard let photos = account.photos, !list.isEmpty else { return }
        do {
            let updated = try await photos.setFavorite(list, value)
            apply(updated, removed: [])
            if case .album(let a, _) = target, a.id == "smart:Favorites", !value { apply([], removed: Set(list.map(\.id))) }
        } catch { alert = AlertInfo(title: "Couldn’t Change Favorites", message: error.localizedDescription) }
    }

    func delete(_ list: [PhotoAsset]) async {
        confirmDelete = nil
        guard let photos = account.photos, !list.isEmpty else { return }
        busy = "Deleting…"
        defer { busy = nil }
        do {
            try await photos.delete(list)
            apply([], removed: Set(list.map(\.id)))
            selecting = false; selected.removeAll()
            state.show(list.count == 1 ? "Moved 1 item to Recently Deleted" : "Moved \(list.count) items to Recently Deleted")
        } catch { alert = AlertInfo(title: "Couldn’t Delete", message: error.localizedDescription) }
    }

    func restore(_ list: [PhotoAsset]) async {
        guard let photos = account.photos, !list.isEmpty else { return }
        busy = "Recovering…"
        defer { busy = nil }
        do {
            try await photos.restore(list)
            apply([], removed: Set(list.map(\.id)))
            selected.removeAll()
            state.show(list.count == 1 ? "Recovered 1 item" : "Recovered \(list.count) items")
        } catch { alert = AlertInfo(title: "Couldn’t Recover", message: error.localizedDescription) }
    }

    func shareOriginals(_ list: [PhotoAsset]) async {
        guard !list.isEmpty else { return }
        if list.count > 50 { alert = AlertInfo(title: "Too Many to Share", message: "Share up to 50 at a time, or use Export Originals to save them to a folder."); return }
        busy = list.count == 1 ? "Downloading original…" : "Downloading \(list.count) originals…"
        defer { busy = nil }
        do {
            var urls = [URL]()
            for a in list { urls.append(try await Ops.photoCopy(account, a)) }
            share = IdentifiedURLs(urls: urls)
        } catch { alert = AlertInfo(title: "Couldn’t Share", message: error.localizedDescription) }
    }

    func exportSelection(_ list: [PhotoAsset]) {
        guard let lib = model.library, !list.isEmpty else { return }
        export = ExportRequest(account: account, library: lib, source: .assets(list))
    }
}

struct PhotoDetailRef: Identifiable { let id: String }

struct BusyBadge: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) { ProgressView(); Text(text).font(.callout) }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
