import XCTest
import Metal
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// **324 — 旋转 + 裁切 + 透视**: the 307/310/317 canvas and clamp rules, extended to a keystoned
/// picture.
///
/// 307 measured the document canvas of a **turned rectangle**; 317 stopped the frame at that
/// rectangle's four edges. A keystoned photograph is a **quadrilateral**, so all four of the user's
/// sentences change owner:
///
///   1. 顺序 — 透视 → 旋转 → 裁切. Pinned by a rendered marker, with the reverse walk printed;
///   2. 画布 — the AABB of the perspective+rotation quad, and the pixels it does not cover are
///      `000000` (photograph black), never the backdrop;
///   3. 遮罩 — the backdrop colour only **outside** that box (`CanvasBackdrop.current`, never a
///      literal — 315 replaced `0F0F0F` with a setting);
///   4. 未勾「不出像素」 — the frame may cover `000000`, may not leave the AABB, and **only translates**;
///   5. 勾「不出像素」 — its four corners stay inside the **quad's** four half-planes, only translates,
///      and a size that fits nowhere is inscribed once.
///
/// Every expectation is recomputed in this file from `PerspectiveMap.forward` + a rotation + an AABB
/// (or from a point-in-polygon the test owns), never read back out of `CropGeometry`, so a
/// disagreement between the two shows up instead of cancelling out.
final class KeystoneCanvas324Tests: XCTestCase {

    /// `(+30, 0)` is the spec's vertical keystone; `(+30, −15)` adds the horizontal knob so the quad
    /// is skew in both axes and an AABB cannot be mistaken for it.
    private static let keystones: [(vertical: Double, horizontal: Double)] = [(30, 0), (30, -15)]
    private static let angles: [Double] = [0, 9, 45]

    /// Document geometry is measured on the shipped 3:2 frame; the renders use a small one.
    private static let source = ImageSize(width: 1200, height: 800)

    // MARK: - the independent geometry (this file's own derivation)

    /// `P` then `R`, in photo pixels — the user's order, written out.
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

    /// The photograph's four corners (un-shifted, photo pixels) and the AABB they are measured in.
    private func photoCorners(vertical: Double, horizontal: Double, degrees: Double,
                              source: ImageSize) -> (corners: [CGPoint], minX: Double, minY: Double,
                                                     width: Double, height: Double) {
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            warpAndTurn($0, vertical: vertical, horizontal: horizontal,
                        degrees: degrees, source: source)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return (corners, minX, minY, xs.max()! - minX, ys.max()! - minY)
    }

    /// A crop rect's four corners in the **document canvas'** pixels (origin = the photo AABB's
    /// top-left), the same order TL/TR/BR/BL.
    private func frameCorners(of rect: CropRect, vertical: Double, horizontal: Double,
                              degrees: Double, source: ImageSize) -> [CGPoint] {
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        return [(rect.left, rect.top), (rect.right, rect.top),
                (rect.right, rect.bottom), (rect.left, rect.bottom)].map { corner in
            let p = warpAndTurn(corner, vertical: vertical, horizontal: horizontal,
                                degrees: degrees, source: source)
            return CGPoint(x: p.x - photo.minX, y: p.y - photo.minY)
        }
    }

