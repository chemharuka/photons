import Foundation
import GRDB

public struct ImportOptions: Sendable {
    public var mode: ManagementMode
    /// Use an existing root instead of resolving one from the sources.
    public var rootID: String?
    /// e.g. `{YYYY}/{MM}/{name}{ext}`. `nil` keeps the original filename at the root.
    public var renameTemplate: String?
    /// Test hook: hard-stop after N files, exactly like a kill (docs/tasks/003-catalog.md §6).
    public var interruptAfter: Int?
    /// Extensions we never import (default: sidecars are ignored by policy, see §4.4).
    public var skipExtensions: Set<String>

    public init(mode: ManagementMode = .reference,
                rootID: String? = nil,
                renameTemplate: String? = nil,
                interruptAfter: Int? = nil,
                skipExtensions: Set<String> = ["xmp", "aae", "thm", "lrv"]) {
        self.mode = mode
        self.rootID = rootID
        self.renameTemplate = renameTemplate
        self.interruptAfter = interruptAfter
        self.skipExtensions = skipExtensions
    }
}

/// The import pipeline: walk → hash → dedupe → metadata → copy (optional) → one transaction per file.
///
/// Order matters: the file is materialised *before* the row is written. The other way round a crash
/// leaves a row pointing at nothing (an "offline" asset the user has to reason about); this way the
/// worst case is an orphan file that `library verify` reports and a re-import adopts.
public final class ImportService {
    private let catalog: Catalog
    private let fm = FileManager.default

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    // MARK: main

