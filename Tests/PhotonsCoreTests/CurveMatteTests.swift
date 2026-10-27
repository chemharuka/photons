import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 派单 008 C — the third surface of the same bug: **S3a's curve lifts the matte.**
///
/// S0 letterboxes with 0 and S2 (派单 008 B) and S3c already write the pixels outside the content
/// rect through untouched. The curve did not: its LUT is the user's own function of the input, so a
/// point at `(0, 0.1)` maps the matte's 0 to 0.1 scene-linear — 0.349 in display units after S4's
/// sRGB encode — and the viewport's background bars turn grey. The precedent from S2 is copied
/// verbatim: `CurveParams.b` carries `contentOrigin.xy, contentSize.xy` in canvas pixels and one
/// guard per pixel writes the matte through.
///
/// The assertions are countable on purpose:
///
///   * `testCurveLeavesTheMatteAtExactlyZero` — pillarbox **and** letterbox (so both the x and the y
///     edge of the guard are exercised), two LUTs that lift black, every matte pixel **exactly** 0.
///   * `testCurveStillMovesTheContent` — the guard must not swallow the picture: same render, mean
///     over the content rect, plus the true-black block, which must land on the LUT's 0.1.
///   * `testIdentityCurveHashesAreUnchanged` — the neutral document's display bytes are the ones
///     measured before the guard, canvas==content and letterboxed.
///   * `testCurveContentPixelsAreUnchanged` — a curve render's content rect hashes to the pre-guard
///     value: only the matte moved.
final class CurveMatteTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "curve-matte-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// 3:2 ramp with an exact-black 32×32 block top-left and a near-white one bottom-right — the
    /// block is what a "drag the black point up" curve has to move, and it is also the pixel the
    /// curve's `(0, 0.1)` point pins.
    private func rampImage(width: Int = 480, height: Int = 320) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                var base = 0.015 + 0.90 * t
                if x < 32 && y < 32 { base = 0 }
                if x >= width - 32 && y >= height - 32 { base = 0.99 }
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(base)
                rgba[o + 2] = Float16(base)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// The two ways a canvas can be bigger than the picture, both at `scale: 1` so the content rect
    /// is exactly the source (no rescale): 80-pixel pillars left/right, 50-pixel bars top/bottom.
    private struct Box {
        let name: String
        let canvas: ImageSize
        /// Which edges the matte is on — printed so the numbers are readable.
        let note: String
    }

    private var boxes: [Box] {
        [Box(name: "pillarbox", canvas: ImageSize(width: 640, height: 320), note: "80-px bars left/right"),
         Box(name: "letterbox", canvas: ImageSize(width: 480, height: 420), note: "50-px bars top/bottom")]
    }

    private func options(_ box: Box) -> RenderOptions {
        RenderOptions(canvas: box.canvas, scale: 1, wantsPixels: true)
    }

    private func contentRect(_ result: RenderResult) -> (x: Int, y: Int, w: Int, h: Int) {
        // The same centred rect `RenderGraph.plan` computes: `(canvas − content) / 2`, integer division.
        (x: (result.canvas.width - result.content.width) / 2,
         y: (result.canvas.height - result.content.height) / 2,
         w: result.content.width,
         h: result.content.height)
    }

    private func meanLuma(_ img: DisplayImage, rect: (x: Int, y: Int, w: Int, h: Int)) -> Double {
        var sum = 0.0
        var n = 0
        for y in rect.y..<(rect.y + rect.h) {
            for x in rect.x..<(rect.x + rect.w) {
                let o = (y * img.width + x) * 4
                sum += (Double(Float(img.rgba[o])) + Double(Float(img.rgba[o + 1]))
                        + Double(Float(img.rgba[o + 2]))) / 3
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// Largest RGB component outside the content rect, and how many of those pixels are not exactly 0.
    private func matteStatistics(_ img: DisplayImage, rect: (x: Int, y: Int, w: Int, h: Int))
        -> (maxValue: Float, nonZeroPixels: Int, pixels: Int) {
        var maxValue: Float = 0
        var nonZero = 0
        var pixels = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let inside = x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
                if inside { continue }
                let o = (y * img.width + x) * 4
                let m = max(Float(img.rgba[o]), max(Float(img.rgba[o + 1]), Float(img.rgba[o + 2])))
                maxValue = max(maxValue, m)
                if m != 0 { nonZero += 1 }
                pixels += 1
            }
        }
        return (maxValue, nonZero, pixels)
    }

    /// Largest per-channel |Δ| between `a`'s content rect at `aOrigin` and `b`'s content rect at `rect`.
    private func maxAbsDifference(_ a: DisplayImage, _ aOrigin: (x: Int, y: Int),
                                 _ b: DisplayImage, _ rect: (x: Int, y: Int, w: Int, h: Int)) -> Float {
        var d: Float = 0
        for y in 0..<rect.h {
            for x in 0..<rect.w {
                let oa = ((aOrigin.y + y) * a.width + (aOrigin.x + x)) * 4
                let ob = ((rect.y + y) * b.width + (rect.x + x)) * 4
                for c in 0..<3 {
                    d = max(d, abs(Float(a.rgba[oa + c]) - Float(b.rgba[ob + c])))
                }
            }
        }
        return d
    }

    /// SHA-256 of the RGB(A) bytes **inside** the content rect only, in raster order. Two renders
    /// that differ only in the matte hash the same, which is exactly the claim "only the matte moved".
    private func contentHash(_ img: DisplayImage, rect: (x: Int, y: Int, w: Int, h: Int)) -> String {
        var hasher = SHA256()
        for y in rect.y..<(rect.y + rect.h) {
            let start = (y * img.width + rect.x) * 4
            let count = rect.w * 4
            img.rgba.withUnsafeBufferPointer { buf in
                let base = UnsafeRawBufferPointer(start: buf.baseAddress! + start, count: count)
                hasher.update(bufferPointer: base)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `CurvePoint(u: 0, v: 0.3) → (1, 1)`: the drag that would light the bars up, if nothing guarded them.
    ///
    /// 030 turned the y axis into the axis coordinate `u` (`HDRCurveAxis`), so the lift has to be
    /// expressed in `u`, not in linear light: since 062 the left half of `u` is the display encoding,
    /// so **0.3 u is display code 0.60** (`sRGB⁻¹(0.6)` = 0.318 linear) — it was +5.4 stops of light
    /// on 044's log axis, and it is a *bigger* lift now. A lifted black end is therefore even more
    /// visible on the letterbox than the old `f(0) = 0.1` was, which is why the guards are still the
    /// point of this file.
    private var liftedBlackCurve: CurveGroup {
        CurveGroup(white: [CurvePoint(u: 0, v: 0.3), CurvePoint(u: 1, v: 1)])
    }

    // MARK: - the matte

    /// Acceptance ①: every pixel outside the content rect is **exactly** 0 — not "small", not
    /// "within an epsilon" — with a curve that maps 0 to 0.1, on both edges of the guard.
    func testCurveLeavesTheMatteAtExactlyZero() throws {
        let graph = try makeGraph(rampImage())
        var edit = EditModel.neutral
        edit.curve = liftedBlackCurve

        for box in boxes {
            let result = try graph.render(edit, options: options(box))
            let img = try XCTUnwrap(result.display)
            let rect = contentRect(result)
            let stats = matteStatistics(img, rect: rect)
            print("派单 008C 黑边 [\(box.name) \(box.note)]: canvas \(result.canvas.width)×\(result.canvas.height), "
                  + "content \(result.content.width)×\(result.content.height) at (\(rect.x),\(rect.y)), "
                  + "matte max = \(stats.maxValue), non-zero matte pixels = \(stats.nonZeroPixels)/\(stats.pixels)")
            XCTAssertEqual(stats.pixels, box.canvas.width * box.canvas.height - rect.w * rect.h,
                           "\(box.name): the fixture must actually be letterboxed")
            XCTAssertEqual(stats.maxValue, 0, "\(box.name): a curve lifted the matte")
            XCTAssertEqual(stats.nonZeroPixels, 0, "\(box.name): \(stats.nonZeroPixels) matte pixels are not black")
        }
    }

    /// The same for a curve that lifts black *and* a colour/vignette stage after it: the matte has
    /// to survive the whole S3 group, not just S3a.
    func testMatteSurvivesCurveColourAndVignette() throws {
        let graph = try makeGraph(rampImage())
        var edit = EditModel.neutral
        edit.curve = liftedBlackCurve
        edit.color.vibrance = 100
        edit.color.saturation = 100
        edit.effects.vignetteAmount = -100

        for box in boxes {
            let result = try graph.render(edit, options: options(box))
            let img = try XCTUnwrap(result.display)
            let rect = contentRect(result)
            let stats = matteStatistics(img, rect: rect)
            print("派单 008C 黑边 curve+color+vignette [\(box.name)]: matte max = \(stats.maxValue), "
                  + "non-zero = \(stats.nonZeroPixels)/\(stats.pixels)")
            XCTAssertEqual(stats.maxValue, 0, "\(box.name): a later S3 stage lifted the matte")
        }
    }

    // MARK: - the picture

    /// Acceptance ②: the guard must not eat the picture. Inside the content rect the table still
    /// runs — the mean rises because the ramp's toe moved.
    ///
    /// 030 note on the true-black block: it stays **exactly 0**, and that is now the *kernel's* rule
    /// 3 (`x ≤ 0` passes through, 派单 018), not the guard. A curve cannot lift an exact zero,
    /// because the log-light shaper has no defined value there and sub-black detail must survive the
    /// curve untouched. So this test pins both halves: the picture moves, the exact-black pixel does
    /// not — the second fact is why the matte needs a guard even though `0 → 0` here.
    func testCurveStillMovesTheContent() throws {
        let graph = try makeGraph(rampImage())
        var edit = EditModel.neutral
        edit.curve = liftedBlackCurve

        for box in boxes {
            let result = try graph.render(edit, options: options(box))
            let img = try XCTUnwrap(result.display)
            let rect = contentRect(result)

            let base = try XCTUnwrap(graph.render(EditModel.neutral, options: options(box)).display)
            let baseMean = meanLuma(base, rect: rect)
            let curveMean = meanLuma(img, rect: rect)
            let delta = curveMean - baseMean

            // The source's exact-black block sits at the content rect's top-left corner (no rescale).
            let blackIndex = ((rect.y + 8) * img.width + (rect.x + 8)) * 4
            let liftedBlack = Float(img.rgba[blackIndex])
            // A *near*-black pixel of the picture: the ramp's first column past the block, 0.0751
            // linear. This is the pixel the lift must move.
            let toeIndex = ((rect.y + 8) * img.width + (rect.x + 40)) * 4
            let toeBase = Float(base.rgba[((rect.y + 8) * base.width + (rect.x + 40)) * 4])
            let toeLifted = Float(img.rgba[toeIndex])

            print("派单 008C content [\(box.name)]: mean \(baseMean) → \(curveMean) (Δ \(delta)), "
                  + "exact-black \(liftedBlack), toe \(toeBase) → \(toeLifted)")

            XCTAssertGreaterThan(delta, 0.02, "\(box.name): the curve must still move the picture")
            XCTAssertEqual(liftedBlack, 0,
                           "\(box.name): an exact 0 must pass through the curve (rule 3, 018)")
            XCTAssertGreaterThan(toeLifted, toeBase + 0.1,
                                 "\(box.name): a near-black pixel must be lifted by the table")
        }
    }

    // MARK: - byte identity

    /// Acceptance ③: the neutral document is untouched by the guard. These are the hashes measured
    /// **before** `CurveParams.b` existed; the identity branch already wrote the matte through, so
    /// the bytes must not move — a change here would mean the guard leaked into the content path.
    ///
    /// ── 075 re-recorded all three, and it is the primaries switch, not this file ────────────────
    /// The three constants are hashes of the **rendered frame** (`graph.render(…).display`, sha256
    /// over the rgba16Float bytes), not of a matte value — the matte is asserted as an exact 0
    /// elsewhere in this file (`testCurveLeavesTheMatteAtExactlyZero`, which still passes), and every
    /// matte pixel here is byte-identical to the pre-075 frame (measured: 0 of the bar pixels moved).
    /// The picture moved because the working space became linear Rec.2020: the frame is now
    /// decode(sRGB) → S0's exit matrix → Rec.2020 → S4's matrix → sRGB instead of a pass-through.
    ///
    /// The ablation is exact: with `ColorPrimaries.working` temporarily set back to `.sRGB` — S0's
    /// matrix then takes `primariesMatrix`'s `source == target` identity branch and S4's `p.a.x` flag
    /// is 1, i.e. the pre-075 arithmetic — these same three renders reproduce the **old constants bit
    /// for bit** (`0487f109…`, `eab59159…`, `d39f90c6…`). Nothing else in the batch touches them.
    ///
    /// How far the picture moved, old frame vs new, per channel value (this is the whole magnitude):
    ///
    /// ```
    /// canvas 480×320    max |Δ| 0.1245 codes; 2464/460800 values differ (0.53 %), none by ≥0.5 codes
    /// pillarbox 640×320 max |Δ| 0.1245 codes;  896/460800 values differ (0.19 %), none by ≥0.5 codes
    /// letterbox 480×420 max |Δ| 0.1245 codes;  896/460800 values differ (0.19 %), none by ≥0.5 codes
    /// matte             max |Δ| 0.0000 codes;    0/51200 and 0/48000 bar pixels moved, all still exact 0
    /// ```
    ///
    /// 0.1245 codes is one float16 ULP at these levels — the other 99.5 % of the frame's channel values
    /// come back byte-identical. The ramp is synthetic neutral grey in [0.015, 0.99] with no sub-black,
    /// so nothing here is clipped — this is the round trip's storage and nothing else (compare
    /// `RenderTests.testNeutralRenderIsDecodePlusOETF`, where the 0.89 % of that fixture's pixels
    /// *below* black move by up to 4 codes because the clip happens in the working cube now). The
    /// curve render's content bytes did not move at all: `testCurveContentPixelsAreUnchanged` still
    /// matches its 030-era constants (`11578fbd…`), so the half-ULP flips live in the uncurved
    /// pass-through, not in the LUT path.
    func testIdentityCurveHashesAreUnchanged() throws {
        let graph = try makeGraph(rampImage())
        let neutral = EditModel.neutral

        let plain = try XCTUnwrap(graph.render(neutral, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        XCTAssertEqual(plain.width, 480)
        XCTAssertEqual(plain.height, 320)

        var observed: [String: String] = ["canvas==content": plain.sha256()]
        for box in boxes {
            let img = try XCTUnwrap(graph.render(neutral, options: options(box)).display)
            observed[box.name] = img.sha256()
        }
        for (name, hash) in observed.sorted(by: { $0.key < $1.key }) {
            print("派单 008C 0/0 恒等 [\(name)]: sha256 = \(hash)")
        }

        XCTAssertEqual(observed["canvas==content"], Self.neutralCanvasHash)
        XCTAssertEqual(observed["pillarbox"], Self.neutralPillarboxHash)
        XCTAssertEqual(observed["letterbox"], Self.neutralLetterboxHash)

        // Determinism: the guard must not depend on dispatch geometry.
        let again = try XCTUnwrap(graph.render(neutral, options: options(boxes[0])).display)
        XCTAssertEqual(again.sha256(), observed["pillarbox"])
    }

    /// Acceptance ④: with a curve active, the content rect's bytes are the ones measured before the
    /// guard — the *only* thing the change may move is the matte. The hash is over the content rect
    /// alone (`contentHash`), so this pins the picture and ignores the bars on purpose.
    func testCurveContentPixelsAreUnchanged() throws {
        let graph = try makeGraph(rampImage())
        var edit = EditModel.neutral
        edit.curve = liftedBlackCurve

        var hashes: [String: String] = [:]
        for box in boxes {
            let result = try graph.render(edit, options: options(box))
            let img = try XCTUnwrap(result.display)
            hashes[box.name] = contentHash(img, rect: contentRect(result))
            print("派单 008C content hash [\(box.name)]: \(hashes[box.name] ?? "")")
        }
        XCTAssertEqual(hashes["pillarbox"], Self.curveContentPillarboxHash)
        XCTAssertEqual(hashes["letterbox"], Self.curveContentLetterboxHash)
        // The two canvases carry the same picture: the matte is the only difference between them.
        XCTAssertEqual(hashes["pillarbox"], hashes["letterbox"],
                       "the content rect must not depend on which edge the bars are on")

        // The picture without a canvas is the same picture. Not byte-identical: S0 samples the
        // source through its 1:1 geometry path when a canvas is asked for, and that path rounds in
        // half floats, which is pre-existing. The claim worth pinning is that the **curve**
        // contributes nothing extra to it — so the curve's drift is measured *against the neutral
        // document's own drift*, and the legitimate amplification is the curve's own local slope.
        //
        // Since 062 that slope is much larger at the toe: `(0, 0.3)` on a display-encoded left half
        // is a lift of ~0.32 in linear light from a 0.075 input, so a 1e-3 rounding difference in the
        // source arrives as 0.022 of a display code (it was 0.002 on 044's log axis, where the same
        // control point was a +5.4-stop lift with a gentler local slope).
        let unwrapped = try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let boxed = try XCTUnwrap(graph.render(edit, options: options(boxes[0])).display)
        let rect = contentRect(try graph.render(edit, options: options(boxes[0])))
        let drift = maxAbsDifference(unwrapped, (x: 0, y: 0), boxed, rect)

        let neutralUnwrapped = try XCTUnwrap(graph.render(EditModel.neutral,
                                                          options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let neutralBoxed = try XCTUnwrap(graph.render(EditModel.neutral, options: options(boxes[0])).display)
        let neutralDrift = maxAbsDifference(neutralUnwrapped, (x: 0, y: 0), neutralBoxed, rect)
        print("派单 008C content [canvas vs none]: max |Δ| = \(drift) with the curve, "
              + "\(neutralDrift) without it (S0's 1:1 resample, amplified by the curve's slope)")
        XCTAssertLessThanOrEqual(drift, max(0.05, 25 * neutralDrift),
                                 "a canvas may not change the picture beyond S0's resample")
    }

    // MARK: - measured-once constants
    //
    // The three identity hashes were recorded **before** any content guard existed and did not move for
    // 派单 030 (curve from S3 to S1.7): the identity branch writes the pixel through, so a reorder of
    // the curve is invisible to them — that is the strongest pixel claim in this file, and it held.
    //
    // They **were re-recorded once**, for 075, and the cause is not this file: the working space became
    // linear Rec.2020, so the neutral frame is now decode(sRGB) → S0's exit matrix → Rec.2020 → S4's
    // matrix → sRGB instead of a pass-through. The evidence, in the order it was measured:
    //
    //   · **what moved is the rendered frame, not a matte value.** These are `DisplayImage.sha256()`
    //     over rgba16Float bytes from `graph.render(…).display`; the matte is pinned as an exact 0 by
    //     `testCurveLeavesTheMatteAtExactlyZero`, which did not move, and 0 of the bar pixels differ
    //     between the old and the new frame (measured below).
    //   · **nothing else in the batch touches them.** With `ColorPrimaries.working` set back to `.sRGB`
    //     — i.e. the pre-075 arithmetic, where S0's matrix takes the `source == target` identity branch
    //     and S4's `p.a.x` flag is 1 — these three renders reproduce `0487f109…` / `eab59159…` /
    //     `d39f90c6…` bit for bit.
    //   · **the movement is one half-float ULP.** Old frame vs new, per channel value: max |Δ| =
    //     0.1245 of an 8-bit code on all three, i.e. 2464/460800 (0.53 %) and 896/460800 (0.19 %,
    //     twice) of the channel values differ at all, **no value moves by ≥0.5 codes**, and every matte
    //     pixel is byte-identical. Nothing here is clipped (the ramp is grey in [0.015, 0.99], no
    //     sub-black), so this is the round trip's storage and only that. The curve render's content
    //     bytes did not move at all — the two curve hashes below still match their 030-era values.
    //
    // The two curve hashes were re-recorded for 030 because the fixture curve is now expressed in the
    // axis coordinate (`CurvePoint(u: 0, v: 0.3)`, see `liftedBlackCurve`): the *same* control points no
    // longer mean the same lift, which is exactly what `processVersion` 2 declares. They moved again
    // for 044 (the axis's right end went +6 → +4 EV) and again for 062 (the axis became the
    // histogram's: SDR white at u = 0.5000 instead of 0.7500, so `(0, 0.3)` is display code 0.60 —
    // a bigger lift than either earlier axis gave it). Same change of meaning, not a regression: the
    // two boxes still hash the same picture. The structure being pinned did not change — content moved,
    // matte did not. Not goldens on disk; nothing needs re-recording elsewhere.

    private static let neutralCanvasHash = "dba62bded02712527ae771932085f196f47fb857f2fcf942b82b9b1781c36943"   // was 0487f109… before 075
    private static let neutralPillarboxHash = "3d444bea2aecffdf1674a4b6ebe2333298f9cefefaa0319ae7eca21ad8736102" // was eab59159… before 075
    private static let neutralLetterboxHash = "abae91ed8984304e0c8173c8322e1c318f0837fb39e88692f2d09f3f538b9547" // was d39f90c6… before 075
    private static let curveContentPillarboxHash = "11578fbde7911dea8aa6807241329531941c626284c1e06cd091c8c0111d8e68"
    private static let curveContentLetterboxHash = "11578fbde7911dea8aa6807241329531941c626284c1e06cd091c8c0111d8e68"
}
