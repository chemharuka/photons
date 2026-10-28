import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 087 — 「角度」卡：转动 / 旋转 / 镜像，第二张卡，没有应用 / 取消。
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
        XCTAssertEqual(cards.cardIDs, ["crop", "angle"])
        XCTAssertEqual(cards.cardTitles, ["裁切", "变换"])

        let crop = try XCTUnwrap(Self.probe(CropCardID.card, in: inspector))
        let angle = try XCTUnwrap(Self.probe(CropCardID.angleCard, in: inspector))
        let cropRect = crop.convert(crop.bounds, to: inspector)
        let angleRect = angle.convert(angle.bounds, to: inspector)
        XCTAssertGreaterThan(angleRect.minY, cropRect.maxY, "角度卡必须在裁切卡之后")

        var headers: [CGRect] = []
        for title in ["宽高比", "转动", "旋转", "镜像"] {
            let probe = try XCTUnwrap(Self.probe("section.\(title)", in: inspector),
                                      "二级标题「\(title)」没有画出来")
            headers.append(probe.convert(probe.bounds, to: inspector))
        }
        XCTAssertEqual(CropSection.angleCardOrder.map(\.title), ["转动", "旋转", "镜像"])
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
