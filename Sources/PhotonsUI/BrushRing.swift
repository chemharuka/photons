import AppKit
import PhotonsCore

/// 247 — the brush ring's one source of truth: how big a spot is on screen, and what colour the
/// ring draws with.
///
/// A heal spot's radius is a **fraction of the frame's short edge**, while the canvas draws in
/// **points** and the projection (`LoupeMapping`) is in **device pixels**. The conversion has two
/// halves and neither belongs to the view: `radius × shortEdge × canvasPerSource` is the diameter
/// in device pixels, and dividing by the backing scale is the same number in points. Writing it
/// once here is what keeps the ring, a future mask-size indicator and the hit tests from drifting.
public enum BrushRing {

    /// Outer stroke, in points.
    public static let lineWidth: CGFloat = 1
    /// White inner stroke, in points — the contrast line the mask overlay also needs on a bright
    /// photograph.
    public static let innerLineWidth: CGFloat = 0.5

    /// The mask overlay's red, taken from `MaskOverlay.red` so the ring never has a second red.
    public static let color: NSColor = NSColor(srgbRed: CGFloat(MaskOverlay.red.x),
                                               green: CGFloat(MaskOverlay.red.y),
                                               blue: CGFloat(MaskOverlay.red.z),
                                               alpha: 1)

    /// The ring radius in **device pixels**.
    ///
    /// `shortEdgeFraction` is a `HealSpot.radius` (short-edge units of the S2 frame). `frameSize`
    /// is that frame in source pixels and `mapping.canvasPerSource` is the one isotropic projection
    /// scale (device px per source px) — deliberately not two per-axis ratios.
    public static func radiusInDevicePixels(shortEdgeFraction: Double,
                                            frameSize: ImageSize,
                                            mapping: LoupeMapping) -> Double {
        let shortEdge = Double(min(max(frameSize.width, 0), max(frameSize.height, 0)))
        let radius = shortEdgeFraction * shortEdge * mapping.canvasPerSource
        return radius.isFinite ? radius : 0
    }

    /// The same radius in **view points** (`device px / backingScale`).
    public static func radiusInPoints(shortEdgeFraction: Double,
                                      frameSize: ImageSize,
                                      mapping: LoupeMapping,
                                      backingScale: CGFloat) -> Double {
        let scale = Double(backingScale)
        let divisor = scale.isFinite && scale > 0 ? scale : 1
        return radiusInDevicePixels(shortEdgeFraction: shortEdgeFraction,
                                    frameSize: frameSize,
                                    mapping: mapping) / divisor
    }
}
