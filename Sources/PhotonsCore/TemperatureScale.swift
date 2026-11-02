import Foundation

/// 派单 242 — the white-balance slider's travel, in **mired** (10⁶ / K), not Kelvin.
///
/// The document still stores Kelvin (`WhiteBalance.temperature`), so old documents and presets need
/// no migration. This type exists only for the two things a control needs and a document does not:
///
///   1. **position** — the slider is uniform in mired, with the two ends fixed by the owner:
///      **left = 2000 K** (`fraction 0`) and **right = 50000 K** (`fraction 1`). A Kelvin-linear
///      slider would give the visually indistinguishable 12000–50000 K band 80 % of the track; the
///      mired one gives it the rightmost 13 %.
///   2. **quantization** — a drag snaps to a mired step, so one step is ~25 K at 5000 K and ~400 K at
///      20000 K: equally invisible everywhere, which is what the old fixed 25 K step could not say.
///
/// The formulas are one definition, and only one: the inspector calls these functions, it does not
/// copy them.
public enum TemperatureScale {

    /// The document's temperature range — the decoder's usable range, not Apple's header maximum.
    public static let kelvinRange: ClosedRange<Double> = 2000...50000

    /// Slider travel: 0 = `kelvinRange.lowerBound`, 1 = `kelvinRange.upperBound`.
    public static let fractionRange: ClosedRange<Double> = 0...1

    /// One quantization step in mired. 1 mired is ~25 K at 5000 K and ~400 K at 20000 K — below the
    /// visible threshold at both ends, which is the standard the old 25 K linear step only met at
    /// the low end.
    public static let miredStep: Double = 1

    /// `10⁶ / K`, the one conversion.
    public static func mired(_ kelvin: Double) -> Double { 1_000_000 / kelvin }

    /// The mired value at the left end (2000 K → 500).
    public static var miredMax: Double { mired(kelvinRange.lowerBound) }
    /// The mired value at the right end (50000 K → 20).
    public static var miredMin: Double { mired(kelvinRange.upperBound) }

    /// Kelvin → slider fraction, clamped to the travel.
    ///
    ///     fraction = (miredMax − 10⁶/T) / (miredMax − miredMin)
    public static func fraction(forKelvin kelvin: Double) -> Double {
        guard kelvin.isFinite else { return 0 }
        let t = min(max(kelvin, kelvinRange.lowerBound), kelvinRange.upperBound)
        let span = miredMax - miredMin
        guard span > 0 else { return 0 }
        return min(max((miredMax - mired(t)) / span, 0), 1)
    }

    /// Slider fraction → Kelvin, clamped to the travel. The inverse of `fraction(forKelvin:)`.
    public static func kelvin(forFraction fraction: Double) -> Double {
        guard fraction.isFinite else { return kelvinRange.lowerBound }
        let f = min(max(fraction, fractionRange.lowerBound), fractionRange.upperBound)
        let m = miredMax - f * (miredMax - miredMin)
        guard m > 0 else { return kelvinRange.upperBound }
        return min(max(1_000_000 / m, kelvinRange.lowerBound), kelvinRange.upperBound)
    }

    /// Snap a Kelvin value onto the mired grid, then clamp it. The result is a whole Kelvin value so
    /// the document, its JSON and its `%.0f K` readout all spell the same number.
    ///
    /// Idempotent: the returned value's mired coordinate is within 0.125 mired of the chosen integer
    /// (even at 2000 K, the most sensitive end), so quantizing it again cannot cross a step boundary.
    public static func quantizedKelvin(_ kelvin: Double, step: Double = miredStep) -> Double {
        guard kelvin.isFinite else { return kelvinRange.lowerBound }
        let t = min(max(kelvin, kelvinRange.lowerBound), kelvinRange.upperBound)
        guard step > 0 else { return t }
        let m = (mired(t) / step).rounded() * step
        guard m > 0 else { return kelvinRange.upperBound }
        let k = 1_000_000 / m
        return min(max(k.rounded(), kelvinRange.lowerBound), kelvinRange.upperBound)
    }

    /// Are two Kelvin values within one quantization step of each other? Used where the contract is
    /// "same bucket", not "same number": preset matching and the as-shot fold.
    public static func isWithinOneStep(_ a: Double, _ b: Double, step: Double = miredStep) -> Bool {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(mired(a) - mired(b)) <= step / 2
    }
}
