import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 188 — 旋转后的四件事: 底图铺满扩大画布 / 输出尺寸按画布 / 裁切框可出画布 / 陈旧矩形失效.
///
/// The four claims, and the number each one is measured by:
///
///   1. **The backdrop's quad is the expanded canvas.** `LoupeFraming.framePlacement` normalises the
///      region against `rotatedCropExtent` (the canvas 176 renders into), not against the crop, so the
///      whole-picture backdrop lands on the picture's own rect instead of being multiplied by
///      `canvas/crop` a second time. At 5.4° on a 1400 × 1000 canvas that was 39 / 54 / 81 / 108 px.
///   2. **The frame may leave the canvas.** With a draft angle the clamp only has to keep the frame
///      *reachable* (its quad's centre on the canvas): a 100 pt overhang used to be shrunk and slid back.
///   3. `EditModel.outputPixels` is `CropMath.canvasSize` — the canvas the renderer allocates, which is
///      what 信息栏 and the backdrop's own scale read.
///   4. At θ = 0 every number above is the pre-188 one, to the last digit: `rotatedCropExtent` returns
///      its input at 0° and `canvasSize` returns `outputSize` at every right angle, so the arithmetic
///      degenerates into the old expressions term for term.
@MainActor
final class CropRotation188Tests: XCTestCase {

    private var workDir: URL!
    private static let viewport = ImageSize(width: 1400, height: 1000)
    /// 4:3 — the aspect at which the turned canvas is narrower than the viewport, so the fit frame is
    /// **letterboxed** and the backdrop's quad has a left margin to get wrong (0.0471 = 66/1400).
    private static let source = ImageSize(width: 6000, height: 4500)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-188-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func framing(degrees: Double, viewport: ImageSize = viewport,
                         source: ImageSize = source) -> LoupeFraming {
        LoupeFraming(viewport: viewport,
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: degrees)
    }
    /// The whole backdrop texture drawn **on the canvas**, in canvas fractions: the inverse of
    /// `PresentWindow.onWholePicture` (`canvas = rect.origin + (picture − region.origin) · rect/region`).
    ///
    /// This is the quantity the user sees: 「底图为 000000 的那一块」 — where the low-resolution whole
    /// picture lands. It is `placement.rect` exactly when the texture *is* the expanded canvas
    /// (`region == .full`), which is the property 176's canvas-sized frame gives at fit.
    private func backdropQuad(_ p: FramePlacement) -> (u0: Double, v0: Double, du: Double, dv: Double) {
        let r = p.rect, g = p.region
        let sx = Double(r.du) / max(g.width, 1e-12)
        let sy = Double(r.dv) / max(g.height, 1e-12)
        return (Double(r.u0) - g.left * sx, Double(r.v0) - g.top * sy, sx, sy)
    }

    private func rect(_ layout: CropToolLayout) -> CGRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A 20 % × 20 % frame whose **centre** is at canvas x = `x` (mid height), built through the drags'
    /// own inverse so the fixture is where the hand would have put it.
    private func draftFrame(mapping: LoupeMapping, angle: Double, atCanvasX x: Double) -> CropRect {
        let point = CGPoint(x: x, y: Double(Self.viewport.height) / 2)
        guard let centre = CropToolController.normalized(point, mapping: mapping, source: Self.source,
                                                        pointScale: 1, rotationDegrees: angle)
        else { return CropRect(left: 0.4, top: 0.4, right: 0.6, bottom: 0.6) }
        return CropRect(left: centre.x - 0.1, top: centre.y - 0.1,
                        right: centre.x + 0.1, bottom: centre.y + 0.1)
    }

    // MARK: - ① the backdrop's quad is the expanded canvas

