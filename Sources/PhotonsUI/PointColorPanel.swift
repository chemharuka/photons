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

    /// The window rows are degrees; the three adjustment rows keep the panel's ±100 travel (0.3° of
    /// hue, a chroma multiplier and a stop of lightness, exactly like the HSL card).
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

/// The dropper's write path, in one place: convert the decoded buffer sample to OKLCh hue/chroma,
/// write the two sample fields, commit **one** history row.
///
/// It never touches `hue`/`saturation`/`luminance`. That is the acceptance's “采样前后帧 SHA 不变（只有
/// 参数变）”: with the three adjustments still at their defaults the document has no active S3.6b, so
/// the sampled frame is the frame before the click. A later slider drag is the first edit that moves
/// pixels.
@MainActor
public struct PointColorCommands {
    public let session: CatalogSession

    public init(session: CatalogSession) {
        self.session = session
    }

    /// Sample one decoded-RGB pixel. Returns `false` (and writes nothing) when the sample is exactly
    /// the one already stored, so a stray click cannot mint an empty snapshot.
    @discardableResult
    public func sample(_ rgb: RGBSample) -> Bool {
        let lch = PointColor.sample(fromDecodedLinear: rgb)
        var point = session.edit.color.point ?? PointColor()
        guard point.sampleHue != lch.hue || point.sampleChroma != lch.chroma else { return false }
        point.sampleHue = lch.hue
        point.sampleChroma = lch.chroma
        session.applyEdit { $0.color.point = point }
        return session.commitEdit(label: "点颜色 取样", coalesce: false)
    }
}

// MARK: - the swatch

/// The one colour block on the card: the sampled hue/chroma at a fixed OKLCh lightness, rendered
/// opaque so the user can see *which* colour the window is centred on.
public struct PointColorSwatchView: View {
    public let point: PointColor?

    public init(point: PointColor?) {
        self.point = point
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Self.color(for: point))
            .frame(width: 30, height: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .background(PointColorProbeHost(rowID: PointColorProbe.swatchID, point: point))
            .accessibilityIdentifier("inspector.pointColor.swatch")
            .help(point.map { Self.summary($0) } ?? "尚未取样")
    }

    /// The swatch's sRGB components. The lightness is fixed: only the sample's **hue and chroma** are
    /// stored, so the block has to choose a lightness to display them at. 0.72 keeps a dark red and a
    /// bright red distinguishable without pretending the swatch is the photographed pixel.
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
/// `ColorGradingProbe`/`BlackAndWhiteProbe` pattern. The swatch also reports the sample and the
/// displayed sRGB, which is how 「色块显示采样色」 becomes a fact instead of a screenshot.
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("PointColorProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

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

    func makeNSView(context: Context) -> PointColorProbe {
        let probe = PointColorProbe()
        probe.update(rowID, point: point)
        return probe
    }

    func updateNSView(_ probe: PointColorProbe, context: Context) {
        probe.update(rowID, point: point)
    }
}
