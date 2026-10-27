import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// The histogram's **screen-brightness indicator** stays true to the panel (2026-10-27).
///
/// The owner's ask: 「调节屏幕亮度后要更新直方图中屏幕亮度指示」. The ceiling tick and the `屏 1.20×`
/// chip were drawn from `histogram.headroom` — the budget the *measurement* was taken at — and rebuilt
/// only when a new frame arrived. On a settled window the brightness slider therefore moved the panel's
/// EDR budget (`maximumExtendedDynamicRangeColorComponentValue`) and the marker stood still, because
/// macOS **posts no notification for a brightness change**: there is nothing to observe, only something
/// to ask.
///
/// What is asserted here, each with the number that answers it:
///
///   ① **the number follows a sequence** — inject `1.0 → 1.695 → 4.08` through a `HeadroomSource` and
///      read the painted tick `x` and the painted chip text back off three real draws;
///   ② **it costs nothing when nothing moves** — ten reads of an unchanged screen repaint **0** times,
///      one moved budget repaints **1**;
///   ③ **a read is microseconds** and a 4.10 Mpx frame pays nothing for one poll per frame;
///   ④ **the poll stops when the card cannot be seen** — a hidden card or a window that is not key
///      retires the timer (`isPollingHeadroom` false, `headroomPollCount` frozen);
///   ⑤ **a real window follows a change within 300 ms** of the next presented frame, with the before /
///      after `frame` of the tick;
///   ⑥ **the row's ink is the same number** — the ceiling that moves the tick is what decides whether a
///      `+1.0` channel is painted as light the panel cannot show;
///   ⑦ and the two **red-proofs** pass by pulling the two rules out: no 0.5 s timer → a settled window
///      never notices a change at all; no "did it move" gate → every read repaints.
@MainActor
final class HistogramHeadroomRefreshTests: XCTestCase {

    private var windows: [NSWindow] = []
    /// 400 pt: `sdrWidth = hdrWidth = 200`, so one stop of the tail is 50 pt and a tick position is easy
    /// to check by hand as well as against `HistogramAxis`.
    private let cardWidth: CGFloat = 400

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - fixtures

    private func measuredHistogram(headroom: Double = 1) -> Histogram {
        func channel(_ sdr: [(Int, Int)], _ tail: [(Int, Int)]) -> HistogramChannel {
            var bins = [Int](repeating: 0, count: 256)
            for (i, v) in sdr { bins[i] = v }
            var hdr = [Int](repeating: 0, count: 64)
            for (i, v) in tail { hdr[i] = v }
            return HistogramChannel(bins: bins, hdrBins: hdr,
                                    clippedHigh: 0.012, clippedCeiling: 0.004, clippedLow: 0.001)
        }
        let red = channel([(128, 1284)], [(8, 812)])
        let green = channel([(128, 1291)], [(8, 819)])
        let blue = channel([(128, 1206)], [(8, 734)])
        return Histogram(binCount: 256, sampleCount: 898_432,
                         canvas: ImageSize(width: 720, height: 420),
                         roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                         sampleSize: ImageSize(width: 720, height: 420),
                         primaries: .sRGB, headroom: headroom,
                         red: red, green: green, blue: blue, luma: red)
    }

