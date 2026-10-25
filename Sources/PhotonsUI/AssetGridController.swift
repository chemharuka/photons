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

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// One card: the thumbnail (when we have one), else the hash-derived placeholder block, plus the
/// filename and stars.
///
/// The placeholder is never removed: a missing, failed or still-loading thumbnail draws the
/// M3 swatch underneath, so a cell is never a white hole and a failure looks like "not yet",
/// not like "broken" (docs/tasks/006-thumbnails.md §2).
public final class AssetCardView: NSView {
    public var asset: Asset? { didSet { needsDisplay = true } }
    public var isActive: Bool = false { didSet { needsDisplay = true } }
    public var isPicked: Bool = false { didSet { needsDisplay = true } }

    /// The decoded thumbnail for this asset, or nil while the placeholder is all we have.
    public var thumbnail: CGImage? { didSet { if thumbnail !== oldValue { needsDisplay = true } } }
    /// Which tier the current image came from — printed by `--ui-smoke` and used to prove the cell
    /// asked for the size it should have (006 §1).
    public var thumbnailTier: ThumbTier?

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let asset else { return }
        let bounds = self.bounds
        let labelHeight = GridLayout.labelHeight
        let swatchRect = NSRect(x: 0, y: 0, width: bounds.width,
                                height: max(1, bounds.height - labelHeight)).insetBy(dx: 0, dy: 0)
        let radius: CGFloat = WorkspaceLayout.cardCornerRadius

        let path = NSBezierPath(roundedRect: swatchRect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let primary = PlaceholderSwatch.color(for: asset.contentHash)
        let secondary = PlaceholderSwatch.secondaryColor(for: asset.contentHash)
        NSGradient(starting: primary, ending: secondary)?.draw(in: path, angle: -90)

        if let thumbnail {
            // Aspect-fill inside the swatch: the cell decides the crop, never the image. Drawing a
            // smaller cached tier larger is intentional — the alternative is an empty cell, and the
            // tier is clamped at request time so this is never a cache lie (see ThumbnailProvider).
            drawThumbnail(thumbnail, in: swatchRect)
        } else {
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

        // Selection / active ring: accent for the anchor, softer accent for the rest of the selection.
        if isPicked || isActive {
            let ring = NSBezierPath(roundedRect: swatchRect.insetBy(dx: 0.75, dy: 0.75),
                                    xRadius: radius, yRadius: radius)
            (isActive ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.55)).setStroke()
            ring.lineWidth = isActive ? 2 : 1.5
            ring.stroke()
        }

        let captionRect = NSRect(x: 2, y: swatchRect.maxY + 4, width: bounds.width - 4,
                                 height: labelHeight - 6)
        (asset.filename as NSString).draw(in: captionRect, withAttributes: PlaceholderStyle.captionAttributes)
        if asset.rating > 0 {
            let stars = PlaceholderSwatch.stars(asset.rating)
            let size = (stars as NSString).size(withAttributes: PlaceholderStyle.starsAttributes)
            (stars as NSString).draw(at: NSPoint(x: bounds.width - size.width - 3,
                                                 y: swatchRect.maxY + 5),
                                     withAttributes: PlaceholderStyle.starsAttributes)
        }
    }

    /// Aspect-fill, centre-anchored. `NSGraphicsContext` is already clipped to the rounded swatch.
    private func drawThumbnail(_ image: CGImage, in rect: NSRect) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = max(rect.width / iw, rect.height / ih)
        let size = NSSize(width: iw * scale, height: ih * scale)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let target = NSRect(origin: origin, size: size)
        NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
        NSGraphicsContext.current?.cgContext.draw(image, in: target)
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
        // A recycled cell must not show the previous photo for one frame: clear first, the
        // controller re-applies from the memory cache (a synchronous `NSCache` hit) right after.
        card.thumbnail = nil
        card.thumbnailTier = nil
        card.asset = asset
        card.isActive = isActive
        card.isPicked = isSelected
        view.toolTip = asset.filename
    }
}

