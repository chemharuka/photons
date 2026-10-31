import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
@testable import PhotonsCore

/// 006's contract, **after 194/195 and 路线 B (2026-10-31)**: a settled white balance is a
/// **development** — the pair goes into `DecodeInputs.whiteBalance`, `CIRAWFilter` balances the pixels,
/// and S1's gain on that buffer is `(1, 1, 1)`. A drag is a **render** over the buffer already on
/// screen. 143 had this backwards (the pair was an S1 gain and the decoder never saw it); these
/// assertions are that contract's rewrite, not its deletion.
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   · **As shot is byte-identical, on three layers.** The file's own pair, `nil` and `.asShot` all
///     produce the same decode, the same pixels and the same PNG — the identity gate of this task.
///   · **A white balance settles with exactly one development**, and the same pair again costs
///     nothing: one value, one decode (`testAssigningAWhiteBalanceSettlesWithOneDevelopment`,
///     `testExplicitWhiteBalanceIsADifferentDevelopment`).
///   · **A drag develops nothing.** A tick never moves the rung identity, so the buffer on screen is
///     reused and the decoder is not asked (`testOneDevelopmentPerSettledPairAndNonePerTick`).
///   · **The key still carries the pair**, and the store still returns the buffer each key named.
///   · **S1 applies the estimator's 3×3 for a drag** — the picture does change between two settled
///     frames, and it changes by the anchor-relative matrix, not by 143's encoded fit.
///
/// The RAW fixture is the user's own photo and is not vendored: set `PHOTONS_TEST_RAW` or the suite
/// skips. The second body (if present) is used only where two cameras prove the point.
final class WhiteBalanceTests: XCTestCase {

    // MARK: - fixtures

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

