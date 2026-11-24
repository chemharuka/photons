import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// 546 — **the 对比 「原图」 side must carry the document's geometry.**
///
/// 080 defined 「显示原图」(`\`) as the whole decode: no crop, no straighten, no turn, no keystone. 对比
/// then used the same decode on one side of the line, so a document with a crop / 90° turn / perspective
/// was two differently placed rectangles of the world inside one canvas — 「比较无意义」. The shipped
/// switch for the other spelling already existed (`RenderOptions.originalRendersAsParametersCleared`,
/// i.e. `EditModel.disregardingParameters`: geometry kept, parameters zeroed); this suite pins that 对比
/// now uses it, and that `\` still does not.
///
/// ① the two sides' picture **quads** are point-for-point equal and their canvases are the same size;
/// ② the parameters still differ: at one scene point, +1 EV on the edited side is not the cleared side;
/// ③ `\` is still the whole decode — its quad is not the geometry-kept compare quad (two paths, not one);
/// ④ the reverse gate: with the switch off, the same quads differ, and the numbers are printed.
///
/// Needs a RAW fixture (`PHOTONS_TEST_RAW`, else `~/Desktop/test/L1030433.dng`) and Metal; ④ is
/// synthetic and needs Metal only.
@MainActor
final class CompareOriginalKeepsGeometry546Tests: XCTestCase {

    private static let viewport = ImageSize(width: 1280, height: 800)
    private static let decodeScale: Float = 0.5

    // MARK: - fixtures

    private static func rawFixture() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        let fallback = URL(fileURLWithPath: NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: fallback.path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return fallback
    }

    private func makeLoupe() -> LoupeController {
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    /// The document the ticket names: perspective V **and** H, a crop, and one 90° turn. Its geometry
    /// is what a decode cannot reproduce, so it is the fixture that can tell the two spellings apart.
    private func geometryDocument(exposure: Double = 0) -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = exposure
        e.geometry = GeometryGroup(crop: NormalizedRect(x: 0.15, y: 0.12, width: 0.70, height: 0.66),
                                   rotationDegrees: 4,
                                   quarterTurns: 1,
                                   perspectiveVertical: 55,
                                   perspectiveHorizontal: -35)
        return e
    }

