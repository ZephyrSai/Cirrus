import CirrusCore
import SwiftUI

struct DriveFolderView: View {
    let account: Account
    let folderID: String
    let title: String
    @State private var model: DriveFolderModel
    @Environment(AppState.self) private var state

    @State private var grid = Prefs.driveGrid
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var preview: IdentifiedURL?
    @State private var share: IdentifiedURLs?
    @State private var busy: String?
    @State private var busyProgress: Double?
    @State private var alert: AlertInfo?
    @State private var renaming: DriveNode?
    @State private var renameText = ""
    @State private var newFolder = false
    @State private var newFolderName = ""
    @State private var confirmTrash: [DriveNode]?
    @State private var pickFolderFor: [DriveNode]?
    @State private var pickFiles = false
    @State private var pickPhotos = false
    @State private var uploadCheck: Ops.UploadCheck?

    init(account: Account, folderID: String, title: String) {
        self.account = account
        self.folderID = folderID
        self.title = title
        _model = State(initialValue: DriveFolderModel(account: account, folderID: folderID))
    }

    var selectedNodes: [DriveNode] { model.nodes.filter { selected.contains($0.id) } }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(folderID == account.drive?.rootID ? .large : .inline)
            .toolbar { toolbar }
            .refreshable { await model.load(force: true) }
            .task {
                await model.load()
                #if DEBUG
                if let n = DebugScreens.quickLookName, let node = model.nodes.first(where: { $0.name == n }) { DebugScreens.quickLookName = nil; open(node) }
                if DebugScreens.stageUpload { DebugScreens.stageUpload = false; startUpload(DebugScreens.sampleUploads()) }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .cirrusDriveChanged)) { n in
                if (n.object as? String) == model.key { Task { await model.load(force: true) } }
            }
            .overlay { busyOverlay }
            .sheet(item: $preview) { QuickLookView(url: $0.url).ignoresSafeArea() }
            .sheet(item: $share) { ShareSheet(items: $0.urls).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $pickFiles) { FilesPicker { urls in startUpload(Ops.inspect(urls, scoped: true, temporary: false)) }.ignoresSafeArea() }
            .sheet(isPresented: $pickPhotos) { PhotoPicker { urls in startUpload(Ops.inspect(urls, scoped: false, temporary: true)) }.ignoresSafeArea() }
            .sheet(item: Binding(get: { pickFolderFor.map { NodeList(nodes: $0) } }, set: { pickFolderFor = $0?.nodes })) { list in
                FolderPicker(startIn: FolderBookmarks.load("downloads") ?? FolderBookmarks.appDownloads) { url in
                    FolderBookmarks.save(url, key: "downloads")
                    Task { await download(list.nodes, to: url) }
                }.ignoresSafeArea()
            }
            .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") { if let n = renaming { Task { await rename(n, to: renameText) } } }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New Folder", isPresented: $newFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { Task { await createFolder(newFolderName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(trashTitle, isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                                titleVisibility: .visible) {
                Button("Move to \(account.deletedTitle)", role: .destructive) { if let n = confirmTrash { Task { await trash(n) } } }
            } message: {
                Text(account.isICloud ? "You can put items back from Recently Deleted for 30 days." : "You can put items back from \(account.deletedTitle).")
            }
            .confirmationDialog(uploadTitle, isPresented: Binding(get: { uploadCheck != nil }, set: { if !$0 { uploadCheck = nil } }),
                                titleVisibility: .visible) {
                if let c = uploadCheck {
                    if !c.conflicts.isEmpty {
                        Button("Replace") { finishUpload(c, replace: true) }
                        Button("Keep Both") { finishUpload(c, replace: false) }
                    } else {
                        Button("Upload \(c.files.count) Item\(c.files.count == 1 ? "" : "s")") { finishUpload(c, replace: false) }
                    }
                }
                Button("Cancel", role: .cancel) { if let c = uploadCheck { discardStaged(c.files) } }
            } message: { Text(uploadMessage) }
    }

    // MARK: Content

    @ViewBuilder var content: some View {
        if model.nodes.isEmpty && model.loaded && model.error == nil {
            ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text(state.readOnly ? "" : "Tap + to upload files or create a folder."))
        } else if model.nodes.isEmpty, let e = model.error {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.icloud")
            } description: { Text(e) } actions: {
                Button("Try Again") { Task { await model.load(force: true) } }
                if account.needsSignIn { Button("Sign In") { state.signIn = .init(appleID: account.appleID) } }
            }
        } else if !model.loaded {
            ProgressView("Loading…")
        } else if grid {
            gridView
        } else {
            listView
        }
    }

    var listView: some View {
        List(selection: selecting ? $selected : .constant(Set<String>())) {
            if let e = model.error { errorRow(e) }
            ForEach(model.nodes, id: \.id) { node in
                row(node).tag(node.id)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
    }

    var gridView: some View {
        ScrollView {
            if let e = model.error { errorRow(e).padding(.horizontal) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                ForEach(model.nodes, id: \.id) { node in
                    gridCell(node)
                }
            }
            .padding()
        }
    }

    func errorRow(_ e: String) -> some View {
        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
    }

    @ViewBuilder func row(_ node: DriveNode) -> some View {
        let label = HStack(spacing: 12) {
            DriveThumb(account: account, node: node, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).lineLimit(2)
                Text(detail(node)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if node.isShared { Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary) }
        }
        if selecting {
            label
        } else if node.isFolder {
            NavigationLink(value: DriveFolderRef(accountID: account.id, folderID: node.id, title: node.name)) { label }
                .contextMenu { menu([node]) }
        } else {
            Button { open(node) } label: { label }.tint(.primary)
                .contextMenu { menu([node]) }
        }
    }

    @ViewBuilder func gridCell(_ node: DriveNode) -> some View {
        let cell = VStack(spacing: 6) {
            DriveThumb(account: account, node: node, size: 76)
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: selected.contains(node.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected.contains(node.id) ? Color.accentColor : .secondary)
                            .background(Circle().fill(.background)).offset(x: 6, y: 6)
                    }
                }
            Text(node.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            Text(node.isFolder ? itemCount(node) : (node.zone.hasPrefix("application/vnd.google-apps.") ? "" : node.size.byteString)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        if selecting {
            cell.onTapGesture { toggle(node) }
        } else if node.isFolder {
            NavigationLink(value: DriveFolderRef(accountID: account.id, folderID: node.id, title: node.name)) { cell }
                .buttonStyle(.plain).contextMenu { menu([node]) }
        } else {
            cell.onTapGesture { open(node) }.contextMenu { menu([node]) }
        }
    }

    func toggle(_ n: DriveNode) { if selected.contains(n.id) { selected.remove(n.id) } else { selected.insert(n.id) } }

    func detail(_ n: DriveNode) -> String {
        let date = n.modified.map { $0.formatted(date: .abbreviated, time: .shortened) }
        if n.isFolder { return [date, itemCount(n)].compactMap { $0 }.joined(separator: " · ") }
        // Google Docs, Sheets and Slides have no size until they're exported.
        if n.zone.hasPrefix("application/vnd.google-apps.") { return date ?? "" }
        return [date, n.size.byteString].compactMap { $0 }.joined(separator: " · ")
    }

    func itemCount(_ n: DriveNode) -> String {
        guard let c = n.childCount else { return "Folder" }
        return c == 1 ? "1 item" : "\(c) items"
    }

    // MARK: Menus and toolbar

    @ViewBuilder func menu(_ nodes: [DriveNode]) -> some View {
        let files = nodes.filter { !$0.isFolder }
        if nodes.count == 1, let n = nodes.first, !n.isFolder {
            Button { open(n) } label: { Label("Quick Look", systemImage: "eye") }
        }
        if !files.isEmpty {
            Button { Task { await shareFiles(files) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Button { pickFolderFor = nodes } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
        if nodes.count == 1, let n = nodes.first, !n.isAppLibrary {
            Button { renameText = n.name; renaming = n } label: { Label("Rename", systemImage: "pencil") }
                .disabled(state.readOnly)
        }
        Divider()
        Button(role: .destructive) { confirmTrash = nodes } label: { Label("Move to \(account.deletedTitle)", systemImage: "trash") }
            .disabled(state.readOnly || nodes.contains { $0.isAppLibrary })
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selecting {
                Button("Done") { selecting = false; selected.removeAll() }
            } else {
                Menu {
                    Button { newFolderName = "New Folder"; newFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { pickFiles = true } label: { Label("Upload from Files", systemImage: "doc.badge.plus") }
                    Button { pickPhotos = true } label: { Label("Upload from Photos", systemImage: "photo.badge.plus") }
                } label: { Image(systemName: "plus") }
                .disabled(state.readOnly)
                .accessibilityLabel("Add")
                Menu {
                    Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    Picker("View", selection: Binding(get: { grid }, set: { grid = $0; Prefs.driveGrid = $0 })) {
                        Label("List", systemImage: "list.bullet").tag(false)
                        Label("Icons", systemImage: "square.grid.2x2").tag(true)
                    }
                    Button { Task { await model.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let nodes = selectedNodes
                Button { Task { await shareFiles(nodes.filter { !$0.isFolder }) } } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(nodes.filter { !$0.isFolder }.isEmpty)
                Spacer()
                Text(nodes.isEmpty ? "Select Items" : "\(nodes.count) Selected").font(.subheadline)
                Spacer()
                Button { pickFolderFor = nodes } label: { Image(systemName: "square.and.arrow.down") }.disabled(nodes.isEmpty)
                Button(role: .destructive) { confirmTrash = nodes } label: { Image(systemName: "trash") }
                    .disabled(nodes.isEmpty || state.readOnly)
            }
        }
    }

    @ViewBuilder var busyOverlay: some View {
        if let busy {
            VStack(spacing: 10) {
                if let p = busyProgress { ProgressView(value: p).frame(width: 180) } else { ProgressView() }
                Text(busy).font(.callout).multilineTextAlignment(.center)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    var trashTitle: String {
        let n = confirmTrash?.count ?? 0
        if n == 1, let name = confirmTrash?.first?.name { return "Move “\(name)” to \(account.deletedTitle)?" }
        return "Move \(n) items to \(account.deletedTitle)?"
    }

    var uploadTitle: String {
        guard let c = uploadCheck else { return "" }
        if !c.conflicts.isEmpty { return c.conflicts.count == 1 ? "“\(c.conflicts[0])” already exists here" : "\(c.conflicts.count) items already exist here" }
        return "Upload \(c.bytes.byteString) to \(account.driveTitle)?"
    }

    var uploadMessage: String {
        guard let c = uploadCheck else { return "" }
        var lines = [String]()
        if !c.conflicts.isEmpty { lines.append("Replace uploads the new copy first, then moves the old one to \(account.deletedTitle). Keep Both adds a number to the new name.") }
        if let free = c.iCloudFree { lines.append("\(c.bytes.byteString) to upload, \(free.byteString) free in \(account.isICloud ? "iCloud" : account.driveTitle).") }
        lines += c.blocked + c.cautions
        return lines.joined(separator: "\n\n")
    }

    // MARK: Actions

    func open(_ node: DriveNode) {
        Task {
            busy = "Downloading “\(node.name)”…"
            busyProgress = node.size > 2_000_000 ? 0 : nil
            defer { busy = nil; busyProgress = nil }
            do {
                let url = try await Ops.localCopy(account, node) { d, t in
                    Task { @MainActor in if t > 0, busyProgress != nil { busyProgress = Double(d) / Double(t) } }
                }
                preview = IdentifiedURL(url: url)
            } catch {
                alert = AlertInfo(title: "Couldn’t Open “\(node.name)”", message: error.localizedDescription)
            }
        }
    }

    func shareFiles(_ files: [DriveNode]) async {
        guard !files.isEmpty else { return }
        busy = files.count == 1 ? "Preparing “\(files[0].name)”…" : "Preparing \(files.count) files…"
        defer { busy = nil }
        do {
            var urls = [URL]()
            for f in files { urls.append(try await Ops.localCopy(account, f)) }
            share = IdentifiedURLs(urls: urls)
        } catch {
            alert = AlertInfo(title: "Couldn’t Share", message: error.localizedDescription)
        }
    }

    func download(_ nodes: [DriveNode], to folder: URL) async {
        busy = "Checking sizes…"
        defer { busy = nil }
        do {
            try await Ops.download(nodes, account: account, to: folder)
            selecting = false; selected.removeAll()
            state.show(nodes.count == 1 ? "Downloading “\(nodes[0].name)” — see Transfers" : "Downloading \(nodes.count) items — see Transfers")
        } catch {
            alert = AlertInfo(title: "Not Downloaded", message: error.localizedDescription)
        }
    }

    func rename(_ node: DriveNode, to raw: String) async {
        renaming = nil
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != node.name else { return }
        guard !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            alert = AlertInfo(title: "Can’t Use That Name", message: "Names can’t contain “/” or “:”."); return
        }
        if model.nodes.contains(where: { $0.id != node.id && $0.name.lowercased() == name.lowercased() }) {
            alert = AlertInfo(title: "Name Taken", message: "There’s already an item called “\(name)” here."); return
        }
        guard let drive = account.drive else { return }
        do {
            _ = try await drive.rename(node, to: name)
            model.invalidate()
            await model.load(force: true)
        } catch {
            alert = AlertInfo(title: "Couldn’t Rename", message: error.localizedDescription)
        }
    }

    func createFolder(_ raw: String) async {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else { return }
        guard let drive = account.drive else { return }
        let final = Ops.uniqueName(name, taken: Set(model.nodes.map(\.name)))
        do {
            _ = try await drive.createFolder(final, in: folderID)
            model.invalidate()
            await model.load(force: true)
        } catch {
            alert = AlertInfo(title: "Couldn’t Create Folder", message: error.localizedDescription)
        }
    }

    func trash(_ nodes: [DriveNode]) async {
        confirmTrash = nil
        guard let drive = account.drive else { return }
        busy = "Moving to \(account.deletedTitle)…"
        defer { busy = nil }
        do {
            try await drive.trash(nodes)
            selecting = false; selected.removeAll()
            model.invalidate()
            await model.load(force: true)
            state.show(nodes.count == 1 ? "Moved “\(nodes[0].name)” to \(account.deletedTitle)" : "Moved \(nodes.count) items to \(account.deletedTitle)")
        } catch {
            alert = AlertInfo(title: "Couldn’t Move to \(account.deletedTitle)", message: error.localizedDescription)
        }
    }

    func startUpload(_ files: [Ops.UploadFile]) {
        guard !files.isEmpty else { return }
        Task {
            busy = "Checking \(account.isICloud ? "iCloud" : account.driveTitle) storage…"
            let check = await Ops.checkUpload(files, account: account, existing: model.nodes)
            busy = nil
            if check.files.isEmpty {
                alert = AlertInfo(title: "Nothing to Upload", message: check.blocked.joined(separator: "\n"))
                discardStaged(files)
            } else if !check.fits {
                alert = AlertInfo(title: account.isICloud ? "Not Enough iCloud Storage" : "Not Enough Space in \(account.driveTitle)",
                                  message: "These files need \(check.bytes.byteString), and \((check.iCloudFree ?? 0).byteString) is free in \(account.isICloud ? "iCloud" : account.driveTitle). Nothing was uploaded.")
                discardStaged(files)
            } else {
                uploadCheck = check
                #if DEBUG
                if DebugScreens.autoRun { finishUpload(check, replace: false) }
                #endif
            }
        }
    }

    func finishUpload(_ c: Ops.UploadCheck, replace: Bool) {
        uploadCheck = nil
        Ops.upload(c, account: account, folderID: folderID, existing: model.nodes, replace: replace)
        state.show(c.files.count == 1 ? "Uploading “\(c.files[0].name)” — see Transfers" : "Uploading \(c.files.count) items — see Transfers")
    }

    /// Removes our own staged copies (Photos picker) when an upload is cancelled. Never touches picked files.
    func discardStaged(_ files: [Ops.UploadFile]) {
        let tmp = Paths.cacheDir("tmp").standardizedFileURL.path + "/"
        for f in files where f.isTemporary {
            let dir = f.url.deletingLastPathComponent()
            if dir.standardizedFileURL.path.hasPrefix(tmp) { try? FileManager.default.removeItem(at: dir) }
        }
    }
}

struct NodeList: Identifiable { let id = UUID(); let nodes: [DriveNode] }

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
