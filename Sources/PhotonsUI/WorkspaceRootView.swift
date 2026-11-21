import PhotonsLocalization
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore

// MARK: - 205 · the newer-document notice (one line, not a banner)

/// The single sentence shown when the open document came from a build with a higher
/// `schemaVersion`, plus the two metrics that keep it a *notice* rather than chrome.
///
/// It exists as its own type so the text can be asserted without a window: the version is the only
/// variable, and `nil` — the case for every document this build writes — must produce no text at all
/// (the view then hides the label, which is what keeps the acceptance's "nil ⇒ zero pixels changed").
public enum ForwardCompatNotice {
    /// 10 pt, matching `TopBarStatusCluster.Metrics`: the smallest type already used for status text.
    public static let fontSize: CGFloat = 10
    public static let lineHeight: CGFloat = 14
    public static let font: NSFont = .systemFont(ofSize: fontSize)
    public static let textColor: NSColor = .secondaryLabelColor

    /// `该文件来自更新的版本 v14，未知设置已原样保留` — or `nil` when there is nothing to say.
    public static func text(for version: Int?) -> String? {
        guard let version else { return nil }
        return Loc.t("该文件来自更新的版本 v{0}，未知设置已原样保留", String(describing: (version)))
    }
}

// MARK: - tool button (§2b: 28 pt hit box, 26 pt paint, radius 7 continuous, 9 pt side padding)

public final class ToolButton: NSButton {
    /// 438 / 442 / 465 —— 顶栏所有按钮的图标用**同一个** symbol 配置：**12 pt / .regular**，
    /// 之后**不再做任何归一化**。
    ///
    /// 历史：442 为了「一排图标看着一样大」把每个字形的高度都缩放到 14 pt。这个基准选错了 ——
    /// 人眼判大小看的是外接足迹，不是高度。实测（12.25 pt 自然尺寸 → 高度归一 14）：
    /// `folder` 从 17×13 放大到 18×14（252 pt²），而 `square.stack.3d.down.right` 从 15×19
    /// 压到 11×14（154 pt²）、两个 `square.and.arrow.*` 压到 12×14（161–172 pt²）—— 高度齐了，
    /// 足迹反而差 1.6 倍，用户看到的就是「打开最大、导入/导出/后台小」。
    ///
    /// 现在回到 SF Symbols 自己的光学尺寸：同一 pointSize 下每个字形都是苹果设计的大小。
    /// 12 pt 下实测 footprint 182–285 pt²（打开 17×13、导入 14×16、导出 14×17、后台 15×19），
    /// 宽度差 14–17 pt，比高度归一后的 11–18 pt 收窄一半。
    public static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

    /// 顶栏图标的唯一入口：只套配置（不缩放），模板化（跟随 labelColor）。
    public static func icon(_ symbol: String, accessibility: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) else {
            return nil
        }
        let configured = base.withSymbolConfiguration(symbolConfiguration) ?? base
        configured.isTemplate = true
        return configured
    }

    public var isActive = false { didSet { needsDisplay = true } }
    private var hovering = false

    public init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        self.image = Self.icon(symbol, accessibility: title)
        self.imageScaling = .scaleProportionallyDown
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 10.5, weight: .semibold)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        contentTintColor = .labelColor
        alignment = .center
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 10.5)])
        // 465 —— 图标宽**按字形实测**（12 pt 下 14–17 pt 不等）。以前这里是写死的 14，
        // 因为 442 的高度归一把所有图标都缩到 14 高；现在不归一化，写死 14 会让最宽的那颗
        // （导出/导入 17 pt）压进文字间距、末位内边距被吃掉。
        let imageWidth: CGFloat = image.map { $0.size.width.rounded() } ?? 0
        return NSSize(width: WorkspaceLayout.toolButtonPaddingH * 2 + imageWidth + text.width + 6,
                      height: WorkspaceLayout.toolButtonHit)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if isActive {
            color = NSColor.controlAccentColor.withAlphaComponent(0.14)
        } else if hovering {
            color = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            color = .clear
        }
        if color != .clear {
            let rect = bounds.insetBy(dx: 0, dy: 1)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: WorkspaceLayout.toolCornerRadius,
                         yRadius: WorkspaceLayout.toolCornerRadius).fill()
        }
        drawIconAndTitle()
    }

    /// 442 —— **自己画图标和标题**，不再让 `NSButtonCell` 摆。
    ///
    /// 为什么必须自己画：cell 会把「图标 + 标题」当成一条基线组来居中，而 SF Symbols 的
    /// **对齐矩形**（alignment rect）随字形不同（`folder` / `square.and.arrow.down` /
    /// `arrow.up.arrow.down` 各不相同），于是同一排里标题的 y 会差 0.25–1.5 px ——
    /// 实测（`cell.titleRect(forBounds:)`）：打开 8.00 / 胶片条 8.50 / 排序 8.25 /
    /// 导入 9.00 / 导出 9.50。用户看到的就是「导入导出偏低约 2 px、胶片条偏低约 1 px」。
    ///
    /// 这里只用两条固定公式：图标 `(bounds.height - icon.height)/2`、标题
    /// `(bounds.height - text.height)/2`，五个按钮逐点相同，与字形无关。
    /// 把 template 图标染成 `color`（保持 alpha 掩码，用来跟随明暗外观）。
    private func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    /// 442 —— 图标与标题的**唯一**几何：`draw` 用它画，测试用它断言「五个按钮的标题逐点同高」。
    /// 两条都是固定公式，与字形、宽度、字号无关；返回的 `title` 是文字行框（不是基线）。
    public func contentGeometry(in box: NSRect) -> (icon: NSRect?, title: NSRect) {
        var x = WorkspaceLayout.toolButtonPaddingH
        var iconRect: NSRect?
        if let icon = image {
            let size = icon.size
            let iy = ((box.height - size.height) / 2).rounded()
            iconRect = NSRect(x: x, y: iy, width: size.width, height: size.height)
            x += size.width + 6
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let ty = ((box.height - size.height) / 2).rounded()
        return (iconRect, NSRect(x: x, y: ty, width: size.width, height: size.height))
    }

    private func drawIconAndTitle() {
        let dimmed = !isEnabled
        let geometry = contentGeometry(in: bounds)
        if let icon = image, let rect = geometry.icon {
            // 442 —— template 图标自己画不会被 `contentTintColor` 着色（那只有 cell 画才生效），
            // 所以按当前外观把 `labelColor` / `disabledControlTextColor` 叠上去，
            // 否则明暗外观下图标一样亮（`SortOrderUITests` 的暗色断言会红）。
            let tint = tinted(icon, color: dimmed ? .disabledControlTextColor : .labelColor)
            tint.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                      respectFlipped: true, hints: nil)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: dimmed ? NSColor.disabledControlTextColor : NSColor.labelColor
        ]
        (title as NSString).draw(at: geometry.title.origin, withAttributes: attributes)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }
}

// MARK: - top bar (§2b: 36 pt container, no NSToolbar)

/// The tool strip, drawn by the app instead of `NSToolbar`.
///
/// The toolbar was dropped on purpose (§2b item 1): it cannot share a row with the traffic lights,
/// its buttons are 24 pt tall with system padding, and it owns its own item layout — three
/// mismatches with a Pixelmator-style shell. This container is 36 pt tall, centred on the traffic
/// lights, with 28 pt hit boxes and 1 × 18 pt separators between groups.
public final class TopBarView: NSView, NSPopoverDelegate {
    public var onOpen: (() -> Void)?
    public var onModeChange: ((CatalogSession.Mode) -> Void)?
    public var onToggleFilmstrip: (() -> Void)?
    public var onToggleBrowser: (() -> Void)?
    /// 442 —— 胶片条 / 侧栏这一对的点击：两者互斥，点哪个就切到哪个（`BrowserMode.list` = 侧栏）。
    public var onBrowserMode: ((BrowserMode) -> Void)?
    /// 排序按钮（`新→旧 / 旧→新`）。One click flips the order the grid, the browser and the strip read.
    public var onToggleSort: (() -> Void)?

