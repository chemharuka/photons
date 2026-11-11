import Foundation

// MARK: - 324 · the photograph in **document space**: one quad, one canvas, two clamps
//
// 307's document canvas was the **turned rectangle's** AABB, and 317's 「不出像素」 clamp was the
// four half-planes of that rectangle. A keystoned document's picture is a **quadrilateral**, so the
// canvas, the `000000` fill, the frame's stop and the 「不出像素」 stop all have to be read off the
// quad instead — and read off **one** quad, computed **once**.
//
// This file is that one place. Everything below is `P → R` (perspective first, straighten second),
// about the photograph's own centre, in the document canvas' pixel grid whose origin is the AABB's
// top-left corner:
//
//     photo norm ──P──▶ warped norm ──×(W,H)──▶ R(θ) about (W/2,H/2) ──▶ −origin──▶ document px
//
// It is the same walk `CropMath.perspectiveCanvas` composes (and, without a keystone, the same walk
// `CropMath.rotatedExtent` + `documentCanvasCropRect` always described), which is why the numbers
// here agree with the renderer's by construction rather than by review.
//
// The **order is not a free choice** and is pinned twice: `CropMath.perspectiveCanvas` composes
// `R · P` for the pixels, and `KeystoneCanvas324Tests` renders a marker and asserts where it lands —
// printing the reverse walk as the counter-example.
//
// **Which shape is 「框」 here.** For a keystoned document the output frame *is* the warped crop's
// AABB (246: `frameSize == canvas`), so the four corners the user's rules are about are the corners
// of `documentQuad(of:)` — the crop rect's image under the same `P → R` walk, which is what the
// overlay draws and what a drag moves. `photoQuad()` is the same walk for the whole photograph.

/// **364 — the two reverse gates.** Test-only knobs; the app never touches them (`false` / `false` is
/// what ships, and they are spelled here rather than at a call site so that no call site can grow a
/// private `± documentOrigin` again).
///
/// ① `foldsDocumentOriginIntoCanvas = false` — the single entry stops subtracting `documentOrigin`,
///    i.e. the pre-364 convention: it answers **photo pixels** while the camera answers canvas pixels.
/// ② `standInRectUsesPhotoPixels = true` — `FrameTransform.frameRectInS5` goes back to re-deriving
///    the stand-in's rectangle from the crop's photo pixels (`unrotatedSourceToView`) instead of
///    asking the canvas for the export frame's own rect.
public enum DocumentCanvasConvention364 {

    /// ① the convention at `documentPointInCanvas`.
    nonisolated(unsafe) public static var foldsDocumentOriginIntoCanvas = true

    /// ② the stand-in's rectangle.
    nonisolated(unsafe) public static var standInRectUsesPhotoPixels = false
}

/// A point in the **document canvas'** pixel grid: origin at the AABB's top-left corner, y down, one
/// unit = one pixel of the canvas `.document` allocates.
public struct DocumentPoint: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public extension CropGeometry {

    // MARK: the quad

    /// `true` when the picture is a quadrilateral rather than the turned rectangle — i.e. a keystone
    /// with a non-zero knob. The one predicate every branch below asks.
    var hasKeystoneQuad: Bool { perspective?.hasWarp == true }

    /// **The photograph's four corners in document-canvas pixels**, in the stable order
    /// top-left, top-right, bottom-right, bottom-left.
    ///
    /// "Document canvas" is the box `canvasRole == .document` allocates, and it is the **AABB of this
    /// very quad** (`photoQuadExtent`) — so the quad defines the canvas and the canvas is not a second
    /// derivation of it. Callers that need the box (the renderer's baseline, the loupe's fit, the
    /// crop tool's stop) ask `photoQuadExtent`; callers that need the shape (the overlay, the two
    /// clamps, the red-frame predicate) ask this.
    ///
    /// Without a keystone the quad *is* the turned rectangle, built from `photoExtent` so a
    /// straightened document's four numbers are 307's bit for bit.
    func photoQuad() -> [DocumentPoint] {
        guard hasKeystoneQuad else {
            let e = photoExtent
            // 330 — **document-canvas pixels, origin at the AABB's top-left**, which is what this
            // function's own contract says and what the keystone branch below already does. The
            // pre-330 spelling returned the box at `((w − e)/2, (h − e)/2)` — photograph coordinates,
            // not document ones — and nothing noticed because the only caller
            // (`translatedInsidePhotoQuad`) ran for keystoned documents only. 330's canvas-spaced
            // clamp runs it for every keystoned *and* straightened document, where the two frames
            // differ by exactly that offset (9°: (−55, −89) px, measured as an 85 px overhang).
            return [DocumentPoint(0, 0), DocumentPoint(e.width, 0),
                    DocumentPoint(e.width, e.height), DocumentPoint(0, e.height)]
        }
        let o = documentOrigin
        return warpedTurnedPhotoCorners.map { DocumentPoint($0.x - o.x, $0.y - o.y) }
    }

