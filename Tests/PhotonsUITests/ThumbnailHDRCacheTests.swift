import XCTest
import AppKit
import CoreImage
import Darwin
import ImageIO
import Metal
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 223 — the one HD thumbnail file three views share: a **10-bit Display P3 PQ** primary image,
/// 1920 long edge, q0.75, **no auxiliary gain map**.
///
/// 227 — the cache stays HDR (and `decodeHD` still returns float extended-linear P3), but the
/// **display is a CAMetalLayer**: a CALayer with EDR contents let macOS raise reference white towards
/// the panel's maximum, so the same picture looked overexposed in the grid while the loupe looked
/// correct. CAMetalLayer keeps EDR 1.0 = SDR white and does not tone map.
///
/// The numbers are asserted by reading the file back (container, depth, colour space, auxiliary
/// items, P3-vs-sRGB primaries) and by decoding it through the shipped Core Image → Metal path at the
/// three real cell sizes, never by trusting the options we passed in.
final class ThumbnailHDRCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hd-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    private func asset(ext: String = "dng") -> Asset {
        Asset(id: "asset-1", sourceRootId: "root", relPath: "L1030433.dng",
              filename: "L1030433.dng", ext: ext, kind: .raw, size: 1, mtime: 0,
              contentHash: String(repeating: "a", count: 64), width: 9520, height: 6336)
    }

    private func cache() throws -> ThumbnailCache { try ThumbnailCache(root: root) }

    private func equalEdit(exposure: Double) -> EditModel {
        var document = EditModel.neutral
        document.light.exposure = exposure
        return document
    }

    /// Generate one HD file from the RAW and return its bytes. The display size only decides the
    /// decode that runs after generation, never the 1920 file itself.
    @discardableResult
    private func generateHD(display: ImageSize = ImageSize(width: 326, height: 242),
                            document: EditModel? = nil,
                            provider: ThumbnailProvider? = nil) throws
        -> (provider: ThumbnailProvider, key: ThumbKey, data: Data) {
        let url = try rawURL()
        let used: ThumbnailProvider
        if let provider { used = provider } else { used = try ThumbnailProvider(cache: cache()) }
        let doc = document ?? equalEdit(exposure: 1)
        let done = expectation(description: "HD thumbnail delivered")
        var delivered: ThumbKey?
        let token = used.request(index: 0, asset: asset(), fileURL: url, document: doc,
                                 tier: .t256, spec: .hd, display: display) { _, key, image in
            XCTAssertNotNil(image, "the HD producer must decode its own file")
            delivered = key
            done.fulfill()
        }
        wait(for: [done], timeout: 180)
        XCTAssertFalse(token.isCancelled)
        let key = try XCTUnwrap(delivered)
        let data = try Data(contentsOf: used.cache.url(for: key))
        return (used, key, data)
    }

    /// Write a synthetic PQ picture with known linear P3 values. Same encoder the thumbnail
    /// producer uses (`HDREncoding.write`), so the primaries/depth assertions cover both.
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
        let linear = LinearPixels(width: width, height: height, rgba: rgba,
                                  primaries: .displayP3)
        let image = DisplayImage(width: width, height: height, rgba: rgba,
                                 primaries: .displayP3, bitDepth: 16, linear: linear)
        let options = ExportOptions(format: .heic, quality: 0.75, bitDepth: 10,
                                    hdr: HDRExport(enabled: true, kind: .pq))
        try HDREncoding.write(image, to: url, options: options)
    }

    // MARK: - 1. key

    func testHDKeyNamesThePinnedSpecAndMovesWithTheDocument() {
        let base = ThumbKey.hd(contentHash: "abc", document: .neutral)
        let same = ThumbKey.hd(contentHash: "abc", document: .neutral)
        let edited = ThumbKey.hd(contentHash: "abc", document: equalEdit(exposure: 1))

        XCTAssertEqual(base, same)
        XCTAssertNotEqual(base.digest, edited.digest, "an edit must produce a new cache key")
        XCTAssertTrue(base.keyString.contains("hd1920q75p3pq10"))
        XCTAssertTrue(base.keyString.contains("sv3"))
        XCTAssertEqual(base.spec.schemaVersion, 3)
        // Legacy (8-bit JPEG, no row-order change) must not be invalidated by the HD bump.
        XCTAssertEqual(ThumbSpec.legacy.schemaVersion, 1)
        XCTAssertEqual(base.spec, .hd)
        XCTAssertEqual(base.spec.longEdge, 1920)
        XCTAssertEqual(base.spec.quality, 0.75)
        XCTAssertEqual(base.spec.bitDepth, 10)
        XCTAssertEqual(base.spec.colorSpaceName, "displayP3_PQ")
        XCTAssertEqual(base.relativePath(in: root).pathExtension, "heic")
        // The legacy ladder is byte-for-byte unchanged.
        XCTAssertEqual(ThumbKey.preview(contentHash: "abc", tier: .t256).keyString,
                       "thumb|v1|abc|t256|preview|-")
        // The 218 gain-map spelling is unreachable, so old files age out through the LRU.
        XCTAssertFalse(base.keyString.contains("gm23"))
    }

    /// The HD thumbnail is our graph, not the camera's JPEG: its key must follow the decoder version
    /// and the four NR/detail amounts, or a switch would keep serving the default decoder's picture.
    func testHDKeyMovesWithTheDocumentsDecoderVersionAndDetail() {
        let neutral = ThumbKey.hd(contentHash: "abc", document: .neutral)
        var versioned = EditModel.neutral
        versioned.decoderVersion = "9.dng"
        var detailed = EditModel.neutral
        detailed.detailSettings = DetailSettings(luminanceNR: 30, colorNR: 70,
                                                  sharpness: 20, detail: 60)
        let v9 = ThumbKey.hd(contentHash: "abc", document: versioned)
        let nr = ThumbKey.hd(contentHash: "abc", document: detailed)

        XCTAssertNotEqual(neutral.digest, v9.digest, "v9 must be a different HD thumbnail")
        XCTAssertNotEqual(neutral.digest, nr.digest, "the detail amounts must move the HD thumbnail")
        XCTAssertNotEqual(v9.digest, nr.digest, "version and detail are independent inputs")
        XCTAssertNotEqual(ThumbRecipe.editFingerprint(.neutral),
                          ThumbRecipe.editFingerprint(versioned))
        XCTAssertNotEqual(ThumbRecipe.editFingerprint(.neutral),
                          ThumbRecipe.editFingerprint(detailed))
        // The default document is unchanged, so every pre-change HD key still hits.
        XCTAssertEqual(neutral, ThumbKey.hd(contentHash: "abc", document: EditModel.neutral))
    }

    /// The measured half: two HD files for the same RAW and the same exposure, one document asking
    /// for `9.dng`. The key must move **and** the bytes must differ — the producer must pass the
    /// version into `DecodeOptions`, not just name it in the key.
    func testHDThumbnailPixelsFollowTheDocumentsDecoderVersion() throws {
        let url = try rawURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        var v8 = EditModel.neutral
        v8.light.exposure = 0.5
        var v9 = v8
        v9.decoderVersion = "9.dng"

        let provider = try ThumbnailProvider(cache: cache())
        let first = try generateHD(display: ImageSize(width: 326, height: 242),
                                   document: v8, provider: provider)
        let second = try generateHD(display: ImageSize(width: 326, height: 242),
                                    document: v9, provider: provider)

        print("THUMB decoder · v8 \(first.key.digest.prefix(16)) \(first.data.count) bytes"
              + " · v9 \(second.key.digest.prefix(16)) \(second.data.count) bytes")
        XCTAssertNotEqual(first.key.digest, second.key.digest,
                          "the HD key must move with decoderVersion")
        XCTAssertNotEqual(first.data, second.data,
                          "the HD file is still the default decoder's picture")
    }

    /// 2 — three views, one file: the HD key ignores the per-cell tier, so a 256 px grid cell, a
    /// 34 pt list row and a filmstrip cell all resolve to the same path.
    func testTheThreeViewsResolveToOneCacheFilePath() throws {
        let a = asset()
        let provider = ThumbnailProvider(cache: try cache())
        let grid = ThumbnailProvider.hdKey(for: a, document: .neutral)
        let list = ThumbnailProvider.hdKey(for: a, document: .neutral)
        let strip = ThumbnailProvider.hdKey(for: a, document: .neutral)

        XCTAssertEqual(grid.digest, list.digest)
        XCTAssertEqual(grid.digest, strip.digest)
        let path = provider.cache.url(for: grid).path
        XCTAssertEqual(path, provider.cache.url(for: list).path)
        XCTAssertEqual(path, provider.cache.url(for: strip).path)
        XCTAssertTrue(path.hasSuffix(".heic"))
        XCTAssertTrue(path.contains("/hd/"))
        print("223 same file: \(path)")
    }

    // MARK: - 2. file parameters

    /// 311 — the HD file is one **1920 8-bit Display P3 PQ JPEG**, and the loupe's stand-in reads
    /// that same file. The HEIC family it used to be (10-bit, plus a second encode per render) is
    /// retired: the assertions that mattered are kept — PQ transfer, P3 primaries, no gain map, and
    /// real light above SDR white — and only the container/depth changed.
    @available(macOS 15.0, *)
    func testGeneratedFileIsEightBitDisplayP3PQJPEGWithNoGainMap() throws {
        let generated = try generateHD()
        let data = generated.data
        let path = generated.provider.cache.url(for: generated.key)

        XCTAssertEqual(generated.key.spec, .hdJPEG, "311: the HD family is the JPEG")
        XCTAssertTrue(path.path.hasSuffix(".jpg"))
        XCTAssertTrue(ThumbnailJPEG.looksComplete(data), "container must be a JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1, "one primary image, no second one")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyDepth] as? NSNumber)?.intValue, 8, "8-bit JPEG")

        let primary = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(primary.width, primary.height), 1920, "long edge ≤ 1920")
        XCTAssertEqual(primary.bitsPerComponent, 8, "bitsPerComponent \(primary.bitsPerComponent)")

        // The colour space is the file's, read through the same Core Image door the cells use.
        let ci = try XCTUnwrap(CIImage(contentsOf: path))
        XCTAssertEqual(ci.colorSpace?.name, CGColorSpace.displayP3_PQ,
                       "Display P3 primaries + PQ curve, not Rec.2020")

        // No gain map: 218 wrote an ISO RGB auxiliary image; 223 writes a single primary item.
        if #available(macOS 15.0, *) {
            XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source, 0, kCGImageAuxiliaryDataTypeISOGainMap), "no ISO gain map")
        }
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap), "no Apple gain map")

        // And the 8-bit PQ codes really carry extended-range light: the stand-in's float peak ≥ 1.8
        // for a source with > 2.0 stops of headroom (311's acceptance number; it was 1.05 when the
        // file was 10-bit, which is why the check got stricter rather than weaker).
        let standIn = try XCTUnwrap(ThumbnailProvider.decodeHDForPlaceholder(data))
        XCTAssertEqual(standIn.bitsPerComponent, 16, "the stand-in decodes to the EDR exit")
        let filePeak = try peak(of: standIn)
        XCTAssertGreaterThanOrEqual(filePeak, 1.8,
                                    "the PQ file must carry light above SDR white (peak \(filePeak))")

        print("311 file: \(primary.width)×\(primary.height) depth \(primary.bitsPerComponent)"
              + " JPEG \(data.count) bytes · stand-in peak \(filePeak)")
    }

    /// A P3 primary is **outside** sRGB: converting a pure P3 red to linear sRGB gives R > 1 and a
    /// negative green. If the file merely carried a P3 *label* over sRGB samples, it would land on
    /// (1, 0, 0) and the sRGB rendering would be saturated red; the measured numbers say otherwise.
    @available(macOS 15.0, *)
    func testP3PrimariesAreRealNotJustATag() throws {
        let url = root.appendingPathComponent("p3-red.heic")
        try writeSyntheticPQ(linear: { _, _ in (1.0, 0.0, 0.0) },
                              width: 64, height: 64, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(CIImage(contentsOf: url)?.colorSpace?.name, CGColorSpace.displayP3_PQ)

        let decoded = try XCTUnwrap(ThumbnailProvider.decodeHD(
            data, display: ImageSize(width: 64, height: 64)))
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let linearSRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

        // Extend the same P3 samples through the sRGB primaries, without clipping.
        let convert = CIContext(options: [.workingColorSpace: p3, .workingFormat: CIFormat.RGBAh,
                                          .outputColorSpace: linearSRGB])
        let converted = try XCTUnwrap(convert.createCGImage(CIImage(cgImage: decoded),
                                                           from: CGRect(x: 0, y: 0, width: 64, height: 64),
                                                           format: .RGBAh, colorSpace: linearSRGB))
        let rgb = try floats(of: converted, colorSpace: linearSRGB, width: 64, height: 64)
        XCTAssertGreaterThan(rgb.r, 1.05, "P3 red is above sRGB's gamut (linear R \(rgb.r))")
        XCTAssertLessThan(rgb.g, 0, "P3 red needs a negative sRGB green (\(rgb.g))")

        // Rendering that red as sRGB must lose saturation. The file declares PQ headroom; a viewer
        // that honours it (Core Graphics does, on an SDR target) rolls the out-of-gamut red off —
        // a pure sRGB red would stay at 255. 208 is the measured value for P3 red.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let primary = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let declared = primary.contentHeadroom > 1 ? primary.contentHeadroom : 1
        let toneMapped = CGImageCreateCopyWithContentHeadroom(declared, decoded) ?? decoded
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                                    bitsPerComponent: 8, bytesPerRow: 64 * 4, space: srgb,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(toneMapped, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let red = Int(bytes[(32 * 64 + 32) * 4])
        XCTAssertLessThan(red, 240, "P3 red rendered as sRGB is \(red), not a saturated 255")
        print("223 P3 proof: linear-sRGB R \(rgb.r) G \(rgb.g) · sRGB code \(red)")
    }

    // MARK: - 3. display-sized decode + counters

    /// 311 — the cells decode the **JPEG**, by ImageIO's thumbnail door at the cell's own pixels
    /// (308's measurement: 14.7 ms to 512 vs the HEIC's 183 ms). What this pins is unchanged in
    /// spirit: the bitmap is exactly the cell's pixels, in float extended linear P3, and it is
    /// **one** decode per disk hit — never a whole-image decode plus a resize.
    func testDecodeAtEachCellSizeMatchesDisplayPixels() throws {
        let generated = try generateHD()
        let data = generated.data

        let sizes = [ImageSize(width: 68, height: 68),          // browser list, 34 pt @2×
                     ImageSize(width: Int((WorkspaceLayout.filmstripCell.width * 2).rounded()),
                               height: Int(((WorkspaceLayout.filmstripCell.height
                                             - WorkspaceLayout.filmstripCaptionHeight) * 2).rounded())),
                                                            // filmstrip, 90×60 pt @2×
                     ImageSize(width: 326, height: 242)]        // grid, common 163×121 pt @2×
        // The picture's own aspect, straight from the file.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let fileW = try XCTUnwrap((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let fileH = try XCTUnwrap((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        let pictureAspect = Double(fileW) / Double(fileH)
        for size in sizes {
            let image = try XCTUnwrap(ThumbnailProvider.decodeJPEG(data, display: size))
            // ImageIO's thumbnail door honours `kCGImageSourceThumbnailMaxPixelSize`: the bitmap's
            // **long** edge is the display's, and the picture's own aspect is kept (the cell's
            // surface does the aspect-fill, as it always did). It returns the file's own form:
            // 8-bit PQ, tagged with the file's PQ profile.
            XCTAssertEqual(max(image.width, image.height), max(size.width, size.height),
                           "long edge = display's long edge")
            let imageAspect = Double(image.width) / Double(image.height)
            XCTAssertEqual(imageAspect, pictureAspect, accuracy: pictureAspect * 0.05,
                           "aspect follows the picture, not the slot")
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3_PQ,
                           "the JPEG's own PQ tag survives the decode")
            XCTAssertEqual(image.bitsPerComponent, 8)
            print("311 decode \(image.width)×\(image.height) for \(size.width)×\(size.height)")
        }

        // A second provider on the same cache has no memory layer, so this request must go
        // disk → decode. The counter is the evidence of which door served it.
        let provider = ThumbnailProvider(cache: try cache())
        provider.resetStats()
        let done = expectation(description: "second decode")
        let display = ImageSize(width: 326, height: 242)
        provider.request(index: 0, asset: asset(), fileURL: try rawURL(),
                         document: equalEdit(exposure: 1), tier: .t256, spec: .hd,
                         display: display) { _, key, image in
            XCTAssertEqual(key.spec, .hdJPEG, "311: a `.hd` ask lands on the JPEG family")
            XCTAssertEqual(image?.width, display.width)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let stats = provider.stats
        XCTAssertEqual(stats.imageIOWholeDecodes, 0,
                       "the whole JPEG must not be decoded and resized by hand")
        XCTAssertEqual(stats.gpuDecodes, 0, "311: no HEIC → no Core Image → Metal cell decode")
        XCTAssertEqual(stats.hdJPEGDecodes, 1, "one disk hit ⇒ one ImageIO thumbnail decode")
        print("311 counters: imageIO whole \(stats.imageIOWholeDecodes) · jpeg \(stats.hdJPEGDecodes)")
    }

    // MARK: - 4. HDR is really on screen

    @available(macOS 15.0, *)
    @MainActor
    func testTheCellLayerIsCAMetalAndKeepsFloatPixels() throws {
        let generated = try generateHD()
        let display = ImageSize(width: 326, height: 242)
        let image = try XCTUnwrap(ThumbnailProvider.decodeHD(generated.data, display: display))

        let view = ThumbnailEDRView(cornerRadius: 6)
        view.frame = NSRect(x: 0, y: 0, width: 326, height: 242)
        view.image = image
        let metal = try XCTUnwrap(view.layer as? CAMetalLayer,
                                  "227: the thumbnail surface is a CAMetalLayer")

        // 227 — a CAMetalLayer does not tone map: EDR 1.0 stays SDR white, values above 1 use the
        // current headroom. A CALayer with EDR contents lifted reference white to the panel max.
        XCTAssertTrue(metal.wantsExtendedDynamicRangeContent, "CAMetalLayer opts into EDR headroom")
        XCTAssertEqual(metal.pixelFormat, .rgba16Float, "half-float drawable, so >1 survives")
        XCTAssertEqual(metal.colorspace?.name, CGColorSpace.extendedLinearDisplayP3)
        XCTAssertTrue(metal.framebufferOnly)
        XCTAssertFalse(metal.isOpaque, "rounded corners stay transparent over the card")

        let contents = try XCTUnwrap(view.image, "the view holds the decoded float image")
        XCTAssertEqual(contents.width, display.width)
        XCTAssertEqual(contents.height, display.height)
        XCTAssertGreaterThanOrEqual(contents.contentHeadroom, 1.05,
                                    "the measured peak is attached, not ImageIO's default")

        let peak = try peak(of: contents)
        XCTAssertGreaterThanOrEqual(peak, 1.05,
                                    "the in-memory pixels still reach \(peak) × SDR white")
        print("227 CAMetal layer: peak \(peak) · headroom \(contents.contentHeadroom) · "
              + "pixelFormat \(metal.pixelFormat.rawValue)")
    }

    /// 227 — the CAMetalLayer pass itself: the float texture must reach the drawable upright and
    /// without clamping the >1 highlights to SDR. (A real screen can only be judged by eye; this is
    /// the pipeline's geometry and values.)
    @available(macOS 15.0, *)
    @MainActor
    func testTheMetalSurfaceKeepsUprightAndHDRValues() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else {
            throw XCTSkip("no Metal device")
        }
        let w = 64, h = 64
        var halves = [UInt16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let top = y < h / 2
                // Top half red at 4× SDR white, bottom half blue at 1× — both orientation and HDR.
                halves[i] = top ? Float16(4).bitPattern : 0
                halves[i + 1] = 0
                halves[i + 2] = top ? 0 : Float16(1).bitPattern
                halves[i + 3] = Float16(1).bitPattern
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes: halves,
                                                              count: halves.count * 2) as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 16,
                                          bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                                          bitmapInfo: bitmapInfo, provider: provider,
                                          decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let view = ThumbnailEDRView(cornerRadius: 0)
        view.frame = NSRect(x: 0, y: 0, width: w, height: h)
        view.image = image
        view.layoutSubtreeIfNeeded()

        let texture = try XCTUnwrap(view.renderForTesting(width: w, height: h),
                                    "the CAMetalLayer pass produced a texture")
        var out = [UInt16](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 8,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let i = (y * w + x) * 4
            return (Float(Float16(bitPattern: out[i])),
                    Float(Float16(bitPattern: out[i + 1])),
                    Float(Float16(bitPattern: out[i + 2])))
        }
        let top = pixel(w / 2, 0)
        let bottom = pixel(w / 2, h - 1)
        XCTAssertEqual(top.0, 4, accuracy: 0.1, "top row is the 4× red half (not flipped)")
        XCTAssertEqual(top.2, 0, accuracy: 0.01)
        XCTAssertEqual(bottom.2, 1, accuracy: 0.02, "bottom row is the blue half")
        XCTAssertEqual(bottom.0, 0, accuracy: 0.01)
        print("227 CAMetal pass: top \(top) · bottom \(bottom)")
    }

    /// 227 — the layer must actually receive a drawable in a real window (the offscreen test proves
    /// the shader, this proves `nextDrawable` on the shipped view).
    @available(macOS 15.0, *)
    @MainActor
    func testTheMetalSurfacePresentsToARealWindow() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable, !NSScreen.screens.isEmpty else {
            throw XCTSkip("no Metal device or no screen")
        }
        let w = 64, h = 64
        var halves = [UInt16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: halves.count, by: 4) {
            halves[i] = Float16(0.18).bitPattern
            halves[i + 1] = Float16(0.18).bitPattern
            halves[i + 2] = Float16(0.18).bitPattern
            halves[i + 3] = Float16(1).bitPattern
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes: halves,
                                                              count: halves.count * 2) as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 16,
                                          bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                                          bitmapInfo: bitmapInfo, provider: provider,
                                          decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))

        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = host
        let view = ThumbnailEDRView(cornerRadius: 6)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.addSubview(view)
        view.image = image
        TestWindows.show(window)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(view.presentedFramesForTesting, 0,
                             "the CAMetalLayer received a drawable")
        XCTAssertFalse(view.isHidden, "the view unhides only after the new drawable landed")
        window.orderOut(nil)
    }

    // MARK: - 5. SDR stays correct

    @available(macOS 15.0, *)
    func testSDRTargetKeepsNeutralGreyAndClipsThePeak() throws {
        let url = root.appendingPathComponent("sdr-check.heic")
        // Four vertical bands: 18 % grey, SDR white, 4× white, black.
        try writeSyntheticPQ(linear: { x, _ in
            switch x {
            case 0..<16: return (0.18, 0.18, 0.18)
            case 16..<32: return (1.0, 1.0, 1.0)
            case 32..<48: return (4.0, 4.0, 4.0)
            default: return (0.0, 0.0, 0.0)
            }
        }, width: 64, height: 64, to: url)
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(ThumbnailProvider.decodeHD(data,
                                                             display: ImageSize(width: 64, height: 64)))
        let peak = try peak(of: image)
        XCTAssertGreaterThanOrEqual(peak, 1.05, "the float image still carries the highlight")

        // The SDR target: a plain colour conversion to 8-bit sRGB (the same conversion Core Graphics
        // performs when there is no EDR surface). No tone-map curve is applied by this test, so the
        // numbers say exactly what the file's reference white decodes to.
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CIContext(options: [.workingColorSpace: p3, .workingFormat: CIFormat.RGBAf])
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!,
                           rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                           format: .RGBA8, colorSpace: srgb)
        }
        let grey = Int(bytes[(32 * 64 + 8) * 4])
        let white = Int(bytes[(32 * 64 + 24) * 4])
        let highlight = Int(bytes[(32 * 64 + 40) * 4])
        // sRGB encode(0.18) = 118. ±2 codes is the spec's allowance.
        XCTAssertLessThanOrEqual(abs(grey - 118), 2, "18 % grey must not move (got \(grey))")
        XCTAssertEqual(white, 255, "reference white lands on SDR white")
        XCTAssertEqual(highlight, 255, "the 4× highlight is clipped at 1.0, not wrapped")
        print("223 SDR: grey \(grey) · white \(white) · 4× \(highlight) · float peak \(peak)")
    }

    // MARK: - 6. hits and performance

    func testTwoHundredMemoryHitsDecodeNothing() throws {
        let generated = try generateHD()
        let provider = generated.provider
        let a = asset()
        let display = ImageSize(width: 326, height: 242)
        provider.resetStats()

        // 311 — the key the producer filled is the JPEG family's.
        let key = ThumbnailProvider.hdJPEGKey(for: a, document: equalEdit(exposure: 1))
        for _ in 0..<200 {
            XCTAssertNotNil(provider.serveFromMemory(for: key, display: display))
        }
        let stats = provider.stats
        XCTAssertEqual(stats.memoryHits, 200)
        XCTAssertEqual(stats.decodes, 0, "200 cells served from the memory LRU must decode 0 images")
        XCTAssertEqual(stats.diskHits, 0)
    }

    func testColdGridDecodeIsGPUAndUnderEightMilliseconds() throws {
        let generated = try generateHD()
        let data = generated.data
        let display = ImageSize(width: 326, height: 242)
        _ = try XCTUnwrap(ThumbnailProvider.decodeHD(data, display: display))   // warm-up

        var times: [Double] = []
        for _ in 0..<15 {
            let start = CFAbsoluteTimeGetCurrent()
            let image = ThumbnailProvider.decodeHD(data, display: display)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            XCTAssertEqual(image?.width, display.width)
        }
        times.sort()
        let p50 = times[times.count / 2]
        let p90 = times[Int(Double(times.count) * 0.9)]
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        print(String(format: "223 1920 P3-PQ → 326 px float: p50 %.2f ms · p90 %.2f ms · load %.2f",
                     p50, p90, load[0]))
        // ImageIO's HEVC path measures 79–100 ms for this same file, so anything in the single-digit
        // range is the Core Image → Metal path. The spec's 8 ms budget is stated for an idle machine
        // (load < 4); this lane shares the host with other agents, so above that load we assert the
        // "not ImageIO" bound and print the number instead of pretending the precondition held.
        if load[0] < 4 {
            XCTAssertLessThanOrEqual(p50, 8.0, "p50 \(p50) ms on an idle machine")
        } else {
            XCTAssertLessThanOrEqual(p50, 40.0,
                                     "p50 \(p50) ms must still be far below ImageIO's 79–100 ms")
        }
    }

    func testTwoHundredDisplayBitmapsFitInThreeHundredMegabytes() throws {
        let generated = try generateHD()
        let data = generated.data
        let display = ImageSize(width: 326, height: 242)
        let before = footprint()

        var images: [CGImage] = []
        images.reserveCapacity(200)
        for _ in 0..<200 {
            autoreleasepool {
                if let image = ThumbnailProvider.decodeHD(data, display: display) {
                    images.append(image)
                }
            }
        }
        XCTAssertEqual(images.count, 200)
        let after = footprint()
        let deltaMB = Double(after > before ? after - before : 0) / (1024 * 1024)
        print(String(format: "223 200 cells @326×242: footprint Δ%.0f MB", deltaMB))
        XCTAssertLessThanOrEqual(deltaMB, 300, "200 display-sized float bitmaps must stay ≤ 300 MB")
        XCTAssertEqual(images.count, 200)
    }

    // MARK: - helpers

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Centre pixel of a half-float extended-linear-P3 image, read through Core Image.
    private func floats(of image: CGImage, colorSpace: CGColorSpace,
                        width: Int, height: Int) throws -> (r: Float, g: Float, b: Float) {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: colorSpace,
                                          .workingFormat: CIFormat.RGBAf])
        pixels.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        let i = ((height / 2) * width + width / 2) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// max(R,G,B) of an extended-linear-P3 float image, read through Core Image.
    private func peak(of image: CGImage) throws -> Double {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let width = image.width, height = image.height
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf])
        pixels.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: space)
        }
        var maximum: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            maximum = max(maximum, max(pixels[i], max(pixels[i + 1], pixels[i + 2])))
        }
        return Double(maximum)
    }
}
