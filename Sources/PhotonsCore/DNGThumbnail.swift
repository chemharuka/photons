import Foundation
import CoreGraphics
import ImageIO

/// 477 — replace the **embedded preview** of a DNG with a JPEG the size of the cropped output at
/// quarter scale.
///
/// The file is TIFF, and the preview lives in its own directory (`NextIFD`'s `JPEGInterchangeFormat`,
/// or a reduced-resolution SubIFD's DNG `PreviewImage` — tags 273/279). Both spellings are handled;
/// only the **JPEG preview** is touched, never the raw image, so a decode before and after is the
/// same picture.
///
/// Two strategies, the same shape `DNGXMP` uses for tag 700:
///
/// 1. **In place** when the new JPEG fits the old slot (JPEG for a quarter-size thumbnail usually
///    does): write it there, zero the tail, keep every offset where it was.
/// 2. **Append** otherwise: the new block goes at EOF and the two inline LONGs are pointed at it.
///    The old block becomes unreferenced bytes — no pointer is left dangling.
public enum DNGThumbnail {

    /// JPEG quality for the embedded thumbnail. Not a user preference: a grid preview is looked at,
    /// not graded, and 0.82 keeps a large preview around 150–400 KB.
    public static let jpegQuality: Double = 0.82

    /// The crop's long edge is divided by this before the 1920 px floor is applied.
    public static let scaleDivisor = 4

    /// **最少要求的长边**. A quarter of a 3000 px crop is 750 px, which is too small for a modern
    /// preview surface; the rule therefore raises it to 1920 (never above the crop itself).
    public static let minimumLongEdge = 1920

    /// The decode proxy used by the UI's thumbnail renderer is 1/4 linear. Exposed so the size rule
    /// and the renderer's scale cannot drift apart.
    public static let decodeProxyDivisor = 4

