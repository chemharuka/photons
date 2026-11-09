import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsCatalog

/// 308 §2 — the `hd` cache stops being "one 368 KB file per edit, reclaimed by a 2 GB LRU someday"
/// and becomes "one file per photo": the path is content-hash-sharded, the old tree is deleted at
/// startup, and a write prunes its own superseded edits.
///
/// Four executable claims, each the acceptance of one bullet in `docs/tasks/308-thumb-parallel-retention.md`:
///   ① the layout — `thumbs/hd/<ch[0..2]>/<ch[2..4]>/<digest>.heic`, `.hd` only;
///   ② retention — three edits of one asset leave **one** file, the newest, and `trim()` never grows
///      the directory;
///   ③ migration — a pre-308 digest-sharded `thd` tree is gone after the cache opens, replaced by the
///      stamp and the new layout, with the deletion counted;
///   ④ the same content hash, a *different* photo — retention must not touch it even when both share
///      a shard directory (that is what the ownership tag is for).
final class ThumbnailRetentionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    /// Structurally valid HEIF header (`ftyp` + `heic`), which is all the cache's completeness check
    /// looks at: the encoder writes the container in one finalize.
    private func heic(_ n: Int = 0) -> Data {
        var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: n), count: 96)
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0; bytes[3] = 24
        bytes.replaceSubrange(4...7, with: Array("ftyp".utf8))
        bytes.replaceSubrange(8...11, with: Array("heic".utf8))
        return Data(bytes)
    }

    private func document(exposure: Double) -> EditModel {
        var d = EditModel.neutral
        d.light.exposure = exposure
        return d
    }

    private func heicFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".heic") }
            .sorted()
    }

    private func setmtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: ① layout

    func testHDPathIsShardedByContentHashAndOnlyHDIsAffected() throws {
        let cache = try ThumbnailCache(root: root)
        let content = "ab" + String(repeating: "c", count: 62)
        let key = ThumbKey.hd(contentHash: content, document: .neutral)
        let url = cache.url(for: key)
        let parts = url.pathComponents.suffix(4).map { $0 }

        XCTAssertEqual(parts[0], ThumbNamespace.hd)
        XCTAssertEqual(parts[1], "ab", "shard 0 is contentHash[0..2], not digest[0..2]")
        XCTAssertEqual(parts[2], "cc", "shard 1 is contentHash[2..4]")
        XCTAssertEqual(parts[3], "\(key.digest).heic")
        XCTAssertNotEqual(parts[1], key.shard0, "the HD family must not shard on the key digest")
        XCTAssertTrue(url.path.hasPrefix(cache.root.path + "/hd/"))

        // A second key for the same photo lands in the same two directories — the point of the shard.
        let other = ThumbKey.hd(contentHash: content, document: document(exposure: 1))
        XCTAssertNotEqual(key.digest, other.digest)
        XCTAssertEqual(cache.url(for: other).deletingLastPathComponent().path,
                       url.deletingLastPathComponent().path)

        // `preview`/`graph` keep the digest shard.
        let preview = ThumbKey.preview(contentHash: content, tier: .t256)
        XCTAssertEqual(cache.url(for: preview).pathComponents.suffix(2).first, preview.shard1)
        XCTAssertEqual(cache.url(for: preview).pathComponents.suffix(3).first, preview.shard0)
        XCTAssertEqual(preview.relativePath(in: cache.root).pathComponents.suffix(4).first,
                       ThumbNamespace.preview)
    }

    // MARK: ② retention

    /// §2.3: three edits of one asset ⇒ the content-hash directory holds exactly one file, and it is
    /// the newest. The mtimes are set explicitly so the assertion is about "newest", not about "the
    /// last store to reach the rename".
    func testThreeEditsOfOneAssetLeaveExactlyTheNewestFile() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("a")
        let now = Date()
        let edits = [0.5, 1.0, 1.5]
        var keys: [ThumbKey] = []

        for (i, exposure) in edits.enumerated() {
            let key = ThumbKey.hd(contentHash: content, document: document(exposure: exposure))
            keys.append(key)
            try cache.store(heic(i), for: key)
            // Age the file that was just written so the *next* store's prune has to choose by mtime.
            try setmtime(cache.url(for: key), now.addingTimeInterval(-Double(3 - i) * 60))
            let dir = cache.url(for: key).deletingLastPathComponent()
            let present = heicFiles(in: dir)
            print("308 retention · after edit \(i + 1): \(present.count) file(s) in \(dir.lastPathComponent)")
            XCTAssertEqual(present.count, 1, "edit \(i + 1) must leave one HD file for this photo")
            XCTAssertEqual(present, ["\(keys.last!.digest).heic"], "the survivor is the newest edit")
        }

        // Global trim must never make it grow again, and the 2 GB budget is untouched by this rule.
        let before = cache.totalBytes()
        cache.policy = .init(budgetBytes: 2_000_000_000, protectWindow: 0)
        let report = cache.trim(now: now)
        XCTAssertEqual(report.totalBefore, before)
        XCTAssertLessThanOrEqual(report.totalAfter, report.totalBefore, "trim is monotone non-increasing")
        XCTAssertEqual(cache.inventory().count, 1)
        XCTAssertEqual(ThumbSpec.hd.schemaVersion, 3)
    }

    /// §2.3's attribution half: a shard directory is shared by many photos. Retention must only delete
    /// files whose ownership tag names *this* content hash — otherwise "keep the newest" in a
    /// 65 536-bucket shard would quietly delete other photos' thumbnails.
    func testRetentionDoesNotTouchAnotherPhotoThatSharesTheShard() throws {
        let cache = try ThumbnailCache(root: root)
        let shared = "ab" + String(repeating: "0", count: 62)
        // Force the collision: both content hashes must map to the same two directories.
        let colliding = "ab" + "00" + String(repeating: "9", count: 60)
        let otherKey = ThumbKey.hd(contentHash: colliding, document: .neutral)
        let myKey = ThumbKey.hd(contentHash: shared, document: .neutral)
        XCTAssertEqual(cache.url(for: otherKey).deletingLastPathComponent().path,
                       cache.url(for: myKey).deletingLastPathComponent().path,
                       "the fixture must actually share the shard directory")

        try cache.store(heic(1), for: otherKey)
        try cache.store(heic(2), for: myKey)
        try cache.store(heic(3), for: ThumbKey.hd(contentHash: shared, document: document(exposure: 2)))

        XCTAssertTrue(cache.exists(otherKey), "another photo's file is not a superseded edit of this one")
        XCTAssertEqual(heicFiles(in: cache.url(for: myKey).deletingLastPathComponent()).count, 2,
                       "one file for the other photo + one for this one")
    }

    // MARK: ③ migration

    /// A pre-308 `thumbs/hd/<digest[0..2]>/<digest[2..4]>/<digest>.heic` tree: opening the cache must
    /// delete it in one go and stamp the new layout, and the next start must find the stamp current.
    func testTheOldDigestShardedHDTreeIsDeletedOnOpenAndStamped() throws {
        // The root is stamped with the *current* arithmetic, so the namespace sweep leaves `hd` alone
        // and only the layout migration can explain the deletion.
        try Data(StageAlgorithmVersion.fingerprint.utf8).write(to: root.appendingPathComponent(".recipe-version"))

        let oldDir = root.appendingPathComponent("hd/ab/cd", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        for i in 0..<3 {
            try heic(i).write(to: oldDir.appendingPathComponent(String(repeating: "d", count: 60) + "\(i).heic"))
        }
        XCTAssertEqual(heicFiles(in: oldDir).count, 3)

        let cache = try ThumbnailCache(root: root)
        print("308 migration · \(cache.hdLayoutSweep.summary)")
        XCTAssertTrue(cache.hdLayoutSweep.didReset, "an unstamped hd tree is a pre-308 layout")
        XCTAssertEqual(cache.hdLayoutSweep.removedFiles, 3, "every file of the old tree is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path), "the old tree is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.hdLayoutMarkerURL.path),
                      "the new layout is stamped")
        XCTAssertEqual(cache.inventory().count, 0)

        // Fresh writes land in the new layout; nothing recreates the old one.
        let content = hash("e")
        let key = ThumbKey.hd(contentHash: content, document: .neutral)
        try cache.store(heic(9), for: key)
        XCTAssertTrue(cache.exists(key))
        XCTAssertEqual(heicFiles(in: cache.url(for: key).deletingLastPathComponent()), ["\(key.digest).heic"])
        XCTAssertTrue(cache.url(for: key).path.contains("/hd/\(key.contentShard0)/\(key.contentShard1)/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))

        // Second start: the stamp matches this build, so nothing is deleted or rebuilt.
        let again = try ThumbnailCache(root: root)
        XCTAssertFalse(again.hdLayoutSweep.didReset)
        XCTAssertEqual(again.hdLayoutSweep.removedFiles, 0)
        XCTAssertTrue(again.exists(key), "a stamped tree is left alone")

        // …and a stamp written by another kernel generation resets it: HD pixels are this build's
        // render graph, not the camera's preview, so they cannot outlive the arithmetic that made them.
        try Data("hd3|0000000000000000".utf8).write(to: again.hdLayoutMarkerURL)
        let upgraded = try ThumbnailCache(root: root)
        XCTAssertTrue(upgraded.hdLayoutSweep.didReset)
        XCTAssertEqual(upgraded.hdLayoutSweep.removedFiles, 1)
        XCTAssertFalse(upgraded.exists(key))
    }

    /// Deleting a library entry must not leave the photo's HD pixels behind — with a content-hash
    /// shard that is one directory scan, not a guess at which documents the undo stack left.
    func testRemoveAllDropsEveryHDEditOfThePhoto() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("f")
        for exposure in [0.0, 1.0, 2.0] {
            try cache.store(heic(Int(exposure)), for: ThumbKey.hd(contentHash: content,
                                                                document: document(exposure: exposure)))
        }
        XCTAssertEqual(cache.inventory().count, 1, "retention already left one")
        let removed = cache.removeAll(contentHash: content)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(cache.inventory().count, 0)
    }
}
