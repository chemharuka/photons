import SwiftUI
import AppKit

// MARK: - 046: 两种滑杆形状

/// 派单 046 —— 一个参数该拿哪种滑杆（用户规则，2026-10-27）：
///
/// > 如果这个选项是对 RAW 处理的，那么滑动条按照「细节」下的来，但不要加刻度线，用长条形的滑动条。
/// > 如果是解 RAW 后的，那么就是圆形的滑动条（Light 下的就是这样）
///
/// 所以形状是**参数类别**的属性，不是审美选择：
///
/// | 类别 | 例子 | 形状 |
/// |---|---|---|
/// | **解码参数**（会触发重新 develop，进 `DecodeInputs`） | 降噪 / 色彩降噪 / 细节 / 锐化 | `.bar` |
/// | **渲染参数**（解 RAW 之后） | 曝光 / 对比 / 高光 / 阴影 / 白色 / 黑色 / 曲线 / 蒙版量 / 色散… | `.knob` |
///
/// 以后新增参数时照这张表选：只要它会改解码缓存键（`DetailSettings.decodeComponent` 那样的东西），
/// 就是 `.bar`；只改渲染的就是 `.knob`。
///
/// **两种形状都不许画刻度线。** SwiftUI 的 `Slider` 只要拿到 `step:` 就画刻度，所以整个面板没有一处
/// 传 `step:`（`sliderRow` 连这个参数都不收）；量化在模型层做 —— `DetailSettings.setPosition` 把位置
/// 四舍五入到 1 个单位，和 `.bar` 的键盘步进是同一个量（`SliderValueMap.keyboardStep(in:)`）。
///
/// 形状是**唯一**的差异。label、数值框、双击复位、`onEditingChanged`（按下 true / 抬起 false）都由
/// `InspectorView.sliderRow` 提供，两种形状共用同一段代码，所以不会出现「长条拖不到两端」或
/// 「圆形不能输入数值」这类分叉。
public enum SliderShape: String, CaseIterable, Sendable, Equatable {
    /// 解码参数：4 pt 胶囊轨道 + 已选部分填充 + 3×14 细把手。没有圆球，没有刻度。
    case bar
    /// 渲染参数：系统圆形滑块（SwiftUI `Slider`，`step: nil`）。
    case knob
}

// MARK: - 几何与数值映射

/// 一根滑杆的几何与「像素 ↔ 值」映射，从视图里拿出来是为了能被测试直接抓住。
///
/// 两种形状用**同一个比例**：把指针放在「行程」的 f 处（把手中心从 `inset` 走到 `width − inset`），
/// 得到的值都是 `lower + f · span`。所以同一个 f 处两形状的差是 0，而不是「允许的一点误差」——
/// 差别只在 `inset`（长条是半个把手 1.5 pt，AppKit 圆球是半个球），那是视觉上的，不是数值上的。
public enum SliderValueMap {

    /// 滑杆行的固定高度。两种形状都钉这个高度，切换形状时面板不跳版式（046 要求 4）。
    public static let rowHeight: CGFloat = 16
    /// 长条轨道的高度。
    public static let trackHeight: CGFloat = 4
    /// 细把手：宽 3 pt、高 14 pt、圆角 1.5 pt。
    public static let handleWidth: CGFloat = 3
    public static let handleHeight: CGFloat = 14
    public static let handleCornerRadius: CGFloat = 1.5

    /// 长条这端的可用行程从半个把手开始 —— 把手中心不越过轨道端点，值才真的能被拖到 0 和 100。
    public static var barInset: CGFloat { handleWidth / 2 }

    /// 键盘一步 = 行程的 1%。细节的四根滑杆行程 0…100，所以一步正好是 1 个单位，与
    /// `DetailSettings.step` 相同（`SliderStyleTests` 钉住这个等式）。
    public static func keyboardStep(in range: ClosedRange<Double>) -> Double {
        (range.upperBound - range.lowerBound) / 100
    }

