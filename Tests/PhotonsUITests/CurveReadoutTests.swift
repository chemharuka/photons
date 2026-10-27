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
///   6. **刻度：五个码值，HDR 视图再补四档 stops** — `0 63 127 191 255` 位置全部由 axis 推出；
///      `+1 … +4` 只在 HDR 视图里（用户 2026-10-27，取代 069 的「stops 标记取消」只对 HDR 态）。
///   7. **读数不带 `EV`** — `输入 233 输出 +1.22`，并且最宽的一条仍在读数行的可用宽度里（见
///      `testTheReadoutFitsTheRowWithoutTheEvSuffix`）。
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

        // +1.22 above white is a stop count, spelled the same way on both sides: **no `EV`**
        // (user 2026-10-27 — the suffix did not fit the row; `output` never had one).
        let example2 = CurvePoint(1.3, 1 + 1.22 / 4)
        XCTAssertEqual(CurvePointReadout.text(for: example2), "输入 +1.20 输出 +1.22")
        let twoStops = CurvePoint(1.5, 1.5)
        XCTAssertEqual(CurvePointReadout.text(for: twoStops), "输入 +2.00 输出 +2.00")
        XCTAssertFalse(CurvePointReadout.text(for: twoStops).contains("EV"),
                       "读数行里没有 `EV` 二字（2026-10-27：放不下）")

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
        let long = Self.fittingSize(CurvePanelFooter(reading: "输入 +4.00 输出 +4.00",
                                                     resetChannel: {}, resetAll: {}), width: 244).height
        XCTAssertEqual(short, blank, accuracy: 0.5, "按下点的那一刻行高不许变")
        XCTAssertEqual(long, blank, accuracy: 0.5, "最长的一条也一样")
        XCTAssertEqual(blank, CurvePanelMetrics.footerHeight, accuracy: 0.5)
        print("footer height · 空 \(blank) · 短 \(short) · 长 \(long) pt")
    }

    /// **读数宽度**：四个代表点的真实文本，在读数行的真实字体下量出来，最宽的一条仍在 footer 的可用
    /// 宽度里 —— 默认 274 pt 与检查器最小 244 pt 各算一遍。
    ///
    /// 可用宽度 = 卡片宽 − 两个按钮（9 pt 字 + 6 pt 左右内边距，`fittingSize` 实测）− HStack 的三道
    /// 6 pt 间距 − `Spacer(minLength: 6)`。行高契约（`footerHeight`）不动，所以证明只能是**横向**的：
    /// 文本宽 ≤ 可用宽。
    ///
    /// **反证**：把 ` EV` 加回输入侧（069 的写法），最宽那条从 103.4 pt 涨到 118.8 pt —— 在 244 pt
    /// 的卡片上就超出可用宽度 15.4 pt，正是用户说的「放不下」。这条断言把那条「必红」钉成数字。
    func testTheReadoutFitsTheRowWithoutTheEvSuffix() {
        let samples: [(String, CurvePoint)] = [
            ("黑端", CurvePoint(0, 0)),
            ("18 % 灰", CurvePoint(118.0 / 255, 118.0 / 255)),
            ("白", CurvePoint(1, 1)),
            ("+2 EV", CurvePoint(1.5, 1.5)),
        ]
        let font = HistogramCardView.numberFont
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let resetChannel = Self.fittingSize(
            CurvePanelButton("复位本通道", identifier: "curve.button.复位本通道", action: {}),
            width: 400).width
        let resetAll = Self.fittingSize(
            CurvePanelButton("全部复位", identifier: "curve.button.全部复位", action: {}),
            width: 400).width
        // The row: Text · Spacer(minLength: 6) · button · button, `spacing: 6` ⇒ three 6 pt gaps.
        let chrome = 3 * 6 + 6 + resetChannel + resetAll

        var widest: (text: String, width: CGFloat, point: CurvePoint) = ("", 0, CurvePoint(0, 0))
        var report: [String] = []
        for cardWidth in [CGFloat(274), 244] {
            let available = cardWidth - chrome
            for (name, point) in samples {
                let text = CurvePointReadout.text(for: point)
                let w = width(text)
                XCTAssertLessThanOrEqual(w, available,
                                         "「\(text)」(\(name)) 宽 \(w) pt，超出可用宽 \(available) pt")
                if w > widest.width { widest = (text, w, point) }
                if cardWidth == 274 {
                    report.append(String(format: "%@「%@」%.2f pt", name, text, w))
                }
            }
            print(String(format: "row · 卡片 %.0f pt − 按钮 %.2f+%.2f − 间距 24 = 可用 %.2f pt"
                         + " · 最宽 %.2f（余 %.2f）",
                         cardWidth, resetChannel, resetAll, available, widest.width,
                         available - widest.width))
            // 反证：069 的 ` EV` 后缀在最小宽度上装不下 —— 这是用户报的那件事。
            if cardWidth == 244 {
                let withSuffix = "输入 +2.00 EV 输出 +2.00"
                XCTAssertGreaterThan(width(withSuffix), available,
                                     "` EV` 加回来必须超出读数行 —— 否则这条宽度断言什么也没证明")
                print(String(format: "反证 · 「%@」%.2f pt > 可用 %.2f pt（超出 %.2f pt）",
                             withSuffix, width(withSuffix), available,
                             width(withSuffix) - available))
            }
        }
        XCTAssertEqual(widest.text, "输入 +2.00 输出 +2.00", "最宽的一条是两边都在两档上的点")
        print("readings · " + report.joined(separator: " · "))
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

    /// **069 的五档码值一个都不变；用户 2026-10-27 要求 HDR 视图右半补回 `+1 +2 +3 +4`。**
    ///
    /// 两件事同时成立，所以分三段测：
    ///
    ///   ① 五档码——文本 `0 63 127 191 255`、位置 `2·forward(displayCode(c))`（即 `c/255`）、次序，
    ///      逐值不变；
    ///   ② 四档 stops——文本 `+1 … +4`，位置 `2·u(stops: e)`（= 1.25 / 1.5 / 1.75 / 2.0 坐标，屏幕上
    ///      落在 box 的 62.5 / 75 / 87.5 / 100 %），**只在 HDR 视图里出现**，SDR 视图一个都不加；
    ///   ③ 屏幕上的几何：SDR 5 个、HDR 9 个，`255` 在 SDR 的右端、HDR 的正中；相邻标签的**方框**
    ///      互不相交（用真实字体量宽，不是估计）。
    func testTheTicksAreFiveCodesInSdrAndNineMarksInHdr() throws {
        let axis = HDRCurveAxis.standard

        // ── ① 五档显示码：069 的，逐值不变 ────────────────────────────────────────────────
        let codes = CurveAxisTicks.codes(axis)
        XCTAssertEqual(codes.map(\.label), ["0", "63", "127", "191", "255"])
        for (tick, code) in zip(codes, [0.0, 63, 127, 191, 255]) {
            XCTAssertEqual(tick.x, 2 * axis.forward(CurveAxisTicks.displayCode(code)),
                           "码 \(code) 的位置来自 axis，差为 0")
            XCTAssertEqual(tick.x, code / 255, accuracy: 1e-15,
                           "x = c/255（encode∘decode 是恒等，差一个 ulp 以内）")
        }
        XCTAssertEqual(codes.first?.x, 0)
        XCTAssertEqual(codes.last?.x, 1, "255 码落在 x = 1（白点）")

        // ── ② 四档 stops：文本与位置都来自轴 ──────────────────────────────────────────────
        let stops = CurveAxisTicks.stops(axis)
        XCTAssertEqual(stops.map(\.label), ["+1", "+2", "+3", "+4"],
                       "用户 2026-10-27：HDR 视图右半要有 +1…+4")
        for (tick, ev) in zip(stops, [1.0, 2, 3, 4]) {
            XCTAssertEqual(tick.x, 2 * axis.u(stops: ev),
                           "「+\(Int(ev))」的位置必须是 axis 的 u(stops:)，不是写死的数")
        }
        for (tick, want) in zip(stops, [1.25, 1.5, 1.75, 2.0]) {
            XCTAssertEqual(tick.x, want, accuracy: 1e-12,
                           "「\(tick.label)」在卡片坐标 \(want)（= 白点 + 每档 0.25）")
        }
        XCTAssertEqual(stops.last!.x, CurvePoint.maximum, accuracy: 1e-12,
                       "+4 EV 就是轴的右端 x = 2（axis 的 u(16) = 1，不是夹出来的）")
        XCTAssertEqual(axis.stops(at: stops.last!.x / 2), 4, accuracy: 1e-12,
                       "反查：右端就是 +4 EV")

        // ── ③ 哪种视图画哪一组：SDR = 五个码，HDR = 五个码 + 四个 stops ─────────────────
        let sdrTicks = CurveAxisTicks.ticks(for: .sdr, axis: axis)
        let hdrTicks = CurveAxisTicks.ticks(for: .hdr, axis: axis)
        XCTAssertEqual(sdrTicks.map(\.label), codes.map(\.label), "SDR 视图不加 stops（只显码值区）")
        XCTAssertEqual(sdrTicks.count, 5)
        XCTAssertEqual(hdrTicks.map(\.label),
                       ["0", "63", "127", "191", "255", "+1", "+2", "+3", "+4"])
        XCTAssertEqual(hdrTicks.count, 9, "HDR 视图 9 个刻度（5 码 + 4 stops）")
        XCTAssertEqual(Array(hdrTicks.prefix(5)), codes, "前五个就是 069 的那五个，逐值相等")

        // ── ④ 屏幕位置：SDR 5 个点、HDR 9 个点，位置由 `x(u:)` 给出 ─────────────────────
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274,
                                                         height: CurvePanelMetrics.plotHeight))
        let sdr = CurvePlotGeometry(plot: plot, view: .sdr)
        let hdr = CurvePlotGeometry(plot: plot, view: .hdr)
        let box = hdr.valueBox

        let sdrPositions = sdr.tickPositions(sdrTicks)
        XCTAssertEqual(sdrPositions.count, 5)
        XCTAssertEqual(sdrPositions[0], sdr.valueBox.minX, accuracy: 1e-12)
        XCTAssertEqual(sdrPositions[4], sdr.valueBox.maxX, accuracy: 1e-12,
                       "SDR 视图里白点在右端（071：0…1 铺满）")

        let sdrLayout = CurveAxisTicks.layout(for: .sdr, in: sdr)
        let hdrLayout = CurveAxisTicks.layout(for: .hdr, in: hdr)
        XCTAssertEqual(sdrLayout.count, 5, "SDR 视图只有五个码")
        XCTAssertEqual(hdrLayout.count, 9, "274 pt 的卡片放得下 9 个刻度，一个都不用丢")
        for placement in hdrLayout {
            XCTAssertEqual(placement.x, hdr.x(u: placement.tick.x), accuracy: 1e-12,
                           "「\(placement.tick.label)」的线必须落在轴给的位置上")
        }
        if hdrLayout.count == 9 {
            XCTAssertEqual(hdrLayout[4].x, box.midX, accuracy: 1e-12, "255 码在 HDR 视图的正中")
            XCTAssertEqual(hdrLayout[8].x, box.maxX, accuracy: 1e-12, "+4 在右端")
        }
        for (placement, fraction) in zip(hdrLayout.suffix(4), [0.625, 0.75, 0.875, 1.0]) {
            XCTAssertEqual(placement.x, box.minX + CGFloat(fraction) * box.width, accuracy: 1e-12,
                           "「\(placement.tick.label)」落在 box 宽 \(fraction * 100) % 处")
        }
        XCTAssertTrue(hdrLayout.suffix(4).allSatisfy { $0.x > box.midX },
                      "四个 stops 全在右半（x > 正中）")

        // ── ⑤ 不重叠：真实字体的标签宽度 + 相邻间距 ──────────────────────────────────────
        var gaps: [CGFloat] = []
        var widths: [String] = []
        for (i, placement) in hdrLayout.enumerated() {
            widths.append(String(format: "%@=%.2f", placement.tick.label, placement.labelWidth))
            guard i > 0 else { continue }
            let previous = hdrLayout[i - 1]
            let previousRight = previous.anchor.leftEdge(of: previous.x,
                                                         width: previous.labelWidth)
                + previous.labelWidth
            let left = placement.anchor.leftEdge(of: placement.x, width: placement.labelWidth)
            XCTAssertGreaterThanOrEqual(left, previousRight,
                                        "「\(previous.tick.label)」与「\(placement.tick.label)」的标签重叠")
            gaps.append(placement.x - previous.x)
        }
        let tightest = gaps.min() ?? 0
        XCTAssertGreaterThanOrEqual(tightest, 8,
                                    "相邻刻度间距 \(tightest) pt 太挤（标签最宽 15.33 pt）")
        // 「255」与「+1」之间是两套刻度的接缝：单独再量一次。
        let seam: CGFloat? = hdrLayout.count == 9
            ? hdrLayout[5].anchor.leftEdge(of: hdrLayout[5].x, width: hdrLayout[5].labelWidth)
                - (hdrLayout[4].x + hdrLayout[4].labelWidth / 2)
            : nil
        XCTAssertNotNil(seam)
        XCTAssertGreaterThan(seam ?? 0, 4, "「255」与「+1」之间必须留出空隙，实测 \(seam ?? 0) pt")

        // ── ⑥ 源码：位置来自轴，SDR 不分支加 stops，绘制用 layout ─────────────────────────
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(source.contains("2 * axis.u(stops: Double(stop))"),
                      "stops 的位置必须是 axis 的 u(stops:)，不许写 1.25 / 1.5 / 1.75 / 2")
        XCTAssertTrue(source.contains("case .sdr: return codes(axis)"),
                      "SDR 视图只给五个码")
        XCTAssertTrue(source.contains("case .hdr: return codes(axis) + stops(axis)"),
                      "HDR 视图 = 五个码 + 四个 stops")
        XCTAssertTrue(source.contains("CurveAxisTicks.layout(for: geometry.view, in: geometry)"),
                      "绘制必须走按视图取刻度的 layout")

        print("ticks · SDR 5 → " + sdrPositions.map { String(format: "%.2f", $0) }
                .joined(separator: ", "))
        print("ticks · HDR 9 → " + hdrLayout.map { String(format: "%@@%.2f", $0.tick.label, $0.x) }
                .joined(separator: " · "))
        print("ticks · 间距 " + gaps.map { String(format: "%.2f", $0) }.joined(separator: ", ")
              + String(format: " pt · 最窄 %.2f · 255↔+1 缝 %.2f pt", tightest, seam ?? 0))
        print("ticks · 标签宽 " + widths.joined(separator: " · ")
              + String(format: " pt · 最宽 %.2f", widths.count > 0 ? hdrLayout.map(\.labelWidth).max()! : 0))
    }

    /// **空间不足时只画放得下的** —— 把卡片压窄，`layout` 丢掉撞不下的标签，**任何两个保留下来的
    /// 标签都不重叠**，而且丢的只可能是右边的 stops（069 的五档码值在任何宽度都留得住）。
    ///
    /// 这条测试的用处是把「不重叠」从「274 pt 下刚好放得下」变成一条规则：卡片变窄时显示的是**少几个
    /// 数字**，而不是两个数字叠在一起。
    func testANarrowBoxDropsTicksInsteadOfOverlappingThem() {
        func layout(_ cardWidth: CGFloat) -> [CurveAxisTicks.Placement] {
            let plot = CurvePanelMetrics.plotRect(in: CGSize(width: cardWidth,
                                                             height: CurvePanelMetrics.plotHeight))
            return CurveAxisTicks.layout(for: .hdr, in: CurvePlotGeometry(plot: plot, view: .hdr))
        }
        XCTAssertEqual(layout(274).count, 9, "默认宽度：九个都在")
        XCTAssertEqual(layout(244).count, 9, "检查器最小宽度：九个仍在")
        for width in [CGFloat(200), 170, 140] {
            let kept = layout(width)
            XCTAssertGreaterThanOrEqual(kept.count, 5, "宽度 \(width)：五档码值必须留得住")
            XCTAssertLessThanOrEqual(kept.count, 9)
            XCTAssertEqual(kept.prefix(5).map(\.tick.label),
                           CurveAxisTicks.codes().map(\.label),
                           "宽度 \(width)：留下的头五个仍是 069 的五档码值（丢的只会是 stops）")
            for (a, b) in zip(kept, kept.dropFirst()) {
                let aRight = a.anchor.leftEdge(of: a.x, width: a.labelWidth) + a.labelWidth
                let bLeft = b.anchor.leftEdge(of: b.x, width: b.labelWidth)
                XCTAssertGreaterThanOrEqual(bLeft, aRight - 1e-9,
                                            "宽度 \(width)：「\(a.tick.label)」与「\(b.tick.label)」重叠")
            }
            print("narrow · 卡片 \(Int(width)) pt → " + kept.map(\.tick.label).joined(separator: " "))
        }
    }

    /// **反证**：把 stops 去掉（HDR 视图只画五档码值，即 069 的口径）→ 上面那条必红。
    ///
    /// 这条测试是那句「必红」的可执行形式：它把「少了 stops 的那份刻度」真的造出来，并断言它与
    /// HDR 视图实画的那份**不等** —— 九个刻度、右半四个标签、`+4` 落在右端，缺一样都不等。
    func testDroppingTheStopsTurnsTheTickSuiteRed() {
        let axis = HDRCurveAxis.standard
        let hdr = CurveAxisTicks.ticks(for: .hdr, axis: axis)
        let withoutStops = CurveAxisTicks.codes(axis)   // 069 的口径：只有五档码值

        XCTAssertNotEqual(hdr.map(\.label), withoutStops.map(\.label),
                          "少了 stops 的刻度与 HDR 实画的刻度必须不同 —— 否则「9 个」的断言白写")
        XCTAssertEqual(hdr.count, 9)
        XCTAssertEqual(withoutStops.count, 5)
        XCTAssertTrue(withoutStops.allSatisfy { $0.x <= CurvePoint.sdrBoundary },
                      "只画码值时右半区（x > 1）一个刻度都没有 —— 用户报的就是这张图")
        XCTAssertTrue(hdr.filter { $0.x > CurvePoint.sdrBoundary }.count == 4,
                      "HDR 视图右半必须是四个 stops")

        // 屏幕上：少了 stops 的那份在 box 右半寸草不生。
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        let geometry = CurvePlotGeometry(plot: plot, view: .hdr)
        let without = CurveAxisTicks.layout(for: .sdr, in: geometry)   // SDR 口径画进 HDR 的 box
        XCTAssertTrue(without.allSatisfy { $0.x <= geometry.valueBox.midX + 1e-9 },
                      "反证：只画五档码值时，HDR 视图正中往右没有任何标签")
        XCTAssertEqual(CurveAxisTicks.layout(for: .hdr, in: geometry).count, 9)
        print("anti-proof · 069 口径 \(without.map(\.tick.label)) · HDR 口径 \(hdr.map(\.label))")
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
