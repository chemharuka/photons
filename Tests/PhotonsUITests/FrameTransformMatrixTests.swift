import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 260 — the transform-chain guard matrix.
///
/// This suite is a **measurement**, not a fix: it renders every combination of the four dimensions the
/// user's report names (straighten × crop × zoom × decode rung) and asserts three independent walks
/// through the same document agree in S5 device pixels:
///
///   1. **render** — the markers actually drawn in the frame are where S1 → S3 (`CropGeometry`) →
///      S5 (`LoupeMapping`) puts them;
///   2. **overlay** — the crop frame the crop tool lays out is the same S2 → S5 rectangle;
///   3. **hit test** — `LoupeMapping.sourcePoint` agrees with S5 → S3 → S1 walked step by step.
///
/// The point of the table is to name the scale factor that is off, not to bless the current numbers.
/// The three historical lesions (`frameOrigin` letterbox double-add, rung-size mix-up, a second crop
/// ratio) are reproduced in `local/REPORT.md`, each with the matrix's failing output.
///
/// Perspective is **not** a dimension here: 246 ("先透视→再旋转→再算画布 AABB") is on `main` but is
/// not an ancestor of this worktree's HEAD (`610beb1`), so this lane measures the identity keystone
/// only. That is stated in the report rather than silently skipped.
///
/// S1 源像素 · S2 帧（裁切框）· S3 帧画布（保留画面）· S4 源画布（整幅照片）· S5 视口.
final class FrameTransformMatrixTests: XCTestCase {

    // MARK: dimensions

    private struct Angle: CustomStringConvertible {
        let name: String
        let straighten: Double
        let quarterTurns: Int
        var description: String { name }
        static let all: [Angle] = [
            Angle(name: "0°", straighten: 0, quarterTurns: 0),
            Angle(name: "0.1°", straighten: 0.1, quarterTurns: 0),
            Angle(name: "1°", straighten: 1, quarterTurns: 0),
            Angle(name: "45°", straighten: 45, quarterTurns: 0),
            Angle(name: "90°", straighten: 0, quarterTurns: 1),
        ]
    }

    private struct Crop: CustomStringConvertible {
        let name: String
        let rect: CropRect
        var description: String { name }
        static let all: [Crop] = [
            Crop(name: "全幅", rect: .full),
            Crop(name: "居中半幅", rect: CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
            Crop(name: "偏心", rect: CropRect(left: 0.15, top: 0.20, right: 0.70, bottom: 0.85)),
            Crop(name: "贴角", rect: CropRect(left: 0, top: 0, right: 0.5, bottom: 0.5)),
        ]
    }

    private struct Zoom: CustomStringConvertible {
        let name: String
        let mode: LoupeViewState.Mode
        let zoom: Double
        var state: LoupeViewState {
            mode == .fit ? .fit
                : LoupeViewState(mode: .actual, zoom: zoom,
                                 centerX: 0, centerY: 0)
        }
        var description: String { name }
        static let all: [Zoom] = [
            Zoom(name: "fit", mode: .fit, zoom: 1),
            Zoom(name: "100%", mode: .actual, zoom: 1),
            Zoom(name: "200%", mode: .actual, zoom: 2),
        ]
    }

    private struct Rung: CustomStringConvertible {
        let scale: Double
        var description: String { String(format: "%.2g", scale) }
        static let all: [Rung] = [
            Rung(scale: 0.25), Rung(scale: 0.5), Rung(scale: 1.0),
        ]
    }

    // MARK: the fixture

    /// A 4:3 upright source. Large enough that a 25 % rung keeps markers apart, small enough that the
    /// whole matrix (540 renders at three rungs) stays a seconds-scale probe rather than a benchmark.
    private static let source = ImageSize(width: 640, height: 480)
    private static let viewport = ImageSize(width: 320, height: 240)
    private static let tolerance = 0.5

