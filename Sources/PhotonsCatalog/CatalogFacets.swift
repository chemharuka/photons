import Foundation
import GRDB

// MARK: - what a dimension is made of

extension FilterDimension {

    /// The dimensions whose clause reads the `asset_metadata` satellite table.
    ///
    /// The query `LEFT JOIN`s it **only** when one of these is on, so a plain 星级/相机 filter keeps
    /// running against `assets` alone — the join is per-query cost, and the grid re-queries on every
    /// keystroke of the filter bar.
    public var needsMetadata: Bool {
        switch self {
        case .serial, .focal, .shutter, .aperture, .iso, .flash, .gps: return true
        case .month, .day, .ext, .rating, .flag, .color, .camera, .lens: return false
        }
    }

    /// The dimension whose value list is a **fixed vocabulary** rather than "what this library
    /// happens to hold". 星级 / 旗标 / 色标 are a closed set of words a photographer picks from; the
    /// other twelve are facts that only exist for the rows that have them.
    public var hasFixedVocabulary: Bool {
        switch self {
        case .rating, .flag, .color: return true
        default: return false
        }
    }

    /// The fixed list, in the order the popup shows it. `nil` for the data-driven dimensions.
    public var fixedValues: [String]? {
        switch self {
        case .rating: return ["5", "4", "3", "2", "1", "0"]     // descending: ≥5★ first
        case .flag: return ["pick", "reject", FilterValue.none]
        case .color: return ColorLabelNames.all + [FilterValue.none]
        default: return nil
        }
    }
}

/// Colour-label raw values, in the popup order. `PhotonsCatalog` cannot see the AppKit `ColorLabel`
/// enum (it lives in `PhotonsUI`), and the value that goes in `assets.color_label` is the plain
/// lowercase word, so the list is spelled here once and the UI maps it to 红/橙/黄/绿/蓝/紫.
public enum ColorLabelNames {
    public static let all = ["red", "orange", "yellow", "green", "blue", "purple"]
}

/// Sentinels for the dimensions whose interesting value is an *absence*.
///
/// `"none"` is not a value the database can hold (the columns are `NULL` for 未标记 / 无色标), and
/// `"1"`/`"0"` are the 有/无 answers for 闪光灯 and GPS — kept as strings because a criterion's value
/// is a string all the way to the popup, and a second typed payload would be one concept too many.
public enum FilterValue {
    public static let none = "none"
    public static let yes = "1"
    public static let no = "0"
}

// MARK: - SQL

/// One criterion → one `WHERE` clause, every user value bound as `?`.
///
/// Two rules the rest of the file keeps:
///
/// - **No value is ever interpolated.** Folder names (021) already taught this lesson: a folder
///   called `100%_raw` is data, and a `LIKE` built from it silently matched other rows. The same is
///   true of a lens called `85mm F1.2 DG | Art 026` — quotes, pipes, percent signs and all.
/// - **JSON paths are bound too**, because the path is the one string that decides which EXIF field
///   is read; with it in the SQL text a typo would be a syntax error instead of an empty column.
enum FilterSQL {

    // The EXIF blob is a *nested* dictionary whose top-level keys are literally `{Exif}`, `{GPS}`,
    // … (`MetadataReader` writes them that way, and `assets.exif_json` is the same document).
    //
    // SQLite's JSON path treats `."…"` as a **quoted object label**, and a quoted label keeps dots
    // inside it — so `$."{EXIF}.BodySerialNumber"` asks for a *root* key named
    // `{Exif}.BodySerialNumber`, which never exists. The nested spelling `$.{Exif}.BodySerialNumber`
    // is the one that reads the value (measured on `~/Documents/photons-demo.photonslibrary`: ->
    // `5954607`, `Flash` -> `16`, `{GPS}.Latitude` -> `30.0036…`). Both spellings are listed and
    // `COALESCE`d, so a library whose EXIF was flattened into dotted root keys still reads.
    static let flashPaths = ["$.{Exif}.Flash", "$.\"{Exif}.Flash\""]
    static let latitudePaths = ["$.{GPS}.Latitude", "$.\"{GPS}.Latitude\""]
    static let longitudePaths = ["$.{GPS}.Longitude", "$.\"{GPS}.Longitude\""]
    static let serialPaths = [
        "$.{Exif}.BodySerialNumber", "$.\"{Exif}.BodySerialNumber\"",
        "$.{ExifAux}.SerialNumber", "$.\"{ExifAux}.SerialNumber\"",
    ]

