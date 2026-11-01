import XCTest
import Metal
@testable import PhotonsCore

/// 215 — the linear gradient is a **straight line between the two lines**.
///
/// The bug (user, 2026-11-01): "start line at 0, end line at 100 ⇒ position 10 should give 10 %
/// strength". `smoothstep(½ − f/2, ½ + f/2, t')` put the whole transition on top of the middle, so at
/// the default `f = ½` the mask was 0 for the first quarter of the span and still 0.5 at the middle.
/// The contract now is `alpha = clamp((t' + f/2)/(1 + f))` with `t' = t^(log ½ / log m)` — linear over
/// the span, the feather split *outside* the two lines. These tests are the dispatch's acceptance
/// numbers, measured on the atlas the kernel wrote (and, for the host side, on the same closed form):
///
///   1. the table: `f = 0` is `alpha = t` (10 % ⇒ 0.10), `f = 0.5` is `(t + 0.25)/1.5`;
///   2. equal steps in `t` are equal steps in alpha — no S-curve anywhere;
///   3. `t < 0` is exactly 0 and `t > 1` exactly 1; the feather's band lives outside the lines;
///   4. the midpoint still moves the 50 % crossing: `m = 0.3` ⇒ α = 0.5 at `t = 0.3`;
///   5. host reference and atlas agree to one 8-bit code, pixel by pixel;
///   6. `MaskBounds.sourceExtent` starts at the **start line** (it used to start at `½ − f/2`).
final class MaskLinearRampTests: XCTestCase {

    // MARK: - fixtures

    private let width = 64
    private let height = 1201
    /// The two lines sit at 20 % and 80 % of the frame, so pixels exist on **both** sides of the span
    /// (`t < 0` above the start line, `t > 1` below the end line) — the feather's band needs them.
    private let startY = 0.2
    private let endY = 0.8

    private var startPx: Double { startY * Double(height) }
    private var spanPx: Double { (endY - startY) * Double(height) }

    private func shape(midpoint: Double = 0.5) -> LinearGradientShape {
        LinearGradientShape(start: NormalizedPoint(0.5, startY), end: NormalizedPoint(0.5, endY),
                            midpoint: midpoint)
    }

    /// The row whose pixel centre sits closest to `t`.
    private func row(_ t: Double) -> Int { Int((startPx + t * spanPx - 0.5).rounded()) }
    /// The projection of a pixel centre, exactly as the kernel computes it (unclamped).
    private func t(_ y: Int) -> Double { (Double(y) + 0.5 - startPx) / spanPx }