    private func frame(_ loupe: LoupeController, _ url: URL, _ edit: EditModel,
                       mode: LoupeFrameMode) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: Self.decodeScale,
                            edit: edit, mode: mode)
    }

    /// Three display-encoded channels of one texel, as the composite stores them.
    private func codes(_ texture: MTLTexture, x: Int, y: Int) -> [Float] {
        guard x >= 0, y >= 0, x < texture.width, y < texture.height else { return [] }
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return (0..<3).map { Float(Float16(bitPattern: raw[$0])) }
    }

    private func maxCornerDelta(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count else { return .infinity }
        var worst = 0.0
        for (p, q) in zip(a, b) {
            worst = max(worst, abs(Double(p.x) - Double(q.x)))
            worst = max(worst, abs(Double(p.y) - Double(q.y)))
        }
        return worst
    }

    private func assertQuadsEqual(_ a: [CGPoint], _ b: [CGPoint], _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, 4, "\(what): four corners", file: file, line: line)
        XCTAssertEqual(b.count, 4, "\(what): four corners", file: file, line: line)
        for i in 0..<min(a.count, b.count) {
            XCTAssertEqual(Double(a[i].x), Double(b[i].x), accuracy: 1e-9,
                           "\(what) corner \(i).x", file: file, line: line)
            XCTAssertEqual(Double(a[i].y), Double(b[i].y), accuracy: 1e-9,
                           "\(what) corner \(i).y", file: file, line: line)
        }
    }

    private func describe(_ quad: [CGPoint]) -> String {
        quad.map { String(format: "(%.3f,%.3f)", Double($0.x), Double($0.y)) }.joined(separator: " ")
    }

    // MARK: - ① 两侧四角逐点相等，画布同尺寸

    func testTheCompareOriginalKeepsPerspectiveCropAndQuarterTurn() throws {
        let url = try Self.rawFixture()
        let loupe = makeLoupe()
        let doc = geometryDocument()

        let edited = try frame(loupe, url, doc, mode: .edited)
        loupe.setCompare(true)
        let composed = try frame(loupe, url, doc, mode: loupe.frameMode)

        let quads = try XCTUnwrap(loupe.lastCompareQuadsForTesting,
                                  "a compare frame must record both sides' quads")
        let canvases = try XCTUnwrap(loupe.lastCompareCanvasesForTesting)
        XCTAssertEqual(canvases.original, canvases.edited,
                       "the two sides must render into one canvas")
        XCTAssertEqual(canvases.edited, composed.canvas)

        assertQuadsEqual(quads.original, quads.edited, "compare sides")
        print("COMPARE 546 original quad: \(describe(quads.original))")
        print("COMPARE 546 edited   quad: \(describe(quads.edited))")
        print("COMPARE 546 canvas \(canvases.original.width)×\(canvases.original.height), "
              + "edited frame canvas \(edited.canvas.width)×\(edited.canvas.height)")
    }

    // MARK: - ② 参数差异仍然可见

    /// The same scene point is read from the two sides: put the line at 0 (the pixel is the edited
    /// side) and at 1 (the same pixel is the original side). A point of the photograph is one point of
    /// the world either way, so a differing pixel is the parameters and nothing else.
    func testTheClearedSideStillDiffersFromAnExposedEdit() throws {
        let url = try Self.rawFixture()
        let loupe = makeLoupe()
        let doc = geometryDocument(exposure: 1)        // +1 EV on the edited side only

        loupe.setCompare(true)
        loupe.setCompareFraction(0)
        let editedSide = try frame(loupe, url, doc, mode: loupe.frameMode)
        let editedSplit = try XCTUnwrap(loupe.compareSplit)

        loupe.setCompareFraction(1)
        let originalSide = try frame(loupe, url, doc, mode: loupe.frameMode)
        let originalSplit = try XCTUnwrap(loupe.compareSplit)

        let canvas = editedSide.canvas
        XCTAssertEqual(originalSide.canvas, canvas)
        let rect = editedSide.photoRect
        let point = (x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        XCTAssertEqual(editedSplit.side(x: point.x, y: point.y, canvas: canvas), .edited)
        XCTAssertEqual(originalSplit.side(x: point.x, y: point.y, canvas: canvas), .original)

        let editedPixel = codes(editedSide.texture, x: point.x, y: point.y)
        let originalPixel = codes(originalSide.texture, x: point.x, y: point.y)
        XCTAssertEqual(editedPixel.count, 3)
        XCTAssertEqual(originalPixel.count, 3)
        let delta = zip(editedPixel, originalPixel).map { abs($0 - $1) }.max() ?? 0
        print("COMPARE 546 point \(point): edited(+1 EV)=\(editedPixel) "
              + "original(cleared)=\(originalPixel) maxΔ=\(String(format: "%.4f", delta))")
        XCTAssertNotEqual(editedPixel, originalPixel,
                          "the original side must be parameters-cleared, not a copy of the edit")
        XCTAssertGreaterThan(delta, 1.0 / 255.0,
                             "a +1 EV difference must be more than one 8-bit code")
    }

    // MARK: - ③ `\` 仍是整幅解码，不与对比合并

    func testShowOriginalIsStillTheWholeDecodeNotTheCompareSpelling() throws {
        let url = try Self.rawFixture()
        let loupe = makeLoupe()
        let doc = geometryDocument()

        let original = try frame(loupe, url, doc, mode: .original)
        let decodeQuad = try XCTUnwrap(loupe.lastFrameQuadForTesting)
        XCTAssertEqual(decodeQuad.count, 4)
        XCTAssertNil(loupe.lastCompareQuadsForTesting,
                     "`\\` is not the compare path and must not record compare sides")

        let edited = try frame(loupe, url, doc, mode: .edited)
        let editedQuad = try XCTUnwrap(loupe.lastFrameQuadForTesting)
        XCTAssertEqual(original.mode, .original)

        let delta = maxCornerDelta(decodeQuad, editedQuad)
        print("SHOW ORIGINAL 546 decode quad: \(describe(decodeQuad))")
        print("SHOW ORIGINAL 546 edited quad: \(describe(editedQuad)) maxΔ="
              + String(format: "%.3f", delta))
        // `\` keeps 080's semantics: the whole decode, so its corners are not the geometry-kept ones.
        // If the two paths were merged this would be 0.
        XCTAssertGreaterThan(delta, 1.0,
                             "`\\` must still be the decode, not the geometry-kept compare side")
    }

    // MARK: - ④ 反向门：开关关掉，四角对不上

    /// A synthetic frame (no RAW): the edited document and the parameters-cleared document must have
    /// the same quad, while the same document rendered as the **decode** (the pre-546 compare side)
    /// must not. The corner deltas are printed — they are the numbers ① asserts are zero.
    func testTheRefutationWithoutTheSwitchShowsTheCornersDiffer() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let doc = geometryDocument()
        let image = syntheticImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "compare-546"))

        let canvas = ImageSize(width: 480, height: 360)
        func options(_ source: RenderSource, _ naive: Bool) -> RenderOptions {
            RenderOptions(canvas: canvas, scale: 0.5,
                          display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
                          useCache: false, wantsPixels: true,
                          source: source, originalRendersAsParametersCleared: naive)
        }

        let edited = try graph.render(doc, options: options(.edited, false))
        let kept = try graph.render(doc, options: options(.decoded, true))
        let decode = try graph.render(doc, options: options(.decoded, false))

        let editedQuad = try XCTUnwrap(edited.photoQuad)
        let keptQuad = try XCTUnwrap(kept.photoQuad)
        let decodeQuad = try XCTUnwrap(decode.photoQuad)

        assertQuadsEqual(keptQuad, editedQuad, "switch on")
        let delta = maxCornerDelta(decodeQuad, editedQuad)
        print("REFUTATION 546 edited quad: \(describe(editedQuad))")
        print("REFUTATION 546 decode quad: \(describe(decodeQuad)) maxΔ="
              + String(format: "%.3f", delta))
        XCTAssertGreaterThan(delta, 1.0,
                             "with the switch off the shipping behaviour returns: the corners differ")
    }

    /// A small synthetic picture with structure; the quads are what this test reads, so the pixels only
    /// have to be a legal `LinearImage`.
    private func syntheticImage() -> LinearImage {
        let w = 300, h = 200
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let gx = Float(x) / Float(w - 1), gy = Float(y) / Float(h - 1)
                rgba[o] = Float16(0.02 + 1.2 * gx)
                rgba[o + 1] = Float16(0.02 + 1.0 * gy)
                rgba[o + 2] = Float16(0.05 + 0.8 * (1 - gx * gy))
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "compare-546")
    }
}
