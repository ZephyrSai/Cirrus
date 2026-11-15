#if DEBUG
import Foundation

/// A small synthetic Google Takeout export (Debug builds only) for tests and the demo. It covers the
/// awkward cases: classic and "supplemental-metadata" sidecars, a 51-character truncated sidecar,
/// "(1)" duplicates, an "-edited" copy, a Live Photo (HEIC-style still + MP4), an album that repeats
/// a year-folder photo, a sidecar in a different part than its photo, a trashed item, an
/// unsupported file, a photo with no sidecar, and a non-Photos product folder.
public enum TakeoutFixture {
    public struct Photo { public var name: String; public var folder: String; public var taken: Date }

    static func jpeg(_ label: String, _ hue: Double) -> Data {
        DemoArt.jpeg(width: 480, height: 320, hue: CGFloat(hue), label: label) ?? Data(label.utf8)
    }

    static func sidecar(title: String, taken: Date, description: String = "", favorite: Bool = false, trashed: Bool = false,
                        lat: Double = 0, lon: Double = 0) -> Data {
        var o: [String: Any] = ["title": title, "description": description, "imageViews": "3",
                                "creationTime": ["timestamp": String(Int(taken.timeIntervalSince1970) + 86_400), "formatted": ""],
                                "photoTakenTime": ["timestamp": String(Int(taken.timeIntervalSince1970)), "formatted": ""],
                                "geoData": ["latitude": lat, "longitude": lon, "altitude": 0.0, "latitudeSpan": 0.0, "longitudeSpan": 0.0],
                                "url": "https://photos.google.com/photo/fake", "googlePhotosOrigin": ["mobileUpload": ["deviceType": "IOS_PHONE"]]]
        if favorite { o["favorited"] = true }
        if trashed { o["trashed"] = true }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The date each test photo should end up with.
    public static let dates: [String: Date] = [
        "IMG_0001.JPG": Date(timeIntervalSince1970: 1_683_000_000),   // May 2023
        "IMG_0002.JPG": Date(timeIntervalSince1970: 1_684_000_000),
        "IMG_0003.HEIC": Date(timeIntervalSince1970: 1_685_000_000),
        "IMG_0004.JPG": Date(timeIntervalSince1970: 1_686_000_000),
        "IMG_0004(1).JPG": Date(timeIntervalSince1970: 1_686_500_000),
        "IMG_0005.JPG": Date(timeIntervalSince1970: 1_687_000_000),
        "Screenshot_20230701_a_very_long_camera_file_name.png": Date(timeIntervalSince1970: 1_688_200_000),
        "IMG_0007.JPG": Date(timeIntervalSince1970: 1_717_000_000),   // May 2024
    ]

    /// Writes the export as two .zip parts, two .tgz parts, or a folder. Returns what to choose.
    public static func make(in dir: URL, format: String = "zip") async throws -> [URL] {
        let fm = FileManager.default
        let tree = dir.appendingPathComponent("tree-" + UUID().uuidString.prefix(6), isDirectory: true)
        let y23 = "Takeout/Google Photos/Photos from 2023", y24 = "Takeout/Google Photos/Photos from 2024", album = "Takeout/Google Photos/Lisbon trip"
        var part1 = [(String, Data)](), part2 = [(String, Data)]()
        func d(_ k: String) -> Date { dates[k]! }
        // Classic sidecar, favorite, with place and caption; also in the album.
        let one = jpeg("Tram 28", 0.05)
        part1 += [("\(y23)/IMG_0001.JPG", one), ("\(y23)/IMG_0001.JPG.json", sidecar(title: "IMG_0001.JPG", taken: d("IMG_0001.JPG"), description: "Tram 28", favorite: true, lat: 38.7139, lon: -9.1394))]
        part2 += [("\(album)/IMG_0001.JPG", one), ("\(album)/IMG_0001.JPG.json", sidecar(title: "IMG_0001.JPG", taken: d("IMG_0001.JPG"), description: "Tram 28", favorite: true, lat: 38.7139, lon: -9.1394))]
        // New-style sidecar name.
        part1 += [("\(y23)/IMG_0002.JPG", jpeg("Alfama", 0.15)), ("\(y23)/IMG_0002.JPG.supplemental-metadata.json", sidecar(title: "IMG_0002.JPG", taken: d("IMG_0002.JPG")))]
        // Live Photo: still + MP4 with one sidecar named after the still.
        part1 += [("\(y23)/IMG_0003.HEIC", jpeg("Live", 0.25)), ("\(y23)/IMG_0003.MP4", Data(count: 3000)),
                  ("\(y23)/IMG_0003.HEIC.supplemental-metadata.json", sidecar(title: "IMG_0003.HEIC", taken: d("IMG_0003.HEIC")))]
        // Two different photos called IMG_0004.JPG: "(1)" goes after the extension in the sidecar name.
        part1 += [("\(y23)/IMG_0004.JPG", jpeg("Belém", 0.35)), ("\(y23)/IMG_0004.JPG.json", sidecar(title: "IMG_0004.JPG", taken: d("IMG_0004.JPG"))),
                  ("\(y23)/IMG_0004(1).JPG", jpeg("Belém again", 0.45)), ("\(y23)/IMG_0004.JPG(1).json", sidecar(title: "IMG_0004.JPG", taken: d("IMG_0004(1).JPG")))]
        // An edited copy shares the original's sidecar.
        part1 += [("\(y23)/IMG_0005.JPG", jpeg("Sintra", 0.55)), ("\(y23)/IMG_0005-edited.JPG", jpeg("Sintra (edited)", 0.6)),
                  ("\(y23)/IMG_0005.JPG.json", sidecar(title: "IMG_0005.JPG", taken: d("IMG_0005.JPG")))]
        // Long name: the sidecar name is cut at 51 characters including ".json".
        let long = "Screenshot_20230701_a_very_long_camera_file_name.png"
        let cut = String((long + ".supplemental-metadata").prefix(46)) + ".json"
        part1 += [("\(y23)/\(long)", jpeg("Screenshot", 0.7)), ("\(y23)/\(cut)", sidecar(title: long, taken: d(long)))]
        // Trashed in Google Photos: not copied. Unsupported type: listed as skipped. No sidecar at all.
        part1 += [("\(y23)/IMG_0009.JPG", jpeg("Trashed", 0.8)), ("\(y23)/IMG_0009.JPG.json", sidecar(title: "IMG_0009.JPG", taken: d("IMG_0005.JPG"), trashed: true)),
                  ("\(y23)/clip.avi", Data(count: 2000)), ("\(y23)/NOSIDECAR.PNG", jpeg("No sidecar", 0.9))]
        // Album metadata; a 2024 photo only in the album and its year folder, with the sidecar in the other part.
        part2 += [("\(album)/metadata.json", (try? JSONSerialization.data(withJSONObject: ["title": "Lisbon trip", "description": "", "access": "protected",
                                                                                          "date": ["timestamp": "1683000000", "formatted": ""]])) ?? Data())]
        let seven = jpeg("Miradouro", 0.95)
        part2 += [("\(album)/IMG_0007.JPG", seven), ("\(album)/IMG_0007.JPG.json", sidecar(title: "IMG_0007.JPG", taken: d("IMG_0007.JPG")))]
        part2 += [("\(y24)/IMG_0007.JPG", seven)]
        part1 += [("\(y24)/IMG_0007.JPG.json", sidecar(title: "IMG_0007.JPG", taken: d("IMG_0007.JPG")))]
        // Another product in the same export: never treated as photos.
        part2 += [("Takeout/Drive/holiday.jpg", jpeg("Not a photo export", 0.3))]

        func write(_ files: [(String, Data)], under root: URL) throws {
            for (p, data) in files {
                let u = root.appendingPathComponent(p)
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u)
            }
        }
        if format == "folder" {
            let out = dir.appendingPathComponent("Takeout export", isDirectory: true)
            try write(part1 + part2, under: out)
            return [out]
        }
        var parts = [URL]()
        for (i, files) in [part1, part2].enumerated() {
            let root = tree.appendingPathComponent("p\(i)", isDirectory: true)
            try write(files, under: root)
            let name = String(format: "takeout-20261115T101500Z-%03d.%@", i + 1, format == "tgz" ? "tgz" : "zip")
            let out = dir.appendingPathComponent(name)
            try? fm.removeItem(at: out)
            let r = try await Shell.run("/usr/bin/tar", ["-a", "-cf", out.path, "-C", root.path, "Takeout"])
            guard r.status == 0 else { throw SyncError.unavailable("Couldn’t build the test export: \(String(decoding: r.err, as: UTF8.self))") }
            parts.append(out)
        }
        try? fm.removeItem(at: tree)
        return parts
    }
}
#endif
