import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 415 — canvas double-click zoom: **only the even press of a click chain counts**.
///
/// The report:
/// > 对画面连续点击三次，会出现放大动画然后立刻跳回适应，如果双击+等200ms再双击，
/// > 则会在放大动画后触发缩回动画，然后跳回放大画面。
///
/// The cause was one character class: `gestureOwner` answered `.doubleClick` for `clickCount >= 2`,
/// while `handleDoubleClick` is a **stateless toggle** (actual ⇄ fit). N presses therefore produced
/// N−1 actions: 3 clicks = zoom in then straight back to fit.
///
/// What is pinned here, from the pure router up to the shipped dispatch:
///
///   1. the parity law in `LoupeController.gestureOwner` — 1 pan, **2 zoom**, **3 pan**, 4 zoom,
///      5 pan, 6 zoom;
///   2. the consequence a user sees: `1,2,3` is **one** zoom action ending at 1:1, `1,2,3,4` is
///      **two** actions ending back at 适应;
///   3. a chain that restarts at 1 (`clickCount` reset by the pause) still zooms — the parity law
///      adds no state and no interval constant;
///   4. the crop tool's `>= 2` rule is **untouched** (it is not a toggle, so parity must not reach it);
///   5. the same route through a real `NSEvent` handed to `LoupeCanvasView.mouseDown`.
///
/// ⚠ AppKit's own chain reset (`NSEvent.doubleClickInterval`) is *not* exercised: a synthesised
/// event carries whatever `clickCount` the test puts in it. Test ⑤ drives our consumption of that
/// number; only a real hand on a real window could prove the window server restarts it at 1.
@MainActor
final class DoubleClickParity415Tests: XCTestCase {

    private static let source = (width: 3000, height: 2000)
    private static let canvas = NSSize(width: 900, height: 600)
    private static let centre = CGPoint(x: 450, y: 300)

    private var workDir: URL!
    private var windows: [NSWindow] = []
    /// `LoupeController.session` is weak: the fixture must outlive the controller.
    private var sessions: [CatalogSession] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-click415-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        sessions.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func makeLoupe() throws -> LoupeController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        sessions.append(session)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        // The animation is not under test; the state it lands on is.
        loupe.reducesMotion = true
        let window = TestWindows.make(contentRect: NSRect(origin: NSPoint(x: 200, y: 200),
                                                          size: Self.canvas),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        loupe.view.layoutSubtreeIfNeeded()
        windows.append(window)
        CropUITestSupport.pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while loupe.framing() == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        XCTAssertNotNil(loupe.framing(), "the loupe never got a projection")
        return loupe
    }

    /// One press of a chain, exactly as `LoupeCanvasView.mouseDown` spends it: ask the router, and
    /// only a `.doubleClick` answer calls the verb. Returns whether an action ran.
    @discardableResult
    private func press(_ clickCount: Int, on loupe: LoupeController,
                       at point: CGPoint = DoubleClickParity415Tests.centre) -> Bool {
        let owner = loupe.gestureOwner(atViewPoint: point, clickCount: clickCount)
        if owner == .doubleClick {
            loupe.handleDoubleClick(at: point)
            return true
        }
        return false
    }

    /// A whole chain `1…n` spent through the router; the return value is the **action count**.
    private func chain(_ counts: [Int], on loupe: LoupeController,
                       at point: CGPoint = DoubleClickParity415Tests.centre) -> Int {
        counts.reduce(0) { actions, count in
            actions + (press(count, on: loupe, at: point) ? 1 : 0)
        }
    }

    // MARK: - ① the pure rule: only the even press is a double-click

    func testThreeClicksInOneChainAreMistakenForADoubleClick() {
        let loupe = LoupeController(session: CatalogSession())
        let point = CGPoint(x: 100, y: 100)

        let owners = (1 ... 6).map { loupe.gestureOwner(atViewPoint: point, clickCount: $0) }
        print("415 ① gestureOwner for clickCount 1…6: "
              + owners.map { String(describing: $0) }.joined(separator: ", "))

        XCTAssertEqual(owners[0], .pan, "1: a single press never zooms")
        XCTAssertEqual(owners[1], .doubleClick, "2: the double-click zooms in")
        XCTAssertEqual(owners[2], .pan,
                       "3: the third press of the chain is a mis-touch — it must NOT toggle back")
        XCTAssertEqual(owners[3], .doubleClick, "4: 2 + 2 zooms in again")
        XCTAssertEqual(owners[4], .pan, "5: odd, ignored")
        XCTAssertEqual(owners[5], .doubleClick, "6: even, fires")
    }

    // MARK: - ② what the user sees: 3 clicks = one action, 4 clicks = two

