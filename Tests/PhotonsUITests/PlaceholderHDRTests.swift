import XCTest
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 284 — the first-frame stand-in must carry the **same light** as the grid/filmstrip cells.
///
/// Before this the HD cache (10-bit Display P3 PQ) went through `decodeWholePictureSRGB`: an 8-bit
/// sRGB bitmap drawn by `NSImageView`. The cells decoded the same file as half-float extended linear
/// Display P3 on a `CAMetalLayer`, so switching from the stand-in to the real frame changed both the
/// highlights (PQ headroom thrown away) and saturated colours (P3 narrowed to sRGB).
///
/// The acceptance here is by numbers, not by eye:
///   · the shipped placeholder decode is 16-bit `extendedLinearDisplayP3` with content headroom > 1;
///   · its aspect is the whole photograph's (no aspect-fill crop);
///   · the 8-bit fallback is `displayP3`, never sRGB;
///   · the shipped cache path counts EDR decodes and never an sRGB one;
///   · the stand-in's surface is the grid's `CAMetalLayer` (float, EDR, extended-range space);
///   · the p99 highlight value of the stand-in is within 5 % of the real first frame's.
@MainActor
final class PlaceholderHDRTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-placeholder-hdr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - the shipped decode

    func testThePlaceholderIsEDRDisplayP3AtTheWholePictureAspect() throws {
        let document = equalEdit(exposure: 1)
        let generated = try generateHD(document: document)
        let placeholder = try XCTUnwrap(ThumbnailProvider.decodeHDForPlaceholder(generated.data))

        let extP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        XCTAssertEqual(placeholder.bitsPerComponent, 16,
                       "the stand-in must be the half-float exit, not an 8-bit one")
        XCTAssertEqual(placeholder.colorSpace?.name, extP3.name,
                       "the stand-in must stay in extended linear Display P3")
        if #available(macOS 15.0, *) {
            XCTAssertGreaterThanOrEqual(placeholder.contentHeadroom, 1.05,
                                        "the PQ file's highlights did not survive into the stand-in")
        }

        // Whole picture: the same aspect as the file, and the HD tier's 1920 long edge (not a
        // display-sized crop).
        let raw = try pixelSize(of: rawURL())
        XCTAssertEqual(Double(placeholder.width) / Double(placeholder.height),
                       Double(raw.width) / Double(raw.height), accuracy: 0.01,
                       "the stand-in was cropped instead of showing the whole photograph")
        XCTAssertLessThanOrEqual(max(placeholder.width, placeholder.height), 1920)
        XCTAssertGreaterThanOrEqual(max(placeholder.width, placeholder.height), 1600,
                                    "the stand-in is not the 1920 HD tier")

        print("284 placeholder · \(placeholder.width)×\(placeholder.height)"
              + " · 16-bit \(String(describing: placeholder.colorSpace?.name))"
              + " · headroom \(contentHeadroomText(placeholder))")
    }

    private func contentHeadroomText(_ image: CGImage) -> String {
        if #available(macOS 15.0, *) { return String(format: "%.2f", image.contentHeadroom) }
        return "n/a"
    }

    /// The no-Metal fallback keeps Display P3. `decodeWholePictureSRGB` still exists as the historical
    /// door but no placeholder path names it any more.
    func testTheSDRFallbackIsDisplayP3EightBit() throws {
        let url = root.appendingPathComponent("fallback.heic")
        try writeSyntheticPQ(linear: { _, _ in (0.8, 0.4, 0.2) }, width: 64, height: 64, to: url)
        let data = try Data(contentsOf: url)

        let sdr = try XCTUnwrap(ThumbnailHDRDecoder.shared.decodeWholePictureSDR(data))
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        XCTAssertEqual(sdr.bitsPerComponent, 8)
        XCTAssertEqual(sdr.colorSpace?.name, p3.name,
                       "the SDR fallback narrowed the P3 file to sRGB")
        XCTAssertEqual(sdr.width, 64)
        XCTAssertEqual(sdr.height, 64)

        print("284 SDR fallback · \(sdr.width)×\(sdr.height) · \(sdr.bitsPerComponent)-bit"
              + " \(String(describing: sdr.colorSpace?.name))")
    }

    /// The shipped `cachedCanvasPlaceholder` door, including its counters: one EDR decode, zero sRGB.
    func testTheShippedPlaceholderPathDecodesEDRAndNeverSRGB() throws {
        let document = equalEdit(exposure: 1)
        let generated = try generateHD(document: document)
        generated.provider.resetStats()

        let placeholder = try XCTUnwrap(
            generated.provider.cachedCanvasPlaceholder(for: asset(), document: document))
        let extP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        XCTAssertEqual(placeholder.bitsPerComponent, 16)
        XCTAssertEqual(placeholder.colorSpace?.name, extP3.name,
                       "the shipped stand-in is not extended linear Display P3")

        let stats = generated.provider.stats
        print("284 placeholder counters · EDR \(stats.placeholderEDRDecodes)"
              + " · SDR \(stats.placeholderSDRDecodes) · sRGB \(stats.placeholderSRGBDecodes)")
        XCTAssertEqual(stats.placeholderEDRDecodes, 1,
                       "the shipped stand-in did not take the EDR decode door")
        XCTAssertEqual(stats.placeholderSDRDecodes, 0,
                       "the no-Metal branch ran on a Metal machine")
        XCTAssertEqual(stats.placeholderSRGBDecodes, 0,
                       "the stand-in still used the old sRGB door")
    }

    /// A library that only has the legacy 8-bit JPEG preview still gets a Display P3 stand-in: the
    /// fallback is colour-managed, not displayed as sRGB.
    func testTheLegacyPreviewFallbackIsRedrawnDisplayP3() throws {
        let asset = asset()
        let cache = try cache()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 427,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 427))
        let bitmap = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let tier = ThumbnailProvider.effectiveTier(requested: .t1024, ext: asset.ext).tier
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: tier))

        let provider = ThumbnailProvider(cache: cache)
        let placeholder = try XCTUnwrap(
            provider.cachedCanvasPlaceholder(for: asset, document: .neutral))
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        XCTAssertEqual(placeholder.bitsPerComponent, 8)
        XCTAssertEqual(placeholder.colorSpace?.name, p3.name,
                       "the legacy preview stand-in is still sRGB")
    }

    /// The stand-in's surface is the grid's: a half-float `CAMetalLayer` with EDR enabled and the
    /// extended-range space. A plain `NSImageView` cannot carry this bitmap.
    func testTheStandInSurfaceIsAnEDRMetalLayer() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else {
            throw XCTSkip("no Metal device")
        }
        _ = NSApplication.shared
        let canvas = LoupeCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let image = try makeEDRImage(width: 64, height: 48)
        canvas.showFirstFramePlaceholder(image, contentRect: canvas.bounds)
        XCTAssertTrue(canvas.isShowingFirstFramePlaceholder,
                      "the stand-in is not visible in the turn it was installed")
        XCTAssertEqual(canvas.firstFramePlaceholderImage?.width, image.width)
        XCTAssertEqual(canvas.firstFramePlaceholderImage?.height, image.height)

        let metal = try XCTUnwrap(canvas.firstFramePlaceholderLayer,
                                  "284: the stand-in must be a CAMetalLayer")
        let extP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        XCTAssertTrue(metal.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(metal.pixelFormat, .rgba16Float, "float drawable, so >1 survives")
        XCTAssertEqual(metal.colorspace?.name, extP3.name)
        XCTAssertFalse(metal.isOpaque, "the matte/cover behind shows through before the present")

        canvas.hideFirstFramePlaceholder()
        XCTAssertFalse(canvas.isShowingFirstFramePlaceholder)
    }

    // MARK: - the brightness agreement

    /// The acceptance's numeric proxy for 「观感统一」: the mean linear value of the top 1 % (p99)
    /// highlights over the whole picture, stand-in vs the loupe's real first frame. Both are Display
    /// P3 linear; the frame texture is S4's sRGB-encoded output, so it is decoded back first.
    func testPlaceholderHighlightsMatchTheRealFirstFrameWithinFivePercent() throws {
        let document = equalEdit(exposure: 1)
        let generated = try generateHD(document: document)
        let placeholder = try XCTUnwrap(ThumbnailProvider.decodeHDForPlaceholder(generated.data))

        let controller = LoupeController(session: CatalogSession())
        controller.setDisplayHeadroom(DisplayHeadroom(headroom: 16, screenName: "test",
                                                       maximumEDRComponent: 16,
                                                       source: .extendedRange))
        let viewport = ImageSize(width: 900, height: 600)
        let frame = try controller.makeFrame(url: rawURL(), viewport: viewport,
                                             decodeScale: 0.5, edit: document,
                                             state: .fit, hashPixels: false)

        let placeholderP99 = try linearHighlightMean(of: placeholder)
        let frameP99 = try frameHighlightMean(frame)
        let difference = abs(placeholderP99 - frameP99) / max(frameP99, 1e-6)

        // The pre-fix door, measured on the same file and frame: this is the number the report
        // quotes as "before". It is the old sRGB bitmap's own top 1 % mean.
        var legacyText = " · legacy sRGB n/a"
        if let legacy = ThumbnailHDRDecoder.shared.decodeWholePictureSRGB(generated.data) {
            let legacyP99 = try srgb8HighlightMean(of: legacy)
            let legacyDifference = abs(legacyP99 - frameP99) / max(frameP99, 1e-6)
            legacyText = String(format: " · legacy sRGB %.4f (difference %.2f %%)",
                                legacyP99, legacyDifference * 100)
        }
        print(String(format: "284 p99 highlights · stand-in %.4f · real frame %.4f · difference %.2f %%",
                     placeholderP99, frameP99, difference * 100) + legacyText)
        XCTAssertLessThanOrEqual(difference, 0.05,
                                 "stand-in p99 \(placeholderP99) vs frame \(frameP99)")
    }

    // MARK: - fixtures

    private func rawURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            ?? NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return URL(fileURLWithPath: path)
    }

    private func asset() -> Asset {
        Asset(id: "asset-1", sourceRootId: "root", relPath: "L1030433.dng",
              filename: "L1030433.dng", ext: "dng", kind: .raw, size: 1, mtime: 0,
              contentHash: String(repeating: "a", count: 64), width: 9520, height: 6336)
    }

    private func cache() throws -> ThumbnailCache { try ThumbnailCache(root: root) }

    private func equalEdit(exposure: Double) -> EditModel {
        var document = EditModel.neutral
        document.light.exposure = exposure
        return document
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ImageSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                         height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    @discardableResult
    private func generateHD(document: EditModel) throws
        -> (provider: ThumbnailProvider, key: ThumbKey, data: Data) {
        let provider = try ThumbnailProvider(cache: cache())
        let done = expectation(description: "HD thumbnail delivered")
        var delivered: ThumbKey?
        let token = provider.request(index: 0, asset: asset(), fileURL: try rawURL(),
                                     document: document, tier: .t256, spec: .hd,
                                     display: ImageSize(width: 326, height: 242)) { _, key, image in
            XCTAssertNotNil(image, "the HD producer must decode its own file")
            delivered = key
            done.fulfill()
        }
        wait(for: [done], timeout: 180)
        XCTAssertFalse(token.isCancelled)
        let key = try XCTUnwrap(delivered)
        return (provider, key, try Data(contentsOf: provider.cache.url(for: key)))
    }

    private func writeSyntheticPQ(linear values: (Int, Int) -> (Float, Float, Float),
                                   width: Int, height: Int, to url: URL) throws {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = values(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(r); rgba[i + 1] = Float16(g)
                rgba[i + 2] = Float16(b); rgba[i + 3] = 1
            }
        }
        let pixels = LinearPixels(width: width, height: height, rgba: rgba, primaries: .displayP3)
        let image = DisplayImage(width: width, height: height, rgba: rgba,
                                 primaries: .displayP3, bitDepth: 16, linear: pixels)
        let options = ExportOptions(format: .heic, quality: 0.75, bitDepth: 10,
                                    hdr: HDRExport(enabled: true, kind: .pq))
        try HDREncoding.write(image, to: url, options: options)
    }

    private func makeEDRImage(width: Int, height: Int) throws -> CGImage {
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: halves.count, by: 4) {
            halves[i] = Float16(4).bitPattern
            halves[i + 1] = Float16(4).bitPattern
            halves[i + 2] = Float16(4).bitPattern
            halves[i + 3] = Float16(1).bitPattern
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes: halves,
                                                              count: halves.count * 2) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16,
                                     bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                                     bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent))
    }

    // MARK: - linear statistics

    /// Top-1 % mean of the per-pixel mean RGB in a whole-picture extended linear P3 bitmap.
    private func linearHighlightMean(of image: CGImage) throws -> Double {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let base = try XCTUnwrap(CFDataGetBytePtr(data))
        let halves = UnsafeRawPointer(base).assumingMemoryBound(to: UInt16.self)
        let rowHalves = image.bytesPerRow / MemoryLayout<UInt16>.size
        let pixels = image.width * image.height
        let step = max(1, pixels / 200_000)

        var values: [Float] = []
        values.reserveCapacity(pixels / step + 1)
        var index = 0
        while index < pixels {
            let x = index % image.width
            let y = index / image.width
            let i = y * rowHalves + x * 4
            let r = Float(Float16(bitPattern: halves[i]))
            let g = Float(Float16(bitPattern: halves[i + 1]))
            let b = Float(Float16(bitPattern: halves[i + 2]))
            values.append((r + g + b) / 3)
            index += step
        }
        return topOnePercentMean(values)
    }

    /// The same quantity from the frame's S4 output (sRGB OETF, clipped at the frame's headroom),
    /// decoded back to linear over the photograph's own rect.
    private func frameHighlightMean(_ frame: LoupeController.FrameResult) throws -> Double {
        let texture = frame.texture
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { throw XCTSkip("empty frame texture") }
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        let rect = frame.photoRect
        let x0 = max(0, min(width, rect.x)), y0 = max(0, min(height, rect.y))
        let x1 = max(x0, min(width, rect.x + rect.width))
        let y1 = max(y0, min(height, rect.y + rect.height))
        let pixels = max(1, (x1 - x0) * (y1 - y0))
        let step = max(1, pixels / 200_000)

        var values: [Float] = []
        values.reserveCapacity(pixels / step + 1)
        var index = 0
        while index < pixels {
            let x = x0 + index % max(1, x1 - x0)
            let y = y0 + index / max(1, x1 - x0)
            let i = (y * width + x) * 4
            let r = Histogram.srgbDecode(max(0, Float(Float16(bitPattern: halves[i]))))
            let g = Histogram.srgbDecode(max(0, Float(Float16(bitPattern: halves[i + 1]))))
            let b = Histogram.srgbDecode(max(0, Float(Float16(bitPattern: halves[i + 2]))))
            values.append((r + g + b) / 3)
            index += step
        }
        return topOnePercentMean(values)
    }

    /// 8-bit sRGB (the pre-284 door): decode the code values back to linear before averaging.
    private func srgb8HighlightMean(of image: CGImage) throws -> Double {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let base = try XCTUnwrap(CFDataGetBytePtr(data))
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        let pixels = image.width * image.height
        let step = max(1, pixels / 200_000)

        var values: [Float] = []
        values.reserveCapacity(pixels / step + 1)
        var index = 0
        while index < pixels {
            let x = index % image.width
            let y = index / image.width
            let i = y * image.bytesPerRow + x * 4
            let r = Histogram.srgbDecode(Float(bytes[i]) / 255)
            let g = Histogram.srgbDecode(Float(bytes[i + 1]) / 255)
            let b = Histogram.srgbDecode(Float(bytes[i + 2]) / 255)
            values.append((r + g + b) / 3)
            index += step
        }
        return topOnePercentMean(values)
    }

    private func topOnePercentMean(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let start = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))
        let top = sorted[start...]
        let sum = top.reduce(Float(0), +)
        return Double(sum / Float(top.count))
    }
}
