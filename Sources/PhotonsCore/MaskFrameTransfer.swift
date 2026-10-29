import Foundation

// MARK: - 蒙版跨照片复制 (P1-5): 短边锚定
//
// 「复制设置」 used to carry no masks at all, for a real reason: a mask's geometry is **normalised to
// its own frame** (x, y are 0…1 fractions of *that* photo's width and height; every radius, feather
// and stroke width is a fraction of *that* photo's short edge — `Masks.swift`'s header, D11,
// docs/xmp-mapping.md §1.8). Dropping those numbers onto another photo unchanged is not "copying a
// mask", it is copying four numbers that happen to be in the same range — and the ticket that said
// so (P1-5) is this one. What makes it portable is choosing **which of the two meanings** of a
// normalised coordinate survives the move, and writing it down:
//
//   ① **frame-relative** — `x = 0.4` means "40 % across the picture". Copy it verbatim and a subject
//      that sat 40 % across a 4:3 frame is claimed to sit 40 % across a 3:2 frame: the *relative*
//      position is kept, the *physical* one is not, and a circle (whose radius is in short-edge
//      units) then covers a different fraction of the subject. On equal aspect ratios the two
//      meanings coincide exactly.
//   ② **short-edge anchored** — expand the normalised pair into the metric the type already uses for
//      every distance: offsets from the frame's centre **in short-edge units** (`(x−0.5)·W/min`,
//      `(y−0.5)·H/min`), then re-normalise against the target's own short edge. Radii, feather and
//      stroke widths are already in that metric and therefore cross unchanged.
//
// **This build chooses ②.** Reasons, in the order they matter:
//
//   · **It is a superset of ①, exactly.** For two frames of the same aspect ratio `W/H` the two
//     spans `W/min` and `H/min` are the same numbers on both sides, so each factor is `k/k = 1` and
//     the point is returned untouched — and `point` short-circuits equal aspects before any
//     arithmetic, so "same aspect ratio" is bit-exact, not merely close. A rule that changed a mask
//     on a 3:2 → 3:2 copy would be a worse rule than ① for the commonest case there is.
//   · **It keeps one metric, not two.** Every distance in the mask document is short-edge
//     normalised (`MaskRadius`, §4). Anchoring the *centre* in the same units means the whole shape
//     is carried by a similarity of that space: radii, angles, feather, brush width all cross
//     unchanged, and there is no second interpretation of "normalised" anywhere in the mask code.
//     ① would need a per-axis radius correction to keep an ellipse an ellipse; ② does not, because
//     the ellipse is already defined in short-edge units and a similarity does not deform it.
//   · **The failure mode is the honest one.** On a different aspect ratio the transform contracts
//     (or stretches) the axis that got longer (shorter) *toward the frame's centre* and leaves the
//     short axis alone. 4:3 → 3:2 therefore pulls a mask **inward** by exactly `(4/3)/(3/2) =
//     8/9` horizontally and moves it not at all vertically: nothing that was inside the frame can
//     leave it (`0.5 ± 0.5·8/9 = 0.0556…0.9444`, and the short axis is unchanged at `0…1`). The
//     reverse direction (3:2 → 4:3) *stretches* by `9/8`, so a mask hugging the left or right edge
//     lands slightly outside the frame — which is the truthful answer, not a bug to be clamped
//     away: mask coordinates are allowed outside `[0,1]` (the atlas clips at render time, it never
//     clamps a document — see `MaskCanvasMapping.canvasPoint`), and squeezing it back in would move
//     the mask relative to the subject it was drawn on, which is the one thing this transfer exists
//     to preserve.
//
// What is **not** carried: mask ids and component ids. A paste appends masks to a document that
// already has its own, and an id is the mask's atlas-cache identity (`Mask.selectionKey`,
// `EditModel.activeMasks` sorts by it) — two masks sharing one id would collide in the cache key,
// in `MaskGraph` and in the history's id-keyed diff (`HistoryFields.maskChanges`). So a copy is
// re-identified as it lands (`Mask.freshID(excluding:)`), and the ids the source document holds are
// passed in as the taken set.

/// The one place that decides where a mask's numbers land on another photograph.
public enum MaskFrameTransfer {

