import XCTest
import PhotonsCore

/// 264 — the exhaustive guard for 263's revert map.
///
/// 263 added a `FieldChange → setter` table to `History.revert(at:)`. Its tests covered only
/// `exposure / curve / heal`, so a new parameter could be added to `changedFields` **and to the
/// document** while nobody wrote the matching revert branch: undo would then silently put back only
/// some of the row's fields — no error, no red test, just a picture that does not match the history.
///
/// This file fixes that with one list, `cases`, and two questions asked of it:
///
/// 1. **The list is every diffable field.** Two documents that differ on *every* parameter must
///    produce exactly the list's keys (a stale fixture or a forgotten new field is a red test).
/// 2. **Every key reverts.** Each case builds `A → B` where only that one parameter moved, reverts
///    the row, and demands that the resulting document is `A` again — compared with
///    `EditHistory.changedFields`, so floats use `dirtyTolerance` and not `==`.
///
/// The reverse gate is `testEveryFieldInTheChecklistRevertsToItsPreviousValue`: comment out any
/// `case` in `EditHistory.revert(_:from:into:)` and the failure names that field's key.
final class RevertMapCoverageTests: XCTestCase {

    // MARK: - the checklist

    /// One diffable parameter: the key `changedFields` prints, the document the case starts from,
    /// and the single mutation that moves **only** that parameter.
    private struct FieldCase {
        let key: String
        let base: EditModel
        let apply: (inout EditModel) -> Void
    }

    private static let maskID = "m-keep"
    private static let shapeMaskID = "m-shape"
    private static let countMaskID = "m-count"
    private static let addedMaskID = "m-added"
    private static let removedMaskID = "m-removed"
    private static let orderMaskIDs = ["m-order-1", "m-order-2"]

    private static let healID = "h-keep"
    private static let kindHealID = "h-kind"
    private static let addedHealID = "h-added"
    private static let removedHealID = "h-removed"
    private static let orderHealIDs = ["h-order-1", "h-order-2"]

    private func base(masks: [Mask] = [], heal: [HealSpot] = []) -> EditModel {
        var m = EditModel.neutral
        m.masks = masks
        m.healSpots = heal
        return m
    }

    private func flat(_ key: String,
                      _ apply: @escaping (inout EditModel) -> Void) -> FieldCase {
        FieldCase(key: key, base: .neutral, apply: apply)
    }

    // MARK: dynamic (id/index-keyed) helpers

    private func curvePath(_ list: String) -> WritableKeyPath<EditModel, [CurvePoint]> {
        switch list {
        case "white": return \EditModel.curve.white
        case "red": return \EditModel.curve.red
        case "green": return \EditModel.curve.green
        default: return \EditModel.curve.blue
        }
    }

    private static let curveLists = ["white", "red", "green", "blue"]
    private static let bandAxes = ["hue", "saturation", "luminance", "mix"]
    private static let gradeWheels = ["shadows", "midtones", "highlights"]
    private static let gradeAxes = ["hue", "saturation", "lightness"]

    private func curvePoint(_ list: String, _ index: Int, _ axis: String,
                            _ value: Double) -> FieldCase {
        let path = curvePath(list)
        return flat("curve.\(list)[\(index)].\(axis)") { m in
            var points = m[keyPath: path]
            if axis == "x" { points[index].x = value } else { points[index].y = value }
            m[keyPath: path] = points
        }
    }

    private func curveCount(_ list: String) -> FieldCase {
        let path = curvePath(list)
        return flat("curve.\(list).count") { m in
            // A point inserted **in the middle**, which is the real UI gesture (and the case the old
            // append/remove-by-tail implementation could not put back).
            m[keyPath: path] = [CurvePoint(0, 0), CurvePoint(1, 1), CurvePoint(2, 2)]
        }
    }

    private func bandField(_ index: Int, _ axis: String, _ value: Double) -> FieldCase {
        flat("color.bands[\(index)].\(axis)") { m in
            switch axis {
            case "hue": m.color.bands[index].hue = value
            case "saturation": m.color.bands[index].saturation = value
            case "luminance": m.color.bands[index].luminance = value
            default: m.color.bands[index].mix = value
            }
        }
    }

