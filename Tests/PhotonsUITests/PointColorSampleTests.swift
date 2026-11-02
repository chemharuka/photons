import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 256 — 点颜色取样的是**屏幕上那一帧的 S3.6b 输入**，不是解码缓存。
///
/// The suite is the acceptance in executable form:
///
///   1. **Determinism**: two clicks on one pixel of one frame give bit-identical RGB.
///   2. **The edit is in the sample**: +1 EV changes the sampled chroma.
///   3. **Screen alignment**: a known red patch samples red; a neutral patch is refused by the model.
///   4. **No fallback**: a click before the first frame reports `.notReady` and writes nothing.
///   5. **No whole-frame render and no decode**: the probe leaves `editRenderCount`,
///      `RAWDecoder.decodeCounts()` and `lastFrame` untouched, and stays under the probe budget.
///   6. **One pixel, said out loud**: the hint names `读数 1 px · S3.6b 输入`.
///
/// The chart is the repo's 512 × 512 synthetic 256-patch DNG (`tools/wb-calibrate/chart256.dng`),
/// so the test always runs; the real-photo A/B is the opt-in report at the end.
@MainActor
final class PointColorSampleTests: XCTestCase {

    private static let viewport = ImageSize(width: 800, height: 600)
    private static let decodeScale: Float = 1

    private var chartURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/wb-calibrate/chart256.dng")
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeLoupe(_ session: CatalogSession) -> LoupeController {
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    @discardableResult
    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel,
                         scale: Float = 1) throws -> LoupeController.FrameResult {
        loupe.frameSource = LoupeController.FrameSource(url: url,
                                                        identity: url.lastPathComponent,
                                                        viewport: Self.viewport,
                                                        edit: edit)
        let frame = try loupe.makeFrame(url: url, viewport: Self.viewport,
                                        decodeScale: scale, edit: edit)
        loupe.installFrameForTesting(frame)
        return frame
    }

    private func point(_ loupe: LoupeController, sourceX: Double, sourceY: Double) throws -> CGPoint {
        try XCTUnwrap(loupe.viewPoint(forSourcePoint: (x: sourceX, y: sourceY)),
                      "the chart's \(sourceX),\(sourceY) is not on the canvas")
    }

