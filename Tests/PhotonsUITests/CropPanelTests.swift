import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 087/334 — 变换工作区的卡片：裁切（比例）/ 校正 / 变换，最后一张没有应用 / 取消。
///
/// 全部走真对象：真的库、真的 `EditorWindowController`、真的 `LoupeController`，卡是宿主在真窗口
/// 里的那个 `InspectorView`。六个用例对应派单的六条验收。
@MainActor
final class CropPanelTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 1. 第二张卡，标题「变换」，位置在裁切卡之后

    func testTheAngleCardIsTheSecondCardAfterCrop() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let cards = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: inspector),
                                  "面板没有报卡片清单")
        XCTAssertEqual(cards.cardIDs, ["crop", "transformCorrection", "angle"])
        XCTAssertEqual(cards.cardTitles, ["裁切", "校正", "变换"])

        let crop = try XCTUnwrap(Self.probe(CropCardID.card, in: inspector))
        let correction = try XCTUnwrap(Self.probe(CropCardID.correctionCard, in: inspector))
        let angle = try XCTUnwrap(Self.probe(CropCardID.angleCard, in: inspector))
        let cropRect = crop.convert(crop.bounds, to: inspector)
        let correctionRect = correction.convert(correction.bounds, to: inspector)
        let angleRect = angle.convert(angle.bounds, to: inspector)
        XCTAssertGreaterThan(correctionRect.minY, cropRect.maxY, "334: 校正卡在裁切卡之后")
        XCTAssertGreaterThan(angleRect.minY, correctionRect.maxY, "334: 变换卡在最后")

        var headers: [CGRect] = []
        // 122 A: 角度 没有二级标题（卡片自己叫「旋转」），所以这里是三个。
        for title in ["宽高比", "旋转", "镜像"] {
            let probe = try XCTUnwrap(Self.probe("section.\(title)", in: inspector),
                                      "二级标题「\(title)」没有画出来")
            headers.append(probe.convert(probe.bounds, to: inspector))
        }
        XCTAssertEqual(CropSection.angleCardOrder.map(\.title), ["旋转", "镜像"])
        for (a, b) in zip(headers, headers.dropFirst()) {
            XCTAssertGreaterThan(b.minY, a.minY)
        }
        print("087 §1 · cards \(cards.cardTitles) · crop \(NSStringFromRect(cropRect))"
              + " · angle \(NSStringFromRect(angleRect))")
    }

    // MARK: - 2. 角度卡里没有应用 / 取消

    func testTheAngleCardHasNoApplyOrCancel() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let angle = try XCTUnwrap(Self.probe(CropCardID.angleCard, in: inspector))
        let angleRect = angle.convert(angle.bounds, to: inspector)
        let forbidden = ["inspector.crop.apply", "inspector.crop.cancel"]
        let inside = Self.allViews(in: inspector).filter {
            let rect = $0.convert($0.bounds, to: inspector)
            return angleRect.intersects(rect) && forbidden.contains($0.accessibilityIdentifier())
        }
        XCTAssertTrue(inside.isEmpty,
                      "087 §2: 角度卡里出现了应用 / 取消：\(inside.map { $0.accessibilityIdentifier() })")
        XCTAssertNotNil(Self.probe(CropCardID.apply, in: inspector),
                        "裁切卡底部仍应有应用 / 取消")
        print("087 §2 · angle card has \(inside.count) apply/cancel controls")
    }

    // MARK: - 3. 旋转：裸图标、不变蓝、一条历史

    func testRotationUsesBareIconsAndNeverTintsThem() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let ccw = try XCTUnwrap(Self.find(TurnButton.self, id: CropTurnRow.counterClockwiseID,
                                         in: inspector), "逆时针按钮不在树上")
        let cw = try XCTUnwrap(Self.find(TurnButton.self, id: CropTurnRow.clockwiseID,
                                        in: inspector), "顺时针按钮不在树上")
        let badge = try XCTUnwrap(Self.find(TurnBadgeLabel.self, id: CropTurnRow.badgeID,
                                           in: inspector), "方向徽标不在树上")
        XCTAssertFalse(ccw.isBordered, "087 §3: 旋转图标不许有边框")
        XCTAssertFalse(cw.isBordered, "087 §3: 旋转图标不许有边框")
        let tintBefore = cw.contentTintColor
        XCTAssertEqual(tintBefore, NSColor.labelColor, "087 §3: 旋转图标不是文字色")
        XCTAssertEqual(badge.stringValue, "0°")

        let historyBefore = session.history.snapshots.count
        cw.performClick(nil)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(session.edit.geometry.quarterTurns, 1)
        XCTAssertEqual(loupe.quarterTurns, 1)
        XCTAssertEqual(badge.stringValue, "90°", "徽标要跟着 ⌘] 从 0° 走到 90°")
        XCTAssertEqual(cw.contentTintColor, tintBefore, "087 §3: 点击不许改变 tint")
        XCTAssertNotEqual(cw.contentTintColor, NSColor.controlAccentColor)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "一次旋转 = 一条历史")
        print("087 §3 · tint \(String(describing: tintBefore)) → \(String(describing: cw.contentTintColor))"
              + " · badge \(badge.stringValue) · history +\(session.history.snapshots.count - historyBefore)")
    }

    // MARK: - 4. 镜像：点后变蓝，再点回文字色，一次一条历史

    func testMirrorIconsTurnAccentWhileOnAndCommitOneRowEachClick() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        let session = editor.session
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let horizontal = try XCTUnwrap(Self.find(MirrorButton.self,
                                                 id: CropMirrorRow.horizontalID,
                                                 in: inspector), "水平图标不在树上")
        XCTAssertFalse(horizontal.isBordered, "087 §4: 镜像图标是裸图标")
        XCTAssertEqual(horizontal.contentTintColor, NSColor.labelColor)
        XCTAssertFalse(session.edit.geometry.flipHorizontal)

        let historyBefore = session.history.snapshots.count
        horizontal.performClick(nil)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertTrue(session.edit.geometry.flipHorizontal, "点水平没有翻转文档")
        XCTAssertEqual(horizontal.contentTintColor, NSColor.controlAccentColor,
                       "087 §4: 开着时图标必须是强调色")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "一次翻转 = 一条历史")

        horizontal.performClick(nil)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        XCTAssertFalse(session.edit.geometry.flipHorizontal)
        XCTAssertEqual(horizontal.contentTintColor, NSColor.labelColor)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2)
        print("087 §4 · flipH \(session.edit.geometry.flipHorizontal)"
              + " · history +\(session.history.snapshots.count - historyBefore)")
    }

    // MARK: - 5. 转动：拖动中只改草稿，松手写一条（088）

    func testStraightenCommitsOnlyOnRelease() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        let tool = loupe.cropTool
        let historyBefore = session.history.snapshots.count
        let straightenBefore = session.edit.geometry.straightenDegrees

        // One drag: onEditingChanged(true) → several ticks → onEditingChanged(false).
        for value in [1.25, 2.5, 3.75, 5.0] {
            tool.setStraightenLive(value)
            XCTAssertEqual(tool.draft.straighten, value, accuracy: 1e-9,
                           "088 §5: 拖动中每一 tick 只改草稿")
            XCTAssertEqual(session.edit.geometry.straightenDegrees, straightenBefore,
                           accuracy: 1e-9,
                           "088 §5: 拖动中不许写文档")
            XCTAssertEqual(session.history.snapshots.count, historyBefore,
                           "088 §5: 拖动过程中历史不许动")
        }
        XCTAssertEqual(session.history.snapshots.count, historyBefore)

        XCTAssertTrue(tool.commitStraighten(), "松手必须写出一条历史")
        CropUITestSupport.pump(0.1)
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 5.0, accuracy: 1e-9)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "松手 = 一条历史")
        XCTAssertEqual(session.history.snapshots.last?.label, "转动")
        XCTAssertNotEqual(straightenBefore, 5.0)
        print("088 §5 · straighten \(session.edit.geometry.straightenDegrees)"
              + " · history \(historyBefore) → \(session.history.snapshots.count)")
    }

    // MARK: - 6. Esc：回到进入前的文档与历史条数

    func testEscapeRestoresTheDocumentAndHistoryFromBeforeTheWorkspaceEntry() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        let straightenBefore = session.edit.geometry.straightenDegrees
        let historyBefore = session.history.snapshots.count

        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        XCTAssertTrue(loupe.isCropToolActive)

        loupe.cropTool.setStraightenLive(5.0)
        XCTAssertEqual(loupe.cropTool.draft.straighten, 5.0, accuracy: 1e-9)
        XCTAssertEqual(session.edit.geometry.straightenDegrees, straightenBefore,
                       accuracy: 1e-9,
                       "088 §6: 松手前角度只在草稿里")
        XCTAssertEqual(session.history.snapshots.count, historyBefore,
                       "松手前不许有历史")

        loupe.cancelCropTool()
        CropUITestSupport.pump(0.2)
        XCTAssertFalse(loupe.isCropToolActive, "Esc = 退出草稿态")
        XCTAssertEqual(session.edit.geometry.straightenDegrees, straightenBefore, accuracy: 1e-9,
                       "087 §6: Esc 必须回到进入前的角度")
        XCTAssertEqual(session.history.snapshots.count, historyBefore,
                       "087 §6: Esc 不许留下历史")
        print("087 §6 · straighten \(session.edit.geometry.straightenDegrees)"
              + " · history \(session.history.snapshots.count)")
    }

    /// 087 §6 (the half `转动` made necessary): once a drag has been **released**, its row is already
    /// in the history and the tool session that owned it has been closed and reopened. Esc must still
    /// put the geometry back to what it was when 变换 was entered — as one undoable row, because the
    /// earlier row is history and history is not rewritten.
    func testEscapeRevertsAfterAReleasedTurnDrag() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        let straightenBefore = session.edit.geometry.straightenDegrees
        let historyBefore = session.history.snapshots.count

        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        XCTAssertTrue(loupe.isCropToolActive)

        loupe.cropTool.setStraightenLive(5.0)
        XCTAssertTrue(loupe.cropTool.commitStraighten(), "松手提交一行")
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 5.0, accuracy: 1e-9)
        XCTAssertGreaterThan(session.history.snapshots.count, historyBefore)

        loupe.cancelCropTool()
        CropUITestSupport.pump(0.2)
        XCTAssertEqual(session.edit.geometry.straightenDegrees, straightenBefore, accuracy: 1e-9,
                       "Esc 必须在松手之后也回到进入前的角度")
        XCTAssertEqual(session.history.snapshots.last?.label, "变换 · 取消",
                       "回退本身是一条可撤销的记录，旧记录不被改写")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2,
                       "一条是那次转动，一条是这次回退")
        print("087 §6b · straighten \(session.edit.geometry.straightenDegrees)"
              + " · history \(session.history.snapshots.count)")
    }

    // MARK: - 334 · 四个比例按钮常显

    /// 334 (user): 「常见比例的按钮(1:1 4:3 16:9 2:3)都放出来，不要做成点击切换的模式」. The four
    /// buttons are on screen together, clicking one writes *its* lock, and the lock in force is the one
    /// drawn pressed — the assertion is on the button's own state, not on a colour.
    func testTheFourRatioButtonsAreAllOnScreenAndEachWritesItsOwnLock() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()
        let tool = editor.rootView.loupeController.cropTool

        var buttons: [RatioButton: RatioPresetButton] = [:]
        for button in RatioButton.allCases {
            buttons[button] = try XCTUnwrap(Self.find(RatioPresetButton.self, id: button.identifier,
                                                      in: inspector),
                                            "334: 比例按钮「\(button.title)」不在树上")
        }
        XCTAssertEqual(buttons.count, 4, "334: 四个比例必须同时存在")

        for button in RatioButton.allCases {
            let view = try XCTUnwrap(buttons[button])
            view.performClick(nil)
            CropUITestSupport.pump(0.1)
            inspector.layoutSubtreeIfNeeded()
            XCTAssertEqual(tool.draft.lock, button.lock,
                           "334: 点「\(button.title)」→ 草稿锁 \(tool.draft.lock.code)")
            // 按下态：正好这一颗亮.
            for other in RatioButton.allCases {
                let on = try XCTUnwrap(buttons[other]).isOn
                XCTAssertEqual(on, other == button,
                               "334: \(button.title) 锁定时 \(other.title) 的按下态是 \(on)")
            }
        }
        // 关闭态 / 开启态一眼看得出不同：accent 底 vs 卡片底.
        let locked = try XCTUnwrap(buttons[.sixteenNine])
        locked.performClick(nil)
        CropUITestSupport.pump(0.1)
        XCTAssertEqual(locked.layer?.backgroundColor, NSColor.controlAccentColor.cgColor)
        let off = try XCTUnwrap(buttons[.square])
        XCTAssertNotEqual(off.layer?.backgroundColor, NSColor.controlAccentColor.cgColor)
        print("334 buttons · " + RatioButton.allCases.map {
            "\($0.title)→\($0.lock.code)"
        }.joined(separator: " · "))
    }

    // MARK: - 334 · 原始 / 自由

    /// The two exits: 「原始」 is the sensor's own ratio (`.matching(source:)`), 「自由」 is
    /// `AspectLock.original` — no constraint at all. Without them a lock could never be released.
    func testOriginalAndFreeAreTheTwoWaysOutOfALock() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()
        let tool = editor.rootView.loupeController.cropTool

        let square = try XCTUnwrap(Self.find(RatioPresetButton.self, id: RatioButton.square.identifier,
                                             in: inspector))
        let original = try XCTUnwrap(Self.find(RatioPresetButton.self, id: CropAspectRow.originalID,
                                               in: inspector), "334: 「原始」不在树上")
        let free = try XCTUnwrap(Self.find(RatioPresetButton.self, id: CropAspectRow.freeID,
                                           in: inspector), "334: 「自由」不在树上")
        XCTAssertEqual(original.titleText, "原始")
        XCTAssertEqual(free.titleText, "自由")

        square.performClick(nil)
        CropUITestSupport.pump(0.1)
        XCTAssertEqual(tool.draft.lock, .square)
        XCTAssertFalse(tool.isAspectFree)

        original.performClick(nil)
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertEqual(tool.aspectPreset(), .original, "334: 「原始」= 传感器比例")
        XCTAssertFalse(tool.isAspectFree, "334: 原始仍是约束（只是没锁成某个常用比例）")
        XCTAssertTrue(original.isOn, "334: 原始 自己是按下态")

        free.performClick(nil)
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertTrue(tool.isAspectFree, "334: 「自由」= 文档里没有比例约束")
        XCTAssertEqual(tool.draft.lock, .original)
        XCTAssertTrue(free.isOn)
        print("334 exits · square \(AspectLock.square.code) → original \(AspectLock.matching(source: tool.sourceSize).code)"
              + " → free \(tool.draft.lock.code)")
    }

    // MARK: - 334 · 自定义键入（字段常显，不弹框）

    /// The typed ratio: the field is **always** in the card (no pencil, no panel), `5:4` becomes
    /// `AspectLock.custom(1.25)`, a decimal works, and committing creates no `NSWindow`/`NSPanel`.
    func testTheAlwaysVisibleRatioFieldWritesACustomLockAndNeverCreatesAWindow() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let inspector = editor.rootView.inspectorHost
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        inspector.layoutSubtreeIfNeeded()

        let tool = editor.rootView.loupeController.cropTool
        let field = try XCTUnwrap(Self.find(CustomRatioField.self, id: CropAspectRow.customID,
                                            in: inspector),
                                  "334: 自定义比例字段不在树上（它应当常显）")
        XCTAssertNil(CropRatioPanels.shared.prompt, "334: 键入比例不许创建面板")
        let windowsBeforeCommit = NSApp.windows.count

        field.stringValue = "5:4"
        field.commitForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()

        guard case .custom(let ratio) = tool.draft.lock else {
            return XCTFail("334: 5:4 没有写进草稿的锁（\(tool.draft.lock)）")
        }
        XCTAssertEqual(ratio, 1.25, accuracy: 1e-9, "334: 5:4 = custom(1.25)")
        XCTAssertEqual(field.stringValue, "5:4", "334: 字段显示键入的 W:H")
        XCTAssertNil(CropRatioPanels.shared.prompt, "334: 提交路径没有面板")
        XCTAssertEqual(NSApp.windows.count, windowsBeforeCommit, "334: 提交路径不创建任何窗口")

        // 小数也收.
        field.stringValue = "1.85"
        field.commitForTesting()
        CropUITestSupport.pump(0.1)
        XCTAssertEqual(tool.draft.lock, .custom(1.85), "334: 1.85 必须被接受")

        // 非法输入：一声响、不写、字段回到草稿的文本.
        let lockBefore = tool.draft.lock
        field.stringValue = "5:x"
        field.commitForTesting()
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertEqual(tool.draft.lock, lockBefore, "334: 被拒的输入不许改比例")
        XCTAssertEqual(field.stringValue, "37:20", "334: 被拒之后字段回到草稿的比例")
        XCTAssertEqual(NSApp.windows.count, windowsBeforeCommit, "334: 被拒的提交也不创建窗口")
        print("334 custom · 5:4 / 1.85 → \(tool.draft.lock.code) · windows \(windowsBeforeCommit)"
              + " → \(NSApp.windows.count)")
    }

    // MARK: - 104 · 底部信息栏重排

    /// Acceptance 4: the pill hugs its content (+ 12 pt each side), the three segments sit 16 pt
    /// apart, the group is centred on the bar, and the bar is centred on the canvas — at 900 / 1200 /
    /// 1600 pt. Printed frames are the evidence.
    func testTheCropBarHugsItsContentAndCentresTheThreeSegments() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let bar = CropToolBar(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1700, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        TestWindows.show(window)
        defer { window.orderOut(nil) }
        bar.controller = controller

        for canvasWidth in [900 as CGFloat, 1200, 1600] {
            let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: 600)
            bar.sync()
            bar.layout(in: canvas)
            bar.layoutSubtreeIfNeeded()
            let pill = bar.pillFrame
            let segments = bar.segmentFrames
            let separators = bar.separatorFrames

            XCTAssertEqual(bar.barWidth, CropToolBar.contentWidth + 24, accuracy: 1,
                           "104: pill 宽 = 内容宽 + 左右 12 pt（\(canvasWidth) pt 画布）")
            XCTAssertEqual(bar.frame.midX, canvas.midX, accuracy: 1,
                           "104: pill 水平居中于画布（\(canvasWidth) pt）")
            XCTAssertEqual((segments.angle.minX + segments.pixels.maxX) / 2, pill.midX, accuracy: 1,
                           "104: 三段整体中心 = pill 中心（\(canvasWidth) pt）")
            XCTAssertEqual(segments.ratio.minX - segments.angle.maxX, 16, accuracy: 1,
                           "104: 角度 | 比例 段间距 16 pt")
            XCTAssertEqual(segments.pixels.minX - segments.ratio.maxX, 16, accuracy: 1,
                           "104: 比例 | 像素 段间距 16 pt")
            XCTAssertEqual(separators.count, 2, "104: 两段之间各一条 1 pt 分隔线")
            for separator in separators {
                XCTAssertEqual(separator.width, 1, accuracy: 0.5)
                XCTAssertEqual(separator.height, 18, accuracy: 0.5)
            }
            print("104 bar \(Int(canvasWidth)) pt · bar \(NSStringFromRect(bar.frame))"
                  + " · pill \(NSStringFromRect(pill)) · angle \(NSStringFromRect(segments.angle))"
                  + " · ratio \(NSStringFromRect(segments.ratio))"
                  + " · pixels \(NSStringFromRect(segments.pixels))"
                  + " · gaps \(String(format: "%.2f", segments.ratio.minX - segments.angle.maxX))"
                  + "/\(String(format: "%.2f", segments.pixels.minX - segments.ratio.maxX))")
        }
    }

    // MARK: - finding the shipped views

    private static func probe(_ rowID: String, in root: NSView) -> CropRowProbe? {
        allViews(in: root).compactMap { $0 as? CropRowProbe }.first { $0.rowID == rowID }
    }

    private static func find<T: NSView>(_ type: T.Type, id: String, in root: NSView) -> T? {
        allViews(in: root).compactMap { $0 as? T }
            .first { $0.accessibilityIdentifier() == id }
    }

    private static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        allViews(in: root).compactMap { $0 as? T }.first
    }

    private static func allViews(in root: NSView) -> [NSView] {
        var found: [NSView] = [root]
        for sub in root.subviews { found += allViews(in: sub) }
        return found
    }
}
