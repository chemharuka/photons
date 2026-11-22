import Foundation
import GRDB

/// 512 — 库属性（星级 / 旗标 / 色标 / 关键词 / 拍摄时间）不是编辑，所以它有自己的入口。
///
/// 与 `copySettings` / `pasteSettings` 的边界：那两件事搬的是 `develop_json`（「怎么处理」），
/// 这一件搬的是「这张照片是什么」。评分、旗标、色标、关键词在库里与堆叠同级 —— 一条
/// `UPDATE`、一次 `metadataRevision` bump、**不写** `asset_history`、⌘Z 不走回来。
public enum LibraryMetadataError: LocalizedError {
    case noSuchAsset(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchAsset(let id): return "no such asset: \(id)"
        }
    }
}

extension Catalog {

    /// 512 — 把 A 的**库属性**搬到 B：星级、旗标、色标、关键词链接。拍摄时间三列一并补齐
    /// （见下）。
    ///
    /// 一个事务：`dbQueue.write` 是 GRDB 的 `BEGIN … COMMIT`，所以中途任何一句抛错整笔回滚 ——
    /// 不会出现「星级搬过去了、关键词没搬」的半张照片。A/B 任一不存在 ⇒ 抛
    /// `LibraryMetadataError.noSuchAsset`（这条要在事务**里**查，否则一句「查不到」与「删了」之间
    /// 会有窗口）。
    ///
    /// **返回值口径**：`3 + 本次真正插进去的关键词链接数`。三项是 `rating` / `flag` /
    /// `color_label`（它们在同一条 `UPDATE` 里，作为一个整体算三件），关键词按 `INSERT OR IGNORE`
    /// 的**实际插入**行数计（已经有的链接不重复算）。拍摄时间三列**不计入**：那是文件的一条事实，
    /// 不是用户给这张照片贴的标签，计入会让「继承了几项库属性」这个数字随文件格式漂移。
    ///
    /// **拍摄时间**（§2.4）：降噪产物是同一张照片，拍摄时间必须与原图相同，但写入器是否保留
    /// EXIF 日期不由我们决定（`DNGRawWriter` 目前不写日期），所以这里一并从原图复制
    /// `capture_time` / `capture_local_date` / `capture_time_source`。原图自己也没有日期
    /// （`capture_time IS NULL`）时**不写**，免得把产物那三列从「有」改成「无」。
    ///
    /// **不碰** `develop_json`、`asset_history`、`render_version`：这不是编辑。
    /// 也**不碰** `stack_id` / `stack_rank`：堆叠是 487 的 `makeStack` 的事。
    @discardableResult
    public func copyLibraryMetadata(fromAsset source: String, toAsset destination: String) throws -> Int {
        try dbQueue.write { db -> Int in
            guard let origin = try Row.fetchOne(db, sql: """
                SELECT rating, flag, color_label, capture_time, capture_local_date, capture_time_source
                FROM assets WHERE id = ?
                """, arguments: [source]) else {
                throw LibraryMetadataError.noSuchAsset(source)
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE id = ?)",
                                    arguments: [destination]) == true else {
                throw LibraryMetadataError.noSuchAsset(destination)
            }

            // `nil` 与 NULL 是两回事：`flag` / `color_label` 为 nil 时就是要把它写成 NULL
            // （「没有旗标」也是一个值），所以参数走 `DatabaseValueConvertible?` 而不是跳过。
            try db.execute(sql: """
                UPDATE assets
                   SET rating = ?, flag = ?, color_label = ?
                 WHERE id = ?
                """, arguments: [origin["rating"] as Int, origin["flag"] as String?,
                                 origin["color_label"] as String?, destination])

            if let captureTime = origin["capture_time"] as String? {
                try db.execute(sql: """
                    UPDATE assets
                       SET capture_time = ?, capture_local_date = ?, capture_time_source = ?
                     WHERE id = ?
                    """, arguments: [captureTime, origin["capture_local_date"] as String?,
                                     origin["capture_time_source"] as String?, destination])
            }

            // 关键词：一条 `INSERT … SELECT`，在同一个事务里。`OR IGNORE` 就是「重新堆叠/重跑」
            // 时不会因为主键冲突失败，也不会改动已有的链接。
            try db.execute(sql: """
                INSERT OR IGNORE INTO photo_keywords(asset_id, keyword_id)
                SELECT ?, keyword_id FROM photo_keywords WHERE asset_id = ?
                """, arguments: [destination, source])
            let keywords = db.changesCount

            return 3 + keywords
        }
    }
}
