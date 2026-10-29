import XCTest
import PhotonsCore
@testable import PhotonsDepth

/// The cache is the half of 120a that must run everywhere: no `.mlmodelc`, no GPU, no RAW file.
final class DepthCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-depth-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testCacheKeyIncludesRevisionAndDecodeKey() {
        let decode = DecodeCacheKey(fileSHA256: String(repeating: "a", count: 64), decoderVersion: "9")
        let base = DepthCacheKey(decodeKey: decode)

        XCTAssertEqual(base.decodeDigest, decode.digest)
        XCTAssertEqual(base.modelRevision, DepthModel.revision)
        XCTAssertEqual(base.keyText, "\(decode.digest)|\(DepthModel.revision)")

        let otherRevision = DepthCacheKey(decodeDigest: decode.digest, modelRevision: "dav2s-f16@other")
        XCTAssertNotEqual(base, otherRevision, "a different weight revision must be a different map")
        XCTAssertNotEqual(base.digest, otherRevision.digest)

        let otherDecode = DepthCacheKey(decodeDigest: String(repeating: "b", count: 64))
        XCTAssertNotEqual(base, otherDecode, "a different decode must be a different map")
        XCTAssertNotEqual(base.digest, otherDecode.digest)

        // And a decode-input change reaches the depth key through the decode digest.
        let changed = DecodeCacheKey(fileSHA256: String(repeating: "a", count: 64), decoderVersion: "9",
                                     exposureEV: 1)
        XCTAssertNotEqual(DepthCacheKey(decodeKey: changed), base)
    }

    func testThumbnailCeilingSkipsTheCache() throws {
        let cache = try DepthCache(directory: directory)
        let key = DepthCacheKey(decodeDigest: String(repeating: "c", count: 64))

        let fullSize = DepthMap(width: DepthCache.thumbnailCeiling + 1, height: 8,
                                values: [Float16](repeating: 1, count: (DepthCache.thumbnailCeiling + 1) * 8))
        XCTAssertFalse(try cache.save(fullSize, key: key), "a map above 4096 on its long edge must not be persisted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.binURL(for: key).path))
        XCTAssertNil(try cache.load(key))
        XCTAssertEqual(cache.totalBytes(), 0)

        let thumbnail = DepthMap(width: 5, height: 3,
                                 values: (0..<15).map { Float16(Float($0) / 14) })
        XCTAssertTrue(try cache.save(thumbnail, key: key))
        let loaded = try XCTUnwrap(try cache.load(key))
        XCTAssertEqual(loaded.width, thumbnail.width)
        XCTAssertEqual(loaded.height, thumbnail.height)
        XCTAssertEqual(loaded.values.map { $0.bitPattern }, thumbnail.values.map { $0.bitPattern })

        XCTAssertNil(try cache.load(DepthCacheKey(decodeDigest: String(repeating: "d", count: 64))))
    }

    func testNormalisedPutsNearAtOne() {
        let map = DepthMap(width: 3, height: 1, values: [2, 4, 6])
        let normalised = map.normalised()
        XCTAssertEqual(normalised?.values ?? [], [Float16(0), Float16(0.5), Float16(1)])
        XCTAssertNil(DepthMap(width: 2, height: 1, values: [3, 3]).normalised(),
                     "a flat map has no range to stretch")
    }
}