    public enum Failure: Error, CustomStringConvertible {
        case noEmbeddedPreview(String)
        case unsupportedLayout(String)
        case encodeFailed(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .noEmbeddedPreview(let name): return "\(name) 没有可替换的内嵌预览（不是带 PreviewImage 的 DNG）"
            case .unsupportedLayout(let why): return "DNG 预览布局不受支持：\(why)"
            case .encodeFailed(let why): return "缩略图 JPEG 编码失败：\(why)"
            case .writeFailed(let why): return "缩略图写入失败：\(why)"
            }
        }
    }

    public struct Outcome: Equatable {
        /// The new JPEG fitted the old slot, so no byte offset moved.
        public var replacedInPlace: Bool
        /// Bytes appended to the file (0 for the in-place case).
        public var appendedBytes: Int
        /// The thumbnail's pixel size, written into the directory's ImageWidth/ImageHeight as well.
        public var width: Int
        public var height: Int
    }

    // MARK: - size

    /// The brief's rule: `longEdge = clamp(cropped long edge / 4, 1920, cropped long edge)`.
    ///
    /// - `6000×4000` → `1500` raised to **1920×1280**
    /// - `3000×2000` → `750` raised to **1920×1280**
    /// - `9000×6000` → **2250×1500**
    /// - `1600×1200` → the crop is already under 1920 → **1600×1200** (no upscale)
    public static func targetSize(forCrop canvas: ImageSize) -> ImageSize {
        let width = max(1, canvas.width)
        let height = max(1, canvas.height)
        let longEdge = max(width, height)
        let quarter = Double(longEdge) / Double(scaleDivisor)
        let desired = min(max(quarter, Double(minimumLongEdge)), Double(longEdge))
        let scale = desired / Double(longEdge)
        return ImageSize(width: max(1, Int((Double(width) * scale).rounded())),
                         height: max(1, Int((Double(height) * scale).rounded())))
    }

    /// The DNG's primary image size, from ImageIO metadata (no decode). This is the **full** source
    /// the crop is measured on; the thumbnail renderer's 0.25 proxy must not be mistaken for it.
    public static func mainImagePixelSize(at url: URL) -> ImageSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return ImageSize(width: w, height: h)
    }

    // MARK: - JPEG

    /// Resize to `target` and encode as an 8-bit sRGB JPEG. Colour is normalised on purpose: an
    /// embedded preview is for every surface that cannot afford a decode, and those all draw sRGB.
    public static func jpegData(from image: CGImage, targetSize: ImageSize,
                                quality: Double = jpegQuality) -> Data? {
        guard targetSize.width > 0, targetSize.height > 0,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: targetSize.width, height: targetSize.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: targetSize.width, height: targetSize.height))
        guard let resized = context.makeImage() else { return nil }
        return jpegData(from: resized, quality: quality)
    }

    /// Encode one already-sized image. Kept separate so a caller that has the exact bitmap does not
    /// pay for a second draw.
    public static func jpegData(from image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - read

    /// The preview JPEG currently embedded in `url`, or `nil` when the file has no JPEG preview.
    public static func embeddedPreviewJPEG(at url: URL) throws -> Data? {
        let file = try TIFFFile(Data(contentsOf: url, options: .mappedIfSafe))
        guard let slot = previewSlot(in: file) else { return nil }
        return previewData(slot, in: file)
    }

    /// The **actual** pixel size of the embedded preview, read from the JPEG itself. `nil` when the
    /// file has no JPEG preview.
    public static func embeddedPreviewSize(at url: URL) throws -> ImageSize? {
        guard let jpeg = try embeddedPreviewJPEG(at: url) else { return nil }
        return jpegSize(jpeg)
    }

    static func jpegSize(_ data: Data) -> ImageSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return ImageSize(width: w, height: h)
    }

    // MARK: - write

    /// Replace the embedded preview with `jpeg`, whose real size must be `size`.
    @discardableResult
    public static func write(_ jpeg: Data, size: ImageSize, to url: URL,
                             journal: DNGXMPJournal = .standard) throws -> Outcome {
        guard size.width > 0, size.height > 0 else {
            throw Failure.unsupportedLayout("thumbnail size \(size.width)×\(size.height)")
        }
        var file = try TIFFFile(Data(contentsOf: url))
        try journal.remember(header: file.headerBytes, ifd0: file.ifd0, for: url)
        guard let slot = previewSlot(in: file) else {
            throw Failure.noEmbeddedPreview(url.lastPathComponent)
        }

        let before = file.data.count
        let replacedInPlace: Bool
        var offset = slot.offset
        if jpeg.count <= slot.length {
            try file.overwriteBytes(at: slot.offset, with: jpeg, zeroFillTo: slot.length)
            replacedInPlace = true
        } else {
            offset = file.appendBlock(jpeg)
            replacedInPlace = false
        }
        let appended = file.data.count - before

        try file.setEntryValue(UInt32(offset), tag: slot.offsetTag, in: slot.ifd)
        try file.setEntryValue(UInt32(jpeg.count), tag: slot.countTag, in: slot.ifd)
        try file.setEntryValue(UInt32(size.width), tag: 256, in: slot.ifd)      // ImageWidth
        try file.setEntryValue(UInt32(size.height), tag: 257, in: slot.ifd)     // ImageHeight
        if file.entries(of: 278, in: slot.ifd) != nil {                         // RowsPerStrip
            try file.setEntryValue(UInt32(size.height), tag: 278, in: slot.ifd)
        }
        try file.persist(to: url)
        return Outcome(replacedInPlace: replacedInPlace, appendedBytes: appended,
                       width: size.width, height: size.height)
    }

    // MARK: - directory discovery

    struct PreviewSlot {
        let ifd: UInt32
        let offsetTag: UInt16
        let countTag: UInt16
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
        let area: Int
    }

    /// Find the JPEG preview a DNG reader means by "the embedded preview".
    ///
    /// Order matters. A classic TIFF thumbnail is `IFD1` with `JPEGInterchangeFormat(513)`; a DNG
    /// Converter file keeps its preview in a reduced-resolution SubIFD with
    /// `PreviewImageStart(273)/PreviewImageLength(279)` — measured on the acceptance fixture
    /// (`CIRAWFilter.previewImage` returned that 1024×682 image, not the 1904×1267 JPEG XL one).
    static func previewSlot(in file: TIFFFile) -> PreviewSlot? {
        var directories: [UInt32] = []
        // 1. the IFD1 chain (classic TIFF thumbnail)
        var next = file.nextIFD(after: file.ifd0)
        var guardCount = 0
        while next != 0, guardCount < 8 {
            directories.append(next)
            next = file.nextIFD(after: next)
            guardCount += 1
        }
        // 2. IFD0's SubIFDs (DNG previews). One level is enough for every DNG layout this app reads;
        //    a preview hidden two levels down is not a layout we claim to support.
        directories.append(contentsOf: file.subIFDOffsets(in: file.ifd0))

        var best: PreviewSlot?
        for ifd in directories {
            guard let compression = file.entries(of: 259, in: ifd),
                  file.scalarValue(compression) == 7 else { continue }
            guard let wEntry = file.entries(of: 256, in: ifd),
                  let hEntry = file.entries(of: 257, in: ifd),
                  let w = file.scalarValue(wEntry), w > 0,
                  let h = file.scalarValue(hEntry), h > 0 else { continue }
            let pair: (UInt16, UInt16)?
            if file.entries(of: 513, in: ifd) != nil, file.entries(of: 514, in: ifd) != nil {
                pair = (513, 514)
            } else if file.entries(of: 273, in: ifd) != nil, file.entries(of: 279, in: ifd) != nil {
                pair = (273, 279)
            } else {
                pair = nil
            }
            guard let (offsetTag, countTag) = pair,
                  let offsetEntry = file.entries(of: offsetTag, in: ifd),
                  let countEntry = file.entries(of: countTag, in: ifd),
                  offsetEntry.count == 1, countEntry.count == 1,
                  let offset = file.scalarValue(offsetEntry),
                  let length = file.scalarValue(countEntry), length > 0,
                  Int(offset) + Int(length) <= file.data.count else { continue }
            let slot = PreviewSlot(ifd: ifd, offsetTag: offsetTag, countTag: countTag,
                                   offset: Int(offset), length: Int(length),
                                   width: Int(w), height: Int(h),
                                   area: Int(w) * Int(h))
            // Prefer the classic IFD1 thumbnail if both exist (that is what DNG readers fall back
            // to for older files); otherwise the largest JPEG preview is the one worth updating.
            if best == nil
                || (offsetTag == 513 && best?.offsetTag != 513)
                || (offsetTag == best?.offsetTag && slot.area > (best?.area ?? 0)) {
                best = slot
            }
        }
        return best
    }

    private static func previewData(_ slot: PreviewSlot, in file: TIFFFile) -> Data? {
        guard slot.offset >= 0, slot.offset + slot.length <= file.data.count else { return nil }
        return file.data.subdata(in: (file.data.startIndex + slot.offset)
                                 ..< (file.data.startIndex + slot.offset + slot.length))
    }
}
