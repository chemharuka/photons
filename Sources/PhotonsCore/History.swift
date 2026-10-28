import Foundation

// MARK: - Render groups (D10)

/// The unit of *dirty tracking*: one bool per panel, never one per parameter.
///
/// darktable keeps a `history` row per edit and ART compresses RawTherapee's 10,673-line
/// per-parameter dirty machinery into 94 lines of group flags (docs/architecture-decisions.md D10).
/// The group set is the Lightroom panel split that `EditModel` already stores, plus `masks`, which
/// occupies its own group because masks are a first-class value (D11) with stages of their own.
///
/// A group is *dirty* when its parameters changed **semantically** — see
/// `EditHistory.dirtyGroups(from:to:)`, which compares floats with `EditHistory.dirtyTolerance`
/// so that re-serialising a document never invalidates a cache entry.
public enum RenderGroup: String, CaseIterable, Sendable, Codable, Hashable {
    case light
    case curve
    case color
    /// 2026-10-28 (P0 色彩分级): 色彩分级's own nine numbers, on a stage of their own (S3.8).
    ///
    /// Its own group rather than a corner of `.color`: the card is its own card with its own
    /// double-click reset, its own history wording (「色彩分级 阴影 色相」) and its own stage, and a
    /// group is what makes "this panel has a default" and "one snapshot" two properties of one thing.
    case colorGrading
    case detail
    case effects
    case geometry
    case masks

    /// Human label, used for menu titles ("Undo Exposure") and history rows.
    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .curve: return "Curve"
        case .color: return "Color"
        case .colorGrading: return "Color Grading"
        case .detail: return "Detail"
        case .effects: return "Effects"
        case .geometry: return "Geometry"
        case .masks: return "Masks"
        }
    }

    /// Stages whose parameters this group feeds, in pipeline order.
    ///
    /// Empty means "stored but not rendered by the current graph": `detail` is mapped onto
    /// `CIRAWFilter` in the decoder rather than onto a kernel, so it owns no stage.
    public var stages: [RenderStage] {
        switch self {
        case .light: return [.sceneLinear, .toneMap]
        case .curve: return [.curve]
        case .color: return [.color, .bw, .hsl]
        // 2026-10-28 (P0 色彩分级): one stage — S3.8.
        case .colorGrading: return [.grade]
        case .detail: return []
        // 2026-10-28: the Effects card is three stages — S3.8 (纹理/清晰度/去雾), S3c (vignette) and
        // S3.7 (grain), in pipeline order.
        case .effects: return [.detailFX, .vignette, .grain]
        case .geometry: return [.geometry]
        case .masks: return [.maskAtlas, .localApply, .localColor]
        }
    }

    /// False for groups the M1/M3 graph does not consume, so a dirty set can be explained.
    public var affectsRender: Bool { !stages.isEmpty }
}

// MARK: - Snapshot stack

/// The edit history: **a stack of parameter snapshots plus a cursor**, not a command log (D10).
///
/// Undo restores a whole `EditModel` rather than replaying inverse operations, so there is no
/// inverse-operation table to keep correct and no way for an undo to drift from what was rendered.
/// The granularity of one undo step is one *edit action*, i.e. one `commit`.
///
/// ```
///   seq  0        1         2          3
///        Original Exposure  Contrast   Saturation
///                    ▲ cursor = 1  →  undo gives seq 0, redo gives seq 2
/// ```
///
/// A `commit` while the cursor sits mid-stack discards the redo branch, exactly like darktable's
/// `history_end`: the future you had walked away from is not a future you can return to.
///
/// Value type, `Sendable`, `Codable`. The encoded shape is the M2 `edit_history` table's envelope:
/// each `Snapshot` maps to one row `(seq, label, edit, createdAt)`, and `cursor` / `nextSeq` /
/// `maxDepth` are the per-photo envelope stored alongside it (an `assets.history_end`-style
/// column).
public struct EditHistory: Sendable, Equatable, Codable {

    /// Bumped when the persisted envelope changes shape. Snapshots themselves are `EditModel`,
    /// which carries its own `schemaVersion` — history never rewrites them.
    ///
    /// 2 = 派单 077: a `Snapshot` carries `changes`, the **field-level** diff it introduced
    /// (`HistoryFields.swift`). Absent in a version-1 envelope, where the diff is recomputed from the
    /// neighbouring snapshots on load — so an old `asset_history` opens with readable rows and needs
    /// no migration.
    public static let currentSchemaVersion = 2

