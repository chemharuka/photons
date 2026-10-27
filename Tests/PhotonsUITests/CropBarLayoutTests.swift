import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 072 §D — 裁切栏 UI.
///
/// D1 信息栏三段定宽 · D2 双击角度归位 · D3 三开关变蓝 · D4 默认模式灰掉裁切动作.
///
/// Everything is measured on the real `CropToolBar` (no snapshot, no screenshot): the three readout
/// fields' `frame(x, width)` for four extreme drafts, the bar's total width for the same four, the
/// two colour slots of each toggle, and the two menu items' `isEnabled` through the real
/// `validateMenuItem`.
@MainActor
final class CropBarLayoutTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-bar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeBar() throws -> (CropToolBar, CropToolController, CatalogSession, NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let controller = CropToolController(session: session)
        let bar = CropToolBar(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        window.orderFront(nil)
        bar.controller = controller
        return (bar, controller, session, window)
    }

    private func layOut(_ bar: CropToolBar) {
        bar.sync()
        bar.layout(in: NSRect(x: 0, y: 0, width: 900, height: 600))
        bar.layoutSubtreeIfNeeded()
    }

    // MARK: - D1

    /// Four extreme drafts — the worst angle, the widest ratio, the largest pixel text, and the
    /// untouched frame — must produce **the same** three field rects and the same bar width.
    func testTheThreeReadoutFieldsNeverMoveOrResize() throws {
        let (bar, controller, session, window) = try makeBar()
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())

        // 9520×6336 frame: [角度 0.0°] [比值 1.50] [像素 9520×6336].
        var snapshots: [(name: String, angle: NSRect, ratio: NSRect, pixels: NSRect, width: CGFloat)] = []
        var texts: [String] = []

        func record(_ name: String) {
            bar.sync()
            layOut(bar)
            texts.append(bar.readoutText.angle + "|" + bar.readoutText.ratio + "|" + bar.readoutText.pixels)
            snapshots.append((name, bar.angleFrame, bar.ratioFrame, bar.pixelFrame, bar.barWidth))
            print("D1 \(name): angle \(bar.angleFrame) · ratio \(bar.ratioFrame) · "
                  + "pixels \(bar.pixelFrame) · bar \(bar.barWidth) · text \(bar.readoutText)")
        }

        controller.setStraighten(0)
        record("full frame")
        controller.setStraighten(-45)
        record("−45.0°")
        controller.setStraighten(45)
        record("+45.0°")
        controller.setAspect(.sixteenNine)
        controller.setStraighten(3.5)
        record("16:9 @ +3.5°")
        // A tiny crop → the shortest pixel string, and a 1:1 lock → a short ratio.
        controller.setAspect(.square)
        controller.draft = CropToolController.Draft(crop: CropRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05),
                                                    straighten: 0, lock: .square)
        record("tiny 1:1")

        let first = try XCTUnwrap(snapshots.first)
        for shot in snapshots {
            XCTAssertEqual(shot.angle, first.angle, "§D1: 角度 field moved/resized at \(shot.name)")
            XCTAssertEqual(shot.ratio, first.ratio, "§D1: 比值 field moved/resized at \(shot.name)")
            XCTAssertEqual(shot.pixels, first.pixels, "§D1: 像素 field moved/resized at \(shot.name)")
            XCTAssertEqual(shot.width, first.width, accuracy: 0.001,
                           "§D1: the whole bar's width changed at \(shot.name)")
        }
        // …and it is *one* assertion of the invariant the task asks for: the width does not follow the
        // numbers. The texts above are different strings while the rects are identical.
        XCTAssertGreaterThan(Set(texts).count, 1, "the four drafts print different numbers")
        print("D1 · \(Set(texts).count) distinct readouts, all in \(snapshots.count) identical field rects")

        // No clipping: each field is at least its worst string plus the 2 pt headroom, and left-aligned.
        let worst = CropToolBar.infoWidths()
        XCTAssertGreaterThanOrEqual(first.angle.width, worst.angle)
        XCTAssertGreaterThanOrEqual(first.ratio.width, worst.ratio)
        XCTAssertGreaterThanOrEqual(first.pixels.width, worst.pixels)
        XCTAssertEqual(bar.angleControl.alignment, .left)
        XCTAssertLessThan(abs(worst.angle - (ceil(("-45.0°" as NSString)
            .size(withAttributes: [.font: CropToolBar.infoFont]).width) + CropToolBar.infoHeadroom)), 1e-6)

        // 比例 is gone, and no dots: the three fields are all the readout prints.
        let text = bar.readoutText
        XCTAssertFalse(text.angle.contains("·"))
        XCTAssertFalse(text.ratio.contains("·"))
        XCTAssertFalse(text.pixels.contains("·"))
        XCTAssertFalse(bar.sizeReadoutForTesting().contains("Original"), "§D1: the lock's name is deleted")
        XCTAssertEqual(controller.sizeReadout().split(separator: " ").count, 3)
    }

    // MARK: - D2

    /// Double-clicking 角度 returns it to 0.0°, writes nothing by itself, and the apply that follows is
    /// **one** history entry (not one for the reset and one for the crop).
    func testDoubleClickingTheAngleResetsItInOneStep() throws {
        let (bar, controller, session, window) = try makeBar()
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())
        controller.setStraighten(-17.5)
        layOut(bar)
        XCTAssertEqual(bar.readoutText.angle, "-17.5°")

        let historyBefore = session.history.snapshots.count
        let revisionBefore = session.editRevision
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 2, pressure: 1)!
        bar.angleControl.mouseDown(with: doubleClick)

        XCTAssertEqual(controller.draft.straighten, 0, accuracy: 1e-12, "§D2: double-click → 0.0°")
        XCTAssertEqual(bar.readoutText.angle, "+0.0°")
        XCTAssertEqual(session.editRevision, revisionBefore, "a draft reset writes nothing")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "and creates no snapshot")

        // A second double-click at 0 is a no-op (one value, not a second write).
        bar.angleControl.mouseDown(with: doubleClick)
        XCTAssertEqual(controller.draft.straighten, 0)

        // A 应用 whose only change is the reset is still an *unchanged* document: no snapshot.
        controller.setStraighten(-17.5)     // the angle the user had chosen before the reset
        bar.angleControl.mouseDown(with: doubleClick)
        XCTAssertEqual(controller.draft.straighten, 0)
        XCTAssertFalse(controller.apply(), "the reset alone leaves the document equal — nothing to commit")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)

        // Reset + a real crop change = exactly **one** entry (the reset did not add one of its own).
        XCTAssertTrue(controller.begin())
        controller.setStraighten(-17.5)
        bar.angleControl.mouseDown(with: doubleClick)
        controller.setAspect(.square)
        XCTAssertTrue(controller.apply())
        print("D2 · double-click → 0.0°, history \(historyBefore) → \(session.history.snapshots.count)")
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1,
                       "§D2: the reset + 应用 is ONE history entry")
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 0, accuracy: 1e-12)
    }

    // MARK: - D3

    /// On = the system accent, off = exactly the old appearance (both colour slots nil), and the three
    /// toggles refresh independently.
    func testTheThreeTogglesTurnAccentBlueOnlyWhenOn() throws {
        let (bar, controller, session, window) = try makeBar()
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())
        layOut(bar)

        // Default: grid on, both flips off.
        var grid = bar.toggleStyle("grid")
        var h = bar.toggleStyle("h")
        var v = bar.toggleStyle("v")
        XCTAssertTrue(grid.on)
        XCTAssertEqual(grid.bezel, NSColor.controlAccentColor, "§D3: on = 系统强调色")
        XCTAssertEqual(grid.tint, NSColor.white)
        for (name, style) in [("h", h), ("v", v)] {
            XCTAssertFalse(style.on, "\(name) starts off")
            XCTAssertNil(style.bezel, "§D3: off keeps the old style (no bezel colour)")
            XCTAssertNil(style.tint, "§D3: off keeps the old style (no content tint)")
        }

        // Flip 水平 only: it turns blue, 垂直 and 九宫格 do not move.
        controller.toggleFlipHorizontal()
        bar.sync()
        h = bar.toggleStyle("h")
        v = bar.toggleStyle("v")
        grid = bar.toggleStyle("grid")
        XCTAssertTrue(h.on)
        XCTAssertEqual(h.bezel, NSColor.controlAccentColor)
        XCTAssertNil(v.bezel, "§D3: the flips refresh independently")
        XCTAssertEqual(grid.bezel, NSColor.controlAccentColor)

        // 九宫格 off → back to the plain style; the flips are untouched.
        let hashBefore = CropUITestSupport.documentHash(session)
        let historyBefore = session.history.snapshots.count
        controller.toggleGrid()
        bar.sync()
        grid = bar.toggleStyle("grid")
        h = bar.toggleStyle("h")
        XCTAssertFalse(grid.on)
        XCTAssertNil(grid.bezel, "§D3: off is the old style again")
        XCTAssertNil(grid.tint)
        XCTAssertEqual(h.bezel, NSColor.controlAccentColor, "and the independent flip keeps its colour")
        // Pure view state: 九宫格 never reached the document or the history.
        XCTAssertEqual(CropUITestSupport.documentHash(session), hashBefore,
                       "§D3: 九宫格 is view state — nothing written")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)
        print("D3 · grid on \(grid.on) bezel \(String(describing: grid.bezel)) · "
              + "h on \(h.on) bezel \(String(describing: h.bezel)) · v on \(v.on) bezel \(String(describing: v.bezel))")
    }

    // MARK: - D4

    /// With the tool off, 应用/取消 are grey — the bar's two buttons **and** the menu's two items — and
    /// ⌘⏎ / ⌘. do nothing.
    func testApplyAndCancelAreDeadOutsideCropMode() throws {
        let (bar, controller, session, window) = try makeBar()
        defer { window.orderOut(nil) }
        layOut(bar)

        // Bar: no tool, nothing to apply.
        XCTAssertFalse(bar.applyControl.isEnabled, "§D4: 应用裁切 is grey in the default mode")
        XCTAssertFalse(bar.cancelControl.isEnabled, "§D4: 取消裁切 is grey in the default mode")

        // ⌘⏎ and ⌘. pressed on the canvas with no crop mode: nothing is written, nothing is counted.
        // A **second, real** editor window (its own session) so the drag-free assertions cannot borrow
        // the state of the bar's session above.
        let editor = EditorWindowController()
        let menu = MainMenu.build()
        func item(_ title: String) -> NSMenuItem? {
            var found: NSMenuItem?
            func walk(_ m: NSMenu) {
                for i in m.items {
                    if i.title == title { found = i }
                    if let sub = i.submenu { walk(sub) }
                }
            }
            walk(menu)
            return found
        }
        let applyItem = try XCTUnwrap(item("应用裁切"))
        let cancelItem = try XCTUnwrap(item("取消裁切"))
        XCTAssertFalse(editor.validateMenuItem(applyItem), "§D4: menu 应用裁切 is disabled by default")
        XCTAssertFalse(editor.validateMenuItem(cancelItem), "§D4: menu 取消裁切 is disabled by default")

        let editorRoot = try XCTUnwrap(editor.rootView)
        editorRoot.loupeController.autoRenderEnabled = false
        editorRoot.loupeController.collectsHistogram = false
        let editorSession = editor.session
        let before = CropUITestSupport.documentHash(editorSession)
        let historyBefore = editorSession.history.snapshots.count
        let canvas = editorRoot.loupeController.canvasView
        for key in ["\r", "."] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: key, charactersIgnoringModifiers: key,
                                         isARepeat: false, keyCode: 0)!
            canvas.keyDown(with: event)
        }
        print("D4 · bar apply/cancel enabled = \(bar.applyControl.isEnabled)/\(bar.cancelControl.isEnabled) · "
              + "menu(validated) = \(editor.validateMenuItem(applyItem))/\(editor.validateMenuItem(cancelItem)) · "
              + "applied \(editorRoot.loupeController.cropTool.appliedCount), "
              + "cancelled \(editorRoot.loupeController.cropTool.cancelledCount)")
        XCTAssertEqual(editorRoot.loupeController.cropTool.appliedCount, 0, "§D4: ⌘⏎ did nothing")
        XCTAssertEqual(editorRoot.loupeController.cropTool.cancelledCount, 0, "§D4: ⌘. did nothing")
        XCTAssertEqual(CropUITestSupport.documentHash(editorSession), before)
        XCTAssertEqual(editorSession.history.snapshots.count, historyBefore)

        // With the tool on, both come alive — which is what makes the greying above a gate, not a bug.
        XCTAssertTrue(controller.begin())
        bar.sync()
        XCTAssertTrue(bar.applyControl.isEnabled)
        XCTAssertTrue(bar.cancelControl.isEnabled)
    }
}

private extension CropToolBar {
    /// The whole readout as one line — the string §D1 says must not contain the lock's name.
    func sizeReadoutForTesting() -> String {
        let t = readoutText
        return "\(t.angle) \(t.ratio) \(t.pixels)"
    }
}
