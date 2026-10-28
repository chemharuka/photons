import XCTest
import AppKit
import SwiftUI
import PhotonsCore
@testable import PhotonsUI

/// 派单 051 — 曲线面板 v1：把已有的 S1.7 HDR 曲线**显示出来并让它可编辑**。
///
/// The engine (`CurveLUT.buildOne` + `HDRCurveAxis`) shipped long before this card and nothing in the
/// library wrote `EditModel.curve`. So the tests below are about the *panel*, and each pins one claim
/// the card makes:
///
///   1. **刻度不是写死的** — the five tick positions are `HDRCurveAxis`'s own answers to 1e-9, and this
///      file greps `CurvePanel.swift` for `0.5955` / `0.7500` / `0.875` to prove no copy came back.
///   2. **单调** — a point dragged past its neighbour is clamped 1e-3 inside it, with a **negative
///      control** that runs the unclamped move and shows the list would be out of order. Without that
///      half, "the clamp works" would also be green if the clamp did nothing at all.
///   3. **通道独立** — editing `red` leaves `white`'s table byte-identical (`buildOne` compared as
///      arrays, not "looks the same").
///   4. **一次拖动 = 一条历史** — ten intermediate `drag` calls commit nothing; `endDrag` commits one.
///      The per-tick route is run too, so "1" and "10" are distinguishable.
///   5. **端点不可删** —双击 (0,0) 和 (1,1) 点数不变、无历史、不报错。
///   6. **复位回到逐字节恒等** — `CurveLUT.isIdentity`, and `tablesAreIdentity` on the built buffer:
///      that is the kernel's copy branch, i.e. the frame is byte-identical again.
///   7. **画的是引擎的表** — `preview == CurveLUT.buildOne(points)`, element by element.
///   8. **尺寸** — measured `fittingSize` at the inspector's 274 pt content width, and the panel's
///      height does not move when the document does (that is what would push the cards below it).
///   9. **端点可以在 x 上移动（061）** — pushing the first point right to `u = 0.2` makes the table one
///      constant below 0.2 (a **black clip**), pulling the last left to 0.8 makes it one constant
///      above (a **white clip**), the table stays monotone, the doc keeps strictly increasing x, and
///      one drag is still one history entry. The **negative control** rebuilds the table from the
///      *pinned* endpoint 051 wrote and shows those same 100 samples would differ — without it,
///      "the clip works" would also be green if the table were flat for some other reason.
///
/// The interactions are driven through `CurveEditorModel` — the same struct the view's gesture calls —
/// because `swift test` has no window session to inject mouse events into (047/040's known limit).
@MainActor
final class CurvePanelTests: XCTestCase {

    // MARK: - 1. the axis ticks come from `HDRCurveAxis`

    /// The five positions are `u(0)`, `u(code 63)`, `u(code 127)`, `u(code 191)`, `u(code 255)` —
    /// **exactly** as the axis computes them (062 pins the difference at zero, not "within a
    /// 069 — 五档 SDR 码值 `0 / 63 / 127 / 191 / 255`，位置 = `2·forward(displayCode(c))`（即 `c/255`），
    /// 每个都是一次相等而不是容差。
    ///
    /// 2026-10-27：stops（`+1…+4`）在 **HDR 视图**里回来了，但**不在这一组里** —— 这五档是码值刻度，
    /// 两种视图都画，位置与文本一个都没动。stops 是另一组（`CurveAxisTicks.stops`），只进 HDR 视图，
    /// 由 `CurveReadoutTests.testTheTicksAreFiveCodesInSdrAndNineMarksInHdr` 钉住。
    func testTheTicksAreTheAxisOwnPositionsAndNotNumbers() {
        let axis = HDRCurveAxis.standard
        let ticks = CurveAxisTicks.codes(axis)

        XCTAssertEqual(ticks.map(\.label), ["0", "63", "127", "191", "255"])
        let expected = [0.0, 63, 127, 191, 255].map { 2 * axis.forward(CurveAxisTicks.displayCode($0)) }
        XCTAssertEqual(ticks.count, expected.count)
        for (tick, want) in zip(ticks, expected) {
            XCTAssertEqual(tick.x, want, "刻度 \(tick.label) 的位置必须是 axis 算出的那一个数")
            XCTAssertEqual(tick.x, Double(Int(tick.label)!) / 255, accuracy: 1e-15,
                           "码 \(tick.label) 落在自己的码值坐标上")
        }
        XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { $0.x < $1.x })
        XCTAssertEqual(ticks.last?.x ?? -1, 1, accuracy: 1e-12, "255 码 = 白点 x = 1")
        XCTAssertEqual(axis.stops(at: ticks.last!.x / 2), 0, accuracy: 1e-12, "白点就是 +0 EV")

        // In points: in the SDR view (the default, 071) the tick x is its own card coordinate of the
        // way across the **value box** — `0…1` fills it, so `255` sits on the right edge.
        let plot = CGRect(x: 0, y: 0, width: 274, height: 189)
        let geometry = CurvePlotGeometry(plot: plot)
        let box = geometry.valueBox
        let positions = geometry.tickPositions(ticks)
        for (position, want) in zip(positions, expected) {
            XCTAssertEqual(position, box.minX + CGFloat(want) * box.width, accuracy: 1e-9)
        }
        XCTAssertEqual(positions[0], box.minX, accuracy: 1e-9)
        XCTAssertEqual(positions[positions.count - 1], box.maxX, accuracy: 1e-9,
                       "SDR 视图里白点在右端（071：0…1 铺满；HDR 视图是整条 0…2，白点在正中）")

