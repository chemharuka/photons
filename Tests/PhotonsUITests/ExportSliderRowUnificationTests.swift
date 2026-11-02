import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 243 — 导出面板数值行统一。
///
/// 217 unified 质量 / 不透明度 on `exportSliderRow`; PPI / 长边 / 长边百分比 were still hand
/// assembled `HStack`s with their own `SliderNumberField(width: 60)` and a loose unit `Text`.
/// These tests pin the structural guards (one call site, no width literals, five rows through the
/// constructor) and read the hosted layout back so every numeric row's rect can be compared.
@MainActor
final class ExportSliderRowUnificationTests: XCTestCase {

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
            .appendingPathComponent("photons-slider-unify-\(UUID().uuidString)", isDirectory: true)
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

    private func host(model sheet: ExportSheetModel) throws -> Hosted {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ExportSheetView(model: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
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

    private func rect(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }

    private func numberField(_ axID: String, in host: NSView) throws -> NumberTextField {
        let fields = descendants(of: host).compactMap { $0 as? NumberTextField }
        return try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == axID },
                             "no NumberTextField for \(axID)")
    }

    /// The checkbox rows' axIDs have no AppKit leaf under `swift test` (the hosted SwiftUI tree
    /// exposes no `accessibilityChildren`), so the honest fallback is: the row's number probe is in
    /// the tree (the row rendered) **and** the axID is still attached in source.
    private func assertTogglePresent(_ axID: String, row: String, in host: NSView) throws {
        XCTAssertTrue(hasProbe(.number, row, in: host), "\(row) 行必须渲染")
        XCTAssertTrue(try sourceText().contains("\"\(axID)\""),
                      "\(axID) 必须仍挂在控件上")
    }

    // MARK: structure

    private func sourceText() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    func testSliderNumberFieldHasExactlyOneCallSite() throws {
        let text = try sourceText()
        XCTAssertEqual(text.components(separatedBy: "SliderNumberField(").count - 1, 1)
    }

    func testNoNumericWidthLiterals() throws {
        let text = try sourceText()
        let pattern = "width: (60|44|46|140|150)(?!\\d)"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let hits = regex.numberOfMatches(in: text, range: range)
        XCTAssertEqual(hits, 0, "数值框/滑杆宽度必须走 ExportSliderRowMetrics，命中 \(hits) 处字面量")
    }

