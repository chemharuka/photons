import Foundation
import GRDB

/// 451 — what one startup sweep did.
public struct SweepReport: Sendable, Equatable {
    /// Hidden temp files that were removed. Only names matching `tempFilePattern` ever count.
    public var filesRemoved = 0
    /// Their size on disk, for the log line / report.
    public var bytes = 0
    /// `import_sessions` rows moved from `running` to `interrupted`.
    public var sessionsMarkedInterrupted = 0
    /// The DB half's failure, if any. The file half never throws (a file it cannot remove is left
    /// alone), so `nil` here means "nothing to report".
    public var error: String?

    public init() {}
}

/// 451 — 「降噪跑到一半杀掉 app，会留下某种状态的残留」.
///
/// A `SIGKILL`ed host cannot run `defer` blocks and cannot signal the child process that is writing
/// the temp file. The residue is therefore a **name**, not a record: a hidden
/// `.<denoise|hdrmerge>-<UUID>.dng` in the photo's folder, plus an `import_sessions` row still
/// saying `running`.
///
/// This sweep removes exactly those two things and nothing else. Matching is deliberately strict
/// (the whole filename has to be the anchored pattern) because "delete hidden files in the user's
/// photo folder" is one typo away from deleting something the user cares about — 宁漏不误删.
public enum InterruptedWorkSweep {
    /// The only names this sweep is allowed to touch. Anchored, 36-char UUID body, `.dng` only.
    public static let tempFilePattern = "^\\.(denoise|hdrmerge)-[0-9A-Fa-f-]{36}\\.dng$"

    private static let matcher = try! NSRegularExpression(pattern: tempFilePattern)

    /// True for `.denoise-<UUID>.dng` / `.hdrmerge-<UUID>.dng`, false for everything else —
    /// including `.hidden-notice.txt`, `.denoise-notauuid.dng` and a visible `photo.dng`.
    public static func isSweepableName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return matcher.firstMatch(in: name, range: range) != nil
    }

    /// The startup sweep: the library package itself plus one level of direct subdirectories
    /// (`depth 2`), and — when a catalog is handed in — the DB's orphan `running` sessions.
    ///
    /// Never throws: a directory that vanished mid-scan, or a file that cannot be deleted, is
    /// simply skipped. Opening a library must not fail because a cleanup did.
    @discardableResult
    public static func sweep(libraryRoot: URL, catalog: Catalog? = nil) -> SweepReport {
        var report = removeLeftovers(in: libraryRoot, recursive: true)
        if let catalog {
            do {
                report.sessionsMarkedInterrupted = try ImportService.markRunningSessionsInterrupted(in: catalog)
            } catch {
                report.error = "\(error)"
            }
        }
        return report
    }

    /// Per-operation cleanup, before a denoise/HDR run starts: the same strict matcher, but only in
    /// the directory the new temp file will be written to. `kinds` narrows it to the prefix the
    /// operation owns, so a concurrently running HDR merge cannot lose its own temp file to a
    /// denoise that happens to start in the same folder.
    @discardableResult
    public static func removeLeftovers(in directory: URL,
                                       kinds: Set<String> = ["denoise", "hdrmerge"],
                                       recursive: Bool = false) -> SweepReport {
        var report = SweepReport()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return report
        }
        var candidates = regularFiles(in: directory, fileManager: fm)
        if recursive {
            for sub in directSubdirectories(in: directory, fileManager: fm) {
                candidates.append(contentsOf: regularFiles(in: sub, fileManager: fm))
            }
        }
        for url in candidates {
            let name = url.lastPathComponent
            guard isSweepableName(name) else { continue }
            guard kinds.contains(where: { name.hasPrefix(".\($0)-") }) else { continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            report.filesRemoved += 1
            report.bytes += size
        }
        return report
    }

    // MARK: filesystem

    private static func regularFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
    }

    private static func directSubdirectories(in directory: URL, fileManager: FileManager) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Never follow a symlinked directory: the sweep is bounded to the two real levels.
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }
}