    /// The frame's own span, per axis, in **short-edge units**: `W/minSide` and `H/minSide`.
    ///
    /// For a landscape frame (`aspect ≥ 1`) the short edge is the height, so the height spans `1`
    /// and the width spans the aspect ratio; for a portrait frame it is the other way round. A
    /// non-positive or non-finite aspect carries no information and answers `(1, 1)` — which makes
    /// every factor `1` and every point an identity, the same degradation as "unknown aspect".
    public static func spans(aspect: Double) -> (x: Double, y: Double) {
        guard aspect.isFinite, aspect > 0 else { return (1, 1) }
        return aspect >= 1 ? (aspect, 1) : (1, 1 / aspect)
    }

    /// A normalised source point re-anchored for another frame's aspect ratio.
    ///
    /// `nil` on either side means "this frame's aspect ratio is not known" (a document does not
    /// store its own pixel size — `MaskSourceFrame` is where the *caller* derives it). An unknown
    /// aspect copies the coordinates verbatim, which is ① and is the only defensible answer when
    /// the factor cannot be computed.
    ///
    /// Each axis with a factor of exactly `1` is passed through **untouched** rather than through
    /// `0.5 + (p − 0.5)·1`: on a 4:3 → 3:2 copy the short axis is mathematically the identity, and
    /// `0.5 + (0.1 − 0.5)` is `0.09999999999999998` in binary floating point. A vertical position
    /// that moved by one ulp on every aspect change would be a number the user cannot see and a
    /// diff that never stops, so the arithmetic is skipped where it is the identity.
    public static func point(_ p: NormalizedPoint, from source: Double?,
                             to target: Double?) -> NormalizedPoint {
        guard let s = source, let t = target,
              s.isFinite, t.isFinite, s > 0, t > 0, s != t else { return p }
        let fs = spans(aspect: s), ft = spans(aspect: t)
        let kx = fs.x / ft.x, ky = fs.y / ft.y
        return NormalizedPoint(kx == 1 ? p.x : 0.5 + (p.x - 0.5) * kx,
                               ky == 1 ? p.y : 0.5 + (p.y - 0.5) * ky)
    }

    /// One shape, carried across. Radii / angles / feather / samples are untouched: they are already
    /// short-edge normalised, and the transform is a similarity of that space.
    public static func shape(_ shape: MaskShape, from source: Double?,
                             to target: Double?) -> MaskShape {
        func move(_ p: NormalizedPoint) -> NormalizedPoint { point(p, from: source, to: target) }
        switch shape {
        case .linearGradient(var g):
            g.start = move(g.start)
            g.end = move(g.end)
            return .linearGradient(g)
        case .radialGradient(var g):
            g.center = move(g.center)
            return .radialGradient(g)
        case .brush(var b):
            // Flat `[x0, y0, x1, y1, …]`; an odd tail (a hand-written document) is left alone.
            b.strokes = b.strokes.map { stroke in
                var s = stroke
                var points = s.points
                var i = 0
                while i + 1 < points.count {
                    let p = move(NormalizedPoint(Double(points[i]), Double(points[i + 1])))
                    points[i] = Float(p.x)
                    points[i + 1] = Float(p.y)
                    i += 2
                }
                s.points = points
                return s
            }
            return .brush(b)
        // No geometry in the parameters: a colour/luminance predicate, an OS matte, or a kind this
        // build cannot interpret (which keeps its bytes and renders nothing — nothing to move).
        case .colorRange, .luminanceRange, .depthRange, .semantic, .unsupported:
            return shape
        }
    }

    /// The mask with its geometry carried across, **id untouched**.
    ///
    /// Equal or unknown aspects return the mask itself, so "same aspect ratio" is byte-for-byte the
    /// old behaviour rather than a value that happens to compare equal.
    public static func geometry(_ mask: Mask, from source: Double?, to target: Double?) -> Mask {
        guard let s = source, let t = target,
              s.isFinite, t.isFinite, s > 0, t > 0, s != t else { return mask }
        var out = mask
        out.components = mask.components.map { c in
            var c = c
            c.shape = shape(c.shape, from: s, to: t)
            return c
        }
        return out
    }

    /// A paste-ready copy: geometry carried across, **fresh mask and component ids** that are not in
    /// `takenIDs`. Shape, feather, opacity, invert, refine, name and every `LocalAdjustments` value
    /// are the source's — only identity is new.
    public static func copied(_ source: Mask, from sourceAspect: Double?, to targetAspect: Double?,
                              takenIDs: Set<String>) -> Mask {
        var out = geometry(source, from: sourceAspect, to: targetAspect)
        out.id = Mask.freshID(excluding: takenIDs)
        out.components = out.components.map { component in
            var c = component
            c.id = "c-\(UUID().uuidString)"
            return c
        }
        return out
    }
}