    private func gradeField(_ wheel: String, _ axis: String, _ value: Double) -> FieldCase {
        flat("colorGrading.\(wheel).\(axis)") { m in
            var grade: GradeWheel
            switch wheel {
            case "shadows": grade = m.colorGrading.shadows
            case "midtones": grade = m.colorGrading.midtones
            default: grade = m.colorGrading.highlights
            }
            switch axis {
            case "hue": grade.hue = value
            case "saturation": grade.saturation = value
            default: grade.lightness = value
            }
            switch wheel {
            case "shadows": m.colorGrading.shadows = grade
            case "midtones": m.colorGrading.midtones = grade
            default: m.colorGrading.highlights = grade
            }
        }
    }

    private func pointField(_ field: String,
                            _ apply: @escaping (inout PointColor) -> Void) -> FieldCase {
        // The base already carries one swatch so the mutation moves that field and not
        // "a swatch appeared" (`color.point[0]` exists on both sides).
        var start = EditModel.neutral
        start.color.point = PointColorSet(swatches: [PointColor()], active: 0)
        return FieldCase(key: "color.point[0].\(field)", base: start) { m in
            guard var set = m.color.point, !set.swatches.isEmpty else { return }
            apply(&set.swatches[0])
            m.color.point = set
        }
    }

    private func maskField(_ field: String,
                           _ baseMask: Mask? = nil,
                           _ apply: @escaping (inout Mask) -> Void) -> FieldCase {
        let id = Self.maskID
        return FieldCase(key: "masks.\(id).\(field)",
                         base: base(masks: [baseMask ?? Mask(id: id)])) { m in
            // The lookup form (not `m.masks[0] = …`) keeps the other masks of the shared fixture
            // alive, so every mask case can be applied to the same "all fields differ" document.
            m.masks = m.masks.map { mask in
                guard mask.id == id else { return mask }
                var copy = mask
                apply(&copy)
                return copy
            }
        }
    }

    private func healField(_ field: String,
                           _ baseSpot: HealSpot? = nil,
                           _ apply: @escaping (inout HealSpot) -> Void) -> FieldCase {
        let id = Self.healID
        return FieldCase(key: "heal.\(id).\(field)",
                         base: base(heal: [baseSpot ?? HealSpot(id: id)])) { m in
            m.healSpots = m.healSpots.map { spot in
                guard spot.id == id else { return spot }
                var copy = spot
                apply(&copy)
                return copy
            }
        }
    }

    // MARK: - every field `changedFields` can print