    typealias Args = [any DatabaseValueConvertible]

    /// `COALESCE(json_extract(m.exif_json, ?), …)` plus the paths to bind, in order.
    static func extract(_ paths: [String]) -> (sql: String, args: Args) {
        let pieces = paths.map { _ in "json_extract(m.exif_json, ?)" }
        return ("COALESCE(" + pieces.joined(separator: ", ") + ")", paths)
    }

    /// 有 / 无 for 闪光灯. `0` = did not fire, anything else = fired, and a missing key is 无.
    ///
    /// `CAST(… AS INTEGER)` rather than a bare `<> 0`: a JSON string `"0"` compares **greater** than
    /// the number `0` in SQLite (text sorts above numbers), which would have called an unfired flash
    /// "fired".
    static func flash(_ value: String) -> (sql: String, args: Args) {
        let e = extract(flashPaths)
        let fired = "(\(e.sql) IS NOT NULL AND CAST(\(e.sql) AS INTEGER) <> 0)"
        let sql = value == FilterValue.yes
            ? fired
            : "NOT \(fired)"
        return (sql, e.args + e.args)
    }

    /// 有 / 无 for GPS — the owner's rule (2026-10-26): **both** coordinates have to be there and they
    /// must not be `0, 0`. A camera that writes a zeroed GPS block is not "a photo taken at the
    /// Gulf of Guinea", it is a photo with no fix; the file says so with `{GPS}.Latitude = 0`.
    static func gps(_ value: String) -> (sql: String, args: Args) {
        let lat = extract(latitudePaths)
        let lon = extract(longitudePaths)
        let has = "(\(lat.sql) IS NOT NULL AND \(lon.sql) IS NOT NULL"
            + " AND NOT (CAST(\(lat.sql) AS REAL) = 0 AND CAST(\(lon.sql) AS REAL) = 0))"
        let sql = value == FilterValue.yes ? has : "NOT \(has)"
        return (sql, lat.args + lon.args + lat.args + lon.args)
    }

    /// 「有没有这个字段」 — deliberately different from 有/无: a library where every photo wrote
    /// `Flash = 0` **has** flash data (offering 无 is honest), where one with no `Flash` key at all does
    /// not (spec ④: an empty list, 「本库无此数据」).
    static func flashPresent() -> (sql: String, args: Args) {
        let e = extract(flashPaths)
        return ("\(e.sql) IS NOT NULL", e.args)
    }

    static func gpsPresent() -> (sql: String, args: Args) {
        let lat = extract(latitudePaths)
        let lon = extract(longitudePaths)
        return ("(\(lat.sql) IS NOT NULL AND \(lon.sql) IS NOT NULL)", lat.args + lon.args)
    }

    /// The value expression a facet list groups by. `nil` for the fixed vocabularies.
    ///
    /// 快门速度 is deliberately left **raw** (`m.shutter`): a Leica DNG holds `55924/44739201` and a
    /// card written elsewhere holds `1/250`. Grouping on the raw string would list both spellings of
    /// the same shutter as two choices; `facetValues` normalises through `ShutterFormat` and the
    /// criterion is compiled into the `IN (…)` list of every raw spelling that normalises to it.
    static func facetExpression(_ dimension: FilterDimension) -> (sql: String, args: Args)? {
        switch dimension {
        case .month: return ("substr(a.capture_local_date, 6, 2)", [])
        case .day: return ("substr(a.capture_local_date, 9, 2)", [])
        case .ext: return ("lower(a.ext)", [])
        case .camera: return ("a.camera_key", [])
        case .lens: return ("a.lens", [])
        case .serial: return extract(serialPaths)
        case .focal: return ("CAST(ROUND(m.focal_length) AS INTEGER)", [])
        case .shutter: return ("m.shutter", [])
        case .aperture: return ("ROUND(m.aperture, 1)", [])
        case .iso: return ("m.iso", [])
        case .rating, .flag, .color, .flash, .gps: return nil
        }
    }
}

// MARK: - one criterion → one clause

extension Catalog {

