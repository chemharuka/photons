import Foundation

// MARK: - 205 · forward compatibility
//
// A document written by a **newer** build must open here: this build understands the fields it
// knows (missing ones read as their explicit defaults), lifts `schemaVersion` to its own, and keeps
// every key it does not know **verbatim** so saving does not throw the future away.
//
// `JSONValue` itself already lives in `Masks.swift` (005d's canonical key material). This file adds
// the two pieces the document codec needs on top of it:
//
//   · `JSONValue(encoding:)` — a known group encoded through the module's encoder, so a future child
//     key can be merged beside it;
//   · `ForwardCompatKnownKeys` — the known-key set **derived from the encoders**, never copied into
//     a table. It encodes two documents (the neutral one and `EditModel.forwardCompatProbe`, whose
//     every conditional branch writes its key) and reads the key sets back. A field added to a group
//     in a future commit and forgotten here is caught by
//     `ForwardCompatTests.testEveryKeyThisBuildWritesIsKnown` (the probe document's key set must be
//     a subset of the known set), not silently treated as "unknown" and re-emitted beside the real
//     value.

extension JSONValue {
    public typealias Object = [String: JSONValue]

    /// Encode a value with this module's JSON encoder, then read it back as a tree.
    ///
    /// Used only on **known** values (a group that has to be merged with a future key), so the
    /// numbers keep the encoder's own representation.
    init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The object's keys, or `[]` for any other kind.
    var objectKeys: Set<String> {
        guard case .object(let o) = self else { return [] }
        return Set(o.keys)
    }
}

// MARK: - the probe document

extension EditModel {
    /// A document whose **conditional** encoder branches all fire: quarter turn, perspective,
    /// temperature/tint/blackOffset, 黑白 + global + point colour, colour grading, every conditional
    /// effect key, sharpen, calibration, decoder version, mask overlay and heal spots.
    ///
    /// Not a fixture and not user-facing: `ForwardCompatKnownKeys` encodes it once to learn the key
    /// set this build can write. The guard test pins that its keys are a subset of the known set, so
    /// a field added without (implicitly) updating the derivation turns a test red instead of being
    /// mistaken for a future key and re-emitted beside its own value.
    static let forwardCompatProbe: EditModel = {
        var m = EditModel.neutral
        m.geometry.quarterTurns = 1
        m.geometry.perspectiveVertical = 3
        m.geometry.perspectiveHorizontal = -3
        m.light.temperature = 5600
        m.light.tint = 7
        m.light.blackOffset = 0.001
        m.color.blackAndWhite = true
        m.color.bands[0].mix = 12
        m.color.global = HSLBand(hue: 1, saturation: 2, luminance: 3)
        m.color.point = PointColorSet(
            swatches: [PointColor(sampleHue: 30, sampleChroma: 0.1,
                                  hue: 1, saturation: 2, luminance: 3)],
            active: 0)
        m.colorGrading = ColorGradingGroup(
            shadows: GradeWheel(hue: 1, saturation: 2, lightness: 3),
            midtones: GradeWheel(hue: 4, saturation: 5, lightness: 6),
            highlights: GradeWheel(hue: 7, saturation: 8, lightness: 9))
        m.detailSettings = DetailSettings(luminanceNR: 10, colorNR: 20,
                                          sharpness: 30, detail: 5, moire: 10)
        m.decoderVersion = "8.dng"
        m.effects.texture = 10
        m.effects.clarity = 10
        m.effects.dehaze = 10
        m.effects.nonBayerLuminanceNR = 10
        m.effects.nonBayerColorNR = 10
        m.sharpen = SharpenGroup(amount: 10)
        m.calibration = CalibrationGroup(shadowTint: 1, redHue: 2, redSat: 3,
                                         greenHue: 4, greenSat: 5, blueHue: 6, blueSat: 7)
        m.showMaskID = "probe-mask"
        m.healSpots = [HealSpot(id: "probe-spot")]
        return m
    }()
}

// MARK: - the known-key set

/// The keys this build writes, derived from the encoders (see the file header).
enum ForwardCompatKnownKeys {
    private static let trees: [JSONValue] = {
        [EditModel.neutral, EditModel.forwardCompatProbe].compactMap { try? JSONValue(encoding: $0) }
    }()

    /// Everything the document encoder can put at the top level, the six conditional keys included
    /// (`colorGrading`, `sharpen`, `calibration`, `decoderVersion`, `showMaskID`, `healSpots` — the
    /// probe document is what makes them appear).
    static let topLevel: Set<String> = {
        var keys: Set<String> = []
        for tree in trees { keys.formUnion(tree.objectKeys) }
        return keys
    }()

    /// One set per group-shaped top-level key (`geometry`, `light`, … `calibration`).
    ///
    /// The six conditional keys matter here too: `colorGrading`/`sharpen`/`calibration` are absent
    /// from a neutral document, so without the probe their *interior* keys (`shadows`, `amount`, …)
    /// would look unknown and a reset of the card would resurrect them.
    static let groups: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for tree in trees {
            guard case .object(let root) = tree else { continue }
            for (key, value) in root where topLevel.contains(key) {
                guard case .object = value else { continue }
                out[key, default: []].formUnion(value.objectKeys)
            }
        }
        return out
    }()
}