    /// The document canvas in continuous pixels — `photoQuad()`'s AABB, which is `photoCanvas`
    /// before the one `ceil`.
    ///
    /// This is the number the user's rule names: 「画布 = 透视 + 旋转之后照片四边形的 AABB」. Without
    /// a keystone it is `photoExtent` (307's turned rectangle) bit for bit.
    var photoQuadExtent: DSize {
        guard hasKeystoneQuad else { return photoExtent }
        let c = warpedTurnedPhotoCorners
        let xs = c.map(\.x), ys = c.map(\.y)
        return DSize(width: max(1, (xs.max() ?? 1) - (xs.min() ?? 0)),
                     height: max(1, (ys.max() ?? 1) - (ys.min() ?? 0)))
    }

    /// A `crop` rect's four corners in the same grid, same order (TL/TR/BR/BL **of the rect**).
    ///
    /// This is the frame the overlay draws and the shape a drag moves: a rectangle of the turned
    /// photo, so its image under a keystone is a quadrilateral — the AABB it is exported through is
    /// `CropMath.perspectiveCanvas`'s business, not this function's.
    func documentQuad(of crop: CropRect) -> [DocumentPoint] {
        documentQuad(of: crop, origin: documentOrigin)
    }

    /// `documentQuad(of:)` with the document origin handed in — the clamp translates a rect dozens of
    /// times and the origin is a property of the document, not of the rect.
    ///
    /// **330** — the rect's own space decides the walk. A `.source` crop is a rectangle of the
    /// *photograph*, so its image under `P → R` is a quadrilateral (324). A `.canvas` crop is a
    /// rectangle of the **document canvas** already, so its four corners are the rect scaled by the
    /// canvas' extent — axis-aligned by construction, which is the whole point of the space: the
    /// frame is a rectangle on screen, the picture inside it is what got warped.
    internal func documentQuad(of crop: CropRect,
                               origin: (x: Double, y: Double)) -> [DocumentPoint] {
        let c = crop.clamped(allowsOutsideSource: true)
        if cropIsCanvasSpaced, !CropGeometry.pre330SourceSpace {
            let e = photoQuadExtent
            let w = max(e.width, 1e-9), h = max(e.height, 1e-9)
            return [(c.left, c.top), (c.right, c.top), (c.right, c.bottom), (c.left, c.bottom)]
                .map { DocumentPoint($0.0 * w, $0.1 * h) }
        }
        return [(c.left, c.top), (c.right, c.top), (c.right, c.bottom), (c.left, c.bottom)]
            .map { documentPointInCanvas(normalizedX: $0.0, $0.1, origin: origin) }
    }

    /// A normalized point of the **turned photograph** in document-canvas pixels — **the one entry**.
    ///
    /// **364 — the convention, and it is this function's contract.** A document-canvas pixel is the
    /// grid the camera speaks: `FrameTransform.s1ToS3` produces it, `s3ToS5` consumes it, and its
    /// `(0, 0)` is the canvas' top-left corner — which for a keystoned document is the AABB of the
    /// warped picture, i.e. `documentOrigin` in photo pixels. The origin is therefore **folded into
    /// the value here, once**: callers never add or subtract it, they draw, hit-test and compare with
    /// canvas rects directly.
    ///
    /// The two spaces are one subtraction apart and the difference is not academic — `canvas` (this
    /// function) versus **photo pixels** (`warpedTurnedPhotoCorners`, `documentOrigin`) — so the
    /// photo-pixel space is named for what it is and is reached only by measurement code
    /// (`photoNormalized`, the diagnostics). A second forward spelling that forgot the subtraction
    /// put the loupe's stand-in 303.67 / 299.21 px off the frame at `(+40, −25) + 9°` and exactly 4×
    /// that at 4× (364 §0: a constant source-space translation, not a scale error).
    func documentPointInCanvas(normalizedX nx: Double, _ ny: Double) -> DocumentPoint {
        documentPointInCanvas(normalizedX: nx, ny,
                              origin: DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas
                                  ? documentOrigin : (x: 0, y: 0))
    }

