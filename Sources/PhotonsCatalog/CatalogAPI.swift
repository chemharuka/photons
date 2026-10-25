import Foundation
import GRDB

// MARK: - request / report types

public struct AssetFilter: Sendable {
    public var ratingAtLeast: Int?
    public var cameraKey: String?
    public var sinceLocalDate: String?
    public var sourceRootId: String?
    public var includeDeleted: Bool
    public var limit: Int

    public init(ratingAtLeast: Int? = nil, cameraKey: String? = nil, sinceLocalDate: String? = nil,
                sourceRootId: String? = nil, includeDeleted: Bool = false, limit: Int = 200) {
        self.ratingAtLeast = ratingAtLeast
        self.cameraKey = cameraKey
        self.sinceLocalDate = sinceLocalDate
        self.sourceRootId = sourceRootId
        self.includeDeleted = includeDeleted
        self.limit = limit
    }
}

public struct CatalogStats: Sendable {
    public var total = 0
    public var deleted = 0
    public var rated = 0
    public var byKind: [String: Int] = [:]
    public var byRoot: [(root: String, status: String, count: Int)] = []
    public var sessions = 0
    public var keywords = 0
    public var bytes = 0
}

public struct VerifyReport: Sendable {
    public var integrity = "unknown"
    public var assets = 0
    public var missingFiles = 0
    public var unreferencedFiles = 0
    public var importFilesWithoutAsset = 0
    public var hashMismatches = 0
    public var problems: [String] = []

    public var isClean: Bool {
        integrity == "ok" && missingFiles == 0 && unreferencedFiles == 0
            && importFilesWithoutAsset == 0 && hashMismatches == 0
    }
}

public struct ImportSummary: Sendable {
    public var sessionId = ""
    public var total = 0
    public var added = 0
    public var duplicate = 0
    public var unchanged = 0
    public var moved = 0
    public var failed = 0
    public var ignoredSidecars = 0
    public var seconds: Double = 0
    public var interrupted = false

    public init() {}

    public var text: String {
        String(format: "total %d  added %d  moved %d  duplicate %d  unchanged %d  failed %d  %.2fs",
               total, added, moved, duplicate, unchanged, failed, seconds)
    }
}

// MARK: - queries

extension Catalog {

    // MARK: roots

    public func roots() throws -> [SourceRoot] {
        try dbQueue.read { db in try SourceRoot.fetchAll(db, sql: "SELECT * FROM source_roots ORDER BY created_at") }
    }

    public func root(id: String) throws -> SourceRoot? {
        try dbQueue.read { db in try SourceRoot.fetchOne(db, key: id) }
    }

    /// Find the root that contains `path`, or create one. Volume identity is the UUID, never the
    /// mount point: a card re-inserted at a different mount path is the same root.
    public func ensureRoot(for path: URL, mode: ManagementMode) throws -> SourceRoot {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw CatalogError.importSourceMissing(path)
        }
        // Ascend to a directory: a file argument belongs to its parent folder.
        var rootURL = isDir.boolValue ? path : path.deletingLastPathComponent()
        rootURL = rootURL.standardizedFileURL

        let volumeUUID = (try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil
        let existing = try roots().first { root in
            if let v = volumeUUID, let rv = root.volumeUuid, v == rv { return true }
            return root.pathHint == rootURL.path
        }
        if var hit = existing {
            if hit.status != .online {
                hit.status = .online
                try dbQueue.write { db in try hit.update(db) }
            }
            return hit
        }

        let bookmark = try? rootURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = SourceRoot(volumeUuid: volumeUUID,
                              bookmark: bookmark,
                              displayName: rootURL.lastPathComponent,
                              pathHint: rootURL.path,
                              managementMode: mode,
                              status: .online)
        try dbQueue.write { db in try root.insert(db) }
        return root
    }

    /// Re-check every root for reachability. Offline roots keep all their rows (never delete).
    @discardableResult
    public func refreshRootStatus() throws -> [SourceRoot] {
        let fm = FileManager.default
        var out: [SourceRoot] = []
        for var root in try roots() {
            let reachable = fm.fileExists(atPath: root.pathHint, isDirectory: nil)
            let status: RootStatus = reachable ? .online : .offline
            if status != root.status {
                root.status = status
                let r = root
                try dbQueue.write { db in try r.update(db) }
            }
            out.append(root)
        }
        return out
    }

    // MARK: assets

    public func asset(id: String) throws -> Asset? {
        try dbQueue.read { db in try Asset.fetchOne(db, key: id) }
    }

    public func asset(contentHash: String) throws -> Asset? {
        try dbQueue.read { db in
            try Asset.fetchOne(db, sql: "SELECT * FROM assets WHERE content_hash = ?", arguments: [contentHash])
        }
    }

    public func assetUnchangedCandidate(quickHash: String, size: Int, mtime: Double) throws -> Asset? {
        try dbQueue.read { db in
            try Asset.fetchOne(db, sql: """
                SELECT * FROM assets WHERE quick_hash = ? AND size = ? AND mtime = ? LIMIT 1
                """, arguments: [quickHash, size, mtime])
        }
    }

