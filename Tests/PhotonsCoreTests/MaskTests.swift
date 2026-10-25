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
/// 2. **Numbers**: every shape is compared against an independent scalar implementation of the
///    formulas in docs/tasks/005-masks.md §4.1–§4.5, pixel by pixel, on a synthetic image — plus a
///    table of pinned values so "fixed input → fixed output" is checked directly, not inferred.
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
        edit.curve = CurveGroup(rgb: [CurvePoint(0, 0), CurvePoint(0.3, 0.25), CurvePoint(1, 1)])
        edit.color = ColorGroup(vibrance: 15, saturation: -10, bands: ColorGroup.identityBands)
        edit.color.bands[3].hue = 20
        edit.effects = EffectsGroup(vignetteAmount: -40, vignetteMidpoint: 45,
                                    vignetteFeather: 60, vignetteRoundness: 30)
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

    // MARK: - independent analytic reference (docs/tasks/005-masks.md §4.2 / §4.3)

    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// §4.2: `t = dot(p−start, d)/dot(d,d)`, midpoint remap, feather window, smoothstep.
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
        let lo = 0.5 - 0.5 * f
        let hi = max(0.5 + 0.5 * f, lo + 1e-5)
        return smoothstep(lo, hi, tp)
    }

    /// §4.3: `q = R(−angle)·(p−centre)/radius`, `alpha = 1 − smoothstep(1−f, 1, |q|)`.
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
        return 1 - smoothstep(1 - min(max(f, 0), 0.999), 1, r)
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
    private func colourRangeAlpha(r: Double, g: Double, b: Double, _ s: ColorRangeShape) -> Double {
        let lab = OKLabMetric.fromLinear(r, g, b)
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

    /// §4.5: OKLab L (headroom clamped to 1) with a two-sided feather, inverted pairs repaired.
    private func luminanceRangeAlpha(r: Double, g: Double, b: Double, _ s: LuminanceRangeShape) -> Double {
        let o = s.ordered
        let L = OKLabMetric.fromLinear(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)).L
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
        let lab = OKLabMetric.fromLinear(c.0, c.1, c.2)
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
    /// (captured by running that commit's `RenderStage`/`EditModel` through its own `plan()`).
    /// If this test fails, the empty-mask path changed and every golden, every disk cache entry and
    /// the claim "adding masks did not touch the no-mask path" are void (§3.2).
    func testEmptyMasksProduceTheM1KeysByteForByte() {
        let edit = m1Fixture()
        XCTAssertTrue(edit.masks.isEmpty)
        XCTAssertFalse(edit.hasActiveMasks)
        let l = links(edit)
        XCTAssertNil(l.maskAtlas, "no masks: the atlas stage must not exist")
        XCTAssertNil(l.localApply, "no masks: the local stage must not exist")

        let expected: [(String, String, String)] = [
            ("geometry", "248063fdc8786acc7fdac7362853bc7f46cd050927d3ed66fabe0e81991f33bb",
             "photons-render-v1|keyvec-fixture|6000x4000|1500x1000|1500x1000|pv=1;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=10"),
            ("sceneLinear", "a213c6fd8dbc7289ce3610d3c58e9c1ffb1f6dd526278f16a6791068ee0f01d0",
             "248063fdc8786acc7fdac7362853bc7f46cd050927d3ed66fabe0e81991f33bb|ev=0.75000;temp=5200.00000;tint=12.00000;hlr=0.40000"),
            ("toneMap", "acc5369fdff40ece79b747d06d10f05285a4400bb91dea7b087171216ff3e9e0",
             "a213c6fd8dbc7289ce3610d3c58e9c1ffb1f6dd526278f16a6791068ee0f01d0|con=20.00000;hi=-30.00000;sh=15.00000;wh=10.00000;bl=-5.00000"),
            ("curve", "089ee8ee8fffff448c989ba44f82312576711070355e4c7e3fe330904cbfd86f",
             "acc5369fdff40ece79b747d06d10f05285a4400bb91dea7b087171216ff3e9e0|rgb=0.0000,0.0000;0.3000,0.2500;1.0000,1.0000|r=0.0000,0.0000;1.0000,1.0000|g=0.0000,0.0000;1.0000,1.0000|b=0.0000,0.0000;1.0000,1.0000"),
            ("color", "1791b2688a3a38ed1ef74f951cf93e39b5f404501e1effe80a421335123c7bdc",
             "089ee8ee8fffff448c989ba44f82312576711070355e4c7e3fe330904cbfd86f|vib=15.00000;sat=-10.00000;bands=0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;20.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000"),
            ("vignette", "4b5e6d5ab3b18af6e56108d43d6189a83b9cb2852e72bf78cceec1f867c83686",
             "1791b2688a3a38ed1ef74f951cf93e39b5f404501e1effe80a421335123c7bdc|vig=-40.00000;mid=45.00000;fea=60.00000;rou=30.00000"),
            ("display", "f0ac628a476eaa4133e715052c941022a056ec94eba5fefe86b4b51d73433f01",
             "4b5e6d5ab3b18af6e56108d43d6189a83b9cb2852e72bf78cceec1f867c83686|sRGB;bits=8;headroom=1.000|1500x1000"),
        ]

        let actual: [String: String] = [
            "geometry": l.geometry, "sceneLinear": l.sceneLinear, "toneMap": l.toneMap,
            "curve": l.curve, "color": l.color, "vignette": l.vignette, "display": l.display,
        ]
        let keys = RenderKeyChain.keys(l, identity: "keyvec-fixture")
        let keyByStage: [String: String] = [
            "geometry": keys.geometry, "sceneLinear": keys.sceneLinear, "toneMap": keys.toneMap,
            "curve": keys.curve, "color": keys.color, "vignette": keys.vignette,
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

        // The three points the spec calls out, on the vertical centre line.
        XCTAssertEqual(sample(dump, 0, 48, 0), 0, accuracy: 1.0 / 255.0, "t = 0 must be 0")
        XCTAssertEqual(sample(dump, 0, 48, 32), 0.5, accuracy: 1.0 / 255.0, "t = 0.5 must be 0.5")
        XCTAssertEqual(sample(dump, 0, 48, 64), 1, accuracy: 1.0 / 255.0, "t = 1 must be 1")

        // Monotone along the ramp: a gradient that folds is a gradient that lies.
        for y in 1..<image.height {
            XCTAssertGreaterThanOrEqual(sample(dump, 0, 48, y) + 1e-4, sample(dump, 0, 48, y - 1))
        }
    }

    /// The midpoint exponent `t^(log 0.5 / log m)`: at m = 0.25 the half-way coverage sits at t = 0.25.
    func testLinearGradientMidpointMovesTheHalfPoint() throws {
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
        XCTAssertEqual(expected, 0.5, accuracy: 0.02, "the reference itself must land near 0.5")
        XCTAssertEqual(sample(dump, 0, 48, y), expected, accuracy: 1.5 / 255.0)

        // With the midpoint pulled up, 50 % arrives far earlier than the geometric middle.
        let geometricMiddle = linearAlpha(x: 48.5, y: Double(image.height / 2) + 0.5, shape,
                                          feather: 1.0, size: (image.width, image.height))
        XCTAssertGreaterThan(sample(dump, 0, 48, image.height / 2), 0.75,
                             "m = 0.25 must already be ~\(geometricMiddle) at the middle row")
        for y in 1..<image.height {
            XCTAssertGreaterThanOrEqual(sample(dump, 0, 48, y) + 1e-4, sample(dump, 0, 48, y - 1))
        }
    }

    /// Feather narrows the transition window to `[0.5 − f/2, 0.5 + f/2]`.
    func testLinearGradientFeatherNarrowsTheWindow() throws {
        let image = rampImage()
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-feather",
                           components: [MaskComponent(id: "c", feather: 0.2,
                                                      shape: .linearGradient(LinearGradientShape()))])]
        let dump = try atlas(edit, image)

        // With f = 0.2 the ramp is hard outside 0.4…0.6 of the field.
        for y in 0..<image.height {
            let t = (Double(y) + 0.5) / Double(image.height)
            let a = sample(dump, 0, 48, y)
            if t < 0.40 { XCTAssertEqual(a, 0, accuracy: 1.0 / 255.0, "row \(y): below the window") }
            if t > 0.60 { XCTAssertEqual(a, 1, accuracy: 1.0 / 255.0, "row \(y): above the window") }
        }
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

        // Centre = 1, the rim = 0, and the half-coverage radius sits at r = 1 − f/2 = 0.75, i.e.
        // 0.75 · 0.25 · shortEdge pixels out from the centre (measured to one pixel).
        let cx = image.width / 2, cy = image.height / 2
        XCTAssertEqual(sample(dump, 0, cx, cy), 1, accuracy: 1.5 / 255.0, "alpha(centre) must be 1")

        let side = Double(min(image.width, image.height))
        let rimX = cx + Int((0.25 * side).rounded())
        XCTAssertEqual(sample(dump, 0, rimX, cy), 0, accuracy: 1.5 / 255.0, "alpha(r) must be 0")

        var crossing = Double.nan
        for x in cx..<(cx + Int(0.3 * side)) where sample(dump, 0, x, cy) <= 0.5 {
            let previous = sample(dump, 0, x - 1, cy)
            let current = sample(dump, 0, x, cy)
            let fraction = (previous - 0.5) / max(previous - current, 1e-6)
            // Pixel x covers [x, x+1) with its centre at x + 0.5.
            crossing = Double(x) + 0.5 + fraction - Double(cx)
            break
        }
        XCTAssertEqual(crossing, 0.75 * 0.25 * side, accuracy: 1.0,
                       "alpha must reach 0.5 at r = 1 − f/2 (one pixel of sampling)")

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
        // A top-to-bottom ramp with a full feather, i.e. alpha = t at every row: row 32 is exactly
        // 0.5, which is what makes the truth table readable.
        let half = { (op: CombineOp) in
            MaskComponent(id: "c2", op: op, feather: 1.0, shape: .linearGradient(LinearGradientShape()))
        }
        func doc(op: CombineOp, feather: Double = 1.0, opacity: Double = 1,
                 invert: Bool = false, componentInvert: Bool = false) -> EditModel {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-ops", opacity: opacity, invert: invert,
                               components: [MaskComponent(id: "c1", invert: componentInvert,
                                                          feather: feather,
                                                          shape: .linearGradient(LinearGradientShape())),
                                            half(op)])]
            return edit
        }
        let y = 32, x = 48

        XCTAssertEqual(sample(try atlas(doc(op: .add), image), 0, x, y), 0.5, accuracy: 1.5 / 255.0,
                       "add must be max(0.5, 0.5)")
        XCTAssertEqual(sample(try atlas(doc(op: .subtract), image), 0, x, y), 0.25, accuracy: 1.5 / 255.0,
                       "subtract must be 0.5 · (1 − 0.5)")
        XCTAssertEqual(sample(try atlas(doc(op: .intersect), image), 0, x, y), 0.25, accuracy: 1.5 / 255.0,
                       "intersect must be 0.5 · 0.5")

        // The first component's op is ignored: a leading subtract must not subtract from nothing.
        var leading = doc(op: .add)
        leading.masks[0].components[0].op = .subtract
        XCTAssertEqual(sample(try atlas(leading, image), 0, x, y), 0.5, accuracy: 1.5 / 255.0)

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

    /// Shapes this build does not evaluate contribute zero coverage — never a guess, never a crash.
    /// Since 005c the brush, colour and luminance ranges are real shapes; what is left unevaluated
    /// is the semantic matte, which needs an OS model (005e).
    func testUnimplementedShapesContributeNoCoverage() throws {
        let image = rampImage()
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
            let dump = try atlas(edit, image)
            XCTAssertEqual(dump.slices.first?.max() ?? 0, 0,
                           "\(shape.kind) must be empty, not approximated")
            XCTAssertFalse(shape.isRenderableNow, "\(shape.kind) is not renderable in this build")
        }
    }

    // MARK: - 005b: the atlas lives in uncropped source space

    /// Shapes are stored in *uncropped original* coordinates (§4), so the atlas kernel has to walk
    /// S0's mapping backwards: canvas → content → flip → rotate → crop → source pixels. If that
    /// inverse is wrong a mask is silently displaced on every cropped or straightened photo — the
    /// one failure a single uncropped test would never catch.
    func testAtlasInvertsCropRotationAndFlip() throws {
        let image = rampImage(width: 96, height: 65)
        let crop = NormalizedRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)
        let rotation = 7.0
        let shape = RadialGradientShape(center: NormalizedPoint(0.5, 0.4),
                                        radius: NormalizedPoint(0.30, 0.20),
                                        angle: 25)
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: crop, rotationDegrees: rotation,
                                      flipHorizontal: true, flipVertical: false)
        edit.masks = [Mask(id: "m-crop",
                           components: [MaskComponent(id: "c", feather: 0.5,
                                                      shape: .radialGradient(shape))])]

        let dump = try atlas(edit, image)
        let w = Double(image.width), h = Double(image.height)
        let clamped = crop.clamped()
        let cs = cos(rotation * Double.pi / 180), sn = sin(rotation * Double.pi / 180)

        var worst = 0.0
        for y in 0..<dump.height {
            for x in 0..<dump.width {
                // Forward model of one canvas pixel, exactly as s0_geometry does it.
                var u = (Double(x) + 0.5) / Double(dump.width)
                var v = (Double(y) + 0.5) / Double(dump.height)
                u = 1 - u                                  // flipHorizontal
                let o = (u - 0.5, v - 0.5)
                let r = (o.0 * cs - o.1 * sn, o.0 * sn + o.1 * cs)
                let sx = (clamped.x + (r.0 + 0.5) * clamped.width) * w
                let sy = (clamped.y + (r.1 + 0.5) * clamped.height) * h

                let expected = radialAlpha(x: sx, y: sy, shape, feather: 0.5,
                                           size: (image.width, image.height))
                worst = max(worst, abs(expected - sample(dump, 0, x, y)))
            }
        }
        XCTAssertLessThan(worst, 2.0 / 255.0,
                          "the atlas does not invert crop/rotation/flip (worst \(worst))")
        XCTAssertLessThan(dump.width, image.width, "the atlas follows the crop, not the source")
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
        XCTAssertEqual(Set(result.trace.executed), Set(RenderStage.order))
        XCTAssertEqual(result.keys.pipeline.count, 9)
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
        // linear: t' = (y + 0.5)/65 on a full feather, so row 32 is exactly ½.
        let linear = try atlas(doc(.linearGradient(LinearGradientShape()), feather: 1.0), rampImage())
        XCTAssertEqual(sample(linear, 0, 48, 32), 0.5000, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(linear, 0, 10, 16), 0.1606, accuracy: 1.5 / 255)
        XCTAssertEqual(sample(linear, 0, 80, 48), 0.8394, accuracy: 1.5 / 255)

        // radial: centre (48, 32.5) px, radius 0.25 · 65 = 16.25 px, feather 0.5.
        let radial = try atlas(doc(.radialGradient(RadialGradientShape()), feather: 0.5), rampImage())
        XCTAssertEqual(sample(radial, 0, 48, 32), 1.0000, accuracy: 1.5 / 255, "centre")
        XCTAssertEqual(sample(radial, 0, 60, 32), 0.4424, accuracy: 1.5 / 255, "q = 12.5/16.25")
        XCTAssertEqual(sample(radial, 0, 64, 32), 0.0000, accuracy: 1.5 / 255, "beyond the rim")

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
                                               vignetteFeather: 50, vignetteRoundness: 0),
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
                + "+0.5 EV, +10 sat, midpoint 0.4) and m-b (radial, −1 EV). Digests cover 8-bit "
                + "quantised values so a GPU family change does not invalidate the frame; re-record "
                + "only when a kernel change is intended.",
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
                + "only when a kernel change is intended.",
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
        guard let data = try? Data(contentsOf: url) else {
            if ProcessInfo.processInfo.environment["PHOTONS_RECORD_GOLDEN"] == "1" {
                try FileManager.default.createDirectory(at: Self.goldenDir,
                                                        withIntermediateDirectories: true)
                try Data(json.utf8).write(to: url)
                return
            }
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
