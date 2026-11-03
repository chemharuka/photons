import XCTest
import Metal
import PhotonsCore

/// 262 — C4: the source **choice** now also looks at the disk, not only at the rim.
///
/// The two synthetic cases are built so the *rim* cannot tell the candidates apart:
///
///  - one candidate whose ring is in phase but whose disk is shifted by 4 px (the L3 failure:
///    「环带一致但相位错位」);
///  - one candidate whose ring is a perfect match but whose disk is flat (the 「平坦/糊掉」 source).
///
/// In both, the bad candidate is the farther (`4r`) one, so the pre-262 far-first tie rule picks
/// it: the tests measure the rendered disk, not just an internal number. The reverse gates run the
/// same search with phase alignment or the variance penalty switched off and assert that the good
/// answer does **not** come back — a green test that would also pass with the feature disabled is
/// not evidence.
final class HealPhaseAlignmentTests: XCTestCase {

    // MARK: - fixtures

    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    private struct Fixture {
        let image: LinearImage
        let clean: LinearImage
        let center: (x: Double, y: Double)
        let radiusPx: Double
    }

    /// A synthetic picture with **disjoint** painted patches: the destination, one `4r` candidate
    /// whose rim matches but whose disk is 4 px out of phase (or flat), and — for the variance
    /// fixture only — a textured `3⅓ r` candidate. Everything else is the flat 0.45 wall.
    ///
    /// The rim depends only on **y** (a per-row hash) and the disk only on **x** (8 px period).
    /// The `4r` candidate sits on the destination's row, so its rim is identical at full resolution
    /// and on the coarse grid; moving its centre 4 px in x fixes the disk and leaves the rim
    /// untouched. This is the cleanest way to separate "rim aligned" from "disk aligned" without a
    /// second texture that would accidentally match somewhere else in the band.
    private func makeFixture(phaseBump: Bool, flatDisk: Bool) -> Fixture {
        let width = 1200, height = 900
        let radius = 0.02
        let radiusPx = radius * Double(min(width, height))        // 18 px
        let center = (x: Double(width) / 2, y: Double(height) / 2)
        // The rim varies with **y** (a per-row hash) and the disk with **x** (8 px period). The bad
        // candidate sits on the same row as the destination, so its rim matches exactly at full
        // resolution *and* on the coarse grid (the y quantisation is identical). The disk is 4 px
        // out of phase; moving the centre 4 px in x fixes the disk and leaves the y-only rim
        // untouched — the cleanest way to separate "rim aligned" from "disk aligned".
        // Paint a little wider than the candidate patch (1.5 r): the rim sample at 1.47 r must not
        // round one texel past the painted edge, or the measurement would see the flat wall instead
        // of the texture (that rounding is exactly the 1-texel mismatch this fixture must avoid).
        let paintRadius = 1.6 * radiusPx
        // Phase fixture: one 4r candidate. Variance fixture: the flat 4r candidate on the right and
        // a textured 3⅓ r candidate on the left (the old rule picks the farther one).
        let bad = (x: center.x + 4 * radiusPx, y: center.y)
        let badPaintRadius = 1.8 * radiusPx
        let good = (x: center.x - (2.0 + 4.0 / 3.0) * radiusPx, y: center.y)

        // A per-row pseudo-random rim: no period means no accidental phase match at another row,
        // while a candidate on the destination's row sees the identical samples.
        func ringTexture(_ v: Double) -> Double {
            0.45 + 0.05 * (2.0 * Self.hash01(0, Int(v.rounded())) - 1.0)
        }
        func diskTexture(_ u: Double) -> Double {
            0.45 + 0.02 * sin(2.0 * Double.pi * u / 8.0)
        }

        func paint(_ px: Double, _ py: Double, at p: (x: Double, y: Double),
                   diskShift: Double, radius: Double = paintRadius) -> Double? {
            let dx = px - p.x
            let dy = py - p.y
            let d = (dx * dx + dy * dy).squareRoot()
            guard d < radius else { return nil }
            return d < 0.98 * radiusPx ? diskTexture(dx + diskShift) : ringTexture(dy)
        }

        func build(blemished: Bool) -> LinearImage {
            var rgba = [Float16](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let px = Double(x) + 0.5
                    let py = Double(y) + 0.5
                    var value = 0.45

                    let dC = ((px - center.x) * (px - center.x)
                        + (py - center.y) * (py - center.y)).squareRoot()
                    if let painted = paint(px, py, at: center, diskShift: 0) {
                        value = painted
                        if blemished, dC < 0.9 * radiusPx { value *= 0.97 }
                    } else if let painted = paint(px, py, at: bad,
                                                  diskShift: phaseBump ? -4 : 0,
                                                  radius: badPaintRadius) {
                        let dB = ((px - bad.x) * (px - bad.x)
                            + (py - bad.y) * (py - bad.y)).squareRoot()
                        value = (flatDisk && dB < 0.98 * radiusPx) ? 0.45 : painted
                    } else if flatDisk, let painted = paint(px, py, at: good, diskShift: 0) {
                        value = painted
                    }
                    let o = (y * width + x) * 4
                    rgba[o] = Float16(value)
                    rgba[o + 1] = Float16(value)
                    rgba[o + 2] = Float16(value)
                    rgba[o + 3] = 1
                }
            }
            return LinearImage(width: width, height: height, rgba: rgba,
                               colorSpace: "extendedLinearSRGB",
                               decoderVersion: "synthetic-heal-phase")
        }

