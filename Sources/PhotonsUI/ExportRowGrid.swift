import AppKit
import SwiftUI

/// 302 — 导出面板改版 A 的**一列**栅格。
///
/// 288 的五列（96 / 8 / 240 / 46 / 52 / 64）是列表的度量：46 / 52 / 64 三列在商业产品里没有对应物，
/// 行高 20 + 行距 6 也装不下 macOS 标准控件，那是「重心不稳」的直接来源。302 把它收回表单：
///
///     [padding 20] [label 110 trailing] [gap 8] [control 286 leading] [gutter 8] [readout 108 trailing] [padding 20]
///
/// 322 只重算了宽度，三条列线的位置（标签右沿 130 / 控件左沿 138 / 读数右沿 540）一个没动。
///
/// 读数（值 + 单位）是一个**右对齐到面板右 padding** 的块：块内 46 / 4 / 58 只是为了让数值框和
/// 单位在每一行都换到同一个 x（288 的列对齐思想），块本身是一条右沿，不再有第三条列。
///
/// 行高 24 / 行距 8 → **pitch 32，只有这一种**；节与节之间额外 16，节标题 24，标题到首行 8。
enum ExportRowGrid {

    // MARK: 面板

    /// 560 —— sheet 固定宽，不再随窗口。左右 padding 相等，这是重心。
    static let panelWidth: CGFloat = 560
    static let horizontalPadding: CGFloat = 20
    /// 内容自适应上限。
    static let contentMaxHeight: CGFloat = 640

    // MARK: 三列

    /// 标签列，右对齐。
    ///
    /// 322 量过整张表的标签（三段全展开、20 行）：最长的是「水印不透明度」71.5 pt，加上勾选框
    /// 自己的盒子（16 + 4 + 文字，见 `toggleBoxWidth`）最宽的「写入 XMP」也只 78 —— 110 有 32 pt
    /// 的余量。所以**不加宽标签列**：加宽它只会把控件列挤窄，而三条列线（130 / 138 / 540）是
    /// 302 的实测值，不能动。
    static let labelWidth: CGFloat = 110
    /// 标签右沿到控件左沿。
    static let gap: CGFloat = 8
    /// 控件列，左对齐，统一高度 24。
    ///
    /// 322：250 → 286。被截的是控件块里的三件东西 —— 「尺寸」行的模式选择 + 像素量读数、
    /// 「存到」行的路径、「半尺寸」行的说明；这 36 pt 从控件块与读数块之间的空白（50 → 8）里出，
    /// 所以标签右沿 130、控件左沿 138、读数右沿 540 三条线一个不动。
    static let controlWidth: CGFloat = 286
    /// 读数块里的数值框（288 的 46 宽度，保持不变，免得同类型控件换位）。
    static let valueWidth: CGFloat = 46
    /// 读数块里的单位。
    ///
    /// 322：52 → 58 —— 「像素/英寸」量出来 54.3 pt，在 52 里被截成「像素/…」（用户看到的就是
    /// 「不写入「像素/…」」）。读数块因此 102 → 108，**右沿仍是 540**，多出来的宽度向左长。
    static let unitWidth: CGFloat = 58
    static let readoutGap: CGFloat = 4

    // MARK: 纵向节奏

    static let rowHeight: CGFloat = 24
    static let rowSpacing: CGFloat = 8
    /// 节标题相对上一节末行的间距（pitch 32 之外**唯一**的另一种间距）。
    static let sectionSpacing: CGFloat = 16
    static let headerHeight: CGFloat = 24
    static let headerToRows: CGFloat = 8
    static let footerHeight: CGFloat = 22
    static let buttonHeight: CGFloat = 28
    static let disclosureSize: CGFloat = 12
    /// 下拉菜单（预设 / 元数据 / 重名 / 水印位置）的宽度。
    static let presetWidth: CGFloat = 150
    static let menuWidth: CGFloat = 160

    // MARK: 控件

    /// 288 §2.2 —— 滑杆仍是 140 宽、不传 `step:`，所以没有刻度。
    static let sliderWidth: CGFloat = 140
    static let sliderTickMarks = 0

    // MARK: 推导出的锚点（测试读的就是这些）

