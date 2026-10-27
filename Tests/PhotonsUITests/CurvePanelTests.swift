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

    /// The five positions are `u(0)`, `u(0.18)`, `u(1)`, `u(+2)`, `u(+4)` — to 1e-9 — and the labels
    /// are exactly `0 / 0.18 / 1 / +2 / +4`. `+4` is the right edge and there is no `+6` (044).
    func testTheFiveTicksAreTheAxisOwnPositionsAndNotNumbers() {
        let axis = HDRCurveAxis.standard
        let ticks = CurveAxisTicks.ticks(axis)

        XCTAssertEqual(ticks.map(\.label), ["0", "0.18", "1", "+2", "+4"])

        let expected = [axis.forward(0),                       // x = 0
                        axis.forward(CurveAxisTicks.middleGrey), // 18 % grey
                        axis.forward(1),                       // display white
                        axis.u(stops: 2),
                        axis.u(stops: 4)]
        XCTAssertEqual(ticks.count, expected.count)
        for (tick, want) in zip(ticks, expected) {
            XCTAssertEqual(tick.u, want, accuracy: 1e-9,
                           "刻度 \(tick.label) 的位置必须由 axis 算出，不能写死")
        }

        // Monotone, and the last one *is* the right edge (that is what makes "+4 at the end" true).
        XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { $0.u < $1.u })
        XCTAssertEqual(ticks.last?.u ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(axis.stops(at: 1), 4, accuracy: 1e-6, "右端 = +4 EV（044），不是 +6")

        // And in points: the tick x is `u` across the plot, so the drawing cannot disagree either.
        let plot = CGRect(x: 0, y: 0, width: 274, height: 189)
        let geometry = CurvePlotGeometry(plot: plot)
        let positions = geometry.tickPositions(ticks)
        for (position, want) in zip(positions, expected) {
            XCTAssertEqual(position, plot.minX + CGFloat(want) * plot.width, accuracy: 1e-9)
        }
        XCTAssertEqual(positions.first ?? -1, plot.minX, accuracy: 1e-9)
        XCTAssertEqual(positions.last ?? -1, plot.maxX, accuracy: 1e-9)

        print("ticks · " + zip(ticks, positions)
            .map { "\($0.label)@u=\(String(format: "%.6f", $0.u))→x=\(String(format: "%.3f", $1))" }
            .joined(separator: " · ")
            + " · 最大误差 \(zip(ticks, expected).map { abs($0.u - $1) }.max() ?? 0)")
    }

    /// 反证 for claim 1: the panel's source contains **no** axis position literal.
    ///
    /// The ticks are derived, so `0.5955` / `0.7500` / `0.875` cannot appear — if someone pastes the
    /// numbers back in, this turns red before the picture does.
    func testThePanelSourceWritesNoAxisPositionLiterals() throws {
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        for literal in ["0.5955", "0.7500", "0.750", "0.875"] {
            XCTAssertFalse(source.contains(literal),
                           "CurvePanel.swift 里出现了 \(literal)：刻度必须是算出来的")
        }
        // …because it does the derivation, through the two functions that own it.
        XCTAssertTrue(source.contains("axis.forward(CurveAxisTicks.middleGrey)")
                      || source.contains("axis.forward(middleGrey)"))
        XCTAssertTrue(source.contains("axis.u(stops: 2)") && source.contains("axis.u(stops: 4)"))
        XCTAssertTrue(source.contains("CurveLUT.buildOne(points)"),
                      "预览必须是引擎那张表，不是第二种插值")
    }

    // MARK: - 2. insert

    /// 单击空白 = 在该 x 插一个点，**y 取当前曲线在该 x 的值**（不是 0，也不是 x）。
    ///
    /// Two curves, because "y = the curve's value" and "y = the identity's value" differ on the second:
    /// a 0 → 0.5 ramp is 0.25 at the midpoint, and a panel that wrote `x` would write 0.5.
    func testClickingEmptySpaceInsertsAPointAtTheCurvesOwnValue() {
        let identity = CatalogSession()
        let identityModel = CurveEditorModel(session: identity, channel: .white)
        XCTAssertNotNil(identityModel.insert(atU: 0.3))
        let onIdentity = identity.edit.curve.white
        XCTAssertEqual(onIdentity.count, 3)
        XCTAssertEqual(onIdentity[1].x, 0.3, accuracy: 1.0 / Double(CurveLUT.size))
        XCTAssertEqual(onIdentity[1].y, 0.3, accuracy: 1.0 / Double(CurveLUT.size),
                       "恒等曲线上 y == x")
        XCTAssertTrue(CurveEditor.isOrdered(onIdentity))
        XCTAssertEqual(identity.history.count, 1, "插入 = 一次动作 = 一条历史")

        // A ramp whose midpoint is 0.25: the new point must land on the *curve*, not at 0 or at x.
        let ramp = CatalogSession()
        ramp.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(1, 0.5)] }
        ramp.commitEdit(label: "ramp")
        let rampModel = CurveEditorModel(session: ramp, channel: .white)
        XCTAssertNotNil(rampModel.insert(atU: 0.5))
        let inserted = ramp.edit.curve.white
        XCTAssertEqual(inserted.count, 3)
        XCTAssertEqual(inserted[1].y, 0.25, accuracy: 0.01,
                       "y 取曲线在该 x 的值（0.25），不是 0，也不是 x（0.5）")
        XCTAssertNotEqual(inserted[1].y, 0, accuracy: 1e-6, "反证：y 不能是 0")
        XCTAssertNotEqual(inserted[1].y, 0.5, accuracy: 0.01, "反证：y 不能是 x")

        print("insert · identity 插入后 x = \(onIdentity.map(\.x)) · "
              + "ramp 中点 y = \(String(format: "%.4f", inserted[1].y))（0.25，不是 0 / 0.5）")
    }

    // MARK: - 3. the clamp

    /// 把中间点拖到最左 → x 被夹在左邻点 + 1e-3；点数不变，`points` 仍严格递增。
    ///
    /// **反证**：同一目标点不夹取地写进去，列表就不递增 —— 所以"夹取生效"不是空话。
    func testDraggingAPointPastItsNeighbourIsClampedToOneMilliMetreGap() {
        let start = [CurvePoint(0, 0), CurvePoint(0.3, 0.2), CurvePoint(0.8, 0.9), CurvePoint(1, 1)]

        // (a) 拖到最左：左邻点是 0.3 → 0.3 + 1e-3
        let left = CurveEditor.movedPoint(CurvePoint(-5, 0.4), index: 1, in: start,
                                          from: start[1], lock: .free)
        XCTAssertEqual(left.x, start[0].x + CurveEditor.minimumGap, accuracy: 1e-12,
                       "夹在左邻点 + 1e-3")
        XCTAssertEqual(left.y, 0.4, accuracy: 1e-12, "y 不受夹取影响")

        // (b) 拖到最右：右邻点是 0.8 → 0.8 − 1e-3
        let right = CurveEditor.movedPoint(CurvePoint(5, 0.4), index: 1, in: start,
                                           from: start[1], lock: .free)
        XCTAssertEqual(right.x, start[2].x - CurveEditor.minimumGap, accuracy: 1e-12)

        // (c) 拖到零点几的邻点之间：0.3 / 0.8 之间的目标 0.6 原样通过（夹取不是"永远贴边"）
        let middle = CurveEditor.movedPoint(CurvePoint(0.6, 0.4), index: 1, in: start,
                                            from: start[1], lock: .free)
        XCTAssertEqual(middle.x, 0.6, accuracy: 1e-12)

        // (d) 左邻是**内部点**：index 2 的左边是 0.3 → 拖到最左停在 0.301，右边 1 不动
        let againstInterior = CurveEditor.movedPoint(CurvePoint(-5, 0.9), index: 2, in: start,
                                                     from: start[2], lock: .free)
        XCTAssertEqual(againstInterior.x, 0.3 + CurveEditor.minimumGap, accuracy: 1e-12,
                       "夹取对着**当前**的左邻点算，不是按下时的那个")

        // (e) **061**: 端点可以在 x 上移动 —— 右移左端点就是调黑点，左移右端点就是调白点
        let first = CurveEditor.movedPoint(CurvePoint(0.2, 0.9), index: 0, in: start,
                                           from: start[0], lock: .free)
        XCTAssertEqual(first.x, 0.2, accuracy: 1e-12, "首点必须能在 x 上移动（051 曾钉在 0）")
        XCTAssertEqual(first.y, 0.9, accuracy: 1e-12)
        let last = CurveEditor.movedPoint(CurvePoint(0.9, 0.1), index: 3, in: start,
                                          from: start[3], lock: .free)
        XCTAssertEqual(last.x, 0.9, accuracy: 1e-12, "末点必须能在 x 上移动（051 曾钉在 1）")
        XCTAssertEqual(last.y, 0.1, accuracy: 1e-12)

        // …但只在区间里：首点 ∈ [0, 次点 − 1e-3]，末点 ∈ [邻点 + 1e-3, 1]，x 仍严格递增
        XCTAssertEqual(CurveEditor.clampX(5, index: 0, in: start),
                       start[1].x - CurveEditor.minimumGap, accuracy: 1e-12,
                       "右移的首点停在次点左边 1e-3 处（不许越过）")
        XCTAssertEqual(CurveEditor.clampX(-5, index: 0, in: start), 0, accuracy: 1e-12,
                       "左边界仍是表的 0")
        XCTAssertEqual(CurveEditor.clampX(-5, index: 3, in: start),
                       start[2].x + CurveEditor.minimumGap, accuracy: 1e-12)
        XCTAssertEqual(CurveEditor.clampX(5, index: 3, in: start), 1, accuracy: 1e-12)
        XCTAssertEqual(CurveEditor.clampX(0.2, index: 0, in: start), 0.2, accuracy: 1e-12,
                       "区间内原样通过（不是\"永远贴边\"）")
        for target in [-5.0, 0.0, 0.2, 0.29, 5.0] {
            let p = CurveEditor.movedPoint(CurvePoint(target, 0.5), index: 0, in: start,
                                          from: start[0], lock: .free)
            XCTAssertTrue(CurveEditor.isOrdered([p] + start.dropFirst()), "首点拖到 \(target) 后仍须递增")
        }

        // **反证**: 钉死端点的那条规则会让上面每一条都红 —— 两种写法都留着，看得见差别
        XCTAssertNotEqual(first.x, 0, "反证：061 之前的 return 0 会得到 0")
        XCTAssertNotEqual(last.x, 1, "反证：061 之前的 return 1 会得到 1")

        // (f) ⇧ 的两种锁：只改 x / 只改 y
        let onlyX = CurveEditor.movedPoint(CurvePoint(0.5, 0.9), index: 1, in: start,
                                           from: start[1], lock: .x)
        XCTAssertEqual(onlyX, CurvePoint(0.5, 0.2), "⇧ 横向：只改 x，y 留在按下时的值")
        let onlyY = CurveEditor.movedPoint(CurvePoint(0.5, 0.9), index: 1, in: start,
                                           from: start[1], lock: .y)
        XCTAssertEqual(onlyY, CurvePoint(0.3, 0.9), "⇧ 纵向：只改 y")

        // (g) 通过面板实际写两次：第一次把 index 1 顶到 0.001，第二次的 index 2 于是贴着**新的**
        //     左邻（0.001）停在 0.002 —— 夹取永远对着文档里现在的邻点，所以不会越过它。
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = start }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        model.drag(index: 1, to: CurvePoint(-5, 0.4), from: start[1], lock: .free)
        var written = session.edit.curve.white
        XCTAssertTrue(CurveEditor.isOrdered(written), "写回后必须严格递增：\(written)")
        XCTAssertEqual(written[1].x, 0.001, accuracy: 1e-12, "左邻是端点 0 → 0 + 1e-3")
        XCTAssertEqual(written[0].x, 0, accuracy: 1e-12, "端点不动")

        model.drag(index: 2, to: CurvePoint(-5, 0.9), from: start[2], lock: .free)
        written = session.edit.curve.white
        XCTAssertTrue(CurveEditor.isOrdered(written), "写回后必须严格递增：\(written)")
        XCTAssertEqual(written[2].x, 0.001 + CurveEditor.minimumGap, accuracy: 1e-12,
                       "贴着**当前**左邻 0.001 → 0.002")
        XCTAssertEqual(written[3].x, 1, accuracy: 1e-12)

        // **反证**: the same write without the clamp is out of order — this is what (g) guards.
        var naive = start
        naive[1] = CurvePoint(-5, 0.4)
        XCTAssertFalse(CurveEditor.isOrdered(naive),
                       "不夹取就是乱序 —— 夹取这一条断言因此不是空的")

        print("clamp · 左邻端点 −5 → \(String(format: "%.4f", written[1].x))；"
              + "再拖 index 2 → \(String(format: "%.4f", written[2].x))（贴 0.001）· "
              + "不夹取 → \(naive.map(\.x)) 乱序")
    }

    // MARK: - 4. delete, and the endpoints that refuse

    /// 双击内部的点 → 删掉，一条历史；双击两个端点 → 点数不变、没有历史、不报错。
    func testDoubleClickDeletesAnInteriorPointAndTheEndpointsRefuseSilently() {
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)] }
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

        let red = CurveEditorModel(session: session, channel: .red)
        XCTAssertNotNil(red.insert(atU: 0.4), "R 通道插入一个点")
        XCTAssertNotNil(red.insert(atU: 0.7))

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
        session.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1, 1)] }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 1)
        XCTAssertEqual(origin, CurvePoint(0.5, 0.5))
        for step in 1...10 {
            model.drag(index: 1,
                       to: CurvePoint(0.5 + 0.02 * Double(step), 0.5 + 0.03 * Double(step)),
                       from: origin!, lock: .free)
            XCTAssertEqual(session.history.count, base, "拖动过程不写历史（step \(step)）")
        }
        XCTAssertEqual(session.edit.curve.white[1].x, 0.7, accuracy: 1e-9, "中间态已经写进文档")
        XCTAssertTrue(model.endDrag(), "抬起 = 一条快照")
        XCTAssertEqual(session.history.count, base + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "曲线")

        // 反证：每个 tick 都 commit 的那条路
        let noisy = CatalogSession()
        noisy.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1, 1)] }
        noisy.commitEdit(label: "起点")
        let noisyBase = noisy.history.count
        for step in 1...10 {
            noisy.applyEdit { $0.curve.white[1] = CurvePoint(0.5 + 0.02 * Double(step), 0.5) }
            noisy.commitEdit(label: "曲线")
        }
        XCTAssertEqual(noisy.history.count - noisyBase, 10,
                       "每个 tick 提交一次就是 10 条 —— 这条断言让上一条有意义")

        // ⌘Z 一步回到拖动前
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.curve.white[1], CurvePoint(0.5, 0.5))

        print("drag · shipped \(base + 1 - base) 条（10 步）· per-tick 10 条 · ⌘Z → "
              + "\(session.edit.curve.white[1])")
    }

    // MARK: - 7. reset

    /// `复位本通道` 只清那一个；`全部复位` / 双击标题 → 四张表全回恒等，
    /// `CurveLUT.isIdentity == true`（渲染走 copy 分支），且每条都是一次历史。
    func testResetChannelClearsOnlyThatChannelAndResetAllReturnsTheIdentityBytes() {
        let session = CatalogSession()
        session.applyEdit { model in
            model.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.62), CurvePoint(1, 1)]
            model.curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.4), CurvePoint(1, 1)]
            model.curve.green = [CurvePoint(0, 0), CurvePoint(0.5, 0.55), CurvePoint(1, 1)]
            model.curve.blue = [CurvePoint(0, 0), CurvePoint(0.5, 0.45), CurvePoint(1, 1)]
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
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.25, 0.35), CurvePoint(0.6, 0.62),
                              CurvePoint(1, 0.95)]
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
        session.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.5, 0.45), CurvePoint(1, 1)] }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 0)
        XCTAssertEqual(origin, CurvePoint(0, 0))
        XCTAssertTrue(model.drag(index: 0, to: CurvePoint(0.2, 0), from: origin!, lock: .free))
        XCTAssertEqual(session.edit.curve.white[0].x, 0.2, accuracy: 1e-12, "右移首点 = 抬黑点")
        XCTAssertEqual(session.edit.curve.white[0].y, 0, accuracy: 1e-12, "y 不动")
        XCTAssertEqual(session.history.count, base, "拖动中不写历史")
        XCTAssertTrue(model.endDrag())
        XCTAssertEqual(session.history.count, base + 1, "一次拖动 = 一条历史")
        XCTAssertTrue(CurveEditor.isOrdered(session.edit.curve.white), "x 仍严格递增")

        let t = model.preview
        XCTAssertEqual(t, CurveLUT.buildOne(model.points), "预览仍是引擎那张表")

        // u < 0.2 的 100 个抽样（4096 点的表上 u = 0.2 大约落在第 819 个采样）
        let ids = (0..<100).map { Int((0.2 * Double($0) / 100 * Double(CurveLUT.size - 1)).rounded()) }
        let below = Set(ids.map { t[$0] })
        XCTAssertEqual(below.count, 1, "u < 0.2 必须全部相等，实际 \(below.sorted())")
        XCTAssertEqual(ids.map { t[$0] }.max() ?? -1, 0, accuracy: 1e-7, "first.y = 0 → 裁到 0")

        // …而且不是整张表都平了：0.2 之上仍在上升，整表单调不减
        XCTAssertGreaterThan(t[Int(0.35 * Double(CurveLUT.size - 1))], 0.05, "0.2 之上必须还在上升")
        for i in 1..<t.count {
            XCTAssertGreaterThanOrEqual(t[i], t[i - 1], "端点右移后表在第 \(i) 个采样折回")
        }

        // **反证**：051 的夹取（首点恒 0）用同一个拖动目标重建 → 同样 100 个采样点各不相同
        let pinned = CurveLUT.buildOne([CurvePoint(0, 0), CurvePoint(0.5, 0.45), CurvePoint(1, 1)])
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

        print("black point · first.x 0 → \(session.edit.curve.white[0].x)（复位后）· "
              + "u<0.2 的 100 点：搬过去 \(below.count) 个值，钉死则 "
              + "\(Set(pinnedBelow).count) 个值（跨度 \(String(format: "%.3f", (pinnedBelow.max() ?? 0) - (pinnedBelow.min() ?? 0))))")
    }

    /// 061 ②：把**末端点左移到 u = 0.8** —— `u > 0.8` 全部同一个输出（白点裁切），最后一段斜率 0，
    /// 所以 +4 EV 之上也停在那里；表仍单调，一次拖动一条历史。
    func testMovingTheLastEndpointLeftClipsTheHighlightsToOneValue() {
        let start = [CurvePoint(0, 0), CurvePoint(0.5, 0.5), CurvePoint(1, 1)]
        let session = CatalogSession()
        session.applyEdit { $0.curve.white = start }
        session.commitEdit(label: "起点")
        let model = CurveEditorModel(session: session, channel: .white)
        let base = session.history.count

        let origin = model.beginDrag(at: 2)
        XCTAssertTrue(model.drag(index: 2, to: CurvePoint(0.8, 0.9), from: origin!, lock: .free))
        XCTAssertEqual(session.edit.curve.white[2].x, 0.8, accuracy: 1e-12, "左移末点 = 降白点")
        XCTAssertEqual(session.edit.curve.white[2].y, 0.9, accuracy: 1e-10)
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
        XCTAssertEqual(ids.map { t[$0] }.max() ?? -1, 0.9, accuracy: 1e-6, "last.y = 0.9")
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
        let atZero = CurveLUT.buildOne([CurvePoint(0, 0.4), CurvePoint(1, 1)])
        let zeroSlope = CurveLUT.slope(of: atZero)
        for x in [-0.039, -0.004, -1e-9, 0.0] {
            XCTAssertEqual(HDRCurve.channel(x, table: atZero, slope: zeroSlope, blackPoint: 0), x,
                           "first.x == 0：\(x) 必须原样穿过（018 的符号保真）")
        }

        let raised = CurveLUT.buildOne([CurvePoint(0.2, 0.3), CurvePoint(1, 1)])
        let raisedSlope = CurveLUT.slope(of: raised)
        let clip = HDRCurve.channel(0, table: raised, slope: raisedSlope, blackPoint: 0.2)
        XCTAssertGreaterThan(clip, 1e-3, "first.y = 0.3 → 裁到的常量是 0.3 对应的线性值")
        for x in [-0.039, -0.004, -1e-9, 0.0, 1e-5, 1e-4, 5e-4] {
            XCTAssertEqual(HDRCurve.channel(x, table: raised, slope: raisedSlope, blackPoint: 0.2),
                           clip, accuracy: 1e-12, "\(x) 必须与 u = 0 的常量相等（裁切没有洞）")
        }
        XCTAssertNotEqual(HDRCurve.channel(-0.039, table: raised, slope: raisedSlope, blackPoint: 0),
                          clip, "反证：按 first.x == 0 走同一条负值会穿过去 —— 两条路必须不同")

        // 表自己的那一半：u < 0.2 是常量（与 HDRCurve 的 u = 0 项同一个数）
        let ids = (0..<100).map { Int((0.2 * Double($0) / 100 * Double(CurveLUT.size - 1)).rounded()) }
        XCTAssertEqual(Set(ids.map { raised[$0] }).count, 1)
        XCTAssertEqual(Double(raised[0]), 0.3, accuracy: 1e-6)
        XCTAssertEqual(HDRCurve.axis.inverse(Double(raised[0])), clip, accuracy: 1e-12)

        print("sub-black · first.x=0 → 直通；first.x=0.2 → 常量 "
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
            $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.2, 0.3), CurvePoint(0.55, 0.5),
                              CurvePoint(0.8, 0.9), CurvePoint(1, 1)]
            $0.curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.4), CurvePoint(1, 1)]
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

        XCTAssertEqual(titles.filter { $0 != "曲线" },
                       ["直方图", "白平衡", "Light", "Color", "细节", "预设", "蒙版", "Decode"],
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

        // 047 的四张参数卡清单没有被曲线改写：Group 还是那四个。
        XCTAssertEqual(PanelResets.Group.allCases.map(\.rawValue),
                       ["whiteBalance", "light", "color", "detail"])
        print("layout · \(titles) · 曲线 index \(detail + 1)")
    }

    // MARK: - helpers

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
