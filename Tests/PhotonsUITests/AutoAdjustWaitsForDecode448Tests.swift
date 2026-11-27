import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 448 — 自动调整（黑电平 / 明暗 / 白平衡）必须等 RAW 解出**全档 rung** 之后再采样。
///
/// 用户口径（2026-11-20）：「自动调整要等RAW解码完成后进行，否则采样采的是缩略图缓存。所以点击后
/// 不要立刻采样，等解码。」
///
/// The three actions share one gate (`anchorFrameIsFullRung`): the frame on screen must be
/// `DecodeLadder.fullScale` **of the current anchor**, through a graph whose identity is the
/// document's full-rung identity — the same comparison `measureHistogramNow` already uses. A click
/// that arrives too early only records `pendingAuto` and asks the ordinary viewport path for the
/// full rung; the next full frame presented runs the original measurement.
///
/// These tests drive the shipped frame path (`scheduleRender` / `requestViewportRender`), not the
/// synchronous `makeFrame` seam: the defect is about *when* a presented frame is allowed to be
/// sampled, and a hand-installed frame would prove nothing about that order.
@MainActor
final class AutoAdjustWaitsForDecode448Tests: XCTestCase {

    private static let viewport = ImageSize(width: 1024, height: 768)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

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

    private func switchPhoto(_ controller: LoupeController, url: URL, identity: String) {
        let edit = controller.frameSource?.edit ?? .neutral
        controller.frameSource = LoupeController.FrameSource(
            url: url, identity: identity, viewport: Self.viewport, state: .fit, edit: edit)
        // The app notices the anchor through the session observation and schedules the new photo's
        // first frame; the harness names the photo explicitly, so it asks for that frame here.
        controller.scheduleRender()
    }

    // MARK: - main-thread pumping

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

    private func waitForFull(_ loupe: LoupeController, photo: String) -> Bool {
        waitFor {
            loupe.currentPresentedPhotoForTesting == photo
                && loupe.lastPresentedScale == DecodeLadder.fullScale
                && loupe.frameScaleForTesting == Double(DecodeLadder.fullScale)
        }
    }

    // MARK: - ① 不立刻采样

    func testClickBeforeTheFullFrameQueuesAndWritesNothing() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-A", session: session)

        // 571-A: there is no 0.5 frame to click at any more; the click arrives while the canvas is
        // still on the stand-in (no presented frame at all).
        XCTAssertNil(loupe.lastPresentedScale, "nothing should have been presented yet")

        let before = session.edit
        let historyBefore = session.history.count
        XCTAssertNil(loupe.autoLight(), "a queued click has no plan yet")

