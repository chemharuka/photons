import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 197 **探针** —— 竖拍「适应」取景：画布只被画到一半宽，右半是黑的。
///
/// **既有缺陷，本单不修**（197 只是碰巧在同一段几何里）。196 的角落套件早就看见它，用
/// `knownFitPortrait` 跳过了断言；这条把它单独钉出来，附最小复现和四个数字，交给主线决定。
///
/// 最小复现（不需要窗口、不需要 RAW、不需要解码 —— 一个 `RenderGraph` 就够）：
///
///     source   2000×3000（竖拍）
///     viewport 700×500
///     θ        5.4°
///     状态      .fit（适应，window = nil）
///
/// 期望：照片的左切线在画布左边缘、右切线在画布右边缘（画布 `358×500 @ x=171`）。
/// 实测：照片只画到 `x = 357`，正好是画布中线 `171 + 358/2`；`358…528` 是 000000。
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

    /// The phenomenon, as numbers. This is the probe: it **passes while the defect is there** and goes
    /// red the day someone fixes it — at which point the right assertion is "the lit extent reaches
    /// `canvasRect.maxX - 1`", i.e. exactly what `CropPortraitCorners196Tests` would then be able to
    /// assert for `fit` too.
    func testPortraitFitDrawsThePictureOnlyToTheCanvasMidline() throws {
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
        let rightBand = canvas.maxX - 5
        print("197 probe · 竖拍 fit · source \(Self.portrait.keyString) θ \(Self.angle)° "
              + "· fitZoom \(String(format: "%.4f", framing.fitZoom)) "
              + "· canvasRect \(canvas.keyString)@(\(canvas.x),\(canvas.y)) "
              + "· drawnRect \(result.drawnRect.keyString) "
              + "· lit extent (\(minX),\(minY))–(\(maxX),\(maxY)) "
              + "· canvas midline x=\(midX) · canvas right x=\(canvas.maxX) "
              + "· 右半采样 (\(rightBand),\(canvas.y + canvas.height / 2)) 亮? "
              + "\(lit(texture, rightBand, canvas.y + canvas.height / 2))")

        // ① the defect: the picture stops at the canvas' midline instead of its right edge.
        XCTAssertEqual(Double(maxX), Double(midX), accuracy: 8,
                       "197 probe: the lit extent no longer stops at the canvas' midline "
                       + "(maxX \(maxX) vs midline \(midX), canvas \(canvas.keyString)) — if this is "
                       + "red because the picture now reaches \(canvas.maxX - 1), the defect is fixed: "
                       + "flip this assertion to `maxX >= canvas.maxX - 1`.")
        // ② the visible symptom: the right half of the canvas is empty.
        XCTAssertFalse(lit(texture, rightBand, canvas.y + canvas.height / 2),
                       "197 probe: the right half of the canvas is no longer black — see ①.")
        // ③ it is not the canvas: the canvas itself fills the viewport's height (that is the 「AABB 比
        //    视口高」 shape) and reaches x = 171 … 528.
        XCTAssertEqual(canvas.height, Self.viewport.height, "the canvas no longer fills the height")
        XCTAssertEqual(canvas.maxX, 529, "the canvas rect moved")
        XCTAssertGreaterThan(maxX, minX, "nothing was drawn at all")
    }
}
