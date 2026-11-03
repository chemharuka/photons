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
// **This version does ship the automatic source search** (`HealSpot.searchSource`): a ring-band SSD
// search in the `2r…4r` annulus, with a coarse 16×16 pass and a full-resolution shortlist. `remove`
// is still not a third mode, though — it would be `heal` with a *content-aware* source, and the enum
// keeps two cases so a document can never claim a mode the renderer does not implement (a `remove`
// case that quietly behaved as `heal` would be a slider that lies).
//
// ## What the search reads
//
// `searchSource` reads an **already decoded `LinearImage`** in **S1 source pixels** — since 249 the
// same space a `HealSpot` is stored in — so the centre and radius it is handed mean exactly what they
// mean to the renderer. The UI hands it the raw upright decode (`decoded?.oriented()`); a crop,
// straighten or keystone is *after* this pass and therefore cannot make the ring measure a different
// picture.
//
// ## Coordinates — S1 source pixels (249)
//
// A heal spot is stored in **S1 source pixels** (`docs/coordinate-spaces.md`): `center ∈ [0,1]²`
// relative to the **whole upright photograph** (the decoded grid, before perspective / straighten /
// crop / the 90° turn), and `radius` / `sourceOffset` in **short-edge units of S1**. The repair pass
// therefore runs *before* S0 (`RenderGraph` visits `.heal` first); S0 then turns/crops/keystones the
// already-repaired pixels. That is the user's rule: 「修复统一应用在原图像上，然后再应用变换卡片的操作」.
//
// **2026-11-02 decision (do not move without re-reading 252).** darktable, RawTherapee, ART and
// RapidRAW all store spot coordinates in image space. We choose S1 — before perspective, rotation
// and crop — because:
//
//   1. A keystone is a strong warp. Healing before it means a perspective edit only deforms the
//      patch; healing after it would recompute a different patch on every keystone move (visible
//      flicker).
//   2. Today's repair is "sample a disk + fit a plane on its rim" and does not understand structure,
//      so sampling on the corrected canvas buys no quality yet.
//
// **When to revisit:** only if structural repair (252's candidate C4/C5) lands. Then the pass may
// move to "after perspective+rotation, before crop" (darktable's position) — a move, not a rewrite,
// because 246 split geometry into three terms. Until then this stays S1, and the same note lives in
// `Kernels/s1_9_heal.metal` and `RenderStage.heal`.
//
// Consequences, stated rather than hidden:
//
//   · A click is mapped back through the **one** geometry inverse (`FrameTransform.viewPointToSource`
//     → the raw-source quarter-turn rename) so a straightened/keystoned document writes the source
//     pixel under the cursor, not a canvas pixel.
//   · Masks (S1.6) now act on the **already-repaired** picture. That is the requested order; no
//     compensation layer is added.
//   · Documents written before 249 stored canvas-v1 coordinates. `healSpace` marks the space and
//     `migrateHealSpots(sourceSize:)` converts on load (or, if the frame is not known yet, the
//     renderer converts at draw time through the same function).

/// 229 — what a spot is *for*. A red-eye spot is a **heal preset**: the same disk, the same source
/// search, the same S1.9 blend, with a red gate in front of the blend and a per-spot threshold.
///
/// The case is additive in the document: an absent `kind` reads `.heal` and a `.heal` spot is
/// encoded without the key, so every pre-229 `healSpots` array re-encodes byte for byte.
public enum HealSpotKind: String, Sendable, Codable, CaseIterable {
    /// 修复 / 克隆 — the pre-229 behaviour, byte for byte.
    case heal
    /// 红眼 — only pixels the red test accepts are replaced.
    case redeye

    public var label: String {
        switch self {
        case .heal: return "修复"
        case .redeye: return "红眼"
        }
    }
}

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

/// Why `HealSpot.searchSource` answered the way it did. **Never silent**: a caller that gets
/// `.noCandidateAccepted` or `.searchSkipped` also gets the legacy `(2r, 0)` offset, and the two
/// are distinguishable from `.found` without inspecting numbers.
public enum HealSourceStatus: String, Sendable, Codable, Equatable, CaseIterable {
    /// A candidate passed every filter; `offset` is where it is.
    case found
    /// The whole `2r…4r` band was rejected (too close / outside the frame / no texture to copy).
    /// The offset is the legacy `(2r, 0)` and the caller is expected to say so.
    case noCandidateAccepted
    /// Nothing to search: auto source off, no frame in hand, a frame too small, or a radius that
    /// degenerates. Legacy `(2r, 0)`.
    case searchSkipped

    public var label: String {
        switch self {
        case .found: return "已取源"
        case .noCandidateAccepted: return "带内无可用源"
        case .searchSkipped: return "未搜索"
        }
    }
}

