import AppKit

/// 顶栏右端那一块状态文本：`45 张` → 间距 → `已选 4` → 间距 → `photons-demo dev`。
///
/// 用户 2026-10-27 的说法：右上角原来有三段文本，颜色/字重/高度各不相同（10 pt medium 的
/// `secondaryLabelColor` 和 10 pt regular 的 `tertiaryLabelColor`），而且 `45 张` 落在检查器
/// 列的左边。要的是**一块**：同字号同字重同颜色、右对齐、整块压在检查器列上方，三段之间是
/// 一个常量间距（`Metrics.gap`）。这里就是那一块。
///
/// 三条设计约束，都是"数字"而不是形容词：
///
/// 1. **同一种字**。三段都用 `Metrics.font`（10 pt、medium、等宽数字）和
///    `Metrics.textColor`（`secondaryLabelColor`），行高 `Metrics.lineHeight`，同一个 `minY`。
///    等宽数字是为了让 `1 → 12 → 999` 不改变字宽（比例数字会让计数自己抽动）。
/// 2. **边不动**。照片数和已选都左补 U+2007 FIGURE SPACE 到固定位数（`Metrics.countDigits` /
///    `Metrics.selectionDigits`），所以它们的**框宽是常量**；库名那一栏的宽度由检查器列宽算出，
///    也与计数无关。于是三段的六条边在计数变化时一个都不动，动的只有框里的字形。
/// 3. **落在检查器列上方**。最右一段的右边缘钉在 `trailingInset`（= 顶栏右边距 16 pt），
///    库名那一栏的可用宽度 = 检查器列宽 − `trailingInset` − 前两段的框宽 − 两个间距。放不下
///    就**尾部省略**（省略号在库名之后、版本号之前，版本号始终可见），全名进 tooltip。
///    极端窄的窗口（簇连"…+版本号"都放不下）时整块让位，留给顶栏的可交互控件——
///    `width(limit:)` 返回 0，`TopBarView` 会把它藏起来，而不是压到按钮上。
public final class TopBarStatusCluster: NSView {

    public enum Metrics {
        public static let fontSize: CGFloat = 10
        public static let fontWeight: NSFont.Weight = .medium
        /// 三段共用的一行高度；`TopBarView` 把它居中在 36 pt 顶栏里（y = 11）。
        public static let lineHeight: CGFloat = 14
        /// 三段之间的固定间距（与顶栏其它间距同量级：按钮 10 pt、分隔线 11 pt）。
        public static let gap: CGFloat = 16
        /// 最右一段的右边缘到窗口右边的距离 = 顶栏右边距。
        public static let trailingInset: CGFloat = 16
        /// 簇的左边缘与顶栏最后一个可交互控件之间至少留这么宽。
        public static let minimumGapFromControls: CGFloat = 16
        /// 数字补到几位（`9999`）：比现实里的库多一位，框宽因此是常量。
        public static let countDigits = 3
        public static let selectionDigits = 3
        /// 库名那一栏的下限。低于这个宽度时整块状态让位（见 `width(limit:)`）。
        public static let minimumIdentityWidth: CGFloat = 72

        public static let font: NSFont = .monospacedDigitSystemFont(ofSize: fontSize, weight: fontWeight)
        public static let textColor: NSColor = .secondaryLabelColor
        /// U+2007 FIGURE SPACE — 与数字同宽的空白（SF 里实测 6.5682 pt，和 `0` 完全一致）。
        public static let figureSpace = "\u{2007}"

        public static func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        /// `45` → `  45` 之类，用 figure space 左补到 `digits` 位；位数已够就原样返回。
        public static func padded(_ value: Int, digits: Int) -> String {
            let text = String(value)
            guard text.count < digits else { return text }
            return String(repeating: figureSpace, count: digits - text.count) + text
        }
    }

    public let countLabel: NSTextField
    public let selectionLabel: NSTextField
    public let identityLabel: NSTextField

    /// 检查器列的宽度 —— 库名那一栏的宽度预算是从这里推的。由 `WorkspaceRootView.layout()`
    /// 从 `WorkspaceGeometry.inspector.width` 灌进来。
    public var columnWidth: CGFloat = 330 {
        didSet { if columnWidth != oldValue { needsLayout = true } }
    }

    /// 簇允许占据的最大宽度（顶栏用它把簇挡在可交互控件右边）。默认不限。
    public var widthLimit: CGFloat = .greatestFiniteMagnitude {
        didSet { if widthLimit != oldValue { needsLayout = true } }
    }

    private var libraryName: String?
    private var revision = BuildStamp.revision
    /// 库名那一段**不省略**时的宽度；`0` 表示还没 `update` 过。
    private var preferredIdentityWidth: CGFloat = 0

