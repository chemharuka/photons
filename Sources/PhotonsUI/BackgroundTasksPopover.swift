import AppKit
import PhotonsLocalization

/// 454 P1 — the panel behind 顶栏「后台」. It is an `NSPopover` (ADR §21.5 default) holding a
/// `NSTableView`; P1 draws only the empty state because the store has no producer yet.
///
/// The row is the same height as a sidebar photo row (`WorkspaceLayout.browserRowHeight`). A task
/// row shows `标题 · 8/40`, a determinate bar, and a square thumbnail slot. The slot is a placeholder
/// until P4 resolves `currentThumbKey` through the thumbnail provider's square size.
public final class BackgroundTasksPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    public static let preferredWidth: CGFloat = 380
    public static let preferredHeight: CGFloat = 240

    /// The store is injected by the top bar. The panel never owns or mutates it: P2/P3 producers write
    /// through the same object, and this view only reads.
    public let backgroundTaskStore: BackgroundTaskStore

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: Loc.t("没有后台任务"))
    private let bridge = ObservationBridge()

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("BackgroundTaskRow")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BackgroundTaskColumn")

    public init(store: BackgroundTaskStore) {
        self.backgroundTaskStore = store
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: Self.preferredWidth, height: Self.preferredHeight)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    deinit { bridge.cancel() }

    // MARK: view

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth,
                                        height: Self.preferredHeight))
        root.wantsLayer = true
        self.view = root

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = WorkspaceLayout.browserRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setAccessibilityIdentifier("backgroundTasks.empty")
        root.addSubview(emptyLabel)

        reload()
        layoutContents()

        // Keep the list live if a future producer writes while the popover is open. P1 never does.
        bridge.observe({ [weak self] in
            _ = self?.backgroundTaskStore.tasks
        }, { [weak self] in
            self?.reload()
        })
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutContents()
    }

    private func layoutContents() {
        let bounds = view.bounds
        scrollView.frame = bounds.insetBy(dx: 8, dy: 8)
        let labelHeight: CGFloat = 20
        emptyLabel.frame = NSRect(x: 12,
                                  y: ((bounds.height - labelHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 24),
                                  height: labelHeight)
    }

    // MARK: data

    /// Re-read the store. Called when the popover is about to show and from the observation bridge.
    public func reload() {
        loadViewIfNeeded()
        let isEmpty = backgroundTaskStore.tasks.isEmpty
        emptyLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        tableView.reloadData()
        view.needsLayout = true
    }

    public var emptyStateText: String { emptyLabel.stringValue }
    public var isShowingEmptyState: Bool { !emptyLabel.isHidden }
    public var rowHeightForTesting: CGFloat { tableView.rowHeight }

    /// The row's one-line title (`标题 · 12/40`, plus the terminal counts). Reads the cell the table
    /// actually renders, not a copy of its formatting.
    public func rowTextForTesting(at row: Int) -> String? {
        rowView(at: row)?.titleTextForTesting
    }

    /// Whether that row draws the 取消 button. Running rows do; terminal rows do not.
    public func rowHasCancelButtonForTesting(at row: Int) -> Bool? {
        rowView(at: row)?.hasCancelButtonForTesting
    }

    private func rowView(at row: Int) -> BackgroundTaskRowView? {
        loadViewIfNeeded()
        guard backgroundTaskStore.tasks.indices.contains(row) else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? BackgroundTaskRowView
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        backgroundTaskStore.tasks.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard backgroundTaskStore.tasks.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self)
            as? BackgroundTaskRowView ?? BackgroundTaskRowView()
        cell.identifier = Self.rowIdentifier
        let task = backgroundTaskStore.tasks[row]
        cell.configure(with: task) { [weak self] in
            self?.backgroundTaskStore.cancel(id: task.id)
        }
        return cell
    }
}

// MARK: - one row

/// `标题 · 8/40` + a determinate bar + a square thumbnail slot. Frame-based on purpose: a popover row
/// has three fixed pieces, and the panel's tests measure the same constants the user sees.
private final class BackgroundTaskRowView: NSTableCellView {

    private let thumbnail = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: Loc.t("取消"), target: nil, action: nil)
    private var onCancel: (() -> Void)?

    private static let inset: CGFloat = 8
    private static let thumbnailSide: CGFloat = 28
    private static let cancelWidth: CGFloat = 44

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // P4 replaces this square with the real square-tier thumbnail for `currentThumbKey`.
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(thumbnail)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        addSubview(progress)

        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 11)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.setAccessibilityIdentifier("backgroundTasks.cancel")
        addSubview(cancelButton)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    var titleTextForTesting: String { titleLabel.stringValue }
    var hasCancelButtonForTesting: Bool { !cancelButton.isHidden }

    func configure(with task: BackgroundTask, onCancel: (() -> Void)?) {
        self.onCancel = onCancel
        var text = "\(task.title) · \(BackgroundTaskStore.countText(for: task))"
        switch task.state {
        case .cancelled:
            text += " · \(Loc.t("已取消"))"
        case .finished, .failed:
            let success = max(0, task.total - task.failureCount)
            text += " · 成功 \(success) / 失败 \(task.failureCount)"
        case .queued, .running:
            break
        }
        titleLabel.stringValue = text
        progress.doubleValue = BackgroundTaskStore.progressFraction(for: task)
        // The panel shows counts only; per-file failure details stay in the export report (§21.3.5).
        cancelButton.isHidden = task.state.isTerminal
        toolTip = task.currentAssetID
        needsLayout = true
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    override func layout() {
        super.layout()
        let side = Self.thumbnailSide
        thumbnail.frame = NSRect(x: Self.inset, y: (bounds.height - side) / 2,
                                 width: side, height: side)
        let textX = thumbnail.frame.maxX + 8
        let buttonWidth = cancelButton.isHidden ? 0 : Self.cancelWidth
        let textWidth = max(0, bounds.width - textX - Self.inset - buttonWidth
                            - (cancelButton.isHidden ? 0 : 6))
        titleLabel.frame = NSRect(x: textX, y: 7, width: textWidth, height: 16)
        progress.frame = NSRect(x: textX, y: 29, width: textWidth, height: 6)
        cancelButton.frame = NSRect(x: bounds.width - Self.inset - buttonWidth,
                                    y: (bounds.height - 18) / 2,
                                    width: buttonWidth, height: 18)
    }
}
