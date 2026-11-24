import Foundation

/// 409 — the old automatic decoder-version namespace, now a **transitional forwarding shell**.
///
/// §555 Phase 2 folded 409 into `DecoderVersionPreference`: the crop normalisation and threshold
/// live there, and `resolve(policy:preference:iso:cropFactor:stored:resolved:in:)` is the **one**
/// automatic-version entry point in the repository. `requestedVersion` / `availableV9` /
/// `v9Spellings` are gone on purpose — keeping them would have left a second rule that could
/// disagree with the 555 table (for example, 409 always preferred `9.dng`, while 555 prefers bare
/// `9`, and 409 could not be suppressed by 设置 → 优先 v8).
///
/// The helpers below are kept only so callers that predate 555 do not all have to move in the same
/// change. They forward to `DecoderVersionPreference` and carry no behaviour of their own. New code
/// should call `DecoderVersionPreference` directly.
@available(*, deprecated, renamed: "DecoderVersionPreference")
public enum DecoderAutoVersion {

    public static var fullFrameBaseISO: Double { DecoderVersionPreference.fullFrameBaseISO }
    public static var cropRange: ClosedRange<Double> { DecoderVersionPreference.cropRange }
    public static var assumedCropFactor: Double { DecoderVersionPreference.assumedCropFactor }

    public static func cropFactor(focalLength: Double?, focalLength35mm: Double?) -> Double? {
        DecoderVersionPreference.cropFactor(focalLength: focalLength,
                                            focalLength35mm: focalLength35mm)
    }

    public static func cropFactor(orFullFrame focalLength: Double?,
                                  _ focalLength35mm: Double?) -> Double {
        DecoderVersionPreference.cropFactor(orFullFrame: focalLength, focalLength35mm)
    }

    public static func thresholdISO(crop sensorCrop: Double) -> Double {
        DecoderVersionPreference.thresholdISO(crop: sensorCrop)
    }

    public static func shouldUpgrade(iso: Int?, crop: Double = assumedCropFactor) -> Bool {
        DecoderVersionPreference.shouldUpgrade(iso: iso, crop: crop)
    }
}
