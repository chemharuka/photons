import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 「裁切界面缩放后，全尺寸那一帧还是按原照片画布来的，要按旋转后扩大的画布来」+
/// 「旋转之后，裁切界面的全尺寸帧和真实渲染的像素对不上」.
///
/// Two claims, one geometry. The crop workspace's *settled* frame renders with **no window**
/// (`state.mode == .fit` → `LoupeFraming.outputWindow` is nil), and `RenderGraph.plan` then composes
/// it on the rotated canvas — `CropMath.canvasSize` — so 适应 is right. The moment the user zooms in,
/// the frame names an `outputWindow` (`LoupeZoom.outputWindow(of:)`), and `RenderGraph.plan`'s
/// rotated-canvas branch is gated on `window == nil` (`RenderGraph.swift:1601`): the frame is cut out
/// of `CropMath.outputSize(...)`, i.e. the crop's own un-rotated rect — the photograph's canvas, not
/// the expanded one. So the full-size frame is the one path that never sees the expansion.
///
/// The reference here is the **real render** — `RenderOptions(canvas: nil, scale: 1)`, exactly what
/// `photonsctl render --scale 1.0 --tone-map none` asks for (its `renderAll` builds the same options),
/// at the same decode rung so no resampling sits between the two pictures.
@MainActor
final class CropFullResCanvasTests: XCTestCase {

    private let decodeScale: Float = 0.25
    private let viewport = ImageSize(width: 400, height: 300)