    private var cases: [FieldCase] {
        var all: [FieldCase] = [
            flat("document.schemaVersion") {
                $0.schemaVersion = EditModel.currentSchemaVersion - 1
            },
            flat("document.processVersion") {
                $0.processVersion = EditModel.currentProcessVersion - 1
            },

            // S0 — geometry.
            flat("geometry.crop.x") { $0.geometry.crop.x = 0.1 },
            flat("geometry.crop.y") { $0.geometry.crop.y = 0.2 },
            flat("geometry.crop.width") { $0.geometry.crop.width = 0.5 },
            flat("geometry.crop.height") { $0.geometry.crop.height = 0.6 },
            flat("geometry.rotationDegrees") { $0.geometry.rotationDegrees = 1.5 },
            flat("geometry.flipHorizontal") { $0.geometry.flipHorizontal = true },
            flat("geometry.flipVertical") { $0.geometry.flipVertical = true },
            flat("geometry.perspectiveVertical") { $0.geometry.perspectiveVertical = 10 },
            flat("geometry.perspectiveHorizontal") { $0.geometry.perspectiveHorizontal = 20 },
            flat("geometry.quarterTurns") { $0.geometry.quarterTurns = 1 },
            flat("geometry.aspectLock") { $0.geometry.aspectLock = .threeTwo },

            // S1 / S2 — Light.
            flat("light.exposure") { $0.light.exposure = 1 },
            flat("light.contrast") { $0.light.contrast = 20 },
            flat("light.highlights") { $0.light.highlights = 10 },
            flat("light.midtones") { $0.light.midtones = 15 },
            flat("light.shadows") { $0.light.shadows = -10 },
            flat("light.whites") { $0.light.whites = 5 },
            flat("light.blacks") { $0.light.blacks = -5 },
            flat("light.temperature") { $0.light.temperature = 5200 },
            flat("light.tint") { $0.light.tint = 8 },
            flat("light.highlightRecovery") { $0.light.highlightRecovery = 0.4 },
            flat("light.blackOffset") { $0.light.blackOffset = 0.002 },

            // S3 — Color's global numbers and the B&W switch. (The bands are added below.)
            flat("color.vibrance") { $0.color.vibrance = 20 },
            flat("color.saturation") { $0.color.saturation = 30 },
            flat("color.global.hue") { $0.color.global.hue = 12 },
            flat("color.global.saturation") { $0.color.global.saturation = -18 },
            flat("color.global.luminance") { $0.color.global.luminance = 7 },
            flat("color.blackAndWhite") { $0.color.blackAndWhite = true },

            // Detail and the decoder-side amounts.
            flat("detail.sharpening") { $0.detail.sharpening = 40 },
            flat("detail.sharpeningRadius") { $0.detail.sharpeningRadius = 2 },
            flat("detail.noiseLuminance") { $0.detail.noiseLuminance = 30 },
            flat("detail.noiseColor") { $0.detail.noiseColor = 20 },
            flat("detail.lensCorrections") { $0.detail.lensCorrections = true },
            flat("detailSettings.luminanceNR") { $0.detailSettings.luminanceNR = 20 },
            flat("detailSettings.colorNR") { $0.detailSettings.colorNR = 30 },
            flat("detailSettings.sharpness") { $0.detailSettings.sharpness = 40 },
            flat("detailSettings.detail") { $0.detailSettings.detail = 5 },
            flat("detailSettings.moire") { $0.detailSettings.moire = 10 },
            flat("decoderVersion") { $0.decoderVersion = "9.dng" },

            // Effects + the display-domain sharpen.
            flat("effects.vignetteAmount") { $0.effects.vignetteAmount = -30 },
            flat("effects.vignetteMidpoint") { $0.effects.vignetteMidpoint = 60 },
            flat("effects.vignetteFeather") { $0.effects.vignetteFeather = 40 },
            flat("effects.grain") { $0.effects.grain = 25 },
            flat("effects.grainSize") { $0.effects.grainSize = 35 },
            flat("effects.grainRoughness") { $0.effects.grainRoughness = 45 },
            flat("effects.grainSeed") { $0.effects.grainSeed = 7 },
            flat("effects.texture") { $0.effects.texture = 15 },
            flat("effects.clarity") { $0.effects.clarity = 25 },
            flat("effects.nonBayerLuminanceNR") { $0.effects.nonBayerLuminanceNR = 35 },
            flat("effects.nonBayerColorNR") { $0.effects.nonBayerColorNR = 45 },
            flat("effects.dehaze") { $0.effects.dehaze = 20 },
            flat("sharpen.amount") { $0.sharpen.amount = 80 },
            flat("sharpen.radius") { $0.sharpen.radius = 2 },
            flat("sharpen.detail") { $0.sharpen.detail = 50 },
            flat("sharpen.masking") { $0.sharpen.masking = 20 },

            // 029 — lateral CA.
            flat("optics.caRed") { $0.optics.caRed = 0.002 },
            flat("optics.caBlue") { $0.optics.caBlue = -0.001 },

            // 179 — 原色校准's seven numbers.
            flat("calibration.shadowTint") { $0.calibration.shadowTint = 20 },
            flat("calibration.redHue") { $0.calibration.redHue = 25 },
            flat("calibration.redSat") { $0.calibration.redSat = -15 },
            flat("calibration.greenHue") { $0.calibration.greenHue = 10 },
            flat("calibration.greenSat") { $0.calibration.greenSat = 5 },
            flat("calibration.blueHue") { $0.calibration.blueHue = -20 },
            flat("calibration.blueSat") { $0.calibration.blueSat = 12 },
        ]

        // S1.7 — four curves, both coordinates at both endpoints, and the structural count.
        for list in Self.curveLists {
            for index in 0..<2 {
                all.append(curvePoint(list, index, "x", index == 0 ? 0.1 : 1.9))
                all.append(curvePoint(list, index, "y", index == 0 ? 0.2 : 1.8))
            }
            all.append(curveCount(list))
        }

        // S3.6 / S3.4 — every band, all four axes.
        for index in 0..<ColorGroup.bandCount {
            for (offset, axis) in Self.bandAxes.enumerated() {
                all.append(bandField(index, axis, Double(index * 4 + offset + 1)))
            }
        }

        // S3.8 — the three wheels' three numbers.
        for (wheelIndex, wheel) in Self.gradeWheels.enumerated() {
            for (axisIndex, axis) in Self.gradeAxes.enumerated() {
                all.append(gradeField(wheel, axis, Double(wheelIndex * 3 + axisIndex + 1)))
            }
        }

        // S3.6b — one swatch's sample, window and three adjustments.
        all += [
            pointField("sampleY") { $0.sampleY = 0.4 },
            pointField("sampleU") { $0.sampleU = 0.45 },
            pointField("sampleV") { $0.sampleV = 0.55 },
            pointField("range") { $0.range = 40 },
            pointField("feather") { $0.feather = 20 },
            pointField("hue") { $0.hue = 10 },
            pointField("saturation") { $0.saturation = -10 },
            pointField("luminance") { $0.luminance = 5 },
        ]

        // Masks — the seven fields plus the eleven local adjustments…
        all += [
            maskField("isEnabled") { $0.isEnabled = false },
            maskField("opacity") { $0.opacity = 0.5 },
            maskField("invert") { $0.invert = true },
            maskField("feather") { $0.feather = 0.2 },
            maskField("refine") { $0.refine = 0.5 },
            maskField("name") { $0.name = "Sky" },
            FieldCase(key: "masks.\(Self.countMaskID).components",
                      base: base(masks: [Mask(id: Self.countMaskID)])) { m in
                m.masks = m.masks.map { mask in
                    guard mask.id == Self.countMaskID else { return mask }
                    var copy = mask
                    copy.components = [MaskComponent()]
                    return copy
                }
            },
            // 267b — the fields inside a component. `op` has the card's 组合方式 picker; invert and
            // feather have no slider today, but they are render inputs and must be diffable.
            maskField("components[0].op", Mask(id: Self.maskID, components: [MaskComponent()])) {
                $0.components[0].op = .subtract
            },
            maskField("components[0].invert",
                      Mask(id: Self.maskID, components: [MaskComponent()])) {
                $0.components[0].invert = true
            },
            maskField("components[0].feather",
                      Mask(id: Self.maskID, components: [MaskComponent()])) {
                $0.components[0].feather = 0.2
            },

            maskField("adj.amount") { $0.adjustments.amount = 50 },
            maskField("adj.exposure") { $0.adjustments.exposure = 1 },
            maskField("adj.temperature") { $0.adjustments.temperature = 10 },
            maskField("adj.tint") { $0.adjustments.tint = 5 },
            maskField("adj.contrast") { $0.adjustments.contrast = 10 },
            maskField("adj.highlights") { $0.adjustments.highlights = 5 },
            maskField("adj.shadows") { $0.adjustments.shadows = -5 },
            maskField("adj.whites") { $0.adjustments.whites = 3 },
            maskField("adj.blacks") { $0.adjustments.blacks = -3 },
            maskField("adj.hue") { $0.adjustments.hue = 10 },
            maskField("adj.saturation") { $0.adjustments.saturation = -10 },
            maskField("adj.texture") { $0.adjustments.texture = 30 },
            maskField("adj.sharpen") { $0.adjustments.sharpen = 40 },

            // 267 — a component's geometry (the shape behind a canvas handle drag).
            FieldCase(key: "masks.\(Self.shapeMaskID).components[0].shape",
                      base: base(masks: [Mask(id: Self.shapeMaskID,
                                              components: [MaskComponent()])])) { m in
                m.masks = m.masks.map { mask in
                    guard mask.id == Self.shapeMaskID, !mask.components.isEmpty else { return mask }
                    var copy = mask
                    copy.components[0].shape = .linearGradient(
                        LinearGradientShape(start: NormalizedPoint(0.2, 0.1)))
                    return copy
                }
            },
        ]

        // …and the three structural entries.
        all += [
            FieldCase(key: "masks.\(Self.addedMaskID).added", base: .neutral) {
                $0.masks = [Mask(id: Self.addedMaskID)]
            },
            FieldCase(key: "masks.\(Self.removedMaskID).removed",
                      base: base(masks: [Mask(id: Self.removedMaskID)])) {
                $0.masks = []
            },
            FieldCase(key: "masks.order",
                      base: base(masks: Self.orderMaskIDs.map { Mask(id: $0) })) {
                $0.masks = [Mask(id: Self.orderMaskIDs[1]), Mask(id: Self.orderMaskIDs[0])]
            },
        ]

        // Heal spots — the eight fields plus added / removed / order.
        all += [
            healField("center.x") { $0.center.x = 0.4 },
            healField("center.y") { $0.center.y = 0.6 },
            healField("radius") { $0.radius = 0.03 },
            healField("source.x") { $0.sourceOffset.x = 0.1 },
            healField("source.y") { $0.sourceOffset.y = 0.02 },
            healField("feather") { $0.feather = 0.2 },
            healField("opacity") { $0.opacity = 0.8 },
            healField("mode") { $0.mode = .clone },

            // 267 — 229's 红眼. The kind row uses its own spot so `healID` can stay `.redeye` on both
            // sides of the universe (see the red-eye trap below); the red-gate rows need a `.redeye`
            // base because a `.heal` spot ignores both numbers in `HealSpot.==`.
            FieldCase(key: "heal.\(Self.kindHealID).kind",
                      base: base(heal: [HealSpot(id: Self.kindHealID)])) { m in
                m.healSpots = m.healSpots.map { spot in
                    guard spot.id == Self.kindHealID else { return spot }
                    var copy = spot
                    copy.kind = .redeye
                    return copy
                }
            },
            healField("redThreshold",
                      HealSpot(id: Self.healID, kind: .redeye, redThreshold: 0.4)) {
                $0.redThreshold = 0.7
            },
            healField("redSoftness",
                      HealSpot(id: Self.healID, kind: .redeye, redSoftness: 0.1)) {
                $0.redSoftness = 0.2
            },

            FieldCase(key: "heal.\(Self.addedHealID).added", base: .neutral) {
                $0.healSpots = [HealSpot(id: Self.addedHealID)]
            },
            FieldCase(key: "heal.\(Self.removedHealID).removed",
                      base: base(heal: [HealSpot(id: Self.removedHealID)])) {
                $0.healSpots = []
            },
            // Distinct radii: a spot's key material deliberately excludes its id, so two otherwise
            // identical spots in a different order are the *same picture* and `commit` refuses them
            // as a no-op. Two different spots make the reorder a real edit.
            FieldCase(key: "heal.order",
                      base: base(heal: [HealSpot(id: Self.orderHealIDs[0], radius: 0.02),
                                        HealSpot(id: Self.orderHealIDs[1], radius: 0.05)])) {
                $0.healSpots = [HealSpot(id: Self.orderHealIDs[1], radius: 0.05),
                                HealSpot(id: Self.orderHealIDs[0], radius: 0.02)]
            },
        ]

        return all
    }

