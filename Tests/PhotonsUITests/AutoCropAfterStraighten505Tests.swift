import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// **505** — 拉直 / 引导线 之后**默认应用自动裁切**, ↵ 也要裁, and 自动裁切 must describe the picture
/// the renderer actually shows.
///
/// The numbers these assertions are stated on are printed, not assumed: the rect the tool wrote, the
/// hull's vertex count, the black pixels the render keeps, and the history rows one gesture leaves.
/// `print` lands in XCTest's buffered stdout, which a redirected `swift test` run does not keep; the
/// numbers the report quotes go to stderr so they survive (`XCTAssert` messages carry them too).
private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@MainActor
final class AutoCropAfterStraighten505Tests: XCTestCase {

    private static let source = ImageSize(width: 480, height: 320)
    private static let viewport = ImageSize(width: 1200, height: 1200)
    private var workDir: URL!
    private var toolCount = 0
    /// The preference suites `makeTool` opened, deleted when the case ends.
    private var preferenceSuites: [String] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-505-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        for suite in preferenceSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        preferenceSuites = []
    }

    // MARK: - ① §2.2 不变式: 8 组参数, 每条边 32 点, 黑像素 0

    /// The fixtures the ticket asks for: 透视 ±, 拉直 ±, 两向组合, shear, 纯旋转 (and all three at
    /// once). For each one the rect the tool wrote is walked back to photo coordinates along its own
    /// four edges — 32 points a side — and every point must be inside `[0,1]²` within `1e-6`; the
    /// same document is then rendered at the fixture's resolution and must carry **no** black pixel.
    func testEightFixturesKeepTheWholeCropInsideThePhotograph() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        struct Fixture { let name: String; let v: Double; let h: Double; let shear: Double; let angle: Double }
        let fixtures = [
            Fixture(name: "透视 +30 / 拉直 0°", v: 30, h: 0, shear: 0, angle: 0),
            Fixture(name: "透视 −30 / 拉直 0°", v: -30, h: 0, shear: 0, angle: 0),
            Fixture(name: "水平 +25 / 拉直 0°", v: 0, h: 25, shear: 0, angle: 0),
            Fixture(name: "两向 +30 / −20 / 拉直 +8°", v: 30, h: -20, shear: 0, angle: 8),
            Fixture(name: "两向 −25 / +15 / 拉直 −6°", v: -25, h: 15, shear: 0, angle: -6),
            Fixture(name: "shear −0.052 / 拉直 0°", v: 0, h: 0, shear: -0.052, angle: 0),
            Fixture(name: "三者 +15 / −10 / shear +0.03 / 拉直 +3°", v: 15, h: -10, shear: 0.03, angle: 3),
            Fixture(name: "纯拉直 +8°", v: 0, h: 0, shear: 0, angle: 8),
        ]

        for fixture in fixtures {
            let (session, tool) = try makeTool { geometry in
                geometry.perspectiveVertical = fixture.v
                geometry.perspectiveHorizontal = fixture.h
                geometry.perspectiveShear = fixture.shear
                geometry.rotationDegrees = fixture.angle
            }
            let before = session.edit.geometry
            XCTAssertTrue(tool.autoCrop(), "① \(fixture.name): 应求出矩形")
            let geometry = session.edit.geometry
            // 505 — the 「改前」 column: the document as the gesture left it, before 自动裁切 runs. On
            // the axis-parallel fixtures the base build's `autoCrop()` wrote **nothing** (the
            // solver's enumeration has no assignment for an axis-parallel side — measured on the
            // untouched solver in `AutoCrop505ProbeTests`), so this is also what the user saw then.
            let beforeBlack = try blackPixels(before)
            let rect = CropRect(geometry.crop)
            XCTAssertGreaterThan(rect.width * rect.height, 0.05, "① \(fixture.name): 面积")

            // The picture's own map, as the renderer builds it for this document.
            let space = geometry.cropSpace
            let canvas = CropMath.documentCanvas(source: Self.source,
                                                 straightenDegrees: fixture.angle,
                                                 perspective: geometry.perspective)
            let epsilon = 1e-6
            var worst = 0.0
            var worstPoint = (x: 0.0, y: 0.0)
            let sides: [((x: Double, y: Double), (x: Double, y: Double))] = [
                ((rect.left, rect.top), (rect.right, rect.top)),
                ((rect.right, rect.top), (rect.right, rect.bottom)),
                ((rect.right, rect.bottom), (rect.left, rect.bottom)),
                ((rect.left, rect.bottom), (rect.left, rect.top)),
            ]
            for (a, b) in sides {
                for step in 0...31 {
                    let t = Double(step) / 31
                    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    let photo = photoPoint(p, space: space, angle: fixture.angle,
                                           perspective: geometry.perspective, canvas: canvas)
                    let outside = max(-photo.x, photo.x - 1, -photo.y, photo.y - 1, 0)
                    if outside > worst { worst = outside; worstPoint = photo }
                }
            }
            note(String(format: "505 ① %@ · 框 L%.6f T%.6f R%.6f B%.6f · 面积 %.6f · space %@"
                         + " · 128 点最外 %.3e (照片 (%.6f,%.6f)) · ε 1e-6",
                         fixture.name, rect.left, rect.top, rect.right, rect.bottom,
                         rect.width * rect.height,
                         space == .canvas ? "canvas" : "source", worst, worstPoint.x, worstPoint.y))
            XCTAssertLessThanOrEqual(worst, epsilon,
                                     "① \(fixture.name): 框住照片外 —— 会出黑边 (最外 \(worst))")

            let black = try blackPixels(geometry)
            note("505 ① \(fixture.name) · 改前(未裁) 纯黑 \(beforeBlack) → 改后 \(black)")
            XCTAssertEqual(black, 0, "① \(fixture.name): 裁切框内仍有黑像素")
        }
    }

    /// §2.2's other half: the polygon is **sampled along every edge**, and on today's single
    /// homography the hull of those samples is the corner quad — 64 samples in, 4 vertices out.
    /// Printed so the claim is a measurement rather than a comment.
    func testTheSampledPolygonIsTheCornerQuadOnEveryFixture() {
        for (v, h, shear, angle) in [(30.0, 0.0, 0.0, 0.0), (30.0, -20.0, 0.0, 8.0),
                                     (0.0, 0.0, -0.052, 0.0), (0.0, 0.0, 0.0, 8.0)] {
            let perspective = PerspectiveMap(vertical: v, horizontal: h, shear: shear, aspect: 1)
            let canvas = CropMath.documentCanvas(source: Self.source, straightenDegrees: angle,
                                                 perspective: perspective)
            var samples: [NormalizedPoint] = []
            let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
            for i in corners.indices {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                for step in 0...16 {
                    let t = Double(step) / 16
                    let p = PerspectiveMap.apply(canvas.forward,
                                                 x: a.0 + (b.0 - a.0) * t,
                                                 y: a.1 + (b.1 - a.1) * t)
                    samples.append(NormalizedPoint(p.x, p.y))
                }
            }
            let raw = AutoCrop505Hull.hull(samples)
            let hull = AutoCrop505Hull.simplified(raw)
            let worst = AutoCrop505Hull.worstDeviation(samples)
            note(String(format: "505 ① 采样 %d 点 (+%.0f/%+.0f/shear %.3f/%.0f°) · 原始凸包 %d 顶点"
                         + " · 共线化简后 %d · 采样离角点四边形的最大偏差 %.3e",
                         samples.count, v, h, shear, angle, raw.count, hull.count, worst))
            XCTAssertEqual(hull.count, 4, "单应映射下每边都是直线 —— 化简后的凸包必须只有四个顶点")
            XCTAssertLessThanOrEqual(worst, 1e-9, "边采样点必须落在角点四边形的边上")
        }
    }

    // MARK: - ② §2.3.1 引导线: 一条历史行, ⌘Z 同时回退两个字段

    func testAGuideLineFitWritesTheAutoCropInTheSameHistoryRow() throws {
        let (session, tool) = try makeTool { _ in }
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        // 505 — auto crop reads 「不出像素」, a process-wide preference; every fixture here needs it
        // off (the ⑥ case is the one that ticks it).
        _ = tool.setCropStaysInsidePixels(false)
        let pair = convergingPair(vertical: 40)
        let rowsBefore = session.history.snapshots.count
        let fullCrop = session.edit.geometry.crop

        XCTAssertNil(try draw(tool, pair[0].0, pair[0].1), "② 一条线还解不出来")
        let solution = try XCTUnwrap(try draw(tool, pair[1].0, pair[1].1), "② 两条线应当解出来")
        let written = session.edit.geometry
        note(String(format: "② 解 v %+.3f h %+.3f shear %+.4f 摆正 %.3f° · 框 L%.4f T%.4f R%.4f B%.4f"
                     + " · space %@ · 面积 %.4f · 历史 %d → %d · 行「%@」",
                     solution.vertical, solution.horizontal, solution.shear, solution.straighten,
                     written.crop.x, written.crop.y,
                     written.crop.x + written.crop.width, written.crop.y + written.crop.height,
                     written.cropSpace == .canvas ? "canvas" : "source",
                     Double(written.crop.width * written.crop.height),
                     rowsBefore, session.history.snapshots.count,
                     session.history.snapshots.last?.label ?? "—"))

        XCTAssertEqual(session.history.snapshots.count, rowsBefore + 1,
                       "② 一次引导线手势 = 一条历史（裁切不许另起一行）")
        XCTAssertEqual(session.history.snapshots.last?.label, "引导线")
        XCTAssertNotEqual(written.crop, fullCrop, "② 自动裁切必须写进同一条行")
        XCTAssertLessThan(Double(written.crop.width * written.crop.height), 0.999)
        XCTAssertEqual(written.cropSpace, .canvas, "② 有透视 ⇒ 裁切框量在文档画布上")
        XCTAssertEqual(tool.draft.crop.normalizedRect, written.crop,
                       "② 屏幕上的框必须是写进文档的那一个")

        // ⌘Z once: both fields back.
        XCTAssertTrue(session.undo(), "② ⌘Z")
        let undone = session.edit.geometry
        XCTAssertEqual(undone.crop, fullCrop, "② ⌘Z 必须同时回退裁切框")
        XCTAssertEqual(undone.perspectiveVertical, 0, accuracy: 1e-12, "② ⌘Z 必须同时回退透视")
        XCTAssertTrue(undone.guideLines.isEmpty, "② ⌘Z 必须同时回退引导线")
        XCTAssertEqual(session.history.snapshots.count, rowsBefore + 1, "② 回退不删行")

        // ⇧⌘Z once: both back.
        XCTAssertTrue(session.redo(), "② ⇧⌘Z")
        XCTAssertEqual(session.edit.geometry.crop, written.crop)
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, written.perspectiveVertical)
    }

    // MARK: - ③ §2.3.2 两个门: 画线拉直会裁, 普通拉直滑块松手不裁

    func testTheDrawnLineCropsAndTheSliderReleaseDoesNot() throws {
        // ③a the plain 拉直 slider's mouse-up: **no** auto crop — the frame is the user's (190's
        // contract, `45° 重排不改 crop`). One row for the angle, and the crop is untouched.
        let (session, tool) = try makeTool { _ in }
        tool.setStraighten(8)
        let rowsBefore = session.history.snapshots.count
        let cropBefore = session.edit.geometry.crop
        XCTAssertTrue(tool.commitStraighten(), "③a 松手提交")
        let afterSlider = session.edit.geometry
        note(String(format: "③a 滑杆松手 · 角度 %.3f° · 框 L%.4f T%.4f R%.4f B%.4f (未裁) · 历史 %d → %d · 行「%@」",
                     afterSlider.rotationDegrees,
                     afterSlider.crop.x, afterSlider.crop.y,
                     afterSlider.crop.x + afterSlider.crop.width,
                     afterSlider.crop.y + afterSlider.crop.height,
                     rowsBefore, session.history.snapshots.count,
                     session.history.snapshots.last?.label ?? "—"))
        XCTAssertEqual(session.history.snapshots.count, rowsBefore + 1, "③a 一条行（角度）")
        XCTAssertEqual(session.history.snapshots.last?.label, "转动")
        XCTAssertEqual(afterSlider.crop, cropBefore, "③a 普通拉直松手不改裁切框")

        // ③b 画线拉直 — the second door the user named: its release takes the auto crop, one row.
        let (session2, tool2) = try makeTool { _ in }
        XCTAssertTrue(tool2.toggleDrawStraighten())
        let mapping = framing().mapping(of: .fit)
        let a = mapping.viewPoint(sourceX: 480 * 0.15, sourceY: 320 * 0.5)
        let b = mapping.viewPoint(sourceX: 480 * 0.85, sourceY: 320 * 0.36)
        let rows2 = session2.history.snapshots.count
        XCTAssertTrue(tool2.beginDrawStraighten(atViewPoint: CGPoint(x: a.x, y: a.y)))
        tool2.continueDrawStraighten(atViewPoint: CGPoint(x: b.x, y: b.y))
        let draw = try XCTUnwrap(tool2.endDrawStraighten(mapping: mapping), "③b 画线要生效")
        let afterDraw = session2.edit.geometry
        note(String(format: "③b 画线 %.2f° · 框 L%.4f T%.4f R%.4f B%.4f · 面积 %.4f"
                     + " · 历史 %d → %d · 行「%@」",
                     draw.raw,
                     afterDraw.crop.x, afterDraw.crop.y,
                     afterDraw.crop.x + afterDraw.crop.width,
                     afterDraw.crop.y + afterDraw.crop.height,
                     Double(afterDraw.crop.width * afterDraw.crop.height),
                     rows2, session2.history.snapshots.count,
                     session2.history.snapshots.last?.label ?? "—"))
        XCTAssertEqual(session2.history.snapshots.count, rows2 + 1, "③b 一条行")
        XCTAssertLessThan(Double(afterDraw.crop.width * afterDraw.crop.height), 0.999,
                          "③b 画线后必须已经裁过")
        XCTAssertEqual(try blackPixels(afterDraw), 0, "③b 画线后的画面不许有黑像素")
    }

    // MARK: - ④ §2.4 ↵ 与「应用」同一条门

    /// A real `NSEvent` key-down (the shipped path, `UISmokeRunner`'s own construction) against the
    /// footer 应用's action — `completeCropTool()`, the closure `CropApplyFooter` is wired to. Two
    /// editors built identically; every field the ticket names must agree bit for bit.
    func testReturnAndTheApplyButtonAreTheSameDoor() throws {
        let a = try makeEditor(prefix: "return")
        let b = try makeEditor(prefix: "button")
        defer { a.window?.close(); b.window?.close() }

        let rowsA = try fitGuideLines(on: a)
        let rowsB = try fitGuideLines(on: b)

        // ↵ into the canvas' own keyDown.
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                  modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: a.window?.windowNumber ?? 0,
                                                  context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r",
                                                  isARepeat: false, keyCode: 36))
        a.rootView.loupeController.canvasView.keyDown(with: event)
        CropUITestSupport.pump(0.1)

        // The footer button's action.
        b.rootView.loupeController.completeCropTool()
        CropUITestSupport.pump(0.1)

        let ga = a.session.edit.geometry, gb = b.session.edit.geometry
        let labelA = a.session.history.snapshots.last?.label ?? "—"
        let labelB = b.session.history.snapshots.last?.label ?? "—"
        note(String(format: "④ ↵ · 框 L%.6f T%.6f R%.6f B%.6f · 历史 %d · 行「%@」",
                     ga.crop.x, ga.crop.y, ga.crop.x + ga.crop.width, ga.crop.y + ga.crop.height,
                     a.session.history.snapshots.count, labelA))
        note(String(format: "④ 应用 · 框 L%.6f T%.6f R%.6f B%.6f · 历史 %d · 行「%@」",
                     gb.crop.x, gb.crop.y, gb.crop.x + gb.crop.width, gb.crop.y + gb.crop.height,
                     b.session.history.snapshots.count, labelB))
        note("④ 进工具前历史行数 a=\(rowsA) b=\(rowsB)")

        XCTAssertEqual(ga.crop, gb.crop, "④ 两条门的裁切框必须逐位相同")
        XCTAssertEqual(a.session.history.snapshots.count, b.session.history.snapshots.count,
                       "④ 两条门的历史行数必须相同")
        XCTAssertEqual(labelA, labelB, "④ 两条门的行 label 必须相同")
        XCTAssertFalse(a.rootView.loupeController.cropTool.isActive, "④ ↵ 离开裁切")
        XCTAssertFalse(b.rootView.loupeController.cropTool.isActive, "④ 应用离开裁切")
    }

    // MARK: - ⑤ §2.3.3 已水平: 不裁不写

    func testALevelPictureIsLeftByteIdentical() throws {
        let (session, tool) = try makeTool { _ in }
        let bytes = CropUITestSupport.documentBytes(session)
        let rows = session.history.snapshots.count
        let crop = session.edit.geometry.crop

        XCTAssertFalse(tool.autoCrop(), "⑤ 已水平: 自动裁切不动作")
        tool.setStraighten(0)
        XCTAssertFalse(tool.commitStraighten(), "⑤ 已水平: 松手不铸行")
        XCTAssertEqual(session.history.snapshots.count, rows, "⑤ 历史不变")
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytes, "⑤ 文档一个字节都不写")
        XCTAssertEqual(session.edit.geometry.crop, crop)
        note("⑤ 已水平 · autoCrop false · 松手提交 false · 历史 \(rows) · 文档字节未变")
    }

    // MARK: - ⑥ §2.3.4 「不出像素」勾上 ⇒ 跳过

    func testStaysInsidePixelsSkipsTheAutoCrop() throws {
        let (session, tool) = try makeTool(staysInsidePixels: true) { _ in }
        tool.setStraighten(8)
        XCTAssertFalse(tool.autoCrop(), "⑥ 勾上「不出像素」时自动裁切必须让步")
        let before = session.edit.geometry.crop
        XCTAssertTrue(tool.commitStraighten(), "⑥ 松手仍然提交角度")
        let after = session.edit.geometry
        // What 317/307's one-shot inscription produces — the same answer this commit had before 505,
        // i.e. the auto crop did not touch it.
        let inscribed = CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: 8,
                                                       keepsInsideRotatedFrame: true)
        note(String(format: "⑥ 不出像素 · autoCrop false · 松手后 框 L%.4f T%.4f R%.4f B%.4f (面积 %.4f)"
                     + " · 内切答案 L%.4f T%.4f R%.4f B%.4f (面积 %.4f) · 角度 %.1f°",
                     after.crop.x, after.crop.y,
                     after.crop.x + after.crop.width, after.crop.y + after.crop.height,
                     Double(after.crop.width * after.crop.height),
                     inscribed.left, inscribed.top, inscribed.right, inscribed.bottom,
                     Double(inscribed.width * inscribed.height), after.rotationDegrees))
        XCTAssertEqual(after.crop, before,
                       "⑥ 自动裁切没有写进文档 —— 裁切框仍是草稿的事（应用时才提交）")
        XCTAssertEqual(tool.draft.crop.normalizedRect, inscribed.normalizedRect,
                       "⑥ 307/317 的内切仍按原样落在草稿上")
    }

    // MARK: - harness

    /// The controller gets its **own** preferences suite: 「不出像素」 is a process-wide preference
    /// (`AppPreferences.store`) and 505 makes 自动裁切 read it, so a test that ticks it would
    /// otherwise decide the answer for every later test in the same run.
    private func makeTool(staysInsidePixels: Bool? = nil,
                          document: (inout GeometryGroup) -> Void)
        throws -> (CatalogSession, CropToolController) {
        toolCount += 1
        let directory = workDir.appendingPathComponent("tool-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                            width: Self.source.width,
                                                            height: Self.source.height)
        session.applyEdit { document(&$0.geometry) }
        _ = session.commitEdit(label: "505 夹具", coalesce: false)
        let suiteName = "com.nousresearch.photons.tests.505." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        preferenceSuites.append(suiteName)
        let tool = CropToolController(session: session, defaults: defaults)
        if let staysInsidePixels { _ = tool.setCropStaysInsidePixels(staysInsidePixels) }
        XCTAssertTrue(tool.begin(), "505: 进裁切模式")
        return (session, tool)
    }

    private func makeEditor(prefix: String) throws -> EditorWindowController {
        let directory = workDir.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let editor = try CropUITestSupport.makeEditor(in: directory)
        return editor
    }

    /// The same 337 construction, on this file's own 480×320 frame: two verticals that are the
    /// inverse image of `vertical`'s parallel pair, drawn on the controller in view points.
    private func convergingPair(vertical: Double) -> [(CGPoint, CGPoint)] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let map = PerspectiveMap(vertical: vertical, horizontal: 0)
        let inset = 0.02
        let screen = [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                      (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))]
        return screen.map { seg in
            (unWarp(map, seg.0), unWarp(map, seg.1))
        }
    }

    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(Self.source.width),
                            y: Double(p.y) / Double(Self.source.height))
        return CGPoint(x: q.x * Double(Self.source.width), y: q.y * Double(Self.source.height))
    }

    private func framing(perspective: PerspectiveMap? = nil, straighten: Double = 0) -> LoupeFraming {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full, straightenDegrees: straighten,
                     flipH: false, flipV: false, perspective: perspective)
    }

    @discardableResult
    private func draw(_ tool: CropToolController, _ a: CGPoint, _ b: CGPoint)
        throws -> GuideLineSolution? {
        let mapping = framing(perspective: tool.draft.perspective).mapping(of: .fit)
        let va = viewPoint(mapping, a), vb = viewPoint(mapping, b)
        guard tool.beginGuideLine(atViewPoint: va) else { return nil }
        tool.continueGuideLine(atViewPoint: vb)
        return tool.endGuideLine(mapping: mapping)
    }

    private func viewPoint(_ mapping: LoupeMapping, _ p: CGPoint) -> CGPoint {
        let q = mapping.viewPoint(sourceX: Double(p.x), sourceY: Double(p.y))
        return CGPoint(x: q.x, y: q.y)
    }

    // MARK: the real editor's guide-line pair

    private func mapping(_ loupe: LoupeController) throws -> LoupeMapping {
        try XCTUnwrap(loupe.guideLineMapping, "没有相机就没有投影")
    }

    private func scale(_ loupe: LoupeController) -> Double {
        let s = loupe.backingScale
        return s > 0 ? s : 1
    }

    private func press(_ loupe: LoupeController, _ m: LoupeMapping, _ p: CGPoint) -> CGPoint {
        let q = loupe.cropTool.guideLineProjection(mapping: m).screenPoint(p)
        let s = scale(loupe)
        return CGPoint(x: q.x / s, y: q.y / s)
    }

    /// Two converging verticals on a real editor, then the crop tool is left open with the solution
    /// written. Returns the history count before the fit.
    @discardableResult
    private func fitGuideLines(on editor: EditorWindowController) throws -> Int {
        let loupe = editor.rootView.loupeController
        let tool = loupe.cropTool
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session))
        CropUITestSupport.pump(0.05)
        XCTAssertTrue(tool.setGuideLinesArmed(true))
        // 505 — auto crop reads 「不出像素」, a process-wide preference; every fixture here needs it
        // off (the ⑥ case is the one that ticks it).
        _ = tool.setCropStaysInsidePixels(false)
        let source = ImageSize(width: Int(loupe.cropTool.sourceSize.width),
                               height: Int(loupe.cropTool.sourceSize.height))
        let w = Double(source.width), h = Double(source.height)
        let map = PerspectiveMap(vertical: 40, horizontal: 0)
        let inset = 0.02
        let pair = [(CGPoint(x: inset * w, y: 0), CGPoint(x: inset * w, y: h)),
                    (CGPoint(x: w - inset * w, y: 0), CGPoint(x: w - inset * w, y: h))].map { seg in
            (unWarp(map, seg.0, source), unWarp(map, seg.1, source))
        }
        let m = try mapping(loupe)
        let rows = editor.session.history.snapshots.count
        for (index, line) in pair.enumerated() {
            XCTAssertTrue(tool.beginGuideLine(atViewPoint: press(loupe, m, line.0)), "④ 按下")
            tool.continueGuideLine(atViewPoint: press(loupe, m, line.1))
            let solution = tool.endGuideLine(mapping: m, pointScale: scale(loupe))
            if index == 0 { XCTAssertNil(solution, "④ 一条线还解不出来") }
            else { XCTAssertNotNil(solution, "④ 两条线应当解出来") }
        }
        CropUITestSupport.pump(0.05)
        return rows
    }

    private func unWarp(_ map: PerspectiveMap, _ p: CGPoint, _ source: ImageSize) -> CGPoint {
        let q = map.inverse(x: Double(p.x) / Double(source.width),
                            y: Double(p.y) / Double(source.height))
        return CGPoint(x: q.x * Double(source.width), y: q.y * Double(source.height))
    }

    // MARK: the maps

    /// A crop-space point walked back to photo coordinates: `.canvas` through the canvas' own
    /// `sampling`, `.source` by undoing the straighten about the photo's centre and then `P⁻¹`.
    private func photoPoint(_ p: CGPoint, space: CropSpace, angle: Double,
                            perspective: PerspectiveMap?, canvas: PerspectiveCanvas)
        -> (x: Double, y: Double) {
        if space == .canvas {
            return PerspectiveMap.apply(canvas.sampling, x: Double(p.x), y: Double(p.y))
        }
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let turned = ((Double(p.x) - 0.5) * w, (Double(p.y) - 0.5) * h)
        let back = CropGeometry.RotationMatrix(degrees: -angle).apply(x: turned.0, y: turned.1)
        let q = (x: 0.5 + back.x / w, y: 0.5 + back.y / h)
        guard let perspective else { return q }
        return perspective.inverse(x: q.x, y: q.y)
    }


    // MARK: - ⑦ 轴平行边的四边形: 后备解法与独立暴力扫描对照

    /// A quad with an **axis-parallel** side is the one shape `AutoCropSolver`'s enumeration cannot
    /// express (its `left` row names `left` only when the supporting edge is not horizontal), and it
    /// is what every keystone at 0° of straighten produces. These are the fixtures the probe measured
    /// as `nil`; the answer the tool now writes must be inside the picture **and** within 1 % of an
    /// independent brute-force optimum over the same polygon.
    func testAxisParallelQuadsReachTheBruteForceOptimum() throws {
        for (v, h, shear, angle) in [(30.0, 0.0, 0.0, 0.0), (-30.0, 0.0, 0.0, 0.0),
                                     (0.0, 25.0, 0.0, 0.0), (15.0, -10.0, 0.03, 3.0)] {
            let (session, tool) = try makeTool { geometry in
                geometry.perspectiveVertical = v
                geometry.perspectiveHorizontal = h
                geometry.perspectiveShear = shear
                geometry.rotationDegrees = angle
            }
            XCTAssertTrue(tool.autoCrop(), "⑦ \(v)/\(h)/sh \(shear)/\(angle)°: 应求出矩形")
            let rect = CropRect(session.edit.geometry.crop)
            let polygon = polygon(vertical: v, horizontal: h, shear: shear, angle: angle)
            let optimum = bruteForceArea(polygon)
            let area = Double(rect.width * rect.height)
            let corners = [NormalizedPoint(rect.left, rect.top),
                           NormalizedPoint(rect.right, rect.top),
                           NormalizedPoint(rect.right, rect.bottom),
                           NormalizedPoint(rect.left, rect.bottom)]
            let inside = corners.allSatisfy { CropMath.quadContains(polygon, x: $0.x, y: $0.y) }
            note(String(format: "505 ⑦ (+%.0f/%+.0f/sh %.3f/%.0f°) · 框 L%.4f T%.4f R%.4f B%.4f"
                        + " · 面积 %.4f · 暴力最优 %.4f · 比 %.4f · 四角在内 %@",
                        v, h, shear, angle, rect.left, rect.top, rect.right, rect.bottom, area,
                        optimum, area / max(optimum, 1e-12), inside ? "是" : "否"))
            XCTAssertTrue(inside, "⑦ 四角必须都落在照片四边形内")
            // 98 %, not 99 %: the answer is inset by one **output pixel** per side (the render's black
            // fringe — see `autoCropTarget`), which on a 480×320 fixture costs about 1 % of the area
            // and on a 66 Mpx photograph 0.02 %. The optimum is the *un-inset* one, so the ratio
            // cannot reach 1 by construction.
            XCTAssertGreaterThanOrEqual(area, optimum * 0.98,
                                        "⑦ 面积 \(area) 小于暴力最优 \(optimum) 的 98%")
            XCTAssertEqual(try blackPixels(session.edit.geometry), 0, "⑦ 框内不许有黑像素")
        }
    }

    /// The polygon the tool solves in, rebuilt here from the document map — 17 samples a side, hull.
    private func polygon(vertical: Double, horizontal: Double, shear: Double,
                         angle: Double) -> [NormalizedPoint] {
        let perspective = PerspectiveMap(vertical: vertical, horizontal: horizontal,
                                         shear: shear, aspect: 1)
        let canvas = CropMath.documentCanvas(source: Self.source, straightenDegrees: angle,
                                             perspective: perspective)
        var samples: [NormalizedPoint] = []
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for step in 0...16 {
                let t = Double(step) / 16
                let p = PerspectiveMap.apply(canvas.forward, x: a.0 + (b.0 - a.0) * t,
                                             y: a.1 + (b.1 - a.1) * t)
                samples.append(NormalizedPoint(p.x, p.y))
            }
        }
        return AutoCrop505Hull.simplified(AutoCrop505Hull.hull(samples))
    }

    /// Independent optimum: scan left/right edges, measure the tallest strip the polygon holds
    /// between them by sampling the vertical chord. Shares no code with the answer under test.
    private func bruteForceArea(_ polygon: [NormalizedPoint]) -> Double {
        let steps = 300
        var best = 0.0
        for i in 0...steps {
            let l = Double(i) / Double(steps)
            for j in i...steps {
                let r = Double(j) / Double(steps)
                guard r - l > 1e-4 else { continue }
                var top = Double.infinity
                var bottom = -Double.infinity
                for k in 0...20 {
                    let x = l + (r - l) * Double(k) / 20
                    let (lo, hi) = verticalChord(polygon, x: x)
                    guard lo <= hi else { continue }
                    top = min(top, hi)
                    bottom = max(bottom, lo)
                }
                if top - bottom > 0 { best = max(best, (r - l) * (top - bottom)) }
            }
        }
        return best
    }

    private func verticalChord(_ polygon: [NormalizedPoint], x: Double) -> (Double, Double) {
        var values: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-12 {
                if abs(x - a.x) < 1e-9 { values.append(a.y); values.append(b.y) }
                continue
            }
            let t = (x - a.x) / (b.x - a.x)
            if t >= -1e-9, t <= 1 + 1e-9 { values.append(a.y + (b.y - a.y) * t) }
        }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    private func ramp() -> LinearImage {
        let size = Self.source
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = 0.6 * Double(x) / Double(max(size.width - 1, 1))
                    + 0.4 * Double(y) / Double(max(size.height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * size.width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "505")
    }

    private func blackPixels(_ geometry: GeometryGroup) throws -> Int {
        var edit = CropUITestSupport.geometryOnly
        edit.geometry = geometry
        let graph = try RenderGraph(input: RenderInput(image: ramp(), identity: "505-black"))
        let display = try XCTUnwrap(try graph.render(edit, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true)).display)
        var black = 0
        for y in 0..<display.height {
            for x in 0..<display.width {
                let o = (y * display.width + x) * 4
                if display.rgba[o] == 0, display.rgba[o + 1] == 0, display.rgba[o + 2] == 0 {
                    black += 1
                }
            }
        }
        return black
    }
}

