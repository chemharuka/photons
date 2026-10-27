import XCTest
import AppKit
import SwiftUI
import CryptoKit
import PhotonsCore
@testable import PhotonsUI

/// 070 — the curve card's two owner-reported problems, held as pixels.
///
/// Both complaints are about what the card *looks like*, so both are measured on a rendered
/// `NSHostingView` rather than argued from constants:
///
///   1. **「SDR 区域/HDR 区域 的选择框在下方，复位旁边」** — the switch must be a row of its own at the
///      **top** of the card, above the four channel tabs, with the whole plot between it and the
///      `读数/复位本通道/全部复位` line. The test measures the capsule's own rect (its 0.06 fill is the
///      only thing in the card that paints 240 on white), the tab row, the plot's top and the footer
///      row, then asserts the order **and the gaps**: 区域 行 → tabs → 绘图区 → 读数/复位. Putting the
///      switch back at the tail of the tab row (as `b57c794` did) fails the gap, not a comment.
///
///   2. **「切到 SDR 后曲线没有重新绘制」** — pressing the capsule must repaint the plot **as a 2×
///      magnified SDR region**. The mechanism is pinned in `CurvePanel.draw`: the table samples the
///      engine's axis (`CurvePoint.u == x/2`), so a sample's card coordinate is `2·u` across and `2·v`
///      up; the `0…2` migration fed the raw numbers, so every curve was drawn at half scale in the
///      lower-left quadrant, and in the SDR window (`xSpan` `0…1`) the gate then let the **whole**
///      table through — the switch repainted a picture of the wrong region. One document with a
///      control point at `(0.5, 0.8)` is rendered in both views and the point's own position is
///      measured: a 6 pt dot at the quarter-width / 40 % height in `.all`, at the half-width / 80 %
///      height in `.sdr` (the 2×), and only the 1.4 pt line at the other view's spot — so "same
///      curve, stretched" cannot pass. `(2, 2)` (the +4 EV end) is a dot in `.all` and is not drawn
///      at all in `.sdr`; all → sdr → all comes back byte-identical; and the switch writes nothing —
///      same curve, same history, same `editRevision`, same encoded document bytes.
///
/// The presses are real: `NSHostingView` in a key window, `window.sendEvent(mouseDown/mouseUp)` at the
/// capsule's measured centre. (`swift test` *can* deliver mouse events this way — the earlier note
/// that it cannot was about accessibility, which does need a live AX session.)
@MainActor
final class CurveRegionTests: XCTestCase {

    // MARK: - ① the switch has its own row, above the tabs, far from the reset row

