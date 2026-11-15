import Foundation

/// One photo or video found in a Google Takeout export, with what its JSON sidecar says.
public struct TakeoutItem: Sendable, Hashable {
    public var key: String           // stable across exports: name|taken|size
    public var archive: URL?         // the .zip/.tgz part, or nil for an extracted folder
    public var path: String          // member path in the archive, or the file's full path
    public var fileName: String      // name it gets in iCloud
    public var size: Int64
    public var taken: Date?
    public var caption: String?
    public var latitude: Double?
    public var longitude: Double?
    public var favorite: Bool
    public var albums: [String]
    public var isVideo: Bool
    public var isEdited: Bool
    public var isCompanion: Bool     // the video half of a Live Photo / motion photo
    public var group: String         // a Live Photo's still and video share a group
}

/// Reads Google Photos out of Takeout exports: `.zip` / `.tgz` parts (listed and extracted with
/// macOS's bsdtar, a batch at a time) or a folder the user already extracted.
public final class TakeoutReader: @unchecked Sendable {
    public struct Result: Sendable {
        public var items: [TakeoutItem] = []
        public var skipped: [MigrationEngine.Skipped] = []
        public var warnings: [String] = []
        public var parts = 0
        public var sidecars = 0
        public var withoutSidecar = 0
    }

    struct Entry: Hashable { var archive: URL?; var path: String; var size: Int64 }

    public let inputs: [URL]
    let workDir: URL

    public init(inputs: [URL], workDir: URL) { self.inputs = inputs; self.workDir = workDir }

    static let archiveExts = ["zip", "tgz", "gz", "tar", "tbz", "bz2"]
    public static func isArchive(_ u: URL) -> Bool { archiveExts.contains(u.pathExtension.lowercased()) }