    public override var isFlipped: Bool { true }

    public init() {
        countLabel = Self.makeLabel()
        selectionLabel = Self.makeLabel()
        identityLabel = Self.makeLabel()
        super.init(frame: .zero)
        for label in [countLabel, selectionLabel, identityLabel] {
            addSubview(label)
        }
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = Metrics.font
        label.textColor = Metrics.textColor
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    // MARK: content

    /// 三段文案。库名只在最右一段出现（`已选 N` 不再夹库名：那是旧布局把三件事塞进两行 label
    /// 的结果），全名永远在 tooltip 里。
    public func update(assetCount: Int, selectionCount: Int, libraryName: String?) {
        self.libraryName = libraryName
        revision = BuildStamp.revision
        countLabel.stringValue = "\(Metrics.padded(assetCount, digits: Metrics.countDigits)) 张"
        selectionLabel.stringValue = "已选 \(Metrics.padded(selectionCount, digits: Metrics.selectionDigits))"
        preferredIdentityWidth = Metrics.width(Self.fullIdentityText(libraryName: libraryName,
                                                                     revision: revision))
        identityLabel.toolTip = Self.fullIdentityText(libraryName: libraryName, revision: revision)
        needsLayout = true
    }

    /// `photons-demo dev` / `未打开库 dev`。
    public static func fullIdentityText(libraryName: String?, revision: String) -> String {
        let name = (libraryName?.isEmpty == false) ? libraryName! : "未打开库"
        return "\(name) \(revision)"
    }

    /// 在 `maxWidth` 内放得下的最右一段文本：放不下就截库名（尾部省略），版本号始终保留。
    public static func identityText(libraryName: String?, revision: String, maxWidth: CGFloat) -> String {
        let full = fullIdentityText(libraryName: libraryName, revision: revision)
        guard Metrics.width(full) > maxWidth else { return full }

        let name = (libraryName?.isEmpty == false) ? libraryName! : "未打开库"
        let suffix = " " + revision
        let ellipsis = "…"
        let budget = maxWidth - Metrics.width(suffix) - Metrics.width(ellipsis)
        guard budget > 0 else {
            return Metrics.width(revision) <= maxWidth ? revision : ""
        }
        var trimmed = name
        while !trimmed.isEmpty && Metrics.width(trimmed) > budget {
            trimmed.removeLast()
        }
        let candidate = trimmed + ellipsis + suffix
        if Metrics.width(candidate) <= maxWidth { return candidate }
        return Metrics.width(revision) <= maxWidth ? revision : ""
    }

    // MARK: layout

    /// 三段的框宽。`count` 与 `selection` 靠 figure space 补位，所以是常量；`identity` 是
    /// `min(全名宽度, 检查器列预算, 顶栏上限)`。
    private func parts(limit: CGFloat) -> (count: CGFloat, selection: CGFloat, identity: CGFloat) {
        let count = Metrics.width(countLabel.stringValue)
        let selection = Metrics.width(selectionLabel.stringValue)
        let fixed = count + Metrics.gap + selection + Metrics.gap
        let columnRoom = max(0, columnWidth - Metrics.trailingInset - fixed)
        let limitRoom = limit.isFinite ? max(0, limit - fixed) : .greatestFiniteMagnitude
        let room = min(columnRoom, limitRoom)
        // 连"…+版本号"都塞不进去：整块让位（`TopBarView` 看到 0 就藏起来），而不是压到按钮上。
        guard room >= Metrics.minimumIdentityWidth else { return (0, 0, 0) }
        return (count, selection, max(0, min(preferredIdentityWidth, room)))
    }

    /// 整块需要的宽度（`limit` 是顶栏给的硬上限）。
    public func width(limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let p = parts(limit: limit)
        guard p.count > 0 else { return 0 }
        return p.count + Metrics.gap + p.selection + Metrics.gap + p.identity
    }

    public override func layout() {
        super.layout()
        let p = parts(limit: widthLimit)
        guard p.count > 0 else { return }

        identityLabel.stringValue = Self.identityText(libraryName: libraryName,
                                                      revision: revision,
                                                      maxWidth: p.identity)

        // 右对齐：最右一段钉在右边缘上，其余只向左生长，间距恒为 `Metrics.gap`。
        let lineHeight = Metrics.lineHeight
        let y = ((bounds.height - lineHeight) / 2).rounded()
        var right = bounds.width
        for (label, width) in [(identityLabel, p.identity),
                               (selectionLabel, p.selection),
                               (countLabel, p.count)] {
            label.frame = NSRect(x: right - width, y: y, width: width, height: lineHeight)
            right -= width + Metrics.gap
        }
    }
}
