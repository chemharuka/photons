import Foundation
import GRDB

// The library stores *references*. Once a file is moved or renamed outside Photons, the row points
// at a path that no longer exists — and before this file, nothing in the catalog could say so:
// `verify()` counted the damage, but the grid, the inspector and every query still treated the row
// as a normal photo. This file is the whole lifecycle of that fact:
//
//   · `refreshAvailability()` — recompute `assets.missing` from `stat`, on open and on rescan.
//   · `relink(assetID:to:)`   — point a row at the file's new home, **only** if the bytes are the
//                               same bytes, so "find the lost file" can never silently swap a photo.
//   · `deleteAssets(ids:)`    — the other answer: remove the entry and its modification records in
//                               one transaction, leaving every original file on disk alone.
//
// Design notes worth keeping:
//
//  1. **Missing is derived, never authoritative.** Nothing here deletes a row because a file is
//     gone. A missing flag is a question for the user ("relink, or remove the entry?"), not a
//     verdict — the same reason darktable keeps its rows and its history when a card is unplugged.
//  2. **Offline roots are skipped, not marked.** "The drive is unplugged" and "the file moved" are
//     different sentences; only the second one is actionable, and marking a whole unplugged volume
//     missing would be a lie the user cannot clear without plugging it back in.
//  3. **Relinking is identity-checked.** `content_hash` is the identity (v1's `UNIQUE`), so a
//     candidate file whose hash differs is not "the moved file" — it is a different photo that
//     happens to share a name. The caller gets a typed error, not a silent overwrite.
//  4. **Deletion is one transaction, and the cache is cleaned after it.** Rows and history land
//     together or not at all; thumbnail files are derived data, so they are removed once the commit
//     is durable (a failed file removal must never roll back a valid deletion).

// MARK: - reports

/// What one `refreshAvailability()` pass found.
public struct AvailabilityReport: Sendable, Equatable {
    /// Rows examined (assets under an online root, not soft-deleted).
    public var checked = 0
    /// Rows that are flagged `missing` after the pass.
    public var missing = 0
    /// Rows that were flagged and are present again — the file came back (or the drive re-mounted
    /// with the same layout).
    public var relinked = 0
    /// Roots skipped because they are offline. Their rows keep whatever flag they had.
    public var offlineRoots = 0

    public init() {}

    public var summary: String {
        "checked \(checked) · missing \(missing) · back \(relinked) · offline roots \(offlineRoots)"
    }
}

/// What one `deleteAssets(ids:)` call removed, table by table — the evidence a test (and a bug
/// report) needs to say "the modification records really are gone".
public struct DeleteReport: Sendable, Equatable {
    public var assets = 0
    public var history = 0
    public var metadata = 0
    public var keywords = 0
    public var albumEntries = 0
    public var quarantine = 0
    public var thumbnailFiles = 0

    public init() {}

    /// Rows removed from `assets` — the number the confirmation sheet promised.
    public var count: Int { assets }

    public var summary: String {
        "assets \(assets) · history \(history) · metadata \(metadata) · keywords \(keywords) "
            + "· album \(albumEntries) · quarantine \(quarantine) · thumbs \(thumbnailFiles)"
    }
}

public enum AvailabilityError: LocalizedError, Equatable {
    /// The candidate file's bytes are not the bytes this row was imported from.
    case contentMismatch(assetID: String, expected: String, found: String)
    /// A stated expectation the caller (or the file) did not meet.
    case notRegularFile(URL)
    case assetNotFound(String)
    case relinkConflict(path: String)

    public var errorDescription: String? {
        switch self {
        case .contentMismatch(let id, let expected, let found):
            return "文件内容与库中记录不一致（\(id)）：期望 \(expected.prefix(12))…，实际 \(found.prefix(12))…"
        case .notRegularFile(let url):
            return "不是一个文件：\(url.path)"
        case .assetNotFound(let id):
            return "库中没有这个条目：\(id)"
        case .relinkConflict(let path):
            return "已有另一个条目指向 \(path)"
        }
    }
}

// MARK: - availability

extension Catalog {

