import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 250 — real-click acceptance for the export sheet's three checkbox/typing controls.
///
/// 243 proved `export.ppi.enabled` and `export.size.noUpscale` only by "the row's number probe
/// exists and the axID string is still in source" — a checkbox that was never operated. This file
/// operates them the way a user does, in a real `NSWindow`:
///
///   · The hosted `ExportSheetView` has **no `NSButton` leaf** (`descendants(of:).filter { $0 is
///     NSButton }` == 0): SwiftUI's `Toggle(.checkbox)` is not an AppKit control.
///   · `accessibilityHitTest` over a 6 pt sweep of the host returns only
///     `NSHostingView<ExportSheetView>` (`role=AXGroup`); no `export.*` node appears.
///   · The system AX tree does not work for our own process either:
///     `AXUIElementCreateApplication(getpid())` returns 1 node with an empty
///     `kAXIdentifierAttribute` under xctest (`AXIsProcessTrusted()` is true), so this is not a
///     permissions problem. That is the measured boundary, not a shortcut.
///
/// The working mechanism is a **zero-hit `NSView` probe** on the `Toggle` itself (the same
/// `ExportSliderRowProbe` pattern 217/243 use). It is a locator only: `hitTest` returns nil, it draws
/// nothing and adds no layout width (`background` takes no space). Its frame is the checkbox's real
/// frame, so a real `leftMouseDown`/`leftMouseUp` at `minX + 7` (the box end, **not** the centre,
/// which lands on the label text and does nothing) flips the same binding the app uses.
///
/// Convention: `export.ppi.enabled` and `export.size.noUpscale` are now **functional** proof — the
/// probe is mounted on the exact `Toggle` that carries `.accessibilityIdentifier(axID)`, its
/// `rowID` is that same axID, and clicking the probe's frame changes `model.preset`.
@MainActor
final class ExportSheetCheckboxClickTests: XCTestCase {

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
            .appendingPathComponent("photons-export-click-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - hosting (same shape as ExportSliderRowUnificationTests)

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
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        TestWindows.show(window, key: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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

    private func toggleProbe(_ rowID: String, in host: NSView) throws -> ExportSliderRowProbe {
        let match = descendants(of: host)
            .compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .toggle && $0.rowID == rowID }
        return try XCTUnwrap(match, "no toggle probe for \(rowID)")
    }

    private func numberField(_ axID: String, in host: NSView) throws -> NumberTextField {
        let fields = descendants(of: host).compactMap { $0 as? NumberTextField }
        return try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == axID },
                             "no NumberTextField for \(axID)")
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A real event pair at `probe.minX + 7`, in **window** coordinates. The box end is a measured
    /// rule: the centre of `export.ppi.enabled` falls on the "PPI" text and does not toggle.
    private func click(_ probe: ExportSliderRowProbe, in window: NSWindow) {
        let location = probe.convert(NSPoint(x: probe.bounds.minX + 7, y: probe.bounds.midY),
                                     to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                      modifierFlags: [], timestamp: timestamp,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                    modifierFlags: [], timestamp: timestamp + 0.15,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)
        guard let down, let up else { return XCTFail("could not build the click events") }
        window.sendEvent(down)
        pump(0.15)
        window.sendEvent(up)
        pump(0.2)
    }

