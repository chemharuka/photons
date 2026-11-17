import Foundation

/// 409 — **which decoder version a document that asks for nothing should get**.
///
/// The user's rule (2026-11-16), in their words:
///
/// > 在 ISO 大于 800（全画幅基准）的照片中，默认解码版本换成 dng9 或者 v9（当然，前提是可以使用）。
/// > 对于 m43 这个值是 ISO 200，画幅越大上限越高
/// > 传感器尺寸通过物理焦距和等效焦距算出
/// > 如果算不出画幅就默认全画幅
///
/// Three consequences shape this type:
///
///   · **The document stays `nil`.** The rule runs at decode time from EXIF + the file's own
///     `supportedDecoderVersions`; `EditModel.decoderVersion` is never written by it. So changing the
///     rule changes pixels of existing photos — accepted by the user, and made identifiable by the
///     `DecodeRecipe` bump that ships with it.
///   · **The crop factor is `FocalLenIn35mmFilm / FocalLength`, nothing else.** No body table: a file
///     whose EXIF cannot answer (either value missing, zero, or the ratio outside `0.5…4.0`) is treated
///     as **full frame** (`crop = 1`), exactly as the user asked.
///   · **"可以用" is the file's own list.** A body that offers `9.dng` but not bare `9` (this machine's
///     SL3 does exactly that, `DecoderCapabilities` header) must be handed the spelling it whitelists;
///     assigning another one is a silent no-op that reads back v8 (`DecoderCapabilities.swift:7-11`).
///
/// The threshold is the standard equivalent-ISO normalisation — `ISO_equiv = ISO_actual · crop²` —
/// so "equivalent ISO above 800" is `ISO_actual > 800 / crop²`. It reproduces both anchors the user
/// gave: full frame 800, m4/3 (crop 2.0) 200.
///
/// **Changing any constant below — `fullFrameBaseISO`, `cropRange`, `v9Spellings`, or the way the
/// threshold is computed — must bump `DecodeRecipe.current` in the same change.** This rule does not
/// enter the decode key (a document that asks for nothing is always spelled `ver=auto`), so a buffer
/// decoded by the old rule and a buffer the new rule would ask for carry the *same* key: nothing but
/// the recipe token can tell the two generations apart. `DecodeRecipe.current` is the **only**
/// invalidation mechanism this rule has.
public enum DecoderAutoVersion {

    /// The full-frame reference the user named: 「ISO 大于 800（全画幅基准）」.
    public static let fullFrameBaseISO: Double = 800

    /// The crop range the ratio is trusted in: medium format ≈0.6 … 1" ≈2.7, 4.0 leaves room for the
    /// small sensors and nothing beyond. Outside it the EXIF pair is treated as unreliable ⇒ full frame.
    public static let cropRange: ClosedRange<Double> = 0.5...4.0

    /// The crop factor an unreadable file is decoded at — full frame, per the user's rule.
    public static let assumedCropFactor: Double = 1

    /// What to try when the rule says "v9", in this order and no other.
    ///
    /// `9.dng` first because it is the spelling the SL3 (and every DNG body measured here) whitelists;
    /// bare `9` second because some bodies offer only that. The order is fixed: probing both would
    /// mean a second assignment on the hot path for no gain.
    public static let v9Spellings = ["9.dng", "9"]

    /// 409 — 画幅比，从 EXIF 的两个焦距算出。`nil` ⇒ 调用方按全画幅处理（用户口径：
    /// 「如果算不出画幅就默认全画幅」）。
    ///
    /// Both values must exist and be positive; a ratio outside `cropRange` is treated as untrustworthy
    /// EXIF rather than as a sensor (`25 / 200 = 8.0` is not a format we know).
    public static func cropFactor(focalLength: Double?, focalLength35mm: Double?) -> Double? {
        guard let f = focalLength, let f35 = focalLength35mm, f > 0, f35 > 0 else { return nil }
        let k = f35 / f
        guard cropRange.contains(k) else { return nil }
        return k
    }

    /// The crop a file is actually decoded at: the measured one, else full frame.
    public static func cropFactor(orFullFrame focalLength: Double?, _ focalLength35mm: Double?) -> Double {
        cropFactor(focalLength: focalLength, focalLength35mm: focalLength35mm) ?? assumedCropFactor
    }

    /// `thresholdISO(crop) = 800 / crop²` — the actual-ISO value at which the equivalent ISO reaches
    /// the full-frame 800 reference. Full frame 800, m4/3 (2.0) 200, APS-C (1.53) 340,
    /// medium format (0.79) 1293, 1" (2.73) 108.
    ///
    /// A non-positive or non-finite crop is a broken input, not a format: it answers the full-frame
    /// threshold instead of dividing by zero.
    public static func thresholdISO(crop: Double) -> Double {
        guard crop.isFinite, crop > 0 else { return fullFrameBaseISO }
        return fullFrameBaseISO / (crop * crop)
    }

    /// 「大于 800」 is **strictly** greater — an actual ISO exactly at the threshold does not upgrade.
    /// No reading of ISO is a "no" (we cannot prove the file is noisy), and neither is no crop: the
    /// caller passes `1` for full frame.
    public static func shouldUpgrade(iso: Int?, crop: Double = assumedCropFactor) -> Bool {
        guard let iso else { return false }
        return Double(iso) > thresholdISO(crop: crop)
    }

    /// The first spelling of `v9Spellings` this file offers, or `nil` when it offers none.
    public static func availableV9(in offered: [String]) -> String? {
        v9Spellings.first(where: { offered.contains($0) })
    }

    /// The final answer of §2.3, as one pure function:
    ///
    ///   1. an explicit document choice wins and is **not** second-guessed;
    ///   2. otherwise the rule may ask for v9, and only for a spelling the file offers;
    ///   3. otherwise `nil` — the pre-409 behaviour (Apple's default, v8 today) byte for byte.
    ///
    /// The caller still has to assign and **read back**: a whitelisted spelling can still be refused
    /// by a filter, and `DecoderCapabilities.downgraded` is where that shows up.
    public static func requestedVersion(explicit: String?,
                                        iso: Int?,
                                        focalLength: Double?,
                                        focalLength35mm: Double?,
                                        offered: [String]) -> String? {
        if let explicit { return explicit }
        let crop = cropFactor(orFullFrame: focalLength, focalLength35mm)
        guard shouldUpgrade(iso: iso, crop: crop) else { return nil }
        return availableV9(in: offered)
    }
}
