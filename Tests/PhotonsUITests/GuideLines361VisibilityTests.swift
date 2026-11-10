import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **361 — 引导线不显示 / 关掉再打开就丢.**
///
/// The user's two sentences, and the third one the audit added:
///
/// > 引导线没有显示出来，关闭引导线后再打开，之前的引导线也没了
/// > 有可能引导线被画布遮挡了？
/// > 引导线跑到画面最下方、出画布了
///
/// Three independent causes, three independent measurements:
///
///   A. **where** the drawn segments are — against the **crop frame's own corners** (`CropTool.layout`'s
///      `corners`, the quad the user sees and trusts), never against a second derivation of the same
///      walk. 354's §A compared `P · R · view` with `P · R · view` and measured 0.00 px while the
///      lines were drawn at twice their position on a Retina canvas: a comparison that shares the
///      error cannot see it. The frame corner is a different code path (the canvas-spaced branch of
///      `CropTool.layout`), so this one can;
///   B. **whether they are inside the overlay at all** — the overlay's sibling index among the canvas'
///      layers (must be above every picture layer), its frame / `isHidden` / `alphaValue` /
///      `wantsLayer`, the painter's own `appliedGuideLineAlpha`, and every endpoint against
///      `overlay.bounds` (an NSView clips to its bounds, so a point outside is a line the user cannot
///      see even though `guideLines.count == 2`);
///   C. **whether the data survives** — the switch, Esc, the two delete doors, ⌘Z-shaped document
///      changes and a document round trip.
///
/// Every number below is printed. The three reverse gates at the end are the `355`/`354` shape: a gate
/// flag restores the pre-361 behaviour and the same assertion must go red.
@MainActor
final class GuideLines361VisibilityTests: XCTestCase {

    /// 3000 × 2000 on a 900 × 600 pt canvas: fit is 0.28, so 「100 %」 and 「400 %」 are three different
    /// cameras and the letterbox is real. `backingScale` is whatever this Mac's screen says — that is
    /// the whole point of A: the projection is in device pixels and the overlay in points.
    private static let source = (width: 3000, height: 2000)
    private static let canvas = NSSize(width: 900, height: 600)

    /// §3.1's display tolerance, in points.
    private let displayTolerance: Double = 0.01
    /// §3's 「以裁切框四角为基准」 tolerance, in points — the frame and the lines are drawn by two
    /// different walks, so this one is a half pixel, not 1e−9.
    private let frameTolerance: Double = 0.5

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var toolCount = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-361-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    /// One loupe on one photo, 裁切 on and 引导线 armed — the state the user is in when they say
    /// 「引导线没有显示出来」. `insidePixels: false` keeps the draft's crop `.full`, which is what lets
    /// §A use the crop frame's corners as the photograph's own four corners.
    private func makeSession(perspective: (vertical: Double, horizontal: Double)? = nil,
                             straighten: Double = 0,
                             insidePixels: Bool = false) throws -> CatalogSession {
        toolCount += 1
        let directory = workDir.appendingPathComponent("tool-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        if let perspective {
            if perspective.vertical != 0 || perspective.horizontal != 0 || straighten != 0 {
                session.applyEdit {
                    $0.geometry.perspectiveVertical = perspective.vertical
                    $0.geometry.perspectiveHorizontal = perspective.horizontal
                    $0.geometry.rotationDegrees = straighten
                }
                _ = session.commitEdit(label: "几何", coalesce: false)
            }
        } else if straighten != 0 {
            session.applyEdit { $0.geometry.rotationDegrees = straighten }
            _ = session.commitEdit(label: "几何", coalesce: false)
        }
        _ = CropToolController(session: session).setCropStaysInsidePixels(insidePixels)
        return session
    }

    private func makeLoupe(perspective: (vertical: Double, horizontal: Double)? = nil,
                           straighten: Double = 0,
                           insidePixels: Bool = false)
        throws -> (loupe: LoupeController, session: CatalogSession) {
        let session = try makeSession(perspective: perspective, straighten: straighten,
                                      insidePixels: insidePixels)
        return (try seat(session, insidePixels: insidePixels), session)
    }

    /// A **fresh** loupe on an existing session — the 「重启 / 新开一个工具」 case: its controller has
    /// no memory of any line, so everything it draws comes from the document.
    private func seat(_ session: CatalogSession, insidePixels: Bool = false) throws -> LoupeController {
        _ = CropToolController(session: session).setCropStaysInsidePixels(insidePixels)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(origin: NSPoint(x: 220, y: 220),
                                                          size: Self.canvas),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        loupe.canvasView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        loupe.view.layoutSubtreeIfNeeded()
        windows.append(window)
        CropUITestSupport.pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        XCTAssertTrue(loupe.beginCropTool(), "361: 进裁切")
        _ = loupe.cropTool.setCropStaysInsidePixels(insidePixels)
        XCTAssertTrue(loupe.cropTool.setGuideLinesArmed(true), "361: 打开引导线")
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        return loupe
    }

