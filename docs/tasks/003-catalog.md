# Task 003 — M2: catalog + import

**Status:** todo (spec ready) · **Depends on:** 002 (green) · **Owner:** unclaimed
**Claim:** `bus.py claim --task 003-catalog`

## Goal

M1 能用一条命令把一张 RAW 渲成 JPEG，但程序不知道"库里有几万张、每张的编辑参数在哪、文件没了该怎样"。
M2 建库与导入：**一个库包 + 一张 SQLite 表 + 一条可中断可续的导入流水线**，没有 UI、没有监听、不碰渲染。

判据只有一句：`make verify` 全绿且 M2 的验收链（`make catalog`）逐条实测通过。

## 一、写这个规格之前已经定下的事（不要再讨论）

| 决定 | 取值 | 依据 |
|---|---|---|
| 库引擎 | **SQLite + WAL，GRDB 7.11.1（MIT）** | D8；GRDB 是项目第一个第三方依赖，版本钉死 |
| schema 形状 | **宽主表 + 冷列 1:1 卫星表 + 关键词/相册多对多** | 用户 2026-10-25 选 A |
| 相机/镜头 | **文本列 `camera_make/camera_model/camera_key/lens`，不建字典表** | 同上（digiKam 形状；dt 的字典表+视图留作可逆的第二步） |
| 身份哈希 | **全文件 SHA-256** 为 `content_hash`（UNIQUE）；`quick_hash` 只做预筛 | digiKam 用 EXIF 块 MD5 当身份是错的（改星就变身份，全库重算过）；头尾 100 KB 也不够 |
| 卷标识 | **volume UUID + 相对路径** + security-scoped bookmark | digiKam（`AlbumRoots`）；换挂载点仍能找到 |
| 删除 | **软删**（`deleted`）+ **独立的 online/offline 状态** | digiKam `INNER JOIN` 静默丢图是真实事故 |
| 导入 | **文件级事务 + sessions/import_files 台账**，可中断可续 | PhotoCatalog `import_sessions`/`import_files`（设计参照，GPL 未抄码） |
| 元数据 | **只读内嵌 XMP**（`CGImageMetadata`），**绝不读 `.xmp` sidecar**；`crs:*` 不解析，原文存 blob | 用户 2026-10-25 决定 |
| 不做 | UI、目录监听、缩略图、FTS、Lightroom 迁库、XMP 写回、预设 | 依次属于 M3/M5 |

## 二、库的形态

```
<Name>.photonslibrary/                 ← 目录包，整体可移动
├── library.db (+ -wal, -shm)          ← 唯一真相
├── originals/YYYY/MM/…                ← 仅 copy 模式
├── previews/                          ← M3 用，M2 只建空目录
└── backups/library.bak-v<n>.db        ← 迁移前自动快照，保留 2 份
```

- 用**目录包**而不是单文件：copy 模式的 originals 需要一个确定的家，打包后"挪一个 item = 搬家完毕"（避免 Lightroom `.lrcat` + `Previews.lrdata` 那种兄弟文件走散）。
- 库外缓存：`~/Library/Caches/Photons/<sha1(库包绝对路径)>/`（darktable 的做法：按库隔离，多库不互相污染）。M0 的线性缓冲缓存路径随之迁移。
- 连接配置：`journal_mode=WAL`、`synchronous=NORMAL`、`foreign_keys=ON`、`busy_timeout=5000`。

## 三、Schema v1

