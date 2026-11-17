import Foundation
import SwiftUI

/// Slider colors identify processing domains. All domains share a rounded rectangular handle.
/// RAW decoding is yellow, post-decode rendering follows the system accent, and linear operations
/// use #FF375F. Native tracking, keyboard control, readouts and reset behavior are preserved.
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

/// Shared value clamping and keyboard increments.
public enum SliderValueMap {

    /// 滑杆行的固定高度。两类参数都钉这个高度，切换形状时面板不跳版式（046 要求 4）。
    public static let rowHeight: CGFloat = 16

    /// 键盘一步 = 行程的 1%。042 之后四根轴不再是同一个行程：降噪/色彩降噪/锐化 0…100（一步 1 个
    /// 单位，等于 `DetailAxis.step`），细节 0…30（一步 0.3 个单位 —— SwiftUI 的 `Slider` 会按 1%
    /// 自己走，`setPosition` 再量化到整数）。
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