    /// `documentPointInCanvas` with the document origin handed in — the clamp translates a rect dozens
    /// of times and the origin is a property of the document, not of the rect. `origin` is
    /// `documentOrigin` at every call site; passing anything else is asking for photo pixels.
    internal func documentPointInCanvas(normalizedX nx: Double, _ ny: Double,
                                        origin: (x: Double, y: Double)) -> DocumentPoint {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        var px = nx, py = ny
        if hasKeystoneQuad, let perspective {
            let warped = perspective.forward(x: nx, y: ny)
            px = warped.x
            py = warped.y
        }
        let turned = rotation.apply(x: px * w - w / 2, y: py * h - h / 2)
        return DocumentPoint(turned.x + w / 2 - origin.x, turned.y + h / 2 - origin.y)
    }

    /// The inverse of `documentPointInCanvas` — what a document-space measurement needs to come back to the
    /// crop's own normalized coordinates (the keystone `documentCanvasCropRect`, a diagnostic).
    func photoNormalized(documentX: Double, _ documentY: Double) -> NormalizedPoint {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let o = documentOrigin
        let q = rotation.invert(x: documentX + o.x - w / 2, y: documentY + o.y - h / 2)
        var nx = (q.x + w / 2) / w, ny = (q.y + h / 2) / h
        if hasKeystoneQuad, let perspective {
            let p = perspective.inverse(x: nx, y: ny)
            nx = p.x
            ny = p.y
        }
        return NormalizedPoint(nx, ny)
    }

    // MARK: the two clamps

    /// `crop` **translated** (never resized) so that all four of its document corners are inside the
    /// convex `region`; `nil` when no translation fits.
    ///
    /// The move is the **minimal** one, exactly like 224/307's per-axis slide: each axis is searched
    /// for the smallest offset that clears every edge, the two are applied together, and a jointly
    /// infeasible pair is pushed out along its own direction until it clears — so the frame stops
    /// *on* the edge the drag crossed instead of snapping to the region's centre. A frame that is
    /// already inside comes back **bit for bit** (`==` on the struct), which is what keeps 317 §3.4's
    /// 「开勾选不缩、不动」 a field-by-field promise.
    ///
    /// The size is never touched: the result is `crop` shifted by `(δx, δy)` in normalized photo
    /// coordinates, so `right − left` and `bottom − top` are the same two doubles.
    func translated(_ crop: CropRect, inside region: DocumentRegion,
                    tolerance: Double = 1e-9) -> CropRect? {
        let c = crop.clamped(allowsOutsideSource: true)
        guard c.width > 0, c.height > 0, region.corners.count >= 3 else { return c }
        func shifted(_ dx: Double, _ dy: Double) -> CropRect {
            CropRect(left: c.left + dx, top: c.top + dy,
                     right: c.right + dx, bottom: c.bottom + dy)
        }
        // The origin is a document fact: resolving it once is what keeps a 20-tick drag's clamp out
        // of the homography's inner loop.
        let origin = documentOrigin
        func slack(_ dx: Double, _ dy: Double) -> Double {
            Self.slack(of: documentQuad(of: shifted(dx, dy), origin: origin), inside: region)
        }
        if slack(0, 0) >= -tolerance { return c }        // already inside: nothing moves

        // 380 — a **search** starts here. The size handles' canvas branch and the reverse gate still
        // use it; a *move* (`.inside`) must not (`TranslationFeasibleSet` is its law).
        KeystoneTranslationProbe380.directionScans &+= 1

        // **Which way is in, and how far?** Two questions that have to be asked together: a corner
        // outside two edges is never fixed on one axis alone, and a frame that starts far outside
        // leaves the region again at the far end of a ray. So every direction is scanned for its
        // **first** feasible point and the shortest of those moves wins — the projection a drag
        // expects, with no iteration and no snap to the region's centre.
        let probeStep = 0.02
        let startViolation = Self.totalViolation(of: documentQuad(of: shifted(0, 0)), in: region)
        var ordered: [(violation: Double, direction: (x: Double, y: Double))] = []
        for direction in Self.directions {
            let probe = Self.totalViolation(of: documentQuad(of:
                    shifted(direction.x * probeStep, direction.y * probeStep)), in: region)
            ordered.append((probe, direction))
        }
        // Best first: a direction that does not reduce the violation cannot reach the region.
        ordered.sort { $0.violation < $1.violation }
        guard let bestViolation = ordered.first?.violation,
              bestViolation < startViolation - 1e-12 else { return nil }

        // The law is `slack >= 0` at the boundary, not `>= -tolerance`: the caller's tolerance is
        // how much slack an already-inside frame may keep, and aiming the bisection at it would leave
        // the answer exactly `-tolerance` — a frame one ULP *outside* the region it claims to be in.
        let strict = min(tolerance, 1e-12)
        var best: (distance: Double, rect: CropRect)?
        for entry in ordered where entry.violation < startViolation - 1e-12 {
            let direction = entry.direction
            let limit = 2.5
            let samples = 60
            var previous = 0.0
            for index in 1...samples {
                let t = limit * Double(index) / Double(samples)
                if slack(direction.x * t, direction.y * t) >= -strict {
                    var lo = previous, hi = t
                    for _ in 0..<52 {
                        let mid = (lo + hi) / 2
                        if slack(direction.x * mid, direction.y * mid) >= -strict { hi = mid }
                        else { lo = mid }
                    }
                    if best == nil || hi < best!.distance {
                        best = (hi, shifted(direction.x * hi, direction.y * hi))
                    }
                    break
                }
                previous = t
            }
        }
        guard let winner = best, slack(winner.rect.left - c.left, winner.rect.top - c.top) >= -tolerance
        else { return nil }
        return winner.rect.clamped(allowsOutsideSource: true)
    }

