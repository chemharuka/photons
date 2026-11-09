import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 314 — **锐化默认 50 / 2.0，且默认值不落盘**.
///
/// Five claims, each a number (brief §3 1–5):
///
///   1. **默认不落盘** — `EditModel()` encodes with no `sharpen` group (and the copy payload with no
///      sharpen leaf). The default is the *resting* value, so it is not material.
///   2. **改了就写** — amount 60 is written; the untouched radius 2.0 is not (per-leaf `differs`).
///   3. **旧文件不被覆盖** — `{"sharpen": {"amount": 0}}` decodes to 0, never to 50.
///   4. **显式 0 仍是恒等** — the stage is absent, so the other three numbers cannot move a pixel.
///   5. **默认真的生效** — default vs explicit 0 on 1 px texture: gradient-energy ratio > 1.05.
///
/// 314 also re-expresses the M1 invariant: it is **the explicit `amount = 0` document** that equals
/// the pipeline identity, not `EditModel.neutral` (which now sharpens). `SharpenStageTests`' identity
/// case is updated to that wording.
final class SharpenDefaultTests: XCTestCase {

    // MARK: - fixtures

    private func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float16(f(x, y))
                let i = (y * w + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// 1 px texture at two scales: a checker `cell` px per square, 0.06 / 0.50.
    private func checker(cell: Int, width: Int = 600, height: Int = 400) -> LinearImage {
        image(width, height) { x, y in
            ((x / cell) + (y / cell)) % 2 == 0 ? 0.06 : 0.50
        }
    }

    /// A noisy flat field: the frame a radius/detail/masking can *only* move through the pass.
    private func noisy(width: Int = 400, height: Int = 300) -> LinearImage {
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 10_000) / 10_000.0
        }
        return image(width, height) { x, _ in
            x < width / 2 ? 0.35 + (next() - 0.5) * 0.04 : (x < width * 3 / 4 ? 0.06 : 0.50)
        }
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        scale: Double = 1) throws -> DisplayImage {
        let options = RenderOptions(scale: scale, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func codes(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            out[i] = 255 * (0.2126 * Double(image.rgba[i * 4])
                            + 0.7152 * Double(image.rgba[i * 4 + 1])
                            + 0.0722 * Double(image.rgba[i * 4 + 2]))
        }
        return out
    }

    private func text(_ edit: EditModel) throws -> String {
        String(decoding: try JSONEncoder().encode(edit), as: UTF8.self)
    }

    private func object(_ edit: EditModel) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit))
                        as? [String: Any])
    }

    // MARK: - 1. the resting value is not material

    func testDefaultDocumentWritesNoSharpenKey() throws {
        let json = try object(EditModel())
        XCTAssertNil(json["sharpen"], "the resting 50/2.0/25/0 must not be written")

        // The copy payload compares every leaf against its resting value too — a default document
        // carries no sharpen leaf at all (`EditSnapshot.capture`).
        let payload = EditSnapshot.capture(EditModel())
        if let effects = payload.effects {
            XCTAssertNil(effects.sharpenAmount)
            XCTAssertNil(effects.sharpenRadius)
            XCTAssertNil(effects.sharpenDetail)
            XCTAssertNil(effects.sharpenMasking)
        }

        let jsonText = try text(EditModel())
        for key in ["sharpenAmount", "sharpenRadius", "sharpenDetail", "sharpenMasking"] {
            XCTAssertFalse(jsonText.contains(key), "\(key) escaped into the document")
        }
        print("314 · 默认不落盘: \(jsonText.count) bytes, contains \"sharpen\" = "
              + "\(jsonText.contains("\"sharpen\""))")
    }

    // MARK: - 2. a moved amount is written, an untouched radius is not

    func testMovedAmountIsWrittenAndUntouchedRadiusIsOmitted() throws {
        var edit = EditModel()
        edit.sharpen.amount = 60

        let payload = try XCTUnwrap(EditSnapshot.capture(edit).effects)
        XCTAssertEqual(payload.sharpenAmount, 60)
        XCTAssertNil(payload.sharpenRadius, "radius 2.0 was never touched and must stay out")
        XCTAssertNil(payload.sharpenDetail)
        XCTAssertNil(payload.sharpenMasking)

        // The document writes the whole group when it is off-resting (the group is the unit of
        // presence there), so the same edit's file carries amount 60 **and** the radius it inherits.
        let group = try XCTUnwrap(try object(edit)["sharpen"] as? [String: Any])
        XCTAssertEqual(group["amount"] as? Double, 60)
        XCTAssertEqual(group["radius"] as? Double, 2.0)
        print("314 · amount 60: snapshot leaves = "
              + "\(payload.fieldCount) (amount \(payload.sharpenAmount ?? -1), radius "
              + "\(payload.sharpenRadius.map { "\($0)" } ?? "nil"))")
    }

    // MARK: - 3. a legacy explicit zero is not overwritten

    func testLegacyExplicitZeroDecodesToZeroNotToTheDefault() throws {
        let json = """
        {"schemaVersion": 14, "sharpen": {"amount": 0}}
        """
        let doc = try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))
        XCTAssertEqual(doc.sharpen.amount, 0, "an explicit 0 must survive the new default")
        XCTAssertEqual(doc.sharpen.radius, 2.0, "a missing radius reads the resting value")
        XCTAssertFalse(doc.hasSharpen, "explicit 0 is not a stage")

        // …and it re-encodes as the same explicit 0 — not as a vanished group, not as 50.
        let out = try object(doc)
        let group = try XCTUnwrap(out["sharpen"] as? [String: Any])
        XCTAssertEqual(group["amount"] as? Double, 0)
        print("314 · 旧 JSON amount 0 → \(doc.sharpen.amount) / radius \(doc.sharpen.radius)"
              + " · hasSharpen \(doc.hasSharpen)")
    }

    // MARK: - 4. explicit zero is still the identity

    /// The M1 invariant, re-expressed (314 §2.1): the **explicit `amount = 0`** document equals the
    /// pre-185 frame — the stage is not encoded, so the radius/detail/masking it still stores cannot
    /// move a pixel. `EditModel.neutral` is *not* that document any more: it now carries 50/2.0.
    func testExplicitZeroIsStillTheIdentity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: noisy(), identity: "sharpen-default"))

        var restingShape = EditModel.neutral
        restingShape.sharpen = SharpenGroup(amount: 0)
        var loudShape = EditModel.neutral
        loudShape.sharpen = SharpenGroup(amount: 0, radius: 3.0, detail: 100, masking: 100)

        let a = try render(graph, restingShape)
        let b = try render(graph, loudShape)
        var worst = 0.0
        for i in 0..<a.rgba.count {
            worst = max(worst, abs(Double(a.rgba[i]) - Double(b.rgba[i])))
        }
        print("314 · 恒等 max|Δ| = \(String(format: "%.9f", worst)) "
              + "(explicit 0 vs explicit 0 with radius 3 / detail 100 / masking 100)")
        XCTAssertLessThan(worst, 0.002, "explicit 0 must be the identity, shape numbers and all")

        XCTAssertNil(RenderKeyChain.links(
            identity: "sharpen-default", sourceSize: ImageSize(width: 400, height: 300),
            canvas: ImageSize(width: 400, height: 300), content: ImageSize(width: 400, height: 300),
            edit: loudShape, display: DisplayOptions(headroom: 1)).sharpen,
            "explicit 0 grew an S3.10 link")

        // The default document is the *other* case: it has the stage, it has the link, it is not
        // the identity. This is the companion the spec asks for — same assertion, opposite sign.
        let defaultRender = try render(graph, EditModel.neutral)
        XCTAssertNotEqual(defaultRender.sha256(), a.sha256(),
                          "default 50 must not render the identity frame")
        XCTAssertNotNil(RenderKeyChain.links(
            identity: "sharpen-default", sourceSize: ImageSize(width: 400, height: 300),
            canvas: ImageSize(width: 400, height: 300), content: ImageSize(width: 400, height: 300),
            edit: EditModel.neutral, display: DisplayOptions(headroom: 1)).sharpen)
    }

    // MARK: - 5. the default is visible

    /// Gradient energy (∂x² + ∂y², in display codes) on a 1 px checkerboard: the default document's
    /// high-frequency energy must exceed the explicit-0 document's by more than 5 % (§3.5). A 4 px
    /// checker is printed alongside, so the number's dependence on frequency is on the record.
    func testDefaultSharpenRaisesOnePixelHighFrequencyEnergy() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        func energy(_ image: DisplayImage) -> Double {
            let v = codes(image)
            let w = image.width
            var sum = 0.0
            for y in 0..<image.height {
                for x in 0..<w {
                    let i = y * w + x
                    if x + 1 < w {
                        let dx = v[i + 1] - v[i]
                        sum += dx * dx
                    }
                    if y + 1 < image.height {
                        let dy = v[i + w] - v[i]
                        sum += dy * dy
                    }
                }
            }
            return sum / Double(w * image.height)
        }

        for cell in [1, 4] {
            let graph = try RenderGraph(input: RenderInput(image: checker(cell: cell),
                                                          identity: "sharpen-default-freq-\(cell)"))
            var zero = EditModel.neutral
            zero.sharpen = SharpenGroup(amount: 0)
            let defaultE = energy(try render(graph, EditModel.neutral))
            let zeroE = energy(try render(graph, zero))
            let ratio = defaultE / zeroE
            print(String(format: "314 · %d px 高频能量: 默认 %.3f · 显式 0 %.3f · 比 %.4f",
                         cell, defaultE, zeroE, ratio))
            if cell == 1 {
                XCTAssertGreaterThan(ratio, 1.05,
                                     "the default 50 must raise 1 px gradient energy by > 5 %")
            }
        }
    }
}

