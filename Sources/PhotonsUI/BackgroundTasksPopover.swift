import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization

/// 488 — everything the panel needs to turn a task's `currentThumbKey` / `currentAssetID` into
/// pixels. The workspace hands in the live session's provider and asset lookup; a bare panel in a
/// unit test can hand in a provider over a temporary cache and leave the asset closures nil (the
/// loader then reads the provider's on-disk file by key).
public struct BackgroundTaskThumbnailSource {

    public var provider: @MainActor () -> ThumbnailProvider?
    public var assetForID: @MainActor (String) -> Asset?
    public var fileURLForAsset: @MainActor (Asset) -> URL?

    public init(provider: @escaping @MainActor () -> ThumbnailProvider?,
                assetForID: @escaping @MainActor (String) -> Asset? = { _ in nil },
                fileURLForAsset: @escaping @MainActor (Asset) -> URL? = { _ in nil }) {
        self.provider = provider
        self.assetForID = assetForID
        self.fileURLForAsset = fileURLForAsset
    }
}

/// 454 P1 — the panel behind 顶栏「后台」. It is an `NSPopover` (ADR §21.5 default) holding a
/// `NSTableView`.
///
/// The row is the same height as a sidebar photo row (`WorkspaceLayout.browserRowHeight`). A task
/// row shows `标题 · 8/40`, a determinate bar, and a 28×28 square thumbnail.
///
/// 488 — the square is now the real square-tier image for `currentThumbKey` (the same
/// `ThumbnailProvider` the grid/list/filmstrip use). A miss keeps the previous placeholder, and
/// the panel increments `thumbnailMissCount` instead of silently drawing a grey box.
public final class BackgroundTasksPopover: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    public static let preferredWidth: CGFloat = 380
    public static let preferredHeight: CGFloat = 240

    /// 28 pt square at 2× — the request size for a row's bitmap. The provider's memory layer is
    /// display-sized, so asking the same size the list does makes the panel's first frame a memory
    /// hit; a miss is still loaded through the shared service (never a second cache).
    static let thumbnailDisplay = ImageSize(width: 56, height: 56)

    /// The store is injected by the top bar. The panel never owns or mutates it: P2/P3 producers write
    /// through the same object, and this view only reads.
    public let backgroundTaskStore: BackgroundTaskStore

    /// Set by `TopBarView` from the workspace. Optional so every existing test can build a bare
    /// panel; without it rows keep their placeholder.
    public var thumbnailSource: BackgroundTaskThumbnailSource? {
        didSet { reload() }
    }

    /// How many rows fell back to the placeholder because no provider/key/image was available.
    /// «取不到就保留现在的占位块（并 assert 级别地记一条计数，别静默）» — this is the counter.
    public private(set) var thumbnailMissCount = 0

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: Loc.t("没有后台任务"))
    private let bridge = ObservationBridge()

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("BackgroundTaskRow")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("BackgroundTaskColumn")

    public init(store: BackgroundTaskStore,
                thumbnailSource: BackgroundTaskThumbnailSource? = nil) {
        self.backgroundTaskStore = store
        self.thumbnailSource = thumbnailSource
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

        // Keep the list live while a producer writes. 488: also the row's 当前照片 changes on every
        // item, so this observation is what makes the square follow the batch.
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

    /// 504 — the table's own row count after the last `reloadData()`. This is the number the panel
    /// actually draws, which is what 「面板行数」 in the retention dispatch must compare against
    /// `store.displayTasks.count` and the top bar's visible lines.
    public var tableRowCountForTesting: Int { tableView.numberOfRows }

    /// The row's one-line title (`标题 · 12/40`, plus the terminal counts). Reads the cell the table
    /// actually renders, not a copy of its formatting.
    public func rowTextForTesting(at row: Int) -> String? {
        rowView(at: row)?.titleTextForTesting
    }

    /// Whether that row draws the 取消 button. Running rows do; terminal rows do not.
    public func rowHasCancelButtonForTesting(at row: Int) -> Bool? {
        rowView(at: row)?.hasCancelButtonForTesting
    }

    /// 488 — the image the square currently holds (`nil` ⇒ placeholder is showing).
    public func rowThumbnailImageForTesting(at row: Int) -> NSImage? {
        rowView(at: row)?.thumbnailImageForTesting
    }

    /// 488 — which `currentThumbKey` the square is displaying. Lets a batch test prove the square
    /// moved from asset A to asset B without comparing bitmap bytes.
    public func rowThumbnailKeyForTesting(at row: Int) -> String? {
        rowView(at: row)?.thumbnailKeyForTesting
    }

    public func rowIsShowingThumbnailPlaceholderForTesting(at row: Int) -> Bool? {
        rowView(at: row)?.isShowingPlaceholderForTesting
    }

    /// Newest-first, the store's one display order. The panel never reverses `tasks` by itself.
    private var displayTasks: [BackgroundTask] { backgroundTaskStore.displayTasks }

    private func rowView(at row: Int) -> BackgroundTaskRowView? {
        loadViewIfNeeded()
        guard displayTasks.indices.contains(row) else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? BackgroundTaskRowView
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayTasks.count
    }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard displayTasks.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self)
            as? BackgroundTaskRowView ?? BackgroundTaskRowView()
        cell.identifier = Self.rowIdentifier
        let task = displayTasks[row]
        cell.configure(with: task, onCancel: { [weak self] in
            self?.backgroundTaskStore.cancel(id: task.id)
        }, thumbnailLoader: { [weak self] task, completion in
            self?.loadThumbnail(for: task, completion: completion)
        })
        return cell
    }

    // MARK: 488 · thumbnail

    private func loadThumbnail(for task: BackgroundTask,
                               completion: @escaping @MainActor (String?, CGImage?) -> Void) {
        guard let source = thumbnailSource, let provider = source.provider() else {
            thumbnailMissCount += 1
            completion(nil, nil)
            return
        }
        guard let key = resolvedKey(for: task, source: source) else {
            thumbnailMissCount += 1
            completion(nil, nil)
            return
        }

        // 1. the shared memory layer, synchronously — a row that scrolls back in draws in one frame.
        if let hit = provider.memoryImage(for: key) {
            completion(key.keyString, hit)
            return
        }

        // 2. the same request the three browsers use, when the producer told us which photo it is.
        if let assetID = task.currentAssetID,
           let asset = source.assetForID(assetID),
           let url = source.fileURLForAsset(asset) {
            provider.request(index: 0,
                             asset: asset,
                             fileURL: url,
                             document: ThumbnailProvider.document(from: asset),
                             tier: .t2048,
                             spec: .hdJPEG,
                             display: Self.thumbnailDisplay,
                             priority: .onScreen) { [weak self] _, _, image in
                if image == nil { self?.thumbnailMissCount += 1 }
                completion(key.keyString, image)
            }
            return
        }

        // 3. no asset lookup (a bare test panel, or a task whose photo left the library): read the
        // key's file through the same provider's service. Never generate a second family here.
        guard provider.cache.exists(key) else {
            thumbnailMissCount += 1
            completion(key.keyString, nil)
            return
        }
        provider.service.request(ThumbRequestSpec(key: key,
                                                  source: URL(fileURLWithPath: "/")),
                                 priority: .onScreen) { [weak self] result in
            let image = result.data.flatMap(ThumbnailCache.decode)
            DispatchQueue.main.async {
                if image == nil { self?.thumbnailMissCount += 1 }
                completion(key.keyString, image)
            }
        }
    }

    private func resolvedKey(for task: BackgroundTask,
                             source: BackgroundTaskThumbnailSource) -> ThumbKey? {
        if let raw = task.currentThumbKey, let key = ThumbKey(keyString: raw) {
            return key
        }
        // 488 §2.3 item 11 — no key but an asset id: compute the shared hdJPEG key instead of
        // inventing another cache. Same rule the browsers use.
        if let assetID = task.currentAssetID, let asset = source.assetForID(assetID) {
            return ThumbnailProvider.hdJPEGKey(for: asset)
        }
        return nil
    }
}

