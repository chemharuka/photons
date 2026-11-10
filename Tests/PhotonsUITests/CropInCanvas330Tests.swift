import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// **330 — 透视不会把裁剪框也透视：裁切框是**文档画布**上的矩形。**
///
/// 用户的次序一直是 **先透视 → 再旋转 → 再裁切**。裁切发生在变换之后，所以裁切矩形属于
/// 「变换后的画布空间」（324 的 `photoCanvas`），在那里它天生是正矩形；被透视的是**框里的画面**。
///
/// 每一条验收都在这个文件里重新算一遍几何（`P → R` 的闭式、旋转的 `cos/sin`、点是否在四边形内
/// 的符号距离），不读回 `CropGeometry` 的实现，这样两边一旦不一致就会露出来而不是互相抵消。
final class CropInCanvas330Tests: XCTestCase {

    /// 验收 ① 的四组透视与三个角度；`(+30,−15)` 让四边形在两个轴上都是斜的。
    private static let keystones: [(vertical: Double, horizontal: Double)] =
        [(0, 0), (30, 0), (30, -15), (0, 25)]
    private static let angles: [Double] = [0, 9, 45]

    /// 文档几何按出货的 3:2 画幅测量；渲染用一张小图。
    private static let source = ImageSize(width: 1200, height: 800)
    private static let renderSource = ImageSize(width: 480, height: 320)

    // MARK: - 本文件自己的几何（闭式，不读 CropMath）

    /// `P` 然后 `R`，在**照片像素**里 —— 用户的次序，照字面写出来。
    private func warpAndTurn(_ corner: (Double, Double), vertical: Double, horizontal: Double,
                             degrees: Double, source: ImageSize) -> CGPoint {
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let w = Double(source.width), h = Double(source.height)
        let warped = map.forward(x: corner.0, y: corner.1)
        let px = warped.x * w - w / 2, py = warped.y * h - h / 2
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        return CGPoint(x: px * c - py * s + w / 2, y: px * s + py * c + h / 2)
    }

    /// 照片四角（`P → R`，未减 AABB 原点）与它们的 AABB —— 文档画布的自身定义。
    private func photoCorners(vertical: Double, horizontal: Double, degrees: Double,
                              source: ImageSize) -> (corners: [CGPoint], minX: Double, minY: Double,
                                                     width: Double, height: Double) {
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            warpAndTurn($0, vertical: vertical, horizontal: horizontal, degrees: degrees, source: source)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return (corners, minX, minY, xs.max()! - minX, ys.max()! - minY)
    }

    /// 一个**画布归一化**点在文档画布像素里的位置（闭式：`AABB 原点 + 归一化 × 画布尺寸`）。
    private func documentPoint(_ normalized: (Double, Double), vertical: Double, horizontal: Double,
                               degrees: Double, source: ImageSize) -> CGPoint {
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        return CGPoint(x: normalized.0 * photo.width, y: normalized.1 * photo.height)
    }

    /// **反向**：文档画布像素 → 照片归一化。`R⁻¹` 后 `P⁻¹`，两步都在本文件里。
    private func photoNormalized(document: CGPoint, vertical: Double, horizontal: Double,
                                 degrees: Double, source: ImageSize) -> (Double, Double) {
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        let w = Double(source.width), h = Double(source.height)
        let x = Double(document.x) + photo.minX - w / 2
        let y = Double(document.y) + photo.minY - h / 2
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        let unrotated = (x * c + y * s, -x * s + y * c)
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let p = map.inverse(x: (unrotated.0 + w / 2) / w, y: (unrotated.1 + h / 2) / h)
        return (p.x, p.y)
    }

