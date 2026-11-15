import CirrusCore
import CoreGraphics
import Foundation

/// Presents a hand-picked set of photos as one album, so the engine's `PhotoExporter` (YYYY/MM layout,
/// Live .MOV, edits, RAW, incremental manifest) can export just a selection. Read-only: every change throws.
final class SubsetPhotos: PhotosBackend, @unchecked Sendable {
    static let album = PhotoAlbum(id: "smart:Selection", name: "Selection", kind: .smart, symbol: "checkmark.circle")
    let base: PhotosBackend
    let picked: [PhotoAsset]

    init(base: PhotosBackend, assets: [PhotoAsset]) { self.base = base; picked = assets }

    var capabilities: PhotoCapabilities { [] }
    var cacheKey: String { base.cacheKey }
    func libraries() async throws -> [PhotoLibraryRef] { try await base.libraries() }
    func albums(in library: PhotoLibraryRef) async throws -> [PhotoAlbum] { [Self.album] }
    func assets(in album: PhotoAlbum, library: PhotoLibraryRef, page: @escaping @Sendable ([PhotoAsset], Int?) -> Void) async throws -> [PhotoAsset] {
        page(picked, picked.count)
        return picked
    }
    func thumbnail(_ asset: PhotoAsset, maxPixel: Int) async throws -> CGImage? { try await base.thumbnail(asset, maxPixel: maxPixel) }
    func export(_ asset: PhotoAsset, resource: PhotoResource.Kind, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await base.export(asset, resource: resource, to: destination, progress: progress)
    }
    func setFavorite(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { throw SafetyPolicy.ReadOnlyError() }
    func setHidden(_ assets: [PhotoAsset], _ value: Bool) async throws -> [PhotoAsset] { throw SafetyPolicy.ReadOnlyError() }
    func delete(_ assets: [PhotoAsset]) async throws { throw SafetyPolicy.ReadOnlyError() }
    func restore(_ assets: [PhotoAsset]) async throws { throw SafetyPolicy.ReadOnlyError() }
    func importFiles(_ files: [URL], into album: PhotoAlbum?, library: PhotoLibraryRef, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        throw SafetyPolicy.ReadOnlyError()
    }
    func add(_ assets: [PhotoAsset], to album: PhotoAlbum, library: PhotoLibraryRef) async throws { throw SafetyPolicy.ReadOnlyError() }
    func createAlbum(_ name: String, in library: PhotoLibraryRef) async throws -> PhotoAlbum { throw SafetyPolicy.ReadOnlyError() }
    func syncToken(library: PhotoLibraryRef) -> String? { nil }
    func hasChanges(since token: String, library: PhotoLibraryRef) async throws -> (changed: Bool, token: String?) { (true, nil) }
    func remember(_ libraries: [PhotoLibraryRef]) { base.remember(libraries) }
    func librariesComplete() -> Bool { base.librariesComplete() }
}
