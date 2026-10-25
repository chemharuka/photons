import XCTest
import PhotonsCore
import PhotonsExport
import CoreGraphics
import ImageIO

/// M1 acceptance tests: the editing graph.
///
/// Everything here renders real pixels from the real RAW fixture — a graph that only "encodes" is
/// worthless. The fixture is the user's own photo and is not vendored, so the suite skips (not
/// fails) when it is missing.
final class RenderTests: XCTestCase {

    // MARK: fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/PhotonsCoreTests/RenderTests.swift
            .deletingLastPathComponent()     // Tests/PhotonsCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func edit(_ name: String) throws -> EditModel {
        let url = Self.repoRoot.appendingPathComponent("Tests/Fixtures/\(name).json")
        return try EditModel.load(from: url)
    }

    /// Decode once at a small scale and build a graph on it. `identity` deliberately varies with the
    /// scale so a key from one fixture can never be mistaken for another's.
    private func makeGraph(scale: Float = 0.125) throws -> (RenderGraph, LinearImage) {
        let url = try fixtureURL()
        let img = try RAWDecoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: scale))
        let graph = try RenderGraph(input: RenderInput(image: img, identity: "test-scale-\(scale)"))
        return (graph, img)
    }

    private func srgbEncode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    // MARK: - 1. neutral is a pure identity pass

    /// The neutral document must produce exactly "decode → sRGB encode": no tone curve, no colour
    /// shift, no resample. If this drifts, every later milestone inherits a hidden baseline offset.
    func testNeutralRenderIsDecodePlusOETF() throws {
        let (graph, decoded) = try makeGraph()
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 0
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        let pixels = try XCTUnwrap(result.display)

        XCTAssertEqual(pixels.width, decoded.width)
        XCTAssertEqual(pixels.height, decoded.height)

        var maxError: Float = 0
        var count = 0
        for i in stride(from: 0, to: decoded.rgba.count, by: 4) {
            for c in 0..<3 {
                let expected = srgbEncode(min(max(Float(decoded.rgba[i + c]), 0), 1))
                let actual = Float(pixels.rgba[i + c])
                maxError = max(maxError, abs(expected - actual))
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        // rgba16Float carries ~11 bits of mantissa: half rounding shows up at ~5e-4, nothing more.
        XCTAssertLessThan(maxError, 0.002, "neutral render is not the identity path (max error \(maxError))")
    }

    // MARK: - 2. determinism

    /// Same input, same document, two independent graphs → identical pixels. L1 for the graph.
    func testRenderIsDeterministic() throws {
        let edit = try edit("edit-push")
        let (graphA, _) = try makeGraph()
        let (graphB, _) = try makeGraph()
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)
        let a = try XCTUnwrap(graphA.render(edit, options: opts).display)
        let b = try XCTUnwrap(graphB.render(edit, options: opts).display)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.sha256(), b.sha256())
    }

    // MARK: - 3. cache keys invalidate exactly the stages they should

    func testChangingOnlyColorParamsSkipsUpstreamStages() throws {
        let (graph, _) = try makeGraph()
        let neutral = EditModel.neutral
        var colored = neutral
        colored.color.saturation = 24
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)

        let first = try graph.render(neutral, options: opts)
        XCTAssertEqual(Set(first.trace.executed), Set(RenderStage.allCases),
                       "a cold graph must run every stage")

        let second = try graph.render(colored, options: opts)
        XCTAssertTrue(second.trace.skipped.contains(.geometry), "S0 must not re-run")
        XCTAssertTrue(second.trace.skipped.contains(.sceneLinear), "S1 must not re-run")
        XCTAssertTrue(second.trace.skipped.contains(.toneMap), "S2 must not re-run")
        XCTAssertFalse(second.trace.executed.isEmpty)
        XCTAssertTrue(second.trace.executed.contains(.color))
        // Different pixels are the point of the change, not just a different trace.
        XCTAssertNotEqual(first.display?.sha256(), second.display?.sha256())
    }

    func testChangingExposureRerunsS1ButNotS0() throws {
        let (graph, _) = try makeGraph()
        var bright = EditModel.neutral
        bright.light.exposure = 0.75
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)

        _ = try graph.render(EditModel.neutral, options: opts)
        let second = try graph.render(bright, options: opts)
        XCTAssertTrue(second.trace.skipped.contains(.geometry))
        XCTAssertTrue(second.trace.executed.contains(.sceneLinear))
        XCTAssertTrue(second.trace.executed.contains(.toneMap))
    }

    func testChangingCropRerunsEverything() throws {
        let (graph, _) = try makeGraph()
        var cropped = EditModel.neutral
        cropped.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let opts = RenderOptions(scale: 1, wantsPixels: true)

        let base = try graph.render(EditModel.neutral, options: opts)
        let second = try graph.render(cropped, options: opts)
        XCTAssertTrue(second.trace.executed.contains(.geometry))
        XCTAssertEqual(second.content.width, base.content.width / 2,
                       "crop of half the frame must halve the output width")
    }

    func testStageKeysAreStableAndSensitive() throws {
        let (graph, _) = try makeGraph()
        let opts = RenderOptions(scale: 0.25, wantsPixels: false)
        let a = try graph.render(EditModel.neutral, options: opts)
        if let t = a.output { graph.recycle(output: t) }
        let b = try graph.render(EditModel.neutral, options: opts)
        if let t = b.output { graph.recycle(output: t) }

        XCTAssertEqual(a.keys.geometry, b.keys.geometry)
        XCTAssertEqual(a.keys.display, b.keys.display)

        var exposed = EditModel.neutral
        exposed.light.exposure = 0.01
        let c = try graph.render(exposed, options: opts)
        if let t = c.output { graph.recycle(output: t) }

        XCTAssertEqual(a.keys.geometry, c.keys.geometry, "exposure must not touch the geometry key")
        XCTAssertNotEqual(a.keys.sceneLinear, c.keys.sceneLinear, "exposure must change the S1 key")
        XCTAssertNotEqual(a.keys.display, c.keys.display, "a changed upstream key must reach the end")
    }

    // MARK: - 4. parameters do what they say

    func testExposureRaisesMeanLuminance() throws {
        let (graph, _) = try makeGraph()
        var bright = EditModel.neutral
        bright.light.exposure = 1.0
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)
        let neutral = try XCTUnwrap(graph.render(EditModel.neutral, options: opts).display)
        let lifted = try XCTUnwrap(graph.render(bright, options: opts).display)

        func mean(_ img: DisplayImage) -> Double {
            var sum = 0.0
            var n = 0
            for i in stride(from: 0, to: img.rgba.count, by: 4) {
                sum += Double(Float(img.rgba[i]) + Float(img.rgba[i + 1]) + Float(img.rgba[i + 2])) / 3
                n += 1
            }
            return sum / Double(max(n, 1))
        }
        XCTAssertGreaterThan(mean(lifted), mean(neutral) * 1.05)
    }

    func testVignetteDarkensTheCornersNotTheCentre() throws {
        let (graph, _) = try makeGraph()
        var vignetted = EditModel.neutral
        vignetted.effects.vignetteAmount = -80
        vignetted.effects.vignetteMidpoint = 40
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)
        let neutral = try XCTUnwrap(graph.render(EditModel.neutral, options: opts).display)
        let dark = try XCTUnwrap(graph.render(vignetted, options: opts).display)

        func luma(_ img: DisplayImage, _ x: Int, _ y: Int) -> Float {
            let o = (y * img.width + x) * 4
            return Float(img.rgba[o]) + Float(img.rgba[o + 1]) + Float(img.rgba[o + 2])
        }
        let cx = neutral.width / 2, cy = neutral.height / 2
        let centreRatio = luma(dark, cx, cy) / max(luma(neutral, cx, cy), 1e-6)
        let cornerRatio = luma(dark, 2, 2) / max(luma(neutral, 2, 2), 1e-6)
        XCTAssertGreaterThan(centreRatio, 0.95, "vignette must not touch the centre")
        XCTAssertLessThan(cornerRatio, 0.9, "vignette must darken the corners")
    }

    func testDisplayP3OutputDiffersFromSRGB() throws {
        let (graph, _) = try makeGraph()
        let edit = try edit("edit-push")
        let srgb = try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 0.25, display: DisplayOptions(primaries: .sRGB), wantsPixels: true)).display)
        let p3 = try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 0.25, display: DisplayOptions(primaries: .displayP3), wantsPixels: true)).display)
        XCTAssertNotEqual(srgb.sha256(), p3.sha256())
        XCTAssertEqual(p3.primaries, .displayP3)
    }

    // MARK: - 5. the model itself

    func testPartialDocumentDecodesToExplicitDefaults() throws {
        let json = Data(#"{ "light": { "exposure": 0.5 } }"#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.light.exposure, 0.5)
        XCTAssertEqual(model.light.contrast, 0, "missing field must not become something else")
        XCTAssertEqual(model.light.temperature, 6500)
        XCTAssertEqual(model.geometry.crop, .full)
        XCTAssertEqual(model.color.bands.count, ColorGroup.bandCount)
        XCTAssertEqual(model.effects.vignetteMidpoint, 50)
        XCTAssertEqual(model.schemaVersion, EditModel.currentSchemaVersion)
        XCTAssertTrue(model.masks.isEmpty)
    }

    func testDocumentRoundTripsThroughJSON() throws {
        var model = try edit("edit-push")
        model.masks = [Mask(id: "m1", name: "Radial",
                            components: [MaskComponent(id: "c1", feather: 0.4,
                                                       shape: .radialGradient(RadialGradientShape(angle: 15)))],
                            adjustments: LocalAdjustments(exposure: 0.5))]
        let data = try JSONEncoder().encode(model)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back, model)
    }

    /// Group-level dirty tracking: a change reports the stage it touches, not every parameter.
    func testChangedStagesIsGroupLevel() throws {
        var a = EditModel.neutral
        var b = a
        b.light.exposure = 0.3
        XCTAssertEqual(a.changedStages(from: a), [])
        XCTAssertEqual(b.changedStages(from: a), [.sceneLinear])

        var c = a
        c.light.contrast = 20
        XCTAssertEqual(c.changedStages(from: a), [.toneMap])

        var d = a
        d.color.saturation = 10
        XCTAssertEqual(d.changedStages(from: a), [.color])

        var e = a
        e.processVersion += 1
        XCTAssertEqual(e.changedStages(from: a), Set(RenderStage.allCases),
                       "a process version bump invalidates everything")
        a.light.exposure = 0
        XCTAssertEqual(b.light.exposure, 0.3, "value semantics: edits must not alias")
    }

    // MARK: - 6. curve LUT

    func testCurveLUTIsMonotoneAndPinnedAtTheEnds() {
        let points = [CurvePoint(0, 0), CurvePoint(0.25, 0.15), CurvePoint(0.6, 0.7), CurvePoint(1, 1)]
        let table = CurveLUT.buildOne(points)
        XCTAssertEqual(table.count, CurveLUT.size)
        XCTAssertEqual(table.first!, 0, accuracy: 1e-4)
        XCTAssertEqual(table.last!, 1, accuracy: 1e-4)
        for i in 1..<table.count {
            XCTAssertGreaterThanOrEqual(table[i], table[i - 1], "tone curve folded back at index \(i)")
        }
    }

    func testIdentityCurveProducesIdentityTable() {
        let tables = CurveLUT.build(.identity)
        XCTAssertTrue(CurveLUT.tablesAreIdentity(tables))
    }

    // MARK: - 7. export

    func testJPEGEncodingIsDeterministic() throws {
        let (graph, _) = try makeGraph()
        let edit = try edit("edit-push")
        let pixels = try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 0.25, wantsPixels: true)).display)
        let a = try Exporter.data(pixels, options: ExportOptions(format: .jpeg, quality: 0.9))
        let b = try Exporter.data(pixels, options: ExportOptions(format: .jpeg, quality: 0.9))
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.count, 1000)
    }

    func testTIFF16BitRoundTripsThroughImageIO() throws {
        let (graph, _) = try makeGraph()
        let pixels = try XCTUnwrap(graph.render(EditModel.neutral, options: RenderOptions(scale: 0.125, wantsPixels: true)).display)
        let data = try Exporter.data(pixels, options: ExportOptions(format: .tiff, bitDepth: 16))
        XCTAssertGreaterThan(data.count, 1000)

        // Read it back with ImageIO: proves the CGImage packing (16 bpc + skip-last) is legal.
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("ImageIO could not read back the 16-bit TIFF")
        }
        XCTAssertEqual(img.width, pixels.width)
        XCTAssertEqual(img.height, pixels.height)
    }

    // MARK: - 8. recorded golden images (L2 for the graph)

    /// Compares against `Tests/Golden/render-*.json`, which `make verify` records. Mirrors the CLI
    /// exactly: decode at the golden's scale, render at the remainder, hash the pixels.
    func testRecordedRenderGoldens() throws {
        let dir = Self.repoRoot.appendingPathComponent("Tests/Golden")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("render-") && $0.pathExtension == "json" } ?? []
        if files.isEmpty { throw XCTSkip("no render goldens recorded yet") }

        let url = try fixtureURL()
        let fileHash = try FileDigest.sha256(of: url)

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            struct Rec: Decodable {
                let rawSHA256: String
                let edit: String
                let scale: Double
                let pixelSHA256: String
                let width: Int
                let height: Int
            }
            let rec = try JSONDecoder().decode(Rec.self, from: Data(contentsOf: file))
            if rec.rawSHA256 != fileHash {
                // Recorded against a different fixture (or a re-copied file): nothing to compare.
                continue
            }
            let decodeScale = Float(max(rec.scale, 0.125))
            let img = try RAWDecoder().decode(url, options: DecodeOptions(decoderVersion: nil, scale: decodeScale))
            let graph = try RenderGraph(input: RenderInput(image: img, identity: "golden"))
            let model = try edit(rec.edit)
            let result = try graph.render(model, options: RenderOptions(scale: rec.scale / Double(decodeScale), wantsPixels: true))
            let pixels = try XCTUnwrap(result.display)
            XCTAssertEqual(pixels.width, rec.width, "\(file.lastPathComponent): width")
            XCTAssertEqual(pixels.height, rec.height, "\(file.lastPathComponent): height")
            XCTAssertEqual(pixels.sha256(), rec.pixelSHA256,
                           "\(file.lastPathComponent): rendered pixels changed — Apple's decoder or our graph moved")
        }
    }
}
