import Foundation
import GRDB
import PhotonsCore

// MARK: - request / report types

/// One folder row in the source tree that is part of the filter (021 B).
///
/// `rootId == nil` is 「全部照片」 — the whole library, not a root — and the catalog treats it as
/// "no constraint at all": the row is what a user clicks to get *back* to everything, so it can
/// never be one clause of a union. `path` is relative to the root and `/`-separated; `nil` (or
/// `""`, or stray slashes, which `normalizedFolderPath` eats) is the root itself.
///
/// `Hashable` so the browser can build the selection as a set and hand the tree back exactly what
/// the user left highlighted: identity is `(rootId, path)`, never a row index — a `reloadData()`
/// moves rows, and restoring by index is what silently retargeted the filter in the 020 handoff.
public struct FolderSelection: Sendable, Hashable {
    public var rootId: String?
    public var path: String?

    public init(rootId: String?, path: String? = nil) {
        self.rootId = rootId
        self.path = path
    }

    /// 「全部照片」: the whole library.
    public var isAllPhotos: Bool { rootId == nil }
    /// The path with stray slashes removed; `nil` is the root itself.
    public var normalizedPath: String? { AssetFilter.normalizedFolderPath(path) }
    /// Stable identity for restoring the outline's highlight after `reloadData()`.
    public var key: String { "\(rootId ?? "*")|\(normalizedPath ?? "")" }

    /// Identity is the **canonical** `(rootId, path)`, not the raw one: `day2/`, `/day2` and `day2`
    /// are the same folder row, so a set of selections cannot hold the same row twice — and a
    /// comparison against what the session stored cannot fail because of a stray slash.
    public static func == (lhs: FolderSelection, rhs: FolderSelection) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// The 15 things a grid slot can filter by (026).
///
/// The raw values are the wire form: they go into a `FilterCriterion`, into a `facetValues` call and
/// into a preset file, so renaming a case is a data migration, not a refactor.
public enum FilterDimension: String, Sendable, CaseIterable, Hashable {
    case month, day, ext, rating, flag, color, camera, serial, lens
    case focal, shutter, aperture, iso, flash, gps

    /// The 7 dimensions the owner insists must be offered **from the numbers that exist**
    /// (「相机 序列号 镜头 焦距 快门速度 光圈 ISO … 如果所有照片都没焦距，就只能选『全部』」).
    /// 月/日/文件后缀 behave the same way by nature; 星级/旗标/色标 are a closed vocabulary.
    public var isDataDriven: Bool { !hasFixedVocabulary }
}

/// One picked value of one dimension — the data layer's unit, deliberately single-valued.
///
/// A slot in the bar may hold several values (星级 1★、2★、5★). That becomes **several criteria of
/// the same dimension**, which the query ORs together; criteria of *different* dimensions are
/// ANDed. Keeping the struct single-valued means CLI/preset JSON stays the obvious thing it was.
public struct FilterCriterion: Sendable, Hashable {
    public var dimension: FilterDimension
    public var value: String

    public init(dimension: FilterDimension, value: String) {
        self.dimension = dimension
        self.value = value
    }
}

public struct AssetFilter: Sendable {
    public var ratingAtLeast: Int?
    public var cameraKey: String?
    public var sinceLocalDate: String?
    public var includeDeleted: Bool
    public var limit: Int
    /// Catalog metadata facets (M5). `flag` is `"pick"` / `"reject"`, `colorLabel` is one of
    /// `red…purple`. Equality against the `assets` columns, so `nil` means "any".
    public var flagEquals: String?
    public var colorLabelEquals: String?
    /// The folder rows the source tree has selected (021 B), ORed together.
    ///
    /// Empty = no folder constraint, i.e. the whole library — which is also what 「全部照片」 means,
    /// so `[FolderSelection(rootId: nil)]` normalises to empty rather than to a clause. A selection
    /// is *not* restricted to one root: `rootA|day2` + `rootB|night` is a cross-root union, which is
    /// the whole point of ⌘-multi-select (the old single `folderPath` + `sourceRootId` pair could
    /// only ever name one root's one subtree).
    ///
    /// Overlapping selections are fine and are **not** deduplicated in the result: the clauses are a
    /// `WHERE … OR …`, so a row that matches both `day2` and `day2/sub` is still returned once, and
    /// no `DISTINCT` (or second pass) is needed to keep `day2 + day2/sub` equal to `day2`.
    public var folders: [FolderSelection]

