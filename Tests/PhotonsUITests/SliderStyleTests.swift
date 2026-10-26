import XCTest
import SwiftUI
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 派单 046 —— 滑杆样式规则，作为一个形状的两条腿：
///
///  1. **结构**：解码参数（细节卡的降噪 / 色彩降噪 / 细节 / 锐化）画 `.bar`；渲染参数（Light 的六行）
///     画 `.knob`。断言打在**卡片迭代的那张表**上，不是打在截图或无障碍树上 —— 后者在
///     `swift test` 里没有窗口会话时是空的（同 `DetailSectionTests`）。
///  2. **无刻度**：两种形状都不许出刻度线。SwiftUI 的 `Slider` 一拿 `step:` 就画，所以这条既用正则
///     钉源码（`InspectorView.swift` 里没有任何 `Slider(... step:)`），也钉住唯一能产生步进的常量
///     （`SliderValueMap.keyboardStep`），并证明它只进到模型层（`DetailSettings.setPosition`）。
///  3. **行为等价**：同一行程里，两形状把「行程的 5% / 50% / 95%」映射到同一个值（≤1% 行程的容差）；
///     键盘一步都是细节的 1 个单位；行高都是 16 pt，切换形状面板不跳。
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
    /// 色温/色调 也会写进 `CIRAWFilter`（= 重新解码），所以按 046 的规则它们也是长条形 —— 这一条
    /// 是主线的补充，子代理按「其它全部 .knob」把它们留成了圆球。
    func testWhiteBalanceRowsDrawTheBarToo() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        guard let start = source.range(of: "private func whiteBalanceRow"),
              let end = source.range(of: "private var dropperRow") else {
            return XCTFail("whiteBalanceRow and dropperRow must both exist")
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("BarSlider("),
                      "色温/色调 are decode parameters: they must be the long bar, not the ball")
        // `BarSlider(value:` trivially contains `Slider(value:` — the lookbehind is the whole point.
        let roundSlider = try NSRegularExpression(pattern: "(?<!Bar)Slider\\(value:",
                                                  options: [.dotMatchesLineSeparators])
        XCTAssertEqual(roundSlider.numberOfMatches(in: body,
                                                   range: NSRange(body.startIndex..., in: body)),
                       0, "no round slider may be left in the white-balance rows")
    }

    func testBothCardsPassTheirRowShapeToTheOneRowBuilder() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("shape: row.shape"),
                      "a card must pass its row's shape to sliderRow, not a literal")
        XCTAssertTrue(source.contains("BarSlider(value: value, range: range"),
                      "sliderRow must draw BarSlider for .bar")
        XCTAssertTrue(source.contains("Slider(value: value, in: range, onEditingChanged:"),
                      "sliderRow must draw the step-free SwiftUI Slider for .knob")

        // 细节卡的 shape 来自它的表，Light 卡来自 `lightRows`。
        XCTAssertTrue(source.contains("ForEach(Self.detailContent.rows"),
                      "the 细节 card iterates the table this test asserts on")
        XCTAssertTrue(source.contains("ForEach(Self.lightRows"),
                      "the Light card iterates the table this test asserts on")
    }

    // MARK: - 2. 无刻度

    /// `step:` 是 SwiftUI 画刻度线的唯一开关，所以源码里一处都不许有 —— 无论给长条还是圆球。
    func testNoSliderIsGivenAStepSoNothingDrawsTicks() throws {
        let inspector = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        let bar = try String(contentsOf: Self.barSliderSource, encoding: .utf8)

        // Any `Slider(` whose argument list carries `step:` — the thing that draws ticks.
        let tickedSlider = try NSRegularExpression(pattern: "Slider\\([^)]*step:",
                                                   options: [.dotMatchesLineSeparators])
        let inspectorRange = NSRange(inspector.startIndex..., in: inspector)
        XCTAssertEqual(tickedSlider.numberOfMatches(in: inspector, range: inspectorRange), 0,
                       "a `Slider(... step:)` draws tick marks; 046 forbids them on every slider")

        // The bar is hand-drawn: it must not host a SwiftUI Slider at all.
        XCTAssertFalse(bar.contains("Slider("),
                       "BarSlider draws its own track; a Slider inside it would bring the ticks back")

        // 圆球那条路只有 `step`-free 的重载，且 `sliderRow` 不再收 `step` 参数（编译期就挡住）。
        XCTAssertFalse(inspector.contains("step: Double? = nil"),
                       "sliderRow must not accept a step: any caller could turn the ticks back on")
        XCTAssertFalse(inspector.contains("row.step,"),
                       "DetailCardContent.Row.step is the model's quantization, never a Slider's")

        // 步进只活在模型层：一个单位（`DetailSettings.step`），只在 `setPosition` 里四舍五入。
        var settings = DetailSettings.identity
        settings.setPosition(50.4, .luminanceNR, in: .measured)
        XCTAssertEqual(settings.luminanceNR, 50, "50.4 quantizes to a whole slider unit")
        XCTAssertEqual(DetailSettings.step, 1)
    }

    // MARK: - 3. 行为等价：同一行程 → 同一值

    /// 5% / 50% / 95% of the travel, both shapes.
    ///
    /// The **bar** side is measured from its own geometry (pointer x → value, and back). The **knob**
    /// side is the contract AppKit's slider implements: the thumb centre is linear in the value over
    /// its travel, with the ends clamped, so `f` of the travel *is* `lower + f·span`. Pixel-level
    /// agreement between the two is not asserted at 5 % because the handles have different widths
    /// (a 3 pt stroke vs an ~11 pt ball) — that is a visual difference, and 046 only requires equal
    /// *values* at the same point of travel.
    ///
    /// `NSSliderCell.knobRect` is printed for the record: on macOS 27 it returns the same 16×12 rect
    /// for every value (measured here), so AppKit's thumb geometry cannot be introspected and the
    /// knob's travel is taken from its documented linear mapping instead of from a fake measurement.
    func testBothShapesMapTheSameTravelToTheSameValues() {
        let width: CGFloat = 274          // the card content width at the default panel (330 − 2·12 − 2·16)
        let range = DetailSettings.range
        let span = range.upperBound - range.lowerBound
        let barInset = SliderValueMap.barInset
        let barTravel = width - 2 * barInset
        print(String(format: "SLIDER geometry · width %.1f · bar handle %.1f pt (inset %.1f, travel %.1f)"
                     + " · AppKit knobRect probe %@",
                     width, SliderValueMap.handleWidth, barInset, barTravel,
                     Self.knobRectProbe(width: width)))
        XCTAssertGreaterThan(barInset, 0)
        XCTAssertLessThanOrEqual(SliderValueMap.handleWidth, 4,
                                 "the handle is a 3 pt stroke, not a ball")

        for fraction in [0.05, 0.5, 0.95] {
            let barX = barInset + CGFloat(fraction) * barTravel
            let barValue = SliderValueMap.value(atX: barX, width: width, inset: barInset, in: range)
            let knobValue = range.lowerBound + fraction * span

            XCTAssertEqual(barValue, knobValue, accuracy: span * 0.01,
                           "at \(fraction * 100)% of the travel the two shapes disagree: "
                           + "bar \(barValue) vs knob \(knobValue)")
            print(String(format: "SLIDER @ %.0f%% of travel · bar x %.1f → %.2f · knob → %.2f · |Δ| %.3f",
                         fraction * 100, barX, barValue, knobValue, abs(barValue - knobValue)))
            // 长条自己也要真的落在那个点上，不能只是「和圆球差得不多」。
            XCTAssertEqual(barValue, SliderValueMap.value(fraction: fraction, in: range),
                           accuracy: span * 0.001,
                           "the bar's geometry must land on the model's own 5/50/95 %")
        }

        // 两端真的摸得到：拖出控件也钳在行程里，不会「差一点到 100」。
        XCTAssertEqual(SliderValueMap.value(atX: -50, width: width, inset: barInset, in: range),
                       range.lowerBound)
        XCTAssertEqual(SliderValueMap.value(atX: width + 50, width: width, inset: barInset, in: range),
                       range.upperBound)
        // 把手位置的逆映射一致（画出来的把手就在那个值上）。
        for fraction in [0.0, 0.05, 0.5, 0.95, 1.0] {
            let x = SliderValueMap.x(fraction: fraction, width: width, inset: barInset)
            let back = SliderValueMap.value(atX: x, width: width, inset: barInset, in: range)
            XCTAssertEqual(back, SliderValueMap.value(fraction: fraction, in: range), accuracy: 0.001)
        }
    }

    /// 键盘：一步 = 行程的 1%。细节的行程是 0…100，所以一步就是模型量化的那 1 个单位，两种形状都
    /// 落到同一个整数上（圆球的 `Slider` 没有 `step`，落点由 `DetailSettings.setPosition` 归整）。
    func testKeyboardStepsByOneDetailUnit() {
        let range = DetailSettings.range
        let step = SliderValueMap.keyboardStep(in: range)
        XCTAssertEqual(step, DetailSettings.step,
                       "the bar's keyboard step and the model's quantization must be the same amount")

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
    }

    // MARK: - 4. 不跳版式

    /// 两种形状的行高都是 16 pt —— 卡片高度不随形状变，切换 `shape:` 时面板不跳。
    func testBothShapesKeepTheSameRowHeight() {
        XCTAssertEqual(SliderValueMap.rowHeight, 16, "046 要求行高固定 16 pt")
        XCTAssertEqual(SliderValueMap.handleHeight, 14, "the handle is taller than the 4 pt track, not the row")
        XCTAssertLessThan(SliderValueMap.handleHeight, SliderValueMap.rowHeight)
        XCTAssertGreaterThanOrEqual(SliderValueMap.trackHeight, 4)

        let bar = Self.fittingHeight(
            BarSlider(value: .constant(30), range: DetailSettings.range)
                .frame(height: SliderValueMap.rowHeight))
        let knob = Self.fittingHeight(
            Slider(value: .constant(30), in: DetailSettings.range) { _ in }
                .controlSize(.mini)
                .frame(height: SliderValueMap.rowHeight))
        print(String(format: "SLIDER row heights · bar %.1f · knob %.1f (target %.1f)",
                     bar, knob, SliderValueMap.rowHeight))
        XCTAssertEqual(bar, knob, accuracy: 0.5, "the two shapes disagree on the row height")
        XCTAssertEqual(bar, SliderValueMap.rowHeight, accuracy: 0.5)
        XCTAssertEqual(knob, SliderValueMap.rowHeight, accuracy: 0.5)
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

    private static var barSliderSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/BarSlider.swift")
    }

    /// What AppKit reports for the knob's rect, printed as a finding rather than asserted on: on
    /// macOS 27 `NSSliderCell.knobRect(flipped:)` returns the same 16×12 rect at 0, 50 and 100, so the
    /// control's thumb geometry is not introspectable from a test — the same class of dead end as the
    /// empty accessibility tree. Status quo recorded so nobody measures a phantom.
    private static func knobRectProbe(width: CGFloat) -> String {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.controlSize = .mini
        slider.frame = NSRect(x: 0, y: 0, width: width, height: SliderValueMap.rowHeight)
        let window = NSWindow(contentRect: slider.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let container = NSView(frame: slider.frame)
        window.contentView = container
        container.addSubview(slider)
        container.layoutSubtreeIfNeeded()
        windows.append(window)

        guard let cell = slider.cell as? NSSliderCell else { return "no cell" }
        var rects: [String] = []
        for value in [0.0, 50.0, 100.0] {
            slider.doubleValue = value
            let r = cell.knobRect(flipped: false)
            rects.append(String(format: "%.0f→(x %.1f, w %.1f)", value, r.minX, r.width))
        }
        return rects.joined(separator: " ")
    }

    private static var windows: [NSWindow] = []

    private static func fittingHeight<V: View>(_ view: V, width: CGFloat = 274) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
