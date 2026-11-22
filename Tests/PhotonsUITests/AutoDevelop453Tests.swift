import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 453 — 「自动调整」= 黑电平 + 明暗 + 自动颜色, **one** press / **one** history row.
///
/// The order is fixed (黑电平 → 明暗 → 颜色): `AutoLight.plan` step 4 reads `light.blackOffset` to
/// cancel its lift, so 明暗 must measure the document that already carries the new floor. The
/// candidates are measured on staged copies and written together, so no intermediate document is
/// ever committed.
///
/// The full-rung gate is 448's, reused unchanged: a click before the anchor's full RAW frame queues
/// `.all` and writes nothing; the frame that lands runs the whole verb exactly once.
@MainActor
final class AutoDevelop453Tests: XCTestCase {

    private static let viewport = ImageSize(width: 1024, height: 768)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixture

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeController(url: URL, identity: String,
                                session: CatalogSession) -> LoupeController {
        session.mode = .loupe
        let controller = LoupeController(session: session)
        controller.autoRenderEnabled = true
        controller.collectsHistogram = false
        controller.frameSource = LoupeController.FrameSource(
            url: url, identity: identity, viewport: Self.viewport, state: .fit)
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.scheduleRender()
        return controller
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func waitForPreview(_ loupe: LoupeController) -> Bool {
        waitFor {
            loupe.currentPresentedPhotoForTesting != nil
                && loupe.lastPresentedScale == DecodeLadder.previewScale
        }
    }

    private func waitForFull(_ loupe: LoupeController, photo: String) -> Bool {
        waitFor {
            loupe.currentPresentedPhotoForTesting == photo
                && loupe.lastPresentedScale == DecodeLadder.fullScale
                && loupe.frameScaleForTesting == Double(DecodeLadder.fullScale)
        }
    }

    // MARK: - ① one press = one history row, all three verbs inside it

    func testOnePressIsOneHistoryRowWithBlackAndColorMoved() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "453-one", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "453-one"), "the full rung never reached the canvas")

        let before = session.edit
        let historyBefore = session.history.count
        XCTAssertTrue(loupe.autoDevelop(), "a settled full frame must produce a plan")
        XCTAssertEqual(session.history.count, historyBefore + 1,
                       "黑电平/明暗/颜色 must not be three history rows")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动调整")

        XCTAssertNotEqual(session.edit.light.blackOffset, before.light.blackOffset,
                          "黑电平 must have measured a real offset")
        let metrics = try XCTUnwrap(loupe.lastAutoColorMetricsForTesting,
                                    "自动颜色 must have run inside the same press")
        XCTAssertGreaterThan(metrics.sampleCount, 0)
        // 452's AutoColor only raises, toward a calibrated target (0.0219). This fixture's median
        // chroma is above it, so the honest answer is 0 — and the composite still commits black+light.
        if AutoColor.plan(metrics) > 0 {
            XCTAssertNotEqual(session.edit.color.vibrance, before.color.vibrance,
                              "a positive auto-colour plan must be written")
        } else {
            XCTAssertEqual(session.edit.color.vibrance, before.color.vibrance)
        }
        XCTAssertNotEqual(session.edit, before)
    }

    // MARK: - ①b 497 — 自动调整 is the whole verb: light and colour move in one undoable row

    /// The menu no longer offers a separate 「自动颜色」 row because 「自动调整」 already includes
    /// colour. A baseline vibrance of -20 makes the raise-only colour step move even when the
    /// fixture's own chroma plan is 0, so the assertion has teeth: dropping the colour step from the
    /// composite turns `vibrance` red.
    func testAutoAdjustMovesLightAndColorAndUndoRevertsBoth() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "497-both", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "497-both"), "the full rung never reached the canvas")

        session.applyEdit { $0.color.vibrance = -20 }
        XCTAssertTrue(session.commitEdit(label: "原照"))
        let before = session.edit
        let historyBefore = session.history.count

        XCTAssertTrue(loupe.autoDevelop(), "a settled full frame must produce a composite plan")
        XCTAssertEqual(session.history.count, historyBefore + 1,
                       "自动调整 must be one history row")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动调整")

        let lightMoved = session.edit.light.exposure != before.light.exposure
            || session.edit.light.highlights != before.light.highlights
            || session.edit.light.whites != before.light.whites
            || session.edit.light.blacks != before.light.blacks
        XCTAssertTrue(lightMoved, "明暗 must move")
        XCTAssertNotEqual(session.edit.color.vibrance, before.color.vibrance,
                          "色彩 must move inside the same 自动调整 row")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit, before, "one ⌘Z undoes light and colour together")
        XCTAssertEqual(session.history.currentSnapshot?.label, "原照")
    }

    // MARK: - ② the order is load-bearing

    func testAutoLightMeasuresTheNewBlackOffset() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "453-order", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "453-order"))

        let blackBefore = session.edit.light.blackOffset
        XCTAssertTrue(loupe.autoDevelop())
        let blackAfter = session.edit.light.blackOffset
        XCTAssertNotEqual(blackAfter, blackBefore)
        XCTAssertEqual(loupe.lastAutoLightBlackOffsetInputForTesting ?? .nan, blackAfter,
                       "AutoLight.plan must be measured on the document that carries the new black offset")
    }

    // MARK: - ③ 448's gate, .all branch

    func testClickBeforeTheFullFrameQueuesAllAndCommitsOnce() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "453-gate", session: session)
        XCTAssertTrue(waitForPreview(loupe), "the preview rung never reached the canvas")

        let editBefore = session.edit
        let historyBefore = session.history.count
        XCTAssertFalse(loupe.autoDevelop(), "a preview frame must not be measured")
        XCTAssertEqual(loupe.pendingAuto, .all)
        XCTAssertEqual(session.edit, editBefore)
        XCTAssertEqual(session.history.count, historyBefore)
        XCTAssertTrue(loupe.isWaitingForDecode)

        XCTAssertTrue(waitFor {
            loupe.pendingAuto == nil && session.history.count == historyBefore + 1
        }, "the queued 自动调整 never ran on the full frame")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动调整")

        pump(0.5)
        XCTAssertEqual(session.history.count, historyBefore + 1, "the full frame must not run it twice")
    }

    // MARK: - ④ the standalone verbs keep one row each (the split must not change behaviour)

    func testStandaloneVerbsStillCommitTheirOwnSingleRow() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "453-standalone", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "453-standalone"))

        var count = session.history.count
        XCTAssertNotNil(loupe.autoBlackOffset())
        XCTAssertEqual(session.history.count, count + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑电平 · 自动")

        count = session.history.count
        XCTAssertNotNil(loupe.autoLight())
        XCTAssertEqual(session.history.count, count + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "明暗 · 自动")
    }
}
