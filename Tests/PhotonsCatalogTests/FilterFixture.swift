import XCTest
import GRDB
@testable import PhotonsCatalog

/// The little library 026's dimension tests are written against.
///
/// Five rows, one per interesting shape, so a dimension's hit count is a fact about the data and not
/// about the SQL's luck:
///
/// | file | date | ext | ★ | flag | colour | camera | serial | flash | GPS |
/// |---|---|---|---|---|---|---|---|---|---|
/// | a.dng | 2026-10-02 | dng | 5 | pick | red | leica\|sl3 | 5954607 | 16 | 30.0036 / 120.56 |
/// | b.cr3 | 2026-10-02 | cr3 | 3 | – | – | canon\|eos r5 | 111 | 0 | 0 / 0 |
/// | c.jpg | 2025-03-12 | jpg | 0 | reject | blue | leica\|sl3 | 5954607 | – | – |
/// | d.dng | 2025-03-12 | dng | 1 | – | – | canon\|eos r5 | **no metadata row at all** |
/// | e.dng | 2025-07-01 | dng | 2 | pick | green | panasonic\|dc-s5 | 777 | 16 | 30.5 / 121.0 |
///
/// `d` is the LEFT JOIN's reason to exist: a photo imported before EXIF was read has no satellite
/// row, and every metadata dimension must answer "no" for it instead of dropping the row from an
/// unrelated query.
///
/// 快门速度 carries both spellings: `b` holds the Leica rational `55924/44739201`, `e` holds `1/800`,
/// and both must be **one** value in the popup and one criterion in the SQL.
struct FilterFixture {
    let tmp: URL
    let catalog: Catalog
    let root: SourceRoot

    static let leica = "leica|sl3"
    static let canon = "canon|eos r5"
    static let panasonic = "panasonic|dc-s5"
    static let lens85 = "85mm F1.2 DG | Art 026"
    static let lens50 = "50mm F1.8"
    static let lens24 = "24-70mm F2.8"
    /// The raw shutter `b` stores — a real exposure written as an improper rational.
    static let rationalShutter = "55924/44739201"

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-026-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        catalog = try Catalog.create(at: tmp.appendingPathComponent("f.photonslibrary", isDirectory: true))
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
        try seed()
    }

    func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    static func exif(serial: String? = nil, flash: Int? = nil,
                     latitude: Double? = nil, longitude: Double? = nil) -> String {
        var root: [String: Any] = ["TIFF": ["Make": "TEST"]]
        var exif: [String: Any] = [:]
        if let serial { exif["BodySerialNumber"] = serial }
        if let flash { exif["Flash"] = flash }
        if !exif.isEmpty { root["{Exif}"] = exif }
        if let latitude, let longitude { root["{GPS}"] = ["Latitude": latitude, "Longitude": longitude] }
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @discardableResult
    func insert(_ name: String,
                date: String?,
                ext: String,
                rating: Int = 0,
                flag: String? = nil,
                color: String? = nil,
                camera: (key: String, model: String)? = nil,
                lens: String? = nil,
                minute: Int = 0,
                iso: Int? = nil, focal: Double? = nil, shutter: String? = nil, aperture: Double? = nil,
                exif: String? = nil) throws -> String {
        let asset = Asset(sourceRootId: root.id,
                          relPath: name,
                          filename: name,
                          ext: ext,
                          kind: AssetKind.detect(ext) ?? .raw,
                          size: 1024,
                          mtime: 0,
                          contentHash: UUID().uuidString,
                          captureTime: date.map { "\($0)T00:\(String(format: "%02d", minute)):00Z" },
                          captureLocalDate: date,
                          rating: rating,
                          flag: flag,
                          colorLabel: color,
                          cameraMake: camera.map { String($0.key.split(separator: "|").first ?? "") },
                          cameraModel: camera?.model,
                          cameraKey: camera?.key,
                          lens: lens)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            if let exif {
                try AssetMetadata(assetId: asset.id, exifJson: exif,
                                  iso: iso, focalLength: focal, aperture: aperture,
                                  shutter: shutter).insert(db)
            }
        }
        return asset.id
    }

    private func seed() throws {
        try insert("a.dng", date: "2026-10-02", ext: "dng", rating: 5, flag: "pick", color: "red",
                   camera: (Self.leica, "LEICA SL3"), lens: Self.lens85,
                   minute: 4, iso: 100, focal: 85, shutter: "1/500", aperture: 1.2,
                   exif: Self.exif(serial: "5954607", flash: 16, latitude: 30.0036, longitude: 120.56))
        try insert("b.cr3", date: "2026-10-02", ext: "cr3", rating: 3,
                   camera: (Self.canon, "EOS R5"), lens: Self.lens50,
                   minute: 3, iso: 200, focal: 50, shutter: Self.rationalShutter, aperture: 2.8,
                   exif: Self.exif(serial: "111", flash: 0, latitude: 0, longitude: 0))
        try insert("c.jpg", date: "2025-03-12", ext: "jpg", rating: 0, flag: "reject", color: "blue",
                   camera: (Self.leica, "LEICA SL3"), lens: Self.lens85,
                   minute: 2, iso: 400, focal: 85, shutter: "1/6", aperture: 8,
                   exif: Self.exif(serial: "5954607"))
        // No `asset_metadata` row: the LEFT JOIN must not lose this photo from 星级/相机 queries.
        try insert("d.dng", date: "2025-03-12", ext: "dng", rating: 1,
                   camera: (Self.canon, "EOS R5"), lens: Self.lens50, minute: 1)
        try insert("e.dng", date: "2025-07-01", ext: "dng", rating: 2, flag: "pick", color: "green",
                   camera: (Self.panasonic, "DC-S5"), lens: Self.lens24,
                   minute: 0, iso: 160, focal: 24, shutter: "1/800", aperture: 5.6,
                   exif: Self.exif(serial: "777", flash: 16, latitude: 30.5, longitude: 121.0))
    }

    func names(_ filter: AssetFilter) throws -> Set<String> {
        Set(try catalog.assets(filter).map(\.filename))
    }

    func criterion(_ dimension: FilterDimension, _ values: String...) -> AssetFilter {
        AssetFilter(limit: 200_000, criteria: values.map { FilterCriterion(dimension: dimension, value: $0) })
    }
}