/// One search's answer: the offset to write, why, and enough numbers to audit it.
public struct HealSourceResult: Sendable, Equatable {
    /// Short-edge units, the same unit as `radius`.
    public let offset: NormalizedPoint
    public let status: HealSourceStatus
    /// Candidates the coarse pass scored.
    public let examined: Int
    /// Candidates that survived every filter.
    public let accepted: Int
    /// Full-res SSD per sample at the winner (`0` otherwise).
    public let score: Double
    /// `|offset| / radius` at the winner (`0` otherwise).
    public let distanceInRadii: Double

    public init(offset: NormalizedPoint, status: HealSourceStatus, examined: Int,
                accepted: Int, score: Double, distanceInRadii: Double) {
        self.offset = offset
        self.status = status
        self.examined = examined
        self.accepted = accepted
        self.score = score
        self.distanceInRadii = distanceInRadii
    }

    /// The legacy answer, explicitly labelled: `(2r, 0)` in short-edge units.
    public static func skipped(radius: Double,
                               status: HealSourceStatus = .searchSkipped) -> HealSourceResult {
        HealSourceResult(offset: HealSpot.defaultSourceOffset(radius: radius), status: status,
                         examined: 0, accepted: 0, score: 0, distanceInRadii: 0)
    }
}

/// 249 — which coordinate space a stored spot is written in.
///
/// `.canvasV1` is the pre-249 layout: `center` was normalised to the cropped frame (S2), radius and
/// offset in that frame's short-edge units. **No marker means `.canvasV1`** — a document that never
/// carried the key must be converted, never guessed to be new. `.sourceV2` is S1 source pixels and is
/// what every new spot writes.
public enum HealSpotSpace: String, Sendable, Codable, Equatable, CaseIterable {
    case canvasV1
    case sourceV2
}

/// One spot: a disk in S1 source pixels, a source offset, and how to blend.
public struct HealSpot: Sendable, Equatable, Codable, Hashable, Identifiable {
    /// Lightroom's own ceiling is 20-ish; the ceiling here is about cost, and 32 is what the apply
    /// pass's loop is sized for. Enforced by `EditModel.addHealSpot` (a document that carries more is
    /// still *rendered*, all of them — a document is data, and refusing to render what it says would
    /// be worse than a slow frame).
    public static let maxCount = 32

    /// `"h-<uuid>"`. Stable, and the only part of the identity that reaches a cache key.
    public var id: String
    /// Centre, normalised to the **whole upright S1 photograph** (`0…1` of width, height). A quarter
    /// turn does not move it: the spot is anchored to the pixels, not to the frame.
    public var center: NormalizedPoint
    /// Radius, in **S1 short-edge units** (`HealSpot.radiusRange`). `0.02` is 2 % of the short edge —
    /// about 32 px on a 4.1 Mpx frame, which is a blemish and not a subject.
    public var radius: Double
    /// Where the texture comes from, as an S1 **pixel offset in short-edge units** (the same unit as
    /// `radius`, so 「偏移一个半径」 is `(radius, 0)`). Signed, and may leave the photograph — the
    /// sampler clamps to the edge, which is what Lightroom does too.
    public var sourceOffset: NormalizedPoint
    /// 249 — the space `center` / `radius` / `sourceOffset` are written in. Absent on disk means
    /// `.canvasV1` (see `HealSpotSpace`).
    public var healSpace: HealSpotSpace
    public var mode: HealMode
    /// Blend ramp, as a fraction of the radius: `1` at `t ≤ 1 − feather`, `0` at `t = 1`.
    /// **0 means a hard edge** — every pixel with `t < 1` gets the source at full strength, which is
    /// the setting under which `clone` is a byte-for-byte copy (`HealTests`).
    public var feather: Double
    /// Multiplies the blend: `1` = the source replaces the destination inside the disk.
    public var opacity: Double
    /// 229 — heal (default) or red-eye. A red-eye spot is rendered by the same S1.9 pass with the
    /// per-pixel red gate described in `RedEye`.
    public var kind: HealSpotKind
    /// 229 — the red gate's threshold, in **display-encoded** redness
    /// (`sRGB(r) − max(sRGB(g), sRGB(b))`). The kernel applies the same curve, so the CPU detector
    /// and the renderer cannot disagree about what "red" means. `RedEye.noopThreshold` is the
    /// sentinel a click with no detected pupil writes: no pixel can pass it, so the spot is a
    /// history row that changes nothing.
    public var redThreshold: Double
    /// 229 — half-width of the red gate's ramp. `0` is a hard threshold.
    public var redSoftness: Double

    /// The nested spelling (`HealSpot.Kind.redeye`) and the top-level one (`HealSpotKind.redeye`)
    /// are the same type; the spec talks about a spot's `kind`, so both read naturally.
    public typealias Kind = HealSpotKind

    // MARK: - identity
    //
    // The red gate is arithmetic only for `.redeye`. A `.heal` spot ignores those two fields in
    // equality/hashing (the same rule `keyString` follows), so a spot written before 229 — or by a
    // build with a different default — is the same spot, not a document change.

