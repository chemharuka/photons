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
            .map { documentPoint(normalizedX: $0.0, $0.1, origin: origin) }
    }

    /// A normalized point of the **turned photograph** in document-canvas pixels — the forward walk
    /// in the header.
    func documentPoint(normalizedX nx: Double, _ ny: Double) -> DocumentPoint {
        documentPoint(normalizedX: nx, ny, origin: documentOrigin)
    }

    /// `documentPoint` with the document origin handed in (see `documentQuad(of:origin:)`).
    internal func documentPoint(normalizedX nx: Double, _ ny: Double,
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

    /// The inverse of `documentPoint` — what a document-space measurement needs to come back to the
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
