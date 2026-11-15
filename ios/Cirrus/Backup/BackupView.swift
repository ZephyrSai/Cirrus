import CirrusCore
import SwiftUI

/// Back Up iCloud: copies iCloud Drive and every Photos library (originals with Live Photo videos, edits and RAW)
/// into "<folder>/Cirrus Backup/<account>/", e.g. on a USB drive. The engine evaluates first (sizes against free
/// space), then copies only what's new or changed; it never deletes anything in iCloud.
struct BackupView: View {
    @Environment(AppState.self) private var state
    @AppStorage("backupAccount") private var accountID = ""
    @State private var folder: URL? = FolderBookmarks.load("backup")
    @State private var picking = false
    @State private var includeDrive = UserDefaults.standard.bool(forKey: "backupDrive")
    @State private var includePhotos = UserDefaults.standard.bool(forKey: "backupPhotos")
    @State private var includeShared = UserDefaults.standard.bool(forKey: "backupShared")
    @State private var keepDeleted = UserDefaults.standard.bool(forKey: "backupKeepDeleted")
    @State private var live = UserDefaults.standard.bool(forKey: "exportLive")
    @State private var edited = UserDefaults.standard.bool(forKey: "exportEdited")
    @State private var raw = UserDefaults.standard.bool(forKey: "exportRAW")
    @State private var evaluating: String?
    @State private var evaluation: BackupEngine.Evaluation?
    @State private var engine: BackupEngine?
    @State private var error: String?

    var sources: [Account] { state.webAccounts + (state.deviceAccount.map { [$0] } ?? []) }
    var account: Account? { sources.first { $0.id == accountID } ?? sources.first }

    var options: SyncOptions {
        var o = SyncOptions()
        o.includeDrive = includeDrive && account?.drive != nil
        o.includePhotos = includePhotos
        o.includeSharedLibrary = includeShared
        o.keepDeleted = keepDeleted
        o.includeLive = live; o.includeEdited = edited; o.includeRAW = raw
        o.photoLayout = "{yyyy}/{MM}"
        o.writeManifest = true
        return o
    }

    var body: some View {
        let _ = state.accountsVersion
        Form {
            Section {
                if sources.isEmpty {
                    Button("Sign In with Apple ID") { state.signIn = .init() }
                } else {
                    Picker("Back up", selection: Binding(get: { account?.id ?? "" }, set: { accountID = $0; reset() })) {
                        ForEach(sources, id: \.id) { Text($0.displayTitle).tag($0.id) }
                    }
                }
                Button { picking = true } label: {
                    LabeledContent("To") {
                        Text(folder.map(FolderBookmarks.displayName) ?? "Choose a folder or drive…")
                            .foregroundStyle(folder == nil ? Color.accentColor : .secondary)
                    }
                }
            } footer: {
                Text("Pick a folder on a USB drive or SD card (USB-C iPhone and iPad), a file server, or this device. Cirrus writes into “Cirrus Backup/\(account?.title ?? "account")” there and only adds or updates files.")
            }
            Section("Include") {
                if account?.drive != nil { Toggle("iCloud Drive", isOn: $includeDrive) }
                Toggle("Photos", isOn: $includePhotos)
                if includePhotos {
                    Toggle("Live Photo videos", isOn: $live)
                    Toggle("Edited versions", isOn: $edited)
                    Toggle("RAW and alternate originals", isOn: $raw)
                    if account?.isDevice == false { Toggle("Shared Library", isOn: $includeShared) }
                }
            }
            Section {
                Toggle("Keep files deleted from iCloud", isOn: $keepDeleted)
            } footer: {
                Text(keepDeleted ? "The backup keeps everything it has ever copied." :
                     "Files you delete in iCloud Drive are moved out of the backup into “.cirrus/Removed” on the drive (never erased). Photos are always kept.")
            }
            .onChange(of: [includeDrive, includePhotos, includeShared, keepDeleted, live, edited, raw]) { evaluation = nil }
            if let e = evaluation { summary(e) }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
            Section {
                if let evaluating {
                    HStack { ProgressView(); Text(evaluating).foregroundStyle(.secondary).lineLimit(2) }
                } else if let e = evaluation {
                    Button { start(e) } label: { Label("Back Up Now", systemImage: "externaldrive.badge.checkmark") }
                        .disabled(!e.fits || stagingProblem(e) != nil || (e.drivePlans.allSatisfy { $0.plan.isEmpty } && e.photos.allSatisfy { $0.pending.isEmpty }))
                    Button("Check Again") { Task { await evaluate() } }
                } else {
                    Button { Task { await evaluate() } } label: { Label("Check Sizes", systemImage: "gauge.with.dots.needle.33percent") }
                        .disabled(folder == nil || account == nil || (!includeDrive && !includePhotos))
                }
            } footer: {
                Text("Long backups keep running when you switch apps" + (ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? "; iOS shows their progress and lets you stop them." : " for a short while; keep Cirrus open for big ones.") + " Running it again continues where it stopped.")
            }
        }
        .navigationTitle("Back Up iCloud")
        .task {
            #if DEBUG
            if let f = DebugScreens.autoFolder {
                DebugScreens.autoFolder = nil; folder = f; await evaluate()
                if DebugScreens.autoRun, let e = evaluation { start(e); state.selection = .transfers }
            }
            #endif
        }
        .sheet(isPresented: $picking) {
            FolderPicker(startIn: folder) { url in
                FolderBookmarks.save(url, key: "backup")
                folder = url
                reset()
            }.ignoresSafeArea()
        }
    }