    public static func == (lhs: HealSpot, rhs: HealSpot) -> Bool {
        guard lhs.id == rhs.id, lhs.center == rhs.center, lhs.radius == rhs.radius,
              lhs.sourceOffset == rhs.sourceOffset, lhs.mode == rhs.mode,
              lhs.feather == rhs.feather, lhs.opacity == rhs.opacity,
              lhs.kind == rhs.kind, lhs.healSpace == rhs.healSpace else { return false }
        guard lhs.kind == .redeye else { return true }
        return lhs.redThreshold == rhs.redThreshold && lhs.redSoftness == rhs.redSoftness
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(center)
        hasher.combine(radius)
        hasher.combine(sourceOffset)
        hasher.combine(mode)
        hasher.combine(feather)
        hasher.combine(opacity)
        hasher.combine(kind)
        hasher.combine(healSpace)
        if kind == .redeye {
            hasher.combine(redThreshold)
            hasher.combine(redSoftness)
        }
    }

    /// The legal radius travel, in short-edge units. One definition for the model, the canvas and
    /// the card's slider: a spot of radius 0 writes nothing (and would divide by zero in the
    /// kernel's `t = |p − c| / r`), and `0.5` is the ceiling of "this is still a *spot*".
    public static let radiusRange: ClosedRange<Double> = 0.002 ... 0.5

    public static let defaultRadius = 0.02
    public static let defaultFeather = 0.35
    public static let defaultOpacity = 1.0