    private var curveCountKeys: Set<String> {
        Set(cases.map(\.key).filter { $0.hasPrefix("curve.") && $0.hasSuffix(".count") })
    }

    // MARK: - ① the checklist is the whole field universe

    /// `A` / `B` differ on every diffable parameter, including every dynamic index. The only
    /// exception is the curve's structural `count`, which is mutually exclusive with a coordinate
    /// diff by construction (`changedFields` emits either the count or the points) — it gets its own
    /// fixture below.
    private func universeA() -> EditModel {
        var m = EditModel.neutral
        m.color.point = PointColorSet(swatches: [PointColor()], active: 0)
        m.masks = [Mask(id: Self.maskID, components: [MaskComponent()]),
                   Mask(id: Self.shapeMaskID, components: [MaskComponent()]),
                   Mask(id: Self.countMaskID),
                   Mask(id: Self.removedMaskID),
                   Mask(id: Self.orderMaskIDs[0]), Mask(id: Self.orderMaskIDs[1])]
        m.healSpots = [HealSpot(id: Self.healID, kind: .redeye),
                       HealSpot(id: Self.kindHealID),
                       HealSpot(id: Self.removedHealID),
                       HealSpot(id: Self.orderHealIDs[0]), HealSpot(id: Self.orderHealIDs[1])]
        return m
    }

