import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore

// MARK: - tool button (§2b: 28 pt hit box, 26 pt paint, radius 7 continuous, 9 pt side padding)

public final class ToolButton: NSButton {
    public var isActive = false { didSet { needsDisplay = true } }
    private var hovering = false

    public init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
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
        let imageWidth: CGFloat = image == nil ? 0 : 14
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
        super.draw(dirtyRect)
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
public final class TopBarView: NSView {
    public var onOpen: (() -> Void)?
    public var onModeChange: ((CatalogSession.Mode) -> Void)?
    public var onToggleFilmstrip: (() -> Void)?
    public var onToggleBrowser: (() -> Void)?
    /// 排序按钮（`新→旧 / 旧→新`）。One click flips the order the grid, the browser and the strip read.
    public var onToggleSort: (() -> Void)?

    private let openButton = ToolButton(title: "打开", symbol: "folder")
    private let modeControl = NSSegmentedControl(labels: ["网格", "单图"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let stripButton = ToolButton(title: "胶片条", symbol: "rectangle.split.1x2")
    /// 胶片条按钮右边那一个：同款 `ToolButton`、同高、10 pt 间距。
    ///
    /// 文字是**当前顺序**（`新→旧` / `旧→新`），图标是通用的 `arrow.up.arrow.down` 且不随方向变——
    /// 两处同时描述状态会互相打架，所以方向只由文字说一次（见 `PhotoSortOrder`）。
    private let sortButton = ToolButton(title: PhotoSortOrder.default.label, symbol: PhotoSortOrder.symbol)
    /// 右上角那一块状态文本（已选 · 张数 · 库名 · 版本号），四段的字体/颜色/高度/顺序和
    /// 右对齐规则都在 `TopBarStatusCluster` 里，这里只负责把它钉在顶栏右边距上。
    public let statusCluster = TopBarStatusCluster()
    private var separators: [NSView] = []

    public var contentLeading: CGFloat = WorkspaceLayout.trafficLightsWidth + 10

    /// 检查器列的宽度：`statusCluster` 用它算库名那一栏的预算，好让整块落在检查器列上方。
    public var statusColumnWidth: CGFloat = WorkspaceLayout.inspectorWidthDefault {
        didSet { if statusColumnWidth != oldValue { needsLayout = true } }
    }

    /// 顶栏最后一个可交互控件的右边缘。公开给测试：簇的左边缘永远在它右边
    /// （`TopBarStatusCluster.Metrics.minimumGapFromControls` 之外），再长的库名也压不到按钮上。
    /// 排序按钮排在胶片条按钮后面，所以它是这一行最右的一个。
    public var controlsTrailingEdge: CGFloat { sortButton.frame.maxX }

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true

        openButton.target = self
        openButton.action = #selector(openTapped)
        stripButton.target = self
        stripButton.action = #selector(stripTapped)
        sortButton.target = self
        sortButton.action = #selector(sortTapped)
        // 图标盒与邻居逐点一致（18 × 14），见 `PhotoSortOrder.symbolConfiguration`。
        sortButton.image = PhotoSortOrder.icon()

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0

        for v: NSView in [openButton, modeControl, stripButton, sortButton, statusCluster] {
            addSubview(v)
        }
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
        modeControl.selectedSegment = mode == .grid ? 0 : 1
        stripButton.isActive = filmstrip
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

    /// 排序按钮本体。测试要量它的 frame / 字体 / 图标，`--ui-smoke` 可以读它的字。
    public var sortButtonView: ToolButton { sortButton }
    /// 它左边那个邻居（胶片条）——「同款」是拿这两个按钮量出来的，不是形容词。
    public var filmstripButtonView: ToolButton { stripButton }

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
        x += 10
        separators[0].frame = NSRect(x: x, y: (h - WorkspaceLayout.toolSeparatorHeight) / 2,
                                     width: 1, height: WorkspaceLayout.toolSeparatorHeight)
        x += 11
        place(modeControl, width: 112)
        x += 10
        separators[1].frame = NSRect(x: x, y: (h - WorkspaceLayout.toolSeparatorHeight) / 2,
                                     width: 1, height: WorkspaceLayout.toolSeparatorHeight)
        x += 11
        place(stripButton, width: stripButton.intrinsicContentSize.width)
        // 排序按钮紧挨着胶片条按钮：同一行、同一 28 pt 命中高、10 pt 间距（和打开↔分段控件、
        // 分段控件↔胶片条用的是同一个数），顶栏里排在最后，所以不压住右上角的状态簇。
        x += 10
        place(sortButton, width: sortButton.intrinsicContentSize.width)

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
    @objc private func stripTapped() { onToggleFilmstrip?() }
    @objc private func sortTapped() { onToggleSort?() }
    @objc private func modeChanged() { onModeChange?(modeControl.selectedSegment == 0 ? .grid : .loupe) }
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
    public let topBar = TopBarView()
    public let browserPane: BrowserPaneController
    public let gridController: AssetGridController
    public let loupeController: LoupeController
    public let filmstripController: FilmstripController
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

    private let canvasHost = NSView()
    private let browserDivider = WorkspaceDivider()
    private let inspectorDivider = WorkspaceDivider()
    private let inspectorBackdrop = NSVisualEffectView()
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

    private let defaults = UserDefaults.standard

    public init(session: CatalogSession) {
        self.session = session
        self.browserPane = BrowserPaneController(session: session)
        self.gridController = AssetGridController(session: session)
        self.loupeController = LoupeController(session: session)
        self.filmstripController = FilmstripController(session: session)
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

        canvasHost.wantsLayer = true
        canvasHost.layer?.backgroundColor = NSColor.black.cgColor

        // 玻璃**最先加**：它必须在最底层（`subviews[0]`），顶栏控件和红绿灯都在它上面。
        // 红绿灯本身由 AppKit 画在 contentView 之上，所以这里只要保证不在按钮上方盖任何不透明层。
        for v: NSView in [headerGlass, topBar, browserPane.view, browserDivider, canvasHost,
                          inspectorDivider, inspectorBackdrop, inspectorHost,
                          filmstripController.view, importProgressBar] {
            addSubview(v)
        }

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

        gridController.onActivate = { [weak self] id in self?.session.activate(id) }
        filmstripController.onActivate = { [weak self] id in self?.session.activate(id) }
        topBar.onOpen = { [weak self] in self?.openLibraryPanel() }
        topBar.onModeChange = { [weak self] mode in self?.session.mode = mode }
        topBar.onToggleFilmstrip = { [weak self] in self?.toggleFilmstrip() }
        // 排序：一个值写进会话，网格/左侧栏/胶片条各自观察它（三个 `observeModel` 都读
        // `session.sortOrder`），按钮文字在 `updateTopBar` 里跟着刷新。
        topBar.onToggleSort = { [weak self] in
            guard let self else { return }
            self.session.toggleSortOrder()
            self.updateTopBar()
        }

        // 072 §E1/§E2 — 裁切 mode takes the inspector's event layer away and hands it back on exit.
        // One switch, published by the loupe when the mode actually changes (so a drag tick cannot
        // flicker it), wired here because this view owns both halves.
        loupeController.onCropModeChange = { [weak self] active in
            self?.inspectorHost.isEditingGated = active
        }

        showModule(for: session.mode)
        applyBrowserMode()
        observeModel()
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: observation

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self else { return }
            _ = self.session.mode
            _ = self.session.assets.count
            _ = self.session.selection
            _ = self.session.libraryURL
            // 排序按钮的字 = 当前顺序：会话里的值一变（按钮、菜单、测试），顶栏就重画。
            _ = self.session.sortOrder
        }, { [weak self] in
            guard let self else { return }
            self.showModule(for: self.session.mode)
            self.updateTopBar()
        })
    }

