import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 313 — **the cell's own pixels, not the file's.**
///
/// 308 replaced the grid's payload with an 8-bit Display P3 **PQ JPEG**, which is not the
/// half-float bitmap `ThumbnailMetalSurface` uploads directly: it takes the Core Image fallback,
/// `CIContext.render(_:to: texture)`. That fallback had never been exercised by a shipped path
/// (`decodeHD` always produced a ready-made 16-bit bitmap), and it was dead: the texture was
/// declared `.shaderRead` only, Core Image's Metal backend writes through **compute**
/// (`.shaderWrite`), and a texture without that usage is left untouched — no error, no assert,
/// no drawable complaint, just zeros. Every cell in the grid and every filmstrip cell drew black.
///
/// 308's acceptance measured the *file* (bytes, EDR peak, decode time, banding) and never read a
/// pixel back off a cell, so nothing between "the JPEG is correct" and "the screen is black" was
/// observed. These tests close that hole at the level the user complained about: a real window, a
/// real `CAMetalLayer`, the cell's `rgba16Float` texture, `getBytes`.
///
/// The reference is the **same photograph** through the path that always worked — the 16-bit
/// extended-linear P3 bitmap uploaded with `replace` — so the assertion is parity between the two
/// payload families (≤ 5 %), not a threshold picked to pass.
final class ThumbnailPQCellReadbackTests: XCTestCase {

    /// 640×427, a linear ramp 0.02 → 2.0 across the width: a large flat area at every level, one
    /// hard highlight well above SDR white (so PQ's headroom is in play), nothing that JPEG's 8×8
    /// DCT can turn into a mean shift.
    private func ramp(width: Int = 640, height: Int = 427) -> LinearPixels {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float(0.02 + 1.98 * Double(x) / Double(width - 1))
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v)
                rgba[i + 3] = 1
            }
        }
        return LinearPixels(width: width, height: height, rgba: rgba, primaries: .displayP3)
    }

    /// The pre-308 payload: the same linear pixels as a half-float CGImage. This is the
    /// `bitsPerComponent == 16 && bitsPerPixel == 64` fast path — the one that never went black.
    private func halfFloatImage(_ linear: LinearPixels) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let bytes = linear.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: linear.width, height: linear.height,
                                     bitsPerComponent: 16, bitsPerPixel: 64,
                                     bytesPerRow: linear.width * 8, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue:
                                         CGImageAlphaInfo.noneSkipLast.rawValue
                                         | CGBitmapInfo.floatComponents.rawValue
                                         | CGBitmapInfo.byteOrder16Little.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false,
                                     intent: .defaultIntent))
    }

    private struct Stats { var mean: Float; var peak: Float }

    private func readback(_ image: CGImage, size: ImageSize,
                          in window: NSWindow) throws -> Stats {
        let view = ThumbnailEDRView(cornerRadius: 0)
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.contentView?.addSubview(view)
        view.image = image
        view.layoutSubtreeIfNeeded()

        let texture = try XCTUnwrap(view.renderForTesting(width: size.width, height: size.height),
                                    "the cell produced no texture")
        var out = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        var sum: Float = 0, peak: Float = 0
        var n = 0
        for i in stride(from: 0, to: out.count - 3, by: 4) {
            for c in 0..<3 {
                let v = Float(Float16(bitPattern: out[i + c]))
                sum += v; peak = max(peak, v); n += 1
            }
        }
        view.removeFromSuperview()
        return Stats(mean: n == 0 ? 0 : sum / Float(n), peak: peak)
    }

    /// A real (headless, off-screen-able) window: the cell lives in a `CAMetalLayer` that is
    /// attached to a window, exactly like the grid's. `renderForTesting` reads that same texture
    /// back, so "the grid is black" is answerable without a screen recording.
    @MainActor
    private func withWindow(_ body: (NSWindow) throws -> Void) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        defer { window.close() }
        try body(window)
    }

    // MARK: - the defect

    /// **The regression itself.** The PQ JPEG reaches a cell as a non-black picture, at every size
    /// the three surfaces use: grid 326×242, filmstrip 180×120, browser list 68×68.
    @MainActor
    func testAGridCellShowsThePQJPEGInsteadOfBlack() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let linear = ramp()
        let jpeg = try XCTUnwrap(ThumbnailPQJPEG.encode(linear: linear, longEdge: 640, quality: 0.75),
                                "the 308 encoder refused the fixture")

        try withWindow { window in
            for size in [ImageSize(width: 326, height: 242),
                         ImageSize(width: 180, height: 120),
                         ImageSize(width: 68, height: 68)] {
                let decoded = try XCTUnwrap(ThumbnailProvider.decodeJPEG(jpeg, display: size))
                XCTAssertEqual(decoded.bitsPerComponent, 8,
                               "this must be the 8-bit PQ payload the CI fallback exists for")
                let cell = try readback(decoded, size: size, in: window)
                print("313 cell \(size.width)×\(size.height): mean \(cell.mean) peak \(cell.peak)")

                // The acceptance numbers: a grid of these is a picture, not a hole.
                XCTAssertGreaterThan(cell.mean, 0.02,
                                     "cell \(size.width)×\(size.height) reads \(cell.mean) — black")
                XCTAssertGreaterThan(cell.peak, 0.2,
                                     "cell \(size.width)×\(size.height) peaks at \(cell.peak)")
            }
        }
    }

    /// **Parity with the path that never broke.** The same photograph through the 16-bit
    /// extended-linear P3 bitmap (`replace` upload) and through the 8-bit PQ JPEG (Core Image
    /// fallback) must reach the cell within 5 % — brightness and headroom, not just "not zero".
    ///
    /// This is also the assertion that makes the fix impossible to fake: dropping `.shaderWrite`
    /// again puts the JPEG branch at 0.0 against a ~0.5 reference, i.e. 100 % off.
    @MainActor
    func testThePQJPEGCellMatchesTheHalfFloatReference() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let linear = ramp()
        let reference = try halfFloatImage(linear)
        let jpeg = try XCTUnwrap(ThumbnailPQJPEG.encode(linear: linear, longEdge: 640, quality: 0.75))
        let size = ImageSize(width: 326, height: 242)

        try withWindow { window in
            let ref = try readback(reference, size: size, in: window)
            let decoded = try XCTUnwrap(ThumbnailProvider.decodeJPEG(jpeg, display: size))
            let pq = try readback(decoded, size: size, in: window)
            print("313 parity: half-float mean \(ref.mean) peak \(ref.peak) · PQ mean \(pq.mean) peak \(pq.peak)")

            XCTAssertGreaterThan(ref.mean, 0.02, "the reference itself must be a picture")
            XCTAssertEqual(pq.mean, ref.mean, accuracy: ref.mean * 0.05,
                           "the PQ cell is \(pq.mean) against \(ref.mean): a brightness step")
            XCTAssertEqual(pq.peak, ref.peak, accuracy: ref.peak * 0.05,
                           "the PQ cell peaks at \(pq.peak) against \(ref.peak)")
        }
    }
}