    /// Media types iCloud Photos takes (the same list Cirrus uses for drops), plus Pixel motion-photo videos.
    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "mp", "mv"]
    static let otherMedia: Set<String> = ["avi", "mkv", "3gp", "3g2", "wmv", "mpg", "mpeg", "mts", "m2ts", "asf", "divx", "mod", "tod", "bmp", "ico", "psd", "svg"]
    static let photosFolders = ["google photos", "google fotos", "google foto", "google zdjęcia", "google фото", "google fotky", "google fotók", "google kuvat",
                                "google φωτογραφίες", "google 포토", "google フォト", "google 相册", "google 相簿", "google 相片"]
    static let editedSuffixes = ["-edited", "-bearbeitet", "-modifié", "-editado", "-modificato", "-bewerkt", "-redigerad", "-redigeret", "-muokattu",
                                 "-edytowane", "-upraveno", "-szerkesztett", "-изменено", "-編集済み", "-已修改", "-편집됨"]
    static let specialFolders: Set<String> = ["trash", "bin", "papierkorb", "corbeille", "papelera", "cestino", "prullenbak", "archive", "failed videos"]

    // MARK: Listing

    public func scan(progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        var entries = [Entry]()
        var jsons = [Entry: Data]()
        var result = Result()
        let fm = FileManager.default
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (n, input) in inputs.enumerated() {
            try Task.checkCancellation()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { throw SyncError.unavailable("“\(input.lastPathComponent)” isn’t there any more.") }
            if isDir.boolValue {
                progress("Reading \(input.lastPathComponent)…")
                let e = fm.enumerator(at: input, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])
                while let u = e?.nextObject() as? URL {
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if v?.isDirectory == true { continue }
                    let entry = Entry(archive: nil, path: u.standardizedFileURL.path, size: Int64(v?.fileSize ?? 0))
                    entries.append(entry)
                    if u.pathExtension.lowercased() == "json", (v?.fileSize ?? 0) < 4 << 20 { jsons[entry] = try? Data(contentsOf: u) }
                }
            } else if Self.isArchive(input) {
                result.parts += 1
                progress("Reading \(input.lastPathComponent) (part \(result.parts))…")
                let listed = try await Self.list(input)
                entries += listed
                // Sidecars are small: unpack just those to read them.
                let dir = workDir.appendingPathComponent("index-\(n)", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let r = try await Shell.run("/usr/bin/tar", ["-xf", input.path, "-C", dir.path, "--include", "*.json"])
                if r.status != 0 { Log.status("takeout: json extraction exited \(r.status)") }
                for e in listed where e.path.lowercased().hasSuffix(".json") {
                    jsons[e] = try? Data(contentsOf: dir.appendingPathComponent(e.path))
                }
            } else {
                throw SyncError.unavailable("“\(input.lastPathComponent)” isn’t a Takeout export. Choose the .zip or .tgz files Google sent, or the folder you unpacked them into.")
            }
        }
        progress("Matching photos with their Google details…")
        build(entries: entries, jsons: jsons, into: &result)
        try? fm.removeItem(at: workDir)
        return result
    }

    /// `tar -tv` (C locale) → members with sizes.
    static func list(_ archive: URL) async throws -> [Entry] {
        let r = try await Shell.run("/usr/bin/tar", ["-tvf", archive.path])
        guard r.status == 0 else {
            throw SyncError.unavailable("Couldn’t read “\(archive.lastPathComponent)”. If the download didn’t finish, download that part again from Google Takeout.")
        }
        let re = try! NSRegularExpression(pattern: #"^(\S)\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+[A-Z][a-z]{2}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s(.*)$"#)
        var out = [Entry]()
        for raw in String(decoding: r.out, as: UTF8.self).split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            guard ns.substring(with: m.range(at: 1)) == "-" else { continue }   // files only
            out.append(Entry(archive: archive, path: ns.substring(with: m.range(at: 3)), size: Int64(ns.substring(with: m.range(at: 2))) ?? 0))
        }
        return out
    }

    // MARK: Matching

    struct Sidecar {
        var title: String?
        var taken: Date?
        var caption: String?
        var lat: Double?
        var lon: Double?
        var favorite = false
        var trashed = false
        init?(_ data: Data) {
            guard let j = try? JSON(data: data), case .object = j else { return nil }
            title = j["title"].string ?? j["albumData"]["title"].string   // older album metadata nests it
            if let t = j["photoTakenTime"]["timestamp"].double ?? j["creationTime"]["timestamp"].double, t > 0 { taken = Date(timeIntervalSince1970: t) }
            caption = j["description"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            for g in [j["geoData"], j["geoDataExif"]] {
                if let a = g["latitude"].double, let o = g["longitude"].double, a != 0 || o != 0 { lat = a; lon = o; break }
            }
            favorite = j["favorited"].bool ?? false
            trashed = j["trashed"].bool ?? false
        }
    }

    /// Path inside the export, the same whichever part (or unpacked folder) it came from: sidecars and
    /// Live Photo halves can land in a different part than their photo.
    static func exportPath(_ e: Entry) -> String {
        guard e.archive == nil else { return e.path }
        if let r = e.path.range(of: "/Takeout/") { return String(e.path[e.path.index(after: r.lowerBound)...]) }
        return e.path
    }
    static func folderKey(_ e: Entry) -> String { (exportPath(e) as NSString).deletingLastPathComponent }

    /// Splits "IMG_1234(1).JPG" into ("IMG_1234", "(1)", ".JPG").
    static func splitDuplicate(_ name: String) -> (stem: String, dup: String, ext: String) {
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        var dup = ""
        if stem.hasSuffix(")"), let open = stem.lastIndex(of: "("), stem[stem.index(after: open)..<stem.index(before: stem.endIndex)].allSatisfy(\.isNumber),
           stem.distance(from: open, to: stem.endIndex) > 2 {
            dup = String(stem[open...])
            stem = String(stem[..<open])
        }
        return (stem, dup, ext.isEmpty ? "" : "." + ext)
    }

    static func editedBase(_ stem: String) -> String? {
        for s in editedSuffixes where stem.lowercased().hasSuffix(s) { return String(stem.dropLast(s.count)) }
        return nil
    }

    /// Finds the sidecar for a media file among the folder's JSON names (classic, supplemental-metadata,
    /// truncated at 46–51 characters, and "(n)" duplicates in either position).
    static func sidecarName(for name: String, in jsonNames: Set<String>) -> String? {
        let (stem0, dup, ext) = splitDuplicate(name)
        let stem = editedBase(stem0) ?? stem0
        let full = stem + ext
        let supp = full + ".supplemental-metadata"
        var candidates = [full + dup + ".json", full + ".json" + dup, full + ".supplemental-metadata" + dup + ".json", stem + dup + ".json", supp + ".json"]
        if dup.isEmpty { candidates.append(stem + ".json") }
        for c in candidates where jsonNames.contains(c) { return c }
        let lowered = Dictionary(jsonNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for c in candidates { if let hit = lowered[c.lowercased()] { return hit } }
        // Truncated names: the JSON's stem is a prefix of "<name>.supplemental-metadata" (or of the name itself).
        var best: String?
        for j in jsonNames {
            var s = String(j.dropLast(5))   // ".json"
            var jdup = ""
            if s.hasSuffix(")"), let open = s.lastIndex(of: "("), s[s.index(after: open)..<s.index(before: s.endIndex)].allSatisfy(\.isNumber) {
                jdup = String(s[open...])
                s = String(s[..<open])
            }
            guard jdup == dup, s.count >= 30 else { continue }
            if supp.hasPrefix(s) || full.hasPrefix(s) {
                if best == nil || s.count > best!.count - 5 { best = j }
            }
        }
        return best
    }

    func build(entries: [Entry], jsons: [Entry: Data], into result: inout Result) {
        // Only Google Photos content when the export holds other products too.
        let inPhotos: (Entry) -> Bool
        let isPhotosPath: (Entry) -> Bool = { e in Self.exportPath(e).split(separator: "/").contains { Self.photosFolders.contains($0.lowercased()) } }
        if entries.contains(where: isPhotosPath) { inPhotos = isPhotosPath } else { inPhotos = { _ in true } }

        var folders = [String: [Entry]]()
        for e in entries where inPhotos(e) { folders[Self.folderKey(e), default: []].append(e) }
        var byKey = [String: TakeoutItem]()
        var order = [String]()
        let yearRE = try! NSRegularExpression(pattern: #"(19|20)\d{2}$"#)
        for (_, list) in folders.sorted(by: { $0.key < $1.key }) {
            let folderName = ((Self.exportPath(list[0]) as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let jsonEntries = list.filter { $0.path.lowercased().hasSuffix(".json") }
            let jsonByName = Dictionary(jsonEntries.map { (($0.path as NSString).lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            let names = Set(jsonByName.keys)
            let media = list.filter { e in
                let ext = (e.path as NSString).pathExtension.lowercased()
                return PhotoFormats.importable(URL(fileURLWithPath: e.path)) || Self.videoExts.contains(ext) || Self.otherMedia.contains(ext)
            }
            // Album or year folder? Albums carry a metadata JSON that isn't any photo's sidecar.
            let used = Set(media.compactMap { Self.sidecarName(for: ($0.path as NSString).lastPathComponent, in: names) })
            var albumTitle: String?
            for (name, e) in jsonByName where !used.contains(name) {
                if let d = jsons[e], let s = Sidecar(d), s.taken == nil, let t = s.title, !t.isEmpty { albumTitle = t; break }
            }
            let isYear = yearRE.firstMatch(in: folderName, range: NSRange(location: 0, length: (folderName as NSString).length)) != nil && albumTitle == nil
            let special = Self.specialFolders.contains(folderName.lowercased())
            let album: String? = (special || isYear || Self.photosFolders.contains(folderName.lowercased())) ? nil : (albumTitle ?? folderName)
            // Live Photos: a still and a .MOV with the same stem.
            let stems = Dictionary(grouping: media) { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
            for e in media {
                let name = (e.path as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                if Self.otherMedia.contains(ext) {
                    result.skipped.append(.init(name: name, size: e.size, reason: "iCloud Photos doesn’t accept .\(ext) files"))
                    continue
                }
                let stem = (name as NSString).deletingPathExtension.lowercased()
                let isVideo = Self.videoExts.contains(ext)
                let sibling = (stems[stem] ?? []).first { $0 != e && !Self.videoExts.contains(($0.path as NSString).pathExtension.lowercased()) }
                let isCompanion = isVideo && (sibling != nil || ext == "mp" || ext == "mv")
                var sc: Sidecar?
                if let n = Self.sidecarName(for: name, in: names), let je = jsonByName[n], let d = jsons[je] { sc = Sidecar(d) }
                if sc == nil, isCompanion, let s = sibling, let n = Self.sidecarName(for: (s.path as NSString).lastPathComponent, in: names),
                   let je = jsonByName[n], let d = jsons[je] { sc = Sidecar(d) }
                if sc == nil { result.withoutSidecar += 1 } else { result.sidecars += 1 }
                if sc?.trashed == true { continue }
                let (stem0, _, _) = Self.splitDuplicate(name)
                let edited = Self.editedBase(stem0) != nil
                var fileName = name
                if ext == "mp" || ext == "mv" { fileName = (name as NSString).deletingPathExtension + ".MP4" }
                else if !edited, !isCompanion, let t = sc?.title, (t as NSString).pathExtension.lowercased() == ext, !t.contains("/") { fileName = t }
                let taken = sc?.taken
                let key = "\(edited ? "edited:" : isCompanion ? "video:" : "")\(fileName.lowercased())|\(taken.map { String(Int64($0.timeIntervalSince1970)) } ?? "-")|\(e.size)"
                let group = Self.folderKey(e) + "|" + stem
                if var existing = byKey[key] {
                    if let a = album, !existing.albums.contains(a) { existing.albums.append(a) }
                    existing.favorite = existing.favorite || (sc?.favorite ?? false)
                    byKey[key] = existing
                    continue
                }
                byKey[key] = TakeoutItem(key: key, archive: e.archive, path: e.path, fileName: fileName, size: e.size, taken: taken, caption: sc?.caption,
                                         latitude: sc?.lat, longitude: sc?.lon, favorite: sc?.favorite ?? false, albums: album.map { [$0] } ?? [],
                                         isVideo: isVideo, isEdited: edited, isCompanion: isCompanion, group: group)
                order.append(key)
            }
        }
        result.items = order.compactMap { byKey[$0] }
        if result.items.isEmpty {
            result.warnings.append("No photos or videos were found in this export. Make sure Google Photos was selected in Takeout.")
        } else if result.withoutSidecar > 0 && result.sidecars == 0 {
            result.warnings.append("This export has no JSON details, so dates come from the files themselves.")
        }
    }

    // MARK: Extraction

    /// Unpacks these items (from one archive, or copies loose files) into `dir`. Returns key → file.
    public func extract(_ items: [TakeoutItem], into dir: URL) async throws -> [String: URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = [String: URL]()
        var byArchive = [URL: [TakeoutItem]]()
        for i in items {
            if let a = i.archive { byArchive[a, default: []].append(i); continue }
            // Loose files: a copy (a clone on APFS), so the user's folder is never changed.
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension((i.path as NSString).pathExtension)
            try fm.copyItem(at: URL(fileURLWithPath: i.path), to: dest)
            out[i.key] = dest
        }
        for (archive, list) in byArchive {
            try Task.checkCancellation()
            let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let listFile = dir.appendingPathComponent(UUID().uuidString + ".txt")
            // bsdtar treats names as patterns: escape the pattern characters.
            let names = Set(list.map(\.path)).map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]") }
            try Data(names.joined(separator: "\n").utf8).write(to: listFile)
            defer { try? fm.removeItem(at: listFile) }
            let r = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", sub.path, "-T", listFile.path])
            if r.status != 0 { Log.status("takeout: extraction exited \(r.status)") }
            for i in list {
                let f = sub.appendingPathComponent(i.path)
                if fm.fileExists(atPath: f.path) { out[i.key] = f }
            }
        }
        return out
    }
}

/// Runs a command-line tool off the main thread (C locale, output collected).
enum Shell {
    struct Output { var status: Int32; var out: Data; var err: Data }

    static func run(_ exe: String, _ args: [String]) async throws -> Output {
        #if !os(macOS)
        throw ICloudError.server("Reading Google Takeout archives needs the Mac app.")
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        p.environment = env
        let outPipe = Pipe(), errFile = Paths.tempFile(named: "stderr.txt")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile.deletingLastPathComponent()) }
        p.standardOutput = outPipe
        p.standardError = try FileHandle(forWritingTo: errFile)
        p.standardInput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do { try p.run() } catch { cont.resume(throwing: error); return }
                    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    let err = (try? Data(contentsOf: errFile)) ?? Data()
                    if p.terminationReason == .uncaughtSignal { cont.resume(throwing: CancellationError()); return }
                    cont.resume(returning: Output(status: p.terminationStatus, out: out, err: err))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        #endif
    }
}
