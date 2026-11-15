import CoreGraphics
import Foundation

/// iCloud Photos through CloudKit web services (ckdatabasews). Listing logic follows rclone's
/// photos backend; record edits follow icloudpd (soft delete via isDeleted on CPLAsset).
public final class WebPhotos: PhotosBackend, @unchecked Sendable {
    public let session: ICloudSession
    public let cacheKey: String
    public var capabilities: PhotoCapabilities { [.favorite, .hide, .delete, .restore, .importFiles, .albums, .createAlbum] }
    static let pcs = (app: "photos", ws: "ckdatabasews")
    static let pageLimit = 200
    private let lock = NSLock()
    private var libs: [String: PhotoLibraryRef] = [:]
    private var tokens: [String: String] = [:]   // library → latest CloudKit syncToken seen

    func noteToken(_ r: JSON, library: String) {
        if let t = r["syncToken"].string, !t.isEmpty { lock.withLock { tokens[library] = t } }
    }

    public func syncToken(library: PhotoLibraryRef) -> String? { lock.withLock { tokens[library.id] } }

    /// CloudKit change feed: no records since `token` ⇒ every cached listing for the library is current.
    public func hasChanges(since token: String, library: PhotoLibraryRef) async throws -> (changed: Bool, token: String?) {
        let lib = self.resolve(library)
        let body: JSON = ["zones": [["zoneID": zoneID(lib), "syncToken": .string(token), "desiredKeys": ["isDeleted"]]]]
        let r = try await call(lib.area, "changes/zone", body)
        let zone = r["zones"][0]
        let newToken = zone["syncToken"].string
        if let t = newToken { lock.withLock { tokens[library.id] = t } }
        return (!(zone["records"].array.isEmpty && zone["moreComing"].bool != true), newToken)
    }

    public init(session: ICloudSession, appleID: String) {
        self.session = session
        cacheKey = "web-" + appleID.lowercased()
    }

    struct Smart { let key: String; let name: String; let objectType: String; let listType: String; let direction: String; let filter: String?; let symbol: String }

    static let smartAlbums: [Smart] = [
        Smart(key: "All Photos", name: "All Photos", objectType: "CPLAssetByAssetDateWithoutHiddenOrDeleted", listType: "CPLAssetAndMasterByAssetDateWithoutHiddenOrDeleted", direction: "ASCENDING", filter: nil, symbol: "photo.on.rectangle"),
        Smart(key: "Favorites", name: "Favorites", objectType: "CPLAssetInSmartAlbumByAssetDate:Favorite", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "FAVORITE", symbol: "heart"),
        Smart(key: "Videos", name: "Videos", objectType: "CPLAssetInSmartAlbumByAssetDate:Video", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "VIDEO", symbol: "video"),
        Smart(key: "Live", name: "Live Photos", objectType: "CPLAssetInSmartAlbumByAssetDate:Live", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "LIVE", symbol: "livephoto"),
        Smart(key: "Screenshots", name: "Screenshots", objectType: "CPLAssetInSmartAlbumByAssetDate:Screenshot", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "SCREENSHOT", symbol: "camera.viewfinder"),
        Smart(key: "Portrait", name: "Portrait", objectType: "CPLAssetInSmartAlbumByAssetDate:Depth", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "DEPTH", symbol: "cube"),
        Smart(key: "Panoramas", name: "Panoramas", objectType: "CPLAssetInSmartAlbumByAssetDate:Panorama", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "PANORAMA", symbol: "pano"),
        Smart(key: "Slo-mo", name: "Slo-mo", objectType: "CPLAssetInSmartAlbumByAssetDate:Slomo", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "SLOMO", symbol: "slowmo"),
        Smart(key: "Time-lapse", name: "Time-lapse", objectType: "CPLAssetInSmartAlbumByAssetDate:Timelapse", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "TIMELAPSE", symbol: "timelapse"),
        Smart(key: "Long Exposure", name: "Long Exposure", objectType: "CPLAssetInSmartAlbumByAssetDate:Exposure", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "EXPOSURE", symbol: "plusminus.circle"),
        Smart(key: "Animated", name: "Animated", objectType: "CPLAssetInSmartAlbumByAssetDate:Animated", listType: "CPLAssetAndMasterInSmartAlbumByAssetDate", direction: "ASCENDING", filter: "ANIMATED", symbol: "square.stack.3d.forward.dottedline"),
        Smart(key: "Bursts", name: "Bursts", objectType: "CPLAssetBurstStackAssetByAssetDate", listType: "CPLBurstStackAssetAndMasterByAssetDate", direction: "ASCENDING", filter: nil, symbol: "square.stack.3d.down.right"),
        Smart(key: "Hidden", name: "Hidden", objectType: "CPLAssetHiddenByAssetDate", listType: "CPLAssetAndMasterHiddenByAssetDate", direction: "ASCENDING", filter: nil, symbol: "eye.slash"),
        Smart(key: "Recently Deleted", name: "Recently Deleted", objectType: "CPLAssetDeletedByExpungedDate", listType: "CPLAssetAndMasterDeletedByExpungedDate", direction: "DESCENDING", filter: nil, symbol: "trash"),
    ]

