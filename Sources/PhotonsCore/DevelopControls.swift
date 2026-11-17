import Foundation
import PhotonsLocalization

/// Shared inspector definitions; platform shells choose layout, not parameter semantics.
public struct DevelopControl: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var range: ClosedRange<Double>
    public var format: String
    public var keyPath: WritableKeyPath<EditModel, Double>
    public var decimals: Int = 0
    public var precise: Bool = false
    public var quantum: Double = 0
    public var linear: Bool = false
    public var defaultValue: Double { EditModel.neutral[keyPath: keyPath] }
}
public enum DevelopControls {
    public static let lightRows: [DevelopControl] = [
        DevelopControl(id: "light.exposure", title: L10n.tr("bc7dacff87db"), range: -4 ... 8, format: "%.2f EV", keyPath: \.light.exposure,
                decimals: 2, precise: true, quantum: 0.01),
        DevelopControl(id: "light.contrast", title: L10n.tr("bc4b2dbbb77b"), range: -100 ... 100, format: "%.0f", keyPath: \.light.contrast,
                decimals: 1),
        DevelopControl(id: "light.highlights", title: L10n.tr("f799c2308083"), range: -100 ... 100, format: "%.0f", keyPath: \.light.highlights,
                decimals: 1),
        DevelopControl(id: "light.midtones", title: L10n.tr("280d2d14de93"), range: -100 ... 100, format: "%.0f", keyPath: \.light.midtones,
                decimals: 1),
        DevelopControl(id: "light.shadows", title: L10n.tr("a0fb1c62d0e8"), range: -100 ... 100, format: "%.0f", keyPath: \.light.shadows,
                decimals: 1),
        DevelopControl(id: "light.whites", title: L10n.tr("f56e7eff58bf"), range: -100 ... 100, format: "%.0f", keyPath: \.light.whites,
                decimals: 1),
        DevelopControl(id: "light.blacks", title: L10n.tr("ed7d2c54184b"), range: -100 ... 100, format: "%.0f", keyPath: \.light.blacks,
                decimals: 1),
    ]
    public static let colorRows: [DevelopControl] = [
        DevelopControl(id: "color.vibrance", title: L10n.tr("ea9f8caa4ed3"), range: -100 ... 100, format: "%.0f",
                keyPath: \.color.vibrance, decimals: 1),
        DevelopControl(id: "color.saturation", title: L10n.tr("1394938c0161"), range: -100 ... 100, format: "%.0f",
                keyPath: \.color.saturation, decimals: 1),
    ]
    public static let vignetteRows: [DevelopControl] = [
        DevelopControl(id: "effects.vignetteAmount", title: L10n.tr("da89443e202b"), range: -100 ... 100, format: "%.0f",
                keyPath: \.effects.vignetteAmount, linear: true),
        DevelopControl(id: "effects.vignetteMidpoint", title: L10n.tr("6d0d9fcc7f37"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.vignetteMidpoint, linear: true),
        DevelopControl(id: "effects.vignetteFeather", title: L10n.tr("a3382c24d9e9"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.vignetteFeather, linear: true),
    ]
    public static let grainRows: [DevelopControl] = [
        DevelopControl(id: "effects.grain", title: L10n.tr("a08cd6ad31a2"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.grain),
        DevelopControl(id: "effects.grainSize", title: L10n.tr("b5d27bfa565b"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.grainSize),
        DevelopControl(id: "effects.grainRoughness", title: L10n.tr("4208ff3a2c8b"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.grainRoughness),
        DevelopControl(id: "effects.grainSeed", title: L10n.tr("5e20fc223736"), range: 0 ... 999, format: "%.0f",
                keyPath: \.effects.grainSeed, quantum: 1),
    ]
    public static let textureClarityRows: [DevelopControl] = [
        DevelopControl(id: "effects.texture", title: L10n.tr("262348fa5f3e"), range: -100 ... 100, format: "%.0f",
                keyPath: \.effects.texture),
        DevelopControl(id: "effects.clarity", title: L10n.tr("0e22652107f5"), range: -100 ... 100, format: "%.0f",
                keyPath: \.effects.clarity),
    ]
    public static let nonBayerRows: [DevelopControl] = [
        DevelopControl(id: "effects.nonBayerLuminanceNR", title: L10n.tr("da6c0db97b87"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.nonBayerLuminanceNR),
        DevelopControl(id: "effects.nonBayerColorNR", title: L10n.tr("ad51d63abfc2"), range: 0 ... 100, format: "%.0f",
                keyPath: \.effects.nonBayerColorNR),
    ]
    public static let sharpenRows: [DevelopControl] = [
        DevelopControl(id: "sharpen.amount", title: L10n.tr("b0dbdc47bcc2"), range: 0 ... 150, format: "%.0f",
                keyPath: \.sharpen.amount),
        DevelopControl(id: "sharpen.radius", title: L10n.tr("e9c8b36e09c7"), range: 0.5 ... 3.0, format: "%.1f",
                keyPath: \.sharpen.radius),
        DevelopControl(id: "sharpen.detail", title: L10n.tr("ca1caeef1733"), range: 0 ... 100, format: "%.0f",
                keyPath: \.sharpen.detail),
        DevelopControl(id: "sharpen.masking", title: L10n.tr("4b16c5d8dbf4"), range: 0 ... 100, format: "%.0f",
                keyPath: \.sharpen.masking),
    ]
    public static let dehazeRows: [DevelopControl] = [
        DevelopControl(id: "effects.dehaze", title: L10n.tr("0665cca26772"), range: -100 ... 100, format: "%.0f",
                keyPath: \.effects.dehaze, linear: true),
    ]
}