    private func updateTopBar() {
        topBar.update(mode: session.mode,
                      assetCount: session.assets.count,
                      selectionCount: session.selection.count,
                      libraryName: session.libraryURL?.deletingPathExtension().lastPathComponent,
                      filmstrip: browserMode == .filmstrip)
        topBar.updateSortOrder(session.sortOrder)
    }

    // MARK: modules

    public func showModule(for mode: CatalogSession.Mode) {
        let target: NSView = mode == .grid ? gridController.view : loupeController.view
        let current = canvasHost.subviews.first
        guard current !== target else {
            if mode == .loupe { loupeController.scheduleRender() }
            return
        }
        current?.removeFromSuperview()
        target.frame = canvasHost.bounds
        target.autoresizingMask = [.width, .height]
        canvasHost.addSubview(target)
        if mode == .loupe { loupeController.scheduleRender() }
        updateTopBar()
    }

    public func setBrowserMode(_ mode: BrowserMode) {
        guard mode != browserMode else { return }
        browserMode = mode
        defaults.set(mode.rawValue, forKey: "photons.browserMode")
        applyBrowserMode()
        needsLayout = true
        updateTopBar()
    }

    public func toggleFilmstrip() {
        setBrowserMode(browserMode == .filmstrip ? .list : .filmstrip)
    }

    private func applyBrowserMode() {
        filmstripController.view.isHidden = browserMode != .filmstrip
        browserPane.showsPhotoList = browserMode == .list
        browserPane.refresh()
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
        } else {
            filmstripController.view.isHidden = true
        }
        // The import line floats over the canvas' bottom edge — above the filmstrip, inside the
        // canvas, so it cannot cover a thumbnail it is counting. Fixed height, width capped so a
        // wide display does not turn one sentence into a banner.
        let barHeight: CGFloat = 22
        let barWidth = min(260, max(140, g.canvas.width - 24))
        importProgressBar.frame = NSRect(x: g.canvas.minX + 12,
                                         y: g.canvas.maxY - barHeight - 12,
                                         width: barWidth, height: barHeight)
        topBar.needsLayout = true
        topBar.needsDisplay = true
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
        }
        coordinator.onError = { [weak self] _ in
            // The only throw here is "the folder is gone"; a whole-import failure is one word, not
            // a paragraph.
            self?.importProgressBar.show("导入失败")
        }
        importProgressBar.onCancel = { [weak coordinator] in coordinator?.cancel() }

        // A previous run's failure line must not sit under a new run.
        importProgressBar.hide()
        coordinator.presentAndStart()
    }

    public func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "打开 .photonslibrary"
        panel.prompt = "打开"
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
