import AppKit
import SwiftUI

/// 288 — the export sheet's one row grid.
///
/// Every row in the sheet (slider rows, picker rows, text rows, button rows) is built by
/// `ExportRowGridRow`, so the five columns cannot drift apart the way 217/243's slider-only grid did:
///
///     [label 96 trailing] [gap 8] [control 240 leading] [value 46 trailing]
///                         [gap 8] [unit 52 leading]      [gap 8] [accessory 64 leading]
///
/// The columns to the right of the control are always there, even when a row leaves one empty, because
/// that is what makes the *next* row's number field start at the same x.
enum ExportRowGrid {
    static let labelWidth: CGFloat = 96
    static let gap: CGFloat = 8
    static let controlWidth: CGFloat = 240
    static let valueWidth: CGFloat = 46
    static let unitWidth: CGFloat = 52
    static let accessoryWidth: CGFloat = 64
    static let rowHeight: CGFloat = 20
    static let rowSpacing: CGFloat = 6
    static let sectionHeaderTopSpacing: CGFloat = 12
    static let sliderWidth: CGFloat = 140

    /// 288 §2.2 — no slider in the sheet asks SwiftUI for a step, so it draws no tick marks. The
    /// value is a construction constant, not an AppKit readback: SwiftUI's `Slider` has no AppKit
    /// leaf under `swift test` (217 measured that). The source guard in `ExportRowGrid288Tests`
    /// keeps the `step:` argument out of `ExportSheet.swift`.
    static let sliderTickMarks = 0

    /// 288 §2.4 — the whole sheet's type scale. Only `title` is allowed above 10 pt.
    enum Font {
        static let title: CGFloat = 13
        static let sectionHeader: CGFloat = 10
        static let label: CGFloat = 10
        static let control: CGFloat = 10
        static let value: CGFloat = 10
        static let unit: CGFloat = 10
        static let hint: CGFloat = 9
    }
}

/// 288 — the column anchors. The hosted `swift test` tree has no AppKit leaf for SwiftUI `Text` or
/// `Picker`, so these transparent backgrounds are the honest readback of the frames the layout gave
/// each column (the same trick `ExportSliderRowProbe` / `ExportLayoutProbe` use).
final class ExportRowGridProbe: NSView {
    enum Kind: String {
        case row
        case label
        case control
        case value
        case unit
        case accessory
        case header
    }

    private(set) var kind: Kind = .row
    private(set) var rowID = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("ExportRowGridProbe is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(kind: Kind, rowID: String) {
        self.kind = kind
        self.rowID = rowID
    }
}

struct ExportRowGridProbeHost: NSViewRepresentable {
    var kind: ExportRowGridProbe.Kind
    var rowID: String

    func makeNSView(context: Context) -> ExportRowGridProbe {
        let probe = ExportRowGridProbe()
        probe.update(kind: kind, rowID: rowID)
        return probe
    }

    func updateNSView(_ probe: ExportRowGridProbe, context: Context) {
        probe.update(kind: kind, rowID: rowID)
    }
}

/// 288 §2.4 — the font every TextField / Picker in the sheet carries. The probe records the point
/// size that was actually applied to that control, so the test can print a control → size list even
/// though SwiftUI draws its own text and exposes no `NSTextField`/`NSFont` leaf under `swift test`.
enum ExportControlKind: String {
    case textField
    case picker
}

final class ExportControlFontProbe: NSView {
    private(set) var kind: ExportControlKind = .picker
    private(set) var rowID = ""
    private(set) var pointSize: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("ExportControlFontProbe is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(kind: ExportControlKind, rowID: String, pointSize: CGFloat) {
        self.kind = kind
        self.rowID = rowID
        self.pointSize = pointSize
    }
}

struct ExportControlFontProbeHost: NSViewRepresentable {
    var kind: ExportControlKind
    var rowID: String
    var pointSize: CGFloat

