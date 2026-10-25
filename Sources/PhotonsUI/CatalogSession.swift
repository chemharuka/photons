import Foundation
import Observation
import PhotonsCatalog
import PhotonsCore
import PhotonsExport

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
    public var brushSize: Double = 0.12
    /// 0…1. A hard brush (`1`) has a 1 px edge; `0` is a fully feathered stamp.
    public var brushHardness: Double = 0.5
    /// 0…1 per-stroke alpha multiplier.
    public var brushFlow: Double = 1.0

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
        // The preset card and the Develop menu read this cache; fill it as soon as the library is
        // open instead of waiting for the panel's first `onAppear`.
        reloadPresets()
    }

    public func reload() {
        guard let c = catalog else { return }
        do {
            roots = try c.roots()
            // The grid is the library view: everything the catalog has, newest first (the query
            // already orders by capture_time DESC). M3 has no paging; 10k rows is the design point.
            // The filter bar's value is folded into the *same* query the source list uses, so the
            // visible rows, their order and the count in the top bar can never disagree.
            let f = filter
            assets = try c.assets(AssetFilter(ratingAtLeast: f.ratingAtLeast,
                                              cameraKey: f.cameraKey,
                                              sourceRootId: selectedRootID,
                                              limit: 200_000,
                                              flagEquals: f.flag,
                                              colorLabelEquals: f.colorLabel))
            stats = try c.stats()
            loadError = nil
            // The camera list is a property of the library, not of the current filter: derive it
            // only from an unfiltered load so narrowing never removes a choice from its own popup.
            if !f.isActive {
                allCameraKeys = Array(Set(assets.compactMap(\.cameraKey))).sorted()
            }
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
    public func applyFilter(_ next: CatalogFilter) {
        guard next != filter else { return }
        filter = next
        reload()
    }

    public func clearFilter() {
        applyFilter(.none)
    }

    /// Drop one facet — what clicking a chip does.
    public func clearFilter(_ facet: CatalogFilter.Facet) {
        applyFilter(filter.without(facet))
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
    @discardableResult
    public func commitEdit(label: String = "") -> Bool {
        let committed = history.commit(MaskViewState.documentOnly(edit), label: label) != nil
        if committed { persist() }
        return committed
    }

    /// ⌘Z. Restores a whole snapshot — never an inverse operation (§History).
    ///
    /// The snapshot is the *document*; the `showMask` overlay that was on screen is pasted back on
    /// top of it. Without that, undoing any edit would silently switch the mask display off (the
    /// snapshot was taken before the overlay was turned on, and `showMaskID` is not an edit), which
    /// is the Q22/Q9e conflict in `docs/tasks/QUEUE.md`.
    @discardableResult
    public func undo() -> Bool {
        guard let model = history.undo() else { return false }
        restore(model)
        persist()
        return true
    }

    /// ⇧⌘Z.
    @discardableResult
    public func redo() -> Bool {
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
            lastSaveResult = try catalog.saveDevelop(document, history: stack, forAsset: id)
            lastPersistError = nil
            persistCount += 1
        } catch {
            // A failed write is reported, never swallowed: the document is still on screen and
            // still undoable, and the next commit retries.
            lastPersistError = "\(error)"
        }
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
    }

    public func recordCapabilities(_ c: DecoderCapabilities) {
        // Equality-guarded: every presented frame reports the same facts, and an unconditional write
        // would re-render the SwiftUI inspector once per slider frame for no information.
        guard capabilities != c else { return }
        capabilities = c
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
            applyEdit { $0 = merged }
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
                                        groups: Set<PresetGroup> = Set(PresetGroup.allCases))
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
            let preset = Preset(name: trimmed, from: MaskViewState.documentOnly(edit), groups: groups)
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
