import XCTest
import PhotonsCore
import Metal
import CryptoKit

/// 005e acceptance: semantic mattes (`CIRAWFilter` → Vision → zero coverage) and the `showMask`
/// overlay.
///
/// Three kinds of check, in the order they can lie:
///
/// 1. **Routes as values.** A matte that does not exist is a `SemanticUnavailableReason`, not an
///    exception and not a silent empty mask: the atlas is empty *and* the report says which kind
///    failed and why (§5.1).
/// 2. **Numbers against an independent implementation.** The synthetic matte is injected through the
///    provider protocol (no RAW file, no OS model, no 120 ms Vision call) and the atlas is compared
///    pixel by pixel against `SemanticRaster.coverage` — the host mirror of `semantic_alpha` in
///    `s1_5_mask_atlas.metal`.
/// 3. **Frames.** `showMask` is checked as a formula (50 % red, coverage-weighted), as a hash (stable
///    across renders), as an exactness claim (`nil` changes nothing) and finally as a recorded golden,
///    which is a new file so 005b/005c/005d's frames stay exactly as recorded.
final class MaskSemanticTests: XCTestCase {

    /// Millisecond ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where a render/DB pass measures several times its Release number.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - fixtures

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

    private func makeGraph(_ image: LinearImage, identity: String = "semantic-test",
                           provider: SemanticMatteProvider = StubSemanticProvider()) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity),
                               semanticMatte: provider)
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage,
                       provider: SemanticMatteProvider = StubSemanticProvider()) throws -> MaskAtlasDump {
        let graph = try makeGraph(image, provider: provider)
        return try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)),
                             "a document with an enabled mask must produce an atlas")
    }

    private func sha(_ display: DisplayImage) -> String { display.sha256() }

    private func value(_ display: DisplayImage, _ x: Int, _ y: Int, _ channel: Int) -> Double {
        Double(display.rgba[(y * display.width + x) * 4 + channel])
    }

    /// One mask, one semantic component, no mask-level feather, so the atlas coverage is exactly the
    /// matte's (any blur would move the reference, not the claim).
    private func semanticDoc(kind: SemanticKind, provider: SemanticProvider = .visionForeground,
                             softEdge: Double = 0.2,
                             adjustments: LocalAdjustments = LocalAdjustments(exposure: 1)) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-sem",
                           components: [MaskComponent(id: "c-sem", feather: 0.5,
                                                      shape: .semantic(SemanticShape(kind: kind,
                                                                                     provider: provider,
                                                                                     softEdge: softEdge)))],
                           adjustments: adjustments)]
        return edit
    }

    // MARK: - 1. a matte that does not exist

    /// §5.1: no route, no matte, **zero coverage and a reason** — not a crash, not a gradient stand-in.
    func testSemanticUnavailableContributesNoCoverageAndReportsTheKind() throws {
        let image = rampImage()
        let provider = StubSemanticProvider(reasons: [.sky: .noSystemMatte,
                                                      .person: .visionFailed])
        var edit = semanticDoc(kind: .sky)
        edit.masks[0].components.append(MaskComponent(
            id: "c-person", op: .add, feather: 0.5,
            shape: .semantic(SemanticShape(kind: .person))))
        edit.showMaskID = "m-sem"      // asking to show it must not resurrect coverage either

        let graph = try makeGraph(image, provider: provider)
        let result = try XCTUnwrap(try graph.maskAtlasWithReport(edit, options: RenderOptions(scale: 1)))

        XCTAssertEqual(result.dump.slices.first?.max() ?? -1, 0, "no matte ⇒ no coverage")
        XCTAssertEqual(Set(result.dump.slices.flatMap { $0 }), [0], "every pixel must be exactly 0")
        XCTAssertEqual(result.report.semanticUnavailableKinds, [.sky, .person])
        XCTAssertTrue(result.report.semanticDigests.isEmpty, "nothing resolved, nothing to digest")

        // The reasons are typed values, and the route is remembered.
        let reasons: [SemanticUnavailableReason] = result.report.semanticEvents.compactMap { event in
            if case .semanticUnavailable(_, _, _, let reason) = event { return reason }
            return nil
        }
        XCTAssertEqual(reasons, [.noSystemMatte, .visionFailed])
        XCTAssertEqual(provider.calls.count, 2, "one provider call per component, cached afterwards")
        XCTAssertEqual(provider.calls.map(\.kind), [.sky, .person])

        // A second frame is a cache hit: the same numbers, no new provider call.
        let again = try XCTUnwrap(try graph.maskAtlasWithReport(edit, options: RenderOptions(scale: 1)))
        XCTAssertEqual(again.dump.slices.first?.max() ?? -1, 0)
        XCTAssertEqual(provider.calls.count, 2, "an unavailable matte must be cached too")
    }

    /// An unavailable component keeps its place in the combination order with zero coverage, so `add`
    /// leaves the other components' union untouched — the same arithmetic an empty shape gets.
    func testUnavailableSemanticLeavesTheOtherComponentsUntouched() throws {
        let image = rampImage()
        var withSemantic = semanticDoc(kind: .person)
        withSemantic.masks[0].components.insert(
            MaskComponent(id: "c-radial", feather: 0.3, shape: .radialGradient(
                RadialGradientShape(center: NormalizedPoint(0.4, 0.45),
                                    radius: NormalizedPoint(0.25, 0.25)))), at: 0)

        var radialOnly = withSemantic
        radialOnly.masks[0].components.remove(at: 1)

        let a = try atlas(withSemantic, image)
        let b = try atlas(radialOnly, image)
        var worst = 0.0
        for i in 0..<(a.width * a.height) {
            worst = max(worst, abs(Double(a.slices[0][i]) - Double(b.slices[0][i])))
        }
        XCTAssertLessThanOrEqual(worst, 1.0 / 255, "add(0) must be the identity")
        XCTAssertGreaterThan(b.slices[0].max() ?? 0, 0.9, "the radial must still be there")
    }

    // MARK: - 2. a matte that does exist

    /// The injected matte reaches the atlas, stays in `[0, 1]`, has a real area, and every pixel
    /// matches the host reference (`coverage`, the mirror of `semantic_alpha`) within half-float noise.
    func testInjectedMatteCoversTheAtlasAndMatchesTheHostReference() throws {
        let image = rampImage()
        let matte = StubSemanticProvider.rampRaster()
        let provider = StubSemanticProvider(rasters: [.subject: matte])
        let edit = semanticDoc(kind: .subject, softEdge: 0.2)

        let result = try XCTUnwrap(try makeGraph(image, provider: provider)
            .maskAtlasWithReport(edit, options: RenderOptions(scale: 1)))
        let slice = result.dump.slices[0]

        XCTAssertEqual(result.report.semanticDigests, [matte.digest])
        let available = result.report.semanticEvents.filter(\.isAvailable)
        XCTAssertEqual(available.count, 1)
        if case .semanticAvailable(_, _, let kind, let route, _) = available[0] {
            XCTAssertEqual(kind, .subject)
            XCTAssertEqual(route, .visionForeground)
        } else {
            XCTFail("expected a semanticAvailable event")
        }

        var nonZero = 0
        var peak = 0.0
        var worst = 0.0
        for y in 0..<result.dump.height {
            for x in 0..<result.dump.width {
                let got = Double(slice[y * result.dump.width + x])
                XCTAssertGreaterThanOrEqual(got, 0)
                XCTAssertLessThanOrEqual(got, 1)
                let u = (Double(x) + 0.5) / Double(result.dump.width)
                let v = (Double(y) + 0.5) / Double(result.dump.height)
                worst = max(worst, abs(got - matte.coverage(u: u, v: v, softEdge: 0.2)))
                if got > 0 { nonZero += 1 }
                peak = max(peak, got)
            }
        }
        XCTAssertGreaterThan(peak, 0.9, "the fixture matte must reach full coverage somewhere")
        XCTAssertGreaterThan(Double(nonZero) / Double(result.dump.width * result.dump.height), 0.15,
                             "a matte with 33 % of the frame covered cannot land on 15 % of it")
        XCTAssertLessThanOrEqual(worst, 2.0 / 255,
                                 "GPU vs host reference: worst |Δ| = \(worst)")

        // §5.3: a stored digest that disagrees with what the OS produced is *reported*, not applied
        // silently — the UI is what decides to warn.
        var stale = edit
        stale.masks[0].components[0].shape = .semantic(
            SemanticShape(kind: .subject, softEdge: 0.2, rasterDigest: "deadbeef"))
        let staleResult = try XCTUnwrap(try makeGraph(image, provider: provider)
            .maskAtlasWithReport(stale, options: RenderOptions(scale: 1)))
        let reported = staleResult.report.semanticEvents.contains { event in
            if case .semanticDigestChanged(_, _, let stored, let produced) = event {
                return stored == "deadbeef" && produced == matte.digest
            }
            return false
        }
        XCTAssertTrue(reported, "a moved raster digest must be reported")
        XCTAssertEqual(staleResult.dump.slices, result.dump.slices,
                       "a stale digest is a warning, not a different selection")
    }

    /// `softEdge` is a real knob: at 0 the matte is binarised at 0.5, at 1 the soft ramp is kept.
    func testSoftEdgeSharpensAndSoftensTheMatte() throws {
        let image = rampImage()
        let provider = StubSemanticProvider(rasters: [.subject: StubSemanticProvider.diskRaster()])

        func partialFraction(_ softEdge: Double) throws -> Double {
            let dump = try atlas(semanticDoc(kind: .subject, softEdge: softEdge), image, provider: provider)
            let slice = dump.slices[0]
            let partial = slice.filter { $0 > 0.02 && $0 < 0.98 }.count
            return Double(partial) / Double(slice.count)
        }
        let hard = try partialFraction(0)
        let soft = try partialFraction(1.0)
        XCTAssertLessThan(hard, soft, "a narrower smoothstep window must produce fewer partial pixels")
        XCTAssertLessThan(hard, 0.01)
    }

    /// Two components asking for the same matte share one raster slice, and the coverage is the
    /// matte's — not twice the matte's.
    func testDuplicateSemanticComponentsShareOneRaster() throws {
        let image = rampImage()
        let provider = StubSemanticProvider(rasters: [.subject: StubSemanticProvider.diskRaster()])
        var edit = semanticDoc(kind: .subject)
        edit.masks[0].components.append(MaskComponent(
            id: "c-again", op: .add, feather: 0.5,
            shape: .semantic(SemanticShape(kind: .subject))))

        let graph = try makeGraph(image, provider: provider)
        let result = try XCTUnwrap(try graph.maskAtlasWithReport(edit, options: RenderOptions(scale: 1)))
        XCTAssertEqual(provider.calls.count, 1, "one kind, one provider call")
        XCTAssertLessThanOrEqual(result.dump.slices[0].max() ?? 9, 1.0, "add is a union, not a sum")
    }

    // MARK: - 3. the in-memory cache (§5.2, 005e ③)

    func testMatteCacheMakesTheSecondCallFastAndStaysKindScoped() throws {
        let provider = StubSemanticProvider(rasters: [.subject: StubSemanticProvider.diskRaster(),
                                                      .person: StubSemanticProvider.diskRaster()])
        provider.delay = 0.06                       // a Vision call, in miniature
        let store = SemanticMatteStore()
        let source = SemanticMatteSource(image: rampImage(), contentHash: "hash-A")

        let t0 = CFAbsoluteTimeGetCurrent()
        let first = store.resolve(kind: .subject, route: .visionForeground,
                                  source: source, provider: provider)
        let firstMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertNotNil(first.raster)
        XCTAssertGreaterThan(firstMs, 50, "the stub must actually be slow, or the test proves nothing")

        let t1 = CFAbsoluteTimeGetCurrent()
        let second = store.resolve(kind: .subject, route: .visionForeground,
                                   source: source, provider: provider)
        let secondMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        XCTAssertEqual(second.raster?.digest, first.raster?.digest)
        if ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" {
            XCTAssertLessThan(secondMs, 5, "second call took \(secondMs) ms (budget 5 ms)")
        }
        XCTAssertEqual(provider.calls.count, 1, "the cache must not re-ask the model")
        XCTAssertEqual(store.providerCalls, 1)

        // Kind and content hash are both part of the key.
        _ = store.resolve(kind: .person, route: .visionForeground, source: source, provider: provider)
        XCTAssertEqual(provider.calls.count, 2)
        let other = SemanticMatteSource(image: rampImage(), contentHash: "hash-B")
        _ = store.resolve(kind: .subject, route: .visionForeground, source: other, provider: provider)
        XCTAssertEqual(provider.calls.count, 3)
        XCTAssertEqual(store.entryCount, 3)
        print(String(format: "SEMANTIC raster: first %.1f ms (stub), cached %.3f ms", firstMs, secondMs))
    }

    func testRasterDigestIsStableAndContentSensitive() {
        let a = SemanticRaster(width: 4, height: 2, values: [0, 0.25, 0.5, 1, 1, 0.5, 0.25, 0],
                               provider: .visionForeground, modelVersion: "m1")
        let b = SemanticRaster(width: 4, height: 2, values: [0, 0.25, 0.5, 1, 1, 0.5, 0.25, 0],
                               provider: .visionForeground, modelVersion: "m1")
        XCTAssertEqual(a.digest, b.digest, "the digest must be a pure function of the content")
        XCTAssertEqual(a.digest.count, 64)

        var changed = a.values
        changed[3] = 0.999
        XCTAssertNotEqual(
            SemanticRaster(width: 4, height: 2, values: changed,
                           provider: .visionForeground, modelVersion: "m1").digest, a.digest)
        XCTAssertNotEqual(
            SemanticRaster(width: 4, height: 2, values: a.values,
                           provider: .systemMatte, modelVersion: "m1").digest, a.digest,
            "a different route is a different selection")
        XCTAssertNotEqual(
            SemanticRaster(width: 4, height: 2, values: a.values,
                           provider: .visionForeground, modelVersion: "m2").digest, a.digest,
            "a different model version is a different selection")
    }

    /// §5.1/§5.2 as data: six CI mattes, three Vision kinds, seven shipped kinds.
    func testSemanticRoutesCoverTheDocumentedKinds() {
        XCTAssertEqual(SemanticRoute.kinds, [.sky, .subject, .person, .hair, .skin, .teeth, .glasses])
        for kind in SemanticRoute.kinds {
            XCTAssertTrue(SemanticRoute.systemMatteSupports(kind) || SemanticRoute.visionSupports(kind),
                          "\(kind) must have at least one route")
        }
        XCTAssertEqual(SemanticRoute.kinds.filter(SemanticRoute.systemMatteSupports),
                       [.sky, .person, .hair, .skin, .teeth, .glasses])
        XCTAssertEqual(SemanticRoute.kinds.filter(SemanticRoute.visionSupports), [.subject, .person])
        XCTAssertTrue(SemanticRoute.visionSupports(.foreground), "the legacy spelling is the same route")
        XCTAssertFalse(SemanticRoute.systemMatteSupports(.subject))
    }

    /// The shape decodes, round-trips and reports itself as renderable — but its extent is the frame,
    /// because only the model knows where the subject is.
    func testSemanticShapeRoundTripsWithTheNewKinds() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for kind in SemanticKind.allCases {
            let shape = MaskShape.semantic(SemanticShape(kind: kind, provider: .systemMatte,
                                                         softEdge: 0.35,
                                                         rasterDigest: "abc123"))
            let data = try encoder.encode(shape)
            let back = try JSONDecoder().decode(MaskShape.self, from: data)
            XCTAssertEqual(back, shape, "\(kind) must round-trip")
            XCTAssertTrue(back.isRenderableNow)
            let extent = MaskBounds.sourceExtent(of: MaskComponent(id: "c", shape: back),
                                                 source: ImageSize(width: 400, height: 300))
            XCTAssertEqual(extent, MaskRect(0, 0, 400, 300),
                           "\(kind): a content-dependent extent is the frame")
        }
        // The wire spelling of a sub-kind is `subject` (never a second `kind` key).
        let json = String(decoding: try encoder.encode(
            MaskShape.semantic(SemanticShape(kind: .teeth))), as: UTF8.self)
        XCTAssertTrue(json.contains("\"subject\":\"teeth\""), json)
        XCTAssertEqual(json.components(separatedBy: "\"kind\"").count, 2,
                       "exactly one `kind` discriminator: \(json)")
    }

    // MARK: - 4. showMask

    private func twoMaskDoc() -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [
            Mask(id: "m-a", name: "radial",
                 components: [MaskComponent(id: "a1", feather: 0.4, shape: .radialGradient(
                    RadialGradientShape(center: NormalizedPoint(0.35, 0.5),
                                        radius: NormalizedPoint(0.25, 0.25))))],
                 adjustments: LocalAdjustments(exposure: 0.6)),
            Mask(id: "m-b", name: "linear",
                 components: [MaskComponent(id: "b1", feather: 0.4, shape: .linearGradient(
                    LinearGradientShape(start: NormalizedPoint(0.6, 0),
                                        end: NormalizedPoint(0.85, 1))))],
                 adjustments: LocalAdjustments(exposure: -0.6)),
        ]
        return edit
    }

    /// The hard claim: `showMask == nil` is the frame the document already produced.
    func testShowMaskNilIsPixelIdenticalAndReportsNoOverlay() throws {
        let image = rampImage()
        var doc = twoMaskDoc()
        doc.showMaskID = nil

        let plain = try makeGraph(image, identity: "show-none")
        let reference = try plain.render(doc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(reference.showsMask)
        let display = try XCTUnwrap(reference.display)
        let digest = sha(display)

        // A graph that has *rendered* the overlay before must come back to the same pixels: the
        // overlay may not leave state behind (no cached display texture to inherit it from).
        var shown = doc
        shown.showMaskID = "m-a"
        let reused = try makeGraph(image, identity: "show-none")
        _ = try reused.render(shown, options: RenderOptions(scale: 1, wantsPixels: true))
        let cleared = try reused.render(doc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(cleared.showsMask)
        XCTAssertEqual(try XCTUnwrap(cleared.display).sha256(), digest,
                       "clearing showMask must restore the exact frame")

        // And the neutral document is untouched by the field existing at all.
        let neutral = try plain.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        let neutralAgain = try plain.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertEqual(try XCTUnwrap(neutral.display).sha256(),
                       try XCTUnwrap(neutralAgain.display).sha256())
        print("SHOWMASK nil frame sha256 = \(digest)")
    }

    /// `showMask` blends 50 % red by coverage, reading the atlas — not a second predicate evaluation.
    func testShowMaskBlendsFiftyPercentRedWhereTheAtlasCovers() throws {
        let image = rampImage()
        let plainDoc = twoMaskDoc()
        var shownDoc = plainDoc
        shownDoc.showMaskID = "m-a"

        let graph = try makeGraph(image, identity: "show-formula")
        let plain = try graph.render(plainDoc, options: RenderOptions(scale: 1, wantsPixels: true))
        let shown = try graph.render(shownDoc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(shown.showsMask)
        XCTAssertNotEqual(try XCTUnwrap(shown.display).sha256(),
                          try XCTUnwrap(plain.display).sha256(),
                          "the overlay must change the frame")

        let dump = try XCTUnwrap(try graph.maskAtlas(plainDoc, options: RenderOptions(scale: 1)))
        let slice = try XCTUnwrap(dump.slice(forMask: "m-a"))
        let before = try XCTUnwrap(plain.display)
        let after = try XCTUnwrap(shown.display)

        var checked = 0
        var worst = 0.0
        for y in stride(from: 2, to: before.height - 2, by: 3) {
            for x in stride(from: 2, to: before.width - 2, by: 3) {
                let c = Double(slice[y * dump.width + x])
                for channel in 0..<3 {
                    let expect = channel == 0
                        ? value(before, x, y, 0) * (1 - 0.5 * c) + 0.5 * c   // toward red 1.0
                        : value(before, x, y, channel) * (1 - 0.5 * c)       // toward red 0.0
                    worst = max(worst, abs(value(after, x, y, channel) - expect))
                }
                if c == 0 {
                    for channel in 0..<3 {
                        XCTAssertEqual(after.rgba[(y * after.width + x) * 4 + channel],
                                       before.rgba[(y * before.width + x) * 4 + channel],
                                       "coverage 0 must be bit-identical at (\(x), \(y))")
                    }
                }
                if c > 0.2 { checked += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 40, "the fixture must have a real covered area")
        XCTAssertLessThanOrEqual(worst, 2.0 / 255, "50 % red formula: worst |Δ| = \(worst)")
        // Alpha is the photograph's, never the mask's.
        XCTAssertEqual(after.rgba[3], before.rgba[3])
    }

    /// An id that names no enabled mask paints nothing — and says so, instead of throwing.
    func testShowMaskWithAnUnknownIDPaintsNothing() throws {
        let image = rampImage()
        var doc = twoMaskDoc()
        doc.showMaskID = "m-does-not-exist"

        let graph = try makeGraph(image, identity: "show-unknown")
        let unknown = try graph.render(doc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(unknown.showsMask)
        XCTAssertNil(unknown.maskReport?.showMaskSlice)

        var none = doc
        none.showMaskID = nil
        let reference = try graph.render(none, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertEqual(try XCTUnwrap(unknown.display).sha256(),
                       try XCTUnwrap(reference.display).sha256())

        // A disabled mask is not a mask either.
        doc.showMaskID = "m-a"
        doc.masks[0].isEnabled = false
        let disabled = try graph.render(doc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertFalse(disabled.showsMask)
    }

    /// §6 005e ⑤: the overlay and S1.6 read the same buffer, so the atlas must not change when the
    /// overlay is switched on, and the slice index must be the one the atlas was built with.
    func testShowMaskReadsTheSameAtlasSlice() throws {
        let image = rampImage()
        var shownDoc = twoMaskDoc()
        shownDoc.showMaskID = "m-b"

        let graph = try makeGraph(image, identity: "show-atlas")
        let withOverlay = try XCTUnwrap(
            try graph.maskAtlasWithReport(shownDoc, options: RenderOptions(scale: 1)))
        var plainDoc = shownDoc
        plainDoc.showMaskID = nil
        let without = try XCTUnwrap(
            try graph.maskAtlasWithReport(plainDoc, options: RenderOptions(scale: 1)))

        XCTAssertEqual(withOverlay.dump.maskIDs, without.dump.maskIDs)
        XCTAssertEqual(withOverlay.dump.slices, without.dump.slices,
                       "switching the overlay on must not move a single coverage value")
        XCTAssertEqual(withOverlay.report.showMaskID, "m-b")
        XCTAssertEqual(withOverlay.report.showMaskSlice, 1, "m-b is the second slice (id order)")
        XCTAssertNil(without.report.showMaskID)

        // Stable across two identical renders (no accumulation, no state).
        let first = try graph.render(shownDoc, options: RenderOptions(scale: 1, wantsPixels: true))
        let second = try graph.render(shownDoc, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertEqual(try XCTUnwrap(first.display).sha256(),
                       try XCTUnwrap(second.display).sha256())
        print("SHOWMASK frame sha256 = \(try XCTUnwrap(first.display).sha256())")
    }

    /// `showMask` is a display-stage change and nothing else: it moves the display key, and — the
    /// other half of the same claim — it leaves every other link byte-identical, including the seven
    /// M1 links of a document without masks.
    func testShowMaskMovesOnlyTheDisplayKey() {
        var edit = EditModel.neutral
        edit.light.exposure = 0.4
        edit.masks = twoMaskDoc().masks
        let display = DisplayOptions()
        let size = ImageSize(width: 400, height: 300)
        func links(_ e: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "keyvec", sourceSize: size, canvas: size,
                                 content: size, edit: e, display: display)
        }
        let off = links(edit)
        var on = edit
        on.showMaskID = "m-a"
        let showing = links(on)

        XCTAssertNotEqual(showing.display, off.display, "the display link must move")
        XCTAssertEqual(showing.geometry, off.geometry)
        XCTAssertEqual(showing.sceneLinear, off.sceneLinear)
        XCTAssertEqual(showing.maskAtlas, off.maskAtlas)
        XCTAssertEqual(showing.localApply, off.localApply)
        XCTAssertEqual(showing.toneMap, off.toneMap)
        XCTAssertEqual(showing.curve, off.curve)
        XCTAssertEqual(showing.color, off.color)
        XCTAssertEqual(showing.vignette, off.vignette)

        // An empty document keeps the seven M1 links and no mask stages, with the field set to nil.
        var empty = EditModel.neutral
        empty.showMaskID = nil
        let emptyLinks = links(empty)
        XCTAssertNil(emptyLinks.maskAtlas)
        XCTAssertNil(emptyLinks.localApply)
        XCTAssertEqual(RenderKeyChain.keys(emptyLinks, identity: "keyvec").pipeline.count, 7)

        // And `changedStages` says "display only".
        XCTAssertEqual(on.changedStages(from: edit), [.display])
        XCTAssertEqual(EditModel.neutral.changedStages(from: empty), [])
    }

    /// The document itself must not grow a field it does not use: a nil `showMaskID` is **absent**
    /// from the JSON, so every existing document keeps its bytes and its digest.
    func testShowMaskIDIsOmittedFromTheDocumentWhenNil() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let neutral = String(decoding: try encoder.encode(EditModel.neutral), as: UTF8.self)
        XCTAssertFalse(neutral.contains("showMaskID"), neutral)

        var doc = twoMaskDoc()
        doc.showMaskID = "m-b"
        let data = try encoder.encode(doc)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"showMaskID\":\"m-b\""), json)

        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.showMaskID, "m-b")
        XCTAssertEqual(back, doc, "the overlay id must round-trip with the document")

        // A document written before 005e decodes to nil, not to a decode failure.
        let legacy = String(decoding: try encoder.encode(EditModel.neutral), as: UTF8.self)
        XCTAssertNil(try JSONDecoder().decode(EditModel.self,
                                              from: Data(legacy.utf8)).showMaskID)
    }

    /// The matte is environment, not document: when `CIRAWFilter` starts answering (an OS update, a
    /// different file) the coverage changes while the *document* does not — so every stage the atlas
    /// feeds must miss its cache, not just the two mask stages.
    func testAMatteAppearingInvalidatesEveryDownstreamStage() throws {
        let image = rampImage()
        let provider = StubSemanticProvider()            // ① no route answers
        let edit = semanticDoc(kind: .subject)
        let graph = try makeGraph(image, provider: provider)

        let first = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(first.trace.executed.contains(.toneMap))
        let empty = try XCTUnwrap(first.display)

        // ② the model changes: the same document, a different answer.
        provider.modelVersion = "stub-2"
        provider.rasters[.subject] = StubSemanticProvider.rampRaster()
        let second = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(second.trace.executed.contains(.maskAtlas), "a new matte must rebuild the atlas")
        XCTAssertTrue(second.trace.executed.contains(.toneMap),
                      "…and every stage downstream of it: a hit there would show the old selection")
        XCTAssertNotEqual(try XCTUnwrap(second.display).sha256(), empty.sha256())

        // A third identical frame is a hit again — the suffix only moves when the answer moves.
        let third = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(third.trace.skipped.contains(.maskAtlas))
        XCTAssertEqual(try XCTUnwrap(third.display).sha256(),
                       try XCTUnwrap(second.display).sha256())
    }

    // MARK: - 5. the recorded frame (a new file; 005b/005c/005d stay as recorded)
    private struct ShowMaskGolden: Codable, Equatable {
        var note: String
        var sourceWidth: Int
        var sourceHeight: Int
        var maskIDs: [String]
        var shownMaskID: String
        var shownSlice: Int
        var atlasSHA256: String
        var plainDisplaySHA256: String
        var showDisplaySHA256: String
        var samples: [[Double]]
        var sampleX: [Int]
        var sampleY: [Int]
    }

    private var goldenDir: URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_GOLDEN_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Golden")
    }

    private func quantisedDigest(_ values: [Float]) -> String {
        var bytes = [UInt8](repeating: 0, count: values.count)
        for (i, v) in values.enumerated() {
            bytes[i] = UInt8(min(max((Double(v) * 255).rounded(), 0), 255))
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func showMaskGolden() throws -> (record: ShowMaskGolden, json: String) {
        let image = rampImage()   // 96 × 65
        var doc = twoMaskDoc()
        doc.showMaskID = "m-b"
        let graph = try makeGraph(image, identity: "show-mask-golden")

        let dump = try XCTUnwrap(try graph.maskAtlas(doc, options: RenderOptions(scale: 1)))
        let shown = try XCTUnwrap(try graph.render(doc, options: RenderOptions(scale: 1,
                                                                              wantsPixels: true)).display)
        var plain = doc
        plain.showMaskID = nil
        let before = try XCTUnwrap(try graph.render(plain, options: RenderOptions(scale: 1,
                                                                                 wantsPixels: true)).display)

        let sampleX = [8, 48, 80, 30, 64, 88]
        let sampleY = [8, 32, 56, 40, 20, 48]
        var samples: [[Double]] = []
        for (x, y) in zip(sampleX, sampleY) {
            samples.append((0..<3).map { Double(shown.rgba[(y * shown.width + x) * 4 + $0]) })
        }

        let record = ShowMaskGolden(
            note: "Recorded by MaskSemanticTests on the synthetic 96×65 ramp image; two masks (m-a "
                + "radial +0.6 EV, m-b linear −0.6 EV, re-recorded for 102's symmetric linear feather) "
                + "with showMask = m-b. `showDisplaySHA256` is the "
                + "frame after the 50 % red overlay, `plainDisplaySHA256` the same document without it, "
                + "so the file pins both sides of the 005e criterion. 8-bit quantised digests.",
            sourceWidth: image.width, sourceHeight: image.height,
            maskIDs: dump.maskIDs,
            shownMaskID: "m-b",
            shownSlice: try XCTUnwrap(dump.maskIDs.firstIndex(of: "m-b")),
            atlasSHA256: quantisedDigest(dump.slices.flatMap { $0 }),
            plainDisplaySHA256: quantisedDigest((0..<(before.width * before.height)).flatMap { i -> [Float] in
                [Float(before.rgba[i * 4]), Float(before.rgba[i * 4 + 1]), Float(before.rgba[i * 4 + 2])]
            }),
            showDisplaySHA256: quantisedDigest((0..<(shown.width * shown.height)).flatMap { i -> [Float] in
                [Float(shown.rgba[i * 4]), Float(shown.rgba[i * 4 + 1]), Float(shown.rgba[i * 4 + 2])]
            }),
            samples: samples, sampleX: sampleX, sampleY: sampleY)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (record, String(decoding: try encoder.encode(record), as: UTF8.self))
    }

    /// Regenerate with `PHOTONS_RECORD_GOLDEN=1 swift test --filter testShowMaskFrameGolden`.
    func testShowMaskFrameGolden() throws {
        let (record, json) = try showMaskGolden()
        let url = goldenDir.appendingPathComponent("mask-show-mask-s1.0.json")
        guard let data = try? Data(contentsOf: url) else {
            if ProcessInfo.processInfo.environment["PHOTONS_RECORD_GOLDEN"] == "1" {
                try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
                try Data(json.utf8).write(to: url)
                return
            }
            XCTFail("no golden at \(url.path). Recorded frame:\n\(json)")
            return
        }
        let golden = try JSONDecoder().decode(ShowMaskGolden.self, from: data)
        XCTAssertEqual(golden.sourceWidth, record.sourceWidth)
        XCTAssertEqual(golden.sourceHeight, record.sourceHeight)
        XCTAssertEqual(golden.maskIDs, record.maskIDs)
        XCTAssertEqual(golden.shownMaskID, record.shownMaskID)
        XCTAssertEqual(golden.shownSlice, record.shownSlice)
        XCTAssertEqual(golden.atlasSHA256, record.atlasSHA256, "atlas coverage changed")
        XCTAssertEqual(golden.plainDisplaySHA256, record.plainDisplaySHA256, "the un-overlaid frame changed")
        XCTAssertEqual(golden.showDisplaySHA256, record.showDisplaySHA256, "the overlaid frame changed")
        for (i, pair) in golden.samples.enumerated() {
            XCTAssertEqual(pair.count, record.samples[i].count)
            for (c, expected) in pair.enumerated() {
                XCTAssertEqual(record.samples[i][c], expected, accuracy: 1.5 / 255,
                               "sample \(i) channel \(c)")
            }
        }
    }

    // MARK: - 6. measurement (skipped unless asked)

    /// `showMask` on and off, 4.10 Mpx, full S0→S4 with cache off. The overlay is one extra pointwise
    /// pass, so the delta is the pass plus one readback-sized texture; the number is reported, not
    /// asserted, for the same reason as 005d's budget test.
    func testShowMaskFrameBudget() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" else {
            throw XCTSkip("set PHOTONS_BENCH=1 to measure the showMask frame budget")
        }
        let image = rampImage(width: 2731, height: 1500)   // 4.0965 Mpx ≈ 4.10 Mpx
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        var doc = EditModel.neutral
        doc.masks = [
            Mask(id: "m-a", feather: 0.15,
                 components: [MaskComponent(id: "a1", feather: 0.4, shape: .radialGradient(
                    RadialGradientShape(center: NormalizedPoint(0.35, 0.4),
                                        radius: NormalizedPoint(0.22, 0.22))))],
                 adjustments: LocalAdjustments(exposure: 0.6)),
            Mask(id: "m-b", feather: 0.15,
                 components: [MaskComponent(id: "b1", feather: 0.4, shape: .brush(
                    BrushShape(size: 0.18, strokes: [
                        Stroke(points: [0.2, 0.6, 0.5, 0.72, 0.8, 0.62], radius: 0.07, feather: 0.4),
                    ])))],
                 adjustments: LocalAdjustments(exposure: -0.8)),
        ]

        func measure(_ label: String, _ edit: EditModel) throws -> (Double, Double) {
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-show"),
                                        semanticMatte: StubSemanticProvider())
            var times: [Double] = []
            for _ in 0..<25 {
                let r = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                     wantsPixels: false))
                if let t = r.output { graph.recycle(output: t) }
                times.append(r.trace.gpuMilliseconds)
            }
            times.sort()
            let p50 = times[times.count / 2]
            let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
            print(String(format: "BENCH showMask %@: p50 %.2f ms  p95 %.2f ms", label, p50, p95))
            XCTAssertLessThan(p95, 100, "\(label): a structural regression, not jitter")
            return (p50, p95)
        }

        let (offP50, offP95) = try measure("off", doc)
        var on = doc
        on.showMaskID = "m-a"
        let (onP50, onP95) = try measure("on ", on)
        print(String(format: "BENCH showMask delta: p50 %+.2f ms  p95 %+.2f ms",
                     onP50 - offP50, onP95 - offP95))
    }

    /// The real thing: probe this machine's RAW fixture for the six `CIRAWFilter` mattes and print the
    /// availability table (005e ①). Skipped unless `PHOTONS_SEMPROBE` points at a file, because it
    /// opens the file (and a 66 MB DNG takes a moment).
    func testSystemMatteProbeOnARealFile() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_SEMPROBE"], !path.isEmpty else {
            throw XCTSkip("set PHOTONS_SEMPROBE=/path/to/file.dng to probe the system mattes")
        }
        let url = URL(fileURLWithPath: path)
        let started = CFAbsoluteTimeGetCurrent()
        let table = SemanticMatteProbe.availability(url: url)
        let probeMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        XCTAssertFalse(table.isEmpty, "CIRAWFilter could not open \(path)")
        var lines: [String] = []
        for kind in SemanticKind.allCases {
            lines.append("\(kind.rawValue)=\(table[kind] == true ? "available" : "nil")")
        }
        print("SEMPROBE \(url.lastPathComponent) (\(String(format: "%.0f ms", probeMs))): "
              + lines.joined(separator: " "))

        // The nil path must be a *value*: probing a matte that is not there returns nil, no throw.
        for kind in SemanticKind.allCases where table[kind] != true {
            XCTAssertNil(SemanticMatteProbe.raster(url: url, kind: kind, modelVersion: "probe"),
                         "\(kind) reported nil but produced a raster")
        }
        // Whatever is available must be a usable raster.
        for kind in SemanticKind.allCases where table[kind] == true {
            let raster = try XCTUnwrap(SemanticMatteProbe.raster(url: url, kind: kind,
                                                                 modelVersion: "probe"))
            XCTAssertGreaterThan(raster.width, 1)
            XCTAssertGreaterThan(raster.height, 1)
            XCTAssertEqual(raster.provider, .systemMatte)
            print("SEMPROBE raster \(kind.rawValue): \(raster.width)×\(raster.height), "
                  + "nonZero \(String(format: "%.3f", raster.nonZeroFraction))")
        }
    }

    /// The Vision route on this machine, if the models are installed: the whole point of ② is that a
    /// subject mask exists without a system matte. Skipped unless `PHOTONS_VISION=1`.
    func testVisionForegroundOnASyntheticImage() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_VISION"] == "1" else {
            throw XCTSkip("set PHOTONS_VISION=1 to run the Vision foreground request")
        }
        let provider = SystemSemanticMatteProvider()

        // A flat ramp is not a photograph: the request should run and honestly find nothing.
        let ramp = SemanticMatteSource(image: rampImage(width: 640, height: 480),
                                       contentHash: "vision-ramp")
        let started = CFAbsoluteTimeGetCurrent()
        let flat = provider.matte(kind: .subject, route: .visionForeground, source: ramp)
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        switch flat {
        case .raster(let raster):
            print(String(format: "VISION subject(ramp): %.1f ms, %d×%d, nonZero %.3f",
                         ms, raster.width, raster.height, raster.nonZeroFraction))
        case .unavailable(let reason):
            print(String(format: "VISION subject(ramp): %.1f ms, unavailable (%@)", ms, reason.rawValue))
        }

        // A high-contrast subject on a dark field: what the model is for.
        var rgba = [Float16](repeating: 0, count: 640 * 480 * 4)
        for y in 0..<480 {
            for x in 0..<640 {
                let o = (y * 640 + x) * 4
                let dx = (Double(x) - 320) / 130, dy = (Double(y) - 240) / 170
                let inside = dx * dx + dy * dy < 1
                let v: Float = inside ? 0.75 : 0.04
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v * 0.92)
                rgba[o + 2] = Float16(v * 0.85); rgba[o + 3] = 1
            }
        }
        let subject = LinearImage(width: 640, height: 480, rgba: rgba,
                                  colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let source = SemanticMatteSource(image: subject, contentHash: "vision-subject")
        let t0 = CFAbsoluteTimeGetCurrent()
        let found = provider.matte(kind: .subject, route: .visionForeground, source: source)
        let subjectMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let t1 = CFAbsoluteTimeGetCurrent()
        _ = provider.matte(kind: .subject, route: .visionForeground, source: source)
        let warmMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        print(String(format: "VISION subject(synthetic): cold %.1f ms, warm %.1f ms",
                     subjectMs, warmMs))
        switch found {
        case .raster(let raster):
            print(String(format: "VISION subject(synthetic): %.1f ms, %d×%d, nonZero %.3f",
                         subjectMs, raster.width, raster.height, raster.nonZeroFraction))
            // If the model found it, the coverage must be inside the blob, not everywhere.
            XCTAssertGreaterThan(raster.nonZeroFraction, 0.01)
            XCTAssertLessThan(raster.nonZeroFraction, 0.9)
        case .unavailable(let reason):
            print(String(format: "VISION subject(synthetic): %.1f ms, unavailable (%@)",
                         subjectMs, reason.rawValue))
        }

        let sky = provider.matte(kind: .sky, route: .visionForeground, source: source)
        XCTAssertEqual(sky.reason, .noVisionRequest, "there is no sky request (§5.2)")
    }
}

