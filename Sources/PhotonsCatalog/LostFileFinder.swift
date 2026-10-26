import Foundation

/// 「查找丢失的文件」: given a folder the user picked, find the moved originals inside it.
///
/// The user's sentence is the spec — *"弹出 finder 框重新按文件名搜索文件夹"* — so the search is
/// **by file name, recursively**, and the content hash only breaks ties. That ordering matters:
///
///   · a name match is what the user can verify by eye ("DAV00471.RAF is here now");
///   · a hash match is what the library can verify by identity. `assets.content_hash` is unique
///     (v1), so two files with one name are never "both the photo" — one of them is a different
///     picture that happens to share the name.
///
/// Everything here is a pure function of (folder contents, targets): the recursive walk is separated
/// from the resolution, so the four cases the task pins — one match, several same-name candidates,
/// a different capitalisation, no match — are unit-testable without a window and without a library.
public enum LostFileFinder {

    /// One row looking for its file.
    public struct Target: Sendable, Equatable {
        public var assetID: String
        /// The name the row remembers (`assets.filename`).
        public var filename: String
        /// The identity to verify against (`assets.content_hash`).
        public var contentHash: String

        public init(assetID: String, filename: String, contentHash: String) {
            self.assetID = assetID
            self.filename = filename
            self.contentHash = contentHash
        }
    }

    /// A resolved pair. The caller still calls `Catalog.relink` — which re-checks the hash — so this
    /// is a *candidate*, not a decision.
    public struct Match: Sendable, Equatable {
        public var assetID: String
        public var url: URL
        public var filename: String

        public init(assetID: String, url: URL, filename: String) {
            self.assetID = assetID
            self.url = url
            self.filename = filename
        }
    }

    /// The result of one search. `rejected` is not `unmatched`: a rejected target had a same-named
    /// file whose bytes differed, which is worth telling the user ("the file on disk is not this
    /// photo") instead of "not found".
    public struct Outcome: Sendable, Equatable {
        public var matches: [Match] = []
        public var unmatched: [String] = []       // asset ids: no file with that name anywhere
        public var rejected: [String] = []        // asset ids: name matched, content did not
        public var scannedFiles = 0

        public init() {}

        public var matchedIDs: [String] { matches.map(\.assetID) }
        public var summary: String {
            "matched \(matches.count) · not found \(unmatched.count) · content differs \(rejected.count)"
        }
    }

    /// The recursion itself: every regular file under `folder`, keyed by **lowercased** last path
    /// component. Hidden files and directories are skipped (`.DS_Store`, `.thumbnails/`), and
    /// directories are never keyed, so a folder called `shot.jpg` cannot be relinked to.
    ///
    /// Symlinks are not followed: a folder symlinked back to its parent would make the walk
    /// unbounded, and the file a symlink points at answers to its own path anyway.
    public static func index(folder: URL, fileManager: FileManager = .default) -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        guard let walker = fileManager.enumerator(at: folder.standardizedFileURL,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return out
        }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            out[url.lastPathComponent.lowercased(), default: []].append(url)
        }
        // Deterministic order: two runs on the same folder resolve the same way, which is what makes
        // a bulk relink reproducible instead of "whichever the filesystem listed first".
        for key in out.keys { out[key]?.sort { $0.path < $1.path } }
        return out
    }

    /// Resolve targets against an index. Pure: no filesystem access beyond `hashing`, which is
    /// injectable so the rules can be tested with fabricated hashes.
    ///
    /// For each target: take the same-named candidates, keep the ones whose full SHA-256 equals the
    /// row's `content_hash`, and take the first (paths are sorted). One candidate with the right
    /// bytes is a match; one candidate with the wrong bytes is a rejection, not a match — a rename
    /// that also replaced the photo is not the photo.
    public static func resolve(index: [String: [URL]],
                               targets: [Target],
                               hashing: (URL) throws -> String = { try FileHasher.sha256(of: $0) })
        -> Outcome {
        var outcome = Outcome()
        outcome.scannedFiles = index.values.reduce(0) { $0 + $1.count }
        for target in targets {
            let candidates = index[target.filename.lowercased()] ?? []
            guard !candidates.isEmpty else {
                outcome.unmatched.append(target.assetID)
                continue
            }
            var hit: URL?
            for candidate in candidates {
                guard let hash = try? hashing(candidate) else { continue }
                if hash == target.contentHash { hit = candidate; break }
            }
            if let hit {
                outcome.matches.append(Match(assetID: target.assetID,
                                             url: hit,
                                             filename: hit.lastPathComponent))
            } else {
                outcome.rejected.append(target.assetID)
            }
        }
        return outcome
    }

    /// Walk `folder` and resolve in one step — what the menu action calls.
    public static func find(folder: URL,
                            targets: [Target],
                            fileManager: FileManager = .default,
                            hashing: (URL) throws -> String = { try FileHasher.sha256(of: $0) })
        -> Outcome {
        resolve(index: index(folder: folder, fileManager: fileManager), targets: targets, hashing: hashing)
    }
}
