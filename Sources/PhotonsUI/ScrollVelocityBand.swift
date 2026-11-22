import CoreGraphics
import QuartzCore

/// 502 — **direction-aware prefetch band**: the band grows in the direction the scroll is heading.
///
/// The ask (2026-11-22) is one sentence:
///
/// > 「带宽改成方向感知（velocity-aware）：按滚动速度在运动方向上延长（比如 ±10 → ±10+2×行/秒，
/// >   上限 ±30）」
///
/// The shape is deliberately small, because three surfaces share it and each of them is a geometry
/// consumer, not a policy:
///
/// * **at rest** (`speed == 0`) both sides are `base` (10) — the shipped ±10 band, bit for bit;
/// * **moving** the leading side is `base + perRowPerSecond × speed`, floored, capped at `cap`;
///   the trailing side stays `base`. A flick therefore preloads where the eye is going and leaves
///   the rows behind it alone;
/// * the speed is **smoothed** (`0.6 × previous sample + 0.4 × current sample`) and a smoothed
///   speed under `0.5` is treated as 0, so one noisy frame cannot double the band and a finger that
///   nudges the trackpad by a pixel widens nothing.
///
/// Two rules the 502 acceptance pins down:
///
/// 1. the speed comes from **bounds displacement over time**, never from `NSEvent`'s scrolling
///    delta: during inertia there is no event, so a delta-based band would collapse to ±10 exactly
///    when the scroll is fastest;
/// 2. `cap` is a **unit** cap — rows on the grid/list, cells on the filmstrip — never a pixel count
///    converted back into a bigger number.
struct ScrollVelocityBand {

    /// The shipped slack, in rows (grid/sidebar) or cells (filmstrip). At zero speed both sides are
    /// exactly this, which is what makes "at rest is unchanged" a property of the formula rather
    /// than a promise in a comment.
    static let base = 10

    /// How many extra units one unit-per-second of speed buys on the leading side.
    static let perRowPerSecond = 2.0

    /// Unit cap for the leading side (rows/cells — never pixels).
    static let cap = 30

    /// Below this smoothed speed the band is the resting band. One trackpad pixel of drift is
    /// ~0.01 rows/s, so 0.5 is comfortably above "no intent to scroll".
    static let minimumSpeed = 0.5

    /// The smoothing weights: `0.6 × previous sample + 0.4 × current sample`.
    ///
    /// The filter is anchored on the **previous sample**, not on the previous filtered value, and
    /// that is what makes a stop cost one sample instead of a 0.6-geometric tail: sampling 20, 0, 0
    /// gives 12 (still wide) and then 0 (resting band again). Anchoring on the filtered value would
    /// take roughly eight samples to fall under `minimumSpeed`, i.e. a band that stays 30 rows wide
    /// for a sixth of a second after the scroll has visibly stopped.
    static let previousSampleWeight = 0.6
    static let currentSampleWeight = 0.4

    /// Two samples closer than this are treated as a zero-speed sample. At 60 Hz a frame is 16 ms,
    /// so a sub-millisecond gap is a clock artefact and dividing by it would invent a speed.
    static let minimumSampleInterval: CFTimeInterval = 0.001

    /// A single-sample displacement is not a scroll when it is **wider than the viewport**, or when it
    /// would imply a speed past this ceiling: both are discontinuities (`scroll(to:)` from a menu or a
    /// selection, restoring a position, scroll-to-top). Tracking either as speed would arm the widest
    /// band exactly when nothing is moving — and, at a programmatic jump, hand the disk a screenful of
    /// thumbnails nobody asked to see. A real flick stays far below 240 units/s even at the 120 ms cap
    /// (30 rows/s × 0.12 s = 3.6 rows per pass).
    static let maximumTrackedDisplacement = 1.0  // viewports per sample
    static let maximumTrackedSpeed = 240.0       // rows or cells per second

    // MARK: - pure core

    /// `abs`, non-finite → 0, and the dead band: a smoothed speed under `minimumSpeed` is rest.
    static func normalisedSpeed(_ rowsPerSecond: Double) -> Double {
        let magnitude = abs(rowsPerSecond)
        guard magnitude.isFinite, magnitude >= minimumSpeed else { return 0 }
        return magnitude
    }

    /// The slacks, in units, for a **smoothed** speed. Pure: no clock, no state.
    ///
    /// - `rowsPerSecond == 0` → `(10, 10)`;
    /// - `v > 0` → `(10, min(30, 10 + floor(2·v)))`;
    /// - `v < 0` → the same magnitudes (`abs`): which side is "forward" is the caller's job, since
    ///   only the caller knows whether a positive offset means down (grid/list) or right (filmstrip).
    ///
    /// The extension is floored — "give less rather than more" — and clamped before the `Int`
    /// conversion so a nonsense sample (a drag reported as 1e6 rows/s) cannot overflow.
    static func slacks(rowsPerSecond: Double) -> (backward: Int, forward: Int) {
        let speed = normalisedSpeed(rowsPerSecond)
        let raw = perRowPerSecond * speed
        let extensionRows = Int(min(Double(cap - base), raw.isFinite ? raw : 0).rounded(.down))
        return (base, min(cap, base + extensionRows))
    }