    /// `crop` translated into the **document canvas** — 307's rule at a keystone (「框可以进 000000，
    /// 不能出 AABB」).
    func translatedInsidePhotoCanvas(_ crop: CropRect, tolerance: Double = 1e-9) -> CropRect? {
        translated(crop, inside: DocumentRegion.axisAligned(width: photoQuadExtent.width,
                                                           height: photoQuadExtent.height),
                   tolerance: tolerance)
    }

    /// `crop` translated into the **photograph's quad** — 317's 「不出像素」 at a keystone (four
    /// half-planes, not a rectangle's four edges).
    func translatedInsidePhotoQuad(_ crop: CropRect, tolerance: Double = 1e-9) -> CropRect? {
        translated(crop, inside: DocumentRegion(photoQuad()), tolerance: tolerance)
    }

    /// The largest rect of `crop`'s **own shape** (same centre, same pixel aspect) whose **export
    /// canvas** lies inside the photograph's quad — 324's 「放不下时一次性内切到最大内接轴对齐矩形」.
    ///
    /// The scale is searched by bisection on `CropMath.frameExceedsPicture`, so the answer is the
    /// same predicate the overlay paints red with: the canvas a keystoned document exports is the
    /// warped crop's AABB (246), and `AABB ⊆ photo quad` is exactly "no black corner in the file".
    /// It is also the stronger of the two conditions — the crop's own quad is inside its AABB, so the
    /// inscribed frame's four corners are inside the quadrilateral too (§3.5).
    ///
    /// Without a keystone this is 307's inscription, `clampedToRotatedFrame(keepsInside: true)`.
    func inscribedInPhotoQuad(_ crop: CropRect) -> CropRect {
        let c = crop.clamped(allowsOutsideSource: true)
        // 330 — a canvas-spaced frame's export canvas **is** the rect, so 「放不下」 is the four
        // corners against the photo quad, in canvas pixels. Same bisection, one predicate.
        if cropIsCanvasSpaced {
            let region = DocumentRegion(photoQuad())
            let e = photoQuadExtent
            let w = max(e.width, 1e-9), h = max(e.height, 1e-9)
            func scaled(_ sigma: Double) -> CropRect {
                let rw = c.width * sigma, rh = c.height * sigma
                let left = c.centerX - rw / 2, top = c.centerY - rh / 2
                return CropRect(left: left, top: top, right: left + rw, bottom: top + rh)
            }
            func fits(_ sigma: Double) -> Bool {
                let r = scaled(sigma)
                // Two canvas pixels of slack for the same reason as the source-space branch: the
                // exported grid is a whole-pixel `ceil` and S0 samples at pixel **centres**.
                let margin = 2.0
                return [(r.left, r.top), (r.right, r.top),
                        (r.right, r.bottom), (r.left, r.bottom)].allSatisfy { corner in
                    region.inset(DocumentPoint(corner.0 * w, corner.1 * h)) >= margin
                }
            }
            if fits(1) { return c }
            var lo = 0.0, hi = 1.0
            for _ in 0..<80 {
                let mid = (lo + hi) / 2
                if fits(mid) { lo = mid } else { hi = mid }
            }
            return scaled(lo)
        }
        guard hasKeystoneQuad, let perspective else {
            return CropMath.clampedToRotatedFrame(c, in: source, degrees: rotationDegrees,
                                                  keepsInsideRotatedFrame: true)
        }
        func scaled(_ sigma: Double) -> CropRect {
            let w = c.width * sigma, h = c.height * sigma
            let left = c.centerX - w / 2, top = c.centerY - h / 2
            return CropRect(left: left, top: top, right: left + w, bottom: top + h)
        }
        func fits(_ sigma: Double) -> Bool {
            let r = scaled(sigma)
            let canvas = CropMath.perspectiveCanvas(crop: r, in: source,
                                                    straightenDegrees: rotationDegrees,
                                                    perspective: perspective)
            let quad = CropMath.perspectivePhotoQuad(crop: r, canvas: canvas)
            // Two canvas pixels of slack: the exported canvas is a whole-pixel `ceil` and S0 samples
            // at pixel **centres**, so a frame flush with the picture's edge puts its first row of
            // samples exactly on the edge — one of them lands outside and the file gains a black
            // pixel. The margin is the smallest one that survives both roundings.
            let margin = 2.0 / Double(max(1, canvas.size.width))
            return CropMath.quadContains(quad, rect: .full, tolerance: -margin)
        }
        if fits(1) { return c }
        var lo = 0.0, hi = 1.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return scaled(lo)
    }

