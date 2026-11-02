import Foundation

/// The one definition of the S4.5 show-mask wash: its blend strength and its red.
///
/// `s4_show_mask.metal` mixes `image` with red at `strength * coverage`. The renderer used to spell
/// the pair as a literal in `RenderGraph` and the UI had no second copy; 247's brush ring shares the
/// same red so the ring and the mask overlay cannot drift apart.
public enum MaskOverlay {
    /// S4.5's blend strength: half the pixel's colour comes from the mask red at full coverage.
    public static let strength: Float = 0.5
    /// S4.5's red — `(1, 0, 0)` in the display-encoded output.
    public static let red = SIMD3<Float>(1, 0, 0)
}
