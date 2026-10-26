import Foundation
import GRDB

/// Schema — one migration per version, each doing one thing (darktable's 57-step discipline;
/// `docs/tasks/003-catalog.md` §3 has the annotated DDL).
///
/// | version | what it adds |
/// |---|---|
/// | v1 | the catalog: assets, source roots, keywords, albums, import ledger, `asset_history` |
/// | v2 | `assets.history_end` — the persisted snapshot cursor (D10's `history_end`) |
/// | v3 | `assets.edit_time` + `develop_quarantine` — the develop document actually lands |
/// | v4 | `presets` — named partial documents for M5's preset panel |
/// | v5 | `assets.missing` — the row whose original file moved away (reference roots only) |
///
/// **Naming deviation, deliberate:** the task that introduced v3 calls the stack table
/// `edit_history(asset_id, seq, label, develop_json, created_at)`. v1 already created exactly that
/// table under the name `asset_history` (`docs/tasks/003-catalog.md` §3, `architecture-decisions.md`
/// §6). v3 therefore does **not** create a second table: the existing name and columns win, and the
/// only things missing were a write timestamp and a place to park blobs that will not decode.
public enum Schema {
    /// Bump on every additive migration; `PRAGMA user_version` follows it.
    public static let version = 5
    /// Version of the identity-hash recipe. Bump when `content_hash` changes meaning.
    public static let uniqueHashVersion = 1

    /// One migration step: a name GRDB records in `grdb_migrations` and the work it does.
    ///
    /// The work is a closure rather than a bare SQL string because a step may have to *look* before
    /// it alters (`v5` adds a column, and `ALTER TABLE … ADD COLUMN` throws if the column is already
    /// there). Every step is written to be replayable: re-running it on a database that already has
    /// its effect is a no-op, never an error (the `user_version` stamp can be lost — a restored
    /// backup, a hand-edited file — and a migration that explodes on a healthy library is worse than
    /// one that does nothing).
    struct Step: Sendable {
        let name: String
        let apply: @Sendable (Database) throws -> Void
    }

