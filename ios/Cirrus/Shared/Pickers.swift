import CirrusCore
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Folders the user picked (downloads, exports, backups), remembered as bookmarks so the next run can
/// write there again without asking. On iOS a bookmark made from a document-picker URL carries its access.
enum FolderBookmarks {
    static func save(_ url: URL, key: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "bookmark." + key)
        }
    }

    static func load(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "bookmark." + key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { save(url, key: key) }
        return url
    }

    static func forget(_ key: String) { UserDefaults.standard.removeObject(forKey: "bookmark." + key) }

    /// "On My iPhone › Cirrus › Downloads" — the default place for downloads.
    static var appDownloads: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A short, human name for where a folder is ("Cirrus › Downloads", "USB Drive › Backups").
    static func displayName(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let vol = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(docs) {
            let rel = String(url.standardizedFileURL.path.dropFirst(docs.count)).split(separator: "/").joined(separator: " › ")
            return "Cirrus" + (rel.isEmpty ? "" : " › " + rel)
        }
        if let vol, vol != url.lastPathComponent, !(VolumeInfo.info(for: url)?.isInternal ?? true) { return vol + " › " + url.lastPathComponent }
        return url.lastPathComponent
    }
}

/// UIDocumentPickerViewController for choosing a folder (open in place, security scoped).
struct FolderPicker: UIViewControllerRepresentable {
    var startIn: URL?
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        vc.allowsMultipleSelection = false
        vc.directoryURL = startIn
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let u = urls.first { onPick(u) } }
    }
}

/// UIDocumentPickerViewController for choosing files to upload (open in place: no extra copy is made).
struct FilesPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        vc.allowsMultipleSelection = true
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

/// The system Photos picker (no library permission needed). Originals are requested as they are
/// (`.current`), staged in Cirrus's temp folder for the upload, then removed.
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.selectionLimit = 0
        cfg.preferredAssetRepresentationMode = .current
        cfg.filter = .any(of: [.images, .videos, .livePhotos])
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ p: PhotoPicker) { parent = p }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            let onPick = parent.onPick
            Task.detached {
                var urls = [URL]()
                for r in results {
                    let p = r.itemProvider
                    let type = [UTType.movie, .image].first { t in p.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: t) == true } }
                    guard let type, let id = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: type) == true }) else { continue }
                    if let u = await Self.stage(p, typeID: id) { urls.append(u) }
                }
                let picked = urls
                await MainActor.run { onPick(picked) }
            }
        }

        static func stage(_ p: NSItemProvider, typeID: String) async -> URL? {
            await withCheckedContinuation { cont in
                _ = p.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    // The provider deletes its file when this returns: copy it into our temp folder first.
                    guard let url else { cont.resume(returning: nil); return }
                    let name = (p.suggestedName.map { $0 + "." + url.pathExtension }) ?? url.lastPathComponent
                    let dst = Paths.tempFile(named: Paths.safeName(name))
                    do { try FileManager.default.copyItem(at: url, to: dst); cont.resume(returning: dst) } catch { cont.resume(returning: nil) }
                }
            }
        }
    }
}

/// QLPreviewController for one local file. Editing (Markup) is off: copies here are previews, and edits
/// would never reach iCloud.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.delegate = context.coordinator
        ql.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in context.coordinator.close() })
        return UINavigationController(rootViewController: ql)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: QuickLookView
        init(_ p: QuickLookView) { parent = p }
        func close() { parent.dismiss() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { parent.url as NSURL }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }
}

/// UIActivityViewController (share sheet) for local copies.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable { let id = UUID(); let url: URL }
struct IdentifiedURLs: Identifiable { let id = UUID(); let urls: [URL] }
