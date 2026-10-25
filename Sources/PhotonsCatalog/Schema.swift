import Foundation
import GRDB

/// Schema v1 — the catalog. One migration per version, each doing one thing (darktable's
/// 57-step discipline; `docs/tasks/003-catalog.md` §3 has the annotated DDL).
public enum Schema {
    /// Bump on every additive migration; `PRAGMA user_version` follows it.
    public static let version = 1
    /// Version of the identity-hash recipe. Bump when `content_hash` changes meaning.
    public static let uniqueHashVersion = 1

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        return m
    }

    static func migrate(_ queue: DatabaseQueue) throws {
        try migrator.migrate(queue)
    }

    private static let v1 = """
    -- 库级元数据：版本号与数据同库（digiKam 的教训：备份/迁移不脱节）
    CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);

    -- 导入来源：卷 UUID 而不是路径，换挂载点仍能找到
    CREATE TABLE source_roots(
      id              TEXT PRIMARY KEY,
      volume_uuid     TEXT,
      bookmark        BLOB,
      display_name    TEXT NOT NULL,
      path_hint       TEXT NOT NULL,
      management_mode TEXT NOT NULL,
      status          TEXT NOT NULL,
      created_at      TEXT NOT NULL
    );

    -- 主表：热列。相机/镜头是文本列（用户选择 A：digiKam 形状，不建字典表）
    CREATE TABLE assets(
      id                   TEXT PRIMARY KEY,
      source_root_id       TEXT NOT NULL REFERENCES source_roots(id) ON DELETE CASCADE,
      rel_path             TEXT NOT NULL,
      filename             TEXT NOT NULL,
      ext                  TEXT NOT NULL,
      kind                 TEXT NOT NULL,
      size                 INTEGER NOT NULL,
      mtime                REAL NOT NULL,
      content_hash         TEXT NOT NULL,
      quick_hash           TEXT,
      width                INTEGER,
      height               INTEGER,
      capture_time         TEXT,
      capture_local_date   TEXT,
      capture_time_source  TEXT,
      rating               INTEGER NOT NULL DEFAULT 0,
      flag                 TEXT,
      color_label          TEXT,
      camera_make          TEXT,
      camera_model         TEXT,
      camera_key           TEXT,
      lens                 TEXT,
      develop_json         TEXT NOT NULL DEFAULT '{}',
      develop_version      INTEGER NOT NULL DEFAULT 1,
      render_version       INTEGER NOT NULL DEFAULT 1,
      imported_at          TEXT NOT NULL,
      checked_at           TEXT,
      deleted              INTEGER NOT NULL DEFAULT 0,
      UNIQUE(content_hash),
      UNIQUE(source_root_id, rel_path)
    );

    -- 1:1 卫星表：冷列（EXIF 全量、XMP 原文），只在检查器里读
    CREATE TABLE asset_metadata(
      asset_id     TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
      exif_json    TEXT NOT NULL DEFAULT '{}',
      xmp_blob     TEXT,
      iso          INTEGER,
      focal_length REAL,
      aperture     REAL,
      shutter      TEXT,
      orientation  INTEGER
    );

    -- 快照栈：assets.develop_json 是当前值
    CREATE TABLE asset_history(
      asset_id     TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      seq          INTEGER NOT NULL,
      develop_json TEXT NOT NULL,
      label        TEXT,
      created_at   TEXT NOT NULL,
      PRIMARY KEY(asset_id, seq)
    );

    CREATE TABLE keywords(
      id        TEXT PRIMARY KEY,
      name      TEXT NOT NULL,
      parent_id TEXT REFERENCES keywords(id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX idx_keywords_name ON keywords(name);
    CREATE TABLE photo_keywords(
      asset_id   TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      keyword_id TEXT NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
      PRIMARY KEY(asset_id, keyword_id)
    );

    CREATE TABLE albums(
      id         TEXT PRIMARY KEY,
      parent_id  TEXT REFERENCES albums(id) ON DELETE CASCADE,
      name       TEXT NOT NULL,
      sort       INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    );
    CREATE TABLE album_assets(
      album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      position INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(album_id, asset_id)
    );

    -- 导入台账：可中断可续的全部秘密
    CREATE TABLE import_sessions(
      id             TEXT PRIMARY KEY,
      source_root_id TEXT REFERENCES source_roots(id) ON DELETE CASCADE,
      mode           TEXT NOT NULL,
      state          TEXT NOT NULL,
      total_count    INTEGER NOT NULL DEFAULT 0,
      imported_count INTEGER NOT NULL DEFAULT 0,
      skipped_count  INTEGER NOT NULL DEFAULT 0,
      failed_count   INTEGER NOT NULL DEFAULT 0,
      started_at     TEXT NOT NULL,
      finished_at    TEXT,
      error_message  TEXT
    );
    CREATE TABLE import_files(
      session_id  TEXT NOT NULL REFERENCES import_sessions(id) ON DELETE CASCADE,
      source_path TEXT NOT NULL,
      asset_id    TEXT,
      outcome     TEXT NOT NULL,
      reason      TEXT,
      seen_at     TEXT NOT NULL,
      PRIMARY KEY(session_id, source_path)
    );

    -- 查询索引：每条对应 local/probes/catalog-schema-bench.py 量过的一个形状
    CREATE INDEX idx_assets_grid     ON assets(deleted, capture_time DESC, id);
    CREATE INDEX idx_assets_imported ON assets(deleted, imported_at DESC, id);
    CREATE INDEX idx_assets_rating   ON assets(deleted, rating, capture_time DESC, id);
    CREATE INDEX idx_assets_filename ON assets(deleted, filename COLLATE NOCASE, id);
    CREATE INDEX idx_assets_camera   ON assets(deleted, camera_key, capture_time DESC, id);
    CREATE INDEX idx_assets_root     ON assets(source_root_id, rel_path);
    CREATE INDEX idx_import_files_session ON import_files(session_id, outcome);
    """
}
