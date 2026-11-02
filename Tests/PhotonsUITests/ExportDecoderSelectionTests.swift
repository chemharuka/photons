import XCTest
import Foundation
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 导出必须使用用户在「解码模型」里选的版本（以及同一批解码期参数）。
///
/// The defect: `UIExportRenderer` and `photonsctl export batch` built `DecodeOptions` with the
/// document's white balance and scale only. `decoderVersion` stayed `nil`, so a document that asked
/// for v9 produced a v8 file — silently, because `RAWDecoder` reports the *effective* version and the
/// export path never looked at the document's request. `detailSettings` had the same omission, so the
/// four decoder-side amounts on screen were not the ones in the file either.
///
/// The source guard is the cheap, always-running half: both exporters must take the whole
/// `edit.decodeInputs`, not a hand-picked subset. The pixel test is the measured half: same picture,
/// same preset, two documents that differ only in `decoderVersion`, and the exported SHA-256 must
/// move.
final class ExportDecoderSelectionTests: XCTestCase {

    // MARK: - 1. both exporters take the whole decode document

    func testBothExportersPassTheDocumentsDecoderVersionAndDetail() throws {
        let sources = [Self.exportSheetSource, Self.cliExportSource]
        XCTAssertEqual(sources.count, 2)
        for url in sources {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            XCTAssertTrue(source.contains("let inputs = edit.decodeInputs"),
                          "\(name): the export must read the document's decode inputs")
            XCTAssertTrue(source.contains("decoderVersion: inputs.decoderVersion"),
                          "\(name): 导出没有把用户选的解码器版本交给 decoder")
            XCTAssertTrue(source.contains("detail: inputs.detail"),
                          "\(name): 导出没有把解码期降噪/细节交给 decoder")
            XCTAssertTrue(source.contains("whiteBalance: exportWhiteBalance"),
                          "\(name): 导出的白平衡来自文档")
        }
    }

    // MARK: - 2. the pixels follow the version

    /// Same RAW, same preset, same crop — only `decoderVersion` differs. If the export path ignores
    /// the document's pick (the reported defect), both SHA-256s are the v8 decode and the assertion
    /// goes red. The default document asks for nothing (`nil`), which is the byte-identical v8 path.
    func testExportedPixelsFollowTheDocumentsDecoderVersion() throws {
        let url = try Self.fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        let preset = ExportPreset(format: .jpeg, longEdge: 1024, quality: 0.9, bitDepth: 8,
                                  colorSpace: .sRGB, sdrToneMapping: .none)

        var v8Document = EditModel.neutral
        v8Document.decoderVersion = nil
        var v9Document = EditModel.neutral
        v9Document.decoderVersion = "9.dng"

        let v8 = try UIExportRenderer.render(
            item: ExportItem(id: "export-decoder", name: "export-decoder",
                             edit: v8Document, sourceURL: url),
            preset: preset, native: nil)
        let v9 = try UIExportRenderer.render(
            item: ExportItem(id: "export-decoder", name: "export-decoder",
                             edit: v9Document, sourceURL: url),
            preset: preset, native: nil)

        let hash8 = v8.sha256()
        let hash9 = v9.sha256()
        print("EXPORT decoder · v8 \(hash8.prefix(16)) · v9 \(hash9.prefix(16))"
              + " · \(v8.size.width)×\(v8.size.height)")

        XCTAssertEqual(v8.size, v9.size, "版本只换解码器，不换输出尺寸")
        XCTAssertNotEqual(hash8, hash9,
                          "导出的像素与文档选的 v9 无关 —— decoderVersion 没有传给 decoder")
    }

    // MARK: - fixture / paths

    private static func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var exportSheetSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift")
    }

    private static var cliExportSource: URL {
        repoRoot.appendingPathComponent("Sources/photonsctl/export.swift")
    }
}
