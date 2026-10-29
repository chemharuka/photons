import XCTest
import PhotonsCore

/// 112 — the export's SDR tone map: `-r` samples the peak, `-R` caps the headroom, and
/// `CIToneMapHeadroom` does the roll-off. `.none` stays the historical hard clamp.
final class SDRToneMapTests: XCTestCase {

    // MARK: fixtures

    private func makePixels(_ width: Int, _ height: Int,
                            _ body: (Int, Int) -> (Float, Float, Float)) -> LinearPixels {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r)
                rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b)
                rgba[o + 3] = 1
            }
        }
        return LinearPixels(width: width, height: height, rgba: rgba, primaries: .sRGB)
    }

    /// The 8-bit code `Exporter.cgImage` would write for an encoded value.
    private func code8(_ value: Float16) -> Int {
        Int(min(max(Float(value), 0), 1) * 255 + 0.5)
    }

    private func srgbOETF(_ linear: Float) -> Float {
        let v = min(max(linear, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    private func linearFromOETF(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : powf((encoded + 0.055) / 1.055, 2.4)
    }

    // MARK: 1 — .none is the byte-identical hard clamp

    func testNoneIsTheHistoricalHardClamp() {
        let values: [Float] = [-0.2, 0, 0.18, 0.5, 0.735, 1, 1.0001, 2.14, 4.41]
        let image = LinearPixels(
            width: values.count, height: 1,
            rgba: values.flatMap { v in [Float16(v), Float16(v), Float16(v), Float16(0.7)] },
            primaries: .sRGB)
        let out = image.displaySDR(bitDepth: 8)

        for (i, v) in values.enumerated() {
            let expected = Float16(srgbOETF(v)).bitPattern
            XCTAssertEqual(out.rgba[i * 4].bitPattern, expected,
                           "R for linear \(v) must be the S4 clamp + OETF")
        }
        XCTAssertEqual(code8(out.rgba[2 * 4]), 118, "linear 0.18 is code 118")
        XCTAssertEqual(code8(out.rgba[3 * 4]), 188, "linear 0.5 is code 188")
        XCTAssertEqual(code8(out.rgba[7 * 4]), 255, "anything above 1 hard-clips")
        // Alpha is copied verbatim, not encoded.
        XCTAssertEqual(out.rgba[3].bitPattern, Float16(0.7).bitPattern)
    }

    // MARK: 2 — .global rolls the highlights into display white

    func testGlobalToneMapMeetsTheHighlightBudget() throws {
        if #unavailable(macOS 15.0) {
            throw XCTSkip("CIToneMapHeadroom — the system global tone map — is macOS 15+")
        }
        // A frame shaped like the measured +2 EV fixture: 20 % above display white, 95 % of that
        // energy just above 1, and a tiny specular block at 4.41 that must not own the whole range.
        let w = 200, h = 200, n = w * h
        let hot = 20                     // 0.05 % at the peak
        let shoulder = 40                // next 0.05 %: 2.0 …
        let image = makePixels(w, h) { x, y in
            let i = y * w + x
            let v: Float
            if i < hot {
                v = 4.41
            } else if i < hot + shoulder {
                v = 2.0 - 0.2 * Float(i - hot) / Float(shoulder)
            } else if i < n / 5 {
                v = 2.0 - 1.0 * Float(i - hot - shoulder) / Float(n / 5 - hot - shoulder)
            } else {
                v = 0.02 + 0.98 * Float(i - n / 5) / Float(n - n / 5)
            }
            return (v, v, v)
        }

        let hard = image.displaySDR(bitDepth: 8)
        let mapped = image.displaySDR(bitDepth: 8, toneMap: .global)
        let hardCodes = hard.rgba.map(code8)
        let mappedCodes = mapped.rgba.map(code8)

        var rgb: [Int] = []
        rgb.reserveCapacity(n * 3)
        var clipped = 0
        for i in stride(from: 0, to: mappedCodes.count, by: 4) {
            for c in 0..<3 {
                rgb.append(mappedCodes[i + c])
                if mappedCodes[i + c] == 255 { clipped += 1 }
            }
        }
        let clipRatio = Double(clipped) / Double(n * 3)
        XCTAssertLessThanOrEqual(clipRatio, 0.0005,
                                 "==255 must fall to ≤0.05 % (got \(clipRatio * 100) %)")
        XCTAssertGreaterThan(Double(hardCodes.filter { $0 == 255 }.count) / Double(n * 3), 0.15,
                             "the fixture must really exercise the hard clip")

        let sorted = rgb.sorted()
        let p999 = sorted[Int(Double(sorted.count - 1) * 0.999)]
        XCTAssertGreaterThanOrEqual(p999, 240, "p99.9 must leave pure white (got \(p999))")
        // The system curve lands the top of the measured +1 EV band one code above the old
        // custom-shoulder prediction (251 vs 250); that prediction expired with the shoulder.
        XCTAssertLessThanOrEqual(p999, 252, "p99.9 must leave pure white (got \(p999))")
    }

    // MARK: 3 — mid-grey moves with the system curve, but stays ordered
    //
    /// §4#3's "≤1 code" prediction was written for the custom shoulder §1 voided. Core Image's
    /// global map normalises the *whole* frame to the measured headroom, so the anchors move down
    /// with it (measured on this machine: 0.18 −25 codes, 0.5 −43 at a 4.4× peak). What the system
    /// curve does promise — and what the export relies on — is that they stay ordered and do not
    /// collapse into the shadows.
    func testMidGreyAnchorsMoveWithTheSystemCurveAndStayOrdered() throws {
        if #unavailable(macOS 15.0) { throw XCTSkip("CIToneMapHeadroom is macOS 15+") }
        var rgba = [Float16](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let v: Float
                switch (x / 8, y / 8) {
                case (0, 0): v = 0.18
                case (1, 0): v = 0.5
                case (2, 0), (3, 0): v = 4.4       // the peak that puts the map to work
                default: v = 0.02
                }
                let o = (y * 64 + x) * 4
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        let image = LinearPixels(width: 64, height: 64, rgba: rgba, primaries: .sRGB)
        let hard = image.displaySDR(bitDepth: 8)
        let mapped = image.displaySDR(bitDepth: 8, toneMap: .global)

        let hard18 = code8(hard.rgba[(4 * 64 + 4) * 4])
        let hard50 = code8(hard.rgba[(4 * 64 + 12) * 4])
        let mapped18 = code8(mapped.rgba[(4 * 64 + 4) * 4])
        let mapped50 = code8(mapped.rgba[(4 * 64 + 12) * 4])

        XCTAssertEqual(hard18, 118)
        XCTAssertEqual(hard50, 188)
        XCTAssertLessThan(mapped18, hard18, "the global map darkens the whole frame, not only >1")
        XCTAssertLessThan(mapped50, hard50)
        XCTAssertLessThan(mapped18, mapped50, "grey ordering must survive")
        XCTAssertGreaterThanOrEqual(mapped18, 60, "0.18 must not collapse into the shadows")
        XCTAssertLessThanOrEqual(hard18 - mapped18, 40, "0.18 moved further than the system curve")
        XCTAssertLessThanOrEqual(hard50 - mapped50, 50, "0.5 moved further than the system curve")
    }

    // MARK: 3b — the two knobs are the ones toGainMapHDR exposes

    func testMeasurementRatioAndMaxHeadroomReallySteerTheMap() throws {
        if #unavailable(macOS 15.0) { throw XCTSkip("CIToneMapHeadroom is macOS 15+") }
        let w = 300, h = 300
        var rgba = [Float16](repeating: 0.18, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4 + 3] = 1 }
        // One hot texel at 20×: `-r` should ignore it, `-r 1` should not.
        let hot = (151 * w + 137) * 4
        rgba[hot] = 20; rgba[hot + 1] = 20; rgba[hot + 2] = 20
        let image = LinearPixels(width: w, height: h, rgba: rgba, primaries: .sRGB)
        let probe = (151 * w + 10) * 4

        let hard = image.displaySDR(bitDepth: 8)
        let fine = image.displaySDR(bitDepth: 8,
                                    toneMap: SDRToneMap(measurementRatio: 1, maxHeadroom: 100))
        let coarse = image.displaySDR(bitDepth: 8,
                                      toneMap: SDRToneMap(measurementRatio: 100, maxHeadroom: 100))
        XCTAssertLessThan(code8(fine.rgba[probe]), code8(hard.rgba[probe]))
        XCTAssertEqual(code8(coarse.rgba[probe]), code8(hard.rgba[probe]),
                       "-r 100 must ignore the one hot texel and take the hard-clamp path")

        let capped = image.displaySDR(bitDepth: 8,
                                      toneMap: SDRToneMap(measurementRatio: 1, maxHeadroom: 2))
        XCTAssertGreaterThan(code8(capped.rgba[probe]), code8(fine.rgba[probe]),
                             "-R 2 must spend less headroom than -R 100")

        let clamped = SDRToneMap(measurementRatio: 0.5, maxHeadroom: 0.1)
        XCTAssertEqual(clamped.measurementRatio, 1)
        XCTAssertEqual(clamped.maxHeadroom, 1)
    }

    // MARK: 4 — the neutral-document gate

    func testFrameBelowOnePointZeroFiveIsByteIdenticalToNone() {
        let image = makePixels(32, 32) { x, y in
            // Peak 1.04, i.e. below toGainMapHDR's 1.05 SDR threshold.
            let v = 1.04 * Float((x + y) % 32) / 31
            return (v, v, v)
        }
        let hard = image.displaySDR(bitDepth: 8)
        let global = image.displaySDR(bitDepth: 8, toneMap: .global)
        XCTAssertEqual(hard.rgba.map(\.bitPattern), global.rgba.map(\.bitPattern),
                       "P < 1.05 must take the hard-clamp path even when .global is selected")
    }

    // MARK: 5 — monotonic in, monotonic out

    func testToneMapIsMonotonicOverTheWholeHDRRange() throws {
        if #unavailable(macOS 15.0) { throw XCTSkip("CIToneMapHeadroom is macOS 15+") }
        let image = makePixels(512, 8) { x, y in
            // 256 SDR steps 0…1, then a logarithmic ramp to +6 EV (64×).
            let v: Float = x < 256
                ? Float(x) / 255
                : powf(2, 6 * Float(x - 255) / 256)
            return (v, v, v)
        }
        let mapped = image.displaySDR(bitDepth: 8, toneMap: .global)
        var previous = -1
        for x in 0..<512 {
            let code = code8(mapped.rgba[(4 * 512 + x) * 4])
            XCTAssertGreaterThanOrEqual(code, previous, "code at x=\(x) went backwards")
            previous = code
        }
    }

    // MARK: 6 — hue is preserved

    func testSaturatedPatchesKeepTheirHue() throws {
        if #unavailable(macOS 15.0) { throw XCTSkip("CIToneMapHeadroom is macOS 15+") }
        let patches: [(String, (Float, Float, Float))] = [
            ("R", (2.0, 0.15, 0.15)),
            ("G", (0.15, 2.0, 0.15)),
            ("B", (0.15, 0.15, 2.0)),
            ("Y", (2.0, 2.0, 0.15)),
            ("C", (0.15, 2.0, 2.0)),
            ("M", (2.0, 0.15, 2.0)),
        ]
        let image = makePixels(8, 8) { x, _ in
            if x < patches.count { return patches[x].1 }
            return x == 7 ? (2.5, 2.5, 2.5) : (0.18, 0.18, 0.18)
        }
        let mapped = image.displaySDR(bitDepth: 16, toneMap: .global)

        for (name, input) in patches {
            let x = patches.firstIndex { $0.0 == name }!
            let o = (4 * 8 + x) * 4
            let out = (Float(mapped.rgba[o]), Float(mapped.rgba[o + 1]),
                       Float(mapped.rgba[o + 2]))
            let expected = hueAngle(input)
            let actual = hueAngle((linearFromOETF(out.0), linearFromOETF(out.1),
                                   linearFromOETF(out.2)))
            var delta = abs(expected - actual)
            delta = min(delta, 360 - delta)
            XCTAssertLessThanOrEqual(delta, 1.0,
                                     "\(name) hue moved \(delta)° (in \(expected), out \(actual))")
        }
    }

    /// Hue angle in `Yxy`, measured around the D65 white point.
    private func hueAngle(_ rgb: (Float, Float, Float)) -> Float {
        let (r, g, b) = rgb
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let sum = x + y + z
        guard sum > 0 else { return 0 }
        let cx = x / sum, cy = y / sum
        return atan2(cy - 0.3290, cx - 0.3127) * 180 / .pi
    }
}
