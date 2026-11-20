import XCTest
import Foundation
@testable import PhotonsCore

/// 442 — 复制设置带默认值，粘贴把对应 key 写回默认。
///
/// The audit table is executable here: `leaves()` lists every copyable leaf exactly once (102 rows,
/// the same number as `EditSnapshot.fullDocumentFieldCount`), with a writer and a reader. The two
/// table-driven tests then ask each row the two questions the ticket is about:
///
///   · source at default / destination off-default → paste restores the default;
///   · source off-default → paste lands the source's value.
///
/// `testAuditTableMatchesCapture` guards the table against capture drifting apart: the number of
/// rows, the number of fields a full capture stores, and the per-patch leaf counts must agree.
private func probe442(_ n: Int) -> Double { Double(n) * 7.25 + 0.125 }

final class CopyDefaults442Tests: XCTestCase {

    // MARK: - the executable audit table

    private struct LeafCase {
        let key: String
        let set: (inout EditModel, Int) -> Void
        let read: (EditModel) -> String
    }

    /// 102 rows. Groups, in `fullDocumentFieldCount` order:
    /// geometry 14, light 10, curve 4, color 38, 色彩分级 9, detail 5, 校正 2, 校准 7, effects 13.
    private func leaves() -> [LeafCase] {
        var out: [LeafCase] = []
        func add(_ key: String,
                 _ set: @escaping (inout EditModel, Int) -> Void,
                 _ read: @escaping (EditModel) -> String) {
            out.append(LeafCase(key: key, set: set, read: read))
        }
        func addDouble(_ key: String,
                       _ set: @escaping (inout EditModel, Double) -> Void,
                       _ read: @escaping (EditModel) -> Double) {
            add(key, { m, n in set(&m, probe442(n)) }, { "\(read($0))" })
        }

        // geometry — 14
        addDouble("geometry.crop.x", { $0.geometry.crop.x = $1 }, { $0.geometry.crop.x })
        addDouble("geometry.crop.y", { $0.geometry.crop.y = $1 }, { $0.geometry.crop.y })
        addDouble("geometry.crop.width", { $0.geometry.crop.width = $1 }, { $0.geometry.crop.width })
        addDouble("geometry.crop.height", { $0.geometry.crop.height = $1 }, { $0.geometry.crop.height })
        add("geometry.quarterTurns", { m, n in m.geometry.quarterTurns = n }, {
            "\($0.geometry.quarterTurns)"
        })
        addDouble("geometry.rotationDegrees", { $0.geometry.rotationDegrees = $1 }, {
            $0.geometry.rotationDegrees
        })
        add("geometry.flipHorizontal", { m, _ in m.geometry.flipHorizontal = true }, {
            "\($0.geometry.flipHorizontal)"
        })
        add("geometry.flipVertical", { m, _ in m.geometry.flipVertical = true }, {
            "\($0.geometry.flipVertical)"
        })
        addDouble("geometry.perspectiveVertical", { $0.geometry.perspectiveVertical = $1 }, {
            $0.geometry.perspectiveVertical
        })
        addDouble("geometry.perspectiveHorizontal", { $0.geometry.perspectiveHorizontal = $1 }, {
            $0.geometry.perspectiveHorizontal
        })
        addDouble("geometry.perspectiveShear", { $0.geometry.perspectiveShear = $1 }, {
            $0.geometry.perspectiveShear
        })
        addDouble("geometry.perspectiveAspect", { $0.geometry.perspectiveAspect = $1 }, {
            $0.geometry.perspectiveAspect
        })
        add("geometry.aspectLock", { m, _ in m.geometry.aspectLock = .threeTwo }, {
            "\($0.geometry.aspectLock)"
        })
        add("geometry.cropSpace", { m, _ in m.geometry.cropSpace = .canvas }, {
            "\($0.geometry.cropSpace)"
        })

        // light — 10 (高光恢复 excluded: 325 removed its child row, so it is not copyable)
        addDouble("light.exposure", { $0.light.exposure = $1 }, { $0.light.exposure })
        addDouble("light.contrast", { $0.light.contrast = $1 }, { $0.light.contrast })
        addDouble("light.highlights", { $0.light.highlights = $1 }, { $0.light.highlights })
        addDouble("light.midtones", { $0.light.midtones = $1 }, { $0.light.midtones })
        addDouble("light.shadows", { $0.light.shadows = $1 }, { $0.light.shadows })
        addDouble("light.whites", { $0.light.whites = $1 }, { $0.light.whites })
        addDouble("light.blacks", { $0.light.blacks = $1 }, { $0.light.blacks })
        add("light.temperature", { m, n in m.light.temperature = 3000 + Double(n) * 100 }, {
            "\(String(describing: $0.light.temperature))"
        })
        add("light.tint", { m, n in m.light.tint = Double(n) * 3 }, {
            "\(String(describing: $0.light.tint))"
        })
        addDouble("light.blackOffset", { $0.light.blackOffset = $1 / 10000 }, {
            $0.light.blackOffset
        })

        // curve — 4
        let curve: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1.3), CurvePoint(2, 2)]
        func curveText(_ points: [CurvePoint]) -> String {
            points.map { "\($0.x):\($0.y)" }.joined(separator: ",")
        }
        add("curve.white", { m, _ in m.curve.white = curve }, { curveText($0.curve.white) })
        add("curve.red", { m, _ in m.curve.red = curve }, { curveText($0.curve.red) })
        add("curve.green", { m, _ in m.curve.green = curve }, { curveText($0.curve.green) })
        add("curve.blue", { m, _ in m.curve.blue = curve }, { curveText($0.curve.blue) })

        // color — 38
        addDouble("color.vibrance", { $0.color.vibrance = $1 }, { $0.color.vibrance })
        addDouble("color.saturation", { $0.color.saturation = $1 }, { $0.color.saturation })
        add("color.blackAndWhite", { m, _ in m.color.blackAndWhite = true }, {
            "\($0.color.blackAndWhite)"
        })
        for i in 0..<ColorGroup.bandCount {
            let read: (EditModel) -> String = { m in
                let b = m.color.bands[i]
                return "\(b.hue),\(b.saturation),\(b.luminance),\(b.mix)"
            }
            add("color.bands[\(i)].hue", { m, n in m.color.bands[i].hue = probe442(n) }, read)
            add("color.bands[\(i)].saturation", { m, n in m.color.bands[i].saturation = probe442(n) }, read)
            add("color.bands[\(i)].luminance", { m, n in m.color.bands[i].luminance = probe442(n) }, read)
            add("color.bands[\(i)].mix", { m, n in m.color.bands[i].mix = probe442(n) }, read)
        }
        add("color.global.hue", { m, n in m.color.global.hue = probe442(n) }, {
            "\($0.color.global.hue)"
        })
        add("color.global.saturation", { m, n in m.color.global.saturation = probe442(n) }, {
            "\($0.color.global.saturation)"
        })
        add("color.global.luminance", { m, n in m.color.global.luminance = probe442(n) }, {
            "\($0.color.global.luminance)"
        })

        // 色彩分级 — 9
        add("colorGrading.shadows.hue", { m, n in m.colorGrading.shadows.hue = probe442(n) }, {
            "\($0.colorGrading.shadows.hue)"
        })
        add("colorGrading.shadows.saturation", { m, n in
            m.colorGrading.shadows.saturation = probe442(n)
        }, { "\($0.colorGrading.shadows.saturation)" })
        add("colorGrading.shadows.lightness", { m, n in
            m.colorGrading.shadows.lightness = probe442(n)
        }, { "\($0.colorGrading.shadows.lightness)" })
        add("colorGrading.midtones.hue", { m, n in m.colorGrading.midtones.hue = probe442(n) }, {
            "\($0.colorGrading.midtones.hue)"
        })
        add("colorGrading.midtones.saturation", { m, n in
            m.colorGrading.midtones.saturation = probe442(n)
        }, { "\($0.colorGrading.midtones.saturation)" })
        add("colorGrading.midtones.lightness", { m, n in
            m.colorGrading.midtones.lightness = probe442(n)
        }, { "\($0.colorGrading.midtones.lightness)" })
        add("colorGrading.highlights.hue", { m, n in m.colorGrading.highlights.hue = probe442(n) }, {
            "\($0.colorGrading.highlights.hue)"
        })
        add("colorGrading.highlights.saturation", { m, n in
            m.colorGrading.highlights.saturation = probe442(n)
        }, { "\($0.colorGrading.highlights.saturation)" })
        add("colorGrading.highlights.lightness", { m, n in
            m.colorGrading.highlights.lightness = probe442(n)
        }, { "\($0.colorGrading.highlights.lightness)" })

        // detail — 5
        addDouble("detail.sharpening", { $0.detail.sharpening = $1 }, { $0.detail.sharpening })
        addDouble("detail.sharpeningRadius", { $0.detail.sharpeningRadius = $1 }, {
            $0.detail.sharpeningRadius
        })
        addDouble("detail.noiseLuminance", { $0.detail.noiseLuminance = $1 }, {
            $0.detail.noiseLuminance
        })
        addDouble("detail.noiseColor", { $0.detail.noiseColor = $1 }, { $0.detail.noiseColor })
        add("detail.lensCorrections", { m, _ in m.detail.lensCorrections = true }, {
            "\($0.detail.lensCorrections)"
        })

        // 校正 — 2
        addDouble("optics.caRed", { $0.optics.caRed = $1 / 10000 }, { $0.optics.caRed })
        addDouble("optics.caBlue", { $0.optics.caBlue = $1 / 10000 }, { $0.optics.caBlue })

        // 校准 — 7
        addDouble("calibration.shadowTint", { $0.calibration.shadowTint = $1 }, {
            $0.calibration.shadowTint
        })
        addDouble("calibration.redHue", { $0.calibration.redHue = $1 }, { $0.calibration.redHue })
        addDouble("calibration.redSat", { $0.calibration.redSat = $1 }, { $0.calibration.redSat })
        addDouble("calibration.greenHue", { $0.calibration.greenHue = $1 }, {
            $0.calibration.greenHue
        })
        addDouble("calibration.greenSat", { $0.calibration.greenSat = $1 }, {
            $0.calibration.greenSat
        })
        addDouble("calibration.blueHue", { $0.calibration.blueHue = $1 }, { $0.calibration.blueHue })
        addDouble("calibration.blueSat", { $0.calibration.blueSat = $1 }, { $0.calibration.blueSat })

        // effects — 13
        addDouble("effects.vignetteAmount", { $0.effects.vignetteAmount = $1 }, {
            $0.effects.vignetteAmount
        })
        addDouble("effects.vignetteMidpoint", { $0.effects.vignetteMidpoint = $1 }, {
            $0.effects.vignetteMidpoint
        })
        addDouble("effects.vignetteFeather", { $0.effects.vignetteFeather = $1 }, {
            $0.effects.vignetteFeather
        })
        addDouble("effects.grain", { $0.effects.grain = $1 }, { $0.effects.grain })
        addDouble("effects.texture", { $0.effects.texture = $1 }, { $0.effects.texture })
        addDouble("effects.clarity", { $0.effects.clarity = $1 }, { $0.effects.clarity })
        addDouble("effects.nonBayerLuminanceNR", { $0.effects.nonBayerLuminanceNR = $1 }, {
            $0.effects.nonBayerLuminanceNR
        })
        addDouble("effects.nonBayerColorNR", { $0.effects.nonBayerColorNR = $1 }, {
            $0.effects.nonBayerColorNR
        })
        addDouble("effects.dehaze", { $0.effects.dehaze = $1 }, { $0.effects.dehaze })
        addDouble("effects.sharpenAmount", { $0.sharpen.amount = $1 }, { $0.sharpen.amount })
        addDouble("effects.sharpenRadius", { $0.sharpen.radius = $1 }, { $0.sharpen.radius })
        addDouble("effects.sharpenDetail", { $0.sharpen.detail = $1 }, { $0.sharpen.detail })
        addDouble("effects.sharpenMasking", { $0.sharpen.masking = $1 }, { $0.sharpen.masking })

        return out
    }

    // MARK: - the audit-table guard

    func testAuditTableMatchesCapture() {
        let rows = leaves()
        let snapshot = EditSnapshot.capture(.neutral)
        print("442 audit table: \(rows.count) leaves; capture \(snapshot.fieldCount) fields;"
              + " denominator \(EditSnapshot.fullDocumentFieldCount)")
        XCTAssertEqual(rows.count, EditSnapshot.fullDocumentFieldCount)
        XCTAssertEqual(snapshot.fieldCount, rows.count, "capture stores exactly the audited leaves")
        XCTAssertEqual(snapshot.geometry?.fieldCount, GeometryPatch.fullFieldCount)
        XCTAssertEqual(snapshot.light?.fieldCount, LightPatch.fullFieldCount)
        XCTAssertEqual(snapshot.curve?.fieldCount, CurvePatch.fullFieldCount)
        XCTAssertEqual(snapshot.color?.fieldCount, ColorPatch.fullFieldCount)
        XCTAssertEqual(snapshot.colorGrading?.fieldCount, ColorGradingPatch.fullFieldCount)
        XCTAssertEqual(snapshot.detail?.fieldCount, DetailPatch.fullFieldCount)
        XCTAssertEqual(snapshot.optics?.fieldCount, OpticsPatch.fullFieldCount)
        XCTAssertEqual(snapshot.calibration?.fieldCount, CalibrationPatch.fullFieldCount)
        XCTAssertEqual(snapshot.effects?.fieldCount, EffectsPatch.fullFieldCount)
        XCTAssertTrue(snapshot.isEmpty == false)
    }

    // MARK: - A② every leaf, both directions

    func testEveryLeafResetsADestinationThatDiffered() {
        for leaf in leaves() {
            var target = EditModel.neutral
            leaf.set(&target, 3)
            let defaultText = leaf.read(.neutral)
            XCTAssertNotEqual(leaf.read(target), defaultText,
                              "\(leaf.key): the probe must move the leaf before the assertion")
            let merged = EditSnapshot.capture(.neutral).applied(to: target)
            XCTAssertEqual(leaf.read(merged), defaultText,
                           "\(leaf.key): 源默认 ⇒ 粘贴回默认")
        }
    }

    func testEveryLeafCopiesANonDefaultSource() {
        for leaf in leaves() {
            var source = EditModel.neutral
            leaf.set(&source, 4)
            let sourceText = leaf.read(source)
            XCTAssertNotEqual(sourceText, leaf.read(.neutral), "\(leaf.key): probe is off-default")
            let merged = EditSnapshot.capture(source).applied(to: .neutral)
            XCTAssertEqual(leaf.read(merged), sourceText,
                           "\(leaf.key): 源非默认 ⇒ 粘贴等于源值")
        }
    }

    // MARK: - A① the user's headline case

    func testLightDefaultsClearTheDestinationKeysFromTheBlob() throws {
        var target = EditModel.neutral
        target.light.exposure = 1.5
        target.light.contrast = -20
        target.light.highlights = 30
        target.light.midtones = -10
        target.light.shadows = 22
        target.light.whites = 9
        target.light.blacks = -7

        let merged = EditSnapshot.capture(.neutral).applied(to: target)
        XCTAssertEqual(merged.light, .identity, "源全默认 ⇒ 目标的 7 条明暗全部回到默认")
        // The document's own serializer writes the LightGroup's seven numbers even at 0 (only some
        // groups are conditional), so the observable fact here is the value, not a missing key;
        // the clipboard payload is where "default = value 0" is spelled. REPORT.md records this
        // deviation from §0.2's assumption.
        let data = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(decoded.light, .identity)
        for key in ["exposure", "contrast", "highlights", "midtones", "shadows", "whites", "blacks"] {
            let value = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["light"]
                    as? [String: Any]
            )[key] as? Double
            XCTAssertEqual(value, 0, "\(key) 落盘为 0（默认值）")
        }

        // Reverse: a non-default source writes the value through.
        var source = EditModel.neutral
        source.light.exposure = 1.5
        source.light.contrast = -20
        let forward = EditSnapshot.capture(source).applied(to: .neutral)
        XCTAssertEqual(forward.light.exposure, 1.5)
        XCTAssertEqual(forward.light.contrast, -20)
        let forwardText = String(decoding: try JSONEncoder().encode(forward), as: UTF8.self)
        XCTAssertTrue(forwardText.contains("\"exposure\""))
        XCTAssertTrue(forwardText.contains("\"contrast\""))
    }

    // MARK: - A③ nil-is-the-default leaves

    func testDecoderVersionAutoRoundTripsAndRequiresADevelopment() throws {
        let automatic = EditSnapshot.capture(.neutral)
        XCTAssertEqual(automatic.decoderVersionAuto, true)
        XCTAssertNil(automatic.decoderVersion)
        XCTAssertTrue(automatic.requiresDecode)

        var pinned = EditModel.neutral
        pinned.decoderVersion = "9.dng"
        let backToAuto = automatic.applied(to: pinned)
        XCTAssertNil(backToAuto.decoderVersion)
        let autoText = String(decoding: try JSONEncoder().encode(backToAuto), as: UTF8.self)
        XCTAssertFalse(autoText.contains("decoderVersion"), "自动 = key 不存在：\(autoText)")

        var source = EditModel.neutral
        source.decoderVersion = "9.dng"
        let payload = EditSnapshot.capture(source)
        XCTAssertEqual(payload.decoderVersionAuto, false)
        XCTAssertEqual(payload.decoderVersion, "9.dng")
        XCTAssertTrue(payload.requiresDecode)
        XCTAssertEqual(payload.applied(to: .neutral).decoderVersion, "9.dng")
    }

    // MARK: - A⑥ filtering still keeps the rest out

    func testNarrowingToOneChildWritesOnlyThatChild() {
        var source = EditModel.neutral
        source.light.exposure = 1.2
        source.light.contrast = 15
        source.color.saturation = 30
        source.optics.caRed = 0.002
        source.effects.texture = 40

        let exposureOnly = EditSnapshot.capture(source)
            .filtered(to: [.light], children: [.exposure])
        XCTAssertEqual(exposureOnly.sections, [.light])
        XCTAssertEqual(exposureOnly.fieldCount, 1)
        XCTAssertEqual(exposureOnly.light?.exposure, 1.2)
        XCTAssertNil(exposureOnly.light?.contrast)
        XCTAssertNil(exposureOnly.color)
        XCTAssertNil(exposureOnly.optics)
        XCTAssertNil(exposureOnly.effects)
        XCTAssertNil(exposureOnly.geometry)

        let caOnly = EditSnapshot.capture(source)
            .filtered(to: [.correction], children: [.caRed])
        XCTAssertEqual(caOnly.sections, [.correction])
        XCTAssertEqual(caOnly.fieldCount, 1)
        XCTAssertEqual(caOnly.optics?.caRed, 0.002)
        XCTAssertNil(caOnly.optics?.caBlue)
        XCTAssertNil(caOnly.light)

        let textureOnly = EditSnapshot.capture(source)
            .filtered(to: [.detailFX], children: [.texture])
        XCTAssertEqual(textureOnly.sections, [.detailFX])
        XCTAssertEqual(textureOnly.fieldCount, 1)
        XCTAssertEqual(textureOnly.effects?.texture, 40)
        XCTAssertNil(textureOnly.effects?.clarity)
        XCTAssertNil(textureOnly.light)
    }

    // MARK: - A④ presets still apply the same way

    func testPresetsKeepTheirApplicationSemantics() throws {
        var source = EditModel.neutral
        source.light.exposure = 0.8
        source.light.contrast = 12
        source.light.temperature = 5600
        source.light.tint = 8
        source.color.saturation = 20
        source.effects.vignetteAmount = -25
        source.calibration.shadowTint = 10
        source.calibration.redHue = 30

        var target = EditModel.neutral
        target.light.exposure = -1
        target.light.temperature = 4800
        target.color.saturation = -10
        target.effects.vignetteAmount = 20
        target.calibration.redHue = -60

        // Three whole-group presets replace exactly their group.
        let lightPreset = Preset(name: "light", from: source, groups: [.light])
        let colorPreset = Preset(name: "color", from: source, groups: [.color])
        let effectsPreset = Preset(name: "effects", from: source, groups: [.effects])
        var expected = target
        expected.light = source.light
        XCTAssertEqual(lightPreset.apply(to: target).light, expected.light)
        expected = target
        expected.color = source.color
        XCTAssertEqual(colorPreset.apply(to: target).color, expected.color)
        expected = target
        expected.effects = source.effects
        XCTAssertEqual(effectsPreset.apply(to: target).effects, expected.effects)

        // Two card-scoped presets still merge field by field, not "write the whole card's defaults".
        let wbPreset = Preset(name: "wb", fromSections: [.whiteBalance], of: source)
        let wbApplied = wbPreset.apply(to: target)
        XCTAssertEqual(wbApplied.light.temperature, 5600)
        XCTAssertEqual(wbApplied.light.tint, 8)
        XCTAssertEqual(wbApplied.light.exposure, target.light.exposure,
                       "白平衡-only 预设不许清掉目标的曝光")

        let calPreset = Preset(name: "cal", fromSections: [.calibration], of: source)
        let calApplied = calPreset.apply(to: target)
        XCTAssertEqual(calApplied.calibration.shadowTint, 10)
        XCTAssertEqual(calApplied.calibration.redHue, 30)
        XCTAssertEqual(calApplied.calibration.blueSat, target.calibration.blueSat)

        // The bytes may grow (capture now fills every leaf) but the fragment is still an EditModel,
        // which omits defaults; print the sizes for the report.
        for preset in [lightPreset, colorPreset, effectsPreset, wbPreset, calPreset] {
            let data = try JSONEncoder().encode(preset)
            print("442 preset \(preset.name): \(data.count) bytes")
        }
    }
}
