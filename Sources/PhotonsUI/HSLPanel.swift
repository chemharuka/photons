import AppKit
import SwiftUI
import PhotonsCore

// MARK: - 派单 076: the HSL card's furniture

/// The three sliders a band has, as data.
///
/// A table rather than three inline rows for the reason 046/047 made `ToneRow` a table: 「三根滑杆、
/// 每根都能输入、每根双击回 0」 is then a value a test can hold, and the card cannot grow a fourth
/// row (or lose one) without the table saying so. `PanelResets.hslField(_:_:)` takes the same enum, so
/// the row a test resets is the row the card drew.
///
/// A row's `keyPath` is *not* a `WritableKeyPath<EditModel, Double>` like `ToneRow`'s: the target is
/// `color.bands[i].hue`, and `i` is view state. The binding is built per band instead — see
/// `InspectorView.hslBinding(_:)` — which is also why this type carries the field, not a key path.
public enum HSLAxis: String, CaseIterable, Sendable {
    case hue
    case saturation
    case luminance

    public var title: String {
        switch self {
        case .hue: return "色相"
        case .saturation: return "饱和"
        case .luminance: return "亮度"
        }
    }

    /// Every band slider travels −100…100, in the same units the mask hue/saturation use (one unit
    /// is 0.3° of hue).
    public static let range: ClosedRange<Double> = -100...100

    /// The eight bands, in Lightroom's order, with the names the selector draws — read from the
    /// **core** table (`HSLBands.bandNames`), because since 2026-10-28 the same eight names are also
    /// the history wording of a 黑白混合 row (「黑白混合[红]」). One table, so the card and the timeline
    /// cannot name the same band differently.
    public static let bandNames = HSLBands.bandNames

    /// 101 — the ninth selector, 「全局」, read from the core table for the same reason as the eight.
    public static let globalName = HSLBands.globalBandName

    /// The selector's cells: the eight bands, then 全局. Kept here so the strip, the probe and the
    /// view-state clamp cannot disagree about there being nine of them.
    public static var selectorCount: Int { bandNames.count + 1 }
    public static var isGlobal: (Int) -> Bool { { $0 == HSLBands.bandNames.count } }

    /// A band's own colour, for the selector dot: OKLCh at the band's **own centre** (the same number
    /// the stage weights against), a mid lightness and a chroma that survives being drawn 12 pt wide.
    ///
    /// Computed, never hand-picked, so a band whose centre moves (a basis change, a different fold)
    /// cannot keep a stale swatch — `HSLPanelTests` asserts the dots are the colours they name.
    public static func swatch(_ band: Int) -> NSColor {
        let i = min(max(band, 0), HSLBands.centresDegrees.count - 1)
        let lch = (L: 0.72, C: 0.15, hue: Double(HSLBands.centresDegrees[i]))
        let working = OKLCh.toLinear(L: lch.L, C: lch.C, hue: lch.hue)
        let srgb = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB).applying(to: working)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return NSColor(srgbRed: encode(srgb.x), green: encode(srgb.y), blue: encode(srgb.z), alpha: 1)
    }
}

/// One band button, as SwiftUI actually built it: which band, whether it is the selected one, the
/// colour it was drawn with, and its frame.
///
/// The same seam `InspectorWorkspaceProbe` uses, and for the same reason: under `swift test` there is
/// no accessibility tree, so 「八个色带选择器都在、第四个是选中的、红点是红的」 would otherwise be a
/// claim about source text rather than about what is on screen. `hitTest` answers `nil` so the probe
/// cannot eat the button's own clicks.
public final class HSLBandProbe: NSView {

    public private(set) var band: Int = -1
    public private(set) var title: String = ""
    public private(set) var isSelected: Bool = false
    public private(set) var swatch: NSColor = .clear
    /// 101: the colour the cell was actually filled with — equal to `swatch` for the eight bands and
    /// pure white for 全局, which is what makes 「第九个按钮底色是白的」 measurable.
    public private(set) var backgroundColor: NSColor = .clear

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("HSLBandProbe is created in code")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    func update(band: Int, title: String, isSelected: Bool, swatch: NSColor) {
        self.band = band
        self.title = title
        self.isSelected = isSelected
        self.swatch = swatch
        self.backgroundColor = swatch
    }
}

struct HSLBandProbeHost: NSViewRepresentable {
    var band: Int
    var title: String
    var isSelected: Bool
    var swatch: NSColor

    func makeNSView(context: Context) -> HSLBandProbe {
        let probe = HSLBandProbe()
        probe.update(band: band, title: title, isSelected: isSelected, swatch: swatch)
        return probe
    }

    func updateNSView(_ probe: HSLBandProbe, context: Context) {
        probe.update(band: band, title: title, isSelected: isSelected, swatch: swatch)
    }
}

/// The nine selector buttons, as one row: the eight bands, then 「全局」.
///
/// Equal width, 18 pt tall, 3 pt between them — at the narrowest panel (244 pt) the card's content
/// width is `244 − 2·12 − 2·16 = 188 pt`, so each cell is `(188 − 8·3)/9 ≈ 18.2 pt`: a 12 pt glyph is
/// two characters of 8 pt type (「品红」 uses both), which still fits with the label's scale-down.
/// `HSLPanelTests` measures that at 244 / 330 / 364 rather than trusting the arithmetic.
public struct HSLBandStrip: View {

    public var selection: Int
    public var onSelect: (Int) -> Void

    public static let height: CGFloat = 18
    public static let spacing: CGFloat = 3

    public init(selection: Int, onSelect: @escaping (Int) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<HSLAxis.selectorCount, id: \.self) { i in
                band(i)
            }
        }
        .frame(height: Self.height)
        .accessibilityIdentifier("inspector.hsl.bands")
    }

    private func band(_ i: Int) -> some View {
        let selected = i == selection
        let global = HSLAxis.isGlobal(i)
        let name = global ? HSLAxis.globalName : HSLAxis.bandNames[i]
        // 101: the ninth cell's **background** is pure white (the user's one visual requirement), not
        // a swatch from the wheel — so its probe reports sRGB (1, 1, 1, 1) and its label is drawn in
        // black when selected, because white-on-white is the one combination that cannot be read.
        let colour = global ? NSColor.white : HSLAxis.swatch(i)
        return Button {
            onSelect(i)
        } label: {
            Text(name)
                .font(.system(size: 8, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: colour).opacity(global || selected ? 1.0 : 0.35))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                }
                .foregroundStyle(global ? Color.black : (selected ? Color.white : Color.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HSLBandProbeHost(band: i, title: name, isSelected: selected, swatch: colour))
        .help("\(name)：色相 / 饱和 / 亮度")
        .accessibilityLabel("\(name)色带")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("inspector.hsl.band.\(i)")
    }
}
