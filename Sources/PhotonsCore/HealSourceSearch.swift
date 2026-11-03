import Foundation

// MARK: - 262 · source search: phase alignment + interior variance
//
// The search in `HealSpot.searchSource` used to rank a candidate by the **rim** alone: the
// plane-corrected SSD of the ring at radius `r`. That is the quantity the kernel can actually be
// blamed for, so it is the right *objective* — but on real structure it is not sufficient. A
// candidate whose ring happens to line up can hold a disk that is half a period out of phase
// (the "拉扯感 / 重复纹理 / 线接不上" in 252 §1.5 L3), and a candidate whose ring is a perfect
// match can hold a flat, blurred disk.
//
// C4 fixes the *choice* of source point and nothing else:
//
//   1. **PatchMatch-lite phase alignment.** For the candidates the rim pass shortlists, a small
//      deterministic local search walks the source centre to the place whose 5 × 5 patch best
//      matches the destination's, on a 3-level pyramid with 3 iterations per level (one
//      propagation proposal + one fixed-seed random proposal, then an integer snap at full
//      resolution). The metric is the plane-corrected
//      SSD, because the kernel absorbs any affine difference on the rim and a raw SSD would
//      reward an exposure offset the kernel removes.
//   2. **Interior variance penalty.** The disk's high-frequency energy is estimated as the
//      standard deviation left after removing the best-fit plane from a 5 × 5 grid across the
//      disk — i.e. the part of the disk a plane cannot explain. A source whose disk is much
//      flatter (or much noisier) than the destination's is penalised by
//      `λ · |σ_src − σ_dst| / max(σ_dst, ε)`; λ is `HealSourceSearchOptions.variancePenalty`
//      (default 0.5) and is not a UI control.
//
// **Determinism.** There is no concurrency and no wall-clock or RNG state: every "random"
// proposal is a pure hash of `(candidate, level, iteration, proposal)`, and the candidate order is
// the same array order the rim pass produced. The same input therefore returns the same offset
// bit for bit, which `HealPhaseAlignmentTests` pins by running the search five times.
//
// **Cost.** Alignment runs on the shortlist (not on all 336 ring candidates), because the point of
// the rim pass is to make the local search affordable: on the 60 Mpx `L1030433.dng` the whole
// search stays in the low milliseconds (see the report). A cheap 4 × 12 ring ranks the aligned
// candidates before the full 8 × 24 ring is measured on the final few.

/// 262 — knobs for the automatic source search. The defaults are the shipped behaviour; the
/// switches exist so the acceptance test can prove that phase alignment is what moves the answer
/// (turn it off and the periodic-texture case must go red) and so λ can be tuned without a UI.
public struct HealSourceSearchOptions: Sendable, Equatable {
    /// PatchMatch-lite on/off. Off keeps the pre-262 answer (rim scoring only), plus the variance
    /// penalty if `variancePenalty > 0`.
    public var phaseAlignment: Bool
    /// λ in `λ · |σ_src − σ_dst| / max(σ_dst, ε)`. `0` disables the penalty.
    public var variancePenalty: Double
    /// Pyramid levels, coarse → fine. 3 is the C4 first version.
    public var pyramidLevels: Int
    /// Iterations per pyramid level.
    public var iterations: Int
    /// Patch side, in samples. Odd; 5 is the C4 first version.
    public var patchSize: Int
    /// How many rim-shortlisted candidates are aligned. Bounds the cost (see the file comment).
    public var alignmentShortlist: Int

    public init(phaseAlignment: Bool = true,
                variancePenalty: Double = 0.5,
                pyramidLevels: Int = 3,
                iterations: Int = 3,
                patchSize: Int = 5,
                alignmentShortlist: Int = 8) {
        self.phaseAlignment = phaseAlignment
        self.variancePenalty = variancePenalty
        self.pyramidLevels = pyramidLevels
        self.iterations = iterations
        self.patchSize = patchSize
        self.alignmentShortlist = alignmentShortlist
    }

    /// The shipped configuration. Named so a caller can say "the default" without spelling the
    /// numbers, and so the tests cannot drift from it silently.
    public static let standard = HealSourceSearchOptions()
}

extension HealSpot {

    /// One local phase-alignment pass around a candidate. Reads the decoded buffer directly — the
    /// same picture (and the same half→float conversion) as `searchSource` and the kernel.
    struct SourceAligner {
        let width: Int
        let height: Int
        let buffer: UnsafeBufferPointer<Float16>
        let dstX: Double
        let dstY: Double
        let radius: Double
        let levels: Int
        let iterations: Int
        let patchSide: Int
        /// A source centre may move at most half a radius: beyond that it is a different candidate,
        /// not an alignment of this one.
        let maxShift: Double
        /// The destination patch per pyramid level, sampled once (it does not depend on the
        /// candidate). `NaN` when a sample fell off the frame.
        private let dstPatches: [[Double]]

