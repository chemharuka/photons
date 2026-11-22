import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 490 — 「全部自动」的顶栏入口、自动颜色的独立入口，以及两者的一条历史行 / 幂等。
///
/// 算法（`AutoColor` / `AutoLight` / 自动黑电平）不在本单里重写：这里量的是**接线**和**流水**，
/// 所以「算法给出的值」是从同一组 candidate 在测试里再算一遍再逐字段比对的。
@MainActor
final class AutoColorAll490Tests: XCTestCase {

    private static let viewport = ImageSize(width: 1024, height: 768)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
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

    private func makeController(url: URL, identity: String,
                                session: CatalogSession) -> LoupeController {
        session.mode = .loupe
        let controller = LoupeController(session: session)
        controller.autoRenderEnabled = true
        controller.collectsHistogram = false
        controller.frameSource = LoupeController.FrameSource(
            url: url, identity: identity, viewport: Self.viewport, state: .fit)
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.scheduleRender()
        return controller
    }

    private func makeBar(width: CGFloat = 1600) -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = 330
        bar.update(mode: .loupe, assetCount: 45, selectionCount: 1,
                   libraryName: "auto490", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func waitForFull(_ loupe: LoupeController, photo: String) -> Bool {
        waitFor {
            loupe.currentPresentedPhotoForTesting == photo
                && loupe.lastPresentedScale == DecodeLadder.fullScale
                && loupe.frameScaleForTesting == Double(DecodeLadder.fullScale)
        }
    }

    // MARK: - ① 顶栏：7 → 8，仍是最后一个按钮决定预算线

    func testTopBarAddsAnEighthButtonBesideBackgroundAndKeepsTheTrailingEdge() {
        let bar = makeBar()
        let buttons = bar.toolButtonsForTesting
        let autoAll = bar.autoAllButtonView
        let background = bar.backgroundButtonView

        XCTAssertEqual(buttons.count, 8, "顶栏按钮从 7 个变成 8 个")
        XCTAssertTrue(buttons.contains { $0 === autoAll })
        // 482（用户 2026-11-21）：顶栏那颗从「全部自动」改名成「自动调整」，与右键/编辑菜单同名。
        XCTAssertEqual(autoAll.title, "自动调整")
        XCTAssertEqual(autoAll.image?.accessibilityDescription, "自动调整")

        // 仍在「排序 |」那一组里、与后台并列；后台仍是最后一个按钮。
        XCTAssertEqual(autoAll.frame.maxX + TopBarView.itemGap, background.frame.minX, accuracy: 0.001,
                       "全部自动 与 后台 不是相邻的 itemGap")
        XCTAssertEqual(bar.controlsTrailingEdge, background.frame.maxX, accuracy: 0.001,
                       "预算线仍 = 最后一个按钮的右边缘")
        XCTAssertLessThan(autoAll.frame.maxX, bar.statusCluster.frame.minX, "按钮压到了状态簇")

        // 「同族」：同一个 ToolButton 的高度/字体/内边距；数值上图标足迹与后台差 1 pt。
        XCTAssertEqual(autoAll.frame.height, background.frame.height, accuracy: 0.001)
        XCTAssertEqual(autoAll.intrinsicContentSize.height, background.intrinsicContentSize.height)
        XCTAssertEqual(autoAll.font, background.font)
        XCTAssertEqual(autoAll.contentTintColor, background.contentTintColor)
        let autoIcon = try! XCTUnwrap(autoAll.image).size
        let backgroundIcon = try! XCTUnwrap(background.image).size
        XCTAssertEqual(autoIcon.width, backgroundIcon.width, accuracy: 1.0,
                       "新按钮的图标足迹与「后台」同族（±1 pt）")

        let autoWidth = autoAll.intrinsicContentSize.width
        let backgroundWidth = background.intrinsicContentSize.width
        let font = try! XCTUnwrap(autoAll.font)
        let textDelta = (("自动调整" as NSString).size(withAttributes: [.font: font]).width
                         - ("后台" as NSString).size(withAttributes: [.font: font]).width)
        // 同一套 padding + 图标宽度 + 6 pt：宽度差就是文字差 + 图标差。
        XCTAssertEqual(autoWidth - backgroundWidth, textDelta + (autoIcon.width - backgroundIcon.width),
                       accuracy: 1.0, "宽度公式与「后台」同族（不是另一套尺寸）")
        print("490① buttons=\(buttons.count) autoW=\(String(format: "%.2f", autoWidth))"
              + " backgroundW=\(String(format: "%.2f", backgroundWidth))"
              + " iconW=\(autoIcon.width)/\(backgroundIcon.width)"
              + " trailing=\(String(format: "%.2f", bar.controlsTrailingEdge))")

        // 点击真的走到那一个回调。
        var clicks = 0
        bar.onAutoAll = { clicks += 1 }
        autoAll.performClick(nil)
        XCTAssertEqual(clicks, 1, "「全部自动」按钮没有接上动作")
    }

    // MARK: - ② 一次点击：黑电平 → 明暗 → 颜色，一条历史行

    func testAutoAllWritesEveryFieldOnceAndUndoRevertsInOneStep() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "490-all", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "490-all"), "the full rung never reached the canvas")

        // A real baseline row (a neutral document has no first snapshot to undo to), and a vibrance
        // the raise-only 自动颜色 must actually move.
        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit
        let historyBefore = session.history.count

        // The algorithm's own answer, staged exactly the way the composite stages it.
        var expected = before
        if let black = loupe.blackOffsetCandidate(), black != expected.light.blackOffset {
            expected.light.blackOffset = black
        }
        for _ in 0 ..< 4 {
            var passChanged = false
            if let plan = loupe.lightPlanCandidate(from: expected) {
                expected = plan.apply(to: expected)
                passChanged = true
            }
            if let color = loupe.colorCandidate(from: expected) {
                expected.color.vibrance = color.vibrance
                expected.color.saturation = color.saturation
                passChanged = true
            }
            if !passChanged { break }
        }

        XCTAssertTrue(loupe.autoAll(), "a settled full frame must produce a composite plan")
        XCTAssertEqual(session.history.count, historyBefore + 1,
                       "全部自动 must be one history row, not three")
        XCTAssertEqual(session.history.currentSnapshot?.label, "全部自动")

        XCTAssertEqual(session.edit.light.exposure, expected.light.exposure)
        XCTAssertEqual(session.edit.light.highlights, expected.light.highlights)
        XCTAssertEqual(session.edit.light.whites, expected.light.whites)
        XCTAssertEqual(session.edit.light.blacks, expected.light.blacks)
        XCTAssertEqual(session.edit.light.contrast, expected.light.contrast)
        XCTAssertEqual(session.edit.color.vibrance, expected.color.vibrance)
        XCTAssertEqual(session.edit.color.saturation, expected.color.saturation,
                       "498: 自动颜色 writes saturation too")
        XCTAssertEqual(session.edit, expected, "the committed document is the staged pipeline, field for field")
        XCTAssertNotEqual(session.edit, before, "全部自动 really moved the document")

        let metrics = try XCTUnwrap(loupe.lastAutoColorMetricsForTesting)
        XCTAssertGreaterThan(metrics.sampleCount, 0)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit, before, "one ⌘Z undoes the whole 全部自动")
        XCTAssertEqual(session.history.currentSnapshot?.label, "原照", "⌘Z stepped back to the baseline row")
    }

    // MARK: - ③ 幂等：已收敛时再点，文档不变、历史不增

    func testSecondAutoAllIsANoOp() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "490-idempotent", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "490-idempotent"))

        // A non-zero starting vibrance makes 自动颜色's first pass a real raise; the second pass must
        // still be a no-op (the measurement includes the boost the first pass wrote).
        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))

        XCTAssertTrue(loupe.autoAll())
        let settled = session.edit
        XCTAssertGreaterThan(settled.color.vibrance, 0, "the colour step really raised vibrance")
        XCTAssertGreaterThanOrEqual(loupe.lastAutoCompositePassCountForTesting, 1)
        XCTAssertLessThanOrEqual(loupe.lastAutoCompositePassCountForTesting, 4,
                                 "498 fixed point stays within four passes")
        print("498 PASSES · \(loupe.lastAutoCompositePassCountForTesting)")
        let history = session.history.count

        XCTAssertFalse(loupe.autoAll(), "a converged document must not be written again")
        XCTAssertEqual(session.edit, settled, "文档不变")
        XCTAssertEqual(session.history.count, history, "历史不增")
        XCTAssertEqual(loupe.lastAutoColorNoOpReasonForTesting, .alreadySaturated,
                       "498: 0+0 says why instead of doing nothing silently")
    }

    // MARK: - ④ 自动颜色的独立入口

    func testAutoColorAloneWritesBothColorSlidersWithItsOwnRow() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "490-color", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "490-color"))

        // Make the starting vibrance a value the (raise-only) plan must move from, so this test
        // measures the write and not a 0 → 0 no-op.
        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))

        let before = session.edit
        let historyBefore = session.history.count
        _ = loupe.autoColor()
        let measured = try XCTUnwrap(loupe.lastAutoColorMetricsForTesting)
        let plan = try XCTUnwrap(loupe.lastAutoColorPlanForTesting)

        XCTAssertGreaterThan(measured.sampleCount, 0)
        XCTAssertEqual(session.edit.color.vibrance, plan.vibrance, "vibrance = 498 plan")
        XCTAssertEqual(session.edit.color.saturation, plan.saturation, "saturation = 498 plan")
        XCTAssertEqual(session.edit.light, before.light, "自动颜色 must not touch 明暗")
        XCTAssertEqual(session.edit.light.blackOffset, before.light.blackOffset,
                       "自动颜色 must not touch 黑电平")
        XCTAssertEqual(session.history.count, historyBefore + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动颜色")

        let settled = session.edit
        XCTAssertNil(loupe.autoColor(), "converged ⇒ nil")
        XCTAssertEqual(session.history.count, historyBefore + 1)
        XCTAssertEqual(session.edit, settled)
    }
}
