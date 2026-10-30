import XCTest
import Foundation
@testable import PhotonsCore

/// M5: copy/paste carries **settings**, not documents.
///
/// `EditSnapshot` is the clipboard payload: one optional per leaf parameter, present only when it
/// differs from the neutral default. These tests pin the three consequences that make it useful —
/// a one-slider copy is one field, a paste leaves everything it did not carry alone, and masks are
/// structurally absent (so a paste can never move a local adjustment onto another photo).
///
/// Filter with `--filter Preset`.
final class PresetSnapshotTests: XCTestCase {

    // MARK: - fixtures

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

    private func encodeCanonical(_ snapshot: EditSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(snapshot), encoding: .utf8) ?? ""
    }

    // MARK: - 1. sparsity

    func testSnapshotOfNeutralDocumentIsEmpty() {
        let snapshot = EditSnapshot.capture(.neutral)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.fieldCount, 0)
        XCTAssertEqual(snapshot.groups, [], "a neutral document has nothing to copy")
        XCTAssertNil(snapshot.light)
        XCTAssertNil(snapshot.geometry)
    }

    func testSnapshotCarriesOnlyNonDefaultFields() {
        var document = EditModel.neutral
        document.light.exposure = 0.75
        document.light.contrast = 12
        document.color.saturation = -12

        let snapshot = EditSnapshot.capture(document)
        XCTAssertEqual(snapshot.fieldCount, 3, "three changed leaves, three stored fields")
        XCTAssertEqual(snapshot.light?.fieldCount, 2)
        XCTAssertEqual(snapshot.light?.exposure, 0.75)
        XCTAssertEqual(snapshot.light?.contrast, 12)
        XCTAssertNil(snapshot.light?.temperature, "an untouched default is not carried")
        XCTAssertNil(snapshot.light?.highlights)
        XCTAssertEqual(snapshot.color?.saturation, -12)
        XCTAssertNil(snapshot.curve, "an identity curve is not carried at all")
        XCTAssertNil(snapshot.detail)
        XCTAssertNil(snapshot.effects)
        XCTAssertNil(snapshot.geometry, "a full-frame crop is not carried at all")
    }

    func testSnapshotIsSparseComparedWithTheFullDocument() {
        let document = richEdit()
        let snapshot = EditSnapshot.capture(document)
        // crop 4 edges + straighten 1 + aspect lock 1 + light 9 + rgb curve 1 + saturation 1
        // + one HSL band (3) + sharpening 1 + vignette 1 = 22 of the document's 84 leaves.
        print("sparse snapshot: \(snapshot.fieldCount) fields of \(EditSnapshot.fullDocumentFieldCount)"
              + "  groups \(snapshot.groups.map(\.rawValue).sorted())")
        // 081: light gained 黑电平 (`blackOffset`) and 色彩分级 joined as nine leaves;
        // 090 adds 中间调 to the tone leaves; 134 removes 圆度; 156 adds 校正 (色差 R/B) → 82;
        // 164 adds the two denoises to the effects patch → 84.
        XCTAssertEqual(EditSnapshot.fullDocumentFieldCount, 84,
                       "9 geometry (4 crop edges + angle + 2 flips + lock + quarterTurns)"
                       + " + 11 light (7 tone + 2 balance + 高光恢复 + 黑电平) + 4 curve"
                       + " + 35 color (2 + switch + 8 bands × 4) + 9 色彩分级"
                       + " + 5 detail + 2 校正 (色差 R/B)"
                       + " + 9 effects (暗角 3 + 颗粒 1 + 纹理/清晰度/去雾 3 + 去噪/去彩噪 2)")
        XCTAssertEqual(snapshot.fieldCount, 22,
                       "crop 4 + straighten 1 + aspect 1 + light 9 + rgb curve 1 + saturation 1"
                       + " + one band 3 + sharpening 1 + vignette 1")
        XCTAssertLessThan(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount / 2)
    }

    func testSnapshotStoresOnlyTheChangedHSLBand() {
        var document = EditModel.neutral
        document.color.bands[6] = HSLBand(hue: 5, saturation: 0, luminance: -30)
        let snapshot = EditSnapshot.capture(document)

        let bands = snapshot.color?.bands ?? []
        XCTAssertEqual(bands.count, 1, "seven identity bands are not stored")
        XCTAssertEqual(bands[0].index, 6)
        XCTAssertEqual(bands[0].hue, 5)
        XCTAssertNil(bands[0].saturation, "a zero inside a changed band is still not carried")
        XCTAssertEqual(bands[0].luminance, -30)
        XCTAssertEqual(snapshot.fieldCount, 2)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = EditSnapshot.capture(richEdit())
        let json = try encodeCanonical(snapshot)
        let decoded = try JSONDecoder().decode(EditSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.fieldCount, snapshot.fieldCount)
        XCTAssertEqual(decoded.schemaVersion, EditSnapshot.currentSchemaVersion)
        XCTAssertFalse(json.contains("\"masks\""),
                       "this document has no masks, so the payload has no masks key")
        XCTAssertFalse(json.contains("showMaskID"))
        XCTAssertEqual(try encodeCanonical(decoded), json, "canonical form is stable")
    }

    func testEmptyPayloadRoundTrips() throws {
        let json = try encodeCanonical(EditSnapshot())
        let decoded = try JSONDecoder().decode(EditSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(try encodeCanonical(decoded), json)
    }

    // MARK: - 2. paste == full copy

    func testPasteEqualsAFullDocumentCopy() {
        let source = richEdit()
        let snapshot = EditSnapshot.capture(source)
        let pasted = snapshot.applied(to: .neutral)

        XCTAssertEqual(pasted, source,
                       "pasting every non-default field onto a neutral document reproduces the source")
        XCTAssertEqual(pasted.light, source.light)
        XCTAssertEqual(pasted.geometry, source.geometry)
        XCTAssertEqual(pasted.color.bands[3], source.color.bands[3])
    }

    func testPasteOntoAnEditedDocumentKeepsWhatItDoesNotCarry() {
        var target = richEdit()
        target.geometry.crop = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        target.detail.sharpening = 90
        target.effects.vignetteAmount = 55

        var source = EditModel.neutral
        source.light.exposure = -2
        let pasted = EditSnapshot.capture(source).applied(to: target)

        XCTAssertEqual(pasted.light.exposure, -2, "the payload wins where it has a field")
        XCTAssertEqual(pasted.light.temperature, 5400,
                       "a default in the source is not carried, so the target's value survives")
        XCTAssertEqual(pasted.geometry, target.geometry, "geometry was not copied")
        XCTAssertEqual(pasted.detail.sharpening, 90, "detail was not copied")
        XCTAssertEqual(pasted.effects.vignetteAmount, 55, "effects were not copied")
        XCTAssertEqual(pasted.color, target.color)
    }

    /// P1-5 replaced this test's original claim ("paste never writes masks"). The list is carried now
    /// — **appended**, with fresh ids — and what the old name pinned survives as the property that
    /// matters: the destination's own mask is still there, and the overlay is still never pasted.
    func testPasteAppendsMasksAndNeverCarriesTheOverlay() {
        var target = richEdit()
        target.masks = [Mask(id: "m-target", name: "Target")]
        target.showMaskID = "m-target"

        var source = richEdit()
        source.masks = [Mask(id: "m-source", name: "Source"), Mask(id: "m-sky", name: "Sky")]
        source.showMaskID = "m-sky"

        let snapshot = EditSnapshot.capture(source)
        XCTAssertEqual(snapshot.maskCount, 2)
        let pasted = snapshot.applied(to: target)

        print("PASTE  masks: \(target.masks.map(\.id)) + \(source.masks.map(\.id))"
              + " → \(pasted.masks.map(\.id))")
        XCTAssertEqual(pasted.masks.count, 3, "3 = the destination's own + the source's two")
        XCTAssertEqual(Set(pasted.masks.map(\.id)).count, 3, "ids stay unique across the merge")
        XCTAssertEqual(pasted.masks.first?.id, "m-target", "the destination's own mask is untouched")
        XCTAssertEqual(pasted.masks.map(\.name), ["Target", "Source", "Sky"],
                       "names travel (free text, not identity)")
        XCTAssertEqual(pasted.showMaskID, "m-target", "the overlay is view state: never pasted")
        XCTAssertEqual(pasted.light, source.light)
        XCTAssertNotEqual(pasted, source, "the two documents still differ — by the destination's mask")
    }

    func testPasteDoesNotTouchVersions() {
        var target = EditModel.neutral
        target.processVersion = 1
        target.light.exposure = 1
        let pasted = EditSnapshot.capture(richEdit()).applied(to: target)
        XCTAssertEqual(pasted.schemaVersion, target.schemaVersion)
        XCTAssertEqual(pasted.processVersion, target.processVersion)
    }

    func testEmptyPasteIsANoOp() {
        let target = richEdit()
        let pasted = EditSnapshot().applied(to: target)
        XCTAssertEqual(pasted, target)
        XCTAssertEqual(EditHistory.dirtyGroups(from: target, to: pasted), [])
        XCTAssertEqual(EditSnapshot.capture(target).unchangedGroups(in: target),
                       EditSnapshot.capture(target).groups,
                       "copying and pasting the same photo changes nothing")
    }

    func testToleranceIgnoresReencodedNoise() {
        // A value that has been through JSON is the same value: a difference below
        // `EditHistory.dirtyTolerance` must not become a "copied field".
        var document = EditModel.neutral
        document.light.exposure = 5e-7          // just under 1e-6
        document.light.contrast = -5e-7
        XCTAssertTrue(EditSnapshot.capture(document).isEmpty,
                      "sub-tolerance differences are not edits")

        document.light.exposure = 2e-6          // just over
        XCTAssertEqual(EditSnapshot.capture(document).fieldCount, 1,
                       "a difference above the tolerance is a real field")

        // 派单 006: white balance is a *state* (`nil` = follow the file) plus an absolute value, so
        // there is no neutral number to be within tolerance of — any pinned value travels.
        document.light.temperature = 6500
        XCTAssertNotNil(EditSnapshot.capture(document).light?.temperature,
                        "a pinned 6500 K must survive \"copy settings\"")
        document.light.temperature = nil
        XCTAssertNil(EditSnapshot.capture(document).light?.temperature,
                     "as shot has nothing to copy")
    }
}
