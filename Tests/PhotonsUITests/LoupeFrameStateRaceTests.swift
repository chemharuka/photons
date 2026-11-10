import XCTest
import AppKit
import Darwin
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

// MARK: - shared fixtures

/// Fixtures for the three suites in this file: a real library with one `1200 × 800` row (the geometry
/// is all `CropMath` / `LoupeFraming` arithmetic — no Metal, no 66 MP decode), and a loupe on it whose
/// canvas has a real size.
@MainActor
enum LoupeFrameStateRaceSupport {
    static let stored = ImageSize(width: 1200, height: 800)
    /// The rung a loupe shows first: half the stored frame.
    static let rung = ImageSize(width: 600, height: 400)
    static let rungScale: Double = 0.5

    static func image(_ size: ImageSize) -> LinearImage {
        LinearImage(width: size.width, height: size.height,
                    rgba: [Float16](repeating: 0, count: size.width * size.height * 4),
                    colorSpace: "extendedLinearSRGB", decoderVersion: "test")
    }

    /// A windowed loupe on a real library row, laid out, with auto-render off (nothing here is about
    /// the render loop: the probes drive both sides by hand).
    static func makeLoupe(workDir: URL) throws
        -> (loupe: LoupeController, session: CatalogSession, window: NSWindow) {
        _ = NSApplication.shared
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: stored.width,
                                                             height: stored.height)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        return (loupe, session, window)
    }
}

/// A counted write from a second queue. The probes only print it — the number proves the other side
/// actually ran; nothing in this file asserts on timing.
final class RaceProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ n: Int) { lock.lock(); stored = n; lock.unlock() }
}

// MARK: - §2E · the ThreadSanitizer probe

