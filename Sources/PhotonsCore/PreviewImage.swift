import Foundation
import CoreImage
import CoreGraphics
import ImageIO

/// Where a preview-sized bitmap came from.
///
/// Both cases are *embedded* camera JPEGs — the difference is only which API handed it to us.
/// There is deliberately **no** case for "we decoded the RAW and downsampled it": that is the
/// G (graph) path and it lives behind `RenderGraph`, never behind this type. A caller that sees
/// `.embedded`/`.fallback` must therefore treat the pixels as "the camera's own look", not as our
/// edit baseline (docs/tasks/006-thumbnails.md §0, §11.2).
public enum PreviewSource: String, Sendable, CaseIterable {
    /// `CIRAWFilter.previewImage` — the full-size JPEG the camera (or DNG Converter) embedded.
    /// Its `sourcePixelSize` is that preview's real size, so it answers "could this file serve
    /// t2048?" without asking for t2048.
    case embedded
    /// `CGImageSourceCreateThumbnailAtIndex` with `CreateThumbnailFromImageIfAbsent = false`.
    /// Measured 2.6× faster than the filter path (49–63 ms vs 153–162 ms p50 over 19 RAWs) and it
    /// **never** forces a full RAW decode. Its `sourcePixelSize` is what ImageIO actually produced
    /// for this request, i.e. the smallest of (embedded thumbnail, embedded preview, request) — so
    /// a file that cannot fill the requested tier reports a short size, which is exactly the
    /// signal `ThumbPolicy.previewAllowed` needs.
    case fallback
}

/// A preview bitmap plus the two sizes and the provenance the UI needs to label it.
public struct PreviewOutcome: Sendable {
    public let image: CGImage
    public let source: PreviewSource
    /// Pixels actually delivered. Never larger than the requested `maxPixelSize`.
    public let pixelSize: CGSize
    /// Pixels of the embedded preview *before* scaling — this is the "禁止放大" budget.
    /// Measured: CR3 8192×5464, RAF 4416×2944, ARW 1616×1080, RW2 1920×1280 (§11.2).
    public let sourcePixelSize: CGSize
    /// EXIF orientation that was applied while rendering, parsed by the same reader the decode path
    /// uses (`RAWDecoder.sourceOrientation(of:)`). Both strategies return an **upright** bitmap, so
    /// this is provenance — the same value `LinearImage.orientation` carries for this file.
    public let orientation: ImageOrientation

    public var longEdge: Int { Int(max(pixelSize.width, pixelSize.height)) }
    public var sourceLongEdge: Int { Int(max(sourcePixelSize.width, sourcePixelSize.height)) }
    /// True when the request was clipped to the embedded preview's own size instead of upscaling.
    public var wasClampedToSource: Bool { longEdge == sourceLongEdge }
}

/// Which API to try.
///
/// `.auto` is filter-first-then-ImageIO and is what `previewImage(_:maxPixelSize:)` uses; the other
/// two exist so the acceptance probe can time each one honestly. Measured on this machine, the
/// ImageIO route is 2.6× faster and is what `photonsctl thumbs` defaults to — but the filter route
/// is the only one that reports a file's *true* embedded-preview size, so a one-off capability
/// probe should use `.filter`.
public enum PreviewStrategy: String, Sendable, CaseIterable {
    case auto
    case filter
    case thumbnail
}

extension RAWDecoder {

