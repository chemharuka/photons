import XCTest
import AppKit
import SwiftUI
import PhotonsCore
@testable import PhotonsUI

/// 派单 069 — 曲线卡的读数行、坐标与 SDR 两态视图。
///
/// The card's coordinate is `0…2`: `0…1` is display code `0…255` (`1` = white), `1…2` is
/// `+0…+4 EV` (`EV = (x − 1)·4`). Claims:
///
///   1. **读数逐字** — `输入 233 输出 +1.22`，两位小数、四舍五入（半远离零）、正数 `+`、负数 U+2212。
///   2. **字体/颜色同源** — 与直方图 RGB 读数同一个常量 `HistogramCardView.numberFont`。
///   3. **行高两态相等**。
///   4. **两态视图** — `SDR ⇄ HDR`：SDR 只显 `x ∈ 0…1`（1 单位坐标 = 整个 box，即 2 倍）；HDR 显
///      **整条轴** `0…2`（SDR 半区 + HDR 半区，用户 2026-10-27 更正），1 单位坐标 = 半个 box。
///   5. **视图是 UI 状态** — 不改文档、不进历史、不改表、不改 key。
///   6. **刻度只有五档 SDR 码值** — `0 63 127 191 255`，位置全部由 axis 推出；右半区没有 stops 标记。
@MainActor
final class CurveReadoutTests: XCTestCase {

    // MARK: - 1. the text

    /// 四舍五入的边界：半值**远离零**，不是 printf 的"取偶"。
    func testTheReadingRoundsHalfAwayFromZeroOnTheBoundary() {
        XCTAssertEqual(CurvePointReadout.ev(0.005), "+0.01", "0.005 → 0.01（向上）")
        XCTAssertEqual(CurvePointReadout.ev(0.015), "+0.02", "0.015 → 0.02（向上）")
        XCTAssertEqual(CurvePointReadout.ev(0.125), "+0.13", "正好半格：远离零 → 0.13（取偶会给 0.12）")
        XCTAssertEqual(CurvePointReadout.ev(-0.005), "\u{2212}0.01")
        XCTAssertEqual(CurvePointReadout.ev(-0.125), "\u{2212}0.13", "负数也远离零")
        XCTAssertEqual(CurvePointReadout.ev(-0.0049), "0.00", "四舍五入到零 → 不带负号")
        XCTAssertEqual(CurvePointReadout.ev(0), "0.00", "零没有符号")
        XCTAssertEqual(CurvePointReadout.ev(1.0), "+1.00")
        XCTAssertEqual(CurvePointReadout.ev(12.345), "+12.35")
        XCTAssertEqual(CurvePointReadout.ev(-.infinity), "\u{2212}∞")
        XCTAssertFalse(CurvePointReadout.ev(-1.5).contains("-"), "负号是 U+2212，不是 ASCII")
        print("ev · 0.005→\(CurvePointReadout.ev(0.005)) · 0.015→\(CurvePointReadout.ev(0.015))"
              + " · 0.125→\(CurvePointReadout.ev(0.125))")
    }

    /// 用户的例子 `输入 233 输出 +1.22`，加上四个代表点。
    func testTheOwnerExampleAndFourRepresentativeReadings() {
        // x = 233/255 (code 233), y = 1 + 1.22/4 (1.22 EV above white).
        let example = CurvePoint(233.0 / 255, 1 + 1.22 / 4)
        XCTAssertEqual(CurvePointReadout.text(for: example), "输入 233 输出 +1.22")

        // 黑端: zero light in, zero light out — code 0 on both sides.
        XCTAssertEqual(CurvePointReadout.text(for: CurvePoint(0, 0)), "输入 0 输出 0")

        // 18 % 灰: display code 118 (`255·sRGB(0.18)`).
        let grey = CurvePoint(118.0 / 255, 118.0 / 255)
        XCTAssertEqual(CurvePointReadout.text(for: grey), "输入 118 输出 118")

        // 白: x = 1 is display white, code 255.
        XCTAssertEqual(CurvePointReadout.text(for: CurvePoint(1, 1)), "输入 255 输出 255")

        // +2 EV: y = 1.5. Above white the *input* says `EV` (there is no 300th code), the output is
        // the owner's own spelling, the bare number.
        let twoStops = CurvePoint(1.5, 1.5)
        XCTAssertEqual(CurvePointReadout.text(for: twoStops), "输入 +2.00 EV 输出 +2.00")

        // 2.25 would be +5 EV — the formula is not normalised to 0…2.
        XCTAssertEqual(CurvePointReadout.stops(2.25), 5, accuracy: 1e-12)
        print("readings · \(CurvePointReadout.text(for: example))"
              + " · 黑端 \(CurvePointReadout.text(for: CurvePoint(0, 0)))"
              + " · 18% \(CurvePointReadout.text(for: grey))"
              + " · 白 \(CurvePointReadout.text(for: CurvePoint(1, 1)))"
              + " · +2EV \(CurvePointReadout.text(for: twoStops))")
    }

