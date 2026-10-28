import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-27 — 裁切搬进「变换」工作区，第一张卡就是裁切。
///
/// 用户的原话：
///
///   > 将裁切下拉菜单中的相关功能，移动到右侧第二栏「变换」，变换包括裁切、旋转等功能；点开变换窗口，
///   > **第一个卡片是裁切**；点按**直角尺图标**后进入裁切模式，出现裁切框；长宽比选择以及值的输入，
///   > UI 类似于调节栏。
///
/// 这份文件钉的是**渲染出来的东西**，不钉愿望：
///
///   1. 卡片清单里**第一张 = 裁切**（`InspectorCardsProbe` 报的 id/标题 + 卡片自己的 frame）；
///   2. 直角尺按钮点一下 = 进裁切（`isActive` **并且 overlay 真的在屏幕上**，复用的是 072 的真挂载），
///      再点 = 出去；
///   3. 比例：六个预设 + 自定义（输 `5:4` → 文档 `AspectLock.custom(1.25)`）；
///   4. 角度：真的往那个数值框里敲 `1.5` → 应用后 `rotationDegrees == 1.5`；
///   5. 三片开关的激活色 = 系统强调色（像素），应用/取消在非裁切模式下 `isEnabled == false`；
///   6. 300 / 330 / 364 pt 三个宽度下每行都不重叠、不出卡片（每行的 frame 打出来）。
///
/// 每一条都从**同一个** `InspectorView` 进：面板是宿主在真窗口里的那个，`loupe` 是真的
/// `LoupeController`（点按钮 → 真工具 → 真 overlay），不是替身。
@MainActor
final class TransformPanelTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-transform-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 1. 一张表：变换的卡片清单，第一张是裁切

    func testTheTransformWorkspaceShowsTheCropCardFirst() throws {
        XCTAssertEqual(InspectorWorkspace.transform.cards, [.crop, .angle],
                       "变换工作区认领裁切 + 角度两张卡（唯一一张「工作区 → 卡片」表）")
        XCTAssertEqual(InspectorView.cardTitles(in: .transform), ["裁切", "角度"],
                       "卡片清单的第一张必须是裁切，第二张是角度")
        XCTAssertEqual(InspectorView.sections(in: .transform).map(\.rawValue), ["crop", "angle"])
        // 调整工作区不受影响：裁切是它自己的工作区的卡片。
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("裁切"))
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("角度"))
        // 077（2026-10-28）：历史记录排在枚举末尾；蒙版仍是它前面最后一张参数卡
        // （`DecoderModelCardTests` 也钉这一条）。
        XCTAssertEqual(InspectorView.sectionTitles.suffix(2), ["蒙版", "历史记录"])

        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        XCTAssertEqual(panel.cards.cardTitles, ["裁切", "角度"])
        let card = try XCTUnwrap(panel.row(CropCardID.card), "裁切卡自己没有 frame")
        let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard), "角度卡自己没有 frame")
        print(String(format: "CARD · 变换第一张 = %@ · frame (%.1f, %.1f, %.1f×%.1f)",
                     panel.cards.cardTitles.first ?? "-",
                     card.minX, card.minY, card.width, card.height))
        XCTAssertGreaterThan(card.width, 200, "卡片比面板还窄")
        XCTAssertGreaterThan(card.height, 60, "裁切卡（宽高比 + 底部行）不该只有 \(card.height) pt")
        XCTAssertGreaterThan(angleCard.height, 100, "角度卡（三节）不该只有 \(angleCard.height) pt")
        XCTAssertGreaterThan(angleCard.minY, card.maxY, "角度卡必须在裁切卡之后")
        // 卡在滚动内容里、在直方图下方 —— 它是一张普通的卡。
        XCTAssertLessThan(panel.histogramPlot.maxY, card.minY)
    }

    // MARK: - 2. 进变换就有裁切框；卡头右边没有按钮

    func testEnteringTransformProvidesTheCropFrameAndTheCardHeaderHasNoButton() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let loupe = root.loupeController
        let inspector = root.inspectorHost

        root.inspectorWorkspaces.select(.transform)
        pump(0.2)

        // 086: the workspace is the entry — no ruler button to press first.
        XCTAssertTrue(loupe.isCropToolActive, "086: 切到「变换」= 进入裁切模式")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "086: 进入后选框在屏上")
        XCTAssertFalse(inspector.isEditingGated, "「变换」工作区里侧栏必须还是活的")

        // The card title's accessory is gone: no CropModeButton anywhere, and the source has no host.
        XCTAssertTrue(Self.views(of: "CropModeButton", in: inspector).isEmpty,
                      "086: 卡片名右边不许再有直角尺按钮")
        let source = try String(contentsOf: Self.source("TransformPanel.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("CropModeButtonHost"),
                       "086: CropModeButtonHost / CropModeButton 应从 TransformPanel 删除")
        // No button in the card's title band either (the card probe gives the card's real frame).
        let card = try XCTUnwrap(Self.rowProbe(CropCardID.card, in: inspector),
                                 "裁切卡自己没有 frame")
        let cardRect = card.convert(card.bounds, to: inspector)
        let titleBand = NSRect(x: cardRect.minX, y: cardRect.minY,
                               width: cardRect.width, height: 26)
        let buttonsInTitle = Self.allButtons(in: inspector)
            .filter { titleBand.intersects($0.convert($0.bounds, to: inspector)) }
        XCTAssertTrue(buttonsInTitle.isEmpty,
                      "086: 卡片名那一行右边不该有任何按钮（\(buttonsInTitle.count) 个）")

        // 082 keeps its leaving half: switching away from 变换 cancels the draft and takes the frame
        // with it; switching back re-enters idempotently (no double toggle).
        for round in 1...2 {
            root.inspectorWorkspaces.select(.adjust)
            pump(0.1)
            XCTAssertFalse(loupe.isCropToolActive, "086/082: 第 \(round) 次切出变换 = 退出裁切模式")
            root.inspectorWorkspaces.select(.transform)
            pump(0.1)
            XCTAssertTrue(loupe.isCropToolActive, "086: 第 \(round) 次切回仍是裁切模式（幂等）")
            XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "086: 第 \(round) 次切回选框在屏上")
            XCTAssertFalse(loupe.enterCropToolIfNeeded(), "086: 已经 active 时幂等入口不做任何事")
        }
        XCTAssertTrue(loupe.isCropToolActive)
    }

    /// ⌘R 仍然是那个动词：菜单里只剩一行，但它进/出裁切的路径和卡头的直角尺是**同一个**。
    func testCommandRStillTogglesTheCropMode() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let loupe = editor.rootView.loupeController

        let menu = MainMenu.build()
        let transform = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "变换" })
        XCTAssertEqual(transform.items.map(\.title),
                       ["裁切", "逆时针旋转 90°", "顺时针旋转 90°"],
                       "菜单里搬走的功能都删掉了，只剩 ⌘R + P0-10 的两个旋转")
        let item = try XCTUnwrap(transform.items.first)
        XCTAssertEqual(item.keyEquivalent, "r")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)

        editor.toggleCropAction(nil)
        pump(0.2)
        XCTAssertTrue(loupe.isCropToolActive, "⌘R 进不去裁切")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "⌘R 进了裁切，overlay 却没上屏")
        editor.toggleCropAction(nil)
        pump(0.2)
        XCTAssertFalse(loupe.isCropToolActive, "⌘R 出不来裁切")
        print("⌘R · in → \(loupe.isCropToolActive) → out · menu rows \(transform.items.map(\.title))")
    }

    // MARK: - 3. 比例：六个预设 + 自定义 5:4

    func testTheSixPresetsAndACustomRatioReachTheDocument() throws {
        XCTAssertEqual(CropAspectRow.items, CropAspectPreset.allCases, "比例行就是那张预设表")
        XCTAssertEqual(CropAspectRow.items.map(\.displayName), ["原始", "1:1", "4:3", "3:2", "16:9", "自由"])
        XCTAssertEqual(CropAspectRow.customTitle, "自定义…")

        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        XCTAssertTrue(loupe.beginCropTool())
        pump(0.1)

        // 六个预设逐个点：每一个都把草稿的比例锁设成它自己（文档不动）。
        var codes: [String] = []
        for preset in CropAspectRow.items {
            loupe.cropTool.setAspect(preset)
            codes.append(loupe.cropTool.draft.lock.code)
            XCTAssertEqual(CropAspectRow.title(for: loupe.cropTool), preset.displayName)
        }
        print("ASPECT presets · \(zip(CropAspectRow.items, codes).map { "\($0.0.displayName)→\($0.1)" })")
        XCTAssertEqual(Set(codes).count, 6, "六个预设不能有两个落到同一个锁上")
        XCTAssertEqual(session.edit.geometry.aspectLock, .original, "比例是草稿的事，应用前不碰文档")

        // 自定义…：真面板、真输入、真提交。
        let window = try XCTUnwrap(CropCardHost.shared.window ?? editor.window)
        XCTAssertTrue(CropRatioPanels.shared.present(for: loupe.cropTool, initial: "4:3"))
        pump(0.1)
        let prompt = try XCTUnwrap(CropRatioPanels.shared.prompt, "自定义比例面板没有出现")
        XCTAssertLessThanOrEqual(abs(prompt.frame.midX - window.frame.midX), 1,
                                 "⑨：面板必须居中于窗口（Δx \(prompt.frame.midX - window.frame.midX)）")
        XCTAssertLessThanOrEqual(abs(prompt.frame.midY - window.frame.midY), 1,
                                 "⑨：面板必须居中于窗口（Δy \(prompt.frame.midY - window.frame.midY)）")

        let field = try XCTUnwrap(prompt.firstResponder as? NSTextView, "输入框没有焦点")
        field.string = "5:4"
        prompt.performCommitForTesting()
        pump(0.1)
        XCTAssertNil(CropRatioPanels.shared.prompt, "提交后面板要消失")
        if case .custom(let ratio) = loupe.cropTool.draft.lock {
            XCTAssertEqual(ratio, 5.0 / 4.0, accuracy: 1e-9, "输入 5:4 应该锁成 1.25")
        } else {
            XCTFail("自定义比例没有进草稿的锁：\(loupe.cropTool.draft.lock)")
        }
        XCTAssertEqual(CropAspectRow.title(for: loupe.cropTool), "自定义 1.25:1",
                       "比例行要说出它现在是一个自定义比例")

        // 应用：那一个锁原样进文档。
        XCTAssertTrue(loupe.applyCropTool())
        pump(0.1)
        XCTAssertEqual(session.edit.geometry.aspectLock, .custom(5.0 / 4.0),
                       "文档里存的不是 custom(5,4)：\(session.edit.geometry.aspectLock.code)")
        print("ASPECT custom · 5:4 → draft \(loupe.cropTool.draft.lock.code) → document "
              + "\(session.edit.geometry.aspectLock.code) · history \(session.history.count)")

        // 非法输入：一声响，什么都没写。
        XCTAssertTrue(loupe.beginCropTool())
        pump(0.1)
        let lockBefore = loupe.cropTool.draft.lock
        XCTAssertFalse(CropRatioPanels.shared.commit("0:0"), "0:0 必须被拒绝")
        XCTAssertEqual(loupe.cropTool.draft.lock, lockBefore, "被拒的输入不许改比例")
        loupe.cancelCropTool()
    }

    // MARK: - 4. 角度：数值框里敲 1.5 → 应用后 rotationDegrees == 1.5

    func testTypingAnAngleIntoTheRowReachesTheDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        pump(0.2)
        // 082: 切到「变换」就已经进了裁切模式，不需要再点一次。
        XCTAssertTrue(loupe.isCropToolActive, "082: 切到「变换」= 自动进入裁切")
        pump(0.2)
        let historyBefore = session.history.snapshots.count

        let inspector = editor.rootView.inspectorHost
        let field = try XCTUnwrap(Self.views(of: "NumberTextField", in: inspector)
                                    .first as? NSTextField,
                                  "裁切卡里没有角度那一行的数值框")
        XCTAssertTrue(window.makeFirstResponder(field), "数值框必须能成为第一响应者")
        let editorView = try XCTUnwrap(field.currentEditor() as? NSTextView, "没有 field editor")

        // 「第一次按键清空」是 052 的规则；这里先选好整段，再一次性插入（一次输入 = 一次改草稿）。
        editorView.setSelectedRange(NSRange(location: 0,
                                           length: (editorView.string as NSString).length))
        editorView.insertText("1.5", replacementRange: editorView.selectedRange())
        editorView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        pump(0.15)

        XCTAssertEqual(loupe.cropTool.draft.straighten, 1.5, accuracy: 1e-9,
                       "敲进去的 1.5 没有进草稿")
        // 087: 转动 is live — one typed value writes the document and commits one row.
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 1.5, accuracy: 1e-9,
                       "转动已经实时，文档的角度也该是 1.5：\(session.edit.geometry.rotationDegrees)")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "一次输入 = 一条历史（松手 / 回车）")
        print("ANGLE · typed 1.5 → live document rotationDegrees "
              + "\(session.edit.geometry.rotationDegrees) · history +\(session.history.snapshots.count - historyBefore)")
    }

    // MARK: - 5. 九宫格开关颜色；五个控件永不置灰

    func testTheGridSwitchTurnsAccentBlueAndTheControlsStayEnabled() throws {
        // 结构那一半：颜色只有一个出口（`CropChip.fill(on:)`），而且是系统强调色。
        let source = try String(contentsOf: Self.source("TransformPanel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static func fill(on: Bool) -> Color { on ? Color.accentColor : Color.clear }"),
                      "开关的颜色只能来自 CropChip.fill(on:)，而且只能是 Color.accentColor")

        // 像素那一半：渲染**这个开关本身**再采中心点（060 的老办法）。087 起水平/垂直是裸图标，
        // 它们的 accent 语义由 `CropPanelTests` 的镜像用例钉住。
        let accent = Self.systemAccent
        guard accent.b >= accent.r else {
            throw XCTSkip("系统强调色不是蓝的（\(accent)）—— 跟随系统，非蓝主题下这条无法断言")
        }
        var table: [String] = []
        for title in ["九宫格"] {
            guard let onPixels = Self.render(CropChip(title: title, on: true) {}) else {
                throw XCTSkip("ImageRenderer 拿不到 CGImage（本机没有可用的离屏图形上下文）")
            }
            let on = try XCTUnwrap(Self.centreColour(onPixels), "\(title) 的激活态没有不透明像素")
            XCTAssertLessThanOrEqual(abs(on.r - accent.r), 24, "\(title) 激活色 R：\(on) vs \(accent)")
            XCTAssertLessThanOrEqual(abs(on.g - accent.g), 24, "\(title) 激活色 G：\(on) vs \(accent)")
            XCTAssertLessThanOrEqual(abs(on.b - accent.b), 24, "\(title) 激活色 B：\(on) vs \(accent)")

            let offPixels = try XCTUnwrap(Self.render(CropChip(title: title, on: false) {}))
            let off = try XCTUnwrap(Self.centreColour(offPixels), "\(title) 的关闭态没有不透明像素")
            let distance = abs(on.r - off.r) + abs(on.g - off.g) + abs(on.b - off.b)
            XCTAssertGreaterThanOrEqual(distance, 100, "\(title)：开与关必须一眼看得出不同（\(on) vs \(off)）")
            table.append("\(title) on \(on) / off \(off)")
        }
        print("CHIP colour · accent \(accent) · " + table.joined(separator: " · "))

        // 086: even with **no loupe at all** (the worst case: `tool == nil`) the five controls are not
        // greyed out. The probe reads SwiftUI's resolved `isEnabled`, so a stray `.disabled` goes red.
        DetailRowEnabledLog.shared.reset()
        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }
        try waitFor(panel) { _ in DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe) != nil }
        let keys = ["宽高比", "转动", "九宫格", CropApplyRow.applyProbe, CropApplyRow.cancelProbe]
        for key in keys {
            _ = try waitFor(panel) { _ in DetailRowEnabledLog.shared.value(key) != nil }
        }
        for key in keys {
            XCTAssertEqual(DetailRowEnabledLog.shared.value(key), true,
                           "086: 「\(key)」不许变灰（tool == nil 时也一样）")
        }
        XCTAssertNil(panel.host.rootView.loupe, "这个宿主没有 loupe —— 正好是「tool == nil」那一档")
        print("ENABLED · " + keys.map {
            "\($0)=\(String(describing: DetailRowEnabledLog.shared.value($0)))"
        }.joined(separator: " · "))
    }

    // MARK: - 4. 宽高比：标题 · 选单 · ⇄ 同一行

    func testTheAspectTitlePickerAndSwapShareOneLineAt244Points() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 300, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        // 086: the second 「裁切」 is now 「宽高比」; the card title itself is untouched.
        XCTAssertEqual(CropSection.crop.title, "宽高比")
        XCTAssertEqual(InspectorView.Section.crop.title, "裁切", "卡片名仍是「裁切」")
        XCTAssertEqual(CropSection.displayOrder.map(\.title), ["宽高比", "转动", "旋转", "镜像"])
        XCTAssertEqual(CropSection.angleCardOrder.map(\.title), ["转动", "旋转", "镜像"])

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let contentWidth = card.width - 2 * WorkspaceLayout.cardInsetH
        XCTAssertGreaterThanOrEqual(contentWidth, 244 - 0.5, "244 pt 内容宽是这张卡的验收宽度")
        let title = try XCTUnwrap(panel.row(CropCardID.section(.crop)),
                                  "「宽高比」小标题没有画出来")
        let menu = try XCTUnwrap(panel.row(CropAspectRow.menuProbeID), "比例选单没有画出来")
        let swap = try XCTUnwrap(panel.row(CropAspectRow.swapProbeID), "⇄ 交换没有画出来")

        for (name, rect) in [("选单", menu), ("⇄", swap)] {
            XCTAssertLessThanOrEqual(abs(rect.midY - title.midY), 1,
                                     "086: 「\(name)」必须和「宽高比」同一行（Δy \(rect.midY - title.midY)）")
            XCTAssertGreaterThan(rect.minX, title.minX, "086: 「\(name)」在标题右侧")
            XCTAssertGreaterThanOrEqual(rect.minX, card.minX + WorkspaceLayout.cardInsetH - 0.5)
            XCTAssertLessThanOrEqual(rect.maxX, card.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                     "086: 「\(name)」出了卡片右边")
        }
        XCTAssertGreaterThanOrEqual(swap.width, CropAspectRow.swapHitSize - 0.5,
                                    "086: ⇄ 的命中区至少 18 pt 宽（实测 \(swap.width)）")
        XCTAssertGreaterThanOrEqual(swap.height, CropAspectRow.swapHitSize - 0.5,
                                    "086: ⇄ 的命中区至少 18 pt 高（实测 \(swap.height)）")

        let source = try String(contentsOf: Self.source("TransformPanel.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Text(\"比例\")"), "086: 这一行不再出现「比例」这个词")
        print(String(format: "ASPECT ROW · title %@ · menu %@ · swap %@ · content %.1f pt",
                     NSStringFromRect(title), NSStringFromRect(menu), NSStringFromRect(swap), contentWidth))
    }

    // MARK: - 5. 九宫格 / 应用 / 取消 = 卡片最后一行

    func testTheGridApplyCancelRowIsTheCardsLastRowAndApplyCancelAreRightAligned() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 330, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard))
        XCTAssertGreaterThan(angleCard.minY, card.maxY, "087: 角度卡在裁切卡之后")
        let grid = try XCTUnwrap(panel.row(CropCardID.grid), "九宫格没有画出来")
        let apply = try XCTUnwrap(panel.row(CropCardID.apply), "应用 / 取消没有画出来")
        XCTAssertLessThanOrEqual(abs(grid.midY - apply.midY), 1,
                                 "086: 九宫格与应用/取消必须同一行（Δy \(grid.midY - apply.midY)）")
        XCTAssertGreaterThan(apply.minX, grid.maxX, "086: 应用/取消在九宫格右边")
        XCTAssertLessThanOrEqual(abs(apply.maxX - (card.maxX - WorkspaceLayout.cardInsetH)), 1,
                                 "086: 应用/取消右对齐到卡片内容右边")

        // Nothing is drawn below the bottom row. The bottom row's own probes (grid + the apply/cancel
        // chips) are measured against each other above, so they are excluded here — including them made
        // this assertion compare the row with itself.
        let bottomIDs: Set<String> = [CropCardID.grid, CropCardID.apply]
        let rows = panel.probes
            .filter { $0.rowID != CropCardID.card && $0.rowID != CropCardID.angleCard }
            .filter { !bottomIDs.contains($0.rowID) }
            .map { ($0.rowID, $0.convert($0.bounds, to: panel.host)) }
            // 087: only the crop card — the angle card legitimately sits below this one.
            .filter { $0.1.minY >= card.minY - 1 && $0.1.maxY <= card.maxY + 1 }
        let bottomTop = min(grid.minY, apply.minY)
        let below = rows.filter { $0.1.minY > bottomTop + 0.5 }
        XCTAssertTrue(below.isEmpty,
                      "086: 底部行之下还有控件（\(below.map(\.0))）")
        let bottomMax = max(grid.maxY, apply.maxY)
        let lowestOther = rows.map(\.1.maxY).max() ?? 0
        XCTAssertLessThanOrEqual(lowestOther, bottomMax + 1,
                                 "086: 最后一行就是九宫格/应用/取消（其它内容最低 \(lowestOther) vs 底部行 \(bottomMax)）")
        print(String(format: "BOTTOM ROW · grid %@ · apply %@ · card %@",
                     NSStringFromRect(grid), NSStringFromRect(apply), NSStringFromRect(card)))
    }

    // MARK: - 6. 三个宽度：每行都不重叠、不出卡片

    func testEveryRowFitsInsideTheCardAt300And330And364() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        var report: [String] = []
        for width in [300 as CGFloat, 330, WorkspaceLayout.inspectorWidthMax] {
            XCTAssertEqual(WorkspaceLayout.inspectorWidthMax, 364, "三个宽度是 300 / 330 / 364")
            let panel = try host(width: width, session: session, loupe: loupe)
            defer { panel.window.contentView = nil }
            panel.state.select(.transform)
            try waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

            let card = try XCTUnwrap(panel.row(CropCardID.card), "\(width) pt：没有卡片 frame")
            let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard), "\(width) pt：没有角度卡 frame")
            // 087: the two cards own two row sets. The crop card is 宽高比 + 底部行; the angle card is
            // 转动 / 旋转 / 镜像.
            let cardRows: [(String, CGRect, CGRect)] = [
                (CropCardID.aspect, card),
                (CropCardID.apply, card),
                (CropCardID.angle, angleCard),
                (CropCardID.turn, angleCard),
                (CropCardID.mirror, angleCard),
            ].compactMap { id, owner in panel.row(id).map { (id, $0, owner) } }
            XCTAssertEqual(cardRows.count, 5, "\(width) pt：五行里少了（\(cardRows.map(\.0))）")
            XCTAssertGreaterThan(angleCard.minY, card.maxY,
                                 "\(width) pt：角度卡必须在裁切卡之后")

            // 每行都在自己的卡片里，而且有宽度。
            for (id, frame, owner) in cardRows {
                XCTAssertGreaterThan(frame.width, 60, "\(width) pt：\(id) 只剩 \(frame.width) pt")
                XCTAssertGreaterThanOrEqual(frame.minX, owner.minX + WorkspaceLayout.cardInsetH - 0.5,
                                            "\(width) pt：\(id) 出了卡片左边（\(frame.minX) vs \(owner.minX)）")
                XCTAssertLessThanOrEqual(frame.maxX, owner.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                         "\(width) pt：\(id) 出了卡片右边（\(frame.maxX) vs \(owner.maxX)）")
            }
            // 不重叠：同一张卡内按 y 排好之后，上面那一行的底不能压到下面那一行的顶。
            for owner in [card, angleCard] {
                let ordered = cardRows.filter { $0.2 == owner }.sorted { $0.1.minY < $1.1.minY }
                for (a, b) in zip(ordered, ordered.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.1.maxY, b.1.minY + 0.5,
                                             "\(width) pt：\(a.0) 与 \(b.0) 重叠（\(a.1) / \(b.1)）")
                }
                let first = try XCTUnwrap(ordered.first?.1), last = try XCTUnwrap(ordered.last?.1)
                XCTAssertLessThanOrEqual(last.maxY, owner.maxY - WorkspaceLayout.cardInsetV + 0.5,
                                         "\(width) pt：最后一行出了卡片底边")
                XCTAssertGreaterThan(first.minY, owner.minY)
            }

            let rows = cardRows.map { ($0.0, $0.1) }
            let frames = rows
                .map { String(format: "%@(%.1f, %.1f, %.1f×%.1f)",
                              $0.0, $0.1.minX, $0.1.minY, $0.1.width, $0.1.height) }
                .joined(separator: " ")
            report.append("\(Int(width)) pt · card \(String(format: "%.1f×%.1f", card.width, card.height)) · \(frames)")
            print("ROWS @\(Int(width)) · \(frames)")
        }
        print("ROWS · " + report.joined(separator: " ‖ "))
        loupe.cancelCropTool()
    }

    // MARK: - harness

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState

        var cards: InspectorCardsProbe {
            Self.views(of: "InspectorCardsProbe", in: host)
                .compactMap { $0 as? InspectorCardsProbe }.first ?? InspectorCardsProbe(frame: .zero)
        }

        var histogramPlot: CGRect {
            Self.views(of: "HistogramCardView", in: host).first
                .map { $0.convert($0.bounds, to: host) } ?? .null
        }

        /// Every crop-card probe currently in the tree.
        var probes: [CropRowProbe] {
            Self.views(of: "CropRowProbe", in: host).compactMap { $0 as? CropRowProbe }
        }

        /// One row's frame, in the panel's coordinates (every probe is reported by the row it backs).
        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        static func views(of className: String, in root: NSView) -> [NSView] {
            var found: [NSView] = []
            if String(describing: type(of: root)) == className { found.append(root) }
            for sub in root.subviews { found += views(of: className, in: sub) }
            return found
        }
    }

    private func host(width: CGFloat, height: CGFloat = 900,
                      session: CatalogSession? = nil,
                      loupe: LoupeController? = nil) throws -> Panel {
        _ = NSApplication.shared
        let session = session ?? CatalogSession()
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                         workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.4)
        host.layoutSubtreeIfNeeded()
        return Panel(host: host, window: window, state: state)
    }

    /// The host above has no loupe — used to prove the card degrades to "everything grey" instead of
    /// pretending it can crop.
    @discardableResult
    private func waitFor(_ panel: Panel, until predicate: (Panel) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            panel.host.layoutSubtreeIfNeeded()
            if predicate(panel) { return true }
            pump(0.05)
        }
        panel.host.layoutSubtreeIfNeeded()
        return predicate(panel)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Poll a plain predicate (the editor harness has no `Panel` to hand to `waitFor`).
    private func waitUntil(_ timeout: TimeInterval = 2, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            pump(0.05)
        }
        return predicate()
    }

    // MARK: - finding the shipped controls

    /// The probe a row reports itself through (the card's own frame included).
    private static func rowProbe(_ id: String, in root: NSView) -> CropRowProbe? {
        var found: CropRowProbe?
        func walk(_ view: NSView) {
            if let probe = view as? CropRowProbe, probe.rowID == id { found = probe }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    /// All `NSButton` leaves (used for 「卡片名右边没有按钮」: no exact class name filter).
    private static func allButtons(in root: NSView) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { found.append(button) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    private static func views(of className: String, in root: NSView) -> [NSView] {
        var found: [NSView] = []
        if String(describing: type(of: root)) == className { found.append(root) }
        for sub in root.subviews { found += views(of: className, in: sub) }
        return found
    }

    private static func frameRect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .null }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - pixel helpers (060's toolbox)

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/\(name)")
    }

    private static var systemAccent: RGB {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return RGB(r: Int((color.redComponent * 255).rounded()),
                   g: Int((color.greenComponent * 255).rounded()),
                   b: Int((color.blueComponent * 255).rounded()))
    }

    private static func render<V: View>(_ view: V) -> Pixels? {
        let renderer = ImageRenderer(content: view.padding(3))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        guard width > 4, height > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    /// The modal colour of the middle band of the render — a chip's fill, not its glyph.
    private static func centreColour(_ pixels: Pixels) -> RGB? {
        let band = (pixels.height / 4) ..< (pixels.height * 3 / 4)
        var histogram: [Int: Int] = [:]
        for y in band {
            for x in 0 ..< pixels.width {
                let i = (y * pixels.width + x) * 4
                guard Int(pixels.bytes[i + 3]) > 200 else { continue }
                let r = Int(pixels.bytes[i]), g = Int(pixels.bytes[i + 1]), b = Int(pixels.bytes[i + 2])
                histogram[(r << 16) | (g << 8) | b, default: 0] += 1
            }
        }
        guard let best = histogram.max(by: { $0.value < $1.value }) else { return nil }
        let packed = best.key
        return RGB(r: (packed >> 16) & 0xFF, g: (packed >> 8) & 0xFF, b: packed & 0xFF)
    }
}
