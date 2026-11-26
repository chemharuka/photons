import PhotonsLocalization
import PhotonsCore
import Foundation
import GRDB

/// 照片堆叠（§378）— 库属性，不是文档属性。
///
/// A stack is nothing but "these rows share `stack_id`, and this one is `stack_rank = 0`" (see v6 in
/// `Schema.swift`). That is the whole storage decision, and it is what makes this file short:
///
///   · **no `stacks` table** — the stack exists exactly as long as some asset points at its id, so
///     deleting the last member deletes the stack with no cascade to remember;
///   · **exactly one 置顶 per stack** — SQLite's partial unique index on `stack_rank = 0`, the same
///     device `presets.is_default` uses. `setStackTop` still clears inside the transaction, because a
///     constraint violation is a worse error message than a successful swap;
///   · **`stack_id` is a fresh UUID**, never an asset id: changing the top must not change the
///     stack's identity.
///
/// Display order (used for 置顶, for the members menu, and for "which member is first") is the
/// catalog's order: `capture_time DESC` (undated last), then `filename`, then `id` — the same total
/// order `PhotoSortOrder` gives the three browsers, so "the first member" means the same thing in
/// every place that asks.
///
/// Like rating / flag / colour label, none of this touches `EditModel`, `EditHistory` or
/// `develop_json`: ⌘Z never walks a stack back, and `editRevision` never moves for one.
// MARK: - kind

/// 487 — what a stack *is*.
///
/// `plain` is every stack that is not a denoise pair (HDR, a manual ⌘G, a merge). `denoise` is the
/// special two-member pair the denoise path creates: the original and its `-denoised` sibling. The
/// kind changes two things and nothing else:
///
///   · **what the three browsers call it** — `降噪-XXX.dng` with a sparkle icon instead of
///     `堆叠 XXX.dng` with `⧉`;
///   · **whether an edit propagates** — a commit on either member is written to both.
///
/// It never enters `EditModel`, a history row or a cache key: it does not change a pixel.
public enum StackKind: String, Sendable, Equatable, CaseIterable {
    case plain
    case denoise

    /// The **one** recognition rule, shared by 组堆叠 and 重新堆叠 (487 §2.1-2).
    ///
    /// Exactly two members, the same extension, and one stem is the other stem plus `"-denoised"`.
    /// A third member, a different extension, or a suffix that is not exactly `-denoised`
    /// (`L-denoised-2.dng`) is `plain` — the rule does not guess from a prefix.
    public static func forMemberFilenames(_ filenames: [String]) -> StackKind {
        denoiseProductFilename(filenames) != nil ? .denoise : .plain
    }

    /// 566 — the product file of a denoise pair, or nil when the shape is not one.
    ///
    /// Exactly two members, the same extension, and one stem is the other stem plus `-denoised`.
    /// Returns the filename whose stem carries the suffix. This is the *same* rule
    /// `forMemberFilenames` asks; the menu and the deletion path call it to name the product itself,
    /// not just to classify the pair.
    public static func denoiseProductFilename(_ filenames: [String]) -> String? {
        guard filenames.count == 2 else { return nil }
        let a = split(filenames[0])
        let b = split(filenames[1])
        guard !a.ext.isEmpty, !b.ext.isEmpty,
              a.ext.caseInsensitiveCompare(b.ext) == .orderedSame else { return nil }
        if a.stem == b.stem + "-denoised" { return filenames[0] }
        if b.stem == a.stem + "-denoised" { return filenames[1] }
        return nil
    }

    private static func split(_ filename: String) -> (stem: String, ext: String) {
        let name = filename as NSString
        return (name.deletingPathExtension, name.pathExtension)
    }
}

public struct StackSummary: Equatable, Sendable {
    /// The stack's id (`assets.stack_id`).
    public let id: String
    /// Member asset ids in display order, **including the top**.
    public let memberIDs: [String]
    /// The 置顶 member — the one every browser shows for this stack.
    public let topID: String
    /// 487 — `plain` unless the pair is a denoise original + product.
    public let kind: StackKind

    public init(id: String, memberIDs: [String], topID: String, kind: StackKind = .plain) {
        self.id = id
        self.memberIDs = memberIDs
        self.topID = topID
        self.kind = kind
    }

    public var count: Int { memberIDs.count }
}

public enum StackError: LocalizedError, Equatable {
    case noSuchStack(String)
    case notEnoughPhotos
    case assetNotInStack(assetID: String, stackID: String)