    static let desiredKeys: [JSON] = [
        "resOriginalRes", "resOriginalVidComplRes", "resOriginalFileType", "resOriginalWidth", "resOriginalHeight",
        "resOriginalAltRes", "resOriginalAltFileType", "resJPEGThumbRes", "resJPEGMedRes", "resJPEGThumbFileType",
        "filenameEnc", "itemType", "assetDate", "addedDate", "masterRef", "isFavorite", "isHidden", "isDeleted",
        "assetSubtype", "assetSubtypeV2", "burstId", "adjustmentRenderType", "adjustmentType", "duration",
        "resJPEGFullRes", "resJPEGFullFileType", "resVidFullRes", "resVidFullFileType", "resVidSmallRes",
    ]

    func endpoint(_ area: String, _ op: String) async throws -> String {
        guard let base = await session.webserviceURL("ckdatabasews") else { throw ICloudError.serviceUnavailable("iCloud Photos") }
        return "\(base)/database/1/com.apple.photos.cloud/production/\(area)/\(op)"
    }

    func call(_ area: String, _ op: String, _ body: JSON, idempotent: Bool = true) async throws -> JSON {
        try await session.request(try await endpoint(area, op), query: ["remapEnums": "true", "getCurrentSyncToken": "true"],
                                  json: body, contentType: "text/plain", pcs: Self.pcs, idempotent: idempotent)
    }

    func zoneID(_ lib: PhotoLibraryRef) -> JSON {
        var z: [String: JSON] = ["zoneName": .string(lib.id)]
        if let o = lib.ownerRecordName { z["ownerRecordName"] = .string(o) }
        if let t = lib.zoneType { z["zoneType"] = .string(t) }
        return .object(z)
    }

    func library(_ id: String) -> PhotoLibraryRef {
        lock.lock(); defer { lock.unlock() }
        return libs[id] ?? PhotoLibraryRef(id: id, name: id, isShared: id != "PrimarySync")
    }

    /// The registered library, or the caller's own ref (which carries its database and zone owner).
    func resolve(_ ref: PhotoLibraryRef) -> PhotoLibraryRef {
        lock.withLock { libs[ref.id] ?? ref }
    }

    private var partialDiscovery = false
    public func librariesComplete() -> Bool { lock.withLock { !partialDiscovery } }
    public func remember(_ libraries: [PhotoLibraryRef]) {
        lock.withLock { for l in libraries where libs[l.id] == nil { libs[l.id] = l } }
    }

    // MARK: Libraries & albums

