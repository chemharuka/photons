import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 213 — 适应统一 90 %，裁切入口不再二次乘 0.9；219 re-bases the clamp on the **canvas**.
///
/// Three claims, each stated where the user sees it:
///
///  1. `LoupeFraming.fitZoom` is the viewport fit × one `fitMargin` (0.90), and
///     `CropWorkspaceLayout.entry` is **the same number** at entry (not 0.9 × 0.9 = 0.81);
///  2. the clamp's canvas is the **document canvas** — the smallest axis-aligned box holding every pixel
///     of the whole photograph after the turn (2026-11-02, 「旋转之后裁剪框能移动的范围应该是画布，不是
///     原始图片」; it is `[0,1]²` at 0°/180° and wider than the photograph in between) — so the frame's
///     projected corners stay inside the *drawn* canvas at every fit/100/200/400 % × angle × frame-size
///     combination. The box does not know about the viewport: at 100 % and above the frame is allowed to
///     leave the screen;
///  3. with `clampsFrameToView` off the same combination is red, so the matrix is not passing for a
///     reason of its own.
///
/// `legalRect(degrees:)` re-derives that box from the AABB formula, and `canvasBox(_:mapping:)` pushes it
/// through the same `CropTool.layout` projection the frame is drawn with; the containment checks compare
/// those two, so nothing here is measured against `mapping.canvasRect` (219's picture-at-the-camera).
@MainActor
final class CropFitNinetyTests: XCTestCase {

    private var workDir: URL!
    private static let source = ImageSize(width: 6000, height: 4500)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-fit-213-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - acceptance 1: one 90 %

    func testTheOrdinaryFitIsTheViewportFitTimesNinetyPercent() {
        // A 4.10 Mpx sample (2480 × 1653) in a 2560 × 1600 viewport.
        let viewport = ImageSize(width: 2560, height: 1600)
        let framing = LoupeFraming(viewport: viewport,
                                   sourceWidth: 2480, sourceHeight: 1653)
        let viewportFit = min(Double(viewport.width) / 2480,
                              Double(viewport.height) / 1653)
        print(String(format: "213 · viewport fit %.9f · × 0.90 = %.9f · fitZoom %.9f",
                     viewportFit, viewportFit * LoupeFraming.fitMargin, framing.fitZoom))
        XCTAssertEqual(framing.fitZoom, min(1, viewportFit * LoupeFraming.fitMargin),
                       accuracy: 1e-12, "ordinary 适应 must be the viewport fit × 0.90")
        XCTAssertEqual(LoupeFraming.fitMargin, 0.90, accuracy: 1e-15)
    }

    // MARK: - acceptance 2: entry is the same projection

    func testCropWorkspaceEntryIsTheOrdinaryFitItself() {
        for degrees in [0.0, 5, 7, 45] {
            let layout = CropWorkspaceLayout(
                source: Self.source, quarterTurns: 0, straighten: degrees,
                canvas: CGRect(x: 0, y: 0,
                               width: Double(Self.viewport.width),
                               height: Double(Self.viewport.height)))
            let entry = layout.entry(crop: .full)
            let framing = LoupeFraming(viewport: Self.viewport,
                                       sourceWidth: Double(Self.source.width),
                                       sourceHeight: Double(Self.source.height),
                                       crop: .full, straightenDegrees: degrees)
            print(String(format: "213 · %.0f° · entry %.9f · fitZoom %.9f",
                         degrees, entry.entryZoom, framing.fitZoom))
            XCTAssertEqual(entry.entryZoom, framing.fitZoom, accuracy: 1e-12,
                           "\(degrees)°: 裁切入口 must be the ordinary fit itself, not another 0.9")
        }
    }

    // MARK: - acceptance 3: the frame never leaves the canvas (219)

    private struct Case {
        let state: LoupeViewState
        let name: String
    }

