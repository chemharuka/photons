import XCTest
import Metal
import PhotonsCore

/// 184 — 修复画笔的**自动取源**: the search itself, and what it is worth against the legacy
/// `(2r, 0)` offset.
///
/// The suite is organised by the question each test answers:
///
///  - **A.** On a flat gradient, does the search find a source the renderer can actually use?
///    (The answer is the RMSE against the clean frame, auto vs legacy.)
///  - **B.** On high-frequency texture, does the ring metric pick a source that is in phase — and
///    does the rendered result beat the hard-coded offset by the margin the task asks for?
///  - **C.** When the band holds no usable source, the answer is a **named refusal**
///    (`.noCandidateAccepted`), not a silent patch. Two ways to have no source: the rim itself is
///    inside a defect larger than the spot, and a band whose texture is everywhere the wrong way.
///  - **D.** The cost of one search on a 3 Mpx frame.
///  - **E.** The legacy offset is untouched, bit for bit.
///
/// Every measurement is printed as well as asserted: the numbers are the acceptance, and a green
/// test that does not say what it measured is not evidence.
final class HealAutoSourceTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A deterministic 0…1 hash. Same shape as `HealTests.hash01`, re-declared here so this file
    /// stands on its own and `HealTests.swift` stays untouched.
    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    private func picture(_ width: Int, _ height: Int, identity: String,
                         _ body: (Int, Int) -> (Double, Double, Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-heal-auto-\(identity)")
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 8,
                                                            headroom: 1, linearOutput: true),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    /// RMSE over the disk `t < tMax`, in **linear** luminance (the render above asks S4 for the
    /// linear picture, so no transfer function is involved here).
    private func rmse(_ a: DisplayImage, _ b: DisplayImage,
                      center: (x: Double, y: Double), radiusPx: Double, tMax: Double) -> Double {
        var sum = 0.0
        var n = 0
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                guard (dx * dx + dy * dy).squareRoot() < tMax * radiusPx else { continue }
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

    private static func luma(_ image: LinearImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return 0.2126 * Double(image.rgba[o])
            + 0.7152 * Double(image.rgba[o + 1])
            + 0.0722 * Double(image.rgba[o + 2])
    }

    /// The same number `searchSource` reports as `score` — 8 rings × 24 angles, plane-corrected —
    /// evaluated at a source centre chosen by hand (the legacy `(2r, 0)` in A and B). Without the
    /// plane correction this would be a different quantity and the comparison would be vacuous.
    private func ringResidual(_ image: LinearImage, center: (x: Double, y: Double),
                              candidate: (x: Double, y: Double), radiusPx: Double) -> Double {
        let rings = 8, angles = 24
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, q2 = 0.0
        for ring in 0..<rings {
            let rr = radiusPx * (1.03 + 0.44 * Double(ring) / Double(rings - 1))
            for a in 0..<angles {
                let theta = 2.0 * Double.pi * Double(a) / Double(angles)
                let ux = cos(theta), vy = sin(theta)
                let dx = Int((center.x + rr * ux).rounded())
                let dy = Int((center.y + rr * vy).rounded())
                let sx = Int((candidate.x + rr * ux).rounded())
                let sy = Int((candidate.y + rr * vy).rounded())
                guard dx >= 0, dx < image.width, dy >= 0, dy < image.height,
                      sx >= 0, sx < image.width, sy >= 0, sy < image.height else { continue }
                let diff = Self.luma(image, dx, dy) - Self.luma(image, sx, sy)
                s0 += diff
                s1 += diff * ux
                s2 += diff * vy
                q2 += diff * diff
            }
        }
        let n = Double(rings * angles)
        return max(0, q2 - s0 * s0 / n - 2 * s1 * s1 / n - 2 * s2 * s2 / n) / n
    }

    // MARK: - A. flat gradient

    /// **A — 平坦渐变.** 1200×900, `0.35 + 0.25·x/w`: a wall, not a texture. The defect is the pair a
    /// dust spot really comes in — the blemish the user clicked (0.75r, 3 % down) and its companion
    /// 2.6r to the right (1.1r, same 3 %), which is roughly where the hard-coded `(2r, 0)` looks.
    /// The acceptance is the rendered RMSE against the frame with **no blemish at all**.
    func testAFlatGradient() throws {
        let width = 1200, height = 900
        let radius = 0.02
        let radiusPx = radius * Double(min(width, height))       // 18 px
        let centerPx = (x: 0.5 * Double(width), y: 0.5 * Double(height))
        let companionPx = (x: centerPx.x + 2.6 * radiusPx, y: centerPx.y)

        func image(blemished: Bool) -> LinearImage {
            picture(width, height, identity: blemished ? "a-blemished" : "a-clean") { x, y in
                var v = 0.35 + 0.25 * (Double(x) + 0.5) / Double(width)
                v += 0.001 * Self.hash01(x, y)
                guard blemished else { return (v, v, v) }
                let dx = Double(x) + 0.5 - centerPx.x
                let dy = Double(y) + 0.5 - centerPx.y
                if (dx * dx + dy * dy).squareRoot() < 0.75 * radiusPx { v *= 0.97 }
                let ex = Double(x) + 0.5 - companionPx.x
                let ey = Double(y) + 0.5 - companionPx.y
                if (ex * ex + ey * ey).squareRoot() < 1.1 * radiusPx { v *= 0.97 }
                return (v, v, v)
            }
        }

        let blemished = image(blemished: true)
        let clean = image(blemished: false)
        let auto = HealSpot.searchSource(in: blemished, center: NormalizedPoint(0.5, 0.5),
                                         radius: radius)
        print("A search: status=\(auto.status.rawValue) d=\(auto.distanceInRadii) "
              + "offset=\(auto.offset.x),\(auto.offset.y) score=\(auto.score) "
              + "examined=\(auto.examined) accepted=\(auto.accepted)")

        let legacyOffset = HealSpot.defaultSourceOffset(radius: radius)
        let legacyCentre = (x: centerPx.x + 2.0 * radiusPx, y: centerPx.y)
        let legacyRing = ringResidual(blemished, center: centerPx, candidate: legacyCentre,
                                      radiusPx: radiusPx)
        print("A ring: auto=\(auto.score) legacy(2r,0)=\(legacyRing)")
        XCTAssertEqual(auto.status, .found, "平坦渐变上必须取到源")
        XCTAssertGreaterThanOrEqual(auto.distanceInRadii, 3.0,
                                    "平坦渐变上应取 3 个半径以外的源，而不是就近的 2r")

        let graph = try makeGraph(blemished, identity: "heal-auto-a")
        let reference = try display(try makeGraph(clean, identity: "heal-auto-a-clean"),
                                    EditModel.neutral)

        func rendered(_ offset: NormalizedPoint) throws -> DisplayImage {
            var doc = EditModel.neutral
            doc.healSpots = [HealSpot(center: NormalizedPoint(0.5, 0.5), radius: radius,
                                      sourceOffset: offset, mode: .heal,
                                      feather: HealSpot.defaultFeather)]
            return try display(graph, doc)
        }

        let rmseAuto = rmse(try rendered(auto.offset), reference,
                            center: centerPx, radiusPx: radiusPx, tMax: 0.9)
        let rmseLegacy = rmse(try rendered(legacyOffset), reference,
                              center: centerPx, radiusPx: radiusPx, tMax: 0.9)
        print("A auto=\(rmseAuto) legacy=\(rmseLegacy) ratio=\(rmseAuto / rmseLegacy)")
        XCTAssertLessThanOrEqual(rmseAuto, 0.5 * rmseLegacy,
                                 "auto \(rmseAuto) vs legacy \(rmseLegacy)")
    }

    // MARK: - B. high-frequency texture

    /// **B — 高频纹理.** A vertical sinusoid of period `4r/3`, so the band's radial steps land on
    /// exact multiples of the period at `2.667r` (2 periods) and `4r` (3 periods) but **not** at
    /// `2r` (1.5 periods — the worst possible phase). The search has to pick a phase-aligned source
    /// out of 336 candidates; the hard-coded offset copies the opposite phase.
    func testBTexture() throws {
        let width = 1200, height = 900
        let radius = 0.02
        let radiusPx = radius * Double(min(width, height))       // 18 px
        let centerPx = (x: 0.5 * Double(width), y: 0.5 * Double(height))
        let period = 4.0 * radiusPx / 3.0                        // 24 px

        func image(blemished: Bool) -> LinearImage {
            picture(width, height, identity: blemished ? "b-blemished" : "b-clean") { x, y in
                var v = 0.45 + 0.02 * cos(2.0 * Double.pi * (Double(x) + 0.5) / period)
                if blemished {
                    let dx = Double(x) + 0.5 - centerPx.x
                    let dy = Double(y) + 0.5 - centerPx.y
                    if (dx * dx + dy * dy).squareRoot() < 0.9 * radiusPx { v *= 0.97 }
                }
                return (v, v, v)
            }
        }

        let blemished = image(blemished: true)
        let clean = image(blemished: false)
        let auto = HealSpot.searchSource(in: blemished, center: NormalizedPoint(0.5, 0.5),
                                         radius: radius)
        print("B search: status=\(auto.status.rawValue) d=\(auto.distanceInRadii) "
              + "score=\(auto.score) examined=\(auto.examined) accepted=\(auto.accepted)")
        XCTAssertEqual(auto.status, .found, "纹理里必须取到源")
        XCTAssertTrue(auto.score.isFinite, "全分辨率残差必须是有限数")

        let legacyOffset = HealSpot.defaultSourceOffset(radius: radius)
        let legacyCentre = (x: centerPx.x + 2.0 * radiusPx, y: centerPx.y)
        let legacyRing = ringResidual(blemished, center: centerPx, candidate: legacyCentre,
                                      radiusPx: radiusPx)
        print("B ring: auto=\(auto.score) legacy(2r,0)=\(legacyRing)")
        XCTAssertLessThan(auto.score, legacyRing,
                          "自动源的环带残差 \(auto.score) 应小于 (2r,0) 的 \(legacyRing)")

        let graph = try makeGraph(blemished, identity: "heal-auto-b")
        let reference = try display(try makeGraph(clean, identity: "heal-auto-b-clean"),
                                    EditModel.neutral)

        func rendered(_ offset: NormalizedPoint) throws -> DisplayImage {
            var doc = EditModel.neutral
            doc.healSpots = [HealSpot(center: NormalizedPoint(0.5, 0.5), radius: radius,
                                      sourceOffset: offset, mode: .heal,
                                      feather: HealSpot.defaultFeather)]
            return try display(graph, doc)
        }

        let rmseAuto = rmse(try rendered(auto.offset), reference,
                            center: centerPx, radiusPx: radiusPx, tMax: 0.9)
        let rmseLegacy = rmse(try rendered(legacyOffset), reference,
                              center: centerPx, radiusPx: radiusPx, tMax: 0.9)
        print("B auto=\(rmseAuto) legacy=\(rmseLegacy) ratio=\(rmseAuto / rmseLegacy)")
        XCTAssertLessThanOrEqual(rmseAuto, 0.6 * rmseLegacy,
                                 "auto \(rmseAuto) vs legacy \(rmseLegacy)")
    }

    // MARK: - C. no usable source in the band

    /// **C1 — 缺陷比画笔大.** A flat wall, and a blemish of **3 × the spot's radius**: the rim the
    /// kernel fits (at `r`) is entirely inside the blemish, so it carries no contrast and the plane
    /// would be fitted to the defect itself — every candidate would then look acceptable against it.
    /// The search must refuse **by name** and hand back the legacy offset, not invent a patch.
    func testCRejectsABlemishBiggerThanTheSpot() {
        let width = 1200, height = 900
        let radius = 0.02
        let radiusPx = radius * Double(min(width, height))       // 18 px
        let centerPx = (x: 0.5 * Double(width), y: 0.5 * Double(height))

        let image = picture(width, height, identity: "c-big-blemish") { x, y in
            var v = 0.5 + 0.0004 * (Self.hash01(x, y) - 0.5) * 2.0
            let dx = Double(x) + 0.5 - centerPx.x
            let dy = Double(y) + 0.5 - centerPx.y
            if (dx * dx + dy * dy).squareRoot() < 3.0 * radiusPx { v *= 0.97 }
            return (v, v, v)
        }

        let result = HealSpot.searchSource(in: image, center: NormalizedPoint(0.5, 0.5),
                                           radius: radius)
        let legacy = HealSpot.defaultSourceOffset(radius: radius)
        print("C1 search: status=\(result.status.rawValue) examined=\(result.examined) "
              + "accepted=\(result.accepted) offset=\(result.offset.x),\(result.offset.y)")

        XCTAssertEqual(result.status, .noCandidateAccepted, "环带里没有可用源，必须具名拒绝")
        XCTAssertEqual(result.offset.x.bitPattern, legacy.x.bitPattern)
        XCTAssertEqual(result.offset.y.bitPattern, legacy.y.bitPattern)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.examined, 0,
                       "环带本身没有反差（rim 落在缺陷里），一个候选都不该被评分")
    }

    /// **C2 — 带里放不下一块源.** A 200 × 200 frame with `radius = 0.4` (`r = 80 px`): a candidate
    /// needs `2r` of distance plus its own `1.5r` patch, i.e. 280 px of room from a centre that is
    /// 100 px from every edge. Every candidate runs off the picture, the sampler would clamp, and a
    /// clamped source is not a source the user can see. Refused by name, `(2r, 0)` returned.
    func testCRejectsABandWithNowhereToPutASource() {
        let width = 200, height = 200
        let radius = 0.4
        let centerPx = (x: 0.5 * Double(width), y: 0.5 * Double(height))

        let image = picture(width, height, identity: "c-tight-frame") { x, y in
            let dx = Double(x) + 0.5 - centerPx.x
            let dy = Double(y) + 0.5 - centerPx.y
            let d = (dx * dx + dy * dy).squareRoot()
            let v = 0.45 + 0.02 * cos(2.0 * Double.pi * d / 12.0)
            return (v, v, v)
        }

        let result = HealSpot.searchSource(in: image, center: NormalizedPoint(0.5, 0.5),
                                           radius: radius)
        let legacy = HealSpot.defaultSourceOffset(radius: radius)
        print("C2 search: status=\(result.status.rawValue) examined=\(result.examined) "
              + "accepted=\(result.accepted) offset=\(result.offset.x),\(result.offset.y)")

        XCTAssertEqual(result.status, .noCandidateAccepted, "没有任何位置放得下整块源，必须具名拒绝")
        XCTAssertEqual(result.offset.x.bitPattern, legacy.x.bitPattern)
        XCTAssertEqual(result.offset.y.bitPattern, legacy.y.bitPattern)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.examined, 0, "一个候选都没能放进画面")
    }

    // MARK: - D. cost

    /// **D — 成本.** 2000×1500 (3.0 Mpx), `r = 0.02` (30 px), 200 searches after 3 warm-ups.
    func testDCost() {
        let width = 2000, height = 1500
        let radius = 0.02
        let image = picture(width, height, identity: "d-cost") { x, y in
            var v = 0.3 + 0.3 * (Double(x) + 0.5) / Double(width)
            v += 0.04 * (Self.hash01(x / 2, y / 2) - 0.5) * 2.0
            return (v, v, v)
        }
        let center = NormalizedPoint(0.5, 0.5)
        for _ in 0..<3 {
            _ = HealSpot.searchSource(in: image, center: center, radius: radius)
        }

        var samples = [Double]()
        samples.reserveCapacity(200)
        for _ in 0..<200 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = HealSpot.searchSource(in: image, center: center, radius: radius)
            samples.append(CFAbsoluteTimeGetCurrent() - t0)
        }
        samples.sort()
        let p50 = samples[100]
        let p95 = samples[190]
        print(String(format: "D p50=%.3f ms p95=%.3f ms", p50 * 1000, p95 * 1000))
        XCTAssertLessThanOrEqual(p50, 0.008, String(format: "p50=%.3f ms", p50 * 1000))
    }

    // MARK: - F. a real photo

    /// The synthetic fixtures pin the *behaviour*; this pins the fact that a real decode answers.
    /// `L1030433.dng` at full size (4.1 Mpx) — the frame D is about — searching its centre 20 times.
    /// Skips (rather than fails) when no RAW is configured: this is a smoke, not an acceptance.
    func testOnARealRawTheSearchAnswers() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let image = try RAWDecoder()
            .decode(URL(fileURLWithPath: path), options: DecodeOptions(decoderVersion: nil, scale: 1))
            .oriented()
        let radius = 0.02
        let center = NormalizedPoint(0.5, 0.5)

        let result = HealSpot.searchSource(in: image, center: center, radius: radius)
        print("RAW \(image.width)×\(image.height): status=\(result.status.rawValue) "
              + "d=\(result.distanceInRadii) score=\(result.score) examined=\(result.examined) "
              + "accepted=\(result.accepted)")

        var samples = [Double]()
        for _ in 0..<20 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = HealSpot.searchSource(in: image, center: center, radius: radius)
            samples.append(CFAbsoluteTimeGetCurrent() - t0)
        }
        samples.sort()
        print(String(format: "RAW p50=%.3f ms p95=%.3f ms",
                     samples[10] * 1000, samples[19] * 1000))

        XCTAssertNotEqual(result.status, .searchSkipped, "中央的 rim 在画面内，搜索必须真的跑")
        XCTAssertLessThanOrEqual(abs(result.offset.x), 4.5 * radius)
        XCTAssertLessThanOrEqual(abs(result.offset.y), 4.5 * radius)
        if result.status == .found {
            XCTAssertGreaterThanOrEqual(result.distanceInRadii, 2.0, "源在 2r…4r 的带里")
            XCTAssertLessThanOrEqual(result.distanceInRadii, 4.01)
        }
    }

    // MARK: - E. the legacy offset is bit-identical

    /// **E — 不变量.** With 自动取源 off (or no frame in hand) the offset is `(2r, 0)` **bit for
    /// bit** — the same expression `HealSpot.defaultSourceOffset` has always had, so a spot written
    /// today and a spot written by this build carry the same `keyString`, i.e. the same render
    /// inputs, and a document already on disk decodes and re-encodes unchanged.
    func testEInvariants() {
        let radius = 0.03
        let spot = HealSpot(center: NormalizedPoint(0.5, 0.5), radius: radius,
                            sourceOffset: HealSpot.defaultSourceOffset(radius: radius))
        XCTAssertEqual(spot.sourceOffset.x.bitPattern, (radius * 2).bitPattern)
        XCTAssertEqual(spot.sourceOffset.y.bitPattern, Double(0).bitPattern)

        let skipped = HealSourceResult.skipped(radius: radius)
        XCTAssertEqual(skipped.offset.x.bitPattern, spot.sourceOffset.x.bitPattern)
        XCTAssertEqual(skipped.offset.y.bitPattern, spot.sourceOffset.y.bitPattern)
        XCTAssertEqual(skipped.status, .searchSkipped)
        XCTAssertEqual(skipped.examined, 0)
        XCTAssertEqual(skipped.accepted, 0)
        XCTAssertEqual(skipped.score, 0)
        XCTAssertEqual(skipped.distanceInRadii, 0)

        // The two documents are one document as far as the renderer is concerned: same key.
        let other = HealSpot(center: NormalizedPoint(0.5, 0.5), radius: radius,
                             sourceOffset: skipped.offset)
        XCTAssertEqual(spot.keyString, other.keyString)

        // A stored spot — the shape a document on disk has — is not touched by the search existing:
        // it decodes to itself and re-encodes to the same values, so an existing document's render
        // inputs (its `keyString`) are unchanged.
        let stored = HealSpot(id: "h-184", center: NormalizedPoint(0.4, 0.6), radius: 0.05,
                              sourceOffset: NormalizedPoint(0.1, 0), mode: .clone, feather: 0.2)
        let data = try! JSONEncoder().encode(stored)
        let back = try! JSONDecoder().decode(HealSpot.self, from: data)
        XCTAssertEqual(back, stored)
        XCTAssertEqual(back.sourceOffset.x.bitPattern, (0.1 as Double).bitPattern)
        XCTAssertEqual(back.keyString, stored.keyString)
        XCTAssertEqual(back.id, stored.id, "id 是文档句柄，解码不能重铸")
    }
}
