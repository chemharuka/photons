import Foundation

// MARK: - heal / clone / remove — the spot model
//
// 078 P0-1 / B9 — Lightroom's 修复画笔: a **spot** that samples another part of the same picture.
// Two modes, and they are one operation with one difference:
//
//   · `clone` — copy the source disk. What the user asks for when the source *is* the answer
//     (a repeated texture, a clean patch of sky in a frame whose sky is uniform).
//   · `heal`  — copy the source disk **plus a smooth boundary correction**, so the copied texture
//     lands in the destination's own light and gradient instead of next to it. That correction is
//     Lightroom's Poisson step; this build's simplification of it is written out in
//     `Kernels/s1_9_heal.metal` (mean + first-harmonic match on the boundary ring) and stated as an
//     approximation with its error term.
//
// `remove` (the third Lightroom tool) is not a third mode: it is `heal` with the *content-aware*
// source search, which this version does not ship. The enum keeps two cases so a document can never
// claim a mode the renderer does not implement (a `remove` case that quietly behaved as `heal` would
// be a slider that lies).
//
// ## Coordinates — and this is the one place heal differs from a mask
//
// A mask is stored in **uncropped source** space (see `s1_5_mask_atlas.metal`): its predicate is
// evaluated while walking S0's mapping backwards, so a crop does not move a mask.
//
// A heal spot is stored in **frame** space — normalised to the cropped picture the user is looking
// at, `center ∈ [0,1]²`, `radius` and `sourceOffset` in **short-edge units** of that frame. Two
// reasons, both structural:
//
//   1. S1.9 runs **after S0**, on the canvas pixel grid (post crop, post turn, post straighten). The
//      spot therefore has to be an object of *that* grid: mapping a source-space centre forward
//      would need S0's whole transform again per pixel, and mapping each of the disk's samples
//      *back* would need its inverse — two transforms that can disagree, on the one stage whose
//      entire job is "the pixels under this disk".
//   2. The heal correction is a statement about the **picture as composed**: `sourceOffset` is a
//      pixel offset in the buffer the stage reads, and the ring it measures is a circle on the same
//      grid. In source space, the offset would be a *different* vector after a straighten, and the
//      disk would not be a disk.
//
// The cost is stated rather than hidden: a spot is anchored to the **frame**, so cropping reframes
// the spots (they keep their fractional position in the picture, like a vignette's centre) and a 90°
// turn carries them with the frame. Lightroom anchors spots to the image; anchoring to the frame is
// this version's choice, and `HealTests` pins what it does.

/// Heal or clone. Two cases, both implemented (`Kernels/s1_9_heal.metal`).
public enum HealMode: String, Sendable, Codable, CaseIterable {
    /// Source texture **+ boundary correction** (mean and gradient matched on the rim).
    case heal
    /// Source texture, verbatim.
    case clone

    public var label: String {
        switch self {
        case .heal: return "修复"
        case .clone: return "克隆"
        }
    }
}

/// One spot: a disk on the frame, a source offset, and how to blend.
public struct HealSpot: Sendable, Equatable, Codable, Hashable, Identifiable {
    /// Lightroom's own ceiling is 20-ish; the ceiling here is about cost, and 32 is what the apply
    /// pass's loop is sized for. Enforced by `EditModel.addHealSpot` (a document that carries more is
    /// still *rendered*, all of them — a document is data, and refusing to render what it says would
    /// be worse than a slow frame).
    public static let maxCount = 32

    /// `"h-<uuid>"`. Stable, and the only part of the identity that reaches a cache key.
    public var id: String
    /// Centre, normalised to the **cropped frame** (`0…1` of width, height).
    public var center: NormalizedPoint
    /// Radius, in **short-edge units** of the frame (0.005…0.5). `0.02` is 2 % of the short edge —
    /// about 32 px on a 4.1 Mpx frame, which is a blemish and not a subject.
    public var radius: Double
    /// Where the texture comes from, as a **pixel offset in short-edge units** (the same unit as
    /// `radius`, so 「偏移一个半径」 is `(radius, 0)`). Signed, and may leave the frame — the sampler
    /// clamps to the edge, which is what Lightroom does too.
    public var sourceOffset: NormalizedPoint
    public var mode: HealMode
    /// Blend ramp, as a fraction of the radius: `1` at `t ≤ 1 − feather`, `0` at `t = 1`.
    /// **0 means a hard edge** — every pixel with `t < 1` gets the source at full strength, which is
    /// the setting under which `clone` is a byte-for-byte copy (`HealTests`).
    public var feather: Double
    /// Multiplies the blend: `1` = the source replaces the destination inside the disk.
    public var opacity: Double

    public static let defaultRadius = 0.02
    public static let defaultFeather = 0.35
    public static let defaultOpacity = 1.0