    public var errorDescription: String? {
        switch self {
        case .noSuchStack(let id): return Loc.t("没有这个堆叠：{0}", String(describing: (id)))
        case .notEnoughPhotos: return Loc.t("堆叠至少需要两张照片")
        case .assetNotInStack(let assetID, let stackID):
            return Loc.t("照片 {0} 不在堆叠 {1} 里", String(describing: (assetID)), String(describing: (stackID)))
        }
    }
}

// MARK: - queries

extension Catalog {

    /// One stack's members, in display order. Empty when the id names no live stack.
    public func stackMembers(stackID: String) throws -> [Asset] {
        try dbQueue.read { db in
            try Asset.fetchAll(db, sql: """
                SELECT * FROM assets
                WHERE stack_id = ? AND deleted = 0
                ORDER BY (capture_time IS NULL), capture_time DESC, filename, id
                """, arguments: [stackID])
        }
    }

    /// Several stacks' members in **one** query, keyed by `stack_id` — what the session's projection
    /// asks for on every reload.
    public func stackMembers(stackIDs: [String]) throws -> [String: [Asset]] {
        let unique = Array(Set(stackIDs))
        guard !unique.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
        return try dbQueue.read { db in
            let rows = try Asset.fetchAll(db, sql: """
                SELECT * FROM assets
                WHERE stack_id IN (\(marks)) AND deleted = 0
                ORDER BY stack_id, (capture_time IS NULL), capture_time DESC, filename, id
                """, arguments: StatementArguments(unique))
            var out: [String: [Asset]] = [:]
            for row in rows {
                guard let id = row.stackId else { continue }
                out[id, default: []].append(row)
            }
            return out
        }
    }

    /// The stack an asset belongs to, or nil for a photo in no stack.
    public func stackID(ofAsset id: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT stack_id FROM assets WHERE id = ?", arguments: [id])
        }
    }

    /// The summary of one stack, or nil when the id names nothing (all its members were deleted).
    public func stackSummary(stackID: String) throws -> StackSummary? {
        let members = try stackMembers(stackID: stackID)
        guard let top = members.first(where: { $0.stackRank == 0 }) else { return nil }
        let kind = try stackKind(stackID: stackID) ?? .plain
        return StackSummary(id: stackID, memberIDs: members.map(\.id), topID: top.id, kind: kind)
    }

    /// 487 — the kind of one stack's rows. Nil when the stack has no live member.
    ///
    /// All members of a stack always carry the same value (written together by `makeStack`); the
    /// `ORDER BY stack_rank` is only a tie-breaker for a hand-edited library, not a second source of
    /// truth.
    public func stackKind(stackID: String) throws -> StackKind? {
        try dbQueue.read { db in
            let raw = try String.fetchOne(db, sql: """
                SELECT stack_kind FROM assets WHERE stack_id = ? ORDER BY stack_rank LIMIT 1
                """, arguments: [stackID])
            guard let raw else { return nil }
            return StackKind(rawValue: raw) ?? .plain
        }
    }

    /// 487 — the kind of the stack an asset belongs to, or nil when it is in no stack.
    public func stackKind(ofAsset id: String) throws -> StackKind? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT stack_id, stack_kind FROM assets WHERE id = ?
                """, arguments: [id])
            guard let row, (row["stack_id"] as String?) != nil else { return nil }
            return StackKind(rawValue: row["stack_kind"] ?? "plain") ?? .plain
        }
    }

    /// 487 — the kinds of several stacks in **one** query, for the projection that rebuilds on every
    /// reload (`CatalogSession.stacksByTop`). Stacks absent from the result are `plain`.
    public func stackKinds(stackIDs: [String]) throws -> [String: StackKind] {
        let unique = Array(Set(stackIDs))
        guard !unique.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT stack_id, stack_kind FROM assets
                WHERE stack_id IN (\(marks))
                ORDER BY stack_id, stack_rank
                """, arguments: StatementArguments(unique))
            var out: [String: StackKind] = [:]
            for row in rows {
                guard let id: String = row["stack_id"], out[id] == nil else { continue }
                out[id] = StackKind(rawValue: row["stack_kind"] ?? "plain") ?? .plain
            }
            return out
        }
    }

    /// 487 — the **other** member of a two-member denoise stack, or nil.
    ///
    /// The id is the only thing an edit needs to link to; the kind and the member count are checked
    /// here so a plain stack or a stack that grew a third member can never propagate an edit.
    public func denoiseSibling(ofAsset id: String) throws -> String? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT stack_id, stack_kind FROM assets WHERE id = ?
                """, arguments: [id]),
                  let stackID: String = row["stack_id"],
                  StackKind(rawValue: row["stack_kind"] ?? "plain") == .denoise else { return nil }
            let liveCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets WHERE stack_id = ? AND deleted = 0
                """, arguments: [stackID]) ?? 0
            guard liveCount == 2 else { return nil }
            return try String.fetchOne(db, sql: """
                SELECT id FROM assets WHERE stack_id = ? AND deleted = 0 AND id <> ? LIMIT 1
                """, arguments: [stackID, id])
        }
    }
}

