import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 317 — 裁切卡的 **「不出像素」** 勾选框：勾上以后，框只能在**旋转后的照片像素**里移动。
///
/// 用户口径：
///
///   > 裁剪功能增加一个复选框：不出像素。勾选后裁剪框的移动范围不是文档画布，而是照片像素
///
/// 未勾选就是 307 的现状（框可以在文档画布 = 旋转后照片的 AABB 里移动，可以盖住 `000000` 黑角）；
/// 勾选后框的四角必须落在**旋转后的照片**里，移动被四边停住且**尺寸不变**（310）。
///
/// 六条验收（规格 §3），逐条给数字：
///
///   1. 未勾选 = 307：15° 满幅推到画布右下角，框仍可覆盖 `000000`（角点在照片外计数 > 0）；
///   2. 勾选后不能出像素：15°，20 tick 任意方向，每步 4 角都在旋转矩形内（有符号距离
///      ≥ −1e−9）且宽高与按下时快照差 ≤ 1e−12；
///   3. 上限可达：沿最远方向推到极限时至少一角落到照片边上（距离 ≤ 1e−9）；
///   4. 开勾选时不缩（本来就放得下）：0° / 9° 里一个内缩 10 % 的框，开勾选前后**逐字段相等**
///      （`==`，不是 1e−12）；
///   5. 开勾选时该缩才缩：45° 满幅（任何平移都放不下）→ 一次性内切，面积变小，内切后 4 角都在内；
///   6. 勾选状态跨 setAngle / 换图 / 重开工具保持（读偏好 `photons.cropStaysInsidePixels`）。
///
/// 另外一条 UI 用例：裁切卡里那个**真的** `NSButton(checkboxWithTitle: "不出像素")` 在位、默认关、
/// 点一下就把偏好与控制器一起翻过去。
///
/// 判据全部在测试里重推（`CropGeometry.RotationMatrix` 的 −θ 转角 + 两个支撑数），不从
/// `CropMath` 读答案，所以这里的绿不是「拿实现给自己打分」。
///
/// 反向门（门后要红的那一条在文件末尾的注释里，红字原文见 `docs/tasks/317-crop-pixel-clamp.md` §6）：
/// 恒 `false`（`placedInsidePixels` 永不生效）→ 验收 2/3 红；恒 `true`（无视勾选）→ 验收 1 红。
@MainActor
final class CropPixelClamp317Tests: XCTestCase {

    private var workDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// `CropToolController` holds its session **weakly** (the window owns it in the app); a test has to
    /// keep it alive itself or `sourceSize` falls back to 1×1 and every number below is about a
    /// one-pixel photograph.
    private var keptSessions: [CatalogSession] = []

    private static let source = ImageSize(width: 6000, height: 4000)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-317-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        suiteName = "photons.crop317.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private func makeController() throws -> CropToolController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        keptSessions.append(session)
        let controller = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(controller.begin())
        XCTAssertEqual(controller.sourceSize, Self.source, "测试必须量的是 6000×4000")
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

    /// One tick **exactly as the app runs it** — the drag, then the refresh's `clampToView`
    /// (`LoupeController.continueCropDrag` → `refreshCropTool` → `syncCropOverlay`).
    private func tick(_ controller: CropToolController, to target: NormalizedPoint,
                      mapping map: LoupeMapping, degrees: Double) {
        controller.continueDrag(atViewPoint: viewPoint(normalized: target, mapping: map,
                                                       degrees: degrees),
                                mapping: map, source: Self.source)
        _ = controller.clampToView(mapping: map, source: Self.source)
    }

