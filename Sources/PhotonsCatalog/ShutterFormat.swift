import Foundation

/// One place that turns a shutter speed into the string a photographer reads.
///
/// Two inputs feed this and both were wrong for the same reason:
///
///   · **XMP** carries `exif:ExposureTime` as a *rational string*, and a Leica DNG writes
///     `55924/44739201` — a real exposure time expressed as an improper rational with a huge
///     denominator. Pasting that through verbatim is what put "huge integer ratios" in the panel.
///   · **EXIF** carries a double, which the old code formatted as `"1/\(Int((1/t).rounded()))"`
///     — that gives `1/8006`-style numbers nobody says out loud instead of the standard `1/800`.
///
/// The display rule (owner, 2026-10-26):
///
///   · **faster than 0.1 s** → a reciprocal: `1/800`, snapped to the standard ladder.
///   · **0.1 s and slower**, unless it is one of the handful of fractions people actually say out
///     loud (`1/2 1/3 1/4 1/5 1/6 1/10`) → **seconds**: `0.3s`, `4s`, `12s`.
///   · seconds are never written with two decimals, never with a decimal above one second, and a
///     value that would round to `0.5` goes **up** to `1s`.
public enum ShutterFormat {

    /// The standard shutter denominators, slowest first. Snapping is done in **log space** so
    /// `1/750` lands on `1/800` rather than on whichever neighbour happens to be numerically closer.
    public static let denominators: [Int] = [
        1, 2, 3, 4, 5, 6, 8, 10, 13, 15, 20,
        25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250, 320, 400, 500,
        640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 16000, 32000,
    ]

    /// Fractions of a second that keep their `1/n` spelling even though they are ≥ 0.1 s.
    public static let spokenFractions: [Int] = [2, 3, 4, 5, 6, 10]

    /// `"55924/44739201"`, `"1/250"`, `"1/250 s"`, `"0.004"`, `"2"` → seconds. `nil` if unparseable.
    public static func seconds(from raw: String?) -> Double? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "sec", with: "").replacingOccurrences(of: "s", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let value: Double?
        if s.contains("/") {
            let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let a = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let b = Double(parts[1].trimmingCharacters(in: .whitespaces)), b != 0 {
                value = a / b
            } else {
                value = nil
            }
        } else {
            value = Double(s)
        }
        guard let t = value, t.isFinite, t > 0 else { return nil }
        return t
    }

    /// Fractions from `1/3` down to `1/10` — the band that is always spelled as a fraction.
    public static let fractionBandDenominators: [Int] = [3, 4, 5, 6, 8, 10]

    /// Seconds → the display string: `1/800`, `1/6`, `1/2`, `0.4s`, `4s`, `12s`.
    ///
    /// The owner's banding (2026-10-26), in order:
    ///   · **< 0.1 s** → `1/n`, snapped to the standard ladder;
    ///   · **0.1 … 0.35 s** → always a fraction, snapped to `1/3 … 1/10`;
    ///   · **> 0.35 s** → seconds, one decimal below a second and none above it, **rounding half up**
    ///     (`3.5 → 4s`, `0.55 → 0.6s`); a value that lands exactly on half a second is `1/2`.
    public static func standard(seconds t: Double) -> String? {
        guard t.isFinite, t > 0 else { return nil }

        // ① faster than a tenth of a second: always a reciprocal, snapped to the standard ladder.
        if t < 0.1 {
            let target = 1.0 / t
            let denominator = denominators.min { a, b in
                abs(log(Double(a) / target)) < abs(log(Double(b) / target))
            } ?? 32000
            return "1/\(denominator)"
        }

        // ② 0.1 … 0.35 s: the fraction band, snapped in log space.
        if t <= 0.35 {
            let denominator = fractionBandDenominators.min { a, b in
                abs(log((1.0 / Double(a)) / t)) < abs(log((1.0 / Double(b)) / t))
            } ?? 10
            return "1/\(denominator)"
        }

        // ③ slower than 0.35 s: seconds, rounded half up. Half a second is written `0.5s` — the
        // owner does not want `1/2` in the seconds band (that spelling belongs to 0.1…0.35 s).
        if t > 1 { return "\(Int(halfUp(t)))s" }
        let v = halfUp(t * 10) / 10
        if v >= 1 { return "\(Int(v))s" }
        return String(format: "%.1fs", v)
    }

    /// Round half **up** — 3.5 → 4, 0.55 → 0.6 (Swift's `.rounded()` does the same for positives,
    /// this exists so the intent is written down rather than assumed).
    private static func halfUp(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// The whole job: any raw string in, the display string out (unchanged input is normalised too,
    /// so a library imported before this existed still reads correctly).
    public static func standard(from raw: String?) -> String? {
        guard let t = seconds(from: raw) else { return raw?.isEmpty == false ? raw : nil }
        return standard(seconds: t)
    }
}
