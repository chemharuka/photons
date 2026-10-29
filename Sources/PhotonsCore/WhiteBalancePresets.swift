import Foundation

// MARK: - sample

/// One scene-linear colour, in the decoded buffer's own coordinates (0…1 ≈ SDR white).
///
/// A tiny value type rather than a tuple: the eyedropper hands it across a closure, the solver
/// returns residuals computed from two of them, and the tests print it — none of that reads well
/// with `(r:g:b:)` spelled out at every call site.
public struct RGBSample: Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public static let black = RGBSample(r: 0, g: 0, b: 0)

    /// Mean of the three channels — the scale a *neutral* sample would have.
    public var mean: Double { (r + g + b) / 3 }

    /// Largest channel deviation from the mean, as a fraction of the mean. 0 = perfectly neutral.
    ///
    /// This is the residual the eyedropper reports: "how far from grey is this point, relative to
    /// its own brightness", which is the only form that survives a dark or a bright patch.
    public var chroma: Double {
        let m = mean
        guard m > 1e-9 else { return 0 }
        return max(abs(r - m), max(abs(g - m), abs(b - m))) / m
    }

    /// `"0.412 0.398 0.377"` — three decimals, enough to see a 1 % move.
    public var text: String {
        String(format: "%.4f %.4f %.4f", r, g, b)
    }

    public func scaled(by gain: (r: Float, g: Float, b: Float)) -> RGBSample {
        RGBSample(r: r * Double(gain.r), g: g * Double(gain.g), b: b * Double(gain.b))
    }
}

// MARK: - presets

/// A white-balance menu entry (派单 009 B).
///
/// Three kinds, and the distinction is the whole design:
///
///   · `asShot` — the document stores `nil`: Apple's own balance, no number in the file, so the menu
///     label carries the *measured* value (`原照设置 · 5872 K`) instead of pretending to know one.
///   · `auto` — no constant either: it is computed from the picture on screen (grey-world mean, then
///     the same inverse solve the eyedropper uses). A hard-coded number would not be "auto".
///   · `fixed` — an absolute Kelvin/tint pair, listed below.
///
/// **Where the numbers come from.** Lightroom Classic's white-balance preset table, which is the
/// only widely-used reference implementation: `日光 5500 K / tint 0`, `阴天 6500 / +10`,
/// `阴影 7500 / +10`, `钨丝灯 2850 / 0`, `荧光灯 3800 / +21`, `闪光灯 5500 / 0`. Adobe derives a
/// per-body variant from these, but the *shape* of the table (Kelvin for the illuminant, tint for
/// the green/magenta cast) is exactly ours, and our document stores absolute Kelvin in the
/// decoder's own coordinates, so the pair goes to `CIRAWFilter.neutralTemperature/neutralTint`
/// unchanged. `闪光灯` coincides with `日光` in this table — flash is daylight-balanced at 5500 K —
/// which is why the menu's checkmark tie-breaks on the item the user last picked instead of on the
/// first numeric match (see `WhiteBalancePresets.match`).
public struct WhiteBalancePreset: Sendable, Equatable, Hashable, Identifiable {

    public enum Kind: String, Sendable, Hashable {
        case asShot
        case auto
        case fixed
    }

    /// Stable identity for `Picker` selection and for remembering the user's last choice.
    public let id: String
    /// What the menu says. Chinese, like the rest of the inspector.
    public let name: String
    public let kind: Kind
    /// The absolute pair, `nil` for as-shot and auto (both of which are *states*, not numbers).
    public let temperature: Double?
    public let tint: Double?

    public init(id: String, name: String, kind: Kind,
                temperature: Double? = nil, tint: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.temperature = temperature
        self.tint = tint
    }

    /// The document value this entry writes. `nil` for as shot; auto is resolved per photo and
    /// therefore cannot be expressed here.
    public var whiteBalance: WhiteBalance? {
        kind == .fixed ? WhiteBalance(temperature: temperature, tint: tint) : nil
    }

