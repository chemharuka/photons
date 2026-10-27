import AppKit

/// 顶栏右端那一块状态文本 —— 一条线上的**四段**，从左到右：
///
///     `已选 4`  ·  `45 张`  ·  `photons-demo`  ·  `498331f`
///
/// 版本号永远在最右（用户 2026-10-27 的原话：顺序为「已选xxx，xxx张，库名称，构建号/版本号」，
/// 右对齐、给库名一个宽度上限、**不要**强制固定锚点）。四段同字号、同字重、同颜色、同一基线。
///
/// 四条设计约束，全是可测的数字：
///
/// 1. **同一套字**。四段都是 `Metrics.font`（10 pt medium，等宽数字）、`Metrics.textColor`
///    （`secondaryLabelColor`）、`Metrics.lineHeight`（14 pt）行高、同一个 `minY`。
///    等宽数字让 `1 → 12 → 999` 不改变字宽。
/// 2. **从右往左按实际宽度排，没有写死的 x**。`layout()` 只有一个游标：从 `bounds.width` 起，
///    每放一段就减去该段**当前文本**的宽度再减一个 `Metrics.gap`。段的位置是计算结果，
///    不是常量表 —— 所以计数变化只影响那一段自己的宽度，右边缘（`bounds.width`）一寸不动。
/// 3. **右边缘固定、库名有宽度上限**。整簇的右边缘钉在窗口右边 −16 pt（`trailingInset`，
///    由 `WorkspaceRootView` 摆放）。库名那一带的预算：
///
///        nameBudget = min(Metrics.nameMaxWidth, 可用宽度 − 已选 − 张 − 版本号 − 3 × gap)
///
///    可用宽度 = `min(检查器列宽, 顶栏给的 limit) − trailingInset`，所以检查器 300 pt 时
///    四段总宽 ≤ 300（实际 ≤ 284）**且没有任何一段被裁**。`nameMaxWidth = 180` 的理由：
///    默认检查器 330 pt 下这条预算算出 184.2 pt，180 正好在它以内 —— 也就是说默认窗口里
///    ≤180 pt（约 30 个半角字符）的库名一个字都不截，窄检查器再按比例收。
/// 4. **只有库名会被截**，而且是**中间省略**（`photons…26-10-27`），全名进 tooltip；
///    两个计数与版本号永远按自身实际宽度完整显示。极端窄的窗口（连 40 pt 库名都放不下）时
///    整块让位：`width(limit:)` 返回 0，顶栏把它藏起来，而不是压到按钮上。
///
/// **"最右字符被吞"的成因（实测，不是猜）**：旧实现让末段的 frame 宽度**等于**文本 advance
/// （`NSString.size(withAttributes:)`），而 `NSTextFieldCell` 右对齐绘制时把行宽按整点取整，
/// 最后一个字形的墨迹于是落到 frame 之外、被 `.byClipping` 切掉。把 label 画进位图实测
/// `498331f`：frame 43.3138 = 文本 43.3138 时，最右墨迹停在距框右边缘 8.63 device px 处
/// （≈4.3 pt，整个 'f' 没了）；frame 加 1.69 pt 后墨迹顶到边缘、墨点数 593 → 657。
/// 所以这里每段 frame = `ceil(advance) + textSlack(1 pt)`：多出来的那一点在**左边**（右对齐），
/// 视觉右边缘不动，末字形完整。
public final class TopBarStatusCluster: NSView {

