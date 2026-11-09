import AppKit
import PhotonsCatalog
import PhotonsCore

/// The photo grid: `NSCollectionView` + flow layout + recycled placeholder cells.
///
/// Research `ui-stack.md` F2: the two projects that reached Lightroom-class libraries split on this
/// — one kept `NSCollectionView` + diffable data source, the other (redlamp) wrote 5,736 lines of
/// custom layer recycling. The note is explicit that the hand-rolled grid is the *ceiling*, not the
/// starting point; so M3 starts here, and `make ui-smoke` / the 10k scroll measurement decide
/// whether M3.5 needs the other path.
public final class AssetCollectionView: NSCollectionView {
    public var onKeyDown: ((NSEvent) -> Bool)?
    /// Right-click plumbing. AppKit asks the *view* for its menu, and only the view knows where the
    /// click landed — a right-click on an unselected cell means that cell, so the resolution has to
    /// happen here (where the event is) and not in `validateMenuItem`.
    public var contextMenuProvider: ((NSEvent?) -> NSMenu?)?

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }
}

/// The card's image surface: a `CAMetalLayer` showing the float extended-linear P3 bitmap
/// `ThumbnailProvider.decodeHD` produced.
///
/// 227 — a `CALayer` with EDR contents let macOS tone map the picture and lift reference white towards
/// the panel's maximum on an HDR display ("SDR white = screen max brightness"). A `CAMetalLayer`
/// does not tone map: EDR `1.0` stays SDR white and values above 1 use the current headroom. The
/// bitmap still lives in the provider's memory LRU; this view owns only the GPU copy for its cell.
///
/// No Metal (headless/VM): falls back to a plain SDR `CALayer`, so the grid still draws.
final class ThumbnailEDRView: NSView {
    var image: CGImage? {
        didSet {
            guard let image else {
                surface?.setImage(nil)
                if surface == nil { layer?.contents = nil }
                isHidden = true
                return
            }
            if let surface {
                // Stay hidden until the new drawable is on the compositor. Otherwise a recycled
                // CAMetalLayer shows its previous photo for one frame ("wrong photo, then correct").
                isHidden = true
                surface.setImage(image) { [weak self] in self?.isHidden = false }
            } else {
                layer?.contents = image
                isHidden = false
            }
        }
    }

    private let cornerRadius: CGFloat
    private var surface: ThumbnailMetalSurface?

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        if let metal = layer as? CAMetalLayer {
            surface = ThumbnailMetalSurface(layer: metal, cornerRadius: cornerRadius)
        } else {
            layer?.contentsGravity = .resizeAspectFill
            layer?.masksToBounds = true
            layer?.cornerRadius = cornerRadius
        }
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    override func makeBackingLayer() -> CALayer {
        if ThumbnailMetalRenderer.shared.isAvailable {
            return CAMetalLayer()
        }
        let fallback = CALayer()
        fallback.contentsGravity = .resizeAspectFill
        fallback.masksToBounds = true
        fallback.cornerRadius = cornerRadius
        return fallback
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        surface?.layout(size: bounds.size, scale: scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Offscreen render of this cell's layer contents (orientation/HDR read-back in tests).
    func renderForTesting(width: Int, height: Int) -> MTLTexture? {
        surface?.renderOffscreen(width: width, height: height)
    }

    /// Drawables this surface has presented (0 before layout/on a headless session).
    var presentedFramesForTesting: Int { surface?.presentCount ?? 0 }
}

/// Transparent sibling *above* `ThumbnailEDRView`: a sublayer's contents always composite above the
/// parent view's own `draw`, so the ring/badges/caption need their own surface to stay on top.
private final class CardOverlayView: NSView {
    weak var card: AssetCardView?

    override var isFlipped: Bool { true }

    /// Clicks belong to the card (context menu, selection), never to this transparent sheet.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        card?.drawForeground()
    }
}

/// One card: the thumbnail (when we have one), else the hash-derived placeholder block, plus the
/// filename and stars.
///
/// The placeholder is never removed: a missing, failed or still-loading thumbnail draws the
/// M3 swatch underneath, so a cell is never a white hole and a failure looks like "not yet",
/// not like "broken".
///
/// 223 — the image is a **layer** (`ThumbnailEDRView`) so it can hold a float extended-range
/// bitmap. Its two siblings keep the old drawing path: the card itself paints the gradient under
/// it, and a transparent overlay paints the ring/badges over it.
public final class AssetCardView: NSView {
    public var asset: Asset? { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isActive: Bool = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isPicked: Bool = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }

