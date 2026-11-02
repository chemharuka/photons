import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 197 **探针** —— 竖拍「适应」取景：画布只被画到一半宽，右半是黑的。
///
/// **2026-11-02（232）已修**：根因是 `RenderGraph.plan` 在「有角度 + 无窗口（适应）」时把 letterbox
/// 的 `origin` 重复加进 `frameOrigin`，画面整体往左上偏 `origin`。本探针原先断言「缺陷还在」；现在
/// 翻成正面形式：竖拍 5.4° 适应时，亮区必须铺满 `canvasRect`（左右上下都到边）。
///
/// 最小复现（不需要窗口、不需要 RAW、不需要解码 —— 一个 `RenderGraph` 就够）：
///
///     source   2000×3000（竖拍）
///     viewport 700×500
///     θ        5.4°
///     状态      .fit（适应，window = nil）
///
/// 期望：照片的左切线在画布左边缘、右切线在画布右边缘。
/// 修复前：照片只画到 `x = 357`，正好是画布中线 `171 + 358/2`；`358…528` 是 000000。
/// 修复后（本探针当前断言）：亮区 `(189,25)–(509,473)`，画布 `189,25,322×450`，四边都到。
///
/// 与 196 的关系：`git stash` 掉 196 的 s0 letterbox 守卫后逐值相同 —— 不是 196 引入的。
@MainActor
final class CropPortraitFitDefect197ProbeTests: XCTestCase {

    private static let viewport = ImageSize(width: 700, height: 500)
    private static let portrait = ImageSize(width: 2000, height: 3000)
    private static let angle = 5.4

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
                           colorSpace: "sRGB", decoderVersion: "portrait-fit-197")
    }

    /// `rgba16Float`: lit = any channel above 0.03.
    private func lit(_ t: MTLTexture, _ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < t.width, y < t.height else { return false }
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 8,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return Float(Float16(bitPattern: raw[0]))
            + Float(Float16(bitPattern: raw[1]))
            + Float(Float16(bitPattern: raw[2])) > 0.03
    }

    /// The phenomenon, as numbers. It used to pass while the defect was there; **232 fixed the
    /// letterbox offset**, so the assertions are now the positive form: the lit extent reaches all
    /// four edges of `canvasRect`.
    func testPortraitFitFillsTheWholeCanvas() throws {
        let graph = try RenderGraph(input: RenderInput(image: image(Self.portrait.width,
                                                                   Self.portrait.height),
                                                       identity: "portrait-fit-197"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = Self.angle
        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(Self.portrait.width),
                                   sourceHeight: Double(Self.portrait.height),
                                   crop: .full, straightenDegrees: Self.angle)
        var state = LoupeViewState()
        state.mode = .fit
        let result = try graph.render(edit, options: RenderOptions(
            canvas: Self.viewport,
            scale: framing.renderScale(of: state, decodeScale: 1),
            outputWindow: framing.outputWindow(of: state, decodeScale: 1),
            useCache: false, wantsPixels: false))
        let texture = try XCTUnwrap(result.output, "no render")
        defer { graph.recycle(output: texture) }

        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<texture.height {
            for x in 0..<texture.width where lit(texture, x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let canvas = result.canvasRect
        let midX = canvas.x + canvas.width / 2
        print("197 probe · 竖拍 fit · source \(Self.portrait.keyString) θ \(Self.angle)° "
              + "· fitZoom \(String(format: "%.4f", framing.fitZoom)) "
              + "· canvasRect \(canvas.keyString)@(\(canvas.x),\(canvas.y)) "
              + "· drawnRect \(result.drawnRect.keyString) "
              + "· lit extent (\(minX),\(minY))–(\(maxX),\(maxY)) "
              + "· canvas midline x=\(midX) · canvas right x=\(canvas.maxX)")

        // ① the picture reaches the canvas' right edge (it stopped exactly on the midline while the
        // letterbox offset was applied twice; ±2 px absorbs the AABB ceil/round pair).
        XCTAssertGreaterThanOrEqual(maxX, canvas.maxX - 2,
                                    "197 probe: the lit extent does not reach the canvas' right edge "
                                    + "(maxX \(maxX) vs canvas.maxX \(canvas.maxX), canvas \(canvas.keyString))")
        // ② …and the other three edges: the lit box spans the canvas, not a quadrant of it.
        XCTAssertLessThanOrEqual(minX, canvas.x + 1, "the picture does not reach the canvas' left edge")
        XCTAssertLessThanOrEqual(minY, canvas.y + 1, "the picture does not reach the canvas' top edge")
        XCTAssertGreaterThanOrEqual(maxY, canvas.maxY - 2, "the picture does not reach the canvas' bottom edge")
        XCTAssertGreaterThan(maxX - minX, canvas.width - 4,
                             "the picture covers only \(maxX - minX) of the canvas' \(canvas.width) px")
        // ③ it is not a missing canvas: the canvas is a real rect inside the viewport (213: it is
        //    90 % of it, so the hard-coded 100 % edges no longer apply).
        XCTAssertGreaterThan(canvas.width, 0)
        XCTAssertGreaterThan(canvas.height, 0)
        XCTAssertLessThanOrEqual(canvas.x + canvas.width, Self.viewport.width)
        XCTAssertLessThanOrEqual(canvas.y + canvas.height, Self.viewport.height)
        XCTAssertGreaterThan(maxX, minX, "nothing was drawn at all")
    }
}
