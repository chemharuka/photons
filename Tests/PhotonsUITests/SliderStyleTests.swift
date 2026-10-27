import XCTest
import SwiftUI
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 派单 046 + 055 —— 滑杆样式规则：
///
///  1. **结构**：解码参数（细节卡的降噪 / 色彩降噪 / 细节 / 锐化、白平衡的色温 / 色调）画 `.bar`；
///     渲染参数（Light 的六行、Color 的两行）画 `.knob`。断言打在**卡片迭代的那张表**上，不是打在
///     截图或无障碍树上 —— 后者在 `swift test` 里没有窗口会话时是空的（同 `DetailSectionTests`）。
///  2. **同一个控件**（055）：`.bar` 与 `.knob` 底层都是 `NSSlider`。055 之前 `.bar` 是自绘的
///     `Canvas` + `DragGesture`，于是两者的焦点、拖动手感、无障碍都是两套，而且为了键盘它调了
///     `.focusable()`，macOS 就在点击时画系统焦点环（用户看到的那圈蓝框）。
///  3. **只换拖动点**：`.bar` 的 cell 只重写拖动点的绘制 —— 10 × 16 pt、圆角 5 pt 的胶囊；轨道和
///     已选部分仍是系统的。行高两种形状都是 16 pt。
///  4. **无刻度 / 无焦点环 / 一次拖动一条历史 / 两端可达**：四条都按能抓住的实物断言（控件实例、
///     cell 记录下来的绘制矩形、`onEditingChanged` 的调用序列）。
@MainActor
final class SliderStyleTests: XCTestCase {

    // MARK: - 1. 结构：哪类参数拿哪种形状

    func testDecoderParametersDrawTheBarAndRenderParametersTheKnob() {
        // 解码参数：细节卡的四行 —— 每一行都是 `.bar`。
        let detail = InspectorView.detailContent.rows
        XCTAssertEqual(detail.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"])
        XCTAssertEqual(detail.map(\.shape), [.bar, .bar, .bar, .bar],
                       "046: 会触发重新 develop 的四根滑杆必须是长条形")
        XCTAssertEqual(detail.map(\.axis), DetailAxis.panelOrder,
                       "the four rows are the four decode axes, in panel order")

        // 渲染参数：Light 的六行 —— 每一行都是 `.knob`。
        let light = InspectorView.lightRows
        XCTAssertEqual(light.map(\.title), ["曝光", "对比", "高光", "阴影", "白色", "黑色"])
        XCTAssertEqual(light.map(\.shape), Array(repeating: .knob, count: 6),
                       "046: 解 RAW 之后的六根滑杆必须保持圆形")

        // 两张表是不相交的两类参数：没有一行同时出现在两边。
        XCTAssertTrue(Set(detail.map(\.title)).isDisjoint(with: Set(light.map(\.title))),
                      "a parameter is either a decoder one or a render one, never both")

        // 形状只有这两种，而且都有名字（UI/日志/测试共用一处）。
        XCTAssertEqual(SliderShape.allCases.map(\.rawValue), ["bar", "knob"])
        print("SLIDER shapes · detail \(detail.map { "\($0.title)=\($0.shape.rawValue)" })"
              + " · light \(light.map { "\($0.title)=\($0.shape.rawValue)" })")
    }

    /// The card the panel actually builds is the table above: the 细节 card passes `row.shape` and the
    /// Light card passes `row.shape`, so a `.bar` in the table is a `.bar` on screen. Pinned on the
    /// source because `sliderRow` is `private` (the same technique `InspectorPinnedHeaderTests` uses
    /// for the 信息 title).
    ///
    /// 色温/色调 也会写进 `CIRAWFilter`（= 重新解码），所以按 046 的规则它们也是长条形。
    /// **055 改了这里的两条断言**：长条形滑杆的构造器从 `BarSlider(` 换成 `BubbleSlider(` ——
    /// 控件换了（自绘 → `NSSlider`），而「白平衡两行必须是长条形、不许留圆球」这条规则没变。
    func testWhiteBalanceRowsDrawTheBarToo() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        guard let start = source.range(of: "private func whiteBalanceRow"),
              let end = source.range(of: "private var dropperRow") else {
            return XCTFail("whiteBalanceRow and dropperRow must both exist")
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("BubbleSlider("),
                      "色温/色调 are decode parameters: they must be the long bar, not the ball")
        // `BubbleSlider(value:` trivially contains `Slider(value:` — the lookbehind is the whole point.
        let roundSlider = try NSRegularExpression(pattern: "(?<!Bubble)Slider\\(value:",
                                                  options: [.dotMatchesLineSeparators])
        XCTAssertEqual(roundSlider.numberOfMatches(in: body,
                                                   range: NSRange(body.startIndex..., in: body)),
                       0, "no round slider may be left in the white-balance rows")
    }