    func testThreeClicksProduceExactlyOneZoomAction() throws {
        let loupe = try makeLoupe()

        // 1,2,3 — one action, and it lands at 1:1 (not back at fit).
        loupe.zoomToFit()
        XCTAssertEqual(loupe.viewState.mode, .fit, "the chain starts from 适应")
        let three = chain([1, 2, 3], on: loupe)
        XCTAssertEqual(three, 1, "three presses must produce exactly one zoom action")
        XCTAssertTrue(loupe.viewState.isActualSize,
                      "…and the picture stays at 1:1 — no 「跳回适应」 after the third press")

        // 1,2,3,4 — two actions, ending back at fit.
        loupe.zoomToFit()
        XCTAssertEqual(loupe.viewState.mode, .fit)
        let four = chain([1, 2, 3, 4], on: loupe)
        XCTAssertEqual(four, 2, "four presses are two double-clicks")
        XCTAssertFalse(loupe.viewState.isActualSize,
                       "2 + 2 = 放大又退回适应 — the fourth press toggles back")
        XCTAssertEqual(loupe.viewState.mode, .fit)

        print("415 ② actions · 1,2,3 → \(three) 次，终态 1:1；1,2,3,4 → \(four) 次，终态 适应")
    }

    // MARK: - ③ a chain that restarts still zooms (no counter, no interval)

    func testAClickAfterTheChainResetsStillZoomsIn() throws {
        let loupe = try makeLoupe()
        loupe.zoomToFit()

        // The first chain: fit → 1:1 on its second press.
        XCTAssertEqual(chain([1, 2], on: loupe), 1)
        XCTAssertTrue(loupe.viewState.isActualSize, "第一段双击：放大")

        // The pause has passed, so AppKit restarts the count at 1: a fresh chain is another
        // double-click, and it toggles back to 适应 — the reset really does re-arm the gesture.
        XCTAssertEqual(chain([1, 2], on: loupe), 1,
                       "停顿后的新链仍然是完整的一次双击")
        XCTAssertFalse(loupe.viewState.isActualSize,
                       "第二段双击：缩回适应")
        XCTAssertEqual(loupe.viewState.mode, .fit)

        // …and a third reset chain zooms in again, so nothing was consumed or latched.
        XCTAssertEqual(chain([1, 2], on: loupe), 1)
        XCTAssertTrue(loupe.viewState.isActualSize)
        print("415 ③ reset chains 1,2 → 1,2 → 1,2: actions 1 / 1 / 1, state 适应 → 1:1 → 适应 → 1:1")
    }

    // MARK: - ④ the crop tool's rule is not a toggle, so parity must not touch it

    /// `LoupeCanvasGesture.crop` is **not** parity-ruled: applying a crop leaves crop mode, so a
    /// third press never reaches it (`gestureOwner` is gated on `isCropToolActive`). At the pure
    /// function level it still answers `.cropToolApply` for every count ≥ 2, and this assertion
    /// exists to pin that we did **not** "helpfully" change it in 415.
    func testACropToolClickIsUnchangedByTheParityRule() {
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .inside), .cropToolApply,
                       "双击框内 = 应用裁切（415 不改）")
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 3, hit: .inside), .cropToolApply,
                       "裁切路径不适用奇偶律：纯函数层对 3 仍返回 apply —— 但真实第三下已离开裁切模式")
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 4, hit: .inside), .cropToolApply)
        // And the rest of the crop split is untouched: only `.inside` applies.
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .topLeft), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .outside), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: nil), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 1, hit: .inside), .cropTool)
    }

    // MARK: - ⑤ the same chain through a real NSEvent and `mouseDown`

    /// Drives the shipped dispatch (`LoupeCanvasView.mouseDown` → `gestureOwner` → the verb) with
    /// real `NSEvent`s carrying clickCount 1…4. This is the routing half of the parity law; the
    /// window server's own chain reset cannot be synthesised (see the file header).
    func testARealEventChainThroughMouseDownZoomsOnceForThreePresses() throws {
        let loupe = try makeLoupe()
        let window = try XCTUnwrap(windows.last)
        let canvas = loupe.canvasView

        func event(_ type: NSEvent.EventType, clickCount: Int) -> NSEvent {
            CropUITestSupport.mouse(type, at: canvas.convert(Self.centre, to: nil), in: window,
                                    clickCount: clickCount)
        }

        func spend(_ counts: [Int]) {
            for count in counts {
                canvas.mouseDown(with: event(.leftMouseDown, clickCount: count))
                canvas.mouseUp(with: event(.leftMouseUp, clickCount: count))
                CropUITestSupport.pump(0.01)
            }
        }

        loupe.zoomToFit()
        spend([1, 2, 3])
        XCTAssertTrue(loupe.viewState.isActualSize, "1,2,3 经真实事件：停在 1:1")
        XCTAssertEqual(loupe.viewState.mode, .actual)
        let threeState = loupe.viewState

        loupe.zoomToFit()
        spend([1, 2, 3, 4])
        XCTAssertEqual(loupe.viewState.mode, .fit, "1,2,3,4 经真实事件：回到适应")
        XCTAssertNotEqual(loupe.viewState, threeState)

        print("415 ⑤ 真实 NSEvent × mouseDown：1,2,3 → \(threeState.mode.rawValue)，"
              + "1,2,3,4 → \(loupe.viewState.mode.rawValue)")
    }
}