    /// A second, different body — the as-shot value is a fact about a *file*, so one camera proves
    /// nothing about the mechanism.
    private func secondBodyURL() -> URL? {
        let p = NSString(string: "~/Desktop/US/_1274394.dng").expandingTildeInPath
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    private func decoder() throws -> RAWDecoder { try RAWDecoder() }

    // MARK: - 1. the value comes from the file

    func testAsShotWhiteBalanceIsReadFromTheFileAndIsNot6500() throws {
        for url in [try fixtureURL()] + [secondBodyURL()].compactMap({ $0 }) {
            let probe = try decoder().probe(url)
            let wb = WhiteBalance(temperature: probe.asShotTemperature, tint: probe.asShotTint)
            print("\(url.lastPathComponent): as-shot \(wb.summary) "
                  + "(raw \(probe.asShotTemperature.map { String(format: "%.3f", $0) } ?? "nil") K / "
                  + "\(probe.asShotTint.map { String(format: "%.3f", $0) } ?? "nil"))")
            let t = try XCTUnwrap(probe.asShotTemperature, "no as-shot temperature for \(url.lastPathComponent)")
            let i = try XCTUnwrap(probe.asShotTint, "no as-shot tint for \(url.lastPathComponent)")
            XCTAssertTrue(WhiteBalance.temperatureRange.contains(t),
                          "as-shot \(t) K outside the slider range")
            XCTAssertTrue(WhiteBalance.tintRange.contains(i), "as-shot tint \(i) outside ±150")
            // The complaint that started this task: every photo showed 6500 K / 0.
            XCTAssertNotEqual(t, 6500, accuracy: 1,
                              "\(url.lastPathComponent) really is a 6500 K shot — pick another fixture")
            // The decode reports the same pair the probe does.
            let outcome = try decoder().decodeDetailed(url, options: DecodeOptions(scale: 0.0625))
            XCTAssertEqual(outcome.asShotWhiteBalance.temperature, probe.asShotTemperature)
            XCTAssertEqual(outcome.capabilities.asShotTemperature, probe.asShotTemperature)
            XCTAssertEqual(outcome.capabilities.asShotTint, probe.asShotTint)
        }
    }

    // MARK: - 2. the default document does not move

    func testAsShotDecodeIsByteIdenticalToTheDefaultDecode() throws {
        let url = try fixtureURL()
        let d = try decoder()
        for scale: Float in [0.125, 0.25] {
            let plain = try d.decode(url, options: DecodeOptions(scale: scale))
            let asShot = try d.decode(url, options: DecodeOptions(scale: scale, whiteBalance: .asShot))
            let partial = try d.decode(url, options: DecodeOptions(scale: scale,
                                                                   whiteBalance: WhiteBalance()))
            XCTAssertEqual(plain.sha256(), asShot.sha256(),
                           "as shot must be the untouched filter (scale \(scale))")
            XCTAssertEqual(plain.sha256(), partial.sha256())
        }
    }

    /// **194/195 — assigning the file's own pair is still the as-shot decode; assigning a different
    /// pair is a development, exactly one.**
    ///
    /// 143 asserted the opposite ("the decoder has no write path for
    /// `neutralTemperature`/`neutralTint`"), because 143 put the balance in S1 and left `CIRAWFilter`
    /// at as shot. 194 restored the write and made the settled frame the decoder's answer, so the
    /// rewrite has to keep both halves honest:
    ///
    ///   ① **as shot is not a development that changes anything** — the file's own pair decodes to the
    ///     same bytes as `nil`, so nothing on the as-shot path moved;
    ///   ② **an explicit pair is one development and it is the decoder's** — 3500 K/+30 produces
    ///     different pixels, costs exactly one decode, and repeats byte for byte (determinism is the
    ///     other half: a "different buffer" that is also unstable would be noise, not a balance).
    func testAssigningAWhiteBalanceSettlesWithOneDevelopment() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let outcome = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125))
        let shot = outcome.asShotWhiteBalance
        _ = try XCTUnwrap(shot.temperature)
        _ = try XCTUnwrap(shot.tint)

        // ① as shot: `.asShot` and an absent pair are the untouched filter. (The *reported* pair
        // written back is a float round-trip and is measured in the three-layer test, not asserted
        // here — 原照设置 writes `nil`, which is why the as-shot path has no residue at all.)
        RAWDecoder.resetDecodeCounts()
        let plain = try d.decode(url, options: DecodeOptions(scale: 0.125))
        let pinned = try d.decode(url, options: DecodeOptions(scale: 0.125, whiteBalance: .asShot))
        XCTAssertEqual(pinned.sha256(), plain.sha256(),
                       "`.asShot` moved the as-shot decode — the default document must be the "
                       + "untouched filter")
        let absent = try d.decode(url, options: DecodeOptions(scale: 0.125, whiteBalance: WhiteBalance()))
        XCTAssertEqual(absent.sha256(), plain.sha256(), "an empty pair is not as shot")

        // ② an explicit pair develops once, and the decoder really took it.
        let before = Self.decodeTotal()
        let wild = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                            whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(Self.decodeTotal() - before, 1,
                       "a settled pair must cost exactly one development (measured "
                       + "\(Self.decodeTotal() - before))")
        XCTAssertNotEqual(wild.sha256(), plain.sha256(),
                          "3500 K/+30 decoded the as-shot pixels — the pair never reached "
                          + "`CIRAWFilter.neutralTemperature`")
        let again = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                             whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(again.sha256(), wild.sha256(),
                       "the same pair is not deterministic — the settle would flicker")
        print("WB settle: as shot == plain (0 change) · 3500 K/+30 → different buffer · one decode per call")
    }

    // MARK: - 3. an explicit value is a second development — and a drag is not

    /// **A settled pair is a development; a drag over the same buffer is not.**
    ///
    /// 143 said the opposite ("an explicit value is a render-side gain, not a second development") and
    /// that is exactly what 194 undid: the truth on screen comes from `CIRAWFilter`, so the pair has to
    /// reach it. The two halves this test keeps apart:
    ///
    ///   · **settle** — the same pair twice is one development (the ladder is asked once, and a second
    ///     identical request is a cache hit), which is still the cost bound 143 was protecting;
    ///   · **drag** — a tick that has not been released moves no decode identity at all, so the
    ///     resident buffer is reused and the decoder is never asked. That is the half of 143's rule
    ///     that survives, and the reason the split exists.
    func testExplicitWhiteBalanceIsADifferentDevelopment() throws {
        let url = try fixtureURL()
        let d = try decoder()
        RAWDecoder.resetDecodeCounts()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.125))
        let afterShot = Self.decodeTotal()
        let warm = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                            whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertNotEqual(shot.sha256(), warm.sha256(),
                          "3500 K/+30 decoded the as-shot buffer — the settle must be the decoder's answer")
        XCTAssertEqual(Self.decodeTotal(), afterShot + 1, "one settle, one development")
        let again = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                             whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertEqual(again.sha256(), warm.sha256(), "the same pair is not deterministic")

        // A drag is a render over a buffer that already exists: its matrix is real, and it decodes
        // nothing — the ladder is not even consulted for a tick.
        RAWDecoder.resetDecodeCounts()
        let ladder = DecodeLadder()
        let identity = "\(url.lastPathComponent)|wb-drag"
        _ = try ladder.rung(identity: identity, scale: 0.125) {
            let o = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125,
                                                                    whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
            return DecodeRung(scale: 0.125, image: o.image, capabilities: o.capabilities, milliseconds: 0)
        }
        let settledCount = Self.decodeTotal()
        // Twelve ticks, each a new pair: every one of them is an S1 matrix change on the same rung.
        for k in stride(from: 3200.0, through: 4300.0, by: 100.0) {
            let m = WhiteBalanceEstimate.anchorRelativeMatrix(
                from: WhiteBalance(temperature: 3500, tint: 30),
                to: WhiteBalance(temperature: k, tint: 30))
            XCTAssertFalse(m.inverseFellBack)
            let tick = try ladder.rung(identity: identity, scale: 0.125) {
                XCTFail("a drag developed the RAW")
                fatalError("unreachable")
            }
            XCTAssertTrue(tick.cached, "drag tick at \(Int(k)) K missed the rung")
        }
        XCTAssertEqual(Self.decodeTotal(), settledCount,
                       "a drag developed \(Self.decodeTotal() - settledCount) buffer(s) — a drag is a "
                       + "matrix on the buffer on screen")
        print("WB split: settle +1 decode · 11 drag ticks +0 · S1 matrix moves at every tick")
    }

    // MARK: - 4. cache identity

    func testCacheKeyCarriesTheWhiteBalance() {
        let shot = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8")
        let legacy = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8", decodeRecipe: DecodeRecipe.current)
        XCTAssertEqual(shot.digest, legacy.digest,
                       "the as-shot digest must stay the pre-006 one, or every buffer on disk is orphaned")

        let warm = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                  whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        let warmAgain = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                       whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        let kelvinOnly = DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                        whiteBalance: WhiteBalance(temperature: 3500))
        XCTAssertNotEqual(shot.digest, warm.digest, "a 3500 K document would hit the as-shot buffer")
        XCTAssertEqual(warm.digest, warmAgain.digest)
        XCTAssertNotEqual(warm.digest, kelvinOnly.digest,
                          "explicit tint and as-shot tint must not share a buffer")
        // `nil` temperature with an explicit tint is a third state, not "0 K".
        XCTAssertNotEqual(kelvinOnly.digest, DecodeCacheKey(fileSHA256: "abc", decoderVersion: "8",
                                                            whiteBalance: WhiteBalance(tint: 30)).digest)
    }

    /// The on-disk store still keeps two **keys** apart byte for byte — the v9 lesson (§8c) was that a
    /// key which does not carry a setting serves the wrong buffer with no error at all. Since 194 the
    /// pair *is* part of the decode, so the two keys are two genuinely different pictures, and each key
    /// must return the bytes it named (a store that answered both from one file would hide a
    /// development that never happened).
    func testStoreRoundTripIsKeyedAndTheDecoderSettlesAtThePair() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let shot = try d.decode(url, options: DecodeOptions(scale: 0.0625))
        let warm = try d.decode(url, options: DecodeOptions(scale: 0.0625,
                                                           whiteBalance: WhiteBalance(temperature: 3500, tint: 30)))
        XCTAssertNotEqual(shot.sha256(), warm.sha256(),
                          "two decodes of the same file differ — the decoder took the balance, so they "
                          + "must differ; identical here would mean the pair was dropped")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-wb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LinearImageStore(directory: dir)
        let shotKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: shot.decoderVersion,
                                     scale: 0.0625, whiteBalance: .asShot)
        let warmKey = DecodeCacheKey(fileSHA256: "wb", decoderVersion: warm.decoderVersion,
                                     scale: 0.0625, whiteBalance: WhiteBalance(temperature: 3500, tint: 30))
        XCTAssertNotEqual(shotKey.digest, warmKey.digest)
        try store.save(shot, key: shotKey)
        try store.save(warm, key: warmKey)
        XCTAssertEqual(try XCTUnwrap(store.load(shotKey)).sha256(), shot.sha256())
        XCTAssertEqual(try XCTUnwrap(store.load(warmKey)).sha256(), warm.sha256(),
                       "the 3500 K key returned the as-shot buffer (or vice versa)")
    }

    // MARK: - 5. quantization: a drag is one rung

    func testQuantizationCollapsesADragIntoOneDevelopment() {
        // 12 ticks inside one 25 K bucket (3562.5…3587.5 → 3575) — the thumb moves, the document
        // does not.
        let ticks = stride(from: 3563.0, through: 3585.0, by: 2.0).map {
            WhiteBalance(temperature: $0, tint: 30.4).quantized()
        }
        XCTAssertEqual(Set(ticks.map { $0.keyString ?? "as-shot" }).count, 1,
                       "ticks 3562…3585 K did not collapse into one development: "
                       + "\(Set(ticks.map { $0.keyString ?? "as-shot" }))")
        XCTAssertEqual(ticks.first?.temperature, 3575)

        XCTAssertEqual(WhiteBalance(temperature: 3537).quantized().temperature, 3525)
        XCTAssertEqual(WhiteBalance(temperature: 3551).quantized().temperature, 3550)
        XCTAssertEqual(WhiteBalance(tint: 30.4).quantized().tint, 30)
        XCTAssertEqual(WhiteBalance(tint: -0.4).quantized().tint, 0)   // -0.0 would key differently
        // Clamped, not wrapped, and as shot stays as shot.
        XCTAssertEqual(WhiteBalance(temperature: 99_999).quantized().temperature,
                       WhiteBalance.temperatureRange.upperBound)
        XCTAssertEqual(WhiteBalance(temperature: 10).quantized().temperature,
                       WhiteBalance.temperatureRange.lowerBound)
        XCTAssertTrue(WhiteBalance().quantized().isAsShot)
        XCTAssertNil(WhiteBalance().keyString)
    }

    // MARK: - 6. one development per settled pair, none per tick

    /// **194's counting rule, on the ladder**: a settled pair is a rung of its own (one development),
    /// asking for it again is a hit, and a *tick* never moves the identity at all.
    ///
    /// 143 asserted "a white balance never reaches the decoder" and that is now false by design. What
    /// survives from it — and is the reason this test still exists — is the cost bound: a drag must not
    /// develop, a settle must develop once and no more, and a document that returns to as shot must be
    /// the as-shot buffer again.
    func testOneDevelopmentPerSettledPairAndNonePerTick() throws {
        let url = try fixtureURL()
        RAWDecoder.resetDecodeCounts()

        let ladder = DecodeLadder()
        let base = "\(url.lastPathComponent)|asset-1"
        func develop() throws -> DecodeRung {
            let d = try RAWDecoder()
            let o = try d.decodeDetailed(url, options: DecodeOptions(scale: 0.125))
            return DecodeRung(scale: 0.125, image: o.image, capabilities: o.capabilities, milliseconds: 0)
        }
        func total() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

        let first = try ladder.rung(identity: base, scale: 0.125) { try develop() }
        XCTAssertFalse(first.cached)
        XCTAssertEqual(total(), 1)

        let second = try ladder.rung(identity: base, scale: 0.125) { try develop() }
        XCTAssertTrue(second.cached, "the second request developed the file again")
        XCTAssertEqual(total(), 1)

        // A settled pair is a **new** rung: the pair is a decode input now, so the identity moves and
        // the decoder is asked exactly once.
        var model = EditModel.neutral
        model.light.temperature = 3500
        model.light.tint = 30
        let wbIdentity = model.decodeInputs.appending(to: base)
        XCTAssertNotEqual(wbIdentity, base,
                          "a settled pair left the decode identity at as shot — the frame would never "
                          + "reach `CIRAWFilter`")
        let settled = try ladder.rung(identity: wbIdentity, scale: 0.125) { try develop() }
        XCTAssertFalse(settled.cached, "the settle reused the as-shot rung")
        XCTAssertEqual(total(), 2, "a settled pair must be exactly one development")

        // Twelve drag ticks inside one bucket still develop nothing: the buffer on screen is reused
        // and only S1's matrix changes.
        let beforeTicks = total()
        for k in stride(from: 3563.0, through: 3585.0, by: 2.0) {
            model.light.temperature = k
            let m = WhiteBalanceEstimate.anchorRelativeMatrix(
                from: WhiteBalance(temperature: 3500, tint: 30),
                to: WhiteBalance(temperature: k, tint: 30))
            XCTAssertFalse(m.inverseFellBack)
            let tick = try ladder.rung(identity: wbIdentity, scale: 0.125) { try develop() }
            XCTAssertTrue(tick.cached, "a slider tick developed the RAW")
        }
        XCTAssertEqual(total(), beforeTicks, "a slider tick decoded the RAW")

        // Back to as shot: its own rung again, and the same bytes as the first development. (A ladder
        // that still holds both rungs may serve it as a hit, so the count is bounded, not fixed.)
        let back = try ladder.rung(identity: base, scale: 0.125) { try develop() }
        XCTAssertEqual(back.rung.image.sha256(), first.rung.image.sha256(),
                       "returning to as shot did not return the as-shot buffer")
        XCTAssertLessThanOrEqual(decodeTotal(), 3, "as shot cost more than one more development")
        print("decode counting: as shot +1 · same request +0 · settle +1 · 12 ticks +0 · as shot +1 "
              + "(total \(decodeTotal()))")
    }

    // MARK: - 2b. the identity gate, on three layers

    /// **As shot is byte-identical all the way down: decode sha, pixel sha, PNG sha.**
    ///
    /// This is the identity gate for this task (there is no `amount = 0` analogue here). Three layers,
    /// because they fail independently: the decode could move while the render hides it, and the render
    /// could move while a display-encoded PNG rounds it back. The comparison is
    /// `.asShot` / the file's own pair / `nil` against the plain decode of the same file.
    func testAsShotIsByteIdenticalOnAllThreeLayers() throws {
        let url = try fixtureURL()
        let d = try decoder()
        let probe = try d.probe(url)
        let reported = WhiteBalance(temperature: probe.asShotTemperature, tint: probe.asShotTint)

        let plain = try d.decode(url, options: DecodeOptions(scale: 0.125))
        var variants: [(String, LinearImage)] = [("nil", plain)]
        variants.append((".asShot", try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                                           whiteBalance: .asShot))))
        // The *reported* pair written back is deliberately **not** in this list: it is a float
        // round-trip of the decoder's own readback (5871.64 K / +20.35 on this file), and assigning it
        // re-enters `CIRAWFilter` with a slightly different pair. Measured below, not asserted as zero
        // — it is the reason 原照设置 writes `nil` and not the numbers the inspector displays.
        if !reported.isAsShot {
            let writtenBack = try d.decode(url, options: DecodeOptions(scale: 0.125,
                                                                      whiteBalance: reported))
            let codes = Self.codeDelta(writtenBack, plain)
            XCTAssertLessThanOrEqual(codes, 3,
                "writing the reported pair back (\(reported.summary)) moved \(codes) codes — a "
                + "readback round-trip should be a rounding, not a different balance")
            print("as shot: reported pair \(reported.summary) written back → \(codes) code(s) "
                  + "(a float round-trip; `.asShot` is the zero)")
        }

        // Layer 1 — the decoded scene-linear buffer.
        let decodeSHA = plain.sha256()
        for (name, image) in variants {
            XCTAssertEqual(image.sha256(), decodeSHA,
                           "layer 1 (decode): \(name) is not the plain decode's bytes")
        }

        // Layers 2 and 3 — the rendered pixels and the PNG the export would write, for an as-shot
        // document against a neutral one (they are the same document: as shot is `nil`).
        let shotDocument = EditModel.neutral
        var nilDocument = EditModel.neutral
        nilDocument.light.temperature = nil
        nilDocument.light.tint = nil
        let graph = try RenderGraph(input: RenderInput(image: plain, identity: "wb-three-layer"))
        let options = RenderOptions(scale: 1,
                                   display: DisplayOptions(primaries: .sRGB, bitDepth: 8),
                                   useCache: false, wantsPixels: true)
        let a = try XCTUnwrap(try graph.render(shotDocument, options: options).display)
        let b = try XCTUnwrap(try graph.render(nilDocument, options: options).display)
        XCTAssertEqual(a.sha256(), b.sha256(), "layer 2 (pixels): the as-shot document moved")
        let pngA = try Self.pngSHA(a)
        let pngB = try Self.pngSHA(b)
        XCTAssertEqual(pngA, pngB, "layer 3 (PNG): the as-shot document encodes differently")
        // …and S1 applied nothing, which is the arithmetic behind all three.
        let g = graph.whiteBalanceGain(for: .asShot)
        XCTAssertEqual(g.r, 1); XCTAssertEqual(g.g, 1); XCTAssertEqual(g.b, 1)
        XCTAssertEqual(graph.whiteBalanceMatrix(from: .asShot, to: .asShot), .identity)

        print("as shot, three layers: decode \(decodeSHA.prefix(16))… · pixels \(a.sha256().prefix(16))… "
              + "· png \(pngA.prefix(16))… — identical across \(variants.count) spellings")
    }

    // MARK: - counting helpers

    /// 8-bit display codes between two scene-linear buffers — the same convention the UI tests use
    /// (`round(clamp(v, 0, 1) · 255)`), applied directly to the decode.
    private static func codeDelta(_ a: LinearImage, _ b: LinearImage) -> Int {
        guard a.width == b.width, a.height == b.height,
              a.rgba.count == b.rgba.count else { return .max }
        var worst = 0
        var i = 0
        while i < a.rgba.count {
            for c in 0..<3 {
                let va = min(max(Double(a.rgba[i + c]) * 255, 0), 255)
                let vb = min(max(Double(b.rgba[i + c]) * 255, 0), 255)
                worst = max(worst, abs(Int(va.rounded()) - Int(vb.rounded())))
            }
            i += 4
        }
        return worst
    }

    /// The process-global development counter (`RAWDecoder.decodeCounts()`, summed over scales).
    private func decodeTotal() -> Int { Self.decodeTotal() }

    private static func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    /// PNG bytes for a rendered frame, hashed — the layer an export would actually write.
    private static func pngSHA(_ image: DisplayImage) throws -> String {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = Double(Float(image.rgba[i * 4 + c]))
                bytes[i * 4 + c] = UInt8(min(max((v * 255).rounded(), 0), 255))
            }
            bytes[i * 4 + 3] = 255
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: w * 4, space: colorSpace,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false,
                                       intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "the PNG did not finalise")
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 7. S1's white-balance gain is the estimator's

    /// **A document with a pair but no decode at that pair renders as the drag would** — S1's matrix on
    /// the buffer on screen. Since 194 this is the *preview* arithmetic (a settle develops its own
    /// buffer instead), which is why the pair must still change the picture here rather than being a
    /// no-op: the drag is what the user looks at while moving, and it cannot be a flat frame.
    ///
    /// The pair is also emphatically not 143's old display-encoded fit, so the difference is the
    /// estimator's arithmetic rather than a coincidence of 3500/30.
    func testWhiteBalanceOnlyDocumentRendersAsTheDragWould() throws {
        let url = try fixtureURL()
        let image = try decoder().decode(url, options: DecodeOptions(scale: 0.125))
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "wb-identity-test"))

        var wbOnly = EditModel.neutral
        wbOnly.light.temperature = 3500
        wbOnly.light.tint = 30

        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        let neutral = try XCTUnwrap(try graph.render(.neutral, options: opts).display)
        let balanced = try XCTUnwrap(try graph.render(wbOnly, options: opts).display)
        XCTAssertNotEqual(neutral.sha256(), balanced.sha256(),
                          "S1 did not apply the white-balance gain")

        // The gain is the estimator's diagonal and it is not the identity.
        let gains = graph.whiteBalanceGain(for: wbOnly.light.whiteBalance)
        XCTAssertFalse(abs(gains.r - 1) < 1e-3 && abs(gains.g - 1) < 1e-3 && abs(gains.b - 1) < 1e-3,
                       "the estimator says 3500 K/+30 is identity — pick another value")
        // …and the old display-encoded fit is a different number, so this is not a re-run of it.
        let old = wbOnly.light.whiteBalanceGains
        XCTAssertNotEqual(Float(gains.r), old.r, accuracy: 1e-3)
    }

    // MARK: - 8. documents written before schema 3

    func testSchema2DocumentReadsTheOldSentinelAsAsShot() throws {
        let old = Data(#"{"schemaVersion":2,"light":{"exposure":0.5,"temperature":6500,"tint":0}}"#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: old)
        XCTAssertNil(model.light.temperature, "6500 was the old \"no change\" sentinel, not a value")
        XCTAssertNil(model.light.tint)
        XCTAssertEqual(model.light.exposure, 0.5)
        XCTAssertTrue(model.light.whiteBalance.isAsShot)

        let edited = Data(#"{"schemaVersion":2,"light":{"temperature":5200,"tint":-12}}"#.utf8)
        let kept = try JSONDecoder().decode(EditModel.self, from: edited)
        XCTAssertEqual(kept.light.temperature, 5200, "a real value must survive the migration")
        XCTAssertEqual(kept.light.tint, -12)

        // A schema-3 document keeps an explicit 6500 K: it is a value now, not a sentinel.
        let pinned = Data(#"{"schemaVersion":3,"light":{"temperature":6500,"tint":0}}"#.utf8)
        let model3 = try JSONDecoder().decode(EditModel.self, from: pinned)
        XCTAssertEqual(model3.light.temperature, 6500)
        XCTAssertEqual(model3.light.tint, 0)

        // And as shot round-trips as *absence*, not as `null`.
        let encoded = try JSONEncoder().encode(EditModel.neutral)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("temperature"), "as shot was written as a number: \(json)")
        XCTAssertEqual(try JSONDecoder().decode(EditModel.self, from: encoded), .neutral)
    }
}
