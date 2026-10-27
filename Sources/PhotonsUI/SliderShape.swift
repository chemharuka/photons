import Foundation

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
/// | **解码参数**（会触发重新 develop，进 `DecodeInputs`） | 降噪 / 色彩降噪 / 细节 / 锐化 / 色温 / 色调 | `.bar` |
/// | **渲染参数**（解 RAW 之后） | 曝光 / 对比 / 高光 / 阴影 / 白色 / 黑色 / 曲线 / 蒙版量 / 色散… | `.knob` |
///
/// 以后新增参数时照这张表选：只要它会改解码缓存键（`DetailSettings.decodeComponent` 那样的东西），
/// 就是 `.bar`；只改渲染的就是 `.knob`。
///
/// **两种形状都不许画刻度线。** SwiftUI 的 `Slider` 只要拿到 `step:` 就画刻度，所以整个面板没有一处
/// 传 `step:`（`sliderRow` 连这个参数都不收）；量化在模型层做 —— `DetailSettings.setPosition` 把位置
/// 四舍五入到 1 个单位，和键盘一步是同一个量（`SliderValueMap.keyboardStep(in:)`）。
///
/// 形状是**唯一**的差异。label、数值框、双击复位、`onEditingChanged`（按下 true / 抬起 false）都由
/// `InspectorView.sliderRow` 提供，两种形状共用同一段代码，所以不会出现「长条拖不到两端」或
/// 「圆形不能输入数值」这类分叉。
///
/// 055 之后两种形状底层是**同一个控件**（`NSSlider`，见 `BubbleSlider`）：`.bar` 只是把拖动点画成
/// 圆角长方形气泡，焦点环关掉。
public enum SliderShape: String, CaseIterable, Sendable, Equatable {
    /// 解码参数：系统滑杆的轨道与已选部分 + 10×16 pt 圆角气泡拖动点（`BubbleSlider`）。没有刻度。
    case bar
    /// 渲染参数：系统圆形滑块（SwiftUI `Slider`，`step: nil`）。
    case knob
}

// MARK: - 数值映射

/// 一根滑杆的数值约定，从视图里拿出来是为了能被测试直接抓住。
///
/// 055 删掉了自绘几何（`trackHeight` / `handleWidth` / `handleHeight` / `barInset` 以及
/// 「指针 x ↔ 值」的两条正反映射）：拖动点不再由我们摆放，`NSSlider` 自己算。留下的都是与绘制无关、
/// 仍被模型或测试按名字引用的纯函数。
public enum SliderValueMap {

    /// 滑杆行的固定高度。两种形状都钉这个高度，切换形状时面板不跳版式（046 要求 4）。
    public static let rowHeight: CGFloat = 16

    /// 键盘一步 = 行程的 1%。细节的四根滑杆行程 0…100，所以一步正好是 1 个单位，与
    /// `DetailSettings.step` 相同（`SliderStyleTests` 钉住这个等式）。
    ///
    /// 055 之后 ←/→ 由 `NSSlider` 原生处理，这个常量不再被生产代码调用 —— 它留在这里是因为它**就是**
    /// 那条规则本身（「一步 = 行程的 1%」），测试仍按名字引用它，而系统滑杆的实际步进要从 UI 里量
    /// （`swift test` 里没有键窗，量不到；见 055 报告的遗留风险）。
    public static func keyboardStep(in range: ClosedRange<Double>) -> Double {
        (range.upperBound - range.lowerBound) / 100
    }

    public static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 键盘一步：加/减一个 `keyboardStep`，钳在行程里（两端不绕回）。
    public static func nudged(_ value: Double, by delta: Double,
                              in range: ClosedRange<Double>) -> Double {
        clamp(value + delta, range)
    }
}
