import Foundation
import GRDB
import PhotonsCore

// The develop document lands in the catalog (D9: `develop_json` is the only truth; XMP is derived).
//
// Before this file, an edit lived in memory only: `EditHistory` (PhotonsCore, c50d2a7) knew how to be
// a snapshot stack, and `asset_history` had been in the schema since v1, but nothing ever wrote
// either. Closing the library threw the edit away.
//
// Three invariants, each enforced by a test:
//
//  1. **The blob is canonical.** `develop_json` is always `JSONEncoder` with `.sortedKeys` and no
//     whitespace. Byte-stability is not cosmetic: `ThumbnailCache` hashes this text into its key, and
//     "did the document change?" is answered by comparing strings.
//  2. **A damaged blob is never repaired.** If it does not decode it is copied verbatim into
//     `develop_quarantine`, the asset reads as `.neutral`, and `developDecodeFailures` moves. The
//     user's bytes survive so a later build (or a human with `sqlite3`) can recover what they meant.
//  3. **One write is one transaction.** The current blob, the new history rows and the cursor land
//     together or not at all — a half-written stack would undo into states that never existed.

// MARK: - value types

/// How the stored document for one asset reads right now.
public struct DevelopState: Sendable, Equatable {
    public var assetId: String
    public var edit: EditModel
    public var developVersion: Int
    public var editTime: String?
    /// `assets.history_end`: the seq currently on screen. 0 when nothing has been written.
    public var historyEnd: Int
    /// True when the blob was missing or would not decode, so `edit` is `.neutral` and the original
    /// bytes (if there were any) are in `develop_quarantine`.
    public var recovered: Bool

    public init(assetId: String, edit: EditModel, developVersion: Int, editTime: String?,
                historyEnd: Int, recovered: Bool) {
        self.assetId = assetId
        self.edit = edit
        self.developVersion = developVersion
        self.editTime = editTime
        self.historyEnd = historyEnd
        self.recovered = recovered
    }
}

/// What a save actually did — the CLI prints it, tests assert on it.
public struct DevelopSaveResult: Sendable, Equatable {
    public var assetId: String
    public var developVersion: Int
    public var editTime: String?
    /// Cursor after the save: the seq of the state that is now current (`assets.history_end`). This is
    /// the row the caller just wrote — it is the tip only when the cursor is at the tip.
    public var historySeq: Int
    /// Highest seq in the stack now (the tip), which can differ from `historySeq` after an undo.
    public var historyTipSeq: Int
    /// Rows in `asset_history` for this asset after the write.
    public var historyRows: Int
    /// False when the canonical blob was already exactly this text: no version bump, no new row.
    public var changed: Bool
}

/// One piece of quarantined evidence, as stored.
public struct QuarantinedDevelop: Sendable, Equatable {
    public var id: Int64
    public var assetId: String
    /// The blob, byte for byte. Never rewritten, never "cleaned up".
    public var developJson: String
    public var developVersion: Int
    public var reason: String
    public var quarantinedAt: String
}

public enum DevelopError: LocalizedError {
    case noSuchAsset(String)
    /// `edit` and the history's current state disagree. Writing both would persist a document whose
    /// blob says one thing and whose cursor says another.
    case historyInconsistent(assetId: String)
    case emptyHistory(String)
    case notEncodable(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchAsset(let id): return "no asset with id \(id)"
        case .historyInconsistent(let id):
            return "develop history for \(id) is not at the document being saved; commit the edit first"
        case .emptyHistory(let id): return "refusing to save an empty history for \(id)"
        case .notEncodable(let m): return "could not encode the develop document: \(m)"
        }
    }
}

/// A counter a UI can read from any thread. `Catalog` holds one for develop decode failures.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int

    init(_ start: Int = 0) { count = start }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }
}

// MARK: - reading

extension Catalog {

