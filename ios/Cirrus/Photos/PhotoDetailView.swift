import CirrusCore
import SwiftUI

/// One photo or video, full screen. Swipe for the next one; originals open in Quick Look.
struct PhotoDetailView: View {
    let account: Account
    let assets: [PhotoAsset]
    let library: PhotoLibraryRef?
    let inRecentlyDeleted: Bool
    let onChange: ([PhotoAsset], Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var index: Int
    @State private var overrides = [String: PhotoAsset]()
    @State private var removed = Set<String>()
    @State private var image: UIImage?
    @State private var showInfo = false
    @State private var preview: IdentifiedURL?
    @State private var share: IdentifiedURLs?
    @State private var export: ExportRequest?
    @State private var busy: String?
    @State private var alert: AlertInfo?
    @State private var confirmDelete = false
    @State private var drag: CGFloat = 0

    init(account: Account, assets: [PhotoAsset], startID: String, library: PhotoLibraryRef?, inRecentlyDeleted: Bool,
         onChange: @escaping ([PhotoAsset], Set<String>) -> Void) {
        self.account = account
        self.assets = assets
        self.library = library
        self.inRecentlyDeleted = inRecentlyDeleted
        self.onChange = onChange
        _index = State(initialValue: assets.firstIndex { $0.id == startID } ?? 0)
    }

    var visible: [PhotoAsset] { assets.filter { !removed.contains($0.id) }.map { overrides[$0.id] ?? $0 } }
    var asset: PhotoAsset? { let v = visible; return v.isEmpty ? nil : v[min(index, v.count - 1)] }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let asset {
                    photo(asset)
                        .offset(x: drag)
                        .gesture(DragGesture(minimumDistance: 20)
                            .onChanged { drag = $0.translation.width }
                            .onEnded { v in
                                let n = visible.count
                                if v.translation.width < -80, index < n - 1 { index += 1 }
                                else if v.translation.width > 80, index > 0 { index -= 1 }
                                withAnimation(.spring(duration: 0.25)) { drag = 0 }
                            })
                } else {
                    Text("No more items").foregroundStyle(.secondary)
                }
                if let busy { BusyBadge(text: busy) }
            }
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: asset?.id) { await loadImage() }
            .sheet(isPresented: $showInfo) { if let asset { InfoSheet(asset: asset).presentationDetents([.medium]) } }
            .sheet(item: $preview) { QuickLookView(url: $0.url).ignoresSafeArea() }
            .sheet(item: $share) { ShareSheet(items: $0.urls).presentationDetents([.medium, .large]) }
            .sheet(item: $export) { ExportView(request: $0) }
            .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Move to Recently Deleted", role: .destructive) { Task { await delete() } }
            } message: { Text("It stays in Recently Deleted for 30 days.") }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder func photo(_ a: PhotoAsset) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                PhotoThumb(account: account, asset: a, px: 256).frame(maxWidth: 320).opacity(0.6)
                ProgressView().tint(.white)
            }
            if a.isVideo {
                Button { Task { await openOriginal(a) } } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 8)
                }
                .accessibilityLabel("Play video")
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                if a.isLive { Label("LIVE", systemImage: "livephoto").font(.caption2.bold()) }
                if a.isEdited { Label("Edited", systemImage: "slider.horizontal.3").font(.caption2.bold()) }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, a.isLive || a.isEdited ? 8 : 0).padding(.vertical, a.isLive || a.isEdited ? 4 : 0)
            .background { if a.isLive || a.isEdited { Capsule().fill(.ultraThinMaterial) } }
            .padding(10)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .principal) {
            if let a = asset {
                VStack(spacing: 0) {
                    Text(a.created?.formatted(date: .abbreviated, time: .omitted) ?? a.filename).font(.subheadline.bold())
                    Text(a.created?.formatted(date: .omitted, time: .shortened) ?? "").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if let a = asset {
                Button { Task { await shareOriginal(a) } } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share original")
                Spacer()
                if !inRecentlyDeleted, account.photos?.capabilities.contains(.favorite) == true {
                    Button { Task { await toggleFavorite(a) } } label: { Image(systemName: a.isFavorite ? "heart.fill" : "heart") }
                        .disabled(state.readOnly).accessibilityLabel(a.isFavorite ? "Unfavorite" : "Favorite")
                    Spacer()
                }
                Button { showInfo = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Info")
                Spacer()
                Button { if let lib = library { export = ExportRequest(account: account, library: lib, source: .assets([a])) } } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }.accessibilityLabel("Export original")
                Spacer()
                if inRecentlyDeleted {
                    Button("Recover") { Task { await recover(a) } }.disabled(state.readOnly)
                } else {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .disabled(state.readOnly || account.photos?.capabilities.contains(.delete) != true).accessibilityLabel("Delete")
                }
            }
        }
    }

    func loadImage() async {
        image = nil
        guard let a = asset else { return }
        let px = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale)
        image = await Thumbs.shared.photo(account, a, px: min(2048, px))
    }

    func openOriginal(_ a: PhotoAsset) async {
        busy = "Downloading original…"
        defer { busy = nil }
        do { preview = IdentifiedURL(url: try await Ops.photoCopy(account, a)) }
        catch { alert = AlertInfo(title: "Couldn’t Open", message: error.localizedDescription) }
    }

    func shareOriginal(_ a: PhotoAsset) async {
        busy = "Downloading original…"
        defer { busy = nil }
        do {
            var urls = [try await Ops.photoCopy(account, a)]
            if a.isLive, a.resource(.liveVideo) != nil, let mov = try? await Ops.photoCopy(account, a, kind: .liveVideo) { urls.append(mov) }
            share = IdentifiedURLs(urls: urls)
        } catch { alert = AlertInfo(title: "Couldn’t Share", message: error.localizedDescription) }
    }

    func toggleFavorite(_ a: PhotoAsset) async {
        guard let photos = account.photos else { return }
        do {
            let updated = try await photos.setFavorite([a], !a.isFavorite)
            for u in updated { overrides[u.id] = u }
            onChange(updated, [])
        } catch { alert = AlertInfo(title: "Couldn’t Change Favorite", message: error.localizedDescription) }
    }

    func delete() async {
        guard let photos = account.photos, let a = asset else { return }
        do {
            try await photos.delete([a])
            removed.insert(a.id)
            onChange([], [a.id])
            if visible.isEmpty { dismiss() } else { index = min(index, visible.count - 1) }
        } catch { alert = AlertInfo(title: "Couldn’t Delete", message: error.localizedDescription) }
    }

    func recover(_ a: PhotoAsset) async {
        guard let photos = account.photos else { return }
        do {
            try await photos.restore([a])
            removed.insert(a.id)
            onChange([], [a.id])
            if visible.isEmpty { dismiss() } else { index = min(index, visible.count - 1) }
        } catch { alert = AlertInfo(title: "Couldn’t Recover", message: error.localizedDescription) }
    }
}

private struct InfoSheet: View {
    let asset: PhotoAsset
    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Name", value: asset.filename)
                if let d = asset.created { LabeledContent("Taken", value: d.formatted(date: .long, time: .shortened)) }
                if asset.width > 0 { LabeledContent("Size", value: "\(asset.width) × \(asset.height)") }
                LabeledContent("Original", value: (asset.resource(.original)?.size ?? asset.size).byteString)
                if let v = asset.resource(.liveVideo) { LabeledContent("Live Photo video", value: v.size.byteString) }
                if let e = asset.resource(.edited) { LabeledContent("Edited version", value: e.size.byteString) }
                if let r = asset.resource(.alternate) { LabeledContent("RAW / alternate", value: r.size.byteString) }
                if let d = asset.duration { LabeledContent("Duration", value: Duration.seconds(d).formatted(.time(pattern: .minuteSecond))) }
                if asset.isFavorite { Label("Favorite", systemImage: "heart.fill") }
                if asset.isHidden { Label("Hidden", systemImage: "eye.slash") }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
