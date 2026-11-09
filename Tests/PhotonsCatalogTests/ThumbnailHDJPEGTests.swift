import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsCatalog

/// 308 §3 — the **1920 px 8-bit Display P3 PQ JPEG** family: what it is, what its key is, and how it
/// survives on disk next to the 1920 HEIC of the same photo.
///
/// These are the assertions that do not need a display or a RAW: the spec's parameters, the key's
/// dependence on the edit, and the retention/removal rules of the **second** file family in the
/// `hd` namespace. The encoder itself is tested in `PhotonsUITests/ThumbnailPQJPEGTests`.
final class ThumbnailHDJPEGTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdjpeg-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    /// A structurally valid JPEG: SOI … EOI, which is the whole of `payloadLooksComplete` for a
    /// JPEG key (the encoder writes the file in one finalize).
    private func jpeg(_ n: Int = 0) -> Data {
        var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: n), count: 64)
        bytes[0] = 0xFF; bytes[1] = 0xD8
        bytes[bytes.count - 2] = 0xFF; bytes[bytes.count - 1] = 0xD9
        return Data(bytes)
    }

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

    private func files(in dir: URL, ext: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".\(ext)") }
            .sorted()
    }

    // MARK: spec

    func testSpecIs1920JPEGAtQ075InEightBitPQ() {
        let spec = ThumbSpec.hdJPEG
        XCTAssertEqual(spec.rawValue, "hd1920q75p3pq8")
        XCTAssertEqual(spec.longEdge, 1920, "the file stays at the render's edge; the decode shrinks")
        XCTAssertEqual(spec.fileExtension, "jpg")
        XCTAssertEqual(spec.quality, 0.75)
        XCTAssertEqual(spec.bitDepth, 8)
        XCTAssertTrue(spec.isHDR)
        XCTAssertEqual(spec.colorSpaceName, "displayP3_PQ")
        XCTAssertTrue(spec.isHDFamily)
        // Its own generation counter: the 1920 HEIC's v3 bump must not alias this family.
        XCTAssertEqual(spec.schemaVersion, 1)
        XCTAssertEqual(ThumbSpec.allCases.count, 3)
    }

    func testKeyCarriesTheEditAndLandsInTheSameContentShardAsTheHEIC() {
        let content = "ab" + String(repeating: "c", count: 62)
        let neutral = ThumbKey.hdJPEG(contentHash: content, document: .neutral)
        let base = ThumbKey.hd(contentHash: content, document: .neutral)
        let edited = ThumbKey.hdJPEG(contentHash: content, document: document(exposure: 1))

        XCTAssertNotEqual(neutral.digest, edited.digest, "an edit must move the 512/1920 JPEG key")
        XCTAssertNotEqual(neutral.digest, base.digest, "the two families must never alias")
        XCTAssertTrue(neutral.keyString.contains("hd1920q75p3pq8"))
        XCTAssertTrue(neutral.keyString.contains("sv1"))
        XCTAssertEqual(neutral.spec, .hdJPEG)
        XCTAssertEqual(neutral.tier, .t2048, "the file is a 1920 image; the tier says so")

        // Path: same content-hash shard, `jpg` extension, `hd` namespace — one directory per photo.
        let rootURL = FileManager.default.temporaryDirectory
        let url = neutral.relativePath(in: rootURL)
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "cc")
        XCTAssertEqual(url.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent, "ab")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent, ThumbNamespace.hd)
        XCTAssertEqual(neutral.namespace, ThumbNamespace.hd)
        // …and the HEIC of the same photo sits in that same directory.
        XCTAssertEqual(url.deletingLastPathComponent().path,
                       base.relativePath(in: rootURL).deletingLastPathComponent().path)
    }

    func testJPEGAndHEICCompletenessChecksArePerFamily() {
        let key = ThumbKey.hdJPEG(contentHash: hash("a"), document: .neutral)
        XCTAssertTrue(ThumbnailCache.payloadLooksComplete(jpeg(), for: key))
        XCTAssertFalse(ThumbnailCache.payloadLooksComplete(heic(), for: key),
                       "a HEIC is not a valid payload for the JPEG family")
        let hd = ThumbKey.hd(contentHash: hash("a"), document: .neutral)
        XCTAssertTrue(ThumbnailCache.payloadLooksComplete(heic(), for: hd))
        XCTAssertFalse(ThumbnailCache.payloadLooksComplete(jpeg(), for: hd))
    }

    // MARK: retention (§2.3, per family)

    func testEachFamilyKeepsItsOwnNewestFile() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("a")
        let keys = [0.0, 1.0, 2.0].map { ThumbKey.hdJPEG(contentHash: content, document: document(exposure: $0)) }
        for (i, key) in keys.enumerated() {
            try cache.store(jpeg(i), for: key)
        }
        let dir = cache.url(for: keys[0]).deletingLastPathComponent()
        XCTAssertEqual(files(in: dir, ext: "jpg").count, 1, "three edits, one JPEG")
        XCTAssertEqual(files(in: dir, ext: "jpg").first, "\(keys[2].digest).jpg",
                       "the newest edit wins")

        // The HEIC of the same photo is untouched by the JPEG prune, and vice versa.
        let hd = ThumbKey.hd(contentHash: content, document: .neutral)
        try cache.store(heic(7), for: hd)
        XCTAssertEqual(files(in: dir, ext: "jpg").count, 1)
        XCTAssertEqual(files(in: dir, ext: "heic").count, 1)
        for i in 1...2 {
            try cache.store(heic(i), for: ThumbKey.hd(contentHash: content,
                                                      document: document(exposure: Double(i))))
        }
        XCTAssertEqual(files(in: dir, ext: "heic").count, 1, "one HEIC per photo")
        XCTAssertEqual(files(in: dir, ext: "jpg").count, 1, "one JPEG per photo")
    }

    func testRemoveAllDropsBothFamilies() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("b")
        let jpgKey = ThumbKey.hdJPEG(contentHash: content, document: .neutral)
        let heicKey = ThumbKey.hd(contentHash: content, document: .neutral)
        try cache.store(jpeg(1), for: jpgKey)
        try cache.store(heic(2), for: heicKey)
        XCTAssertTrue(cache.exists(jpgKey))
        XCTAssertTrue(cache.exists(heicKey))

        let removed = cache.removeAll(contentHash: content)
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(cache.exists(jpgKey))
        XCTAssertFalse(cache.exists(heicKey))
    }
}
