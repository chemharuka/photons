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

    /// `CurvePoint(0, 0.1) → (1, 1)`: the drag that lights the bars up. 0 in, 0.1 out.
    private var liftedBlackCurve: CurveGroup {
        CurveGroup(rgb: [CurvePoint(0, 0.1), CurvePoint(1, 1)])
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

    /// Acceptance ②: the guard must not eat the picture. Inside the content rect the LUT still runs —
    /// the mean rises because the ramp's toe moved, and the true-black block lands on the LUT's 0.1
    /// (0.349 in display units), which is the number the pre-guard render showed on the bars too.
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

            print("派单 008C content [\(box.name)]: mean \(baseMean) → \(curveMean) (Δ \(delta)), "
                  + "source-black pixel → \(liftedBlack)")

            XCTAssertGreaterThan(delta, 0.02, "\(box.name): the curve must still move the picture")
            XCTAssertEqual(liftedBlack, 0.349, accuracy: 0.005,
                           "\(box.name): the LUT's 0 → 0.1 must survive inside the content rect")
        }
    }

    // MARK: - byte identity

    /// Acceptance ③: the neutral document is untouched by the guard. These are the hashes measured
    /// **before** `CurveParams.b` existed; the identity branch already wrote the matte through, so
    /// the bytes must not move — a change here would mean the guard leaked into the content path.
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
        // half floats, which is pre-existing (measured below). The claim worth pinning is that the
        // **curve** contributes nothing extra to it.
        let unwrapped = try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let boxed = try XCTUnwrap(graph.render(edit, options: options(boxes[0])).display)
        let rect = contentRect(try graph.render(edit, options: options(boxes[0])))
        let drift = maxAbsDifference(unwrapped, (x: 0, y: 0), boxed, rect)
        print("派单 008C content [canvas vs none]: max |Δ| = \(drift) (S0's 1:1 resample, pre-existing)")
        XCTAssertLessThanOrEqual(drift, 0.002, "a canvas may not change the picture beyond S0's resample")
    }

    // MARK: - measured-once constants
    //
    // Recorded from the render **before** `s3_curve`'s content guard (the matte was 0.349 there, the
    // content rect is the same picture either way). Re-measure only if the curve pipeline itself
    // changes; these are not goldens on disk, so nothing needs re-recording.

    private static let neutralCanvasHash = "0487f109112b48233dce485d843610dd1dfae7884e307533bb7baa0bf18437bb"
    private static let neutralPillarboxHash = "eab59159b31e72b4fc223fce364c44e67c025db96e09015c739780371d52795a"
    private static let neutralLetterboxHash = "d39f90c648b367c2042b882e84733a56a3db65d7f364e1e04d92b668efc1e3a5"
    private static let curveContentPillarboxHash = "4347144dcb07f7faeec3fd3b476213f357c1e3797e2fb1aba7a23cc2a2f9bdfa"
    private static let curveContentLetterboxHash = "4347144dcb07f7faeec3fd3b476213f357c1e3797e2fb1aba7a23cc2a2f9bdfa"
}
