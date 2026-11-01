import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// 202 P3 — the camera's target state, as arithmetic.
///
/// Every case here is a question `LoupeController` used to answer inline: what the next
/// `LoupeViewState` is for a fit, a named stop, a ⌘=/⌘− step, a drag, a scroll or a pinch. The
/// controller's side effects (`setViewState`, the animation, the crop clamp) are not in reach, so
/// the formulas are asserted directly.
final class LoupeCameraTests: XCTestCase {

    private func framing() -> LoupeFraming {
        LoupeFraming(viewport: ImageSize(width: 1000, height: 800),
                     sourceWidth: 4000, sourceHeight: 3000, crop: .full)
    }

    private func camera(state: LoupeViewState = .fit, backingScale: Double = 2,
                        cropLimit: Double? = nil) -> LoupeCamera {
        LoupeCamera(viewport: LoupeViewport(framing: framing(), state: state),
                    backingScale: backingScale, cropLimit: cropLimit)
    }

    private func actual(zoom: Double, x: Double = 2000, y: Double = 1500) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: zoom, centerX: x, centerY: y)
    }

    // MARK: 1

    func testFitKeepsCentreButClearsMode() {
        let state = actual(zoom: 2, x: 1234, y: 567)
        let next = camera(state: state).fitted()
        XCTAssertEqual(next.mode, .fit)
        XCTAssertEqual(next.zoom, 2)
        XCTAssertEqual(next.centerX, 1234)
        XCTAssertEqual(next.centerY, 567)
    }

    // MARK: 2

    func testActualSizeFromFitLandsOnOneAndKeepsTheAnchor() {
        let f = framing()
        let anchor = CGPoint(x: 250, y: 200)
        let before = f.sourcePoint(of: .fit, viewX: 250, viewY: 200, backingScale: 2)
        let next = camera(state: .fit).actualSize(aroundView: anchor)
        let after = f.sourcePoint(of: next, viewX: 250, viewY: 200, backingScale: 2)
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 1, accuracy: 1e-12)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-9)
    }

    // MARK: 3

    func testZoomToStopSnapsDownToTheRung() {
        let next = camera().zoomed(to: 0.9, aroundView: CGPoint(x: 500, y: 400))
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 2.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: 4

    func testStepInFromFitIsActualSize() {
        XCTAssertEqual(camera(state: .fit).stepped(inward: true), .actualSize)
    }

    // MARK: 5

    func testStepOutFromLowestRungIsFit() {
        XCTAssertEqual(camera(state: actual(zoom: 0.125)).stepped(inward: false), .fit)
    }

    // MARK: 6

    func testPanOnlyInActualAndMovesByWindowPointsOverBackingScale() {
        let fit = camera(state: .fit)
        XCTAssertEqual(fit.panned(byWindowPoints: CGSize(width: 10, height: 0)), .fit)

        let zoomed = camera(state: actual(zoom: 1))
        let next = zoomed.panned(byWindowPoints: CGSize(width: 10, height: 0))
        XCTAssertEqual(next.centerX, 1980, accuracy: 1e-9)
        XCTAssertEqual(next.centerY, 1500, accuracy: 1e-9)
    }

    // MARK: 7

    func testPinchAccumulatesBelowTheRung() {
        var state = LoupeViewState.fit
        var accumulated: Double?
        var seen: [Double] = []
        for _ in 0..<3 {
            let camera = camera(state: state)
            let result = camera.pinched(by: 1.02, aroundView: CGPoint(x: 500, y: 400),
                                        accumulated: accumulated)
            state = result.state
            accumulated = result.accumulated
            seen.append(result.accumulated)
        }
        XCTAssertEqual(state.mode, .actual)
        XCTAssertEqual(state.zoom, 0.125, accuracy: 1e-12)
        XCTAssertEqual(seen.count, 3)
        XCTAssertLessThan(seen[0], seen[1])
        XCTAssertLessThan(seen[1], seen[2])
    }

    // MARK: 8

    func testCropLimitCapsActualSize() {
        let next = camera(cropLimit: 0.6).actualSize(aroundView: CGPoint(x: 500, y: 400))
        XCTAssertEqual(next.mode, .actual)
        XCTAssertEqual(next.zoom, 0.6, accuracy: 1e-12)
    }

    // MARK: 9

    func testLabelSaysFitPercent() {
        XCTAssertEqual(camera(state: .fit).label, "适应 23%")
    }

    // MARK: 10

    func testCurrentStopIsNilAtFit() {
        XCTAssertNil(camera(state: .fit).currentStop)
    }
}
