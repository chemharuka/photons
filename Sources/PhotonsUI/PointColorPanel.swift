import AppKit
import SwiftUI
import PhotonsCore

// MARK: - 140 · 点颜色 card furniture

/// The card's five sliders as data: the same shape `HSLAxis`/`GradeAxis` give their cards.
///
/// A table rather than five inline rows, for the reason 046/047 made every card a table: 「五根滑杆、
/// 每根都能输入、每根双击回默认」 is then a value a test can hold, and the card cannot grow a sixth
/// row (or lose one) without the table saying so.
public enum PointColorAxis: String, CaseIterable, Sendable, Identifiable {
    case range
    case feather
    case hue
    case saturation
    case luminance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .range: return "范围"
        case .feather: return "过渡"
        case .hue: return "色相"
        case .saturation: return "饱和"
        case .luminance: return "亮度"
        }
    }

    /// The window rows are the card's 0…120 travel (158: they scale the YUV box around its perceptual
    /// defaults); the three adjustment rows keep the panel's ±100 travel (0.3° of hue, a chroma
    /// multiplier and a stop of lightness, exactly like the HSL card).
    public var range: ClosedRange<Double> {
        switch self {
        case .range, .feather: return 0 ... 120
        case .hue, .saturation, .luminance: return -100 ... 100
        }
    }

    /// Read from the type's own defaults, never a literal in the row.
    public var defaultValue: Double {
        let p = PointColor()
        switch self {
        case .range: return p.range
        case .feather: return p.feather
        case .hue: return p.hue
        case .saturation: return p.saturation
        case .luminance: return p.luminance
        }
    }

    /// The history/paste spelling — `color.point.hue` etc.
    public var fieldKey: String { "color.point.\(rawValue)" }

    /// The row's unit: `°` for the two window rows, the panel's unitless ±100 for the rest.
    public var format: String {
        switch self {
        case .range, .feather: return "%.0f°"
        default: return "%.0f"
        }
    }
}

extension PointColor {
    /// One row's value, so the slider binding, the reset verb and a test all read/write the same field.
    public subscript(axis: PointColorAxis) -> Double {
        get {
            switch axis {
            case .range: return range
            case .feather: return feather
            case .hue: return hue
            case .saturation: return saturation
            case .luminance: return luminance
            }
        }
        set {
            switch axis {
            case .range: range = newValue
            case .feather: feather = newValue
            case .hue: hue = newValue
            case .saturation: saturation = newValue
            case .luminance: luminance = newValue
            }
        }
    }
}

// MARK: - the sample command

/// The dropper's write path, in one place: convert the decoded buffer sample to Rec.709 YCbCr, append
/// one swatch, select it, and commit **one** history row.
///
/// It never touches the three adjustment sliders. The sample alone is therefore not an active stage
/// (S3.6b's `isActive` needs an adjustment too), so the sampled frame is the frame before the click.
@MainActor
public struct PointColorCommands {
    public let session: CatalogSession

    public init(session: CatalogSession) {
        self.session = session
    }

    /// What one eyedropper click did. The caller turns this into the card's one-line status.
    public enum SampleOutcome: Equatable, Sendable {
        case appended(Int)
        case rejectedLowChroma
        case full
    }

    /// Sample one decoded-RGB pixel and **append** it. Returns `.rejectedLowChroma` (writing nothing)
    /// when `hypot(U − 0.5, V − 0.5) < PointColor.chromaFloorYCbCr` — the user's "不能选择饱和度很
    /// 淡的区域" rule. At eight swatches the UI refuses the ninth.
    @discardableResult
    public func sample(_ rgb: RGBSample) -> SampleOutcome {
        let yuv = PointColor.sampleYUV(fromDecodedLinear: rgb)
        let swatch = PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
        guard swatch.isSampled else { return .rejectedLowChroma }

        var set = session.edit.color.point ?? PointColorSet()
        guard let index = set.append(swatch) else { return .full }
        session.applyEdit { $0.color.point = set }
        session.commitEdit(label: "点颜色 取样", coalesce: false)
        return .appended(index)
    }

