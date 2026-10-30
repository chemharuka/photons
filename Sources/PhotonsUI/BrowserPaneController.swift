import AppKit
import PhotonsCatalog

/// Left browser (Phos "素材浏览"): the source roots on top, the photo list below.
///
/// Matte, not glass — §2b item 5: big panels stay matte (`.sidebar`), only small widget containers
/// use glass. Photo rows are 46 pt and recycled, so 10k photos cost the same as 10; the folder tree
/// above them is 28 pt per row (021 A).
///
/// The 34 pt square in a row is a **thumbnail**, not a colour chip. It used to be painted as
/// `PlaceholderSwatch.color(for:)` and nothing ever replaced it, which is why the default browser
/// mode (`photons.browserMode = list`) showed a wall of flat colours while the centre grid — the
/// other surface — streamed real images out of the same cache. The rows now ask the same
/// `ThumbnailProvider.shared(for:)` the grid and the filmstrip use (one LRU, one single-flight map,
/// 006 §4), keyed by the tier a 34 pt cell implies, and cancel whatever scrolls away.
public final class BrowserPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                          NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    /// Side of the square preview in a photo row, in points. It is the only input to the tier
    /// policy (`ThumbnailProvider.tier(cellEdgePoints:)` → `t256` at 1× and 2×).
    public static let thumbnailSide: CGFloat = 34
    /// Rows of prefetch above and below the visible band (006 §5 "可见 + 上下各一行", applied to a
    /// 46 pt row: one row of slack is cheaper than a scroll hitch).
    private static let prefetchSlackRows = 5

    private let headerTitle = NSTextField(labelWithString: "素材浏览")
    private let headerCount = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let sourcesOutline = NSOutlineView()
    private let photosTable = NSTableView()
    /// 右键：从库中删除… / 查找丢失的文件… — one menu object, the same verbs as the grid.
    public let contextMenu = AssetContextMenu()
    private let sourcesScroll = NSScrollView()
    private let photosScroll = NSScrollView()
    private let matte = NSVisualEffectView()
    private let bridge = ObservationBridge()
    private weak var session: CatalogSession?
    private var isApplyingModel = false

    /// The source tree: 相册 → 全部照片 → each source root → the folders `rel_path` implies.
    ///
    /// A class, not a struct, because `NSOutlineView` identifies items by object identity; the tree is
    /// rebuilt from the session on every `refresh()` (a 10k-photo library has few folders, and the
    /// nodes carry only counts, never pixels).
    final class FolderTreeItem: NSObject {
        /// 相册（078 B10）与文件夹是**同一层的两个区段**：`albumGroup` 是一个可展开的标题行，
        /// `album` 是它下面的相册行。两者都不带 `rootID`/`path` —— 相册不是磁盘上的位置，
        /// 把它硬塞进 `(rootId, path)` 会让「点相册」走成分支过滤。
        enum Kind { case allPhotos, root, folder, albumGroup, album }
        let kind: Kind
        let title: String
        /// The right-aligned count.
        let detail: String
        /// `nil` only for 全部照片.
        let rootID: String?
        /// Path relative to the root; `""` is the root itself (and 全部照片).
        let path: String
        let status: String?
        /// 相册行的 id（`.album`），其余为 nil。
        let albumID: String?
        var children: [FolderTreeItem] = []

        init(kind: Kind, title: String, detail: String, rootID: String?, path: String, status: String?,
             albumID: String? = nil) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.rootID = rootID
            self.path = path
            self.status = status
            self.albumID = albumID
        }

        var isAllPhotos: Bool { kind == .allPhotos }
        var isAlbum: Bool { kind == .album }
        var isAlbumGroup: Bool { kind == .albumGroup }
        var isExpandable: Bool { !children.isEmpty }
        /// Stable across a rebuild — used to keep the user's expansion state over `reloadData()`.
        /// 相册行的键带自己的前缀：`(nil, "")` 是「全部照片」，相册行若复用同一套键就会在
        /// `expandedKeys` 里撞上它，展开一个相册等于展开了整个文件夹树。
        var key: String {
            switch kind {
            case .albumGroup: return "albums|"
            case .album: return "album|\(albumID ?? "")"
            default: return "\(rootID ?? "*")|\(path)"
            }
        }
        /// SF Symbol: a folder for roots and subfolders, the library glyph for 全部照片,
        /// a photo stack for the 相册 section and each album in it (078 B10).
        var symbolName: String {
            switch kind {
            case .allPhotos: return "photo.on.rectangle"
            case .albumGroup: return "rectangle.stack"
            case .album: return "rectangle.stack.badge.play"
            case .root, .folder: return "folder"
            }
        }
    }

    /// One visible row of the tree, in outline order. What the shape tests read.
    public struct FolderTreeRow: Equatable {
        public var title: String
        public var detail: String
        public var level: Int
        public var rootID: String?
        public var path: String
        public var isAllPhotos: Bool
        /// 相册行的 id（`.album` 行），其余行 nil —— 「点这一行」在测试里靠它指名相册。
        public var albumID: String?
    }

    private var treeRoot: FolderTreeItem?
    private var allPhotosItem: FolderTreeItem?
    /// 「相册」区段的标题行（078 B10）。与 `treeRoot` 平级：左栏是两个区段，不是一个。
    private var albumGroupItem: FolderTreeItem?
    /// Top-level rows, in draw order: 相册, then 全部照片（它下面才是各个 root 与文件夹）。
    /// `NSOutlineView` 只认这个数组和每个 item 的 `children`，所以「加一个区段」= 往这里加一行。
    private var sections: [FolderTreeItem] = []
    /// 相册段默认展开（相册通常是个位数，而且要两下点击才能看到内容等于藏起来）；用户收起过就记住。
    private var albumsExpanded = true
    /// Expansion the user expressed, so a `reload()` does not collapse the folder they opened.
    private var expandedKeys: Set<String> = []

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

        configure(table: photosTable, rowHeight: WorkspaceLayout.browserRowHeight, identifier: "PhotoRowCell")
        configureOutline()
        configureAlbumMenu()
        photosTable.allowsMultipleSelection = true
        // 2026-10-30（用户）：「双击左侧的照片列表不能进入单图编辑界面」。
        // 网格与胶片条用的是 `NSClickGestureRecognizer`，而左侧是 `NSTableView` —— 它需要显式的
        // `doubleAction` + `target` 才会响应双击，这里以前从没接过，所以双击等于没发生。
        photosTable.target = self
        photosTable.doubleAction = #selector(openPhotoRowInLoupe(_:))

        // 右键：the same two verbs the grid and the filmstrip offer, on the same menu object. The
        // list resolves the click through `clickedRow`, which AppKit keeps current for us.
        contextMenu.willOpen = { [weak self] in self?.prepareContextMenu() }
        contextMenu.onDelete = { [weak self] ids in self?.deleteMissingAssets(ids) }
        contextMenu.onFindLost = { [weak self] ids in self?.findAndRelinkMissingAssets(ids) }
        // 照片列表也是「菜单入口」的一部分：选中几张 → 右键 → 加入相册（078 B10）。
        contextMenu.albumsProvider = { [weak self] ids in
            AlbumMenuSupport.items(session: self?.session, ids: ids)
        }
        contextMenu.onAddToAlbum = { [weak self] ids, albumID in
            AlbumMenuSupport.add(ids, albumID: albumID, session: self?.session)
            self?.refresh()
        }
        contextMenu.onRemoveFromAlbum = { [weak self] ids, albumID in
            AlbumMenuSupport.remove(ids, albumID: albumID, session: self?.session)
            self?.refresh()
        }
        photosTable.menu = contextMenu.menu

        sourcesScroll.documentView = sourcesOutline
        // The tree scrolls: 180 pt is a floor, a deep `shoot/day2/sub/night` tree goes past it and
        // must stay reachable without stealing the photo list's room.
        sourcesScroll.hasVerticalScroller = true
        sourcesScroll.autohidesScrollers = true
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
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
    }

    /// The folder tree. 28 pt rows and `.sourceList` — a navigation row is one 12 pt line and a
    /// folder glyph, not a 46 pt photo row (021 A); `configure(table:)` keeps the photo rows at 46.
    private func configureOutline() {
        sourcesOutline.headerView = nil
        sourcesOutline.backgroundColor = .clear
        // Order matters: `.sourceList` applies the system's compact row metrics, so the height has to
        // be pinned *after* the style, and `rowSizeStyle = .custom` is what keeps AppKit from putting
        // its own 24 pt back. With the height set first, the cells were laid out for 46 pt rows inside
        // 24 pt ones — the folder name sat above the row and got clipped by it.
        sourcesOutline.style = .sourceList
        sourcesOutline.rowSizeStyle = .custom
        sourcesOutline.rowHeight = WorkspaceLayout.browserTreeRowHeight
        sourcesOutline.intercellSpacing = NSSize(width: 0, height: 0)
        sourcesOutline.selectionHighlightStyle = .regular
        sourcesOutline.dataSource = self
        sourcesOutline.delegate = self
        sourcesOutline.allowsEmptySelection = true
        // Deliberately `true`, against the old flat list's `false`: with an empty selection
        // forbidden, `reloadData()` auto-selects row 0 — which is 全部照片 — and posts a selection
        // change through the delegate, silently resetting the user's folder filter on every refresh
        // (a rating, an import, `reload()`). The highlight is installed from the model instead
        // (`selectSourceItem`), and a click in the empty area below the tree simply keeps the filter.
        // 021 B: still `true` — ⌘-clicking the last row off is a legitimate gesture ("back to
        // everything") and it is handled in `outlineViewSelectionDidChange`, not by AppKit.
        sourcesOutline.allowsMultipleSelection = true
        sourcesOutline.floatsGroupRows = false
        // 14 pt per level: a `day2/sub` row still leaves ~150 pt for its name at the 212 pt default
        // width, and the indent reads as a hierarchy rather than as a stray gap.
        sourcesOutline.indentationPerLevel = 14
        sourcesOutline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SourceRowCell"))
        col.resizingMask = .autoresizingMask
        sourcesOutline.addTableColumn(col)
        sourcesOutline.outlineTableColumn = col
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
        let headerH = WorkspaceLayout.browserHeaderHeight
        headerTitle.frame = NSRect(x: inset, y: 18, width: view.bounds.width - inset * 2, height: 16)
        headerCount.frame = NSRect(x: inset, y: 36, width: view.bounds.width - inset * 2, height: 13)

        matte.frame = view.bounds
        let footerH = WorkspaceLayout.browserFooterHeight
        let gap = WorkspaceLayout.browserPaneGap
        // The tree's height is the layout contract's, not the row count's: 180 pt floor, 45 % of the
        // panel ceiling, and the photo list keeps its 120 pt floor underneath.
        let sourcesH = WorkspaceLayout.browserTreeHeight(rowCount: sourcesOutline.numberOfRows,
                                                         panelHeight: view.bounds.height)
        let top = headerH
        sourcesScroll.frame = NSRect(x: 6, y: top, width: view.bounds.width - 12, height: sourcesH)
        let photosTop = top + sourcesH + gap
        photosScroll.frame = NSRect(x: 6, y: photosTop,
                                    width: view.bounds.width - 12,
                                    height: max(WorkspaceLayout.browserPhotoListMinHeight,
                                                view.bounds.height - photosTop - footerH))
        footer.frame = NSRect(x: inset, y: view.bounds.height - footerH + 6,
                              width: view.bounds.width - inset * 2, height: 13)
    }

    /// Lay the panes out for a panel of `size` and return the frames that were applied.
    ///
    /// The window drives `viewDidLayout` in the app; a controller constructed by a test (or by a
    /// probe) has no window, and this is the same code path with the frame set explicitly — so the
    /// height assertions measure the layout that ships, not a copy of the arithmetic.
    @discardableResult
    public func applyLayout(in size: CGSize) -> (tree: NSRect, photos: NSRect) {
        view.frame = NSRect(origin: .zero, size: size)
        layoutPanes()
        return (sourcesScroll.frame, photosScroll.frame)
    }

    private func observeModel() {
        bridge.observe({ [weak self] in
            guard let self, let session = self.session else { return }
            _ = session.assets.count
            _ = session.roots.count
            _ = session.selectedRootID
            _ = session.selectedFolderPath
            _ = session.folderNodes.count
            _ = session.selection
            _ = session.anchorID
            _ = session.stats
            _ = session.metadataRevision
            // 相册（078 B10）：左栏的「相册」段与它每一行的数字跟着库走 —— 建/改名/删/加入/移出
            // 都只 bump 这一个值，所以视图不需要知道是哪种操作。
            _ = session.albums.count
            _ = session.selectedAlbumID
            _ = session.albumRevision
            // 排序（网格/胶片条/左侧栏同源）：这一行让左侧照片行跟着换序，见 `PhotoSortOrder`。
            _ = session.sortOrder
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
        rebuildTree(for: session)
        headerCount.stringValue = "\(session.assets.count) 张照片"
        footer.stringValue = session.selection.isEmpty
            ? "未选择"
            : "已选 \(session.selection.count)"
        // `reloadData` clamps the table's selection to what still exists and posts
        // `tableViewSelectionDidChange` for it. That transient row count is not the user's
        // selection: writing it back would collapse a 5-photo selection to one row on every
        // refresh (the grid's ⌘-click range, then any metadata write). The model is the truth, so
        // the transient notification is ignored here and the real selection is installed below.
        isApplyingModel = true
        photosTable.reloadData()
        isApplyingModel = false
        applySelectionFromModel()
        reloadTree()
        // The tree's row count just changed, and the tree's height is derived from it — lay out in
        // the same pass instead of waiting for a `viewDidLayout` that a resize may never trigger.
        layoutPanes()
        // `reloadData` recycles every visible row, so every visible row re-asks for its image.
        // Deferred one runloop turn because the table has not laid its rows out yet.
        DispatchQueue.main.async { [weak self] in self?.reconcileThumbnails(force: true) }
    }

    // MARK: folder tree

    /// Build 全部照片 → roots → folders from the session.
    ///
    /// Counts come from `session.folderNodes`, i.e. from the same `rel_path` scan that the filter
    /// queries, so a root row and the folders under it can never disagree; `stats.byRoot` is keyed by
    /// display name and cannot tell two folders named "test" apart, which is why it is not used here.
    private func rebuildTree(for session: CatalogSession) {
        for row in 0..<sourcesOutline.numberOfRows {
            if let item = sourcesOutline.item(atRow: row) as? FolderTreeItem,
               sourcesOutline.isItemExpanded(item) {
                if item.isAlbumGroup { albumsExpanded = true } else { expandedKeys.insert(item.key) }
            }
        }
        let all = FolderTreeItem(kind: .allPhotos, title: "全部照片",
                                 // The library's size, not the filtered count: this row is the way
                                 // *back* to everything, so it must not shrink as a filter is applied.
                                 detail: "\(session.stats?.total ?? session.assets.count)",
                                 rootID: nil, path: "", status: nil)
        let perRoot = session.photoCountByRoot
        all.children = session.roots.map { root in
            let rootItem = FolderTreeItem(kind: .root, title: root.displayName,
                                          detail: "\(perRoot[root.id] ?? 0)",
                                          rootID: root.id, path: "",
                                          status: root.status.rawValue)
            // The aggregation sorts by path, so every parent is attached before its children and a
            // single pass over the nodes builds the whole subtree. `""` is the root item itself.
            var itemsByPath: [String: FolderTreeItem] = ["": rootItem]
            for node in session.folderNodes(forRoot: root.id) where !node.path.isEmpty {
                let item = FolderTreeItem(kind: .folder, title: node.name,
                                          detail: "\(node.total)",
                                          rootID: root.id, path: node.path, status: nil)
                (itemsByPath[node.parentPath] ?? rootItem).children.append(item)
                itemsByPath[node.path] = item
            }
            return rootItem
        }
        // 「相册」区段（078 B10）：标题行 + 一个相册一行，数字直接来自 `session.albums`
        // —— 也就是 `album_assets` 里数出来的那一份。左栏的数字和点开后的行数不可能不一致，
        // 因为两者都不在这一层算。
        let group = FolderTreeItem(kind: .albumGroup, title: "相册",
                                   detail: session.albums.isEmpty ? "" : "\(session.albums.count)",
                                   rootID: nil, path: "", status: nil)
        group.children = session.albums.map { album in
            FolderTreeItem(kind: .album, title: album.name, detail: "\(album.count)",
                           rootID: nil, path: "", status: nil, albumID: album.id)
        }
        treeRoot = all
        allPhotosItem = all
        albumGroupItem = group
        sections = [group, all]
    }

    private func reloadTree() {
        sourcesOutline.reloadData()
        // 默认展开前两层: 全部照片 open, so the roots are the second visible level. Subfolders stay
        // collapsed until asked for — a library with 40 folders must not open as a wall of rows.
        if let all = allPhotosItem {
            sourcesOutline.expandItem(all)
            expandedKeys.insert(all.key)
        }
        // 相册段默认展开（用户可以收起，收起状态记在 `albumsExpanded` 里）。
        if let group = albumGroupItem, albumsExpanded, group.isExpandable,
           !sourcesOutline.isItemExpanded(group) {
            sourcesOutline.expandItem(group)
        }
        // Then whatever the user had open: a `reload()` (an import, a rating, a click) must not
        // collapse the folder they just navigated into. Sorted by depth so a parent exists first.
        for item in allItems().sorted(by: { $0.path.count < $1.path.count }) {
            guard expandedKeys.contains(item.key), item.isExpandable,
                  !sourcesOutline.isItemExpanded(item) else { continue }
            sourcesOutline.expandItem(item)
        }
        selectSourceItem()
    }

    private func allItems() -> [FolderTreeItem] {
        var out: [FolderTreeItem] = sections
        var stack = sections
        while let item = stack.popLast() {
            out.append(contentsOf: item.children)
            stack.append(contentsOf: item.children)
        }
        return out
    }

    private func item(rootID: String?, path: String) -> FolderTreeItem? {
        let wanted = rootID == nil ? "" : (AssetFilter.normalizedFolderPath(path) ?? "")
        // 相册行与「全部照片」都是 `(nil, "")`；不排除的话 `selectFolderRow(rootID: nil)` 会
        // 把高亮装到某个相册上（而网格是整库）—— 这正是"左栏说 A、网格画 B"的生成方式。
        return allItems().first {
            !$0.isAlbum && !$0.isAlbumGroup && $0.rootID == rootID && $0.path == wanted
        }
    }

    private func parentItem(of item: FolderTreeItem) -> FolderTreeItem? {
        allItems().first { node in node.children.contains { $0 === item } }
    }

    private func expandAncestors(of item: FolderTreeItem) {
        var chain: [FolderTreeItem] = []
        var cursor = item
        while let parent = parentItem(of: cursor) {
            chain.append(parent)
            cursor = parent
        }
        for parent in chain.reversed() where !sourcesOutline.isItemExpanded(parent) {
            sourcesOutline.expandItem(parent)
        }
    }

    /// Put the outline's highlight on the model's selection. The model is the truth: a refresh that
    /// cannot find a selected folder drops that row from the highlight (the session drops it too),
    /// and an empty model selection — 「全部照片」 — highlights the 全部照片 row.
    ///
    /// 021 B: restored **by `(rootId, path)`**, never by index. `reloadData()` keeps the table's
    /// selected *indexes* but the rows behind them are new objects, so an index-based restore would
    /// quietly move a ⌘-selection from `day2` to whatever row now sits there. Installed with
    /// `isApplyingModel` on, so the delegate cannot write AppKit's own idea of the selection back
    /// into the session (which is what wiped the filter in the 020 handoff).
    private func selectSourceItem() {
        guard let session else { return }
        var rows = IndexSet()
        if let albumID = session.selectedAlbumID, let album = item(albumID: albumID) {
            // 相册高亮：模型说在看哪个相册，左栏就把它点亮（并确保它所在的段是展开的）。
            if let group = albumGroupItem, !sourcesOutline.isItemExpanded(group) {
                sourcesOutline.expandItem(group)
                albumsExpanded = true
            }
            let row = sourcesOutline.row(forItem: album)
            if row >= 0 { rows.insert(row) }
        } else if session.selectedFolders.isEmpty {
            if let all = allPhotosItem, sourcesOutline.row(forItem: all) >= 0 {
                rows.insert(sourcesOutline.row(forItem: all))
            }
        } else {
            for selection in session.selectedFolders {
                // A model row the tree cannot draw (it should not happen — `reload()` prunes those)
                // contributes nothing, so the highlight never points at a row that is not selected.
                guard let target = item(rootID: selection.rootId, path: selection.path ?? "") else {
                    continue
                }
                expandAncestors(of: target)
                let row = sourcesOutline.row(forItem: target)
                if row >= 0 { rows.insert(row) }
            }
        }
        isApplyingModel = true
        sourcesOutline.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingModel = false
    }

    private func item(albumID: String) -> FolderTreeItem? {
        allItems().first { $0.isAlbum && $0.albumID == albumID }
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

    /// 双击照片行 = 在单图（loupe）里打开它。与网格/胶片条的双击同义：只选中这一张，再切到单图模式。
    ///
    /// `clickedRow` 是 AppKit 在派发 `doubleAction` 前设好的；键盘触发（`performDoubleClick`）时
    /// 它是 −1，此时退回 `selectedRow`，所以两种入口都能用。
    @objc private func openPhotoRowInLoupe(_ sender: Any?) {
        let row = photosTable.clickedRow >= 0 ? photosTable.clickedRow : photosTable.selectedRow
        openRowInLoupe(row)
    }

    /// The body of the double-click, addressable from tests (`clickedRow` is AppKit's business).
    /// Returns whether it actually opened something — a row outside the list does nothing.
    @discardableResult
    public func openRowInLoupe(_ row: Int) -> Bool {
        guard let session, let asset = session.assets[safe: row] else { return false }
        session.selectOnly(asset.id)
        session.mode = .loupe
        return true
    }

    /// The list the double-click is wired to — the test reads `doubleAction` / `target` off it.
    public var photoListForTesting: NSTableView { photosTable }

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

    // The folder tree is an `NSOutlineView`: AppKit asks these four, never `numberOfRows(in:)`.
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderTreeItem else { return sections.count }
        return node.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderTreeItem else { return sections[index] }
        return node.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderTreeItem)?.isExpandable ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                            item: Any) -> NSView? {
        guard let node = item as? FolderTreeItem else { return nil }
        let cell = SourceRowCell.reuse(in: outlineView, owner: self)
        cell.configure(title: node.title, detail: node.detail,
                       isOffline: node.status == "offline",
                       isAllPhotos: node.isAllPhotos,
                       symbolName: node.symbolName)
        return cell
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView !== sourcesOutline else { return 0 }
        guard showsPhotoList else { return 0 }
        return session?.assets.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session, let asset = session.assets[safe: row] else { return nil }
        let cell = PhotoRowCell.reuse(in: tableView, owner: self)
        cell.configure(asset: asset, isActive: session.anchorID == asset.id)
        applyThumbnail(to: cell, row: row, asset: asset)
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel, let session else { return }
        guard let table = notification.object as? NSTableView, table !== sourcesOutline else { return }
        let ids = table.selectedRowIndexes.compactMap { session.assets[safe: $0]?.id }
        guard !ids.isEmpty else { return }
        let anchor = ids.first { session.anchorID == $0 } ?? ids.first
        session.setSelection(Set(ids), anchor: anchor)
    }

    /// A folder row is a filter, not a selection: the same `reload()` the flat list drove.
    ///
    /// 021 B: the whole outline selection is a filter, ORed. AppKit does the ⌘-click (free
    /// multi-select) and the ⇧-range itself — there is no key handling here on purpose.
    ///
    /// An **empty** selection is only acted on when it came from a real click on a row (⌘-clicking
    /// the last highlight off → back to 全部照片 / the whole library). Clicking the blank area under
    /// the last row also empties it, and that must leave the filter exactly as it was — the model is
    /// reinstalled a line later by `refresh()`.
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel, let session else { return }
        let items = sourcesOutline.selectedRowIndexes
            .compactMap { sourcesOutline.item(atRow: $0) as? FolderTreeItem }
        // 相册行是**范围**，不是选择项：点它就是「网格只看这个相册」。
        if let album = items.first(where: \.isAlbum) {
            session.selectAlbum(album.albumID)
            selectSourceItem()
            return
        }
        // 「相册」标题行只表示展开状态；把它点亮等于让用户以为网格换了范围。高亮还给模型。
        if items.contains(where: \.isAlbumGroup) {
            selectSourceItem()
            return
        }
        if items.isEmpty {
            guard sourcesOutline.clickedRow >= 0 else { return }
            session.selectFolders([])          // 也清掉相册：这是「回到全库」
            selectSourceItem()
            return
        }
        let clicked = sourcesOutline.clickedRow >= 0
            ? sourcesOutline.item(atRow: sourcesOutline.clickedRow) as? FolderTreeItem
            : nil
        let chosen = Self.folderSelection(from: items, clicked: clicked)
        session.selectFolders(chosen)
        // Repaired **synchronously and without a data reload**: `reloadData()` inside a selection
        // notification is AppKit reentrancy for nothing (`session.selectFolders` already re-ran the
        // query and the bridge rebuilds the tree on the next turn). This only re-points the highlight
        // at what the model accepted, which is what keeps 「全部照片」 exclusive on screen.
        selectSourceItem()
    }

    /// Turn highlighted rows into the session's selection.
    ///
    /// 「全部照片」 is the library, not a folder, so it can only ever be a selection of exactly one.
    /// When it is highlighted together with folders — only reachable with ⌘ — the **row the user just
    /// clicked decides**: ⌘-clicking 全部照片 means "back to everything", ⌘-clicking a folder on top
    /// of it means "narrow to this". The catalog takes the same decision defensively (an all-photos
    /// entry collapses the whole filter), so the two can never disagree about what is on screen.
    static func folderSelection(from items: [FolderTreeItem],
                               clicked: FolderTreeItem?) -> [FolderSelection] {
        let allPhotos = items.filter(\.isAllPhotos)
        let folders = items.filter { !$0.isAllPhotos }
        if !allPhotos.isEmpty, !folders.isEmpty {
            if let clicked, clicked.isAllPhotos { return [FolderSelection(rootId: nil)] }
            return folders.map { FolderSelection(rootId: $0.rootID, path: $0.path) }
        }
        return items.map { FolderSelection(rootId: $0.rootID, path: $0.path) }
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? FolderTreeItem {
            if item.isAlbumGroup { albumsExpanded = true } else { expandedKeys.insert(item.key) }
        }
        layoutPanes()
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? FolderTreeItem {
            if item.isAlbumGroup { albumsExpanded = false } else { expandedKeys.remove(item.key) }
        }
        layoutPanes()
    }

    // MARK: tree probes (tests and `--ui-smoke`)

    public var folderTreeRowCount: Int { sourcesOutline.numberOfRows }
    public var folderTreeHeight: CGFloat { sourcesScroll.frame.height }
    public var photoListHeight: CGFloat { photosScroll.frame.height }

    /// The visible tree rows in outline order, with their depth — the shape assertion.
    public var folderTreeRows: [FolderTreeRow] {
        (0..<sourcesOutline.numberOfRows).compactMap { row in
            guard let item = sourcesOutline.item(atRow: row) as? FolderTreeItem else { return nil }
            return FolderTreeRow(title: item.title, detail: item.detail,
                                 level: sourcesOutline.level(forRow: row),
                                 rootID: item.rootID, path: item.path,
                                 isAllPhotos: item.isAllPhotos, albumID: item.albumID)
        }
    }

    /// Open or close one node, as a click on its disclosure triangle does.
    public func setFolderExpanded(rootID: String?, path: String, _ expanded: Bool) {
        guard let item = item(rootID: rootID, path: path) else { return }
        if expanded {
            expandAncestors(of: item)
            sourcesOutline.expandItem(item)
        } else {
            sourcesOutline.collapseItem(item)
        }
        layoutPanes()
    }

    /// Click a node: the outline's highlight **and** the session's folder filter, in one step.
    ///
    /// The observation bridge lands on the next run loop turn; refreshing here is what makes a click
    /// synchronous (and what a test can assert on without spinning the run loop). The bridge's later
    /// pass finds nothing changed and is a no-op.
    public func selectFolderRow(rootID: String?, path: String) {
        selectFolderRows([FolderSelection(rootId: rootID, path: path)])
    }

    /// The same one step for a **set** of rows — what a ⌘-multi-selection ends up as (021 B).
    ///
    /// Used by the tests and by `--ui-smoke` to reach the state AppKit produces with ⌘-clicks without
    /// synthesising mouse events. The highlight is not set here: it is installed from the model by
    /// `refresh()` → `selectSourceItem()`, i.e. by the same path a real click takes, so a test that
    /// asserts two highlighted rows is asserting the restore-by-`(rootId, path)` logic.
    public func selectFolderRows(_ folders: [FolderSelection]) {
        guard let session else { return }
        for folder in session.selectedFolders + folders {
            if let target = item(rootID: folder.rootId, path: folder.path ?? "") {
                expandAncestors(of: target)
            }
        }
        session.selectFolders(folders)
        refresh()
    }

    /// The highlighted tree rows as `(rootId, path)` keys — the probe the multi-select tests read.
    public var selectedFolderKeys: [String] {
        sourcesOutline.selectedRowIndexes.compactMap { row in
            (sourcesOutline.item(atRow: row) as? FolderTreeItem)?.key
        }
    }

    // MARK: albums (078 B10) — 左栏相册段的 CRUD 与「点相册 = 过滤网格」

    /// 最近一次相册操作失败的原因（重名、空名、已删）。不弹窗：一个已经把手放回鼠标的用户不该
    /// 被模态框拦住；测试要断言的是这个字符串，不是一张对话框。
    public private(set) var lastAlbumError: String?

    @discardableResult
    public func createAlbum(named name: String) -> String? {
        guard let session else { return nil }
        do {
            let album = try session.createAlbum(named: name)
            lastAlbumError = nil
            refresh()
            return album.id
        } catch {
            lastAlbumError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func renameAlbum(_ id: String, to name: String) -> Bool {
        guard let session else { return false }
        do {
            _ = try session.renameAlbum(id: id, to: name)
            lastAlbumError = nil
            refresh()
            return true
        } catch {
            lastAlbumError = error.localizedDescription
            return false
        }
    }

    /// 删相册：只删相册与成员关系，照片一张不少（`Catalog.deleteAlbum` 的契约）。
    @discardableResult
    public func deleteAlbum(_ id: String) -> Bool {
        guard let session else { return false }
        do {
            _ = try session.deleteAlbum(id: id)
            lastAlbumError = nil
            refresh()
            return true
        } catch {
            lastAlbumError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func addSelectedPhotos(toAlbum id: String) -> Int {
        guard let session else { return 0 }
        do {
            let added = try session.addSelection(toAlbum: id)
            lastAlbumError = nil
            refresh()
            return added
        } catch {
            lastAlbumError = error.localizedDescription
            return 0
        }
    }

    @discardableResult
    public func removeSelectedPhotos(fromAlbum id: String) -> Int {
        guard let session else { return 0 }
        do {
            let removed = try session.removeSelection(fromAlbum: id)
            lastAlbumError = nil
            refresh()
            return removed
        } catch {
            lastAlbumError = error.localizedDescription
            return 0
        }
    }

    /// 点左栏的相册行：展开「相册」段（若收起）、让模型进入这个相册、重画。
    ///
    /// 与 `selectFolderRow` 同一形状：一条路径既是 AppKit 的点击，也是测试/`--ui-smoke` 的入口，
    /// 所以测试断言的展开与过滤就是真实点击的那一次。
    public func selectAlbumRow(_ id: String) {
        guard let session else { return }
        if let group = albumGroupItem {
            if !sourcesOutline.isItemExpanded(group) { sourcesOutline.expandItem(group) }
            albumsExpanded = true
        }
        session.selectAlbum(id)
        refresh()
    }

    /// 展开/收起「相册」段（标题行上的那个三角）。
    public func setAlbumSectionExpanded(_ expanded: Bool) {
        guard let group = albumGroupItem else { return }
        albumsExpanded = expanded
        if expanded { sourcesOutline.expandItem(group) } else { sourcesOutline.collapseItem(group) }
        layoutPanes()
    }

    public var albumSectionExpanded: Bool {
        guard let group = albumGroupItem else { return false }
        return sourcesOutline.isItemExpanded(group)
    }

    // MARK: 相册的右键菜单
    //
    // 入口选择：**右键菜单**，不是拖放。三条理由，按重要性：
    //
    // 1. 拖放要在三个面（网格 `NSCollectionView`、左栏 `NSTableView`、胶片条）各自注册拖源与
    //    拖目的地、各自持有一份 pasteboard type 与落点判定 —— 三份实现、三种失效方式。菜单是
    //    **一个** `AssetContextMenu` 对象，三个面共用（它已经是「从库中删除…」的家）。
    // 2. 菜单可以被无窗口的测试进程驱动（`menuNeedsUpdate` + `items` 读得到），拖放只能合成
    //    `NSEvent`，在一个没有事件循环的测试里是不可靠的输入。
    // 3. 键盘可达（Control-F2 或辅助功能右键），拖放对键盘用户不可达。

    private lazy var albumSectionMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }()

    /// The album row the menu is being opened on (`nil` = the section header or blank space).
    private var menuAlbumID: String?

    private func configureAlbumMenu() {
        sourcesOutline.menu = albumSectionMenu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === albumSectionMenu else { return }
        menu.removeAllItems()
        let row = sourcesOutline.clickedRow
        let item = row >= 0 ? sourcesOutline.item(atRow: row) as? FolderTreeItem : nil
        menuAlbumID = item?.isAlbum == true ? item?.albumID : nil

        let new = NSMenuItem(title: "新建相册…", action: #selector(albumMenuNew), keyEquivalent: "")
        new.target = self
        menu.addItem(new)

        if let albumID = menuAlbumID {
            menu.addItem(.separator())
            let rename = NSMenuItem(title: "重命名相册…", action: #selector(albumMenuRename), keyEquivalent: "")
            rename.target = self
            rename.representedObject = albumID
            menu.addItem(rename)

            let delete = NSMenuItem(title: "删除相册…", action: #selector(albumMenuDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = albumID
            menu.addItem(delete)

            // 选中照片时，「加入 / 移出这个相册」就在同一个菜单里：不用先去找网格的右键菜单。
            let hasSelection = !(session?.selection.isEmpty ?? true)
            let add = NSMenuItem(title: "把选中的照片加入此相册", action: #selector(albumMenuAdd), keyEquivalent: "")
            add.target = self
            add.representedObject = albumID
            add.isEnabled = hasSelection
            menu.addItem(add)

            let remove = NSMenuItem(title: "把选中的照片移出此相册", action: #selector(albumMenuRemove), keyEquivalent: "")
            remove.target = self
            remove.representedObject = albumID
            remove.isEnabled = hasSelection
            menu.addItem(remove)
        }
    }

    @objc private func albumMenuNew() {
        guard let name = AlbumNamePrompt.run(title: "新建相册", message: "相册名", value: "") else { return }
        _ = createAlbum(named: name)
    }

    @objc private func albumMenuRename(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String,
              let album = session?.albums.first(where: { $0.id == albumID }) else { return }
        guard let name = AlbumNamePrompt.run(title: "重命名相册", message: "相册名", value: album.name) else { return }
        _ = renameAlbum(albumID, to: name)
    }

    @objc private func albumMenuDelete(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String,
              let album = session?.albums.first(where: { $0.id == albumID }) else { return }
        // 确认框只说真话：删的是相册，照片留在库里。
        let alert = NSAlert()
        alert.messageText = "删除相册「\(album.name)」？"
        alert.informativeText = "相册里的 \(album.count) 张照片不会被删除，只是不再属于这个相册。"
        alert.addButton(withTitle: "删除相册")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = deleteAlbum(albumID)
    }

    @objc private func albumMenuAdd(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String else { return }
        _ = addSelectedPhotos(toAlbum: albumID)
    }

    @objc private func albumMenuRemove(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String else { return }
        _ = removeSelectedPhotos(fromAlbum: albumID)
    }

    public var photoRowCount: Int { photosTable.numberOfRows }

    /// The photos the left list is **actually drawing**, row 0 first.
    ///
    /// Read off the live `PhotoRowCell`s (`assetID`), the same honesty rule as the grid's
    /// `renderedAssetIDs`: a list that ignored the sort order would keep its old rows here, and the
    /// three-view consistency assertion is what would notice.
    public var renderedPhotoRowIDs: [String] {
        (0..<photosTable.numberOfRows).compactMap {
            (photosTable.view(atColumn: 0, row: $0, makeIfNecessary: false) as? PhotoRowCell)?.assetID
        }
    }
}

// MARK: - cells

private final class SourceRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    /// One cell for all three node kinds: 全部照片, a root, a subfolder. The glyph is what separates
    /// them at a glance; the outline supplies the indent and the disclosure triangle.
    private static let iconSide: CGFloat = 13
    private static let iconToText: CGFloat = 21

    static func reuse(in table: NSTableView, owner: Any) -> SourceRowCell {
        let id = NSUserInterfaceItemIdentifier("SourceRowCell")
        if let v = table.makeView(withIdentifier: id, owner: owner) as? SourceRowCell { return v }
        let cell = SourceRowCell()
        cell.identifier = id
        return cell
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("no nibs") }

    func configure(title t: String, detail d: String, isOffline: Bool, isAllPhotos: Bool,
                   symbolName: String = "folder") {
        title.stringValue = t
        detail.stringValue = d
        title.textColor = isOffline ? .tertiaryLabelColor : .labelColor
        title.toolTip = isOffline ? "offline" : nil
        // A folder for a root and for every subfolder; the library glyph for 全部照片, so the
        // "everything" row never reads as a plain folder next to the folder it contains. 相册 段
        // 与相册行各有自己的 glyph（078 B10）：左栏里「一叠照片」和「一个文件夹」是两种东西。
        let description: String = isAllPhotos ? "全部照片" : (symbolName == "folder" ? "文件夹" : "相册")
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        icon.contentTintColor = isOffline ? .tertiaryLabelColor
            : (isAllPhotos ? .labelColor : .secondaryLabelColor)
    }

    override func layout() {
        super.layout()
        let rowHeight = bounds.height
        let side = SourceRowCell.iconSide
        icon.frame = NSRect(x: 2, y: (rowHeight - side) / 2, width: side, height: side)
        let textX = SourceRowCell.iconToText
        // Everything is centred on the row's own height, not on a hard-coded 46 pt: a row that comes
        // out shorter (a style change, a system metric, a test frame) must not push the name out of
        // the row it belongs to. The count keeps its 40 pt gutter on the right; the name truncates in
        // the middle so "day2-very-long-name" and "...-name" stay distinguishable at 212 pt.
        let textHeight: CGFloat = 18
        let detailHeight: CGFloat = 16
        let titleY = (rowHeight - textHeight) / 2
        detail.frame = NSRect(x: bounds.width - 44, y: (rowHeight - detailHeight) / 2,
                              width: 40, height: detailHeight)
        title.frame = NSRect(x: textX, y: titleY,
                             width: max(10, bounds.width - textX - 48), height: textHeight)
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

    // MARK: text block metrics

    /// Line heights of the row's three text lines, in the order they stack bottom → top:
    /// `meta` (机身 · 日期) sits at the bottom, `name` in the middle, `stars` on top.
    /// These are line *frames*, not font sizes (11 / 9 / 8 pt): a label needs a little more height
    /// than its cap height, and keeping the numbers here is what lets `layout()` treat the three
    /// lines as one block instead of three absolute offsets from `bounds.height`.
    static let nameLineHeight: CGFloat = 15
    static let metaLineHeight: CGFloat = 12
    static let starsLineHeight: CGFloat = 10
    /// Height of the three lines edge to edge — the block `layout()` centres on the row.
    static var textBlockHeight: CGFloat { nameLineHeight + metaLineHeight + starsLineHeight }

    /// The three line heights for a row `rowHeight` tall.
    ///
    /// At 46 pt (and anything taller) this is exactly 15 / 12 / 10. A row shorter than the block
    /// (a style change, a degenerate test frame) shrinks all three **in proportion**, because the
    /// alternatives are worse: keeping them would hang a line outside the row it belongs to, and
    /// top-aligning the block would break the one thing this cell is for — lining the text up with
    /// the thumbnail. The square does not fit such a row either (`thumbnailSide` is 34 pt).
    static func textLineHeights(fitting rowHeight: CGFloat) -> (name: CGFloat, meta: CGFloat, stars: CGFloat) {
        let natural = (name: nameLineHeight, meta: metaLineHeight, stars: starsLineHeight)
        let block = textBlockHeight
        guard rowHeight > 0, rowHeight < block else { return natural }
        let k = rowHeight / block
        return (nameLineHeight * k, metaLineHeight * k, starsLineHeight * k)
    }

    /// Where `layout()` actually put the row's parts, as frames in the cell's own coordinates.
    ///
    /// The geometry has to be assertable offscreen — "the text block is 3 pt low" is a number, not
    /// an opinion — and the views themselves are private, so this is the probe the layout tests
    /// read. Nothing in the UI depends on it.
    struct LayoutProbe {
        var swatch: NSRect
        var name: NSRect
        var meta: NSRect
        var stars: NSRect
        var pill: NSRect
        var nameBreakMode: NSLineBreakMode
        /// Width the name would need at its own font, unclipped. `> name.width` means it truncates.
        var nameUnclippedWidth: CGFloat
        var nameText: String
    }

    var layoutProbe: LayoutProbe {
        let needed = (name.stringValue as NSString)
            .size(withAttributes: [.font: name.font ?? NSFont.systemFont(ofSize: 11)]).width
        return LayoutProbe(swatch: swatch.frame, name: name.frame, meta: meta.frame,
                           stars: stars.frame, pill: pill.frame,
                           nameBreakMode: name.lineBreakMode,
                           nameUnclippedWidth: ceil(needed), nameText: name.stringValue)
    }

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
        let side = BrowserPaneController.thumbnailSide
        swatch.frame = NSRect(x: 2, y: (bounds.height - side) / 2, width: side, height: side)

        let textX: CGFloat = 44
        let width = max(10, bounds.width - textX - 2)
        // The three lines are one block, and the **block** is what gets centred: it shares the
        // thumbnail square's vertical centre. The row used to place each line at an absolute
        // offset from `bounds.height` (46 − 31 / − 45 / − 17), which put the block's centre at 20
        // against a 23 pt square centre — 3 pt low, with 7 pt of slack above and 1 pt below.
        // Deriving the block from its own line heights means a different `browserRowHeight` (or a
        // test frame) stays centred instead of drifting; there is no 46 anywhere in here.
        let heights = PhotoRowCell.textLineHeights(fitting: bounds.height)
        let block = heights.name + heights.meta + heights.stars
        // Top edge of the block, then stack down: stars, name, meta — edge to edge, so the lines
        // can neither overlap nor open a gap the eye reads as a misalignment.
        let top = (bounds.height + block) / 2
        let starsY = top - heights.stars
        let nameY = starsY - heights.name
        // `max(0,…)`: on a row exactly as tall as the block this lands on 0, and the subtraction
        // can leave −1.8e−15 there. A row may not contain a line at a negative y, not even one
        // that only exists because of binary floating point.
        let metaY = max(0, nameY - heights.meta)
        stars.frame = NSRect(x: textX, y: starsY, width: width, height: heights.stars)
        name.frame = NSRect(x: textX, y: nameY, width: width, height: heights.name)
        meta.frame = NSRect(x: textX, y: metaY, width: width, height: heights.meta)
        // The pill rides the bottom of the thumbnail square (12 pt tall, inset 1 pt).
        pill.frame = NSRect(x: swatch.frame.minX, y: swatch.frame.maxY - 13,
                            width: swatch.frame.width, height: 12)
    }
}