    /// 同一个点在两种视图里读**同一个文本** —— 读数是点的函数，不是视图的函数。
    func testTheReadoutIsTheSameTextInBothViews() throws {
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(source.contains("CurvePointReadout.text(for: points[index])"),
                      "读数必须取自文档里的点")
        XCTAssertFalse(source.contains("func text(for point: CurvePoint, view:"), "读数不许带视图参数")

        let point = CurvePoint(0.91, 1.31)
        let plot = CGRect(x: 0, y: 0, width: 274, height: 189)
        let sdr = CurvePlotGeometry(plot: plot, view: .sdr)
        let hdr = CurvePlotGeometry(plot: plot, view: .hdr)
        XCTAssertNotEqual(sdr.point(point), hdr.point(point), "同一个点在两个视图里位置不同")
        XCTAssertEqual(CurvePointReadout.text(for: point), "输入 232 输出 +1.24")
        print("same text · \(CurvePointReadout.text(for: point)) · SDR x = "
              + String(format: "%.1f", sdr.point(point).x)
              + " · HDR x = " + String(format: "%.1f", hdr.point(point).x))
    }

    // MARK: - 2. the face is the histogram's

    func testTheReadingUsesTheHistogramsOwnNumberFont() throws {
        let panel = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(panel.contains(".font(Font(HistogramCardView.numberFont))"),
                      "读数行的字体必须是直方图那个常量")
        XCTAssertFalse(panel.contains("size: 9.5"), "不许在这里复制字号")
        XCTAssertTrue(panel.contains(".foregroundStyle(.secondary)"), "颜色是次要色")

        let card = try String(contentsOf: Self.histogramSource, encoding: .utf8)
        XCTAssertTrue(card.contains("public static let numberFont = NSFont.monospacedDigitSystemFont"
                                    + "(ofSize: 9.5, weight: .semibold)"))
        XCTAssertTrue(card.contains("valueFont: Self.numberFont"), "直方图用同一个常量")
        print("font · \(HistogramCardView.numberFont.fontName) "
              + "\(HistogramCardView.numberFont.pointSize) pt · 面板与直方图同一个常量")
    }

    func testTheReadoutRowKeepsItsHeight() {
        let blank = Self.fittingSize(CurvePanelFooter(reading: nil, resetChannel: {}, resetAll: {}),
                                     width: 244).height
        let short = Self.fittingSize(CurvePanelFooter(reading: "输入 0 输出 0",
                                                      resetChannel: {}, resetAll: {}), width: 244).height
        let long = Self.fittingSize(CurvePanelFooter(reading: "输入 +4.00 EV 输出 +4.00",
                                                     resetChannel: {}, resetAll: {}), width: 244).height
        XCTAssertEqual(short, blank, accuracy: 0.5, "按下点的那一刻行高不许变")
        XCTAssertEqual(long, blank, accuracy: 0.5, "最长的一条也一样")
        XCTAssertEqual(blank, CurvePanelMetrics.footerHeight, accuracy: 0.5)
        print("footer height · 空 \(blank) · 短 \(short) · 长 \(long) pt")
    }

    // MARK: - 4. the two views

