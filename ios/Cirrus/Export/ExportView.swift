import CirrusCore
import SwiftUI

struct ExportRequest: Identifiable {
    enum Source { case album(PhotoAlbum), assets([PhotoAsset]) }
    let id = UUID()
    let account: Account
    let library: PhotoLibraryRef
    let source: Source
}

/// Where exports and backups may go.
enum DestinationCheck {
    static func problem(_ url: URL, backup: Bool) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if SafetyPolicy.touchesICloud(url) {
            if backup { return "This folder is in iCloud Drive. A backup of iCloud should live somewhere else: choose a USB drive or a folder on this device." }
            if SafetyPolicy.readOnlyICloud { return "This folder is in iCloud Drive, and read-only mode is on. Choose a folder on this device or a drive." }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return "That folder isn’t available. Connect the drive it’s on, or choose it again."
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { return "Cirrus can’t write to that folder. Choose another one." }
        return nil
    }
}

/// Export originals (with Live Photo videos, edits and RAW) into YYYY/MM folders in any Files location.
struct ExportView: View {
    let request: ExportRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var folder: URL? = FolderBookmarks.load("export")
    @State private var picking = false
    @State private var live = UserDefaults.standard.bool(forKey: "exportLive")
    @State private var edited = UserDefaults.standard.bool(forKey: "exportEdited")
    @State private var raw = UserDefaults.standard.bool(forKey: "exportRAW")
    @State private var layout = UserDefaults.standard.string(forKey: "exportLayout") ?? "{yyyy}/{MM}"
    @State private var evaluating: String?
    @State private var evaluation: PhotoExporter.Evaluation?
    @State private var exporter: PhotoExporter?
    @State private var free: Int64?
    @State private var error: String?

    var sourceTitle: String {
        switch request.source {
        case .album(let a): return a.isAllPhotos || a.id == "smart:all" ? "All Photos — \(request.library.name)" : a.name
        case .assets(let list): return list.count == 1 ? list[0].filename : "\(list.count) selected items"
        }
    }

    var isWholeLibrary: Bool { if case .album(let a) = request.source { return a.isAllPhotos || a.id == "smart:all" }; return false }

