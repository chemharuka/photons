import AppKit
import PhotonsCatalog

/// Left browser (Phos "素材浏览"): the source roots on top, the photo list below.
///
/// Matte, not glass — §2b item 5: big panels stay matte (`.sidebar`), only small widget containers
/// use glass. Rows are 46 pt and recycled, so 10k photos cost the same as 10.
public final class BrowserPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let headerTitle = NSTextField(labelWithString: "素材浏览")
    private let headerCount = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let sourcesTable = NSTableView()
    private let photosTable = NSTableView()
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

    /// When the filmstrip is the browser (mode B), the photo rows live down there instead.
    public var showsPhotoList = true {
        didSet { photosTable.isHidden = !showsPhotoList }
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

        sourcesScroll.documentView = sourcesTable
        sourcesScroll.hasVerticalScroller = false
        sourcesScroll.drawsBackground = false
        sourcesScroll.borderType = .noBorder
        photosScroll.documentView = photosTable
        photosScroll.hasVerticalScroller = true
        photosScroll.drawsBackground = false
        photosScroll.borderType = .noBorder
        photosScroll.autohidesScrollers = true

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

private final class PhotoRowCell: NSTableCellView {
    private let swatch = NSView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let stars = NSTextField(labelWithString: "")

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
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        meta.font = .systemFont(ofSize: 9)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        stars.font = .systemFont(ofSize: 8)
        stars.textColor = .systemYellow
        for v in [swatch, name, meta, stars] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    func configure(asset: Asset, isActive: Bool) {
        swatch.layer?.backgroundColor = PlaceholderSwatch.color(for: asset.contentHash).cgColor
        name.stringValue = asset.filename
        var bits: [String] = []
        if let m = asset.cameraModel { bits.append(m) }
        if let d = asset.captureLocalDate { bits.append(d) }
        meta.stringValue = bits.joined(separator: " · ")
        stars.stringValue = asset.rating > 0 ? PlaceholderSwatch.stars(asset.rating) : ""
        name.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        swatch.frame = NSRect(x: 2, y: (bounds.height - 34) / 2, width: 34, height: 34)
        let textX: CGFloat = 44
        let width = max(10, bounds.width - textX - 2)
        name.frame = NSRect(x: textX, y: bounds.height - 31, width: width, height: 15)
        meta.frame = NSRect(x: textX, y: bounds.height - 45, width: width, height: 12)
        stars.frame = NSRect(x: textX, y: bounds.height - 17, width: width, height: 10)
    }
}