    /// A card with the display injected (and a measurement, so the tick is drawn at all).
    ///
    /// The measurement says `headroom: 1` on purpose: with a source the live number wins, so every
    /// position asserted below is the injected one and not the fixture's.
    private func makeCard(source: HeadroomSource?, histogram: Histogram? = nil) -> HistogramCardView {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: HistogramCardView.contentHeight)
        card.appearance = NSAppearance(named: .aqua)
        if let source { card.headroomSource = source }
        card.histogram = histogram ?? measuredHistogram()
        return card
    }

    private func makeWindow(_ card: HistogramCardView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cardWidth,
                                                  height: HistogramCardView.contentHeight + 40),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = card
        windows.append(window)
        return window
    }

    /// One real `draw` through AppKit's offscreen path — the readbacks (`lastCeilingMarkerX`,
    /// `lastCeilingText`, `channelValueColors`) are read off the paint, not off the input.
    @discardableResult
    private func render(_ card: HistogramCardView, scale: CGFloat = 2) -> NSBitmapImageRep {
        let w = max(1, Int(card.bounds.width * scale)), h = max(1, Int(card.bounds.height * scale))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = card.bounds.size
        card.needsDisplay = true
        card.cacheDisplay(in: card.bounds, to: rep)
        return rep
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - ① the tick and the chip follow the injected sequence

    func testTheTickAndTheChipFollowThreeInjectedHeadrooms() throws {
        let source = FixedHeadroomSource(headroom: 1)
        let card = makeCard(source: source)
        render(card)
        let axis = try XCTUnwrap(card.lastAxis)
        print(String(format: "轴：plot %.0f pt · SDR %.0f pt + 尾 %.0f pt · %.1f pt/stop · 白点 x %.1f",
                     axis.plot.width, axis.sdrWidth, axis.hdrWidth, axis.stopWidth, axis.sdrMaxX))

        var rows: [(value: Double, x: CGFloat, stops: Double, text: String, headroom: Double)] = []
        for value in [1.0, 1.695, 4.08] {
            source.headroom = value
            card.noteFramePresented()
            render(card)
            rows.append((value, card.lastCeilingMarkerX, card.lastCeilingStops,
                         card.lastCeilingText, card.lastCeilingHeadroom))
        }

        for (value, x, stops, text, headroom) in rows {
            XCTAssertEqual(x, axis.x(ceiling: value), accuracy: 1e-6,
                           "刻度 x 必须是 axis.x(ceiling: \(value))")
            XCTAssertEqual(stops, log2(max(value, 1)), accuracy: 1e-9)
            XCTAssertEqual(text, DisplayHeadroom.ceilingLabel(value), "芯片文字必须就是 headroom")
            XCTAssertEqual(headroom, value, accuracy: 1e-12,
                           "画出来的 headroom 必须就是注入的那个数（不是测量的 headroom）")
            // The semantics, not only the arithmetic: headroom is linear, so the tick is
            // `log2(h)` stops into the tail — 0 / 0.76 / 2.03 stops on this card.
            XCTAssertEqual(x, axis.sdrMaxX + CGFloat(log2(max(value, 1))) * axis.stopWidth, accuracy: 1e-6)
            print(String(format: "headroom %.3f× → 刻度 x %.2f pt（%+.3f 档，白点 %+.2f pt）· 读数 “%@”",
                         value, Double(x), stops, Double(x - axis.sdrMaxX), text))
        }

        // Strictly rightwards, and the SDR case is *exactly* the SDR/tail boundary — the honest picture
        // of a panel with no headroom at all.
        XCTAssertEqual(rows[0].1, axis.sdrMaxX, accuracy: 1e-9, "1.0× 的天花板就是白点分界")
        XCTAssertLessThan(rows[0].1, rows[1].1)
        XCTAssertLessThan(rows[1].1, rows[2].1)
        XCTAssertEqual(rows[1].1, 238.07, accuracy: 0.05, "1.695× = 0.7614 档 × 50 pt/stop")
        XCTAssertEqual(rows[2].1, 301.42, accuracy: 0.05, "4.08× = 2.0285 档 × 50 pt/stop")

        // The card's own arithmetic and the smoke's expectation agree by construction: same axis, same
        // function. (The tick is the *live* number, so the check is against the injected value.)
        XCTAssertNotEqual(rows[2].2, log2(max(measuredHistogram().headroom, 1)),
                          "反证：如果刻度还来自测量的 headroom，三个值会全落在白点上")
    }

    /// The same sequence seen as the *document's* number vs the *screen's*: a measurement taken at 1.2×
    /// and a panel now at 4.08× disagree, and the screen wins (that is the whole bug).
    func testTheScreenWinsOverTheMeasurementsOwnHeadroom() throws {
        let source = FixedHeadroomSource(headroom: 4.08)
        let card = makeCard(source: source, histogram: measuredHistogram(headroom: 1.2))
        render(card)
        XCTAssertEqual(try XCTUnwrap(card.displayedHeadroom), 4.08, accuracy: 1e-12)
        XCTAssertEqual(card.lastCeilingHeadroom, 4.08, accuracy: 1e-12)
        XCTAssertEqual(card.lastCeilingStops, log2(4.08), accuracy: 1e-9)
        XCTAssertEqual(card.lastCeilingText, "屏 4.08×")
        print(String(format: "测量的 headroom 1.20× vs 屏幕 4.08× → 刻度画在 %.1f pt（%.2f 档），测量自己的会是 %.1f pt",
                     Double(card.lastCeilingMarkerX), card.lastCeilingStops,
                     Double(card.lastAxis!.x(ceiling: 1.2))))
    }

    /// With **no** source the old rule stands — the measurement's own headroom — so every existing card
    /// (previews, unit fixtures) keeps its behaviour.
    func testWithoutASourceTheMeasurementStillDecides() {
        let card = makeCard(source: nil, histogram: measuredHistogram(headroom: 1.695))
        render(card)
        XCTAssertNil(card.displayedHeadroom)
        XCTAssertEqual(card.lastCeilingHeadroom, 1.695, accuracy: 1e-12)
        XCTAssertEqual(card.headroomRedrawCount, 0, "没有数值源就没有 headroom 引起的重画")
    }

    // MARK: - ② 变了才重画

    func testTenPollsOfAnUnchangedScreenRepaintNothing() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        render(card)
        let redraws = card.headroomRedrawCount
        let reads = card.headroomReadCount

        for _ in 0..<10 { card.noteFramePresented() }
        XCTAssertEqual(card.headroomRedrawCount - redraws, 0,
                       "headroom 没变：十次轮询必须 0 次重画（实际 \(card.headroomRedrawCount - redraws)）")
        XCTAssertEqual(card.headroomReadCount - reads, 10, "但确实读了十次 — 这才是成本")

        source.headroom = 4.08
        card.noteFramePresented()
        XCTAssertEqual(card.headroomRedrawCount - redraws, 1,
                       "变一次就一次重画（实际 \(card.headroomRedrawCount - redraws)）")

        for _ in 0..<10 { card.noteFramePresented() }
        XCTAssertEqual(card.headroomRedrawCount - redraws, 1,
                       "新值稳定后十次轮询又回到 0 次重画")

        // A change smaller than the gate is not a change: 1e-3 in the ceiling is 0.0004 pt on this card.
        source.headroom = 4.08 + 0.0004
        XCTAssertFalse(card.refreshHeadroomIfNeeded(), "小于 1e-3 的变化不算变化")
        XCTAssertEqual(card.headroomRedrawCount - redraws, 1)
        print(String(format: "重画计数：10 次不变 → 0 · 变一次 → 1 · 再 10 次 → 1 · 1e-3 以下的变化 → 仍 1（读 %d 次，画 %d 次）",
                     card.headroomReadCount, card.headroomRedrawCount))
    }

    /// 反证 ②: pull the gate out and the same ten polls repaint ten times. The counter is the same one;
    /// only the rule differs, so the assertion above is load-bearing rather than decorative.
    func testWithoutTheGateEveryPollRepaints() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        card.headroomRepaintsUnconditionally = true
        render(card)
        let before = card.headroomRedrawCount
        for _ in 0..<10 { card.noteFramePresented() }
        XCTAssertEqual(card.headroomRedrawCount - before, 10,
                       "反证：没有 1e-3 的门，十次不变的轮询就是十次重画")
        print("反证②：去掉「变了才重画」→ 10 次轮询 = \(card.headroomRedrawCount - before) 次重画（应为 10，故 ② 的 0 是有内容的）")
    }

    // MARK: - ③ 成本

    func testAPollCostsMicroseconds() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        render(card)
        let n = 1000
        var times: [Double] = []
        for _ in 0..<n {
            let t0 = CFAbsoluteTimeGetCurrent()
            card.refreshHeadroomIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1e6)
        }
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(format: "一次轮询（注入源）：p50 %.2f µs · p95 %.2f µs · 最大 %.2f µs",
                     p50, p95, sorted.last ?? 0))
        XCTAssertLessThan(p50, 20, "一次 headroom 轮询应该是微秒级（实测 \(p50) µs）")
        XCTAssertLessThan(p95, 200)
    }

    /// The live screen's read, for the record: what this machine actually reports, and the proof that
    /// every call really goes to `NSScreen` (`readCount` moves with each read).
    func testTheScreenSourceAsksThePropertyEveryTime() throws {
        let card = makeCard(source: nil)
        let window = makeWindow(card)
        let source = ScreenHeadroomSource(window: window)
        let first = source.readHeadroom()
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        let maximum = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        XCTAssertEqual(first.maximumEDRComponent, maximum, accuracy: 1e-12,
                       "读到的必须是 window.screen 的 maximumExtendedDynamicRangeColorComponentValue")
        XCTAssertEqual(first.headroom, DisplayHeadroom.headroom(fromMaximumEDR: maximum), accuracy: 1e-12)
        XCTAssertEqual(source.readCount, 1)
        _ = source.readHeadroom()
        XCTAssertEqual(source.readCount, 2, "每次询问都要真的去问 — 现场读数，不是缓存")
        print(String(format: "本机屏幕：%@ · max EDR %.3f → headroom %.3f×（potential %.3f×，读 %d 次）",
                     first.screenName ?? "—", maximum, first.headroom,
                     Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                     source.readCount))
        XCTAssertGreaterThanOrEqual(first.headroom, 1)
        XCTAssertLessThanOrEqual(first.headroom, DisplayHeadroom.maximumHeadroom)
        _ = card
    }

    /// 4.096 Mpx (2560 × 1600) — the viewport the other benches use — through the **real** present pass,
    /// with and without one poll per frame. A poll is a µs; a frame is ms; the difference must vanish in
    /// the noise. (24 frames each, reported as p50/p95.)
    func testAFourPointOneMegapixelFramePaysNothingForAPollPerFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device in this session")
        }
        let presenter = try CanvasPresenter()
        let canvas = ImageSize(width: 2560, height: 1600)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        func texture(_ width: Int, _ height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                     width: width, height: height,
                                                                     mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = .private
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let picture = try texture(canvas.width, canvas.height, usage: .shaderRead)
        let target = try texture(canvas.width, canvas.height, usage: [.renderTarget, .shaderRead])

        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        render(card)                                  // warm: font, layer, bitmap
        let redraws = card.headroomRedrawCount

        func frame() {
            presenter.renderForTest(picture, into: target)
        }
        for _ in 0..<4 { frame() }                    // the first frames pay the pipeline's warm-up

        var withoutPoll: [Double] = [], withPoll: [Double] = []
        for index in 0..<24 {
            if index % 2 == 0 {
                let t0 = CFAbsoluteTimeGetCurrent()
                frame()
                withoutPoll.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            } else {
                let t0 = CFAbsoluteTimeGetCurrent()
                // The worst case the timer could ever impose: one poll **per frame** (the real timer
                // asks twice a second, i.e. once per ~120 frames at 60 Hz).
                card.refreshHeadroomIfNeeded()
                frame()
                withPoll.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        let off = withoutPoll.sorted(), on = withPoll.sorted()
        let offP50 = off[off.count / 2], onP50 = on[on.count / 2]
        let offP95 = off[min(off.count - 1, Int(Double(off.count) * 0.95))]
        let onP95 = on[min(on.count - 1, Int(Double(on.count) * 0.95))]
        print(String(format: "4.096 Mpx 一帧（2560×1600，真实 present pass）：无轮询 p50 %.2f / p95 %.2f ms · "
                     + "每帧一次轮询 p50 %.2f / p95 %.2f ms · Δp50 %+.3f / Δp95 %+.3f ms",
                     offP50, offP95, onP50, onP95, onP50 - offP50, onP95 - offP95))
        XCTAssertEqual(card.headroomRedrawCount - redraws, 0,
                       "整段基准里 headroom 没变 — 一次重画都不该有（实际 \(card.headroomRedrawCount - redraws)）")
        // The claim is "≈ 0": a poll is ~1 µs against a ~ms frame, i.e. < 0.2 %.
        XCTAssertLessThan(abs(onP50 - offP50), max(0.5, offP50 * 0.05),
                          "一次轮询不该进入 4.10 Mpx 一帧的关键路径")
    }

    // MARK: - ④ 可见性：定时器只在卡片看得见时跑

    /// **The timer only runs while the card can be seen.** Four ways it can stop, each asserted on
    /// `isPollingHeadroom` *and* on the poll counter standing still:
    ///
    ///   ① the card is hidden (the inspector switched to a context with no histogram);
    ///   ② the window loses key — driven by the notification AppKit posts, because a test session has no
    ///      key window of its own (`NSApp.isActive` is false in `swift test`, measured);
    ///   ③ the app resigns active (the user went to another app);
    ///   ④ the card leaves the view hierarchy / the window is ordered out.
    func testTheTimerRunsOnlyWhileTheCardIsOnScreen() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        let window = makeWindow(card)
        window.orderFront(nil)
        pump(0.05)
        print("可见性：window.isVisible \(window.isVisible) · isKeyWindow \(window.isKeyWindow) · "
              + "NSApp.isActive \(NSApp.isActive) · shouldPoll \(card.shouldPollHeadroom)")

        XCTAssertTrue(card.isPollingHeadroom, "看得见的卡片必须有 0.5 s 定时器")
        let pollsBefore = card.headroomPollCount
        pump(1.2)
        XCTAssertGreaterThan(card.headroomPollCount - pollsBefore, 0,
                             "1.2 s 内应该跑过至少一次轮询（实际 \(card.headroomPollCount - pollsBefore)）")

        // ① hidden card.
        card.isHidden = true
        pump(0.05)
        XCTAssertFalse(card.isPollingHeadroom, "卡片隐藏后定时器必须停")
        let frozenHidden = card.headroomPollCount
        pump(1.2)
        XCTAssertEqual(card.headroomPollCount, frozenHidden, "停了就不该再计数")
        card.isHidden = false
        pump(0.05)
        XCTAssertTrue(card.isPollingHeadroom, "重新显示后恢复")

        // ② the window lost key (clicked into another window).
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        pump(0.05)
        XCTAssertTrue(card.headroomPollPaused)
        XCTAssertFalse(card.isPollingHeadroom, "窗口失焦后定时器必须停")
        let frozenUnfocused = card.headroomPollCount
        pump(1.2)
        XCTAssertEqual(card.headroomPollCount, frozenUnfocused)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        pump(0.05)
        XCTAssertTrue(card.isPollingHeadroom, "重新成为 key window 后恢复")

        // ③ the app resigned active.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        pump(0.05)
        XCTAssertFalse(card.isPollingHeadroom, "app 退到后台后定时器必须停")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        pump(0.05)
        XCTAssertTrue(card.isPollingHeadroom, "回到前台后恢复")

        // ④ order out / off the hierarchy.
        // Ordering a window out posts no notification this card can observe (`NSWindow` has no
        // `didOrderOffScreen` in Swift; occlusion is only tracked while the app is active), so the tick
        // itself is what retires the timer — at most one interval later. That is the design: the poll
        // checks the condition it was started under before doing any work.
        window.orderOut(nil)
        pump(0.6)
        XCTAssertFalse(card.isPollingHeadroom, "窗口收起来后定时器必须停（最迟一个 tick 后自己退场）")
        let frozenOrderedOut = card.headroomPollCount
        pump(1.0)
        XCTAssertEqual(card.headroomPollCount, frozenOrderedOut)
        window.orderFront(nil)
        render(card)                                  // a draw re-arms the poll (see `draw`)
        pump(0.05)
        XCTAssertTrue(card.isPollingHeadroom)
        card.removeFromSuperview()
        pump(0.6)
        XCTAssertFalse(card.isPollingHeadroom, "卡片离开视图树后定时器必须停")
        print("可见性：轮询总次数 \(card.headroomPollCount) · 隐藏/失焦/后台/收起/移除五种情况都停了")
    }

    /// ③ The poll is the only path that can see a brightness change on a settled window: no frame, no
    /// notification — only the timer.
    func testTheLowFrequencyTimerCatchesAChangeWithNoFrameAndNoNotification() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        let window = makeWindow(card)
        window.orderFront(nil)
        pump(0.05)
        render(card)                             // a draw is also what arms the poll
        XCTAssertTrue(card.isPollingHeadroom)
        let before = card.lastCeilingMarkerX
        let redraws = card.headroomRedrawCount

        source.headroom = 4.08                   // the brightness slider moved; nothing announced it
        pump(0.75)                               // 0.5 s poll + slack

        XCTAssertGreaterThan(card.headroomPollCount, 0)
        XCTAssertEqual(card.headroomRedrawCount - redraws, 1,
                       "低频轮询必须发现亮度变化并重画一次（实际 \(card.headroomRedrawCount - redraws)）")
        render(card)
        XCTAssertNotEqual(card.lastCeilingMarkerX, before, "刻度必须动")
        print(String(format: "无帧无通知：0.5 s 轮询在 %.2f s 内发现 1.695→4.08，刻度 %.1f → %.1f pt，轮询 %d 次",
                     0.75, Double(before), Double(card.lastCeilingMarkerX), card.headroomPollCount))
    }

    /// 反证 ①: **without the timer** the same scenario is invisible — the ceiling stands still while the
    /// screen changed. This is the failure the whole section exists to prevent, executed.
    func testWithoutTheTimerABrightnessChangeIsNeverNoticed() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        card.headroomPollingEnabled = false            // the timer, removed
        let window = makeWindow(card)
        window.orderFront(nil)
        pump(0.05)
        XCTAssertFalse(card.isPollingHeadroom, "反证的前提：定时器确实不在")
        render(card)
        let before = card.lastCeilingMarkerX
        let redraws = card.headroomRedrawCount

        source.headroom = 4.08
        pump(1.2)                                       // two would-be polls, and no frame is presented

        XCTAssertEqual(card.headroomPollCount, 0)
        XCTAssertEqual(card.headroomRedrawCount - redraws, 0, "没有定时器 → 一次重画都没有")
        render(card)
        XCTAssertEqual(card.lastCeilingMarkerX, before, "没有定时器 → 刻度一动不动（这就是修之前的 bug）")
        print(String(format: "反证①：去掉 0.5 s 定时器 → 1.2 s 内 0 次轮询、0 次重画，刻度停在 %.1f pt（屏幕已是 4.08×）",
                     Double(before)))
    }

    // MARK: - ⑤ 真窗口：变了之后 300 ms 内刻度就动

    func testARealWindowMovesTheCeilingWithinThreeHundredMilliseconds() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let card = makeCard(source: source)
        let window = makeWindow(card)
        window.orderFront(nil)
        window.makeKey()
        pump(0.05)
        render(card)
        let before = card.lastCeilingMarkerX
        XCTAssertEqual(card.lastCeilingHeadroom, 1.695, accuracy: 1e-12)

        // The slider moves. From here the clock runs: the next presented frame is what has to notice
        // (a 60 Hz window presents one every ~16 ms; this loop is that, one frame at a time).
        source.headroom = 4.08
        let started = CFAbsoluteTimeGetCurrent()
        var elapsed = 0.0
        var frames = 0
        while elapsed < 0.3 {
            frames += 1
            card.noteFramePresented()          // what `LoupeController.presentCanvas` calls
            render(card)
            elapsed = CFAbsoluteTimeGetCurrent() - started
            if card.lastCeilingMarkerX != before { break }
        }
        let after = card.lastCeilingMarkerX
        print(String(format: "真窗口：headroom 1.695→4.08 后 %.1f ms（%d 帧）刻度 %.1f → %.1f pt，读数 “%@”",
                     elapsed * 1000, frames, Double(before), Double(after), card.lastCeilingText))
        XCTAssertLessThan(elapsed, 0.3, "300 ms 内必须跟上")
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(card.lastCeilingHeadroom, 4.08, accuracy: 1e-12)
        XCTAssertEqual(card.lastCeilingText, "屏 4.08×")
    }

    // MARK: - ⑥ 指针读数用的是同一个数

    /// `R 245 G +1.0 B 64`, same pixel, two ceilings: on a 1.695× panel the green channel is light the
    /// panel cannot show (0.76 stop of budget), on a 4.08× one it is not (2.03 stops). The **digits do
    /// not move** — 「相对屏幕白点的 +x.x」 is the picture's — but the ink and the plot's tick both follow
    /// the one live headroom.
    func testTheRowInkAndTheTickAreTheSameLiveNumber() {
        let source = FixedHeadroomSource(headroom: 1.695)
        let histogram = measuredHistogram()
        let card = makeCard(source: source, histogram: histogram)
        let pixel = PointerPixel(linearRed: 0.9128, green: 2, blue: 0.0508, histogram: histogram)
        XCTAssertEqual(pixel.channelTexts, ["245", "+1.0", "64"])

        card.showPointerReadout(pixel)
        render(card)
        let narrowTick = card.lastCeilingMarkerX
        let narrowInk = card.channelOverWhite
        XCTAssertEqual(card.channelRowValues, ["245", "+1.0", "64"])
        XCTAssertEqual(card.channelOverWhite, [false, true, false],
                       "1.695× 的屏幕装不下 +1.0 档")
        XCTAssertEqual(card.channelValueColors[1], HistogramCardView.overWhiteColor)

        source.headroom = 4.08
        card.noteFramePresented()
        render(card)
        let wideTick = card.lastCeilingMarkerX
        let wideInk = card.channelOverWhite
        XCTAssertEqual(card.channelRowValues, ["245", "+1.0", "64"], "数字是画面的，不随屏幕变")
        XCTAssertEqual(card.channelRowText, "R 245 G +1.0 B 64")
        XCTAssertEqual(wideInk, [false, false, false],
                       "4.08× 的屏幕装得下 +1.0 档 → 不再是削顶色")
        XCTAssertEqual(card.channelValueColors[1], HistogramCardReadability.readoutColor(isDark: false))
        XCTAssertGreaterThan(wideTick, narrowTick, "同一时刻刻度也右移了（同一个数）")

        // The same statement in arithmetic, off the public helpers rather than the paint.
        XCTAssertEqual(pixel.channelsBeyond(headroom: 1.695), [false, true, false])
        XCTAssertEqual(pixel.channelsBeyond(headroom: 4.08), [false, false, false])
        func inkText(_ flags: [Bool]) -> String {
            flags.map { $0 ? "削顶" : "行色" }.joined(separator: "/")
        }
        print(String(format: "同一像素 “%@”：1.695× → 墨色 %@ / 刻度 %.1f pt；4.08× → 墨色 %@ / 刻度 %.1f pt",
                     card.channelRowText, inkText(narrowInk), Double(narrowTick),
                     inkText(wideInk), Double(wideTick)))
    }
}