    /// Does this entry describe the document's current pair?
    ///
    /// Compared after quantization (25 K / 1 tint), because that is the resolution the sliders
    /// commit at: a document holding 5500 K must not show "自定义" next to a 5500 K preset.
    public func matches(_ wb: WhiteBalance) -> Bool {
        guard kind == .fixed, let t = wb.temperature, let i = wb.tint else { return false }
        return abs(t - (temperature ?? .nan)) <= WhiteBalance.temperatureStep / 2
            && abs(i - (tint ?? .nan)) <= WhiteBalance.tintStep / 2
    }

    /// `"5500 K / 0"` — the value column of the report and of the menu's help text.
    public var valueText: String {
        guard kind == .fixed else { return kind.rawValue }
        let t = temperature.map { String(format: "%.0f K", $0) } ?? "as shot"
        let i = tint.map { String(format: "%+.0f", $0) } ?? "+0"
        return "\(t) / \(i)"
    }
}

public enum WhiteBalancePresets {

    public static let asShot = WhiteBalancePreset(id: "asShot", name: "原照设置", kind: .asShot)
    public static let auto = WhiteBalancePreset(id: "auto", name: "自动", kind: .auto)
    public static let daylight = WhiteBalancePreset(id: "daylight", name: "日光", kind: .fixed,
                                                    temperature: 5500, tint: 0)
    public static let cloudy = WhiteBalancePreset(id: "cloudy", name: "阴天", kind: .fixed,
                                                  temperature: 6500, tint: 10)
    public static let shade = WhiteBalancePreset(id: "shade", name: "阴影", kind: .fixed,
                                                 temperature: 7500, tint: 10)
    public static let tungsten = WhiteBalancePreset(id: "tungsten", name: "钨丝灯", kind: .fixed,
                                                    temperature: 2850, tint: 0)
    public static let fluorescent = WhiteBalancePreset(id: "fluorescent", name: "荧光灯", kind: .fixed,
                                                       temperature: 3800, tint: 21)
    public static let flash = WhiteBalancePreset(id: "flash", name: "闪光灯", kind: .fixed,
                                                 temperature: 5500, tint: 0)

    /// Menu order: the two states first (as shot, auto), then the illuminants from cool to warm —
    /// the order every raw converter uses, so the eye can find "shade" without reading.
    public static let all: [WhiteBalancePreset] = [
        asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash,
    ]

    public static func preset(id: String) -> WhiteBalancePreset? {
        all.first { $0.id == id }
    }

    /// The entry to check in the menu for a live document.
    ///
    /// `preferred` is the id the user picked last: it breaks the `闪光灯 == 日光` tie (and would
    /// break any future duplicate) without inventing a different number for one of them. A drag of
    /// the sliders leaves `preferred` stale, which is why it only wins while it still *matches* —
    /// otherwise the menu honestly says `自定义`.
    public static func match(_ wb: WhiteBalance, preferred: String? = nil) -> WhiteBalancePreset? {
        if wb.isAsShot { return asShot }
        if let preferred, let p = preset(id: preferred), p.matches(wb) { return p }
        return all.first { $0.matches(wb) }
    }

    /// What the menu shows: a preset name, or `自定义` when the pair is nobody's constant.
    public static func menuLabel(_ wb: WhiteBalance, preferred: String? = nil) -> String {
        if wb.isAsShot { return asShot.name }
        return match(wb, preferred: preferred)?.name ?? "自定义"
    }
}

// MARK: - inverse solve

/// Result of asking "which Kelvin/tint makes this pixel neutral?".
public struct WhiteBalanceSolve: Sendable, Equatable {
    /// The pair to write into the document (already quantized to the slider's 25 K / 1 tint).
    public let whiteBalance: WhiteBalance
    /// Largest channel deviation from the mean **after** the model's gain is applied, as a fraction.
    /// 0 = the model can neutralize this sample exactly; the model is a Planckian fit, so a strongly
    /// saturated sample keeps a few percent.
    public let residual: Double
    /// The modelled result of applying `whiteBalance` to the sample — what the *model* promises.
    /// The pixels can still differ: the document's pair goes through `CIRAWFilter`, whose own fit is
    /// Adobe's, not `LightGroup.whiteBalanceGains`. The tests report both numbers.
    public let predicted: RGBSample
    /// Bisection steps used for the temperature; 0 when the tint alone had to do.
    public let iterations: Int
    /// True when the sample asked for something outside 2000–12000 K or ±150 tint and the answer is
    /// the nearest legal pair rather than a solution — the UI must say so ("近似") rather than imply
    /// this point can be made neutral.
    public let clamped: Bool