// MARK: - injected mattes (no RAW, no OS model)

/// A provider whose answers the test chooses. Deliberately not `Sendable`: the graph owns it and the
/// test reads `calls` afterwards, which is the whole reason the route is a protocol.
final class StubSemanticProvider: SemanticMatteProvider {
    var modelVersion: String
    var rasters: [SemanticKind: SemanticRaster]
    var reasons: [SemanticKind: SemanticUnavailableReason]
    /// A stand-in for a model call, so the cache test can prove a hit rather than a fast miss.
    var delay: TimeInterval = 0
    private(set) var calls: [(kind: SemanticKind, route: SemanticProvider)] = []

    init(rasters: [SemanticKind: SemanticRaster] = [:],
         reasons: [SemanticKind: SemanticUnavailableReason] = [:],
         modelVersion: String = "stub-1") {
        self.rasters = rasters
        self.reasons = reasons
        self.modelVersion = modelVersion
    }

    func matte(kind: SemanticKind, route: SemanticProvider,
               source: SemanticMatteSource) -> SemanticMatteResult {
        calls.append((kind, route))
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let raster = rasters[kind] { return .raster(raster) }
        return .unavailable(reasons[kind] ?? .noSystemMatte)
    }

    /// A soft-edged disk covering roughly a third of the frame, at an analysis-like resolution so the
    /// atlas has to upsample it (which is what the kernel does for a real matte).
    static func diskRaster(width: Int = 40, height: Int = 26,
                           center: (Double, Double) = (0.35, 0.5),
                           radius: Double = 0.24) -> SemanticRaster {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let v = (Double(y) + 0.5) / Double(height)
                let d = ((u - center.0) * (u - center.0) + (v - center.1) * (v - center.1)).squareRoot()
                values[y * width + x] = Float(min(max((radius - d) / (0.15 * radius), 0), 1))
            }
        }
        return SemanticRaster(width: width, height: height, values: values,
                              provider: .visionForeground, modelVersion: "stub-1")
    }

    /// A matte whose *gradient* is gentle (one unit across the frame), for the numeric comparison
    /// against the host reference. A model matte is that shape: a soft ramp of coverage. A steep
    /// three-texel edge would compare the sampler's last-bit rounding instead of its geometry, which
    /// is a different claim (and `diskRaster` pins the area/edge behaviour where it belongs).
    static func rampRaster(width: Int = 64, height: Int = 32) -> SemanticRaster {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = Float((Double(x) + 0.5) / Double(width))
            }
        }
        return SemanticRaster(width: width, height: height, values: values,
                              provider: .visionForeground, modelVersion: "stub-1")
    }
}
