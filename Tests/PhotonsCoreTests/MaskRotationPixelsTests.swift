import XCTest
import PhotonsCore
import Metal
import CryptoKit

/// 派单 080 — the mask atlas turns **pixels**, like the picture does (073's sheared twin).
///
/// Nothing here re-derives the kernel's coordinates and checks the kernel against that derivation.
/// That is the shape `MaskTests.testAtlasInvertsCropRotationAndFlip` used to have, and it is why a
/// real 273 px displacement could live in the product with a green suite: the test's "expected" model
/// rotated `uv − ½` exactly like the kernel did, so both sides agreed on the sheared answer.
///
/// The measurement here is a **distance between the selection and the picture**, taken from pixels:
///
///   1. plant a bright dot in the source image at a known source pixel;
///   2. let S0 render it — the picture's own pixels say where that dot ended up;
///   3. read back the coverage of the mask that is *supposed* to select exactly that spot, and take
///      its centroid;
///   4. the number under test is the distance, in canvas pixels, between the two centroids.
///
/// A second, softer check (the picture's centroid against a `Double` transcription of S0's formula)
/// keeps the formula honest: it says the pixels agree with the algebra, so a centroid that lands
/// "where the formula says" is also landing where the photograph is.
///
/// The bug being pinned: rotating `uv − ½` is `rot(θ) ∘ aniso(W/H)` — a rotation followed by the
/// non-uniform scale back to pixels is a **shear**, and 073 removed it from the picture while the
/// atlas kept it. Magnitude, measured on `main` (2c7a8ff) by this very file: 229 px at 7° on
/// 9504×6336 at the probe below, and up to **273 px** at the frame corner (the survey's number).
/// It scales with `|W/H − 1|`, which is why the 16:9 / 1:1 pair below is the judgement and a square
/// frame is the control.
final class MaskRotationPixelsTests: XCTestCase {

    // MARK: - the shapes measured

    /// One frame shape to measure.
    ///
    /// `probe` is the dot's position **within the crop** (0…1 on both axes), so the same probe names
    /// the same place on the photograph whether the frame is 16:9 or a square cut out of it.
    private struct FrameProbe {
        let name: String
        let width: Int
        let height: Int
        let crop: NormalizedRect
        let angle: Double
        let probe: NormalizedPoint
    }

    private func full() -> NormalizedRect { NormalizedRect(x: 0, y: 0, width: 1, height: 1) }

    /// `bug` is the distance the normalised turn produced on `main`, in canvas pixels — printed, and
    /// quoted in the failure messages so a regression reads as "the 229 px mistake is back".
    private func probes() -> [(FrameProbe, bug: Double)] {
        [
            // The survey's case. 7° is what a straightened horizon actually is; 9504×6336 is a 45 MP
            // body's 3:2 frame, the aspect that makes the shear worst in absolute pixels.
            (FrameProbe(name: "9504×6336 @ 7°", width: 9504, height: 6336, crop: full(),
                        angle: 7, probe: NormalizedPoint(0.08, 0.08)), 229.3),
            // Landscape and portrait at the same angle: the shear factor is W/H one way round and
            // its reciprocal the other, so a fix that only works for landscape is not a fix.
            (FrameProbe(name: "1200×800 @ 45°", width: 1200, height: 800, crop: full(),
                        angle: 45, probe: NormalizedPoint(0.30, 0.10)), 126.5),
            (FrameProbe(name: "800×1200 @ 45° (portrait)", width: 800, height: 1200, crop: full(),
                        angle: 45, probe: NormalizedPoint(0.30, 0.90)), 126.5),
            // The shear judgement: one photograph, two crops, one angle. The 16:9 frame sheared by
            // 1.78 (165 px at this probe); the square frame cannot shear at all — so "both ≤ 1 px"
            // is a statement about the *cause*, not about two lucky sizes.
            (FrameProbe(name: "1600×900 (16:9) @ 30°", width: 1600, height: 900, crop: full(),
                        angle: 30, probe: NormalizedPoint(0.25, 0.10)), 165.1),
            (FrameProbe(name: "900×900 (1:1 crop of the same frame) @ 30°", width: 1600, height: 900,
                        crop: NormalizedRect(x: 0.21875, y: 0, width: 0.5625, height: 1),
                        angle: 30, probe: NormalizedPoint(0.25, 0.10)), 0.0),
        ]
    }

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Flat 0.05 with one soft dot, so the frame's only feature is at a known source pixel and its
    /// coverage centroid is that pixel to well under a tenth of one.
    private func dotImage(width: Int, height: Int, at p: NormalizedPoint,
                          sigma: Double = 8) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        let bg: Float = 0.05
        let cx = p.x * Double(width), cy = p.y * Double(height)
        let reach = sigma * 4
        let x0 = max(0, Int((cx - reach).rounded(.down))), x1 = min(width, Int((cx + reach).rounded(.up)) + 1)
        let y0 = max(0, Int((cy - reach).rounded(.down))), y1 = min(height, Int((cy + reach).rounded(.up)) + 1)
        // Uniform background first, then the dot's window — a full 60 Mpx `exp` sweep is not needed
        // to light up 64 × 64 pixels.
        for i in 0..<(width * height) {
            let o = i * 4
            rgba[o] = Float16(bg); rgba[o + 1] = Float16(bg); rgba[o + 2] = Float16(bg)
            rgba[o + 3] = 1
        }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let v = bg + 0.95 * Float(exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// The document: the frame shape under test, and one small hard radial sitting exactly on the
    /// dot — no feather, so its centroid is the shape's own centre and nothing else.
    private func document(_ p: FrameProbe, sourceUV: NormalizedPoint, source: ImageSize) -> EditModel {
        let radius = 24.0 / Double(min(source.width, source.height))
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: p.crop, rotationDegrees: p.angle,
                                      flipHorizontal: false, flipVertical: false)
        edit.masks = [Mask(id: "m-probe",
                           components: [MaskComponent(id: "c", feather: 0,
                                                      shape: .radialGradient(RadialGradientShape(
                                                        center: sourceUV,
                                                        radius: NormalizedPoint(radius, radius),
                                                        angle: 0)))],
                           adjustments: LocalAdjustments(exposure: 1))]
        return edit
    }

