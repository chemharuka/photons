import AppKit
import PhotonsCatalog

/// Left browser (Phos "素材浏览"): the source roots on top, the photo list below.
///
/// Matte, not glass — §2b item 5: big panels stay matte (`.sidebar`), only small widget containers
/// use glass. Rows are 46 pt and recycled, so 10k photos cost the same as 10.
///
/// The 34 pt square in a row is a **thumbnail**, not a colour chip. It used to be painted as
/// `PlaceholderSwatch.color(for:)` and nothing ever replaced it, which is why the default browser
/// mode (`photons.browserMode = list`) showed a wall of flat colours while the centre grid — the
/// other surface — streamed real images out of the same cache. The rows now ask the same
/// `ThumbnailProvider.shared(for:)` the grid and the filmstrip use (one LRU, one single-flight map,
/// 006 §4), keyed by the tier a 34 pt cell implies, and cancel whatever scrolls away.
public final class BrowserPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Side of the square preview in a photo row, in points. It is the only input to the tier
    /// policy (`ThumbnailProvider.tier(cellEdgePoints:)` → `t256` at 1× and 2×).
    public static let thumbnailSide: CGFloat = 34
    /// Rows of prefetch above and below the visible band (006 §5 "可见 + 上下各一行", applied to a
    /// 46 pt row: one row of slack is cheaper than a scroll hitch).
    private static let prefetchSlackRows = 5

    private let headerTitle = NSTextField(labelWithString: "素材浏览")
    private let headerCount = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let sourcesTable = NSTableView()
    private let photosTable = NSTableView()
    /// 右键：从库中删除… / 查找丢失的文件… — one menu object, the same verbs as the grid.
    public let contextMenu = AssetContextMenu()
    private let sourcesScroll = NSScrollView()
    private let photosScroll = NSScrollView()
    private let matte = NSVisualEffectView()
    private let bridge = ObservationBridge()
    private weak var session: CatalogSession?
    private var isApplyingModel = false

    /// Rows of the sources table: index 0 is "all photos", the rest map to `roots`.
    private struct SourceRow {
        var title: String
        var detail: String
        var rootID: String?
        var status: String?
    }
    private var sourceRows: [SourceRow] = []

    // MARK: thumbnails

    /// One instance per library cache, shared with the grid and the filmstrip: a row and a grid cell
    /// asking for the same `contentHash` join one job and hit one LRU (006 §4 单飞).
    private var thumbnailProvider: ThumbnailProvider?
    private var providerCache: ThumbnailCache?
    /// Outstanding loads by photo row. Cancelled the moment the row leaves the window.
    private var thumbRequests: [Int: ThumbnailRequest] = [:]
    private var reconcileWork: DispatchWorkItem?
    private var cellTier: ThumbTier = .t256
    private var lastWanted: Set<Int> = []
    private var lastTier: ThumbTier?
    private var lastLibraryURL: URL?
    private var loggedMissingCache = false

    /// When the filmstrip is the browser (mode B), the photo rows live down there instead.
    public var showsPhotoList = true {
        didSet {
            photosTable.isHidden = !showsPhotoList
            scheduleThumbnailReconcile()
        }
    }

    public init(session: CatalogSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func loadView() {
        let root = FlippedView()

        matte.material = .sidebar
        matte.blendingMode = .behindWindow
        matte.state = .followsWindowActiveState
        root.addSubview(matte)

        headerTitle.font = .systemFont(ofSize: 12, weight: .bold)
        headerCount.font = .systemFont(ofSize: 10)
        headerCount.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 10, weight: .medium)
        footer.textColor = .secondaryLabelColor

        configure(table: sourcesTable, rowHeight: WorkspaceLayout.browserRowHeight, identifier: "SourceRowCell")
        configure(table: photosTable, rowHeight: WorkspaceLayout.browserRowHeight, identifier: "PhotoRowCell")
        photosTable.allowsMultipleSelection = true

        // 右键：the same two verbs the grid and the filmstrip offer, on the same menu object. The
        // list resolves the click through `clickedRow`, which AppKit keeps current for us.
        contextMenu.willOpen = { [weak self] in self?.prepareContextMenu() }
        contextMenu.onDelete = { [weak self] ids in self?.deleteMissingAssets(ids) }
        contextMenu.onFindLost = { [weak self] ids in self?.findAndRelinkMissingAssets(ids) }
        photosTable.menu = contextMenu.menu

        sourcesScroll.documentView = sourcesTable
        sourcesScroll.hasVerticalScroller = false
        sourcesScroll.drawsBackground = false
        sourcesScroll.borderType = .noBorder
        photosScroll.documentView = photosTable
        photosScroll.hasVerticalScroller = true
        photosScroll.drawsBackground = false
        photosScroll.borderType = .noBorder
        photosScroll.autohidesScrollers = true
        // Scrolling is what changes "which rows are visible", and that is what decides which loads
        // stay alive (006 §5). Cheapest hook there is — no delegate, no timer.
        photosScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(photoListDidScroll),
                                              name: NSView.boundsDidChangeNotification,
                                              object: photosScroll.contentView)

        for v: NSView in [headerTitle, headerCount, footer, sourcesScroll, photosScroll] {
            root.addSubview(v)
        }
        view = root
    }

    private func configure(table: NSTableView, rowHeight: CGFloat, identifier: String) {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .sourceList
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        observeModel()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutPanes()
        scheduleThumbnailReconcile()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func layoutPanes() {
        let inset = WorkspaceLayout.cardInsetH
        let headerH: CGFloat = 56
        headerTitle.frame = NSRect(x: inset, y: 18, width: view.bounds.width - inset * 2, height: 16)
        headerCount.frame = NSRect(x: inset, y: 36, width: view.bounds.width - inset * 2, height: 13)

        matte.frame = view.bounds
        let footerH: CGFloat = 26
        let sourcesH = min(CGFloat(max(1, sourceRows.count)) * WorkspaceLayout.browserRowHeight + 6, 200)
        let top = headerH
        sourcesScroll.frame = NSRect(x: 6, y: top, width: view.bounds.width - 12, height: sourcesH)
        let photosTop = top + sourcesH + 6
        photosScroll.frame = NSRect(x: 6, y: photosTop,
                                    width: view.bounds.width - 12,
                                    height: max(40, view.bounds.height - photosTop - footerH))
        footer.frame = NSRect(x: inset, y: view.bounds.height - footerH + 6,
                              width: view.bounds.width - inset * 2, height: 13)
    }

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets.count
            _ = session.roots.count
            _ = session.selection
            _ = session.anchorID
            _ = session.stats
            _ = session.metadataRevision
        }, { [weak self] in
            self?.refresh()
        })
    }

    public func refresh() {
        guard isViewLoaded, let session else { return }
        // A different library is a different cache directory: drop the memory layer so a row can
        // never show the previous library's pixels.
        if let url = session.libraryURL, url != lastLibraryURL {
            lastLibraryURL = url
            resetThumbnails()
        }
        sourceRows = [SourceRow(title: "全部照片", detail: "\(session.assets.count)", rootID: nil, status: nil)]
        let counts = Dictionary(uniqueKeysWithValues: (session.stats?.byRoot ?? []).map { ($0.root, $0) })
        for root in session.roots {
            let n = counts[root.displayName]?.count ?? 0
            sourceRows.append(SourceRow(title: root.displayName,
                                        detail: "\(n)",
                                        rootID: root.id,
                                        status: root.status.rawValue))
        }
        headerCount.stringValue = "\(session.assets.count) 张照片"
        footer.stringValue = session.selection.isEmpty
            ? "未选择"
            : "已选 \(session.selection.count)"
        sourcesTable.reloadData()
        // `reloadData` clamps the table's selection to what still exists and posts
        // `tableViewSelectionDidChange` for it. That transient row count is not the user's
        // selection: writing it back would collapse a 5-photo selection to one row on every
        // refresh (the grid's ⌘-click range, then any metadata write). The model is the truth, so
        // the transient notification is ignored here and the real selection is installed below.
        isApplyingModel = true
        photosTable.reloadData()
        isApplyingModel = false
        applySelectionFromModel()
        selectSourceRow()
        // `reloadData` recycles every visible row, so every visible row re-asks for its image.
        // Deferred one runloop turn because the table has not laid its rows out yet.
        DispatchQueue.main.async { [weak self] in self?.reconcileThumbnails(force: true) }
    }

    private func selectSourceRow() {
        guard let session else { return }
        let index = sourceRows.firstIndex { $0.rootID == session.selectedRootID } ?? 0
        isApplyingModel = true
        sourcesTable.selectRowIndexes([index], byExtendingSelection: false)
        isApplyingModel = false
    }

    private func applySelectionFromModel() {
        guard let session else { return }
        let rows = IndexSet(session.assets.enumerated()
            .filter { session.selection.contains($0.element.id) }
            .map { $0.offset })
        guard rows != photosTable.selectedRowIndexes else { return }
        isApplyingModel = true
        photosTable.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingModel = false
    }

    // MARK: thumbnails

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? 2
    }

    // MARK: right-click (same verbs as the grid and the strip)

    /// Refresh the shared menu's state from the row the click landed on (`clickedRow`, which AppKit
    /// sets immediately before it asks for the menu).
    public func prepareContextMenu() {
        guard let session else { return }
        let row = photosTable.clickedRow
        if row >= 0, let asset = session.assets[safe: row], !session.selection.contains(asset.id) {
            session.selectOnly(asset.id)
            isApplyingModel = true
            photosTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingModel = false
        }
        contextMenu.update(selectedIDs: session.selectedAssets.map(\.id),
                           missingIDs: session.missingAssets.map(\.id))
    }

    public func deleteMissingAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.delete(ids, session: session, window: view.window)
    }

    public func findAndRelinkMissingAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.findLost(ids, session: session, window: view.window)
    }

    private func provider() -> ThumbnailProvider? {
        guard let session else { return nil }
        guard let cache = session.thumbnailCache else {
            // A library is open but there is no cache: the only state in which a row can never get
            // pixels. Say so once instead of returning nil into the void (the bug this replaces was
            // silent for exactly this reason).
            if session.isOpen, !loggedMissingCache {
                loggedMissingCache = true
                FileHandle.standardError.write(Data(
                    "photons: thumbnail cache unavailable for \(session.libraryURL?.path ?? "?") — the photo list cannot draw images\n".utf8))
            }
            return nil
        }
        if let thumbnailProvider, providerCache === cache { return thumbnailProvider }
        // A different library is a different cache directory: never keep the previous one's pixels.
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        lastWanted = []
        lastTier = nil
        providerCache = cache
        let made = ThumbnailProvider.shared(for: cache)
        thumbnailProvider = made
        return made
    }

    /// The tier a 34 pt square should ask for: cell edge × DPR, clamped to what the source can fill
    /// and then to the pipeline ceiling (§6.1). 34 pt → 68 px → `t256`; at 2× a 512 px preview could
    /// only ever be downscaled, so asking for it would waste a generation and a third of a megabyte.
    private func tier(for asset: Asset) -> ThumbTier {
        let requested = ThumbnailProvider.tier(
            cellEdgePoints: BrowserPaneController.thumbnailSide,
            backingScale: backingScale,
            sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: asset))
        return ThumbnailProvider.effectiveTier(requested: requested, ext: asset.ext).tier
    }

    /// Show the image we already hold; queue a load when we hold none.
    ///
    /// The memory layer is synchronous on purpose: a row that scrolls back into view must draw in
    /// the same frame, and a flash of solid colour is exactly the symptom this fixes. A **missing**
    /// original has nothing to decode, so only a cached thumbnail may stand in (same rule as the
    /// grid and the strip).
    private func applyThumbnail(to cell: PhotoRowCell, row: Int, asset: Asset) {
        guard let provider = provider() else { return }
        let tier = tier(for: asset)
        cell.thumbnailTier = tier
        if let cached = provider.serveFromMemory(for: .preview(contentHash: asset.contentHash, tier: tier)) {
            cell.setThumbnail(cached)
            return
        }
        if asset.isMissing {
            let key = ThumbKey.preview(contentHash: asset.contentHash, tier: tier)
            guard provider.cache.exists(key) else { return }
        }
        requestThumbnail(row: row, asset: asset, tier: tier, priority: .onScreen)
    }

    private func requestThumbnail(row: Int, asset: Asset, tier: ThumbTier, priority: ThumbPriority) {
        guard let provider = provider(), thumbRequests[row] == nil else { return }
        guard let session, let url = session.fileURL(for: asset) else { return }
        let token = provider.request(index: row, asset: asset, fileURL: url, tier: tier,
                                     priority: priority) { [weak self] idx, key, image in
            self?.thumbnailDidLoad(row: idx, key: key, image: image)
        }
        thumbRequests[row] = token
    }

    private func thumbnailDidLoad(row: Int, key: ThumbKey, image: CGImage?) {
        thumbRequests[row] = nil
        guard let image, let session, row >= 0, row < session.assets.count else { return }
        guard let cell = photosTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoRowCell,
              cell.assetID == session.assets[row].id else { return }
        // The row may have been recycled between request and delivery; the asset id is the guard.
        cell.thumbnailTier = key.tier
        cell.setThumbnail(image)
    }

    @objc private func photoListDidScroll() {
        scheduleThumbnailReconcile()
    }

    private func scheduleThumbnailReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileThumbnails(force: false) }
        reconcileWork = work
        // One frame of coalescing: a live scroll fires this dozens of times a second and the answer
        // only changes when the visible row range does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    /// Visible rows plus a few either side; everything else is cancelled (§5).
    private func reconcileThumbnails(force: Bool) {
        guard isViewLoaded, let session, !session.assets.isEmpty, let provider = provider() else { return }
        guard showsPhotoList else {
            for (_, token) in thumbRequests { token.cancel() }
            thumbRequests.removeAll()
            lastWanted = []
            return
        }

        // The tier is a property of the cell size, so one number covers every row.
        if let first = session.assets.first {
            let wantedTier = tier(for: first)
            if wantedTier != lastTier {
                lastTier = wantedTier
                cellTier = wantedTier
                for (_, token) in thumbRequests { token.cancel() }
                thumbRequests.removeAll()
                lastWanted = []
            }
        }

        let wanted = wantedRows()
        guard force || wanted != lastWanted else { return }
        lastWanted = wanted
        let visible = visibleRows()

        for (row, token) in thumbRequests where !wanted.contains(row) {
            token.cancel()
            thumbRequests.removeValue(forKey: row)
        }

        for row in wanted {
            guard row < session.assets.count else { continue }
            let asset = session.assets[row]
            if provider.memoryImage(contentHash: asset.contentHash, tier: cellTier) != nil { continue }
            if thumbRequests[row] != nil { continue }
            requestThumbnail(row: row, asset: asset, tier: cellTier,
                             priority: visible.contains(row) ? .onScreen : .prefetch)
        }
    }

    private func visibleRows() -> Set<Int> {
        Set(integers(in: photosTable.rows(in: photosScroll.contentView.bounds)))
    }

    private func integers(in range: NSRange) -> Range<Int> {
        range.length <= 0 ? 0..<0 : range.location..<(range.location + range.length)
    }

    private func wantedRows() -> Set<Int> {
        let visible = photosTable.rows(in: photosScroll.contentView.bounds)
        guard visible.length > 0 else { return [] }
        let slack = BrowserPaneController.prefetchSlackRows
        let lower = max(0, visible.location - slack)
        let upper = min(session?.assets.count ?? 0, visible.location + visible.length + slack)
        guard lower < upper else { return [] }
        return Set(lower..<upper)
    }

    // MARK: thumbnail probes (used by `--grid-probe`)

    public var thumbnailStats: ThumbnailProvider.Stats {
        thumbnailProvider?.stats ?? ThumbnailProvider.Stats()
    }

    public var currentThumbnailTier: ThumbTier { cellTier }

    /// Photo rows currently on screen.
    public var visiblePhotoRowCount: Int { visibleRows().count }

    /// Rows on screen whose square is drawing a real thumbnail rather than the flat placeholder.
    /// This is the number that separates "the list streams images" from "the list still paints
    /// colour chips" — the same judgement the grid's `visibleThumbnailCount` makes.
    public var visibleThumbnailCount: Int {
        visibleRows().reduce(0) { total, row in
            guard let cell = photosTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? PhotoRowCell,
                  cell.thumbnail != nil else { return total }
            return total + 1
        }
    }

    public var pendingThumbnailRequests: Int { thumbRequests.count }

    /// Outstanding loads for rows outside the wanted band. Must be 0 once the scroll handler ran.
    public var pendingThumbnailIndexesOutsideWindow: Int {
        Set(thumbRequests.keys).subtracting(wantedRows()).count
    }

    /// The provider the rows draw from — the probe asserts it is `===` the grid's.
    public var thumbnailProviderForSmoke: ThumbnailProvider? { provider() }

    public func resetThumbnails() {
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        lastWanted = []
        lastTier = nil
        thumbnailProvider = nil
        providerCache = nil
    }

    // MARK: data source

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sourcesTable { return sourceRows.count }
        guard showsPhotoList else { return 0 }
        return session?.assets.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourcesTable {
            let cell = SourceRowCell.reuse(in: tableView, owner: self)
            let r = sourceRows[row]
            cell.configure(title: r.title, detail: r.detail, isOffline: r.status == "offline")
            return cell
        }
        guard let session, let asset = session.assets[safe: row] else { return nil }
        let cell = PhotoRowCell.reuse(in: tableView, owner: self)
        cell.configure(asset: asset, isActive: session.anchorID == asset.id)
        applyThumbnail(to: cell, row: row, asset: asset)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel, let session else { return }
        guard let table = notification.object as? NSTableView else { return }
        if table === sourcesTable {
            let row = max(0, table.selectedRow)
            let rootID = sourceRows[safe: row]?.rootID
            if rootID != session.selectedRootID { session.selectRoot(rootID) }
            return
        }
        let ids = table.selectedRowIndexes.compactMap { session.assets[safe: $0]?.id }
        guard !ids.isEmpty else { return }
        let anchor = ids.first { session.anchorID == $0 } ?? ids.first
        session.setSelection(Set(ids), anchor: anchor)
    }

    public var sourceRowCount: Int { sourceRows.count }
    public var photoRowCount: Int { photosTable.numberOfRows }
}