/// **333 — Loupe 的帧状态被主线程和 render 队列无锁共享（滚动即闪退）: the TSan probe.**
///
/// 三份 `.ips`（`Photons-2026-11-10-113046.ips` 与 `Retired/` 两份）都是同一条链上的 over-release：
///
/// ```
/// Thread 0 (main)  _swift_release_dealloc ← RefCounts::doDecrementSlow
///                  ← framing(viewport:) ← camera() ← setViewState ← scrollWheel
/// Thread (render)  _swift_release_dealloc ← swift_deallocClassInstance.cold.1
///                  ← makeFrame(url:cacheIdentity:…) ← residentFrame ← renderFrame
/// ```
///
/// 写方 = `makeFrame` 在 `photons.loupe.render` 上写 `decoded / decodedIdentity / decodedURL /
/// decodedScale / decodedCaps`（6415–6419）；读方 = 主线程的 `framing(viewport:)`、`backdropPhotoKey`、
/// `hasIngestedPlaceholderSource`。没有锁，所以主线程可能 retain 一个 render 队列刚释放的 buffer 或
/// String，随后 release 就崩。
///
/// 这条探针只做一件事：**把两个方向同时跑起来**，让 ThreadSanitizer 自己说这是 data race。
/// 它不改任何生产行为，也不做断言（竞态的结果是「有时崩」，没有可断言的确定值）。
///
/// **只在 `swift test --sanitize thread` 下有意义**：正常套件跑它等于故意制造竞态，所以默认
/// `XCTSkip`（规格 §2E 允许的唯一一处）。
@MainActor
final class LoupeFrameStateRaceTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-loupe-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// Is this test binary linked against the ThreadSanitizer runtime?
    ///
    /// `--sanitize thread` is the only thing that puts `libclang_rt.tsan_osx_dynamic.dylib` into the
    /// process, so its presence is exactly the question "is anyone reading the result". A plain run
    /// answers no and both probes skip instead of manufacturing a race for nobody.
    static var isThreadSanitized: Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index) else { return false }
            return String(cString: name).contains("libclang_rt.tsan")
        }
    }

    /// The probe: `framing()` on the main thread while the frame state is written underneath it.
    ///
    /// The writer is the seam that leaves the state exactly the way `makeFrame` leaves it (same five
    /// fields, same values, alternating rung); the shipped function itself is the second test.
    ///
    /// The main thread does what `scrollWheel` does: one `framing()` per event, in a loop, plus the two
    /// other readers in the chain. No sleeps and no retries: a race that needs a sleep to be visible is
    /// not the one that crashes the app.
    func testFramingOnMainRunsWhileTheOtherQueueWritesTheFrameState() throws {
        try XCTSkipUnless(Self.isThreadSanitized, """
            333 §2E: 这条探针只在 `swift test --sanitize thread` 下有意义 —— 正常套件跑它等于故意制造 \
            data race（而且竞态的结果没有可断言的确定值）。默认跳过。
            """)
        let (loupe, _, window) = try LoupeFrameStateRaceSupport.makeLoupe(workDir: workDir)
        defer { window.orderOut(nil) }

        // The identity the writes carry (`makeFrame`'s base identity), captured **on the main thread**
        // so the writer never reads `session` itself: this test is about the frame state, not about a
        // second race on the catalog.
        let identity = loupe.backdropPhotoKeyForTesting ?? "tsan-probe"
        let preview = LoupeFrameStateRaceSupport.image(LoupeFrameStateRaceSupport.rung)
        let full = LoupeFrameStateRaceSupport.image(LoupeFrameStateRaceSupport.stored)

        // Seed: the state a loupe has once its first frame landed, so `framing()` is on the decoded
        // branch (the one that crashed) from the first iteration on.
        loupe.installDecodedRungForTesting(preview, scale: 0.5, identity: identity)

        let deadline = Date().addingTimeInterval(2)
        let driver = DispatchQueue(label: "tsan.driver")
        let finished = DispatchSemaphore(value: 0)
        let writes = RaceProbeCounter()
        driver.async {
            var i = 1
            while Date() < deadline {
                // Alternating rung, like a zoom whose decode lands while the hand is still on the wheel.
                let scale: Double = (i % 2 == 0) ? 0.5 : 1.0
                loupe.installDecodedRungForTesting(i % 2 == 0 ? preview : full,
                                                  scale: scale, identity: identity)
                writes.set(i)
                i += 1
            }
            finished.signal()
        }

        var frames = 0
        while Date() < deadline {
            _ = loupe.framing()
            _ = loupe.hasIngestedPlaceholderSourceForProbe
            frames += 1
        }
        _ = finished.wait(timeout: .now() + 10)

        print("333 §2E · 主线程 framing \(frames) 次 · 第二队列写帧状态 \(writes.value) 次")
        XCTAssertGreaterThan(frames, 0)
        XCTAssertGreaterThan(writes.value, 0)
    }

    /// The same probe with the **shipped** `makeFrame` as the writer: one development of the real DNG at
    /// a small rung, then the **cached** rung over and over — which is the render queue's own hot path
    /// (`residentFrame → makeFrame(resolve: .residentOnly)`) and still writes all five fields.
    func testTheShippedMakeFrameWritesTheFrameStateUnderFraming() throws {
        try XCTSkipUnless(Self.isThreadSanitized, """
            333 §2E: 同上 —— 这条探针只在 `swift test --sanitize thread` 下有意义。
            """)
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("333: 没有 DNG 样品（PHOTONS_TEST_RAW）；这条探针只跑真渲染路径")
        }
        let (loupe, _, window) = try LoupeFrameStateRaceSupport.makeLoupe(workDir: workDir)
        defer { window.orderOut(nil) }
        let url = URL(fileURLWithPath: path)
        let viewport = ImageSize(width: 1600, height: 1000)
        var edit = EditModel.neutral
        edit.sharpen = SharpenGroup(amount: 0, radius: 2.0, detail: 25, masking: 0)

        // One development at a rung small enough to be a probe and not a benchmark: it puts a rung in
        // the ladder, so every later `makeFrame` is the cached one the render queue runs.
        //
        // 333 C — the writer passes the four render-queue values **explicitly** (a `RenderJob`
        // snapshot): a probe that read `cropTool` / `session` from its own queue would be a second,
        // self-inflicted race and would mask the one under test.
        let snapshot: (CanvasRole, Bool) = (.document, false)
        _ = try? loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.125, edit: edit,
                                 state: .fit, canvasRole: snapshot.0, cropIsActive: snapshot.1)

        let deadline = Date().addingTimeInterval(2)
        let driver = DispatchQueue(label: "tsan.render")
        let finished = DispatchSemaphore(value: 0)
        let writes = RaceProbeCounter()
        driver.async {
            var i = 1
            while Date() < deadline {
                _ = try? loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.125,
                                         edit: edit, state: .fit,
                                         canvasRole: snapshot.0, cropIsActive: snapshot.1)
                writes.set(i)
                i += 1
            }
            finished.signal()
        }
        var frames = 0
        while Date() < deadline {
            _ = loupe.framing()
            frames += 1
        }
        _ = finished.wait(timeout: .now() + 10)
        print("333 §2E · 主线程 framing \(frames) 次 · makeFrame 写 \(writes.value) 次")
        XCTAssertGreaterThan(writes.value, 0, "makeFrame 没跑起来，这条探针什么也没探到")
    }
}

