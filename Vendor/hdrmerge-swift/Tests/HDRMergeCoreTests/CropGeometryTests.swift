import Foundation
import XCTest
@testable import HDRMergeCore

/// Geometry: a DNG's stored array (and even its ActiveArea) can be larger than the picture.
/// Leica SL3 writes 9536×6344 of sensor, ActiveArea over all of it, and
/// DefaultCropOrigin/Size = 4,4 / 9520×6336. The surplus columns carry sensor dummy data —
/// samples that alternate between 0 and the white level — and merging them in put a
/// black/white band down the right edge of every merged file (#band).
///
/// These tests build that geometry synthetically, so they run everywhere; the real-file test at
/// the bottom pins the actual camera layout when the sample is on disk.
final class CropGeometryTests: XCTestCase {

    /// A CFA frame with sensor margins around a photo rectangle.
    /// `dummy(x)` fills the pixels outside the crop, modelling the sensor's junk columns.
    private func makeFrame(fullWidth: Int, fullHeight: Int,
                           cropX: Int, cropY: Int, cropW: Int, cropH: Int,
                           activeTop: Int = 0, activeLeft: Int = 0,
                           activeW: Int? = nil, activeH: Int? = nil,
                           photo: (Int, Int) -> UInt16,
                           dummy: (Int, Int) -> UInt16) -> RawFrame {
        var px = [UInt16](repeating: 0, count: fullWidth * fullHeight)
        for y in 0..<fullHeight {
            for x in 0..<fullWidth {
                let inActive = x >= activeLeft && x < activeLeft + (activeW ?? fullWidth)
                    && y >= activeTop && y < activeTop + (activeH ?? fullHeight)
                let inPhoto = x >= activeLeft + cropX && x < activeLeft + cropX + cropW
                    && y >= activeTop + cropY && y < activeTop + cropY + cropH
                px[y * fullWidth + x] = inActive
                    ? (inPhoto ? photo(x - activeLeft - cropX, y - activeTop - cropY) : dummy(x, y))
                    : 0
            }
        }
        return RawFrame(url: URL(fileURLWithPath: "/tmp/synthetic.dng"),
                        fullWidth: fullWidth, fullHeight: fullHeight,
                        activeTop: activeTop, activeLeft: activeLeft,
                        activeWidth: activeW ?? fullWidth, activeHeight: activeH ?? fullHeight,
                        cropX: cropX, cropY: cropY, cropWidth: cropW, cropHeight: cropH,
                        cfaRows: 2, cfaCols: 2, cfaPattern: [0, 1, 1, 2],
                        cfaPlaneColor: [0, 1, 2], cfaLayout: 1,
                        blackLevel: [512, 512, 512, 512], whiteLevel: 16383,
                        pixels: px,
                        make: "Test", model: "Synthetic", exposureTime: 0.01, iso: 100,
                        asShotNeutral: [1, 1, 1], colorMatrix1: nil, colorMatrix2: nil,
                        rawMeta: [], calibrationIlluminant1: 21, calibrationIlluminant2: 21,
                        exifTags: [], gpsTags: [], extraIFD0: [],
                        dateTime: "", orientation: 1)
    }

    private func photo(_ x: Int, _ y: Int) -> UInt16 {
        UInt16(3000 + (x * 7 + y * 13) % 500)
    }

    /// The sensor's junk: an alternating 0 / white pattern, which is what a Leica SL3 stores
    /// beyond the crop and what showed up as the band.
    private func dummy(_ x: Int, _ y: Int) -> UInt16 {
        y % 2 == 0 ? 0 : 16383
    }

    // MARK: reading

    func testCropTagsAreReadAsRationals() throws {
        // DefaultCropOrigin/Size are RATIONAL (type 5) in real camera DNGs; `ints` returns [] for
        // that type, which is how the crop silently became "the whole active area".
        let frame = try DNGReader.read(url: try syntheticDNGFile())
        XCTAssertEqual(frame.cropX, 4)
        XCTAssertEqual(frame.cropY, 4)
        XCTAssertEqual(frame.cropWidth, 60)
        XCTAssertEqual(frame.cropHeight, 40)
        // `width`/`height` are the photo size, not the stored size.
        XCTAssertEqual(frame.width, 60)
        XCTAssertEqual(frame.height, 40)
        XCTAssertEqual(frame.fullWidth, 68)
        XCTAssertEqual(frame.fullHeight, 48)
        XCTAssertEqual(frame.sample(0, 0), photo(0, 0), "sample(0,0) is the crop's top-left")
        XCTAssertEqual(frame.sample(59, 39), photo(59, 39))
    }