/// The hull the tool feeds `AutoCropSolver`, reproduced here so the sampling claim is measured rather
/// than asserted from the implementation (a test that calls the private function cannot tell whether
/// it is the thing under test).
enum AutoCrop505Hull {
    static func hull(_ points: [NormalizedPoint]) -> [NormalizedPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: NormalizedPoint, _ a: NormalizedPoint, _ b: NormalizedPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [NormalizedPoint] = []
        for p in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [NormalizedPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Drop vertices that lie on the segment between their neighbours (within `1e-9`).
    static func simplified(_ input: [NormalizedPoint]) -> [NormalizedPoint] {
        var hull = input
        guard hull.count > 3 else { return hull }
        var index = 0
        while hull.count > 3, index < hull.count {
            let previous = hull[(index + hull.count - 1) % hull.count]
            let next = hull[(index + 1) % hull.count]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = (dx * dx + dy * dy).squareRoot()
            let cross = dx * (hull[index].y - previous.y) - dy * (hull[index].x - previous.x)
            let distance = length > 0 ? abs(cross) / length : 0
            if distance <= 1e-9 { hull.remove(at: index); index = 0 } else { index += 1 }
        }
        return hull
    }

    /// How far the worst sample sits from the four-corner quad of the same map: the corner points in,
    /// each sample's perpendicular distance to the nearest quad edge, maximum out.
    static func worstDeviation(_ points: [NormalizedPoint]) -> Double {
        let quad = hull(points)
        guard quad.count >= 3 else { return .infinity }
        var worst = 0.0
        for p in points {
            var nearest = Double.infinity
            for i in quad.indices {
                let a = quad[i], b = quad[(i + 1) % quad.count]
                let dx = b.x - a.x, dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 1e-12 else { continue }
                let cross = dx * (p.y - a.y) - dy * (p.x - a.x)
                nearest = min(nearest, abs(cross) / length)
            }
            worst = max(worst, nearest)
        }
        return worst
    }
}
