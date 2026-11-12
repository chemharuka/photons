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

    public func configure(asset: Asset, isActive: Bool, stackCount: Int = 0) {
        // A recycled cell must not show a *different* photo for one frame; the same asset keeps
        // its bitmap (a filter/metadata refresh is not a pixel change).
        if card.asset?.id != asset.id {
            card.clearThumbnail()
            card.thumbnailTier = nil
        }
        card.asset = asset
        card.isActive = isActive
        card.isPicked = isSelected
        card.stackCount = stackCount
        view.toolTip = asset.filename
    }
}

public final class FilmstripCard: NSView {
    public var asset: Asset? { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isActive = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    public var isPicked = false { didSet { needsDisplay = true; overlay.needsDisplay = true } }
    /// §378 — member count of the stack this cell represents (0/1 = not a stack). Set by the
    /// controller from `CatalogSession.stacksByTopID`.
    public var stackCount: Int = 0 { didSet { overlay.needsDisplay = true } }
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

    /// 363 — same question as the grid card's: is the bitmap on screen, or is the card's solid
    /// placeholder gradient the thing the eye sees while a new bitmap is swapped in?
    public var thumbnailSurfaceVisible: Bool { !thumbnailView.isHidden }

    /// 363 — how many times this cell blanked a preview it was already showing (0 = the swap goes
    /// old picture → new picture with no solid frame in between).
    public var blankedPreviewFrames: Int { thumbnailView.blankedPreviewCount }

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

    /// 377 — what the caption line actually painted and at what width (same evidence the grid card
    /// keeps, so both faces can be asserted against the same `PlaceholderStyle.fitted`).
    public private(set) var lastDrawnCaption: String?
    public private(set) var lastCaptionRect: NSRect = .zero

    /// What the last `draw` painted in the corners ("stars:3", "stack:5"), read back by the smoke and
    /// the §378 acceptance exactly like the grid card's. The strip draws **the same**
    /// `AssetBadges.draw`, so the two surfaces cannot disagree about what a stack looks like.
    public private(set) var lastDrawnBadges: [String] = []

    /// §382 — the capsule rects the last `draw` painted (see `AssetBadges.Layout`).
    public private(set) var lastBadgeLayout = AssetBadges.Layout()

    /// The badge this cell would draw — the same string the grid card reports.
    public var badgeSignature: String {
        asset.map { AssetBadges(asset: $0, stackCount: stackCount).signature } ?? "—"
    }

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

        // Stars / flag / colour label / stack indicator: the same `AssetBadges` the grid card draws,
        // so the two surfaces can never disagree about what a badge means. Drawn before the missing
        // scrim so 「原文件已移动」 stays on top of everything.
        let badges = AssetBadges(asset: asset, stackCount: stackCount)
        lastBadgeLayout = badges.draw(in: thumb)
        lastDrawnBadges = missingLabel == nil ? badges.drawn : badges.drawn + ["missing"]

        // The badge is drawn *outside* the clip so its pill is never cut by the rounded corner, and
        // last, so no selection ring sits on top of the words the user has to read.
        lastDrawnMissingLabel = nil
        if let missingLabel {
            MissingFileBadge.draw(in: thumb, compact: true)
            lastDrawnMissingLabel = missingLabel
        }
        let name = NSRect(x: 0, y: thumb.maxY + 1, width: bounds.width, height: 11)
        // 377 — same one implementation as the grid: fit the head + `…` to the caption's width
        // instead of letting `NSString.draw(in:)` word-wrap at a space or `-` and clip the rest.
        // §382 — 「堆叠 XXX.dng」 is composed **before** the fit, exactly like the grid card.
        let display = StackText.displayName(asset.filename, isStack: badges.isStack)
        let drawnCaption = PlaceholderStyle.fitted(display, width: name.width,
                                                   font: PlaceholderStyle.captionFont)
        (drawnCaption as NSString).draw(in: name, withAttributes: PlaceholderStyle.captionAttributes)
        lastDrawnCaption = drawnCaption
        lastCaptionRect = name
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
    /// §378 — the verbs behind the 「堆叠 ▸」 submenu.
    private lazy var stackMenuTarget = StackMenuTarget(session: session)
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
        // 383 — 按下时只记命中项（双击要打开**第一下**那张），单击本身交给 AppKit 走选择。
        // 352 的「窗口内第二下落到另一格就整次吞掉」随延迟居中一起退役：单击不再居中，格子就不会
        // 从指针下面滑走，第二下自然还落在同一张上；点两张不同照片就是两次正常的单击。
        collectionView.onMouseDown = { [weak self] event in
            guard let self else { return false }
            let point = self.collectionView.convert(event.locationInWindow, from: nil)
            // ⇧/⌘ are the session's range gesture, not AppKit's "extend from the last clicked
            // row" — resolving them here keeps the anchor/base fixed while the range moves.
            if self.handleSelectionClick(at: point, modifiers: event.modifierFlags) { return true }
            _ = self.clickGuard.mouseDown(hit: self.hit(at: point), now: Date())
            return false
        }

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
                cell.configure(asset: asset, isActive: self.session?.anchorID == asset.id,
                               stackCount: self.session?.stackSummary(forAssetID: asset.id)?.count ?? 0)
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
        // 383 — **布局不再是居中 door。** 332 当年在这里补了一次「第一个真实视口出现后再居中」，
        // 但布局随时会发生（另一面换了选中、缩略图落地、窗格拖动），而锚点可能是**另一面**刚选中的
        // 那张 —— 实测（③ 的 6 次单击）：layout → `centerAnchorIfChanged` 还会自己滚 3 次，把
        // 「单击不居中」打回去。居中的入口只剩显式动作：双击 / Return / ←→、编辑落地，以及 ⇧/⌘ 的
        // 范围手势（`handleSelectionClick`）。快照还没落地时 `centerAnchor()` 自己会 `deferCenterOnce()`。
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
        // 332 — a bounds change that `Activity` did not attribute to our own animation is the user
        // scrolling. 383: there is no parked centre left to drop (a click never centres), so this
        // only records the timestamp `CenterOnEditTests` / `CenteredScroll` read.
        scrollActivity.noteChange()
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
            // 383 — 选择/锚点变了**不是**滚动的理由（谁写的都一样：本条的单击、侧栏的单击、方向键之外
            // 的任何模型写回）。把锚点记为已结算，于是随后的一次 `viewDidLayout` 也不会替它居中；
            // 居中的入口只剩显式动作 —— 双击 / Return / ←→（`centreForLoupeEntry()`）与编辑落地
            // （303 的 0.25 s 窗口直接调 `centerAnchor()`）。
            markAnchorSettled()
            return
        }
        lastSnapshot = next
        refresh()
        markAnchorSettled()
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
        // §382 — `apply(snapshot)` does not re-run the cell provider for an id that stayed put, so
        // a metadata write (stars / colour / a new stack) never reached the cell that was already on
        // screen. Re-configure the visible cells in place, matched by the photo each already shows.
        reconfigureVisibleItems()
        applySelectionFromModel()
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleThumbnails()
            self?.reconcileThumbnails(force: true)
            self?.reconfigureVisibleItems()
        }
        if let session { lastSnapshot = modelSnapshot(session) }
    }

    /// §382 — the strip's half of the grid's `reconfigureVisibleItems`: same asset id ⇒ the cell
    /// keeps its bitmap, and only the badge/count values are re-read from the session.
    private func reconfigureVisibleItems() {
        guard isViewLoaded, let session else { return }
        for path in collectionView.indexPathsForVisibleItems() {
            guard let cell = collectionView.item(at: path) as? FilmstripCell,
                  let id = cell.cardView.asset?.id,
                  let asset = assetsByID[id] else { continue }
            cell.configure(asset: asset, isActive: session.anchorID == id,
                           stackCount: session.stackSummary(forAssetID: id)?.count ?? 0)
        }
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
        cell.configure(asset: asset, isActive: session.anchorID == asset.id,
                       stackCount: session.stackSummary(forAssetID: asset.id)?.count ?? 0)
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
        StackMenuBuilder.attach(to: contextMenu.menu, session: session, target: stackMenuTarget,
                                selectedIDs: session.selectedAssets.map(\.id))
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

    /// The live document for the photo on screen, the stored one for every other row (218's key
    /// input) — 363: the cell's *pixels* stay committed (nothing is blanked, an older delivery is
    /// dropped), but the cell must still **ask** for the document the user is looking at, or the
    /// pause (326/§4) has nothing to refuse and nothing to hold. See the grid's twin for the full
    /// argument, including why a cached key is a file switch the pause allows.
    private func document(for asset: Asset) -> EditModel {
        guard let session else { return .neutral }
        if asset.id == session.loadedEditAssetID { return session.edit }
        return ThumbnailProvider.document(from: asset)
    }

    private func requestThumbnail(index: Int, asset: Asset, tier: ThumbTier,
                                  display: ImageSize, priority: ThumbPriority) {
        guard let provider = provider() else { return }
        guard let session, let url = session.fileURL(for: asset) else { return }
        let document = document(for: asset)
        let wanted = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        if let pending = thumbRequests[index] {
            // One request per cell for one key.
            guard pending.key.digest != wanted.digest else { return }
            // 363 — a later document superseded it: condemn the old ask so an older frame cannot
            // repaint this cell after a newer one is already there.
            pending.cancel()
            thumbRequests[index] = nil
        }
        let token = provider.request(index: index, asset: asset, fileURL: url,
                                     document: document, tier: tier, spec: .hdJPEG,
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
        // 363 — and the document may have moved on: a frame for an older edit must not land here.
        let row = session.assets[index]
        guard key.digest == ThumbnailProvider.hdJPEGKey(for: row, document: document(for: row)).digest
        else {
            staleThumbnailDrops += 1
            return
        }
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
            // 363 — the **catalog row**, not the copy the cell was configured with: `develop_json` is
            // what the key is derived from, and that copy is only as fresh as the last `configure`.
            // Reading it here is what put an edited photo back on its pre-edit key.
            applyThumbnail(to: cell, index: index, asset: session.assets[index])
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
              cell.cardView.asset?.id == id else { return }
        // The in-flight request still carries the pre-edit key; cancel it so it cannot repaint the
        // old frame after the new one arrives.
        thumbRequests[index]?.cancel()
        thumbRequests.removeValue(forKey: index)
        applyThumbnail(to: cell, index: index, asset: session.assets[index])
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
        // AppKit's selection is only the trigger; the session owns the anchor and the range base.
        // Never guess the anchor from `ids.first` here.
        let ids = Set(collectionView.selectionIndexPaths.compactMap { session.assets[safe: $0.item]?.id })
        if ids.isEmpty {
            if !session.selection.isEmpty { session.setSelection([]) }
        } else if ids.count == 1, let id = ids.first {
            if session.selection != ids || session.anchorID != id { session.selectOnly(id) }
        } else if ids != session.selection {
            let anchor = [session.anchorID, session.selectionBase]
                .compactMap { $0 }
                .first { ids.contains($0) }
                ?? session.assets.last { ids.contains($0.id) }?.id
            session.setSelection(ids, anchor: anchor)
        }
        updateSelectionAndActive()
        // The new anchor is priority ① for the next reconcile.
        scheduleThumbnailReconcile()
        // 383 — 单击只选中：把锚点记为「已结算」，于是模型那条「锚点变了」（`applyModelSnapshot`）也不会
        // 为它居中。居中的两个入口只剩显式动作：双击 / Return（`centreForLoupeEntry()`）与编辑落地
        // （303 的 0.25 s 窗口 → `centerAnchor()`）。
        markAnchorSettled()
    }

    /// Resolve a ⇧/⌘ press against the session. Plain presses return `false` and reach AppKit,
    /// which reports the hit row through the delegate door above.
    @discardableResult
    public func handleSelectionClick(at point: NSPoint,
                                     modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let session,
              let indexPath = collectionView.indexPathForItem(at: point),
              let asset = session.assets[safe: indexPath.item] else { return false }
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)
        guard shift || command else { return false }
        if shift {
            session.selectRange(to: asset.id, adding: command)
        } else {
            session.toggle(asset.id)
        }
        collectionView.window?.makeFirstResponder(collectionView)
        updateSelectionAndActive()
        scheduleThumbnailReconcile()
        centerAnchorIfChanged()
        return true
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

    // MARK: 332 — keep the anchor photo in the middle of the strip

    /// 383 — the press/double-click rule, shared verbatim with `BrowserPaneController`. Both surfaces
    /// 单击只选中；双击打开第一下那张。352 的延迟居中已退役。
    public let clickGuard = BrowserClickGuard()

    /// The user's scrolling, as a timestamp — `isUserScrolling` reads it to stand down.
    let scrollActivity = CenteredScroll.Activity()
    /// How many times a centred scroll actually moved the strip. 332's 「已居中 → 0 次」 counts this.
    public private(set) var centerScrollCount = 0
    /// 363 — deliveries dropped because the document moved on while the frame was rendering.
    public private(set) var staleThumbnailDrops = 0
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` in the app; a test replaces it.
    public var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// What the last centred scroll gave `NSAnimationContext` — 0 on the jumped (reduce-motion) path.
    public private(set) var lastCenterAnimationDuration: TimeInterval = 0
    /// The anchor this strip last centred, so a metadata refresh of the same photo does not scroll.
    private var centredAnchorID: String?
    /// 332b — 见 `deferCenterOnce()`：快照未落地时只推迟一次。
    private var isDeferringCenter = false

    /// Put the anchor photo in the middle of the strip — ends flush, no blank space — animated.
    ///
    /// **The** entry point for both triggers of 332 §2: the anchor changing, and an edit landing
    /// (303's 0.25 s window calls it). Idempotent: already-centred (≤ 2 pt) is a no-op, so a
    /// redundant trigger can never make the strip jitter, and a scroll the user is driving is
    /// dropped rather than fought over.
    ///
    /// - Returns: `true` when there was an anchor and live geometry to work with (whether or not
    ///   the viewport had to move).
    @discardableResult
    /// 332b — `layoutAttributesForItem` **抛异常**（不是返回 nil）当索引超出已装载的条目数时，
    /// 而 `viewDidLoad` 里画面还没应用 diffable 快照（条目数 0）—— 之前这行让 App 一启动就
    /// `NSApplication._crashOnException` 崩掉。所以先问条目数，再取 attributes；快照还没落地时
    /// 推迟到下一个 runloop 再试一次（`isDeferringCenter` 防重入死循环）。
    public func centerAnchor() -> Bool {
        guard isViewLoaded, let session, let id = session.anchorID,
              let scroll = collectionView.enclosingScrollView,
              let index = session.assets.firstIndex(where: { $0.id == id })
        else { return false }
        guard collectionView.numberOfItems(inSection: 0) > index else {
            deferCenterOnce()
            return false
        }
        guard let item = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
        else { return false }
        let clip = scroll.contentView
        let visible = clip.bounds.width
        let content = collectionView.collectionViewLayout?.collectionViewContentSize.width ?? 0
        guard visible > 0, content > 0 else { return false }
        if scrollActivity.isUserScrolling(scroll) { return true }
        let target = CenteredScroll.target(itemMidpoint: item.frame.midX,
                                           contentLength: content,
                                           visibleLength: visible)
        lastCenterAnimationDuration = 0
        let moved = CenteredScroll.scroll(scroll, axis: .horizontal, to: target,
                                          activity: scrollActivity,
                                          reduceMotion: reduceMotion()) { [weak self] duration in
            self?.lastCenterAnimationDuration = duration
        }
        if moved { centerScrollCount += 1 }
        return true
    }

    /// Centre whenever the anchor moved **without a click**: an arrow key, a menu, a model write from
    /// elsewhere, the first real layout. 383 — a click is not one of them: it marks its anchor settled
    /// (`markAnchorSettled()`), so the model tick a click causes lands here and does nothing.
    private func centerAnchorIfChanged() {
        guard let id = session?.anchorID, id != centredAnchorID else { return }
        if centerAnchor() { centredAnchorID = id }
    }

    /// 383 — 单击只选中：把当前锚点记为「已结算」，两条居中 door（模型 tick、`viewDidLayout`）都不会
    /// 再为它滚动。这不是「假装已居中」——`centerAnchor()` 的幂等判据仍是几何（≤ 2 pt），编辑落地与
    /// 双击都会**直接**调它，照样会滚。
    private func markAnchorSettled() {
        centredAnchorID = session?.anchorID
    }

    /// 383 — 双击 / Return 进了 `.loupe` 之后居中一次（幂等：已居中则 0 次）。显式动作，不需要任何
    /// 双击窗口，也不再走 `pendingCenter`。
    private func centreForLoupeEntry() {
        guard let id = session?.anchorID else { return }
        if centerAnchor() { centredAnchorID = id }
    }

    /// 332b — 快照还没落地时（`viewDidLoad` 第一次调用），把这次居中推迟到下一个 runloop，
    /// 并且**只推一次**，避免条目永远为 0 时无限排队。
    private func deferCenterOnce() {
        guard !isDeferringCenter else { return }
        isDeferringCenter = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDeferringCenter = false
            self.centerAnchorIfChanged()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        // Same table as the grid: the strip is a second browser over the same selection.
        if RatingShortcuts.handle(event, session: session) { return true }
        switch event.keyCode {
        case 123:
            guard session.moveAnchor(by: -1, extend: event.modifierFlags.contains(.shift)) else { return true }
            // 383 — ←/→ 是显式动作（和 Return 同一类）：锚点真的动了就居中一次，不再靠模型 tick。
            centreForLoupeEntry()
            return true
        case 124:
            guard session.moveAnchor(by: 1, extend: event.modifierFlags.contains(.shift)) else { return true }
            centreForLoupeEntry()
            return true
        case 36, 76:
            if let id = session.anchorID {
                onActivate?(id)
                // 383 §2.4 — Return 进了编辑视角就居中一次（幂等）。
                centreForLoupeEntry()
                return true
            }
            return false
        default:
            return false
        }
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        activateItem(at: recognizer.location(in: collectionView))
    }

    /// 352 — the cell under `point` (strip coordinates) at **press time**, or nil for empty space.
    public func hit(at point: NSPoint) -> BrowserClickGuard.Hit? {
        guard let session,
              let indexPath = collectionView.indexPathForItem(at: point),
              let asset = session.assets[safe: indexPath.item] else { return nil }
        return BrowserClickGuard.Hit(index: indexPath.item, assetID: asset.id)
    }

    /// The click seam AppKit drives (`collectionView.onMouseDown`) plus the one step a real
    /// `NSCollectionView.mouseDown` would take next — write the selection through the delegate door.
    /// Split out so the acceptance tests press real points at real timestamps without synthesising
    /// window events; the decision itself is the shipping `clickGuard.mouseDown`.
    @discardableResult
    public func handleMouseDown(at point: NSPoint, now: Date = Date(),
                                modifiers: NSEvent.ModifierFlags = []) -> BrowserClickGuard.Decision {
        let decision = clickGuard.mouseDown(hit: hit(at: point), now: now)
        guard decision == .forward,
              let session,
              let indexPath = collectionView.indexPathForItem(at: point),
              let asset = session.assets[safe: indexPath.item] else { return decision }
        if modifiers.contains(.shift) {
            session.selectRange(to: asset.id, adding: modifiers.contains(.command))
        } else if modifiers.contains(.command) {
            session.toggle(asset.id)
        } else {
            session.selectOnly(asset.id)
        }
        updateSelectionAndActive()
        scheduleThumbnailReconcile()
        // 383 — 单击只选中：这里以前调 `centerAnchorIfChanged()`，把「点哪张就滚到哪张」带回来了。
        // 现在只把锚点记为已结算，居中留给双击 / Return 与编辑落地。
        markAnchorSettled()
        return decision
    }

    /// Open the cell under `point` (strip coordinates). `internal` so the test can drive the same
    /// hit-testing the gesture uses instead of guessing a window-space click.
    ///
    /// 352 / 383 — the photo a double-click means is the one the **first** press hit.
    /// 383 §2.4 — 进编辑视角是显式动作：这里居中一次，不再是「窗口内挂起、第二下 flush」。
    func activateItem(at point: NSPoint) {
        guard let session,
              let indexPath = collectionView.indexPathForItem(at: point),
              let asset = session.assets[safe: indexPath.item] else { return }
        let id = clickGuard.openTargetID(fallback: asset.id)
        onActivate?(id)
        centreForLoupeEntry()
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
