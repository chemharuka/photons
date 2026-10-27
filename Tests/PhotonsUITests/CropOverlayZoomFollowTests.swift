import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ② (2026-10-27) — the crop overlay travels **with the zoom animation**, frame by frame.
///
/// The report: 「点击缩放条/⌘=/⌘− 切倍率时，照片有过渡动画，但裁切框是瞬跳（或在动画结束后才到位）」.
///
/// The picture does not move on a stop change: it is the *old* frame on the canvas, re-presented every
/// display tick through a sampling window, i.e. carried by one similarity
/// (`LoupeZoomBridge.map(atProgress:)`). The crop frame is a rect of that picture, so the only honest
/// answer on frame `t` is "project the crop rect with the mapping the pixels were laid out with, then
/// carry it by that frame's own `(scale, offset)`" — and do it in the tick that presented the frame.
///
/// What is measured here, on a real window, a real `LoupeController`, a real decode and a real crop
/// tool:
///
///   1. **every** frame the bridge presented: the quad's four corners, the eight grips and the
///      nine-square grid are within **1 pt** of the similarity's own projection (`testTheOverlay…`);
///   2. at rest the error is **0** (the same layout function the non-animating path uses);
///   3. the reverse evidence: with the overlay refresh cut away from the animation
///      (`followsCropOverlayDuringBridge = false`) the same per-frame number goes **> 1 pt**
///      (`testOnlyTheTwoEndsWouldBeRed`);
///   4. two stop changes in a row (a held ⌘=) neither jump back nor oscillate, and still end exactly
///      on the target (`testTwoZoomsInARowDoNotJumpBackOrRing`);
///   5. a photo switch mid-animation cannot leave the old picture's frame on screen
///      (`testSwitchingPhotoMidAnimation…`).
@MainActor
final class CropOverlayZoomFollowTests: XCTestCase {

    /// The frame source's viewport (device pixels). The window below is 320×200 pt at backing scale 2,
    /// so this is exactly the canvas — the same numbers `LoupeZoomAnchorProgressTests` uses.
    private static let viewport = ImageSize(width: 640, height: 400)
    /// A frame small enough to be legal at **1:1 and at 12.5 %** in this harness, so ⑦'s clamp never
    /// moves the draft while the animation is being measured.
    ///
    /// The harness decodes the 9520×6336 fixture at a preview rung (4760×3168), and `maskSourceSize`
    /// reports the *ingested* size — so the crop space here is the half-size one and a frame that is
    /// legal at 1:1 is a small part of the picture. The claim under test is about the **similarity**
    /// (does the overlay sit on the picture on every frame), not about where the frame is, so a small
    /// frame is the honest way to keep the clamp out of the measurement.
    private static let crop = CropRect(left: 0.48, top: 0.50, right: 0.56, bottom: 0.56)
    private static let tolerance: CGFloat = 1.0

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-follow-zoom-\(UUID().uuidString)", isDirectory: true)
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