    func testEveryNumericRowGoesThroughTheConstructor() throws {
        let text = try sourceText()
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "exportSliderRow(label:").count - 1, 5)
    }

    // MARK: layout

    /// Number x/width are identical on all five rows; only 质量 / 不透明度 carry a slider.
    func testValueRowsShareTheNumberRectWithTheSliderRows() throws {
        let sheet = model()
        let hosted = try host(model: sheet)

        let qualityNumber = try probe(.number, "export.quality", in: hosted.host)
        let opacityNumber = try probe(.number, "export.watermark.opacity", in: hosted.host)
        let ppiNumber = try probe(.number, "export.ppi", in: hosted.host)

        let qualityRect = rect(of: qualityNumber, in: hosted.host)
        let opacityRect = rect(of: opacityNumber, in: hosted.host)
        let ppiRect = rect(of: ppiNumber, in: hosted.host)

        XCTAssertEqual(qualityRect.width, 46, accuracy: 0.5)
        XCTAssertEqual(opacityRect.width, 46, accuracy: 0.5)
        XCTAssertEqual(ppiRect.width, 46, accuracy: 0.5)
        XCTAssertEqual(qualityRect.minX, opacityRect.minX, accuracy: 0.5)
        XCTAssertEqual(qualityRect.minX, ppiRect.minX, accuracy: 0.5)

        XCTAssertTrue(hasProbe(.number, "export.ppi", in: hosted.host))
        try assertTogglePresent("export.ppi.enabled", row: "export.ppi", in: hosted.host)
        XCTAssertFalse(hasProbe(.slider, "export.ppi", in: hosted.host))

        let qualitySlider = try probe(.slider, "export.quality", in: hosted.host)
        let opacitySlider = try probe(.slider, "export.watermark.opacity", in: hosted.host)
        XCTAssertEqual(qualitySlider.frame.width, 140, accuracy: 0.5)
        XCTAssertEqual(opacitySlider.frame.width, 140, accuracy: 0.5)
        XCTAssertEqual(rect(of: qualitySlider, in: hosted.host).minX,
                       rect(of: opacitySlider, in: hosted.host).minX, accuracy: 0.5)

        sheet.preset.sizingMode = .longEdge
        let longHosted = try host(model: sheet)
        try assertTogglePresent("export.size.noUpscale", row: "export.size.longEdge",
                                in: longHosted.host)
        XCTAssertFalse(hasProbe(.slider, "export.size.longEdge", in: longHosted.host))
        let longNumber = try probe(.number, "export.size.longEdge", in: longHosted.host)
        let longRect = rect(of: longNumber, in: longHosted.host)

        sheet.preset.sizingMode = .percent
        let percentHosted = try host(model: sheet)
        XCTAssertFalse(hasProbe(.slider, "export.size.percent", in: percentHosted.host))
        let percentNumber = try probe(.number, "export.size.percent", in: percentHosted.host)
        let percentRect = rect(of: percentNumber, in: percentHosted.host)

        XCTAssertEqual(longRect.width, 46, accuracy: 0.5)
        XCTAssertEqual(percentRect.width, 46, accuracy: 0.5)
        XCTAssertEqual(longRect.minX, qualityRect.minX, accuracy: 0.5)
        XCTAssertEqual(percentRect.minX, qualityRect.minX, accuracy: 0.5)
    }

    /// The unit column sits at the same x on every row that has one; 质量 reserves it but draws
    /// nothing, so 217's "质量无单位探针" assertion still holds.
    func testUnitColumnIsTheSameOnEveryRowWithAUnit() throws {
        let sheet = model()
        let hosted = try host(model: sheet)

        let ppiUnit = try probe(.unit, "export.ppi", in: hosted.host)
        let opacityUnit = try probe(.unit, "export.watermark.opacity", in: hosted.host)
        let ppiUnitX = rect(of: ppiUnit, in: hosted.host).minX
        let opacityUnitX = rect(of: opacityUnit, in: hosted.host).minX
        XCTAssertEqual(opacityUnitX, ppiUnitX, accuracy: 0.5)

        sheet.preset.sizingMode = .percent
        let percentHosted = try host(model: sheet)
        let percentUnit = try probe(.unit, "export.size.percent", in: percentHosted.host)
        XCTAssertEqual(rect(of: percentUnit, in: percentHosted.host).minX,
                       ppiUnitX, accuracy: 0.5)
        XCTAssertEqual(rect(of: percentUnit, in: percentHosted.host).minX,
                       opacityUnitX, accuracy: 0.5)

        XCTAssertFalse(hasProbe(.unit, "export.quality", in: hosted.host), "质量没有单位")
    }

    /// The audit table's source: every numeric row's number / slider / unit rect.
    func testAuditPrint() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        printRow("export.quality", in: hosted.host)
        printRow("export.watermark.opacity", in: hosted.host)
        printRow("export.ppi", in: hosted.host)

        sheet.preset.sizingMode = .longEdge
        let longHosted = try host(model: sheet)
        printRow("export.size.longEdge", in: longHosted.host)

        sheet.preset.sizingMode = .percent
        let percentHosted = try host(model: sheet)
        printRow("export.size.percent", in: percentHosted.host)
    }

    private func printRow(_ axID: String, in host: NSView) {
        let numberRect: NSRect? = {
            if let probe = descendants(of: host).compactMap({ $0 as? ExportSliderRowProbe })
                .first(where: { $0.kind == .number && $0.rowID == axID }) {
                return rect(of: probe, in: host)
            }
            if let field = descendants(of: host).compactMap({ $0 as? NumberTextField })
                .first(where: { $0.accessibilityIdentifier() == axID }) {
                return rect(of: field, in: host)
            }
            return nil
        }()
        let sliderRect = descendants(of: host).compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .slider && $0.rowID == axID }
            .map { rect(of: $0, in: host) }
        let unitRect = descendants(of: host).compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .unit && $0.rowID == axID }
            .map { rect(of: $0, in: host) }

        print("243 · \(axID) · number x=\(fmt(numberRect?.minX)) w=\(fmt(numberRect?.width))"
              + " · slider x=\(fmt(sliderRect?.minX)) w=\(fmt(sliderRect?.width))"
              + " · unit x=\(fmt(unitRect?.minX)) w=\(fmt(unitRect?.width))")
    }

    private func fmt(_ value: CGFloat?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }
}