    // MARK: the arithmetic

    /// `P → R` for the photograph's four corners, in photo pixels, **before** the AABB origin is
    /// subtracted. `CropMath.perspectiveCanvas(crop: .full, …)` composes the same walk; this is the one
    /// the document canvas uses.
    internal var warpedTurnedPhotoCorners: [(x: Double, y: Double)] {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let inputs = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        return inputs.map { corner in
            var nx = corner.0, ny = corner.1
            if hasKeystoneQuad, let perspective {
                let warped = perspective.forward(x: nx, y: ny)
                nx = warped.x
                ny = warped.y
            }
            let turned = rotation.apply(x: nx * w - w / 2, y: ny * h - h / 2)
            return (x: turned.x + w / 2, y: turned.y + h / 2)
        }
    }

    /// The document canvas' own origin in photo pixels: the AABB's top-left corner.
    internal var documentOrigin: (x: Double, y: Double) {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        guard hasKeystoneQuad else {
            let e = photoExtent
            return ((w - e.width) / 2, (h - e.height) / 2)
        }
        let c = warpedTurnedPhotoCorners
        return (c.map(\.x).min() ?? 0, c.map(\.y).min() ?? 0)
    }

    // MARK: 380 — a move's containment is a **projection**, not a search

    /// **380 — the translations a *move* may take, as one convex set.**
    ///
    /// 371 fixed the size handles (a tick is the hand's delta on the frame it holds, and a clamp pins
    /// it). A **move** (`.inside`) went through `translated(_:inside:)`, whose direction scan and
    /// bisection pick a *new* direction and distance on every tick: what the user sees is the search's
    /// output, not the hand's step — 「尺寸/位置乱跳，还出界」.
    ///
    /// A translation never changes the shape, so 「框 ⊆ 区域」 is exactly 「四个角都在区域里」: one
    /// linear inequality per corner and region edge, i.e. a convex polygon in `t` (the rect's own
    /// normalized units). Its **nearest point** to the hand's `t` is the whole law:
    ///
    ///   · `t` inside → `t` itself, bit for bit (the frame follows the hand);
    ///   · `t` outside → the orthogonal projection (it stops *on* the boundary, exactly);
    ///   · a projection is idempotent, so a hand that keeps pushing gets the same frame back every
    ///     tick — the 「被钉住后逐位冻结」 371 gives the size handles.
    ///
    /// Pure algebra: no sampling, no direction scan, no iteration cap. Nothing here reads a screen.
    public struct HalfPlane380: Sendable, Equatable {
        /// `ax·t.x + ay·t.y ≤ b`.
        public var ax: Double
        public var ay: Double
        public var b: Double
        public init(ax: Double, ay: Double, b: Double) {
            self.ax = ax
            self.ay = ay
            self.b = b
        }
        /// Signed distance to this line, positive on the legal side.
        public func slack(x: Double, y: Double) -> Double { b - (ax * x + ay * y) }
    }

    /// The feasible translations of a frame, `{ t : every half-plane }` — a convex polygon.
    public struct TranslationFeasibleSet380: Sendable {
        public let constraints: [HalfPlane380]

        public init(constraints: [HalfPlane380]) {
            self.constraints = constraints
        }

        public var isEmpty: Bool { constraints.isEmpty }

        public func isFeasible(x: Double, y: Double, tolerance: Double = 0) -> Bool {
            constraints.allSatisfy { $0.slack(x: x, y: y) >= -tolerance }
        }