    func makeNSView(context: Context) -> ExportControlFontProbe {
        let probe = ExportControlFontProbe()
        probe.update(kind: kind, rowID: rowID, pointSize: pointSize)
        return probe
    }

    func updateNSView(_ probe: ExportControlFontProbe, context: Context) {
        probe.update(kind: kind, rowID: rowID, pointSize: pointSize)
    }
}

private struct ExportControlFontModifier: ViewModifier {
    var rowID: String
    var kind: ExportControlKind
    var design: Font.Design?

    func body(content: Content) -> some View {
        content
            .font(.system(size: ExportRowGrid.Font.control, design: design))
            .controlSize(.small)
            .background(ExportControlFontProbeHost(kind: kind, rowID: rowID,
                                                   pointSize: ExportRowGrid.Font.control))
    }
}

extension View {
    /// The one font/control-size rule for every TextField and Picker in the export sheet.
    func exportControlFont(_ rowID: String, kind: ExportControlKind,
                           design: Font.Design? = nil) -> some View {
        modifier(ExportControlFontModifier(rowID: rowID, kind: kind, design: design))
    }
}

/// 288 — the sheet's one row. Every column is fixed-width and every row reserves all five, so the
/// label right edge, the control left edge, the value leading edge (right-aligned column), the unit
/// column and the accessory column land on the same x on every row.
struct ExportRowGridRow<Label: View, Control: View, Value: View, Unit: View, Accessory: View>: View {
    let rowID: String
    let label: Label
    let control: Control
    let value: Value
    let unit: Unit
    let accessory: Accessory

    init(rowID: String,
         @ViewBuilder label: () -> Label,
         @ViewBuilder control: () -> Control,
         @ViewBuilder value: () -> Value,
         @ViewBuilder unit: () -> Unit,
         @ViewBuilder accessory: () -> Accessory) {
        self.rowID = rowID
        self.label = label()
        self.control = control()
        self.value = value()
        self.unit = unit()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: ExportRowGrid.gap) {
            column(label, width: ExportRowGrid.labelWidth, alignment: .trailing, kind: .label)
            column(control, width: ExportRowGrid.controlWidth, alignment: .leading, kind: .control)
            column(value, width: ExportRowGrid.valueWidth, alignment: .trailing, kind: .value)
            column(unit, width: ExportRowGrid.unitWidth, alignment: .leading, kind: .unit)
            column(accessory, width: ExportRowGrid.accessoryWidth,
                   alignment: .leading, kind: .accessory)
        }
        .frame(height: ExportRowGrid.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportRowGridProbeHost(kind: .row, rowID: rowID))
    }

    /// A fixed column that keeps its width even when the row leaves it empty. `EmptyView` plus a
    /// `.frame` is discarded by SwiftUI (the columns collapsed to 0 in the hosted readback), so the
    /// width lives on a clear rectangle and the content rides as an overlay.
    private func column<Content: View>(_ content: Content, width: CGFloat,
                                       alignment: Alignment,
                                       kind: ExportRowGridProbe.Kind) -> some View {
        Color.clear
            .frame(width: width, height: ExportRowGrid.rowHeight)
            .overlay(alignment: alignment) { content }
            .background(ExportRowGridProbeHost(kind: kind, rowID: rowID))
    }
}

/// 288 — a section: header then a 6 pt-spaced run of rows, all inside the sheet's single `Form`
/// section. The header's 12 pt top padding is the gap from the previous section's last row.
struct ExportSectionGrid<Rows: View>: View {
    let title: String
    let rows: Rows

    init(_ title: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: ExportRowGrid.Font.sectionHeader, weight: .semibold))
                .foregroundStyle(.secondary)
                .background(ExportRowGridProbeHost(kind: .header, rowID: title))
                .padding(.top, ExportRowGrid.sectionHeaderTopSpacing)
                .padding(.bottom, ExportRowGrid.rowSpacing)
            VStack(alignment: .leading, spacing: ExportRowGrid.rowSpacing) {
                rows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
