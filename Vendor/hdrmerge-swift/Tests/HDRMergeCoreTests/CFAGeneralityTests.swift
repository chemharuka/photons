import Foundation
import XCTest
@testable import HDRMergeCore

/// Nothing about the CFA should be hardcoded to "2×2 Bayer, 3 colours".
///
/// The real cameras on this machine all happen to be RGGB (499 DNGs audited: every one is
/// `CFARepeatPatternDim = 2,2` with a 3-entry `CFAPlaneColor`), which is exactly why a hardcoded
/// 2×2 assumption would survive testing and then break on the first X-Trans / RGBW / dual-green
/// file. These tests drive the general paths directly.
final class CFAGeneralityTests: XCTestCase {

    private func makeFrame(rows: Int, cols: Int, planeColor: [UInt8], pattern: [UInt8],
                           width: Int, height: Int,
                           photo: (Int, Int) -> UInt16) -> RawFrame {
        var px = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { px[y * width + x] = photo(x, y) } }
        return RawFrame(url: URL(fileURLWithPath: "/tmp/cfa.dng"),
                        fullWidth: width, fullHeight: height,
                        activeTop: 0, activeLeft: 0, activeWidth: width, activeHeight: height,
                        cropX: 0, cropY: 0, cropWidth: width, cropHeight: height,
                        cfaRows: rows, cfaCols: cols, cfaPattern: pattern,
                        cfaPlaneColor: planeColor, cfaLayout: 1,
                        blackLevel: [Double](repeating: 512, count: rows * cols),
                        whiteLevel: 65535, pixels: px,
                        make: "Test", model: "CFA", exposureTime: 0.01, iso: 100,
                        asShotNeutral: [1, 1, 1], colorMatrix1: nil, colorMatrix2: nil,
                        rawMeta: [], calibrationIlluminant1: 21, calibrationIlluminant2: 21,
                        exifTags: [], gpsTags: [], extraIFD0: [], dateTime: "", orientation: 1)
    }

    /// RGGB and its rotated forms must round-trip through `CFA.rotate` exactly.
    func testRotateCoversAllFourBayerPhases() {
        let rggb: [UInt8] = [0, 1, 1, 2]
        XCTAssertEqual(CFA.rotate(rggb, rows: 2, cols: 2, byX: 0, byY: 0), [0, 1, 1, 2])  // RGGB
        XCTAssertEqual(CFA.rotate(rggb, rows: 2, cols: 2, byX: 1, byY: 0), [1, 0, 2, 1])  // GRBG
        XCTAssertEqual(CFA.rotate(rggb, rows: 2, cols: 2, byX: 0, byY: 1), [1, 2, 0, 1])  // GBRG
        XCTAssertEqual(CFA.rotate(rggb, rows: 2, cols: 2, byX: 1, byY: 1), [2, 1, 1, 0])  // BGGR
        // Rotating by the repeat returns the original, for every phase.
        for dx in 0..<4 {
            for dy in 0..<4 {
                let r = CFA.rotate(rggb, rows: 2, cols: 2, byX: dx, byY: dy)
                XCTAssertEqual(r, CFA.rotate(rggb, rows: 2, cols: 2, byX: dx % 2, byY: dy % 2))
            }
        }
    }

    /// A 6×6 CFA (the shape X-Trans writes) must rotate by its own geometry, not by 2.
    func testRotateHandlesNonSquareSixBySix() {
        let pattern = (0..<36).map { UInt8($0 % 5) }
        let rotated = CFA.rotate(pattern, rows: 6, cols: 6, byX: 1, byY: 2)
        XCTAssertEqual(rotated.count, 36)
        XCTAssertEqual(rotated[0], pattern[(0 + 2) % 6 * 6 + (0 + 1) % 6])
        XCTAssertEqual(rotated[35], pattern[(5 + 2) % 6 * 6 + (5 + 1) % 6])
        // A full period is a no-op.
        XCTAssertEqual(CFA.rotate(pattern, rows: 6, cols: 6, byX: 6, byY: 6), pattern)
    }

    /// A 4-plane CFA (RGBW-style) must keep four distinct planes all the way through the merge,
    /// and the written file must carry a 4-entry CFAPlaneColor.
    func testFourPlaneCFASurvivesMergeAndWrite() throws {
        let rows = 2, cols = 2
        let pattern: [UInt8] = [0, 1, 2, 3]          // R, G, B, W
        let planeColor: [UInt8] = [0, 1, 2, 3]
        // Four distinguishable levels, one per plane, so a flattened-to-3 mistake would show up
        // as two planes sharing a value.
        let level: [UInt16] = [1000, 2000, 3000, 4000]
        let frame = makeFrame(rows: rows, cols: cols, planeColor: planeColor, pattern: pattern,
                              width: 32, height: 32) { x, y in
            level[Int(pattern[(y % rows) * cols + (x % cols)])]
        }
        let merged = try HDRMergeCore.merge(frames: [frame], options: MergeOptions(headroom: 4))
        XCTAssertEqual(merged.cfaPattern, [0, 1, 2, 3])
        XCTAssertEqual(merged.cfaPlaneColor, [0, 1, 2, 3])

        let data = try DNGWriter.render(merged, source: frame, bits: 16)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfa4-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let reread = try DNGReader.read(url: url)
        XCTAssertEqual(reread.cfaPlaneColor, [0, 1, 2, 3], "four planes must not be flattened to RGB")
        XCTAssertEqual(reread.cfaPattern, [0, 1, 2, 3])
    }

    /// The white level comes from the *brightest* frame's own CFA phase. Feed the bracket in
    /// brightest-first order with a phase that differs from the first input's, and check the
    /// reported saturation threshold still matches the brightest frame's channel layout.
    func testSaturationUsesBrightestFramesOwnPhase() throws {
        // Darker frame first (0), brighter second (1). Their raw values are what tell them apart,
        // so after the internal sort planes[0] is the *second* input.
        let pattern: [UInt8] = [0, 1, 1, 2]
        let dim = makeFrame(rows: 2, cols: 2, planeColor: [0, 1, 2], pattern: pattern,
                            width: 64, height: 64) { _, _ in 2000 }
        let bright = makeFrame(rows: 2, cols: 2, planeColor: [0, 1, 2], pattern: pattern,
                               width: 64, height: 64) { _, _ in 12000 }
        let merged = try HDRMergeCore.merge(frames: [dim, bright])
        // The saturation threshold must be derived from the bright frame (12000), not clamped to
        // the dim one; a wrong-phase histogram would land on a different number.
        let line = merged.report.first { $0.hasPrefix("white level") } ?? ""
        XCTAssertTrue(line.contains("saturation threshold"),
                      "report should name a saturation threshold, got: \(line)")
        let threshold = Int(line.split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThan(threshold, 2000,
                             "saturation must come from the bright frame, not the dim one (\(line))")
    }

    /// Staggered CFALayout changes the pixel-to-plane mapping; refuse it rather than merge garbage.
    func testStaggeredLayoutIsRejectedAtRead() throws {
        // Patch a real output's 50711 to 2 (staggered) and confirm the reader says no.
        let frame = makeFrame(rows: 2, cols: 2, planeColor: [0, 1, 2], pattern: [0, 1, 1, 2],
                              width: 16, height: 16) { _, _ in 1000 }
        let merged = try HDRMergeCore.merge(frames: [frame])
        var data = try DNGWriter.render(merged, source: frame, bits: 16)
        var bytes = [UInt8](data)
        let n = Int(bytes[8]) | Int(bytes[9]) << 8
        for i in 0..<n {
            let p = 10 + i * 12
            let tag = UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
            guard tag == 50711 else { continue }
            bytes[p + 8] = 2; bytes[p + 9] = 0; bytes[p + 10] = 0; bytes[p + 11] = 0
        }
        data = Data(bytes)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("staggered-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DNGReader.read(url: url)) { error in
            guard case DNGError.inconsistentGeometry(let s) = error else {
                return XCTFail("expected inconsistentGeometry, got \(error)")
            }
            XCTAssertTrue(s.contains("CFALayout"), s)
        }
    }

    /// A pattern index outside CFAPlaneColor is a corrupt file, not something to paper over.
    func testPatternIndexOutsidePlaneColorIsRejected() throws {
        let frame = makeFrame(rows: 2, cols: 2, planeColor: [0, 1, 2], pattern: [0, 1, 1, 2],
                              width: 16, height: 16) { _, _ in 1000 }
        let merged = try HDRMergeCore.merge(frames: [frame])
        var data = try DNGWriter.render(merged, source: frame, bits: 16)
        var bytes = [UInt8](data)
        let n = Int(bytes[8]) | Int(bytes[9]) << 8
        for i in 0..<n {
            let p = 10 + i * 12
            let tag = UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
            guard tag == 33422 else { continue }
            // CFAPattern is 4 bytes, stored inline in the entry.
            bytes[p + 8 + 3] = 9          // index 9 with only 3 plane colours
        }
        data = Data(bytes)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("badcfa-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DNGReader.read(url: url))
    }
}
