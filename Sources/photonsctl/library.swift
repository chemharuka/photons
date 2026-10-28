import Foundation
import PhotonsCatalog

// MARK: - photonsctl library …   (M2 has no UI; this is the whole product surface for now)

func jsonLine(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

func openLibrary(_ a: Args, index: Int) -> Catalog {
    let pkg = a.positional[index]
    let url = URL(fileURLWithPath: (pkg as NSString).expandingTildeInPath)
    do { return try Catalog.open(at: url) } catch { die("\(error.localizedDescription)") }
}

/// `<名字或 id>` → 相册行。名字大小写不敏感、必须唯一命中；打错名字是错误而不是"什么都不做"，
/// 因为一个静默的空操作会让人以为照片进了相册。
func resolveAlbum(_ catalog: Catalog, _ key: String) throws -> AlbumSummary {
    if let byID = try catalog.album(id: key) { return byID }
    if let byName = try catalog.album(named: key) { return byName }
    die("no album '\(key)'")
}

func cmdLibrary(_ a: Args) throws {
    guard let sub = a.positional.first else {
        die("library needs a subcommand: create | import | rescan | assets | stats | verify | develop"
            + " | copy-settings | paste-settings | albums | album-create | album-rename | album-delete"
            + " | album-add | album-remove | album-assets")
    }

    switch sub {
    case "develop":
        try cmdLibraryDevelop(a)

    // M5: the settings clipboard. Both sides parse their own options (`preset.swift`) so `--asset`
    // does not have to be registered in `main.swift`'s `valueFlags`.
    case "copy-settings":
        try cmdLibraryCopySettings()

    case "paste-settings":
        try cmdLibraryPasteSettings()

    case "create":
        guard a.positional.count >= 2 else { die("library create <pkg>") }
        let url = URL(fileURLWithPath: (a.positional[1] as NSString).expandingTildeInPath)
        guard url.pathExtension == LibraryLayout.packageExtension else {
            die("library package must end in .\(LibraryLayout.packageExtension)")
        }
        let catalog = try Catalog.create(at: url)
        note("created    \(url.path)")
        note("schema     v\(catalog.schemaVersionApplied)")
        note("cache      \(catalog.layout.cacheDirectory.path)")

    case "import":
        guard a.positional.count >= 3 else {
            die("library import <pkg> <src…> [--mode copy|reference] [--root id] [--rename T] [--json]")
        }
        let catalog = openLibrary(a, index: 1)
        let sources = a.positional.dropFirst(2).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        var options = ImportOptions()
        if let m = a.value("--mode") {
            guard let mode = ManagementMode(rawValue: m) else { die("--mode must be copy or reference") }
            options.mode = mode
        }
        options.rootID = a.value("--root")
        options.renameTemplate = a.value("--rename")
        options.interruptAfter = a.value("--test-interrupt-after").flatMap(Int.init)

        let service = ImportService(catalog: catalog)
        let summary = try service.run(sources: sources, options: options) { line in
            if !a.has("--json") { note(line) }
        }
        if a.has("--json") {
            note(jsonLine([
                "session": summary.sessionId,
                "total": summary.total, "added": summary.added, "moved": summary.moved,
                "duplicate": summary.duplicate, "unchanged": summary.unchanged, "failed": summary.failed,
                "sidecars": summary.ignoredSidecars, "seconds": summary.seconds,
            ]))
        } else {
            note("session    \(summary.sessionId)")
            note("result     \(summary.text)")
            if summary.ignoredSidecars > 0 {
                note("sidecars   \(summary.ignoredSidecars) .xmp/AAE files ignored (policy: embedded XMP only)")
            }
        }
        if summary.failed > 0 { exit(2) }

    case "rescan":
        guard a.positional.count >= 2 else { die("library rescan <pkg> [--root id]") }
        let catalog = openLibrary(a, index: 1)
        let roots = try catalog.refreshRootStatus()
        if !a.has("--json") {
            for r in roots { note("root       \(r.displayName)  \(r.status.rawValue)  \(r.pathHint)") }
        }
        // Re-walk each online root, importing anything new (dedupe makes this idempotent).
        let service = ImportService(catalog: catalog)
        var summary = ImportSummary()
        for root in roots where root.status == .online {
            let url = URL(fileURLWithPath: root.pathHint, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var opts = ImportOptions(mode: root.managementMode)
            opts.rootID = root.id
            let s = try service.run(sources: [url], options: opts)
            summary.total += s.total; summary.added += s.added
            summary.duplicate += s.duplicate; summary.unchanged += s.unchanged
            summary.moved += s.moved
            summary.failed += s.failed
        }
        // The import walk says "what is new"; it says nothing about rows whose file the Finder took
        // away. Re-derive `assets.missing` here too, so a rescan is a full answer to "what changed
        // on disk?" and not half of one.
        let availability = try catalog.refreshAvailability()
        if a.has("--json") {
            // **One object, not two.** This used to `note()` the import summary and then a second
            // `{"availability": …}` line, which broke every consumer that parses the output as a
            // single JSON document (`M2 acceptance §4` died with `Extra data: line 2 column 1`).
            // The availability block is a nested key, so an old reader that only looks at the top
            // level keeps working unchanged.
            note(jsonLine(["total": summary.total, "added": summary.added, "moved": summary.moved,
                           "duplicate": summary.duplicate, "unchanged": summary.unchanged,
                           "failed": summary.failed,
                           "availability": ["checked": availability.checked,
                                            "missing": availability.missing,
                                            "relinked": availability.relinked,
                                            "offlineRoots": availability.offlineRoots]]))
        } else {
            note("rescan     \(summary.text)")
            note("available  \(availability.summary)")
        }

    case "assets":
        guard a.positional.count >= 2 else { die("library assets <pkg> [filters]") }
        let catalog = openLibrary(a, index: 1)
        var filter = AssetFilter()
        filter.ratingAtLeast = a.value("--rating").flatMap(Int.init)
        filter.cameraKey = a.value("--camera")
        filter.sinceLocalDate = a.value("--since")
        filter.limit = a.value("--limit").flatMap(Int.init) ?? 200
        filter.includeDeleted = a.has("--deleted")
        // `--album <名字或 id>`（078 B10）：把「点相册 → 网格只显示成员」这条验收也做成命令行，
        // 这样它可以在真实库上跑，而不是只在单测里成立。
        if let wanted = a.value("--album") {
            let album = try resolveAlbum(catalog, wanted)
            filter.albumIds = [album.id]
        }

        let started = CFAbsoluteTimeGetCurrent()
        let assets = try catalog.assets(filter)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        if a.has("--json") {
            note(jsonLine(assets.map { [
                "id": $0.id, "relPath": $0.relPath, "rating": $0.rating,
                "cameraKey": $0.cameraKey ?? "", "capture": $0.captureTime ?? "",
                "localDate": $0.captureLocalDate ?? "", "kind": $0.kind.rawValue,
            ] }))
        } else {
            for asset in assets {
                let stars = String(repeating: "*", count: max(0, asset.rating))
                note("\(asset.captureLocalDate ?? "----------")  \(stars.padding(toLength: 5, withPad: " ", startingAt: 0))  \(asset.relPath)")
            }
            note(String(format: "… %d rows in %.1f ms", assets.count, elapsed))
        }

    // MARK: 相册（078 B10）

    // 动词与表一一对应：建 / 改名 / 删 / 加入 / 移出 / 列出成员。每个动词一次事务，
    // 输出逐行可比（`--json` 给脚本）。**删相册不删照片**在这一层也看得见 ——
    // `album-delete` 打印操作后的 `photos` 总数，验收脚本比的就是它。

    case "albums":
        guard a.positional.count >= 2 else { die("library albums <pkg> [--json]") }
        let catalog = openLibrary(a, index: 1)
        let albums = try catalog.albums()
        if a.has("--json") {
            note(jsonLine(albums.map { ["id": $0.id, "name": $0.name, "count": $0.count, "sort": $0.sort] }))
        } else {
            for album in albums { note("album      \(album.count)\t\(album.name)\t\(album.id)") }
            note("albums     \(albums.count)  memberships \(albums.reduce(0) { $0 + $1.count })")
        }

    case "album-create":
        guard a.positional.count >= 3 else { die("library album-create <pkg> <name> [--json]") }
        let catalog = openLibrary(a, index: 1)
        let album = try catalog.createAlbum(named: a.positional[2])
        if a.has("--json") {
            note(jsonLine(["id": album.id, "name": album.name, "count": 0]))
        } else {
            note("created    \(album.name)  \(album.id)")
        }

    case "album-rename":
        guard a.positional.count >= 4 else { die("library album-rename <pkg> <album> <new name>") }
        let catalog = openLibrary(a, index: 1)
        let album = try resolveAlbum(catalog, a.positional[2])
        let renamed = try catalog.renameAlbum(id: album.id, to: a.positional[3])
        note("renamed    \(album.name) → \(renamed.name)  \(renamed.id)")

    case "album-delete":
        guard a.positional.count >= 3 else { die("library album-delete <pkg> <album>") }
        let catalog = openLibrary(a, index: 1)
        let album = try resolveAlbum(catalog, a.positional[2])
        let report = try catalog.deleteAlbum(id: album.id)
        let photos = try catalog.stats().total
        note("deleted    albums \(report.albums)  entries \(report.entries)  photos \(photos)")

    case "album-add", "album-remove":
        guard a.positional.count >= 4 else {
            die("library \(sub) <pkg> <album> <assetId…>")
        }
        let catalog = openLibrary(a, index: 1)
        let album = try resolveAlbum(catalog, a.positional[2])
        let ids = Array(a.positional.dropFirst(3))
        let changed = sub == "album-add"
            ? try catalog.addAssets(ids, toAlbum: album.id)
            : try catalog.removeAssets(ids, fromAlbum: album.id)
        let count = try catalog.albumAssetCount(album.id)
        note("\(sub == "album-add" ? "added     " : "removed   ") \(changed)  album \(album.name) now \(count)")
        if a.has("--json") { note(jsonLine(["album": album.id, "changed": changed, "count": count])) }

    case "album-assets":
        guard a.positional.count >= 3 else { die("library album-assets <pkg> <album> [--json]") }
        let catalog = openLibrary(a, index: 1)
        let album = try resolveAlbum(catalog, a.positional[2])
        let ids = try catalog.albumAssetIDs(album.id)
        if a.has("--json") {
            note(jsonLine(ids))
        } else {
            for id in ids { note("member     \(id)") }
            note("album      \(album.name)  \(ids.count) photos")
        }

    case "stats":
        guard a.positional.count >= 2 else { die("library stats <pkg>") }
        let catalog = openLibrary(a, index: 1)
        let stats = try catalog.stats()
        let integrity = try catalog.integrityCheck()
        if a.has("--json") {
            note(jsonLine([
                "assets": stats.total, "deleted": stats.deleted, "rated": stats.rated,
                "bytes": stats.bytes, "sessions": stats.sessions, "keywords": stats.keywords,
                "byKind": stats.byKind, "integrity": integrity,
                "roots": stats.byRoot.map { ["name": $0.root, "status": $0.status, "count": $0.count] },
                "schemaVersion": catalog.schemaVersionApplied,
            ]))
        } else {
            note("library    \(catalog.layout.packageURL.path)")
            note("schema     v\(catalog.schemaVersionApplied)  integrity \(integrity)")
            note("assets     \(stats.total)  deleted \(stats.deleted)  rated \(stats.rated)"
                 + String(format: "  %.1f MB", Double(stats.bytes) / 1e6))
            note("kinds      " + stats.byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  "))
            for r in stats.byRoot { note("root       \(r.root)  \(r.status)  \(r.count)") }
            note("sessions   \(stats.sessions)   keywords \(stats.keywords)")
        }

    case "verify":
        guard a.positional.count >= 2 else { die("library verify <pkg> [--rehash]") }
        let catalog = openLibrary(a, index: 1)
        let report = try catalog.verify(rehash: a.has("--rehash"))
        if a.has("--json") {
            note(jsonLine([
                "integrity": report.integrity, "assets": report.assets,
                "missing": report.missingFiles, "orphans": report.unreferencedFiles,
                "badLedger": report.importFilesWithoutAsset, "hashMismatches": report.hashMismatches,
                "clean": report.isClean, "problems": report.problems,
            ]))
        } else {
            note("integrity  \(report.integrity)")
            note("assets     \(report.assets)")
            note("missing    \(report.missingFiles)")
            note("orphans    \(report.unreferencedFiles)")
            note("ledger     \(report.importFilesWithoutAsset) broken import_files rows")
            note("hashes     \(report.hashMismatches) mismatches\(a.has("--rehash") ? " (rehashed)" : " (not rehashed)")")
            for p in report.problems { note("  · " + p) }
            note(report.isClean ? "CLEAN" : "PROBLEMS")
        }
        exit(report.isClean ? 0 : 1)

    default:
        die("unknown library subcommand '\(sub)' (create|import|rescan|assets|stats|verify|develop"
            + "|copy-settings|paste-settings|albums|album-create|album-rename|album-delete"
            + "|album-add|album-remove|album-assets)")
    }
}
