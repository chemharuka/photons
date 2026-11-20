import XCTest
import Foundation
@testable import PhotonsCore

/// M5: copy/paste carries **settings**, not documents.
///
/// 442 changed the contract: `EditSnapshot.capture` carries **every copyable leaf**, defaults
/// included, so pasting a default clears the destination's value. These tests pin that plus the two
/// properties that remain — a narrowed payload leaves everything it does not carry alone, and masks
/// are appended rather than substituted.
///
/// Filter with `--filter Preset`.
final class PresetSnapshotTests: XCTestCase {

    // MARK: - fixtures

    private func richEdit() -> EditModel {
        var m = EditModel.neutral
        m.geometry.crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.7)
        m.geometry.rotationDegrees = -3.25
        m.geometry.aspectLock = .threeTwo
        // 442: 高光恢复 is not a copyable leaf (325 removed its child row), so the fixture leaves it
        // at 0 — a full capture is expected to reproduce every *copyable* leaf.
        m.light = LightGroup(exposure: 0.75, contrast: 12, highlights: -30, shadows: 18,
                             whites: 5, blacks: -8, temperature: 5400, tint: 7)
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

    // MARK: - 1. every leaf, defaults included (442)

    func testSnapshotOfNeutralDocumentCarriesEveryLeaf() {
        let snapshot = EditSnapshot.capture(.neutral)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount)
        XCTAssertEqual(snapshot.groups,
                       [.geometry, .light, .curve, .color, .colorGrading, .detail, .effects],
                       "a neutral document is a complete payload now: every card is carried")
        XCTAssertEqual(snapshot.light?.exposure, 0)
        XCTAssertEqual(snapshot.geometry?.cropWidth, 1)
        XCTAssertEqual(snapshot.light?.temperatureAuto, true, "as shot is an explicit copied state")
        XCTAssertEqual(snapshot.decoderVersionAuto, true, "自动 is an explicit copied state")
    }

    func testSnapshotCarriesDefaultsBesideChangedFields() {
        var document = EditModel.neutral
        document.light.exposure = 0.75
        document.light.contrast = 12
        document.color.saturation = -12

        let snapshot = EditSnapshot.capture(document)
        XCTAssertEqual(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount,
                       "the payload is no longer sparse: every copyable leaf is there")
        XCTAssertEqual(snapshot.light?.fieldCount, LightPatch.fullFieldCount)
        XCTAssertEqual(snapshot.light?.exposure, 0.75)
        XCTAssertEqual(snapshot.light?.contrast, 12)
        XCTAssertEqual(snapshot.light?.highlights, 0, "a default is carried as a value")
        XCTAssertEqual(snapshot.color?.saturation, -12)
        XCTAssertNotNil(snapshot.curve, "an identity curve is carried")
        XCTAssertNotNil(snapshot.detail)
        XCTAssertNotNil(snapshot.effects)
        XCTAssertNotNil(snapshot.geometry, "a full-frame crop is carried")
    }

    func testSnapshotCarriesTheFullDocument() {
        let document = richEdit()
        let snapshot = EditSnapshot.capture(document)
        print("full snapshot: \(snapshot.fieldCount) fields of \(EditSnapshot.fullDocumentFieldCount)"
              + "  groups \(snapshot.groups.map(\.rawValue).sorted())")
        // 442: geometry now includes the four perspective leaves and cropSpace; color includes the
        // ninth selector's three numbers.
        XCTAssertEqual(EditSnapshot.fullDocumentFieldCount, 102,
                       "14 geometry (4 crop edges + angle + 2 flips + lock + quarterTurns"
                       + " + 4 perspective + cropSpace)"
                       + " + 10 light (7 tone + 2 balance + 黑电平; 高光恢复 is wire-only) + 4 curve"
                       + " + 38 color (2 + switch + 8 bands × 4 + global 3) + 9 色彩分级"
                       + " + 5 detail + 2 校正 (色差 R/B) + 7 校准"
                       + " + 13 effects (暗角 3 + 颗粒 + 纹理/清晰度/去雾 3 + 去噪/去彩噪 2"
                       + " + 锐化 4)")
        XCTAssertEqual(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount)
    }

    func testSnapshotCarriesAllEightBandsAndEveryLeafInsideThem() {
        var document = EditModel.neutral
        document.color.bands[6] = HSLBand(hue: 5, saturation: 0, luminance: -30)
        let snapshot = EditSnapshot.capture(document)

        let bands = snapshot.color?.bands ?? []
        XCTAssertEqual(bands.count, 8, "all eight bands travel, identity included")
        XCTAssertEqual(bands[6].index, 6)
        XCTAssertEqual(bands[6].hue, 5)
        XCTAssertEqual(bands[6].saturation, 0, "a zero inside a band is carried too")
        XCTAssertEqual(bands[6].luminance, -30)
        XCTAssertEqual(bands.filter { $0.index != 6 }.count, 7)
        XCTAssertEqual(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount)
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

    func testNarrowedPasteKeepsWhatItDoesNotCarry() {
        var target = richEdit()
        target.geometry.crop = NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        target.detail.sharpening = 90
        target.effects.vignetteAmount = 55

        var source = EditModel.neutral
        source.light.exposure = -2
        let pasted = EditSnapshot.capture(source).filtered(to: [.light]).applied(to: target)

        XCTAssertEqual(pasted.light.exposure, -2, "the payload wins where it has a field")
        XCTAssertEqual(pasted.light.temperature, 5400,
                       "白平衡 was not in the checklist, so the destination's pin survives")
        XCTAssertEqual(pasted.geometry, target.geometry, "geometry was not in the checklist")
        XCTAssertEqual(pasted.detail.sharpening, 90, "detail was not in the checklist")
        XCTAssertEqual(pasted.effects.vignetteAmount, 55, "effects were not in the checklist")
        XCTAssertEqual(pasted.color, target.color)
    }

    func testFullPasteOfANeutralSourceResetsTheDestinationToDefaults() {
        var target = richEdit()
        target.light.exposure = 1.5
        target.light.temperature = 4800
        target.light.tint = 12
        target.decoderVersion = "9.dng"

        let pasted = EditSnapshot.capture(.neutral).applied(to: target)
        XCTAssertEqual(pasted.light.exposure, 0)
        XCTAssertNil(pasted.light.temperature, "源是 as shot，粘贴把目标的白平衡也写回自动")
        XCTAssertNil(pasted.light.tint)
        XCTAssertNil(pasted.decoderVersion, "源是自动，粘贴把目标的解码器写回自动")
        XCTAssertEqual(pasted.geometry.crop, .full)
        XCTAssertEqual(pasted.effects.vignetteAmount, 0)
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

    func testToleranceIgnoresReencodedNoiseInTheExplicitReading() {
        // A value that has been through JSON is the same value: a difference below
        // `EditHistory.dirtyTolerance` must not become an explicit leaf. (Capture is complete
        // since 442; `captureExplicit` is the old reading, still used to apply preset fragments.)
        var document = EditModel.neutral
        document.light.exposure = 5e-7          // just under 1e-6
        document.light.contrast = -5e-7
        XCTAssertTrue(EditSnapshot.captureExplicit(document).isEmpty,
                      "sub-tolerance differences are not edits")

        document.light.exposure = 2e-6          // just over
        XCTAssertEqual(EditSnapshot.captureExplicit(document).fieldCount, 1,
                       "a difference above the tolerance is a real field")

        // 派单 006: white balance is a *state* (`nil` = follow the file) plus an absolute value, so
        // there is no neutral number to be within tolerance of — any pinned value travels.
        document.light.temperature = 6500
        XCTAssertNotNil(EditSnapshot.captureExplicit(document).light?.temperature,
                        "a pinned 6500 K must survive \"copy settings\"")
        document.light.temperature = nil
        XCTAssertNil(EditSnapshot.captureExplicit(document).light?.temperature,
                     "as shot has nothing explicit to copy")
    }
}
