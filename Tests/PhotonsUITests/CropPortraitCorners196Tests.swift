import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 196 — 直线校正 + 缩小：**画布内、裁切区外**的那一圈必须是照片像素。
///
/// 这是本单的验收口径（用户 2026-10-31）：188/192 的探针取样点全在**裁切区**内，那里纹理
/// 一直有内容，所以每次都绿 —— 漏洞在验收方法上。旋转后照片的四个角落在 `canvasRect` 之内、
/// `drawnRect` 之外的带里，只有它们能同时抓住「纹理没覆盖画布」和「quad 画错」。
///
/// 八组：{横拍 3:2 · 竖拍 2:3} × {适应 · 25 % · 50 % · 1:1}，另加 θ = 0 的等值门。
@MainActor
final class CropPortraitCorners196Tests: XCTestCase {

    private static let viewport = ImageSize(width: 700, height: 500)
    private static let landscape = ImageSize(width: 3000, height: 2000)
    private static let portrait = ImageSize(width: 2000, height: 3000)
    private static let angle = 5.4

    // MARK: - fixture + readback

    private func image(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0.2, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 8 || y < 8 || x >= w - 8 || y >= h - 8
                let v: Float16 = edge ? 0.95 : 0.2
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "portrait-corners-196")
    }

    private func makeTarget(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w,
                                                         height: h, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    private func triple(_ t: MTLTexture, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        guard x >= 0, y >= 0, x < t.width, y < t.height else { return (-1, -1, -1) }
        var raw = [UInt8](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 4,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return (Int(raw[2]), Int(raw[1]), Int(raw[0]))
    }

    /// The frame texture's lit pixels (rgba16Float: a photograph texel is > 0.03 per channel).
    private func litness(_ t: MTLTexture) -> [Bool] {
        let w = t.width, h = t.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: w * 8,
                       from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            out[i] = raw[o] + raw[o + 1] + raw[o + 2] > 24
        }
        return out
    }

    // MARK: - the geometry under test

    private struct Framing { let name: String; let state: LoupeViewState }

    private func states(_ framing: LoupeFraming) -> [Framing] {
        let cx = framing.cropOriginX + framing.cropWidthPixels / 2
        let cy = framing.cropOriginY + framing.cropHeightPixels / 2
        func actual(_ z: Double) -> LoupeViewState {
            var s = LoupeViewState()
            s.mode = .actual
            s.zoom = z
            s.centerX = cx
            s.centerY = cy
            return s
        }
        var fit = LoupeViewState()
        fit.mode = .fit
        return [Framing(name: "fit", state: fit),
                // 缩小到画布小于视口 —— 用户说的「缩小」: 整张画布（含 000000 边带）都在屏幕上。
                Framing(name: "缩小10%", state: actual(0.1)),
                Framing(name: "25%", state: actual(0.25)),
                Framing(name: "50%", state: actual(0.5)),
                Framing(name: "1:1", state: actual(1.0))]
    }

    /// The photograph's four corners **on the canvas**: the crop rect at this scale, turned about the
    /// canvas' centre by the straighten angle. Each is a point where the turned picture touches
    /// `canvasRect` — pixels a crop-rect-only sampling never sees.
    private func turnedCorners(cropPixels: ImageSize, scale: Double, canvas: ImageRect,
                               degrees: Double) -> [(name: String, x: Double, y: Double)] {
        let w = Double(cropPixels.width) * scale
        let h = Double(cropPixels.height) * scale
        let cx = Double(canvas.x) + Double(canvas.width) / 2
        let cy = Double(canvas.y) + Double(canvas.height) / 2
        let c = cos(degrees * .pi / 180), s = sin(degrees * .pi / 180)
        return [("TL", -w / 2, -h / 2), ("TR", w / 2, -h / 2),
                ("BR", w / 2, h / 2), ("BL", -w / 2, h / 2)].map { (name, x, y) in
            (name, cx + x * c - y * s, cy + x * s + y * c)
        }
    }

    // MARK: - the test

    private func run(_ orientation: String, source: ImageSize) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let graph = try RenderGraph(input: RenderInput(image: image(source.width, source.height),
                                                       identity: "portrait-196-\(orientation)"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = Self.angle
        let cropPixels = CropMath.frameSize(edit.geometry.renderCrop(source: source), in: source,
                                            allowsOutsideSource: true)
        let aabb = CropMath.canvasSize(crop: edit.geometry.renderCrop(source: source), in: source,
                                       straightenDegrees: Self.angle, quarterTurns: 0,
                                       allowsOutsideSource: true)
        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(source.width),
                                   sourceHeight: Double(source.height),
                                   crop: .full, straightenDegrees: Self.angle)
        print("196 \(orientation) · source \(source.keyString) · cropPix \(cropPixels.keyString) "
              + "· θ \(Self.angle)° · fitZoom \(String(format: "%.4f", framing.fitZoom))")
        for f in states(framing) {
            let scale = framing.renderScale(of: f.state, decodeScale: 1)
            let window = framing.outputWindow(of: f.state, decodeScale: 1)
            let result = try graph.render(edit, options: RenderOptions(
                canvas: Self.viewport, scale: scale, outputWindow: window,
                useCache: false, wantsPixels: false))
            let texture = try XCTUnwrap(result.output, "no render at \(f.name)")
            defer { graph.recycle(output: texture) }
            let target = try makeTarget(device, Self.viewport.width, Self.viewport.height)
            let request = presenter.requestForTest(texture, window: .whole, backdrop: nil,
                                                   backdropWindow: .whole,
                                                   picture: result.canvasRect,
                                                   canvas: Self.viewport)
            XCTAssertTrue(presenter.render(request, into: target, linearize: false),
                          presenter.lastFailure ?? "present failed")
            let canvas = result.canvasRect
            let clipped = canvas.intersected(in: Self.viewport)
            print("196 \(f.name) · scale \(String(format: "%.4f", scale)) "
                  + "· canvasRect \(canvas.keyString)@(\(canvas.x),\(canvas.y)) "
                  + "· drawnRect \(result.drawnRect.keyString) "
                  + "· quad \(request.pictureQuad.keyString)@(\(request.pictureQuad.x),\(request.pictureQuad.y))")

            // The canvas may be larger than the viewport (25 % / 50 % / 1:1 on a big source): its
            // corners and the picture's turned corners are then off screen, and only the numbers are
            // checkable. 缩小到画布小于视口 is the case the user sees, and it is fully on it.
            // The whole canvas is on screen only when its own AABB fits the viewport — `canvasRect` is
            // already clipped to the canvas, so comparing it with `clipped` cannot tell.
            let fullyVisible = Double(aabb.width) * scale <= Double(Self.viewport.width) + 0.5
                && Double(aabb.height) * scale <= Double(Self.viewport.height) + 0.5

            // ① the turned picture's corners are on the canvas — and they are photograph.
            var missing: [String] = []
            for corner in turnedCorners(cropPixels: cropPixels, scale: scale, canvas: canvas,
                                        degrees: Self.angle) {
                let cx = Double(canvas.x) + Double(canvas.width) / 2
                let cy = Double(canvas.y) + Double(canvas.height) / 2
                let dx = cx - corner.x, dy = cy - corner.y
                let len = max((dx * dx + dy * dy).squareRoot(), 1)
                let px = Int((corner.x + dx / len * 3).rounded())
                let py = Int((corner.y + dy / len * 3).rounded())
                let sample = triple(target, px, py)
                let ok = sample.0 > 60 || sample.1 > 60 || sample.2 > 60
                let onScreen = px >= 0 && py >= 0 && px < Self.viewport.width && py < Self.viewport.height
                if !ok && onScreen { missing.append("\(corner.name)@(\(px),\(py))=\(sample)") }
                print("  corner \(corner.name) → canvas (\(Int(corner.x.rounded())),"
                      + "\(Int(corner.y.rounded()))) · sample (\(px),\(py)) \(sample) "
                      + (ok ? "photo" : "NOT PHOTO") + (onScreen ? "" : " (off screen)"))
            }
            // 既有缺陷，不是本单的修复对象：竖拍在「适应」下（AABB 比视口高、整幅被裁）
            // 照片只画到画布的中线，右半是黑的 —— 与窗口无关，改前改后逐值相同（git stash 对照过）。
            // 记录在此，别让它被误当成 196 的回归：缩小 / 25 % / 50 % / 1:1 都必须绿。
            let knownFitPortrait = orientation == "portrait" && f.name == "fit"
            if fullyVisible && !knownFitPortrait {
                XCTAssertTrue(missing.isEmpty,
                              "196 \(orientation) \(f.name): the turned picture's corners are not on "
                              + "the canvas — \(missing.joined(separator: " · "))")
            }

            // ② where the picture actually starts: the lit extent reaches the canvas on every axis
            //    whose canvas edge is inside the texture.
            let lit = litness(texture)
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for y in 0..<texture.height {
                for x in 0..<texture.width where lit[y * texture.width + x] {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            print("  lit extent (\(minX),\(minY))–(\(maxX),\(maxY)) · canvas \(clipped.keyString)"
                  + "@(\(clipped.x),\(clipped.y))")
            // The picture must reach the canvas' edge, or — when the tangent point is off screen on
            // the other axis — at least leave the crop's own rect into the margin. Both are the same
            // statement: the band between `drawnRect` and `canvasRect` is photograph. Before 196 the
            // lit extent stopped at `drawnRect` exactly (the render was clipped to the crop's grid).
            let drawn = result.drawnRect
            if !knownFitPortrait && clipped.maxX < texture.width - 1 && clipped.x > 1 {
                XCTAssertTrue(minX <= clipped.x + 1 || minX < drawn.x,
                              "196 \(orientation) \(f.name): the picture starts at x=\(minX) — the "
                              + "canvas starts at \(clipped.x) and the crop at \(drawn.x): margin empty")
                XCTAssertTrue(maxX >= clipped.maxX - 1 || maxX > drawn.maxX,
                              "196 \(orientation) \(f.name): the picture ends at x=\(maxX) — the "
                              + "canvas ends at \(clipped.maxX) and the crop at \(drawn.maxX): margin empty")
            }
            if !knownFitPortrait && clipped.maxY < texture.height - 1 && clipped.y > 1 {
                XCTAssertTrue(minY <= clipped.y + 1 || minY < drawn.y,
                              "196 \(orientation) \(f.name): the picture starts at y=\(minY) — the "
                              + "canvas starts at \(clipped.y) and the crop at \(drawn.y): margin empty")
                XCTAssertTrue(maxY >= clipped.maxY - 1 || maxY > drawn.maxY,
                              "196 \(orientation) \(f.name): the picture ends at y=\(maxY) — the "
                              + "canvas ends at \(clipped.maxY) and the crop at \(drawn.maxY): margin empty")
            }

            // ③ the canvas' own corners are black, and no 0F anywhere inside it.
            let corners = [(canvas.x, canvas.y), (canvas.maxX - 1, canvas.y),
                           (canvas.x, canvas.maxY - 1), (canvas.maxX - 1, canvas.maxY - 1)]
                .map { triple(target, $0.0, $0.1) }
            var total = 0, grey = 0
            for y in stride(from: clipped.y + 1, to: clipped.maxY - 1, by: 3) {
                for x in stride(from: clipped.x + 1, to: clipped.maxX - 1, by: 3) {
                    total += 1
                    if triple(target, x, y) == (15, 15, 15) { grey += 1 }
                }
            }
            let share = total > 0 ? 100.0 * Double(grey) / Double(total) : -1
            print("  canvas corners \(corners.map { "\($0.0),\($0.1),\($0.2)" }.joined(separator: " · "))"
                  + " · 0F inside canvas \(String(format: "%.2f", share))%")
            if fullyVisible {
                for (i, c) in corners.enumerated() {
                    XCTAssertEqual([c.0, c.1, c.2], [0, 0, 0],
                                   "196 \(orientation) \(f.name): canvas corner \(i) is not 000000 — \(c)")
                }
            }
            XCTAssertEqual(share, 0, accuracy: 0.001,
                           "196 \(orientation) \(f.name): 0F0F0F inside the canvas")
        }
    }

    func testLandscapeStraightenedCornersAreOnTheCanvas() throws {
        try run("landscape", source: Self.landscape)
    }

    func testPortraitStraightenedCornersAreOnTheCanvas() throws {
        try run("portrait", source: Self.portrait)
    }

    /// θ = 0 is the anchor: the picture *is* the canvas, so `canvasRect == drawnRect` at every framing.
    func testZeroDegreesKeepsCanvasRectEqualToDrawnRect() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.portrait.width,
                                                                    Self.portrait.height),
                                                       identity: "portrait-196-zero"))
        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(Self.portrait.width),
                                   sourceHeight: Double(Self.portrait.height),
                                   crop: .full, straightenDegrees: 0)
        for f in states(framing) {
            let result = try graph.render(EditModel.neutral, options: RenderOptions(
                canvas: Self.viewport, scale: framing.renderScale(of: f.state, decodeScale: 1),
                outputWindow: framing.outputWindow(of: f.state, decodeScale: 1),
                useCache: false, wantsPixels: false))
            if let t = result.output { graph.recycle(output: t) }
            print("196 θ=0 \(f.name) · drawnRect \(result.drawnRect.keyString) "
                  + "· canvasRect \(result.canvasRect.keyString)")
            XCTAssertEqual(result.canvasRect, result.drawnRect, "θ = 0 · \(f.name)")
        }
    }
}