    func testTheRegionSwitchHasItsOwnRowAboveTheTabsAndAwayFromTheResetRow() throws {
        let card = Self.host(CurvePanel(session: CatalogSession()), width: 274)
        let image = try XCTUnwrap(Self.snapshot(card.host))

        let capsule = try XCTUnwrap(Self.capsule(image), "没找到 0.06 填充的区域胶囊")
        let rows = image.bands(darkerThan: 250)
        // The tab row is the first band *below* the switch's own row (the switch's row also spans the
        // card's width — 区域 on the left, the capsule on the right — so "wide" alone cannot find it).
        let tabRow = try XCTUnwrap(rows.first { $0.top > capsule.bottom },
                                   "没找到 tab 行")
        let plot = try XCTUnwrap(image.plotBand(rows), "没找到绘图区那一带")
        let footer = try XCTUnwrap(rows.last { $0.maxX - $0.minX > Int(80 * image.scale) },
                                   "没找到读数/复位行")

        // ── the switch is inside its own 18 pt row, at the top, hard right ────────────────
        XCTAssertEqual(image.pt(capsule.top), 0, accuracy: 3,
                       "区域行必须是卡片的第一行（胶囊顶 ≈ 0 pt），实际 \(image.pt(capsule.top))")
        XCTAssertEqual(image.pt(capsule.bottom - capsule.top),
                       CurvePanelMetrics.modeRowHeight, accuracy: 3.5,
                       "区域行的高度就是 modeRowHeight")
        XCTAssertGreaterThan(image.pt(capsule.midX), 274 * 0.6,
                             "胶囊右对齐（中心落在右 40 % 内），实际 \(image.pt(capsule.midX))")

        // ── the order: 区域 行 → tab 行 → 绘图区 → 读数/复位 ───────────────────────────────
        XCTAssertLessThan(image.pt(capsule.bottom), image.pt(tabRow.top), "区域行在四个通道 tab 之上")
        XCTAssertLessThan(image.pt(tabRow.bottom), image.pt(plot.top), "tab 行在绘图区之上")
        XCTAssertLessThan(image.pt(plot.bottom), image.pt(footer.top), "绘图区在读数/复位行之上")

        // ── the plot's top is exactly the three rows above it, so nothing overlaps ─────────
        let expectedPlotTop = CurvePanelMetrics.modeRowHeight + 6 + CurvePanelMetrics.tabHeight + 6
        XCTAssertEqual(image.pt(plot.top), expectedPlotTop + CurvePanelMetrics.plotInset, accuracy: 1.2,
                       "绘图区顶 = 区域行 + 间距 + tab 行 + 间距（\(expectedPlotTop) pt），"
                       + "实际 \(image.pt(plot.top))")

        // ── and the footer is a whole plot (plus the tick band) away from the switch ───────
        let gap = image.pt(footer.top) - image.pt(capsule.bottom)
        XCTAssertGreaterThan(gap, 200, "胶囊与复位行之间隔着整个绘图区（> 200 pt），实际 \(gap) pt")
        XCTAssertEqual(card.host.fittingSize.height, 269, accuracy: 1,
                       "卡片总高 = 18 + 6 + 18 + 6 + 200 + 6 + 15")

        print("layout · 胶囊 (\(Self.f(image.pt(capsule.minX))), \(Self.f(image.pt(capsule.top))))"
              + "–(\(Self.f(image.pt(capsule.maxX))), \(Self.f(image.pt(capsule.bottom))))"
              + " · tab 行 \(Self.f(image.pt(tabRow.top)))…\(Self.f(image.pt(tabRow.bottom)))"
              + " · 绘图区 \(Self.f(image.pt(plot.top)))…\(Self.f(image.pt(plot.bottom)))"
              + " · 复位行 \(Self.f(image.pt(footer.top)))…\(Self.f(image.pt(footer.bottom)))"
              + " · 胶囊→复位行 \(Self.f(gap)) pt · 卡片高 \(Self.f(card.host.fittingSize.height)) pt")
    }

    // MARK: - ② switching really repaints: 2× magnified SDR region, document untouched

