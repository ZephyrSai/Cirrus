import Compression
import Foundation

/// In-process zip extraction (stored and deflate entries, ZIP64), for platforms without `/usr/bin/ditto`.
/// iCloud Drive delivers packages (Pages, Keynote, Numbers bundles…) as a zip of the bundle.
///
/// Safety: entries are written only inside the destination folder. Absolute paths, `..` components,
/// symbolic links and encrypted entries are refused, and every file's CRC-32 and size are checked.
public enum ZipReader {
    public struct ZipError: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    struct Entry {
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
        var isDirectory: Bool { name.hasSuffix("/") }
        var isSymlink: Bool { (externalAttributes >> 16) & 0o170000 == 0o120000 }
    }

    /// Expands `zip` into `directory` (created if needed). Returns the top-level items written.
    @discardableResult
    public static func extract(_ zip: URL, into directory: URL) throws -> [URL] {
        let fh = try FileHandle(forReadingFrom: zip)
        defer { try? fh.close() }
        let entries = try centralDirectory(fh)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Resolved once; targets are built from it with validated relative paths (no "..", not absolute), so
        // they can only land inside. (standardizedFileURL isn't used: it rewrites /private/… only for paths
        // that exist, which made the prefix comparison inconsistent.)
        let root = directory.resolvingSymlinksInPath()
        let base = root.path
        var tops = [String: URL]()
        // Check every entry before writing anything, so a bad archive leaves nothing behind.
        var plan = [(entry: Entry, target: URL)]()
        for e in entries {
            guard let rel = safeRelativePath(e.name) else { throw ZipError(message: "The archive contains an unsafe path.") }
            if e.flags & 0x1 != 0 { throw ZipError(message: "The archive is encrypted.") }
            if e.isSymlink { continue }
            let target = root.appendingPathComponent(rel)
            guard target.path.hasPrefix(base + "/"), !target.pathComponents.contains("..") else {
                throw ZipError(message: "The archive contains an unsafe path.")
            }
            if let first = rel.split(separator: "/").first { tops[String(first)] = directory.appendingPathComponent(String(first)) }
            plan.append((e, target))
        }
        // Declared sizes are enforced while writing; refuse up front when they can't fit at all.
        let needed = plan.reduce(UInt64(0)) { $0 &+ $1.entry.size }
        if let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map({ UInt64(max(0, $0)) }),
           needed > free {
            throw ZipError(message: "Not enough space to unpack the archive (\(Int64(clamping: needed).byteString) needed).")
        }
        for (e, target) in plan {
            if e.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(e, from: fh, to: target)
        }
        return tops.keys.sorted().compactMap { tops[$0] }
    }

    /// Rejects absolute paths, drive letters, backslash tricks and `..`; drops `.` and empty components.
    static func safeRelativePath(_ raw: String) -> String? {
        let s = raw.replacingOccurrences(of: "\\", with: "/")
        if s.hasPrefix("/") || s.contains("\0") { return nil }
        var parts = [String]()
        for c in s.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { return nil }
            if parts.isEmpty, c.count == 2, c.hasSuffix(":") { return nil }
            parts.append(String(c))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/") + (s.hasSuffix("/") ? "/" : "")
    }

    // MARK: - Reading the archive

    static func readExactly(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try fh.seek(toOffset: offset)
        let d = try fh.read(upToCount: count) ?? Data()
        guard d.count == count else { throw ZipError(message: "The archive is truncated.") }
        return d
    }

