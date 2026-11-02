import XCTest
@testable import PhotonsCore

/// 派单 242 — **the mired slider's properties, as arithmetic**.
///
/// The owner's two constraints are the whole contract: the temperature ceiling is 50000 K, but the
/// track cannot be linear Kelvin or 12000–50000 K would eat 80 % of it. So:
///
///   · **left = 2000 K** (`fraction 0`), **right = 50000 K** (`fraction 1`);
///   · the position in between is uniform in **mired** (10⁶/T), which is the perceptual spacing;
///   · the document is still Kelvin — `TemperatureScale` is the control's coordinate only, and
///     `WhiteBalance.quantized()` writes Kelvin back.
///
/// Test ④ is the reverse gate: a linear-Kelvin mapping fails the 5000 K / 12000 K assertions by more
/// than half the track, so the test cannot pass by accident if someone "simplifies" the scale back.
final class WhiteBalanceRangeTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/PhotonsCoreTests/WhiteBalanceRangeTests.swift
            .deletingLastPathComponent()     // Tests/PhotonsCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // repo root
    }

    /// 200 points across the whole travel, endpoints included.
    private func samplePoints() -> [Double] {
        (0...199).map { i in
            2000 + Double(i) / 199 * (50000 - 2000)
        }
    }

    // MARK: - ① round trip

    func testKelvinFractionKelvinRoundTripsWithinOneKelvin() {
        var worst = 0.0
        for kelvin in samplePoints() {
            let back = TemperatureScale.kelvin(forFraction: TemperatureScale.fraction(forKelvin: kelvin))
            worst = max(worst, abs(back - kelvin))
            XCTAssertEqual(back, kelvin, accuracy: 1,
                           "\(kelvin) K → fraction → \(back) K")
        }
        print(String(format: "242 ① round trip: 200 points, worst error %.6f K", worst))
    }

    // MARK: - ② monotonic

    func testFractionIsStrictlyMonotonicInKelvin() {
        // 242: the *mired* coordinate decreases as Kelvin rises, so the fraction
        // ((miredMax − mired)/span) **increases**. The owner's ask and the formula both put 2000 K
        // at 0 and 50000 K at 1; what matters is that the relation is strictly one-way.
        let points = samplePoints()
        for i in 1..<points.count {
            let cooler = TemperatureScale.fraction(forKelvin: points[i - 1])
            let warmer = TemperatureScale.fraction(forKelvin: points[i])
            XCTAssertGreaterThan(warmer, cooler,
                                 "\(points[i - 1]) K (\(cooler)) → \(points[i]) K (\(warmer)) "
                                 + "is not strictly increasing")
        }
        print("242 ② monotonic: fraction strictly increases over 200 points")
    }

    // MARK: - ③ equal mired steps

    func testAdjacentMiredStepsHaveTheSameFractionSpacing() {
        let expected = 1 / (TemperatureScale.miredMax - TemperatureScale.miredMin)
        var worstRelative = 0.0
        for mired in stride(from: 100.0, through: 400.0, by: 7) {
            let warm = TemperatureScale.fraction(forKelvin: 1_000_000 / mired)
            let cool = TemperatureScale.fraction(forKelvin: 1_000_000 / (mired + 1))
            let delta = warm - cool
            worstRelative = max(worstRelative, abs(delta - expected) / expected)
            XCTAssertEqual(delta, expected, accuracy: expected * 0.001,
                           "mired \(mired) → \(mired + 1) moved \(delta), expected \(expected)")
        }
        print(String(format: "242 ③ equal mired steps: worst relative error %.6f%%",
                     worstRelative * 100))
    }

    // MARK: - ④ the owner's key points (and the linear-map reverse gate)

    func testKeyPointsPut2000AtTheLeftAnd50000AtTheRight() {
        let points: [(kelvin: Double, fraction: Double)] = [
            (2000, 0.000),
            (5000, 0.625),
            (12000, 0.868),
            (50000, 1.000),
        ]
        for point in points {
            XCTAssertEqual(TemperatureScale.fraction(forKelvin: point.kelvin), point.fraction,
                           accuracy: 0.01,
                           "\(point.kelvin) K must sit at \(point.fraction)")
        }

        let highEnd = TemperatureScale.fraction(forKelvin: 50000)
            - TemperatureScale.fraction(forKelvin: 12000)
        XCTAssertLessThanOrEqual(highEnd, 0.15,
                                 "12000–50000 K takes \(highEnd) of the track; the cap is 15 %")

        // Reverse gate: if this mapping were linear Kelvin, these three would be the values, and
        // every key-point assertion above would fail by far more than its 0.01 tolerance.
        func linear(_ kelvin: Double) -> Double { (kelvin - 2000) / (50000 - 2000) }
        XCTAssertGreaterThan(abs(linear(5000) - 0.625), 0.5)
        XCTAssertGreaterThan(abs(linear(12000) - 0.868), 0.5)
        XCTAssertGreaterThan(abs(linear(20000) - TemperatureScale.fraction(forKelvin: 20000)), 0.5)

        print(String(format: "242 ④ key points: 2000→0 · 5000→%.3f · 12000→%.3f · 50000→%.3f "
                     + "· 12000–50000 = %.1f%% of the track",
                     TemperatureScale.fraction(forKelvin: 5000),
                     TemperatureScale.fraction(forKelvin: 12000),
                     TemperatureScale.fraction(forKelvin: 50000),
                     highEnd * 100))
    }

    // MARK: - ⑤ quantization

    func testQuantizationIsIdempotentAndMiredSized() {
        for kelvin in samplePoints() {
            let once = TemperatureScale.quantizedKelvin(kelvin)
            let twice = TemperatureScale.quantizedKelvin(once)
            XCTAssertEqual(twice, once, "quantizing \(kelvin) K twice moved it")
            XCTAssertEqual(once, once.rounded(), "the document should hold a whole Kelvin value")
            XCTAssertTrue(TemperatureScale.kelvinRange.contains(once))
        }

        // One mired at 5000 K is ~25 K on either side (±30 % is the task's tolerance).
        let at5000 = TemperatureScale.quantizedKelvin(5000)
        let cooler = TemperatureScale.quantizedKelvin(1_000_000 / 201)   // next mired down
        let warmer = TemperatureScale.quantizedKelvin(1_000_000 / 199)   // next mired up
        XCTAssertEqual(abs(at5000 - cooler), 25, accuracy: 25 * 0.30,
                       "one mired below 5000 K is \(at5000 - cooler) K")
        XCTAssertEqual(abs(warmer - at5000), 25, accuracy: 25 * 0.30,
                       "one mired above 5000 K is \(warmer - at5000) K")

        // Endpoints stay exact, and a value beyond them clamps onto the endpoint, not onto a mired
        // value outside the travel.
        XCTAssertEqual(TemperatureScale.quantizedKelvin(2000), 2000)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(50000), 50000)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(99_999), 50000)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(10), 2000)

        print("242 ⑤ quantization: idempotent over 200 points · 5000 K step "
              + "\(at5000 - cooler) K / \(warmer - at5000) K")
    }

    // MARK: - the existing documents

    /// 242 changed the quantization grid, **not the read path**. An old document's Kelvin is decoded
    /// and displayed exactly as it was written; only a gesture puts it on the mired grid.
    func testExistingFixtureTemperaturesReadBackUnchanged() throws {
        let push = Self.repoRoot.appendingPathComponent("Tests/Fixtures/edit-push.json")
        guard FileManager.default.fileExists(atPath: push.path) else {
            throw XCTSkip("fixture missing at \(push.path)")
        }
        let edited = try EditModel.load(from: push)
        XCTAssertEqual(edited.light.temperature, 7150,
                       "the fixture's 7150 K must read back unchanged")
        XCTAssertEqual(edited.light.whiteBalance.temperature, 7150)

        let neutral = try EditModel.load(
            from: Self.repoRoot.appendingPathComponent("Tests/Fixtures/edit-neutral.json"))
        XCTAssertNil(neutral.light.temperature, "as shot stays as shot")

        // The grid would move 7150 only when a gesture commits it; that is the documented behaviour.
        XCTAssertEqual(TemperatureScale.quantizedKelvin(7150), 7143)

        print("242 fixtures with temperature: edit-push.json = 7150 K (read back 7150) · "
              + "edit-neutral.json = as shot · gesture grid would snap 7150 → 7143")
    }
}
