import XCTest
import AppKit
import CoreImage
import CoreVideo
import Darwin
import ImageIO
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 218 — the one HD thumbnail cache three views share.
///
/// The numbers are asserted by reading the file back (container, bit depth, auxiliary map size,
/// headroom, extended-linear peak), never by trusting the options we passed in.
final class ThumbnailHDRCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hd-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fixtures

    private func rawURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            ?? NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return URL(fileURLWithPath: path)
    }

    private func asset(ext: String = "dng") -> Asset {
        Asset(id: "asset-1", sourceRootId: "root", relPath: "L1030433.dng",
              filename: "L1030433.dng", ext: ext, kind: .raw, size: 1, mtime: 0,
              contentHash: String(repeating: "a", count: 64), width: 9520, height: 6336)
    }

    private func cache() throws -> ThumbnailCache { try ThumbnailCache(root: root) }

    /// One request, waited for synchronously. The completion runs on the main actor; XCTest's test
    /// methods are already on it, so the run loop is what turns the expectation.
    private func request(_ provider: ThumbnailProvider, asset: Asset, url: URL,
                         document: EditModel) throws -> ThumbKey {
        let done = expectation(description: "thumbnail delivered")
        var delivered: ThumbKey?
        let token = provider.request(index: 0, asset: asset, fileURL: url, document: document,
                                     tier: .t256, spec: .hd) { _, key, image in
            XCTAssertNotNil(image, "the HD producer must decode its own file")
            delivered = key
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        XCTAssertFalse(token.isCancelled)
        return try XCTUnwrap(delivered)
    }

    private func equalEdit(exposure: Double) -> EditModel {
        var document = EditModel.neutral
        document.light.exposure = exposure
        return document
    }

    // MARK: - 1. key

    func testHDKeyNamesThePinnedSpecAndMovesWithTheDocument() {
        let base = ThumbKey.hd(contentHash: "abc", document: .neutral)
        let same = ThumbKey.hd(contentHash: "abc", document: .neutral)
        let edited = ThumbKey.hd(contentHash: "abc", document: equalEdit(exposure: 1))

        XCTAssertEqual(base, same)
        XCTAssertNotEqual(base.digest, edited.digest, "an edit must produce a new cache key")
        XCTAssertTrue(base.keyString.contains("hd1920q75gm23"))
        XCTAssertTrue(base.keyString.contains("sv1"))
        XCTAssertEqual(base.spec, .hd)
        XCTAssertEqual(base.spec.longEdge, 1920)
        XCTAssertEqual(base.spec.quality, 0.75)
        XCTAssertEqual(base.spec.gainMapHeadroom, 2.3)
        XCTAssertEqual(base.relativePath(in: root).pathExtension, "heic")
        // The legacy ladder is byte-for-byte unchanged.
        XCTAssertEqual(ThumbKey.preview(contentHash: "abc", tier: .t256).keyString,
                       "thumb|v1|abc|t256|preview|-")
    }

    /// 2 — three views, one file: the HD key ignores the per-cell tier, so a 256 px grid cell, a
    /// 34 pt list row and a filmstrip cell all resolve to the same path.
    func testTheThreeViewsResolveToOneCacheFilePath() throws {
        let a = asset()
        let provider = ThumbnailProvider(cache: try cache())
        let grid = ThumbnailProvider.hdKey(for: a, document: .neutral)
        let list = ThumbnailProvider.hdKey(for: a, document: .neutral)
        let strip = ThumbnailProvider.hdKey(for: a, document: .neutral)

        XCTAssertEqual(grid.digest, list.digest)
        XCTAssertEqual(grid.digest, strip.digest)
        let path = provider.cache.url(for: grid).path
        XCTAssertEqual(path, provider.cache.url(for: list).path)
        XCTAssertEqual(path, provider.cache.url(for: strip).path)
        XCTAssertTrue(path.hasSuffix(".heic"))
        XCTAssertTrue(path.contains("/hd/"))
        print("218 same file: \(path)")
    }

    // MARK: - 3. file parameters

    @available(macOS 15.0, *)
    func testGeneratedFileHasThePinnedParametersAndAHalfSizeGainMap() throws {
        let url = try rawURL()
        let provider = ThumbnailProvider(cache: try cache())
        // +1 EV keeps a real photo's highlights above display white, so the "HDR really is in the
        // file" assertion measures the shipped path rather than a synthetic ramp.
        let document = equalEdit(exposure: 1)
        let key = try request(provider, asset: asset(), url: url, document: document)
        let path = provider.cache.url(for: key)
        let data = try Data(contentsOf: path)

        XCTAssertTrue(ThumbnailCache.looksLikeHEIC(data), "container must be HEIF/HEIC")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        let base = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(base.width, base.height), 1920, "long edge ≤ 1920")
        XCTAssertEqual(base.bitsPerComponent, 8, "8-bit SDR base")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyDepth] as? NSNumber)?.intValue, 8)

        // Half-size colour gain map.
        let aux = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
            "no ISO gain map in the file")
        let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        let mapW = intValue(description["Width"])
        let mapH = intValue(description["Height"])
        XCTAssertEqual(mapW, base.width / 2, "gain map width = base / 2")
        XCTAssertEqual(mapH, base.height / 2, "gain map height = base / 2")

        // Headroom: the spec pins 2.3 **EV**. The file's `contentHeadroom` is the linear ratio
        // (2^2.3 ≈ 4.9246), and the private keys the writers emit are in stops, so read back
        // `log2(contentHeadroom)` and compare that to the EV number.
        let read = try XCTUnwrap(GainMapHEIC.readHeadroom(at: path))
        let stops = log2(read)
        XCTAssertEqual(stops, 2.3, accuracy: 0.12,
                       "declared +2.3 EV headroom (contentHeadroom \(read), \(stops) stops)")
        XCTAssertEqual(read, pow(2, 2.3), accuracy: 0.25,
                       "contentHeadroom is the linear ratio, not the EV value")
        XCTAssertEqual(ThumbSpec.hd.gainMapHeadroom, 2.3, "the spec value stays in EV")
        XCTAssertEqual(ThumbSpec.hd.gainMapHeadroomRatio, pow(2, 2.3), accuracy: 1e-9)

        // Acceptance 4: the file really carries extended-range light, not just a label.
        let peak = try linearPeak(at: path)
        XCTAssertGreaterThanOrEqual(peak, 1.05, "linear peak \(peak) must be ≥ 1.05 × SDR white")
        print("218 file: \(base.width)×\(base.height) depth \(base.bitsPerComponent) "
              + "map \(mapW)×\(mapH) contentHeadroom \(read) log2 \(stops) peak \(peak) bytes \(data.count)")
    }

    // MARK: - 4. edit → new key → new pixels; undo → old key → old file

    @available(macOS 15.0, *)
    func testAnEditRebuildsAndUndoHitsTheOldFile() throws {
        let url = try rawURL()
        let provider = ThumbnailProvider(cache: try cache())
        let a = asset()
        let neutral = try request(provider, asset: a, url: url, document: .neutral)
        let neutralPath = provider.cache.url(for: neutral)
        let neutralData = try Data(contentsOf: neutralPath)
        let neutralSHA = sha256(neutralData)

        let editedDocument = equalEdit(exposure: 1)
        let edited = try request(provider, asset: a, url: url, document: editedDocument)
        let editedPath = provider.cache.url(for: edited)
        let editedData = try Data(contentsOf: editedPath)
        let editedSHA = sha256(editedData)

        XCTAssertNotEqual(neutral.digest, edited.digest, "exposure +1 EV must move the key")
        XCTAssertNotEqual(neutralSHA, editedSHA, "and the pixels")
        XCTAssertTrue(FileManager.default.fileExists(atPath: neutralPath.path),
                      "the old file stays for undo (LRU decides when it goes)")
        let editedSource = try XCTUnwrap(CGImageSourceCreateWithURL(editedPath as CFURL, nil))
        let editedBase = try XCTUnwrap(CGImageSourceCreateImageAtIndex(editedSource, 0, nil))
        XCTAssertLessThanOrEqual(max(editedBase.width, editedBase.height), 1920)

        // Undo: the key is the old value again, so the cache serves it and nothing is regenerated.
        let runsBefore = provider.generationCounts[neutral.digest] ?? 0
        let memoryBefore = provider.stats.memoryHits
        let undone = try request(provider, asset: a, url: url, document: .neutral)
        XCTAssertEqual(undone, neutral, "undo returns to the old key")
        XCTAssertGreaterThan(provider.stats.memoryHits, memoryBefore,
                             "the old key is a hit (memory or disk), not a rebuild")
        XCTAssertEqual(provider.generationCounts[neutral.digest] ?? 0, runsBefore,
                       "a hit must not run the producer again")
        XCTAssertEqual(try Data(contentsOf: provider.cache.url(for: undone)), neutralData)
        print("218 edit: neutral \(neutralSHA.prefix(16)) → +1EV \(editedSHA.prefix(16))")
    }

    // MARK: - 5. hits and performance

    func testTwoHundredMemoryHitsDecodeNothing() throws {
        let url = try rawURL()
        let provider = ThumbnailProvider(cache: try cache())
        let a = asset()
        _ = try request(provider, asset: a, url: url, document: .neutral)
        provider.resetStats()

        let key = ThumbnailProvider.hdKey(for: a, document: .neutral)
        for i in 0..<200 {
            XCTAssertNotNil(provider.serveFromMemory(for: key))
            _ = i
        }
        let stats = provider.stats
        XCTAssertEqual(stats.memoryHits, 200)
        XCTAssertEqual(stats.decodes, 0, "200 cells served from the memory LRU must decode 0 images")
        XCTAssertEqual(stats.diskHits, 0)
    }

    @available(macOS 15.0, *)
    func testColdGenerationCost() throws {
        let url = try rawURL()
        let provider = ThumbnailProvider(cache: try cache())
        let footprintBefore = footprint()
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try request(provider, asset: asset(), url: url, document: equalEdit(exposure: 0.5))
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let peakMB = Double(footprint() &- footprintBefore) / (1024 * 1024)
        print(String(format: "218 cold generation: %.0f ms · footprint Δ%.0f MB (decode + 2 renders + HEIC)",
                     ms, peakMB))
        XCTAssertLessThan(ms, 30_000)
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    // MARK: - helpers

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func sha256(_ data: Data) -> String {
        // CryptoKit is not needed here: a file-level equality hash is enough for "pixels changed".
        data.withUnsafeBytes { raw -> String in
            var h: UInt64 = 0xcbf29ce484222325
            for byte in raw {
                h = (h ^ UInt64(byte)) &* 0x100000001b3
            }
            return String(h, radix: 16)
        }
    }

    /// Peak of the extended-linear picture ImageIO reconstructs from the base + gain map.
    @available(macOS 15.0, *)
    private func linearPeak(at url: URL) throws -> Double {
        guard let ci = CIImage(contentsOf: url, options: [.expandToHDR: true]) else {
            throw XCTSkip("Core Image cannot open the HDR thumbnail")
        }
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf])
        pixels.withUnsafeMutableBytes { buffer in
            context.render(ci, toBitmap: buffer.baseAddress!, rowBytes: w * 4 * MemoryLayout<Float>.size,
                           bounds: ci.extent, format: .RGBAf, colorSpace: space)
        }
        var peak: Float = 0
        for i in 0..<(w * h) {
            peak = max(peak, max(pixels[i * 4], max(pixels[i * 4 + 1], pixels[i * 4 + 2])))
        }
        return Double(peak)
    }
}