    /// Switch which swatch the sliders edit. **No history row** (U5): selection moves no pixel.
    @discardableResult
    public func select(_ index: Int?) -> Bool {
        guard var set = session.edit.color.point, !set.swatches.isEmpty else { return false }
        let old = set.active
        set.select(index)
        guard set.active != old else { return false }
        session.applyEdit { $0.color.point = set }
        return true
    }

    /// Delete exactly one swatch (double-click). One history row; selecting the fallback is part of
    /// the same row. Deleting the last swatch removes the optional entirely.
    @discardableResult
    public func delete(at index: Int) -> Bool {
        guard var set = session.edit.color.point, set.remove(at: index) else { return false }
        let next: PointColorSet? = set.swatches.isEmpty ? nil : set
        session.applyEdit { $0.color.point = next }
        session.commitEdit(label: "点颜色 删除色框", coalesce: false)
        return true
    }
}

// MARK: - the swatch strip (158)

/// The horizontal strip: one box per swatch, the selected one outlined in the system accent, a small
/// 1…8 index in each box's top-left corner, and the dropper at the end. With no swatches it shows one
/// transparent dashed slot (未选择).
///
/// Click selects (sliders follow, no history); double-click deletes **that** swatch. The exclusive
/// gesture means a double-click never also fires the single-click selection, so the fallback index is
/// computed from the click that actually happened (U3).
public struct PointColorSwatchStrip: View {
    public let set: PointColorSet?
    public let dropperArmed: Bool
    public let onSelect: (Int) -> Void
    public let onDelete: (Int) -> Void
    public let onDropper: () -> Void

    public init(set: PointColorSet?, dropperArmed: Bool,
                onSelect: @escaping (Int) -> Void,
                onDelete: @escaping (Int) -> Void,
                onDropper: @escaping () -> Void) {
        self.set = set
        self.dropperArmed = dropperArmed
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onDropper = onDropper
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let set, !set.swatches.isEmpty {
                ForEach(Array(set.swatches.enumerated()), id: \.offset) { item in
                    box(item.element, index: item.offset,
                        selected: set.active == item.offset)
                        .gesture(
                            TapGesture(count: 2)
                                .onEnded { onDelete(item.offset) }
                                .exclusively(before:
                                    TapGesture(count: 1)
                                        .onEnded { onSelect(item.offset) })
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: 30, height: 18)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .help("尚未取样")
                    .accessibilityIdentifier("inspector.pointColor.emptySwatch")
            }

            Spacer(minLength: 4)

            Button(action: onDropper) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("点颜色吸管：点击画布上要调的颜色（Esc 取消）")
            .accessibilityIdentifier("inspector.pointColor.dropper")
            .foregroundStyle(dropperArmed
                             ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("inspector.pointColor.swatches")
    }

    private func box(_ swatch: PointColor, index: Int, selected: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(PointColorSwatchView.color(for: swatch))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(selected ? Color(nsColor: .controlAccentColor)
                                       : Color.white.opacity(0.28),
                              lineWidth: selected ? 2 : 0.75)
            Text("\(index + 1)")
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .padding(.vertical, 0.5)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 2))
                .padding(1.5)
        }
        .frame(width: 30, height: 18)
        .help(PointColorSwatchView.summary(swatch))
        .accessibilityIdentifier("inspector.pointColor.swatch.\(index)")
    }
}

// MARK: - the swatch

/// One colour block: the sampled hue/chroma at a fixed OKLCh lightness, rendered opaque so the user
/// can see *which* colour a swatch is centred on.
public struct PointColorSwatchView: View {
    public let point: PointColor?

