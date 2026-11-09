import AppKit
import PhotonsCatalog
import PhotonsCore

/// The filmstrip: a horizontal `NSCollectionView` that is the *same* browser as the photo list,
/// just laid out along the bottom (Phos mode B: a 122 pt bar of 74×50 thumbs, ⌃⌘B shows/hides it,
/// ⌃⌘A switches back to the list).
///
/// It shares `CatalogSession.selection` with the grid — no second selection set, no second model —
/// and it shares the *thumbnail* pipeline too: one `ThumbnailProvider` (hence one
/// `ThumbnailService` and one memory LRU) for both views, obtained through
/// `ThumbnailProvider.shared(for:)`. A 90 × 72 pt cell (90 × 60 image area, 3:2) asks for the tier its DPR implies (§1), i.e.
/// `t256` at 1x and 2x, and the selected cell always goes out at `.onScreen` priority.
///
/// 223/227 — the image itself is a `CAMetalLayer` (`ThumbnailEDRView`) showing the float
/// extended-linear P3 bitmap; the card paints the gradient underneath and a transparent overlay
/// paints the ring/badge above it.
public final class FilmstripCell: NSCollectionViewItem {
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("FilmstripCell")

    private let card = FilmstripCard()

    public override func loadView() { view = card }

    public var cardView: FilmstripCard { card }

    public override var isSelected: Bool { didSet { card.isPicked = isSelected } }

    public func configure(asset: Asset, isActive: Bool) {
        // A recycled cell must not show a *different* photo for one frame; the same asset keeps
        // its bitmap (a filter/metadata refresh is not a pixel change).
        if card.asset?.id != asset.id {
            card.clearThumbnail()
            card.thumbnailTier = nil
        }
        card.asset = asset
        card.isActive = isActive
        card.isPicked = isSelected
        view.toolTip = asset.filename
    }
}

public final class FilmstripCard: NSView {
    public var asset: Asset? { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isActive = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isPicked = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    /// The decoded thumbnail, or nil while the hash-derived placeholder is all we have.
    public var thumbnail: CGImage? {
        didSet {
            thumbnailView.image = thumbnail
            overlay.needsDisplay = true
        }
    }
    /// Same invariant as the grid: same key + same bitmap = no layer work.
    public private(set) var thumbnailKey: ThumbKey?
    public private(set) var thumbnailDisplay: ImageSize?
    public func applyThumbnail(_ image: CGImage?, key: ThumbKey, display: ImageSize) {
        if thumbnailKey == key, thumbnailDisplay == display, thumbnail === image { return }
        thumbnailKey = key
        thumbnailDisplay = display
        thumbnail = image
    }
    public func clearThumbnail() {
        thumbnailKey = nil
        thumbnailDisplay = nil
        thumbnail = nil
    }
    /// Which tier the current image came from — `--ui-smoke` asserts the DPR choice against it.
    public var thumbnailTier: ThumbTier?
    /// 223 — the pixel rectangle this cell asked the provider for.
    public var thumbnailDisplayPixels: ImageSize?

    /// The EDR surface, exposed for the acceptance read-back.
    public var thumbnailLayer: CALayer? { thumbnailView.layer }

    private let thumbnailView = ThumbnailEDRView(cornerRadius: 6)
    private let overlay = FilmstripOverlayView()

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        thumbnailView.isHidden = true
        addSubview(thumbnailView)
        overlay.card = self
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    /// 「原文件已移动」 for this cell, or nil — the same string the grid card and the inspector use.
    public var missingLabel: String? { asset?.isMissing == true ? MissingFileText.moved : nil }
    /// Set inside `draw` when the badge was actually painted.
    public private(set) var lastDrawnMissingLabel: String?

    public override var isFlipped: Bool { true }

    private var thumbRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width,
               height: max(1, bounds.height - WorkspaceLayout.filmstripCaptionHeight))
    }

    public override func layout() {
        super.layout()
        thumbnailView.frame = thumbRect
        overlay.frame = bounds
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let asset else { return }
        let thumb = thumbRect
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: PlaceholderSwatch.color(for: asset.contentHash),
                   ending: PlaceholderSwatch.secondaryColor(for: asset.contentHash))?
            .draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Above the EDR image: ring, 「原文件已移动」 and the filename line.
    fileprivate func drawForeground() {
        guard let asset else { return }
        let thumb = thumbRect
        let radius: CGFloat = 6
        if isPicked || isActive {
            let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.75, dy: 0.75),
                                    xRadius: radius, yRadius: radius)
            (isActive ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.5)).setStroke()
            ring.lineWidth = isActive ? 2 : 1.5
            ring.stroke()
        }

        // The badge is drawn *outside* the clip so its pill is never cut by the rounded corner, and
        // last, so no selection ring sits on top of the words the user has to read.
        lastDrawnMissingLabel = nil
        if let missingLabel {
            MissingFileBadge.draw(in: thumb, compact: true)
            lastDrawnMissingLabel = missingLabel
        }
        let name = NSRect(x: 0, y: thumb.maxY + 1, width: bounds.width, height: 11)
        (asset.filename as NSString).draw(in: name, withAttributes: PlaceholderStyle.captionAttributes)
    }
}