    /// 有符号距离（像素，向内为正）到凸多边形 `polygon`。
    private func inset(_ point: CGPoint, in polygon: [CGPoint]) -> Double {
        let cx = polygon.reduce(0) { $0 + Double($1.x) } / Double(polygon.count)
        let cy = polygon.reduce(0) { $0 + Double($1.y) } / Double(polygon.count)
        var worst = Double.infinity
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
            let len = (ex * ex + ey * ey).squareRoot()
            guard len > 1e-12 else { continue }
            var nx = ey / len, ny = -ex / len
            if nx * (cx - Double(a.x)) + ny * (cy - Double(a.y)) > 0 { nx = -nx; ny = -ny }
            worst = min(worst, -(nx * (Double(point.x) - Double(a.x))
                                 + ny * (Double(point.y) - Double(a.y))))
        }
        return worst
    }

    /// 四边相对水平/垂直的**偏角**，取最大值（度）。
    private func worstEdgeAngle(_ quad: [CGPoint]) -> (worst: Double, angles: [Double]) {
        guard quad.count == 4 else { return (180, []) }
        var angles: [Double] = []
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            // 第 0/2 边应当水平，第 1/3 边应当竖直：偏角就是与最近那条轴的夹角。
            let raw = atan2(abs(dy), abs(dx)) * 180 / .pi
            angles.append(index % 2 == 0 ? raw : abs(90 - raw))
        }
        return (angles.max() ?? 180, angles)
    }

    /// 验收数字的**取数通道**：XCTest 的 stdout 在 `swift test --skip-build` 下不一定被收进日志，
    /// 所以每一行也存进这里，由最后跑的那条用例写进 `$PHOTONS_330_REPORT`（不设就不写文件）。
    nonisolated(unsafe) private static var report: [String] = []

    private func note(_ line: String) {
        print(line)
        Self.report.append(line)
    }

    private func label(_ vertical: Double, _ horizontal: Double) -> String {
        String(format: "透视(%+.0f,%+.0f)", vertical, horizontal)
    }

    private func geometry(vertical: Double, horizontal: Double, degrees: Double,
                          crop: CropRect = .full,
                          cropSpace: CropSpace = .canvas,
                          source: ImageSize = CropInCanvas330Tests.source) -> CropGeometry {
        let group = GeometryGroup(crop: crop.normalizedRect,
                                  rotationDegrees: degrees,
                                  aspectLock: .original,
                                  quarterTurns: 0,
                                  perspectiveVertical: vertical,
                                  perspectiveHorizontal: horizontal,
                                  cropSpace: cropSpace)
        return CropGeometry(geometry: group, source: source)
    }

    /// 文档画布归一化的中心框，`0.5 ± span/2`。
    private func centred(span: Double) -> CropRect {
        CropRect(left: 0.5 - span / 2, top: 0.5 - span / 2,
                 right: 0.5 + span / 2, bottom: 0.5 + span / 2)
    }

    // MARK: - ① 框是矩形：屏幕四边与轴夹角 ≤ 0.05°

    /// 12 组（4 组透视 × 3 组拉直）：同一个框，**修前**（裁切量在源空间 → `documentQuad` 把它
    /// `P → R` 成四边形）与**修后**（裁切量在画布上 → 四角就是矩形）的四边偏角。
    ///
    /// 偏角在**文档画布像素**里量；画布 → 屏幕是 `LoupeMapping.documentView` 的一次相似变换
    /// （等比缩放 + 平移 + 翻转），相似变换不改角度，所以这就是屏幕上的角度。为了不靠这句话，
    /// 屏幕上的角度也一并量了一遍（`measureOnScreen`），两组数字一起打印。
    func testOneTheFrameIsARectangleAtEveryKeystoneAndAngle() {
        var beforeWorst = 0.0, afterWorst = 0.0
        var rows: [String] = []
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let crop = centred(span: 0.6)
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let canvasGeometry = geometry(vertical: vertical, horizontal: horizontal,
                                              degrees: degrees, crop: crop, cropSpace: .canvas)
                // 修后：画布上的矩形 —— 四角 = 归一化 × 画布尺寸。
                let after = canvasGeometry.documentQuad(of: crop)
                    .map { CGPoint(x: $0.x, y: $0.y) }
                // 修前：330 之前的框 —— 它是**照片**上的矩形，`P` 把它扭成梯形。
                //
                // 量在**拉直之后的那一帧**里（照片转、框不转，301/330 前后都是这样画的），所以只有
                // `P` 参与：这就是「透视把框也透视了」的裸效应，与直角度数无关。`8ad8e32` 上跑
                // `CropTool.layout` 记下的 12 行（`330ANGLE`）与本式逐位相同，见 ①b。
                let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
                let before = [(crop.left, crop.top), (crop.right, crop.top),
                              (crop.right, crop.bottom), (crop.left, crop.bottom)].map { corner -> CGPoint in
                    let p = map.forward(x: corner.0, y: corner.1)
                    return CGPoint(x: p.x * Double(Self.source.width),
                                   y: p.y * Double(Self.source.height))
                }
                let beforeAngle = worstEdgeAngle(before)
                let afterAngle = worstEdgeAngle(after)
                beforeWorst = max(beforeWorst, beforeAngle.worst)
                afterWorst = max(afterWorst, afterAngle.worst)
                rows.append(String(format: "%@ @%.0f° · 修前 %.4f° (%.2f/%.2f/%.2f/%.2f) · 修后 %.4f°",
                                   label(vertical, horizontal), degrees, beforeAngle.worst,
                                   beforeAngle.angles[0], beforeAngle.angles[1],
                                   beforeAngle.angles[2], beforeAngle.angles[3], afterAngle.worst))
                XCTAssertLessThanOrEqual(afterAngle.worst, 0.05,
                    "\(label(vertical, horizontal)) @\(Int(degrees))°: 框不是矩形了 —— 最大偏角 \(afterAngle.worst)°")
                // …and the picture inside it is genuinely warped: the frame's four *source* images are
                // not a rectangle, or the "before" number would be a lie about the bug.
                if vertical != 0 || horizontal != 0 {
                    if degrees > 0 || vertical == 30 {
                        XCTAssertGreaterThan(beforeAngle.worst, 0.5,
                            "\(label(vertical, horizontal)) @\(Int(degrees))°: 修前的框居然是正的 —— 这条验收没有判别力")
                    }
                }
            }
        }
        for row in rows { note("330 ① · " + row) }
        note(String(format: "330 ① · 12 组 · 修前最差 %.3f° · 修后最差 %.4f°", beforeWorst, afterWorst))
        XCTAssertLessThanOrEqual(afterWorst, 0.05)
        XCTAssertGreaterThan(beforeWorst, 1.0, "修前的偏角太小 —— 这条验收分不出两版")
    }

    /// 同一个框在**真实屏幕映射**上的偏角：`CropTool.layout` 的四角，走的是画布 → 视图的相机
    /// （`LoupeMapping.documentView`，相似变换）。这是 ① 里「屏幕」两个字的直接证据。
    func testOneBTheAnglesAreTheSameOnScreen() {
        var worstCanvas = 0.0, worstSource = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let framing = LoupeFraming(viewport: ImageSize(width: 1400, height: 1000),
                                           sourceWidth: Double(Self.source.width),
                                           sourceHeight: Double(Self.source.height),
                                           crop: .full, straightenDegrees: degrees,
                                           perspective: PerspectiveMap(vertical: vertical,
                                                                       horizontal: horizontal),
                                           canvasRole: .document)
                let mapping = framing.mapping(of: .fit)
                let crop = centred(span: 0.6)
                let canvasLayout = CropTool.layout(crop: crop, source: Self.source, mapping: mapping,
                                                   showsGrid: false, cropSpace: .canvas)
                let sourceLayout = CropTool.layout(crop: crop, source: Self.source, mapping: mapping,
                                                   showsGrid: false, cropSpace: .source)
                let canvasAngle = worstEdgeAngle(canvasLayout.corners).worst
                let sourceAngle = worstEdgeAngle(sourceLayout.corners).worst
                worstCanvas = max(worstCanvas, canvasAngle)
                worstSource = max(worstSource, sourceAngle)
                note(String(format: "330 ①b · %@ @%.0f° · 屏幕框角 修前 %.3f° · 修后 %.4f°",
                             label(vertical, horizontal), degrees, sourceAngle, canvasAngle))
                XCTAssertLessThanOrEqual(canvasAngle, 0.05,
                    "\(label(vertical, horizontal)) @\(Int(degrees))°: 屏幕上不是矩形")
            }
        }
        note(String(format: "330 ①b · 屏幕 · 修前最差 %.3f° · 修后最差 %.4f°", worstSource, worstCanvas))
        XCTAssertLessThanOrEqual(worstCanvas, 0.05)
        XCTAssertGreaterThan(worstSource, 0.5)
    }

    // MARK: - ② 框内画面正确：标记在框内 ≤ 1 px，框外 20 px 处不出现

    /// `+30, 9°`：一个标记在框内左上，另一个在**框外 20 px**（文档画布像素），同一次导出。
    /// 框内的标记必须落在它在框内的位置（≤ 1 px），框外的那个必须**一个像素都没有**。
    func testTwoThePictureInsideTheFrameIsCorrect() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let source = Self.renderSource
        let vertical = 30.0, horizontal = 0.0, degrees = 9.0
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        // 画布上的框：200×140 px，居中偏左上一点。
        let boxPx = (width: 200.0, height: 140.0)
        let cropOrigin = (x: 0.25 * photo.width, y: 0.22 * photo.height)
        let crop = CropRect(left: cropOrigin.x / photo.width, top: cropOrigin.y / photo.height,
                            right: (cropOrigin.x + boxPx.width) / photo.width,
                            bottom: (cropOrigin.y + boxPx.height) / photo.height)
        // 框内标记：框内 (40, 30) 处。框外标记：框下方 20 px 处。
        let insideDoc = (x: cropOrigin.x + 40, y: cropOrigin.y + 30)
        let outsideDoc = (x: cropOrigin.x + 100, y: cropOrigin.y + boxPx.height + 20)
        let insidePhoto = photoNormalized(document: CGPoint(x: insideDoc.x, y: insideDoc.y),
                                          vertical: vertical, horizontal: horizontal,
                                          degrees: degrees, source: source)
        let outsidePhoto = photoNormalized(document: CGPoint(x: outsideDoc.x, y: outsideDoc.y),
                                           vertical: vertical, horizontal: horizontal,
                                           degrees: degrees, source: source)

        // 两张图各自只有一个标记，渲染两次 —— 一个标记的亮度不会污染另一个的计数。
        func render(markerAt point: (Double, Double)) throws -> (DisplayImage, CropRect) {
            let image = markerImage(source, centre: point, blockSize: 26)
            let graph = try RenderGraph(input: RenderInput(image: image, identity: "330-marker"))
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = degrees
            edit.geometry.perspectiveVertical = vertical
            edit.geometry.perspectiveHorizontal = horizontal
            edit.geometry.crop = crop.normalizedRect
            edit.geometry.cropSpace = .canvas
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                      wantsPixels: true))
            return (try XCTUnwrap(result.display), crop)
        }

        let (inside, _) = try render(markerAt: insidePhoto)
        let (outside, _) = try render(markerAt: outsidePhoto)

        let insideCentroid = brightCentroid(inside)
        let expected = CGPoint(x: insideDoc.x - cropOrigin.x, y: insideDoc.y - cropOrigin.y)
        let error = hypot(insideCentroid.x - Double(expected.x), insideCentroid.y - Double(expected.y))
        let outsideCount = brightCount(outside)

        note(String(format: "330 ② · 导出 %d×%d · 框内标记 (%.1f,%.1f) 预测 (%.1f,%.1f) 偏差 %.2f px"
                     + " · 框外 20 px 标记可见像素 %d",
                     inside.width, inside.height, insideCentroid.x, insideCentroid.y,
                     Double(expected.x), Double(expected.y), error, outsideCount))
        XCTAssertLessThanOrEqual(error, 1.0, "框内标记不在它该在的位置")
        XCTAssertEqual(outsideCount, 0, "框外 20 px 的标记出现在导出里 —— 框没在裁切")
        // 判别力：标记确实在画面里（不是整幅全黑让上面两断言都平凡成立）。
        XCTAssertGreaterThan(brightCount(inside), 100, "框内标记没渲染出来 —— 这条验收对丢失型缺陷无判别力")
    }

    // MARK: - ③ 迁移：同像素，文件只多空间标记

    /// 旧文档（源空间 crop + 透视）读入 → 换算成等价的画布矩形：可见结果同像素（≤1 灰度阶、
    /// SSIM ≥ 0.9999），并且写回的 JSON 只多一个键。
    func testThreeMigrationKeepsThePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let source = Self.renderSource
        let vertical = 30.0, horizontal = -15.0, degrees = 9.0
        let legacyCrop = CropRect(left: 0.12, top: 0.15, right: 0.88, bottom: 0.8)

        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "330-migration"))
        func document(_ crop: CropRect, _ space: CropSpace) -> EditModel {
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = degrees
            edit.geometry.perspectiveVertical = vertical
            edit.geometry.perspectiveHorizontal = horizontal
            edit.geometry.crop = crop.normalizedRect
            edit.geometry.cropSpace = space
            return edit
        }
        let before = document(legacyCrop, .source)
        let beforeImage = try XCTUnwrap(try graph.render(before, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true)).display)

        var migrated = before
        XCTAssertTrue(migrated.migrateCropToCanvasSpace(sourceSize: source))
        let afterImage = try XCTUnwrap(try graph.render(migrated, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true)).display)

        // 逐像素：两张图的尺寸可以差一个 `ceil`，比公共区域。
        let w = min(beforeImage.width, afterImage.width), h = min(beforeImage.height, afterImage.height)
        var worst = 0.0, sum = 0.0, count = 0
        var sums = (x: 0.0, y: 0.0, xx: 0.0, yy: 0.0, xy: 0.0)
        for y in 0..<h {
            for x in 0..<w {
                let a = Double(gray(beforeImage, x, y)), b = Double(gray(afterImage, x, y))
                worst = max(worst, abs(a - b))
                sum += pow(a - b, 2)
                sums.x += a; sums.y += b; sums.xx += a * a; sums.yy += b * b; sums.xy += a * b
                count += 1
            }
        }
        let n = Double(max(count, 1))
        let meanA = sums.x / n, meanB = sums.y / n
        let varA = sums.xx / n - meanA * meanA, varB = sums.yy / n - meanB * meanB
        let cov = sums.xy / n - meanA * meanB
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        let ssim = ((2 * meanA * meanB + c1) * (2 * cov + c2))
            / ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2))
        let rms = (sum / n).squareRoot()

        // 文件：写回的 JSON 树里，除了 `cropSpace` 与四边（它们就是「这条矩形现在量在画布上」），
        // 再没有别的键变化。
        let beforeJSON = try jsonTree(before), afterJSON = try jsonTree(migrated)
        let diff = differingLeafPaths(beforeJSON, afterJSON)

        note(String(format: "330 ③ · 迁前 %d×%d · 迁后 %d×%d · 最大 |Δ| %.0f 灰阶 · RMS %.4f"
                     + " · SSIM %.6f · 差异叶子 %@",
                     beforeImage.width, beforeImage.height, afterImage.width, afterImage.height,
                     worst, rms, ssim, diff.joined(separator: ",")))
        XCTAssertLessThanOrEqual(worst, 1.0, "迁移前后的可见结果不是同像素")
        XCTAssertGreaterThanOrEqual(ssim, 0.9999)
        // 文件里变的只有两件事：四边被换写成等价的画布矩形，以及空间标记。
        let allowed = Set(["geometry.cropSpace", "geometry.crop.x", "geometry.crop.y",
                           "geometry.crop.width", "geometry.crop.height"])
        XCTAssertTrue(Set(diff).isSubset(of: allowed),
                      "写回的文件变了别的键: \(Set(diff).subtracting(allowed))")
        XCTAssertTrue(diff.contains("geometry.cropSpace"), "空间标记没写进文件")
        XCTAssertEqual(migrated.geometry.cropSpace, .canvas)
    }

    // MARK: - ④ 无透视时逐字节不变（8 组，与 8ad8e32 的金值比）

    /// 8 组（满幅/内缩 × 0°/9°/45°），渲染 SHA 与 330 之前**逐字节相同**。
    ///
    /// 金值是在 `8ad8e32` 的独立 worktree 上跑同一段渲染记录下来的（`330PIN …` 八行），所以这是一条
    /// 与「改前」的比较，不是自己跟自己比。
    func testFourKeystoneZeroIsByteIdenticalToTheBaseline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: ramp(Self.renderSource),
                                                      identity: "330-pin"))
        var mismatches: [String] = []
        var lines: [String] = []
        for group in Self.fourGroups {
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = group.angle
            edit.geometry.crop = group.crop.normalizedRect
            let display = try XCTUnwrap(try graph.render(edit, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true)).display)
            let digest = Self.digest(display)
            let expected = Self.baselinePins[group.label]
            lines.append("\(group.label) \(display.width)x\(display.height) \(digest)")
            if digest != expected { mismatches.append("\(group.label): \(digest) ≠ \(expected ?? "nil")") }
            // …and the document's own bytes: a keystone-free crop must not be migrated at all.
            var mutable = edit
            XCTAssertFalse(mutable.migrateCropToCanvasSpace(sourceSize: Self.renderSource),
                           "\(group.label): 没有透视的文档不该被迁移")
            XCTAssertEqual(mutable.geometry.crop, edit.geometry.crop)
        }
        for line in lines { note("330 ④ · " + line) }
        XCTAssertTrue(mismatches.isEmpty, "无透视的渲染不再逐字节相同: \(mismatches)")
        // 判别力：金值表必须真的有 8 条，且键都对得上。
        XCTAssertEqual(Self.baselinePins.count, 8)
        XCTAssertEqual(Set(Self.baselinePins.keys), Set(Self.fourGroups.map(\.label)))
    }

    // MARK: - ⑤ 导出没有黑像素

    /// `+30, 9°`，满幅 → 一次性内切 → 导出黑像素 0.000 %。
    func testFiveTheInscribedExportCarriesNoBlackPixel() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let source = Self.renderSource
        let graph = try RenderGraph(input: RenderInput(image: ramp(source), identity: "330-export"))
        let vertical = 30.0, degrees = 9.0
        let full = geometry(vertical: vertical, horizontal: 0, degrees: degrees,
                            crop: .full, cropSpace: .canvas, source: source)
        let inscribed = full.inscribedInPhotoQuad(.full)
        note(String(format: "330 ⑤ · 满幅画布 → 内切 %.6f×%.6f (面积 %.6f)",
                     inscribed.width, inscribed.height, inscribed.width * inscribed.height))
        XCTAssertLessThan(inscribed.width, 1, "满幅画布在透视下放不下 —— 必须内切")

        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = degrees
        edit.geometry.perspectiveVertical = vertical
        edit.geometry.crop = inscribed.normalizedRect
        edit.geometry.cropSpace = .canvas
        let display = try XCTUnwrap(try graph.render(edit, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true)).display)
        var black = 0
        for y in 0..<display.height {
            for x in 0..<display.width where gray(display, x, y) <= 1e-3 { black += 1 }
        }
        let fraction = Double(black) / Double(display.width * display.height)
        note(String(format: "330 ⑤ · 导出 %d×%d · 黑像素 %d = %.3f %%",
                     display.width, display.height, black, fraction * 100))
        XCTAssertEqual(fraction, 0, accuracy: 1e-9)
    }

    // MARK: - ⑥ 夹取：20 tick 只平移

    /// 20 tick 连推：`Δw/Δh ≤ 1e−12`；「不出画布」时四角在画布内（`[0,1]²`）；
    /// 「不出像素」时四角在照片四边形内（`≥ −1e−9`）。
    func testSixTheClampOnlyTranslates() {
        var worstDw = 0.0, worstDh = 0.0, worstOutsideCanvas = 0.0
        var worstOutsideQuad = Double.infinity
        var worstQuadCase = ""
        var ticks = 0
        var refusedTicks = 0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees,
                                    crop: centred(span: 0.6), cropSpace: .canvas)
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                // 324 的 `photoQuad()`：有透视时是**扭曲后的四边形**，没有透视时是拉直后照片的
                // **AABB**（307 的合法区就是画布本身，不是那个菱形）—— 两条都在这里照字面写一遍。
                let quad: [CGPoint] = (vertical == 0 && horizontal == 0)
                    ? [CGPoint(x: 0, y: 0),
                       CGPoint(x: photo.width, y: 0),
                       CGPoint(x: photo.width, y: photo.height),
                       CGPoint(x: 0, y: photo.height)]
                    : photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
                var shrink = 0
                let snapshot = centred(span: 0.6)
                var rect = snapshot
                for tick in 1...20 {
                    let step = 0.04 * Double(tick)
                    let candidate = CropRect(left: snapshot.left - step, top: snapshot.top - step,
                                             right: snapshot.right - step,
                                             bottom: snapshot.bottom - step)
                    rect = CropTool.clampToCanvas(candidate, mapping: Self.mapping(degrees: degrees),
                                                  source: Self.source, degrees: degrees,
                                                  perspective: PerspectiveMap(vertical: vertical,
                                                                              horizontal: horizontal),
                                                  cropSpace: .canvas, shrinkTicks: &shrink)
                    worstDw = max(worstDw, abs(rect.width - snapshot.width))
                    worstDh = max(worstDh, abs(rect.height - snapshot.height))
                    worstOutsideCanvas = max(worstOutsideCanvas,
                                             max(0, -rect.left, rect.right - 1, -rect.top, rect.bottom - 1))
                    ticks += 1
                }
                XCTAssertEqual(shrink, 0, "拖动期间夹取改了尺寸")

                // 勾选「不出像素」：四角在照片四边形内。起点用**内切后的**框，20 tick 连续推 —
                // 每 tick 0.01（一次拖动的行程），两个对角方向各推一次。
                for direction in [(-1.0, -1.0), (1.0, 1.0)] {
                    let insideStart = mine.inscribedInPhotoQuad(.full)
                    var inside = insideStart
                    for tick in 1...20 {
                        // 一 tick = 一次拖动步进：从**当前**框走一小步（不是从起点跳），
                        // 这正是 `placedInsidePixels` 在每次刷新里做的事。
                        let step = 0.01
                        let candidate = CropRect(left: inside.left + direction.0 * step,
                                                 top: inside.top + direction.1 * step,
                                                 right: inside.right + direction.0 * step,
                                                 bottom: inside.bottom + direction.1 * step)
                        let placed = mine.translatedInsidePhotoQuad(candidate, tolerance: 1e-9)
                        if placed == nil { refusedTicks += 1 }
                        inside = placed ?? inside
                        let corners = mine.documentQuad(of: inside).map { CGPoint(x: $0.x, y: $0.y) }
                        let distance = corners.reduce(Double.infinity) { min($0, inset($1, in: quad)) }
                        if distance < worstOutsideQuad {
                            worstOutsideQuad = distance
                            worstQuadCase = "\(label(vertical, horizontal)) @\(Int(degrees)) tick \(tick) inset \(distance) placed \(placed != nil)"
                        }
                        worstDw = max(worstDw, abs(inside.width - insideStart.width))
                        worstDh = max(worstDh, abs(inside.height - insideStart.height))
                    }
                }
                note(String(format: "330 ⑥ · %@ @%.0f° · Δw %.1e Δh %.1e · 画布外 %.2e · 四边形内 %.2e",
                             label(vertical, horizontal), degrees,
                             abs(rect.width - snapshot.width), abs(rect.height - snapshot.height),
                             max(0, -rect.left, rect.right - 1, -rect.top, rect.bottom - 1),
                             worstOutsideQuad))
            }
        }
        note(String(format: "330 ⑥ · %d tick · 最大 Δw %.1e Δh %.1e · 画布外 %.2e · 四边形内 %.2e",
                     ticks, worstDw, worstDh, worstOutsideCanvas, worstOutsideQuad))
        XCTAssertLessThanOrEqual(worstDw, 1e-12)
        XCTAssertLessThanOrEqual(worstDh, 1e-12)
        XCTAssertLessThanOrEqual(worstOutsideCanvas, 1e-12)
        XCTAssertGreaterThanOrEqual(worstOutsideQuad, -1e-9,
            "worst case: \(worstQuadCase)")
    }

    // MARK: - ⑧ 反向门

    /// **门 ① — 裁切改回源空间，框又不是矩形了。**
    ///
    /// 打开 `CropGeometry.pre330SourceSpace`（把 `documentQuad` 换回 `P → R` 的四边形走法，等于把
    /// 裁切改回源空间），同一条 ① 的测量必须**远超** 0.05°；关掉必须回到 0.05° 以内。红 → 绿在
    /// 一次运行里都出现，所以这不是「我说它会红」。
    func testGateOneSourceSpaceBendsTheFrame() {
        let crop = centred(span: 0.6)
        var worst = 0.0
        var worstCase = ""
        CropGeometry.pre330SourceSpace = true
        defer { CropGeometry.pre330SourceSpace = false }
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees,
                                    crop: crop, cropSpace: .canvas)
                let angle = worstEdgeAngle(mine.documentQuad(of: crop)
                    .map { CGPoint(x: $0.x, y: $0.y) }).worst
                if angle > worst { worst = angle; worstCase = "\(label(vertical, horizontal)) @\(Int(degrees))°" }
            }
        }
        CropGeometry.pre330SourceSpace = false
        // …and with the gate closed, the same measurement is the ① verdict.
        var after = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees,
                                    crop: crop, cropSpace: .canvas)
                after = max(after, worstEdgeAngle(mine.documentQuad(of: crop)
                    .map { CGPoint(x: $0.x, y: $0.y) }).worst)
            }
        }
        note(String(format: "330 门① · 裁切改回源空间 → ① 红：最大偏角 %.3f° (%@) ≫ 0.05°"
                     + " · 关回去 → %.4f°", worst, worstCase, after))
        XCTAssertGreaterThan(worst, 0.05, "源空间下框居然还是正的 —— ① 没有判别力")
        XCTAssertLessThanOrEqual(after, 0.05)
    }

    /// **门 ② — 采样另写一份映射，框内画面就错了。**
    ///
    /// 打开 `CropGeometry.pre330SourceSpace` 的第二半：导出的采样回到 246 的旧映射（透视作用在
    /// **裁切矩形自己的四边形**上，而不是画布上）。同一个标记在导出图上必须偏 > 1 px；关回去必须
    /// 回到 ≤ 1 px。② 的两条断言因此都是可红可绿的。
    func testGateTwoASecondMapMovesTheMarker() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let source = Self.renderSource
        let vertical = 30.0, horizontal = 0.0, degrees = 9.0
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        let cropOrigin = (x: 0.25 * photo.width, y: 0.22 * photo.height)
        let crop = CropRect(left: cropOrigin.x / photo.width, top: cropOrigin.y / photo.height,
                            right: (cropOrigin.x + 200) / photo.width,
                            bottom: (cropOrigin.y + 140) / photo.height)
        let insideDoc = (x: cropOrigin.x + 40, y: cropOrigin.y + 30)
        let insidePhoto = photoNormalized(document: CGPoint(x: insideDoc.x, y: insideDoc.y),
                                          vertical: vertical, horizontal: horizontal,
                                          degrees: degrees, source: source)
        let expected = CGPoint(x: insideDoc.x - cropOrigin.x, y: insideDoc.y - cropOrigin.y)

        let graph = try RenderGraph(input: RenderInput(
            image: markerImage(source, centre: insidePhoto, blockSize: 26), identity: "330-gate2"))
        func measure() throws -> Double {
            var edit = EditModel.neutral
            edit.geometry.rotationDegrees = degrees
            edit.geometry.perspectiveVertical = vertical
            edit.geometry.crop = crop.normalizedRect
            edit.geometry.cropSpace = .canvas
            let display = try XCTUnwrap(try graph.render(edit, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true)).display)
            let centroid = brightCentroid(display)
            return hypot(centroid.x - Double(expected.x), centroid.y - Double(expected.y))
        }
        let correct = try measure()
        CropGeometry.pre330SourceSpace = true
        let naive = try measure()
        CropGeometry.pre330SourceSpace = false
        note(String(format: "330 门② · 导出映射：标记偏 %.2f px · 换成 246 的旧映射（裁切自己的四边形）："
                     + "偏 %.2f px —— ② 红", correct, naive))
        XCTAssertLessThanOrEqual(correct, 1.0, "② 本身没绿 —— 门无从谈起")
        XCTAssertGreaterThan(naive, 1.0, "另写一份映射后标记没动 —— ② 没有判别力")
    }

    // MARK: - fixtures

    private struct Group {
        let label: String
        let crop: CropRect
        let angle: Double
    }

    /// 验收 ④ 的 8 组：满幅 / 两种内缩 × 0°/9°/45°。
    private static let fourGroups: [Group] = [
        Group(label: "full·0°", crop: .full, angle: 0),
        Group(label: "full·9°", crop: .full, angle: 9),
        Group(label: "full·45°", crop: .full, angle: 45),
        Group(label: "0.10-0.90·0°", crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), angle: 0),
        Group(label: "0.10-0.90·9°", crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), angle: 9),
        Group(label: "0.10-0.90·45°", crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9), angle: 45),
        Group(label: "0.25-0.75·9°", crop: CropRect(left: 0.2, top: 0.25, right: 0.8, bottom: 0.75), angle: 9),
        Group(label: "0.25-0.75·45°", crop: CropRect(left: 0.2, top: 0.25, right: 0.8, bottom: 0.75), angle: 45),
    ]

    /// `8ad8e32` 上跑同一段渲染记录下来的 8 个摘要（`330PIN` 八行，独立 worktree `/tmp/330-base`
    /// 的 `CropInCanvas330Probe` 打印）。改一个像素就会变。
    private static let baselinePins: [String: String] = [
        "full·0°": "41abb775ccc7cce6·1228800",
        "full·9°": "9f11c55c8e2a563f·1228800",
        "full·45°": "22ee6f9b0800a8b2·1228800",
        "0.10-0.90·0°": "10c4b705a204eff2·786432",
        "0.10-0.90·9°": "264b276b20b05f46·786432",
        "0.10-0.90·45°": "9032f61524ea0193·786432",
        "0.25-0.75·9°": "276b3bedf6c957c0·368640",
        "0.25-0.75·45°": "39b96b0b85599885·368640",
    ]

    private static func mapping(degrees: Double) -> LoupeMapping {
        LoupeFraming(viewport: ImageSize(width: 1400, height: 1000),
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: degrees,
                     canvasRole: .document).mapping(of: .fit)
    }

    private func ramp(_ size: ImageSize) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = 0.6 * Double(x) / Double(max(size.width - 1, 1))
                    + 0.4 * Double(y) / Double(max(size.height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * size.width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "330-pin")
    }

    /// 黑底上一个亮块 —— 位置测的是它在**照片归一化**坐标里的中心。
    private func markerImage(_ size: ImageSize, centre: (Double, Double),
                             blockSize: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        let cx = Int(centre.0 * Double(size.width))
        let cy = Int(centre.1 * Double(size.height))
        let half = blockSize / 2
        for y in 0..<size.height {
            for x in 0..<size.width {
                let o = (y * size.width + x) * 4
                let inside = abs(x - cx) <= half && abs(y - cy) <= half
                let v = Float16(inside ? 0.85 : 0.01)
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "330-marker")
    }

    private func gray(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return (Double(image.rgba[o]) + Double(image.rgba[o + 1]) + Double(image.rgba[o + 2])) / 3
    }

    private func brightCentroid(_ image: DisplayImage) -> CGPoint {
        var sx = 0.0, sy = 0.0, count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where gray(image, x, y) > 0.3 {
                sx += Double(x) + 0.5; sy += Double(y) + 0.5; count += 1
            }
        }
        guard count > 0 else { return CGPoint(x: -1, y: -1) }
        return CGPoint(x: sx / Double(count), y: sy / Double(count))
    }

    private func brightCount(_ image: DisplayImage) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where gray(image, x, y) > 0.3 { count += 1 }
        }
        return count
    }

    private static func digest(_ image: DisplayImage) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let raw: [UInt8] = image.rgba.withUnsafeBytes { Array($0) }
        for b in raw { hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        hash = (hash ^ UInt64(image.width)) &* 0x0000_0100_0000_01b3
        hash = (hash ^ UInt64(image.height)) &* 0x0000_0100_0000_01b3
        return String(format: "%016llx·%d", hash, raw.count)
    }

    private func jsonTree(_ edit: EditModel) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(edit)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func differingLeafPaths(_ a: [String: Any], _ b: [String: Any],
                                   prefix: String = "") -> [String] {
        var paths: [String] = []
        for key in Set(a.keys).union(b.keys) {
            let path = prefix.isEmpty ? key : prefix + "." + key
            switch (a[key], b[key]) {
            case let (lhs as [String: Any], rhs as [String: Any]):
                paths += differingLeafPaths(lhs, rhs, prefix: path)
            case let (lhs as [Any], rhs as [Any]):
                if "\(lhs)".count != "\(rhs)".count || !"\(lhs)".elementsEqual("\(rhs)") {
                    paths.append(path)
                }
            default:
                if "\(a[key] ?? "nil")" != "\(b[key] ?? "nil")" { paths.append(path) }
            }
        }
        return paths.sorted()
    }

    /// **取数**：把上面每一条打印过的数字写进 `PHOTONS_330_REPORT`。没有这个变量时什么也不做，
    /// 所以它在 CI 里是一条无名用例（0 副作用）。
    func testZReportWritesWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_330_REPORT"],
              !path.isEmpty else { return }
        try (Self.report.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}