    /// Shared context: a `CIContext` costs milliseconds to build, and the P path's whole budget is
    /// 25 ms/thumbnail, so it must not be per-call.
    private static let previewContext: CIContext = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .workingColorSpace: sRGB,
            .outputColorSpace: sRGB,
            .cacheIntermediates: false,
        ])
    }()

    /// The fast path: an embedded camera JPEG, resampled to `maxPixelSize`, in 8-bit sRGB.
    ///
    /// Returns `nil` when the file carries no usable preview. It never falls through to a RAW
    /// decode: "no preview" is a normal state (some DNGs, some damaged cards) and the caller is
    /// expected to escalate to the graph path, not to block a grid cell for 0.5 s.
    public func previewImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        preview(url, maxPixelSize: maxPixelSize, strategy: .auto)?.image
    }

    /// Same pixels, plus where they came from and how big the source was.
    public func preview(_ url: URL, maxPixelSize: Int,
                        strategy: PreviewStrategy = .auto) -> PreviewOutcome? {
        guard maxPixelSize > 0 else { return nil }
        switch strategy {
        case .filter:
            return Self.filterPreview(url, maxPixelSize: maxPixelSize)
        case .thumbnail:
            return Self.imageIOPreview(url, maxPixelSize: maxPixelSize)
        case .auto:
            return Self.filterPreview(url, maxPixelSize: maxPixelSize)
                ?? Self.imageIOPreview(url, maxPixelSize: maxPixelSize)
        }
    }

    // MARK: - the two sources

    private static func filterPreview(_ url: URL, maxPixelSize: Int) -> PreviewOutcome? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        // §11.2: this *is* the embedded JPEG, not a decode — 0.19 s for 4416×2944 versus 0.76 s
        // for a 1/4-scale decode.
        guard let ci = filter.previewImage else { return nil }
        let orientation = sourceOrientation(of: url)
        // `previewImage` is the JPEG bytes as stored, transform not applied (§11.2) — so the
        // orientation is ours to apply, with the same value the decode path records.
        let oriented = ci.oriented(forExifOrientation: Int32(orientation.rawValue))
        guard let outcome = render(oriented, orientation: orientation, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return PreviewOutcome(image: outcome.image, source: .embedded,
                              pixelSize: outcome.pixelSize, sourcePixelSize: outcome.sourcePixelSize,
                              orientation: orientation)
    }

    private static func imageIOPreview(_ url: URL, maxPixelSize: Int) -> PreviewOutcome? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // The load-bearing line: `false` means "use the embedded thumbnail, do NOT decode the
            // image to synthesise one". With `true`, ImageIO would happily do a full RAW decode
            // and the "fast path" would silently become the slow path.
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            // `false` on purpose: ImageIO's own transform only knows `kCGImagePropertyOrientation`,
            // which is 1 for every `irot`-carrying HEIC (§11.5). The transform is applied below
            // with the shared reader instead, so both preview strategies and the decode agree on
            // the same value by construction rather than by coincidence.
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        // Re-render through sRGB so an AdobeRGB embedded thumbnail does not shift the whole grid.
        let orientation = sourceOrientation(of: url)
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation.rawValue))
        let srcSize = CGSize(width: cg.width, height: cg.height)
        let scaled = fit(ci, maxPixelSize: maxPixelSize)
        guard let out = previewContext.createCGImage(scaled.image, from: scaled.rect,
                                                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return nil
        }
        return PreviewOutcome(image: out, source: .fallback, pixelSize: scaled.size,
                              sourcePixelSize: srcSize, orientation: orientation)
    }

    // MARK: - geometry

    private struct Rendered {
        let image: CGImage
        let pixelSize: CGSize
        let sourcePixelSize: CGSize
    }

    private static func fit(_ ci: CIImage, maxPixelSize: Int) -> (image: CIImage, rect: CGRect, size: CGSize) {
        let extent = ci.extent.integral
        let srcLong = max(extent.width, extent.height)
        // No upscaling: asking for t4096 from a 1616 px ARW preview yields 1616 px, and the caller
        // can see that from `sourcePixelSize` (006 §1 "禁止放大").
        let scale = srcLong > CGFloat(maxPixelSize) ? CGFloat(maxPixelSize) / srcLong : 1
        let outW = max(1, (extent.width * scale).rounded())
        let outH = max(1, (extent.height * scale).rounded())
        let scaled = ci
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x * scale,
                                               y: -extent.origin.y * scale))
        let rect = CGRect(x: 0, y: 0, width: outW, height: outH)
        return (scaled, rect, CGSize(width: outW, height: outH))
    }

    private static func render(_ ci: CIImage, orientation: ImageOrientation, maxPixelSize: Int) -> Rendered? {
        let extent = ci.extent.integral
        guard extent.width >= 1, extent.height >= 1,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let fitted = fit(ci, maxPixelSize: maxPixelSize)
        guard let cg = previewContext.createCGImage(fitted.image, from: fitted.rect,
                                                    format: .RGBA8, colorSpace: sRGB) else { return nil }
        return Rendered(image: cg, pixelSize: fitted.size,
                        sourcePixelSize: CGSize(width: extent.width, height: extent.height))
    }

    /// EXIF orientation from the container header. `CIRAWFilter.previewImage` hands back the raw
    /// embedded JPEG without applying it, so a portrait frame would otherwise land sideways in
    /// the grid.
    ///
    /// Delegates to `RAWDecoder.sourceOrientation(of:)` — the same reader the decode path uses, so
    /// the two paths cannot disagree about a file's orientation (and a HEIC's `irot` is honoured
    /// here too, which `kCGImagePropertyOrientation` alone never reports, §11.5).
    static func exifOrientation(of url: URL) -> Int? {
        Self.sourceOrientation(of: url).rawValue
    }
}
