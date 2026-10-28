import Foundation

// MARK: - 077: field-level history diff
//
// `HistoryDirty.swift` answers **"which panel needs recomputing"** with seven group bools (D10). That
// is the cache's question, and it is deliberately coarse: one bool per panel, never one per
// parameter.
//
// The history *panel* asks a different question — "which number did this step move, from what to
// what" — and a group bool cannot answer it ("Light changed" is not a history row a user can read).
// So this file adds a second, finer diff. The two never replace each other:
//
//   · group level → `changedStages` / cache keys (untouched by this file)
//   · field level → a history row's text, its delete rule, and its merge class
//
// The resolution is a **string identity**, not an enum case, because the interesting parameters are
// of dynamic length: `curve.white[3].y` and `masks.m-1.feather` cannot be spelled as enum cases.
// The same string is three things at once — display key, merge class (minus the trailing axis) and
// the identity `deletable(at:)` intersects — which is why there is exactly one spelling per field.

/// One parameter, identified by the path a document uses for it.
///
/// ```
///   light.exposure          curve.white[3].y        masks.m-1.feather
///   geometry.crop.width     color.bands[2].hue      document.processVersion
/// ```
public struct EditField: Hashable, Codable, Sendable {
    /// The path. Stable across processes and across a save/load round-trip: it is written into the
    /// history envelope and is what `deletable(at:)` compares.
    public let key: String
    /// The panel this field belongs to — the same `RenderGroup` the cache uses, so a row can be
    /// coloured/named by the group without a second table.
    public let group: RenderGroup

    public init(key: String, group: RenderGroup) {
        self.key = key
        self.group = group
    }

    /// A structural field: a count or an order, not a slider. Printed without a `+` sign
    /// (「点数 2 → 3」, not 「+2 → +3」).
    public var isStructural: Bool {
        key.hasSuffix(".count") || key == "masks.order" || key.hasSuffix(".components")
    }

    /// The human name, in the panel's own wording (「曝光」「对比」「白[3].y」).
    ///
    /// Derived from `key`, never stored: one spelling, one table (`EditHistory.parameterName`). A key
    /// this table does not know still reads as itself — a row must never print an empty name because
    /// somebody added a parameter and forgot the table.
    public var displayName: String { EditHistory.parameterName(for: key) }

    /// The **gesture class**: the field with its trailing axis dropped.
    ///
    /// `curve.white[3].x` and `curve.white[3].y` are one class, because dragging a curve point moves
    /// both at once and the user means "one drag" — two classes would put two rows in the timeline
    /// for one gesture. `light.exposure` is its own class, so exposure and contrast never merge.
    public var gestureClass: String {
        // 2026-10-28 (P0 色彩分级): **a wheel is one gesture.** `colorGrading.shadows.hue` and
        // `colorGrading.shadows.saturation` are one class, because the acceptance is 「每轮一行，拖动
        // 合并」: dragging a wheel's 色相 and then its 饱和 is still one look being dialled in, and two
        // rows would make ⌘Z take back half a gesture. The wheel's *name* is the class — a different
        // wheel (阴影 → 高光) is a different gesture and breaks the run, exactly as `exposure,
        // contrast, exposure` does.
        if key.hasPrefix("colorGrading.") {
            let parts = key.dropFirst("colorGrading.".count).split(separator: ".")
            return "colorGrading." + (parts.first.map(String.init) ?? "")
        }
        guard let close = key.lastIndex(of: "]"), key[key.startIndex..<close].contains("[") else {
            return key
        }
        return String(key[key.startIndex...close])
    }
}

/// A field's value, in the shape a history row prints.
public enum FieldValue: Equatable, Codable, Sendable {
    case number(Double)
    /// A value that can be absent, where absent is a *state* rather than a number — the white
    /// balance's `nil` = "follow the file" (派单 006). Never printed as `0`.
    case optionalNumber(Double?)
    case flag(Bool)
    case text(String)

    /// `0 → +1.2`, `开`, `原照`, `未定`. Two decimals at most, trailing zeros trimmed, `+` for
    /// positives (the panel's own sign convention), and **POSIX** formatting so a locale with `,`
    /// as the decimal separator cannot make a history row disagree with the slider.
    public var display: String { display(structural: false) }

