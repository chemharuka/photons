import XCTest
import PhotonsCore

/// Crop / straighten / flip at the **model** layer: the pure crop math, the document fields that
/// describe the gesture, and two pins on real pixels — a full-frame `cropRect` must reproduce the
/// recorded neutral golden exactly, and a cropped + straightened frame must reproduce its own.
///
/// Nothing here needs a UI drag: every number is either closed-form or a frame the renderer produces
/// through the same single path the app uses (docs/architecture-decisions.md D12).
final class CropMathTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/PhotonsCoreTests/CropMathTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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

    private let source = ImageSize(width: 6000, height: 4000)

    // MARK: - 1. normalized ↔ pixels

    /// The two spellings are inverses on any whole-pixel rect, at both ends of the frame.
    func testCropRectRoundTripsThroughPixels() {
        for origin in [(0, 0), (500, 250), (3999, 2999)] {
            let pixel = PixelRect(x: origin.0, y: origin.1,
                                  width: 2000 - origin.0 / 4, height: 1500 - origin.1 / 4)
            let normalized = CropMath.cropRect(pixel, in: source)
            XCTAssertEqual(CropMath.pixelRect(normalized, in: source), pixel,
                           "normalized ↔ pixel round trip broke at \(pixel.keyString)")
            // Edges, not extents: right/bottom are absolute fractions of the frame.
            XCTAssertEqual(normalized.right, Double(pixel.maxX) / 6000, accuracy: 1e-12)
            XCTAssertEqual(normalized.bottom, Double(pixel.maxY) / 4000, accuracy: 1e-12)
            XCTAssertEqual(normalized.width, Double(pixel.width) / 6000, accuracy: 1e-12)
        }
    }

    /// A full-frame crop is the whole source at 1:1 and at any preview scale — the identity promise.
    func testFullFrameCropYieldsTheWholeSource() {
        let pixels = CropMath.pixelRect(.full, in: source)
        XCTAssertEqual(pixels, PixelRect(x: 0, y: 0, width: 6000, height: 4000))
        XCTAssertEqual(CropMath.outputSize(.full, in: source), source)
        XCTAssertEqual(CropMath.renderSize(.full, in: source, scale: 1), source)
        XCTAssertEqual(CropMath.renderSize(.full, in: source, scale: 0.25),
                       ImageSize(width: 1500, height: 1000))
        XCTAssertTrue(CropRect.full.coversFrame)
    }

    /// `pixelRect` must round exactly like `RenderGraph.plan` always has, or a crop would shift the
    /// rendered size by a pixel depending on which code path asked.
    func testPixelRoundingMatchesTheGraphFormula() {
        for fraction in [0.1, 0.3333, 0.5, 0.9, 1.0] {
            let crop = CropRect(x: 0, y: 0, width: fraction, height: fraction)
            let expectedW = Int((6000.0 * fraction).rounded())
            let expectedH = Int((4000.0 * fraction).rounded())
            let out = CropMath.outputSize(crop, in: source)
            XCTAssertEqual(out.width, expectedW)
            XCTAssertEqual(out.height, expectedH)
        }
    }

    // MARK: - 2. containing rect of a rotated image (0 / 15 / −12.5 / 45 degrees)

    private func assertContaining(degrees: Double, width: Double, height: Double,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let e = CropMath.containingExtent(of: source, degrees: degrees)
        XCTAssertEqual(e.width, width, accuracy: 1e-6, "width at \(degrees)°", file: file, line: line)
        XCTAssertEqual(e.height, height, accuracy: 1e-6, "height at \(degrees)°", file: file, line: line)
    }

    func testContainingRectAtZeroDegreesIsTheSource() {
        assertContaining(degrees: 0, width: 6000, height: 4000)
    }

    func testContainingRectAt15Degrees() {
        assertContaining(degrees: 15, width: 6830.831138, height: 5416.617576)
    }

    func testContainingRectAtMinus12PointFiveDegrees() {
        // |cos| / |sin| are the same either way round: a straighten does not care about the sign.
        assertContaining(degrees: -12.5, width: 6723.534498, height: 5203.821712)
    }

    func testContainingRectAt45DegreesIsTheDiagonalBox() {
        let diagonal = 10000.0 * (2.0).squareRoot() / 2.0
        assertContaining(degrees: 45, width: diagonal, height: diagonal)
    }

    // MARK: - 3. inscribed rect (the "no clamped edge" crop)

    /// The inscribed rect keeps the source aspect and touches the sensor on exactly one axis: it is
    /// the largest picture that can be straightened without sampling outside the frame.
    func testInscribedRectKeepsAspectAndTouchesTheSensor() {
        for degrees in [0.0, 15, -12.5, 45] {
            let e = CropMath.inscribedExtent(of: source, degrees: degrees)
            let (c, s) = (abs(cos(degrees * .pi / 180)), abs(sin(degrees * .pi / 180)))
            XCTAssertEqual(e.height / e.width, 4000.0 / 6000.0, accuracy: 1e-12,
                           "aspect drifted at \(degrees)°")
            XCTAssertLessThanOrEqual(e.width * c + e.height * s, 6000.0 + 1e-6,
                                     "x extent exceeds the sensor at \(degrees)°")
            XCTAssertLessThanOrEqual(e.width * s + e.height * c, 4000.0 + 1e-6,
                                     "y extent exceeds the sensor at \(degrees)°")
            let tightX = abs(e.width * c + e.height * s - 6000.0) < 1e-6
            let tightY = abs(e.width * s + e.height * c - 4000.0) < 1e-6
            XCTAssertTrue(tightX || tightY, "not the *largest* inscribed rect at \(degrees)°")
        }
    }

    func testInscribedCropIsCentredAndFitsWithoutClamping() {
        let crop = CropMath.inscribedCrop(of: source, degrees: -12.5)
        XCTAssertEqual(crop.centerX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(crop.centerY, 0.5, accuracy: 1e-12)
        XCTAssertTrue(CropMath.fitsInsideSource(crop, in: source, degrees: -12.5))
        // …and a full-frame crop of the same angle does *not* fit: that is what straighten does.
        XCTAssertFalse(CropMath.fitsInsideSource(.full, in: source, degrees: -12.5))
    }

    // MARK: - 4. aspect lock

    private func ratio(_ crop: CropRect) -> Double {
        let px = CropMath.outputSize(crop, in: source)
        return Double(px.width) / Double(px.height)
    }

    func testSquareLockProducesASquareCrop() {
        let selection = CropRect(left: 0.2, top: 0.15, right: 0.7, bottom: 0.65)
        let locked = CropMath.fittedCrop(aspect: 1, in: selection, source: source)
        XCTAssertEqual(ratio(locked), 1, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(locked.left, selection.left - 1e-9)
        XCTAssertLessThanOrEqual(locked.right, selection.right + 1e-9)
        // Centred on the selection, not on the frame.
        XCTAssertEqual(locked.centerX, selection.centerX, accuracy: 1e-12)
        XCTAssertEqual(locked.centerY, selection.centerY, accuracy: 1e-12)
    }

    func testThreeTwoLockIsAlreadySatisfiedByAThreeTwoSelection() {
        let selection = CropRect(left: 0.2, top: 0.15, right: 0.7, bottom: 0.65)  // 3000×2000 px
        let locked = CropMath.lockedCrop(.threeTwo, in: selection, source: source)
        XCTAssertEqual(locked.left, selection.left, accuracy: 1e-12)
        XCTAssertEqual(locked.bottom, selection.bottom, accuracy: 1e-12)
        XCTAssertEqual(ratio(locked), 1.5, accuracy: 0.001)
    }

    func testFourThreeAndSixteenNineLocksConstrainBothAxes() {
        let selection = CropRect(left: 0.2, top: 0.15, right: 0.7, bottom: 0.65)
        for (lock, expected) in [(AspectLock.fourThree, 4.0 / 3.0), (.sixteenNine, 16.0 / 9.0)] {
            let locked = CropMath.lockedCrop(lock, in: selection, source: source)
            XCTAssertEqual(ratio(locked), expected, accuracy: 0.002, "\(lock.code)")
            XCTAssertTrue(locked.clamped() == locked, "\(lock.code) escaped the frame")
            XCTAssertGreaterThan(locked.width, 0)
            XCTAssertGreaterThan(locked.height, 0)
        }
    }

    func testCustomLockUsesTheGivenRatio() {
        let selection = CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)
        let twoToOne = CropMath.lockedCrop(.custom(2), in: selection, source: source)
        XCTAssertEqual(ratio(twoToOne), 2, accuracy: 0.003)
        // A degenerate ratio must not blow the rect up or produce NaNs.
        let nonsense = CropMath.lockedCrop(.custom(-1), in: selection, source: source)
        XCTAssertEqual(nonsense, selection.clamped())
        XCTAssertNil(AspectLock.custom(.nan).ratio)
    }

    /// The default lock changes nothing — not the rect, not the key text. This is the migration
    /// guarantee: a document written before `aspectLock` existed renders exactly as it did.
    func testOriginalLockLeavesTheStoredRectAlone() {
        var edit = EditModel.neutral
        edit.geometry.cropRect = CropRect(left: 0.1, top: 0.05, right: 0.9, bottom: 0.8)
        edit.geometry.rotationDegrees = 1.5
        let before = edit.geometry.renderCrop(source: source)
        edit.geometry.aspectLock = .original
        XCTAssertEqual(edit.geometry.renderCrop(source: source), before)
        // `;alg=1` is P1f's algorithm-version token (`StageAlgorithmVersion`), not a lock segment:
        // it is on every stage's material, so the claim "an unconstrained lock adds nothing" is about
        // the text *after* it. `algorithmVersion: false` is the same material without the token — the
        // pre-P1f spelling, which is where the "no segment" claim is asserted byte for byte.
        XCTAssertEqual(edit.keyMaterial(.geometry),
                       "pv=2;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=00;alg=1",
                       "the unconstrained lock must not add a key segment")
        XCTAssertEqual(edit.keyMaterial(.geometry, algorithmVersion: false),
                       "pv=2;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=00",
                       "and the parameters themselves are byte-identical to the pre-P1f material")
        edit.geometry.aspectLock = .square
        XCTAssertNotEqual(edit.keyMaterial(.geometry),
                          "pv=2;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=00;alg=1",
                          "a constraining lock must invalidate S0")
        XCTAssertTrue(edit.keyMaterial(.geometry).contains(";asp=square"))
    }

    /// An aspect lock on a *straightened* image must land inside the rotated frame — the difference
    /// between a real straighten crop and one that smears the clamped edge.
    func testLockedCropOnARotatedFrameStaysInsideTheSensor() {
        for lock in [AspectLock.square, .threeTwo, .fourThree, .sixteenNine] {
            let ratio = lock.ratio!
            let crop = CropMath.lockedCrop(aspect: ratio, source: source, degrees: -12.5)
            XCTAssertTrue(CropMath.fitsInsideSource(crop, in: source, degrees: -12.5),
                          "\(lock.code) lock samples outside the sensor")
            XCTAssertEqual(self.ratio(crop), ratio, accuracy: 0.003, "\(lock.code) ratio")
        }
    }

    // MARK: - 5. flips and straighten limits

    func testFlipCombinationsAreIndependent() {
        var seen = Set<String>()
        for h in [false, true] {
            for v in [false, true] {
                var edit = EditModel.neutral
                edit.geometry.flipH = h
                edit.geometry.flipV = v
                XCTAssertEqual(edit.geometry.flipHorizontal, h)
                XCTAssertEqual(edit.geometry.flipVertical, v)
                XCTAssertEqual(edit.geometry.isIdentity, !h && !v)
                seen.insert(edit.keyMaterial(.geometry))
            }
        }
        XCTAssertEqual(seen.count, 4, "the four flip states must be four different S0 keys")
    }

    func testStraightenIsClampedToFortyFiveDegrees() {
        var g = GeometryGroup()
        g.rotationDegrees = 60
        XCTAssertEqual(g.straightenDegrees, 45)
        g.rotationDegrees = -90
        XCTAssertEqual(g.straightenDegrees, -45)
        g.rotationDegrees = -12.5
        XCTAssertEqual(g.straightenDegrees, -12.5)
        XCTAssertEqual(GeometryGroup.straightenLimit, 45)
    }

    // MARK: - 6. clamping

    func testOutOfBoundsEdgesArePulledBackInside() {
        let wild = CropRect(left: -0.1, top: 0.9, right: 0.5, bottom: 1.2).clamped()
        XCTAssertEqual(wild.left, 0, accuracy: 1e-12)
        XCTAssertEqual(wild.top, 0.7, accuracy: 1e-12)
        XCTAssertEqual(wild.right, 0.6, accuracy: 1e-12)
        XCTAssertEqual(wild.bottom, 1.0, accuracy: 1e-12)
        XCTAssertEqual(CropMath.pixelRect(wild, in: source),
                       PixelRect(x: 0, y: 2800, width: 3600, height: 1200))
    }

    func testDegenerateCropKeepsAMinimumSpan() {
        let dot = CropRect(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5).clamped()
        XCTAssertEqual(dot.width, 0.001, accuracy: 1e-12)
        XCTAssertEqual(dot.height, 0.001, accuracy: 1e-12)
        XCTAssertGreaterThan(CropMath.outputSize(dot, in: source).width, 0)
        // A crop set through the model is clamped on the way in, never stored inverted.
        var g = GeometryGroup()
        g.cropRect = CropRect(left: 0.9, top: 0.9, right: 0.1, bottom: 0.1)
        XCTAssertLessThan(g.cropRect.left, g.cropRect.right)
        XCTAssertLessThan(g.cropRect.top, g.cropRect.bottom)
    }

    // MARK: - 7. document migration

    func testLegacyDocumentWithoutNewFieldsDecodesToDefaults() throws {
        let json = Data(#"""
        { "geometry": { "crop": { "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4 },
                        "rotationDegrees": 5, "flipHorizontal": true } }
        """#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.geometry.aspectLock, .original, "missing lock must default to no constraint")
        let rect = model.geometry.cropRect
        XCTAssertEqual(rect.left, 0.1, accuracy: 1e-12)
        XCTAssertEqual(rect.top, 0.2, accuracy: 1e-12)
        XCTAssertEqual(rect.right, 0.4, accuracy: 1e-12)
        XCTAssertEqual(rect.bottom, 0.6, accuracy: 1e-12)
        XCTAssertTrue(model.geometry.flipH)
        XCTAssertFalse(model.geometry.flipV)
    }

    func testEdgeSpelledCropRectDecodesIntoTheStoredRect() throws {
        let json = Data(#"""
        { "geometry": { "cropRect": { "left": 0.2, "top": 0.1, "right": 0.7, "bottom": 0.6 },
                        "aspectLock": "16:9" } }
        """#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        // 0.7 − 0.2 is 0.49999999999999994 in binary: compare, don't match bits.
        let stored = model.geometry.crop
        XCTAssertEqual(stored.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(stored.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(stored.width, 0.5, accuracy: 1e-12)
        XCTAssertEqual(stored.height, 0.5, accuracy: 1e-12)
        XCTAssertEqual(model.geometry.aspectLock, .sixteenNine)
        // An unknown lock is a default, never a decode failure.
        let unknown = Data(#"{ "geometry": { "aspectLock": "golden" } }"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EditModel.self, from: unknown).geometry.aspectLock,
                       .original)
    }

    func testGeometryRoundTripsThroughJSONWithTheNewFields() throws {
        var g = GeometryGroup(crop: NormalizedRect(x: 0.2, y: 0.1, width: 0.5, height: 0.5),
                              rotationDegrees: -12.5, flipHorizontal: true, flipVertical: true,
                              aspectLock: .custom(1.85))
        g.aspectLock = .custom(1.85)
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(GeometryGroup.self, from: data)
        XCTAssertEqual(back, g)
        XCTAssertEqual(back.aspectLock.ratio!, 1.85, accuracy: 1e-9)
    }

    // MARK: - 8. pixels: the recorded frames

    private struct RenderGolden: Decodable {
        let rawSHA256: String
        let edit: String
        let scale: Double
        let pixelSHA256: String
        let width: Int
        let height: Int
    }

    /// Render `edit` exactly the way `photonsctl --golden check` does and compare the digest.
    private func renderGolden(_ name: String) throws -> (golden: RenderGolden, pixels: [Float16],
                                                         width: Int, height: Int) {
        let url = Self.repoRoot.appendingPathComponent("Tests/Golden/\(name).json")
        let golden: RenderGolden
        do {
            golden = try JSONDecoder().decode(RenderGolden.self, from: Data(contentsOf: url))
        } catch {
            throw XCTSkip("no golden at \(url.path)")
        }
        let raw = try fixtureURL()
        guard try FileDigest.sha256(of: raw) == golden.rawSHA256 else {
            throw XCTSkip("\(name) was recorded against a different RAW fixture")
        }
        let decodeScale = Float(max(golden.scale, 0.125))
        // 097: decode and render must agree on the lens profile (see RenderTests' note).
        let outcome = try RAWDecoder().decodeDetailed(raw, options: DecodeOptions(decoderVersion: nil,
                                                                                 scale: decodeScale))
        let graph = try RenderGraph(input: RenderInput(image: outcome.image, identity: "cropmath-golden",
                                                        lensProfile: outcome.lensProfile))
        let model = try EditModel.load(from: Self.repoRoot
            .appendingPathComponent("Tests/Fixtures/\(golden.edit).json"))
        let result = try graph.render(model, options: RenderOptions(scale: golden.scale / Double(decodeScale),
                                                                   wantsPixels: true))
        let display = try XCTUnwrap(result.display)
        XCTAssertEqual(display.width, golden.width, "\(name): width")
        XCTAssertEqual(display.height, golden.height, "\(name): height")
        XCTAssertEqual(display.sha256(), golden.pixelSHA256,
                       "\(name): pixels moved — crop/straighten changed the frame")
        return (golden, display.rgba, display.width, display.height)
    }

    /// `cropRect = .full` must be the neutral frame, bit for bit. Pinned with the hash the existing
    /// `render-edit-neutral-s0.25.json` golden recorded before this field existed.
    func testFullFrameCropRectReproducesTheNeutralGolden() throws {
        let model = try EditModel.load(from: Self.repoRoot
            .appendingPathComponent("Tests/Fixtures/edit-neutral.json"))
        var edit = model
        edit.geometry.cropRect = .full
        XCTAssertTrue(edit.geometry.cropRect.coversFrame)
        XCTAssertEqual(edit.geometry.crop, .full)
        let (golden, pixels, width, height) = try renderGolden("render-edit-neutral-s0.25")
        XCTAssertEqual(edit.geometry.crop, model.geometry.crop,
                       "spelling the crop as edges must not move the rect")
        XCTAssertEqual(pixels.count, width * height * 4)
        _ = golden
    }

    /// One cropped + straightened frame (quarter of the frame, −12.5°): proves the two knobs compose
    /// through S0 rather than fighting in the model.
    func testCropAndStraightenFrameGolden() throws {
        let fixture = try EditModel.load(from: Self.repoRoot
            .appendingPathComponent("Tests/Fixtures/edit-crop-rot.json"))
        XCTAssertEqual(fixture.geometry.rotationDegrees, -12.5)
        XCTAssertEqual(fixture.geometry.cropRect.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fixture.geometry.cropRect.height, 0.5, accuracy: 1e-9)
        _ = try renderGolden("render-edit-crop-rot-s0.25")
    }

    // MARK: - 90° turns (P0-10)

    /// A quarter turn of a rect is `1 − x` on two edges and a swap of the four numbers — nothing else.
    /// That is what makes four turns exact for a dyadic rect, and what the document's
    /// 「转 4 次回到原帧」 rests on (`QuarterTurnTests` measures the pixels).
    func testQuarterTurnRectIsExactAfterFourTurns() {
        let rects: [(CropRect, String)] = [
            (.full, "整幅"),
            (CropRect(left: 0.125, top: 0.25, right: 0.625, bottom: 0.75), "二进制精确"),
            (CropRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.65), "任意"),
        ]
        for (rect, name) in rects {
            var turned = rect
            for k in 1...4 {
                turned = CropMath.turnedClockwise(turned)
                // `.full` is invariant (a full-frame crop stays full), so it is the case that must
                // *not* move; every other rect must.
                if k < 4, rect != .full {
                    XCTAssertNotEqual(turned.keyString, rect.keyString,
                                      "\(name): 第 \(k) 次旋转没有改变矩形")
                }
            }
            XCTAssertEqual(turned.keyString, rect.keyString,
                           "\(name): 4 次旋转后 keyString 变了")
            if name != "任意" {
                XCTAssertEqual(turned, rect, "\(name): 4 次旋转后四边不是逐位相等")
            }
            // The inverse is the inverse.
            XCTAssertEqual(CropMath.turnedCounterClockwise(CropMath.turnedClockwise(rect)).keyString,
                           rect.keyString, "\(name): 逆运算不还原")
            // Four turns of the *document* are the same rect whatever the direction used.
            XCTAssertEqual(CropMath.turned(rect, quarterTurns: 4).keyString, rect.keyString)
            XCTAssertEqual(CropMath.turned(rect, quarterTurns: -1).keyString,
                           CropMath.turnedCounterClockwise(rect).keyString, "\(name): −1 ≠ 逆时针")
        }
    }

    /// The rect turn and the point turn are the same rotation: the turned rect is the bounding box of
    /// its four turned corners, and `sourceRect` is the inverse. Two spellings of one 90°, checked
    /// against each other rather than against a second derivation.
    func testPointTurnAgreesWithTheRectTurn() {
        let rect = CropRect(left: 0.12, top: 0.2, right: 0.62, bottom: 0.75)
        let corners = [NormalizedPoint(rect.left, rect.top), NormalizedPoint(rect.right, rect.top),
                       NormalizedPoint(rect.right, rect.bottom), NormalizedPoint(rect.left, rect.bottom)]
        for turns in 0..<4 {
            let turned = CropMath.turned(rect, quarterTurns: turns)
            let points = corners.map { CropMath.turned($0, quarterTurns: turns) }
            let xs = points.map(\.x), ys = points.map(\.y)
            XCTAssertEqual(xs.min()!, turned.left, accuracy: 1e-12, "q=\(turns): left")
            XCTAssertEqual(xs.max()!, turned.right, accuracy: 1e-12, "q=\(turns): right")
            XCTAssertEqual(ys.min()!, turned.top, accuracy: 1e-12, "q=\(turns): top")
            XCTAssertEqual(ys.max()!, turned.bottom, accuracy: 1e-12, "q=\(turns): bottom")
            // sourceRect undoes it, in the rect algebra.
            XCTAssertEqual(CropMath.sourceRect(turned, quarterTurns: turns).keyString,
                           rect.clamped().keyString, "q=\(turns): sourceRect 不是逆运算")
        }
        // A quarter turn is exact on a point too: `1 − y` and a swap, no arithmetic.
        let p = NormalizedPoint(0.25, 0.5)
        XCTAssertEqual(CropMath.turned(p, quarterTurns: 1).x, 0.5, accuracy: 0)
        XCTAssertEqual(CropMath.turned(p, quarterTurns: 1).y, 0.25, accuracy: 0)
        XCTAssertEqual(CropMath.turned(p, quarterTurns: 4).x, p.x, accuracy: 0)
    }

    /// `GeometryGroup.outputPixels` is the turned frame's pixel size, and `orientedSource` is the
    /// grid it is measured against — the pair that makes 「裁剪后尺寸」 swapped rather than wrong.
    func testOutputPixelsSwapWithAnOddTurn() {
        let source = ImageSize(width: 240, height: 160)
        var geometry = GeometryGroup(crop: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let upright = geometry.outputPixels(in: source)
        XCTAssertEqual(upright, ImageSize(width: 120, height: 80))
        XCTAssertEqual(geometry.orientedSource(source), source)

        geometry.turn(clockwise: true)
        XCTAssertEqual(geometry.orientedSource(source), ImageSize(width: 160, height: 240))
        let turned = geometry.outputPixels(in: source)
        XCTAssertEqual(turned, ImageSize(width: 80, height: 120),
                       "转 90° 后同一块像素的长宽必须交换")
        XCTAssertEqual(turned, ImageSize(width: upright.height, height: upright.width))

        // A 1:1 lock stays 1:1 through a turn (the ratio inversion is what does it); 3:2 becomes 2:3.
        geometry.aspectLock = .square
        geometry.turn(clockwise: true)
        XCTAssertEqual(geometry.aspectLock, .square, "1:1 转 90° 还是 1:1")
        geometry.aspectLock = .threeTwo
        geometry.turn(clockwise: true)
        if let ratio = geometry.aspectLock.ratio {
            XCTAssertEqual(ratio, 2.0 / 3.0, accuracy: 1e-12, "3:2 转 90° 应该是 2:3")
        } else {
            XCTFail("转 90° 不该把比例锁丢掉")
        }
    }
}
