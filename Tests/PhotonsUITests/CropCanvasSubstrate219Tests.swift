import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 219 — **the crop frame is clamped to the canvas, not to the viewport.**
///
/// 213 was right to state the law in screen space, but it used `(0, 0, viewport.w, viewport.h)` as the
/// bound. Any framing above 适应 therefore shrank a full frame to the window: 22.2 % at 100 %,
/// 11.1 % at 200 %, 5.6 % at 400 % (top tightening axis: 1000 / 4500 / zoom). The user's rule has
/// always been 「框不许出画布」, not 「不许出屏幕」: at 100 % and above the canvas is larger than the
/// screen and a frame leaving the screen is normal.
///
/// This file pins the two numbers that make that concrete:
///
///  1. **zoom does not shrink a full frame** — fit/100/200/400 %, `crop = full`, `straighten = 0`:
///     with the canvas bound the frame keeps its size (ratio 1 at all four levels); the old
///     viewport bound is printed alongside for the record;
///  2. **out of the canvas is still pulled back** — the frame's centre moved more than one canvas
///     width past each edge; after the clamp the frame is wholly on the canvas and flush with the
///     edge it came from.
@MainActor
final class CropCanvasSubstrate219Tests: XCTestCase {

    private var workDir: URL!
    private static let source = ImageSize(width: 6000, height: 4500)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-219-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeController() throws -> CropToolController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        return controller
    }

    private struct Framing {
        let name: String
        let state: LoupeViewState
    }

    private static let framings: [Framing] = [
        Framing(name: "fit", state: .fit),
        Framing(name: "100%", state: LoupeViewState(mode: .actual, zoom: 1,
                                                    centerX: 3000, centerY: 2250)),
        Framing(name: "200%", state: LoupeViewState(mode: .actual, zoom: 2,
                                                    centerX: 3000, centerY: 2250)),
        Framing(name: "400%", state: LoupeViewState(mode: .actual, zoom: 4,
                                                    centerX: 3000, centerY: 2250)),
    ]

    private func mapping(_ state: LoupeViewState) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: 0).mapping(of: state)
    }

    /// The frame as the overlay draws it, in device pixels.
    private func screenBox(_ controller: CropToolController, mapping: LoupeMapping) -> CGRect {
        let corners = controller.layout(mapping: mapping, source: Self.source,
                                        pointScale: 1).corners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    // MARK: - acceptance 1: zooming in does not shrink a full frame

    /// The user's number, before and after. "Larger" means the frame's projected box relative to the
    /// canvas: 1.0 is untouched. The "before" column is what 213's viewport bound would have done to
    /// the very same box (`min(viewport.w / box.w, viewport.h / box.h)`).
    func testFullFrameKeepsItsSizeAtEveryFraming() throws {
        let controller = try makeController()
        controller.draft.straighten = 0

        var before: [String] = [], after: [String] = []
        for framing in Self.framings {
            let map = mapping(framing.state)
            controller.draft.crop = .full
            let canvas = map.canvasRect
            let box = screenBox(controller, mapping: map)

            let viewport = CGRect(x: 0, y: 0,
                                  width: Double(Self.viewport.width),
                                  height: Double(Self.viewport.height))
            let oldShrink = min(1, viewport.width / max(box.width, 1e-9),
                                viewport.height / max(box.height, 1e-9))

            _ = controller.clampToView(mapping: map, source: Self.source)
            let clamped = screenBox(controller, mapping: map)
            // "Did the clamp shrink it?" — the same factor the 213 bound computed, now measured
            // against the canvas. 100 % means the full frame came through untouched.
            let newShrink = min(1, canvas.width / max(clamped.width, 1e-9),
                                canvas.height / max(clamped.height, 1e-9))

            before.append(String(format: "%@ %.1f%%", framing.name, oldShrink * 100))
            after.append(String(format: "%@ %.1f%%", framing.name, newShrink * 100))

            XCTAssertEqual(controller.draft.crop, .full,
                           "\(framing.name): 219 must not shrink a full frame")
            XCTAssertEqual(newShrink, 1, accuracy: 1e-9,
                           "\(framing.name): the full frame must not be shrunk")
            XCTAssertEqual(clamped.width, box.width, accuracy: 1e-9)
            XCTAssertEqual(clamped.height, box.height, accuracy: 1e-9)
        }
        print("219 §1 · 满幅框 · 改前（基准=视口） " + before.joined(separator: " · ")
              + " → 改后（基准=画布） " + after.joined(separator: " · "))
    }

    // MARK: - acceptance 2: out of the canvas is still pulled back

    /// Four directions: the frame's centre is placed **more than one canvas width** past that edge,
    /// then the shipped clamp runs. It must come back wholly onto the canvas (intersection = 1) and
    /// stop flush with the edge it crossed — no gap, no overshoot.
    func testTheFrameIsPulledBackFromOutsideEveryCanvasEdge() throws {
        let controller = try makeController()
        controller.draft.straighten = 0
        let map = mapping(Self.framings[1].state)          // 100 %: the canvas is 0…1² in frame units
        let canvas = map.canvasRect
        let span = 0.2                                     // a 1200 × 900 frame, well inside the canvas
        let outside = 1.1                                  // centred 1.1 canvas widths beyond the edge

        // (name, centre, the canvas edge the frame must end up on)
        let cases: [(String, (Double, Double), String)] = [
            ("左", (-outside, 0.5), "left"),
            ("右", (1 + outside, 0.5), "right"),
            ("上", (0.5, -outside), "top"),
            ("下", (0.5, 1 + outside), "bottom"),
        ]

        var reports: [String] = []
        for (name, centre, edge) in cases {
            controller.draft.crop = CropRect(left: centre.0 - span / 2, top: centre.1 - span / 2,
                                             right: centre.0 + span / 2, bottom: centre.1 + span / 2)
            let before = screenBox(controller, mapping: map)
            XCTAssertFalse(CropCanvasClamp.contains(before, in: canvas, tolerance: 0.5),
                           "219 §2 \(name): the seed frame must start outside the canvas")

            XCTAssertTrue(controller.clampToView(mapping: map, source: Self.source),
                          "219 §2 \(name): the clamp must move a frame that is off the canvas")
            let after = screenBox(controller, mapping: map)

            XCTAssertTrue(CropCanvasClamp.contains(after, in: canvas, tolerance: 0.5),
                          "219 §2 \(name): still outside \(after) vs \(canvas)")
            let intersection = after.intersection(canvas)
            let cover = intersection.isNull ? 0
                : intersection.width * intersection.height / max(after.width * after.height, 1e-9)
            XCTAssertGreaterThanOrEqual(cover, 1 - 1e-9,
                                        "219 §2 \(name): intersection \(cover) must be 1")
            // The boundary that crossed is now on the canvas edge (within half a point of layout).
            switch edge {
            case "left": XCTAssertEqual(after.minX, canvas.minX, accuracy: 0.5)
            case "right": XCTAssertEqual(after.maxX, canvas.maxX, accuracy: 0.5)
            case "top": XCTAssertEqual(after.minY, canvas.minY, accuracy: 0.5)
            default: XCTAssertEqual(after.maxY, canvas.maxY, accuracy: 0.5)
            }
            reports.append(String(format: "%@ 框 %.1f,%.1f–%.1f,%.1f · 画布 %.1f,%.1f–%.1f,%.1f · 覆盖 %.4f",
                                  name, after.minX, after.minY, after.maxX, after.maxY,
                                  canvas.minX, canvas.minY, canvas.maxX, canvas.maxY, cover))
        }
        print("219 §2 · 出画布拉回 " + reports.joined(separator: " ‖ "))
    }
}