    public func libraries() async throws -> [PhotoLibraryRef] {
        // Private and shared databases in parallel; the shared one is optional and gets a short leash.
        async let privateZones = call("private", "changes/database", [:])
        let sharedTask = Task { () -> JSON? in try? await withThrowingTaskGroup(of: JSON?.self) { g in
            g.addTask { try await self.call("shared", "changes/database", [:]) }
            g.addTask { try await Task.sleep(nanoseconds: 6_000_000_000); return nil }
            let r = try await g.next() ?? nil
            g.cancelAll()
            return r
        } }
        let priv = try await privateZones
        let shared = await sharedTask.value
        var found = [PhotoLibraryRef]()
        for (area, r) in [("private", priv), ("shared", shared ?? .null)] {
            for z in r["zones"].array where z["deleted"].bool != true {
                let name = z["zoneID"]["zoneName"].string ?? ""
                guard name == "PrimarySync" || name.hasPrefix("SharedSync"), !found.contains(where: { $0.id == name }) else { continue }
                var lib = PhotoLibraryRef(id: name, name: name == "PrimarySync" ? "Personal Library" : "Shared Library", isShared: name != "PrimarySync")
                lib.area = area
                lib.ownerRecordName = z["zoneID"]["ownerRecordName"].string
                lib.zoneType = z["zoneID"]["zoneType"].string
                found.append(lib)
            }
        }
        if found.isEmpty { found = [PhotoLibraryRef(id: "PrimarySync", name: "Personal Library", isShared: false)] }
        // The Shared Library didn't answer in time: keep any we already know rather than dropping it.
        let partial = shared == nil
        if partial {
            let known = lock.withLock { libs.values.filter { $0.isShared } }
            for l in known where !found.contains(where: { $0.id == l.id }) { found.append(l) }
        }
        found.sort { !$0.isShared && $1.isShared }
        lock.withLock { for l in found { libs[l.id] = l }; partialDiscovery = partial }
        return found
    }