    /// 223 — the image lives in its own layer so it can be an EDR surface (float contents); the
    /// placeholder, ring, caption and badges stay in ordinary `draw` above/below it.
    private let thumbnailView = ThumbnailEDRView(cornerRadius: WorkspaceLayout.cardCornerRadius)
    private let overlay = CardOverlayView()

    /// What the last `draw` painted in the corners ("stars:3", "flag:pick", "color:red"). The smoke
    /// reads this back off the cell that actually painted, so "the badge is drawn" is an observation
    /// and not an inference from `asset.rating`.
    public private(set) var lastDrawnBadges: [String] = []

    /// The 「原文件已移动」 line this card would draw, or nil for a healthy file.
    ///
    /// Exposed as a *string* (not only as pixels) on purpose: the badge has to be assertable from a
    /// test and readable from a log, and "there is a pill somewhere in this rect" is not a fact a
    /// test can state.
    public var missingLabel: String? { asset?.isMissing == true ? MissingFileText.moved : nil }

    /// What the last `draw` actually painted — set inside `draw`, so it is evidence and not intent.
    public private(set) var lastDrawnMissingLabel: String?

    /// The badge this cell would draw — handy for a log line and for the smoke's expected value.
    public var badgeSignature: String { asset.map { AssetBadges(asset: $0).signature } ?? "—" }

    /// The decoded thumbnail for this asset, or nil while the placeholder is all we have.
    public var thumbnail: CGImage? {
        didSet {
            thumbnailView.image = thumbnail
            overlay.needsDisplay = true
        }
    }
    /// The identity of the pixels currently in `thumbnail`. Re-applying the same key/bitmap is a
    /// **no-op**: a refresh that did not change this file must not hide or re-present the layer.
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
    /// Which tier the current image came from — printed by `--ui-smoke` and used to prove the cell
    /// asked for the size it should have (006 §1).
    public var thumbnailTier: ThumbTier?
    /// 223 — the pixel rectangle this card asked the provider for (for probes and logs).
    public var thumbnailDisplayPixels: ImageSize?

    /// The EDR surface, exposed so a test can read back `wantsExtendedDynamicRangeContent`,
    /// `contentsFormat` and the actual float pixels (acceptance 223 §3).
    public var thumbnailLayer: CALayer? { thumbnailView.layer }

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        thumbnailView.isHidden = true
        addSubview(thumbnailView)
        overlay.card = self
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { false }

    public override func layout() {
        super.layout()
        let rect = swatchRect
        thumbnailView.frame = rect
        overlay.frame = bounds
    }

