import XCTest
@testable import PhotonsPanorama

final class CameraBodyProfileTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("camera-bodies-\(UUID())") }
    private func body(id: UUID = UUID(), name: String = "我的机身") throws -> PanoramaCameraBody {
        .custom(try CameraBodyProfile(id: id, name: name, travel: .init(left: 10, right: 20, up: 30, down: 0)))
    }

    func testBuiltInsKeepLegacyEncodingAndCannotBeSavedOrDeleted() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraBodyStore(directory: root)
        let ids = ["alpa12Max", "alpa12XY", "alpa12STC", "alpa12Pano", "alpa12Plus"]
        for (body, id) in zip(PanoramaCameraBody.allCases, ids) {
            let legacy = Data("\"\(id)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(PanoramaCameraBody.self, from: legacy), body)
            XCTAssertEqual(try JSONEncoder().encode(body), legacy)
            XCTAssertThrowsError(try store.save(body))
            XCTAssertThrowsError(try store.delete(body))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(store.catalog().bodies, PanoramaCameraBody.allCases)
    }

    func testCreateRenameReloadAndDeletePreserveIDAndSavedSnapshots() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraBodyStore(directory: root), id = UUID()
        let original = try body(id: id)
        let url = try store.save(original)
        var lens = LCCProfileTests().sample(); lens.cameraBody = original
        let archivedLens = try LCCProfileCodec.encode(lens)
        let renamed = try body(id: id, name: " 改名后的机身 ")
        XCTAssertEqual(try store.save(renamed), url)
        let reopened = CameraBodyStore(directory: root).catalog()
        XCTAssertEqual(reopened.custom, [renamed]); XCTAssertTrue(reopened.issues.isEmpty)
        XCTAssertEqual(renamed.name, "改名后的机身")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        try store.delete(renamed)
        XCTAssertTrue(store.catalog().custom.isEmpty)
        let restored = try LCCProfileCodec.decode(archivedLens)
        XCTAssertEqual(restored.cameraBody, original)
        XCTAssertEqual(LCCProfileSummary(restored).cameraBody, original)
        XCTAssertEqual(restored.cameraBody?.travel(at: .degrees90), .init(left: 30, right: 0, up: 20, down: 10))
    }

    func testCustomTravelConstrainsPositionsAndRotatesLikeBuiltIns() throws {
        let body = try body()
        XCTAssertEqual(body.orientations.count, 4)
        XCTAssertTrue(body.defaultTravel.contains(CGPoint(x: -10, y: 30)))
        XCTAssertFalse(body.defaultTravel.contains(CGPoint(x: 0, y: -1)))
        XCTAssertEqual(body.travel(at: .degrees270), .init(left: 0, right: 30, up: 10, down: 20))
        let vertical = PanoramaCameraBody.custom(try CameraBodyProfile(name: "竖移", travel: .init(left: 0, right: 0, up: 18, down: 18)))
        XCTAssertEqual(vertical.orientations.count, 2)
        XCTAssertNil(vertical.defaultTravel.opticalOriginBounds(centers: [.zero, CGPoint(x: 5, y: 0)], tolerance: 0))
        XCTAssertNotNil(vertical.travel(at: .degrees90).opticalOriginBounds(centers: [.zero, CGPoint(x: 5, y: 0)], tolerance: 0))
        XCTAssertEqual(try JSONDecoder().decode(PanoramaCameraBody.self, from: JSONEncoder().encode(vertical)), vertical)
    }

    func testPanoramaManifestKeepsCustomBodyWithoutItsLibrary() throws {
        let snapshot = try body()
        let plan = PanoramaPlan(sources: [], origins: [], size: CGSize(width: 800, height: 600),
            registrationScores: [], whiteBalance: nil, gains: [], ownership: [], maskWidth: 0, maskHeight: 0,
            optical: .init(center: nil, confidence: 0, explanation: "", occludedEdges: []), options: .init(),
            previewScale: 1, previewImages: [], preview: nil)
        let manifest = PanoramaManifest(plan: plan, bodyOrientation: .degrees270, cameraBody: snapshot)
        let restored = try JSONDecoder().decode(PanoramaManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(restored.cameraBody, snapshot)
        XCTAssertEqual(restored.bodyOrientation, .degrees270)
        XCTAssertEqual(restored.cameraBody?.travel(at: restored.bodyOrientation), .init(left: 0, right: 30, up: 10, down: 20))
    }

    func testValidationDuplicateNamesAndCorruptFilesDoNotReplaceBuiltIns() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraBodyStore(directory: root)
        for value in [-1, Double.nan, Double.infinity, 151] {
            XCTAssertThrowsError(try CameraBodyProfile(name: "Invalid", travel: .init(left: value, right: 0, up: 0, down: 0)))
        }
        XCTAssertThrowsError(try body(name: " \n "))
        XCTAssertThrowsError(try body(name: String(repeating: "A", count: 201)))
        XCTAssertThrowsError(try store.save(body(name: "alpa 12 max")))
        let saved = try body(name: "My Camera")
        try store.save(saved)
        XCTAssertThrowsError(try store.save(body(name: "my camera")))
        try Data("\"alpa12Max\"".utf8).write(to: store.url(for: UUID()))
        try Data("not JSON".utf8).write(to: store.url(for: UUID()))
        let result = store.catalog()
        XCTAssertEqual(result.custom, [saved]); XCTAssertEqual(result.issues.count, 2)
        XCTAssertEqual(Array(result.bodies.prefix(5)), PanoramaCameraBody.allCases)
        XCTAssertThrowsError(try JSONDecoder().decode(PanoramaCameraBody.self, from: Data("{\"version\":2}".utf8)))
    }
}
