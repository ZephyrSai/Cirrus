import Foundation
import os

/// Logging. Never pass passwords, cookies, tokens or Apple IDs to these functions.
public enum Log {
    static let logger = Logger(subsystem: "io.github.zephyrsai.cirrus", category: "core")
    public static var verbose = ProcessInfo.processInfo.environment["CIRRUS_DEBUG"] != nil

    /// May mention file names or other user content: redacted in the system log (shows as <private>).
    public static func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.notice("\(m, privacy: .private)")
        if verbose { FileHandle.standardError.write(Data("[cirrus] \(m)\n".utf8)) }
    }

    /// Diagnostics with no user content (HTTP status lines, timings, counts): readable in the system log.
    public static func status(_ message: @autoclosure () -> String) {
        let m = message()
        logger.notice("\(m, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data("[cirrus] \(m)\n".utf8)) }
    }

    public static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let m = message()
        logger.debug("\(m, privacy: .public)")
        FileHandle.standardError.write(Data("[cirrus] \(m)\n".utf8))
    }

    public static func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .private)")
        if verbose { FileHandle.standardError.write(Data("[cirrus] ERROR \(m)\n".utf8)) }
    }
}

public enum Paths {
    /// CIRRUS_PROFILE as a plain name (letters, digits, - and _, at most 32), never a path.
    public static let profile: String? = ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map(profileName)
    static func profileName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let s = String(String.UnicodeScalarView(raw.unicodeScalars.filter { allowed.contains($0) }).prefix(32))
        return s.isEmpty ? "invalid" : s
    }

    /// Per-account folder name inside the Open/Preview caches (a hash, so it never names the Apple ID).
    public static func accountCacheName(_ accountID: String) -> String { "acct-" + SHA256Hex.digest("cirrus-cache|" + accountID).prefix(16) }
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(profile.map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
        privateDir(dir)
        return dir
    }

    /// Owner-only (0700) so other accounts on this Mac can't read cached iCloud content.
    static func privateDir(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Temporary copies (previews, relays, partial downloads) are removed after a day, opened/preview
    /// copies of iCloud files after two weeks.
    public static func cleanCaches() {
        let fm = FileManager.default
        let now = Date()
        for (name, maxAge) in [("Preview", 86_400.0), ("relay", 86_400.0), ("tmp", 86_400.0), ("Open", 14 * 86_400.0)] {
            for u in itemDirs(in: caches.appendingPathComponent(name)) where now.timeIntervalSince(newestChange(u)) > maxAge {
                if name == "Open" { retireOpenCopy(u) } else { try? fm.removeItem(at: u) }
            }
        }
    }

    /// Entries of a cache folder, looking inside per-account `acct-…` folders.
    public static func itemDirs(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var out = [URL]()
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            if u.lastPathComponent.hasPrefix("acct-") { out += (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] }
            else { out.append(u) }
        }
        return out
    }

    /// Latest modification anywhere inside (a folder's own date doesn't change when a file in it is edited).
    public static func newestChange(_ u: URL, ignoring: Set<String> = [fetchedMarker, ".DS_Store"], includeSelf: Bool = true) -> Date {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = includeSelf ? ((try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) : .distantPast
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: keys) {
            while let f = e.nextObject() as? URL {
                if ignoring.contains(f.lastPathComponent) { continue }
                if let m = try? f.resourceValues(forKeys: Set(keys)).contentModificationDate, m > newest { newest = m }
            }
        }
        return newest
    }

    public static let fetchedMarker = ".cirrus-fetched"
    /// Stamped when a download into an opened-copy folder finishes; later changes inside mean local edits.
    public static func markFetched(_ dir: URL) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(fetchedMarker).path, contents: nil)
    }

    /// True when a file inside was changed after Cirrus finished downloading it. Without a marker (older
    /// copies), the folder's creation date is used, and anything unknown counts as edited.
    public static func wasEditedLocally(_ u: URL) -> Bool {
        let marker = u.appendingPathComponent(fetchedMarker)
        let ref = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate)
        guard let ref else { return true }
        // The folder's own date moves when the marker is written, so only the files inside count.
        return newestChange(u, includeSelf: false) > ref.addingTimeInterval(2)
    }

    /// Opened copies can hold edits that were never uploaded: those go to the Trash, the rest are removed.
    public static func retireOpenCopy(_ u: URL) {
        if wasEditedLocally(u) {
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { return }
            return   // couldn't trash it: keep it rather than lose edits
        }
        try? FileManager.default.removeItem(at: u)
    }

    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(profile.map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
        privateDir(dir)
        return dir
    }

    public static func cacheDir(_ name: String) -> URL {
        let d = caches.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public static func supportDir(_ name: String) -> URL {
        let d = appSupport.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A unique scratch file location for downloads in flight.
    public static func tempFile(named name: String) -> URL {
        let dir = cacheDir("tmp").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name.isEmpty ? "file" : name)
    }

    /// Filesystem-safe version of a name coming from the network.
    public static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: ":")
        s = s.replacingOccurrences(of: "\0", with: "")
        if s == "." || s == ".." || s.isEmpty { s = "_" + s }
        return s
    }
}

public extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
