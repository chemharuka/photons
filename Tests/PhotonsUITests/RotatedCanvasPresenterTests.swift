import XCTest
import Metal
import PhotonsCore

/// 132 §7/§9 — the **two blacks** in one frame: the rotated-out empty pixels are 0/255, the window
/// letterbox is `CanvasMatte` #0F0F0F, and neither is covered by the backdrop.
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

    func testRotatedEmptyPixelsAreBlackAndTheLetterboxIsStill0F() throws {
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
        // 566×566 AABB centred in 700×700 → 67 px of matte on each side.
        XCTAssertEqual(result.drawnRect, ImageRect(x: 67, y: 67, width: 566, height: 566),
                       "the rotated canvas is not the centred bounding box")

        let presenter = try CanvasPresenter(device: device)
        let presented = try makeTexture(device, canvas.width, canvas.height)
        XCTAssertTrue(presenter.renderForTest(texture, window: .whole,
                                              picture: result.drawnRect,
                                              into: presented, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        // Window letterbox: the pass's clear colour, #0F0F0F.
        for (x, y) in [(2, 2), (697, 2), (2, 697), (697, 697)] {
            XCTAssertEqual(Int(pixel(presented, x, y)[0]), 15,
                           "letterbox (\(x),\(y)) is not #0F0F0F")
        }
        // Rotated-out empty pixels: inside the AABB, outside the rotated photograph. Pure black.
        for (x, y) in [(69, 69), (630, 69), (69, 630), (630, 630)] {
            XCTAssertEqual(pixel(presented, x, y), [0, 0, 0],
                           "rotated empty pixel (\(x),\(y)) is not 0/255")
        }
        // Neither black is a backdrop: the photograph's own edge is still there.
        let edge = pixel(presented, 350, 69)
        XCTAssertGreaterThan(Int(edge[0]), 150, "the picture's rotated top corner is missing")
        print("132 · letterbox \(Int(pixel(presented, 2, 2)[0])) · empty \(pixel(presented, 69, 69)) "
              + "· picture edge \(edge)")
    }
}