    public func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] {
        var albums = Self.smartAlbums.map { PhotoAlbum(id: "smart:" + $0.key, name: $0.name, kind: .smart, symbol: $0.symbol) }
        var marker: String?
        var records = [JSON]()
        repeat {
            var q: [String: JSON] = ["query": ["recordType": "CPLAlbumByPositionLive"], "zoneID": zoneID(library),
                                     "desiredKeys": ["albumNameEnc", "albumType", "parentId", "isDeleted"]]
            if let m = marker { q["continuationMarker"] = .string(m) }
            let r: JSON
            do { r = try await call(library.area, "records/query", .object(q)) } catch {
                if library.isShared { break } // shared libraries have no album index
                throw error
            }
            records += r["records"].array
            marker = r["continuationMarker"].string
        } while marker != nil
        for rec in records {
            let f = rec["fields"]
            guard let name = rec["recordName"].string, name != "----Root-Folder----", name != "----Project-Root-Folder----",
                  f["isDeleted"]["value"].bool != true, let enc = f["albumNameEnc"]["value"].string else { continue }
            let title = (Data(base64Encoded: enc).flatMap { String(data: $0, encoding: .utf8) } ?? enc).precomposedStringWithCanonicalMapping
            let isFolder = f["albumType"]["value"].int == 3
            var parent = f["parentId"]["value"].string
            if parent == "----Root-Folder----" { parent = nil }
            albums.append(PhotoAlbum(id: (isFolder ? "folder:" : "album:") + name, name: title, kind: isFolder ? .folder : .album,
                                     parentID: parent.map { "folder:" + $0 }, symbol: isFolder ? "folder" : "rectangle.stack"))
        }
        // Counts in one batch.
        let countable = albums.filter { $0.kind != .folder }
        let batch = JSON.array(countable.map { countQuery(objectType(for: $0), library) })
        if let r = try? await call(library.area, "internal/records/query/batch", ["batch": batch]) {
            for (i, a) in countable.enumerated() {
                if let n = r["batch"][i]["records"][0]["fields"]["itemCount"]["value"].int, let idx = albums.firstIndex(of: a) { albums[idx].count = n }
            }
        }
        return albums
    }

    func countQuery(_ objectType: String, _ lib: PhotoLibraryRef) -> JSON {
        ["resultsLimit": 1, "zoneWide": true, "zoneID": zoneID(lib),
         "query": ["recordType": "HyperionIndexCountLookup",
                   "filterBy": ["fieldName": "indexCountID", "comparator": "IN", "fieldValue": ["type": "STRING_LIST", "value": [.string(objectType)]]]]]
    }

    func objectType(for album: PhotoAlbum) -> String {
        if album.kind == .smart, let s = Self.smartAlbums.first(where: { "smart:" + $0.key == album.id }) { return s.objectType }
        return "CPLContainerRelationNotDeletedByAssetDate:" + album.id.replacingOccurrences(of: "album:", with: "")
    }

    func listQuery(_ album: PhotoAlbum, lib: PhotoLibraryRef, startRank: Int) -> JSON {
        var listType = "CPLContainerRelationLiveByAssetDate"
        var direction = "ASCENDING"
        var filters: [JSON] = []
        if album.kind == .smart, let s = Self.smartAlbums.first(where: { "smart:" + $0.key == album.id }) {
            listType = s.listType
            direction = s.direction
            if let f = s.filter { filters.append(["fieldName": "smartAlbum", "comparator": "EQUALS", "fieldValue": ["type": "STRING", "value": .string(f)]]) }
        } else {
            filters.append(["fieldName": "parentId", "comparator": "EQUALS",
                            "fieldValue": ["type": "STRING", "value": .string(album.id.replacingOccurrences(of: "album:", with: ""))]])
        }
        let all: [JSON] = [["fieldName": "startRank", "comparator": "EQUALS", "fieldValue": ["type": "INT64", "value": .int(startRank)]],
                           ["fieldName": "direction", "comparator": "EQUALS", "fieldValue": ["type": "STRING", "value": .string(direction)]]] + filters
        return ["query": ["recordType": .string(listType), "filterBy": .array(all)], "resultsLimit": .int(Self.pageLimit),
                "desiredKeys": .array(Self.desiredKeys), "zoneID": zoneID(lib)]
    }

    // MARK: Assets

    public func assets(in album: PhotoAlbum, library: PhotoLibraryRef,
                       page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        guard album.kind != .folder else { return [] }
        let lib = self.resolve(library)
        var total = album.count
        if total == nil {
            let r = try? await call(lib.area, "records/query", countQuery(objectType(for: album), lib))
            total = r?["records"][0]["fields"]["itemCount"]["value"].int
        }
        // Partitions of 100 assets each (a full page always holds >= 100 assets), fetched in
        // parallel from the newest end, de-duplicated by asset record name.
        let stride = Self.pageLimit / 2
        let partitions = max(1, ((total ?? 0) + stride - 1) / stride)
        var results = [Int: [PhotoAsset]]()
        var lastFull = false
        try await withThrowingTaskGroup(of: (Int, [PhotoAsset], Int).self) { group in
            var next = partitions - 1
            var inFlight = 0
            func launch() {
                let idx = next
                next -= 1
                inFlight += 1
                group.addTask {
                    let r = try await self.call(lib.area, "records/query", self.listQuery(album, lib: lib, startRank: idx * stride))
                    self.noteToken(r, library: lib.id)
                    let recs = r["records"].array
                    return (idx, Self.parse(recs, library: lib.id), recs.count)
                }
            }
            while next >= 0 && inFlight < 6 { launch() }
            while let (idx, batch, recCount) = try await group.next() {
                inFlight -= 1
                results[idx] = batch
                if idx == partitions - 1 { lastFull = recCount >= Self.pageLimit }
                page(batch, total)
                while next >= 0 && inFlight < 6 { launch() }
            }
        }
        // Tail pages if the count was stale.
        var rank = partitions * stride
        var more = lastFull || total == nil
        var tailIndex = partitions
        while more {
            try Task.checkCancellation()
            let r = try await call(lib.area, "records/query", listQuery(album, lib: lib, startRank: rank))
            let recs = r["records"].array
            let batch = Self.parse(recs, library: lib.id)
            results[tailIndex] = batch
            if !batch.isEmpty { page(batch, nil) }
            more = recs.count >= Self.pageLimit && !batch.isEmpty
            rank += stride
            tailIndex += 1
        }
        var seen = Set<String>()
        var out = [PhotoAsset]()
        for k in results.keys.sorted() {
            for a in results[k]! where seen.insert(a.id).inserted { out.append(a) }
        }
        return out
    }

    static func parse(_ records: [JSON], library: String) -> [PhotoAsset] {
        var masters = [String: JSON]()
        var assets = [JSON]()
        for r in records {
            switch r["recordType"].string {
            case "CPLMaster": if let n = r["recordName"].string { masters[n] = r }
            case "CPLAsset": assets.append(r)
            default: break
            }
        }
        return assets.compactMap { a in
            guard let mid = a["fields"]["masterRef"]["value"]["recordName"].string, let m = masters[mid] else { return nil }
            return build(master: m, asset: a, library: library)
        }
    }

    static func build(master m: JSON, asset a: JSON, library: String) -> PhotoAsset? {
        let mf = m["fields"], af = a["fields"]
        guard let assetID = a["recordName"].string, let masterID = m["recordName"].string else { return nil }
        var filename = ""
        let fe = mf["filenameEnc"]
        if let v = fe["value"].string {
            filename = fe["type"].string == "STRING" ? v : (Data(base64Encoded: v).flatMap { String(data: $0, encoding: .utf8) } ?? v)
        }
        let uti = mf["resOriginalFileType"]["value"].string ?? mf["itemType"]["value"].string
        if filename.isEmpty { filename = masterID + "." + (uti.flatMap { PhotoFormats.utiExtensions[$0] } ?? "jpg") }
        filename = Paths.safeName(filename.precomposedStringWithCanonicalMapping)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        func res(_ fields: JSON, _ key: String, _ kind: PhotoResource.Kind, _ owner: String, name: String, utiKey: String? = nil) -> PhotoResource? {
            let v = fields[key]["value"]
            guard let url = v["downloadURL"].string else { return nil }
            return PhotoResource(kind: kind, filename: name, size: v["size"].int64 ?? 0, key: key, recordName: owner, url: url,
                                 uti: utiKey.flatMap { fields[$0]["value"].string })
        }
        var resources = [PhotoResource]()
        guard let original = res(mf, "resOriginalRes", .original, masterID, name: filename, utiKey: "resOriginalFileType") else { return nil }
        resources.append(original)
        if let live = res(mf, "resOriginalVidComplRes", .liveVideo, masterID, name: stem + ".MOV") { resources.append(live) }
        let adjustment = af["adjustmentType"]["value"].string ?? ""
        if !adjustment.isEmpty && adjustment != "com.apple.video.slomo" {
            if let e = res(af, "resJPEGFullRes", .edited, assetID, name: "", utiKey: "resJPEGFullFileType") ?? res(af, "resVidFullRes", .edited, assetID, name: "", utiKey: "resVidFullFileType") {
                var ed = e
                let eext = ed.uti.flatMap { PhotoFormats.utiExtensions[$0] } ?? ext
                ed.filename = stem + "-edited." + eext
                resources.append(ed)
            }
        }
        if var alt = res(mf, "resOriginalAltRes", .alternate, masterID, name: "", utiKey: "resOriginalAltFileType") {
            let aext = alt.uti.flatMap { PhotoFormats.utiExtensions[$0] } ?? "dng"
            alt.filename = aext.lowercased() == ext.lowercased() ? stem + "-alt." + aext : stem + "." + aext
            resources.append(alt)
        }
        if let t = res(mf, "resJPEGThumbRes", .thumbnail, masterID, name: stem + "-thumb.jpg") { resources.append(t) }
        if let t = res(mf, "resJPEGMedRes", .medium, masterID, name: stem + "-medium.jpg") { resources.append(t) }
        let isVideo = uti.map { PhotoFormats.videoUTIs.contains($0) } ?? false
        return PhotoAsset(id: assetID, masterID: masterID, changeTag: a["recordChangeTag"].string, library: library, filename: filename,
                          size: original.size, created: af["assetDate"]["value"].date, added: af["addedDate"]["value"].date,
                          width: mf["resOriginalWidth"]["value"].int ?? 0, height: mf["resOriginalHeight"]["value"].int ?? 0,
                          duration: af["duration"]["value"].double, isVideo: isVideo, isLive: resources.contains { $0.kind == .liveVideo },
                          isFavorite: af["isFavorite"]["value"].int == 1, isHidden: af["isHidden"]["value"].int == 1,
                          isDeleted: af["isDeleted"]["value"].int == 1, isEdited: resources.contains { $0.kind == .edited },
                          uti: uti, resources: resources)
    }

    // MARK: Content

    func freshURL(_ r: PhotoResource, library: String) async throws -> String {
        let lib = self.library(library)
        let resp = try await call(lib.area, "records/lookup", ["records": [["recordName": .string(r.recordName)]], "zoneID": zoneID(lib)])
        guard let url = resp["records"][0]["fields"][r.key]["value"]["downloadURL"].string else { throw ICloudError.notFound }
        return url
    }

    func fetch(_ r: PhotoResource, library: String, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if let url = r.url {
            do { try await session.download(from: url, to: dest, expectedSize: r.size, progress: progress); return } catch let ICloudError.http(code, _) where [401, 403, 404, 410].contains(code) {}
        }
        try await session.download(from: try await freshURL(r, library: library), to: dest, expectedSize: r.size, progress: progress)
    }

    public func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? {
        let kind: PhotoResource.Kind = maxPixel > 400 ? .medium : .thumbnail
        let px = kind == .medium ? 1024 : 360
        if let d = ThumbnailDiskCache.read(cacheKey, asset.id, px) { return PhotoFormats.cgImage(from: d, maxPixel: maxPixel) }
        // No medium rendition (common for uploads): use the original for big previews when it's small enough.
        var r = asset.resource(kind)
        if r == nil, kind == .medium, let o = asset.resource(.original), o.size > 0, o.size <= 20_000_000, !asset.isVideo { r = o }
        guard let r = r ?? asset.resource(.thumbnail) else { return nil }
        let tmp = Paths.tempFile(named: "t.jpg")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        try await fetch(r, library: asset.library, to: tmp) { _, _ in }
        guard var data = try? Data(contentsOf: tmp) else { return nil }
        if r.kind == .original, let cg = PhotoFormats.cgImage(from: data, maxPixel: px), let jpeg = PhotoFormats.jpeg(cg) { data = jpeg }
        ThumbnailDiskCache.write(data, cacheKey, asset.id, px)
        return PhotoFormats.cgImage(from: data, maxPixel: maxPixel)
    }

    public func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let r = asset.resource(resource) else { throw ICloudError.notFound }
        try await fetch(r, library: asset.library, to: destination, progress: progress)
        if let d = asset.created {
            try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: destination.path)
        }
    }

    // MARK: Edits

    func modifyAssets(_ assets: [PhotoAsset], fields: [String: JSON]) async throws -> [PhotoAsset] {
        var updated = assets
        for (libID, group) in Dictionary(grouping: assets.indices, by: { assets[$0].library }) {
            let lib = library(libID)
            for chunk in group.chunked(100) {
                let ops = JSON.array(chunk.map { i in
                    ["operationType": "update",
                     "record": ["recordName": .string(assets[i].id), "recordType": "CPLAsset", "recordChangeTag": .string(assets[i].changeTag ?? ""),
                                "fields": .object(fields.mapValues { ["value": $0] })]]
                })
                let r = try await call(lib.area, "records/modify", ["atomic": false, "operations": ops, "zoneID": zoneID(lib),
                                                                     "desiredKeys": .array(fields.keys.map { .string($0) })], idempotent: false)
                for rec in r["records"].array {
                    if let reason = rec["reason"].string ?? rec["serverErrorCode"].string {
                        throw ICloudError.server("iCloud Photos refused the change: \(reason)")
                    }
                    if let name = rec["recordName"].string, let i = chunk.first(where: { assets[$0].id == name }) {
                        updated[i].changeTag = rec["recordChangeTag"].string ?? updated[i].changeTag
                        if let v = fields["isFavorite"]?.int { updated[i].isFavorite = v == 1 }
                        if let v = fields["isHidden"]?.int { updated[i].isHidden = v == 1 }
                        if let v = fields["isDeleted"]?.int { updated[i].isDeleted = v == 1 }
                    }
                }
            }
        }
        return updated
    }

    public func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        try SafetyPolicy.checkWrite()
        return try await modifyAssets(assets, fields: ["isFavorite": .int(value ? 1 : 0)])
    }

    public func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] {
        try SafetyPolicy.checkWrite()
        return try await modifyAssets(assets, fields: ["isHidden": .int(value ? 1 : 0)])
    }

    /// Moves to Recently Deleted (recoverable for 30 days), like icloudpd's delete.
    public func delete(_ assets: [PhotoAsset]) async throws { try SafetyPolicy.checkWrite(); _ = try await modifyAssets(assets, fields: ["isDeleted": .int(1)]) }

    public func restore(_ assets: [PhotoAsset]) async throws { try SafetyPolicy.checkWrite(); _ = try await modifyAssets(assets, fields: ["isDeleted": .int(0)]) }

    public func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef,
                            progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let created = try await importReturningIDs(files, library: library, progress: progress)
        if let album, album.kind == .album, !created.isEmpty {
            let fake = created.map { PhotoAsset(id: $0, library: library.id, filename: "", size: 0, width: 0, height: 0, isVideo: false, isLive: false, isFavorite: false, isHidden: false, resources: []) }
            try await add(fake, to: album, library: library)
        }
    }

    public func importReturningIDs(_ files: [URL], library: PhotoLibraryRef, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> [String] {
        try SafetyPolicy.checkWrite()
        guard let base = await session.webserviceURL("uploadimagews"), let dsid = await session.dsid else {
            throw ICloudError.serviceUnavailable("iCloud Photos upload")
        }
        try await session.ensurePCS(app: "photos", webservice: "ckdatabasews")
        var created = [String]()
        for file in files {
            let mod = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            let r = try await session.upload(to: base + "/upload", query: ["filename": file.lastPathComponent, "dsid": dsid,
                                                                             "lastModDate": String(Int64(mod.timeIntervalSince1970 * 1000)),
                                                                             "timezoneOffset": String(TimeZone.current.secondsFromGMT() / 60)],
                                             file: file, multipartName: nil, contentType: "application/octet-stream", progress: progress)
            if let err = r["errors"][0]["errorMessage"].string ?? r["errors"][0]["message"].string { throw ICloudError.server(err) }
            created += r["records"].array.filter { $0["recordType"].string == "CPLAsset" }.compactMap { $0["recordName"].string }
        }
        return created
    }

    public func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws {
        try SafetyPolicy.checkWrite()
        guard album.kind == .album else { throw ICloudError.server("Photos can only be added to regular albums.") }
        let lib = self.resolve(library)
        let albumRecord = album.id.replacingOccurrences(of: "album:", with: "")
        for chunk in assets.chunked(100) {
            let ops = JSON.array(chunk.enumerated().map { i, a in
                ["operationType": "create",
                 "record": ["recordName": .string("\(a.id)-IN-\(albumRecord)"), "recordType": "CPLContainerRelation",
                            "fields": ["itemId": ["value": .string(a.id)], "containerId": ["value": .string(albumRecord)],
                                       "position": ["value": .int(1024 * (i + 1))]]]]
            })
            let r = try await call(lib.area, "records/modify", ["atomic": false, "operations": ops, "zoneID": zoneID(lib)], idempotent: false)
            for rec in r["records"].array {
                if let code = rec["serverErrorCode"].string, code != "CONFLICT" {
                    throw ICloudError.server("Couldn’t add to album: \(rec["reason"].string ?? code)")
                }
            }
        }
    }

    public func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum {
        try SafetyPolicy.checkWrite()
        let lib = self.resolve(library)
        let record = UUID().uuidString.uppercased()
        let op: JSON = ["operationType": "create",
                        "record": ["recordName": .string(record), "recordType": "CPLAlbum",
                                   "fields": ["albumNameEnc": ["value": .string(Data(name.utf8).base64EncodedString()), "type": "ENCRYPTED_BYTES"],
                                              "albumType": ["value": 0], "position": ["value": .int(Int(Date().timeIntervalSince1970))],
                                              "parentId": ["value": "----Root-Folder----"], "sortAscending": ["value": 1], "sortType": ["value": 0]]]]
        let r = try await call(lib.area, "records/modify", ["atomic": true, "operations": [op], "zoneID": zoneID(lib)], idempotent: false)
        if let reason = r["records"][0]["reason"].string { throw ICloudError.server("Couldn’t create album: \(reason)") }
        return PhotoAlbum(id: "album:" + record, name: name, kind: .album, count: 0)
    }
}

public extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