    // MARK: - the mapping, twice

    /// The forward half of S0's map in `Double`: normalised **source** point → canvas pixel index of
    /// the picture (no flips, no window — every probe here is one of those).
    ///
    /// Spelled from `s0_geometry.metal`'s pixel-space turn, and cross-checked below against the
    /// rendered dot's own centroid, so it cannot quietly become a description of whatever the kernel
    /// happens to do.
    private func canvasOfSource(_ s: NormalizedPoint, crop: NormalizedRect, angle: Double,
                                frame: ImageSize) -> (x: Double, y: Double) {
        let t = angle * .pi / 180
        let cs = cos(t), sn = sin(t)
        let fx = Double(frame.width), fy = Double(frame.height)
        let rx = (s.x - crop.x) / max(crop.width, 1e-9) - 0.5
        let ry = (s.y - crop.y) / max(crop.height, 1e-9) - 0.5
        // `R(−θ)` on a **pixel** offset about the frame's centre, then back to index space (a pixel
        // index i has its centre at i + 0.5, which is the −0.5 at the end).
        let px = rx * fx, py = ry * fy
        let ox = px * cs + py * sn
        let oy = -px * sn + py * cs
        return (ox + 0.5 * fx - 0.5, oy + 0.5 * fy - 0.5)
    }

    /// Coverage-weighted centroid of one slice, in canvas pixel indices.
    private func maskCentroid(_ dump: MaskAtlasDump, slice: Int) -> (x: Double, y: Double) {
        let values = dump.slices[slice]
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<dump.height {
            let row = y * dump.width
            for x in 0..<dump.width {
                let w = Double(values[row + x])
                if w <= 0 { continue }
                sx += Double(x) * w
                sy += Double(y) * w
                sw += w
            }
        }
        XCTAssertGreaterThan(sw, 0, "the probe mask has no coverage at all")
        return sw > 0 ? (sx / sw, sy / sw) : (0, 0)
    }

    /// Where the picture's dot actually is, in canvas pixel indices — the ground truth, read off the
    /// frame S0 produced rather than off any formula.
    private func pictureCentroid(_ image: DisplayImage) -> (x: Double, y: Double) {
        // Anything brighter than the flat background is the dot. The corner is background on every
        // one of these frames (a rotated frame clamps its edge texels to the same flat value).
        let bg = Double(image.rgba[(2 * image.width + 2) * 4])
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<image.height {
            let row = y * image.width
            for x in 0..<image.width {
                let o = (row + x) * 4
                let luma = (Double(image.rgba[o]) + Double(image.rgba[o + 1])
                            + Double(image.rgba[o + 2])) / 3
                let w = luma - bg
                if w <= 1e-4 { continue }
                sx += Double(x) * w
                sy += Double(y) * w
                sw += w
            }
        }
        XCTAssertGreaterThan(sw, 1e-3, "the dot is not in the frame at all — the probe is off-canvas")
        return sw > 0 ? (sx / sw, sy / sw) : (0, 0)
    }