    static var contentWidth: CGFloat { panelWidth - horizontalPadding * 2 }
    /// 标签右沿：20 + 110 = 130。（302 的注释写成 118 是笔误，实测一直是 130。）
    static var labelRight: CGFloat { horizontalPadding + labelWidth }
    /// 控件左沿：130 + 8 = 138。
    static var controlLeft: CGFloat { labelRight + gap }
    /// 控件右沿：138 + 286 = 424。
    static var controlRight: CGFloat { controlLeft + controlWidth }
    /// 读数块宽：46 + 4 + 58 = 108。
    static var readoutWidth: CGFloat { valueWidth + readoutGap + unitWidth }
    /// 读数右沿 = 面板右 padding：560 − 20 = 540。
    static var readoutRight: CGFloat { panelWidth - horizontalPadding }
    static var readoutLeft: CGFloat { readoutRight - readoutWidth }
    /// 行 pitch：24 + 8 = 32。
    static var rowPitch: CGFloat { rowHeight + rowSpacing }
    /// 控件块与读数块之间的走道（560 − 20·2 − 110 − 8 − 286 − 108 = 8）。
    static var controlToReadout: CGFloat { contentWidth - labelWidth - gap - controlWidth - readoutWidth }

    /// 322 —— 勾选框的点击框宽度，按**标签文字自己**量：16 的盒子 + 4 的间距 + 文字 + 4 的余量。
    ///
    /// 302 把它写死成 34，于是「不扩大」（55.8）、「写入 XMP」（73.9）、「移除位置」（67.7）、
    /// 「半尺寸」（55.8）、「PPI」（39.0）全被截成「…」。勾选框是行修饰，框要跟着自己的字走。
    static func toggleBoxWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Font.label, weight: .medium)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return 20 + text + 4
    }

    /// 288 §2.4 / 302 §2A —— 字号表。标题 13 只留给面板标题。
    enum Font {
        static let title: CGFloat = 13
        static let sectionHeader: CGFloat = 12
        static let label: CGFloat = 12
        static let control: CGFloat = 12
        static let value: CGFloat = 12
        static let unit: CGFloat = 12
        static let hint: CGFloat = 11
        static let disclosure: CGFloat = 12
        static let footer: CGFloat = 12
    }
}

/// 288 —— 列的锚点。hosted `swift test` 里 SwiftUI 的 `Text` / `Picker` 没有 AppKit 叶子，
/// 这些透明背景是布局真正给出去的那几个 frame 的诚实读数（217/243 用的同一招）。
final class ExportRowGridProbe: NSView {
    enum Kind: String {
        case row
        case label
        case control
        /// 302：读数整块（值 + 单位），右沿 = 面板右 padding。
        case readout
        case value
        case unit
        case accessory
        case header
        /// 302：页脚摘要行与按钮带。
        case summary
        case buttons
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

/// 288 §2.4 —— 每个 TextField / Picker 的字体。探针记录真正打到控件上的字号。
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
    /// 导出面板里每个 TextField / Picker 唯一的字号/控件尺寸规则。
    func exportControlFont(_ rowID: String, kind: ExportControlKind,
                           design: Font.Design? = nil) -> some View {
        modifier(ExportControlFontModifier(rowID: rowID, kind: kind, design: design))
    }
}

/// 302 —— 面板的一行：三列，宽度固定，空列也占位。
///
/// 标签右沿 118、控件左沿 138、读数右沿 540 三根线，每一行都一样 —— 这是「同类型控件位置一致」
/// 的可判定形式。控件块（250）内部再分：控件内容左对齐、行修饰勾选框贴右沿。
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
        HStack(spacing: 0) {
            column(label, width: ExportRowGrid.labelWidth, alignment: .trailing, kind: .label)
            Color.clear.frame(width: ExportRowGrid.gap)
            controlBlock
            Spacer(minLength: 0)
            readout
        }
        // 322 —— 两行行（长说明）按内容长高；单行的行仍然正好 24。
        .frame(minHeight: ExportRowGrid.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportRowGridProbeHost(kind: .row, rowID: rowID))
    }

    private var controlBlock: some View {
        control
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { accessory }
            .frame(width: ExportRowGrid.controlWidth, alignment: .leading)
            .background(ExportRowGridProbeHost(kind: .control, rowID: rowID))
    }

    /// 读数是一个块：值 46（右对齐）+ 4 + 单位 52（左对齐），整块右对齐到面板右 padding。
    private var readout: some View {
        HStack(spacing: ExportRowGrid.readoutGap) {
            column(value, width: ExportRowGrid.valueWidth, alignment: .trailing, kind: .value)
            column(unit, width: ExportRowGrid.unitWidth, alignment: .leading, kind: .unit)
        }
        .frame(width: ExportRowGrid.readoutWidth, alignment: .trailing)
        .background(ExportRowGridProbeHost(kind: .readout, rowID: rowID))
    }

    /// 固定列：`EmptyView` + `.frame` 会被 SwiftUI 丢掉（288 的 hosted 读数里那些列塌成 0），
    /// 所以宽度长在一块透明矩形上，内容作为 overlay 挂上去。
    private func column<Content: View>(_ content: Content, width: CGFloat,
                                       alignment: Alignment,
                                       kind: ExportRowGridProbe.Kind) -> some View {
        Color.clear
            .frame(width: width, height: ExportRowGrid.rowHeight)
            .overlay(alignment: alignment) { content }
            .background(ExportRowGridProbeHost(kind: kind, rowID: rowID))
    }
}