    /// Typing goes through the real field editor. `field.stringValue = "50"` + `sendAction` was
    /// measured to write `nil` (it bypasses the formatter), so it is not an option.
    private func type(_ text: String, into field: NumberTextField, in window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field), "field must accept first responder")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView,
                                   "no field editor for \(field.accessibilityIdentifier() ?? "?")")
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        pump(0.2)
    }

    // MARK: - fixtures / readback

    private func image(width: Int = 64, height: Int = 48) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                rgba[o] = Float16(Double(x) / Double(width))
                rgba[o + 1] = Float16(Double(y) / Double(height))
                rgba[o + 2] = 0.5
                rgba[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 8)
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raw = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        if let d = raw as? [CFString: Any] { return d }
        let d = raw as! [String: Any]
        var out: [CFString: Any] = [:]
        for (key, value) in d { out[key as CFString] = value }
        return out
    }

    private func tiff(_ url: URL) throws -> [CFString: Any] {
        let value = try properties(of: url)[kCGImagePropertyTIFFDictionary]
        if let d = value as? [CFString: Any] { return d }
        if let d = value as? [String: Any] {
            var out: [CFString: Any] = [:]
            for (key, value) in d { out[key as CFString] = value }
            return out
        }
        return [:]
    }

    /// The production metadata path (`BatchExport.swift:357`): `preset.effectivePPI`, never a
    /// hand-recomputed clamp.
    private func export(_ format: ExportFormat, from preset: ExportPreset, name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let metadata = ExportMetadataContext(level: .none, author: "Ada", copyright: "© 2026 Ada",
                                             ppi: preset.effectivePPI)
        try Exporter.write(image(), to: url, options: preset.exportOptions, metadata: metadata)
        return url
    }

    // MARK: - 1. PPI checkbox

    func testThePPICheckboxIsClickedInARealWindowAndClearsTheTag() throws {
        let sheet = model()
        var preset = sheet.preset
        preset.ppi = 240
        sheet.preset = preset

        let hosted = try host(model: sheet)
        let probe = try toggleProbe("export.ppi.enabled", in: hosted.host)
        let rect = probe.convert(probe.bounds, to: nil)
        // 322 —— 框宽跟着自己的字走（302 的 34 装不下「PPI」的 39，界面上是「PP…」）。
        XCTAssertEqual(rect.width, ExportRowGrid.toggleBoxWidth(for: "PPI"), accuracy: 1.0)
        XCTAssertLessThan(rect.minX + 7, rect.maxX, "点击点仍在盒子里")
        XCTAssertEqual(sheet.preset.ppi, 240)

        click(probe, in: hosted.window)
        let afterOff = sheet.preset.ppi
        XCTAssertNil(afterOff, "clicking the PPI box must clear the tag")

        hosted.host.layoutSubtreeIfNeeded()
        pump(0.1)
        let probeAgain = try toggleProbe("export.ppi.enabled", in: hosted.host)
        click(probeAgain, in: hosted.window)
        let afterOn = sheet.preset.ppi
        XCTAssertEqual(afterOn, 240, "clicking it again restores 240")

        print(String(format: "250 ppi 240 → %@ → %@（真实点击，rect %.1f,%.1f %.1f×%.1f）",
                     afterOff.map(String.init) ?? "nil", afterOn.map(String.init) ?? "nil",
                     rect.minX, rect.minY, rect.width, rect.height))
    }

    // MARK: - 2. PPI off really writes no resolution tag; 300 is written

    func testTheTurningOffPPIReallyWritesNoResolutionTag() throws {
        let sheet = model()
        let png = ExportPreset(name: "PNG", format: .png, quality: 0.9, bitDepth: 8,
                               colorSpace: .sRGB, hdr: nil, sizingMode: .none, ppi: 240)
        sheet.preset = png

        let hosted = try host(model: sheet)
        let probe = try toggleProbe("export.ppi.enabled", in: hosted.host)
        click(probe, in: hosted.window)
        XCTAssertNil(sheet.preset.ppi)

        let offPNG = try export(.png, from: sheet.preset, name: "off-ppi.png")
        let offPNGProperties = try properties(of: offPNG)
        XCTAssertNil(offPNGProperties[kCGImagePropertyDPIWidth],
                     "PPI off must write no PNG DPI width")
        XCTAssertNil(offPNGProperties[kCGImagePropertyDPIHeight],
                     "PPI off must write no PNG DPI height")

        // JPEG uses the same click-derived preset, just a container that stores resolution in TIFF.
        sheet.preset.format = .jpeg
        let offJPEG = try export(.jpeg, from: sheet.preset, name: "off-ppi.jpg")
        let offJPEGTags = try tiff(offJPEG)
        XCTAssertNil(offJPEGTags[kCGImagePropertyTIFFXResolution],
                     "PPI off must write no JPEG XResolution")

        // Turn it back on, then type 300 through the real field editor.
        let probeAgain = try toggleProbe("export.ppi.enabled", in: hosted.host)
        click(probeAgain, in: hosted.window)
        XCTAssertEqual(sheet.preset.ppi, 240)

        sheet.preset.format = .png
        hosted.host.layoutSubtreeIfNeeded()
        pump(0.3)
        let field = try numberField("export.ppi", in: hosted.host)
        try type("300", into: field, in: hosted.window)
        XCTAssertEqual(sheet.preset.ppi, 300)

        let onPNG = try export(.png, from: sheet.preset, name: "on-ppi-300.png")
        let onPNGProperties = try properties(of: onPNG)
        XCTAssertEqual(onPNGProperties[kCGImagePropertyDPIWidth] as? Double, 300)

        print("250 关闭 PPI 导出：PNG DPI=\(offPNGProperties[kCGImagePropertyDPIWidth] ?? "nil")"
              + " · JPEG XResolution=\(offJPEGTags[kCGImagePropertyTIFFXResolution] ?? "nil")"
              + " · 重新打开并输入 300 → PNG DPI=\(onPNGProperties[kCGImagePropertyDPIWidth] ?? "nil")")
    }

    // MARK: - 3. 长边 不扩大 checkbox

    func testTheLongEdgeCheckboxIsClickedAndTheBatchStopsUpscaling() throws {
        let sheet = model()
        var preset = sheet.preset
        preset.sizingMode = .longEdge
        preset.longEdge = 2000
        preset.noUpscale = true
        sheet.preset = preset

        let hosted = try host(model: sheet)
        XCTAssertTrue(sheet.preset.noUpscale)

        let probe = try toggleProbe("export.size.noUpscale", in: hosted.host)
        let rect = probe.convert(probe.bounds, to: nil)
        click(probe, in: hosted.window)
        let afterOff = sheet.preset.noUpscale
        XCTAssertFalse(afterOff, "clicking 不扩大 must allow upscaling")

        let content = ImageSize(width: 320, height: 240)
        let offSize = ExportSizing.outputSize(
            content: content, scale: sheet.preset.renderScale(content: content))
        XCTAssertEqual(offSize, ImageSize(width: 2000, height: 1500))

        hosted.host.layoutSubtreeIfNeeded()
        pump(0.1)
        let probeAgain = try toggleProbe("export.size.noUpscale", in: hosted.host)
        click(probeAgain, in: hosted.window)
        let afterOn = sheet.preset.noUpscale
        XCTAssertTrue(afterOn, "clicking it again caps the long edge at the source")

        let onSize = ExportSizing.outputSize(
            content: content, scale: sheet.preset.renderScale(content: content))
        XCTAssertEqual(onSize, ImageSize(width: 320, height: 240))

        print("250 不扩大 \(afterOn) ← 点击 → \(afterOff)；320×240 @ 长边 2000："
              + "开 \(onSize.width)×\(onSize.height) · 关 \(offSize.width)×\(offSize.height)"
              + String(format: "（真实点击，rect %.1f,%.1f %.1f×%.1f）",
                       rect.minX, rect.minY, rect.width, rect.height))
    }

    // MARK: - 4. 百分比行打字

    func testThePercentRowTakesTypedInput() throws {
        let sheet = model()
        var preset = sheet.preset
        preset.sizingMode = .percent
        preset.percent = 100
        sheet.preset = preset

        let hosted = try host(model: sheet)
        let field = try numberField("export.size.percent", in: hosted.host)
        try type("50", into: field, in: hosted.window)
        XCTAssertEqual(sheet.preset.percent, 50)

        let content = ImageSize(width: 320, height: 240)
        let size = ExportSizing.outputSize(
            content: content, scale: sheet.preset.renderScale(content: content))
        XCTAssertEqual(size, ImageSize(width: 160, height: 120))
        print("250 长边百分比 100 → \(sheet.preset.percent ?? -1)；320×240 @ 50 % ⇒ \(size.width)×\(size.height)")
    }
}