    private func universeB() -> EditModel {
        var b = universeA()

        // Every flat / coordinate / band / point / grade case, applied to one document. Mask and
        // heal cases are set explicitly below (applying all of them would add and remove the same
        // list entries); their structural keys are produced by these lists.
        for c in cases where !c.key.hasPrefix("masks.")
            && !c.key.hasPrefix("heal.")
            && !(c.key.hasPrefix("curve.") && c.key.hasSuffix(".count")) {
            c.apply(&b)
        }

        b.masks = [
            Mask(id: Self.maskID, name: "Sky", isEnabled: false, opacity: 0.5, invert: true,
                 feather: 0.2, refine: 0.5,
                 components: [MaskComponent(op: .subtract, invert: true, feather: 0.2)],
                 adjustments: LocalAdjustments(amount: 50, exposure: 1, temperature: 10, tint: 5,
                                               contrast: 10, highlights: 5, shadows: -5,
                                               whites: 3, blacks: -3, hue: 10, saturation: -10,
                                               texture: 30, sharpen: 40)),
            Mask(id: Self.shapeMaskID, components: [MaskComponent(
                shape: .linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1))))]),
            Mask(id: Self.countMaskID, components: [MaskComponent()]),
            Mask(id: Self.addedMaskID),
            Mask(id: Self.orderMaskIDs[1]),
            Mask(id: Self.orderMaskIDs[0]),
        ]
        b.healSpots = [
            HealSpot(id: Self.healID, center: NormalizedPoint(0.4, 0.6), radius: 0.03,
                     sourceOffset: NormalizedPoint(0.1, 0.02), mode: .clone,
                     feather: 0.2, opacity: 0.8, kind: .redeye,
                     redThreshold: 0.7, redSoftness: 0.2),
            HealSpot(id: Self.kindHealID, kind: .redeye),
            HealSpot(id: Self.addedHealID),
            HealSpot(id: Self.orderHealIDs[1]),
            HealSpot(id: Self.orderHealIDs[0]),
        ]
        return b
    }

    func testTheChecklistIsEveryFieldChangedFieldsReports() {
        let checklist = Set(cases.map(\.key))
        XCTAssertEqual(checklist.count, cases.count, "清单里有重复 key")

        // The one pair that moves every non-structural-curve field.
        let a = universeA()
        let b = universeB()
        let actual = Set(EditHistory.changedFields(between: a, and: b).map(\.field.key))
        let expected = checklist.subtracting(curveCountKeys)
        XCTAssertEqual(actual, expected,
                       "字段全集与清单不一致：多出 \(actual.subtracting(expected).sorted())，"
                       + "缺少 \(expected.subtracting(actual).sorted())")

        // The structural count fixture: each of the four curves gains a point.
        var counted = EditModel.neutral
        for list in Self.curveLists {
            counted[keyPath: curvePath(list)] = [CurvePoint(0, 0), CurvePoint(1, 1),
                                                 CurvePoint(2, 2)]
        }
        let actualCounts = Set(EditHistory.changedFields(between: .neutral, and: counted)
                                .map(\.field.key))
        XCTAssertEqual(actualCounts, curveCountKeys,
                       "曲线 count 与清单不一致："
                       + "多出 \(actualCounts.subtracting(curveCountKeys).sorted())，"
                       + "缺少 \(curveCountKeys.subtracting(actualCounts).sorted())")

        XCTAssertEqual(actual.union(actualCounts), checklist,
                       "两份夹具合起来没有覆盖清单："
                       + "\(checklist.symmetricDifference(actual.union(actualCounts)).sorted())")

        print("264 CHECKLIST · \(checklist.count) fields · dynamic fixture \(actual.count)"
              + " · curve counts \(actualCounts.count)")
    }

    // MARK: - ② every field reverts to its previous value

    func testEveryFieldInTheChecklistRevertsToItsPreviousValue() {
        var failures: [String] = []

        for c in cases {
            var b = c.base
            c.apply(&b)

            let moved = EditHistory.changedFields(between: c.base, and: b).map(\.field.key)
            guard moved.contains(c.key) else {
                XCTFail("夹具没有移动 \(c.key)（实际 moved: \(moved)）")
                failures.append(c.key)
                continue
            }

            var history = EditHistory(baseline: c.base)
            guard history.commit(b, label: c.key, coalesce: false) != nil else {
                XCTFail("commit 没有产生一行：\(c.key)")
                failures.append(c.key)
                continue
            }
            guard let reverted = history.revert(at: 1) else {
                XCTFail("revert(at: 1) 返回 nil：\(c.key)")
                failures.append(c.key)
                continue
            }

            // Field-level comparison, at the same tolerance the history and the cache use.
            let residual = EditHistory.changedFields(between: c.base, and: reverted.edit)
                .map(\.field.key)
            guard residual.isEmpty else {
                XCTFail("revert 后 \(c.key) 没有回到 A：残余字段 \(residual)")
                failures.append(c.key)
                continue
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(cases.count) 个字段撤销后没有回到原值：\(failures)")
        }
        print("264 REVERT · \(cases.count - failures.count)/\(cases.count) fields restored"
              + (failures.isEmpty ? "" : " · failed \(failures)"))
    }
}