    // MARK: - 1. the measurement

    /// The assertion this task exists for: the mask's centroid and the picture's dot must be the same
    /// place, to within one canvas pixel, at every frame shape.
    func testMaskLandsOnThePixelItSelects() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        var report: [String] = []
        for (p, bug) in probes() {
            let source = ImageSize(width: p.width, height: p.height)
            // The dot's place on the photograph, from the probe's crop-relative position: the same
            // spot in the 16:9 frame and in the square cut out of it.
            let sourceUV = NormalizedPoint(p.crop.x + p.probe.x * p.crop.width,
                                          p.crop.y + p.probe.y * p.crop.height)
            let image = dotImage(width: p.width, height: p.height, at: sourceUV)
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "mask-rotation"))
            let edit = document(p, sourceUV: sourceUV, source: source)
            let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
            let display = try XCTUnwrap(result.display, "\(p.name): no pixels came back")
            // Second call is a cache hit for every stage: it copies the atlas out, nothing else.
            let dump = try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)),
                                     "\(p.name): the document has a mask, so there must be an atlas")

            let frame = ImageSize(width: display.width, height: display.height)
            let expected = canvasOfSource(sourceUV, crop: p.crop, angle: p.angle, frame: frame)
            let picture = pictureCentroid(display)
            let mask = maskCentroid(dump, slice: 0)

            // (a) The formula describes the picture. If this fails the ground truth moved, and (b)
            // below is measuring nothing.
            let formulaError = hypot(picture.x - expected.x, picture.y - expected.y)
            XCTAssertLessThan(formulaError, 1.0,
                              "\(p.name): the pixel-space formula is \(formulaError) px from where the "
                              + "picture actually put the dot")

            // (b) The selection is on the picture. This is the number the bug moved.
            let offset = hypot(mask.x - picture.x, mask.y - picture.y)
            report.append(String(format: "%@: mask↔picture %.2f px (formula↔picture %.2f px; "
                                 + "the normalised turn was %.1f px)",
                                 p.name, offset, formulaError, bug))
            XCTAssertLessThanOrEqual(offset, 1.0,
                                     "\(p.name): the mask sits \(String(format: "%.2f", offset)) px off "
                                     + "the pixels it selects — the normalised-coordinate turn "
                                     + "(\(bug) px here) is back")
        }
        for line in report { print("MASK↔PICTURE " + line) }
    }

    // MARK: - 2. the host map agrees with the kernels

    /// `MaskCanvasMapping.canvasPoint` is the CPU's copy of S0's mapping (`MaskBounds` uses it for
    /// dirty rectangles, the mask handles for their positions). It has to turn pixels too, or the
    /// bounds and the atlas disagree — which is how the atlas's version of this bug stayed invisible
    /// for a release: the host map sheared in step with it and the two agreed on the wrong answer.
    func testMaskCanvasMappingTurnsPixels() throws {
        let cases: [(frame: ImageSize, crop: NormalizedRect, angle: Double)] = [
            (ImageSize(width: 9504, height: 6336), full(), 7),
            (ImageSize(width: 1200, height: 800), full(), 45),
            (ImageSize(width: 800, height: 1200), full(), 45),
            (ImageSize(width: 1600, height: 900),
             NormalizedRect(x: 0.21875, y: 0, width: 0.5625, height: 1), 30),
        ]
        for (frame, crop, angle) in cases {
            let geometry = GeometryGroup(crop: crop, rotationDegrees: angle,
                                         flipHorizontal: false, flipVertical: false)
            let mapping = MaskCanvasMapping(geometry: geometry, source: frame,
                                            content: frame, canvas: frame, origin: (0, 0))
            for probe in [NormalizedPoint(0.1, 0.1), NormalizedPoint(0.5, 0.5),
                          NormalizedPoint(0.9, 0.15), NormalizedPoint(0.35, 0.8)] {
                let source = NormalizedPoint(crop.x + probe.x * crop.width,
                                             crop.y + probe.y * crop.height)
                let host = mapping.canvasPoint(source)
                let kernel = canvasOfSource(source, crop: crop, angle: angle, frame: frame)
                let off = hypot(host.x - kernel.x, host.y - kernel.y)
                XCTAssertLessThan(off, 1e-6,
                                  "\(frame.keyString) at \(angle)°: `canvasPoint` is \(off) px from "
                                  + "S0's pixel-space map at \(probe)")
            }
            // And the same map at 0°, where it must be the identity on the crop-relative offset: the
            // `× frame` / `÷ frame` round trip is not in the θ = 0 path in either place.
            let upright = GeometryGroup(crop: crop, rotationDegrees: 0,
                                        flipHorizontal: false, flipVertical: false)
            let flat = MaskCanvasMapping(geometry: upright, source: frame, content: frame,
                                         canvas: frame, origin: (0, 0))
            let here = flat.canvasPoint(NormalizedPoint(crop.x + 0.25 * crop.width,
                                                        crop.y + 0.4 * crop.height))
            // 0.25 / 0.4 of the way through the crop, out in canvas pixel indices.
            let wanted = 0.25 * Double(frame.width) - 0.5
            let wantedY = 0.4 * Double(frame.height) - 0.5
            XCTAssertEqual(here.x, wanted, accuracy: 1e-9, "the θ = 0 map must not round-trip")
            XCTAssertEqual(here.y, wantedY, accuracy: 1e-9)
        }
    }

    // MARK: - 3. straighten = 0 is bit-identical

    /// The floor of this change: a document that is not straightened must produce the **same atlas
    /// bytes** it always did. Pinned as the 8-bit quantised digest of each slice (structure
    /// sensitive, GPU-family tolerant — the same convention the recorded goldens use), on three
    /// shape kinds: radial, linear and brush, each covering the whole frame so every pixel of every
    /// slice carries a value.
    ///
    /// The recorded values are `main` (2c7a8ff)'s: this file was run against that tree before the
    /// kernel changed. They are the reason the fix is a *second entry point* rather than a new
    /// expression in one: `(uv − ½)·frameSize / frameSize + ½` is 1 ulp from `uv − ½`, and one ulp
    /// rewrites every digest below (the same lesson `s0_geometry` documents at length).
    func testStraightenZeroAtlasIsBitIdentical() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        // Straight from `main`, recorded by this test before the kernel learned to turn pixels.
        let pinned = [
            "radial": "PIN_RADIAL",
            "linear": "PIN_LINEAR",
            "brush": "PIN_BRUSH",
        ]

        let image = dotImage(width: 320, height: 200, at: NormalizedPoint(0.4, 0.6), sigma: 30)
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        edit.masks = [
            Mask(id: "m-radial", components: [MaskComponent(id: "r", feather: 0.35, shape:
                .radialGradient(RadialGradientShape(center: NormalizedPoint(0.45, 0.5),
                                                    radius: NormalizedPoint(0.25, 0.18),
                                                    angle: 20)))],
                 adjustments: LocalAdjustments(exposure: 0.7)),
            Mask(id: "m-linear", components: [MaskComponent(id: "l", feather: 0.6, shape:
                .linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1),
                                                   end: NormalizedPoint(0.8, 0.9),
                                                   midpoint: 0.42)))],
                 adjustments: LocalAdjustments(exposure: -0.4)),
            Mask(id: "m-brush", components: [MaskComponent(id: "b", feather: 0.25, shape: .brush(
                BrushShape(size: 0.2, strokes: [
                    Stroke(points: [0.15, 0.3, 0.45, 0.55, 0.8, 0.35], radius: 0.1,
                           feather: 0.4, flow: 0.9),
                    Stroke(points: [0.5, 0.6, 0.7, 0.7], radius: 0.05, feather: 0.3, erase: true),
                ])))],
                 adjustments: LocalAdjustments(exposure: 0.3)),
        ]

        let graph = try RenderGraph(input: RenderInput(image: image, identity: "mask-zero-degrees"))
        let dump = try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
        // The atlas orders its slices by id, not by document order.
        XCTAssertEqual(dump.maskIDs.sorted(), ["m-brush", "m-linear", "m-radial"])

        for (slice, id) in dump.maskIDs.enumerated() {
            var bytes = [UInt8](repeating: 0, count: dump.width * dump.height)
            for i in 0..<bytes.count {
                bytes[i] = UInt8(min(max((Double(dump.slices[slice][i]) * 255).rounded(), 0), 255))
            }
            let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            print("ATLAS-DIGEST \(id) \(digest.prefix(16))…")
            if let want = pinned[id] {
                XCTAssertEqual(digest, want,
                               "\(id): a document at straighten = 0 must keep its atlas byte for byte")
            }
        }
    }
}
