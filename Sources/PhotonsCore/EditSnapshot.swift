import Foundation

// MARK: - Copy/paste settings (M5)
//
// "Copy settings" is not "copy the document". Pasting a whole `EditModel` would drag along every
// field the user never touched — 57 leaves of defaults for a one-slider edit — and, worse, would
// overwrite the destination's own values with those defaults. Lightroom's copy/paste copies
// *settings*, and the UI shows a checklist of exactly which ones are non-default.
//
// So the clipboard payload is **sparse**: one optional per leaf parameter, present only when it
// differs from `EditModel`'s default value (the same defaults the document decoder falls back to,
// D9). Three consequences, each tested:
//
//  1. Copying a document that changed one slider carries exactly one field.
//  2. Pasting onto a document that already has an edit changes only those fields — the
//     destination's other values survive, which is the whole point of "paste settings".
//  3. Copying a *neutral* document carries nothing, and pasting nothing is a no-op.
//
// Masks are **not** in this type at all: mask geometry is normalised to the source frame and is
// meaningless on another photo (docs/xmp-mapping.md §1.8, docs/architecture-decisions.md D11), so
// paste never touches `masks` or `showMaskID`. That is a structural guarantee, not a rule the
// merge code has to remember.

/// Which fields belong to which group. Used for reporting what a clipboard payload carries.
public enum EditSnapshotGroup: String, CaseIterable, Sendable, Hashable {
    case geometry, light, curve, color, detail, effects
}

// MARK: - patches

/// Geometry, leaf by leaf. A crop rect is normally stored whole (capture sees four changed
/// components), but each edge is its own field so a paste that changes only `x` keeps the
/// destination's width.
public struct GeometryPatch: Sendable, Equatable, Codable {
    public var cropX: Double?
    public var cropY: Double?
    public var cropWidth: Double?
    public var cropHeight: Double?
    public var rotationDegrees: Double?
    public var flipHorizontal: Bool?
    public var flipVertical: Bool?
    public var aspectLock: AspectLock?

    public init() {}

