import Foundation
import SwiftUI
import PhotonsCore

// MARK: - 蒙版的参数，和它们各自的数域
//
// M4 shipped six shapes and a `Mask` value with eleven local sliders, but the panel only exposed the
// brush's size/hardness/flow: the mask-level parameters (`opacity`, `invert`, `feather`, `refine`,
// the component's `op`) and the whole `LocalAdjustments` struct were reachable only from a test.
// This file is the UI half of 005/M4 §2 — the *numbers*, in one place, so the panel, the smoke and
// any later surface cannot disagree about what 0 means.
//
// The rule that matters: **no range here is invented.** Each case cites the field it mirrors in
// `PhotonsCore/Masks.swift`, and every default is read from the Core value type (`Mask.fallback`,
// `LocalAdjustments.identity`) instead of being re-typed. A UI range wider than the kernel's lets a
// slider produce a number the shader silently clamps (`s1_6_local.metal` divides by 100 and
// `MaskRadius.featherPixels` clamps to 0…1); a narrower one hides half of what a document may hold,
// and then opening someone else's document shows a slider at its end stop with no way to tell that
// the value is simply outside the widget.

// MARK: - 吸管（任务 139）

/// Which parameter an armed mask eyedropper writes.
///
/// The picker itself is the loupe's existing one (`LoupeController.armEyedropper`, the same route the
/// white-balance dropper uses): armed state, Esc and the crosshair are view state and are never in
/// the document. This enum only says *what* the next click means.
public enum MaskEyedropperKind: String, Sendable, Equatable {
    case luminance
    case colour

    public var label: String {
        switch self {
        case .luminance: return "亮度吸管"
        case .colour: return "颜色吸管"
        }
    }

    public var accessibilityID: String {
        switch self {
        case .luminance: return "mask.luminance.eyedropper"
        case .colour: return "mask.color.eyedropper"
        }
    }

    public var help: String {
        switch self {
        case .luminance:
            return "点击画面：以该点亮度为中心重设窗口；⌥点击：只移动较近的一条边（Esc 取消）"
        case .colour:
            return "点击画面：把该点颜色加入样本（最多 8 个，超过时替换最旧的一个）；Esc 取消"
        }
    }
}

/// The armed-state row above a luminance / colour range section.
///
/// A plain button, not a menu: the owner treats picking as a normal operation, so it is visible at
/// the top of the row block. `isArmed` is read from the loupe (the source of truth), so Esc — which
/// the canvas handles without telling SwiftUI — turns the highlight off on the next render.
public struct MaskEyedropperRow: View {
    public let kind: MaskEyedropperKind
    public let isArmed: Bool
    public let enabled: Bool
    public let action: () -> Void

