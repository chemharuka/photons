import AppKit
import SwiftUI
import PhotonsCore

// MARK: - 2026-10-28 (P0 色彩分级): the 色彩分级 card's furniture

/// The three axes one wheel has, as data — the same shape `HSLAxis` gives the HSL card.
///
/// A table rather than nine inline rows for the reason 046/047 made `ToneRow` a table: 「三个轮 × 三根
/// 滑杆、每根都能输入、每根双击回 0」 is then a value a test can hold, and the card cannot grow a
/// tenth row (or lose an axis) without the table saying so.
public enum GradeAxis: String, CaseIterable, Sendable {
    case hue
    case saturation
    case lightness

    public var title: String {
        switch self {
        case .hue: return "色相"
        case .saturation: return "饱和"
        case .lightness: return "亮度"
        }
    }

    /// The key's tail in `EditModel` — `colorGrading.shadows.hue` etc. One spelling, used by the
    /// binding, the history field key and the reset verb.
    public var field: String { rawValue }

    /// ±100 for all three. The units are the app's existing ones (0.3° of hue, a chroma multiplier, a
    /// stop of light) — see `GradeWheel`, which is where they are defined.
    public static let range: ClosedRange<Double> = GradeWheel.travel
}

/// The three regions, as data: the card's order, the panel's words, and the wheel each row drives.
///
/// **The order is the pipeline's**: 阴影 → 中间调 → 高光 is the luminance axis, dark to light, which is
/// also where the three windows sit (−5.9…−3.9 EV, then the gap, then −3.2…+∞). The words are the Light
/// card's own (阴影 / 高光), because they are the *same* windows (`tone_shape.metal`'s
/// `region_weights`); 中间调 is the remainder between them.
public enum GradeRegion: String, CaseIterable, Sendable, Identifiable {
    case shadows
    case midtones
    case highlights

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shadows: return "阴影"
        case .midtones: return "中间调"
        case .highlights: return "高光"
        }
    }

    /// The wheel this region edits.
    public var wheel: WritableKeyPath<EditModel, GradeWheel> {
        switch self {
        case .shadows: return \EditModel.colorGrading.shadows
        case .midtones: return \EditModel.colorGrading.midtones
        case .highlights: return \EditModel.colorGrading.highlights
        }
    }
}

/// One row of the 色彩分级 card: which region, which axis, and the numbers the row draws.
///
/// Nine of them, straight out of `GradeRegion.allCases` × `GradeAxis.allCases`, so the card and its
/// tests cannot disagree about what is on screen. `keyPath` is a two-step path through the group
/// (`\EditModel.colorGrading.shadows` + the axis) rather than a `WritableKeyPath<EditModel, Double>`,
/// because Swift cannot compose key paths at run time — the binding builds the pair, the same way the
/// HSL card's binding takes a band index.
public struct GradeRow: Equatable, Identifiable, Sendable {
    public var region: GradeRegion
    public var axis: GradeAxis
    /// 「阴影 色相」 — the row's label, and the undo label a double-click commits.
    public var title: String
    public var range: ClosedRange<Double> = GradeAxis.range
    /// Whole units, like every other ±100 row in the panel.
    public var format: String = "%.0f"
    /// `.knob` — S3.8 runs in the display-referred domain on the already-decoded frame, the same class
    /// S3.6's rows are: 060's yellow would claim a decode parameter and 071's red a scene-linear one.
    public var shape: SliderShape = .knob
    /// 047: typeable, like every other row (no card opts out).
    public var editable: Bool = true
    /// 052: no decimals while editing — the number on screen is the number in the document.
    public var decimals: Int = 0
    /// 052: whole numbers, rounded away from zero, so a readout never reads smaller than the model.
    public var rounding: InspectorView.SliderRounding = .outward
    /// The document's grid: 1 unit, so the number the user read is the number the kernel gets.
    public var quantum: Double = 1
    /// The history field this row writes — `colorGrading.shadows.hue`.
    public var fieldKey: String { "colorGrading.\(region.rawValue).\(axis.field)" }
    /// The default, read from the neutral document — never a literal (all nine are 0, and
    /// `GradeWheel()` is where that lives).
    public var defaultValue: Double {
        EditModel.neutral[keyPath: region.wheel][axis]
    }
    public var id: String { fieldKey }
}

/// `GradeWheel` by axis, so the binding and the reset verb read and write the same field.
extension GradeWheel {
    public subscript(axis: GradeAxis) -> Double {
        get {
            switch axis {
            case .hue: return hue
            case .saturation: return saturation
            case .lightness: return lightness
            }
        }
        set {
            switch axis {
            case .hue: hue = newValue
            case .saturation: saturation = newValue
            case .lightness: lightness = newValue
            }
        }
    }
}

/// One row's frame, for the card's tests — the `BlackAndWhiteProbe`/`EffectsRowProbe` pattern, for the
/// same reason: the card is drawn by `SliderRow` (the panel's one row view, 040), so there is no view of
/// the card's own to measure, and measuring a re-declared row would keep passing after the shipped row
/// changed. A `.background(…)` gives the probe exactly the row's frame and cannot change it.
///
/// Inert in production (nothing is drawn, `hitTest` answers `nil`).
final class ColorGradingProbe: NSView {

    /// The card's own frame, probed from the card's `.background` so the layout test can say 「行在卡里」.
    static let cardID = "色彩分级卡"

    private(set) var rowID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("ColorGradingProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String) { rowID = id }
}

struct ColorGradingProbeHost: NSViewRepresentable {

    let rowID: String

    func makeNSView(context: Context) -> ColorGradingProbe {
        let probe = ColorGradingProbe()
        probe.update(rowID)
        return probe
    }

    func updateNSView(_ probe: ColorGradingProbe, context: Context) {
        probe.update(rowID)
    }
}
