import Foundation

/// **路线 B's bill, paid where it is cheapest: the eyedropper.**
///
/// Since 194 the *settled* frame is `CIRAWFilter`'s answer, while the dropper's first solve is
/// `WhiteBalanceSolver`'s analytic model. Measured on the user's own grey patch (L1030433, 1/8 rung),
/// the settled frame at the solver's pair still carries a **13.71 %** cast: the model is a Planckian
/// fit and the decoder balances in camera space with its own primaries. Drag-and-settle can live with
/// that (路线 B accepts the jump), but a *dropper* cannot — it is a one-shot action whose whole promise
/// is "this pixel is now grey", and it happens once per click, so it can afford what a drag cannot:
/// **a few real developments.**
///
/// So the click is: solve analytically (instant), then **iterate against the decoder** — develop, read
/// the same pixel back off the developed buffer, and take a Newton step on `(log₂ K, tint)` with the
/// Jacobian measured from two single-axis probes. The budget is **four developments** (the settle plus
/// three steps, `maxDecodes`), each at the rung the loupe is already at, which is ~0.2 s each at 1/8
/// scale on a 60 MP file — under the 1.5 s the task allows, and it runs off the main thread
/// (`WhiteBalanceCommands.beginDropper`).
///
/// The target is **2 %**, the pre-194 gate, and it is a gate, not a wish: when the budget cannot reach
/// it the report says so and carries the whole convergence curve (`attempts`), because a dropper that
/// quietly stops at 9 % is worse than one that says "9 %".
public enum WhiteBalanceDropperRefiner {

    /// The residual the click owes: max channel deviation from the mean, as a fraction.
    public static let targetChroma = 0.02
    /// Developments one click may spend: the settle + two single-axis probes + two Newton steps.
    public static let maxDecodes = 5
    /// The rung the iteration measures on: **the click's own rung**.
    ///
    /// 1/16 was tried to save time and is a false economy twice over: `CIRAWFilter` costs ~580 ms per
    /// development on this 60 MP file at *any* rung (ImageIO demosaics the whole frame — measured
    /// 585 ms at 1/16 against 564–715 ms at 1/8), and a coarser rung averages a different patch, so a
    /// strongly coloured sample was driven to 0.3 % *on the wrong pixels* while the frame that settles
    /// carried 43.8 %. Measuring where the user clicked is both cheaper than the mistake. The cost is
    /// reported as `decoderMillisecondsPerDevelopment` instead of being hidden in a scale factor.
    public static let decoderMillisecondsPerDevelopment: Double = 700
    /// The single-axis probe along Kelvin (0.125 stop — the "small step" the iteration is built on).
    public static let kelvinProbeStops = 0.125
    /// The single-axis probe along tint.
    public static let tintProbeUnits = 5.0

    // MARK: - values

    /// One development and the pixel it produced at the sampled point.
    public struct Attempt: Sendable {
        public let whiteBalance: WhiteBalance
        public let sample: RGBSample
        public let milliseconds: Double
        /// `true` for the two single-axis probes the Jacobian reads (they are measurements, not
        /// candidates: the click never ends on one).
        public let isProbe: Bool

        public var chroma: Double { sample.chroma }
        public var text: String {
            String(format: "%@ · chroma %.2f%% · RGB %@ · %.0f ms%@",
                   whiteBalance.summary, sample.chroma * 100, sample.text, milliseconds,
                   isProbe ? " · probe" : "")
        }
    }

    /// What one click actually did: the curve, the answer, and whether it met the gate.
    public struct Refinement: Sendable {
        public let initial: WhiteBalance
        public let attempts: [Attempt]
        public let target: Double
        public let failure: String?

