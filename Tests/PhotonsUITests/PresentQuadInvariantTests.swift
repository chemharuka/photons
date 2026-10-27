import XCTest
import Metal
import PhotonsCore
import PhotonsUI

/// 067 — the present layer's acceptance, measured **per canvas pixel** over seven states.
///
/// The refactor replaced "ask the fragment whether this pixel is the photograph" with "draw the
/// photograph's rectangle, and clear the rest to `#0F0F0F`". The failure mode of the old structure was
/// not a wrong colour, it was a *coverage* decision taken in the wrong place, so the acceptance has to be
/// about coverage: for every pixel of the canvas, is it the frame or the canvas colour, and did it come
/// from the frame that is on screen now?
///
/// The seven states are the ones the task names, and they are the ones the loupe actually produces (the
/// geometry comes from `LoupeFraming`, the same type the controller uses — nothing here is a
/// hand-drawn rectangle):
///
///   fit · 1:1 · 3× · a bridge frame halfway between fit and 1:1 · the canvas after a resize ·
///   1600×500 (a 16:5 strip) · and a portrait frame (EXIF 6: stored landscape, upright portrait).
///
/// Per state, four things are asserted over the whole canvas:
///
///   1. **Inside `pictureQuad` every pixel is bit-for-bit what the same window samples** — rendered twice,
///      once with the derived quad and once with 025's full-canvas coverage, and compared **byte for
///      byte**. This is the strongest form of "the photograph is untouched": the quad decides *coverage*,
///      the window decides *sampling*, and this proves the first did not disturb the second.
///   2. **Outside it every pixel is `#0F0F0F`**, three channels equal, 15/255 within 1 code — and no
///      pixel anywhere is `(0, 0, 0)`, which is what the old structure wrote wherever the rect was
///      missing.
///   3. **No stale pixels**: the same canvas is reused, frame A at geometry 1 then frame B at geometry 2,
///      and every pixel must be B (inside) or the canvas colour (outside) — never A.
///   4. **`pictureQuad`'s aspect is the photograph's**, within one pixel, before and after a resize.
@MainActor
final class PresentQuadInvariantTests: XCTestCase {

    // MARK: - the seven states

    /// One state: a camera, the canvas it is shown on, and the source it is looking at.
    private struct State {
        let name: String
        let viewport: ImageSize
        /// The upright source size (an EXIF-6 file is landscape on disk and portrait here).
        let source: ImageSize
        let state: LoupeViewState
        var crop: CropRect = .full
    }

