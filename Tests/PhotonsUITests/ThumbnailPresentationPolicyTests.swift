import XCTest
import AppKit
import Metal
import QuartzCore
@testable import PhotonsUI

/// Layout must not redraw a thumbnail that has not changed.
///
/// **The HDR half of this test went away with the feature.** The PR added an EDR/"HDR preview"
/// switch to the thumbnail pipeline (`ThumbnailMetalSurface.applyDynamicRange()` plus an `hdr`
/// uniform in the fragment shader that clipped the SDR path). The user's ruling is that the HDR
/// button does not merge, so that whole line was rolled back: the pipeline passes the sampled RGB
/// straight through again, exactly as on `main`. The three assertions that pinned the switch
/// (`pixel() == 2` / `== 1` / `== 2`, and `wantsExtendedDynamicRangeContent == false`) described a
/// behaviour that no longer exists, so they were removed with it — not relaxed, not re-baselined.
/// That is also why this test is renamed: it no longer claims to cover an HDR switch.
///
/// What **is kept** is the other half, which guards a change the user did approve (the thumbnail
/// speed-up): `ThumbnailMetalSurface.layout` skips the draw when the drawable size and the bitmap
/// are unchanged. That is what stops AppKit's frequent re-layout of cells (selection, scrolling,
/// sidebar updates) from re-submitting the same frame over and over.
@MainActor
final class ThumbnailPresentationPolicyTests: XCTestCase {
    func testUnchangedLayoutDoesNotRedrawAnAlreadyPresentedImage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
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

        // Twenty no-op layouts must not submit a single extra GPU frame.
        for _ in 0..<20 { view.needsLayout = true; view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(view.presentedFramesForTesting, initial,
            "unchanged layout must submit zero additional GPU frames")

        // A real size change **must** still redraw: the guard is about no-op layouts only.
        view.setFrameSize(NSSize(width: 180, height: 180))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.presentedFramesForTesting, initial,
            "a changed drawable size must still redraw")
    }

    /// The rolled-back HDR switch must not come back: the thumbnail layer is unconditionally
    /// EDR-capable (EDR 1.0 = reference white, no tone map) and the render is a pass-through.
    func testThumbnailPipelineKeepsNoHDRPreviewSwitch() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/ThumbnailMetal.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("hdrPreview"),
                       "HDR 预览开关不合并：缩略图管线里不许再有 hdrPreview")
        XCTAssertFalse(text.contains("applyDynamicRange"),
                       "HDR 预览开关不合并：不许再按偏好切换 EDR 动态范围")
    }
}
