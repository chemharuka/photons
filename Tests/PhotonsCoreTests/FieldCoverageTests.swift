import XCTest
@testable import PhotonsCore

/// Every group that decides dirtiness by hand must compare **every** field it stores.
///
/// The bug this exists for: `EditParameters.areEqual(EffectsGroup)` was a hand-written `&&` chain
/// that omitted `texture` / `clarity` / `dehaze`, so `CatalogSession.applyEdit` returned on
/// `isSemanticallyIdentical` and the three sliders wrote nothing at all — the drag snapped back to 0
/// and typing a number had no effect. Nothing failed: there was no test that could notice a field
/// that was never mentioned.
///
/// Now the comparisons live in a named `FieldTable`, and this test reflects over the struct's stored
/// properties and demands that the two agree in both directions. A forgotten field is a red test;
/// a name that no longer exists is also a red test (so a rename cannot drift either).
final class FieldCoverageTests: XCTestCase {

    /// The groups whose comparison is hand-written (a synthesised `Equatable` needs no guard).
    ///
    /// `Mask` and `HealSpot` are deliberately absent: they are compared by their canonical
    /// key strings (`selectionKey` / `applyKey` / `keyString`), which is the resolution the renderer
    /// and the cache use — `MaskKeyTests` and `HealKeyTests` hold that, not a field list.
    private func tables() -> [(name: String, stored: Set<String>, named: [String])] {
        [
            ("GeometryGroup", stored(GeometryGroup()), EditParameters.geometryFields.names),
            ("LightGroup", stored(LightGroup()), EditParameters.lightFields.names),
            ("CurveGroup", stored(CurveGroup()), EditParameters.curveFields.names),
            ("ColorGroup", stored(ColorGroup()), EditParameters.colorFields.names),
            ("ColorGradingGroup", stored(ColorGradingGroup()), EditParameters.colorGradingFields.names),
            ("DetailGroup", stored(DetailGroup()), EditParameters.detailFields.names),
            ("DetailSettings", stored(DetailSettings()), EditParameters.detailSettingsFields.names),
            ("EffectsGroup", stored(EffectsGroup()), EditParameters.effectsFields.names),
            ("OpticsGroup", stored(OpticsGroup()), EditParameters.opticsFields.names),
        ]
    }

    /// The struct's own stored properties, straight from the runtime.
    private func stored<T>(_ value: T) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    /// Fields that are stored but deliberately **not** compared, each with the reason. They are
    /// subtracted from the "must be compared" demand and still have to exist in the struct, so an
    /// exemption cannot outlive the field it excuses.
    private let exemptions: [String: Set<String>] = [
        // Decode-time diagnostics (the `/tmp` notes a decoder leaves on a document). Nothing a slider
        // can write, nothing the renderer reads.
        "CurveGroup": ["decodeWarnings"],
    ]

    func testEveryStoredFieldIsCompared() {
        for (group, storedFields, namedFields) in tables() {
            let exempt = exemptions[group] ?? []
            XCTAssertTrue(exempt.isSubset(of: storedFields),
                          "\(group) 的豁免名单里有不存在的字段：\(exempt.subtracting(storedFields).sorted())")
            let missing = storedFields.subtracting(namedFields).subtracting(exempt)
            XCTAssertTrue(missing.isEmpty,
                          "\(group) 存了这些字段但比较表里没有：\(missing.sorted()) —— "
                          + "漏一个就是一根写不进文档的滑杆")
        }
    }

    func testTheTableNamesNothingTheGroupDoesNotHave() {
        for (group, storedFields, namedFields) in tables() {
            let extra = Set(namedFields).subtracting(storedFields)
            XCTAssertTrue(extra.isEmpty,
                          "\(group) 的比较表里有不存在的字段：\(extra.sorted())"
                          + "（改了名却没改表，比较的是空气）")
        }
    }

    func testNoFieldIsListedTwice() {
        for (group, _, namedFields) in tables() {
            XCTAssertEqual(Set(namedFields).count, namedFields.count,
                           "\(group) 的比较表里有重复字段")
        }
    }

    /// The three that were missing, held by name so a future refactor cannot quietly drop them.
    func testTheDetailFXFieldsAreInTheTable() {
        let names = Set(EditParameters.effectsFields.names)
        XCTAssertTrue(names.isSuperset(of: ["texture", "clarity", "dehaze"]))
        // …and they actually decide the answer, not just appear in a list.
        var a = EffectsGroup()
        var b = a
        b.texture = 10
        XCTAssertFalse(EditParameters.areEqual(a, b), "纹理 变了必须算脏")
        a.texture = 10
        XCTAssertTrue(EditParameters.areEqual(a, b))
        b.clarity = -35
        XCTAssertFalse(EditParameters.areEqual(a, b), "清晰度 变了必须算脏")
        b.clarity = 0
        b.dehaze = -100
        XCTAssertFalse(EditParameters.areEqual(a, b), "去雾 变了必须算脏")
    }
}
