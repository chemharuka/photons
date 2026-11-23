import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 535 — 平移/缩放之后切图，窗口画布缓存**间歇性**建不起来。
///
/// 用户口径（2026-11-23）：「屏幕画面 10/3 张缓存，平移之后切换照片，就不再重建新的缓存了」，
/// 随后补充「看起来问题在于缓存并不一定能建立成功，多试几次后发现有缓存」；最终口径是
/// 「不要单独为了生成缓存再做一次渲染 —— 打开新的照片解码的时候自然而然就有了屏幕画布的像素值」。
///
/// 本套件用真库、真解码、真 present，把每一次尝试的判据记下来再断言，而不是单次断言：
///
///   1. 平移后切图重复 20 次（20 张不同的 B）：每一次 B 的**第一帧上屏**时 `stores +1`，
///      且该 key 能被 `lookup` 命中；
///   2. 冷启动（无平移）的 0.5 → 1.0 上屏顺序与修复前一致（不误伤 532 的单调门）；
///   3. 缩放到 200% 后切图，第二次进入同一相机时 `hits +1`；
///   4. 缓存是「反正要画的那一帧」的副产品：每次存条目都对应一次本来就要发生的上屏，
///      `viewRenderCount` / `editRenderCount` 的增量与修复前逐次相等（±0）。
@MainActor
final class CanvasCacheStoreRetry535Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        CanvasFrameCache.browsingCapacity = 10
        CanvasFrameCache.editingCapacity = 3
        CanvasFrameCache.invalidatesOnEdit = true
        CanvasFrameCache.protectsCurrentPhoto = true
        CanvasFrameCache.quantizesCanvasCamera = true
        CanvasFrameCache.canonicalizesCanvasEditDigest = true
        super.tearDown()
    }

    // MARK: - fixtures / harness

    /// `count` distinct, readable DNGs from the configured fixture's directory.
    private func rawFixtures(count: Int) throws -> [URL] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            candidates.append(NSString(string: env).expandingTildeInPath)
        }
        candidates.append(NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath)
        guard let first = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
        else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }
        let firstURL = URL(fileURLWithPath: first)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: firstURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let others = siblings
            .filter { $0.standardizedFileURL != firstURL.standardizedFileURL }
            .filter { ["dng", "DNG", "raw", "RAW"].contains($0.pathExtension) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let urls = [firstURL] + others
        guard urls.count >= count else {
            throw XCTSkip("\(count) RAW fixtures are required, found \(urls.count)")
        }
        return Array(urls.prefix(count))
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 180, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.autoRenderEnabled = true
        return controller
    }

    private func source(_ url: URL, _ identity: String,
                        state: LoupeViewState = .fit) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: state, edit: .neutral)
    }

    /// Start one switch; returns the index the new present records begin at.
    @discardableResult
    private func beginSwitch(_ controller: LoupeController, _ url: URL, _ identity: String,
                             state: LoupeViewState = .fit) -> Int {
        let start = controller.framePresentLog.count
        controller.frameSource = source(url, identity, state: state)
        controller.scheduleRender()
        return start
    }

    /// Wait for the **first** real frame of `identity` to reach the layer. That frame — not the
    /// eventual full rung — is what §5 calls 「已经在屏幕上」, and it is the instant the cache write
    /// is due.
    @discardableResult
    private func waitForFirstFrame(_ controller: LoupeController, _ identity: String,
                                   from start: Int, timeout: TimeInterval = 180) -> Bool {
        waitFor(timeout) {
            controller.framePresentLog.dropFirst(start).contains {
                $0.photo == identity && !$0.fromCanvasCache
            }
        }
    }

    /// Wait for the full rung of `identity`, for the cold-start sequence assertion.
    @discardableResult
    private func waitForFullFrame(_ controller: LoupeController, _ identity: String,
                                  from start: Int, timeout: TimeInterval = 180) -> Bool {
        waitFor(timeout) {
            controller.framePresentLog.dropFirst(start).contains {
                $0.photo == identity && !$0.fromCanvasCache
                    && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
            }
        }
    }

    private func describe(_ records: [LoupeController.FramePresentRecord]) -> String {
        records.map {
            "\($0.kind)\($0.fromCanvasCache ? "/cache" : "")@\($0.decodeScale)"
        }.joined(separator: " → ")
    }

    /// What the entry the controller says it would look up can actually answer.
    private func lookupHit(_ controller: LoupeController) -> Bool {
        guard let key = controller.lastCanvasFrameCacheKey,
              let entry = controller.canvasFrameCache.cachedCanvas(matching: key) else { return false }
        return controller.canvasFrameCache.lookup(
            key, decodeScale: Double(entry.decodeScale)) != nil
    }

    private func regimeAndMemory(_ controller: LoupeController) -> String {
        let d = controller.canvasFrameCacheDiagnostics
        return "regime=\(controller.canvasCacheRegime) count=\(d.count)/\(d.capacity)"
            + " bytes=\(d.bytes) stores=\(d.stores) hits=\(d.hits) misses=\(d.misses)"
    }

    // MARK: - ① the reported path, twenty times

    /// 打开 A → 平移（1:1）→ 切到 B（20 张不同的 B）。每次都在 B 的第一帧上屏那一刻记账。
    ///
    /// This is also the reverse gate's ledger: on the pre-fix build the dominant refusal is
    /// `belowTarget` (the 0.5 screen frame waits for the whole 60 MP decode), so `stores` does not
    /// move at that instant. The fix must make it move every time.
    func testPanThenSwitchStoresEveryTime() throws {
        let photos = try rawFixtures(count: 21)
        let controller = makeController()
        let aURL = photos[0]
        let aID = "retry535-a"

        var rows: [(step: Int, stores: Int, reason: String, detail: String,
                    viewDelta: Int, editDelta: Int)] = []
        var succeeded = 0
        var panStores = 0

        for step in 0..<20 {
            let bURL = photos[step + 1]
            let bID = "retry535-b\(step)"

            // A at fit, then 1:1 and one pan — the user's gesture.
            let aStart = beginSwitch(controller, aURL, aID, state: .fit)
            XCTAssertTrue(waitForFirstFrame(controller, aID, from: aStart),
                          "step \(step): A never presented")
            if !controller.viewState.isActualSize {
                controller.zoom(to: 1, aroundView: CGPoint(x: 320, y: 200))
            }
            XCTAssertTrue(waitFor(30) { controller.zoomBridge == nil },
                          "step \(step): the 1:1 bridge never finished")
            let panStoresBefore = controller.canvasCacheStores
            controller.panImage(byPoints: CGSize(width: step.isMultiple(of: 2) ? -12 : 12,
                                                 height: step.isMultiple(of: 2) ? 8 : -8))
            XCTAssertTrue(waitFor(120) { !controller.viewportRenderInFlight },
                          "step \(step): the panned frame never quiesced")
            pump(0.05)
            if controller.canvasCacheStores > panStoresBefore { panStores += 1 }

            let storesBefore = controller.canvasCacheStores
            let viewsBefore = controller.viewRenderCount
            let editsBefore = controller.editRenderCount
            let skipBefore = controller.canvasCacheLastSkip

            // Switch to B and stop at its **first** on-screen frame.
            let bStart = beginSwitch(controller, bURL, bID, state: .fit)
            XCTAssertTrue(waitForFirstFrame(controller, bID, from: bStart),
                          "step \(step): B never presented")
            let storesDelta = controller.canvasCacheStores - storesBefore
            let viewDelta = controller.viewRenderCount - viewsBefore
            let editDelta = controller.editRenderCount - editsBefore
            let skip = controller.canvasCacheLastSkip
            let reason: String
            let detail: String
            if storesDelta > 0 {
                reason = "stored"
                detail = "—"
            } else {
                reason = skip?.reason.rawValue ?? (skipBefore == skip ? "none" : "unknown")
                detail = skip.map {
                    "s=\($0.decodeScale) target=\($0.target) kind=\($0.kind) camera=\($0.camera)"
                } ?? "—"
            }
            rows.append((step, storesDelta, reason, detail, viewDelta, editDelta))
            if storesDelta > 0 { succeeded += 1 }

            // §5 主判据的一个现场读数：条目必须来自本来就要上屏的那一帧。
            if storesDelta > 0 {
                XCTAssertTrue(lookupHit(controller),
                              "step \(step): B's key was stored but `lookup` could not answer it")
            }
            XCTAssertEqual(editDelta, 0, "step \(step): a view switch must not render an edit frame")
        }

        print("[535] ①  pan → switch, 20 attempts:\n" + rows.map {
            "  \($0.step): stores +\($0.stores) · \($0.reason) · \($0.detail)"
                + " · view +\($0.viewDelta) edit +\($0.editDelta)"
        }.joined(separator: "\n"))
        let lastSkipLine = controller.canvasCacheLastSkip.map {
            "\($0.reason.rawValue) s=\($0.decodeScale) target=\($0.target)"
        } ?? "—"
        print("[535] ①  success \(succeeded)/20 · skips \(controller.canvasCacheStoreSkips.description)"
            + " · last \(lastSkipLine) · \(regimeAndMemory(controller))")

        XCTAssertEqual(succeeded, 20, "every pan-then-switch must store B's first screen frame")
        XCTAssertGreaterThan(panStores, 0,
                             "the settled pan frame itself must be written (200 % is the same rule)")
        XCTAssertEqual(controller.canvasCacheStoreSkips[.notSettledKind] ?? 0, 0,
                       "the settled pan frame must not be refused as an unsettled view")
        XCTAssertEqual(controller.canvasCacheStoreSkips[.belowTarget] ?? 0, 0,
                       "the 0.5 screen frame must not wait for the whole decode")
        XCTAssertGreaterThan(controller.canvasCacheStoreAttempts, 0,
                             "the ledger must have seen the attempts it is judging")
    }

    /// ② — cold start has no pan: the present sequence is still 0.5 → 1.0 and the gate stays out.
    func testColdStartStillPresentsPreviewThenFull() throws {
        let photos = try rawFixtures(count: 1)
        let controller = makeController()
        let start = beginSwitch(controller, photos[0], "retry535-cold")
        XCTAssertTrue(waitForFullFrame(controller, "retry535-cold", from: start),
                      "the cold start never reached the full rung")
        pump(0.1)

        let records = Array(controller.framePresentLog.dropFirst(start))
            .filter { $0.photo == "retry535-cold" }
        let line = describe(records)
        print("[535] ②  cold start: \(line) · \(regimeAndMemory(controller))")

        guard let preview = records.firstIndex(where: {
            !$0.fromCanvasCache && $0.decodeScale >= DecodeLadder.previewScale - 1e-4
                && $0.decodeScale < DecodeLadder.fullScale - 1e-4
        }) else {
            return XCTFail("the cold start never presented the 0.5 rung: \(line)")
        }
        XCTAssertTrue(records[(preview + 1)...].contains {
            !$0.fromCanvasCache && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
        }, "the 1.0 rung must follow the 0.5 rung: \(line)")
        XCTAssertEqual(controller.monotonicSuppressedPresents, 0,
                       "the gate must not touch a cold start")
        XCTAssertGreaterThanOrEqual(controller.canvasCacheStores, 1,
                                    "the cold start's on-screen frame must still be cached")
    }

    /// ③ — 200 %: zoom, switch away, come back. The second entry must be a cache hit.
    func testZoomTo200ThenSwitchHitsOnReturn() throws {
        let photos = try rawFixtures(count: 2)
        let controller = makeController()
        let aID = "retry535-zoom-a"
        let bID = "retry535-zoom-b"

        // Warm A to the full rung at fit, so the 200 % frame is rendered from 1.0 (the rung that
        // will be the stored key on the return).
        let warmStart = beginSwitch(controller, photos[0], aID, state: .fit)
        XCTAssertTrue(waitForFullFrame(controller, aID, from: warmStart), "A never reached 1.0")
        pump(0.1)

        controller.zoom(to: 2, aroundView: CGPoint(x: 320, y: 200))
        XCTAssertTrue(waitFor(30) { controller.zoomBridge == nil }, "the 2× bridge never finished")
        XCTAssertTrue(waitFor(120) { !controller.viewportRenderInFlight })
        pump(0.1)
        let storesAfterZoom = controller.canvasCacheStores

        // Switch away and back to the same camera.
        let bStart = beginSwitch(controller, photos[1], bID, state: .fit)
        XCTAssertTrue(waitForFirstFrame(controller, bID, from: bStart), "B never presented")
        pump(0.05)

        let hitsBefore = controller.canvasFrameCacheDiagnostics.hits
        let presentsBefore = controller.canvasCachePresents
        let aStart = beginSwitch(controller, photos[0], aID, state: controller.viewState)
        XCTAssertTrue(waitForFirstFrame(controller, aID, from: aStart),
                      "A never came back on screen")
        pump(0.1)

        let records = Array(controller.framePresentLog.dropFirst(aStart))
            .filter { $0.photo == aID }
        print("[535] ③  200% return: \(describe(records)) · stores after zoom \(storesAfterZoom)"
            + " → \(controller.canvasCacheStores) · hits \(hitsBefore) → "
            + "\(controller.canvasFrameCacheDiagnostics.hits) · \(regimeAndMemory(controller))")

        XCTAssertGreaterThan(storesAfterZoom, 0, "the 200 % screen frame was never cached")
        XCTAssertGreaterThan(controller.canvasFrameCacheDiagnostics.hits, hitsBefore,
                             "coming back to the 200 % camera must hit the cache")
        XCTAssertGreaterThan(controller.canvasCachePresents, presentsBefore,
                             "the hit must actually put the cached canvas on the layer")
        XCTAssertTrue(records.contains { $0.fromCanvasCache },
                      "no cached present in the return sequence: \(describe(records))")
    }
}
