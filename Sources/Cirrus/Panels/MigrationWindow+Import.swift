import AppKit
import CirrusCore

/// “Google → iCloud” in the Move window: Google Drive into iCloud Drive, Google Photos (Takeout
/// export or the Google Photos picker) into iCloud Photos.
extension MigrationWindowController {
    var isImport: Bool { directionControl.selectedSegment == 1 }
    var importIdleText: String { "Choose what to copy, then select Check Space. Nothing in Google is changed." }
    static let importIntro = "Cirrus copies your Google Drive into a “From Google Drive” folder in iCloud Drive (Docs, Sheets and Slides as Office files), and your Google Photos — from a Google Takeout export — into iCloud Photos with their dates, places, albums and favorites. Google isn’t changed, and later runs only bring what’s new."

    @objc func directionChanged(_ sender: Any?) {
        applyDirection()
        optionsChanged()
    }

    func applyDirection() {
        let imp = isImport
        for v in forwardViews { v.isHidden = imp }
        importPanel.view.isHidden = !imp
        introLabel.stringValue = imp ? Self.importIntro : Self.forwardIntro
        window?.title = imp ? "Copy from Google" : "Move to Google"
        openDrive.isHidden = true
        openPhotos.isHidden = true
        icloudBar.isHidden = true; icloudBarLabel.isHidden = true
        googleBar.isHidden = true; googleBarLabel.isHidden = true
        showDetails(nil, [])
        importPanel.refresh(for: selectedGoogle)
    }

    func makeImportEngine() throws -> ImportEngine {
        guard let a = selectedAccount else { throw SyncError.unavailable("Sign in to an iCloud account first (File › Sign In with Apple ID…).") }
        if a.status == .needsSignIn { throw ICloudError.needsSignIn }
        guard let g = selectedGoogle else { throw GoogleAccounts.shared.isConfigured ? GoogleError.reconnect("Connect a Google account first.") : GoogleError.notConfigured }
        let api = try GoogleAccounts.shared.api(for: g.id)
        var storage: (@Sendable () async -> StorageUsage?)?
        if a.session != nil { storage = { await a.storageUsage() } }
        let target = ImportEngine.Target(key: a.id, title: a.kind == .mac ? "This Mac" : (a.appleID ?? a.title), drive: a.drive,
                                         nativeDriveRoot: a.drive == nil ? a.driveRoot : nil, photos: a.photos, storage: storage, isWeb: a.kind == .web)
        return ImportEngine(source: .init(api: api, takeout: importPanel.takeout, picked: importPanel.picked), target: target, options: importPanel.options,
                            stateDir: Paths.supportDir("migration"), stagingDir: Paths.cacheDir("migration-staging"))
    }

    func evaluateImport() {
        let o = importPanel.options
        guard o.includeDrive || o.includePhotos else { summary.stringValue = "Pick at least one thing to copy."; return }
        let e: ImportEngine
        do { e = try makeImportEngine() } catch {
            summary.stringValue = error.localizedDescription
            if (error as? GoogleError) == .notConfigured { presentSetup(thenConnect: true) }
            return
        }
        evalTask?.cancel()
        spinner.startAnimation(nil)
        checkButton.isEnabled = false
        fitIcon.image = nil
        warnings.stringValue = ""
        showDetails(nil, [])
        summary.stringValue = "Measuring…"
        evalTask = Task {
            defer { spinner.stopAnimation(nil); checkButton.isEnabled = true; evalTask = nil }
            do {
                let ev = try await e.evaluate { s in Task { @MainActor in self.summary.stringValue = s } }
                guard !Task.isCancelled else { return }
                importEngine = e
                showImport(ev)
            } catch {
                summary.stringValue = error.localizedDescription
                fitIcon.image = NSImage(systemSymbolName: "xmark.octagon.fill", accessibilityDescription: nil)
                fitIcon.contentTintColor = .systemRed
            }
        }
    }