    public enum Metrics {
        public static let fontSize: CGFloat = 10
        public static let fontWeight: NSFont.Weight = .medium
        /// 四段共用的一行高度；顶栏把它居中在 36 pt 里。
        public static let lineHeight: CGFloat = 14
        /// 段与段之间的固定间距。四段比旧的三段多一个 gap，所以从 16 收到 12：
        /// 默认检查器 330 pt 下留出上面算的 184.2 pt 库名预算。
        public static let gap: CGFloat = 12
        /// 最右一段（版本号）的右边缘到窗口右边的距离 = 顶栏右边距。
        public static let trailingInset: CGFloat = 16
        /// 簇的左边缘与顶栏最后一个可交互控件之间至少留这么宽。
        public static let minimumGapFromControls: CGFloat = 16
        /// 数字补到几位（`999`）：比现实里的库多一位，框宽因此与计数无关。
        public static let countDigits = 3
        public static let selectionDigits = 3
        /// 库名那一段的宽度上限（见类型注释里 180 的由来）。
        public static let nameMaxWidth: CGFloat = 180
        /// 库名的下限：连它都放不下就整块让位（`width(limit:)` 返回 0）。
        public static let minimumNameWidth: CGFloat = 40
        /// 每段 frame 比文本 advance 多出来的那一点（见类型注释里"最右字符被吞"的实测）。
        public static let textSlack: CGFloat = 1

        public static let font: NSFont = .monospacedDigitSystemFont(ofSize: fontSize, weight: fontWeight)
        public static let textColor: NSColor = .secondaryLabelColor
        /// U+2007 FIGURE SPACE — 与数字同宽的空白（SF 里实测 6.5682 pt，和 `0` 完全一致）。
        public static let figureSpace = "\u{2007}"
        public static let ellipsis = "…"

        /// 文本的 advance 宽度（`NSTextFieldCell` 排版用的同一个度量）。
        public static func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        /// 一段的 frame 宽度：整点向上取整 + `textSlack`。必须**严格大于** advance，
        /// 否则右对齐的 cell 会把最后一个字形切掉（见类型注释）。
        public static func frameWidth(for text: String) -> CGFloat {
            ceil(width(text)) + textSlack
        }

        /// `45` → `  45` 之类，用 figure space 左补到 `digits` 位；位数已够就原样返回。
        public static func padded(_ value: Int, digits: Int) -> String {
            let text = String(value)
            guard text.count < digits else { return text }
            return String(repeating: figureSpace, count: digits - text.count) + text
        }

        /// 中间省略：`photons-demo.photonslibrary.backup-2026-10-27` + 96 pt →
        /// `photons-demo.ph…up-2026-10-27`。放得下就原样返回；连一个省略号都放不下就返回空串。
        public static func middleTruncated(_ text: String, maxWidth: CGFloat) -> String {
            guard width(text) > maxWidth else { return text }
            guard width(ellipsis) <= maxWidth else { return "" }
            let chars = Array(text)
            guard chars.count > 2 else { return ellipsis }
            // 头尾各留一半，逐步少留一个字，直到放得下。
            for keep in stride(from: chars.count - 1, through: 1, by: -1) {
                let headCount = (keep + 1) / 2
                let tailCount = keep - headCount
                let candidate = String(chars[0..<headCount]) + ellipsis
                    + String(chars[(chars.count - tailCount)...])
                if width(candidate) <= maxWidth { return candidate }
            }
            return ellipsis
        }
    }

    /// 四段的框宽（`layout()` 与 `width(limit:)` 共用同一份计算）。
    public struct SegmentWidths: Equatable {
        public var selection: CGFloat = 0
        public var count: CGFloat = 0
        public var name: CGFloat = 0
        public var revision: CGFloat = 0
        /// 四段 + 三个 gap。
        public var total: CGFloat {
            guard selection > 0 else { return 0 }
            return selection + count + name + revision + 3 * Metrics.gap
        }
    }

    // 顺序即从左到右：已选 → 张数 → 库名 → 版本号。
    public let selectionLabel: NSTextField
    public let countLabel: NSTextField
    public let nameLabel: NSTextField
    public let revisionLabel: NSTextField

    /// 检查器列的宽度 —— 库名预算的起点。由 `WorkspaceRootView.layout()` 从
    /// `WorkspaceGeometry.inspector.width` 灌进来。
    public var columnWidth: CGFloat = 330 {
        didSet { if columnWidth != oldValue { needsLayout = true } }
    }

    /// 顶栏允许簇占据的最大宽度（把簇挡在可交互控件右边）。默认不限。
    public var widthLimit: CGFloat = .greatestFiniteMagnitude {
        didSet { if widthLimit != oldValue { needsLayout = true } }
    }

    private var libraryName: String?
    private var revision = BuildStamp.revision

