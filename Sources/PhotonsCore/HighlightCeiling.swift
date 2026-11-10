import Foundation

/// 320 — **the picture's highest brightness**, as one adjustable number.
///
/// The user's report (2026-11-03): after +5 EV the picture, the histogram and the pointer's readout
/// all stopped at **+2 EV** (linear 4.0) — 「现在应该是有 +2 的最高亮度限制，这个需要加到 UI 里面以便用户
/// 调整。这个值默认设置为 +2.3」.
///
/// **Where the 4.0 came from.** Not from `DisplayOptions.headroom` (the panel's own ceiling, 1.0 on
/// this machine), not from `Histogram.maxStops` / `HDRCurveAxis.xHI` (both +4 EV = 16), not from
/// `SDRToneMap.maxHeadroom` (6, export only) — from the **display-referred tail guards**:
/// `s3_10_sharpen.metal:402` wrote `clamp(rgb + delta, 0.0, 4.0)` on every document, because 314
/// left 锐化's resting amount at 50 (`SharpenGroup.init`), i.e. the pass — and its 4.0 — has been on
/// by default. `s3_8_detail_fx.metal` and `s3_7_grain.metal` carry the same literal, so the ceiling
/// was 4.0 no matter which of the three effects was on. Those three guards are where the value now
/// comes from, and `s2_tone_map.metal` applies it once at the end of the tone map so the ceiling is a
/// property of the picture and not of 锐化 being non-zero. The probe table and the file:line are in
/// `Tests/PhotonsCoreTests/HighlightCeilingTests.swift`.
///
/// **Why a preference and not a document field.** The ceiling is a display decision (how much light
/// the photograph is allowed to keep on its way to the screen), like 画布底色 — not something a
/// document carries, so two photos do not disagree about it and a preset cannot import it.
public enum HighlightCeiling {

    /// `photons.highlightCeilingEV`. Stored in **EV above SDR white**, which is the unit the card's
    /// row and the histogram's tail both print; the renderers take `pow(2, ev)`.
    public static let defaultsKey = "photons.highlightCeilingEV"

    /// +2.3 EV — the owner's number (线性 4.925). It is above the 2^2 = 4.0 the old hard literal
    /// clipped at, so the default alone already frees 0.3 stop of highlight the picture used to lose
    /// silently.
    public static let defaultEV: Double = 2.3

    /// 0…+4 EV, the histogram's own tail (`Histogram.maxStops = 4`, `HDRCurveAxis.xHI = 16`): a
    /// ceiling past +4 EV would be off the axis the card draws, and the row would move a control no
    /// reading could show.
    public static let evRange: ClosedRange<Double> = 0 ... 4

    /// 0.1 EV per tick — the precision the readout prints (`+2.3 EV`).
    public static let stepEV: Double = 0.1

    /// `2^2.3 = 4.924577653378805` — the linear default, so a caller that builds `DisplayOptions` by
    /// hand and a caller that reads the preference agree to the bit.
    public static var defaultLinear: Double { linear(ev: defaultEV) }

    /// The linear ceiling for an EV value, clamped into `evRange`.
    public static func linear(ev: Double) -> Double {
        pow(2.0, clampEV(ev))
    }

    /// Clamp and snap to the row's 0.1 grid. `nil`/non-finite falls back to the default.
    public static func clampEV(_ ev: Double?) -> Double {
        guard let ev, ev.isFinite else { return defaultEV }
        let bounded = min(max(ev, evRange.lowerBound), evRange.upperBound)
        return (bounded / stepEV).rounded() * stepEV
    }

    /// The number the row shows today. Read on every use (never cached), like
    /// `CanvasBackdrop.current`: a value cached at window open would survive the row that changed it.
    public static var currentEV: Double {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Double else {
            return defaultEV
        }
        return clampEV(stored)
    }

    /// The linear ceiling the renderers want: `pow(2, currentEV)`.
    public static var current: Double { linear(ev: currentEV) }

    /// Persist an EV value and tell the producers that cache a render to re-read it. The stored form
    /// is the Double itself (not a string), so `photons.defaults` shows a number in EV.
    public static func setEV(_ ev: Double) {
        let value = clampEV(ev)
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(name: .highlightCeilingDidChange, object: nil)
    }

    /// The readout's own spelling: `+2.3 EV` (always signed — it is light above white, and a bare
    /// `2.3 EV` next to the histogram's `+2.3` tick would read as two different numbers).
    public static func label(_ ev: Double) -> String {
        String(format: "%+.1f EV", clampEV(ev))
    }
}

public extension Notification.Name {
    /// Posted by `HighlightCeiling.setEV(_:)` after the preference is written. The loupe re-renders
    /// the frame it already has, so the change is visible in the same turn.
    static let highlightCeilingDidChange = Notification.Name("photons.highlightCeilingDidChange")
}