    private static let states: [Case] = [
        Case(state: .fit, name: "fit"),
        Case(state: LoupeViewState(mode: .actual, zoom: 1,
                                   centerX: 3000, centerY: 2250), name: "100%"),
        Case(state: LoupeViewState(mode: .actual, zoom: 2,
                                   centerX: 3000, centerY: 2250), name: "200%"),
        Case(state: LoupeViewState(mode: .actual, zoom: 4,
                                   centerX: 3000, centerY: 2250), name: "400%"),
    ]

    private static let crops: [(String, CropRect)] = [
        ("full", .full),
        ("居中半幅", CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
        ("贴左上", CropRect(left: 0, top: 0, right: 0.5, bottom: 0.5)),
    ]

    private func makeController() throws -> CropToolController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        return controller
    }

    private func screenBox(_ controller: CropToolController,
                           mapping: LoupeMapping) -> CGRect {
        let corners = controller.layout(mapping: mapping, source: Self.source,
                                        pointScale: 1).corners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The legal area of a crop frame — the **document canvas**: the smallest axis-aligned box holding
    /// every pixel of the whole photograph once it is turned, in normalized crop coordinates.
    ///
    /// Derived here from the AABB formula (`e = |w·cos| + |h·sin|` by `|w·sin| + |h·cos|`, centred on the
    /// photograph) instead of `CropGeometry.documentCanvasCropRect`, so the test owns its own bound.
    /// `[0,1]²` at 0°/180°; 5° on 6000 × 4500 is `-0.030781…1.030781 × -0.056201…1.056201`; 45° is
    /// `-0.118718…1.118718 × -0.324958…1.324958`.
    private func legalRect(degrees: Double) -> CropRect {
        let w = Double(max(Self.source.width, 1)), h = Double(max(Self.source.height, 1))
        let quarter = degrees / 90
        let extent: (width: Double, height: Double)
        if abs(quarter - quarter.rounded()) < 1e-9 {
            extent = Int(quarter.rounded()) % 2 != 0 ? (h, w) : (w, h)
        } else {
            let radians = degrees * .pi / 180
            let c = abs(cos(radians)), s = abs(sin(radians))
            extent = (w * c + h * s, w * s + h * c)
        }
        let left = (w - extent.width) / 2, top = (h - extent.height) / 2
        return CropRect(left: left / w, top: top / h,
                        right: (left + extent.width) / w, bottom: (top + extent.height) / h)
    }

    /// The canvas **as drawn**: the legal rect through the very projection the frame goes through
    /// (`CropTool.layout` with the draft's rotation), so the containment comparison is one space.
    ///
    /// 2026-11-02 — this replaced `mapping.canvasRect(rotatedBy:)` as the judgement source: that one is
    /// 219's picture-at-the-camera, and it cannot be the bound of a clamp whose law is the document.
    private func canvasBox(_ mapping: LoupeMapping, degrees: Double) -> CGRect {
        let legal = legalRect(degrees: degrees)
        let corners = CropTool.layout(crop: legal, source: Self.source, mapping: mapping,
                                      pointScale: 1, showsGrid: false,
                                      quadRotationDegrees: degrees).corners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// 2026-11-02 — containment is measured against the **drawn document canvas** (the legal rect), not
    /// the viewport and no longer 219's picture-at-the-camera. At 100 %/200 %/400 % the box is far larger
    /// than the 1400 × 1000 screen, which is exactly the point.
    private func inside(_ box: CGRect, canvas: CGRect, tolerance: Double = 0.5) -> Bool {
        box.minX >= canvas.minX - tolerance && box.minY >= canvas.minY - tolerance
            && box.maxX <= canvas.maxX + tolerance && box.maxY <= canvas.maxY + tolerance
    }

    func testEveryFramingAngleAndFrameSizeStaysInsideTheCanvas() throws {
        let controller = try makeController()
        var failures: [String] = []

        for degrees in [0.0, 5, 7, 45] {
            controller.draft.straighten = degrees
            for state in Self.states {
                let mapping = LoupeFraming(viewport: Self.viewport,
                                           sourceWidth: Double(Self.source.width),
                                           sourceHeight: Double(Self.source.height),
                                           crop: .full,
                                           straightenDegrees: 0).mapping(of: state.state)
                for (name, crop) in Self.crops {
                    controller.draft.crop = crop
                    _ = controller.clampToView(mapping: mapping, source: Self.source)
                    let canvas = canvasBox(mapping, degrees: degrees)
                    let box = screenBox(controller, mapping: mapping)
                    if !inside(box, canvas: canvas) {
                        failures.append("\(state.name) · \(degrees)° · \(name) → \(box) "
                                        + "vs canvas \(canvas)")
                    }
                }
            }
        }

        if !failures.isEmpty {
            for line in failures { print("213 OUT \(line)") }
        }
        XCTAssertTrue(failures.isEmpty,
                      "the frame left the canvas in \(failures.count) combinations: \(failures)")
    }

    /// 219's anti-proof runs the **same 48 cells** with the frame's centre pushed two canvas widths to
    /// the right first. That translation is the only way a cell can be out of the canvas now: a crop
    /// rect is a part of the source, so once the canvas turns with the draft angle every untranslated
    /// cell is inside it *by construction* — the red has to be a frame the user moved out.
    ///
    /// 2026-11-02 — the canvas is the **drawn legal rect** (`canvasBox`), not 219's
    /// `mapping.canvasRect`. The claim is unchanged: with the clamp on, all 48 translated cells come
    /// back inside the document canvas; with it off, all 48 are out.
    func testWithoutTheClampTheSameMatrixLeavesTheCanvas() throws {
        let controller = try makeController()
        var unclampedOutside = 0
        var clampedOutside = 0
        var untranslatedOutside = 0

        for degrees in [0.0, 5, 7, 45] {
            controller.draft.straighten = degrees
            for state in Self.states {
                let mapping = LoupeFraming(viewport: Self.viewport,
                                           sourceWidth: Double(Self.source.width),
                                           sourceHeight: Double(Self.source.height),
                                           crop: .full,
                                           straightenDegrees: 0).mapping(of: state.state)
                let canvas = canvasBox(mapping, degrees: degrees)
                for (_, crop) in Self.crops {
                    // Untranslated: a rect of the source is a subset of the canvas that turns with
                    // it, so 219 records 0/48 here — the red has to be a moved frame.
                    controller.clampsFrameToView = false
                    controller.draft.crop = crop
                    _ = controller.clampToView(mapping: mapping, source: Self.source)
                    if !inside(screenBox(controller, mapping: mapping), canvas: canvas) {
                        untranslatedOutside += 1
                    }

                    let seed = CropRect(left: crop.left + 2, top: crop.top,
                                        right: crop.right + 2, bottom: crop.bottom)
                    controller.clampsFrameToView = false
                    controller.draft.crop = seed
                    _ = controller.clampToView(mapping: mapping, source: Self.source)
                    if !inside(screenBox(controller, mapping: mapping), canvas: canvas) {
                        unclampedOutside += 1
                    }

                    controller.clampsFrameToView = true
                    controller.draft.crop = seed
                    _ = controller.clampToView(mapping: mapping, source: Self.source)
                    if !inside(screenBox(controller, mapping: mapping), canvas: canvas) {
                        clampedOutside += 1
                    }
                }
            }
        }

        print("219 · anti-proof · 原 48 格（不动）关钳制出画布 \(untranslatedOutside)/48 → "
              + "同一 48 格（框心右移两个画布宽）关钳制出画布 \(unclampedOutside)/48 · "
              + "开钳制仍出画布 \(clampedOutside)/48")
        XCTAssertEqual(unclampedOutside, 48,
                       "with `clampsFrameToView` off every translated cell must be red")
        XCTAssertEqual(clampedOutside, 0,
                       "with the clamp on the same translated cells must be inside the canvas")
    }
}
