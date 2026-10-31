import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// LANE PROBE (measurement only, no product change) — 「旋转后再缩小，画布被裁 / 0F 入侵画布」.
///
/// For θ = 5.4° and four framings (25 % / 50 % / 适应 / 1:1) it prints, per framing:
///
///   * the viewport, the **canvas** rect on screen (the expanded canvas, = `CropMath.canvasSize`
///     at the zoom, derived independently as "the picture quad outset by the AABB inset"),
///     `pictureQuad`, `backdropQuad` (none: a settled present draws no backdrop) and `plan.drawnRect`;
///   * the `0F0F0F` share of the canvas rect (step 8), and its distance to the four canvas edges;
///   * whether the picture is inside the viewport and by how much it misses it;
///   * the three rounding conventions (`canvasSize` ceil, plan `rounded`, present quad `rounded`)
///     edge by edge;
///   * A = `CropMath.canvasSize` vs B = the canvas `plan.drawnRect` implies vs C = `frameSize(crop)`.
@MainActor
final class RotZoomOutProbeTests: XCTestCase {

    private static let viewport = ImageSize(width: 700, height: 500)
    /// A crop **smaller than four viewports**: `fitZoom` (0.30) then sits *above* the 25 % stop, which
    /// is the user's condition — 「旋转后再缩小到 25 %」 means a zoom below 适应, where the picture and
    /// the canvas are both smaller than the viewport and the canvas' margin is on screen.
    private static let source = ImageSize(width: 2000, height: 1500)
    /// The 188 report's fixture, for the analytic half (no render).
    private static let bigSource = ImageSize(width: 6000, height: 4500)
    private static let bigViewport = ImageSize(width: 1400, height: 1000)