// MARK: - key-string → ThumbKey

private extension ThumbKey {

    /// Parse the exact strings `ThumbKey.keyString` writes. This is the inverse of that property and
    /// exists only because `BackgroundTask.currentThumbKey` is a `String` (the value type stays
    /// `Sendable`; no `ThumbKey` leaks into the task model).
    init?(keyString: String) {
        let parts = keyString.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6, parts[0] == "thumb" else { return nil }
        if parts[1] == "v1", parts.count == 6 {
            guard let tier = ThumbTier(rawValue: parts[3]),
                  let pipeline = ThumbPipeline(rawValue: parts[4]) else { return nil }
            self.init(contentHash: parts[2], tier: tier, pipeline: pipeline,
                      recipeDigest: parts[5], spec: .legacy)
            return
        }
        guard parts[1] == "v2", parts.count == 9,
              let spec = ThumbSpec(rawValue: parts[3]),
              let tier = ThumbTier(rawValue: parts[5]),
              let pipeline = ThumbPipeline(rawValue: parts[6]) else { return nil }
        self.init(contentHash: parts[2], tier: tier, pipeline: pipeline,
                  recipeDigest: parts[7], spec: spec, editFingerprint: parts[8])
    }
}

// MARK: - one row

/// `标题 · 8/40` + a determinate bar + a 28×28 square. Frame-based on purpose: a popover row
/// has three fixed pieces, and the panel's tests measure the same constants the user sees.
private final class BackgroundTaskRowView: NSTableCellView {