    /// 5.4° — the angle the report was measured at. The canvas is 1400 × 1000 device pixels; the
    /// picture inside it is 1268 × 1000 at x = 66, so the backdrop's quad must be
    /// `(0.0471, 0, 0.9057, 1.0) × canvas` — **to 1 pt**.
    ///
    /// Before 188 the region was normalised against `cropWidthPixels`, i.e. by `canvas/crop` as well:
    /// the quad came out `(0.0752, 0.0540, 0.8495, 0.8921)`, which is 39 px right, 54 px down and
    /// 81 × 108 px small. Red on that rectangle, green on this one.
    func testTheBackdropQuadIsTheExpandedCanvasAtFivePointFour() throws {
        let f = framing(degrees: 5.4)
        let placement = f.framePlacement(of: f.mapping(of: .fit))
        let quad = backdropQuad(placement)
        let px = (x: quad.u0 * 1400, y: quad.v0 * 1000,
                  w: quad.du * 1400, h: quad.dv * 1000)
        print(String(format: "188 ① · 5.4° · canvas %d×%d · region u[%.4f…%.4f] v[%.4f…%.4f] · "
                     + "rect %@ · backdrop quad (%.4f, %.4f, %.4f, %.4f) × canvas = (%.1f, %.1f, %.1f, %.1f) px",
                     1400, 1000, placement.region.left, placement.region.right,
                     placement.region.top, placement.region.bottom,
                     String(format: "u0 %.4f du %.4f v0 %.4f dv %.4f",
                            Double(placement.rect.u0), Double(placement.rect.du),
                            Double(placement.rect.v0), Double(placement.rect.dv)),
                     quad.u0, quad.v0, quad.du, quad.dv, px.x, px.y, px.w, px.h))

        // The frame texture *is* the canvas at 适应, and that is the whole fix in one assertion.
        XCTAssertEqual(placement.region.left, 0, accuracy: 1 / 1400)
        XCTAssertEqual(placement.region.top, 0, accuracy: 1 / 1000)
        XCTAssertEqual(placement.region.width, 1, accuracy: 1 / 1400)
        XCTAssertEqual(placement.region.height, 1, accuracy: 1 / 1000)

        // …and the quad the user sees, in points: the picture's own rect, no second margin.
        XCTAssertEqual(px.x, 0.0471 * 1400, accuracy: 1, "left margin of the quad")
        XCTAssertEqual(px.y, 0, accuracy: 1, "the quad starts at the canvas' top edge")
        XCTAssertEqual(px.w, 0.9057 * 1400, accuracy: 1, "the quad's width")
        XCTAssertEqual(px.h, 1000, accuracy: 1, "and it fills the canvas' height")

        // The picture quad the present pass paints the matte's edge from is the same rectangle: the
        // backdrop and the photograph agree to the pixel, so the `0F0F0F` band starts where it must.
        let pr = placement.rect
        let pictureFraction = PresentWindow.whole.canvasRect(ofTexture: Double(pr.u0), Double(pr.v0),
                                                             Double(pr.du), Double(pr.dv))
        let picture = (x: (pictureFraction?.x ?? 0) * 1400,
                       y: (pictureFraction?.y ?? 0) * 1000,
                       w: (pictureFraction?.width ?? 0) * 1400,
                       h: (pictureFraction?.height ?? 0) * 1000)
        print(String(format: "188 ① · picture quad (%.1f, %.1f, %.1f, %.1f) px",
                     picture.x, picture.y, picture.w, picture.h))
        XCTAssertEqual(picture.x, px.x, accuracy: 1)
        XCTAssertEqual(picture.w, px.w, accuracy: 1)

        // 45°: the turned canvas is square (6000 + 4500 on both axes), so the quad is the centred
        // 1000 × 1000 square — 0.7143 wide, not 0.577 × 0.606 (Δ 394 px on the old arithmetic).
        let diagonal = framing(degrees: 45)
        let at45 = backdropQuad(diagonal.framePlacement(of: diagonal.mapping(of: .fit)))
        print(String(format: "188 ① · 45° · quad (%.4f, %.4f, %.4f, %.4f)", at45.u0, at45.v0, at45.du, at45.dv))
        XCTAssertEqual(at45.du, 1000.0 / 1400, accuracy: 1 / 1400, "45°: the AABB is square")
        XCTAssertEqual(at45.dv, 1, accuracy: 1 / 1000)
        XCTAssertEqual(at45.u0, 200.0 / 1400, accuracy: 1 / 1400, "centred in the canvas")
        XCTAssertEqual(at45.v0, 0, accuracy: 1 / 1000)
    }

