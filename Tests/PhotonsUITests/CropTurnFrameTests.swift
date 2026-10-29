import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 088 — 拖动 转动 时「图不转、框转」.
///
/// Four claims, each measured on the shipped controller with a real window and real pixels:
///
///   1. **the picture does not move.** Every slider tick is a draft write; `editRenderCount` and the
///      presented frame's SHA stay bit-identical from 0° to +5° and back.
///   2. **the frame does turn.** The overlay's four corners equal
///      `DocFraming.map(R(−5°)·corners(rect))` to ≤ 0.05 pt, and the same quad is what the old,
///      axis-aligned committed state shows once the picture is turned by 5°.
///   3. **the release is the only write.** One release = one document angle, one 「转动」 row and
///      exactly one re-render; dragging on to 7° afterwards renders nothing.
///   4. **Esc still restores** the geometry from before 变换 was entered (087's contract).
@MainActor
final class CropTurnFrameTests: XCTestCase {

    /// The canvas the frame source renders into (device pixels) — same numbers as the zoom-follow
    /// suite, so a bridge and a fit are both real.
    private static let viewport = ImageSize(width: 640, height: 400)

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-turn-frame-\(UUID().uuidString)", isDirectory: true)
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
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
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

    /// A loupe with both halves of the shipped path: a session (an anchor, a frame size) and a frame
    /// source (real pixels, no catalog import). `hashesFrames` is on because claim 1 is about bytes.
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let url = try rawFixture()
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.hashesFrames = true
        loupe.reducesMotion = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)

        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            pump(0.01)
        }
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "turn-frame",
                                                        viewport: Self.viewport, state: .fit)
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        pump(0.1)
        return (loupe, session, window)
    }

    /// Enter 裁切 and wait for the one frame the entry asks for, so the baseline is a settled picture.
    private func openCrop(_ loupe: LoupeController, _ session: CatalogSession) throws {
        let before = loupe.editRenderCount
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        XCTAssertTrue(waitFor { loupe.editRenderCount > before }, "the entry frame never landed")
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "the entry zoom never finished")
        pump(0.15)
    }

    private func corners(_ rect: CropRect, source: ImageSize) -> [(x: Double, y: Double)] {
        let w = Double(source.width), h = Double(source.height)
        return [(rect.left * w, rect.top * h), (rect.right * w, rect.top * h),
                (rect.right * w, rect.bottom * h), (rect.left * w, rect.bottom * h)]
    }

    /// `R(−θ)` about the image centre, in y-down pixels — the geometry 088 specifies, written here
    /// independently of the production code so the assertion is not circular.
    private func turned(_ points: [(x: Double, y: Double)], by degrees: Double,
                        source: ImageSize) -> [(x: Double, y: Double)] {
        let theta = degrees * .pi / 180
        let c = cos(theta), s = sin(theta)
        let cx = Double(source.width) / 2, cy = Double(source.height) / 2
        return points.map { p in
            let dx = p.x - cx, dy = p.y - cy
            return (cx + dx * c + dy * s, cy - dx * s + dy * c)
        }
    }

    // MARK: - 1. 拖动中图不转（一个像素都不重渲）

    func testDraggingTheAngleRendersNothing() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)
        let tool = loupe.cropTool

        let baselineCount = loupe.editRenderCount
        let baselineHash = try XCTUnwrap(loupe.lastFrame?.displayHash, "no frame hash to compare")
        XCTAssertEqual(tool.draft.straighten, session.edit.geometry.straightenDegrees,
                       accuracy: 1e-9, "the draft starts at the document's angle")

        var rows: [(Double, Int, String?)] = []
        for value in [1.0, 2.5, 4.0, 5.0, 0.0] {
            tool.setStraighten(value)
            pump(0.12)
            rows.append((value, loupe.editRenderCount, loupe.lastFrame?.displayHash))
        }

        for row in rows {
            XCTAssertEqual(row.1, baselineCount,
                           "088 §1: \(row.0)° re-rendered the picture (\(row.1) vs \(baselineCount))")
            XCTAssertEqual(row.2, baselineHash,
                           "088 §1: \(row.0)° changed the presented pixels")
        }
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 0, accuracy: 1e-9,
                       "088 §1: no tick may touch the document")
        print("088 §1 · \(rows.count) ticks · edit frames \(baselineCount) → \(loupe.editRenderCount)"
              + " · hash \(baselineHash.prefix(12)) unchanged")
    }

    // MARK: - 2. 框转（四角 = DocFraming ∘ R(−Δ)）

    func testTheFrameQuadTurnsWithTheDraftAngle() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)
        let tool = loupe.cropTool
        let source = loupe.cropSourceSize
        let framing = try XCTUnwrap(loupe.framing(), "no document framing")
        let mapping = framing.mapping(of: loupe.viewState)

        tool.setStraighten(5.0)
        pump(0.02)
        let drawn = try XCTUnwrap(loupe.cropOverlayLayoutForTesting, "the overlay is not drawing")
        XCTAssertEqual(drawn.corners.count, 4)

        let rect = tool.effectiveCrop(source: source)
        // `frameView` is viewport **pixels**; the overlay is laid out in view **points**.
        let scale = loupe.backingScale
        let expected = turned(corners(rect, source: source), by: 5.0, source: source)
            .map { p in
                let q = mapping.frameView(frameX: p.x, frameY: p.y)
                return (x: q.x / scale, y: q.y / scale)
            }
        var worst = 0.0
        for (got, want) in zip(drawn.corners, expected) {
            worst = max(worst, hypot(Double(got.x - want.x), Double(got.y - want.y)))
        }
        print(String(format: "088 §2 · overlay↔DocFraming∘R(−5°) worst %.6f pt", worst))
        XCTAssertLessThanOrEqual(worst, 0.05,
                                 "088 §2: the quad is \(worst) pt off the specified mapping")

        // …and it really is a turned quad, not the axis-aligned one: the top edge is not horizontal.
        let topDy = Double(drawn.corners[1].y - drawn.corners[0].y)
        let topDx = Double(drawn.corners[1].x - drawn.corners[0].x)
        let screenAngle = atan2(topDy, topDx) * 180 / .pi
        XCTAssertEqual(screenAngle, -5.0, accuracy: 1e-6,
                       "088 §2: the frame turns the opposite way to the picture it will become")

        // 132: on screen the committed state is a *different camera* — the canvas grows to the
        // rotated bounding box and 适应 re-fits it (§9), so comparing screen points across the two
        // projections would be comparing zoom levels. The invariant is in **picture space**: the
        // quad the draft draws, mapped back through the un-turned projection, is the same rotated
        // rectangle the committed document names.
        let turnedCorners = turned(corners(rect, source: source), by: 5.0, source: source)
        var equivalence = 0.0
        for (corner, want) in zip(drawn.corners, turnedCorners) {
            let got = try XCTUnwrap(loupe.sourcePoint(forViewPoint: corner),
                                    "the live projection cannot map the drawn corner")
            equivalence = max(equivalence, hypot(got.x - want.x, got.y - want.y))
        }
        print(String(format: "088 §2 · draft quad ↔ rotated source corners %.4f px", equivalence))
        XCTAssertLessThanOrEqual(equivalence, 0.5,
                                 "the draft quad and the committed state must describe the same frame")

        // …and the committed camera really does frame the rotated bounding box, not the un-turned
        // crop (132's whole point).
        let committed = LoupeFraming(viewport: framing.viewport,
                                     sourceWidth: Double(source.width),
                                     sourceHeight: Double(source.height),
                                     crop: .full,
                                     straightenDegrees: 5.0,
                                     flipH: framing.flipH,
                                     flipV: framing.flipV)
        let committedWindow = committed.windowSize(of: .fit)
        XCTAssertEqual(committedWindow.width, committed.rotatedCropExtent.width, accuracy: 1e-9)
        XCTAssertGreaterThan(committedWindow.width, committed.cropWidthPixels,
                             "5°: the committed canvas must be the rotated bounding box")
    }

    // MARK: - 3. 松手只写一次、只渲一帧

    func testReleaseWritesOnceAndRendersExactlyOneFrame() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        try openCrop(loupe, session)
        let tool = loupe.cropTool
        let historyBefore = session.history.snapshots.count
        let renderBefore = loupe.editRenderCount

        tool.setStraighten(5.0)
        pump(0.1)
        XCTAssertEqual(loupe.editRenderCount, renderBefore,
                       "088 §3: the drag itself must render nothing")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)

        XCTAssertTrue(tool.commitStraighten(), "松手必须写出一条历史")
        XCTAssertTrue(waitFor(5) { loupe.editRenderCount > renderBefore },
                      "松手后没有重渲")
        pump(0.2)

        XCTAssertEqual(session.edit.geometry.rotationDegrees, 5.0, accuracy: 1e-9)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "松手 = 一条历史")
        XCTAssertEqual(session.history.snapshots.last?.label, "转动")
        XCTAssertEqual(loupe.editRenderCount, renderBefore + 1,
                       "088 §3: 松手正好一帧（不是两帧）")

        // A second drag that is not released writes and renders nothing.
        tool.setStraighten(7.0)
        pump(0.2)
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 5.0, accuracy: 1e-9,
                       "088 §3: 未松手的 7° 不许进文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1)
        XCTAssertEqual(loupe.editRenderCount, renderBefore + 1,
                       "088 §3: 未松手的拖动不许重渲")
        print("088 §3 · history +\(session.history.snapshots.count - historyBefore)"
              + " · edit frames +\(loupe.editRenderCount - renderBefore)")
    }

    // MARK: - 4. Esc 仍回到进入前（087 不破坏）

    func testEscapeStillRestoresTheEntryGeometryAfterARelease() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }
        let entry = session.edit.geometry
        let historyBefore = session.history.snapshots.count
        XCTAssertTrue(loupe.beginCropTool(), "裁切 mode did not open")
        pump(0.1)

        loupe.cropTool.setStraighten(5.0)
        XCTAssertTrue(loupe.cropTool.commitStraighten())
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 5.0, accuracy: 1e-9)
        loupe.cancelCropTool()
        pump(0.2)

        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertEqual(session.edit.geometry.rotationDegrees, entry.rotationDegrees, accuracy: 1e-9,
                       "088 §4: Esc 必须回到进入前的角度")
        XCTAssertEqual(session.edit.geometry, entry, "088 §4: and the rest of the geometry too")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2,
                       "one 转动 row + one 变换 · 取消 row")
        XCTAssertEqual(session.history.snapshots.last?.label, "变换 · 取消")
        print("088 §4 · angle \(session.edit.geometry.rotationDegrees)"
              + " · history +\(session.history.snapshots.count - historyBefore)")
    }
}