    func summary(_ e: BackupEngine.Evaluation) -> some View {
        Section("Check") {
            if let s = e.storage, s.total > 0 { LabeledContent("iCloud storage used", value: "\(s.used.byteString) of \(s.total.byteString)") }
            if includeDrive, account?.drive != nil { LabeledContent("iCloud Drive", value: "\(e.driveFiles) files, \(e.driveBytes.byteString)") }
            if includePhotos { LabeledContent("Photos", value: "\(e.photoCount) items, \(e.photosBytes.byteString)") }
            LabeledContent("To copy now", value: e.pendingBytes == 0 ? "Nothing — up to date" : e.pendingBytes.byteString)
            LabeledContent("Free at destination", value: e.free.byteString)
            if !e.fits {
                Label("Needs \(e.requiredFree.byteString) free, including headroom.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let p = stagingProblem(e) { Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            ForEach(e.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    func reset() { evaluation = nil; engine = nil; error = nil }

    /// Files are downloaded into Cirrus's caches on this device before they're copied to the drive, up to
    /// four at a time (twice for iCloud Drive packages, which arrive zipped).
    func stagingProblem(_ e: BackupEngine.Evaluation) -> String? {
        let drive = e.drivePlans.flatMap { $0.plan.actions.map(\.bytes) }.max() ?? 0
        let photos = e.photos.flatMap { $0.pending.map(\.size) }.max() ?? 0
        return Ops.internalSpaceProblem(largest: max(drive, photos), copies: 4)
    }

    func makeEngine(_ account: Account, _ dest: URL) -> BackupEngine {
        var storage: (@Sendable () async -> StorageUsage?)?
        if account.kind == .web { storage = { await account.storageUsage() } }
        let sources = BackupEngine.Sources(accountTitle: account.title, drive: account.drive, nativeDriveRoot: nil, photos: account.photos,
                                           storage: storage)
        return BackupEngine(sources: sources, destination: dest, options: options)
    }

    func evaluate() async {
        guard let folder, let account else { return }
        if let p = DestinationCheck.problem(folder, backup: true) { error = p; evaluation = nil; return }
        error = nil
        evaluating = "Checking…"
        defer { evaluating = nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let eng = makeEngine(account, folder)
        do {
            var e = try await eng.evaluate { msg in Task { @MainActor in if evaluating != nil { evaluating = msg } } }
            if VolumeInfo.info(for: folder)?.isInternal == true, !e.warnings.contains(where: { $0.contains("own storage") }) {
                e.warnings.append("This folder is on this device’s own storage. For a real backup, choose a USB drive or a folder on another device.")
            }
            engine = eng
            evaluation = e
        } catch {
            self.error = error.localizedDescription
        }
    }

    func start(_ e: BackupEngine.Evaluation) {
        guard let folder, let eng = engine, let account else { return }
        let d = UserDefaults.standard
        d.set(includeDrive, forKey: "backupDrive"); d.set(includePhotos, forKey: "backupPhotos")
        d.set(includeShared, forKey: "backupShared"); d.set(keepDeleted, forKey: "backupKeepDeleted")
        let first = EvalBox(e)
        let title = "Back Up " + account.displayTitle
        TransferManager.shared.enqueue(title, detail: FolderBookmarks.displayName(folder), direction: .download, total: e.pendingBytes,
                                       group: Ops.group(account), quotaKey: Ops.volumeKey(folder)) { t in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            // The system shows this progress on the Lock Screen: counts and sizes only, no names.
            let run = await MainActor.run { LongRun.start(title: "Backing up iCloud", subtitle: "Starting…") { TransferManager.shared.cancel(t) } }
            var ok = false
            defer { Task { @MainActor in run.finish(success: ok) } }
            // A retry evaluates again, so it copies only what's still missing.
            let ev: BackupEngine.Evaluation
            if let e0 = await first.take() { ev = e0 } else { ev = try await eng.evaluate { t.setDetail($0) } }
            let report = try await eng.run(ev) { p in
                t.report(p.bytesDone, max(p.bytesTotal, 1))
                t.setDetail(p.phase)
                let line = p.bytesTotal > 0 ? "\(p.bytesDone.byteString) of \(p.bytesTotal.byteString)" : "\(p.filesDone) of \(p.filesTotal) files"
                Task { @MainActor in run.update(done: p.bytesDone, total: p.bytesTotal, subtitle: line) }
            }
            if !report.failed.isEmpty {
                throw OpsError(message: "\(report.failed.count) items didn’t copy (see “Backup Info.txt”). Retry continues with those.")
            }
            t.setDetail(report.summary)
            ok = true
        }
        evaluation = nil
        state.show("Backing up — see Transfers")
    }
}