    /// Marker centres in the **turned** S1 frame (1/10 … 9/10 on both axes). A regular grid is what
    /// lets a crop cut some of them off without losing the measurement: every remaining marker is an
    /// independent S1→S5 sample.
    private static let markers: [(x: Double, y: Double)] = {
        var out: [(Double, Double)] = []
        for i in 1...9 {
            for j in 1...9 { out.append((Double(i) / 10, Double(j) / 10)) }
        }
        return out
    }()

    private struct Violation: CustomStringConvertible {
        let check: String
        let dx: Double
        let dy: Double
        let detail: String
        var description: String {
            String(format: "%@ Δ(%+.2f, %+.2f) px · %.2f px · %@",
                   check, dx, dy, hypot(dx, dy), detail)
        }
    }

    private struct Result {
        let angle: Angle
        let crop: Crop
        let zoom: Zoom
        let rung: Rung
        let violations: [Violation]
    }

    // MARK: - the three consistency walks

    private struct GeometryWalk {
        let geometry: CropGeometry
        let framing: LoupeFraming
        let mapping: LoupeMapping
        let state: LoupeViewState
        let decodeScale: Double
        let cropPixels: (width: Double, height: Double)
        let frameExtent: DSize
        let windowInFrame: (x: Double, y: Double)
        let s3Window: (x: Double, y: Double)
        /// S2 frame pixels → S5 device pixels (`mapping.frameView`'s own scale).
        let framePerSource: Double
        /// S3 canvas pixels → S5 device pixels. At fit the content rect is the whole S3 canvas, so
        /// this is `fitZoom`; at an actual camera the content rect is the window, so it is `zoom`.
        let canvasPerSource: Double

        init(edit: EditModel, source: ImageSize, rung: Rung,
             viewport: ImageSize, state: LoupeViewState) {
            let decoded = ImageSize(width: max(1, Int((Double(source.width) * rung.scale).rounded())),
                                    height: max(1, Int((Double(source.height) * rung.scale).rounded())))
            self.geometry = CropGeometry(geometry: edit.geometry, source: source)
            self.framing = LoupeFraming(viewport: viewport, decoded: decoded,
                                        decodeScale: rung.scale, edit: edit)
            self.mapping = framing.mapping(of: state)
            self.state = state
            self.decodeScale = rung.scale
            let cg = geometry
            let c = cg.crop
            self.cropPixels = (c.width * Double(cg.source.width),
                               c.height * Double(cg.source.height))
            self.frameExtent = cg.frameExtentPixels
            // The window's own origin, in the S2 frame's pixel space. `mapping.cropLeft/Top` are the
            // source-pixel window; subtracting the crop's own origin is the S2 offset the frame grid
            // is measured from.
            let wx = (mapping.cropLeft - cg.frameOriginInPhoto.x) / max(cropPixels.width, 1e-9)
            let wy = (mapping.cropTop - cg.frameOriginInPhoto.y) / max(cropPixels.height, 1e-9)
            self.windowInFrame = (wx, wy)
            // …and where that window starts in S3. At fit the whole canvas is the content, so the
            // origin is the canvas' own (0, 0); an actual camera names a window on the canvas and
            // `outputWindow` is already in that scaled canvas' pixels (integer, as the renderer).
            let zoom = framing.zoom(of: state)
            if state.mode == .fit {
                self.s3Window = (0, 0)
            } else if let window = framing.outputWindow(of: state, decodeScale: rung.scale) {
                // `outputWindow` is in the *scaled* canvas' pixels; S3 here is the 1:1 frame canvas.
                self.s3Window = (Double(window.x) / zoom, Double(window.y) / zoom)
            } else {
                self.s3Window = (0, 0)
            }
            self.framePerSource = mapping.canvasPerSource
            // Fit shows the whole S3 canvas (the rotated crop's AABB) inside the content rect; an
            // actual camera shows only the window, and `mapping.contentWidth / windowWidth == zoom`.
            self.canvasPerSource = state.mode == .fit
                ? mapping.contentWidth / Double(max(cg.canvas.width, 1))
                : mapping.canvasPerSource
        }

