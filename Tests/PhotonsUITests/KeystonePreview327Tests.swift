import XCTest
import Metal
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **327 — 透视：预览不准（A）+ 应用裁切后透视丢失（B）**
///
/// 324 只改了几何（画布/夹取/导出），它自己写明的未完成项第 1 条就是「keystone 下 overlay 的框仍走
/// `CropTool.layout` / `LoupeMapping` 的**旋转投影**」。这份文件把两件事分开量：
///
///   · **A** — overlay 画的四条边 vs `P → R` 的真角点（文档画布像素），六组参数；并与**导出**
///     画面上的同名标记对位；
///   · **B** — 「进裁切 → 在变换卡里调透视（写**文档**）→ 应用」之后，导出里的标记点是否还在
///     `P → R` 的位置上，两条本该收敛的竖线夹角是否还在。
///
/// 每个期望值都由本文件自己的闭式 `P → R` 重算（不读 `CropGeometry`），所以两处独立实现的分歧会
/// 暴露出来而不是互相抵消。
@MainActor
final class KeystonePreview327Tests: XCTestCase {

    private static let keystones: [(vertical: Double, horizontal: Double)] = [(30, 0), (30, -15)]
    private static let angles: [Double] = [0, 9, 45]
    private static let source = ImageSize(width: 1200, height: 800)

    // MARK: - this file's own P → R (photo pixels)

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

    private func photoAABB(vertical: Double, horizontal: Double, degrees: Double,
                           source: ImageSize) -> CGRect {
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            warpAndTurn($0, vertical: vertical, horizontal: horizontal,
                        degrees: degrees, source: source)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A normalized photo point in the **document canvas**' pixels (origin = the quad's AABB).
    private func documentPoint(_ corner: (Double, Double), vertical: Double, horizontal: Double,
                               degrees: Double, source: ImageSize) -> CGPoint {
        let c = warpAndTurn(corner, vertical: vertical, horizontal: horizontal,
                            degrees: degrees, source: source)
        let aabb = photoAABB(vertical: vertical, horizontal: horizontal,
                             degrees: degrees, source: source)
        return CGPoint(x: c.x - aabb.minX, y: c.y - aabb.minY)
    }

    /// The warped crop's AABB' top-left in photo pixels — the export canvas' origin.
    private func warpedCropOrigin(of crop: CropRect, vertical: Double, horizontal: Double,
                                  degrees: Double, source: ImageSize) -> CGPoint {
        let corners = [(crop.left, crop.top), (crop.right, crop.top),
                       (crop.right, crop.bottom), (crop.left, crop.bottom)]
            .map { warpAndTurn($0, vertical: vertical, horizontal: horizontal,
                               degrees: degrees, source: source) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGPoint(x: xs.min()!, y: ys.min()!)
    }

    /// A normalized photo point in the **export canvas'** pixels for a given crop — the renderer's
    /// own walk: `P → R` in photo pixels, then minus the warped crop's AABB origin.
    private func exportPoint(_ corner: (Double, Double), crop: CropRect, vertical: Double,
                             horizontal: Double, degrees: Double) -> CGPoint {
        let p = warpAndTurn(corner, vertical: vertical, horizontal: horizontal,
                            degrees: degrees, source: Self.source)
        let origin = warpedCropOrigin(of: crop, vertical: vertical, horizontal: horizontal,
                                      degrees: degrees, source: Self.source)
        return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
    }

    // MARK: - the mapping the crop workspace is projected through

    /// The app's own framing for 裁切: the **document** canvas (`canvasEdit` → `crop == .full`),
    /// at the document's angle, with the document's keystone.
    private func mapping(degrees: Double, vertical: Double = 0, horizontal: Double = 0,
                         canvasRole: CanvasRole = .document) -> LoupeMapping {
        LoupeFraming(viewport: ImageSize(width: 1400, height: 1000),
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: degrees,
                     perspective: vertical == 0 && horizontal == 0
                        ? nil : PerspectiveMap(vertical: vertical, horizontal: horizontal),
                     canvasRole: canvasRole).mapping(of: .fit)
    }

    /// A point in the projection's canvas pixels (S3) → view points, through the matrix the picture
    /// itself is laid out with.
    private func viewPoint(_ mapping: LoupeMapping, canvas p: CGPoint) -> CGPoint? {
        guard let transform = mapping.transform else { return nil }
        return Self.apply(transform.s3ToS5, p)
    }

    /// View points → the projection's canvas pixels, the exact inverse. For `canvasRole ==
    /// .document` in a keystoned document S3 **is** the document canvas' pixel grid.
    private func canvasPoint(_ mapping: LoupeMapping, view p: CGPoint) -> CGPoint? {
        guard let transform = mapping.transform else { return nil }
        return Self.apply(transform.s5ToS3, p)
    }

    private static func apply(_ matrix: Matrix3, _ p: CGPoint) -> CGPoint? {
        let v = matrix.values
        let x = v[0] * p.x + v[1] * p.y + v[2]
        let y = v[3] * p.x + v[4] * p.y + v[5]
        let w = v[6] * p.x + v[7] * p.y + v[8]
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: x / w, y: y / w)
    }

