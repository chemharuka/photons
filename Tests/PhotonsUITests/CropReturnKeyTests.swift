import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 2026-11-02 — 「在裁剪界面按回车没有应用更改」.
///
/// Three claims, each on the shipped path:
///
///   1. **entering the frame gives the canvas the keyboard** — `↵` / `Esc` are handled in
///      `LoupeCanvasView.keyDown`, and that view only sees a key while it is the first responder.
///      Before this, a click on the 变换 tab or anywhere in the 裁切 card could leave the focus on a
///      control beside the canvas and the key went nowhere.
///   2. **`↵` applies the draft wherever the focus is** — the window-level monitor the loupe installs
///      on `beginCropTool`, and removes the moment the frame closes.
///   3. **`↵` is only `↵`** — a modified return, another key, or no frame at all leaves the document
///      alone and lets the event through to whoever else wants it.
@MainActor
final class CropReturnKeyTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-return-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A loupe on a real window with an anchor and the baseline snapshot the first apply needs. No
    /// render: this suite is about the key, not the pixels.
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return (loupe, session, window)
    }

    private func returnKey(modifiers: NSEvent.ModifierFlags = [],
                           characters: String = "\r") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: 36)!
    }

    // MARK: - 1

    /// Opening the frame puts the canvas in front of the keyboard, so the shipped `keyDown` path is
    /// live without the user having to click the picture first.
    func testEnteringTheFrameFocusesTheCanvas() throws {
        let (loupe, session, window) = try makeLoupe()
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        pump(0.05)
        print("↵ · 进入裁切后 firstResponder = \(String(describing: window.firstResponder))")
        XCTAssertTrue(window.firstResponder === loupe.canvasView,
                      "进入裁切后画布必须拿到键盘，否则 ↵ 到不了 LoupeCanvasView.keyDown")
    }

    // MARK: - 2

    /// The key the user presses: `↵` with the focus **not** on the canvas still applies, once, through
    /// the same `TransformFinish.confirm` every other door uses, and the frame closes.
    func testReturnAppliesTheDraftWhereverTheFocusIs() throws {
        let (loupe, session, window) = try makeLoupe()
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        pump(0.05)
        // Put the keyboard somewhere that is not the canvas — the report's situation.
        window.makeFirstResponder(nil)

        // A draft that is worth writing: half the frame.
        loupe.cropTool.draft.crop = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        let before = session.history.snapshots.count

        XCTAssertTrue(loupe.handleCropReturn(returnKey()), "↵ 必须被裁切模式吃下")
        pump(0.05)

        XCTAssertFalse(loupe.cropTool.isActive, "↵ 之后裁切框应当关闭（= 已应用）")
        XCTAssertEqual(session.edit.geometry.cropRect.left, 0.25, accuracy: 1e-9, "↵ 必须写入草稿")
        XCTAssertEqual(session.edit.geometry.cropRect.right, 0.75, accuracy: 1e-9)
        XCTAssertEqual(session.history.snapshots.count, before + 1, "一次 ↵ = 一条历史")
        print("↵ · 应用后 crop = \(session.edit.geometry.cropRect) · history \(before) → \(session.history.snapshots.count)")
    }

    /// Keypad Enter is the same key (`\u{3}`), and it carries `.numericPad`.
    func testKeypadEnterAppliesToo() throws {
        let (loupe, session, _) = try makeLoupe()
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        pump(0.05)
        XCTAssertTrue(loupe.handleCropReturn(returnKey(modifiers: .numericPad, characters: "\u{3}")))
        XCTAssertFalse(loupe.cropTool.isActive, "小键盘 Enter 与 ↵ 同一个键")
    }

    // MARK: - 3

    /// `⌘↵`, another key, and the tool being off all leave the event to the rest of the app.
    func testTheBindingIsOnlyABareReturnWhileTheFrameIsUp() throws {
        let (loupe, session, _) = try makeLoupe()
        XCTAssertFalse(loupe.handleCropReturn(returnKey()), "裁切框没开时不许吃 ↵")

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        pump(0.05)
        XCTAssertFalse(loupe.handleCropReturn(returnKey(modifiers: .command)), "⌘↵ 不是应用")
        XCTAssertFalse(loupe.handleCropReturn(returnKey(characters: "x")), "别的键不是应用")
        XCTAssertFalse(loupe.handleCropReturn(returnKey(characters: "\u{1b}")), "Esc 走它自己那条路")
        XCTAssertTrue(loupe.cropTool.isActive, "上面几下都不许关掉裁切框")
    }

    /// The monitor that makes claim 2 true exists only while the frame is up — a leaked one would let
    /// `↵` apply a frame that is not on screen (or keep the loupe alive for ever).
    func testTheKeyMonitorLivesExactlyAsLongAsTheFrame() throws {
        let (loupe, session, _) = try makeLoupe()
        XCTAssertFalse(loupe.hasCropReturnMonitorForTesting)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        pump(0.05)
        XCTAssertTrue(loupe.hasCropReturnMonitorForTesting, "进入裁切必须装上窗口级 ↵ 监听")
        loupe.cancelCropTool()
        pump(0.05)
        XCTAssertFalse(loupe.hasCropReturnMonitorForTesting, "离开裁切必须拆掉监听")
    }
}