    /// **055 改了这里的断言**：`sliderRow` 的 `.bar` 分支现在画的是 `BubbleSlider`（同一条
    /// `onEditingChanged`、同一个 `range`），`.knob` 仍是 `step`-free 的 SwiftUI `Slider` ——
    /// 两者名字不同但底层同类，这正是验收 1 的「同一个类」。
    func testBothCardsPassTheirRowShapeToTheOneRowBuilder() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("shape: row.shape"),
                      "a card must pass its row's shape to sliderRow, not a literal")
        XCTAssertTrue(source.contains("BubbleSlider(value: value, range: range"),
                      "sliderRow must draw BubbleSlider for .bar")
        XCTAssertTrue(source.contains("Slider(value: value, in: range, onEditingChanged:"),
                      "sliderRow must draw the step-free SwiftUI Slider for .knob")

        // 细节卡的 shape 来自它的表，Light 卡来自 `lightRows`。
        XCTAssertTrue(source.contains("ForEach(Self.detailContent.rows"),
                      "the 细节 card iterates the table this test asserts on")
        XCTAssertTrue(source.contains("ForEach(Self.lightRows"),
                      "the Light card iterates the table this test asserts on")
    }

    // MARK: - 2. 同一个控件（055 验收 1）

    /// `.bar` 必须是一个真正的 AppKit 控件：`NSSlider` + `NSSliderCell`。
    ///
    /// **实测推翻了一条规格假设**（写在这里，因为它决定了这条断言怎么写）：macOS 27 上 SwiftUI 的
    /// `Slider` **不再**是 `NSSlider` —— 把一只 `Slider` 放进 `NSHostingView`、开着键窗跑起来，
    /// 子视图树里只有 `KeyViewProxy` 和 `_FocusRingView`，一个 `NSSlider` 都没有（`Slider` 自己画）。
    /// 所以「两者的控件的 className 一个是 `NSSlider` 另一个不是」这种断言在本机**不会**红，
    /// 也就不能用来钉「同一个类」。能钉、也确实管用的是这条：`.bar` 从「自绘 `Canvas` + `DragGesture`」
    /// 变成了平台控件 `NSSlider` —— 焦点环可关、键盘/无障碍归 AppKit。这正是蓝框消失的原因。
    ///
    /// 下面顺带把「SwiftUI 那边是自绘」这件事**钉成一条会红的观察**：哪天 Apple 把 `Slider` 换回
    /// `NSSlider` 底，这条会红，届时应把断言收紧成两者都 `isKind(of: NSSlider.self)`。
    func testTheBarIsANativeSliderAndTheKnobIsNot() {
        let bar = Self.firstSlider(BubbleSlider(value: .constant(30), range: DetailSettings.range))
        guard let bar else { return XCTFail("the .bar shape must put a control on screen") }
        XCTAssertTrue(bar.isKind(of: NSSlider.self),
                      "055: .bar 必须是 NSSlider（不是自绘视图），与其它滑杆同一类控件")
        XCTAssertTrue(bar is BubbleSliderControl, "…and it is our subclass, so the cell is ours")
        XCTAssertTrue(bar.cell is NSSliderCell, "the bar draws through a real NSSliderCell")

        // `.knob`：SwiftUI 的 Slider —— 在本机是 SwiftUI 自绘（见上面的冻结观察）。
        let knobTree = Self.classNames(Self.hosted(Slider(value: .constant(30), in: DetailSettings.range) { _ in }
            .controlSize(.mini)))
        let knobIsNSViewSlider = knobTree.contains { $0.contains("NSSlider") }
        print("SLIDER controls · bar \(NSStringFromClass(type(of: bar)))"
              + " · cell \(NSStringFromClass(type(of: bar.cell!)))"
              + " · knob tree \(knobTree)")
        XCTAssertFalse(knobIsNSViewSlider,
                       "macOS 27 的 SwiftUI Slider 是自绘的（子视图树里没有 NSSlider）。"
                       + "这条红说明 Apple 换回了 NSSlider 底：请把 055 的「同一个类」断言收紧为"
                       + "两者都 isKind(of: NSSlider.self)。")
    }

    // MARK: - 3. 点击不出焦点环（055 验收 2）

    /// `focusRingType == .none`，控件与 cell 都断言；而且源码里没有自绘焦点高亮。
    ///
    /// 反证写在同一个测试里：一只**系统**的 `NSSlider` 默认不是 `.none`（它画环），所以
    /// 「有人把 `focusRingType` 设回 `.default` 就得红」这件事不是空话。
    func testTheBubbleSliderHasNoFocusRing() throws {
        let control = Self.firstSlider(BubbleSlider(value: .constant(30), range: DetailSettings.range))
        guard let control else { return XCTFail("no control") }
        XCTAssertEqual(control.focusRingType, NSFocusRingType.none,
                       "055: 点击解码参数滑杆不许出蓝色焦点框")
        // `.none` on an Optional would resolve to `Optional.none` (nil) instead of the ring type, so
        // the enum is spelled out: the cell is the thing that actually draws the ring.
        XCTAssertEqual(control.cell?.focusRingType, NSFocusRingType.none,
                       "the ring is drawn by the cell: it must opt out too")

        // 负对照：系统的滑杆默认是画环的。把上面两条改成 `.default` 时，这一条仍然成立而上面会红。
        let stock = NSSlider(value: 30, minValue: 0, maxValue: 100, target: nil, action: nil)
        XCTAssertNotEqual(stock.focusRingType, NSFocusRingType.none,
                          "a stock NSSlider does draw a focus ring — ours has to opt out explicitly")
        // NSFocusRingType: .default == 0, .none == 1 — printed so the numbers in the report are checkable.
        print("SLIDER focus ring · bar \(control.focusRingType.rawValue) (\(control.focusRingType == .none ? "none" : "default"))"
              + " / cell \(control.cell!.focusRingType.rawValue)"
              + " · stock \(stock.focusRingType.rawValue) (default)")

        // 也没有自绘的焦点高亮：只关掉系统环、再自己画一圈蓝，等于没修。
        let source = try String(contentsOf: Self.bubbleSliderSource, encoding: .utf8)
        for forbidden in ["drawFocusRing", "focusRingMask", "keyboardFocusIndicator",
                          "showFocusRing", "focusRingType = .default"] {
            XCTAssertFalse(source.contains(forbidden),
                           "BubbleSlider must not draw its own focus highlight (\(forbidden))")
        }
        // 键盘仍然要能进：不可聚焦就没有 ←/→。
        XCTAssertFalse(control.refusesFirstResponder)
        XCTAssertTrue(control.acceptsFirstResponder)
    }

    // MARK: - 4. 拖动点：10 × 16 的圆角气泡（055 验收 3）

    /// 气泡尺寸/圆角，以及 cell **实际画出来的**那个矩形（不是「打算画」的常量）。
    func testTheKnobIsATenBySixteenCapsule() {
        XCTAssertEqual(BubbleSliderCell.knobSize, CGSize(width: 10, height: 16),
                       "055: 拖动点是宽 10 pt × 高 16 pt 的圆角长方形")
        XCTAssertEqual(BubbleSliderCell.knobCornerRadius, 5)
        XCTAssertEqual(BubbleSliderCell.knobCornerRadius, BubbleSliderCell.knobSize.width / 2,
                       "radius = half the width → the two ends are semicircles (a capsule)")
        XCTAssertEqual(BubbleSliderCell.knobSize.height, SliderValueMap.rowHeight,
                       "the bubble is exactly the 16 pt row high")

        let control = Self.firstSlider(BubbleSlider(value: .constant(30), range: DetailSettings.range))
        guard let control, let cell = control.cell as? BubbleSliderCell else {
            return XCTFail("the .bar control must install BubbleSliderCell")
        }
        Self.render(control)
        if cell.drawCount == 0 { cell.drawKnob(cell.knobRect(flipped: false)) }   // 兜底，见下
        XCTAssertGreaterThan(cell.drawCount, 0, "the cell never painted the knob")
        guard let drawn = cell.drawnKnobRect else { return XCTFail("no recorded knob rect") }
        XCTAssertEqual(drawn.size, CGSize(width: 10, height: 16),
                       "the painted rect is the bubble, not AppKit's round knob")
        XCTAssertEqual(drawn.height, control.bounds.height, accuracy: 0.5,
                       "the bubble spans the row's height")
        print(String(format: "SLIDER knob · drawn (%.1f, %.1f, %.1f, %.1f) · radius %.1f",
                     drawn.minX, drawn.minY, drawn.width, drawn.height,
                     BubbleSliderCell.knobCornerRadius))
    }

    // MARK: - 5. 无刻度（055 验收 5）

    /// `step:` 是 SwiftUI 画刻度线的唯一开关，所以源码里一处都不许有 —— 无论给长条还是圆球；
    /// `NSSlider` 那边则是 `numberOfTickMarks == 0`（默认值，没人去设就更没人能设错）。
    ///
    /// **055 删掉了旧断言 `XCTAssertFalse(bar.contains("Slider("))`**：那条的前提是「长条是自绘的，
    /// 里面不许有 SwiftUI Slider」。现在长条**就是** `NSSlider`，那句话已经反过来成了要求；换成了
    /// 「没有 `step:`、`numberOfTickMarks` 是 0、cell 不画刻度」三条。
    func testNoSliderIsGivenAStepSoNothingDrawsTicks() throws {
        let inspector = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        let bubble = try String(contentsOf: Self.bubbleSliderSource, encoding: .utf8)

        // Any `Slider(` whose argument list carries `step:` — the thing that draws ticks.
        let tickedSlider = try NSRegularExpression(pattern: "Slider\\([^)]*step:",
                                                   options: [.dotMatchesLineSeparators])
        let inspectorRange = NSRange(inspector.startIndex..., in: inspector)
        XCTAssertEqual(tickedSlider.numberOfMatches(in: inspector, range: inspectorRange), 0,
                       "a `Slider(... step:)` draws tick marks; 046 forbids them on every slider")
        let bubbleRange = NSRange(bubble.startIndex..., in: bubble)
        XCTAssertEqual(tickedSlider.numberOfMatches(in: bubble, range: bubbleRange), 0,
                       "BubbleSlider must not hand a `step:` to anything either")
        XCTAssertFalse(bubble.contains("drawTickMarks"),
                       "the cell draws no tick marks of its own")

        // 圆球那条路只有 `step`-free 的重载，且 `sliderRow` 不再收 `step` 参数（编译期就挡住）。
        XCTAssertFalse(inspector.contains("step: Double? = nil"),
                       "sliderRow must not accept a step: any caller could turn the ticks back on")
        XCTAssertFalse(inspector.contains("row.step,"),
                       "DetailCardContent.Row.step is the model's quantization, never a Slider's")

        // 实物：两条控制都没有刻度。
        let barControl = Self.firstSlider(BubbleSlider(value: .constant(30), range: DetailSettings.range))
        XCTAssertEqual(barControl?.numberOfTickMarks, 0, "055: 解码参数的滑杆不许有刻度")
        XCTAssertEqual((barControl?.cell as? NSSliderCell)?.numberOfTickMarks, 0, "…cell 也不许有")
        // `.knob` 那条没有 AppKit 实例可问（macOS 27 的 SwiftUI Slider 是自绘的），它的「无刻度」
        // 由上面那条源码正则钉住：没有人给 `Slider(...)` 传 `step:`，就没有人能画出刻度。

        // 步进只活在模型层：一个单位（`DetailSettings.step`），只在 `setPosition` 里四舍五入。
        var settings = DetailSettings.identity
        settings.setPosition(50.4, .luminanceNR, in: .measured)
        XCTAssertEqual(settings.luminanceNR, 50, "50.4 quantizes to a whole slider unit")
        XCTAssertEqual(DetailSettings.step, 1)
    }

    // MARK: - 6. 一次拖动一条历史（055 验收 4）

    /// 一次拖动 = 一次 `onEditingChanged(true)` + 一次 `(false)`，不是每一跳一次
    /// （那样一次拖动会变成几十个 undo 快照）。
    ///
    /// 走 cell 的 `startTracking` / `continueTracking` / `stopTracking`：这是 AppKit 真实拖动的顺序，
    /// 也是唯一能在没有键窗的 `swift test` 里跑的做法（`mouseDown` 会开同步跟踪循环，测试里不能调）。
    /// 控件自己还会在 `mouseDown` 前后各报一次 —— 那对方法带幂等守卫，所以两条路同时走也还是一条。
    func testOneDragIsOneHistoryEntry() {
        let box = Self.Box(value: 30)
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let events = Self.Recorder()
        let control = Self.firstBubbleControl(BubbleSlider(value: binding,
                                                           range: DetailSettings.range,
                                                           onEditingChanged: { events.calls.append($0) }))
        guard let control, let cell = control.cell as? BubbleSliderCell else {
            return XCTFail("no control/cell")
        }
        XCTAssertTrue(events.calls.isEmpty, "nothing is committed before the mouse goes down")

        // 按下在中间，拖到最左端，抬起。
        _ = cell.startTracking(at: NSPoint(x: control.bounds.midX, y: control.bounds.midY), in: control)
        for x in stride(from: control.bounds.midX, through: -400, by: -40) {
            _ = cell.continueTracking(last: NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                                      current: NSPoint(x: x, y: control.bounds.midY), in: control)
        }
        cell.stopTracking(last: NSPoint(x: 0, y: control.bounds.midY),
                          current: NSPoint(x: -400, y: control.bounds.midY),
                          in: control, mouseIsUp: true)

        XCTAssertEqual(events.calls, [true, false],
                       "one drag must be exactly one press and one release, not one per jump")
        XCTAssertEqual(control.editingBeganCount, 1)
        XCTAssertEqual(control.editingEndedCount, 1)
        XCTAssertFalse(control.isEditingSession, "the editing session is closed after the drag")

        // 两端可达：拖到控件外也落在 range 的端点上（容差 1e-9），并且真的写进了 binding。
        XCTAssertEqual(control.doubleValue, DetailSettings.range.lowerBound, accuracy: 1e-9,
                       "dragged past the left end → the low end of the range")
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(box.value, DetailSettings.range.lowerBound, accuracy: 1e-9,
                       "the action writes the binding the panel previews from")

        // 再拖到最右端。
        events.calls.removeAll()
        _ = cell.startTracking(at: NSPoint(x: 0, y: control.bounds.midY), in: control)
        _ = cell.continueTracking(last: NSPoint(x: 0, y: control.bounds.midY),
                                  current: NSPoint(x: control.bounds.maxX + 400, y: control.bounds.midY),
                                  in: control)
        cell.stopTracking(last: NSPoint(x: control.bounds.maxX, y: control.bounds.midY),
                          current: NSPoint(x: control.bounds.maxX + 400, y: control.bounds.midY),
                          in: control, mouseIsUp: true)
        XCTAssertEqual(events.calls, [true, false], "the second drag is its own single entry")
        XCTAssertEqual(control.doubleValue, DetailSettings.range.upperBound, accuracy: 1e-9,
                       "dragged past the right end → the high end of the range")
        control.sendAction(control.action, to: control.target)
        XCTAssertEqual(box.value, DetailSettings.range.upperBound, accuracy: 1e-9)

        // 真实的一次鼠标拖动会**同时**走两条路：`mouseDown` 在同步跟踪循环前后各报一次，循环里 cell
        // 的 start/stopTracking 也各报一次。下面按这个确切顺序回放一遍 —— 幂等守卫必须让它仍然只有一对，
        // 否则一次拖动会变成两条历史。
        events.calls.removeAll()
        control.beginEditing()                                   // mouseDown, before super
        _ = cell.startTracking(at: NSPoint(x: control.bounds.midX, y: control.bounds.midY), in: control)
        _ = cell.continueTracking(last: NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                                  current: NSPoint(x: control.bounds.midX / 2, y: control.bounds.midY),
                                  in: control)
        cell.stopTracking(last: NSPoint(x: control.bounds.midX, y: control.bounds.midY),
                          current: NSPoint(x: control.bounds.midX / 2, y: control.bounds.midY),
                          in: control, mouseIsUp: true)
        control.endEditing()                                     // mouseDown, after super
        XCTAssertEqual(events.calls, [true, false],
                       "both routes fire in one drag — the guard must keep it one press and one release")

        print("SLIDER history · last drag → \(events.calls) · value \(box.value)"
              + " · range \(DetailSettings.range) · sessions sealed \(control.editingBeganCount)"
              + "/\(control.editingEndedCount)")
    }

    // MARK: - 7. 键盘：一步 = 细节的一个单位

    /// 046 的规则：键盘一步 = 行程的 1%。细节的行程是 0…100，所以一步就是模型量化的那 1 个单位。
    ///
    /// 055 之后 ←/→ 由 `NSSlider` 原生处理，这里不另写按键逻辑 —— 所以除了常量本身，还断言
    /// `BubbleSlider.swift` 里**没有**自己的按键处理（有的话就成了两套步进）。
    func testKeyboardStepsByOneDetailUnit() throws {
        let range = DetailSettings.range
        let step = SliderValueMap.keyboardStep(in: range)
        XCTAssertEqual(step, DetailSettings.step,
                       "the keyboard step and the model's quantization must be the same amount")

        XCTAssertEqual(SliderValueMap.nudged(50, by: step, in: range), 51)
        XCTAssertEqual(SliderValueMap.nudged(50, by: -step, in: range), 49)
        XCTAssertEqual(SliderValueMap.nudged(0, by: -step, in: range), 0, "no wrap-around at the ends")
        XCTAssertEqual(SliderValueMap.nudged(100, by: step, in: range), 100)

        // 键盘一步在文档里的效果：50 → 51，一个 `setPosition` 就够，一个快照。
        var settings = DetailSettings.identity
        settings.setPosition(SliderValueMap.nudged(50, by: step, in: range), .colorNR, in: .measured)
        XCTAssertEqual(settings.colorNR, 51)
        // 回到默认位置写回 nil（双击复位与滑回默认位置是同一条规则）。
        settings.setPosition(50, .colorNR, in: .measured)
        XCTAssertNil(settings.colorNR)

        // 没有第二套按键处理：←/→ 归 AppKit。
        let source = try String(contentsOf: Self.bubbleSliderSource, encoding: .utf8)
        for forbidden in ["onKeyPress", "keyDown(with", "NSEvent.keyEvent", "charactersIgnoringModifiers"] {
            XCTAssertFalse(source.contains(forbidden),
                           "BubbleSlider must leave the arrow keys to NSSlider (\(forbidden))")
        }
    }

    // MARK: - 8. 不跳版式

    /// 两种形状的行高都是 16 pt —— 卡片高度不随形状变，切换 `shape:` 时面板不跳。
    ///
    /// **055 改了这里的两条断言**：旧的两条量的是自绘把手（`handleHeight == 14`、`< rowHeight`）。
    /// 气泡是 16 pt 高（正好等于行高），所以改成量气泡与行高的关系。
    func testBothShapesKeepTheSameRowHeight() {
        XCTAssertEqual(SliderValueMap.rowHeight, 16, "046 要求行高固定 16 pt")
        XCTAssertEqual(BubbleSliderCell.knobSize.height, SliderValueMap.rowHeight,
                       "the bubble is 16 pt tall, like the row")
        XCTAssertLessThan(BubbleSliderCell.knobSize.width, SliderValueMap.rowHeight,
                          "10 pt wide — a bubble, not a bar")

        // The panel wraps both shapes in `.frame(height: SliderValueMap.rowHeight)`; measured the same
        // way here so the row height is compared like for like.
        let bar = Self.fittingHeight(BubbleSlider(value: .constant(30), range: DetailSettings.range)
            .frame(height: SliderValueMap.rowHeight))
        let knob = Self.fittingHeight(Slider(value: .constant(30), in: DetailSettings.range) { _ in }
            .controlSize(.mini)
            .frame(height: SliderValueMap.rowHeight))
        // 055: `BubbleSlider` reports 16 pt by itself (`sizeThatFits`) — the frame is a belt, not the
        // thing that makes the bar 16 pt tall. SwiftUI's own knob is 12 pt tall, which is why the
        // panel's frame is what keeps the two rows the same height.
        let barWithoutFrame = Self.fittingHeight(BubbleSlider(value: .constant(30), range: DetailSettings.range))
        print(String(format: "SLIDER row heights · bar %.1f · knob %.1f (target %.1f)",
                     bar, knob, SliderValueMap.rowHeight))
        XCTAssertEqual(bar, knob, accuracy: 0.5, "the two shapes disagree on the row height")
        XCTAssertEqual(bar, SliderValueMap.rowHeight, accuracy: 0.5,
                       "BubbleSlider reports 16 pt on its own (sizeThatFits), without a .frame")
        XCTAssertEqual(knob, SliderValueMap.rowHeight, accuracy: 0.5)
        XCTAssertEqual(barWithoutFrame, SliderValueMap.rowHeight, accuracy: 0.5,
                       "BubbleSlider is 16 pt on its own, without the row's .frame")
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    /// 055: `BarSlider.swift` 被删了，长条形滑杆的实现（和它的 cell）现在在这个文件里。
    private static var bubbleSliderSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/BubbleSlider.swift")
    }

    /// A mutable box so a test can watch what the control writes through its binding.
    final class Box {
        var value: Double
        init(value: Double) { self.value = value }
    }

    final class Recorder {
        var calls: [Bool] = []
    }

    private static var windows: [NSWindow] = []

    /// Hosts a SwiftUI view offscreen and returns the hosting view, so the AppKit control SwiftUI made
    /// for it can be found in the subview tree. No key window and no event loop is needed for this —
    /// the same trick `LightCardTests` uses for the rendered card.
    @discardableResult
    private static func hosted<V: View>(_ view: V,
                                        width: CGFloat = 274,
                                        height: CGFloat = 60) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The first `NSSlider` SwiftUI put on screen for `view` (`.bar` → `BubbleSliderControl`,
    /// `.knob` → the `NSSlider` behind SwiftUI's `Slider`).
    private static func firstSlider<V: View>(_ view: V) -> NSSlider? {
        sliders(in: hosted(view)).first
    }

    /// The `.bar` control itself (not just "some NSSlider"): the editing bookkeeping lives on the
    /// subclass, so the drag test needs the real type.
    private static func firstBubbleControl<V: View>(_ view: V) -> BubbleSliderControl? {
        firstSlider(view) as? BubbleSliderControl
    }

    /// Every AppKit class in a hosted SwiftUI view's subtree — the evidence for "what is this control
    /// actually made of" (used by the `.knob` observation in `testTheBarIsANativeSliderAndTheKnobIsNot`).
    private static func classNames(_ view: NSView) -> [String] {
        [NSStringFromClass(type(of: view))] + view.subviews.flatMap { classNames($0) }
    }

    private static func sliders(in view: NSView) -> [NSSlider] {
        var found: [NSSlider] = view is NSSlider ? [view as! NSSlider] : []
        for sub in view.subviews { found += sliders(in: sub) }
        return found
    }

    /// Forces a draw so the cell's `drawKnob` runs (it records the rect it painted).
    /// `cacheDisplay` is what makes it a real AppKit draw rather than a call we made ourselves; if the
    /// offscreen backing store declines to draw, the caller falls back to one explicit `drawKnob`.
    private static func render(_ view: NSView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    private static func fittingHeight<V: View>(_ view: V, width: CGFloat = 274) -> CGFloat {
        hosted(view, width: width).fittingSize.height
    }
}
