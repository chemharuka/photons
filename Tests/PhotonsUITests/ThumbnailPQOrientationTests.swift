import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 316 — **the cell's texture, not the JPEG, must be upright** for *both* payload families.
///
/// 313 made the Core Image branch write at all (`.shaderWrite`), and that branch then showed the
/// picture upside down: `CIContext.render(_:to: MTLTexture)` hands back the image with its **bottom**
/// row first (Core Image is y-up, `getBytes`/`texture.replace` count rows from the top), while the
/// 16-bit fast path uploads the `CGImage` verbatim — row 0 = top. Both feed the same texture and the
/// same shader UVs, so only the CI path could be flipped, and only once it stopped being all-black.
///
/// 241 already recorded the same convention one layer up (`ThumbnailHDRDecoder.makeCGImage` reverses
/// the rows after `render(to:)`). This file is the second one, at the surface itself.
///
/// The fixture is deliberately **top-heavy**: the top quarter is bright, the rest is dark. A row band
/// comparison cannot be satisfied by a uniform image, and a double flip is caught by the correlation
/// against the source (item 3), not by a single band.
final class ThumbnailPQOrientationTests: XCTestCase {

    private let display = ImageSize(width: 300, height: 200)

    // MARK: - fixture

    /// 480×320 (aspect 1.5, the same as the 300×200 read-back, so the aspect-fill window is the unit
    /// rectangle): top quarter at 1.5× white, the rest at 0.02. Nothing about JPEG's 8×8 DCT can move
    /// a 80-row band across the 240-row boundary.
    private func stacked(width: Int = 480, height: Int = 320) -> LinearPixels {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v: Float = y < height / 4 ? 1.5 : 0.02
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v)
                rgba[i + 3] = 1
            }
        }
        return LinearPixels(width: width, height: height, rgba: rgba, primaries: .displayP3)
    }

    /// The 16-bit extended-linear P3 payload: `bitsPerComponent == 16 && bitsPerPixel == 64`, i.e. the
    /// `texture.replace` fast path.
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

    // MARK: - the same harness 313 uses: real window, real CAMetalLayer, getBytes

    @MainActor
    private func withWindow(_ body: (NSWindow) throws -> Void) throws {
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        defer { window.close() }
        try body(window)
    }

    /// Luminance of every pixel of the cell's rendered texture, **row 0 = top of the drawable**.
    @MainActor
    private func readback(_ image: CGImage, in window: NSWindow) throws -> (w: Int, h: Int, px: [Float]) {
        let view = ThumbnailEDRView(cornerRadius: 0)
        view.frame = NSRect(x: 0, y: 0, width: display.width, height: display.height)
        window.contentView?.addSubview(view)
        view.image = image
        view.layoutSubtreeIfNeeded()

        let texture = try XCTUnwrap(view.renderForTesting(width: display.width, height: display.height),
                                    "the cell produced no texture")
        let w = texture.width, h = texture.height
        var out = [UInt16](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 8,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            px[i] = Float(Float16(bitPattern: out[i * 4]))
        }
        view.removeFromSuperview()
        return (w, h, px)
    }

    private struct Bands { var top: Float; var bottom: Float; var ratio: Float }

    /// Mean of the top and bottom eighth of the texture — two bands that never touch, so an image
    /// that is bright at the top and dark at the bottom cannot pass by accident.
    private func bands(_ w: Int, _ h: Int, _ px: [Float]) -> Bands {
        let n = max(1, h / 8)
        var top: Float = 0, bottom: Float = 0
        for y in 0..<n {
            for x in 0..<w {
                top += px[y * w + x]
                bottom += px[(h - 1 - y) * w + x]
            }
        }
        let count = Float(n * w)
        top /= count; bottom /= count
        return Bands(top: top, bottom: bottom, ratio: bottom > 0 ? top / bottom : .infinity)
    }

    private func describe(_ label: String, _ w: Int, _ h: Int, _ px: [Float]) -> String {
        let b = bands(w, h, px)
        let row0 = px[0..<w].reduce(0, +) / Float(w)
        let rowN = px[(h - 1) * w..<(h * w)].reduce(0, +) / Float(w)
        return String(format: "316 %@ %d×%d: top band %.3f (row0 %.3f) · bottom band %.3f (row%d %.3f) · ratio %.1f×",
                      label, w, h, b.top, row0, b.bottom, h - 1, rowN, b.ratio)
    }

    // MARK: - 1. the two payload families through the same surface

    /// The reference path: a half-float `CGImage` uploaded with `replace`. Row 0 of the `CGImage` is
    /// row 0 of the texture, so the bright quarter stays on top. This is also the guard that the fix
    /// for the CI branch does not flip the path that always worked.
    @MainActor
    func testSixteenBitFastPathKeepsTheBrightQuarterOnTop() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let reference = try halfFloatImage(stacked())

        try withWindow { window in
            let cell = try readback(reference, in: window)
            print(describe("fast-path", cell.w, cell.h, cell.px))
            let b = bands(cell.w, cell.h, cell.px)
            XCTAssertGreaterThan(b.top, b.bottom * 3,
                                 "the replace upload must keep the bright quarter on top "
                                 + "(top \(b.top), bottom \(b.bottom))")
            XCTAssertGreaterThan(b.top, 0.5, "the bright quarter must survive the upload")
            XCTAssertLessThan(b.bottom, 0.2, "the dark three quarters must stay dark")
        }
    }

    /// **The defect.** The same photograph as an 8-bit Display P3 PQ JPEG — the 308 payload — decoded
    /// through the shipped `decodeJPEG` and uploaded by `CIContext.render(_:to:)`. Before 316 this
    /// cell read bright at the bottom; the assertion below is the one that went red.
    @MainActor
    func testPQJPEGCoreImageBranchKeepsTheBrightQuarterOnTop() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let jpeg = try XCTUnwrap(ThumbnailPQJPEG.encode(linear: stacked(), longEdge: 480, quality: 0.75),
                                 "the 308 encoder refused the fixture")
        let decoded = try XCTUnwrap(ThumbnailProvider.decodeJPEG(jpeg, display: display))
        XCTAssertEqual(decoded.bitsPerComponent, 8,
                       "this must be the 8-bit PQ payload the Core Image branch exists for")

        try withWindow { window in
            let cell = try readback(decoded, in: window)
            print(describe("CI-branch", cell.w, cell.h, cell.px))
            let b = bands(cell.w, cell.h, cell.px)
            XCTAssertGreaterThan(b.top, b.bottom * 3,
                                 "the CI upload must keep the bright quarter on top, i.e. the same "
                                 + "row order as the replace upload (top \(b.top), bottom \(b.bottom))")
            XCTAssertGreaterThan(b.top, 0.5, "the bright quarter must survive the CI render")
            XCTAssertLessThan(b.bottom, 0.2, "the dark three quarters must stay dark")
        }
    }

    // MARK: - 2. same direction as the source, block by block

    /// A band ratio alone cannot separate "correct" from "correct twice" (a double flip is upright
    /// again); this compares the read-back with the source in the same orientation, block by block,
    /// and requires the **unflipped** comparison to be the one that wins. A flipped texture scores
    /// exactly the same against a vertically symmetric fixture, which is why the fixture is top-heavy
    /// *and* the source correlation is measured, not just the ratio.
    @MainActor
    func testPQJPEGReadbackAgreesWithTheSourceInTheSameDirection() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else { throw XCTSkip("no Metal device") }
        let source = stacked()
        let jpeg = try XCTUnwrap(ThumbnailPQJPEG.encode(linear: source, longEdge: 480, quality: 0.75))
        let decoded = try XCTUnwrap(ThumbnailProvider.decodeJPEG(jpeg, display: display))

        try withWindow { window in
            let cell = try readback(decoded, in: window)
            let upright = correlation(readback: cell, source: source)
            let flipped = correlation(readback: (cell.w, cell.h, flipRows(cell.w, cell.h, cell.px)),
                                      source: source)
            print(String(format: "316 correlation: upright %.4f · vertically flipped %.4f", upright, flipped))
            XCTAssertGreaterThan(upright, 0.9, "the cell must correlate with its source")
            XCTAssertGreaterThan(upright, flipped + 0.2,
                                 "flipping the read-back must lose the match (upright \(upright), "
                                 + "flipped \(flipped)) — otherwise the cell is not the source's way up")
        }
    }

    private func flipRows(_ w: Int, _ h: Int, _ px: [Float]) -> [Float] {
        var out = px
        for y in 0..<(h / 2) {
            for x in 0..<w {
                out[y * w + x] = px[(h - 1 - y) * w + x]
                out[(h - 1 - y) * w + x] = px[y * w + x]
            }
        }
        return out
    }

    /// 6×4 block means of the cell vs the same blocks of the source linear fixture, Pearson.
    private func correlation(readback cell: (w: Int, h: Int, px: [Float]), source: LinearPixels) -> Double {
        let bx = 6, by = 4
        var a: [Double] = [], b: [Double] = []
        for byi in 0..<by {
            for bxi in 0..<bx {
                var sa = 0.0, sb = 0.0
                var n = 0
                for y in (byi * cell.h / by)..<((byi + 1) * cell.h / by) {
                    for x in (bxi * cell.w / bx)..<((bxi + 1) * cell.w / bx) {
                        let sx = min(source.width - 1, Int((Double(x) + 0.5) * Double(source.width) / Double(cell.w)))
                        let sy = min(source.height - 1, Int((Double(y) + 0.5) * Double(source.height) / Double(cell.h)))
                        sa += Double(cell.px[y * cell.w + x])
                        sb += Double(Float(source.rgba[(sy * source.width + sx) * 4]))
                        n += 1
                    }
                }
                guard n > 0 else { continue }
                a.append(sa / Double(n)); b.append(sb / Double(n))
            }
        }
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da.squareRoot() * db.squareRoot()) : 0
    }
}