    func testCFAPatternIsRephasedForOddCropOrigin() {
        // An odd crop offset shifts the Bayer phase. RGGB laid out as rows [0,1] / [1,2]:
        //   shift x by 1 → rows [1,0] / [2,1]  = GRBG
        //   shift y by 1 → rows [1,2] / [0,1]  = GBRG
        let f = makeFrame(fullWidth: 12, fullHeight: 8, cropX: 1, cropY: 0,
                          cropW: 10, cropH: 8, photo: photo, dummy: dummy)
        XCTAssertEqual(f.photoCFAPattern, [1, 0, 2, 1], "RGGB shifted 1 px in x → GRBG")
        let g = makeFrame(fullWidth: 12, fullHeight: 8, cropX: 0, cropY: 1,
                          cropW: 12, cropH: 6, photo: photo, dummy: dummy)
        XCTAssertEqual(g.photoCFAPattern, [1, 2, 0, 1], "RGGB shifted 1 px in y → GBRG")
        // An even offset must not touch the pattern.
        let h = makeFrame(fullWidth: 12, fullHeight: 8, cropX: 4, cropY: 4,
                          cropW: 8, cropH: 4, photo: photo, dummy: dummy)
        XCTAssertEqual(h.photoCFAPattern, [0, 1, 1, 2])
        XCTAssertEqual(CFA.rotate([0, 1, 1, 2], rows: 2, cols: 2, byX: 0, byY: 2), [0, 1, 1, 2])
    }

    // MARK: merging