        init(width: Int, height: Int, buffer: UnsafeBufferPointer<Float16>,
             dstX: Double, dstY: Double, radius: Double,
             levels: Int, iterations: Int, patchSide: Int) {
            self.width = width
            self.height = height
            self.buffer = buffer
            self.dstX = dstX
            self.dstY = dstY
            self.radius = radius
            self.levels = Swift.max(1, levels)
            self.iterations = Swift.max(1, iterations)
            self.patchSide = (patchSide % 2 == 0) ? patchSide + 1 : Swift.max(1, patchSide)
            self.maxShift = 0.5 * radius

            var cache: [[Double]] = []
            cache.reserveCapacity(self.levels)
            for level in 0..<self.levels {
                var row = [Double](repeating: .nan, count: self.patchSide * self.patchSide)
                if let luma = SourceAligner.destinationPatch(
                    width: width, height: height, buffer: buffer,
                    dstX: dstX, dstY: dstY, level: level, levels: self.levels,
                    side: self.patchSide) {
                    row = luma
                }
                cache.append(row)
            }
            self.dstPatches = cache
        }

        /// Luminance at the nearest texel. Nearest (not bilinear) keeps the search byte-comparable
        /// with the existing rim measurement and with the kernel's own source comparison.
        @inline(__always)
        func luma(_ x: Double, _ y: Double) -> Double? {
            let xi = Int(x.rounded())
            let yi = Int(y.rounded())
            guard xi >= 0, xi < width, yi >= 0, yi < height else { return nil }
            let o = (yi * width + xi) * 4
            return 0.2126 * Double(HealSpot.halfToFloat(buffer[o].bitPattern))
                + 0.7152 * Double(HealSpot.halfToFloat(buffer[o + 1].bitPattern))
                + 0.0722 * Double(HealSpot.halfToFloat(buffer[o + 2].bitPattern))
        }

        private static func destinationPatch(
            width: Int, height: Int, buffer: UnsafeBufferPointer<Float16>,
            dstX: Double, dstY: Double, level: Int, levels: Int, side: Int
        ) -> [Double]? {
            let step = 1 << Swift.max(0, levels - 1 - level)
            let half = side / 2
            var out = [Double](repeating: .nan, count: side * side)
            var index = 0
            for v in -half...half {
                for u in -half...half {
                    let x = Int((dstX + Double(u * step)).rounded())
                    let y = Int((dstY + Double(v * step)).rounded())
                    guard x >= 0, x < width, y >= 0, y < height else { return nil }
                    let o = (y * width + x) * 4
                    out[index] = 0.2126 * Double(HealSpot.halfToFloat(buffer[o].bitPattern))
                        + 0.7152 * Double(HealSpot.halfToFloat(buffer[o + 1].bitPattern))
                        + 0.0722 * Double(HealSpot.halfToFloat(buffer[o + 2].bitPattern))
                    index += 1
                }
            }
            return out
        }

        /// Plane-corrected SSD over the 5 × 5 patch at `(x, y)` on one pyramid level. The plane is
        /// fitted on the *difference* dst − src, which is exactly what the kernel's rim fit absorbs.
        func patchCost(_ x: Double, _ y: Double, level: Int) -> Double {
            let step = 1 << Swift.max(0, levels - 1 - level)
            let dst = dstPatches[level]
            let half = patchSide / 2
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, q2 = 0.0
            var suu = 0.0, svv = 0.0
            var index = 0
            for v in -half...half {
                for u in -half...half {
                    let d = dst[index]
                    guard d.isFinite,
                          let src = luma(x + Double(u * step), y + Double(v * step)) else {
                        return .infinity
                    }
                    let diff = d - src
                    s0 += diff
                    s1 += diff * Double(u)
                    s2 += diff * Double(v)
                    q2 += diff * diff
                    suu += Double(u * u)
                    svv += Double(v * v)
                    index += 1
                }
            }
            let n = Double(patchSide * patchSide)
            var residual = q2 - s0 * s0 / n
            if suu > 0 { residual -= s1 * s1 / suu }
            if svv > 0 { residual -= s2 * s2 / svv }
            return Swift.max(0, residual)
        }

