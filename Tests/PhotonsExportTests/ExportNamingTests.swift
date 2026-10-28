import XCTest
import PhotonsCore
@testable import PhotonsExport

/// 099 — the naming surface: the four existing tokens, the two subfolder tokens, and the three
/// conflict policies as the batch actually applies them.
final class ExportNamingTests: XCTestCase {

    private var scratch: URL!
    private var out: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-naming-tests-\(UUID().uuidString)", isDirectory: true)
        out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: string)!
    }

    private func image(width: Int = 24, height: Int = 18) -> DisplayImage {
        DisplayImage(width: width, height: height,
                     rgba: [Float16](repeating: 1, count: width * height * 4),
                     primaries: .sRGB, bitDepth: 8)
    }

    // MARK: filename tokens

    func testAllFourFilenameTokensStillExpand() {
        let got = ExportNaming.baseName(template: "{date}_{name}_r{rating}_{seq}",
                                        item: ExportItem(id: "1", name: "L1030433",
                                                         captureDate: date("2026-03-04 05:06:07"),
                                                         rating: 4),
                                        sequence: 7)
        XCTAssertEqual(got, "20260304_L1030433_r4_0007")
    }

    // MARK: subfolder tokens

    func testSubfolderResolvesDateAndCamera() {
        let item = ExportItem(id: "1", name: "X", captureDate: date("2026-03-04 05:06:07"),
                              cameraKey: "leica|sl3")
        XCTAssertEqual(ExportNaming.subfolder(template: "{date}/{camera}", item: item),
                       "2026-03-04/sl3")
    }

    func testSubfolderUsesTodayWhenTheCaptureDateIsMissing() {
        let item = ExportItem(id: "1", name: "X")
        let now = date("2027-12-31 23:00:00")
        XCTAssertEqual(ExportNaming.subfolder(template: "{date}", item: item, now: now),
                       "2027-12-31")
    }

    func testSubfolderCameraFallsBackWhenTheCatalogHasNoKey() {
        let item = ExportItem(id: "1", name: "X", captureDate: date("2026-03-04 05:06:07"))
        XCTAssertEqual(ExportNaming.subfolder(template: "{camera}", item: item), "camera")
    }

    func testSubfolderCannotWalkOutOfTheDestination() {
        let item = ExportItem(id: "1", name: "X", captureDate: date("2026-03-04 05:06:07"),
                              cameraKey: "leica|sl3")
        XCTAssertEqual(ExportNaming.subfolder(template: "{date}/../{camera}", item: item),
                       "2026-03-04/sl3")
        XCTAssertEqual(ExportNaming.subfolder(template: "/{date}/", item: item), "2026-03-04")
    }

    // MARK: conflict policies

    func testRenameGivesMinusOneThenMinusTwo() {
        let allocator = OutputNameAllocator()
        XCTAssertEqual(allocator.reserve(base: "a", ext: "jpg", in: out, policy: .rename)?
                        .lastPathComponent, "a.jpg")
        XCTAssertEqual(allocator.reserve(base: "a", ext: "jpg", in: out, policy: .rename)?
                        .lastPathComponent, "a-1.jpg")
        XCTAssertEqual(allocator.reserve(base: "a", ext: "jpg", in: out, policy: .rename)?
                        .lastPathComponent, "a-2.jpg")
    }

    func testSkipCountsTheItemAndLeavesTheExistingFileAlone() throws {
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: out.appendingPathComponent("a.jpg"))
        let items = [ExportItem(id: "1", name: "a"), ExportItem(id: "2", name: "b")]
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .jpeg, conflict: .skip),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        XCTAssertEqual(report.written.map(\.sourceName), ["b"])
        XCTAssertEqual(report.skipped.map(\.sourceName), ["a"])
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.jpg")), sentinel)
    }

    func testOverwriteReplacesTheTarget() throws {
        let sentinel = Data("replace me".utf8)
        try sentinel.write(to: out.appendingPathComponent("a.jpg"))
        let report = BatchExporter.run(items: [ExportItem(id: "1", name: "a")],
                                       preset: ExportPreset(format: .jpeg, conflict: .overwrite),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        XCTAssertEqual(report.written.count, 1)
        XCTAssertEqual(report.written.first?.fileURL?.lastPathComponent, "a.jpg")
        XCTAssertNotEqual(try Data(contentsOf: out.appendingPathComponent("a.jpg")), sentinel)
    }

    // MARK: subfolder reaches the disk

    func testBatchWritesIntoTheResolvedSubfolder() throws {
        let item = ExportItem(id: "1", name: "a", captureDate: date("2026-03-04 05:06:07"),
                              cameraKey: "leica|sl3")
        let report = BatchExporter.run(items: [item],
                                       preset: ExportPreset(format: .jpeg,
                                                            subfolder: "{date}/{camera}"),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        XCTAssertEqual(url.path, out.appendingPathComponent("2026-03-04/sl3/a.jpg").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
