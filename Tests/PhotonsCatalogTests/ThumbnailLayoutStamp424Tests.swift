import XCTest
import PhotonsCore
@testable import PhotonsCatalog

/// 424 — **the `hd` stamp stops being a delete trigger; invalidation belongs to the key.**
///
/// The user's report: 「为什么现在重新编译后还是需要加载资源库的缩略图？」 — a bump of *any* of the
/// twenty stages used to rewrite `thumbs/hd/.layout-v3` (308 put the whole unconditional
/// `StageAlgorithmVersion.fingerprint` in it) and delete every HD file. 405 already made
/// `ThumbRecipe.editFingerprint` version exactly the stages a document runs, so the tree deletion is
/// redundant: a bumped file is unreachable by key and naturally misses.
///
/// The claims, in the order the spec numbers them:
///   ① A①/A② — an arithmetic-generation change (layout still `hd3`) deletes **nothing** and refreshes
///      the stamp in place;
///   ② A③/A④ — a *layout* change (and a missing stamp) still deletes the whole tree (308 intact);
///   ③ C①′ — the new `HDLayoutSweep.stampRefreshed` names that half;
///   ④ C②′ — `sweepUnreachable(knownKeys:)` is the collector the files now need, and it is not `trim`;
///   ⑤ D①′–D③′ — at the **key digest** level: a bump of a stage a document does not run leaves its
///      digest alone, a bump of one it runs moves it, and the old file is what the collector reclaims.
final class ThumbnailLayoutStamp424Tests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-stamp424-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    /// Structurally complete JPEG: SOI … EOI, which is the whole of `looksComplete`.
    private func jpeg(_ n: Int = 0) -> Data {
        var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: n), count: 64)
        bytes[0] = 0xFF; bytes[1] = 0xD8
        bytes[bytes.count - 2] = 0xFF; bytes[bytes.count - 1] = 0xD9
        return Data(bytes)
    }

    /// A `hd/…/xxx.jpg` that no key of this build names: what a superseded generation leaves behind.
    @discardableResult
    private func writeOrphan(_ n: Int, inDir dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(repeating: String(Character(UnicodeScalar(97 + n)!)), count: 64) + ".jpg")
        try jpeg(n).write(to: url)
        return url
    }

    private var hdRoot: URL { root.appendingPathComponent("hd", isDirectory: true) }
    private var markerURL: URL { hdRoot.appendingPathComponent(".layout-v3") }
    private var currentStamp: String { "hd3|\(StageAlgorithmVersion.fingerprint)" }

    private func writeStamp(_ s: String) throws {
        try FileManager.default.createDirectory(at: hdRoot, withIntermediateDirectories: true)
        try Data(s.utf8).write(to: markerURL)
    }

    private func stampOnDisk() throws -> String {
        try String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jpgFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
    }

    // MARK: - ① an arithmetic-generation change deletes nothing

    /// A① — the user's bug, as an assertion: three files on disk, a stamp naming another generation of
    /// the *same* layout, open the cache. Nothing may be deleted, and the files must be byte- and
    /// mtime-identical (a refresh that rewrote them would be the same bug with a smaller radius).
    func testAGenerationChangeDeletesNoFile() throws {
        // Keep the namespace sweep out of it: the root is stamped with this build's arithmetic.
        try Data(StageAlgorithmVersion.fingerprint.utf8)
            .write(to: root.appendingPathComponent(".recipe-version"))
        let shard = hdRoot.appendingPathComponent("ab/cd", isDirectory: true)
        let written = try (0..<3).map { try writeOrphan($0, inDir: shard) }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        for url in written {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        try writeStamp("hd3|0000000000000000")

        let cache = try ThumbnailCache(root: root)
        print("424 A① · \(cache.hdLayoutSweep.summary)")
        XCTAssertFalse(cache.hdLayoutSweep.didReset, "the layout did not move: no tree reset")
        XCTAssertEqual(cache.hdLayoutSweep.removedFiles, 0, "not one file may be deleted")
        XCTAssertEqual(jpgFiles(in: shard).count, 3, "all three are still there")
        XCTAssertEqual(cache.inventory().count, 3)
        for url in written {
            XCTAssertEqual(try Data(contentsOf: url), jpeg(written.firstIndex(of: url)!),
                           "the bytes are untouched")
            let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            XCTAssertEqual(mtime, oldDate, "the mtime is untouched too")
        }
    }

    /// A② — the same open refreshes the stamp to this build's generation, so the log/support report can
    /// still say which arithmetic wrote what is in the tree.
    func testAGenerationChangeRefreshesTheStampInPlace() throws {
        try writeStamp("hd3|0000000000000000")
        let cache = try ThumbnailCache(root: root)
        XCTAssertTrue(cache.hdLayoutSweep.stampRefreshed, "C①′ — the new bit names this half")
        XCTAssertFalse(cache.hdLayoutSweep.didReset)
        XCTAssertEqual(try stampOnDisk(), currentStamp)
        // A second open finds it current and says so.
        let again = try ThumbnailCache(root: root)
        XCTAssertFalse(again.hdLayoutSweep.stampRefreshed)
        XCTAssertFalse(again.hdLayoutSweep.didReset)
        XCTAssertEqual(again.hdLayoutSweep.summary, "hd layout v3: up to date")
    }

    // MARK: - ② a layout change still resets the tree (308 must not regress)

    /// A③ — `hd2` is another *layout*: its files carry no content hash in their path, so no key can
    /// name them. The whole tree goes, and the count is reported.
    func testALayoutChangeStillDeletesTheWholeTree() throws {
        let shard = hdRoot.appendingPathComponent("ab/cd", isDirectory: true)
        try (0..<3).forEach { try writeOrphan($0, inDir: shard) }
        try writeStamp("hd2|\(StageAlgorithmVersion.fingerprint)")

        let cache = try ThumbnailCache(root: root)
        print("424 A③ · \(cache.hdLayoutSweep.summary)")
        XCTAssertTrue(cache.hdLayoutSweep.didReset, "a different layout is a wholesale reset")
        XCTAssertFalse(cache.hdLayoutSweep.stampRefreshed)
        XCTAssertEqual(cache.hdLayoutSweep.removedFiles, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shard.path), "the old tree is gone")
        XCTAssertEqual(try stampOnDisk(), currentStamp)
    }

    /// A④ — a missing/unreadable stamp has no layout segment at all: it is the pre-308 tree and keeps
    /// the delete branch (a stamp we cannot read cannot promise the content-hash layout).
    func testAMissingStampStillDeletesTheWholeTree() throws {
        let shard = hdRoot.appendingPathComponent("ab/cd", isDirectory: true)
        try (0..<3).forEach { try writeOrphan($0, inDir: shard) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        let cache = try ThumbnailCache(root: root)
        XCTAssertTrue(cache.hdLayoutSweep.didReset)
        XCTAssertEqual(cache.hdLayoutSweep.removedFiles, 3)
        XCTAssertEqual(cache.inventory().count, 0)
    }

    // MARK: - ③ C②′ the collector for what the refresh deliberately leaves behind

    /// The reason 424 needs a new door at all: `trim(knownKeys:)` returns before it looks at anything
    /// while the directory is under budget, and treats `knownKeys` as "digests I can explain", skipping
    /// the rest. Reclaiming orphaned generations therefore cannot be `trim` — it is this.
    func testTheCollectorRemovesExactlyTheUnreachableFilesAndNothingElse() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("a")
        let reachable = ThumbKey.hdJPEG(contentHash: content, document: .neutral)
        try cache.store(jpeg(0), for: reachable)
        let shard = cache.url(for: reachable).deletingLastPathComponent()
        // Two files no key of this build names, in the same real shard directory.
        let orphans = [try writeOrphan(1, inDir: shard), try writeOrphan(2, inDir: shard)]
        XCTAssertEqual(cache.inventory().count, 3)

        // `trim` is not the collector: under budget it returns immediately and deletes nothing.
        let report = cache.trim(knownKeys: [reachable])
        XCTAssertEqual(report.evicted, 0, "trim's budget guard is why C② of the first draft was void")
        XCTAssertEqual(cache.inventory().count, 3)

        XCTAssertEqual(cache.sweepUnreachable(knownKeys: [reachable]), 2, "exactly the two orphans")
        XCTAssertEqual(cache.inventory().count, 1, "the reachable file survives")
        XCTAssertTrue(cache.exists(reachable))
        for url in orphans {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }

        // Idempotent: a second pass has nothing left to do.
        XCTAssertEqual(cache.sweepUnreachable(knownKeys: [reachable]), 0)
        // …and an empty whitelist is not a licence to wipe the tree: the reachable key is still named.
        XCTAssertEqual(cache.sweepUnreachable(knownKeys: []), 1)
        XCTAssertEqual(cache.inventory().count, 0)
    }

    // MARK: - ④ D①′–D③′ the same claims at the key-digest level

    private var dehazed: EditModel {
        var e = EditModel.neutral
        e.effects.dehaze = 50
        return e
    }

    private func bumpedDehaze(_ s: RenderStage) -> Int {
        s == .dehaze ? StageAlgorithmVersion.dehaze + 1 : StageAlgorithmVersion.version(of: s)
    }

    /// The key `hdJPEG` would produce if `versions` were the live table — same spelling as
    /// `ThumbKey.hdJPEG`, with 405's injection point exposed. The digest is `sha256(keyString)`, so
    /// comparing digests compares exactly what is on disk.
    private func hdKey(_ document: EditModel, content: Character = "a",
                       versions: (RenderStage) -> Int
        = StageAlgorithmVersion.version(of:)) -> ThumbKey {
        ThumbKey(contentHash: hash(content), tier: .t2048, pipeline: .graph,
                 recipeDigest: ThumbRecipe.placeholderDigest, spec: .hdJPEG,
                 editFingerprint: ThumbRecipe.editFingerprint(document, spec: .hdJPEG, versions: versions))
    }

    /// D①′ — a dehaze bump moves the digest of a document that **runs** dehaze and leaves every other
    /// document's digest byte-identical. This is the fact the whole change rests on: the stamp no
    /// longer has to delete, because the key already says which files are stale.
    func testABumpOfADehazeOnlyMovesTheDigestOfADocumentThatRunsIt() {
        let neutralBefore = hdKey(.neutral)
        let neutralAfter = hdKey(.neutral, versions: bumpedDehaze)
        XCTAssertEqual(neutralBefore.digest, neutralAfter.digest,
                       "a neutral document does not run S1.9: its file stays reachable")
        XCTAssertEqual(neutralBefore.keyString, ThumbKey.hdJPEG(contentHash: hash("a"), document: .neutral).keyString,
                       "the fixture spells the same key the production door does")

        let dehazedBefore = hdKey(dehazed)
        let dehazedAfter = hdKey(dehazed, versions: bumpedDehaze)
        XCTAssertNotEqual(dehazedBefore.digest, dehazedAfter.digest,
                          "a dehazed document does run S1.9: its old file must miss")
    }

    /// D②′ — after a generation-only reopen, a file on disk is still hit by this build's own key. The
    /// refresh is not a rename and not a re-hash: the key is the identity, the stamp is a note.
    func testAFileSurvivesAGenerationChangeAndIsStillHitByItsKey() throws {
        let cache = try ThumbnailCache(root: root)
        let key = ThumbKey.hdJPEG(contentHash: hash("b"), document: .neutral)
        try cache.store(jpeg(7), for: key)
        let path = cache.url(for: key).path
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        try writeStamp("hd3|0000000000000000")
        let reopened = try ThumbnailCache(root: root)
        XCTAssertEqual(reopened.hdLayoutSweep.removedFiles, 0)
        XCTAssertTrue(reopened.exists(key), "the key still names the file")
        XCTAssertEqual(reopened.data(for: key), before, "and the bytes are the ones that were there")
        XCTAssertEqual(reopened.sweepUnreachable(knownKeys: [key]), 0,
                       "so the collector has nothing to reclaim: the file is not an orphan")
    }

    /// D③′ — the close-out claim, run under **both** inputs: a moved generation keeps the files, a
    /// moved layout deletes them. Same fixture, one character apart in the stamp.
    func testOnlyTheLayoutSegmentCanTriggerDeletion() throws {
        let shard = hdRoot.appendingPathComponent("ab/cd", isDirectory: true)
        try (0..<3).forEach { try writeOrphan($0, inDir: shard) }

        try writeStamp("hd3|0000000000000000")
        let generationOnly = try ThumbnailCache(root: root)
        XCTAssertEqual(generationOnly.hdLayoutSweep.removedFiles, 0)
        XCTAssertEqual(generationOnly.inventory().count, 3, "D③′ · generation-only: 3 files, 0 removed")

        try writeStamp("hd2|0000000000000000")
        let layoutMoved = try ThumbnailCache(root: root)
        XCTAssertEqual(layoutMoved.hdLayoutSweep.removedFiles, 3)
        XCTAssertEqual(layoutMoved.inventory().count, 0, "D③′ · layout: 3 files, 3 removed")
    }

    /// The two halves of D③′ in one more direction: with a dehaze bump simulated, the neutral file is
    /// still reachable and the dehazed file becomes the collector's business — "only the documents that
    /// run the bumped stage rebuild", on a real disk.
    func testOnlyTheFileOfADocumentThatRunsTheBumpedStageIsReclaimed() throws {
        let cache = try ThumbnailCache(root: root)
        let neutral = hdKey(.neutral, content: "a")
        let oldDehazed = hdKey(dehazed, content: "b")
        try cache.store(jpeg(1), for: neutral)
        try cache.store(jpeg(2), for: oldDehazed)
        XCTAssertEqual(cache.inventory().count, 2)

        // What a library open would pass after the bump: the keys of the documents it still holds.
        let afterBump = [hdKey(.neutral, content: "a", versions: bumpedDehaze),
                         hdKey(dehazed, content: "b", versions: bumpedDehaze)]
        XCTAssertEqual(cache.sweepUnreachable(knownKeys: afterBump), 1,
                       "only the dehazed document's old file is unreachable")
        XCTAssertTrue(cache.exists(neutral), "the neutral photo's thumbnail is kept")
        XCTAssertFalse(cache.exists(oldDehazed), "the dehazed photo's old thumbnail is reclaimed")
    }
}