    /// Compile one criterion into `(sql, args)`. The clause never contains a user value.
    ///
    /// `db` is needed for exactly one dimension (快门速度), whose stored spelling is not the value
    /// the user picked: the clause has to name every raw string in the library that normalises to
    /// that shutter, so it asks the catalogue what those are. Everything else is a pure expression.
    static func clause(for criterion: FilterCriterion, in db: Database) throws -> (sql: String, args: FilterSQL.Args) {
        let v = criterion.value
        switch criterion.dimension {
        case .month:
            return ("substr(a.capture_local_date, 6, 2) = ?", [v])
        case .day:
            return ("substr(a.capture_local_date, 9, 2) = ?", [v])
        case .ext:
            return ("lower(a.ext) = ?", [v.lowercased()])
        case .rating:
            // 026 v2 §5: a slot's 星级 values are **tiers**, not thresholds — 1★·2★·5★ is
            // `rating IN (1,2,5)`, so 3★ is *not* included. The old `>= N` meaning still lives in
            // `AssetFilter.ratingAtLeast`, untouched, for the CLI and the presets.
            return ("a.rating = CAST(? AS INTEGER)", [v])
        case .flag:
            return v == FilterValue.none
                ? ("(a.flag IS NULL OR a.flag = '')", [])
                : ("a.flag = ?", [v.lowercased()])
        case .color:
            return v == FilterValue.none
                ? ("(a.color_label IS NULL OR a.color_label = '')", [])
                : ("a.color_label = ?", [v.lowercased()])
        case .camera:
            return ("a.camera_key = ?", [v.lowercased()])
        case .lens:
            return ("a.lens = ?", [v])
        case .serial:
            let e = FilterSQL.extract(FilterSQL.serialPaths)
            return ("\(e.sql) = ?", e.args + [v])
        case .focal:
            // The lens is a zoom: 23.6 mm and 24.4 mm are both "24 mm" on the bar, so the comparison
            // is on the rounded value — the same number the facet list prints.
            return ("CAST(ROUND(m.focal_length) AS INTEGER) = CAST(? AS INTEGER)", [v])
        case .aperture:
            return ("ROUND(m.aperture, 1) = ROUND(CAST(? AS REAL), 1)", [v])
        case .iso:
            return ("m.iso = CAST(? AS INTEGER)", [v])
        case .shutter:
            let raws = try String.fetchAll(db, sql: """
                SELECT DISTINCT m.shutter FROM assets a
                JOIN asset_metadata m ON m.asset_id = a.id
                WHERE a.deleted = 0 AND m.shutter IS NOT NULL
                """)
            let matching = raws.filter { ShutterFormat.standard(from: $0) == v }
            guard !matching.isEmpty else { return ("0", []) }        // 没有一排能是这个快门 → 空集
            let marks = Array(repeating: "?", count: matching.count).joined(separator: ", ")
            return ("m.shutter IN (\(marks))", matching)
        case .flash:
            return FilterSQL.flash(v)
        case .gps:
            return FilterSQL.gps(v)
        }
    }
}

// MARK: - the query, assembled once

extension Catalog {