/// 302 —— 一个折叠段：标题行 24（三角 12×12 + 标题 + 收起时的摘要），展开后是 8 pt 间距的行。
///
/// 收起的段**不建**子行（`if isExpanded`），所以首屏只有标题 —— 这是「一屏 7 行 + 3 折叠段」
/// 能被量出来的原因。
struct ExportCollapsibleSection<Rows: View>: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let toggle: () -> Void
    let rows: Rows

    init(_ title: String, summary: String, isExpanded: Bool,
         toggle: @escaping () -> Void, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.summary = summary
        self.isExpanded = isExpanded
        self.toggle = toggle
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: ExportRowGrid.disclosureSize,
                               height: ExportRowGrid.disclosureSize)
                    Text(title)
                        .font(.system(size: ExportRowGrid.Font.sectionHeader, weight: .semibold))
                        .kerning(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    if !isExpanded {
                        Text(summary)
                            .font(.system(size: ExportRowGrid.Font.hint))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: ExportRowGrid.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ExportRowGridProbeHost(kind: .header, rowID: title))

            if isExpanded {
                VStack(alignment: .leading, spacing: ExportRowGrid.rowSpacing) {
                    rows
                }
                .padding(.top, ExportRowGrid.headerToRows)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, ExportRowGrid.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 数值行 / 色调映射行的探针（288 / 217 / 243 的读数手段，302 继续用）

/// 168 §1 —— 色调映射行自己的定位锚。`ExportLayoutProbe.Kind` 在 `ExportHDRControls.swift`
/// 里（本任务的改动范围之外），所以这一行带一个自己的小标记。
final class ExportToneMappingRowProbe: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

struct ExportToneMappingRowProbeHost: NSViewRepresentable {
    func makeNSView(context: Context) -> ExportToneMappingRowProbe {
        ExportToneMappingRowProbe()
    }

    func updateNSView(_ probe: ExportToneMappingRowProbe, context: Context) {}
}

/// 217 —— 数值行的布局锚。SwiftUI 的 `Slider` 在 hosted `swift test` 里既没有 AppKit 叶子也
/// 没有 accessibility 节点，透明背景探针是唯一诚实的读数方式。
final class ExportSliderRowProbe: NSView {
    enum Kind: String {
        case slider
        case number
        case unit
        /// 250 —— 勾选框自己的 frame（定位用，不是控件）：窗口测试把真实鼠标事件打在这个矩形里。
        case toggle
    }

    private(set) var kind: Kind = .slider
    private(set) var rowID = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("ExportSliderRowProbe is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(kind: Kind, rowID: String) {
        self.kind = kind
        self.rowID = rowID
    }
}

struct ExportSliderRowProbeHost: NSViewRepresentable {
    var kind: ExportSliderRowProbe.Kind
    var rowID: String

    func makeNSView(context: Context) -> ExportSliderRowProbe {
        let probe = ExportSliderRowProbe()
        probe.update(kind: kind, rowID: rowID)
        return probe
    }

    func updateNSView(_ probe: ExportSliderRowProbe, context: Context) {
        probe.update(kind: kind, rowID: rowID)
    }
}
