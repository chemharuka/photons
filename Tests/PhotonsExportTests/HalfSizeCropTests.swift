import XCTest
import CoreGraphics
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 163 §1.6 — half-size gain maps are even × even, and an odd source is trimmed right/bottom by 1 px
/// with a non-fatal note. The exact 6001×4001 case is checked through the pure plan (no 384 MB pixel
/// fixture); the note path is checked end-to-end with a small odd picture.
final class HalfSizeCropTests: XCTestCase {

    private func preset(halfSize: Bool) -> ExportPreset {
        ExportPreset(format: .jpeg, bitDepth: 8, colorSpace: .displayP3,
                     hdr: HDRExport(kind: .gainMap, gainMap: .iso, halfSize: halfSize))
    }

    private func image(width: Int, height: Int) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            rgba[o] = Float16(0.2 + 0.6 * Double(i % width) / Double(max(1, width - 1)))
            rgba[o + 1] = Float16(0.4)
            rgba[o + 2] = Float16(0.8)
            rgba[o + 3] = 1
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 8)
    }

    // MARK: - the exact task numbers

    func test6001By4001HalfSizePlanIs3000By2000AfterEvenCrop() {
        let plan = GainMapSizing.plan(width: 6001, height: 4001, halfSize: true)
        XCTAssertEqual(plan.output, ImageSize(width: 6000, height: 4000))
        XCTAssertEqual(plan.gainMap, ImageSize(width: 3000, height: 2000))
        XCTAssertEqual(plan.crop, HalfSizeCrop(dx: 1, dy: 1))
        XCTAssertEqual(plan.crop.hint(current: plan.input),
                       "半尺寸需要偶数像素：当前 6001×4001，将裁到 6000×4000（右/下各 1 px）")
    }

    func test6000By4000HalfSizePlanIsExactlyHalfWithNoCrop() {
        let plan = GainMapSizing.plan(width: 6000, height: 4000, halfSize: true)
        XCTAssertEqual(plan.output, ImageSize(width: 6000, height: 4000))
        XCTAssertEqual(plan.gainMap, ImageSize(width: 3000, height: 2000))
        XCTAssertEqual(plan.crop, .none)
        XCTAssertNil(plan.crop.hint(current: plan.input))
    }

    func testFullSizePlanKeepsTheOddDimensions() {
        let plan = GainMapSizing.plan(width: 6001, height: 4001, halfSize: false)
        XCTAssertEqual(plan.output, ImageSize(width: 6001, height: 4001))
        XCTAssertEqual(plan.gainMap, ImageSize(width: 6001, height: 4001))
        XCTAssertEqual(plan.crop, .none)
    }

    // MARK: - the batch path (report/metrics/note)

    func testOddSourceIsCroppedAndTheNoteCarriesDXAndDY() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-half-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let report = BatchExporter.run(items: [ExportItem(id: "odd", name: "odd")],
                                       preset: preset(halfSize: true),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 61, height: 41) })
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(written.pixelSize, ImageSize(width: 60, height: 40))
        XCTAssertEqual(written.croppedForHalfSize, HalfSizeCrop(dx: 1, dy: 1))
        XCTAssertTrue(written.warnings.contains {
            $0.contains("61×41") && $0.contains("已裁 (1,1)") && $0.contains("60×40")
        }, "\(written.warnings)")
        if let url = written.fileURL {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(cg.width, 60)
            XCTAssertEqual(cg.height, 40)
        }
    }

    func testEvenSourceHasNoCropAndNoNote() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-half-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let report = BatchExporter.run(items: [ExportItem(id: "even", name: "even")],
                                       preset: preset(halfSize: true),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 60, height: 40) })
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(written.pixelSize, ImageSize(width: 60, height: 40))
        XCTAssertEqual(written.croppedForHalfSize, .none)
        XCTAssertFalse(written.warnings.contains { $0.contains("半尺寸增益图") },
                       "\(written.warnings)")
    }

    func testFullSizeKeepsOddPixelsAndHasNoNote() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-half-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let report = BatchExporter.run(items: [ExportItem(id: "full", name: "full")],
                                       preset: preset(halfSize: false),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 61, height: 41) })
        let written = try XCTUnwrap(report.written.first)
        XCTAssertEqual(written.pixelSize, ImageSize(width: 61, height: 41))
        XCTAssertEqual(written.croppedForHalfSize, .none)
        XCTAssertFalse(written.warnings.contains { $0.contains("半尺寸增益图") },
                       "\(written.warnings)")
    }
}