    /// The cancellation ring on the **leading** side.
    ///
    /// At rest the ring is whatever the surface shipped with (`restingRing`: 12 rows on the grid,
    /// 20 on the list and the strip) — 502 must not move it. Once the band widens, the ring has to
    /// be at least the band plus one unit of margin, otherwise the pass that issues a 30-row forward
    /// ask would condemn it in the same turn (`ThumbnailService.suppressWrite` then throws away
    /// bytes that were just produced).
    static func cancellationRing(forward: Int, restingRing: Int) -> Int {
        forward <= base ? restingRing : max(restingRing, forward + base)
    }

    // MARK: - sampling

    /// Which way the scroll is heading. `forward` means the scroll offset (and therefore the item
    /// index) is increasing: down on the grid/list, right on the filmstrip.
    enum Direction: Int {
        case backward = -1
        case none = 0
        case forward = 1
    }

    /// One pass's band, in **travel coordinates**: `forward` is the side the motion points at.
    struct Sample: Equatable {
        var backward: Int
        var forward: Int
        var direction: Direction

        /// True when this is the shipped ±`base` band on both sides.
        var isResting: Bool {
            backward == ScrollVelocityBand.base && forward == ScrollVelocityBand.base
        }

        static let resting = Sample(backward: ScrollVelocityBand.base,
                                    forward: ScrollVelocityBand.base,
                                    direction: .none)
    }

    /// Turns consecutive `(bounds origin, time)` readings into a smoothed `Sample`.
    ///
    /// The clock and the offsets are injected, so the acceptance can describe a scroll exactly
    /// ("twenty rows per second, sampled 100 ms ago") without sleeping.
    struct Sampler {
        private var previousOffset: CGFloat?
        private var previousTime: CFTimeInterval?
        /// The **raw** speed of the previous sample — the number the smoothing weights read.
        private var previousSpeed: Double = 0

        init() {}

        /// Sample one pass.
        ///
        /// - Parameters:
        ///   - offset: the scrolled coordinate (`bounds.origin.y` on the grid/list, `.x` on the strip).
        ///   - time: a monotonic clock reading (`CACurrentMediaTime()` in the shipping callers).
        ///   - unitPoints: points per row/cell — the unit `slacks` is counted in.
        ///   - viewportSpan: the visible extent in points, for the jump guard.
        mutating func sample(offset: CGFloat, time: CFTimeInterval,
                             unitPoints: CGFloat, viewportSpan: CGFloat) -> Sample {
            guard let lastOffset = previousOffset, let lastTime = previousTime else {
                // First sample since the last reset: there is no interval, so there is no speed.
                previousOffset = offset
                previousTime = time
                previousSpeed = 0
                return .resting
            }

            let unit = max(1, unitPoints)
            let displacement = Double((offset - lastOffset) / unit)
            let interval = time - lastTime
            let isTooWide = viewportSpan > 0 && abs(offset - lastOffset) > viewportSpan
            let isTooFast = interval >= ScrollVelocityBand.minimumSampleInterval
                && abs(displacement / max(interval, ScrollVelocityBand.minimumSampleInterval))
                    > ScrollVelocityBand.maximumTrackedSpeed
            let isJump = isTooWide || isTooFast

            let raw: Double
            if isJump || !interval.isFinite || interval < ScrollVelocityBand.minimumSampleInterval {
                raw = 0
            } else {
                raw = displacement / interval
            }

            // Smooth a *magnitude*: a reversal is a direction change, not a negative speed.
            let smoothed = ScrollVelocityBand.previousSampleWeight * previousSpeed
                + ScrollVelocityBand.currentSampleWeight * abs(raw)

            previousOffset = offset
            previousTime = time
            previousSpeed = abs(raw)

            let slacks = ScrollVelocityBand.slacks(rowsPerSecond: smoothed)
            let direction: Direction = raw > 0 ? .forward : (raw < 0 ? .backward : .none)
            return Sample(backward: slacks.backward, forward: slacks.forward, direction: direction)
        }

        /// Forget the history. Called when the surface switches library or leaves the photo list:
        /// the next pass must not measure a speed across a document swap.
        mutating func reset() {
            previousOffset = nil
            previousTime = nil
            previousSpeed = 0
        }

        /// Seed the sampler as if the previous pass had been taken `offsetDelta` points back, at
        /// `time`, with a raw speed of `speed` rows/cells per second. Acceptance only — the shipping
        /// call path only ever calls `sample`.
        mutating func prime(offset: CGFloat, time: CFTimeInterval, speed: Double) {
            previousOffset = offset
            previousTime = time
            previousSpeed = abs(speed)
        }
    }
}
