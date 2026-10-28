import Foundation
import GRDB

/// 相册（P0-12 / 078 B10）— 库属性，不是文档属性。
///
/// `albums` / `album_assets` 两张表从 v1 就在 `Schema.swift` 里，`Album` 记录类型也在
/// `Models.swift`。缺的一直是**动词**：没有创建/改名/删除，没有加入/移出，没有左栏入口。
/// 这个文件补上动词，并且只补动词 —— 相册成员是**图库事实**，和 rating/flag/色标同级：
/// 它不进 `EditModel`、不进 `EditHistory`、不进 `develop_json`，所以 ⌘Z 不会回退一次「加入相册」，
/// `editRevision` 也不会为它动一下（判据见 `AlbumCRUDTests.testAlbumWritesNeverTouchTheDocument`）。
///
/// 三条硬约束，写在这里免得以后有人"顺手优化"掉：
///
/// 1. **删相册不删照片。** `deleteAlbum` 只碰 `album_assets` 和 `albums`。`assets` 表、磁盘上的
///    原文件、缩略图缓存都不在其中 —— 相册是观看方式，不是所有权。
/// 2. **一张照片可以属于任意多个相册。** 主键是 `(album_id, asset_id)`，不是 `asset_id`，
///    所以「同一张照片进两个相册」是正常状态而不是要防的重复。
/// 3. **`position` 只增不改。** 加入相册是 append（`MAX(position)+1`），移出后重加会排到末尾；
///    已有的成员顺序不会因为一次批量加入而重排 —— 网格里看过的顺序不该在别处被改写。
public struct AlbumSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var parentId: String?
    public var name: String
    public var sort: Int
    public var createdAt: String
    /// 成员数，**只数活着的照片**（`assets.deleted = 0`）。左侧栏的数字与点开相册后网格的行数
    /// 来自同一次 join，所以两者不可能不一致。
    public var count: Int

    public init(id: String, parentId: String? = nil, name: String, sort: Int = 0,
                createdAt: String, count: Int = 0) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.sort = sort
        self.createdAt = createdAt
        self.count = count
    }
}

/// 一次删除的结果：删掉几个相册、清掉几条成员关系。**没有 `photos` 字段**，这是故意的 ——
/// 这个操作在类型层面就说不出"删了多少张照片"。
public struct AlbumDeleteReport: Equatable, Sendable {
    public var albums = 0
    public var entries = 0

    public init(albums: Int = 0, entries: Int = 0) {
        self.albums = albums
        self.entries = entries
    }

    public var text: String { "albums \(albums) entries \(entries)" }
}

public enum AlbumError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case noSuchAlbum(String)
    case noLibrary

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "相册名不能为空"
        case .duplicateName(let n): return "已经有一个叫「\(n)」的相册"
        case .noSuchAlbum(let id): return "没有这个相册: \(id)"
        case .noLibrary: return "没有打开的库"
        }
    }
}

// MARK: - queries

extension Catalog {

