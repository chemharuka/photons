import Foundation
import Observation
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
// §384: the HDR verb. `PhotonsExtensions` owns `HDRMergeService`, which spawns the GPLv3
// `hdrmerge-swift` binary as a child process — nothing of it is linked into this app.
import PhotonsExtensions

/// The one and only source of truth for the workspace.
///
/// Research `ui-stack.md` F5: the projects that mixed AppKit + SwiftUI did **not** keep two state
/// managers — they kept one `@Observable` model, one 15-line observation bridge for the AppKit side,
/// and `@Bindable` for the SwiftUI leaf views. That is the rule here: every view (grid, filmstrip,
/// sources, loupe, inspector) reads and writes this object, and nothing keeps a copy.
///
/// The document is *persisted* (Q16): `develop(forAsset:)` on open, `saveDevelop(_:history:forAsset:)`
/// after every commit, so closing the app no longer throws an edit away. What is deliberately **not**
/// persisted and **not** in history is mask view state (`selectedMaskID`, the brush, `showMaskID`) —
/// see `MaskViewState`.
@MainActor
@Observable
public final class CatalogSession {

    public enum Mode: String, Sendable {
        case grid
        case loupe
    }

    // MARK: library

    public private(set) var libraryURL: URL?
    public private(set) var roots: [SourceRoot] = []
    public private(set) var assets: [Asset] = []
    /// The stacks the visible rows represent, keyed by their 置顶 asset id (§378).
    ///
    /// `assets` is the **projection**: one row per stack (its 置顶), plus every photo that is in no
    /// stack. This dictionary is the other half of that fact — a row's full membership, which is
    /// what the 「⧉ N」 badge counts and what 设为置顶 lists. A photo in no stack leaves no entry,
    /// so `stacksByTopID[asset.id] == nil` is the whole test for "draw no indicator".
    ///
    /// Rebuilt in `reload()` from the same query pass, never patched in place: the projection and
    /// this table can then never disagree about which row is a top, and nobody has to remember to
    /// update two things after a stack write.
    public private(set) var stacksByTopID: [String: StackSummary] = [:]
    public private(set) var stats: CatalogStats?
    public private(set) var loadError: String?

    /// Content-addressed thumbnail files for this library (`~/Library/Caches/Photons/<hash>/thumbs`).
    /// Owned by the session so every view shares one instance (and one set of cache counters).
    public private(set) var thumbnailCache: ThumbnailCache?

    // MARK: selection

    /// Multi-selection by asset id (⌘/⇧ in the grid, mirrored by the filmstrip).
    public private(set) var selection: Set<String> = []
    /// The "active" photo: the one the loupe shows and the inspector edits.
    public private(set) var anchorID: String?
    /// The ⇧ range base: the photo a range starts from.
    ///
    /// Deliberately separate from `anchorID`: the anchor is the thick blue ring / the photo the
    /// loupe shows, and it must stay put for the whole ⇧ gesture, while the base is what the next
    /// ⇧ click measures from. The first ⇧ click establishes it; further ⇧ clicks/arrows keep it.
    public private(set) var selectionBase: String?
    /// The far end of the current ⇧ range (the cursor ⇧+arrows advance). Not part of the
    /// selection itself; any non-⇧ selection change resets it to the clicked photo.
    private var rangeFocus: String?

    /// Set by `deleteAssets` just before the rows go away: the photo the anchor should hand over to
    /// when it is the anchor that got deleted. `reload()` consumes it exactly once, so a later
    /// reload for an unrelated reason (filter, folder, relink) keeps its original "fall back to the
    /// first row" behaviour.
    private var pendingAnchorSuccessor: String?

    // MARK: document

    /// The live document for the anchor photo. **Read-only from outside**: a slider goes through
    /// `applyEdit`, which is what bumps `editRevision` — the one signal the render loop listens to.
    /// A second writer that assign to `edit` directly would move pixels without invalidating them.
    public private(set) var edit: EditModel = .neutral

    /// Monotonic counter of document changes. The loupe observes *this* instead of diffing
    /// `EditModel` (a struct comparison on every observation pass, for no extra information).
    public private(set) var editRevision = 0

    /// 303 — callbacks for "a document edit moved the pixels of this asset". The loupe already watches
    /// `editRevision`; the three browsers need the **asset id** so they can refresh the one visible
    /// thumbnail instead of invalidating the library. Keys are removal tokens; the closures are
    /// expected to capture their owner weakly (see `WorkspaceRootView`).
    @ObservationIgnored
    private var editObservers: [UUID: (String) -> Void] = [:]

