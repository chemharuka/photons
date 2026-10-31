import XCTest
import Foundation
@testable import PhotonsCore

/// 205 — **a document from a newer build opens instead of being refused**, keeps the keys this build
/// does not know, and stays byte-identical when it has none.
///
/// Four things are pinned here, each on the real codec:
///
///  1. the known-key set is *derived from the encoders*: every key the all-non-default probe writes
///     is in it (so a future field cannot be mistaken for an unknown key and resurrected beside its
///     own value);
///  2. a v14 document lifts to v13, remembers `forwardCompatVersion`, and writes `futureThing` /
///     `effects.futureGrain` back unchanged — with the rest of the document identical to the same
///     file without those two keys;
///  3. a `colorGrading` the user resets to neutral is **gone** on save, even though the file that
///     carried it had unknown keys elsewhere (the six conditional keys are known, not extras);
///  4. a v3…v13 document this build writes re-encodes byte for byte (the old path is unchanged).
///
/// (`effects.grain` in the brief's example is an *existing* known key — adding it would change S3.7
/// and the pixels — so the test's unknown effect key is `futureGrain`; see `local/REPORT.md`.)
final class ForwardCompatTests: XCTestCase {

    // MARK: - helpers

    private func encode(_ model: EditModel) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(model)
    }

    private func tree(_ model: EditModel) throws -> JSONValue {
        try JSONValue(encoding: model)
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let o) = value else {
            XCTFail("expected an object, got \(value)")
            return [:]
        }
        return o
    }

    private func child(_ object: [String: JSONValue], _ key: String) throws -> [String: JSONValue] {
        try self.object(XCTUnwrap(object[key], "missing key \(key)"))
    }

    // MARK: - 1. known-key guard

    func testEveryKeyThisBuildWritesIsKnown() throws {
        let probe = try tree(EditModel.forwardCompatProbe)
        let top = try object(probe)
        XCTAssertTrue(Set(top.keys).isSubset(of: ForwardCompatKnownKeys.topLevel),
                      "top-level keys of the probe are not all known: "
                      + "\(Set(top.keys).subtracting(ForwardCompatKnownKeys.topLevel).sorted())")

        // The six conditional keys must be in the set even though a neutral document omits them.
        XCTAssertTrue(ForwardCompatKnownKeys.topLevel.isSuperset(of: [
            "colorGrading", "sharpen", "calibration", "decoderVersion", "showMaskID", "healSpots",
        ]))

        for key in ["geometry", "light", "color", "colorGrading", "detailSettings",
                    "effects", "sharpen", "optics", "calibration"] {
            let children = try child(top, key)
            let known = ForwardCompatKnownKeys.groups[key] ?? []
            XCTAssertTrue(Set(children.keys).isSubset(of: known),
                          "\(key) has unknown-looking keys \(Set(children.keys).subtracting(known).sorted())")
        }
    }

    // MARK: - 2. a newer document

    private let futureDocument = """
    {
      "schemaVersion": 14,
      "processVersion": 2,
      "geometry": {"crop": {"x": 0, "y": 0, "width": 1, "height": 1},
                   "rotationDegrees": 0, "flipHorizontal": false, "flipVertical": false,
                   "aspectLock": "original"},
      "light": {"exposure": 0.5, "contrast": 0, "highlights": 0, "midtones": 0, "shadows": 0,
                "whites": 0, "blacks": 0, "highlightRecovery": 0},
      "futureThing": {"a": 1},
      "effects": {"vignetteAmount": 0, "vignetteMidpoint": 50, "vignetteFeather": 50,
                  "grain": 0, "grainSize": 25, "grainRoughness": 50, "grainSeed": 0,
                  "futureGrain": 0.5}
    }
    """

    private let sameDocumentWithoutTheFutureKeys = """
    {
      "schemaVersion": 14,
      "processVersion": 2,
      "geometry": {"crop": {"x": 0, "y": 0, "width": 1, "height": 1},
                   "rotationDegrees": 0, "flipHorizontal": false, "flipVertical": false,
                   "aspectLock": "original"},
      "light": {"exposure": 0.5, "contrast": 0, "highlights": 0, "midtones": 0, "shadows": 0,
                "whites": 0, "blacks": 0, "highlightRecovery": 0},
      "effects": {"vignetteAmount": 0, "vignetteMidpoint": 50, "vignetteFeather": 50,
                  "grain": 0, "grainSize": 25, "grainRoughness": 50, "grainSeed": 0}
    }
    """

    func testANewerDocumentIsLiftedAndKeepsItsUnknownKeys() throws {
        let model = try JSONDecoder().decode(EditModel.self, from: Data(futureDocument.utf8))
        XCTAssertEqual(model.forwardCompatVersion, 14, "the file's version is remembered for the notice")
        XCTAssertEqual(model.schemaVersion, EditModel.currentSchemaVersion, "lifted, not refused")
        XCTAssertEqual(model.light.exposure, 0.5, "the known fields still decode")
        XCTAssertEqual(model.effects.grain, 0, "futureGrain is not a known field")

        let future = try object(try tree(model))
        let futureThing = try child(future, "futureThing")
        XCTAssertEqual(futureThing["a"], .number(1))
        let effects = try child(future, "effects")
        XCTAssertEqual(effects["futureGrain"], .number(0.5))

        // The rest of the document is exactly the same file with the two keys removed — the unknown
        // keys ride beside the known encoding, they do not perturb it.
        let withoutKeys = try JSONDecoder().decode(EditModel.self,
                                                   from: Data(sameDocumentWithoutTheFutureKeys.utf8))
        XCTAssertNil(withoutKeys.forwardExtras)
        XCTAssertEqual(withoutKeys.forwardCompatVersion, 14)
        let expected = try object(try tree(withoutKeys))
        var got = future
        got.removeValue(forKey: "futureThing")
        var gotEffects = try child(got, "effects")
        gotEffects.removeValue(forKey: "futureGrain")
        got["effects"] = .object(gotEffects)
        XCTAssertEqual(JSONValue.object(got), JSONValue.object(expected))
    }

    // MARK: - 3. a reset is not resurrected

    func testResettingAConditionalGroupDropsItsKeyEvenWithUnknownKeysPresent() throws {
        let json = """
        {
          "schemaVersion": 14,
          "colorGrading": {"shadows": {"hue": 10, "saturation": 20, "lightness": 5},
                           "midtones": {"hue": 0, "saturation": 0, "lightness": 0},
                           "highlights": {"hue": 0, "saturation": 0, "lightness": 0}},
          "sharpen": {"amount": 40, "radius": 1, "detail": 25, "masking": 0},
          "calibration": {"shadowTint": 10, "redHue": 0, "redSat": 0,
                          "greenHue": 0, "greenSat": 0, "blueHue": 0, "blueSat": 0},
          "futureThing": {"a": 1}
        }
        """
        var model = try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))
        XCTAssertFalse(model.colorGrading.isIdentity, "the file's grade decoded")
        XCTAssertFalse(model.sharpen.isIdentity)
        XCTAssertFalse(model.calibration.isIdentity)
        XCTAssertEqual(model.forwardExtras?["futureThing"], .object(["a": .number(1)]))

        model.colorGrading = .identity
        model.sharpen = .identity
        model.calibration = .identity

        let out = try object(try tree(model))
        XCTAssertNil(out["colorGrading"], "a reset grade must vanish, not be revived from extras")
        XCTAssertNil(out["sharpen"], "a reset sharpen must vanish")
        XCTAssertNil(out["calibration"], "reset calibration must vanish")
        XCTAssertNotNil(out["futureThing"], "and the genuinely unknown key is still kept")
    }

    // MARK: - 4. old documents are untouched

    func testDocumentsThisBuildWritesReencodeByteForByteFromV3ToV13() throws {
        for version in 3...EditModel.currentSchemaVersion {
            var model = EditModel.neutral
            model.schemaVersion = version
            model.light.exposure = 0.5
            let first = try encode(model)
            let decoded = try JSONDecoder().decode(EditModel.self, from: first)
            XCTAssertNil(decoded.forwardCompatVersion, "v\(version) is not a newer document")
            XCTAssertNil(decoded.forwardExtras, "no unknown keys ⇒ no extras")
            XCTAssertEqual(try encode(decoded), first, "v\(version) must re-encode byte for byte")
        }
    }

    // MARK: - 5. presets

    func testANewerPresetEnvelopeKeepsUnknownGroupsAndTopLevelKeys() throws {
        let json = """
        {"schemaVersion":2,"name":"From the future","groups":["light","futureGroup"],
         "fragment":{"light":{"exposure":1.5},"futureGroup":{"x":1}},
         "futureTop":{"b":true}}
        """
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.schemaVersion, 2, "the preset keeps the envelope number the file wrote")
        XCTAssertEqual(preset.forwardCompatVersion, 2)
        XCTAssertEqual(preset.groups, [.light], "the known group still applies")
        XCTAssertEqual(preset.edit.light.exposure, 1.5)

        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(preset)
        let root = try object(try JSONDecoder().decode(JSONValue.self, from: data))

        guard case .array(let tokens)? = root["groups"] else { return XCTFail("groups missing") }
        XCTAssertEqual(tokens.compactMap { if case .string(let s) = $0 { return s } else { return nil } },
                       ["light", "futureGroup"],
                       "the unknown group name is still in the list")
        let fragment = try child(root, "fragment")
        XCTAssertNotNil(fragment["futureGroup"], "unknown group key kept")
        XCTAssertEqual(try child(fragment, "light")["exposure"], .number(1.5))
        XCTAssertEqual(try child(root, "futureTop")["b"], .bool(true),
                       "unknown envelope key kept")
    }
}
