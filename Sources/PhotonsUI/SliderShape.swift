import Foundation
import SwiftUI

// MARK: - 046: 滑杆形状（060 一个控件，071 三类配色）

/// 派单 046 —— 一个参数该归哪一类（用户规则，2026-10-27）：
///
/// > 如果这个选项是对 RAW 处理的，那么滑动条按照「细节」下的来，但不要加刻度线，用长条形的滑动条。
/// > 如果是解 RAW 后的，那么就是圆形的滑动条（Light 下的就是这样）
///
/// 所以类别是**参数**的属性，不是审美选择：
///
/// | 类别 | 例子 |
/// |---|---|
/// | **解码参数**（会触发重新 develop，进 `DecodeInputs`） | 降噪 / 色彩降噪 / 细节 / 锐化 / 色温 / 色调 |
/// | **渲染参数**（解 RAW 之后） | 曝光 / 对比 / 高光 / 阴影 / 白色 / 黑色 / 曲线 / 蒙版量 / 色散… |
///
/// 以后新增参数时照这张表选：只要它会改解码缓存键（`DetailSettings.decodeComponent` 那样的东西），
/// 就是 `.bar`；只改渲染的就是 `.knob`。
///
/// **060（用户定案）**：形状不再对应「两种控件」，也不再有自绘气泡 —— 两类参数都画**同一个**
/// SwiftUI `Slider`，差别只有**强调色**：`.bar` = `Color.orange`，`.knob` = 不设 tint（跟随系统
/// 强调色，默认蓝）。用户原话：「都改成 SwiftUI，只不过强调色不同，这样用来区分。默认的强调色应该是
/// 蓝色，然后与 RAW 解码有关的改为橙色。」
///
/// **071（用户 2026-10-27 重新定案，覆盖 060 的配色）**：颜色现在表达的是参数**在哪个域**，共三类：
///
/// | 类别 | 颜色 | 行 |
/// |---|---|---|
/// | 默认（解 RAW 之后的渲染：Light / Color / 曲线面板） | **蓝 = 系统强调色**（不设 tint） | 与 060 相同 |
/// | raw / 解码参数（写 `CIRAWFilter`，会重新 develop） | **黄**（060 是橙 → 改） | 降噪 / 色彩降噪 / 细节 / 锐化 / 色温 / 色调 |
/// | **线性域**（直接加在 scene-linear 缓冲上的算术） | **`#FF375F`** | 黑电平（071） |
///
/// 三类都还是**同一个** `Slider`、同一个 `sliderRow`，`accent` 是唯一的差别，而且是**唯一**的颜色
/// 来源（`HistogramCard` 的橙色刻度是「显示 headroom」的语义标记，不是滑杆 tint，不在这里）。
///
/// **三类都不许画刻度线。** SwiftUI 的 `Slider` 只要拿到 `step:` 就画刻度，所以整个面板没有一处
/// 传 `step:`（`sliderRow` 连这个参数都不收）；量化在模型层做 —— `DetailSettings.setPosition` 把位置
/// 四舍五入到 1 个单位，和键盘一步是同一个量（`SliderValueMap.keyboardStep(in:)`）。
///
/// 强调色是**唯一**的差异。label、数值框、双击复位、`onEditingChanged`（按下 true / 抬起 false）
/// 都由 `InspectorView.sliderRow` 提供，三类共用同一段代码。
public enum SliderShape: String, CaseIterable, Sendable, Equatable {
    /// 解码参数：**黄色**强调色。没有刻度。
    case bar
    /// 渲染参数：不设 tint，跟随系统强调色（默认蓝）。没有刻度。
    case knob
    /// 071：**线性域**参数，直接改 scene-linear 缓冲的算术。`#FF375F`（红）。没有刻度。
    case linear

    /// 这条滑杆的强调色 —— 面板里**唯一**的一份颜色定义。
    ///
    /// `nil` 是「跟随系统」（SwiftUI 的 `.tint(nil)`），不是「没有颜色」：渲染参数必须跟着用户的
    /// 系统强调色走，写死一个蓝色会在暖色主题下变成另一种「不跟随」的错。
    public var accent: Color? {
        switch self {
        case .knob: return nil
        case .bar: return SliderShape.rawAccent
        case .linear: return SliderShape.linearAccent
        }
    }

    /// raw / 解码参数 = **黄**（071 改的；060 是橙）。
    ///
    /// 用系统 `Color.yellow` 而不是写死一个 RGB：它就是「黄」，在深/浅色主题与提高对比度下都由系统
    /// 处理。实测的取色像素见 `SliderStyleTests`（报告里给了数字）。
    public static let rawAccent = Color.yellow

    /// 线性域 = **`#FF375F`**（用户指定的红）。sRGB 逐通道写死：这个颜色是用户给的品牌色，
    /// 不该随系统主题漂移。
    public static let linearAccent = Color(.sRGB, red: 1.0, green: 55.0 / 255, blue: 95.0 / 255,
                                          opacity: 1)
}

// MARK: - 数值映射

/// 一根滑杆的数值约定，从视图里拿出来是为了能被测试直接抓住。
///
/// 这里**没有**任何绘制几何：055 删掉了自绘把手（旧的长条形状），060 又把最后一处自绘气泡
/// 换成了 SwiftUI `Slider` —— 轨道、拖动点、已选部分全由系统画，强调色是唯一的自定义。
/// 留下的都是与绘制无关、仍被模型或测试按名字引用的纯函数。
public enum SliderValueMap {

    /// 滑杆行的固定高度。两类参数都钉这个高度，切换形状时面板不跳版式（046 要求 4）。
    public static let rowHeight: CGFloat = 16

    /// 键盘一步 = 行程的 1%。细节的四根滑杆行程 0…100，所以一步正好是 1 个单位，与
    /// `DetailSettings.step` 相同（`SliderStyleTests` 钉住这个等式）。
    ///
    /// ←/→ 由 SwiftUI `Slider` 原生处理，这个常量不再被生产代码调用 —— 它留在这里是因为它**就是**
    /// 那条规则本身（「一步 = 行程的 1%」），测试仍按名字引用它。
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