    /// 200 steps of whole-document JSON is at most a few hundred KB; unbounded is a leak, 50 is
    /// too few for a slider-drag session that commits per release.
    public static let defaultMaxDepth = 200

    /// Two parameter values this close are the same value. Chosen well below a slider's quantum
    /// (1/100 units) and well above double noise from a JSON round-trip (~1e-16 relative).
    public static let dirtyTolerance = 1e-6

    // MARK: snapshot

    /// One committed state. `seq` is monotonic for the life of the document and is **not**
    /// renumbered when old snapshots are evicted or a redo branch is truncated, so a seq is a
    /// stable identity across a save/load round-trip.
    public struct Snapshot: Sendable, Equatable, Codable {
        public var seq: Int
        public var label: String
        public var edit: EditModel
        public var createdAt: Date
        /// 077: the **field-level** diff this snapshot introduced, in a fixed order
        /// (`EditHistory.changedFields(between:and:)`). Empty for the baseline, and empty in a
        /// version-1 envelope until `init(rows:)` / `init(from:)` recompute it from the neighbour.
        ///
        /// Stored rather than derived, for one reason: **deleting a middle row must not rewrite the
        /// row after it.** A derived diff would compare against the new (further-back) predecessor
        /// and silently re-word somebody else's line.
        public var changes: [FieldChange]

        public init(seq: Int, label: String, edit: EditModel, createdAt: Date = Date(),
                    changes: [FieldChange] = []) {
            self.seq = seq
            self.label = label
            self.edit = edit
            self.createdAt = createdAt
            self.changes = changes
        }

        private enum CodingKeys: String, CodingKey {
            case seq, label, edit, createdAt, changes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.seq = try c.decode(Int.self, forKey: .seq)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            self.edit = try c.decode(EditModel.self, forKey: .edit)
            self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            // Forgiving: version-1 rows have no `changes` (see `backfillChanges`).
            self.changes = try c.decodeIfPresent([FieldChange].self, forKey: .changes) ?? []
        }
    }

    // MARK: state

    public private(set) var schemaVersion: Int
    /// Retained depth, clamped to ≥ 1 (a history that forgets the current state is not a history).
    public private(set) var maxDepth: Int
    public private(set) var snapshots: [Snapshot]
    /// Index into `snapshots` of the state that is currently on screen. Meaningless when
    /// `snapshots` is empty, where it is kept at 0 and `current` returns nil.
    public private(set) var cursor: Int
    /// Seq the next commit will take. Stored rather than derived so it survives truncation of the
    /// tip and eviction of the tail without ever reusing a number.
    public private(set) var nextSeq: Int
    /// 077: the tool session in progress, if any (裁切 / 旋转 / …). While one is open `commit` is a
    /// no-op, so a session is **exactly one** snapshot — taken by `endSession`, against the state the
    /// session started from. Transient by design: a session that is open when the app quits never
    /// existed, because nothing of it was ever committed.
    public private(set) var activeSession: ToolSession?

    /// One tool session: what it is called, the state it started from, and where the cursor stood.
    public struct ToolSession: Sendable, Equatable {
        /// The tool's name (`"裁切"`), used as the row's label unless `endSession` passes another.
        public let tool: String
        public let label: String
        /// The document **before** the tool was entered. `endSession` diffs against this, not against
        /// whatever the live document had become — which is what keeps the 20 handle positions out.
        public let base: EditModel
        public let cursorAtStart: Int
        public let seqAtStart: Int?

        public init(tool: String, label: String, base: EditModel, cursorAtStart: Int, seqAtStart: Int?) {
            self.tool = tool
            self.label = label
            self.base = base
            self.cursorAtStart = cursorAtStart
            self.seqAtStart = seqAtStart
        }
    }

    public var isSessionActive: Bool { activeSession != nil }

    // MARK: init

    /// An empty history. Committing into it makes the first snapshot immediately undoable-in-name
    /// only (there is nothing before it) — prefer `init(baseline:)` when opening a document.
    public init(maxDepth: Int = EditHistory.defaultMaxDepth) {
        self.schemaVersion = EditHistory.currentSchemaVersion
        self.maxDepth = max(1, maxDepth)
        self.snapshots = []
        self.cursor = 0
        self.nextSeq = 0
    }

