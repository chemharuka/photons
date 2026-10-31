import XCTest
import PhotonsCore
import Metal
import CryptoKit

/// M4 acceptance, steps 005a (model + keys), 005b (linear/radial gradients → atlas) and 005c
/// (brush, colour range, luminance range, amount/opacity).
///
/// Three kinds of check, in the order they can lie:
///
/// 1. **Text**: the seven M1 cache keys are pinned verbatim, as produced by *committed* M1 code
///    (b1c58ec) for a fixed document. Empty masks must not move a single byte of them.
/// 2. **Numbers**: every shape is compared against an independent scalar implementation of its
///    analytic formula (brush, linear, radial, colour range, luminance range), pixel by pixel, on a
///    synthetic image — plus a table of pinned values so "fixed input → fixed output" is checked
///    directly, not inferred.
///    No RAW fixture, no decoder, no eyeballing.
/// 3. **Frames**: recorded goldens under `Tests/Golden/mask-*.json`, quantised to 8 bits so they
///    survive a GPU family change while still catching a structural regression.
final class MaskTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `Tests/Golden`, unless `PHOTONS_GOLDEN_DIR` points somewhere else (used when the suite runs
    /// from a scratch copy of the package).
    private static var goldenDir: URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_GOLDEN_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return repoRoot.appendingPathComponent("Tests/Golden")
    }

    /// The M1 key-vector fixture. Every value here is deliberately non-default: a key that ignored
    /// one of them would still match a neutral document.
    private func m1Fixture() -> EditModel {
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.75),
                                      rotationDegrees: 1.5,
                                      flipHorizontal: true, flipVertical: false)
        edit.light = LightGroup(exposure: 0.75, contrast: 20, highlights: -30, shadows: 15,
                                whites: 10, blacks: -5, temperature: 5200, tint: 12,
                                highlightRecovery: 0.4)
        edit.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.3, v: 0.25), CurvePoint(u: 1, v: 1)])
        edit.color = ColorGroup(vibrance: 15, saturation: -10, bands: ColorGroup.identityBands)
        edit.color.bands[3].hue = 20
        edit.effects = EffectsGroup(vignetteAmount: -40, vignetteMidpoint: 45,
                                    vignetteFeather: 60)
        edit.detail = DetailGroup(sharpening: 40)
        edit.masks = []
        return edit
    }

    private func links(_ edit: EditModel) -> RenderKeyChain.Links {
        RenderKeyChain.links(identity: "keyvec-fixture",
                             sourceSize: ImageSize(width: 6000, height: 4000),
                             canvas: ImageSize(width: 1500, height: 1000),
                             content: ImageSize(width: 1500, height: 1000),
                             edit: edit,
                             display: DisplayOptions())
    }

    /// Horizontal ramp, every channel slightly different so a channel mix-up cannot pass.
    private func rampImage(width: Int = 96, height: Int = 65) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.10 + 0.55 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.95)
                rgba[o + 2] = Float16(v * 0.9)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Flat mid-grey: makes the local-exposure ratio readable without a real photograph.
    private func flatImage(_ value: Float, width: Int = 64, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func makeGraph(_ image: LinearImage, identity: String = "mask-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage,
                       scale: Double = 1) throws -> MaskAtlasDump {
        let graph = try makeGraph(image)
        let dump = try graph.maskAtlas(edit, options: RenderOptions(scale: scale))
        return try XCTUnwrap(dump, "a document with an enabled mask must produce an atlas")
    }

    // MARK: - independent analytic reference (linear / radial gradient)

    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Linear gradient (102): `t = dot(p−start, d)/dot(d,d)`, midpoint remap, then a **symmetric**
    /// smoothstep ramp of width `f` centred on the half-way line `t' = ½`. 079 A4's "short-edge
    /// percentage spent outside the rim" rule is the *radial* one; applying it to the open shapes made
    /// the linear ramp one-sided and a tenth as wide, so 102 restores the pre-A4 (`e3a011d^`) contract.
    private func linearAlpha(x: Double, y: Double, _ s: LinearGradientShape,
                             feather f: Double, size: (w: Int, h: Int)) -> Double {
        let w = Double(size.w), h = Double(size.h)
        let ax = s.start.x * w, ay = s.start.y * h
        let bx = s.end.x * w, by = s.end.y * h
        let dx = bx - ax, dy = by - ay
        let denom = max(dx * dx + dy * dy, 1e-12)
        var t = ((x - ax) * dx + (y - ay) * dy) / denom
        t = min(max(t, 0), 1)
        let m = min(max(s.midpoint, 0.02), 0.98)
        var tp = t
        if abs(m - 0.5) > 1e-6 && t > 0 { tp = pow(t, log(0.5) / log(m)) }
        let radius = min(max(f, 0), 1)
        let lo = 0.5 - 0.5 * radius
        let hi = max(0.5 + 0.5 * radius, lo + 1e-5)
        return smoothstep(lo, hi, tp)
    }

    /// 079 A4: `q = R(−angle)·(p−centre)/radius`, `r = |q|`; `alpha = 1` for `r ≤ 1`, then
    /// `clamp((r_out² − r²)/(r_out² − 1))²` out to `r_out = 1 + f·0.1·shortEdge / min(rx, ry)`.
    private func radialAlpha(x: Double, y: Double, _ s: RadialGradientShape,
                             feather f: Double, size: (w: Int, h: Int)) -> Double {
        let w = Double(size.w), h = Double(size.h)
        let side = min(w, h)
        let cx = s.center.x * w
        let cy = s.center.y * h
        let rx = max(abs(s.radius.x) * side, 1e-4)
        let ry = max(abs(s.radius.y) * side, 1e-4)
        let dvx = x - cx, dvy = y - cy
        let rad = s.angle * Double.pi / 180
        let cs = cos(rad), sn = sin(rad)
        let qx = (dvx * cs + dvy * sn) / rx
        let qy = (-dvx * sn + dvy * cs) / ry
        let r = (qx * qx + qy * qy).squareRoot()
        let radius = min(max(f, 0), 1)
        let featherPx = radius * 0.1 * side
        if featherPx <= 0 {
            // `feather == 0` keeps the pre-A4 expression verbatim (a hard edge at the rim; the
            // division by zero at `r == 1` exactly is why callers compare pixel centres, never the rim).
            return 1 - smoothstep(1 - radius, 1, r)
        }
        let g = featherPx / min(rx, ry)
        let rOut = 1 + g
        let ratio = min(max((rOut * rOut - r * r) / (rOut * rOut - 1), 0), 1)
        return ratio * ratio
    }

    /// Pixel-centre sampling, exactly as the kernel walks S0's mapping backwards for an identity
    /// geometry: canvas pixel `(x, y)` is source position `(x + 0.5, y + 0.5)`.
    private func sample(_ dump: MaskAtlasDump, _ slice: Int, _ x: Int, _ y: Int) -> Double {
        Double(dump.value(slice: slice, x: x, y: y) ?? -1)
    }

    // MARK: - independent references for the 005c shapes (§4.1 / §4.4 / §4.5)

    /// The value a half-float texture actually holds, so a reference never disagrees with the GPU
    /// about the input rather than about the maths.
    private func h16(_ v: Float) -> Double { Double(Float16(v)) }

    /// §4.1: `alpha = 1 − smoothstep(r(1−f), r, distToSegment)`.
    private func segmentAlpha(x: Double, y: Double, ax: Double, ay: Double, bx: Double, by: Double,
                              ra: Double, rb: Double, feather f: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 1e-12 ? min(max(((x - ax) * dx + (y - ay) * dy) / len2, 0), 1) : 0
        let cx = ax + dx * t, cy = ay + dy * t
        let r = ra + (rb - ra) * t
        let core = r * (1 - f)
        let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
        return 1 - smoothstep(core, max(r, core + 1e-6), d)
    }

    /// One stroke: capsule chain with `max` inside, `flow` outside. Pressure scales the radius.
    private func strokeAlpha(x: Double, y: Double, _ s: Stroke, size: (w: Int, h: Int)) -> Double {
        let n = s.points.count / 2
        guard n > 0 else { return 0 }
        let side = Double(min(size.w, size.h))
        let base = max(s.radius, 0) * side
        let f = min(max(s.feather, 0), 0.999)
        func at(_ i: Int) -> (x: Double, y: Double, p: Double) {
            let pressure = i < s.pressure.count ? max(Double(s.pressure[i]), 0.02) : 1
            return (Double(s.points[i * 2]) * Double(size.w),
                    Double(s.points[i * 2 + 1]) * Double(size.h), pressure)
        }
        var acc = 0.0
        if n == 1 {
            let q = at(0)
            let r = max(base * q.p, 0.5)
            acc = 1 - smoothstep(r * (1 - f), max(r, r * (1 - f) + 1e-6),
                                 ((x - q.x) * (x - q.x) + (y - q.y) * (y - q.y)).squareRoot())
        } else {
            for i in 0..<(s.closed ? n : n - 1) {
                let a = at(i), b = at((i + 1) % n)
                acc = max(acc, segmentAlpha(x: x, y: y, ax: a.x, ay: a.y, bx: b.x, by: b.y,
                                            ra: max(base * a.p, 0.5), rb: max(base * b.p, 0.5),
                                            feather: f))
            }
        }
        return acc * min(max(s.flow, 0), 1)
    }

    /// §4.1 accumulation across strokes: paint over `s + d(1−s)`, erase `d(1−s)`.
    private func brushAlpha(x: Double, y: Double, _ b: BrushShape, size: (w: Int, h: Int)) -> Double {
        var acc = 0.0
        for s in b.strokes {
            let v = strokeAlpha(x: x, y: y, s, size: size)
            acc = s.erase ? acc * (1 - v) : v + acc * (1 - v)
        }
        return min(max(acc, 0), 1)
    }

    /// §4.4: nearest sample in the `OKLabMetric` space, then the soft threshold.
    /// `OKLabMetric` is defined on the graph's **working primaries** — Rec.2020 since 075 — while the
    /// mask fixtures are linear sRGB. Every expectation that feeds a fixture colour into the metric
    /// converts first. Skipping this step is not a rounding difference: it reads Rec.2020 codes with
    /// an sRGB fold (or vice versa) and moved the colour-range ramp's mid-threshold by 0.01 of
    /// coverage, which is 2.5 codes — measured on the first Rec.2020 build of 075.
    static func workingLinear(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let w = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
            .applying(to: SIMD3(r, g, b))
        return (w.x, w.y, w.z)
    }

    private func colourRangeAlpha(r: Double, g: Double, b: Double, _ s: ColorRangeShape) -> Double {
        let c = Self.workingLinear(r, g, b)
        let lab = OKLabMetric.fromLinear(c.0, c.1, c.2)
        var best = Double.infinity
        for sample in s.samples where sample.count >= 3 {
            best = min(best, OKLabMetric.distance(lab,
                                                 OKLabMetric.fromSRGB(sample[0], sample[1], sample[2])))
        }
        guard best.isFinite else { return 0 }
        let tol = max(s.tolerance, 0)
        let upper = max(tol + min(max(s.smoothness, 0), 1) * max(0.5 - tol, 0), tol + 1e-4)
        return 1 - smoothstep(tol, upper, best)
    }

    /// §4.5: OKLab L with a two-sided feather, inverted pairs repaired. 167: the light is folded
    /// **unclamped**, so this reference and the kernel share the HDR axis as well as the SDR one.
    private func luminanceRangeAlpha(r: Double, g: Double, b: Double, _ s: LuminanceRangeShape) -> Double {
        let o = s.ordered
        let linear = Self.workingLinear(max(r, 0), max(g, 0), max(b, 0))
        let L = OKLabMetric.fromLinear(linear.0, linear.1, linear.2).L
        let loF = max(o.lowFeather, 0), hiF = max(o.highFeather, 0)
        let inLow = smoothstep(o.low - loF, max(o.low + loF, o.low - loF + 1e-5), L)
        let inHigh = 1 - smoothstep(o.high - hiF, max(o.high + hiF, o.high - hiF + 1e-5), L)
        return min(max(inLow * inHigh, 0), 1)
    }

    // MARK: - 005c fixtures

    /// Solid left/right halves: a colour range has two known answers and one hard edge.
    private func twoToneImage(_ left: (Float, Float, Float), _ right: (Float, Float, Float),
                              width: Int = 96, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = x < width / 2 ? left : right
                let o = (y * width + x) * 4
                rgba[o] = Float16(c.0); rgba[o + 1] = Float16(c.1)
                rgba[o + 2] = Float16(c.2); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Linear grey ramp 0…1 across the columns — the luminance range's natural test signal.
    private func greyRampImage(width: Int = 96, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float(Double(x) / Double(max(width - 1, 1)))
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Linear ramp from one colour to another across the columns: a colour range's tolerance sweep.
    private func colourRampImage(from a: (Float, Float, Float) = MaskTests.leftColour,
                                 to b: (Float, Float, Float) = MaskTests.farColour,
                                 width: Int = 96, height: Int = 8) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(Double(x) / Double(max(width - 1, 1)))
                let o = (y * width + x) * 4
                rgba[o] = Float16(a.0 + (b.0 - a.0) * t)
                rgba[o + 1] = Float16(a.1 + (b.1 - a.1) * t)
                rgba[o + 2] = Float16(a.2 + (b.2 - a.2) * t)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// One mask around one shape, so a coverage test reads exactly one answer.
    private func doc(_ shape: MaskShape, feather: Double = 0.5, opacity: Double = 1,
                     invert: Bool = false, adjustments: LocalAdjustments = .identity) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-\(shape.kind)", opacity: opacity, invert: invert,
                           components: [MaskComponent(id: "c", feather: feather, shape: shape)],
                           adjustments: adjustments)]
        return edit
    }

    // MARK: - 005c colour fixtures

    /// Linear working-space colour at the near end of the ramp (a desaturated green).
    static let leftColour: (Float, Float, Float) = (0.20, 0.40, 0.15)
    /// The far end: a blue, i.e. far from `leftColour` in OKLab.
    static let farColour: (Float, Float, Float) = (0.15, 0.20, 0.85)

    /// sRGB OETF, the encode the document's sample colours are stored in (§2/§4.4).
    static func encodeSRGB(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// The same colours as the document stores them: sRGB-encoded 0…1 (§2).
    static let leftColourSRGB: [Double] = [encodeSRGB(Double(leftColour.0)),
                                           encodeSRGB(Double(leftColour.1)),
                                           encodeSRGB(Double(leftColour.2))]
    static let farColourSRGB: [Double] = [encodeSRGB(Double(farColour.0)),
                                          encodeSRGB(Double(farColour.1)),
                                          encodeSRGB(Double(farColour.2))]

    /// Column `t` of `colourRampImage()`, exactly as the half-float texture holds it.
    static func colourRampColour(_ t: Double) -> (Double, Double, Double) {
        func mix(_ a: Float, _ b: Float) -> Double {
            Double(Float16(a + (b - a) * Float(t)))
        }
        return (mix(leftColour.0, farColour.0),
                mix(leftColour.1, farColour.1),
                mix(leftColour.2, farColour.2))
    }

    /// Nearest-sample distance in the metric space, for the boundary assertions.
    static func colourDistance(_ c: (Double, Double, Double), from samples: [[Double]]) -> Double {
        let w = workingLinear(c.0, c.1, c.2)
        let lab = OKLabMetric.fromLinear(w.0, w.1, w.2)
        return samples.reduce(Double.infinity) { best, s in
            min(best, OKLabMetric.distance(lab, OKLabMetric.fromSRGB(s[0], s[1], s[2])))
        }
    }

    // MARK: - 005a: the model

    /// Missing fields must land on the documented defaults, never on zero and never on an error.
    func testMaskDecodesMissingFieldsToDefaults() throws {
        let json = Data(#"""
        { "schemaVersion": 2,
          "masks": [ { "id": "m-1",
                       "components": [ { "id": "c-1" },
                                       { "id": "c-2", "op": "subtract",
                                         "shape": { "kind": "radialGradient" } } ] } ] }
        """#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.masks.count, 1)
        let mask = model.masks[0]
        XCTAssertEqual(mask.name, "Mask 1")
        XCTAssertTrue(mask.isEnabled)
        XCTAssertEqual(mask.opacity, 1.0)
        XCTAssertFalse(mask.invert)
        XCTAssertEqual(mask.feather, 0)
        XCTAssertEqual(mask.refine, 0)
        XCTAssertEqual(mask.adjustments, .identity)
        XCTAssertEqual(mask.adjustments.amount, 100, "amount defaults to 100, not 0")

        XCTAssertEqual(mask.components.count, 2)
        let first = mask.components[0]
        XCTAssertEqual(first.op, .add)
        XCTAssertFalse(first.invert)
        XCTAssertEqual(first.feather, 0.5, "component feather defaults to 0.5, not 0")
        // No `shape` at all: the documented default is the top-to-bottom linear gradient.
        guard case .linearGradient(let linear) = first.shape else {
            return XCTFail("a component without a shape must default to linearGradient")
        }
        XCTAssertEqual(linear.start, NormalizedPoint(0.5, 0))
        XCTAssertEqual(linear.end, NormalizedPoint(0.5, 1))
        XCTAssertEqual(linear.midpoint, 0.5)

        let second = mask.components[1]
        XCTAssertEqual(second.op, .subtract)
        guard case .radialGradient(let radial) = second.shape else {
            return XCTFail("radialGradient discriminator was not honoured")
        }
        XCTAssertEqual(radial.center, NormalizedPoint(0.5, 0.5))
        XCTAssertEqual(radial.radius, NormalizedPoint(0.25, 0.25))
        XCTAssertEqual(radial.angle, 0)
    }

    /// Every kind in the schema survives a round trip; an unknown kind keeps its bytes and is
    /// disabled instead of being guessed at (§2).
    func testEveryShapeKindRoundTrips() throws {
        let shapes: [MaskShape] = [
            .linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1),
                                                end: NormalizedPoint(0.9, 0.8),
                                                midpoint: 0.3)),
            .radialGradient(RadialGradientShape(center: NormalizedPoint(0.4, 0.6),
                                                radius: NormalizedPoint(0.3, 0.15),
                                                angle: -22.5)),
            .brush(BrushShape(size: 0.08,
                              strokes: [Stroke(points: [0.1, 0.2, 0.3, 0.4], radius: 0.05,
                                               feather: 0.25, flow: 0.8, erase: true)])),
            .colorRange(ColorRangeShape(samples: [[0.1, 0.2, 0.3], [0.9, 0.8, 0.7]],
                                        tolerance: 0.22, smoothness: 0.4)),
            .luminanceRange(LuminanceRangeShape(low: 0.1, high: 0.9,
                                                lowFeather: 0.2, highFeather: 0.3)),
            .semantic(SemanticShape(kind: .sky, provider: .systemMatte, softEdge: 0.3,
                                    rasterDigest: "abc123")),
            .unsupported(kind: "spotRemoval", payload: .object([
                "x": .number(0.5), "y": .number(0.25), "radius": .number(12),
                "nested": .object(["keep": .array([.number(1), .string("two"), .bool(true)])]),
            ])),
        ]

        for shape in shapes {
            let mask = Mask(id: "m-1", name: "Round trip",
                            components: [MaskComponent(id: "c-1", feather: 0.4, shape: shape)])
            let data = try JSONEncoder().encode(mask)
            let back = try JSONDecoder().decode(Mask.self, from: data)
            XCTAssertEqual(back.components[0].shape, shape, "\(shape.kind) lost data in a round trip")

            if shape.isKnownKind {
                XCTAssertEqual(back, mask, "\(shape.kind) changed outside its payload")
            } else {
                // An unknown kind keeps its bytes but must arrive disabled (§2), so only the
                // payload and the non-enable fields are expected to match.
                XCTAssertFalse(back.isEnabled, "an unknown kind must decode disabled")
                XCTAssertEqual(back.components, mask.components)
                XCTAssertEqual(back.adjustments, mask.adjustments)
            }
        }
    }

    /// An unknown `kind` is preserved **and** disabled, and re-encoding is a fixed point: the
    /// document a newer build wrote is not damaged by this one.
    func testUnknownKindIsPreservedAndDisabled() throws {
        let json = Data(#"""
        { "masks": [ { "id": "m-1", "isEnabled": true,
                       "components": [ { "id": "c-1", "shape": { "kind": "spotRemoval",
                                                                 "x": 0.5, "radius": 12,
                                                                 "tags": ["a", "b"] } } ] } ] }
        """#.utf8)
        let mask = try JSONDecoder().decode(EditModel.self, from: json).masks[0]
        XCTAssertFalse(mask.isEnabled, "a shape this build cannot interpret must never render")
        guard case .unsupported(let kind, let payload) = mask.components[0].shape,
              case .object(let fields) = payload else {
            return XCTFail("unknown kind did not become .unsupported")
        }
        XCTAssertEqual(kind, "spotRemoval")
        XCTAssertEqual(fields["radius"], JSONValue.number(12))
        XCTAssertEqual(fields["tags"], JSONValue.array([.string("a"), .string("b")]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let once = try encoder.encode(mask)
        let twice = try encoder.encode(JSONDecoder().decode(Mask.self, from: once))
        XCTAssertEqual(String(decoding: once, as: UTF8.self), String(decoding: twice, as: UTF8.self),
                       "re-encoding an unsupported shape must be byte-stable")
        XCTAssertTrue(String(decoding: once, as: UTF8.self).contains("\"spotRemoval\""))
    }

    /// `name` is documented as "not in any key": renaming must not rebuild anything.
    func testNameIsNotInAnyKey() {
        var a = m1Fixture()
        a.masks = [Mask(id: "m-1", name: "A", components: [MaskComponent(id: "c", shape: .linearGradient(.default))])]
        var b = a
        b.masks[0].name = "Something else entirely"
        XCTAssertEqual(a.maskSelectionMaterial, b.maskSelectionMaterial)
        XCTAssertEqual(a.maskApplyMaterial, b.maskApplyMaterial)
        XCTAssertEqual(links(a), links(b))
        XCTAssertEqual(b.changedStages(from: a), [])
    }

    // MARK: - 005a: the seven M1 keys must not move

    /// Byte-for-byte the canonical text and digest that **b1c58ec** produced for this document
    /// (captured by running that commit's `RenderStage`/`EditModel` through its own `plan()`), with the
    /// migrations later tasks were allowed to make:
    ///
    ///   · 019 — `wh=…;bl=…` moved from the `.toneMap` material into `.sceneLinear`, because
    ///     blacks/whites are a linear *level* now and the maths moved with them. So the `sceneLinear`
    ///     text gained two tokens, the `toneMap` text lost them, and every digest from `sceneLinear`
    ///     down follows its parent. The `geometry` link is untouched, and the `curve`/`color`/
    ///     `vignette`/`display` *materials* are untouched — only their chain digests moved.
    ///   · 030 — **曲线换阶段** (the curve changed stage). Three string facts, no pixel fact:
    ///       1. `pv=1` → `pv=2`: the process version, because the curve's axis changed meaning;
    ///       2. `curve` and `toneMap` swapped places in the chain: the curve now runs before S2, so
    ///          `curve` is seeded by `sceneLinear` and `toneMap` by `curve`;
    ///       3. the W table's key prefix is `w=` where it was `rgb=`, since the field is now
    ///          `curve.white` (the luminance curve) and no longer claims to be a composite.
    ///     The **pixels** of this document are unchanged only where the curve is the identity; its
    ///     curve is not, and that is what `processVersion` 2 declares (`docs/tasks/030` §10.1).
    ///     Nothing about the invariance criteria was relaxed: same seven links, same counts, same
    ///     `masks == []` → no mask stages.
    ///   · 069 — **曲线坐标换单位，`curve` 一行的数字变、含义不变**. Two spelling facts, no
    ///     coordinate fact, and the conversion is arithmetic, not a re-recording:
    ///       1. `x_new = 2·x_old`, `y_new = 2·y_old` — the stored pair is now the card's `0…2` axis
    ///          (`0…1` SDR display code, `1…2` = +4 EV) while the engine kept its `0…1` axis at
    ///          `u = x/2` (`EditModel.swift:1016,1019`; `CurveLUT` reads `.u`/`.v`, so the table, the
    ///          shaper and the kernel see the **same numbers as before**). `CurveStorageTests
    ///          .testTheNewCoordinateIsTwiceTheAxis` recomputes that factor from the anchors.
    ///          So `0.3000,0.2500` → `0.600000,0.500000` and `1.0000,1.0000` → `2.000000,2.000000`,
    ///          and the identity tables `0…1` → `0…2` the same way.
    ///       2. `%.4f` → `%.6f` (`CurvePoint.keyString`, `EditModel.swift:1036`): six decimals for a
    ///          continuous coordinate. `0.6000` and `0.600000` are the same number, spelled longer.
    ///     Everything else in the `curve` line is unchanged, and the four downstream links
    ///     (`toneMap`/`color`/`vignette`/`display`) moved **only** because they chain-digest this
    ///     line — their materials are byte-identical to 005a's, which is what the last four rows show.
    ///
    ///   · P1f (079 §2.7.1) — **the algorithm version enters the key** (`;alg=N` on every link's
    ///     material, `StageAlgorithmVersion`). Every digest below the painted text moved, and the four
    ///     materials that did not change (`geometry`, `sceneLinear`, `curve` at version 1) moved too,
    ///     because the token is unconditional. That is the deliberate one-time cost of making a key
    ///     answer "which generation of the arithmetic wrote this" for **every** stage rather than only
    ///     for stages that have been bumped once: the alternative (append only above 1) would have kept
    ///     these bytes and made the token a property of half the pipeline. No pixel changed, and no
    ///     document changed — `CacheVersionTests.testTheVersionNeverEntersTheDocument` holds that end.
    ///
    /// Nothing about the *structure* changed, and the mask-side invariance criteria below are not
    /// touched. If this test fails again, the empty-mask path changed and every golden, every disk
    /// cache entry and the claim "adding masks did not touch the no-mask path" are void (§3.2).
    func testEmptyMasksProduceTheM1KeysByteForByte() {
        let edit = m1Fixture()
        XCTAssertTrue(edit.masks.isEmpty)
        XCTAssertFalse(edit.hasActiveMasks)
        let l = links(edit)
        XCTAssertNil(l.maskAtlas, "no masks: the atlas stage must not exist")
        XCTAssertNil(l.localApply, "no masks: the local stage must not exist")

        let expected: [(String, String, String)] = [
            ("geometry", "4eabf95b4171026012b61b5d80c672d2c4925673112b5bdfd613f1150054258c",
             "photons-render-v1|keyvec-fixture|6000x4000|1500x1000|1500x1000|pv=2;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=10;alg=2"),
            ("sceneLinear", "e6dab7c142ee92f6dcd0d54c7b668f4ecab947b2438ca6ef8801c92116c2863b",
             "4eabf95b4171026012b61b5d80c672d2c4925673112b5bdfd613f1150054258c|ev=0.75000;temp=5200.00000;tint=12.00000;hlr=0.40000;wh=10.00000;bl=-5.00000;alg=8"),
            ("curve", "ae2655131716e5d024c4e69fbe808003998889eca736a6e1c4de48cbb49e4e91",
             "e6dab7c142ee92f6dcd0d54c7b668f4ecab947b2438ca6ef8801c92116c2863b|w=0.000000,0.000000;0.600000,0.500000;2.000000,2.000000|r=0.000000,0.000000;2.000000,2.000000|g=0.000000,0.000000;2.000000,2.000000|b=0.000000,0.000000;2.000000,2.000000;alg=2"),
            // 159: the contrast link is seeded by the tone map and feeds colour; alg=2.
            ("toneMap", "65d51a87a11ca3510313a8f90c26d4d180925a16a22bf2fdda7f91db962f7e17",
             "ae2655131716e5d024c4e69fbe808003998889eca736a6e1c4de48cbb49e4e91|hi=-30.00000;sh=15.00000;alg=5"),
            ("contrast", "14b6649f123fa2feab72d1a0b8f7041abc8b20bf15c6d39547df0d64211029db",
             "65d51a87a11ca3510313a8f90c26d4d180925a16a22bf2fdda7f91db962f7e17|contrast|con=20.00000;alg=2"),
            ("color", "de7cd2787a780d0490060ba4fd99a47f942cd42beef240b67b664be30c706dfa",
             "14b6649f123fa2feab72d1a0b8f7041abc8b20bf15c6d39547df0d64211029db|vib=15.00000;sat=-10.00000;alg=1"),
            ("hsl", "a0c3b41c8b1168864b8d2aeef1a3c98449bc10fd1788d840eafe39fe515adfdd",
             "de7cd2787a780d0490060ba4fd99a47f942cd42beef240b67b664be30c706dfa|hsl|hsl=bands=0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;20.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;alg=1"),
            ("vignette", "8818b5d4e8645cae93b889b5b136344f731383b3bb9e0f113207a088610d705e",
             "a0c3b41c8b1168864b8d2aeef1a3c98449bc10fd1788d840eafe39fe515adfdd|vig=-40.00000;mid=45.00000;fea=60.00000;alg=3"),
            ("display", "94182b5d7340d8f057d3ae8ed4be1e2293bc645e9a4adcd0f200cd496190cf4f",
             "8818b5d4e8645cae93b889b5b136344f731383b3bb9e0f113207a088610d705e|sRGB;bits=8;headroom=1.000|1500x1000"),
        ]

        let actual: [String: String] = [
            "geometry": l.geometry, "sceneLinear": l.sceneLinear, "toneMap": l.toneMap,
            "curve": l.curve, "contrast": l.contrast ?? "", "color": l.color,
            "hsl": l.hsl ?? "",
            "vignette": l.vignette, "display": l.display,
        ]
        let keys = RenderKeyChain.keys(l, identity: "keyvec-fixture")
        let keyByStage: [String: String] = [
            "geometry": keys.geometry, "sceneLinear": keys.sceneLinear, "toneMap": keys.toneMap,
            "curve": keys.curve, "contrast": keys.contrast ?? "", "color": keys.color,
            "hsl": keys.hsl ?? "",
            "vignette": keys.vignette,
            "display": keys.display,
        ]

        for (name, digest, canonical) in expected {
            XCTAssertEqual(actual[name], canonical, "\(name): canonical text changed against M1")
            XCTAssertEqual(Self.sha256(canonical), digest, "\(name): the pinned digest is not SHA-256 of the pinned text")
            XCTAssertEqual(keyByStage[name], digest, "\(name): the graph's key differs from M1")
        }
    }

    /// With masks the chain is nine links, and the two mask keys separate cleanly: a slider move
    /// (adjustments) must not rebuild the atlas, a shape move must rebuild both (§3.2, §3.3).
    func testMaskKeysSplitSelectionFromAdjustments() {
        var edit = m1Fixture()
        edit.masks = [Mask(id: "m-1",
                           components: [MaskComponent(id: "c-1", feather: 0.5,
                                                      shape: .linearGradient(.default))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        let base = links(edit)
        XCTAssertNotNil(base.maskAtlas)
        XCTAssertNotNil(base.localApply)
        XCTAssertNotEqual(base.toneMap, links(m1Fixture()).toneMap,
                          "masks must change the chain below the atlas")

        var moved = edit
        moved.masks[0].adjustments.exposure = 1.25
        let afterAdjust = links(moved)
        XCTAssertEqual(afterAdjust.maskAtlas, base.maskAtlas, "adjustments must not rebuild the atlas")
        XCTAssertNotEqual(afterAdjust.localApply, base.localApply)

        var reshaped = edit
        reshaped.masks[0].components[0].feather = 0.2
        let afterShape = links(reshaped)
        XCTAssertNotEqual(afterShape.maskAtlas, base.maskAtlas)
        XCTAssertNotEqual(afterShape.localApply, base.localApply, "a new atlas must reach the local stage")

        XCTAssertEqual(moved.changedStages(from: edit), [.localApply])
        XCTAssertEqual(reshaped.changedStages(from: edit), [.maskAtlas])
        XCTAssertEqual(edit.changedStages(from: m1Fixture()), [.maskAtlas, .localApply],
                       "empty → non-empty dirties both stages")
        XCTAssertEqual(m1Fixture().changedStages(from: edit), [.maskAtlas, .localApply])
    }

    // MARK: - 005b: linear gradient against the analytic value

    func testLinearGradientMatchesAnalyticDistanceField() throws {
        let image = rampImage()   // 96 × 65, so row 32 has its centre exactly at t = 0.5
        let shape = LinearGradientShape(start: NormalizedPoint(0.5, 0), end: NormalizedPoint(0.5, 1),
                                        midpoint: 0.5)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-lin",
                           components: [MaskComponent(id: "c", feather: 1.0, shape: .linearGradient(shape))],
                           adjustments: LocalAdjustments(exposure: 1))]
        let dump = try atlas(edit, image)
        XCTAssertEqual(dump.width, image.width)
        XCTAssertEqual(dump.height, image.height)
        XCTAssertEqual(dump.maskIDs, ["m-lin"])

        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = linearAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                           feather: 1.0, size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 1.5 / 255.0, "linear gradient deviates from the distance field")

        // The three points the spec calls out, on the vertical centre line. The ramp is symmetric
        // about the middle (102), so `t = 0.5` is the **half-coverage** point, not the rim.
        XCTAssertEqual(sample(dump, 0, 48, 0), 0, accuracy: 1.0 / 255.0, "t = 0 must be 0")
        XCTAssertEqual(sample(dump, 0, 48, 32), 0.5, accuracy: 1.5 / 255.0,
                       "t = 0.5 is the middle of the ramp: exactly half coverage")
        XCTAssertEqual(sample(dump, 0, 48, 64), 1, accuracy: 1.0 / 255.0, "t = 1 must be 1")

        // Monotone along the ramp: a gradient that folds is a gradient that lies.
        for y in 1..<image.height {
            XCTAssertGreaterThanOrEqual(sample(dump, 0, 48, y) + 1e-4, sample(dump, 0, 48, y - 1))
        }
    }

    /// The midpoint exponent `t^(log 0.5 / log m)` decides **where the ramp is centred**. At m = 0.25
    /// the half-way line `t' = ½` sits at `t = 0.25`, so half coverage arrives a quarter of the way
    /// along and the transition is symmetric around that line.
    func testLinearGradientMidpointMovesTheRamp() throws {
        let image = rampImage()
        let shape = LinearGradientShape(start: NormalizedPoint(0.5, 0), end: NormalizedPoint(0.5, 1),
                                        midpoint: 0.25)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-mid",
                           components: [MaskComponent(id: "c", feather: 1.0, shape: .linearGradient(shape))])]
        let dump = try atlas(edit, image)

        // t = 0.25 → row where (y + 0.5)/65 = 0.25 → y = 15.75, so use y = 16 and the analytic value.
        let y = 16
        let expected = linearAlpha(x: 48.5, y: Double(y) + 0.5, shape, feather: 1.0,
                                   size: (image.width, image.height))
        XCTAssertEqual(expected, 0.5058, accuracy: 0.01, "t' = ½ at t = 0.25: half coverage")
        XCTAssertEqual(sample(dump, 0, 48, y), expected, accuracy: 1.5 / 255.0)

        // Two rows below the centre the ramp is already below half — the transition of a m = 0.25
        // midpoint is centred on t = 0.25, so it lives in t ∈ [0.125, 0.375] at f = 1.
        XCTAssertLessThan(sample(dump, 0, 48, y - 4), 0.5)
        XCTAssertGreaterThan(sample(dump, 0, 48, y - 4), 0)

        // With the midpoint pulled up, the solid region arrives far earlier than the geometric middle.
        XCTAssertGreaterThan(sample(dump, 0, 48, image.height / 2), 0.75,
                             "m = 0.25 must be solid well before the middle row")
        for y in 1..<image.height {
            XCTAssertGreaterThanOrEqual(sample(dump, 0, 48, y) + 1e-4, sample(dump, 0, 48, y - 1))
        }
    }

    /// 102 — the feather is a **symmetric** ramp of width `f` of the span, centred on the half-way
    /// line: coverage is 0 below `½ − f/2`, 0.5 at `½`, and 1 above `½ + f/2`. 079 A4 pinned the
    /// opposite (a hard rim at `½` with a squared `0.1·shortEdge` band below it) because it applied the
    /// *radial* rule to the open shapes; that is exactly the bug 102 fixes.
    func testLinearGradientFeatherIsSymmetricAboutTheMidpoint() throws {
        let image = rampImage()
        let shape = LinearGradientShape()          // start (0.5, 0) → end (0.5, 1): a vertical ramp
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-feather",
                           components: [MaskComponent(id: "c", feather: 0.2,
                                                      shape: .linearGradient(shape))])]
        let dump = try atlas(edit, image)

        // f = 0.2 ⇒ the ramp is `t' ∈ [0.4, 0.6]`, symmetric about the middle.
        for y in 0..<image.height {
            let t = (Double(y) + 0.5) / Double(image.height)
            let a = sample(dump, 0, 48, y)
            if t > 0.6 + 1e-9 {
                XCTAssertEqual(a, 1, accuracy: 1.0 / 255.0, "row \(y): past the ramp the mask is solid")
            }
            if t < 0.4 - 1e-9 {
                XCTAssertEqual(a, 0, accuracy: 1.0 / 255.0, "row \(y): below the ramp it is empty")
            }
        }

        // … and the whole field still matches the reference, ramp included.
        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = linearAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                           feather: 0.2, size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 1.5 / 255.0, "linear gradient deviates from the distance field")
    }

    /// 102 acceptance 1–2: on a 1584-px span with `f = 0.5` the ramp is symmetric about `t' = ½`
    /// (`α(0.35) ≈ 0.104`, `α(0.5) = 0.5`, `α(0.35) = 1 − α(0.65)`) and its width is the feather
    /// fraction of the span. The crossing at half coverage is measured by interpolating the two pixel
    /// centres that straddle it, so a half-texel offset cannot hide a one-sided ramp.
    func testLinearGradientFeatherSymmetryAndWidth() throws {
        let image = rampImage(width: 64, height: 1584)   // span = 1584 px, short edge 64
        let shape = LinearGradientShape()                // vertical: (0.5, 0) → (0.5, 1)
        let f = 0.5
        let dump = try atlas(doc(.linearGradient(shape), feather: f), image)
        let span = Double(image.height)

        func analytic(_ t: Double) -> Double {
            linearAlpha(x: 32.5, y: t * span, shape, feather: f, size: (image.width, image.height))
        }
        func row(at t: Double) -> Int { Int((t * span - 0.5).rounded()) }

        // Symmetry and the two spec probes, from the analytic reference and from the atlas.
        XCTAssertEqual(analytic(0.35), 0.1041, accuracy: 0.0005, "smoothstep at t' = 0.35")
        XCTAssertEqual(analytic(0.5), 0.5, accuracy: 1e-12, "the crossing is exactly at t' = ½")
        XCTAssertEqual(analytic(0.35), 1 - analytic(0.65), accuracy: 1e-9, "symmetric ramp")
        XCTAssertEqual(sample(dump, 0, 32, row(at: 0.35)), analytic(0.35), accuracy: 1.5 / 255.0)
        XCTAssertEqual(sample(dump, 0, 32, row(at: 0.5)), 0.5, accuracy: 1.5 / 255.0)

        // Half-coverage crossing, interpolated between rows 791 and 792 (t = 0.4997 / 0.5003).
        let low = row(at: 0.5) - 1, high = row(at: 0.5)
        let a0 = sample(dump, 0, 32, low), a1 = sample(dump, 0, 32, high)
        let fraction = (0.5 - a0) / max(a1 - a0, 1e-9)
        let crossing = ((Double(low) + fraction) + 0.5) / span
        XCTAssertEqual(crossing, 0.5, accuracy: 0.001, "the ½ crossing must sit at t' = 0.5")

        // Width of the visible ramp. `smoothstep` spends its flat tails before 0.02 and after 0.98, so
        // the 2 %–98 % width is `(1 − 2s)` of the ramp with `s²(3−2s) = 0.02` (s ≈ 0.0838), i.e.
        // 0.8323·f·span; the full 0→1 ramp is exactly f·span = 792 px.
        var first: Int?, last: Int?
        for y in 0..<image.height {
            let a = sample(dump, 0, 32, y)
            if a >= 0.02 { first = first ?? y }
            if a >= 0.98, last == nil { last = y }
        }
        let width = Double((last ?? 0) - (first ?? 0) + 1)
        let s = 0.0838
        let expectedWidth = (1 - 2 * s) * f * span
        print(String(format: "102 linear f=0.5 span=%.0f: 2–98%% width %.1f px (analytic %.1f, f·span %.1f)",
                     span, width, expectedWidth, f * span))
        XCTAssertEqual(width, expectedWidth, accuracy: expectedWidth * 0.02,
                       "the 2 %–98 % ramp must be the smoothstep's own width")
        XCTAssertEqual(width, f * span, accuracy: f * span * 0.2,
                       "… and within the quarter of f·span the smoothstep tails occupy")
    }

    // MARK: - 005b: radial gradient against the analytic value

    func testRadialGradientMatchesAnalyticEllipse() throws {
        let image = rampImage()   // 96 × 65
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                        radius: NormalizedPoint(0.25, 0.25),
                                        angle: 0)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-rad",
                           components: [MaskComponent(id: "c", feather: 0.5, shape: .radialGradient(shape))])]
        let dump = try atlas(edit, image)

        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = radialAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                           feather: 0.5, size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 1.5 / 255.0, "radial gradient deviates from the ellipse field")

        // 079 A4: the rim is **solid**, and the ½-coverage radius now sits *outside* it — at r = 1.0625,
        // i.e. 17.27 px, where the pre-A4 rule crossed at r = 0.75 (12.19 px) because the feather ate
        // half the disc.
        let cx = image.width / 2, cy = image.height / 2
        XCTAssertEqual(sample(dump, 0, cx, cy), 1, accuracy: 1.5 / 255.0, "alpha(centre) must be 1")

        let side = Double(min(image.width, image.height))
        let radiusPx = 0.25 * side
        let rOut = 1 + 0.5 * 0.1 * side / radiusPx          // 1.2
        // The last pixel whose centre is inside the rim.
        let insideRim = cx + Int(radiusPx.rounded(.down)) - 1
        XCTAssertEqual(sample(dump, 0, insideRim, cy), 1, accuracy: 1.5 / 255.0,
                       "the rim must be solid, not the start of the ramp")
        // … and the mask is empty past r_out.
        let outsideOuter = cx + Int((radiusPx * rOut).rounded()) + 1
        XCTAssertEqual(sample(dump, 0, outsideOuter, cy), 0, accuracy: 1.5 / 255.0,
                       "coverage past r_out must be 0")

        var crossing = Double.nan
        for x in cx..<(cx + Int(0.3 * side)) where sample(dump, 0, x, cy) <= 0.5 {
            let previous = sample(dump, 0, x - 1, cy)
            let current = sample(dump, 0, x, cy)
            let fraction = (previous - 0.5) / max(previous - current, 1e-6)
            // Pixel x covers [x, x+1) with its centre at x + 0.5; `previous` is the sample one pixel to
            // the left, so the ½ point lies `fraction` of the way from x − 0.5 to x + 0.5.
            crossing = Double(x) - 0.5 + fraction - Double(cx)
            break
        }
        // ratio = ½ ⇒ r² = r_out² − (r_out² − 1)·√½, by the kernel's own quadratic.
        let crossRadius = radiusPx * (rOut * rOut - (rOut * rOut - 1) * 0.5.squareRoot()).squareRoot()
        XCTAssertEqual(crossing, crossRadius, accuracy: 1.0,
                       "alpha must reach 0.5 at r = 1.0625 (one pixel of sampling), not at 0.75")

        // Monotone outwards along the horizontal radius.
        var previous = 2.0
        for x in cx..<min(image.width, cx + Int(0.3 * side)) {
            let a = sample(dump, 0, x, cy)
            XCTAssertLessThanOrEqual(a, previous + 1e-4, "radial coverage grew outwards at x = \(x)")
            previous = a
        }
    }

    /// Rotation is applied in pixel space, so a rotated ellipse is a real ellipse on screen — and an
    /// anisotropic radius (rx ≠ ry) must actually differ from a circle.
    func testRadialGradientRotationAndAnisotropy() throws {
        let image = rampImage()
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                        radius: NormalizedPoint(0.40, 0.10),
                                        angle: 45)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-rot",
                           components: [MaskComponent(id: "c", feather: 0.5, shape: .radialGradient(shape))])]
        let dump = try atlas(edit, image)

        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = radialAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, shape,
                                           feather: 0.5, size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 1.5 / 255.0, "rotated ellipse deviates from the analytic field")

        // Along the rotated major axis (45° down-right) coverage must survive much further out than
        // along the minor axis: at these two points the ellipse radius is 0.25 short-edge units.
        let cx = Double(image.width) / 2, cy = Double(image.height) / 2
        let side = Double(min(image.width, image.height))
        let reach = 0.25 * side
        let alongMajor = (Int((cx + reach * 0.7071).rounded()), Int((cy + reach * 0.7071).rounded()))
        let alongMinor = (Int((cx + reach * 0.7071).rounded()), Int((cy - reach * 0.7071).rounded()))
        XCTAssertGreaterThan(sample(dump, 0, alongMajor.0, alongMajor.1),
                             sample(dump, 0, alongMinor.0, alongMinor.1) + 0.1,
                             "the 45° major axis must out-reach the minor axis")
    }

    // MARK: - 005b: combination, invert, opacity

    /// add = union (max), subtract = `acc·(1−a)`, intersect = `acc·a`, first op ignored.
    func testCombineOpsTruthTable() throws {
        let image = rampImage()
        // Two linear gradients whose ramps overlap at row 30 — 102's symmetric ramp gives a = 0.4539
        // (f = 1, t' = 0.4692) and b = 0.3855 (f = 0.4, t' = 0.4692 in a 0.3…0.7 ramp).
        let narrow = { (op: CombineOp) in
            MaskComponent(id: "c2", op: op, feather: 0.4, shape: .linearGradient(LinearGradientShape()))
        }
        func doc(op: CombineOp, feather: Double = 1.0, opacity: Double = 1,
                 invert: Bool = false, componentInvert: Bool = false) -> EditModel {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-ops", opacity: opacity, invert: invert,
                               components: [MaskComponent(id: "c1", invert: componentInvert,
                                                          feather: feather,
                                                          shape: .linearGradient(LinearGradientShape())),
                                            narrow(op)])]
            return edit
        }
        let y = 30, x = 48

        XCTAssertEqual(sample(try atlas(doc(op: .add), image), 0, x, y), 0.4539, accuracy: 1.5 / 255.0,
                       "add must be max(0.454, 0.386)")
        XCTAssertEqual(sample(try atlas(doc(op: .subtract), image), 0, x, y), 0.2789, accuracy: 1.5 / 255.0,
                       "subtract must be 0.454 · (1 − 0.386)")
        XCTAssertEqual(sample(try atlas(doc(op: .intersect), image), 0, x, y), 0.1750, accuracy: 1.5 / 255.0,
                       "intersect must be 0.454 · 0.386")

        // The first component's op is ignored: a leading subtract must not subtract from nothing.
        var leading = doc(op: .add)
        leading.masks[0].components[0].op = .subtract
        XCTAssertEqual(sample(try atlas(leading, image), 0, x, y), 0.4539, accuracy: 1.5 / 255.0)

        // One component, so invert can be measured without a second component in the way.
        func single(feather: Double, invert: Bool = false, maskInvert: Bool = false,
                    opacity: Double = 1) -> EditModel {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-single", opacity: opacity, invert: maskInvert,
                               components: [MaskComponent(id: "c1", invert: invert, feather: feather,
                                                          shape: .linearGradient(LinearGradientShape()))])]
            return edit
        }
        let base = try atlas(single(feather: 0.2), image)
        let maskInverted = try atlas(single(feather: 0.2, maskInvert: true), image)
        let componentInverted = try atlas(single(feather: 0.2, invert: true), image)
        for y in 0..<image.height {
            XCTAssertEqual(sample(maskInverted, 0, 48, y), 1 - sample(base, 0, 48, y),
                           accuracy: 1.5 / 255.0, "mask invert must be exactly 1 − a (row \(y))")
            XCTAssertEqual(sample(componentInverted, 0, 48, y), 1 - sample(base, 0, 48, y),
                           accuracy: 1.5 / 255.0, "component invert must be exactly 1 − a (row \(y))")
        }

        // Opacity multiplies the combined selection; 0 opacity is no selection at all.
        let faded = try atlas(single(feather: 1.0, opacity: 0.5), image)
        let full = try atlas(single(feather: 1.0), image)
        for y in [8, 32, 56] {
            XCTAssertEqual(sample(faded, 0, 48, y), 0.5 * sample(full, 0, 48, y),
                           accuracy: 1.5 / 255.0, "opacity must scale the combined selection")
        }
        let invisible = try atlas(single(feather: 1.0, opacity: 0), image)
        for y in [8, 32, 56] {
            XCTAssertEqual(sample(invisible, 0, 48, y), 0, accuracy: 1.5 / 255.0,
                           "opacity 0 must be an empty selection")
        }
    }

    /// Shapes that produce no coverage contribute zero — never a guess, never a crash.
    ///
    /// Since 005c the brush, colour and luminance ranges are real shapes, and since 005e a semantic
    /// matte is real *when a route can produce one*. This pins the other half of 005e: with no model
    /// and no system matte, the selection is still empty and the document still renders.
    func testUnimplementedShapesContributeNoCoverage() throws {
        let image = rampImage()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let shapes: [MaskShape] = [
            .semantic(SemanticShape(kind: .sky)),
            .semantic(SemanticShape(kind: .person, provider: .visionForeground)),
            .unsupported(kind: "spotRemoval", payload: .object(["x": .number(0.5)])),
        ]
        for shape in shapes {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-\(shape.kind)",
                               components: [MaskComponent(id: "c", shape: shape)],
                               adjustments: LocalAdjustments(exposure: 2))]
            // The stub answers "no matte" for every kind, which is what this machine's DNGs answer
            // through `CIRAWFilter` (§5.1) — and it keeps the suite off a 120 ms Vision call.
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "shape-coverage"),
                                        semanticMatte: StubSemanticProvider())
            let dump = try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
            XCTAssertEqual(dump.slices.first?.max() ?? 0, 0,
                           "\(shape.kind) must be empty, not approximated")
            XCTAssertEqual(shape.isRenderableNow, shape.isKnownKind,
                           "\(shape.kind): only a kind this build cannot interpret is unrenderable")
        }
    }

    // MARK: - 005b: the atlas lives in uncropped source space

    /// Shapes are stored in *uncropped original* coordinates (§4), so the atlas kernel has to walk
    /// S0's mapping backwards: canvas → content → flip → rotate → crop → source pixels. If that
    /// inverse is wrong a mask is silently displaced on every cropped or straightened photo — the
    /// one failure a single uncropped test would never catch.
    ///
    /// ── why the old version of this test could not fail (派单 080 rewrote it) ────────────────────
    /// It modelled the turn as `r = R(θ)·(uv − ½) + ½` — a rotation of **normalised** coordinates —
    /// because that is what the kernel did. Both sides then agreed on the *sheared* answer, so the
    /// comparison was green while the mask sat hundreds of pixels off the photograph, and there was
    /// no way for it to be anything else: a test that re-derived the implementation's coordinates
    /// pins the coordinates, not the behaviour. The 2/255 tolerance finished the job — it was spent
    /// on a smoothly feathered 20 px ramp, where even the residual 3.8 px disagreement at 96×65 is
    /// worth less than one step, and at a size this small the shear itself is only a couple of
    /// pixels. (Measured: with the kernel fixed and this model left alone it fails at 0.174, i.e. 44
    /// quantisation steps — the assertion was never the thing protecting the mapping.)
    ///
    /// So: the model now spells S0's turn the way S0 spells it (`(uv − ½)·frame` → `R(θ)` →
    /// `÷ frame`, `s0_geometry.metal` / `frame_turn.metal`), and the second half measures a
    /// **distance in pixels** — the small hard disc's coverage centroid against the position S0's map
    /// gives it — because a number in pixels is what the failure actually is. `MaskRotationPixelsTests`
    /// takes that idea to the end (it compares against the rendered picture instead of a formula);
    /// this one stays on the crop/flip composition, at unit cost.
    func testAtlasInvertsCropRotationAndFlip() throws {
        // 960×650, not 96×65: the shear is `|W/H − 1|` in *pixels*, so a thumbnail-sized fixture is
        // a fixture where the wrong answer is only 0.8 px from the right one.
        let image = rampImage(width: 960, height: 650)
        let crop = NormalizedRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)
        let rotation = 7.0
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.4),
                                        radius: NormalizedPoint(0.30, 0.20),
                                        angle: 25)
        // A second, small disc at a known source point: hard-edged and inside the crop, so its
        // centroid is the shape's centre and nothing else.
        let probeSource = NormalizedPoint(crop.x + 0.3 * crop.width, crop.y + 0.3 * crop.height)
        let probe = RadialGradientShape(center: probeSource,
                                        radius: NormalizedPoint(0.06, 0.06), angle: 0)
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: crop, rotationDegrees: rotation,
                                      flipHorizontal: true, flipVertical: false)
        edit.masks = [
            Mask(id: "m-crop",
                 components: [MaskComponent(id: "c", feather: 0.5, shape: .radialGradient(shape))]),
            Mask(id: "m-probe",
                 components: [MaskComponent(id: "p", feather: 0, shape: .radialGradient(probe))]),
        ]

        let dump = try atlas(edit, image)
        let w = Double(image.width), h = Double(image.height)
        let clamped = crop.clamped()
        let frame = (width: Double(dump.width), height: Double(dump.height))
        let cs = cos(rotation * Double.pi / 180), sn = sin(rotation * Double.pi / 180)
        // 132: at θ ≠ 0 the canvas is the rotated crop's bounding box and the frame is centred in it,
        // so `p.f.xy` is the frame's pixel size and the canvas origin is `(frame − canvas)/2`.
        // 188: `outputPixels` is now the **canvas** (the info-bar size), so the frame's own pixels are
        // asked for by name — the two are the same number at every right angle and differ by the AABB
        // margin at any other, which is exactly the difference this forward model needs.
        let framePixels = CropMath.frameSize(edit.geometry.renderCrop(source: ImageSize(width: image.width,
                                                                                       height: image.height)),
                                             in: ImageSize(width: image.width, height: image.height),
                                             allowsOutsideSource: true)
        let fx = Double(framePixels.width), fy = Double(framePixels.height)
        let ox = (Double(dump.width) - fx) / 2, oy = (Double(dump.height) - fy) / 2

        var worst = 0.0
        for y in 0..<dump.height {
            for x in 0..<dump.width {
                // Forward model of one canvas pixel, exactly as `s0_geometry` does it: normalise to
                // the frame, flip, then turn the **pixel** offset about the frame's centre.
                // 126: S0 walks canvas → source with `R(−θ)` (its `sintheta` is the inverse sine),
                // because `+θ` is the picture's clockwise turn in the other direction.
                var u = (Double(x) + 0.5 - ox) / fx
                var v = (Double(y) + 0.5 - oy) / fy
                u = 1 - u                                  // flipHorizontal
                let px = (u - 0.5) * fx, py = (v - 0.5) * fy
                let r = ((px * cs + py * sn) / fx, (-px * sn + py * cs) / fy)
                let sx = (clamped.x + (r.0 + 0.5) * clamped.width) * w
                let sy = (clamped.y + (r.1 + 0.5) * clamped.height) * h

                let expected = radialAlpha(x: sx, y: sy, shape, feather: 0.5,
                                           size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 2.0 / 255.0,
                          "the atlas does not invert crop/rotation/flip (worst \(worst))")
        XCTAssertLessThan(crop.clamped().width * Double(image.width), Double(dump.width),
                          "the atlas follows the crop, not the source")

        // Where S0's own map puts the probe, in canvas pixel indices (`MaskCanvasMapping` is the same
        // arithmetic with the flips in it, which is what makes it the right thing to compare to).
        let mapping = MaskCanvasMapping(geometry: edit.geometry, source: ImageSize(width: image.width,
                                                                                  height: image.height),
                                        content: framePixels,
                                        canvas: ImageSize(width: dump.width, height: dump.height),
                                        origin: (ox, oy))
        let expectedPoint = mapping.canvasPoint(probeSource)

        var sx = 0.0, sy = 0.0, sw = 0.0
        let slice = dump.slices[1]
        for y in 0..<dump.height {
            for x in 0..<dump.width {
                let value = Double(slice[y * dump.width + x])
                if value <= 0 { continue }
                sx += Double(x) * value
                sy += Double(y) * value
                sw += value
            }
        }
        XCTAssertGreaterThan(sw, 0, "the probe disc is not in the frame at all")
        let offset = (sx / sw - expectedPoint.x, sy / sw - expectedPoint.y)
        let distance = (offset.0 * offset.0 + offset.1 * offset.1).squareRoot()
        // 1 px, in pixels: at this size the normalised turn puts the disc 7.6 px away, so this is the
        // assertion that would have caught it (`MaskRotationPixelsTests` states the same thing at
        // 9504×6336, against the picture rather than a map).
        XCTAssertLessThanOrEqual(distance, 1.0,
                                 "the mask's centroid is \(distance) px from where S0 maps it "
                                 + "(\(offset.0), \(offset.1)) — a normalised-coordinate turn?")
    }

    // MARK: - 005b: the stages exist only with masks

    func testEmptyMasksRenderHasNoMaskStages() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let result = try graph.render(EditModel.neutral,
                                      options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertEqual(Set(result.trace.executed), Set(RenderStage.allCases))
        XCTAssertFalse(result.trace.executed.contains(.maskAtlas))
        XCTAssertFalse(result.trace.executed.contains(.localApply))
        XCTAssertFalse(result.trace.skipped.contains(.maskAtlas))
        XCTAssertFalse(result.trace.skipped.contains(.localApply))
        XCTAssertNil(result.keys.maskAtlas)
        XCTAssertNil(result.keys.localApply)
        XCTAssertEqual(result.keys.pipeline.count, 7)
        let dump = try graph.maskAtlas(EditModel.neutral, options: RenderOptions(scale: 1))
        XCTAssertNil(dump, "no masks: no atlas, not an empty one")
    }

    func testMaskedRenderRunsBothNewStages() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-1",
                           components: [MaskComponent(id: "c", shape: .linearGradient(.default))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        // 056: this document's mask carries no hue/saturation, so S3.5 does not exist for it — the
        // trace is the nine pre-056 stages, and the local-colour key stays `nil`.
        // 076 also does not exist here (the document has no band value), S3.7 not (2026-10-28: the
        // document has no grain), S3.4 not (2026-10-28: the document is not black-and-white), S3.8
        // not (2026-10-28, P0 色彩分级: the grade group is neutral) and S1.9 not (2026-10-28,
        // 078 P0-1: the document carries no heal spot), so the expected set drops all six conditional
        // stages.
        XCTAssertEqual(Set(result.trace.executed),
                       Set(RenderStage.order.filter {
                           $0 != .localColor && $0 != .hsl && $0 != .pointColour && $0 != .grain
                               && $0 != .bw
                               && $0 != .grade && $0 != .detailFX && $0 != .heal
                               && $0 != .dehaze   // 117: no dehaze value ⇒ no S1.9
                               && $0 != .contrast   // 098: no contrast value ⇒ no S1.8
                               && $0 != .sharpen    // 185: no sharpAmount ⇒ no S3.10
                       }))
        XCTAssertFalse(result.trace.executed.contains(.localColor),
                       "a mask with only an exposure must not add a colour stage")
        XCTAssertEqual(result.keys.pipeline.count, 9)
        XCTAssertNil(result.keys.localColor)
        XCTAssertNotNil(result.keys.maskAtlas)
        XCTAssertNotNil(result.keys.localApply)

        // Second frame: everything hits, including the atlas (§3.3 item 4 is about sliders, this is
        // about a repeat of the same document).
        let again = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(again.trace.skipped.contains(.maskAtlas))
        XCTAssertTrue(again.trace.skipped.contains(.localApply))
        XCTAssertEqual(result.display?.sha256(), again.display?.sha256())
    }

    /// Dirty-flag split end to end: a slider move must hit the atlas; a shape move must not.
    func testAdjustmentChangeReusesTheAtlas() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-1",
                           components: [MaskComponent(id: "c", shape: .linearGradient(.default))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        _ = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))

        edit.masks[0].adjustments.exposure = 1.5
        let moved = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(moved.trace.skipped.contains(.maskAtlas), "adjustments must not rebuild the atlas")
        XCTAssertTrue(moved.trace.executed.contains(.localApply))

        edit.masks[0].components[0].feather = 0.1
        let reshaped = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(reshaped.trace.executed.contains(.maskAtlas))
        XCTAssertTrue(reshaped.trace.executed.contains(.localApply))
    }

    // MARK: - 005b/005c boundary: the local pass does nothing when it has nothing to do

    /// A mask with neutral adjustments must be indistinguishable from no mask at all — bit-exact
    /// pixels, not "close" (M1-6 discipline, §3.3 item 3).
    func testNeutralMaskIsBitExactAgainstNoMask() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let plain = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        let plainSHA = try XCTUnwrap(plain.display).sha256()

        for adjustments in [LocalAdjustments(), LocalAdjustments(amount: 0, exposure: 2)]
        {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-1",
                               components: [MaskComponent(id: "c", feather: 0.3,
                                                          shape: .linearGradient(.default))],
                               adjustments: adjustments)]
            let masked = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
            XCTAssertEqual(try XCTUnwrap(masked.display).sha256(), plainSHA,
                           "neutral adjustments (\(adjustments.keyString)) must not change a pixel")
        }
    }

    /// Local exposure is a scene-linear gain: coverage 1 doubles the pixel for +1 EV, coverage 0
    /// leaves it untouched.
    func testLocalExposureIsAGainInsideTheSelectionOnly() throws {
        let image = flatImage(0.4)
        let graph = try makeGraph(image)
        let plain = try XCTUnwrap(
            graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true)).display)

        // A radial with feather 0 gives a crisp disc in the middle of the frame.
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-gain",
                           components: [MaskComponent(id: "c", feather: 0.0,
                                                      shape: .radialGradient(RadialGradientShape(
                                                        center: NormalizedPoint(0.5, 0.5),
                                                        radius: NormalizedPoint(0.15, 0.15))))],
                           adjustments: LocalAdjustments(exposure: 1))]
        let lifted = try XCTUnwrap(
            graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)

        /// sRGB OETF, the encode S4 applies at headroom 1.
        func encode(_ v: Float) -> Float {
            v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
        }

        let centre = ((image.height / 2) * image.width + image.width / 2) * 4
        let corner = 0
        // +1 EV on a 0.4 pixel is 0.8 linear, i.e. one stop, *before* the display encode.
        XCTAssertEqual(Float(lifted.rgba[centre]), encode(0.8), accuracy: 1.5 / 255.0,
                       "+1 EV inside the mask must double the linear value")
        XCTAssertEqual(Float(plain.rgba[centre]), encode(0.4), accuracy: 1.5 / 255.0)
        XCTAssertEqual(lifted.rgba[corner], plain.rgba[corner],
                       "outside the selection the pixel must be touched by nothing")
    }

    // MARK: - 005c: five kinds, fixed input → fixed output

    /// One fixed document per shape kind, one pinned number per probe. The literal is what the
    /// closed form in §4.1/§4.4/§4.5 evaluates to at that pixel centre, rounded to 4 decimals; the
    /// 1.5/255 window is the R16F storage plus a float32 kernel against a double reference, and it
    /// is far tighter than any change of formula (the nearest alternative values are ≥ 0.01 away).
    func testFiveShapeKindsProduceFixedCoverage() throws {
        // linear: 102 restores the symmetric ramp (f = 1 spans the whole field), so row 32 is the
        // half-coverage point and rows 28/30 sit on the smoothstep below it.
        let linear = try atlas(doc(.linearGradient(LinearGradientShape()), feather: 1.0), rampImage())
        XCTAssertEqual(sample(linear, 0, 48, 32), 0.5000, accuracy: 1.5 / 255, "t' = 0.5")
        XCTAssertEqual(sample(linear, 0, 10, 28), 0.4082, accuracy: 1.5 / 255, "t' = 0.4385")
        XCTAssertEqual(sample(linear, 0, 80, 30), 0.4539, accuracy: 1.5 / 255, "t' = 0.4692")

        // radial: centre (48, 32.5) px, radius 0.25 · 65 = 16.25 px, feather 0.5 → r_out = 1.2.
        let radial = try atlas(doc(.radialGradient(RadialGradientShape()), feather: 0.5), rampImage())
        XCTAssertEqual(sample(radial, 0, 48, 32), 1.0000, accuracy: 1.5 / 255, "centre")
        XCTAssertEqual(sample(radial, 0, 60, 32), 1.0000, accuracy: 1.5 / 255, "q = 12.5/16.25, inside")
        XCTAssertEqual(sample(radial, 0, 64, 32), 0.8640, accuracy: 1.5 / 255, "q = 1.015, in the falloff")
        XCTAssertEqual(sample(radial, 0, 68, 32), 0.0000, accuracy: 1.5 / 255, "beyond r_out")

        // brush: a vertical capsule at x = 48 px, r = 0.2 · 65 = 13 px, feather 0.5 (core 6.5 px).
        let brush = try atlas(doc(.brush(BrushShape(size: 0.4, strokes: [
            Stroke(points: [0.5, 0.25, 0.5, 0.75], radius: 0.2, feather: 0.5)])), feather: 0.5),
                              rampImage())
        XCTAssertEqual(sample(brush, 0, 48, 32), 1.0000, accuracy: 1.5 / 255, "on the axis")
        XCTAssertEqual(sample(brush, 0, 55, 32), 0.9363, accuracy: 1.5 / 255, "7.5 px out, in the ramp")
        XCTAssertEqual(sample(brush, 0, 62, 32), 0.0000, accuracy: 1.5 / 255, "14.5 px out, past the rim")

        // colour: sample = sRGB-encode of the ramp's left end, tolerance 0.15, smoothness 0.6.
        let colourShape = ColorRangeShape(samples: [Self.leftColourSRGB], tolerance: 0.15,
                                          smoothness: 0.6)
        let colour = try atlas(doc(.colorRange(colourShape), feather: 0.5), colourRampImage())
        XCTAssertEqual(sample(colour, 0, 0, 4), 1.0000, accuracy: 1.5 / 255, "d = 0")
        XCTAssertEqual(sample(colour, 0, 30, 4), 0.5987, accuracy: 1.5 / 255, "d ≈ 0.241")
        XCTAssertEqual(sample(colour, 0, 40, 4), 0.1407, accuracy: 1.5 / 255, "d ≈ 0.310")

        // luminance: the grey ramp in OKLab L, window 0.45…0.85 with 0.08 feathers on both sides.
        let lumaShape = LuminanceRangeShape(low: 0.45, high: 0.85,
                                            lowFeather: 0.08, highFeather: 0.08)
        let luma = try atlas(doc(.luminanceRange(lumaShape), feather: 0.5), greyRampImage())
        XCTAssertEqual(sample(luma, 0, 20, 32), 1.0000, accuracy: 1.5 / 255, "L ≈ 0.595, inside")
        XCTAssertEqual(sample(luma, 0, 60, 32), 0.4264, accuracy: 1.5 / 255, "L ≈ 0.858, high edge")
        XCTAssertEqual(sample(luma, 0, 80, 32), 0.0000, accuracy: 1.5 / 255, "L ≈ 0.944, above")
    }

    // MARK: - 005c: the OKLab metric

    /// The metric itself, against published OKLab values: white is exactly (1, 0, 0), black is 0,
    /// and sRGB red is (0.62796, 0.22486, 0.12585). Pinning these is what makes "the host and the
    /// kernel agree" mean something — two identical mistakes would pass a self-consistency test.
    func testOKLabMetricMatchesPublishedValues() {
        let white = OKLabMetric.fromSRGB(1, 1, 1)
        XCTAssertEqual(white.L, 1, accuracy: 1e-6, "OKLab L of white is exactly 1")
        XCTAssertEqual(white.a, 0, accuracy: 1e-6)
        XCTAssertEqual(white.b, 0, accuracy: 1e-6)

        let black = OKLabMetric.fromSRGB(0, 0, 0)
        XCTAssertEqual(black.L, 0, accuracy: 1e-9)
        XCTAssertEqual(black.a, 0, accuracy: 1e-9)
        XCTAssertEqual(black.b, 0, accuracy: 1e-9)

        let red = OKLabMetric.fromSRGB(1, 0, 0)
        XCTAssertEqual(red.L, 0.62796, accuracy: 1e-4)
        XCTAssertEqual(red.a, 0.22486, accuracy: 1e-4)
        XCTAssertEqual(red.b, 0.12585, accuracy: 1e-4)

        // Distance is symmetric and zero on identity, and one tolerance number covers both axes.
        let g = OKLabMetric.fromSRGB(0.5, 0.5, 0.5)
        XCTAssertEqual(OKLabMetric.distance(g, g), 0, accuracy: 1e-12)
        XCTAssertEqual(OKLabMetric.distance(black, white), 1, accuracy: 1e-6)
    }

    // MARK: - 005c: brush

    /// The whole field, pixel by pixel, against an independent scalar implementation of §4.1.
    func testBrushMatchesTheDistanceField() throws {
        let image = rampImage()
        let brush = BrushShape(size: 0.36, strokes: [
            Stroke(points: [0.2, 0.35, 0.5, 0.55, 0.8, 0.3], radius: 0.14, feather: 0.4, flow: 0.9),
            Stroke(points: [0.3, 0.7, 0.7, 0.72], radius: 0.10, feather: 0.3),
        ])
        let dump = try atlas(doc(.brush(brush), feather: 0.5), image)

        var worst = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let expected = brushAlpha(x: Double(x) + 0.5, y: Double(y) + 0.5, brush,
                                          size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 2.0 / 255.0, "brush deviates from the capsule-chain field")
        // The stroke must actually paint: a kernel that returned 0 everywhere would pass a
        // monotonicity check but not this one. This stroke carries flow 0.9, hence the 0.85 floor.
        XCTAssertGreaterThan(sample(dump, 0, 48, 36), 0.85)
    }

    /// Overlap is a union, never a sum: two crossing strokes and a self-overlapping polyline both
    /// stay at or below 1.0, and the crossing itself reaches exactly 1.0 (§4.1, `MTLBlendOperation
    /// .max` semantics).
    func testBrushOverlapStaysWithinUnitInterval() throws {
        let image = rampImage()
        let crossing = BrushShape(size: 0.3, strokes: [
            Stroke(points: [0.2, 0.5, 0.8, 0.5], radius: 0.15, feather: 0.5),
            Stroke(points: [0.5, 0.2, 0.5, 0.8], radius: 0.15, feather: 0.5),
        ])
        let dump = try atlas(doc(.brush(crossing), feather: 0.5), image)
        let slice = try XCTUnwrap(dump.slices.first)
        XCTAssertLessThanOrEqual(slice.max() ?? 2, 1.0, "coverage left the unit interval")
        XCTAssertEqual(sample(dump, 0, 48, 32), 1.0, accuracy: 1.5 / 255,
                       "the crossing must saturate at 1, not at 2")

        // Every pixel of the crossing area is also exactly what one stroke alone would give, where
        // one stroke alone already saturates: a double-exposure would read 1.5+ there.
        let one = try atlas(doc(.brush(BrushShape(size: 0.3, strokes: [crossing.strokes[0]])),
                                feather: 0.5), image)
        for (x, y) in [(48, 32), (30, 32), (66, 32)] {
            XCTAssertEqual(sample(dump, 0, x, y), sample(one, 0, x, y), accuracy: 1.5 / 255,
                           "overlap at (\(x), \(y)) must equal the single stroke")
        }

        // A polyline that doubles back over itself: the joint is a union, so no seam.
        let foldBack = BrushShape(size: 0.3, strokes: [
            Stroke(points: [0.2, 0.5, 0.8, 0.5, 0.5, 0.5], radius: 0.15, feather: 0.5),
        ])
        let folded = try atlas(doc(.brush(foldBack), feather: 0.5), image)
        XCTAssertLessThanOrEqual((folded.slices.first?.max() ?? 2), 1.0)
        XCTAssertEqual(sample(folded, 0, 48, 32), 1.0, accuracy: 1.5 / 255)
    }

    /// `flow` is the per-stroke multiplier, `erase` is `dst·(1 − src)`, and pressure only scales the
    /// radius (§4.1). One stroke each, so the number at the probe is exactly the parameter.
    func testBrushFlowEraseAndPressure() throws {
        let image = rampImage()
        let band = [(0.5 as Float), 0.25, 0.5, 0.75]

        let full = try atlas(doc(.brush(BrushShape(size: 0.4, strokes: [
            Stroke(points: band, radius: 0.2, feather: 0.5)])), feather: 0.5), image)
        XCTAssertEqual(sample(full, 0, 48, 32), 1.0, accuracy: 1.5 / 255)

        let halfFlow = try atlas(doc(.brush(BrushShape(size: 0.4, strokes: [
            Stroke(points: band, radius: 0.2, feather: 0.5, flow: 0.5)])), feather: 0.5), image)
        XCTAssertEqual(sample(halfFlow, 0, 48, 32), 0.5, accuracy: 1.5 / 255,
                       "flow 0.5 must halve the whole stroke")

        // Paint then erase the same geometry: the erase multiplies the surviving coverage by zero.
        let erased = try atlas(doc(.brush(BrushShape(size: 0.4, strokes: [
            Stroke(points: band, radius: 0.2, feather: 0.5),
            Stroke(points: band, radius: 0.2, feather: 0.5, erase: true)])), feather: 0.5), image)
        XCTAssertEqual(sample(erased, 0, 48, 32), 0.0, accuracy: 1.5 / 255,
                       "erase must remove the coverage it covers")

        // A dot stroke with half pressure has half the radius: the probe at 0.75 r is inside the
        // full dot and outside the pressed one.
        let dot = [(0.5 as Float), 0.5, 0.5, 0.5]
        let probe = (48 + 11, 32)   // 11.5 px from the centre; r = 0.2 · 65 = 13 px
        let pressed = BrushShape(size: 0.4, strokes: [
            Stroke(points: dot, pressure: [0.5], radius: 0.2, feather: 0.0)])
        let fullDot = BrushShape(size: 0.4, strokes: [
            Stroke(points: dot, pressure: [1.0], radius: 0.2, feather: 0.0)])
        XCTAssertEqual(sample(try atlas(doc(.brush(fullDot), feather: 0.5), image), 0,
                              probe.0, probe.1), 1.0, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(try atlas(doc(.brush(pressed), feather: 0.5), image), 0,
                              probe.0, probe.1), 0.0, accuracy: 1.5 / 255,
                       "pressure 0.5 must shrink the radius")
    }

    /// A closed stroke walks the last→first segment; an open one does not. The probe sits on the
    /// midpoint of that closing edge, far from every other segment.
    func testBrushClosedStrokePaintsTheClosingSegment() throws {
        let image = rampImage()
        let points: [Float] = [0.2, 0.2, 0.6, 0.2, 0.4, 0.55]
        let open = try atlas(doc(.brush(BrushShape(size: 0.16, strokes: [
            Stroke(points: points, radius: 0.08, feather: 0.0)])), feather: 0.5), image)
        let closed = try atlas(doc(.brush(BrushShape(size: 0.16, strokes: [
            Stroke(points: points, radius: 0.08, feather: 0.0, closed: true)])), feather: 0.5),
                               image)

        XCTAssertEqual(sample(open, 0, 30, 24), 0.0, accuracy: 1.5 / 255,
                       "the closing edge must not be painted by an open stroke")
        XCTAssertEqual(sample(closed, 0, 30, 24), 1.0, accuracy: 1.5 / 255,
                       "a closed stroke must paint the last→first segment")
        // Everything the open stroke painted is still painted.
        for (x, y) in [(24, 14), (48, 14), (36, 32)] {
            XCTAssertEqual(sample(closed, 0, x, y), sample(open, 0, x, y), accuracy: 1.5 / 255,
                           "closing must only add a segment at (\(x), \(y))")
        }
    }

    // MARK: - 005c: colour range

    /// The colour range is a soft threshold on an OKLab distance: below `tolerance` the coverage is
    /// 1, above `tolerance + smoothness·(0.5 − tolerance)` it is 0, and the edges are monotone.
    /// The set relations are exact, which is what makes this a boundary test rather than a
    /// "looks smooth" test.
    func testColourRangeToleranceBoundary() throws {
        let shape = ColorRangeShape(samples: [Self.leftColourSRGB], tolerance: 0.15, smoothness: 0.6)
        let image = colourRampImage()
        let dump = try atlas(doc(.colorRange(shape), feather: 0.5), image)

        let upper = 0.15 + 0.6 * (0.5 - 0.15)   // 0.36
        var sawInside = false, sawOutside = false, sawRamp = false
        var previous = 2.0
        for x in 0..<image.width {
            let t = Double(x) / Double(image.width - 1)
            let c = Self.colourRampColour(t)
            let d = Self.colourDistance(c, from: [Self.leftColourSRGB])
            let a = sample(dump, 0, x, 4)
            XCTAssertEqual(a, colourRangeAlpha(r: c.0, g: c.1, b: c.2, shape), accuracy: 2.0 / 255,
                           "x = \(x): the kernel and the metric must agree (d = \(d))")
            if d < 0.15 { XCTAssertGreaterThan(a, 1 - 2.0 / 255, "x = \(x): d < tolerance ⇒ 1"); sawInside = true }
            if d > upper { XCTAssertLessThan(a, 2.0 / 255, "x = \(x): d > upper ⇒ 0"); sawOutside = true }
            if a > 0.05 && a < 0.95 { sawRamp = true }
            XCTAssertLessThanOrEqual(a, previous + 1e-4, "coverage must fall along the ramp (x = \(x))")
            previous = a
        }
        XCTAssertTrue(sawInside, "the ramp must start inside the tolerance")
        XCTAssertTrue(sawOutside, "the ramp must end outside it")
        XCTAssertTrue(sawRamp, "the soft threshold must produce a partial ramp, not a step")
        XCTAssertEqual(sample(dump, 0, 0, 0), 1.0, accuracy: 1.5 / 255, "the sample itself is 1")
    }

    /// Two samples: each end of the ramp is covered, which a single sample cannot do — the metric is
    /// the *minimum* distance over the set (§4.4).
    func testColourRangeTakesTheNearestSample() throws {
        let image = colourRampImage()   // left → far
        let one = try atlas(doc(.colorRange(ColorRangeShape(samples: [Self.leftColourSRGB],
                                                             tolerance: 0.1, smoothness: 0.5)),
                                feather: 0.5), image)
        let two = try atlas(doc(.colorRange(ColorRangeShape(
            samples: [Self.leftColourSRGB, Self.farColourSRGB],
            tolerance: 0.1, smoothness: 0.5)), feather: 0.5), image)

        XCTAssertEqual(sample(one, 0, 0, 4), 1.0, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(one, 0, 95, 4), 0.0, accuracy: 1.5 / 255,
                       "one sample cannot cover the far end")
        XCTAssertEqual(sample(two, 0, 0, 4), 1.0, accuracy: 1.5 / 255,
                       "the near end still matches its own sample")
        XCTAssertEqual(sample(two, 0, 95, 4), 1.0, accuracy: 1.5 / 255,
                       "the far end now matches the second sample")
        XCTAssertLessThan(sample(two, 0, 48, 4), 0.5,
                          "the middle belongs to neither sample")
    }

    // MARK: - 005c: luminance range

    /// Both edges of the window, on a grey ramp: 0 under `low − lowFeather`, 1 between the inner
    /// edges, 0 over `high + highFeather`, with the pinned in-between values from §4.5.
    func testLuminanceRangeTwoSidedWindow() throws {
        let shape = LuminanceRangeShape(low: 0.45, high: 0.85, lowFeather: 0.08, highFeather: 0.08)
        let image = greyRampImage()
        let dump = try atlas(doc(.luminanceRange(shape), feather: 0.5), image)

        var sawZero = 0, sawOne = 0
        for x in 0..<image.width {
            let v = h16(Float(Double(x) / Double(image.width - 1)))
            let L = OKLabMetric.fromLinear(v, v, v).L
            let a = sample(dump, 0, x, 32)
            XCTAssertEqual(a, luminanceRangeAlpha(r: v, g: v, b: v, shape), accuracy: 2.0 / 255,
                           "x = \(x): kernel and reference disagree at L = \(L)")
            if L < 0.45 - 0.08 { XCTAssertLessThan(a, 2.0 / 255, "x = \(x): below the window"); sawZero += 1 }
            if L > 0.85 + 0.08 { XCTAssertLessThan(a, 2.0 / 255, "x = \(x): above the window"); sawZero += 1 }
            if L > 0.45 + 0.08 && L < 0.85 - 0.08 {
                XCTAssertGreaterThan(a, 1 - 2.0 / 255, "x = \(x): inside the window"); sawOne += 1
            }
        }
        XCTAssertGreaterThan(sawZero, 10)
        XCTAssertGreaterThan(sawOne, 3)

        // Pinned: L ≈ 0.858 sits on the high feather, L ≈ 0.944 is past it.
        XCTAssertEqual(sample(dump, 0, 60, 32), 0.4264, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(dump, 0, 70, 32), 0.0747, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(dump, 0, 20, 32), 1.0000, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(dump, 0, 80, 32), 0.0000, accuracy: 1.5 / 255)
    }

    /// 167 — the luminance window reaches the HDR half of the axis: neutral patches at 0, +1, +2,
    /// +3 and +4 EV, with `low = 1.6, high = 2.6, feather = 0`.
    ///
    /// The exact `low = 1.6` excludes the +2 EV patch: its OKLab `L` is `cbrt(4) = 1.5874`, just
    /// below the edge (that is the "boundary" the task notes). The second window (`low = 1.55`) is
    /// the same three-patch case with the edge moved below `cbrt(4)`, so the intended
    /// "+2/+3/+4 selected, +1/0 not" is visible as well. Every alpha is printed.
    func testLuminanceRangeExtendsIntoTheHDRDomain() throws {
        let stops: [Double] = [1, 2, 4, 8, 16]   // 0, +1, +2, +3, +4 EV
        let patch = 20, height = 16
        var rgba = [Float16](repeating: 0, count: stops.count * patch * height * 4)
        for (i, value) in stops.enumerated() {
            for y in 0..<height {
                for x in 0..<patch {
                    let o = ((y * stops.count * patch) + i * patch + x) * 4
                    rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value); rgba[o + 3] = 1
                }
            }
        }
        let image = LinearImage(width: stops.count * patch, height: height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")

        func alpha(_ shape: LuminanceRangeShape) throws -> [Double] {
            let dump = try atlas(doc(.luminanceRange(shape), feather: 0), image)
            return (0..<stops.count).map {
                sample(dump, 0, $0 * patch + patch / 2, height / 2)
            }
        }

        let spec = LuminanceRangeShape(low: 1.6, high: 2.6, lowFeather: 0, highFeather: 0)
        let specAlpha = try alpha(spec)
        print("HDR V1 · low 1.6 high 2.6 · " +
              zip(["0", "+1", "+2", "+3", "+4"], specAlpha)
                .map { "\($0)=\(String(format: "%.4f", $1))" }.joined(separator: " · "))
        XCTAssertEqual(specAlpha[0], 0, accuracy: 1.5 / 255, "0 EV is below the window")
        XCTAssertEqual(specAlpha[1], 0, accuracy: 1.5 / 255, "+1 EV is below the window")
        XCTAssertEqual(specAlpha[2], 0, accuracy: 1.5 / 255,
                       "+2 EV L = cbrt(4) = 1.5874 < 1.6, so the exact spec edge excludes it")
        XCTAssertEqual(specAlpha[3], 1, accuracy: 1.5 / 255, "+3 EV (L = 2.0) is selected")
        XCTAssertEqual(specAlpha[4], 1, accuracy: 1.5 / 255, "+4 EV (L = 2.5198) is selected")

        let three = LuminanceRangeShape(low: 1.55, high: 2.6, lowFeather: 0, highFeather: 0)
        let threeAlpha = try alpha(three)
        print("HDR V1 · low 1.55 high 2.6 · " +
              zip(["0", "+1", "+2", "+3", "+4"], threeAlpha)
                .map { "\($0)=\(String(format: "%.4f", $1))" }.joined(separator: " · "))
        XCTAssertEqual(threeAlpha[0], 0, accuracy: 1.5 / 255)
        XCTAssertEqual(threeAlpha[1], 0, accuracy: 1.5 / 255)
        XCTAssertEqual(threeAlpha[2], 1, accuracy: 1.5 / 255, "cbrt(4) = 1.5874 > 1.55")
        XCTAssertEqual(threeAlpha[3], 1, accuracy: 1.5 / 255)
        XCTAssertEqual(threeAlpha[4], 1, accuracy: 1.5 / 255)
    }

    /// 167 (no-migration revision), V5′ — a **new** luminance mask defaults to the whole HDR axis:
    /// `high == hdrMax`. On neutral patches from 0 to +4 EV, the default window covers every stop
    /// (alpha > 0); 0…+3 EV are fully selected, and +4 EV sits exactly on the axis end, where the
    /// centred high feather gives `0.5` by the same `two_sided_window` rule as every other edge.
    func testNewLuminanceMaskDefaultsToTheWholeHDRDomain() throws {
        let shape = LuminanceRangeShape.default
        XCTAssertEqual(shape.low, 0)
        XCTAssertEqual(shape.high, LuminanceRangeShape.hdrMax, accuracy: 1e-12,
                       "a new mask defaults to the whole HDR axis")
        XCTAssertEqual(shape.lowFeather, 0.10, accuracy: 1e-12)
        XCTAssertEqual(shape.highFeather, 0.10, accuracy: 1e-12)

        let stops: [Double] = [1, 2, 4, 8, 16]   // 0, +1, +2, +3, +4 EV
        let patch = 20, height = 16
        var rgba = [Float16](repeating: 0, count: stops.count * patch * height * 4)
        for (i, value) in stops.enumerated() {
            for y in 0..<height {
                for x in 0..<patch {
                    let o = ((y * stops.count * patch) + i * patch + x) * 4
                    rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value); rgba[o + 3] = 1
                }
            }
        }
        let image = LinearImage(width: stops.count * patch, height: height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let dump = try atlas(doc(.luminanceRange(shape), feather: 0), image)
        let alphas = (0..<stops.count).map { sample(dump, 0, $0 * patch + patch / 2, height / 2) }
        print("V5′ default high \(shape.high) · "
              + zip(["0", "+1", "+2", "+3", "+4"], alphas)
                .map { "\($0)=\(String(format: "%.4f", $1))" }.joined(separator: " · "))
        for (i, a) in alphas.enumerated() {
            XCTAssertGreaterThan(a, 0, "the default window must reach the \(i) EV stop")
        }
        for i in 0..<4 {
            XCTAssertEqual(alphas[i], 1, accuracy: 1.5 / 255,
                           "0…+3 EV are fully inside the default window")
        }
        XCTAssertEqual(alphas[4], 0.5, accuracy: 1.5 / 255,
                       "+4 EV is the axis end; the centred feather gives 0.5")
    }

    /// 167 (no-migration revision) — a v1 document (no `v`) decodes **verbatim**: the five stored
    /// fields are kept exactly as written, so `high = 1.0` stays `1.0`, and only the encoding
    /// generation is promoted to `v == 2`. A field the v1 document omits falls back to the **v1**
    /// default (`high = 1.0`), never the new HDR `hdrMax`: an old document missing `high` must not
    /// silently become an HDR select-all.
    func testLuminanceRangeV1DocumentsDecodeVerbatim() throws {
        func decode(_ json: String) throws -> LuminanceRangeShape {
            try JSONDecoder().decode(LuminanceRangeShape.self, from: Data(json.utf8))
        }

        let full = try decode(#"{"low":0,"high":1.0,"lowFeather":0.10,"highFeather":0.10}"#)
        XCTAssertEqual(full.high, 1.0, accuracy: 1e-12, "no migration: a v1 `high` is kept")
        XCTAssertEqual(full.low, 0)
        XCTAssertEqual(full.lowFeather, 0.10, accuracy: 1e-12)
        XCTAssertEqual(full.highFeather, 0.10, accuracy: 1e-12)
        XCTAssertEqual(full.v, 2, "the encoding generation is promoted")

        let narrow = try decode(#"{"low":0.4,"high":0.6,"lowFeather":0.05,"highFeather":0.07}"#)
        XCTAssertEqual(narrow.high, 0.6, accuracy: 1e-12, "a mid-tone cut stays a mid-tone cut")
        XCTAssertEqual(narrow.low, 0.4, accuracy: 1e-12)
        XCTAssertEqual(narrow.lowFeather, 0.05, accuracy: 1e-12)
        XCTAssertEqual(narrow.highFeather, 0.07, accuracy: 1e-12)
        XCTAssertEqual(narrow.v, 2)

        // Re-encode → v2 with the same numbers; decoding that v2 document is a no-op.
        let encoded = try JSONEncoder().encode(full)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"v\":2"), "the document must encode its generation")
        XCTAssertEqual(try JSONDecoder().decode(LuminanceRangeShape.self, from: encoded), full,
                       "decoding a v2 document must be a no-op")
        let literal = LuminanceRangeShape(low: 0, high: 1.0)
        let literalAgain = try JSONDecoder().decode(LuminanceRangeShape.self,
                                                    from: JSONEncoder().encode(literal))
        XCTAssertEqual(literalAgain.high, 1.0, accuracy: 1e-12, "a v2 `high = 1.0` is a real edge")

        // Missing fields: v1 falls back to v1 defaults (SDR `high = 1.0`); v2 keeps the HDR default.
        let v1Missing = try decode(#"{"low":0}"#)
        XCTAssertEqual(v1Missing.high, 1.0, accuracy: 1e-12,
                       "a v1 document missing `high` must not become an HDR select-all")
        XCTAssertEqual(v1Missing.lowFeather, 0.10, accuracy: 1e-12)
        XCTAssertEqual(v1Missing.highFeather, 0.10, accuracy: 1e-12)
        XCTAssertEqual(v1Missing.v, 2)
        let v2Missing = try decode(#"{"low":0,"v":2}"#)
        XCTAssertEqual(v2Missing.high, LuminanceRangeShape.hdrMax, accuracy: 1e-12,
                       "only a v2 document gets the new default")
        print("V1 DECODE · full high \(full.high) · narrow high \(narrow.high) · "
              + "v1 missing high \(v1Missing.high) · v2 missing high \(v2Missing.high) · v \(full.v)")
    }

    /// 167 (no-migration revision), V2′ — a v1 `{low:0, high:1.0, f:.10/.10}` document keeps
    /// `high = 1.0` verbatim. The old predicate folded `clamp(light, 0, 1)` and the reference below
    /// keeps that clamp, exactly like the pre-167 kernel.
    ///
    /// **Measured fact (not the assumption in the task):** the two kernels agree at display white
    /// (0 EV, `L = 1`: both give `0.5` — this window's upper feather is centred on `high`, so neither
    /// the old nor the new window ever returns `1` there). Above white they **cannot** agree: the old
    /// clamp turns every highlight into `L = 1` (alpha `0.5`), while the new kernel reads
    /// `L = cbrt(2^stop) > 1` and the preserved `high = 1.0` closes the window (alpha `0`). Keeping
    /// the old clamp and getting byte equality across 0…+4 EV would require the new kernel to fold
    /// highlights back to `L = 1` — that is exactly the clamp 167 removes. The no-migration decision
    /// is still the right one: the old document keeps its numbers, and it does **not** start selecting
    /// highlights; it is the *old clamp* that half-selected them.
    func testV1FullRangeDocumentAgainstTheOldClampedKernel() throws {
        func oldAlpha(_ r: Double, _ g: Double, _ b: Double, _ s: LuminanceRangeShape) -> Double {
            let clamped = Self.workingLinear(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
            let L = OKLabMetric.fromLinear(clamped.0, clamped.1, clamped.2).L
            let o = s.ordered
            let loF = max(o.lowFeather, 0), hiF = max(o.highFeather, 0)
            let inLow = smoothstep(o.low - loF, max(o.low + loF, o.low - loF + 1e-5), L)
            let inHigh = 1 - smoothstep(o.high - hiF, max(o.high + hiF, o.high - hiF + 1e-5), L)
            return min(max(inLow * inHigh, 0), 1)
        }

        let fullV1 = try JSONDecoder().decode(
            LuminanceRangeShape.self,
            from: Data(#"{"low":0,"high":1.0,"lowFeather":0.10,"highFeather":0.10}"#.utf8))
        XCTAssertEqual(fullV1.high, 1.0, accuracy: 1e-12)

        // 0, +1, +2, +3, +4 EV neutral patches — the top half is above display white.
        let stops: [Double] = [1, 2, 4, 8, 16]
        let patch = 20, height = 16
        var rgba = [Float16](repeating: 0, count: stops.count * patch * height * 4)
        for (i, value) in stops.enumerated() {
            for y in 0..<height {
                for x in 0..<patch {
                    let o = ((y * stops.count * patch) + i * patch + x) * 4
                    rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value); rgba[o + 3] = 1
                }
            }
        }
        let image = LinearImage(width: stops.count * patch, height: height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let dump = try atlas(doc(.luminanceRange(fullV1), feather: 0), image)

        var oldValues: [Float] = [], newValues: [Float] = []
        for i in 0..<(image.width * image.height) {
            let r = Double(image.rgba[i * 4])
            oldValues.append(Float(oldAlpha(r, r, r, LuminanceRangeShape(low: 0, high: 1.0,
                                                                        lowFeather: 0.10,
                                                                        highFeather: 0.10))))
            newValues.append(dump.slices[0][i])
        }
        let patchAlpha = { (values: [Float]) in
            (0..<stops.count).map { Double(values[(height / 2) * image.width + $0 * patch + patch / 2]) }
        }
        let old = patchAlpha(oldValues), new = patchAlpha(newValues)
        let fmt = { (v: [Double]) in
            zip(["0", "+1", "+2", "+3", "+4"], v)
                .map { "\($0)=\(String(format: "%.4f", $1))" }.joined(separator: " · ")
        }
        print("V2′ old \(fmt(old))")
        print("V2′ new \(fmt(new))")
        print("V2′ digest old \(quantisedDigest(oldValues)) new \(quantisedDigest(newValues))")

        // Display white (0 EV) is the last tone the old clamp leaves untouched.
        XCTAssertEqual(new[0], old[0], accuracy: 1.5 / 255,
                       "V2′: at display white the two kernels must agree")
        // Above white the old clamp is the only difference: it folds to L = 1 (0.5), the new kernel
        // reads L > 1 and the preserved high = 1.0 window closes (0). Measured, not assumed.
        for i in 1..<stops.count {
            XCTAssertEqual(old[i], 0.5, accuracy: 1.5 / 255, "old clamp folds \(i) to L = 1")
            XCTAssertEqual(new[i], 0.0, accuracy: 1.5 / 255,
                           "high = 1.0 is preserved, so \(i) EV is above the window")
        }
        XCTAssertNotEqual(quantisedDigest(newValues), quantisedDigest(oldValues),
                          "full-range equality is impossible with the old clamp kept")
    }

    /// 167 (no-migration revision), V3′ — a v1 `{low:0.4, high:0.6}` document decodes verbatim (the
    /// omitted feathers fall back to the v1 `0.10`) and renders the old selection byte for byte.
    ///
    /// The image is three flat SDR bands at `L = 0.2 / 0.5 / 0.8`: with `low = 0.4, high = 0.6` and
    /// `feather = 0.10` the window is `0.3…0.7`, so the bands are exactly `0 / 1 / 0`. Flat bands are
    /// deliberate: the atlas is `rgba16Float`, and a continuous ramp puts many pixels within one
    /// 8-bit rounding step of a boundary, where the GPU's float fold and the CPU's double fold
    /// disagree by half an ULP. The 8-bit digest is meaningful on values a half-float can hold
    /// exactly, which is what "byte for byte" means here.
    func testV1MidToneDocumentRendersTheOldSelectionByteForByte() throws {
        func oldAlpha(_ r: Double, _ g: Double, _ b: Double, _ s: LuminanceRangeShape) -> Double {
            let clamped = Self.workingLinear(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
            let L = OKLabMetric.fromLinear(clamped.0, clamped.1, clamped.2).L
            let o = s.ordered
            let loF = max(o.lowFeather, 0), hiF = max(o.highFeather, 0)
            let inLow = smoothstep(o.low - loF, max(o.low + loF, o.low - loF + 1e-5), L)
            let inHigh = 1 - smoothstep(o.high - hiF, max(o.high + hiF, o.high - hiF + 1e-5), L)
            return min(max(inLow * inHigh, 0), 1)
        }

        let narrowV1 = try JSONDecoder().decode(
            LuminanceRangeShape.self,
            from: Data(#"{"low":0.4,"high":0.6}"#.utf8))
        XCTAssertEqual(narrowV1.low, 0.4, accuracy: 1e-12)
        XCTAssertEqual(narrowV1.high, 0.6, accuracy: 1e-12)
        XCTAssertEqual(narrowV1.lowFeather, 0.10, accuracy: 1e-12, "v1 fallback feather")
        XCTAssertEqual(narrowV1.highFeather, 0.10, accuracy: 1e-12, "v1 fallback feather")
        XCTAssertEqual(narrowV1.v, 2)

        // Three flat SDR bands whose OKLab L is exactly 0.2 / 0.5 / 0.8 (linear v³).
        let bands: [Float] = [0.008, 0.125, 0.512]
        let band = 16, height = 16
        var rgba = [Float16](repeating: 0, count: bands.count * band * height * 4)
        for (b, value) in bands.enumerated() {
            for y in 0..<height {
                for x in 0..<band {
                    let o = ((y * bands.count * band) + b * band + x) * 4
                    rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value); rgba[o + 3] = 1
                }
            }
        }
        let sdr = LinearImage(width: bands.count * band, height: height, rgba: rgba,
                              colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let dump = try atlas(doc(.luminanceRange(narrowV1), feather: 0), sdr)
        var oldNarrow: [Float] = [], newNarrow: [Float] = []
        for i in 0..<(sdr.width * sdr.height) {
            let r = Double(sdr.rgba[i * 4])
            oldNarrow.append(Float(oldAlpha(r, r, r, LuminanceRangeShape(low: 0.4, high: 0.6,
                                                                        lowFeather: 0.10,
                                                                        highFeather: 0.10))))
            newNarrow.append(dump.slices[0][i])
        }
        XCTAssertEqual(quantisedDigest(newNarrow), quantisedDigest(oldNarrow),
                       "V3′: a v1 mid-tone cut must render the old selection exactly")
        let alphas = (0..<bands.count).map {
            sample(dump, 0, $0 * band + band / 2, height / 2)
        }
        print("V3′ L 0.2/0.5/0.8 → \(alphas.map { String(format: "%.4f", $0) }.joined(separator: " / "))")
        print("V3′ digest old \(quantisedDigest(oldNarrow)) new \(quantisedDigest(newNarrow))")
        XCTAssertEqual(alphas[0], 0, accuracy: 1.5 / 255)
        XCTAssertEqual(alphas[1], 1, accuracy: 1.5 / 255)
        XCTAssertEqual(alphas[2], 0, accuracy: 1.5 / 255)
    }


    /// `low > high` is a mirror, not an empty selection: the descriptor is repaired by swapping the
    /// bounds (and their feathers) once, in the host table (§4.5).
    func testLuminanceRangeRepairsAnInvertedPair() throws {
        let image = greyRampImage()
        let inverted = LuminanceRangeShape(low: 0.85, high: 0.45,
                                           lowFeather: 0.08, highFeather: 0.02)
        let ordered = LuminanceRangeShape(low: 0.45, high: 0.85,
                                          lowFeather: 0.02, highFeather: 0.08)
        XCTAssertFalse(inverted.isOrdered)
        XCTAssertTrue(ordered.isOrdered)

        let a = try atlas(doc(.luminanceRange(inverted), feather: 0.5), image)
        let b = try atlas(doc(.luminanceRange(ordered), feather: 0.5), image)
        for x in 0..<image.width {
            XCTAssertEqual(sample(a, 0, x, 32), sample(b, 0, x, 32), accuracy: 1e-4,
                           "x = \(x): the inverted pair must render as its mirror")
        }
        XCTAssertGreaterThan(a.slices[0].max() ?? 0, 0.99, "and it must not be empty")
    }

    /// 139: the picker's two window gestures are pure Core helpers, and their coordinate is the
    /// kernel's own OKLab L on working-linear light. 167 moved that coordinate to the HDR axis.
    func testLuminancePickerHelpersUseTheKernelCoordinate() {
        // A full-range window opens 0.25 wide, centred; a narrower one keeps its width.
        let opened = LuminanceRangeShape.default.centring(on: 0.9)
        XCTAssertEqual(opened.low, 0.775, accuracy: 1e-12)
        XCTAssertEqual(opened.high, 1.025, accuracy: 1e-12)
        let kept = LuminanceRangeShape(low: 0.10, high: 0.40).centring(on: 0.60)
        XCTAssertEqual(kept.low, 0.45, accuracy: 1e-12)
        XCTAssertEqual(kept.high, 0.75, accuracy: 1e-12)
        XCTAssertEqual(kept.lowFeather, LuminanceRangeShape.default.lowFeather)
        XCTAssertEqual(kept.highFeather, LuminanceRangeShape.default.highFeather)

        // ⌥ moves only the nearer edge and never repairs the order.
        let option = LuminanceRangeShape(low: 0.775, high: 1.0).movingNearerEdge(to: 0.1)
        XCTAssertEqual(option.low, 0.1, accuracy: 1e-12)
        XCTAssertEqual(option.high, 1.0, accuracy: 1e-12)
        let crossed = LuminanceRangeShape(low: 0.2, high: 0.4).movingNearerEdge(to: 0.9)
        XCTAssertEqual(crossed.low, 0.2, accuracy: 1e-12)
        XCTAssertEqual(crossed.high, 0.9, accuracy: 1e-12)

        // The picker's luminance is the kernel's: OKLab L of the unclamped working-linear fold.
        let mid = OKLabMetric.maskLuminance(fromDecodedSRGB: 0.5, 0.5, 0.5)
        let working = ColorPrimaries.conversion(from: .sRGB, to: .working)
            .applying(to: SIMD3(0.5, 0.5, 0.5))
        let expected = OKLabMetric.fromLinear(working.x, working.y, working.z).L
        XCTAssertEqual(mid, expected, accuracy: 1e-12)
        let narrow = LuminanceRangeShape(low: mid - 0.02, high: mid + 0.02,
                                         lowFeather: 0, highFeather: 0)
        XCTAssertGreaterThanOrEqual(luminanceRangeAlpha(r: 0.5, g: 0.5, b: 0.5, narrow), 0.95,
                                    "a ±0.02 window centred on the picker's value covers the pixel")
        // 167: above display white the picker reaches the HDR axis (cbrt(4) = 1.5874), capped only
        // at the axis end.
        XCTAssertEqual(OKLabMetric.maskLuminance(fromDecodedSRGB: 4, 4, 4), cbrt(4.0),
                       accuracy: 1e-6)
        XCTAssertLessThanOrEqual(OKLabMetric.maskLuminance(fromDecodedSRGB: 100, 100, 100),
                                 LuminanceRangeShape.hdrMax + 1e-12)
        print("PICKER CORE · mid L \(mid) · opened \(opened.low)…\(opened.high)")
    }

    // MARK: - 005c: amount and opacity

    /// `amount = 0` is the identity branch, bit-exactly, even when every other slider is at an
    /// extreme: the pixel is not "close to" the unmasked frame, it is the same half. This is §3.3
    /// item 3 with the mask *present* — the pass runs, it just writes the source back.
    func testAmountZeroIsBitExactEvenWithExtremeSliders() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let plain = try XCTUnwrap(
            graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let plainSHA = plain.sha256()

        var extremes = LocalAdjustments(amount: 0, exposure: 4, temperature: 100, tint: -100,
                                        contrast: 100, highlights: 100, shadows: -100,
                                        whites: 100, blacks: -100, hue: 180, saturation: 100)
        XCTAssertTrue(extremes.isIdentity, "amount 0 makes any slider set the identity")

        let shapes: [MaskShape] = [
            .brush(BrushShape(size: 0.3, strokes: [Stroke(points: [0.2, 0.3, 0.8, 0.7],
                                                          radius: 0.15, feather: 0.4)])),
            .colorRange(ColorRangeShape(samples: [Self.leftColourSRGB], tolerance: 0.4)),
            .luminanceRange(LuminanceRangeShape(low: 0.1, high: 0.9)),
        ]
        for shape in shapes {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-\(shape.kind)",
                               components: [MaskComponent(id: "c", feather: 0.5, shape: shape)],
                               adjustments: extremes)]
            let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
            XCTAssertEqual(try XCTUnwrap(result.display).sha256(), plainSHA,
                           "\(shape.kind) with amount 0 must be bit-identical to no mask")
            XCTAssertTrue(result.trace.executed.contains(.localApply),
                          "the pass must have run; the identity branch is what is under test")
            XCTAssertTrue(result.trace.executed.contains(.maskAtlas))
        }

        // And the same document with amount 100 must *not* be identical, or the test proves nothing.
        extremes.amount = 100
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-live",
                           components: [MaskComponent(id: "c", shape: shapes[0])],
                           adjustments: extremes)]
        let live = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertNotEqual(try XCTUnwrap(live.display).sha256(), plainSHA,
                          "the fixture must be able to change a pixel")
    }

    /// The weight is `coverage · opacity · amount`: opacity lives in the atlas, amount in the local
    /// table, and S1.6 multiplies them (§3.1, §4.1). 0.5 × 0.5 = 0.25, so a +1 EV mask lifts a 0.4
    /// pixel to 0.4·(1 − 0.25) + 0.8·0.25 = 0.5 — not to 0.8 and not to 0.4.
    func testOpacityTimesAmountWeightsTheGain() throws {
        let image = flatImage(0.4)
        let graph = try makeGraph(image)
        func encode(_ v: Float) -> Float {
            v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
        }
        let disc = RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                       radius: NormalizedPoint(0.15, 0.15))

        func frame(opacity: Double, amount: Double) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-w", opacity: opacity,
                               components: [MaskComponent(id: "c", feather: 0,
                                                          shape: .radialGradient(disc))],
                               adjustments: LocalAdjustments(amount: amount, exposure: 1))]
            return try XCTUnwrap(
                graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        }

        let full = try frame(opacity: 1, amount: 100)
        let quarter = try frame(opacity: 0.5, amount: 50)
        let centre = ((image.height / 2) * image.width + image.width / 2) * 4
        XCTAssertEqual(Float(full.rgba[centre]), encode(0.8), accuracy: 1.5 / 255,
                       "full weight must be the whole +1 EV")
        XCTAssertEqual(Float(quarter.rgba[centre]), encode(0.5), accuracy: 1.5 / 255,
                       "opacity 0.5 × amount 50 must quarter the gain")
        XCTAssertEqual(quarter.rgba[0], full.rgba[0], "outside the disc nothing may change")
    }

    // MARK: - 005c: dirty flags

    /// Editing the brush's point sequence must rebuild the atlas; moving `amount` must not. The
    /// split rides on the existing `selectionKey` / `applyKey` — no new key material (§3.2).
    func testBrushEditRebuildsAtlasAndAmountDoesNot() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-brush",
                           components: [MaskComponent(id: "c", feather: 0.5,
                                                      shape: .brush(BrushShape(size: 0.3, strokes: [
                                                        Stroke(points: [0.2, 0.3, 0.8, 0.3],
                                                               radius: 0.12)])))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        let first = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(first.trace.executed.contains(.maskAtlas))

        // Repeat the same document: both mask stages hit.
        let again = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(again.trace.skipped.contains(.maskAtlas))
        XCTAssertTrue(again.trace.skipped.contains(.localApply))

        // One more point in the stroke: the selection moved, so the atlas is dirty.
        edit.masks[0].components[0].shape = .brush(BrushShape(size: 0.3, strokes: [
            Stroke(points: [0.2, 0.3, 0.5, 0.6, 0.8, 0.3], radius: 0.12)]))
        let moved = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(moved.trace.executed.contains(.maskAtlas), "a new point must rebuild the atlas")
        XCTAssertTrue(moved.trace.executed.contains(.localApply))

        // Only `amount`: the atlas is reused, the local pass re-runs.
        edit.masks[0].adjustments.amount = 40
        let faded = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(faded.trace.skipped.contains(.maskAtlas), "amount must not rebuild the atlas")
        XCTAssertTrue(faded.trace.executed.contains(.localApply))

        // The key materials say the same thing, so a cache on disk would agree with the trace.
        var onlyAmount = edit
        onlyAmount.masks[0].adjustments.amount = 90
        XCTAssertEqual(onlyAmount.changedStages(from: edit), [.localApply])
        var onlyPoints = edit
        onlyPoints.masks[0].components[0].shape = .brush(BrushShape(size: 0.3, strokes: [
            Stroke(points: [0.2, 0.3, 0.9, 0.9], radius: 0.12)]))
        XCTAssertEqual(onlyPoints.changedStages(from: edit), [.maskAtlas])
    }

    // MARK: - 005d: feather and refine (radius mapping, edge clamp, unit interval)

    /// One mask with the *mask-level* feather/refine set — the operators 005d adds. Kept separate from
    /// `doc(...)` (which sets the component feather) so a test never confuses the shape's own
    /// transition width with the atlas's spatial blur.
    private func maskDoc(_ shape: MaskShape, componentFeather: Double = 0.5,
                         maskFeather: Double = 0, refine: Double = 0,
                         opacity: Double = 1, invert: Bool = false,
                         adjustments: LocalAdjustments = .identity,
                         id: String = "m-005d") -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: id, opacity: opacity, invert: invert,
                           feather: maskFeather, refine: refine,
                           components: [MaskComponent(id: "c", feather: componentFeather, shape: shape)],
                           adjustments: adjustments)]
        return edit
    }

    /// Pixels strictly between the extremes: the width of a transition, in pixels.
    private func partialCount(_ dump: MaskAtlasDump, slice: Int = 0,
                              below: Double = 0.02, above: Double = 0.98) -> Int {
        guard dump.slices.indices.contains(slice) else { return 0 }
        let lo = Float(below), hi = Float(above)
        return dump.slices[slice].filter { $0 > lo && $0 < hi }.count
    }

    /// §4.6/§2 — both radii are pixel lengths derived from the **short edge**, so one parameter gives
    /// the same shape at thumbnail, fit, 1:1 and export scale.
    func testFeatherAndGuidedRadiiFollowTheShortEdge() {
        let content = ImageSize(width: 2400, height: 1600)
        // feather = 1 is the whole documented span: 10 % of the short edge.
        XCTAssertEqual(MaskRadius.featherPixels(0, content: content), 0)
        XCTAssertEqual(MaskRadius.featherPixels(0.5, content: content), 80, accuracy: 1e-9)
        XCTAssertEqual(MaskRadius.featherPixels(1, content: content), 160, accuracy: 1e-9)
        XCTAssertEqual(MaskRadius.featherPixels(4, content: content), 160, accuracy: 1e-9,
                       "the radius clamps at the documented maximum instead of growing without bound")
        XCTAssertEqual(MaskRadius.featherPixels(-1, content: content), 0)

        // Scale invariance: half the canvas, half the radius — the fault that would make a thumbnail's
        // feather and an export's feather different shapes.
        let half = ImageSize(width: 1200, height: 800)
        XCTAssertEqual(MaskRadius.featherPixels(0.5, content: half) * 2,
                       MaskRadius.featherPixels(0.5, content: content), accuracy: 1e-9)

        // §4.6: kernelDiameter = odd(clamp(2·round(max(W,H)/30) + 1, 3, 65)).
        XCTAssertEqual(MaskRadius.guidedKernelDiameter(ImageSize(width: 96, height: 64)), 7)
        XCTAssertEqual(MaskRadius.guidedKernelDiameter(ImageSize(width: 300, height: 200)), 21)
        XCTAssertEqual(MaskRadius.guidedKernelDiameter(ImageSize(width: 2731, height: 1500)), 65)
        XCTAssertEqual(MaskRadius.guidedKernelDiameter(ImageSize(width: 10, height: 10)), 3,
                       "the floor is a 3-tap kernel, never a degenerate one")
        XCTAssertEqual(MaskRadius.guidedRadiusPixels(0, content: content), 0, "refine 0 = no radius")
        XCTAssertEqual(MaskRadius.guidedRadiusPixels(1, content: content), 32)

        // ε: 0.01 at "barely on", 1e−3 at full strength.
        XCTAssertEqual(MaskRadius.guidedEpsilon(0), 0.01, accuracy: 1e-12)
        XCTAssertEqual(MaskRadius.guidedEpsilon(1), 0.001, accuracy: 1e-12)

        // The halo is both radii, and it is what the tile bounds are grown by.
        let mask = Mask(id: "m", feather: 0.5, refine: 1)
        XCTAssertEqual(MaskRadius.haloPixels(of: mask, content: content), 112)   // 80 + 32
        XCTAssertEqual(MaskRadius.atlasDependency(of: mask, content: content), .neighborhood(radius: 112))
        XCTAssertEqual(MaskRadius.atlasDependency(of: Mask(id: "m"), content: content), .pointwise)
    }

    /// The blur radius must actually be realised in pixels: a hard-edged disc whose mask-level feather
    /// is r gets a transition about 2r wide, and one that is 2× the radius is about 2× as wide.
    func testFeatherRealisesItsRadiusInPixels() throws {
        let image = flatImage(0.4, width: 192, height: 128)   // short edge 128 ⇒ feather 0.5 = 6.4 px
        let disc = MaskShape.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.5, 0.5), radius: NormalizedPoint(0.30, 0.30)))
        let hard = try atlas(maskDoc(disc, componentFeather: 0, maskFeather: 0), image)
        let soft = try atlas(maskDoc(disc, componentFeather: 0, maskFeather: 0.5), image)
        let softer = try atlas(maskDoc(disc, componentFeather: 0, maskFeather: 1.0), image)

        XCTAssertLessThan(partialCount(hard), 8, "a feather-0 disc has an aliased, one-pixel edge")
        let content = ImageSize(width: image.width, height: image.height)
        // A box blur of radius r turns a step into a ramp 2r wide, so this is the width the parameter
        // promises — measured, not assumed.
        let expected = 2 * MaskRadius.featherPixels(0.5, content: content)   // ≈ 12.8 px
        let width = { (dump: MaskAtlasDump) -> Double in
            var count = 0
            for x in 0..<dump.width where (dump.value(slice: 0, x: x, y: 64) ?? 0) > 0.02
                && (dump.value(slice: 0, x: x, y: 64) ?? 0) < 0.98 { count += 1 }
            return Double(count) / 2   // both sides of the disc
        }
        XCTAssertEqual(width(soft), expected, accuracy: expected * 0.35,
                       "the transition on one side must be about 2 × the feather radius")
        XCTAssertGreaterThan(partialCount(soft), 500, "feather 0.5 must soften a 192×128 disc")
        // Twice the parameter is twice the radius, i.e. about twice the transition width.
        XCTAssertEqual(width(softer), 2 * width(soft), accuracy: width(soft) * 0.6)
        for value in softer.slices[0] + soft.slices[0] {
            XCTAssertTrue(value >= 0 && value <= 1, "coverage left [0, 1]: \(value)")
        }
    }

    /// Edge clamping (§3.4): a mask that covers the whole frame must still be 1.0 at the border. Zero
    /// padding — the obvious implementation — darkens every edge, which reads as a vignette painted
    /// into the mask and would be blamed on the local adjustment, not on the blur.
    func testFeatherClampsAtTheFrameBorder() throws {
        let image = flatImage(0.4, width: 96, height: 64)
        // Radius 1.0 short-edge units: the ellipse covers every corner (57.7 px < 64 px), so the
        // unblurred coverage is exactly 1 everywhere.
        let covering = MaskShape.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.5, 0.5), radius: NormalizedPoint(1.0, 1.0)))
        let hard = try atlas(maskDoc(covering, componentFeather: 0, maskFeather: 0), image)
        let soft = try atlas(maskDoc(covering, componentFeather: 0, maskFeather: 0.8), image)
        let softest = try atlas(maskDoc(covering, componentFeather: 0, maskFeather: 1.0), image)

        XCTAssertEqual(Double(hard.slices[0].min() ?? 0), 1, accuracy: 1.0 / 255,
                       "the fixture must be a uniform 1.0 field, or the clamp is not what is tested")
        let border = [(0, 0), (95, 0), (0, 63), (95, 63), (48, 0), (0, 32), (95, 32), (48, 63)]
        for dump in [soft, softest] {
            for (x, y) in border {
                XCTAssertEqual(sample(dump, 0, x, y), 1, accuracy: 2.0 / 255,
                               "border pixel (\(x), \(y)) was pulled under 1: the blur read outside the canvas")
            }
            XCTAssertGreaterThanOrEqual(Double(dump.slices[0].min() ?? -1), 0)
            XCTAssertLessThanOrEqual(Double(dump.slices[0].max() ?? 2), 1)
        }
    }

    /// `feather = 0` must not merely look like 005c: no blur pass may run, so the numbers are the ones
    /// the recorded goldens were made from. The pinned values are 005c's own probe points.
    func testFeatherZeroRunsNoBlurAndKeepsTheCoverage() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let result = try XCTUnwrap(try graph.maskAtlasWithReport(
            maskDoc(.linearGradient(LinearGradientShape()), componentFeather: 1.0, maskFeather: 0),
            options: RenderOptions(scale: 1)))
        XCTAssertEqual(result.report.atlasPasses, ["s1_5_mask_atlas"],
                       "a document without feather/refine must run the pointwise pass only")
        XCTAssertEqual(result.report.featherMaskCount, 0)
        XCTAssertEqual(result.report.refineMaskCount, 0)
        XCTAssertEqual(result.report.atlasDependency, .pointwise)

        // The pointwise pass alone, with the symmetric ramp (½ coverage at row 32, smoothstep below).
        XCTAssertEqual(sample(result.dump, 0, 48, 32), 0.5000, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(result.dump, 0, 10, 28), 0.4082, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(result.dump, 0, 80, 30), 0.4539, accuracy: 1.5 / 255)
    }

    /// The guided filter has to leave a mask in [0, 1] and actually change it: a uniform guide turns it
    /// into the window mean, which softens the stroke's hard edge.
    func testRefineStaysInTheUnitIntervalAndSoftens() throws {
        let image = flatImage(0.4, width: 192, height: 128)
        let brush = MaskShape.brush(BrushShape(size: 0.3, strokes: [
            Stroke(points: [0.3, 0.5, 0.72, 0.5], radius: 0.12, feather: 0.0)]))
        let raw = try atlas(maskDoc(brush, componentFeather: 0, maskFeather: 0), image)
        let refined = try atlas(maskDoc(brush, componentFeather: 0, maskFeather: 0, refine: 1), image)

        XCTAssertEqual(partialCount(raw), 0, "the fixture must start as a hard-edged stroke")
        XCTAssertGreaterThan(partialCount(refined), 200, "refine must soften the edge")
        var changed = 0.0
        for i in 0..<(raw.width * raw.height) {
            changed += abs(Double(raw.slices[0][i]) - Double(refined.slices[0][i]))
        }
        XCTAssertGreaterThan(changed, 10, "meanAbs must move (§005b criterion ⑥)")
        for value in refined.slices[0] {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    /// The refine's whole point: a mask edge that nearly coincides with an image edge gets pulled onto
    /// it, because `a = cov/(var + ε)` is large exactly where the two agree. §005b criterion ⑥ asks for
    /// "the edge gradient rises", so that is what is measured — the mask's ½ point, before and after,
    /// against the guide's edge.
    ///
    /// 079 A4 caps a shape's feather at 10 % of the short edge, so the fixture offsets the ramp by 8 px
    /// and asserts that refine **moves the edge onto the guide's** (the pre-A4 fixture measured a slope
    /// ratio, which only worked because the feather then spanned the whole gradient).
    func testRefinePullsTheMaskEdgeOntoTheImageEdge() throws {
        let width = 240, height = 160
        // Guide: dark left half, bright right half, so the edge sits at x = 120.
        let image = twoToneImage((0.05, 0.05, 0.05), (0.60, 0.60, 0.60),
                                 width: width, height: height)
        // Mask: a 64-px ramp (f = 1 spans the whole gradient) whose ½ point sits at x = 112 — 8 px short
        // of the guide's edge. (102: the ramp is symmetric, so `t = 0.5` is the half-coverage point;
        // 079 A4 had put the solid rim there, which is why this fixture used to read 1.0 at x = 112.)
        let ramp = MaskShape.linearGradient(LinearGradientShape(
            start: NormalizedPoint(1.0 / 3.0, 0.5), end: NormalizedPoint(0.6, 0.5), midpoint: 0.5))
        let raw = try atlas(maskDoc(ramp, componentFeather: 1.0, maskFeather: 0), image)
        let refined = try atlas(maskDoc(ramp, componentFeather: 1.0, maskFeather: 0, refine: 1), image)

        let y = height / 2
        let edge = width / 2
        XCTAssertEqual(sample(raw, 0, 112, y), 0.5, accuracy: 0.03, "the fixture's ½ point is at x = 112")

        /// Where the row crosses ½ coverage, in pixels.
        func crossing(_ dump: MaskAtlasDump) -> Double {
            for x in 2..<width {
                let previous = self.sample(dump, 0, x - 1, y)
                let current = self.sample(dump, 0, x, y)
                guard previous <= 0.5, current > 0.5 else { continue }   // the rise, left → right
                let fraction = (0.5 - previous) / max(current - previous, 1e-6)
                return Double(x) - 0.5 + fraction
            }
            return .nan
        }
        let rawCross = crossing(raw), refinedCross = crossing(refined)
        print(String(format: "REFINE ½ point: raw x = %.2f, refined x = %.2f, guide edge x = %d",
                     rawCross, refinedCross, edge))
        XCTAssertLessThan(abs(refinedCross - Double(edge)) + 1, abs(rawCross - Double(edge)),
                          "refine must pull the mask's edge onto the guide's "
                          + "(raw \(rawCross), refined \(refinedCross), edge \(edge))")
        XCTAssertLessThanOrEqual(Double(refined.slices[0].max() ?? 2), 1)
        XCTAssertGreaterThanOrEqual(Double(refined.slices[0].min() ?? -1), 0)
    }

    // MARK: - 005d: tiles, bounds, dependency closure

    /// **The** 005d criterion (§3.4): a tiled pass and a full-frame pass of the same document must
    /// produce the same bytes — not "the same picture". Three shapes, two tile modes, SHA-256 over both
    /// the display frame and every atlas slice.
    func testTiledLocalStageIsByteIdenticalToFullFrame() throws {
        let image = rampImage(width: 320, height: 200)
        let docs: [(String, EditModel)] = [
            ("brush", maskDoc(.brush(BrushShape(size: 0.14, strokes: [
                Stroke(points: [0.12, 0.2, 0.34, 0.26], radius: 0.06, feather: 0.4)])),
                componentFeather: 0.5, maskFeather: 0.3,
                adjustments: LocalAdjustments(exposure: 1.2, saturation: 15))),
            ("radial", maskDoc(.radialGradient(RadialGradientShape(
                center: NormalizedPoint(0.3, 0.4), radius: NormalizedPoint(0.12, 0.12))),
                componentFeather: 0.4, maskFeather: 0, refine: 1,
                adjustments: LocalAdjustments(exposure: -1.5))),
            ("colour", maskDoc(.colorRange(ColorRangeShape(samples: [Self.leftColourSRGB],
                                                           tolerance: 0.2, smoothness: 0.5)),
                componentFeather: 0.5, adjustments: LocalAdjustments(exposure: 0.8))),
        ]
        for (name, edit) in docs {
            for mode in [MaskTiling.tiles, .auto] {
                let graph = try makeGraph(image)
                var full = RenderOptions(scale: 1, wantsPixels: true)
                full.maskTiling = .off
                var tiled = full
                tiled.maskTiling = mode

                let a = try graph.render(edit, options: full)
                let b = try graph.render(edit, options: tiled)
                let shaA = try XCTUnwrap(a.display).sha256()
                let shaB = try XCTUnwrap(b.display).sha256()
                XCTAssertEqual(shaA, shaB, "\(name)/\(mode): the tiled frame differs from the full frame")

                // The atlas is a full-frame pass in both modes, so it must be bit-identical too.
                let da = try XCTUnwrap(try graph.maskAtlas(edit, options: full))
                let db = try XCTUnwrap(try graph.maskAtlas(edit, options: tiled))
                XCTAssertEqual(da.slices, db.slices, "\(name)/\(mode): the atlas changed with the tiling")
            }
        }
    }

    /// The tile plan must be *smaller* — measured in pixels, not in wall-clock time, so a loaded machine
    /// cannot turn this red — and it must **cover every pixel the atlas covers**. A plan that is too
    /// small would still pass a pixel comparison (the missing pixels are simply never written), which is
    /// exactly why the coverage assertion is here.
    func testTilePlanCoversEveryCoveredPixelAndIsCheaper() throws {
        // 1024×640: a 256-px tile lattice, and the stroke's halo stays inside two of them.
        let image = rampImage(width: 1024, height: 640)
        let brush = BrushShape(size: 0.12, strokes: [
            Stroke(points: [0.10, 0.14, 0.26, 0.19], radius: 0.05, feather: 0.3)])
        let edit = maskDoc(.brush(brush), componentFeather: 0.5, maskFeather: 0.2,
                           adjustments: LocalAdjustments(exposure: 0.7))
        let result = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            edit, options: RenderOptions(scale: 1, maskTiling: .tiles)))
        let plan = result.report.localPlan

        XCTAssertTrue(plan.tiled, "a small brush must not be dispatched over the whole canvas")
        XCTAssertGreaterThan(plan.tiles.count, 1, "the plan must be several tiles, not one")
        XCTAssertLessThan(Double(plan.pixelCount), 0.25 * Double(plan.canvasPixelCount),
                          "the plan is \(plan.pixelCount) of \(plan.canvasPixelCount) pixels")
        XCTAssertEqual(plan.canvasPixelCount, image.width * image.height)
        XCTAssertEqual(plan.dependency, .pointwise, "S1.6 reads one pixel and writes it")
        XCTAssertEqual(plan.tiles.count, Set(plan.tiles).count, "no tile may be dispatched twice")

        let slice = result.dump.slices[0]
        var covered = 0
        var outsidePlan = 0
        for y in 0..<result.dump.height {
            for x in 0..<result.dump.width where slice[y * result.dump.width + x] > 0 {
                covered += 1
                let inside = plan.tiles.contains {
                    $0.x0 <= x && x < $0.x1 && $0.y0 <= y && y < $0.y1
                }
                if !inside { outsidePlan += 1 }
            }
        }
        XCTAssertGreaterThan(covered, 500, "the fixture must actually cover something")
        XCTAssertEqual(outsidePlan, 0,
                       "\(outsidePlan) covered pixels lie outside the dispatched tiles")
    }

    /// A mask that covers the frame has no smaller plan to offer: it must degenerate to one full pass,
    /// otherwise "tiling" would be a per-pixel branch masquerading as an optimisation.
    func testFullFrameMaskDegeneratesToOnePass() throws {
        let image = rampImage(width: 256, height: 160)
        let ramp = MaskShape.linearGradient(LinearGradientShape())
        let edit = maskDoc(ramp, componentFeather: 1.0, maskFeather: 0,
                           adjustments: LocalAdjustments(exposure: 0.5))
        let result = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            edit, options: RenderOptions(scale: 1, maskTiling: .tiles)))
        XCTAssertFalse(result.report.localPlan.tiled)
        XCTAssertEqual(result.report.localPlan.pixelCount, image.width * image.height)
        XCTAssertEqual(result.report.localPlan.tiles.count, 1)

        // A content-dependent predicate is a full-frame mask by definition (§4.4/§4.5), so it must not
        // pretend to be a patch either.
        let colour = maskDoc(.colorRange(ColorRangeShape(samples: [Self.leftColourSRGB],
                                                         tolerance: 0.15)),
                             adjustments: LocalAdjustments(exposure: 0.5))
        let colourResult = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            colour, options: RenderOptions(scale: 1, maskTiling: .tiles)))
        XCTAssertFalse(colourResult.report.localPlan.tiled)
    }

    /// Bounds must contain every pixel the atlas actually covers — through a crop, a rotation and a
    /// flip, and with the feather's halo included. The failure mode is silent (a stripe of the mask
    /// stops being recomputed), so it is checked against the rendered coverage, not against a formula.
    func testMaskBoundsContainEveryCoveredPixel() throws {
        let image = rampImage(width: 200, height: 140)
        var edit = maskDoc(.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.45, 0.55), radius: NormalizedPoint(0.14, 0.09), angle: 30)),
            componentFeather: 0.5, maskFeather: 0.4,
            adjustments: LocalAdjustments(exposure: 0.5), id: "m-bounds")
        edit.geometry = GeometryGroup(crop: NormalizedRect(x: 0.12, y: 0.08, width: 0.7, height: 0.62),
                                      rotationDegrees: 6, flipHorizontal: true, flipVertical: false)

        let result = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            edit, options: RenderOptions(scale: 1, maskTiling: .tiles)))
        let bounds = try XCTUnwrap(result.report.bounds["m-bounds"])
        let slice = result.dump.slices[0]

        var covered = 0
        for y in 0..<result.dump.height {
            for x in 0..<result.dump.width where slice[y * result.dump.width + x] > 0 {
                covered += 1
                XCTAssertTrue(bounds.x0 <= x && x < bounds.x1 && bounds.y0 <= y && y < bounds.y1,
                              "coverage at (\(x), \(y)) lies outside \(bounds.keyString)")
            }
        }
        XCTAssertGreaterThan(covered, 200)
        XCTAssertFalse(bounds.x1 - bounds.x0 == result.dump.width
                       && bounds.y1 - bounds.y0 == result.dump.height,
                       "the fixture must produce a real bound, not the whole canvas")

        // The halo is part of the bound: a bigger feather must widen it by the radius difference.
        var softened = edit
        softened.masks[0].feather = 0
        let tightResult = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            softened, options: RenderOptions(scale: 1)))
        let tight = try XCTUnwrap(tightResult.report.bounds["m-bounds"])
        let halo = MaskRadius.featherPixels(0.4, content: ImageSize(width: result.dump.width,
                                                                    height: result.dump.height))
        XCTAssertEqual(Double((bounds.x1 - bounds.x0) - (tight.x1 - tight.x0)),
                       halo * 2, accuracy: 4,
                       "feather 0.4 must widen the bound by 2 × its radius")
        XCTAssertLessThanOrEqual(bounds.x0, tight.x0)
    }

    // MARK: - 081: the atlas evaluates only inside each mask's box

    /// 081 — the pointwise kernel is still dispatched over the whole canvas (so a reused atlas
    /// texture never keeps a previous frame's coverage) but *evaluates* only inside the mask's own
    /// canvas box. This pins all three halves of that sentence:
    ///
    /// · every covered texel lies inside the box, so the box cannot be too small (the silent
    ///   failure — a stripe of the mask stops being recomputed);
    /// · every texel outside it is **exactly** +0.0, i.e. the untouched area is byte-identical to
    ///   what the full-canvas pass used to write there;
    /// · `atlasRasterPixels` is the box's pixel count, not the canvas's, so the saving is a receipt
    ///   and not a claim. The counter-proof is one line: revert `MaskBounds.rasterRect` to the canvas
    ///   and the last three assertions go red while nothing else in the suite moves.
    func testAtlasRasterIsConfinedToMaskBounds() throws {
        let image = rampImage(width: 320, height: 200)
        var edit = maskDoc(.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.5, 0.5), radius: NormalizedPoint(0.2, 0.2))),
            componentFeather: 0.4, maskFeather: 0.4,
            adjustments: LocalAdjustments(exposure: 0.5), id: "m-box")
        // A rotated, cropped frame: the box then goes through S0's mapping instead of measuring
        // axis-aligned source pixels, which is where a too-small bound would hide.
        edit.geometry = GeometryGroup(crop: NormalizedRect(x: 0.04, y: 0.03, width: 0.92, height: 0.9),
                                     rotationDegrees: 4, flipHorizontal: false, flipVertical: false)

        let result = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
            edit, options: RenderOptions(scale: 1)))
        let box = try XCTUnwrap(result.report.bounds["m-box"])
        let slice = result.dump.slices[0]
        let w = result.dump.width

        var covered = 0
        var outsideNonZero = 0
        for y in 0..<result.dump.height {
            for x in 0..<w {
                let v = slice[y * w + x]
                let inside = box.x0 <= x && x < box.x1 && box.y0 <= y && y < box.y1
                if v > 0 {
                    covered += 1
                    XCTAssertTrue(inside, "coverage at (\(x), \(y)) lies outside the box \(box.keyString)")
                }
                if !inside, v != 0 { outsideNonZero += 1 }
            }
        }
        XCTAssertGreaterThan(covered, 2000)
        XCTAssertEqual(outsideNonZero, 0, "every texel outside the box must be exactly +0.0")

        // The dispatch receipt. `atlasRasterPixels` counts what the kernel evaluated, `atlasCanvasPixels`
        // what a full-canvas dispatch would have cost; the ratio is the saving in one number.
        XCTAssertEqual(result.report.atlasRasterPixels, box.pixelCount)
        XCTAssertEqual(result.report.atlasCanvasPixels, w * result.dump.height)
        XCTAssertLessThan(result.report.atlasRasterFraction, 0.5,
                          "a 0.2-radius radial mask must not be evaluated over the whole canvas")
        XCTAssertGreaterThan(result.report.atlasRasterFraction, 0.01,
                             "…and the box must still be where the mask is")
    }

    /// The conservative branches, spelled out: an inverted mask covers everything *outside* its
    /// shape, and the two content-dependent predicates have no parameter-only extent — both must
    /// answer the whole canvas, or the box would silently drop coverage. A cheaper frame is worth
    /// nothing next to a wrong pixel, so this is the test that keeps the bound honest.
    func testAtlasRasterFallsBackToTheWholeCanvasWhenTheBoxCannotBeProved() throws {
        let image = rampImage(width: 200, height: 140)
        let circle = MaskShape.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.5, 0.5), radius: NormalizedPoint(0.15, 0.15)))
        let cases: [(String, EditModel)] = [
            ("inverted mask", maskDoc(circle, invert: true,
                                      adjustments: LocalAdjustments(exposure: 0.4), id: "m-inv")),
            ("colour range", maskDoc(.colorRange(ColorRangeShape(samples: [Self.leftColourSRGB],
                                                                tolerance: 0.15)),
                                     adjustments: LocalAdjustments(exposure: 0.4), id: "m-col")),
        ]
        for (label, edit) in cases {
            let result = try XCTUnwrap(try makeGraph(image).maskAtlasWithReport(
                edit, options: RenderOptions(scale: 1)))
            XCTAssertEqual(result.report.atlasRasterFraction, 1.0, accuracy: 1e-9,
                           "\(label): the box must be the whole canvas")
        }
    }

    /// 081 — "no mask ⇒ the stage does not exist" has to survive the box work: S1.5 is not merely
    /// cheap, it is absent (`hasActiveMasks` is the predicate), and an all-disabled mask set must be
    /// the same frame byte for byte as no mask at all.
    func testNoMaskDocumentDoesNotExecuteTheAtlas() throws {
        let image = rampImage()
        let neutral = try makeGraph(image).render(EditModel.neutral,
                                                  options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(neutral.trace.executed.contains(.maskAtlas), "no masks: S1.5 must not run")
        XCTAssertNil(neutral.maskReport)
        XCTAssertNil(neutral.keys.maskAtlas)
        let plain = try XCTUnwrap(neutral.display).sha256()

        var disabled = maskDoc(.radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.5, 0.5), radius: NormalizedPoint(0.2, 0.2))),
            componentFeather: 0.3, maskFeather: 0.4,
            adjustments: LocalAdjustments(exposure: 0.8), id: "m-off")
        disabled.masks[0].isEnabled = false
        let off = try makeGraph(image).render(disabled,
                                              options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(off.trace.executed.contains(.maskAtlas), "a disabled mask must not run S1.5")
        XCTAssertNil(off.maskReport)
        XCTAssertEqual(try XCTUnwrap(off.display).sha256(), plain,
                       "a disabled mask must not move a single pixel")

        // Sanity, so the assertions above are not vacuous: the same mask *enabled* does run it.
        var on = disabled
        on.masks[0].isEnabled = true
        let live = try makeGraph(image).render(on,
                                              options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(live.trace.executed.contains(.maskAtlas))
        XCTAssertNotNil(live.maskReport)
    }

    /// §3.4 step 4: the closure is `D ∪ descendants(D)` in Kahn order, and a cycle is reported instead
    /// of half-rendered. M4's own documents have no edges, which is why the chain is synthetic.
    func testMaskGraphClosureOrdersProducersBeforeConsumers() {
        typealias Edge = MaskGraph.Edge
        let chain = MaskGraph(ids: ["A", "B", "C"],
                              edges: [Edge(from: "A", to: "B"), Edge(from: "B", to: "C")])
        XCTAssertEqual(chain.closure(of: ["A"]), ["A", "B", "C"])
        XCTAssertEqual(chain.closure(of: ["B"]), ["B", "C"])
        XCTAssertEqual(chain.closure(of: ["C"]), ["C"])
        XCTAssertEqual(chain.closure(of: ["Z"]), [], "an unknown id must not invent a node")
        XCTAssertEqual(chain.executionOrder(for: ["A"]), ["A", "B", "C"])
        XCTAssertEqual(chain.executionOrder(for: ["B"]), ["B", "C"])
        XCTAssertEqual(chain.topologicalOrder(), ["A", "B", "C"])
        XCTAssertNil(chain.cycle)

        // Diamond: C is reached twice but executed once.
        let diamond = MaskGraph(ids: ["A", "B", "C", "D"],
                                edges: [Edge(from: "A", to: "B"), Edge(from: "A", to: "C"),
                                        Edge(from: "B", to: "D"), Edge(from: "C", to: "D")])
        XCTAssertEqual(diamond.executionOrder(for: ["A"]), ["A", "B", "C", "D"])

        // A cycle is refused, not silently broken: no order, a cycle to report, nothing to execute.
        let cyclic = MaskGraph(ids: ["A", "B"],
                               edges: [Edge(from: "A", to: "B"), Edge(from: "B", to: "A")])
        XCTAssertNil(cyclic.topologicalOrder())
        XCTAssertNotNil(cyclic.cycle)
        XCTAssertEqual(cyclic.cycle?.first, cyclic.cycle?.last, "a reported cycle is a closed walk")
        XCTAssertEqual(cyclic.executionOrder(for: ["A"]), [])

        // The document graph of M4 is edgeless — that is a fact about this milestone, asserted rather
        // than assumed, so adding a linked mask without an edge shows up here.
        var edit = maskDoc(.linearGradient(.default))
        edit.masks.append(Mask(id: "m-second", components: [MaskComponent(id: "c2")]))
        let documentGraph = MaskGraph.from(edit.activeMasks)
        XCTAssertEqual(documentGraph.ids, ["m-005d", "m-second"])
        XCTAssertTrue(documentGraph.edges.isEmpty)
        XCTAssertEqual(documentGraph.executionOrder(for: ["m-second"]), ["m-second"])
    }

    /// `masks == []` must still be the M1 graph, now including 005d's report: no atlas, no tiles, no
    /// neighbourhood pass, and the seven pinned keys untouched.
    func testEmptyMasksProduceNoMaskWork() throws {
        let graph = try makeGraph(rampImage())
        let result = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertNil(result.maskReport, "no masks: no mask work to report")
        XCTAssertNil(result.keys.maskAtlas)
        XCTAssertEqual(result.keys.pipeline.count, 7)
        XCTAssertEqual(Set(result.trace.executed), Set(RenderStage.allCases))
    }

    /// The 005d golden: one mask softened by `feather`, one sharpened by `refine`, on the ramp so the
    /// guided filter has structure to follow. A new file — 005b's gradient frame and 005c's
    /// brush/colour frame stay exactly as recorded.
    private func goldenFeatherRefineRecord() throws -> (record: MaskGolden, json: String) {
        let image = rampImage()   // 96 × 65
        let graph = try makeGraph(image, identity: "mask-feather-refine")
        var edit = EditModel.neutral
        let soft = Mask(id: "m-fe", name: "Feathered radial +0.6 EV",
                        feather: 0.5, refine: 0,
                        components: [MaskComponent(id: "fe1", feather: 0.2, shape: .radialGradient(
                            RadialGradientShape(center: NormalizedPoint(0.42, 0.5),
                                                radius: NormalizedPoint(0.28, 0.28), angle: 0)))],
                        adjustments: LocalAdjustments(exposure: 0.6))
        let guided = Mask(id: "m-rf", name: "Refined brush −0.7 EV",
                          feather: 0, refine: 1,
                          components: [MaskComponent(id: "rf1", feather: 0.3, shape: .brush(
                            BrushShape(size: 0.2, strokes: [
                                Stroke(points: [0.55, 0.3, 0.8, 0.45, 0.86, 0.7],
                                       radius: 0.09, feather: 0.35),
                            ])))],
                          adjustments: LocalAdjustments(amount: 80, exposure: -0.7))
        edit.masks = [soft, guided]

        let dump = try XCTUnwrap(graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
        let display = try XCTUnwrap(
            graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)

        let sampleX = [8, 32, 40, 64, 84, 72]
        let sampleY = [8, 16, 32, 32, 48, 56]
        var samples: [[Double]] = []
        for (x, y) in zip(sampleX, sampleY) {
            samples.append(dump.slices.map { Double($0[y * dump.width + x]) })
        }

        let record = MaskGolden(
            note: "Recorded by MaskTests on the synthetic 96×65 ramp image; masks m-fe (radial, "
                + "mask-level feather 0.5 → a 3.2 px box blur, +0.6 EV) and m-rf (brush, refine 1 → "
                + "guided filter on S1's luma, amount 80, −0.7 EV). Both 005d neighbourhood operators "
                + "are in the frame. 8-bit quantised digests so a GPU family change does not invalidate "
                + "the frame; re-record only when a kernel change is intended.",
            sourceWidth: image.width,
            sourceHeight: image.height,
            maskIDs: dump.maskIDs,
            atlasSHA256: quantisedDigest(dump.slices.flatMap { $0 }),
            displaySHA256: quantisedDigest((0..<(display.width * display.height)).flatMap { i -> [Float] in
                [Float(display.rgba[i * 4]), Float(display.rgba[i * 4 + 1]), Float(display.rgba[i * 4 + 2])]
            }),
            samples: samples,
            sampleX: sampleX,
            sampleY: sampleY)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (record, String(decoding: try encoder.encode(record), as: UTF8.self))
    }

    /// The 005d frame: feather + refine, pinned to its own file.
    /// Regenerate with `PHOTONS_RECORD_GOLDEN=1 swift test --filter testFeatherAndRefineFrameGolden`.
    func testFeatherAndRefineFrameGolden() throws {
        let (record, json) = try goldenFeatherRefineRecord()
        try assertGolden(named: "mask-feather-refine-s1.0.json", record: record, json: json)
    }

    // MARK: - 005d: the frame budget

    /// Three masks at 4.10 Mpx, full S0→S4, cache off — the budget §005c item ⑦ set at p95 ≤ 16.7 ms.
    ///
    /// Skipped unless `PHOTONS_BENCH=1`. The assertion is a *structural* ceiling (100 ms), because a
    /// wall-clock assertion at the 16.7 ms scale turns a busy machine into a red test; the pixel-based
    /// assertions above are the ones that guard correctness. What this reports is the number that goes
    /// in the milestone note.
    func testFrameBudgetWithThreeMasks() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" else {
            throw XCTSkip("set PHOTONS_BENCH=1 to measure the 4.10 Mpx frame budget")
        }
        let image = rampImage(width: 2731, height: 1500)   // 4.0965 Mpx ≈ 4.10 Mpx
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        func document(feather: Double, refine: Double) -> EditModel {
            var edit = EditModel.neutral
            edit.masks = [
                Mask(id: "m-a", feather: feather, refine: refine,
                     components: [MaskComponent(id: "a1", feather: 0.4, shape: .radialGradient(
                        RadialGradientShape(center: NormalizedPoint(0.3, 0.35),
                                            radius: NormalizedPoint(0.18, 0.18)))),
                                  MaskComponent(id: "a2", feather: 0.3, shape: .linearGradient(
                        LinearGradientShape(start: NormalizedPoint(0.4, 0),
                                            end: NormalizedPoint(0.5, 1))))],
                     adjustments: LocalAdjustments(exposure: 0.8, saturation: 10)),
                Mask(id: "m-b", feather: feather, refine: refine,
                     components: [MaskComponent(id: "b1", feather: 0.35, shape: .brush(
                        BrushShape(size: 0.2, strokes: [
                            Stroke(points: [0.2, 0.6, 0.5, 0.72, 0.8, 0.62], radius: 0.08,
                                   feather: 0.4),
                        ])))],
                     adjustments: LocalAdjustments(exposure: -1.1, contrast: 20)),
                Mask(id: "m-c", feather: feather, refine: refine,
                     components: [MaskComponent(id: "c1", feather: 0.5, shape: .colorRange(
                        ColorRangeShape(samples: [Self.leftColourSRGB], tolerance: 0.18,
                                        smoothness: 0.5)))],
                     adjustments: LocalAdjustments(amount: 60, temperature: 30, saturation: -20)),
            ]
            return edit
        }

        for (label, doc) in [("feather 0.15", document(feather: 0.15, refine: 0)),
                             ("feather 0.15 + refine 0.5", document(feather: 0.15, refine: 0.5))] {
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-4mpx"))
            var times: [Double] = []
            for _ in 0..<25 {
                let result = try graph.render(doc, options: RenderOptions(scale: 1, useCache: false,
                                                                        wantsPixels: false))
                if let t = result.output { graph.recycle(output: t) }
                times.append(result.trace.gpuMilliseconds)
            }
            times.sort()
            let p50 = times[times.count / 2]
            let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
            print(String(format: "BENCH %@: p50 %.2f ms  p95 %.2f ms  min %.2f  max %.2f (3 masks, 4.10 Mpx)",
                         label, p50, p95, times.first ?? 0, times.last ?? 0))
            XCTAssertLessThan(p95, 100, "\(label): a structural regression, not jitter")
        }

        // A slider drag with two masks: with `.off` the whole local pass re-runs; with `.tiles` the
        // increment lands in place inside the moved mask's tiles (§3.4 step 3).
        var drag = document(feather: 0.15, refine: 0)
        drag.masks = [drag.masks[1], drag.masks[2]]
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-4mpx"))
        var off: [Double] = [], on: [Double] = []
        for mode in [MaskTiling.off, .tiles] {
            var o = RenderOptions(scale: 1, useCache: true, wantsPixels: false)
            o.maskTiling = mode
            _ = try graph.render(drag, options: o)          // warm
            var times: [Double] = []
            for i in 0..<20 {
                drag.masks[0].adjustments.exposure = 0.5 + Double(i) * 0.05
                let r = try graph.render(drag, options: o)
                if let t = r.output { graph.recycle(output: t) }
                times.append(r.trace.gpuMilliseconds)
            }
            times.sort()
            if mode == .off { off = times } else { on = times }
        }
        print(String(format: "BENCH slider drag, 2 masks: full pass p50 %.2f ms, tiled increment p50 %.2f ms",
                     off[off.count / 2], on[on.count / 2]))
    }

    /// The 005d criterion in its incremental form — "the tiled increment equals one full-frame
    /// computation, pixel for pixel". A slider move on one of two masks must rewrite only that mask's
    /// region **in place** and still match a *cold* full-frame render of the new document.
    func testIncrementalUpdateEqualsAColdFullFrameRender() throws {
        let image = rampImage(width: 1024, height: 640)
        var doc = EditModel.neutral
        doc.masks = [
            Mask(id: "m-a", feather: 0.2,
                 components: [MaskComponent(id: "a1", feather: 0.4, shape: .brush(
                    BrushShape(size: 0.14, strokes: [
                        Stroke(points: [0.12, 0.16, 0.3, 0.2], radius: 0.06, feather: 0.35)])))],
                 adjustments: LocalAdjustments(exposure: 0.5)),
            Mask(id: "m-b", feather: 0,
                 components: [MaskComponent(id: "b1", feather: 0.4, shape: .radialGradient(
                    RadialGradientShape(center: NormalizedPoint(0.78, 0.72),
                                        radius: NormalizedPoint(0.1, 0.1))))],
                 adjustments: LocalAdjustments(exposure: -1)),
        ]
        var moved = doc
        moved.masks[0].adjustments.exposure = 1.8          // one slider, no selection change
        for mode in [MaskTiling.auto, .tiles] {
        var tiled = RenderOptions(scale: 1, wantsPixels: true)
        tiled.maskTiling = mode

        let graph = try makeGraph(image)
        _ = try graph.render(doc, options: tiled)          // the frame this update builds on
        let incremental = try graph.render(moved, options: tiled)
        XCTAssertTrue(incremental.trace.executed.contains(.localApply))
        XCTAssertTrue(incremental.trace.skipped.contains(.maskAtlas),
                      "moving a slider must not rebuild the selection")
        let plan = try XCTUnwrap(incremental.maskReport?.localPlan)
        XCTAssertTrue(plan.tiled, "the update must be confined to the mask's tiles")
        XCTAssertLessThan(Double(plan.pixelCount), 0.25 * Double(plan.canvasPixelCount),
                          "the increment covered \(plan.pixelCount) of \(plan.canvasPixelCount) pixels")

        // A cold render (fresh graph, no history) of the *same* document is the reference.
        var full = RenderOptions(scale: 1, wantsPixels: true)
        full.maskTiling = .off
        let cold = try makeGraph(image).render(moved, options: full)
        XCTAssertEqual(try XCTUnwrap(incremental.display).sha256(),
                       try XCTUnwrap(cold.display).sha256(),
                       "the in-place increment differs from one full-frame computation")

        // And a repeat is a whole-stage hit: nothing is recomputed for an unchanged document.
        let again = try graph.render(moved, options: tiled)
        XCTAssertTrue(again.trace.skipped.contains(.localApply))
        XCTAssertEqual(try XCTUnwrap(again.display).sha256(), try XCTUnwrap(cold.display).sha256())
        }
    }

    // MARK: - the recorded golden frames

    struct MaskGolden: Codable, Equatable {
        var note: String
        var sourceWidth: Int
        var sourceHeight: Int
        var maskIDs: [String]
        /// SHA-256 of the atlas quantised to 8 bits — GPU-family tolerant, structure sensitive.
        var atlasSHA256: String
        /// Same, for the display-encoded frame.
        var displaySHA256: String
        /// Six `[slice0, slice1]` coverage pairs, so a failure says *where* it drifted.
        var samples: [[Double]]
        var sampleX: [Int]
        var sampleY: [Int]
    }

    private func goldenEdit() -> EditModel {
        var linear = LocalAdjustments(exposure: 0.5)
        linear.saturation = 10
        let maskA = Mask(id: "m-a", name: "Linear +½ EV",
                         components: [MaskComponent(id: "a1", feather: 1.0, shape: .linearGradient(
                            LinearGradientShape(start: NormalizedPoint(0.5, 0),
                                                end: NormalizedPoint(0.5, 1),
                                                midpoint: 0.4)))],
                         adjustments: linear)
        let maskB = Mask(id: "m-b", name: "Radial −1 EV",
                         components: [MaskComponent(id: "b1", feather: 0.5,
                                                    shape: .radialGradient(RadialGradientShape(
                                                        center: NormalizedPoint(0.55, 0.5),
                                                        radius: NormalizedPoint(0.2, 0.2),
                                                        angle: 20)))],
                         adjustments: LocalAdjustments(exposure: -1))
        return EditModel(geometry: .identity, light: .identity, curve: .identity,
                         color: .identity, detail: .identity,
                         effects: EffectsGroup(vignetteAmount: -20, vignetteMidpoint: 50,
                                               vignetteFeather: 50),
                         masks: [maskA, maskB])
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func quantisedDigest(_ values: [Float]) -> String {
        var bytes = [UInt8](repeating: 0, count: values.count)
        for (i, v) in values.enumerated() {
            bytes[i] = UInt8(min(max((Double(v) * 255).rounded(), 0), 255))
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func goldenRecord() throws -> (record: MaskGolden, json: String) {
        let image = flatImage(0.4, width: 96, height: 64)
        let graph = try makeGraph(image, identity: "mask-golden")
        let edit = goldenEdit()
        let dump = try XCTUnwrap(graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
        let display = try XCTUnwrap(
            graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)

        let sampleX = [4, 48, 90, 24, 72, 60]
        let sampleY = [4, 32, 60, 12, 52, 48]
        var samples: [[Double]] = []
        for (x, y) in zip(sampleX, sampleY) {
            samples.append(dump.slices.map { Double($0[y * dump.width + x]) })
        }

        let atlasValues = dump.slices.flatMap { $0 }
        let displayValues = (0..<(display.width * display.height)).flatMap { i -> [Float] in
            [Float(display.rgba[i * 4]), Float(display.rgba[i * 4 + 1]), Float(display.rgba[i * 4 + 2])]
        }
        let record = MaskGolden(
            note: "Recorded by MaskTests on the synthetic 96×64 flat-0.4 image; masks m-a (linear, "
                + "+0.5 EV, +10 sat, midpoint 0.4 — 102's symmetric feather ramp) and m-b (radial, "
                + "−1 EV). Digests cover 8-bit quantised values so a GPU family change does not "
                + "invalidate the frame; re-record only when a kernel change is intended.",
            sourceWidth: image.width,
            sourceHeight: image.height,
            maskIDs: dump.maskIDs,
            atlasSHA256: quantisedDigest(atlasValues),
            displaySHA256: quantisedDigest(displayValues),
            samples: samples,
            sampleX: sampleX,
            sampleY: sampleY)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        return (record, json)
    }

    /// One frame with two masks, pinned. Regenerate deliberately (and only deliberately):
    /// `PHOTONS_RECORD_GOLDEN=1 swift test --filter testMaskedFrameGolden`.
    func testMaskedFrameGolden() throws {
        let (record, json) = try goldenRecord()
        try assertGolden(named: "mask-gradient-s1.0.json", record: record, json: json)
    }

    /// A brush with an erase stroke plus a colour range, on a ramp so both predicates have
    /// something to bite on. A new file: 005b's gradient frame stays exactly as recorded.
    private func goldenBrushColourRecord() throws -> (record: MaskGolden, json: String) {
        let image = rampImage()
        let graph = try makeGraph(image, identity: "mask-brush-colour")
        var edit = EditModel.neutral
        let brush = Mask(id: "m-br", name: "Brush +½ EV",
                         components: [MaskComponent(id: "br1", feather: 0.5, shape: .brush(
                            BrushShape(size: 0.24, strokes: [
                                Stroke(points: [0.15, 0.35, 0.5, 0.5, 0.85, 0.35],
                                       radius: 0.11, feather: 0.45, flow: 0.95),
                                Stroke(points: [0.55, 0.62, 0.75, 0.7], radius: 0.06,
                                       feather: 0.3, erase: true),
                            ])))],
                         adjustments: LocalAdjustments(amount: 100, exposure: 0.5))
        let colour = Mask(id: "m-cr", name: "Colour range −0.8 EV",
                          components: [MaskComponent(id: "cr1", feather: 0.5, shape: .colorRange(
                            ColorRangeShape(samples: [Self.leftColourSRGB, Self.farColourSRGB],
                                            tolerance: 0.15, smoothness: 0.6)))],
                          adjustments: LocalAdjustments(amount: 60, exposure: -0.8, saturation: 20))
        edit.masks = [brush, colour]

        let dump = try XCTUnwrap(graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
        let display = try XCTUnwrap(
            graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)

        let sampleX = [6, 24, 48, 72, 90, 60]
        let sampleY = [8, 32, 32, 32, 60, 46]
        var samples: [[Double]] = []
        for (x, y) in zip(sampleX, sampleY) {
            samples.append(dump.slices.map { Double($0[y * dump.width + x]) })
        }

        let record = MaskGolden(
            note: "Recorded by MaskTests on the synthetic 96×65 ramp image; masks m-br (brush: "
                + "3-point paint stroke + erase stroke, +0.5 EV) and m-cr (colour range over the two "
                + "ramp ends, tolerance 0.15 / smoothness 0.6, amount 60, −0.8 EV, +20 sat). 8-bit "
                + "quantised digests so a GPU family change does not invalidate the frame; re-record "
                + "only when a kernel change is intended. Re-recorded once for 派单 056: m-cr\'s +20 "
                + "saturation now runs in S3.5, display-referred and from the same color_hsl.metal "
                + "include the global slider compiles — so the *frame* is meant to differ while the "
                + "atlas digest and the six coverage samples stay exactly as recorded.",
            sourceWidth: image.width,
            sourceHeight: image.height,
            maskIDs: dump.maskIDs,
            atlasSHA256: quantisedDigest(dump.slices.flatMap { $0 }),
            displaySHA256: quantisedDigest((0..<(display.width * display.height)).flatMap { i -> [Float] in
                [Float(display.rgba[i * 4]), Float(display.rgba[i * 4 + 1]), Float(display.rgba[i * 4 + 2])]
            }),
            samples: samples,
            sampleX: sampleX,
            sampleY: sampleY)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (record, String(decoding: try encoder.encode(record), as: UTF8.self))
    }

    /// The 005c frame: brush + colour range, pinned to its own file.
    /// Regenerate with `PHOTONS_RECORD_GOLDEN=1 swift test --filter testBrushAndColourFrameGolden`.
    func testBrushAndColourFrameGolden() throws {
        let (record, json) = try goldenBrushColourRecord()
        try assertGolden(named: "mask-brush-colour-s1.0.json", record: record, json: json)
    }

    /// Shared comparison: digests, ids, and the six sample pairs.
    private func assertGolden(named name: String, record actual: MaskGolden, json: String) throws {
        let url = Self.goldenDir.appendingPathComponent(name)
        // `PHOTONS_RECORD_GOLDEN=1` used to overwrite **only when the file was missing**, so the
        // documented "Regenerate with PHOTONS_RECORD_GOLDEN=1" did nothing once a golden existed and
        // every stale golden had to be deleted by hand. Recording now always wins.
        if ProcessInfo.processInfo.environment["PHOTONS_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDir,
                                                    withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("no golden at \(url.path). Recorded frame:\n\(json)")
            return
        }
        let golden = try JSONDecoder().decode(MaskGolden.self, from: data)

        XCTAssertEqual(golden.sourceWidth, actual.sourceWidth)
        XCTAssertEqual(golden.sourceHeight, actual.sourceHeight)
        XCTAssertEqual(golden.maskIDs, actual.maskIDs, "atlas slice order changed")
        XCTAssertEqual(golden.atlasSHA256, actual.atlasSHA256, "atlas coverage changed")
        XCTAssertEqual(golden.displaySHA256, actual.displaySHA256, "the frame changed")
        XCTAssertEqual(golden.sampleX, actual.sampleX)
        XCTAssertEqual(golden.sampleY, actual.sampleY)
        for (i, pair) in golden.samples.enumerated() {
            XCTAssertEqual(pair.count, actual.samples[i].count)
            for (s, expected) in pair.enumerated() {
                XCTAssertEqual(actual.samples[i][s], expected, accuracy: 1.5 / 255.0,
                               "sample \(i) (x \(golden.sampleX[i]), y \(golden.sampleY[i])) slice \(s)")
            }
        }
    }
}
