import XCTest
import PhotonsCore

/// 267 — the two-direction audit of `EditHistory.changedFields`.
///
/// 264's guard (`RevertMapCoverageTests`) only covered fields `changedFields` **could already
/// produce**. A parameter that `changedFields` never mentions is invisible there: it produces no
/// history row, so there is nothing to revert and no case to list. This file starts from the other
/// side — every parameter the UI can move — and demands two things of each one:
///
/// 1. moving it produces **exactly one** row, with exactly its own key;
/// 2. that row reverts to the value it had before, i.e. "drag it, press ⌘Z" is the identity.
///
/// A third, deliberately separate list holds the fields that are **not** edits (view state). Each
/// entry asserts that changing it produces **no** diff, so the day somebody puts view state into the
/// document diff the test goes red and the whitelist has to be deleted, not silently extended.
final class DiffCoverageTests: XCTestCase {

    // MARK: - fixtures

    private struct Param {
        let key: String
        let base: EditModel
        let apply: (inout EditModel) -> Void
    }

    private struct Whitelisted {
        let key: String
        let reason: String
        let base: EditModel
        let apply: (inout EditModel) -> Void
    }

    private static let maskID = "m-267"
    private static let orderMaskIDs = ["m-267-order-1", "m-267-order-2"]

    private static let healID = "h-267"
    private static let orderHealIDs = ["h-267-order-1", "h-267-order-2"]

    private func base(masks: [Mask] = [], heal: [HealSpot] = []) -> EditModel {
        var m = EditModel.neutral
        m.masks = masks
        m.healSpots = heal
        return m
    }

