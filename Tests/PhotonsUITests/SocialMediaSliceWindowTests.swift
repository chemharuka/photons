import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

@MainActor
final class SocialMediaSliceWindowTests: XCTestCase {
    func testMenuRequiresASelection() {
        _ = NSApplication.shared
        let editor = EditorWindowController()
        if let window = editor.window { TestWindows.adopt(window) }
        let item = NSMenuItem(title: "社交媒体切片输出", action: #selector(EditorWindowController.socialMediaSlicesAction(_:)), keyEquivalent: "")
        XCTAssertFalse(editor.validateMenuItem(item))
    }

    func testRasterOrientationAndEditsUseTheExportGraph() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photons-slice-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotated.jpg")
        let image = fixture(width: 240, height: 120)
        let upright = directory.appendingPathComponent("upright.jpg")
        try Exporter.write(image, to: upright, options: .init(quality: 1))
        let uprightFrame = try UIExportRenderer.render(item: .init(id: "upright", name: "upright", edit: .neutral, sourceURL: upright),
            preset: ExportPreset(format: .jpeg, longEdge: 240, colorSpace: .sRGB, hdr: HDRExport()), native: nil)
        let top = (20 * uprightFrame.width + 20) * 4
        let bottom = ((uprightFrame.height - 20) * uprightFrame.width + 20) * 4
        XCTAssertGreaterThan(uprightFrame.rgba[top], uprightFrame.rgba[top+2], "The sky/top of a raster must stay at the top")
        XCTAssertGreaterThan(uprightFrame.rgba[bottom+2], uprightFrame.rgba[bottom])
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try Exporter.cgImage(image, bitDepth: 8),
                                  [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertFalse(UIExportSource.isRAW(url))
        XCTAssertEqual(try UIExportSource.size(at: url), ImageSize(width: 120, height: 240))
        let decoded = try UIExportSource.decodeRaster(url, scale: 1)
        // Clockwise orientation turns the original blue bottom into the left side.
        let left = (120 * 120 + 20) * 4, right = (120 * 120 + 100) * 4
        XCTAssertGreaterThan(decoded.rgba[left+2], decoded.rgba[left])
        XCTAssertGreaterThan(decoded.rgba[right], decoded.rgba[right+2])
        let preset = ExportPreset(format: .jpeg, longEdge: 100, colorSpace: .sRGB, hdr: HDRExport())
        let neutral = try UIExportRenderer.render(item: .init(id: "raster", name: "rotated", edit: .neutral, sourceURL: url),
                                                 preset: preset, native: nil)
        var edit = EditModel.neutral
        edit.geometry.crop = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = try UIExportRenderer.render(item: .init(id: "crop", name: "rotated", edit: edit, sourceURL: url),
                                                 preset: preset, native: nil)
        XCTAssertEqual(neutral.width, 50); XCTAssertEqual(neutral.height, 100)
        XCTAssertEqual(cropped.width, cropped.height)
        XCTAssertNotNil(neutral.linear)
    }

    func testHDRRasterInputRetainsHighlights() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("ISO gain maps require macOS 15") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photons-slice-hdr-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        var pixels = [Float16](repeating: 4, count: 120 * 80 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 1 }
        let linear = LinearPixels(width: 120, height: 80, rgba: pixels, primaries: .sRGB)
        let sdr = linear.displaySDR(bitDepth: 8, toneMap: .global)
        try GainMapHEIC.write(sdr: sdr, linear: linear, to: url,
                             options: .init(halfSize: false, quality: 1), format: .jpeg)
        let decoded = try UIExportSource.decodeRaster(url, scale: 1)
        XCTAssertGreaterThan(Float(decoded.rgba[0]), 2)
        let rendered = try UIExportRenderer.render(item: .init(id: "hdr", name: "hdr", edit: .neutral, sourceURL: url),
            preset: ExportPreset(format: .jpeg, longEdge: 120, colorSpace: .sRGB, hdr: HDRExport()), native: nil)
        XCTAssertGreaterThan(GainMapHEIC.peak(of: try XCTUnwrap(rendered.linear)), 2)
    }

