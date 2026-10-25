import Foundation
import Observation
import PhotonsCatalog
import PhotonsCore

/// The one and only source of truth for the workspace.
///
/// Research `ui-stack.md` F5: the projects that mixed AppKit + SwiftUI did **not** keep two state
/// managers — they kept one `@Observable` model, one 15-line observation bridge for the AppKit side,
/// and `@Bindable` for the SwiftUI leaf views. That is the rule here: every view (grid, filmstrip,
/// sources, loupe, inspector) reads and writes this object, and nothing keeps a copy.
///
/// What is *not* here on purpose (M3 scope): thumbnails, per-photo edit documents (only one live
/// `EditModel` for the current photo), rating writes, masks.
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

    // MARK: document

    /// The live document for the anchor photo. **Read-only from outside**: a slider goes through
    /// `applyEdit`, which is what bumps `editRevision` — the one signal the render loop listens to.
    /// A second writer that assign to `edit` directly would move pixels without invalidating them.
    public private(set) var edit: EditModel = .neutral

    /// Monotonic counter of document changes. The loupe observes *this* instead of diffing
    /// `EditModel` (a struct comparison on every observation pass, for no extra information).
    public private(set) var editRevision = 0

    /// When the last document change landed. Slider→frame latency is measured from here, so the
    /// reported number includes the 50 ms debounce window rather than hiding it.
    public private(set) var lastEditChangedAt: CFAbsoluteTime = 0

    /// The undo stack (D10: snapshots plus a cursor, not a command log). Seeded with the state the
    /// document was opened in, so the floor of undo is "Original", never "neutral".
    public private(set) var history = EditHistory()

    /// The asset whose document is loaded in `edit` / `history`.
    public private(set) var loadedEditAssetID: String?

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// Label of the action ⌘Z would take back — what the menu item should read.
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }

    // MARK: view state (mirrors, never duplicates, model state)

    public var mode: Mode = .grid {
        didSet { if mode == .loupe, anchorID == nil { anchorID = assets.first?.id } }
    }

    // MARK: decoder facts

    /// What the last decode actually used — v9 or a silent v8 downgrade (§11.1).
    public private(set) var capabilities: DecoderCapabilities?

    private var catalog: Catalog?

    public init() {}

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
        reload()
    }

    public func reload() {
        guard let c = catalog else { return }
        do {
            roots = try c.roots()
            // The grid is the library view: everything the catalog has, newest first (the query
            // already orders by capture_time DESC). M3 has no paging; 10k rows is the design point.
            assets = try c.assets(AssetFilter(sourceRootId: selectedRootID, limit: 200_000))
            stats = try c.stats()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            assets = []
            roots = []
        }
        // Drop selections that no longer exist (a reload can follow an import).
        let ids = Set(assets.map(\.id))
        selection.formIntersection(ids)
        if let a = anchorID, !ids.contains(a) { anchorID = assets.first?.id }
        if anchorID == nil { anchorID = assets.first?.id }
        if selection.isEmpty, let first = anchorID { selection = [first] }
        // A fresh library (or a new root) can leave `edit` pointing at the previous document; load
        // the anchor's stored document now instead of waiting for the next selection change.
        if let a = anchorAsset, loadedEditAssetID != a.id { loadEditForAnchor() }
    }

    // MARK: selection

    /// `nil` = all photos. The browser's source list writes this; the grid/list/loupe all follow.
    public private(set) var selectedRootID: String?

    public func selectRoot(_ id: String?) {
        guard id != selectedRootID else { return }
        selectedRootID = id
        reload()
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

    public func setSelection(_ ids: Set<String>, anchor: String? = nil) {
        selection = ids
        if let anchor {
            anchorID = anchor
        } else if let current = anchorID, ids.contains(current) {
            // keep the anchor
        } else {
            anchorID = ids.isEmpty ? nil : assets.last(where: { ids.contains($0.id) })?.id
        }
        loadEditForAnchor()
    }

    public func selectOnly(_ id: String) {
        setSelection([id], anchor: id)
    }

    /// Grid/filmstrip click with modifiers already resolved by the control.
    public func toggle(_ id: String) {
        var next = selection
        if next.contains(id) {
            next.remove(id)
            if anchorID == id { anchorID = next.isEmpty ? nil : assets.last(where: { next.contains($0.id) })?.id }
        } else {
            next.insert(id)
            anchorID = id
        }
        setSelection(next, anchor: anchorID)
    }

    /// Arrow/Home/End/Page navigation: move the anchor by `delta` library rows and select only it.
    @discardableResult
    public func moveAnchor(by delta: Int, extend: Bool = false) -> Bool {
        guard !assets.isEmpty else { return false }
        let current = anchorIndex ?? 0
        let target = min(max(0, current + delta), assets.count - 1)
        guard target != current || anchorID == nil else { return false }
        let id = assets[target].id
        if extend {
            var next = selection
            next.insert(id)
            anchorID = id
            setSelection(next)
        } else {
            selectOnly(id)
        }
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

    // MARK: documents

    /// The one way a slider (or a test) moves the document.
    ///
    /// Bumps `editRevision` only when the value actually changed, so an idle drag calls the
    /// renderer zero times instead of once per mouse move.
    public func applyEdit(_ mutate: (inout EditModel) -> Void) {
        var next = edit
        mutate(&next)
        guard !EditHistory.isSemanticallyIdentical(edit, next) else { return }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
    }

    /// End of one edit action (a slider release, a toggle, a menu command): push a snapshot.
    /// `EditHistory.commit` is a no-op when nothing changed, so a click on a slider that did not
    /// move does not grow the stack or truncate the redo branch.
    @discardableResult
    public func commitEdit(label: String = "") -> Bool {
        history.commit(edit, label: label) != nil
    }

    /// ⌘Z. Restores a whole snapshot — never an inverse operation (§History).
    @discardableResult
    public func undo() -> Bool {
        guard let model = history.undo() else { return false }
        restore(model)
        return true
    }

    /// ⇧⌘Z.
    @discardableResult
    public func redo() -> Bool {
        guard let model = history.redo() else { return false }
        restore(model)
        return true
    }

    private func restore(_ model: EditModel) {
        edit = model
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
    }

    /// `force` re-reads the stored document (after an external save or a develop-json change).
    /// Without it, re-selecting the same photo keeps the live edit *and its history* — a selection
    /// change must not silently throw away the undo stack.
    public func loadEditForAnchor(force: Bool = false) {
        guard let a = anchorAsset else {
            edit = .neutral
            history = EditHistory(baseline: .neutral)
            loadedEditAssetID = nil
            return
        }
        if !force, loadedEditAssetID == a.id { return }
        // `developJson` is the document truth (D7/D9). M3 keeps the schema but does not save.
        let model: EditModel
        if let data = a.developJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EditModel.self, from: data) {
            model = decoded
        } else {
            model = .neutral
        }
        edit = model
        history = EditHistory(baseline: model)
        loadedEditAssetID = a.id
    }

    public func recordCapabilities(_ c: DecoderCapabilities) {
        // Equality-guarded: every presented frame reports the same facts, and an unconditional write
        // would re-render the SwiftUI inspector once per slider frame for no information.
        guard capabilities != c else { return }
        capabilities = c
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
