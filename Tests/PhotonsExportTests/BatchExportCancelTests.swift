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
                     primaries: .displayP3, bitDepth: 8)
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
    }

    /// 161 §8 — a cancel that lands during the fifth render must not write the fifth file any more.
    /// Before this the in-flight render fell through to the encoder, so 5 files appeared.
    func testCancelDuringTheFifthRenderLeavesFourFilesAndSixteenCancelled() throws {
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
        XCTAssertEqual(report.written.count, 4, "the render that saw the cancel must not be written")
        XCTAssertEqual(report.cancelledCount, 16)
        XCTAssertEqual(report.outcomes.count, 20)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try files().count, report.written.count,
                       "a cancelled item must not leave a half-written file")
        XCTAssertEqual(Set(report.written.map(\.sourceName)),
                       Set(["i1", "i2", "i3", "i4"]))
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

    // MARK: 161 §8 C1/C2/C3

    /// C1 — three items, concurrency 1, cancel while the second render is in flight: the first file
    /// is already on disk, the other two end `cancelled` and have no file.
    func testC1_CancelAfterTheFirstRenderWritesOneFileAndCancelsTwo() throws {
        let items = (1...3).map { ExportItem(id: "i\($0)", name: "i\($0)") }
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
            // Item 1 has finished rendering and been written by now; cancel on item 2 before it
            // returns, so its pixels exist but must be discarded.
            if n == 2 { token.cancel() }
            return self.image()
        })

        XCTAssertEqual(renders, 2)
        XCTAssertEqual(report.written.count, 1)
        XCTAssertEqual(report.cancelledCount, 2)
        XCTAssertEqual(try files().count, 1, "目录里只能有第 1 项的文件")
        XCTAssertEqual(report.written.first?.sourceName, "i1")
        XCTAssertTrue(report.cancelled.allSatisfy { $0.fileURL == nil })
    }

    /// C2 — all three renders finish, *then* the cancel lands. Every item must end cancelled and the
    /// directory must be empty: no write happens after the click.
    func testC2_CancelAfterEveryRenderButBeforeAnyWriteWritesZeroFiles() throws {
        let items = (1...3).map { ExportItem(id: "i\($0)", name: "i\($0)") }
        let token = CancellationToken()
        let lock = NSLock()
        var renders = 0

        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .png),
                                       outputDirectory: out,
                                       concurrency: 3,
                                       cancel: token,
                                       render: { _, _ in
            lock.lock()
            renders += 1
            let n = renders
            lock.unlock()
            if n == 3 { token.cancel() }
            // Everyone has rendered before anyone returns; the cancel is in place for all three
            // post-render checks.
            while !token.isCancelled { usleep(500) }
            return self.image()
        })

        XCTAssertEqual(renders, 3, "all three renders completed")
        XCTAssertEqual(report.written.count, 0, "取消之后不许再写文件")
        XCTAssertEqual(report.cancelledCount, 3)
        XCTAssertEqual(try files().count, 0)
    }

    /// C3 — no token, no change: same names and byte-identical payloads as a reference run.
    func testC3_WithoutACancelTheOutputIsUnchanged() throws {
        let items = (1...3).map { ExportItem(id: "i\($0)", name: "i\($0)") }
        let firstOut = scratch.appendingPathComponent("c3-a", isDirectory: true)
        let secondOut = scratch.appendingPathComponent("c3-b", isDirectory: true)

        func run(into directory: URL) throws -> [String: Data] {
            let report = BatchExporter.run(items: items,
                                           preset: ExportPreset(format: .png),
                                           outputDirectory: directory,
                                           concurrency: 2,
                                           render: { _, _ in self.image() })
            XCTAssertEqual(report.written.count, 3)
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            return Dictionary(uniqueKeysWithValues: try files.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        }

        let a = try run(into: firstOut)
        let b = try run(into: secondOut)
        XCTAssertEqual(Set(a.keys), Set(b.keys))
        XCTAssertEqual(Set(a.keys), Set(["i1.png", "i2.png", "i3.png"]))
        for name in a.keys {
            XCTAssertEqual(a[name], b[name], "\(name) must be byte-identical without a cancel")
        }
    }
}