    static func centralDirectory(_ fh: FileHandle) throws -> [Entry] {
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw ZipError(message: "Not a zip archive.") }
        // End of central directory: within the last 64 KiB + 22 bytes (comment).
        let tailLen = Int(min(fileSize, 65_557))
        let tail = try readExactly(fh, at: fileSize - UInt64(tailLen), count: tailLen)
        guard let eocdIndex = lastIndex(of: 0x06054b50, in: tail) else { throw ZipError(message: "Not a zip archive.") }
        var count = UInt64(tail.u16(eocdIndex + 10))
        var cdSize = UInt64(tail.u32(eocdIndex + 12))
        var cdOffset = UInt64(tail.u32(eocdIndex + 16))
        // ZIP64 end of central directory locator sits right before the EOCD.
        if (count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF), eocdIndex >= 20, tail.u32(eocdIndex - 20) == 0x07064b50 {
            let z64Offset = tail.u64(eocdIndex - 20 + 8)
            let rec = try readExactly(fh, at: z64Offset, count: 56)
            guard rec.u32(0) == 0x06064b50 else { throw ZipError(message: "The archive's ZIP64 directory is damaged.") }
            count = rec.u64(32)
            cdSize = rec.u64(40)
            cdOffset = rec.u64(48)
        }
        guard cdSize <= fileSize, cdOffset <= fileSize - cdSize, cdSize < 1 << 31 else { throw ZipError(message: "The archive's directory is damaged.") }
        let cd = try readExactly(fh, at: cdOffset, count: Int(cdSize))
        var entries = [Entry]()
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x02014b50 else { throw ZipError(message: "The archive's directory is damaged.") }
            let flags = cd.u16(p + 8), method = cd.u16(p + 10), crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20)), usize = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            let ext = cd.u32(p + 38)
            var offset = UInt64(cd.u32(p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw ZipError(message: "The archive's directory is damaged.") }
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // ZIP64 extra field (0x0001): only the fields that overflowed are present, in this order.
            var x = p + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = cd.u16(x), len = Int(cd.u16(x + 2))
                guard x + 4 + len <= xEnd else { throw ZipError(message: "The archive's directory is damaged.") }
                if id == 0x0001 {
                    var q = x + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= x + 4 + len { usize = cd.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= x + 4 + len { csize = cd.u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= x + 4 + len { offset = cd.u64(q); q += 8 }
                }
                x += 4 + len
            }
            entries.append(Entry(name: name.precomposedStringWithCanonicalMapping, method: method, flags: flags, crc: crc,
                                 compressedSize: csize, size: usize, localHeaderOffset: offset, externalAttributes: ext))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    static func lastIndex(of signature: UInt32, in d: Data) -> Int? {
        var i = d.count - 22
        while i >= 0 {
            if d.u32(i) == signature { return i }
            i -= 1
        }
        return nil
    }

    static func write(_ e: Entry, from fh: FileHandle, to target: URL) throws {
        let local = try readExactly(fh, at: e.localHeaderOffset, count: 30)
        guard local.u32(0) == 0x04034b50 else { throw ZipError(message: "The archive is damaged.") }
        let dataStart = e.localHeaderOffset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28))
        let part = target.deletingLastPathComponent().appendingPathComponent(".cirrus-unzip-" + UUID().uuidString.prefix(8))
        FileManager.default.createFile(atPath: part.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: part)
            var crc = CRC32()
            var written: UInt64 = 0
            func emit(_ chunk: Data) throws {
                crc.update(chunk)
                written += UInt64(chunk.count)
                if written > e.size { throw ZipError(message: "The archive is damaged (an entry is larger than stated).") }
                try out.write(contentsOf: chunk)
            }
            do {
                try fh.seek(toOffset: dataStart)
                switch e.method {
                case 0:
                    var left = e.compressedSize
                    while left > 0 {
                        let n = Int(min(left, 4 << 20))
                        guard let chunk = try fh.read(upToCount: n), chunk.count == n else { throw ZipError(message: "The archive is truncated.") }
                        try emit(chunk)
                        left -= UInt64(n)
                    }
                case 8:
                    try inflate(fh, compressedSize: e.compressedSize, emit: emit)
                default:
                    throw ZipError(message: "The archive uses an unsupported compression method (\(e.method)).")
                }
                try out.close()
            } catch { try? out.close(); throw error }
            guard written == e.size, crc.value == e.crc else { throw ZipError(message: "The archive is damaged (checksum mismatch).") }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    /// Raw DEFLATE (what zip stores) through the Compression framework, streamed in 1 MiB pieces.
    static func inflate(_ fh: FileHandle, compressedSize: UInt64, emit: (Data) throws -> Void) throws {
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError(message: "Couldn't start decompressing.")
        }
        defer { compression_stream_destroy(&stream) }
        var left = compressedSize
        var finished = false
        while !finished {
            let n = Int(min(left, 1 << 20))
            let input = n > 0 ? (try fh.read(upToCount: n) ?? Data()) : Data()
            if n > 0 && input.count != n { throw ZipError(message: "The archive is truncated.") }
            left -= UInt64(input.count)
            let flags = left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var progressed = false
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                stream.src_size = input.count
                while true {
                    stream.dst_ptr = dst
                    stream.dst_size = 1 << 20
                    let status = compression_stream_process(&stream, flags)
                    let produced = (1 << 20) - stream.dst_size
                    if produced > 0 { progressed = true; try emit(Data(bytes: dst, count: produced)) }
                    if status == COMPRESSION_STATUS_END { finished = true; break }
                    guard status == COMPRESSION_STATUS_OK else { throw ZipError(message: "The archive is damaged (bad compressed data).") }
                    // The decoder hands out buffered output in pieces even after the input is used up:
                    // keep going while it still produces something or has input left.
                    if stream.src_size == 0 && produced == 0 { break }
                }
            }
            if !finished && left == 0 && input.isEmpty && !progressed { throw ZipError(message: "The archive is truncated.") }
        }
    }
}

struct CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private var c: UInt32 = 0xFFFF_FFFF
    mutating func update(_ d: Data) {
        var v = c
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for byte in b { v = Self.table[Int((v ^ UInt32(byte)) & 0xFF)] ^ (v >> 8) }
        }
        c = v
    }
    var value: UInt32 { c ^ 0xFFFF_FFFF }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
