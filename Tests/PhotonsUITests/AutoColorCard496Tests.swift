import XCTest
import SwiftUI
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 派单 496b — 「色彩」卡的 自动颜色 图标按钮（496 在 497 之后重做）。
///
/// 算法与两个入口（右键「自动调整」、顶栏「全部自动」）已经存在；这一份只管**色彩卡这个新入口**，
/// 以及它与「明暗」卡的隔离：
///
///   1. 点彩色卡的 wand 只写 `color.vibrance`：`light`（含 `blackOffset`）、`color.saturation`、
///      `detail`、`sharpen`、`effects`、`geometry` 逐字段相等（并打印点前/点后，作为证据）。
///   2. 反向：点「明暗」卡的 wand 后 `color.vibrance` / `color.saturation` 不变。
///   3. 按钮 == 直接调 `loupe.autoColor()`：同一张图、中途撤销，两次 `vibrance` 逐位相同。
///   4. 「自动调整」仍然含色彩：一次按下 ⇒ 明暗至少一项变 **且** `vibrance` 变、一条历史、一次撤销全回退。
///   5. 右键菜单只做方向性断言：单选时自动项恰有一条且标题为「自动调整」（「自动颜色」行已由 497 删除）。
///   6. 几何：与「明暗」卡按钮同尺寸，右缘各贴自己的值列，且各在自己那一行上方。
@MainActor
final class AutoColorCard496Tests: XCTestCase {

    private static let panelHeight: CGFloat = 2600
    private var windows: [NSWindow] = []
    private var workDir: URL?

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    // MARK: - fixtures

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

    @discardableResult
    private func host(_ view: InspectorView) -> NSHostingView<InspectorView> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        TestWindows.show(window, key: true)
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func makeController(url: URL, identity: String,
                                session: CatalogSession) throws -> LoupeController {
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        return loupe
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - ① 跨卡隔离：彩色卡只动 vibrance

    func testTheColorButtonTouchesOnlyVibranceAcrossEveryCard() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496b-isolation", session: session)

        // Non-neutral values in every other group make the equality below mean something: a plan that
        // accidentally wrote a whole group would move a visible number, not a zero.
        session.applyEdit {
            $0.color.vibrance = -20
            $0.color.saturation = 17
            $0.light.exposure = 0.35
            $0.light.blackOffset = 0.004
            $0.light.blacks = -12
            $0.detail.sharpening = 23
            $0.sharpen.amount = 41
            $0.effects.texture = 9
            $0.effects.grain = 11
            $0.geometry.quarterTurns = 1
        }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit
        let historyBefore = session.history.count

        let host = host(InspectorView(session: session, loupe: loupe))
        let probe = try XCTUnwrap(Self.colorProbe(in: host,
                                                 probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }))
        print(String(format: "496b isolation · before: vibrance %+.2f sat %+.2f light(ev %+.3f hi %+.1f mid %+.1f sh %+.1f wh %+.1f bl %+.1f ctr %+.1f blackOffset %.5f) detail.sharpening %.1f sharpen.amount %.1f effects.texture %.1f grain %.1f geometry.turns %d",
                     before.color.vibrance, before.color.saturation,
                     before.light.exposure, before.light.highlights, before.light.midtones,
                     before.light.shadows, before.light.whites, before.light.blacks,
                     before.light.contrast, before.light.blackOffset,
                     before.detail.sharpening, before.sharpen.amount,
                     before.effects.texture, before.effects.grain, before.geometry.quarterTurns))

        Self.click(probe, in: host)
        pump(0.05)
        let after = session.edit
        print(String(format: "496b isolation · after:  vibrance %+.2f sat %+.2f light(ev %+.3f hi %+.1f mid %+.1f sh %+.1f wh %+.1f bl %+.1f ctr %+.1f blackOffset %.5f) detail.sharpening %.1f sharpen.amount %.1f effects.texture %.1f grain %.1f geometry.turns %d",
                     after.color.vibrance, after.color.saturation,
                     after.light.exposure, after.light.highlights, after.light.midtones,
                     after.light.shadows, after.light.whites, after.light.blacks,
                     after.light.contrast, after.light.blackOffset,
                     after.detail.sharpening, after.sharpen.amount,
                     after.effects.texture, after.effects.grain, after.geometry.quarterTurns))

