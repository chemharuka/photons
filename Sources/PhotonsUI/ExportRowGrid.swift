import AppKit
import CoreText
import SwiftUI

/// 335 — 导出面板的**两列**栅格（302 的三列，去掉右侧那条独立「读数列」）。
///
/// 302 / 322 的形状是三列：
///
///     [padding 20] [label 110 trailing] [gap 8] [control 286] [gutter 8] [readout 108] [padding 20]
///
/// 用户在 335 里要的是「右侧没有额外列，主列的宽度对齐到右侧去」：读数列被取消，读数变成主列
/// **内部**的一段 —— 数值行左起、单位紧跟（PPI），或者值+单位贴着主列右沿（百分数 / px）。于是
/// 只剩两条列线：
///
///     [padding 20] [label 110 trailing] [gap 8] [main 402 → 右沿 540] [padding 20] [gutter 16 → 576]
///
/// 标签右沿 130 与主列起点 138 是 302 的实测值，一个不动；控件右沿从 424 长到 540，于是
/// **424 那条中间线消失**（这正是 335 的可判定形式）。
///
/// 388 —— 最右边那 16 是 `scrollerGutter`：面板 560 → 576，内容是 0…540 不动。overlay 式滚动
/// 指示条画在面板右缘、不占布局宽度，所以这段留白必须在**面板**上加，不能从内容里挤。
///
/// 行高 24 / 行距 8 → **pitch 32，只有这一种**；节与节之间额外 16，节标题 24，标题到首行 8。
enum ExportRowGrid {

    // MARK: 面板

    /// 滚动指示条要让出的宽度。macOS 默认是 overlay 式 scroller：它**画在内容之上、不占布局宽度**，
    /// 所以只把内容铺到面板边是不够的 —— 指示条会压在读数（百分数 / px）右沿上。
    static let scrollerGutter: CGFloat = 16

    /// 576 —— sheet 固定宽（`ExportSheetController.present` 也按这个宽度开窗），不再随窗口。
    ///
    /// 560 是**内容**宽度（左 padding 20 + 内容 520 + 右 padding 20），右侧再加 `scrollerGutter` 16
    /// 是给 overlay 指示条的留白。见 `contentRight` 的注释：加宽的是面板，不是内容。
    static let panelWidth: CGFloat = 560 + scrollerGutter
    static let horizontalPadding: CGFloat = 20
    /// 内容区右 padding（左侧同宽 20）：panelWidth − padding − gutter。
    static var trailingPadding: CGFloat { horizontalPadding + scrollerGutter }
    /// 388 —— 滚动区右缘与面板右缘之间的视觉留白。
    ///
    /// overlay 式指示条贴的是**它自己那个 `NSScrollView` 的右缘**（实测：ScrollView 右沿 540 时
    /// 指示条落在 523…540），不是面板右缘。所以要让指示条离开内容，ScrollView 必须伸到面板边上；
    /// 这里只留 4 pt 免得指示条贴着窗口边。
    static let scrollerEdgeInset: CGFloat = 4
    /// 388 —— 滚动区的「破出量」= 内容缩进量。ScrollView 向右破出 `trailingPadding − scrollerEdgeInset`
    /// （= 32），它内部的滚动内容再缩进同样多，两者成对抵消 —— 于是 540 这条右沿一动不动。
    static var scrollerBleed: CGFloat { trailingPadding - scrollerEdgeInset }
    /// 内容自适应上限。
    static let contentMaxHeight: CGFloat = 640

    // MARK: 两列

    /// 标签列，右对齐。
    ///
    /// 322 量过整张表的标签（三段全展开、20 行）：最长的是「水印不透明度」71.5 pt，加上勾选框
    /// 自己的盒子（16 + 4 + 文字，见 `toggleBoxWidth`）最宽的「写入 XMP」也只 78 —— 110 有 32 pt
    /// 的余量。所以**不加宽标签列**：标签右沿 130 是 302 的实测值，不能动。
    static let labelWidth: CGFloat = 110
    /// 标签右沿到主列左沿。
    static let gap: CGFloat = 8
    /// 主列宽 = 520 − 110 − 8 = 402，右沿落在 560 − 20 = 540。
    ///
    /// 335：286 → 402。多出来的 116 全部来自被取消的读数列（108）与它两侧的走道，
    /// 所以**控件右沿 424 不再存在** —— 滑杆、文本框、路径都长到 540 这条线上。
    static var controlWidth: CGFloat { contentWidth - labelWidth - gap }
    /// 数值框的宽度（288 的 46，保持不变，免得同类型控件换位）。
    static let valueWidth: CGFloat = 46
    /// 数值框与它右侧单位的间距（302 是 4；335 单位不再占固定列，8 才不会和数字粘在一起）。
    static let readoutGap: CGFloat = 8

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