        public var final: WhiteBalance { attempts.last?.whiteBalance ?? initial }
        public var finalSample: RGBSample { attempts.last?.sample ?? .black }
        public var residual: Double { attempts.last?.sample.chroma ?? 1 }
        public var decodes: Int { attempts.count }
        /// Steps taken after the settle (the settle is the decode the click already costs).
        public var iterations: Int { max(0, attempts.filter { !$0.isProbe }.count - 1) }
        public var milliseconds: Double { attempts.reduce(0) { $0 + $1.milliseconds } }
        public var converged: Bool { residual <= target }
        public var clamped: Bool {
            let f = final
            return f != f.clamped()
        }

        /// One line for the inspector's hint, then the whole convergence curve: the residual, the cost,
        /// and every attempt (probes included) whether it converged or not — "how many developments it
        /// needed" is the number the next reader will want.
        public var text: String {
            let head = String(format: "吸管精修 %.2f%%（目标 %.0f%%）· %d 次解码 · %.0f ms%@%@",
                              residual * 100, target * 100, decodes, milliseconds,
                              converged ? "" : " · 未达标",
                              failure.map { " · \($0)" } ?? "")
            return ([head] + attempts.map { "  " + $0.text }).joined(separator: "\n")
        }
    }

    /// Where to read: the file, the rung the click resolved on, and the buffer pixel it landed on.
    ///
    /// `measurementScale` defaults to the click's own rung — the same pixels the user is looking at.
    public struct Probe: Sendable {
        public let url: URL
        public let scale: Float
        public let x: Int
        public let y: Int
        public let measurementScale: Float

        public init(url: URL, scale: Float, x: Int, y: Int, measurementScale: Float? = nil) {
            self.url = url
            self.scale = scale
            self.x = x
            self.y = y
            self.measurementScale = measurementScale ?? scale
        }

        /// The same picture point on the iteration's rung.
        public var measurementPoint: (x: Int, y: Int) {
            guard scale > 0, measurementScale != scale else { return (x, y) }
            let k = Double(measurementScale) / Double(scale)
            return (Int((Double(x) * k).rounded()), Int((Double(y) * k).rounded()))
        }
    }

    /// Develop a file at a pair. Injectable so a test can count, cache or stub the development — the
    /// default is the decoder the app uses.
    public typealias Develop = @Sendable (URL, Float, WhiteBalance) throws -> LinearImage

    public static let decoderDevelop: Develop = { url, scale, pair in
        try RAWDecoder().decode(url, options: DecodeOptions(scale: scale, whiteBalance: pair))
    }

    // MARK: - the loop

