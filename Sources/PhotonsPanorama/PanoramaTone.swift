import Foundation
import CoreImage

/// Output adjustments in scene-linear light, shared by preview, histogram, worker and export.
/// A missing highlight limit keeps legacy documents neutral. New panorama UIs offer a 4× white
/// default; changing it only compresses highlights, never rescales the picture from its peak.
public struct PanoramaToneSettings: Codable, Equatable, Sendable {
    public var exposureEV: Double
    public var highlightHeadroom: Double?
    public init(exposureEV: Double = 0, highlightHeadroom: Double? = nil) {
        self.exposureEV = exposureEV; self.highlightHeadroom = highlightHeadroom
    }
    public static let panoramaDefault = Self(highlightHeadroom: 4)
    public var isValid: Bool {
        exposureEV.isFinite && (-8...8).contains(exposureEV)
            && (highlightHeadroom.map { $0.isFinite && (1...16).contains($0) } ?? true)
    }
}

enum PanoramaToneMapping {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 panoramaHighlights(__sample s, float ceiling) {
            vec3 v = s.a > 0.000001 ? s.rgb / s.a : vec3(0.0);
            float peak = max(v.r, max(v.g, v.b));
            float knee = min(1.0, ceiling * 0.8);
            float span = ceiling - knee;
            float excess = max(0.0, peak - knee);
            float mapped = knee + span * excess / (span + excess);
            float gain = peak > knee ? mapped / peak : 1.0;
            return vec4(v * gain * s.a, s.a);
        }
        """)!

    static func image(_ input: CIImage, settings: PanoramaToneSettings, lccProtection: Bool) -> CIImage {
        var image = settings.exposureEV == 0 ? input : input.applyingFilter("CIExposureAdjust",parameters: ["inputEV": settings.exposureEV])
        if let headroom = settings.highlightHeadroom ?? (lccProtection ? 4 : nil) {
            image = kernel.apply(extent: image.extent,arguments: [image,headroom])!
        }
        return image
    }
}