    /// 288 §2.2 —— 滑杆不传 `step:`，所以没有刻度。
    ///
    /// 335：滑杆不再写死 140，而是吃掉主列里读数留下之后的所有宽度（左沿 138、右沿 = 百分数左沿 − 8）。
    /// 140 现在是**下限**，不是宽度。
    static let sliderWidth: CGFloat = 140
    static let sliderTickMarks = 0

    // MARK: 推导出的锚点（测试读的就是这些）

    /// 内容宽 = 540 − 20 = 520。**不读 `panelWidth`**：面板加宽（给指示条）不改变内容宽。
    static var contentWidth: CGFloat { contentRight - horizontalPadding }
    /// 标签右沿：20 + 110 = 130。（302 的注释写成 118 是笔误，实测一直是 130。）
    static var labelRight: CGFloat { horizontalPadding + labelWidth }
    /// 主列左沿：130 + 8 = 138。
    static var controlLeft: CGFloat { labelRight + gap }
    /// 主列右沿：138 + 402 = 540。**不再有 424。**
    static var controlRight: CGFloat { controlLeft + controlWidth }
    /// 内容右沿 / 主列右沿：**字面 540**，不再是 `panelWidth − horizontalPadding`。
    ///
    /// 388 —— 这个字面值是本单的关键，别"顺手改回推导式"：面板为给 overlay 滚动指示条让位而从
    /// 560 加宽到 576，如果右沿跟着 `panelWidth − padding` 变成 556，那么滑杆读数与百分数会**一起
    /// 右移 16 pt**，指示条仍旧压着它们 —— 加宽就白做了。540 是内容的右沿，560 是内容的宽度（= 20
    /// + 520 + 20），576 只是面板。三者关系：`contentRight == horizontalPadding + contentWidth`，
    /// 且 `panelWidth == contentWidth + horizontalPadding + trailingPadding`。
    static var contentRight: CGFloat { 540 }
    /// 行 pitch：24 + 8 = 32。
    static var rowPitch: CGFloat { rowHeight + rowSpacing }

    /// 322 —— 勾选框的点击框宽度，按**标签文字自己**量：16 的盒子 + 4 的间距 + 文字 + 4 的余量。
    ///
    /// 302 把它写死成 34，于是「不扩大」（55.8）、「写入 XMP」（73.9）、「移除位置」（67.7）、
    /// 「半尺寸」（55.8）、「PPI」（39.0）全被截成「…」。勾选框是行修饰，框要跟着自己的字走。
    static func toggleBoxWidth(for title: String) -> CGFloat {
        toggleTextLead + ceil(textWidth(title)) + toggleTrailingSlack
    }

    /// 勾选框里文字相对点击框左沿的偏移（16 的盒子 + 4 的间距）。
    static let toggleTextLead: CGFloat = 20
    /// 322 给点击框留的右侧余量。它同时是「文字墨迹到标签列右沿」那段可见空隙的一半 ——
    /// 335 把这段也算进墨迹修正里（见 `labelInkShift`）。
    static let toggleTrailingSlack: CGFloat = 4

    /// 同一字号同一字重下这段文字的行宽（advance）。
    static func textWidth(_ text: String, size: CGFloat = Font.label,
                          weight: NSFont.Weight = .medium) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 335 —— 标签的**右侧 side bearing**：advance 宽减去墨迹（glyph outline）右沿。
    ///
    /// 用户看到的「PPI 没右对齐」不是文本框没对齐，而是 `I` 的墨迹右边并不贴 advance box 右边：
    /// 把文本框右沿对到 130 之后，`I` 右边还差一条缝。所以对齐的是**墨迹**：
    /// 文本往右挪一个 bearing，墨迹右沿才落到 130。
    ///
    /// 用 CoreText 的 glyph path bounds 量，不用常量凑：`I`/`F`/`1` 这类窄字形 bearing 大，
    /// 汉字几乎为 0 —— 这也正是「改了 PPI 不许把「质量」「不透明度」搞乱」能成立的原因。
    static func labelInkInset(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: Font.label, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        return max(0, advance - ink.maxX)
    }

    /// 335 —— 标签要**往右**挪多少，墨迹右沿才落在 `labelRight` 上。
    ///
    /// 文字标签：文本的 advance box 在列右沿，墨迹还差一段 bearing，所以挪 bearing。
    /// 勾选框：335 让它自己的文字在点击框里右对齐（见 `rowToggle`），于是同样的规则 ——
    /// 也只挪 bearing。`checkbox` 参数保留给读数用（探针记的是「这个标签是不是勾选框」）。
    static func labelInkShift(for text: String, checkbox: Bool = false) -> CGFloat {
        labelInkInset(for: text)
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
        /// 335：行内按钮（「存到」行的换路径按钮）。探针贴在按钮自己的 frame 上 ——
        /// 量的是布局真给按钮的宽，不是文字的宽。
        case button
        /// 335：标签文字的**文本框**（advance box）。墨迹右沿 = 这框的右沿 − 该字的右侧 bearing，
        /// 所以这条探针的右沿允许超过 130（用户口径：文本框可以出头，墨迹必须齐）。
        case labelInk
    }

