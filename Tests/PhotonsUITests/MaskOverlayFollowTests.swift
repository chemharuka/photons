import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ③ (2026-10-27) — the mask chrome travels **with the picture**, on every frame of a pan and of a
/// zoom animation.
///
/// The report: 「蒙版的控件在画面移动/缩放时不是和画面同时移动的，不跟手」. Both halves of that are
/// the same defect with two faces:
///
///   · a **pan** moves the picture on the pan's own tick (`setViewState`), and the grips were only
///     rebuilt when the *document* changed — so they stood still under a moving picture;
///   · a **stop change** is not a camera at all: the canvas keeps the old picture and re-presents it
///     every display tick through a sampling window, i.e. one similarity
///     (`LoupeZoomBridge.map(atProgress:)`). The grips were laid out on the target camera, so they
///     sat where the picture would be in 180 ms instead of where it was.
///
/// The answer is the one the crop overlay already ships (②): project the mask's geometry with the
/// mapping the canvas pixels were laid out with, then carry it by that frame's own `(scale, offset)`,
/// **in the tick that presented the frame**. No second timeline — the loupe has one camera and one
/// bridge, and both overlays ride them.
///
/// Measured here on a real window, a real `LoupeController`, a real decode and a real bridge:
///
///   1. a **400 pt pan in 20 steps** — the grips and every guide are on `mapping(照片坐标)` to
///      floating point (`testPan…`, and the radial + feather ring in `testRadialRimAndFeather…`);
///   2. a **1:1 → 50 % → 25 % zoom**, every presented frame (≥ 20 of them) — error 0, including a
///      rubber band that is in flight while the animation runs (`testZoom…`, `testTheDraft…`);
///   3. the reverse evidence: with the per-camera refresh cut away a pan of 400 pt leaves the chrome
///      **400 pt** behind (`testOnlyTheGestureEnd…`), and with the bridge follow cut away the middle of
///      a 1:1 → 25 % transition is **hundreds of pt** off (`testWithoutTheBridgeFollow…`);
///   4. the chrome is **not** a render: panning, zooming and hiding it changes no pixel
///      (`testTheChromeIsNotARender`).
@MainActor
final class MaskOverlayFollowTests: XCTestCase {

