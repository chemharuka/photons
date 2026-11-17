import XCTest
import AppKit
import CoreImage
import ImageIO
import Metal
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

final class PanoramaHDRTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func scene() -> CIImage {
        // CI coordinates: red at the top, blue at the bottom; neither is a neutral
        // sample, so this also catches accidentally retagging sRGB as Display P3.
        let red = CIImage(color: CIColor(red: 2, green: 0, blue: 0, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 32, width: 96, height: 32))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 0.5, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        return red.composited(over: blue)
    }

    func testExportBridgeKeepsHDRPrimariesOrientationAndSizing() throws {
        let preset = ExportPreset(format: .tiff, longEdge: 48, bitDepth: 16, colorSpace: .displayP3,
                                  hdrKind: .pq, sizingMode: .longEdge)
        let result = try PanoramaExportRenderer.render(scene: scene(), preset: preset)
        XCTAssertEqual(result.width, 48); XCTAssertEqual(result.height, 32)
        XCTAssertEqual(result.bitDepth, 16); XCTAssertEqual(result.primaries, .displayP3)
        let linear = try XCTUnwrap(result.linear)
        // sRGB red transformed to P3, rather than the unconverted (2, 0, 0).
        XCTAssertEqual(Float(linear.rgba[0]), 1.645, accuracy: 0.015)
        XCTAssertEqual(Float(linear.rgba[1]), 0.0664, accuracy: 0.01)
        XCTAssertLessThan(Float(linear.rgba[2]), 0.05)
        let bottom = (linear.width * (linear.height - 1)) * 4
        XCTAssertGreaterThan(Float(linear.rgba[bottom + 2]), 0.4)
        XCTAssertLessThan(Float(linear.rgba[bottom]), 0.01)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporter.write(result, to: url, options: preset.exportOptions)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(cg.bitsPerComponent, 16)
        XCTAssertEqual(cg.colorSpace?.name, CGColorSpace.displayP3_PQ)
        let roundTrip = try PanoramaExportRenderer.render(scene: CIImage(cgImage: cg), preset: ExportPreset(
            format: .tiff, bitDepth: 16, colorSpace: .displayP3, hdrKind: .pq))
        XCTAssertEqual(Float(try XCTUnwrap(roundTrip.linear).rgba[0]), 1.645, accuracy: 0.04)
    }

    @MainActor
    func testEDRSurfaceKeepsHighlightsAndFitsWholePanorama() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(scene(), from: scene().extent, format: .RGBAh, colorSpace: space))
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PanoramaHDRPreviewView(); window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        view.setImage(cg); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.surface.frame.width, 300, accuracy: 0.1)
        XCTAssertEqual(view.surface.frame.height, 200, accuracy: 0.1)
        XCTAssertEqual(view.surface.frame.minY, 50, accuracy: 0.1)
        let layer = try XCTUnwrap(view.surface.layer as? CAMetalLayer)
        XCTAssertEqual(layer.pixelFormat, CanvasPresenter.Storage.linear16.pixelFormat)
        XCTAssertEqual(layer.colorspace, CanvasPresenter.Storage.linear16.colorSpace)
        let texture = try XCTUnwrap(view.surface.renderForTesting(width: 96, height: 64))
        var pixels = [UInt16](repeating: 0, count: 96 * 64 * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 96 * 8, from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
        }
        XCTAssertEqual(Float(Float16(bitPattern: pixels[0])), 1.645, accuracy: 0.02)
        XCTAssertGreaterThan(Float(Float16(bitPattern: pixels[(63 * 96) * 4 + 2])), 0.4)
    }

    func testResizingHDRKeepsUnclippedLinearCompanion() throws {
        let pixel: [Float16] = [8, 2, 0.5, 1]
        let pixels = Array(repeating: pixel, count: 32).flatMap { $0 }
        let source = LinearPixels(width: 8, height: 4, rgba: pixels, primaries: .displayP3)
        let resized = DisplayResample.fitLongEdge(source.displaySDR(bitDepth: 16), to: 4)
        let linear = try XCTUnwrap(resized.linear)
        XCTAssertEqual(linear.width, 4); XCTAssertEqual(linear.height, 2)
        XCTAssertEqual(Float(linear.rgba[0]), 8, accuracy: 0.01)
        XCTAssertEqual(Float(linear.rgba[1]), 2, accuracy: 0.01)
        XCTAssertEqual(linear.primaries, .displayP3)
    }

    @MainActor
    func testSharedSheetUsesPanoramaRendererAndNativeDefaultGainMap() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("ISO gain map needs macOS 15") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ExportSheetModel(preset: ExportSheetModel.defaultPreset, outputDirectory: dir,
            presetStore: ExportPresetStore(directory: dir), draftStore: ExportSheetModelTests.MemoryDraftStore())
        model.preset.sizingMode = .percent; model.preset.percent = 50
        model.run(items: [ExportItem(id: "test", name: "panorama")]) { _, preset, _ in
            try PanoramaExportRenderer.render(scene: self.scene(), preset: preset)
        }
        for _ in 0..<300 where model.phase == .running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(model.phase, .finished)
        let outcome = try XCTUnwrap(model.report?.written.first, model.report?.failures.first?.error ?? "missing output")
        let url = try XCTUnwrap(outcome.fileURL)
        XCTAssertEqual(url.pathExtension, "heic")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 48, "percentage must be applied only once")
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 32)
        let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        XCTAssertNotNil(gainMap, "default native export must carry an HDR gain map")
        XCTAssertEqual(model.preset.colorSpace, .displayP3)
    }
}