        /// A point of the S2 frame (frame pixels, crop-origin relative) in S5.
        func view(frameX x: Double, frameY y: Double) -> (x: Double, y: Double) {
            (mapping.originX + (x - windowInFrame.x * frameExtent.width) * framePerSource,
             mapping.originY + (y - windowInFrame.y * frameExtent.height) * framePerSource)
        }

        /// S1 normalized (turned photograph) → S2 normalized (crop frame).
        func frameNormalized(sourceX qx: Double, sourceY qy: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let c = cg.crop
            var qx = qx, qy = qy
            if let perspective = cg.perspective, perspective.hasWarp {
                (qx, qy) = perspective.forward(x: qx, y: qy)
            }
            return ((qx - c.left) / max(c.width, 1e-9),
                    (qy - c.top) / max(c.height, 1e-9))
        }

        /// S3 canvas pixel → S5 device pixel, through the camera's window (no renderer involved).
        func view(canvasX x: Double, canvasY y: Double) -> (x: Double, y: Double) {
            (mapping.originX + (x - s3Window.x) * canvasPerSource,
             mapping.originY + (y - s3Window.y) * canvasPerSource)
        }

        /// The inverse of `view(canvasX:canvasY:)` — S5 device pixel → S3 canvas pixel.
        func canvas(viewX x: Double, viewY y: Double) -> (x: Double, y: Double) {
            (s3Window.x + (x - mapping.originX) / max(canvasPerSource, 1e-9),
             s3Window.y + (y - mapping.originY) / max(canvasPerSource, 1e-9))
        }

        /// S1 source pixel → S5 device pixel, the first-principles composition the acceptance names.
        func view(sourceX x: Double, sourceY y: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let qx = x / max(Double(cg.source.width), 1e-9)
            let qy = y / max(Double(cg.source.height), 1e-9)
            let f = frameNormalized(sourceX: qx, sourceY: qy)
            let s3 = cg.canvasPoint(frameX: f.x * frameExtent.width,
                                    frameY: f.y * frameExtent.height)
            return view(canvasX: s3.x, canvasY: s3.y)
        }

        /// S5 device pixel → S1 source pixel, the two-step inverse (S5→S3, then S3→S1).
        func source(viewX x: Double, viewY y: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let s3 = canvas(viewX: x, viewY: y)
            let f = cg.framePoint(canvasX: s3.x, canvasY: s3.y)
            var rx = f.x / max(frameExtent.width, 1e-9)
            var ry = f.y / max(frameExtent.height, 1e-9)
            let c = cg.crop
            rx = c.left + rx * c.width
            ry = c.top + ry * c.height
            if let perspective = cg.perspective, perspective.hasWarp {
                (rx, ry) = perspective.inverse(x: rx, y: ry)
            }
            return (rx * Double(cg.source.width), ry * Double(cg.source.height))
        }
    }

    // MARK: - the synthetic marked photograph

    private func markedFixture(quarterTurns: Int, rung: Rung)
        -> (image: LinearImage, markers: [(x: Double, y: Double)]) {
        let width = max(1, Int((Double(Self.source.width) * rung.scale).rounded()))
        let height = max(1, Int((Double(Self.source.height) * rung.scale).rounded()))
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        let radius = max(2, Int((0.03 * Double(min(width, height))).rounded()))
        let inverseTurns = (4 - (quarterTurns % 4 + 4) % 4) % 4
        var centres: [(x: Double, y: Double)] = []
        for marker in Self.markers {
            let upright = CropMath.turned(NormalizedPoint(marker.x, marker.y),
                                          quarterTurns: inverseTurns)
            let cx = Int((upright.x * Double(width)).rounded())
            let cy = Int((upright.y * Double(height)).rounded())
            for y in max(0, cy - radius)...min(height - 1, cy + radius) {
                for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                    let o = (y * width + x) * 4
                    rgba[o] = 1; rgba[o + 1] = 1; rgba[o + 2] = 1; rgba[o + 3] = 1
                }
            }
            // The marker's physical centre is the centre of its pixel block (`+0.5`), which is the
            // convention S0 and the readbacks use too. Using the ideal 1/10 grid instead leaves a
            // systematic half-pixel bias in every marker, which is exactly the size of this suite's
            // tolerance.
            let actual = CropMath.turned(
                NormalizedPoint((Double(cx) + 0.5) / Double(width),
                                (Double(cy) + 0.5) / Double(height)),
                quarterTurns: quarterTurns)
            centres.append((actual.x, actual.y))
        }
        let image = LinearImage(width: width, height: height, rgba: rgba,
                                colorSpace: "sRGB", decoderVersion: "frame-matrix-260")
        return (image, centres)
    }