    private let openButton = ToolButton(title: Loc.t("打开"), symbol: "folder")
    /// 文件 ▸ 导入照片… 的顶栏入口。**与菜单项同一个 selector、同一个 nil target**：走响应链到
    /// `EditorWindowController.importAction(_:)`，菜单将来加守卫时按钮自动跟着变。
    private let importButton = ToolButton(title: Loc.t("导入"), symbol: "square.and.arrow.down")
    /// 文件 ▸ 导出… 的顶栏入口，同上。
    private let exportButton = ToolButton(title: Loc.t("导出"), symbol: "square.and.arrow.up")
    /// 442 —— 「网格 / 单图」是**一个**按钮，写的是**当前模式**，点一下换到另一个 ——
    /// 与「排序」那颗（`新→旧` ⇄ `旧→新`）同一个行为。宽度按两者较宽的算，切换时顶栏不抖。
    static let gridSymbol = "square.grid.2x2"
    static let singleSymbol = "rectangle.portrait"
    private let modeButton = ToolButton(title: Loc.t("网格"), symbol: TopBarView.gridSymbol)
    /// 「胶片条 / 侧栏」也是**一个**按钮（与网格/单图同一个行为）：写当前形态，点一下换到另一个。
    static let filmstripSymbol = "rectangle.split.1x2"
    static let sidebarSymbol = "sidebar.left"
    private let browserButton = ToolButton(title: Loc.t("胶片条"), symbol: TopBarView.filmstripSymbol)

    /// 442 —— 按钮之间的间距（原 10 pt，用户口径「减少为现在的一半」）。
    static let itemGap: CGFloat = 5
    /// 分隔线两侧：进来 5、出去 6（原来是 10 / 11，同样减半取整）。
    static let separatorGapIn: CGFloat = 5
    static let separatorGapOut: CGFloat = 6
    /// 胶片条按钮右边那一个：同款 `ToolButton`、同高、10 pt 间距。
    ///
    /// 文字是**当前顺序**（`新→旧` / `旧→新`），图标是通用的 `arrow.up.arrow.down` 且不随方向变——
    /// 两处同时描述状态会互相打架，所以方向只由文字说一次（见 `PhotoSortOrder`）。
    private let sortButton = ToolButton(title: PhotoSortOrder.default.label, symbol: PhotoSortOrder.symbol)
    /// 454 P1 — 排序右侧的「后台」入口。它和排序之间还有一条分隔线（`排序 | 后台`）。
    private let backgroundButton = ToolButton(title: Loc.t("后台"),
                                               symbol: "square.stack.3d.down.right")
    /// 右上角那一块状态文本（已选 · 张数 · 库名 · 版本号），四段的字体/颜色/高度/顺序和
    /// 右对齐规则都在 `TopBarStatusCluster` 里，这里只负责把它钉在顶栏右边距上。
    public let statusCluster = TopBarStatusCluster()
    private var separators: [NSView] = []

    /// 454 P1 — the panel's model. P2a moved the single instance to `CatalogSession`; the workspace
    /// hands that same object in (`TopBarView(store:)`), and tests that build a bare bar get a fresh
    /// one by default. The popover and the header therefore cannot drift apart.
    public let backgroundTaskStore: BackgroundTaskStore
    private lazy var backgroundTasksPopoverController = BackgroundTasksPopover(store: backgroundTaskStore)
    private let backgroundTasksPopover = NSPopover()
    /// Test/`--ui-smoke` read: whether the popover was opened. Mirrors `isShown` whenever there is a
    /// window to anchor to (the FilterBar popovers use the same pattern).
    public private(set) var isBackgroundTasksPopoverOpen = false

    public var contentLeading: CGFloat = WorkspaceLayout.trafficLightsWidth + 10

    /// 检查器列的宽度：`statusCluster` 用它算库名那一栏的预算，好让整块落在检查器列上方。
    public var statusColumnWidth: CGFloat = WorkspaceLayout.inspectorWidthDefault {
        didSet { if statusColumnWidth != oldValue { needsLayout = true } }
    }

    /// 顶栏最后一个可交互控件的右边缘。公开给测试：簇的左边缘永远在它右边
    /// （`TopBarStatusCluster.Metrics.minimumGapFromControls` 之外），再长的库名也压不到按钮上。
    /// 454 P1 —— 「后台」排在排序右边，所以它是这一行最右的一个。
    public var controlsTrailingEdge: CGFloat { backgroundButton.frame.maxX }

    public override var isFlipped: Bool { true }

    public init(store: BackgroundTaskStore = BackgroundTaskStore()) {
        backgroundTaskStore = store
        super.init(frame: .zero)
        wantsLayer = true

        openButton.target = self
        openButton.action = #selector(openTapped)
        // 导入/导出 **不挂在自己的 `@objc` 方法上**：target 留 nil、action 就是菜单项那两个
        // selector，AppKit 顺着响应链找到窗口控制器，与文件菜单走同一条路。
        importButton.target = nil
        importButton.action = #selector(EditorWindowController.importAction(_:))
        importButton.toolTip = Loc.t("导入照片…") + "（⇧⌘I）"
        importButton.isEnabled = false
        exportButton.target = nil
        exportButton.action = #selector(EditorWindowController.exportAction(_:))
        exportButton.toolTip = Loc.t("导出…") + "（⇧⌘E）"
        exportButton.isEnabled = false
        sortButton.target = self
        sortButton.action = #selector(sortTapped)
        // 图标与邻居同一个配置（12 pt，不缩放），见 `ToolButton.symbolConfiguration`。
        sortButton.image = PhotoSortOrder.icon()

        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundTapped)

        modeButton.target = self
        modeButton.action = #selector(modeTapped(_:))
        browserButton.target = self
        browserButton.action = #selector(browserTapped(_:))

        backgroundTasksPopover.behavior = .transient
        backgroundTasksPopover.animates = false
        backgroundTasksPopover.delegate = self
        backgroundTasksPopover.contentViewController = backgroundTasksPopoverController

