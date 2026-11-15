import Foundation

/// A change to a manifest that can be replayed from the journal.
protocol ManifestOperation: Codable {
    associatedtype Manifest: Codable
    func apply(_ m: inout Manifest)
}

/// A manifest file plus an append-only journal of changes since it was written, so a crash or
/// quit mid-run loses nothing. `compact()` folds the journal back into the manifest.
final class JournalStore<Op: ManifestOperation>: @unchecked Sendable {
    let base: URL
    let journal: URL
    private let lock = NSLock()
    private var m: Op.Manifest
    private var handle: FileHandle?

    init(dir: URL, name: String, empty: Op.Manifest) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        base = dir.appendingPathComponent(name + ".json")
        journal = dir.appendingPathComponent(name + ".journal")
        var manifest = (try? Data(contentsOf: base)).flatMap { try? JSONDecoder().decode(Op.Manifest.self, from: $0) } ?? empty
        if let data = try? Data(contentsOf: journal) {
            let dec = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                // A half-written last line (crash mid-write) is skipped.
                if let op = try? dec.decode(Op.self, from: Data(line)) { op.apply(&manifest) }
            }
        }
        m = manifest
    }

    var value: Op.Manifest { lock.withLock { m } }

    func apply(_ op: Op) {
        lock.withLock {
            op.apply(&m)
            guard var line = try? JSONEncoder().encode(op) else { return }
            line.append(UInt8(ascii: "\n"))
            if handle == nil {
                if !FileManager.default.fileExists(atPath: journal.path) {
                    FileManager.default.createFile(atPath: journal.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                handle = try? FileHandle(forWritingTo: journal)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: line)
        }
    }

    func compact() {
        lock.withLock {
            guard let d = try? JSONEncoder().encode(m) else { return }
            do {
                try d.write(to: base, options: .atomic)
                try? handle?.close()
                handle = nil
                try? FileManager.default.removeItem(at: journal)
            } catch { Log.error("manifest save failed: \(error.localizedDescription)") }
        }
    }
}
