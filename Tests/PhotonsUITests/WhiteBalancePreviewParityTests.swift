import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 194 — **two-stage white balance: the drag is an approximation, the settled frame is the truth.**
///
/// 143b used to pin "preview == settled, ≤ 1 code" on this file. That contract could only hold while
/// both halves were the *same* computation — the as-shot buffer times `WhiteBalanceEstimate`'s S1 gain —
/// which is exactly what made the app never write the document's pair into `CIRAWFilter`. 194 splits
/// them on purpose:
///
///   · **drag** — the resident buffer through S1 with `WhiteBalanceEstimate`'s gain. One render, zero
///     developments, ~5 ms;
///   · **settle** — the value goes into the document → `DecodeInputs.whiteBalance` → `CIRAWFilter`'s
///     `neutralTemperature`/`neutralTint` → one development (~0.5 s on 25 MP) → S1 gain identity.
///
/// So the numbers here are no longer "0 or 1 code". §2 of the task measured the gap between the two
/// (same RAW, five pairs, `WhiteBalanceTwoStageGapTests`), and the measured worst case is
/// **97 codes at 3200 K** (ΔE00 4.7 mid / 7.6 highlights), 16 codes at 6500 K, 15–19 codes at tint ±30,
/// and **0 for as shot**. The estimate is a von Kries gain in the working primaries; the decoder
/// balances in camera space. `previewToleranceCodes` is that measurement rounded up to the next ten —
/// it is a **statement about how good the preview is**, not a promise that it equals the frame.
///
/// What stays exact, and is the whole point of the split:
///
///   ① a settled frame carries the decoder's balance and **S1's gain is `(1, 1, 1)`** — one application,
///      never two;
///   ② an **as-shot** document is byte-identical on both paths (the gain is the identity there), which
///      is the identity gate;
///   ③ a drag costs **no development at all**, and one settle costs exactly **one** (`decodeCounts`);
///   ④ the drag still fits p50 ≤ 8 ms / p95 ≤ 16 ms at the 0.25 rung.
///
/// The fixtures are the user's own files; the suite skips when they are absent.
@MainActor
final class WhiteBalancePreviewParityTests: XCTestCase {

    private struct Sample {
        let name: String
        let path: String
    }

    private static let samples = [
        Sample(name: "L1030433", path: "~/Desktop/test/L1030433.dng"),
        Sample(name: "L1030437", path: "~/Desktop/test/L1030437.dng"),
        Sample(name: "DJI_air3_2250_D", path: "~/Desktop/US/DJI_air3_2250_D.dng"),
    ]

    private static let pairs: [(Double, Double)] = [(6500, 0), (7500, 10), (5000, -10)]
    private static let viewport = ImageSize(width: 800, height: 600)
    private static let decodeScale: Float = 0.125

    /// **195's measured gap — and this tolerance is a failure, on purpose.**
    ///
    /// 194's preview was a von Kries diagonal and measured 97 codes at 3200 K; 195 replaces it with
    /// the full 3×3 (`WhiteBalanceEstimate.relativeMatrix`) anchored on the file's as-shot pair, which
    /// is measurably better — 6500 K 16 → 8 codes, 3200 K 97 → 60, tint +30 13 → 10 — but **not**
    /// within the 3 codes the task asked for. The remaining error is not the diagonality: a 3×3
    /// *fitted to the decoder* reaches ΔE00 0.06–0.43 (ceiling, `WhiteBalanceModelProbeTests`), while
    /// the *analytic estimate* lands at 2–12. `CIRAWFilter` balances in camera space with its own
    /// primaries and white-point normalisation, and no single 3×3 in the output space reproduces it
    /// (the extreme cells need 4× entries, i.e. extrapolation).
    ///
    /// So this number stays at the **target**, not at the measurement: a looser number would turn a
    /// known-unmet requirement into a green test. The decision the number waits on is the main line's
    /// — A: refine the estimate progressively; B: accept the jump on release; C: limit the drag's
    /// gain travel. Until then this test is red and says so.
    private static let previewToleranceCodes = 3