        for v: NSView in [openButton, importButton, exportButton, modeButton,
                          browserButton, sortButton, backgroundButton, statusCluster] {
            addSubview(v)
        }
        // 442 —— 顶栏第一条分隔线在导出之后；454 P1 在「排序 | 后台」之间加第二条。
        addSeparator()
        addSeparator()
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    private func addSeparator() {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        addSubview(line)
        separators.append(line)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // **不填底色**。这一条背后是 `HeaderGlassView` 的系统材质（`.headerView` / `.behindWindow`），
        // 也就是红绿灯所在的标题栏区域。以前这里填的 `windowBackgroundColor(0.96)` 是那块把玻璃
        // 架空的底板：按钮画在它上面，采样背景却被它挡死，原生按钮因此看着像自画的扁平圆点。
        // 这里只剩顶栏下沿的 1 pt 分隔线，画在材质之上（这一层不透明，但只有 1 pt、在按钮下方）。
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// 空白处不吃鼠标：顶栏只有按钮/分段控件/状态文本接事件，其余命中要落到窗口自己的窗体上
    /// （标题栏那条拖动、以及 `isMovableByWindowBackground == false` 的契约都靠这个）。
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public func update(mode: CatalogSession.Mode, assetCount: Int, selectionCount: Int,
                       libraryName: String?, filmstrip: Bool) {
        // 442 —— 按钮文字/图标 = **当前模式**（和排序按钮一样：显示现状，点一下换到另一边）。
        modeButton.title = mode == .grid ? Loc.t("网格") : Loc.t("单图")
        modeButton.image = ToolButton.icon(mode == .grid ? Self.gridSymbol : Self.singleSymbol,
                                           accessibility: modeButton.title)
        browserButton.title = filmstrip ? Loc.t("胶片条") : Loc.t("侧栏")
        browserButton.image = ToolButton.icon(filmstrip ? Self.filmstripSymbol : Self.sidebarSymbol,
                                              accessibility: browserButton.title)
        // 047: the corner carries the **build** revision, so a glance answers "is this the build with
        // my merge?" without going back to a commit list. Since 2026-10-27 the four facts are one
        // block of one type (`TopBarStatusCluster`), left to right:
        // `已选 4` · `45 张` · `photons-demo` · `498331f` — the version is always rightmost.
        // The library name is the only segment that truncates (middle ellipsis, full name in tooltip).
        statusCluster.update(assetCount: assetCount,
                             selectionCount: selectionCount,
                             libraryName: libraryName)
        needsLayout = true
    }

    /// 排序按钮的状态：文字 = 当前顺序，tooltip = 键 + 顺序。
    ///
    /// 只改字和 tooltip，**不改图标**（`arrow.up.arrow.down` 是静态的通用排序语义），也不给按钮加
    /// active 底色——「现在是什么顺序」已经在字里说清楚了，再加一处高亮就是第二个信号。
    /// 字宽会变（`新→旧` 与 `旧→新` 不等宽），所以这里必须重新布局，否则状态簇的右边界会留在旧宽度上。
    public func updateSortOrder(_ order: PhotoSortOrder) {
        sortButton.title = order.label
        sortButton.toolTip = order.tooltip
        needsLayout = true
    }

    /// 顶栏两个命令按钮的可用性。判据在 `WorkspaceRootView.canImport/canExport` **只写一份**，
    /// 菜单的 `validateMenuItem` 读同一对属性 —— 菜单灰 ⇔ 按钮灰。
    public func updateActions(canImport: Bool, canExport: Bool) {
        importButton.isEnabled = canImport
        exportButton.isEnabled = canExport
    }

    /// 排序按钮本体。测试要量它的 frame / 字体 / 图标，`--ui-smoke` 可以读它的字。
    public var sortButtonView: ToolButton { sortButton }
    /// 454 P1 —— 顶栏最右的「后台」按钮（`controlsTrailingEdge` 就是它的右边缘）。
    public var backgroundButtonView: ToolButton { backgroundButton }
    /// 454 P1 —— 两条分隔线：`[0]` 在导出之后，`[1]` 在排序与后台之间。
    public var separatorsForTesting: [NSView] { separators }
    /// 454 P1 —— 面板本体与它的 popover 外壳，供入口/空态测试读取。
    public var backgroundTasksPopoverControllerForTesting: BackgroundTasksPopover {
        backgroundTasksPopoverController
    }
    public var backgroundTasksPopoverForTesting: NSPopover { backgroundTasksPopover }
    /// 442 —— 排序刷新期间把按钮置灰（点击会被 `WorkspaceRootView` 丢弃）。
    public func setSortEnabled(_ enabled: Bool) { sortButton.isEnabled = enabled }
    /// 它左边那个邻居（胶片条）——「同款」是拿这两个按钮量出来的，不是形容词。
    /// 442 —— 兼容旧读数：顶栏现在只有一个「胶片条/侧栏」按钮。
    public var filmstripButtonView: ToolButton { browserButton }
    public var browserButtonView: ToolButton { browserButton }
    /// 442 —— 切换按钮的本体（测试量宽度/激活底色用）。
    public var modeButtonView: ToolButton { modeButton }

    /// 网格/单图那一个按钮的固定宽度（两者较宽者），测试据此断言「切换不抖」。
    public var modeButtonWidthForTesting: CGFloat { Self.modeWidth() }
    public var sortButtonWidthForTesting: CGFloat { Self.sortWidth() }
    public var browserButtonWidthForTesting: CGFloat { Self.browserWidth() }
    static func modeWidth() -> CGFloat {
        let a = ToolButton(title: Loc.t("网格"), symbol: gridSymbol)
        let b = ToolButton(title: Loc.t("单图"), symbol: singleSymbol)
        return max(a.intrinsicContentSize.width, b.intrinsicContentSize.width)
    }

    /// 442 —— 排序按钮（`新→旧` ⇄ `旧→新`）同样按**两者较宽者**定宽：它是同一个按钮换文字，
    /// 不固定的话每次切换顶栏都会抖一下。用户口径：「Olderst first 点击切换为 Newest first 目前也要统一宽度」。
    /// 442 —— 「胶片条/侧栏」那一个按钮的固定宽度（两者较宽者）。
    static func browserWidth() -> CGFloat {
        let a = ToolButton(title: Loc.t("胶片条"), symbol: filmstripSymbol)
        let b = ToolButton(title: Loc.t("侧栏"), symbol: sidebarSymbol)
        return max(a.intrinsicContentSize.width, b.intrinsicContentSize.width)
    }

    static func sortWidth() -> CGFloat {
        PhotoSortOrder.allCases
            .map { ToolButton(title: $0.label, symbol: PhotoSortOrder.symbol).intrinsicContentSize.width }
            .max() ?? 0
    }
    /// 「打开」按钮本体（A①/A⑥ 用它作为样式基准）。
    public var openButtonView: ToolButton { openButton }
    public var importButtonView: ToolButton { importButton }
    public var exportButtonView: ToolButton { exportButton }

    public override func layout() {
        super.layout()
        let h = bounds.height
        var x = contentLeading
        func place(_ v: NSView, width: CGFloat) {
            v.frame = NSRect(x: x, y: (h - WorkspaceLayout.toolButtonHit) / 2,
                             width: width, height: WorkspaceLayout.toolButtonHit)
            x += width
        }

        place(openButton, width: openButton.intrinsicContentSize.width)
        x += Self.itemGap
        // 435 — 用户口径「在顶栏"打开"的右边」：导入/导出紧贴打开按钮，节奏与其余控件一致。
        place(importButton, width: importButton.intrinsicContentSize.width)
        x += Self.itemGap
        place(exportButton, width: exportButton.intrinsicContentSize.width)
        x += Self.separatorGapIn
        separators[0].frame = NSRect(x: x, y: (h - WorkspaceLayout.toolSeparatorHeight) / 2,
                                     width: 1, height: WorkspaceLayout.toolSeparatorHeight)
        x += Self.separatorGapOut
        // 442 —— 顺序：打开 导入 导出 | 网格/单图 胶片条 侧栏 排序 | 后台（454 P1 加了第二条分隔线）。
        // 「网格/单图」是一个按钮，宽度固定为两者较宽者。
        place(modeButton, width: Self.modeWidth())
        x += Self.itemGap
        // 「胶片条/侧栏」一个按钮：宽度固定为两者较宽者。
        place(browserButton, width: Self.browserWidth())
        x += Self.itemGap
        place(sortButton, width: Self.sortWidth())
        x += Self.separatorGapIn
        separators[1].frame = NSRect(x: x, y: (h - WorkspaceLayout.toolSeparatorHeight) / 2,
                                     width: 1, height: WorkspaceLayout.toolSeparatorHeight)
        x += Self.separatorGapOut
        place(backgroundButton, width: backgroundButton.intrinsicContentSize.width)

        // 状态四段：整块右对齐，右边缘 = 顶栏右边距（= 检查器列的右边），整块落在检查器列上方。
        //
        // 两个约束，取更紧的那个：
        // ① 检查器列宽（`statusColumnWidth`）：让整块留在列上方，而不是横到画布上去；
        // ② 顶栏最后一个可交互控件的右边缘 + 16 pt：库名再长也不许压到按钮上。
        // 簇内部只截库名一段（中间省略），计数与版本号按自身实际宽度完整显示；
        // ①② 都塞不下 40 pt 库名时 `width(limit:)` 返回 0，整块隐藏（退化到没有状态文本，
        // 而不是压住控件或画出一段被剪碎的省略号）。
        let rightEdge = bounds.width - TopBarStatusCluster.Metrics.trailingInset
        let controlLimit = controlsTrailingEdge + TopBarStatusCluster.Metrics.minimumGapFromControls
        let limit = max(0, rightEdge - controlLimit)
        statusCluster.columnWidth = statusColumnWidth
        statusCluster.widthLimit = limit
        let clusterWidth = statusCluster.width(limit: limit)
        let clusterHeight = TopBarStatusCluster.Metrics.lineHeight
        statusCluster.isHidden = clusterWidth <= 0
        statusCluster.frame = NSRect(x: rightEdge - clusterWidth,
                                     y: ((h - clusterHeight) / 2).rounded(),
                                     width: clusterWidth,
                                     height: clusterHeight)
        statusCluster.needsLayout = true
    }

    @objc private func openTapped() { onOpen?() }
    @objc private func sortTapped() { onToggleSort?() }

    /// 454 P1 —— 点「后台」开/关空面板。A click on the already-open popover's anchor closes it, the
    /// same toggle the two filter popovers use; `.transient` also closes it on any outside click.
    @objc private func backgroundTapped() {
        if isBackgroundTasksPopoverOpen {
            isBackgroundTasksPopoverOpen = false
            if backgroundTasksPopover.isShown { backgroundTasksPopover.performClose(nil) }
            return
        }
        backgroundTasksPopoverController.reload()
        backgroundTasksPopover.contentSize = backgroundTasksPopoverController.preferredContentSize
        isBackgroundTasksPopoverOpen = true
        // Without a window (a detached view in a unit test) there is nothing to anchor to; the flag
        // above is still the truth the bar reports, exactly like `FilterBarView`.
        guard backgroundButton.window != nil else { return }
        backgroundTasksPopover.show(relativeTo: backgroundButton.bounds,
                                    of: backgroundButton,
                                    preferredEdge: .maxY)
    }

    public func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === backgroundTasksPopover else { return }
        isBackgroundTasksPopoverOpen = false
    }

