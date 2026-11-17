import XCTest
import SwiftUI
import PhotonsCore
import PhotonsExport
import PhotonsLocalization
@testable import PhotonsUI

@MainActor
final class ExportSizeAndWatermarkTests: XCTestCase {
    private func model() -> ExportSheetModel {
        ExportSheetModel(draftStore: ExportSheetFooterTests.MemoryDraftStore())
    }

    func testEstimateWaitsForWholeSelectionAndUpdatesWithSettings() throws {
        let sheet = model()
        sheet.selectionCount = 2
        sheet.selectionContents = [.init(width: 6000, height: 4000)]
        XCTAssertNil(sheet.estimatedFileSize, "Unknown dimensions must not silently omit a photo from the total")
        sheet.selectionContents.append(.init(width: 4000, height: 3000))
        let original = try XCTUnwrap(sheet.estimatedFileSize)
        XCTAssertEqual(original.fileCount, 2)
        XCTAssertTrue(ExportFileSizeText.summary(original).contains("合计"))
        sheet.selectSizingMode(.percent); sheet.preset.percent = 50
        XCTAssertLessThan(try XCTUnwrap(sheet.estimatedFileSize).upperBytes, original.upperBytes)
        XCTAssertFalse(ExportFileSizeText.summary(sheet.estimatedFileSize).contains("{0}"))
        XCTAssertEqual(ExportFileSizeText.summary(nil), "预计大小：—")
    }

    func testWatermarkNoneCanBeEnabledAndRestoresCustomText() {
        let sheet = model()
        for format in [ExportFormat.jpeg, .heic, .tiff, .png, .avif] {
            sheet.selectFormat(format)
            sheet.setWatermarkEnabled(false)
            XCTAssertTrue(sheet.canChooseWatermark)
            XCTAssertFalse(sheet.canEditWatermark)
            sheet.setWatermarkEnabled(true)
            XCTAssertTrue(sheet.canEditWatermark)
            sheet.preset.watermarkText = "Leo © 2026"
            sheet.setWatermarkEnabled(false)
            XCTAssertEqual(sheet.effectivePreset.watermarkText, "")
            sheet.setWatermarkEnabled(true)
            XCTAssertEqual(sheet.effectivePreset.watermarkText, "Leo © 2026")
        }
        sheet.phase = .running
        XCTAssertFalse(sheet.canChooseWatermark)
        sheet.setWatermarkEnabled(false)
        XCTAssertEqual(sheet.preset.watermarkText, "Leo © 2026")
    }

    func testDNGDisablesWatermarksWithoutLosingNormalExportChoice() {
        let sheet = model()
        sheet.preset.watermarkText = "Leo"
        sheet.allowsLinearDNG = true; sheet.usesLinearDNG = true
        XCTAssertFalse(sheet.canChooseWatermark)
        XCTAssertFalse(sheet.canEditWatermark)
        XCTAssertFalse(sheet.watermarkEnabled)
        XCTAssertEqual(sheet.effectivePreset.watermarkText, "")
        XCTAssertEqual(L10n.tr("export.watermark.dngHint"), "无损输出下将禁用水印")
        sheet.setWatermarkEnabled(false)
        sheet.usesLinearDNG = false
        XCTAssertTrue(sheet.canChooseWatermark)
        XCTAssertTrue(sheet.canEditWatermark)
        XCTAssertEqual(sheet.effectivePreset.watermarkText, "Leo")
    }

    func testSliceEstimateTotalsEveryTileAndTracksHDR() throws {
        let model = SocialMediaSliceModel(items: [.init(id: "a", name: "a"), .init(id: "b", name: "b")])
        XCTAssertNil(model.estimatedFileSize())
        model.sizes = ["a": .init(width: 6000, height: 2000), "b": .init(width: 6000, height: 2000)]
        model.settings.dynamicRange = .sdr
        let current = try XCTUnwrap(model.estimatedFileSize(currentOnly: true))
        let all = try XCTUnwrap(model.estimatedFileSize())
        XCTAssertEqual(all.fileCount, model.totalSlices)
        XCTAssertEqual(all.upperBytes, current.upperBytes * 2)
        model.settings.dynamicRange = .hdr
        XCTAssertGreaterThan(try XCTUnwrap(model.estimatedFileSize()).upperBytes, all.upperBytes)
        model.sizes.removeValue(forKey: "b")
        XCTAssertNil(model.estimatedFileSize())
        XCTAssertNotNil(model.estimatedFileSize(currentOnly: true))
    }

    func testExportFooterFitsBesideButtonsInNormalAndDNGWindows() throws {
        let sheet = model()
        sheet.selectionCount = 1
        sheet.selectionContents = [.init(width: 21000, height: 16000)]
        sheet.allowsLinearDNG = true
        let store = ExportSectionCollapseStore.memory([ExportSheetView.afterSection: true])
        for dng in [false, true] {
            sheet.usesLinearDNG = dng
            let host = NSHostingView(rootView: ExportSheetView(model: sheet, sectionStore: store)
                .background(Color(nsColor: StudioTheme.raised)))
            host.frame = NSRect(x: 0, y: 0, width: ExportRowGrid.panelWidth, height: 900)
            let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let probes = descendants(host).compactMap { $0 as? ExportRowGridProbe }
            let summary = try XCTUnwrap(probes.first { $0.kind == .summary })
            let buttons = try XCTUnwrap(probes.first { $0.kind == .buttons })
            let left = summary.convert(summary.bounds, to: host), right = buttons.convert(buttons.bounds, to: host)
            let labelWidth = (ExportFileSizeText.summary(sheet.estimatedFileSize) as NSString).size(
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width
            XCTAssertGreaterThanOrEqual(left.width, labelWidth - 1, "The full estimate must fit without truncation")
            XCTAssertLessThan(left.maxX, right.minX)
            XCTAssertEqual(left.midY, right.midY, accuracy: 1)
            if ProcessInfo.processInfo.environment["PHOTONS_EXPORT_SIZE_SNAPSHOTS"] == "1" {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = dng ? "dng" : "normal"
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/photons-export-size-\(name).png"))
            }
        }
    }
}