    /// The ordered steps. GRDB records the applied names in `grdb_migrations`; `user_version` is
    /// ours to stamp (Database.swift), so both readers and `sqlite3` see the same number.
    static let steps: [Step] = [
        Step(name: "v1") { db in try db.execute(sql: v1) },
        Step(name: "v2") { db in try db.execute(sql: v2) },
        Step(name: "v3") { db in try db.execute(sql: v3) },
        Step(name: "v4") { db in try db.execute(sql: v4) },
        Step(name: "v5") { db in try addMissingColumnIfAbsent(db) },
    ]

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        for step in steps {
            m.registerMigration(step.name) { db in
                try step.apply(db)
            }
        }
        return m
    }

    static func migrate(_ queue: DatabaseQueue) throws {
        try migrator.migrate(queue)
    }

    /// Apply only the first `version` steps.
    ///
    /// Tests use this to fabricate a library of an older version and then watch `Catalog.open`
    /// migrate it (the snapshot-before-migration path is only reachable from a real older file).
    /// Nothing in the product calls it with a target below `Schema.version`.
    static func migrate(_ queue: DatabaseQueue, upTo version: Int) throws {
        let target = steps.prefix(max(0, min(version, steps.count)))
        guard let last = target.last else { return }
        try migrator.migrate(queue, upTo: last.name)
    }

    // MARK: - v5

    /// `assets.missing` — "the original file is not where this row says it is".
    ///
    /// The library stores *references* (`ManagementMode.reference`), so moving or renaming a file
    /// outside Photons leaves the row pointing at a path that no longer exists. That used to be
    /// invisible: `verify()` counted it, nothing marked the row. The flag is what the grid can draw
    /// a badge from, what the inspector can print, and what the right-click menu can act on.
    ///
    /// Two decisions worth the ink:
    ///
    /// - **It is a cache of a filesystem fact, never a state machine.** `refreshAvailability()`
    ///   recomputes it from `stat` on every open and every rescan; nothing else writes it. An
    ///   offline root is skipped rather than marked, because "the drive is unplugged" and "the file
    ///   moved" are different sentences and only the second one is actionable.
    /// - **`DEFAULT 0` is the whole back-compat story.** An existing library reads every row as
    ///   present until the first `refreshAvailability()`, which is exactly the pre-v5 behaviour.
    ///   Nothing is deleted, so a wrong guess costs one rescan.
    private static func addMissingColumnIfAbsent(_ db: Database) throws {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(assets)").map { $0["name"] as String }
        guard !columns.contains("missing") else { return }   // replayable: already applied
        try db.execute(sql: "ALTER TABLE assets ADD COLUMN missing INTEGER NOT NULL DEFAULT 0")
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

    // MARK: - v2

    /// The snapshot-stack cursor.
    ///
    /// `asset_history` alone cannot say *where* the user is in the stack: without a persisted cursor
    /// a reopen silently flattens every undo position to the tip, and a document saved after three
    /// undos comes back showing the state the user walked away from. D10 calls this `history_end`
    /// (darktable's column name); it is the seq currently on screen, 0 meaning "no row yet".
    private static let v2 = """
    ALTER TABLE assets ADD COLUMN history_end INTEGER NOT NULL DEFAULT 0;
    """

    // MARK: - v3

    /// The develop document lands.
    ///
    /// `assets.develop_json` / `develop_version` have existed since v1 but nothing ever wrote them.
    /// v3 adds the two things a write path needs and cannot invent:
    ///
    /// - `assets.edit_time`: when the current blob was last written. `develop_version` says *whether*
    ///   the document changed, this says *when* — and it survives a re-render, unlike a file mtime.
    /// - `develop_quarantine`: the parking lot for blobs that do not decode. A corrupt document is
    ///   never repaired and never overwritten in place: the bytes are copied here verbatim, the
    ///   asset reads as `.neutral`, and the damaged original stays recoverable (§develop).
    ///
    /// No foreign key on `develop_quarantine` on purpose: evidence must survive even if the asset row
    /// is removed, otherwise a cleanup deletes the only copy of what went wrong.
    private static let v3 = """
    ALTER TABLE assets ADD COLUMN edit_time TEXT;

    CREATE TABLE develop_quarantine(
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      asset_id        TEXT NOT NULL,
      develop_json    TEXT NOT NULL,
      develop_version INTEGER NOT NULL,
      reason          TEXT NOT NULL,
      quarantined_at  TEXT NOT NULL
    );
    CREATE INDEX idx_develop_quarantine_asset ON develop_quarantine(asset_id, quarantined_at);
    """

    // MARK: - v4

    /// Presets: named **partial** documents (M5).
    ///
    /// There is no `presets` table before this step, so v4 is pure `CREATE` — nothing to ALTER and
    /// therefore **no new columns on existing tables**. A library that never uses presets ends up
    /// with one empty table, which is the cheapest honest shape for an additive feature.
    ///
    /// Two decisions worth the ink:
    ///
    /// - `develop_json` holds the whole preset envelope (schemaVersion, name, groups, fragment),
    ///   encoded with the same canonical encoder as `assets.develop_json` (`Catalog.encode`). Name
    ///   and groups are duplicated in the envelope *on purpose*: the row is a cache of facts the
    ///   envelope owns, so a preset can be exported to a file and re-imported with nothing lost.
    /// - `is_default` has a **partial unique index**, so "exactly one default preset" is enforced by
    ///   SQLite rather than by remembering to clear the previous one. `setDefaultPreset` still clears
    ///   in the same transaction, because a constraint violation is a worse error message than a
    ///   successful swap.
    private static let v4 = """
    CREATE TABLE presets(
      id           TEXT PRIMARY KEY,
      name         TEXT NOT NULL,
      develop_json TEXT NOT NULL,
      is_default   INTEGER NOT NULL DEFAULT 0,
      created_at   TEXT NOT NULL,
      updated_at   TEXT NOT NULL
    );
    CREATE UNIQUE INDEX idx_presets_name ON presets(name COLLATE NOCASE);
    CREATE UNIQUE INDEX idx_presets_default ON presets(is_default) WHERE is_default = 1;
    """
}
