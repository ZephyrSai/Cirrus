import CirrusCore
import SwiftUI

/// Albums of one account (or this device): smart albums, your albums and folders, shared albums.
struct AlbumsView: View {
    let account: Account
    var folder: PhotoAlbum? = nil
    var fixedLibrary: PhotoLibraryRef? = nil
    @AppStorage("photoLibrary") private var preferredLibrary = ""
    @State private var libraries: [PhotoLibraryRef] = []
    @State private var library: PhotoLibraryRef?
    @State private var albums: [PhotoAlbum] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if folder == nil, libraries.count > 1 {
                Picker("Library", selection: Binding(get: { library?.id ?? "" }, set: { id in
                    preferredLibrary = id
                    library = libraries.first { $0.id == id }
                    Task { await loadAlbums() }
                })) {
                    ForEach(libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
            }
            let here = albums.filter { $0.parentID == folder?.id }
            let smart = here.filter { $0.kind == .smart && (($0.count ?? 1) > 0 || $0.isDeletedBin || $0.id == "smart:Favorites") }
            let mine = here.filter { $0.kind == .album || $0.kind == .folder }
            let shared = here.filter { $0.kind == .shared }
            if !smart.isEmpty { Section(folder == nil ? "Library" : "") { ForEach(smart, id: \.id) { row($0) } } }
            if !mine.isEmpty { Section(folder == nil ? "My Albums" : "") { ForEach(mine, id: \.id) { row($0) } } }
            if !shared.isEmpty { Section("Shared Albums") { ForEach(shared, id: \.id) { row($0) } } }
            if loaded && here.isEmpty && error == nil {
                Text("No albums").foregroundStyle(.secondary)
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(folder?.name ?? "Albums")
        .task { await start() }
        .refreshable { await loadAlbums(refresh: true) }
        .navigationDestination(for: AlbumFolderRef.self) { ref in
            AlbumsView(account: account, folder: ref.folder, fixedLibrary: ref.library)
        }
    }

    @ViewBuilder func row(_ a: PhotoAlbum) -> some View {
        if let lib = library {
            if a.kind == .folder {
                NavigationLink(value: AlbumFolderRef(library: lib, folder: a)) { label(a) }
            } else {
                NavigationLink(value: AlbumRef(accountID: account.id, library: lib, album: a)) { label(a) }
            }
        }
    }

    func label(_ a: PhotoAlbum) -> some View {
        HStack {
            Label(a.name, systemImage: a.kind == .folder ? "folder" : a.symbol)
            Spacer()
            if let c = a.count { Text("\(c)").foregroundStyle(.secondary).monospacedDigit() }
        }
    }

    func start() async {
        if let fixedLibrary { library = fixedLibrary; libraries = [fixedLibrary]; await loadAlbums(); return }
        do {
            libraries = try await PhotoCatalog.libraries(account)
            library = libraries.first { $0.id == preferredLibrary } ?? libraries.first { !$0.isShared } ?? libraries.first
            await loadAlbums()
        } catch {
            self.error = (account.isDevice ? PhotoCatalog.deviceAccessProblem : nil) ?? error.localizedDescription
            loaded = true
        }
    }

    func loadAlbums(refresh: Bool = false) async {
        guard let library else { loaded = true; return }
        do {
            albums = try await PhotoCatalog.albums(account, library, refresh: refresh)
            error = nil
        } catch {
            self.error = (account.isDevice ? PhotoCatalog.deviceAccessProblem : nil) ?? error.localizedDescription
        }
        loaded = true
    }
}

struct AlbumFolderRef: Hashable {
    var library: PhotoLibraryRef
    var folder: PhotoAlbum
}