    typealias ThumbnailLoader = (BackgroundTask,
                                 @escaping @MainActor (String?, CGImage?) -> Void) -> Void

    private let thumbnail = NSView()
    private let thumbnailImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: Loc.t("取消"), target: nil, action: nil)
    private var onCancel: (() -> Void)?
    private var thumbnailGeneration = 0

    private static let inset: CGFloat = 8
    private static let thumbnailSide: CGFloat = 28
    private static let cancelWidth: CGFloat = 44
    private static let placeholderColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // 488 — the old placeholder is still the fallback, but a resolved thumbnail covers it with
        // the real square-tier bitmap and clears the tint entirely.
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.layer?.masksToBounds = true
        addSubview(thumbnail)

        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 3
        thumbnailImageView.layer?.masksToBounds = true
        thumbnail.addSubview(thumbnailImageView)

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

        showThumbnail(nil, key: nil)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    var titleTextForTesting: String { titleLabel.stringValue }
    var hasCancelButtonForTesting: Bool { !cancelButton.isHidden }
    var thumbnailImageForTesting: NSImage? { thumbnailImageView.image }
    var thumbnailKeyForTesting: String? { displayedThumbnailKey }
    var isShowingPlaceholderForTesting: Bool { thumbnailImageView.image == nil }

    private var displayedThumbnailKey: String?

    func configure(with task: BackgroundTask,
                   onCancel: (() -> Void)?,
                   thumbnailLoader: @escaping ThumbnailLoader) {
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

        // A recycled cell must not keep the previous task's square while the new request runs.
        thumbnailGeneration += 1
        let generation = thumbnailGeneration
        showThumbnail(nil, key: nil)
        thumbnailLoader(task) { [weak self] key, image in
            guard let self, self.thumbnailGeneration == generation else { return }
            self.showThumbnail(image, key: key)
        }

        needsLayout = true
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func showThumbnail(_ image: CGImage?, key: String?) {
        displayedThumbnailKey = image == nil ? nil : key
        if let image {
            // 488 — the square shows the processed photo, not the placeholder tint.
            thumbnail.layer?.backgroundColor = NSColor.clear.cgColor
            thumbnailImageView.image = NSImage(cgImage: image,
                                               size: NSSize(width: image.width,
                                                            height: image.height))
        } else {
            thumbnail.layer?.backgroundColor = Self.placeholderColor.cgColor
            thumbnailImageView.image = nil
        }
    }

    override func layout() {
        super.layout()
        let side = Self.thumbnailSide
        thumbnail.frame = NSRect(x: Self.inset, y: (bounds.height - side) / 2,
                                 width: side, height: side)
        thumbnailImageView.frame = thumbnail.bounds
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