    public init(point: PointColor?) {
        self.point = point
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Self.color(for: point))
            .frame(width: 30, height: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .background(PointColorProbeHost(rowID: PointColorProbe.swatchID, point: point))
            .accessibilityIdentifier("inspector.pointColor.swatch")
            .help(point.map { Self.summary($0) } ?? "尚未取样")
    }

    /// The swatch's sRGB components. The lightness is fixed: only the sample's **hue and chroma** are
    /// displayed, so the block has to choose a lightness. 0.72 keeps a dark red and a bright red
    /// distinguishable without pretending the swatch is the photographed pixel.
    public static func srgb(for point: PointColor) -> (r: Double, g: Double, b: Double) {
        let chroma = min(max(point.sampleChroma, 0), 0.4)
        let working = OKLCh.toLinear(L: 0.72, C: chroma, hue: point.sampleHue)
        let linear = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)
            .applying(to: working)
        func encode(_ v: Double) -> Double {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return (encode(linear.x), encode(linear.y), encode(linear.z))
    }

    public static func color(for point: PointColor?) -> Color {
        guard let point, point.isSampled else { return Color(white: 0.28) }
        let c = srgb(for: point)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    public static func summary(_ point: PointColor) -> String {
        guard point.isSampled else { return "尚未取样" }
        return String(format: "采样色 H %.0f° · C %.3f", point.sampleHue, point.sampleChroma)
    }
}

// MARK: - the probe

/// The card and its five rows, as frames a hosted-panel test can measure — the
/// `ColorGradingProbe`/`BlackAndWhiteProbe` pattern. The strip probe also reports the swatch count,
/// the selected index and whether the transparent slot is showing, which is how U1–U4 become facts
/// instead of screenshots.
///
/// Inert in production (`hitTest` answers `nil`, nothing is drawn).
final class PointColorProbe: NSView {

    static let cardID = "点颜色卡"
    static let swatchID = "点颜色色块"

    private(set) var rowID: String = ""
    private(set) var sampleHue: Double = 0
    private(set) var sampleChroma: Double = 0
    private(set) var isSampled = false
    private(set) var swatchRed: Double = 0
    private(set) var swatchGreen: Double = 0
    private(set) var swatchBlue: Double = 0
    /// 158: the strip's state.
    private(set) var swatchCount: Int = 0
    /// -1 = nothing selected (the transparent slot is showing).
    private(set) var activeIndex: Int = -1
    private(set) var showsTransparentSlot = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("PointColorProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String, set: PointColorSet?) {
        rowID = id
        swatchCount = set?.swatches.count ?? 0
        activeIndex = set?.active ?? -1
        showsTransparentSlot = swatchCount == 0
        update(id, point: set?.activeSwatch ?? set?.swatches.first)
    }

    func update(_ id: String, point: PointColor?) {
        rowID = id
        sampleHue = point?.sampleHue ?? 0
        sampleChroma = point?.sampleChroma ?? 0
        isSampled = point?.isSampled ?? false
        if let point, point.isSampled {
            let c = PointColorSwatchView.srgb(for: point)
            swatchRed = c.r
            swatchGreen = c.g
            swatchBlue = c.b
        } else {
            swatchRed = 0.28
            swatchGreen = 0.28
            swatchBlue = 0.28
        }
    }
}

struct PointColorProbeHost: NSViewRepresentable {
    let rowID: String
    let point: PointColor?
    let set: PointColorSet?

    init(rowID: String, point: PointColor?) {
        self.rowID = rowID
        self.point = point
        self.set = nil
    }

    init(rowID: String, set: PointColorSet?) {
        self.rowID = rowID
        self.point = set?.activeSwatch
        self.set = set
    }

    func makeNSView(context: Context) -> PointColorProbe {
        let probe = PointColorProbe()
        if let set { probe.update(rowID, set: set) } else { probe.update(rowID, point: point) }
        return probe
    }

    func updateNSView(_ probe: PointColorProbe, context: Context) {
        if let set { probe.update(rowID, set: set) } else { probe.update(rowID, point: point) }
    }
}
