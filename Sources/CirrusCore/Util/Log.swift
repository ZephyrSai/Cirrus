import Foundation
import os

/// Logging. Never pass passwords, cookies, tokens or Apple IDs to these functions.
public enum Log {
    static let logger = Logger(subsystem: "io.github.zephyrsai.cirrus", category: "core")
    public static var verbose = ProcessInfo.processInfo.environment["CIRRUS_DEBUG"] != nil

    public static func info(_ message: @autoclosure () -> String) {
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
        logger.error("\(m, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data("[cirrus] ERROR \(m)\n".utf8)) }
    }
}

public enum Paths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ProcessInfo.processInfo.environment["CIRRUS_PROFILE"].map { "Cirrus-\($0)" } ?? "Cirrus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