    /// `structural` drops the sign: a count of points is not a deflection (see `EditField.isStructural`).
    public func display(structural: Bool) -> String {
        switch self {
        case .number(let v): return FieldValue.decimal(v, signed: !structural)
        case .optionalNumber(let v):
            return v.map { FieldValue.decimal($0, signed: !structural) } ?? "原照"
        case .flag(let v): return v ? "开" : "关"
        case .text(let v): return v.isEmpty ? "—" : v
        }
    }

    /// A number as the panel prints it: up to two decimals, trailing zeros trimmed, `+` on values of
    /// magnitude 1 and up (a slider at +1.2 reads `+1.2`; a mask feather of 0.1 does not need a sign
    /// in front of it).
    static func decimal(_ value: Double, signed: Bool = true) -> String {
        guard value.isFinite else { return String(format: "%.2f", locale: FieldValue.posix, value) }
        let rounded = (value * 100).rounded() / 100
        var text = String(format: "%.2f", locale: FieldValue.posix, rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        if signed, rounded >= 1, !text.hasPrefix("+") { text = "+" + text }
        return text
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
}

/// One parameter's move, as one history row shows it.
public struct FieldChange: Equatable, Codable, Sendable {
    public let field: EditField
    public let from: FieldValue
    public let to: FieldValue

    public init(field: EditField, from: FieldValue, to: FieldValue) {
        self.field = field
        self.from = from
        self.to = to
    }

    /// `曝光 0 → +1.2` — the row's text. One wording, shared by the panel, the CLI and the tests.
    public var summary: String {
        let structural = field.isStructural
        return "\(field.displayName) \(from.display(structural: structural)) → "
            + "\(to.display(structural: structural))"
    }
}

// MARK: - the diff

extension EditHistory {

    /// Every parameter that differs between two documents, in a **fixed** order.
    ///
    /// Fixed order matters twice: two rows can be compared literally (`Equatable`, "其余行逐字不变")
    /// and a merged row's re-computed diff cannot shuffle. The traversal mirrors `EditModel`'s own
    /// declaration order (geometry → light → curve → color → detail → detailSettings → decoder →
    /// effects → optics → masks), so reading the struct and reading the list agree.
    ///
    /// Tolerance is `dirtyTolerance` (1e-6), the *same* window the cache uses: the history must not
    /// claim a step the renderer would call a no-op, nor call a real change "nothing".
    public static func changedFields(between before: EditModel, and after: EditModel) -> [FieldChange] {
        var out: [FieldChange] = []
        func add(_ key: String, _ group: RenderGroup, _ from: FieldValue, _ to: FieldValue) {
            guard from != to else { return }
            out.append(FieldChange(field: EditField(key: key, group: group), from: from, to: to))
        }
        func num(_ key: String, _ group: RenderGroup, _ a: Double, _ b: Double) {
            guard !EditParameters.areEqual(a, b) else { return }
            add(key, group, .number(a), .number(b))
        }
        func opt(_ key: String, _ group: RenderGroup, _ a: Double?, _ b: Double?) {
            guard !EditParameters.areEqual(a, b) else { return }
            add(key, group, .optionalNumber(a), .optionalNumber(b))
        }
        func flag(_ key: String, _ group: RenderGroup, _ a: Bool, _ b: Bool) {
            guard a != b else { return }
            add(key, group, .flag(a), .flag(b))
        }

        // A version bump changes what every number *means*: one row, not fifty (D9).
        if before.schemaVersion != after.schemaVersion {
            add("document.schemaVersion", .light,
                .number(Double(before.schemaVersion)), .number(Double(after.schemaVersion)))
        }
        if before.processVersion != after.processVersion {
            add("document.processVersion", .light,
                .number(Double(before.processVersion)), .number(Double(after.processVersion)))
        }

        // S0 — geometry.
        num("geometry.crop.x", .geometry, before.geometry.crop.x, after.geometry.crop.x)
        num("geometry.crop.y", .geometry, before.geometry.crop.y, after.geometry.crop.y)
        num("geometry.crop.width", .geometry, before.geometry.crop.width, after.geometry.crop.width)
        num("geometry.crop.height", .geometry, before.geometry.crop.height, after.geometry.crop.height)
        num("geometry.rotationDegrees", .geometry,
            before.geometry.rotationDegrees, after.geometry.rotationDegrees)
        flag("geometry.flipHorizontal", .geometry,
             before.geometry.flipHorizontal, after.geometry.flipHorizontal)
        flag("geometry.flipVertical", .geometry,
             before.geometry.flipVertical, after.geometry.flipVertical)
        if before.geometry.aspectLock != after.geometry.aspectLock {
            add("geometry.aspectLock", .geometry,
                .text(before.geometry.aspectLock.code), .text(after.geometry.aspectLock.code))
        }

        // S1 / S2 — the Light panel.
        num("light.exposure", .light, before.light.exposure, after.light.exposure)
        num("light.contrast", .light, before.light.contrast, after.light.contrast)
        num("light.highlights", .light, before.light.highlights, after.light.highlights)
        num("light.shadows", .light, before.light.shadows, after.light.shadows)
        num("light.whites", .light, before.light.whites, after.light.whites)
        num("light.blacks", .light, before.light.blacks, after.light.blacks)
        opt("light.temperature", .light, before.light.temperature, after.light.temperature)
        opt("light.tint", .light, before.light.tint, after.light.tint)
        num("light.highlightRecovery", .light,
            before.light.highlightRecovery, after.light.highlightRecovery)
        opt("light.blackLevel", .light, before.light.blackLevel, after.light.blackLevel)
        opt("light.whiteLevel", .light, before.light.whiteLevel, after.light.whiteLevel)
        num("light.blackOffset", .light, before.light.blackOffset, after.light.blackOffset)

        // S1.7 — the curve. Structure first: a point added or removed is one row ("点数 2 → 3"),
        // not a coordinate that happens to land where the new point is.
        let curveLists: [(String, [CurvePoint], [CurvePoint])] = [
            ("white", before.curve.white, after.curve.white),
            ("red", before.curve.red, after.curve.red),
            ("green", before.curve.green, after.curve.green),
            ("blue", before.curve.blue, after.curve.blue),
        ]
        for (list, old, new) in curveLists {
            if old.count != new.count {
                add("curve.\(list).count", .curve,
                    .number(Double(old.count)), .number(Double(new.count)))
                continue
            }
            for i in old.indices {
                num("curve.\(list)[\(i)].x", .curve, old[i].x, new[i].x)
                num("curve.\(list)[\(i)].y", .curve, old[i].y, new[i].y)
            }
        }

        // S3 — Color.
        num("color.vibrance", .color, before.color.vibrance, after.color.vibrance)
        num("color.saturation", .color, before.color.saturation, after.color.saturation)
        let bandsBefore = ColorGroup.normalize(before.color.bands)
        let bandsAfter = ColorGroup.normalize(after.color.bands)
        for i in 0..<ColorGroup.bandCount {
            num("color.bands[\(i)].hue", .color, bandsBefore[i].hue, bandsAfter[i].hue)
            num("color.bands[\(i)].saturation", .color,
                bandsBefore[i].saturation, bandsAfter[i].saturation)
            num("color.bands[\(i)].luminance", .color,
                bandsBefore[i].luminance, bandsAfter[i].luminance)
            // 2026-10-28 (P0-4): 黑白混合 — the same eight bands, a fourth number per band. It sits
            // directly under the three it shares a row group with, so a history line reads the band's
            // four values in panel order.
            num("color.bands[\(i)].mix", .color, bandsBefore[i].mix, bandsAfter[i].mix)
        }
        // The 黑白 switch itself: a structural flag, so the row says 「黑白 关 → 开」 rather than a
        // number (`FieldValue.flag`, the same shape `light.lensCorrections` uses).
        flag("color.blackAndWhite", .color, before.color.blackAndWhite, after.color.blackAndWhite)

        // 2026-10-28 (P0 色彩分级) — S3.8's nine numbers, in panel order: 阴影 → 中间调 → 高光, and
        // 色相 → 饱和 → 亮度 inside each wheel. The order is the card's order, so a row that moved two
        // of them (a reset, a paste) reads the way the card reads.
        let gradeWheels: [(String, GradeWheel, GradeWheel)] = [
            ("shadows", before.colorGrading.shadows, after.colorGrading.shadows),
            ("midtones", before.colorGrading.midtones, after.colorGrading.midtones),
            ("highlights", before.colorGrading.highlights, after.colorGrading.highlights),
        ]
        for (name, old, new) in gradeWheels {
            num("colorGrading.\(name).hue", .colorGrading, old.hue, new.hue)
            num("colorGrading.\(name).saturation", .colorGrading, old.saturation, new.saturation)
            num("colorGrading.\(name).lightness", .colorGrading, old.lightness, new.lightness)
        }

        // Detail — stored (XMP) and decode-side amounts share the group, so they share the rows.
        num("detail.sharpening", .detail, before.detail.sharpening, after.detail.sharpening)
        num("detail.sharpeningRadius", .detail,
            before.detail.sharpeningRadius, after.detail.sharpeningRadius)
        num("detail.noiseLuminance", .detail,
            before.detail.noiseLuminance, after.detail.noiseLuminance)
        num("detail.noiseColor", .detail, before.detail.noiseColor, after.detail.noiseColor)
        flag("detail.lensCorrections", .detail,
             before.detail.lensCorrections, after.detail.lensCorrections)
        opt("detailSettings.luminanceNR", .detail,
            before.detailSettings.luminanceNR, after.detailSettings.luminanceNR)
        opt("detailSettings.colorNR", .detail,
            before.detailSettings.colorNR, after.detailSettings.colorNR)
        opt("detailSettings.sharpness", .detail,
            before.detailSettings.sharpness, after.detailSettings.sharpness)
        opt("detailSettings.detail", .detail,
            before.detailSettings.detail, after.detailSettings.detail)
        if before.decoderVersion != after.decoderVersion {
            add("decoderVersion", .detail,
                .text(before.decoderVersion ?? "默认"), .text(after.decoderVersion ?? "默认"))
        }

        // S3 — Effects.
        num("effects.vignetteAmount", .effects,
            before.effects.vignetteAmount, after.effects.vignetteAmount)
        num("effects.vignetteMidpoint", .effects,
            before.effects.vignetteMidpoint, after.effects.vignetteMidpoint)
        num("effects.vignetteFeather", .effects,
            before.effects.vignetteFeather, after.effects.vignetteFeather)
        num("effects.vignetteRoundness", .effects,
            before.effects.vignetteRoundness, after.effects.vignetteRoundness)
        num("effects.grain", .effects, before.effects.grain, after.effects.grain)
        // 2026-10-28 — S3.7's shape and seed. The seed is reported as the integer the kernel
        // hashes, so a row can never claim a change the pixels cannot see.
        num("effects.grainSize", .effects, before.effects.grainSize, after.effects.grainSize)
        num("effects.grainRoughness", .effects, before.effects.grainRoughness, after.effects.grainRoughness)
        if before.effects.grainSeedValue != after.effects.grainSeedValue {
            add("effects.grainSeed", .effects,
                .text("\(before.effects.grainSeedValue)"), .text("\(after.effects.grainSeedValue)"))
        }

        // S0 (029) — lateral CA.
        num("optics.caRed", .geometry, before.optics.caRed, after.optics.caRed)
        num("optics.caBlue", .geometry, before.optics.caBlue, after.optics.caBlue)

        // Masks — aligned by id. Array order is *combination* order (§3.3), so a reorder is an edit.
        out.append(contentsOf: maskChanges(before.masks, after.masks))

        // `showMaskID` is deliberately absent: it is view state (005e), never a document edit.
        return out
    }

    /// The masks half of the diff. Split out because it is the one dynamic, id-keyed part.
    ///
    /// Per-mask fields come first and the structural entries (`masks.order`, added/removed) last, so a
    /// row's two-line summary leads with what the user actually moved (「蒙版 羽化 0 → +0.35」) rather
    /// than with bookkeeping — the order is still fixed, which is what `Equatable` needs.
    static func maskChanges(_ before: [Mask], _ after: [Mask]) -> [FieldChange] {
        var out: [FieldChange] = []
        let beforeIDs = before.map(\.id)
        let afterIDs = after.map(\.id)
        var beforeByID: [String: Mask] = [:]
        for m in before { beforeByID[m.id] = m }
        for m in after {
            let id = m.id
            let key = { (field: String) in "masks.\(id).\(field)" }
            let isNew = beforeByID[id] == nil
            if isNew {
                out.append(FieldChange(field: EditField(key: key("added"), group: .masks),
                                       from: .text("无"), to: .text("有")))
            }
            // A brand-new mask is compared against `Mask.fallback` — the row then says what the mask
            // *is* (「羽化 0 → +0.35」) instead of only "a mask appeared", which is what the timeline
            // is for. A removed mask is reported below.
            let o = beforeByID[id] ?? Mask.fallback
            func num(_ field: String, _ a: Double, _ b: Double) {
                guard !EditParameters.areEqual(a, b) else { return }
                out.append(FieldChange(field: EditField(key: key(field), group: .masks),
                                       from: .number(a), to: .number(b)))
            }
            func flag(_ field: String, _ a: Bool, _ b: Bool) {
                guard a != b else { return }
                out.append(FieldChange(field: EditField(key: key(field), group: .masks),
                                       from: .flag(a), to: .flag(b)))
            }
            flag("isEnabled", o.isEnabled, m.isEnabled)
            num("opacity", o.opacity, m.opacity)
            flag("invert", o.invert, m.invert)
            num("feather", o.feather, m.feather)
            num("refine", o.refine, m.refine)
            if o.name != m.name {
                out.append(FieldChange(field: EditField(key: key("name"), group: .masks),
                                       from: .text(o.name), to: .text(m.name)))
            }
            if o.components.count != m.components.count {
                out.append(FieldChange(field: EditField(key: key("components"), group: .masks),
                                       from: .number(Double(o.components.count)),
                                       to: .number(Double(m.components.count))))
            }
            let adjBefore = o.adjustments
            let adjAfter = m.adjustments
            func adj(_ field: String, _ a: Double, _ b: Double) {
                guard !EditParameters.areEqual(a, b) else { return }
                out.append(FieldChange(field: EditField(key: key("adj.\(field)"), group: .masks),
                                       from: .number(a), to: .number(b)))
            }
            adj("amount", adjBefore.amount, adjAfter.amount)
            adj("exposure", adjBefore.exposure, adjAfter.exposure)
            adj("temperature", adjBefore.temperature, adjAfter.temperature)
            adj("tint", adjBefore.tint, adjAfter.tint)
            adj("contrast", adjBefore.contrast, adjAfter.contrast)
            adj("highlights", adjBefore.highlights, adjAfter.highlights)
            adj("shadows", adjBefore.shadows, adjAfter.shadows)
            adj("whites", adjBefore.whites, adjAfter.whites)
            adj("blacks", adjBefore.blacks, adjAfter.blacks)
            adj("hue", adjBefore.hue, adjAfter.hue)
            adj("saturation", adjBefore.saturation, adjAfter.saturation)
        }
        let afterIDsSet = Set(afterIDs)
        for o in before where !afterIDsSet.contains(o.id) {
            out.append(FieldChange(field: EditField(key: "masks.\(o.id).removed", group: .masks),
                                   from: .text("有"), to: .text("无")))
        }
        if beforeIDs != afterIDs {
            // A different set **or** a different order: the stack's own combination order (§3.3) moved.
            out.append(FieldChange(field: EditField(key: "masks.order", group: .masks),
                                   from: .number(Double(beforeIDs.count)),
                                   to: .number(Double(afterIDs.count))))
        }
        return out
    }

    // MARK: names

    /// Field key → the panel's wording. One table for the whole app; a key that is not in it reads as
    /// itself (never empty), and the structured keys (curve point, HSL band, mask field) are composed
    /// from their parts so a new index needs no table entry.
    public static func parameterName(for key: String) -> String {
        if let exact = parameterNames[key] { return exact }
        if let point = curvePointName(key) { return point }
        if let band = bandName(key) { return band }
        if let mask = maskFieldName(key) { return mask }
        return key
    }

    private static let parameterNames: [String: String] = [
        "document.schemaVersion": "文档版本",
        "document.processVersion": "处理版本",
        "geometry.crop.x": "裁切 x",
        "geometry.crop.y": "裁切 y",
        "geometry.crop.width": "裁切 宽",
        "geometry.crop.height": "裁切 高",
        "geometry.rotationDegrees": "角度",
        "geometry.flipHorizontal": "水平翻转",
        "geometry.flipVertical": "垂直翻转",
        "geometry.aspectLock": "比例",
        "light.exposure": "曝光",
        "light.contrast": "对比",
        "light.highlights": "高光",
        "light.shadows": "阴影",
        "light.whites": "白色",
        "light.blacks": "黑色",
        "light.temperature": "色温",
        "light.tint": "色调",
        "light.highlightRecovery": "高光恢复",
        "light.blackLevel": "黑电平",
        "light.whiteLevel": "白电平",
        "light.blackOffset": "黑电平微调",
        "color.vibrance": "自然饱和",
        "color.saturation": "饱和",
        "color.blackAndWhite": "黑白",
        "colorGrading.shadows.hue": "色彩分级[阴影] 色相",
        "colorGrading.shadows.saturation": "色彩分级[阴影] 饱和",
        "colorGrading.shadows.lightness": "色彩分级[阴影] 亮度",
        "colorGrading.midtones.hue": "色彩分级[中间调] 色相",
        "colorGrading.midtones.saturation": "色彩分级[中间调] 饱和",
        "colorGrading.midtones.lightness": "色彩分级[中间调] 亮度",
        "colorGrading.highlights.hue": "色彩分级[高光] 色相",
        "colorGrading.highlights.saturation": "色彩分级[高光] 饱和",
        "colorGrading.highlights.lightness": "色彩分级[高光] 亮度",
        "detail.sharpening": "锐化",
        "detail.sharpeningRadius": "锐化半径",
        "detail.noiseLuminance": "亮度降噪",
        "detail.noiseColor": "色彩降噪",
        "detail.lensCorrections": "镜头校正",
        "detailSettings.luminanceNR": "亮度降噪",
        "detailSettings.colorNR": "色彩降噪",
        "detailSettings.sharpness": "锐度",
        "detailSettings.detail": "细节",
        "decoderVersion": "解码版本",
        "effects.vignetteAmount": "暗角",
        "effects.vignetteMidpoint": "暗角中点",
        "effects.vignetteFeather": "暗角羽化",
        "effects.vignetteRoundness": "暗角圆度",
        "effects.grain": "颗粒数量",
        "effects.grainSize": "颗粒大小",
        "effects.grainRoughness": "颗粒粗糙度",
        "effects.grainSeed": "颗粒种子",
        "optics.caRed": "横向色差 R",
        "optics.caBlue": "横向色差 B",
        "masks.order": "蒙版顺序",
    ]

    private static let maskFieldNames: [String: String] = [
        "isEnabled": "启用", "opacity": "不透明度", "invert": "反相", "feather": "羽化",
        "refine": "细化", "name": "名称", "components": "形状", "added": "新增", "removed": "删除",
        "adj.amount": "强度", "adj.exposure": "曝光", "adj.temperature": "色温", "adj.tint": "色调",
        "adj.contrast": "对比", "adj.highlights": "高光", "adj.shadows": "阴影",
        "adj.whites": "白色", "adj.blacks": "黑色", "adj.hue": "色相", "adj.saturation": "饱和",
    ]

    /// `curve.white[3].y` → 「白[3].y」.
    private static func curvePointName(_ key: String) -> String? {
        guard key.hasPrefix("curve.") else { return nil }
        let parts = key.dropFirst("curve.".count).split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let head = String(parts[0])                       // "white[3]" or "white.count"
        guard let bracket = head.firstIndex(of: "[") else {
            return head == "white" || head == "red" || head == "green" || head == "blue"
                ? "曲线 \(curveListName(head)) 点数" : nil
        }
        let list = String(head[head.startIndex..<bracket])
        let index = String(head[head.index(after: bracket)...].dropLast())   // "3"
        let axis = parts[1]                              // "x" / "y"
        return "曲线 \(curveListName(list))[\(index)].\(axis)"
    }

    private static func curveListName(_ list: String) -> String {
        switch list {
        case "white": return "白"
        case "red": return "红"
        case "green": return "绿"
        case "blue": return "蓝"
        default: return list
        }
    }

    /// `color.bands[2].hue` → 「HSL[2] 色相」; `color.bands[0].mix` → 「黑白混合[红]」.
    ///
    /// 黑白混合 (2026-10-28, S3.4) is named **the other way round** on purpose: the HSL axes are one
    /// of three numbers on a band the user picked in a selector, so an index is the honest handle
    /// (「HSL[2] 色相」); a 黑白混合 row is its own row on its own card, one per hue, so the hue's
    /// *name* is — 「黑白混合[红] 0 → +50」 names the control the user double-clicked.
    private static func bandName(_ key: String) -> String? {
        let prefix = "color.bands["
        guard key.hasPrefix(prefix), let close = key.lastIndex(of: "]") else { return nil }
        let index = key[key.index(key.startIndex, offsetBy: prefix.count)..<close]
        let axis = key[key.index(after: close)...].dropFirst()   // after "]."
        let name: String
        switch axis {
        case "hue": name = "色相"
        case "saturation": name = "饱和"
        case "luminance": name = "明度"
        case "mix":
            let i = Int(index).map { min(max($0, 0), HSLBands.bandNames.count - 1) } ?? 0
            return "黑白混合[\(HSLBands.bandNames[i])]"
        default: name = String(axis)
        }
        return "HSL[\(index)] \(name)"
    }

    /// `masks.m-1.feather` → 「蒙版 羽化」.
    private static func maskFieldName(_ key: String) -> String? {
        guard key.hasPrefix("masks.") else { return nil }
        let rest = key.dropFirst("masks.".count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let field = String(rest[rest.index(after: dot)...])
        let name = maskFieldNames[field] ?? field
        return "蒙版 \(name)"
    }
}

// MARK: - 077: one row of the history panel

/// One line of the timeline, as the panel draws it: `序号 · 标签（具体参数 + 旧→新）· 时间`, plus the
/// two questions the panel asks of every row.
///
/// A value, built from the stack — the panel holds no copy of anything and cannot invent a row. The
/// three flags are computed from `EditHistory`'s own predicates (`isCurrent` from `cursor`,
/// `isNewestOfClass` / `canDelete` from the one delete rule), so a row cannot claim to be deletable
/// when the model would refuse.
public struct HistoryRow: Identifiable, Hashable, Sendable {
    /// Index in `EditHistory.snapshots` — what `delete(at:)` and `jump(to:)` are addressed by.
    public var index: Int
    /// Stable identity across a save/load round-trip.
    public var seq: Int
    /// The action's name (「裁切」/「曝光」/「Light」), as committed.
    public var label: String
    /// The field-level text: `曝光 0 → +1.2`, up to two changes then `+N`.
    public var summary: String
    /// The changed field keys, for tests and for the CLI.
    public var fields: [String]
    /// How many parameters this row moved (the summary may abbreviate them).
    public var changedCount: Int
    public var createdAt: Date
    /// The row the document is currently showing.
    public var isCurrent: Bool
    /// 「最新的该类操作」 — every field it moved is still the newest statement about that field.
    public var isNewestOfClass: Bool
    /// Whether the panel may offer 删除. Identical to `isNewestOfClass` by construction.
    public var canDelete: Bool

    public var id: Int { seq }

    /// `14:32` — local time, no locale, no formatter object (a row list can be 1000 long).
    public var timeText: String { HistoryRow.timeText(createdAt) }

    public static func timeText(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    /// The summary line, abbreviated when a row moved many parameters.
    static func summarize(_ changes: [FieldChange]) -> String {
        guard !changes.isEmpty else { return "原始状态" }
        let shown = changes.prefix(2).map(\.summary)
        let rest = changes.count - shown.count
        return rest > 0 ? shown.joined(separator: "、") + " +\(rest)" : shown.joined(separator: "、")
    }
}

extension EditHistory {
    /// The timeline, oldest first, exactly what the panel draws.
    ///
    /// One reverse pass: a row is 「最新」 when none of its fields has been claimed by a later row —
    /// the same predicate `isNewestOfClass(at:)` answers, computed once for the whole list instead of
    /// once per row (a 1000-row stack is 1000 views, not 1 000 000 set operations on every refresh).
    public var rows: [HistoryRow] {
        var claimed = Set<String>()
        var newest = [Bool](repeating: false, count: snapshots.count)
        for i in snapshots.indices.reversed() {
            let fields = snapshots[i].changes.map(\.field.key)
            if i > 0, !fields.isEmpty, fields.allSatisfy({ !claimed.contains($0) }) {
                newest[i] = true
            }
            claimed.formUnion(fields)
        }
        return snapshots.indices.map { i in
            let snap = snapshots[i]
            return HistoryRow(index: i,
                              seq: snap.seq,
                              label: snap.label,
                              summary: HistoryRow.summarize(snap.changes),
                              fields: snap.changes.map(\.field.key),
                              changedCount: snap.changes.count,
                              createdAt: snap.createdAt,
                              isCurrent: i == cursor,
                              isNewestOfClass: newest[i],
                              canDelete: newest[i])
        }
    }
}
