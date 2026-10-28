import XCTest
import PhotonsCore
@testable import PhotonsExport

/// 099 — the three metadata levels, and `.none` winning over a stale `writeXMP` flag.
final class ExportMetadataLevelTests: XCTestCase {

    private var scratch: URL!
    private var out: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func image() -> DisplayImage {
        DisplayImage(width: 24, height: 18,
                     rgba: [Float16](repeating: 0.5, count: 24 * 18 * 4),
                     primaries: .sRGB, bitDepth: 8)
    }

    private func edited() -> ExportItem {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        return ExportItem(id: "1", name: "a", edit: edit,
                          author: "Ada Lovelace", copyright: "© 2026 Ada")
    }

    func testAllKeepsTheDevelopPacket() throws {
        let report = BatchExporter.run(items: [edited()],
                                       preset: ExportPreset(format: .jpeg, writeXMP: true,
                                                            metadataLevel: .all),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: url))
        XCTAssertNotNil(XMPReadback.string(metadata, "photons:settings"))
    }

    func testNoneWritesNoXMPEvenWhenTheFlagSaysYes() throws {
        let report = BatchExporter.run(items: [edited()],
                                       preset: ExportPreset(format: .jpeg, writeXMP: true,
                                                            metadataLevel: .none),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        XCTAssertNil(report.written.first?.xmpURL)
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: url))
        XCTAssertNil(XMPReadback.string(metadata, "photons:settings"))
        XCTAssertNil(XMPReadback.string(metadata, "crs:Version"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            url.deletingPathExtension().appendingPathExtension("xmp").path))
    }

    func testCopyrightWritesOnlyTheSidecar() throws {
        let report = BatchExporter.run(items: [edited()],
                                       preset: ExportPreset(format: .jpeg, writeXMP: true,
                                                            metadataLevel: .copyright),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let sidecar = try XCTUnwrap(report.written.first?.xmpURL)
        XCTAssertEqual(sidecar.pathExtension, "xmp")
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("Ada Lovelace"))
        XCTAssertTrue(text.contains("© 2026 Ada"))
        XCTAssertFalse(text.contains("crs:"), "the copyright level must not carry develop settings")
        XCTAssertFalse(text.contains("photons:settings"))
    }
}