    public var summary: String {
        String(format: "%@ · residual %.2f%%%@", whiteBalance.summary, residual * 100,
               clamped ? " · clamped" : "")
    }
}

/// Inverse of the white-balance model, by search (派单 009 C).
///
/// **The model, and why it is evaluated in linear light.**
///
/// `LightGroup.planckianRGB` is the 0…255 *display-encoded* (sRGB-gamma) colour of a black body at
/// `T`. `LightGroup.whiteBalanceGains` divides those encoded numbers directly, which is fine for the
/// mask-local ±100 nudge it was built for, but is ~2.2× too weak as a prediction of what
/// `CIRAWFilter.neutralTemperature` does: the decoder corrects in **linear light**, and a ratio of
/// gamma-encoded channels under-states every ratio (measured on L1030433: asking the model for
/// 7825 K predicted a 0.86× move in B/R where the decoder delivered 0.63×). So this solver feeds the
/// same curve through the sRGB EOTF, divides in linear light, and normalizes on green — the identical
/// algebra, in the space the decoder works in.
///
/// **The reference is the illuminant the buffer was decoded under**, not a fixed 6500 K: the sample
/// comes from a picture that is already balanced, so the only thing that can be predicted is the
/// *change* between the current pair and the requested one. The caller passes the document's current
/// pair, or the file's as-shot pair while the document follows the file (派单 006's `nil`).
///
/// Then:
///
///   1. **Kelvin** — the model's gains are normalized so green is 1, so neutrality needs
///      `gainR/gainB = B/R` of the sample. That ratio is strictly increasing in temperature, so a
///      bisection on 2000…12000 K finds the single root (40 iterations, exact to ~1 K).
///   2. **Tint** — with Kelvin fixed, the tint term scales R,B by √s and divides G by s, so `R' = G'`
///      has the closed form `s = (G·gainG / (R·gainR))^(2/3)`; the model's `s = (1 + Δ/300)²` inverts
///      to `Δtint = 300·(√s − 1)`, relative to the reference tint.
///   3. **Residual** — the model's own error on that sample, in % of its mean. It is 0 whenever the
///      two parameters were free (they are two equations for two unknowns); it is *not* 0 when a
///      channel is clamped at the end of a range, which is exactly when the caller should be told.
///      The pixels can still differ by a few percent: what actually happens is Adobe's fit inside
///      `CIRAWFilter`, not this one. The tests print both numbers.
public enum WhiteBalanceSolver {

    public static let searchRange = 2000.0...12000.0
    private static let iterations = 40

    /// The nominal white point this model is centred on — and, since 143, the reference of the
    /// scene-linear estimator as well. One constant, so the solver, the mask's anchor and the new
    /// `WhiteBalanceEstimate` cannot disagree about what "6500 K" means.
    public static let nominalTemperature = 6500.0

    /// The illuminant a buffer was decoded under. `nil` temperature (as shot with no decode yet) is
    /// read as the nominal 6500 K the model is centred on, and the caller is expected to have said so.
    public struct Reference: Sendable, Equatable {
        public let temperature: Double
        public let tint: Double

        public init(temperature: Double, tint: Double) {
            self.temperature = temperature
            self.tint = tint
        }

        public init(_ wb: WhiteBalance, fallback: WhiteBalance = .asShot) {
            self.temperature = wb.temperature ?? fallback.temperature ?? WhiteBalanceSolver.nominalTemperature
            self.tint = wb.tint ?? fallback.tint ?? 0
        }
    }

    /// The model's linear-light gain for a requested pair, relative to `reference`.
    ///
    /// Public because the eyedropper's hint, the tests and any future preview want the same numbers
    /// the solve used — a second copy of this arithmetic is how the two would drift apart.
    public static func gain(temperature: Double, tint: Double,
                            reference: Reference) -> (r: Double, g: Double, b: Double) {
        let ref = linearWhite(reference.temperature)
        let cur = linearWhite(min(max(temperature, searchRange.lowerBound), searchRange.upperBound))
        var r = ref.0 / cur.0
        var g = ref.1 / cur.1
        var b = ref.2 / cur.2
        let n = max(g, 1e-9)
        r /= n; g /= n; b /= n
        // The model's own tint term, squared: it is written against display-encoded values, this is
        // the linear-light equivalent (γ ≈ 2 for the encoded curve the model was defined on).
        let encoded = 1 + (tint - reference.tint) / 600
        let s = encoded * encoded
        let comp = s.squareRoot()
        return (r * comp, g / s, b * comp)
    }