    // MARK: - ② the frame stays inside the canvas, and may cover its letterbox

    /// 5.4°, one 100 pt overhang: **the frame is pulled back inside the canvas, at its own size.**
    ///
    /// 190 read the user's 「框可以超出扩大后的画布」 as an area rule (≥25 % of the frame still over
    /// the canvas) and this test pinned it. The user has since reversed it (196): the canvas is a
    /// **hard** bound again (162's semantics) and the *photograph* is the soft one. So the same
    /// overhang must now be clamped — and the two halves of the new contract are asserted here: the
    /// frame *moves* (never shrinks), and it may sit over the canvas' `000000` corners.
    func testTheFrameStaysInsideTheCanvasButMayCoverTheLetterbox() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let angle = 5.4
        let mapping = framing(degrees: angle).mapping(of: .fit)
        let canvas = CGRect(x: 0, y: 0, width: Double(Self.viewport.width),
                            height: Double(Self.viewport.height))
        let draft = draftFrame(mapping: mapping, angle: angle, atCanvasX: 8)
        controller.draft = CropToolController.Draft(crop: draft, straighten: angle, lock: .original)

        let before = rect(controller.layout(mapping: mapping, source: Self.source, pointScale: 1))
        print(String(format: "188 ② · before clamp · quad %@ · canvas %@",
                     NSStringFromRect(before), NSStringFromRect(canvas)))
        XCTAssertLessThan(before.minX, canvas.minX - 100,
                          "the fixture must start 100 pt out: \(NSStringFromRect(before))")

        // The app's own model-layer clamp, on the shipped drag path's mapping.
        let moved = controller.clampToView(mapping: mapping, source: Self.source)
        let after = rect(controller.layout(mapping: mapping, source: Self.source, pointScale: 1))
        let drawn = controller.draft.crop
        print(String(format: "188 ② · clampToView → %@ · quad %@ · draft l %.6f r %.6f w %.6f h %.6f",
                     moved ? "MOVED" : "untouched", NSStringFromRect(after),
                     drawn.left, drawn.right, drawn.width, drawn.height))

        // ① 196 — 「框不得移出画布」: the 100 pt overhang is clamped, and the quad lands inside the
        //    canvas (one point of slack for the overlay's rounding).
        XCTAssertTrue(moved, "196: a frame 100 pt outside the canvas must be pulled back")
        XCTAssertGreaterThanOrEqual(after.minX, canvas.minX - 1,
                                    "the quad is still outside on the left: \(NSStringFromRect(after))")
        XCTAssertLessThanOrEqual(after.maxX, canvas.maxX + 1, "\(NSStringFromRect(after))")
        XCTAssertGreaterThanOrEqual(after.minY, canvas.minY - 1, "\(NSStringFromRect(after))")
        XCTAssertLessThanOrEqual(after.maxY, canvas.maxY + 1, "\(NSStringFromRect(after))")

        // ② it is **moved**, never shrunk: the size the user drew is the size they keep.
        XCTAssertEqual(drawn.width, draft.width, accuracy: 1e-9, "a clamp may never resize the frame")
        XCTAssertEqual(drawn.height, draft.height, accuracy: 1e-9)
        XCTAssertNotEqual(drawn.left, draft.left, "the frame must actually have moved")

        // ③ …and the canvas is not the photograph: the clamped frame still covers pixels that are
        //    **not** photograph — the `000000` letterbox inside the canvas — and that is allowed.
        //    (196: 画布是硬边界，照片只是「红框」警告。)
        let overLetterbox = controller.frameExceedsPicture(source: Self.source, degrees: angle)
        let layoutAfter = controller.layout(mapping: mapping, source: Self.source, pointScale: 1)
        print("188 ② · after clamp · over the photograph \(overLetterbox)"
              + " · exceedsPicture \(layoutAfter.exceedsPicture)")
        XCTAssertTrue(overLetterbox,
                      "a frame against the canvas' edge covers the letterbox at 5.4° — that is legal")
        XCTAssertTrue(layoutAfter.exceedsPicture, "and the overlay must be told to paint it red")