    /// History seeded with the state the document was opened in. This snapshot is the floor of
    /// undo: the cursor can reach it but never pass it.
    public init(baseline: EditModel,
                label: String = "Original",
                maxDepth: Int = EditHistory.defaultMaxDepth,
                now: Date = Date()) {
        self.init(maxDepth: maxDepth)
        let first = Snapshot(seq: 0, label: label, edit: baseline, createdAt: now)
        self.snapshots = [first]
        self.cursor = 0
        self.nextSeq = 1
    }

    /// Rebuild from persisted rows — the M2 `edit_history` table, or any other row store.
    ///
    /// Rows are ordered by `seq`; duplicate seqs keep the last one written. `cursorSeq` is the
    /// persisted `history_end`-style cursor: nil (or a seq that no longer exists) puts the cursor
    /// on the tip, which is what "the document you just saved" means.
    public init(rows: [Snapshot],
                cursorSeq: Int? = nil,
                maxDepth: Int = EditHistory.defaultMaxDepth,
                now: Date = Date()) {
        self.init(maxDepth: maxDepth)
        var bySeq: [Int: Snapshot] = [:]
        for row in rows { bySeq[row.seq] = row }
        self.snapshots = bySeq.values.sorted { $0.seq < $1.seq }
        if let cursorSeq, let idx = snapshots.firstIndex(where: { $0.seq == cursorSeq }) {
            cursor = idx
        } else {
            cursor = max(0, snapshots.count - 1)
        }
        nextSeq = (snapshots.last?.seq ?? -1) + 1
        backfillChanges()
        enforceDepth()
    }

    // MARK: reading the stack

    public var count: Int { snapshots.count }
    public var isEmpty: Bool { snapshots.isEmpty }

    /// The state on screen, or nil for an empty history.
    public var current: EditModel? { snapshot(at: cursor)?.edit }

    public var currentSnapshot: Snapshot? { snapshot(at: cursor) }

    public var currentSeq: Int? { snapshot(at: cursor)?.seq }

    /// Label of the action `undo()` would take back — what a menu item should read.
    public var undoLabel: String? { cursor > 0 ? snapshot(at: cursor)?.label : nil }

    /// Label of the action `redo()` would re-apply.
    public var redoLabel: String? { canRedo ? snapshot(at: cursor + 1)?.label : nil }

    public var canUndo: Bool { cursor > 0 && cursor < snapshots.count }

    public var canRedo: Bool { cursor + 1 < snapshots.count }

    public func snapshot(at index: Int) -> Snapshot? {
        snapshots.indices.contains(index) ? snapshots[index] : nil
    }

    /// Index of a snapshot by its stable `seq`, or nil once it has been evicted/truncated.
    public func index(of seq: Int) -> Int? {
        snapshots.firstIndex { $0.seq == seq }
    }

    // MARK: committing

    /// Append a state and move the cursor onto it.
    ///
    /// - No-op (returns nil) when `edit` is semantically identical to the current state: an
    ///   unchanged document must not grow the stack, and — importantly — must not truncate the
    ///   redo branch either, so a stray commit cannot destroy the future.
    /// - No-op (returns nil) while a **tool session** is open (077): a session is one snapshot, and
    ///   `endSession` is the only thing that takes it. A UI that commits per handle position gets
    ///   nothing — the granularity is the session's, not the timer's.
    /// - **Merges into the tip** when the top of the stack is the last snapshot and both it and this
    ///   commit move exactly one gesture class (077): a slider drag is one row, not 300.
    /// - Otherwise truncates everything after the cursor (the redo branch) and appends.
    /// - An empty `label` is derived from the dirty groups ("Light + Color").
    ///
    /// - Returns: the snapshot written (or the merged tip), or nil for a no-op.
    /// - Parameter coalesce: `true` (the default) lets a same-class run fold into the tip — a slider
    ///   drag is one row however many frames it wrote. Pass `false` for a **discrete command**
    ///   (双击复位, 换解码版本, a preset): it is one action by definition, and folding it into the drag
    ///   before it would either hide it inside that drag's row or — when it lands exactly on the
    ///   drag's start — erase both, leaving ⌘Z with nothing to take back. The default is deliberately
    ///   the permissive one: a UI that says nothing gets one row per drag, never 300.
    @discardableResult
    public mutating func commit(_ edit: EditModel,
                                label: String = "",
                                now: Date = Date(),
                                coalesce: Bool = true) -> Snapshot? {
        // 077: a session owns the next snapshot. Committing "inside" it is not an edit yet.
        guard activeSession == nil else { return nil }
        return appendSnapshot(edit, label: label, before: current ?? .neutral,
                              now: now, allowsMerge: coalesce)
    }

