import Foundation
import GRDB

/// 合成结果 + 参与的原帧组成一个**新堆叠**，且参与的原帧先**抽离**它们原来的堆叠（§384）。
///
/// Two facts make this file necessary instead of a one-line call:
///
/// 1. `makeStack` already *moves* photos out of their old stacks, but it repairs the leftovers with
///    `repairStack`, which only promotes a **missing** 置顶 — it never re-numbers. A stack that lost
///    its rank 0 and its rank 2 keeps ranks 1/3/4: a rank hole, and (when the removed photo was not
///    the top) a stack whose 置顶 is still the photo the user just took out. So the extraction has to
///    happen **first**, explicitly, before `makeStack` ever sees the ids.
/// 2. 「结果为置顶」 is not a second write: `makeStack` gives rank 0 to the **first id in the caller's
///    array** (`Stacks.swift:144-147`), so the caller only has to put the merged asset first. That
///    ordering lives in exactly one place — `makeHDRStack` below — which is what makes the reverse
///    gate (§3 ⑩) one-line wide.
extension Catalog {

    /// Take `assetIDs` out of whatever stacks they sit in, leaving every stack they leave behind
    /// self-consistent.
    ///
    /// For each distinct stack touched: the chosen rows go to `stack_id = NULL, stack_rank = 0`, then
    /// the remaining members are re-numbered `rank = 0…n-1` **in display order** (the same
    /// `capture_time DESC, filename, id` order `StackSummary.memberIDs` reports, so "the first
    /// remaining member" means the same thing everywhere), and a stack left with a single member
    /// dissolves — a stack of one is a residue nobody asked for (`repairStack`'s own rule).
    ///
    /// Why the parking pass: the partial unique index constrains `stack_rank = 0` only, but
    /// re-numbering in place can still collide on *non-zero* ranks (row A holds 1, row B is about to
    /// take 1). Parking every row of the stack above every existing rank first makes 0…n-1 free, so
    /// the pass cannot be rejected half way through — one transaction, and no constraint error the
    /// user would see as "HDR 合成失败".
    ///
    /// Soft-deleted rows (`deleted = 1`) stay in the stack, parked at a non-zero rank: they count for
    /// the index and must never hold 置顶, exactly as `repairStack` treats them.
    ///
    /// Returns how many of the named rows left their stack.
    @discardableResult
    public func extractFromStacks(assetIDs: [String]) throws -> Int {
        let unique = Array(Set(assetIDs))
        guard !unique.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")

        return try dbQueue.write { db -> Int in
            let stacks = try String.fetchAll(db, sql: """
                SELECT DISTINCT stack_id FROM assets
                WHERE id IN (\(marks)) AND stack_id IS NOT NULL
                """, arguments: StatementArguments(unique))
            var moved = 0

            for stack in stacks {
                let args: [any DatabaseValueConvertible] = [stack] + unique.map { $0 }

                // 1. The named photos leave.
                try db.execute(sql: """
                    UPDATE assets SET stack_id = NULL, stack_rank = 0
                    WHERE stack_id = ? AND id IN (\(marks))
                    """, arguments: StatementArguments(args))
                moved += db.changesCount

                // 2. What is left: one member ⇒ dissolve; more ⇒ re-number in display order.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, deleted FROM assets
                    WHERE stack_id = ?
                    ORDER BY deleted, (capture_time IS NULL), capture_time DESC, filename, id
                    """, arguments: [stack])
                if rows.count <= 1 {
                    try db.execute(sql: """
                        UPDATE assets SET stack_id = NULL, stack_rank = 0 WHERE stack_id = ?
                        """, arguments: [stack])
                    continue
                }
                // Park every row first (non-zero ranks are unconstrained), then hand out 0…n-1.
                for (i, row) in rows.enumerated() {
                    try db.execute(sql: "UPDATE assets SET stack_rank = ? WHERE id = ?",
                                   arguments: [1_000_000 + i, row["id"] as String])
                }
                var rank = 0
                for row in rows where (row["deleted"] as Int) == 0 {
                    try db.execute(sql: "UPDATE assets SET stack_rank = ? WHERE id = ?",
                                   arguments: [rank, row["id"] as String])
                    rank += 1
                }
            }
            return moved
        }
    }

    /// 合成结果置顶 + 参与的原帧抽离旧堆叠，**这个顺序**：
    ///
    /// 1. `extractFromStacks(participantIDs)` — the old stacks are re-numbered before anyone joins a
    ///    new one, so nothing is left for `repairStack` to guess;
    /// 2. `makeStack([result] + participants)` — the merged asset is **first**, which is what makes it
    ///    rank 0 without a second `setStackTop` write.
    ///
    /// Returns the new stack, whose `topID` is `resultAssetID`.
    @discardableResult
    public func makeHDRStack(resultAssetID: String, participantIDs: [String]) throws -> StackSummary? {
        try extractFromStacks(assetIDs: participantIDs)
        return try makeStack(assetIDs: [resultAssetID] + participantIDs)
    }
}
