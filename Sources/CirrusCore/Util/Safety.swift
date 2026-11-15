import Foundation

/// Global safety switches enforced inside the engine (not just the UI), so no code path can bypass them.
public enum SafetyPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _readOnly = false

    /// When on, nothing in iCloud (Drive, Photos, or the Mac's iCloud Drive folder) is changed:
    /// browsing, downloading, exporting and backing up still work.
    public static var readOnlyICloud: Bool {
        get { lock.withLock { _readOnly } }
        set { lock.withLock { _readOnly = newValue } }
    }

    public struct ReadOnlyError: LocalizedError {
        public init() {}
        public var errorDescription: String? {
            "Read-only mode is on, so Cirrus won’t change anything in iCloud. Turn it off in Settings › Safety if you want to upload, rename or delete."
        }
    }

    /// Throws when iCloud writes are blocked.
    public static func checkWrite() throws { if readOnlyICloud { throw ReadOnlyError() } }

    /// The user's home folder (on iOS the device's mobile home, not the app container).
    static var homeDirectory: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: "/private/var/mobile", isDirectory: true)
        #endif
    }

    /// The Mac's own iCloud Drive folders (~/Library/Mobile Documents) are iCloud too.
    public static func isICloudPath(_ url: URL) -> Bool {
        let mobile = homeDirectory.appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p == mobile || p.hasPrefix(mobile + "/") { return true }
        #if !os(macOS)
        // Files-app folders in iCloud Drive (from the document picker) live under …/Library/Mobile Documents/.
        if p.contains("/Library/Mobile Documents/") || p.hasSuffix("/Library/Mobile Documents") { return true }
        #endif
        if let o = ProcessInfo.processInfo.environment["CIRRUS_NATIVE_DRIVE"] { return p.hasPrefix(URL(fileURLWithPath: o).standardizedFileURL.path) }
        return false
    }

    /// Also true for items iCloud syncs from elsewhere (Desktop & Documents in iCloud) and for folders that
    /// contain the Mac's iCloud Drive, since trashing or replacing those would change iCloud too.
    public static func touchesICloud(_ url: URL) -> Bool {
        let paths = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
        for p in paths where isICloudPath(URL(fileURLWithPath: p)) { return true }
        let mobile = homeDirectory.appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
        for p in paths where mobile.hasPrefix(p.hasSuffix("/") ? p : p + "/") { return true }
        var u = url.resolvingSymlinksInPath()
        while u.path != "/" && !u.path.isEmpty {
            if let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey]) { return v.isUbiquitousItem == true }
            u = u.deletingLastPathComponent()
        }
        return false
    }

    public static func checkLocalWrite(_ url: URL) throws { if readOnlyICloud && touchesICloud(url) { throw ReadOnlyError() } }
}

public extension DriveBackend {
    /// Replace a file without a window where only the old copy exists in Recently Deleted:
    /// upload under a temporary name, then trash the old file, then rename the new one into place.
    func safeReplace(_ file: URL, name: String, in folderID: String, existing: DriveNode?, modified: Date?,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DriveNode {
        guard let existing, !existing.isFolder else {
            return try await upload(file, name: name, into: folderID, modified: modified, progress: progress)
        }
        let temp = ".cirrus-upload-\(UUID().uuidString.prefix(8))-" + name
        let uploaded = try await upload(file, name: temp, into: folderID, modified: modified, progress: progress)
        try await trash([existing])
        return try await rename(uploaded, to: name)
    }
}