```sql
-- 库级元数据：版本号与数据同库（digiKam 的教训：备份/迁移不脱节）
CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
--   schema_version        = "1"
--   unique_hash_version   = "1"   ← 哈希算法换代时必须能识别旧哈希
--   app_version           = "0.0.0+<build>"

-- 导入来源（根）：卷 UUID 而非路径
CREATE TABLE source_roots(
  id              TEXT PRIMARY KEY,
  volume_uuid     TEXT,               -- 外置卷为 Disk UUID；本地目录为 nil
  bookmark        BLOB,               -- security-scoped bookmark（引用模式）
  display_name    TEXT NOT NULL,
  path_hint       TEXT NOT NULL,      -- 最近一次已知绝对路径
  management_mode TEXT NOT NULL,      -- 'reference' | 'copy'
  status          TEXT NOT NULL,      -- 'online' | 'offline'（打开/重扫时更新）
  created_at      TEXT NOT NULL
);

-- 主表：只放热列（列表/网格/筛选要用的）
CREATE TABLE assets(
  id                   TEXT PRIMARY KEY,
  source_root_id       TEXT NOT NULL REFERENCES source_roots(id) ON DELETE CASCADE,
  rel_path             TEXT NOT NULL,             -- 相对 root，卷 UUID 方案的关键
  filename             TEXT NOT NULL,
  ext                  TEXT NOT NULL,
  kind                 TEXT NOT NULL,             -- 'raw' | 'jpeg' | 'heic'
  size                 INTEGER NOT NULL,
  mtime                REAL NOT NULL,
  content_hash         TEXT NOT NULL,             -- 全文件 SHA-256 = 身份
  quick_hash           TEXT,                      -- size+mtime+首尾 1MB，预筛用，非身份
  width                INTEGER,
  height               INTEGER,
  capture_time         TEXT,                      -- ISO8601 UTC 'Z'，排序用
  capture_local_date   TEXT,                      -- 'YYYY-MM-DD'，按日期分目录/分组用
  capture_time_source  TEXT,                      -- 'exif' | 'file' | 'none'
  rating               INTEGER NOT NULL DEFAULT 0,
  flag                 TEXT,                      -- 'pick' | 'reject' | NULL
  color_label          TEXT,
  camera_make          TEXT,
  camera_model         TEXT,
  camera_key           TEXT,                      -- lower(make|model)，筛选/分组用
  lens                 TEXT,
  develop_json         TEXT NOT NULL DEFAULT '{}',-- M1 的 EditModel blob（唯一真相）
  develop_version      INTEGER NOT NULL DEFAULT 1,
  render_version       INTEGER NOT NULL DEFAULT 1,
  imported_at          TEXT NOT NULL,
  checked_at           TEXT,                      -- 最近一次确认文件存在的时刻
  deleted              INTEGER NOT NULL DEFAULT 0,
  UNIQUE(content_hash),
  UNIQUE(source_root_id, rel_path)
);

-- 冷列 1:1 卫星表：EXIF 全量、XMP 原文，只在检查器里读
CREATE TABLE asset_metadata(
  asset_id      TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
  exif_json     TEXT NOT NULL DEFAULT '{}',       -- ImageIO properties 全量，逐字保存
  xmp_blob      TEXT,                             -- 内嵌 XMP 原文（含 crs:*，不解析）
  iso           INTEGER,
  focal_length  REAL,
  aperture      REAL,
  shutter       TEXT,
  orientation   INTEGER
);

-- 快照栈（D10）：assets.develop_json 是当前值，这里是历史
CREATE TABLE asset_history(
  asset_id      TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,
  develop_json  TEXT NOT NULL,
  label         TEXT,
  created_at    TEXT NOT NULL,
  PRIMARY KEY(asset_id, seq)
);

-- 关键词：真多对多，必须规范化
CREATE TABLE keywords(id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES keywords(id) ON DELETE CASCADE);
CREATE UNIQUE INDEX idx_keywords_name ON keywords(name);
CREATE TABLE photo_keywords(
  asset_id   TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  keyword_id TEXT NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
  PRIMARY KEY(asset_id, keyword_id)
);

-- 相册/集合：真多对多
CREATE TABLE albums(id TEXT PRIMARY KEY, parent_id TEXT REFERENCES albums(id) ON DELETE CASCADE,
                    name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
CREATE TABLE album_assets(
  album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(album_id, asset_id)
);

-- 导入台账：可中断可续的全部秘密
CREATE TABLE import_sessions(
  id TEXT PRIMARY KEY, source_root_id TEXT REFERENCES source_roots(id) ON DELETE CASCADE,
  mode TEXT NOT NULL, state TEXT NOT NULL,          -- 'running' | 'finished' | 'failed'
  total_count INTEGER NOT NULL DEFAULT 0, imported_count INTEGER NOT NULL DEFAULT 0,
  skipped_count INTEGER NOT NULL DEFAULT 0, failed_count INTEGER NOT NULL DEFAULT 0,
  started_at TEXT NOT NULL, finished_at TEXT, error_message TEXT
);
CREATE TABLE import_files(
  session_id TEXT NOT NULL REFERENCES import_sessions(id) ON DELETE CASCADE,
  source_path TEXT NOT NULL,                        -- 源侧绝对路径
  asset_id TEXT, outcome TEXT NOT NULL,             -- 'added'|'duplicate'|'unchanged'|'failed'
  reason TEXT, seen_at TEXT NOT NULL,
  PRIMARY KEY(session_id, source_path)
);

-- 查询索引：每一条都对应 `catalog-schema-bench.py` 量过的一个形状
CREATE INDEX idx_assets_grid     ON assets(deleted, capture_time DESC, id);
CREATE INDEX idx_assets_imported ON assets(deleted, imported_at DESC, id);
CREATE INDEX idx_assets_rating   ON assets(deleted, rating, capture_time DESC, id);
CREATE INDEX idx_assets_filename ON assets(deleted, filename COLLATE NOCASE, id);
CREATE INDEX idx_assets_camera   ON assets(deleted, camera_key, capture_time DESC, id);
CREATE INDEX idx_assets_root     ON assets(source_root_id, rel_path);
CREATE INDEX idx_assets_hash     ON assets(content_hash);   -- UNIQUE 已隐含，但显式声明意图
CREATE INDEX idx_import_files_session ON import_files(session_id, outcome);
```

