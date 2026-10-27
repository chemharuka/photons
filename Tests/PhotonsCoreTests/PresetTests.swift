import XCTest
import Foundation
@testable import PhotonsCore

/// M5: presets are **named subsets** of a develop document.
///
/// The two failures this file exists to prevent:
///
///  - a preset that resets panels it does not own (apply a Light look → the crop is gone), and
///  - a preset that carries per-photo state (masks), which would make "save preset" a way to leak
///    one photo's local adjustments onto another.
///
/// Filter with `--filter Preset`.
final class PresetTests: XCTestCase {

    // MARK: - fixtures

    /// A document that touches every group, so "only my groups changed" is a real question.
    private func richEdit() -> EditModel {
        var m = EditModel.neutral
        m.geometry.crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.7)
        m.geometry.rotationDegrees = -3.25
        m.geometry.aspectLock = .threeTwo
        m.light = LightGroup(exposure: 0.75, contrast: 12, highlights: -30, shadows: 18,
                             whites: 5, blacks: -8, temperature: 5400, tint: 7,
                             highlightRecovery: 0.25)
        m.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.62), CurvePoint(u: 1, v: 1)]
        m.color.saturation = -12
        m.color.bands[3] = HSLBand(hue: 10, saturation: -20, luminance: 5)
        m.detail.sharpening = 40
        m.effects.vignetteAmount = -18
        return m
    }

    private func lightOnlyEdit() -> EditModel {
        var m = EditModel.neutral
        m.light.exposure = 0.5
        m.light.contrast = 20
        return m
    }

    private func encodeCanonical(_ preset: Preset) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(preset), encoding: .utf8) ?? ""
    }

    private func jsonObject(_ preset: Preset) throws -> [String: Any] {
        let data = Data(try encodeCanonical(preset).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1. round trip

    func testPresetRoundTripsThroughCanonicalJSON() throws {
        let document = richEdit()
        let preset = Preset(name: "Punchy Landscape", from: document,
                            groups: [.light, .curve, .color, .effects])
        let decoded = try JSONDecoder().decode(Preset.self, from: Data(try encodeCanonical(preset).utf8))

        XCTAssertEqual(decoded.name, "Punchy Landscape")
        XCTAssertEqual(decoded.groups, [.light, .curve, .color, .effects])
        XCTAssertEqual(decoded.schemaVersion, Preset.currentSchemaVersion)
        // Only the groups in the subset come back; geometry was not captured and stays neutral.
        XCTAssertEqual(decoded.edit.light, document.light)
        XCTAssertEqual(decoded.edit.curve, document.curve)
        XCTAssertEqual(decoded.edit.color, document.color)
        XCTAssertEqual(decoded.edit.effects, document.effects)
        XCTAssertEqual(decoded.edit.geometry, .identity, "groups outside the subset are not carried")
        XCTAssertEqual(decoded.edit, preset.edit, "byte-for-byte equal after a round trip")
    }

    func testPresetEncodingIsByteStable() throws {
        let preset = Preset(name: "Stable", from: richEdit())
        let a = try encodeCanonical(preset)
        let b = try encodeCanonical(try JSONDecoder().decode(Preset.self, from: Data(a.utf8)))
        XCTAssertEqual(a, b, "re-encoding a decoded preset must produce the same bytes")
        XCTAssertFalse(a.contains("\n"), "canonical form is one line")
    }

    // MARK: - 2. the subset rule (the whole point of the type)

    func testPresetApplyWritesOnlyItsGroups() {
        // Target: a fully edited photo with its own values everywhere.
        var target = richEdit()
        target.geometry.crop = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        target.detail.sharpening = 75
        target.effects.vignetteAmount = 40

        // Preset: Light only, different values from the target's.
        var source = EditModel.neutral
        source.light = LightGroup(exposure: -1.5, contrast: 35, temperature: 7200)
        let preset = Preset(name: "Cold & Dark", from: source, groups: [.light])

        let applied = preset.apply(to: target)

        XCTAssertEqual(applied.light, source.light, "the preset's own group is written")
        // The reported line:
        XCTAssertEqual(applied.color, target.color, "a Light preset must leave every field of the Color group exactly as the target had it")
        XCTAssertEqual(applied.curve, target.curve, "Curve is untouched by a Light preset")
        XCTAssertEqual(applied.detail, target.detail, "Detail is untouched by a Light preset")
        XCTAssertEqual(applied.effects, target.effects, "Effects is untouched by a Light preset")
        XCTAssertEqual(applied.geometry, target.geometry, "Geometry (crop, straighten, aspect) is untouched by a Light preset")
        XCTAssertEqual(EditHistory.dirtyGroups(from: target, to: applied), [.light],
                       "exactly one group changed")
    }

    func testPresetApplyOfSeveralGroupsLeavesTheRestAlone() {
        var target = richEdit()
        target.detail.noiseLuminance = 22
        var source = EditModel.neutral
        source.color = ColorGroup(vibrance: 30, saturation: 10)
        source.effects.vignetteAmount = -45
        let preset = Preset(name: "Warm", from: source, groups: [.color, .effects])

        let applied = preset.apply(to: target)
        XCTAssertEqual(applied.color, source.color)
        XCTAssertEqual(applied.effects, source.effects)
        XCTAssertEqual(applied.detail, target.detail)
        XCTAssertEqual(applied.light, target.light)
        XCTAssertEqual(applied.geometry, target.geometry)
    }

    func testPresetWithIdentityGroupResetsJustThatGroup() {
        // A group in the subset is written even when it is neutral: that is how a preset *removes*
        // a look ("Reset Light") without touching anything else.
        var target = richEdit()
        target.detail.sharpening = 60
        let reset = Preset(name: "Reset Light", from: .neutral, groups: [.light])
        let applied = reset.apply(to: target)

        XCTAssertEqual(applied.light, .identity, "Light goes back to the document default")
        XCTAssertEqual(applied.color, target.color)
        XCTAssertEqual(applied.detail, target.detail)
    }

    func testPresetApplyIsIdempotent() {
        let preset = Preset(name: "Once", from: richEdit(), groups: [.light, .color])
        let target = richEdit()
        let once = preset.apply(to: target)
        let twice = preset.apply(to: once)
        XCTAssertEqual(once, twice, "applying the same preset twice changes nothing the second time")
        XCTAssertEqual(preset.changedGroups(appliedTo: once), [], "no group is dirty on a re-apply")
    }

    // MARK: - 3. masks are never part of a preset

    func testPresetCarriesNoMasksOrOverlay() throws {
        var document = richEdit()
        document.masks = [Mask(id: "m-sky", name: "Sky"), Mask(id: "m-face", name: "Face")]
        document.showMaskID = "m-sky"

        let preset = Preset(name: "No Masks", from: document)
        XCTAssertEqual(preset.edit.masks, [], "a preset never stores masks")
        XCTAssertNil(preset.edit.showMaskID, "a preset never stores the overlay selection")

        let json = try encodeCanonical(preset)
        XCTAssertFalse(json.contains("\"masks\""), "no masks key in the encoded preset: \(json.prefix(120))")
        XCTAssertFalse(json.contains("showMaskID"))
        XCTAssertFalse(json.contains("m-sky"))
    }

    func testPresetApplyKeepsTheTargetsMasksAndOverlay() {
        var target = richEdit()
        target.masks = [Mask(id: "m-target", name: "Target mask")]
        target.showMaskID = "m-target"

        var source = richEdit()
        source.masks = [Mask(id: "m-source", name: "Source mask")]
        let preset = Preset(name: "All", from: source, groups: Set(PresetGroup.allCases))

        let applied = preset.apply(to: target)
        XCTAssertEqual(applied.masks.map(\.id), ["m-target"], "the destination keeps its own masks")
        XCTAssertEqual(applied.showMaskID, "m-target", "and its own overlay selection")
        XCTAssertEqual(EditHistory.dirtyGroups(from: target, to: applied).contains(.masks), false)
    }

    // MARK: - 4. the encoded fragment is the subset

    func testPresetFragmentHoldsOnlySubsetGroups() throws {
        let preset = Preset(name: "Light + Curve", from: richEdit(), groups: [.light, .curve])
        let object = try jsonObject(preset)
        let groups = try XCTUnwrap(object["groups"] as? [String])
        XCTAssertEqual(groups, ["light", "curve"], "declaration order, not hash order")

        let fragment = try XCTUnwrap(object["fragment"] as? [String: Any])
        XCTAssertEqual(Set(fragment.keys), ["light", "curve"],
                       "the fragment has one key per group and nothing else: got \(fragment.keys.sorted())")
        XCTAssertNotNil(fragment["light"] as? [String: Any])
        XCTAssertNotNil(fragment["curve"] as? [String: Any])
    }

    func testPresetJSONOfNeutralDocumentIsJustTheEnvelope() throws {
        let preset = Preset(name: "Empty", from: .neutral, groups: [.light])
        let object = try jsonObject(preset)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "name", "groups", "fragment"])
        XCTAssertEqual(object["schemaVersion"] as? Int, Preset.currentSchemaVersion)
        // A neutral Light group still encodes its nine defaults — the *fragment* is bounded by the
        // group, not by whether a value happens to be non-default (a preset may reset a panel).
        let light = try XCTUnwrap((object["fragment"] as? [String: Any])?["light"] as? [String: Any])
        XCTAssertEqual(light["exposure"] as? Double, 0)
    }

    // MARK: - 5. versioning

    func testPresetRejectsDifferentSchemaVersion() throws {
        let future = """
        {"schemaVersion":2,"name":"From the future","groups":["light"],"fragment":{"light":{"exposure":1}}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(Preset.self, from: Data(future.utf8))) { error in
            guard case PresetError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, Preset.currentSchemaVersion)
        }
    }

    func testPresetForgivesAMissingSchemaVersionAndGroups() throws {
        // Hand-written or M5.0 file: no version, no groups list, fragment only.
        let legacy = #"{"name":"Handwritten","fragment":{"light":{"exposure":0.5}}}"#
        let preset = try JSONDecoder().decode(Preset.self, from: Data(legacy.utf8))
        XCTAssertEqual(preset.schemaVersion, Preset.currentSchemaVersion)
        XCTAssertEqual(preset.groups, Set(PresetGroup.allCases), "absent list = every group")
        XCTAssertEqual(preset.edit.light.exposure, 0.5)
    }

    func testPresetIgnoresFragmentKeysOutsideTheSubset() throws {
        let json = """
        {"schemaVersion":1,"name":"Sneaky","groups":["light"],
         "fragment":{"light":{"exposure":2},"color":{"saturation":99},"masks":[{"id":"m-1"}]}}
        """
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.groups, [.light])
        XCTAssertEqual(preset.edit.light.exposure, 2)
        XCTAssertEqual(preset.edit.color, .identity, "a group outside the subset is not readable")
        XCTAssertEqual(preset.edit.masks, [], "masks in a file are ignored, not loaded")
    }

    // MARK: - 6. group vocabulary

    func testPresetGroupsCoverEveryRenderGroupButMasks() {
        let mapped = Set(PresetGroup.allCases.map(\.renderGroup))
        XCTAssertEqual(mapped, Set(RenderGroup.allCases).subtracting([.masks]),
                       "every document group is presetable except masks")
        XCTAssertEqual(PresetGroup.allCases.count, 6)
    }

    func testPresetGroupParsingAcceptsTokensAndReportsUnknown() {
        let ok = PresetGroup.parse("light,Curve, hsl")
        XCTAssertEqual(ok.groups, [.light, .curve, .color])
        XCTAssertEqual(ok.unknown, [])

        let bad = PresetGroup.parse("light,masks,nonsense")
        XCTAssertEqual(bad.groups, [.light], "masks is not a preset group")
        XCTAssertEqual(bad.unknown, ["masks", "nonsense"])
    }
}