    private func grab(_ controller: CropToolController, at point: NormalizedPoint,
                      mapping map: LoupeMapping, degrees: Double) {
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: point, mapping: map,
                                                                  degrees: degrees),
                                           mapping: map, source: Self.source))
        XCTAssertEqual(controller.lastHandle, .inside, "按住框内必须拿到 .inside")
    }

    // MARK: - the measurement (recomputed here, never read from CropMath)

    /// The four corners of `rect`, turned by −θ into the photograph's own axes, and the **worst**
    /// signed distance to the picture's four edges — in normalized rect units, so `>= 0` is
    /// 「四角都在照片里」 and `<= 1e-9` at the limit is 「贴边」.
    private func worstCornerDistance(_ rect: CropRect, degrees: Double,
                                     source: ImageSize = source) -> Double {
        let w = Double(source.width), h = Double(source.height)
        let m = CropGeometry.RotationMatrix(degrees: degrees)
        var worst = Double.infinity
        for (u, v) in [(rect.left, rect.top), (rect.right, rect.top),
                       (rect.right, rect.bottom), (rect.left, rect.bottom)] {
            let sensor = m.invert(x: u * w - w / 2, y: v * h - h / 2)
            worst = min(worst, (w / 2 - abs(sensor.x)) / w, (h / 2 - abs(sensor.y)) / h)
        }
        return worst
    }

    /// How many of the four corners are outside the turned picture by more than `tolerance`
    /// (normalized units) — the count 验收 1 is about.
    private func cornersOutside(_ rect: CropRect, degrees: Double,
                                tolerance: Double = 1e-9) -> Int {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let m = CropGeometry.RotationMatrix(degrees: degrees)
        return [(rect.left, rect.top), (rect.right, rect.top),
                (rect.right, rect.bottom), (rect.left, rect.bottom)].reduce(into: 0) { count, corner in
            let sensor = m.invert(x: corner.0 * w - w / 2, y: corner.1 * h - h / 2)
            let distance = min((w / 2 - abs(sensor.x)) / w, (h / 2 - abs(sensor.y)) / h)
            if distance < -tolerance { count += 1 }
        }
    }

    /// The same rectangle, shrunk about its own centre by `factor` — 「内缩 10 %」.
    private func inset(_ rect: CropRect, by factor: Double) -> CropRect {
        let width = rect.width * factor, height = rect.height * factor
        let left = rect.centerX - width / 2, top = rect.centerY - height / 2
        return CropRect(left: left, top: top, right: left + width, bottom: top + height)
    }

    private func label(_ degrees: Double) -> String { String(format: "%.0f°", degrees) }

    // MARK: - ① 未勾选 = 307 现状（框可以盖住 000000）

    /// 15° 满幅（6000×4000 → 画布 `-0.0660…1.0660 × -0.0801…1.0801`），框推到画布右下角：
    /// 照片的角在画布里面，所以这条位移的最后一段必然把框的两个角送进 `000000`。
    ///
    /// 断言：勾选默认 `false`；推到极限后有 **> 0** 个角在照片外，且最远那个角出了 ≥ 1e-3
    /// （0.1 % 的画布宽，远大于浮点噪声）；尺寸仍是快照（307 的「只停住不缩放」）。
    func testOneUncheckedTheFrameMayStillCoverTheBlackCorners() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        controller.draft = CropToolController.Draft(crop: .full, straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)

        XCTAssertFalse(controller.cropStaysInsidePixels, "默认必须是 307 的「可出像素」")
        XCTAssertFalse(defaults.bool(forKey: CropToolController.staysInsidePixelsKey))

        let snapshot = controller.draft.crop
        grab(controller, at: NormalizedPoint(0.5, 0.5), mapping: map, degrees: degrees)
        for _ in 1...20 {
            tick(controller, to: NormalizedPoint(1.6, 1.6), mapping: map, degrees: degrees)
        }
        controller.endDrag()

        let after = controller.draft.crop
        let outside = cornersOutside(after, degrees: degrees)
        let worst = worstCornerDistance(after, degrees: degrees)
        print(String(format: "317 ① · 15° 满幅 unchecked · 末端框 L %.6f T %.6f R %.6f B %.6f"
                     + " · 角点在照片外 %d 个 · 最差有符号距离 %.6e · 尺寸 %.12f×%.12f",
                     after.left, after.top, after.right, after.bottom, outside, worst,
                     after.width, after.height))
        XCTAssertGreaterThan(outside, 0, "未勾选必须还能盖住 000000（317 不许改 307 的默认）")
        XCTAssertLessThan(worst, -1e-3, "最远的角要真的出了照片（实测 \(worst)）")
        XCTAssertEqual(after.width, snapshot.width, accuracy: 1e-12, "307 的「只停住不缩放」不变")
        XCTAssertEqual(after.height, snapshot.height, accuracy: 1e-12)
    }

    // MARK: - ② 勾选后不能出像素（20 tick，尺寸不变）

    /// 15° 的**内接**框（满幅在 15° 放不下：`A = 3000·cos15° + 2000·sin15° = 3415.6 > 3000`），
    /// 开勾选后 20 tick：10 tick 小步（框还在照片里走），10 tick 大步（每步都被四边停住）。
    ///
    /// 每一步都断言：4 个角到四条边的有符号距离 ≥ −1e−9，且宽高与按下时快照差 ≤ 1e−12。
    func testTwoCheckedTheFrameNeverLeavesThePixelsAndNeverResizes() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        let inscribed = CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true)
        controller.draft = CropToolController.Draft(crop: inscribed, straighten: degrees,
                                                    lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)
        XCTAssertGreaterThanOrEqual(worstCornerDistance(controller.draft.crop, degrees: degrees), -1e-9,
                                    "起点本身就在照片里")

        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        XCTAssertTrue(controller.cropStaysInsidePixels)

        let snapshot = controller.draft.crop
        let grabbed = NormalizedPoint(controller.draft.crop.centerX, controller.draft.crop.centerY)
        grab(controller, at: grabbed, mapping: map, degrees: degrees)

        var worstDistance = Double.infinity
        var worstDw = 0.0, worstDh = 0.0
        for index in 1...20 {
            // 1…10: 0.005 一步的小推（先往右下，再往左上）；11…20: 一次推出去 1.5 个画布。
            let offset = index <= 10
                ? 0.005 * Double(index)
                : -1.5 * Double(index - 10)
            tick(controller, to: NormalizedPoint(grabbed.x + offset, grabbed.y + offset),
                 mapping: map, degrees: degrees)
            let now = controller.draft.crop
            let distance = worstCornerDistance(now, degrees: degrees)
            worstDistance = min(worstDistance, distance)
            let dw = abs(now.width - snapshot.width), dh = abs(now.height - snapshot.height)
            worstDw = max(worstDw, dw)
            worstDh = max(worstDh, dh)
            XCTAssertGreaterThanOrEqual(distance, -1e-9,
                String(format: "317 ② tick %d: 角点出了照片 %.3e（宽 %.12f 高 %.12f）",
                       index, distance, now.width, now.height))
            XCTAssertLessThanOrEqual(dw, 1e-12,
                String(format: "317 ② tick %d: Δwidth %.3e（310：拖动不改尺寸）", index, dw))
            XCTAssertLessThanOrEqual(dh, 1e-12,
                String(format: "317 ② tick %d: Δheight %.3e（310：拖动不改尺寸）", index, dh))
        }
        controller.endDrag()
        print(String(format: "317 ② · 15° 20 tick · 最差有符号距离 %.3e · Δw %.1e · Δh %.1e"
                     + " · 末端 %.12f×%.12f", worstDistance, worstDw, worstDh,
                     controller.draft.crop.width, controller.draft.crop.height))
        XCTAssertEqual(controller.canvasShrinkTicks, 0, "整段拖动里 clampToCanvas 的缩分支必须 0 次")
    }

    // MARK: - ③ 上限可达（推到极限就贴边，不是保守地缩在一角）

    /// 沿一个方向一直推（右下 1.6 个画布，20 tick），最后至少一个角落在照片边上：距离 ≤ 1e−9。
    /// 同时它仍然不许越界（≥ −1e−9）—— 贴边而不是穿出去。
    func testThreeTheLimitIsTheEdgeItself() throws {
        let degrees = 15.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        let inscribed = CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true)
        controller.draft = CropToolController.Draft(crop: inscribed, straighten: degrees,
                                                    lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)
        XCTAssertTrue(controller.setCropStaysInsidePixels(true))

        let grabbed = NormalizedPoint(controller.draft.crop.centerX, controller.draft.crop.centerY)
        grab(controller, at: grabbed, mapping: map, degrees: degrees)
        for _ in 1...20 {
            tick(controller, to: NormalizedPoint(grabbed.x + 1.6, grabbed.y + 1.6),
                 mapping: map, degrees: degrees)
        }
        controller.endDrag()

        let after = controller.draft.crop
        let distance = worstCornerDistance(after, degrees: degrees)
        print(String(format: "317 ③ · 推到极限 · 框 L %.9f T %.9f R %.9f B %.9f"
                     + " · 最近角到照片边 %.6e", after.left, after.top, after.right, after.bottom,
                     distance))
        XCTAssertLessThanOrEqual(distance, 1e-9, "极限处必须贴边（距离 \(distance) 太大 = 保守）")
        XCTAssertGreaterThanOrEqual(distance, -1e-9, "贴边，不是穿出去")
    }

    // MARK: - ④ 开勾选不缩（本来就放得下 → 逐字段相等）

    /// 0°：满幅内缩 10 %（`0.05…0.95`）；9°：307 自己内切出的框再内缩 10 %。
    ///
    /// 两个都**放得下**（平移可行），所以 `setCropStaysInsidePixels(true)` 之后 `draft.crop` 的四个
    /// 字段**逐位相等**（`==`，没有 1e−12 的余地），连随后的 `clampToView` 都不许动它一个 ULP。
    func testFourTurningTheBoxOnDoesNotShrinkAFrameThatAlreadyFits() throws {
        var report: [String] = []
        for degrees in [0.0, 9.0] {
            // Each angle gets a clean preference: ④ is about the *toggle*, not about a state left behind.
            defaults.removePersistentDomain(forName: suiteName)
            let controller = try makeController()
            XCTAssertFalse(controller.cropStaysInsidePixels)
            let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
            let base = degrees == 0
                ? inset(.full, by: 0.9)
                : inset(CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true), by: 0.9)
            controller.draft = CropToolController.Draft(crop: base, straighten: degrees,
                                                        lock: .original)
            _ = controller.clampToView(mapping: map, source: Self.source)
            let before = controller.draft.crop
            let limit = CropMath.pixelTranslationLimit(of: before, in: Self.source, degrees: degrees)
            XCTAssertTrue(limit.isFeasible, "\(label(degrees)): 这个框必须放得下（可行集非空）")
            XCTAssertGreaterThanOrEqual(worstCornerDistance(before, degrees: degrees), -1e-9)

            XCTAssertTrue(controller.setCropStaysInsidePixels(true))
            _ = controller.clampToView(mapping: map, source: Self.source)
            let after = controller.draft.crop

            XCTAssertEqual(after.left, before.left, "\(label(degrees)): left 逐字段必须相等")
            XCTAssertEqual(after.top, before.top, "\(label(degrees)): top 逐字段必须相等")
            XCTAssertEqual(after.right, before.right, "\(label(degrees)): right 逐字段必须相等")
            XCTAssertEqual(after.bottom, before.bottom, "\(label(degrees)): bottom 逐字段必须相等")
            XCTAssertEqual(after, before, "\(label(degrees)): 整条 rect 必须 `==`")
            report.append(String(format: "%@ L %.9f T %.9f R %.9f B %.9f",
                                 label(degrees), after.left, after.top, after.right, after.bottom))
        }
        print("317 ④ · 开勾选前后逐字段相等 · " + report.joined(separator: " · "))
    }

    // MARK: - ⑤ 开勾选时该缩才缩（45° 满幅 → 一次性内切）

    /// 45° 满幅：`A = B = 3000·cos45° + 2000·sin45° = 3535.5 > 3000 / 2000`，任何平移都放不下
    /// （可行集为空）。开勾选 → 一次性内切（`clampedToRotatedFrame(keepsInside: true)`）：
    /// 面积严格变小、宽高比保持、4 角都在照片里。
    func testFiveAFrameThatFitsNowhereIsInscribedOnce() throws {
        let degrees = 45.0
        let controller = try makeController()
        let map = mapping(LoupeViewState(mode: .fit, zoom: 1), degrees: degrees)
        controller.draft = CropToolController.Draft(crop: .full, straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)
        XCTAssertEqual(controller.draft.crop, .full, "45° 满幅的草稿就是满幅（307 的单次内切只在 setAngle 里）")

        let limit = CropMath.pixelTranslationLimit(of: .full, in: Self.source, degrees: degrees)
        XCTAssertFalse(limit.isFeasible, "45° 满幅的平移可行集必须是空的")
        let before = controller.draft.crop
        let areaBefore = before.width * before.height

        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        let after = controller.draft.crop
        let areaAfter = after.width * after.height
        let distance = worstCornerDistance(after, degrees: degrees)
        print(String(format: "317 ⑤ · 45° 满幅 · area %.6f → %.6f (Δ %.6f) · 内切后 %.9f×%.9f"
                     + " · 最近角 %.3e · 可行集 w %.3f h %.3f",
                     areaBefore, areaAfter, areaBefore - areaAfter, after.width, after.height,
                     distance, limit.x, limit.y))
        XCTAssertLessThan(areaAfter, areaBefore, "该缩就要缩（面积必须变小）")
        XCTAssertGreaterThan(areaBefore - areaAfter, 1e-6, "缩得出来才算缩（Δarea > 0）")
        XCTAssertGreaterThanOrEqual(distance, -1e-9, "内切以后 4 个角都在照片里")
        XCTAssertEqual(after.width / after.height, before.width / before.height, accuracy: 1e-9,
                       "内切保像素比")
    }

    // MARK: - ⑥ 勾选状态跨 setAngle / 换图 / 重开工具保持

    /// 勾选写的是**偏好**，所以它不属于草稿、不属于文档，也不被 `setAngle` 或换图复位：
    /// 同一个控制器、另建一个控制器（＝重开工具）、`reseedForPhotoChange`（＝换图）读到的都是 `true`；
    /// 一个从未写过的 suite 读到的是 `false`。
    func testSixTheBoxSurvivesAnglePhotoAndToolReopen() throws {
        let controller = try makeController()
        XCTAssertFalse(controller.cropStaysInsidePixels, "默认关")
        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        XCTAssertTrue(defaults.bool(forKey: CropToolController.staysInsidePixelsKey),
                      "偏好键 photons.cropStaysInsidePixels 必须被写")

        controller.setAngle(uiValue: 12)
        XCTAssertTrue(controller.cropStaysInsidePixels, "setAngle 不许复位勾选")

        // 换图
        XCTAssertTrue(controller.reseedForPhotoChange())
        XCTAssertTrue(controller.cropStaysInsidePixels, "换图不许复位勾选")

        // 重开工具（同一个控制器）
        controller.cancel()
        XCTAssertTrue(controller.begin())
        XCTAssertTrue(controller.cropStaysInsidePixels, "重开工具不许复位勾选")

        // 重开工具（新建的控制器，同一个偏好存储 = 另一个窗口/另一次启动）
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        keptSessions.append(session)
        let reopened = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(reopened.begin())
        XCTAssertTrue(reopened.cropStaysInsidePixels, "新控制器必须从偏好读到 true")

        // 一个干净的存储 → 默认 false
        let fresh = try XCTUnwrap(UserDefaults(suiteName: "photons.crop317.fresh.\(UUID().uuidString)"))
        let clean = CropToolController(session: session, defaults: fresh)
        XCTAssertFalse(clean.cropStaysInsidePixels, "没写过偏好的库必须是 307 的默认")
        print("317 ⑥ · 勾选跨 setAngle / 换图 / 重开工具保持 · 键 \(CropToolController.staysInsidePixelsKey)")
    }

    // MARK: - 卡片里的那个 NSButton

    /// 变换工作区的**裁切卡**里有一个真的 `NSButton(checkboxWithTitle: "不出像素")`，默认关，
    /// 与 `CropToolController.cropStaysInsidePixels` 同一位；点一下两边一起翻。
    func testSevenTheCropCardCarriesTheRealCheckbox() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer {
            // 这个窗口用的是 `UserDefaults.standard`：离开前把偏好还原成 307 的默认。
            editor.rootView.loupeController.cropTool.setCropStaysInsidePixels(false)
            editor.window?.orderOut(nil)
        }
        let loupe = editor.rootView.loupeController
        XCTAssertTrue(loupe.beginCropTool())
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let boxes = Self.allViews(in: inspector).compactMap { $0 as? NSButton }
            .filter { $0.title == "不出像素" }
        let box = try XCTUnwrap(boxes.first, "裁切卡里没有「不出像素」勾选框")
        XCTAssertEqual(boxes.count, 1, "只有一个")
        XCTAssertEqual(box.state, .off, "默认不勾（307）")
        XCTAssertEqual(box.accessibilityIdentifier(), "inspector.crop.staysInsidePixels")

        let row = try XCTUnwrap(Self.allViews(in: inspector).compactMap { $0 as? CropRowProbe }
            .first { $0.rowID == CropCardID.staysInsidePixels }, "勾选框的行探针不在树上")
        let grid = try XCTUnwrap(Self.allViews(in: inspector).compactMap { $0 as? CropRowProbe }
            .first { $0.rowID == CropCardID.grid })
        let rowRect = row.convert(row.bounds, to: inspector)
        let gridRect = grid.convert(grid.bounds, to: inspector)
        // 334 之后裁切卡只剩比例 + 自定义 + 不出像素 + 九宫格：九宫格从「与勾选框同一行」改为**独立一行**，
        // 排在勾选框下面（用户：卡片里保留九宫格）。断言改成「上下相邻、九宫格在下」，语义不变。
        XCTAssertGreaterThan(gridRect.minY, rowRect.maxY - 0.5,
                             "317/334: 九宫格在「不出像素」下面一行")
        XCTAssertLessThanOrEqual(abs(gridRect.minX - rowRect.minX), 1,
                                 "317/334: 两行左对齐")

        box.performClick(nil)
        CropUITestSupport.pump(0.05)
        XCTAssertTrue(loupe.cropTool.cropStaysInsidePixels, "点一下必须写到控制器")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CropToolController.staysInsidePixelsKey),
                      "点一下必须写到偏好")
        XCTAssertEqual(box.state, .on)

        box.performClick(nil)
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.cropTool.cropStaysInsidePixels, "再点一下关掉")
        print(String(format: "317 UI · 「不出像素」 %@ · row %@ · grid %@",
                     box.state == .on ? "on" : "off", NSStringFromRect(rowRect),
                     NSStringFromRect(gridRect)))
    }

    private static func allViews(in root: NSView) -> [NSView] {
        var found: [NSView] = [root]
        for sub in root.subviews { found += allViews(in: sub) }
        return found
    }
}
