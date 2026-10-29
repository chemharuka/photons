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
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        // The enum is the one spelling, and its order is the stacked order.
        XCTAssertEqual(InspectorView.Section.angle.title, "旋转", "123: 第二张卡的卡名是「旋转」")
        XCTAssertEqual(InspectorView.cardTitles(in: .transform), ["裁切", "旋转"])
        XCTAssertEqual(CropSection.allCases.map(\.rawValue), ["crop", "angle", "rotation", "mirror"])
        XCTAssertEqual(CropSection.displayOrder.map(\.title), ["宽高比", "角度", "旋转", "镜像"])
        XCTAssertEqual(CropSection.angleCardOrder.map(\.title), ["角度", "旋转", "镜像"])

        // …and the panel really drew its headers in that order, top to bottom. 122 A (user 2026-10-29):
        // the 「转动」 sub-header is gone — the card is titled 「旋转」 and the angle row sits directly
        // under it — so 角度 is the one section with no header of its own.
        var drawn: [(title: String, rect: CGRect)] = []
        for section in CropSection.displayOrder where section != .angle {
            let id = "section.\(section.title)"
            guard let rect = panel.row(id) else {
                XCTFail("082: 分区小标题「\(section.title)」没有画出来（probe \(id)）")
                continue
            }
            drawn.append((section.title, rect))
            print("082 §4 · 小标题「\(section.title)」 \(NSStringFromRect(rect))")
        }
        XCTAssertEqual(drawn.map(\.title), ["宽高比", "旋转", "镜像"])
        for (a, b) in zip(drawn, drawn.dropFirst()) {
            XCTAssertGreaterThan(b.rect.minY, a.rect.minY,
                                 "082 §4: 「\(b.title)」必须在「\(a.title)」下面")
        }
        // Nothing else calls itself a section.
        let allSectionProbes = panel.probes.filter { $0.rowID.hasPrefix("section.") }
        // 122 A: 角度 has no header of its own any more (the card itself is 「旋转」).
        XCTAssertEqual(allSectionProbes.count, 3,
                       "082 §4: 三个分区小标题，多出来的是 \(allSectionProbes.map(\.rowID))")
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
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        let cropCard = try XCTUnwrap(panel.row(CropCardID.card))
        let angleCard = try XCTUnwrap(panel.row(CropCardID.angleCard))
        print("082 §4 · panel 300 pt → 裁切卡 \(String(format: "%.1f×%.1f", cropCard.width, cropCard.height)) "
              + "· 角度卡 \(String(format: "%.1f×%.1f", angleCard.width, angleCard.height))")
        XCTAssertGreaterThan(angleCard.minY, cropCard.maxY, "087: 角度卡在裁切卡之后")

        // 087: the rows belong to two cards. Each one is measured against the card that owns it.
        let owners: [(CGRect, [String], [CropSection])] = [
            (cropCard, [CropCardID.aspect, CropCardID.apply], [.crop]),
            (angleCard, [CropCardID.angle, CropCardID.turn, CropCardID.mirror],
             [.angle, .rotation, .mirror]),
        ]
        var gaps: [String] = []
        for (card, rowIDs, sections) in owners {
            let contentWidth = card.width - 2 * WorkspaceLayout.cardInsetH
            XCTAssertGreaterThanOrEqual(contentWidth, 244 - 0.5,
                                        "082 §4: 244 pt 内容宽是这张卡的验收宽度")
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

            var headers: [(id: String, rect: CGRect)] = []
            for section in sections where section != .angle {   // 122 A: 角度 没有小标题
                let rect = try XCTUnwrap(panel.row("section.\(section.title)"))
                headers.append((section.title, rect))
            }
            // No two rows intersect — the corpus-wide rule these cards must not break.
            for i in 0..<rows.count {
                for j in (i + 1)..<rows.count {
                    XCTAssertFalse(rows[i].rect.intersects(rows[j].rect),
                                   "082 §4: \(rows[i].id) 与 \(rows[j].id) 相交 "
                                   + "(\(NSStringFromRect(rows[i].rect)) / \(NSStringFromRect(rows[j].rect)))")
                }
            }
            // Headers do not intersect rows either.
            for header in headers {
                for row in rows {
                    XCTAssertFalse(header.rect.intersects(row.rect),
                                   "082 §4: 小标题「\(header.id)」压到了 \(row.id)")
                }
            }

            // Gaps: 6 pt from a title to its own content, ≥ 12 pt between sections.
            let ordered = (rows + headers).sorted { $0.rect.minY < $1.rect.minY }
            for section in sections where section != .angle {   // 122 A: 角度 没有小标题
                let header = try XCTUnwrap(headers.first { $0.id == section.title }).rect
                guard let firstBelow = ordered.first(where: { $0.rect.minY > header.maxY - 0.5 }) else { continue }
                let insideGap = firstBelow.rect.minY - header.maxY
                gaps.append("「\(section.title)」→\(firstBelow.id) \(String(format: "%.2f", insideGap)) pt")
                XCTAssertGreaterThanOrEqual(insideGap, 5.5,
                                            "082 §4: 小标题与内容之间应 6 pt，实测 \(insideGap)")
            }
            for (a, b) in zip(headers, headers.dropFirst()) {
                let above = ordered.filter { $0.rect.maxY <= b.rect.minY + 0.5 }
                guard let last = above.max(by: { $0.rect.maxY < $1.rect.maxY }) else { continue }
                let gap = b.rect.minY - last.rect.maxY
                gaps.append("\(last.id)→「\(b.id)」 \(String(format: "%.2f", gap)) pt")
                XCTAssertGreaterThanOrEqual(gap, 11.5, "082 §4: 分区之间应 ≥12 pt，实测 \(gap) pt")
            }

            let orderedRows = rows.sorted { $0.rect.minY < $1.rect.minY }
            XCTAssertLessThanOrEqual(orderedRows.last!.rect.maxY,
                                     card.maxY - WorkspaceLayout.cardInsetV + 0.5,
                                     "082 §4: 最后一区出了卡片底边")
        }
        print("082 §4 · 间距 " + gaps.joined(separator: " · "))
    }

    // MARK: - 3. 两个角度（卡上不再印读数，悬浮栏仍旧）

    /// 093: the card no longer prints the 「实际角度 / 滑块角度」 readout. The floating bar keeps printing
    /// the actual angle, and the number still adds up in all three groups: 实际 = 滑块 + 90 × turns.
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
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        /// 093 §2: the readout that used to spell both angles out is gone from the card.
        func assertNoCardReadout() {
            let leaks = panel.views(ofType: NSTextField.self).filter {
                $0.stringValue.contains("实际角度") || $0.stringValue.contains("滑块角度")
            }
            XCTAssertTrue(leaks.isEmpty,
                          "093 §2: 卡片上不该再有「实际角度 / 滑块角度」读数：\(leaks.map(\.stringValue))")
        }

        // ① turns 0, slider +2.5 → 2.5°
        tool.setStraighten(2.5)
        CropUITestSupport.pump(0.1)
        loupe.cropBar.sync()
        assertNoCardReadout()
        print("093 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · bar "
              + "\(loupe.cropBar.readoutText.angle)")
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "2.5°", "悬浮栏印的是实际角度")
        XCTAssertEqual(tool.actualAngle, 2.5, accuracy: 1e-12)

        // ② turns 1, slider +2.5 → 92.5°
        // (The verb answers `false` while a crop session is open: `commitEdit` returns nil inside a tool
        // session by design — 072/077's rule — and the row lands at 应用. So the turn is measured on the
        // document, not on the return value.)
        loupe.rotateQuarter(clockwise: true)
        XCTAssertEqual(tool.quarterTurns, 1)
        CropUITestSupport.pump(0.1)
        loupe.cropBar.sync()
        assertNoCardReadout()
        print("093 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · bar "
              + "\(loupe.cropBar.readoutText.angle)")
        XCTAssertEqual(tool.actualAngle, 92.5, accuracy: 1e-12)
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "92.5°")

        // ③ turns 3, slider −4 → 266°
        loupe.rotateQuarter(clockwise: true)
        loupe.rotateQuarter(clockwise: true)
        XCTAssertEqual(tool.quarterTurns, 3)
        tool.setStraighten(-4)
        CropUITestSupport.pump(0.1)
        loupe.cropBar.sync()
        assertNoCardReadout()
        print("093 §3 · turns \(tool.quarterTurns) · slider \(tool.sliderAngleText()) · bar "
              + "\(loupe.cropBar.readoutText.angle)")
        XCTAssertEqual(tool.actualAngle, 266, accuracy: 1e-12)
        XCTAssertEqual(loupe.cropBar.readoutText.angle, "266.0°")
    }

    // MARK: - 093 §2: 转动小节没有第一条发丝线，滑块行叫「角度」

    /// A section header with `isFirst: false` is 1 pt hairline + 6 pt gap + ~14 pt title ≈ 21 pt; with
    /// `isFirst: true` it is just the title (~14 pt). The card's first section (转动) must be the latter,
    /// while 旋转 / 镜像 keep their lines.
    func testTheStraightenSectionHasNoHairlineAndItsRowSaysAngle() throws {
        DetailRowEnabledLog.shared.reset()
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 300, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        // 122 A (user 2026-10-29: 「转动的二级标题删掉」): there is no 角度 header any more — the angle
        // row sits directly under the card title, which is now 「旋转」. The other two sections keep
        // their headers, hairline and all.
        XCTAssertNil(panel.row("section.\(CropSection.angle.title)"),
                     "122 A: 角度 小标题必须已经删掉")
        let rotationHeader = try XCTUnwrap(panel.row("section.\(CropSection.rotation.title)"),
                                           "旋转小标题没有画出来")
        let mirrorHeader = try XCTUnwrap(panel.row("section.\(CropSection.mirror.title)"),
                                         "镜像小标题没有画出来")
        print("093 §2 · 旋转 \(NSStringFromRect(rotationHeader)) · 镜像 \(NSStringFromRect(mirrorHeader))")
        XCTAssertGreaterThanOrEqual(rotationHeader.height, 20,
                                    "093 §2: 旋转小节仍要有发丝线（实测 \(rotationHeader.height) pt）")
        XCTAssertGreaterThanOrEqual(mirrorHeader.height, 20,
                                    "093 §2: 镜像小节仍要有发丝线（实测 \(mirrorHeader.height) pt）")


        _ = waitFor(panel) { _ in DetailRowEnabledLog.shared.value("角度") != nil }
        XCTAssertEqual(DetailRowEnabledLog.shared.value("角度"), true,
                       "093 §2: 滑块行的标签必须是「角度」（行探针读回 \(String(describing: DetailRowEnabledLog.shared.value("角度")))）")
        XCTAssertNil(DetailRowEnabledLog.shared.value("转动"),
                     "093 §2: 「转动」已不再是滑块行的标签")

        let source = try Self.source("TransformPanel.swift")
        XCTAssertFalse(source.contains("CropAngleReadout"),
                       "093 §2: 卡片读数（CropAngleReadoutLabel / Host）应删除")
    }

    // MARK: - 093 §3: 旋转 = 左旋 · 右旋 · 最右角度（无背景块）

    func testTheRotationRowIsTwoIconsThenTheAngleAtTheFarRight() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 330, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        let row = try XCTUnwrap(panel.row(CropCardID.turn), "旋转行没有画出来")
        let ccw = try XCTUnwrap(panel.view(TurnButton.self, identifier: CropTurnRow.counterClockwiseID),
                                "左旋图标不在树上")
        let cw = try XCTUnwrap(panel.view(TurnButton.self, identifier: CropTurnRow.clockwiseID),
                               "右旋图标不在树上")
        let badge = try XCTUnwrap(panel.view(TurnBadgeLabel.self, identifier: CropTurnRow.badgeID),
                                  "角度文本不在树上")
        let ccwRect = ccw.convert(ccw.bounds, to: panel.host)
        let cwRect = cw.convert(cw.bounds, to: panel.host)
        let badgeRect = badge.convert(badge.bounds, to: panel.host)
        print("093 §3 · row \(NSStringFromRect(row)) · ccw \(NSStringFromRect(ccwRect))"
              + " · cw \(NSStringFromRect(cwRect)) · angle \(NSStringFromRect(badgeRect))")

        XCTAssertLessThan(ccwRect.maxX, cwRect.minX, "093 §3: 左旋在右旋左边")
        XCTAssertLessThanOrEqual(cwRect.minX - ccwRect.maxX, 8,
                                 "093 §3: 两个图标相邻，中间不许夹角度")
        XCTAssertGreaterThan(badgeRect.minX, cwRect.maxX,
                             "093 §3: 角度必须在两个图标的右边")
        XCTAssertGreaterThanOrEqual(badgeRect.maxX, ccwRect.maxX,
                                    "093 §3: 角度的 maxX 必须 ≥ 左旋的 maxX")
        XCTAssertGreaterThanOrEqual(badgeRect.maxX, cwRect.maxX,
                                    "093 §3: 角度的 maxX 必须 ≥ 右旋的 maxX")
        // The AppKit leaves report a couple of points of cell padding beyond SwiftUI's row frame
        // (icons: 22 pt wide in a 20 pt slot), so "right aligned" means "at the row's trailing edge,
        // within that same padding".
        XCTAssertLessThanOrEqual(abs(badgeRect.maxX - row.maxX), 3,
                                 "093 §3: 角度右对齐到行尾（badge \(badgeRect.maxX) vs row \(row.maxX)）")
        XCTAssertEqual(badge.stringValue, "0°", "干净文档的角度是 0°")

        // No background block: no fill, no border, no bezel, no rounded capsule.
        XCTAssertFalse(badge.drawsBackground, "093 §3: 角度文本不许有底色")
        XCTAssertFalse(badge.isBordered, "093 §3: 角度文本不许有描边")
        XCTAssertFalse(badge.isBezeled, "093 §3: 角度文本不许有 bezel")
        XCTAssertEqual(badge.layer?.cornerRadius ?? 0, 0, "093 §3: 角度文本不许有圆角块")
        XCTAssertNil(badge.layer?.backgroundColor, "093 §3: 角度文本背后不许有填充视图")

        let source = try Self.source("TransformPanel.swift")
        XCTAssertFalse(source.contains("Text(\"方向\")"), "093 §3: 「方向」文本应删除")
        XCTAssertFalse(panel.views(ofType: NSTextField.self).contains { $0.stringValue == "方向" },
                       "093 §3: 旋转行里不许再有「方向」文本")
    }

    // MARK: - 093 §4: 镜像两个按钮都在，各写一次文档 / 一条历史

    func testBothMirrorButtonsAreHitAndFlipTheDocument() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view
        XCTAssertTrue(loupe.beginCropTool())

        let panel = try host(width: 300, session: session, loupe: loupe)
        defer { panel.window.contentView = nil }
        panel.state.select(.transform)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "angle"] }

        let horizontal = try XCTUnwrap(panel.view(MirrorButton.self,
                                                  identifier: CropMirrorRow.horizontalID),
                                       "水平镜像按钮不在树上")
        let vertical = try XCTUnwrap(panel.view(MirrorButton.self,
                                                identifier: CropMirrorRow.verticalID),
                                     "垂直镜像按钮不在树上")
        let horizontalRect = horizontal.convert(horizontal.bounds, to: panel.host)
        let verticalRect = vertical.convert(vertical.bounds, to: panel.host)
        print("093 §4 · mirror H \(NSStringFromRect(horizontalRect)) \(horizontalRect.width) pt"
              + " · V \(NSStringFromRect(verticalRect)) \(verticalRect.width) pt"
              + " · images H=\(horizontal.image != nil) V=\(vertical.image != nil)")
        XCTAssertGreaterThan(horizontalRect.width, 0, "093 §4: 水平按钮的命中区宽必须 > 0")
        XCTAssertGreaterThan(verticalRect.width, 0,
                             "093 §4: 垂直按钮的命中区宽必须 > 0（实测 \(verticalRect.width) pt）")
        XCTAssertGreaterThan(horizontalRect.height, 0)
        XCTAssertGreaterThan(verticalRect.height, 0)
        XCTAssertNotNil(horizontal.image, "093 §4: 水平图标解析不出来")
        XCTAssertNotNil(vertical.image,
                        "093 §4: 垂直图标解析不出来（曾用 flip.vertical，本机 NSImage 返回 nil）")
        XCTAssertLessThan(horizontalRect.maxX, verticalRect.minX, "093 §4: 水平在垂直左边")

        let historyBefore = session.history.snapshots.count
        horizontal.performClick(nil)
        CropUITestSupport.pump(0.2)
        panel.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(session.edit.geometry.flipHorizontal, "093 §4: 点水平没有翻转文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "093 §4: 一次水平翻转 = 一条历史")

        vertical.performClick(nil)
        CropUITestSupport.pump(0.2)
        panel.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(session.edit.geometry.flipVertical, "093 §4: 点垂直没有翻转文档")
        XCTAssertTrue(session.edit.geometry.flipHorizontal, "093 §4: 垂直翻转不该碰水平")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2,
                       "093 §4: 一次垂直翻转 = 一条历史")
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

        // A document with something in every section: crop, angle, turn, flip. Written **before** the
        // tool opens, so the tool session's base *is* this document — that is what makes 「一次双击 =
        // 一条历史」 measurable (a reset closes the session first, and a pending document change would
        // become its own row, as it must: 072/077's rule).
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true))   // turns 1
        XCTAssertTrue(loupe.flipHorizontal())                 // mirror
        session.applyEdit { model in
            model.geometry.rotationDegrees = 7.5
            model.geometry.cropRect = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
            model.geometry.aspectLock = .square
        }
        session.commitEdit(label: "比例", coalesce: false)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        let resets = PanelResets(session: session, loupe: loupe)
        XCTAssertEqual(loupe.cropTool.draft.straighten, 7.5, accuracy: 1e-12,
                       "草稿从文档播种：滑块角度 7.5°")

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
        let turnedBack = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
        for (lhs, rhs) in [(geometry.cropRect.left, turnedBack.left),
                           (geometry.cropRect.top, turnedBack.top),
                           (geometry.cropRect.right, turnedBack.right),
                           (geometry.cropRect.bottom, turnedBack.bottom)] {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9,
                           "082 §5: 转回来的是同一块像素（rect 跟着转回去）\(geometry.cropRect)")
        }
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
        // Flush the tool session's pending row first: a discrete geometry action inside a session
        // closes it, so the *next* reset would otherwise commit two rows (the pending one + its own).
        // That is 072/077's rule working as designed, not the reset's arithmetic.
        session.endToolSession(label: "裁切与旋转")
        session.beginToolSession("裁切", label: "裁切与旋转")
        let beforeTitle = session.history.snapshots.count
        XCTAssertTrue(resets.cropGeometry(), "082 §7: 双击卡标题 = 整卡复位")
        XCTAssertEqual(session.edit.geometry, .identity, "082 §7: 整卡回 identity")
        XCTAssertEqual(session.history.snapshots.count, beforeTitle + 1, "082 §7: 整卡一条历史")
        print("082 §5 · 四次分区复位 + 整卡复位：history \(historyBefore) → "
              + "\(session.history.snapshots.count)（角度 1 · 镜像 1 · 旋转 1 · 裁切 1 · 整卡 1）")
    }

    // MARK: - 1 + 6. 进变换即进模式，且不改文档

    /// Switching to 变换 opens the tool (overlay on screen); 086 says switching away must **not** force
    /// it closed, and nothing about the document, the revision or the history moves either way.
    /// Anti-proof: the same switch with the hook off leaves the tool closed.
    func testTheWorkspaceEntersCropModeAndDoesNotForceItClosedWithoutTouchingTheDocument() throws {
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
        print("086 §1 · 切到变换：isCropToolActive \(loupe.isCropToolActive) · overlay 在屏 "
              + "\(loupe.isCropOverlayOnScreenForTesting) · bar 可见 \(!loupe.cropBar.isHidden)")
        XCTAssertTrue(loupe.isCropToolActive, "086 §1: 进变换 = 进裁切模式")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting, "086 §1: 选框真的在屏上")
        XCTAssertFalse(loupe.cropBar.isHidden, "086 §1: 悬浮栏跟着出现")
        // 6. no document write on the way in.
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytesBefore, "082 §6: 进模式不写文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "082 §6: 不产生历史")
        XCTAssertEqual(session.editRevision, revisionBefore, "082 §6: revision 不变")

        // → 调整 (082's leaving half is kept: the frame goes away with the card, and the draft is
        // cancelled rather than applied — a workspace switch is not 「应用」)
        root.inspectorWorkspaces.select(.adjust)
        CropUITestSupport.pump(0.1)
        print("086 §1 · 切回调整：isCropToolActive \(loupe.isCropToolActive) · overlay 在屏 "
              + "\(loupe.isCropOverlayOnScreenForTesting) · bar 可见 \(!loupe.cropBar.isHidden)")
        XCTAssertFalse(loupe.isCropToolActive, "082: 切走工作区 = 退出裁切模式")
        XCTAssertFalse(loupe.isCropOverlayOnScreenForTesting, "082: 选框随卡片一起消失")
        XCTAssertTrue(loupe.cropBar.isHidden)
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytesBefore, "082 §6: 切走也不写文档")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)
        XCTAssertEqual(session.editRevision, revisionBefore)

        // The explicit entries still work, and the workspace entry is idempotent.
        XCTAssertTrue(loupe.beginCropTool(), "082 §1: 回到变换再进模式")
        XCTAssertFalse(loupe.enterCropToolIfNeeded(), "086: 已经在裁切模式时重复进入必须什么都不做")
        XCTAssertTrue(loupe.isCropToolActive)
        loupe.cancelCropTool()
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertTrue(loupe.beginCropTool(), "082 §1: ⌘R / 菜单仍能进")
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
        let loupe = try XCTUnwrap(editor.rootView).loupeController
        defer { editor.window?.orderOut(nil) }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session))
        loupe.cropTool.setStraighten(1.5)
        loupe.rotateQuarter(clockwise: true)
        XCTAssertEqual(loupe.quarterTurns, 1)

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
    ///
    /// The two keys are **menu key equivalents** (`AppMenu` 变换 ▸ 逆时针/顺时针旋转 90°), so the
    /// honest measurement is the shipped row: its `keyEquivalent`, the target AppKit dispatches to
    /// (`EditorWindowController.rotateClockwiseAction`), and the document afterwards. A synthesised
    /// `keyDown` on the canvas would prove nothing — that is not where the key is handled.
    func testTheQuarterTurnShortcutsStillWork() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let loupe = try XCTUnwrap(editor.rootView).loupeController
        let session = editor.session
        defer { editor.window?.orderOut(nil) }
        _ = loupe.view
        let historyBefore = session.history.snapshots.count

        func menuItem(_ title: String) -> NSMenuItem? {
            var found: NSMenuItem?
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    if item.title == title { found = item }
                    if let sub = item.submenu { walk(sub) }
                }
            }
            walk(MainMenu.build())
            return found
        }

        let clockwise = try XCTUnwrap(menuItem("顺时针旋转 90°"), "082 §7: ⌘] 的菜单行不见了")
        let counter = try XCTUnwrap(menuItem("逆时针旋转 90°"), "082 §7: ⌘[ 的菜单行不见了")
        XCTAssertEqual(clockwise.keyEquivalent, "]", "082 §7: 顺时针 = ⌘]")
        XCTAssertEqual(counter.keyEquivalent, "[", "082 §7: 逆时针 = ⌘[")
        XCTAssertTrue(clockwise.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(counter.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(editor.validateMenuItem(clockwise), "有照片时 ⌘] 可用")

        editor.rotateClockwiseAction(nil)
        print("082 §7 · ⌘] → quarterTurns \(session.edit.geometry.quarterTurns) · 徽标 "
              + "\(LoupeController.quarterTurnBadge(for: session.edit.geometry.quarterTurns))")
        XCTAssertEqual(session.edit.geometry.quarterTurns, 1, "082 §7: ⌘] = 顺时针 90°")
        XCTAssertEqual(LoupeController.quarterTurnBadge(for: session.edit.geometry.quarterTurns), "90°")

        editor.rotateCounterClockwiseAction(nil)
        XCTAssertEqual(session.edit.geometry.quarterTurns, 0, "082 §7: ⌘[ 转回来")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 2, "每一步一条历史")
        print("082 §7 · history \(historyBefore) → \(session.history.snapshots.count)")
    }

    // MARK: - harness

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Sources/PhotonsUI/\(name)"),
                   encoding: .utf8)
    }

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

        /// The one AppKit leaf with this accessibility id (turn / mirror buttons, the angle label).
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