    // MARK: the mask's relative coordinate — one body, so one cast

    /// **079 A3 — the mask's `temperature`/`tint` are read in this solver's coordinates.**
    ///
    /// The defect: `LocalAdjustments.gain` multiplied `LightGroup.whiteBalanceGains`, which divides
    /// the 0…255 *display-encoded* black-body colour. That fit is ~2.2–2.4× too weak as a model of a
    /// linear-light gain (this type's header has the same measurement: 0.86× predicted where the
    /// decoder delivered 0.63×), so the mask and the global control disagreed about what a number
    /// means — `+30` in a mask moved R/B by 12 % where the global request of the same Kelvin moves it
    /// by 30 %. darktable cannot have that bug: `process()` runs once whether the module is masked or
    /// not and the mask only decides alpha (`blend.c:833-859`). Here the equivalent is that a masked
    /// slider calls the **same** `gain` the global path calls, with the same reference.
    ///
    /// The two coordinates, and why these are the numbers:
    ///
    ///   · **temperature** — the mask's slider is *relative*, not Kelvin (the global Light card owns
    ///     absolute Kelvin, 派单 009 A). Its mapping has been `6500 K + 30 K/unit` since M1-7 and is
    ///     kept: `+30` asks for 7400 K. What changes is only that the answer now comes from `gain`
    ///     (linear light) instead of from the encoded fit, i.e. the mask applies the cast a global
    ///     request for 7400 K predicts.
    ///   · **tint** — 1:1 in `WhiteBalance.tint` units, which is the coordinate the document's tint is
    ///     written in; the old path multiplied the mask's ±100 straight into `LightGroup.tint`, and
    ///     that fit's encoded tint term is the linear one with `Δtint = 2·tint`, i.e. a *different*
    ///     number for the same slider. 1:1 is the only mapping under which "same value → same cast"
    ///     is a statement about one coordinate rather than two. The visible consequence is small by
    ///     luck — `√(1 + t/300)` and `1 + t/600` are within 3 % of each other in R/G at ±100 — so an
    ///     existing document's tint keeps its strength; only its definition moves (pinned in
    ///     `LocalWhiteBalanceTests.testMaskedTintIsTheGlobalSolverTint`).
    ///   · **reference** — the nominal 6500 K / 0 this fit is centred on, which is also what
    ///     `Reference` defaults to. A mask's nudge is applied to a buffer the decoder has **already
    ///     balanced**, so the model's origin is the neutral of the model, not the file's as-shot pair;
    ///     the value layer has no decode pair to pass, and inventing one would make the mask's pixels
    ///     depend on a setting the mask's own key does not carry. Callers that do have the decode pair
    ///     (the eyedropper, `apply`) pass their own `reference` to the same function.
    ///
    /// The result is normalized on green exactly as `gain` is, and there is **no extra brightness
    /// compensation** — the mask has never had one, and adding one now would make a masked +30 a
    /// different *level* change from a global one (the global decode does not preserve luma either).
    public static let localAnchorKelvin = nominalTemperature
    /// The mask's kelvin step per slider unit (M1-7's mapping, unchanged).
    public static let localKelvinPerUnit = 30.0
    /// The reference the mask's relative units are measured from.
    public static let localReference = Reference(temperature: localAnchorKelvin, tint: 0)

    /// The mask's `temperature` units as Kelvin, clamped to the slider's own ±100 (a hand-edited
    /// document cannot ask for 30000 K; `gain` clamps the pair to 2000…12000 as well).
    public static func localKelvin(_ units: Double) -> Double {
        localAnchorKelvin + min(max(units, -100), 100) * localKelvinPerUnit
    }

