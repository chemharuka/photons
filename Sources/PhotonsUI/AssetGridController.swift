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

/// One card: colour block + filename + stars, drawn by hand (no thumbnails in M3).
public final class AssetCardView: NSView {
    public var asset: Asset? { didSet { needsDisplay = true } }
    public var isActive: Bool = false { didSet { needsDisplay = true } }
    public var isPicked: Bool = false { didSet { needsDisplay = true } }

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

        // A thin "this is a placeholder" rule set: one diagonal + the extension, no image work.
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let diag = NSBezierPath()
        diag.move(to: NSPoint(x: swatchRect.minX, y: swatchRect.maxY))
        diag.line(to: NSPoint(x: swatchRect.maxX, y: swatchRect.minY))
        diag.lineWidth = 1
        diag.stroke()

        let ext = asset.ext.uppercased()
        (ext as NSString).draw(at: NSPoint(x: 8, y: 6), withAttributes: PlaceholderStyle.captionAttributes)
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
        view = scroll
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        observeModel()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateMetrics()
    }

    // MARK: model plumbing

    private func observeModel() {
        guard let session else { return }
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
        let before = collectionView.numberOfItems(inSection: 0)
        updateMetrics()
        collectionView.reloadData()
        reloadCount += 1
        applySelectionFromModel()
        if before == 0 { collectionView.scroll(.zero) }
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
        return cell
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
