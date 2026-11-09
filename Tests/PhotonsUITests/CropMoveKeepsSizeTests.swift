import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 310 — **拖动裁切框必须「平移不改尺寸」**（307 之后）。
///
/// 用户原话（2026-11-09）：
///
///   > 旋转后再裁剪时，拖动裁剪框到边缘，裁剪框会自动缩小/或者改变宽高比，以免出文档画布。
///   > 我希望行为是：拖动裁剪框裁剪框大小不变
///
/// 三条，逐条钉住：
///
///   1. `.inside` 拖动是**纯平移**：每个 tick 的 `width` / `height` / `w÷h` 与 mouse-down 快照
///      相等（1e-12），不只是最后停在哪儿；
///   2. 到画布边只**停住**：`right == legal.right`、`bottom == legal.bottom`（1e-9），尺寸仍不变；
///   3. 四角度 0° / 9° / 15° / 45°，15° 另跑**满幅** 6000×4000，3:2 锁下再跑一遍。
///
/// **每个 tick 之后都补一次 `clampToView`**，因为应用里 `continueCropDrag` → `refreshCropTool`
/// → `syncCropOverlay` → `clampToView` 就是这么走的：只测 `continueDrag` 会漏掉刷新那一半的
/// reshape（310 的第一版测试就漏了，`.inside` 什么都没修也全绿）。
///
/// `legal` 由 AABB 公式在测试里重推（`legalRect(degrees:)`），不从 `CropGeometry` 读；0° 时它退化
/// 成 `0…1²`，与 224/307 的数字一致。
///
/// 两条反向门：
///   · 把 `reshapedForLock` 重新接回 `.inside` 路径（`reshapesLockOnInsideDrag = true`）→ 用例 1/4 红；
///   · `clampsToRotatedFrame = true` → 用例 2 红（框被缩进照片，所以尺寸被改）。
/// 门的红字原文见 `docs/tasks/310-crop-move-keeps-size.md` §4。
@MainActor
final class CropMoveKeepsSizeTests: XCTestCase {

