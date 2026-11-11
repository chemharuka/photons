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
public struct StackSummary: Equatable, Sendable {
    /// The stack's id (`assets.stack_id`).
    public let id: String
    /// Member asset ids in display order, **including the top**.
    public let memberIDs: [String]
    /// The 置顶 member — the one every browser shows for this stack.
    public let topID: String

    public init(id: String, memberIDs: [String], topID: String) {
        self.id = id
        self.memberIDs = memberIDs
        self.topID = topID
    }

    public var count: Int { memberIDs.count }
}

public enum StackError: LocalizedError, Equatable {
    case noSuchStack(String)
    case notEnoughPhotos
    case assetNotInStack(assetID: String, stackID: String)

    public var errorDescription: String? {
        switch self {
        case .noSuchStack(let id): return "没有这个堆叠：\(id)"
        case .notEnoughPhotos: return "堆叠至少需要两张照片"
        case .assetNotInStack(let assetID, let stackID):
            return "照片 \(assetID) 不在堆叠 \(stackID) 里"
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
        return StackSummary(id: stackID, memberIDs: members.map(\.id), topID: top.id)
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
    /// Returns nil when fewer than two of the ids exist — a "stack of one" is not a stack.
    @discardableResult
    public func makeStack(assetIDs: [String]) throws -> StackSummary? {
        var seen = Set<String>()
        var unique: [String] = []
        for id in assetIDs where seen.insert(id).inserted { unique.append(id) }
        guard unique.count >= 2 else { throw StackError.notEnoughPhotos }

        return try dbQueue.write { db -> StackSummary? in
            let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
            let live = Set(try String.fetchAll(db, sql: """
                SELECT id FROM assets WHERE id IN (\(marks)) AND deleted = 0
                """, arguments: StatementArguments(unique)))
            let ordered = unique.filter { live.contains($0) }
            guard ordered.count >= 2 else { return nil }

            let stackID = UUID().uuidString
            let oldStacks = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT stack_id FROM assets
                WHERE id IN (\(marks)) AND stack_id IS NOT NULL
                """, arguments: StatementArguments(ordered)))
            for (rank, assetID) in ordered.enumerated() {
                try db.execute(sql: "UPDATE assets SET stack_id = ?, stack_rank = ? WHERE id = ?",
                               arguments: [stackID, rank, assetID])
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
            return StackSummary(id: stackID, memberIDs: rows.map(\.id), topID: top.id)
        }
    }

    /// 取消堆叠 for these stacks: every member goes back to `stack_id = NULL, stack_rank = 0`.
    /// Returns the number of rows that moved.
    @discardableResult
    public func ungroup(stackIDs: [String]) throws -> Int {
        let unique = Array(Set(stackIDs))
        guard !unique.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
        return try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET stack_id = NULL, stack_rank = 0 WHERE stack_id IN (\(marks))
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
            try db.execute(sql: "UPDATE assets SET stack_id = NULL, stack_rank = 0 WHERE stack_id = ?",
                           arguments: [stackID])
        default:
            guard !members.contains(where: { ($0["stack_rank"] as Int) == 0 }) else { return }
            guard let firstLive = members.first(where: { ($0["deleted"] as Int) == 0 }) else { return }
            let firstID: String = firstLive["id"]
            try db.execute(sql: "UPDATE assets SET stack_rank = 0 WHERE id = ?", arguments: [firstID])
        }
    }
}
