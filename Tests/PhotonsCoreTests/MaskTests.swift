import XCTest
import PhotonsCore
import Metal
import CryptoKit

/// M4 acceptance, steps 005a (model + keys) and 005b (linear/radial gradients → atlas).
///
/// Three kinds of check, in the order they can lie:
///
/// 1. **Text**: the seven M1 cache keys are pinned verbatim, as produced by *committed* M1 code
///    (b1c58ec) for a fixed document. Empty masks must not move a single byte of them.
/// 2. **Numbers**: the two gradient shapes are compared against an independent scalar
///    implementation of the formulas in docs/tasks/005-masks.md §4.2/§4.3, pixel by pixel, on a
///    synthetic image. No RAW fixture, no decoder, no eyeballing.
/// 3. **One frame**: a recorded golden under `Tests/Golden/mask-*.json`, quantised to 8 bits so it
///    survives a GPU family change while still catching a structural regression.
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
    func testUnimplementedShapesContributeNoCoverage() throws {
        let image = rampImage()
        let shapes: [MaskShape] = [
            .brush(BrushShape(strokes: [Stroke(points: [0.2, 0.2, 0.8, 0.8], radius: 0.1)])),
            .colorRange(ColorRangeShape(samples: [[0.5, 0.5, 0.5]])),
            .luminanceRange(LuminanceRangeShape(low: 0.2, high: 0.8)),
            .semantic(SemanticShape(kind: .sky)),
        ]
        for shape in shapes {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m-\(shape.kind)",
                               components: [MaskComponent(id: "c", shape: shape)],
                               adjustments: LocalAdjustments(exposure: 2))]
            let dump = try atlas(edit, image)
            XCTAssertEqual(dump.slices.first?.max() ?? 0, 0,
                           "\(shape.kind) must be empty, not approximated")
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

    // MARK: - the recorded golden frame

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
        let (actual, json) = try goldenRecord()
        let url = Self.goldenDir.appendingPathComponent("mask-gradient-s1.0.json")
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