    /// 相册列表，按 `sort`、名字排序，带成员数。左栏和 CLI 读同一个函数。
    ///
    /// 计数走 `LEFT JOIN assets … AND a.deleted = 0`，不是 `COUNT(aa.asset_id)`：一张被 soft-delete
    /// 的照片还留在 `album_assets` 里（删照片的级联是**硬删**，见 `Availability.deleteAssets`，
    /// 但 `setDeleted(true)` 是软删），左栏若把软删的也算上，点进去就会少行 —— 数字与网格不符正是
    /// 078 B10 验收要盯的那条。
    public func albums() throws -> [AlbumSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT al.id, al.parent_id, al.name, al.sort, al.created_at,
                       COUNT(a.id) AS member_count
                FROM albums al
                LEFT JOIN album_assets aa ON aa.album_id = al.id
                LEFT JOIN assets a ON a.id = aa.asset_id AND a.deleted = 0
                GROUP BY al.id
                ORDER BY al.sort, al.name COLLATE NOCASE
                """).map { row in
                AlbumSummary(id: row["id"], parentId: row["parent_id"], name: row["name"],
                             sort: row["sort"], createdAt: row["created_at"],
                             count: row["member_count"])
            }
        }
    }

    public func album(id: String) throws -> AlbumSummary? {
        try albums().first { $0.id == id }
    }

    /// 名字精确匹配（大小写不敏感），给 CLI 用：让人打 `/album 旅行` 而不是一串 UUID。
    public func album(named name: String) throws -> AlbumSummary? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try albums().first { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
    }

    /// 相册成员，**按 `position` 排序**（加入顺序），只含活着的照片。
    public func albumAssetIDs(_ albumId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT aa.asset_id FROM album_assets aa
                JOIN assets a ON a.id = aa.asset_id
                WHERE aa.album_id = ? AND a.deleted = 0
                ORDER BY aa.position, aa.asset_id
                """, arguments: [albumId])
        }
    }

    public func albumAssetCount(_ albumId: String) throws -> Int {
        try albumAssetIDs(albumId).count
    }

    /// 这些照片各自属于哪些相册（`asset_id → [album_id]`）。右键菜单用它决定「移出相册」列出谁。
    public func albumMemberships(assetIDs: [String]) throws -> [String: [String]] {
        guard !assetIDs.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: assetIDs.count).joined(separator: ", ")
        return try dbQueue.read { db in
            var out: [String: [String]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT aa.asset_id, aa.album_id FROM album_assets aa
                WHERE aa.asset_id IN (\(marks))
                ORDER BY aa.album_id
                """, arguments: StatementArguments(assetIDs))
            for row in rows {
                out[row["asset_id"], default: []].append(row["album_id"])
            }
            return out
        }
    }
}

// MARK: - mutations

extension Catalog {

    /// 建一个相册。名字去首尾空白；空名与重名是**错误**而不是静默纠正 —— 左栏是导航面，
    /// 两个「旅行」是无法点击区分的两行。
    @discardableResult
    public func createAlbum(named rawName: String, parentId: String? = nil) throws -> Album {
        let name = try Self.albumName(rawName)
        return try dbQueue.write { db in
            let clash = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE name = ? COLLATE NOCASE",
                                         arguments: [name]) ?? 0
            guard clash == 0 else { throw AlbumError.duplicateName(name) }
            if let parentId {
                guard try Album.fetchOne(db, key: parentId) != nil else { throw AlbumError.noSuchAlbum(parentId) }
            }
            // `sort` 是用户在左栏拖出来的顺序（目前只由创建顺序决定）；append 到末尾。
            let next = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort), -1) + 1 FROM albums") ?? 0)
            let album = Album(id: UUID().uuidString, parentId: parentId, name: name,
                              sort: next, createdAt: ISO8601.now())
            try album.insert(db)
            return album
        }
    }

    /// 改名。返回改完的记录（调用方要的是新名字，不是"成功了"）。
    @discardableResult
    public func renameAlbum(id: String, to rawName: String) throws -> Album {
        let name = try Self.albumName(rawName)
        return try dbQueue.write { db in
            guard var album = try Album.fetchOne(db, key: id) else { throw AlbumError.noSuchAlbum(id) }
            guard album.name != name else { return album }
            let clash = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM albums WHERE name = ? COLLATE NOCASE AND id <> ?
                """, arguments: [name, id]) ?? 0
            guard clash == 0 else { throw AlbumError.duplicateName(name) }
            album.name = name
            try album.update(db)
            return album
        }
    }

    /// 删相册：**只删成员关系与相册行，一张照片都不删。**
    ///
    /// 显式写两条 `DELETE`（子表先）而不是靠外键 CASCADE：CASCADE 报不出每张表的行数，而且
    /// 哪天有人把 `album_assets.album_id` 的外键删了，级联会静默消失；显式语句能被
    /// `AlbumDeleteReport` 断言，也能被读 SQL 的人看懂（同 `Availability.deleteAssets` 的理由）。
    ///
    /// 子相册用递归 CTE 一起收掉：schema 有 `parent_id`（LR 的「相册文件夹」），删父不删子会留下
    /// 不可达的孤儿行。
    @discardableResult
    public func deleteAlbum(id: String) throws -> AlbumDeleteReport {
        try dbQueue.write { db in
            guard try Album.fetchOne(db, key: id) != nil else { throw AlbumError.noSuchAlbum(id) }
            let ids = try String.fetchAll(db, sql: """
                WITH RECURSIVE tree(id) AS (
                    SELECT id FROM albums WHERE id = ?
                    UNION
                    SELECT a.id FROM albums a JOIN tree t ON a.parent_id = t.id
                )
                SELECT id FROM tree
                """, arguments: [id])
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")

            var report = AlbumDeleteReport()
            // 先数相册行：`DELETE FROM albums` 的 `changesCount` 只数**语句直接删掉**的行，
            // 外键级联删掉的子相册不算（SQLite 的 `sqlite3_changes` 不把 FK action 记在内），
            // 于是"删一棵树报 1 个"会成为一次谎报。数在删之前，答案与树的大小一致。
            report.albums = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE id IN (\(marks))",
                                             arguments: StatementArguments(ids)) ?? 0
            try db.execute(sql: "DELETE FROM album_assets WHERE album_id IN (\(marks))",
                           arguments: StatementArguments(ids))
            report.entries = db.changesCount
            // 整棵树的 id 已经在上面删过 `album_assets`，这里删相册行本身。子相册既被这条
            // `IN` 命中、也会被 `parent_id` 的 CASCADE 带走 —— 两条路同一个结果，不留孤儿行。
            try db.execute(sql: "DELETE FROM albums WHERE id IN (\(marks))",
                           arguments: StatementArguments(ids))
            return report
        }
    }

    /// 把照片加入相册，返回**实际新增**的成员数（已在相册里的不算）。
    ///
    /// 一切在一个 `dbQueue.write`（= 一个事务）里：200 张的一次加入不该变成 200 次 fsync，
    /// 也不该在中途失败后留下半个相册。不在库里的 id 被跳过而不是让整批失败 ——
    /// 调用方拿的是网格的选中集，而选中集可能比库旧一个 runloop。
    @discardableResult
    public func addAssets(_ assetIds: [String], toAlbum albumId: String) throws -> Int {
        // 去重**保序**：`Set` 会打乱顺序，而这里顺序就是 `position`（用户在网格里选的那一排
        // 应该按同一个顺序进相册）。这个 bug 的形状是"相册里的顺序反了"，只有当有人真的看
        // 相册里的排列时才会发现。
        var seen = Set<String>()
        var unique: [String] = []
        for id in assetIds where seen.insert(id).inserted { unique.append(id) }
        guard !unique.isEmpty else { return 0 }
        return try dbQueue.write { db in
            guard try Album.fetchOne(db, key: albumId) != nil else { throw AlbumError.noSuchAlbum(albumId) }
            let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
            let live = Set(try String.fetchAll(db, sql: "SELECT id FROM assets WHERE id IN (\(marks))",
                                              arguments: StatementArguments(unique)))
            // 保持调用方给的顺序（网格顺序），不是 `IN` 回表的顺序。
            let sorted = unique.filter { live.contains($0) }
            guard !sorted.isEmpty else { return 0 }
            var position = (try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(position), -1) + 1 FROM album_assets WHERE album_id = ?
                """, arguments: [albumId])) ?? 0
            var added = 0
            for assetId in sorted {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO album_assets(album_id, asset_id, position) VALUES (?, ?, ?)
                    """, arguments: [albumId, assetId, position])
                if db.changesCount > 0 { added += 1; position += 1 }
            }
            return added
        }
    }

    /// 把照片移出相册（**只删关系**，照片当然还在库里），返回移除条数。
    @discardableResult
    public func removeAssets(_ assetIds: [String], fromAlbum albumId: String) throws -> Int {
        let unique = Array(Set(assetIds))
        guard !unique.isEmpty else { return 0 }
        return try dbQueue.write { db in
            guard try Album.fetchOne(db, key: albumId) != nil else { throw AlbumError.noSuchAlbum(albumId) }
            let marks = Array(repeating: "?", count: unique.count).joined(separator: ", ")
            try db.execute(sql: "DELETE FROM album_assets WHERE album_id = ? AND asset_id IN (\(marks))",
                           arguments: StatementArguments([albumId] + unique))
            return db.changesCount
        }
    }

    /// 相册名的唯一规范：去空白 + 非空。建与改名都过这里，所以两条路径的名字规则不可能分叉。
    static func albumName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AlbumError.emptyName }
        return name
    }
}