    @objc private func modeTapped(_ sender: ToolButton) {
        // 按钮写的是当前模式 ⇒ 点它换到另一个。
        onModeChange?(sender.title == Loc.t("网格") ? .loupe : .grid)
    }

    @objc private func browserTapped(_ sender: ToolButton) {
        // 按钮写的是当前形态 ⇒ 点它换到另一个。
        onBrowserMode?(sender.title == Loc.t("胶片条") ? .list : .filmstrip)
    }
}

// MARK: - draggable divider

final class WorkspaceDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    /// 068: the two edges of a drag. A divider drag runs its own `nextEvent` loop — AppKit knows nothing
    /// about it, so it never starts a window live resize and the canvas would go on rendering (and
    /// presenting) for every mouse-moved tick. The workspace hands both edges to the loupe instead, so a
    /// divider drag and a window drag follow **the same** freeze (one draw per runloop tick, one render
    /// at the size the hand stopped on).
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var mouseDownX: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: (bounds.width - WorkspaceLayout.dividerThickness) / 2, y: 0,
               width: WorkspaceLayout.dividerThickness, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownX = convert(event.locationInWindow, from: nil).x
        onDragBegan?()
        // `defer` so a throw or an early `break` still ends the gesture: a freeze that is never released
        // would leave the canvas at the pre-drag geometry with no frame coming.
        defer { onDragEnded?() }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let x = convert(next.locationInWindow, from: nil).x
            let delta = x - mouseDownX
            mouseDownX = x
            if abs(delta) > 0.01 { onDrag?(delta) }
        }
    }
}

// MARK: - root layout

/// The workspace: tool bar, browser, canvas, inspector and the filmstrip — all frames from
/// `WorkspaceLayout.resolve`, all state from `CatalogSession`.
///
/// Deliberately not an `NSSplitViewController` (§2b supersedes the earlier split-view plan): the
/// filmstrip has to span the browser *and* the canvas at the bottom while the inspector runs full
/// height, which is not a three-column split. Dragging is therefore two 5 pt hit strips with resize
/// cursors, and the widths they produce are the numbers already covered by the layout unit tests.
public final class WorkspaceRootView: NSView {

    public let session: CatalogSession
    public let topBar: TopBarView
    /// 454 P2a —— the one store lives on the model (`session.backgroundTasks`); the top bar's popover
    /// is handed the same instance. P1 的面板外观与行为不变，视图只是读它。
    public var backgroundTaskStore: BackgroundTaskStore { session.backgroundTasks }
    public let browserPane: BrowserPaneController
    public let gridController: AssetGridController
    public let loupeController: LoupeController
    public let filmstripController: FilmstripController
    /// 303 — the one coalescer behind all three browsers' HD thumbnail refresh: an edit calls
    /// `noteEdit`, and 0.25 s after the last tick the edited photo's visible cells re-request.
    public let editThumbnailRefresher: EditThumbnailRefresher
    public let inspectorHost: InspectorHostingView
    /// **Which inspector workspace is showing** (派单 073), owned by the window's root rather than by
    /// the SwiftUI panel, so anything outside that panel — `--ui-smoke`, a future menu command, a
    /// test that hosts the real window — has one reachable handle on it.
    ///
    /// 派单 073's switcher is view state: selecting a workspace writes no document and no history.
    /// The state lives here, `InspectorView` receives the *same object* through its
    /// `init(session:loupe:workspaces:)`, so `root.inspectorWorkspaces.select(.masks)` rebuilds the
    /// panel's card list exactly as clicking the tab does.
    public let inspectorWorkspaces: InspectorWorkspaceState
    /// The one line of import feedback (进度 + 取消), floating at the bottom of the canvas.
    public let importProgressBar = ImportProgressBar()

    /// 205 — the one-line notice when the open document came from a newer build. A plain 10 pt
    /// secondary label over the canvas' top edge; hidden (and zero pixels different) when
    /// `session.edit.forwardCompatVersion == nil`, i.e. for every document this build wrote.
    ///
    /// Deliberately **not** a banner, alert or inspector row: the document is readable, so this is a
    /// note about provenance, not an error, and it must not move any `WorkspaceLayout` frame.
    public let forwardCompatNotice = NSTextField(labelWithString: "")

    private let canvasHost = NSView()
    /// 430 — set when the loupe is installed, consumed by the next grid install: the grid entry that
    /// follows a loupe visit is the only one allowed to centre the anchor and rematerialise cells.
    /// A plain `grid → grid` (⌘1) or a metadata tick never moves this.
    private var pendingGridEntry = false
    /// 471 — 浏览器面切换后，等新出现那一面的几何落地（`layout()` 设完 frame）再把锚点那张
    /// 露出来 / 居中。`setBrowserMode` 的 `applyBrowserMode()` 跑在 `layout()` 之前，当时
    /// `filmstripController.view.bounds` 还是切换前的旧值（列表模式下甚至是零），所以这里只
    /// 记一个一次性的旗标。
    private var pendingBrowserReveal = false
    private let browserDivider = WorkspaceDivider()
    private let inspectorDivider = WorkspaceDivider()
    private let inspectorBackdrop = NSVisualEffectView()
    /// 402 — 胶片条那一条的底板（与 `inspectorBackdrop` 同款材质）。
    ///
    /// 胶片条自己的 `view` 是一个 `drawsBackground = false` 的 `NSScrollView`，`collectionView` 的
    /// `backgroundColors` 也是 `.clear`：那一块**没有像素**去遮挡画布 overlay 的越界部分（裁切框、
    /// 引导线画到 `canvasHost` 之外后继续向下画到窗口底部）。层次本来是对的（胶片条在画布之上），
    /// 缺的是这一层不透明的采样板。放在 `filmstripController.view` 之前、`canvasHost` 之后。
    ///
    /// 不用「把 `collectionView.backgroundColors` 设成不透明」：那只盖住 collectionView 的可见矩形，
    /// 滚动条区与 `sectionInset` 外的留白仍会漏——正是用户看到的「背景上」。
    let filmstripBackdrop = NSVisualEffectView()
    /// 顶栏那条（含红绿灯所在的标题栏区域）背后的系统材质。见 `HeaderGlassView`。
    public let headerGlass = HeaderGlassView()
    private let bridge = ObservationBridge()

