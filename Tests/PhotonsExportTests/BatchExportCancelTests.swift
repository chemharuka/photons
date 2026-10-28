import XCTest
import PhotonsCore
@testable import PhotonsExport

/// 099 — cancelling a batch keeps the finished files and never leaves a partial one behind.
final class BatchExportCancelTests: XCTestCase {

    private var scratch: URL!
    private var out: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-cancel-tests-\(UUID().uuidString)", isDirectory: true)
        out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func image(width: Int = 16, height: Int = 16) -> DisplayImage {
        DisplayImage(width: width, height: height,
                     rgba: [Float16](repeating: 0.5, count: width * height * 4),
                     primaries: .sRGB, bitDepth: 8)
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
    }

    func testCancelAfterTheFifthRenderLeavesFiveFilesAndFifteenCancelled() throws {
        let items = (1...20).map { ExportItem(id: "i\($0)", name: "i\($0)") }
        let token = CancellationToken()
        let lock = NSLock()
        var renders = 0

        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .png),
                                       outputDirectory: out,
                                       concurrency: 1,
                                       cancel: token,
                                       render: { _, _ in
            lock.lock()
            renders += 1
            let n = renders
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            if n == 5 { token.cancel() }
            return self.image()
        })

        XCTAssertEqual(renders, 5, "items queued after the cancel must not even render")
        XCTAssertEqual(report.written.count, 5)
        XCTAssertEqual(report.cancelledCount, 15)
        XCTAssertEqual(report.outcomes.count, 20)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try files().count, report.written.count,
                       "a cancelled item must not leave a half-written file")
        XCTAssertEqual(Set(report.written.map(\.sourceName)), Set(["i1", "i2", "i3", "i4", "i5"]))
        XCTAssertTrue(report.cancelled.allSatisfy { $0.fileURL == nil })
    }

    func testCancelBeforeTheStartCancelsEveryItem() throws {
        let token = CancellationToken()
        token.cancel()
        let items = (1...3).map { ExportItem(id: "i\($0)", name: "i\($0)") }
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .png),
                                       outputDirectory: out,
                                       cancel: token,
                                       render: { _, _ in XCTFail("nothing should render"); return self.image() })
        XCTAssertEqual(report.written.count, 0)
        XCTAssertEqual(report.cancelledCount, 3)
        XCTAssertEqual(try files().count, 0)
    }
}