// MARK: - ⑥ · the crash surface

/// **333 ⑥ — 200 random gestures on the demo library, and the process is still here.**
///
/// The `.ips` chain needs a real library, a real decode landing **while the hand is still on the wheel**,
/// and the real render queue — a fixture cannot reproduce "解码刚落地正在写". So this drives the shipped
/// controller on `~/Documents/photons-demo.photonslibrary`: random 滚动 / 缩放 / 图切换 / 进出裁切.
///
/// "A decode landed during a drag" is not a guess and not a timer: it is the **frame state's own token**
/// (identity + rung scale + source width, the values `framing()` reads) changing between two wheel
/// events of the same sweep. That is exactly the window the `.ips` chain needs, and it is measured on
/// the value that crashed, not on a boolean that happens to be true.
///
/// It is opt-in (`PHOTONS_DEMO_STRESS=1`): 200 gestures over 60 MP originals cost minutes and gigabytes,
/// which is not something the ordinary suite should pay for. It is not an `XCTSkip` — with the variable
/// unset it does nothing and says so.
@MainActor
final class LoupeCrashSurface333Tests: XCTestCase {

    /// The frame state the canvas is showing, as one comparable string — identity, rung scale and the
    /// source width the projection reports. A change between two reads is a frame that landed.
    private func frameToken(_ loupe: LoupeController) -> String {
        let projection = loupe.framing()
        return "\(loupe.decodedIdentityForTesting ?? "-")@\(projection?.decodeScale ?? -1)"
            + "/\(projection?.sourceWidth ?? -1)"
    }

