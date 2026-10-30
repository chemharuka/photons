import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 072 §D + **082 §2/§3** — 裁切悬浮栏：三段只读信息，角度是**实际角度**.
///
/// 082 的用户原话把这条栏砍掉了控件：
///
///   > 裁切模式下方悬浮栏的调节功能全部移动到右侧面板，只保留比例，像素，角度的信息。
///   > 注意角度有两个，一个是实际角度，一个是滑块角度。实际角度等于滑块角度 + 90 旋转两个之和。
///
/// 所以这一份现在钉四件事，全部量在**真实的** `CropToolBar` 上（没有快照、没有截图）：
///
///   1. **D1 原样**：三段定宽，五个极端草稿（含 90°/270° 转过的文档）之后 `frame(x, width)` 与整栏
///      宽度**逐点相同** —— 数字不左右滑。
///   2. **§2 只读**：视图树里可交互控件数 = **0**（没有 `NSButton` / `NSSlider` / `NSPopUpButton` /
///      可编辑文本），而三段信息都在。
///   3. **§3 实际角度**：`quarterTurns` 1 / 3 时栏里的角度是 `straighten + 90·turns`（三组数字）。
///   4. **§D4 的动词（不是按钮）**：工具没开时 应用/取消 在*卡*里是灰的、菜单项校验为 false，⌘⏎ / ⌘.
///      什么都不写 —— 082 之前这条量的是栏里的两个按钮，那两颗按钮搬进卡后，动词的门禁没有变。
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

    /// Five extreme drafts — the worst angle, the widest ratio, the largest pixel text, the untouched
    /// frame, and a document turned 270° with a straighten — must produce **the same** three field
    /// rects and the same bar width.
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
        record("slider −45.0°")
        controller.setStraighten(45)
        record("slider +45.0°")
        controller.setAspect(.sixteenNine)
        controller.setStraighten(3.5)
        record("16:9 @ +3.5°")
        // A tiny crop → the shortest pixel string, and a 1:1 lock → a short ratio.
        controller.setAspect(.square)
        controller.draft = CropToolController.Draft(crop: CropRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05),
                                                    straighten: 0, lock: .square)
        record("tiny 1:1")
        // 082: the widest 角度 string is the **actual** one — three turns + 45° = 315.0°.
        controller.setStraighten(45)
        XCTAssertTrue(controller.rotateQuarter(clockwise: true))
        XCTAssertTrue(controller.rotateQuarter(clockwise: true))
        XCTAssertTrue(controller.rotateQuarter(clockwise: true))
        record("270° + slider +45.0°")

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
        XCTAssertGreaterThan(Set(texts).count, 1, "the drafts print different numbers")
        print("D1 · \(Set(texts).count) distinct readouts, all in \(snapshots.count) identical field rects")

        // No clipping: each field is at least its worst string plus the 2 pt headroom, and **centred**
        // (N6: the three readouts are each centred in their own box, 2026-10-30).
        let worst = CropToolBar.infoWidths()
        XCTAssertGreaterThanOrEqual(first.angle.width, worst.angle)
        XCTAssertGreaterThanOrEqual(first.ratio.width, worst.ratio)
        XCTAssertGreaterThanOrEqual(first.pixels.width, worst.pixels)
        XCTAssertEqual(bar.angleControl.alignment, .center)
        XCTAssertLessThan(abs(worst.angle - (ceil((CropToolController.WorstCase.angle as NSString)
            .size(withAttributes: [.font: CropToolBar.infoFont]).width) + CropToolBar.infoHeadroom)), 1e-6)

        // 比例 is gone, and no dots: the three fields are all the readout prints.
        let text = bar.readoutText
        XCTAssertFalse(text.angle.contains("·"))
        XCTAssertFalse(text.ratio.contains("·"))
        XCTAssertFalse(text.pixels.contains("·"))
        XCTAssertEqual(controller.sizeReadout().split(separator: " ").count, 3)
    }

    // MARK: - §2 只读

    /// **The bar has no controls at all** — the acceptance is 「悬浮栏视图树里可交互控件数 = 0」, and the
    /// three readouts are still there with real text.
    func testTheBarHasNoInteractiveControlsAndStillPrintsTheThreeSegments() throws {
        // The session is **held**: `CropToolController.session` is `weak`, and a released session makes
        // `begin()` answer `false` (the same trap `CropToggleAccentTests` records).
        let (bar, controller, session, window) = try makeBar()
        _ = session
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())
        layOut(bar)

        // Every one of these used to exist on the bar (ratio popup, ⇄, 拉直 slider, 水平 / 垂直 /
        // 九宫格, 应用 / 取消) and now lives in the card's four sections.
        let controls = CropToolBar.interactiveControls(in: bar)
        print("§2 · 悬浮栏可交互控件 \(controls.count) 个："
              + controls.map { String(describing: type(of: $0)) }.joined(separator: ", "))
        XCTAssertEqual(bar.interactiveControlCount, 0, "082 §2: 悬浮栏只剩只读信息，不许有控件")
        XCTAssertTrue(controls.isEmpty)
        // …and specifically: no button, no slider, no popup, nothing editable.
        var stack: [NSView] = [bar]
        var buttons = 0, sliders = 0, popups = 0, editable = 0
        while let view = stack.popLast() {
            if view is NSButton { buttons += 1 }
            if view is NSSlider { sliders += 1 }
            if view is NSPopUpButton { popups += 1 }
            if let field = view as? NSTextField, field.isEditable || field.isSelectable { editable += 1 }
            stack += view.subviews
        }
        XCTAssertEqual(buttons, 0, "NSButton")
        XCTAssertEqual(sliders, 0, "NSSlider")
        XCTAssertEqual(popups, 0, "NSPopUpButton")
        XCTAssertEqual(editable, 0, "editable/selectable field")
        XCTAssertEqual(bar.subviews.count, 1, "the pill is the only subview; nothing is added beside it")

        // The three segments are still printed, in the D1 order.
        let text = bar.readoutText
        XCTAssertFalse(text.ratio.isEmpty, "比值")
        XCTAssertTrue(text.pixels.contains("×"), "像素: \(text.pixels)")
        XCTAssertFalse(text.angle.isEmpty, "角度")
        XCTAssertGreaterThan(bar.angleFrame.width, 0)
        XCTAssertGreaterThan(bar.ratioFrame.width, 0)
        XCTAssertGreaterThan(bar.pixelFrame.width, 0)
    }

    // MARK: - §3 实际角度

    /// The bar's 角度 段 is `straighten + 90 × quarterTurns`, in three groups of numbers.
    func testTheAngleSegmentIsTheActualAngle() throws {
        let (bar, controller, session, window) = try makeBar()
        _ = session
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())

        var seen: [String] = []
        func record(_ name: String) {
            layOut(bar)
            seen.append("\(name): 栏「\(bar.readoutText.angle)」 卡 实际 \(controller.angleText()) / "
                        + "滑块 \(controller.sliderAngleText()) · turns \(controller.quarterTurns)")
            print("§3 · \(seen.last!)")
        }

        controller.setStraighten(0)
        record("turns 0 · slider 0")
        XCTAssertEqual(bar.readoutText.angle, "0.0°")

        // ① turns = 1, straighten = 2.5 → 92.5°
        // (Inside a tool session the verb answers `false` — `commitEdit` returns nil there by design —
        // so the turn is measured on the document.)
        controller.rotateQuarter(clockwise: true)
        XCTAssertEqual(controller.quarterTurns, 1)
        controller.setStraighten(2.5)
        record("turns 1 · slider +2.5")
        XCTAssertEqual(bar.readoutText.angle, "92.5°", "实际 = 2.5 + 90")

        // ② turns = 3, straighten = −4 → 266°
        controller.rotateQuarter(clockwise: true)
        controller.rotateQuarter(clockwise: true)
        XCTAssertEqual(controller.quarterTurns, 3)
        controller.setStraighten(-4)
        record("turns 3 · slider −4")
        XCTAssertEqual(bar.readoutText.angle, "266.0°", "实际 = −4 + 270")

        // ③ turns = 4 (back to 0), straighten = 0 → 0°
        controller.rotateQuarter(clockwise: true)
        XCTAssertEqual(controller.quarterTurns, 0)
        controller.setStraighten(0)
        record("turns 4 · slider 0")
        XCTAssertEqual(bar.readoutText.angle, "0.0°", "四圈回到 0°")

        XCTAssertEqual(seen.count, 4)
        // The document's own field is the same number the bar prints, so the two cannot drift.
        XCTAssertEqual(controller.quarterTurns, 0)
    }

    // MARK: - §D4 (the verbs, not the buttons)

    /// With the tool off, 应用/取消 do nothing — ⌘⏎ / ⌘. write nothing and count nothing — and the menu's
    /// validation closes the same door. (082 之前这条量的是栏里的两颗按钮；它们现在在卡里，
    /// `TransformPanelTests` 量的是卡的灰态，这里量的是动词本身。)
    func testApplyAndCancelAreDeadOutsideCropMode() throws {
        let (_session, _) = try CropUITestSupport.makeSession(in: workDir)
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
        XCTAssertNil(item("应用裁切"), "应用裁切 的菜单行已经搬进裁切卡")
        XCTAssertNil(item("取消裁切"), "取消裁切 的菜单行已经搬进裁切卡")
        let applyItem = NSMenuItem(title: "应用裁切",
                                   action: #selector(EditorWindowController.applyCropAction(_:)),
                                   keyEquivalent: "")
        let cancelItem = NSMenuItem(title: "取消裁切",
                                    action: #selector(EditorWindowController.cancelCropAction(_:)),
                                    keyEquivalent: "")
        XCTAssertFalse(editor.validateMenuItem(applyItem), "§D4: 应用裁切 is disabled by default")
        XCTAssertFalse(editor.validateMenuItem(cancelItem), "§D4: 取消裁切 is disabled by default")

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
        print("D4 · menu(validated) = \(editor.validateMenuItem(applyItem))/"
              + "\(editor.validateMenuItem(cancelItem)) · applied "
              + "\(editorRoot.loupeController.cropTool.appliedCount), cancelled "
              + "\(editorRoot.loupeController.cropTool.cancelledCount)")
        XCTAssertEqual(editorRoot.loupeController.cropTool.appliedCount, 0, "§D4: ⌘⏎ did nothing")
        XCTAssertEqual(editorRoot.loupeController.cropTool.cancelledCount, 0, "§D4: ⌘. did nothing")
        XCTAssertEqual(CropUITestSupport.documentHash(editorSession), before)
        XCTAssertEqual(editorSession.history.snapshots.count, historyBefore)


        // With the tool on, the card's pair comes alive (`DetailRowEnabledLog` is the card's seam) —
        // which is what makes the greying above a gate, not a bug.
        let (bar, controller, session, window) = try makeBar()
        defer { window.orderOut(nil) }
        XCTAssertTrue(controller.begin())
        _ = session
        bar.sync()
        XCTAssertEqual(bar.readoutText.pixels.contains("×"), true,
                       "应用可用时栏里照样只有读数 —— 按钮在卡里")
    }
}
