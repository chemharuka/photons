import XCTest
import AppKit
import Metal
import QuartzCore
@testable import PhotonsUI

@MainActor
final class ThumbnailPresentationPolicyTests: XCTestCase {
    func testHDRSwitchClipsOnlyDisplayAndLayoutDoesNotRedrawUnchangedImage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let old = ApplicationPreferences.shared.hdrPreview
        defer { ApplicationPreferences.shared.hdrPreview = old }
        ApplicationPreferences.shared.hdrPreview = true
        var pixels = [Float16](repeating: 2, count: 16 * 16 * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 1 }
        let bytes = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let image = try XCTUnwrap(CGImage(width: 16, height: 16, bitsPerComponent: 16,
            bitsPerPixel: 64, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, bitmapInfo: info,
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = ThumbnailEDRView(cornerRadius: 0)
        window.contentView = view
        window.orderFrontRegardless()
        view.image = image
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let initial = view.presentedFramesForTesting
        XCTAssertGreaterThan(initial, 0)
        for _ in 0..<20 { view.needsLayout = true; view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(view.presentedFramesForTesting, initial,
            "unchanged layout must submit zero additional GPU frames")

        func pixel() throws -> Float {
            let texture = try XCTUnwrap(view.renderForTesting(width: 16, height: 16))
            var out = [Float16](repeating: 0, count: 16 * 16 * 4)
            out.withUnsafeMutableBytes { buffer in
                texture.getBytes(buffer.baseAddress!, bytesPerRow: 128,
                    from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)
            }
            return Float(out[0])
        }
        XCTAssertEqual(try pixel(), 2, accuracy: 0.001)
        ApplicationPreferences.shared.hdrPreview = false
        XCTAssertFalse((view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent ?? true)
        XCTAssertEqual(try pixel(), 1, accuracy: 0.001)
        ApplicationPreferences.shared.hdrPreview = true
        XCTAssertEqual(try pixel(), 2, accuracy: 0.001, "switching previews must not modify source pixels")
        view.setFrameSize(NSSize(width: 180, height: 180))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.presentedFramesForTesting, initial)
    }
}