    /// Recompute `assets.missing` for every asset under an **online** root. Nothing is deleted.
    ///
    /// Called when a library opens and when the user asks for a rescan; it is one `stat` per row,
    /// which is the same cost `verify()` already pays and is the only way this fact can be true.
    /// Copy-managed roots resolve against the package's `originals/`; reference roots against the
    /// root's own `path_hint`, so relocating a library package does not mark every row missing.
    @discardableResult
    public func refreshAvailability() throws -> AvailabilityReport {
        var report = AvailabilityReport()
        let fm = FileManager.default
        let allRoots = try refreshRootStatus()
        var base: [String: (url: URL, online: Bool)] = [:]
        for root in allRoots {
            let url = root.managementMode == .copy
                ? layout.originalsURL
                : URL(fileURLWithPath: root.pathHint, isDirectory: true)
            base[root.id] = (url, root.status == .online)
            if root.status != .online { report.offlineRoots += 1 }
        }

        let rows: [(id: String, root: String, rel: String, wasMissing: Bool)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, source_root_id, rel_path, missing FROM assets WHERE deleted = 0")
                .map { ($0["id"], $0["source_root_id"], $0["rel_path"], ($0["missing"] as Int) != 0) }
        }

        var toMissing: [String] = []
        var toPresent: [String] = []
        var relinked = 0
        for row in rows {
            guard let root = base[row.root], root.online else { continue }
            report.checked += 1
            let url = root.url.appendingPathComponent(row.rel)
            let exists = fm.fileExists(atPath: url.path)
            if !exists, !row.wasMissing {
                toMissing.append(row.id)
            } else if exists, row.wasMissing {
                toPresent.append(row.id)
                relinked += 1
            }
        }
        report.relinked = relinked

        guard !toMissing.isEmpty || !toPresent.isEmpty else {
            report.missing = rows.filter { $0.wasMissing }.count
            return report
        }
        try dbQueue.write { db in
            try Self.setMissing(true, ids: toMissing, in: db)
            try Self.setMissing(false, ids: toPresent, in: db)
        }
        // Read the total back instead of doing the arithmetic twice: the flag is the truth, and a
        // report that disagrees with the table is worse than no report.
        report.missing = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE missing = 1 AND deleted = 0") ?? 0
        }
        return report
    }

    /// One `UPDATE … IN (…)` per chunk: a 10k library must not be 10k transactions (the same rule
    /// `setRating(_:forAssets:)` follows).
    private static func setMissing(_ missing: Bool, ids: [String], in db: Database) throws {
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0 ..< min($0 + 400, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var args: [any DatabaseValueConvertible] = [missing]
            args.append(contentsOf: chunk)
            try db.execute(sql: "UPDATE assets SET missing = ? WHERE id IN (\(marks))",
                           arguments: StatementArguments(args))
        }
    }

    /// Point a row at the file's new location — **only** when the bytes are identical.
    ///
    /// The check is `content_hash`, the library's identity for a photo, so this can never turn
    /// "I picked the wrong file" into a silent photo swap. Size is a cheap pre-screen (a different
    /// size cannot be the same bytes); the full SHA-256 decides.
    ///
    /// Returns the updated row, so a caller can reload it without a second query.
    @discardableResult
    public func relink(assetID: String, to url: URL) throws -> Asset {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AvailabilityError.notRegularFile(url)
        }
        guard var asset = try asset(id: assetID) else {
            throw AvailabilityError.assetNotFound(assetID)
        }
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
        if let size, size != asset.size, asset.size > 0 {
            let found = try FileHasher.sha256(of: url)
            throw AvailabilityError.contentMismatch(assetID: assetID, expected: asset.contentHash, found: found)
        }
        let hash = try FileHasher.sha256(of: url)
        guard hash == asset.contentHash else {
            throw AvailabilityError.contentMismatch(assetID: assetID, expected: asset.contentHash, found: hash)
        }

        let target = try location(of: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? asset.mtime
        let newSize = values.fileSize ?? Int(size ?? asset.size)
        let filename = url.lastPathComponent

        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE assets
                       SET source_root_id = ?, rel_path = ?, filename = ?,
                           size = ?, mtime = ?, missing = 0
                     WHERE id = ?
                    """, arguments: [target.rootID, target.relPath, filename, newSize, mtime, assetID])
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw AvailabilityError.relinkConflict(path: url.path)
        }

        asset.sourceRootId = target.rootID
        asset.relPath = target.relPath
        asset.filename = filename
        asset.size = newSize
        asset.mtime = mtime
        asset.missing = false
        return asset
    }

    /// Where a file URL lives in library terms: the deepest root that contains it, or a new
    /// reference root for the folder the user found it in.
    ///
    /// Registering the folder (rather than storing an absolute path in `rel_path`) keeps the one
    /// invariant every query depends on — `fileURL(for:)` = root + rel_path — true for relinked rows
    /// too, and it survives the folder being renamed or moved again.
    ///
    /// `ensureRoot` is deliberately **not** used here: its identity is the *volume*, which is right
    /// for an import (one card, one root) and wrong for a relink — a file recovered into
    /// `~/Pictures/Recovered` on the same disk must not be folded into the card's root and given a
    /// relative path that does not resolve.
    func location(of url: URL) throws -> (rootID: String, relPath: String) {
        let target = url.standardizedFileURL
        let roots = try roots()
        var best: (rootID: String, relPath: String, depth: Int)?
        for root in roots {
            let base = (root.managementMode == .copy
                        ? layout.originalsURL
                        : URL(fileURLWithPath: root.pathHint, isDirectory: true)).standardizedFileURL
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard target.path.hasPrefix(basePath) else { continue }
            let rel = String(target.path.dropFirst(basePath.count))
            guard !rel.isEmpty, !rel.hasPrefix("..") else { continue }
            if best == nil || basePath.count > best!.depth {
                best = (root.id, rel, basePath.count)
            }
        }
        if let best { return (best.rootID, best.relPath) }

        // Somewhere new: register the containing folder as its own reference root.
        let folder = target.deletingLastPathComponent().standardizedFileURL
        let root = try registerRoot(folder: folder)
        return (root.id, target.lastPathComponent)
    }

    /// One reference root per folder, created on demand by a relink into a folder the library has
    /// never seen. Reuses an existing root with the same `path_hint`, so relinking twenty files into
    /// one folder adds one root, not twenty.
    private func registerRoot(folder: URL) throws -> SourceRoot {
        let url = folder.standardizedFileURL
        if let existing = try roots().first(where: { $0.pathHint == url.path }) { return existing }
        let volumeUUID = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = SourceRoot(volumeUuid: volumeUUID,
                              bookmark: bookmark,
                              displayName: url.lastPathComponent,
                              pathHint: url.path,
                              managementMode: .reference,
                              status: .online)
        try dbQueue.write { db in try root.insert(db) }
        return root
    }

    // MARK: deletion

    /// Remove library entries **and** everything that hangs off them, in one transaction.
    ///
    /// Tables, explicitly and in child-first order (`asset_history`, `asset_metadata`,
    /// `photo_keywords`, `album_assets`, `develop_quarantine`, then `assets`): the schema has
    /// `ON DELETE CASCADE` on four of them, but a cascade reports no per-table count and silently
    /// changes when a future migration drops a foreign key. Explicit statements are the version that
    /// can be asserted on (`DeleteReport`) and read by somebody debugging a library.
    ///
    /// `develop_quarantine` is deleted too, deliberately: v3 keeps quarantine rows alive across
    /// *automatic* cleanups (evidence must survive a repair pass), but this is the user saying "this
    /// entry and its modification records are gone". Leaving orphans behind would make the deletion
    /// incomplete in exactly the way the confirmation text promises it will not be.
    ///
    /// Thumbnail files are removed **after** the commit: they are derived data, and a failed unlink
    /// must never roll back a deletion the user confirmed. `thumbnails` is optional because the
    /// catalog does not own the cache (the session does); when it is nil nothing is cleaned and the
    /// report says 0.
    @discardableResult
    public func deleteAssets(ids: [String], thumbnails: ThumbnailCache? = nil) throws -> DeleteReport {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return DeleteReport() }

        // Read the thumb keys before the rows go: after the delete there is nothing to derive them from.
        let doomed: [(contentHash: String, developJSON: String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT content_hash, develop_json FROM assets WHERE id IN (\(Self.marks(unique.count)))
                """, arguments: StatementArguments(unique))
                .map { ($0["content_hash"], $0["develop_json"]) }
        }

        var report = DeleteReport()
        // `dbQueue.write` **is** the transaction (GRDB wraps every write in BEGIN/COMMIT): the six
        // statements below land together or not at all. Wrapping them in a second `inTransaction`
        // would only add a savepoint, and asking SQLite for a nested BEGIN is an error.
        try dbQueue.write { db in
            report.history = try Self.delete("asset_history", assetIDs: unique, in: db)
            report.metadata = try Self.delete("asset_metadata", assetIDs: unique, in: db)
            report.keywords = try Self.delete("photo_keywords", assetIDs: unique, in: db)
            report.albumEntries = try Self.delete("album_assets", assetIDs: unique, in: db)
            report.quarantine = try Self.delete("develop_quarantine", assetIDs: unique, in: db)
            report.assets = try Self.delete("assets", assetIDs: unique, in: db, keyColumn: "id")
        }

        if let thumbnails {
            for row in doomed {
                report.thumbnailFiles += thumbnails.removeAll(contentHash: row.contentHash,
                                                             developJSONs: [row.developJSON, "{}"])
            }
        }
        return report
    }

    /// How many rows one table holds for these assets — the assertion helper the tests use to prove
    /// the cascade happened (and that the other photos are untouched). `keyColumn` exists because
    /// `assets` is keyed by `id` while every satellite table is keyed by `asset_id`.
    public func rowCount(_ table: String, assetIDs: [String], keyColumn: String = "asset_id") throws -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(keyColumn) IN (\(Self.marks(assetIDs.count)))",
                             arguments: StatementArguments(assetIDs)) ?? 0
        }
    }

    private static func delete(_ table: String, assetIDs: [String], in db: Database,
                               keyColumn: String = "asset_id") throws -> Int {
        try db.execute(sql: "DELETE FROM \(table) WHERE \(keyColumn) IN (\(marks(assetIDs.count)))",
                       arguments: StatementArguments(assetIDs))
        return db.changesCount
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