        print("ticks · " + zip(ticks, positions)
            .map { "\($0.label)@x=\(String(format: "%.6f", $0.x))→\(String(format: "%.3f", $1))" }
            .joined(separator: " · "))
    }

    /// 反证 for claim 1: the panel's source contains **no** axis position literal.
    ///
    /// The ticks are derived, so none of 044's positions and none of 062's can appear — if someone
    /// pastes a number back in, this turns red before the picture does.
    func testThePanelSourceWritesNoAxisPositionLiterals() throws {
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        for literal in ["0.5955", "0.7500", "0.750", "0.875", "0.2307", "0.5000", "0.0016"] {
            XCTAssertFalse(source.contains(literal),
                           "CurvePanel.swift 里出现了 \(literal)：刻度必须是算出来的")
        }
        // …because it does the derivation, through the two functions that own it.
        XCTAssertTrue(source.contains("axis.forward(displayCode(Double(code)))"),
                      "SDR 刻度必须是「显示码 → 线性 → axis」算出来的")
        XCTAssertTrue(source.contains("[0, 63, 127, 191, 255]"),
                      "五档码值就是这五个数（标签），位置仍由 axis 推出")
        // 2026-10-27: the stops are back **in the HDR view**, and their positions are the axis'
        // `u(stops:)` — still derived, still no literal `1.25 / 1.5 / 1.75 / 2`.
        XCTAssertTrue(source.contains("axis.u(stops: Double(stop))"),
                      "stops 刻度必须由 axis.u(stops:) 推出（069 的取消已按用户 2026-10-27 收回）")
        XCTAssertTrue(source.contains("CurveLUT.buildOne(points)"),
                      "预览必须是引擎那张表，不是第二种插值")
        // 069: the bottom caption line is gone, and the read-out that replaced its space is derived from
        // the axis the same way — `axis.whiteU` is where the SDR half ends and `axis.stops(at:)` is what
        // a coordinate means in EV. No number in this file is allowed to be its own copy.
        XCTAssertFalse(source.contains("横轴与直方图一致"), "底部说明必须删掉")
        // The read-out is arithmetic on the coordinate, not a second axis: the split is
        // `CurvePoint.sdrBoundary` and the EV side is `(x − 1)·4`, written once, in `CurvePointReadout`.
        XCTAssertTrue(source.contains("CurvePoint.sdrBoundary") && source.contains("* 4"))
        XCTAssertFalse(source.contains("label: \"SDR\"") || source.contains("label: \"HDR\""),
                       "轴上不许出现 SDR/HDR 字样（069）")
    }

    // MARK: - 1b. 071 — one transform for everything

    /// **同一变换**：曲线、网格、控制点、命中判定、读数、`isVisible` 都走 `CurvePlotGeometry`，
    /// 而比例只在一处算 —— 源码级断言 + 一条行为级的等式。
    ///
    /// 这条测试的存在理由不是洁癖：069/070 的 bug 全是「曲线和点各算各的」——曲线用表里的 `0…1`、
    /// 点用卡片的 `0…2`，两张图各自都「像曲线」。把比例钉成一处，就没有第二个地方可以漂移。
    func testEveryDrawingPathUsesTheOneTransform() throws {
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)

        // ① span 的减法只有一处（`spanOriginAndWidth`），除以 span 宽度的比例也只有一处（`fraction`）。
        // 注释不参与计数：`///` 行里写着同一条规则，代码才是证据。
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        func occurrences(_ needle: String) -> Int {
            source.components(separatedBy: needle).count - 1
        }
        func codeOccurrences(_ needle: String) -> Int {
            code.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(codeOccurrences("span.upperBound - span.lowerBound"), 1,
                       "span 的减法必须只出现一次（spanOriginAndWidth）")
        XCTAssertEqual(codeOccurrences("- origin) / width"), 1,
                       "归一化比例必须只在 fraction(_:) 里出现一次")
        XCTAssertEqual(occurrences("func fraction("), 1)
        XCTAssertEqual(occurrences("func coordinate("), 1)

        // ② 每一个图元都必须经过几何：曲线取样、控制点、网格、刻度、命中、可见性。
        for call in ["geometry.x(u: cardX)", "geometry.yRaw(v: 2 * Double(table[i]))",
                     "geometry.point(p)", "geometry.isVisible(p)", "geometry.hitIndex(",
                     "geometry.gridLines()", "geometry.x(u: tick.x)",
                     "geometry.u(atX:", "geometry.v(atY:"] {
            XCTAssertTrue(source.contains(call), "绘图/命中路径没走几何：\(call)")
        }
        // ③ 绘制代码里不许自己乘 / 除盒子的宽高 —— 那就是第二份比例。
        let drawBody = (source.components(separatedBy: "private func draw(into").last ?? "")
            .components(separatedBy: "// MARK: one gesture").first ?? ""
        for forbidden in ["valueBox.width", "valueBox.height", "box.width *", "box.height *"] {
            XCTAssertFalse(drawBody.contains(forbidden), "draw 里自己算比例：\(forbidden)")
        }
        XCTAssertTrue(drawBody.contains("geometry.valueBox"), "draw 仍从几何取盒子")

        // ④ 行为等式：同一个点，`point(_:)` == (`x(u:)`, `y(v:)`)；每一档刻度都落在网格的 x 上。
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        for view in CurveViewMode.allCases {
            let g = CurvePlotGeometry(plot: plot, view: view)
            for p in [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1, 1), CurvePoint(2, 2),
                      CurvePoint(1.5, 1.2), CurvePoint(0.25, 0.9)] {
                XCTAssertEqual(g.point(p), CGPoint(x: g.x(u: p.x), y: g.y(v: p.y)),
                               "\(view): point(_:) 与 x/y 不是同一个变换")
            }
            // 网格线、边框、对角线与取值盒同源：最外两条竖线就是 box 的两条边。
            let grid = g.gridLines()
            XCTAssertEqual(grid.vertical.first!, g.valueBox.minX)
            XCTAssertEqual(grid.vertical.last!, g.valueBox.maxX)
            XCTAssertEqual(grid.horizontal.first!, g.valueBox.minY)
            XCTAssertEqual(grid.horizontal.last!, g.valueBox.maxY)
            // 命中判定用的是画点那个位置：点在屏幕上，就点得到。
            for p in [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1.5, 1.5)] where g.isVisible(p) {
                XCTAssertEqual(g.hitIndex([p], at: g.point(p)), 0,
                               "\(view): 画出来的点必须点得到：\(p)")
            }
        }
        print("transform · span 减法 1 处 · 归一化 1 处 · 9 条绘图路径全部走几何")
    }

    // MARK: - 2. insert

    /// 单击空白 = 在该 x 插一个点，**y 取当前曲线在该 x 的值**（不是 0，也不是 x）。
    ///
    /// Two curves, because "y = the curve's value" and "y = the identity's value" differ on the second:
    /// a 0 → 1 ramp is 0.5 at the midpoint, and a panel that wrote `x` would write 1.
    ///
    /// 069: the coordinates are the card's `0…2` — no grid, no quantisation: `x = 0.6` stays `0.6`.
    func testClickingEmptySpaceInsertsAPointAtTheCurvesOwnValue() {
        let identity = CatalogSession()
        let identityModel = CurveEditorModel(session: identity, channel: .white)
        XCTAssertNotNil(identityModel.insert(atX: 0.6))
        let onIdentity = identity.edit.curve.white
        XCTAssertEqual(onIdentity.count, 3)
        XCTAssertEqual(onIdentity[1].x, 0.6, accuracy: 1e-12, "插入的坐标就是点下的坐标")
        XCTAssertEqual(onIdentity[1].y, 0.6, accuracy: 0.01, "恒等曲线上 y == x")
        XCTAssertTrue(CurveEditor.isOrdered(onIdentity))
        XCTAssertEqual(identity.history.count, 1, "插入 = 一次动作 = 一条历史")

        // A ramp whose midpoint is 1.0: the new point must land on the *curve*, not at 0 and not at x.
        let ramp = CatalogSession()
        ramp.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(2, 1)] }
        ramp.commitEdit(label: "ramp")
        let rampModel = CurveEditorModel(session: ramp, channel: .white)
        XCTAssertNotNil(rampModel.insert(atX: 1.0))
        let inserted = ramp.edit.curve.white
        XCTAssertEqual(inserted.count, 3)
        XCTAssertEqual(inserted[1].y, 0.5, accuracy: 0.01,
                       "y 取曲线在该 x 的值（0.5），不是 0，也不是 x（1.0）")
        XCTAssertNotEqual(inserted[1].y, 0, accuracy: 1e-6, "反证：y 不能是 0")
        XCTAssertNotEqual(inserted[1].y, 1.0, accuracy: 0.01, "反证：y 不能是 x")

        print("insert · identity 插入后 \(onIdentity.map { "($0.x,$0.y)" != "" ? "(\($0.x),\($0.y))" : "" }) · "
              + "ramp 中点 y = \(String(format: "%.4f", inserted[1].y))")
    }

    // MARK: - 3. the clamp

    /// 把中间点拖到最左 → x 被夹在左邻点右边 `minimumGap`；点数不变，`points` 仍严格递增。
    ///
    /// **反证**：同一目标点不夹取地写进去，列表就不递增 —— 所以"夹取生效"不是空话。
    func testDraggingAPointPastItsNeighbourIsClampedToTheGap() {
        let gap = CurveEditor.minimumGap
        let start = [CurvePoint(0, 0), CurvePoint(0.6, 0.4), CurvePoint(1.6, 1.8), CurvePoint(2, 2)]

        let left = CurveEditor.movedPoint(CurvePoint(-5, 0.8), index: 1, in: start,
                                          from: start[1], lock: .free)
        XCTAssertEqual(left.x, start[0].x + gap, accuracy: 1e-12, "夹在左邻点右边一个 gap")
        XCTAssertEqual(left.y, 0.8, accuracy: 1e-12, "y 不受夹取影响")

        let right = CurveEditor.movedPoint(CurvePoint(5, 0.8), index: 1, in: start,
                                           from: start[1], lock: .free)
        XCTAssertEqual(right.x, start[2].x - gap, accuracy: 1e-12)

        let middle = CurveEditor.movedPoint(CurvePoint(1.2, 0.8), index: 1, in: start,
                                            from: start[1], lock: .free)
        XCTAssertEqual(middle.x, 1.2, accuracy: 1e-12, "区间内原样通过（不是永远贴边）")

        let againstInterior = CurveEditor.movedPoint(CurvePoint(-5, 1.8), index: 2, in: start,
                                                     from: start[2], lock: .free)
        XCTAssertEqual(againstInterior.x, start[1].x + gap, accuracy: 1e-12,
                       "夹取对着**当前**的左邻点算")

        // 061: 端点可以在 x 上移动 —— 右移左端点就是调黑点，左移右端点就是调白点
        let first = CurveEditor.movedPoint(CurvePoint(0.4, 1.8), index: 0, in: start,
                                          from: start[0], lock: .free)
        XCTAssertEqual(first.x, 0.4, accuracy: 1e-12, "首点必须能在 x 上移动（051 曾钉在 0）")
        let last = CurveEditor.movedPoint(CurvePoint(1.8, 0.2), index: 3, in: start,
                                          from: start[3], lock: .free)
        XCTAssertEqual(last.x, 1.8, accuracy: 1e-12, "末点必须能在 x 上移动（051 曾钉在 1）")

        XCTAssertEqual(CurveEditor.clampX(5, index: 0, in: start), start[1].x - gap, accuracy: 1e-12)
        XCTAssertEqual(CurveEditor.clampX(-5, index: 0, in: start), 0, accuracy: 1e-12)
        XCTAssertEqual(CurveEditor.clampX(-5, index: 3, in: start), start[2].x + gap, accuracy: 1e-12)
        XCTAssertEqual(CurveEditor.clampX(5, index: 3, in: start), 2, accuracy: 1e-12)
        for target in [-5.0, 0.0, 0.4, 0.59, 5.0] {
            let p = CurveEditor.movedPoint(CurvePoint(target, 1), index: 0, in: start,
                                          from: start[0], lock: .free)
            XCTAssertTrue(CurveEditor.isOrdered([p] + start.dropFirst()), "首点拖到 \(target) 后仍须递增")
        }
        XCTAssertNotEqual(first.x, 0, "反证：061 之前的 return 0 会得到 0")
        XCTAssertNotEqual(last.x, 2, "反证：061 之前的 return 2 会得到 2")

        // ⇧ 的两种锁
        let onlyX = CurveEditor.movedPoint(CurvePoint(1, 1.8), index: 1, in: start,
                                           from: start[1], lock: .x)
        XCTAssertEqual(onlyX, CurvePoint(1, 0.4), "⇧ 横向：只改 x，y 留在按下时的值")
        let onlyY = CurveEditor.movedPoint(CurvePoint(1, 1.8), index: 1, in: start,
                                           from: start[1], lock: .y)
        XCTAssertEqual(onlyY, CurvePoint(0.6, 1.8), "⇧ 纵向：只改 y")

        // 通过面板实际写两次：索引 1 顶到 gap，索引 2 于是贴着**新的**左邻停在 2·gap
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = start }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        model.drag(index: 1, to: CurvePoint(-5, 0.8), from: start[1], lock: .free)
        var written = session.edit.curve.white
        XCTAssertTrue(CurveEditor.isOrdered(written), "写回后必须严格递增：\(written)")
        XCTAssertEqual(written[1].x, gap, accuracy: 1e-12, "左邻是端点 0 → gap")
        XCTAssertEqual(written[0].x, 0, accuracy: 1e-12, "端点不动")

        model.drag(index: 2, to: CurvePoint(-5, 1.8), from: start[2], lock: .free)
        written = session.edit.curve.white
        XCTAssertTrue(CurveEditor.isOrdered(written), "写回后必须严格递增：\(written)")
        XCTAssertEqual(written[2].x, gap + gap, accuracy: 1e-12, "贴着**当前**左邻 gap → 2·gap")
        XCTAssertEqual(written[3].x, 2, accuracy: 1e-12)

        var naive = start
        naive[1] = CurvePoint(-5, 0.8)
        XCTAssertFalse(CurveEditor.isOrdered(naive), "不夹取就是乱序 —— 夹取这一条断言因此不是空的")
        print("clamp · \(written.map { String(format: "%.4f", $0.x) })")
    }

    // MARK: - 4. delete, and the endpoints that refuse

    /// 双击内部的点 → 删掉，一条历史；双击两个端点 → 点数不变、没有历史、不报错。
    func testDoubleClickDeletesAnInteriorPointAndTheEndpointsRefuseSilently() {
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.7), CurvePoint(u: 1, v: 1)] }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let before = session.history.count

        XCTAssertTrue(model.delete(index: 1), "内部点可以删")
        XCTAssertEqual(session.edit.curve.white, CurvePoint.linear)
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "曲线")

        // 端点：拒绝，且**什么都不写**
        let endpoints = session.history.count
        XCTAssertFalse(model.delete(index: 0), "首点不可删")
        XCTAssertFalse(model.delete(index: 1), "末点不可删")     // (1,1) is now the last point
        XCTAssertEqual(session.edit.curve.white, CurvePoint.linear, "点数不变")
        XCTAssertEqual(session.edit.curve.white.count, 2)
        XCTAssertEqual(session.history.count, endpoints, "拒绝不等于一条空快照")

        // 越界索引也只是 false，不崩
        XCTAssertFalse(model.delete(index: 99))

        print("delete · 内部点 → 2 点；端点双击 → 拒绝，点数 \(session.edit.curve.white.count)，"
              + "历史 \(session.history.count - endpoints)")
    }

    // MARK: - 5. the channels are independent

    /// 只改 R → `white` 的表逐字节相同，`red` 变了；面板的 tab 写的确实是那张表。
    func testEditingRedLeavesTheWhiteTableByteIdentical() {
        let session = CatalogSession()
        let whiteBefore = CurveLUT.buildOne(session.edit.curve.white)
        let redBefore = CurveLUT.buildOne(session.edit.curve.red)

        // 069: inserting on the identity curve lands *on* the identity (the new point takes the curve's
        // own value), so the table would not move — the shape comes from dragging one point down.
        let red = CurveEditorModel(session: session, channel: .red)
        XCTAssertNotNil(red.insert(atX: 0.8), "R 通道插入一个点")
        XCTAssertNotNil(red.insert(atX: 1.4))
        let origin = red.beginDrag(at: 1)!
        XCTAssertTrue(red.drag(index: 1, to: CurvePoint(0.8, 0.4), from: origin, lock: .free))
        XCTAssertTrue(red.endDrag())

        XCTAssertEqual(CurveLUT.buildOne(session.edit.curve.white), whiteBefore,
                       "改 R 不许动 W 的表（逐字节）")
        XCTAssertNotEqual(CurveLUT.buildOne(session.edit.curve.red), redBefore)
        XCTAssertEqual(session.edit.curve.red.count, 4)
        XCTAssertEqual(session.edit.curve.white, CurvePoint.linear, "W 的点列表原样")

        // 四张表各自独立：绿和蓝也没被动
        XCTAssertEqual(session.edit.curve.green, CurvePoint.linear)
        XCTAssertEqual(session.edit.curve.blue, CurvePoint.linear)

        // W 是**增益**表，不是第四张逐通道表 —— tab 的 tooltip 说的就是这件事。
        XCTAssertTrue(CurveChannel.white.help.contains("亮度增益"))
        print("channels · white 表 \(whiteBefore.count) 点逐字节未变 · red 点数 "
              + "\(session.edit.curve.red.count)")
    }

    // MARK: - 6. one drag, one history entry

    /// 一次拖动 = 一条历史：10 个中间态都不进历史，抬起时 +1。
    ///
    /// **反证**：每个 tick 各提交一次就是 10 条 —— 两条路径都跑，1 和 10 必须可分辨。
    func testOneDragIsOneHistoryEntryWhileThePerTickRouteWouldBeTen() {
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5), CurvePoint(u: 1, v: 1)] }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 1)
        XCTAssertEqual(origin, CurvePoint(u: 0.5, v: 0.5))
        for step in 1...10 {
            model.drag(index: 1,
                       to: CurvePoint(u: 0.5 + 0.02 * Double(step), v: 0.5 + 0.03 * Double(step)),
                       from: origin!, lock: .free)
            XCTAssertEqual(session.history.count, base, "拖动过程不写历史（step \(step)）")
        }
        XCTAssertEqual(session.edit.curve.white[1].x, 2 * (0.5 + 0.02 * 10), accuracy: 1e-12,
                       "中间态已经写进文档（无量化，坐标就是 1.4）")
        XCTAssertTrue(model.endDrag(), "抬起 = 一条快照")
        XCTAssertEqual(session.history.count, base + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "曲线")

        // 反证：每个 tick 都 commit 的那条路。
        //
        // 077（2026-10-27）之后这条反证的**结论变了**：粒度不再靠 UI 小心，`commit` 自己把同一 class
        // 的连续提交合并成一行，所以每 tick 提交也只有 **1** 行 —— 这比"UI 必须只提交一次"更稳。
        // 要让一行一个 tick 成立，必须每步换一个类：下面 `noisy2` 每步同时改白、红两条曲线（两类 ⇒ 永不合并）。
        let noisy = CatalogSession()
        noisy.applyEdit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5), CurvePoint(u: 1, v: 1)] }
        noisy.commitEdit(label: "起点")
        let noisyBase = noisy.history.count
        for step in 1...10 {
            noisy.applyEdit { $0.curve.white[1] = CurvePoint(u: 0.5 + 0.02 * Double(step), v: 0.5) }
            noisy.commitEdit(label: "曲线")
        }
        XCTAssertEqual(noisy.history.count - noisyBase, 1,
                       "同参数每 tick 提交也合并成一行（077 的合并发生在 commit 里）")

        let noisy2 = CatalogSession()
        noisy2.applyEdit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5), CurvePoint(u: 1, v: 1)] }
        noisy2.commitEdit(label: "起点")
        let noisy2Base = noisy2.history.count
        for step in 1...10 {
            noisy2.applyEdit {
                $0.curve.white[1] = CurvePoint(u: 0.5 + 0.02 * Double(step), v: 0.5)
                $0.curve.red[1] = CurvePoint(u: 0.5, v: 0.5 + 0.02 * Double(step))
            }
            noisy2.commitEdit(label: "曲线")
        }
        XCTAssertEqual(noisy2.history.count - noisy2Base, 10,
                       "每步两个类 ⇒ 不合并 ⇒ 10 条 —— 这条让「同参数才合并」有意义")

        // ⌘Z 一步回到拖动前
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.curve.white[1], CurvePoint(u: 0.5, v: 0.5))

        print("drag · shipped \(base + 1 - base) 条（10 步）· per-tick 10 条 · ⌘Z → "
              + "\(session.edit.curve.white[1])")
    }

    // MARK: - 7. reset

    /// `复位本通道` 只清那一个；`全部复位` / 双击标题 → 四张表全回恒等，
    /// `CurveLUT.isIdentity == true`（渲染走 copy 分支），且每条都是一次历史。
    func testResetChannelClearsOnlyThatChannelAndResetAllReturnsTheIdentityBytes() {
        let session = CatalogSession()
        session.applyEdit { model in
            model.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.62), CurvePoint(u: 1, v: 1)]
            model.curve.red = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.4), CurvePoint(u: 1, v: 1)]
            model.curve.green = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.55), CurvePoint(u: 1, v: 1)]
            model.curve.blue = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.45), CurvePoint(u: 1, v: 1)]
        }
        session.commitEdit(label: "四条曲线")
        XCTAssertFalse(CurveLUT.isIdentity(session.edit.curve))

        // 复位本通道（R）
        let redTable = CurveLUT.buildOne(session.edit.curve.red)
        let before = session.history.count
        let red = CurveEditorModel(session: session, channel: .red)
        XCTAssertTrue(red.resetChannel())
        XCTAssertEqual(session.edit.curve.red, CurvePoint.linear)
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "复位本通道")
        XCTAssertNotEqual(session.edit.curve.white, CurvePoint.linear, "只清 R，不动 W")
        XCTAssertNotEqual(CurveLUT.buildOne(session.edit.curve.white), CurveLUT.identityTable(),
                          "W 的表还在")
        XCTAssertFalse(red.resetChannel(), "已经是恒等：不写空快照")

        // 全部复位
        let beforeAll = session.history.count
        let anyChannel = CurveEditorModel(session: session, channel: .blue)
        XCTAssertTrue(anyChannel.resetAll())
        XCTAssertEqual(session.edit.curve, CurveGroup.identity)
        XCTAssertTrue(CurveLUT.isIdentity(session.edit.curve),
                      "四张表回恒等 → 渲染走内核的 copy 分支")
        XCTAssertTrue(CurveLUT.tablesAreIdentity(CurveLUT.build(session.edit.curve)),
                      "整块 64 KB 表都是 i/(N−1)")
        XCTAssertEqual(session.history.count, beforeAll + 1, "全部复位 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "曲线", "标题双击的标签就是卡名")

        // 逐字节恒等：每一张表 == identityTable()
        for channel in CurveChannel.allCases {
            XCTAssertEqual(CurveLUT.buildOne(session.edit.curve[keyPath: channel.keyPath]),
                           CurveLUT.identityTable(),
                           "\(channel.label) 的表必须逐字节回到 i/(N−1)")
        }

        // 双击标题走的是同一个 verb（`PanelResets.curve()`），且恒等时不写
        XCTAssertFalse(PanelResets(session: session).curve())
        XCTAssertEqual(session.history.count, beforeAll + 1)

        let identityAfterReset = CurveLUT.isIdentity(session.edit.curve)
        print("reset · R → identity（W 仍是 \(session.edit.curve.white.count) 点）· "
              + "all → isIdentity \(identityAfterReset) · 历史各 +1")

        XCTAssertTrue(session.undo())
        XCTAssertNotEqual(session.edit.curve.blue, CurvePoint.linear, "⌘Z 把四条一起带回来")
        _ = redTable
    }

    // MARK: - 8. the preview is the engine's table

    /// 面板预览用的数组就是 `CurveLUT.buildOne(points)` 的结果，逐元素相等。
    func testThePreviewIsTheEnginesOwnTableAndNotASecondInterpolation() {
        let session = CatalogSession()
        session.applyEdit {
            $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.25, v: 0.35), CurvePoint(u: 0.6, v: 0.62),
                              CurvePoint(u: 1, v: 0.95)]
        }
        session.commitEdit(label: "手工曲线")

        for channel in CurveChannel.allCases {
            let model = CurveEditorModel(session: session, channel: channel)
            XCTAssertEqual(model.preview, CurveLUT.buildOne(model.points),
                           "\(channel.label) 的预览必须 == buildOne(points)")
            XCTAssertEqual(model.preview.count, CurveLUT.size)
        }

        // 同一张表也喂给渲染：整块缓冲区里 W 那一段就是预览
        let full = CurveLUT.build(session.edit.curve)
        let model = CurveEditorModel(session: session, channel: .white)
        XCTAssertEqual(Array(full[0..<CurveLUT.size]), model.preview,
                       "预览的 W 段与上传给内核的第一段是同一组数")
        print("preview · \(model.preview.count) 点逐元素 == buildOne · 与上传缓冲首段一致")
    }

    // MARK: - 8b. 061 — the endpoints move in x (that is the black point)

    /// 061 ①：把**首端点右移到 u = 0.2**。表里 `u < 0.2` 的 100 个采样点必须**全部相等**（黑点裁切），
    /// 之上仍在上升，整张表仍单调不减；文档 x 严格递增；一次拖动只有一条历史；复位逐字节回恒等。
    ///
    /// **反证**：拿同一个拖动目标按 051 的「首点钉在 0」重建，同样那 100 个采样点**各不相同** ——
    /// 没有这一半，「裁切生效」在表恰好因为别的原因变平时也会绿。
    func testMovingTheFirstEndpointRightClipsTheWholeSegmentBelowItToOneValue() throws {
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.45), CurvePoint(u: 1, v: 1)] }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 0)
        XCTAssertEqual(origin, CurvePoint(u: 0, v: 0))
        XCTAssertTrue(model.drag(index: 0, to: CurvePoint(u: 0.2, v: 0), from: origin!, lock: .free))
        XCTAssertEqual(session.edit.curve.white[0].x, 0.4, accuracy: 1e-12, "右移首点 = 抬黑点")
        XCTAssertEqual(session.edit.curve.white[0].y, 0, "y 不动")
        XCTAssertEqual(session.history.count, base, "拖动中不写历史")
        XCTAssertTrue(model.endDrag())
        XCTAssertEqual(session.history.count, base + 1, "一次拖动 = 一条历史")
        XCTAssertTrue(CurveEditor.isOrdered(session.edit.curve.white), "x 仍严格递增")

        let t = model.preview
        XCTAssertEqual(t, CurveLUT.buildOne(model.points), "预览仍是引擎那张表")

        // `u < 首点` 的 100 个抽样（069：首点吸附到格 102，u = 102/511 = 0.19961…，所以边界取它的
        // 自身坐标，不是写死的 0.2）
        let blackU = session.edit.curve.white[0].u
        let ids = (0..<100).map { Int((blackU * Double($0) / 100 * Double(CurveLUT.size - 1)).rounded()) }
        let below = Set(ids.map { t[$0] })
        XCTAssertEqual(below.count, 1, "u < 首点 必须全部相等，实际 \(below.sorted())")
        XCTAssertEqual(ids.map { t[$0] }.max() ?? -1, 0, accuracy: 1e-7, "first.y = 0 → 裁到 0")

        // …而且不是整张表都平了：0.2 之上仍在上升，整表单调不减
        XCTAssertGreaterThan(t[Int(0.35 * Double(CurveLUT.size - 1))], 0.05, "0.2 之上必须还在上升")
        for i in 1..<t.count {
            XCTAssertGreaterThanOrEqual(t[i], t[i - 1], "端点右移后表在第 \(i) 个采样折回")
        }

        // **反证**：051 的夹取（首点恒 0）用同一个拖动目标重建 → 同样 100 个采样点各不相同
        let pinned = CurveLUT.buildOne([CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.45), CurvePoint(u: 1, v: 1)])
        let pinnedBelow = ids.map { pinned[$0] }
        XCTAssertGreaterThan(Set(pinnedBelow).count, 1, "钉死的端点：采样点必须各不相同")
        XCTAssertGreaterThan((pinnedBelow.max() ?? 0) - (pinnedBelow.min() ?? 0), 0.05,
                             "钉死的端点：暗部是斜坡，不是常量")
        // 同一条反证钉在源码上：钉死端点的两行不许回来
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertFalse(source.contains("if index == 0 { return 0 }"), "端点 x 又被钉死了（061 反证）")
        XCTAssertFalse(source.contains("if index == points.count - 1 { return 1 }"))

        // 复位：逐字节回到恒等 → 内核走 copy 分支，像素一个字节都不动
        XCTAssertTrue(model.resetChannel())
        XCTAssertTrue(CurveLUT.isIdentity(session.edit.curve))
        XCTAssertEqual(CurveLUT.buildOne(session.edit.curve.white), CurveLUT.identityTable())
        XCTAssertTrue(CurveLUT.tablesAreIdentity(CurveLUT.build(session.edit.curve)))

        print("black point · first.x → 格 \(session.edit.curve.white[0].x)（复位后）· "
              + "u<首点 的 100 点：搬过去 \(below.count) 个值，钉死则 "
              + "\(Set(pinnedBelow).count) 个值（跨度 \(String(format: "%.3f", (pinnedBelow.max() ?? 0) - (pinnedBelow.min() ?? 0))))")
    }

    /// 061 ②：把**末端点左移到 u = 0.8** —— `u > 0.8` 全部同一个输出（白点裁切），最后一段斜率 0，
    /// 所以 +4 EV 之上也停在那里；表仍单调，一次拖动一条历史。
    func testMovingTheLastEndpointLeftClipsTheHighlightsToOneValue() {
        let start = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.5), CurvePoint(u: 1, v: 1)]
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = start }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 2)
        XCTAssertTrue(model.drag(index: 2, to: CurvePoint(u: 0.8, v: 0.9), from: origin!, lock: .free))
        XCTAssertEqual(session.edit.curve.white[2].x, 1.6, accuracy: 1e-12, "左移末点 = 降白点")
        XCTAssertEqual(session.edit.curve.white[2].y, 1.8, accuracy: 1e-12)
        XCTAssertEqual(session.history.count, base, "拖动中不写历史")
        XCTAssertTrue(model.endDrag())
        XCTAssertEqual(session.history.count, base + 1)
        XCTAssertTrue(CurveEditor.isOrdered(session.edit.curve.white))

        // 直接用点列表建表：u > 0.8 的 100 个抽样全等，且等于 last.y
        let t = CurveLUT.buildOne(session.edit.curve.white)
        let ids = (0..<100).map {
            Int(((0.8 + 0.2 * Double($0 + 1) / 100) * Double(CurveLUT.size - 1)).rounded())
        }
        let above = Set(ids.map { t[$0] })
        XCTAssertEqual(above.count, 1, "u > 0.8 必须全部相等，实际 \(above.sorted())")
        let lastY = ids.map { Double(t[$0]) }.max() ?? -1
        XCTAssertEqual(lastY, 0.9, accuracy: 1e-6, "last.y = 0.9（即 v = 0.9）")
        XCTAssertEqual(CurveLUT.slope(of: t), 0, accuracy: 1e-6,
                       "平的最后一段 → 斜率 0：+4 EV 之上不再上升（rule 4）")
        for i in 1..<t.count {
            XCTAssertGreaterThanOrEqual(t[i], t[i - 1], "端点左移后表在第 \(i) 个采样折回")
        }
        XCTAssertLessThan(t[Int(0.5 * Double(CurveLUT.size - 1))], 0.8, "0.8 以下不是常量")

        print("white point · last.x = 0.8, y = 0.9 · u>0.8 的 100 点 → \(above.count) 个值 · slope "
              + "\(CurveLUT.slope(of: t))")
    }

    /// 061 ⑤：**两种 sub-black 情况都要钉住**（表与 CPU 参考这一侧；渲染侧在 `HDRCurveTests` ⑩）。
    ///
    ///   · `first.x == 0` → `x ≤ 0` 直通、符号不变（018 的既有断言必须仍绿）；
    ///   · `first.x == 0.2` → 负值也落到表里 `u = 0` 那一个常量上（裁切没有洞）。
    ///
    /// 两种情况的输出**必须不同**——否则"裁切"与"直通"就只是同一句话的两种说法。
    func testTheSubBlackRuleFollowsTheBlackPointAndNotTheMoodOfTheDay() {
        let atZero = CurveLUT.buildOne([CurvePoint(u: 0, v: 0.4), CurvePoint(u: 1, v: 1)])
        let zeroSlope = CurveLUT.slope(of: atZero)
        for x in [-0.039, -0.004, -1e-9, 0.0] {
            XCTAssertEqual(HDRCurve.channel(x, table: atZero, slope: zeroSlope, blackPoint: 0), x,
                           "first.x == 0：\(x) 必须原样穿过（018 的符号保真）")
        }

        // 069: the black point is a cell — the kernel gets `x/511` through `CurveLUT.blackPoints`, so
        // the constant is asked for at the same number.
        let raisedPoint = CurvePoint(u: 0.2, v: 0.3)
        let raised = CurveLUT.buildOne([raisedPoint, CurvePoint(u: 1, v: 1)])
        let raisedSlope = CurveLUT.slope(of: raised)
        let clip = HDRCurve.channel(0, table: raised, slope: raisedSlope, blackPoint: raisedPoint.u)
        XCTAssertGreaterThan(clip, 1e-3, "first.y = 0.3 → 裁到的常量是 0.3 对应的线性值")
        for x in [-0.039, -0.004, -1e-9, 0.0, 1e-5, 1e-4, 5e-4] {
            XCTAssertEqual(HDRCurve.channel(x, table: raised, slope: raisedSlope, blackPoint: raisedPoint.u),
                           clip, accuracy: 1e-12, "\(x) 必须与 u = 0 的常量相等（裁切没有洞）")
        }
        XCTAssertNotEqual(HDRCurve.channel(-0.039, table: raised, slope: raisedSlope, blackPoint: 0),
                          clip, "反证：按 first.x == 0 走同一条负值会穿过去 —— 两条路必须不同")

        // 表自己的那一半：u < 首点 是常量（与 HDRCurve 的 u = 0 项同一个数）
        let ids = (0..<100).map {
            Int((raisedPoint.u * Double($0) / 100 * Double(CurveLUT.size - 1)).rounded())
        }
        XCTAssertEqual(Set(ids.map { raised[$0] }).count, 1)
        XCTAssertEqual(Double(raised[0]), raisedPoint.v, accuracy: 1e-6, "first.y = 格 \(raisedPoint.y)")
        XCTAssertEqual(HDRCurve.axis.inverse(Double(raised[0])), clip, accuracy: 1e-12)

        print("sub-black · first.x=0 → 直通；first.x=格 \(raisedPoint.x) → 常量 "
              + "\(String(format: "%.6f", clip)) linear（表项 \(raised[0])）")
    }

    // MARK: - 9. the panel's size

    /// 面板在检查器的 274 pt 内容宽度下量出的高度，以及**它不随文档变化**。
    ///
    /// The second half is what protects the cards below it: a card whose height followed the curve
    /// (a point count, a readout line) would push 预设/蒙版/Decode down every time the user dragged a
    /// point. The card is a fixed-height plot + furniture, so nothing below it moves.
    func testThePanelHasAFixedHeightAtTheInspectorWidthAndDoesNotFollowTheDocument() throws {
        let identity = Self.fittingSize(CurvePanel(session: CatalogSession()), width: 274)

        let edited = CatalogSession()
        edited.applyEdit {
            $0.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.2, v: 0.3), CurvePoint(u: 0.55, v: 0.5),
                              CurvePoint(u: 0.8, v: 0.9), CurvePoint(u: 1, v: 1)]
            $0.curve.red = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.4), CurvePoint(u: 1, v: 1)]
        }
        edited.commitEdit(label: "曲线")
        let busy = Self.fittingSize(CurvePanel(session: edited), width: 274)

        XCTAssertEqual(busy.height, identity.height, accuracy: 0.5,
                       "面板高度不跟文档走，否则下面的卡片会被推着动")
        // `fittingSize` reports the *ideal* width (the tab row's), which must never exceed the card.
        // The panel is greedy (`.frame(maxWidth: .infinity)`) so the plot spans the card; that is a
        // layout detail a hosted view cannot report, so it is pinned on the source instead.
        XCTAssertLessThanOrEqual(identity.width, 274,
                                 "理想宽度不许超过卡片内容宽（274 pt），否则检查器会被撑开")
        let panelSource = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(panelSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
                      "面板必须吃满卡片宽度，否则 274 pt 的绘图区会缩成理想宽度")

        // The plot is the tallest part; the furniture is the tick band, the tabs and the buttons.
        XCTAssertGreaterThan(identity.height, CurvePanelMetrics.plotHeight)
        XCTAssertLessThan(identity.height,
                          CurvePanelMetrics.plotHeight + CurvePanelMetrics.tickBand + 80,
                          "脚注 + 两个按钮 + tab 不该占到 80 pt")

        // Narrowest and widest inspector: same height, because the plot's height is a constant.
        let narrow = Self.fittingSize(CurvePanel(session: CatalogSession()), width: 244)
        XCTAssertEqual(narrow.height, identity.height, accuracy: 0.5)
        print("size · \(String(format: "%.1f", identity.width))×\(String(format: "%.1f", identity.height)) pt"
              + " @274 宽 · 文档变了之后 \(String(format: "%.1f", busy.height)) pt")
    }

    // MARK: - 10. where the card sits

    /// 曲线卡在「细节」之后、预设之前；其它卡的相对位置一条没动；标题双击接的是 `PanelResets.curve()`。
    func testTheCurveCardSitsDirectlyUnderDetailAndLeavesEveryOtherCardInPlace() throws {
        let titles = InspectorView.sectionTitles
        let detail = try XCTUnwrap(titles.firstIndex(of: "细节"))
        XCTAssertEqual(titles[detail + 1], "曲线", "曲线必须在细节之后，实际 \(titles)")

        // 076 把 HSL 插在 Color 之后（它属于「色彩」工作区），077 把历史记录放在最后，2026-10-28
        // 把效果插在曲线之后（暗角 + 颗粒是最后两段渲染），同一天又把黑白插在 Color 之后（S3.4 紧跟
        // S3）—— 其它卡的相对顺序一条都没动。
        XCTAssertEqual(titles.filter { $0 != "曲线" },
                       ["直方图", "白平衡", "黑电平", "Light", "Color", "黑白", "HSL", "色彩分级", "细节",
                        "效果", "预设", "裁切", "蒙版", "历史记录"],
                       "插入一张卡，其它卡的相对顺序一条都不许变")
        XCTAssertTrue(InspectorView.scrollingSections.contains(.curve), "曲线跟随滚动，不属于钉住区")
        XCTAssertFalse(InspectorView.scrollingSections.contains(.histogram))

        // 标题 = 卡名 = 撤销标签
        XCTAssertEqual(InspectorView.Section.curve.title, "曲线")
        // 046/047 的约定：双击标题 = 全部复位（一条历史），接线在唯一那个 card builder 上。
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("card(Section.curve.title, reset: { resets.curve() })"),
                      "曲线卡的标题必须接 PanelResets.curve()")
        XCTAssertTrue(source.contains("case .curve:\n            curveCard"))

        // 047 的四张参数卡清单没有被曲线改写：Group 还是那四个 + 2026-10-28 的效果卡 + 黑白卡。
        XCTAssertEqual(PanelResets.Group.allCases.map(\.rawValue),
                       ["whiteBalance", "light", "color", "blackAndWhite", "detail", "effects",
                        "colorGrading"])
        print("layout · \(titles) · 曲线 index \(detail + 1)")
    }

    // MARK: - 11. 064: the value box is inset one radius, so every circle is whole

    /// 边缘/角落的控制点圆必须整个画在绘图区里 —— 圆心到四边的距离 ≥ 半径，且圆的包围盒整个落在绘图区里。
    /// 用几何算，不看截图。
    ///
    /// ⚠ 064 的验收原文写的是 `plot.insetBy(dx: r).contains(circleRect)`。这一条和"`inset = radius + 1`"
    /// **互相矛盾**：`circleRect ⊆ plot.insetBy(r)` 要求圆心离每条边至少 **2r**，也就是 `inset ≥ 2r = 6`，
    /// 而 `inset = r + 1 = 4`。所以这里钉的是那条断言真正想说的话 —— `plot.contains(circleRect)`
    /// 加上"圆心到四边的距离 ≥ r"—— 并把原式的结果也钉住（在 4 pt 下为假，需要 6 pt 才为真），
    /// 让这条矛盾在源码里可见，而不是被悄悄改弱。
    ///
    /// **反证**：同一个谓词跑 `inset = 0`（就是改动前的映射）—— `(0,0)` 那一项必须为假，所以第 1 条
    /// 断言不是"永远绿"的空话。
    func testEveryControlPointCircleAtACornerOrEdgeIsWholeInsideThePlot() {
        let plot = CGRect(x: 0.5, y: 0.5, width: 274, height: 189)
        let geometry = CurvePlotGeometry(plot: plot)
        let r = CurvePanelMetrics.pointRadius
        // "距四边 ≥ r" 的正确写法（也是 064 原式真正想说的话）：**圆心**落在 plot.insetBy(r) 里
        // ⟺ 圆心离每条边 ≥ r ⟺ 半径 r 的圆整个落在 plot 里。原式把这个 insetBy(r) 用在了圆的包围盒上，
        // 那要求的是 2r —— 见下面钉住的那条。
        let centreRoom = plot.insetBy(dx: r, dy: r)

        // 内缩量 == radius + 1，且换算严格相等（不是差一点）
        XCTAssertEqual(geometry.inset, r + 1, accuracy: 1e-12, "inset 必须是 半径 + 1 pt 呼吸")
        XCTAssertEqual(geometry.inset, CurvePanelMetrics.pointInset, accuracy: 1e-12)
        XCTAssertEqual(geometry.x(u: 0), plot.minX + geometry.inset, "x(0) == inset")
        XCTAssertEqual(geometry.x(u: 2), plot.maxX - geometry.inset, "x(2) == width − inset")
        XCTAssertEqual(geometry.y(v: 2), plot.minY + geometry.inset, "y(2) == inset")
        XCTAssertEqual(geometry.y(v: 0), plot.maxY - geometry.inset, "y(0) == height − inset")
        XCTAssertEqual(geometry.x(u: 0), geometry.valueBox.minX)
        XCTAssertEqual(geometry.x(u: 2), geometry.valueBox.maxX)
        XCTAssertEqual(geometry.y(v: 2), geometry.valueBox.minY)
        XCTAssertEqual(geometry.y(v: 0), geometry.valueBox.maxY)

        // 四角 + 四边中点，都用 `point(_:)` 走一遍真正的绘制路径
        let samples: [(String, CurvePoint)] = [
            ("左下角 (0,0)", CurvePoint(u: 0, v: 0)), ("右下角 (1,0)", CurvePoint(u: 1, v: 0)),
            ("左上角 (0,1)", CurvePoint(u: 0, v: 1)), ("右上角 (1,1)", CurvePoint(u: 1, v: 1)),
            ("左边 (0,½)", CurvePoint(u: 0, v: 0.5)), ("右边 (1,½)", CurvePoint(u: 1, v: 0.5)),
            ("下边 (½,0)", CurvePoint(u: 0.5, v: 0)), ("上边 (½,1)", CurvePoint(u: 0.5, v: 1)),
        ]
        var report: [String] = []
        for (name, p) in samples {
            let c = geometry.point(p)
            let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            XCTAssertTrue(centreRoom.contains(c),
                          "\(name) 的圆心离某条边不到一个半径：圆心 \(c)，允许区 \(centreRoom)")
            XCTAssertTrue(plot.contains(circle),
                          "\(name) 的圆没整个落在绘图区里：圆 \(circle)，绘图区 \(plot)")
            // 到绘图区四边的实测距离（四条，取最小那条和半径比）
            let distances = [c.x - plot.minX, plot.maxX - c.x, c.y - plot.minY, plot.maxY - c.y]
            XCTAssertGreaterThanOrEqual(distances.min() ?? -1, r,
                                        "\(name) 到最近一条边不足一个半径：\(distances)")
            // 呼吸恰好 1 pt：最近的一条边距 == inset == r + 1
            XCTAssertEqual(distances.min() ?? -1, geometry.inset, accuracy: 1e-12,
                           "\(name) 的呼吸不是 1 pt")
            report.append("\(name) 边距 "
                          + distances.map { String(format: "%.2f", $0) }.joined(separator: "/"))
        }

        // 064 原文式的实测结果（钉住这条矛盾本身）：4 pt 下为假，需 ≥ 2r = 6 pt 才为真。
        let c00 = geometry.point(CurvePoint(u: 0, v: 0))
        let circle00 = CGRect(x: c00.x - r, y: c00.y - r, width: 2 * r, height: 2 * r)
        XCTAssertFalse(plot.insetBy(dx: r, dy: r).contains(circle00),
                       "原文式 `plot.insetBy(r).contains(circle)` 需要 inset ≥ 2r；若这里变真说明 inset 被悄悄加大"
                       + "（当前 inset = \(geometry.inset)，2r = \(2 * r)）")

        // 半径 3 / 3.5 / 4 都能整圆在内（inset 跟着半径走），供用户拍板"点大一点"时不用重算几何：
        // 只要 inset == r + 1，四角的呼吸就还是 1 pt。
        for radius in [CGFloat(3), 3.5, 4] {
            let g = CurvePlotGeometry(plot: plot, inset: radius + 1)
            for corner in [CurvePoint(u: 0, v: 0), CurvePoint(u: 1, v: 1), CurvePoint(u: 0, v: 1), CurvePoint(u: 1, v: 0)] {
                let c = g.point(corner)
                let circle = CGRect(x: c.x - radius, y: c.y - radius,
                                    width: 2 * radius, height: 2 * radius)
                XCTAssertTrue(plot.contains(circle), "半径 \(radius) 时 \(corner) 的圆出界")
                XCTAssertEqual(g.inset, radius + 1, accuracy: 1e-12)
            }
        }

        // 反证：inset 改回 0（改动前的映射）→ 同一个谓词必须红
        let naive = CurvePlotGeometry(plot: plot, inset: 0)
        for corner in [CurvePoint(u: 0, v: 0), CurvePoint(u: 1, v: 1), CurvePoint(u: 0, v: 1), CurvePoint(u: 1, v: 0)] {
            let c = naive.point(corner)
            let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse(centreRoom.contains(c),
                           "反证失效：inset = 0 时 \(corner) 的圆心就在边上")
            XCTAssertFalse(plot.contains(circle), "反证失效：inset = 0 时 \(corner) 的圆居然整个在区内")
        }
        XCTAssertEqual(naive.x(u: 0), plot.minX, "inset = 0 就是改动前：圆心贴在 x = 0 上")
        XCTAssertFalse(plot.contains(CGRect(x: naive.x(u: 0) - r, y: naive.y(v: 0) - r,
                                            width: 2 * r, height: 2 * r)),
                       "反证：inset = 0 时左下角的圆只剩四分之一")

        print("inset · \(String(format: "%.1f", geometry.inset)) pt（半径 \(r) + 1）· "
              + report.joined(separator: " · ")
              + " · 反证 inset=0 → 四角全部出界")
    }

    /// 网格、边框、y = x 参考线都画在**同一个内缩盒**上：最外两条网格线就是 `x(0)/x(1)/y(0)/y(1)`。
    func testTheGridFrameAndDiagonalAllSitOnTheSameInsetValueBox() throws {
        // The real layout rect at the inspector's 274 pt width — not a made-up box.
        let plot = CurvePanelMetrics.plotRect(in: CGSize(width: 274, height: CurvePanelMetrics.plotHeight))
        XCTAssertEqual(plot, CGRect(x: 0.5, y: 0.5, width: 273, height: 188.5),
                       "绘图区布局（含刻度带）不许因为内缩而改变")
        let geometry = CurvePlotGeometry(plot: plot)
        let box = geometry.valueBox
        let grid = geometry.gridLines()

        XCTAssertEqual(grid.vertical.count, CurvePanelMetrics.gridDivisions + 1)
        XCTAssertEqual(grid.horizontal.count, CurvePanelMetrics.gridDivisions + 1)

        // 网格的"边框"（最外两条线）与取值盒的坐标严格相等
        XCTAssertEqual(grid.vertical.first!, geometry.x(u: 0), "左边框不在 x(0) 上")
        XCTAssertEqual(grid.vertical.last!, geometry.x(u: 2), "右边框不在 x(2) 上")
        XCTAssertEqual(grid.horizontal.first!, geometry.y(v: 2), "上边框不在 y(2) 上")
        XCTAssertEqual(grid.horizontal.last!, geometry.y(v: 0), "下边框不在 y(0) 上")

        let frame = CGRect(x: grid.vertical.first!, y: grid.horizontal.first!,
                           width: grid.vertical.last! - grid.vertical.first!,
                           height: grid.horizontal.last! - grid.horizontal.first!)
        XCTAssertEqual(frame, box, "网格围出来的框必须 == 内缩盒")
        XCTAssertEqual(box, plot.insetBy(dx: geometry.inset, dy: geometry.inset))
        XCTAssertNotEqual(box, plot, "反证：内缩盒不能等于外框，否则圆又会出界")

        // 对角线也在这只盒子里（端点就是盒的两个角）
        XCTAssertEqual(geometry.x(u: 0), box.minX)
        XCTAssertEqual(geometry.y(v: 0), box.maxY)
        XCTAssertEqual(geometry.x(u: 2), box.maxX)
        XCTAssertEqual(geometry.y(v: 2), box.minY)

        // 刻度：位置仍由 axis 推出（差为 0），且标签仍在外框下方那一带（tickBand 没变）。
        // 071：默认视图是 SDR，`0…1` 铺满，所以 255 码（x = 1 = 白点）落在**右端**。
        let ticks = CurveAxisTicks.codes()
        let axis = HDRCurveAxis.standard
        let expected = [0.0, 63, 127, 191, 255].map {
            2 * axis.forward(CurveAxisTicks.displayCode($0))
        }
        let positions = geometry.tickPositions(ticks)
        XCTAssertEqual(positions[0], box.minX, accuracy: 1e-12)
        XCTAssertEqual(positions[positions.count - 1], box.maxX, accuracy: 1e-12,
                       "SDR 视图里白点在右端")
        for ((tick, want), position) in zip(zip(ticks, expected), positions) {
            XCTAssertEqual(tick.x, want, accuracy: 0, "刻度 \(tick.label) 的位置来自 HDRCurveAxis")
            XCTAssertEqual(position - (box.minX + CGFloat(want) * box.width), 0, accuracy: 1e-12,
                           "刻度 \(tick.label) 的位置差必须为 0")
        }
        // 外框（标签所在的那块）与取值盒的关系：只差一个 inset，布局没动
        XCTAssertEqual(CurvePanelMetrics.tickBand, 11)

        // 绘制代码用的确实是那只盒子（不是外框），否则"网格贴不贴边"只能靠眼睛
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(source.contains("let box = geometry.valueBox"),
                      "draw 必须显式取内缩盒")
        XCTAssertTrue(source.contains("gridPath.move(to: CGPoint(x: x, y: box.minY))")
                      && source.contains("CGPoint(x: box.maxX, y: y)"),
                      "网格线必须画在 box 上")
        XCTAssertTrue(source.contains("diagonal.move(to: CGPoint(x: box.minX, y: box.maxY))"),
                      "对角线也必须画在 box 上")

        print("grid · vertical \(grid.vertical.map { String(format: "%.1f", $0) })"
              + " · horizontal \(grid.horizontal.map { String(format: "%.1f", $0) })"
              + " · 边框 == \(frame) · 刻度位置差 "
              + String(format: "%.1e", tickError(ticks, positions, box)))
    }

    // MARK: - 12. 080 — the tail's drag limit is 2, and only the tail's

    /// 派单 080 (079 A5): 末段（最后两点之间）的斜率上限 **1 → 2**，而且拖动上限与渲染上限是**同一个数**
    /// （`HDRCurve.tailSlopeLimit`，kernel 的两处 `clamp` 由 `HDRCurveTests` 解析比对）。
    ///
    /// 三条主张，各有自己的数：
    ///   · 要求 4.0 的拖动落在 **2.000**（被限位），不是"随便就 4"；
    ///   · 同一个拖动在 1.0 上限下会是 **1.1** —— 所以"2.0 可拖出"不是空话（这就是 079 A5 之前的行为）；
    ///   · **中间段没有新上限**：不在末段的点原样写入（"y 不受夹取影响"是 061 起的既有规则，本单没有改它）。
    ///
    /// 最后一段的两端都能改变它的斜率，所以两端都被夹：末点往上拖封顶在 `prev.y + 2·Δx`，末点**左边那个**
    /// 点往下拖封底在 `last.y − 2·Δx`。
    func testTheTailCanBeDraggedToTwiceTheSlopeAndNoFurther() throws {
        XCTAssertEqual(CurveEditor.tailSlopeLimit, HDRCurve.tailSlopeLimit,
                       "拖动限位就是渲染上限，不是第二份拷贝")
        XCTAssertEqual(CurveEditor.tailSlopeLimit, 2.0, "079 A5：1 → 2")

        // A tail at 1.0 to start with — the old ceiling's maximum: (1.4, 0.8) → (2, 1.4).
        let start = [CurvePoint(0, 0), CurvePoint(1.4, 0.8), CurvePoint(2, 1.4)]
        XCTAssertEqual(try XCTUnwrap(CurveEditor.tailSlope(atLast: start[2], in: start)), 1.0,
                       accuracy: 1e-12, "起点正是旧上限的最大值")

        // Pull the white point left AND up: (1.7, 2) would be a slope of (2 − 0.8)/0.3 = 4.0.
        let steep = CurveEditor.movedPoint(CurvePoint(1.7, 2), index: 2, in: start,
                                           from: start[2], lock: .free)
        XCTAssertEqual(steep.x, 1.7, accuracy: 1e-12, "x 在框内原样通过")
        XCTAssertEqual(steep.y, 0.8 + 2 * 0.3, accuracy: 1e-12, "封顶在 y = 1.4 —— 斜率正好 2.0")
        XCTAssertEqual(try XCTUnwrap(CurveEditor.tailSlope(atLast: steep, in: start)), 2.0,
                       accuracy: 1e-12, "写出来的末段斜率就是 2.0")
        XCTAssertNotEqual(steep.y, 2, "反证：不夹取就是 (1.7, 2) → 斜率 4.0")

        // 反证 for the *old* ceiling: the same gesture with 1.0 lands on 1.1, i.e. 0.3 lower.
        let asIfOne = start[1].y + 1.0 * (1.7 - start[1].x)
        XCTAssertEqual(asIfOne, 1.1, accuracy: 1e-12)
        XCTAssertGreaterThan(steep.y - asIfOne, 0.29, "上限 1.0 时这个拖动只能到 1.1")

        // The other end of the tail: drag the point *before* it down, and it stops at slope 2.
        let floored = CurveEditor.movedPoint(CurvePoint(1.6, 0.2), index: 1, in: start,
                                            from: start[1], lock: .free)
        XCTAssertEqual(floored.x, 1.6, accuracy: 1e-12)
        XCTAssertEqual(floored.y, 1.4 - 2 * 0.4, accuracy: 1e-12, "封底在 y = 0.6")
        XCTAssertEqual(try XCTUnwrap(CurveEditor.tailSlope(atLast: start[2],
                                                          in: [start[0], floored, start[2]])), 2.0,
                       accuracy: 1e-12)

        // **中间段**: a point that is not on the tail passes through untouched — including a segment
        // slope of 2.0, which is a legitimate midtone S and has been legal since 051/061 (the
        // suite's own `testDraggingAPointPastItsNeighbourIsClampedToTheGap` drags `y` freely).
        let four = [CurvePoint(0, 0), CurvePoint(0.5, 0.2), CurvePoint(1.5, 1.0), CurvePoint(2, 2)]
        let interior = CurveEditor.movedPoint(CurvePoint(0.5, 1.2), index: 1, in: four,
                                             from: four[1], lock: .free)
        XCTAssertEqual(interior.y, 1.2, accuracy: 1e-12, "中间段的 y 原样通过（本单没有给它加上限）")
        XCTAssertEqual((interior.y - four[0].y) / (interior.x - four[0].x), 1.2 / 0.5, accuracy: 1e-12,
                       "段斜率 2.4 的中间段是合法的 —— 它只进表，不外延")
        XCTAssertEqual(four[3].y, CurveEditor.movedPoint(CurvePoint(2, 2), index: 3, in: four,
                                                         from: four[3], lock: .free).y,
                       accuracy: 1e-12, "恒等末段（斜率 1）当然不被夹")

        // **SDR 轴与 HDR 轴同一口径.** 卡上的 `x/2` 就是引擎的 `u`（`CurvePoint.u`），横竖两条轴按同一个 2
        // 缩放，所以同一条曲线在卡坐标里和引擎轴里的末段斜率是**同一个数**，限位也就不需要按轴/半轴分支：
        // 无论那一段落在 SDR 半轴还是 HDR 半轴，斜率 2 都是斜率 2。
        let card = [CurvePoint(0.5, 0.2), CurvePoint(1.5, 1.0), CurvePoint(2, 1.8)]
        let cardSlope = try XCTUnwrap(CurveEditor.tailSlope(atLast: card[2], in: card))
        let axisSlope = (card[2].v - card[1].v) / (card[2].u - card[1].u)
        XCTAssertEqual(axisSlope, cardSlope, accuracy: 1e-12, "Δv/Δu 与 Δy/Δx 是同一个数")
        let clamped = CurveEditor.clampTail(2.0, x: 1.7, index: 2, in: card)
        XCTAssertEqual((clamped - card[1].y) / (1.7 - card[1].x), 2.0, accuracy: 1e-12, "卡坐标里正好 2")
        let onAxis = CurvePoint(1.7, clamped)
        XCTAssertEqual((onAxis.v - card[1].v) / (onAxis.u - card[1].u), 2.0, accuracy: 1e-12,
                       "…引擎轴里也是 2（换坐标不改斜率，所以 SDR/HDR 两半同一口径）")

        // Through the panel's own path: 一次拖动 → 文档；再写盘、读回，还是那四个数。
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = start }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let origin = try XCTUnwrap(model.beginDrag(at: 2))
        model.drag(index: 2, to: CurvePoint(1.7, 2), from: origin, lock: .free)
        XCTAssertTrue(model.endDrag(), "抬起 = 一条快照")
        let written = session.edit.curve.white
        XCTAssertEqual(written[2].x, 1.7, accuracy: 1e-12)
        XCTAssertEqual(written[2].y, 0.8 + 2 * 0.3, accuracy: 1e-12,
                       "通过 CurveEditorModel 写进文档的也是封顶后的 1.4")
        XCTAssertEqual(try XCTUnwrap(CurveEditor.tailSlope(atLast: written[2], in: written)), 2.0,
                       accuracy: 1e-12)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session.edit)
        let reloaded = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(reloaded.curve.white, written, "存盘 → 重载，末段斜率 2.0 的控制点原样回来")
        XCTAssertEqual(try XCTUnwrap(CurveEditor.tailSlope(atLast: reloaded.curve.white[2],
                                                          in: reloaded.curve.white)), 2.0,
                       accuracy: 1e-12, "…重载后的斜率仍是 2.0")
        XCTAssertEqual(try encoder.encode(reloaded), data, "写 → 读 → 写逐字节相等")

        let csv = written.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: "\n")
        print("080 drag · 末段斜率 \(try XCTUnwrap(CurveEditor.tailSlope(atLast: written[2], in: written)))"
              + " · 中间段 2.4 未被夹 · 存盘重载逐字节相等\ncurve.csv\nx,y\n" + csv)
    }

    // MARK: - helpers

    /// The largest |tick − (box.minX + x/2·width)|, computed in one place so the print statement does
    /// not become a type-checker puzzle.
    private func tickError(_ ticks: [CurveAxisTick], _ positions: [CGFloat], _ box: CGRect) -> CGFloat {
        var worst: CGFloat = 0
        for (tick, position) in zip(ticks, positions) {
            worst = max(worst, abs(position - (box.minX + CGFloat(tick.x / 2) * box.width)))
        }
        return worst
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var panelSource: URL { repoRoot.appendingPathComponent("Sources/PhotonsUI/CurvePanel.swift") }
    private static var inspectorSource: URL { repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift") }

    /// The same measurement `SliderStyleTests` uses: a real `NSHostingView` in a borderless window,
    /// laid out at a fixed width, then `fittingSize` read back.
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

    /// The windows have to outlive the measurement; `NSHostingView` returns zeros once its window is
    /// gone.
    private static var windows: [NSWindow] = []
}