    private func fixture() throws -> URL {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
                                "UI tests must run with PHOTONS_TEST_RAW")
        return URL(fileURLWithPath: raw)
    }

    // MARK: the two pictures

    private struct Plate {
        let pixels: [SIMD3<Float>]
        let width: Int
        let height: Int
    }

    /// `photonsctl render`'s own options: no canvas, one output pixel per decoded pixel.
    private func realRender(_ edit: EditModel, graph: RenderGraph) throws -> Plate {
        let result = try graph.render(edit, options: RenderOptions(
            canvas: nil, scale: 1,
            display: DisplayOptions(primaries: .displayP3, bitDepth: 8, headroom: 1),
            useCache: false, wantsPixels: true, source: .edited))
        let d = try XCTUnwrap(result.display, "the reference render produced no pixels")
        var out = [SIMD3<Float>](repeating: .zero, count: d.width * d.height)
        for i in 0..<(d.width * d.height) {
            out[i] = SIMD3(Float(d.rgba[i * 4]), Float(d.rgba[i * 4 + 1]), Float(d.rgba[i * 4 + 2]))
        }
        return Plate(pixels: out, width: d.width, height: d.height)
    }

    private func plate(_ texture: MTLTexture) -> Plate {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [SIMD3<Float>](repeating: .zero, count: w * h)
        for i in 0..<(w * h) {
            out[i] = SIMD3(Float(Float16(bitPattern: raw[i * 4])),
                           Float(Float16(bitPattern: raw[i * 4 + 1])),
                           Float(Float16(bitPattern: raw[i * 4 + 2])))
        }
        return Plate(pixels: out, width: w, height: h)
    }

    /// The crop workspace's full-size frame: a 1:1 window centred on the picture, one rung pixel per
    /// canvas pixel (so the two plates are on the same grid and no interpolation is being measured).
    private func fullSizeFrame(_ edit: EditModel, loupe: LoupeController,
                               decoded: ImageSize) throws -> (plate: Plate, framing: LoupeFraming) {
        let framing = LoupeFraming(viewport: viewport, decoded: decoded,
                                   decodeScale: Double(decodeScale), edit: edit)
        var state = LoupeViewState.fit
        state.mode = .actual
        state.zoom = Double(decodeScale)
        state.centerX = framing.cropOriginX + framing.cropWidthPixels / 2
        state.centerY = framing.cropOriginY + framing.cropHeightPixels / 2
        let frame = try loupe.makeFrame(url: try fixture(), viewport: viewport,
                                        decodeScale: decodeScale, edit: edit, state: state,
                                        useCache: false)
        XCTAssertEqual(frame.canvas, viewport, "the frame must be rendered on the viewport")
        return (plate(frame.texture), framing)
    }

    // MARK: measurement

    private struct Difference {
        let maxCode: Int
        let meanCode: Double
        let aboveTwoPercent: Double
    }

    private func difference(_ a: Plate, _ b: Plate, at origin: (x: Int, y: Int)) throws -> Difference {
        let pw = a.width, ph = a.height
        guard origin.x >= 0, origin.y >= 0,
              origin.x + pw <= b.width, origin.y + ph <= b.height else {
            throw XCTSkip("the block \(pw)×\(ph) at \(origin) is outside the reference \(b.width)×\(b.height)")
        }
        var maxCode = 0, aboveTwo = 0
        var sum = 0.0
        for y in 0..<ph {
            for x in 0..<pw {
                let p = a.pixels[y * pw + x], q = b.pixels[(y + origin.y) * b.width + (x + origin.x)]
                let d = max(abs(Int((p.x * 255).rounded()) - Int((q.x * 255).rounded())),
                            max(abs(Int((p.y * 255).rounded()) - Int((q.y * 255).rounded())),
                                abs(Int((p.z * 255).rounded()) - Int((q.z * 255).rounded()))))
                maxCode = max(maxCode, d)
                sum += Double(d)
                if d > 2 { aboveTwo += 1 }
            }
        }
        let n = Double(pw * ph)
        return Difference(maxCode: maxCode, meanCode: sum / n, aboveTwoPercent: 100 * Double(aboveTwo) / n)
    }

    // MARK: the two rules

    /// ① 画布 = 旋转后扩大的画布. At 45° the reference canvas is `CropMath.canvasSize` —
    /// 4243×4243 for a 3000×2000 crop — and the picture sits centred in it. A 1:1 window centred on
    /// the picture must therefore be the reference block at the **AABB origin**, not at the origin
    /// the crop's own (un-rotated) rect would put it at.
    func testFullSizeFrameIsAPlaceOnTheExpandedCanvas() throws {
        let url = try fixture()
        let developed = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: decodeScale))
        let decoded = ImageSize(width: developed.image.width, height: developed.image.height)
        let graph = try RenderGraph(input: RenderInput(image: developed.image, identity: "real",
                                                       sourceURL: url,
                                                       lensProfile: developed.lensProfile))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 45

        let real = try realRender(edit, graph: graph)
        let expanded = CropMath.canvasSize(crop: .full, in: decoded, straightenDegrees: 45,
                                           quarterTurns: 0)
        XCTAssertEqual(real.width, expanded.width)
        XCTAssertEqual(real.height, expanded.height)

        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let frame = try fullSizeFrame(edit, loupe: loupe, decoded: decoded)

        // Where the picture's frame sits inside the expanded canvas: (canvas − frame) / 2.
        let frameSize = CropMath.outputSize(edit.geometry.renderCrop(source: decoded), in: decoded,
                                            allowsOutsideSource: true)
        let centre = frame.framing.windowCenter(of: {
            var s = LoupeViewState.fit
            s.mode = .actual
            s.zoom = Double(decodeScale)
            s.centerX = frame.framing.cropOriginX + frame.framing.cropWidthPixels / 2
            s.centerY = frame.framing.cropOriginY + frame.framing.cropHeightPixels / 2
            return s
        }())
        let insetX = (expanded.width - frameSize.width) / 2
        let insetY = (expanded.height - frameSize.height) / 2
        let origin = (x: Int((centre.x * Double(decodeScale)).rounded()) - viewport.width / 2 + insetX,
                      y: Int((centre.y * Double(decodeScale)).rounded()) - viewport.height / 2 + insetY)
        let d = try difference(frame.plate, real, at: origin)
        print(String(format: "FULLRES · 45° · canvas %d×%d · frame %d×%d · inset (%d,%d) · block at (%d,%d)"
                     + " · max|Δ| %d · mean|Δ| %.2f · >2 codes %.1f%%",
                     expanded.width, expanded.height, frameSize.width, frameSize.height,
                     insetX, insetY, origin.x, origin.y, d.maxCode, d.meanCode, d.aboveTwoPercent))
        XCTAssertLessThanOrEqual(d.maxCode, 2,
                                 "the full-size frame is not the expanded canvas' picture "
                                 + "(max|Δ| \(d.maxCode) codes, \(String(format: "%.1f", d.aboveTwoPercent))% > 2)")
        XCTAssertLessThanOrEqual(d.aboveTwoPercent, 1.0,
                                 "\(String(format: "%.1f", d.aboveTwoPercent))% of the full-size frame "
                                 + "differs from the real render by more than 2 code values")
    }

    /// ② 裁切预览 ≡ 真实渲染 (same region, same pixels — no offset allowed). A quarter turn is the
    /// negative control that already holds: the turned frame grid *is* the canvas, so if this goes red
    /// the measurement, not the projection, is what broke.
    func testFullSizeFrameIsTheRealRenderAtRightAngles() throws {
        let url = try fixture()
        let developed = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: decodeScale))
        let decoded = ImageSize(width: developed.image.width, height: developed.image.height)
        let graph = try RenderGraph(input: RenderInput(image: developed.image, identity: "real",
                                                       sourceURL: url,
                                                       lensProfile: developed.lensProfile))
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        for turns in [0, 1, 2, 3] {
            var edit = EditModel.neutral
            edit.geometry.quarterTurns = turns
            let real = try realRender(edit, graph: graph)
            let frame = try fullSizeFrame(edit, loupe: loupe, decoded: decoded)
            var state = LoupeViewState.fit
            state.mode = .actual
            state.zoom = Double(decodeScale)
            state.centerX = frame.framing.cropOriginX + frame.framing.cropWidthPixels / 2
            state.centerY = frame.framing.cropOriginY + frame.framing.cropHeightPixels / 2
            let centre = frame.framing.windowCenter(of: state)
            let origin = (x: Int((centre.x * Double(decodeScale)).rounded()) - viewport.width / 2,
                          y: Int((centre.y * Double(decodeScale)).rounded()) - viewport.height / 2)
            let d = try difference(frame.plate, real, at: origin)
            print(String(format: "FULLRES · %d×90° · canvas %d×%d · max|Δ| %d · mean|Δ| %.2f · >2 %.1f%%",
                         turns, real.width, real.height, d.maxCode, d.meanCode, d.aboveTwoPercent))
            XCTAssertEqual(d.maxCode, 0,
                           "\(turns)×90°: the full-size frame is not the real render at (\(origin.x),\(origin.y))")
        }
    }

    /// ③ 反向断言：未旋转时全尺寸帧与真实渲染逐像素一致 —— 修画布不许把正常路径改坏。
    func testUnrotatedFullSizeFrameIsUnchanged() throws {
        let url = try fixture()
        let developed = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: decodeScale))
        let decoded = ImageSize(width: developed.image.width, height: developed.image.height)
        let graph = try RenderGraph(input: RenderInput(image: developed.image, identity: "real",
                                                       sourceURL: url,
                                                       lensProfile: developed.lensProfile))
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        let real = try realRender(EditModel.neutral, graph: graph)
        let frame = try fullSizeFrame(EditModel.neutral, loupe: loupe, decoded: decoded)
        var state = LoupeViewState.fit
        state.mode = .actual
        state.zoom = Double(decodeScale)
        state.centerX = frame.framing.cropOriginX + frame.framing.cropWidthPixels / 2
        state.centerY = frame.framing.cropOriginY + frame.framing.cropHeightPixels / 2
        let centre = frame.framing.windowCenter(of: state)
        let origin = (x: Int((centre.x * Double(decodeScale)).rounded()) - viewport.width / 2,
                      y: Int((centre.y * Double(decodeScale)).rounded()) - viewport.height / 2)
        let d = try difference(frame.plate, real, at: origin)
        print(String(format: "FULLRES · 0° · max|Δ| %d · mean|Δ| %.2f · >2 %.1f%%",
                     d.maxCode, d.meanCode, d.aboveTwoPercent))
        XCTAssertEqual(d.maxCode, 0, "the unrotated full-size frame must stay pixel-identical")
    }

    /// ④ θ = 9° — ① one step away from the case the diagnosis called "phase-level": at 9° the best
    /// integer offset already landed on the canvas' origin, and the residual was 8 codes. That 8 was
    /// the picture being composed at the crop's pivot with the canvas' margin bolted on by the
    /// *measurement*; composed by the renderer at the canvas' pivot the residual is **zero**.
    func testFullSizeFrameAtNineDegreesIsExact() throws {
        let url = try fixture()
        let developed = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: decodeScale))
        let decoded = ImageSize(width: developed.image.width, height: developed.image.height)
        let graph = try RenderGraph(input: RenderInput(image: developed.image, identity: "real",
                                                       sourceURL: url,
                                                       lensProfile: developed.lensProfile))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 9

        let real = try realRender(edit, graph: graph)
        let expanded = CropMath.canvasSize(crop: .full, in: decoded, straightenDegrees: 9,
                                           quarterTurns: 0)
        XCTAssertEqual(real.width, expanded.width)
        XCTAssertEqual(real.height, expanded.height)

        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let frame = try fullSizeFrame(edit, loupe: loupe, decoded: decoded)

        let frameSize = CropMath.outputSize(edit.geometry.renderCrop(source: decoded), in: decoded,
                                            allowsOutsideSource: true)
        var fitState = LoupeViewState.fit
        fitState.mode = .actual
        fitState.zoom = Double(decodeScale)
        fitState.centerX = frame.framing.cropOriginX + frame.framing.cropWidthPixels / 2
        fitState.centerY = frame.framing.cropOriginY + frame.framing.cropHeightPixels / 2
        let centre = frame.framing.windowCenter(of: fitState)
        let insetX = (expanded.width - frameSize.width) / 2
        let insetY = (expanded.height - frameSize.height) / 2
        let origin = (x: Int((centre.x * Double(decodeScale)).rounded()) - viewport.width / 2 + insetX,
                      y: Int((centre.y * Double(decodeScale)).rounded()) - viewport.height / 2 + insetY)
        let d = try difference(frame.plate, real, at: origin)
        print(String(format: "FULLRES · 9° · canvas %d×%d · frame %d×%d · inset (%d,%d) · block at (%d,%d)"
                     + " · max|Δ| %d · mean|Δ| %.2f · >2 codes %.1f%%",
                     expanded.width, expanded.height, frameSize.width, frameSize.height,
                     insetX, insetY, origin.x, origin.y, d.maxCode, d.meanCode, d.aboveTwoPercent))
        XCTAssertEqual(d.maxCode, 0,
                       "at 9° the full-size frame must be the expanded canvas' picture exactly "
                       + "(max|Δ| \(d.maxCode) codes)")
    }
}
