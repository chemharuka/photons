import XCTest
@testable import PhotonsCore

/// P1-5 — 蒙版跨照片复制, measured in numbers.
///
/// The ticket's four questions, each one an assertion rather than a description:
///
///   ① **A (two masks) → B (one of its own)**: three masks afterwards, **ids all distinct**, and A's
///      geometry still in the same place *relative to the picture* (two circles' centres and radii,
///      in normalised coordinates, before and after).
///   ② **4:3 → 3:2**: the short-edge anchoring rule, with the coordinate it produces and the proof
///      that nothing leaves the frame (`0.0556…0.9444` on the long axis, `0…1` on the short one).
///   ③ **masks only**: every other field of the destination is byte-for-byte unchanged.
///   ④ **反证**: the same paste with the ids *not* regenerated produces two masks with one id — the
///      uniqueness assertion above is what fails, so it is a real gate and not decoration.
///
/// The expected coordinates are computed here from the definition (offset from the frame centre in
/// short-edge units, re-normalised), **not** by calling `MaskFrameTransfer` — a test that asks the
/// implementation what the answer should be proves only that it is self-consistent.
final class MaskCopyTransferTests: XCTestCase {

    // MARK: - fixtures

    /// A 4:3 frame and a 3:2 frame, in real pixels, so every number below is traceable.
    private let fourThree = (w: 4032.0, h: 3024.0)     // aspect 1.3333…, min side 3024
    private let threeTwo = (w: 6000.0, h: 4000.0)      // aspect 1.5,      min side 4000
    private var aspectA: Double { fourThree.w / fourThree.h }
    private var aspectB: Double { threeTwo.w / threeTwo.h }

    private func radial(id: String, center: NormalizedPoint, radius: Double,
                        feather: Double = 0.25) -> Mask {
        var m = Mask(id: id, name: id, feather: feather, refine: 0.3, components: [
            MaskComponent(id: "c-\(id)", op: .add, invert: false, feather: 0.4,
                          shape: .radialGradient(RadialGradientShape(center: center,
                                                                     radius: NormalizedPoint(radius, radius),
                                                                     angle: 15))),
        ])
        m.opacity = 0.8
        m.adjustments = LocalAdjustments(amount: 90, exposure: 0.75, temperature: 20, tint: -10,
                                         contrast: 5, hue: 12, saturation: 30)
        return m
    }

    private func linearMask(id: String) -> Mask {
        Mask(id: id, name: id, components: [
            MaskComponent(id: "c-\(id)", shape: .linearGradient(
                LinearGradientShape(start: NormalizedPoint(0.2, 0.1),
                                    end: NormalizedPoint(0.8, 0.9),
                                    midpoint: 0.4))),
        ])
    }

    private func brushMask(id: String) -> Mask {
        Mask(id: id, name: id, components: [
            MaskComponent(id: "c-\(id)", shape: .brush(BrushShape(size: 0.1, strokes: [
                Stroke(points: [0.9, 0.5, 0.6, 0.75], radius: 0.05, feather: 0.3, flow: 0.7),
            ]))),
        ])
    }