    /// The one write path. `before` is what the row's diff and label are computed against — the
    /// state on screen for an ordinary commit, the session's base for a tool session (077).
    @discardableResult
    mutating func appendSnapshot(_ edit: EditModel,
                                 label: String,
                                 before: EditModel,
                                 now: Date,
                                 allowsMerge: Bool) -> Snapshot? {
        // "same document", not "same pixels": a mask rename redraws nothing but must still be
        // undoable, so the no-op test is the stricter of the two questions.
        guard !EditHistory.isSemanticallyIdentical(before, edit) else { return nil }
        var labelGroups = EditHistory.dirtyGroups(from: before, to: edit)
        // A change that redraws nothing but is still committed (a rename) has no dirty group to
        // name itself after; it is a masks-panel edit all the same.
        if labelGroups.isEmpty && before.masks != edit.masks { labelGroups = [.masks] }

        let changes = EditHistory.changedFields(between: before, and: edit)

        // 077 — coalesce a continuous drag into the row it started.
        //
        // The test for "continuous" is deliberately **structural**, not temporal: the cursor is at
        // the tip (nothing was undone or jumped away in between) and the parameter class is the
        // same. darktable asks the GUI instead (`focus_hash`: "is the same control still focused"),
        // which is exactly what this design refuses — a history row must not depend on the window
        // server's idea of focus, and a 300 ms timer is a guess. A different class in between
        // (`exposure, contrast, exposure`) breaks the run, which is the user's rule.
        if allowsMerge, cursor == snapshots.count - 1, snapshots.count >= 2,
           let mine = EditHistory.mergeClass(of: changes),
           let theirs = EditHistory.mergeClass(of: snapshots[snapshots.count - 1].changes),
           mine == theirs {
            let tip = snapshots[snapshots.count - 1]
            let runStart = snapshots[snapshots.count - 2].edit
            let mergedChanges = EditHistory.changedFields(between: runStart, and: edit)
            // Dragged back to where the run started: the row has nothing left to say, so it goes
            // away entirely (and the cursor with it). "拖过去又拖回来" is not an edit.
            if mergedChanges.isEmpty {
                snapshots.removeLast()
                cursor = snapshots.count - 1
                return nil
            }
            var merged = tip
            merged.edit = edit
            merged.changes = mergedChanges
            // `seq`, `label` and `createdAt` stay the run's **first** ones: the row's identity is
            // when the drag began, and `seq` is a stable identity nothing may renumber.
            snapshots[snapshots.count - 1] = merged
            return merged
        }

        if cursor + 1 < snapshots.count {
            snapshots.removeSubrange((cursor + 1)...)
        }
        let snap = Snapshot(seq: nextSeq,
                            label: EditHistory.derivedLabel(label, groups: labelGroups),
                            edit: edit,
                            createdAt: now,
                            changes: changes)
        snapshots.append(snap)
        nextSeq = snap.seq + 1
        cursor = snapshots.count - 1
        enforceDepth()
        return snap
    }

    /// The class a commit belongs to, or nil when it is not a single-gesture change.
    ///
    /// A multi-class commit (paste settings, a group reset, a preset) is one action that moved
    /// several panels; it is never "the same drag continued", so it never merges and never gets
    /// merged into.
    static func mergeClass(of changes: [FieldChange]) -> String? {
        let classes = Set(changes.map(\.field.gestureClass))
        return classes.count == 1 ? classes.first : nil
    }

    // MARK: tool sessions (077)

    /// Open a tool session: from here until `endSession` / `cancelSession`, `commit` records nothing.
    ///
    /// Entering a tool is **not** an edit (nothing is committed), and neither is any handle position
    /// inside it — see `endSession` for the one row a session may leave behind. A session opened
    /// while one is already open is ignored: nesting would produce two rows for one gesture.
    public mutating func beginSession(_ tool: String, label: String? = nil) {
        guard activeSession == nil else { return }
        activeSession = ToolSession(tool: tool,
                                    label: label ?? tool,
                                    base: current ?? .neutral,
                                    cursorAtStart: cursor,
                                    seqAtStart: currentSeq)
    }

