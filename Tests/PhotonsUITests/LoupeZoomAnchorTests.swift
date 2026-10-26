import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The anchor invariant: **the source pixel under the cursor does not move**.
///
/// A zoom is a question about the pixel under the pointer — `放大这里` — so every command that
/// changes the stop anchors there: the menu stops, ⌘= / ⌘−, Z, the pinch, and the double-click that
/// enters 1:1. Before this change the stop commands re-centred the *picture* (`centering(_:onSource:)`
/// with the crop's middle) and the double-click carried the clicked pixel to the middle of the
/// viewport, which is precisely a moving cursor.
///
/// Two outcomes now that the picture is allowed to leave the frame:
///
///   ① **exact** — the anchored pixel does not move at all: Δ is 0 to floating-point noise (~1e-13),
///      because the anchor enters `LoupeFraming.mapping` with slope 1 and `zooming` is one affine step.
///      This is the answer for every anchor that is on the picture, including one that pushes the
///      window off the edge, and it is what the numbers below show.
///   ② **capped** — the one case the rule still has a say in: an excursion so large that less than
///      `LoupeFraming.minimumPictureCoverage` (½) of the canvas would still be photograph. The window
///      stops there and the pixel moves by the shortfall. Measured in
///      `testZoomingOutFromACornerStopsAtTheCoverageLimit`.
///
/// `fit` has no anchor to honour (the whole frame is the whole frame, centred) — that is unchanged.
@MainActor
final class LoupeZoomAnchorTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A controller with a first frame and **no** transition in the way: these tests are about the
    /// state the command produces, and the bridge is measured in `LoupeZoomTransitionAnimationTests`.
    private func makeController(url: URL, identity: String) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        controller.reducesMotion = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport, state: .fit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    /// The window's own backing scale — the same number `LoupeController.backingScale` uses, so the
    /// anchor arithmetic in this file runs in the same space as the command under test.
    private func backingScale(_ controller: LoupeController) -> Double {
        Double(controller.canvasView.window?.backingScaleFactor ?? 2)
    }

    // MARK: - measuring

    private struct AnchorReading {
        var before: (x: Double, y: Double)
        var after: (x: Double, y: Double)
        var delta: (x: Double, y: Double)
        var desiredCentre: (x: Double, y: Double)
        var actualCentre: (x: Double, y: Double)
        var clamped: Bool
        var pullBack: (x: Double, y: Double)
        var magnitude: Double { (delta.x * delta.x + delta.y * delta.y).squareRoot() }
        var pullBackMagnitude: Double { (pullBack.x * pullBack.x + pullBack.y * pullBack.y).squareRoot() }
    }

    /// The source pixel under `point` before and after, plus what the anchor *wanted* to be (the
    /// unclamped centre) so a clamp can be reported as a number rather than as a shrug.
    private func reading(_ framing: LoupeFraming, from before: LoupeViewState, at point: CGPoint,
                         scale: Double, backingScale k: Double) -> AnchorReading {
        // Run the command.
        let after = framing.zooming(before, to: scale, aroundView: point, backingScale: k)
        let vx = Double(point.x) * k, vy = Double(point.y) * k
        let p0 = framing.mapping(of: before).sourcePoint(viewX: vx, viewY: vy)
        let p1 = framing.mapping(of: after).sourcePoint(viewX: vx, viewY: vy)
        // The same step without the clamp: what `zooming` computes before `clampedCenter` speaks.
        var wanted = after
        let shifted = framing.zoomingWithoutClamping(before, to: scale, aroundView: point,
                                                     backingScale: k)
        wanted.centerX = shifted.x
        wanted.centerY = shifted.y
        let actual = framing.windowCenter(of: after)
        return AnchorReading(before: p0, after: p1,
                             delta: (p1.x - p0.x, p1.y - p0.y),
                             desiredCentre: (shifted.x, shifted.y),
                             actualCentre: (actual.x, actual.y),
                             clamped: abs(actual.x - shifted.x) > 1e-6 || abs(actual.y - shifted.y) > 1e-6,
                             pullBack: (actual.x - shifted.x, actual.y - shifted.y))
    }

    private func report(_ label: String, _ r: AnchorReading) -> String {
        let kind: String
        if r.clamped {
            kind = String(format: "CAPPED at minimumPictureCoverage (short by %.1f, %.1f src px)",
                          r.pullBack.x, r.pullBack.y)
        } else {
            kind = "exact"
        }
        return String(format: "%@ · anchor src (%.1f, %.1f) → (%.1f, %.1f) · |Δ| = %.3f src px · %@",
                      label, r.before.x, r.before.y, r.after.x, r.after.y, r.magnitude, kind)
    }

    // MARK: - ① menu / ⌘= steps: 100 → 200 % at three positions

    func testFortyToEightyKeepsTheCursorPixelAtThreePositions() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-stops")
        let framing = try XCTUnwrap(controller.framing())

        controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
        XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)

        let positions: [(String, CGPoint)] = [
            ("centre      ", CGPoint(x: 160, y: 100)),
            ("top-left ¼  ", CGPoint(x: 80, y: 50)),
            ("bottom-right", CGPoint(x: 300, y: 186)),
        ]
        var lines: [String] = []
        for (label, point) in positions {
            let before = controller.viewState
            let r = reading(framing, from: before, at: point, scale: 2,
                            backingScale: backingScale(controller))
            controller.zoom(to: 2, aroundView: point)
            XCTAssertEqual(controller.viewState.zoom, 2, accuracy: 1e-12)
            // The model must agree with the arithmetic we just measured.
            XCTAssertEqual(controller.viewState.centerX, r.actualCentre.x, accuracy: 1e-6)
            XCTAssertEqual(controller.viewState.centerY, r.actualCentre.y, accuracy: 1e-6)
            XCTAssertFalse(r.clamped, "\(label): the picture may leave the frame — nothing should cap it")
            XCTAssertLessThan(r.magnitude, 1e-9,
                              "\(label): the anchored pixel moved \(r.magnitude) source px")
            lines.append(report("100→200 \(label) @\(Int(point.x)),\(Int(point.y))", r))
            // A known 100 % state for the next position: centred, unpanned.
            controller.zoomToActualSize(aroundView: CGPoint(x: 160, y: 100))
            XCTAssertTrue(waitFor { controller.zoomBridge == nil })
            XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)
        }
        print(lines.joined(separator: "\n        "))
    }

    // MARK: - ② double-click: fit → 100 % keeps the clicked pixel

    func testDoubleClickIntoOneToOneKeepsTheClickedPixel() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-doubleclick")
        let framing = try XCTUnwrap(controller.framing())
        XCTAssertEqual(controller.viewState.mode, .fit)

        let positions: [(String, CGPoint)] = [
            ("centre      ", CGPoint(x: 160, y: 100)),
            ("top-left ¼  ", CGPoint(x: 80, y: 50)),
            ("bottom-right", CGPoint(x: 300, y: 186)),
            // Inside the letterbox: the pixel under the cursor is *outside* the picture, which is the
            // one case where the window cannot follow the anchor at all.
            ("letterbox   ", CGPoint(x: 4, y: 190)),
        ]
        var lines: [String] = []
        for (label, point) in positions {
            controller.zoomToFit()
            XCTAssertEqual(controller.viewState.mode, .fit)
            let before = controller.viewState
            let r = reading(framing, from: before, at: point, scale: 1,
                            backingScale: backingScale(controller))
            controller.handleDoubleClick(at: point)
            XCTAssertEqual(controller.viewState.mode, .actual)
            XCTAssertEqual(controller.viewState.zoom, 1, accuracy: 1e-12)
            XCTAssertEqual(controller.viewState.centerX, r.actualCentre.x, accuracy: 1e-6)
            if !r.clamped {
                XCTAssertLessThan(r.magnitude, 1.0,
                                  "\(label): the clicked pixel moved \(r.magnitude) source px")
            }
            lines.append(report("dbl-click \(label) @\(Int(point.x)),\(Int(point.y))", r))
        }
        print(lines.joined(separator: "\n        "))
    }

    // MARK: - ③ zooming out from a corner: the coverage limit, measured

    /// Zoom *out* anchored on a pixel near the corner: the window has to grow, the anchor asks it to
    /// grow to the left of the frame, and the picture now **may** leave the frame — so it does, until
    /// `LoupeFraming.minimumPictureCoverage` says half of the canvas would stop being photograph.
    /// That limit is what this test measures: the excursion it allows, the coverage at the stop, and
    /// the fact that nothing springs back afterwards.
    func testZoomingOutFromACornerStopsAtTheCoverageLimit() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-out")
        let framing = try XCTUnwrap(controller.framing())

        // Park the window on the crop's top-left corner at 400 %, then zoom out with the pointer on
        // the far side of the canvas.
        controller.zoom(to: 2, aroundView: CGPoint(x: 0, y: 0))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        controller.zoom(to: 4, aroundView: CGPoint(x: 0, y: 0))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        let parked = controller.viewState
        XCTAssertEqual(parked.zoom, 4, accuracy: 1e-12)
        print(String(format: "parked at 400%%: window centre (%.1f, %.1f) src · window %.0f×%.0f src",
                     parked.centerX, parked.centerY,
                     framing.windowSize(of: parked).width, framing.windowSize(of: parked).height))

        let corner = CGPoint(x: 300, y: 186)
        let r = reading(framing, from: parked, at: corner, scale: 1,
                        backingScale: backingScale(controller))
        controller.zoom(to: 1, aroundView: corner)
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        print(report("400→100 bottom-right @\(Int(corner.x)),\(Int(corner.y))", r))

        let after = controller.viewState
        let size = framing.windowSize(of: after)
        let centre = framing.windowCenter(of: after)
        // The limit: the centre sits on the crop's edge, and exactly half the window still covers it.
        XCTAssertEqual(centre.x, framing.cropOriginX, accuracy: 1e-6)
        XCTAssertEqual(centre.y, framing.cropOriginY, accuracy: 1e-6)
        let pictureX = max(0, min(centre.x + size.width / 2, framing.cropWidthPixels)
                           - max(centre.x - size.width / 2, 0))
        let coverage = pictureX / size.width
        print(String(format: "        limit reached: window centre (%.1f, %.1f) src · "
                     + "%.1f of %.1f px still photograph = %.0f %% = minimumPictureCoverage",
                     centre.x, centre.y, pictureX, size.width, coverage * 100))
        XCTAssertEqual(coverage, LoupeFraming.minimumPictureCoverage, accuracy: 0.01,
                       "the stop is the coverage rule, not an arbitrary edge")
        XCTAssertEqual(after.zoom, 1, accuracy: 1e-12, "the camera still got to the stop it was asked for")
        // Nothing springs back: asking again with the same anchor must not move the picture.
        let again = framing.zooming(after, to: 1, aroundView: corner,
                                    backingScale: backingScale(controller))
        XCTAssertEqual(framing.windowCenter(of: again).x, centre.x, accuracy: 1e-6)
        XCTAssertEqual(framing.windowCenter(of: again).y, centre.y, accuracy: 1e-6)
    }

    // MARK: - ④ zoom to fit: the whole frame, the anchor vacuous

    func testZoomToFitShowsTheWholeFrame() throws {
        let url = try rawFixture()
        let controller = makeController(url: url, identity: "anchor-fit")
        let framing = try XCTUnwrap(controller.framing())
        controller.zoom(to: 4, aroundView: CGPoint(x: 40, y: 30))
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })

        controller.zoomToFit()
        XCTAssertTrue(waitFor { controller.zoomBridge == nil })
        XCTAssertEqual(controller.viewState.mode, .fit)
        let window = framing.windowSize(of: controller.viewState)
        XCTAssertEqual(window.width, framing.cropWidthPixels, accuracy: 1e-6)
        XCTAssertEqual(window.height, framing.cropHeightPixels, accuracy: 1e-6)
        let content = framing.contentPixels(of: controller.viewState)
        print("zoom to fit: window \(Int(window.width))×\(Int(window.height)) src = the whole crop, "
              + "content \(content.width)×\(content.height) px of a "
              + "\(framing.viewport.width)×\(framing.viewport.height) canvas — nothing to anchor")
    }
}

extension LoupeFraming {

    /// `zooming` with `clampedCenter` left out: the centre the anchor *wants*, before the crop has its
    /// say. Exists so a test can report the pull-back instead of hiding it.
    func zoomingWithoutClamping(_ state: LoupeViewState, to zoom: Double, aroundView view: CGPoint,
                                backingScale: Double) -> (x: Double, y: Double) {
        var base = state
        if base.mode != .actual {
            base.mode = .actual
            let fit = windowCenter(of: state)
            base.centerX = fit.x
            base.centerY = fit.y
        }
        var next = base
        next.mode = .actual
        next.zoom = LoupeViewState.clampZoom(zoom)
        let anchor = mapping(of: next).sourcePoint(viewX: Double(view.x) * backingScale,
                                                   viewY: Double(view.y) * backingScale)
        let mapped = mapping(of: state).sourcePoint(viewX: Double(view.x) * backingScale,
                                                    viewY: Double(view.y) * backingScale)
        let centre = windowCenter(of: state)
        return (centre.x + (mapped.x - anchor.x), centre.y + (mapped.y - anchor.y))
    }
}