    public override var isFlipped: Bool { true }

    public init() {
        selectionLabel = Self.makeLabel()
        countLabel = Self.makeLabel()
        nameLabel = Self.makeLabel()
        revisionLabel = Self.makeLabel()
        super.init(frame: .zero)
        for label in [selectionLabel, countLabel, nameLabel, revisionLabel] {
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
        label.cell?.truncatesLastVisibleLine = false
        return label
    }

    // MARK: content

    /// 库名（未命名时为 `未打开库`）：只有它会被截断，全名永远在 tooltip 里。
    public var fullName: String {
        (libraryName?.isEmpty == false) ? libraryName! : "未打开库"
    }

    public func update(assetCount: Int, selectionCount: Int, libraryName: String?) {
        self.libraryName = libraryName
        revision = BuildStamp.revision
        selectionLabel.stringValue = "已选 \(Metrics.padded(selectionCount, digits: Metrics.selectionDigits))"
        countLabel.stringValue = "\(Metrics.padded(assetCount, digits: Metrics.countDigits)) 张"
        revisionLabel.stringValue = revision
        nameLabel.stringValue = fullName
        nameLabel.toolTip = fullName
        revisionLabel.toolTip = revision
        needsLayout = true
    }

    // MARK: layout

    /// 四段的框宽。计数与版本号是自己的实际宽度；库名是
    /// `min(nameMaxWidth, 预算)`，预算里已经扣掉另外三段与三个 gap。
    public func segmentWidths(limit: CGFloat = .greatestFiniteMagnitude) -> SegmentWidths {
        let selection = Metrics.frameWidth(for: selectionLabel.stringValue)
        let count = Metrics.frameWidth(for: countLabel.stringValue)
        let revision = Metrics.frameWidth(for: revisionLabel.stringValue)
        let budget = nameWidthLimit(limit: limit)
        // 连一个像样的库名都放不下：整块让位（顶栏看到宽度 0 就藏起来）。
        guard budget >= Metrics.minimumNameWidth else { return SegmentWidths() }
        let nameText = Metrics.middleTruncated(fullName, maxWidth: budget - Metrics.textSlack)
        return SegmentWidths(selection: selection,
                             count: count,
                             name: min(budget, Metrics.frameWidth(for: nameText)),
                             revision: revision)
    }

    /// 整块需要的宽度（`limit` 是顶栏给的硬上限）。
    public func width(limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        segmentWidths(limit: limit).total
    }

    /// 库名那一段**这一次**的宽度上限：
    /// `min(nameMaxWidth, 可用宽度 − 已选 − 张 − 版本号 − 3 × gap)`。
    /// 验收里要跟"实际库名宽"并列，所以它是公开的。
    public func nameWidthLimit(limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let selection = Metrics.frameWidth(for: selectionLabel.stringValue)
        let count = Metrics.frameWidth(for: countLabel.stringValue)
        let revision = Metrics.frameWidth(for: revisionLabel.stringValue)
        let available = min(columnWidth - Metrics.trailingInset,
                            limit.isFinite ? limit : .greatestFiniteMagnitude)
        let budget = min(Metrics.nameMaxWidth,
                         available - (selection + count + revision + 3 * Metrics.gap))
        return max(0, budget)
    }

    public override func layout() {
        super.layout()
        let w = segmentWidths(limit: widthLimit)
        guard w.selection > 0 else { return }

        nameLabel.stringValue = Metrics.middleTruncated(fullName,
                                                        maxWidth: w.name - Metrics.textSlack)

        // 从右往左，按各段**实际**宽度排。右边缘就是 `bounds.width`，
        // 任何一个坐标都不是写死的常量。
        let y = ((bounds.height - Metrics.lineHeight) / 2).rounded()
        var right = bounds.width
        for (label, width) in [(revisionLabel, w.revision),
                               (nameLabel, w.name),
                               (countLabel, w.count),
                               (selectionLabel, w.selection)] {
            label.frame = NSRect(x: right - width, y: y, width: width, height: Metrics.lineHeight)
            right -= width + Metrics.gap
        }
    }
}
