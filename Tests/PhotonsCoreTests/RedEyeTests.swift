import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 229 — 红眼 / 宠物眼: the detector, the renderer's red gate, and the additive document.
///
/// The acceptance is in three numbers, measured on the shipped path (`RenderGraph` → S1.9):
///
///   1. **The pupil is found.** A 512 × 512 neutral face with two pure-red disks (r = 6 / 10 px,
///      `r = 1, g = b = 0.05`); a click inside one returns a `Detection` whose radius covers it.
///   2. **The red goes away, the neighbours do not move.** `max(r − max(g,b))` inside the clicked
///      disk goes from > 0.9 to < 0.15, and every byte outside the disk is identical.
///   3. **No red, no repair.** A click on skin / an empty wall writes a spot (`redThreshold =
///      RedEye.noopThreshold`) whose pixels are the baseline, byte for byte — the negative gate.
final class RedEyeTests: XCTestCase {

    // MARK: - fixtures

    private static let size = ImageSize(width: 512, height: 512)
    private static let bigCircle = (x: 170.5, y: 256.5, r: 10.0)
    private static let smallCircle = (x: 342.5, y: 256.5, r: 6.0)

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A neutral, slightly warm face with a gentle vertical light falloff — enough structure that
    /// the heal source is a real patch, not a constant field. Two pure-red disks sit on it.
    private func face(identity: String) -> LinearImage {
        let w = Self.size.width, h = Self.size.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = 0.52 + 0.06 * (1 - Double(y) / Double(h))
                var r = v, g = v * 0.94, b = v * 0.88
                if inCircle(x, y, Self.bigCircle) || inCircle(x, y, Self.smallCircle) {
                    r = 1; g = 0.05; b = 0.05
                }
                let o = (y * w + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-redeye-\(identity)")
    }

    private func inCircle(_ x: Int, _ y: Int,
                          _ circle: (x: Double, y: Double, r: Double)) -> Bool {
        let dx = Double(x) + 0.5 - circle.x
        let dy = Double(y) + 0.5 - circle.y
        return (dx * dx + dy * dy).squareRoot() <= circle.r
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 8,
                                                            headroom: 1, linearOutput: true),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    /// The acceptance's own unit: **raw scene-linear** `r − max(g,b)`. (The renderer's gate uses the
    /// display-encoded definition in `RedEye.redness`; the fixture's 1 / 0.05 numbers are linear.)
    private func linearRedness(_ image: DisplayImage, x: Int, y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return Double(image.rgba[o]) - max(Double(image.rgba[o + 1]), Double(image.rgba[o + 2]))
    }

    private func maxRedness(_ image: DisplayImage,
                            _ circle: (x: Double, y: Double, r: Double)) -> Double {
        var peak = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width where inCircle(x, y, circle) {
                peak = max(peak, linearRedness(image, x: x, y: y))
            }
        }
        return peak
    }