    public init(id: String = "h-\(UUID().uuidString)",
                center: NormalizedPoint = NormalizedPoint(0.5, 0.5),
                radius: Double = HealSpot.defaultRadius,
                sourceOffset: NormalizedPoint = NormalizedPoint(HealSpot.defaultRadius * 2, 0),
                mode: HealMode = .heal,
                feather: Double = HealSpot.defaultFeather,
                opacity: Double = HealSpot.defaultOpacity,
                kind: HealSpotKind = .heal,
                redThreshold: Double = RedEye.defaultThreshold,
                redSoftness: Double = RedEye.defaultSoftness,
                healSpace: HealSpotSpace = .sourceV2) {
        self.id = id
        self.center = center
        self.radius = radius
        self.sourceOffset = sourceOffset
        self.mode = mode
        self.feather = feather
        self.opacity = opacity
        self.kind = kind
        self.redThreshold = redThreshold
        self.redSoftness = redSoftness
        self.healSpace = healSpace
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
                  opacity: c.val("opacity", HealSpot.defaultOpacity),
                  kind: c.val("kind", HealSpotKind.heal),
                  redThreshold: c.val("redThreshold", RedEye.defaultThreshold),
                  redSoftness: c.val("redSoftness", RedEye.defaultSoftness),
                  // 249 — **absent means canvasV1**, never a guess (spec §5.3).
                  healSpace: c.val("healSpace", HealSpotSpace.canvasV1))
        self.radius = clampedRadius
        self.feather = min(max(feather, 0), 0.999)
        self.opacity = min(max(opacity, 0), 1)
        self.redThreshold = min(max(redThreshold, 0), RedEye.noopThreshold)
        self.redSoftness = min(max(redSoftness, 0), 0.5)
    }

    /// Explicit, and deliberately the pre-229 key set for `.heal`: a document on disk re-encodes
    /// byte for byte. Only a red-eye spot carries the three new keys.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(center, forKey: AnyCodingKey("center"))
        try c.encode(radius, forKey: AnyCodingKey("radius"))
        try c.encode(sourceOffset, forKey: AnyCodingKey("sourceOffset"))
        try c.encode(mode, forKey: AnyCodingKey("mode"))
        try c.encode(feather, forKey: AnyCodingKey("feather"))
        try c.encode(opacity, forKey: AnyCodingKey("opacity"))
        // 249 — a pre-249 blob carried no marker; keep it that way until the spot is migrated, so an
        // untouched old document still re-encodes byte for byte. New spots write the marker.
        if healSpace == .sourceV2 {
            try c.encode(healSpace, forKey: AnyCodingKey("healSpace"))
        }
        guard kind != .heal else { return }
        try c.encode(kind, forKey: AnyCodingKey("kind"))
        try c.encode(redThreshold, forKey: AnyCodingKey("redThreshold"))
        try c.encode(redSoftness, forKey: AnyCodingKey("redSoftness"))
    }

    // MARK: - clamping

    /// `HealSpot.radiusRange` (`0.002…0.5`) — the same travel the card's slider and the canvas'
    /// wheel/keys use.
    public var clampedRadius: Double {
        min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
    }

    /// The spot with every out-of-range number brought inside its travel. `EditModel.addHealSpot`
    /// applies it, and so does a document read back from disk — a hand-edited `radius: 9` must not
    /// produce a disk that covers the frame with a `t` that never reaches 1.
    public var clamped: HealSpot {
        var v = self
        v.radius = clampedRadius
        v.feather = min(max(feather, 0), 0.999)
        v.opacity = min(max(opacity, 0), 1)
        v.center = NormalizedPoint(min(max(center.x, 0), 1), min(max(center.y, 0), 1))
        v.redThreshold = min(max(redThreshold, 0), RedEye.noopThreshold)
        v.redSoftness = min(max(redSoftness, 0), 0.5)
        return v
    }

    /// The key material: the values the S1.9 pass reads, quantised to the canonical `1e-5`
    /// (`k(_:)`). `id` is **not** here — it is identity, not arithmetic, and two spots with the same
    /// geometry produce the same pixels; the cache key is the whole list's text, so a reordering of
    /// two identical spots would move a key for nothing. That is the mask rule (`Mask.selectionKey`
    /// keeps the id, because a mask's id names a slice) read the other way: a spot has no slice, so
    /// its id is only a document handle.
    public var keyString: String {
        let base = "c=\(center.keyString);r=\(k(clampedRadius));so=\(sourceOffset.keyString)"
            + ";mode=\(mode.rawValue);f=\(k(feather));op=\(k(opacity))"
        // 249 — the space is arithmetic: the same numbers in canvasV1 and sourceV2 are different
        // pixels. Only the legacy spelling carries a token, so new spots keep the pre-249 key text
        // plus the new `;alg` (the source point itself is already in the numbers).
        let space = healSpace == .canvasV1 ? ";space=canvasV1" : ""
        // A heal spot's key is untouched (pre-229 documents and caches keep their answer). Only the
        // red gate changes pixels, so only a red-eye spot's key carries it.
        guard kind != .heal else { return base + space }
        return base + space + ";kind=redeye;rt=\(k(redThreshold));rs=\(k(redSoftness))"
    }

    // MARK: - the default source

    /// The default source offset: one radius to the **right**, which is Lightroom's own first guess
    /// (it then lets you drag it). `2·radius` — the source disk touches the destination disk rather
    /// than overlapping it, so a `heal` spot never samples the blemish it is asked to remove.
    public static func defaultSourceOffset(radius: Double) -> NormalizedPoint {
        NormalizedPoint(radius * 2, 0)
    }

    // MARK: - 249 · S1 source ⇄ turned source
    //
    // The geometry helpers speak the **turned** S1 frame (`CropGeometry.source`: the quarter turn is
    // already applied), while a spot is stored in the **raw** S1 frame (the decoded buffer, before the
    // 90° turn) so pressing 旋转 does not move it. These two names are the only conversion between
    // the two; they are axis renames, not geometry, and the view↔source inverse stays in
    // `FrameTransform`.

    /// A normalized point in the turned source frame → the raw (decoded) source frame.
    public static func sourcePoint(fromTurned point: NormalizedPoint,
                                   quarterTurns: Int) -> NormalizedPoint {
        CropMath.turned(point, quarterTurns: (4 - normalizedTurns(quarterTurns)) % 4)
    }

    /// A normalized point in the raw source frame → the turned source frame.
    public static func turnedPoint(fromSource point: NormalizedPoint,
                                   quarterTurns: Int) -> NormalizedPoint {
        CropMath.turned(point, quarterTurns: normalizedTurns(quarterTurns))
    }

    private static func normalizedTurns(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    /// 249 — a pre-249 (canvasV1) spot in S1 source coordinates.
    ///
    /// `canvasV1` stored `center` normalised to the **cropped frame** (S2) and placed it on the
    /// S1.9 canvas as `inset + center·frameSize` (the old `RenderGraph.healSpotU`). To keep the same
    /// picture feature covered, this reconstructs that canvas point, walks it back through the
    /// document's geometry (`FrameTransform.s3ToS1`, the one inverse — perspective included), then
    /// renames the turned source frame to raw source. Radius scales from the frame's short edge to
    /// S1's (the same edge only for a full crop), and the offset is the **difference of the two
    /// mapped endpoints**, so straighten/perspective are part of the vector too.
    public func migratedToSourceV2(sourceSize: ImageSize, geometry: GeometryGroup) -> HealSpot {
        guard healSpace == .canvasV1 else { return self }
        let cg = CropGeometry(geometry: geometry, source: sourceSize)
        let frame = cg.frameSize
        let canvas = cg.canvas
        let inset = cg.canvasInsetPixels
        let frameShort = Double(min(frame.width, frame.height))
        let sourceShort = Double(min(max(cg.source.width, 1), max(cg.source.height, 1)))
        let transform = FrameTransform(
            source: cg.source, crop: cg.crop,
            straightenDegrees: cg.rotationDegrees, quarterTurns: 0,
            flipHorizontal: cg.flipHorizontal, flipVertical: cg.flipVertical,
            perspective: cg.perspective,
            contentScale: 1, viewport: nil, zoom: 1, cameraOffset: .zero,
            cameraWindowSize: SIMD2(Double(canvas.width), Double(canvas.height)),
            allowsUpscale: true)
        // The old kernel placed `center` at `inset + center·frameSize` and the source disk at that
        // point **plus** `sourceOffset·min(frameSize)` in canvas axes. Map both endpoints back
        // through the same inverse (perspective and straighten included) and take the difference:
        // a vector is not a point, so it must not skip the local Jacobian of the warp.
        let oldCenter = SIMD2<Double>(Double(inset.x) + center.x * Double(frame.width),
                                      Double(inset.y) + center.y * Double(frame.height))
        let oldSource = oldCenter + SIMD2<Double>(sourceOffset.x * frameShort,
                                                  sourceOffset.y * frameShort)
        func sourcePixels(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let v = transform.s3ToS1.applying(to: SIMD3(p.x, p.y, 1))
            let w = v.z == 0 ? 1 : v.z
            let turned = NormalizedPoint(v.x / w / Double(max(cg.source.width, 1)),
                                         v.y / w / Double(max(cg.source.height, 1)))
            let raw = HealSpot.sourcePoint(fromTurned: turned, quarterTurns: cg.quarterTurns)
            return SIMD2(raw.x * Double(sourceSize.width), raw.y * Double(sourceSize.height))
        }
        let centerPx = sourcePixels(oldCenter)
        let sourcePx = sourcePixels(oldSource)
        let factor = sourceShort > 0 && frameShort > 0 ? frameShort / sourceShort : 1
        var out = self
        out.center = NormalizedPoint(
            min(max(centerPx.x / Double(max(sourceSize.width, 1)), 0), 1),
            min(max(centerPx.y / Double(max(sourceSize.height, 1)), 0), 1))
        out.radius = radius * factor
        out.sourceOffset = NormalizedPoint(
            (sourcePx.x - centerPx.x) / sourceShort,
            (sourcePx.y - centerPx.y) / sourceShort)
        out.healSpace = .sourceV2
        return out.clamped
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

    /// 249 — the spots as S1 source coordinates. Already-migrated documents are returned unchanged
    /// (no copy of the geometry path); a legacy document is converted with its own geometry and the
    /// **exact** source frame. The renderer uses this so a canvasV1 document that was never loaded
    /// through a session (a thumbnail, an export, `photonsctl`) still lands on the same pixels.
    public func migratedHealSpots(sourceSize: ImageSize) -> [HealSpot] {
        guard healSpots.contains(where: { $0.healSpace == .canvasV1 }) else { return healSpots }
        return healSpots.map { $0.migratedToSourceV2(sourceSize: sourceSize, geometry: geometry) }
    }

    /// 249 — convert every canvasV1 spot in place. Returns `true` when something moved, so a caller
    /// can persist the new marker without minting a history row.
    @discardableResult
    public mutating func migrateHealSpots(sourceSize: ImageSize) -> Bool {
        guard healSpots.contains(where: { $0.healSpace == .canvasV1 }) else { return false }
        healSpots = healSpots.map {
            $0.migratedToSourceV2(sourceSize: sourceSize, geometry: geometry)
        }
        return true
    }

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

// MARK: - the automatic source
//
// 184 — 「点一下就好」. The click already places the spot; the *source* is the part of the job the
// user used to do by hand.
//
// ## What is measured — and why it is not a raw SSD
//
// The kernel (`s1_9_heal.metal`) copies the source disk and adds a plane fitted on the rim:
//
//     out = src(q + o) + P(q),    P = a₀ + a₁u + b₁v = least squares of (dst − src) on the rim
//
// so the only difference a *source* can be blamed for is what that plane cannot absorb. The search
// therefore scores a candidate by exactly that — the **plane-corrected** SSD of the rim ring:
//
//     score = mean over the rim of ((dst − src) − P)²
//
// It is zero for a source whose rim differs from the destination's by an affine map (a linear
// gradient, an exposure or slope difference — the kernel removes those exactly) and large for one
// that differs in *structure*: a blemish inside the ring, a texture out of phase, a wall that is
// smoother than the one being repaired. A raw SSD would rank the first case by its brightness offset,
// which is the very thing the kernel removes, and would then prefer whichever corner of a flat wall
// happened to have the same mean.
//
// ## The two stages
//
// 336 candidates (7 radii × 48 angles over the `2r…4r` band) each need a patch comparison. The
// **coarse** stage builds a 16 × 16 grayscale grid over the 3r patch (`cellPx = 3r/16`),
// **point-sampled** two texels per cell on the diagonal, straight from the decoded buffer — never a
// full copy of the picture, which is what keeps this at ~5 ms on a 60 Mpx frame (measured) and off
// the heap. It scores
// every candidate on the ring cells and keeps the best; the **full-resolution** stage re-scores a
// shortlist of four on 8 concentric circles × 24 angles (192 texels, the ring the kernel reads) and
// that `score` is the one reported. The cost is therefore `336 × ~110` coarse multiply-adds plus
// `4 × 192` full-resolution ones — independent of the frame's size.
//
// ## Filters — all of them named, none of them silent
//
//   · `d ≥ 1.5r` — a source disk closer than that would sit on the defect it is asked to replace.
//   · the 3r patch inside the frame — the sampler clamps at the edge, but a clamped source is not a
//     source the user can see; a candidate off the picture is skipped rather than clamped.
//   · `σ ≥ 1e-3` on **both** rings — about 0.3 of an 8-bit code in linear light. A flat wall is not a
//     texture, so copying it into a blemish that sits in texture is the 「糊」 case; and a
//     *destination* rim without contrast means the rim is itself inside the blemish (the spot is
//     smaller than the defect), so the plane would be fitted to the defect and every candidate would
//     look acceptable against it. Both cases are refused, with the named status, rather than
//     answered with a plausible-looking patch (acceptance C).
//   · `σ_c ≥ 0.4 σ_d` — the source must carry at least two-fifths of the destination's contrast.
//
// There is deliberately **no absolute quality ceiling** on the winner's residual. On real detail the
// per-texel ring residual of a *good* source is 0.9–1.3 σ (measured on `L1030433.dng`, 60 Mpx, at
// `3.3r`: rms 0.049–0.059 against σ 0.040–0.058), so any "the residual must be small" gate rejects
// real photographs while looking principled on a synthetic one. What the search can honestly refuse
// is *structural*: a rim with nothing to fit (the spot is smaller than the blemish) and a band with
// nowhere to put a patch (a radius so large, or a frame so tight, that every candidate runs off the
// picture). Everything else is answered with the least-bad candidate and that candidate's `score`,
// which the panel shows — a number the user can judge, rather than a patch presented as a fact.
//
// When nothing survives, the answer is `(2r, 0)` **with `.noCandidateAccepted`** — a fallback the
// caller cannot see is exactly the silent wrong answer this task exists to avoid. Ties (a tenth of
// the local contrast) go to the candidate further from the defect, and that preference is applied
// when the shortlist is chosen, so a wide flat wall really does get its far corner rather than the
// first tie the sort happened to emit.

extension HealSpot {

    /// Contrast a ring must carry before it can be a source, in linear light (≈ 0.3 of an 8-bit code).
    static let contrastFloor = 1e-3

    /// `Float16` → `Float`, bit-exact, without the per-sample stdlib call a debug build pays for
    /// `Float(_:)`. Same bits, same rounding: the search never sees a different picture.
    @inline(__always)
    static func halfToFloat(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = UInt32(half & 0x7C00)
        let mantissa = UInt32(half & 0x03FF)
        if exponent == 0 {
            guard mantissa != 0 else { return Float(bitPattern: sign) }
            var m = mantissa
            var e = -14
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            return Float(bitPattern: sign | (UInt32(e + 127) << 23) | ((m & 0x03FF) << 13))
        }
        if exponent == 0x7C00 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | (((exponent >> 10) + 112) << 23) | (mantissa << 13))
    }

    /// Find a source for a spot at `center` / `radius` in `image`. See the section comment above for
    /// the metric, the two stages and every filter; `.noCandidateAccepted` always comes with the
    /// legacy `(2r, 0)` offset so a caller can still draw the spot it asked for.
    public static func searchSource(in image: LinearImage,
                                    center: NormalizedPoint,
                                    radius: Double,
                                    downsample: Int = 16,
                                    shortlist: Int = 4) -> HealSourceResult {
        let w = image.width
        let h = image.height
        let shortEdge = Double(min(w, h))
        guard radius.isFinite, radius > 0, shortEdge >= 16 else { return .skipped(radius: radius) }
        let r = radius * shortEdge
        guard r >= 2 else { return .skipped(radius: radius) }

        let cx = center.x * Double(w)
        let cy = center.y * Double(h)
        // The rim the kernel fits lives at `r`; if that circle is not on the picture there is nothing
        // to fit and nothing to search.
        guard cx - r >= 0, cx + r <= Double(w), cy - r >= 0, cy + r <= Double(h) else {
            return .skipped(radius: radius)
        }

        let cells = max(6, min(64, downsample))
        let cellPx = 3.0 * r / Double(cells)      // one coarse cell, in pixels
        let reach = 5.5 * r                        // 4r of search + 1.5r of patch
        let gx = cx - reach
        let gy = cy - reach
        let gw = Int((2 * reach) / cellPx) + 2     // the coarse grid covers every ring sample

        return image.rgba.withUnsafeBufferPointer { buf -> HealSourceResult in

            /// Luminance of one texel, straight from the decoded buffer — the only way this function
            /// reads the picture, so the search cannot see a different picture than the renderer.
            @inline(__always)
            func luma(_ x: Int, _ y: Int) -> Double {
                let o = (y * w + x) * 4
                return 0.2126 * Double(HealSpot.halfToFloat(buf[o].bitPattern))
                    + 0.7152 * Double(HealSpot.halfToFloat(buf[o + 1].bitPattern))
                    + 0.0722 * Double(HealSpot.halfToFloat(buf[o + 2].bitPattern))
            }

            // 1. The coarse grid: 2 × 2 point samples per cell. Off-picture cells stay NaN and are
            //    skipped below, so a candidate that would need one is skipped rather than clamped.
            // Two samples per cell, on the diagonal: at `cellPx ≈ 0.19r` (5.6 px at r = 30) the cell
            // is small enough that a pair is already its own average, and the ring sums 110 of them.
            var coarse = [Double](repeating: .nan, count: gw * gw)
            for j in 0..<gw {
                let yBase = gy + Double(j) * cellPx
                for i in 0..<gw {
                    let xBase = gx + Double(i) * cellPx
                    let ax = Int(xBase + 0.3 * cellPx)
                    let ay = Int(yBase + 0.3 * cellPx)
                    let bx = Int(xBase + 0.7 * cellPx)
                    let by = Int(yBase + 0.7 * cellPx)
                    guard ax >= 0, ax < w, bx >= 0, bx < w,
                          ay >= 0, ay < h, by >= 0, by < h else { continue }
                    coarse[j * gw + i] = 0.5 * (luma(ax, ay) + luma(bx, by))
                }
            }

            // 2. The rim ring on the coarse grid — cell offsets from the patch centre plus the
            //    plane's basis (u, v) on the unit circle, the same basis the kernel's fit uses.
            let originX = Int((cx - gx) / cellPx)
            let originY = Int((cy - gy) / cellPx)
            // `maskFlat` is `du + dv·gw`, so a candidate's cell is one addition away from its own
            // base index — the inner loop of the whole search, kept to an add and a multiply-add.
            var maskFlat: [Int] = []
            var maskU: [Double] = []
            var maskV: [Double] = []
            var dstRing: [Double] = []
            var seen = Set<Int>()
            for v in 0..<cells {
                let oy = -1.5 * r + (Double(v) + 0.5) * cellPx
                for u in 0..<cells {
                    let ox = -1.5 * r + (Double(u) + 0.5) * cellPx
                    let len = (ox * ox + oy * oy).squareRoot()
                    // The ring is the annulus just outside the disk: `r … 1.45r`, one cell wide.
                    guard len >= 1.00 * r, len <= 1.45 * r else { continue }
                    let dx = Int((ox / cellPx).rounded())
                    let dy = Int((oy / cellPx).rounded())
                    let key = (dx + 512) * 1024 + (dy + 512)
                    guard seen.insert(key).inserted else { continue }
                    let i = originX + dx
                    let j = originY + dy
                    guard i >= 0, i < gw, j >= 0, j < gw else { continue }
                    let value = coarse[j * gw + i]
                    guard !value.isNaN else { continue }
                    maskFlat.append(dx + dy * gw)
                    maskU.append(ox / len)
                    maskV.append(oy / len)
                    dstRing.append(value)
                }
            }
            let n = dstRing.count
            guard n >= 24 else { return .skipped(radius: radius) }

            let nD = Double(n)
            var dstSum = 0.0
            var dstSq = 0.0
            for k in 0..<n {
                dstSum += dstRing[k]
                dstSq += dstRing[k] * dstRing[k]
            }
            let dstMean = dstSum / nD
            let sigmaD = max(0, dstSq / nD - dstMean * dstMean).squareRoot()
            // A rim without contrast has nothing to fit: it is the inside of a blemish larger than the
            // spot. Refused by name (acceptance C) — the alternative is a plausible patch that the
            // plane then poisons.
            guard sigmaD >= HealSpot.contrastFloor else {
                return HealSourceResult(offset: defaultSourceOffset(radius: radius),
                                        status: .noCandidateAccepted,
                                        examined: 0, accepted: 0, score: 0, distanceInRadii: 0)
            }

            // 3. The 2r…4r band: 7 radii × 48 angles.
            let radialSteps = 7
            let angularSteps = 48
            let patch = 1.5 * r
            var ranked: [(px: Double, py: Double, d: Double, score: Double)] = []
            ranked.reserveCapacity(radialSteps * angularSteps)
            var examined = 0

            for radial in 0..<radialSteps {
                let d = 2.0 * r + Double(radial) * (2.0 * r / Double(radialSteps - 1))
                // Spec §3: a centre closer than 1.5r would put the source disk on the defect. With
                // this schedule it is never true; kept as a hard condition so a change to the
                // schedule cannot silently reintroduce the overlap.
                guard d >= 1.5 * r else { continue }
                for angular in 0..<angularSteps {
                    let theta = 2.0 * Double.pi * Double(angular) / Double(angularSteps)
                    let px = cx + d * cos(theta)
                    let py = cy + d * sin(theta)
                    guard px - patch >= 0, px + patch <= Double(w),
                          py - patch >= 0, py + patch <= Double(h) else { continue }
                    let ci = Int((px - gx) / cellPx)
                    let cj = Int((py - gy) / cellPx)
                    let base = ci + cj * gw
                    let last = gw * gw - 1

                    var s0 = 0.0       // Σ (dst − src)
                    var s1 = 0.0       // Σ (dst − src)·u
                    var s2 = 0.0       // Σ (dst − src)·v
                    var q2 = 0.0       // Σ (dst − src)²
                    var cSum = 0.0
                    var cSq = 0.0
                    var onGrid = true
                    for k in 0..<n {
                        let index = base + maskFlat[k]
                        guard index >= 0, index <= last else { onGrid = false; break }
                        let s = coarse[index]
                        guard !s.isNaN else { onGrid = false; break }
                        let diff = dstRing[k] - s
                        s0 += diff
                        s1 += diff * maskU[k]
                        s2 += diff * maskV[k]
                        q2 += diff * diff
                        cSum += s
                        cSq += s * s
                    }
                    guard onGrid else { continue }
                    examined += 1

                    let cMean = cSum / nD
                    let sigmaC = max(0, cSq / nD - cMean * cMean).squareRoot()
                    guard sigmaC >= HealSpot.contrastFloor, sigmaC >= 0.4 * sigmaD else { continue }

                    // The residual after the least-squares plane. The closed form holds because the
                    // ring's basis is orthogonal: Σu = Σv = Σuv = 0, Σu² = Σv² = N/2.
                    let residual = q2 - s0 * s0 / nD - 2 * s1 * s1 / nD - 2 * s2 * s2 / nD
                    ranked.append((px, py, d, max(0, residual) / nD))
                }
            }

            guard let coarseBest = ranked.min(by: { $0.score < $1.score }) else {
                return HealSourceResult(offset: defaultSourceOffset(radius: radius),
                                        status: .noCandidateAccepted,
                                        examined: examined, accepted: 0, score: 0,
                                        distanceInRadii: 0)
            }

            // 4. The shortlist: everything whose ring residual is within a **tenth of the local
            //    contrast** of the best — a difference no one can see — ordered far first. On a flat
            //    wall hundreds of sources tie at the noise floor, and the tie has to be broken by
            //    where the user would have dragged: away from the defect.
            let tieBand = coarseBest.score.squareRoot() + 0.1 * sigmaD
            var shortlisted = ranked.filter { $0.score.squareRoot() <= tieBand }.sorted { $0.d > $1.d }
            let take = min(max(shortlist, 1), 12)
            if shortlisted.count > take { shortlisted.removeLast(shortlisted.count - take) }

            // 5. Full resolution: 8 concentric circles × 24 angles, nearest texel — the ring the
            //    kernel reads, at the resolution the answer is judged at.
            let ringCount = 8
            let angularCount = 24
            let nS = Double(ringCount * angularCount)

            func fullResolution(_ px: Double, _ py: Double) -> (score: Double, sigma: Double) {
                var s0 = 0.0, s1 = 0.0, s2 = 0.0, q2 = 0.0, cSum = 0.0, cSq = 0.0
                for ring in 0..<ringCount {
                    let rr = r * (1.03 + 0.44 * Double(ring) / Double(ringCount - 1))
                    for a in 0..<angularCount {
                        let theta = 2.0 * Double.pi * Double(a) / Double(angularCount)
                        let ux = cos(theta)
                        let vy = sin(theta)
                        let dst = luma(Int((cx + rr * ux).rounded()), Int((cy + rr * vy).rounded()))
                        let src = luma(Int((px + rr * ux).rounded()), Int((py + rr * vy).rounded()))
                        let diff = dst - src
                        s0 += diff
                        s1 += diff * ux
                        s2 += diff * vy
                        q2 += diff * diff
                        cSum += src
                        cSq += src * src
                    }
                }
                let cMean = cSum / nS
                let sigma = max(0, cSq / nS - cMean * cMean).squareRoot()
                let residual = q2 - s0 * s0 / nS - 2 * s1 * s1 / nS - 2 * s2 * s2 / nS
                return (max(0, residual) / nS, sigma)
            }

            var survivors: [(px: Double, py: Double, d: Double, rms: Double)] = []
            for candidate in shortlisted {
                let result = fullResolution(candidate.px, candidate.py)
                guard result.score.isFinite,
                      result.sigma >= HealSpot.contrastFloor,
                      result.sigma >= 0.4 * sigmaD else { continue }
                let rms = result.score.squareRoot()
                survivors.append((candidate.px, candidate.py, candidate.d, rms))
            }
            let accepted = survivors.count
            // Best first, then the farthest of the sources that are within a tenth of the local
            // contrast of it — the same tie rule the shortlist uses, applied at full resolution.
            let winner: (px: Double, py: Double, d: Double, rms: Double)? = {
                guard let best = survivors.min(by: { $0.rms < $1.rms }) else { return nil }
                let band = best.rms + 0.1 * sigmaD
                return survivors.filter { $0.rms <= band }.max(by: { $0.d < $1.d })
            }()

            guard let winner else {
                return HealSourceResult(offset: defaultSourceOffset(radius: radius),
                                        status: .noCandidateAccepted,
                                        examined: examined, accepted: 0, score: 0,
                                        distanceInRadii: 0)
            }

            let dx = winner.px - cx
            let dy = winner.py - cy
            return HealSourceResult(offset: NormalizedPoint(dx / shortEdge, dy / shortEdge),
                                    status: .found,
                                    examined: examined,
                                    accepted: accepted,
                                    score: winner.rms * winner.rms,
                                    distanceInRadii: (dx * dx + dy * dy).squareRoot() / r)
        }
    }
}