    /// Weighted centroids of every bright connected blob in the rendered S5 frame, in device pixels.
    private func blobs(in image: DisplayImage, threshold: Float = 0.15)
        -> [(x: Double, y: Double, weight: Double)] {
        let w = image.width, h = image.height
        var visited = [Bool](repeating: false, count: w * h)
        var out: [(Double, Double, Double)] = []
        func brightness(_ x: Int, _ y: Int) -> Double {
            let o = (y * w + x) * 4
            return Double(max(image.rgba[o], max(image.rgba[o + 1], image.rgba[o + 2])))
        }
        var queue: [(Int, Int)] = []
        for sy in 0..<h {
            for sx in 0..<w {
                let start = sy * w + sx
                if visited[start] || brightness(sx, sy) <= Double(threshold) { continue }
                visited[start] = true
                queue.removeAll(keepingCapacity: true)
                queue.append((sx, sy))
                var sumX = 0.0, sumY = 0.0, sumW = 0.0, count = 0
                var head = 0
                while head < queue.count {
                    let (x, y) = queue[head]; head += 1
                    let b = brightness(x, y)
                    sumX += Double(x) * b; sumY += Double(y) * b; sumW += b
                    count += 1
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        let index = ny * w + nx
                        if !visited[index], brightness(nx, ny) > Double(threshold) {
                            visited[index] = true
                            queue.append((nx, ny))
                        }
                    }
                }
                guard sumW > 0, count >= 2 else { continue }
                out.append((sumX / sumW, sumY / sumW, sumW))
            }
        }
        return out
    }

    // MARK: - one combination

    private func edit(for angle: Angle, crop: Crop) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = angle.straighten
        edit.geometry.quarterTurns = angle.quarterTurns
        edit.geometry.crop = crop.rect.normalizedRect
        return edit
    }

    private func measure(angle: Angle, crop: Crop, zoom: Zoom, rung: Rung,
                         markers: [(x: Double, y: Double)],
                         graph: RenderGraph) throws -> [Violation] {
        let edit = edit(for: angle, crop: crop)
        let state = zoom.state
        let walk = GeometryWalk(edit: edit, source: Self.source, rung: rung,
                                viewport: Self.viewport, state: state)
        let cg = walk.geometry
        let ds = rung.scale
        let options = RenderOptions(
            canvas: Self.viewport,
            scale: walk.framing.renderScale(of: state, decodeScale: ds),
            outputWindow: walk.framing.outputWindow(of: state, decodeScale: ds),
            useCache: false,
            wantsPixels: true,
            neverUpscalesContent: true)
        let result = try graph.render(edit, options: options)
        let display = try XCTUnwrap(result.display, "\(angle) \(crop) \(zoom) \(rung): no pixels")
        var violations: [Violation] = []

        // ① the rendered markers against S1 → S3 → S5.
        let blobs = self.blobs(in: display)
        var measured = 0
        var worstRender: (dx: Double, dy: Double, detail: String)?
        for marker in markers {
            let f = walk.frameNormalized(sourceX: marker.x, sourceY: marker.y)
            guard f.x > 0.055, f.x < 0.945, f.y > 0.055, f.y < 0.945 else { continue }
            guard marker.x > 0.02, marker.x < 0.98 else { continue }
            guard marker.y > 0.02, marker.y < 0.98 else { continue }
            let expected = walk.view(sourceX: marker.x * Double(cg.source.width),
                                     sourceY: marker.y * Double(cg.source.height))
            // Keep the whole marker block inside the viewport: a clipped block has a biased centroid,
            // which would be measured as a transform error.
            guard expected.x > 30, expected.x < Double(Self.viewport.width) - 30,
                  expected.y > 30, expected.y < Double(Self.viewport.height) - 30 else { continue }
            guard let blob = blobs.min(by: {
                hypot($0.x - expected.x, $0.y - expected.y)
                    < hypot($1.x - expected.x, $1.y - expected.y)
            }) else { continue }
            let distance = hypot(blob.x + 0.5 - expected.x, blob.y + 0.5 - expected.y)
            guard distance < 12 else { continue }
            measured += 1
            let dx = blob.x + 0.5 - expected.x, dy = blob.y + 0.5 - expected.y
            if abs(dx) > Self.tolerance || abs(dy) > Self.tolerance {
                if worstRender == nil
                    || hypot(dx, dy) > hypot(worstRender!.dx, worstRender!.dy) {
                    worstRender = (dx, dy, String(format: "marker (%.2f,%.2f)", marker.x, marker.y))
                }
            }
        }
        if let worst = worstRender {
            violations.append(Violation(check: "①渲染帧", dx: worst.dx, dy: worst.dy,
                                        detail: "\(measured) 个标记 · \(worst.detail)"))
        }

        // ② the crop overlay's four corners against S2 → S5.
        let layout = CropTool.layout(crop: edit.geometry.renderCrop(source: Self.source),
                                     source: cg.source,
                                     mapping: walk.mapping,
                                     pointScale: 1,
                                     showsGrid: false,
                                     quadRotationDegrees: 0)
        let frameCorners = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                            NormalizedPoint(1, 1), NormalizedPoint(0, 1)]
        for (index, corner) in frameCorners.enumerated() {
            let expected = walk.view(frameX: corner.x * walk.frameExtent.width,
                                     frameY: corner.y * walk.frameExtent.height)
            let got = layout.corners[index]
            let dx = Double(got.x) - expected.x, dy = Double(got.y) - expected.y
            if abs(dx) > Self.tolerance || abs(dy) > Self.tolerance {
                violations.append(Violation(check: "②叠层", dx: dx, dy: dy,
                                            detail: "corner \(index)"))
            }
        }

        // ③ hit-testing: the product's view→S1 against the two-step S5→S3→S1.
        let points: [(Double, Double)] = [
            (Double(Self.viewport.width) / 2, Double(Self.viewport.height) / 2),
            (8, 8),
            (Double(Self.viewport.width) - 8, 8),
            (8, Double(Self.viewport.height) - 8),
            (Double(Self.viewport.width) - 8, Double(Self.viewport.height) - 8),
        ]
        for (index, p) in points.enumerated() {
            let got = walk.mapping.sourcePoint(viewX: p.0, viewY: p.1)
            let expected = walk.source(viewX: p.0, viewY: p.1)
            if angle.name == "1°" && crop.name == "全幅" && zoom.name == "100%" && index == 2 {
                print("[260-debug1] got \(got) expected \(expected) window \(walk.s3Window)"
                      + " scale \(walk.canvasPerSource) cropLeft \(walk.mapping.cropLeft)")
            }
            let dx = got.x - expected.x, dy = got.y - expected.y
            if abs(dx) > Self.tolerance || abs(dy) > Self.tolerance {
                let label = "point \(index) (\(Int(p.0)),\(Int(p.1)))"
                violations.append(Violation(check: "③命中", dx: dx, dy: dy, detail: label))
            }
        }
        return violations
    }

    // MARK: - the matrix

    private func runMatrix(_ rung: Rung) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let plain = markedFixture(quarterTurns: 0, rung: rung)
        let graph = try RenderGraph(input: RenderInput(image: plain.image,
                                                       identity: "frame-matrix-\(rung)"))
        let turned = markedFixture(quarterTurns: 1, rung: rung)
        let turnGraph = try RenderGraph(input: RenderInput(image: turned.image,
                                                           identity: "frame-matrix-\(rung)-t1"))
        let started = Date()
        var results: [Result] = []
        for angle in Angle.all {
            // One graph per quarter turn as well: the marker grid is painted in the *upright* source,
            // so a 90° document needs the same pixels turned into S1.
            let fixture = angle.quarterTurns == 0 ? plain : turned
            let activeGraph = angle.quarterTurns == 0 ? graph : turnGraph
            for crop in Crop.all {
                for zoom in Zoom.all {
                    let violations = try measure(angle: angle, crop: crop, zoom: zoom,
                                                 rung: rung, markers: fixture.markers,
                                                 graph: activeGraph)
                    results.append(Result(angle: angle, crop: crop, zoom: zoom,
                                          rung: rung, violations: violations))
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        var failing = 0
        var measured = 0
        for result in results where !result.violations.isEmpty {
            // Only ② is asserted in this commit. ① and ③ are **measured and printed** — the numbers
            // are the deliverable of this lane (the spec's table), and their assertion waits for the
            // follow-up round that settles the bilinear-centroid noise floor at 0.1°/1° and the 45°
            // S3 scale. Printing them instead of skipping them is the spec's "no silent skip".
            for violation in result.violations {
                let centralized = violation.check.hasPrefix("②")
                if centralized {
                    failing += 1
                    print("[260] ✗ \(result.angle) / \(result.crop) / \(result.zoom)"
                          + " / rung \(result.rung) · \(violation)")
                } else {
                    measured += 1
                    print("[260] ○ \(result.angle) / \(result.crop) / \(result.zoom)"
                          + " / rung \(result.rung) · \(violation)")
                }
            }
        }
        print(String(format: "[260] rung %.2g · %d combos · %d asserted-failing · %d measured-over-tolerance · %.2f s (%.1f ms/combo)",
                     rung.scale, results.count, failing, measured, elapsed,
                     elapsed * 1000 / Double(max(results.count, 1))))
        XCTAssertEqual(failing, 0,
                       "260: the S2 → S5 overlay deviates by more than \(Self.tolerance) px in "
                       + "\(failing) places at rung \(rung); see the [260] ✗ rows above")
    }

    func testMatrixRungQuarter() throws { try runMatrix(Rung.all[0]) }
    func testMatrixRungHalf() throws { try runMatrix(Rung.all[1]) }
    func testMatrixRungFull() throws { try runMatrix(Rung.all[2]) }

    // MARK: - 231's rung-size lesion, kept inside the matrix

    /// The rung dimension must be **invisible to S1**. `publishIngestedSource` is the one writer of
    /// `CatalogSession.ingestedSourceFrame`, and 231's bug was publishing the rung buffer's size
    /// there while `framing()` divides by `decodeScale`. The matrix's S1 is the full file at every
    /// rung; this test drives the shipped publication through its seam so a regression is red here
    /// even if the pixel walk happens to be insensitive at one zoom.
    @MainActor
    func testPublishedIngestedSourceIsRungIndependent() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-frame-matrix-260-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let source = ImageSize(width: 1200, height: 800)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: source.width,
                                                             height: source.height)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        for rung in Rung.all {
            let buffer = ImageSize(width: Int((Double(source.width) * rung.scale).rounded()),
                                   height: Int((Double(source.height) * rung.scale).rounded()))
            loupe.publishIngestedSourceForTesting(rung: buffer, decodeScale: rung.scale)
            XCTAssertEqual(session.maskSourceSize, source,
                           "231: rung \(rung) published the buffer's size, not the full file")
            XCTAssertEqual(loupe.cropSourceSize, source,
                           "231: the crop tool's S1 frame changed with the rung")
            XCTAssertEqual(LoupeController.fullSourceSize(rung: buffer, decodeScale: rung.scale),
                           source, "the rung → source division")
        }
    }
}
