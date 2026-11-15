import CirrusCore
import Foundation
import Observation

struct DriveFolderRef: Hashable {
    var accountID: String
    var folderID: String
    var title: String
}

/// One Drive folder's listing: the in-memory copy (60 s, like the Mac), then the disk cache shown at once
/// while the server is asked again.
@MainActor @Observable
final class DriveFolderModel {
    static var memory = [String: (at: Date, nodes: [DriveNode])]()

    let account: Account
    let folderID: String
    var nodes: [DriveNode] = []
    var loading = false
    var error: String?
    var loaded = false
    var key: String { account.id + "|" + folderID }

    init(account: Account, folderID: String) {
        self.account = account
        self.folderID = folderID
        if let m = Self.memory[key] { nodes = m.nodes; loaded = true }
    }

    var cacheURL: URL { ListingCache.file(account: account.id, library: "drive", album: ListingCache.stableKey(folderID)) }

    func load(force: Bool = false) async {
        if !force, let m = Self.memory[key], Date().timeIntervalSince(m.at) < 60 { nodes = m.nodes; loaded = true; return }
        guard let drive = account.drive else { error = ICloudError.needsSignIn.localizedDescription; return }
        if !loaded, account.kind == .web, let c = ListingCache.read(ListingCache.DriveCache.self, cacheURL) {
            nodes = Self.sorted(c.nodes); loaded = true
        }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await drive.list(folderID)
            if account.kind == .web { ListingCache.write(ListingCache.DriveCache(nodes: fresh, savedAt: Date()), cacheURL) }
            nodes = Self.sorted(fresh)
            Self.memory[key] = (Date(), nodes)
            error = nil
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Folders first, then names the way Finder and Files sort them. Temporary ".cirrus-upload-…" copies stay
    /// visible: if a replace was interrupted, that copy may be the newest version of the file.
    static func sorted(_ nodes: [DriveNode]) -> [DriveNode] {
        nodes.filter { $0.name != ".DS_Store" }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func invalidate() { Self.memory[key] = nil }
}