    /// 303 — observe document edits. The returned token removes the observer again. Not called for
    /// `publishViewState` (the mask overlay is view state, not a pixel change).
    @discardableResult
    public func addEditObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        editObservers[token] = observer
        return token
    }

    /// Remove an observer registered by `addEditObserver`.
    public func removeEditObserver(_ token: UUID) {
        editObservers.removeValue(forKey: token)
    }

    private func notifyEditObservers(assetID: String?) {
        guard let assetID else { return }
        for observer in editObservers.values { observer(assetID) }
    }

    /// The asset a live document edit belongs to: the loaded photo, or the anchor when no document is
    /// loaded (tests and a session with no library). `nil` = nothing to refresh.
    private var editedAssetID: String? { loadedEditAssetID ?? anchorAsset?.id }

    /// When the last document change landed. Slider→frame latency is measured from here, so the
    /// reported number includes the 50 ms debounce window rather than hiding it.
    public private(set) var lastEditChangedAt: CFAbsoluteTime = 0

    /// The undo stack (D10: snapshots plus a cursor, not a command log). Seeded with the state the
    /// document was opened in, so the floor of undo is "Original", never "neutral".
    public private(set) var history = EditHistory()

    /// The asset whose document is loaded in `edit` / `history`.
    public private(set) var loadedEditAssetID: String?

    /// What the last successful write to `develop_json` did (version, seq, row count). `nil` before
    /// the first save of this session — a UI that shows "saved" must read *this*, not assume.
    public private(set) var lastSaveResult: DevelopSaveResult?

    /// Why the last write failed, or nil. A failed save is never silent: the smoke asserts on it,
    /// and the inspector could surface it.
    public private(set) var lastPersistError: String?

    /// How many times `persist()` has actually written the catalog. Cheap proof that a commit
    /// reached the database instead of only the undo stack.
    public private(set) var persistCount = 0

    // MARK: catalog metadata (rating / flag / colour label)
    //
    // These are **library facts**, not document edits: they live in `assets.rating` /
    // `assets.flag` / `assets.color_label`, they never enter `EditModel`, `EditHistory` or
    // `develop_json`, and therefore ⌘Z never walks one back and `editRevision` never moves for
    // them. `metadataRevision` is the one signal the views watch to redraw badges, exactly like
    // `editRevision` is the one the loupe watches for pixels.

    /// Bumped on every metadata write. The grid/filmstrip observe *this* to refresh badges without
    /// a full `reload()` (row order and membership do not change unless a filter is on).
    public private(set) var metadataRevision = 0

    /// Number of metadata transactions issued this session — one per keystroke, however many
    /// photos are selected. The smoke asserts "5 selected → 1 transaction, 5 rows".
    public private(set) var metadataWriteCount = 0

    /// Rows the last metadata statement actually changed (`db.changesCount`).
    public private(set) var lastMetadataAffectedRows = 0

    /// What the grid is narrowed to. Survives a selection change by construction: only
    /// `applyFilter`/`clearFilter` write it, and `reload()` reads it.
    public private(set) var filter = CatalogFilter.none

    /// Distinct camera keys in the library, for the filter bar's popup. Refreshed when an
    /// unfiltered load runs, so narrowing the grid does not shrink the list of cameras to choose.
    public private(set) var allCameraKeys: [String] = []

    /// `camera_key` → `camera_model`, for the slot popup's labels (a key is `make|model`, lowercased;
    /// the model is what the user recognises). Refreshed with `allCameraKeys`.
    public private(set) var allCameraLabels: [String: String] = [:]

    /// The assets a metadata command applies to: the whole selection, or the anchor when the
    /// selection is empty (a filter can leave nothing selected while the anchor is still visible).
    public var metadataTargetIDs: [String] {
        let ids = selectedAssets.map(\.id)
        if !ids.isEmpty { return ids }
        if let anchorID, assets.contains(where: { $0.id == anchorID }) { return [anchorID] }
        return []
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// Label of the action ⌘Z would take back — what the menu item should read.
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }

    // MARK: view state (mirrors, never duplicates, model state)

    public var mode: Mode = .grid {
        didSet { if mode == .loupe, anchorID == nil { anchorID = assets.first?.id } }
    }

    /// True while a continuous control (a slider) is being dragged.
    ///
    /// View state, exactly like `mode` and `selectedMaskID`: not in `EditModel`, not in history, not
    /// persisted. It exists so entering the loupe on the first real write of a grid drag can be
    /// asserted without a window: the mode changes under the gesture, the gesture does not end.
    public private(set) var isAdjusting = false

    /// Slider press/release, called by the panel's one row builder (`InspectorView.sliderRow`).
    func setAdjusting(_ adjusting: Bool) {
        guard adjusting != isAdjusting else { return }
        isAdjusting = adjusting
    }

    // MARK: view state — sort order
    //
    // The order the grid, the left browser and the filmstrip read `assets` in. It is **one value in
    // one place**: the three views never sort anything themselves, they index this array, so "the
    // three views agree" holds by construction rather than by three copies of a comparator. It is
    // view state: not in the document, not in `EditHistory`, not in `develop_json` — flipping it must
    // leave `editRevision`, `history` and the pixels exactly where they were.

    /// `.newestFirst` (default) / `.oldestFirst`, restored from `PhotoSortPreferences` at launch.
    public private(set) var sortOrder: PhotoSortOrder

    /// Where the choice is remembered (`UserDefaults.standard` in the app).
    private let sortPreferenceStore: PhotoSortPreferences.Store

    /// Where 「上次打开哪个库」 is remembered. Injectable so a test owns its own domain.
    private let recentLibraryStore: RecentLibrary.Store

    /// Turned off by the smoke/bench harness (`UISmokeRunner`): its temporary library must not become
    /// the user's "last opened" library. Public because the runner sets it before `run()`.
    public var remembersRecentLibrary: Bool

    // MARK: view state — masks (Q22)
    //
    // None of this is in the document, in a cache key or in history. It is what the canvas and the
    // inspector are currently pointed at: which mask is selected, which tool a drag means, and how
    // wide the brush is. `EditModel.showMaskID` is the one piece that lives in the document *value*
    // (the renderer reads the document) but it too is view state — `MaskViewState` keeps it out of
    // snapshots and out of the stored blob.

    /// The mask the canvas paints into and the inspector edits.
    public private(set) var selectedMaskID: String?

    /// What a drag on the canvas means. `.off` = pan, which is the pre-mask behaviour.
    public var maskTool: MaskTool = .off

    /// Brush diameter in **short-edge units** (0.12 = 12 % of the short edge of the photo). Each
    /// stroke stores its own radius, so changing this never changes a stroke already painted.
    ///
    /// The three defaults are named constants because the panel's double-click reset puts a brush row
    /// back on them: a literal in the reset closure would be a second answer to 「画笔的默认是多少」.
    public static let defaultBrushSize: Double = 0.12
    /// 0…1. A hard brush (`1`) has a 1 px edge; `0` is a fully feathered stamp.
    public static let defaultBrushHardness: Double = 0.5
    /// 0…1 per-stroke alpha multiplier.
    public static let defaultBrushFlow: Double = 1.0

    public var brushSize: Double = CatalogSession.defaultBrushSize
    public var brushHardness: Double = CatalogSession.defaultBrushHardness
    public var brushFlow: Double = CatalogSession.defaultBrushFlow

    // MARK: view state — 修复画笔 (078 P0-1)
    //
    // View state, all four: arming the tool, which spot the panel points at, the radius the *next*
    // click will use and the mode it will use. Nothing here is in the document, in a cache key or in
    // a snapshot — the spots themselves are (`EditModel.healSpots`).

    /// The canvas click adds a spot instead of panning. Disarms the mask tools and vice versa: two
    /// canvas gestures that both claim the first click cannot both be armed.
    public var healTool: Bool = false

    /// The spot the panel's rows are about.
    public var selectedHealSpotID: String?

    /// Radius of the next spot, in short-edge units of the frame.
    public var healRadius: Double = HealSpot.defaultRadius

    /// Mode of the next spot.
    public var healMode: HealMode = .heal

    // MARK: view state — 229 红眼
    //
    // Same rule as the heal view state above: none of this is in the document, a snapshot or a
    // cache key. The spots themselves are.

    /// 修复 / 红眼 — what the next canvas click means.
    public var healToolMode: HealToolMode = .heal

    /// The red-eye search radius, in **view points** (the card's 0.5…8 pt slider). The controller
    /// converts it to short-edge units with the live projection, so it means the same distance on
    /// screen at fit and at 1:1.
    public var redEyeRadiusPoints: Double = RedEye.defaultRadiusPoints

    /// 0…1 — the spot's opacity, shown as 0…100 in the card.
    public var redEyeStrength: Double = 1.0

    /// What the last red-eye click measured (the card's one status line; `nil` = no pupil found).
    public private(set) var lastRedEyeDetection: RedEye.Detection?

    /// Vision's face/animal hints for one image. Injectable so a headless test can answer without
    /// running a model; production is `RedEyeVision`, on the click only.
    public var redEyeFaceHintProvider: ((LinearImage) -> [RedEyeFaceHint])? = { image in
        RedEyeVision.hints(in: image)
    }

    /// Internal door for `addRedEyeSpot`, so a view cannot pretend a detection happened.
    func setLastRedEyeDetection(_ detection: RedEye.Detection?) {
        lastRedEyeDetection = detection
    }

    /// 自动取源：**view state**，不进文档、不进快照、不进 cache key。默认开。
    public var autoHealSource: Bool = true

    /// 搜索读的那张图。由 loupe 在解码落地后装上（`decoded?.oriented()`）；测试里可以是 nil，
    /// 此时搜索返回 `.searchSkipped` 并退回 `(2r, 0)` —— 也就是 184 之前的行为。
    /// 已知限度：这是未裁切的正立图，裁切时环带量的是裁切前的内容（源仍合法，只是不最优）。
    public var healFrameProvider: (() -> LinearImage?)?

    /// 最近一次新点取源的结果（面板/测试读它；`nil` = 还没有新点）。
    public private(set) var lastHealSource: HealSourceResult?

    /// Internal door for `MaskCanvasController.addHealSpot` (same module): the setter stays private
    /// so a view cannot pretend a search happened.
    func setLastHealSource(_ result: HealSourceResult?) {
        lastHealSource = result
    }

    /// The **upright** pixel size of the photo on screen, as the renderer actually ingested it
    /// (`RenderGraph.sourceSize`, i.e. after EXIF orientation was applied — task 028).
    ///
    /// Mask parameters are normalised to this frame, and every short-edge distance (`brushSize`, a
    /// stroke's radius, a radial mask's rim) is a fraction of it. The catalog row's `width/height` are
    /// the *stored* dimensions, which are transposed for EXIF 5…8: a portrait frame then converts
    /// `left/right` rim offsets with the landscape ratio and the ellipse renders half again as wide as
    /// the hand drew it. Written once per presented photo by the loupe, keyed by asset id so a photo
    /// switch cannot inherit the previous picture's frame before its own decode lands.
    public internal(set) var ingestedSourceFrame: (assetID: String, size: ImageSize)?

    /// 290 — the EXIF orientation the import recorded for `assetID`, or `nil` when the row has no
    /// metadata (or no orientation). The first-frame stand-in runs **before** the first ingest
    /// publishes `ingestedSourceFrame`, so this is the one fact that turns the catalog row's stored
    /// dimensions into the upright aspect the thumbnail already shows.
    public func sourceOrientation(of assetID: String) -> ImageOrientation? {
        guard let catalog,
              let value = (try? catalog.metadata(assetId: assetID))?.orientation else { return nil }
        return ImageOrientation(exifOrDefault: value)
    }

    /// The crop tool's **live** draft geometry while the tool is open (派单 049).
    ///
    /// The draft is view state that lives in `CropToolController` and reaches the document only at
    /// 应用, so `edit` does not move while the box is being dragged — the information row would sit
    /// on the old numbers until the drag ended. This is the one bridge: written by the tool on every
    /// draft change (and cleared on 应用 / 取消 / 离开), read by the inspector, never written to the
    /// document, the history or the render key. `assetID` is carried because a published draft must
    /// not be applied to the next photo's row.
    public internal(set) var cropToolDraft: (assetID: String, geometry: GeometryGroup)?

    /// What the next drag on the canvas creates, when a shape gradient is waiting for one.
    ///
    /// View state like `maskTool`: selecting 线性/径向渐变 in the inspector's 新建 menu arms a drag,
    /// and the mask is created **when the drag ends** with the geometry the user drew. That ordering
    /// is what makes one gesture one snapshot instead of "new mask" + "move it".
    public var pendingMaskShape: MaskCreationKind?

    /// Drag on the canvas adjusts the selected linear/radial mask instead of panning.
    ///
    /// On by default because "I just drew an ellipse" is followed by "…a bit more to the left" far
    /// more often than by a pan, and only armed while a *shape* mask is selected — a brush mask, or
    /// no mask, leaves the camera alone.
    public var adjustShapeOnDrag: Bool = true

    /// The semantic sub-kind the next 语义 mask uses (the 新建 menu's submenu).
    public var pendingSemanticKind: SemanticKind = .subject

    /// The mask the frame is painting over, or nil.
    public var shownMaskID: String? { edit.showMaskID }

    /// The overlay is on for `selectedMaskID` — what the inspector's toggle reads.
    public var isShowingSelectedMask: Bool {
        guard let id = selectedMaskID else { return false }
        return edit.showMaskID == id
    }

    // MARK: decoder facts

    /// What the last decode actually used — v9 or a silent v8 downgrade (§11.1).
    public private(set) var capabilities: DecoderCapabilities?

    private var catalog: Catalog?

    /// Where the filter bar's state is remembered (043). Injectable so a test runs against its own
    /// domain and can count writes; production gets `UserDefaults.standard`.
    public let filterPersistence: FilterPersistence.Writer

    /// The library the filter is remembered *for* — the key of the archive the next write goes to.
    /// Set by `open`; nil until a library is open, which is why a filter applied with no library
    /// open is not written anywhere (there is no library to attach it to).
    private var filterPersistencePath: String?

    public init(filterStore: FilterPersistence.Store = UserDefaults.standard,
                sortPreferenceStore: PhotoSortPreferences.Store = UserDefaults.standard,
                recentLibraryStore: RecentLibrary.Store = UserDefaults.standard,
                remembersRecentLibrary: Bool = true) {
        filterPersistence = FilterPersistence.Writer(store: filterStore)
        self.sortPreferenceStore = sortPreferenceStore
        self.recentLibraryStore = recentLibraryStore
        self.remembersRecentLibrary = remembersRecentLibrary
        // Restored before the first `open()`, so a session's very first query already lands in the
        // order the user chose last time — there is no "restore after the first paint" flicker.
        sortOrder = PhotoSortPreferences.recall(from: sortPreferenceStore)
    }

    // MARK: lifecycle

    public var isOpen: Bool { catalog != nil }

    public func open(_ url: URL) throws {
        let c = try Catalog.open(at: url)
        catalog = c
        libraryURL = url.standardizedFileURL
        // A missing cache directory is created by the initialiser; a failure here only means the
        // grid falls back to placeholders, which must not stop the library from opening.
        thumbnailCache = try? ThumbnailCache(layout: c.layout)
        loadedEditAssetID = nil
        // Anything still pending belongs to the library we are leaving (043): write it before the
        // path changes, so a fast 打开另一个库 → 回来 does not lose the last click.
        filterPersistence.flush()
        let path = Self.filterPersistencePath(for: url)
        filterPersistencePath = path
        // The previous library's filter must not be inherited: this is the *reset* half of "remember
        // per library". Assigned directly rather than through `applyFilter` because the restore right
        // below (or the `reload()` further down) is what runs the query — one query, not three.
        filter = .none
        // 上一个库的相册范围同理不能继承：相册 id 属于那个库，留在 `selectedAlbumID` 里只会让新库的
        // 第一次查询空着（`reload()` 也会把它当"已不存在的相册"丢掉，但没必要开一次空查询）。
        selectedAlbumID = nil
        albums = []
        // Before the first query, so the grid's very first paint already carries 「原文件已移动」:
        // the flag is a filesystem fact and this is the only moment it can be fresh. A failure here
        // only means the flags keep yesterday's values, which is why it does not throw.
        lastAvailability = try? c.refreshAvailability()
        // 043 — the bar's slots are view state remembered per library, restored **before the first
        // query** so the grid's very first paint is already narrowed. It goes through `applyFilter`,
        // the door a click uses: a restored filter must be indistinguishable from a clicked one —
        // which also means its `reload()` is the only query this open runs when an archive exists.
        if let restored = filterPersistence.recall(libraryPath: path), restored != filter {
            applyFilter(restored)
        } else {
            reload()
        }
        // The preset list and the Develop menu read this cache; fill it as soon as the library is
        // open instead of waiting for the panel's first `onAppear`.
        reloadPresets()
        // 081 §3: the 复制设置 checklist is remembered **per library**, so it is read here and not
        // from `UserDefaults`. A library that never stored one answers 全部.
        copySelection = (try? c.copySelection()) ?? .all
        // 295 B: the next launch has no `--library`, so it has to know which library this was. Only
        // reached when `Catalog.open` succeeded — a failed open must not overwrite the last good one.
        if remembersRecentLibrary {
            RecentLibrary.remember(url, in: recentLibraryStore)
        }
    }

    /// Where this library's filter archive lives. The path is the library *directory*; the hash of it
    /// inside `FilterPersistence` is what makes a path with a user name or CJK safe as a defaults key.
    private static func filterPersistencePath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    public func reload() {
        guard let c = catalog else { return }
        do {
            roots = try c.roots()
            // One scan for the whole tree, before the rows: the source list and the photo list are
            // then guaranteed to describe the same library state, and a selected folder that lost
            // its last photo (a delete, a relink) stops filtering instead of filtering to nothing.
            folderNodes = (try? c.folderIndex()) ?? [:]
            // 相册：左栏的「相册」段与它每一行的数字都读这一个列表（078 B10）。加载在查询**之前**，
            // 因为下面那次 `assets()` 就带着 `selectedAlbumID`；一个已经不存在的相册（另一个进程删的、
            // 或者本进程刚删的）必须在这里被丢掉，否则网格会永远空着而左栏没有那一行可点回来。
            albums = (try? c.albums()) ?? []
            if let open = selectedAlbumID, !albums.contains(where: { $0.id == open }) {
                selectedAlbumID = nil
            }
            // Drop selections that no longer exist — a delete, a relink or a removed root. A dead
            // *root* drops its row outright; a dead *subfolder* falls back to its root, which is
            // what the single-selection model did ("the folder I was in lost its last photo" must
            // narrow to the root, not to nothing). Multi-selection keeps the other rows.
            if !selectedFolders.isEmpty {
                var kept: [FolderSelection] = []
                for sel in selectedFolders {
                    guard let id = sel.rootId, roots.contains(where: { $0.id == id }) else { continue }
                    guard let path = sel.normalizedPath else { kept.append(sel); continue }
                    if (folderNodes[id] ?? []).contains(where: { $0.path == path }) {
                        kept.append(sel)
                    } else {
                        kept.append(FolderSelection(rootId: id, path: nil))
                    }
                }
                let normalized = Self.normalizedFolders(kept)
                if normalized != selectedFolders { selectedFolders = normalized }
            }
            // The grid is the library view: everything the catalog has, in the session's sort order.
            // M3 has no paging; 10k rows is the design point.
            // The filter bar's value is folded into the *same* query the source list uses, so the
            // visible rows, their order and the count in the top bar can never disagree.
            //
            // The order is applied **here and nowhere else** on the load path: the query itself
            // returns `capture_time DESC` (the catalog's index order), and `sortOrder.sorted` makes
            // the array the one truth every view reads. Picking `.oldestFirst` therefore needs no
            // second SQL dialect (`ORDER BY … ASC`) and no second query — one comparator defines
            // "newest" for the grid, the browser and the strip at once.
            let f = filter
            let albumScope = selectedAlbumID.map { [$0] } ?? []
            assets = sortOrder.sorted(try c.assets(f.assetFilter(limit: 200_000,
                                                                 folders: selectedFolders,
                                                                 albumIds: albumScope)))
            // §378 — the other half of the projection: which stacks the visible rows stand for.
            // One query for every stack id on screen (not one per row), and only stacks whose
            // **top** survived the filter get an entry — a stack only a hidden member would match
            // is not in `assets` and must not be in this table either.
            stacksByTopID = Self.stacksByTop(assets, catalog: c)
            stats = try c.stats()
            loadError = nil
            // The camera list is a property of the library, not of the current filter: derive it
            // only from an unfiltered load so narrowing never removes a choice from its own popup.
            if !f.isActive {
                allCameraKeys = Array(Set(assets.compactMap(\.cameraKey))).sorted()
                var labels: [String: String] = [:]
                for asset in assets {
                    guard let key = asset.cameraKey, let model = asset.cameraModel, !model.isEmpty else { continue }
                    if labels[key] == nil { labels[key] = model }
                }
                allCameraLabels = labels
            }
        } catch {
            loadError = error.localizedDescription
            assets = []
            roots = []
            stacksByTopID = [:]
        }
        // Drop selections that no longer exist (a reload can follow an import).
        let ids = Set(assets.map(\.id))
        selection.formIntersection(ids)
        // The range base and cursor follow the same rule: an id that is gone cannot anchor a ⇧.
        if let base = selectionBase, !ids.contains(base) { selectionBase = nil }
        if let focus = rangeFocus, !ids.contains(focus) { rangeFocus = nil }
        let successor = pendingAnchorSuccessor
        pendingAnchorSuccessor = nil
        if let a = anchorID, !ids.contains(a) {
            // A delete hands the anchor to the next photo the user saw, not to the first row. Any
            // other reload keeps `pendingAnchorSuccessor == nil` and falls back to the first row.
            anchorID = successor.flatMap { ids.contains($0) ? $0 : nil } ?? assets.first?.id
        }
        if anchorID == nil { anchorID = assets.first?.id }
        if selection.isEmpty, let first = anchorID { selection = [first] }
        // A fresh library (or a new root) can leave `edit` pointing at the previous document; load
        // the anchor's stored document now instead of waiting for the next selection change.
        if let a = anchorAsset, loadedEditAssetID != a.id { loadEditForAnchor() }
    }

    // MARK: import (文件 ▸ 导入照片…)

    /// An `ImportService` for this library, for a caller that runs it **off the main actor**
    /// (`ImportCoordinator`). Nil when no library is open — which is exactly the condition the menu
    /// item is validated against.
    ///
    /// The engine is handed out instead of being driven by the session: `ImportService.run` is
    /// synchronous and does its own writing through `catalog.dbQueue`, so the caller owns the
    /// background queue and only the *result* comes back to the main actor.
    public func makeImportService() -> ImportService? {
        guard let catalog else { return nil }
        return ImportService(catalog: catalog)
    }

    /// After an import: reload, then select the first of `ids` that survived the current filter.
    /// A photo the filter hides must not become the anchor — that would leave the grid showing no
    /// selection at all. With nothing added the current selection is kept as it is.
    public func selectImported(_ ids: [String]) {
        reload()
        guard let hit = ids.first(where: { id in assets.contains { $0.id == id } }) else { return }
        selectOnly(hit)
    }

    // MARK: photo stacks (§378) — 库属性，不是编辑
    //
    // A stack is目录元数据: it lives in `assets.stack_id` / `assets.stack_rank`, so nothing in this
    // section touches `edit`, `history`, `develop_json` or `editRevision` — ⌘Z never walks a stack
    // back. Every verb is one transaction and **one** `metadataRevision` bump (the same signal a
    // rating uses), then one `reload()`: the projection (`assets` = tops only) and
    // `stacksByTopID` are recomputed together, so a card can never lose its 「⧉ N」 while the row
    // it counts is still hidden, or the other way round.

    /// Why the last stack command did nothing, or nil. Reported, never swallowed (same contract as
    /// `lastMetadataAffectedRows` / `lastAvailabilityError`).
    public private(set) var lastStackError: String?

    /// Rows the last stack statement changed.
    public private(set) var lastStackAffectedRows = 0

    /// The stack a displayed row stands for, or nil. `stacksByTopID` is keyed by the top id, and
    /// only tops are ever in `assets`, so this is the one lookup a cell needs.
    public func stackSummary(forAssetID id: String) -> StackSummary? {
        stacksByTopID[id]
    }

    /// Members of the stack behind a displayed row, in display order (top included). Asked when the
    /// right-click submenu opens, not on every paint.
    public func stackMembers(topID: String) -> [Asset] {
        guard let summary = stacksByTopID[topID], let catalog else { return [] }
        return (try? catalog.stackMembers(stackID: summary.id)) ?? []
    }

    /// Members of the stack an asset **belongs to** — the same list whether the id is the top or a
    /// hidden member. Nil when the id is in no stack.
    public func stackMembers(ofAssetID id: String) -> [Asset]? {
        guard let catalog else { return nil }
        if let summary = stacksByTopID[id] {
            return (try? catalog.stackMembers(stackID: summary.id)) ?? []
        }
        guard let found = (try? catalog.stackID(ofAsset: id)) ?? nil else { return nil }
        return try? catalog.stackMembers(stackID: found)
    }

    /// 堆叠所选照片 (⌘G): the selection, **in display order**, becomes one new stack whose first
    /// member is 置顶.
    ///
    /// Fewer than two photos is a no-op with an error, not a stack of one: one photo is already a
    /// stack's worth of nothing, and a "stack" of one would hide its own badge rule (≥ 2).
    /// Cross-album and cross-filter selections are allowed on purpose — the members need not be
    /// visible together, and the path is not validated at all.
    @discardableResult
    public func stackSelection() -> StackSummary? {
        guard let catalog else {
            lastStackError = "未打开库"
            return nil
        }
        let ids = selectedAssets.map(\.id)
        guard ids.count >= 2 else {
            lastStackError = "堆叠至少需要选中两张照片"
            return nil
        }
        do {
            guard let summary = try catalog.makeStack(assetIDs: ids) else {
                lastStackError = "选中的照片已经不在库里"
                return nil
            }
            lastStackError = nil
            lastStackAffectedRows = summary.count
            metadataWriteCount += 1
            lastMetadataAffectedRows = summary.count
            metadataRevision &+= 1
            reload()
            // The other members just left the projection: the selection follows to the 置顶 only.
            if assets.contains(where: { $0.id == summary.topID }) { selectOnly(summary.topID) }
            return summary
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// 取消堆叠 (⇧⌘G): every stack the selection (or the anchor) touches dissolves — all of its
    /// members return to `stack_id = NULL, stack_rank = 0`.
    ///
    /// Returns the number of photos that came back. Zero with no stack in the selection is not an
    /// error condition worth an alert; `lastStackError` stays nil (the user sees nothing happen
    /// because nothing was stacked).
    @discardableResult
    public func ungroupSelection() -> Int {
        guard let catalog else {
            lastStackError = "未打开库"
            return 0
        }
        let ids = metadataTargetIDs
        guard !ids.isEmpty else { return 0 }
        // The members that come back are what the user selected the *stack* for; select them again
        // after the reload so ⇧⌘G visibly restores the row group.
        var returning: [String] = []
        for id in ids {
            if let summary = stacksByTopID[id] { returning.append(contentsOf: summary.memberIDs) }
        }
        do {
            let affected = try catalog.ungroup(assetIDs: ids)
            guard affected > 0 else {
                lastStackError = nil
                return 0
            }
            lastStackError = nil
            lastStackAffectedRows = affected
            metadataWriteCount += 1
            lastMetadataAffectedRows = affected
            metadataRevision &+= 1
            reload()
            let visible = returning.filter { id in assets.contains { $0.id == id } }
            if !visible.isEmpty {
                setSelection(Set(visible), anchor: visible.first)
            }
            return affected
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return 0
        }
    }

    /// 设为置顶: the chosen member becomes the stack's top, and the previous top takes its old rank
    /// (a swap, not a re-sort).
    ///
    /// The row in `assets` is **replaced** by the new top on the next projection, and the selection
    /// follows it — that is what "click the second member and the card becomes that photo" means.
    @discardableResult
    public func setStackTop(assetID: String) -> Bool {
        guard let catalog else {
            lastStackError = "未打开库"
            return false
        }
        let stackID = stacksByTopID.values.first(where: { $0.memberIDs.contains(assetID) })?.id
            ?? (try? catalog.stackID(ofAsset: assetID)).flatMap { $0 }
        guard let stackID else {
            lastStackError = "这张照片不在任何堆叠里"
            return false
        }
        do {
            let changed = try catalog.setStackTop(stackID: stackID, assetID: assetID)
            lastStackError = nil
            guard changed else { return false }        // already 置顶: no write, no revision
            lastStackAffectedRows = 3                 // chosen, old top, and the stack row they share
            metadataWriteCount += 1
            lastMetadataAffectedRows = 2
            metadataRevision &+= 1
            reload()
            if assets.contains(where: { $0.id == assetID }) { selectOnly(assetID) }
            return true
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return false
        }
    }

    // MARK: HDR 合成 (§384) — 右键菜单一个动词，不弹窗口
    //
    // The user's contract: 「不用弹窗口，直接和堆叠一样，在右键菜单入口」 and 「参与合成的照片 = 用户
    // 自己确认的方式就是先选好，再点菜单项」. So there is no sheet, no frame picker and no second
    // dialog: the selection *is* the choice, and the whole job is one verb that reports into
    // `lastHDRMergeError` / `lastHDRMergeProgress` — the same "a failure is never silent" contract
    // `lastStackError` keeps.
    //
    // Threading cannot be relaxed: `inspect` ≈2.8 s/frame, `merge` ≈15 s per 60 MP frame, and
    // `ImportService.run` is synchronous with its own disk I/O. The whole body therefore runs on
    // `hdrMergeQueue` and only the *result* comes back to the main actor. `hdrMergeRanOffMain`
    // records what the worker actually saw, so a test can assert the hop instead of trusting this
    // comment (§3 ⑦).

    /// Why the last HDR merge did not happen, in the service's own Chinese prose
    /// (`HDRMergeService.Failure.description`) — or the tool's compatibility sentence, which is
    /// already specific (「尺寸不一致：…」). Nil after a success. Never a sheet: no windows.
    public private(set) var lastHDRMergeError: String?

    /// The last progress line (`解码 1/3…`), then a one-line summary after a success. One string the
    /// panel or the footer can read — there is no global HUD in this app and §384 says not to build
    /// one for this.
    public private(set) var lastHDRMergeProgress: String?

    /// Runs started / finished. A test waits for the second number instead of sleeping.
    public private(set) var hdrMergeRunCount = 0
    public private(set) var hdrMergeCompletionCount = 0

    /// What the worker thread saw when it entered the blocking body. `nil` before the first run;
    /// `false` would mean the merge ran on the main thread — the bug §3 ⑦ exists to catch.
    public private(set) var hdrMergeRanOffMain: Bool?

    /// True between the click and the result: a second click must not start a second 15 s job.
    public private(set) var isHDRMergeRunning = false

    /// What the last successful merge produced — the numbers the tool reported, the asset that joined
    /// the library, and the stack it tops. Nil until a merge succeeds; the failure path leaves it nil
    /// and fills `lastHDRMergeError` instead.
    public struct HDRMergeReport: Sendable, Equatable {
        public let output: URL
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let whiteLevel: Int
        public let assetID: String
        public let stackTopID: String
        public let stackCount: Int
    }

    public private(set) var lastHDRMergeReport: HDRMergeReport?

    /// The service the menu validates against and the verb calls. Injectable so a test can point the
    /// client at a missing binary (⇒ 「未找到 hdrmerge-swift」) or at a pinned copy.
    public var hdrMergeService = HDRMergeService()

    /// Whether the merge tool is **actually there**.
    ///
    /// `HDRMergeService.isAvailable` only answers "a client was resolved" — a client can name a path
    /// that no longer exists (a bundle that lost its binary, a Homebrew upgrade mid-session), and
    /// `merge` is what would then fail with `tool_missing` 15 s later. The menu needs the same answer
    /// the merge would get, so the check is the executable itself.
    public var isHDRMergeAvailable: Bool {
        guard let client = hdrMergeService.client else { return false }
        return FileManager.default.isExecutableFile(atPath: client.executableURL.path)
    }

    /// The queue the blocking half runs on. Injectable so a test can observe the hop without racing
    /// the global pool.
    public var hdrMergeQueue = DispatchQueue(label: "photons.hdr.merge", qos: .userInitiated)

    /// 合成所选的照片: 结果 + 参与的原帧 = 一个新堆叠，**结果为置顶**，参与的原帧抽离旧堆叠。
    ///
    /// Returns the participating asset ids (empty when the verb refused to start), so a test can name
    /// the frames without re-reading the selection.
    @discardableResult
    public func hdrMergeSelection() -> [String] {
        hdrMergeRunCount += 1
        lastHDRMergeError = nil
        lastHDRMergeProgress = nil
        hdrMergeRanOffMain = nil

        guard let catalog else {
            lastHDRMergeError = "未打开库"
            return []
        }
        guard !isHDRMergeRunning else {
            lastHDRMergeError = "已有一次 HDR 合成在进行"
            return []
        }
        guard isHDRMergeAvailable else {
            lastHDRMergeError = HDRMergeService.Failure.toolMissing.description
            return []
        }
        // The two gates the menu greys on, re-checked here: a stale menu or a keyboard path must not
        // be able to start a job the tool would refuse 3 s later.
        let chosen = selectedAssets
        var frames: [URL] = []
        var participants: [String] = []
        for asset in chosen {
            guard HDRMergeService.mergeableExtensions.contains(asset.ext.lowercased()) else {
                lastHDRMergeError = HDRMergeService.Failure.notCFARaw(asset.filename).description
                return []
            }
            guard let url = fileURL(for: asset) else {
                lastHDRMergeError = HDRMergeService.Failure.unreadable(asset.filename).description
                return []
            }
            frames.append(url)
            participants.append(asset.id)
        }
        guard frames.count >= 2 else {
            lastHDRMergeError = HDRMergeService.Failure.notEnoughFrames(frames.count).description
            return []
        }
        guard let importService = makeImportService(),
              let rootID = chosen.first?.sourceRootId
        else {
            lastHDRMergeError = "未打开库"
            return []
        }

        let service = hdrMergeService
        let queue = hdrMergeQueue
        isHDRMergeRunning = true
        lastHDRMergeProgress = "准备合成…"
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.lastHDRMergeProgress = text }
        }
        queue.async { [weak self] in
            let run = Self.runHDRMerge(service: service, importService: importService,
                                       catalog: catalog, frames: frames,
                                       participantIDs: participants,
                                       rootID: rootID, progress: report)
            Task { @MainActor in self?.finishHDRMerge(run) }
        }
        return participants
    }

    /// What one HDR run produced. A plain `Sendable` box so the background half never touches the
    /// session (which is main-actor isolated).
    private struct HDRMergeRun: Sendable {
        var ranOffMain = false
        var failure: String?
        var output: URL?
        var assetID: String?
        var width = 0
        var height = 0
        var frameCount = 0
        var whiteLevel = 0
        var stackTopID: String?
        var stackCount = 0
    }

    /// The blocking half. **Runs off the main thread** (asserted by the caller via `ranOffMain`).
    ///
    /// Order is the contract: 预检 → merge → 加进库 → 抽离旧堆叠 + 组新堆叠. The merged file lands
    /// next to its sources (`HDRMergeService` default), so no extra directory is invented here.
    private nonisolated static func runHDRMerge(service: HDRMergeService,
                                               importService: ImportService,
                                               catalog: Catalog,
                                               frames: [URL],
                                               participantIDs: [String],
                                               rootID: String,
                                               progress: @escaping @Sendable (String) -> Void) -> HDRMergeRun {
        var run = HDRMergeRun()
        run.ranOffMain = !Thread.isMainThread
        do {
            progress("预检 \(frames.count) 帧…")
            if let issue = try service.compatibilityIssue(frames) {
                run.failure = issue
                return run
            }

            var importedID: String?
            var importFailure: String?
            let outcome = try service.merge(frames, progress: { progress($0) }, onOutput: { url in
                // `onOutput` is the module's own "add this to your library" hook — it knows nothing
                // about catalogs, which is why the import lives here and not in PhotonsExtensions.
                // `ImportService` dedupes by content hash, so a re-run cannot create two rows.
                do {
                    let summary = try importService.run(sources: [url],
                                                        options: ImportOptions(mode: .reference,
                                                                               rootID: rootID,
                                                                               recursive: false))
                    importedID = summary.addedAssetIDs.first
                    if importedID == nil {
                        importFailure = "合成结果已经在库里（内容相同），没有新建照片"
                    }
                } catch {
                    importFailure = error.localizedDescription
                }
            })
            run.width = outcome.width
            run.height = outcome.height
            run.frameCount = outcome.frameCount
            run.whiteLevel = outcome.whiteLevel
            run.output = outcome.output
            if let importFailure {
                run.failure = importFailure
                return run
            }
            guard let importedID else {
                run.failure = "合成结果未能加入照片库"
                return run
            }
            run.assetID = importedID

            progress("加入堆叠…")
            let summary = try catalog.makeHDRStack(resultAssetID: importedID,
                                                  participantIDs: participantIDs)
            run.stackTopID = summary?.topID
            run.stackCount = summary?.count ?? 0
            return run
        } catch {
            run.failure = (error as? HDRMergeService.Failure)?.description
                ?? error.localizedDescription
            return run
        }
    }

    /// Back on the main actor: publish the outcome, bump the projection, select the result.
    private func finishHDRMerge(_ run: HDRMergeRun) {
        isHDRMergeRunning = false
        hdrMergeCompletionCount += 1
        hdrMergeRanOffMain = run.ranOffMain
        lastHDRMergeError = run.failure
        lastHDRMergeReport = nil
        guard run.failure == nil, let assetID = run.assetID else {
            lastHDRMergeProgress = nil
            return
        }
        // A stack write is catalog metadata, not an edit: the same signal a rating uses, and ⌘Z never
        // walks it back.
        metadataWriteCount += 1
        lastMetadataAffectedRows = run.stackCount
        metadataRevision &+= 1
        lastStackError = nil
        lastStackAffectedRows = run.stackCount
        reload()
        // The result is 置顶, so it is the row the projection shows; select it and the user sees the
        // finished photo where the bracketed frames used to be.
        if assets.contains(where: { $0.id == assetID }) { selectOnly(assetID) }
        if let output = run.output {
            lastHDRMergeReport = HDRMergeReport(output: output, width: run.width, height: run.height,
                                                frameCount: run.frameCount, whiteLevel: run.whiteLevel,
                                                assetID: assetID, stackTopID: run.stackTopID ?? "",
                                                stackCount: run.stackCount)
        }
        lastHDRMergeProgress = "合成完成：\(run.width)×\(run.height)，\(run.frameCount) 帧"
    }

    // MARK: 模型降噪 (§386) — 右键菜单一个动词，不弹窗口
    //
    // 和 §384 的 HDR 合成同一套口径：入口在右键菜单、点下去不弹窗、选择本身就是「处理哪张」。
    // 不同的是**只处理单张**，而且产物是「原图的降噪版」，所以完成后原图不消失 ——
    // 它成为新堆叠的第二张，产物置顶。
    //
    // 线程：一张 60 MP 是 1426 个 tile（step 208），GPU 上也要几十秒；解码 / 归一化 /
    // 写 DNG 同样是几十秒级的同步工作。整个 body 因此在 `denoiseQueue` 上跑，主线程只收结果。
    // `denoiseRanOffMain` 记录 worker 实际看到的值，测试断言的是这个，不是注释。

    /// 为什么上一次模型降噪没做成，中文原因。成功时为 nil。永远不弹窗。
    public private(set) var lastDenoiseError: String?

    /// 进度一行（`降噪 9536×6344，tile 256…`），成功后是结果摘要。没有全局 HUD（§2.5）。
    public private(set) var lastDenoiseProgress: String?

    /// 起了几次 / 完成了几次。测试等第二个数字，不靠 sleep。
    public private(set) var denoiseRunCount = 0
    public private(set) var denoiseCompletionCount = 0

    /// worker 进入阻塞体时看到的值。`nil` = 还没跑过；`false` 意味着跑在主线程（§3 ⑥ 要抓的 bug）。
    public private(set) var denoiseRanOffMain: Bool?

    /// 点了到结果之间为 true：第二次点击不许再起一个几十秒的任务。
    public private(set) var isDenoiseRunning = false

    /// 上一次成功的数字。失败时留 nil 并填 `lastDenoiseError`。
    public struct DenoiseReport: Sendable, Equatable {
        public let output: URL
        public let source: URL
        public let width: Int
        public let height: Int
        public let whiteLevel: Double
        public let cfa: String
        public let tiles: Int
        public let seconds: Double
        public let byteCount: Int
        public let assetID: String
        public let stackTopID: String
        public let stackCount: Int
    }

    public private(set) var lastDenoiseReport: DenoiseReport?

    /// 工具与模型在哪儿。Injectable：测试把它指向一个不存在的可执行文件或模型路径，
    /// 就能复现「菜单灰掉的三种原因」，不需要真装东西。
    public var denoiseLocation = AnselDenoiseLocation()

    /// 工具**真的在**：`AnselDenoiseClient` 会把一条不存在的显式路径原样收下，
    /// 所以这里问的是那个文件本身（与 `isHDRMergeAvailable` 同一条规矩）。
    public var isDenoiseToolAvailable: Bool {
        guard let client = denoiseLocation.client() else { return false }
        return FileManager.default.isExecutableFile(atPath: client.executableURL.path)
    }

    /// 模型在四级解析顺序里找到了没有。
    public var isDenoiseModelAvailable: Bool {
        denoiseLocation.resolvedModel() != nil
    }

    /// 缺模型时 tooltip 要写的完整期望路径。
    public var denoiseModelPathHint: String { denoiseLocation.modelPathHint() }

    /// 阻塞的那一半跑在这个队列上。Injectable，测试因此能不抢全局池。
    public var denoiseQueue = DispatchQueue(label: "photons.denoise", qos: .userInitiated)

    /// 对选中的**那一张**跑模型降噪：产物落在原图同目录，然后原图 + 产物组成一个新堆叠、
    /// **产物置顶**、选中产物。
    ///
    /// 返回参与的原图 id（拒绝启动时为空数组），测试因此不用再读一遍选择。
    @discardableResult
    public func denoiseSelection() -> [String] {
        denoiseRunCount += 1
        lastDenoiseError = nil
        lastDenoiseProgress = nil
        denoiseRanOffMain = nil

        guard let catalog else {
            lastDenoiseError = AnselDenoiseNotices.noLibrary
            return []
        }
        guard !isDenoiseRunning else {
            lastDenoiseError = AnselDenoiseNotices.alreadyRunning
            return []
        }
        guard isDenoiseToolAvailable else {
            lastDenoiseError = AnselDenoiseNotices.toolMissing
            return []
        }
        guard isDenoiseModelAvailable else {
            lastDenoiseError = AnselDenoiseNotices.modelMissing(denoiseModelPathHint)
            return []
        }
        // 菜单已经拦过这三条；这里是第二次，因为一个过期的菜单行或键盘路径不该让任务白跑。
        let chosen = selectedAssets
        guard chosen.count == 1 else {
            lastDenoiseError = AnselDenoiseNotices.singlePhotoOnly
            return []
        }
        let asset = chosen[0]
        guard asset.ext.lowercased() == "dng" else {
            lastDenoiseError = AnselDenoiseNotices.onlyDNG(asset.filename)
            return []
        }
        guard let url = fileURL(for: asset) else {
            lastDenoiseError = AnselDenoiseNotices.onlyDNG(asset.filename)
            return []
        }
        guard let importService = makeImportService() else {
            lastDenoiseError = AnselDenoiseNotices.noLibrary
            return []
        }

        let job = AnselDenoiseJob(location: denoiseLocation)
        let queue = denoiseQueue
        let participantID = asset.id
        let rootID = asset.sourceRootId
        isDenoiseRunning = true
        lastDenoiseProgress = "准备降噪…"
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.lastDenoiseProgress = text }
        }
        queue.async { [weak self] in
            let run = Self.runDenoise(job: job, importService: importService, catalog: catalog,
                                      source: url, participantID: participantID, rootID: rootID,
                                      progress: report)
            Task { @MainActor in self?.finishDenoise(run) }
        }
        return [participantID]
    }

    /// 一次降噪的产物。纯 `Sendable` 盒子，后台那一半永远不碰 session。
    private struct DenoiseRun: Sendable {
        var ranOffMain = false
        var failure: String?
        var output: URL?
        var source: URL?
        var assetID: String?
        var width = 0
        var height = 0
        var whiteLevel: Double = 0
        var cfa = ""
        var tiles = 0
        var seconds: Double = 0
        var byteCount = 0
        var stackTopID: String?
        var stackCount = 0
    }

    /// 阻塞的那一半。**不在主线程**（由 `ranOffMain` 断言）。
    ///
    /// 顺序就是契约：降噪 → 加进库 → 抽离旧堆叠 + 组新堆叠。产物写在源目录，
    /// 所以走 `mode: .reference` + 原图的 `sourceRootId`（与 §384 一致）。
    private nonisolated static func runDenoise(job: AnselDenoiseJob,
                                               importService: ImportService,
                                               catalog: Catalog,
                                               source: URL,
                                               participantID: String,
                                               rootID: String,
                                               progress: @escaping @Sendable (String) -> Void) -> DenoiseRun {
        var run = DenoiseRun()
        run.ranOffMain = !Thread.isMainThread
        do {
            let outcome = try job.run(source: source, progress: { progress($0) })
            run.output = outcome.output
            run.source = source
            run.width = outcome.width
            run.height = outcome.height
            run.whiteLevel = outcome.whiteLevel
            run.cfa = outcome.cfa
            run.tiles = outcome.tiles
            run.seconds = outcome.seconds
            run.byteCount = outcome.byteCount

            progress("加入照片库…")
            // `ImportService` 按内容哈希去重，重跑不会造出第二行。
            let summary = try importService.run(sources: [outcome.output],
                                               options: ImportOptions(mode: .reference,
                                                                      rootID: rootID,
                                                                      recursive: false))
            guard let importedID = summary.addedAssetIDs.first else {
                run.failure = "降噪结果已经在库里（内容相同），没有新建照片"
                return run
            }
            run.assetID = importedID

            progress("组成堆叠…")
            let summary2 = try catalog.makeStack(resultAssetID: importedID,
                                                 participantIDs: [participantID])
            run.stackTopID = summary2?.topID
            run.stackCount = summary2?.count ?? 0
            return run
        } catch {
            run.failure = (error as? AnselDenoiseJobError)?.description ?? error.localizedDescription
            return run
        }
    }

    /// 回到主 actor：发布结果、推进投影、选中产物。
    private func finishDenoise(_ run: DenoiseRun) {
        isDenoiseRunning = false
        denoiseCompletionCount += 1
        denoiseRanOffMain = run.ranOffMain
        lastDenoiseError = run.failure
        lastDenoiseReport = nil
        guard run.failure == nil, let assetID = run.assetID else {
            lastDenoiseProgress = nil
            return
        }
        // 堆叠是库元数据，不是编辑：和评分用同一个信号，⌘Z 不会走回去。
        metadataWriteCount += 1
        lastMetadataAffectedRows = run.stackCount
        metadataRevision &+= 1
        lastStackError = nil
        lastStackAffectedRows = run.stackCount
        reload()
        // 产物是置顶，也就是投影里这一行代表的那张 —— 选中它，用户立刻看到降噪结果。
        if assets.contains(where: { $0.id == assetID }) { selectOnly(assetID) }
        if let output = run.output {
            lastDenoiseReport = DenoiseReport(output: output,
                                              source: run.source ?? output,
                                              width: run.width, height: run.height,
                                              whiteLevel: run.whiteLevel, cfa: run.cfa,
                                              tiles: run.tiles, seconds: run.seconds,
                                              byteCount: run.byteCount,
                                              assetID: assetID, stackTopID: run.stackTopID ?? "",
                                              stackCount: run.stackCount)
        }
        lastDenoiseProgress = "降噪完成：\(run.width)×\(run.height)，\(run.tiles) 个 tile"
    }

    /// The `stacksByTopID` half of the projection, computed from the rows the query just returned.
    ///
    /// Only stack ids present in `visible` are asked for, so a filter that hides every member of a
    /// stack costs nothing. A stack whose top is missing from the query (a soft-deleted top, a row
    /// whose rank was moved) contributes no entry at all: the dictionary is keyed by top, and the
    /// contract is 「no entry = draw no indicator」.
    static func stacksByTop(_ visible: [Asset], catalog: Catalog) -> [String: StackSummary] {
        let stackIDs = Set(visible.compactMap(\.stackId))
        guard !stackIDs.isEmpty else { return [:] }
        guard let members = try? catalog.stackMembers(stackIDs: Array(stackIDs)) else { return [:] }
        var out: [String: StackSummary] = [:]
        for (id, rows) in members {
            guard let top = rows.first(where: { $0.stackRank == 0 }) else { continue }
            guard visible.contains(where: { $0.id == top.id }) else { continue }
            out[top.id] = StackSummary(id: id, memberIDs: rows.map(\.id), topID: top.id)
        }
        return out
    }

    // MARK: sort order (view state: one value, three views)

    /// Switch the order the three browsers read the library in, and remember the choice.
    ///
    /// No query and no decode: the array is re-sorted **in place from what is already loaded**, so a
    /// toggle costs one `sorted` and one `reloadData` per view — the thumbnails come back out of the
    /// shared memory cache (`ThumbnailProvider.serveFromMemory`), which is why the pixel hash, the
    /// document and the undo stack all read the same afterwards. Bumping `sortOrder` is also the
    /// one signal the views observe (`ObservationBridge`), so the grid, the left browser and the
    /// filmstrip refresh from this one write.
    public func setSortOrder(_ order: PhotoSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        assets = order.sorted(assets)
        PhotoSortPreferences.remember(order, in: sortPreferenceStore)
    }

    /// What the sort button does: `新→旧 ⇄ 旧→新`.
    public func toggleSortOrder() { setSortOrder(sortOrder.toggled) }

    // MARK: selection

    /// The folder rows the source tree has highlighted (021 B), in the order the user added them.
    ///
    /// Empty means no folder constraint — the whole library — and that is also how 「全部照片」 is
    /// stored: it is the *absence* of a constraint, not a clause. The old model was one
    /// `selectedRootID` + one `selectedFolderPath`, which could only ever name a single root's single
    /// subtree; ⌘-multi-select needs a set, and a set that spans roots.
    ///
    /// Normalised on the way in (`normalizedFolders`): 「全部照片」 collapses the whole set, duplicate
    /// rows collapse to one, and paths are canonicalised — so `reload()` compares like with like and
    /// a ⌘-click that changes nothing does not re-run the query.
    public private(set) var selectedFolders: [FolderSelection] = []

    /// `nil` = all photos. Read-only convenience for the single-selection case (the tree's own
    /// probes and the 020-era tests read it); with a multi-selection it is `nil`, because there is
    /// no single root to name — `selectedFolders` is the truth.
    public var selectedRootID: String? {
        guard selectedFolders.count == 1 else { return nil }
        return selectedFolders[0].rootId
    }

    /// A folder inside `selectedRootID`, relative to it and `/`-separated; `""` = the whole root.
    /// Same single-selection caveat as `selectedRootID`, and `""` whenever the set is empty (the
    /// whole library) so the old "全部照片 sets the path to empty" assertion still means what it says.
    public var selectedFolderPath: String {
        guard selectedFolders.count == 1 else { return "" }
        return selectedFolders[0].normalizedPath ?? ""
    }

    /// Per-root folder trees, filled by `reload()` from one `folderIndex()` scan. The browser draws
    /// its rows and reads its counts from here — never from `stats.byRoot`, which keys on the
    /// display name and therefore cannot tell two folders of the same name apart.
    public private(set) var folderNodes: [String: [FolderNode]] = [:]

    /// 相册（078 B10）。`reload()` 从 `Catalog.albums()` 填，每行带成员数；左栏那一列的数字、
    /// 「这一行点开有几张」和命令行 `library albums` 是同一份数据，不是三份各自算的。
    public private(set) var albums: [AlbumSummary] = []

    /// 当前打开的相册，`nil` = 不在任何相册里。与 `selectedFolders` 互斥（见 `selectFolders`）：
    /// 左栏只有一个「范围」高亮，网格只有一个范围。
    public private(set) var selectedAlbumID: String?

    /// 相册集合或成员数每变一次 +1 —— 与 `metadataRevision` 同一套用法：视图观察这个数，不去 diff
    /// 整个数组。**不进文档、不进历史**：相册是库属性，`editRevision` 不会为它动。
    public private(set) var albumRevision = 0

    public func selectRoot(_ id: String?) {
        selectFolder(rootID: id, path: "")
    }

    /// One click in the folder tree: root + subtree prefix, one reload.
    public func selectFolder(rootID: String?, path: String) {        selectFolders([FolderSelection(rootId: rootID, path: path)])
    }

    /// The whole selection at once — what a ⌘-click, a ⇧-range or a "clicked the empty area" hands
    /// over. One reload per gesture, never one per row.
    public func selectFolders(_ folders: [FolderSelection]) {
        let normalized = Self.normalizedFolders(folders)
        // 相册与文件夹是同一个问题的两个入口（「现在在看什么范围」）。点任意文件夹行 —— 包括
        // 「全部照片」—— 就意味着离开相册，即使文件夹集合本来就是空的：那一下点击的语义是
        // 「回到全库」，不是「什么都不做」。所以 `selectedAlbumID` 也参与这个 guard。
        guard normalized != selectedFolders || selectedAlbumID != nil else { return }
        selectedFolders = normalized
        selectedAlbumID = nil
        reload()
    }

    /// Canonical form of a selection, so the tree, the query and the highlight all agree.
    ///
    /// * 「全部照片」 (`rootId == nil`) means the whole library → the selection collapses to empty; the
    ///   other rows are ignored rather than ORed with everything (021 §B, last row of the table).
    /// * duplicates collapse (`Hashable` on `(rootId, path)`, paths canonicalised) — two highlights on
    ///   one row are not two clauses.
    /// * `day2` + `day2/sub` is left **as is**: the union is `day2`'s subtree by arithmetic, the SQL
    ///   OR returns each row once, and both rows stay highlighted because the user selected both.
    public static func normalizedFolders(_ folders: [FolderSelection]) -> [FolderSelection] {
        if folders.contains(where: { $0.isAllPhotos }) { return [] }
        var seen = Set<FolderSelection>()
        var out: [FolderSelection] = []
        for folder in folders {
            guard let root = folder.rootId else { continue }
            let canonical = FolderSelection(rootId: root, path: folder.normalizedPath)
            if seen.insert(canonical).inserted { out.append(canonical) }
        }
        return out
    }

    /// The folders of one root. Always contains the `""` node (the root itself) when it holds a photo,
    /// which is where the root row's count comes from.
    public func folderNodes(forRoot id: String) -> [FolderNode] { folderNodes[id] ?? [] }

    /// Photos per root — read from the same tree the rows are drawn from, so a count can never
    /// disagree with what expanding the row reveals.
    public var photoCountByRoot: [String: Int] {
        var out: [String: Int] = [:]
        for (id, nodes) in folderNodes { out[id] = nodes.first { $0.path.isEmpty }?.total ?? 0 }
        return out
    }

    // MARK: albums (078 B10) — 库属性，不是文档属性
    //
    // 这一段里没有一个函数碰 `edit` / `history` / `develop_json`：相册成员是「谁和谁放在一起看」，
    // 不是「这张照片长什么样」。所以 ⌘Z 不会撤一次「加入相册」，`editRevision` 也不会动一下
    // （`AlbumCRUDTests.testAlbumWritesNeverTouchTheDocument` 把这条钉成断言）。

    /// 点左栏的相册行：一个范围，一次查询。
    ///
    /// 与文件夹互斥是**设计**而不是限制：左栏是「现在看什么」的唯一入口，两个高亮意味着两个
    /// 不同的范围同时生效，而网格只能画一个结果 —— 那种不一致正是 078 B10 要消掉的东西。
    /// 筛选条（026 的槽位）不受影响：范围是 AND 的一边，挑选是另一边。
    public func selectAlbum(_ id: String?) {
        guard id != selectedAlbumID else { return }
        selectedAlbumID = id
        if id != nil { selectedFolders = [] }
        reload()
    }

    @discardableResult
    public func createAlbum(named name: String) throws -> AlbumSummary {
        guard let catalog else { throw AlbumError.noLibrary }
        let album = try catalog.createAlbum(named: name)
        try refreshAlbums()
        return albums.first { $0.id == album.id }
            ?? AlbumSummary(id: album.id, parentId: album.parentId, name: album.name,
                            sort: album.sort, createdAt: album.createdAt, count: 0)
    }

    @discardableResult
    public func renameAlbum(id: String, to name: String) throws -> AlbumSummary {
        guard let catalog else { throw AlbumError.noLibrary }
        let album = try catalog.renameAlbum(id: id, to: name)
        try refreshAlbums()
        return albums.first { $0.id == album.id }
            ?? AlbumSummary(id: album.id, parentId: album.parentId, name: album.name,
                            sort: album.sort, createdAt: album.createdAt, count: 0)
    }

    /// 删相册 —— **只删相册与成员关系，照片留在库里**。若删的正是当前打开的那个相册，
    /// 网格回到全库（不是回到一个已经不存在的相册）。
    @discardableResult
    public func deleteAlbum(id: String) throws -> AlbumDeleteReport {
        guard let catalog else { throw AlbumError.noLibrary }
        let report = try catalog.deleteAlbum(id: id)
        if selectedAlbumID == id { selectedAlbumID = nil }
        try refreshAlbums()
        reload()
        return report
    }

    /// 把照片加入相册（一次事务）。返回真正新增的成员数。
    ///
    /// 加完 `reload()`：正在看这个相册时，新成员必须立刻出现在网格里；不在看的时候这次 reload
    /// 也只是把左栏的数字改对。**不写 develop、不进历史。**
    @discardableResult
    public func addPhotos(_ ids: [String], toAlbum albumId: String) throws -> Int {
        guard let catalog else { throw AlbumError.noLibrary }
        let added = try catalog.addAssets(ids, toAlbum: albumId)
        try refreshAlbums()
        if added > 0 { reload() } else { albumRevision += 1 }
        return added
    }

    @discardableResult
    public func removePhotos(_ ids: [String], fromAlbum albumId: String) throws -> Int {
        guard let catalog else { throw AlbumError.noLibrary }
        let removed = try catalog.removeAssets(ids, fromAlbum: albumId)
        try refreshAlbums()
        if removed > 0 { reload() } else { albumRevision += 1 }
        return removed
    }

    /// 把当前选中（或锚点）的照片加入 / 移出相册 —— 菜单动作的落点。
    @discardableResult
    public func addSelection(toAlbum albumId: String) throws -> Int {
        try addPhotos(metadataTargetIDs, toAlbum: albumId)
    }

    @discardableResult
    public func removeSelection(fromAlbum albumId: String) throws -> Int {
        try removePhotos(metadataTargetIDs, fromAlbum: albumId)
    }

    /// 这些照片各自在哪些相册里 —— 右键菜单的「移出相册」用它决定列出谁。
    public func albumMemberships(of ids: [String]) -> [String: [String]] {
        guard let catalog else { return [:] }
        return (try? catalog.albumMemberships(assetIDs: ids)) ?? [:]
    }

    public func albumAssetIDs(_ albumId: String) -> [String] {
        guard let catalog else { return [] }
        return (try? catalog.albumAssetIDs(albumId)) ?? []
    }

    private func refreshAlbums() throws {
        guard let catalog else { return }
        albums = try catalog.albums()
        albumRevision += 1
    }

    public var anchorIndex: Int? {
        guard let id = anchorID else { return nil }
        return assets.firstIndex { $0.id == id }
    }

    public var anchorAsset: Asset? {
        guard let i = anchorIndex else { return nil }
        return assets[i]
    }

    /// The selection in library order — menus, filmstrip scrolling and "open" all want this.
    public var selectedAssets: [Asset] {
        assets.filter { selection.contains($0.id) }
    }

    /// Which photo a document edit applies to, given the selection and the grid's current order.
    ///
    /// 「当前顺序」 is the order the grid and filmstrip are actually drawing (`assets`, already sorted
    /// by `sortOrder`), not the order the user clicked the photos in and not the anchor. The answer
    /// is the **first selected photo in that order**; an empty selection — or a selection whose ids
    /// have all disappeared from the library — has no target and therefore writes nothing.
    ///
    /// Pure on purpose: the edit path and its tests both read this one function, so "多选时改的是
    /// 当前顺序第一张" cannot drift into "改的是锚点" in one place and not the other.
    public static func editTarget(selection: [String], order: [String]) -> String? {
        guard !selection.isEmpty else { return nil }
        let selected = Set(selection)
        return order.first { selected.contains($0) }
    }

    /// `editTarget` asked against *this* session's live selection and order.
    public var currentEditTargetID: String? {
        Self.editTarget(selection: Array(selection), order: assets.map(\.id))
    }

    /// Instance spelling, for callers that already hold the session.
    public func editTarget(selection: [String], order: [String]) -> String? {
        Self.editTarget(selection: selection, order: order)
    }

    public func setSelection(_ ids: Set<String>, anchor: String? = nil) {
        selection = ids
        if let anchor {
            anchorID = anchor
        } else if let current = anchorID, ids.contains(current) {
            // keep the anchor
        } else {
            anchorID = ids.isEmpty ? nil : assets.last(where: { ids.contains($0.id) })?.id
        }
        // A programmatic selection that dropped the base no longer has a range to extend.
        if let base = selectionBase, !ids.contains(base) { selectionBase = nil }
        if let focus = rangeFocus, !ids.contains(focus) { rangeFocus = nil }
        loadEditForAnchor()
    }

    /// A plain click / non-⇧ keyboard landing: this photo is the selection, the anchor **and** the
    /// range base, so the next ⇧ click starts here.
    public func selectOnly(_ id: String) {
        selection = [id]
        anchorID = id
        selectionBase = id
        rangeFocus = id
        loadEditForAnchor()
    }

    /// Grid/filmstrip click with modifiers already resolved by the control.
    ///
    /// ⌘ adds/removes one photo. Adding makes it the anchor and the new range base (the next ⇧
    /// starts from what the user just picked); removing a non-anchor leaves both where they were,
    /// and removing the anchor hands the anchor back to the range base (or, with no base left, to
    /// the last remaining photo in display order).
    public func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
            if selectionBase == id {
                selectionBase = anchorID.flatMap { selection.contains($0) ? $0 : nil }
            }
            if anchorID == id {
                if let base = selectionBase, selection.contains(base) {
                    anchorID = base
                } else {
                    // 2026-11-11 主线修：锚被 ⌘ 关掉时，范围基点跟着落到新锚上，而不是变 nil ——
                    // 否则用户紧接着按 ⇧ 会退化成「只选一张再重建基点」，白丢一次范围手势。
                    anchorID = selection.isEmpty
                        ? nil : assets.last(where: { selection.contains($0.id) })?.id
                    selectionBase = anchorID
                }
            }
            if rangeFocus == id { rangeFocus = anchorID }
        } else {
            selection.insert(id)
            anchorID = id
            selectionBase = id
            rangeFocus = id
        }
        loadEditForAnchor()
    }

    /// ⇧ click: select the **closed range in display order** (`assets`, not id order) between the
    /// range base and `id`, replacing the current selection. `adding` is ⇧⌘ (union instead of
    /// replace). The anchor and the base do not move — that is the whole point of the gesture.
    public func selectRange(to id: String, adding: Bool = false) {
        guard let base = selectionBase else {
            // No base yet (first ⇧ after a programmatic selection): a plain selection is the only
            // honest answer, and it establishes the base.
            selectOnly(id)
            return
        }
        guard let baseIndex = assets.firstIndex(where: { $0.id == base }),
              let targetIndex = assets.firstIndex(where: { $0.id == id }) else {
            selectOnly(id)
            return
        }
        let lo = min(baseIndex, targetIndex)
        let hi = max(baseIndex, targetIndex)
        let range = Set(assets[lo ... hi].map(\.id))
        selection = adding ? selection.union(range) : range
        rangeFocus = id
        loadEditForAnchor()
    }

    /// Arrow/Home/End/Page navigation. Without ⇧ the landing photo becomes the anchor and the
    /// base; with ⇧ the **cursor** moves from the previous range end, the range is recomputed from
    /// the unchanged base, and the anchor stays put (thick ring stays on the original photo).
    @discardableResult
    public func moveAnchor(by delta: Int, extend: Bool = false) -> Bool {
        guard !assets.isEmpty else { return false }
        if extend {
            let base = selectionBase ?? anchorID ?? assets.first?.id
            guard let base, assets.contains(where: { $0.id == base }),
                  let cursorID = rangeFocus ?? anchorID,
                  let cursor = assets.firstIndex(where: { $0.id == cursorID }) else { return false }
            let target = min(max(0, cursor + delta), assets.count - 1)
            guard target != cursor else { return false }
            selectionBase = base
            rangeFocus = assets[target].id
            selectRange(to: assets[target].id)
            return true
        }
        let current = anchorIndex ?? 0
        let target = min(max(0, current + delta), assets.count - 1)
        guard target != current || anchorID == nil else { return false }
        selectOnly(assets[target].id)
        return true
    }

    /// Double-click / Return: open the photo in the loupe.
    public func activate(_ id: String) {
        selectOnly(id)
        mode = .loupe
    }

    public func showGrid() {
        mode = .grid
    }

    // MARK: rating / flag / colour label (catalog metadata, never an edit)

    /// 0–5 stars on the whole selection. One transaction for the selection, because the shortcut
    /// runs per keystroke and a 10k-row selection must not become 10k writes.
    @discardableResult
    public func setRatingForSelection(_ rating: Int) -> Bool {
        let value = max(0, min(5, rating))
        return writeMetadata({ catalog, ids in try catalog.setRating(value, forAssets: ids) },
                             apply: { $0.rating = value })
    }

    /// P / X / U. `nil` clears the flag.
    @discardableResult
    public func setFlagForSelection(_ flag: String?) -> Bool {
        let value = AssetFlag.normalized(flag)?.rawValue
        return writeMetadata({ catalog, ids in try catalog.setFlag(value, forAssets: ids) },
                             apply: { $0.flag = value })
    }

    /// ⌥1–⌥6. `nil` clears the label.
    @discardableResult
    public func setColorLabelForSelection(_ label: String?) -> Bool {
        let value = ColorLabel.normalized(label)?.rawValue
        return writeMetadata({ catalog, ids in try catalog.setColorLabel(value, forAssets: ids) },
                             apply: { $0.colorLabel = value })
    }

    /// The one path a metadata write takes.
    ///
    /// Nothing here commits history or calls `persist()`: `develop_json`, `asset_history` and
    /// `editRevision` are untouched by construction, which is what makes "a rating is not an edit"
    /// an invariant rather than a promise. With a filter on, membership can change (a photo rated 2
    /// leaves "≥3"), so the query is re-run instead of patching rows in place.
    @discardableResult
    private func writeMetadata(_ write: (Catalog, [String]) throws -> Int,
                               apply: (inout Asset) -> Void) -> Bool {
        guard let catalog else { return false }
        let ids = metadataTargetIDs
        guard !ids.isEmpty else { return false }
        do {
            let affected = try write(catalog, ids)
            metadataWriteCount += 1
            lastMetadataAffectedRows = affected
            metadataRevision &+= 1
            lastPersistError = nil
            if filter.isActive {
                reload()
            } else {
                let touched = Set(ids)
                var next = assets
                for i in next.indices where touched.contains(next[i].id) { apply(&next[i]) }
                assets = next
            }
            return true
        } catch {
            lastPersistError = "\(error)"
            return false
        }
    }

    // MARK: filter

    /// Narrow (or widen) the grid. Re-runs the catalog query; the selection is intersected with
    /// what is left, exactly like a source change. Never touches the document or history.
    ///
    /// This is also the **only** place the filter is remembered (043): the bar, a chip's ×, a
    /// shortcut and the restore in `open` all arrive here, so what is stored is always what the user
    /// sees — there is no restore-only path that could drift from the click path.
    public func applyFilter(_ next: CatalogFilter) {
        guard next != filter else { return }
        filter = next
        reload()
        rememberFilter()
    }

    public func clearFilter() {
        applyFilter(.none)
        // 「清除全部」 means "start from the defaults next time too": that library's archive goes,
        // and every other library keeps its own (043 §4). `.none` is deliberately *not* written as an
        // archive — the default bar is the absence of one.
        if let path = filterPersistencePath { filterPersistence.forget(libraryPath: path) }
    }

    /// Write a pending filter archive right now. The app calls this on termination; a test calls it
    /// instead of waiting out the 0.5 s throttle.
    public func flushPendingFilterSave() {
        filterPersistence.flush()
    }

    private func rememberFilter() {
        guard let path = filterPersistencePath else { return }
        // A bar with nothing ticked constrains nothing: its archive is *absence*, not a blob of empty
        // slots. Dropping it is what makes "I un-ticked everything" survive a restart — writing
        // nothing here would leave yesterday's narrower archive to be restored over the user's own
        // clearing, which is the one way this feature could contradict the screen.
        guard filter.slots.contains(where: { !$0.isEmpty }) else {
            filterPersistence.forget(libraryPath: path)
            return
        }
        filterPersistence.remember(filter, libraryPath: path)
    }

    /// Drop one facet from the active filter.
    ///
    /// 050: the bar no longer draws removable chips, so nothing in the UI calls this — the same removal
    /// now happens by unticking the value in the slot's own checklist. Kept because the filter value is
    /// still a value: a facet can be dropped from a preset, a CLI or a test without going through a
    /// button that no longer exists.
    public func clearFilter(_ facet: CatalogFilter.Facet) {
        applyFilter(filter.without(facet))
    }

    /// Drop **one value** from one slot — what a chip's × does (026 v2). The slot stays, because a
    /// slot is the dimension the user is looking at, not a condition.
    public func removeSlotValue(at slot: Int, value: String) {
        applyFilter(filter.removingValue(value, atSlot: slot))
    }

    /// The values a slot's popup offers for `dimension`, scoped to the rest of the filter.
    ///
    /// Asked per dimension while the bar rebuilds; the catalog answers from this library only, so a
    /// dimension with nothing in it yields `[]` and the popup says 「本库无此数据」 instead of inventing
    /// a ladder of ISO values.
    public func facetValues(_ dimension: FilterDimension) -> [String] {
        guard let c = catalog else { return [] }
        let albumScope = selectedAlbumID.map { [$0] } ?? []
        return c.facetValues(dimension, filter: filter.assetFilter(limit: 200_000,
                                                                  folders: selectedFolders,
                                                                  albumIds: albumScope))
    }

    // MARK: documents

    /// The one way a slider (or a test) moves the document.
    ///
    /// Bumps `editRevision` only when the value actually changed, so an idle drag calls the
    /// renderer zero times instead of once per mouse move.
    ///
    /// A real write while the **grid** is on screen is also the moment the workspace enters the
    /// loupe (派单 119): the target is `editTarget(selection:order:)`, not necessarily the anchor, so
    /// a multi-selection is adjusted on its first photo in the current order. Pressing a slider
    /// without changing a value is not an edit and does not switch; entering happens on the first
    /// tick that writes, and the following ticks of the same drag continue in the loupe.
    public func applyEdit(_ mutate: (inout EditModel) -> Void) {
        if mode == .grid, catalog != nil {
            applyEditFromGrid(mutate)
            return
        }
        applyEditInPlace(mutate)
    }

    /// The grid half of `applyEdit`: choose the target, write that photo's document, and switch.
    ///
    /// The target's document is read from the catalog **before** the switch so the mutation is
    /// applied exactly once (a closure may append a mask or generate an id; calling it twice to
    /// "test the water" would be a different edit). Nothing is written when the selection is empty
    /// or the mutation is a no-op.
    private func applyEditFromGrid(_ mutate: (inout EditModel) -> Void) {
        guard let target = currentEditTargetID else { return }
        let base: EditModel
        if target == loadedEditAssetID {
            base = edit
        } else if let catalog, let stored = try? catalog.develop(forAsset: target) {
            base = MaskViewState.documentOnly(stored)
        } else {
            base = .neutral
        }
        var next = base
        mutate(&next)
        guard !EditHistory.isSemanticallyIdentical(base, next) else { return }

        // 多选时改的是「当前顺序第一张」：切进单图后选集收成这一张，锚点同步成它。文档加载发生
        // 在写入之前，所以 `edit` / `history` / `loadedEditAssetID` 从第一帧起就是同一张照片的。
        if selection != [target] || anchorID != target || loadedEditAssetID != target {
            selectOnly(target)
        }
        mode = .loupe
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: target)
    }

    /// The old `applyEdit` body, also used by commands whose target is already the loaded anchor
    /// (paste settings, presets): those are not grid adjustments and must not be retargeted.
    private func applyEditInPlace(_ mutate: (inout EditModel) -> Void) {
        var next = edit
        mutate(&next)
        guard !EditHistory.isSemanticallyIdentical(edit, next) else { return }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: editedAssetID)
    }

    /// Publish a change that is **not** a document edit — today that is only `showMaskID`.
    ///
    /// `applyEdit` cannot carry it: it short-circuits on "semantically identical", which is exactly
    /// the property that keeps the overlay out of history. This door bumps the revision (so the
    /// loupe re-encodes the last pass) and touches nothing else — no snapshot, no `persist()`.
    func publishViewState(_ mutate: (inout EditModel) -> Void) {
        var next = edit
        mutate(&next)
        guard next.showMaskID != edit.showMaskID else { return }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
    }

    /// Internal door for the mask extension in `MaskCanvasController.swift` (same module, and the
    /// selection is view state that only that file's API should move).
    func setSelectedMaskID(_ id: String?) {
        selectedMaskID = id
    }

    /// End of one edit action (a slider release, a toggle, a menu command): push a snapshot and
    /// write it to the catalog.
    ///
    /// `EditHistory.commit` is a no-op when nothing changed, so a click on a slider that did not
    /// move neither grows the stack nor truncates the redo branch (and then nothing is written).
    /// The snapshot is `MaskViewState.documentOnly(edit)`: the overlay is view state, so a snapshot
    /// that carried it would make ⌘Z look like it also toggled the mask display.
    /// - Parameter coalesce: `false` for a discrete command (077): 双击复位 / 换解码版本 / 预设 各自
    ///   是**一个动作**，不许折进它前面那次拖动里（详见 `EditHistory.commit`）。
    @discardableResult
    public func commitEdit(label: String = "", coalesce: Bool = true) -> Bool {
        let committed = history.commit(MaskViewState.documentOnly(edit), label: label,
                                       coalesce: coalesce) != nil
        if committed { persist() }
        return committed
    }

    /// ⌘Z. Restores a whole snapshot — never an inverse operation (§History).
    ///
    /// The snapshot is the *document*; the `showMask` overlay that was on screen is pasted back on
    /// top of it. Without that, undoing any edit would silently switch the mask display off (the
    /// snapshot was taken before the overlay was turned on, and `showMaskID` is not an edit), which
    /// is exactly the failure this paste-back prevents.
    @discardableResult
    public func undo() -> Bool {
        // 356 — ⌘Z is a command, not a gesture: a session a gesture left open would be closed *after*
        // the undo and commit `base → edit`, resurrecting the state ⌘Z had just stepped away from.
        // Closing first is a no-op when nothing is open, so the door is the same either way.
        endToolSession()
        guard let model = history.undo() else { return false }
        restore(model)
        persist()
        return true
    }

    // MARK: history panel (077)

    /// Click a row: move the cursor there and show it. **Not** an edit.
    ///
    /// `EditHistory.jump(to:)` only moves the cursor (no snapshot, nothing truncated), so this is one
    /// render and one write of `history_end`; the redo branch survives, and the *next* edit is what
    /// truncates it — which is the user's 「如果继续操作了，恢复点后面的操作就没了」.
    @discardableResult
    public func jumpToHistory(seq: Int) -> Bool {
        guard let index = history.index(of: seq), index != history.cursor else { return false }
        guard let model = history.jump(to: seq) else { return false }
        restore(model)
        persist()
        return true
    }

    /// Delete one row of the timeline — 「可直接删除某个操作，其他不动」.
    ///
    /// Only the newest row of its class can go (`EditHistory.deletable(at:)`); the rule lives in the
    /// model so the panel's button and the model cannot disagree. Deleting **creates no snapshot**:
    /// it removes one, and the document moves only when the row the cursor stood on is the one
    /// removed (then the previous row's state is shown, one render).
    @discardableResult
    public func deleteHistoryEntry(at index: Int) -> Bool {
        let seqBefore = history.currentSeq
        guard history.delete(at: index) else { return false }
        if history.currentSeq != seqBefore, let model = history.current { restore(model) }
        persist()
        return true
    }

    /// 263: 撤销 one 「最新」 row — append a normal 「撤销 xxx」 snapshot that puts that row's fields
    /// back to their previous values, then write it once.
    ///
    /// Unlike `deleteHistoryEntry`, this always moves the document (the reverted snapshot is the new
    /// tip), so `restore` is unconditional: the append itself is the "the current document changed"
    /// signal. Returns false when the row cannot be reverted.
    @discardableResult
    public func revertHistoryEntry(at index: Int) -> Bool {
        guard let snapshot = history.revert(at: index) else { return false }
        restore(snapshot.edit)
        persist()
        return true
    }

    /// Rows for the panel: seq, label, the field-level summary, the time, and the two flags.
    public var historyRows: [HistoryRow] { history.rows }

    /// Begin a tool session (077): from here to `endToolSession` the history records **nothing**, so
    /// a crop/rotate gesture is one row however many handle positions it went through.
    public func beginToolSession(_ tool: String, label: String? = nil) {
        history.beginSession(tool, label: label)
    }

    /// 356 — **a slider drag is a gesture: these are its two ends.**
    ///
    /// Press: close anything a previous gesture left open (a leak must not swallow this gesture's
    /// row), then open this one's. Release: close it — one row, `base → edit` — or, when the slider
    /// was driven without a press at all (a test, a preset, a reset), commit the same one row.
    ///
    /// The pair exists so a panel never asks the history whether a session is open: the two calls are
    /// the same whatever it contains, which is what makes a slider's row — and therefore what ⌘Z
    /// gives back — independent of it.
    public func beginToolGesture(tool: String, label: String) {
        endToolSession()                        // no-op when nothing is open
        history.beginSession(tool, label: label)
    }

    @discardableResult
    public func endToolGesture(label: String, coalesce: Bool = true) -> Bool {
        if endToolSession(label: label) { return true }
        return commitEdit(label: label, coalesce: coalesce)
    }

    /// Is a tool session open?
    ///
    /// 356 — **only a gesture may make this true**, and no geometry judgement may read it. The crop
    /// tool asks nothing of it any more: `CropToolController` opens one on mouse-down and closes it on
    /// mouse-up, and closes any leftover before a command writes. It survives as the one question a
    /// *test* can ask ("is a session still open?") and nothing in the geometry paths branches on it.
    public var isToolSessionActive: Bool { history.isSessionActive }

    /// 应用: close the session with exactly one snapshot (`base → edit`), or none if nothing moved.
    @discardableResult
    public func endToolSession(label: String? = nil) -> Bool {
        let committed = history.endSession(MaskViewState.documentOnly(edit), label: label) != nil
        if committed { persist() }
        return committed
    }

    /// 取消: close the session with zero snapshots.
    ///
    /// The document goes back to where the tool started — normally a no-op (a draft tool never writes
    /// the document), but a control that *does* write inside a session (裁切 bar's flips) must not
    /// survive a cancel with no history row to undo it. One render, no snapshot.
    public func cancelToolSession() {
        let base = history.activeSession?.base
        history.cancelSession()
        guard let base, !EditHistory.isSemanticallyIdentical(edit, base) else { return }
        edit = MaskViewState.restoring(base, keeping: edit.showMaskID)
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: editedAssetID)
    }

    /// 356 — **the one writer for a command that changes the transform geometry** (双击「垂直透视」,
    /// a section reset, the card's title). A command is not a gesture, so it closes whatever a gesture
    /// left open — that close records the crop-so-far, which 应用 would have written anyway — then
    /// writes the document and commits **one** row.
    ///
    /// The three steps are the same whether or not a session was open, which is the whole point: the
    /// old shape ended-and-reopened a session only if there was one, so the same double-click left one
    /// row or none depending on what the history happened to contain, and the next ⌘Z therefore put a
    /// different document back.
    @discardableResult
    public func commitGeometryCommand(label: String,
                                      _ mutate: (inout GeometryGroup) -> Bool) -> Bool {
        endToolSession()                       // no-op when no gesture is running
        var changed = false
        applyEdit { model in changed = mutate(&model.geometry) }
        guard changed else { return false }
        return commitEdit(label: label, coalesce: false)
    }

    /// ⇧⌘Z.
    @discardableResult
    public func redo() -> Bool {
        endToolSession()            // 356 — same rule as `undo()`: a command closes the gesture's session
        guard let model = history.redo() else { return false }
        restore(model)
        persist()
        return true
    }

    /// Show a snapshot on screen: its document, plus the overlay that is currently on (view state).
    private func restore(_ model: EditModel) {
        edit = MaskViewState.restoring(model, keeping: edit.showMaskID)
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        // 165: ⌘Z / ⇧⌘Z / a history-row jump replaces the whole snapshot — the same "the user is
        // looking at the result, there was no pointer entry" case as a paste. The open photo's
        // backdrop must follow at once instead of waiting for the pointer to leave and come back.
        if let id = loadedEditAssetID ?? anchorAsset?.id {
            invalidateBackdrops(for: [id])
        }
        notifyEditObservers(assetID: editedAssetID)
    }

    /// Write the stack's current document to the catalog. One transaction, `saveDevelop`'s.
    ///
    /// Saving `history.current` rather than `edit` is deliberate: they are the same document except
    /// for the overlay, and the history is by construction the thing `DevelopError.historyInconsistent`
    /// checks a save against. A no-op commit therefore cannot throw "the blob disagrees with the
    /// cursor" just because a double moved by less than `EditHistory.dirtyTolerance`.
    private func persist() {
        guard let catalog, let id = loadedEditAssetID ?? anchorAsset?.id else { return }
        var stack = history
        if stack.isEmpty {
            // Nothing was ever written for this asset (or its rows were quarantined): seed the floor
            // with the live document so the edit about to land has something to undo back to.
            stack = EditHistory(baseline: MaskViewState.documentOnly(edit))
        }
        guard let document = stack.current else { return }
        do {
            let result = try catalog.saveDevelop(document, history: stack, forAsset: id)
            lastSaveResult = result
            lastPersistError = nil
            // 363 — the row goes first: `persistCount` is the signal that wakes all three browsers,
            // and a refresh that runs before the row is updated would derive the pre-edit key again.
            adoptCommittedDocument(document, save: result)
            persistCount += 1
        } catch {
            // A failed write is reported, never swallowed: the document is still on screen and
            // still undoable, and the next commit retries.
            lastPersistError = "\(error)"
        }
    }

    /// 363 — **the store and the row must not disagree.** `develop_json` in memory is what the three
    /// browsers derive a thumbnail key from for every photo that is not the loaded one, and what
    /// `reload()`/`catalog.develop(forAsset:)` would serve. It used to be written only to the
    /// database: the `Asset` in `assets` kept the **pre-edit** document until something re-read the
    /// library, so the next refresh of that photo's cell rebuilt the *old* key — the reported
    /// 「修改了 A，再修改 B，A 的预览又回退了」. Writing the committed document back into the row
    /// makes the key a consequence of the save instead of of a reload nobody performed.
    ///
    /// The bytes are `Catalog.encode`, i.e. the same canonical JSON the store just wrote, so a later
    /// decode yields the identical model (and therefore the identical `ThumbKey`).
    private func adoptCommittedDocument(_ document: EditModel, save: DevelopSaveResult) {
        guard let index = assets.firstIndex(where: { $0.id == save.assetId }) else { return }
        guard let json = try? Catalog.encode(document) else { return }
        guard assets[index].developJson != json
                || assets[index].developVersion != save.developVersion else { return }
        assets[index].developJson = json
        assets[index].developVersion = save.developVersion
        assets[index].editTime = save.editTime
        assets[index].historyEnd = save.historySeq
    }

    /// `force` re-reads the stored document (after an external save or a develop-json change).
    /// Without it, re-selecting the same photo keeps the live edit *and its history* — a selection
    /// change must not silently throw away the undo stack.
    ///
    /// The document comes from `Catalog.develop(forAsset:)` (D9: `develop_json` is the truth; a
    /// damaged blob is quarantined and reads as `.neutral`), and the stack from
    /// `Catalog.editHistory(forAsset:)` so ⌘Z survives a relaunch. A library that has no rows yet
    /// gets `EditHistory(baseline:)`, i.e. the floor is the document as it was opened.
    public func loadEditForAnchor(force: Bool = false) {
        guard let a = anchorAsset else {
            edit = .neutral
            history = EditHistory(baseline: .neutral)
            loadedEditAssetID = nil
            selectedMaskID = nil
            pendingMaskShape = nil
            recordHistogram(nil)
            return
        }
        if !force, loadedEditAssetID == a.id { return }
        var model: EditModel
        var stack: EditHistory?
        if let catalog {
            model = (try? catalog.develop(forAsset: a.id)) ?? .neutral
            stack = try? catalog.editHistory(forAsset: a.id)
        } else if let data = a.developJson.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(EditModel.self, from: data) {
            model = decoded
        } else {
            model = .neutral
        }
        // The overlay is view state: a stored document that carries one is stale by definition.
        model = MaskViewState.documentOnly(model)
        edit = model
        if let stack, !stack.isEmpty {
            history = stack
        } else {
            history = EditHistory(baseline: model)
        }
        loadedEditAssetID = a.id
        selectedMaskID = edit.masks.first?.id
        maskTool = .off
        // A document change retires the pending shape and the previous photo's histogram: both
        // describe the picture that is no longer on screen.
        pendingMaskShape = nil
        recordHistogram(nil)
    }

    /// 249 — convert a legacy (`canvasV1`) heal document to S1 source coordinates once the **exact**
    /// decoded frame is known. This is a schema migration, not an edit: it mints no history row, and
    /// it rewrites the stored document (the marker is the point of the version bump). The whole
    /// history is migrated with the live document so ⌘Z cannot bring a canvasV1 spot back.
    ///
    /// Returns `true` when anything moved.
    @discardableResult
    public func migrateHealSpots(sourceSize: ImageSize) -> Bool {
        var next = edit
        guard next.migrateHealSpots(sourceSize: sourceSize) else { return false }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        history.migrateHealSpots(sourceSize: sourceSize)
        notifyEditObservers(assetID: editedAssetID)
        persist()
        return true
    }

    /// 330 — convert a pre-330 crop (a rect of the **photograph**) to the equivalent rectangle of the
    /// **document canvas** once the exact frame is known. The sibling of `migrateHealSpots`: a schema
    /// migration, not an edit — no history row, and the stored document is rewritten (the marker is
    /// the point). A keystone-free document returns `false` and its bytes do not move.
    @discardableResult
    public func migrateCropToCanvasSpace(sourceSize: ImageSize) -> Bool {
        var next = edit
        guard next.migrateCropToCanvasSpace(sourceSize: sourceSize) else { return false }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        history.migrateCropToCanvasSpace(sourceSize: sourceSize)
        notifyEditObservers(assetID: editedAssetID)
        persist()
        return true
    }

    public func recordCapabilities(_ c: DecoderCapabilities) {
        // Equality-guarded: every presented frame reports the same facts, and an unconditional write
        // would re-render the SwiftUI inspector once per slider frame for no information.
        guard capabilities != c else { return }
        capabilities = c
    }

    // MARK: measured facts — the histogram and the clipping warning
    //
    // Neither of these is a document edit: `lastHistogram` is a *reading* of the frame the loupe
    // already rendered (handed over when that frame is presented, so there is never a second
    // render), and `highlightWarning` is a display preference. `editRevision`, `EditHistory` and
    // `develop_json` are untouched by both — which is exactly what `--ui-smoke` asserts when it
    // toggles the warning and compares the document hash.

    /// The last frame's histogram, or nil before the first frame. Read by the inspector card.
    public private(set) var lastHistogram: Histogram?

    /// Paint clipped pixels magenta on the canvas. A toggle, not an edit.
    public private(set) var highlightWarning = false

    /// Bumped whenever the warning is switched, so the loupe (an AppKit observer of this object)
    /// has something cheap to watch that is not `editRevision`.
    public private(set) var highlightWarningRevision = 0

    /// The loupe hands over what its frame measured. Equality-guarded: a frame that measured the
    /// same distribution must not re-render the inspector.
    public func recordHistogram(_ h: Histogram?) {
        guard h != lastHistogram else { return }
        lastHistogram = h
    }

    public func setHighlightWarning(_ on: Bool) {
        guard on != highlightWarning else { return }
        highlightWarning = on
        highlightWarningRevision &+= 1
    }

    public func toggleHighlightWarning() {
        setHighlightWarning(!highlightWarning)
    }

    // MARK: presets (M5)
    //
    // A preset is a named *subset* of the document (`Preset` in PhotonsCore) stored in
    // `presets.develop_json`. `Presets.swift` owns the storage rules; the session's job is to keep
    // the live `edit`/`history` and the database in step:
    //
    //   · applying merges through `Preset.apply(to:)` — only the preset's groups move, masks and
    //     `showMaskID` stay the target's own — then commits **once**, so ⌘Z takes the whole preset
    //     back in one press (the same granularity as paste settings);
    //   · that commit is an ordinary `EditHistory.commit`, so the pixels, the blob and the undo
    //     label travel the path a slider does: a preset is not a special kind of edit;
    //   · the list is cached here (`presetRecords`) and rebuilt after every write, because the
    //     inspector card, the menu and the CLI-facing name lookups all draw from it.

    public private(set) var presetRecords: [PresetRecord] = []
    /// Bumped on every refresh — the panel observes this, not the array.
    public private(set) var presetsRevision = 0
    public private(set) var lastPresetError: String?

    public var defaultPresetName: String? { presetRecords.first(where: { $0.isDefault })?.name }

    public func reloadPresets() {
        guard let catalog else {
            presetRecords = []
            presetsRevision &+= 1
            return
        }
        do {
            presetRecords = try catalog.presetRecords()
            lastPresetError = nil
        } catch {
            presetRecords = []
            lastPresetError = error.localizedDescription
        }
        presetsRevision &+= 1
    }

    /// Apply a preset to the anchor photo as **one** undo step.
    @discardableResult
    public func applyPreset(named name: String) -> Bool {
        guard let catalog, anchorAsset != nil else {
            lastPresetError = "先打开库并选中一张照片"
            return false
        }
        do {
            let record = try catalog.requirePreset(named: name)
            let merged = record.preset.apply(to: edit)
            guard !EditHistory.isSemanticallyIdentical(edit, merged) else {
                // Nothing to change is not an error — `commitEdit` would be a no-op too, and a
                // preset that is already applied must not grow the undo stack.
                lastPresetError = nil
                return false
            }
            // 356 — a preset is a command: close a gesture's session first, or `commitEdit` answers
            // `nil` and the preset moves the document with no row (⌘Z then cannot take it back).
            endToolSession()
            applyEditInPlace { $0 = merged }
            let committed = commitEdit(label: "预设 \(record.name)")
            lastPresetError = committed ? nil : "预设没有落地"
            return committed
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    /// Capture the anchor's document (minus the overlay, minus masks) as a new preset.
    ///
    /// `groups` defaults to every group, which is what "从当前照片新建" means: the whole look. The
    /// fragment is projected onto those groups by `Preset.init(name:from:groups:)`, so the stored
    /// preset can only carry what it claims to.
    @discardableResult
    public func createPresetFromCurrent(named name: String,
                                        groups: Set<PresetGroup> = Set(PresetGroup.allCases),
                                        sections: Set<EditSnapshotSection>? = nil)
        -> PresetRecord? {
        guard let catalog else {
            lastPresetError = "未打开库"
            return nil
        }
        guard anchorAsset != nil else {
            lastPresetError = "未选择照片"
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastPresetError = "预设需要一个名字"
            return nil
        }
        do {
            // 081 §4: a preset saved from the copy sheet carries **the cards that were checked**, and
            // nothing else — the fragment is those cards' current values over a neutral document, so
            // a later apply moves those leaves and only those. `groups` is the old door (「从当前照片
            // 新建预设」, the whole look).
            let preset: Preset = if let sections, !sections.isEmpty {
                Preset(name: trimmed, fromSections: sections, of: MaskViewState.documentOnly(edit))
            } else {
                Preset(name: trimmed, from: MaskViewState.documentOnly(edit), groups: groups)
            }
            let record = try catalog.savePreset(preset)
            lastPresetError = nil
            reloadPresets()
            return record
        } catch {
            lastPresetError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func deletePreset(named name: String) -> Bool {
        guard let catalog else { return false }
        do {
            let removed = try catalog.deletePreset(named: name)
            lastPresetError = removed ? nil : "没有名为“\(name)”的预设"
            reloadPresets()
            return removed
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func setDefaultPreset(named name: String?) -> Bool {
        guard let catalog else { return false }
        do {
            _ = try catalog.setDefaultPreset(named: name)
            lastPresetError = nil
            reloadPresets()
            return true
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    // MARK: settings clipboard — 复制/粘贴设置 (078 P0-7)
    //
    // ⌘C/⌘V for *settings*, which is a different verb from copying the document:
    //
    //   · the payload is `EditSnapshot` — **sparse** (non-default leaves only, Q18) and narrowed by
    //     the checklist (`CopySettingsSelection`). A paste therefore writes only what the user
    //     checked *and* only what the source actually changed; the destination's own white balance,
    //     crop, colour and masks survive a paste that does not name them.
    //   · it lives in this object, **not** on `NSPasteboard`. Develop settings are not text: putting
    //     them on the system pasteboard would make ⌘V into an image editor a `photons.*` blob, and
    //     would let a copied screenshot be "pasted" as settings. The menu item is ⌘C/⌘V and the
    //     focus rule (a text field keeps the system clipboard) lives in the window controller.
    //   · a paste is **one history row per photo** (`commitEdit(coalesce: false)` / `appendDevelop`),
    //     so one ⌘Z takes the whole paste back — however many groups it carried.
    //   · only a white balance paste re-develops (`EditSnapshotSection.requiresDecode`); tone, curve,
    //     colour, crop and masks are GPU-stage changes and `detail` is stored-not-rendered.

    /// What ⌘C captured (already narrowed). `nil` before the first copy.
    public private(set) var copiedSettings: EditSnapshot?
    /// Which photo it came from — the menu/paste messages name it, and the anchor's own paste goes
    /// through the live document only when this is the photo on screen.
    public private(set) var copiedSettingsSourceID: String?

    /// The checklist ⌘C uses. Lives here so the dialog's last answer is what the next ⌘C copies
    /// (Lightroom's behaviour: the Copy Settings checklist is sticky).
    public var copySelection = CopySettingsSelection.all

    /// Bumped after every copy/paste, for the status line and the menu titles.
    public private(set) var settingsRevision = 0
    /// Why the last copy/paste did nothing, or nil.
    public private(set) var lastSettingsError: String?
    /// The reports of the last paste, one per target photo.
    public private(set) var lastPasteReports: [SettingsPasteReport] = []

    // MARK: backdrop invalidation (165)
    //
    // `editRevision` says "the document moved" and the loupe answers with a new sharp frame. That is
    // not enough for the low-resolution whole picture: an ordinary edit deliberately only *marks* the
    // backdrop stale (039), and only a photo switch or a pointer entry into the canvas rebuilds it.
    // ⌘V and ⌘Z are not ordinary edits — the user is already looking at their result, and neither
    // command involves a pointer entry. These two properties are the command-scoped signal the loupe
    // observes, so it can rebuild **the photo that changed** immediately without turning every slider
    // tick into a backdrop render.
    //
    // A paste onto other photos writes their `develop_json` directly (no editor, no frame); the ids
    // are still reported so the scope is explicit and a future photo-keyed cache has one place to be
    // cleared. The loupe holds only the open photo's texture, so those ids cost no request.
    /// Bumped by a command that moved a document outside the frame/pointer path (paste, history).
    public private(set) var backdropInvalidationRevision = 0
    /// The photos the last such command touched. The loupe acts only when the photo on screen is in it.
    public private(set) var backdropInvalidationAssetIDs: Set<String> = []

    private func invalidateBackdrops(for assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        backdropInvalidationAssetIDs = assetIDs
        backdropInvalidationRevision &+= 1
    }

    public var canCopySettings: Bool { anchorAsset != nil }

    public var canPasteSettings: Bool {
        guard let payload = copiedSettings, !payload.isEmpty else { return false }
        return !metadataTargetIDs.isEmpty
    }

    /// ⌘C — capture the anchor's non-default leaves, narrowed by `selection` (default: the sticky
    /// checklist).
    @discardableResult
    public func copySettingsFromAnchor(selection: CopySettingsSelection? = nil) -> EditSnapshot? {
        guard let asset = anchorAsset else {
            lastSettingsError = "先选中一张照片"
            return nil
        }
        let choice = selection ?? copySelection
        let document = asset.id == loadedEditAssetID
            ? MaskViewState.documentOnly(edit)
            : (catalog.flatMap { try? $0.develop(forAsset: asset.id) } ?? .neutral)
        // P1-5: masks travel with the aspect ratio of the frame they were measured in, so the paste
        // side can re-anchor them. This is the one place that knows it (the document does not store
        // its own pixel size).
        let payload = EditSnapshot.capture(document, frameAspect: frameAspect(of: asset.id))
            .filtered(to: choice)
        copiedSettings = payload
        copiedSettingsSourceID = asset.id
        copySelection = choice
        // 081 §3: every 复制 writes the checklist once, into **this** library's `settings` row. Failure
        // is silent on purpose — a read-only library must still be able to copy settings, and the
        // selection then simply comes back as 全部 next time.
        if let catalog { try? catalog.storeCopySelection(choice) }
        lastSettingsError = payload.isEmpty
            ? "这张照片在所选组里没有非默认设置：粘贴不会改动任何字段"
            : nil
        settingsRevision &+= 1
        return payload
    }

    /// ⌘V — paste into the selection (or the anchor when nothing is selected).
    ///
    /// `sections` narrows the payload further at paste time (the 「粘贴设置（选择…）」 row); `nil`
    /// keeps what ⌘C already narrowed. `ids` exists for the tests and for a future Sync command; the
    /// menu passes neither.
    @discardableResult
    public func pasteSettings(sections: Set<EditSnapshotSection>? = nil,
                              into ids: [String]? = nil) -> [SettingsPasteReport] {
        let narrowed = sections.flatMap { checked in copiedSettings.map { $0.filtered(to: checked) } }
        return pasteSettings(narrowed: narrowed, into: ids)
    }

    /// ⇧⌘V — narrow the payload by **the sheet's whole answer**, cards *and* parameter rows, so the
    /// paste writes exactly what the checkboxes said (081 §2/§3).
    @discardableResult
    public func pasteSettings(selection: CopySettingsSelection,
                              into ids: [String]? = nil) -> [SettingsPasteReport] {
        let narrowed = copiedSettings.map { $0.filtered(to: selection) }
        return pasteSettings(narrowed: narrowed, into: ids)
    }

    private func pasteSettings(narrowed: EditSnapshot?, into ids: [String]?) -> [SettingsPasteReport] {
        let targets = ids ?? metadataTargetIDs
        lastPasteReports = []
        guard let copied = copiedSettings else {
            lastSettingsError = "剪贴板里没有设置：先按 ⌘C 复制"
            settingsRevision &+= 1
            return []
        }
        let payload = narrowed ?? copied
        guard !payload.isEmpty else {
            lastSettingsError = "所选组里没有可粘贴的设置"
            settingsRevision &+= 1
            return []
        }
        guard !targets.isEmpty else {
            lastSettingsError = "没有目标照片"
            settingsRevision &+= 1
            return []
        }

        var reports: [SettingsPasteReport] = []
        var failures: [String] = []
        // 165: the photos whose document this paste actually moved, for the backdrop signal below.
        var changedTargets: Set<String> = []
        for id in targets {
            if id == loadedEditAssetID {
                if let report = pasteIntoLiveDocument(payload) {
                    reports.append(report)
                    if report.changed { changedTargets.insert(id) }
                } else {
                    failures.append("当前照片在工具会话里：先应用或取消裁切/蒙版工具再粘贴")
                }
                continue
            }
            guard let catalog else { continue }
            do {
                let report = try catalog.pasteSettings(payload, intoAsset: id,
                                                       sections: Set(EditSnapshotSection.copyable),
                                                       label: "粘贴设置",
                                                       destinationAspect: frameAspect(of: id))
                reports.append(report)
                if report.changed { changedTargets.insert(id) }
            } catch {
                failures.append("\(id.prefix(8))：\(error.localizedDescription)")
            }
        }
        lastPasteReports = reports
        lastSettingsError = failures.isEmpty
            ? (reports.contains(where: \.changed) ? nil : "目标照片已经是这些值：没有改动")
            : failures.joined(separator: "；")
        // 165: a paste is a command, not a slider tick. Rebuild the open photo's bottom image now;
        // the other targets are only named, never rendered (their backdrops are made when opened).
        invalidateBackdrops(for: changedTargets)
        settingsRevision &+= 1
        return reports
    }

    /// The anchor's paste goes through the **live** document, so the pixels, the stack and the blob
    /// travel the same path a slider does — and so the undo row is the session's own.
    ///
    /// `commitEdit(coalesce: false)`: a paste is a discrete command, never the continuation of the
    /// drag that happened to precede it (EditHistory's merge rule is asked not to apply).
    /// The mask overlay (`showMaskID`) is pasted back on top because it is view state, exactly as
    /// `undo()` does.
    ///
    /// The perspective a mask paste has to be re-anchored in: `W/H` of the photo's **upright**
    /// source frame (P1-5).
    ///
    /// Three sources, in the order they can be trusted:
    ///   1. the frame the renderer actually ingested for *this* photo (`ingestedSourceFrame`) — the
    ///      exact numbers every mask on screen was normalised against, including EXIF orientation;
    ///   2. the catalog row's `width`/`height` — the *stored* dimensions, which are transposed for
    ///      EXIF 5…8, so for those files this answers the reciprocal ratio. That is a degradation,
    ///      not a wrong point: a reciprocal pair still meets an unknown aspect on the other side, and
    ///      the paste falls back to copying fractions rather than inventing a factor;
    ///   3. nothing (`nil`) — a paste copies the normalised coordinates as-is, which is what a
    ///      same-aspect copy would do anyway.
    func frameAspect(of assetID: String) -> Double? {
        if assetID == loadedEditAssetID, let frame = ingestedSourceFrame, frame.assetID == assetID {
            return Self.aspect(of: frame.size)
        }
        guard let row = assets.first(where: { $0.id == assetID }) else { return nil }
        return Self.aspect(width: row.width, height: row.height)
    }

    static func aspect(of size: ImageSize) -> Double? {
        aspect(width: size.width, height: size.height)
    }

    static func aspect(width: Int?, height: Int?) -> Double? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    /// The live-document half of ⌘V. (See `frameAspect(of:)` for the `destinationAspect` term.)
    private func pasteIntoLiveDocument(_ payload: EditSnapshot) -> SettingsPasteReport? {
        // 356 — a paste is a command, not a gesture: close whatever a gesture left open (its row is
        // the crop-so-far, which 应用 would have written anyway) instead of **refusing** the paste.
        // The old `guard !…isSessionActive else { return nil }` made ⌘V do nothing at all
        // whenever the history happened to hold a session — the user's 「只要历史里有东西…」.
        // `endToolSession` is a no-op when nothing is open, so the door is the same either way.
        endToolSession()
        let current = MaskViewState.documentOnly(edit)
        let merged = payload.applied(to: current,
                                     destinationAspect: frameAspect(of: loadedEditAssetID ?? ""))
        let fields = EditHistory.changedFields(between: current, and: merged)
        guard !fields.isEmpty else {
            return SettingsPasteReport(assetID: loadedEditAssetID ?? "",
                                       changed: false, fields: [], sections: payload.sections,
                                       requiresDecode: payload.requiresDecode, historyRows: nil)
        }
        applyEditInPlace { $0 = MaskViewState.restoring(merged, keeping: $0.showMaskID) }
        let committed = commitEdit(label: "粘贴设置", coalesce: false)
        return SettingsPasteReport(assetID: loadedEditAssetID ?? "", changed: committed,
                                   fields: fields, sections: payload.sections,
                                   requiresDecode: payload.requiresDecode,
                                   historyRows: committed ? history.count : nil)
    }

    // MARK: missing originals (a reference root's file moved on disk)

    // The library stores references, so the Finder can move a photo out from under a row. Nothing
    // here deletes anything without the user saying so: `refreshAvailability()` re-derives the flag,
    // `relinkMissing` puts a row back on its file, and `deleteAssets` is the other answer.
    //
    // All three are *library* facts, not document edits: `editRevision`, `editHistory` and
    // `develop_json` are untouched by a relink (the document belongs to the photo, and the photo is
    // the same photo — that is what the content hash check proves).

    /// What the last availability pass found (`nil` before the library was opened).
    public private(set) var lastAvailability: AvailabilityReport?

    /// Why the last relink/delete failed, or nil. Reported, never swallowed.
    public private(set) var lastAvailabilityError: String?

    /// Rows whose original file is not where the library says — what the badge and the menu read.
    public var missingAssets: [Asset] { assets.filter(\.isMissing) }

    /// The missing subset of the current selection, in library order. Both context-menu verbs act on
    /// exactly this list, so the count in the confirmation sheet is the count that gets deleted.
    public var missingSelectionIDs: [String] { selectedAssets.filter(\.isMissing).map(\.id) }

    /// Re-stat every row under an online root. Called on open and by the manual rescan action.
    @discardableResult
    public func refreshAvailability() -> AvailabilityReport? {
        guard let catalog else { return nil }
        let report = try? catalog.refreshAvailability()
        lastAvailability = report
        reload()
        return report
    }

    /// Remove entries **and their modification records**. The originals on disk are never touched.
    @discardableResult
    public func deleteAssets(_ ids: [String]) -> DeleteReport? {
        guard let catalog, !ids.isEmpty else { return nil }
        // Decide the successor from the order seen *before* the rows go away. The query afterwards
        // can only answer "what is first now", which is exactly the bug (back to the first photo).
        pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                removing: Set(ids),
                                                                anchor: anchorID)
        do {
            let report = try catalog.deleteAssets(ids: ids, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            // `reload()` and not a local splice: membership, the selection, the anchor and the stats
            // all change at once, and the query is the only thing that knows the new truth.
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Remove one folder subtree from the library — 「从照片库移除此文件夹…」 (379).
    ///
    /// Same order as `deleteAssets`: the anchor's successor is decided from the order the user saw
    /// **before** the rows go, then the transaction, then `reload()`. The folder selection that
    /// pointed into the removed subtree is pruned in the same breath — `reload()` would otherwise
    /// narrow the grid to a prefix no row carries any more while the left column has no row to click
    /// back from. Nothing on disk is touched (see `Catalog.removeFolder`).
    @discardableResult
    public func removeFolder(rootID: String, path: String) -> DeleteReport? {
        guard let catalog else { return nil }
        let folder = AssetFilter.normalizedFolderPath(path)
        let ids = (try? catalog.assetIDs(rootID: rootID, folderPath: path)) ?? []
        // 381: an empty id list is not a reason to stop. A root whose last photo went still has a
        // 0-count row in the left column, and only `reload()` below takes it out of the tree — a
        // `return nil` here would leave the menu verb doing nothing at all. There is simply no
        // anchor successor to compute when nothing the user saw is going away.
        if !ids.isEmpty {
            pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                    removing: Set(ids),
                                                                    anchor: anchorID)
        }
        do {
            let report = try catalog.removeFolder(rootID: rootID, path: path, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            // Drop the dead rows from the selection *before* the reload, so the query it runs is the
            // one the user will see. A selection that loses every row goes back to 全部照片 — which
            // is `selectedFolders == []`, the same state the 全部照片 row stores. Selections from
            // **other roots** are untouched: removing `rootA/day2` is not removing `rootB/x`.
            selectedFolders = Self.selectedFolders(selectedFolders, removing: rootID, folder: folder)
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Remove a whole source root from the library (root row → 「从照片库移除此文件夹…」).
    ///
    /// The photos go with it (FK cascade) and so does the root's row in the left column; the originals
    /// on disk stay. Selections naming that root are dropped — a root that no longer exists cannot be
    /// a filter.
    @discardableResult
    public func removeSourceRoot(id: String) -> DeleteReport? {
        guard let catalog else { return nil }
        // Every id under the root, not just the ones the current filter shows: the successor rule is
        // about the order the user saw, and the removal is about the whole root.
        let ids = (try? catalog.assetIDs(rootID: id, folderPath: "")) ?? []
        // 381: 0 张的根行照样要移（见 `removeFolder` 的同一理由）：`removeSourceRoot` 删的是
        // `source_roots` 那一行，没有照片可删不是错误。
        if !ids.isEmpty {
            pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                    removing: Set(ids),
                                                                    anchor: anchorID)
        }
        do {
            let report = try catalog.removeSourceRoot(id: id, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            selectedFolders = Self.selectedFolders(selectedFolders, removing: id, folder: nil)
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Keep the selections that do not point into the removed subtree. `removedPath` is the removed
    /// folder's canonical path; `nil` means **every photo of that root went** (the root row, or a
    /// folder removal with an empty path), so every selection of that root is dead.
    ///
    /// A sub-selection of the removed folder (`day2/sub` when `day2` went) is inside the subtree just
    /// as much as the folder itself, so the test is prefix-based and segment-safe — `day2x` is not
    /// `day2`. Selections naming a **different root** are neither, and stay. A selection of the root
    /// itself survives a *subfolder* removal: the root still holds its other photos. Pure, so the
    /// rule can be asserted without a library.
    static func selectedFolders(_ folders: [FolderSelection], removing rootID: String,
                                folder removedPath: String?) -> [FolderSelection] {
        folders.filter { folder in
            guard folder.rootId == rootID else { return true }
            guard let removedPath else { return false }
            guard let path = folder.normalizedPath else { return true }
            return path != removedPath && !path.hasPrefix(removedPath + "/")
        }
    }

    /// The count the confirmation sheet prints: one `COUNT(*)` over the folder subtree (or the root),
    /// never a full id read — a ten-thousand-photo folder must open its dialog instantly.
    public func folderAssetCount(rootID: String, path: String) -> Int {
        (try? catalog?.folderAssetCount(rootID: rootID, folderPath: path)) ?? 0
    }

    /// What 「移出并删除…」 did, in the user's terms.
    public struct RemovalOutcome: Sendable, Equatable {
        /// What the row transaction removed (table counts — the same shape `DeleteReport` always had).
        public var removed: DeleteReport?
        /// Originals that really went to the Trash (a file already gone is not counted).
        public var filesTrashed: Int
        /// Rows that stayed in the library because their original could not be recycled.
        public var keptIDs: [String]
        /// One human-readable reason per kept row.
        public var failures: [String]

        public init(removed: DeleteReport? = nil, filesTrashed: Int = 0,
                    keptIDs: [String] = [], failures: [String] = []) {
            self.removed = removed
            self.filesTrashed = filesTrashed
            self.keptIDs = keptIDs
            self.failures = failures
        }
    }

    /// The real recycle: `FileManager`'s Trash, so ⌘Z-less deletion is still undoable in the Finder.
    nonisolated public static func trashItem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Remove rows **and** recycle their originals. Per entry: recycle first, then delete the row, so
    /// a row is never gone while its file is still where the library said it was. A recycle failure
    /// keeps that row and does not stop the others.
    ///
    /// A file that is already absent on disk is just a row removal (nothing to recycle, not a failure).
    @discardableResult
    public func removeAssetsDeletingFiles(_ ids: [String],
                                          recycle: (URL) throws -> Void = CatalogSession.trashItem)
        -> RemovalOutcome {
        guard catalog != nil, !ids.isEmpty else { return RemovalOutcome() }
        var toDelete: [String] = []
        var filesTrashed = 0
        var keptIDs: [String] = []
        var failures: [String] = []
        for asset in assets where ids.contains(asset.id) {
            if let url = fileURL(for: asset), FileManager.default.fileExists(atPath: url.path) {
                do {
                    try recycle(url)
                    filesTrashed += 1
                } catch {
                    keptIDs.append(asset.id)
                    failures.append("\(asset.filename)：\(error.localizedDescription)")
                    continue
                }
            }
            toDelete.append(asset.id)
        }
        let report = deleteAssets(toDelete)
        if !toDelete.isEmpty, report == nil {
            failures.append("移出条目失败：\(lastAvailabilityError ?? "未知错误")")
        }
        return RemovalOutcome(removed: report, filesTrashed: filesTrashed,
                              keptIDs: keptIDs, failures: failures)
    }

    /// One 「查找丢失的文件…」 run: search `folder` by file name, then relink every hit whose content
    /// hash matches. Entries that are not found keep their flag — nothing is guessed.
    ///
    /// One search for the whole batch (`LostFileFinder.find` takes every target at once), because a
    /// recursive walk per photo would make a 40-photo relink 40 walks of the same folder.
    public func relinkMissing(_ ids: [String], in folder: URL) -> RelinkOutcome {
        guard let catalog else { return RelinkOutcome() }
        let chosen = assets.filter { ids.contains($0.id) && $0.isMissing }
        let targets = chosen.map {
            LostFileFinder.Target(assetID: $0.id, filename: $0.filename, contentHash: $0.contentHash)
        }
        var outcome = RelinkOutcome()
        guard !targets.isEmpty else { return outcome }

        let found = LostFileFinder.find(folder: folder, targets: targets)
        outcome.unmatched = found.unmatched
        outcome.rejected = found.rejected
        for match in found.matches {
            do {
                _ = try catalog.relink(assetID: match.assetID, to: match.url)
                outcome.relinked.append(match.assetID)
            } catch {
                outcome.failed.append(match.assetID)
                outcome.failures.append("\(match.filename)：\(error.localizedDescription)")
            }
        }
        lastAvailabilityError = outcome.failures.isEmpty ? nil : outcome.failures.joined(separator: "；")
        if !outcome.relinked.isEmpty { reload() }
        return outcome
    }

    // MARK: export items

    /// The photos an export acts on: the selection, in library order.
    public var exportableSelection: [Asset] { selectedAssets }

    /// One `ExportItem` per asset — the engine's input, built from the catalog.
    ///
    /// The document is the catalog's (`develop_json`), except for the photo whose document is live
    /// in `edit`: that one is *this* session's, which is what makes "edit, then export" export the
    /// edit that is on screen rather than the last committed one.
    public func exportItems(for assets: [Asset]) -> [ExportItem] {
        assets.map { asset in
            let document: EditModel
            if asset.id == loadedEditAssetID {
                document = MaskViewState.documentOnly(edit)
            } else if let catalog, let stored = try? catalog.develop(forAsset: asset.id) {
                document = MaskViewState.documentOnly(stored)
            } else {
                document = .neutral
            }
            return ExportItem(id: asset.id,
                              name: (asset.filename as NSString).deletingPathExtension,
                              captureDate: Self.captureDate(asset.captureTime),
                              rating: asset.rating,
                              edit: document,
                              sourceURL: fileURL(for: asset))
        }
    }

    /// `assets.capture_time` is ISO8601 UTC. `{date}` in a name template wants a `Date`.
    static func captureDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    // MARK: paths

    public func fileURL(for asset: Asset) -> URL? {
        try? catalog?.fileURL(for: asset)
    }

    public var currentPhotoURL: URL? {
        guard let a = anchorAsset else { return nil }
        return fileURL(for: a)
    }
}