    func showImport(_ ev: ImportEngine.Evaluation) {
        importEvaluation = ev
        if let u = ev.icloud, u.total > 0 {
            icloudBar.usage = u.adding(ev.pendingBytes, label: "This copy")
            icloudBar.isHidden = false
            icloudBarLabel.isHidden = false
            icloudBarLabel.stringValue = "iCloud — after this copy"
        }
        googleBar.isHidden = true
        googleBarLabel.isHidden = true
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ i: Int) -> String { f.string(from: NSNumber(value: i)) ?? String(i) }
        var lines = [String]()
        if ev.driveEnabled {
            let left = ev.drivePending.isEmpty ? "already in iCloud" : "\(n(ev.drivePending.count)) to copy (\(ev.drivePendingBytes.byteString)\(ev.drivePending.contains { $0.export != nil } ? " or so" : ""))"
            lines.append("Google Drive: \(n(ev.driveFiles)) files, \(ev.driveBytes.byteString)" + (ev.docs > 0 ? " plus \(n(ev.docs)) Google Docs" : "") + " — \(left).")
        }
        if ev.photosEnabled {
            var sources = [String]()
            if ev.takeoutItems > 0 || !importPanel.takeout.isEmpty {
                sources.append(ev.takeoutParts > 0 ? "\(n(ev.takeoutItems)) from the Takeout export (\(ev.takeoutParts) part\(ev.takeoutParts == 1 ? "" : "s"))" : "\(n(ev.takeoutItems)) from the Takeout folder")
            }
            if ev.pickedItems > 0 { sources.append("\(n(ev.pickedItems)) picked") }
            let about = ev.photoPending.contains(where: \.sizeIsEstimate) ? "about " : ""
            lines.append("Google Photos: " + sources.joined(separator: ", ") + " — " + (ev.photoPending.isEmpty ? "already in iCloud." : "\(n(ev.photoPending.count)) to copy (\(about)\(ev.photoPendingBytes.byteString))."))
            if !ev.albums.isEmpty {
                lines.append(ev.albumAddsPending > 0 ? "Albums: \(ev.albums.count), with \(n(ev.albumAddsPending)) photo\(ev.albumAddsPending == 1 ? "" : "s") to add." : "Albums: \(ev.albums.count) — already in iCloud.")
            }
            if ev.favoritesPending > 0 { lines.append("Favorites: \(n(ev.favoritesPending)) to mark.") }
        }
        if let free = ev.icloudFree {
            lines.append(ev.pendingBytes == 0 ? "iCloud storage: \(free.byteString) free." : "iCloud storage: \(free.byteString) free; this copy needs about \(ev.requiredICloud.byteString) with headroom.")
        }
        var warns = ev.warnings
        if let at = importPanel.pickedAt, !importPanel.picked.isEmpty, Date().timeIntervalSince(at) > 50 * 60 {
            warns.append("Google’s links to the photos you picked expire after an hour. Pick them again before copying.")
        }
        summary.stringValue = lines.isEmpty ? "Nothing to copy with these choices." : lines.joined(separator: "\n")
        warnings.stringValue = warns.map { "⚠︎ " + $0 }.joined(separator: "\n")
        showDetails(ev.skipped.isEmpty ? nil : "Skipped — these can’t be copied", ev.skipped.map { "\($0.name)\($0.size > 0 ? " (\($0.size.byteString))" : ""): \($0.reason)" })
        let ok = ev.fits && (ev.driveEnabled || ev.photosEnabled)
        fitIcon.image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill", accessibilityDescription: nil)
        fitIcon.contentTintColor = ok ? .systemGreen : .systemRed
        runButton.isEnabled = ok && runningTransfer == nil
        runButton.title = ev.isUpToDate ? "Copy to iCloud (up to date)" : "Copy \(ev.sizesEstimated ? "about " : "")\(ev.pendingBytes.byteString) to iCloud"
    }

    func runImport() {
        guard let ev = importEvaluation, let e = importEngine, ev.fits, runningTransfer == nil else { return }
        runningIsImport = true
        runButton.isEnabled = false
        checkButton.isEnabled = false
        progress.doubleValue = 0
        progress.isHidden = false
        lastImportReport = nil
        let label = selectedGoogle.map { $0.email.isEmpty ? "Google" : $0.email } ?? "Google"
        runningTransfer = TransferManager.shared.enqueue("Copy \(label) to iCloud", detail: "Starting…", direction: .download, total: ev.pendingBytes * 2,
                                                         group: "migration") { t in
            let report = try await e.run(ev) { p in
                t.report(p.bytesDone, p.bytesTotal)
                t.setDetail(p.filesTotal > 0 ? "\(p.phase) — \(p.filesDone) of \(p.filesTotal)" : p.phase)
            }
            await MainActor.run { MigrationWindowController.shared?.lastImportReport = report }
            t.setDetail(report.summary)
            if let s = report.stopped { throw GoogleError.badResponse("Stopped: \(s)") }
            if !report.failed.isEmpty { throw GoogleError.badResponse("\(report.failed.count) item\(report.failed.count == 1 ? "" : "s") failed: \(report.failed.first ?? "")") }
        }
        updateRunProgress()
    }

    func finishImport(_ t: Transfer) {
        progress.isHidden = true
        runningTransfer = nil
        runningIsImport = false
        checkButton.isEnabled = true
        runButton.isEnabled = false
        runButton.title = "Copy to iCloud"
        let r = lastImportReport
        var lines = [String]()
        switch t.state {
        case .cancelled: lines.append("The copy was stopped. Select Check Space and Copy to iCloud to continue where it stopped.")
        default:
            if let r {
                lines.append((r.stopped == nil && r.failed.isEmpty ? "Done: " : "Finished with problems: ") + r.summary + ".")
                if r.albumAdds > 0 { lines.append("\(r.albumAdds) photo\(r.albumAdds == 1 ? "" : "s") added to albums; everything copied is also in “From Google Photos”.") }
                if let s = r.stopped { lines.append("Stopped early: \(s)") }
                lines.append("Run it again any time: only new and changed items are copied.")
            } else if case .failed(let m) = t.state { lines.append("The copy stopped: \(m)") }
        }
        summary.stringValue = lines.joined(separator: "\n")
        let ok = r != nil && r!.stopped == nil && r!.failed.isEmpty
        fitIcon.image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        fitIcon.contentTintColor = ok ? .systemGreen : .systemOrange
        warnings.stringValue = ""
        if let r {
            showDetails(r.failed.isEmpty && r.skipped.isEmpty ? nil : "Report", r.failed.map { "Failed — " + $0 } + r.skipped.map { "Skipped — \($0.name): \($0.reason)" })
        }
        // The picker session has served its purpose.
        if let sid = importPanel.pickerSession, let g = selectedGoogle, let api = try? GoogleAccounts.shared.api(for: g.id) {
            importPanel.pickerSession = nil
            Task { await GooglePicker(api: api).delete(sid) }
        }
        importEvaluation = nil
        importEngine = nil
    }

    /// Google Photos picker: Google's page opens in the browser, the user picks, Cirrus polls for the result.
    func startPicking() {
        guard let g = selectedGoogle else { summary.stringValue = "Connect a Google account first."; return }
        if !g.has(GoogleScopes.photosPicker) {
            startConnect(scopes: GoogleAccounts.importScopes, hint: g.email.isEmpty ? nil : g.email) { [weak self] in self?.startPicking() }
            return
        }
        guard pickTask == nil, let w = window, w.attachedSheet == nil else { return }
        let api: GoogleAPI
        do { api = try GoogleAccounts.shared.api(for: g.id) } catch { summary.stringValue = error.localizedDescription; return }
        let sheet = makeWaitSheet(title: "Pick photos in your browser",
                                  text: "Google Photos opened in your browser. Select the photos and videos to copy (up to 2,000), then choose Done. Cirrus is waiting here.")
        waitSheet = sheet
        w.beginSheet(sheet)
        pickTask = Task {
            defer {
                pickTask = nil
                if let s = waitSheet { w.endSheet(s); waitSheet = nil }
            }
            let picker = GooglePicker(api: api)
            var session: GooglePicker.Session?
            do {
                let s = try await picker.create()
                session = s
                let url = GooglePicker.browserURL(s)
                #if DEBUG
                if GoogleAccounts.shared.isDemo {
                    Task { try? await Task.sleep(nanoseconds: 300_000_000); FakeGoogleServer.pick(url) }
                } else { NSWorkspace.shared.open(url) }
                #else
                NSWorkspace.shared.open(url)
                #endif
                let done = try await picker.waitForPick(s)
                let items = try await picker.items(done.id)
                if let old = importPanel.pickerSession, old != s.id { await picker.delete(old) }
                importPanel.pickerSession = s.id
                importPanel.pickedAt = Date()
                importPanel.picked = items
                optionsChanged()
                summary.stringValue = items.isEmpty ? "Nothing was picked." : "\(items.count) picked. Select Check Space to see what will be copied."
            } catch {
                if let s = session { await picker.delete(s.id) }
                summary.stringValue = MigrationEngine.isCancel(error) ? "Picking was cancelled." : error.localizedDescription
            }
        }
    }
}
