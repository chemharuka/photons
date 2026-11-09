import XCTest
import Metal
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// **307 — the two canvases** (`CanvasRole`), measured.
///
/// The user's report (2026-11-09): 「0F 遮罩没有按照旋转后的源画布大小，按照的是最初照片的大小，导致
/// 照片存在裁切；裁剪框的限位变成了照片像素，而不是源画布」. The contract this file pins:
///
///   · `.export` — 301: the canvas *is* the crop frame. Untouched here (the golden hashes in
///     `RenderTests` / `CropMathTests` are the authority; §5 of this file re-measures the shape).
///   · `.document` — the turned **whole photograph's AABB**: `000000` in the corners the picture does
///     not cover, `0F0F0F` only *outside* the box, and the crop frame free to sit in those corners.
///
/// The five numbers the diagnosis asked for at θ = 0 are printed verbatim by
/// `testThetaZeroIsTheFrameAndTheInsetIsZero`: `canvasSize == frameSize` and `canvasInset == (0, 0)`
/// for the export role, while the document role's inset is `(canvas − frame)/2`. That is what makes
/// `CropWorkspaceLayout.entry`'s new number the **AABB's** fit rather than a doubled canvas.
final class CanvasRole307Tests: XCTestCase {

    private let source = ImageSize(width: 480, height: 320)

    // MARK: - fixtures

    private func rampImage(_ width: Int, _ height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = 0.6 * Double(x) / Double(max(width - 1, 1))
                    + 0.4 * Double(y) / Double(max(height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "307-canvas-role")
    }

    private func geometry(_ degrees: Double, crop: CropRect = .full,
                          source: ImageSize? = nil) -> CropGeometry {
        var g = GeometryGroup.identity
        g.rotationDegrees = degrees
        g.crop = crop.normalizedRect
        return CropGeometry(geometry: g, source: source ?? self.source)
    }

    private func document(_ degrees: Double, crop: CropRect = .full) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.crop = crop.normalizedRect
        edit.geometry.rotationDegrees = degrees
        edit.geometry.aspectLock = .original
        return edit
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return Double(image.rgba[o]) + Double(image.rgba[o + 1]) + Double(image.rgba[o + 2])
    }

    // MARK: - 1. θ = 0: the export canvas *is* the frame, the inset *is* zero

    /// The five numbers, verbatim, at θ = 0 · crop = (0.25, 0.25, 0.75, 0.75) on the 6000×4000 frame
    /// the `FitToCrop259` re-pin argument turns on. The first two are the invariant: an upright
    /// document must not gain an AABB, or every entry zoom built from it is half of what it should be.
    func testThetaZeroIsTheFrameAndTheInsetIsZero() {
        let src = ImageSize(width: 6000, height: 4000)
        let crop = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        let g = geometry(0, crop: crop, source: src)

        print(String(format: "307 · θ=0 crop=(0.25,0.25,0.75,0.75) · canvasSize %d×%d · frameSize %d×%d"
                     + " · canvasInset(.export) (%.6f, %.6f) · canvasInset(.document) (%.6f, %.6f)"
                     + " · photoExtent %.1f×%.1f · rotatedSourceExtent(entry) %.1f×%.1f",
                     g.canvas.width, g.canvas.height, g.frameSize.width, g.frameSize.height,
                     g.canvasInset(.export).x, g.canvasInset(.export).y,
                     g.canvasInset(.document).x, g.canvasInset(.document).y,
                     g.photoExtent.width, g.photoExtent.height,
                     g.canvasExtent(.document).width, g.canvasExtent(.document).height))

        XCTAssertEqual(g.canvas, g.frameSize, "θ=0: the export canvas must be the crop frame")
        XCTAssertEqual(g.canvasInset(.export).x, 0, accuracy: 1e-12,
                       "θ=0: the export inset must be zero")
        XCTAssertEqual(g.canvasInset(.export).y, 0, accuracy: 1e-12,
                       "θ=0: the export inset must be zero")
        XCTAssertEqual(g.canvas(.export), ImageSize(width: 3000, height: 2000),
                       "θ=0: the crop frame at 1:1")
        XCTAssertEqual(g.photoExtent.width, 6000, accuracy: 1e-9,
                       "θ=0: the document canvas is the photograph, not its AABB")
        XCTAssertEqual(g.canvasExtent(.document).width, 6000, accuracy: 1e-9)
        XCTAssertEqual(g.canvasInset(.document).x, 1500, accuracy: 1e-9,
                       "θ=0: the frame sits (canvas − frame)/2 inside the document canvas")
        XCTAssertEqual(g.canvasInset(.document).y, 1000, accuracy: 1e-9)
    }