    /// Signed distance (pixels, positive inside) from `point` to the convex polygon `polygon`.
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
            if nx * (cx - Double(a.x)) + ny * (cy - Double(a.y)) > 0 {
                nx = -nx; ny = -ny
            }
            worst = min(worst, -(nx * (Double(point.x) - Double(a.x))
                                 + ny * (Double(point.y) - Double(a.y))))
        }
        return worst
    }

    private func worstInset(_ corners: [CGPoint], in polygon: [CGPoint]) -> Double {
        corners.reduce(Double.infinity) { min($0, inset($1, in: polygon)) }
    }

    /// Fraction of the frame's own document quad that lies **outside** the photograph's quad — the
    /// `000000` the frame would cover. Sampled bilinearly over the frame's four corners (TL/TR/BR/BL),
    /// so it measures the region the crop would export, not just four points.
    private func blackCoverage(of frame: [CGPoint], photoQuad: [CGPoint], samples: Int = 48) -> Double {
        guard frame.count == 4 else { return 0 }
        let tl = frame[0], tr = frame[1], br = frame[2], bl = frame[3]
        var outside = 0, total = 0
        for j in 0..<samples {
            for i in 0..<samples {
                let u = (Double(i) + 0.5) / Double(samples)
                let v = (Double(j) + 0.5) / Double(samples)
                let x = (1 - u) * (1 - v) * Double(tl.x) + u * (1 - v) * Double(tr.x)
                    + u * v * Double(br.x) + (1 - u) * v * Double(bl.x)
                let y = (1 - u) * (1 - v) * Double(tl.y) + u * (1 - v) * Double(tr.y)
                    + u * v * Double(br.y) + (1 - u) * v * Double(bl.y)
                total += 1
                if inset(CGPoint(x: x, y: y), in: photoQuad) < -1e-9 { outside += 1 }
            }
        }
        return total > 0 ? Double(outside) / Double(total) : 0
    }

    private func geometry(vertical: Double, horizontal: Double, degrees: Double,
                          crop: CropRect = .full,
                          source: ImageSize = KeystoneCanvas324Tests.source) -> CropGeometry {
        let group = GeometryGroup(crop: crop.normalizedRect,
                                  rotationDegrees: degrees,
                                  aspectLock: .original,
                                  quarterTurns: 0,
                                  perspectiveVertical: vertical,
                                  perspectiveHorizontal: horizontal)
        return CropGeometry(geometry: group, source: source)
    }

    private func label(_ vertical: Double, _ horizontal: Double) -> String {
        String(format: "keystone(%+.0f,%+.0f)", vertical, horizontal)
    }

    // MARK: - ① 画布 = 四边形 AABB

    /// `canvas(.document)` == the AABB of `P → R`'s four corners, per component within a pixel, and
    /// the magnification over the raw photograph printed for the diagnosis.
    func testOneTheCanvasIsThePerspectiveQuadAABB() {
        var worstError = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees)
                let canvas = mine.canvas(.document)
                let quad = mine.photoQuad()
                // …the quad's own corners, in document pixels, against the closed form.
                for (index, corner) in quad.enumerated() {
                    let expected = CGPoint(x: photo.corners[index].x - photo.minX,
                                           y: photo.corners[index].y - photo.minY)
                    let error = max(abs(corner.x - Double(expected.x)),
                                    abs(corner.y - Double(expected.y)))
                    worstError = max(worstError, error)
                    XCTAssertLessThanOrEqual(error, 1e-9,
                        "\(label(vertical, horizontal)) @\(Int(degrees))° corner \(index)")
                }
                // …and the canvas is that quad's AABB, ±1 px per component.
                let expectedW = CropGeometry.canvasPixels(photo.width)
                let expectedH = CropGeometry.canvasPixels(photo.height)
                print(String(format: "324 ① · %@ @%.0f° · canvas %d×%d · quad AABB %d×%d"
                             + " · magnification %.3f× × %.3f× · AABB %.3f×%.3f px",
                             label(vertical, horizontal), degrees,
                             canvas.width, canvas.height, expectedW, expectedH,
                             Double(canvas.width) / Double(Self.source.width),
                             Double(canvas.height) / Double(Self.source.height),
                             photo.width, photo.height))
                XCTAssertLessThanOrEqual(abs(canvas.width - expectedW), 1)
                XCTAssertLessThanOrEqual(abs(canvas.height - expectedH), 1)
                XCTAssertEqual(mine.canvasExtent(.document).width, photo.width, accuracy: 1.0)
                XCTAssertEqual(mine.canvasExtent(.document).height, photo.height, accuracy: 1.0)
                // A keystone can only grow the box: the picture is warped outside the frame.
                XCTAssertGreaterThanOrEqual(canvas.width, Self.source.width - 1)
                XCTAssertGreaterThanOrEqual(canvas.height, Self.source.height - 1)
                XCTAssertEqual(mine.frameSize, canvas,
                               "a keystoned document's frame *is* its canvas (246)")
            }
        }
        print(String(format: "324 ① · worst quad-corner error %.3e px", worstError))
        XCTAssertLessThanOrEqual(worstError, 1e-9)
    }

    // MARK: - ② 000000 inside, the backdrop outside

    /// `.document` at `+30/−15 · 9°`: every pixel inside the drawn canvas is photograph or `000000`,
    /// the backdrop appears **only** outside it, and `000000` appears **only** inside it.
    func testTwoTheCanvasFillIsBlackAndTheBackdropStaysOutside() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let source = ImageSize(width: 480, height: 320)
        let vertical = 30.0, horizontal = -15.0, degrees = 9.0
        let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees,
                            source: source)
        let box = mine.canvas(.document)
        let viewport = ImageSize(width: 900, height: 640)
        let graph = try RenderGraph(input: RenderInput(image: rampImage(source, keystone: true),
                                                       identity: "324-document-canvas"))
        let edit = document(vertical: vertical, horizontal: horizontal, degrees: degrees)
        let zoom = LoupeFraming.fitZoom(viewportWidth: Double(viewport.width),
                                        viewportHeight: Double(viewport.height),
                                        extent: (Double(box.width), Double(box.height)),
                                        isWholeFrame: true)
        let result = try graph.render(edit, options: RenderOptions(
            canvas: viewport, canvasRole: .document, scale: zoom, useCache: false,
            wantsPixels: false, neverUpscalesContent: true))
        let texture = try XCTUnwrap(result.output, "no render")
        defer { graph.recycle(output: texture) }
        let presenter = try CanvasPresenter(device: device)
        let presented = try present(device, width: viewport.width, height: viewport.height)
        XCTAssertTrue(presenter.renderForTest(texture, window: .whole, picture: result.drawnRect,
                                              into: presented, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        // 315 — the matte is a **setting**, read, never typed.
        let matte = Int(CanvasBackdrop.current.eightBitValue)
        let mattePixel = [UInt8(matte), UInt8(matte), UInt8(matte)]
        let r = result.drawnRect
        var zeroInside = 0, matteInside = 0, zeroOutside = 0, matteOutside = 0, photo = 0
        for y in 0..<viewport.height {
            for x in 0..<viewport.width {
                let p = pixel(presented, x, y)
                let inside = x >= r.x && x < r.maxX && y >= r.y && y < r.maxY
                if inside {
                    if p == [0, 0, 0] { zeroInside += 1 }
                    else if p == mattePixel { matteInside += 1 }
                    else { photo += 1 }
                } else if p == mattePixel { matteOutside += 1 }
                else if p == [0, 0, 0] { zeroOutside += 1 }
            }
        }
        print(String(format: "324 ② · %@ @%.0f° · canvas %d×%d drawn %dx%d@(%d,%d)"
                     + " · 000000 inside %d (%.2f%%) · backdrop(%d) outside %d"
                     + " · backdrop inside %d · 000000 outside %d · photo %d",
                     label(vertical, horizontal), degrees, box.width, box.height,
                     r.width, r.height, r.x, r.y, zeroInside,
                     100 * Double(zeroInside) / Double(max(1, r.width * r.height)),
                     matte, matteOutside, matteInside, zeroOutside, photo))
        XCTAssertLessThanOrEqual(abs(r.width - Int((Double(box.width) * zoom).rounded())), 1)
        XCTAssertLessThanOrEqual(abs(r.height - Int((Double(box.height) * zoom).rounded())), 1)
        XCTAssertEqual(matteInside, 0, "the backdrop leaked inside the canvas")
        XCTAssertEqual(zeroOutside, 0, "000000 leaked outside the canvas")
        XCTAssertGreaterThan(zeroInside, 0, "a keystone must leave 000000 in the canvas")
        XCTAssertGreaterThan(matteOutside, 0)
        XCTAssertGreaterThan(photo, 0)
    }

    // MARK: - ③ 未勾选：可以进 000000，不能出 AABB，只平移

    /// A 70 %-wide frame pushed into each of the canvas' four corners, 20 ticks each, through the
    /// **shipped** stop (`CropTool.clampToCanvas(perspective:)`).
    ///
    /// 70 % because that is what makes 「可以进 000000」 measurable: a small frame parked on the
    /// canvas' corner sits on the *photograph* (the quad's vertex is that corner), so it would say
    /// nothing. A large one spans the black the warp leaves along the canvas' edges, and the coverage
    /// is counted by sampling the frame's own document quad — the pixels the export would take from
    /// that region.
    func testThreeUncheckedTheFrameCoversBlackButNeverLeavesTheAABB() {
        var worstOverhang = 0.0, worstDw = 0.0, worstDh = 0.0
        var cases = 0
        var bestCoverage = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
                let canvas = CGSize(width: photo.width, height: photo.height)
                let canvasQuad = [CGPoint.zero, CGPoint(x: canvas.width, y: 0),
                                  CGPoint(x: canvas.width, y: canvas.height),
                                  CGPoint(x: 0, y: canvas.height)]
                for corner in 0..<4 {
                    var rect = CropRect(left: 0.15, top: 0.15, right: 0.85, bottom: 0.85)
                    let snapshot = rect
                    // Push 20 ticks toward one canvas corner; each tick is 「drag wrote a rect, then
                    // the refresh clamps it」, which is exactly `clampToView`'s law.
                    for tick in 1...20 {
                        let step = 0.05 * Double(tick)
                        let dx = (corner == 0 || corner == 3) ? -step : step
                        let dy = (corner == 0 || corner == 1) ? -step : step
                        rect = CropRect(left: snapshot.left + dx, top: snapshot.top + dy,
                                        right: snapshot.right + dx, bottom: snapshot.bottom + dy)
                        rect = CropTool.clampToCanvas(rect, mapping: Self.mapping(degrees: degrees),
                                                      source: Self.source, degrees: degrees,
                                                      perspective: PerspectiveMap(vertical: vertical,
                                                                                 horizontal: horizontal))
                    }
                    let corners = frameCorners(of: rect, vertical: vertical, horizontal: horizontal,
                                               degrees: degrees, source: Self.source)
                    let overhang = max(0, -worstInset(corners, in: canvasQuad))
                    let black = blackCoverage(of: corners, photoQuad: quad)
                    let dw = abs(rect.width - snapshot.width)
                    let dh = abs(rect.height - snapshot.height)
                    worstOverhang = max(worstOverhang, overhang)
                    worstDw = max(worstDw, dw)
                    worstDh = max(worstDh, dh)
                    cases += 1
                    bestCoverage = max(bestCoverage, black)
                    print(String(format: "324 ③ · %@ @%.0f° corner %d · L %.4f T %.4f"
                                 + " · overhang %.3e px · 000000 under the frame %.2f %%",
                                 label(vertical, horizontal), degrees, corner,
                                 rect.left, rect.top, overhang, black * 100))
                    XCTAssertLessThanOrEqual(overhang, 1e-9,
                        "\(label(vertical, horizontal)) @\(Int(degrees))° corner \(corner): the frame left the AABB by \(overhang) px")
                    XCTAssertLessThanOrEqual(dw, 1e-12)
                    XCTAssertLessThanOrEqual(dh, 1e-12)
                }
            }
        }
        // ── the other half of the rule: 「可以到 00 的黑色像素」 ────────────────────────────────────────
        // A keystoned crop's document quad is `P(crop rect)`, and `P` maps the photograph's own edges
        // to the quad's edges — so a crop **inside** `0…1²` can never cover black. Only a frame that
        // reaches past the photograph can, and the canvas is what stops it. So the proof is: a frame
        // that pokes out of the picture and stays inside the AABB is left **exactly** where it is,
        // and the black under it is counted.
        var reaching: [(label: String, rect: CropRect, coverage: Double)] = []
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
                for offset in [-0.08, -0.04, -0.02] as [Double] {
                    for verticalSign in [offset, -offset] {
                        let rect = CropRect(left: verticalSign, top: offset,
                                            right: verticalSign + 0.9, bottom: offset + 0.9)
                        let clamped = CropTool.clampToCanvas(rect, mapping: Self.mapping(degrees: degrees),
                                                             source: Self.source, degrees: degrees,
                                                             perspective: PerspectiveMap(vertical: vertical,
                                                                                        horizontal: horizontal))
                        guard clamped == rect else { continue }      // moved: not a legal black seat
                        let corners = frameCorners(of: rect, vertical: vertical,
                                                   horizontal: horizontal,
                                                   degrees: degrees, source: Self.source)
                        let black = blackCoverage(of: corners, photoQuad: quad)
                        guard black > 0 else { continue }
                        reaching.append((label(vertical, horizontal), rect, black))
                        print(String(format: "324 ③ · %@ @%.0f° · frame (%.2f,%.2f)-(%.2f,%.2f)"
                                     + " left where it is · 000000 under it %.2f %%",
                                     label(vertical, horizontal), degrees,
                                     rect.left, rect.top, rect.right, rect.bottom, black * 100))
                        XCTAssertEqual(clamped, rect,
                                       "a frame covering black inside the AABB must not be moved")
                    }
                }
            }
        }
        print("324 ③ · frames covering 000000 inside the AABB: \(reaching.count)"
              + String(format: " · best %.2f %%", (reaching.map(\.coverage).max() ?? 0) * 100))
        XCTAssertGreaterThan(reaching.count, 0,
                             "no legal frame reaches 000000 — the clamp forbids the black corners")

        print(String(format: "324 ③ · 20 tick × 4 corners × %d groups × %d angles · worst overhang"
                     + " %.3e px · Δw %.1e · Δh %.1e · %d pushes",
                     Self.keystones.count, Self.angles.count, worstOverhang, worstDw, worstDh,
                     cases))
        XCTAssertLessThanOrEqual(worstOverhang, 1e-9)
        XCTAssertLessThanOrEqual(worstDw, 1e-12)
        XCTAssertLessThanOrEqual(worstDh, 1e-12)
    }

    // MARK: - ④ 勾选：四角在透视四边形内，只平移

    /// With 「不出像素」 on, 20 ticks: every corner stays inside the **quad** (≥ −1e−9), the size never
    /// moves (≤ 1e−12), and the limit is the edge itself.
    ///
    /// The clamp under test is the one `CropToolController.placedInsidePixels` runs on every refresh
    /// (`CropGeometry.translatedInsidePhotoQuad`); a tick is 「the drag wrote a rect」 + that clamp,
    /// which is the whole of a tick's geometry. `testFourB` proves the controller reaches it.
    func testFourCheckedTheFrameStaysInsideTheQuadAndNeverResizes() {
        var worstInsetSeen = Double.infinity, worstDw = 0.0, worstDh = 0.0
        var worstLimitDistance = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in Self.angles {
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees)
                // A frame the picture can hold: the inscribed one (no translation needed at 45°).
                let start = mine.inscribedInPhotoQuad(.full)
                XCTAssertGreaterThanOrEqual(
                    worstInset(frameCorners(of: start, vertical: vertical, horizontal: horizontal,
                                            degrees: degrees, source: Self.source), in: quad), -1e-9,
                    "\(label(vertical, horizontal)) @\(Int(degrees))°: the inscribed frame is not inside the quad")
                let snapshot = start
                var rect = start
                for tick in 1...20 {
                    let offset = tick <= 10 ? 0.01 * Double(tick) : -0.12 * Double(tick - 10)
                    let candidate = CropRect(left: snapshot.left + offset, top: snapshot.top + offset,
                                             right: snapshot.right + offset,
                                             bottom: snapshot.bottom + offset)
                    rect = mine.translatedInsidePhotoQuad(candidate, tolerance: 1e-9) ?? rect
                    let corners = frameCorners(of: rect, vertical: vertical, horizontal: horizontal,
                                               degrees: degrees, source: Self.source)
                    let distance = worstInset(corners, in: quad)
                    worstInsetSeen = min(worstInsetSeen, distance)
                    let dw = abs(rect.width - snapshot.width)
                    let dh = abs(rect.height - snapshot.height)
                    worstDw = max(worstDw, dw)
                    worstDh = max(worstDh, dh)
                    XCTAssertGreaterThanOrEqual(distance, -1e-9,
                        String(format: "%@ @%.0f° tick %d: corner %.3e px outside the quad",
                               label(vertical, horizontal), degrees, tick, distance))
                    XCTAssertLessThanOrEqual(dw, 1e-12)
                    XCTAssertLessThanOrEqual(dh, 1e-12)
                }
                // The limit is the edge: after being pushed the frame touches it.
                let corners = frameCorners(of: rect, vertical: vertical, horizontal: horizontal,
                                           degrees: degrees, source: Self.source)
                let closest = corners.map { inset($0, in: quad) }.min() ?? .infinity
                worstLimitDistance = max(worstLimitDistance, abs(closest))
                print(String(format: "324 ④ · %@ @%.0f° · 20 tick · worst inset %.3e px"
                             + " · Δw %.1e Δh %.1e · limit touch %.3e px · frame %.4f×%.4f",
                             label(vertical, horizontal), degrees, worstInsetSeen,
                             worstDw, worstDh, closest, rect.width, rect.height))
                XCTAssertLessThanOrEqual(abs(closest), 1e-9,
                                         "the limit must be the edge itself, not a conservative inset")
            }
        }
        print(String(format: "324 ④ · worst inset %.3e px · Δw %.1e · Δh %.1e",
                     worstInsetSeen, worstDw, worstDh))
        XCTAssertGreaterThanOrEqual(worstInsetSeen, -1e-9)
    }

    // MARK: - ⑤ 45° 满幅 → 一次性内切

    /// At 45° the warp puts the export canvas' corners outside the picture, so a full frame cannot be
    /// kept at all (its `frameSize` **is** its canvas, 246) and is inscribed **once**: smaller area,
    /// same pixel aspect, four corners inside.
    func testFiveAFullFrameAtFortyFiveDegreesIsInscribedOnce() {
        for (vertical, horizontal) in Self.keystones {
            let degrees = 45.0
            let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees)
            let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                     degrees: degrees, source: Self.source)
            let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
            XCTAssertTrue(CropMath.frameExceedsPicture(.full, in: Self.source, degrees: degrees,
                                                       perspective: PerspectiveMap(vertical: vertical,
                                                                                  horizontal: horizontal)),
                          "\(label(vertical, horizontal)) 45°: a full frame's canvas must not fit")
            let inscribed = mine.inscribedInPhotoQuad(.full)
            let areaBefore = 1.0, areaAfter = inscribed.width * inscribed.height
            let distance = worstInset(frameCorners(of: inscribed, vertical: vertical,
                                                   horizontal: horizontal, degrees: degrees,
                                                   source: Self.source), in: quad)
            print(String(format: "324 ⑤ · %@ @45° · area %.6f → %.6f (Δ %.6f)"
                         + " · frame %.6f×%.6f · inset %.3e px · pixel aspect %.6f → %.6f",
                         label(vertical, horizontal), areaBefore, areaAfter,
                         areaBefore - areaAfter, inscribed.width, inscribed.height, distance,
                         Double(Self.source.width) / Double(Self.source.height),
                         (inscribed.width * Double(Self.source.width))
                            / (inscribed.height * Double(Self.source.height))))
            XCTAssertLessThan(areaAfter, areaBefore)
            XCTAssertGreaterThan(areaBefore - areaAfter, 1e-6)
            XCTAssertGreaterThanOrEqual(distance, -1e-9, "the inscribed frame is not inside the quad")
            XCTAssertEqual(inscribed.width / inscribed.height, 1.0, accuracy: 1e-9)
            // Once only: the answer is a fixed point of the inscription.
            XCTAssertEqual(mine.inscribedInPhotoQuad(inscribed), inscribed)
        }
    }

    // MARK: - ⑥ 导出无黑

    /// `+30 · 9°`, full frame → 一次性内切 → the **export** carries no black pixel: the frame's canvas
    /// lies inside the photograph, so every sample is a photograph pixel.
    func testSixTheInscribedExportCarriesNoBlackPixel() throws {
        let source = ImageSize(width: 480, height: 320)
        let graph = try RenderGraph(input: RenderInput(image: rampImage(source, keystone: false),
                                                       identity: "324-export"))
        for (vertical, horizontal) in Self.keystones {
            let degrees = 9.0
            let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees,
                                source: source)
            let insetFrame = mine.inscribedInPhotoQuad(.full)
            var edit = document(vertical: vertical, horizontal: horizontal, degrees: degrees)
            edit.geometry.crop = insetFrame.normalizedRect
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: true))
            let display = try XCTUnwrap(result.display)
            var black = 0
            for y in 0..<display.height {
                for x in 0..<display.width where luma(display, x, y) <= 1e-3 { black += 1 }
            }
            let fraction = Double(black) / Double(display.width * display.height)
            print(String(format: "324 ⑥ · %@ @9° · export %d×%d · frame %.6f×%.6f"
                         + " · black %d px = %.3f %%",
                         label(vertical, horizontal), display.width, display.height,
                         insetFrame.width, insetFrame.height, black, fraction * 100))
            XCTAssertEqual(fraction, 0, accuracy: 1e-9,
                           "\(label(vertical, horizontal)): the inscribed export still carries black")
        }
    }

    // MARK: - ⑦ 顺序：透视 → 旋转

    /// A bright block in the photograph's top-left, rendered at `+30 · 9°` on the export canvas (which
    /// for a full crop **is** the document canvas). It must land where `R(P(·))` puts it; the reverse
    /// walk `P(R(·))` is printed as the counter-example and must be a different place by a distance
    /// the assertion would notice.
    func testTheOrderIsPerspectiveThenRotation() throws {
        let source = ImageSize(width: 480, height: 320)
        let vertical = 30.0, degrees = 9.0, horizontal = 0.0
        // The marker: a 40×40 block centred on (0.12, 0.12) of the photograph.
        let blockCentre = (u: 0.12, v: 0.12)
        let image = markerImage(source, blockCentre: blockCentre, blockSize: 40)
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "324-order"))
        let edit = document(vertical: vertical, horizontal: horizontal, degrees: degrees)
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                   wantsPixels: true))
        let display = try XCTUnwrap(result.display)

        var sumX = 0.0, sumY = 0.0, count = 0
        for y in 0..<display.height {
            for x in 0..<display.width where luma(display, x, y) > 1.0 {
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0, "the marker did not render")
        let measured = CGPoint(x: sumX / Double(count), y: sumY / Double(count))

        // The document canvas' own grid, so the expected point is directly comparable.
        let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                 degrees: degrees, source: source)
        let forward = warpAndTurn(blockCentre, vertical: vertical, horizontal: horizontal,
                                  degrees: degrees, source: source)
        let expected = CGPoint(x: forward.x - photo.minX, y: forward.y - photo.minY)
        // The reverse order: turn the photograph first, then warp it.
        let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
        let w = Double(source.width), h = Double(source.height)
        let upright = (x: blockCentre.u * w, y: blockCentre.v * h)
        let radians = degrees * .pi / 180
        let dx = upright.x - w / 2, dy = upright.y - h / 2
        let turned = (x: dx * cos(radians) - dy * sin(radians) + w / 2,
                      y: dx * sin(radians) + dy * cos(radians) + h / 2)
        let reversedWarp = map.forward(x: turned.x / w, y: turned.y / h)
        let reversed = CGPoint(x: reversedWarp.x * w - photo.minX,
                               y: reversedWarp.y * h - photo.minY)

        let toForward = hypot(Double(measured.x - expected.x), Double(measured.y - expected.y))
        let toReversed = hypot(Double(measured.x - reversed.x), Double(measured.y - reversed.y))
        print(String(format: "324 ⑦ · %@ @%.0f° · marker centroid (%.1f, %.1f)"
                     + " · P→R predicts (%.1f, %.1f) (Δ %.2f px)"
                     + " · R→P predicts (%.1f, %.1f) (Δ %.2f px) · the two differ by %.1f px",
                     label(vertical, horizontal), degrees, measured.x, measured.y,
                     expected.x, expected.y, toForward,
                     reversed.x, reversed.y, toReversed,
                     hypot(Double(expected.x - reversed.x), Double(expected.y - reversed.y))))
        XCTAssertLessThan(toForward, 1.5, "the marker is not where 透视 then 旋转 puts it")
        XCTAssertGreaterThan(toReversed, 2.0,
                             "the reverse order is too close to tell the two apart — the test would not discriminate")
        XCTAssertGreaterThan(hypot(Double(expected.x - reversed.x),
                                   Double(expected.y - reversed.y)), 2.0)
    }

    // MARK: - ④b the controller reaches the quad

    /// The wiring, on the shipped controller: with 「不出像素」 on, ticking the box inscribes a
    /// keystone's full frame once, and a refresh after a hand-write stops the frame at the **quad**,
    /// not at the canvas' AABB (307's stop) and not at the turned rectangle's edges (317's).
    @MainActor
    func testFourBTheControllerStopsTheFrameAtTheQuad() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-324-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let suite = "photons.crop324.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session, defaults: defaults)
        XCTAssertTrue(controller.begin())
        let vertical = 30.0, horizontal = -15.0, degrees = 9.0
        controller.draft = CropToolController.Draft(crop: .full, straighten: degrees,
                                                    lock: .original,
                                                    perspectiveVertical: vertical,
                                                    perspectiveHorizontal: horizontal)
        XCTAssertEqual(controller.sourceSize, Self.source)
        XCTAssertFalse(controller.cropStaysInsidePixels)
        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        let inscribed = controller.draft.crop
        XCTAssertLessThan(inscribed.width, 1, "the keystone's full frame cannot be held — it must be inscribed")

        let photo = photoCorners(vertical: vertical, horizontal: horizontal, degrees: degrees,
                                 source: Self.source)
        let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
        let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees)
        XCTAssertEqual(inscribed, mine.inscribedInPhotoQuad(.full),
                       "the controller's inscription is not the one `inscribedInPhotoQuad` names")

        // A hand-write far outside, then the refresh the loupe runs on every tick.
        let pushed = CropRect(left: 0.85, top: 0.85, right: 1.15, bottom: 1.15)
        controller.draft.crop = pushed
        _ = controller.clampToView(mapping: Self.mapping(degrees: degrees), source: Self.source)
        let after = controller.draft.crop
        let corners = frameCorners(of: after, vertical: vertical, horizontal: horizontal,
                                   degrees: degrees, source: Self.source)
        let distance = worstInset(corners, in: quad)
        print(String(format: "324 ④b · controller %@ @%.0f° · inscribed %.6f×%.6f"
                     + " · pushed (%.2f,%.2f) → (%.4f,%.4f) · inset %.3e px · Δsize (%.1e, %.1e)",
                     label(vertical, horizontal), degrees, inscribed.width, inscribed.height,
                     pushed.left, pushed.top, after.left, after.top, distance,
                     after.width - pushed.width, after.height - pushed.height))
        XCTAssertGreaterThanOrEqual(distance, -1e-9, "the controller let the frame out of the quad")
        XCTAssertEqual(after.width, pushed.width, accuracy: 1e-12)
        XCTAssertEqual(after.height, pushed.height, accuracy: 1e-12)
        XCTAssertEqual(controller.canvasShrinkTicks, 0)
    }

    // MARK: - ⑧ 两条反向门

    /// **Gate ① — the quad, not the turned rectangle.** A frame the 317 rule calls legal (its corners
    /// inside `0…1²` of the turned photograph) has corners **outside** the keystoned quad: the old
    /// predicate counted the black triangle as photograph. This is the gate 验收 ④ turns red on.
    func testGateOneTheRotatedRectangleCallsAKeystonedFrameLegal() {
        var disagreements = 0, worst = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in [0.0, 9.0] {
                let photo = photoCorners(vertical: vertical, horizontal: horizontal,
                                         degrees: degrees, source: Self.source)
                let quad = photo.corners.map { CGPoint(x: $0.x - photo.minX, y: $0.y - photo.minY) }
                let mine = geometry(vertical: vertical, horizontal: horizontal, degrees: degrees)
                // The corner of the crop's own axes: 317's rule is exactly "inside 0…1²" (+ the
                // rotation), and at the picture's corner that is legal while the warp has moved the
                // picture's edge inward.
                for corner in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
                    let rect = CropRect(left: corner.0, top: corner.1,
                                        right: corner.0 + 0.2, bottom: corner.1 + 0.2)
                        .clamped(allowsOutsideSource: true)
                    let rectangleRuleAccepts = CropMath.translatedInsidePixels(
                        rect, in: Self.source, degrees: degrees) != nil
                        && CropMath.fitsInsideRotatedFrame(rect.clamped(),
                                                           in: Self.source, degrees: degrees,
                                                           tolerance: 1e-6)
                    let corners = frameCorners(of: rect, vertical: vertical, horizontal: horizontal,
                                               degrees: degrees, source: Self.source)
                    let distance = worstInset(corners, in: quad)
                    guard rectangleRuleAccepts, distance < -1e-9 else { continue }
                    disagreements += 1
                    worst = min(worst, distance)
                    // …and the quad rule refuses it: `photoQuad` is the region 324 clamps to.
                    let placed = mine.translatedInsidePhotoQuad(rect)
                    XCTAssertNotEqual(placed, rect,
                                      "\(label(vertical, horizontal)): the quad rule must move the frame")
                    print(String(format: "324 gate① · %@ @%.0f° · rect (%.2f,%.2f)-(%.2f,%.2f)"
                                 + " legal under the 317 rectangle, %.1f px outside the quad"
                                 + " → the quad rule moves it %@",
                                 label(vertical, horizontal), degrees,
                                 rect.left, rect.top, rect.right, rect.bottom, -distance,
                                 placed == nil ? "nowhere" : "in"))
                }
            }
        }
        print("324 gate① · 317's rotated rectangle accepts \(disagreements) frames the quad rejects"
              + String(format: " · worst %.2f px outside", -worst))
        XCTAssertGreaterThan(disagreements, 0,
                             "the two rules never disagree — 验收 ④ would not be a gate")
    }

    /// **Gate ② — the order.** Turning the photograph *before* warping it puts the same marker a
    /// measurable distance away, so ⑦ is a test of the order and not of "a point moved at all".
    func testGateTwoTheReversedOrderIsMeasurablyDifferent() {
        var worst = 0.0
        for (vertical, horizontal) in Self.keystones {
            for degrees in [9.0, 45.0] {
                let source = Self.source
                let w = Double(source.width), h = Double(source.height)
                let map = PerspectiveMap(vertical: vertical, horizontal: horizontal)
                let radians = degrees * .pi / 180
                var separations: [Double] = []
                for corner in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
                    let forward = warpAndTurn(corner, vertical: vertical, horizontal: horizontal,
                                              degrees: degrees, source: source)
                    let upright = (x: corner.0 * w - w / 2, y: corner.1 * h - h / 2)
                    let turned = (x: upright.x * cos(radians) - upright.y * sin(radians) + w / 2,
                                  y: upright.x * sin(radians) + upright.y * cos(radians) + h / 2)
                    let reversedWarp = map.forward(x: turned.x / w, y: turned.y / h)
                    separations.append(hypot(forward.x - reversedWarp.x * w,
                                             forward.y - reversedWarp.y * h))
                }
                let mean = separations.reduce(0, +) / Double(separations.count)
                worst = max(worst, mean)
                print(String(format: "324 gate② · %@ @%.0f° · P→R vs R→P corners differ by"
                             + " %.1f px on average (max %.1f px)",
                             label(vertical, horizontal), degrees, mean, separations.max() ?? 0))
                XCTAssertGreaterThan(mean, 5.0,
                                     "\(label(vertical, horizontal)) @\(Int(degrees))°: the two orders coincide, so ⑦ proves nothing")
            }
        }
        XCTAssertGreaterThan(worst, 5.0)
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

    private func rampImage(_ size: ImageSize, keystone: Bool) -> LinearImage {
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
                           colorSpace: "sRGB", decoderVersion: keystone ? "324-keystone" : "324")
    }

    /// Black photograph with one bright block — the order test's marker.
    private func markerImage(_ size: ImageSize, blockCentre: (u: Double, v: Double),
                             blockSize: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        let cx = Int(blockCentre.u * Double(size.width))
        let cy = Int(blockCentre.v * Double(size.height))
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
                           colorSpace: "sRGB", decoderVersion: "324-marker")
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return Double(image.rgba[o]) + Double(image.rgba[o + 1]) + Double(image.rgba[o + 2])
    }

    private static func mapping(degrees: Double) -> LoupeMapping {
        LoupeFraming(viewport: ImageSize(width: 1400, height: 1000),
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: .full, straightenDegrees: degrees).mapping(of: .fit)
    }

    private func present(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 4,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return [raw[2], raw[1], raw[0]]
    }
}