/// Owns the grid, its layout and the keyboard rules; reads and writes `CatalogSession` only.
public final class AssetGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    public let collectionView = AssetCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let bridge = ObservationBridge()
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
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AssetGridItem.self, forItemWithIdentifier: AssetGridItem.reuseIdentifier)
        collectionView.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(doubleClick)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Scrolling is what changes "what is visible", and that is what decides which in-flight
        // requests stay alive (006 §5). `postsBoundsChangedNotifications` is the cheapest hook —
        // no delegate, no timer.
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
        updateMetrics()
        scheduleThumbnailReconcile()
    }

    @objc private func clipViewBoundsChanged() {
        scheduleThumbnailReconcile()
    }

    // MARK: model plumbing

    private func observeModel() {
        guard session != nil else { return }
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets.count
            _ = session.selection
            _ = session.anchorID
        }, { [weak self] in
            self?.refresh()
        })
    }

    public func refresh() {
        guard isViewLoaded else { return }
        // A different library means a different cache directory: drop the memory layer so the grid
        // can never show the previous library's pixels.
        if let url = session?.libraryURL, url != lastLibraryURL {
            lastLibraryURL = url
            resetThumbnails()
        }
        let before = collectionView.numberOfItems(inSection: 0)
        updateMetrics()
        collectionView.reloadData()
        reloadCount += 1
        applySelectionFromModel()
        if before == 0 { collectionView.scroll(.zero) }
        // `reloadData` recycles every visible cell, so every visible cell re-asks for its image.
        // Deferred by one runloop turn because the flow layout has not produced attributes yet.
        DispatchQueue.main.async { [weak self] in self?.reconcileThumbnails(force: true) }
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
    private func applyThumbnail(to cell: AssetGridItem, index: Int, asset: Asset) {
        guard let provider = provider() else { return }
        let tier = tier(for: asset)
        cell.cardView.thumbnailTier = tier
        // `serveFromMemory` (not `memoryImage`) so a warm cell is counted as a hit rather than
        // disappearing from the statistics.
        if let cached = provider.serveFromMemory(for: .preview(contentHash: asset.contentHash, tier: tier)) {
            cell.cardView.thumbnail = cached
            return
        }
        requestThumbnail(index: index, asset: asset, tier: tier, priority: .onScreen)
    }

    // MARK: thumbnails

    private var backingScale: CGFloat {
        view.window?.backingScaleFactor ?? 2
    }

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
        guard let cache = session?.thumbnailCache else { return nil }
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

    private func requestThumbnail(index: Int, asset: Asset, tier: ThumbTier, priority: ThumbPriority) {
        guard let provider = provider(), thumbRequests[index] == nil else { return }
        guard let session, let url = session.fileURL(for: asset) else { return }
        let token = provider.request(index: index, asset: asset, fileURL: url, tier: tier,
                                     priority: priority) { [weak self] idx, _, image in
            self?.thumbnailDidLoad(index: idx, image: image)
        }
        thumbRequests[index] = token
    }

    private func thumbnailDidLoad(index: Int, image: CGImage?) {
        thumbRequests[index] = nil
        // A nil image is a real answer ("no preview / unreadable"): the card keeps its placeholder.
        guard let image, let session, index >= 0, index < session.assets.count else { return }
        let path = IndexPath(item: index, section: 0)
        guard let cell = collectionView.item(at: path) as? AssetGridItem else { return }
        // The cell may have been recycled between request and delivery; the asset id is the guard.
        guard cell.cardView.asset?.id == session.assets[index].id else { return }
        cell.cardView.thumbnail = image
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
        for index in wanted {
            guard index < session.assets.count else { continue }
            let asset = session.assets[index]
            if provider.memoryImage(contentHash: asset.contentHash, tier: cellTier) != nil { continue }
            if thumbRequests[index] != nil { continue }
            // §4 ②③: what is on screen is on-screen work; the one-row slack is prefetch.
            requestThumbnail(index: index, asset: asset, tier: cellTier,
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
        // Active ring must follow the anchor even when the selection set did not change.
        collectionView.reloadData()
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
        let point = collectionView.convert(recognizer.location(in: collectionView), from: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let session, let asset = session.assets[safe: indexPath.item] else { return }
        onActivate?(asset.id)
    }

    /// Grid metrics actually applied by the flow layout — used by `--ui-smoke` to prove that what
    /// was drawn matches the pure function.
    public var appliedItemSize: CGSize { flow.itemSize }
    public var appliedSectionInset: NSEdgeInsets { flow.sectionInset }
}

extension Array {
    /// Bounds-safe read: a reload race must not crash the UI thread.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
