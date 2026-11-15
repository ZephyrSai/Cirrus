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
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
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
            let dir = caches.appendingPathComponent(name)
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(m) > maxAge { try? fm.removeItem(at: u) }
            }
        }
    }

    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
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