    public init(kind: MaskEyedropperKind, isArmed: Bool, enabled: Bool,
                action: @escaping () -> Void) {
        self.kind = kind
        self.isArmed = isArmed
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(!enabled)
            .help(kind.help)
            .accessibilityIdentifier(kind.accessibilityID)
            .foregroundStyle(isArmed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

            Text(isArmed ? "点击画布取样 · Esc 取消" : kind.label)
                .font(.system(size: 10))
                .foregroundStyle(isArmed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
    }
}

// MARK: mask-level parameters

/// The three scalar fields a mask has **besides** its components (005/M4 §2).
///
/// `opacity` multiplies the combined selection (Core: "1.0 = full"), `feather` is the spatial blur of
/// the combined selection (Core documents the field as 0…0.1 with an explicit "the UI range is 0…1,
/// so `feather = 1` is the whole documented span"), and `refine` is the guided filter's strength
/// (0…1, 0 = off). All three accept exactly one normalised unit, which is why one range serves all
/// three — and why the panel shows opacity as a percentage instead of inventing a 0…100 field.
public enum MaskLevelParameter: String, CaseIterable, Sendable {
    case opacity
    case feather
    case refine

    public var label: String {
        switch self {
        case .opacity: return "不透明度"
        case .feather: return "羽化"
        case .refine: return "精修"
        }
    }

    /// `Masks.swift`: opacity "1.0 = full", feather 0…1 (UI span), refine "0…1 guided-filter
    /// strength (0 = off)".
    public var range: ClosedRange<Double> { 0 ... 1 }

    public var format: String { "%.2f" }

    /// What the panel prints for the same number in percent (opacity only).
    public var isPercent: Bool { self == .opacity }

    public var value: (Mask) -> Double {
        switch self {
        case .opacity: return { $0.opacity }
        case .feather: return { $0.feather }
        case .refine: return { $0.refine }
        }
    }

    public var write: (inout Mask, Double) -> Void {
        switch self {
        case .opacity: return { $0.opacity = $1 }
        case .feather: return { $0.feather = $1 }
        case .refine: return { $0.refine = $1 }
        }
    }

    /// Core's decode fallback — what a document that never wrote the key means.
    public var defaultValue: Double { value(Mask.fallback) }

    public var help: String {
        switch self {
        case .opacity:
            return "乘在合成后的选区上（Core: 1.0 = 满强度）；0 等于这个蒙版不参与合成"
        case .feather:
            return "选区的空间模糊：1 = 短边 10 %（Core 的 0…0.1 全跨度），走 S1.7 的箱式模糊，与半径无关的 O(1) 代价"
        case .refine:
            return "导向滤波强度（0 = 关）：用 S1 的亮度引导边界，半径 = max(W,H)/30 钳到 3…65"
        }
    }
}

// MARK: local adjustments

/// The eleven local sliders plus `amount`, in the order the panel draws them — which is the order
/// `LocalAdjustments` declares them in.
///
/// Every range is the one the *document* is defined in:
///   · `amount` — "0…100，默认 100（整体 lerp）";
///   · `exposure` — "−4…4 EV" (`LocalAdjustments.gain` clamps to ±4 too);
///   · `temperature` / `tint` — "−100…100"; temperature is a relative shift mapped as
///     `6500 K + 30 K/unit`, so it is *not* a kelvin slider (that is the global Light card's);
///   · `contrast` / `highlights` / `shadows` / `whites` / `blacks` / `hue` / `saturation` —
///     "−100…100", and `s1_6_local.metal` divides each by 100 before use.
///   · 181 — 纹理 (−100…100) and 锐化 (0…100). Both are **S3.9's**, applied in the display-referred
///     domain from the S1.5 atlas, because the global 效果 card's 纹理 lives there (079: one slider
///     number, one operation). The ranges are the document's own (`LocalAdjustments.texture`
///     −100…100, `.sharpen` 0…100); the kernel divides by 100.
public enum MaskAdjustmentParameter: String, CaseIterable, Sendable {
    case amount
    case exposure
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case temperature
    case tint
    case hue
    case saturation
    case texture
    case sharpen

    public var label: String {
        switch self {
        case .amount: return "强度"
        case .exposure: return "曝光"
        case .contrast: return "对比"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .whites: return "白色"
        case .blacks: return "黑色"
        case .temperature: return "色温"
        case .tint: return "色调"
        case .hue: return "色相"
        case .saturation: return "饱和"
        case .texture: return "纹理"
        case .sharpen: return "锐化"
        }
    }

    public var keyPath: WritableKeyPath<LocalAdjustments, Double> {
        switch self {
        case .amount: return \.amount
        case .exposure: return \.exposure
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .temperature: return \.temperature
        case .tint: return \.tint
        case .hue: return \.hue
        case .saturation: return \.saturation
        case .texture: return \.texture
        case .sharpen: return \.sharpen
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .amount: return 0 ... 100          // §2: 0…100, default 100
        case .sharpen: return 0 ... 100         // §2: 0…100 — a negative sharpen is 纹理's − half
        case .exposure: return -4 ... 4         // §2: −4…4 EV
        default: return -100 ... 100            // §2: −100…100 for the other nine
        }
    }

    public var format: String {
        switch self {
        case .amount: return "%.0f"
        case .exposure: return "%+.2f EV"
        case .temperature, .tint: return "%+.0f"
        case .texture: return "%+.0f"
        case .sharpen: return "%.0f"
        default: return "%+.0f"
        }
    }

    /// Core's default, not a literal: `LocalAdjustments.identity` is what a missing key decodes to
    /// and what the S1.6 kernel tests for (`isIdentity`).
    public var defaultValue: Double { LocalAdjustments.identity[keyPath: keyPath] }

    /// How far this slider has been moved from identity — what the list row counts.
    public var isMoved: (LocalAdjustments) -> Bool {
        let read = keyPath
        let base = defaultValue
        return { adjustments in adjustments[keyPath: read] != base }
    }

    public var help: String {
        switch self {
        case .amount:
            return "整段局部调整的 lerp 系数（0…100）：0 与“没有这个蒙版”位精确相等，S1.6 直接跳过"
        case .exposure:
            return "场景线性的 EV 增益（−4…4），在 S2 之前施加；显示侧增益救不回 S2 已压掉的高光"
        case .temperature:
            return "相对白平衡 −100…100，按 6500 K + 30 K/单位换算后走全局同一个 WhiteBalanceSolver.gain（不是开尔文，也不再有第二套算法）"
        case .tint:
            return "−100…100，正值偏品红；与全局色温/色调同一个坐标系（1 单位 = 文档 tint 1），同一份 WhiteBalanceSolver.gain"
        case .contrast, .highlights, .shadows, .whites, .blacks:
            // 056: the tone half stayed in S1.6, where scene-linear is the right domain for them.
            return "−100…100；S1.6 按 /100 归一后作用在场景线性像素上（对比以 0.18 为枢轴）"
        case .hue, .saturation:
            // 056: colour moved to S3.5, **after** the tone map, so a local slider means what the
            // global one means (same `color_hsl.metal`, same numbers — measured equal to 0 codes).
            return "−100…100；在 tone map 之后的显示参考域施加，与全局同名滑杆同一份算法"
        case .texture:
            return "−100…100；在 tone map 之后的显示参考域，用与全局「纹理」同一个导向滤波残差、同一个门控，按蒙版覆盖度 lerp（不是第二套算法）"
        case .sharpen:
            return "0…100；1 px 半径的 USM（与「纹理」的频带无关，那是纹理/清晰度的活），提升被夹在窗口自身的最小/最大 ±1.5 码内（实测 1.49 码，判定线 2 码），所以锐化边缘而不是画光晕"
        }
    }
}

// MARK: - what a list row says

/// "径向渐变 · 局部 2" — the shape and how many local sliders are off their defaults.
///
/// Pure and shared by the row and the smoke, so the number the panel prints is the number the
/// harness asserts (a second formatter in the test would agree with itself and nothing else).
public enum MaskRowSummary {

    /// The shape, in the same vocabulary the 新建 menu uses.
    public static func shapeText(_ mask: Mask) -> String {
        guard let first = mask.components.first else { return "空" }
        if case .brush(let brush) = first.shape {
            return brush.strokes.isEmpty ? "空" : "\(brush.strokes.count) 笔"
        }
        if case .semantic(let semantic) = first.shape {
            return semantic.kind.displayName
        }
        return MaskCreationKind.of(first.shape)?.label ?? first.shape.kind
    }

    /// Sliders off their Core default, `amount` included (a mask whose amount was pulled down *is*
    /// adjusted — that is the whole point of the field).
    public static func adjustmentCount(_ mask: Mask) -> Int {
        MaskAdjustmentParameter.allCases.reduce(0) { total, parameter in
            total + (parameter.isMoved(mask.adjustments) ? 1 : 0)
        }
    }

    /// The whole row's second half. "局部 0 项" is printed rather than hidden: a mask with no
    /// adjustments is the identity branch of S1.6, and the list should say so instead of implying
    /// the mask changes something.
    public static func text(_ mask: Mask) -> String {
        "\(shapeText(mask)) · 局部 \(adjustmentCount(mask)) 项"
    }
}

// MARK: - combine op, in words

extension CombineOp {
    /// What the picker says. Core names the algebra ("`acc · (1 − a)`"), the panel names the verb.
    public var displayName: String {
        switch self {
        case .add: return "相加"
        case .subtract: return "减去"
        case .intersect: return "相交"
        }
    }

    public var help: String {
        switch self {
        case .add: return "并集 max(acc, a)：交界不会重复曝光"
        case .subtract: return "acc · (1 − a)：把这块从已有选区里擦掉"
        case .intersect: return "acc · a：与已有选区求交（ART 的叠乘规则）"
        }
    }
}

// MARK: - the mask panel's rows, as one table

/// One slider row of the 蒙版 card, as data — the same shape `ToneRow` gives the tone cards.
///
/// 蒙版 was the last card drawing its own rows: a bare `Slider` with a `Text` beside it, so its
/// numbers could not be typed, its names had no double-click, and its labels were set in their own
/// sizes. The fix is the panel's own: **one table per card, one row view** (`SliderRow`), so every
/// promise the other cards make (label double-click = default, click the number to type it,
/// `↵`/`Esc`/clamp) is a property of the table rather than a thing this panel remembered to do.
///
/// The table is also what makes 「每一根蒙版滑杆」 a loop in a test instead of a screenshot
/// (`MaskSliderRowTests` walks `all` and resets each row once).
///
/// Nothing here invents a number:
///   · `range` / `format` are `MaskLevelParameter`'s and `MaskAdjustmentParameter`'s own (cited
///     against `Masks.swift` there);
///   · `defaultValue` is `Mask.fallback` / `LocalAdjustments.identity` read through the parameter;
///   · opacity is shown as a **percentage** (the panel has always printed `%.0f%%`), so `document(_:)`
///     is the one place the row's unit becomes the mask's normalised 0…1.
public struct MaskSliderRow: Sendable, Identifiable, Equatable {

    /// Which document field the row writes.
    public enum Target: Sendable, Equatable {
        case level(MaskLevelParameter)
        case adjustment(MaskAdjustmentParameter)
    }

    public var title: String
    public var target: Target
    /// The slider's travel, **in the row's own units** (opacity: 0…100 %).
    public var range: ClosedRange<Double>
    public var format: String
    /// 052: decimals while editing (`2` for the normalised rows, `1`/`0` for the ±100 ones).
    public var decimals: Int
    /// 052: how the resting readout rounds (`.outward` for the whole-number rows — the panel's rule;
    /// `.asIs` for the rows that print decimals, like 曝光).
    public var rounding: InspectorView.SliderRounding
    /// 047: the undo label one gesture gets — the words the mask panel has always used.
    public var label: String
    public var help: String

    /// 046: 蒙版量 is a **render** parameter (it acts on the already-decoded selection), so the row is
    /// `.knob` — the system accent, no colour of its own. The mask panel has no second palette.
    public var shape: SliderShape { .knob }

    public var id: String {
        switch target {
        case .level(let p): return "mask.level.\(p.rawValue)"
        case .adjustment(let p): return "mask.adjust.\(p.rawValue)"
        }
    }

    /// The row's own units → the document's value. The one conversion in this file.
    public func document(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        switch target {
        case .level(.opacity): return clamped / 100          // percent on screen, 0…1 in the mask
        case .level, .adjustment: return clamped
        }
    }

    /// The document's value → the row's own units.
    public func display(_ mask: Mask) -> Double {
        switch target {
        case .level(let parameter):
            let stored = parameter.value(mask)
            return parameter.isPercent ? stored * 100 : stored
        case .adjustment(let parameter):
            return mask.adjustments[keyPath: parameter.keyPath]
        }
    }

    /// Core's default, in the row's own units (`不透明度` = 100 %, 羽化/精修 = 0, 强度 = 100, …).
    public var defaultValue: Double {
        switch target {
        case .level(let parameter):
            return parameter.isPercent ? parameter.defaultValue * 100 : parameter.defaultValue
        case .adjustment(let parameter):
            return parameter.defaultValue
        }
    }

    /// Write one value into a mask **in place** — the whole-card reset uses this to keep every field
    /// inside one `applyEdit`.
    public func apply(_ displayValue: Double, to mask: inout Mask) {
        let value = document(displayValue)
        switch target {
        case .level(let parameter): parameter.write(&mask, value)
        case .adjustment(let parameter): mask.adjustments[keyPath: parameter.keyPath] = value
        }
    }

    /// The live/typed path: the session's own write door, so the clamping, the label and the "commit
    /// only when the gesture ends" rule are the ones the mask panel already had.
    @MainActor
    @discardableResult
    /// - Parameter coalesce: `false` when this write is a **command** (双击复位) rather than a drag
    ///   release — 077: a command must not merge into the drag in front of it.
    public func write(_ displayValue: Double, into session: CatalogSession, maskID: String,
                      commit: Bool, coalesce: Bool = true) -> Bool {
        session.writeMask(maskID, label: label, commit: commit, coalesce: coalesce) {
            apply(displayValue, to: &$0)
        }
    }

    // MARK: the shipped table

    /// 不透明度 / 羽化 / 精修, in that order.
    public static let level: [MaskSliderRow] = MaskLevelParameter.allCases.map { parameter in
        MaskSliderRow(title: parameter.label,
                      target: .level(parameter),
                      range: parameter.isPercent ? 0 ... 100 : parameter.range,
                      format: parameter.isPercent ? "%.0f%%" : parameter.format,
                      decimals: parameter.isPercent ? 0 : 2,
                      rounding: parameter.isPercent ? .outward : .asIs,
                      label: "蒙版\(parameter.label)",
                      help: parameter.help)
    }

    /// 强度 plus the ten local sliders, in the order `LocalAdjustments` declares them.
    public static let adjustments: [MaskSliderRow] = MaskAdjustmentParameter.allCases.map { parameter in
        // 曝光 keeps two decimals (and `.asIs`, like the Light card's 曝光); the rest print whole
        // numbers and round outward — the same two rules the tone rows follow.
        let isExposure = parameter == .exposure
        return MaskSliderRow(title: parameter.label,
                             target: .adjustment(parameter),
                             range: parameter.range,
                             format: parameter.format,
                             decimals: isExposure ? 2 : 1,
                             rounding: isExposure ? .asIs : .outward,
                             label: "局部\(parameter.label)",
                             help: parameter.help)
    }

    /// Every parameter row the 蒙版 card draws, in draw order — what `MaskPanelProbe` reports and what
    /// 「每一根蒙版滑杆都能复位 / 都能输入」 is asserted over.
    public static var all: [MaskSliderRow] { level + adjustments }
}

/// One row of the selected shape's own section (中点 / 半径 / 角度 / 容差 / 下限 / 上限 / 软边).
///
/// A second table type because these rows read and write a `MaskShape`, not a `Mask`: the shape is a
/// tagged union, so each row carries the closure that rebuilds its own case. The defaults are the
/// Core value types' own (`LinearGradientShape.default.midpoint` = 0.5, `RadialGradientShape.default`
/// radius 0.25 / angle 0, `ColorRangeShape.default.tolerance` = 0.30,
/// `LuminanceRangeShape.default` 0…1, `SemanticShape.default.softEdge` = 0.20) — never a literal
/// re-typed here.
public struct MaskShapeSliderRow: Sendable {

    public var title: String
    public var range: ClosedRange<Double>
    public var format: String
    public var decimals: Int
    public var rounding: InspectorView.SliderRounding
    /// The undo label one gesture gets (the words the shape section has always used).
    public var label: String
    /// The shape's value in the row's units.
    public var read: @Sendable (MaskShape) -> Double
    /// Rebuild the shape with one row changed (the geometry the row does not own is preserved).
    public var apply: @Sendable (MaskShape, Double) -> MaskShape
    /// Core's default, in the row's units.
    public var defaultValue: Double

    /// 046: the shape parameters are render-domain numbers → `.knob` (system accent).
    public var shape: SliderShape { .knob }

    /// The rows the selected shape actually has — **empty for a brush** (a brush's own numbers are
    /// the view-state rows below the section) and for a shape this build does not know.
    public static func rows(for shape: MaskShape) -> [MaskShapeSliderRow] {
        switch shape {
        case .linearGradient:
            return [MaskShapeSliderRow(
                title: "中点", range: 0.05 ... 0.95, format: "%.2f", decimals: 2, rounding: .asIs,
                label: "渐变中点",
                read: { if case .linearGradient(let g) = $0 { return g.midpoint } else { return .nan } },
                apply: { shape, value in
                    guard case .linearGradient(let g) = shape else { return shape }
                    return .linearGradient(LinearGradientShape(start: g.start, end: g.end,
                                                               midpoint: value))
                },
                defaultValue: LinearGradientShape.default.midpoint)]

        case .radialGradient:
            return [
                MaskShapeSliderRow(
                    title: "半径", range: 0.02 ... 1.2, format: "%.3f", decimals: 3, rounding: .asIs,
                    label: "椭圆半径",
                    read: { if case .radialGradient(let g) = $0 {
                        return max(g.radius.x, g.radius.y) } else { return .nan } },
                    apply: { shape, value in
                        guard case .radialGradient(let g) = shape else { return shape }
                        return .radialGradient(RadialGradientShape(center: g.center,
                                                                   radius: NormalizedPoint(value, value),
                                                                   angle: g.angle))
                    },
                    defaultValue: RadialGradientShape.default.radius.x),
                MaskShapeSliderRow(
                    title: "角度", range: -180 ... 180, format: "%.0f°", decimals: 1, rounding: .outward,
                    label: "椭圆角度",
                    read: { if case .radialGradient(let g) = $0 { return g.angle } else { return .nan } },
                    apply: { shape, value in
                        guard case .radialGradient(let g) = shape else { return shape }
                        return .radialGradient(RadialGradientShape(center: g.center,
                                                                   radius: g.radius, angle: value))
                    },
                    defaultValue: RadialGradientShape.default.angle),
            ]

        case .colorRange:
            return [
                MaskShapeSliderRow(
                    // 139 — the one control that means 「扩大选择范围」. Row units are percent
                    // (0…100 %); the document stays `tolerance` in 0…1, so this is the only
                    // conversion and the panel's readout is the engine's own number ×100.
                    title: "选择范围", range: 0 ... 100, format: "%.0f%%", decimals: 0,
                    rounding: .outward, label: "颜色选择范围",
                    read: { if case .colorRange(let c) = $0 { return c.tolerance * 100 } else { return .nan } },
                    apply: { shape, value in
                        guard case .colorRange(let c) = shape else { return shape }
                        return .colorRange(ColorRangeShape(
                            samples: c.samples,
                            tolerance: min(max(value, 0), 100) / 100,
                            smoothness: c.smoothness))
                    },
                    defaultValue: ColorRangeShape.default.tolerance * 100),
                MaskShapeSliderRow(
                    title: "过渡", range: 0 ... 1, format: "%.2f", decimals: 2, rounding: .asIs,
                    label: "颜色过渡",
                    read: { if case .colorRange(let c) = $0 { return c.smoothness } else { return .nan } },
                    apply: { shape, value in
                        guard case .colorRange(let c) = shape else { return shape }
                        return .colorRange(ColorRangeShape(samples: c.samples, tolerance: c.tolerance,
                                                           smoothness: min(max(value, 0), 1)))
                    },
                    defaultValue: ColorRangeShape.default.smoothness),
            ]

        case .luminanceRange:
            let top = LuminanceRangeShape.hdrMax
            return [
                MaskShapeSliderRow(
                    title: "下限", range: 0 ... top, format: "%.2f", decimals: 2, rounding: .asIs,
                    label: "亮度下限",
                    read: { if case .luminanceRange(let l) = $0 { return l.low } else { return .nan } },
                    apply: { shape, value in
                        guard case .luminanceRange(let l) = shape else { return shape }
                        // 139: no ordering clamp here. `low > high` is a mirror with its own
                        // documented meaning (`LuminanceRangeShape.ordered`); a second repair in the
                        // UI is how two rules start disagreeing.
                        return .luminanceRange(LuminanceRangeShape(low: min(max(value, 0), top),
                                                                   high: l.high,
                                                                   lowFeather: l.lowFeather,
                                                                   highFeather: l.highFeather))
                    },
                    defaultValue: LuminanceRangeShape.default.low),
                MaskShapeSliderRow(
                    title: "上限", range: 0 ... top, format: "%.2f", decimals: 2, rounding: .asIs,
                    label: "亮度上限",
                    read: { if case .luminanceRange(let l) = $0 { return l.high } else { return .nan } },
                    apply: { shape, value in
                        guard case .luminanceRange(let l) = shape else { return shape }
                        return .luminanceRange(LuminanceRangeShape(low: l.low,
                                                                   high: min(max(value, 0), top),
                                                                   lowFeather: l.lowFeather,
                                                                   highFeather: l.highFeather))
                    },
                    defaultValue: LuminanceRangeShape.default.high),
            ]

        case .semantic:
            return [MaskShapeSliderRow(
                title: "软边", range: 0 ... 0.6, format: "%.2f", decimals: 2, rounding: .asIs,
                label: "语义软边",
                read: { if case .semantic(let s) = $0 { return s.softEdge } else { return .nan } },
                apply: { shape, value in
                    guard case .semantic(var s) = shape else { return shape }
                    s.softEdge = value
                    return .semantic(s)
                },
                defaultValue: SemanticShape.default.softEdge)]

        case .brush, .unsupported:
            return []
        }
    }
}

// MARK: - 吸管：the sampled value and the two document writes

/// The bridge between the loupe's decode-buffer sample and the two mask parameters.
///
/// `LoupeController.samplePixel` returns `RGBSample` in the **decoded** buffer's space (linear sRGB,
/// `ColorPrimaries.decoded`). The kernel's predicates run on **S1's output** in working primaries, so
/// both conversions live in `OKLabMetric` next to the metric they must agree with — see
/// `maskLuminance` / `maskSampleSRGB` there, and the report's space check.
public enum MaskEyedropper {

    /// The luminance axis: OKLab L of clamped working-linear light (`0…1`).
    public static func luminance(from sample: RGBSample) -> Double {
        OKLabMetric.maskLuminance(fromDecodedSRGB: sample.r, sample.g, sample.b)
    }

    /// The colour storage triple: sRGB-encoded 0…1, the contract of `ColorRangeShape.samples`.
    public static func colour(from sample: RGBSample) -> [Double] {
        OKLabMetric.maskSampleSRGB(fromDecodedSRGB: sample.r, sample.g, sample.b)
    }
}

extension CatalogSession {

    /// One luminance pick = **one** document write = one history entry.
    ///
    /// `moveNearerEdge` is the ⌥-click: it replaces only the edge closer to the sample. A plain
    /// click re-centres the current window (or opens a 0.25-wide one when the window was "everything").
    /// Feathers are untouched in both cases; `ordered` is the only place that repairs an inverted
    /// pair.
    @discardableResult
    public func pickMaskLuminance(_ maskID: String, component: Int, at value: Double,
                                  moveNearerEdge: Bool = false) -> Bool {
        guard let mask = edit.masks.first(where: { $0.id == maskID }),
              mask.components.indices.contains(component),
              case .luminanceRange(let shape) = mask.components[component].shape else { return false }
        let next = moveNearerEdge ? shape.movingNearerEdge(to: value) : shape.centring(on: value)
        guard next != shape else { return false }
        setMaskComponentShape(maskID, component: component, shape: .luminanceRange(next),
                              commit: true,
                              label: moveNearerEdge ? "亮度吸管 · 单边" : "亮度吸管",
                              coalesce: false)
        return true
    }

    /// One colour pick = one sample append (FIFO past 8) = one history entry.
    ///
    /// `tolerance` and `smoothness` are copied through unchanged: the picker widens the **union** of
    /// sampled colours, it does not reset the range the user set.
    @discardableResult
    public func pickMaskColour(_ maskID: String, component: Int, sampleSRGB: [Double]) -> Bool {
        guard sampleSRGB.count >= 3,
              let mask = edit.masks.first(where: { $0.id == maskID }),
              mask.components.indices.contains(component),
              case .colorRange(let shape) = mask.components[component].shape else { return false }
        // A new 颜色范围 mask opens on the mid-grey placeholder (`MaskShapeControls.defaultShape`:
        // "a starting point the user replaces by picking a colour"). The first real pick replaces
        // it; otherwise "pick red" would also keep selecting the whole mid-tone range.
        var base = shape
        if base.samples == [[0.5, 0.5, 0.5]] { base.samples = [] }
        let next = base.appendingSample(Array(sampleSRGB.prefix(3)))
        setMaskComponentShape(maskID, component: component, shape: .colorRange(next),
                              commit: true, label: "颜色吸管", coalesce: false)
        return true
    }
}

// MARK: - the panel's reset verbs, for 蒙版

/// Double-click on a mask row's name, and on the 蒙版 card's title — the same two verbs every other
/// card has, with the same guarantee: **one act = one snapshot**.
///
/// They live on `PanelResets` (not in the view) for 047's reason: the panel and the tests must call
/// one implementation, or 「复位」 means one thing on screen and another in a test. They are not
/// `Group` cases — `Group` is the enum `PanelResetTests` holds to exactly four *number* cards, and a
/// mask is a list; the whole-card verb is spelled `maskCard(_:)`, like `curve()` is for the curve
/// (which is also not a field group).
extension PanelResets {

    /// Double-click on 不透明度 / 羽化 / 精修 / 强度 / 曝光 …: that one field back to its Core default.
    /// `false` when it was already there, so a stray double-click cannot truncate the redo branch.
    @discardableResult
    public func mask(_ row: MaskSliderRow, in mask: Mask) -> Bool {
        guard row.display(mask) != row.defaultValue else { return false }
        // 077: 复位是**命令**，不参与"同参数连续拖动"的合并（否则它会折进前面那次拖动，
        // 落回起点时两行一起消失，⌘Z 无从撤销）。
        return row.write(row.defaultValue, into: session, maskID: mask.id, commit: true,
                         coalesce: false)
    }

    /// Double-click on 中点 / 半径 / 角度 / 容差 / 下限 / 上限 / 软边: that one shape field back to the
    /// Core value type's default, one snapshot.
    @discardableResult
    public func maskShape(_ row: MaskShapeSliderRow, in mask: Mask, component: Int) -> Bool {
        guard mask.components.indices.contains(component) else { return false }
        let current = mask.components[component].shape
        guard row.read(current) != row.defaultValue else { return false }
        session.setMaskComponentShape(mask.id, component: component,
                                      shape: row.apply(current, row.defaultValue),
                                      commit: true, label: row.label, coalesce: false)
        return true
    }

    /// Double-click on the 蒙版 card's title: **this mask's parameters** back to their defaults, in one
    /// snapshot — 不透明度 / 羽化 / 精修 / 反转 and the whole `LocalAdjustments` set.
    ///
    /// The drawn shape's geometry (中点 / 半径 / 角度 / 容差 / 下限 / 上限 / 软边) is deliberately **not**
    /// in here: those numbers describe the gesture the user drew on the photo (a ramp's midpoint, an
    /// ellipse's radius), and a double-click on the card title must not move the selection somewhere
    /// nobody drew. Each of them has its own double-click on its own name, and the trash button is how
    /// a mask goes away.
    @discardableResult
    public func maskCard(_ id: String) -> Bool {
        guard let mask = session.edit.masks.first(where: { $0.id == id }) else { return false }
        var next = mask
        for row in MaskSliderRow.level { row.apply(row.defaultValue, to: &next) }
        next.adjustments = .identity
        // 反转 is a checkbox, not a row, and its default is the fallback mask's: off.
        next.invert = Mask.fallback.invert
        guard next != mask else { return false }
        return session.writeMask(id, label: InspectorView.Section.masks.title, commit: false) { $0 = next }
            && session.commitEdit(label: InspectorView.Section.masks.title, coalesce: false)
    }
}

// MARK: - the session: one writer for every parameter

extension CatalogSession {

    /// Mutate one mask, and commit only when the caller says the gesture ended.
    ///
    /// `commit: false` is the **drag** case: the pixels follow the hand (each tick goes through
    /// `applyEdit`, so `editRevision` moves and the loupe's 50 ms debounce coalesces the frames) but
    /// the history does not grow. `commit: true` is a click on a toggle, a menu pick, or the mouse-up
    /// of a slider — one snapshot per gesture, exactly like the Light card.
    ///
    /// Returns whether the document actually changed: a slider released where it started is not an
    /// edit, and the caller can tell the difference instead of guessing.
    /// - Parameter coalesce: `false` for a **discrete command** (双击复位). Same rule as
    ///   `commitEdit` (077): a reset must not fold into the drag that came before it — folding it in
    ///   would either hide the reset inside that row or erase both when it lands on the drag's start.
    @discardableResult
    public func writeMask(_ id: String, label: String = "蒙版", commit: Bool = false,
                          coalesce: Bool = true,
                          _ body: (inout Mask) -> Void) -> Bool {
        guard let index = edit.masks.firstIndex(where: { $0.id == id }) else { return false }
        let before = editRevision
        applyEdit { body(&$0.masks[index]) }
        let changed = editRevision != before
        if commit { commitEdit(label: label, coalesce: coalesce) }
        return changed
    }

    /// One mask-level scalar (opacity / feather / refine), clamped to the field's own domain.
    ///
    /// A `commit: true` here is a slider's **mouse-up** — one gesture — so it is committed as a
    /// discrete row (`coalesce: false`). Letting 077 fold it into the previous same-class row made
    /// three separate ±2 EV releases disappear (`UISmokeRunner`'s 12.5 check read history +0): the
    /// first one merged into the mask-creation row, and because it returned the value to that row's
    /// start, the merge rule deleted the row instead of appending one.
    @discardableResult
    public func setMaskLevel(_ id: String, _ parameter: MaskLevelParameter, _ value: Double,
                             commit: Bool = false) -> Bool {
        let clamped = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        return writeMask(id, label: "蒙版\(parameter.label)", commit: commit,
                         coalesce: false) { mask in
            parameter.write(&mask, clamped)
        }
    }

    /// One local slider. `amount` is clamped to 0…100, everything else to ±the documented span.
    ///
    /// `coalesce: false` for the same reason as `setMaskLevel`: `commit: true` is the release of one
    /// drag, and two releases are two history rows even when they touch the same parameter.
    @discardableResult
    public func setMaskAdjustment(_ id: String, _ parameter: MaskAdjustmentParameter,
                                  _ value: Double, commit: Bool = false) -> Bool {
        let clamped = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        return writeMask(id, label: "局部\(parameter.label)", commit: commit,
                         coalesce: false) { mask in
            mask.adjustments[keyPath: parameter.keyPath] = clamped
        }
    }

    /// Mask-level `invert`: applies to the combined selection (`1 − a`), not to one component.
    @discardableResult
    public func setMaskInverted(_ id: String, _ inverted: Bool) -> Bool {
        writeMask(id, label: inverted ? "反转蒙版" : "取消反转", commit: true) { $0.invert = inverted }
    }

    /// One component's blend mode. Core: the **first** component's `op` is ignored, so the panel
    /// disables the picker for it rather than offering a control that writes a value nothing reads.
    @discardableResult
    public func setMaskCombineOp(_ id: String, component: Int, _ op: CombineOp) -> Bool {
        guard let mask = edit.masks.first(where: { $0.id == id }),
              mask.components.indices.contains(component) else { return false }
        return writeMask(id, label: "混合\(op.displayName)", commit: true) { mask in
            mask.components[component].op = op
        }
    }

    /// Rename. One snapshot, and **no** render: `name` is in no key (`Masks.swift`: "Free text.
    /// Deliberately **not** in any key: renaming must not invalidate a render").
    ///
    /// `EditHistory.commit` still records it, because `isSemanticallyIdentical` compares the masks by
    /// value — name included — and only the *dirty groups* look at key material. That is why a
    /// rename commits with an empty dirty set and gets the `.masks` label fallback: ⌘Z brings the old
    /// name back, and the frame it redraws is bit-identical.
    @discardableResult
    public func renameMask(_ id: String, to name: String) -> Bool {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !trimmed.isEmpty else { return false }
        return writeMask(id, label: "重命名蒙版", commit: true) { $0.name = trimmed }
    }

    /// Move a mask one slot up (`-1`) or down (`+1`) in the list.
    ///
    /// What this order *is*: the document's array order — the order `develop_json` stores and the
    /// list draws. It is **not** the combination order across masks: `EditModel.activeMasks` sorts by
    /// id ("id ascending — locale-free, so two processes and the disk cache agree, D6"), and so does
    /// every piece of key material. Within one mask the combination order is `components`, which is
    /// the order the shapes were added and which the key *does* see.
    @discardableResult
    public func moveMask(_ id: String, by delta: Int) -> Bool {
        guard let index = edit.masks.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + delta
        guard delta != 0, edit.masks.indices.contains(target) else { return false }
        // A move is a document-level operation (the array), so it goes through `applyEdit` directly —
        // `writeMask` hands the *mask* to its body and cannot reach the list. The commit is still the
        // ordinary one-snapshot door.
        applyEdit { $0.masks.swapAt(index, target) }
        commitEdit(label: delta < 0 ? "上移蒙版" : "下移蒙版")
        return true
    }

    /// Whether there is a slot to move into (what the ▲▼ buttons read to enable themselves).
    public func canMoveMask(_ id: String, by delta: Int) -> Bool {
        guard let index = edit.masks.firstIndex(where: { $0.id == id }) else { return false }
        return edit.masks.indices.contains(index + delta) && delta != 0
    }
}
