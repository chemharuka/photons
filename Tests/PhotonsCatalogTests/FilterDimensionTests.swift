import XCTest
@testable import PhotonsCatalog

/// 026 — one test per dimension, each asserting the **exact hit set** on `FilterFixture`.
///
/// The point of one case per dimension is that a wrong expression in one clause cannot hide behind a
/// broad filter that happens to return something: 焦距 `85` must be `{a,c}` and nothing else, 快门
/// `1/800` must be `{b,e}` though the two rows store *different raw strings*, and 闪光灯 `0` must
/// include the rows with **no EXIF at all** (a camera that never wrote `{Exif}.Flash` did not fire).
///
/// Same-dimension values are OR (`rating IN (1,2,5)`), different dimensions are AND — 026 v2 §4.
final class FilterDimensionTests: XCTestCase {

    private var fx: FilterFixture!

    override func setUpWithError() throws { fx = try FilterFixture() }
    override func tearDownWithError() throws { fx.tearDown(); fx = nil }

    private func assertHits(_ dimension: FilterDimension, _ value: String, _ expected: Set<String>,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try fx.names(fx.criterion(dimension, value)), expected,
                       "\(dimension.rawValue) = \(value)", file: file, line: line)
    }

    // MARK: ① one case per dimension

    func testMonth() throws {
        try assertHits(.month, "10", ["a.dng", "b.cr3"])
        try assertHits(.month, "03", ["c.jpg", "d.dng"])
        try assertHits(.month, "07", ["e.dng"])
        try assertHits(.month, "11", [])
    }

    func testDay() throws {
        try assertHits(.day, "02", ["a.dng", "b.cr3"])
        try assertHits(.day, "12", ["c.jpg", "d.dng"])
        try assertHits(.day, "01", ["e.dng"])
        XCTAssertTrue(try fx.names(fx.criterion(.day, "31")).isEmpty, "a day nobody shot is empty, not an error")
    }

    func testFileExtension() throws {
        try assertHits(.ext, "dng", ["a.dng", "d.dng", "e.dng"])
        try assertHits(.ext, "cr3", ["b.cr3"])
        try assertHits(.ext, "jpg", ["c.jpg"])
        try assertHits(.ext, "DNG", ["a.dng", "d.dng", "e.dng"])   // case-insensitive, the popup lowercases
    }

    /// 星级 is a **tier**, not `>= N` (026 v2 §5): 3★ is not in `1★·2★·5★`.
    func testRatingIsExactTierNotThreshold() throws {
        try assertHits(.rating, "5", ["a.dng"])
        try assertHits(.rating, "3", ["b.cr3"])
        try assertHits(.rating, "0", ["c.jpg"])
        try assertHits(.rating, "1", ["d.dng"])
        try assertHits(.rating, "2", ["e.dng"])
        try assertHits(.rating, "4", [])
        // …which is what makes multi-select OR rather than an intersection of two equalities.
        XCTAssertEqual(try fx.names(fx.criterion(.rating, "1", "2", "5")), ["a.dng", "d.dng", "e.dng"])
    }

    func testFlag() throws {
        try assertHits(.flag, "pick", ["a.dng", "e.dng"])
        try assertHits(.flag, "reject", ["c.jpg"])
        try assertHits(.flag, FilterValue.none, ["b.cr3", "d.dng"])
    }

    func testColorLabel() throws {
        try assertHits(.color, "red", ["a.dng"])
        try assertHits(.color, "blue", ["c.jpg"])
        try assertHits(.color, "green", ["e.dng"])
        try assertHits(.color, FilterValue.none, ["b.cr3", "d.dng"])
        try assertHits(.color, "purple", [])
    }

    func testCamera() throws {
        try assertHits(.camera, FilterFixture.leica, ["a.dng", "c.jpg"])
        try assertHits(.camera, FilterFixture.canon, ["b.cr3", "d.dng"])
        try assertHits(.camera, FilterFixture.panasonic, ["e.dng"])
        try assertHits(.camera, "nikon|z8", [])
    }

    /// The EXIF key the spec calls out: nested `{Exif}` → `BodySerialNumber`, path
    /// `$.{Exif}.BodySerialNumber` (the `."{Exif}.BodySerialNumber"` spelling looks for one root key
    /// containing a dot and finds nothing — see `FilterSQL.serialPaths`).
    func testSerialNumberReadsTheNestedExifKey() throws {
        try assertHits(.serial, "5954607", ["a.dng", "c.jpg"])
        try assertHits(.serial, "111", ["b.cr3"])
        try assertHits(.serial, "777", ["e.dng"])
        try assertHits(.serial, "00000", [])
    }

    func testSerialNumberFallsBackToExifAux() throws {
        let id = try fx.insert("aux.dng", date: "2024-01-05", ext: "dng",
                               exif: #"{"{ExifAux}":{"SerialNumber":"AUX-42"},"TIFF":{"Make":"TEST"}}"#)
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(try fx.names(fx.criterion(.serial, "AUX-42")), ["aux.dng"])
    }

    func testLens() throws {
        try assertHits(.lens, FilterFixture.lens85, ["a.dng", "c.jpg"])
        try assertHits(.lens, FilterFixture.lens50, ["b.cr3", "d.dng"])
        try assertHits(.lens, FilterFixture.lens24, ["e.dng"])
        // The alias's `|` and spaces are data, not SQL: a lens called `85mm F1.2 DG | Art 026` has to
        // survive every binding, and quotes in a lens name must not become syntax.
        try assertHits(.lens, "85mm F1.2 DG ' OR 1=1 --", [])
    }

    func testFocalLengthIsRounded() throws {
        try assertHits(.focal, "85", ["a.dng", "c.jpg"])
        // d.dng has no `asset_metadata` row at all: 50 mm is a fact this library cannot state about it.
        try assertHits(.focal, "50", ["b.cr3"])
        try assertHits(.focal, "24", ["e.dng"])
        try assertHits(.focal, "200", [])
    }

    /// Two rows, two raw spellings, one shutter — the value the popup prints is the normalised one.
    func testShutterMatchesEveryRawSpellingOfTheSameSpeed() throws {
        try assertHits(.shutter, "1/800", ["b.cr3", "e.dng"])
        try assertHits(.shutter, "1/500", ["a.dng"])
        try assertHits(.shutter, "1/6", ["c.jpg"])
        try assertHits(.shutter, "1/4000", [])
    }

    func testAperture() throws {
        try assertHits(.aperture, "1.2", ["a.dng"])
        try assertHits(.aperture, "2.8", ["b.cr3"])
        try assertHits(.aperture, "8.0", ["c.jpg"])
        try assertHits(.aperture, "5.6", ["e.dng"])
        try assertHits(.aperture, "16.0", [])
    }

    func testISO() throws {
        try assertHits(.iso, "100", ["a.dng"])
        try assertHits(.iso, "200", ["b.cr3"])
        try assertHits(.iso, "400", ["c.jpg"])
        try assertHits(.iso, "160", ["e.dng"])
        try assertHits(.iso, "3200", [])
    }

    /// `0` did not fire, anything else did — and a row with **no EXIF** did not fire either.
    func testFlash() throws {
        try assertHits(.flash, FilterValue.yes, ["a.dng", "e.dng"])
        try assertHits(.flash, FilterValue.no, ["b.cr3", "c.jpg", "d.dng"])
    }

    /// 有 = both coordinates exist **and are not 0/0** (the owner's rule); so `b`'s zeroed GPS block is
    /// 无, exactly like `c`'s missing block.
    func testGPS() throws {
        try assertHits(.gps, FilterValue.yes, ["a.dng", "e.dng"])
        try assertHits(.gps, FilterValue.no, ["b.cr3", "c.jpg", "d.dng"])
    }

    // MARK: ② dimensions AND, ③ same dimension ORs, empty results survive

    func testTwoDimensionsAreAnded() throws {
        let both = AssetFilter(limit: 200_000, criteria: [
            FilterCriterion(dimension: .month, value: "10"),
            FilterCriterion(dimension: .camera, value: FilterFixture.leica),
        ])
        XCTAssertEqual(try fx.names(both), ["a.dng"])

        let contradiction = AssetFilter(limit: 200_000, criteria: [
            FilterCriterion(dimension: .camera, value: FilterFixture.leica),
            FilterCriterion(dimension: .ext, value: "cr3"),
        ])
        XCTAssertTrue(try fx.names(contradiction).isEmpty, "an impossible AND is an empty grid, not a crash")
    }

    func testValuesOfOneDimensionAreOredAndStillAndedWithOtherSlots() throws {
        let or = AssetFilter(limit: 200_000, criteria: [
            FilterCriterion(dimension: .rating, value: "1"),
            FilterCriterion(dimension: .rating, value: "2"),
            FilterCriterion(dimension: .rating, value: "5"),
            FilterCriterion(dimension: .flag, value: "pick"),
        ])
        XCTAssertEqual(try fx.names(or), ["a.dng", "e.dng"], "1★/2★/5★ OR, then AND 留用")
    }

    /// ③ values that cannot all hold still return a result set (empty), no throw.
    func testImpossibleValuesReturnEmptyInsteadOfThrowing() throws {
        XCTAssertTrue(try fx.names(fx.criterion(.rating, "4", "6")).isEmpty,
                      "no photo is 4★ or 6★ — an empty grid, not a crash")
        XCTAssertTrue(try fx.names(fx.criterion(.serial, "nope")).isEmpty)
        XCTAssertEqual(try fx.names(fx.criterion(.focal, "85", "200")), ["a.dng", "c.jpg"])
    }

    /// The legacy fields keep their old meaning and AND with the new criteria — CLI/presets/tests that
    /// only know `ratingAtLeast` must not change behaviour.
    func testLegacyFieldsStillApplyAndAndWithCriteria() throws {
        XCTAssertEqual(try fx.names(AssetFilter(ratingAtLeast: 3, limit: 200_000)),
                       ["b.cr3", "a.dng"], ">= 3 is still a threshold, unlike a 星级 slot")
        XCTAssertEqual(try fx.names(AssetFilter(ratingAtLeast: 3, limit: 200_000,
                                                criteria: [FilterCriterion(dimension: .flag, value: "pick")])),
                       ["a.dng"])
        XCTAssertEqual(try fx.names(AssetFilter(cameraKey: FilterFixture.canon, limit: 200_000)), ["b.cr3", "d.dng"])
        XCTAssertEqual(try fx.names(AssetFilter(limit: 200_000, flagEquals: "reject")), ["c.jpg"])
        XCTAssertEqual(try fx.names(AssetFilter(limit: 200_000, colorLabelEquals: "green")), ["e.dng"])
    }

    /// Soft-deleted rows stay out of every criteria query, exactly like the plain one.
    func testCriteriaRespectDeletedFlag() throws {
        let victim = try XCTUnwrap(try fx.catalog.assets(AssetFilter(limit: 200_000))
            .first { $0.filename == "a.dng" })
        try fx.catalog.setDeleted(true, forAsset: victim.id)
        XCTAssertTrue(try fx.names(fx.criterion(.serial, "5954607")) == ["c.jpg"])
        XCTAssertEqual(try fx.names(AssetFilter(includeDeleted: true, limit: 200_000,
                                                criteria: [FilterCriterion(dimension: .serial, value: "5954607")])),
                       ["a.dng", "c.jpg"])
    }
}
