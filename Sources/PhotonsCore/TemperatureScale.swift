import Foundation

/// Shared white-balance control range. Documents continue to store Kelvin; the desktop slider
/// maps its travel to reciprocal temperature (mired) and snaps changes to one-mired steps.
public enum TemperatureScale {

    /// The document's temperature range — the decoder's usable range, not Apple's header maximum.
    public static let kelvinRange: ClosedRange<Double> = 800...14000

    /// Slider travel: 0 = `kelvinRange.lowerBound`, 1 = `kelvinRange.upperBound`.
    public static let fractionRange: ClosedRange<Double> = 0...1

    /// One quantization step in mired. 1 mired is ~25 K at 5000 K and ~196 K at 14000 K — below the
    /// visible threshold at both ends, which is the standard the old 25 K linear step only met at
    /// the low end.
    public static let miredStep: Double = 1

    /// `10⁶ / K`, the one conversion.
    public static func mired(_ kelvin: Double) -> Double { 1_000_000 / kelvin }

    /// The mired value at the left end (800 K → 1250).
    public static var miredMax: Double { mired(kelvinRange.lowerBound) }
    /// The mired value at the right end (14000 K → 71.43).
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
    /// Repeated quantization preserves the whole-Kelvin result, including the low-temperature
    /// end where one Kelvin spans more than one mired.
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