    /// The entry zoom is the **document canvas'** fit — and the ratio to the crop-frame fit is exactly
    /// `AABB / frame`, which is what the `FitToCrop259` number moved by. A doubled canvas would give
    /// the square of this ratio; the printed derivation is the evidence.
    func testEntryIsTheDocumentCanvasFitNotADoubledCanvas() {
        let viewport = ImageSize(width: 2560, height: 1600)
        let src = ImageSize(width: 6000, height: 4000)
        let crops = [CropRect.full,
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
                     CropRect(left: 0.45, top: 0.45, right: 0.55, bottom: 0.55)]
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            let layout = CropWorkspaceLayout(source: src, quarterTurns: 0, straighten: degrees,
                                             canvas: CGRect(x: 0, y: 0,
                                                            width: Double(viewport.width),
                                                            height: Double(viewport.height)))
            for crop in crops {
                let entry = layout.entry(crop: crop)
                let g = geometry(degrees, crop: crop, source: src)
                let box = g.canvasExtent(.document)
                let expected = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                                    viewportHeight: Double(viewport.height),
                                                    extent: (box.width, box.height),
                                                    isWholeFrame: crop.coversFrame)
                let cropFit = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                                   viewportHeight: Double(viewport.height),
                                                   extent: (crop.width * 6000, crop.height * 4000),
                                                   isWholeFrame: crop.coversFrame)
                print(String(format: "307 · θ=%.0f° crop=%@ · entry %.6f · AABB fit %.6f"
                             + " · crop-frame fit %.6f · ratio %.4f (AABB/frame = %.4f)",
                             degrees, crop.keyString, entry.entryZoom, expected, cropFit,
                             cropFit == 0 ? 0 : entry.entryZoom / cropFit,
                             (crop.width * 6000) == 0 ? 0 : box.width / (crop.width * 6000)))
                XCTAssertEqual(entry.entryZoom, expected, accuracy: 1e-9,
                               "\(degrees)° · \(crop.keyString): entry is not the document canvas' fit")
            }
        }
    }

    // MARK: - 2. ⑥ the 90 % fit no longer overflows the viewport

    func testTheEntryFitNeverOverflowsTheViewport() {
        let viewport = ImageSize(width: 1200, height: 800)
        let src = ImageSize(width: 9520, height: 6336)
        for degrees in [0.0, 9.0, 15.0] {
            let layout = CropWorkspaceLayout(source: src, quarterTurns: 0, straighten: degrees,
                                             canvas: CGRect(x: 0, y: 0,
                                                            width: Double(viewport.width),
                                                            height: Double(viewport.height)))
            let entry = layout.entry(crop: .full)
            // The number 301b produced: [picture = AABB · cropFit] — the shipped 78.9 / 173.8 px.
            let g = geometry(degrees, source: src)
            let cropFit = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                               viewportHeight: Double(viewport.height),
                                               extent: (Double(src.width), Double(src.height)),
                                               isWholeFrame: true)
            let oldHeight = g.canvasExtent(.document).height * cropFit
            let oldOverflow = max(0, oldHeight - Double(viewport.height))
            let newOverflow = max(0, entry.picture.height - Double(viewport.height))
            let newWide = max(0, entry.picture.width - Double(viewport.width))
            print(String(format: "307 · ⑥ θ=%.0f° · entry picture %.2f×%.2f · old %.2f×%.2f"
                         + " (overflow %.2f px) · new overflow %.2f px (x %.2f)",
                         degrees, entry.picture.width, entry.picture.height,
                         g.canvasExtent(.document).width * cropFit, oldHeight, oldOverflow,
                         max(newOverflow, newWide), newWide))
            XCTAssertLessThanOrEqual(newOverflow, 1.0,
                                     "θ=\(degrees): the 90 % fit still overflows the viewport")
            XCTAssertLessThanOrEqual(newWide, 1.0,
                                     "θ=\(degrees): the 90 % fit still overflows the viewport")
            XCTAssertEqual(max(newOverflow, newWide), 0.0, accuracy: 1e-9,
                           "θ=\(degrees): a 90 % fit leaves 10 % of the viewport on the long axis")
        }
    }

    // MARK: - 3. ① no photograph pixel falls outside the document canvas

    func testNoPhotographPixelFallsOutsideTheDocumentCanvas() {
        for degrees in [0.0, 9.0, 15.0] {
            let g = geometry(degrees)
            let box = g.canvasExtent(.document)
            let inset = g.canvasInset(.document)
            let m = CropGeometry.RotationMatrix(degrees: degrees)
            var lost = 0, total = 0
            let n = 400
            for j in 0..<n {
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n) * Double(source.width)
                    let v = (Double(j) + 0.5) / Double(n) * Double(source.height)
                    let p = m.apply(x: u - Double(source.width) / 2,
                                    y: v - Double(source.height) / 2)
                    let x = p.x + box.width / 2, y = p.y + box.height / 2
                    total += 1
                    if x < 0 || x > box.width || y < 0 || y > box.height { lost += 1 }
                    _ = inset
                }
            }
            // The 301 canvas (= the crop frame) for the same document, for the printed comparison.
            var oldLost = 0
            let old = g.canvasExtent(.export)
            for j in 0..<n {
                for i in 0..<n {
                    let u = (Double(i) + 0.5) / Double(n) * Double(source.width)
                    let v = (Double(j) + 0.5) / Double(n) * Double(source.height)
                    let p = m.apply(x: u - Double(source.width) / 2,
                                    y: v - Double(source.height) / 2)
                    let x = p.x + old.width / 2, y = p.y + old.height / 2
                    if x < 0 || x > old.width || y < 0 || y > old.height { oldLost += 1 }
                }
            }
            let fraction = total == 0 ? 0 : Double(lost) / Double(total)
            print(String(format: "307 · ① θ=%.0f° · outside document canvas %.2f %%"
                         + " (301 export canvas: %.2f %%) · box %.1f×%.1f · photo %.0f×%.0f",
                         degrees, fraction * 100, Double(oldLost) / Double(total) * 100,
                         box.width, box.height, Double(source.width), Double(source.height)))
            XCTAssertEqual(fraction, 0, accuracy: 0,
                           "θ=\(degrees): a photograph pixel is outside the document canvas")
        }
    }

    // MARK: - 4. ② the two blacks, on one 1200×800 · 15° frame

    func testDocumentCanvasIs000000InsideAndTheBackdropOutside() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let viewport = ImageSize(width: 1200, height: 800)
        let viewportBox = self.source
        let graph = try RenderGraph(input: RenderInput(image: rampImage(viewportBox.width,
                                                                        viewportBox.height),
                                                       identity: "307-document-canvas"))
        let degrees = 15.0
        let g = geometry(degrees)
        let box = g.canvas(.document)
        // The canvas the crop workspace asks for: the AABB at the 90 % fit that frames it.
        let zoom = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                        viewportHeight: Double(viewport.height),
                                        extent: (Double(box.width), Double(box.height)),
                                        isWholeFrame: true)
        let result = try graph.render(document(degrees), options: RenderOptions(
            canvas: viewport, canvasRole: .document, scale: zoom, useCache: false,
            wantsPixels: false, neverUpscalesContent: true))
        let texture = try XCTUnwrap(result.output, "no render")
        defer { graph.recycle(output: texture) }

        print("307 · ② θ=\(degrees) · canvas requested \(viewport.width)×\(viewport.height)"
              + " · render canvas \(result.canvas.width)×\(result.canvas.height)"
              + " · drawnRect \(result.drawnRect) · canvasRect \(result.canvasRect)"
              + " · AABB \(box.width)×\(box.height) at zoom \(String(format: "%.4f", zoom))")

        XCTAssertEqual(result.canvas, viewport)
        XCTAssertLessThanOrEqual(abs(result.drawnRect.width - Int((Double(box.width) * zoom).rounded())), 1)
        XCTAssertLessThanOrEqual(abs(result.drawnRect.height - Int((Double(box.height) * zoom).rounded())), 1)

        let presenter = try CanvasPresenter(device: device)
        let presented = try present(device, width: viewport.width, height: viewport.height)
        XCTAssertTrue(presenter.renderForTest(texture, window: .whole,
                                              picture: result.drawnRect,
                                              into: presented, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        // Inside the canvas, outside the photograph → the render wrote `float4(0)` there, which the
        // present pass transfers as 0/0/0 (opaque black, not the matte).
        let r = result.drawnRect
        let corners = [(r.x + 2, r.y + 2), (r.maxX - 3, r.y + 2),
                       (r.x + 2, r.maxY - 3), (r.maxX - 3, r.maxY - 3)]
        var blackInside = 0
        for (x, y) in corners {
            XCTAssertEqual(pixel(presented, x, y), [0, 0, 0],
                           "canvas corner (\(x),\(y)) is not 000000")
            blackInside += 1
        }
        // Outside the canvas → the pass' clear colour, i.e. the **current** backdrop stop (315: read
        // the constant, never a literal — a change of default is not a change of this invariant).
        let matte = Int(CanvasPresenter.CanvasMatte.eightBitValue)
        let mattePixel = [UInt8(matte), UInt8(matte), UInt8(matte)]
        var outside = 0
        for (x, y) in [(2, 2), (viewport.width - 3, 2), (2, viewport.height - 3),
                       (viewport.width - 3, viewport.height - 3)] where
            x < r.x || x >= r.maxX || y < r.y || y >= r.maxY {
            XCTAssertEqual(Int(pixel(presented, x, y)[0]), matte,
                           "outside the canvas (\(x),\(y)) is not the backdrop")
            outside += 1
        }
        // The photograph still reaches the canvas' own edge — a turned rectangle touches its AABB at
        // four points, so scan the top row for the tangency instead of assuming it is at the middle
        // (that assumption is what a "canvas = photo rectangle" reading would make).
        var topRowPhoto = 0
        for x in r.x..<r.maxX where Int(pixel(presented, x, r.y + 1)[0]) > 20 { topRowPhoto += 1 }
        print("307 · ② photograph texels on the canvas' top row: \(topRowPhoto)")
        XCTAssertGreaterThan(topRowPhoto, 0, "the photograph never reaches the canvas' top edge")
        // …and the canvas' centre is photograph, not background.
        XCTAssertGreaterThan(Int(pixel(presented, (r.x + r.maxX) / 2,
                                       (r.y + r.maxY) / 2)[0]), 20,
                             "the canvas' centre is not photograph")

        // Count the whole surface: every non-photograph pixel inside the canvas is exactly 0, every
        // pixel outside it exactly the backdrop — i.e. the two blacks did not swap.
        var zeroInside = 0, matteOutside = 0, wrongInside = 0, wrongOutside = 0
        for y in 0..<viewport.height {
            for x in 0..<viewport.width {
                let p = pixel(presented, x, y)
                let inside = x >= r.x && x < r.maxX && y >= r.y && y < r.maxY
                if inside {
                    if p == [0, 0, 0] { zeroInside += 1 } else if p == mattePixel { wrongInside += 1 }
                } else if p == mattePixel { matteOutside += 1 } else { wrongOutside += 1 }
            }
        }
        print("307 · ② 000000 inside \(zeroInside) · backdrop \(matte) outside \(matteOutside)"
              + " · stray backdrop inside \(wrongInside) · stray !backdrop outside \(wrongOutside)")
        XCTAssertEqual(wrongInside, 0, "the matte leaked inside the canvas")
        XCTAssertEqual(wrongOutside, 0, "the canvas' black leaked outside the box")
        XCTAssertGreaterThan(zeroInside, 0)
        XCTAssertGreaterThan(matteOutside, 0)
    }

    // MARK: - 6. ③ the frame may enter 000000, never the 0F outside the canvas

    /// Three angles, on the shipped controller: a frame whose corner sits in the black the straighten
    /// opened is left **exactly** where it is (no inscription back to the photograph), while a frame
    /// that leaves the canvas is pulled back in — the user's 「裁剪框可以拖到 00 的文档画布里，不能拖到
    /// 0F 的背景遮罩里」.
    @MainActor
    func testTheFrameMayEnterTheBlackCornersButNotLeaveTheCanvas() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-307-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let (session, _) = try CropUITestSupport.makeSession(in: workDir, width: 1200, height: 800)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        XCTAssertFalse(controller.clampsToRotatedFrame,
                       "307: the interaction frame is not inscribed in the photograph any more")

        let source = ImageSize(width: 1200, height: 800)
        for degrees in [9.0, 15.0, 45.0] {
            let legal = CropGeometry.documentCanvasCropRect(in: source, degrees: degrees)
            let mapping = LoupeFraming(viewport: ImageSize(width: 900, height: 600),
                                       sourceWidth: 1200, sourceHeight: 800,
                                       crop: .full, straightenDegrees: degrees,
                                       canvasRole: .document).mapping(of: .fit)

            // A 20 %-wide frame whose top-left corner sits just inside the canvas' corner: at a
            // straighten that corner is *outside the photograph* (it is one of the black triangles).
            let corner = CropRect(left: legal.left + 0.005, top: legal.top + 0.005,
                                  right: legal.left + 0.205, bottom: legal.top + 0.205)
            controller.draft = CropToolController.Draft(crop: corner, straighten: degrees,
                                                        lock: .original)
            XCTAssertTrue(controller.frameExceedsPicture(source: source),
                          "\(degrees)°: the fixture must sit in the black corner")
            XCTAssertEqual(controller.effectiveCrop(source: source), corner,
                           "\(degrees)°: the frame was pulled back onto the photograph")
            let stillThere = controller.clampToView(mapping: mapping, source: source)
            let kept = controller.draft.crop
            print(String(format: "307 · ③ %.0f° · corner frame l %.4f t %.4f r %.4f b %.4f"
                         + " · legal l %.4f t %.4f r %.4f b %.4f · moved %@",
                         degrees, kept.left, kept.top, kept.right, kept.bottom,
                         legal.left, legal.top, legal.right, legal.bottom,
                         stillThere ? "yes" : "no"))
            XCTAssertEqual(kept, corner,
                           "\(degrees)°: clamping moved a frame that is already inside the canvas")

            // Now push it out: the right/bottom edges past the canvas must come back.
            let outside = CropRect(left: legal.right - 0.05, top: legal.bottom - 0.05,
                                   right: legal.right + 0.4, bottom: legal.bottom + 0.4)
            controller.draft = CropToolController.Draft(crop: outside, straighten: degrees,
                                                        lock: .original)
            XCTAssertTrue(controller.clampToView(mapping: mapping, source: source),
                          "\(degrees)°: a frame outside the canvas was not pulled back")
            let clamped = controller.draft.crop
            let eps = 1e-9
            XCTAssertLessThanOrEqual(clamped.right, legal.right + eps,
                                     "\(degrees)°: the frame is still outside the canvas (0F)")
            XCTAssertLessThanOrEqual(clamped.bottom, legal.bottom + eps,
                                     "\(degrees)°: the frame is still outside the canvas (0F)")
            XCTAssertTrue(clamped.left >= legal.left - eps && clamped.top >= legal.top - eps,
                          "\(degrees)°: the frame left the canvas on the low side")
            print(String(format: "307 · ③ %.0f° · pushed out r %.4f b %.4f → clamped r %.4f b %.4f"
                         + " · canvas right %.4f bottom %.4f",
                         degrees, outside.right, outside.bottom, clamped.right, clamped.bottom,
                         legal.right, legal.bottom))
        }
    }

    // MARK: - 7. ④ the shipped 0 → θ inscription leaves the export black-free

    /// `setAngle` is the product path: lifting the straighten from 0° writes the inscribed frame into
    /// the **draft**, so 应用 records exactly that rect. Rendering it through the **export** role must
    /// carry no background at all — measured, on the 480×320 ramp, at 9° / 15° / 45°.
    @MainActor
    func testTheAutoInscribedFrameExportsWithoutABlackCorner() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        _ = device
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-307-inscribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let (session, _) = try CropUITestSupport.makeSession(in: workDir, width: 480, height: 320)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let source = ImageSize(width: 480, height: 320)

        let graph = try RenderGraph(input: RenderInput(image: rampImage(480, 320),
                                                      identity: "307-inscribe"))
        for degrees in [9.0, 15.0, 45.0] {
            controller.draft = CropToolController.Draft(crop: .full, straighten: 0, lock: .original)
            controller.setAngle(uiValue: degrees)
            let drawn = controller.effectiveCrop(source: source)
            let expected = CropMath.clampedToRotatedFrame(.full, in: source, degrees: degrees,
                                                          keepsInsideRotatedFrame: true)
            XCTAssertEqual(drawn.left, expected.left, accuracy: 1e-12,
                           "\(degrees)°: setAngle did not inscribe the draft")
            XCTAssertEqual(controller.draft.crop.right, expected.right, accuracy: 1e-12,
                           "\(degrees)°: the draft does not carry the inscribed rect")

            // The committed document → export render (role .export by default).
            var edit = EditModel.neutral
            // The draft **is** what 应用 writes (`committedGeometry` = the draft's fields with the
            // effective rect, and at `clampsToRotatedFrame == false` that is the draft rect itself).
            edit.geometry = controller.transformSession.geometry
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: true))
            let display = try XCTUnwrap(result.display)
            var black = 0
            for y in 0..<display.height {
                for x in 0..<display.width where luma(display, x, y) <= 1e-3 { black += 1 }
            }
            let fraction = Double(black) / Double(display.width * display.height)
            print(String(format: "307 · ④ %.0f° · export %d×%d · black %.3f %%",
                         degrees, display.width, display.height, fraction * 100))
            XCTAssertEqual(fraction, 0, accuracy: 1e-9,
                           "\(degrees)°: the auto-inscribed export still carries black")
        }
    }

    // MARK: - 8. the two reverse gates

    /// **Gate ①/② — "the canvas is the crop frame".** The same document and camera, rendered with
    /// `.export` (301): the photograph's own AABB is *outside* the canvas, so the 0F matte starts
    /// inside it — the reported 「0F 遮罩按最初照片的大小，照片被裁切」. Under `.document` the matte is
    /// outside the AABB and the corners inside it are `000000`. Flip `canvasRole` back and the
    /// measurement above goes from 0 stray-15-inside to a whole band.
    func testTheRefutationPutsTheBackdropInsideThePhotographWhenTheCanvasIsTheFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let viewport = ImageSize(width: 1200, height: 800)
        let graph = try RenderGraph(input: RenderInput(image: rampImage(source.width, source.height),
                                                      identity: "307-gate-frame"))
        let degrees = 15.0
        let g = geometry(degrees)
        let box = g.canvas(.document)
        let zoom = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                        viewportHeight: Double(viewport.height),
                                        extent: (Double(box.width), Double(box.height)),
                                        isWholeFrame: true)
        let result = try graph.render(document(degrees), options: RenderOptions(
            canvas: viewport, canvasRole: .export, scale: zoom, useCache: false,
            wantsPixels: false, neverUpscalesContent: true))
        let texture = try XCTUnwrap(result.output, "no render")
        defer { graph.recycle(output: texture) }
        let presenter = try CanvasPresenter(device: device)
        let presented = try present(device, width: viewport.width, height: viewport.height)
        XCTAssertTrue(presenter.renderForTest(texture, window: .whole,
                                              picture: result.drawnRect,
                                              into: presented, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        // The AABB's rectangle in the viewport, at the same zoom and the same centre.
        let matte = Int(CanvasPresenter.CanvasMatte.eightBitValue)
        let mattePixel = [UInt8(matte), UInt8(matte), UInt8(matte)]
        let ox = (Double(viewport.width) - Double(box.width) * zoom) / 2
        let oy = (Double(viewport.height) - Double(box.height) * zoom) / 2
        var matteInsideTheAABB = 0
        var photoTexels = 0
        for y in 0..<viewport.height {
            for x in 0..<viewport.width {
                let inAABB = Double(x) >= ox && Double(x) < ox + Double(box.width) * zoom
                    && Double(y) >= oy && Double(y) < oy + Double(box.height) * zoom
                guard inAABB else { continue }
                let p = pixel(presented, x, y)
                if p == mattePixel { matteInsideTheAABB += 1 }
                if p != [0, 0, 0] && p != mattePixel { photoTexels += 1 }
            }
        }
        print("307 · gate① · export role at 15°: backdrop \(matte) inside the photograph's AABB = "
              + "\(matteInsideTheAABB) px · photograph texels drawn = \(photoTexels)")
        XCTAssertGreaterThan(matteInsideTheAABB, 0,
                             "the refutation must show the backdrop band inside the AABB — it is the report")
        XCTAssertEqual(result.drawnRect, ImageRect(x: 360, y: 240, width: 480, height: 320),
                       "the export canvas is the 480×320 crop frame, not the 547×434 AABB")
    }

    /// **Gate ③ — 301's inscribed clamp.** Turning `clampsToRotatedFrame` back on pulls a frame out of
    /// the black corners onto the photograph, which is the 「限位 = 照片像素」 the user reported. The
    /// shipped value is `false`; the gate shows the assertion above is load-bearing.
    @MainActor
    func testTheRefutationInscribesTheFrameWhenThe301ClampIsOn() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-307-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let (session, _) = try CropUITestSupport.makeSession(in: workDir, width: 1200, height: 800)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let source = ImageSize(width: 1200, height: 800)
        let degrees = 15.0
        let legal = CropGeometry.documentCanvasCropRect(in: source, degrees: degrees)
        let corner = CropRect(left: legal.left + 0.005, top: legal.top + 0.005,
                              right: legal.left + 0.205, bottom: legal.top + 0.205)
        controller.draft = CropToolController.Draft(crop: corner, straighten: degrees,
                                                    lock: .original)
        XCTAssertEqual(controller.effectiveCrop(source: source), corner,
                       "the shipped value must leave the corner frame alone")
        // …now the 301 switch, on the same controller and the same rect.
        controller.clampsToRotatedFrame = true
        let inscribed = controller.effectiveCrop(source: source)
        print(String(format: "307 · gate③ · clampsToRotatedFrame=true · corner l %.4f t %.4f %.4f×%.4f px"
                     + " → l %.4f t %.4f %.4f×%.4f px",
                     corner.left, corner.top, corner.width * 1200, corner.height * 800,
                     inscribed.left, inscribed.top,
                     inscribed.width * 1200, inscribed.height * 800))
        XCTAssertNotEqual(inscribed, corner,
                          "the 301 clamp must pull the frame back — otherwise ③ is not a gate")
        XCTAssertGreaterThan(inscribed.left, corner.left + 0.3,
                             "the 301 clamp must move the frame into the photograph")
        XCTAssertGreaterThan(inscribed.top, corner.top + 0.3)
    }

    // MARK: - 5. export is untouched: the canvas and the inset are 301's

    func testTheExportRoleIsStillTheCropFrame() {
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            for crop in [CropRect.full,
                         CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)] {
                let g = geometry(degrees, crop: crop)
                XCTAssertEqual(g.canvas(.export), g.frameSize,
                               "\(degrees)° \(crop.keyString): the export canvas is the frame")
                XCTAssertEqual(g.canvasInset(.export).x, 0, accuracy: 0)
                XCTAssertEqual(g.canvasInset(.export).y, 0, accuracy: 0)
                XCTAssertEqual(g.canvas(.export), g.canvas,
                               "the stored `.canvas` keeps its 301 meaning")
            }
        }
        // …and the renderer agrees: an export render is allocated at the crop frame at 1:1.
        for degrees in [0.0, 15.0, 45.0] {
            let g = geometry(degrees)
            XCTAssertEqual(g.canvas, CropMath.canvasSize(crop: g.crop, in: source,
                                                         straightenDegrees: degrees,
                                                         quarterTurns: 0,
                                                         allowsOutsideSource: true))
        }
    }

    // MARK: - helpers

    private func present(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: width, height: height,
                                                         mipmapped: false)
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
}
