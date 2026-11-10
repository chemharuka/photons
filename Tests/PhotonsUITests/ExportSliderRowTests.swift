import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 217 — 导出界面：水印「不透明度」与「质量」两行共用同一个滑杆行。
///
/// The two rows used to be different controls (150 + 44 vs 140 + a hand-written `TextField`).
/// These tests read the hosted view back: the row probes report the width the layout really gave
/// the slider and the number field, and the number fields are driven through AppKit's field editor
/// so a typed value goes through the same `SliderNumberField` path the app uses.
@MainActor
final class ExportSliderRowTests: XCTestCase {

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private var scratch: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-slider-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: MemoryDraftStore())
    }

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    /// 322 —— 水印不透明度在「输出后」段里；量它的行得把那一段展开。
    private func host(model sheet: ExportSheetModel, expanded: Bool = true) throws -> Hosted {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store: ExportSectionCollapseStore = expanded
            ? .memory([ExportSheetView.afterSection: true])
            : .memory()
        let host = NSHostingView(rootView: ExportSheetView(model: sheet, sectionStore: store))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        TestWindows.show(window, key: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Hosted(host: host, window: window)
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func probe(_ kind: ExportSliderRowProbe.Kind, _ rowID: String,
                       in host: NSView) throws -> ExportSliderRowProbe {
        let match = descendants(of: host)
            .compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == kind && $0.rowID == rowID }
        return try XCTUnwrap(match, "no \(kind.rawValue) probe for \(rowID)")
    }

    private func hasProbe(_ kind: ExportSliderRowProbe.Kind, _ rowID: String,
                          in host: NSView) -> Bool {
        descendants(of: host).contains {
            guard let probe = $0 as? ExportSliderRowProbe else { return false }
            return probe.kind == kind && probe.rowID == rowID
        }
    }

    /// §3 acceptance 1 — both rows are a flexible slider + 46 number, measured on the hosted view.
    ///
    /// 335：滑杆不再写死 140。它从主列起点 138 起、吃掉读数（46 + 8 + `%`）留下的宽度，
    /// 所以两行的宽度仍然相等（同一个 `%` 单位），但比 140 宽。
    func testBothRowsUseTheSameSliderAndNumberMetrics() throws {
        let sheet = model()
        let hosted = try host(model: sheet)

        let qualitySlider = try probe(.slider, "export.quality", in: hosted.host)
        let opacitySlider = try probe(.slider, "export.watermark.opacity", in: hosted.host)
        let qualityNumber = try probe(.number, "export.quality", in: hosted.host)
        let opacityNumber = try probe(.number, "export.watermark.opacity", in: hosted.host)

        print(String(format: "217 · quality slider %.0f × %.0f · number %.0f × %.0f",
                     qualitySlider.frame.width, qualitySlider.frame.height,
                     qualityNumber.frame.width, qualityNumber.frame.height))
        print(String(format: "217 · opacity slider %.0f × %.0f · number %.0f × %.0f",
                     opacitySlider.frame.width, opacitySlider.frame.height,
                     opacityNumber.frame.width, opacityNumber.frame.height))

        XCTAssertGreaterThanOrEqual(qualitySlider.frame.width, ExportRowGrid.sliderWidth - 0.01,
                                    "滑杆不窄于 140（335 之后是吃满主列）")
        XCTAssertGreaterThanOrEqual(opacitySlider.frame.width, ExportRowGrid.sliderWidth - 0.01)
        XCTAssertEqual(qualityNumber.frame.width, 46, accuracy: 0.01)
        XCTAssertEqual(opacityNumber.frame.width, 46, accuracy: 0.01)
        XCTAssertEqual(qualitySlider.frame.width, opacitySlider.frame.width, accuracy: 0.01,
                       "两行滑杆同宽")
        XCTAssertEqual(qualityNumber.frame.width, opacityNumber.frame.width, accuracy: 0.01,
                       "两行数值框同宽")
    }

    /// §3 acceptance 3 + the unit: both numbers are the app-wide `SliderNumberField`. 288 changed
    /// 质量's **readout** to percent (10…100, `%`), while the stored value is still 0.1…1.0, so the
    /// typed values here are percent (75 → 0.75) rather than the old 0…1 decimal text.
    func testQualityAndOpacityWriteThroughTheSharedNumberField() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        XCTAssertTrue(hasProbe(.unit, "export.watermark.opacity", in: hosted.host),
                      "不透明度必须仍带 % 单位")
        XCTAssertTrue(hasProbe(.unit, "export.quality", in: hosted.host),
                      "288：质量也带 % 单位，读数区间统一 10…100")

        let fields = descendants(of: hosted.host).compactMap { $0 as? NumberTextField }
        let quality = try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == "export.quality" })
        let opacity = try XCTUnwrap(fields.first {
            $0.accessibilityIdentifier() == "export.watermark.opacity"
        })

        try type("50", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 0.5, accuracy: 1e-12)

        try type("200", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 1.0, accuracy: 1e-12, "200% 钳到 100%")

        try type("abc", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 1.0, accuracy: 1e-12, "abc 保持上一个合法值")

        try type("30", into: opacity, in: hosted)
        XCTAssertEqual(sheet.preset.watermarkOpacity, 30, accuracy: 1e-12)
        XCTAssertTrue(hasProbe(.unit, "export.watermark.opacity", in: hosted.host),
                      "写完后单位仍是 %")
    }

    /// Drive a field exactly like a click + typing + `↵` does (`NumberFieldTypingTests`' path).
    private func type(_ text: String, into field: NumberTextField, in hosted: Hosted) throws {
        XCTAssertTrue(hosted.window.makeFirstResponder(field), "字段必须能成为第一响应者")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "字段没有 field editor")
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosted.host.layoutSubtreeIfNeeded()
    }
}