        // ③ the size rules are untouched: `minimumSpan` and the ratio lock still describe the draft.
        let span = CropTool.minimumSpan(source: Self.source)
        XCTAssertGreaterThanOrEqual(drawn.width, span.width)
        XCTAssertGreaterThanOrEqual(drawn.height, span.height)
        XCTAssertEqual(drawn.width / drawn.height, draft.width / draft.height, accuracy: 1e-9,
                       "a clamp may never reshape the frame")

        // ④ the canvas is still the larger of the two, and the band outside the crop is S0's `0/0/0`
        //    (`RotatedCanvasTests.testOutOfRangeCropRendersABiggerCanvasWithABlackBorder` pins the
        //    pixels; here the geometry that makes them possible): at 5.4° the canvas is bigger than the
        //    crop on both axes, so a crop that leaves it is still inside a canvas of real pixels.
        let pixels = session.edit.geometry
        _ = pixels
        let canvasPixels = CropMath.canvasSize(crop: draft, in: Self.source,
                                              straightenDegrees: angle, quarterTurns: 0,
                                              allowsOutsideSource: true)
        let cropPixels = CropMath.frameSize(draft, in: Self.source, allowsOutsideSource: true)
        print("188 ② · canvas \(canvasPixels) ≥ crop \(cropPixels)")
        XCTAssertGreaterThanOrEqual(canvasPixels.width, cropPixels.width)
        XCTAssertGreaterThanOrEqual(canvasPixels.height, cropPixels.height)
    }

    // MARK: - ③ outputPixels is the canvas

    /// `EditModel.outputPixels` — 「裁剪后尺寸」 — is the canvas the renderer allocates, so it grows with
    /// the straighten and is `outputSize` at every right angle.
    func testTheOutputPixelsAreTheCanvas() {
        var edit = EditModel.neutral
        let upright = edit.geometry.outputPixels(in: Self.source)
        XCTAssertEqual(upright, Self.source, "0°: the canvas *is* the picture, bit for bit")

        edit.geometry.rotationDegrees = 5.4
        let turned = edit.geometry.outputPixels(in: Self.source)
        let canvas = CropMath.canvasSize(crop: edit.geometry.renderCrop(source: Self.source),
                                        in: Self.source, straightenDegrees: 5.4, quarterTurns: 0,
                                        allowsOutsideSource: true)
        print("188 ③ · θ=0 \(upright) · θ=5.4 canvas \(canvas) · outputPixels \(turned)")
        XCTAssertEqual(turned, canvas, "the info bar must report the canvas, not the crop")
        XCTAssertGreaterThan(turned.width, Self.source.width - 1)
        XCTAssertGreaterThan(turned.height, Self.source.height)

        // A quarter turn is not a rotation: the canvas stays the crop's own size (swapped axes).
        edit.geometry.rotationDegrees = 0
        edit.geometry.quarterTurns = 1
        XCTAssertEqual(edit.geometry.outputPixels(in: Self.source),
                       CropMath.frameSize(edit.geometry.renderCrop(source: Self.source),
                                          in: edit.geometry.orientedSource(Self.source),
                                          allowsOutsideSource: true),
                       "90°: 只有真的旋转才扩画布")
        XCTAssertEqual(edit.geometry.outputPixels(in: Self.source),
                       ImageSize(width: Self.source.height, height: Self.source.width))
    }

    // MARK: - ④ θ = 0: every rectangle is the pre-188 one

    /// The reverse gate. At 0° the placement's region is `(window − cropOrigin)/cropSize` — the exact
    /// expression 188 replaced — `canvasBounds` is the canvas, and `maxZoom` is the inscribed level.
    /// The numbers are the ones the pre-188 code printed for the same states (see the lane's
    /// `local/REPORT.md`), asserted to ±1e-12: **any** drift here is a regression, not a tolerance.
    func testAtZeroDegreesEveryRectIsUnchanged() {
        let f = framing(degrees: 0)
        let fit = f.framePlacement(of: f.mapping(of: .fit))
        print(String(format: "188 ④ · 0° fit · region u[%.12f…%.12f] v[%.12f…%.12f] · rect u0 %.12f du %.12f",
                     fit.region.left, fit.region.right, fit.region.top, fit.region.bottom,
                     Double(fit.rect.u0), Double(fit.rect.du)))
        // The whole source at 适应 with no angle: the texture is the picture, and the 4:3 picture in a
        // 1.4 canvas is letterboxed by 33.33 pt on each side — the pre-188 numbers.
        XCTAssertEqual(fit.region, .full)
        XCTAssertEqual(Double(fit.rect.u0), 33.3333 / 1400, accuracy: 1e-6)
        XCTAssertEqual(Double(fit.rect.du), 1333.333 / 1400, accuracy: 1e-6)
        XCTAssertEqual(Double(fit.rect.v0), 0, accuracy: 1e-12)
        XCTAssertEqual(Double(fit.rect.dv), 1, accuracy: 1e-12)

        // A 2:1 window in the middle: the region is the old `(window − crop)/crop`, unchanged.
        let zoomed = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2250)
        let p = f.framePlacement(of: f.mapping(of: zoomed))
        let window = f.windowSize(of: zoomed)
        let centre = f.windowCenter(of: zoomed)
        let old = CropRect(left: (centre.x - window.width / 2 - f.cropOriginX) / f.cropWidthPixels,
                           top: (centre.y - window.height / 2 - f.cropOriginY) / f.cropHeightPixels,
                           right: (centre.x + window.width / 2 - f.cropOriginX) / f.cropWidthPixels,
                           bottom: (centre.y + window.height / 2 - f.cropOriginY) / f.cropHeightPixels)
        print(String(format: "188 ④ · 0° 2:1 · region u[%.12f…%.12f] v[%.12f…%.12f]",
                     p.region.left, p.region.right, p.region.top, p.region.bottom))
        XCTAssertEqual(p.region.left, old.left, accuracy: 1e-12)
        XCTAssertEqual(p.region.top, old.top, accuracy: 1e-12)
        XCTAssertEqual(p.region.right, old.right, accuracy: 1e-12)
        XCTAssertEqual(p.region.bottom, old.bottom, accuracy: 1e-12)

        // `maxZoom` — the workspace's inscribed level — is the same function it always was.
        let canvasSize = CGSize(width: 1400, height: 1000)
        let frame = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let maxZoom = CropWorkspaceLayout.maxZoom(canvas: canvasSize, frame: frame)
        print(String(format: "188 ④ · maxZoom %.12f", maxZoom))
        XCTAssertEqual(maxZoom, min(1400.0 / 3000, 1000.0 / 2000), accuracy: 1e-12)

        // `canvasBounds` at 0° fit: the visible canvas in frame coordinates — the 3:2 source fitted by
        // width in a 1.4 canvas leaves a 1/28 band top and bottom, and nothing here moved it.
        let source = ImageSize(width: 3000, height: 2000)
        let own = framing(degrees: 0, source: source)
        let bounds = CropWorkspaceLayout.canvasBounds(mapping: own.mapping(of: .fit), source: source)
        print(String(format: "188 ④ · canvasBounds l %.12f t %.12f r %.12f b %.12f",
                     bounds.left, bounds.top, bounds.right, bounds.bottom))
        XCTAssertEqual(bounds.left, 0, accuracy: 1e-12)
        XCTAssertEqual(bounds.right, 1, accuracy: 1e-12)
        XCTAssertEqual(bounds.top, -1.0 / 28, accuracy: 1e-9,
                       "the letterbox band above the picture, in frame units")
        XCTAssertEqual(bounds.bottom, 1 + 1.0 / 28, accuracy: 1e-9)
    }
}