        /// The nearest point of the set to `t`, or `nil` when the set is empty (a frame no
        /// translation can hold — 317's 「放不下」, which the caller answers by keeping the rect).
        ///
        /// `t` feasible → `t` **unchanged** (the idempotence the acceptance asserts); otherwise the
        /// standard convex-polygon nearest point: a single violated edge's foot, or — at a corner —
        /// the intersection of two violated edges. Both are closed form.
        public func project(x: Double, y: Double,
                            tolerance: Double = 1e-9) -> (x: Double, y: Double)? {
            if isFeasible(x: x, y: y, tolerance: tolerance) { return (x, y) }
            guard !constraints.isEmpty else { return nil }
            var best: (point: (x: Double, y: Double), distance: Double)?

            func consider(_ point: (x: Double, y: Double)) {
                guard isFeasible(x: point.x, y: point.y, tolerance: tolerance) else { return }
                let distance = hypot(point.x - x, point.y - y)
                if best == nil || distance < best!.distance { best = (point, distance) }
            }

            let violated = constraints.filter { $0.slack(x: x, y: y) < 0 }
            // ① the foot of each violated edge.
            for edge in violated {
                let norm = edge.ax * edge.ax + edge.ay * edge.ay
                guard norm > 1e-24 else { continue }
                let scale = edge.slack(x: x, y: y) / norm
                consider((x + edge.ax * scale, y + edge.ay * scale))
            }
            // ② the corner where two violated edges meet.
            for i in violated.indices {
                for j in violated.indices where j > i {
                    let p = violated[i], q = violated[j]
                    let determinant = p.ax * q.ay - p.ay * q.ax
                    guard abs(determinant) > 1e-18 else { continue }
                    consider(((p.b * q.ay - p.ay * q.b) / determinant,
                              (p.ax * q.b - p.b * q.ax) / determinant))
                }
            }
            return best?.point
        }
    }

    /// **380 — the move's one region.** The feasible translations of `crop` so that every one of its
    /// document corners stays inside the photograph's quad **and** the document canvas — one
    /// intersection, projected once, never 「先夹画布、再平进四边形」 (that sequence is this task's bug).
    ///
    /// `t` is in the rect's **own normalized units**; the constraint rows are in document pixels
    /// (`Mᵀn`, `M` the affine part of the frame's own walk), and the normal is unit length, so the
    /// feasibility tolerance is a pixel distance.
    ///
    /// `nil` when the state cannot be expressed as a translation set — a `.source` rect of a
    /// **keystoned** document, a state `CropToolController.liveCropSpace` cannot produce (a keystoned
    /// document is always read on its canvas), but one a caller could build by hand.
    ///
    /// `insidePhotoPixels == false` is 「不出像素」 off: the only region is the document canvas, so a
    /// move is still one projection, just a smaller set.
    func moveFeasibleSet380(of crop: CropRect,
                            insidePhotoPixels: Bool = true) -> TranslationFeasibleSet380? {
        if hasKeystoneQuad, !cropIsCanvasSpaced { return nil }
        let c = crop.clamped(allowsOutsideSource: true)
        guard c.width > 0, c.height > 0 else { return nil }
        // **§6.3 — the two spaces are two different questions, and only one of them is rotated.**
        //
        //   · `.canvas` — the frame *is* a rectangle of the canvas: its four corners are
        //     `documentQuad(of:)`'s, i.e. **turned** by θ exactly like the picture. Both sides of
        //     「框 ⊆ 画布 ∩ 照片」 are then read on one grid, so conjugating the two regions' edges by
        //     the frame's own affine map is the whole law (this branch is right, and stays untouched).
        //   · `.source` — the frame is a rectangle of the photograph's **own pixel grid**: the overlay
        //     draws it axis-aligned in photo-normalized coordinates (`R(−θ)` is the picture's, not the
        //     frame's), so its legality is literally `0 ≤ left+t.x`, `right+t.x ≤ 1`,
        //     `0 ≤ top+t.y`, `bottom+t.y ≤ 1` — four axis-aligned rows, **no rotation, no
        //     `documentOrigin`, no canvas AABB**.
        //
        // Reading the `.source` frame's corners as turned (`documentQuad`, or photo pixels shifted by
        // `documentOrigin`) compares an **un-turned** box with a **turned** region: at θ = 9° the
        // projection calls a frame legal while it sits 0.0394 (normalized, ≈ 236 px) outside the
        // photograph, and never once reaches the boundary, so nothing ever freezes
        // (`CropMovePixelPress380Tests` ⑪⑫ — measured before this branch existed).
        if !cropIsCanvasSpaced {
            // 「不出像素」 on → the photograph itself; off → the document canvas, which in
            // photo-normalized coordinates is `documentCanvasCropRect` (a superset of `[0,1]²` at
            // θ ≠ 0, `[0,1]²` at every right angle — so the two answers agree where they must).
            let legal: CropRect = insidePhotoPixels ? .full : documentCanvasCropRect
            return TranslationFeasibleSet380(constraints: [
                HalfPlane380(ax: -1, ay: 0, b: c.left - legal.left),
                HalfPlane380(ax: 1, ay: 0, b: legal.right - c.right),
                HalfPlane380(ax: 0, ay: -1, b: c.top - legal.top),
                HalfPlane380(ax: 0, ay: 1, b: legal.bottom - c.bottom),
            ])
        }
        // **The frame's four corners at `t = 0`, and what one unit of `t` moves them by** — `.canvas`
        // only: there the frame and the picture are the same turn, so `documentQuad` (the one owner of
        // that walk) gives the corners and its two edge vectors give `mapX` / `mapY`.
        let quad = documentQuad(of: c)
        guard quad.count == 4 else { return nil }
        let corners: [DocumentPoint] = quad
        let mapX = (x: (quad[1].x - quad[0].x) / c.width, y: (quad[1].y - quad[0].y) / c.width)
        let mapY = (x: (quad[3].x - quad[0].x) / c.height, y: (quad[3].y - quad[0].y) / c.height)
        let extent = photoQuadExtent
        var regions = [DocumentRegion.axisAligned(width: extent.width, height: extent.height)]
        if insidePhotoPixels {
            // 380 — the picture in the **same** grid (`documentPointInCanvas`), so the two rows below
            // are literally 「画布 ∩ 照片」 and one projection answers both. The canvas is the quad's
            // AABB by definition, so its four rows never exclude what the picture's four accept.
            regions.append(DocumentRegion(photoQuadInDocumentPixels380()))
        }
        var constraints: [HalfPlane380] = []
        constraints.reserveCapacity(regions.count * 4 * corners.count)
        for region in regions {
            for edge in region.halfPlanes {
                // (n · (corner + M·t) ≤ offset)  ⇔  (Mᵀn) · t ≤ offset − n · corner
                let ax = mapX.x * edge.nx + mapX.y * edge.ny
                let ay = mapY.x * edge.nx + mapY.y * edge.ny
                for corner in corners {
                    constraints.append(HalfPlane380(
                        ax: ax, ay: ay,
                        b: edge.offset - (edge.nx * corner.x + edge.ny * corner.y)))
                }
            }
        }
        return TranslationFeasibleSet380(constraints: constraints)
    }