    private var browserWidth: CGFloat
    private var inspectorWidth: CGFloat
    public private(set) var browserMode: BrowserMode = .list
    public private(set) var geometry: WorkspaceGeometry

    /// 导入照片… — created on first use, because a session with no library has nothing to import
    /// into and the coordinator is only reachable through `beginImport()`.
    public private(set) lazy var importCoordinator = ImportCoordinator(session: session)

    public var isImporting: Bool { importCoordinator.isImporting }

    /// 435 — 导入/导出两条命令的**唯一判据**。菜单的 `validateMenuItem` 与顶栏按钮都读这里，
    /// 所以「文件 ▸ 导入照片…」灰掉时顶栏的导入也一定灰，反之亦然。
    public var canImport: Bool { session.isOpen && !isImporting }
    public var canExport: Bool { !session.selection.isEmpty }

    /// 466/467 —— 偏好走 `AppPreferences`：测试与烟测不再写进用户的域。
    private let defaults = AppPreferences.store

    // MARK: - 442 · 排序切换的「刷新中」闸门

    /// 上一次排序切换之后，**刷新完成之前不再接受点击**。
    ///
    /// 用户口径（2026-11-20）：「点击切换后直到刷新完成，不响应后面的点击。例如重复点击 Oldest first
    /// 几次，如果照片很多每次加载四五秒，就会不断切换直到点击的次数都响应完」。
    /// 所以第二次点击**被丢弃**（不是排队）：连点 5 下只切 1 次。
    private var sortBusyDeadline: CFAbsoluteTime = 0
    private var sortSettleTimer: Timer?
    /// 测试读数：这次刷新期间被忽略的点击数。
    public private(set) var sortClicksIgnored = 0
    /// 测试读数：闸门当前是否关着。
    public var isSortBusy: Bool { CFAbsoluteTimeGetCurrent() < sortBusyDeadline }

    /// 安全上限：无论缩略图队列说什么，5 s 后一定放开，按钮不许卡死。
    private static let sortSettleTimeout: CFAbsoluteTime = 5.0
    /// 最短占用：重排刚开始时队列还是空的，太早放开会让连点漏过去。
    private static let sortSettleMinimumTicks = 5      // × 0.1 s = 0.5 s