        XCTAssertEqual(session.edit, before, "点击后不得立刻采样/写文档")
        XCTAssertEqual(session.history.count, historyBefore, "点击后不得写 history")
        XCTAssertEqual(loupe.pendingAuto, .light, "点击必须排进 pendingAuto")
        XCTAssertTrue(loupe.isWaitingForDecode)
    }

    // MARK: - ② 帧到即执行一次

    func testQueuedLightRunsOnceWhenTheFullFrameLands() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-A", session: session)

        let historyBefore = session.history.count
        _ = loupe.autoLight()
        XCTAssertEqual(loupe.pendingAuto, .light)

        XCTAssertTrue(waitFor {
            loupe.pendingAuto == nil && session.history.count == historyBefore + 1
        }, "the queued 明暗 click never ran on the full frame")
        XCTAssertEqual(session.history.currentSnapshot?.label, "明暗 · 自动")
        XCTAssertEqual(loupe.lastAutoLightSampleIdentityForTesting, "448-A")
        XCTAssertFalse(loupe.isWaitingForDecode)

        pump(0.5)
        XCTAssertEqual(session.history.count, historyBefore + 1, "全档帧不能再执行第二次")
    }

    // MARK: - ③ 照片门

    func testTheSampleCarriesTheNewPhotosIdentity() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-A", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "448-A"), "A never reached the full rung")
        // Let A's capability read-back settle before switching: its revision bump belongs to A.
        XCTAssertTrue(waitFor { session.edit.resolvedDecoderVersion != nil })
        pump(0.1)

        switchPhoto(loupe, url: url, identity: "448-B")
        // 571-A: there is no preview frame to click on; the click waits for B's full frame.
        XCTAssertTrue(waitForFull(loupe, photo: "448-B"), "B never reached the full rung")

        let editBefore = session.edit
        let historyBefore = session.history.count
        _ = loupe.autoLight()
        XCTAssertEqual(loupe.lastAutoLightSampleIdentityForTesting, "448-B",
                       "the measurement must carry B's identity")
        XCTAssertEqual(session.history.count, historyBefore + 1, "B 的全档帧必须执行一次")
        XCTAssertEqual(session.history.currentSnapshot?.label, "明暗 · 自动")
    }

    // MARK: - ④ 黑电平与白平衡同门

    func testBlackLevelWaitsAndThenRunsOnce() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-black", session: session)
        XCTAssertNil(loupe.lastPresentedScale,
                     "571-A: no canvas frame yet — the click must queue")

        let before = session.edit.light.blackOffset
        let historyBefore = session.history.count
        XCTAssertNil(loupe.autoBlackOffset())
        XCTAssertEqual(loupe.pendingAuto, .black)
        XCTAssertEqual(session.edit.light.blackOffset, before, "等待期间黑电平不得变")
        XCTAssertEqual(session.history.count, historyBefore)

        XCTAssertTrue(waitFor {
            loupe.pendingAuto == nil && session.history.count == historyBefore + 1
        }, "the queued 黑电平 click never ran on the full frame")
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑电平 · 自动")
        XCTAssertNotEqual(session.edit.light.blackOffset, before)

        pump(0.5)
        XCTAssertEqual(session.history.count, historyBefore + 1, "不得重复执行")
    }

    func testWhiteBalanceWaitsAndThenRunsOnce() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-wb", session: session)
        XCTAssertNil(loupe.lastPresentedScale,
                     "571-A: no canvas frame yet — the click must queue")

        let before = session.edit.light.whiteBalance
        let historyBefore = session.history.count
        XCTAssertNil(loupe.autoWhiteBalance())
        XCTAssertEqual(loupe.pendingAuto, .whiteBalance)
        XCTAssertEqual(session.edit.light.whiteBalance, before, "等待期间温度/色调不得变")
        XCTAssertEqual(session.history.count, historyBefore)

        XCTAssertTrue(waitFor {
            loupe.pendingAuto == nil && session.history.count == historyBefore + 1
        }, "the queued 自动白平衡 never ran on the full frame")
        XCTAssertEqual(session.history.currentSnapshot?.label, "自动白平衡")
        XCTAssertNotEqual(session.edit.light.whiteBalance, before)

        pump(0.5)
        XCTAssertEqual(session.history.count, historyBefore + 1, "不得重复执行")
    }

    // MARK: - ⑤ 换照片即作废

    func testSwitchingPhotosDropsTheWaitingClick() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        let loupe = makeController(url: url, identity: "448-A", session: session)
        XCTAssertTrue(waitForFull(loupe, photo: "448-A"))
        XCTAssertTrue(waitFor { session.edit.resolvedDecoderVersion != nil })
        pump(0.1)

        let editBefore = session.edit
        let historyBefore = session.history.count
        // A click while B is still developing is queued…
        switchPhoto(loupe, url: url, identity: "448-B")
        XCTAssertNil(loupe.autoLight())
        XCTAssertEqual(loupe.pendingAuto, .light)

        // …and switching again before B's full frame lands drops it.
        switchPhoto(loupe, url: url, identity: "448-C")
        XCTAssertNil(loupe.pendingAuto, "换照片必须清 pendingAuto")
        XCTAssertFalse(loupe.isWaitingForDecode)

        XCTAssertTrue(waitForFull(loupe, photo: "448-C"),
                      "C never reached the full rung (the counter-proof needs that frame)")
        pump(0.3)
        XCTAssertEqual(session.edit, editBefore, "新照片的全档帧不得执行上一条点击")
        XCTAssertEqual(session.history.count, historyBefore)
    }
}