**没建的东西，以及为什么**：`jobs`（M3 缩略图才需要队列）、FTS5（M3 有搜索框再上，PhotoCatalog 用 `tokenize='trigram'` 且短查询降级）、`camera`/`lens` 字典表（A 决定）、`masks`/`presets`（M4/M5）。

## 四、导入流水线

### 4.1 状态机

```
create session(state=running) ──► 遍历文件 ──► 每文件一个事务 ──► state=finished
                                        └─ 崩溃/被杀 ──► 重开时 state=running 的会话可续：
                                                        按 import_files 里 outcome='added' 的 source_path 跳过
```
每文件的 `outcome`：`added`（新入库）、`duplicate`（同 content_hash 已在库，跳过并记 asset_id）、`unchanged`（quick_hash + size + mtime 命中，连文件都不读）、`failed`（附 `reason`）。

### 4.2 单文件事务边界（顺序不可换）

```
1. stat: size, mtime
2. quick_hash 预筛：命中已有 asset 且 size+mtime 一致 → outcome=unchanged，结束（不读文件内容）
3. 全文件 SHA-256 → 与既有 content_hash 比对 → 命中则 outcome=duplicate，结束
4. 读元数据：ImageIO properties + CGImageMetadata（内嵌 XMP）
5. copy 模式：复制到 originals/YYYY/MM/<name>（先写 .tmp 再 rename）
6. BEGIN；INSERT assets；INSERT asset_metadata；INSERT asset_history(seq=1)；
   INSERT import_files；UPDATE sessions 计数；COMMIT
```
**先落文件、再写库**。反过来会在崩溃后留下"库里有行、磁盘没文件"的 offline 资产（用户可见的坏状态）；先落文件最坏只留下一个孤儿文件，重扫时可被收养或清理。

### 4.3 哈希策略

- `content_hash`：全文件 SHA-256，**首次导入必算**（去重必须可信）。
- `quick_hash`：`SHA-256(size | mtime | 首 1MB | 尾 1MB)`。只用于**重复扫描**时跳过整文件读取，**绝不用于身份判定**。
- `unique_hash_version` 写入 `settings`：将来换算法（例如加 BLAKE3）时，旧值可被识别并后台重算。

### 4.4 元数据（只读内嵌 XMP）

**重要更正（实测，2026-10-25）**：`kCGImagePropertyXMPDictionary` 在 SDK 里**不存在**（`CGImageProperties.h` 无任何 XMP 符号），`CGImageSourceCopyPropertiesAtIndex` 也不会给出 `{XMP}`（本机 DNG 实测为 nil，而文件里确有 15,478 字节 XMP 包，位于 TIFF tag 700）。**正确 API 是 `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataRef`**，实测能读到 `crs:Version=18.5.1`、`crs:CameraProfile`、`exifEX:LensMake` 等。

映射（只取这些，其余不解释）：

