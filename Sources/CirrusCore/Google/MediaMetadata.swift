import AVFoundation
import Foundation
import ImageIO

/// Writes Google's capture date (and place and caption) into the *staged copy* of a photo or video
/// when the file doesn't carry them itself, so iCloud Photos files it under the right day.
/// Files that already have a date are left byte-for-byte as they are.
public enum MediaMetadataWriter {
    /// Returns true when the staged file was rewritten.
    @discardableResult
    public static func fill(_ url: URL, isVideo: Bool, taken: Date?, latitude: Double?, longitude: Double?, caption: String?) async -> Bool {
        let changed = isVideo ? await fillVideo(url, taken: taken) : fillImage(url, taken: taken, latitude: latitude, longitude: longitude, caption: caption)
        if let d = taken { try? FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: url.path) }
        return changed
    }

    static func exifDate(_ d: Date) -> (String, String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let secs = TimeZone.current.secondsFromGMT(for: d)
        let off = String(format: "%@%02d:%02d", secs < 0 ? "-" : "+", abs(secs) / 3600, (abs(secs) % 3600) / 60)
        return (f.string(from: d), off)
    }

    static func fillImage(_ url: URL, taken: Date?, latitude: Double?, longitude: Double?, caption: String?) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) > 0 else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let meta = CGImageMetadataCreateMutable()
        var changed = false
        func set(_ dict: CFString, _ key: CFString, _ value: CFTypeRef) {
            if CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value) { changed = true }
        }
        if exif[kCGImagePropertyExifDateTimeOriginal] == nil, exif[kCGImagePropertyExifDateTimeDigitized] == nil, tiff[kCGImagePropertyTIFFDateTime] == nil,
           let d = taken {
            let (s, off) = exifDate(d)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, s as CFString)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, s as CFString)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, off as CFString)
        }
        if props[kCGImagePropertyGPSDictionary] == nil, let lat = latitude, let lon = longitude, lat != 0 || lon != 0 {
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(lat) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (lat < 0 ? "S" : "N") as CFString)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(lon) as CFNumber)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (lon < 0 ? "W" : "E") as CFString)
        }
        if iptc[kCGImagePropertyIPTCCaptionAbstract] == nil, tiff[kCGImagePropertyTIFFImageDescription] == nil, let c = caption, !c.isEmpty {
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, c as CFString)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, c as CFString)
        }
        guard changed else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".meta-" + UUID().uuidString.prefix(6) + "-" + url.lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        // Lossless: copies the encoded image and merges in the new metadata (JPEG, HEIC, PNG, TIFF).
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) else {
            err?.release()
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch { try? FileManager.default.removeItem(at: tmp); return false }
        return true
    }

    static func fillVideo(_ url: URL, taken: Date?) async -> Bool {
        guard let d = taken else { return false }
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), (try? await item.load(.dateValue)) != nil { return false }
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = ext == "mov" ? .mov : (ext == "m4v" ? .m4v : .mp4)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let iso = ISO8601DateFormatter().string(from: d)
        var items = (try? await asset.load(.metadata)) ?? []
        for id in [AVMetadataIdentifier.commonIdentifierCreationDate, .quickTimeMetadataCreationDate] {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = iso as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(m)
        }
        export.metadata = items
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".meta-" + UUID().uuidString.prefix(6) + "-" + url.lastPathComponent)
        do {
            if #available(macOS 15, *) {
                try await export.export(to: tmp, as: type)
            } else {
                export.outputURL = tmp
                export.outputFileType = type
                let box = UncheckedBox(export)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.value.exportAsynchronously { c.resume() } }
                guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}

final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
