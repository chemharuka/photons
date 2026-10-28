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
        XCTAssertEqual(InspectorWorkspace.transform.cards, [.crop],
                       "变换工作区只认领裁切卡（唯一一张「工作区 → 卡片」表）")
        XCTAssertEqual(InspectorView.cardTitles(in: .transform), ["裁切"],
                       "卡片清单的第一张（今天也是唯一一张）必须是裁切")
        XCTAssertEqual(InspectorView.sections(in: .transform).map(\.rawValue), ["crop"])
        // 调整工作区不受影响：裁切是它自己的工作区的卡片。
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("裁切"))
        // 077（2026-10-28）：历史记录排在枚举末尾；蒙版仍是它前面最后一张参数卡
        // （`DecoderModelCardTests` 也钉这一条）。
        XCTAssertEqual(InspectorView.sectionTitles.suffix(2), ["蒙版", "历史记录"])

        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop"] }

        XCTAssertEqual(panel.cards.cardTitles, ["裁切"])
        let card = try XCTUnwrap(panel.row(CropCardID.card), "裁切卡自己没有 frame")
        print(String(format: "CARD · 变换第一张 = %@ · frame (%.1f, %.1f, %.1f×%.1f)",
                     panel.cards.cardTitles.first ?? "-",
                     card.minX, card.minY, card.width, card.height))
        XCTAssertGreaterThan(card.width, 200, "卡片比面板还窄")
        XCTAssertGreaterThan(card.height, 90, "四行卡片不该只有 \(card.height) pt")
        // 卡在滚动内容里、在直方图下方 —— 它是一张普通的卡。
        XCTAssertLessThan(panel.histogramPlot.maxY, card.minY)
    }

    // MARK: - 2. 直角尺：点一下进裁切（overlay 上屏），再点出去

    func testTheRulerButtonEntersAndLeavesCropModeWithTheOverlayOnScreen() throws {
        // A real editor: the real `InspectorHostingView`, the real canvas, the real overlay mount.
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let root = editor.rootView!
        let loupe = root.loupeController
        let inspector = root.inspectorHost
        root.inspectorWorkspaces.select(.transform)
        pump(0.2)

        let button = try XCTUnwrap(Self.cropModeButton(in: inspector),
                                  "卡头没有直角尺按钮（CropModeButton 不在树上）")
        XCTAssertTrue(button.isEnabled, "有照片时直角尺必须是活的")
        XCTAssertNotNil(button.image, "直角尺的 SF Symbol 在本机解析不出来")
        // 082 (用户口径): 「点击右侧裁切菜单后，自动进入裁切模式出现裁切选框」——切到「变换」**就是**
        // 进了裁切模式，所以直角尺这时已经是激活态，选框已经在屏上。
        XCTAssertTrue(loupe.isCropToolActive, "082: 切到「变换」= 自动进入裁切")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "082: 自动进入后选框在屏上")
        XCTAssertTrue(button.isOn, "082: 自动进入后直角尺是激活态")
        XCTAssertFalse(inspector.isEditingGated, "「变换」工作区里侧栏必须还是活的")

        // ① 再点一下直角尺 = 退出（显式开关保留），再点一下 = 重新进入并**框真的在屏幕上**。
        button.performClick(nil)
        pump(0.3)
        XCTAssertFalse(loupe.isCropToolActive, "082: 直角尺仍是「再点一次退出」的开关")
        XCTAssertFalse(loupe.isCropOverlayOnScreenForTesting, "退出后 overlay 不该还在屏幕上")
        DetailRowEnabledLog.shared.reset()
        button.performClick(nil)
        pump(0.3)
        XCTAssertTrue(loupe.isCropToolActive, "点直角尺没有进入裁切模式")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting,
                      "裁切模式进了，但 overlay 没有上屏（isHidden/superview/window/layout 有一样不成立）")
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertEqual(layout.corners.count, 4)
        XCTAssertTrue(button.isOn, "裁切模式下直角尺要有激活态")
        XCTAssertEqual(button.layer?.backgroundColor, NSColor.controlAccentColor.cgColor,
                       "激活态的底色 = 系统强调色")
        XCTAssertFalse(inspector.isEditingGated, "在「变换」里，裁切模式的侧栏必须还是活的")
        XCTAssertTrue(waitUntil { DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe) == true },
                      "裁切模式下「应用」必须是活的（草稿在现场）")
        XCTAssertTrue(waitUntil { DetailRowEnabledLog.shared.value(CropApplyRow.cancelProbe) == true },
                      "裁切模式下「取消」必须是活的")
        print(String(format: "RULER on · active=%@ · overlay on screen=%@ · frame %@ · gated=%@",
                     "\(loupe.isCropToolActive)", "\(loupe.isCropOverlayOnScreenForTesting)",
                     NSStringFromRect(Self.frameRect(layout)), "\(inspector.isEditingGated)"))

        // ② 再点一下 = 出去（等同 ⌘R：应用并离开）。
        button.performClick(nil)
        pump(0.3)
        XCTAssertFalse(loupe.isCropToolActive, "再点一次没有退出裁切模式")
        XCTAssertFalse(loupe.isCropOverlayOnScreenForTesting, "退出后 overlay 还在屏幕上")
        XCTAssertFalse(button.isOn, "退出后直角尺不能还是激活态")
        print("RULER off · active=\(loupe.isCropToolActive) · overlay on screen="
              + "\(loupe.isCropOverlayOnScreenForTesting)")

        // ③ §E1 没有被这张卡削掉：换回「调整」，裁切模式下侧栏整块闸住。
        root.inspectorWorkspaces.select(.adjust)
        pump(0.1)
        XCTAssertFalse(inspector.isEditingGated, "裁切没开，任何工作区都不该被闸")
        XCTAssertTrue(loupe.beginCropTool())
        pump(0.1)
        XCTAssertTrue(inspector.isEditingGated, "§E1：调整工作区在裁切模式下仍然整块闸住")
        loupe.cancelCropTool()
        pump(0.1)
        XCTAssertFalse(inspector.isEditingGated)
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
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 0, "草稿的角度不许直接写文档")

        XCTAssertTrue(loupe.applyCropTool())
        pump(0.1)
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 1.5, accuracy: 1e-9,
                       "应用后文档的角度不是 1.5：\(session.edit.geometry.rotationDegrees)")
        print("ANGLE · typed 1.5 → draft → document rotationDegrees "
              + "\(session.edit.geometry.rotationDegrees)")
    }

    // MARK: - 5. 三片开关：激活色 = 系统强调色；应用/取消在非裁切下置灰

    func testTheThreeSwitchesTurnAccentBlueAndApplyCancelAreGreyWithoutTheTool() throws {
        // 结构那一半：颜色只有一个出口（`CropChip.fill(on:)`），而且是系统强调色。
        let source = try String(contentsOf: Self.source("TransformPanel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static func fill(on: Bool) -> Color { on ? Color.accentColor : Color.clear }"),
                      "开关的颜色只能来自 CropChip.fill(on:)，而且只能是 Color.accentColor")

        // 像素那一半：渲染**这三个控件本身**再采中心点（060 的老办法）。
        let accent = Self.systemAccent
        guard accent.b >= accent.r else {
            throw XCTSkip("系统强调色不是蓝的（\(accent)）—— 跟随系统，非蓝主题下这条无法断言")
        }
        var table: [String] = []
        for title in ["水平", "垂直", "九宫格"] {
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

        // 非裁切下：比例/角度置灰，应用/取消 `isEnabled == false`，而且面板里没有草稿可写。
        DetailRowEnabledLog.shared.reset()
        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop"] }
        try waitFor(panel) { _ in DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe) != nil }

        XCTAssertEqual(DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe), false,
                       "裁切没开时「应用」必须是灰的")
        XCTAssertEqual(DetailRowEnabledLog.shared.value(CropApplyRow.cancelProbe), false,
                       "裁切没开时「取消」必须是灰的")
        XCTAssertNil(panel.host.rootView.loupe, "这个宿主没有 loupe：卡里的控件一律置灰")

        // 九宫格是纯视图态，随时可以按：它不跟着裁切模式置灰。
        print("GREY · apply=\(String(describing: DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe)))"
              + " · cancel=\(String(describing: DetailRowEnabledLog.shared.value(CropApplyRow.cancelProbe)))")
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
            try waitFor(panel) { $0.cards.cardIDs == ["crop"] }

            let card = try XCTUnwrap(panel.row(CropCardID.card), "\(width) pt：没有卡片 frame")
            // 082: four sections → five probe rows (裁切 / 角度 / 旋转 / 镜像 / 应用+取消). The section
            // titles have their own probes (`section.<title>`) and are measured in
            // `CropCardSectionsTests`; here it is the rows inside them.
            let rows = [CropCardID.aspect, CropCardID.angle, CropCardID.turn,
                        CropCardID.mirror, CropCardID.apply]
                .compactMap { id in panel.row(id).map { (id, $0) } }
            XCTAssertEqual(rows.count, 5, "\(width) pt：五行里少了（\(rows.map(\.0))）")

            // 每行都在卡片里，而且有宽度。
            for (id, frame) in rows {
                XCTAssertGreaterThan(frame.width, 60, "\(width) pt：\(id) 只剩 \(frame.width) pt")
                XCTAssertGreaterThanOrEqual(frame.minX, card.minX + WorkspaceLayout.cardInsetH - 0.5,
                                            "\(width) pt：\(id) 出了卡片左边（\(frame.minX) vs \(card.minX)）")
                XCTAssertLessThanOrEqual(frame.maxX, card.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                         "\(width) pt：\(id) 出了卡片右边（\(frame.maxX) vs \(card.maxX)）")
            }
            // 不重叠：按 y 排好之后，上面那一行的底不能压到下面那一行的顶。
            let ordered = rows.sorted { $0.1.minY < $1.1.minY }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                XCTAssertLessThanOrEqual(a.1.maxY, b.1.minY + 0.5,
                                         "\(width) pt：\(a.0) 与 \(b.0) 重叠（\(a.1) / \(b.1)）")
            }
            // 四行加起来必须还在卡片里（卡片高度够）。
            let first = try XCTUnwrap(ordered.first?.1), last = try XCTUnwrap(ordered.last?.1)
            XCTAssertLessThanOrEqual(last.maxY, card.maxY - WorkspaceLayout.cardInsetV + 0.5,
                                     "\(width) pt：最后一行出了卡片底边")
            XCTAssertGreaterThan(first.minY, card.minY)

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

        /// One row's frame, in the panel's coordinates (every probe is reported by the row it backs).
        func row(_ id: String) -> CGRect? {
            Self.views(of: "CropRowProbe", in: host)
                .compactMap { $0 as? CropRowProbe }
                .first { $0.rowID == id }
                .map { $0.convert($0.bounds, to: host) }
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

    private static func cropModeButton(in root: NSView) -> CropModeButton? {
        var found: CropModeButton?
        func walk(_ view: NSView) {
            if let button = view as? CropModeButton { found = button }
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
