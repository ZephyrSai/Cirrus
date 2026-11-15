import Foundation
import Testing
@testable import CirrusCore

/// The in-process zip extractor that replaces `ditto` on iOS (iCloud Drive packages arrive as zips).
@Suite struct ZipReaderTests {
    func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("cirrus-zip-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A zip made by the system (`ditto -c -k`, deflate) of a package-like folder round-trips byte for byte.
    @Test func extractsDittoArchive() throws {
        let base = tmp()
        let pkg = base.appendingPathComponent("Report.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Data/Sub"), withIntermediateDirectories: true)
        var big = Data()
        for i in 0..<60_000 { big.append(contentsOf: "line \(i) of a compressible document — ünïcödé\n".utf8) }
        var noise = Data(count: 300_000)
        for i in noise.indices { noise[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        try big.write(to: pkg.appendingPathComponent("Index.xml"))
        try noise.write(to: pkg.appendingPathComponent("Data/Sub/preview.bin"))
        try Data().write(to: pkg.appendingPathComponent("Data/empty.txt"))
        let zip = base.appendingPathComponent("pkg.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", pkg.path, zip.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let out = base.appendingPathComponent("out", isDirectory: true)
        let tops = try ZipReader.extract(zip, into: out)
        #expect(tops.map(\.lastPathComponent) == ["Report.pages"])
        let x = out.appendingPathComponent("Report.pages")
        #expect(try Data(contentsOf: x.appendingPathComponent("Index.xml")) == big)
        #expect(try Data(contentsOf: x.appendingPathComponent("Data/Sub/preview.bin")) == noise)
        #expect(try Data(contentsOf: x.appendingPathComponent("Data/empty.txt")).isEmpty)
        // Nothing but the package was written.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["Report.pages"])
    }

    /// Builds a stored (uncompressed) zip with arbitrary entry names and optionally a wrong CRC.
    func storedZip(_ entries: [(String, Data)], badCRC: Bool = false) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        var out = Data(), central = Data()
        for (name, body) in entries {
            var crc = CRC32(); crc.update(body)
            let c = badCRC ? crc.value ^ 1 : crc.value
            let n = Array(name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0) + le32(c)
                       + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(n.count) + le16(0) + n)
            out.append(body)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0) + le32(c)
                           + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        return out
    }

    @Test func refusesPathsOutsideTheDestination() throws {
        for evil in ["../escape.txt", "a/../../escape.txt", "/etc/escape.txt", "C:/escape.txt", "a\\..\\..\\escape.txt"] {
            let base = tmp()
            let zip = base.appendingPathComponent("evil.zip")
            try storedZip([("ok.txt", Data("fine".utf8)), (evil, Data("pwned".utf8))]).write(to: zip)
            let out = base.appendingPathComponent("out/inner", isDirectory: true)
            #expect(throws: (any Error).self) { try ZipReader.extract(zip, into: out) }
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("out/escape.txt").path))
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
        }
    }

    @Test func checksumMismatchLeavesNoFile() throws {
        let base = tmp()
        let zip = base.appendingPathComponent("bad.zip")
        try storedZip([("doc.txt", Data("hello".utf8))], badCRC: true).write(to: zip)
        let out = base.appendingPathComponent("out", isDirectory: true)
        #expect(throws: (any Error).self) { try ZipReader.extract(zip, into: out) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func storedEntriesAndTruncation() throws {
        let base = tmp()
        let zip = base.appendingPathComponent("ok.zip")
        let data = storedZip([("Folder/", Data()), ("Folder/a.txt", Data("alpha".utf8))])
        try data.write(to: zip)
        let out = base.appendingPathComponent("out", isDirectory: true)
        try ZipReader.extract(zip, into: out)
        #expect(try String(contentsOf: out.appendingPathComponent("Folder/a.txt"), encoding: .utf8) == "alpha")
        let cut = base.appendingPathComponent("cut.zip")
        try data.prefix(data.count - 30).write(to: cut)
        #expect(throws: (any Error).self) { try ZipReader.extract(cut, into: base.appendingPathComponent("out2")) }
    }
}
