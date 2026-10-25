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
        case .color: return [.color]
        case .detail: return []
        case .effects: return [.vignette]
        case .geometry: return [.geometry]
        case .masks: return [.maskAtlas, .localApply]
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
    public static let currentSchemaVersion = 1

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

        public init(seq: Int, label: String, edit: EditModel, createdAt: Date = Date()) {
            self.seq = seq
            self.label = label
            self.edit = edit
            self.createdAt = createdAt
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
    /// - Truncates everything after the cursor (the redo branch) before appending.
    /// - An empty `label` is derived from the dirty groups ("Light + Color").
    ///
    /// - Returns: the snapshot written, or nil for a no-op.
    @discardableResult
    public mutating func commit(_ edit: EditModel,
                                label: String = "",
                                now: Date = Date()) -> Snapshot? {
        let before = current ?? .neutral
        // "same document", not "same pixels": a mask rename redraws nothing but must still be
        // undoable, so the no-op test is the stricter of the two questions.
        guard !EditHistory.isSemanticallyIdentical(before, edit) else { return nil }
        var labelGroups = EditHistory.dirtyGroups(from: before, to: edit)
        // A change that redraws nothing but is still committed (a rename) has no dirty group to
        // name itself after; it is a masks-panel edit all the same.
        if labelGroups.isEmpty && before.masks != edit.masks { labelGroups = [.masks] }

        if cursor + 1 < snapshots.count {
            snapshots.removeSubrange((cursor + 1)...)
        }
        let snap = Snapshot(seq: nextSeq,
                            label: EditHistory.derivedLabel(label, groups: labelGroups),
                            edit: edit,
                            createdAt: now)
        snapshots.append(snap)
        nextSeq = snap.seq + 1
        cursor = snapshots.count - 1
        enforceDepth()
        return snap
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
