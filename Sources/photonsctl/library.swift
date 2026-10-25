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

func cmdLibrary(_ a: Args) throws {
    guard let sub = a.positional.first else {
        die("library needs a subcommand: create | import | rescan | assets | stats | verify")
    }

    switch sub {
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
        if a.has("--json") {
            note(jsonLine(["total": summary.total, "added": summary.added, "moved": summary.moved,
                           "duplicate": summary.duplicate, "unchanged": summary.unchanged,
                           "failed": summary.failed]))
        } else {
            note("rescan     \(summary.text)")
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
        die("unknown library subcommand '\(sub)' (create|import|rescan|assets|stats|verify)")
    }
}
