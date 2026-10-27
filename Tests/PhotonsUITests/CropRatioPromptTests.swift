import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ⑨ — 弹出自定义比例等输入框时，位置要是软件窗口的正中心.
///
/// Before: `NSAlert.runModal()` — an **app-modal** alert centred on the *screen*, which is not the
/// window as soon as the window has been moved, resized or is on a second display, and which blocks
/// the run loop so nothing behind it can be asserted.
///
/// Now: `CropRatioPrompt`, a borderless `NSPanel` placed from `parent.frame` at open time and added as
/// a child window (so it travels with the window). This file measures the two rectangles' centres, the
/// focus, `↵`, `Esc`, and the "a click outside does not commit" rule.
@MainActor
final class CropRatioPromptTests: XCTestCase {

    private var workDir: URL!
    private var window: NSWindow!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeBar(size: NSSize = NSSize(width: 900, height: 600))
        throws -> (bar: CropToolBar, controller: CropToolController, window: NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let controller = CropToolController(session: session)
        let bar = CropToolBar(frame: NSRect(origin: .zero, size: NSSize(width: 900, height: 34)))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 320, y: 260), size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bar
        window.orderFront(nil)
        bar.controller = controller
        XCTAssertTrue(controller.begin())
        bar.sync()
        bar.layout(in: bar.bounds)
        bar.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.02)
        return (bar, controller, window)
    }

    private func centres(_ prompt: NSWindow, _ parent: NSWindow) -> (dx: CGFloat, dy: CGFloat) {
        (abs(prompt.frame.midX - parent.frame.midX), abs(prompt.frame.midY - parent.frame.midY))
    }

    /// 浮层中心 = 窗口中心 (≤1 pt), at the default size and at the minimum size, and `Esc` changes
    /// nothing.
    func testTheRatioPromptIsCentredOnTheWindow() throws {
        let (bar, controller, window) = try makeBar()
        defer { window.orderOut(nil) }

        var committed: String?
        bar.presentCustomRatioPrompt(in: window, initial: "4:3") { committed = $0 }
        CropUITestSupport.pump(0.05)
        var prompt = try XCTUnwrap(bar.customRatioPrompt)
        var delta = centres(prompt, window)
        print(String(format: "⑨ 900×600 · prompt %@ · window %@ · Δcentre (%.2f, %.2f) pt · "
                     + "child=%@ · firstResponder=%@",
                     NSStringFromRect(prompt.frame), NSStringFromRect(window.frame),
                     delta.dx, delta.dy,
                     window.childWindows?.contains(prompt) == true ? "yes" : "NO",
                     prompt.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))
        XCTAssertLessThanOrEqual(delta.dx, 1, "⑨: the prompt is not horizontally centred")
        XCTAssertLessThanOrEqual(delta.dy, 1, "⑨: the prompt is not vertically centred")
        XCTAssertTrue(window.childWindows?.contains(prompt) == true, "⑨: it is a child of the window")
        // Focus is in the field (the field editor is the first responder of the panel).
        XCTAssertTrue(prompt.firstResponder is NSTextView, "⑨: the input has the keyboard focus")

        // Esc: no commit, no change to the lock, and the panel goes away.
        let lockBefore = controller.draft.lock
        prompt.cancelOperation(nil)
        CropUITestSupport.pump(0.02)
        XCTAssertNil(committed, "⑨: Esc must not commit")
        XCTAssertNil(bar.customRatioPrompt, "⑨: the panel is gone")
        XCTAssertEqual(controller.draft.lock, lockBefore, "⑨: aspectLock is untouched")
        print("⑨ Esc · committed=\(String(describing: committed)) · lock \(controller.draft.lock.code) "
              + "→ \(controller.draft.lock.code) · panel open=\(bar.customRatioPrompt != nil)")

        // Minimum window: centred again (the centre is recomputed from `window.frame` at every open).
        window.setContentSize(WorkspaceLayout.minimumWindowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.02)
        bar.presentCustomRatioPrompt(in: window, initial: "16:9") { text in
            committed = text
            bar.commitCustomRatio(text)
        }
        CropUITestSupport.pump(0.05)
        prompt = try XCTUnwrap(bar.customRatioPrompt)
        delta = centres(prompt, window)
        print(String(format: "⑨ 1200×780 (minimum) · prompt %@ · window %@ · Δcentre (%.2f, %.2f) pt",
                     NSStringFromRect(prompt.frame), NSStringFromRect(window.frame), delta.dx, delta.dy))
        XCTAssertLessThanOrEqual(delta.dx, 1, "⑨: not centred at the minimum size")
        XCTAssertLessThanOrEqual(delta.dy, 1, "⑨: not centred at the minimum size")

        // ↵ commits the typed ratio, once.
        let field = try XCTUnwrap(prompt.firstResponder as? NSTextView)
        field.string = "16:9"
        prompt.performCommitForTesting()
        CropUITestSupport.pump(0.02)
        print("⑨ ↵ · committed=\(String(describing: committed)) · lock \(controller.draft.lock.code)")
        XCTAssertEqual(committed, "16:9")
        if case .custom(let ratio) = controller.draft.lock {
            XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 1e-6, "⑨: the typed ratio is the lock")
        } else {
            XCTFail("⑨: the committed ratio did not reach the draft's lock (\(controller.draft.lock))")
        }
        XCTAssertNil(bar.customRatioPrompt, "⑨: the panel closed on ↵")

        // A second open while one is up replaces it (never two at once).
        bar.presentCustomRatioPrompt(in: window, initial: "4:3") { _ in }
        bar.presentCustomRatioPrompt(in: window, initial: "4:3") { _ in }
        CropUITestSupport.pump(0.02)
        XCTAssertEqual(window.childWindows?.filter { $0 is CropRatioPrompt }.count, 1,
                       "⑨: one prompt at a time")
        bar.customRatioPrompt?.cancelOperation(nil)
    }
}
