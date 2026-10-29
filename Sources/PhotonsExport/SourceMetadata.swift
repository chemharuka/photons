import Foundation
import ImageIO
import PhotonsCore

// MARK: - 107 · source metadata carried into the export
//
// ImageIO already decodes every metadata block the source file has; the export path used to ignore
// all of them and write a bare pixel stream. This file reads those dictionaries once and hands the
// encoder a property dictionary + an XMP packet, so a JPEG/HEIC/TIFF/PNG keeps the camera, lens,
// exposure, capture time, GPS and copyright of the file it came from.
//
// Only ImageIO touches metadata (docs/architecture-decisions.md D1): no Exiv2, no LibRaw.

/// The metadata blocks of a source file, still in ImageIO's own dictionaries.
///
/// The dictionaries are copied **whole** (including keys this milestone does not name) because
/// re-serialising a partial EXIF/TIFF block is how a file loses its maker notes. The writer only
/// overrides the fields whose value is a property of the *output*: pixel dimensions and orientation.
public struct SourceMetadata {

    public var exif: [String: Any]
    public var tiff: [String: Any]
    public var gps: [String: Any]
    public var iptc: [String: Any]
    public var xmp: CGImageMetadata?

    public init(exif: [String: Any] = [:], tiff: [String: Any] = [:],
                gps: [String: Any] = [:], iptc: [String: Any] = [:],
                xmp: CGImageMetadata? = nil) {
        self.exif = exif
        self.tiff = tiff
        self.gps = gps
        self.iptc = iptc
        self.xmp = xmp
    }

    /// `nil` when the URL is missing or ImageIO cannot read it: an export must still succeed for a
    /// source whose metadata is unreadable (the pixels are the product).
    public static func read(from url: URL?) -> SourceMetadata? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return nil
        }
        return SourceMetadata(
            exif: dictionary(properties[kCGImagePropertyExifDictionary]),
            tiff: dictionary(properties[kCGImagePropertyTIFFDictionary]),
            gps: dictionary(properties[kCGImagePropertyGPSDictionary]),
            iptc: dictionary(properties[kCGImagePropertyIPTCDictionary]),
            xmp: CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    /// ImageIO hands these back as `CFDictionary` keyed by `CFString`; bridge them to `String` keys so
    /// the rest of the code can use the `kCGImageProperty*` constants directly.
    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let d = value as? [String: Any] { return d }
        if let d = value as? [CFString: Any] {
            var out: [String: Any] = [:]
            for (key, value) in d {
                out[key as String] = value
            }
            return out
        }
        return [:]
    }
}

// MARK: - what to write

/// Everything the encoder needs to know about metadata for one export.
///
/// `level` is 099's `metadataLevel`; `source` is the file read above; `edit` is only used for the
/// embedded `crs:` packet. `embedXMP` is decided by the batch engine (it depends on the container),
/// so the encoder never has to guess whether a sidecar is the fallback.
public struct ExportMetadataContext {

    public var level: ExportMetadataLevel
    public var source: SourceMetadata?
    public var edit: EditModel?
    /// The catalog's author/copyright, used by `.copyright` and overlaid on `.all`.
    public var author: String?
    public var copyright: String?
    /// Embed the `crs:`/`photons:` packet. `.none` and `.copyright` never embed.
    public var embedXMP: Bool

    public init(level: ExportMetadataLevel = .all, source: SourceMetadata? = nil,
                edit: EditModel? = nil, author: String? = nil, copyright: String? = nil,
                embedXMP: Bool = false) {
        self.level = level
        self.source = source
        self.edit = edit
        self.author = author
        self.copyright = copyright
        self.embedXMP = embedXMP
    }

