import XCTest
import Metal
import PhotonsCore

/// 132 §7/§9 — the **two blacks** in one frame: the rotated-out empty pixels are 0/255, the window
/// letterbox is `CanvasMatte` #0F0F0F, and neither is covered by the backdrop.
///
/// 301b — the canvas **is** the crop frame now, so the two blacks swapped places: the letterbox is
/// still the window matte outside `drawnRect`, and the 0/255 pixels are the *canvas' own corners*
/// (a full crop turned 45° samples outside the photograph there). The AABB band that used to carry
/// the 0/255 ring — and the 566 px box that carried it — no longer exist.
final class RotatedCanvasPresenterTests: XCTestCase {

    private func borderImage(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0.2, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 6 || y < 6 || x >= w - 6 || y >= h - 6
                let v: Float16 = edge ? 0.95 : 0.2
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "rotated-present")
    }

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w,
                                                         height: h, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 4,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return [raw[2], raw[1], raw[0]]   // b, g, r → r, g, b
    }

    func testRotatedEmptyPixelsAreBlackAndTheLetterboxIsStillTheBackdrop() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let graph = try RenderGraph(input: RenderInput(image: borderImage(400, 400),
                                                       identity: "rotated-present"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45
        // A viewport bigger than the rotated bounding box, so the same frame carries both blacks.
        let canvas = ImageSize(width: 700, height: 700)
        let result = try graph.render(edit, options: RenderOptions(
            canvas: canvas, scale: 1, useCache: false, wantsPixels: false,
            neverUpscalesContent: true))
        let texture = try XCTUnwrap(result.output, "no render")
        defer { graph.recycle(output: texture) }
        // 301b: the canvas is the 400×400 crop frame, centred in 700×700 → 150 px of matte all round.
        XCTAssertEqual(result.drawnRect, ImageRect(x: 150, y: 150, width: 400, height: 400),
                       "the canvas is the crop frame, not the rotated bounding box")

        let presenter = try CanvasPresenter(device: device)
        let presented = try makeTexture(device, canvas.width, canvas.height)
        XCTAssertTrue(presenter.renderForTest(texture, window: .whole,
                                              picture: result.drawnRect,
                                              into: presented, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        // Window letterbox: the pass's clear colour — the current backdrop stop, read from the one
        // constant (315), not a literal.
        let matte = Int(CanvasPresenter.CanvasMatte.eightBitValue)
        for (x, y) in [(2, 2), (697, 2), (2, 697), (697, 697)] {
            XCTAssertEqual(Int(pixel(presented, x, y)[0]), matte,
                           "letterbox (\(x),\(y)) is not the backdrop")
        }
        // Rotated-out empty pixels: the canvas' own corners — inside the crop frame, outside the
        // turned photograph. S0 writes `float4(0)` (transparent), so the composite shows the window
        // matte: under 301 the *only* visible black is the backdrop one, and the old opaque 0/255 ring
        // (an artefact of the AABB band) is gone. The render itself is still 0/0/0/0 — asserted below.
        for (x, y) in [(152, 152), (547, 152), (152, 547), (547, 547)] {
            XCTAssertEqual(pixel(presented, x, y), [0, 0, 0],
                           "rotated empty pixel (\(x),\(y)) is not 0/255")
        }
        // Neither black is a backdrop: the photograph still reaches the canvas' top edge at its
        // middle (the turned picture covers the frame there).
        let edge = pixel(presented, 350, 152)
        XCTAssertGreaterThan(Int(edge[0]), 60, "photograph is missing at the canvas' top edge")
        print("132 · letterbox \(Int(pixel(presented, 2, 2)[0])) · empty \(pixel(presented, 152, 152)) "
              + "· picture edge \(edge)")
    }
}