// MARK: - mutations

extension Catalog {

    /// 堆叠所选照片: one new `stack_id`, the **first** id in the caller's order becomes 置顶
    /// (`stack_rank = 0`), the rest get 1…n.
    ///
    /// The caller passes the display order (the grid/filmstrip/photo-list order), because that is
    /// what the user means by "the first of these". Photos already in another stack are *moved*:
    /// their old stacks are repaired below (a stack that lost its top promotes its first remaining
    /// member; a stack left with a single member dissolves), in the same transaction.
    ///
    /// 487 — the stack's **kind** is decided here, before the rows are written, by the one rule in
    /// `StackKind.forMemberFilenames`. A two-member `[L.dng, L-denoised.dng]` is `.denoise`; every
    /// other shape is `.plain`. The kind is written onto every member (the columns are the only
    /// storage: there is no `stacks` table), so it dies with the last member.
    ///
    /// `alignDenoiseEdits` is `true` for a user restack: a newly made denoise pair then aligns its
    /// two documents by history time (`alignDenoisePair`). The synthetic-result entry point
    /// (`makeStack(resultAssetID:participantIDs:)`) passes `false`, because there the product's
    /// document deliberately carries decoder/NR overrides the original must not inherit.
    ///
    /// Returns nil when fewer than two of the ids exist — a "stack of one" is not a stack.
    @discardableResult
    public func makeStack(assetIDs: [String], alignDenoiseEdits: Bool = true) throws -> StackSummary? {
        var seen = Set<String>()
        var unique: [String] = []
        for id in assetIDs where seen.insert(id).inserted { unique.append(id) }
        guard unique.count >= 2 else { throw StackError.notEnoughPhotos }

        let summary = try dbQueue.write { db -> StackSummary? in
            let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
            let live = Set(try String.fetchAll(db, sql: """
                SELECT id FROM assets WHERE id IN (\(marks)) AND deleted = 0
                """, arguments: StatementArguments(unique)))
            let ordered = unique.filter { live.contains($0) }
            guard ordered.count >= 2 else { return nil }

            // 487 §2.1-2: recognition is a property of the members' filenames, decided before the
            // write so the kind and the membership land in the same transaction.
            let liveMarks = Array(repeating: "?", count: ordered.count).joined(separator: ", ")
            let filenames = try String.fetchAll(db, sql: """
                SELECT filename FROM assets WHERE id IN (\(liveMarks))
                """, arguments: StatementArguments(ordered))
            let kind = StackKind.forMemberFilenames(filenames)

            let stackID = UUID().uuidString
            let oldStacks = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT stack_id FROM assets
                WHERE id IN (\(marks)) AND stack_id IS NOT NULL
                """, arguments: StatementArguments(ordered)))
            for (rank, assetID) in ordered.enumerated() {
                try db.execute(sql: """
                    UPDATE assets SET stack_id = ?, stack_rank = ?, stack_kind = ? WHERE id = ?
                    """, arguments: [stackID, rank, kind.rawValue, assetID])
            }
            for old in oldStacks { try Self.repairStack(old, in: db) }
            // Return the summary in **display order**, not in the caller's order: `StackSummary`
            // describes the stack (which is ordered by capture time), while the caller's order only
            // decided which photo got rank 0. One summary shape for every reader, or the projection
            // and the command report would disagree about `memberIDs`.
            let rows = try Asset.fetchAll(db, sql: """
                SELECT * FROM assets
                WHERE stack_id = ? AND deleted = 0
                ORDER BY (capture_time IS NULL), capture_time DESC, filename, id
                """, arguments: [stackID])
            guard let top = rows.first(where: { $0.stackRank == 0 }) else { return nil }
            return StackSummary(id: stackID, memberIDs: rows.map(\.id), topID: top.id, kind: kind)
        }

        if alignDenoiseEdits, let summary, summary.kind == .denoise {
            try alignDenoisePair(summary)
        }
        return summary
    }

    /// 487 §2.4-13 — a **restack** of a denoise pair: the later edit wins.
    ///
    /// The comparison is the same fact the history panel shows: `MAX(asset_history.created_at)`
    /// per member. The later member's current document is written to both (each with one history
    /// row, label 「重堆对齐（取自 …）」), which is the "one undo step" shape `copySettings` /
    /// `pasteSettings` already uses. Equal stamps prefer the **product** (`-denoised`), because that
    /// is the member the user thinks of as the stack's subject; a member whose document is already
    /// identical is skipped, so the alignment never adds a no-op row.
    private func alignDenoisePair(_ summary: StackSummary) throws {
        let members = try dbQueue.read { db -> [(id: String, filename: String, last: String?)] in
            let marks = Array(repeating: "?", count: summary.memberIDs.count).joined(separator: ", ")
            return try Row.fetchAll(db, sql: """
                SELECT a.id, a.filename,
                       (SELECT MAX(h.created_at) FROM asset_history h WHERE h.asset_id = a.id) AS last
                FROM assets a WHERE a.id IN (\(marks))
                """, arguments: StatementArguments(summary.memberIDs)).map {
                    ($0["id"] as String, $0["filename"] as String, $0["last"] as String?)
                }
        }
        guard members.count == 2 else { return }

        func stamp(_ raw: String?) -> Date { raw.flatMap(ISO8601.date(from:)) ?? .distantPast }
        let first = members[0], second = members[1]
        let firstTime = stamp(first.last), secondTime = stamp(second.last)
        let winner: (id: String, filename: String, last: String?)
        if firstTime > secondTime {
            winner = first
        } else if secondTime > firstTime {
            winner = second
        } else {
            // Same write (or both never edited): the product is the subject of the stack.
            winner = (second.filename as NSString).deletingPathExtension.hasSuffix("-denoised")
                ? second : first
        }

        let document = try develop(forAsset: winner.id)
        let label = Loc.t("重堆对齐（取自 {0}）", winner.filename)
        for member in members where member.id != winner.id {
            guard try develop(forAsset: member.id) != document else { continue }
            try appendDevelop(document, label: label, forAsset: member.id)
        }
    }

    /// 487 §2.2-4/5 — write one edit to the other member of a denoise stack.
    ///
    /// This is the **only** propagation door. It is a no-op (`nil`) when the asset is in no stack,
    /// the stack is not `.denoise`, the stack does not have exactly two live members, or the sibling
    /// already holds exactly this document. The last check is what stops A→B→A feedback: writing a
    /// document the sibling already has adds no history row at all.
    @discardableResult
    public func propagateDenoiseEdit(_ edit: EditModel, fromAsset id: String,
                                     label: String = Catalog.denoiseLinkLabel) throws -> DevelopSaveResult? {
        guard let sibling = try denoiseSibling(ofAsset: id) else { return nil }
        guard try develop(forAsset: sibling) != edit else { return nil }
        return try appendDevelop(edit, label: label, forAsset: sibling)
    }

    /// 487 — the history label of an edit that crossed to the sibling member.
    public static let denoiseLinkLabel = Loc.t("降噪联动")

    /// 取消堆叠 for these stacks: every member goes back to `stack_id = NULL, stack_rank = 0`, and
    /// its `stack_kind` to `plain` (487: the kind is a property of the stack, not the photo).
    /// Returns the number of rows that moved.
    @discardableResult
    public func ungroup(stackIDs: [String]) throws -> Int {
        let unique = Array(Set(stackIDs))
        guard !unique.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
        return try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET stack_id = NULL, stack_rank = 0, stack_kind = 'plain'
                WHERE stack_id IN (\(marks))
                """, arguments: StatementArguments(unique))
            return db.changesCount
        }
    }

    /// 取消堆叠 — by asset: every photo in a stack the selection touches leaves **with its whole
    /// stack**, because "ungroup the stack" is the verb the menu offers (a member on its own is not
    /// what the user is looking at; the visible card is the stack).
    @discardableResult
    public func ungroup(assetIDs: [String]) throws -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: assetIDs.count).joined(separator: ", ")
        let stacks = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT stack_id FROM assets
                WHERE id IN (\(marks)) AND stack_id IS NOT NULL
                """, arguments: StatementArguments(assetIDs))
        }
        return try ungroup(stackIDs: stacks)
    }

    /// 设为置顶: the chosen member becomes rank 0 and the old top takes **the chosen member's old
    /// rank** — a swap, not a re-numbering, so the rest of the stack's order is unchanged.
    ///
    /// Three statements in one transaction, not one `CASE`: the partial unique index is checked as
    /// SQLite walks the UPDATE, so a single-statement swap would be rejected at whichever row it
    /// visited second. The old top is parked on a rank above every existing one (the index only
    /// constrains `0`), the chosen row is promoted, and the parked row takes the freed rank — so
    /// "exactly one 置顶" holds after every statement, and no rank is ever negative.
    ///
    /// A soft-deleted former top is parked and stays parked (a nonzero rank): the stack has one live
    /// 置顶 again, and restoring the deleted row cannot collide with it.
    @discardableResult
    public func setStackTop(stackID: String, assetID: String) throws -> Bool {
        try dbQueue.write { db -> Bool in
            let members = try Row.fetchAll(db, sql: """
                SELECT id, stack_rank FROM assets WHERE stack_id = ? AND deleted = 0
                """, arguments: [stackID])
            guard !members.isEmpty else { throw StackError.noSuchStack(stackID) }
            guard let chosen = members.first(where: { ($0["id"] as String) == assetID }) else {
                throw StackError.assetNotInStack(assetID: assetID, stackID: stackID)
            }
            let chosenRank: Int = chosen["stack_rank"]
            guard chosenRank != 0 else { return false }        // already 置顶: no write, no revision
            let oldTopID: String? = members.first { ($0["stack_rank"] as Int) == 0 }.map { $0["id"] }
            try Self.parkTopRows(stackID: stackID, in: db)
            try db.execute(sql: "UPDATE assets SET stack_rank = 0 WHERE id = ?", arguments: [assetID])
            if let oldTopID {
                try db.execute(sql: "UPDATE assets SET stack_rank = ? WHERE id = ?",
                               arguments: [chosenRank, oldTopID])
            }
            return true
        }
    }

    /// Move every rank-0 row of one stack out of the way (including soft-deleted ones, which the
    /// partial unique index still sees). The caller then promotes exactly one row to 0; a parked row
    /// that keeps a nonzero rank is harmless — rank only means "0 is the top".
    @discardableResult
    static func parkTopRows(stackID: String, in db: Database) throws -> Int {
        let zeros = try String.fetchAll(db, sql: """
            SELECT id FROM assets WHERE stack_id = ? AND stack_rank = 0 ORDER BY id
            """, arguments: [stackID])
        guard !zeros.isEmpty else { return 0 }
        var next = (try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(stack_rank), 0) FROM assets WHERE stack_id = ?
            """, arguments: [stackID]) ?? 0) + 1
        for id in zeros {
            try db.execute(sql: "UPDATE assets SET stack_rank = ? WHERE id = ?",
                           arguments: [next, id])
            next += 1
        }
        return zeros.count
    }

    /// Keep one stack self-consistent after rows left it (deleted, or moved to another stack):
    ///
    /// * nothing left → nothing to do (the stack is gone by construction);
    /// * exactly one left → dissolve it (`stack_id = NULL, stack_rank = 0`), because a stack of one
    ///   is a residue nobody asked for;
    /// * more than one and no rank 0 → the **first live member in display order** becomes 置顶.
    ///
    /// Rows left behind by a soft delete (`deleted = 1`, still holding the id) are counted the way
    /// the partial unique index counts them, but they never become 置顶 and they are dissolved with
    /// the rest: the index constrains every row, live or not.
    ///
    /// Runs inside the caller's transaction. The hard-delete path reaches the same rule through the
    /// v6 trigger, so a plain `DELETE FROM assets` (any caller, any future feature) cannot leave a
    /// stack without a top.
    static func repairStack(_ stackID: String, in db: Database) throws {
        let members = try Row.fetchAll(db, sql: """
            SELECT id, stack_rank, deleted FROM assets
            WHERE stack_id = ?
            ORDER BY deleted, (capture_time IS NULL), capture_time DESC, filename, id
            """, arguments: [stackID])
        switch members.count {
        case 0:
            return
        case 1:
            try db.execute(sql: """
                UPDATE assets SET stack_id = NULL, stack_rank = 0, stack_kind = 'plain'
                WHERE stack_id = ?
                """, arguments: [stackID])
        default:
            guard !members.contains(where: { ($0["stack_rank"] as Int) == 0 }) else { return }
            guard let firstLive = members.first(where: { ($0["deleted"] as Int) == 0 }) else { return }
            let firstID: String = firstLive["id"]
            try db.execute(sql: "UPDATE assets SET stack_rank = 0 WHERE id = ?", arguments: [firstID])
        }
    }
}