    public static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 值 → 行程上的比例（0…1）。
    public static func fraction(value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((clamp(value, range) - range.lowerBound) / span, 0), 1)
    }

    /// 行程上的比例 → 值。
    public static func value(fraction: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return range.lowerBound + f * span
    }

    /// 指针的 x（控件坐标系，单位 pt）→ 值。
    ///
    /// `inset` 是把手/圆球的一半宽：可用行程 = `width − 2·inset`。x 落在轨道外时钳到两端 ——
    /// 用户把指针拖出控件也应该是 0 或 100，而不是「拖不到底」。
    public static func value(atX x: CGFloat, width: CGFloat, inset: CGFloat,
                            in range: ClosedRange<Double>) -> Double {
        let w = width.isFinite ? width : 0
        let i = max(min(inset.isFinite ? inset : 0, w / 2), 0)
        guard w > 0 else { return range.lowerBound }
        let usable = w - 2 * i
        guard usable > 0 else { return value(fraction: 0.5, in: range) }
        let f = (Double(x) - Double(i)) / Double(usable)
        return value(fraction: f, in: range)
    }

    /// 值 → 把手中心的 x（`value(atX:width:inset:in:)` 的逆）。
    public static func x(fraction: Double, width: CGFloat, inset: CGFloat) -> CGFloat {
        let w = width.isFinite ? max(width, 0) : 0
        let i = max(min(inset.isFinite ? inset : 0, w / 2), 0)
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return CGFloat(Double(i) + f * Double(max(w - 2 * i, 0)))
    }

    /// 键盘一步：加/减一个 `keyboardStep`，钳在行程里。
    public static func nudged(_ value: Double, by delta: Double,
                              in range: ClosedRange<Double>) -> Double {
        clamp(value + delta, range)
    }
}

// MARK: - 长条形滑杆

/// 解码参数的滑杆（046）：一条 4 pt 圆角轨道、已选部分填充、一个 3×14 的细竖条把手。
///
/// 与圆形滑杆**行为等价**，只有形状不同：
///  · 拖动写 `value`（每一跳都写，调用方据此实时预览），按下/抬起各调一次 `onEditingChanged`；
///  · 拖出控件也钳到两端，所以 0 和 100 都摸得到；
///  · Tab 聚焦后 ←/→ 各走 `SliderValueMap.keyboardStep(in:)`（细节的四根 = 1 个单位），
///    `accessibilityAdjustableAction` 走同一段代码；
///  · 高度固定 16 pt，与圆形滑杆的行高一致。
public struct BarSlider: View {

    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let onEditingChanged: (Bool) -> Void

    /// 拖动是否已经开始：按下时调用一次 `onEditingChanged(true)`，抬起时一次 `false`，
    /// 而不是每一跳都调用（那样一次拖动会变成几十个 undo 快照）。
    @State private var isDragging = false

    public init(value: Binding<Double>,
                range: ClosedRange<Double>,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let x = SliderValueMap.x(fraction: SliderValueMap.fraction(value: value, in: range),
                                     width: width,
                                     inset: SliderValueMap.barInset)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(height: SliderValueMap.trackHeight)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: max(x, 0), height: SliderValueMap.trackHeight)
                RoundedRectangle(cornerRadius: SliderValueMap.handleCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: SliderValueMap.handleWidth, height: SliderValueMap.handleHeight)
                    .offset(x: x - SliderValueMap.handleWidth / 2)
            }
            .frame(width: width, height: SliderValueMap.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        write(SliderValueMap.value(atX: gesture.location.x, width: width,
                                                   inset: SliderValueMap.barInset, in: range))
                    }
                    .onEnded { gesture in
                        write(SliderValueMap.value(atX: gesture.location.x, width: width,
                                                   inset: SliderValueMap.barInset, in: range))
                        if isDragging {
                            isDragging = false
                            onEditingChanged(false)
                        }
                    }
            )
        }
        .frame(height: SliderValueMap.rowHeight)
        .focusable()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(+1) }
        .onKeyPress(.upArrow) { step(+1) }
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(+1)
            case .decrement: _ = step(-1)
            @unknown default: break
            }
        }
    }

    /// 一次键盘/辅助功能步进：写值，然后把这一跳当作「一次编辑结束」提交（一步 = 一个 undo 快照）。
    @discardableResult
    private func step(_ direction: Double) -> KeyPress.Result {
        let delta = direction * SliderValueMap.keyboardStep(in: range)
        write(SliderValueMap.nudged(value, by: delta, in: range))
        onEditingChanged(false)
        return .handled
    }

    private func write(_ newValue: Double) {
        let clamped = SliderValueMap.clamp(newValue, range)
        guard clamped != value else { return }
        value = clamped
    }
}