    /// 两个状态各自的轴铺满 box：SDR 只显 `0…1`（1 单位坐标 = 整个 box，即 2 倍放大）；HDR 显
    /// **整条** `0…2`（SDR 半区 + HDR 半区，用户 2026-10-27 更正），1 单位坐标 = 半个 box。
    func testEachViewFillsTheBoxWithItsOwnAxis() {
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        let sdr = CurvePlotGeometry(plot: plot, view: .sdr)
        let hdr = CurvePlotGeometry(plot: plot, view: .hdr)

        // span 就是两态的全部内容：「SDR 展示 SDR 信息，HDR 展示 SDR+HDR 信息」。
        XCTAssertEqual(CurveViewMode.sdr.span, 0...CurvePoint.sdrBoundary)
        XCTAssertEqual(CurveViewMode.hdr.span, 0...CurvePoint.maximum,
                       "HDR 是整条轴（SDR 半区 + HDR 半区），不是 1…2")

        // 铺满：SDR 的 1 单位坐标 = 整个 box（2 倍放大）；HDR 的 2 单位 = 整个 box。
        XCTAssertEqual(sdr.x(u: 1) - sdr.x(u: 0), sdr.valueBox.width, accuracy: 1e-9)
        XCTAssertEqual(hdr.x(u: 2) - hdr.x(u: 0), hdr.valueBox.width, accuracy: 1e-9)

        for g in [sdr, hdr] {
            let span = g.span
            XCTAssertEqual(g.x(u: span.lowerBound), g.valueBox.minX, accuracy: 1e-9)
            XCTAssertEqual(g.x(u: span.upperBound), g.valueBox.maxX, accuracy: 1e-9)
            XCTAssertEqual(g.y(v: span.lowerBound), g.valueBox.maxY, accuracy: 1e-9)
            XCTAssertEqual(g.y(v: span.upperBound), g.valueBox.minY, accuracy: 1e-9)
        }
        XCTAssertEqual(sdr.x(u: 1), sdr.valueBox.maxX, accuracy: 1e-9, "SDR 视图右端是白点 x = 1")
        XCTAssertEqual(hdr.x(u: 0), hdr.valueBox.minX, accuracy: 1e-9, "HDR 视图左端是黑端 x = 0")
        XCTAssertEqual(hdr.x(u: 1), hdr.valueBox.midX, accuracy: 1e-9, "HDR 视图正中是白点 x = 1")
        XCTAssertEqual(hdr.x(u: 2), hdr.valueBox.maxX, accuracy: 1e-9, "HDR 视图右端是 +4 EV x = 2")

        // 双射：每个视图在自己的 span 里 x ↔ 屏幕 互为反函数。
        for g in [sdr, hdr] {
            let span = g.span
            for step in 0...100 {
                let x = span.lowerBound + (span.upperBound - span.lowerBound) * Double(step) / 100
                XCTAssertEqual(g.u(atX: g.x(u: x)), x, accuracy: 1e-12, "双射 x = \(x)")
                XCTAssertEqual(g.v(atY: g.y(v: x)), x, accuracy: 1e-12, "双射 y = \(x)")
            }
        }

        // **反证**: SDR 用「全幅」映射（`x/2` 跨全宽）会把白点放在正中 —— 它必须在右端。
        let box = sdr.valueBox
        XCTAssertNotEqual(sdr.x(u: 1), box.minX + box.width / 2, "反证：SDR 里 x = 1 不能在正中")
        XCTAssertEqual(sdr.x(u: 1) - box.minX, 2 * (box.width / 2), accuracy: 1e-9,
                       "SDR 视图的 1 个坐标单位是「全幅」视图的 2 倍")
        print("views · step SDR \(sdr.x(u: 1) - sdr.x(u: 0)) · HDR \(hdr.x(u: 2) - hdr.x(u: 0))"
              + " · box \(box.width) · HDR 白点 x = \(hdr.x(u: 1))（正中 \(box.midX)）")
    }