    /// The grid bar's slots (026), flattened: one criterion per picked value.
    ///
    /// **Values of the same dimension OR together, dimensions AND together** — 星级 1★·2★·5★ AND
    /// 留用 AND LEICA SL3. They are ANDed with every field above as well, so the CLI's
    /// `ratingAtLeast` / `cameraKey` / `flagEquals` / `colorLabelEquals` keep their meaning unchanged
    /// (nothing that already worked had to be rewritten to gain slots).
    public var criteria: [FilterCriterion]

    /// 相册成员的约束（078 B10）：网格「点相册」就是这一条。
    ///
    /// 多个 id 是 **OR**（同一张照片在任一相册里即命中），且与 folders / criteria / 各 legacy 字段
    /// **AND**：相册是「看什么范围」，筛选条是「在这个范围里挑」，两者叠在一起才等于用户眼里的结果 ——
    /// 所以左栏点相册不该把筛选条清掉。空数组 = 不约束。
    ///
    /// 走 `EXISTS` 子查询而不是 join：一张照片在同一个相册里只有一行，join 不会放大行数，但
    /// `EXISTS` 让这条子句可以被单独摘掉（facet 的 `excluding` 不需要它），也不需要 `DISTINCT`。
    public var albumIds: [String]

    public init(ratingAtLeast: Int? = nil, cameraKey: String? = nil, sinceLocalDate: String? = nil,
                includeDeleted: Bool = false, limit: Int = 200,
                flagEquals: String? = nil, colorLabelEquals: String? = nil,
                folders: [FolderSelection] = [],
                criteria: [FilterCriterion] = [],
                albumIds: [String] = []) {
        self.ratingAtLeast = ratingAtLeast
        self.cameraKey = cameraKey
        self.sinceLocalDate = sinceLocalDate
        self.includeDeleted = includeDeleted
        self.limit = limit
        self.flagEquals = flagEquals
        self.colorLabelEquals = colorLabelEquals
        self.folders = folders
        self.criteria = criteria
        self.albumIds = albumIds
    }

    /// `"day2/"` → `"day2"`, `"/day2//sub/"` → `"day2/sub"`, `""`/`nil` → `nil` (= the whole root).
    ///
    /// One normaliser for the query and the folder tree, so a path the tree hands out is a path the
    /// query understands — and a stray slash can never turn "the root" into "a folder named -".
    public static func normalizedFolderPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One folder in the browser's source tree: the directory's own photo count and its subtree's.
///
/// `path` is relative to the source root and uses `/`; the empty path is the root itself. A root has
/// exactly one `""` node whenever it holds a photo, which is what the root row's count reads.
public struct FolderNode: Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    /// Photos directly in this folder.
    public var direct: Int
    /// Photos in this folder and everything under it.
    public var total: Int

