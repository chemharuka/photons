import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 260 — the transform-chain guard matrix; 268 — ① is measured in **source** pixels;
/// 274 — the fifth dimension is **flip** (`none / H / V / HV`), at every rung.
///
/// This suite is a **measurement**, not a fix: it renders every combination of the five dimensions
/// (straighten × crop × zoom × decode rung × flip) and asserts three independent walks through the
/// same document agree:
///
///   1. **render** — the markers actually drawn in the frame are where S1 → S3 (`CropGeometry`) →
///      S5 (`LoupeMapping`) puts them. The gate is **half a source pixel** of the rung the renderer
///      decoded, converted to S5 by the current projection (`0.5 × canvasPerSource / decodeScale`),
///      because the canvas and window are integers (D1) and the picture may therefore sit half its
///      own pixel off the continuous projection. The tolerance is printed per group;
///   2. **overlay** — the crop frame the crop tool lays out is the same S2 → S5 rectangle (0.5 S5 px);
///   3. **hit test** — `LoupeMapping.sourcePoint` agrees with S5 → S3 → S1 walked step by step
///      (0.5 S5 px).
///
/// 268 also recomputes `plan`'s integer phase (`round`, `ceil`, the truncated `(baseline − frame)/2`
/// and the letterbox `(canvas − content)/2`) and asserts the measured offset equals it within
/// 0.05 source px, so the ① residual is shown to be integer allocation rather than a mapping error.
///
/// The point of the table is to name the scale factor that is off, not to bless the current numbers.
/// The three historical lesions (`frameOrigin` letterbox double-add, rung-size mix-up, a second crop
/// ratio) are reproduced in `local/REPORT.md`, each with the matrix's failing output.
///
/// 274 — the **coverage matrix** is explicit and is not reduced for speed:
///
///     5 angles × 4 crops × 3 zooms × 3 rungs × 4 flips = 720 combinations
///     (240 per rung; every flip state is exercised at 0.25, 0.5 and 1.0)
///
/// The flip dimension exists because a flip/turn order mix-up is invisible to the 180-combination
/// matrix: a flip commutes with a zero turn, so only `flip × angle ≠ 0` can see it. The **expected
/// side of the flip** is derived by a second, hand-written geometry (see
/// `GeometryWalk.view(sourceX:sourceY:)` and `PlanPhase.view`), never by calling the product's
/// `sourceToView` / `FrameTransform`; otherwise the gate would be a tautology.
///
/// **274 measured the order, and it is `turn → flip` (not `flip → turn`).** A single asymmetric
/// marker rendered at 45° with `flip H` lands on the hand-computed `F(R(θ)·p)` position within
/// 0.69 S5 px; the `R(θ)·F(p)` spelling is 112.91 S5 px away. The kernel's inverse walk
/// (`s0_geometry.metal`: mirror the photo sample, then rotate by `−θ`) has that forward order.
/// `FrameTransform`'s `toFrame · turn · flip` therefore hit-tests the mirror of the picture: this
/// suite's ① (render) gate is **green**, ③ (hit test) is **red** for every `flip × angle ≠ 0`
/// combination until the product is corrected. That is a finding for the main line, not something
/// this test-only lane may paper over by flipping the expectation back.
///
/// Perspective is **not** an assertion dimension here: 246 ("先透视→再旋转→再算画布 AABB") is on
/// `main` but is not an ancestor of this worktree's HEAD, so the matrix measures the identity
/// keystone only. `testPerspectiveFlipRecordsKnownDifference` records (does not assert) the
/// perspective + flip combination, which waits for the "kernel 透视路径统一到 S1/S3" task to land.
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

    /// 274 — the fifth dimension. `H` and `V` are mirrors of the **photograph** about its own centre
    /// in S1 source pixels; `HV` is both. The names are the UI's (horizontal / vertical flip).
    private struct Flip: CustomStringConvertible {
        let name: String
        let horizontal: Bool
        let vertical: Bool
        var description: String { name }
        static let all: [Flip] = [
            Flip(name: "none", horizontal: false, vertical: false),
            Flip(name: "H", horizontal: true, vertical: false),
            Flip(name: "V", horizontal: false, vertical: true),
            Flip(name: "HV", horizontal: true, vertical: true),
        ]
    }

    // MARK: the fixture

    /// A 4:3 upright source. Large enough that a 25 % rung keeps markers apart, small enough that the
    /// whole matrix (720 renders at three rungs) stays a seconds-scale probe rather than a benchmark.
    private static let source = ImageSize(width: 640, height: 480)
    private static let viewport = ImageSize(width: 320, height: 240)
    private static let tolerance = 0.5

    /// Diagnostics go to stderr: XCTest's own failure lines do too, so `swift test` output keeps the
    /// per-group table in order instead of losing a buffered stdout chunk on exit.
    private func note(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

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
        let flip: Flip
        let violations: [Violation]
        /// 274 reporting — the worst ① gate residual of the group, in S5 px (the number the gate
        /// compares with `0.5 × ratio`), and the worst single marker (`|measured − plan|` in S1 px).
        let meanResidualS5: Double
        let maxMarkerResidualSource: Double
    }

    // MARK: - the three consistency walks

    private struct GeometryWalk {
        let geometry: CropGeometry
        let framing: LoupeFraming
        let mapping: LoupeMapping
        let state: LoupeViewState
        let decodeScale: Double
        let flip: Flip
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
             viewport: ImageSize, state: LoupeViewState, flip: Flip) {
            let decoded = ImageSize(width: max(1, Int((Double(source.width) * rung.scale).rounded())),
                                    height: max(1, Int((Double(source.height) * rung.scale).rounded())))
            self.geometry = CropGeometry(geometry: edit.geometry, source: source)
            self.framing = LoupeFraming(viewport: viewport, decoded: decoded,
                                        decodeScale: rung.scale, edit: edit)
            self.mapping = framing.mapping(of: state)
            self.state = state
            self.decodeScale = rung.scale
            self.flip = flip
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

        /// S1 source pixel → crop-normalized, **without** the turn but with the photo-space flip.
        /// Used only as the "is this marker safely inside the kept picture" guard.
        ///
        /// The kernel clips on the sampled *source* position (`cropped`, after the un-turn and after
        /// the photo mirror), so the visible source region is `flip⁻¹(crop)` — the crop rect for an
        /// unflipped document, the mirrored rect otherwise. Checking the *turned* position (the first
        /// reading of the shader) lets edge markers through and biases ① at 45°; ignoring the mirror
        /// does the same at 90° + an off-centre crop. At every angle in this matrix the document has
        /// no keystone, so the perspective stage is the identity.
        func cropNormalized(sourceX x: Double, sourceY y: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let w = Double(cg.source.width), h = Double(cg.source.height)
            let crop = cg.crop
            var x = x, y = y
            if flip.horizontal { x = w - x }
            if flip.vertical { y = h - y }
            return ((x - crop.left * w) / max(crop.width * w, 1e-9),
                    (y - crop.top * h) / max(crop.height * h, 1e-9))
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

        /// The kernel's pivot: the **photograph's** centre, in turned source pixels (273 / 248).
        private var photoCentre: (x: Double, y: Double) {
            (Double(geometry.source.width) / 2, Double(geometry.source.height) / 2)
        }

        /// The photo centre in the crop frame's own pixels (`P − cropOrigin`).
        private var photoCentreInFrame: (x: Double, y: Double) {
            let p = photoCentre, o = geometry.frameOriginInPhoto
            return (p.x - o.x, p.y - o.y)
        }

        /// The picture's place in the canvas: `inset + A + R(θ)(source − P)`, the walk S0 executes.
        ///
        /// 286 / 294 — re-derived here from 279's geometry, not read out of the product: the
        /// hit-test inverse must not call the same continuous origin the overlay/renderer use.
        private var independentCanvasInset: (x: Double, y: Double) {
            let cg = geometry
            if cg.perspective?.hasWarp == true { return (0, 0) }
            let degrees = cg.rotationDegrees
            let quarter = degrees / 90
            guard degrees.isFinite, abs(quarter - quarter.rounded()) >= 1e-9 else { return (0, 0) }
            let frame = cg.frameSize
            let extent = PlanPhase.rotatedExtent(width: Double(frame.width),
                                                 height: Double(frame.height),
                                                 degrees: degrees)
            let w = Double(cg.source.width), h = Double(cg.source.height)
            var dx = cg.crop.centerX * w - w / 2
            var dy = cg.crop.centerY * h - h / 2
            // 274 — the pivot is the crop offset about the photograph's centre, mirrored first
            // (kernel order: flip, then turn).
            if cg.flipHorizontal { dx = -dx }
            if cg.flipVertical { dy = -dy }
            if dx == 0 && dy == 0 {
                return ((Double(canvasPixels(extent.width)) - Double(frame.width)) / 2,
                        (Double(canvasPixels(extent.height)) - Double(frame.height)) / 2)
            }
            let radians = degrees * .pi / 180
            let c = cos(radians), s = sin(radians)
            let turned = (x: dx * c - dy * s, y: dx * s + dy * c)
            return (dx - turned.x + (extent.width - Double(frame.width)) / 2,
                    dy - turned.y + (extent.height - Double(frame.height)) / 2)
        }

        /// The one `ceil` the canvas uses, written here rather than borrowed.
        private func canvasPixels(_ value: Double) -> Int {
            max(1, Int((value - 1e-9).rounded(.up)))
        }

        /// S1 source pixel → S5 device pixel, the **prediction** that picks the nearest rendered blob.
        ///
        /// 274 — this is the **second geometry**, written out by hand from the kernel's order so a
        /// flip/turn mix-up cannot hide behind the product's own composition:
        ///
        ///     q  = P + R(θ)·(p − P)                    // turn about the photograph centre
        ///     S2 = flip(q, photograph centre) − cropOrigin   // then mirror about the same centre
        ///     S3 = inset + S2                          // rotate/crop AABB (integer inset)
        ///
        /// `s0_geometry.metal` walks canvas → source as `R(−θ)(flip(frame))`; inverting that is
        /// `flip(R(θ)(source))`, i.e. turn first. (Reading the shader's two statements in source
        /// order gives the opposite answer — 273's 50.1 px probe at 7.5° was that misreading.)
        ///
        /// Nothing here calls `sourceToView`, `FrameTransform`, `CropGeometry.canvasPoint` or
        /// `LoupeMapping.sourcePoint`. Only the crop rect, the source size and the S3→S5 letterbox
        /// (which is not the thing under test) are shared with the product. At θ = 0 a flip commutes
        /// with the turn, which is exactly why the 180-combination matrix could not see the order.
        ///
        /// This stays the continuous walk: ① is measured as `measured − plan` (PlanPhase), so the
        /// prediction only has to be close enough to find the blob. Keeping it independent of the
        /// pivot under test also keeps a 45° corner crop from selecting blobs that the photograph's
        /// edge has already clipped (their centroid is biased, not the mapping).
        func view(sourceX x: Double, sourceY y: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let w = Double(cg.source.width), h = Double(cg.source.height)
            let crop = cg.crop

            // 1. Turn about the photograph centre. +θ is clockwise in y-down pixel coordinates.
            let theta = cg.rotationDegrees * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            let dx = x - w / 2, dy = y - h / 2
            var turnedX = w / 2 + dx * cosT - dy * sinT
            var turnedY = h / 2 + dx * sinT + dy * cosT

            // 2. Photo-space mirror about the photograph's own centre (kernel: `1 − photo.x`).
            if flip.horizontal { turnedX = w - turnedX }
            if flip.vertical { turnedY = h - turnedY }

            // 3. Crop → frame pixels, then the 279 AABB inset into S3. The inset is the renderer's
            //    own painted origin (independently re-derived), not the frame-centred half margin:
            //    with an off-centre crop the two differ by `(I − R)·(cropCentre − photoCentre)`,
            //    which is exactly the 279 correction. The *flip/turn order* above stays hand-written
            //    so it cannot hide behind the product's composition.
            let cropX = crop.left * w, cropY = crop.top * h
            let inset = independentCanvasInset
            let s3 = (x: inset.x + turnedX - cropX, y: inset.y + turnedY - cropY)
            return view(canvasX: s3.x, canvasY: s3.y)
        }

        /// S5 device pixel → S1 source pixel, the two-step inverse (S5→S3, then S3→S1).
        ///
        /// 274 — the inverse of `F·R` is `R⁻¹·F⁻¹`: mirror about the photo centre **first**, then
        /// un-turn about the same centre. Written by hand, like the forward walk above.
        func source(viewX x: Double, viewY y: Double) -> (x: Double, y: Double) {
            let cg = geometry
            let s3 = canvas(viewX: x, viewY: y)
            let p = photoCentre
            let a = photoCentreInFrame
            let inset = independentCanvasInset
            let ux = s3.x - inset.x - a.x
            let uy = s3.y - inset.y - a.y
            var sx = ux + p.x, sy = uy + p.y
            if flip.horizontal { sx = Double(cg.source.width) - sx }
            if flip.vertical { sy = Double(cg.source.height) - sy }
            let r = cg.rotation.invert(x: sx - p.x, y: sy - p.y)
            return (r.0 + p.x, r.1 + p.y)
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
        // A smooth Gaussian bump rather than a hard-edged square: the renderer resamples with a 2×2
        // bilinear kernel, and a hard edge under a sub-degree rotation biases the measured centroid
        // by ~0.1 source px (which would show up as a transform error). A band-limited marker keeps
        // the centroid of a linear resample equal to the transformed centre.
        let sigma = Double(radius) / 2
        let reach = max(2, Int((3 * sigma).rounded(.up)))
        let inverseTwoSigmaSquared = 1 / (2 * sigma * sigma)
        let inverseTurns = (4 - (quarterTurns % 4 + 4) % 4) % 4
        var centres: [(x: Double, y: Double)] = []
        for marker in Self.markers {
            let upright = CropMath.turned(NormalizedPoint(marker.x, marker.y),
                                          quarterTurns: inverseTurns)
            let cx = Int((upright.x * Double(width)).rounded())
            let cy = Int((upright.y * Double(height)).rounded())
            for y in max(0, cy - reach)...min(height - 1, cy + reach) {
                for x in max(0, cx - reach)...min(width - 1, cx + reach) {
                    let ddx = Double(x - cx), ddy = Double(y - cy)
                    let value = Float16(exp(-(ddx * ddx + ddy * ddy) * inverseTwoSigmaSquared))
                    guard value > 0.02 else { continue }
                    let o = (y * width + x) * 4
                    rgba[o] = value; rgba[o + 1] = value; rgba[o + 2] = value; rgba[o + 3] = 1
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
                    // Weight by the amount above the connectivity threshold: the boundary pixels
                    // (b ≈ threshold) carry the pixel-grid phase noise, the interior does not.
                    let weight = max(0, b - Double(threshold))
                    sumX += Double(x) * weight; sumY += Double(y) * weight; sumW += weight
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

    private func edit(for angle: Angle, crop: Crop, flip: Flip) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = angle.straighten
        edit.geometry.quarterTurns = angle.quarterTurns
        edit.geometry.crop = crop.rect.normalizedRect
        edit.geometry.flipHorizontal = flip.horizontal
        edit.geometry.flipVertical = flip.vertical
        return edit
    }

    private struct PlanPhase {
        let decodedOriented: ImageSize
        let cropOrigin: (x: Double, y: Double)
        let cropSpan: (x: Double, y: Double)
        /// The picture's own grid as S0 walks it, in content pixels (`frameSize` in the plan).
        let frameContent: (width: Double, height: Double)
        /// The integer letterbox `(canvas − content)/2`.
        let origin: (x: Double, y: Double)
        /// `plan.frameOrigin` — `windowOrigin − inset`, the same value S0 is handed.
        let frameOrigin: (x: Double, y: Double)
        let cosine: Double
        let sine: Double
        let hasAngle: Bool
        /// 274 — the kernel's mirror, in **photograph** space (before the turn).
        let flipHorizontal: Bool
        let flipVertical: Bool

        /// The test's own `|w·cos| + |h·sin|` — the formula is written here so the expected origin
        /// cannot borrow the product's copy of it.
        static func rotatedExtent(width: Double, height: Double,
                                  degrees: Double) -> (width: Double, height: Double) {
            guard degrees.isFinite, degrees != 0 else { return (width, height) }
            let quarter = degrees / 90
            if abs(quarter - quarter.rounded()) < 1e-9 {
                return Int(quarter.rounded()) % 2 != 0
                    ? (height, width) : (width, height)
            }
            let radians = degrees * .pi / 180
            let c = abs(cos(radians)), s = abs(sin(radians))
            return (width * c + height * s, width * s + height * c)
        }

        init(edit: EditModel, decoded: ImageSize, scale: Double, viewport: ImageSize,
             result: RenderResult) {
            let oriented = edit.geometry.orientedSource(decoded)
            let crop = edit.geometry.renderCrop(source: decoded)
            self.decodedOriented = oriented
            self.flipHorizontal = edit.geometry.flipHorizontal
            self.flipVertical = edit.geometry.flipVertical
            self.cropOrigin = (crop.left * Double(oriented.width),
                               crop.top * Double(oriented.height))
            self.cropSpan = (crop.width * Double(oriented.width),
                             crop.height * Double(oriented.height))
            // Recompute `plan`'s integer walk, one rounding at a time:
            //   frame    = round(cropPixels · scale)
            //   baseline = round(ceil(canvasExtent) · scale)      (only with an angle)
            //   inset    = turned crop AABB origin               (279; integer, snapped)
            //              a centred crop keeps (baseline − frame) / 2, truncated
            //   origin   = (canvas − content) / 2                 (integer, truncated)
            let cropPixels = CropMath.frameSize(crop, in: oriented, allowsOutsideSource: true)
            let frameW = max(1, Int((Double(cropPixels.width) * scale).rounded()))
            let frameH = max(1, Int((Double(cropPixels.height) * scale).rounded()))
            let straighten = edit.geometry.straightenDegrees
            let expanded = straighten != 0
                ? CropMath.canvasSize(crop: crop, in: decoded,
                                      straightenDegrees: straighten,
                                      quarterTurns: edit.geometry.quarterTurns,
                                      allowsOutsideSource: true)
                : nil
            let baselineW = expanded.map {
                max(1, Int((Double($0.width) * scale).rounded()))
            } ?? frameW
            let baselineH = expanded.map {
                max(1, Int((Double($0.height) * scale).rounded()))
            } ?? frameH
            // `plan`'s content is the rounded continuous content; `requested` is what the window
            // asked for. Their ratio is the letterbox squeeze `k` applied to `frameSize`. 274 —
            // `requested` is re-derived here (`outputWindow` when windowed, otherwise the rounded
            // canvas) rather than asked of `FrameTransform`, so this walk never calls the product
            // geometry it is guarding.
            let requestedW = result.outputWindow?.width ?? baselineW
            let requestedH = result.outputWindow?.height ?? baselineH
            let kx = Double(result.content.width) / Double(max(requestedW, 1))
            let ky = Double(result.content.height) / Double(max(requestedH, 1))
            self.frameContent = (Double(frameW) * kx, Double(frameH) * ky)
            self.origin = (Double((viewport.width - result.content.width) / 2),
                           Double((viewport.height - result.content.height) / 2))
            let windowOrigin = (x: Double(result.outputWindow?.x ?? 0) * kx,
                                y: Double(result.outputWindow?.y ?? 0) * ky)
            // 286 / 294 — re-derive the 279 origin **inside the test**, never from the plan:
            //
            //     frame    = round(cropPixels · scale)
            //     extent   = |w·cos| + |h·sin| by |w·sin| + |h·cos|   (unscaled frame: the
            //                renderer rotates first and snaps the origin once, so scaling the
            //                continuous extent is the number `plan` actually rounds)
            //     pivot    = flip(cropCentre − photoCentre) · source
            //     origin   = (I − R)·pivot + (extent − frame)/2
            //
            // A centred crop is the historical integer half difference; a right angle is (0, 0).
            // No `FrameTransform`, no `CropGeometry`, no `plan.frameOrigin` enters this value.
            let centred = abs(crop.centerX - 0.5) < 1e-12
                && abs(crop.centerY - 0.5) < 1e-12
            let inset: (x: Double, y: Double)
            if expanded == nil {
                inset = (0, 0)
            } else if centred {
                inset = (Double((baselineW - frameW) / 2),
                         Double((baselineH - frameH) / 2))
            } else {
                let extent = Self.rotatedExtent(width: Double(cropPixels.width),
                                                height: Double(cropPixels.height),
                                                degrees: straighten)
                let photoCentre = (x: Double(oriented.width) / 2,
                                   y: Double(oriented.height) / 2)
                var pivot = (x: crop.centerX * Double(oriented.width) - photoCentre.x,
                             y: crop.centerY * Double(oriented.height) - photoCentre.y)
                // 274 — a flip mirrors the crop offset about the photograph's centre first
                // (kernel order: flip, then turn).
                if flipHorizontal { pivot.x = -pivot.x }
                if flipVertical { pivot.y = -pivot.y }
                let radians = straighten * .pi / 180
                let c = cos(radians), s = sin(radians)
                let turned = (x: pivot.x * c - pivot.y * s,
                              y: pivot.x * s + pivot.y * c)
                let continuous = (
                    x: pivot.x - turned.x
                        + (extent.width - Double(cropPixels.width)) / 2,
                    y: pivot.y - turned.y
                        + (extent.height - Double(cropPixels.height)) / 2)
                inset = ((continuous.x * scale).rounded(),
                         (continuous.y * scale).rounded())
            }
            self.frameOrigin = (windowOrigin.x - inset.x * kx,
                                windowOrigin.y - inset.y * ky)
            let theta = straighten * .pi / 180
            self.cosine = cos(theta)
            self.sine = sin(theta)
            let quarter = straighten / 90
            self.hasAngle = straighten.isFinite
                && abs(quarter - quarter.rounded()) >= 1e-9
        }

        /// Where `plan` + `s0_geometry` put a point of the turned decoded source, in S5.
        /// This is the **integer** walk the renderer actually executes.
        func view(sourceX x: Double, sourceY y: Double) -> (x: Double, y: Double) {
            var p = (x * Double(decodedOriented.width), y * Double(decodedOriented.height))
            // 274 — the kernel's forward order is turn, then mirror. `s0_geometry.metal` samples
            // `R(−θ)(flip(frame))`, whose inverse is `flip(R(θ)(source))`; its own source order
            // (flip statement, then rotate statement) is the *inverse* walk and reads backwards.
            // This is deliberately not the product's `toFrame · turn · flip` assembly.
            if hasAngle {
                let cx = Double(decodedOriented.width) / 2, cy = Double(decodedOriented.height) / 2
                let ox = p.0 - cx, oy = p.1 - cy
                p = (ox * cosine - oy * sine + cx, ox * sine + oy * cosine + cy)
            }
            if flipHorizontal { p.0 = Double(decodedOriented.width) - p.0 }
            if flipVertical { p.1 = Double(decodedOriented.height) - p.1 }
            let photo: (x: Double, y: Double) = p
            let fx = (photo.x - cropOrigin.x) * frameContent.width / max(cropSpan.x, 1e-9)
            let fy = (photo.y - cropOrigin.y) * frameContent.height / max(cropSpan.y, 1e-9)
            return (origin.x + fx - frameOrigin.x, origin.y + fy - frameOrigin.y)
        }
    }

    private func measure(angle: Angle, crop: Crop, zoom: Zoom, rung: Rung, flip: Flip,
                         markers: [(x: Double, y: Double)],
                         graph: RenderGraph) throws
        -> (violations: [Violation], meanResidualS5: Double, maxMarkerResidualSource: Double) {
        let edit = edit(for: angle, crop: crop, flip: flip)
        let state = zoom.state
        let walk = GeometryWalk(edit: edit, source: Self.source, rung: rung,
                                viewport: Self.viewport, state: state, flip: flip)
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
        let decodedRaw = ImageSize(
            width: max(1, Int((Double(Self.source.width) * ds).rounded())),
            height: max(1, Int((Double(Self.source.height) * ds).rounded())))
        let phase = PlanPhase(edit: edit, decoded: decodedRaw,
                              scale: walk.framing.renderScale(of: state, decodeScale: ds),
                              viewport: Self.viewport, result: result)

        // ① the rendered markers against S1 → S3 → S5.
        //
        // 268 — the tolerance is a **source-pixel** one, not an S5 one. The renderer's canvas and
        // window are integers (D1), so the picture may sit up to half a pixel of its own grid away
        // from the continuous projection; at 200 % of a 25 % rung that half pixel is 4 S5 px.
        // `ratio` is S5 px per decoded (rung S1) px, computed from the current projection, and the
        // gate allows half of one decoded pixel: `0.5 × ratio` S5 px.
        let ratio = walk.canvasPerSource / max(rung.scale, 1e-9)
        let tolerance = 0.5 * ratio
        let blobs = self.blobs(in: display)
        var measured = 0
        var sumRaw = (x: 0.0, y: 0.0)
        var sumPhase = (x: 0.0, y: 0.0)
        var sumCorrected = (x: 0.0, y: 0.0)
        var sumCorrectedSquared = 0.0
        var maxMarkerResidualSource = 0.0
        let markerRadius = 0.03 * Double(min(decodedRaw.width, decodedRaw.height))
        // the Gaussian's visible tail is 3σ = 1.5 · radius: a marker whose *centre* is inside the
        // crop can still have its outer tail cut by the 279 crop clip (the rotating, unflipped
        // instantiation), which biases the centroid. Guard the whole tail, not just the centre.
        let cropGuardX = markerRadius * 1.5 / max(phase.cropSpan.x, 1e-9) + 0.01
        let cropGuardY = markerRadius * 1.5 / max(phase.cropSpan.y, 1e-9) + 0.01
        // The Gaussian's visible tail is 3σ = 1.5 · radius (in decoded pixels); scaling that to S5
        // keeps the *whole* block inside the viewport, so an edge-clipped tail cannot bias the
        // centroid by the 0.05 source px the plan-corroboration check asks for.
        let viewMargin = max(30.0, markerRadius * 1.5 * ratio + 4)
        for marker in markers {
            // The guard is computed with the same independent flip+turn (274), not the product's
            // `CropGeometry` — a marker near the crop edge has a biased centroid and must be skipped
            // on the side it actually appears after the mirror.
            let f = walk.cropNormalized(sourceX: marker.x * Double(cg.source.width),
                                        sourceY: marker.y * Double(cg.source.height))
            guard f.x > cropGuardX, f.x < 1 - cropGuardX,
                  f.y > cropGuardY, f.y < 1 - cropGuardY else { continue }
            guard marker.x > 0.02, marker.x < 0.98 else { continue }
            guard marker.y > 0.02, marker.y < 0.98 else { continue }
            let expected = walk.view(sourceX: marker.x * Double(cg.source.width),
                                     sourceY: marker.y * Double(cg.source.height))
            // Keep the whole marker block inside what the renderer actually draws: a clipped block
            // has a biased centroid, which would be measured as a transform error. That surface is
            // the **content** rect (the picture/canvas at fit, the camera window at zoom), clipped
            // to the viewport — not the viewport alone, whose letterbox can hide the content's edge.
            let contentLeft = walk.mapping.originX
            let contentTop = walk.mapping.originY
            let contentRight = contentLeft + walk.mapping.contentWidth
            let contentBottom = contentTop + walk.mapping.contentHeight
            let safeLeft = max(0, contentLeft) + viewMargin
            let safeTop = max(0, contentTop) + viewMargin
            let safeRight = min(Double(Self.viewport.width), contentRight) - viewMargin
            let safeBottom = min(Double(Self.viewport.height), contentBottom) - viewMargin
            guard expected.x > safeLeft, expected.x < safeRight,
                  expected.y > safeTop, expected.y < safeBottom
            else { continue }
            guard let blob = blobs.min(by: {
                hypot($0.x - expected.x, $0.y - expected.y)
                    < hypot($1.x - expected.x, $1.y - expected.y)
            }) else { continue }
            let measuredX = blob.x + 0.5, measuredY = blob.y + 0.5
            let distance = hypot(measuredX - expected.x, measuredY - expected.y)
            guard distance < 12 else { continue }
            measured += 1
            // The plan's own integer walk — recomputed above from `ceil`/`round`/integer division —
            // is where the renderer actually puts the picture.
            let plan = phase.view(sourceX: marker.x, sourceY: marker.y)
            sumRaw.x += measuredX - expected.x
            sumRaw.y += measuredY - expected.y
            sumPhase.x += plan.x - expected.x
            sumPhase.y += plan.y - expected.y
            sumCorrected.x += measuredX - plan.x
            sumCorrected.y += measuredY - plan.y
            sumCorrectedSquared += pow(measuredX - plan.x, 2) + pow(measuredY - plan.y, 2)
            maxMarkerResidualSource = max(maxMarkerResidualSource,
                                          max(abs(measuredX - plan.x),
                                              abs(measuredY - plan.y)) / max(ratio, 1e-9))
        }
        var meanResidualS5 = 0.0
        if measured > 0 {
            let n = Double(measured)
            let meanRaw = (x: sumRaw.x / n, y: sumRaw.y / n)
            let meanPhase = (x: sumPhase.x / n, y: sumPhase.y / n)
            let meanCorrected = (x: sumCorrected.x / n, y: sumCorrected.y / n)
            let rmsCorrected = sqrt(sumCorrectedSquared / n) / ratio
            meanResidualS5 = max(abs(meanCorrected.x), abs(meanCorrected.y))
            note(String(format: "[268] %@ / %@ / %@ / rung %@ / flip %@"
                          + " · 容差 = 0.5 × ratio %.4f = %.4f px"
                          + " · 实测相位 (%+.4f,%+.4f) src px · plan 相位 (%+.4f,%+.4f) src px"
                          + " · 残差 (%+.4f,%+.4f) src px · RMS %.4f src px · %d 标记",
                        angle.name, crop.name, zoom.name, rung.description, flip.name,
                        ratio, tolerance,
                        meanRaw.x / ratio, meanRaw.y / ratio,
                        meanPhase.x / ratio, meanPhase.y / ratio,
                        meanCorrected.x / ratio, meanCorrected.y / ratio,
                        rmsCorrected, measured))
            // ① the main gate: half a decoded pixel, in S5 after the dimension conversion.
            if abs(meanCorrected.x) > tolerance || abs(meanCorrected.y) > tolerance {
                violations.append(Violation(
                    check: "①渲染帧", dx: meanCorrected.x, dy: meanCorrected.y,
                    detail: String(format: "%d 个标记 · %.4f src px · 容差 %.4f px",
                                   measured,
                                   max(abs(meanCorrected.x), abs(meanCorrected.y)) / ratio,
                                   tolerance)))
            }
            // 268 §4 — a spread larger than half-pixel quantisation can explain must not be
            // swallowed. RMS keeps one marker's sampling noise from masquerading as a transform bug,
            // while a real offset still fails: a uniform 1 src px shift gives RMS = 1.
            if rmsCorrected > 0.75 {
                violations.append(Violation(
                    check: "①渲染帧-超界", dx: meanCorrected.x, dy: meanCorrected.y,
                    detail: String(format: "RMS %.3f src px > 0.75", rmsCorrected)))
            }
            // 268 §3 — independent corroboration: the measured deviation is the integer phase,
            // recomputed above step by step. ±0.05 src px is the measurement floor of the marker
            // centroid, not a relaxation of the transform tolerance.
            let corroboration = max(abs(meanRaw.x - meanPhase.x),
                                    abs(meanRaw.y - meanPhase.y)) / ratio
            if corroboration > 0.05 {
                violations.append(Violation(
                    check: "①相位佐证", dx: meanRaw.x - meanPhase.x, dy: meanRaw.y - meanPhase.y,
                    detail: String(format: "实测 − plan 相位 = %.4f src px > 0.05", corroboration)))
            }
            // 268 §2 — the reverse gate: move the expectation one **source** pixel (the decoded
            // rung's own pixel). The tolerance must not be wide enough to accept that.
            let shifted = (x: abs(meanCorrected.x - ratio), y: abs(meanCorrected.y - ratio))
            if shifted.x <= tolerance || shifted.y <= tolerance {
                violations.append(Violation(
                    check: "①反向门", dx: shifted.x, dy: shifted.y,
                    detail: "1 源像素平移没有变红 · 容差 \(tolerance) px"))
            }
        } else {
            note(String(format: "[268] %@ / %@ / %@ / rung %@ / flip %@"
                          + " · 容差 = 0.5 × ratio %.4f = %.4f px · 无可见标记（②③ 仍已检查）",
                        angle.name, crop.name, zoom.name, rung.description, flip.name,
                        ratio, tolerance))
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
            let dx = got.x - expected.x, dy = got.y - expected.y
            if abs(dx) > Self.tolerance || abs(dy) > Self.tolerance {
                let label = "point \(index) (\(Int(p.0)),\(Int(p.1)))"
                violations.append(Violation(check: "③命中", dx: dx, dy: dy, detail: label))
            }
        }
        return (violations, meanResidualS5, maxMarkerResidualSource)
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
                    for flip in Flip.all {
                        let outcome = try measure(angle: angle, crop: crop, zoom: zoom,
                                                  rung: rung, flip: flip,
                                                  markers: fixture.markers,
                                                  graph: activeGraph)
                        results.append(Result(angle: angle, crop: crop, zoom: zoom,
                                              rung: rung, flip: flip,
                                              violations: outcome.violations,
                                              meanResidualS5: outcome.meanResidualS5,
                                              maxMarkerResidualSource:
                                                outcome.maxMarkerResidualSource))
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        var failing = 0
        for result in results where !result.violations.isEmpty {
            // 261 made all three walks assertions; 268 moved ① to its own unit — half a **source**
            // pixel of the decoded rung, converted to S5 by the current projection — while ② and ③
            // stay at the original 0.5 S5 px. 274 adds the flip dimension at every rung: 720
            // combinations in total (5 angles × 4 crops × 3 zooms × 3 rungs × 4 flips), no silent
            // reduction of any dimension or fixture grid.
            for violation in result.violations {
                failing += 1
                note("[260] ✗ \(result.angle) / \(result.crop) / \(result.zoom)"
                     + " / rung \(result.rung) / flip \(result.flip) · \(violation)")
            }
        }
        if let worst = results.max(by: { $0.meanResidualS5 < $1.meanResidualS5 }) {
            note(String(format: "[274] max ①残差 rung %.2g · %.4f S5 px · 单标记最大 %.4f src px"
                          + " @ %@ / %@ / %@ / flip %@",
                        rung.scale, worst.meanResidualS5, worst.maxMarkerResidualSource,
                        worst.angle.name, worst.crop.name, worst.zoom.name, worst.flip.name))
        }
        note(String(format: "[260] rung %.2g · %d combos · %d failing · %.2f s (%.1f ms/combo)",
                    rung.scale, results.count, failing, elapsed,
                    elapsed * 1000 / Double(max(results.count, 1))))
        XCTAssertEqual(failing, 0,
                       "274: render (half a source pixel), overlay and hit test (0.5 S5 px) deviate in "
                       + "\(failing) places at rung \(rung), flip included; see the [260] ✗ rows above")
    }

    func testMatrixRungQuarter() throws { try runMatrix(Rung.all[0]) }
    func testMatrixRungHalf() throws { try runMatrix(Rung.all[1]) }
    func testMatrixRungFull() throws { try runMatrix(Rung.all[2]) }

    // MARK: - 274's perspective + flip: record only

    /// **Record only — `axes=[]`, never red.** 273's report found that the perspective path still
    /// flips in canvas-normalised space while the non-perspective kernel flips the **photograph**
    /// about its own centre; that difference is not in scope here. This test renders perspective +
    /// flip and prints the deviation from the same independent S1/S3 walk the matrix uses (that walk
    /// models the no-keystone picture), so the number on record carries both the keystone's own
    /// displacement and the canvas-space flip difference, without pretending the paths already agree.
    ///
    /// It **waits for the "kernel 透视路径统一到 S1/S3" task** to land; when it does, this case can
    /// be promoted to an assertion (and moved into the matrix) rather than being deleted.
    func testPerspectiveFlipRecordsKnownDifference() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let rung = Rung.all[2]
        let plain = markedFixture(quarterTurns: 0, rung: rung)
        let graph = try RenderGraph(input: RenderInput(image: plain.image,
                                                       identity: "frame-matrix-274-perspective"))
        let state = LoupeViewState.fit
        let angles = [Angle.all[2], Angle.all[3]]   // 1° and 45°: a turn a mirror does not commute with
        let crops = [Crop.all[0], Crop.all[2]]      // 全幅 and 偏心: a pivot-sensitive crop

        for angle in angles {
            for crop in crops {
                for flip in Flip.all {
                    var edit = edit(for: angle, crop: crop, flip: flip)
                    edit.geometry.perspectiveVertical = 50
                    let walk = GeometryWalk(edit: edit, source: Self.source, rung: rung,
                                            viewport: Self.viewport, state: state, flip: flip)
                    let options = RenderOptions(
                        canvas: Self.viewport,
                        scale: walk.framing.renderScale(of: state, decodeScale: rung.scale),
                        outputWindow: walk.framing.outputWindow(of: state, decodeScale: rung.scale),
                        useCache: false, wantsPixels: true, neverUpscalesContent: true)
                    guard let display = try graph.render(edit, options: options).display
                    else { continue }
                    let blobs = self.blobs(in: display)
                    var deviations: [Double] = []
                    for marker in plain.markers {
                        let expected = walk.view(sourceX: marker.x * Double(Self.source.width),
                                                 sourceY: marker.y * Double(Self.source.height))
                        guard expected.x > 30, expected.x < Double(Self.viewport.width) - 30,
                              expected.y > 30, expected.y < Double(Self.viewport.height) - 30
                        else { continue }
                        guard let blob = blobs.min(by: {
                            hypot($0.x - expected.x, $0.y - expected.y)
                                < hypot($1.x - expected.x, $1.y - expected.y)
                        }) else { continue }
                        let d = hypot(blob.x + 0.5 - expected.x, blob.y + 0.5 - expected.y)
                        // The keystone legitimately moves markers; keep the record wide enough to
                        // include them, but reject a nearest-blob mismatch.
                        guard d < 80 else { continue }
                        deviations.append(d)
                    }
                    let mean = deviations.isEmpty
                        ? Double.nan : deviations.reduce(0, +) / Double(deviations.count)
                    let worst = deviations.max() ?? Double.nan
                    note(String(format: "[274-record] axes=[] perspective+flip ·"
                                  + " %@ / %@ / rung %@ / flip %@ · mean %.2f S5 px · max %.2f S5 px"
                                  + " · %d 标记（记录型，等 kernel 透视路径统一到 S1/S3）",
                                angle.name, crop.name, rung.description, flip.name,
                                mean, worst, deviations.count))
                }
            }
        }
    }

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
