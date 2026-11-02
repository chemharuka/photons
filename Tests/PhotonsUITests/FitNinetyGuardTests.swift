import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 234 — 「适应 = 90 %」的验收与防回退守卫.
///
/// 213 already put `fitMargin = 0.90` into `LoupeFraming.fitZoom`; this suite is about the **drawn**
/// result. The user's 2026-11-02 report is precise: the animation maths used 90 %, but the settled
/// 适应 picture was still drawn at 100 % of the viewport, so leaving an animation landed on a jump.
///
/// Three claims, all measured on a real editor window:
///
///  1. ordinary 适应 draws the photograph at **0.90** of the viewport (the constraining axis), and the
///     render's own camera (`FrameResult.zoom`) is the viewport fit × 0.90 — the two agree;
///  2. entering 裁切 is the same 0.90, not 0.81;
///  3. the > 6° whole-canvas re-fit is still the one 0.90, taking the smaller of the source AABB and
///     the crop AABB;
///
/// plus a structural guard on `fitMargin` and a reverse gate that shows the guard goes red when the
/// margin is 1.0 (a test-local copy — the production constant is never changed).
@MainActor
final class FitNinetyGuardTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-fit-ninety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 2.2.1 structural guard

    /// The one constant, and the arithmetic that reads it. The expected value is the **computed**
    /// viewport fit (1000 × 800 into 4000 × 3000), never a hard-coded 0.9×something.
    func testFitMarginIsNinetyAndFitZoomIsTheViewportFitTimesIt() {
        XCTAssertEqual(LoupeFraming.fitMargin, 0.90, accuracy: 1e-15,
                       "LoupeFraming.fitMargin is the one 适应 margin")

        let viewport = ImageSize(width: 1000, height: 800)
        let framing = LoupeFraming(viewport: viewport, sourceWidth: 4000, sourceHeight: 3000)
        let extent = framing.rotatedSourceExtent
        let viewportFit = min(Double(viewport.width) / extent.width,
                              Double(viewport.height) / extent.height)

        XCTAssertEqual(framing.fitZoom, viewportFit * LoupeFraming.fitMargin, accuracy: 1e-6,
                       "no crop, no rotation: fitZoom must be the computed viewport fit × 0.90")
        print(String(format: "234 · viewport fit %.9f × %.2f = %.9f · fitZoom %.9f",
                     viewportFit, LoupeFraming.fitMargin, viewportFit * LoupeFraming.fitMargin,
                     framing.fitZoom))
    }

    /// The reverse gate: the same guard with the margin replaced by 1.0 must be red. The margin is a
    /// parameter of a test-local copy of `fitZoom`'s arithmetic; the production constant is untouched.
    func testTheGuardGoesRedWhenTheMarginIsOne() {
        let viewport = ImageSize(width: 1000, height: 800)
        let framing = LoupeFraming(viewport: viewport, sourceWidth: 4000, sourceHeight: 3000)
        let extent = framing.rotatedSourceExtent
        let viewportFit = min(Double(viewport.width) / extent.width,
                              Double(viewport.height) / extent.height)
        let expected = viewportFit * LoupeFraming.fitMargin

        XCTAssertTrue(guardHolds(fitZoom(framing, margin: LoupeFraming.fitMargin), expected: expected),
                      "the guard must pass at the production margin")
        XCTAssertFalse(guardHolds(fitZoom(framing, margin: 1.0), expected: expected),
                       "the same guard must be red at margin 1.0 — otherwise it is not a guard")
        XCTAssertEqual(fitZoom(framing, margin: 1.0), viewportFit, accuracy: 1e-12,
                       "margin 1.0 is the un-margined viewport fit the user reported as fullscreen")
    }

    private func guardHolds(_ value: Double, expected: Double) -> Bool {
        abs(value - expected) <= 1e-6
    }

    /// A test-local copy of `LoupeFraming.fitZoom` with the margin injectable. Deliberately mirrors the
    /// production formula (including the > 6° re-fit) so the reverse gate exercises the same shape.
    private func fitZoom(_ framing: LoupeFraming, margin: Double) -> Double {
        let base = framing.rotatedSourceExtent
        let z = min(Double(framing.viewport.width) / max(base.width, 1e-9),
                    Double(framing.viewport.height) / max(base.height, 1e-9))
        guard z.isFinite, z > 0 else { return 1 }
        var zoom = min(1, z * margin)
        if abs(framing.straightenDegrees) > LoupeFraming.cropRefitDegrees {
            let aabb = framing.rotatedCropExtent
            let fit = min(Double(framing.viewport.width) / max(aabb.width, 1e-9),
                          Double(framing.viewport.height) / max(aabb.height, 1e-9))
            if fit.isFinite, fit > 0 { zoom = min(zoom, min(1, fit * margin)) }
        }
        return zoom
    }

    // MARK: - 2.1 real-window measurements (drawn side)

    /// ① ordinary 适应: the rendered photograph occupies 0.90 of the viewport on its constraining axis,
    /// and the render's own zoom equals the viewport fit × 0.90. Before the fix this was 1.00 while
    /// `fitZoom` was 0.90 — the user's 「看到还是全屏」.
    func testOrdinaryFitDrawsAtNinetyPercentOfTheViewport() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let framing = try XCTUnwrap(loupe.framing())
        let state = loupe.viewState
        XCTAssertEqual(state.mode, .fit)

        let frame = try renderedFrame(loupe, session: session, state: state)
        let occupancy = max(Double(frame.photoRect.width) / Double(frame.canvas.width),
                            Double(frame.photoRect.height) / Double(frame.canvas.height))
        print(String(format: "234 ① ordinary · fitZoom %.6f · drawn zoom %.6f · photo %@ / canvas %@ "
                     + "· occupancy %.4f",
                     framing.fitZoom, frame.zoom, frame.photoRect.keyString,
                     frame.canvas.keyString, occupancy))

        // The constraining axis is the whole story: the other one is letterboxed by the aspect.
        XCTAssertTrue(ninetyPercentGate(occupancy),
                      "ordinary 适应 must draw the picture at 90 % of the viewport, not 100 %")

        // Drawn-side camera: the render's own `zoom` is the viewport fit × 0.90.
        let viewportFit = min(Double(frame.canvas.width) / Double(frame.window.width),
                              Double(frame.canvas.height) / Double(frame.window.height))
        XCTAssertEqual(frame.zoom, min(1, viewportFit * LoupeFraming.fitMargin), accuracy: 1e-6,
                       "the render's zoom is not the viewport fit × 0.90")

        // Consistency: the camera/readout and the drawing are the same number (≤ 0.5 % apart).
        let relative = abs(loupe.effectiveZoom - frame.zoom) / max(frame.zoom, 1e-9)
        XCTAssertLessThanOrEqual(relative, 0.005,
                                 "fitZoom \(loupe.effectiveZoom) and drawn zoom \(frame.zoom) disagree")
        XCTAssertEqual(loupe.zoomLabel,
                       "适应 \(Int((frame.zoom * 100).rounded()))%",
                       "the readout does not describe the frame that was drawn")
    }

    /// ② 裁切入口: the same 0.90 as ordinary 适应 — 213 removed the second ×0.9, and 234 keeps the
    /// drawn result honest.
    func testCropEntryDrawsAtTheSameNinetyPercent() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let ordinary = try XCTUnwrap(loupe.framing()).fitZoom

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        let state = loupe.viewState
        let edit = loupe.cropTool.canvasEdit(from: session.edit)
        let frame = try renderedFrame(loupe, session: session, state: state, edit: edit)
        let occupancy = max(Double(frame.photoRect.width) / Double(frame.canvas.width),
                            Double(frame.photoRect.height) / Double(frame.canvas.height))
        print(String(format: "234 ② crop entry · ordinary %.6f · entry %.6f · drawn %.6f "
                     + "· occupancy %.4f",
                     ordinary, loupe.effectiveZoom, frame.zoom, occupancy))

        XCTAssertEqual(occupancy, 0.90, accuracy: 0.005,
                       "裁切入口 must draw at 90 %, not 81 % and not 100 %")
        XCTAssertEqual(frame.zoom, ordinary, accuracy: 1e-6,
                       "裁切入口 changed the drawn camera — it must be the ordinary fit itself")
        XCTAssertEqual(loupe.effectiveZoom, frame.zoom, accuracy: 0.005 * max(frame.zoom, 1e-9))
    }

    /// ③ 旋转 45° 后整幅重取景: the smaller of the source AABB and the crop AABB, both × 0.90.
    func testFortyFiveDegreeRefitDrawsAtTheSameNinetyPercent() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let ordinary = try XCTUnwrap(loupe.framing()).fitZoom

        XCTAssertTrue(loupe.beginCropTool(), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        loupe.cropTool.setStraighten(45)
        XCTAssertTrue(loupe.cropTool.commitStraighten(), "45° must be written")
        CropUITestSupport.pump(0.05)

        let framing = try XCTUnwrap(loupe.framing())
        XCTAssertEqual(framing.straightenDegrees, 45, accuracy: 1e-9)
        let state = loupe.viewState
        let edit = loupe.cropTool.canvasEdit(from: session.edit)
        let frame = try renderedFrame(loupe, session: session, state: state, edit: edit)

        let sourceFit = min(Double(framing.viewport.width) / framing.rotatedSourceExtent.width,
                            Double(framing.viewport.height) / framing.rotatedSourceExtent.height)
        let cropFit = min(Double(framing.viewport.width) / framing.rotatedCropExtent.width,
                          Double(framing.viewport.height) / framing.rotatedCropExtent.height)
        let expected = min(min(1, sourceFit * LoupeFraming.fitMargin),
                           min(1, cropFit * LoupeFraming.fitMargin))
        let occupancy = max(Double(frame.photoRect.width) / Double(frame.canvas.width),
                            Double(frame.photoRect.height) / Double(frame.canvas.height))
        print(String(format: "234 ③ 45° · ordinary %.6f · source fit %.6f · crop AABB fit %.6f "
                     + "· expected %.6f · drawn %.6f · occupancy %.4f",
                     ordinary, sourceFit, cropFit, expected, frame.zoom, occupancy))

        XCTAssertEqual(framing.fitZoom, expected, accuracy: 1e-6,
                       "45° must take the smaller AABB, still × 0.90")
        XCTAssertEqual(frame.zoom, expected, accuracy: 1e-6,
                       "the 45° render did not use the re-fit zoom")
        XCTAssertEqual(occupancy, 0.90, accuracy: 0.005,
                       "the 45° whole-canvas re-fit must draw at 90 % of the viewport")
        XCTAssertLessThan(frame.zoom, ordinary, "45° must re-fit (the AABB no longer fits at 90 %)")
    }

    /// ④ 245 reverse gate on the **drawn** side: with `fitMarginOverride = 1.0` the picture must be
    /// drawn at 100 % of the viewport, so the same occupancy gate that passes at 0.90 goes red. This
    /// is the side 234 could only prove by hand-reverting the production line: the camera and the
    /// drawn rectangle both read the override, so they stay consistent with each other and still both
    /// miss 0.90.
    func testDrawnOccupancyGateGoesRedWhenTheFitMarginIsOverriddenToOne() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let fitZoomAtNinety = try XCTUnwrap(loupe.framing()).fitZoom

        // Default (nil): the production margin, and the gate holds.
        let defaultState = loupe.viewState
        let defaultFrame = try renderedFrame(loupe, session: session, state: defaultState)
        let defaultOccupancy = occupancy(of: defaultFrame)
        print(String(format: "245 reverse gate · default · fitZoom %.6f · drawn %.6f · occupancy %.4f",
                     fitZoomAtNinety, defaultFrame.zoom, defaultOccupancy))
        XCTAssertTrue(ninetyPercentGate(defaultOccupancy),
                      "the gate must hold at the production margin (nil ⇒ 0.90)")

        // Override = 1.0: the same code path, drawn at the un-margined viewport fit.
        loupe.fitMarginOverride = 1.0
        defer { loupe.fitMarginOverride = nil }
        let state = loupe.viewState
        let frame = try renderedFrame(loupe, session: session, state: state)
        let drawnOccupancy = occupancy(of: frame)
        let gateMessage = String(format:
            "XCTAssertEqual failed: occupancy %.4f is not equal to 0.90 ± 0.005", drawnOccupancy)
        print(String(format: "245 reverse gate · override 1.0 · fitZoom %.6f · drawn %.6f "
                     + "· occupancy %.4f", loupe.effectiveZoom, frame.zoom, drawnOccupancy))
        print("245 reverse gate · the 90 % assertion would fail: \(gateMessage)")

        XCTAssertFalse(ninetyPercentGate(drawnOccupancy),
                       "override 1.0 must turn the drawn 90 % assertion red — otherwise the gate "
                       + "does not guard the drawing")
        XCTAssertEqual(drawnOccupancy, 1.0, accuracy: 0.005,
                       "override 1.0 means the un-margined viewport fit, i.e. 100 % occupancy")
        XCTAssertGreaterThan(abs(frame.zoom - fitZoomAtNinety), 0.005,
                             "override 1.0 must also move the drawn zoom off the 0.90 value")

        // §1.3: camera and drawing remain one number even when that number is not 0.90.
        let relative = abs(loupe.effectiveZoom - frame.zoom) / max(frame.zoom, 1e-9)
        XCTAssertLessThanOrEqual(relative, 0.005,
                                 "override must move camera and drawing together, not apart")
    }

    // MARK: - harness

    /// The drawn 90 % criterion, extracted so the production-margin case and the override case run
    /// the **same** predicate: `true` at occupancy 0.90 ± 0.005, `false` at 1.00.
    private func ninetyPercentGate(_ occupancy: Double) -> Bool {
        abs(occupancy - 0.90) <= 0.005
    }

    private func occupancy(of frame: LoupeController.FrameResult) -> Double {
        max(Double(frame.photoRect.width) / Double(frame.canvas.width),
            Double(frame.photoRect.height) / Double(frame.canvas.height))
    }

    private func renderedFrame(_ loupe: LoupeController, session: CatalogSession,
                               state: LoupeViewState,
                               edit: EditModel? = nil) throws -> LoupeController.FrameResult {
        let raw = try rawFixture()
        return try loupe.makeFrame(url: raw,
                                   viewport: loupe.viewportPixels,
                                   decodeScale: 0.5,
                                   edit: edit ?? session.edit,
                                   state: state)
    }

    private func rawFixture() throws -> URL {
        var candidates = [ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]].compactMap { $0 }
        let dir = NSString(string: "~/Desktop/test").expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted() ?? []
        candidates += names.map { "\(dir)/\($0)" }
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw XCTSkip("no DNG fixture — set PHOTONS_TEST_RAW")
    }
}