    private func image(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0.2, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 4 || y < 4 || x >= w - 4 || y >= h - 4
                let v: Float16 = edge ? 0.95 : 0.2
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "rot-zoomout-probe")
    }

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w,
                                                         height: h, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    private func pixelTriple(_ t: MTLTexture, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var raw = [UInt8](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 4,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return (Int(raw[2]), Int(raw[1]), Int(raw[0]))
    }

    private struct Framing {
        let name: String
        let state: LoupeViewState
    }

    private func states(_ framing: LoupeFraming) -> [Framing] {
        let centre = (x: framing.cropOriginX + framing.cropWidthPixels / 2,
                      y: framing.cropOriginY + framing.cropHeightPixels / 2)
        func actual(_ z: Double) -> LoupeViewState {
            var s = LoupeViewState()
            s.mode = .actual
            s.zoom = z
            s.centerX = centre.x
            s.centerY = centre.y
            return s
        }
        var fit = LoupeViewState()
        fit.mode = .fit
        return [Framing(name: "25%", state: actual(0.25)),
                Framing(name: "50%", state: actual(0.5)),
                Framing(name: "fit", state: fit),
                Framing(name: "100%", state: actual(1.0))]
    }

    func testProbeRotatedZoomOutGeometry() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source.width,
                                                                    Self.source.height),
                                                       identity: "rot-zoomout-probe"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 5.4
        let crop = edit.geometry.renderCrop(source: Self.source)
        let cropPix = CropMath.frameSize(crop, in: Self.source, allowsOutsideSource: true)
        let aabb = CropMath.canvasSize(crop: crop, in: Self.source, straightenDegrees: 5.4,
                                       quarterTurns: 0, allowsOutsideSource: true)
        print("PROBE fixture · source \(Self.source.keyString) · viewport \(Self.viewport.keyString) "
              + "· θ 5.4° · cropPix \(cropPix.keyString) · A=canvasSize \(aabb.keyString)")

        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(Self.source.width),
                                   sourceHeight: Double(Self.source.height),
                                   crop: .full, straightenDegrees: 5.4)
        print(String(format: "PROBE fitZoom %.5f", framing.fitZoom))

        for f in states(framing) {
            let scale = framing.renderScale(of: f.state, decodeScale: 1)
            let window = framing.outputWindow(of: f.state, decodeScale: 1)
            let result = try graph.render(edit, options: RenderOptions(
                canvas: Self.viewport, scale: scale, outputWindow: window,
                useCache: false, wantsPixels: false))
            let texture = try XCTUnwrap(result.output, "no render for \(f.name)")
            defer { graph.recycle(output: texture) }

            let target = try makeTexture(device, Self.viewport.width, Self.viewport.height)
            // 192: the quad the controller now paints is `canvasRect` — the canvas, not the picture.
            let request = presenter.requestForTest(texture, window: .whole, backdrop: nil,
                                                   backdropWindow: .whole,
                                                   picture: result.canvasRect,
                                                   canvas: Self.viewport)
            XCTAssertTrue(presenter.render(request, into: target, linearize: false),
                          presenter.lastFailure ?? "present failed")
            let quad = request.pictureQuad

            // The canvas on screen, derived independently of the plan: the picture's own rect grown
            // by the AABB inset `(AABB − crop)/2` at this scale.
            let baseline = ImageSize(width: max(1, Int((Double(aabb.width) * scale).rounded())),
                                     height: max(1, Int((Double(aabb.height) * scale).rounded())))
            let canvasRect = result.canvasRect
            // The canvas contains the picture, sits inside the viewport, and is the AABB at this
            // scale wherever the viewport does not cut it (the user's own criterion).
            XCTAssertTrue(canvasRect.intersected(in: Self.viewport) == canvasRect,
                          "the canvas rect left the viewport at \(f.name)")
            XCTAssertTrue(canvasRect.x <= result.drawnRect.x
                          && canvasRect.y <= result.drawnRect.y
                          && canvasRect.maxX >= result.drawnRect.maxX
                          && canvasRect.maxY >= result.drawnRect.maxY,
                          "the canvas does not contain the picture at \(f.name)")
            if abs(canvasRect.width - baseline.width) <= 1 && abs(canvasRect.height - baseline.height) <= 1 {
                XCTAssertEqual(canvasRect.width, baseline.width, accuracy: 1, "canvas width")
                XCTAssertEqual(canvasRect.height, baseline.height, accuracy: 1, "canvas height")
            }
            if f.name == "25%" {
                // The symptom's own number: at 25 % the canvas must be the AABB, not the crop.
                XCTAssertEqual(canvasRect.width, Int((Double(aabb.width) * scale).rounded()),
                               accuracy: 1, "25 %: canvas width is not CropMath.canvasSize × 0.25")
                XCTAssertEqual(canvasRect.height, Int((Double(aabb.height) * scale).rounded()),
                               accuracy: 1, "25 %: canvas height is not CropMath.canvasSize × 0.25")
            }
            let clipped = canvasRect.intersected(in: Self.viewport)

            // 0F share inside the canvas rect, step 8, plus the least distance to a canvas edge.
            var total = 0, grey = 0
            var minEdge = Int.max
            for y in stride(from: clipped.y + 1, to: clipped.y + clipped.height - 1, by: 8) {
                for x in stride(from: clipped.x + 1, to: clipped.x + clipped.width - 1, by: 8) {
                    total += 1
                    let p = pixelTriple(target, x, y)
                    if p == (15, 15, 15) {
                        grey += 1
                        let d = min(x - clipped.x, clipped.y + clipped.height - 1 - y,
                                    clipped.x + clipped.width - 1 - x, y - clipped.y)
                        minEdge = min(minEdge, d)
                    }
                }
            }
            let share = total > 0 ? 100.0 * Double(grey) / Double(total) : -1
            // The symptom itself: no `0F0F0F` may be inside the canvas at any framing.
            XCTAssertEqual(share, 0, accuracy: 0.001, "\(f.name): 0F inside the canvas")

            // The two colours either side of the canvas' own edge: inside the margin it is the
            // canvas' `000000`, outside the canvas it is still the matte `0F0F0F`.
            let margin = (x: max(clipped.x, result.drawnRect.x - 3),
                          y: clipped.y + clipped.height / 2)
            let outside = (x: max(0, clipped.x - 4), y: clipped.y + clipped.height / 2)
            let marginPixel = margin.x < result.drawnRect.x && margin.y >= clipped.y
                && margin.y < clipped.y + clipped.height
                ? pixelTriple(target, margin.x, margin.y) : (-1, -1, -1)
            let outsidePixel = clipped.x >= 4 && outside.y < Self.viewport.height
                ? pixelTriple(target, outside.x, outside.y) : (-1, -1, -1)

            // What the *picture* would be if the canvas were the crop (the "只有原图范围是好的" marker).
            let cropOnScreen = ImageRect(x: 0, y: 0,
                                         width: Int((Double(cropPix.width) * scale).rounded()),
                                         height: Int((Double(cropPix.height) * scale).rounded()))

            print(String(format:
                "PROBE %@ · scale %.4f · window %@ · viewport %@ · canvas(A×s) %d×%d at (%d,%d) "
                + "· drawnRect %@ · canvasRect %@ · pictureQuad %@ · backdropQuad nil "
                + "· pictureQuad==cropPix(%d×%d)=%@ "
                + "· 0F in canvas %.1f%% (min edge %@) · picture beyond viewport L%d T%d R%d B%d",
                f.name, scale,
                window.map { "\($0.keyString)@(\($0.x),\($0.y))" } ?? "nil",
                Self.viewport.keyString, baseline.width, baseline.height, canvasRect.x, canvasRect.y,
                "\(result.drawnRect.x),\(result.drawnRect.y),\(result.drawnRect.width),\(result.drawnRect.height)",
                "\(result.canvasRect.x),\(result.canvasRect.y),\(result.canvasRect.width),\(result.canvasRect.height)",
                "\(quad.x),\(quad.y),\(quad.width),\(quad.height)",
                cropOnScreen.width, cropOnScreen.height,
                (result.drawnRect.width == cropOnScreen.width
                    && result.drawnRect.height == cropOnScreen.height ? "YES" : "no"),
                share, grey > 0 ? "\(minEdge)" : "-",
                max(0, -quad.x), max(0, -quad.y),
                max(0, quad.x + quad.width - Self.viewport.width),
                max(0, quad.y + quad.height - Self.viewport.height)))
            print("PROBE \(f.name) · margin \(margin)=(\(marginPixel.0),\(marginPixel.1),\(marginPixel.2))"
                  + " inside canvas · outside \(outside)=(\(outsidePixel.0),\(outsidePixel.1),\(outsidePixel.2))"
                  + " (0F = 15,15,15)")
            if marginPixel.0 >= 0 {
                XCTAssertEqual([marginPixel.0, marginPixel.1, marginPixel.2], [0, 0, 0],
                               "\(f.name): the canvas margin is not 000000")
            }
            if outsidePixel.0 >= 0 {
                XCTAssertEqual([outsidePixel.0, outsidePixel.1, outsidePixel.2], [15, 15, 15],
                               "\(f.name): the matte outside the canvas")
            }

            // Rounding, edge by edge: canvas (ceil from CropMath) vs the picture (plan's `.rounded()`).
            let continuousW = Double(cropPix.width) * scale
            print(String(format:
                "PROBE %@ · rounding · crop×scale %.3f×%.3f → rounded %d×%d (Δ %.3f %.3f) "
                + "· AABB×scale %.3f×%.3f → rounded %d×%d (Δ %.3f %.3f)",
                f.name, continuousW, Double(cropPix.height) * scale,
                int(continuousW), int(Double(cropPix.height) * scale),
                Double(int(continuousW)) - continuousW,
                Double(int(Double(cropPix.height) * scale)) - Double(cropPix.height) * scale,
                Double(aabb.width) * scale, Double(aabb.height) * scale,
                baseline.width, baseline.height,
                Double(baseline.width) - Double(aabb.width) * scale,
                Double(baseline.height) - Double(aabb.height) * scale))
        }
    }

    /// θ = 0 is the anchor: with no angle the picture **is** the canvas, so `canvasRect` must be
    /// `drawnRect` to the pixel at every framing — the value that was on screen before 192.
    func testProbeZeroDegreesCanvasIsThePicture() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.source.width,
                                                                    Self.source.height),
                                                       identity: "rot-zoomout-probe-zero"))
        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(Self.source.width),
                                   sourceHeight: Double(Self.source.height),
                                   crop: .full, straightenDegrees: 0)
        for f in states(framing) {
            let scale = framing.renderScale(of: f.state, decodeScale: 1)
            let window = framing.outputWindow(of: f.state, decodeScale: 1)
            let result = try graph.render(EditModel.neutral, options: RenderOptions(
                canvas: Self.viewport, scale: scale, outputWindow: window,
                useCache: false, wantsPixels: false))
            if let texture = result.output { graph.recycle(output: texture) }
            print("PROBE 0° \(f.name) · window \(window.map { "\($0.keyString)@(\($0.x),\($0.y))" } ?? "nil")"
                  + " · drawnRect \(result.drawnRect.keyString) · canvasRect \(result.canvasRect.keyString)")
            XCTAssertEqual(result.canvasRect, result.drawnRect, "θ = 0 · \(f.name)")
        }
    }

    /// The 188 report's own fixture, analytic (no render): A vs B vs C in canvas pixels at four zooms.
    func testProbeAABBVersusPlanCanvasAtThe188Fixture() {
        let crop: CropRect = .full
        let cropPix = CropMath.frameSize(crop, in: Self.bigSource, allowsOutsideSource: true)
        let aabb = CropMath.canvasSize(crop: crop, in: Self.bigSource, straightenDegrees: 5.4,
                                       quarterTurns: 0, allowsOutsideSource: true)
        let framing = LoupeFraming(viewport: Self.bigViewport,
                                   sourceWidth: Double(Self.bigSource.width),
                                   sourceHeight: Double(Self.bigSource.height),
                                   crop: .full, straightenDegrees: 5.4)
        print("PROBE188 · source \(Self.bigSource.keyString) · viewport \(Self.bigViewport.keyString) "
              + "· A=canvasSize \(aabb.keyString) · C=cropPix \(cropPix.keyString) "
              + "· fitZoom \(framing.fitZoom)")
        for (name, z) in [("25%", 0.25), ("50%", 0.5), ("100%", 1.0)] {
            var s = LoupeViewState()
            s.mode = .actual
            s.zoom = z
            s.centerX = framing.cropOriginX + framing.cropWidthPixels / 2
            s.centerY = framing.cropOriginY + framing.cropHeightPixels / 2
            let w = framing.outputWindow(of: s, decodeScale: 1)
            let baselineW = Int((Double(aabb.width) * z).rounded())
            let baselineH = Int((Double(aabb.height) * z).rounded())
            let cropW = Int((Double(cropPix.width) * z).rounded())
            let cropH = Int((Double(cropPix.height) * z).rounded())
            print(String(format:
                "PROBE188 %@ · zoom %.2f · window %@ · canvas A×z %d×%d · crop C×z %d×%d "
                + "· A−C %d×%d (margin %d,%d per side) · window covers canvas? %@",
                name, z, w.map { "\($0.keyString)@(\($0.x),\($0.y))" } ?? "nil",
                baselineW, baselineH, cropW, cropH,
                baselineW - cropW, baselineH - cropH,
                (baselineW - cropW) / 2, (baselineH - cropH) / 2,
                (w != nil && w!.width >= baselineW && w!.height >= baselineH) ? "yes" : "NO"))
        }
    }

    private func int(_ v: Double) -> Int { Int(v.rounded()) }
}