    /// The frame source's viewport (device pixels). The window below is 320×200 pt at backing scale 2,
    /// so this is exactly the canvas — the same numbers `CropOverlayZoomFollowTests` uses.
    private static let viewport = ImageSize(width: 640, height: 400)
    /// The task's tolerance for the pan table.
    private static let panTolerance: CGFloat = 0.5

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-mask-follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

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

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    /// A loupe with both halves of the shipped path: the session (so a mask has an anchor and a real
    /// source frame) and a frame source (so the pixels — and therefore the bridge — are real).
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let url = try rawFixture()
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.reducesMotion = false          // 减弱动态效果 would take the animation away
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)

        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "mask-follow",
                                                        viewport: Self.viewport, state: .fit)
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        pump(0.1)
        return (loupe, session, window)
    }

    /// One mask with `shape`, selected — the document state the grips are drawn from.
    private func install(_ shape: MaskShape, feather: Double = 0.5,
                         in session: CatalogSession) -> String {
        let id = "m-follow"
        session.applyEdit {
            $0.masks = [Mask(id: id,
                             components: [MaskComponent(id: "c-follow", feather: feather,
                                                        shape: shape)])]
        }
        session.setSelectedMaskID(id)
        session.commitEdit(label: "新建蒙版")
        return id
    }

    /// Park the camera at 1:1 with nothing animating, and put the 蒙版 workspace up (its chrome is only
    /// drawn there).
    private func openMasks(_ loupe: LoupeController) throws {
        loupe.setMasksWorkspaceActive(true)
        loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the 1:1 landing never finished")
        XCTAssertEqual(loupe.viewState.zoom, 1, accuracy: 1e-12)
    }

    // MARK: - the theory: where a grip belongs, from the picture's own coordinates

    /// The grips the **picture** puts at a point, in view points, at rest: the shape's normalised
    /// handles through the projection the loupe says the canvas pixels are in.
    ///
    /// Derived from `MaskHandles.handles` (the shape's own geometry) and the projection — **not** from
    /// `MaskHandles.layout`, which is the thing under test.
    private func expectedGrips(_ shape: MaskShape, source: ImageSize,
                               projection: LoupeController.MaskPictureProjection)
        -> [(kind: MaskHandleKind, point: CGPoint)] {
        MaskHandles.handles(for: shape, source: source).map { handle in
            let v = projection.mapping.viewPoint(sourceX: handle.point.x * Double(source.width),
                                                 sourceY: handle.point.y * Double(source.height))
            return (handle.kind,
                    CGPoint(x: projection.carry.applyX(v.x) / projection.pointScale,
                            y: projection.carry.applyY(v.y) / projection.pointScale))
        }
    }

    /// The same, on one **frame of a bridge**: the old picture's mapping, then that frame's own
    /// similarity — the transform the present pass drew the pixels with.
    private func expectedGrips(_ shape: MaskShape, source: ImageSize,
                               bridge: LoupeZoomBridge, progress t: Double, pointScale k: Double)
        -> [(kind: MaskHandleKind, point: CGPoint)] {
        MaskHandles.handles(for: shape, source: source).map { handle in
            let v = bridge.fromMapping.viewPoint(sourceX: handle.point.x * Double(source.width),
                                                 sourceY: handle.point.y * Double(source.height))
            let moved = bridge.canvasPoint(atProgress: t, of: (x: v.x, y: v.y))
            return (handle.kind, CGPoint(x: moved.x / k, y: moved.y / k))
        }
    }

    /// The worst distance between what was drawn and the theory, and which grip it was.
    private func deviation(drawn: MaskHandlesLayout,
                           want: [(kind: MaskHandleKind, point: CGPoint)])
        -> (error: CGFloat, where_: String) {
        var worst: CGFloat = 0
        var where_ = "—"
        for (index, grip) in drawn.grips.enumerated() where index < want.count {
            let d = hypot(grip.point.x - want[index].point.x, grip.point.y - want[index].point.y)
            if d > worst { worst = d; where_ = "\(grip.kind)" }
        }
        return (worst, where_)
    }

    /// How far the drawn guides are from the **same translation** the grips moved by — the invariance a
    /// stale guide would break (the grips can be right while the rings and iso-lines stayed behind, and
    /// then the picture has a control the hand can see and the numbers disagree with).
    private func guideResidual(drawn: MaskHandlesLayout, from base: MaskHandlesLayout) -> CGFloat {
        guard let a = drawn.grips.first?.point, let b = base.grips.first?.point,
              drawn.guides.count == base.guides.count else { return .infinity }
        let dx = a.x - b.x, dy = a.y - b.y
        var worst: CGFloat = 0
        for (index, guide) in drawn.guides.enumerated() {
            let old = base.guides[index]
            guard guide.points.count == old.points.count else { return .infinity }
            for (p, q) in zip(guide.points, old.points) {
                worst = max(worst, hypot(p.x - (q.x + dx), p.y - (q.y + dy)))
            }
        }
        return worst
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let x = points.reduce(0) { $0 + Double($1.x) } / Double(points.count)
        let y = points.reduce(0) { $0 + Double($1.y) } / Double(points.count)
        return CGPoint(x: x, y: y)
    }

    private func meanRadius(_ points: [CGPoint], around centre: CGPoint) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + hypot($1.x - centre.x, $1.y - centre.y) } / CGFloat(points.count)
    }

    private func linear() -> MaskShape {
        .linearGradient(LinearGradientShape(start: NormalizedPoint(0.30, 0.25),
                                            end: NormalizedPoint(0.70, 0.75), midpoint: 0.5))
    }

    private func radial() -> MaskShape {
        .radialGradient(RadialGradientShape(center: NormalizedPoint(0.45, 0.55),
                                            radius: NormalizedPoint(0.28, 0.20), angle: 12))
    }

    // MARK: - 1. the pan: 400 pt in 20 steps

    func testPanCarriesTheHandlesWithThePicture() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        let shape = linear()
        install(shape, in: session)
        try openMasks(loupe)

        let source = session.maskSourceSize
        let base = try XCTUnwrap(loupe.maskHandlesLayoutForTesting, "nothing drawn at rest")
        var rows: [(step: Int, error: CGFloat, where_: String, guides: CGFloat)] = []
        var worst: CGFloat = 0
        for step in 1...20 {
            // 20 pt a step, 20 steps: the 400 pt the task names.
            loupe.panImage(byPoints: CGSize(width: -20, height: 0))
            let drawn = try XCTUnwrap(loupe.maskHandlesLayoutForTesting, "step \(step): nothing drawn")
            let projection = try XCTUnwrap(loupe.maskPictureProjection())
            XCTAssertEqual(projection.carry, .identity, "a pan is not an animation — no carry")
            let want = expectedGrips(shape, source: source, projection: projection)
            let dev = deviation(drawn: drawn, want: want)
            worst = max(worst, dev.error)
            rows.append((step, dev.error, dev.where_, guideResidual(drawn: drawn, from: base)))
        }

        print("③ 平移 400 pt / 20 步 · 线性渐变 · 手柄 vs mapping(照片坐标) 理论值")
        for row in rows {
            print(String(format: "        step %2d · error %.5f pt (%@) · guides %.5f pt",
                         row.step, row.error, row.where_, row.guides))
        }
        print(String(format: "③ 平移最差误差 %.5f pt（容差 %.1f pt）", worst, Self.panTolerance))

        // The pan is real: the chrome travelled the 400 pt with the picture (a pan that did not move
        // would make every row above trivially zero).
        let moved = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        let travel = hypot(moved.grips[0].point.x - base.grips[0].point.x,
                           moved.grips[0].point.y - base.grips[0].point.y)
        print(String(format: "③ 手柄随画面移动 %.3f pt（400 pt 平移）", travel))
        XCTAssertGreaterThan(travel, 380, "the pan did not move the chrome — the table means nothing")

        for row in rows {
            XCTAssertLessThanOrEqual(row.error, Self.panTolerance,
                                     String(format: "step %d: the grip is %.5f pt off the picture (%@)",
                                            row.step, row.error, row.where_))
            XCTAssertLessThanOrEqual(row.guides, Self.panTolerance,
                                     String(format: "step %d: a guide is %.5f pt off the translation",
                                            row.step, row.guides))
        }
    }

    /// The radial shape: the rim ring and the feather ring are the same claim, at the shape's own
    /// radius and at `1 − feather` of it (a control the hand can see that is off by a pixel is a bug
    /// even when the six dots are right).
    func testRadialRimAndFeatherRingFollowThePan() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        let shape = radial()
        install(shape, feather: 0.5, in: session)
        try openMasks(loupe)

        let base = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        let baseRim = try XCTUnwrap(base.guides.first { $0.style == .rim })
        let baseFeather = try XCTUnwrap(base.guides.first { $0.style == .featherRing })
        var rows: [(step: Int, error: CGFloat, rimOffset: CGFloat, featherOffset: CGFloat,
                    ratio: CGFloat)] = []
        var worstError: CGFloat = 0
        var worstOffset: CGFloat = 0
        var worstRatio: CGFloat = 0
        for step in 1...20 {
            loupe.panImage(byPoints: CGSize(width: 0, height: 20))
            let drawn = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
            let projection = try XCTUnwrap(loupe.maskPictureProjection())
            let dev = deviation(drawn: drawn, want: expectedGrips(shape, source: session.maskSourceSize,
                                                                  projection: projection))
            let rim = try XCTUnwrap(drawn.guides.first { $0.style == .rim })
            let feather = try XCTUnwrap(drawn.guides.first { $0.style == .featherRing })
            let rimCentre = centroid(rim.points), featherCentre = centroid(feather.points)
            // Both rings must sit exactly where the picture carried them: the same translation the
            // grip set moved by (`cancel` to zero for the comparison).
            let shift = CGPoint(x: rimCentre.x - centroid(baseRim.points).x,
                                y: rimCentre.y - centroid(baseRim.points).y)
            let featherShift = CGPoint(x: featherCentre.x - centroid(baseFeather.points).x,
                                       y: featherCentre.y - centroid(baseFeather.points).y)
            let ratio = meanRadius(feather.points, around: featherCentre)
                / meanRadius(rim.points, around: rimCentre)
            worstError = max(worstError, dev.error)
            worstOffset = max(worstOffset, hypot(featherShift.x - shift.x, featherShift.y - shift.y))
            worstRatio = max(worstRatio, abs(ratio - 0.5))
            rows.append((step, dev.error, hypot(shift.x, shift.y), worstOffset, ratio))
        }

        print("③ 平移 400 pt / 20 步 · 径向渐变（含半径 + 羽化环）")
        for row in rows {
            print(String(format: "        step %2d · grips %.5f pt · rim 中心移动 %.3f pt · 羽化环偏移 %.5f pt · 环比 %.6f",
                         row.step, row.error, row.rimOffset, row.featherOffset, row.ratio))
        }
        print(String(format: "③ 径向最差：手柄 %.5f pt · 羽化环 %.5f pt · 环比偏差 %.6f",
                     worstError, worstOffset, worstRatio))

        XCTAssertLessThanOrEqual(worstError, Self.panTolerance)
        XCTAssertLessThanOrEqual(worstOffset, Self.panTolerance,
                                 "the feather ring is not carried with the rim")
        XCTAssertLessThanOrEqual(worstRatio, 1e-6, "the feather ring's radius drifted")
    }

    // MARK: - 2. the zoom animation, frame by frame

    func testZoomAnimationCarriesTheHandlesFrameByFrame() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        let shape = linear()
        install(shape, in: session)
        try openMasks(loupe)

        let k = loupe.backingScale
        let source = session.maskSourceSize
        let atRest = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        let oldState = loupe.viewState

        var rows: [(serial: Int, t: Double, error: CGFloat, where_: String)] = []
        var worst: CGFloat = 0
        var presented = 0
        var atEnd: MaskHandlesLayout?

        // 1:1 → 50 % → 25 %: two bridges, one after the other — a 2× shrink and then another 2×, so a
        // chrome that only moved at the two ends is wrong in the middle by a quarter of the picture.
        for stop in [0.5, 0.25] {
            let armed = loupe.zoomBridgeArmedCount
            loupe.zoom(to: stop, aroundView: nil)
            let bridge = try XCTUnwrap(loupe.zoomBridge,
                                       "a stop change with a picture on screen must bridge")
            XCTAssertEqual(loupe.zoomBridgeArmedCount, armed + 1)
            XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the bridge never ended")

            let frames = loupe.maskOverlayFollowFrames.filter { $0.serial == armed + 1 }
            XCTAssertGreaterThanOrEqual(frames.count, 5,
                                        "only \(frames.count) frames — a transition is not two pictures")
            presented += frames.count
            for frame in frames {
                let drawn = try XCTUnwrap(frame.handles, "the workspace is up, so a layout must be drawn")
                let want = expectedGrips(shape, source: source, bridge: bridge,
                                         progress: frame.progress, pointScale: k)
                let dev = deviation(drawn: drawn, want: want)
                worst = max(worst, dev.error)
                rows.append((armed + 1, frame.progress, dev.error, dev.where_))
            }
            atEnd = loupe.maskHandlesLayoutForTesting
        }

        print("③ 缩放 1:1 → 50 % → 25 % · \(presented) 个 presented 帧 · 逐帧误差")
        for row in rows {
            print(String(format: "        bridge %d · t %.4f · error %.6f pt (%@)",
                         row.serial, row.t, row.error, row.where_))
        }
        print(String(format: "③ 缩放最差帧误差 %.6f pt（%d 帧）", worst, rows.count))

        XCTAssertGreaterThanOrEqual(presented, 20, "the acceptance asks for ≥ 20 presented frames")
        XCTAssertTrue(rows.contains { $0.t > 0.3 && $0.t < 0.9 },
                      "the record must contain mid-transition frames, not just the ends")
        for row in rows {
            XCTAssertLessThanOrEqual(row.error, Self.panTolerance,
                                     String(format: "bridge %d t %.4f: %.6f pt off (%@)",
                                            row.serial, row.t, row.error, row.where_))
        }

        // At rest the error is **exactly zero**: the same layout function the idle path uses.
        let target = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        XCTAssertEqual(target, try XCTUnwrap(loupe.maskHandlesLayout()),
                       "at rest the overlay must be the projection's own layout")
        XCTAssertEqual(loupe.viewState.zoom, 0.25, accuracy: 1e-12)
        if let atEnd { XCTAssertEqual(atEnd, target, "the last frame is already the stop's own geometry") }
        // …and the chrome really did shrink with the picture.
        let oldZoom = try XCTUnwrap(loupe.framing()).zoom(of: oldState)
        let ratio = meanRadius(target.grips.map(\.point), around: centroid(target.grips.map(\.point)))
            / meanRadius(atRest.grips.map(\.point), around: centroid(atRest.grips.map(\.point)))
        XCTAssertEqual(ratio, 0.25 / oldZoom, accuracy: 0.03,
                       "the grips' own spread must shrink with the picture")
    }

    /// A rubber band that is **in flight** when the animation starts is a second thing the eye is
    /// watching: it is stored in source pixels, so it has to be re-projected on every frame too.
    func testTheDraftTravelsWithTheZoomAnimation() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        install(linear(), in: session)
        try openMasks(loupe)

        // Arm a creation and hold the band half-drawn, so it is on screen while the zoom runs.
        session.createMask(.linearGradient)
        XCTAssertEqual(session.pendingMaskShape, .linearGradient)
        let start = CGPoint(x: 120, y: 90), current = CGPoint(x: 210, y: 150)
        loupe.beginShapeDrag(at: start)
        loupe.continueShapeDrag(at: current)
        let drawn = try XCTUnwrap(loupe.maskDraftForTesting, "the rubber band is not on screen")
        // Its two ends, in source pixels — the river the frames below are re-projected from.
        let sourceStart = try XCTUnwrap(loupe.sourcePoint(forViewPoint: start))
        let sourceCurrent = try XCTUnwrap(loupe.sourcePoint(forViewPoint: current))
        XCTAssertEqual(drawn.start.x, start.x, accuracy: 1e-9,
                       "at rest the band is drawn under the hand")

        let k = loupe.backingScale
        var worst: CGFloat = 0
        var rows: [(t: Double, start: CGPoint, want: CGPoint, error: CGFloat)] = []
        var presented = 0
        for stop in [0.5, 0.25] {
            let armed = loupe.zoomBridgeArmedCount
            loupe.zoom(to: stop, aroundView: nil)
            let bridge = try XCTUnwrap(loupe.zoomBridge)
            XCTAssertTrue(waitFor { loupe.zoomBridge == nil })
            let frames = loupe.maskOverlayFollowFrames.filter { $0.serial == armed + 1 }
            presented += frames.count
            for frame in frames {
                let band = try XCTUnwrap(frame.draft, "the band is in flight — it must be drawn")
                for (got, want) in [(band.start, sourceStart), (band.current, sourceCurrent)] {
                    let v = bridge.fromMapping.viewPoint(sourceX: want.x, sourceY: want.y)
                    let moved = bridge.canvasPoint(atProgress: frame.progress, of: (x: v.x, y: v.y))
                    let expected = CGPoint(x: moved.x / k, y: moved.y / k)
                    let error = hypot(got.x - expected.x, got.y - expected.y)
                    worst = max(worst, error)
                    if error > 0 { rows.append((frame.progress, got, expected, error)) }
                }
            }
        }
        print(String(format: "③ 在飞 draft · %d 个 presented 帧 · 最差误差 %.6f pt", presented, worst))
        for row in rows.prefix(5) {
            print(String(format: "        t %.4f · drawn (%.3f, %.3f) · expected (%.3f, %.3f) · %.6f pt",
                         row.t, row.start.x, row.start.y, row.want.x, row.want.y, row.error))
        }
        XCTAssertGreaterThanOrEqual(presented, 20)
        XCTAssertLessThanOrEqual(worst, Self.panTolerance)

        // The band follows the hand again once the animation is over, and it is still a band.
        loupe.continueShapeDrag(at: CGPoint(x: 230, y: 160))
        XCTAssertEqual(loupe.maskDraftForTesting?.current.x ?? -1, 230, accuracy: 1e-9)
        loupe.cancelShapeDrag()
        XCTAssertNil(loupe.maskDraftForTesting)
    }

    // MARK: - 3. the reverse evidence

    /// The pre-③ behaviour for a pan — the chrome rebuilt only when a gesture **ends** (a document
    /// change), never on the camera's own tick. 400 pt of pan, and the grips stay where they started.
    func testOnlyTheGestureEndWouldMoveTheChrome() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        install(linear(), in: session)
        try openMasks(loupe)
        // The seam: the camera no longer tells the chrome anything (exactly the shipped defect).
        loupe.syncsMaskOverlaysOnCameraChange = false

        let base = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        for _ in 1...20 { loupe.panImage(byPoints: CGSize(width: -20, height: 0)) }
        let stale = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)
        let projection = try XCTUnwrap(loupe.maskPictureProjection())
        let dev = deviation(drawn: stale,
                            want: expectedGrips(linear(), source: session.maskSourceSize,
                                                projection: projection))
        print(String(format: "③ 反证（只在手势结束同步）· 平移 400 pt 后手柄误差 %.3f pt", dev.error))
        XCTAssertGreaterThan(dev.error, 100,
                             "the anti-proof must be visibly red — it was \(dev.error) pt")
        XCTAssertEqual(stale, base, "without the camera callback the overlay never moved at all")
    }

    /// The pre-③ behaviour for a stop change: the chrome is laid out on the **target** camera at frame
    /// 0 and left there while the picture travels, so the middle of the transition is off by most of
    /// the geometry's own displacement.
    func testWithoutTheBridgeFollowTheChromeJumpsToTheTarget() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        install(linear(), in: session)
        try openMasks(loupe)
        loupe.followsMaskOverlaysDuringBridge = false

        let k = loupe.backingScale
        let armed = loupe.zoomBridgeArmedCount
        loupe.zoom(to: 0.25, aroundView: nil)
        let bridge = try XCTUnwrap(loupe.zoomBridge)
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil })

        let frames = loupe.maskOverlayFollowFrames.filter { $0.serial == armed + 1 }
        XCTAssertGreaterThanOrEqual(frames.count, 5)
        var worst: (t: Double, error: CGFloat) = (0, 0)
        for frame in frames {
            guard let drawn = frame.handles else { continue }
            let want = expectedGrips(linear(), source: session.maskSourceSize, bridge: bridge,
                                     progress: frame.progress, pointScale: k)
            let dev = deviation(drawn: drawn, want: want)
            if dev.error > worst.error { worst = (frame.progress, dev.error) }
        }
        print(String(format: "③ 反证（不跟随 bridge）· 最差帧 t %.3f · 误差 %.3f pt", worst.t, worst.error))
        XCTAssertGreaterThan(worst.error, 100,
                             "the anti-proof must be visibly red — it was \(worst.error) pt at t \(worst.t)")
    }

    // MARK: - 4. the chrome is not a render

    /// The overlays are AppKit views over the canvas: panning, zooming and hiding them must not touch a
    /// pixel or the document. Measured on the **presented** pixels' SHA-256, and on `editRevision`.
    func testTheChromeIsNotARender() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        let url = try rawFixture()
        install(radial(), in: session)
        try openMasks(loupe)

        func hash(_ state: LoupeViewState) throws -> String {
            let frame = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                            edit: session.edit, state: state, hashPixels: true)
            return try XCTUnwrap(frame.displayHash)
        }
        let revision = session.editRevision
        let before = try hash(.fit)

        for _ in 1...20 { loupe.panImage(byPoints: CGSize(width: 12, height: -8)) }
        loupe.zoom(to: 0.5, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil })
        loupe.setMasksWorkspaceActive(false)
        loupe.setMasksWorkspaceActive(true)
        pump(0.05)

        let after = try hash(.fit)
        print("③ 像素不变 · \(before.prefix(16)) → \(after.prefix(16)) · editRevision \(revision)")
        XCTAssertEqual(before, after, "the mask chrome changed the pixels")
        XCTAssertEqual(session.editRevision, revision, "the mask chrome wrote to the document")
    }
}