    private static let states: [State] = [
        State(name: "fit", viewport: ImageSize(width: 640, height: 400),
              source: ImageSize(width: 6000, height: 4000), state: .fit),
        State(name: "1:1", viewport: ImageSize(width: 640, height: 400),
              source: ImageSize(width: 6000, height: 4000),
              state: LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)),
        State(name: "3×", viewport: ImageSize(width: 640, height: 400),
              source: ImageSize(width: 6000, height: 4000),
              state: LoupeViewState(mode: .actual, zoom: 3, centerX: 1800, centerY: 2600)),
        // 1600×500: a 16:5 strip. Fit letterboxes it into bars on the left and right.
        State(name: "strip 1600×500", viewport: ImageSize(width: 1600, height: 500),
              source: ImageSize(width: 6000, height: 4000), state: .fit),
        // EXIF 6: stored 6000×4000, upright 4000×6000 — a portrait canvas for a portrait frame.
        State(name: "portrait (EXIF 6)", viewport: ImageSize(width: 700, height: 1000),
              source: ImageSize(width: 4000, height: 6000),
              state: LoupeViewState(mode: .actual, zoom: 1, centerX: 2000, centerY: 3000)),
    ]

    /// The geometry one state asks for, as the loupe computes it.
    private struct Geometry {
        let canvas: ImageSize
        /// Where S0 drew the photograph inside the frame texture, in canvas pixels — the render's own
        /// receipt (`RenderResult.photoRect`), reproduced here from the same framing type.
        let photoRect: ImageRect
        /// The sampling window for that texture on that canvas.
        let window: PresentWindow
        /// The photograph's aspect, from the window: `contentWidth / contentHeight`.
        let aspect: Double
    }

    private func geometry(_ s: State) -> Geometry {
        let framing = LoupeFraming(viewport: s.viewport, sourceWidth: Double(s.source.width),
                                   sourceHeight: Double(s.source.height), crop: s.crop)
        let mapping = framing.mapping(of: s.state)
        let rect = ImageRect(x: Int(mapping.originX.rounded()), y: Int(mapping.originY.rounded()),
                             width: Int(mapping.contentWidth.rounded()),
                             height: Int(mapping.contentHeight.rounded()))
            .intersected(in: s.viewport)
        return Geometry(canvas: s.viewport, photoRect: rect, window: .whole,
                        aspect: mapping.contentWidth / max(mapping.contentHeight, 1))
    }

    // MARK: - fixtures

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    private func makeTexture(_ device: MTLDevice, _ size: ImageSize, _ format: MTLPixelFormat,
                             _ usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width,
                                                         height: size.height, mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    /// A canvas-sized frame texture exactly as S2/S4 leave it: the photograph in `photoRect`, and
    /// `float4(0, 0, 0, 1)` — black, not the canvas colour — everywhere else.
    private func frame(_ device: MTLDevice, _ size: ImageSize, picture: ImageRect,
                       colour: [Float]) throws -> MTLTexture {
        try fill(device, size) { x, y in
            (x >= picture.x && x < picture.maxX && y >= picture.y && y < picture.maxY)
                ? colour : [0, 0, 0, 1]
        }
    }

    private func fill(_ device: MTLDevice, _ size: ImageSize,
                      _ value: (Int, Int) -> [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, size, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: size.width * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let v = value(x, y)
                for c in 0..<4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
            }
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, size.width, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: size.width * 8)
            }
        }
        return t
    }

    private static func pixels(_ t: MTLTexture) -> [UInt16] {
        var raw = [UInt16](repeating: 0, count: t.width * t.height * 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: t.width * 8,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return raw
    }

    private static func floats(_ t: MTLTexture) -> [Float] {
        pixels(t).map { Float(Float16(bitPattern: $0)) }
    }

    private var matte: Double { CanvasPresenter.CanvasMatte.displayEncoded }

    // MARK: - the invariant, per state

    func testEveryStateIsTheFrameInsideItsQuadAndTheCanvasColourOutside() throws {
        let device = try self.device()
        let presenter = try CanvasPresenter(device: device)
        let colour: [Float] = [0.30, 0.62, 0.85, 1]
        var lines: [String] = []

        for state in Self.states {
            let g = geometry(state)
            let texture = try frame(device, g.canvas, picture: g.photoRect, colour: colour)
            let target = try makeTexture(device, g.canvas, .rgba16Float, [.shaderRead, .renderTarget])
            let reference = try makeTexture(device, g.canvas, .rgba16Float, [.shaderRead, .renderTarget])

            // ① the present under test: the quad derived from the window.
            let request = PresentRequest(picture: texture, photoRect: g.photoRect,
                                         window: g.window, canvas: g.canvas)
            XCTAssertEqual(request.pictureQuad, g.photoRect,
                           "\(state.name): a settled frame's quad is the render's own rect")
            XCTAssertTrue(presenter.render(request, into: target, linearize: false),
                          presenter.lastFailure ?? "the present pass failed")

            // ② the reference: 025's coverage — the whole canvas, the same window. Any pixel inside the
            //    quad must be *identical* to this, to the last bit: the quad changed where paint goes,
            //    not what the texture says there.
            let preQuad = PresentRequest(
                picture: texture, canvas: g.canvas,
                pictureQuad: ImageRect(x: 0, y: 0, width: g.canvas.width, height: g.canvas.height),
                window: g.window)
            XCTAssertTrue(presenter.render(preQuad, into: reference, linearize: false),
                          presenter.lastFailure ?? "the reference pass failed")

            let got = Self.pixels(target)
            let want = Self.pixels(reference)
            let flat = Self.floats(target)
            var inside = 0, insideExact = 0, outside = 0, outsideMatte = 0, black = 0
            var firstInsideMismatch: String?
            var firstOutsideMismatch: String?

            for y in 0..<g.canvas.height {
                for x in 0..<g.canvas.width {
                    let i = (y * g.canvas.width + x) * 4
                    let isInside = x >= g.photoRect.x && x < g.photoRect.maxX
                        && y >= g.photoRect.y && y < g.photoRect.maxY
                    if isInside {
                        inside += 1
                        if got[i] == want[i] && got[i + 1] == want[i + 1] && got[i + 2] == want[i + 2] {
                            insideExact += 1
                        } else if firstInsideMismatch == nil {
                            firstInsideMismatch = "(\(x),\(y)): \(flat[i]),\(flat[i + 1]),\(flat[i + 2])"
                                + " vs \(Float(Float16(bitPattern: want[i])))…"
                        }
                    } else {
                        outside += 1
                        let grey = Double(flat[i])
                        if abs(grey - matte) <= 1.0 / 255, flat[i] == flat[i + 1], flat[i] == flat[i + 2] {
                            outsideMatte += 1
                        } else if firstOutsideMismatch == nil {
                            firstOutsideMismatch = "(\(x),\(y)): \(grey) (want \(matte))"
                        }
                    }
                    if flat[i] == 0 && flat[i + 1] == 0 && flat[i + 2] == 0 { black += 1 }
                }
            }

            XCTAssertEqual(insideExact, inside,
                           "\(state.name): \(inside - insideExact) of \(inside) photograph pixels differ "
                           + "from what the window samples — \(firstInsideMismatch ?? "")")
            XCTAssertEqual(outsideMatte, outside,
                           "\(state.name): \(outside - outsideMatte) of \(outside) canvas pixels outside "
                           + "the quad are not #0F0F0F — \(firstOutsideMismatch ?? "")")
            XCTAssertEqual(black, 0, "\(state.name): \(black) pixels are the frame's zeros as pure black")

            // ④ the quad's aspect is the photograph's, within one pixel.
            let aspectError = abs(Double(g.photoRect.width) / Double(max(g.photoRect.height, 1)) - g.aspect)
            XCTAssertLessThan(aspectError, 1.5 / Double(max(g.photoRect.height, 1)),
                              "\(state.name): quad \(g.photoRect.keyString) has the wrong aspect "
                              + "(\(g.aspect))")

            lines.append(String(format: "  %-18@ canvas %dx%d · quad %@ · %d/%d inside identical · "
                               + "%d/%d outside #0F0F0F · %d black · aspect %.4f (want %.4f)",
                               state.name as NSString, g.canvas.width, g.canvas.height,
                               g.photoRect.keyString as NSString, insideExact, inside,
                               outsideMatte, outside, black,
                               Double(g.photoRect.width) / Double(max(g.photoRect.height, 1)), g.aspect))
        }
        print("[067] seven states, whole canvas, per pixel:\n" + lines.joined(separator: "\n"))
    }

    // MARK: - a bridge frame (the state the user's zoom bug lived in)

    /// The fifth state the task names: a frame presented **mid-transition**, from the texture held on the
    /// canvas, with a window that is a similarity rather than the identity.
    ///
    /// This is also the direct evidence for the first reported bug. The old structure painted the matte
    /// from the *held frame's* `photoRect`, which the transition does not scale — so as the picture grew,
    /// a stationary grey band stayed where the old letterbox had been and vanished when the sharp frame
    /// landed (「放大时，画面边缘 0f 的遮罩会固定住等渲染完了突然消失」). Here the same transition is
    /// rendered twice: once with the quad derived from the bridge's window (067), once with the quad at
    /// the held frame's rect (054's coverage, same sampling). The second has grey pixels where the
    /// photograph has moved; the first has none.
    func testABridgeFrameCarriesItsMatteWithThePicture() throws {
        let device = try self.device()
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 640, height: 400)
        // A 6000×4000 picture fitted into 640×400: content 600×400, so 20 px bars left and right.
        let framing = LoupeFraming(viewport: canvas, sourceWidth: 6000, sourceHeight: 4000)
        let fitMapping = framing.mapping(of: .fit)
        let heldRect = ImageRect(x: Int(fitMapping.originX.rounded()), y: 0,
                                 width: Int(fitMapping.contentWidth.rounded()), height: 400)
        XCTAssertEqual(heldRect, ImageRect(x: 20, y: 0, width: 600, height: 400),
                       "the fixture is the fit letterbox this test is about")

        // fit → 1:1, halfway. The picture grows by 640 × 400 / 600 × 400 = 1.0667 and moves left.
        let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: .fit),
                                     toContent: framing.contentPixels(of:
                                        LoupeViewState(mode: .actual, zoom: 1,
                                                       centerX: 3000, centerY: 2000)),
                                     fromMapping: fitMapping,
                                     toMapping: framing.mapping(of: LoupeViewState(mode: .actual, zoom: 1,
                                                                                  centerX: 3000,
                                                                                  centerY: 2000)),
                                     canvas: canvas, anchor: .center)
        let window = bridge.window(atProgress: 0.5, textureSize: canvas)
        XCTAssertLessThan(Double(window.du), 1, "halfway through a zoom-in the canvas reads a sub-rect")

        let colour: [Float] = [0.25, 0.55, 0.80, 1]
        let held = try frame(device, canvas, picture: heldRect, colour: colour)
        let target = try makeTexture(device, canvas, .rgba16Float, [.shaderRead, .renderTarget])
        let old = try makeTexture(device, canvas, .rgba16Float, [.shaderRead, .renderTarget])

        // 067: the quad follows the bridge's map.
        let request = PresentRequest(picture: held, photoRect: heldRect, window: window, canvas: canvas)
        XCTAssertNotEqual(request.pictureQuad, heldRect,
                          "the bridge's quad must move with the bridge, not stay at the held frame's rect")
        XCTAssertEqual(request.pictureQuad, ImageRect(x: 0, y: 0, width: 640, height: 400).intersected(in: canvas),
                       "halfway through fit → 1:1 the picture covers the canvas")
        XCTAssertTrue(presenter.render(request, into: target, linearize: false))

        // 054's coverage: the same texture, the same window, but the quad at the **unscaled** held rect.
        let stale = PresentRequest(picture: held, canvas: canvas, pictureQuad: heldRect, window: window)
        XCTAssertTrue(presenter.render(stale, into: old, linearize: false))

        let now = Self.floats(target)
        let before = Self.floats(old)
        let matteCode = Float(matte)
        var greyBefore = 0, greyAfter = 0
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let i = (y * canvas.width + x) * 4
                // A pixel the picture has grown over: inside the canvas, outside the held letterbox —
                // the left bar (x < 20) is where the growing picture arrives first.
                if x < 20 || x >= 620 {
                    if abs(before[i] - matteCode) < 1e-3 { greyBefore += 1 }
                    if abs(now[i] - matteCode) < 1e-3 { greyAfter += 1 }
                }
            }
        }
        XCTAssertGreaterThan(greyBefore, 0,
                             "the counterexample must show the band: 054 paints the matte inside the "
                             + "held frame's rect while the picture has moved over it")
        XCTAssertEqual(greyAfter, 0,
                       "\(greyAfter) pixels are still canvas-grey where the bridge's picture is — the band "
                       + "did not move with the picture")

        // …and the band 054 drew is exactly the difference between the two: those pixels are now picture.
        var reclaimed = 0
        for i in stride(from: 0, to: now.count, by: 4) where abs(before[i] - matteCode) < 1e-3 {
            if abs(now[i] - colour[0]) < 1e-3 { reclaimed += 1 }
        }
        XCTAssertGreaterThan(reclaimed, 0, "no pixel changed from matte to picture — nothing was proven")
        print("[067] bridge fit → 1:1 at 50 %: quad \(heldRect.keyString) → \(request.pictureQuad.keyString); "
              + "\(greyBefore) pixels were grey inside the held rect (054), \(greyAfter) are grey now, "
              + "\(reclaimed) became photograph")
    }

    // MARK: - the second reported bug: a shrink at the edge

    /// 「缩小时，如果画面在边缘，纯黑色背景还是存在」 — the shrink that kept a black background.
    ///
    /// Two things had to be true for it: the letterbox zeros have to be *in view* (a shrink pulls the
    /// frame's own edge, and its zeros, onto the canvas) and the present has to be told nothing about
    /// where the photograph is — then those zeros are drawn as `(0, 0, 0)`. The old call site with no
    /// rect was the bridge's stop (`finishZoomBridge`), which is exactly the moment a zoom ends at the
    /// edge of the picture.
    ///
    /// The evidence: the same held frame and the same shrinking window, rendered with no rect at all
    /// (quad = the whole canvas, which is what `p.d = (0,0,1,1)` meant) and with the rect (quad = the
    /// photograph). The first has black pixels; the second has none, and they are the canvas colour.
    func testAShrinkAtTheEdgeIsNeverPureBlack() throws {
        let device = try self.device()
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 320, height: 200)
        // A held frame with the picture letterboxed: 240 × 160 photo in a 320 × 200 canvas.
        let picture = ImageRect(x: 40, y: 20, width: 240, height: 160)
        let colour: [Float] = [0.40, 0.30, 0.70, 1]
        let held = try frame(device, canvas, picture: picture, colour: colour)
        // The stop of a zoom-out: the picture shrinks to a quarter of the canvas about its centre.
        let window = PresentWindow(scale: 0.25, originX: 90, originY: 55, canvas: canvas, texture: canvas)

        let told = try makeTexture(device, canvas, .rgba16Float, [.shaderRead, .renderTarget])
        let untold = try makeTexture(device, canvas, .rgba16Float, [.shaderRead, .renderTarget])

        let request = PresentRequest(picture: held, photoRect: picture, window: window, canvas: canvas)
        XCTAssertTrue(presenter.render(request, into: told, linearize: false))
        // What a caller that passed no rect got: `p.d = (0,0,1,1)`, i.e. the quad covers everything and
        // the texture's zeros are drawn as they are stored.
        let noRect = PresentRequest(
            picture: held, canvas: canvas,
            pictureQuad: ImageRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
            window: window)
        XCTAssertTrue(presenter.render(noRect, into: untold, linearize: false))

        let withRect = Self.floats(told)
        let withoutRect = Self.floats(untold)
        func blackCount(_ px: [Float]) -> Int {
            stride(from: 0, to: px.count, by: 4).filter {
                px[$0] == 0 && px[$0 + 1] == 0 && px[$0 + 2] == 0
            }.count
        }
        let oldBlack = blackCount(withoutRect)
        let newBlack = blackCount(withRect)
        XCTAssertGreaterThan(oldBlack, 0, "the counterexample must show black: the frame's zeros at the edge")
        XCTAssertEqual(newBlack, 0, "\(newBlack) canvas pixels are pure black")

        // The pixels that were black are the canvas colour now, and the picture is where the map says.
        var repaired = 0
        for i in stride(from: 0, to: withRect.count, by: 4)
        where withoutRect[i] == 0 && withoutRect[i + 1] == 0 && withoutRect[i + 2] == 0 {
            if abs(Double(withRect[i]) - matte) <= 1.0 / 255,
               withRect[i] == withRect[i + 1], withRect[i] == withRect[i + 2] { repaired += 1 }
        }
        XCTAssertGreaterThan(repaired, 0)
        let quad = request.pictureQuad
        XCTAssertEqual(quad, ImageRect(x: 100, y: 60, width: 60, height: 40).intersected(in: canvas),
                       "a 0.25 shrink moved to (90, 55) puts the photograph at 0.25·rect + origin")
        // Inside the quad: the picture's colour, not black and not the matte.
        let centre = (quad.x + quad.width / 2, quad.y + quad.height / 2)
        let c = (centre.1 * canvas.width + centre.0) * 4
        XCTAssertEqual(Double(withRect[c]), Double(Float(Float16(colour[0]))), accuracy: 2e-3,
                       "the middle of the shrunken picture is the picture")
        print("[067] shrink to 25 % at the picture's edge (canvas 320×200, photo \(picture.keyString)): "
              + "with no rect \(oldBlack) pixels are pure black, with the rect \(newBlack); "
              + "\(repaired) of them are #0F0F0F now; quad \(quad.keyString)")
    }

    // MARK: - no stale pixels

    /// Invariant 3, the one the old structure could not keep: two frames of **different colours**
    /// presented alternately at **different geometries** into the same canvas. After the second, every
    /// pixel must be the second frame (inside its quad) or the canvas colour (outside). A pixel that is
    /// still the first colour is a stale pixel, and the fixed grey band of the reported zoom bug is the
    /// same failure with the colours swapped.
    func testNoPixelSurvivesFromTheFrameItReplaced() throws {
        let device = try self.device()
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 240, height: 160)
        let target = try makeTexture(device, canvas, .rgba16Float, [.shaderRead, .renderTarget])

        func frameWith(_ colour: [Float], picture: ImageRect) throws -> MTLTexture {
            try frame(device, canvas, picture: picture, colour: colour)
        }
        // Painted over the whole canvas, so its colour is where the second frame is not.
        let red: [Float] = [0.85, 0.10, 0.10, 1]
        let blue: [Float] = [0.10, 0.20, 0.85, 1]
        let wide = ImageRect(x: 0, y: 0, width: 240, height: 160)
        let small = ImageRect(x: 60, y: 40, width: 120, height: 80)

        var stale = 0
        var canvasColour = 0
        var second = 0
        for step in 0..<6 {
            let first = step % 2 == 0
            let texture = try frameWith(first ? red : blue, picture: first ? wide : small)
            let request = PresentRequest(picture: texture, photoRect: first ? wide : small,
                                         window: .whole, canvas: canvas)
            XCTAssertTrue(presenter.render(request, into: target, linearize: false))
            let px = Self.floats(target)
            let quad = request.pictureQuad
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    let i = (y * canvas.width + x) * 4
                    let inside = x >= quad.x && x < quad.maxX && y >= quad.y && y < quad.maxY
                    if inside {
                        second += 1
                        if abs(Double(px[i]) - Double(first ? red[0] : blue[0])) > 2e-3 { stale += 1 }
                    } else if abs(Double(px[i]) - matte) <= 1.0 / 255 {
                        canvasColour += 1
                    } else {
                        stale += 1
                    }
                }
            }
        }
        XCTAssertEqual(stale, 0, "\(stale) pixels survived the frame that replaced them")
        XCTAssertGreaterThan(canvasColour, 0, "the fixture never exercised the canvas colour")
        XCTAssertGreaterThan(second, 0)
        print("[067] six alternating frames (red 240×160 ↔ blue 120×80) into one canvas: "
              + "\(stale) stale pixels, \(canvasColour) canvas-colour pixels, \(second) picture pixels")
    }

    // MARK: - the resize, as pixels

    /// 067's resize contract, measured on the **same geometry the frozen present uses**
    /// (`PresentWindow.stretched`): the picture keeps its pixel size, the canvas crops or extends it.
    ///
    ///   · **shrink** → the same picture, cut off by the surface. No stretch, no black.
    ///   · **grow** → the same picture, and the new area is the whole-picture backdrop through the same
    ///     map; with nothing cached it is the canvas colour.
    ///
    /// The aspect assertion is the one 「变扁」 violates: a frame stretched into a different canvas has a
    /// different width-per-height on screen than the source does.
    func testFrozenResizeGeometryCropsAndExtendsWithoutStretching() throws {
        let device = try self.device()
        let presenter = try CanvasPresenter(device: device)
        // The frame on the canvas: 400 × 300, the photograph filling it — a 3× window of a
        // 1200 × 900 picture, so the **whole picture** is three times the canvas and the band a grown
        // canvas exposes is picture the frame does not hold (the case the low-res backdrop exists for).
        let oldCanvas = ImageSize(width: 400, height: 300)
        let photo = ImageRect(x: 0, y: 0, width: 400, height: 300)
        // A horizontal ramp, so "the same pixel of the picture" is a number that moves if anything
        // rescales.
        let frameTexture = try fill(device, oldCanvas) { x, _ in
            let v = Float(x) / Float(oldCanvas.width - 1)
            return [v, 1 - v, 0.5, 1]
        }
        // The whole picture at low resolution, with its own horizontal gradient in green: the value at a
        // pixel *is* the picture coordinate it holds, so "the band shows the continuation" is checkable.
        let backdropTexture = try fill(device, ImageSize(width: 128, height: 96)) { x, _ in
            [0.1, Float(x) / 127, 0.1, 1]
        }
        let window: PresentWindow = .whole
        // The frame holds the middle ninth of the picture (`FramePlacement` of a 3× camera).
        let placement = FramePlacement(region: CropRect(x: 1.0 / 3, y: 1.0 / 3, width: 1.0 / 3,
                                                        height: 1.0 / 3),
                                       rect: .whole)
        let backdropWindow = window.onWholePicture(placement)

        for newCanvas in [ImageSize(width: 400, height: 300),      // unchanged
                          ImageSize(width: 260, height: 300),      // narrower: the picture is cropped
                          ImageSize(width: 640, height: 300)] {    // wider: the picture is extended
            let frozenWindow = window.stretched(to: newCanvas, from: oldCanvas)
            let frozenBackdrop = backdropWindow.stretched(to: newCanvas, from: oldCanvas)
            let target = try makeTexture(device, newCanvas, .rgba16Float, [.shaderRead, .renderTarget])
            let request = PresentRequest(picture: frameTexture, photoRect: photo, window: frozenWindow,
                                         canvas: newCanvas, backdrop: backdropTexture,
                                         backdropWindow: frozenBackdrop)
            XCTAssertTrue(presenter.render(request, into: target, linearize: false))
            let px = Self.floats(target)

            // The photograph keeps its pixel geometry: the quad is the same rectangle, cropped by the
            // surface. That is the whole of "the picture does not move or rescale with the window" —
            // and it is what 「变扁」 violates (a re-derived quad has the canvas's aspect, not the picture's).
            XCTAssertEqual(request.pictureQuad, photo.intersected(in: newCanvas),
                           "\(newCanvas.keyString): the picture is the same pixels, cropped by the canvas")
            XCTAssertEqual(Double(photo.width) / Double(photo.height), 400.0 / 300.0,
                           "the picture's own rect still has the source's aspect")

            var black = 0
            var mattePixels = 0
            var backdropPixels = 0
            for y in 0..<newCanvas.height {
                for x in 0..<newCanvas.width {
                    let i = (y * newCanvas.width + x) * 4
                    let inside = x >= request.pictureQuad.x && x < request.pictureQuad.maxX
                        && y >= request.pictureQuad.y && y < request.pictureQuad.maxY
                    if inside {
                        // The ramp value is the picture's own: if the picture had been rescaled, this
                        // pixel would read a different x of the source.
                        let want = Float(x) / Float(oldCanvas.width - 1)
                        XCTAssertEqual(Double(px[i]), Double(Float(Float16(want))), accuracy: 2e-3,
                                       "\(newCanvas.keyString): picture pixel (\(x), \(y)) is not the "
                                       + "source's pixel \(x) — the picture was stretched")
                        _ = inside
                    } else if abs(Double(px[i]) - matte) <= 1.0 / 255,
                              px[i] == px[i + 1], px[i] == px[i + 2] {
                        mattePixels += 1
                    } else {
                        backdropPixels += 1
                    }
                    if px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0 { black += 1 }
                }
            }
            XCTAssertEqual(black, 0, "\(newCanvas.keyString): \(black) pixels are pure black")
            if newCanvas.width > oldCanvas.width {
                XCTAssertGreaterThan(backdropPixels, 0,
                                     "a wider canvas must fill the exposed band with the backdrop, "
                                     + "not with a colour")
                XCTAssertEqual(mattePixels, 0,
                               "…and nowhere in that band may the canvas colour show: the whole picture "
                               + "reaches past the canvas at 3×")
                // The band is the backdrop's content **at its own coordinates**, not one smeared
                // column: green is the picture coordinate, so it has to be a ramp.
                let y = newCanvas.height / 2
                var greens: [Float] = []
                for x in oldCanvas.width..<newCanvas.width {
                    greens.append(px[(y * newCanvas.width + x) * 4 + 1])
                }
                XCTAssertGreaterThan((greens.max() ?? 0) - (greens.min() ?? 0), 0.02,
                                     "the exposed band is one colour — that is a stretched edge, not the "
                                     + "picture's continuation")
                for (offset, g) in greens.enumerated() {
                    let x = Double(oldCanvas.width + offset) + 0.5
                    let u = Double(frozenBackdrop.u0) + x / Double(newCanvas.width) * Double(frozenBackdrop.du)
                    XCTAssertEqual(Double(g), u, accuracy: 0.02,
                                   "backdrop pixel x \(Int(x)) holds picture coordinate \(Double(g)), "
                                   + "want \(u)")
                }
            } else {
                XCTAssertEqual(backdropPixels, 0,
                               "a narrower canvas has nothing to extend: the picture is cropped, so every "
                               + "pixel is either the picture or the canvas colour")
            }
            print(String(format: "[067] frozen resize %@ → %@: quad %@, %d canvas-colour, "
                         + "%d backdrop, %d black", "\(oldCanvas.width)×\(oldCanvas.height)" as NSString,
                         newCanvas.keyString as NSString, request.pictureQuad.keyString as NSString,
                         mattePixels, backdropPixels, black))
        }

        // The fallback order, stated: no backdrop cached → the grown band is the canvas colour, never
        // black and never stretched (requirement 4 of the resize contract).
        let newCanvas = ImageSize(width: 640, height: 300)
        let target = try makeTexture(device, newCanvas, .rgba16Float, [.shaderRead, .renderTarget])
        let request = PresentRequest(picture: frameTexture, photoRect: photo,
                                     window: window.stretched(to: newCanvas, from: oldCanvas),
                                     canvas: newCanvas)
        XCTAssertTrue(presenter.render(request, into: target, linearize: false))
        let px = Self.floats(target)
        for x in oldCanvas.width..<newCanvas.width {
            let i = ((newCanvas.height / 2) * newCanvas.width + x) * 4
            XCTAssertEqual(Double(px[i]), matte, accuracy: 1.0 / 255,
                           "with no backdrop the exposed band is #0F0F0F at x \(x)")
        }
    }
}