    /// Close a session with **exactly one** snapshot: `base → edit`, or none at all if the tool
    /// changed nothing.
    ///
    /// The diff is taken against `base`, so the row reads 「裁切: 裁切 x 0 → 0.12 …」 and every
    /// intermediate rectangle the user dragged through is absent from the history. Returns nil when
    /// there is no session, or when the session left the document where it found it.
    @discardableResult
    public mutating func endSession(_ edit: EditModel, label: String? = nil,
                                    now: Date = Date()) -> Snapshot? {
        guard let session = activeSession else { return nil }
        activeSession = nil
        // `allowsMerge: false`: two crop sessions are two actions. A session has already declared
        // its own boundaries, and merging across them would quietly undo that declaration.
        return appendSnapshot(edit, label: label ?? session.label, before: session.base,
                              now: now, allowsMerge: false)
    }

    /// Close a session with **zero** snapshots — 取消. Nothing was committed inside it, so this only
    /// drops the session; a redo branch that existed before the tool is left exactly as it was.
    public mutating func cancelSession() {
        activeSession = nil
    }

    // MARK: navigating

    /// Step back one snapshot and return the state to show. Does not truncate the redo branch.
    @discardableResult
    public mutating func undo() -> EditModel? {
        guard canUndo else { return nil }
        cursor -= 1
        return snapshots[cursor].edit
    }

    /// Step forward one snapshot and return the state to show.
    @discardableResult
    public mutating func redo() -> EditModel? {
        guard canRedo else { return nil }
        cursor += 1
        return snapshots[cursor].edit
    }

    /// Select an arbitrary snapshot by seq (clicking a row in the history panel).
    ///
    /// Jumping forward past the cursor is redo, not a new edit: it never truncates anything.
    /// Returns nil when that seq is no longer in the stack.
    @discardableResult
    public mutating func jump(to seq: Int) -> EditModel? {
        guard let idx = index(of: seq) else { return nil }
        cursor = idx
        return snapshots[idx].edit
    }

    /// Move the cursor to the tip (redo everything retained). No-op on an empty history.
    @discardableResult
    public mutating func jumpToTip() -> EditModel? {
        guard !snapshots.isEmpty else { return nil }
        cursor = snapshots.count - 1
        return snapshots[cursor].edit
    }

    // MARK: deleting a row (077)

    /// The diff this row introduced, as it was recorded when it was committed.
    public func changedFields(at index: Int) -> [FieldChange] {
        snapshot(at: index)?.changes ?? []
    }

    /// The row's fields that **no later snapshot touches** — i.e. the ones this row is still the
    /// newest statement about.
    public func newestFields(at index: Int) -> Set<String> {
        guard snapshots.indices.contains(index) else { return [] }
        var mine = Set(snapshots[index].changes.map(\.field.key))
        guard !mine.isEmpty else { return [] }
        for later in snapshots[(index + 1)...] {
            for change in later.changes { mine.remove(change.field.key) }
        }
        return mine
    }

    /// True when every field this row moved is still the newest statement about that field — the
    /// 「最新的该类操作」 the panel badges, and the only rows the panel lets the user delete.
    ///
    /// One predicate, deliberately: if the badge and the delete button were two conditions, the
    /// panel could offer a delete on a row it is not marking, or mark a row it will not delete,
    /// and either one is a lie about the same fact.
    public func isNewestOfClass(at index: Int) -> Bool {
        guard index > 0, snapshots.indices.contains(index) else { return false }
        let all = Set(snapshots[index].changes.map(\.field.key))
        return !all.isEmpty && newestFields(at: index) == all
    }

    /// May this row be deleted on its own?
    ///
    /// ```
    ///   deletable(i) ⟺ i > 0 ∧ changes(i) ≠ ∅ ∧ ∀ j > i : fields(j) ∩ fields(i) = ∅
    /// ```
    ///
    /// **Why deleting a row is safe at all** — three structural facts, no analogy:
    ///
    /// 1. A snapshot is an **absolute** state, not a delta (D10). Removing row i leaves
    ///    `snapshots[i+1].edit` byte-identical, so no other row has to be recomputed or re-worded.
    /// 2. `fields(i)` is untouched by every later row ⇒ every later row carries i's value forward.
    ///    The step from i−1 to i+1 therefore has equal values on those fields, which is exactly what
    ///    "the step is gone, the document is not" means.
    /// 3. `seq` is a stable identity and is never renumbered (`Snapshot.seq`), so the surviving rows
    ///    keep their numbers and the store deletes exactly one row.
    ///
    /// **Why a covered row is refused**: it is the only record of what that parameter looked like
    /// mid-stack. Deleting it would silently move the value the user can jump back to, with nothing
    /// on screen to explain it. (The user's rule — 「只有最新的该类操作可以单独删除」 — is this.)
    public func deletable(at index: Int) -> Bool { isNewestOfClass(at: index) }