    /// **反证（用户 2026-10-27 更正）**：把 HDR 的 span 改回 071 的 `1…2`（只显 HDR 半区）必须让这个
    /// 套件变红。这条测试就是那句「必红」的可执行形式 —— 三件事只有「整条轴」才成立：
    ///
    ///   1. `hdr.span == 0…2`；
    ///   2. 白点 `x = 1` 落在 box **正中**（`1…2` 口径下它在左端）；
    ///   3. SDR 半区的点（`(0.5, 0.5)`）在 HDR 视图里**可见、可命中**（`1…2` 口径下被藏起来）。
    func testRevertingHdrToTheHalfSpanTurnsThisSuiteRed() {
        XCTAssertEqual(CurveViewMode.hdr.span, 0...CurvePoint.maximum,
                       "HDR = 整条轴 0…2 —— 改回 `1...2` 这条必红")

        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        let hdr = CurvePlotGeometry(plot: plot, view: .hdr)
        let box = hdr.valueBox
        XCTAssertEqual(hdr.x(u: CurvePoint.sdrBoundary), box.midX, accuracy: 1e-9,
                       "白点 x = 1 在 HDR 正中 —— `1...2` 口径下它会在左端")
        XCTAssertEqual(hdr.y(v: CurvePoint.sdrBoundary), box.midY, accuracy: 1e-9,
                       "白点 y = 1 在 HDR 正中 —— `1...2` 口径下它会在底边")

        let sdrHalf = CurvePoint(0.5, 0.5)
        XCTAssertTrue(hdr.isVisible(sdrHalf), "SDR 半区的点在 HDR 视图里可见 —— `1...2` 口径下不可见")
        XCTAssertEqual(hdr.hitIndex([sdrHalf], at: hdr.point(sdrHalf)), 0,
                       "可见即可命中 —— `1...2` 口径下 hitIndex 跳过了它")
        print("anti-proof · hdr.span = \(CurveViewMode.hdr.span) · 白点 x = "
              + String(format: "%.1f", hdr.x(u: 1)) + " / 正中 "
              + String(format: "%.1f", box.midX))
    }

    /// 视图外的点：SDR 视图里 **x = 1.2 的点不画**、点不到，但它仍然改变曲线；HDR 是**整条轴**，
    /// 两个半区的点都在里面（用户 2026-10-27 更正 —— 071 的 `1…2` 才把 SDR 半区的点藏起来）。
    func testPointsOutsideTheViewAreInvisibleAndUnhittableButStillBendTheCurve() {
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        let sdr = CurvePlotGeometry(plot: plot, view: .sdr)
        let hdr = CurvePlotGeometry(plot: plot, view: .hdr)
        let inside = CurvePoint(0.8, 0.4)
        let outside = CurvePoint(1.2, 1.2)

        XCTAssertTrue(sdr.isVisible(inside))
        XCTAssertFalse(sdr.isVisible(outside), "x = 1.2 在 SDR 视图之外")
        XCTAssertTrue(hdr.isVisible(outside), "HDR 是整条轴，x = 1.2 在里面")
        XCTAssertTrue(hdr.isVisible(inside), "HDR 是整条轴，SDR 半区的 x = 0.8 也在里面")
        XCTAssertNotEqual(CurveViewMode.hdr.span, CurvePoint.sdrBoundary...CurvePoint.maximum,
                          "反证：HDR 不是 `1…2`，否则 SDR 半区的点会被藏起来")

        let points = [CurvePoint(0, 0), inside, outside]
        XCTAssertEqual(sdr.hitIndex(points, at: sdr.point(inside)), 1)
        XCTAssertNil(sdr.hitIndex([CurvePoint(0, 0), outside], at: sdr.point(CurvePoint(2, 2))),
                     "点在视图外 → 它在框上的投影不许被点中")
        XCTAssertEqual(hdr.hitIndex(points, at: hdr.point(inside)), 1, "HDR 里 SDR 半区的点也点得到")
        XCTAssertEqual(hdr.hitIndex(points, at: hdr.point(outside)), 2, "HDR 里 HDR 半区的点也点得到")

        let bending = CurvePoint(1.2, 1.6)
        let withOutside = CurveLUT.buildOne([CurvePoint(0, 0), CurvePoint(1, 1), bending,
                                             CurvePoint(2, 2)])
        let without = CurveLUT.buildOne([CurvePoint(0, 0), CurvePoint(1, 1), CurvePoint(2, 2)])
        let delta = zip(withOutside, without).map { abs($0 - $1) }
        let biggest = delta.max() ?? 0
        let at = delta.firstIndex(of: biggest) ?? 0
        XCTAssertGreaterThan(biggest, 0.01, "视图外的点仍在表里，仍弯着曲线")
        print("visibility · x = 1.2 visible=\(sdr.isVisible(outside))"
              + " · 表最大差 \(String(format: "%.3f", biggest)) @ u="
              + String(format: "%.3f", Double(at) / 4095))
    }

