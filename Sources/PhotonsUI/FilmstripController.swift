import AppKit
import PhotonsCatalog

/// The filmstrip: a horizontal `NSCollectionView` that is the *same* browser as the photo list,
/// just laid out along the bottom (Phos mode B, docs/tasks/004-ui-skeleton.md §2b item 3).
///
/// It shares `CatalogSession.selection` with the grid — no second selection set, no second model.
public final class FilmstripCell: NSCollectionViewItem {
    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("FilmstripCell")

    private let card = FilmstripCard()

    public override func loadView() { view = card }

    public var cardView: FilmstripCard { card }

    public override var isSelected: Bool { didSet { card.isPicked = isSelected } }

    public func configure(asset: Asset, isActive: Bool) {
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
}

public final class FilmstripController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    public let collectionView = AssetCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let bridge = ObservationBridge()
    private weak var session: CatalogSession?
    private var isApplyingModel = false
    public var onActivate: ((String) -> Void)?

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
        view = scroll
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        observeModel()
    }

    private func observeModel() {
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
        collectionView.reloadData()
        applySelectionFromModel()
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
        return cell
    }

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