    public func run(sources: [URL],
                    options: ImportOptions,
                    progress: ((String) -> Void)? = nil) throws -> ImportSummary {
        let started = CFAbsoluteTimeGetCurrent()
        guard !sources.isEmpty else { throw CatalogError.importSourceMissing(URL(fileURLWithPath: ".")) }

        let root: SourceRoot
        if let id = options.rootID {
            guard let r = try catalog.root(id: id) else { throw CatalogError.noSuchSourceRoot(id) }
            root = r
        } else {
            root = try catalog.ensureRoot(for: sources[0], mode: options.mode)
        }

        // Any session left 'running' belongs to a process that died. Book-keep it, then start clean:
        // idempotency across runs comes from content_hash, not from resuming a stale session.
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE import_sessions SET state = 'failed', error_message = 'interrupted (process died)'
                WHERE state = 'running'
                """)
        }

        var session = ImportSession(id: UUID().uuidString, sourceRootId: root.id, mode: root.managementMode,
                                    state: .running, totalCount: 0, importedCount: 0, skippedCount: 0,
                                    failedCount: 0, startedAt: ISO8601.now(), finishedAt: nil, errorMessage: nil)
        try catalog.dbQueue.write { db in try session.insert(db) }

        var summary = ImportSummary()
        summary.sessionId = session.id
        let files = try enumerate(sources: sources, options: options, summary: &summary)

        var processed = 0
        for file in files {
            if let limit = options.interruptAfter, processed >= limit {
                // Deliberately no cleanup: this must look exactly like SIGKILL to the next process.
                fputs("interrupted by --test-interrupt-after after \(processed) files\n", stderr)
                exit(137)
            }
            processed += 1
            summary.total += 1
            do {
                let outcome = try importOne(file, root: root, options: options, sessionId: session.id)
                switch outcome {
                case .added: summary.added += 1
                case .duplicate: summary.duplicate += 1
                case .unchanged: summary.unchanged += 1
                case .moved: summary.moved += 1
                case .failed: summary.failed += 1
                case .ignored: break
                }
            } catch {
                summary.failed += 1
                try? record(file: file, outcome: .failed, reason: "\(error)", assetId: nil, sessionId: session.id)
                try? bumpFailure(sessionId: session.id)
            }
            if let progress, processed % 100 == 0 {
                progress("… \(processed)/\(files.count)")
            }
        }

        let finished = ISO8601.now()
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE import_sessions SET state = 'finished', finished_at = ?,
                  total_count = ?, imported_count = ?, skipped_count = ?, failed_count = ?
                WHERE id = ?
                """, arguments: [finished, summary.total, summary.added,
                                 summary.duplicate + summary.unchanged, summary.failed, session.id])
        }
        summary.seconds = CFAbsoluteTimeGetCurrent() - started
        return summary
    }

    // MARK: enumeration

    private func enumerate(sources: [URL], options: ImportOptions, summary: inout ImportSummary) throws -> [URL] {
        var out: [URL] = []
        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
                throw CatalogError.importSourceMissing(source)
            }
            if !isDir.boolValue {
                if accepts(source, options: options, summary: &summary) { out.append(source) }
                continue
            }
            guard let walker = fm.enumerator(at: source,
                                             includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if accepts(url, options: options, summary: &summary) { out.append(url) }
            }
        }
        return out.sorted { $0.path < $1.path }   // deterministic order → reproducible tests
    }

    private func accepts(_ url: URL, options: ImportOptions, summary: inout ImportSummary) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        if options.skipExtensions.contains(ext) {
            if ext == "xmp" { summary.ignoredSidecars += 1 }
            return false
        }
        return AssetKind.detect(ext) != nil
    }

    // MARK: one file

    private func importOne(_ url: URL, root: SourceRoot, options: ImportOptions,
                           sessionId: String) throws -> ImportOutcome {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        // 1. Cheap pre-screen: identical size+mtime+ends ⇒ nothing to do — but only when the row we
        // matched *is this very file*. A byte-identical copy elsewhere must fall through to the
        // full hash, otherwise it would be recorded as "unchanged" while no row points at it.
        let quick = try? FileHasher.quickHash(of: url, size: size, mtime: mtime)
        if let quick, let hit = try catalog.assetUnchangedCandidate(quickHash: quick, size: size, mtime: mtime),
           let hitURL = try? catalog.fileURL(for: hit),
           hitURL.standardizedFileURL.path == url.standardizedFileURL.path {
            try record(file: url, outcome: .unchanged, reason: "same path, size+mtime+quick_hash match",
                       assetId: hit.id, sessionId: sessionId)
            return .unchanged
        }

        // 2. Identity: full-file SHA-256.
        let hash = try FileHasher.sha256(of: url)
        if let existing = try catalog.asset(contentHash: hash) {
            // Same bytes. If the row's file is gone and the bytes turned up elsewhere, it moved —
            // keep the row (its rating, its develop_json, its history) and just re-point it.
            let newRelPath = root.managementMode == .reference
                ? relativePath(of: url, under: root.pathHint)
                : existing.relPath
            let oldURL = try? catalog.fileURL(for: existing)
            let oldExists = oldURL.map { fm.fileExists(atPath: $0.path) } ?? false
            // Heuristic (deliberately conservative): a *missing old file with the same filename*
            // is a move. Byte-identical copies elsewhere (same content, different name) stay
            // duplicates — otherwise a duplicate twin would hijack the row's location.
            if root.managementMode == .reference, !oldExists,
               url.lastPathComponent == existing.filename,
               newRelPath != existing.relPath || existing.sourceRootId != root.id {
                try catalog.relocate(existing, toRoot: root.id, relPath: newRelPath)
                try record(file: url, outcome: .moved, reason: "was at \(existing.relPath)",
                           assetId: existing.id, sessionId: sessionId)
                return .moved
            }
            try record(file: url, outcome: .duplicate, reason: "content_hash match", assetId: existing.id, sessionId: sessionId)
            return .duplicate
        }

        // 3. Metadata (embedded XMP only).
        let meta = try MetadataReader.read(url)

        // 4. Materialise the file (copy mode) before writing the row.
        let relPath: String
        if root.managementMode == .copy {
            relPath = try materialise(url, meta: meta, options: options)
        } else {
            relPath = relativePath(of: url, under: root.pathHint)
        }

        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: url.pathExtension.lowercased(),
                          kind: AssetKind.detect(url.pathExtension) ?? .jpeg,
                          size: size,
                          mtime: mtime,
                          contentHash: hash,
                          quickHash: quick,
                          width: meta.width,
                          height: meta.height,
                          captureTime: meta.captureTime,
                          captureLocalDate: meta.captureLocalDate,
                          captureTimeSource: meta.captureTimeSource,
                          rating: meta.rating ?? 0,
                          flag: nil,
                          colorLabel: meta.colorLabel,
                          cameraMake: meta.cameraMake,
                          cameraModel: meta.cameraModel,
                          cameraKey: meta.cameraKey,
                          lens: meta.lens)

        let metadata = AssetMetadata(assetId: asset.id,
                                     exifJson: meta.exifJSON,
                                     xmpBlob: meta.xmpBlob,
                                     iso: meta.iso,
                                     focalLength: meta.focalLength,
                                     aperture: meta.aperture,
                                     shutter: meta.shutter,
                                     orientation: meta.orientation)

        // 5. One transaction: asset + metadata + first history entry + keywords + ledger + counter.
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try metadata.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: asset.developJson,
                             label: "import", createdAt: ISO8601.now()).insert(db)
            for name in meta.keywords {
                let keywordID = try Self.keywordID(db, name: name)
                try db.execute(sql: "INSERT OR IGNORE INTO photo_keywords(asset_id, keyword_id) VALUES(?, ?)",
                               arguments: [asset.id, keywordID])
            }
            try ImportFile(sessionId: sessionId, sourcePath: url.path, assetId: asset.id,
                           outcome: .added, reason: nil, seenAt: ISO8601.now()).insert(db)
            try db.execute(sql: "UPDATE import_sessions SET imported_count = imported_count + 1 WHERE id = ?",
                           arguments: [sessionId])
        }
        return .added
    }

    private func record(file: URL, outcome: ImportOutcome, reason: String?, assetId: String?,
                        sessionId: String) throws {
        try catalog.dbQueue.write { db in
            try ImportFile(sessionId: sessionId, sourcePath: file.path, assetId: assetId,
                           outcome: outcome, reason: reason, seenAt: ISO8601.now()).insert(db)
            let column = outcome == .failed ? "failed_count" : "skipped_count"
            try db.execute(sql: "UPDATE import_sessions SET \(column) = \(column) + 1 WHERE id = ?",
                           arguments: [sessionId])
        }
    }

    private func bumpFailure(sessionId: String) throws {
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE import_sessions SET failed_count = failed_count + 1 WHERE id = ?",
                           arguments: [sessionId])
        }
    }

    private static func keywordID(_ db: Database, name: String) throws -> String {
        if let id = try String.fetchOne(db, sql: "SELECT id FROM keywords WHERE name = ?", arguments: [name]) {
            return id
        }
        let id = UUID().uuidString
        try db.execute(sql: "INSERT INTO keywords(id, name, parent_id) VALUES(?, ?, NULL)", arguments: [id, name])
        return id
    }

    // MARK: paths

    private func relativePath(of url: URL, under rootPath: String) -> String {
        let base = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
        return url.lastPathComponent
    }

    /// Copy into `originals/` (write to `.tmp`, then rename — never a half file under the real name)
    /// and return the path relative to `originals/`.
    private func materialise(_ url: URL, meta: PhotoMetadata, options: ImportOptions) throws -> String {
        let template = options.renameTemplate ?? "{orig}"
        let dest = try destinationPath(for: url, meta: meta, template: template)
        let destURL = catalog.layout.originalsURL.appendingPathComponent(dest)
        try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: destURL.path) {
            // Same bytes already there (a previous interrupted run): keep it.
            if (try? FileHasher.sha256(of: destURL)) == (try? FileHasher.sha256(of: url)) {
                return dest
            }
            let unique = Self.uniqueVariant(for: destURL)
            try copy(url, to: unique)
            return relativePath(of: unique, under: catalog.layout.originalsURL.path)
        }
        try copy(url, to: destURL)
        return dest
    }

    private func copy(_ source: URL, to destination: URL) throws {
        let tmp = destination.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: source, to: tmp)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            throw CatalogError.fileOperationFailed("\(source.lastPathComponent) → \(destination.path): \(error)")
        }
    }

    private static func uniqueVariant(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func destinationPath(for url: URL, meta: PhotoMetadata, template: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        let date = meta.captureLocalDate ?? ISO8601.now().prefix(10).description
        let parts = date.split(separator: "-")
        let year = parts.count > 0 ? String(parts[0]) : "unknown"
        let month = parts.count > 1 ? String(parts[1]) : "00"
        let day = parts.count > 2 ? String(parts[2]) : "00"

        var out = template
        for (token, value) in ["{YYYY}": year, "{MM}": month, "{DD}": day,
                               "{name}": stem, "{orig}": url.lastPathComponent,
                               "{ext}": ext.isEmpty ? "" : ".\(ext)"] {
            out = out.replacingOccurrences(of: token, with: value)
        }
        // A template without a file extension would drop it; be forgiving.
        if (out as NSString).pathExtension.isEmpty { out += ".\(ext)" }
        return out
    }
}