    public init(session: CatalogSession) {
        let browserPane = BrowserPaneController(session: session)
        let gridController = AssetGridController(session: session)
        let filmstripController = FilmstripController(session: session)
        self.session = session
        // 454 P2a — the bar's popover reads the model-owned store, exactly as the header does.
        self.topBar = TopBarView(store: session.backgroundTasks)
        self.browserPane = browserPane
        self.gridController = gridController
        self.loupeController = LoupeController(session: session)
        self.filmstripController = filmstripController
        // 303: every document edit feeds one window, and one callback refreshes the edited photo in
        // whichever of the three browsers has it on screen.
        self.editThumbnailRefresher = EditThumbnailRefresher { assetID in
            browserPane.refreshThumbnail(forAssetID: assetID)
            gridController.refreshThumbnail(forAssetID: assetID)
            filmstripController.refreshThumbnail(forAssetID: assetID)
            // 332 — the edit landed. The same 0.25 s tick that refreshes the thumbnails also puts
            // the current photo back in the middle of the two lists that follow it; the anchor
            // changing uses the same entry (`centerAnchor`), so a new edit path cannot miss it.
            browserPane.centerAnchor()
            filmstripController.centerAnchor()
        }
        // The panel gets **this** object, not a fresh one: the root is the handle the smoke runner
        // (and the unit test behind it) switches workspaces through.
        let workspaces = InspectorWorkspaceState()
        self.inspectorWorkspaces = workspaces
        self.inspectorHost = InspectorHostingView(rootView: InspectorView(session: session,
                                                                          loupe: loupeController,
                                                                          workspaces: workspaces))
        self.browserWidth = WorkspaceLayout.clampBrowserWidth(
            CGFloat(defaults.object(forKey: "photons.browserWidth") as? Double
                    ?? Double(WorkspaceLayout.browserWidthDefault)))
        self.inspectorWidth = WorkspaceLayout.clampInspectorWidth(
            CGFloat(defaults.object(forKey: "photons.inspectorWidth") as? Double
                    ?? Double(WorkspaceLayout.inspectorWidthDefault)))
        self.browserMode = BrowserMode(rawValue: defaults.string(forKey: "photons.browserMode") ?? "") ?? .list
        self.geometry = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 1000),
                                                mode: .list,
                                                browserWidth: 212,
                                                inspectorWidth: 330)
        super.init(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        inspectorBackdrop.material = .underWindowBackground
        inspectorBackdrop.blendingMode = .behindWindow
        inspectorBackdrop.state = .followsWindowActiveState

        // 402 — same material as the inspector's plate, for the same reasons (light/dark and inactive
        // windows follow the system, nothing is hard-coded, and `.behindWindow` samples the window
        // behind so the plate itself is fully opaque — an overlay cannot draw through it).
        filmstripBackdrop.material = .underWindowBackground
        filmstripBackdrop.blendingMode = .behindWindow
        filmstripBackdrop.state = .followsWindowActiveState

        canvasHost.wantsLayer = true
        canvasHost.layer?.backgroundColor = NSColor.black.cgColor

        // 402 — **顶栏在画布之上.** 394 只修了左侧栏，顶栏仍排在 `canvasHost` 前面（即之下），
        // 于是越界的裁切框/引导线（连同 `canvasHost` 自己的黑底）盖住了顶栏与红绿灯。
        // 面板级元素从上到下：通知/进度条 > 顶栏 = 左侧栏 = 右侧检查器 > 胶片条 > 画布及其 overlay。
        //
        // `headerGlass` 仍排在 `topBar` 之前（玻璃衬托按钮）；它铺满顶栏那条的整宽，但下沿只到
        // `topBar.maxY` == `g.canvas.minY`，所以正常路径下不遮画布（见 402 验收 ①）。
        //
        // 402 — 胶片条缺的是底板而不是层次：`filmstripBackdrop` 插在 `filmstripController.view`
        // 之前、`canvasHost` 之后，让那块透明滚动视图底下终于有不透明像素。
        for v: NSView in [canvasHost,
                          headerGlass, topBar,
                          browserPane.view, browserDivider,
                          inspectorDivider, inspectorBackdrop, inspectorHost,
                          filmstripBackdrop, filmstripController.view,
                          importProgressBar, forwardCompatNotice] {
            addSubview(v)
        }

        forwardCompatNotice.font = ForwardCompatNotice.font
        forwardCompatNotice.textColor = ForwardCompatNotice.textColor
        forwardCompatNotice.isSelectable = false
        forwardCompatNotice.lineBreakMode = .byTruncatingTail
        forwardCompatNotice.isHidden = true
        forwardCompatNotice.setAccessibilityIdentifier("workspace.forwardCompat.notice")

        browserDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.browserWidth = WorkspaceLayout.clampBrowserWidth(self.browserWidth + delta)
            self.defaults.set(Double(self.browserWidth), forKey: "photons.browserWidth")
            self.needsLayout = true
        }
        inspectorDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            // Dragging left grows the inspector.
            self.inspectorWidth = WorkspaceLayout.clampInspectorWidth(self.inspectorWidth - delta)
            self.defaults.set(Double(self.inspectorWidth), forKey: "photons.inspectorWidth")
            self.needsLayout = true
        }
        // 068: both dividers resize the **canvas**, so both drags are canvas geometry gestures. A drag
        // that is not announced freezes nothing, which is the state the 274→360 inspector drag was in:
        // every mouse-moved tick laid the canvas out and asked for a frame at a size the next tick would
        // replace — the picture re-fitting on each landed frame, which is the jelly.
        for divider in [inspectorDivider, browserDivider] {
            divider.onDragBegan = { [weak self] in self?.beginPanelDividerDrag() }
            divider.onDragEnded = { [weak self] in self?.endPanelDividerDrag() }
        }

        // 391 — 网格双击进单图：`session.activate` 只写模型（选中 + `mode = .loupe`），另外两个面
        // 不知道要滚，所以这里补一次居中。两个入口都是幂等的（已居中 → `centerAnchor()` 判据
        // ≤ 2 pt 直接返回 false），从网格连点几次不会累积滚动。
        //
        // 无脑调两面的代价是零：列表模式下胶片条虽然 `isHidden` 但仍有几何，会顺带对位好（切到
        // 胶片条模式时不用再滚一次）；胶片条模式下侧栏没有照片行，`centerAnchor()` 自己返回 false。
        //
        // 不推迟到下一帧：`activate` 只把 canvas 的子视图从网格换成单图，胶片条/侧栏的 frame 由
        // `browserMode` 决定、与本单无关，所以这一拍读到的就是最终几何 —— 实测两面偏移与
        // `CenteredScroll.target` 差 0.0 pt（偏差若来自旧几何不可能为 0）。推迟反而与用户连点抢帧。
        gridController.onActivate = { [weak self] id in
            guard let self else { return }
            self.session.activate(id)
            self.filmstripController.centreForLoupeEntry()
            self.browserPane.centreForLoupeEntry()
        }
        filmstripController.onActivate = { [weak self] id in self?.session.activate(id) }
        topBar.onOpen = { [weak self] in self?.openLibraryPanel() }
        topBar.onModeChange = { [weak self] mode in self?.session.mode = mode }
        topBar.onToggleFilmstrip = { [weak self] in self?.toggleFilmstrip() }
        // 442 —— 顶栏「胶片条 / 侧栏」这一对：直接指定模式，不是「切换」。
        topBar.onBrowserMode = { [weak self] mode in self?.setBrowserMode(mode) }
        // 排序：一个值写进会话，网格/左侧栏/胶片条各自观察它（三个 `observeModel` 都读
        // `session.sortOrder`），按钮文字在 `updateTopBar` 里跟着刷新。
        topBar.onToggleSort = { [weak self] in
            guard let self else { return }
            // 442 —— 刷新期间不接受后续点击（丢弃，不排队）。
            if self.isSortBusy {
                self.sortClicksIgnored += 1
                return
            }
            self.session.toggleSortOrder()
            self.updateTopBar()
            self.beginSortSettling()
        }

        // 072 §E1/§E2 — 裁切 mode takes the inspector's event layer away and hands it back on exit.
        // One switch, published by the loupe when the mode actually changes (so a drag tick cannot
        // flicker it), wired here because this view owns both halves.
        //
        // 2026-10-27 — the gate now depends on **two** facts: the mode and the workspace. 变换 *is* the
        // crop tool's own panel (its rows are 宽高比 / 角度 / 应用取消), so gating it would leave the
        // user with a frame they cannot apply from the panel they just opened. Every other workspace
        // stays inert exactly as §E1 measured it while the frame is up.
        loupeController.onCropModeChange = { [weak self] _ in self?.updateInspectorGate() }
        workspaces.onSelectionChange = { [weak self] _ in self?.updateInspectorGate() }

        // 202 ① — **leaving 裁切 hands the panel back**, every door: the panel goes to the last
        // non-crop workspace it showed (调整 by default), so ↵ / 完成 / Esc / 取消 all land the same
        // place. 123's `onTransformConfirmed` used to do this for ↵/完成 only, and unconditionally
        // forced 调整 — which is now the *fallback* rather than the rule: an entry from 色彩 comes
        // back to 色彩. The callback is deliberately left unwired here (the mode signal is the one
        // that must land the panel, and two listeners could disagree about where).
        loupeController.onCropToolExit = { [weak self] in
            self?.inspectorWorkspaces.returnFromCrop()
        }

        // 蒙版 workspace → the canvas' mask chrome (2026-10-27). `selection` is the panel's one writer
        // (`InspectorWorkspaceState.selection`), and its `onChange` fires synchronously, so the grips
        // are away in the same turn as the tab click — a turn of delay would leave them hittable while
        // the panel is already showing 调节. The initial value is pushed too: the app opens on `.adjust`.
        inspectorWorkspaces.onChange = { [weak self] workspace in
            self?.loupeController.setMasksWorkspaceActive(workspace == .masks)
            // 082/086 — entering 变换 opens the frame, leaving it cancels the draft (082). The same
            // synchronous switch the mask chrome rides: the frame is up before the panel has finished
            // redrawing, and a hidden overlay never lingers for a turn.
            self?.loupeController.setCropWorkspaceActive(workspace.showsCropCard)
        }
        loupeController.setMasksWorkspaceActive(inspectorWorkspaces.selection == .masks)
        loupeController.setCropWorkspaceActive(inspectorWorkspaces.selection.showsCropCard)

        showModule(for: session.mode)
        // 205: a session that already has a document loaded before this view exists (the app opens
        // the library first) must show the notice on the very first frame, not on the next change.
        updateForwardCompatNotice()
        applyBrowserMode()
        observeModel()

        // 303 — weak on both sides: the session does not keep the workspace (or its refresher) alive.
        session.addEditObserver { [weak self, weak refresher = editThumbnailRefresher] assetID in
            refresher?.noteEdit(assetID: assetID)
            self?.noteCanvasWarm(assetID: assetID)
        }
    }

    /// 311 — queue the anchor photo's canvas warm behind 303's window. Edits of any other photo
    /// (a grid adjustment, a paste over a selection) do not touch the loupe's stand-in.
    private func noteCanvasWarm(assetID: String) {
        guard assetID == session.anchorID else { return }
        canvasWarmRefresher.noteEdit(assetID: assetID)
    }

    /// 311 — the photo **on screen** needs its new HD key rendered even when no browser cell is
    /// visible to ask for it. The loupe's stand-in (`cachedCanvasPlaceholder`) is cache-only, so
    /// after a crop the canvas had nothing to put up until the user edited again; 303's refresher
    /// only serves the grid/filmstrip. One `.hd` request at `.prefetch` for the anchor photo's
    /// current document closes that hole — the provider dedupes by key and cancels the superseded
    /// one, so two doors (this observer and `finishCropTool`) cost one render.
    private func warmAnchorHDPreview(assetID: String) {
        guard assetID == session.anchorID,
              let asset = session.anchorAsset,
              let cache = session.thumbnailCache else { return }
        ThumbnailProvider.shared(for: cache)
            .warmHDPreview(for: asset,
                           fileURL: session.fileURL(for: asset),
                           document: session.edit)
    }

    /// The same window discipline 303 gives the browsers, for the canvas' own stand-in.
    ///
    /// 311 — the edit observer fires on **every** slider tick; asking for a 1920 render per tick
    /// would spend the drag re-encoding frames nobody sees, and would leave a file behind for every
    /// abandoned intermediate document. One warm per settled edit, for the document as it is *then*.
    /// The crop door (`finishCropTool`) deliberately does not wait for this window.
    private lazy var canvasWarmRefresher = EditThumbnailRefresher { [weak self] assetID in
        self?.warmAnchorHDPreview(assetID: assetID)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: observation

    /// 072 §E1's event gate, re-decided from its two inputs: the crop mode and the workspace.
    ///
    /// The panel goes inert (`hitTest → nil`) while 裁切 mode owns the canvas, **except** in 变换, where
    /// the panel *is* the crop tool's own controls (086: 宽高比, 角度 and the 应用/取消 pair all live in
    /// that card). Both callers — `onCropModeChange` and
    /// `InspectorWorkspaceState.onSelectionChange` — land here, so the two facts cannot be applied
    /// one without the other, and a workspace switch while the frame is up hands the panel over
    /// (or away) exactly once.
    private func updateInspectorGate() {
        let cropOwnsPanel = inspectorWorkspaces.selection == .transform
        inspectorHost.isEditingGated = loupeController.isCropToolActive && !cropOwnsPanel
    }

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self else { return }
            _ = self.session.mode
            _ = self.session.assets.count
            _ = self.session.selection
            _ = self.session.libraryURL
            // 排序按钮的字 = 当前顺序：会话里的值一变（按钮、菜单、测试），顶栏就重画。
            _ = self.session.sortOrder
            // 205: the provenance notice follows the open document. `editRevision` moves on every
            // commit; the loaded id moves on a photo switch.
            _ = self.session.editRevision
            _ = self.session.loadedEditAssetID
            // The value the notice is made of: a forced re-read of the same asset changes this
            // without moving `editRevision`.
            _ = self.session.edit.forwardCompatVersion
        }, { [weak self] in
            guard let self else { return }
            self.showModule(for: self.session.mode)
            self.updateTopBar()
            self.updateForwardCompatNotice()
        })
    }

    func updateTopBar() {
        topBar.update(mode: session.mode,
                      assetCount: session.assets.count,
                      selectionCount: session.selection.count,
                      libraryName: session.libraryURL?.deletingPathExtension().lastPathComponent,
                      filmstrip: browserMode == .filmstrip)
        topBar.updateSortOrder(session.sortOrder)
        // 435 — 菜单与按钮读同一对判据，刷新点也只有一个。
        topBar.updateActions(canImport: canImport, canExport: canExport)
    }

    /// 205 — show/hide the one-line notice. `nil` means the document was written by this build (or an
    /// older one), so the label is hidden and takes no space at all; no other frame/constraint moves.
    public func updateForwardCompatNotice() {
        showForwardCompatNotice(session.edit.forwardCompatVersion)
    }

    /// The view half of `updateForwardCompatNotice()`, reachable without a loaded library so a test
    /// can assert the exact wording and that showing it moves no layout frame.
    public func showForwardCompatNotice(_ version: Int?) {
        let text = ForwardCompatNotice.text(for: version)
        forwardCompatNotice.stringValue = text ?? ""
        forwardCompatNotice.isHidden = text == nil
        needsLayout = true
    }

    // MARK: modules

    public func showModule(for mode: CatalogSession.Mode) {
        // 253 — leaving the editor (网格) is a workspace switch too: no armed brush / eyedropper may
        // survive behind a canvas that is no longer on screen. The inspector's own workspace switch
        // is handled in `InspectorView`; this is the mode half.
        if mode != .loupe { loupeController.disarmAllTools() }
        let target: NSView = mode == .grid ? gridController.view : loupeController.view
        let current = canvasHost.subviews.first
        guard current !== target else {
            if mode == .loupe { loupeController.scheduleRender() }
            // 430 — a redundant request for the grid (⌘1 while already in the grid) arrives through
            // this branch too. It does nothing unless the loupe → grid switch below armed it, which
            // is what keeps a scroll the user made from being undone.
            if mode == .grid { applyPendingGridEntry() }
            return
        }
        current?.removeFromSuperview()
        target.frame = canvasHost.bounds
        target.autoresizingMask = [.width, .height]
        canvasHost.addSubview(target)
        if mode == .loupe {
            loupeController.scheduleRender()
            // 430 — arm the one-shot for the way back. The loupe has no scroll position to restore,
            // so the grid is where "my photo must be centred and already drawn" is decided.
            pendingGridEntry = true
        } else {
            applyPendingGridEntry()
        }
        updateTopBar()
    }

    /// 430 — the one `grid` entry that follows a `loupe` visit: centre the photo the loupe was
    /// showing, and fill the cells the re-entry recreated from the memory layer **synchronously**
    /// (before the next frame is drawn — a runloop hop would let the placeholder paint once, which
    /// is the flash the user reported). One-shot by construction: the flag is consumed here, so a
    /// later ⌘1, metadata tick or layout pass cannot yank the grid back to the anchor.
    private func applyPendingGridEntry() {
        guard pendingGridEntry else { return }
        pendingGridEntry = false
        gridController.thumbnailRematerializeOnAppear()
        gridController.centerOnAnchorIfNeeded()
    }

    public func setBrowserMode(_ mode: BrowserMode) {
        guard mode != browserMode else { return }
        browserMode = mode
        defaults.set(mode.rawValue, forKey: "photons.browserMode")
        applyBrowserMode()
        needsLayout = true
        updateTopBar()
    }

    /// 442 —— 排序切换之后关门，等缩略图队列空下来再开：`pending 0 && queueDepth 0`，
    /// 最短 0.5 s、最长 5 s。期间按钮置灰，点击被丢弃。
    private func beginSortSettling() {
        sortBusyDeadline = CFAbsoluteTimeGetCurrent() + Self.sortSettleTimeout
        topBar.setSortEnabled(false)
        sortSettleTimer?.invalidate()
        let deadline = sortBusyDeadline
        var ticks = 0
        sortSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            let idle = self.gridController.pendingThumbnailRequests == 0
                && self.gridController.thumbnailQueueDepth == 0
            let timedOut = CFAbsoluteTimeGetCurrent() >= deadline
            guard timedOut || (idle && ticks >= Self.sortSettleMinimumTicks) else { return }
            timer.invalidate()
            self.sortSettleTimer = nil
            self.sortBusyDeadline = 0
            self.topBar.setSortEnabled(true)
        }
    }

    public func toggleFilmstrip() {
        setBrowserMode(browserMode == .filmstrip ? .list : .filmstrip)
    }

    private func applyBrowserMode() {
        filmstripController.view.isHidden = browserMode != .filmstrip
        browserPane.showsPhotoList = browserMode == .list
        browserPane.refresh()
        // 471 — 新出现那一面要落在**当前锚点**上，而不是它自己上一次的旧偏移。几何在
        // `layout()` 里才更新，所以这里只登记，等这一轮布局结束再做（启动时那一次同样允许：
        // 锚点通常就是第一张，等价于 no-op）。
        pendingBrowserReveal = true
    }

    /// 471 — 把刚变可见的那一面带到锚点照片：
    ///
    /// - 网格（`session.mode != .loupe`）：只要**可见**即可（`scrollRowToVisible` /
    ///   `scrollToItems(.centeredHorizontally)` 仅在锚点不可见时用），两面位置大致匹配，不要求居中；
    /// - 单图（`.loupe`）：锚点那张在这面里**居中**，复用既有 `centreForLoupeEntry()`（≤ 2 pt
    ///   幂等）。383 的「单击不居中」不受影响：这条只由模式切换触发，不接选择变化。
    ///
    /// 相机与缩放**不动**（用户口径：居中的是浏览面里的照片，不是画布）。
    private func revealAnchorInVisibleBrowser() {
        guard session.anchorID != nil else { return }
        if session.mode == .loupe {
            if browserMode == .filmstrip { filmstripController.centreForLoupeEntry() }
            else { browserPane.centreForLoupeEntry() }
        } else {
            if browserMode == .filmstrip { filmstripController.revealAnchor() }
            else { browserPane.revealAnchor() }
        }
    }

    // MARK: layout

    public override func layout() {
        super.layout()
        let centre = trafficLightCentreY()
        let g = WorkspaceLayout.resolve(window: bounds.size,
                                        mode: browserMode,
                                        browserWidth: browserWidth,
                                        inspectorWidth: inspectorWidth,
                                        trafficLightCentreY: centre)
        geometry = g

        topBar.frame = g.topBar
        topBar.contentLeading = g.toolContentLeading
        // 玻璃铺满顶栏那一条的**整宽**，从窗口上边缘一直到顶栏下沿：红绿灯（标题栏里那 16…36 pt）
        // 和顶栏控件都画在它上面，中间不许再有别的底板。高度跟着 `topBar.maxY` 走，窗口缩放、
        // 全屏、红绿灯位置变化都不会把它留在原地。
        headerGlass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(1, g.topBar.maxY))
        // 顶栏右上角那块状态文本要落在检查器列上方：列宽从这里进 `TopBarStatusCluster`。
        topBar.statusColumnWidth = g.inspector.width
        browserPane.view.frame = g.browser
        browserDivider.frame = NSRect(x: g.browserDivider.minX - 2, y: g.browserDivider.minY,
                                      width: g.browserDivider.width + 4, height: g.browserDivider.height)
        canvasHost.frame = g.canvas
        inspectorDivider.frame = NSRect(x: g.inspectorDivider.minX - 2, y: g.inspectorDivider.minY,
                                        width: g.inspectorDivider.width + 4, height: g.inspectorDivider.height)
        inspectorBackdrop.frame = g.inspector
        inspectorHost.frame = g.inspector.insetBy(dx: 0, dy: 0)
        if let strip = g.filmstrip {
            filmstripController.view.frame = strip
            filmstripController.view.isHidden = false
            // 402 — the plate is the strip's own rect, field for field (the test compares them
            // exactly), so it can never end up as a stale 86 pt band over the canvas.
            filmstripBackdrop.frame = strip
            filmstripBackdrop.isHidden = false
        } else {
            filmstripController.view.isHidden = true
            // ② not a strip → no plate: the whole band would otherwise sit over the canvas' bottom
            // edge with nothing behind it (the same bug this lane fixes, just inverted).
            filmstripBackdrop.isHidden = true
            filmstripBackdrop.frame = .zero
        }
        // The import line floats over the canvas' bottom edge — above the filmstrip, inside the
        // canvas, so it cannot cover a thumbnail it is counting. Fixed height, width capped so a
        // wide display does not turn one sentence into a banner.
        let barHeight: CGFloat = 22
        let barWidth = min(260, max(140, g.canvas.width - 24))
        importProgressBar.frame = NSRect(x: g.canvas.minX + 12,
                                         y: g.canvas.maxY - barHeight - 12,
                                         width: barWidth, height: barHeight)
        // 205: one 10 pt line under the top bar, over the canvas' top edge. Its own frame only — the
        // notice is not part of `WorkspaceLayout`, so no existing size assertion moves.
        forwardCompatNotice.frame = NSRect(x: g.canvas.minX + 12,
                                           y: g.topBar.maxY + 8,
                                           width: min(360, max(0, g.canvas.width - 24)),
                                           height: ForwardCompatNotice.lineHeight)
        topBar.needsLayout = true
        topBar.needsDisplay = true
        // 471 — 布局已经把这轮浏览器面的最终几何写下去了，现在才轮到「把锚点带进新出现的一面」。
        // 一次性：消费掉旗标，后续任何布局（拖动分隔条、缩略图落地）都不会再把用户滚走的视口拽回来。
        if pendingBrowserReveal {
            pendingBrowserReveal = false
            // The surface's own frame just changed in this pass; let it lay its scroll view out before
            // reading a viewport rect, otherwise the reveal would use the previous width/height.
            if browserMode == .filmstrip { filmstripController.view.layoutSubtreeIfNeeded() }
            else { browserPane.view.layoutSubtreeIfNeeded() }
            revealAnchorInVisibleBrowser()
        }
    }

    /// Distance from the window's top edge to the traffic-light centre, measured live (§2b item 1).
    public func trafficLightCentreY() -> CGFloat? {
        guard let window, let close = window.standardWindowButton(.closeButton) else { return nil }
        let centre = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: self)
        let y = isFlipped ? centre.y : bounds.height - centre.y
        return y > 0 ? y : nil
    }

    public func setBrowserWidth(_ w: CGFloat) {
        browserWidth = WorkspaceLayout.clampBrowserWidth(w)
        defaults.set(Double(browserWidth), forKey: "photons.browserWidth")
        needsLayout = true
    }

    public func setInspectorWidth(_ w: CGFloat) {
        inspectorWidth = WorkspaceLayout.clampInspectorWidth(w)
        defaults.set(Double(inspectorWidth), forKey: "photons.inspectorWidth")
        needsLayout = true
    }

    // MARK: panel divider gestures (068)

    /// The two edges of a divider drag, as `WorkspaceDivider` calls them.
    ///
    /// Public because the acceptance test has to start where the divider starts: the bug was that a
    /// divider drag resized the canvas without telling it, so a test that called only
    /// `setInspectorWidth` in a loop would be testing the *unfixed* wiring and passing.
    public func beginPanelDividerDrag() {
        loupeController.beginCanvasGeometryGesture(.panelDivider)
    }

    public func endPanelDividerDrag() {
        loupeController.endCanvasGeometryGesture(.panelDivider)
    }

    /// Both dividers are wired to the canvas freeze (`onDrag`, `onDragBegan`, `onDragEnded`). A drag
    /// that loses any of the three is a canvas that renders per mouse-moved tick or freezes forever.
    public var panelDividersAreWired: Bool {
        [inspectorDivider, browserDivider].allSatisfy {
            $0.onDrag != nil && $0.onDragBegan != nil && $0.onDragEnded != nil
        }
    }

    public var currentBrowserWidth: CGFloat { browserWidth }
    public var currentInspectorWidth: CGFloat { inspectorWidth }

    // MARK: commands

    /// 文件 ▸ 导入照片… — panel, background import, then reload + select the first new photo.
    ///
    /// Everything the window shows about an import is wired here and nowhere else: one progress
    /// line (which doubles as the cancel affordance), and — on a run that had failures — that same
    /// line saying 「N 个失败」 for a few seconds. No sheet, no summary alert (用户: 摘要文案暂时不需要).
    public func beginImport() {
        guard session.isOpen else { return }
        let coordinator = importCoordinator

        coordinator.onProgress = { [weak self] progress in
            self?.importProgressBar.show(progress.text)
        }
        coordinator.onFinish = { [weak self] summary in
            guard let self else { return }
            if summary.failed > 0 {
                self.importProgressBar.showFailure(summary.failed)
            } else {
                self.importProgressBar.hide()
            }
            // 导入结束后 `isImporting` 变回 false：顶栏的导入按钮与菜单同时恢复可用。
            self.updateTopBar()
        }
        coordinator.onError = { [weak self] _ in
            // The only throw here is "the folder is gone"; a whole-import failure is one word, not
            // a paragraph.
            self?.importProgressBar.show(Loc.t("导入失败"))
            self?.updateTopBar()
        }
        importProgressBar.onCancel = { [weak coordinator] in coordinator?.cancel() }

        // A previous run's failure line must not sit under a new run.
        importProgressBar.hide()
        coordinator.presentAndStart()
        // A run that has just started has `isImporting == true`; refresh the pair now so the button
        // greys in the same turn as the menu would.
        updateTopBar()
    }

    public func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = Loc.t("打开 .photonslibrary")
        panel.prompt = Loc.t("打开")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.open(url)
            window?.title = "Photons — \(url.deletingPathExtension().lastPathComponent)"
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// 顶栏那一条的**空白处不吃鼠标**：命中要落到窗口自己的窗体上，由 AppKit 去处理拖动
    /// （`isMovableByWindowBackground == false`，窗口只能靠顶栏那条拖）。
    ///
    /// `super.hitTest` 先问子视图，所以按钮/分段控件/状态文本照样拿到自己的点击；只有
    /// 「命中的是 root 自己」这一种情况才交还给窗口——玻璃和顶栏已经各自在空白处返回 nil，
    /// 这里是最后一层。
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        // `hitTest` 的入参在**父视图**坐标系里（不是自己的），要先换成本地坐标再比那条带。
        let local = superview.map { convert(point, from: $0) } ?? point
        let band = headerGlass.frame.height > 0 ? headerGlass.frame : topBar.frame
        return band.contains(local) ? nil : hit
    }
}