    public var fieldCount: Int {
        [cropX != nil, cropY != nil, cropWidth != nil, cropHeight != nil,
         rotationDegrees != nil, flipHorizontal != nil, flipVertical != nil,
         aspectLock != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    /// Leaf count of the whole group in a full document (see `EditSnapshot.fullDocumentFieldCount`).
    public static let fullFieldCount = 8
}

public struct LightPatch: Sendable, Equatable, Codable {
    public var exposure: Double?
    public var contrast: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var temperature: Double?
    public var tint: Double?
    public var highlightRecovery: Double?

    public init() {}

    public var fieldCount: Int {
        [exposure != nil, contrast != nil, highlights != nil, shadows != nil, whites != nil,
         blacks != nil, temperature != nil, tint != nil, highlightRecovery != nil]
            .filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 9
}

/// Tone curves: four LUTs, each stored only when it is not the identity ramp. A curve is one field
/// per channel, not 16 points — the points are the value.
public struct CurvePatch: Sendable, Equatable, Codable {
    public var rgb: [CurvePoint]?
    public var red: [CurvePoint]?
    public var green: [CurvePoint]?
    public var blue: [CurvePoint]?

    public init() {}

    public var fieldCount: Int {
        [rgb != nil, red != nil, green != nil, blue != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 4
}

/// One HSL band, sparse. `index` is position in Lightroom's eight-band order and is not a field.
public struct HSLBandPatch: Sendable, Equatable, Codable {
    public var index: Int
    public var hue: Double?
    public var saturation: Double?
    public var luminance: Double?

    public init(index: Int, hue: Double? = nil, saturation: Double? = nil, luminance: Double? = nil) {
        self.index = index
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var fieldCount: Int {
        [hue != nil, saturation != nil, luminance != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }
}

public struct ColorPatch: Sendable, Equatable, Codable {
    public var vibrance: Double?
    public var saturation: Double?
    /// Only the bands that differ from `HSLBand()`; absent bands are the destination's.
    public var bands: [HSLBandPatch]?

    public init() {}

    public var fieldCount: Int {
        [vibrance != nil, saturation != nil].filter { $0 }.count + (bands ?? []).reduce(0) { $0 + $1.fieldCount }
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 2 + ColorGroup.bandCount * 3
}

public struct DetailPatch: Sendable, Equatable, Codable {
    public var sharpening: Double?
    public var sharpeningRadius: Double?
    public var noiseLuminance: Double?
    public var noiseColor: Double?
    public var lensCorrections: Bool?

    public init() {}

    public var fieldCount: Int {
        [sharpening != nil, sharpeningRadius != nil, noiseLuminance != nil, noiseColor != nil,
         lensCorrections != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 5
}

public struct EffectsPatch: Sendable, Equatable, Codable {
    public var vignetteAmount: Double?
    public var vignetteMidpoint: Double?
    public var vignetteFeather: Double?
    public var vignetteRoundness: Double?
    public var grain: Double?

    public init() {}

    public var fieldCount: Int {
        [vignetteAmount != nil, vignetteMidpoint != nil, vignetteFeather != nil,
         vignetteRoundness != nil, grain != nil].filter { $0 }.count
    }

    public var isEmpty: Bool { fieldCount == 0 }

    public static let fullFieldCount = 5
}

// MARK: - the snapshot

/// A sparse, transferable set of develop settings: the clipboard payload of "copy settings".
public struct EditSnapshot: Sendable, Equatable, Codable {
    /// Bumped when the sparse shape changes. Independent of `EditModel.currentSchemaVersion`; a
    /// snapshot is a message, not a document.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var geometry: GeometryPatch?
    public var light: LightPatch?
    public var curve: CurvePatch?
    public var color: ColorPatch?
    public var detail: DetailPatch?
    public var effects: EffectsPatch?

    public init() {
        self.schemaVersion = EditSnapshot.currentSchemaVersion
    }

    // MARK: capture

    /// Everything in `edit` that differs from the neutral document. `masks` / `showMaskID` are
    /// absent by construction.
    public static func capture(_ edit: EditModel) -> EditSnapshot {
        var s = EditSnapshot()

        var geometry = GeometryPatch()
        if differs(edit.geometry.crop.x, NormalizedRect.full.x) { geometry.cropX = edit.geometry.crop.x }
        if differs(edit.geometry.crop.y, NormalizedRect.full.y) { geometry.cropY = edit.geometry.crop.y }
        if differs(edit.geometry.crop.width, NormalizedRect.full.width) { geometry.cropWidth = edit.geometry.crop.width }
        if differs(edit.geometry.crop.height, NormalizedRect.full.height) { geometry.cropHeight = edit.geometry.crop.height }
        if differs(edit.geometry.rotationDegrees, 0) { geometry.rotationDegrees = edit.geometry.rotationDegrees }
        if edit.geometry.flipHorizontal { geometry.flipHorizontal = true }
        if edit.geometry.flipVertical { geometry.flipVertical = true }
        if edit.geometry.aspectLock != .original { geometry.aspectLock = edit.geometry.aspectLock }
        s.geometry = geometry.isEmpty ? nil : geometry

        var light = LightPatch()
        if differs(edit.light.exposure, 0) { light.exposure = edit.light.exposure }
        if differs(edit.light.contrast, 0) { light.contrast = edit.light.contrast }
        if differs(edit.light.highlights, 0) { light.highlights = edit.light.highlights }
        if differs(edit.light.shadows, 0) { light.shadows = edit.light.shadows }
        if differs(edit.light.whites, 0) { light.whites = edit.light.whites }
        if differs(edit.light.blacks, 0) { light.blacks = edit.light.blacks }
        if differs(edit.light.temperature, 6500) { light.temperature = edit.light.temperature }
        if differs(edit.light.tint, 0) { light.tint = edit.light.tint }
        if differs(edit.light.highlightRecovery, 0) { light.highlightRecovery = edit.light.highlightRecovery }
        s.light = light.isEmpty ? nil : light

        var curve = CurvePatch()
        if !same(edit.curve.rgb, CurvePoint.linear) { curve.rgb = edit.curve.rgb }
        if !same(edit.curve.red, CurvePoint.linear) { curve.red = edit.curve.red }
        if !same(edit.curve.green, CurvePoint.linear) { curve.green = edit.curve.green }
        if !same(edit.curve.blue, CurvePoint.linear) { curve.blue = edit.curve.blue }
        s.curve = curve.isEmpty ? nil : curve

        var color = ColorPatch()
        if differs(edit.color.vibrance, 0) { color.vibrance = edit.color.vibrance }
        if differs(edit.color.saturation, 0) { color.saturation = edit.color.saturation }
        var bands: [HSLBandPatch] = []
        for (i, band) in ColorGroup.normalize(edit.color.bands).enumerated() {
            var patch = HSLBandPatch(index: i)
            if differs(band.hue, 0) { patch.hue = band.hue }
            if differs(band.saturation, 0) { patch.saturation = band.saturation }
            if differs(band.luminance, 0) { patch.luminance = band.luminance }
            if !patch.isEmpty { bands.append(patch) }
        }
        if !bands.isEmpty { color.bands = bands }
        s.color = color.isEmpty ? nil : color

        var detail = DetailPatch()
        if differs(edit.detail.sharpening, 0) { detail.sharpening = edit.detail.sharpening }
        if differs(edit.detail.sharpeningRadius, 1.0) { detail.sharpeningRadius = edit.detail.sharpeningRadius }
        if differs(edit.detail.noiseLuminance, 0) { detail.noiseLuminance = edit.detail.noiseLuminance }
        if differs(edit.detail.noiseColor, 0) { detail.noiseColor = edit.detail.noiseColor }
        if edit.detail.lensCorrections { detail.lensCorrections = true }
        s.detail = detail.isEmpty ? nil : detail

        var effects = EffectsPatch()
        if differs(edit.effects.vignetteAmount, 0) { effects.vignetteAmount = edit.effects.vignetteAmount }
        if differs(edit.effects.vignetteMidpoint, 50) { effects.vignetteMidpoint = edit.effects.vignetteMidpoint }
        if differs(edit.effects.vignetteFeather, 50) { effects.vignetteFeather = edit.effects.vignetteFeather }
        if differs(edit.effects.vignetteRoundness, 0) { effects.vignetteRoundness = edit.effects.vignetteRoundness }
        if differs(edit.effects.grain, 0) { effects.grain = edit.effects.grain }
        s.effects = effects.isEmpty ? nil : effects

        return s
    }

    // MARK: reading the payload

    /// Number of stored leaves. The point of the type: a one-slider copy is 1, the document it came
    /// from is `fullDocumentFieldCount` (57).
    public var fieldCount: Int {
        (geometry?.fieldCount ?? 0) + (light?.fieldCount ?? 0) + (curve?.fieldCount ?? 0)
            + (color?.fieldCount ?? 0) + (detail?.fieldCount ?? 0) + (effects?.fieldCount ?? 0)
    }

    public var isEmpty: Bool { fieldCount == 0 }

    /// Leaves a full `EditModel` carries — the denominator `fieldCount` is compared against.
    /// geometry 8 + light 9 + curve 4 + color 26 (2 + 8 bands × 3) + detail 5 + effects 5.
    public static let fullDocumentFieldCount =
        GeometryPatch.fullFieldCount + LightPatch.fullFieldCount + CurvePatch.fullFieldCount
        + ColorPatch.fullFieldCount + DetailPatch.fullFieldCount + EffectsPatch.fullFieldCount

    /// Groups with at least one field present, for a "copied: Light, Color" line.
    public var groups: Set<RenderGroup> {
        var out: Set<RenderGroup> = []
        if geometry != nil { out.insert(.geometry) }
        if light != nil { out.insert(.light) }
        if curve != nil { out.insert(.curve) }
        if color != nil { out.insert(.color) }
        if detail != nil { out.insert(.detail) }
        if effects != nil { out.insert(.effects) }
        return out
    }

    /// Groups whose values are semantically identical between the payload and `target` (i.e. a
    /// paste of those groups would change nothing). For a "nothing to paste" message.
    public func unchangedGroups(in target: EditModel) -> Set<RenderGroup> {
        let dirty = EditHistory.dirtyGroups(from: target, to: applied(to: target))
        return groups.subtracting(dirty)
    }

    // MARK: pasting

    /// `target` with the payload's fields written over it. Fields the payload does not carry keep
    /// the destination's value; `masks`, `showMaskID`, `schemaVersion` and `processVersion` are
    /// always the destination's.
    public func applied(to target: EditModel) -> EditModel {
        var out = target

        if let p = geometry {
            if let v = p.cropX { out.geometry.crop.x = v }
            if let v = p.cropY { out.geometry.crop.y = v }
            if let v = p.cropWidth { out.geometry.crop.width = v }
            if let v = p.cropHeight { out.geometry.crop.height = v }
            if let v = p.rotationDegrees { out.geometry.rotationDegrees = v }
            if let v = p.flipHorizontal { out.geometry.flipHorizontal = v }
            if let v = p.flipVertical { out.geometry.flipVertical = v }
            if let v = p.aspectLock { out.geometry.aspectLock = v }
        }

        if let p = light {
            if let v = p.exposure { out.light.exposure = v }
            if let v = p.contrast { out.light.contrast = v }
            if let v = p.highlights { out.light.highlights = v }
            if let v = p.shadows { out.light.shadows = v }
            if let v = p.whites { out.light.whites = v }
            if let v = p.blacks { out.light.blacks = v }
            if let v = p.temperature { out.light.temperature = v }
            if let v = p.tint { out.light.tint = v }
            if let v = p.highlightRecovery { out.light.highlightRecovery = v }
        }

        if let p = curve {
            if let v = p.rgb { out.curve.rgb = v }
            if let v = p.red { out.curve.red = v }
            if let v = p.green { out.curve.green = v }
            if let v = p.blue { out.curve.blue = v }
        }

        if let p = color {
            if let v = p.vibrance { out.color.vibrance = v }
            if let v = p.saturation { out.color.saturation = v }
            // Bands are indexed into the eight-band array; an out-of-range index cannot exist in a
            // payload this build wrote, and is ignored if a hand-written one carries it.
            for patch in p.bands ?? [] {
                guard out.color.bands.indices.contains(patch.index) else { continue }
                var band = out.color.bands[patch.index]
                if let v = patch.hue { band.hue = v }
                if let v = patch.saturation { band.saturation = v }
                if let v = patch.luminance { band.luminance = v }
                out.color.bands[patch.index] = band
            }
        }

        if let p = detail {
            if let v = p.sharpening { out.detail.sharpening = v }
            if let v = p.sharpeningRadius { out.detail.sharpeningRadius = v }
            if let v = p.noiseLuminance { out.detail.noiseLuminance = v }
            if let v = p.noiseColor { out.detail.noiseColor = v }
            if let v = p.lensCorrections { out.detail.lensCorrections = v }
        }

        if let p = effects {
            if let v = p.vignetteAmount { out.effects.vignetteAmount = v }
            if let v = p.vignetteMidpoint { out.effects.vignetteMidpoint = v }
            if let v = p.vignetteFeather { out.effects.vignetteFeather = v }
            if let v = p.vignetteRoundness { out.effects.vignetteRoundness = v }
            if let v = p.grain { out.effects.grain = v }
        }

        return out
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.schemaVersion = c.val("schemaVersion", EditSnapshot.currentSchemaVersion)
        self.geometry = c.val("geometry", GeometryPatch?.none)
        self.light = c.val("light", LightPatch?.none)
        self.curve = c.val("curve", CurvePatch?.none)
        self.color = c.val("color", ColorPatch?.none)
        self.detail = c.val("detail", DetailPatch?.none)
        self.effects = c.val("effects", EffectsPatch?.none)
    }

    // MARK: tolerant comparison

    /// Same tolerance as `EditHistory.dirtyTolerance`: a value that was through JSON is the same
    /// value, so a re-encoded document is not reported as edited.
    static func differs(_ a: Double, _ b: Double) -> Bool {
        if a == b { return false }
        if a.isNaN && b.isNaN { return false }
        return abs(a - b) > EditHistory.dirtyTolerance
    }

    static func same(_ a: [CurvePoint], _ b: [CurvePoint]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where differs(x.x, y.x) || differs(x.y, y.y) { return false }
        return true
    }
}
