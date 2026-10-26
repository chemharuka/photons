import XCTest
@testable import PhotonsCatalog

/// 026 — `facetValues`: the popup must offer **what the library holds**, in an order a photographer
/// can read.
///
/// The hard constraint from the owner (2026-10-26): 「相机 序列号 镜头 焦距 快门速度 光圈 ISO 这几个必须
/// 从已有的数值中提供；如果所有照片都没焦距，就只能选『全部』」. An empty answer is therefore a
/// *correct* answer, and an invented `100 / 200 / 400` ISO ladder in a library with no EXIF is the
/// bug this file exists to prevent.
final class FacetValuesTests: XCTestCase {

    private var fx: FilterFixture!

    override func setUpWithError() throws { fx = try FilterFixture() }
    override func tearDownWithError() throws { fx.tearDown(); fx = nil }

    private func values(_ dimension: FilterDimension, filter: AssetFilter = AssetFilter()) -> [String] {
        fx.catalog.facetValues(dimension, filter: filter)
    }

    // MARK: ④ an empty library offers nothing for the data-driven dimensions

    func testEmptyLibraryOffersOnlyWhatTheClosedVocabulariesCanOffer() throws {
        let empty = try Catalog.create(at: fx.tmp.appendingPathComponent("empty.photonslibrary",
                                                                        isDirectory: true))
        let dataDriven: [FilterDimension] = [.camera, .serial, .lens, .focal, .shutter, .aperture, .iso,
                                             .month, .day, .ext, .flash, .gps]
        for dimension in dataDriven {
            XCTAssertEqual(empty.facetValues(dimension), [],
                           "\(dimension.rawValue): 空库只能选「全部」")
        }
        // 星级/旗标/色标 are a closed language, not a fact about the library — full list even when empty.
        XCTAssertEqual(empty.facetValues(.rating), ["5", "4", "3", "2", "1", "0"])
        XCTAssertEqual(empty.facetValues(.flag), ["pick", "reject", FilterValue.none])
        XCTAssertEqual(empty.facetValues(.color),
                       ["red", "orange", "yellow", "green", "blue", "purple", FilterValue.none])
    }

    /// 序列号/闪光灯/GPS with rows but no EXIF at all: still empty, and the SQL must not throw.
    func testDimensionsWithNoExifAnswerEmptyRatherThanAFakeLadder() throws {
        let bare = try Catalog.create(at: fx.tmp.appendingPathComponent("bare.photonslibrary",
                                                                       isDirectory: true))
        let shoot = fx.tmp.appendingPathComponent("shoot", isDirectory: true)
        let root = try bare.ensureRoot(for: shoot, mode: .reference)
        let asset = Asset(sourceRootId: root.id, relPath: "bare.dng", filename: "bare.dng",
                          ext: "dng", kind: .raw, size: 1, mtime: 0,
                          contentHash: "bare", captureLocalDate: "2026-01-01")
        try bare.dbQueue.write { db in
            try asset.insert(db)
            try AssetMetadata(assetId: asset.id).insert(db)        // an `{}` blob: no EXIF at all
        }
        for dimension in [FilterDimension.serial, .focal, .shutter, .aperture, .iso, .flash, .gps] {
            XCTAssertEqual(bare.facetValues(dimension), [], dimension.rawValue)
        }
        XCTAssertEqual(bare.facetValues(.ext), ["dng"], "月/日/后缀 still list what exists")
        XCTAssertEqual(bare.facetValues(.month), ["01"])
    }

    // MARK: the real library's lists

    func testDataDrivenDimensionsListOnlyExistingValuesInNumericOrder() {
        XCTAssertEqual(values(.iso), ["100", "160", "200", "400"])
        XCTAssertEqual(values(.focal), ["24", "50", "85"], "focal is a number, not a string")
        XCTAssertEqual(values(.aperture), ["1.2", "2.8", "5.6", "8.0"])
    }