    private func label(_ vertical: Double, _ horizontal: Double, _ degrees: Double) -> String {
        String(format: "keystone(%+.0f,%+.0f) @%.0f°", vertical, horizontal, degrees)
    }

    // MARK: - ① 预览 == 照片四边形

    /// overlay 的四角 vs `P → R` 的真角点，六组参数，误差以**文档画布像素**计。
    func testOneTheOverlayFrameIsThePerspectiveQuad() {
        var worst = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let mapping = mapping(degrees: degrees, vertical: vertical, horizontal: horizontal)
                let layout = CropTool.layout(crop: .full, source: Self.source, mapping: mapping,
                                             showsGrid: true, quadRotationDegrees: degrees)
                XCTAssertEqual(layout.corners.count, 4)
                let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
                for (index, corner) in corners.enumerated() {
                    let expected = documentPoint(corner, vertical: vertical, horizontal: horizontal,
                                                 degrees: degrees, source: Self.source)
                    guard let measured = canvasPoint(mapping, view: layout.corners[index]) else {
                        return XCTFail("the mapping has no transform — nothing to project through")
                    }
                    let error = hypot(Double(measured.x - expected.x),
                                      Double(measured.y - expected.y))
                    worst = max(worst, error)
                    print(String(format: "327 ① · %@ · corner %d overlay (%.2f, %.2f)"
                                 + " · P→R (%.2f, %.2f) · Δ %.2f px",
                                 label(vertical, horizontal, degrees), index,
                                 measured.x, measured.y, expected.x, expected.y, error))
                    XCTAssertLessThanOrEqual(error, 1.0,
                        "\(label(vertical, horizontal, degrees)) corner \(index): the overlay is "
                        + String(format: "%.2f px off the picture's quad", error))
                }
                // …and the rule-of-thirds grid reads off the same quad: every node is inside it.
                let extent = photoAABB(vertical: vertical, horizontal: horizontal,
                                       degrees: degrees, source: Self.source)
                for line in layout.grid {
                    for point in [line.a, line.b] {
                        guard let canvas = canvasPoint(mapping, view: point) else { continue }
                        XCTAssertTrue(canvas.x >= -1 && canvas.x <= extent.width + 1
                                      && canvas.y >= -1 && canvas.y <= extent.height + 1,
                                      "a grid node left the photo quad")
                    }
                }
            }
        }
        print(String(format: "327 ① · worst overlay corner error %.3f px "
                     + "(2 keystones × 3 angles × 4 corners)", worst))
        XCTAssertLessThanOrEqual(worst, 1.0)
    }

    // MARK: - ② 预览 == 导出（同一张图上的同名标记）

    /// The four **rule-of-thirds intersections** are marked in the photograph; the document is
    /// exported with the same rect. The overlay's drawn grid lines and the exported dots must meet at
    /// the same four points (both in the export canvas' own pixels) — a homography maps lines to
    /// lines, so the intersection of the two drawn lines is the image of the marked point.
    func testTwoTheOverlayAgreesWithTheExport() throws {
        let crop = CropRect(left: 0.12, top: 0.14, right: 0.88, bottom: 0.86)
        let thirds = [1.0 / 3.0, 2.0 / 3.0]
        let dots = thirds.flatMap { tj in thirds.map { ti in
            (crop.left + ti * crop.width, crop.top + tj * crop.height)
        } }
        let image = markedImage(Self.source, at: dots, block: 11)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "327-preview-export"))
        var worst = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in [0.0, 9.0] {
                let mapping = mapping(degrees: degrees, vertical: vertical, horizontal: horizontal)
                let layout = CropTool.layout(crop: crop, source: Self.source, mapping: mapping,
                                             showsGrid: true, quadRotationDegrees: degrees)
                XCTAssertEqual(layout.grid.count, 4)
                var edit = document(vertical: vertical, horizontal: horizontal, degrees: degrees)
                edit.geometry.crop = crop.normalizedRect
                let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                           wantsPixels: true))
                let display = try XCTUnwrap(result.display)
                let origin = warpedCropOrigin(of: crop, vertical: vertical, horizontal: horizontal,
                                              degrees: degrees, source: Self.source)
                let found = blobs(display)
                XCTAssertEqual(found.count, 4, "\(label(vertical, horizontal, degrees)): dots lost")
                // The grid is built horizontal-then-vertical per third: 0/2 horizontal, 1/3 vertical.
                let drawn = [(layout.grid[0], layout.grid[1]), (layout.grid[0], layout.grid[3]),
                             (layout.grid[2], layout.grid[3]), (layout.grid[2], layout.grid[1])]
                _ = exportPoint((0, 0), crop: crop, vertical: vertical,
                               horizontal: horizontal, degrees: degrees)
                for (index, pair) in drawn.enumerated() {
                    guard let intersection = Self.intersection(pair.0, pair.1),
                          let overlay = canvasPoint(mapping, view: intersection) else {
                        return XCTFail("the drawn grid has no intersection")
                    }
                    // The overlay speaks document-canvas pixels; the export speaks the warped
                    // crop's AABB. One offset between the two grids.
                    let shift = photoAABB(vertical: vertical, horizontal: horizontal,
                                          degrees: degrees, source: Self.source)
                    let expected = CGPoint(x: overlay.x + shift.minX - origin.x,
                                           y: overlay.y + shift.minY - origin.y)
                    guard let measured = Self.nearest(found, to: expected) else {
                        return XCTFail("no dot for node \(index)")
                    }
                    let error = hypot(Double(measured.x - expected.x),
                                      Double(measured.y - expected.y))
                    worst = max(worst, error)
                    print(String(format: "327 ② · %@ · node %d export dot (%.2f, %.2f)"
                                 + " · overlay grid (%.2f, %.2f) · Δ %.2f px",
                                 label(vertical, horizontal, degrees), index,
                                 measured.x, measured.y, expected.x, expected.y, error))
                    XCTAssertLessThanOrEqual(error, 1.0,
                        "\(label(vertical, horizontal, degrees)) node \(index): the preview and "
                        + "the export disagree by " + String(format: "%.2f px", error))
                }
            }
        }
        print(String(format: "327 ② · worst preview-vs-export error %.3f px", worst))
        XCTAssertLessThanOrEqual(worst, 1.0)
    }

    // MARK: - ③ 应用之后透视还在（B）

    /// The user's own order, in the app's own widgets: 进裁切 → 在**变换卡**里把垂直透视拖到 +30
    /// （写的是**文档**）→ 勾「不出像素」一次性内切 → 应用 → 导出。
    ///
    /// (a) 标记点仍在 `P → R` 上（≤ 1 px）；
    /// (b) 两条本该收敛的竖线，其夹角与 `P → R` 的预测差 ≤ 0.2°；
    /// (c) 判别力：keystone = 0 的对照组夹角 ≈ 0°。
    func testThreeApplyingTheCropKeepsTheKeystone() throws {
        let lines = (left: 0.25, right: 0.75)
        for (vertical, horizontal) in [(30.0, 0.0), (30.0, -15.0), (0.0, 0.0)] {
            let (session, _) = try makeSession()
            let controller = CropToolController(session: session, defaults: try defaults())
            XCTAssertTrue(controller.begin())
            // The 变换 card's slider: a **document** write, exactly as `TransformPanel` does it.
            session.applyEdit { $0.geometry.perspectiveVertical = vertical }
            session.applyEdit { $0.geometry.perspectiveHorizontal = horizontal }
            XCTAssertTrue(controller.setCropStaysInsidePixels(true))
            // The frame on screen, as the overlay drew it — the box the export must be of.
            let drawn = controller.effectiveCrop(source: Self.source)
            let drawnCanvas = CropMath.canvasSize(crop: drawn, in: Self.source,
                                                  straightenDegrees: 0, quarterTurns: 0,
                                                  allowsOutsideSource: true,
                                                  perspective: PerspectiveMap(vertical: vertical,
                                                                              horizontal: horizontal))
            controller.apply()
            if vertical != 0 || horizontal != 0 {
                XCTAssertEqual(session.edit.geometry.perspectiveVertical, vertical, accuracy: 1e-12)
            }
            let committed = session.edit.geometry
            print(String(format: "327 ③ · %@ · committed pv=%.1f ph=%.1f crop "
                         + "(%.4f, %.4f)-(%.4f, %.4f) canvas %d×%d",
                         label(vertical, horizontal, 0), committed.perspectiveVertical,
                         committed.perspectiveHorizontal, committed.cropRect.left,
                         committed.cropRect.top, committed.cropRect.right,
                         committed.cropRect.bottom,
                         committed.outputPixels(in: Self.source).width,
                         committed.outputPixels(in: Self.source).height))
            XCTAssertEqual(committed.perspectiveVertical, vertical, accuracy: 1e-12,
                           "应用把透视丢了：文档的垂直透视不是滑杆上的那个数")
            XCTAssertEqual(committed.perspectiveHorizontal, horizontal, accuracy: 1e-12)

            // ②-a 空间：提交的矩形就是 overlay 画的那个（直立源空间，不是文档画布空间），
            // 所以导出的画布也必须是那一框的 AABB。
            XCTAssertEqual(committed.cropRect.left, drawn.left, accuracy: 1e-12,
                           "提交的裁切不是画面上那一框 —— 存错空间了")
            XCTAssertEqual(committed.cropRect.top, drawn.top, accuracy: 1e-12)
            XCTAssertEqual(committed.cropRect.right, drawn.right, accuracy: 1e-12)
            XCTAssertEqual(committed.cropRect.bottom, drawn.bottom, accuracy: 1e-12)
            let exported = committed.outputPixels(in: Self.source)
            print("327 ③ · export canvas \(exported.width)×\(exported.height)"
                  + " · the drawn frame's AABB \(drawnCanvas.width)×\(drawnCanvas.height)")
            XCTAssertLessThanOrEqual(abs(exported.width - drawnCanvas.width), 1,
                                     "导出的画布不是画面上那一框的 AABB")
            XCTAssertLessThanOrEqual(abs(exported.height - drawnCanvas.height), 1)

            let crop = committed.cropRect
            let origin = warpedCropOrigin(of: crop, vertical: vertical, horizontal: horizontal,
                                          degrees: 0, source: Self.source)

            // (a) four marked points, one render.
            let dots = [(0.30, 0.30), (0.70, 0.30), (0.70, 0.70), (0.30, 0.70)]
            let markerGraph = try RenderGraph(
                input: RenderInput(image: markedImage(Self.source, at: dots, block: 11),
                                   identity: "327-apply-dots"))
            let markerResult = try markerGraph.render(session.edit, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true))
            let markers = try XCTUnwrap(markerResult.display)
            let found = blobs(markers)
            print("327 ③ · blobs \(found.count) · display \(markers.width)×\(markers.height)")
            XCTAssertEqual(found.count, 4, "标记点没有画出来")
            var worstMarker = 0.0
            for (index, dot) in dots.enumerated() {
                let target = exportPoint(dot, crop: crop, vertical: vertical,
                                         horizontal: horizontal, degrees: 0)
                guard let measured = Self.nearest(found, to: target) else {
                    return XCTFail("no marker near \(target)")
                }
                let error = hypot(Double(measured.x - target.x), Double(measured.y - target.y))
                worstMarker = max(worstMarker, error)
                print(String(format: "327 ③ · %@ · marker %d measured (%.2f, %.2f)"
                             + " · M=R·P predicts (%.2f, %.2f) · Δ %.2f px",
                             label(vertical, horizontal, 0), index,
                             measured.x, measured.y, target.x, target.y, error))
                XCTAssertLessThanOrEqual(error, 1.0,
                    "\(label(vertical, horizontal, 0)) marker \(index): the export does not carry "
                    + "the keystone — " + String(format: "%.2f px", error))
            }

            // (b) the two vertical lines' convergence, on their own render.
            let lineGraph = try RenderGraph(
                input: RenderInput(image: linedImage(Self.source, lines: lines),
                                   identity: "327-apply-lines"))
            let lineResult = try lineGraph.render(session.edit, options: RenderOptions(
                scale: 1, useCache: false, wantsPixels: true))
            let linesImage = try XCTUnwrap(lineResult.display)
            guard let measured = lineAngles(linesImage) else {
                return XCTFail("\(label(vertical, horizontal, 0)): the two lines did not render")
            }
            let measuredLeft = measured.left
            let measuredRight = measured.right
            let predictedLeft = predictedAngle(of: lines.left, vertical: vertical,
                                              horizontal: horizontal)
            let predictedRight = predictedAngle(of: lines.right, vertical: vertical,
                                               horizontal: horizontal)
            let measuredGap = measuredLeft - measuredRight
            let predictedGap = predictedLeft - predictedRight
            print(String(format: "327 ③ · %@ · lines %.2f° / %.2f° (Δ %.2f°)"
                         + " · predicted %.2f° / %.2f° (Δ %.2f°) · gap error %.2f°"
                         + " · markers worst %.2f px",
                         label(vertical, horizontal, 0), measuredLeft, measuredRight, measuredGap,
                         predictedLeft, predictedRight, predictedGap,
                         abs(measuredGap - predictedGap), worstMarker))
            XCTAssertEqual(measuredLeft, predictedLeft, accuracy: 0.2)
            XCTAssertEqual(measuredRight, predictedRight, accuracy: 0.2)
            XCTAssertEqual(measuredGap, predictedGap, accuracy: 0.2)
            if vertical == 0 && horizontal == 0 {
                // The control: without a keystone the two lines are parallel, so the test can tell
                // 「透视还在」 from 「什么都没做」.
                XCTAssertEqual(measuredGap, 0, accuracy: 0.05,
                               "无透视对照组的夹角不是 0° —— 这个判据没有判别力")
            } else {
                XCTAssertGreaterThan(abs(measuredGap), 1.0,
                                     "keystone 下两条竖线没有收敛 —— 判据没有判别力")
            }
        }
    }

    // MARK: - 反向门

    /// **Gate ① — the old projection.** The rotated-rectangle walk 324 left in place puts the same
    /// four corners this far from the quad: reverting `CropTool.layout` to it reddens ①.
    func testGateOneTheRotatedProjectionIsMeasurablyWrong() {
        var worst = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in [0.0, 9.0] {
                let mapping = mapping(degrees: degrees, vertical: vertical, horizontal: horizontal)
                for corner in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
                    // The pre-327 walk, verbatim: R(−θ) about the photo centre, then the frame's
                    // axis-aligned screen map — no `P` anywhere.
                    let w = Double(Self.source.width), h = Double(Self.source.height)
                    let rotation = CropGeometry.RotationMatrix(degrees: degrees)
                    let turned = rotation.invert(x: corner.0 * w - w / 2,
                                                 y: corner.1 * h - h / 2)
                    let frame = mapping.frameView(frameX: turned.x + w / 2,
                                                  frameY: turned.y + h / 2)
                    guard let measured = canvasPoint(mapping,
                                                     view: CGPoint(x: frame.x, y: frame.y)) else {
                        return XCTFail("no transform")
                    }
                    let expected = documentPoint(corner, vertical: vertical, horizontal: horizontal,
                                                 degrees: degrees, source: Self.source)
                    let error = hypot(Double(measured.x - expected.x),
                                      Double(measured.y - expected.y))
                    worst = max(worst, error)
                    print(String(format: "327 gate① · %@ · corner (%.1f,%.1f) rotated projection"
                                 + " (%.1f, %.1f) vs quad (%.1f, %.1f) · Δ %.1f px",
                                 label(vertical, horizontal, degrees), corner.0, corner.1,
                                 measured.x, measured.y, expected.x, expected.y, error))
                }
            }
        }
        print(String(format: "327 gate① · the rotated projection is up to %.1f px off the quad", worst))
        XCTAssertGreaterThan(worst, 10.0,
                             "旋转投影和四边形差得太小 —— ① 不会因为回退而变红")
    }

    /// **Gate ② — the wrong space.** 324's `documentCanvasCropRect` is the canvas' AABB walked
    /// **back** into the crop's axes — a *diagnostic*. Writing it into `geometry.crop`, which the
    /// renderer reads as the **upright source space**, cannot round-trip: the canvas *is* the crop's
    /// warped AABB, so the canvas-space rect always describes the whole canvas. The measurement is
    /// end-to-end: a mark the user cropped **away** comes back in the export, and the export canvas
    /// grows to the whole picture's.
    func testGateTwoCommittingTheDocumentCanvasRectLosesTheKeystone() throws {
        let vertical = 30.0, horizontal = -15.0
        // The crop, and a mark **outside** it: the user's frame removes it.
        let correct = CropRect(left: 0.12, top: 0.14, right: 0.88, bottom: 0.86)
        let outside = (0.06, 0.06)
        let image = markedImage(Self.source, at: [outside], block: 15)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "327-gate2"))

        var right = document(vertical: vertical, horizontal: horizontal, degrees: 0)
        right.geometry.crop = correct.normalizedRect
        let wrong = CropGeometry(geometry: right.geometry, source: Self.source)
            .documentCanvasCropRect
        var left = right
        left.geometry.crop = wrong.normalizedRect
        print(String(format: "327 gate② · correct crop (%.4f, %.4f)-(%.4f, %.4f)"
                     + " · documentCanvasCropRect (%.4f, %.4f)-(%.4f, %.4f)",
                     correct.left, correct.top, correct.right, correct.bottom,
                     wrong.left, wrong.top, wrong.right, wrong.bottom))

        let rightCanvas = CropMath.canvasSize(crop: correct, in: Self.source,
                                              straightenDegrees: 0, quarterTurns: 0,
                                              allowsOutsideSource: true,
                                              perspective: PerspectiveMap(vertical: vertical,
                                                                          horizontal: horizontal))
        let leftCanvas = CropMath.canvasSize(crop: wrong, in: Self.source,
                                             straightenDegrees: 0, quarterTurns: 0,
                                             allowsOutsideSource: true,
                                             perspective: PerspectiveMap(vertical: vertical,
                                                                         horizontal: horizontal))
        let rightResult = try graph.render(right, options: RenderOptions(scale: 1, useCache: false,
                                                                        wantsPixels: true))
        let leftResult = try graph.render(left, options: RenderOptions(scale: 1, useCache: false,
                                                                      wantsPixels: true))
        let rightImage = try XCTUnwrap(rightResult.display)
        let leftImage = try XCTUnwrap(leftResult.display)
        let rightBlobs = blobs(rightImage, minArea: 40)
        let leftBlobs = blobs(leftImage, minArea: 40)
        print("327 gate② · source-space crop: canvas \(rightCanvas.width)×\(rightCanvas.height)"
              + " · blobs \(rightBlobs.count) \(rightBlobs)")
        print("327 gate② · document-canvas crop: canvas \(leftCanvas.width)×\(leftCanvas.height)"
              + " · blobs \(leftBlobs.count) \(leftBlobs)")
        XCTAssertEqual(rightBlobs.count, 0,
                       "直立源空间的裁切把框外的标记裁掉了 —— 这一侧必须是 0")
        XCTAssertGreaterThanOrEqual(leftBlobs.count, 1,
                                    "写进文档画布空间之后，框外的标记又回来了 —— ② 不是门")
        // …and the canvas is the giveaway: the wrong rect always describes the whole canvas.
        let rightTarget = exportPoint(outside, crop: correct, vertical: vertical,
                                      horizontal: horizontal, degrees: 0)
        XCTAssertTrue(rightTarget.x < 0 || rightTarget.y < 0 || rightTarget.x > Double(rightCanvas.width)
                      || rightTarget.y > Double(rightCanvas.height),
                      "the mark is inside the correct crop — the gate would prove nothing")
        XCTAssertGreaterThan(Double(abs(leftCanvas.width - rightCanvas.width)), 5,
                             "两个空间的画布宽度差不出 5 px —— ② 量不出东西")
    }

    // MARK: - fixtures

    private func document(vertical: Double, horizontal: Double, degrees: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.crop = .full
        edit.geometry.rotationDegrees = degrees
        edit.geometry.aspectLock = .original
        edit.geometry.perspectiveVertical = vertical
        edit.geometry.perspectiveHorizontal = horizontal
        return edit
    }

    /// Black photograph with bright blocks centred on the given normalized points.
    ///
    /// The block is drawn so that **the centroid of its pixel centres is the point itself**: the
    /// renderer's grid has pixel `i` covering `[i, i+1)`, so a normalized `u` is the continuous
    /// coordinate `u · width` and a block symmetric about it has no half-pixel bias. Without that the
    /// measurement carries a constant 0.5 px and an acceptance of 1 px means nothing.
    private func markedImage(_ size: ImageSize, at points: [(Double, Double)],
                             block halfWidth: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for p in points {
            let cx = p.0 * Double(size.width), cy = p.1 * Double(size.height)
            let x0 = max(0, Int((cx - Double(halfWidth)).rounded(.down)))
            let x1 = min(size.width - 1, Int((cx + Double(halfWidth)).rounded(.up)))
            let y0 = max(0, Int((cy - Double(halfWidth)).rounded(.down)))
            let y1 = min(size.height - 1, Int((cy + Double(halfWidth)).rounded(.up)))
            for y in y0...y1 {
                guard abs(Double(y) + 0.5 - cy) <= Double(halfWidth) else { continue }
                for x in x0...x1 {
                    guard abs(Double(x) + 0.5 - cx) <= Double(halfWidth) else { continue }
                    let o = (y * size.width + x) * 4
                    rgba[o] = Float16(0.85); rgba[o + 1] = Float16(0.85)
                    rgba[o + 2] = Float16(0.85)
                }
            }
        }
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "327-markers")
    }

    /// Black photograph with two vertical lines at the given normalized x.
    private func linedImage(_ size: ImageSize,
                            lines: (left: Double, right: Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for x in [Int(lines.left * Double(size.width)), Int(lines.right * Double(size.width))] {
            for row in 0..<size.height {
                for column in max(0, x - 1)...min(size.width - 1, x + 1) {
                    let o = (row * size.width + column) * 4
                    rgba[o] = Float16(0.7); rgba[o + 1] = Float16(0.7); rgba[o + 2] = Float16(0.7)
                }
            }
        }
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "327-lines")
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return Double(image.rgba[o]) + Double(image.rgba[o + 1]) + Double(image.rgba[o + 2])
    }

    /// Every connected bright region's centroid, in pixels (row-major scan, 8-connected).
    private func blobs(_ image: DisplayImage, threshold: Double = 1.0,
                       minArea: Int = 12) -> [CGPoint] {
        var visited = [Bool](repeating: false, count: image.width * image.height)
        var out: [CGPoint] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = y * image.width + x
                guard !visited[o], luma(image, x, y) > threshold else { continue }
                var stack = [(x, y)], sumX = 0.0, sumY = 0.0, count = 0
                visited[o] = true
                while let (cx, cy) = stack.popLast() {
                    sumX += Double(cx) + 0.5; sumY += Double(cy) + 0.5; count += 1
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else { continue }
                            let no = ny * image.width + nx
                            guard !visited[no], luma(image, nx, ny) > threshold else { continue }
                            visited[no] = true
                            stack.append((nx, ny))
                        }
                    }
                }
                if count >= minArea {
                    out.append(CGPoint(x: sumX / Double(count), y: sumY / Double(count)))
                }
            }
        }
        return out
    }

    private static func nearest(_ points: [CGPoint], to target: CGPoint) -> CGPoint? {
        points.min { a, b in
            hypot(Double(a.x - target.x), Double(a.y - target.y))
                < hypot(Double(b.x - target.x), Double(b.y - target.y))
        }
    }

    private static func intersection(_ a: CropToolSegment, _ b: CropToolSegment) -> CGPoint? {
        let x1 = Double(a.a.x), y1 = Double(a.a.y), x2 = Double(a.b.x), y2 = Double(a.b.y)
        let x3 = Double(b.a.x), y3 = Double(b.a.y), x4 = Double(b.b.x), y4 = Double(b.b.y)
        let denominator = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denominator
        return CGPoint(x: x1 + t * (x2 - x1), y: y1 + t * (y2 - y1))
    }

    /// The two bright vertical lines' angles (degrees, from vertical), fitted from their row
    /// centroids over the middle 70 % of the picture. The lines are found wherever they are — the
    /// fit never assumes where a keystone should have put them, so a lost keystone shows up in the
    /// number instead of hiding the line from the search window.
    private func lineAngles(_ image: DisplayImage) -> (left: Double, right: Double)? {
        var left: [(y: Double, x: Double)] = [], right: [(y: Double, x: Double)] = []
        for y in Int(Double(image.height) * 0.15)..<Int(Double(image.height) * 0.85) {
            var runs: [(sum: Double, count: Int)] = []
            var sum = 0.0, count = 0
            for x in 0..<image.width {
                if luma(image, x, y) > 0.6 {
                    sum += Double(x) + 0.5
                    count += 1
                } else if count > 0 {
                    runs.append((sum, count)); sum = 0; count = 0
                }
            }
            if count > 0 { runs.append((sum, count)) }
            guard runs.count == 2 else { continue }
            left.append((Double(y), runs[0].sum / Double(runs[0].count)))
            right.append((Double(y), runs[1].sum / Double(runs[1].count)))
        }
        guard let l = Self.slope(left), let r = Self.slope(right) else { return nil }
        return (atan(l) * 180 / .pi, atan(r) * 180 / .pi)
    }

    /// Least-squares `dx/dy` of a set of (y, x) row centroids.
    private static func slope(_ rows: [(y: Double, x: Double)]) -> Double? {
        guard rows.count > 20 else { return nil }
        let meanY = rows.reduce(0) { $0 + $1.y } / Double(rows.count)
        let meanX = rows.reduce(0) { $0 + $1.x } / Double(rows.count)
        var num = 0.0, den = 0.0
        for row in rows {
            num += (row.y - meanY) * (row.x - meanX)
            den += (row.y - meanY) * (row.y - meanY)
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// The same line's angle predicted by the closed form (`P → R` of two of its points).
    private func predictedAngle(of u: Double, vertical: Double, horizontal: Double) -> Double {
        let low = warpAndTurn((u, 0.02), vertical: vertical, horizontal: horizontal,
                              degrees: 0, source: Self.source)
        let high = warpAndTurn((u, 0.98), vertical: vertical, horizontal: horizontal,
                               degrees: 0, source: Self.source)
        let dy = Double(high.y - low.y), dx = Double(high.x - low.x)
        return atan(dx / dy) * 180 / .pi
    }

    // MARK: the shipped controller's session

    private func makeSession() throws -> (CatalogSession, Asset) {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-327-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }
        return try CropUITestSupport.makeSession(in: workDir,
                                                 width: Self.source.width,
                                                 height: Self.source.height)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "photons.327.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
