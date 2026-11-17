import XCTest
@testable import PhotonsCore

/// White-balance range, reciprocal slider mapping and persisted Kelvin compatibility.
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
            800 + Double(i) / 199 * (14000 - 800)
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
        // ((miredMax − mired)/span) **increases**. The owner's ask and the formula both put 800 K
        // at 0 and 14000 K at 1; what matters is that the relation is strictly one-way.
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

    func testAdjustmentRangeAndDecoderClampingAgree() {
        XCTAssertEqual(TemperatureScale.kelvinRange,800...14000)
        XCTAssertEqual(WhiteBalance.temperatureRange,TemperatureScale.kelvinRange)
        XCTAssertEqual(WhiteBalance(temperature: 300).clamped().temperature,800)
        XCTAssertEqual(WhiteBalance(temperature: 50000).clamped().temperature,14000)
        XCTAssertNil(WhiteBalance.asShot.clamped().temperature)
        XCTAssertEqual(TemperatureScale.fraction(forKelvin: 800),0)
        XCTAssertEqual(TemperatureScale.fraction(forKelvin: 14000),1)
        XCTAssertEqual(TemperatureScale.fraction(forKelvin: 5000),0.8909,accuracy: 0.001)
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
        XCTAssertEqual(TemperatureScale.quantizedKelvin(800), 800)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(14000), 14000)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(99_999), 14000)
        XCTAssertEqual(TemperatureScale.quantizedKelvin(10), 800)

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
