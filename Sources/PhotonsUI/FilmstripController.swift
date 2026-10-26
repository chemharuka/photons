import AppKit
import PhotonsCatalog

/// The filmstrip: a horizontal `NSCollectionView` that is the *same* browser as the photo list,
/// just laid out along the bottom (Phos mode B, docs/tasks/004-ui-skeleton.md §2b item 3).
///
/// It shares `CatalogSession.selection` with the grid — no second selection set, no second model —
/// and it shares the *thumbnail* pipeline too: one `ThumbnailProvider` (hence one
/// `ThumbnailService` and one memory LRU) for both views, obtained through
/// `ThumbnailProvider.shared(for:)`. A 74 × 50 pt cell asks for the tier its DPR implies (§1), i.e.
/// `t256` at 1x and 2x, and the selected cell always goes out at `.onScreen` priority.
public final class FilmstripCell: NSCollectionViewItem {
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("FilmstripCell")

    private let card = FilmstripCard()

    public override func loadView() { view = card }

    public var cardView: FilmstripCard { card }

    public override var isSelected: Bool { didSet { card.isPicked = isSelected } }

    public func configure(asset: Asset, isActive: Bool) {
        // A recycled cell must not show the previous photo for one frame: clear first, the
        // controller re-applies from the shared memory cache right after (a synchronous hit).
        card.thumbnail = nil
        card.thumbnailTier = nil
        card.asset = asset
        card.isActive = isActive
        card.isPicked = isSelected
        view.toolTip = asset.filename
    }
}

public final class FilmstripCard: NSView {
    public var asset: Asset? { didSet { needsDisplay = true } }
    public var isActive = false { didSet { needsDisplay = true } }
    public var isPicked = false { didSet { needsDisplay = true } }
    /// The decoded thumbnail, or nil while the hash-derived placeholder is all we have.
    public var thumbnail: CGImage? { didSet { if thumbnail !== oldValue { needsDisplay = true } } }
    /// Which tier the current image came from — `--ui-smoke` asserts the DPR choice against it.
    public var thumbnailTier: ThumbTier?

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let asset else { return }
        let thumb = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 12)
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: PlaceholderSwatch.color(for: asset.contentHash),
                   ending: PlaceholderSwatch.secondaryColor(for: asset.contentHash))?
            .draw(in: path, angle: -90)
        if let thumbnail {
            drawThumbnail(thumbnail, in: thumb)
        }
        if isPicked || isActive {
            let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.75, dy: 0.75),
                                    xRadius: radius, yRadius: radius)
            (isActive ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.5)).setStroke()
            ring.lineWidth = isActive ? 2 : 1.5
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = NSRect(x: 0, y: thumb.maxY + 1, width: bounds.width, height: 11)
        (asset.filename as NSString).draw(in: name, withAttributes: PlaceholderStyle.captionAttributes)
    }

    /// Aspect-fill, centre-anchored, inside the already-clipped rounded card.
    private func drawThumbnail(_ image: CGImage, in rect: NSRect) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = max(rect.width / iw, rect.height / ih)
        let size = NSSize(width: iw * scale, height: ih * scale)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        // A flipped view (`isFlipped == true`) plus a raw `CGContext.draw(CGImage)` draws the image
        // **bottom-up**: the cell is flipped, the CGImage is not. Go through `NSImage` with
        // `respectFlipped`, which is the only spelling that is correct in both orientations.
        let ns = NSImage(cgImage: image, size: NSSize(width: iw, height: ih))
        ns.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.medium])
    }
}

public final class FilmstripController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    public let collectionView = AssetCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let bridge = ObservationBridge()
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
        flow.minimumInteritemSpacing = 8
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 6, right: 16)

        collectionView.collectionViewLayout = flow
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FilmstripCell.self, forItemWithIdentifier: FilmstripCell.reuseIdentifier)
        collectionView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

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
        refresh()
        observeModel()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        scheduleThumbnailReconcile()
    }

    @objc private func clipViewBoundsChanged() {
        scheduleThumbnailReconcile()
    }

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets.count
            _ = session.selection
            _ = session.anchorID
            _ = session.metadataRevision
        }, { [weak self] in
            self?.refresh()
        })
    }

    public func refresh() {
        guard isViewLoaded else { return }
        // Same trap as the grid: `reloadData` clears the selection and posts `didDeselectItemsAt`,
        // and this view observes the session even while it is hidden (the strip is a second browser,
        // not a lazy one). Writing that transient state back would collapse a 5-photo selection to
        // one row every time anything refreshed — from either browser.
        isApplyingModel = true
        collectionView.reloadData()
        isApplyingModel = false
        applySelectionFromModel()
        DispatchQueue.main.async { [weak self] in self?.reconcileThumbnails(force: true) }
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

    /// The tier a 74 × 50 pt cell should ask for: cell edge × DPR, clamped to what the source can
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
        if let cached = provider.serveFromMemory(for: .preview(contentHash: asset.contentHash, tier: tier)) {
            cell.cardView.thumbnail = cached
            return
        }
        requestThumbnail(index: index, asset: asset, tier: tier, priority: .onScreen)
    }

    private func requestThumbnail(index: Int, asset: Asset, tier: ThumbTier, priority: ThumbPriority) {
        guard let provider = provider(), thumbRequests[index] == nil else { return }
        guard let session, let url = session.fileURL(for: asset) else { return }
        let token = provider.request(index: index, asset: asset, fileURL: url, tier: tier,
                                     priority: priority) { [weak self] idx, key, image in
            self?.thumbnailDidLoad(index: idx, key: key, image: image)
        }
        thumbRequests[index] = token
    }

    private func thumbnailDidLoad(index: Int, key: ThumbKey, image: CGImage?) {
        thumbRequests[index] = nil
        guard let image, let session, index >= 0, index < session.assets.count else { return }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.item(at: path) as? FilmstripCell else { return }
        // The cell may have been recycled between request and delivery; the asset id is the guard.
        guard cell.cardView.asset?.id == session.assets[index].id else { return }
        cell.cardView.thumbnailTier = key.tier
        cell.cardView.thumbnail = image
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

        for index in wanted {
            guard index < session.assets.count else { continue }
            let asset = session.assets[index]
            if provider.memoryImage(contentHash: asset.contentHash, tier: cellTier) != nil { continue }
            if thumbRequests[index] != nil { continue }
            // §4 ①②: the selected/anchor cell wins even if it is only in the slack band; the rest of
            // the visible window is on-screen work; the slack is prefetch.
            let isAnchor = session.anchorID == asset.id || session.selection.contains(asset.id)
            let priority: ThumbPriority = (isAnchor || visible.contains(index)) ? .onScreen : .prefetch
            requestThumbnail(index: index, asset: asset, tier: cellTier, priority: priority)
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
        collectionView.reloadData()
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

    /// Cells actually laid out — `--ui-smoke` asserts this against the library row count.
    public var itemCount: Int { collectionView.numberOfItems(inSection: 0) }
}