    /// Delete one row. `cursor` stays on the same snapshot where possible (see below); `nextSeq` is
    /// **not** rewound, so no seq is ever reused.
    ///
    /// | deleted index | cursor |
    /// |---|---|
    /// | `< cursor` | `cursor − 1` — still the same snapshot, the picture does not move |
    /// | `== cursor` | `max(0, i − 1)` — you cannot stand on a row that no longer exists; the
    ///   document becomes the previous row's, which the caller shows (one render) |
    /// | `> cursor` | unchanged — the deleted row was in the redo branch |
    ///
    /// Returns false (and changes nothing) when `deletable(at:)` is false.
    @discardableResult
    public mutating func delete(at index: Int) -> Bool {
        guard deletable(at: index) else { return false }
        let wasCurrent = index == cursor
        snapshots.remove(at: index)
        if wasCurrent {
            cursor = max(0, index - 1)
        } else if index < cursor {
            cursor -= 1
        }
        cursor = min(max(cursor, 0), max(0, snapshots.count - 1))
        return true
    }

    /// Fill in `changes` for rows that arrive without them (a version-1 envelope, or rows built from
    /// `asset_history`, which stores no diff).
    ///
    /// Recomputed from the **neighbour that is there now**, so after a reload the row that followed
    /// a deleted one shows the surviving transition. That is the honest reading of a stack that no
    /// longer has that predecessor; within a session the stored `changes` are what keeps every other
    /// row byte-identical (see `Snapshot.changes`).
    mutating func backfillChanges() {
        guard snapshots.count > 1 else { return }
        for i in snapshots.indices.dropFirst() where snapshots[i].changes.isEmpty {
            snapshots[i].changes = EditHistory.changedFields(between: snapshots[i - 1].edit,
                                                            and: snapshots[i].edit)
        }
    }

    // MARK: depth

    /// Change the retained depth. Shrinking evicts the **oldest** snapshots and keeps the cursor
    /// on the same snapshot where possible; when the cursor's own snapshot is evicted it lands on
    /// the oldest survivor. Never renumbers the survivors' seqs.
    public mutating func setMaxDepth(_ newValue: Int) {
        maxDepth = max(1, newValue)
        enforceDepth()
    }

    private mutating func enforceDepth() {
        guard !snapshots.isEmpty else { cursor = 0; return }
        if snapshots.count > maxDepth {
            let overflow = snapshots.count - maxDepth
            snapshots.removeFirst(overflow)
            cursor -= overflow
        }
        cursor = min(max(cursor, 0), snapshots.count - 1)
    }

    // MARK: labels

    static func derivedLabel(_ label: String, groups: Set<RenderGroup>) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !groups.isEmpty else { return "Edit" }
        return RenderGroup.allCases
            .filter { groups.contains($0) }
            .map(\.displayName)
            .joined(separator: " + ")
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, maxDepth, snapshots, cursor, nextSeq
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // Forgiving: an older or hand-written envelope decodes to a usable history rather than
        // failing a whole document open.
        self.schemaVersion = c.val("schemaVersion", EditHistory.currentSchemaVersion)
        let depth = c.val("maxDepth", EditHistory.defaultMaxDepth)
        self.maxDepth = max(1, depth)
        self.snapshots = c.val("snapshots", [Snapshot]())
        self.nextSeq = c.val("nextSeq", (self.snapshots.last?.seq ?? -1) + 1)
        let rawCursor = c.val("cursor", max(0, self.snapshots.count - 1))
        self.cursor = self.snapshots.isEmpty ? 0 : min(max(rawCursor, 0), self.snapshots.count - 1)
        self.nextSeq = max(self.nextSeq, (self.snapshots.map(\.seq).max() ?? -1) + 1)
        backfillChanges()
        enforceDepth()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(maxDepth, forKey: .maxDepth)
        try c.encode(snapshots, forKey: .snapshots)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(nextSeq, forKey: .nextSeq)
    }
}
