import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 「画面跟着手走」 — the pan direction, measured on a real window and a real `LoupeController`.
///
/// The bug as reported:
/// > 现在按住画布，往下移动，画面实际上是往上走的，可能是苹果设置的"自然滚动"？不要这样。
///
/// Two paths, and both had a sign wrong:
///
///   · **drag** (`LoupeCanvasView.mouseDragged` → `panImage(byPoints:)`) — the delta is in *window*
///     points, y **up**, while the projection is y **down** (the canvas view is flipped). The y term
///     was negated along with x, so a drag downwards moved the picture upwards. x was already right,
///     which is exactly why it read like a trackpad problem rather than an axis problem.
///   · **scroll** (`LoupeCanvasView.scrollWheel` → `scrollPan`) — `scrollingDeltaY` went through
///     untouched, so the picture depended on whether 「自然滚动」 was on (the system inverts the
///     deltas for the user's preference; `NSEvent.isDirectionInvertedFromDevice` is the flag that
///     says so). Normalising on that flag is the fix, not negating the delta.
///
/// What is asserted here, all of it through the public surface a gesture actually uses:
///
///   1. four drags — right / left / down / up — move the picture's rect by the same vector the hand
///      moved, in **screen** points, to ≤ 1 pt;
///   2. the pixel grabbed at `mouseDown` stays under the cursor as the drag continues (≤ 0.5 source
///      px), which is the invariant the whole "跟手" reading rests on;
///   3. a two-finger scroll lands in the same place whether the system is inverted or not: the four
///      (deltaY, inverted) combinations, precise *and* wheel (the wheel keeps its ×12);
///   4. a straightened picture still pans along the **screen** axes — 9° and 45°, 120 pt right is
///      ≥ 119 pt of x and ≤ 2 pt of y;
///   5. the edge rule is untouched: a huge drag still stops the centre on the crop's edge
///      (`minimumPictureCoverage`) and stays there;
///   6. the anti-proof: every direction assertion also rejects the mirrored vector, and
///      `testThePictureMovesAgainstTheCameraDelta` pins the one sign convention both call sites use —
///      flipping it anywhere turns 1–4 red.
@MainActor
final class PanFollowTests: XCTestCase {

    /// Same frame pair as `CropOverlayFollowTests`: 3:2, so 1:1 is a window much smaller than the
    /// picture and there is room to drag; 900×600 pt of canvas keeps a whole 120 pt drag on screen.
    private static let source = (width: 3000, height: 2000)
    private static let canvas = NSSize(width: 900, height: 600)
    private static let centre = CGPoint(x: 450, y: 300)

