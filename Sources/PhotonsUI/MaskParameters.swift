import Foundation
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

/// The eleven local sliders plus `amount`, in the order the panel draws them and the order
/// `docs/tasks/005-masks.md` §2 lists them.
///
/// Every range is the one the *document* is defined in:
///   · `amount` — "0…100，默认 100（整体 lerp）";
///   · `exposure` — "−4…4 EV" (`LocalAdjustments.gain` clamps to ±4 too);
///   · `temperature` / `tint` — "−100…100"; temperature is a relative shift mapped as
///     `6500 K + 30 K/unit`, so it is *not* a kelvin slider (that is the global Light card's);
///   · `contrast` / `highlights` / `shadows` / `whites` / `blacks` / `hue` / `saturation` —
///     "−100…100", and `s1_6_local.metal` divides each by 100 before use.
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
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .amount: return 0 ... 100          // §2: 0…100, default 100
        case .exposure: return -4 ... 4         // §2: −4…4 EV
        default: return -100 ... 100            // §2: −100…100 for the other nine
        }
    }

    public var format: String {
        switch self {
        case .amount: return "%.0f"
        case .exposure: return "%+.2f EV"
        case .temperature, .tint: return "%+.0f"
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
            return "相对白平衡 −100…100，按 6500 K + 30 K/单位映射到 M1-7 的 Planckian 近似（不是开尔文）"
        case .tint:
            return "−100…100，正值偏品红；与全局 LightGroup.tint 同一套映射"
        case .contrast, .highlights, .shadows, .whites, .blacks, .hue, .saturation:
            return "−100…100；S1.6 按 /100 归一后作用在场景线性像素上（对比以 0.18 为枢轴）"
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
    @discardableResult
    public func writeMask(_ id: String, label: String = "蒙版", commit: Bool = false,
                          _ body: (inout Mask) -> Void) -> Bool {
        guard let index = edit.masks.firstIndex(where: { $0.id == id }) else { return false }
        let before = editRevision
        applyEdit { body(&$0.masks[index]) }
        let changed = editRevision != before
        if commit { commitEdit(label: label) }
        return changed
    }

    /// One mask-level scalar (opacity / feather / refine), clamped to the field's own domain.
    @discardableResult
    public func setMaskLevel(_ id: String, _ parameter: MaskLevelParameter, _ value: Double,
                             commit: Bool = false) -> Bool {
        let clamped = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        return writeMask(id, label: "蒙版\(parameter.label)", commit: commit) { mask in
            parameter.write(&mask, clamped)
        }
    }

    /// One local slider. `amount` is clamped to 0…100, everything else to ±the documented span.
    @discardableResult
    public func setMaskAdjustment(_ id: String, _ parameter: MaskAdjustmentParameter,
                                  _ value: Double, commit: Bool = false) -> Bool {
        let clamped = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        return writeMask(id, label: "局部\(parameter.label)", commit: commit) { mask in
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