    /// A loupe with **both** halves of the shipped path: the session (so 裁切 mode has an anchor and a
    /// real source size) and a frame source (so the pixels come from the RAW fixture, decodable, with no
    /// catalog import). The crop tool only needs the former; the bridge only needs the latter.
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let url = try rawFixture()
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        // The animation is the subject; a machine with 减弱动态效果 on would take it away.
        loupe.reducesMotion = false
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
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "crop-follow-zoom",
                                                        viewport: Self.viewport, state: .fit)
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        pump(0.1)
        // NOTE for the numbers below: this harness renders through a `frameSource`, and the renderer
        // ingests the fixture at a preview rung (4760×3168), which the session then reports as
        // `maskSourceSize` — while `framing()` reports the full 9520×6336. The crop layout is therefore
        // expressed in the *rung's* space here while the projection is the full frame's, so the frame
        // sits off to one side of the canvas in these screenshots. That shifts **where** the frame is
        // drawn, never **whether it travels with the picture** — which is the claim, and it is measured
        // against the bridge's own map (`deviation(drawn:from:bridge:…)`). `testElevenProgresses…`
        // gives the same table on a projection with a single source size, i.e. on-screen numbers.
        return (loupe, session, window)
    }

    /// The crop tool up, a legal frame, and the camera parked at **1:1** with nothing animating.
    private func openCrop(_ loupe: LoupeController, _ session: CatalogSession) throws {
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the entry zoom never finished")
        XCTAssertEqual(loupe.viewState.mode, .fit, "entering 裁切 goes to fit")
        loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the 1:1 landing never finished")
        // ⑦'s clamp is switched off **for this measurement only**: the harness decodes the fixture at a
        // preview rung, and `maskSourceSize` reports the ingested size while `framing()` reports the
        // full one, so the clamp's "room" is computed in a source space the mapping does not use — its
        // own suite (`CropFrameClampTests`) pins the behaviour, and ② is about the similarity.
        loupe.cropTool.clampsFrameToView = false
        loupe.cropTool.draft = CropToolController.Draft(crop: Self.crop)
        loupe.refreshCropTool()
        pump(0.05)
        XCTAssertEqual(loupe.viewState.zoom, 1, accuracy: 1e-12)
        XCTAssertEqual(loupe.cropTool.draft.crop, Self.crop, "the harness' frame is the one under test")
    }

    /// The rect a layout's four corners span, in points — the number the report prints.
    private func rect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// One frame's worst deviation, in points: quad corners, eight grips and every grid endpoint,
    /// each against `carry ∘ (the same point at rest before the animation)`.
    ///
    /// The reference is the bridge's own map — the transform the present pass drew with — so this
    /// measures exactly "does the overlay sit on the picture the eye is looking at".
    private func deviation(drawn: CropToolLayout,
                           from old: CropToolLayout,
                           bridge: LoupeZoomBridge,
                           progress t: Double,
                           backingScale k: Double) -> (worst: CGFloat, where: String) {
        func carried(_ p: CGPoint) -> CGPoint {
            let moved = bridge.canvasPoint(atProgress: t,
                                           of: (x: Double(p.x) * k, y: Double(p.y) * k))
            return CGPoint(x: moved.x / k, y: moved.y / k)
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        var worst: CGFloat = 0
        var where_ = ""
        for (index, corner) in drawn.corners.enumerated() where index < old.corners.count {
            let d = distance(corner, carried(old.corners[index]))
            if d > worst { worst = d; where_ = "corner \(index)" }
        }
        for (index, grip) in drawn.grips.enumerated() where index < old.grips.count {
            let d = distance(grip.point, carried(old.grips[index].point))
            if d > worst { worst = d; where_ = "grip \(grip.kind)" }
        }
        for (index, segment) in drawn.grid.enumerated() where index < old.grid.count {
            let d = max(distance(segment.a, carried(old.grid[index].a)),
                        distance(segment.b, carried(old.grid[index].b)))
            if d > worst { worst = d; where_ = "grid \(index)" }
        }
        return (worst, where_)
    }

    /// The frames one bridge drew for the crop overlay, in presentation order.
    private func followFrames(_ loupe: LoupeController, serial: Int) -> [LoupeController.CropOverlayFollowFrame] {
        loupe.cropOverlayFollowFrames.filter { $0.serial == serial }
    }

    // MARK: - ② the measurement, every presented frame

    func testTheOverlayFollowsEveryFrameOfTheZoomAnimation() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)

        let k = loupe.backingScale
        let oldState = loupe.viewState
        let old = try XCTUnwrap(loupe.cropOverlayLayoutForTesting, "nothing drawn before the zoom")
        XCTAssertEqual(old.corners.count, 4)
        XCTAssertEqual(old.grips.count, 8)
        XCTAssertEqual(old.grid.count, 4, "the nine-square grid is two lines each way")

        // 1:1 → 25 %: an 4× shrink, big enough that a stale frame is obvious.
        let armed = loupe.zoomBridgeArmedCount
        loupe.zoom(to: 0.25, aroundView: nil)
        let bridge = try XCTUnwrap(loupe.zoomBridge, "a stop change with a picture on screen must bridge")
        XCTAssertEqual(loupe.zoomBridgeArmedCount, armed + 1)
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the bridge never ended")

        let frames = followFrames(loupe, serial: armed + 1)
        XCTAssertGreaterThanOrEqual(frames.count, 5,
                                    "only \(frames.count) frames — a transition is not two pictures")

        var rows: [(t: Double, drawn: NSRect, want: NSRect, error: CGFloat, where_: String)] = []
        for frame in frames {
            let layout = try XCTUnwrap(frame.layout, "the tool was on, so a layout must have been drawn")
            let deviation = deviation(drawn: layout, from: old, bridge: bridge,
                                      progress: frame.progress, backingScale: k)
            // The rect the similarity gives, for the table.
            let wantCorners = old.corners.map { corner -> CGPoint in
                let moved = bridge.canvasPoint(atProgress: frame.progress,
                                               of: (x: Double(corner.x) * k, y: Double(corner.y) * k))
                return CGPoint(x: moved.x / k, y: moved.y / k)
            }
            let wantLayout = CropToolLayout(corners: wantCorners)
            rows.append((frame.progress, rect(layout), rect(wantLayout), deviation.worst,
                         deviation.where))
        }

        // The two ends, in the record rather than assumed. The first *presented* frame is the
        // ticker's first tick, which lands a fraction of a millisecond after the arm (`t ≈ 3e-4`); the
        // arm itself records frame 0 without a present, so "starts where the picture was" is the
        // claim, not an exact zero.
        XCTAssertLessThanOrEqual(rows.first?.t ?? 1, 0.01, "frame 0 is the picture as it was")
        XCTAssertGreaterThan(rows.last?.t ?? -1, 0.99, "…and the last frame is the stop's own geometry")
        XCTAssertTrue(rows.contains { $0.t > 0.35 && $0.t < 0.85 },
                      "the record must contain mid-transition frames, not just the ends")

        print("② 1:1 → 25 % · \(rows.count) frames · backing scale \(k) · old rect \(NSStringFromRect(rect(old)))")
        for row in rows {
            print(String(format: "        t %.3f · overlay %@ · expected %@ · error %.4f pt (%@)",
                         row.t, NSStringFromRect(row.drawn), NSStringFromRect(row.want),
                         row.error, row.where_))
        }
        let worst = rows.map(\.error).max() ?? .infinity
        print(String(format: "② worst per-frame error %.4f pt (tolerance %.1f pt)", worst, Self.tolerance))
        for row in rows {
            XCTAssertLessThanOrEqual(row.error, Self.tolerance,
                                     String(format: "② t %.3f: the overlay is %.4f pt off the picture "
                                            + "(%@)", row.t, row.error, row.where_))
        }

        // At rest: **zero**. The same `cropToolLayout()` the non-animating path uses, value for value.
        let atRest = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let target = try XCTUnwrap(loupe.cropToolLayout())
        for (drawn, want) in zip(atRest.corners, target.corners) {
            XCTAssertEqual(drawn.x, want.x, accuracy: 1e-9, "② at rest: corner x")
            XCTAssertEqual(drawn.y, want.y, accuracy: 1e-9, "② at rest: corner y")
        }
        // …and the animation really ended on the new camera (a 4× shrink from 1:1).
        XCTAssertEqual(loupe.viewState.zoom, 0.25, accuracy: 1e-12)
        let oldZoom = loupe.framing()!.zoom(of: oldState)
        XCTAssertEqual(rect(atRest).width / rect(old).width, 0.25 / oldZoom, accuracy: 0.02,
                       "the frame really did shrink with the picture")
        // The draft was never touched by the animation.
        XCTAssertEqual(loupe.cropTool.draft.crop, Self.crop, "a zoom writes no draft")
    }

    // MARK: - ② the same claim, as arithmetic (no window, no decode, 11 progresses)

    /// The carry is not "close enough": on a projection with **one** source size (no ingested preview
    /// rung in the way) every progress of a 1:1 → 25 % bridge puts the quad, the eight grips and the
    /// grid on `scale(t)·p + offset(t)` to floating-point, and **progress 1 reproduces the target
    /// camera's own layout** — which is why handing the canvas over at the end is not a jump.
    func testElevenProgressesLandOnTheProjectionAndOneReproducesTheTarget() {
        let viewport = ImageSize(width: 640, height: 400)
        let source = ImageSize(width: 9520, height: 6336)
        let framing = LoupeFraming(viewport: viewport, sourceWidth: Double(source.width),
                                   sourceHeight: Double(source.height))
        let from = LoupeViewState(mode: .actual, zoom: 1, centerX: 4760, centerY: 3168)
        let to = LoupeViewState(mode: .actual, zoom: 0.25, centerX: 4760, centerY: 3168)
        let fromMapping = framing.mapping(of: from)
        let toMapping = framing.mapping(of: to)
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: from),
                                     toContent: framing.contentPixels(of: to),
                                     fromMapping: fromMapping, toMapping: toMapping,
                                     canvas: viewport)
        XCTAssertTrue(bridge.isVisible)

        let crop = CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60)
        let old = CropTool.layout(crop: crop, source: source, mapping: fromMapping, pointScale: 2)
        var rows: [(t: Double, rect: NSRect, error: CGFloat)] = []
        for index in 0...10 {
            let t = Double(index) / 10
            let drawn = CropTool.layout(crop: crop, source: source, mapping: fromMapping,
                                        pointScale: 2, carry: CropCarry(bridge.map(atProgress: t)))
            // The reference: the same corners carried by the similarity, computed here.
            func carried(_ p: CGPoint) -> CGPoint {
                let moved = bridge.canvasPoint(atProgress: t, of: (x: Double(p.x) * 2, y: Double(p.y) * 2))
                return CGPoint(x: moved.x / 2, y: moved.y / 2)
            }
            var worst: CGFloat = 0
            for (index, corner) in drawn.corners.enumerated() {
                let want = carried(old.corners[index])
                worst = max(worst, hypot(corner.x - want.x, corner.y - want.y))
            }
            for (index, grip) in drawn.grips.enumerated() {
                let want = carried(old.grips[index].point)
                worst = max(worst, hypot(grip.point.x - want.x, grip.point.y - want.y))
            }
            for (index, segment) in drawn.grid.enumerated() {
                let a = carried(old.grid[index].a), b = carried(old.grid[index].b)
                worst = max(worst, hypot(segment.a.x - a.x, segment.a.y - a.y),
                            hypot(segment.b.x - b.x, segment.b.y - b.y))
            }
            rows.append((t, rect(drawn), worst))
        }
        print("② arithmetic · 1:1 → 25 % · frame, eight grips and grid at 11 progresses")
        for row in rows {
            print(String(format: "        t %.1f · overlay frame %@ · error %.9f pt",
                         row.t, NSStringFromRect(row.rect), row.error))
        }
        for row in rows {
            XCTAssertLessThan(row.error, 1e-6,
                              String(format: "t %.1f: the carried layout is %.9f pt off", row.t, row.error))
        }

        // Progress 1 **is** the target camera: the same layout, value for value.
        let atOne = CropTool.layout(crop: crop, source: source, mapping: fromMapping,
                                    pointScale: 2, carry: CropCarry(bridge.map(atProgress: 1)))
        let target = CropTool.layout(crop: crop, source: source, mapping: toMapping, pointScale: 2)
        var handover: CGFloat = 0
        for (a, b) in zip(atOne.corners, target.corners) {
            handover = max(handover, hypot(a.x - b.x, a.y - b.y))
        }
        print(String(format: "② handover at t=1 · carried %@ · target camera %@ · max Δ %.9f pt",
                     NSStringFromRect(rect(atOne)), NSStringFromRect(rect(target)), handover))
        XCTAssertLessThan(handover, 1e-6,
                          "progress 1 must be the target camera's own layout, or the handover jumps")
    }

    // MARK: - ② the reverse evidence

    /// The same measurement with the overlay refresh **cut away from the animation** — the pre-②
    /// behaviour, "first frame and the end, nothing in between". It must be red, and visibly so.
    func testOnlyTheTwoEndsWouldBeRed() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)
        loupe.followsCropOverlayDuringBridge = false

        let k = loupe.backingScale
        let old = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let armed = loupe.zoomBridgeArmedCount
        loupe.zoom(to: 0.25, aroundView: nil)
        let bridge = try XCTUnwrap(loupe.zoomBridge)
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil })

        let frames = followFrames(loupe, serial: armed + 1)
        XCTAssertGreaterThanOrEqual(frames.count, 5, "the anti-proof needs frames to be about")
        var rows: [(t: Double, drawn: NSRect, want: NSRect, error: CGFloat)] = []
        for frame in frames {
            let layout = try XCTUnwrap(frame.layout)
            let deviation = deviation(drawn: layout, from: old, bridge: bridge,
                                      progress: frame.progress, backingScale: k)
            let wantCorners = old.corners.map { corner -> CGPoint in
                let moved = bridge.canvasPoint(atProgress: frame.progress,
                                               of: (x: Double(corner.x) * k, y: Double(corner.y) * k))
                return CGPoint(x: moved.x / k, y: moved.y / k)
            }
            rows.append((frame.progress, rect(layout),
                         rect(CropToolLayout(corners: wantCorners)), deviation.worst))
        }
        print("② anti-proof (overlay refresh cut from the animation) · \(rows.count) frames")
        for row in rows {
            print(String(format: "        t %.3f · overlay %@ · expected %@ · error %.4f pt",
                         row.t, NSStringFromRect(row.drawn), NSStringFromRect(row.want), row.error))
        }
        // The first frame is still right — the overlay starts where the picture starts…
        XCTAssertLessThanOrEqual(rows.first?.error ?? .infinity, Self.tolerance,
                                 "the anti-proof must not be a constant offset")
        // …and every mid-transition frame is off by much more than a point.
        let mid = rows.filter { $0.t > 0.05 && $0.t < 0.95 }
        XCTAssertFalse(mid.isEmpty, "no mid-transition frame to fail on")
        let worstMid = mid.map(\.error).max() ?? 0
        print(String(format: "② anti-proof worst mid-transition error %.4f pt", worstMid))
        XCTAssertGreaterThan(worstMid, Self.tolerance,
                             "with the overlay refresh cut away the mid frames must be off by more "
                             + "than \(Self.tolerance) pt, got \(worstMid)")
        // At rest it is right again (that is what 「动画结束后才到位」 described).
        let atRest = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let target = try XCTUnwrap(loupe.cropToolLayout())
        XCTAssertEqual(atRest.corners[0].x, target.corners[0].x, accuracy: 1e-9)
    }

    // MARK: - ② two stop changes in a row

    /// A held ⌘=: the second stop change retargets a running bridge. The overlay must continue from
    /// where the eye is (no jump back), never shrink while the picture grows (no 抽动), and still land
    /// exactly on the target.
    func testTwoZoomsInARowDoNotJumpBackOrRing() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)

        let k = loupe.backingScale
        let old = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let firstSerial = loupe.zoomBridgeArmedCount + 1
        loupe.zoom(to: 0.5, aroundView: nil)
        let firstBridge = try XCTUnwrap(loupe.zoomBridge)
        // Let the first transition get somewhere (about a third of its 180 ms), then push again.
        pump(0.06)
        XCTAssertNotNil(loupe.zoomBridge, "the first bridge is still running")
        let secondSerial = loupe.zoomBridgeArmedCount + 1
        loupe.zoom(to: 0.125, aroundView: nil)
        let secondBridge = try XCTUnwrap(loupe.zoomBridge, "the second change must arm a bridge too")
        XCTAssertGreaterThan(abs(secondBridge.startScale - 1), 1e-6,
                             "a retarget starts from the map the eye is looking at, not the identity")
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the retargeted bridge never ended")
        XCTAssertGreaterThanOrEqual(loupe.zoomBridgeRetargets, 1,
                                    "the second change replaced a running bridge")

        let first = followFrames(loupe, serial: firstSerial)
        let second = followFrames(loupe, serial: secondSerial)
        XCTAssertGreaterThanOrEqual(first.count + second.count, 5, "not enough frames to judge a trajectory")

        // The trajectory, in presentation order: the rect the overlay drew and the rect the picture's
        // own similarity put it at, per frame, per bridge.
        var trajectory: [(serial: Int, t: Double, drawn: NSRect, want: NSRect, error: CGFloat)] = []
        for (serial, frames, bridge) in [(firstSerial, first, firstBridge), (secondSerial, second, secondBridge)] {
            for frame in frames {
                guard let layout = frame.layout else { continue }
                let deviation = deviation(drawn: layout, from: old, bridge: bridge,
                                          progress: frame.progress, backingScale: k)
                let wantCorners = old.corners.map { corner -> CGPoint in
                    let moved = bridge.canvasPoint(atProgress: frame.progress,
                                                   of: (x: Double(corner.x) * k, y: Double(corner.y) * k))
                    return CGPoint(x: moved.x / k, y: moved.y / k)
                }
                trajectory.append((serial, frame.progress, rect(layout),
                                   rect(CropToolLayout(corners: wantCorners)), deviation.worst))
            }
        }
        print("② two zooms (1:1 → 50 % → 12.5 %) · \(first.count) + \(second.count) frames, "
              + "\(loupe.zoomBridgeRetargets) retarget(s)")
        for row in trajectory {
            print(String(format: "        bridge %d · t %.3f · overlay %@ · expected %@ · error %.4f pt",
                         row.serial, row.t, NSStringFromRect(row.drawn),
                         NSStringFromRect(row.want), row.error))
        }
        // Every frame of **both** bridges is on its own picture: the retarget did not repair anything
        // after the fact, it followed the same rule throughout.
        for row in trajectory {
            XCTAssertLessThanOrEqual(row.error, Self.tolerance,
                                     String(format: "② bridge %d t %.3f: %.4f pt off",
                                            row.serial, row.t, row.error))
        }

        // (a) **No jump back at the splice.** The two frames are not the same instant (the ticker runs
        // at 120 Hz and the retarget lands between two ticks), so the honest comparison is against the
        // *motion* the bridges themselves are making: the splice's step may not be larger than the
        // biggest single-tick step either bridge took on its own. A retarget that re-started from the
        // old endpoints would break this by an order of magnitude.
        let lastOfFirst = try XCTUnwrap(first.last?.layout.map(rect))
        let firstOfSecond = try XCTUnwrap(second.first?.layout.map(rect))
        let splice = max(abs(lastOfFirst.minX - firstOfSecond.minX),
                         abs(lastOfFirst.minY - firstOfSecond.minY),
                         abs(lastOfFirst.width - firstOfSecond.width),
                         abs(lastOfFirst.height - firstOfSecond.height))
        func biggestStep(_ frames: [LoupeController.CropOverlayFollowFrame]) -> CGFloat {
            let rects = frames.compactMap { $0.layout.map(rect) }
            return zip(rects, rects.dropFirst()).map { a, b in
                max(abs(a.minX - b.minX), abs(a.minY - b.minY),
                    abs(a.width - b.width), abs(a.height - b.height))
            }.max() ?? 0
        }
        let worstStep = max(biggestStep(first), biggestStep(second))
        print(String(format: "② splice: last of bridge 1 %@ → first of bridge 2 %@ · Δ %.4f pt "
                     + "(biggest single-tick step %.4f pt)",
                     NSStringFromRect(lastOfFirst), NSStringFromRect(firstOfSecond), splice, worstStep))
        XCTAssertLessThanOrEqual(firstOfSecond.width, lastOfFirst.width + 0.5,
                                 "② the retarget rewound the frame (\(lastOfFirst.width) → \(firstOfSecond.width) pt)")
        XCTAssertLessThanOrEqual(splice, max(Self.tolerance, worstStep * 1.5),
                                 "② the splice moved the frame \(splice) pt in one step — 回跳/抽动")

        // (b) **No ringing**: the camera is zooming *out*, so the frame never grows, on either bridge or
        // across the splice, and never collapses faster than the picture could (the biggest step is
        // 50 % → 12.5 % = 4×, and one display tick of it is well under half).
        let widths = trajectory.map { $0.drawn.width }
        XCTAssertFalse(widths.isEmpty)
        for (previous, next) in zip(widths, widths.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.5,
                                     "② the frame grew mid-zoom (\(previous) → \(next) pt) — 抽动")
            XCTAssertGreaterThanOrEqual(next, previous * 0.4,
                                        "② the frame collapsed mid-zoom (\(previous) → \(next) pt)")
        }
        print(String(format: "② trajectory widths: %.2f … %.2f pt over %d frames (monotone, no ringing)",
                     widths.first ?? 0, widths.last ?? 0, widths.count))

        // (c) The end is the target, value for value.
        let atRest = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let target = try XCTUnwrap(loupe.cropToolLayout())
        for (drawn, want) in zip(atRest.corners, target.corners) {
            XCTAssertEqual(drawn.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(drawn.y, want.y, accuracy: 1e-9)
        }
        XCTAssertEqual(loupe.viewState.zoom, 0.125, accuracy: 1e-12,
                       "the retarget landed on the new 12.5 % rung, in 裁切 mode")
        // The grips and grid are on the target too (one assignment, so they must be).
        XCTAssertEqual(atRest.grips.map(\.point), target.grips.map(\.point))
        XCTAssertEqual(atRest.grid, target.grid)
    }

    // MARK: - ② a photo switch during the animation

    /// The same gate that ends the pixels ends the overlay: switching photos mid-animation must leave
    /// the frame on the **new** projection, never at a mid-transition rect of the old picture.
    func testSwitchingPhotoMidAnimationLeavesNoStaleFrame() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)
        let url = try rawFixture()

        loupe.zoom(to: 0.25, aroundView: nil)
        XCTAssertNotNil(loupe.zoomBridge, "the bridge must be running to switch under it")
        pump(0.05)
        let framesBeforeSwitch = loupe.cropOverlayFollowFrames.count

        // B is the same file under another photo identity — the half of the key the picture lives in.
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "crop-follow-zoom-B",
                                                        viewport: Self.viewport, state: loupe.viewState)
        XCTAssertNil(loupe.zoomBridge, "a photo switch ends the running bridge at once")

        // The overlay is put back on the current camera's projection in the same turn — not left at the
        // point the transition had reached.
        let atSwitch = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let projected = try XCTUnwrap(loupe.cropToolLayout())
        for (drawn, want) in zip(atSwitch.corners, projected.corners) {
            XCTAssertEqual(drawn.x, want.x, accuracy: 1e-9, "② switch: corner x")
            XCTAssertEqual(drawn.y, want.y, accuracy: 1e-9, "② switch: corner y")
        }
        // …and no bridge frame (no overlay frame either) is recorded after the switch for the old one.
        pump(0.25)
        XCTAssertEqual(loupe.cropOverlayFollowFrames.count, framesBeforeSwitch,
                       "the bridge kept drawing the old picture's overlay after the switch")
        print("② switch mid-animation · overlay at switch \(NSStringFromRect(rect(atSwitch))) · "
              + "projection \(NSStringFromRect(rect(projected))) · follow frames before/after "
              + "\(framesBeforeSwitch)/\(loupe.cropOverlayFollowFrames.count)")
    }
}