    /// 快门速度: deduped **after** normalisation, ordered by real duration — the Leica rational and the
    /// plain `1/800` are one entry.
    func testShutterIsNormalisedDedupedAndOrderedByDuration() {
        XCTAssertEqual(values(.shutter), ["1/800", "1/500", "1/6"])
    }

    func testTextualDimensionsUseLocalisedDictionaryOrder() {
        XCTAssertEqual(values(.camera), [FilterFixture.canon, FilterFixture.leica, FilterFixture.panasonic])
        XCTAssertEqual(values(.lens), [FilterFixture.lens24, FilterFixture.lens50, FilterFixture.lens85])
        // `localizedStandardCompare` is numeric-aware, so a serial reads 111 → 777 → 5954607 instead of
        // "111" → "5954607" → "777" (which is what plain UTF-16 order does to digits).
        XCTAssertEqual(values(.serial), ["111", "777", "5954607"])
        XCTAssertEqual(values(.ext), ["cr3", "dng", "jpg"])
        XCTAssertEqual(values(.month), ["03", "07", "10"])
        XCTAssertEqual(values(.day), ["01", "02", "12"])
    }

    func testRatingDescendsAndFlagColourKeepTheirVocabularyOrder() {
        // Not "what exists": the tier list is the vocabulary, so 4★ is offered though nobody used it.
        XCTAssertEqual(values(.rating), ["5", "4", "3", "2", "1", "0"])
        XCTAssertEqual(values(.flag), ["pick", "reject", FilterValue.none])
        XCTAssertEqual(values(.color),
                       ["red", "orange", "yellow", "green", "blue", "purple", FilterValue.none])
    }

    /// 有 before 无 — and only values that can actually happen: a library where every photo fired the
    /// flash offers 有 alone.
    func testPresenceDimensionsOfferYesBeforeNo() {
        XCTAssertEqual(values(.flash), [FilterValue.yes, FilterValue.no])
        XCTAssertEqual(values(.gps), [FilterValue.yes, FilterValue.no])

        // c.jpg has no flash key and b.cr3 fired 0 — after deleting a and e nothing said 有.
        let fired = try? fx.catalog.assets(AssetFilter(limit: 200_000))
        for asset in fired ?? [] where asset.filename == "a.dng" || asset.filename == "e.dng" {
            try? fx.catalog.setDeleted(true, forAsset: asset.id)
        }
        XCTAssertEqual(values(.flash), [FilterValue.no])
    }

    // MARK: scoping — a facet answers "what else is there"

    func testFacetIgnoresItsOwnDimensionButHonoursTheOthers() {
        // A camera is already picked: its own popup must still list every camera, or the user could
        // never switch to another one…
        let leica = AssetFilter(cameraKey: FilterFixture.leica, limit: 200_000)
        XCTAssertEqual(values(.camera, filter: leica),
                       [FilterFixture.canon, FilterFixture.leica, FilterFixture.panasonic])

        // …while a different dimension narrows to what is inside that camera's photos.
        XCTAssertEqual(values(.iso, filter: leica), ["100", "400"])
        XCTAssertEqual(values(.lens, filter: leica), [FilterFixture.lens85])
        XCTAssertEqual(values(.ext, filter: leica), ["dng", "jpg"])
    }

    func testFacetHonoursSlotCriteriaOnOtherDimensions() {
        let hidden = AssetFilter(limit: 200_000, criteria: [FilterCriterion(dimension: .ext, value: "cr3")])
        XCTAssertEqual(values(.iso, filter: hidden), ["200"])
        XCTAssertEqual(values(.camera, filter: hidden), [FilterFixture.canon])
    }

    /// A photo with no `asset_metadata` row contributes nothing to metadata facets — the LEFT JOIN
    /// must not turn `NULL` into a `""` choice.
    func testRowsWithoutMetadataDoNotInventValues() {
        XCTAssertFalse(values(.iso).contains(""), "no blank ISO entry for d.dng")
        XCTAssertFalse(values(.shutter).contains(""))
        XCTAssertEqual(values(.iso).count, 4)
    }
}