    /// Bytes of every pixel **outside** the given circle. This is the "圆外逐码不变" comparison.
    private func outsideBytes(_ image: DisplayImage,
                              _ circle: (x: Double, y: Double, r: Double)) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<image.height {
            for x in 0..<image.width where !inCircle(x, y, circle) {
                let o = (y * image.width + x) * 4
                for c in 0..<4 {
                    bytes.append(contentsOf: withUnsafeBytes(of: image.rgba[o + c]) { Array($0) })
                }
            }
        }
        return bytes
    }

    private func allBytes(_ image: DisplayImage) -> [UInt8] {
        image.rgba.withUnsafeBytes { Array($0) }
    }

    private func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func spot(for detection: RedEye.Detection, image: LinearImage,
                      threshold: Double = RedEye.defaultThreshold) -> HealSpot {
        let source = RedEye.neutralSource(in: image, center: detection.center,
                                          radius: detection.radius, threshold: threshold)?.offset
            ?? HealSpot.defaultSourceOffset(radius: detection.radius)
        return HealSpot(center: detection.center, radius: detection.radius,
                        sourceOffset: source, mode: .heal, feather: 0, opacity: 1,
                        kind: .redeye, redThreshold: threshold)
    }

    // MARK: - 1. the detector

    func testTheDetectorFindsThePupilAndReportsItsNumbers() throws {
        let image = face(identity: "detect")
        let click = NormalizedPoint(Self.bigCircle.x / 512, Self.bigCircle.y / 512)
        let detection = try XCTUnwrap(RedEye.detect(in: image, near: click,
                                                    searchRadius: 0.06,
                                                    threshold: RedEye.defaultThreshold))
        print("RedEye detection: pixels=\(detection.pixelCount) extent=\(detection.extentPixels)"
              + " radius=\(detection.radius) peak=\(detection.peakRedness)"
              + " mean=\(detection.meanRedness) fraction=\(detection.redFraction)")
        XCTAssertGreaterThanOrEqual(detection.pixelCount, 250, "10 px 半径的圆约 314 个像素")
        XCTAssertGreaterThan(detection.peakRedness, 0.7, "纯红瞳在 display redness 上应远高于阈值")
        XCTAssertGreaterThan(detection.redFraction, 0.05,
                             "圆的面积 / 搜索窗面积 ≈ 8 %（窗口是 0.06 短边）")
        XCTAssertEqual(detection.center.x, Self.bigCircle.x / 512, accuracy: 0.01)
        XCTAssertEqual(detection.center.y, Self.bigCircle.y / 512, accuracy: 0.01)
        // The repair disk covers the whole red component: extent + a 1.5 px rim.
        XCTAssertGreaterThanOrEqual(detection.radius * 512, Self.bigCircle.r)
        XCTAssertLessThan(detection.radius * 512, Self.bigCircle.r + 8)

        // The negative half of the detector: no red pixels, no detection.
        XCTAssertNil(RedEye.detect(in: image, near: NormalizedPoint(0.5, 0.1),
                                   searchRadius: 0.06,
                                   threshold: RedEye.defaultThreshold))
    }

    /// A big red object (a lip / shirt / ruddy cheek) is refused by the extent cap rather than
    /// repaired as a pupil. This is the false-positive guard the negative acceptance is about.
    func testALargeRedRegionIsNotAPupil() {
        let w = 512, h = 512
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let red = x >= 200 && x < 300 && y >= 200 && y < 300
                let o = (y * w + x) * 4
                rgba[o] = Float16(red ? 1 : 0.5)
                rgba[o + 1] = Float16(red ? 0.05 : 0.48)
                rgba[o + 2] = Float16(red ? 0.05 : 0.46)
                rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: "extendedLinearSRGB",
                                decoderVersion: "synthetic-redeye-large")
        XCTAssertNil(RedEye.detect(in: image, near: NormalizedPoint(0.5, 0.5),
                                   searchRadius: 0.05),
                     "100 px 的红块是红物体，不是瞳孔（上限 8 % 短边 = 41 px）")
    }

    // MARK: - 2. the render

    func testRedEyeRemovesTheRedAndLeavesEveryOutsideByteAlone() throws {
        let image = face(identity: "repair")
        let graph = try makeGraph(image, identity: "redeye-repair")
        let cleaned = try display(graph, .neutral)

        let click = NormalizedPoint(Self.bigCircle.x / 512, Self.bigCircle.y / 512)
        let detection = try XCTUnwrap(RedEye.detect(in: image, near: click, searchRadius: 0.06))
        var doc = EditModel.neutral
        doc.healSpots = [spot(for: detection, image: image)]
        let repaired = try display(graph, doc)

        let before = maxRedness(cleaned, Self.bigCircle)
        let after = maxRedness(repaired, Self.bigCircle)
        print("RedEye repair: max linear redness \(before) → \(after)")
        XCTAssertGreaterThan(before, 0.9, "夹具的红瞳必须真的是红的")
        XCTAssertLessThan(after, 0.15, "修补后红瞳不得再有明显红色")

        // Every pixel outside the red disk is byte-identical. The disk's own soft edge is the red
        // gate, not a feather, so a non-red neighbour inside the spot is untouched too.
        let outsideBefore = outsideBytes(cleaned, Self.bigCircle)
        let outsideAfter = outsideBytes(repaired, Self.bigCircle)
        XCTAssertEqual(sha(outsideBefore), sha(outsideAfter), "圆外像素必须逐码不变")
        // The control: the clicked circle *did* move, so the assertion above is not vacuous.
        XCTAssertNotEqual(sha(allBytes(cleaned)), sha(allBytes(repaired)))
    }

    // MARK: - 3. the negative gate

    func testANonRedClickChangesNoPixel() throws {
        let image = face(identity: "noop")
        let graph = try makeGraph(image, identity: "redeye-noop")
        let cleaned = try display(graph, .neutral)

        let click = NormalizedPoint(0.5, 0.1)
        XCTAssertNil(RedEye.detect(in: image, near: click, searchRadius: 0.06),
                     "皮肤上没有红瞳，检测必须返回 nil")

        var doc = EditModel.neutral
        doc.healSpots = [HealSpot(center: click, radius: 0.03,
                                  sourceOffset: NormalizedPoint(0.06, 0), mode: .heal,
                                  feather: 0, opacity: 1, kind: .redeye,
                                  redThreshold: RedEye.noopThreshold)]
        let after = try display(graph, doc)
        XCTAssertEqual(sha(allBytes(cleaned)), sha(allBytes(after)),
                       "没有红瞳的点击不得改一个像素（假阳 = 红）")

        // And with the default gate, a neutral field still has nothing to repair.
        doc.healSpots[0].redThreshold = RedEye.defaultThreshold
        let defaultGate = try display(graph, doc)
        XCTAssertEqual(sha(allBytes(cleaned)), sha(allBytes(defaultGate)),
                       "中性像素低于阈值，默认门也不得动它")
    }

    // MARK: - 4. the document is additive

    func testKindIsAdditiveAndAnOldHealSpotReEncodesByteForByte() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let heal = HealSpot(id: "h-old", center: NormalizedPoint(0.4, 0.6), radius: 0.05,
                            sourceOffset: NormalizedPoint(0.1, 0), mode: .clone,
                            feather: 0.2, opacity: 1)
        let healJSON = String(decoding: try encoder.encode(heal), as: UTF8.self)
        XCTAssertFalse(healJSON.contains("kind"), "旧 spot 不写 kind，逐字节兼容")
        XCTAssertFalse(healJSON.contains("redThreshold"))
        XCTAssertFalse(healJSON.contains("redSoftness"))

        let old = """
        {"center":[0.4,0.6],"feather":0.2,"id":"h-old","mode":"clone","opacity":1,
         "radius":0.05,"sourceOffset":[0.1,0]}
        """
        let decoded = try JSONDecoder().decode(HealSpot.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.kind, .heal, "缺省 kind = .heal")
        XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), healJSON)
        XCTAssertEqual(decoded.keyString, heal.keyString, "旧 spot 的渲染 key 不变")

        let red = HealSpot(id: "h-red", center: NormalizedPoint(0.5, 0.5), radius: 0.03,
                           sourceOffset: NormalizedPoint(0.06, 0), mode: .heal,
                           feather: 0, opacity: 1, kind: .redeye,
                           redThreshold: 0.2, redSoftness: 0.06)
        let back = try JSONDecoder().decode(HealSpot.self, from: try encoder.encode(red))
        XCTAssertEqual(back.kind, .redeye)
        XCTAssertEqual(back.redThreshold, 0.2)
        XCTAssertEqual(back.redSoftness, 0.06)
        XCTAssertEqual(back, red)
        XCTAssertNotEqual(back.keyString, heal.keyString)
    }

    // MARK: - 5. the Vision geometry (no model needed)

    func testEyeLandmarkBoxConversionUsesTheFaceAndFlipsY() throws {
        // A face occupying the middle of the image; an eye region occupying the upper-left quarter
        // of that face in Vision's bottom-left coordinates.
        let face = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let points = [CGPoint(x: 0.1, y: 0.6), CGPoint(x: 0.3, y: 0.6),
                      CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.8)]
        let rect = try XCTUnwrap(RedEyeVision.eyeRect(faceBounds: face, points: points))
        XCTAssertEqual(rect.x, 0.24, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.08, accuracy: 1e-9)
        // bottom = 0.3 + 0.6·0.5 = 0.6; height = 0.2·0.5 = 0.1 → top = 1 − 0.7 = 0.3.
        XCTAssertEqual(rect.y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.1, accuracy: 1e-9)

        XCTAssertNil(RedEyeVision.eyeRect(faceBounds: face, points: []))
    }
}
