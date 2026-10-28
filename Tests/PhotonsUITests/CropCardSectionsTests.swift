import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **082 — 裁切卡重写：进卡即进模式、悬浮栏只剩信息、角度分「滑块 / 实际」、四个分区。**
///
/// 用户的原话（2026-10-28）：
///
///   > 点击右侧裁切菜单后，自动进入裁切模式出现裁切选框。离开裁切模式也退出裁切选框。
///   > 裁切模式下方悬浮栏的调节功能全部移动到右侧面板，只保留比例，像素，角度的信息。
///   > 注意角度有两个，一个是实际角度，一个是滑块角度。实际角度等于滑块角度 + 90 旋转两个之和。
///   > 右侧裁切模式的 UI 要重写，裁切、角度、旋转、镜像等要区分更大，现在挤在一起。
///
/// 七条验收，每条都真跑在**宿主出来、排过版**的面板 / 真窗口上（不量愿望）：
///
///   1. 进卡即进模式，切走就退出（含反证：关掉自动进入，断言必红）。
///   2. 悬浮栏只读：视图树里可交互控件 0 个，三段信息仍在，角度 = 实际角度。
///   3. 两个角度：`turns 1 + 2.5 = 92.5°`、`turns 3 − 4 = 266°`、`turns 0 = 0°`。
///   4. 四分区：小标题存在且顺序为 裁切 / 角度 / 旋转 / 镜像；244 pt 下四区不重叠、任何两行不相交。
///   5. 各分区复位：双击「角度」→ 只有滑块角度（和文档的 `straightenDegrees`）回 0，`quarterTurns`
///      与两个翻转不变，历史 +1 一条。
///   6. 不改文档：进/出模式、切工作区，`documentHash` / `history.count` / `editRevision` 全不变。
///   7. 旧快捷键仍有效：⌘[ / ⌘] 转 90°，双击卡标题整卡复位。
@MainActor
final class CropCardSectionsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-sections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 4. 四分区：标题、顺序、几何

    /// The four section titles exist, in the user's order, and the four of them are the whole card.
    func testTheCardHasTheFourSectionsInTheUsersOrder() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        let panel = try host(width: 330, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop"] }

        // The enum is the one spelling, and its order is the stacked order.
        XCTAssertEqual(CropSection.allCases.map(\.rawValue), ["crop", "angle", "rotation", "mirror"])
        XCTAssertEqual(CropSection.displayOrder.map(\.title), ["裁切", "角度", "旋转", "镜像"])

        // …and the panel really drew four headers, in that order, top to bottom.
        var drawn: [(title: String, rect: CGRect)] = []
        for section in CropSection.displayOrder {
            let id = "section.\(section.title)"
            guard let rect = panel.row(id) else {
                XCTFail("082: 分区小标题「\(section.title)」没有画出来（probe \(id)）")
                continue
            }
            drawn.append((section.title, rect))
            print("082 §4 · 小标题「\(section.title)」 \(NSStringFromRect(rect))")
        }
        XCTAssertEqual(drawn.map(\.title), ["裁切", "角度", "旋转", "镜像"])
        for (a, b) in zip(drawn, drawn.dropFirst()) {
            XCTAssertGreaterThan(b.rect.minY, a.rect.minY,
                                 "082 §4: 「\(b.title)」必须在「\(a.title)」下面")
        }
        // Nothing else calls itself a section.
        let allSectionProbes = panel.probes.filter { $0.rowID.hasPrefix("section.") }
        XCTAssertEqual(allSectionProbes.count, 4, "082 §4: 正好四个分区，多出来的是 \(allSectionProbes.map(\.rowID))")
    }

    /// 244 pt of content: every row has a real width, nothing leaves the card, the section gaps are
    /// ≥ 12 pt, a title sits 6 pt above its own content, and **no two rows intersect**.
    func testTheFourSectionsLayOutAt244PointsWithoutOverlapping() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        // 300 pt is the narrowest panel the workspace allows; its card content is 244 pt wide.
        let panel = try host(width: 300, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop"] }

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let contentWidth = card.width - 2 * WorkspaceLayout.cardInsetH
        print("082 §4 · panel 300 pt → card \(String(format: "%.1f×%.1f", card.width, card.height)) "
              + "· 内容宽 \(String(format: "%.1f", contentWidth)) pt")
        XCTAssertGreaterThanOrEqual(contentWidth, 244 - 0.5, "082 §4: 244 pt 内容宽是这张卡的验收宽度")

        let rowIDs = [CropCardID.aspect, CropCardID.angle, CropCardID.turn,
                      CropCardID.mirror, CropCardID.apply]
        var rows: [(id: String, rect: CGRect)] = []
        for id in rowIDs {
            let rect = try XCTUnwrap(panel.row(id), "082 §4: 行 \(id) 没有画出来")
            rows.append((id, rect))
            XCTAssertGreaterThan(rect.width, 60, "082 §4: \(id) 只剩 \(rect.width) pt 宽")
            XCTAssertLessThanOrEqual(rect.width, contentWidth + 0.5,
                                     "082 §4: \(id) 比内容宽还宽（\(rect.width) > \(contentWidth)）—— 会换行")
            XCTAssertGreaterThanOrEqual(rect.minX, card.minX + WorkspaceLayout.cardInsetH - 0.5,
                                        "082 §4: \(id) 出了卡片左边")
            XCTAssertLessThanOrEqual(rect.maxX, card.maxX - WorkspaceLayout.cardInsetH + 0.5,
                                     "082 §4: \(id) 出了卡片右边")
            print("082 §4 · \(id) \(NSStringFromRect(rect))")
        }

        // No two rows intersect — the corpus-wide rule this card must not break.
        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count {
                XCTAssertFalse(rows[i].rect.intersects(rows[j].rect),
                               "082 §4: \(rows[i].id) 与 \(rows[j].id) 相交 "
                               + "(\(NSStringFromRect(rows[i].rect)) / \(NSStringFromRect(rows[j].rect)))")
            }
        }
        // And the four headers do not intersect the rows either.
        var headers: [(id: String, rect: CGRect)] = []
        for section in CropSection.displayOrder {
            let rect = try XCTUnwrap(panel.row("section.\(section.title)"))
            headers.append((section.title, rect))
        }
        for header in headers {
            for row in rows {
                XCTAssertFalse(header.rect.intersects(row.rect),
                               "082 §4: 小标题「\(header.id)」压到了 \(row.id)")
            }
        }

        // Gaps: ≥ 12 pt between one section's content and the next title, 6 pt inside a section.
        let ordered = (rows + headers).sorted { $0.rect.minY < $1.rect.minY }
        var gaps: [String] = []
        for section in CropSection.displayOrder {
            let header = try XCTUnwrap(headers.first { $0.id == section.title }).rect
            guard let firstRow = ordered.first(where: { $0.rect.minY > header.maxY - 0.5 }) else { continue }
            let insideGap = firstRow.rect.minY - header.maxY
            print("082 §4 · 「\(section.title)」标题与 \(firstRow.id) 之间 \(String(format: "%.2f", insideGap)) pt")
            XCTAssertGreaterThanOrEqual(insideGap, 5.5,
                                        "082 §4: 小标题与内容之间应 6 pt，实测 \(insideGap)")
        }
        for (a, b) in zip(headers, headers.dropFirst()) {
            // The previous section's last row → the next section's title.
            let previousRows = rows.filter { $0.rect.maxY <= a.rect.maxY + 0.5 }
            guard let last = previousRows.max(by: { $0.rect.maxY < $1.rect.maxY }) else { continue }
            let gap = b.rect.minY - last.rect.maxY
            gaps.append("\(a.id)→\(b.id) \(String(format: "%.2f", gap)) pt")
            XCTAssertGreaterThanOrEqual(gap, 11.5, "082 §4: 分区之间应 ≥12 pt，实测 \(gap) pt")
        }
        print("082 §4 · 分区间距 " + gaps.joined(separator: " · "))

        XCTAssertLessThanOrEqual(ordered.last!.rect.maxY, card.maxY - WorkspaceLayout.cardInsetV + 0.5,
                                 "082 §4: 最后一区出了卡片底边")
    }

    // MARK: - 3. 两个角度

    /// 实际 = 滑块 + 90 × quarterTurns, in three groups of numbers, and the readout is **read-only**.
    func testTheCardPrintsBothAnglesAndTheyAddUp() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())
        let tool = loupe.cropTool

        let panel = try host(width: 330, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop"] }

        func readout() throws -> String {
            let label = try XCTUnwrap(panel.views(ofType: CropAngleReadoutLabel.self).first,
                                      "082 §3: 卡片上没有「实际角度 / 滑块角度」读数")
            _ = waitFor(panel) { _ in true }
            return label.stringValue
        }

        // ① turns 0, slider +2.5 → 2.5°
        tool.setStraighten(2.5)
        var text = try readout()
        print("082 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · \(text)")
        XCTAssertTrue(text.contains("实际角度 2.5°"), text)
        XCTAssertTrue(text.contains("滑块角度 +2.5°"), text)
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "2.5°", "悬浮栏印的是同一个实际角度")
        XCTAssertEqual(tool.actualAngle, 2.5, accuracy: 1e-12)

        // ② turns 1, slider +2.5 → 92.5°
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true))
        text = try readout()
        print("082 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · \(text)")
        XCTAssertTrue(text.contains("实际角度 92.5°"), text)
        XCTAssertTrue(text.contains("滑块角度 +2.5°"), text)
        XCTAssertEqual(tool.actualAngle, 92.5, accuracy: 1e-12)
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "92.5°")

        // ③ turns 3, slider −4 → 266°
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true))
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true))
        tool.setStraighten(-4)
        text = try readout()
        print("082 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · \(text)")
        XCTAssertTrue(text.contains("实际角度 266.0°"), text)
        XCTAssertTrue(text.contains("滑块角度 -4.0°"), text)
        XCTAssertEqual(tool.actualAngle, 266, accuracy: 1e-12)
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "266.0°")

        // The readout is a **label**, not an input: nothing here can be typed into or selected.
        let label = try XCTUnwrap(panel.views(ofType: CropAngleReadoutLabel.self).first)
        XCTAssertFalse(label.isEditable, "082 §3: 读数是只读的")
        XCTAssertFalse(label.isSelectable)
        XCTAssertEqual(label.identifier?.rawValue, CropAngleReadoutLabel.identifier)
        XCTAssertTrue(label.stringValue.contains("实际角度"))
        XCTAssertTrue(label.stringValue.contains("滑块角度"))
        // …and it is a *number*, not a second source of truth: it is derived from the tool.
        XCTAssertEqual(text, CropAngleReadoutLabel.text(actual: tool.angleText(),
                                                        slider: tool.sliderAngleText()))
    }

    // MARK: - 5. 各分区复位

    /// Double-clicking a section title resets **that** section — one snapshot, and nothing else moves.
    ///
    /// The panel's title gesture and this test call the same verb (`PanelResets.cropSection`), the rule
    /// every other card follows (`PanelResetTests`): a reset a test can call is a reset that cannot rot.
    func testEachSectionResetsOnlyItsOwnFieldsInOneSnapshot() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())
        let resets = PanelResets(session: session, loupe: loupe)

        // A document with something in every section: crop, angle, turn, flip.
        loupe.rotateQuarter(clockwise: true)                  // turns 1
        XCTAssertTrue(loupe.flipHorizontal())                 // mirror
        loupe.cropTool.setStraighten(7.5)                     // slider angle (draft)
        session.applyEdit { $0.geometry.rotationDegrees = 7.5 }
        session.commitEdit(label: "角度", coalesce: false)
        session.applyEdit { model in
            model.geometry.cropRect = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
            model.geometry.aspectLock = .square
        }
        session.commitEdit(label: "比例", coalesce: false)
        loupe.cropTool.reseedDraftFromDocument()

        let turnsBefore = session.edit.geometry.quarterTurns
        let flipBefore = session.edit.geometry.flipHorizontal
        let cropBefore = session.edit.geometry.cropRect
        let historyBefore = session.history.snapshots.count
        print("082 §5 · 起点 turns \(turnsBefore) · flipH \(flipBefore) · angle "
              + "\(session.edit.geometry.straightenDegrees) · crop \(cropBefore.keyString) "
              + "· history \(historyBefore)")

        // 角度: only the angle moves.
        XCTAssertTrue(resets.cropSection(.angle), "082 §5: 「角度」复位必须写一条")
        var geometry = session.edit.geometry
        XCTAssertEqual(geometry.straightenDegrees, 0, accuracy: 1e-12, "082 §5: 角度回 0")
        XCTAssertEqual(geometry.quarterTurns, turnsBefore, "082 §5: 旋转不动")
        XCTAssertEqual(geometry.flipHorizontal, flipBefore, "082 §5: 翻转不动")
        XCTAssertEqual(geometry.cropRect, cropBefore, "082 §5: 裁切框不动")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "082 §5: 一条历史")
        XCTAssertEqual(loupe.cropTool.draft.straighten, 0, accuracy: 1e-12,
                       "082 §5: 草稿跟着文档 —— 画面上不再斜")
        XCTAssertEqual(loupe.cropBar.readoutText.angle, String(format: "%.1f°", 90.0 * Double(turnsBefore)))

        // A second double-click on the same title writes nothing (no empty snapshot).
        let afterAngle = session.history.snapshots.count
        XCTAssertFalse(resets.cropSection(.angle), "082 §5: 已经归位就不写")

        // 镜像: both flips off, everything else stays.
        XCTAssertTrue(resets.cropSection(.mirror))
        geometry = session.edit.geometry
        XCTAssertFalse(geometry.flipHorizontal)
        XCTAssertFalse(geometry.flipVertical)
        XCTAssertEqual(geometry.quarterTurns, turnsBefore, "082 §5: 镜像不动旋转")
        XCTAssertEqual(session.history.snapshots.count, afterAngle + 1)

        // 旋转: back to 0° *with the rect turned back*, one row, angle and flips untouched.
        let angleBefore = session.edit.geometry.straightenDegrees
        XCTAssertTrue(resets.cropSection(.rotation))
        geometry = session.edit.geometry
        XCTAssertEqual(geometry.quarterTurns, 0, "082 §5: 旋转回 0°")
        XCTAssertEqual(geometry.straightenDegrees, angleBefore, accuracy: 1e-12, "082 §5: 旋转不动角度")
        XCTAssertEqual(geometry.cropRect, CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
                       "082 §5: 转回来的是同一块像素（rect 跟着转回去）")
        XCTAssertEqual(session.history.snapshots.count, afterAngle + 2)
        XCTAssertFalse(resets.cropSection(.rotation), "已经 0° 就不写")

        // 裁切: the whole frame, no lock.
        XCTAssertTrue(resets.cropSection(.crop))
        geometry = session.edit.geometry
        XCTAssertEqual(geometry.cropRect, .full, "082 §5: 裁切框回整幅")
        XCTAssertEqual(geometry.aspectLock, .original, "082 §5: 比例回自由")
        XCTAssertEqual(session.history.snapshots.count, afterAngle + 3)

        // …and the whole card in one: everything back to identity, one row.
        loupe.cropTool.setStraighten(6)
        session.applyEdit { $0.geometry.rotationDegrees = 6 }
        session.commitEdit(label: "角度", coalesce: false)
        _ = loupe.flipVertical()
        _ = loupe.rotateQuarter(clockwise: true)
        let beforeTitle = session.history.snapshots.count
        XCTAssertTrue(resets.cropGeometry(), "082 §7: 双击卡标题 = 整卡复位")
        XCTAssertEqual(session.edit.geometry, .identity, "082 §7: 整卡回 identity")
        XCTAssertEqual(session.history.snapshots.count, beforeTitle + 1, "082 §7: 整卡一条历史")
        print("082 §5 · 四次分区复位 + 整卡复位：history \(historyBefore) → "
              + "\(session.history.snapshots.count)（角度 1 · 镜像 1 · 旋转 1 · 裁切 1 · 整卡 1）")
    }

    // MARK: - 1 + 6. 进卡即进模式，且不改文档

    /// Switching to 变换 opens the tool (overlay on screen); switching away closes it — and **nothing**
    /// about the document, the revision or the history moves. Anti-proof: the same switch with the hook
    /// off leaves the tool closed.
    func testTheWorkspaceEntersAndLeavesCropModeWithoutTouchingTheDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let root = try XCTUnwrap(editor.rootView)
        let loupe = root.loupeController
        let session = editor.session
        defer { editor.window?.orderOut(nil) }

        let bytesBefore = CropUITestSupport.documentBytes(session)
        let revisionBefore = session.editRevision
        let historyBefore = session.history.snapshots.count
        XCTAssertFalse(loupe.isCropToolActive, "起步：调整工作区，裁切模式关着")

        // → 变换
        root.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.1)
        print("082 §1 · 切到变换：isCropToolActive \(loupe.isCropToolActive) · overlay 在屏 "
              + "\(loupe.isCropOverlayOnScreenForTesting) · bar 可见 \(!loupe.cropBar.isHidden)")
        XCTAssertTrue(loupe.isCropToolActive, "082 §1: 进变换 = 进裁切模式")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "082 §1: 选框真的在屏上")
        XCTAssertFalse(loupe.cropBar.isHidden, "082 §1: 悬浮栏跟着出现")
        // 6. no document write on the way in.
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytesBefore, "082 §6: 进模式不写文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "082 §6: 不产生历史")
        XCTAssertEqual(session.editRevision, revisionBefore, "082 §6: revision 不变")

        // → 调整
        root.inspectorWorkspaces.select(.adjust)
        CropUITestSupport.pump(0.1)
        print("082 §1 · 切回调整：isCropToolActive \(loupe.isCropToolActive) · overlay 在屏 "
              + "\(loupe.isCropOverlayOnScreenForTesting) · bar 可见 \(!loupe.cropBar.isHidden)")
        XCTAssertFalse(loupe.isCropToolActive, "082 §1: 切走工作区 = 退出裁切模式")
        XCTAssertFalse(loupe.isCropOverlayOnScreenForTesting, "082 §1: 选框消失")
        XCTAssertTrue(loupe.cropBar.isHidden)
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytesBefore, "082 §6: 退出也不写文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)
        XCTAssertEqual(session.editRevision, revisionBefore)

        // The 直角尺 button is still an explicit switch (it is no longer the only way in).
        XCTAssertTrue(loupe.beginCropTool(), "082 §1: 直角尺 / ⌘R 仍能进")
        XCTAssertTrue(loupe.isCropToolActive)
        loupe.cancelCropTool()

        // Anti-proof: with the hook off, the same switch leaves the tool closed.
        loupe.workspaceDrivesCropMode = false
        root.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.1)
        let activeWithoutHook = loupe.isCropToolActive
        print("082 §1 anti-proof · hook off：切到变换后 isCropToolActive \(activeWithoutHook)")
        XCTAssertFalse(activeWithoutHook,
                       "082 §1 反证：关掉「工作区驱动模式」，切到变换后工具必须还是关着的")
        loupe.workspaceDrivesCropMode = true
    }

    // MARK: - 2. 悬浮栏只读（在真画布上）

    /// The bar the loupe really shows has zero interactive controls and three readouts; its 角度 is the
    /// actual angle after a quarter turn.
    func testTheRealBarIsReadOnlyAndShowsTheActualAngle() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let loupe = editor.rootView.loupeController
        defer { editor.window?.orderOut(nil) }
        XCTAssertTrue(loupe.beginCropTool())
        loupe.cropTool.setStraighten(1.5)
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true))

        let bar = loupe.cropBar
        bar.sync()
        bar.layout(in: loupe.canvasView.bounds)
        let controls = CropToolBar.interactiveControls(in: bar)
        print("082 §2 · 真悬浮栏：控件 \(controls.count) 个 · 读数 角度「\(bar.readoutText.angle)」"
              + " 比值「\(bar.readoutText.ratio)」 像素「\(bar.readoutText.pixels)」")
        XCTAssertEqual(controls.count, 0, "082 §2: 悬浮栏里不许有可交互控件")
        XCTAssertEqual(bar.readoutText.angle, "91.5°", "082 §2/§3: 角度 = 实际角度（1.5 + 90）")
        XCTAssertFalse(bar.readoutText.ratio.isEmpty)
        XCTAssertTrue(bar.readoutText.pixels.contains("×"))
        XCTAssertGreaterThan(bar.barWidth, 100)
    }

    // MARK: - 7. 旧快捷键

    /// ⌘[ / ⌘] still turn the picture by 90° (one snapshot each), and the card's badge follows.
    func testTheQuarterTurnShortcutsStillWork() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let loupe = editor.rootView.loupeController
        let session = editor.session
        let canvas = loupe.canvasView
        defer { editor.window?.orderOut(nil) }
        _ = loupe.view
        let historyBefore = session.history.snapshots.count

        func press(_ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                         timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                                         context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: 0)!
            canvas.keyDown(with: event)
        }

        press("]")
        print("082 §7 · ⌘] → quarterTurns \(session.edit.geometry.quarterTurns) · 徽标 "
              + "\(LoupeController.quarterTurnBadge(for: session.edit.geometry.quarterTurns))")
        XCTAssertEqual(session.edit.geometry.quarterTurns, 1, "082 §7: ⌘] = 顺时针 90°")
        XCTAssertEqual(LoupeController.quarterTurnBadge(for: session.edit.geometry.quarterTurns), "90°")

        press("[")
        XCTAssertEqual(session.edit.geometry.quarterTurns, 0, "082 §7: ⌘[ 转回来")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2, "每一步一条历史")
        print("082 §7 · history \(historyBefore) → \(session.history.snapshots.count)")
    }

    // MARK: - harness

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState

        var cards: InspectorCardsProbe {
            views(ofType: InspectorCardsProbe.self).first ?? InspectorCardsProbe(frame: .zero)
        }

        /// Every crop-card probe currently in the tree.
        var probes: [CropRowProbe] { views(ofType: CropRowProbe.self) }

        /// One row's frame, in the panel's coordinates.
        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
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
    }

    private func host(width: CGFloat, height: CGFloat = 900,
                      session: CatalogSession, loupe: LoupeController) throws -> Panel {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                         workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.4)
        host.layoutSubtreeIfNeeded()
        return Panel(host: host, window: window, state: state)
    }

    @discardableResult
    private func waitFor(_ panel: Panel, until predicate: (Panel) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            panel.host.layoutSubtreeIfNeeded()
            if predicate(panel) { return true }
            CropUITestSupport.pump(0.05)
        }
        panel.host.layoutSubtreeIfNeeded()
        return predicate(panel)
    }
}
