import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 「渐变的两个蒙版都添加不了了」 (2026-10-30, 在线) — the **whole chain** from the 新建 menu to a mask
/// in the document, in the order the app walks it:
///
///   1. the menu calls `session.createMask(.linearGradient / .radialGradient)` and the session **arms**
///      the next drag (`pendingMaskShape`, draft state — the mask itself is not created yet);
///   2. the loupe **publishes** that arm to the canvas (`isShapeDragArmed`) and the click at any point
///      belongs to `.maskCreate` (`gestureOwner`, the pure hit test `LoupeCanvasView.mouseDown`
///      switches on);
///   3. the drag is **consumed**: `beginShapeDrag` → `continueShapeDrag` → `endShapeDrag(at:)` writes
///      one mask with the geometry the hand drew (`addShapeMask`, one commit).
///
/// Each step is asserted separately, so a break can be named: an arming that never happens, an arm the
/// canvas cannot see, or a gesture that is armed and then dropped. The existing coverage does not see
/// the whole path — `UISmokeRunner` (§10.1/§10.2) drives it with synthesised `NSEvent`s, which only
/// runs in `--ui-smoke`, not in `swift test`.
@MainActor
final class MaskGradientAddTests: XCTestCase {

    /// The frame source's viewport (device pixels) for a 320×200 pt window at backing scale 2 — the
    /// same numbers `MaskOverlayFollowTests` uses, so the projection is the shipped one.
    private static let viewport = ImageSize(width: 640, height: 400)

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-mask-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    /// A clean session with one anchored photo and a real sized canvas. No RAW is decoded: `framing()`
    /// answers from the catalog row, which is exactly what the mask maths is expressed against
    /// (`maskSourceSize`), so the gesture is measured on the same frame the app uses before a decode.
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        // The 蒙版 workspace: the chrome's owner, and the state the user is in when they pick 新建.
        loupe.setMasksWorkspaceActive(true)
        XCTAssertNotNil(session.anchorAsset, "no anchor — the 新建 menu is disabled in this state")
        return (loupe, session)
    }

    private func centre(_ loupe: LoupeController) -> CGPoint {
        CGPoint(x: loupe.canvasView.bounds.midX, y: loupe.canvasView.bounds.midY)
    }

    /// `begin → continue → end` at two real canvas points — what `LoupeCanvasView` calls for
    /// mouseDown / mouseDragged / mouseUp once `gestureOwner` said `.maskCreate`.
    @discardableResult
    private func drag(_ loupe: LoupeController,
                      from a: CGPoint = CGPoint(x: 90, y: 70),
                      to b: CGPoint = CGPoint(x: 230, y: 140)) -> Int {
        loupe.beginShapeDrag(at: a)
        loupe.continueShapeDrag(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        loupe.continueShapeDrag(at: b)
        loupe.endShapeDrag(at: b)
        return loupe.shapeDragsCreated
    }

    // MARK: - ① the menu arms the drag

    func testTheMenuArmsBothGradients() throws {
        let (loupe, session) = try makeLoupe()
        let point = centre(loupe)

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            session.pendingMaskShape = nil
            let created = session.createMask(kind)

            XCTAssertNil(created, "\(kind.label) must not create a mask before the drag")
            XCTAssertEqual(session.pendingMaskShape, kind, "\(kind.label) did not arm the drag")
            XCTAssertTrue(session.edit.masks.isEmpty, "\(kind.label) wrote a mask before the gesture")
            XCTAssertTrue(loupe.isShapeDragArmed,
                          "\(kind.label) is armed in the session but the canvas does not see it")
            XCTAssertEqual(loupe.gestureOwner(atViewPoint: point), .maskCreate,
                           "a click at \(point) does not belong to \(kind.label)'s creation")
        }
    }

    // MARK: - ③ the whole view path: real mouse events on the real canvas

    /// The click arrives as an `NSEvent` through `LoupeCanvasView.mouseDown/Dragged/Up` — the same
    /// functions the window calls — so this also covers 「the arm is published but the view drops it」.
    func testRealMouseEventsCreateTheGradient() throws {
        let (loupe, session) = try makeLoupe()
        let canvas = loupe.canvasView
        let window = windows[0]
        let bounds = canvas.bounds

        func post(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) {
            guard let event = NSEvent.mouseEvent(with: type,
                                                 location: canvas.convert(point, to: nil),
                                                 modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber,
                                                 context: nil,
                                                 eventNumber: number,
                                                 clickCount: 1,
                                                 pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            let before = session.edit.masks.count
            session.createMask(kind)
            let a = CGPoint(x: bounds.width * 0.28, y: bounds.height * 0.30)
            let b = CGPoint(x: bounds.width * 0.74, y: bounds.height * 0.68)
            post(.leftMouseDown, a, 0)
            for step in 1...10 {
                let t = CGFloat(step) / 10
                post(.leftMouseDragged,
                     CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), step)
            }
            post(.leftMouseUp, b, 11)

            XCTAssertEqual(session.edit.masks.count, before + 1,
                           "\(kind.label): mouse events created no mask "
                           + "(armed=\(loupe.isShapeDragArmed) refused=\(loupe.shapeDragsRefused) "
                           + "owner=\(loupe.gestureOwner(atViewPoint: a)))")
            XCTAssertEqual(session.edit.masks.last?.components.first?.shape.kind, kind.shapeKind,
                           "\(kind.label): wrong shape")
        }
    }

    // MARK: - ④ 修复 (heal) stays armed and outranks the creation

    /// The reported symptom exactly: 新建 → 线性/径向渐变 **arms** (the menu works, the pointer turns
    /// into a crosshair), and then the drag creates **nothing** — because the 修复 button at the top of
    /// the same card is a sticky toggle (`session.healTool.toggle()`, and `addHealSpot` deliberately
    /// leaves it armed), and `gestureOwner` puts `.healClick` **above** `.maskCreate`.
    ///
    /// So the click the user aimed at the gradient places a heal spot instead, `pendingMaskShape`
    /// stays armed, and neither gradient can be added until 修复 is pressed off. Nothing in the arm
    /// path (`createMask`) or the document path is broken; the gesture is simply taken by a tool the
    /// user armed earlier and no longer remembers.
    func testTheHealToolMustNotEatTheArmedGradientDrag() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true                     // the sticky 修复 toggle, left on

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            let before = session.edit.masks.count
            session.createMask(kind)
            XCTAssertEqual(loupe.gestureOwner(atViewPoint: centre(loupe)), .maskCreate,
                           "\(kind.label): the armed drag belongs to \(loupe.gestureOwner(atViewPoint: centre(loupe)))"
                           + " instead of the creation (healTool=\(session.healTool))")
            drag(loupe)
            XCTAssertEqual(session.edit.masks.count, before + 1,
                           "\(kind.label): no mask — the click went to 修复")
        }
    }

    /// The same class, second member: the 亮度/颜色 吸管 is armed `staysArmed: true` (the mask panel's
    /// own buttons), so it too sits above the creation in `gestureOwner` and eats the drag.
    func testAStickyEyedropperMustNotEatTheArmedGradientDrag() throws {
        let (loupe, session) = try makeLoupe()
        loupe.armEyedropper(staysArmed: true) { _, _ in }

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            let before = session.edit.masks.count
            session.createMask(kind)
            XCTAssertEqual(loupe.gestureOwner(atViewPoint: centre(loupe)), .maskCreate,
                           "\(kind.label): the armed drag belongs to "
                           + "\(loupe.gestureOwner(atViewPoint: centre(loupe))) — the 吸管 is still armed")
            drag(loupe)
            XCTAssertEqual(session.edit.masks.count, before + 1,
                           "\(kind.label): no mask — the click went to the 吸管")
        }
    }

    // MARK: - ② the drag becomes a mask

    func testDraggingTheCanvasCreatesBothGradients() throws {
        let (loupe, session) = try makeLoupe()

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            let before = session.edit.masks.count
            let depth = session.history.count
            let dragsBefore = loupe.shapeDragsCreated
            session.createMask(kind)
            XCTAssertEqual(loupe.gestureOwner(atViewPoint: centre(loupe)), .maskCreate,
                           "\(kind.label): the armed click is not the canvas'")

            drag(loupe)

            XCTAssertEqual(session.edit.masks.count, before + 1,
                           "\(kind.label): the drag created no mask (refused \(loupe.shapeDragsRefused))")
            XCTAssertEqual(loupe.shapeDragsCreated, dragsBefore + 1, "\(kind.label): shapeDragsCreated")
            XCTAssertEqual(session.edit.masks.last?.components.first?.shape.kind, kind.shapeKind,
                           "\(kind.label): the mask is not the shape the menu offered")
            XCTAssertEqual(session.history.count, depth + 1,
                           "\(kind.label): one gesture must be one ⌘Z")
            XCTAssertNil(session.pendingMaskShape, "\(kind.label): the arm must not survive the gesture")
        }
    }

    /// 建完一个渐变后，粘滞的「修复」不许活下来——否则下一次点击又被它吃掉（§3 追加断言）。
    func testCreatingAGradientClearsTheStickyHealTool() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true

        for kind in [MaskCreationKind.linearGradient, .radialGradient] {
            session.createMask(kind)
            XCTAssertFalse(session.healTool,
                           "\(kind.label): the sticky 修复 arm survived the 新建 choice")
            XCTAssertEqual(loupe.gestureOwner(atViewPoint: centre(loupe)), .maskCreate,
                           "\(kind.label): the armed drag does not belong to the creation")
            drag(loupe)
            XCTAssertEqual(session.edit.masks.last?.components.first?.shape.kind, kind.shapeKind)
            XCTAssertFalse(session.healTool, "\(kind.label): 修复 came back after the gesture")
            XCTAssertNotEqual(loupe.gestureOwner(atViewPoint: centre(loupe)), .healClick,
                              "\(kind.label): 修复 owns the click again after the mask exists")
        }
    }
}