    public var id: String { path }
    /// The last path component — what a row shows.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
    /// The parent's path (`"day2/sub"` → `"day2"`, `"day2"` → `""`).
    public var parentPath: String {
        var parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    public init(path: String, direct: Int, total: Int) {
        self.path = path
        self.direct = direct
        self.total = total
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
    /// The user pressed 取消 and the walk stopped between two files (`ImportState.cancelled`).
    public var interrupted = false
    /// Ids of the rows this run created, in import order — the GUI selects the first one that is
    /// still visible after `reload()`.
    public var addedAssetIDs: [String] = []

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
    /// The root a given path belongs to, creating one when nothing contains it.
    ///
    /// **Reference roots are folders, not volumes.** Matching only on the volume UUID folded every
    /// folder of one disk into the first root that happened to exist, so importing `~/Desktop/US`
    /// into a library that already had `~/Desktop/test` produced rows whose `rel_path` was a bare
    /// filename — the paths resolved to files that were never there (no thumbnail, no decode, no
    /// error). A root therefore has to *contain* the file: the deepest containing `pathHint` wins,
    /// and a folder nothing contains becomes a root of its own.
    ///
    /// Copy roots are different by design: the originals live inside the package, so one root per
    /// volume is enough and the bookkeeping stays simple.
    public func ensureRoot(for path: URL, mode: ManagementMode) throws -> SourceRoot {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw CatalogError.importSourceMissing(path)
        }
        // Ascend to a directory: a file argument belongs to its parent folder.
        var rootURL = isDir.boolValue ? path : path.deletingLastPathComponent()
        rootURL = rootURL.standardizedFileURL
        let rootPath = rootURL.path

        let existing = try roots().filter { $0.managementMode == mode }
        if mode == .reference {
            // Deepest container wins; a folder that contains itself matches exactly.
            if var hit = existing
                .filter({ Self.path($0.pathHint, contains: rootPath) })
                .max(by: { $0.pathHint.count < $1.pathHint.count }) {
                if hit.status != .online {
                    hit.status = .online
                    try dbQueue.write { db in try hit.update(db) }
                }
                return hit
            }
        } else {
            let volumeUUID = (try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil
            if var hit = existing.first(where: { root in
                if root.pathHint == rootPath { return true }
                if let v = volumeUUID, let rv = root.volumeUuid { return v == rv }
                return false
            }) {
                if hit.status != .online {
                    hit.status = .online
                    try dbQueue.write { db in try hit.update(db) }
                }
                return hit
            }
        }

        let volumeUUID = (try? rootURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? nil
        let bookmark = try? rootURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = SourceRoot(volumeUuid: volumeUUID,
                              bookmark: bookmark,
                              displayName: rootURL.lastPathComponent,
                              pathHint: rootPath,
                              managementMode: mode,
                              status: .online)
        try dbQueue.write { db in try root.insert(db) }
        return root
    }

    /// Is `descendant` the same path as `ancestor`, or inside it? Component-aware, so
    /// `/a/bc` is *not* inside `/a/b`.
    static func path(_ ancestor: String, contains descendant: String) -> Bool {
        let a = ancestor.hasSuffix("/") ? String(ancestor.dropLast()) : ancestor
        return descendant == a || descendant.hasPrefix(a + "/")
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
        try dbQueue.read { db in
            let (sql, args) = try Self.assetsQuery(filter, in: db)
            return try Asset.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func metadata(assetId: String) throws -> AssetMetadata? {
        try dbQueue.read { db in try AssetMetadata.fetchOne(db, key: assetId) }
    }

    // MARK: folders (the browser's source tree)

    /// Every folder that holds a photo, with its direct and subtree counts.
    ///
    /// `rootId` nil = across the whole library (paths that exist under two roots merge — the tree
    /// never asks for that; the per-root index is what it draws). `nil`/`""` is not a special case
    /// here: the root's own node is the node whose `path` is `""`, and it is always present when the
    /// root holds at least one photo, so a root row can read its count from the same list.
    ///
    /// The aggregation runs in Swift over `(source_root_id, rel_path)` — 10k rows is the design
    /// point (006 §5) and one grouped scan is cheaper than a recursive CTE plus `LIKE` per folder.
    public func folders(rootId: String? = nil) throws -> [FolderNode] {
        let rows: [(rootID: String, relPath: String)] = try dbQueue.read { db in
            var args: [any DatabaseValueConvertible] = []
            var sql = "SELECT source_root_id, rel_path FROM assets WHERE deleted = 0"
            if let rootId { sql += " AND source_root_id = ?"; args.append(rootId) }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                (rootID: $0["source_root_id"], relPath: $0["rel_path"])
            }
        }
        let grouped = Self.folderNodes(rows)
        if rootId != nil { return grouped.values.first ?? [] }
        return Self.merge(grouped)
    }

    /// The whole tree in one scan, keyed by root id — one query per reload however many roots the
    /// library has.
    public func folderIndex() throws -> [String: [FolderNode]] {
        let rows: [(rootID: String, relPath: String)] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_root_id, rel_path FROM assets WHERE deleted = 0
                """).map { (rootID: $0["source_root_id"], relPath: $0["rel_path"]) }
        }
        return Self.folderNodes(rows)
    }

    /// Group `(root, relPath)` rows into per-root folder nodes. Pure, so the unit test can drive it
    /// with the four paths the tree cares about instead of a database.
    ///
    /// A row's folder is its path minus the filename; every ancestor of that folder (and the root
    /// itself, `""`) gets the row in `total`, only the leaf folder gets it in `direct`. Empty path
    /// components are dropped, so `"day2//b.dng"` and `"day2/b.dng"` are one folder.
    static func folderNodes(_ rows: [(rootID: String, relPath: String)]) -> [String: [FolderNode]] {
        var direct: [String: [String: Int]] = [:]
        var total: [String: [String: Int]] = [:]
        for row in rows {
            var parts = row.relPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            parts.removeLast()                       // the filename is not a folder
            let leaf = parts.joined(separator: "/")
            direct[row.rootID, default: [:]][leaf, default: 0] += 1
            total[row.rootID, default: [:]][""] = (total[row.rootID]?[""] ?? 0) + 1
            var prefix = ""
            for part in parts {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                total[row.rootID, default: [:]][prefix, default: 0] += 1
            }
        }
        var out: [String: [FolderNode]] = [:]
        for rootID in Set(direct.keys).union(total.keys) {
            var paths = Set<String>()
            if let d = direct[rootID] { paths.formUnion(d.keys) }
            if let t = total[rootID] { paths.formUnion(t.keys) }
            out[rootID] = paths
                .map { FolderNode(path: $0,
                                  direct: direct[rootID]?[$0] ?? 0,
                                  total: total[rootID]?[$0] ?? 0) }
                .sorted { $0.path < $1.path }        // "" first, then parents before children
        }
        return out
    }

    /// Fold several roots' trees into one, summing equal paths. Only `folders(rootId: nil)` needs it.
    static func merge(_ grouped: [String: [FolderNode]]) -> [FolderNode] {
        var direct: [String: Int] = [:]
        var total: [String: Int] = [:]
        for nodes in grouped.values {
            for node in nodes {
                direct[node.path, default: 0] += node.direct
                total[node.path, default: 0] += node.total
            }
        }
        return Set(direct.keys).union(total.keys)
            .map { FolderNode(path: $0, direct: direct[$0] ?? 0, total: total[$0] ?? 0) }
            .sorted { $0.path < $1.path }
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

    // MARK: batch metadata (a whole selection, one statement, one transaction)

    /// Rating a 200-photo selection is **one** `UPDATE`, not 200: the grid's 0–5 shortcuts run on
    /// every keypress over the selection, and a per-row loop would make a 10k selection 10k
    /// transactions (and 10k fsyncs) for one keystroke.
    ///
    /// Returns the number of rows the statement actually changed, which is what the smoke asserts
    /// on ("5 selected, 5 rows").
    @discardableResult
    public func setRating(_ rating: Int, forAssets ids: [String]) throws -> Int {
        try updateMetadata(set: "rating = ?", value: rating, ids: ids)
    }

    /// `nil` clears the flag. Same one-transaction contract as `setRating(_:forAssets:)`.
    @discardableResult
    public func setFlag(_ flag: String?, forAssets ids: [String]) throws -> Int {
        try updateMetadata(set: "flag = ?", value: flag, ids: ids)
    }

    /// `nil` clears the colour label.
    @discardableResult
    public func setColorLabel(_ label: String?, forAssets ids: [String]) throws -> Int {
        try updateMetadata(set: "color_label = ?", value: label, ids: ids)
    }

    private func updateMetadata(set clause: String, value: (any DatabaseValueConvertible)?,
                                ids: [String]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var args: [any DatabaseValueConvertible] = [value ?? DatabaseValue.null]
        args.append(contentsOf: ids)
        return try dbQueue.write { db -> Int in
            try db.execute(sql: "UPDATE assets SET \(clause) WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(args))
            return db.changesCount
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

    // MARK: settings (081 §3: 选择记在库里)

    /// The 复制设置 checklist this library last used, with **本库** as the scope.
    ///
    /// Not `UserDefaults` (081 §3): one machine holds several libraries, and the checklist belongs to
    /// the library whose photos it describes — 「A 库选 3 项、B 库选 7 项」 must survive reopening both.
    /// The row lives in `settings` (`Database.setting(_:)` / `writeSettings`), whose table has existed
    /// since v1. Every read failure is 全部 (`CopySettingsSelection.init(storageValue:)`), because an
    /// empty checklist would make the next ⌘C carry nothing.
    public func copySelection() throws -> CopySettingsSelection {
        CopySettingsSelection(storageValue: try setting(CopySettingsSelection.storageKey))
    }

    /// Remember the checklist. Called on every 复制 — the same moment `assets` rows would be written
    /// if this were an edit, which it is not: a selection is a preference about the *next* copy.
    public func storeCopySelection(_ selection: CopySettingsSelection) throws {
        try writeSettings([CopySettingsSelection.storageKey: selection.storageValue])
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