    private var swatchRect: NSRect {
        let labelHeight = GridLayout.labelHeight
        return NSRect(x: 0, y: 0, width: bounds.width,
                      height: max(1, bounds.height - labelHeight))
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let asset else { return }
        let swatchRect = self.swatchRect
        let radius: CGFloat = WorkspaceLayout.cardCornerRadius

        let path = NSBezierPath(roundedRect: swatchRect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let primary = PlaceholderSwatch.color(for: asset.contentHash)
        let secondary = PlaceholderSwatch.secondaryColor(for: asset.contentHash)
        NSGradient(starting: primary, ending: secondary)?.draw(in: path, angle: -90)

        if thumbnail == nil {
            // A thin "this is a placeholder" rule set: one diagonal + the extension, no image work.
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let diag = NSBezierPath()
            diag.move(to: NSPoint(x: swatchRect.minX, y: swatchRect.maxY))
            diag.line(to: NSPoint(x: swatchRect.maxX, y: swatchRect.minY))
            diag.lineWidth = 1
            diag.stroke()

            let ext = asset.ext.uppercased()
            (ext as NSString).draw(at: NSPoint(x: 8, y: 6), withAttributes: PlaceholderStyle.captionAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Everything that composites *above* the EDR image: the selection ring and the badges. Called
    /// by `overlay`, which sits above `thumbnailView` in the subview order so a sublayer image can
    /// never cover the star the user is looking at.
    fileprivate func drawForeground() {
        guard let asset else { return }
        let bounds = self.bounds
        let swatchRect = self.swatchRect
        let radius: CGFloat = WorkspaceLayout.cardCornerRadius

        // Selection / active ring: accent for the anchor, softer accent for the rest of the selection.
        if isPicked || isActive {
            let ring = NSBezierPath(roundedRect: swatchRect.insetBy(dx: 0.75, dy: 0.75),
                                    xRadius: radius, yRadius: radius)
            (isActive ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.55)).setStroke()
            ring.lineWidth = isActive ? 2 : 1.5
            ring.stroke()
        }

        let captionRect = NSRect(x: 2, y: swatchRect.maxY + 4, width: bounds.width - 4,
                                 height: GridLayout.labelHeight - 6)
        (asset.filename as NSString).draw(in: captionRect, withAttributes: PlaceholderStyle.captionAttributes)

        // Stars / flag / colour label go *on* the thumbnail, in its corners — not in the caption
        // strip. The placeholder block stays underneath (006 §2), so a cell without a thumbnail
        // still shows its rating.
        let badges = AssetBadges(asset: asset)
        badges.draw(in: swatchRect)

        // 「原文件已移动」 is an overlay of its own, drawn last: it is the one thing on this card the
        // user has to act on, and it must never be covered by a star.
        lastDrawnMissingLabel = nil
        if let missingLabel {
            MissingFileBadge.draw(in: swatchRect)
            lastDrawnMissingLabel = missingLabel
        }
        lastDrawnBadges = missingLabel == nil ? badges.drawn : badges.drawn + ["missing"]
    }
}

public final class AssetGridItem: NSCollectionViewItem {
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("AssetGridItem")

    private let card = AssetCardView()

    public override func loadView() {
        card.wantsLayer = false
        view = card
    }

    public var cardView: AssetCardView { card }

    public override var isSelected: Bool {
        didSet { card.isPicked = isSelected }
    }

    public override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { card.needsDisplay = true }
    }

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

/// Owns the grid, its layout and the keyboard rules; reads and writes `CatalogSession` only.
public final class AssetGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    public let collectionView = AssetCollectionView()
    public let scrollView = NSScrollView()
    /// The filter strip: 星级 ≥ N / 旗标 / 色标 / 相机 + one chip per active facet.
    public let filterBar = FilterBarView()
    /// 右键：从库中删除… / 查找丢失的文件… — shared code, one instance per browser.
    public let contextMenu = AssetContextMenu()
    private let container = FlippedCanvasView()
    private let flow = NSCollectionViewFlowLayout()
    private let bridge = ObservationBridge()

    /// Diffable identity: the item identifier is the **asset id**, never the index. A filter/sort
    /// moves the same cell with its photo instead of recycling every cell by index.
    private enum Section: Hashable { case main }
    private var diffableDataSource: NSCollectionViewDiffableDataSource<Section, String>!
    private var assetsByID: [String: Asset] = [:]

    /// One model decision, made from a snapshot instead of from individual properties. The list
    /// (ids + order), the edit/metadata generation and the filter decide whether the cells are
    /// rebuilt; selection/anchor are the only things that may change without rebuilding them.
    private struct ModelSnapshot: Equatable {
        var ids: [String]
        var edit: Int
        var metadata: Int
        var filter: String
        var cameras: [String]
    }
    private var lastSnapshot: ModelSnapshot?

    private func modelSnapshot(_ session: CatalogSession) -> ModelSnapshot {
        ModelSnapshot(ids: session.assets.map(\.id),
                      edit: session.persistCount,
                      metadata: session.metadataRevision,
                      filter: String(describing: session.filter),
                      cameras: session.allCameraKeys)
    }
    private weak var session: CatalogSession?
    private var isApplyingModel = false
    private(set) public var metrics = GridLayout.metrics(forWidth: 800)
    public private(set) var reloadCount = 0

    // MARK: thumbnails

    /// Created on first use: the cache only exists once a library is open. Obtained from
    /// `ThumbnailProvider.shared(for:)` so the filmstrip draws from the *same* service and LRU.
    private var thumbnailProvider: ThumbnailProvider?
    private var providerCache: ThumbnailCache?
    /// Outstanding loads by item index. One per index, cancelled the moment the cell scrolls away.
    private var thumbRequests: [Int: ThumbnailRequest] = [:]
    private var reconcileWork: DispatchWorkItem?
    private var cellTier: ThumbTier = .t256
    /// Signatures of the last reconcile pass, so the scroll handler does no work when nothing
    /// visible changed (the main thread budget is 8 ms, 006 §5).
    private var lastWanted: Set<Int> = []
    private var lastTier: ThumbTier?
    private var lastLibraryURL: URL?
    private var loggedMissingCache = false

    /// Open the anchor in the loupe (double-click / Return).
    public var onActivate: ((String) -> Void)?

    public init(session: CatalogSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func loadView() {
        collectionView.collectionViewLayout = flow
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true   // ⌘ / ⇧ come from AppKit
        collectionView.allowsEmptySelection = false
        // 054/061: the grid's own surface is the canvas matte, not the window background showing
        // through a clear collection view. Same stop as the loupe's bands, so the two views are one
        // colour instead of "darkish" and "slightly different darkish". 315: the stop is a preference,
        // and both surfaces store it — `canvasBackdropChanged` re-reads them.
        collectionView.backgroundColors = [.canvasMatte]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AssetGridItem.self, forItemWithIdentifier: AssetGridItem.reuseIdentifier)
        collectionView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        // Context menu: attach the shared menu, resolve the clicked cell here (only this view knows
        // where the event landed), and let the verbs run through the session.
        contextMenu.onRemove = { [weak self] ids in self?.removeAssets(ids) }
        contextMenu.onRemoveAndDelete = { [weak self] ids in self?.removeAndDeleteAssets(ids) }
        contextMenu.onFindLost = { [weak self] ids in self?.findAndRelinkMissingAssets(ids) }
        // 相册（078 B10）：同一个 `AssetContextMenu` 对象在三个面共用，所以三个面拿到的
        // 「加入相册 / 移出相册」是同一份代码，不是三份。写入走 session（一次事务），
        // 再由观察桥重画三个面。
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

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(doubleClick)

        let scroll = scrollView
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .canvasMatte
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // 315 — both of those assignments **store** the colour; a preference change has to reach them.
        NotificationCenter.default.addObserver(self, selector: #selector(canvasBackdropChanged),
                                              name: .canvasBackdropDidChange, object: nil)
        // Scrolling is what changes "what is visible", and that is what decides which in-flight
        // requests stay alive (006 §5). `postsBoundsChangedNotifications` is the cheapest hook —
        // no delegate, no timer.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsChanged),
                                              name: NSView.boundsDidChangeNotification,
                                              object: scroll.contentView)

        // Filter strip on top, grid below: the bar is a view of `CatalogSession.filter`, so the
        // grid area and the row order come from one query, never from a post-hoc UI filter.
        filterBar.onChange = { [weak self] next in self?.session?.applyFilter(next) }
        filterBar.onClearAll = { [weak self] in self?.session?.clearFilter() }
        // The slot menus must offer **this library's** values (026's hard constraint), so the bar
        // asks the session, which asks the catalog with the current filter folded in.
        filterBar.facetProvider = { [weak self] dimension in
            self?.session?.facetValues(dimension) ?? []
        }
        container.addSubview(filterBar)
        container.addSubview(scroll)
        view = container
    }

    /// The frame below the filter strip — the flow layout's input.
    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutGrid()
        updateMetrics()
        scheduleThumbnailReconcile()
    }