private final class FilmstripOverlayView: NSView {
    weak var card: FilmstripCard?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { card?.drawForeground() }
}

public final class FilmstripController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    public let collectionView = AssetCollectionView()
    /// 右键：从库中删除… / 查找丢失的文件… — the same menu object the grid uses.
    public let contextMenu = AssetContextMenu()
    private let flow = NSCollectionViewFlowLayout()
    private let bridge = ObservationBridge()

    /// Diffable identity is the asset id: filtering/sorting moves the cell with its photo.
    private enum Section: Hashable { case main }
    private var diffableDataSource: NSCollectionViewDiffableDataSource<Section, String>!
    private var assetsByID: [String: Asset] = [:]

    /// One snapshot per update: ids/order/edit/metadata decide the list; selection/anchor only move
    /// the ring. No per-property refresh paths.
    private struct ModelSnapshot: Equatable {
        var ids: [String]
        var edit: Int
        var metadata: Int
    }
    private var lastSnapshot: ModelSnapshot?

    private func modelSnapshot(_ session: CatalogSession) -> ModelSnapshot {
        ModelSnapshot(ids: session.assets.map(\.id),
                      edit: session.persistCount,
                      metadata: session.metadataRevision)
    }
    private weak var session: CatalogSession?
    private var isApplyingModel = false
    public var onActivate: ((String) -> Void)?

    // MARK: thumbnails

    /// Lazily created through `ThumbnailProvider.shared(for:)`, so this is the *same* instance the
    /// grid uses for the same library cache.
    private var thumbnailProvider: ThumbnailProvider?
    private var providerCache: ThumbnailCache?
    /// Outstanding loads by item index. One per index; cancelled the moment the cell scrolls out.
    private var thumbRequests: [Int: ThumbnailRequest] = [:]
    private var reconcileWork: DispatchWorkItem?
    private var cellTier: ThumbTier = .t256
    private var lastWanted: Set<Int> = []
    private var lastTier: ThumbTier?

    public init(session: CatalogSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func loadView() {
        flow.scrollDirection = .horizontal
        flow.itemSize = WorkspaceLayout.filmstripCell
        flow.minimumInteritemSpacing = WorkspaceLayout.filmstripSpacing
        flow.minimumLineSpacing = WorkspaceLayout.filmstripSpacing
        flow.sectionInset = NSEdgeInsets(top: WorkspaceLayout.filmstripInsetTop,
                                         left: WorkspaceLayout.filmstripInsetH,
                                         bottom: WorkspaceLayout.filmstripInsetBottom,
                                         right: WorkspaceLayout.filmstripInsetH)

        collectionView.collectionViewLayout = flow
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FilmstripCell.self, forItemWithIdentifier: FilmstripCell.reuseIdentifier)
        collectionView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        // 119: a double-click opens the photo under the pointer, exactly like the grid's. The strip
        // used to open only the anchor (Return); "double-click which one, open that one" needs the
        // hit row, and only this view knows it.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(doubleClick)

        // Same two verbs as the grid, on the same kind of menu.
        contextMenu.onRemove = { [weak self] ids in self?.removeAssets(ids) }
        contextMenu.onRemoveAndDelete = { [weak self] ids in self?.removeAndDeleteAssets(ids) }
        contextMenu.onFindLost = { [weak self] ids in self?.findAndRelinkMissingAssets(ids) }
        contextMenu.albumsProvider = { [weak self] ids in
            AlbumMenuSupport.items(session: self?.session, ids: ids)
        }
        contextMenu.onAddToAlbum = { [weak self] ids, albumID in
            AlbumMenuSupport.add(ids, albumID: albumID, session: self?.session)
        }
        contextMenu.onRemoveFromAlbum = { [weak self] ids, albumID in
            AlbumMenuSupport.remove(ids, albumID: albumID, session: self?.session)
        }
        collectionView.contextMenuProvider = { [weak self] event in self?.menuForRightClick(event) }

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Same hook as the grid: a horizontal scroll changes "what is visible", and that decides
        // which requests stay alive (006 §5).
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsChanged),
                                              name: NSView.boundsDidChangeNotification,
                                              object: scroll.contentView)
        view = scroll
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        makeDiffableDataSource()
        refresh()
        observeModel()
    }

    private func makeDiffableDataSource() {
        diffableDataSource = NSCollectionViewDiffableDataSource<Section, String>(
            collectionView: collectionView) { [weak self] collectionView, indexPath, id in
                guard let self, let asset = self.assetsByID[id] else { return nil }
                let item = collectionView.makeItem(withIdentifier: FilmstripCell.reuseIdentifier,
                                                   for: indexPath)
                guard let cell = item as? FilmstripCell else { return item }
                cell.configure(asset: asset, isActive: self.session?.anchorID == asset.id)
                self.applyThumbnail(to: cell, index: indexPath.item, asset: asset)
                return item
            }
        // A diffable data source starts with **no sections**; the collection view (and tests) may
        // ask for section 0 before the first refresh. Install the empty section once, now.
        var initial = NSDiffableDataSourceSnapshot<Section, String>()
        initial.appendSections([.main])
        diffableDataSource.apply(initial, animatingDifferences: false)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        fitItemHeightToContainer()
        scheduleThumbnailReconcile()
    }

    /// `scrollDirection = .horizontal` does **not** mean "one row". A horizontal
    /// `NSCollectionViewFlowLayout` still fills a **column** top-to-bottom before it wraps to the next
    /// column — its "lines" run vertically — so the row count is whatever packing the available height
    /// allows. That is exactly how the strip rendered two rows while already being `.horizontal`: the
    /// 122 pt container gave 122 − 8 − 6 = 108 pt of column, which held 50 + 8 + 50 = two cells and one
    /// gap.
    ///
    /// So the item size is derived from the live container instead of being a free-standing constant:
    /// the height comes from the container and the width from the image's 3:2 aspect
    /// (`WorkspaceLayout.filmstripCell(forContainerHeight:)`), and if the strip is ever made taller
    /// the cell grows in both dimensions rather than the column wrapping. One item per column, by
    /// construction — not by intent.
    private func fitItemHeightToContainer() {
        let container = view.bounds.height
        let insets = WorkspaceLayout.filmstripInsetTop + WorkspaceLayout.filmstripInsetBottom
        // Before the first real layout (`bounds == .zero`) keep the contract size.
        guard container > insets + 1 else { return }
        let wanted = WorkspaceLayout.filmstripCell(forContainerHeight: container)
        guard abs(flow.itemSize.height - wanted.height) > 0.01
                || abs(flow.itemSize.width - wanted.width) > 0.01 else { return }
        flow.itemSize = wanted
        flow.invalidateLayout()
    }

    @objc private func clipViewBoundsChanged() {
        scheduleThumbnailReconcile()
    }

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets
            _ = session.selection
            _ = session.anchorID
            _ = session.metadataRevision
            // 排序（与网格、左侧栏同一个值）：点了按钮，胶片条按 `session.assets` 的新顺序重排。
            _ = session.sortOrder
            // 218 — a commit moved the thumbnail key; re-ask instead of redrawing the old pixels.
            _ = session.persistCount
        }, { [weak self] in
            self?.applyModelSnapshot()
        })
    }

    private func applyModelSnapshot() {
        guard isViewLoaded, let session else { return }
        let next = modelSnapshot(session)
        guard next != lastSnapshot else {
            updateSelectionAndActive()
            return
        }
        lastSnapshot = next
        refresh()
    }

    /// Selection/anchor are view state: update the rings in place, never reload the cells.
    public func updateSelectionAndActive() {
        guard isViewLoaded, let session else { return }
        applySelectionFromModel()
        for path in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: path) as? FilmstripCell,
                  let asset = cell.cardView.asset else { continue }
            cell.cardView.isActive = session.anchorID == asset.id
        }
    }

    public func refresh() {
        guard isViewLoaded else { return }
        // One snapshot, applied once; item identity is the asset id, so a filter/sort moves cells
        // instead of recycling them by index (and their CAMetalLayers) wholesale.
        assetsByID = Dictionary(uniqueKeysWithValues: (session?.assets ?? []).map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems((session?.assets ?? []).map(\.id), toSection: .main)
        isApplyingModel = true
        // `animatingDifferences: false` is documented as a reloadData (no diff), which would
        // recycle the cells and defeat the identity. Use the diff, with a zero-length animation
        // so filter/sort changes do not visibly slide.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            diffableDataSource.apply(snapshot, animatingDifferences: true)
        }
        isApplyingModel = false
        applySelectionFromModel()
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleThumbnails()
            self?.reconcileThumbnails(force: true)
        }
        if let session { lastSnapshot = modelSnapshot(session) }
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        session?.assets.count ?? 0
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripCell.reuseIdentifier, for: indexPath)
        guard let cell = item as? FilmstripCell, let session, let asset = session.assets[safe: indexPath.item] else {
            return item
        }
        cell.configure(asset: asset, isActive: session.anchorID == asset.id)
        applyThumbnail(to: cell, index: indexPath.item, asset: asset)
        return cell
    }

    // MARK: thumbnails

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? 2
    }

    /// 223 — the swatch is the cell minus its 12 pt filename caption; this is the real pixel size
    /// the cache decodes to (90 × 60 pt → 180 × 120 px at 2×).
    private var displayPixels: ImageSize {
        ThumbnailProvider.displayPixels(
            swatch: CGSize(width: flow.itemSize.width,
                           height: max(1, flow.itemSize.height - WorkspaceLayout.filmstripCaptionHeight)),
            backingScale: backingScale)
    }

    /// 223 — the bitmap size every strip cell asks the cache for (222 × 114 px at 2×).
    public var displayPixelSize: ImageSize { displayPixels }

    // MARK: right-click (same verbs as the grid)

    public func menuForRightClick(_ event: NSEvent?) -> NSMenu? {
        guard let session else { return nil }
        if let event, event.window != nil {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            if let indexPath = collectionView.indexPathForItem(at: point),
               let asset = session.assets[safe: indexPath.item], !session.selection.contains(asset.id) {
                session.selectOnly(asset.id)
            }
        }
        contextMenu.update(selectedIDs: session.selectedAssets.map(\.id),
                           missingIDs: session.missingAssets.map(\.id))
        return contextMenu.menu
    }

    /// 「移出照片库」: rows + history + thumbnails, no confirmation (the file stays).
    public func removeAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.remove(ids, session: session, window: view.window)
    }

    /// 「移出并删除…」: one confirmation, then recycle the originals and remove the rows.
    public func removeAndDeleteAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.removeAndDelete(ids, session: session, window: view.window)
    }

    public func findAndRelinkMissingAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.findLost(ids, session: session, window: view.window)
    }

    private func provider() -> ThumbnailProvider? {
        guard let cache = session?.thumbnailCache else { return nil }
        if let thumbnailProvider, providerCache === cache { return thumbnailProvider }
        // A different library is a different cache directory: drop the old requests first.
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        lastWanted = []
        lastTier = nil
        providerCache = cache
        let made = ThumbnailProvider.shared(for: cache)
        thumbnailProvider = made
        return made
    }

    /// The tier a 90 × 72 pt cell should ask for: cell edge × DPR, clamped to what the source can
    /// fill (`ThumbnailProvider.tier`), then to the pipeline ceiling (`effectiveTier`, §6.1).
    private func tier(for asset: Asset) -> ThumbTier {
        let edge = max(flow.itemSize.width, flow.itemSize.height)
        let requested = ThumbnailProvider.tier(cellEdgePoints: edge,
                                               backingScale: backingScale,
                                               sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: asset))
        return ThumbnailProvider.effectiveTier(requested: requested, ext: asset.ext).tier
    }

    private func applyThumbnail(to cell: FilmstripCell, index: Int, asset: Asset) {
        guard let provider = provider() else { return }
        let tier = tier(for: asset)
        cell.cardView.thumbnailTier = tier
        let display = displayPixels
        cell.cardView.thumbnailDisplayPixels = display
        let document = document(for: asset)
        let key = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        if let cached = provider.serveFromMemory(for: key, display: display) {
            cell.cardView.applyThumbnail(cached, key: key, display: display)
            return
        }
        // A missing original has nothing to decode: only an already-cached thumbnail may stand in,
        // otherwise the cell keeps its placeholder and its badge (identical rule to the grid).
        if asset.isMissing {
            guard provider.cache.exists(key) else { return }
        }
        if let previous = provider.placeholderImage(contentHash: asset.contentHash, display: display) {
            cell.cardView.applyThumbnail(previous, key: key, display: display)
        }
        requestThumbnail(index: index, asset: asset, tier: tier, display: display, priority: .onScreen)
    }

    /// The live document for the anchor photo, the stored one for every other row (218 key input).
    private func document(for asset: Asset) -> EditModel {
        guard let session else { return .neutral }
        if asset.id == session.loadedEditAssetID { return session.edit }
        return ThumbnailProvider.document(from: asset)
    }

    private func requestThumbnail(index: Int, asset: Asset, tier: ThumbTier,
                                  display: ImageSize, priority: ThumbPriority) {
        guard let provider = provider(), thumbRequests[index] == nil else { return }
        guard let session, let url = session.fileURL(for: asset) else { return }
        let token = provider.request(index: index, asset: asset, fileURL: url,
                                     document: document(for: asset), tier: tier, spec: .hdJPEG,
                                     display: display,
                                     priority: priority) { [weak self] idx, key, image in
            self?.thumbnailDidLoad(index: idx, key: key, display: display, image: image)
        }
        thumbRequests[index] = token
    }

    private func thumbnailDidLoad(index: Int, key: ThumbKey, display: ImageSize, image: CGImage?) {
        thumbRequests[index] = nil
        guard let image, let session, index >= 0, index < session.assets.count else { return }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.item(at: path) as? FilmstripCell else { return }
        // The cell may have been recycled between request and delivery; the asset id is the guard.
        guard cell.cardView.asset?.id == session.assets[index].id else { return }
        cell.cardView.thumbnailTier = key.tier
        cell.cardView.applyThumbnail(image, key: key, display: display)
    }

    private func scheduleThumbnailReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcileThumbnails(force: false) }
        reconcileWork = work
        // One frame of coalescing: a live scroll fires this dozens of times per second and the
        // answer only changes when the visible index range changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    /// Visible cells plus one cell of slack on either side (006 §5 "可见 + 上下一行"; horizontally
    /// that is one cell). Everything else is cancelled, index by index.
    /// Same-key re-application is a no-op inside the card; this only does work for a changed edit.
    private func refreshVisibleThumbnails() {
        guard let session else { return }
        for path in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: path) as? FilmstripCell,
                  let asset = cell.cardView.asset,
                  let index = session.assets.firstIndex(where: { $0.id == asset.id }) else { continue }
            applyThumbnail(to: cell, index: index, asset: asset)
        }
    }

    /// 303 — after an edit, re-ask for the one photo that moved. Only a cell that is on screen is
    /// refreshed; an off-screen cell computes the new key when it is configured again.
    public func refreshThumbnail(forAssetID id: String) {
        guard isViewLoaded, let session,
              let index = session.assets.firstIndex(where: { $0.id == id }) else { return }
        let path = IndexPath(item: index, section: 0)
        guard collectionView.indexPathsForVisibleItems().contains(path),
              let cell = collectionView.item(at: path) as? FilmstripCell,
              let asset = cell.cardView.asset, asset.id == id else { return }
        // The in-flight request still carries the pre-edit key; cancel it so it cannot repaint the
        // old frame after the new one arrives.
        thumbRequests[index]?.cancel()
        thumbRequests.removeValue(forKey: index)
        applyThumbnail(to: cell, index: index, asset: asset)
    }

    private func reconcileThumbnails(force: Bool) {
        guard isViewLoaded, let session, !session.assets.isEmpty, let provider = provider() else { return }

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

        let wanted = wantedIndexes()
        if !force, wanted == lastWanted { return }
        lastWanted = wanted
        let visible = visibleIndexes()

        for (index, token) in thumbRequests where !wanted.contains(index) {
            token.cancel()
            thumbRequests.removeValue(forKey: index)
        }

        let display = displayPixels
        for index in wanted {
            guard index < session.assets.count else { continue }
            let asset = session.assets[index]
            if provider.memoryImage(for: ThumbnailProvider.hdJPEGKey(for: asset,
                                                                 document: document(for: asset)),
                                     display: display) != nil { continue }
            if thumbRequests[index] != nil { continue }
            // §4 ①②: the selected/anchor cell wins even if it is only in the slack band; the rest of
            // the visible window is on-screen work; the slack is prefetch.
            let isAnchor = session.anchorID == asset.id || session.selection.contains(asset.id)
            let priority: ThumbPriority = (isAnchor || visible.contains(index)) ? .onScreen : .prefetch
            requestThumbnail(index: index, asset: asset, tier: cellTier, display: display,
                             priority: priority)
        }
    }

    private func visibleIndexes() -> Set<Int> {
        Set(collectionView.indexPathsForVisibleItems().map { $0.item })
    }

    private func wantedIndexes() -> Set<Int> {
        guard let scroll = collectionView.enclosingScrollView else { return [] }
        let bounds = scroll.contentView.bounds
        let slack = max(24, flow.itemSize.width)
        let expanded = bounds.insetBy(dx: -slack, dy: 0)
        guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForElements(in: expanded)
        else { return [] }
        return Set(attributes.compactMap { $0.indexPath?.item })
    }

    // MARK: thumbnail probes (used by `--ui-smoke`)

    /// The provider this strip draws from — the smoke asserts it is `===` the grid's.
    public var thumbnailProviderForSmoke: ThumbnailProvider? { provider() }

    public var thumbnailStats: ThumbnailProvider.Stats {
        thumbnailProvider?.stats ?? ThumbnailProvider.Stats()
    }

    public var currentThumbnailTier: ThumbTier { cellTier }

    public var pendingThumbnailRequests: Int { thumbRequests.count }

    /// Outstanding requests for indices that are no longer visible or in the slack band. Must be 0
    /// once the scroll handler has run.
    public var pendingThumbnailIndexesOutsideWindow: Int {
        Set(thumbRequests.keys).subtracting(wantedIndexes()).count
    }

    public var visibleCellCount: Int { collectionView.indexPathsForVisibleItems().count }

    // MARK: layout probes (used by `--ui-smoke`)

    /// The item size the flow layout is actually applying — the smoke compares it to the contract.
    public var appliedItemSize: CGSize { flow.itemSize }

    /// Every laid-out item frame, in library order. Off-screen items resolve too (a one-row
    /// horizontal flow is arithmetic per column), so this is the whole strip, not a screenful.
    public var laidOutItemFrames: [NSRect] {
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return [] }
        return (0..<count).compactMap {
            collectionView.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
    }

    /// Distinct item `minY` baselines — **1 means the strip is one row**. This is the countable
    /// form of "single row": the old 122 pt container produced 2 (8+50+8+50+6) even though
    /// `scrollDirection` was already `.horizontal`.
    public var itemRowCount: Int {
        Set(laidOutItemFrames.map { ($0.minY * 100).rounded() }).count
    }

    /// Visible cells drawing a real thumbnail rather than the placeholder.
    public var visibleThumbnailCount: Int {
        collectionView.indexPathsForVisibleItems().reduce(0) { total, path in
            guard let cell = collectionView.item(at: path) as? FilmstripCell,
                  cell.cardView.thumbnail != nil else { return total }
            return total + 1
        }
    }

    /// Drop every outstanding request (library switch / teardown).
    public func resetThumbnails() {
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        lastWanted = []
        lastTier = nil
        thumbnailProvider = nil
        providerCache = nil
    }

    // MARK: selection

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingModel else { return }
        writeSelectionToModel(collectionView)
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingModel else { return }
        writeSelectionToModel(collectionView)
    }

    private func writeSelectionToModel(_ collectionView: NSCollectionView) {
        guard let session else { return }
        let ids = collectionView.selectionIndexPaths.compactMap { session.assets[safe: $0.item]?.id }
        let anchor = collectionView.selectionIndexPaths
            .compactMap { session.assets[safe: $0.item]?.id }
            .first { session.anchorID == $0 } ?? ids.first
        session.setSelection(Set(ids), anchor: anchor)
        updateSelectionAndActive()
        // The new anchor is priority ① for the next reconcile.
        scheduleThumbnailReconcile()
        revealAnchor()
    }

    public func applySelectionFromModel() {
        guard isViewLoaded, let session else { return }
        let paths = Set(session.assets.enumerated()
            .filter { session.selection.contains($0.element.id) }
            .map { IndexPath(item: $0.offset, section: 0) })
        guard paths != collectionView.selectionIndexPaths else { return }
        isApplyingModel = true
        collectionView.selectionIndexPaths = paths
        isApplyingModel = false
    }

    public func revealAnchor() {
        guard let session, let id = session.anchorID,
              let index = session.assets.firstIndex(where: { $0.id == id }) else { return }
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)],
                                     scrollPosition: .nearestHorizontalEdge)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        // Same table as the grid: the strip is a second browser over the same selection.
        if RatingShortcuts.handle(event, session: session) { return true }
        switch event.keyCode {
        case 123: return session.moveAnchor(by: -1, extend: event.modifierFlags.contains(.shift))
        case 124: return session.moveAnchor(by: 1, extend: event.modifierFlags.contains(.shift))
        case 36, 76:
            if let id = session.anchorID { onActivate?(id); return true }
            return false
        default:
            return false
        }
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        activateItem(at: recognizer.location(in: collectionView))
    }

    /// Open the cell under `point` (strip coordinates). `internal` so the test can drive the same
    /// hit-testing the gesture uses instead of guessing a window-space click.
    func activateItem(at point: NSPoint) {
        guard let session,
              let indexPath = collectionView.indexPathForItem(at: point),
              let asset = session.assets[safe: indexPath.item] else { return }
        onActivate?(asset.id)
    }

    /// Cells actually laid out — `--ui-smoke` asserts this against the library row count.
    public var itemCount: Int { collectionView.numberOfItems(inSection: 0) }

    /// The photos the strip is **actually drawing**, left to right.
    ///
    /// Read off the live cells (`cardView.asset`) for the same reason the grid's probe is: a strip
    /// that had not followed a sort change would still be showing the old sequence, and this is the
    /// array the three-view consistency assertion compares.
    public var renderedAssetIDs: [String] {
        collectionView.indexPathsForVisibleItems()
            .sorted { ($0.section, $0.item) < ($1.section, $1.item) }
            .compactMap { (collectionView.item(at: $0) as? FilmstripCell)?.cardView.asset?.id }
    }
}
