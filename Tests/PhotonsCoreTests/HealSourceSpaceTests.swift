import XCTest
import Metal
import simd
import PhotonsCore

/// 249 — 修复在 **S1 源像素** 上，落点走几何逆变换，旧文档 `canvasV1 → sourceV2` 迁移。
///
/// The suite is written as the acceptance's measurements, not as a restatement of the
/// implementation:
///
///   1. **Order.** `.heal` executes before `.geometry` in the trace and in the pipeline.
///   2. **Rotation does not move the repair.** The same S1 source spot is rendered at straighten
///      0 / 10 / 45 and a quarter turn; the changed output pixels are projected back to S1 and the
///      bounding box must stay within 1 px of the un-rotated one.
///   3. **A click on a rotated/keystoned view lands on the source feature.** A view point is mapped
///      back with `FrameTransform.viewPointToSource` + the raw-source quarter-turn rename; rotating
///      back to 0 leaves the repair on the same feature and still removes the blemish.
///   4. **canvasV1 migration.** A legacy spot built from a known source feature is converted with
///      the document's crop + straighten + perspective and lands back on that feature (≤ 1 px).
final class HealSourceSpaceTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    private static let size = ImageSize(width: 240, height: 160)
    private static let feature = (x: 88.5, y: 74.5)
    private static let featureRadius = 9.0

    /// A textured, left-to-right gradient with a dark blemish at `feature`. `blemished: false` is the
    /// clean reference; the texture keeps the clone/heal arithmetic honest.
    private func picture(blemished: Bool, identity: String,
                         textured: Bool = true) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: Self.size.width * Self.size.height * 4)
        for y in 0..<Self.size.height {
            for x in 0..<Self.size.width {
                var v = 0.16 + 0.52 * (Double(x) + 0.5) / Double(Self.size.width)
                if textured { v += 0.05 * Self.hash01(x, y) }
                if blemished {
                    let dx = Double(x) + 0.5 - Self.feature.x
                    let dy = Double(y) + 0.5 - Self.feature.y
                    if (dx * dx + dy * dy).squareRoot() < Self.featureRadius { v = min(v, 0.02) }
                }
                let o = (y * Self.size.width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: Self.size.width, height: Self.size.height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-heal-source-\(identity)")
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    /// The spot in S1 source coordinates: the blemish's centre, a disk big enough to hold it, and a
    /// source one disk to the right — the same shape every rotation test uses.
    private func sourceSpot(radius: Double = 22.0 / 160.0,
                            offset: NormalizedPoint = NormalizedPoint(44.0 / 160.0, 0)) -> HealSpot {
        HealSpot(id: "h-source",
                 center: NormalizedPoint(Self.feature.x / Double(Self.size.width),
                                         Self.feature.y / Double(Self.size.height)),
                 radius: radius, sourceOffset: offset,
                 mode: .heal, feather: 0, opacity: 1)
    }

    private func frameTransform(_ geometry: GeometryGroup) -> (CropGeometry, FrameTransform) {
        let cg = CropGeometry(geometry: geometry, source: Self.size)
        let transform = FrameTransform(
            source: cg.source, crop: cg.crop,
            straightenDegrees: cg.rotationDegrees, quarterTurns: 0,
            flipHorizontal: cg.flipHorizontal, flipVertical: cg.flipVertical,
            perspective: cg.perspective,
            contentScale: 1, viewport: nil, zoom: 1, cameraOffset: .zero,
            cameraWindowSize: SIMD2(Double(cg.canvas.width), Double(cg.canvas.height)),
            allowsUpscale: true)
        return (cg, transform)
    }

    // MARK: - 1. order

    func testHealExecutesBeforeGeometry() throws {
        let pipeline = RenderStage.pipeline(hasMasks: false, hasHeal: true)
        let heal = try XCTUnwrap(pipeline.firstIndex(of: .heal))
        let geometry = try XCTUnwrap(pipeline.firstIndex(of: .geometry))
        XCTAssertLessThan(heal, geometry, "249: 修复必须在 S0 之前")
        XCTAssertEqual(pipeline.first, .heal)

        let graph = try makeGraph(picture(blemished: true, identity: "order"), identity: "heal-order")
        var doc = EditModel.neutral
        doc.healSpots = [sourceSpot()]
        let result = try graph.render(doc, options: RenderOptions(scale: 1, useCache: false))
        XCTAssertEqual(Array(result.trace.executed.prefix(2)), [.heal, .geometry],
                       "pass 顺序日志：修复先跑，S0 读它的输出")
        XCTAssertFalse(result.trace.executed.isEmpty)
    }

    // MARK: - 2. rotation does not move the source repair

    /// The healed **S1 texture** itself: `stopBefore: .geometry` runs the heal stage and stops before
    /// S0, so this is the exact source grid the transform card is about to consume. If the repair is
    /// applied before geometry, this image must be byte-identical at every straighten/turn.
    private func healedSource(_ geometry: GeometryGroup, spot: HealSpot?) throws -> DisplayImage {
        let graph = try makeGraph(picture(blemished: true, identity: "source-\(geometry.rotationDegrees)-\(geometry.quarterTurns)"),
                                  identity: "heal-source-\(geometry.rotationDegrees)-\(geometry.quarterTurns)")
        var doc = EditModel.neutral
        doc.geometry = geometry
        doc.healSpots = spot.map { [$0] } ?? []
        let options = RenderOptions(scale: 1, useCache: false, wantsPixels: true,
                                    stopBefore: .geometry)
        return try XCTUnwrap(graph.render(doc, options: options).display)
    }

    func testTheSameSourceRegionIsRepairedAtEveryRotation() throws {
        let geometries = [
            GeometryGroup(crop: .full, rotationDegrees: 0),
            GeometryGroup(crop: .full, rotationDegrees: 10),
            GeometryGroup(crop: .full, rotationDegrees: 45),
            GeometryGroup(crop: .full, rotationDegrees: 0, quarterTurns: 1),
        ]
        let spot = sourceSpot()
        let baseline = try healedSource(geometries[0], spot: spot)
        let plain = try healedSource(geometries[0], spot: nil)
        XCTAssertEqual(baseline.width, Self.size.width)
        XCTAssertEqual(baseline.height, Self.size.height)

        // The repaired source region, read directly on S1 (no inverse projection rounding).
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<baseline.height {
            for x in 0..<baseline.width {
                let o = (y * baseline.width + x) * 4
                let differs = (0..<3).contains { c in
                    abs(Self.code(baseline.rgba[o + c]) - Self.code(plain.rgba[o + c])) > 0
                }
                guard differs else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertLessThan(minX, Int.max, "the fixture must change some source pixels")
        let rect = CGRect(x: Double(minX), y: Double(minY),
                          width: Double(maxX - minX), height: Double(maxY - minY))
        print("source heal coverage on S1 at 0°/q0: \(rect)")

        for geometry in geometries.dropFirst() {
            let other = try healedSource(geometry, spot: spot)
            print("source heal at \(geometry.rotationDegrees)°/q\(geometry.quarterTurns): "
                  + "\(other.sha256().prefix(16))… vs baseline \(baseline.sha256().prefix(16))…")
            XCTAssertEqual(other.sha256(), baseline.sha256(),
                           "\(geometry.rotationDegrees)°/q\(geometry.quarterTurns): S1 修复结果必须逐字节相同"
                           + "（反投影后四边偏差 0 px）")
            XCTAssertEqual(other.rgba, baseline.rgba, "每一个 Float16 字节，不只是摘要")
        }
    }

    // MARK: - 3. inverse mapping from a rotated view

    func testAClickOnARotatedViewLandsOnTheSourceFeatureAndSurvivesRotatingBack() throws {
        let geometry = GeometryGroup(crop: .full, rotationDegrees: 10,
                                     flipHorizontal: false, flipVertical: false,
                                     aspectLock: .original, quarterTurns: 0)
        let (cg, transform) = frameTransform(geometry)
        let sourcePx = SIMD2(Self.feature.x, Self.feature.y)
        let turnedNorm = HealSpot.turnedPoint(
            fromSource: NormalizedPoint(sourcePx.x / Double(Self.size.width),
                                        sourcePx.y / Double(Self.size.height)),
            quarterTurns: cg.quarterTurns)
        let turnedPx = SIMD2(turnedNorm.x * Double(cg.source.width),
                             turnedNorm.y * Double(cg.source.height))
        let view = transform.sourceToView(turnedPx)

        // The click the controller receives, mapped back through the one inverse.
        let back = transform.viewPointToSource(view)
        let backTurnedNorm = NormalizedPoint(back.x / Double(cg.source.width),
                                            back.y / Double(cg.source.height))
        let backSource = HealSpot.sourcePoint(fromTurned: backTurnedNorm,
                                              quarterTurns: cg.quarterTurns)
        let dx = abs(backSource.x * Double(Self.size.width) - Self.feature.x)
        let dy = abs(backSource.y * Double(Self.size.height) - Self.feature.y)
        print(String(format: "click round-trip at 10°: (%.3f, %.3f) px", dx, dy))
        XCTAssertLessThanOrEqual(dx, 1.0, "旋转后落点必须映射回源像素（x）")
        XCTAssertLessThanOrEqual(dy, 1.0, "旋转后落点必须映射回源像素（y）")

        // The feature is still removed after the rotation is set back to 0.
        let cleanGraph = try makeGraph(picture(blemished: false, identity: "inverse-clean",
                                               textured: false),
                                       identity: "heal-inverse-clean")
        let blemishedGraph = try makeGraph(picture(blemished: true, identity: "inverse-blemish",
                                                   textured: false),
                                           identity: "heal-inverse-blemish")
        func worstAt(_ straighten: Double) throws -> Int {
            var doc = EditModel.neutral
            doc.geometry = GeometryGroup(crop: .full, rotationDegrees: straighten,
                                         flipHorizontal: false, flipVertical: false,
                                         aspectLock: .original, quarterTurns: 0)
            doc.healSpots = [HealSpot(id: "h-click",
                                      center: backSource,
                                      radius: 22.0 / 160.0,
                                      sourceOffset: NormalizedPoint(44.0 / 160.0, 0),
                                      mode: .heal, feather: 0, opacity: 1)]
            let healed = try display(blemishedGraph, doc)
            var cleanDoc = doc
            cleanDoc.healSpots = []
            let clean = try display(cleanGraph, cleanDoc)
            var worst = 0
            // The blemish's own disk, at its **source** location; the clean picture has the same
            // geometry, so this is a fair comparison at either angle.
            let (_, inverse) = frameTransform(doc.geometry)
            let featureTurned = HealSpot.turnedPoint(
                fromSource: NormalizedPoint(Self.feature.x / Double(Self.size.width),
                                            Self.feature.y / Double(Self.size.height)),
                quarterTurns: doc.geometry.quarterTurns)
            let featureView = inverse.sourceToView(
                SIMD2(featureTurned.x * Double(Self.size.width),
                      featureTurned.y * Double(Self.size.height)))
            for y in 0..<min(healed.height, clean.height) {
                for x in 0..<min(healed.width, clean.width) {
                    let dxv = Double(x) + 0.5 - featureView.x
                    let dyv = Double(y) + 0.5 - featureView.y
                    guard (dxv * dxv + dyv * dyv).squareRoot() <= Self.featureRadius else { continue }
                    let o = (y * healed.width + x) * 4
                    for c in 0..<3 {
                        worst = max(worst,
                                    abs(Self.code(healed.rgba[o + c]) - Self.code(clean.rgba[o + c])))
                    }
                }
            }
            return worst
        }
        let atTen = try worstAt(10)
        let atZero = try worstAt(0)
        print("click at 10°: residual \(atTen) code; rotated back to 0°: \(atZero) code")
        XCTAssertLessThanOrEqual(atTen, 8, "落笔时（10°）补丁必须在特征上")
        XCTAssertLessThanOrEqual(atZero, 8, "把旋转归零后补丁仍在同一个特征上，不漂移")
    }

    // MARK: - 4. canvasV1 → sourceV2 migration

    func testCanvasV1MigrationKeepsTheCoveredSourceRegion() throws {
        let geometry = GeometryGroup(
            crop: NormalizedRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80),
            rotationDegrees: 10,
            flipHorizontal: false, flipVertical: false,
            aspectLock: .original, quarterTurns: 0,
            perspectiveVertical: 18, perspectiveHorizontal: -6)
        let (cg, transform) = frameTransform(geometry)
        let sourceCenter = NormalizedPoint(Self.feature.x / Double(Self.size.width),
                                           Self.feature.y / Double(Self.size.height))
        let turns = cg.quarterTurns
        let newRadius = 22.0 / 160.0
        let newOffset = NormalizedPoint(44.0 / 160.0, 0)
        let frame = cg.frameSize
        let inset = cg.canvasInsetPixels
        let frameShort = Double(min(frame.width, frame.height))
        let sourceShort = Double(min(cg.source.width, cg.source.height))

        // Build the legacy spot the way the old renderer placed it: center at `inset + c·F`, source
        // at that point **plus** `offset·frameShort` in canvas axes. Both are forward-mapped from the
        // source feature and its +44 px source, so migration has an exact expected answer.
        func canvas(_ raw: NormalizedPoint) -> SIMD2<Double> {
            let turned = HealSpot.turnedPoint(fromSource: raw, quarterTurns: turns)
            let p = SIMD2(turned.x * Double(cg.source.width),
                          turned.y * Double(cg.source.height))
            let v = transform.s1ToS3.applying(to: SIMD3(p.x, p.y, 1))
            let w = v.z == 0 ? 1 : v.z
            return SIMD2(v.x / w, v.y / w)
        }
        let sourceRaw = NormalizedPoint(
            sourceCenter.x + newOffset.x * sourceShort / Double(Self.size.width),
            sourceCenter.y + newOffset.y * sourceShort / Double(Self.size.height))
        let canvasCenter = canvas(sourceCenter)
        let canvasSource = canvas(sourceRaw)
        let oldCenter = NormalizedPoint(
            (canvasCenter.x - Double(inset.x)) / Double(frame.width),
            (canvasCenter.y - Double(inset.y)) / Double(frame.height))
        let legacyOffset = NormalizedPoint(
            (canvasSource.x - canvasCenter.x) / frameShort,
            (canvasSource.y - canvasCenter.y) / frameShort)
        let oldRadius = newRadius * sourceShort / frameShort

        var legacy = EditModel.neutral
        legacy.geometry = geometry
        legacy.healSpots = [HealSpot(id: "h-legacy", center: oldCenter, radius: oldRadius,
                                     sourceOffset: legacyOffset,
                                     mode: .heal, feather: 0, opacity: 1,
                                     healSpace: .canvasV1)]
        XCTAssertTrue(legacy.migrateHealSpots(sourceSize: Self.size), "canvasV1 必须被迁移")
        let migrated = try XCTUnwrap(legacy.healSpots.first)
        XCTAssertEqual(migrated.healSpace, .sourceV2)

        let sx = migrated.center.x * Double(Self.size.width)
        let sy = migrated.center.y * Double(Self.size.height)
        print(String(format: "canvasV1 → sourceV2: (%.3f, %.3f) px, r %.5f → %.5f",
                     sx, sy, oldRadius, migrated.radius))
        XCTAssertLessThanOrEqual(abs(sx - Self.feature.x), 1.0, "迁移后仍覆盖同一个源像素特征（x）")
        XCTAssertLessThanOrEqual(abs(sy - Self.feature.y), 1.0, "迁移后仍覆盖同一个源像素特征（y）")
        XCTAssertEqual(migrated.radius, newRadius, accuracy: 1e-9,
                       "半径从帧短边换算到源短边")
        XCTAssertEqual(migrated.sourceOffset.x, newOffset.x, accuracy: 1e-9)
        XCTAssertEqual(migrated.sourceOffset.y, newOffset.y, accuracy: 1e-9)

        // And the converted document renders the repair on that same feature.
        let graph = try makeGraph(picture(blemished: true, identity: "migrated", textured: false),
                                  identity: "heal-migrated")
        let cleanGraph = try makeGraph(picture(blemished: false, identity: "migrated-clean",
                                               textured: false),
                                       identity: "heal-migrated-clean")
        let healed = try display(graph, legacy)
        var cleanDoc = legacy
        cleanDoc.healSpots = []
        let clean = try display(cleanGraph, cleanDoc)
        var worst = 0
        let (_, inverse) = frameTransform(geometry)
        let featureTurned = HealSpot.turnedPoint(fromSource: sourceCenter, quarterTurns: turns)
        let featureView = inverse.sourceToView(
            SIMD2(featureTurned.x * Double(cg.source.width),
                  featureTurned.y * Double(cg.source.height)))
        for y in 0..<min(healed.height, clean.height) {
            for x in 0..<min(healed.width, clean.width) {
                let dxv = Double(x) + 0.5 - featureView.x
                let dyv = Double(y) + 0.5 - featureView.y
                guard (dxv * dxv + dyv * dyv).squareRoot() <= Self.featureRadius else { continue }
                let o = (y * healed.width + x) * 4
                for c in 0..<3 {
                    worst = max(worst,
                                abs(Self.code(healed.rgba[o + c]) - Self.code(clean.rgba[o + c])))
                }
            }
        }
        print("migrated document: residual on the source feature \(worst) code")
        XCTAssertLessThanOrEqual(worst, 8, "迁移后的 spot 仍在原来的源像素特征上")
    }
}