    func testTwoHundredGesturesOnTheDemoLibraryDoNotKillTheProcess() throws {
        let library = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/photons-demo.photonslibrary")
        guard ProcessInfo.processInfo.environment["PHOTONS_DEMO_STRESS"] == "1" else {
            print("333 ⑥ · 未设 PHOTONS_DEMO_STRESS=1 —— 200 次手势压在 demo 库上要跑几分钟，不进常规套件")
            return
        }
        _ = NSApplication.shared
        let session = CatalogSession()
        try session.open(library)
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        let window = TestWindows.make(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        loupe.view.layoutSubtreeIfNeeded()
        loupe.autoRenderEnabled = true
        loupe.collectsHistogram = true
        CropUITestSupport.pump(0.2)

        let assets = session.assets.filter { $0.kind == .raw }
        XCTAssertGreaterThan(assets.count, 8, "333 ⑥: demo 库要有照片可切")
        var photo = 0
        session.selectOnly(assets[0].id)
        CropUITestSupport.pump(0.3)

        var gestures = 0, scrolls = 0, zooms = 0, switches = 0, crops = 0
        var identityChanges = 0
        var landings: [String] = []
        var dragSeconds: Double = 0
        let runStart = Date()
        var lastToken = frameToken(loupe)
        var seed: UInt64 = 0x3333_3333
        func next(_ bound: Int) -> Int {          // a deterministic LCG: the same 200 gestures every run
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        /// Read the frame state once. A change is a frame that landed; `drag` says whether the wheel was
        /// still turning when it did, which is the window the `.ips` chain needs.
        func noteLanding(_ label: String, drag: Bool) {
            let now = frameToken(loupe)
            guard now != lastToken else { return }
            identityChanges += 1
            let detail = "\(label)：\(lastToken) → \(now)"
            lastToken = now
            if drag { landings.append(detail) }
        }

        /// **The report's gesture**: the wheel keeps turning *across* the development, for as long as the
        /// rung takes to land (or `budget` runs out). Twelve to sixteen ticks is the floor, not the goal.
        /// Returning early on `want` landings only stops a sweep that has already proven the point.
        func dragAcrossTheLanding(_ label: String, budget: TimeInterval, want: Int) {
            let started = Date()
            let deadline = started.addingTimeInterval(budget)
            var ticks = 0
            var seen = 0
            while Date() < deadline, seen < want {
                loupe.scrollPan(deltaX: 0, deltaY: ticks % 2 == 0 ? 14 : -14,
                                precise: true, inverted: true)
                ticks += 1
                CropUITestSupport.pump(0.008)
                let before = identityChanges
                noteLanding("\(label) · scroll tick \(ticks)", drag: true)
                if identityChanges > before { seen += 1 }
            }
            dragSeconds += Date().timeIntervalSince(started)
        }

        for step in 0..<200 {
            switch next(20) {
            case 0, 1:                          // photo switch
                photo = (photo + 1) % assets.count
                session.selectOnly(assets[photo].id)
                session.mode = .loupe
                switches += 1
                // The decode for the new photo is requested by the frame the switch asks for. Stand at
                // 100 % (or 400 %, a bigger rung and so a slower development) and keep the wheel turning
                // across it — six switches get the long window, so "landed during the drag" cannot be a
                // coincidence of one lucky tick.
                if switches <= 6 {
                    loupe.zoom(to: switches % 2 == 0 ? 1 : 4, aroundView: CGPoint(x: 300, y: 200))
                    dragAcrossTheLanding("切图 #\(switches)（\(loupe.viewState.zoomLabel)）",
                                         budget: 10, want: 1)
                }
            case 2:                             // in / out of 裁切
                if loupe.isCropToolActive { loupe.cancelCropTool() } else { _ = loupe.beginCropTool() }
                crops += 1
            case 3, 4, 5, 6, 7:                 // zoom a stop
                loupe.zoom(to: [0.25, 0.3333, 0.5, 1, 2, 4][next(6)],
                           aroundView: CGPoint(x: 300, y: 200))
                zooms += 1
            default:                            // wheel pan, token watched across the eight events
                if !loupe.viewState.isActualSize { loupe.zoom(to: 1, aroundView: nil) }
                let wheelStarted = Date()
                for _ in 0..<8 {
                    loupe.scrollPan(deltaX: CGFloat(next(80) - 40),
                                    deltaY: CGFloat(next(80) - 40),
                                    precise: next(2) == 0, inverted: next(2) == 0)
                }
                scrolls += 1
                CropUITestSupport.pump(0.004)
                noteLanding("滚动 (step \(step))", drag: true)
                dragSeconds += Date().timeIntervalSince(wheelStarted)
            }
            gestures += 1
            CropUITestSupport.pump(0.004)
            if step % 20 == 0 { loupe.view.layoutSubtreeIfNeeded() }
        }
        // Let the last queued frame land, then say what the run cost.
        CropUITestSupport.pump(1.0)
        let totalSeconds = Date().timeIntervalSince(runStart)
        print("333 ⑥ · \(gestures) 次手势（滚动 \(scrolls) · 缩放 \(zooms) · 切图 \(switches) · 裁切 "
              + "\(crops)）· 解码中继续拖 \(landings.count) 次 · 进程仍在 · 解码请求 "
              + "\(loupe.decodeRequests) · 相机 \(loupe.viewState.zoomLabel)")
        print(String(format: "333 ⑥ · identity 变化 %d 次 · 其中拖动中 %d 次 · 拖动总时长 %.1f s / %.1f s = %d%%",
                     identityChanges, landings.count, dragSeconds, totalSeconds,
                     Int(dragSeconds / max(totalSeconds, 1e-9) * 100)))
        for (index, landing) in landings.enumerated() {
            print("333 ⑥ · 落地点 #\(index + 1)：\(landing)")
        }
        XCTAssertEqual(gestures, 200)
        XCTAssertGreaterThanOrEqual(landings.count, 3,
                                    "333 ⑥: 至少 3 次「拖动中解码落地」（实测 \(landings.count)）")
        window.orderOut(nil)
    }
}


// MARK: - ④ · one wheel event, one projection

/// **333 ④ — one synthetic wheel event must cost exactly one `framing()`.**
///
/// 崩溃的放大器：一个滚轮事件里 `framing()` 被算 **4 次**（`scrollPan` 的 `camera()`；
/// `setViewState → updateStatusChip → statusText → zoomLabel → camera()`；
/// `syncZoomSlider → currentZoomStop → camera()`；`setViewState` 的 `movesScale`）。两指滚动每秒
/// 60–120 个事件，每个事件都在 retain/release 一个 480 MB buffer，而解码刚落地正在写 —— 这就是
/// `.ips` 里那条链的节拍。
@MainActor
final class LoupeWheelFramingCostTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-loupe-wheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testOneWheelEventComputesTheProjectionOnce() throws {
        let (loupe, _, window) = try LoupeFrameStateRaceSupport.makeLoupe(workDir: workDir)
        defer { window.orderOut(nil) }
        loupe.installDecodedRungForTesting(
            LoupeFrameStateRaceSupport.image(LoupeFrameStateRaceSupport.rung),
            scale: LoupeFrameStateRaceSupport.rungScale)
        // A wheel only pans at 1:1 (`viewState.isActualSize`), so the gesture is measured from there.
        loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(loupe.viewState.isActualSize, "333 ④: 先站到 100 %，滚轮才有事可做")

        let before = loupe.framingCalls
        loupe.scrollPan(deltaX: 0, deltaY: 40, precise: false, inverted: true)
        let cost = loupe.framingCalls - before
        print("333 ④ · 一次 wheel 事件 framing() 调用 \(cost) 次 · centre → "
              + String(format: "%.3f / %.3f", loupe.viewState.centerX, loupe.viewState.centerY))
        XCTAssertEqual(cost, 1, "333 ④: 一次滚轮事件只允许算一次投影（实测 \(cost) 次）")
    }

    /// The same event **inside 裁切**, where the clamp (`clampedToCropCanvas`) and the ceiling
    /// (`cropZoomLimit`) are two more consumers of the projection: they take the one the event already
    /// built, so the count stays 1 instead of 3.
    func testOneWheelEventInsideCropAlsoComputesTheProjectionOnce() throws {
        let (loupe, session, window) = try LoupeFrameStateRaceSupport.makeLoupe(workDir: workDir)
        defer { window.orderOut(nil) }
        loupe.installDecodedRungForTesting(
            LoupeFrameStateRaceSupport.image(LoupeFrameStateRaceSupport.rung),
            scale: LoupeFrameStateRaceSupport.rungScale)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        loupe.cropTool.draft = CropToolController.Draft(
            crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), straighten: 0, lock: .original)
        loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(loupe.viewState.isActualSize)

        let before = loupe.framingCalls
        loupe.scrollPan(deltaX: 0, deltaY: 40, precise: false, inverted: true)
        let cost = loupe.framingCalls - before
        print("333 ④ · 裁切内一次 wheel 事件 framing() 调用 \(cost) 次")
        XCTAssertEqual(cost, 1, "333 ④: 裁切模式里也只算一次（实测 \(cost) 次）")
    }
}