    private func layoutGrid() {
        let h = FilterBarView.height
        let b = view.bounds
        filterBar.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        scrollView.frame = NSRect(x: 0, y: h, width: b.width, height: max(0, b.height - h))
        filterBar.needsLayout = true
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
                let item = collectionView.makeItem(withIdentifier: AssetGridItem.reuseIdentifier,
                                                   for: indexPath)
                guard let cell = item as? AssetGridItem else { return item }
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

    @objc private func clipViewBoundsChanged() {
        scheduleThumbnailReconcile()
    }

    /// 315 — the two surfaces that store the matte (`NSCollectionView.backgroundColors` and the
    /// enclosing scroll view's background) re-read it when the preference moves. Both are set in
    /// `loadView` from the same `NSColor.canvasMatte`, so this keeps "one colour" true after a change.
    @objc private func canvasBackdropChanged() {
        collectionView.backgroundColors = [.canvasMatte]
        scrollView.backgroundColor = .canvasMatte
    }

    // MARK: model plumbing

    private func observeModel() {
        guard session != nil else { return }
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets
            _ = session.selection
            _ = session.anchorID
            // A rating/flag/colour write repaints the badges; a filter change re-ran the query.
            _ = session.metadataRevision
            _ = session.filter
            _ = session.allCameraKeys
            // 排序是会话上的一个值，三个视图都读它：这一行就是「点了按钮，网格跟着重排」的全部接线
            // （`reloadData` 复用的还是同一批单元格，缩略图从内存层同步取出，不重新解码）。
            _ = session.sortOrder
            // 218 — every commit (and undo) writes the catalog; the thumbnail key moved with it, so
            // the next reconcile must re-ask instead of reusing the old cell image.
            _ = session.persistCount
        }, { [weak self] in
            self?.applyModelSnapshot()
        })
    }

    /// The one update path. Build the snapshot first, then either rebuild the list once or only
    /// move the selection/active ring — never refresh thumbnails for a selection change.
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