    private func swatch(_ rgb: RGBSample) -> PointColor {
        let yuv = PointColor.sampleYUV(fromWorkingLinear: rgb)
        return PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    // MARK: - 1 / 5 / 6. determinism, no frame render, the hint

    func testTwoClicksOnOnePixelAreBitIdenticalAndCostNoFrame() throws {
        let url = chartURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("chart fixture missing: \(url.path)")
        }
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        let click = try point(loupe, sourceX: 368, sourceY: 112)

        let renders = loupe.editRenderCount
        let decodes = decodeTotal()
        let frameIdentity = ObjectIdentifier(frame.texture)
        var samples: [LoupeController.PointColorDropperSample] = []
        var hint = ""
        for _ in 0..<5 {
            let outcome = loupe.sampleForPointColor(atViewPoint: click)
            guard case .sampled(let sample) = outcome else {
                return XCTFail("expected a sample")
            }
            hint = outcome.hint
            samples.append(sample)
        }

        let a = try XCTUnwrap(samples.first)
        for b in samples.dropFirst() {
            XCTAssertEqual(a.rgb, b.rgb, "same frame, same pixel ⇒ same bytes")
            XCTAssertEqual(a.contentX, b.contentX)
            XCTAssertEqual(a.contentY, b.contentY)
        }
        XCTAssertEqual(loupe.editRenderCount, renders, "the probe is not a frame")
        XCTAssertEqual(decodeTotal(), decodes, "the probe does not decode")
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(loupe.lastFrame).texture), frameIdentity,
                       "the frame on screen is still the frame that was measured")
        XCTAssertEqual(loupe.pointColorProbeCount, samples.count)
        XCTAssertTrue(hint.contains("1 px") && hint.contains("S3.6b"),
                      "the hint must say which sample this is: \(hint)")

        let times = samples.map(\.milliseconds).sorted()
        let median = times[times.count / 2]
        print(String(format: "POINT SAMPLE · %d clicks @%d,%d · RGB %@ · probe min %.3f / median %.3f"
                     + " / max %.3f ms · hint “%@”",
                     samples.count, a.contentX, a.contentY, a.rgb.text,
                     times.first ?? 0, median, times.last ?? 0, hint))
        // The **minimum** is the probe's own cost; a loaded test process adds scheduling noise to
        // individual clicks, which is not a regression in the probe. A steady >5 ms still fails,
        // because then even the best of five is over budget.
        XCTAssertLessThanOrEqual(times.first ?? .infinity, 5.0,
                                 "debug probe budget is 5 ms (release 2 ms), measured \(times)")
    }

    // MARK: - 2. the sample follows the edit

    func testAddingExposureMovesTheSampledChroma() throws {
        let url = chartURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("chart fixture missing: \(url.path)")
        }
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)
        // A mid-bright saturated red patch (row 3, col 9): +1 EV does not clip it into white.
        let click = try point(loupe, sourceX: 304, sourceY: 112)

        guard case .sampled(let beforeSample) = loupe.sampleForPointColor(atViewPoint: click) else {
            return XCTFail("no baseline sample")
        }
        let before = swatch(beforeSample.rgb)

        var exposed = session.edit
        exposed.light.exposure = 1
        _ = try develop(loupe, url, exposed)
        guard case .sampled(let afterSample) = loupe.sampleForPointColor(atViewPoint: click) else {
            return XCTFail("no exposed sample")
        }
        let after = swatch(afterSample.rgb)

        print(String(format: "POINT EXPOSURE · H %.2f°/%.2f° · C %.4f → %.4f (ΔC %.4f)",
                     before.sampleHue, after.sampleHue,
                     before.sampleChroma, after.sampleChroma,
                     abs(after.sampleChroma - before.sampleChroma)))
        XCTAssertGreaterThan(abs(after.sampleChroma - before.sampleChroma), 1e-4,
                             "exposure is upstream of S3.6b; the sample must move")
    }

    // MARK: - 3. screen alignment

    func testRedPatchSamplesRedAndNeutralPatchIsRefused() throws {
        let url = chartURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("chart fixture missing: \(url.path)")
        }
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)

        let redClick = try point(loupe, sourceX: 304, sourceY: 112)
        guard case .sampled(let redSample) = loupe.sampleForPointColor(atViewPoint: redClick) else {
            return XCTFail("no red sample")
        }
        let red = swatch(redSample.rgb)
        var delta = red.sampleHue.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        print(String(format: "POINT RED · H %.2f° C %.3f", red.sampleHue, red.sampleChroma))
        // The chart's red is an HSV red; in OKLCh that is ≈20°, so the screen-alignment claim here
        // is "in the red half of the circle and red-dominant". The strict 0°/360° ±10° quadrant is
        // `PointColorProbeTests.testQuadrantsSampleTheColoursTheScreenShows`, whose fixture is built
        // at OKLCh hue 0.
        XCTAssertGreaterThanOrEqual(delta, -10)
        XCTAssertLessThanOrEqual(delta, 45)
        XCTAssertGreaterThan(red.sampleChroma, PointColor.chromaFloorYCbCr)
        XCTAssertGreaterThan(redSample.rgb.r, redSample.rgb.g)
        XCTAssertGreaterThan(redSample.rgb.r, redSample.rgb.b)

        // A neutral step of the chart (row 1, col 0). The model — not this test — refuses it.
        let neutralClick = try point(loupe, sourceX: 16, sourceY: 48)
        guard case .sampled(let neutralSample) = loupe.sampleForPointColor(
            atViewPoint: neutralClick) else {
            return XCTFail("no neutral sample")
        }
        let commands = PointColorCommands(session: session)
        let base = session.history.count
        XCTAssertEqual(commands.sampleForPointColor(workingLinear: neutralSample.rgb),
                       .rejectedLowChroma, "a near-grey pixel creates no swatch")
        XCTAssertEqual(session.history.count, base, "…and writes no history")
    }

    func testTheLetterboxAndAnEmptyFrameAreNotSampled() throws {
        let url = chartURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("chart fixture missing: \(url.path)")
        }
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)

        let before = session.history.count
        XCTAssertEqual(loupe.sampleForPointColor(atViewPoint: CGPoint(x: 4, y: 300)),
                       .outsideImage, "the chart is square in a 4:3 viewport: 4,300 is letterbox")
        XCTAssertEqual(session.history.count, before)

        // No frame at all: the probe has nothing to read and must not fall back to the decode.
        let emptySession = CatalogSession()
        let empty = makeLoupe(emptySession)
        let emptyHistory = emptySession.history.count
        var reported: [LoupeController.PointColorDropperOutcome] = []
        empty.armPointColorEyedropper { reported.append($0) }
        XCTAssertNil(empty.handleEyedropperClick(atViewPoint: CGPoint(x: 200, y: 150)))
        XCTAssertEqual(reported, [.notReady])
        XCTAssertEqual(reported.first?.hint, "画面尚未就绪，未取样")
        XCTAssertEqual(emptySession.history.count, emptyHistory, "not ready writes no history")
        XCTAssertTrue(empty.isEyedropperArmed, "a miss leaves the point dropper armed")
    }

    // MARK: - 7. grid vs one pixel (the report)

    /// The numeric comparison the task asks for: the 256-grid readout vs the 1 px S3.6b probe.
    /// Prints ΔH (degrees) and ΔC at three chart points and three real-photo points.
    func testGridVersusOnePixelReport() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_POINT_COLOR_REPORT"] == "1" else {
            throw XCTSkip("set PHOTONS_POINT_COLOR_REPORT=1 to print the grid-vs-1px table")
        }
        let chart = chartURL
        guard FileManager.default.isReadableFile(atPath: chart.path) else {
            throw XCTSkip("chart fixture missing")
        }
        try reportGridVersusPixel(label: "chart", url: chart, scale: 1,
                                  cells: [(304, 112), (48, 240), (176, 368)])
        let real = try fixtureURL()
        try reportGridVersusPixel(label: "L1030433", url: real, scale: 0.125, cells: [])

        // The cost gate on a ~3.8 Mpx frame with contrast and dehaze live: both statistics proxies
        // were built by the frame, so the probe should hit their caches and stay a small render.
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        var edit = session.edit
        edit.light.contrast = 30
        edit.effects.dehaze = 20
        let frame = try develop(loupe, real, edit, scale: 0.25)
        let click = try point(loupe, sourceX: Double(frame.content.width) / 2,
                              sourceY: Double(frame.content.height) / 2)
        guard case .sampled(let sample) = loupe.sampleForPointColor(atViewPoint: click) else {
            return XCTFail("no probe on the cost fixture")
        }
        print(String(format: "  cost · frame %d×%d = %.2f Mpx · probe %.3f ms",
                     frame.canvas.width, frame.canvas.height,
                     Double(frame.canvas.width * frame.canvas.height) / 1_000_000,
                     sample.milliseconds))
        XCTAssertLessThanOrEqual(sample.milliseconds, 5.0, "debug probe budget")
    }

    private struct Comparison {
        let sourceX: Double
        let sourceY: Double
        let precise: PointColor
        let coarse: PointColor
        var dh: Double {
            var d = (precise.sampleHue - coarse.sampleHue).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        var dc: Double { precise.sampleChroma - coarse.sampleChroma }
    }

    private func reportGridVersusPixel(label: String, url: URL, scale: Float,
                                       cells: [(sourceX: Double, sourceY: Double)]) throws {
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit, scale: scale)
        let grid = try XCTUnwrap(frame.sceneLinearSample, "no 256-grid in the frame")
        let lattice = PointerSampleLattice(picture: frame.photoRect, grid: grid.size)

        func compare(sourceX: Double, sourceY: Double) throws -> Comparison? {
            guard let view = loupe.viewPoint(forSourcePoint: (x: sourceX, y: sourceY)) else {
                return nil
            }
            guard case .sampled(let precise) = loupe.sampleForPointColor(atViewPoint: view) else {
                return nil
            }
            guard let texel = loupe.textureTexel(forViewPoint: view) else { return nil }
            let gridTexel = lattice.gridTexel(forTextureX: texel.x, y: texel.y)
            guard let coarse = grid.texel(x: gridTexel.x, y: gridTexel.y) else { return nil }
            return Comparison(sourceX: sourceX, sourceY: sourceY,
                              precise: swatch(precise.rgb),
                              coarse: swatch(RGBSample(r: Double(coarse.red),
                                                       g: Double(coarse.green),
                                                       b: Double(coarse.blue))))
        }

        func printRow(_ c: Comparison) {
            print(String(format: "  %@ %4.0f,%-4.0f · 1px H %6.1f° C %.3f · grid H %6.1f° C %.3f"
                         + " · ΔH %+7.2f° · ΔC %+.4f",
                         label, c.sourceX, c.sourceY,
                         c.precise.sampleHue, c.precise.sampleChroma,
                         c.coarse.sampleHue, c.coarse.sampleChroma, c.dh, c.dc))
        }

        // The named points, then — for a real photo — the three points of a systematic 12 × 8
        // source grid whose grid-vs-1px disagreement is largest. The second set is what shows why a
        // 256-cell lattice cannot be the point-colour sample: a small target is averaged with its
        // neighbours.
        for cell in cells {
            if let c = try compare(sourceX: cell.sourceX, sourceY: cell.sourceY) { printRow(c) }
        }
        guard label != "chart" else { return }
        /** A systematic scan; the top three are printed, not silently cherry-picked from the point
            list above. */
        guard let framing = loupe.framing() else { return }
        var scanned: [Comparison] = []
        for iy in 0..<8 {
            for ix in 0..<12 {
                let x = framing.sourceWidth * (Double(ix) + 0.5) / 12
                let y = framing.sourceHeight * (Double(iy) + 0.5) / 8
                if let c = try compare(sourceX: x, sourceY: y) { scanned.append(c) }
            }
        }
        // Only points with a real colour on both sides: a near-grey's hue angle is numerical noise,
        // not an error a user could see.
        let coloured = scanned.filter {
            max($0.precise.sampleChroma, $0.coarse.sampleChroma) > 2 * PointColor.chromaFloorYCbCr
        }
        let worst = coloured.sorted { abs($0.dc) > abs($1.dc) }.prefix(3)
        for c in worst { printRow(c) }
        let maxH = coloured.map { abs($0.dh) }.max() ?? 0
        let maxC = coloured.map { abs($0.dc) }.max() ?? 0
        print(String(format: "  %@ scan 12×8 · %d coloured · max |ΔH| %.2f° · max |ΔC| %.4f",
                     label, coloured.count, maxH, maxC))
    }
}