    func testSwitchingToTheSdrViewRepaintsThePlotAsATwiceMagnifiedRegion() throws {
        let session = CatalogSession()
        // Two control points the two views must disagree about: `(0.5, 0.8)` is inside both (and
        // lands at two different places — that is the 2×), `(1.2, 1.2)` is in the HDR half and is
        // therefore invisible in the SDR window. (1,1) is deliberately **not** a point: the white
        // point would sit exactly on the SDR view's top-right corner and hide the crop.
        session.applyEdit {
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.8),
                              CurvePoint(1.2, 1.2), CurvePoint(2, 2)]
        }
        session.commitEdit(label: "曲线")

        let card = Self.host(CurvePanel(session: session), width: 274)
        let all = try XCTUnwrap(Self.snapshot(card.host))
        let rows = all.bands(darkerThan: 250)
        let plot = try XCTUnwrap(all.plotBand(rows), "没找到绘图区那一带")
        // The GeometryReader's own origin: the plot band's first ink row is the frame 0.5 pt inside it.
        let rowOffset = all.pt(plot.top) - CurvePanelMetrics.plotInset

        let curveBefore = session.edit.curve
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision
        let bytesBefore = try Self.documentBytes(session)

        // ── press the capsule we just measured ────────────────────────────────────────────
        let capsule = try XCTUnwrap(Self.capsule(all))
        Self.press(card, at: NSPoint(x: all.pt(capsule.midX), y: all.pt(capsule.midY)))
        let sdr = try XCTUnwrap(Self.snapshot(card.host))

        // ── ① the two bitmaps differ, and they differ *inside the plot* ───────────────────
        let plotDiff = all.difference(sdr, rowsY: plot.top..<plot.bottom)
        XCTAssertGreaterThan(plotDiff, 500, "按下区域后绘图区必须有像素变化，实际 \(plotDiff) px")
        XCTAssertNotEqual(all.sha256, sdr.sha256, "两张位图整体必须不同")

        // ── ② a point lands where the card says, in both views (the 2×, measured) ─────────
        let probe = CurvePoint(0.5, 0.8)
        try Self.assertDot(all, view: .all, card: probe, offset: rowOffset,
                           message: "全部视图：(0.5, 0.8) 应在 1/4 宽、40 % 高")
        try Self.assertDot(sdr, view: .sdr, card: probe, offset: rowOffset,
                           message: "SDR 视图：(0.5, 0.8) 应在 1/2 宽、80 % 高（2 倍放大）")
        // The other view's spot must carry no dot: a "zoom" that draws the same point twice is exactly
        // the "curve did not redraw" the owner reported.
        let probeAll = Self.screenPoint(probe, view: .all, offset: rowOffset)
        let probeSdr = Self.screenPoint(probe, view: .sdr, offset: rowOffset)
        XCTAssertLessThanOrEqual(Self.darkRun(sdr, at: probeAll), 4,
                                 "SDR 视图里不该有第二颗点落在全部视图的位置上")
        XCTAssertLessThanOrEqual(Self.darkRun(all, at: probeSdr), 4,
                                 "全部视图里不该有第二颗点落在 SDR 视图的位置上")

        // ── a point in the HDR half: a dot in `.all`, **not drawn** in `.sdr` ──────────────
        //
        // This is what "the SDR view is the SDR *region*" means as a picture: the +0.8 EV point is on
        // the card in the all view and off the window in the SDR view, where only the curve's cropped
        // line remains.
        let hdr = CurvePoint(1.2, 1.2)
        try Self.assertDot(all, view: .all, card: hdr, offset: rowOffset,
                           message: "全部视图：(1.2, 1.2) 应在 60 % 宽、60 % 高处")
        XCTAssertLessThanOrEqual(Self.darkRun(sdr, at: Self.screenPoint(hdr, view: .all, offset: rowOffset)), 4,
                                 "SDR 视图：全部视图画 (1.2, 1.2) 的那个像素上没有点")
        // …and the curve is cut at display white: the window's top-right corner carries the line's end,
        // not a point.
        let corner = Self.screenPoint(CurvePoint(2, 2), view: .sdr, offset: rowOffset)
        XCTAssertLessThanOrEqual(Self.darkRun(sdr, at: corner), 4,
                                 "SDR 视图：曲线在 x = 1（显示白）处被裁掉，右上角只有线尾")

        // ── ③ all → sdr → all, byte for byte ─────────────────────────────────────────────
        Self.press(card, at: NSPoint(x: all.pt(capsule.midX), y: all.pt(capsule.midY)))
        let back = try XCTUnwrap(Self.snapshot(card.host))
        XCTAssertEqual(all.sha256, back.sha256, "切回全部视图必须逐字节回到原图")

        // ── the switch is view state: no document, no history, no sidecar ────────────────
        XCTAssertEqual(session.edit.curve, curveBefore, "切区域不改文档")
        XCTAssertEqual(session.history.count, historyBefore, "切区域不产生历史")
        XCTAssertEqual(session.editRevision, revisionBefore, "切区域不 bump revision（画布不用重渲染）")
        XCTAssertEqual(try Self.documentBytes(session), bytesBefore, "sidecar 里的曲线块一个字节都不变")

        print("redraw · 绘图区变化 \(plotDiff) px · all \(all.sha256.prefix(12)) · sdr \(sdr.sha256.prefix(12))"
              + " · 往返 " + (all.sha256 == back.sha256 ? "逐字节相同" : "不同")
              + " · 历史 \(session.history.count) · revision \(session.editRevision)")
    }

    /// The region capsule's own rect: the rightmost 0.06-fill cluster inside the card's **first row**.
    /// (0.06 of `primary` over white is 240; the tab row's 0.05 is 242 and the plot's 0.04 is 245, so
    /// the narrow band 235…244 plus the row limit is what isolates the capsule.)
    static func capsule(_ image: Bitmap) -> Bitmap.Box? {
        image.rightmostCluster(of: 235...244,
                               rows: 0..<Int(CurvePanelMetrics.modeRowHeight * image.scale))
    }

    // MARK: - where a point lands, measured on the two bitmaps

    private static func geometry(_ view: CurveViewMode) -> CurvePlotGeometry {
        CurvePlotGeometry(plot: CurvePanelMetrics.plotRect(
            in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight)), view: view)
    }

    /// A card coordinate → the bitmap point of the card at 274 pt of width.
    static func screenPoint(_ p: CurvePoint, view: CurveViewMode, offset: CGFloat) -> CGPoint {
        let inPlot = geometry(view).point(p)
        return CGPoint(x: inPlot.x, y: inPlot.y + offset)
    }

    /// Assert a **dot** is drawn at `p` for `view`: the widest dark run near that row is at least 5 pt
    /// (a 3 pt radius disc), centred on the position within 2.5 pt.
    private static func assertDot(_ image: Bitmap, view: CurveViewMode, card: CurvePoint,
                                  offset: CGFloat, message: String) throws {
        let point = screenPoint(card, view: view, offset: offset)
        let run = darkRunDetail(image, at: point)
        XCTAssertGreaterThanOrEqual(run.width, 5,
                                    message + " — 该处应是 6 pt 的点，实测最宽 \(run.width) pt")
        XCTAssertEqual(run.centerX, point.x, accuracy: 2.5,
                       message + " — 点的中心 x 应为 \(point.x) pt，实测 \(run.centerX)")
        XCTAssertEqual(run.centerY, point.y, accuracy: 2.5, message + " — y 同理")
    }

    /// The widest contiguous run of dark pixels around `point`, in points.
    static func darkRun(_ image: Bitmap, at point: CGPoint) -> CGFloat {
        darkRunDetail(image, at: point).width
    }

    struct Run { let width: CGFloat, centerX: CGFloat, centerY: CGFloat }

    /// Search ±2 pt of rows around `point.y` for the widest dark run within ±6 pt of `point.x` and
    /// report its width and centre: a 6 pt disc and a 1.4 pt line then differ by width alone, which is
    /// what makes "the dot moved" a measurement instead of an impression.
    static func darkRunDetail(_ image: Bitmap, at point: CGPoint) -> Run {
        let cx = point.x * image.scale, cy = point.y * image.scale
        var best = Run(width: 0, centerX: point.x, centerY: point.y)
        for dy in -Int(2 * image.scale)...Int(2 * image.scale) {
            let y = Int(cy) + dy
            guard y >= 0, y < image.height else { continue }
            let row = y * image.width
            var x = max(Int(cx - 6 * image.scale), 0)
            let end = min(Int(cx + 6 * image.scale), image.width - 1)
            while x <= end {
                guard image.lum[row + x] < 120 else { x += 1; continue }
                let start = x
                while x <= end, image.lum[row + x] < 120 { x += 1 }
                let width = CGFloat(x - start) / image.scale
                if width > best.width {
                    best = Run(width: width,
                               centerX: (CGFloat(start) + CGFloat(x - 1)) / 2 / image.scale,
                               centerY: CGFloat(y) / image.scale)
                }
            }
        }
        return best
    }

    // MARK: - the document's encoded bytes (what the sidecar holds)

    private static func documentBytes(_ session: CatalogSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session.edit.curve)
    }

    private static func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    // MARK: - the harness: a real hosting view, a real window, real mouse events

    struct Hosted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
    }

    private static var windows: [NSWindow] = []

    static func host(_ view: some View, width: CGFloat) -> Hosted {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(
            view.environment(\.colorScheme, .light).background(Color.white)))
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // A *titled* window on purpose: a borderless one never becomes key, and a SwiftUI gesture in a
        // non-key window ignores the synthetic events. `makeKeyAndOrderFront` is what makes the press
        // below a real one — the same click the owner made in the app.
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return Hosted(host: host, window: window)
    }

    /// One press at `point` (card coordinates, y down), then a settled runloop so the redraw lands.
    static func press(_ hosted: Hosted, at point: NSPoint) {
        let inWindow = NSPoint(x: point.x, y: hosted.host.bounds.height - point.y)
        let now = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                           timestamp: now, windowNumber: hosted.window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: 1)!
            hosted.window.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }

    // MARK: - a bitmap and the three readings this file needs from it

    struct Bitmap {
        let width: Int
        let height: Int
        let scale: CGFloat
        let lum: [Int]
        let sha256: String

        func pt(_ v: Int) -> CGFloat { CGFloat(v) / scale }

        struct Band { let top: Int, bottom: Int, minX: Int, maxX: Int }

        /// Contiguous bands of rows that contain any pixel darker than `threshold`.
        func bands(darkerThan threshold: Int) -> [Band] {
            var out: [Band] = []
            var start: Int?
            var minX = Int.max, maxX = -1
            for y in 0..<height {
                var ink = 0
                var rowMinX = Int.max, rowMaxX = -1
                for x in 0..<width where lum[y * width + x] < threshold {
                    ink += 1
                    rowMinX = min(rowMinX, x)
                    rowMaxX = max(rowMaxX, x)
                }
                if ink > 0 {
                    if start == nil { start = y }
                    minX = min(minX, rowMinX)
                    maxX = max(maxX, rowMaxX)
                } else if let s = start {
                    out.append(Band(top: s, bottom: y - 1, minX: minX, maxX: maxX))
                    start = nil; minX = Int.max; maxX = -1
                }
            }
            if let s = start { out.append(Band(top: s, bottom: height - 1, minX: minX, maxX: maxX)) }
            return out
        }

        /// The plot's own band: the 200 pt tall block between the tabs and the tick band.
        func plotBand(_ bands: [Band]) -> Band? {
            bands.first {
                let height = pt($0.bottom - $0.top)
                return height > 150 && height < 230
            }
        }

        /// The rightmost horizontal cluster of pixels whose luminance falls in `range`, inside `rows`.
        ///
        /// A plain bounding box is not enough here: the tab row's 0.05 fill paints 242 as well, so a
        /// box over both rows spans the whole card. Clusters (columns separated by more than `gap`
        /// empty columns) separate 区域 from the capsule, and the capsule is the rightmost one.
        func rightmostCluster(of range: ClosedRange<Int>, rows: Range<Int>,
                              gap: Int = 4) -> Box? {
            let rows = rows.clamped(to: 0..<height)
            var columnHasInk = [Bool](repeating: false, count: width)
            for y in rows {
                let row = y * width
                for x in 0..<width where range.contains(lum[row + x]) { columnHasInk[x] = true }
            }
            var clusters: [(start: Int, end: Int)] = []
            var start: Int?
            var empties = 0
            for x in 0..<width {
                if columnHasInk[x] {
                    if start == nil { start = x }
                    empties = 0
                } else {
                    empties += 1
                    if let s = start, empties > gap {
                        clusters.append((s, x - empties))
                        start = nil
                    }
                }
            }
            if let s = start { clusters.append((s, width - 1)) }
            guard let last = clusters.last else { return nil }
            var top = height, bottom = -1
            for y in rows {
                let row = y * width
                for x in last.start...last.end where range.contains(lum[row + x]) {
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard bottom >= 0 else { return nil }
            return Box(left: last.start, right: last.end, top: top, bottom: bottom)
        }

        /// The bounding box of the pixels whose luminance falls in `range`, searched in `rows` only.
        func bbox(of range: ClosedRange<Int>, in rows: Range<Int>) -> Box? {
            var left = Int.max, right = -1, top = Int.max, bottom = -1
            for y in rows.clamped(to: 0..<height) {
                for x in 0..<width where range.contains(lum[y * width + x]) {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= 0 else { return nil }
            return Box(left: left, right: right, top: top, bottom: bottom)
        }

        struct Box {
            let left: Int, right: Int, top: Int, bottom: Int
            var minX: Int { left }
            var maxX: Int { right }
            var midX: Int { (left + right) / 2 }
            var midY: Int { (top + bottom) / 2 }
        }

        /// How many pixels differ between two bitmaps, limited to `rowsY`.
        func difference(_ other: Bitmap, rowsY: Range<Int>) -> Int {
            var n = 0
            let rows = rowsY.clamped(to: 0..<min(height, other.height))
            let cols = min(width, other.width)
            for y in rows {
                let mine = y * width, theirs = y * other.width
                for x in 0..<cols where lum[mine + x] != other.lum[theirs + x] { n += 1 }
            }
            return n
        }
    }

    static func snapshot(_ host: NSView) -> Bitmap? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        var lum = [Int](repeating: 255, count: w * h)
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * spp
                lum[y * w + x] = (Int(data[o]) * 299 + Int(data[o + 1]) * 587
                                  + Int(data[o + 2]) * 114) / 1000
                let d = (y * w + x) * 4
                for c in 0..<min(spp, 4) { raw[d + c] = data[o + c] }
            }
        }
        let digest = SHA256.hash(data: Data(raw))
        return Bitmap(width: w, height: h,
                      scale: CGFloat(w) / max(host.bounds.width, 1),
                      lum: lum,
                      sha256: digest.map { String(format: "%02x", $0) }.joined())
    }
}