    /// Selection and anchor are view state: update the rings in place. **Never** reload the cells —
    /// that would clear each thumbnail and re-ask the provider, which is the flash this exists to
    /// prevent.
    public func updateSelectionAndActive() {
        guard isViewLoaded, let session else { return }
        applySelectionFromModel()
        for path in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: path) as? AssetGridItem,
                  let asset = item.cardView.asset else { continue }
            item.cardView.isActive = session.anchorID == asset.id
        }
    }

    public func refresh() {
        guard isViewLoaded else { return }
        // A different library means a different cache directory: drop the memory layer so the grid
        // can never show the previous library's pixels.
        if let url = session?.libraryURL, url != lastLibraryURL {
            lastLibraryURL = url
            resetThumbnails()
        }
        let before = collectionView.numberOfSections > 0
            ? collectionView.numberOfItems(inSection: 0) : 0
        updateMetrics()
        // One snapshot, applied once. Item identity is the asset id, so adding a camera filter or
        // changing sort moves cells instead of recycling them (and their thumbnails) by index.
        assetsByID = Dictionary(uniqueKeysWithValues: (session?.assets ?? []).map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems((session?.assets ?? []).map(\.id), toSection: .main)
        // `apply` may clear the selection transiently; the model is the truth, so keep the
        // selection callbacks from writing AppKit's transient state back.
        isApplyingModel = true
        // `animatingDifferences: false` is documented as a reloadData (no diff), which would
        // recycle the cells and defeat the identity. Use the diff, with a zero-length animation
        // so filter/sort changes do not visibly slide.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            diffableDataSource.apply(snapshot, animatingDifferences: true)
        }
        isApplyingModel = false
        reloadCount += 1
        filterBar.update(filter: session?.filter ?? .none,
                         cameraKeys: session?.allCameraKeys ?? [],
                         cameraLabels: session?.allCameraLabels ?? [:])
        applySelectionFromModel()
        if before == 0 { collectionView.scroll(.zero) }
        // A moved cell keeps its bitmap, but an edit (`persistCount`) can change a key without
        // changing the id. Re-apply from memory once the diffable pass has laid the cells out.
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleThumbnails()
            self?.reconcileThumbnails(force: true)
        }
        if let session { lastSnapshot = modelSnapshot(session) }
    }

    private func updateMetrics() {
        guard isViewLoaded else { return }
        let width = collectionView.bounds.width > 1
            ? collectionView.bounds.width
            : max(1, view.bounds.width)
        let m = GridLayout.metrics(forWidth: width)
        guard m != metrics else { return }
        metrics = m
        flow.itemSize = m.itemSize
        flow.minimumInteritemSpacing = m.spacing
        flow.minimumLineSpacing = m.spacing
        flow.sectionInset = NSEdgeInsets(top: m.inset, left: m.inset, bottom: m.inset, right: m.inset)
        flow.invalidateLayout()
    }

    // MARK: data source

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        session?.assets.count ?? 0
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AssetGridItem.reuseIdentifier, for: indexPath)
        guard let cell = item as? AssetGridItem, let session, indexPath.item < session.assets.count else {
            return item
        }
        let asset = session.assets[indexPath.item]
        cell.configure(asset: asset, isActive: session.anchorID == asset.id)
        applyThumbnail(to: cell, index: indexPath.item, asset: asset)
        return cell
    }

    /// Show the best image we already hold, and queue a load when we hold none.
    ///
    /// The memory layer is synchronous on purpose: a cell that scrolls back into view must draw in
    /// the same frame (a spinner or a flash of placeholder would be a visible regression).
    ///
    /// A **missing** file is a third case: there are no bytes to decode, so a request could only
    /// ever fail. The cell draws a thumbnail only if one is already on disk (the key is
    /// content-addressed, so the pixels of a moved file are still valid); otherwise it keeps the
    /// placeholder and the 「原文件已移动」 badge and asks for nothing. That is what keeps a missing
    /// entry from sitting in `pendingThumbnailRequests` forever, and it is the same terminal state
    /// the request path reaches on a failure — without the failed decode.
    private func applyThumbnail(to cell: AssetGridItem, index: Int, asset: Asset) {
        guard let provider = provider() else { return }
        let tier = tier(for: asset)
        cell.cardView.thumbnailTier = tier
        let display = displayPixels
        cell.cardView.thumbnailDisplayPixels = display
        let document = document(for: asset)
        let key = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        // `serveFromMemory` (not `memoryImage`) so a warm cell is counted as a hit rather than
        // disappearing from the statistics.
        if let cached = provider.serveFromMemory(for: key, display: display) {
            cell.cardView.applyThumbnail(cached, key: key, display: display)
            return
        }
        if asset.isMissing {
            guard provider.cache.exists(key) else { return }
        }
        // 218 — a commit changed the key, so the new one is a miss by construction; draw the
        // previous rendering while the rebuild runs instead of flashing the hash swatch.
        if let previous = provider.placeholderImage(contentHash: asset.contentHash, display: display) {
            cell.cardView.applyThumbnail(previous, key: key, display: display)
        }
        requestThumbnail(index: index, asset: asset, tier: tier, display: display, priority: .onScreen)
    }

    // MARK: thumbnails

    /// The live document for the anchor photo, the stored one for every other row. The thumbnail key
    /// is derived from this, which is how a slider commit changes the cache file the grid draws.
    private func document(for asset: Asset) -> EditModel {
        guard let session else { return .neutral }
        if asset.id == session.loadedEditAssetID { return session.edit }
        return ThumbnailProvider.document(from: asset)
    }

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? 2
    }

    /// 223 — the swatch's real pixel rectangle (the card is `itemSize` high including its 22 pt
    /// caption). This is the size the cache decodes to; 1920 is never requested by a cell.
    private var displayPixels: ImageSize {
        ThumbnailProvider.displayPixels(
            swatch: CGSize(width: metrics.itemSize.width,
                           height: max(1, metrics.itemSize.height - GridLayout.labelHeight)),
            backingScale: backingScale)
    }

    /// 223 — the bitmap size every grid cell asks the cache for (the acceptance read-back).
    public var displayPixelSize: ImageSize { displayPixels }

    /// The tier this cell should ask for: cell edge in points × DPR, clamped to what the source
    /// can actually fill, then to the preview ceiling (a DNG never gets a `> t512` placeholder,
    /// 006 §6.1). `GridLayout` gives the cell size; the grid never invents a number.
    private func tier(for asset: Asset) -> ThumbTier {
        let requested = ThumbnailProvider.tier(
            cellEdgePoints: max(metrics.itemSize.width, metrics.itemSize.height),
            backingScale: backingScale,
            sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: asset))
        return ThumbnailProvider.effectiveTier(requested: requested, ext: asset.ext).tier
    }

    private func provider() -> ThumbnailProvider? {
        guard let session else { return nil }
        guard let cache = session.thumbnailCache else {
            // A library is open but there is no cache: the only state in which no cell can ever get
            // pixels. Say it once — returning nil silently is how "the grid is a wall of swatches"
            // stayed invisible for a whole milestone.
            if session.isOpen, !loggedMissingCache {
                loggedMissingCache = true
                FileHandle.standardError.write(Data(
                    "photons: thumbnail cache unavailable for \(session.libraryURL?.path ?? "?") — grid cells stay placeholders\n".utf8))
            }
            return nil
        }
        if let thumbnailProvider, providerCache === cache { return thumbnailProvider }
        // A different library is a different cache directory: never keep drawing the previous
        // library's pixels (the service and its memory LRU belong to that cache).
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        providerCache = cache
        let made = ThumbnailProvider.shared(for: cache)
        thumbnailProvider = made
        return made
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
        // A nil image is a real answer ("no preview / unreadable"): the card keeps its placeholder.
        guard let image, let session, index >= 0, index < session.assets.count else { return }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.item(at: path) as? AssetGridItem else { return }
        // The cell may have been recycled between request and delivery; the asset id is the guard.
        guard cell.cardView.asset?.id == session.assets[index].id else { return }
        cell.cardView.applyThumbnail(image, key: key, display: display)
    }

    private func scheduleThumbnailReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcileThumbnails(force: false)
        }
        reconcileWork = work
        // One frame of coalescing: a live scroll fires this dozens of times per second and the
        // answer only changes when the visible *row range* changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    /// Visible items plus exactly one row either side (006 §5: prefetch is "visible + one row",
    /// computed from the layout function, not guessed in pixels). Everything else is cancelled.
    /// Re-apply the snapshot's thumbnails to whatever cells the diffable pass reused. Same key +
    /// same bitmap is a no-op inside the card, so this is cheap for an unchanged list.
    private func refreshVisibleThumbnails() {
        guard let session else { return }
        for path in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: path) as? AssetGridItem,
                  let asset = cell.cardView.asset,
                  let index = session.assets.firstIndex(where: { $0.id == asset.id }) else { continue }
            applyThumbnail(to: cell, index: index, asset: asset)
        }
    }

    /// 303 — after an edit, re-ask for the one photo that moved. Only a cell that is **on screen**
    /// is refreshed: an off-screen row will compute the new key when it is configured again, and
    /// walking the whole library here is exactly the 10k-row stall this feature must avoid.
    public func refreshThumbnail(forAssetID id: String) {
        guard isViewLoaded, let session,
              let index = session.assets.firstIndex(where: { $0.id == id }) else { return }
        let path = IndexPath(item: index, section: 0)
        guard collectionView.indexPathsForVisibleItems().contains(path),
              let cell = collectionView.item(at: path) as? AssetGridItem,
              let asset = cell.cardView.asset, asset.id == id else { return }
        // An in-flight request still carries the pre-edit key. Letting it land after the new one
        // would repaint the old frame, so it is cancelled before the re-request.
        thumbRequests[index]?.cancel()
        thumbRequests.removeValue(forKey: index)
        applyThumbnail(to: cell, index: index, asset: asset)
    }

    private func reconcileThumbnails(force: Bool) {
        guard isViewLoaded, let session, !session.assets.isEmpty else { return }
        guard let provider = provider() else { return }

        // The tier is a property of the cell, so a resize can invalidate every request at once.
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

        for (index, token) in thumbRequests where !wanted.contains(index) {
            token.cancel()
            thumbRequests.removeValue(forKey: index)
        }

        let visible = Set(collectionView.indexPathsForVisibleItems().map { $0.item })
        let display = displayPixels
        for index in wanted {
            guard index < session.assets.count else { continue }
            let asset = session.assets[index]
            if provider.memoryImage(for: ThumbnailProvider.hdJPEGKey(for: asset,
                                                                 document: document(for: asset)),
                                     display: display) != nil { continue }
            if thumbRequests[index] != nil { continue }
            // §4 ②③: what is on screen is on-screen work; the one-row slack is prefetch.
            requestThumbnail(index: index, asset: asset, tier: cellTier, display: display,
                             priority: visible.contains(index) ? .onScreen : .prefetch)
        }
    }

    private func wantedIndexes() -> Set<Int> {
        guard let scroll = collectionView.enclosingScrollView else { return [] }
        let bounds = scroll.contentView.bounds
        // One row of slack on each side. `rowHeight` already includes the caption strip.
        let expanded = bounds.insetBy(dx: 0, dy: -max(24, metrics.rowHeight))
        guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForElements(in: expanded)
        else { return [] }
        return Set(attributes.compactMap { $0.indexPath?.item })
    }

    // MARK: thumbnail probes (used by `--ui-smoke`)

    public var thumbnailStats: ThumbnailProvider.Stats {
        thumbnailProvider?.stats ?? ThumbnailProvider.Stats()
    }

    public var currentThumbnailTier: ThumbTier { cellTier }

    /// Requests the grid believes are still outstanding (queued or running).
    public var pendingThumbnailRequests: Int { thumbRequests.count }

    /// Outstanding requests for item indices that are no longer visible or prefetched. Must be 0
    /// once the scroll handler has run: "cancel what scrolled away" is an invariant, not a hope.
    public var pendingThumbnailIndexesOutsideWindow: Int {
        Set(thumbRequests.keys).subtracting(wantedIndexes()).count
    }

    /// Worker-pool depth at this instant — queued + running, from the shared service.
    public var thumbnailQueueDepth: Int { thumbnailProvider?.queueDepth ?? 0 }

    /// The provider this grid draws from — `--ui-smoke` asserts it is the filmstrip's too.
    public var thumbnailProviderForSmoke: ThumbnailProvider? { provider() }

    /// Cells currently on screen.
    public var visibleCellCount: Int { collectionView.indexPathsForVisibleItems().count }

    /// The photos the grid is **actually drawing**, in layout order (index 0 = top-left).
    ///
    /// Read off the live cells (`cardView.asset`), not off `session.assets`: a grid that did not react
    /// to a sort change would still be holding the previous photos here, which is exactly the state
    /// the "three views agree" assertion has to be able to see. The probe is what the sort tests and
    /// `--ui-smoke` compare across the three browsers.
    public var renderedAssetIDs: [String] {
        collectionView.indexPathsForVisibleItems()
            .sorted { ($0.section, $0.item) < ($1.section, $1.item) }
            .compactMap { (collectionView.item(at: $0) as? AssetGridItem)?.cardView.asset?.id }
    }

    /// Cells on screen that are drawing a real thumbnail rather than the placeholder. This is the
    /// assertion that separates "the grid streams images" from "the grid still draws swatches".
    public var visibleThumbnailCount: Int {
        collectionView.indexPathsForVisibleItems().reduce(0) { total, path in
            guard let cell = collectionView.item(at: path) as? AssetGridItem,
                  cell.cardView.thumbnail != nil else { return total }
            return total + 1
        }
    }

    /// Cancel everything and drop the memory layer — used when the library changes under the grid.
    public func resetThumbnails() {
        for (_, token) in thumbRequests { token.cancel() }
        thumbRequests.removeAll()
        lastWanted = []
        lastTier = nil
        thumbnailProvider = nil
        providerCache = nil
    }

    // MARK: right-click (「原文件已移动」 → 删除 or 重新链接)

    /// The menu for a right-click at `event` (nil = "the current selection, no click"), or nil when
    /// there is nothing to show.
    ///
    /// A right-click on a cell that is **not** selected means that cell (Finder/Photos behaviour), so
    /// the selection is moved first — otherwise the user right-clicks a red-badged photo that is not
    /// in the selection and the menu talks about a different photo.
    public func menuForRightClick(_ event: NSEvent?) -> NSMenu? {
        guard let session else { return nil }
        if let event, let point = collectionViewPoint(for: event),
           let indexPath = collectionView.indexPathForItem(at: point),
           let asset = session.assets[safe: indexPath.item],
           !session.selection.contains(asset.id) {
            session.selectOnly(asset.id)
        }
        contextMenu.update(selectedIDs: session.selectedAssets.map(\.id),
                           missingIDs: session.missingAssets.map(\.id))
        return contextMenu.menu
    }

    /// Where the click landed, in the collection view's own coordinates.
    private func collectionViewPoint(for event: NSEvent) -> NSPoint? {
        guard event.window != nil else { return nil }
        return collectionView.convert(event.locationInWindow, from: nil)
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

    /// 「查找丢失的文件…」: one folder panel, one recursive search, one relink per hash-verified hit.
    public func findAndRelinkMissingAssets(_ ids: [String]) {
        guard let session else { return }
        MissingFilesActions.findLost(ids, session: session, window: view.window)
    }

    // MARK: selection

    public func collectionView(_ collectionView: NSCollectionView,
                               didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingModel, let session else { return }
        writeSelectionToModel(collectionView)
        _ = session
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               didDeselectItemsAt indexPaths: Set<IndexPath>) {
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
        // Active ring must follow the anchor even when the selection set did not change. In place:
        // a `reloadData()` here would recycle every cell and clear its thumbnail for no reason.
        updateSelectionAndActive()
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

    // MARK: keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        // 0–5 / P / X / U / ⌥1–⌥6 are catalog metadata, handled by the one shared table.
        if RatingShortcuts.handle(event, session: session) { return true }
        let columns = max(1, metrics.columns)
        let extend = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: return session.moveAnchor(by: -1, extend: extend)          // ←
        case 124: return session.moveAnchor(by: 1, extend: extend)           // →
        case 126: return session.moveAnchor(by: -columns, extend: extend)    // ↑
        case 125: return session.moveAnchor(by: columns, extend: extend)     // ↓
        case 115: return session.moveAnchor(by: -pageStride(), extend: extend) // Home
        case 119: return session.moveAnchor(by: pageStride(), extend: extend)  // End
        case 116: return session.moveAnchor(by: -pageStride(), extend: extend) // PageUp
        case 121: return session.moveAnchor(by: pageStride(), extend: extend)  // PageDown
        case 36, 76, 49:                                                     // Return / Enter / Space
            if let id = session.anchorID {
                onActivate?(id)
                return true
            }
            return false
        default:
            return false
        }
    }

    private func pageStride() -> Int {
        let rowHeight = max(1, metrics.rowHeight)
        let rows = max(1, Int(collectionView.bounds.height / rowHeight) - 1)
        return rows * max(1, metrics.columns)
    }

    public func showAnchor() {
        guard let session, let id = session.anchorID,
              let index = session.assets.firstIndex(where: { $0.id == id }) else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        activateItem(at: recognizer.location(in: collectionView))
    }

    /// Open the cell under `point` (grid coordinates). `internal` for the same reason the strip's
    /// twin is: the test drives the hit-testing the gesture uses.
    func activateItem(at point: NSPoint) {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let session, let asset = session.assets[safe: indexPath.item] else { return }
        onActivate?(asset.id)
    }

    /// Grid metrics actually applied by the flow layout — used by `--ui-smoke` to prove that what
    /// was drawn matches the pure function.
    public var appliedItemSize: CGSize { flow.itemSize }
    public var appliedSectionInset: NSEdgeInsets { flow.sectionInset }

    /// The live cell for an asset, if it is on screen. The smoke reads `lastDrawnBadges` off *this*
    /// to prove the corner badge was painted, not merely that the model says `rating == 3`.
    public func visibleItem(forAssetID id: String) -> AssetGridItem? {
        guard let session, let index = session.assets.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.item(at: IndexPath(item: index, section: 0)) as? AssetGridItem
    }

    /// The card the filter strip occupies above the grid (0 when the view has not laid out yet).
    public var filterBarFrame: NSRect { filterBar.frame }
}

/// Top-left origin, so the filter strip is at y = 0 and the grid fills what is left.
final class FlippedCanvasView: NSView {
    override var isFlipped: Bool { true }
}

extension Array {
    /// Bounds-safe read: a reload race must not crash the UI thread.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