    public init(id: String = "h-\(UUID().uuidString)",
                center: NormalizedPoint = NormalizedPoint(0.5, 0.5),
                radius: Double = HealSpot.defaultRadius,
                sourceOffset: NormalizedPoint = NormalizedPoint(HealSpot.defaultRadius * 2, 0),
                mode: HealMode = .heal,
                feather: Double = HealSpot.defaultFeather,
                opacity: Double = HealSpot.defaultOpacity) {
        self.id = id
        self.center = center
        self.radius = radius
        self.sourceOffset = sourceOffset
        self.mode = mode
        self.feather = feather
        self.opacity = opacity
    }

    // MARK: - the additive-decoding rule

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // Every key has an explicit default (`EditModel`'s document rule): a hand-written spot with
        // only a centre is a spot, not a decode failure.
        self.init(id: c.val("id", "h-\(UUID().uuidString)"),
                  center: c.val("center", NormalizedPoint(0.5, 0.5)),
                  radius: c.val("radius", HealSpot.defaultRadius),
                  sourceOffset: c.val("sourceOffset",
                                      NormalizedPoint(HealSpot.defaultRadius * 2, 0)),
                  mode: c.val("mode", HealMode.heal),
                  feather: c.val("feather", HealSpot.defaultFeather),
                  opacity: c.val("opacity", HealSpot.defaultOpacity))
        self.radius = clampedRadius
        self.feather = min(max(feather, 0), 0.999)
        self.opacity = min(max(opacity, 0), 1)
    }

    // MARK: - clamping

    /// `0.002…0.5`. A spot of radius 0 is a spot that writes nothing (and would divide by zero in
    /// the kernel's `t = |p − c| / r`); a spot of radius 0.5 is most of the frame, which is the
    /// ceiling of "this is still a *spot*".
    public var clampedRadius: Double { min(max(radius, 0.002), 0.5) }

    /// The spot with every out-of-range number brought inside its travel. `EditModel.addHealSpot`
    /// applies it, and so does a document read back from disk — a hand-edited `radius: 9` must not
    /// produce a disk that covers the frame with a `t` that never reaches 1.
    public var clamped: HealSpot {
        var v = self
        v.radius = clampedRadius
        v.feather = min(max(feather, 0), 0.999)
        v.opacity = min(max(opacity, 0), 1)
        v.center = NormalizedPoint(min(max(center.x, 0), 1), min(max(center.y, 0), 1))
        return v
    }

    /// The key material: the values the S1.9 pass reads, quantised to the canonical `1e-5`
    /// (`k(_:)`). `id` is **not** here — it is identity, not arithmetic, and two spots with the same
    /// geometry produce the same pixels; the cache key is the whole list's text, so a reordering of
    /// two identical spots would move a key for nothing. That is the mask rule (`Mask.selectionKey`
    /// keeps the id, because a mask's id names a slice) read the other way: a spot has no slice, so
    /// its id is only a document handle.
    public var keyString: String {
        "c=\(center.keyString);r=\(k(clampedRadius));so=\(sourceOffset.keyString)"
            + ";mode=\(mode.rawValue);f=\(k(feather));op=\(k(opacity))"
    }

    // MARK: - the default source

    /// The default source offset: one radius to the **right**, which is Lightroom's own first guess
    /// (it then lets you drag it). `2·radius` — the source disk touches the destination disk rather
    /// than overlapping it, so a `heal` spot never samples the blemish it is asked to remove.
    public static func defaultSourceOffset(radius: Double) -> NormalizedPoint {
        NormalizedPoint(radius * 2, 0)
    }
}

// MARK: - document helpers

extension EditModel {

    /// Does S1.9 exist for this document? Judged **by value** — the presence of at least one spot,
    /// the same way `hasGrain`/`hasHSL` are judged. A document with no spot keeps the pre-S1.9 stage
    /// list, key chain and pixels byte for byte: the pass is not encoded at all.
    public var hasHeal: Bool { !healSpots.isEmpty }

    /// The spots S1.9 renders, in document order (composition order — a later spot may overwrite an
    /// earlier one, exactly like a stack of layers).
    public var activeHealSpots: [HealSpot] { healSpots }

    /// Append a spot. Returns `nil` when the document is full (`HealSpot.maxCount`) or the spot
    /// would render nothing (`opacity == 0`), so a UI click can never mint an undo step for a spot
    /// that changes no pixel.
    @discardableResult
    public mutating func addHealSpot(_ spot: HealSpot) -> HealSpot? {
        guard healSpots.count < HealSpot.maxCount else { return nil }
        guard spot.opacity > 0 else { return nil }
        let landed = spot.clamped
        healSpots.append(landed)
        return landed
    }

    /// Remove a spot. `false` when no such id — so the caller does not commit a no-op.
    @discardableResult
    public mutating func removeHealSpot(_ id: String) -> Bool {
        let before = healSpots.count
        healSpots.removeAll { $0.id == id }
        return healSpots.count != before
    }
}
