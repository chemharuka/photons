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
        // 334 (user): 「现在有三个卡片：裁切，校正，变换」.
        XCTAssertEqual(InspectorWorkspace.transform.cards, [.crop, .transformCorrection, .angle],
                       "变换工作区认领裁切 / 校正 / 变换三张卡（唯一一张「工作区 → 卡片」表）")
        XCTAssertEqual(InspectorView.cardTitles(in: .transform), ["裁切", "校正", "变换"],
                       "三张卡，顺序就是用户的：裁切 → 校正 → 变换")
        XCTAssertEqual(InspectorView.sections(in: .transform).map(\.rawValue),
                       ["crop", "transformCorrection", "angle"])
        // 调整工作区不受影响：裁切是它自己的工作区的卡片。
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("裁切"))
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("变换"))
        // 077（2026-10-28）：历史记录排在枚举末尾；蒙版仍是它前面最后一张参数卡
        // （`DecoderModelCardTests` 也钉这一条）。
        XCTAssertEqual(InspectorView.sectionTitles.suffix(2), ["蒙版", "历史记录"])

        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }

        XCTAssertEqual(panel.cards.cardTitles, ["裁切", "校正", "变换"])
        let card = try XCTUnwrap(panel.row(CropCardID.card), "裁切卡自己没有 frame")
        let correctionCard = try XCTUnwrap(panel.row(CropCardID.correctionCard), "校正卡自己没有 frame")
        let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard), "变换卡自己没有 frame")
        print(String(format: "CARD · 变换三张 = %@ · frame (%.1f, %.1f, %.1f×%.1f)",
                     panel.cards.cardTitles.joined(separator: " / "),
                     card.minX, card.minY, card.width, card.height))
        XCTAssertGreaterThan(card.width, 200, "卡片比面板还窄")
        XCTAssertGreaterThan(card.height, 100, "裁切卡（宽高比 + 自定义 + 不出像素 + 九宫格 + 应用/取消）不该只有 \(card.height) pt")
        XCTAssertGreaterThan(correctionCard.height, 100, "校正卡（拉直 / 画线 / 两条透视）不该只有 \(correctionCard.height) pt")
        XCTAssertGreaterThan(angleCard.height, 60, "变换卡（旋转 / 镜像）不该只有 \(angleCard.height) pt")
        XCTAssertGreaterThan(correctionCard.minY, card.maxY, "校正卡必须在裁切卡之后")
        XCTAssertGreaterThan(angleCard.minY, correctionCard.maxY, "变换卡必须在最后")
        // 卡在滚动内容里、在直方图下方 —— 它是一张普通的卡。
        XCTAssertLessThan(panel.histogramPlot.maxY, card.minY)
    }

    // MARK: - 2. 进变换就有裁切框；卡头右边没有按钮

    func testEnteringTransformProvidesTheCropFrameAndTheCardHeaderHasNoButton() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        TestWindows.show(window)
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

    // MARK: - 3. 比例：四个常显按钮 + 原始 / 自由 + 自定义输入（334）

    func testTheFourRatioButtonsTheTwoExitsAndACustomRatioReachTheDocument() throws {
        // 334 (user): 「常见比例的按钮(1:1 4:3 16:9 2:3)都放出来，不要做成点击切换的模式」.
        XCTAssertEqual(RatioButton.allCases.map(\.title), ["1:1", "4:3", "16:9", "2:3"])
        XCTAssertEqual(RatioButton.allCases.map(\.identifier),
                       ["inspector.crop.ratio.1x1", "inspector.crop.ratio.4x3",
                        "inspector.crop.ratio.16x9", "inspector.crop.ratio.2x3"])
        // 2:3 没有 `AspectLock` 命名分支：它是显式的 custom，和键入的那一条同一个锁.
        // 2026-11-12 (user): 方向由**当前裁剪框**决定 —— 横构图点 2:3 落 3:2，竖构图落 2:3.
        XCTAssertEqual(RatioButton.allCases.map { $0.lock(landscape: true) },
                       [.square, .fourThree, .sixteenNine, .custom(3.0 / 2.0)])
        XCTAssertEqual(RatioButton.allCases.map { $0.lock(landscape: false) },
                       [.square, .fourThree, .sixteenNine, .custom(2.0 / 3.0)])

        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        pump(0.2)
        let inspector = editor.rootView.inspectorHost
        inspector.layoutSubtreeIfNeeded()
        XCTAssertTrue(loupe.isCropToolActive, "082: 切到「变换」= 进入裁切")

        // 四个按钮各点一次：草稿的锁就是它自己（文档不动）.
        var codes: [String] = []
        for button in RatioButton.allCases {
            let view = try XCTUnwrap(Self.button(RatioPresetButton.self, id: button.identifier,
                                                 in: inspector),
                                     "334: 比例按钮「\(button.title)」不在树上（\(button.identifier)）")
            // What this click must mean is read **before** the click: 2:3's direction depends on the
            // frame as it stands right now, and the click itself re-cuts that frame.
            let expected = button.lock(landscape: loupe.cropTool.frameIsLandscape())
            view.performClick(nil)
            pump(0.05)
            inspector.layoutSubtreeIfNeeded()
            XCTAssertEqual(loupe.cropTool.draft.lock.ratio, expected.ratio,
                           "334: 点「\(button.title)」必须把草稿锁设成 \(expected.code)")
            codes.append(loupe.cropTool.draft.lock.code)
        }
        XCTAssertEqual(Set(codes).count, 4, "334: 四个比例不能有两个落到同一个锁上")
        print("ASPECT buttons · \(zip(RatioButton.allCases, codes).map { "\($0.0.title)→\($0.1)" })")
        XCTAssertEqual(session.edit.geometry.aspectLock, .original, "比例是草稿的事，应用前不碰文档")
        XCTAssertNil(CropRatioPanels.shared.prompt, "104/334：比例不再有居中面板")

        // 原始 / 自由：两道解掉约束的门.
        let original = try XCTUnwrap(Self.button(RatioPresetButton.self, id: CropAspectRow.originalID,
                                                 in: inspector))
        original.performClick(nil)
        pump(0.05)
        XCTAssertEqual(loupe.cropTool.aspectPreset(), .original, "334: 「原始」= 传感器比例")
        let free = try XCTUnwrap(Self.button(RatioPresetButton.self, id: CropAspectRow.freeID,
                                             in: inspector))
        free.performClick(nil)
        pump(0.05)
        XCTAssertTrue(loupe.cropTool.isAspectFree, "334: 「自由」= 取消约束")

        // 自定义输入：`5:4` → custom(1.25)，卡片里那个常显字段就是入口.
        let field = try XCTUnwrap(Self.button(CustomRatioField.self, id: CropAspectRow.customID,
                                              in: inspector),
                                  "334: 自定义比例字段不在树上")
        field.stringValue = "5:4"
        field.commitForTesting()
        pump(0.1)
        guard case .custom(let ratio) = loupe.cropTool.draft.lock else {
            return XCTFail("334: 5:4 没有写进草稿的锁（\(loupe.cropTool.draft.lock)）")
        }
        XCTAssertEqual(ratio, 5.0 / 4.0, accuracy: 1e-9, "334: 5:4 = custom(1.25)")

        // 小数也收：`1.85`.
        field.stringValue = "1.85"
        field.commitForTesting()
        pump(0.1)
        XCTAssertEqual(loupe.cropTool.draft.lock, .custom(1.85), "334: 1.85 必须被接受")

        // 应用：那一个锁原样进文档.
        XCTAssertTrue(loupe.applyCropTool())
        pump(0.1)
        XCTAssertEqual(session.edit.geometry.aspectLock, .custom(1.85),
                       "文档里存的不是 custom(1.85)：\(session.edit.geometry.aspectLock.code)")

        // 非法输入：一声响，什么都没写.
        XCTAssertTrue(loupe.beginCropTool())
        pump(0.1)
        let lockBefore = loupe.cropTool.draft.lock
        // 应用把工作区送回了「调整」；再进一次变换，卡片才在树上.
        editor.rootView.inspectorWorkspaces.select(.transform)
        pump(0.2)
        editor.rootView.inspectorHost.layoutSubtreeIfNeeded()
        let badField = try XCTUnwrap(Self.button(CustomRatioField.self, id: CropAspectRow.customID,
                                                 in: editor.rootView.inspectorHost))
        badField.stringValue = "abc"
        badField.commitForTesting()
        pump(0.1)
        XCTAssertEqual(loupe.cropTool.draft.lock, lockBefore, "334: 被拒的输入不许改比例")
        XCTAssertFalse(CropRatioPanels.shared.commit("0:0", to: loupe.cropTool), "0:0 必须被拒绝")
        XCTAssertEqual(loupe.cropTool.draft.lock, lockBefore, "334: 被拒的输入不许改比例")
        print("ASPECT custom · 5:4 / 1.85 → document \(session.edit.geometry.aspectLock.code)")
        loupe.cancelCropTool()
    }

    // MARK: - 4. 角度：数值框里敲 1.5 → 应用后 rotationDegrees == 1.5

    func testTypingAnAngleIntoTheRowReachesTheDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let window = try XCTUnwrap(editor.window)
        TestWindows.show(window, key: true)
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

        XCTAssertEqual(loupe.cropTool.angleUIValue, 1.5, accuracy: 1e-9,
                       "敲进去的 1.5 是 UI 的正向角度")
        XCTAssertEqual(loupe.cropTool.draft.straighten, 1.5, accuracy: 1e-9,
                       "用户实测后（2026-10-29）：滑块正角就是文档正角，不再取反")
        // 087: 转动 is live — one typed value writes the document and commits one row.
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 1.5, accuracy: 1e-9,
                       "滑块向右 = 画面顺时针（文档与 UI 同号）：\(session.edit.geometry.rotationDegrees)")
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
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        try waitFor(panel) { _ in DetailRowEnabledLog.shared.value(CropApplyRow.applyProbe) != nil }
        // 334: 拉直行搬到了校正卡，裁切卡上剩下的开关是 宽高比 / 九宫格 / 应用 / 取消.
        let keys = ["宽高比", "九宫格", CropApplyRow.applyProbe, CropApplyRow.cancelProbe]
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

    // MARK: - 4. 四个比例按钮：244 pt 下同排、等宽、不截断（334）

    func testTheFourRatioButtonsShareOneRowAt244PointsAndNoneIsTruncated() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        // 300 pt 是工作区允许的最窄面板：卡内容 244 pt.
        let panel = try host(width: 300, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }

        XCTAssertEqual(CropSection.crop.title, "宽高比")
        XCTAssertEqual(InspectorView.Section.crop.title, "裁切", "卡片名仍是「裁切」")
        XCTAssertEqual(CropSection.displayOrder.map(\.title), ["宽高比", "角度", "透视", "旋转", "镜像"])
        XCTAssertEqual(CropSection.angleCardOrder.map(\.title), ["旋转", "镜像"])

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let contentWidth = card.width - 2 * WorkspaceLayout.cardInsetH
        XCTAssertGreaterThanOrEqual(contentWidth, 244 - 0.5, "244 pt 内容宽是这张卡的验收宽度")
        let title = try XCTUnwrap(panel.row(CropCardID.section(.crop)), "「宽高比」小标题没有画出来")

        var frames: [(String, CGRect)] = []
        for button in RatioButton.allCases {
            let view = try XCTUnwrap(panel.view(RatioPresetButton.self, identifier: button.identifier),
                                     "334: 比例按钮「\(button.title)」没有画出来")
            let rect = view.convert(view.bounds, to: panel.host)
            frames.append((button.title, rect))
            // 不截断：NSButton 的 cell 按裁剪而不是省略号断行，文本也真的放得下.
            XCTAssertEqual(view.cell?.lineBreakMode, .byClipping,
                           "334: 「\(button.title)」不许出现省略号")
            XCTAssertGreaterThanOrEqual(rect.width, CropAspectRow.minimumButtonWidth - 0.5,
                                        "334: 「\(button.title)」只有 \(rect.width) pt 宽（< 40）")
        }
        print("334 §3 · 四个比例 " + frames.map {
            String(format: "%@ (%.1f, %.1f, %.1f×%.1f)", $0.0, $0.1.minX, $0.1.minY,
                   $0.1.width, $0.1.height)
        }.joined(separator: " · "))

        // 同一行：midY 差 ≤ 0.5 pt；都在卡片里；都在「宽高比」小标题下面.
        let mids = frames.map(\.1.midY)
        XCTAssertLessThanOrEqual((mids.max() ?? 0) - (mids.min() ?? 0), 0.5,
                                 "334: 四个按钮必须同一行（midY \(mids)）")
        for (name, rect) in frames {
            XCTAssertGreaterThan(rect.minX, title.minX - 1, "334: 「\(name)」在小标题右侧")
            XCTAssertGreaterThanOrEqual(rect.minX, card.minX + WorkspaceLayout.cardInsetH - 0.5)
            XCTAssertLessThanOrEqual(rect.maxX, card.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                     "334: 「\(name)」出了卡片右边")
            XCTAssertGreaterThan(rect.minY, title.maxY, "334: 「\(name)」要在小标题下面")
        }

        // 点 16:9 → 草稿的锁就是 16:9.
        let sixteenNine = try XCTUnwrap(frames.first { $0.0 == "16:9" }?.1)
        let button = try XCTUnwrap(panel.view(RatioPresetButton.self,
                                              identifier: RatioButton.sixteenNine.identifier))
        button.performClick(nil)
        _ = try waitFor(panel) { _ in loupe.cropTool.draft.lock == .sixteenNine }
        print("334 §3 · 点 16:9 → draft.lock \(loupe.cropTool.draft.lock.code)"
              + " · 按钮 \(NSStringFromRect(sixteenNine))")
        XCTAssertEqual(loupe.cropTool.draft.lock, .sixteenNine,
                       "334: 点 16:9 之后 aspectLock 必须是 16:9")

        // 自定义比例那一行就在它们下面（图标 `ruler`，不是画线拉直的水平仪）.
        XCTAssertEqual(CropAspectRow.customSymbol, "ruler")
        let customRow = try XCTUnwrap(panel.row(CropAspectRow.customProbeID), "自定义比例行没有画出来")
        XCTAssertGreaterThan(customRow.minY, frames.map(\.1.maxY).max() ?? 0,
                             "334: 自定义比例在四个按钮下面")
    }

    // MARK: - 5. 应用 / 取消：面板的**固定页脚**，不再进裁切卡（336）

    /// 336 —— 334 那条「应用/取消是卡内最底一行」的断言，改成了「卡内没有 apply 行 + 页脚固定」：
    /// 用户要的是「放在右侧栏的右下方，不随卡片滚动而变」，所以它必须离开滚动内容，留在面板的
    /// 底部；尺寸与右下角的位置由 `ApplyFooter336Tests` 量。
    func testApplyAndCancelSitInThePinnedFooterNotInTheCropCard() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 330, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        try waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let correctionCard = try XCTUnwrap(panel.row(CropCardID.correctionCard))
        XCTAssertGreaterThan(correctionCard.minY, card.maxY, "334: 校正卡在裁切卡之后")
        let stays = try XCTUnwrap(panel.row(CropCardID.staysInsidePixels), "「不出像素」没有画出来")
        let grid = try XCTUnwrap(panel.row(CropCardID.grid), "九宫格没有画出来")
        XCTAssertGreaterThan(stays.minY, try XCTUnwrap(panel.row(CropAspectRow.customProbeID)).maxY,
                             "334: 「不出像素」在宽高比/自定义之下")
        XCTAssertEqual(grid.minY, stays.minY, accuracy: 1.0,
                       "343（用户）：九宫格与「不出像素」在同一行 —— 两行已并成一行")
        XCTAssertGreaterThan(grid.minX, stays.maxX,
                             "343（用户）：「不出像素」左对齐、九宫格右对齐")

        // 卡内不再有应用/取消：行探针不在卡里，按钮探针也不在.
        let cardRows = panel.probes.filter { $0.rowID != CropCardID.card }.filter {
            card.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: panel.host).origin)
        }.map(\.rowID)
        XCTAssertFalse(cardRows.contains(CropCardID.apply), "336: 裁切卡里还有 apply 行（\(cardRows)）")
        XCTAssertFalse(cardRows.contains(CropApplyRow.applyButtonProbe), "336: 裁切卡里还有应用按钮")
        XCTAssertFalse(cardRows.contains(CropApplyRow.cancelButtonProbe), "336: 裁切卡里还有取消按钮")

        // 页脚固定：存在、在卡外、不在 `ScrollView` 的内容里、并且在面板的底边.
        let row = try XCTUnwrap(panel.row(CropApplyRow.probeID), "应用 / 取消没有画出来")
        let footer = try XCTUnwrap(panel.row(CropApplyFooter.probeID), "固定页脚没有画出来")
        XCTAssertGreaterThan(footer.minY, card.maxY, "336: 页脚在卡片下方（卡外）")
        XCTAssertNil(panel.probes.first { $0.rowID == CropApplyFooter.probeID }?.enclosingScrollView,
                     "336: 页脚必须在 ScrollView 内容之外")
        XCTAssertEqual(footer.maxY, panel.host.bounds.maxY, accuracy: 0.5,
                       "336: 页脚容器贴面板底边")
        XCTAssertEqual(panel.host.bounds.maxY - row.maxY, CropApplyFooter.bottomInset, accuracy: 0.5,
                       "336: 页脚底 == 检查器底边 − 12")
        print(String(format: "336 FOOTER · stays %@ · grid %@ · 行集合 %@ · footer %@ · row %@",
                     NSStringFromRect(stays), NSStringFromRect(grid), "\(cardRows)",
                     NSStringFromRect(footer), NSStringFromRect(row)))
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
            try waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }

            let card = try XCTUnwrap(panel.row(CropCardID.card), "\(width) pt：没有卡片 frame")
            let correctionCard = try XCTUnwrap(panel.row(CropCardID.correctionCard),
                                               "\(width) pt：没有校正卡 frame")
            let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard), "\(width) pt：没有变换卡 frame")
            // 334/336: three cards, three row sets — 裁切 (宽高比 / 不出像素 / 九宫格),
            // 校正 (拉直 / 画线拉直 / 两条透视), 变换 (旋转 / 镜像). 应用/取消 是页脚，不在卡里.
            let cardRows: [(String, CGRect, CGRect)] = [
                (CropCardID.aspect, card),
                (CropCardID.staysInsidePixels, card),
                (CropCardID.grid, card),
            ].compactMap { id, owner in panel.row(id).map { (id, $0, owner) } }
            + CorrectionCardRow.allCases.compactMap { row in
                panel.row(row.probeID).map { (row.probeID, $0, correctionCard) }
            }
            + [(CropCardID.turn, angleCard), (CropCardID.mirror, angleCard)]
                .compactMap { id, owner in panel.row(id).map { (id, $0, owner) } }
            // 343 之后「不出像素」与「九宫格」同处一行；348 又给校正卡加了「引导线」。
            // 行数由枚举自己算，别再写字面量 —— 每加一行都要改数字的钉值只会带来假红。
            let expectedRows = 3 + CorrectionCardRow.allCases.count + 2
            XCTAssertEqual(cardRows.count, expectedRows,
                           "\(width) pt：\(expectedRows) 行里少了（\(cardRows.map(\.0))）")
            XCTAssertGreaterThan(correctionCard.minY, card.maxY,
                                 "\(width) pt：校正卡必须在裁切卡之后")
            XCTAssertGreaterThan(angleCard.minY, correctionCard.maxY,
                                 "\(width) pt：变换卡必须在最后")

            // 每行都在自己的卡片里，而且有宽度。九宫格是 343 并进「不出像素」那一行右侧的
            // 控件（不是整行），宽度按控件算，不参与「整行 ≥60 pt」这条。
            for (id, frame, owner) in cardRows where id != CropCardID.grid {
                XCTAssertGreaterThan(frame.width, 60, "\(width) pt：\(id) 只剩 \(frame.width) pt")
                XCTAssertGreaterThanOrEqual(frame.minX, owner.minX + WorkspaceLayout.cardInsetH - 0.5,
                                            "\(width) pt：\(id) 出了卡片左边（\(frame.minX) vs \(owner.minX)）")
                XCTAssertLessThanOrEqual(frame.maxX, owner.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                         "\(width) pt：\(id) 出了卡片右边（\(frame.maxX) vs \(owner.maxX)）")
            }
            // 不重叠：同一张卡内按 y 排好之后，上面那一**带**的底不能压到下面那一带的顶。
            // 343 起「不出像素」与「九宫格」并排在同一带（同一行、左右分置），所以先把同一行
            // 的行合成带，再检查带与带之间 —— 否则并排的两行会被当成上下重叠。
            for owner in [card, correctionCard, angleCard] {
                let ordered = cardRows.filter { $0.2 == owner }.sorted { $0.1.minY < $1.1.minY }
                var bands: [(name: String, rect: CGRect)] = []
                for (id, frame, _) in ordered {
                    if let last = bands.last, frame.minY <= last.rect.maxY - 0.5 {
                        bands[bands.count - 1].rect = last.rect.union(frame)
                        bands[bands.count - 1].name += "|\(id)"
                    } else {
                        bands.append((id, frame))
                    }
                }
                for (a, b) in zip(bands, bands.dropFirst()) {
                    XCTAssertLessThanOrEqual(a.rect.maxY, b.rect.minY + 0.5,
                                             "\(width) pt：\(a.name) 与 \(b.name) 重叠（\(a.rect) / \(b.rect)）")
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

    // MARK: - 123: 三条退出路径走同一个 finish，确认后回 .adjust

    func testConfirmLeavesCropModeReturnsToAdjustAndOnlyWritesWhenChanged() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let root = try XCTUnwrap(editor.rootView)
        let session = editor.session
        let loupe = root.loupeController

        root.inspectorWorkspaces.select(.transform)
        pump(0.2)
        XCTAssertTrue(loupe.isCropToolActive)
        XCTAssertEqual(root.inspectorWorkspaces.selection, .transform)
        let historyBefore = session.history.snapshots.count

        // ↵ with no edit: the tool closes, the workspace returns, no history row.
        XCTAssertFalse(loupe.applyCropTool(), "an unchanged draft must not claim a write")
        pump(0.2)
        XCTAssertFalse(loupe.isCropping)
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertEqual(root.inspectorWorkspaces.selection, .adjust,
                       "123: 确认后工作区回到 .adjust")
        XCTAssertEqual(session.history.snapshots.count, historyBefore,
                       "123: 无改动不加历史")

        // 完成 with a real edit: one row, same exit.
        root.inspectorWorkspaces.select(.transform)
        pump(0.2)
        loupe.cropTool.setAngle(uiValue: 5)
        XCTAssertTrue(loupe.completeCropTool())
        pump(0.2)
        XCTAssertFalse(loupe.isCropping)
        XCTAssertEqual(root.inspectorWorkspaces.selection, .adjust)
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 5, accuracy: 1e-9,
                       "完成写入的是 TransformSession 的符号（与 UI 同号）")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "123: 有改动加一条历史")

        // Structural half of acceptance 2: the controller and the renderer's document now carry the
        // same `CropGeometry` — no second angle, no second sign.
        let rendered = CropGeometry(geometry: session.edit.geometry, source: loupe.cropSourceSize)
        XCTAssertEqual(loupe.cropTool.cropGeometry, rendered,
                       "123: overlay/session and the render input must be one CropGeometry")
        XCTAssertEqual(loupe.cropTool.cropGeometry.rotationDegrees,
                       loupe.cropTool.transformSession.cropGeometry.rotationDegrees)

        // Esc still goes through the same `finish(_:)`, but writes nothing and does not move the
        // workspace back.
        root.inspectorWorkspaces.select(.transform)
        pump(0.2)
        loupe.cropTool.setAngle(uiValue: 12)
        loupe.finishCropTool(.cancel)
        pump(0.2)
        XCTAssertFalse(loupe.isCropping)
        XCTAssertEqual(session.edit.geometry.rotationDegrees, 5, accuracy: 1e-9,
                       "Esc 不写文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "Esc 不加历史")
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

        /// The one AppKit leaf with this accessibility id (ratio buttons, the custom field, …).
        func view<T: NSView>(_ type: T.Type, identifier: String) -> T? {
            views(ofType: type).first { $0.accessibilityIdentifier() == identifier }
        }

        func views<T: NSView>(ofType: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ root: NSView) {
                if let match = root as? T { found.append(match) }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            return found
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
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
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

    /// The one leaf of `type` with this identifier, anywhere under `root`.
    private static func button<T: NSView>(_ type: T.Type, id: String, in root: NSView) -> T? {
        var found: T?
        func walk(_ view: NSView) {
            if let match = view as? T, match.accessibilityIdentifier() == id { found = match }
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