        /// Deterministic 32-bit hash — the whole "RNG". Pure function of its arguments, so the
        /// same candidate/level/iteration always proposes the same offset.
        @inline(__always)
        private static func hash(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> UInt32 {
            var h = UInt32(truncatingIfNeeded: a &* 73_856_093)
            h ^= UInt32(truncatingIfNeeded: b &* 19_349_663)
            h ^= UInt32(truncatingIfNeeded: c &* 83_492_791)
            h ^= UInt32(truncatingIfNeeded: d &* 2_654_435_761)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            h ^= h >> 16
            return h
        }

        /// One fixed-seed proposal inside a disk of `searchRadius` around `(x, y)`.
        @inline(__always)
        private static func randomProposal(key: Int, level: Int, iteration: Int, proposal: Int,
                                           x: Double, y: Double,
                                           searchRadius: Double) -> (Double, Double) {
            let a = hash(key, level, iteration, proposal * 2)
            let b = hash(key, level, iteration, proposal * 2 + 1)
            let theta = 2.0 * Double.pi * Double(a % 1_000_003) / 1_000_003.0
            // sqrt gives a uniform density over the disk rather than over the radius.
            let dist = searchRadius * (Double(b % 1_000_003) / 1_000_003.0).squareRoot()
            return (x + dist * cos(theta), y + dist * sin(theta))
        }

        /// `seed` is the displacement the previous shortlisted candidate accepted — PatchMatch's
        /// propagation term. Returns the aligned centre and its finest-level patch cost.
        func align(_ px: Double, _ py: Double, seedX: Double, seedY: Double,
                   key: Int) -> (x: Double, y: Double, patch: Double) {
            let originX = px
            let originY = py
            var bx = px
            var by = py

            // Coarse → fine: the coarse level can move half a radius, the finest one a sixteenth.
            for level in 0..<levels {
                let searchRadius = Swift.max(1.0, radius * 0.5 * pow(0.5, Double(level)))
                var levelBest = patchCost(bx, by, level: level)

                for iteration in 0..<iterations {
                    // 1. Propagation: the neighbour's accepted shift, applied to this centre.
                    let propagated = (bx + seedX, by + seedY)
                    // 2. One fixed-seed random proposal around the current best. (Two were tried;
                    //    the second bought no measurable alignment on the fixtures and cost the
                    //    shortlist two candidates, so the budget went to breadth instead.)
                    let random = SourceAligner.randomProposal(
                        key: key, level: level, iteration: iteration, proposal: 0,
                        x: bx, y: by, searchRadius: searchRadius)

                    for proposal in [propagated, random] {
                        let dx = proposal.0 - originX
                        let dy = proposal.1 - originY
                        // Stay inside the candidate's local neighbourhood (and on the frame).
                        guard dx * dx + dy * dy <= maxShift * maxShift else { continue }
                        guard proposal.0 - radius >= 0, proposal.0 + radius <= Double(width),
                              proposal.1 - radius >= 0, proposal.1 + radius <= Double(height)
                        else { continue }
                        let cost = patchCost(proposal.0, proposal.1, level: level)
                        guard cost.isFinite, cost < levelBest else { continue }
                        levelBest = cost
                        bx = proposal.0
                        by = proposal.1
                    }
                }
            }

            // Final integer refinement at full resolution. The random proposals move in continuous
            // steps; the texture is sampled at whole texels, so snapping to the best neighbouring
            // texel removes the sub-texel error a random proposal can leave behind (and makes the
            // answer independent of where the proposal happened to land).
            var best = patchCost(bx, by, level: levels - 1)
            let cx0 = bx.rounded()
            let cy0 = by.rounded()
            // Visit (0,0) first, then the nearer neighbours, so a *tie* in the patch cost cannot
            // slide the centre along an axis the texture does not constrain (the rim still does).
            let offsets: [(Int, Int)] = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1),
                                         (-1, -1), (1, -1), (-1, 1), (1, 1)]
            for (dx, dy) in offsets {
                let px = cx0 + Double(dx)
                let py = cy0 + Double(dy)
                let sx = px - originX
                let sy = py - originY
                guard sx * sx + sy * sy <= maxShift * maxShift else { continue }
                guard px - radius >= 0, px + radius <= Double(width),
                      py - radius >= 0, py + radius <= Double(height) else { continue }
                let cost = patchCost(px, py, level: levels - 1)
                guard cost.isFinite, cost < best else { continue }
                best = cost
                bx = px
                by = py
            }
            return (bx, by, best)
        }

        /// Standard deviation of the disk's **plane-removed** luma — a simple, deterministic stand-in
        /// for "high-frequency energy inside the disk" (a smooth gradient has none after the plane).
        /// A 5 × 5 grid spanning ±0.8 r is enough to tell texture from a flat patch, and it is the
        /// same quantity for destination and source, so the units cancel in the penalty ratio.
        func interiorSigma(_ cx: Double, _ cy: Double) -> Double {
            // 9 × 9 over ±0.8 r: enough samples that two candidates whose disk is the same texture
            // shifted by half a period estimate the same σ (a 5 × 5 grid picked a winner by
            // sampling noise on exactly that case), still bounded and independent of frame size.
            let step = Swift.max(1.0, radius * 0.2)
            let half = 4
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, q2 = 0.0
            var suu = 0.0, svv = 0.0
            var count = 0
            for v in -half...half {
                for u in -half...half {
                    guard let value = luma(cx + Double(u) * step, cy + Double(v) * step) else {
                        return .nan
                    }
                    s0 += value
                    s1 += value * Double(u)
                    s2 += value * Double(v)
                    q2 += value * value
                    suu += Double(u * u)
                    svv += Double(v * v)
                    count += 1
                }
            }
            let n = Double(count)
            var residual = q2 - s0 * s0 / n
            if suu > 0 { residual -= s1 * s1 / suu }
            if svv > 0 { residual -= s2 * s2 / svv }
            return Swift.max(0, residual / n).squareRoot()
        }
    }
}