    /// `assets` + every constraint in `filter`, minus `ORDER BY`/`LIMIT` (which the facet query does
    /// not want). `excluding` drops the criteria and legacy fields of one dimension, which is what a
    /// facet list needs: asking "which cameras are there" while the camera filter is on would
    /// otherwise always answer with the one camera already chosen.
    static func constraints(of filter: AssetFilter,
                            excluding dimension: FilterDimension? = nil,
                            in db: Database) throws
        -> (clauses: [String], args: FilterSQL.Args, needsMetadata: Bool) {

        var clauses: [String] = []
        var args: FilterSQL.Args = []
        var needsMetadata = false

        if !filter.includeDeleted { clauses.append("a.deleted = 0") }
        func isKept(_ d: FilterDimension) -> Bool { d != dimension }

        if let r = filter.ratingAtLeast, isKept(.rating) { clauses.append("a.rating >= ?"); args.append(r) }
        if let c = filter.cameraKey, isKept(.camera) {
            clauses.append("a.camera_key = ?"); args.append(c.lowercased())
        }
        if let f = filter.flagEquals, isKept(.flag) {
            clauses.append(f == FilterValue.none ? "(a.flag IS NULL OR a.flag = '')" : "a.flag = ?")
            if f != FilterValue.none { args.append(f) }
        }
        if let l = filter.colorLabelEquals, isKept(.color) {
            clauses.append(l == FilterValue.none ? "(a.color_label IS NULL OR a.color_label = '')" : "a.color_label = ?")
            if l != FilterValue.none { args.append(l) }
        }
        if let d = filter.sinceLocalDate { clauses.append("a.capture_local_date >= ?"); args.append(d) }

        // Folder selection: an **OR group** of `(root match AND path prefix)` clauses, every value
        // bound (`?`), never interpolated — a folder is data (`100%_raw` is a real folder name in the
        // tests), so it must never reach the SQL text.
        //
        // Segment-safe by construction: `instr(rel_path, 'day2/') = 1` asks "does the path *start*
        // with this exact text", which cannot swallow `day2x/` (the prefix ends in `/`) and cannot be
        // fooled by a `_` or `%` in the name. An empty path is the root itself, so it contributes a
        // bare `source_root_id = ?`. 「全部照片」 wins over the other rows (021 §B).
        if !filter.folders.contains(where: { $0.isAllPhotos }) {
            var folderClauses: [String] = []
            for folder in filter.folders {
                guard let root = folder.rootId else { continue }
                if let path = folder.normalizedPath {
                    folderClauses.append("(a.source_root_id = ? AND instr(a.rel_path, ?) = 1)")
                    args.append(root)
                    args.append(path + "/")
                } else {
                    folderClauses.append("(a.source_root_id = ?)")
                    args.append(root)
                }
            }
            if !folderClauses.isEmpty {
                clauses.append("(" + folderClauses.joined(separator: " OR ") + ")")
            }
        }

        // Criteria: **same dimension ORs, different dimensions AND** (026 v2). A slot holding
        // 1★·2★·5★ arrives as three criteria of `.rating`; grouping them into one clause is what
        // makes it `rating IN (1,2,5)` rather than three ANDed equalities (which would be empty).
        var dimensionOrder: [FilterDimension] = []
        var valuesByDimension: [FilterDimension: [String]] = [:]
        for criterion in filter.criteria where isKept(criterion.dimension) {
            if valuesByDimension[criterion.dimension] == nil { dimensionOrder.append(criterion.dimension) }
            valuesByDimension[criterion.dimension, default: []].append(criterion.value)
            if criterion.dimension.needsMetadata { needsMetadata = true }
        }
        for dimension in dimensionOrder {
            var parts: [String] = []
            var partArgs: FilterSQL.Args = []
            for value in valuesByDimension[dimension] ?? [] {
                let compiled = try clause(for: FilterCriterion(dimension: dimension, value: value), in: db)
                parts.append(compiled.sql)
                partArgs.append(contentsOf: compiled.args)
            }
            guard !parts.isEmpty else { continue }
            clauses.append(parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")")
            args.append(contentsOf: partArgs)
        }
        return (clauses, args, needsMetadata)
    }

    static func assetsQuery(_ filter: AssetFilter, in db: Database) throws -> (sql: String, args: FilterSQL.Args) {
        let (clauses, args, needsMetadata) = try constraints(of: filter, in: db)
        var sql = "SELECT a.* FROM assets a"
        if needsMetadata { sql += " LEFT JOIN asset_metadata m ON m.asset_id = a.id" }
        sql += " WHERE " + (clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND "))
        sql += " ORDER BY a.capture_time DESC, a.id LIMIT ?"
        var bound = args
        bound.append(filter.limit)
        return (sql, bound)
    }
}

// MARK: - facet values

extension Catalog {

    /// The values a slot's right-hand popup offers for `dimension`, **as this library actually is**.
    ///
    /// The owner's rule (2026-10-26): 相机 序列号 镜头 焦距 快门速度 光圈 ISO must be offered *from the
    /// numbers that exist* — 「如果所有照片都没焦距，就只能选『全部』」. So a data-driven dimension with
    /// nothing in the library returns `[]` (the popup then holds only 全部), never an invented
    /// vocabulary like `100 / 200 / 400`. 星级/旗标/色标 are the exception: they are a closed language
    /// the user picks from, so they answer with the full list even in an empty library.
    ///
    /// Scoped to `filter` **minus its own dimension**: the list answers "what else is there", so a
    /// camera already chosen must not collapse its own popup to that one camera. Errors are swallowed
    /// to `[]` — a broken library should show an empty popup, not take the grid down.
    public func facetValues(_ dimension: FilterDimension,
                            filter: AssetFilter = AssetFilter()) -> [String] {
        if let fixed = dimension.fixedValues { return fixed }
        let rows = (try? dbQueue.read { db in
            try Self.facetRows(dimension, filter: filter, in: db)
        }) ?? []
        return Self.sortedFacetValues(rows, for: dimension)
    }

