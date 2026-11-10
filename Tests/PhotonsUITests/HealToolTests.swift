import XCTest
import AppKit
import SwiftUI
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

    func testTheHealCardCarriesTheHealToolAndItsRows() throws {
        let heal = try Self.source("Sources/PhotonsUI/HealCardPanel.swift")
        XCTAssertTrue(heal.contains("InspectorCardShell"), "修复卡要用同一套卡头与玻璃底")
        XCTAssertTrue(heal.contains("inspector.heal.tool"),
                      "工具按钮带读回点，--ui-smoke 才能证明它在树里")
        XCTAssertTrue(heal.contains("session.deleteHealSpot(spot.id)"), "每一行可以删除")
        XCTAssertTrue(heal.contains("session.setHealRadius("), "每一行可以调半径")

        let mask = try Self.source("Sources/PhotonsUI/MaskListPanel.swift")
        XCTAssertFalse(mask.contains("inspector.heal."), "蒙版卡里不许再有修复的任何节点")
    }

    // MARK: - 5. 221: 两张卡、空状态、无复位声明

    func testTheMaskWorkspaceDeclaresBothCardsAndTheHealCardHasNoReset() {
        XCTAssertEqual(MaskWorkspaceCardSpec.all.map(\.title), ["蒙版", "修复"],
                       "蒙版工作区里上下两张卡")
        XCTAssertEqual(MaskWorkspaceCardSpec.all.map(\.reset), [.selectedMask, .none],
                       "修复卡显式登记为「无复位」")
        XCTAssertTrue(MaskWorkspaceCardSpec.mask.resetAction(session: session()) != nil)
        XCTAssertNil(MaskWorkspaceCardSpec.heal.resetAction(session: session()),
                     "修复卡没有双击复位：声明就是 nil，不是漏写")
    }

    /// 221 验收 2/3/4/5: an **empty** mask workspace still draws both cards, the heal tool in the
    /// empty 修复 card is clickable, and a spot lands in the 修复 card — not in 蒙版.
    ///
    /// The AX tree is empty under `swift test` (it is not a trusted accessibility client), so the
    /// titles come from each card's own `NSView` readback seam; the click targets the real SwiftUI
    /// button through the frame the button's own probe reports. The AX identifiers are still
    /// asserted on the sources, which is the form the existing card tests use.
    func testEmptyWorkspaceShowsBothCardsAndTheHealToolWorks() throws {
        let s = session()
        let (window, host) = Self.host(
            VStack(spacing: 8) {
                MaskListPanel(session: s)
                HealCardPanel(session: s)
            },
            size: CGSize(width: 330, height: 700))
        defer { window.contentView = nil }

        let maskProbe = try XCTUnwrap(Self.view(of: "MaskPanelProbe", in: host) as? MaskPanelProbe)
        let healProbe = try XCTUnwrap(Self.view(of: "HealCardProbe", in: host) as? HealCardProbe)
        XCTAssertEqual(maskProbe.title, "蒙版", "空的蒙版卡仍在")
        XCTAssertEqual(maskProbe.maskCount, 0, "空的蒙版卡真的没有蒙版")
        XCTAssertEqual(healProbe.title, "修复", "空的修复卡仍在")
        XCTAssertTrue(healProbe.isEmpty, "空的修复卡真的没有修复点")

        // Both empty-state lines are part of the shipped sources (Text has no AppKit leaf).
        let maskSource = try Self.source("Sources/PhotonsUI/MaskListPanel.swift")
        let healSource = try Self.source("Sources/PhotonsUI/HealCardPanel.swift")
        XCTAssertTrue(maskSource.contains("还没有蒙版"))
        XCTAssertTrue(healSource.contains("还没有修复点"))
        XCTAssertTrue(maskSource.contains("inspector.card.masks.title"))
        XCTAssertTrue(healSource.contains("inspector.card.heal.title"))
        XCTAssertTrue(maskSource.contains("newMaskMenu"), "空蒙版卡仍保留新建入口")

        // 3. the empty card is usable: click the real button, through its own probe's frame.
        let tool = try XCTUnwrap(Self.view(of: "HealToolProbe", in: host))
        XCTAssertFalse((tool as? HealToolProbe)?.isArmed ?? true)
        Self.click(tool, in: window)
        XCTAssertTrue(s.healTool, "空修复卡上的「修复」按钮必须可点")
        XCTAssertEqual(s.maskTool, .off, "修复与画笔互斥")

        // 4. a click on the canvas lands the row in 修复, not in 蒙版.
        _ = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.4, 0.5), radius: 0.03))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(healProbe.spotCount, 1, "新点出现在修复卡")

        // 5. a mask does not push the 修复 card away or change what it holds.
        _ = try XCTUnwrap(s.addMask(kind: .linearGradient))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(maskProbe.maskCount, 1, "蒙版卡有了一个蒙版")
        XCTAssertEqual(healProbe.title, "修复", "有蒙版时修复卡仍在")
        XCTAssertEqual(healProbe.spotCount, 1, "修复卡内容不因蒙版存在而变化")

        let maskOnly = Self.host(MaskListPanel(session: s),
                                 size: CGSize(width: 330, height: 700))
        defer { maskOnly.0.contentView = nil }
        XCTAssertNil(Self.view(of: "HealCardProbe", in: maskOnly.1),
                     "蒙版卡里不应出现修复卡")
        XCTAssertFalse(maskSource.contains("inspector.heal."),
                       "蒙版卡里不应出现任何 inspector.heal.* 节点")
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        TestWindows.show(window, key: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func view(of className: String, in root: NSView) -> NSView? {
        if String(describing: type(of: root)) == className { return root }
        for child in root.subviews {
            if let found = view(of: className, in: child) { return found }
        }
        return nil
    }

    /// A real left click at the covered view's centre. The probe's `hitTest` is nil, so the event
    /// lands on the SwiftUI button it sits behind.
    private static func click(_ target: NSView, in window: NSWindow) {
        TestWindows.show(window, key: true)
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)),
                                 (NSEvent.EventType.leftMouseUp, Float(0))] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1,
                                                 pressure: pressure) else { continue }
            window.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