// MARK: - cells

private final class SourceRowCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    static func reuse(in table: NSTableView, owner: Any) -> SourceRowCell {
        let id = NSUserInterfaceItemIdentifier("SourceRowCell")
        if let v = table.makeView(withIdentifier: id, owner: owner) as? SourceRowCell { return v }
        let cell = SourceRowCell()
        cell.identifier = id
        return cell
    }

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    func configure(title t: String, detail d: String, isOffline: Bool) {
        title.stringValue = t
        detail.stringValue = d
        title.textColor = isOffline ? .tertiaryLabelColor : .labelColor
        title.toolTip = isOffline ? "offline" : nil
    }

    override func layout() {
        super.layout()
        detail.frame = NSRect(x: bounds.width - 44, y: 14, width: 40, height: 16)
        title.frame = NSRect(x: 2, y: 13, width: max(10, bounds.width - 52), height: 18)
    }
}

final class PhotoRowCell: NSTableCellView {
    private let swatch = NSView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let stars = NSTextField(labelWithString: "")
    /// 「原文件已移动」, over the thumbnail square. Hidden unless the row's original moved.
    private let pill = MissingFilePillView()

    /// Which asset this row is currently showing. A recycled row must never accept an image that was
    /// requested for the photo it used to hold.
    private(set) var assetID: String?
    /// The decoded thumbnail, or nil while the flat placeholder is all we have.
    private(set) var thumbnail: CGImage?
    /// Which tier the current image came from — the probe asserts the DPR choice against it.
    var thumbnailTier: ThumbTier?
    /// 「原文件已移动」 for this row, or nil. A string, not just a colour, so the row can be asserted
    /// on (the grid card and the strip cell expose the same one, from the same constant).
    private(set) var missingLabel: String?