    /// The source photo: two masks (a radial and a linear gradient) plus one tone leaf, so a
    /// masks-only paste has something it must *not* carry.
    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.light.exposure = 1.2
        a.color.saturation = 25
        a.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.1), CurvePoint(2, 2)]
        a.masks = [radial(id: "m-a1", center: NormalizedPoint(0.25, 0.75), radius: 0.2),
                   linearMask(id: "m-a2")]
        return a
    }

    /// The destination: its own mask, its own exposure / colour / curve.
    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.temperature = 4800
        b.light.exposure = -0.4
        b.color.saturation = 30
        b.curve.white = [CurvePoint(0, 0), CurvePoint(1, 0.9), CurvePoint(2, 2)]
        b.masks = [radial(id: "B-mask", center: NormalizedPoint(0.5, 0.5), radius: 0.3, feather: 0.6)]
        return b
    }

    private func radialOf(_ mask: Mask) -> RadialGradientShape? {
        guard case .radialGradient(let g)? = mask.components.first?.shape else { return nil }
        return g
    }

    // MARK: - ① A(2 masks) → B(1 mask): three, all distinct, geometry carried

    func testTwoMasksPasteOntoOneAndAllThreeIDsAreDistinct() {
        let a = documentA(), b = documentB()
        let payload = EditSnapshot.capture(a, frameAspect: aspectA).filtered(to: [.masks])
        XCTAssertEqual(payload.maskCount, 2, "A's two masks are in the payload")
        XCTAssertEqual(payload.fieldCount, 0, "a masks-only payload carries no scalar leaf")
        XCTAssertEqual(payload.sections, [.masks])

        let merged = payload.applied(to: b, destinationAspect: aspectB)
        let ids = merged.masks.map(\.id)
        print("MASKS  B before: \(b.masks.map(\.id)) → after: \(ids)")
        XCTAssertEqual(merged.masks.count, 3, "1 of B's own + 2 carried = 3")
        XCTAssertEqual(Set(ids).count, 3, "all three ids distinct; got \(ids)")
        XCTAssertEqual(ids.first, "B-mask", "B's own mask keeps its place in the combination order")
        XCTAssertFalse(ids.contains("m-a1"), "a carried mask does not keep the source's id")
        XCTAssertFalse(ids.contains("m-a2"))
        XCTAssertFalse(ids.contains("c-m-a1"), "nor its component ids")
        // Component ids are minted too, and are distinct within the document.
        let componentIDs = merged.masks.flatMap { $0.components.map(\.id) }
        XCTAssertEqual(Set(componentIDs).count, componentIDs.count)

        // Geometry: the radial's centre, in normalised coordinates, before and after.
        guard let sourceRadial = radialOf(a.masks[0]), let carried = radialOf(merged.masks[1]) else {
            return XCTFail("the carried mask is still a radial gradient")
        }
        let expected = (x: 0.5 + (0.25 - 0.5) * (fourThree.w / fourThree.h) / (threeTwo.w / threeTwo.h),
                        y: 0.75)
        print("GEOM   radial centre \(sourceRadial.center.keyString) → \(carried.center.keyString)"
              + " (expected \(expected.x), \(expected.y));"
              + " radius \(sourceRadial.radius.keyString) → \(carried.radius.keyString)")
        XCTAssertEqual(carried.center.x, expected.x, accuracy: 1e-12)
        XCTAssertEqual(carried.center.y, expected.y, accuracy: 1e-12)
        XCTAssertEqual(carried.center.x, 0.2777777777777778, accuracy: 1e-12, "0.5 − 0.25·8/9")
        // Radius is short-edge normalised, so it crosses unchanged — the mask keeps its size.
        XCTAssertEqual(carried.radius.x, 0.2, "radius unchanged: short-edge units are portable")
        XCTAssertEqual(carried.radius.y, 0.2)
        XCTAssertEqual(carried.angle, 15, "angle unchanged: the transform is a similarity")

        // Shape = the source's everywhere else: feather, invert, op, opacity, refine, name, adjustments.
        XCTAssertEqual(merged.masks[1].components.first?.feather, 0.4,
                       "the component's own feather is a distance: unchanged")
        XCTAssertEqual(merged.masks[1].feather, 0.25)
        XCTAssertEqual(merged.masks[1].opacity, 0.8)
        XCTAssertEqual(merged.masks[1].refine, 0.3)
        XCTAssertEqual(merged.masks[1].components.first?.op, .add)
        XCTAssertEqual(merged.masks[1].adjustments, a.masks[0].adjustments,
                       "eleven local sliders travel with the mask that carries them")
        XCTAssertEqual(merged.masks[1].name, "m-a1", "the name is free text, not an id")

        // The linear gradient's two endpoints, x-contracted by 8/9 and y untouched.
        guard case .linearGradient(let carriedLinear)? = merged.masks[2].components.first?.shape else {
            return XCTFail("the second carried mask is still a linear gradient")
        }
        print("GEOM   linear start/end → \(carriedLinear.start.keyString) "
              + "\(carriedLinear.end.keyString)")
        XCTAssertEqual(carriedLinear.start.x, 0.5 + (0.2 - 0.5) * (8.0 / 9.0), accuracy: 1e-12)
        XCTAssertEqual(carriedLinear.start.y, 0.1)
        XCTAssertEqual(carriedLinear.end.x, 0.5 + (0.8 - 0.5) * (8.0 / 9.0), accuracy: 1e-12)
        XCTAssertEqual(carriedLinear.end.y, 0.9)
        XCTAssertEqual(carriedLinear.midpoint, 0.4)
    }

    // MARK: - ② 4:3 → 3:2: the short-edge rule, and nothing leaves the frame

    func testDifferentAspectAnchorsOnTheShortEdgeAndKeepsEverythingInside() {
        let a = documentA()
        let payload = EditSnapshot.capture(a, frameAspect: aspectA).filtered(to: [.masks])
        let merged = payload.applied(to: .neutral, destinationAspect: aspectB)

        // The rule, stated once: offsets from the frame centre are measured in short-edge units and
        // re-normalised against the target's own short edge.
        let kx = (fourThree.w / fourThree.h) / (threeTwo.w / threeTwo.h)   // 8/9
        let ky = (fourThree.h / fourThree.h) / (threeTwo.h / threeTwo.h)   // 1
        XCTAssertEqual(kx, 8.0 / 9.0, accuracy: 1e-15)

        // Every point of the source frame maps into the destination frame: on the short axis because
        // ky = 1, on the long axis because the contraction pulls [0,1] into [1/18, 17/18].
        let corners = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                       NormalizedPoint(1, 1), NormalizedPoint(0, 1)]
        var lo = (x: Double.infinity, y: Double.infinity)
        var hi = (x: -Double.infinity, y: -Double.infinity)
        for corner in corners {
            let p = MaskFrameTransfer.point(corner, from: aspectA, to: aspectB)
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        print("FRAME  corners → x [\(lo.x), \(hi.x)] y [\(lo.y), \(hi.y)] (kx=\(kx), ky=\(ky))")
        XCTAssertEqual(lo.x, 0.5 - 0.5 * kx, accuracy: 1e-12)
        XCTAssertEqual(hi.x, 0.5 + 0.5 * kx, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(lo.x, 0)
        XCTAssertLessThanOrEqual(hi.x, 1)
        XCTAssertEqual(lo.y, 0); XCTAssertEqual(hi.y, 1, "the short axis is untouched")

        // The carried circle, as a box inside the *destination* frame. A short-edge radius `r` spans
        // `r·min/W` in normalised x, so the box is not the same rectangle — it is the same *circle*.
        let g = radialOf(merged.masks[0])!
        let halfX = 0.2 * threeTwo.h / threeTwo.w       // r · min/W
        let halfY = 0.2 * threeTwo.h / threeTwo.h
        let box = (x0: g.center.x - halfX, x1: g.center.x + halfX,
                   y0: g.center.y - halfY, y1: g.center.y + halfY)
        print("FRAME  carried circle box: x[\(box.x0), \(box.x1)] y[\(box.y0), \(box.y1)]")
        XCTAssertGreaterThanOrEqual(box.x0, 0)
        XCTAssertLessThanOrEqual(box.x1, 1)
        XCTAssertGreaterThanOrEqual(box.y0, 0)
        XCTAssertLessThanOrEqual(box.y1, 1)
        // And it moved toward the centre on the long axis only: 0.25 → 0.2778, 0.75 → 0.75.
        XCTAssertEqual(g.center.x, 0.5 + (0.25 - 0.5) * kx, accuracy: 1e-12)
        XCTAssertEqual(g.center.y, 0.75, accuracy: 0.0, "the short axis is not merely close: exact")

        // Brush polylines are points too: [0.9, 0.5, 0.6, 0.75] → x scaled, y kept.
        let brushed = documentA()
        var withBrush = brushed
        withBrush.masks = [brushMask(id: "m-a3")]
        let brushPayload = EditSnapshot.capture(withBrush, frameAspect: aspectA)
            .filtered(to: [.masks])
        let brushMerged = brushPayload.applied(to: .neutral, destinationAspect: aspectB)
        guard case .brush(let b)? = brushMerged.masks[0].components.first?.shape else {
            return XCTFail("still a brush")
        }
        let points = b.strokes[0].points
        XCTAssertEqual(Double(points[0]), 0.5 + (0.9 - 0.5) * kx, accuracy: 1e-6)
        XCTAssertEqual(Double(points[1]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(points[2]), 0.5 + (0.6 - 0.5) * kx, accuracy: 1e-6)
        XCTAssertEqual(Double(points[3]), 0.75, accuracy: 1e-6)
        XCTAssertEqual(b.strokes[0].radius, 0.05, "the stroke's radius is short-edge units: unchanged")
        XCTAssertEqual(b.strokes[0].feather, 0.3)
        XCTAssertEqual(b.strokes[0].flow, 0.7)
    }

    /// Same aspect ratio is the identity, and it is the *identity* rather than "equal to 1e-12":
    /// that is what makes the short-edge rule a strict superset of "copy the fractions".
    func testEqualAspectRatioCarriesTheGeometryUnchanged() {
        let a = documentA()
        let sameAspect = (w: 6720.0, h: 5040.0)          // 4:3, like A
        var b = EditModel.neutral
        b.masks = [radial(id: "B-mask", center: NormalizedPoint(0.5, 0.5), radius: 0.3)]

        let payload = EditSnapshot.capture(a, frameAspect: aspectA).filtered(to: [.masks])
        let merged = payload.applied(to: b, destinationAspect: sameAspect.w / sameAspect.h)
        let carried = merged.masks[1]
        XCTAssertEqual(carried.selectionKey.replacingOccurrences(of: carried.id, with: ""),
                       a.masks[0].selectionKey.replacingOccurrences(of: a.masks[0].id, with: ""),
                       "same aspect ratio: byte-identical geometry, masks and keys")
        XCTAssertEqual(carried.components.first?.shape, a.masks[0].components.first?.shape)

        // Unknown aspect ratios degrade to the same thing (copy the fractions), never to a guess.
        let unknown = EditSnapshot.capture(a).filtered(to: [.masks]).applied(to: b)
        XCTAssertEqual(unknown.masks[1].components.first?.shape, a.masks[0].components.first?.shape)
        XCTAssertNil(EditSnapshot.capture(a).masks?.frameAspect)
    }

    // MARK: - ③ masks only: everything else byte-for-byte unchanged

    func testMaskOnlyPasteLeavesEveryOtherFieldByteIdentical() {
        let b = documentB()
        let payload = EditSnapshot.capture(documentA(), frameAspect: aspectA)
            .filtered(to: [.masks])
        let merged = payload.applied(to: b, destinationAspect: aspectB)

        // The whole document minus its mask list, byte for byte (encoded, so a float that survived
        // JSON at a different precision would show).
        var strippedBefore = b; strippedBefore.masks = []
        var strippedAfter = merged; strippedAfter.masks = []
        let canonical: (EditModel) throws -> String = { model in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(data: try encoder.encode(model), encoding: .utf8) ?? ""
        }
        XCTAssertEqual(try canonical(strippedBefore), try canonical(strippedAfter),
                       "只粘蒙版: exposure / colour / curve / crop / effects are the bytes they were")
        XCTAssertEqual(merged.light, b.light)
        XCTAssertEqual(merged.color, b.color)
        XCTAssertEqual(merged.curve, b.curve)
        XCTAssertEqual(merged.geometry, b.geometry)
        XCTAssertEqual(merged.effects, b.effects)
        XCTAssertEqual(merged.detail, b.detail)
        XCTAssertEqual(merged.showMaskID, b.showMaskID, "the overlay is view state, never carried")

        // And the diff agrees: the only fields that moved are masks.<id>.…
        let keys = EditHistory.changedFields(between: b, and: merged).map(\.field.key)
        print("SECTION masks-only → B: \(keys.sorted())")
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("masks.") },
                      "只粘蒙版 moved nothing outside the mask list; got \(keys.sorted())")
        // Exactly one mask was added and none removed.
        XCTAssertEqual(keys.filter { $0.hasSuffix(".added") }.count, 2)
        XCTAssertEqual(keys.filter { $0.hasSuffix(".removed") }.count, 0)
        XCTAssertFalse(payload.requiresDecode, "masks are a GPU-stage change, not a development")

        // The opposite narrowing still drops masks (the section is copied only when checked).
        let toneOnly = EditSnapshot.capture(documentA(), frameAspect: aspectA).filtered(to: [.light])
        XCTAssertEqual(toneOnly.maskCount, 0)
        XCTAssertEqual(toneOnly.applied(to: b, destinationAspect: aspectB).masks.map(\.id),
                       ["B-mask"], "曝光 does not carry the mask list")
    }

    // MARK: - ④ 反证: without re-identification the uniqueness assertion goes red

    /// The 反证 for `testTwoMasksPasteOntoOneAndAllThreeIDsAreDistinct`. `m-shared` is what two photos
    /// derived from one another actually look like (a virtual copy keeps the mask list), so appending
    /// the source's masks **as they are** produces two masks with one id: the cache key, the
    /// `MaskGraph` node and the history's `masks.<id>.…` rows all collapse. The assertion that fails
    /// is the same one the real path passes.
    func testWithoutRegeneratingIDsTheUniquenessAssertionFails() {
        var a = EditModel.neutral
        a.masks = [radial(id: "m-shared", center: NormalizedPoint(0.3, 0.3), radius: 0.2)]
        var b = EditModel.neutral
        b.masks = [radial(id: "m-shared", center: NormalizedPoint(0.6, 0.6), radius: 0.2)]

        // The naive merge: append the payload's masks untouched.
        var naive = b
        naive.masks.append(contentsOf: a.masks)
        let naiveIDs = naive.masks.map(\.id)
        print("反证  naive ids: \(naiveIDs) unique=\(Set(naiveIDs).count)")
        XCTAssertEqual(naiveIDs, ["m-shared", "m-shared"])
        XCTAssertNotEqual(Set(naiveIDs).count, naiveIDs.count,
                          "反证: without new ids the document has two masks with one identity")
        // What a shared id collapses: the history keys its mask rows by id (`masks.<id>.…`), so the
        // two rows become one identity there — the reason the shipped path mints an id per copy.
        XCTAssertEqual(Set(naive.masks.map { "masks.\($0.id)" }).count, 1,
                       "反证: and the history's id-keyed diff cannot tell the two apart")

        // The shipped path, on the same inputs.
        let merged = EditSnapshot.capture(a, frameAspect: aspectA).filtered(to: [.masks])
            .applied(to: b, destinationAspect: aspectB)
        let ids = merged.masks.map(\.id)
        print("反证  regenerated ids: \(ids) unique=\(Set(ids).count)")
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "regeneration is what makes this hold: \(ids)")
        XCTAssertEqual(ids[0], "m-shared", "the destination's own id is never rewritten")
        XCTAssertEqual(Set(merged.masks.map(\.selectionKey)).count, 2)
    }

    // MARK: - the cap, and the payload's own round trip

    func testAPasteNeverExceedsTheMaskCap() {
        var b = EditModel.neutral
        b.masks = (0..<(Mask.maxCount - 1)).map {
            radial(id: "m-b\($0)", center: NormalizedPoint(0.5, 0.5), radius: 0.05)
        }
        let merged = EditSnapshot.capture(documentA(), frameAspect: aspectA)
            .filtered(to: [.masks])
            .applied(to: b, destinationAspect: aspectB)
        XCTAssertEqual(merged.masks.count, Mask.maxCount,
                       "one slot left, one mask taken: §7's cap is respected, not exceeded")
        XCTAssertEqual(Set(merged.masks.map(\.id)).count, Mask.maxCount)
    }

    func testTheMasksSectionSurvivesJSONAndV1PayloadsStillDecode() throws {
        var a = documentA()
        a.showMaskID = "m-a1"
        let payload = EditSnapshot.capture(a, frameAspect: aspectA).filtered(to: [.masks])
        // The envelope's own version, not a literal: it went 1 → 2 with P1-5 (masks in the clipboard)
        // and 2 → 3 with 081 (`⌘C` card-level copy added optional keys such as `light.blackOffset`,
        // which an older reader would silently drop — the same reason masks bumped it). What this
        // test guards is that the payload is **versioned at all** and that the document's own schema
        // version is untouched, so it reads the constant.
        XCTAssertEqual(payload.schemaVersion, EditSnapshot.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(payload.schemaVersion, 2,
                                    "the clipboard's shape has changed at least once since 1 (P1-5)")
        XCTAssertEqual(EditModel.neutral.schemaVersion, EditModel.currentSchemaVersion,
                       "the document's own schema version is untouched: masks already existed there")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(payload), encoding: .utf8) ?? ""
        print("JSON   \(json.prefix(160))…")
        XCTAssertTrue(json.contains("\"masks\""))
        XCTAssertFalse(json.contains("\"showMaskID\""), "view state never enters a payload")
        let decoded = try JSONDecoder().decode(EditSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.masks?.frameAspect, aspectA)
        XCTAssertEqual(decoded.maskCount, 2)

        // A payload written before P1-5: no `masks` key at all. It must still decode, and mean "the
        // destination keeps its own masks".
        let v1 = """
        {"schemaVersion":1,"light":{"exposure":0.5},"geometry":{"cropX":0.1}}
        """
        let old = try JSONDecoder().decode(EditSnapshot.self, from: Data(v1.utf8))
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertNil(old.masks)
        XCTAssertEqual(old.maskCount, 0)
        var target = documentB()
        target.showMaskID = "B-mask"
        let merged = old.applied(to: target, destinationAspect: aspectB)
        XCTAssertEqual(merged.masks.map(\.id), ["B-mask"])
        XCTAssertEqual(merged.light.exposure, 0.5)
        XCTAssertEqual(merged.showMaskID, "B-mask")
    }
}
