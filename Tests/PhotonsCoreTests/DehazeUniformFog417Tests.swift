import XCTest
import Metal
import PhotonsCore

/// 417 — **the four bands of the uniform-fog reference frame**, `L1030600`, at `dehaze = 100`.
///
/// The verdict (`417-verdict-sky-darkens.md` §5.4) asks for this frame's bands under **both**
/// transmission floors (`t0 = 0.05` shipped, `0.10` the pre-417 value) so the main line can pick one by
/// eye. This file is the reproducible half of that table: it prints the four bands unconditionally and
/// asserts only what the verdict actually promises about the shipped arithmetic.
///
/// Measurement, stated once so the numbers are not ambiguous:
///
///   · the **band** of a pixel is decided by the *neutral* render's display code (sRGB OETF applied to
///     the linear exit), which is the coordinate the user's sliders live in: `dark` 0.05–0.15,
///     `mid` 0.30–0.50, `bright` 0.50–0.70, `fog` 0.70–0.85;
///   · the **darkening** of a band is `1 − ΣJ/ΣI` over the band's pixels, in **scene-linear** light
///     (the domain the stage works in), so a band's number is the light it lost, not a code shift.
///
/// To reproduce the `t0 = 0.10` column: set `RenderGraph.dehazeTransmissionFloor` to `0.10`, rebuild and
/// run the same filter (see `local/REPORT.md` §5.4 for the exact commands).
final class DehazeUniformFog417Tests: XCTestCase {

    /// The reference frame lives in the user's library, not in the test fixtures directory.
    private var referencePath: String? {
        let candidates = ["~/Desktop/austria/L1030600.dng", "~/Desktop/test/L1030600.dng"]
            .map { NSString(string: $0).expandingTildeInPath }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// S4's scene-linear exit: the light itself, no OETF and no clamp.
    private func linearRender(_ graph: RenderGraph, _ edit: EditModel,
                              probe: Bool = false) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 1,
                                     linearOutput: true)
        // The subject is S1.9; 314's resting 锐化 is a spatial pass and would ride in every number.
        var doc = edit
        doc.sharpen = SharpenGroup(amount: 0)
        let result = try graph.render(doc, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true,
            probesDehazeAirlight: probe))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let i = (y * image.width + x) * 4
        return 0.2627 * Double(image.rgba[i])
            + 0.6780 * Double(image.rgba[i + 1])
            + 0.0593 * Double(image.rgba[i + 2])
    }

    /// The sRGB OETF — the display code a linear value is shown at (the band coordinate).
    private func encoded(_ linear: Double) -> Double {
        let c = max(linear, 0)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private struct Band {
        let name: String
        let lo: Double
        let hi: Double
        var i = 0.0
        var j = 0.0
        var ei = 0.0
        var ej = 0.0
        var n = 0
        var ratio: Double { j / max(i, 1e-9) }
        var darkening: Double { 1 - ratio }
        /// The same ratio in **display codes** (sRGB OETF on both sides) — the coordinate the lane's
        /// earlier probes printed, kept so the two tables are comparable.
        var encodedRatio: Double { ej / max(ei, 1e-9) }
        var encodedDarkening: Double { 1 - encodedRatio }
    }

    private static let bandEdges: [(String, Double, Double)] = [
        ("dark", 0.05, 0.15), ("mid", 0.30, 0.50),
        ("bright", 0.50, 0.70), ("fog", 0.70, 0.85),
    ]

    func testTheUniformFogFrameKeepsItsDarkBandAndDarkensTheFog() throws {
        guard let path = referencePath else {
            throw XCTSkip("需要 ~/Desktop/austria/L1030600.dng 或 ~/Desktop/test/L1030600.dng")
        }
        let decoded = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(scale: 0.25))
        let graph = try makeGraph(decoded, identity: "dehaze-uniform-fog-417")
        var edit = EditModel.neutral
        edit.effects.dehaze = 100

        let input = try linearRender(graph, .neutral)
        let out = try linearRender(graph, edit, probe: true)
        let A = try XCTUnwrap(graph.lastDehazeAirlight)

        var bands = Self.bandEdges.map { Band(name: $0.0, lo: $0.1, hi: $0.2) }
        for y in 0..<input.height {
            for x in 0..<input.width {
                let i = luma(input, x, y)
                let code = encoded(i)
                for b in bands.indices where code >= bands[b].lo && code < bands[b].hi {
                    bands[b].i += i
                    bands[b].j += luma(out, x, y)
                    bands[b].ei += code
                    bands[b].ej += encoded(luma(out, x, y))
                    bands[b].n += 1
                }
            }
        }
        print(String(format: "417-BANDS · L1030600 · t0 %.2f · A %.4f · dehaze 100",
                     RenderGraph.dehazeTransmissionFloor, A))
        for b in bands {
            print(String(format: "417-BANDS · %@ %.2f–%.2f · n %d · LIN J/I %.4f (%+.2f%%) · ENC J/I %.4f (%+.2f%%)",
                         b.name, b.lo, b.hi, b.n, b.ratio, b.darkening * 100,
                         b.encodedRatio, b.encodedDarkening * 100))
        }

        let dark = bands[0], mid = bands[1], fog = bands[3]
        XCTAssertGreaterThan(dark.n, 1000, "暗带必须真的采到点")
        XCTAssertGreaterThan(mid.n, 1000, "中带必须真的采到点")
        XCTAssertGreaterThan(fog.n, 1000, "雾带必须真的采到点")
        // The dark band is below the airlight but carries almost no veil: the model's own `J/I` there is
        // within a few percent of 1 (`|L − A|` is large, but the capped gain's floor is 0.4 only for the
        // pixels the veil covers, and this band is nearly black in the *input* too).
        XCTAssertLessThanOrEqual(abs(dark.darkening), 0.02,
                                 String(format: "暗带不许被压（实测 %+.2f%%）", dark.darkening * 100))
        // The verdict asks the fog to be the band that moves: on this frame it is the only band whose
        // 0.70–0.85 window is the veil itself, so "the fog is darkened" is the user-facing claim.
        XCTAssertGreaterThanOrEqual(fog.darkening, 0.10,
                                    String(format: "雾带必须真的被压暗（实测 %+.2f%%）", fog.darkening * 100))
        XCTAssertLessThanOrEqual(fog.darkening, 0.60,
                                 String(format: "雾带不许被压死（401 的 floor 是 0.4，实测 %+.2f%%）",
                                        fog.darkening * 100))
    }
}
