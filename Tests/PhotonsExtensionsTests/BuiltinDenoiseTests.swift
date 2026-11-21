import XCTest
@testable import PhotonsExtensions

/// 480 — the ported core: Anscombe, the four-plane transform, the noise estimator and two-pass NLM.
///
/// These tests are about the mathematics that makes the filter safe in highlights, not about the
/// file plumbing (that is `BuiltinDenoiseJobTests`). Every noise field is deterministic: an LCG plus
/// Box-Muller, so a failure is reproducible without a fixture.
final class BuiltinDenoiseTests: XCTestCase {

    // MARK: - deterministic noise

    private struct Noise {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func uniform() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) + 0.5) / Float(1 << 24)
        }
        mutating func normal() -> Float {
            let u = uniform(), v = uniform()
            return (-2 * logf(u)).squareRoot() * cosf(2 * .pi * v)
        }
    }

    private func spread(_ planes: [[Float]], level: Float) -> Float {
        var sum: Double = 0
        var n = 0
        for plane in planes {
            for v in plane { sum += Double((v - level) * (v - level)); n += 1 }
        }
        return Float((sum / Double(max(n, 1))).squareRoot())
    }

    // MARK: - Anscombe

    /// Round trip, unit steps at every brightness, and the plain-scaling case when `a` is zero.
    func testTheStabiliserRoundTripsAndGivesUnitNoise() {
        let s = BuiltinDenoise.Stabiliser(a: 0.01, b: 0.0005)
        for v: Float in [0, 0.01, 0.1, 0.5, 0.9] {
            let back = s.inverse(s.forward(v))
            XCTAssertLessThan(abs(back - v), 0.005 + 0.03 * v, "\(v) -> \(back)")
        }
        for v: Float in [0.05, 0.2, 0.6] {
            let sigma = (0.01 * v + 0.0005).squareRoot()
            let step = s.forward(v + sigma) - s.forward(v)
            XCTAssertLessThan(abs(step - 1), 0.15, "at \(v): \(step)")
        }
        let flat = BuiltinDenoise.Stabiliser(a: 0, b: 4e-4)
        XCTAssertEqual(flat.forward(0.1), 5, accuracy: 1e-4)
        XCTAssertEqual(flat.inverse(5), 0.1, accuracy: 1e-6)
    }

    // MARK: - four planes

    /// Applied twice gives the planes back, and it keeps their energy.
    func testTheHadamardTransformIsItsOwnInverseAndKeepsEnergy() {
        let planes: [[Float]] = (0..<4).map { c in
            (0..<9).map { i in Float(c * 9 + i) * 0.37 - 3 }
        }
        let back = BuiltinDenoise.hadamard(BuiltinDenoise.hadamard(planes))
        for (a, b) in zip(planes.joined(), back.joined()) {
            XCTAssertEqual(a, b, accuracy: 1e-4)
        }
        let energy: ([[Float]]) -> Float = { $0.joined().reduce(0) { $0 + $1 * $1 } }
        XCTAssertEqual(energy(planes), energy(BuiltinDenoise.hadamard(planes)), accuracy: 1e-2)
    }

    /// The RGB adapter's whole contract: independent unit-noise channels come out as four planes
    /// whose spread is still about 1. This is the acceptance's 「变换后方差仍均匀」.
    func testTheRGBFourPlaneAdapterKeepsUnitNoiseUniform() {
        let t = 96
        var rng = Noise(0x480)
        let level: Float = 0.4
        let rgb: [[Float]] = (0..<3).map { _ in
            (0..<(t * t)).map { _ in level + rng.normal() }
        }
        let planes = BuiltinDenoise.fourPlanesFromRGB(rgb)
        XCTAssertEqual(planes.count, 4)
        for (c, plane) in planes.enumerated() {
            let sigma = spread([plane], level: 0)
            XCTAssertEqual(sigma, 1, accuracy: 0.12, "plane \(c): \(sigma)")
        }
    }

    // MARK: - noise estimator

    /// `variance = a · signal + b` is recovered within 30 % at two brightness levels.
    func testTheNoiseEstimatorFindsPoissonGaussianNoise() {
        let (t, a, b) = (128, Float(0.004), Float(0.0004))
        var rng = Noise(7)
        let planes: [[Float]] = (0..<4).map { _ in
            (0..<(t * t)).map { i in
                let x = Float(i % t) / Float(t)
                let y = Float(i / t) / Float(t)
                let signal = 0.1 + 0.5 * x + 0.2 * y
                return signal + rng.normal() * (a * signal + b).squareRoot()
            }
        }
        let (ea, eb) = BuiltinDenoise.estimateNoise(planes: planes, t: t)
        for signal: Float in [0.15, 0.5] {
            let want = a * signal + b
            let got = ea * signal + eb
            XCTAssertLessThan(abs(got / want - 1), 0.3,
                              "at \(signal): got \(got), want \(want) (a=\(ea), b=\(eb))")
        }
    }

    /// A landscape frame is `width/2 × height/2`, not square. Passing the width as both dimensions
    /// used to skip every plane and report the minimum variance — the real-image regression this
    /// test pins. The estimator must take both sides.
    func testTheNoiseEstimatorHandlesNonSquarePlanes() {
        let (w, h, a, b) = (256, 96, Float(0.004), Float(0.0004))
        var rng = Noise(17)
        let planes: [[Float]] = (0..<4).map { _ in
            (0..<(w * h)).map { i in
                let signal = 0.1 + 0.4 * Float(i % w) / Float(w)
                return signal + rng.normal() * (a * signal + b).squareRoot()
            }
        }
        let (ea, eb) = BuiltinDenoise.estimateNoise(planes: planes, width: w, height: h)
        for signal: Float in [0.15, 0.4] {
            let want = a * signal + b
            let got = ea * signal + eb
            XCTAssertLessThan(abs(got / want - 1), 0.35, "at \(signal): \(got) vs \(want)")
        }
    }

    /// Flat noise alone comes out at the right deviation, and a clipped plane is not treated as signal.
    func testTheNoiseEstimatorSurvivesFlatDarkAndClippedPlanes() {
        let t = 96
        var rng = Noise(11)
        let sigma: Float = 0.02
        let planes: [[Float]] = (0..<4).map { _ in
            (0..<(t * t)).map { _ in 0.3 + rng.normal() * sigma }
        }
        let (a, b) = BuiltinDenoise.estimateNoise(planes: planes, t: t)
        XCTAssertEqual((a * 0.3 + b).squareRoot(), sigma, accuracy: 0.01)
        for level: Float in [0, 1] {
            let flat = [[Float]](repeating: [Float](repeating: level, count: t * t), count: 4)
            let (ca, cb) = BuiltinDenoise.estimateNoise(planes: flat, t: t)
            XCTAssertTrue(ca.isFinite && cb.isFinite && ca >= 0 && cb > 0,
                          "\(level): \(ca) \(cb)")
        }
    }

    // MARK: - the filter

    /// A noisy flat field plus a hard step: noise drops, the step survives. That is the
    /// 「高光不化开 / 纹理保留」 claim at its smallest scale.
    func testTheFilterCleansFlatNoiseAndKeepsAStep() {
        let t = 48
        var rng = Noise(3)
        let level: Float = 0.6
        let step: Float = 0.12
        let plane: [Float] = (0..<(t * t)).map { i in
            let x = i % t
            let base = x < t / 2 ? level : level + step
            return base + rng.normal() * 0.05
        }
        let input = [[Float]](repeating: plane, count: 4)
        let out = BuiltinDenoise.filter(planes: input, t: t,
                                        tuning: BuiltinDenoise.Tuning(),
                                        noise: 0.05)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].count, t * t)

        func flatSigma(_ p: [Float], rows: Range<Int>, columns: Range<Int>) -> Float {
            var sum: Double = 0, n = 0
            for y in rows {
                for x in columns {
                    let around = (p[y * t + x - 1] + p[y * t + x + 1] + p[(y - 1) * t + x] + p[(y + 1) * t + x]) / 4
                    sum += Double((p[y * t + x] - around) * (p[y * t + x] - around)); n += 1
                }
            }
            return Float((sum / Double(max(n, 1))).squareRoot())
        }
        let before = flatSigma(plane, rows: 4..<20, columns: 4..<20)
        let after = flatSigma(out[0], rows: 4..<20, columns: 4..<20)
        XCTAssertLessThan(after, before * 0.5, "noise hardly dropped: \(before) -> \(after)")

        let left = out[0][(t / 2) * t + t / 4]
        let right = out[0][(t / 2) * t + 3 * t / 4]
        XCTAssertGreaterThan(right - left, 0.8 * step, "the step was smoothed away: \(left) \(right)")
    }

    /// A cell no patch resembles is pulled towards its surroundings by the looser fallback.
    func testTheLooseFallbackPullsASpeckTowardsItsSurroundings() {
        let t = 40
        var rng = Noise(9)
        var planes: [[Float]] = (0..<4).map { _ in
            (0..<(t * t)).map { _ in 5 + rng.normal() }
        }
        let at = (t / 2) * t + t / 2
        for c in 0..<4 { planes[c][at] += 6 }
        let with = BuiltinDenoise.filter(planes: planes, t: t,
                                         tuning: BuiltinDenoise.Tuning(), noise: 0.2)
        var noLoose = BuiltinDenoise.Tuning()
        noLoose.loose = 0
        let without = BuiltinDenoise.filter(planes: planes, t: t, tuning: noLoose, noise: 0.2)
        let peak = { (p: [[Float]]) in p.map { abs($0[at] - 5) }.max() ?? 0 }
        XCTAssertLessThan(peak(with), peak(without), "\(peak(with)) vs \(peak(without))")
    }

    /// No measured noise, NaN or next to nothing still gives finite output.
    func testAPhotoWithNoMeasuredNoiseStaysFinite() {
        let t = 24
        var rng = Noise(5)
        var planes: [[Float]] = (0..<4).map { _ in (0..<(t * t)).map { _ in 5 + rng.normal() } }
        for c in 0..<4 { planes[c][t * t / 2] += 50 }
        for noise: Float in [0, .nan, 1e-9] {
            let out = BuiltinDenoise.filter(planes: planes, t: t,
                                            tuning: BuiltinDenoise.Tuning(), noise: noise)
            XCTAssertTrue(out.joined().allSatisfy(\.isFinite), "noise \(noise)")
        }
    }
}