        return Fixture(image: build(blemished: true),
                       clean: build(blemished: false),
                       center: center,
                       radiusPx: radiusPx)
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 8,
                                                            headroom: 1, linearOutput: true),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private func rmseDisk(_ a: DisplayImage, _ b: DisplayImage,
                          center: (x: Double, y: Double), radiusPx: Double) -> Double {
        var sum = 0.0
        var n = 0
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                guard (dx * dx + dy * dy).squareRoot() < 0.9 * radiusPx else { continue }
                let o = (y * a.width + x) * 4
                for c in 0..<3 {
                    let diff = Double(a.rgba[o + c]) - Double(b.rgba[o + c])
                    sum += diff * diff
                }
                n += 3
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Render a spot with `offset` on the blemished fixture and measure the disk against the clean
    /// one. Throws `XCTSkip` when this machine has no Metal device.
    private func renderedRMSE(_ fixture: Fixture, offset: NormalizedPoint) throws -> Double {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let radius = 0.02
        let graph = try RenderGraph(input: RenderInput(image: fixture.image,
                                                       identity: "heal-phase-render"))
        let reference = try display(try RenderGraph(input: RenderInput(image: fixture.clean,
                                                                      identity: "heal-phase-clean")),
                                    EditModel.neutral)
        var doc = EditModel.neutral
        doc.healSpots = [HealSpot(center: NormalizedPoint(0.5, 0.5), radius: radius,
                                  sourceOffset: offset, mode: .heal,
                                  feather: HealSpot.defaultFeather)]
        return rmseDisk(try display(graph, doc), reference,
                        center: fixture.center, radiusPx: fixture.radiusPx)
    }

    // MARK: - 1. phase alignment

    /// **Periodic texture, ring in phase, disk 4 px out.** Phase off → the 4r candidate; phase on →
    /// a disk-aligned candidate. The rendered disk residual must at least halve.
    func testPhaseAlignmentHalvesTheDiskResidual() throws {
        let fixture = makeFixture(phaseBump: true, flatDisk: false)

        // This case is about phase only: λ = 0 so the variance term cannot break the rim tie on
        // sampling noise (the variance term has its own fixture below).
        let off = HealSpot.searchSource(
            in: fixture.image, center: NormalizedPoint(0.5, 0.5), radius: 0.02,
            options: HealSourceSearchOptions(phaseAlignment: false, variancePenalty: 0))
        let on = HealSpot.searchSource(
            in: fixture.image, center: NormalizedPoint(0.5, 0.5), radius: 0.02,
            options: HealSourceSearchOptions(variancePenalty: 0))
        print("262 phase: off d=\(off.distanceInRadii) offset=\(off.offset.x),\(off.offset.y) "
              + "status=\(off.status.rawValue) examined=\(off.examined) accepted=\(off.accepted); "
              + "on d=\(on.distanceInRadii) offset=\(on.offset.x),\(on.offset.y) "
              + "status=\(on.status.rawValue) accepted=\(on.accepted)")

        XCTAssertEqual(off.status, .found)
        XCTAssertEqual(on.status, .found)
        XCTAssertGreaterThanOrEqual(off.distanceInRadii, 3.9,
                                    "修前应选到 4r 的相位错位源")
        // The 4r source is the same candidate; alignment moves its centre by half a disk period.
        let shiftPx = (on.offset.x - off.offset.x) * Double(min(fixture.image.width,
                                                                fixture.image.height))
        print(String(format: "262 phase: shift=%.3f px", shiftPx))
        XCTAssertGreaterThan(abs(shiftPx), 1.5, "相位对齐必须移动源点")
        XCTAssertLessThanOrEqual(abs(abs(shiftPx) - 4.0), 1.5,
                                 "对齐位移应约为盘内周期的半个周期（4 px）")

        let r0 = try renderedRMSE(fixture, offset: off.offset)
        let r1 = try renderedRMSE(fixture, offset: on.offset)
        print(String(format: "262 phase: r0=%.6f r1=%.6f ratio=%.3f", r0, r1, r1 / max(r0, 1e-12)))
        XCTAssertLessThanOrEqual(r1, 0.5 * r0, "r1 \(r1) vs r0 \(r0)")
    }

    /// **Reverse gate.** With phase alignment off the same acceptance must fail: the chosen source
    /// is still the 4r one and its rendered residual is more than half of the aligned one. This is
    /// the test that would go red if `phaseAlignment` stopped having an effect.
    func testPhaseGateIsRedWithoutAlignment() throws {
        let fixture = makeFixture(phaseBump: true, flatDisk: false)
        let off = HealSpot.searchSource(in: fixture.image, center: NormalizedPoint(0.5, 0.5),
                                        radius: 0.02,
                                        options: HealSourceSearchOptions(phaseAlignment: false))
        let on = HealSpot.searchSource(in: fixture.image, center: NormalizedPoint(0.5, 0.5),
                                       radius: 0.02)
        let rOff = try renderedRMSE(fixture, offset: off.offset)
        let rOn = try renderedRMSE(fixture, offset: on.offset)
        print(String(format: "262 phase gate: rOff=%.6f rOn=%.6f", rOff, rOn))
        XCTAssertGreaterThan(rOff, 0.5 * rOn,
                             "关掉相位后仍满足 r≤0.5·r0 ⇒ 相位对齐没有起作用")
    }

    // MARK: - 2. interior variance penalty

    /// **Ring matches, disk is flat.** With λ = 0 the far (4r) flat candidate wins, exactly as
    /// before 262. With λ = 0.5 it is penalised out and the answer moves to a textured candidate.
    func testVariancePenaltyRejectsAFlatDisk() {
        let fixture = makeFixture(phaseBump: false, flatDisk: true)
        let noPenalty = HealSpot.searchSource(
            in: fixture.image, center: NormalizedPoint(0.5, 0.5), radius: 0.02,
            options: HealSourceSearchOptions(phaseAlignment: false, variancePenalty: 0))
        let withPenalty = HealSpot.searchSource(
            in: fixture.image, center: NormalizedPoint(0.5, 0.5), radius: 0.02,
            options: HealSourceSearchOptions(phaseAlignment: false, variancePenalty: 0.5))
        print("262 variance: noPenalty d=\(noPenalty.distanceInRadii) "
              + "offset=\(noPenalty.offset.x),\(noPenalty.offset.y) score=\(noPenalty.score); "
              + "withPenalty d=\(withPenalty.distanceInRadii) "
              + "offset=\(withPenalty.offset.x),\(withPenalty.offset.y) score=\(withPenalty.score)")

        XCTAssertEqual(noPenalty.status, .found)
        XCTAssertEqual(withPenalty.status, .found)
        XCTAssertGreaterThanOrEqual(noPenalty.distanceInRadii, 3.9,
                                    "λ=0 时远端的平坦源仍会被选中（修前行为）")
        XCTAssertGreaterThan(noPenalty.offset.x, 0.05,
                             "修前应命中右侧 4r 的平坦候选")
        XCTAssertLessThan(withPenalty.offset.x, -0.03,
                          "λ=0.5 时必须改选左侧有纹理的候选")
        XCTAssertGreaterThan(withPenalty.distanceInRadii, 2.9)
        XCTAssertLessThan(withPenalty.distanceInRadii, 3.5)
    }

    // MARK: - 3. determinism

    /// Same input, five searches, bit-identical `sourceOffset`.
    func testSearchIsDeterministic() {
        let fixture = makeFixture(phaseBump: true, flatDisk: false)
        let first = HealSpot.searchSource(in: fixture.image, center: NormalizedPoint(0.5, 0.5),
                                          radius: 0.02)
        for _ in 0..<4 {
            let next = HealSpot.searchSource(in: fixture.image, center: NormalizedPoint(0.5, 0.5),
                                             radius: 0.02)
            XCTAssertEqual(next.offset.x.bitPattern, first.offset.x.bitPattern)
            XCTAssertEqual(next.offset.y.bitPattern, first.offset.y.bitPattern)
            XCTAssertEqual(next.distanceInRadii.bitPattern, first.distanceInRadii.bitPattern)
        }
    }

    // MARK: - 4. cost

    /// **Cost on the real 60 Mpx frame.** Ten searches, p50/p95 printed and p95 held to C4's 60 ms.
    /// Skips when no RAW is configured (same convention as `HealAutoSourceTests`).
    func testCostOnTheRealRaw() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let image = try RAWDecoder()
            .decode(URL(fileURLWithPath: path), options: DecodeOptions(decoderVersion: nil, scale: 1))
            .oriented()
        let center = NormalizedPoint(0.5, 0.5)
        _ = HealSpot.searchSource(in: image, center: center, radius: 0.02)
        var samples = [Double]()
        for _ in 0..<10 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = HealSpot.searchSource(in: image, center: center, radius: 0.02)
            samples.append(CFAbsoluteTimeGetCurrent() - t0)
        }
        samples.sort()
        let p50 = samples[5] * 1000
        let p95 = samples[9] * 1000
        print(String(format: "262 cost %d×%d: p50=%.3f ms p95=%.3f ms",
                     image.width, image.height, p50, p95))
        XCTAssertLessThanOrEqual(p95, 60.0, String(format: "p95=%.3f ms", p95))
    }
}