    /// The click: `initial` is the analytic solve, and the answer is what the *decoder* had to say.
    ///
    /// Each step is a development at a candidate pair followed by reading the very pixel the user
    /// clicked. The Jacobian of `(log(b/r), log((r+b)/2g))` against `(log₂ K, tint)` is measured with
    /// two single-axis probes, then one Newton step lands the click; the loop stops early as soon as
    /// the residual is within `target`. Nothing here touches the document — the caller writes the
    /// final pair **once**, which is what keeps one click one history entry.
    public static func refine(initial: WhiteBalance,
                              probe: Probe,
                              target: Double = targetChroma,
                              maxDecodes: Int = maxDecodes,
                              develop: Develop = decoderDevelop) -> Refinement {
        var attempts: [Attempt] = []
        var failure: String?

        func measure(_ pair: WhiteBalance, isProbe: Bool = false) -> Attempt? {
            let clamped = pair.clamped()
            let point = probe.measurementPoint
            let started = Date()
            do {
                let image = try develop(probe.url, probe.measurementScale, clamped)
                let sample = image.averageRGB(x: point.x, y: point.y)
                let attempt = Attempt(whiteBalance: clamped, sample: sample,
                                      milliseconds: Date().timeIntervalSince(started) * 1000,
                                      isProbe: isProbe)
                attempts.append(attempt)
                return attempt
            } catch {
                failure = "精修解码失败：\(error)"
                return nil
            }
        }

        guard measure(initial) != nil, let first = attempts.first else {
            return Refinement(initial: initial, attempts: attempts, target: target, failure: failure)
        }
        // A patch the model already made neutral needs no development at all.
        guard first.sample.chroma > target, first.sample.mean > 1e-6 else {
            return Refinement(initial: initial, attempts: attempts, target: target, failure: failure)
        }

        // The coordinates the Newton step moves in: Kelvin in stops (so a step is perceptual), tint in
        // its own units. The first iteration measures the Jacobian with two single-axis probes; the
        // second reuses it (the response is locally linear, and a probe costs as much as a step).
        var best = first
        var logK = log2(max(first.whiteBalance.temperature ?? 6000, 1))
        var tint = first.whiteBalance.tint ?? 0
        var jacobian: (drb_dk: Double, dgm_dk: Double, drb_dt: Double, dgm_dt: Double)?

        while attempts.count < maxDecodes, !failure_blocked(failure) {
            let c0 = cast(best.sample)
            if jacobian == nil {
                guard attempts.count + 3 <= maxDecodes else { break }
                guard let alongK = measure(WhiteBalance(temperature: exp2(logK + kelvinProbeStops),
                                                        tint: tint), isProbe: true),
                      let alongT = measure(WhiteBalance(temperature: exp2(logK),
                                                        tint: tint + tintProbeUnits), isProbe: true)
                else { break }
                let c1 = cast(alongK.sample), c2 = cast(alongT.sample)
                // J = [ (c1−c0)/h , (c2−c0)/w ] — measured, not modelled.
                jacobian = ((c1.rb - c0.rb) / kelvinProbeStops,
                            (c1.gm - c0.gm) / kelvinProbeStops,
                            (c2.rb - c0.rb) / tintProbeUnits,
                            (c2.gm - c0.gm) / tintProbeUnits)
            }
            guard let j = jacobian else { break }
            guard attempts.count + 1 <= maxDecodes else { break }

            let det = j.drb_dk * j.dgm_dt - j.drb_dt * j.dgm_dk
            var step: (k: Double, t: Double)
            if det.isFinite, abs(det) > 1e-9 {
                // Solve J · δ = −c0.
                step = (min(max((-c0.rb * j.dgm_dt + c0.gm * j.drb_dt) / det, -6), 6),
                        min(max((-c0.gm * j.drb_dk + c0.rb * j.dgm_dk) / det, -80), 80))
            } else {
                // A singular Jacobian (the axes barely move the cast): the dominant axis alone, so the
                // click still improves rather than bailing. Reported, not hidden.
                failure = "精修：雅可比退化，改用单轴步"
                step = abs(c0.rb) >= abs(c0.gm) ? (-c0.rb, 0) : (0, -c0.gm / 0.001)
            }
            guard abs(step.k) > 1e-6 || abs(step.t) > 1e-6 else { break }

            guard let landed = measure(WhiteBalance(temperature: exp2(logK + step.k),
                                                    tint: tint + step.t)) else { break }
            best = landed
            logK = log2(max(landed.whiteBalance.temperature ?? 6000, 1))
            tint = landed.whiteBalance.tint ?? 0
            if landed.sample.chroma <= target { break }
            let moved = cast(landed.sample)
            if abs(moved.rb - c0.rb) < 1e-6 && abs(moved.gm - c0.gm) < 1e-6 {
                failure = "精修：解码器对这对值没有响应"
                break
            }
        }

        return Refinement(initial: initial, attempts: attempts, target: target, failure: failure)
    }

    /// A failure that must stop the loop (a decode error) as opposed to one that merely explains it.
    private static func failure_blocked(_ failure: String?) -> Bool {
        failure?.contains("解码失败") ?? false
    }

    // MARK: - cast

    /// The patch's cast as two signed logs: red/blue (Kelvin's axis) and green vs magenta (tint's).
    /// Zero on both is grey; the sign says which way the frame is off, which is what the Newton step
    /// reads.
    static func cast(_ sample: RGBSample) -> (rb: Double, gm: Double) {
        let r = max(sample.r, 1e-6), g = max(sample.g, 1e-6), b = max(sample.b, 1e-6)
        return (log(b / r), log((r + b) / 2 / g))
    }
}