    /// **380 — the photograph's four corners in the document canvas' pixels** — the grid
    /// `documentQuad(of:)` speaks, through that same one entry (`documentPointInCanvas`).
    ///
    /// **§5.1 — the origin is handed in, not defaulted.** `documentQuad(of:)` passes
    /// `documentOrigin`; the default of the single entry is a *test gate*
    /// (`DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas`, 364's reverse switch). Reading it
    /// here would make 「框 ⊆ 照片」 two sets in two origins the moment that gate is flipped — the
    /// exact shape of this task's 「投影通过了、框还是出界」. `documentOrigin` is a property of the
    /// document, so the two spellings of the same four points must agree independently of any test
    /// switch (see `CropMovePixelPress380Tests.testGridCoherence380`).
    /// `internal` rather than `private` for one reason: §5.3 ⑩ asserts the identity *between* the two
    /// spellings of the picture's corners, so the test has to be able to ask this one.
    func photoQuadInDocumentPixels380() -> [DocumentPoint] {
        let o = documentOrigin
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            documentPointInCanvas(normalizedX: $0.0, $0.1, origin: o)
        }
    }

    /// The worst signed distance (in pixels, positive inside) of `quad`'s corners to `region`.
    static func slack(of quad: [DocumentPoint], inside region: DocumentRegion) -> Double {
        quad.reduce(Double.infinity) { min($0, region.inset($1)) }
    }

    /// The eight probe directions a translation may take: the two axes and the four diagonals.
    private static let directions: [(x: Double, y: Double)] = {
        let d = 1.0 / 2.0.squareRoot()
        return [(1, 0), (-1, 0), (0, 1), (0, -1), (d, d), (d, -d), (-d, d), (-d, -d)]
    }()

    /// Total outside-ness of `quad` w.r.t. `region`, in pixels: the sum of every corner's negative
    /// inset. It is the **direction-finding** measure only (a sum, so a corner over two edges still
    /// registers every step); the law itself is the strict `slack`.
    static func totalViolation(of quad: [DocumentPoint], in region: DocumentRegion) -> Double {
        quad.reduce(0) { $0 + max(0, -region.inset($1)) }
    }
}