    public func assets(_ filter: AssetFilter = AssetFilter()) throws -> [Asset] {
        var sql = "SELECT * FROM assets WHERE 1 = 1"
        var args: [any DatabaseValueConvertible] = []
        if !filter.includeDeleted { sql += " AND deleted = 0" }
        if let r = filter.ratingAtLeast { sql += " AND rating >= ?"; args.append(r) }
        if let c = filter.cameraKey { sql += " AND camera_key = ?"; args.append(c.lowercased()) }
        if let d = filter.sinceLocalDate { sql += " AND capture_local_date >= ?"; args.append(d) }
        if let s = filter.sourceRootId { sql += " AND source_root_id = ?"; args.append(s) }
        sql += " ORDER BY capture_time DESC, id LIMIT ?"
        args.append(filter.limit)
        return try dbQueue.read { db in
            try Asset.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func metadata(assetId: String) throws -> AssetMetadata? {
        try dbQueue.read { db in try AssetMetadata.fetchOne(db, key: assetId) }
    }

    public func keywords(assetId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT k.name FROM keywords k
                JOIN photo_keywords pk ON pk.keyword_id = k.id
                WHERE pk.asset_id = ? ORDER BY k.name
                """, arguments: [assetId])
        }
    }

    /// Resolve the on-disk location of an asset (copy roots live inside the package).
    public func fileURL(for asset: Asset) throws -> URL {
        guard let root = try root(id: asset.sourceRootId) else {
            throw CatalogError.noSuchSourceRoot(asset.sourceRootId)
        }
        let base = root.managementMode == .copy
            ? layout.originalsURL
            : URL(fileURLWithPath: root.pathHint, isDirectory: true)
        return base.appendingPathComponent(asset.relPath)
    }

    // MARK: mutations

    /// A file that moved on disk: keep the row (and its edit history), fix the location.
    public func relocate(_ asset: Asset, toRoot rootId: String, relPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE assets SET source_root_id = ?, rel_path = ?, filename = ? WHERE id = ?
                """, arguments: [rootId, relPath, (relPath as NSString).lastPathComponent, asset.id])
        }
    }

    public func setRating(_ rating: Int, forAsset id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET rating = ? WHERE id = ?", arguments: [rating, id])
        }
    }

    public func setColorLabel(_ label: String?, forAsset id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET color_label = ? WHERE id = ?", arguments: [label, id])
        }
    }

    public func setDeleted(_ deleted: Bool, forAsset id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET deleted = ? WHERE id = ?", arguments: [deleted, id])
        }
    }

    public func markChecked(_ assetIds: [String]) throws {
        guard !assetIds.isEmpty else { return }
        let stamp = ISO8601.now()
        try dbQueue.write { db in
            for id in assetIds {
                try db.execute(sql: "UPDATE assets SET checked_at = ? WHERE id = ?", arguments: [stamp, id])
            }
        }
    }

    // MARK: stats

    public func stats() throws -> CatalogStats {
        // Root reachability is a derived fact; re-derive it on every report rather than trusting a
        // status written at import time (a card can be unplugged between commands).
        _ = try refreshRootStatus()
        return try dbQueue.read { db in
            var s = CatalogStats()
            s.total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE deleted = 0") ?? 0
            s.deleted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE deleted = 1") ?? 0
            s.rated = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE deleted = 0 AND rating > 0") ?? 0
            s.sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_sessions") ?? 0
            s.keywords = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM keywords") ?? 0
            s.bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM assets WHERE deleted = 0") ?? 0
            for row in try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM assets WHERE deleted = 0 GROUP BY kind") {
                s.byKind[row["kind"]] = row["n"]
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT r.display_name AS name, r.status AS status, COUNT(a.id) AS n
                FROM source_roots r LEFT JOIN assets a ON a.source_root_id = r.id AND a.deleted = 0
                GROUP BY r.id ORDER BY r.created_at
                """) {
                s.byRoot.append((row["name"], row["status"], row["n"]))
            }
            return s
        }
    }

    // MARK: verify

    public func verify(rehash: Bool = false) throws -> VerifyReport {
        _ = try refreshRootStatus()
        var report = VerifyReport()
        report.integrity = try integrityCheck()

        let onlineRoots = try roots()
        let fm = FileManager.default
        let allAssets = try dbQueue.read { db in try Asset.fetchAll(db) }
        report.assets = allAssets.count

        var referenced: Set<String> = []
        for asset in allAssets {
            guard let root = onlineRoots.first(where: { $0.id == asset.sourceRootId }) else { continue }
            let url: URL
            if root.managementMode == .copy {
                url = layout.originalsURL.appendingPathComponent(asset.relPath)
                referenced.insert(url.standardizedFileURL.path)
            } else {
                url = URL(fileURLWithPath: root.pathHint, isDirectory: true).appendingPathComponent(asset.relPath)
            }
            if root.status == .offline { continue }
            if !fm.fileExists(atPath: url.path) {
                report.missingFiles += 1
                if report.problems.count < 20 { report.problems.append("missing: \(asset.relPath)") }
                continue
            }
            if rehash {
                let actual = try? FileHasher.sha256(of: url)
                if let actual, actual != asset.contentHash {
                    report.hashMismatches += 1
                    if report.problems.count < 20 { report.problems.append("hash changed: \(asset.relPath)") }
                }
            }
        }

        // Files inside our own copy-mode originals/ that no row points at.
        if fm.fileExists(atPath: layout.originalsURL.path) {
            let e = fm.enumerator(at: layout.originalsURL, includingPropertiesForKeys: [.isRegularFileKey])
            while let u = e?.nextObject() as? URL {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if !referenced.contains(u.standardizedFileURL.path) {
                    report.unreferencedFiles += 1
                    if report.problems.count < 20 { report.problems.append("orphan: \(u.lastPathComponent)") }
                }
            }
        }

        report.importFilesWithoutAsset = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM import_files f
                LEFT JOIN assets a ON a.id = f.asset_id
                WHERE f.asset_id IS NOT NULL AND a.id IS NULL
                """) ?? 0
        }
        return report
    }
}