    private func fixtures() throws -> [(Sample, URL)] {
        var found: [(Sample, URL)] = []
        for sample in Self.samples {
            let path = NSString(string: sample.path).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw XCTSkip("missing fixture \(sample.path)")
            }
            found.append((sample, URL(fileURLWithPath: path)))
        }
        return found
    }

    private func makeLoupe() -> LoupeController {
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel,
                         viewport: ImageSize, scale: Float,
                         useCache: Bool = true) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale,
                            edit: edit, hashPixels: false, useCache: useCache)
    }

    private func settledEdit(_ edit: EditModel, _ pair: (Double, Double)) -> EditModel {
        var out = edit
        let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
        out.light.temperature = target.temperature
        out.light.tint = target.tint
        return out
    }

    // MARK: - 1. the drag approximates, the settled frame is the decoder's

    func testPreviewApproximatesTheSettledFrame() throws {
        let fixtures = try fixtures()
        var worst = 0
        for (sample, url) in fixtures {
            let session = CatalogSession()
            let loupe = makeLoupe()
            let asShot = session.edit
            _ = try develop(loupe, url, asShot, viewport: Self.viewport, scale: Self.decodeScale)

            // ② as shot is the identity gate: no gain on either side, so the frames are byte-equal.
            let asShotPreview = try loupe.renderWhiteBalancePreview(.asShot, viewport: Self.viewport)
            let asShotSettled = try develop(loupe, url, asShot, viewport: Self.viewport,
                                             scale: Self.decodeScale)
            XCTAssertEqual(asShotPreview.whiteBalanceGain, SIMD3(1, 1, 1),
                           "\(sample.name): an as-shot preview applied a gain")
            XCTAssertEqual(asShotSettled.whiteBalanceGain, SIMD3(1, 1, 1),
                           "\(sample.name): an as-shot frame applied a gain")
            let identityGap = Self.maxCodeDelta(asShotPreview.texture, asShotSettled.texture)
            XCTAssertEqual(identityGap, 0,
                           "\(sample.name): an as-shot document is not byte-identical on the two paths "
                           + "(\(identityGap) codes) — the as-shot buffer moved")

            for pair in Self.pairs {
                let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
                let preview = try loupe.renderWhiteBalancePreview(target, viewport: Self.viewport)
                let settled = try develop(loupe, url, settledEdit(asShot, pair),
                                           viewport: Self.viewport, scale: Self.decodeScale)

                // ① the settled frame is the decoder's: S1 must be the identity, or the pair is applied
                //   twice — once by `CIRAWFilter`, once by the gain.
                XCTAssertEqual(settled.whiteBalanceGain, SIMD3(1, 1, 1),
                               "\(sample.name) \(pair): the settled buffer was decoded at "
                               + "\(target.summary) and S1 still applied \(settled.whiteBalanceGain) — "
                               + "the balance is applied twice")
                // At the file's own temperature the estimate **is** the identity, so the preview is the
                // as-shot frame while the decoder still moves a few codes — that row of §2's table is
                // the honest measure of it, not a tautology.
                XCTAssertTrue(preview.whiteBalanceGain.x.isFinite
                              && preview.whiteBalanceGain.y.isFinite
                              && preview.whiteBalanceGain.z.isFinite,
                              "\(sample.name) \(pair): the preview gain is not a number")

                let delta = Self.maxCodeDelta(preview.texture, settled.texture)
                worst = max(worst, delta)
                XCTAssertLessThanOrEqual(delta, Self.previewToleranceCodes,
                    "\(sample.name) \(pair): the 3×3 preview is \(delta) codes from the settled frame "
                    + "(target \(Self.previewToleranceCodes)). 195 measured this and it does not pass — "
                    + "the model class is proven sufficient (fitted 3×3 → ΔE00 0.1) and the analytic "
                    + "estimate is what is short. Waiting on the main line's A/B/C decision; do not "
                    + "raise this number to make it green.")
                print(String(format: "WB two-stage %@ (%@): preview↔settled max|Δ| %d code · "
                             + "mean|Δ| %.3f · preview gain [%.6f %.6f %.6f] · settled gain (1, 1, 1)",
                             sample.name, WhiteBalance(temperature: pair.0, tint: pair.1).summary,
                             delta, Self.meanCodeDelta(preview.texture, settled.texture),
                             preview.whiteBalanceGain.x, preview.whiteBalanceGain.y,
                             preview.whiteBalanceGain.z))
            }
        }
        print("WB two-stage: 3 samples × 3 pairs · worst preview↔settled max|Δ| \(worst) code "
              + "(measured tolerance \(Self.previewToleranceCodes); as shot is 0)")
    }

    // MARK: - 2. the preview really re-runs S1…S4

    func testPreviewReRunsTheRenderGraph() throws {
        let fixtures = try fixtures()
        for (sample, url) in fixtures {
            let session = CatalogSession()
            let loupe = makeLoupe()
            _ = try develop(loupe, url, session.edit, viewport: Self.viewport, scale: Self.decodeScale)
            let pair = Self.pairs[1]
            let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
            let preview = try loupe.renderWhiteBalancePreview(target,
                                                             viewport: Self.viewport)
            let settled = try develop(loupe, url, settledEdit(session.edit, pair),
                                      viewport: Self.viewport, scale: Self.decodeScale,
                                      useCache: false)

            XCTAssertFalse(preview.trace.executed.isEmpty,
                           "\(sample.name): the preview executed no stages — it is not a render")
            XCTAssertTrue(preview.trace.executed.contains(.sceneLinear),
                          "\(sample.name): the preview did not run S1")
            XCTAssertTrue(preview.trace.executed.contains(.toneMap),
                          "\(sample.name): the preview did not run the tone map")
            XCTAssertEqual(preview.trace.executed, settled.trace.executed,
                           "\(sample.name): preview stages \(preview.trace.csv) ≠ settled "
                           + "\(settled.trace.csv)")
            print("WB preview stages \(sample.name): \(preview.trace.csv)")
        }
    }

    // MARK: - 3. a drag develops nothing; one settle develops exactly once

    func testDragNeverDevelopsAndOneSettleDevelopsOnce() throws {
        let fixtures = try fixtures()
        guard let (sample, url) = fixtures.first else { throw XCTSkip("no fixtures") }
        let session = CatalogSession()
        let loupe = makeLoupe()
        _ = try develop(loupe, url, session.edit, viewport: Self.viewport, scale: Self.decodeScale)

        func decodes() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

        // Twenty drag ticks, each a new pair (a repeated pair would be a cache hit, not a tick).
        let beforeDrag = decodes()
        let rendersBefore = loupe.whiteBalancePreviewRenderCount
        loupe.beginWhiteBalancePreview()
        let deadline = Date().addingTimeInterval(120)
        for tick in 1...20 {
            loupe.updateWhiteBalancePreview(temperature: 3000 + Double(tick) * 50,
                                            tint: Double(tick % 11) - 5)
            while loupe.isRenderingWhiteBalancePreview, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }
        let dragDecodes = decodes() - beforeDrag
        XCTAssertEqual(dragDecodes, 0,
                       "\(sample.name): the drag developed \(dragDecodes) buffer(s) — a drag must cost "
                       + "renders only")
        XCTAssertGreaterThan(loupe.whiteBalancePreviewRenderCount, rendersBefore,
                             "\(sample.name): the drag painted nothing")

        // The release writes one pair, and that costs exactly one development — the price of the truth.
        loupe.releaseWhiteBalancePreview(awaiting: nil)
        let pair = Self.pairs[0]
        let beforeSettle = decodes()
        let settled = try develop(loupe, url, settledEdit(session.edit, pair),
                                   viewport: Self.viewport, scale: Self.decodeScale)
        let settleDecodes = decodes() - beforeSettle
        XCTAssertEqual(settleDecodes, 1,
                       "\(sample.name): a settle developed \(settleDecodes) buffers — one value, one decode")
        XCTAssertEqual(settled.whiteBalanceGain, SIMD3(1, 1, 1),
                       "\(sample.name): the settled frame ran a gain on a buffer that already has the pair")
        print(String(format: "WB two-stage %@: drag 20 ticks → %d development(s); settle → %d "
                     + "development(s) in %.0f ms",
                     sample.name, dragDecodes, settleDecodes, settled.decodeMilliseconds))
    }

    // MARK: - 4. drag latency at the 0.25 rung (≈ 4.1 Mpx)

    func testDragLatency() throws {
        guard let sample = Self.samples.first else { throw XCTSkip("no samples") }
        let url = URL(fileURLWithPath: NSString(string: sample.path).expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("missing fixture \(sample.path)")
        }

        // The 0.25 rung of a 60.3 Mpx frame is 2380 × 1584 ≈ 3.77 Mpx (the task calls it 4.1 Mpx).
        let scale: Float = 0.25
        let full = ImageSize(width: Int((9520.0 * 0.25).rounded()),
                             height: Int((6336.0 * 0.25).rounded()))
        let session = CatalogSession()
        let loupe = makeLoupe()
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: full.width / 2, height: full.height / 2)
        _ = try develop(loupe, url, session.edit, viewport: full, scale: scale)

        loupe.beginWhiteBalancePreview()
        loupe.resetWhiteBalancePreviewLatencies()
        let deadline = Date().addingTimeInterval(120)
        for tick in 1...200 {
            // Every tick is a new pair: S1 must miss on each one. A repeated Kelvin would be a cache
            // hit and would measure the cache, not the drag.
            let kelvin = 3000 + Double(tick) * 30
            let tint = Double(tick % 21) - 10
            loupe.updateWhiteBalancePreview(temperature: kelvin, tint: tint)
            while loupe.isRenderingWhiteBalancePreview, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }

        let p = loupe.whiteBalancePreviewLatencyPercentiles()
        XCTAssertEqual(p.count, 200, "200 drags must produce 200 measured frames")
        XCTAssertLessThanOrEqual(p.p50, 8, "drag p50 \(p.p50) ms exceeds 8 ms")
        XCTAssertLessThanOrEqual(p.p95, 16, "drag p95 \(p.p95) ms exceeds 16 ms")

        let preview = try loupe.renderWhiteBalancePreview(
            WhiteBalance(temperature: 6500, tint: 0), viewport: full)
        print(String(format: "WB drag latency %.2f Mpx: p50 %.2f ms · p95 %.2f ms · n %d",
                     Double(full.width * full.height) / 1e6, p.p50, p.p95, p.count))
        print("WB drag executed: \(preview.trace.executed.map(\.rawValue).joined(separator: " "))")
    }

    // MARK: - pixel maths

    /// 8-bit display codes, the budget the task states. The frame texture stores display-encoded
    /// light, so an 8-bit rendering is `round(clamp(v, 0, 1) · 255)`.
    private static func code(_ texture: MTLTexture) -> [UInt8] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = Double(Float(Float16(bitPattern: raw[i * 4 + c])))
                out[i * 3 + c] = UInt8(min(max((v * 255).rounded(), 0), 255))
            }
        }
        return out
    }

    private static func maxCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Int {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let ca = code(a), cb = code(b)
        var worst = 0
        for i in 0..<min(ca.count, cb.count) {
            worst = max(worst, abs(Int(ca[i]) - Int(cb[i])))
        }
        return worst
    }

    private static func meanCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Double {
        let ca = code(a), cb = code(b)
        guard !ca.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<min(ca.count, cb.count) { sum += abs(Int(ca[i]) - Int(cb[i])) }
        return Double(sum) / Double(min(ca.count, cb.count))
    }
}