    /// Raw value rows, before sorting/dedupe: `[String]`, or the 有/无 pair for the presence dims.
    static func facetRows(_ dimension: FilterDimension,
                          filter: AssetFilter,
                          in db: Database) throws -> [String] {
        let (clauses, args, _) = try constraints(of: filter, excluding: dimension, in: db)
        var where_ = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")

        if dimension == .flash || dimension == .gps {
            // Presence dimensions: 有/无 only make sense as a pair when *some* row carries the field.
            // 「本库无此数据」 (empty list) is the answer for a library that has no flash or no GPS at
            // all — that is spec 026 ④, and it is why this is not simply a fixed ["1","0"]. A library
            // where every row wrote `Flash = 0` is different: it has the data, and its only honest
            // offer is 无.
            let has = dimension == .flash ? FilterSQL.flash(FilterValue.yes) : FilterSQL.gps(FilterValue.yes)
            let present = dimension == .flash ? FilterSQL.flashPresent() : FilterSQL.gpsPresent()
            // Argument order follows the **text** order: both expressions are inside the SELECT, the
            // filter's own values come after them in the WHERE.
            let bound = has.args + present.args + args
            let sql = """
                SELECT COUNT(*) AS n,
                       COUNT(CASE WHEN \(has.sql) THEN 1 END) AS h,
                       COUNT(CASE WHEN \(present.sql) THEN 1 END) AS w
                FROM assets a
                LEFT JOIN asset_metadata m ON m.asset_id = a.id
                WHERE \(where_)
                """
            let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(bound))
            let n: Int = row?["n"] ?? 0
            let h: Int = row?["h"] ?? 0
            let w: Int = row?["w"] ?? 0
            guard n > 0, w > 0 else { return [] }
            var out: [String] = []
            if h > 0 { out.append(FilterValue.yes) }
            if h < n { out.append(FilterValue.no) }
            return out
        }

        guard let expr = FilterSQL.facetExpression(dimension) else { return [] }
        // One copy of the expression, one copy of its paths: the SELECT list comes *before* the
        // WHERE in the text, so its bound paths must come before the filter's values.
        let sql = """
            SELECT DISTINCT v FROM (
                SELECT \(expr.sql) AS v
                FROM assets a
                LEFT JOIN asset_metadata m ON m.asset_id = a.id
                WHERE \(where_)
            ) WHERE v IS NOT NULL
            """
        let values = try String.fetchAll(db, sql: sql,
                                         arguments: StatementArguments(expr.args + args))
        if dimension == .shutter {
            // Group by what the bar *prints*: `55924/44739201` and `1/800` are one shutter.
            return values.compactMap { ShutterFormat.standard(from: $0) }
        }
        return values
    }

    /// Dedupe + the order the popup shows.
    ///
    /// 星级 descends (≥5★ first), 焦距/光圈/ISO/快门 ascend by number (a lens list is not an
    /// alphabet), 闪光灯/GPS put 有 before 无, and everything textual is localised dictionary order so
    /// 「20-60mm」 sorts before 「85mm」 for a Chinese locale.
    static func sortedFacetValues(_ raw: [String], for dimension: FilterDimension) -> [String] {
        let unique = Array(Set(raw))
        switch dimension {
        case .rating:
            return unique.sorted { (Int($0) ?? -1) > (Int($1) ?? -1) }
        case .flag, .color:
            let order = dimension.fixedValues ?? []
            func rank(_ v: String) -> Int { order.firstIndex(of: v) ?? order.count }
            return unique.sorted { rank($0) < rank($1) }
        case .focal, .iso:
            return unique.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
        case .aperture:
            return unique.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
        case .shutter:
            return unique.sorted {
                (ShutterFormat.seconds(from: $0) ?? .greatestFiniteMagnitude)
                    < (ShutterFormat.seconds(from: $1) ?? .greatestFiniteMagnitude)
            }
        case .flash, .gps:
            return unique.sorted { (Double($0) ?? 0) > (Double($1) ?? 0) }
        case .month, .day:
            return unique.sorted()          // "01"…"12" — zero-padded, so lexical == numeric
        case .ext, .camera, .lens, .serial:
            return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}