    /// `kCGImageProperty*Dictionary` entries for `CGImageDestinationAddImage`.
    ///
    /// `width`/`height` are the **output** pixel size: the source's `PixelXDimension` describes a
    /// picture this file is not. Orientation is forced to 1 because the renderer already baked the
    /// rotation/flip into the pixels; leaving the camera's 6/8 would rotate the output a second time.
    public func properties(outputWidth width: Int, outputHeight height: Int,
                           format: ExportFormat = .jpeg) -> [CFString: Any] {
        switch level {
        case .none:
            // JPEG's writer accepts `NSNull` as "no EXIF block"; without it ImageIO adds a
            // three-field EXIF block of its own (colour space + pixel dimensions). The PNG/TIFF/HEIC
            // writers reject that marker, and they cannot be told to omit their structural tags
            // either, so there we simply pass no property dictionary.
            return format == .jpeg ? [kCGImagePropertyExifDictionary: NSNull()] : [:]
        case .copyright:
            return copyrightProperties()
        case .all:
            return allProperties(outputWidth: width, outputHeight: height)
        }
    }

    /// The XMP packet to embed, or `nil` when this export must not carry one.
    public func xmpMetadata(outputWidth width: Int, outputHeight height: Int) -> CGImageMetadata? {
        guard level == .all, embedXMP, let edit else { return nil }
        // Merge into the source packet so rating/label/keywords and other people's namespaces
        // survive; only our `crs:`/`photons:` keys are overwritten (docs/xmp-mapping.md §4.2).
        guard let built = try? XMPWriter.makeMetadata(for: edit,
                                                      existing: source?.xmp,
                                                      context: XMPWriteContext(exifOrientation: 1)).metadata,
              let metadata = CGImageMetadataCreateMutableCopy(built) else {
            return nil
        }
        // A source packet written by ImageIO carries the *source's* EXIF dimensions. The file we are
        // about to write has different ones (crop/scale), and ImageIO prefers the XMP over the
        // property dictionary when both are present — so update them here.
        setNumber(metadata, "exif:PixelXDimension", width)
        setNumber(metadata, "exif:PixelYDimension", height)
        // Same for the camera's orientation: neutral geometry has already been baked into pixels,
        // and a stale `tiff:Orientation = 6` would rotate the output again in Lightroom.
        let g = edit.geometry
        if !g.flipHorizontal && !g.flipVertical && g.quarterTurns == 0 {
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, "tiff:Orientation" as CFString)
        }
        return metadata
    }

    private func setNumber(_ metadata: CGMutableImageMetadata, _ path: String, _ value: Int) {
        _ = CGImageMetadataSetValueWithPath(metadata, nil, path as CFString,
                                            NSNumber(value: value))
    }

    // MARK: per-level shapes

    private func copyrightProperties() -> [CFString: Any] {
        var exif: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        if let artist = nonEmpty(author) ?? sourceString(kCGImagePropertyTIFFArtist) {
            exif["Artist"] = artist
            tiff[kCGImagePropertyTIFFArtist as String] = artist
            // ImageIO's JPEG/TIFF writer drops `Artist` when it is the TIFF block's only ASCII
            // field (verified on macOS 27). A document name is a harmless extra tag that keeps the
            // author in the file without re-introducing Make/Model.
            tiff[kCGImagePropertyTIFFDocumentName as String] = "photons"
        }
        if let rights = nonEmpty(copyright) ?? sourceString(kCGImagePropertyTIFFCopyright) {
            exif["Copyright"] = rights
            tiff[kCGImagePropertyTIFFCopyright as String] = rights
        }
        guard !tiff.isEmpty else { return [:] }
        return [kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff]
    }

    private func allProperties(outputWidth width: Int, outputHeight height: Int) -> [CFString: Any] {
        var exif = source?.exif ?? [:]
        var tiff = source?.tiff ?? [:]
        // The catalog's values win over whatever the file happened to carry.
        if let artist = nonEmpty(author) { tiff[kCGImagePropertyTIFFArtist as String] = artist }
        if let rights = nonEmpty(copyright) { tiff[kCGImagePropertyTIFFCopyright as String] = rights }
        // These two describe the output, not the source.
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        tiff[kCGImagePropertyTIFFOrientation as String] = 1

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyPixelWidth: width,
            kCGImagePropertyPixelHeight: height,
        ]
        if let gps = source?.gps, !gps.isEmpty {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        if let iptc = source?.iptc, !iptc.isEmpty {
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
        return properties
    }

    private func sourceString(_ key: CFString) -> String? {
        nonEmpty(source?.tiff[key as String] as? String)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