    /// The actual bug: merge must never let a margin pixel into the output.
    func testMergeExcludesSensorMargins() throws {
        let frame = makeFrame(fullWidth: 68, fullHeight: 48, cropX: 4, cropY: 4,
                              cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        let merged = try HDRMergeCore.merge(frames: [frame], options: MergeOptions(headroom: 4))
        XCTAssertEqual(merged.width, 60)
        XCTAssertEqual(merged.height, 40)

        // Re-derive what the merge should have produced: the photo rectangle, nothing else.
        // With headroom > 1 the scale is fixed by the levels (Merge step 10), so this is exact.
        let black = 512.0, white = 16383.0, headroom = 4.0
        let mult = (65535.0 - black) / ((white - black) * headroom)
        for y in 0..<40 {
            for x in 0..<60 {
                let raw = max(0.0, Double(photo(x, y)) - black)   // step 1 clamps at black
                let expected = raw * mult + black
                XCTAssertEqual(Double(merged.values[y * 60 + x]), expected, accuracy: 0.01,
                               "photo sample \(x),\(y)")
            }
        }
        // And explicitly: no output sample may be above the photo's own peak, which the dummy
        // columns (0 / 16383) would blow past.
        let peak = Double((0..<40).flatMap { y in (0..<60).map { x in Int(photo(x, y)) } }
            .map { $0 - 512 }.max() ?? 0) * mult + black
        for v in merged.values {
            XCTAssertLessThanOrEqual(Double(v), peak + 0.01, "a margin sample leaked into the mosaic")
        }
    }

    /// Two frames with different stored sizes but the same photo rectangle are mergeable — the
    /// old code refused them because it compared ActiveArea.
    func testFramesWithDifferentMarginsButSamePhotoAreMergeable() throws {
        let a = makeFrame(fullWidth: 68, fullHeight: 48, cropX: 4, cropY: 4,
                          cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        let b = makeFrame(fullWidth: 72, fullHeight: 52, cropX: 6, cropY: 6,
                          cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        let merged = try HDRMergeCore.merge(frames: [a, b])
        XCTAssertEqual(merged.width, 60)
        XCTAssertEqual(merged.height, 40)
    }

    /// A crop offset with a different CFA phase makes the frames unmixable; say so instead of
    /// producing a magenta image.
    func testDifferentCFAPhaseIsRejected() throws {
        let a = makeFrame(fullWidth: 68, fullHeight: 48, cropX: 4, cropY: 4,
                          cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        let b = makeFrame(fullWidth: 68, fullHeight: 48, cropX: 5, cropY: 4,
                          cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        XCTAssertThrowsError(try HDRMergeCore.merge(frames: [a, b])) { error in
            guard case MergeError.geometryMismatch = error else {
                return XCTFail("expected geometryMismatch, got \(error)")
            }
        }
    }

    /// The written DNG must describe the photo rectangle, so a decoder cannot resurrect the band.
    func testWrittenDNGCarriesTheCropRectangle() throws {
        let frame = makeFrame(fullWidth: 68, fullHeight: 48, cropX: 4, cropY: 4,
                              cropW: 60, cropH: 40, photo: photo, dummy: dummy)
        let merged = try HDRMergeCore.merge(frames: [frame], options: MergeOptions(headroom: 4))
        let data = try DNGWriter.render(merged, source: frame, bits: 16)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-out-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reread = try DNGReader.read(url: url)
        XCTAssertEqual(reread.fullWidth, 60)
        XCTAssertEqual(reread.fullHeight, 40)
        XCTAssertEqual(reread.cropX, 0)
        XCTAssertEqual(reread.cropY, 0)
        XCTAssertEqual(reread.cropWidth, 60)
        XCTAssertEqual(reread.cropHeight, 40)
        XCTAssertEqual(reread.photoCFAPattern, [0, 1, 1, 2])
    }

    // MARK: helpers

    /// Writes a small DNG whose crop tags are RATIONAL, the way a camera writes them.
    private func syntheticDNGFile(width: Int = 68, height: Int = 48,
                                  cropX: Int = 4, cropY: Int = 4,
                                  cropW: Int = 60, cropH: Int = 40) throws -> URL {
        let frame = makeFrame(fullWidth: width, fullHeight: height, cropX: cropX, cropY: cropY,
                              cropW: cropW, cropH: cropH, photo: self.photo, dummy: self.dummy)
        var data = try DNGWriter.render(
            MergedImage(width: width, height: height,
                        values: frame.pixels.map(Float.init),
                        black: 512, white: 16383,
                        cfaPattern: [0, 1, 1, 2], cfaRows: 2, cfaCols: 2,
                        offsets: [(0, 0)], referenceIndex: 1, report: []),
            source: frame, bits: 16)
        // Rewrite tags 50719/50720 as RATIONAL (type 5, count 2) — the writer emits LONGs, and the
        // bug only appears for the rational encoding real cameras use.
        data = try rewriteCropTagsAsRational(data, cropX: cropX, cropY: cropY,
                                             cropW: cropW, cropH: cropH)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-geometry-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Minimal TIFF patcher: adds a values block and points 50719/50720 at RATIONAL pairs.
    private func rewriteCropTagsAsRational(_ data: Data, cropX: Int, cropY: Int,
                                           cropW: Int, cropH: Int) throws -> Data {
        var bytes = [UInt8](data)
        let entryCount = Int(bytes[8]) | Int(bytes[9]) << 8
        // Append the two rational pairs at the end of the file, 4-byte aligned.
        while bytes.count % 4 != 0 { bytes.append(0) }
        func appendRationals(_ values: [(UInt32, UInt32)]) -> Int {
            let at = bytes.count
            for (n, d) in values {
                for v in [n, d] {
                    bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8((v >> 8) & 0xFF))
                    bytes.append(UInt8((v >> 16) & 0xFF)); bytes.append(UInt8((v >> 24) & 0xFF))
                }
            }
            while bytes.count % 4 != 0 { bytes.append(0) }
            return at
        }
        let originAt = appendRationals([(UInt32(cropX), 1), (UInt32(cropY), 1)])
        let sizeAt = appendRationals([(UInt32(cropW), 1), (UInt32(cropH), 1)])

        var patched = 0
        for i in 0..<entryCount {
            let p = 10 + i * 12
            let tag = UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
            let target: Int?
            switch tag {
            case 50719: target = originAt
            case 50720: target = sizeAt
            default: target = nil
            }
            guard let off = target else { continue }
            bytes[p + 2] = 5; bytes[p + 3] = 0                      // type RATIONAL
            bytes[p + 4] = 2; bytes[p + 5] = 0                      // count 2
            bytes[p + 6] = 0; bytes[p + 7] = 0
            let v = UInt32(off)
            bytes[p + 8] = UInt8(v & 0xFF); bytes[p + 9] = UInt8((v >> 8) & 0xFF)
            bytes[p + 10] = UInt8((v >> 16) & 0xFF); bytes[p + 11] = UInt8((v >> 24) & 0xFF)
            patched += 1
        }
        XCTAssertEqual(patched, 2, "both crop tags must be present to patch them")
        return Data(bytes)
    }
}