    private var workDir: URL!
    private var windows: [NSWindow] = []
    /// `LoupeController.session` is a **weak** reference, so a test that throws the session away gets a
    /// loupe with no anchor and no projection (`framing() == nil`). Hold it here for the whole test.
    private var sessions: [CatalogSession] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-pan-follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        sessions.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                            width: Self.source.width,
                                                            height: Self.source.height)
        sessions.append(session)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: Self.canvas),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        windows.append(window)
        CropUITestSupport.pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while loupe.framing() == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        XCTAssertNotNil(loupe.framing(), "the loupe never got a projection")
        return (loupe, session, window)
    }

    /// A pan is a 1:1 gesture (`panImage` / `scrollPan` both guard on `isActualSize`), so every
    /// measurement below is taken at 1:1 from the middle of the picture.
    private func oneToOne(_ loupe: LoupeController) {
        loupe.zoom(to: 1, aroundView: Self.centre)
        CropUITestSupport.pump(0.02)
        XCTAssertTrue(loupe.viewState.isActualSize, "1:1 never landed — the pan would be a no-op")
        XCTAssertEqual(loupe.viewState.zoom, 1, accuracy: 1e-9)
    }

    /// The photograph's rect **on screen**, in points — its four corners, not the viewport's (the
    /// letterbox is centred and never moves, so measuring it would hide the bug entirely).
    private func pictureRect(_ loupe: LoupeController) throws -> NSRect {
        let framing = try XCTUnwrap(loupe.framing())
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        let a = mapping.frameView(frameX: 0, frameY: 0)
        let b = mapping.frameView(frameX: framing.sourceWidth, frameY: framing.sourceHeight)
        return NSRect(x: min(a.x, b.x) / scale, y: min(a.y, b.y) / scale,
                      width: abs(b.x - a.x) / scale, height: abs(b.y - a.y) / scale)
    }

    /// The vector the picture's rect travelled across `body`, in points (x right, y **down**, i.e. the
    /// canvas's own flipped space — "down" on the screen is +y here).
    private func pictureShift(_ loupe: LoupeController, _ body: () -> Void) throws -> CGPoint {
        let before = try pictureRect(loupe)
        body()
        CropUITestSupport.pump(0.02)
        let after = try pictureRect(loupe)
        return CGPoint(x: after.minX - before.minX, y: after.minY - before.minY)
    }

    /// Which source pixel the canvas point `point` (points, y down from the top of the view) sits on.
    private func sourcePixel(_ loupe: LoupeController, at point: CGPoint) throws -> CGPoint {
        let framing = try XCTUnwrap(loupe.framing())
        let p = framing.sourcePoint(of: loupe.viewState, viewX: Double(point.x), viewY: Double(point.y),
                                    backingScale: loupe.backingScale)
        return CGPoint(x: p.x, y: p.y)
    }

    /// Where a **fixed source pixel** is drawn in `state`, in points.
    private func screenPoint(_ loupe: LoupeController, of source: CGPoint,
                             in state: LoupeViewState) throws -> CGPoint {
        let framing = try XCTUnwrap(loupe.framing())
        let p = framing.viewPoint(of: state, sourceX: source.x, sourceY: source.y,
                                  backingScale: loupe.backingScale)
        return CGPoint(x: p.x, y: p.y)
    }

    /// A mouse event for the canvas at a point in **canvas** points (y down). `convert(_:to: nil)` is
    /// the view's own flip, so what the event carries is what a real drag would carry.
    private func mouseEvent(_ type: NSEvent.EventType, canvas point: CGPoint, clickCount: Int = 1,
                           loupe: LoupeController, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: loupe.canvasView.convert(point, to: nil),
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    /// One whole press-drag-release. `delta` is in **window** points (y up) — the space a hand's drag
    /// is reported in — split into `steps` events so the accumulation is tested, not just the total.
    private func drag(_ loupe: LoupeController, from start: CGPoint, by delta: CGSize,
                      steps: Int = 4, window: NSWindow) throws {
        func canvasPoint(_ t: CGFloat) -> CGPoint {
            // window y is up, canvas y is down: a hand moving *down* is −y in window points.
            CGPoint(x: start.x + delta.width * t, y: start.y - delta.height * t)
        }
        loupe.canvasView.mouseDown(with: try mouseEvent(.leftMouseDown, canvas: start,
                                                       loupe: loupe, window: window))
        for step in 1 ... steps {
            loupe.canvasView.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                                              canvas: canvasPoint(CGFloat(step) / CGFloat(steps)),
                                                              loupe: loupe, window: window))
        }
        loupe.canvasView.mouseUp(with: try mouseEvent(.leftMouseUp, canvas: canvasPoint(1),
                                                     loupe: loupe, window: window))
        CropUITestSupport.pump(0.01)
    }

    /// A scroll event for the canvas. `inverted` is what 「自然滚动」 on sets on the event, through the
    /// same CGEvent field AppKit reads it from; `pixel` units are a trackpad, `line` units a wheel.
    private func scrollEvent(deltaX: Int32 = 0, deltaY: Int32, inverted: Bool,
                             pixel: Bool = true) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line,
                                       wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        if inverted, let field = CGEventField(rawValue: 137) {   // isDirectionInvertedFromDevice
            cg.setIntegerValueField(field, value: 1)
        }
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        // The event really carries the two flags this suite is about, or the rows below would prove
        // nothing about a trackpad.
        XCTAssertEqual(event.isDirectionInvertedFromDevice, inverted,
                       "the synthetic event did not take the inversion flag")
        XCTAssertEqual(event.hasPreciseScrollingDeltas, pixel, "pixel/line units did not survive")
        return event
    }

    // MARK: - 1. the drag follows the hand

    /// Four drags, four vectors, in the hand's own direction and the same length. Window coordinates
    /// are y up, so "down" arrives as a negative height and must still move the picture **down**.
    func testDragMovesThePictureWithTheHand() throws {
        let (loupe, _, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        oneToOne(loupe)

        let cases: [(String, CGSize, CGPoint)] = [
            ("right", CGSize(width: 120, height: 0), CGPoint(x: 120, y: 0)),
            ("left", CGSize(width: -120, height: 0), CGPoint(x: -120, y: 0)),
            ("down", CGSize(width: 0, height: -80), CGPoint(x: 0, y: 80)),
            ("up", CGSize(width: 0, height: 80), CGPoint(x: 0, y: -80)),
        ]
        var rows: [String] = []
        for (name, delta, expected) in cases {
            let shift = try pictureShift(loupe) {
                try? drag(loupe, from: Self.centre, by: delta, window: window)
            }
            rows.append(String(format: "%@ hand(%.0f,%.0f)→picture(%.2f,%.2f)pt",
                               name, delta.width, delta.height, shift.x, shift.y))
            XCTAssertEqual(shift.x, expected.x, accuracy: 1,
                           "\(name): the picture did not move with the hand in x")
            XCTAssertEqual(shift.y, expected.y, accuracy: 1,
                           "\(name): the picture did not move with the hand in y")
            // Anti-proof: the mirrored (wrong-way) vector is rejected with the same tolerance, so a
            // flipped sign in `panImage` cannot pass this test by being "close enough".
            let mirrored = CGPoint(x: -expected.x, y: -expected.y)
            XCTAssertGreaterThan(hypot(shift.x - mirrored.x, shift.y - mirrored.y), 1,
                                 "\(name): a pan the wrong way round would have passed this test")
        }
        print("① drag follows the hand · " + rows.joined(separator: " · "))
    }

    /// The pixel under the pointer at `mouseDown` is still under the pointer at every step of the
    /// drag — the "grab the photo and move it" reading of 跟手, at 1:1 where a point is a device pixel.
    /// A diagonal drag, so a swapped axis shows up as drift instead of as nothing happening.
    func testTheGrabbedPixelStaysUnderTheCursor() throws {
        let (loupe, _, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        oneToOne(loupe)

        let start = Self.centre
        let delta = CGSize(width: 96, height: -64)          // right and down, in the hand's terms
        let grabbed = try sourcePixel(loupe, at: start)
        loupe.canvasView.mouseDown(with: try mouseEvent(.leftMouseDown, canvas: start,
                                                       loupe: loupe, window: window))
        var worst = 0.0
        for step in 1 ... 6 {
            let t = CGFloat(step) / 6
            let cursor = CGPoint(x: start.x + delta.width * t, y: start.y - delta.height * t)
            loupe.canvasView.mouseDragged(with: try mouseEvent(.leftMouseDragged, canvas: cursor,
                                                              loupe: loupe, window: window))
            CropUITestSupport.pump(0.005)
            let here = try sourcePixel(loupe, at: cursor)
            let drift = hypot(here.x - grabbed.x, here.y - grabbed.y)
            worst = max(worst, drift)
            XCTAssertLessThanOrEqual(drift, 0.5,
                                     "step \(step): the grabbed pixel drifted \(drift) px off the cursor")
        }
        loupe.canvasView.mouseUp(with: try mouseEvent(.leftMouseUp,
                                                     canvas: CGPoint(x: start.x + delta.width,
                                                                     y: start.y - delta.height),
                                                     loupe: loupe, window: window))
        print(String(format: "② grabbed pixel stays under the cursor · worst drift %.3f px over 6 steps",
                     worst))
    }

    // MARK: - 2. the scroll does not depend on 「自然滚动」

    /// The four (deltaY, inverted) combinations a trackpad can report, precise and wheel.
    ///
    /// `isDirectionInvertedFromDevice == true` (「自然滚动」 on, the macOS default) means the system has
    /// already turned the deltas into **content** movement, so the picture moves by `+delta`;
    /// `false` means they are the device's own direction, so the picture moves by `−delta`. Either way
    /// "two fingers down" is one and the same picture, which is what the equalities below pin.
    func testScrollIsTheSameGestureWhicheverWayTheSystemIsSet() throws {
        let (loupe, _, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        oneToOne(loupe)

        func shift(_ deltaX: Int32 = 0, _ deltaY: Int32, inverted: Bool,
                   pixel: Bool = true) throws -> CGPoint {
            let event = try scrollEvent(deltaX: deltaX, deltaY: deltaY, inverted: inverted, pixel: pixel)
            return try pictureShift(loupe) { loupe.canvasView.scrollWheel(with: event) }
        }

        var rows: [String] = []
        var measured: [String: CGPoint] = [:]
        for (name, deltaY, inverted) in [("inverted+100", Int32(100), true),
                                         ("inverted−100", Int32(-100), true),
                                         ("device+100", Int32(100), false),
                                         ("device−100", Int32(-100), false)] {
            let d = try shift(0, deltaY, inverted: inverted)
            measured[name] = d
            rows.append(String(format: "%@→(%.2f,%.2f)pt", name, d.x, d.y))
        }
        print("③ scroll precise · " + rows.joined(separator: " · "))

        let invertedDown = try XCTUnwrap(measured["inverted+100"])
        let invertedUp = try XCTUnwrap(measured["inverted−100"])
        let deviceDown = try XCTUnwrap(measured["device−100"])
        let deviceUp = try XCTUnwrap(measured["device+100"])

        // 1:1 magnitude, and the picture follows the fingers: +y is down on the canvas.
        XCTAssertEqual(invertedDown.x, 0, accuracy: 0.01)
        XCTAssertEqual(invertedDown.y, 100, accuracy: 1, "two fingers down must move the picture down")
        XCTAssertEqual(invertedUp.y, -100, accuracy: 1, "two fingers up must move the picture up")
        // The invariance: one physical gesture, reported the other way by the system.
        XCTAssertEqual(invertedDown.x, deviceDown.x, accuracy: 0.01)
        XCTAssertEqual(invertedDown.y, deviceDown.y, accuracy: 0.01,
                       "「自然滚动」 changed the result: inverted +100 and device −100 must agree")
        XCTAssertEqual(invertedUp.x, deviceUp.x, accuracy: 0.01)
        XCTAssertEqual(invertedUp.y, deviceUp.y, accuracy: 0.01,
                       "「自然滚动」 changed the result: inverted −100 and device +100 must agree")
        // Anti-proof: the raw delta sign is not the answer. An implementation that ignored the flag
        // (what shipped) lands 200 pt away on this row, and that is rejected here.
        XCTAssertGreaterThan(abs(deviceUp.y - 100), 1,
                             "the non-inverted event moved with the raw delta — the flag was ignored")
        // …and neither is the mirror of the inverted row.
        XCTAssertGreaterThan(abs(invertedDown.y - -100), 1,
                             "the inverted event moved against the content — the sign was flipped")

        // Horizontal, same rule.
        let right = try shift(100, 0, inverted: true)
        let rightDevice = try shift(-100, 0, inverted: false)
        print(String(format: "③ scroll · two fingers right→(%.2f,%.2f)pt · device−100→(%.2f,%.2f)pt",
                     right.x, right.y, rightDevice.x, rightDevice.y))
        XCTAssertEqual(right.x, 100, accuracy: 1, "two fingers right must move the picture right")
        XCTAssertEqual(right.y, 0, accuracy: 0.01)
        XCTAssertEqual(right.x, rightDevice.x, accuracy: 0.01)
        XCTAssertEqual(right.y, rightDevice.y, accuracy: 0.01)

        // A wheel keeps its ×12: one line of `scrollingDeltaY` is one notch, and a notch is 12 pt.
        let notch = try shift(0, 1, inverted: true, pixel: false)
        let notchDevice = try shift(0, -1, inverted: false, pixel: false)
        print(String(format: "③ scroll wheel 1 notch→(%.2f,%.2f)pt · device 1 notch→(%.2f,%.2f)pt",
                     notch.x, notch.y, notchDevice.x, notchDevice.y))
        XCTAssertEqual(notch.x, 0, accuracy: 0.01)
        XCTAssertEqual(notch.y, 12, accuracy: 0.5, "the wheel lost its ×12")
        XCTAssertEqual(notch.x, notchDevice.x, accuracy: 0.01)
        XCTAssertEqual(notch.y, notchDevice.y, accuracy: 0.01,
                       "a wheel notch must land in the same place either way the system is set")
    }

    // MARK: - 3. straighten keeps the picture on the screen's axes

    /// With the picture straightened the pan is still a screen-axis translation: the hand moves right,
    /// the photograph moves right — it does not slide along the picture's own rotated axis.
    /// (`LoupeFraming.panning` rotates the delta into source space and the projection rotates it back,
    /// which is exact, so the tolerance here is the measurement's, not the maths'.)
    func testStraightenedPictureStillPansAlongTheScreenAxis() throws {
        for degrees in [9.0, 45.0] {
            let (loupe, session, window) = try makeLoupe()
            defer { window.orderOut(nil) }
            session.applyEdit { $0.geometry.rotationDegrees = degrees }
            CropUITestSupport.pump(0.02)
            oneToOne(loupe)

            let before = loupe.viewState
            let grabbed = try sourcePixel(loupe, at: Self.centre)
            let a = try screenPoint(loupe, of: grabbed, in: before)
            loupe.panImage(byPoints: CGSize(width: 120, height: 0))
            CropUITestSupport.pump(0.02)
            let after = loupe.viewState
            let b = try screenPoint(loupe, of: grabbed, in: after)
            let shift = CGPoint(x: b.x - a.x, y: b.y - a.y)
            print(String(format: "④ straighten %.0f° · hand(120,0)→picture(%.2f,%.2f)pt",
                         degrees, shift.x, shift.y))
            XCTAssertGreaterThanOrEqual(shift.x, 119,
                                        "\(degrees)°: the picture did not travel 120 pt along screen x")
            XCTAssertLessThanOrEqual(abs(shift.y), 2,
                                     "\(degrees)°: the picture slid off the screen axis (y \(shift.y) pt)")
        }
    }

    // MARK: - 4. the edge rule is untouched

    /// A drag and a scroll both still stop at `minimumPictureCoverage`, and stay stopped — the same
    /// rule `LoupeZoomTests.testPanStopsAtTheCoverageLimitNotAtTheFrameEdge` pins as maths.
    func testBothPathsStillStopAtTheCoverageLimit() throws {
        let (loupe, _, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        oneToOne(loupe)
        let framing = try XCTUnwrap(loupe.framing())

        // Hand right and down: the picture goes right and down, so the camera goes to the crop's
        // top-left corner and stops there.
        _ = try pictureShift(loupe) {
            try? drag(loupe, from: Self.centre, by: CGSize(width: 60_000, height: -60_000),
                      steps: 2, window: window)
        }
        let atEdge = loupe.viewState
        XCTAssertEqual(atEdge.centerX, framing.cropOriginX, accuracy: 0.5,
                       "a drag to the right must stop the centre on the crop's left edge")
        XCTAssertEqual(atEdge.centerY, framing.cropOriginY, accuracy: 0.5,
                       "a drag downwards must stop the centre on the crop's top edge")

        // The same from a scroll, in the other three directions: the centre never leaves the picture.
        for (deltaX, deltaY) in [(Int32(5000), Int32(0)), (Int32(0), Int32(5000)),
                                 (Int32(0), Int32(-5000))] {
            loupe.canvasView.scrollWheel(with: try scrollEvent(deltaX: deltaX, deltaY: deltaY,
                                                              inverted: true))
            CropUITestSupport.pump(0.01)
            let state = loupe.viewState
            XCTAssertTrue((framing.cropOriginX ... framing.cropOriginX + framing.cropWidthPixels)
                            .contains(state.centerX), "the centre left the picture in x")
            XCTAssertTrue((framing.cropOriginY ... framing.cropOriginY + framing.cropHeightPixels)
                            .contains(state.centerY), "the centre left the picture in y")
            XCTAssertEqual(state.zoom, 1, accuracy: 1e-9, "a pan changed the zoom")
        }
        // Letting go moves nothing: the limit is a stop, not a rubber band.
        let resting = loupe.viewState
        _ = try pictureShift(loupe) {
            try? drag(loupe, from: Self.centre, by: .zero, steps: 1, window: window)
        }
        XCTAssertEqual(loupe.viewState.centerX, resting.centerX, accuracy: 1e-9)
        XCTAssertEqual(loupe.viewState.centerY, resting.centerY, accuracy: 1e-9)
        print(String(format: "⑤ edge · drag clamped centre (%.2f, %.2f) in crop [%.0f, %.0f]×[%.0f, %.0f]"
                     + " · after three scrolls (%.2f, %.2f)",
                     atEdge.centerX, atEdge.centerY, framing.cropOriginX,
                     framing.cropOriginX + framing.cropWidthPixels, framing.cropOriginY,
                     framing.cropOriginY + framing.cropHeightPixels,
                     resting.centerX, resting.centerY))
    }

    // MARK: - 5. the convention both call sites rest on

    /// The one sign relation the two paths are built on: a **camera** delta of `c` moves the picture
    /// by `−c`. `panImage` and `scrollPan` both feed `panning(_:byContent:)` and differ only in how
    /// they build `c` (window y-up for the hand, content/device direction for the scroll), so this is
    /// the line to read when one of them goes wrong again.
    func testThePictureMovesAgainstTheCameraDelta() throws {
        let framing = LoupeFraming(viewport: ImageSize(width: 2560, height: 1600),
                                   sourceWidth: Double(Self.source.width),
                                   sourceHeight: Double(Self.source.height),
                                   crop: .full, straightenDegrees: 0, flipH: false, flipV: false)
        for zoom in [1.0, 2.0] {
            let state = LoupeViewState(mode: .actual, zoom: zoom, centerX: 1500, centerY: 1000)
            for c in [(120.0, 0.0), (-120.0, 0.0), (0.0, -80.0), (0.0, 80.0)] {
                let before = framing.mapping(of: state)
                    .viewPoint(sourceX: state.centerX, sourceY: state.centerY)
                let next = framing.panning(state, byContent: (x: c.0, y: c.1))
                let after = framing.mapping(of: next)
                    .viewPoint(sourceX: state.centerX, sourceY: state.centerY)
                XCTAssertEqual(after.x - before.x, -c.0, accuracy: 1e-9,
                               "\(zoom):1 — the picture did not move against the camera delta in x")
                XCTAssertEqual(after.y - before.y, -c.1, accuracy: 1e-9,
                               "\(zoom):1 — the picture did not move against the camera delta in y")
                XCTAssertEqual(next.zoom, state.zoom, accuracy: 1e-12, "a pan changed the zoom")
            }
        }
    }
}
