import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §392 — 「HDR 合成」 的中心提示卡：三行（HDR 合成 / 张数 / 时间），**没有曝光指示**。
///
/// 用户第三轮口径（2026-11-12，最终）：去掉曝光差距那一行，只要三行；卡片钉在**画布（UI）中心**，
/// 定尺寸，0.5 s ticker 走 `分:秒`，合成期间才在。
///
/// 显示条件是本单与 387 唯一的语义差别，且是用户第四轮补充的：
///
///   > 「HDR 合成是多张参与，所以设计的那些图片都显示」
///
/// 也就是 **`anchorID ∈ 参与合成的 id 集合`**，不是 `anchorID == 某一个 id`（那是降噪的单张语义）。
/// `testSwitchingAmongParticipantsKeepsTheCardUpAndLeavingTheBatchHidesIt` 就是这一条的三组实测。
///
/// 「合成中」这个状态**不靠真跑一次合成来等**（本机可能一秒内就结束）：`hdrMergeQueue` 是可注入的，
/// 测试塞一个 **suspend 住的队列** 进去，于是 `isHDRMergeRunning == true`、参与 id 已记下、后台那
/// 一半还排着 —— in-flight 成了测试自己持有的状态，和 387 用 gate 文件持有降噪是同一个手法。
@MainActor
final class HDRMergeCard392Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var catalog: Catalog!
    private var session: CatalogSession!
    /// The suspended queue that holds the merge in flight, and whether the test resumed it.
    private var heldQueue: DispatchQueue?
    private var heldResumed = false

    private static let canvas = NSSize(width: 900, height: 600)

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr392-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A suspended queue must be resumed before it is released (libdispatch traps otherwise), and
        // the pending block has to be given a chance to fail out so `finishHDRMerge` runs.
        endHeldMerge()
        pump(0.2)
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    /// `count` DNG rows over the committed 1024² fixture, each with a real file behind it so
    /// `hdrMergeSelection`'s `fileURL(for:)` gate passes.
    @discardableResult
    private func makeSession(count: Int = 3) throws -> [Asset] {
        let url = workDir.appendingPathComponent("S392.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        var out: [Asset] = []
        for i in 0..<count {
            let name = String(format: "IMG_%04d.dng", i)
            try FileManager.default.copyItem(at: Self.fixtureURL, to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString, width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            out.append(asset)
        }
        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        try s.open(url)
        s.setSortOrder(.newestFirst)
        session = s
        return out
    }

    /// Hold a real merge **in flight** without running it: `hdrMergeSelection()` does every gate it
    /// normally does (2+ mergeable frames, resolvable files, a tool that exists) and then `queue.async`
    /// onto a queue this test has suspended. So `isHDRMergeRunning` is `true`, the participant ids are
    /// recorded, and the blocking half is parked — the exact state the card is for.
    ///
    /// The tool only has to **exist** (`isHDRMergeAvailable` is a file check): when the queue is
    /// resumed the call fails immediately on `/bin/echo`'s non-JSON output, which is the failure path
    /// out of the run.
    @discardableResult
    private func startHeldMerge(participants assets: [Asset]) -> [String] {
        let queue = DispatchQueue(label: "test.hdr392.held")
        queue.suspend()
        heldQueue = queue
        heldResumed = false
        session.hdrMergeQueue = queue
        session.hdrMergeService = HDRMergeService(
            client: HDRMergeClient(executableURL: URL(fileURLWithPath: "/bin/echo")))
        session.setSelection(Set(assets.map(\.id)), anchor: assets[0].id)
        return session.hdrMergeSelection()
    }

    private func endHeldMerge() {
        guard let heldQueue, !heldResumed else { return }
        heldResumed = true
        heldQueue.resume()
    }

    private func waitForHDRRun(timeout: TimeInterval = 10) {
        pumpUntil("⑤ 卡片没在合成开始后一个 runloop 内出现", timeout: timeout) {
            self.session.hdrMergeCompletionCount > 0 || self.session.isHDRMergeRunning
        }
    }

    private func waitForHDREnd(timeout: TimeInterval = 30) {
        pumpUntil("⑤ 合成没在 \(timeout) s 内结束", timeout: timeout) {
            self.session.hdrMergeCompletionCount > 0
        }
    }

    private func makeLoupe(anchor: String, size: NSSize = HDRMergeCard392Tests.canvas)
        throws -> (loupe: LoupeController, window: NSWindow) {
        _ = NSApplication.shared
        session.selectOnly(anchor)
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        windows.append(window)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return (loupe, window)
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func pumpUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    /// The photograph's rect on the canvas, in view points — the same independent recomputation
    /// `DenoiseHUD387Tests` uses, so ④ compares the card against a number it did not produce itself.
    private func photoRect(_ loupe: LoupeController) throws -> NSRect {
        let framing = try XCTUnwrap(loupe.framing())
        let mapping = framing.mapping(of: loupe.viewState)
        let scale = loupe.backingScale
        let a = mapping.frameView(frameX: 0, frameY: 0)
        let b = mapping.frameView(frameX: framing.sourceWidth, frameY: framing.sourceHeight)
        return NSRect(x: min(a.x, b.x) / scale, y: min(a.y, b.y) / scale,
                      width: abs(b.x - a.x) / scale, height: abs(b.y - a.y) / scale)
    }

    // MARK: - ① 三行内容：HDR 合成 / N 张 / m:ss

    func testTheThreeLinesAreTitleFrameCountAndElapsed() throws {
        // Pure first, so the literal is pinned even if the run below never starts.
        let pure = HDRMergeProgressOverlay.lines(frameCount: 3, elapsed: 9)
        print("① 纯函数：lines=\(pure) N=3")
        XCTAssertEqual(pure, ["HDR 合成", "3 张", "0:09"], "① 三行、顺序、字面量都必须完全一致")
        XCTAssertEqual(pure.count, 3, "① 只有三行 —— 用户第三轮把曝光那行去掉了")
        XCTAssertEqual(HDRMergeProgressOverlay.lines(frameCount: 12, elapsed: 3665),
                       ["HDR 合成", "12 张", "61:05"],
                       "① 12 张、3665 s ⇒ 61:05（不转小时）")
        // No exposure anywhere: the two rounds that asked for EV are superseded (spec §0/§3).
        let joined = pure.joined(separator: "|")
        for word in ["EV", "ISO", "光圈", "快门", "曝光", "%"] {
            XCTAssertFalse(joined.contains(word), "① 不许出现「\(word)」—— 曝光指示已作废")
        }

        // …then the number the card actually lays down during a real (held) run.
        let assets = try makeSession()
        let (loupe, _) = try makeLoupe(anchor: assets[0].id)
        XCTAssertEqual(loupe.hdrHUDStateForTesting, .hidden, "① 静止时没有卡片")
        startHeldMerge(participants: [assets[0], assets[1]])
        waitForHDRRun()
        pumpUntil("① 卡片没出现") { loupe.hdrHUDStateForTesting == .running }
        let laydown = try XCTUnwrap(loupe.hdrLaydownForTesting)

        print("① 实测：state=\(loupe.hdrHUDStateForTesting) lines=\(laydown.lines) "
              + "N=\(session.hdrMergeParticipantIDs.count) bounds=\(NSStringFromRect(laydown.bounds))")

        XCTAssertEqual(laydown.lines.count, 3)
        XCTAssertEqual(laydown.lines[0], "HDR 合成")
        XCTAssertEqual(laydown.lines[1], "\(session.hdrMergeParticipantIDs.count) 张")
        XCTAssertNotNil(laydown.lines[2].range(of: "^\\d+:\\d{2}$", options: .regularExpression),
                        "① 第三行必须匹配 ^\\d+:\\d{2}$，实际 \(laydown.lines[2])")

        endHeldMerge()
        waitForHDREnd()
    }

    // MARK: - ② 标题更大，三行同一个中心 x

    func testTheTitleIsBiggerAndAllThreeLinesShareACentreX() throws {
        let title = ProgressCardOverlay.titleFont
        let detail = ProgressCardOverlay.detailFont
        let host = CGRect(x: 0, y: 0, width: 900, height: 600)
        let laydown = HDRMergeProgressOverlay.laydown(
            lines: HDRMergeProgressOverlay.lines(frameCount: 3, elapsed: 34),
            center: CGPoint(x: 450, y: 300), containerBounds: host)
        let rects = ProgressCardOverlay.textRects(in: laydown.bounds)
        let midXs = rects.map { ($0.midX * 100).rounded() / 100 }

        print("② 第1行字号 \(title.pointSize) (\(title.fontName)) · 第2/3行字号 \(detail.pointSize) "
              + "(\(detail.fontName)) · 三行绘制中心 x = \(midXs) · rects=\(rects.map { NSStringFromRect($0) })")

        XCTAssertGreaterThan(title.pointSize, detail.pointSize, "② 第 1 行字号必须大于第 2/3 行")
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(Set(midXs).count, 1, "② 三行必须同一个中心 x，实际 \(midXs)")
        XCTAssertEqual(midXs[0], Double(laydown.bounds.midX), accuracy: 0.01,
                       "② 而且中心 x 就是卡片中心")
    }

    // MARK: - ③ 尺寸固定：张数 3→12、时间 0:09→10:05

    func testTheBoxSizeIgnoresTheDigits() throws {
        let host = CGRect(x: 0, y: 0, width: 900, height: 600)
        let a = HDRMergeProgressOverlay.laydown(
            lines: HDRMergeProgressOverlay.lines(frameCount: 3, elapsed: 9),
            center: CGPoint(x: 450, y: 300), containerBounds: host)
        let b = HDRMergeProgressOverlay.laydown(
            lines: HDRMergeProgressOverlay.lines(frameCount: 12, elapsed: 605),
            center: CGPoint(x: 450, y: 300), containerBounds: host)

        print("③ 3 张/0:09 → \(a.lines) · size=\(a.bounds.size)")
        print("③ 12 张/10:05 → \(b.lines) · size=\(b.bounds.size)")

        XCTAssertEqual(a.bounds.size, b.bounds.size, "③ 两次尺寸必须完全相等")
        XCTAssertEqual(a.bounds.size, ProgressCardOverlay.boxSize, "③ 且等于共享的 boxSize")
        XCTAssertEqual(a.bounds.size, CGSize(width: 180, height: 74))
        // …and the strings really do differ in natural width, or 「尺寸没变」 would be trivial.
        let widths = [a, b].map { laydown -> CGFloat in
            let font = ProgressCardOverlay.detailFont
            return (laydown.lines[1] as NSString).size(withAttributes: [.font: font]).width
                + (laydown.lines[2] as NSString).size(withAttributes: [.font: font]).width
        }
        print(String(format: "③ 第2+3行自然宽 %.1f → %.1f pt，卡片尺寸没变", widths[0], widths[1]))
        XCTAssertGreaterThan(abs(widths[1] - widths[0]), 4,
                             "③ 两次文字的自然宽必须不同，否则「尺寸没变」不说明问题")
        for laydown in [a, b] {
            XCTAssertTrue(ProgressCardOverlay.textRects(in: laydown.bounds)
                            .allSatisfy { laydown.bounds.contains($0) },
                          "③ 三行都画在卡片里面")
        }
    }

    // MARK: - ④ 钉在画布中心，照片平移也不动

    func testTheBoxStaysOnTheCanvasCentreAfterAPan() throws {
        let assets = try makeSession()
        let (loupe, _) = try makeLoupe(anchor: assets[0].id)
        // 1:1 so the photo can be panned off the canvas' centre — at 适应 both centres coincide and
        // ④ would pass for the wrong reason.
        loupe.zoom(to: 1, aroundView: CGPoint(x: 450, y: 300))
        XCTAssertTrue(loupe.viewState.isActualSize, "④ 先站到 100 %")
        loupe.panImage(byPoints: CGSize(width: 120, height: -80))
        pump(0.02)
        let pannedPhoto = try photoRect(loupe)

        startHeldMerge(participants: [assets[0], assets[1]])
        waitForHDRRun()
        pumpUntil("④ 卡片没出现") { loupe.hdrHUDStateForTesting == .running }
        let laydown = try XCTUnwrap(loupe.hdrLaydownForTesting)

        let canvasCentre = CGPoint(x: loupe.view.bounds.midX, y: loupe.view.bounds.midY)
        let dx = abs(laydown.center.x - canvasCentre.x)
        let dy = abs(laydown.center.y - canvasCentre.y)
        print(String(format: "④ 卡片中心 (%.2f, %.2f) · 画布中心 (%.2f, %.2f) · 差 (%.2f, %.2f) pt · "
                     + "照片中心 (%.2f, %.2f)（被 pan 平移过 +120/-80）",
                     laydown.center.x, laydown.center.y, canvasCentre.x, canvasCentre.y, dx, dy,
                     pannedPhoto.midX, pannedPhoto.midY))

        XCTAssertLessThanOrEqual(dx, 1, "④ 横向必须钉在画布中心")
        XCTAssertLessThanOrEqual(dy, 1, "④ 纵向必须钉在画布中心")
        XCTAssertGreaterThan(hypot(pannedPhoto.midX - canvasCentre.x, pannedPhoto.midY - canvasCentre.y),
                             20, "④ 这一帧里照片中心必须明显偏离画布中心，否则判据是退化的")

        endHeldMerge()
        waitForHDREnd()
    }

    // MARK: - ⑤ 只在合成时显示；参与的那几张都显示（用户第四轮补充）

    func testSwitchingAmongParticipantsKeepsTheCardUpAndLeavingTheBatchHidesIt() throws {
        let assets = try makeSession(count: 3)
        let a = assets[0], b = assets[1], outsider = assets[2]
        let (loupe, _) = try makeLoupe(anchor: a.id)
        XCTAssertEqual(loupe.hdrHUDStateForTesting, .hidden, "⑤ 合成前：.hidden")

        startHeldMerge(participants: [a, b])
        waitForHDRRun()
        pumpUntil("⑤ 卡片没出现") { loupe.hdrHUDStateForTesting == .running }
        let onA = try XCTUnwrap(loupe.hdrLaydownForTesting)
        print("⑤-1 合成中 anchor=参与① \(session.anchorID?.prefix(8) ?? "nil") → state="
              + "\(loupe.hdrHUDStateForTesting) lines=\(onA.lines)")

        // ── the second participant: still up (this is the whole difference from 387) ─────────────
        session.selectOnly(b.id)
        pump(0.1)
        let onB = loupe.hdrLaydownForTesting
        print("⑤-2 合成中 anchor=参与② \(session.anchorID?.prefix(8) ?? "nil") → state="
              + "\(loupe.hdrHUDStateForTesting) lines=\(String(describing: onB?.lines))")

        XCTAssertEqual(loupe.hdrHUDStateForTesting, .running, "⑤ 参与②上卡片必须还在")
        XCTAssertEqual(onB?.lines[0], "HDR 合成", "⑤ 参与②上的第 1 行仍是标题")
        XCTAssertEqual(onB?.lines[1], "2 张", "⑤ 张数=参与数，与参与①上一致")
        XCTAssertEqual(onB?.lines.count, 3, "⑤ 参与②上仍然只有三行")
        XCTAssertEqual(session.isHDRMergeRunning, true, "⑤ 合成还在跑")

        // ── a photo outside the batch: gone ───────────────────────────────────────────────────────
        session.selectOnly(outsider.id)
        pump(0.1)
        print("⑤-3 合成中 anchor=不参与③ \(session.anchorID?.prefix(8) ?? "nil") → state="
              + "\(loupe.hdrHUDStateForTesting) laydown="
              + "\(String(describing: loupe.hdrLaydownForTesting)) 计时器="
              + "\(loupe.isHDRMergeTimerRunningForTesting)")

        XCTAssertEqual(loupe.hdrHUDStateForTesting, .hidden, "⑤ 不参与的那张上必须看不到")
        XCTAssertNil(loupe.hdrLaydownForTesting, "⑤ 而且 lastLaydown 要清空，不是只隐藏")
        XCTAssertTrue(session.isHDRMergeRunning, "⑤ 卡片没了，合成照样在跑")

        // ── back to a participant while the run is still going ───────────────────────────────────
        session.selectOnly(a.id)
        pump(0.1)
        print("⑤-4 切回参与① → state=\(loupe.hdrHUDStateForTesting) lines="
              + "\(String(describing: loupe.hdrLaydownForTesting?.lines))")
        XCTAssertEqual(loupe.hdrHUDStateForTesting, .running, "⑤ 切回参与者卡片必须重现")

        // ── and it is gone once the run ends, whatever it ended with ─────────────────────────────
        endHeldMerge()
        waitForHDREnd()
        pump(0.15)
        print("⑤-5 合成后：error=\(session.lastHDRMergeError ?? "nil") 运行中=\(session.isHDRMergeRunning) "
              + "state=\(loupe.hdrHUDStateForTesting) laydown="
              + "\(String(describing: loupe.hdrLaydownForTesting)) 计时器="
              + "\(loupe.isHDRMergeTimerRunningForTesting) 活的timer=\(loupe.liveHDRMergeTickerCountForTesting)")
        XCTAssertEqual(session.isHDRMergeRunning, false)
        XCTAssertEqual(loupe.hdrHUDStateForTesting, .hidden, "⑤ 合成后：.hidden")
        XCTAssertNil(loupe.hdrLaydownForTesting, "⑤ 合成后 lastLaydown == nil")
    }

    // MARK: - ⑥ ticker 会死

    func testTheTickerIsInvalidatedWhenTheRunEnds() throws {
        let assets = try makeSession()
        let (loupe, _) = try makeLoupe(anchor: assets[0].id)
        startHeldMerge(participants: [assets[0], assets[1]])
        waitForHDRRun()
        pumpUntil("⑥ 卡片没出现") { loupe.hdrHUDStateForTesting == .running }
        let running = loupe.isHDRMergeTimerRunningForTesting
        let laidDown = loupe.hdrMergeLaydownCountForTesting
        pump(1.2)
        let later = loupe.hdrMergeLaydownCountForTesting
        print("⑥ 运行期：ticker 活着=\(running) 铺卡片次数 \(laidDown)→\(later)（0.5 s 一格）")
        XCTAssertTrue(running, "⑥ 运行期 ticker 必须在跑")
        XCTAssertGreaterThanOrEqual(later - laidDown, 2, "⑥ 1.2 s 内至少 tick 2 次 —— 否则时间不走")

        endHeldMerge()
        waitForHDREnd()
        pump(0.15)
        let settled = loupe.hdrMergeLaydownCountForTesting
        pump(1.0)
        print("⑥ 结束后：ticker 活着=\(loupe.isHDRMergeTimerRunningForTesting) "
              + "活的 timer 数=\(loupe.liveHDRMergeTickerCountForTesting) "
              + "一共起过 \(loupe.hdrMergeTickerCountForTesting) 个 · 铺卡片次数 "
              + "\(settled)→\(loupe.hdrMergeLaydownCountForTesting)")
        XCTAssertFalse(loupe.isHDRMergeTimerRunningForTesting, "⑥ 结束后 ticker 必须作废")
        XCTAssertEqual(loupe.liveHDRMergeTickerCountForTesting, 0,
                       "⑥ 创建过的 timer 里活着的必须为 0 —— 否则 runloop 还在每 0.5 s 叫一次")
        XCTAssertGreaterThan(loupe.hdrMergeTickerCountForTesting, 0, "⑥ 这一轮真的起过 timer")
        XCTAssertEqual(loupe.hdrMergeLaydownCountForTesting, settled, "⑥ 结束后不许再刷新")
    }

    // MARK: - ⑦ 不吃鼠标

    func testTheCardNeverTakesAClick() throws {
        let assets = try makeSession()
        let (loupe, _) = try makeLoupe(anchor: assets[0].id)
        startHeldMerge(participants: [assets[0], assets[1]])
        waitForHDRRun()
        pumpUntil("⑦ 卡片没出现") { loupe.hdrHUDStateForTesting == .running }
        let view = loupe.hdrHUDViewForTesting
        let laydown = try XCTUnwrap(loupe.hdrLaydownForTesting)
        let inside = CGPoint(x: laydown.bounds.midX, y: laydown.bounds.midY)
        let hit = view.hitTest(inside)
        print("⑦ 卡片内一点 \(inside) → hitTest=\(String(describing: hit)) · "
              + "在卡片 frame 里=\(view.frame.contains(inside)) · 在窗口里=\(view.window != nil)")

        XCTAssertTrue(view.frame.contains(inside), "⑦ 这一点确实在卡片的 frame 里")
        XCTAssertNil(hit, "⑦ hitTest 必须是 nil —— 点击属于画布")

        endHeldMerge()
        waitForHDREnd()
    }

    // MARK: - ⑧ 降噪卡的三行没被这次泛化动过

    func testTheDenoiseCardStillSaysWhatItSaidBefore() throws {
        // 387's three strings, through the shared base — the refactor must not have moved them.
        XCTAssertEqual(DenoiseProgressOverlay.lines(width: 1000, height: 1000, elapsed: 34),
                       ["降噪中", "1000×1000", "0:34"], "⑧ 降噪三行未变")
        XCTAssertEqual(DenoiseProgressOverlay.lines(width: nil, height: nil, elapsed: 34)[1], "",
                       "⑧ 像素未知仍是空行")
        XCTAssertEqual(DenoiseProgressOverlay.elapsedText(3665), "61:05", "⑧ 分:秒 未变")
        XCTAssertNotEqual(DenoiseProgressOverlay.lines(width: 1, height: 1, elapsed: 1),
                          HDRMergeProgressOverlay.lines(frameCount: 1, elapsed: 1),
                          "⑧ 两张卡的三行确实是不同的内容")
        XCTAssertEqual(DenoiseProgressOverlay.boxSize, HDRMergeProgressOverlay.boxSize,
                       "⑧ 尺寸是同一份（共享 base，不是两份会漂的算术）")
        print("⑧ 降噪 lines=\(DenoiseProgressOverlay.lines(width: 1000, height: 1000, elapsed: 34)) · "
              + "HDR lines=\(HDRMergeProgressOverlay.lines(frameCount: 3, elapsed: 34)) · "
              + "共享 boxSize=\(ProgressCardOverlay.boxSize)")
    }
}