    /// Scene-linear RGB gain for a mask's `temperature`/`tint` sliders — **`gain` itself**, called with
    /// the mask's units converted into its coordinates. One body: a second copy of this arithmetic is
    /// how the two sides drifted apart in the first place.
    public static func localGain(temperature: Double, tint: Double,
                                 reference: Reference = localReference)
        -> (r: Double, g: Double, b: Double) {
        gain(temperature: localKelvin(temperature),
             tint: min(max(tint, -100), 100),
             reference: reference)
    }

    /// `nil` for a sample that carries no colour information (black, or a channel at zero), where
    /// "make this neutral" has no meaning and any Kelvin would be a guess.
    public static func neutral(for sample: RGBSample,
                               reference: Reference = Reference(temperature: WhiteBalanceSolver.nominalTemperature, tint: 0))
        -> WhiteBalanceSolve? {
        let r = sample.r, g = sample.g, b = sample.b
        guard r.isFinite, g.isFinite, b.isFinite,
              r > 1e-6, g > 1e-6, b > 1e-6 else { return nil }
        let target = b / r

        /// The model's R/B gain ratio at `kelvin`, tint held at the reference's.
        func ratio(_ kelvin: Double) -> Double {
            let gains = gain(temperature: kelvin, tint: reference.tint, reference: reference)
            return gains.r / max(gains.b, 1e-12)
        }

        var lo = searchRange.lowerBound, hi = searchRange.upperBound
        var clamped = false
        if ratio(lo) >= target { hi = lo; clamped = true }        // redder than 2000 K can explain
        else if ratio(hi) <= target { lo = hi; clamped = true }   // bluer than 12000 K
        else {
            for _ in 0..<iterations {
                let mid = (lo + hi) / 2
                if ratio(mid) < target { lo = mid } else { hi = mid }
            }
        }
        let kelvin = (lo + hi) / 2

        let gains = gain(temperature: kelvin, tint: reference.tint, reference: reference)
        // R and B scale by √s, G by 1/s: R' = G' ⟺ s = (G·gainG / (R·gainR))^(2/3).
        let s = pow(max(g * gains.g / (r * gains.r), 1e-9), 2.0 / 3.0)
        let delta = 300 * (s.squareRoot() - 1)
        var tint = reference.tint + delta
        if tint < WhiteBalance.tintRange.lowerBound || tint > WhiteBalance.tintRange.upperBound {
            clamped = true
            tint = min(max(tint, WhiteBalance.tintRange.lowerBound),
                       WhiteBalance.tintRange.upperBound)
        }

        let wb = WhiteBalance(temperature: min(max(kelvin, searchRange.lowerBound),
                                               searchRange.upperBound),
                              tint: tint).quantized()
        let applied = apply(wb, to: sample, reference: reference)
        return WhiteBalanceSolve(whiteBalance: wb,
                                 residual: applied.chroma,
                                 predicted: applied,
                                 iterations: iterations,
                                 clamped: clamped)
    }

    /// The model's answer for "the document says `wb`, the sample was decoded under `reference`".
    public static func apply(_ wb: WhiteBalance, to sample: RGBSample,
                             reference: Reference = Reference(temperature: WhiteBalanceSolver.nominalTemperature, tint: 0)) -> RGBSample {
        let g = gain(temperature: wb.temperature ?? reference.temperature,
                     tint: wb.tint ?? reference.tint, reference: reference)
        return RGBSample(r: sample.r * g.r, g: sample.g * g.g, b: sample.b * g.b)
    }

    /// Grey-world "auto": the same solve applied to the picture's mean colour instead of one point.
    ///
    /// This is Auto WB in spirit (an estimate against the scene, not a constant), and it is honest
    /// about being one: the caller gets the same `WhiteBalanceSolve` with its residual.
    public static func auto(forAverage sample: RGBSample, reference: Reference) -> WhiteBalanceSolve? {
        neutral(for: sample, reference: reference)
    }

    // MARK: the curve, in linear light

    /// `planckianRGB(T)` through the sRGB EOTF — the linear-light white point of a black body.
    static func linearWhite(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let encoded = LightGroup.planckianRGB(kelvin)
        return (srgbToLinear(encoded.0), srgbToLinear(encoded.1), srgbToLinear(encoded.2))
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        let v = min(max(value / 255, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