    private func flatImage() -> LinearImage {
        let n = width * height
        var rgba = [Float16](repeating: 0, count: n * 4)
        for i in 0..<n {
            rgba[i * 4] = Float16(0.3)
            rgba[i * 4 + 1] = Float16(0.3)
            rgba[i * 4 + 2] = Float16(0.3)
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-215")
    }

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "mask-linear-ramp"))
    }

    private func atlas(feather: Double, midpoint: Double = 0.5) throws -> MaskAtlasDump {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-lin", opacity: 1, feather: 0, refine: 0,
                           components: [MaskComponent(id: "c", feather: feather,
                                                      shape: .linearGradient(shape(midpoint: midpoint)))],
                           adjustments: LocalAdjustments(exposure: 0.5))]
        let graph = try makeGraph(flatImage())
        return try XCTUnwrap(try graph.maskAtlas(edit, options: RenderOptions(scale: 1)))
    }

    private func sample(_ dump: MaskAtlasDump, _ y: Int) -> Double {
        Double(dump.value(slice: 0, x: width / 2, y: y) ?? -1)
    }

    // MARK: - the host reference (mirrors the kernel's algebra expression for expression)

    private func alpha(_ t: Double, feather f: Double, midpoint m: Double) -> Double {
        let mm = min(max(m, 0.02), 0.98)
        var tp = t
        if abs(mm - 0.5) > 1e-6 && t > 0 { tp = pow(t, log(0.5) / log(mm)) }
        let ff = min(max(f, 0), 1)
        return min(max((tp + 0.5 * ff) / (1 + ff), 0), 1)
    }

    // MARK: - 1. the numeric table

    /// Acceptance 1. The closed form is asserted to 1e−12 (so a change of formula cannot hide), the
    /// atlas to one 8-bit code (it stores R16F, half a code at 0.5).
    func testLinearRampNumericTable() throws {
        let probes = [0.1, 0.25, 0.5, 0.75, 0.9]
        for f in [0.0, 0.5] {
            let dump = try atlas(feather: f)
            var table: [String] = []
            for wanted in probes {
                let y = row(wanted)
                let measured = t(y)
                XCTAssertEqual(measured, wanted, accuracy: 1 / spanPx, "the probe row is off the requested t")
                let expected = f == 0 ? measured : (measured + 0.25) / 1.5
                let cpu = alpha(measured, feather: f, midpoint: 0.5)
                XCTAssertEqual(cpu, expected, accuracy: 1e-12,
                               "f = \(f): the host mirror must be the closed form")
                XCTAssertLessThanOrEqual(abs(sample(dump, y) - cpu), 1.0 / 256.0,
                                         "f = \(f), t = \(measured): atlas disagrees with the closed form")
                table.append(String(format: "%.2f→%.4f", wanted, sample(dump, y)))
            }
            print("215 TABLE f=\(f): " + table.joined(separator: " · "))
        }
    }

    // MARK: - 2. linear, not an S-curve

    /// Acceptance 2: every 40-px step inside the span moves the coverage by the same amount —
    /// `40 / (span · (1 + f))`. A `smoothstep` flattens at both ends, which is the bug.
    func testLinearRampHasEqualSteps() throws {
        for f in [0.0, 0.5] {
            let dump = try atlas(feather: f)
            let step = Double(40)
            let ideal = step / (spanPx * (1 + f))
            var deltas: [Double] = []
            for y in stride(from: row(0.05), through: row(0.95) - Int(step), by: Int(step)) {
                deltas.append(sample(dump, y + Int(step)) - sample(dump, y))
            }
            XCTAssertGreaterThan(deltas.count, 10, "the fixture must give enough steps to judge")
            for (i, delta) in deltas.enumerated() {
                XCTAssertEqual(delta, ideal, accuracy: 2.0 / 256.0,
                               "f = \(f): step \(i) is \(delta), the linear ramp is \(ideal)")
            }
            // Second difference: zero is exactly "linear". Kept separate from the tolerance above so a
            // consistent bias in the atlas' own reading cannot pass as a constant slope.
            for i in 1..<deltas.count {
                XCTAssertEqual(deltas[i], deltas[i - 1], accuracy: 1.0 / 256.0,
                               "f = \(f): the slope changes at step \(i) — that is an S-curve")
            }
        }
    }

    // MARK: - 3. the ends

    /// Acceptance 3: `f = 0` is a hard 0 below the start line and a hard 1 past the end line, and a
    /// feather puts its transition **outside** those lines (`t = −f/2` is where it reaches 0).
    func testLinearRampEndsAreOutsideTheTwoLines() throws {
        let hard = try atlas(feather: 0)
        for y in 0...row(-0.005) {
            XCTAssertEqual(sample(hard, y), 0, "t = \(t(y)) < 0 must be exactly 0")
        }
        for y in row(1.005)...(height - 1) {
            XCTAssertEqual(sample(hard, y), 1, "t = \(t(y)) > 1 must be exactly 1")
        }

        let soft = try atlas(feather: 0.5)
        for wanted in [-0.2, -0.1, -0.01] {
            let y = row(wanted)
            let expected = alpha(t(y), feather: 0.5, midpoint: 0.5)
            XCTAssertGreaterThan(expected, 0, "the probe must sit inside the outward band")
            XCTAssertLessThanOrEqual(abs(sample(soft, y) - expected), 1.0 / 256.0,
                                     "t = \(t(y)): the band must ramp outside the line, not stay at 0")
        }
        for wanted in [1.01, 1.1, 1.2] {
            let y = row(wanted)
            let expected = alpha(t(y), feather: 0.5, midpoint: 0.5)
            XCTAssertLessThan(expected, 1, "the probe must sit inside the outward band")
            XCTAssertLessThanOrEqual(abs(sample(soft, y) - expected), 1.0 / 256.0,
                                     "t = \(t(y)): the band must ramp outside the line, not saturate")
        }
    }

    // MARK: - 4. the midpoint

    /// Acceptance 4: `t' = t^(log ½ / log m)` is unchanged, so `m = 0.3` still crosses 50 % at
    /// `t = 0.3` — with and without a feather (the band is symmetric about that crossing).
    func testMidpointStillPutsHalfCoverageAtM() throws {
        for f in [0.0, 0.5] {
            let dump = try atlas(feather: f, midpoint: 0.3)
            let y = row(0.3)
            XCTAssertEqual(t(y), 0.3, accuracy: 0.002)
            XCTAssertEqual(sample(dump, y), 0.5, accuracy: 0.01,
                           "f = \(f): m = 0.3 must put 50 % coverage at t = 0.3")
            XCTAssertEqual(alpha(0.3, feather: f, midpoint: 0.3), 0.5, accuracy: 1e-12)
        }
    }

    // MARK: - 5. host vs atlas

    /// Acceptance 5: the host reference and the atlas can differ by at most one 8-bit code at **every**
    /// row, for four feathers and three midpoints. This is the "two copies of the arithmetic" guard —
    /// a `MaskBounds`/host change that forgets the kernel (or the other way round) lands here.
    func testHostReferenceAndAtlasAgreeToOneCode() throws {
        for f in [0.0, 0.2, 0.5, 1.0] {
            for m in [0.5, 0.3, 0.75] {
                let dump = try atlas(feather: f, midpoint: m)
                var worst = 0.0
                for y in 0..<height {
                    worst = max(worst, abs(alpha(t(y), feather: f, midpoint: m) - sample(dump, y)))
                }
                XCTAssertLessThanOrEqual(worst, 1.0 / 256.0, "f = \(f), m = \(m): worst \(worst)")
            }
        }
    }

    // MARK: - 6. bounds

    /// Acceptance 6 (and the regression the old `lo = ½ − f/2` caused): the support starts at the
    /// **start line** whatever the feather, and every pixel with `alpha > 0` is inside the bound.
    func testBoundsStartAtTheStartLine() throws {
        let source = ImageSize(width: width, height: height)
        for f in [0.0, 0.5, 1.0] {
            let component = MaskComponent(id: "c", feather: f, shape: .linearGradient(shape()))
            let extent = try XCTUnwrap(MaskBounds.sourceExtent(of: component, source: source))
            XCTAssertEqual(extent.x0, 0, "the ramp covers the full width")
            XCTAssertEqual(extent.x1, width)
            // The band reaches 0 at `y = startPx − f/2·span`; it is clipped to the frame, so the bound
            // is the larger of that and 0.
            let bandStart = max(0, startPx - 0.5 * f * spanPx)
            XCTAssertLessThanOrEqual(abs(Double(extent.y0) - bandStart), 1.5,
                                     "f = \(f): the support must begin where the band reaches 0 "
                                     + "(y = \(bandStart))")
            XCTAssertEqual(extent.y1, height, "the ramp runs to the end of the frame")

            let dump = try atlas(feather: f)
            var outside = 0
            for y in 0..<height where sample(dump, y) > 0 && !(extent.y0 <= y && y < extent.y1) {
                outside += 1
            }
            XCTAssertEqual(outside, 0, "f = \(f): \(outside) covered rows lie outside the declared bound")
        }
    }
}