    /// The camera the overlay is (or is about to be) drawn with — the loupe's own `cropMapping()`.
    private func mapping(_ loupe: LoupeController) throws -> LoupeMapping {
        try XCTUnwrap(loupe.guideLineMapping, "没有相机就没有投影")
    }

    private func scale(_ loupe: LoupeController) -> Double {
        let s = loupe.backingScale
        return s > 0 ? s : 1
    }

    private func projection(_ loupe: LoupeController, _ m: LoupeMapping) -> GuideLineProjection {
        loupe.cropTool.guideLineProjection(mapping: m)
    }

    /// A source pixel at the **mouse**: the projection is in device pixels, the event is in points.
    private func press(_ loupe: LoupeController, _ p: CGPoint, _ m: LoupeMapping) -> CGPoint {
        points(projection(loupe, m).screenPoint(p), scale(loupe))
    }

    private func points(_ p: CGPoint, _ scale: Double) -> CGPoint {
        CGPoint(x: p.x / scale, y: p.y / scale)
    }

    /// Two verticals that are the **inverse image** of a known keystone's parallel pair — 337's own
    /// construction, so a fit with an exact answer at `v = +40` is guaranteed to exist in range.
    private func convergingPair() -> [(CGPoint, CGPoint)] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let map = PerspectiveMap(vertical: 40, horizontal: 0)
        let inset = 0.02
        let screen = [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                      (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))]
        return screen.map { seg in
            (unWarp(map, seg.0), unWarp(map, seg.1))
        }
    }

    /// A screen point back in source pixels through `map`'s inverse (P⁻¹ only).
    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(Self.source.width),
                            y: Double(p.y) / Double(Self.source.height))
        return CGPoint(x: q.x * Double(Self.source.width), y: q.y * Double(Self.source.height))
    }

    /// Every number the acceptance quotes, in one line per assertion group (the report is these
    /// numbers; a claim without them is not one).
    private func note(_ text: String) {
        print(text)
    }

    @discardableResult
    private func draw(_ loupe: LoupeController, _ a: CGPoint, _ b: CGPoint) throws -> GuideLineSolution? {
        let m = try mapping(loupe)
        let s = scale(loupe)
        XCTAssertTrue(loupe.cropTool.beginGuideLine(atViewPoint: press(loupe, a, m)), "按下")
        loupe.cropTool.continueGuideLine(atViewPoint: press(loupe, b, m))
        return loupe.cropTool.endGuideLine(mapping: m, pointScale: s)
    }

    /// Two accepted lines, drawn in source pixels. The first says 「不够」, the second solves.
    private func drawPair(_ loupe: LoupeController) throws -> [(CGPoint, CGPoint)] {
        let pair = convergingPair()
        XCTAssertNil(try draw(loupe, pair[0].0, pair[0].1), "一条线解不出来")
        let solution = try draw(loupe, pair[1].0, pair[1].1)
        if solution == nil {
            note("361 !! 第二条被拒: reason=\(String(describing: loupe.cropTool.guideLineFailure))"
                  + " 残差=\(String(describing: loupe.cropTool.guideLineMeasuredPairwise))"
                  + " 已存=\(loupe.cropTool.guideLines.count) 条"
                  + " 提示=\(loupe.cropTool.guideLineStatusText ?? "—")"
                  + " 文档=\(loupe.cropTool.draft.guideLines.count)")
        }
        XCTAssertNotNil(solution, "两条会聚的竖线应当解出透视")
        XCTAssertEqual(loupe.cropTool.guideLines.count, 2)
        return pair
    }

    /// Two lines **already in the document**, read back through the one seeding function.
    ///
    /// The gesture tests the solver (337/348 own that); this task's subject is what happens *after* a
    /// line exists — the switch, Esc, clearing, deleting, re-entering, a document tick. Seeding the
    /// document is the honest way to say 「这两条线是文档里的」: the overlay only ever learns them from
    /// `GeometryGroup.guideLines`, which is the property 361 is about.
    @discardableResult
    private func seedLines(_ loupe: LoupeController, _ session: CatalogSession,
                           count: Int = 2) -> [StoredGuideLine] {
        let pair = Array(convergingPair().prefix(max(1, count)))
        let stored = pair.map {
            StoredGuideLine(ax: Double($0.0.x), ay: Double($0.0.y),
                            bx: Double($0.1.x), by: Double($0.1.y), vertical: true)
        }
        session.applyEdit { $0.geometry.guideLines = stored }
        _ = session.commitEdit(label: "引导线", coalesce: false)
        XCTAssertEqual(session.edit.geometry.guideLines.count, stored.count,
                       "361: 文档里应当有 \(stored.count) 条线")
        _ = loupe.cropTool.reloadGuideLines()
        return stored
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        hypot(Double(p.x - q.x), Double(p.y - q.y))
    }

    // MARK: - A. the drawn segments sit on the crop frame

    /// **The measurement 354's §A could not make**: the picture's own four corners, projected, against
    /// the crop frame that is on the screen — the quad the user trusts.
    ///
    /// With `crop = .full` and a canvas-spaced draft the frame is the **AABB of the warped photograph**
    /// (`photoQuadExtent`), so the like-for-like comparison is that AABB against the projection's own
    /// AABB — four edges, in points. Both scalings are printed: the raw device-pixel walk and the point
    /// walk the overlay needs. A missing `÷ backingScale` makes every edge delta proportional to the
    /// rectangle (≈ half of it), and a document-origin slip shifts all four edges by `|origin|` — the
    /// two failure modes 361 found.
    func testTheDrawnSegmentsSitOnTheCropFrame() throws {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let photoCorners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0),
                            CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
        var worstPoints = 0.0, worstRaw = 0.0
        var report: [String] = []
        for (v, h2, s) in [(0.0, 0.0, 0.0), (40.0, 0.0, 0.0), (40.0, -25.0, 9.0)] {
            let map = PerspectiveMap(vertical: v, horizontal: h2)
            let m = try framing(perspective: map, straighten: s).mapping(of: .fit)
            // **The frame, drawn by the path the user sees** — `CropTool.layout`'s canvas branch, in
            // points at this camera. `crop = .full` in canvas space means its four corners are the
            // AABB of the warped photograph.
            let layout = CropTool.layout(crop: .full, source: Self.size, mapping: m,
                                         pointScale: Self.backing, showsGrid: false,
                                         quadRotationDegrees: 0, cropSpace: .canvas)
            let p = GuideLineProjection(source: Self.size, perspective: map,
                                        straightenDegrees: s, mapping: m)
            let frame = Self.bounding(layout.corners)
            let inPoints = Self.bounding(photoCorners.map { points(p.screenPoint($0), Self.backing) })
            let raw = Self.bounding(photoCorners.map { p.screenPoint($0) })
            let groupPoints = max(abs(inPoints.minX - frame.minX), abs(inPoints.maxX - frame.maxX),
                                  abs(inPoints.minY - frame.minY), abs(inPoints.maxY - frame.maxY))
            let groupRaw = max(abs(raw.minX - frame.minX), abs(raw.maxX - frame.maxX),
                               abs(raw.minY - frame.minY), abs(raw.maxY - frame.maxY))
            report.append(String(format: "P=(%+.0f,%+.0f) s=%+.0f° · 四条边差 点 %.3f / 设备px %.1f px · 框 %@ · 投影AABB %@",
                                v, h2, s, groupPoints, groupRaw,
                                Self.describe(frame), Self.describe(inPoints)))
            worstPoints = max(worstPoints, groupPoints)
            worstRaw = max(worstRaw, groupRaw)
        }
        note("361 §A 投影的照片 AABB == 裁切框: 最坏 点空间 "
              + String(format: "%.3f px · 设备px %.1f px", worstPoints, worstRaw)
              + "\n    " + report.joined(separator: "\n    "))
        XCTAssertLessThanOrEqual(worstPoints, frameTolerance,
                                 "361 §A 引导线的 AABB 不在裁切框上 —— 投影与框不是同一条几何")
    }

    private static let size = ImageSize(width: source.width, height: source.height)
    /// The backing scale every number in this suite is divided by — this Mac's is 2, and that is the
    /// whole reason the hand-off needed a `÷`.
    private static let backing = 2.0

    /// The document-canvas framing of this picture, the way `cropMapping()` builds it (crop `.full`,
    /// document canvas) — a value, no window, so the two walks can be compared without a camera that
    /// depends on a decode having landed.
    private func framing(perspective: PerspectiveMap?, straighten: Double,
                         viewport: ImageSize = ImageSize(width: 1800, height: 1200),
                         zoom: Double = 1) throws -> LoupeFraming {
        LoupeFraming(viewport: viewport,
                     sourceWidth: Double(Self.source.width), sourceHeight: Double(Self.source.height),
                     crop: .full, straightenDegrees: straighten,
                     flipH: false, flipV: false, perspective: perspective,
                     canvasRole: .document)
    }

    private static func bounding(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func describe(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f)-(%.1f,%.1f)", r.minX, r.minY, r.maxX, r.maxY)
    }

    /// `(x,y)-(x,y)` per segment, for the printouts — safe on an empty array.
    private func describeSegments(_ segments: [CropToolSegment]) -> String {
        segments.map {
            String(format: "(%.1f,%.1f)-(%.1f,%.1f)", $0.a.x, $0.a.y, $0.b.x, $0.b.y)
        }.joined(separator: " / ")
    }

    // MARK: - B. the occlusion audit

    /// 「有可能引导线被画布遮挡了？」 — answered with indices and rectangles, not with a reading.
    ///
    /// The overlay must be **above every picture layer** of the canvas and must cover it, and every
    /// drawn endpoint must be **inside its own bounds** (an `NSView` clips; a point outside is a line
    /// nobody sees).
    func testTheOverlayIsAboveEveryPictureLayerAndTheLinesAreInsideItsBounds() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        let overlay = loupe.cropOverlayViewForAudit
        let siblings = loupe.view.subviews
        let overlayIndex = try XCTUnwrap(siblings.firstIndex { $0 === overlay }, "overlay 不在 canvas 里")
        let canvasIndex = try XCTUnwrap(siblings.firstIndex { $0 === loupe.canvasView },
                                        "画面层不在 canvas 里")

        var layers: [String] = []
        for (index, view) in siblings.enumerated() {
            layers.append("[\(index)] \(type(of: view)) hidden=\(view.isHidden) "
                          + "frame=(\(Int(view.frame.minX)),\(Int(view.frame.minY)),"
                          + "\(Int(view.frame.width))×\(Int(view.frame.height)))")
        }
        var canvasLayers: [String] = []
        for (index, layer) in (loupe.canvasView.layer?.sublayers ?? []).enumerated() {
            canvasLayers.append("[canvas.\(index)] \(type(of: layer)) hidden=\(layer.isHidden) "
                                + "frame=(\(Int(layer.frame.minX)),\(Int(layer.frame.minY)),"
                                + "\(Int(layer.frame.width))×\(Int(layer.frame.height)))")
        }
        let segments = loupe.cropOverlayGuideLines
        var outside = 0
        var corners: [String] = []
        for segment in segments {
            for p in [segment.a, segment.b] {
                corners.append(String(format: "(%.1f,%.1f)", p.x, p.y))
                if !overlay.bounds.contains(p) { outside += 1 }
            }
        }
        note("361 §B 层序: canvas[\(canvasIndex)] · overlay[\(overlayIndex)] / 共 \(siblings.count) 层"
              + " · overlay frame=(\(Int(overlay.frame.minX)),\(Int(overlay.frame.minY)),"
              + "\(Int(overlay.frame.width))×\(Int(overlay.frame.height)))"
              + " bounds=\(Int(overlay.bounds.width))×\(Int(overlay.bounds.height))"
              + " hidden=\(overlay.isHidden) alpha=\(overlay.alphaValue) wantsLayer=\(overlay.wantsLayer)"
              + " masksToBounds=\(overlay.layer?.masksToBounds ?? false)"
              + " 画线透明度=\(CropToolOverlayView.appliedGuideLineAlpha)"
              + " · 端点在 bounds 外的个数 \(outside)/\(segments.count * 2) \(corners.joined(separator: " "))")
        note("361 §B 兄弟层: " + layers.joined(separator: " | "))
        note("361 §B 画面子层: " + canvasLayers.joined(separator: " | "))

        XCTAssertGreaterThan(overlayIndex, canvasIndex, "overlay 必须在画面层之上")
        XCTAssertFalse(overlay.isHidden, "裁切模式下 overlay 不该隐藏")
        XCTAssertEqual(overlay.alphaValue, 1, accuracy: 1e-9, "overlay 自己被调透明了")
        XCTAssertNotNil(overlay.layer, "overlay 没有 layer —— 它画不到窗口上")
        XCTAssertEqual(overlay.frame.size.width, loupe.view.bounds.width, accuracy: 1,
                       "overlay 没有盖住画布（宽）")
        XCTAssertEqual(overlay.frame.size.height, loupe.view.bounds.height, accuracy: 1,
                       "overlay 没有盖住画布（高）")
        XCTAssertGreaterThan(CropToolOverlayView.appliedGuideLineAlpha, 0.2,
                             "线的透明度太低，等于看不见")
        XCTAssertEqual(outside, 0, "有端点落在 overlay 的 bounds 之外 —— 被裁掉的那种「看不见」")
        XCTAssertEqual(segments.count, 2)
    }

    // MARK: - ① 画完立刻可见

    /// §3.1 — two gestures → two segments **in the overlay**, each end within 0.01 pt of the
    /// projection and inside the overlay's bounds.
    func testDrawingTwoLinesPutsTwoVisibleSegmentsOnTheOverlay() throws {
        let (loupe, session) = try makeLoupe()
        _ = try drawPair(loupe)
        let m = try XCTUnwrap(loupe.guideLineSyncMapping, "画完之后 overlay 没有用任何相机同步过")
        let p = projection(loupe, m)
        let sc = scale(loupe)
        let segments = loupe.cropOverlayGuideLines
        XCTAssertEqual(segments.count, 2, "361 ① overlay 上应当有两条线段")
        var worst = 0.0
        for (index, line) in loupe.cropTool.guideLines.enumerated() where index < segments.count {
            let expected = (points(p.screenPoint(line.a), sc), points(p.screenPoint(line.b), sc))
            worst = max(worst, distance(segments[index].a, expected.0))
            worst = max(worst, distance(segments[index].b, expected.1))
        }
        note(String(format: "361 ① 画 2 条: overlay %d 段 · 与 screenPoint 最坏 %.3f px · 文档 %d 条",
                     segments.count, worst, session.edit.geometry.guideLines.count)
              + " · 端点 " + describeSegments(segments))
        XCTAssertLessThanOrEqual(worst, displayTolerance, "361 ① 画完的位置不是投影给的")
        XCTAssertTrue(segments.allSatisfy { loupe.cropOverlayViewForAudit.bounds.contains($0.a)
            && loupe.cropOverlayViewForAudit.bounds.contains($0.b) }, "361 ① 线画到 overlay 外面去了")
    }

    // MARK: - ② 关掉再打开不丢

    /// §3.2 — the user's own sentence. Off: still 2 in memory **and** in the document, and the overlay
    /// still holds both (the switch is not a delete). On: 2 again, same coordinates to 0.01 pt.
    func testTheSwitchOffAndOnKeepsTheLinesWhereTheyWere() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        let before = loupe.cropOverlayGuideLines
        XCTAssertEqual(before.count, 2)

        XCTAssertTrue(loupe.cropTool.setGuideLinesArmed(false), "关开关")
        XCTAssertFalse(loupe.cropTool.isGuideLinesArmed)
        XCTAssertEqual(loupe.cropTool.guideLines.count, 2, "361 ② 关开关把线清了")
        XCTAssertEqual(session.edit.geometry.guideLines.count, 2, "361 ② 关开关也不该动文档")
        XCTAssertEqual(loupe.cropOverlayGuideLines.count, 2, "361 ② 关开关后 overlay 也丢了线")

        XCTAssertTrue(loupe.cropTool.setGuideLinesArmed(true), "再打开")
        let after = loupe.cropOverlayGuideLines
        XCTAssertEqual(after.count, 2, "361 ② 再打开线没回来")
        var worst = 0.0
        for (a, b) in zip(before, after) {
            worst = max(worst, distance(a.a, b.a))
            worst = max(worst, distance(a.b, b.b))
        }
        note(String(format: "361 ② 关/开开关: 关 → 内存 %d 条 · 文档 %d 条 · overlay %d 段；开 → overlay %d 段 · 坐标差 %.4f px",
                     loupe.cropTool.guideLines.count, session.edit.geometry.guideLines.count,
                     before.count, after.count, worst))
        XCTAssertLessThanOrEqual(worst, displayTolerance, "361 ② 再打开位置变了")
    }

    // MARK: - ③ Esc 不丢

    /// §3.3 — Esc ends the gesture and leaves the lines (337's rule; 361's implementation).
    func testEscapeEndsTheGestureAndKeepsTheLines() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        XCTAssertTrue(loupe.cancelStraightenDrawIfArmed(), "Esc 应当被引导线吃掉")
        XCTAssertFalse(loupe.cropTool.isGuideLinesArmed, "361 ③ Esc 退出引导线模式")
        XCTAssertEqual(loupe.cropTool.guideLines.count, 2, "361 ③ Esc 把线清了")
        XCTAssertEqual(loupe.cropOverlayGuideLines.count, 2, "361 ③ Esc 之后 overlay 丢了线")
        note("361 ③ Esc: armed=\(loupe.cropTool.isGuideLinesArmed) · 内存 \(loupe.cropTool.guideLines.count) 条 · overlay \(loupe.cropOverlayGuideLines.count) 段")
    }

    // MARK: - ④ 只有清除按钮清文档

    /// §3.4 — 「清除引导线」 empties **both** halves; nothing else does.
    func testOnlyTheClearButtonEmptiesTheDocument() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        XCTAssertTrue(loupe.cropTool.clearGuideLines(), "清除引导线")
        let stored = session.edit.geometry.guideLines
        XCTAssertEqual(loupe.cropTool.guideLines.count, 0, "361 ④ 内存没清")
        XCTAssertEqual(stored.count, 0, "361 ④ 文档没清")
        XCTAssertEqual(loupe.cropOverlayGuideLines.count, 0, "361 ④ overlay 还留着线")
        XCTAssertTrue(loupe.cropTool.isGuideLinesArmed, "361 ④ 清除不该顺手关掉工具")
        note("361 ④ 清除: 内存 \(loupe.cropTool.guideLines.count) · 文档 \(stored.count) 条 · overlay \(loupe.cropOverlayGuideLines.count) 段 · armed=\(loupe.cropTool.isGuideLinesArmed)")
    }

    // MARK: - ⑤ 双击删单条

    /// §3.5 — 2 → 1, and the survivor does not move (0.01 pt on screen, 1e−9 in source).
    func testDoubleClickDeletesOneLineAndLeavesTheOtherWhereItWas() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        let m = try mapping(loupe)
        let p = projection(loupe, m)
        guard loupe.cropTool.guideLines.count >= 2, loupe.cropOverlayGuideLines.count >= 2 else {
            XCTFail("⑤ 需要两条线，前置句已经报红")
            return
        }
        let kept = loupe.cropTool.guideLines[0]
        let keptBefore = loupe.cropOverlayGuideLines[0]
        let gone = loupe.cropTool.guideLines[1]
        // `deleteGuideLine` hit-tests in **device pixels** (the same space `guideLineProjection`
        // speaks); the loupe's own double-click multiplies the event point by `backingScale` before
        // asking, and so does this.
        let a = p.screenPoint(gone.a), b = p.screenPoint(gone.b)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertTrue(loupe.cropTool.deleteGuideLine(atViewPoint: mid, mapping: m), "双击删一条")
        let after = loupe.cropOverlayGuideLines
        XCTAssertEqual(loupe.cropTool.guideLines.count, 1, "361 ⑤ 2 → 1")
        XCTAssertEqual(after.count, 1)
        let moved = max(distance(after[0].a, keptBefore.a), distance(after[0].b, keptBefore.b))
        note(String(format: "361 ⑤ 双击删: 2 → %d 条 · 剩下那条屏幕位移 %.4f px · 源端点 Δ=(%.1e, %.1e)",
                     loupe.cropTool.guideLines.count, moved,
                     Double(loupe.cropTool.guideLines[0].a.x - kept.a.x),
                     Double(loupe.cropTool.guideLines[0].b.y - kept.b.y)))
        XCTAssertLessThanOrEqual(moved, displayTolerance, "361 ⑤ 删一条把另一条也挪了")
        XCTAssertEqual(loupe.cropTool.guideLines[0].a.x, kept.a.x, accuracy: 1e-9)
    }

    // MARK: - ⑥ 重进裁切 / 文档往返

    /// §3.6 — document round trip, then 退出裁切 + 重进: same count, same endpoints, 1e−9 in source
    /// and 0.01 pt on the screen.
    func testReenteringCropAndADocumentRoundTripKeepTheLines() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        let stored = session.edit.geometry.guideLines
        let before = loupe.cropOverlayGuideLines
        let reread = try JSONDecoder().decode(GeometryGroup.self,
                                              from: JSONEncoder().encode(session.edit.geometry))
        XCTAssertEqual(reread.guideLines.count, 2, "361 ⑥ 文档往返丢了线")
        for (index, line) in reread.guideLines.enumerated() {
            XCTAssertEqual(line.ax, stored[index].ax, accuracy: 1e-9)
            XCTAssertEqual(line.ay, stored[index].ay, accuracy: 1e-9)
            XCTAssertEqual(line.bx, stored[index].bx, accuracy: 1e-9)
            XCTAssertEqual(line.by, stored[index].by, accuracy: 1e-9)
        }

        // 「重启 / 重进裁切」: a **fresh** tool on the same document has no memory of any line, so the
        // two it draws back can only have come from `GeometryGroup.guideLines` through the one
        // seeding function.
        let fresh = try seat(session)
        let reopened = try XCTUnwrap(fresh.guideLineSyncMapping, "重进之后没有重新投影")
        let p = projection(fresh, reopened)
        let sc = scale(fresh)
        XCTAssertEqual(fresh.cropOverlayGuideLines.count, 2, "361 ⑥ 重进裁切线没回来")
        var worst = 0.0
        for (index, line) in fresh.cropTool.guideLines.enumerated() {
            XCTAssertEqual(Double(line.a.x), stored[index].ax, accuracy: 1e-9)
            XCTAssertEqual(Double(line.a.y), stored[index].ay, accuracy: 1e-9)
            XCTAssertEqual(Double(line.b.x), stored[index].bx, accuracy: 1e-9)
            XCTAssertEqual(Double(line.b.y), stored[index].by, accuracy: 1e-9)
            let expected = points(p.screenPoint(line.a), sc)
            worst = max(worst, distance(fresh.cropOverlayGuideLines[index].a, expected))
        }

        // …and 退出裁切再进入 on the same loupe lands on the same two segments.
        loupe.toggleCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(session.edit.geometry.guideLines.count, 2, "361 ⑥ 离开裁切不该动文档")
        XCTAssertTrue(loupe.beginCropTool())
        CropUITestSupport.pump(0.05)
        var back = 0.0
        for (a, b) in zip(before, loupe.cropOverlayGuideLines) {
            back = max(back, distance(a.a, b.a))
            back = max(back, distance(a.b, b.b))
        }
        note(String(format: "361 ⑥ 重进裁切: 文档 %d 条 · 新工具读回 %d 条 · overlay %d 段 · 端点往返 1e-9 · 屏幕 %.3f px · 退出再进入差 %.3f px",
                     stored.count, fresh.cropTool.guideLines.count,
                     fresh.cropOverlayGuideLines.count, worst, back))
        XCTAssertLessThanOrEqual(worst, displayTolerance)
        XCTAssertLessThanOrEqual(back, displayTolerance, "361 ⑥ 退出再进入位置变了")
    }

    // MARK: - ⑦ 随变换走

    /// §3.7 — `P = +60`, `s = 9°`, 400 %: the projection against **the crop frame's own walk**
    /// (`CropGeometry.documentPoint` + `LoupeMapping.documentView`, the pair `CropTool.layout` draws
    /// the quad with), 0.01 px; and how far the endpoints actually travel from the untransformed
    /// state, so 「跟着变换走」 is a displacement and not a claim.
    func testTheLinesFollowTheKeystoneTheStraightenAndTheZoom() throws {
        let pair = convergingPair()
        let lines = [GuideLine(a: pair[0].0, b: pair[0].1, viewAngle: 90, axis: .vertical),
                     GuideLine(a: pair[1].0, b: pair[1].1, viewAngle: 90, axis: .vertical)]
        let viewport = ImageSize(width: Int(900 * Self.backing), height: Int(600 * Self.backing))
        var report: [String] = []
        var worst = 0.0
        let rest = try endpoints(lines, perspective: nil, straighten: 0, viewport: viewport, zoom: 1)
        for (name, map, s, zoom) in [("P=+60", PerspectiveMap(vertical: 60, horizontal: 0), 0.0, 1.0),
                                     ("s=9°", nil as PerspectiveMap?, 9.0, 1.0),
                                     ("400%", PerspectiveMap(vertical: 30, horizontal: 0), 4.0, 4.0)] {
            let state = LoupeViewState(mode: .actual, zoom: zoom)
            let m = try framing(perspective: map, straighten: s, viewport: viewport).mapping(of: state)
            let p = GuideLineProjection(source: Self.size, perspective: map,
                                        straightenDegrees: s, mapping: m)
            // The frame's own two functions, for the very same endpoints.
            let geometry = CropGeometry(
                geometry: GeometryGroup(crop: .full, rotationDegrees: s, quarterTurns: 0,
                                        perspectiveVertical: map?.vertical ?? 0,
                                        perspectiveHorizontal: map?.horizontal ?? 0,
                                        cropSpace: .source),
                source: Self.size)
            var groupWorst = 0.0
            for line in lines {
                for end in [line.a, line.b] {
                    let doc = geometry.documentPoint(normalizedX: Double(end.x) / Double(Self.size.width),
                                                     Double(end.y) / Double(Self.size.height))
                    let reference = try XCTUnwrap(m.documentView(doc), "相机必须有 documentView")
                    let ours = p.screenPoint(end)
                    groupWorst = max(groupWorst, hypot(Double(ours.x - reference.x),
                                                       Double(ours.y - reference.y)))
                }
            }
            let here = try endpoints(lines, perspective: map, straighten: s,
                                     viewport: viewport, zoom: zoom)
            var moved = 0.0
            for (a, b) in zip(rest, here) {
                moved = max(moved, distance(a.0, b.0), distance(a.1, b.1))
            }
            report.append(String(format: "%@ → 与框的走法差 %.3f px · 端点位移 %.1f px", name, groupWorst, moved))
            worst = max(worst, groupWorst)
        }
        note("361 ⑦ 随变换走（与裁切框同一条 P·R·view）: "
              + report.joined(separator: " · ") + String(format: " · 最坏 %.3f px", worst))
        XCTAssertLessThanOrEqual(worst, displayTolerance, "361 ⑦ 线没跟着变换走")
    }

    /// Both ends of both lines at one camera, in points.
    private func endpoints(_ lines: [GuideLine], perspective: PerspectiveMap?, straighten: Double,
                           viewport: ImageSize, zoom: Double) throws -> [(CGPoint, CGPoint)] {
        let m = try framing(perspective: perspective, straighten: straighten,
                            viewport: viewport).mapping(of: LoupeViewState(mode: .actual, zoom: zoom))
        let p = GuideLineProjection(source: Self.size, perspective: perspective,
                                    straightenDegrees: straighten, mapping: m)
        return lines.map { (points(p.screenPoint($0.a), Self.backing),
                            points(p.screenPoint($0.b), Self.backing)) }
    }

    // MARK: - ⑨ the three reverse gates

    /// Gate ① — 关开关改回 354 的 `cancelGuideLines()`（清内存）→ ② 红：关掉那一刻两条线就没了，
    /// 而这正是用户报的那半句。门打开时按 ② 自己的判据断言（关后仍为 2），所以 ② 不是空话。
    func testGateOneClearingOnDisarmMakesTheSwitchRed() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        loupe.cropTool.guideLinesSurviveDisarm = false
        defer { loupe.cropTool.guideLinesSurviveDisarm = true }
        _ = loupe.cropTool.setGuideLinesArmed(false)
        let afterDisarm = loupe.cropTool.guideLines.count
        let documentAfterDisarm = session.edit.geometry.guideLines.count
        _ = loupe.cropTool.setGuideLinesArmed(true)
        let afterRearm = loupe.cropOverlayGuideLines.count
        note("361 ⑨ 反向门①（关开关清线）: 关后内存 \(afterDisarm) 条 · 文档 \(documentAfterDisarm) 条 · 再开后 overlay \(afterRearm) 段 —— 验收② 要求关后 2 条")
        XCTAssertEqual(afterDisarm, 0, "门① 没有把线清掉 —— 它不是 354 的形状")
        XCTAssertNotEqual(afterDisarm, 2, "门① 下 ② 竟然还是绿的 —— 那条验收是空的")
    }

    /// Gate ② — 去掉「重新播种」→ ⑥ 必红（一个新工具拿不到文档里的线）。
    func testGateTwoRemovingTheReseedMakesReentryRed() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        XCTAssertEqual(session.edit.geometry.guideLines.count, 2)
        CropToolController.guideLinesReseedFromDocument = false
        defer { CropToolController.guideLinesReseedFromDocument = true }
        let fresh = try seat(session)
        let reloaded = fresh.cropTool.guideLines.count
        note("361 ⑨ 反向门②（去掉重播）: 文档仍有 \(session.edit.geometry.guideLines.count) 条 · 新工具的裁切里 \(reloaded) 条 · overlay \(fresh.cropOverlayGuideLines.count) 段 —— 验收⑥ 要求 2/2")
        XCTAssertEqual(reloaded, 0, "门② 下重进竟然把线播回来了 —— ⑥ 不能证明重播")
        XCTAssertNotEqual(fresh.cropOverlayGuideLines.count, 2)
    }

    /// Gate ③ — the point-scale walk removed (354's device-pixel hand-off) → §B/① 必红: the endpoints
    /// leave the overlay's bounds, which is 「跑到画面最下方、出画布」.
    func testGateThreeTheDevicePixelHandOffLeavesTheOverlayBounds() throws {
        let (loupe, session) = try makeLoupe()
        seedLines(loupe, session)
        let bounds = loupe.cropOverlayViewForAudit.bounds
        let inside = loupe.cropOverlayGuideLines.filter {
            bounds.contains($0.a) && bounds.contains($0.b)
        }.count
        loupe.guideLinesSkipPointScale = true
        defer { loupe.guideLinesSkipPointScale = false }
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)
        let gated = loupe.cropOverlayGuideLines
        let sc = scale(loupe)
        var outside = 0
        var deepest = 0.0
        for point in gated.flatMap({ [$0.a, $0.b] }) {
            guard !bounds.contains(point) else { continue }
            outside += 1
            let dx = max(bounds.minX - point.x, 0, point.x - bounds.maxX)
            let dy = max(bounds.minY - point.y, 0, point.y - bounds.maxY)
            deepest = max(deepest, hypot(Double(dx), Double(dy)))
        }
        note(String(format: "361 ⑨ 反向门③（设备px 直接交给 overlay）: 出厂 %d/2 段在 bounds 内 · 门开 %d/2 段 · %d/4 端点出界 · 出界最深 %.1f px · 屏幕缩放 %.0f× · 画布 %.0f×%.0f pt",
                     inside, gated.count, outside, deepest, sc, bounds.width, bounds.height))
        XCTAssertEqual(inside, 2, "出厂必须两条线都在 bounds 内")
        XCTAssertGreaterThan(outside, 0, "门③ 下端点竟然还在 bounds 内 —— 遮挡那条验收是空的")
    }
}