// MARK: - the region

/// A **convex polygon used as a containment region**, with the interior side of every edge resolved
/// once (from the centroid) so the signed distance is a plain `dot` per edge.
///
/// Two regions matter to 324 and both are one of these: the document canvas (an axis-aligned
/// rectangle) and the photograph's quadrilateral. The distance is in **pixels** — the normals are
/// unit length — which is what lets the acceptance quote `≥ −1e−9` without a unit conversion.
// MARK: - 380 · a move is a projection

/// **380 — the search counter.** `translated(_:inside:)` is a *direction scan*: 8 probes plus up to
/// 60 samples and 52 bisection steps per tick. It is the right answer for a size handle's canvas
/// clamp (the frame may be genuinely larger than the region), but it is **not** how a *move* may be
/// bounded: a scan's output is a function of its own probes, so every tick re-picks a direction and a
/// distance and the frame jumps by up to `limit = 2.5` region widths.
///
/// This counter exists so the acceptance can say 「`.inside` 不再做搜索」 as a number (`== 0`) instead
/// of a reading of the code. `moveFeasibleSet380` / `TranslationFeasibleSet380.project` never touch
/// it — they are closed form.
public enum KeystoneTranslationProbe380 {
    /// How many times `translated(_:inside:)` ran its probe/bisection search. Diagnostics only.
    nonisolated(unsafe) public static var directionScans = 0

    /// A read-and-reset: the acceptance measures one trajectory at a time.
    @discardableResult
    public static func takeDirectionScans() -> Int {
        let value = directionScans
        directionScans = 0
        return value
    }
}

public struct DocumentRegion: Sendable {

    public let corners: [DocumentPoint]

    /// Outward unit normal + offset per edge: inside ⟺ `n.x·x + n.y·y ≤ offset` for every edge.
    private let edges: [(nx: Double, ny: Double, offset: Double)]

    public init(_ corners: [DocumentPoint]) {
        self.corners = corners
        guard corners.count >= 3 else {
            self.edges = []
            return
        }
        let cx = corners.reduce(0) { $0 + $1.x } / Double(corners.count)
        let cy = corners.reduce(0) { $0 + $1.y } / Double(corners.count)
        var built: [(nx: Double, ny: Double, offset: Double)] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let ex = b.x - a.x, ey = b.y - a.y
            let len = (ex * ex + ey * ey).squareRoot()
            guard len > 1e-12 else { continue }
            // Right-hand normal of a→b; flip it if it points at the centroid.
            var nx = ey / len, ny = -ex / len
            if nx * (cx - a.x) + ny * (cy - a.y) > 0 {
                nx = -nx
                ny = -ny
            }
            built.append((nx: nx, ny: ny, offset: nx * a.x + ny * a.y))
        }
        self.edges = built
    }

    /// A rectangle with one corner at the origin — the document canvas.
    public static func axisAligned(width: Double, height: Double) -> DocumentRegion {
        DocumentRegion([DocumentPoint(0, 0), DocumentPoint(width, 0),
                        DocumentPoint(width, height), DocumentPoint(0, height)])
    }

    /// **380** — the same edges as raw half-planes (`nx·x + ny·y ≤ offset`), unit normals.
    ///
    /// Read-only: a translation's feasible set is these rows conjugated by the rect's own affine map
    /// (see `CropGeometry.moveFeasibleSet380`). Exposed so the projection and the signed distance are
    /// built from **one** resolution of the interior side, not two.
    var halfPlanes: [(nx: Double, ny: Double, offset: Double)] { edges }

    /// Signed distance to the nearest edge, in pixels; positive inside, negative outside.
    public func inset(_ p: DocumentPoint) -> Double {
        guard !edges.isEmpty else { return -.infinity }
        var worst = Double.infinity
        for e in edges {
            worst = min(worst, e.offset - (e.nx * p.x + e.ny * p.y))
        }
        return worst
    }

    public func contains(_ p: DocumentPoint, tolerance: Double = 0) -> Bool {
        inset(p) >= -tolerance
    }

    public var centroid: DocumentPoint {
        guard !corners.isEmpty else { return DocumentPoint(0, 0) }
        return DocumentPoint(corners.reduce(0) { $0 + $1.x } / Double(corners.count),
                             corners.reduce(0) { $0 + $1.y } / Double(corners.count))
    }
}