| XMP / EXIF 来源 | 落库列 |
|---|---|
| `xmp:Rating` | `assets.rating` |
| `xmp:Label` | `assets.color_label` |
| `dc:subject`（可多次） | `keywords` + `photo_keywords` |
| `photoshop:DateCreated` / `exif:DateTimeOriginal` / `tiff:DateTime` | `capture_time`（UTC）+ `capture_time_local_date` |
| `tiff:Make` / `tiff:Model` | `camera_make/model` + `camera_key` |
| `exifEX:LensModel` / `aux:Lens` | `lens` |
| `exif:ISOSpeedRatings` / `exif:FocalLength` / `exif:FNumber` / `exif:ExposureTime` / `tiff:Orientation` | `asset_metadata` 对应列 |
| **整个 XMP packet 原文** | `asset_metadata.xmp_blob`（`crs:*` 一个都不解析，只存档） |

**绝不读** 同名 `.xmp` sidecar（用户决定）；发现 sidecar 只记一条 `import_files.reason='sidecar-ignored'`，不入库。

### 4.5 卷与离线

- 打开库时：对每个 `source_roots` 检查 `path_hint` 可达 + `volume_uuid` 是否匹配当前挂载卷 → 更新 `status`。
- `status='offline'` 的根，其下资产**照常出现在库里**（可筛选、可看缩略图缓存），只是不可渲染；不删行、不清 `develop_json`。
- `rescan` 只做三件事：补新文件、标 missing（`checked_at` 落后且文件不存在 → 资产保持 online 状态但记 `checked_at`，另由 `library verify` 报告）、修正 `rel_path`（同 hash 不同路径 = 移动）。
- **不做** 目录监听（M3）。文件在应用外的移动/改名，靠 `rescan` 兜底。

## 五、迁移与保护

- **GRDB `DatabaseMigrator`**，一个版本一个 `migrate` 闭包，顺序执行（darktable 的 57 步纪律）。
- **迁移前自动快照**：`backups/library.bak-v<当前版本>.db`，保留 2 份，迁移成功后才继续打开。
- **前向保护**：`PRAGMA user_version > 当前已知最大值` → 抛 `CatalogError.libraryFromNewerVersion`，**拒绝打开**并提示"由更新版本的 Photons 创建"（ART 的反面教训：新文件在旧程序里静默丢字段）。
- 迁移失败 → 自动回滚到快照并原样抛错；不允许半迁移状态留库。

## 六、CLI（M2 没有 UI，验收全靠它）

```bash
photonsctl library create  <pkg> [--copy|--reference]
photonsctl library import  <pkg> <src...> [--mode copy|reference] [--root <id|path>]
                           [--rename '{YYYY}/{MM}/{name}'] [--json] [--test-interrupt-after N]
photonsctl library rescan  <pkg> [--root <id>]
photonsctl library assets  <pkg> [--rating>=N] [--camera <key>] [--since <date>] [--limit N] [--json]
photonsctl library stats   <pkg>
photonsctl library verify  <pkg>            # 完整性：hash 不符 / 行指向不存在的文件 / 孤儿文件
photonsctl library fixtures <dir> --count N [--dupes 10%]   # 确定性合成样本，供验收用
```

`--test-interrupt-after N` 是**验收钩子**（导到第 N 个文件后 `_exit(137)` 模拟被杀），不是产品语义，写在 `--help` 里注明。

## 七、验收

`make verify` 追加 `catalog` 一环；`make catalog` 跑下面全部（脚本 `Tests/catalog-acceptance.sh`，退出码即结论）：

| # | 检查 | 命令 | 通过条件 |
|---|---|---|---|
| 1 | 去重 | `fixtures --count 1000 --dupes 10%` → `import` | `added=900, duplicate=100`；`stats` = 900 |
| 2 | 重复导入 | 同一目录再 `import` | 新增 0，全部 `unchanged`/`duplicate`；`stats` 不变 |
| 3 | 可中断可续 | `import --test-interrupt-after 300` → 重开 → `import` 同目录 | 最终 `added=900`；库里无重复 `content_hash`；`import_files` 无半条记录 |
| 4 | 移动不丢 | `mv` 5 个文件后 `rescan` | 5 条记录 `rel_path` 更新为新位置，`id` 与 `develop_json` 不变 |
| 5 | 卷离线 | 把 root 目录改名（模拟未挂载）→ `library stats` | 根 `status=offline`，资产数**不变**，无一行被删 |
| 6 | 迁移保护 | 手工把 `user_version` 改成 999 → 打开 | 拒绝打开，错误信息含 "newer version"，库文件未被修改 |
| 7 | 迁移正确性 | v1 库 → 造一个 v2 迁移 → 打开 | 快照已生成，`develop_json` 逐字节不变 |
| 8 | 查询耗时 | 1 万行库 | 网格首页、`rating>=4`、机身筛选三条各 **< 50 ms**（打印实测值） |
| 9 | 元数据 | 导入用户真实 DNG | `rating/color_label/camera_key/lens` 与文件内嵌 XMP 一致；`xmp_blob` 非空；**未**创建任何 `.xmp` |
| 10 | 全链 | `make verify` | build + 23 单测（M1）+ 新单测 + L1/L2/L3 + bench + catalog 全绿 |

