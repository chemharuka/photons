import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-28 (078 P0-1 / B9) — 修复画笔's UI surface: **one button, one click, one snapshot**.
///
/// The acceptance for the tool is deliberately small and this file pins exactly that, on the shipped
/// objects rather than on a rehearsal of them:
///
///   1. **Arming the tool takes the click.** `LoupeController.gestureOwner` — the one router the
///      canvas switches on — answers `.healClick` while 修复 is armed, even with a brush selected
///      (the spot tool is the innermost one-shot, like the eyedropper). Disarmed, the same click is
///      `.pan`.
///   2. **A click makes a spot, and a spot is one undo step.** `addHealSpot` appends to the document,
///      commits one row, and ⌘Z removes it — the same granularity every other edit has.
///   3. **Nothing is written for a click that cannot be a spot** — outside the frame, or when the
///      document is full (`HealSpot.maxCount`).
///   4. **The row's three verbs** — radius (with the drag/commit split), mode, delete — write to the
///      document and each leaves a history row.
///   5. **The panel really draws it**: the mask card's source has the 修复 button and the per-spot
///      rows (a source scan, the cheap form the other card tests use, because a SwiftUI `Button` is
///      not an `NSButton` a test can find in the live tree).
@MainActor
final class HealToolTests: XCTestCase {

    private func session() -> CatalogSession { CatalogSession() }

    // MARK: - 1. the gesture

    func testArmingTheToolTakesTheClickAndDisarmingGivesItBackToThePan() {
        let s = session()
        let controller = LoupeController(session: s)
        let point = CGPoint(x: 40, y: 40)

        XCTAssertEqual(controller.gestureOwner(atViewPoint: point), .pan,
                       "未启用时点画布还是平移（M3 的行为）")

        s.healTool = true
        XCTAssertEqual(controller.gestureOwner(atViewPoint: point), .healClick,
                       "修复 工具启用后，第一次点击属于它")

        // The spot tool is a **one-shot**: it does not need a mask, a selection or a drag, which is
        // why it is asked before `maskCreate`/`maskHandle`/`maskShape`/`paint`.
        s.maskTool = .brush
        XCTAssertEqual(controller.gestureOwner(atViewPoint: point), .healClick,
                       "同时装着画笔时，修复 仍然先拿这次点击")

        s.healTool = false
        XCTAssertEqual(controller.gestureOwner(atViewPoint: point), .pan)
    }

    // MARK: - 2. one click, one spot, one snapshot

    func testAClickAddsOneSpotAndOneUndoStep() throws {
        let s = session()
        // One ordinary edit first: the history's first snapshot is its base (cursor 0, `canUndo`
        // false), so "⌘Z takes the spot back" needs a state to go back to — the same setup every
        // other one-step test in this target uses.
        s.applyEdit { $0.light.exposure = 0.2 }
        s.commitEdit(label: "曝光")
        let before = s.history.count
        let spot = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.4, 0.6), radius: 0.03))
        XCTAssertEqual(s.edit.healSpots.count, 1)
        XCTAssertEqual(s.edit.healSpots.first?.center, NormalizedPoint(0.4, 0.6))
        XCTAssertEqual(s.edit.healSpots.first?.radius, 0.03)
        XCTAssertEqual(s.selectedHealSpotID, spot.id, "新点就是面板指向的点")
        XCTAssertEqual(spot.mode, .heal, "默认是 修复（带边界匹配），不是 克隆")
        XCTAssertEqual(s.history.count, before + 1, "一次点击 = 一行历史")

        // The first frame after the spot is a frame that visits S1.9.
        XCTAssertTrue(s.edit.hasHeal)

        XCTAssertTrue(s.undo(), "⌘Z 必须能撤销这一次点击")
        XCTAssertEqual(s.edit.healSpots.count, 0)
        XCTAssertFalse(s.edit.hasHeal)
    }

    func testAClickOutsideTheFrameWritesNothing() {
        let s = session()
        let before = s.history.count
        XCTAssertNil(s.addHealSpot(at: NormalizedPoint(1.4, 0.5)))
        XCTAssertNil(s.addHealSpot(at: NormalizedPoint(0.5, -0.1)))
        XCTAssertEqual(s.edit.healSpots.count, 0)
        XCTAssertEqual(s.history.count, before, "画框外的点击不留历史行")
    }

    func testTheCeilingIsTheModelSCeiling() {
        let s = session()
        for i in 0..<HealSpot.maxCount {
            XCTAssertNotNil(s.addHealSpot(at: NormalizedPoint(Double(i % 8) / 8 + 0.05,
                                                             Double(i / 8) / 8 + 0.05)))
        }
        XCTAssertEqual(s.edit.healSpots.count, HealSpot.maxCount)
        XCTAssertNil(s.addHealSpot(at: NormalizedPoint(0.5, 0.5)), "满了就不再收")
        XCTAssertEqual(s.edit.healSpots.count, HealSpot.maxCount)
    }

    // MARK: - 3. the row's verbs

    func testRadiusModeAndDeleteEachWriteOneStep() throws {
        let s = session()
        let spot = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.5, 0.5), radius: 0.02))
        let afterAdd = s.history.count

        // A drag writes through without committing; the mouse-up commits **once**.
        s.setHealRadius(0.03, for: spot.id, commit: false)
        s.setHealRadius(0.04, for: spot.id, commit: false)
        XCTAssertEqual(s.edit.healSpots.first?.radius, 0.04)
        XCTAssertEqual(s.history.count, afterAdd, "拖动中间态不落历史")
        s.commitEdit(label: "修复 半径")
        XCTAssertEqual(s.history.count, afterAdd + 1, "一次拖动 = 一行历史")

        s.setHealMode(.clone, for: spot.id)
        XCTAssertEqual(s.edit.healSpots.first?.mode, .clone)
        XCTAssertEqual(s.history.count, afterAdd + 2)

        s.deleteHealSpot(spot.id)
        XCTAssertEqual(s.edit.healSpots.count, 0)
        XCTAssertEqual(s.history.count, afterAdd + 3)
    }

    // MARK: - 4. the panel draws it

    func testTheMaskCardCarriesTheHealToolAndItsRows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo
            .appendingPathComponent("Sources/PhotonsUI/MaskListPanel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("healSection"), "蒙版卡里必须有一段 修复")
        XCTAssertTrue(source.contains("inspector.heal.tool"),
                      "工具按钮带读回点，--ui-smoke 才能证明它在树里")
        XCTAssertTrue(source.contains("session.deleteHealSpot(spot.id)"), "每一行可以删除")
        XCTAssertTrue(source.contains("session.setHealRadius("), "每一行可以调半径")
    }
}