    private var workDir: URL!
    private static let source = ImageSize(width: 6000, height: 4000)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-310-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private func makeController() throws -> CropToolController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        return controller
    }

    private func mapping(_ state: LoupeViewState, degrees: Double) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: degrees).mapping(of: state)
    }

    /// The exact inverse of `CropToolController.normalized` at the draft's angle.
    private func viewPoint(normalized point: NormalizedPoint, mapping: LoupeMapping,
                           degrees: Double) -> CGPoint {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        let turned = rotation.invert(x: (point.x - 0.5) * w, y: (point.y - 0.5) * h)
        let p = mapping.frameView(frameX: w / 2 + turned.x, frameY: h / 2 + turned.y)
        return CGPoint(x: p.x, y: p.y)
    }

    /// The document canvas — the smallest axis-aligned box holding every pixel of the whole photograph
    /// once it is turned, in the crop rect's own normalized coordinates. Re-derived here from the AABB
    /// formula (`e = |w·cos| + |h·sin|` by `|w·sin| + |h·cos|`), never read from `CropGeometry`.
    private func legalRect(degrees: Double, source: ImageSize = source) -> CropRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
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

    private struct Sizes {
        let width: Double
        let height: Double
        var ratio: Double { width / height }
    }

    private func sizes(_ rect: CropRect) -> Sizes {
        Sizes(width: rect.width, height: rect.height)
    }

    private func label(_ degrees: Double) -> String {
        String(format: "%.0f°", degrees)
    }

    /// One tick **exactly as the app runs it**: the drag, then the refresh's `clampToView`
    /// (`LoupeController.continueCropDrag` → `refreshCropTool` → `syncCropOverlay`).
    private func tick(_ controller: CropToolController, to target: NormalizedPoint,
                      mapping map: LoupeMapping, degrees: Double) {
        controller.continueDrag(atViewPoint: viewPoint(normalized: target, mapping: map,
                                                       degrees: degrees),
                                mapping: map, source: Self.source)
        _ = controller.clampToView(mapping: map, source: Self.source)
    }

    // MARK: - 1 + 3. twenty ticks, four angles, one size

    /// §2.1/§2.3 — 20 ticks of a right-down push, four angles. **Every** tick is compared with the
    /// mouse-down size: `Δwidth`, `Δheight`, `Δ(w÷h)` all ≤ 1e-12 (the worst of them is printed).
    ///
    /// The frame starts inset (`0.15…0.85`) so the upright case has somewhere to travel: a **full**
    /// upright frame is already flush on all four sides and cannot move at all — that is the correct
    /// answer, not a bug, which is why §2.1's "满幅" case is the 15° one below.
    func testTwentyTicksKeepTheSizeAtEveryAngle() throws {
        var report: [String] = []
        var shrinkTicks = 0
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            let controller = try makeController()
            let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
            let start = CropRect(left: 0.15, top: 0.15, right: 0.85, bottom: 0.85)
            controller.draft = CropToolController.Draft(crop: start, straighten: degrees,
                                                        lock: .original)
            _ = controller.clampToView(mapping: map, source: Self.source)

            let snapshot = sizes(controller.draft.crop)
            let grabbed = NormalizedPoint(controller.draft.crop.centerX, controller.draft.crop.centerY)
            XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                      degrees: degrees),
                                               mapping: map, source: Self.source))
            XCTAssertEqual(controller.lastHandle, .inside,
                           "\(label(degrees)): 点框内必须拿到 .inside，不是把手")

            var worst = (dw: 0.0, dh: 0.0, dr: 0.0)
            for index in 1...20 {
                let offset = 0.005 * Double(index)          // 0.1 document widths in 20 steps
                tick(controller, to: NormalizedPoint(grabbed.x + offset, grabbed.y + offset),
                     mapping: map, degrees: degrees)
                let now = sizes(controller.draft.crop)
                let dw = abs(now.width - snapshot.width)
                let dh = abs(now.height - snapshot.height)
                let dr = abs(now.ratio - snapshot.ratio)
                worst = (max(worst.dw, dw), max(worst.dh, dh), max(worst.dr, dr))
                XCTAssertLessThanOrEqual(dw, 1e-12,
                    String(format: "310 §1 %@ tick %d: Δwidth %.3e", label(degrees), index, dw))
                XCTAssertLessThanOrEqual(dh, 1e-12,
                    String(format: "310 §1 %@ tick %d: Δheight %.3e", label(degrees), index, dh))
                XCTAssertLessThanOrEqual(dr, 1e-12,
                    String(format: "310 §1 %@ tick %d: Δ(w/h) %.3e", label(degrees), index, dr))
            }
            controller.endDrag()
            shrinkTicks += controller.canvasShrinkTicks
            report.append(String(format: "%@ Δw %.1e Δh %.1e Δ(w/h) %.1e",
                                 label(degrees), worst.dw, worst.dh, worst.dr))
        }
        print("310 §1 · 20 ticks · " + report.joined(separator: " · ")
              + " · clampToCanvas 缩分支 \(shrinkTicks) 次")
        XCTAssertEqual(shrinkTicks, 0, "310: 本轮正常拖动里 clampToCanvas 的「缩」分支次数必须为 0")
    }

    /// §2.1/§2.3 — the specification's own case: **15°, full frame, 6000×4000**. Twenty ticks of a
    /// right-down push, each tick still the mouse-down size. (At 15° the canvas is wider than the
    /// photograph — `-0.0692…1.0692 × -0.0824…1.0824` — so a full frame does have room to move.)
    func testFifteenDegreesFullFrameKeepsTheSize() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        controller.draft = CropToolController.Draft(crop: .full, straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)
        XCTAssertEqual(controller.draft.crop, .full, "15° 满幅框在 clampToView 之后仍是满幅")

        let snapshot = sizes(controller.draft.crop)
        let grabbed = NormalizedPoint(0.5, 0.5)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        XCTAssertEqual(controller.lastHandle, .inside)

        var worst = (dw: 0.0, dh: 0.0, dr: 0.0)
        for index in 1...20 {
            let offset = 0.002 * Double(index)              // 0.04 — inside the 0.069 slack
            tick(controller, to: NormalizedPoint(grabbed.x + offset, grabbed.y + offset),
                 mapping: map, degrees: degrees)
            let now = sizes(controller.draft.crop)
            worst = (max(worst.dw, abs(now.width - snapshot.width)),
                     max(worst.dh, abs(now.height - snapshot.height)),
                     max(worst.dr, abs(now.ratio - snapshot.ratio)))
        }
        controller.endDrag()
        let after = controller.draft.crop
        print(String(format: "310 §1 · 15° 满幅 6000×4000 · 20 ticks · "
                     + "Δwidth %.3e · Δheight %.3e · Δ(w/h) %.3e · 末 w %.12f h %.12f",
                     worst.dw, worst.dh, worst.dr, after.width, after.height))
        XCTAssertLessThanOrEqual(worst.dw, 1e-12)
        XCTAssertLessThanOrEqual(worst.dh, 1e-12)
        XCTAssertLessThanOrEqual(worst.dr, 1e-12)
    }

    // MARK: - 2 + 3. the edge stops it, and only the edge

    /// §2.2/§2.3 — pushed far past the canvas on all four angles: the frame **stops flush** on the
    /// canvas' right/bottom edges (`≤1e-9`) and its size is still the mouse-down one (`≤1e-9`, the
    /// accumulated round-trip through the pointer), and the canvas clamp never resized it.
    func testBeyondTheCanvasEdgeStopsFlushAndKeepsTheSize() throws {
        var report: [String] = []
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            let controller = try makeController()
            let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
            let start = CropRect(left: 0.15, top: 0.15, right: 0.85, bottom: 0.85)
            controller.draft = CropToolController.Draft(crop: start, straighten: degrees,
                                                        lock: .original)
            _ = controller.clampToView(mapping: map, source: Self.source)

            let snapshot = sizes(controller.draft.crop)
            let grabbed = NormalizedPoint(controller.draft.crop.centerX, controller.draft.crop.centerY)
            XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                      degrees: degrees),
                                               mapping: map, source: Self.source))
            let far = NormalizedPoint(grabbed.x + 3, grabbed.y + 3)
            for _ in 0..<8 {
                tick(controller, to: far, mapping: map, degrees: degrees)
            }
            controller.endDrag()

            let after = controller.draft.crop
            let legal = legalRect(degrees: degrees)
            let dw = abs(after.width - snapshot.width)
            let dh = abs(after.height - snapshot.height)
            print(String(format: "310 §2 · %@ · right−legal.right %.3e · bottom−legal.bottom %.3e "
                         + "· Δw %.3e Δh %.3e · 缩分支 %d",
                         label(degrees), after.right - legal.right, after.bottom - legal.bottom,
                         dw, dh, controller.canvasShrinkTicks))
            XCTAssertEqual(after.right, legal.right, accuracy: 1e-9,
                           "\(label(degrees)): 右边缘必须停在画布右边界")
            XCTAssertEqual(after.bottom, legal.bottom, accuracy: 1e-9,
                           "\(label(degrees)): 下边缘必须停在画布下边界")
            XCTAssertLessThanOrEqual(dw, 1e-9, "\(label(degrees)): 贴边不许改宽度")
            XCTAssertLessThanOrEqual(dh, 1e-9, "\(label(degrees)): 贴边不许改高度")
            XCTAssertEqual(controller.canvasShrinkTicks, 0,
                           "\(label(degrees)): clampToCanvas 的「缩」分支本轮必须为 0")
            report.append(String(format: "%@ 右 %.1e 下 %.1e Δw %.1e Δh %.1e",
                                 label(degrees), after.right - legal.right,
                                 after.bottom - legal.bottom, dw, dh))
        }
        XCTAssertEqual(report.count, 4)
    }

    // MARK: - 4. the 3:2 lock

    /// §2.4 — 3:2 locked, 15°, moved by `.inside` in twenty ticks: still the mouse-down size.
    ///
    /// The start rect is one a document can actually hold: a 3:2 lock whose stored crop is
    /// `0.90 × 0.80` of the frame — a true 3:2 would be `0.90 × 0.60` — so the rect is **off the
    /// lock** by construction (legacy XMP, a ratio typed while another crop was live, a hand-edited
    /// document). That is the state in which `reshapedForLock` re-shapes the frame on a *move*, i.e.
    /// the reported 「拖动裁剪框会自动缩小 / 改变宽高比」. A move keeps the size the user has; the
    /// lock comes back the moment a grip or a new frame asks for a size.
    func testThreeTwoLockKeepsTheSize() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        let offLock = CropRect(left: 0.05, top: 0.10, right: 0.95, bottom: 0.90)
        controller.draft = CropToolController.Draft(crop: offLock, straighten: degrees,
                                                    lock: .threeTwo)
        // The ⑦ clamp may shape it on entry; the drag is the thing under test, so the mouse-down
        // state is the off-lock rect the document held.
        _ = controller.clampToView(mapping: map, source: Self.source)
        controller.draft.crop = offLock

        let snapshot = sizes(controller.draft.crop)
        let grabbed = NormalizedPoint(offLock.centerX, offLock.centerY)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        XCTAssertEqual(controller.lastHandle, .inside)

        var worst = (dw: 0.0, dh: 0.0, dr: 0.0)
        for index in 1...20 {
            let offset = 0.002 * Double(index)
            tick(controller, to: NormalizedPoint(grabbed.x + offset, grabbed.y + offset),
                 mapping: map, degrees: degrees)
            let now = sizes(controller.draft.crop)
            worst = (max(worst.dw, abs(now.width - snapshot.width)),
                     max(worst.dh, abs(now.height - snapshot.height)),
                     max(worst.dr, abs(now.ratio - snapshot.ratio)))
        }
        controller.endDrag()
        // The mouse-up refresh must not re-shape it either: the frame stays where the hand left it
        // until a grip asks for a size.
        _ = controller.clampToView(mapping: map, source: Self.source)
        let after = controller.draft.crop
        print(String(format: "310 §4 · 3:2 锁 15° · 20 ticks · Δw %.3e Δh %.3e Δ(w/h) %.3e "
                     + "· 快照 %.6f×%.6f → 末 %.6f×%.6f",
                     worst.dw, worst.dh, worst.dr,
                     snapshot.width, snapshot.height, after.width, after.height))
        XCTAssertLessThanOrEqual(worst.dw, 1e-12)
        XCTAssertLessThanOrEqual(worst.dh, 1e-12)
        XCTAssertLessThanOrEqual(worst.dr, 1e-12)
        XCTAssertEqual(after.width, snapshot.width, accuracy: 1e-12,
                       "310 §4: 松手之后的刷新也不许改尺寸")
        XCTAssertEqual(after.height, snapshot.height, accuracy: 1e-12)
    }

    /// §2.4 的另一半 — the lock is **still a lock**: after the move, a corner drag re-imposes it.
    /// (Same off-lock start; only the gesture changes.)
    func testTheLockStillAppliesToAHandleDrag() throws {
        let degrees = 0.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        let offLock = CropRect(left: 0.05, top: 0.10, right: 0.95, bottom: 0.90)
        controller.draft = CropToolController.Draft(crop: offLock, straighten: degrees,
                                                    lock: .threeTwo)
        controller.draft.crop = offLock

        let corner = NormalizedPoint(offLock.right, offLock.bottom)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: corner, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        XCTAssertEqual(controller.lastHandle, .bottomRight)
        tick(controller, to: NormalizedPoint(offLock.right - 0.20, offLock.bottom - 0.20),
             mapping: map, degrees: degrees)
        controller.endDrag()
        let after = controller.draft.crop
        let pixelRatio = after.width * Double(Self.source.width)
            / (after.height * Double(Self.source.height))
        print(String(format: "310 §4 对照 · 把手拖动仍受锁约束 · 末 %.6f×%.6f · 像素比 %.6f",
                     after.width, after.height, pixelRatio))
        XCTAssertEqual(pixelRatio, 1.5, accuracy: 1e-6,
                       "310 §4: 锁只在改尺寸的手柄上生效 —— 它不能因此消失")
    }

    // MARK: - 5. the two reverse gates

    /// Reverse gate ① — the size assertion is load-bearing: with the lock's reshape re-attached to
    /// the `.inside` path (`reshapesLockOnInsideDrag = true`), the very same drag changes the size.
    /// This test is the switch's story; the red run of `testThreeTwoLockKeepsTheSize` is quoted in
    /// the task doc.
    func testReverseGateTheLockReshapeOnInsideDragChangesTheSize() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        let offLock = CropRect(left: 0.05, top: 0.10, right: 0.95, bottom: 0.90)
        controller.reshapesLockOnInsideDrag = true
        controller.draft = CropToolController.Draft(crop: offLock, straighten: degrees,
                                                    lock: .threeTwo)
        controller.draft.crop = offLock
        let snapshot = sizes(controller.draft.crop)

        let grabbed = NormalizedPoint(offLock.centerX, offLock.centerY)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        for index in 1...20 {
            let offset = 0.002 * Double(index)
            tick(controller, to: NormalizedPoint(grabbed.x + offset, grabbed.y + offset),
                 mapping: map, degrees: degrees)
        }
        controller.endDrag()
        let after = sizes(controller.draft.crop)
        print(String(format: "310 反向门① · 锁 reshape 接回 .inside · Δw %.3e Δh %.3e "
                     + "(快照 %.6f×%.6f → %.6f×%.6f)",
                     abs(after.width - snapshot.width), abs(after.height - snapshot.height),
                     snapshot.width, snapshot.height, after.width, after.height))
        XCTAssertGreaterThan(max(abs(after.width - snapshot.width), abs(after.height - snapshot.height)),
                             1e-12,
                             "反向门①: 接回 reshape 之后尺寸必须被改 —— 否则用例 1/4 的断言不承重")
    }

    /// Reverse gate ② — `clampsToRotatedFrame = true` (the pre-307 standing containment) shrinks the
    /// frame into the turned photograph instead of stopping it at the canvas, so **the size** moves:
    /// that is what makes "flush on the canvas edge + same size" a real assertion, not a tautology.
    func testReverseGateRotatedFrameContainmentShrinksTheFrame() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        controller.clampsToRotatedFrame = true
        controller.draft = CropToolController.Draft(crop: .full, straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)

        let snapshot = sizes(controller.draft.crop)
        let grabbed = NormalizedPoint(0.5, 0.5)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grabbed, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        let far = NormalizedPoint(grabbed.x + 3, grabbed.y + 3)
        for _ in 0..<8 {
            tick(controller, to: far, mapping: map, degrees: degrees)
        }
        controller.endDrag()

        let after = controller.draft.crop
        let dw = abs(after.width - snapshot.width), dh = abs(after.height - snapshot.height)
        print(String(format: "310 反向门② · clampsToRotatedFrame=true · Δw %.3e Δh %.3e "
                     + "· 快照 %.6f×%.6f → %.6f×%.6f",
                     dw, dh, snapshot.width, snapshot.height, after.width, after.height))
        XCTAssertGreaterThan(max(dw, dh), 1e-6,
                             "反向门②: 内切规则下框的尺寸必然被改 —— 用例 2 的「尺寸不变」才承重")
    }
}
