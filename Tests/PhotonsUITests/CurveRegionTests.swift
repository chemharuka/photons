import XCTest
import AppKit
import SwiftUI
import CryptoKit
import PhotonsCore
@testable import PhotonsUI

/// 070/071 — the curve card's two owner-reported problems, held as pixels.
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
///   2. **「曲线/控制点的切换还没好」** (071, 口径按用户 2026-10-27 的更正) — the card has two states,
///      `SDR` (`0…1`, magnified) and `HDR` (**the whole axis `0…2`**: the SDR half *plus* the HDR
///      half, magnified), and the button names the state it is **in**. Three things are measured on
///      the bitmaps, not on the geometry:
///        · the **curve's ink bounding box inside the value box** must fill it in *both* states
///          (≥ 90 % each way, edges on the box's edges). The half-empty picture the owner reported as
///          「HDR 模式下只占据左下 1/2」 was the `2·u`/`2·v` **sampling** bug, not the span — this
///          test holds both ends of it: a missing `2·u` shrinks the curve into the corner, and 071's
///          `1…2` span dropped the SDR half out of the HDR state.
///        · a known control point sits where its own state's axis puts it: `(0.5, 0.5)` in the
///          **middle** of the SDR box, and **`(1.0, 1.0)` — display white — in the middle of the HDR
///          box** (`1…2` put `(1.5,1.5)` there; 069's full-axis mapping put them at 1/4 · 3/4).
///          Measured as a 6 pt dot, i.e. a ≥ 5 pt dark run, at that pixel.
///        · the **curve passes through those control points**: at three fractions of the box the ink
///          is where `CurvePlotGeometry.y(v:)` says it is, so the line and the handles share one
///          transform — the 069/070 bug was exactly that they did not.
///      The press is real (`NSHostingView` in a key window, `sendEvent(mouseDown/mouseUp)` at the
///      capsule's measured centre), the round trip must be byte-identical, and the switch writes
///      nothing — same curve, same history, same `editRevision`, same encoded document bytes.
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

    // MARK: - ② SDR = the SDR half, HDR = the whole axis, and the curve fills the box in both

    /// 071（口径按用户 2026-10-27 更正）— **曲线铺满、点落在自己状态的轴该在的位置**，两种状态各测一遍，
    /// 全部以位图为准。
    ///
    /// One document, five probes chosen so the two states cannot pass with the same picture: `(0.5,0.5)`
    /// is the **centre of the SDR box**; `(1.0,1.0)` — display white — is the **centre of the HDR box**
    /// (071's `1…2` had white on the HDR box's left edge, so `(1,1)` there is itself the 反证); and two
    /// off-diagonal points, `(0.4,0.2)` in the SDR half and `(1.6,1.8)` in the HDR half. In the SDR
    /// state the HDR half's points are not drawn; in the HDR state **both halves are** — that is what
    /// 「HDR 展示 SDR+HDR 信息」 means as a pixel. `y` stays increasing throughout, so the engine's
    /// monotone cubic round-trips them unchanged.
    func testTheCurveFillsTheBoxAndThePointsSitOnTheirOwnAxisInBothViews() throws {
        let points = [CurvePoint(0, 0), CurvePoint(0.4, 0.2), CurvePoint(0.5, 0.5),
                      CurvePoint(1, 1), CurvePoint(1.5, 1.5), CurvePoint(1.6, 1.8), CurvePoint(2, 2)]
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = points }
        session.commitEdit(label: "曲线")

        let card = Self.host(CurvePanel(session: session), width: 274)
        let sdr = try XCTUnwrap(Self.snapshot(card.host))          // 071: the card opens in SDR
        let rows = sdr.bands(darkerThan: 250)
        let plot = try XCTUnwrap(sdr.plotBand(rows), "没找到绘图区那一带")
        let rowOffset = sdr.pt(plot.top) - CurvePanelMetrics.plotInset
        let capsule = try XCTUnwrap(Self.capsule(sdr))

        let curveBefore = session.edit.curve
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision
        let bytesBefore = try Self.documentBytes(session)
        let digestBefore = Histogram.editDigest(session.edit)

        // ── ① SDR: the curve fills the value box, (0.5,0.5) is its centre ────────────────────
        try Self.assertCurveFillsBox(sdr, view: .sdr, offset: rowOffset, label: "SDR")
        // Note: the expectations below are **literal fractions of the box**, never `geometry.point` —
        // otherwise a wrong span would move the expectation along with the picture and this test would
        // pass with the bug in place (071's mutation check).
        try Self.assertDot(at: sdr, fx: 0.5, fy: 0.5, offset: rowOffset,
                           message: "SDR 视图：(0.5, 0.5) 必须落在 valueBox 正中（2 倍放大）")
        try Self.assertDot(at: sdr, fx: 0.4, fy: 0.8, offset: rowOffset,
                           message: "SDR 视图：(0.4, 0.2) 在 40 % 宽、80 % 高")
        // 反证：069 的全幅映射把 (0.5,0.5) 放在 1/4 宽、3/4 高处，那颗点不许在那儿。
        XCTAssertLessThanOrEqual(
            Self.darkRun(sdr, at: Self.fullAxisPoint(CurvePoint(0.5, 0.5), offset: rowOffset)), 4,
            "SDR 视图里不该有第二颗点落在「全幅」映射的位置上")
        // 另一半的点不画、不可命中：查它在 HDR 视图里会占的那一格。
        XCTAssertLessThanOrEqual(
            Self.darkRun(sdr, at: Self.boxPoint(fx: 0.6, fy: 0.2, offset: rowOffset)), 4,
            "SDR 视图里不该出现 HDR 那一半的点 (1.6,1.8)")

        // ── ② press → HDR: **整条轴** 0…2，白点 (1,1) 落在 valueBox 正中 ────────────────────────
        Self.press(card, at: NSPoint(x: sdr.pt(capsule.midX), y: sdr.pt(capsule.midY)))
        let hdr = try XCTUnwrap(Self.snapshot(card.host))
        XCTAssertNotEqual(sdr.sha256, hdr.sha256, "两个状态的位图必须不同")
        try Self.assertCurveFillsBox(hdr, view: .hdr, offset: rowOffset, label: "HDR")
        try Self.assertDot(at: hdr, fx: 0.5, fy: 0.5, offset: rowOffset,
                           message: "HDR 视图：(1.0, 1.0)（显示白）必须落在 valueBox 正中（整条 0…2 铺满）")
        // (1.6, 1.8) 在整条轴上的位置：x/2 = 80 % 宽、1 − y/2 = 10 % 高。
        try Self.assertDot(at: hdr, fx: 0.8, fy: 0.1, offset: rowOffset,
                           message: "HDR 视图：(1.6, 1.8) 在 80 % 宽、10 % 高")
        // 整条轴 = SDR + HDR：SDR 半区的点 (0.4,0.2) 在 HDR 视图里 **也画**（x/2 = 20 %、1 − y/2 = 90 %）。
        // 反证：把 HDR 改回 071 的 `1…2`，这个点不被画，这条断言必红。
        try Self.assertDot(at: hdr, fx: 0.2, fy: 0.9, offset: rowOffset,
                           message: "HDR 视图：SDR 半区的 (0.4, 0.2) 也要画（整条轴 = SDR + HDR）")
        // 反证（第二重）：`1…2` 口径下白点 (1,1) 会被画在左下角，而不是正中。
        XCTAssertEqual(CurveViewMode.hdr.span, 0...CurvePoint.maximum,
                       "HDR 的 span 是整条轴 —— 改回 `1...2` 这条必红")
        // 刻度：两种视图都画同一组五档（255 在 SDR 的右端、HDR 的正中），但右侧 HDR 半区没有数字。
        let plotBottom = rowOffset + CurvePanelMetrics.plotRect(
            in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight)).maxY
        let tickTop = Int(plotBottom * sdr.scale)
        let tickBottom = Int((plotBottom + CurvePanelMetrics.tickBand - 2) * sdr.scale)
        let tickBandRows = tickTop..<tickBottom
        XCTAssertNotNil(hdr.bbox(of: 0...250, in: tickBandRows), "HDR 视图里刻度带也有字（同一组五档）")
        // …而右 1/4（HDR 半区）一个数都没有，否则上一条断言会因为「整条带都算有字」而空过。
        let rightQuarter = Int(0.75 * 274 * sdr.scale)..<Int(274 * sdr.scale)
        XCTAssertNil(hdr.bbox(of: 0...250, in: tickBandRows, cols: rightQuarter),
                     "HDR 半区没有可标的数字（069 取消了 stops）：右 1/4 不画刻度")
        // …而 SDR 视图里那一带**有**刻度（五档码值），否则上一条断言会因为「哪儿都没字」而空过。
        XCTAssertNotNil(sdr.bbox(of: 0...250, in: tickBandRows), "SDR 视图必须有刻度")

        // ── ③ 曲线经过自己的控制点：同一条变换的像素级证据 ─────────────────────────────────
        // The curve's ink is measured at three fractions of the box against the *geometry's* own
        // mapping (fed by the engine's table, the same numbers `draw` feeds it): a curve drawn with a
        // different ratio than the dots would miss those rows.
        try Self.assertCurveFollowsTheMapping(sdr, view: .sdr, points: points,
                                              offset: rowOffset, label: "SDR")
        try Self.assertCurveFollowsTheMapping(hdr, view: .hdr, points: points,
                                              offset: rowOffset, label: "HDR")

        // ── ④ press again → back to SDR, byte for byte ──────────────────────────────────────
        Self.press(card, at: NSPoint(x: sdr.pt(capsule.midX), y: sdr.pt(capsule.midY)))
        let back = try XCTUnwrap(Self.snapshot(card.host))
        XCTAssertEqual(sdr.sha256, back.sha256, "按两次必须逐字节回到原图")

        // ── ⑤ the switch is view state: no document, no history, no sidecar ────────────────
        XCTAssertEqual(session.edit.curve, curveBefore, "切视图不改文档")
        XCTAssertEqual(session.history.count, historyBefore, "切视图不产生历史")
        XCTAssertEqual(session.editRevision, revisionBefore, "切视图不 bump revision")
        XCTAssertEqual(try Self.documentBytes(session), bytesBefore, "sidecar 里的曲线块一个字节都不变")
        // …and the frame the canvas keys on is the same digest, so no stage is marked dirty by a view
        // switch (the points' `x`/`y` are still the `0…2` doubles they were).
        XCTAssertEqual(Histogram.editDigest(session.edit), digestBefore,
                       "切视图不改 editDigest（视图不进文档，也不进帧键）")

        print("redraw · sdr \(sdr.sha256.prefix(12)) · hdr \(hdr.sha256.prefix(12))"
              + " · 往返 " + (sdr.sha256 == back.sha256 ? "逐字节相同" : "不同")
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

    /// The value box the card actually draws into at the default 274 pt width.
    private static func valueBox() -> CGRect { geometry(.sdr).valueBox }

    /// A card coordinate → the bitmap point of the card at 274 pt of width.
    static func screenPoint(_ p: CurvePoint, view: CurveViewMode, offset: CGFloat) -> CGPoint {
        let inPlot = geometry(view).point(p)
        return CGPoint(x: inPlot.x, y: inPlot.y + offset)
    }

    /// A **literal fraction of the value box** (fx across, fy down) — the expectation for a picture the
    /// test is checking, so a wrong span cannot drag the expectation along with it.
    static func boxPoint(fx: CGFloat, fy: CGFloat, offset: CGFloat) -> CGPoint {
        let box = valueBox()
        return CGPoint(x: box.minX + fx * box.width, y: box.minY + fy * box.height + offset)
    }

    /// **The 反证's mapping for the SDR state**: the full axis `0…2` stretched across the box — 069's
    /// mapping, which is exactly what the HDR state draws now (2026-10-27) and exactly what the SDR
    /// state must *not*: in SDR it puts `(0.5,0.5)` at 25 % / 75 % instead of the centre.
    static func fullAxisPoint(_ p: CurvePoint, offset: CGFloat) -> CGPoint {
        let box = valueBox()
        return CGPoint(x: box.minX + CGFloat(p.x / 2) * box.width,
                       y: box.maxY - CGFloat(p.y / 2) * box.height + offset)
    }

    /// Assert a **dot** is drawn at `(fx, fy)` of the value box: the widest dark run near that row is at
    /// least 5 pt (a 3 pt radius disc), centred on the position within 2.5 pt.
    private static func assertDot(at image: Bitmap, fx: CGFloat, fy: CGFloat,
                                  offset: CGFloat, message: String) throws {
        let point = boxPoint(fx: fx, fy: fy, offset: offset)
        let run = darkRunDetail(image, at: point)
        XCTAssertGreaterThanOrEqual(run.width, 5,
                                    message + " — 该处应是 6 pt 的点，实测最宽 \(run.width) pt")
        XCTAssertEqual(run.centerX, point.x, accuracy: 2.5,
                       message + " — 点的中心 x 应为 \(point.x) pt，实测 \(run.centerX)")
        XCTAssertEqual(run.centerY, point.y, accuracy: 2.5, message + " — y 同理")
        print(String(format: "dot · %@: 实测 (%.1f, %.1f) · 期望 (%.1f, %.1f) · 宽 %.1f pt",
                     message, run.centerX, run.centerY, point.x, point.y, run.width))
    }

    /// The widest contiguous run of dark pixels around `point`, in points.
    static func darkRun(_ image: Bitmap, at point: CGPoint) -> CGFloat {
        darkRunDetail(image, at: point).width
    }

    // MARK: - the curve's ink, measured against the value box (071)

    /// The curve's ink bounding box inside the value box, as **pixels and as a percentage of the box**,
    /// asserted to fill it. This is the owner's 「HDR 模式下只占据左下 1/2」 as a number: a curve drawn
    /// at half scale in one corner fails `width ≥ 90 %` or `height ≥ 90 %`, and a curve that starts
    /// one inset in fails the edge equalities.
    ///
    /// The 120 threshold is what isolates the **curve**: `primary` at full opacity is black, the 4 × 4
    /// grid is 0.10 (≈ 229 on white), the dashed identity 0.22 (≈ 199), the plot's field 0.04 (≈ 245),
    /// and the 8 pt tick labels live outside these rows.
    static func assertCurveFillsBox(_ image: Bitmap, view: CurveViewMode, offset: CGFloat,
                                    label: String) throws {
        let box = valueBox()
        let s = image.scale
        let rows = Int(((offset + box.minY) * s).rounded())..<Int(((offset + box.maxY) * s).rounded())
        let cols = Int((box.minX * s).rounded())..<Int((box.maxX * s).rounded())
        let ink = try XCTUnwrap(image.inkBox(darkerThan: 120, cols: cols, rows: rows),
                                "\(label) 视图：绘图区里没有曲线的墨迹")

        let inkW = image.pt(ink.maxX - ink.minX + 1)
        let inkH = image.pt(ink.bottom - ink.top + 1)
        let widthPct = 100 * inkW / box.width
        let heightPct = 100 * inkH / box.height
        let maxY = image.pt(ink.bottom) - offset
        XCTAssertGreaterThanOrEqual(widthPct, 90,
                                    "\(label) 视图：曲线只占 box 宽的 \(String(format: "%.0f", widthPct))%")
        XCTAssertGreaterThanOrEqual(heightPct, 90,
                                    "\(label) 视图：曲线只占 box 高的 \(String(format: "%.0f", heightPct))%")
        XCTAssertEqual(image.pt(ink.minX), box.minX, accuracy: 2, "\(label)：墨迹左边不在 box 左边")
        XCTAssertEqual(image.pt(ink.maxX), box.maxX, accuracy: 2, "\(label)：墨迹右边不在 box 右边")
        XCTAssertEqual(maxY, box.maxY, accuracy: 2, "\(label)：墨迹**底边**不在 box 底边（左下 1/2 的形态）")
        XCTAssertEqual(image.pt(ink.top) - offset, box.minY, accuracy: 2, "\(label)：墨迹顶边不在 box 顶边")

        print(String(format: "ink · %@: x %.1f…%.1f (%.1f pt = %.0f%% of %.1f)"
                     + " · y %.1f…%.1f (%.1f pt = %.0f%% of %.1f)",
                     label, image.pt(ink.minX), image.pt(ink.maxX), inkW, widthPct, box.width,
                     image.pt(ink.top) - offset, maxY, inkH, heightPct, box.height))
    }

    /// The curve's ink is where the **geometry** says it is: at three fractions of the box, the dark
    /// run's centre row equals `yRaw(v:)` of the card coordinate the *engine's table* holds there —
    /// the same `2·u` / `2·v` pair `draw` feeds into the same two functions. Within 1.5 pt.
    ///
    /// Together with `assertDot` (the dots are drawn at `point(_:)`) this is the pixel-level form of
    /// 「同一变换」: the line and the handles cannot be drawn by two different ratios, because both are
    /// measured against the same function.
    static func assertCurveFollowsTheMapping(_ image: Bitmap, view: CurveViewMode,
                                             points: [CurvePoint], offset: CGFloat,
                                             label: String) throws {
        let box = valueBox()
        let geometry = geometry(view)
        let span = view.span
        let table = CurveLUT.buildOne(points)
        let last = table.count - 1
        var rows: [String] = []
        for fraction in [CGFloat(0.2), 0.5, 0.8] {
            let cardX = span.lowerBound + Double(fraction) * (span.upperBound - span.lowerBound)
            let sample = min(max(Int((cardX / 2 * Double(last)).rounded()), 0), last)
            let want = geometry.yRaw(v: 2 * Double(table[sample])) + offset
            let x = box.minX + fraction * box.width
            let got = try XCTUnwrap(image.inkCentreY(nearX: x, aroundY: want, window: 10),
                                    "\(label) 视图：x = \(String(format: "%.1f", x)) 处没有曲线的墨迹")
            XCTAssertEqual(got, want, accuracy: 1.5,
                           "\(label) 视图：曲线在 box 宽 \(Int(fraction * 100))% 处的高度是 "
                           + "\(String(format: "%.1f", got)) pt，几何说 \(String(format: "%.1f", want)) pt")
            rows.append(String(format: "%.0f%%→%.1f/%.1f", fraction * 100, got, want))
        }
        print("follows · \(label): " + rows.joined(separator: " · "))
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
            bbox(of: range, in: rows, cols: 0..<width)
        }

        /// The same, restricted to `cols` — how the tick band's right quarter is shown to be empty.
        func bbox(of range: ClosedRange<Int>, in rows: Range<Int>, cols: Range<Int>) -> Box? {
            let cols = cols.clamped(to: 0..<width)
            var left = Int.max, right = -1, top = Int.max, bottom = -1
            for y in rows.clamped(to: 0..<height) {
                for x in cols where range.contains(lum[y * width + x]) {
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

        /// The bounding box of the pixels **darker than `threshold`, inside `cols` × `rows`** — the
        /// curve's ink inside the value box, with the grid, the field and the dashed diagonal excluded
        /// by luminance alone (071).
        func inkBox(darkerThan threshold: Int, cols: Range<Int>, rows: Range<Int>) -> Box? {
            let rows = rows.clamped(to: 0..<height)
            let cols = cols.clamped(to: 0..<width)
            var left = Int.max, right = -1, top = Int.max, bottom = -1
            for y in rows {
                for x in cols where lum[y * width + x] < threshold {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= 0 else { return nil }
            return Box(left: left, right: right, top: top, bottom: bottom)
        }

        /// The centre row of the dark ink in a narrow column around `x`, searched ±`window` points
        /// around `aroundY`. `nil` when that column carries no curve.
        func inkCentreY(nearX x: CGFloat, aroundY: CGFloat, window: CGFloat) -> CGFloat? {
            let cx = Int((x * scale).rounded()), cy = Int((aroundY * scale).rounded())
            let span = Int((window * scale).rounded())
            var top = Int.max, bottom = -1
            for y in max(cy - span, 0)...min(cy + span, height - 1) {
                for dx in -Int(2 * scale)...Int(2 * scale) {
                    let px = cx + dx
                    guard px >= 0, px < width else { continue }
                    if lum[y * width + px] < 120 {
                        top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            guard bottom >= 0 else { return nil }
            return (CGFloat(top) + CGFloat(bottom)) / 2 / scale
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