    func testTheViewModeChangesNoDocumentAndNoHistory() throws {
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1), CurvePoint(2, 2)] }
        session.commitEdit(label: "曲线")
        let before = session.history.count
        let curve = session.edit.curve
        let table = CurveLUT.build(curve)
        let digest = session.edit.curve.keyString

        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: 200))
        _ = CurvePlotGeometry(plot: plot, view: .sdr)
        _ = CurvePlotGeometry(plot: plot, view: .hdr)
        XCTAssertEqual(session.edit.curve, curve)
        XCTAssertEqual(session.history.count, before)
        XCTAssertEqual(CurveLUT.build(session.edit.curve), table)
        XCTAssertEqual(session.edit.curve.keyString, digest, "视图不进 key，也不进 sidecar")
        let model = try String(contentsOf: Self.modelSource, encoding: .utf8)
        XCTAssertFalse(model.contains("CurveViewMode"), "EditModel.swift 不该认识视图")
        print("view state · history \(before) → \(session.history.count) · keyString 未变")
    }

    // MARK: - 6. the ticks

    /// 只有五档 SDR 码值，**两种视图都画同一组**：它们是轴上的位置，所以在 SDR 里 `255` 在右端、
    /// 在 HDR（整条轴）里 `255` 落在**正中**（码值半区到此结束）；右侧 HDR 半区没有可标的数字
    /// （069 取消了 stops），那一半只有网格。用户 2026-10-27 更正后不再按视图分支。
    func testTheTicksAreTheFiveSdrCodesInBothViews() throws {
        let axis = HDRCurveAxis.standard
        let ticks = CurveAxisTicks.ticks(axis)
        XCTAssertEqual(ticks.map(\.label), ["0", "63", "127", "191", "255"],
                       "stops 标记取消：轴上没有 +1/+2/+3/+4")
        XCTAssertEqual(CurveAxisTicks.ticks().map(\.label), ticks.map(\.label),
                       "默认参数就是这五档")
        XCTAssertEqual(ticks.count, 5, "两种视图同一组刻度：`ticks(_:)` 不再接 view")

        for (tick, code) in zip(ticks, [0.0, 63, 127, 191, 255]) {
            XCTAssertEqual(tick.x, 2 * axis.forward(CurveAxisTicks.displayCode(code)),
                           "码 \(code) 的位置来自 axis，差为 0")
            XCTAssertEqual(tick.x, code / 255, accuracy: 1e-15,
                           "x = c/255（encode∘decode 是恒等，差一个 ulp 以内）")
        }
        XCTAssertEqual(ticks.first?.x, 0)
        XCTAssertEqual(ticks.last?.x, 1, "255 码落在 x = 1（白点）")

        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: 200))
        let sdrGeometry = CurvePlotGeometry(plot: plot, view: .sdr)
        let positions = sdrGeometry.tickPositions(ticks)
        XCTAssertEqual(positions[0], sdrGeometry.valueBox.minX, accuracy: 1e-12)
        XCTAssertEqual(positions[4], sdrGeometry.valueBox.maxX, accuracy: 1e-12,
                       "SDR 视图里白点在右端（071：0…1 铺满）")
        for (position, tick) in zip(positions, ticks) {
            XCTAssertEqual(position - (sdrGeometry.valueBox.minX
                                       + CGFloat(tick.x) * sdrGeometry.valueBox.width), 0,
                           accuracy: 1e-12, "码 \(tick.label) 的 x 差必须为 0")
        }

        // HDR 视图是整条 0…2：同一组五档落在左半，`255` 正好在正中。
        let hdrGeometry = CurvePlotGeometry(plot: plot, view: .hdr)
        let hdrPositions = hdrGeometry.tickPositions(ticks)
        XCTAssertEqual(hdrPositions[0], hdrGeometry.valueBox.minX, accuracy: 1e-12)
        XCTAssertEqual(hdrPositions[4], hdrGeometry.valueBox.midX, accuracy: 1e-12,
                       "HDR 视图里 255 码落在正中（码值半区的右端），不是右端")
        for (position, tick) in zip(hdrPositions, ticks) {
            XCTAssertEqual(position, hdrGeometry.valueBox.minX
                                    + CGFloat(tick.x / 2) * hdrGeometry.valueBox.width,
                           accuracy: 1e-12, "HDR 视图里码 \(tick.label) 落在自己坐标的一半处")
        }

        // 源码里不许有 stops 刻度，也不许再按视图分支（两态同一组）。
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertFalse(source.contains("label: \"+\\(stop)\""), "stops 刻度必须删掉")
        XCTAssertTrue(source.contains("public static func ticks(_ axis: HDRCurveAxis = .standard)"
                                      + " -> [CurveAxisTick]"),
                      "ticks 不带 view 参数：两种视图画同一组五档")
        XCTAssertFalse(source.contains("guard view == .sdr"), "刻度不再按视图分支")

        print("ticks · \(ticks.map(\.label)) @ SDR "
              + positions.map { String(format: "%.2f", $0) }.joined(separator: ", ")
              + " · HDR " + hdrPositions.map { String(format: "%.2f", $0) }.joined(separator: ", "))
    }

    /// 按钮两态：文字 = **当前状态**（`SDR` / `HDR`，没有「区域」二字），按下即互切 —— 071。
    func testTheViewButtonSaysSdrThenHdr() throws {
        XCTAssertEqual(CurveViewMode.sdr.buttonTitle, "SDR")
        XCTAssertEqual(CurveViewMode.hdr.buttonTitle, "HDR")
        XCTAssertEqual(CurveViewMode.sdr.next, .hdr)
        XCTAssertEqual(CurveViewMode.hdr.next, .sdr, "两态互切")
        XCTAssertEqual(CurveViewMode.sdr.next.next, .sdr, "按两次回到原处")
        XCTAssertEqual(CurveViewMode.allCases.count, 2, "没有第三个「全部」状态")
        XCTAssertEqual(CurveViewMode.allCases.map(\.buttonTitle), ["SDR", "HDR"])
        for mode in CurveViewMode.allCases {
            XCTAssertFalse(mode.buttonTitle.contains("区域"), "按钮上不许有「区域」二字")
            XCTAssertFalse(mode.buttonTitle.contains("视图"), "按钮写的是状态，不是「视图」")
        }
        // 每个状态的 span：SDR 只显 `0…1`，HDR 是**整条轴** `0…2`（SDR + HDR，用户 2026-10-27 更正）。
        XCTAssertEqual(CurveViewMode.sdr.span, 0...1)
        XCTAssertEqual(CurveViewMode.hdr.span, 0...2, "HDR 是整条轴（SDR 半区 + HDR 半区），不是 1…2")

        // 旧文案（写的是「按下去会去哪」，而且把「全部」叫成 HDR）必须从源码里消失。
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertFalse(source.contains("\"SDR 区域\"") || source.contains("\"HDR 区域\""),
                       "「区域」二字的旧按钮文案必须删掉")
        XCTAssertTrue(source.contains("CurvePanelButton(mode.buttonTitle, identifier: \"curve.view\")"),
                      "按钮显示的就是当前状态的文案，不许在视图里再写一遍")
        XCTAssertTrue(source.contains("@State private var viewMode: CurveViewMode = .sdr"),
                      "卡片打开就是 SDR 视图")
        print("button · SDR →「\(CurveViewMode.sdr.buttonTitle)」· HDR →「\(CurveViewMode.hdr.buttonTitle)」")
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var panelSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/CurvePanel.swift")
    }
    private static var histogramSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/HistogramCard.swift")
    }
    private static var modelSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsCore/EditModel.swift")
    }

    private static func fittingSize<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
    private static var windows: [NSWindow] = []
}