单测（`Tests/PhotonsCatalogTests/`）：schema 建库/重复建库、`content_hash` 唯一约束、软删后不出现在默认查询、`camera_key` 归一化（大小写/空格）、XMP 映射表逐项、迁移快照与回滚、`quick_hash` 不算身份。

## 八、不做（M2 边界）

UI / 目录监听 / 缩略图 / FTS 搜索 / Lightroom `.lrcat` 迁移 / XMP 写回 / 预设 / 批量导出 / 人脸与语义蒙版 / MySQL 后端。
`PhotoCatalog`（GPL-3）只读设计与注释，**一行代码都不并入**；`PixelLoupe` 的 `LightroomImport/`（MIT）与本任务无关（A 决定不做迁库）。

## 九、工作分解（一个 worktree，估计）

| 文件 | 内容 | 估行 |
|---|---|---|
| `Sources/PhotonsCatalog/Database.swift` | 打开/配置/WAL/迁移器/快照/前向保护 | ~230 |
| `Sources/PhotonsCatalog/Schema.swift` | v1 迁移闭包（上面的 DDL） | ~200 |
| `Sources/PhotonsCatalog/Models.swift` | `Asset`/`AssetMetadata`/`SourceRoot`/`ImportSession` 等 GRDB 记录 | ~200 |
| `Sources/PhotonsCatalog/Catalog.swift` | CRUD、软删、可用性、筛选查询、统计 | ~330 |
| `Sources/PhotonsCatalog/ImportService.swift` | 遍历/哈希/去重/复制/会话台账/续跑 | ~400 |
| `Sources/PhotonsCatalog/MetadataReader.swift` | ImageIO + `CGImageMetadata` → 列 | ~170 |
| `Sources/photonsctl/main.swift` | `library` 子命令 + `fixtures` | ~260 |
| `Tests/PhotonsCatalogTests/*.swift` | 单测 | ~500 |
| `Tests/catalog-acceptance.sh` + Makefile | 验收链 | ~140 |
| 合计 | | **~2,430 行** + GRDB |

`Package.swift`：`PhotonsCatalog` 新 target，依赖 `GRDB 7.11.1`（`.upToNextMajor`），photonsctl 依赖它；新增 `THIRD_PARTY_NOTICES.md`（GRDB MIT + 其内置 SQLite 的公有领域声明），并在第一步确认 GRDB 7.11.1 的**传递依赖为 0**（若不为 0，先停下来问）。

## 十、风险

| 风险 | 应对 |
|---|---|
| GRDB 引入传递依赖（SPI 页面提到 2 个包，疑为文档/测试插件） | 实施第一步验证并记录；若真引入运行时依赖 → 停下来问用户 |
| `kill -9` 时 WAL 半写 | 每文件事务 + 重开时 `PRAGMA integrity_check` + 会话续跑；验收 #3 实测 |
| 外置盘 exFAT/NTFS 大小写与 Unicode 规范化 | `rel_path` 存原样、比较时 `caseInsensitive` + NFC 归一化 |
| security-scoped bookmark 失效（换机/重装） | bookmark 只是加速器；失效时退回 `volume_uuid + path_hint` 匹配 |
| 时区：`capture_time` 用 UTC，日期分目录要本地日期 | 同时存 `capture_local_date`（导入时按 EXIF 里的 offset 算出） |
| 一次导入 5 万张时的内存 | 流式遍历，不建全量数组；每 500 个文件提交一次统计（不是事务） |