    private(set) var kind: Kind = .row
    private(set) var rowID = ""
    /// `.labelInk` 量的是哪一个字符串（墨迹 bearing 由它算，不写常量）。
    private(set) var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("ExportRowGridProbe is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(kind: Kind, rowID: String, text: String = "") {
        self.kind = kind
        self.rowID = rowID
        self.text = text
    }
}

struct ExportRowGridProbeHost: NSViewRepresentable {
    var kind: ExportRowGridProbe.Kind
    var rowID: String
    var text: String = ""

    func makeNSView(context: Context) -> ExportRowGridProbe {
        let probe = ExportRowGridProbe()
        probe.update(kind: kind, rowID: rowID, text: text)
        return probe
    }

    func updateNSView(_ probe: ExportRowGridProbe, context: Context) {
        probe.update(kind: kind, rowID: rowID, text: text)
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

/// 335 —— 读数在**主列内部**的落位。302 的第三列（读数块）被取消，读数只剩两种排版。
enum ExportReadoutPlacement {
    /// 没有读数（大多数行）：控件占满主列。
    case none
    /// 读数紧跟控件左边起排 —— PPI：输入框在 138，单位「像素/英寸」随后。
    case inline
    /// 读数贴主列右沿（540）—— 百分数 / px 的值 + 单位。
    case trailing
}

/// 302 —— 面板的一行：标签列 + 主列，宽度固定，空列也占位。
///
/// 335：标签右沿 130、主列左沿 138、主列右沿 540。**只有两条列线**（302 的第三条线 424 已随
/// 读数列一起消失）：每一行的控件都长到 540，读数作为主列内部的一段贴右沿。
struct ExportRowGridRow<Label: View, Control: View, Value: View, Unit: View, Accessory: View>: View {
    let rowID: String
    let label: Label
    let control: Control
    let value: Value
    let unit: Unit
    let accessory: Accessory
    let readout: ExportReadoutPlacement

    init(rowID: String,
         readout: ExportReadoutPlacement = .none,
         @ViewBuilder label: () -> Label,
         @ViewBuilder control: () -> Control,
         @ViewBuilder value: () -> Value,
         @ViewBuilder unit: () -> Unit,
         @ViewBuilder accessory: () -> Accessory) {
        self.rowID = rowID
        self.readout = readout
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
            mainColumn
        }
        // 322 —— 两行行（长说明）按内容长高；单行的行仍然正好 24。
        .frame(minHeight: ExportRowGrid.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportRowGridProbeHost(kind: .row, rowID: rowID))
    }

    /// 主列：138 起、540 止。读数是它内部的一段，不再是右侧的一列。
    private var mainColumn: some View {
        HStack(spacing: 0) {
            switch readout {
            case .none:
                controlBlock(flexible: true)
            case .inline:
                controlBlock(flexible: false)
                readoutBlock
                Spacer(minLength: 0)
            case .trailing:
                controlBlock(flexible: true)
                Color.clear.frame(width: ExportRowGrid.readoutGap)
                readoutBlock
            }
        }
        .frame(width: ExportRowGrid.controlWidth, alignment: .leading)
        .background(ExportRowGridProbeHost(kind: .control, rowID: rowID))
    }

    private func controlBlock(flexible: Bool) -> some View {
        control
            .frame(maxWidth: flexible ? .infinity : nil, alignment: .leading)
            .overlay(alignment: .trailing) { accessory }
    }

    /// 读数：值 46（右对齐）+ 8 + 单位（自然宽，右对齐）。
    ///
    /// 单位不再占固定列 —— 335 之前是 58 宽的「单位列」，`%` 在 58 里左对齐，于是百分数离右沿
    /// 还有 50 pt 空白；现在单位自己贴到 540，`85 %` 的 `%` 就是主列的右沿。
    private var readoutBlock: some View {
        HStack(spacing: ExportRowGrid.readoutGap) {
            value
                .frame(width: ExportRowGrid.valueWidth, height: ExportRowGrid.rowHeight,
                       alignment: .trailing)
                .background(ExportRowGridProbeHost(kind: .value, rowID: rowID))
            unit.background(ExportRowGridProbeHost(kind: .unit, rowID: rowID))
        }
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
