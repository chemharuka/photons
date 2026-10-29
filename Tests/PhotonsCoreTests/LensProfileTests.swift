import XCTest
@testable import PhotonsCore
import Metal
import CoreImage

/// 097 — the DNG `OpcodeList3 / WarpRectilinear` parser, and 103 — the Panasonic RW2 `0x0119`
/// distortion block (pure data, no Metal for most tests).
final class LensProfileTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// Every RW2 sample this machine happens to have. `PHOTONS_TEST_RW2` wins; otherwise the two
    /// measured files are used, and a missing array skips instead of failing on another machine.
    private func rw2FixtureURLs() -> [URL] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RW2"] {
            paths.append(env)
        }
        paths += [
            "~/workspace/research/lightroom-mit/samples/P1126458_mechanical.RW2",
            "~/Desktop/test/viltrox/0164541249.rw2",
            "~/Desktop/test/P1126473_96MP.RW2",
            "~/Desktop/test/P1126458_mechanical.RW2",
        ]
        var seen = Set<String>()
        return paths.map { NSString(string: $0).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The SL3 file: three planes with different `kr0`, big-endian payload under an `II` header, in a
    /// SubIFD. Every number below was read from `L1030433.dng` (exiftool agrees the opcode is
    /// WarpRectilinear).
    func testSL3FileHasThreeDistinctPlanesAndExactCoefficients() throws {
        let url = try fixtureURL()
        let profile = try XCTUnwrap(LensProfile.read(from: url))
        XCTAssertEqual(profile.planes.count, 3)
        XCTAssertTrue(profile.hasPerPlaneDifference)
        XCTAssertEqual(profile.centerX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(profile.centerY, 0.5, accuracy: 1e-12)

        let expected = [1.00022744, 0.99991073, 0.99966989]
        for (plane, kr0) in zip(profile.planes, expected) {
            XCTAssertEqual(plane.kr0, kr0, accuracy: 1e-8)
            XCTAssertEqual(plane.kt0, 0, accuracy: 1e-12)
            XCTAssertEqual(plane.kt1, 0, accuracy: 1e-12)
        }
        // The first plane's own non-zero terms (095's numbers); the other planes differ.
        XCTAssertEqual(profile.planes[0].kr1, -0.007641494406453521, accuracy: 1e-8)
        XCTAssertEqual(profile.planes[0].kr2, -0.010054672900487066, accuracy: 1e-8)
        XCTAssertEqual(profile.planes[0].kr3, -0.0028838454462290714, accuracy: 1e-8)
        print("L1030433 planes: "
              + profile.planes.map {
                  String(format: "kr0=%.8f kr1=%.8f kr2=%.8f kr3=%.8f",
                         $0.kr0, $0.kr1, $0.kr2, $0.kr3)
              }.joined(separator: " | "))
        print("lens key: \(profile.recipeComponent)")
    }

    /// A TIFF with no OpcodeList3 (indeed no IFD entries at all) is `nil`, not a crash and not a
    /// guess. Written to a temp file so `read(from:)` exercises the real entry point.
    func testFileWithoutOpcodeList3IsNil() throws {
        var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]) // II, magic 42, IFD0 @8
        tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])   // 0 entries, next IFD 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-empty-\(UUID().uuidString).tiff")
        try tiff.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LensProfile.read(from: url))
    }

    func testIdenticalPlanesHaveNoPerPlaneDifference() {
        let p = LensWarpPlane(kr0: 1.0002, kr1: -0.0076, kr2: -0.0100, kr3: -0.0028)
        let profile = LensProfile(planes: [p, p, p])
        XCTAssertFalse(profile.hasPerPlaneDifference)
        XCTAssertEqual(profile.recipeComponent, "lens=apple")

        var q = p
        let different = LensProfile(planes: [p, p, LensWarpPlane(kr0: q.kr0 + 1e-6,
                                                                 kr1: q.kr1, kr2: q.kr2, kr3: q.kr3)])
        XCTAssertTrue(different.hasPerPlaneDifference)
        XCTAssertTrue(different.recipeComponent.hasPrefix("lens=ours:"))

        q = p
        let withinTolerance = LensProfile(planes: [p, p, LensWarpPlane(kr0: q.kr0 + 1e-12,
                                                                       kr1: q.kr1, kr2: q.kr2, kr3: q.kr3)])
        XCTAssertFalse(withinTolerance.hasPerPlaneDifference)
    }

    // MARK: - 103: Panasonic RW2 `0x0119`

    /// The three measured files. Only the two present on this machine are asserted exactly; the
    /// generic fit/flag checks still run on any third file supplied through `PHOTONS_TEST_RW2`.
    private let expectedPanasonic: [String: (z: Double, a: Double, b: Double, c: Double, w12: Double)] = [
        "P1126458_mechanical.RW2": (1 - 167.0 / 32768, 328.0 / 32768, -372.0 / 32768,
                                    -122.0 / 32768, 3606),
        "0164541249.rw2": (1 - 173.0 / 32768, -1106.0 / 32768, 2022.0 / 32768,
                           -412.0 / 32768, 4892),
    ]

    func testPanasonicSamplesParseAndFitTheirInverse() throws {
        let urls = rw2FixtureURLs()
        guard !urls.isEmpty else { throw XCTSkip("no RW2 fixture; set PHOTONS_TEST_RW2") }
        for url in urls {
            let profile = try XCTUnwrap(LensProfile.readPanasonic(from: url),
                                        "readPanasonic returned nil for \(url.lastPathComponent)")
            XCTAssertEqual(profile.source, .panasonicRW2)
            let warp = try XCTUnwrap(profile.panasonic)
            XCTAssertEqual(warp.flag, 1)
            XCTAssertEqual(profile.planes.count, 3)
            XCTAssertTrue(profile.requiresOwnWarp)
            XCTAssertTrue(profile.planes.allSatisfy {
                $0.isWithin(warp.inverse, tolerance: 1e-12)
            }, "Panasonic has no per-channel data; all three planes must be the same fit")
            XCTAssertTrue(warp.isStrictlyMonotonic())
            XCTAssertLessThanOrEqual(warp.maxResidual, 1e-3)
            XCTAssertEqual(warp.inverse.kr0, warp.z, accuracy: 1e-3,
                           "the inverse's kr0 should land on 1/scale = z")
            XCTAssertEqual(warp.halfDiagonal, Double(Int(warp.halfDiagonal)), accuracy: 1e-9)

            if let e = expectedPanasonic[url.lastPathComponent] {
                XCTAssertEqual(warp.z, e.z, accuracy: 1e-12)
                XCTAssertEqual(warp.a, e.a, accuracy: 1e-12)
                XCTAssertEqual(warp.b, e.b, accuracy: 1e-12)
                XCTAssertEqual(warp.c, e.c, accuracy: 1e-12)
                XCTAssertEqual(warp.halfDiagonal, e.w12, accuracy: 1e-9)
            }
            XCTAssertTrue(profile.recipeComponent.hasPrefix("lens=panasonic:"),
                          "recipeComponent = \(profile.recipeComponent)")
            print(String(format: "%@: z=%.9f a=%+.9f b=%+.9f c=%+.9f w12=%.0f "
                         + "kr0=%.9f fitResidual=%.3e",
                         url.lastPathComponent, warp.z, warp.a, warp.b, warp.c,
                         warp.halfDiagonal, warp.inverse.kr0, warp.maxResidual))
        }
    }

    /// Acceptance 2: the 4-term fitted inverse against the Newton root at 21 radii, per sample.
    func testPanasonicFittedInverseMatchesNewtonAt21Radii() throws {
        let urls = rw2FixtureURLs()
        guard !urls.isEmpty else { throw XCTSkip("no RW2 fixture; set PHOTONS_TEST_RW2") }
        for url in urls {
            let warp = try XCTUnwrap(LensProfile.readPanasonic(from: url)?.panasonic)
            var worst = 0.0
            for i in 0...20 {
                let rho = 0.1 + 0.9 * Double(i) / 20
                let truth = warp.inverseRadius(at: rho)
                let fitted = rho * warp.inverse.radialScale(at: rho)
                worst = max(worst, abs(fitted - truth))
            }
            print(String(format: "%@: max |fit - Newton| over rho 0.1…1.0 = %.3e",
                         url.lastPathComponent, worst))
            XCTAssertLessThanOrEqual(worst, 1e-3)
        }
    }

    /// `0x0119` with `w7 & 0xf == 0` means "no correction" and must read as `nil`, not as an
    /// identity profile. A non-monotonic forward map is the same answer for a different reason.
    func testPanasonicFlagZeroAndNonMonotonicMapsAreRejected() throws {
        let good = panasonicWords(z: 1 - 167.0 / 32768, a: 328.0 / 32768,
                                  b: -372.0 / 32768, c: -122.0 / 32768,
                                  halfDiagonal: 3606, flag: 1)
        let goodURL = try writeRW2(panasonicWords: good)
        defer { try? FileManager.default.removeItem(at: goodURL) }
        let profile = try XCTUnwrap(LensProfile.readPanasonic(from: goodURL))
        XCTAssertEqual(profile.source, .panasonicRW2)
        XCTAssertEqual(profile.panasonic?.flag, 1)

        var off = good
        off[7] = 0
        let offURL = try writeRW2(panasonicWords: off)
        defer { try? FileManager.default.removeItem(at: offURL) }
        XCTAssertNil(LensProfile.readPanasonic(from: offURL), "w7 & 0xf == 0 means no correction")

        var folded = good
        folded[4] = -32768          // b = -1: f'(r) = 1 + 5·b·r⁴ goes negative
        folded[5] = 0               // z = 1
        folded[8] = 0
        folded[11] = 0
        let foldedURL = try writeRW2(panasonicWords: folded)
        defer { try? FileManager.default.removeItem(at: foldedURL) }
        XCTAssertNil(LensProfile.readPanasonic(from: foldedURL),
                     "a non-monotonic forward map has no inverse and must not be corrected")
    }

    /// Acceptance 5: the Panasonic profile is a decode input. Apple's path and ours must not share
    /// a buffer, and the recipe bump alone must orphan the old buffers.
    func testPanasonicRecipeEntersTheDecodeKeyAndTheRecipeIsV3() throws {
        let warp = try XCTUnwrap(PanasonicWarp(z: 1 - 167.0 / 32768, a: 328.0 / 32768,
                                               b: -372.0 / 32768, c: -122.0 / 32768,
                                               halfDiagonal: 3606, flag: 1))
        let ours = LensProfile(planes: [warp.inverse, warp.inverse, warp.inverse],
                               source: .panasonicRW2, panasonic: warp)
        let oursKey = DecodeInputs(lens: ours.recipeComponent).key
        let appleKey = DecodeInputs(lens: "lens=apple").key
        XCTAssertNotEqual(oursKey, appleKey)
        XCTAssertTrue(oursKey.contains("lens=panasonic:"))

        let appleDigest = DecodeCacheKey(fileSHA256: "rw2", decoderVersion: "8",
                                         lens: "lens=apple").digest
        let oursDigest = DecodeCacheKey(fileSHA256: "rw2", decoderVersion: "8",
                                        lens: ours.recipeComponent).digest
        XCTAssertNotEqual(appleDigest, oursDigest,
                          "switching from Apple's correction to ours must miss the old buffer")
        XCTAssertEqual(DecodeRecipe.current, "v3-lens")
    }

    /// The S0 Metal entry point gets a real warp (not the identity), and the frame is no longer a
    /// byte-for-byte copy of the uncorrected one.
    func testPanasonicProfileSelectsTheLensEntryAndMovesPixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let warp = try XCTUnwrap(PanasonicWarp(z: 1 - 167.0 / 32768, a: 328.0 / 32768,
                                               b: -372.0 / 32768, c: -122.0 / 32768,
                                               halfDiagonal: 3606, flag: 1))
        let profile = LensProfile(planes: [warp.inverse, warp.inverse, warp.inverse],
                                  source: .panasonicRW2, panasonic: warp)
        let input = RenderInput(image: rampImage(width: 801, height: 601),
                                identity: "rw2-lens", lensProfile: profile)
        XCTAssertTrue(input.hasPerPlaneLensWarp)
        let matrix = RenderGraph.lensMatrix(profile)
        XCTAssertNotEqual(matrix.columns.0, SIMD4<Float>(1, 0, 0, 0))

        let bare = try render(input.image, identity: "rw2-bare", profile: nil)
        let warped = try render(input.image, identity: "rw2-warped", profile: profile)
        XCTAssertNotEqual(bare.image.sha256(), warped.image.sha256(),
                          "a Panasonic profile must change the sampled pixels")
        XCTAssertTrue(warped.trace.executed.contains(.geometry))
    }

    /// Acceptance 3 on a real RW2: Apple's own lens correction and ours must put the four corners
    /// within 2 px of each other at a 2380 px long edge. The displacement is measured from a
    /// correction-off decode of the same file, so both sides are compared in the same pixels.
    func testRealRW2CornersMatchAppleWithinTwoPixelsAt2380() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        guard let url = rw2FixtureURLs().first(where: {
            $0.lastPathComponent.hasPrefix("0164541249")
        }) ?? rw2FixtureURLs().first else {
            throw XCTSkip("no RW2 fixture; set PHOTONS_TEST_RW2")
        }
        guard let probe = CIRAWFilter(imageURL: url) else { throw XCTSkip("CIRAWFilter unavailable") }
        let fullExtent = try XCTUnwrap(probe.outputImage).extent.integral
        let longEdge = max(Int(fullExtent.width), Int(fullExtent.height))
        let scale = Float(2380.0 / Double(max(longEdge, 1)))
        print("real RW2: full \(Int(fullExtent.width))×\(Int(fullExtent.height)), "
              + "probe scale \(scale) for 2380 px")

        let baseline = try appleDecode(url, scale: scale, lensCorrection: false)
        let apple = try appleDecode(url, scale: scale, lensCorrection: true)
        let developed = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: scale))
        let profile = try XCTUnwrap(developed.lensProfile)
        XCTAssertEqual(profile.source, .panasonicRW2)
        XCTAssertTrue(profile.requiresOwnWarp)

        let base = try render(baseline, identity: "rw2-apple-off", profile: nil).image
        let appleImage = try render(apple, identity: "rw2-apple-on", profile: nil).image
        let ours = try render(developed.image, identity: "rw2-ours", profile: profile).image
        XCTAssertEqual(base.width, appleImage.width)
        XCTAssertEqual(base.width, ours.width)
        XCTAssertLessThanOrEqual(abs(max(base.width, base.height) - 2380), 1,
                                 "the displacement budget is stated at a 2380 px long edge")

        let centres = cornerCentres(width: base.width, height: base.height)
        var worst = 0.0
        var appleMoves = 0.0
        for centre in centres {
            let a = bestTranslation(from: base, to: appleImage, at: centre)
            let o = bestTranslation(from: base, to: ours, at: centre)
            let d = hypot(a.dx - o.dx, a.dy - o.dy)
            worst = max(worst, d)
            appleMoves = max(appleMoves, hypot(a.dx, a.dy))
            print(String(format: "corner (%d,%d): apple=(%+.2f,%+.2f) ours=(%+.2f,%+.2f) "
                         + "diff=%.2f px",
                         centre.x, centre.y, a.dx, a.dy, o.dx, o.dy, d))
        }
        print(String(format: "2380 px: worst corner displacement difference %.1f px "
                     + "(Apple max move %.1f px)", worst, appleMoves))
        guard appleMoves > 1 else {
            throw XCTSkip("Apple's RW2 lens correction moved nothing measurable; A/B still unknown")
        }
        XCTAssertLessThanOrEqual(worst, 2.0)
    }

    // MARK: - Apple decode / displacement probes

    private func appleDecode(_ url: URL, scale: Float, lensCorrection: Bool) throws -> LinearImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let filter = CIRAWFilter(imageURL: url),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("CIRAWFilter unavailable")
        }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.scaleFactor = scale
        filter.isLensCorrectionEnabled = lensCorrection
        guard let output = filter.outputImage else { throw XCTSkip("no output image") }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw XCTSkip("bad extent") }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer() else { throw XCTSkip("texture failed") }
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CIContext(mtlDevice: device, options: [.workingColorSpace: cs,
                                                         .outputColorSpace: cs,
                                                         .cacheIntermediates: false])
        ctx.render(output, to: texture, commandBuffer: cb,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: cs)
        cb.commit()
        cb.waitUntilCompleted()
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        RAWDecoder.flipRows(&rgba, width: w, height: h)
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "apple-\(scale)")
    }

    private func cornerCentres(width: Int, height: Int) -> [(x: Int, y: Int)] {
        let mx = max(60, Int(Double(width) * 0.10))
        let my = max(60, Int(Double(height) * 0.10))
        return [(mx, my), (width - 1 - mx, my), (mx, height - 1 - my),
                (width - 1 - mx, height - 1 - my)]
    }

    /// Translation that best maps `from` to `to` in a patch around `centre`: integer search, then a
    /// quarter-pixel refinement with bilinear sampling on the moved image.
    private func bestTranslation(from: DisplayImage, to: DisplayImage,
                                 at centre: (x: Int, y: Int),
                                 search: Int = 20, patch: Int = 32) -> (dx: Double, dy: Double) {
        func error(dx: Double, dy: Double) -> Double {
            var sum = 0.0
            for y in -patch...patch {
                for x in -patch...patch {
                    let bx = centre.x + x, by = centre.y + y
                    guard bx >= 0, by >= 0, bx < from.width, by < from.height else {
                        return .greatestFiniteMagnitude
                    }
                    let a = Double(from.rgba[(by * from.width + bx) * 4 + 1])
                    let b = greenBilinear(to, Double(bx) + dx, Double(by) + dy)
                    guard b.isFinite else { return .greatestFiniteMagnitude }
                    sum += abs(a - b)
                }
            }
            return sum
        }
        var best: (dx: Double, dy: Double, error: Double) =
            (dx: 0, dy: 0, error: Double.greatestFiniteMagnitude)
        for dy in -search...search {
            for dx in -search...search {
                let e = error(dx: Double(dx), dy: Double(dy))
                if e < best.error { best = (Double(dx), Double(dy), e) }
            }
        }
        let coarse = (dx: best.dx, dy: best.dy)
        for k in -4...4 {
            for j in -4...4 {
                let dx = coarse.dx + Double(k) * 0.25
                let dy = coarse.dy + Double(j) * 0.25
                let e = error(dx: dx, dy: dy)
                if e < best.error { best = (dx, dy, e) }
            }
        }
        return (best.dx, best.dy)
    }

    private func greenBilinear(_ image: DisplayImage, _ x: Double, _ y: Double) -> Double {
        guard x >= 0, y >= 0, x <= Double(image.width - 1), y <= Double(image.height - 1) else {
            return .nan
        }
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let x1 = min(x0 + 1, image.width - 1), y1 = min(y0 + 1, image.height - 1)
        let fx = x - Double(x0), fy = y - Double(y0)
        func g(_ i: Int, _ j: Int) -> Double {
            Double(image.rgba[(j * image.width + i) * 4 + 1])
        }
        let top = g(x0, y0) * (1 - fx) + g(x1, y0) * fx
        let bottom = g(x0, y1) * (1 - fx) + g(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - Panasonic synthetic fixture

    private func panasonicWords(z: Double, a: Double, b: Double, c: Double,
                                halfDiagonal: Int16, flag: Int16) -> [Int16] {
        var w = [Int16](repeating: 0, count: 16)
        w[5] = Int16(((z - 1) * 32768).rounded())
        w[8] = Int16((a * 32768).rounded())
        w[4] = Int16((b * 32768).rounded())
        w[11] = Int16((c * 32768).rounded())
        w[7] = flag
        w[12] = halfDiagonal
        w[9] = 100
        w[13] = w[9] + 500        // the observed w13 == w9 + 500 relation (diagnostic only)
        return w
    }

    /// A minimal little-endian TIFF with one IFD0 entry: tag 0x0119, UNDEFINED[32] at offset 26.
    private func writeRW2(panasonicWords words: [Int16]) throws -> URL {
        precondition(words.count == 16)
        var data = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x01, 0x00])                       // 1 entry
        data.append(contentsOf: [0x19, 0x01, 0x07, 0x00])           // tag 0x0119, UNDEFINED
        data.append(contentsOf: [0x20, 0x00, 0x00, 0x00])           // count 32
        data.append(contentsOf: [0x1A, 0x00, 0x00, 0x00])           // offset 26
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])           // next IFD
        for w in words {
            let u = UInt16(bitPattern: w)
            data.append(contentsOf: [UInt8(u & 0xff), UInt8(u >> 8)])
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panasonic-\(UUID().uuidString).rw2")
        try data.write(to: url)
        return url
    }

    private func rampImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let u = Double(x) / Double(max(width - 1, 1))
                let v = Double(y) / Double(max(height - 1, 1))
                let s = Float(0.05 + 0.65 * (0.55 * u + 0.45 * v)
                              + 0.15 * sin(13.0 * u + 7.0 * v))
                rgba[o] = Float16(s)
                rgba[o + 1] = Float16(s)
                rgba[o + 2] = Float16(s)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ image: LinearImage, identity: String,
                        profile: LensProfile?) throws -> (image: DisplayImage,
                                                          trace: RenderTrace) {
        let graph = try RenderGraph(input: RenderInput(image: image, identity: identity,
                                                       lensProfile: profile))
        let result = try graph.render(EditModel.neutral,
                                      options: RenderOptions(scale: 1, useCache: false,
                                                             wantsPixels: true))
        return (try XCTUnwrap(result.display), result.trace)
    }
}