    func testWindowLoadsSelectedPhotosKeepsPerPhotoFillAndRendersLayout() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photons-slice-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let synthetic = directory.appendingPathComponent("panorama.jpg")
        try Exporter.write(fixture(), to: synthetic, options: .init())
        let source = ProcessInfo.processInfo.environment["PHOTONS_SLICE_PHOTO"].map { URL(fileURLWithPath: $0) } ?? synthetic
        let items = [ExportItem(id: "first", name: "first", edit: .neutral, sourceURL: source),
                     ExportItem(id: "second", name: "second", edit: .neutral, sourceURL: synthetic)]
        let controller = SocialMediaSliceWindowController(items: items)
        let window = try XCTUnwrap(controller.window)
        TestWindows.adopt(window)
        defer { controller.close() }
        controller.model.settings.dynamicRange = .sdr
        TestWindows.show(window, key: true)
        let limit = Date().addingTimeInterval(40)
        while (controller.model.preparing || controller.model.previewLoading) && Date() < limit {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertFalse(controller.model.preparing)
        XCTAssertNotNil(controller.model.preview, controller.model.currentError ?? "preview missing")
        XCTAssertNotNil(controller.model.layout)
        controller.model.currentFill = 55
        controller.model.select(1)
        controller.model.currentFill = 60
        controller.model.select(0)
        XCTAssertEqual(controller.model.currentFill, 55)
        XCTAssertEqual(controller.model.fills["second"], 60)
        let content = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 1100, height: 820), NSSize(width: 880, height: 660)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(content.fittingSize.width, size.width + 1)
        }
        if let path = ProcessInfo.processInfo.environment["PHOTONS_SLICE_SCREENSHOT"] {
            window.setContentSize(NSSize(width: 1100, height: 820))
            let limit = Date().addingTimeInterval(20)
            while controller.model.previewLoading && Date() < limit { try await Task.sleep(nanoseconds: 30_000_000) }
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        // Exercise the same asynchronous command as the window's export button. The optional
        // fixture is read-only; both output modes always go into this test's temporary folder.
        controller.model.settings.width = 1800; controller.model.settings.height = 2400
        controller.model.clampFills()
        for mode in SliceDynamicRange.allCases where mode != .hdr || SliceDynamicRange.hdrAvailable {
            controller.model.settings.dynamicRange = mode
            controller.model.outputParent = directory.appendingPathComponent(mode.rawValue)
            controller.model.requestExport(currentOnly: true)
            XCTAssertTrue(controller.model.exporting)
            let exportLimit = Date().addingTimeInterval(60)
            while controller.model.exporting && Date() < exportLimit { try await Task.sleep(nanoseconds: 30_000_000) }
            XCTAssertFalse(controller.model.exporting)
            XCTAssertNil(controller.model.error)
            let output = try XCTUnwrap(controller.model.lastOutputs.first)
            let manifest = try JSONDecoder().decode(SliceManifest.self, from: Data(contentsOf: output.appendingPathComponent("slices.json")))
            XCTAssertEqual(manifest.settings.dynamicRange, mode)
            XCTAssertEqual(manifest.files.count, controller.model.layout?.count)
            XCTAssertEqual(manifest.hdr != nil, mode == .hdr)
            for name in manifest.files {
                XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path))
            }
        }
    }

    private func fixture(width: Int = 480, height: Int = 180) -> DisplayImage {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                pixels[o] = y < height / 2 ? 0.8 : 0.1
                pixels[o+1] = 0.2
                pixels[o+2] = y < height / 2 ? 0.1 : 0.8
            }
        }
        return DisplayImage(width: width, height: height, rgba: pixels, primaries: .sRGB, bitDepth: 8)
    }
}