/// 314 §2.2 — **the L3 goldens' shock, measured**: the three recorded frames are stale because the
/// fixture documents carry no `sharpen` key and now read the 50/2.0 resting value. This class does
/// not re-record anything; it renders each golden twice (default · explicit 0) and prints where the
/// pixels moved, so the main line can decide on re-recording with the numbers in hand.
///
/// The claim it asserts: the change is **high-frequency**. A 15×15 box mean of the |Δ| field — the
/// low-frequency component — stays under 0.5 % of the 0…255 display range on all three documents.
final class SharpenGoldenImpactTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Golden: Decodable {
        let rawSHA256: String, edit: String, scale: Double
        let pixelSHA256: String, width: Int, height: Int
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

    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<(image.width * image.height) {
            out[i] = 255 * (0.2126 * Double(image.rgba[i * 4])
                            + 0.7152 * Double(image.rgba[i * 4 + 1])
                            + 0.0722 * Double(image.rgba[i * 4 + 2]))
        }
        return out
    }

    /// Separable 15×15 box mean, edges clamped — the "low-frequency block" of §3.6.
    private func boxMean(_ v: [Double], width w: Int, height h: Int, radius r: Int = 7) -> [Double] {
        var tmp = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0; var n = 0
                for dx in -r...r {
                    let xx = min(max(x + dx, 0), w - 1)
                    sum += v[y * w + xx]; n += 1
                }
                tmp[y * w + x] = sum / Double(n)
            }
        }
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0; var n = 0
                for dy in -r...r {
                    let yy = min(max(y + dy, 0), h - 1)
                    sum += tmp[yy * w + x]; n += 1
                }
                out[y * w + x] = sum / Double(n)
            }
        }
        return out
    }

    func testGoldensMoveOnlyInHighFrequency() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let raw = try fixtureURL()

        for name in ["render-edit-neutral-s0.25", "render-edit-push-s0.25",
                     "render-edit-crop-rot-s0.25"] {
            let url = Self.repoRoot.appendingPathComponent("Tests/Golden/\(name).json")
            let golden: Golden
            do {
                golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
            } catch {
                throw XCTSkip("no golden at \(url.path)")
            }
            guard try FileDigest.sha256(of: raw) == golden.rawSHA256 else {
                throw XCTSkip("\(name) was recorded against a different RAW fixture")
            }
            let edit = try EditModel.load(from: Self.repoRoot
                .appendingPathComponent("Tests/Fixtures/\(golden.edit).json"))
            let decodeScale = Float(max(golden.scale, 0.125))
            let outcome = try RAWDecoder().decodeDetailed(raw, options: DecodeOptions(
                decoderVersion: nil, scale: decodeScale,
                whiteBalance: edit.light.whiteBalance))
            let graph = try RenderGraph(input: RenderInput(image: outcome.image,
                                                           identity: "sharpen-golden-impact",
                                                           sourceURL: raw,
                                                           whiteBalance: edit.light.whiteBalance))

            var zero = edit
            zero.sharpen = SharpenGroup(amount: 0)

            func render(_ e: EditModel) throws -> DisplayImage {
                let options = RenderOptions(scale: golden.scale / Double(decodeScale),
                                            display: DisplayOptions(headroom: 1),
                                            useCache: false, wantsPixels: true)
                let result = try graph.render(e, options: options)
                if let t = result.output { graph.recycle(output: t) }
                return try XCTUnwrap(result.display)
            }

            let sharp = try render(edit)
            let flat = try render(zero)
            XCTAssertEqual(sharp.width, flat.width)
            XCTAssertEqual(sharp.height, flat.height)
            XCTAssertEqual(flat.width, golden.width, "\(name): width moved")

            let a = luma(sharp), b = luma(flat)
            var sum = 0.0, worst = 0.0
            for i in 0..<a.count {
                let d = abs(a[i] - b[i])
                sum += d
                worst = max(worst, d)
            }
            let mean = sum / Double(a.count)

            // 314 §3.6's split: DC = a 15×15 box mean of each frame (the low-frequency block), AC =
            // what the box removed (the high-frequency detail). "The change is high-frequency" means
            // the DC fields agree to well under 0.5 % of the 0…255 range while the AC field grows.
            let loA = boxMean(a, width: flat.width, height: flat.height)
            let loB = boxMean(b, width: flat.width, height: flat.height)
            var maxDC = 0.0, sumDC = 0.0, acA = 0.0, acB = 0.0
            for i in 0..<a.count {
                let dc = abs(loA[i] - loB[i])
                maxDC = max(maxDC, dc); sumDC += dc
                acA += abs(a[i] - loA[i]); acB += abs(b[i] - loB[i])
            }
            let n = Double(a.count)
            let p90 = loA.indices.map { abs(loA[$0] - loB[$0]) }.sorted()[Int(n * 0.9)]

            print(String(format: "314 · 金值 %@ (%d×%d) 默认 %@ · 显式0 %@ · 金值 %@",
                         name, flat.width, flat.height,
                         String(sharp.sha256().prefix(12)), String(flat.sha256().prefix(12)),
                         String(golden.pixelSHA256.prefix(12))))
            print(String(format: "314 ·   |Δ| 平均 %.3f 码 / 最大 %.0f 码 · 低频块(15×15) |ΔDC| 平均 %.4f%% "
                         + "· p90 %.4f%% · 最大 %.4f%% · 高频 AC %.3f→%.3f 码",
                         mean, worst, 100 * (sumDC / n) / 255, 100 * p90 / 255, 100 * maxDC / 255,
                         acB / n, acA / n))
            print("314 ·   默认 == 金值 ? \(sharp.sha256() == golden.pixelSHA256) "
                  + "· 显式0 == 金值 ? \(flat.sha256() == golden.pixelSHA256)")

            // The recorded golden is the pre-314 identity frame: the explicit-0 document must still
            // reproduce it byte for byte (that is also §3.4's reference, at 0.000|Δ|).
            XCTAssertEqual(flat.sha256(), golden.pixelSHA256,
                           "\(name): explicit 0 is no longer the recorded frame")
            XCTAssertNotEqual(sharp.sha256(), golden.pixelSHA256,
                              "\(name): the default 50 changed nothing — the golden would be current")
            XCTAssertLessThan((sumDC / n) / 255, 0.005,
                              "\(name): the mean low-frequency block moved "
                              + "\((sumDC / n) / 255 * 100) % — not a high-frequency change")
            XCTAssertGreaterThan(acA, acB,
                                 "\(name): the high-frequency energy did not rise")
        }
    }
}