        XCTAssertNotEqual(after.color.vibrance, before.color.vibrance, "彩色卡必须写 vibrance")
        XCTAssertEqual(session.history.count, historyBefore + 1, "一次点击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动颜色")

        // The用户口径: 明暗卡管明暗、色彩卡管色彩.
        XCTAssertEqual(after.light, before.light, "light 整组不变（含 blackOffset）")
        XCTAssertEqual(after.light.exposure, before.light.exposure)
        XCTAssertEqual(after.light.contrast, before.light.contrast)
        XCTAssertEqual(after.light.highlights, before.light.highlights)
        XCTAssertEqual(after.light.midtones, before.light.midtones)
        XCTAssertEqual(after.light.shadows, before.light.shadows)
        XCTAssertEqual(after.light.whites, before.light.whites)
        XCTAssertEqual(after.light.blacks, before.light.blacks)
        XCTAssertEqual(after.light.blackOffset, before.light.blackOffset, "blackOffset 逐位不变")
        // 498（d10faa0，在本 lane 基点 8fe5062 之后合入）把自动颜色升成**两自由度**：
        // p50 → vibrance、p95 → saturation（`AutoColorAll490Tests.testAutoColorAloneWritesBothColorSliders…`
        // 是 main 上的既有断言）。所以「色彩卡只动一个字段」这句口径从 498 起不成立 ——
        // 色彩卡管的是**两个色彩滑块**，跨卡的隔离仍然必须逐位成立。
        XCTAssertGreaterThan(after.color.vibrance, before.color.vibrance, "vibrance 变")
        XCTAssertGreaterThanOrEqual(after.color.saturation, before.color.saturation,
                                    "saturation 只加不减（498 的护栏）")
        XCTAssertEqual(after.detail, before.detail, "detail 整组不变")
        XCTAssertEqual(after.sharpen, before.sharpen, "sharpen 整组不变")
        XCTAssertEqual(after.effects, before.effects, "effects 整组不变")
        XCTAssertEqual(after.geometry, before.geometry, "geometry 整组不变")
    }

    // MARK: - ② 反向：明暗卡不碰色彩

    func testTheLightButtonLeavesVibranceAndSaturationAlone() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496b-light", session: session)

        session.applyEdit {
            $0.color.vibrance = 7
            $0.color.saturation = 13
        }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit

        let host = host(InspectorView(session: session, loupe: loupe))
        let probe = try XCTUnwrap(Self.lightProbe(in: host,
                                                 probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }))
        Self.click(probe, in: host)
        pump(0.05)
        let after = session.edit
        print(String(format: "496b reverse · light before EV %+.2f after %+.2f · vibrance %+.2f→%+.2f · saturation %+.2f→%+.2f",
                     before.light.exposure, after.light.exposure,
                     before.color.vibrance, after.color.vibrance,
                     before.color.saturation, after.color.saturation))

        XCTAssertNotEqual(after.light, before.light, "明暗卡的按钮必须真的工作（否则隔离断言没有意义）")
        XCTAssertEqual(after.color.vibrance, before.color.vibrance, "明暗卡不得写 vibrance")
        XCTAssertEqual(after.color.saturation, before.color.saturation, "明暗卡不得写 saturation")
        XCTAssertEqual(after.color, before.color, "color 整组不变")
    }

    // MARK: - ③ 按钮 == loupe.autoColor()，逐位相同

    func testTheButtonAndTheControllerVerbProduceTheSameBits() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496b-same-source", session: session)

        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit

        let host = host(InspectorView(session: session, loupe: loupe))
        let probe = try XCTUnwrap(Self.colorProbe(in: host,
                                                 probes: Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }))
        Self.click(probe, in: host)
        pump(0.05)
        let buttonValue = session.edit.color.vibrance

        XCTAssertTrue(session.undo(), "中途撤销，让第二次从同一个起点重新测")
        XCTAssertEqual(session.edit, before, "撤销必须回到点击前")

        let directValue = try XCTUnwrap(loupe.autoColor(), "直接调 autoColor() 必须给出 plan")
        print(String(format: "496b same-source · button %+.17g (0x%016llx) · direct %+.17g (0x%016llx)",
                     buttonValue, buttonValue.bitPattern,
                     directValue, directValue.bitPattern))

        XCTAssertEqual(buttonValue, directValue, "按钮与 autoColor() 必须是同一套 plan")
        XCTAssertEqual(buttonValue.bitPattern, directValue.bitPattern, "逐位相同")
    }

    // MARK: - ④ 「自动调整」确实含色彩：一条历史、一次撤销

    func testAutoAdjustMovesLightAndColorInOneUndoableRow() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496b-auto-adjust", session: session)

        // Raise-only colour is a no-op on this fixture's own chroma, so a -20 baseline makes the
        // composite's colour step move even at plan 0 (0 > -20). Dropping the step turns vibrance red.
        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit
        let historyBefore = session.history.count

        XCTAssertTrue(loupe.autoDevelop(), "一张有帧的照片必须给出复合 plan")
        let after = session.edit
        print(String(format: "496b auto-adjust · EV %+.3f→%+.3f · blackOffset %.5f→%.5f · vibrance %+.2f→%+.2f · history %d→%d",
                     before.light.exposure, after.light.exposure,
                     before.light.blackOffset, after.light.blackOffset,
                     before.color.vibrance, after.color.vibrance,
                     historyBefore, session.history.count))

        XCTAssertEqual(session.history.count, historyBefore + 1, "自动调整只能有一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动调整")

        let lightMoved = after.light.exposure != before.light.exposure
            || after.light.highlights != before.light.highlights
            || after.light.whites != before.light.whites
            || after.light.blacks != before.light.blacks
            || after.light.blackOffset != before.light.blackOffset
        XCTAssertTrue(lightMoved, "自动调整必须含明暗")
        XCTAssertNotEqual(after.color.vibrance, before.color.vibrance, "自动调整必须含色彩")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit, before, "一次撤销把明暗与色彩一起回退")
        XCTAssertEqual(session.history.currentSnapshot?.label, "原照")
    }

    // MARK: - ⑤ 菜单方向：单选时只有一条「自动调整」

    func testTheSingleSelectionMenuHasOneAutoRowAndNoColorSibling() throws {
        let session = try makeCatalogSession()
        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)

        let menu = try XCTUnwrap(grid.menuForRightClick(nil))
        let autoTitles = menu.items.map(\.title).filter {
            $0 == AutoAdjustMenuBuilder.title || $0 == "自动颜色"
        }
        print("496b menu · auto rows = \(autoTitles) · all titles = \(menu.items.map(\.title))")

        XCTAssertEqual(AutoAdjustMenuBuilder.title, "自动调整")
        XCTAssertEqual(autoTitles, ["自动调整"], "单选时自动项恰有一条，且没有第二行「自动颜色」")
        XCTAssertEqual(menu.items.filter { $0.title == "自动调整" }.count, 1)
    }

    // MARK: - ⑥ 几何：与明暗卡同尺寸、各自贴自己的值列、各在自己那一行上方

    func testTheColorIconMatchesTheLightIconAndSitsAboveItsOwnRow() throws {
        let host = host(InspectorView(session: CatalogSession()))

        let probes = Self.allViews(in: host).compactMap { $0 as? LightAutoProbe }
        XCTAssertEqual(probes.count, 2, "wand 家族应有两只探针：明暗卡与色彩卡")

        let colorProbe = try XCTUnwrap(Self.colorProbe(in: host, probes: probes),
                                       "色彩卡头里找不到 wand 探针")
        let lightProbe = try XCTUnwrap(Self.lightProbe(in: host, probes: probes),
                                       "明暗卡头里找不到 wand 探针")
        XCTAssertFalse(colorProbe === lightProbe, "两只探针必须是两个实例")

        let colorField = try XCTUnwrap(Self.view(in: host, id: "inspector.color.自然饱和"),
                                       "色彩卡的第一行没有渲染出来")
        let lightField = try XCTUnwrap(Self.view(in: host, id: "inspector.light.曝光"),
                                       "明暗卡的第一行没有渲染出来")
        let colorIcon = colorProbe.convert(colorProbe.bounds, to: host)
        let lightIcon = lightProbe.convert(lightProbe.bounds, to: host)
        let colorValue = colorField.convert(colorField.bounds, to: host)
        let lightValue = lightField.convert(lightField.bounds, to: host)
        print(String(format: "496b geometry · color (%.2f, %.2f, %.2f×%.2f) vs value maxX %.2f · light (%.2f, %.2f, %.2f×%.2f) vs value maxX %.2f",
                     colorIcon.minX, colorIcon.minY, colorIcon.width, colorIcon.height, colorValue.maxX,
                     lightIcon.minX, lightIcon.minY, lightIcon.width, lightIcon.height, lightValue.maxX))

        XCTAssertEqual(colorIcon.width, lightIcon.width, accuracy: 0.001, "宽度与 自动调节 同尺寸（差 0.00）")
        XCTAssertEqual(colorIcon.height, lightIcon.height, accuracy: 0.001, "高度与 自动调节 同尺寸（差 0.00）")
        XCTAssertGreaterThanOrEqual(colorIcon.width, 18, "命中区 ≥ 18 pt 宽")
        XCTAssertGreaterThanOrEqual(colorIcon.height, 18, "命中区 ≥ 18 pt 高")
        XCTAssertFalse(colorProbe.hasBorder, "裸图标：没有底、没有边、没有胶囊（同一族）")

        // Row ownership, not instance order: each wand is compared with its own card's first row.
        XCTAssertLessThan(colorIcon.midY, colorValue.midY, "色彩卡的图标在「自然饱和」行上方")
        XCTAssertLessThan(lightIcon.midY, lightValue.midY, "明暗卡的图标在「曝光」行上方")
        XCTAssertLessThanOrEqual(abs(colorIcon.maxX - colorValue.maxX), 0.5,
                                 "色彩卡右缘与值列右边对齐（−2 尾距抵掉单元格溢出）")
        XCTAssertLessThanOrEqual(abs(lightIcon.maxX - lightValue.maxX), 0.5,
                                 "明暗卡右缘与值列右边对齐")
        XCTAssertGreaterThanOrEqual(colorIcon.maxX, colorValue.minX, "不得挤进标题区域")
        XCTAssertGreaterThanOrEqual(lightIcon.maxX, lightValue.minX, "不得挤进标题区域")

        let ids = Self.allViews(in: host).compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(ids.contains("inspector.color.自然饱和") || ids.contains("inspector.color.饱和"),
                      "色彩卡的行仍然在")
        XCTAssertEqual(InspectorView.colorRows.count, 2, "自动颜色 是卡头按钮，不是色彩卡的第三行")
        XCTAssertFalse(InspectorView.colorRows.map(\.title).contains("自动颜色"))

        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"inspector.color.auto\")"),
                      "控件树的 id 必须是 inspector.color.auto")
        XCTAssertTrue(source.contains("private var autoColorButton: some View"))
        XCTAssertTrue(source.contains("spec.section == .color"),
                      "挂在色彩卡的 accessory 上，不是新加一行")
        XCTAssertTrue(source.contains("_ = loupe?.autoColor()"),
                      "动作必须是 loupe?.autoColor()（不复制算法）")
    }

    // MARK: - menu fixture

    private func makeCatalogSession() throws -> CatalogSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-auto496b-menu-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        workDir = root

        let library = root.appendingPathComponent("S496b.\(LibraryLayout.packageExtension)", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let sourceRoot = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_496b.dng"
        let fileURL = src.appendingPathComponent(name)
        try Data([0x00]).write(to: fileURL)
        let asset = Asset(sourceRootId: sourceRoot.id, relPath: name, filename: name,
                          ext: "dng", kind: .raw, size: 1, mtime: 0,
                          contentHash: UUID().uuidString,
                          width: 1024, height: 1024,
                          captureTime: "2026-05-01T10:00:00Z",
                          captureLocalDate: "2026-05-01",
                          cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try catalog.dbQueue.write { db in try asset.insert(db) }

        let session = CatalogSession(remembersRecentLibrary: false)
        try session.open(library)
        session.setSortOrder(.newestFirst)
        session.setSelection([asset.id], anchor: asset.id)
        return session
    }

    // MARK: - ⑦ help 文案说明「为什么是 0」（501 删掉 autoColorHelpText 之后的新来源）

    func testTheHelpTextExplainsWhyNothingWasWritten() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = try makeController(url: url, identity: "496b-help", session: session)
        let view = InspectorView(session: session, loupe: loupe)

        // 点前：还没按过 ⇒ reason 是 nil ⇒「我做什么」那句。
        XCTAssertNil(loupe.lastAutoColorNoOpReasonForTesting)
        let idle = view.autoColorHelp
        print("496b help · 点前 (reason nil) = \(idle)")
        XCTAssertEqual(idle, Loc.t("自动颜色：按彩度中位数与 95 分位同时调整自然饱和度与饱和度"))

        // 第一次按：文档的 vibrance 低于 plan 目标 ⇒ 真的写了 ⇒ reason 回到 nil。
        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        XCTAssertNotNil(loupe.autoColor(), "第一次按必须写")
        pump(0.05)
        let moved = view.autoColorHelp
        print("496b help · 点后 (vibrance \(session.edit.color.vibrance), reason nil) = \(moved)")
        XCTAssertNil(loupe.lastAutoColorNoOpReasonForTesting, "写进去了就不该有 no-op 原因")
        XCTAssertEqual(moved, idle, "写过之后回到「我做什么」那句")

        // 第二次按：两个色彩滑块都顶到 100（plan 只能「只加不减」地抬，抬不动）⇒ 合法的 0 + 0，
        // 必须说明而不是静默。这也是 490 那条「第二次是 no-op」的状态，只是这里直接压在饱和端。
        session.applyEdit {
            $0.color.vibrance = 100
            $0.color.saturation = 100
        }
        XCTAssertTrue(session.commitEdit(label: "顶到 100"))
        XCTAssertNil(loupe.autoColor(), "抬不动就不写")
        XCTAssertEqual(loupe.lastAutoColorNoOpReasonForTesting, .alreadySaturated)
        let settled = view.autoColorHelp
        print("496b help · 点后 (reason alreadySaturated, sat \(session.edit.color.saturation)) = \(settled)")
        XCTAssertEqual(settled, Loc.t("自动颜色：这张已经足够饱和，两个参数都保持 0"))

        // .tooGrey：本仓没有「几乎无颜色」的 RAW 样片，所以这一行按按钮自己调用的那张映射表测，
        // 用的是管线在 画面几乎没有颜色 时写入的那个 case。
        let grey = InspectorView.autoColorHelpText(for: .tooGrey, waitingForDecode: false)
        let waiting = InspectorView.autoColorHelpText(for: .tooGrey, waitingForDecode: true)
        print("496b help · tooGrey = \(grey) | waiting = \(waiting)")
        XCTAssertEqual(grey, Loc.t("自动颜色：画面几乎没有颜色，未写入"))
        XCTAssertEqual(waiting, Loc.t("等待解码…"), "等待解码压过 no-op 原因")
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func allViews(in root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews { out += allViews(in: child) }
        return out
    }

    private static func view(in root: NSView, id: String) -> NSView? {
        allViews(in: root).first { $0.accessibilityIdentifier() == id }
    }

    /// The color card's wand probe: the one directly above 自然饱和.
    private static func colorProbe(in host: NSView, probes: [LightAutoProbe]) -> LightAutoProbe? {
        guard let field = view(in: host, id: "inspector.color.自然饱和") else { return nil }
        return probe(above: field, in: host, probes: probes)
    }

    /// The Light card's wand probe: the one directly above 曝光.
    private static func lightProbe(in host: NSView, probes: [LightAutoProbe]) -> LightAutoProbe? {
        guard let field = view(in: host, id: "inspector.light.曝光") else { return nil }
        return probe(above: field, in: host, probes: probes)
    }

    /// The wand probe in the header directly above `field` — smallest absolute vertical gap. Using the
    /// row's own frame (not probe order) is what makes this row ownership rather than a guess.
    private static func probe(above field: NSView, in host: NSView,
                              probes: [LightAutoProbe]) -> LightAutoProbe? {
        let value = field.convert(field.bounds, to: host)
        return probes.min { lhs, rhs in
            let a = lhs.convert(lhs.bounds, to: host)
            let b = rhs.convert(rhs.bounds, to: host)
            return abs(value.minY - a.maxY) < abs(value.minY - b.maxY)
        }
    }

    /// A real click on whatever the SwiftUI button landed as: the wand host view is not an `NSButton`,
    /// so drive the window's own hit test at the probe's centre (`CropAspectOrientationTests`' path).
    private static func click(_ probe: NSView, in host: NSView) {
        guard let window = host.window else { return }
        let point = probe.convert(CGPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }
}