    /// Canonical JSON for a value that goes into the catalog.
    ///
    /// Sorted keys, no whitespace, no pretty printing: two processes writing the same value must
    /// produce the same bytes, because the thumbnail cache keys on this text. One encoder for
    /// `assets.develop_json` and `presets.develop_json` — two encoders would eventually disagree.
    static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            guard let s = String(data: data, encoding: .utf8) else {
                throw DevelopError.notEncodable("not UTF-8")
            }
            return s
        } catch let e as DevelopError {
            throw e
        } catch {
            throw DevelopError.notEncodable(error.localizedDescription)
        }
    }

    /// Canonical bytes for `assets.develop_json`.
    public static func encode(_ edit: EditModel) throws -> String {
        try canonicalJSON(edit)
    }

    /// Canonical bytes for `presets.develop_json` (the preset envelope, §v4 in Schema.swift).
    public static func encode(_ preset: Preset) throws -> String {
        try canonicalJSON(preset)
    }

    /// Why a blob failed, or the document it decodes to.
    ///
    /// `EditModel.init(from:)` is deliberately forgiving: a missing or mistyped key falls back to that
    /// field's default instead of failing the whole document, so the only blobs that reach `.failed`
    /// are the ones that are not JSON objects at all (`""`, `"not json"`, `"[]"`, `"null"`). That is
    /// exactly the damage worth quarantining — a partially-written row from a killed process.
    enum DevelopDecode {
        case decoded(EditModel)
        case failed(String)
    }

    static func decodeDevelop(_ json: String) -> DevelopDecode {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("empty blob") }
        do {
            return .decoded(try JSONDecoder().decode(EditModel.self, from: Data(trimmed.utf8)))
        } catch {
            return .failed("\(error)")
        }
    }

    /// The document for one asset, always usable.
    ///
    /// A missing row, an empty blob or a blob that will not decode all read as `.neutral` and bump
    /// `developDecodeFailures`; a damaged blob is also copied into `develop_quarantine` first. The
    /// alternative (throwing) would make one bad row poison a whole batch read.
    public func develop(forAsset id: String) throws -> EditModel {
        try developState(forAsset: id).edit
    }

    /// `develop(forAsset:)` plus the version bookkeeping the CLI and the UI want.
    public func developState(forAsset id: String) throws -> DevelopState {
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT develop_json, develop_version, edit_time, history_end
                FROM assets WHERE id = ?
                """, arguments: [id])
        }
        guard let row else {
            // No row at all: nothing to quarantine, but the caller still gets a document it can render
            // and the counter still moves (a view asking for a deleted asset should not crash).
            developFailureCounter.increment()
            return DevelopState(assetId: id, edit: .neutral, developVersion: 0, editTime: nil,
                                historyEnd: 0, recovered: true)
        }
        let json: String = row["develop_json"]
        let version: Int = row["develop_version"]
        let editTime: String? = row["edit_time"]
        let historyEnd: Int = row["history_end"]

        switch Self.decodeDevelop(json) {
        case .decoded(let edit):
            return DevelopState(assetId: id, edit: edit, developVersion: version, editTime: editTime,
                                historyEnd: historyEnd, recovered: false)
        case .failed(let reason):
            try quarantine(assetId: id, developJSON: json, developVersion: version, reason: reason)
            developFailureCounter.increment()
            return DevelopState(assetId: id, edit: .neutral, developVersion: version, editTime: editTime,
                                historyEnd: historyEnd, recovered: true)
        }
    }

    /// The snapshot stack for one asset, `seq` ascending — one row is one `Snapshot`, 1:1.
    ///
    /// A row whose blob does not decode cannot be restored as a state, so it is quarantined and
    /// **left out** of the stack rather than replaced with `.neutral`: substituting a neutral document
    /// in the middle of an undo stack would let a user undo into a state they never had.
    public func historyRows(forAsset id: String) throws -> [EditHistory.Snapshot] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, label, develop_json, created_at
                FROM asset_history WHERE asset_id = ? ORDER BY seq
                """, arguments: [id])
        }
        var out: [EditHistory.Snapshot] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let seq: Int = row["seq"]
            let json: String = row["develop_json"]
            let label: String? = row["label"]
            let createdAt: String = row["created_at"]
            switch Self.decodeDevelop(json) {
            case .decoded(let edit):
                out.append(EditHistory.Snapshot(seq: seq, label: label ?? "", edit: edit,
                                                createdAt: ISO8601.date(from: createdAt) ?? .distantPast))
            case .failed(let reason):
                try quarantine(assetId: id, developJSON: json, developVersion: 0,
                               reason: "history seq \(seq): \(reason)")
                developFailureCounter.increment()
            }
        }
        return out
    }

    /// The whole stack with its persisted cursor — what a document open wants, instead of
    /// `EditHistory(baseline:)`, which would flatten history to a single "Original" row.
    public func editHistory(forAsset id: String) throws -> EditHistory {
        let state = try developState(forAsset: id)
        let rows = try historyRows(forAsset: id)
        let cursor = rows.contains { $0.seq == state.historyEnd } ? state.historyEnd : nil
        return EditHistory(rows: rows, cursorSeq: cursor)
    }

    // MARK: quarantine

    /// Copy a damaged blob aside. Idempotent: the same damaged text for the same asset is one piece
    /// of evidence no matter how many times it is read (`developDecodeFailures` still counts reads).
    @discardableResult
    func quarantine(assetId: String, developJSON: String, developVersion: Int, reason: String) throws -> Bool {
        let stamp = ISO8601.now()
        return try dbQueue.write { db in
            let known = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM develop_quarantine WHERE asset_id = ? AND develop_json = ?
                """, arguments: [assetId, developJSON]) ?? 0
            if known > 0 { return false }
            try db.execute(sql: """
                INSERT INTO develop_quarantine(asset_id, develop_json, develop_version, reason, quarantined_at)
                VALUES(?, ?, ?, ?, ?)
                """, arguments: [assetId, developJSON, developVersion, reason, stamp])
            return true
        }
    }

    /// Everything parked, newest last. `assetId` nil returns the whole table.
    public func quarantinedDevelop(forAsset assetId: String? = nil) throws -> [QuarantinedDevelop] {
        try dbQueue.read { db in
            let sql = assetId == nil
                ? "SELECT * FROM develop_quarantine ORDER BY id"
                : "SELECT * FROM develop_quarantine WHERE asset_id = ? ORDER BY id"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(assetId.map { [$0] } ?? []))
            return rows.map { row in
                QuarantinedDevelop(id: row["id"],
                                   assetId: row["asset_id"],
                                   developJson: row["develop_json"],
                                   developVersion: row["develop_version"],
                                   reason: row["reason"],
                                   quarantinedAt: row["quarantined_at"])
            }
        }
    }

    public func developQuarantineCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM develop_quarantine") ?? 0 }
    }

    // MARK: writing

    /// Commit a state: the current blob, the new history rows and the cursor, in **one** transaction.
    ///
    /// - `edit` must be the history's current snapshot (`history.commit(edit)` first). Anything else
    ///   means the caller would persist a blob that disagrees with its own cursor, so it throws
    ///   `DevelopError.historyInconsistent` before touching the database.
    /// - Rows already on disk are never rewritten (history never rewrites the past, D10); only new
    ///   seqs are inserted.
    /// - Rows **inside the live window** that the stack no longer contains are deleted. After an undo
    ///   and a fresh commit the abandoned redo branch is exactly such a row — and because `seq` is
    ///   never reused (History.swift), it is a *hole* in the middle, not a suffix, so a `seq > tip`
    ///   delete would miss it. Rows the stack evicted by depth (below its oldest seq) are kept: the
    ///   database is the archive, the in-memory depth limit is not a licence to destroy history.
    /// - `develop_version` bumps only when the canonical blob actually changed, so re-saving an
    ///   identical document (or fixing only a label) does not invalidate every cached render.
    @discardableResult
    public func saveDevelop(_ edit: EditModel, history: EditHistory, forAsset id: String) throws -> DevelopSaveResult {
        guard !history.isEmpty else { throw DevelopError.emptyHistory(id) }
        if let current = history.current, current != edit {
            throw DevelopError.historyInconsistent(assetId: id)
        }
        let blob = try Self.encode(edit)
        let stamp = ISO8601.now()

        // Encode outside the transaction's write path: a document that will not encode should fail
        // before anything is locked, and the bytes are reused for every row that needs them.
        var encoded: [Int: String] = [:]
        for snap in history.snapshots where snap.edit != edit { encoded[snap.seq] = try Self.encode(snap.edit) }
        let live = history.snapshots
        let firstSeq = live[0].seq
        let tipSeq = live[live.count - 1].seq
        let cursorSeq = history.currentSeq ?? tipSeq
        let keepSQL = live.map { _ in "?" }.joined(separator: ", ")
        var keepArgs: [any DatabaseValueConvertible] = [id, firstSeq]
        keepArgs.append(contentsOf: live.map(\.seq))

        return try dbQueue.write { db in
            guard let stored = try Row.fetchOne(db, sql: """
                SELECT develop_json, develop_version, edit_time FROM assets WHERE id = ?
                """, arguments: [id]) else {
                throw DevelopError.noSuchAsset(id)
            }
            let oldBlob: String = stored["develop_json"]
            let oldVersion: Int = stored["develop_version"]
            let oldEditTime: String? = stored["edit_time"]

            // 1. Drop the states the stack no longer holds, within the window it covers.
            try db.execute(sql: """
                DELETE FROM asset_history
                WHERE asset_id = ? AND seq >= ? AND seq NOT IN (\(keepSQL))
                """, arguments: StatementArguments(keepArgs))

            // 2. New rows only. An existing seq keeps its bytes even if the label would differ today.
            for snap in history.snapshots {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM asset_history WHERE asset_id = ? AND seq = ?
                    """, arguments: [id, snap.seq]) ?? 0
                if exists > 0 { continue }
                let json = snap.edit == edit ? blob : (encoded[snap.seq] ?? blob)
                try db.execute(sql: """
                    INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                    VALUES(?, ?, ?, ?, ?)
                    """, arguments: [id, snap.seq, json, snap.label, ISO8601.string(from: snap.createdAt)])
            }

            // 3. The current document. `edit_time` records a real write, so it stays put when the save
            //    was a no-op — "when was this last edited" must not move because someone re-saved.
            let changed = oldBlob != blob
            let newVersion = changed ? oldVersion + 1 : oldVersion
            let newEditTime = changed ? stamp : oldEditTime
            if changed {
                try db.execute(sql: """
                    UPDATE assets SET develop_json = ?, develop_version = ?, edit_time = ?, history_end = ?
                    WHERE id = ?
                    """, arguments: [blob, newVersion, newEditTime, cursorSeq, id])
            } else {
                try db.execute(sql: "UPDATE assets SET history_end = ? WHERE id = ?",
                               arguments: [cursorSeq, id])
            }

            let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                                            arguments: [id]) ?? 0
            return DevelopSaveResult(assetId: id, developVersion: newVersion, editTime: newEditTime,
                                     historySeq: cursorSeq, historyTipSeq: tipSeq,
                                     historyRows: rowCount, changed: changed)
        }
    }

    /// Convenience: append `edit` to the stored stack and save it, in one call.
    ///
    /// This is the shape a slider release takes: read the stack, commit, save. It exists so the CLI and
    /// tests share one path instead of re-deriving the cursor rules.
    @discardableResult
    public func appendDevelop(_ edit: EditModel, label: String = "", forAsset id: String,
                              now: Date = Date()) throws -> DevelopSaveResult {
        var history = try editHistory(forAsset: id)
        if history.isEmpty {
            // No rows at all (a row written before history was maintained): seed the stack with the
            // document as it stands so the edit about to land has something to undo back to.
            history = EditHistory(baseline: try develop(forAsset: id), label: "Original")
        }
        history.commit(edit, label: label, now: now)
        return try saveDevelop(edit, history: history, forAsset: id)
    }
}