    var options: SyncOptions {
        var o = SyncOptions()
        o.includeLive = live; o.includeEdited = edited; o.includeRAW = raw
        o.photoLayout = layout
        // The CSV/JSON manifest describes a whole library; partial exports leave an existing one alone.
        o.writeManifest = isWholeLibrary
        o.albumFolders = false
        return o
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Export") {
                    LabeledContent("From", value: sourceTitle)
                    LabeledContent("Account", value: request.account.displayTitle)
                }
                Section {
                    Button { picking = true } label: {
                        LabeledContent("Folder") {
                            Text(folder.map(FolderBookmarks.displayName) ?? "Choose…").foregroundStyle(folder == nil ? Color.accentColor : .secondary)
                        }
                    }
                    if let free { LabeledContent("Free there", value: free.byteString) }
                } header: { Text("Destination") } footer: {
                    Text("Any Files location: this device, a USB drive or SD card, or a file server. Files that are already there from an earlier export are skipped.")
                }
                Section("Include") {
                    Toggle("Live Photo videos (.MOV)", isOn: $live)
                    Toggle("Edited versions (-edited)", isOn: $edited)
                    Toggle("RAW and alternate originals", isOn: $raw)
                    Picker("Folders", selection: $layout) {
                        Text("Year / Month").tag("{yyyy}/{MM}")
                        Text("Year / Month / Day").tag("{yyyy}/{MM}/{dd}")
                        Text("One folder").tag("flat")
                    }
                }
                .onChange(of: [live, edited, raw]) { evaluation = nil }
                .onChange(of: layout) { evaluation = nil }
                if let e = evaluation { summary(e) }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
            }
            .navigationTitle("Export Originals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if evaluating != nil { ProgressView() }
                    else if let e = evaluation, canExport(e) { Button("Export") { start(e) }.bold() }
                    else { Button("Check") { Task { await evaluate() } }.disabled(folder == nil) }
                }
            }
            .overlay(alignment: .bottom) {
                if let evaluating { Text(evaluating).font(.footnote).foregroundStyle(.secondary).padding() }
            }
            .sheet(isPresented: $picking) {
                FolderPicker(startIn: folder) { url in
                    FolderBookmarks.save(url, key: "export")
                    folder = url; evaluation = nil; error = nil
                    Task { await evaluate() }
                }.ignoresSafeArea()
            }
            .task {
                #if DEBUG
                if let f = DebugScreens.autoFolder { folder = f; DebugScreens.autoFolder = nil }
                #endif
                if folder != nil { await evaluate() }
            }
        }
    }

    func summary(_ e: PhotoExporter.Evaluation) -> some View {
        Section("Check") {
            LabeledContent("Items", value: "\(e.assetCount)")
            LabeledContent("Files", value: "\(e.files.count) (\(e.totalBytes.byteString))")
            LabeledContent("To copy now", value: e.pending.isEmpty ? "Nothing — up to date" : "\(e.pending.count) files, \(e.pendingBytes.byteString)")
            if let folder, Ops.isFAT(folder), e.largestFile > Limits.fat32Max {
                Label("This drive is FAT32, which can’t hold files over 4 GB; some of these are larger.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let free, e.pendingBytes + 100_000_000 > free {
                Label("Not enough space: \(e.pendingBytes.byteString) needed, \(free.byteString) free.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let p = stagingProblem(e) { Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
    }

    func canExport(_ e: PhotoExporter.Evaluation) -> Bool {
        if stagingProblem(e) != nil { return false }
        guard let free else { return !e.pending.isEmpty }
        return !e.pending.isEmpty && e.pendingBytes + 100_000_000 <= free
    }

    /// Up to four originals download at once and are staged on this device first.
    func stagingProblem(_ e: PhotoExporter.Evaluation) -> String? {
        Ops.internalSpaceProblem(largest: e.pending.map(\.size).max() ?? 0, copies: 4)
    }

    func makeExporter(_ dest: URL) -> PhotoExporter? {
        guard let backend = request.account.photos else { return nil }
        switch request.source {
        case .album(let a): return PhotoExporter(backend: backend, library: request.library, album: isWholeLibrary ? nil : a, destination: dest, options: options)
        case .assets(let list):
            return PhotoExporter(backend: SubsetPhotos(base: backend, assets: list), library: request.library, album: SubsetPhotos.album,
                                 destination: dest, options: options)
        }
    }

    func evaluate() async {
        guard let folder else { return }
        if let p = DestinationCheck.problem(folder, backup: false) { error = p; return }
        error = nil
        evaluating = "Listing photos…"
        defer { evaluating = nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        free = Ops.localFree(folder)
        guard let ex = makeExporter(folder) else { error = ICloudError.needsSignIn.localizedDescription; return }
        do {
            let e = try await ex.evaluate { msg in Task { @MainActor in if evaluating != nil { evaluating = msg } } }
            exporter = ex
            evaluation = e
        } catch {
            self.error = error.localizedDescription
        }
    }

    func start(_ e: PhotoExporter.Evaluation) {
        guard let folder, let ex = exporter else { return }
        let d = UserDefaults.standard
        d.set(live, forKey: "exportLive"); d.set(edited, forKey: "exportEdited"); d.set(raw, forKey: "exportRAW"); d.set(layout, forKey: "exportLayout")
        let first = EvalBox(e)
        let title = "Export: " + sourceTitle
        TransferManager.shared.enqueue(title, detail: FolderBookmarks.displayName(folder), direction: .download, total: e.pendingBytes,
                                       group: Ops.group(request.account), quotaKey: Ops.volumeKey(folder)) { t in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            // The system shows this progress on the Lock Screen: counts only, no album, file or account names.
            let run = await MainActor.run { LongRun.start(title: "Exporting photos", subtitle: "Starting…") { TransferManager.shared.cancel(t) } }
            var ok = false
            defer { Task { @MainActor in run.finish(success: ok) } }
            // A retry re-checks what's still missing (the manifest makes this incremental).
            let ev: PhotoExporter.Evaluation
            if let e0 = await first.take() { ev = e0 } else { ev = try await ex.evaluate { t.setDetail($0) } }
            if let free = await MainActor.run(body: { Ops.localFree(folder) }), ev.pendingBytes > free {
                throw OpsError(message: "Not enough space at the destination: \(ev.pendingBytes.byteString) needed, \(free.byteString) free.")
            }
            let report = try await ex.run(ev) { p in
                t.report(p.bytesDone, max(p.bytesTotal, 1))
                t.setDetail("\(p.filesDone) of \(p.filesTotal) files")
                Task { @MainActor in run.update(done: p.bytesDone, total: p.bytesTotal, subtitle: "\(p.filesDone) of \(p.filesTotal) files") }
            }
            if !report.failed.isEmpty {
                throw OpsError(message: "\(report.failed.count) files didn’t export. Retry continues with those.")
            }
            t.setDetail(report.summary)
            ok = true
        }
        state.show("Exporting — see Transfers")
        dismiss()
    }
}

/// Hands the first evaluation to the first run only; a retry evaluates again.
actor EvalBox<T: Sendable> {
    private var value: T?
    init(_ v: T) { value = v }
    func take() -> T? { defer { value = nil }; return value }
}