// MARK: - ③ · the projection is the same value, twelve ways

/// **333 ③ — the new snapshot path and the old field reads must produce the *same* `LoupeFraming`.**
///
/// Twelve inputs: `{fit, 100 %, 400 %}` × `{裁切开, 关}` × `{有 rung, 无 rung}`. The expectation is the
/// pre-333 code transcribed here, one branch for branch: the resident buffer only describes the photo it
/// is a buffer of (`202 ④`), and with no rung the frame comes from `maskSourceSize` at scale 1.
@MainActor
final class LoupeFramingEquivalence333Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-loupe-equiv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// The old implementation, branch for branch — the reference the new one has to equal.
    private func legacyFraming(_ loupe: LoupeController, session: CatalogSession,
                               viewport: ImageSize, image: LinearImage?,
                               scale: Double) -> LoupeFraming? {
        let edit = loupe.cropTool.canvasEdit(from: session.edit)
        let role = loupe.cropTool.canvasRole
        if let image, loupe.decodedIdentityForTesting == loupe.backdropPhotoKeyForTesting {
            return LoupeFraming(viewport: viewport,
                                decoded: ImageSize(width: image.width, height: image.height),
                                decodeScale: scale,
                                edit: edit,
                                fitScale: loupe.currentCropWorkspaceFitScale,
                                fitMargin: loupe.fitMarginOverride,
                                canvasRole: role)
        }
        guard let asset = session.anchorAsset, asset.width != nil, asset.height != nil else { return nil }
        let source = session.maskSourceSize
            ?? ImageSize(width: max(1, asset.width ?? 1), height: max(1, asset.height ?? 1))
        return LoupeFraming(viewport: viewport,
                            decoded: source,
                            decodeScale: 1,
                            edit: edit,
                            fitScale: loupe.currentCropWorkspaceFitScale,
                            fitMargin: loupe.fitMarginOverride,
                            canvasRole: role)
    }

    func testTheSnapshotProjectionEqualsTheOldFieldReadsInTwelveInputs() throws {
        var groups = 0
        var lines: [String] = []
        for crop in [false, true] {
            for rung in [false, true] {
                for stop in ["fit", "100%", "400%"] {
                    let (loupe, session, window) = try LoupeFrameStateRaceSupport.makeLoupe(workDir: workDir)
                    defer { window.orderOut(nil) }
                    if crop {
                        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session),
                                      "333 ③: 裁切模式没打开（crop=\(crop) rung=\(rung) \(stop)）")
                        loupe.cropTool.draft = CropToolController.Draft(
                            crop: CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5),
                            straighten: 3, lock: .original)
                    }
                    var image: LinearImage?
                    if rung {
                        let buffer = LoupeFrameStateRaceSupport.image(LoupeFrameStateRaceSupport.rung)
                        image = buffer
                        loupe.installDecodedRungForTesting(buffer,
                                                          scale: LoupeFrameStateRaceSupport.rungScale)
                    }
                    switch stop {
                    case "fit": loupe.zoomToFit()
                    case "100%": loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
                    default: loupe.zoom(to: 4, aroundView: CGPoint(x: 160, y: 100))
                    }

                    let viewport = loupe.viewportPixels
                    let expected = legacyFraming(loupe, session: session, viewport: viewport,
                                                 image: image,
                                                 scale: LoupeFrameStateRaceSupport.rungScale)
                    let actual = loupe.framing(viewport: viewport)
                    XCTAssertEqual(actual, expected,
                                   "333 ③: crop=\(crop) rung=\(rung) \(stop) 的投影必须逐字段相等")
                    XCTAssertNotNil(actual, "333 ③: crop=\(crop) rung=\(rung) \(stop) 必须有投影")
                    groups += 1
                    if let actual {
                        lines.append(String(format: "crop=%d rung=%d %@ → src %.1f×%.1f ds %.2f role %@",
                                            crop ? 1 : 0, rung ? 1 : 0, stop,
                                            actual.sourceWidth, actual.sourceHeight,
                                            actual.decodeScale, "\(actual.canvasRole)"))
                    }
                }
            }
        }
        print("333 ③ · \(groups) 组新旧投影全等\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(groups, 12, "333 ③: 3 档 × 裁切开关 × 有无 rung = 12 组")
    }
}