    static func reuse(in table: NSTableView, owner: Any) -> PhotoRowCell {
        let id = NSUserInterfaceItemIdentifier("PhotoRowCell")
        if let v = table.makeView(withIdentifier: id, owner: owner) as? PhotoRowCell { return v }
        let cell = PhotoRowCell()
        cell.identifier = id
        return cell
    }

    init() {
        super.init(frame: .zero)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.masksToBounds = true
        // The image is aspect-filled and centre-anchored, exactly like a grid card: the cell decides
        // the crop, never the image. `contentsGravity` also keeps this off the draw path — a list
        // row is 34 pt and `CALayer` composites it on the GPU.
        swatch.layer?.contentsGravity = .resizeAspectFill
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        meta.font = .systemFont(ofSize: 9)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        stars.font = .systemFont(ofSize: 8)
        stars.textColor = .systemYellow
        for v in [swatch, name, meta, stars] { addSubview(v) }
        addSubview(pill)   // last: the badge sits on top of the thumbnail square
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    func configure(asset: Asset, isActive: Bool) {
        // A recycled row must not show the previous photo for one frame: clear first, the controller
        // re-applies from the memory cache (a synchronous `NSCache` hit) right after.
        setThumbnail(nil)
        thumbnailTier = nil
        assetID = asset.id
        // The placeholder stays underneath the image (006 §2): a row is never a white hole, and a
        // failure looks like "not yet", not like "broken".
        swatch.layer?.backgroundColor = PlaceholderSwatch.color(for: asset.contentHash).cgColor
        name.stringValue = asset.filename
        var bits: [String] = []
        if let m = asset.cameraModel { bits.append(m) }
        if let d = asset.captureLocalDate { bits.append(d) }
        meta.stringValue = bits.joined(separator: " · ")
        stars.stringValue = asset.rating > 0 ? PlaceholderSwatch.stars(asset.rating) : ""
        name.textColor = isActive ? .labelColor : .secondaryLabelColor

        // 「原文件已移动」 takes the meta line: on a 46 pt row the fact that the file is gone outranks
        // the camera model, and the badge is drawn on the thumbnail as well so a glance finds it.
        let moved = asset.isMissing ? MissingFileText.moved : nil
        missingLabel = moved
        pill.text = moved
        if let moved {
            meta.stringValue = moved
            meta.textColor = .systemOrange
        } else {
            meta.stringValue = bits.joined(separator: " · ")
            meta.textColor = .secondaryLabelColor
        }
    }

    /// Paint the image (or drop back to the placeholder when `image` is nil).
    ///
    /// `contentsScale` is set here rather than once in `init` because the cell can be adopted by a
    /// different window (a 1× display) after being created; without it a 256 px thumbnail would be
    /// resampled as if it were 256 pt.
    func setThumbnail(_ image: CGImage?) {
        guard thumbnail !== image else { return }
        thumbnail = image
        swatch.layer?.contents = image
        swatch.layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = image == nil
    }

    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 2, y: (bounds.height - BrowserPaneController.thumbnailSide) / 2,
                              width: BrowserPaneController.thumbnailSide,
                              height: BrowserPaneController.thumbnailSide)
        let textX: CGFloat = 44
        let width = max(10, bounds.width - textX - 2)
        name.frame = NSRect(x: textX, y: bounds.height - 31, width: width, height: 15)
        meta.frame = NSRect(x: textX, y: bounds.height - 45, width: width, height: 12)
        stars.frame = NSRect(x: textX, y: bounds.height - 17, width: width, height: 10)
        // The pill rides the bottom of the thumbnail square (12 pt tall, inset 1 pt).
        pill.frame = NSRect(x: swatch.frame.minX, y: swatch.frame.maxY - 13,
                            width: swatch.frame.width, height: 12)
    }
}
