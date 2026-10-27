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

    private let openButton = ToolButton(title: "打开", symbol: "folder")
    private let modeControl = NSSegmentedControl(labels: ["网格", "单图"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let stripButton = ToolButton(title: "胶片条", symbol: "rectangle.split.1x2")
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
    public var controlsTrailingEdge: CGFloat { stripButton.frame.maxX }

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true

        openButton.target = self
        openButton.action = #selector(openTapped)
        stripButton.target = self
        stripButton.action = #selector(stripTapped)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.selectedSegment = 0

        for v: NSView in [openButton, modeControl, stripButton, statusCluster] {
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
        // Matte, not glass: the top container is a large panel like the others.
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
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

        for v: NSView in [topBar, browserPane.view, browserDivider, canvasHost,
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
}