    private func flat(_ key: String,
                      _ apply: @escaping (inout EditModel) -> Void) -> Param {
        Param(key: key, base: .neutral, apply: apply)
    }

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
                            _ value: Double) -> Param {
        let path = curvePath(list)
        return flat("curve.\(list)[\(index)].\(axis)") { m in
            var points = m[keyPath: path]
            if axis == "x" { points[index].x = value } else { points[index].y = value }
            m[keyPath: path] = points
        }
    }

    private func curveCount(_ list: String) -> Param {
        let path = curvePath(list)
        return flat("curve.\(list).count") { m in
            m[keyPath: path] = [CurvePoint(0, 0), CurvePoint(1, 1), CurvePoint(2, 2)]
        }
    }

    private func bandField(_ index: Int, _ axis: String, _ value: Double) -> Param {
        flat("color.bands[\(index)].\(axis)") { m in
            switch axis {
            case "hue": m.color.bands[index].hue = value
            case "saturation": m.color.bands[index].saturation = value
            case "luminance": m.color.bands[index].luminance = value
            default: m.color.bands[index].mix = value
            }
        }
    }

    private func gradeField(_ wheel: String, _ axis: String, _ value: Double) -> Param {
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
                            _ apply: @escaping (inout PointColor) -> Void) -> Param {
        var start = EditModel.neutral
        start.color.point = PointColorSet(swatches: [PointColor()], active: 0)
        return Param(key: "color.point[0].\(field)", base: start) { m in
            guard var set = m.color.point, !set.swatches.isEmpty else { return }
            apply(&set.swatches[0])
            m.color.point = set
        }
    }

    private func maskField(_ field: String,
                           _ baseMask: Mask = Mask(id: maskID),
                           _ apply: @escaping (inout Mask) -> Void) -> Param {
        let id = Self.maskID
        return Param(key: "masks.\(id).\(field)", base: base(masks: [baseMask])) { m in
            m.masks = m.masks.map { mask in
                guard mask.id == id else { return mask }
                var copy = mask
                apply(&copy)
                return copy
            }
        }
    }

    /// One field **inside** `components[0]` (shape / op / invert / feather). The base always carries
    /// one component so the row is about that field and not about "a component appeared".
    private func componentField(_ field: String,
                                _ apply: @escaping (inout MaskComponent) -> Void) -> Param {
        let id = Self.maskID
        return Param(key: "masks.\(id).components[0].\(field)",
                     base: base(masks: [Mask(id: id, components: [MaskComponent()])])) { m in
            m.masks = m.masks.map { mask in
                guard mask.id == id, !mask.components.isEmpty else { return mask }
                var copy = mask
                apply(&copy.components[0])
                return copy
            }
        }
    }

    private func healField(_ field: String,
                           _ baseSpot: HealSpot = HealSpot(id: healID),
                           _ apply: @escaping (inout HealSpot) -> Void) -> Param {
        let id = Self.healID
        return Param(key: "heal.\(id).\(field)", base: base(heal: [baseSpot])) { m in
            m.healSpots = m.healSpots.map { spot in
                guard spot.id == id else { return spot }
                var copy = spot
                apply(&copy)
                return copy
            }
        }
    }

    // MARK: - every parameter the UI can move

    private var params: [Param] {
        var all: [Param] = [
            // The two document declarations (a turn / a preset can lift the schema; the decoder
            // picker is the process version's UI).
            flat("document.schemaVersion") {
                $0.schemaVersion = EditModel.currentSchemaVersion - 1
            },
            flat("document.processVersion") {
                $0.processVersion = EditModel.currentProcessVersion - 1
            },

            // S0 — geometry, all reachable from 裁切 / 旋转.
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

            // S1 / S2 — the Light card.
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

            // S3 — Color's two sliders, the ninth (全局) triplet and the B&W switch.
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

            // 029 — lateral CA, and 179 — the seven calibration numbers.
            flat("optics.caRed") { $0.optics.caRed = 0.002 },
            flat("optics.caBlue") { $0.optics.caBlue = -0.001 },
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

        // Masks — the seven mask-level fields, the thirteen local adjustments, one component's
        // geometry, and the three structural entries.
        all += [
            maskField("isEnabled") { $0.isEnabled = false },
            maskField("opacity") { $0.opacity = 0.5 },
            maskField("invert") { $0.invert = true },
            maskField("feather") { $0.feather = 0.2 },
            maskField("refine") { $0.refine = 0.5 },
            maskField("name") { $0.name = "Sky" },
            maskField("components") { $0.components = [MaskComponent()] },

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

            // 267 — the fields inside one component: blend arithmetic, inversion, edge softness and
            // geometry (the last changed through a canvas handle drag).
            componentField("op") { $0.op = .subtract },
            componentField("invert") { $0.invert = true },
            componentField("feather") { $0.feather = 0.2 },
            componentField("shape") {
                $0.shape = .linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1)))
            },

            Param(key: "masks.order",
                  base: base(masks: Self.orderMaskIDs.map { Mask(id: $0) })) {
                $0.masks = [Mask(id: Self.orderMaskIDs[1]), Mask(id: Self.orderMaskIDs[0])]
            },
        ]

        // Heal spots — the eight pre-229 fields, 229's kind and two red-gate numbers, plus the
        // structural entries.
        all += [
            healField("center.x") { $0.center.x = 0.4 },
            healField("center.y") { $0.center.y = 0.6 },
            healField("radius") { $0.radius = 0.03 },
            healField("source.x") { $0.sourceOffset.x = 0.1 },
            healField("source.y") { $0.sourceOffset.y = 0.02 },
            healField("feather") { $0.feather = 0.2 },
            healField("opacity") { $0.opacity = 0.8 },
            healField("mode") { $0.mode = .clone },
            healField("kind") { $0.kind = .redeye },
            // A red-eye base, because a `.heal` spot ignores the red gate by contract (`HealSpot.==`).
            healField("redThreshold", HealSpot(id: Self.healID, kind: .redeye, redThreshold: 0.4)) {
                $0.redThreshold = 0.7
            },
            healField("redSoftness", HealSpot(id: Self.healID, kind: .redeye, redSoftness: 0.1)) {
                $0.redSoftness = 0.2
            },

            Param(key: "heal.order",
                  base: base(heal: [HealSpot(id: Self.orderHealIDs[0], radius: 0.02),
                                    HealSpot(id: Self.orderHealIDs[1], radius: 0.05)])) {
                $0.healSpots = [HealSpot(id: Self.orderHealIDs[1], radius: 0.05),
                                HealSpot(id: Self.orderHealIDs[0], radius: 0.02)]
            },
        ]

        return all
    }

    // MARK: - the fields that are deliberately NOT edits

    /// `(key, reason)` — an exhaustive list, never a prefix/default rule. Each reason names the
    /// property that makes the field view state; each case then proves the diff ignores it.
    private var whitelist: [Whitelisted] {
        var start = EditModel.neutral
        start.color.point = PointColorSet(swatches: [PointColor()], active: 0)
        return [
            Whitelisted(key: "showMaskID",
                        reason: "005e 的视图状态：当前显示哪个蒙版的红色叠加，不动一个像素",
                        base: .neutral) { $0.showMaskID = "m-overlay" },
            Whitelisted(key: "color.point[].active",
                        reason: "140/158 的卡片选中项：只决定哪块色板被高亮，不动一个像素",
                        base: start) { $0.color.point?.active = 1 },
            Whitelisted(key: "forwardExtras",
                        reason: "205 的前向兼容透传：未知/更高版本字段原样保存，改它不动一个像素",
                        base: .neutral) { $0.forwardExtras = ["futureThing": .number(1)] },
            Whitelisted(key: "forwardCompatVersion",
                        reason: "205 的前向兼容版本标签：只用于提示「来自更新的版本」，不是渲染参数",
                        base: .neutral) { $0.forwardCompatVersion = 99 },
        ]
    }

    // MARK: - ① exactly one row per parameter

    func testEveryParameterProducesExactlyItsOwnRow() {
        var failures: [String] = []
        for p in params {
            var b = p.base
            p.apply(&b)
            let keys = EditHistory.changedFields(between: p.base, and: b).map(\.field.key)
            if keys != [p.key] {
                XCTFail("\(p.key) 应恰好产出一行，实际 \(keys)")
                failures.append(p.key)
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(params.count) 个参数的行数不是恰好一行：\(failures)")
        }
        print("267 DIFF · \(params.count) params · \(whitelist.count) whitelisted")
    }

    // MARK: - ② that row reverts

    func testEveryParameterRevertsToItsPreviousValue() {
        var failures: [String] = []
        for p in params {
            var b = p.base
            p.apply(&b)

            var history = EditHistory(baseline: p.base)
            guard history.commit(b, label: p.key, coalesce: false) != nil else {
                XCTFail("commit 没有产生一行：\(p.key)")
                failures.append(p.key)
                continue
            }
            guard let reverted = history.revert(at: 1) else {
                XCTFail("revert(at: 1) 返回 nil：\(p.key)")
                failures.append(p.key)
                continue
            }
            let residual = EditHistory.changedFields(between: reverted.edit, and: p.base)
                .map(\.field.key)
            if !residual.isEmpty {
                XCTFail("撤销 \(p.key) 后没有回到原值，残余 \(residual)")
                failures.append(p.key)
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count)/\(params.count) 个参数撤销不回去：\(failures)")
        }
        print("267 REVERT · \(params.count - failures.count)/\(params.count) params restored")
    }

    // MARK: - ③ the whitelist really is invisible to the diff

    func testWhitelistedFieldsProduceNoDiff() {
        for w in whitelist {
            var b = w.base
            w.apply(&b)
            let keys = EditHistory.changedFields(between: w.base, and: b).map(\.field.key)
            XCTAssertTrue(keys.isEmpty,
                          "\(w.key) 在白名单里（\(w.reason)），却产生了 diff：\(keys)")
        }
    }
}
