import XCTest
import CoreImage
@testable import PhotonsPanorama

final class LCCCrossBodyTests: XCTestCase {
    private func profile(shifts: [Double]) -> LCCLensProfile {
        var profile = LCCProfileTests().sample()
        let capture = profile.captures[0]
        profile.captures = shifts.map { shift in
            var copy = capture; copy.id = UUID(); copy.shiftX = shift
            return copy
        }
        profile.cameraBody = .alpa12XY
        return profile
    }

    func testCalibrationBodyDoesNotRestrictMatchingAcrossBuiltInAndCustomBodies() throws {
        let custom = PanoramaCameraBody.custom(try CameraBodyProfile(name: "Custom", travel: .init(left: 8, right: 12, up: 4, down: 0)))
        let bodies = PanoramaCameraBody.allCases + [custom]
        var calibration = profile(shifts: [-12, 0, 12])
        for recordedBody in bodies {
            calibration.cameraBody = recordedBody
            let summary = LCCProfileSummary(try LCCProfileCodec.decode(LCCProfileCodec.encode(calibration)))
            for activeBody in bodies {
                for angle in LCCCaptureOrientation.allCases {
                    let sensor = SensorSize(width: angle.isPortrait ? 24 : 36, height: angle.isPortrait ? 36 : 24, source: "test")
                    let placement = try XCTUnwrap(summary.placement(camera: "Test back/Electronic Shutter",
                        exifOrientation: angle.rawValue, sensor: sensor, cameraBody: activeBody, bodyOrientation: angle.rotation))
                    XCTAssertEqual(placement.variant.orientation, .landscape)
                    XCTAssertEqual(placement.bodyOrientation, angle.rotation)
                }
            }
            XCTAssertNil(summary.match(camera: "Other back", exifOrientation: 1, sensor: .init(width: 36, height: 24, source: "test")))
            XCTAssertNil(summary.match(camera: "Test back", exifOrientation: 1, sensor: .init(width: 54, height: 40, source: "test")))
        }
    }

    func testMultipleCalibrationsAndImportCopiesPreserveExistingReferencesAndMeasurements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root)
        let wide = profile(shifts: [-12, 0, 12])
        var narrow = profile(shifts: [0]); narrow.cameraBody = .alpa12STC
        try store.save(wide); try store.save(narrow)
        XCTAssertEqual(store.catalog().profiles.count, 2, "Same lens/back/name must not collapse separate calibrations")
        let originalBytes = try Data(contentsOf: store.url(for: wide.id))
        var revision = wide; revision.notes = "New measurements"; revision.captures = narrow.captures
        let copy = try store.importProfile(revision, keepingBoth: true)
        XCTAssertNotEqual(copy.id, wide.id); XCTAssertNotEqual(copy.name, wide.name)
        XCTAssertEqual(try Data(contentsOf: store.url(for: wide.id)), originalBytes)
        let loaded = try store.load(copy.id)
        XCTAssertEqual(loaded.captures, revision.captures); XCTAssertEqual(loaded.cameraBody, revision.cameraBody)
        XCTAssertEqual(loaded.notes, revision.notes)
        let secondCopy = try store.importProfile(revision, keepingBoth: true)
        XCTAssertNotEqual(secondCopy.name, copy.name); XCTAssertNotEqual(secondCopy.id, copy.id)
        XCTAssertEqual(store.catalog().profiles.count, 4)
        let replacement = try store.importProfile(revision, keepingBoth: false)
        XCTAssertEqual(replacement.id, wide.id); XCTAssertEqual(try store.load(wide.id), revision)
        XCTAssertEqual(try store.load(narrow.id), narrow)
    }

    func testCrossBodyCorrectionDependsOnMeasuredCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PanoramaEngine(), plan = try plan(root: root, engine: engine, separation: 16)
        let sensor = SensorSize(width: 36, height: 24, source: "test")
        var wide = profile(shifts: [-12, 0, 12]); wide.camera = plan.sources[0].camera
        var narrow = profile(shifts: [0]); narrow.camera = wide.camera
        let fields = try LCCCorrectionEngine.fields(wide)
        let sameBody = try engine.applyingLCC(plan, profile: wide, fields: fields, offsetMM: .zero,
            sensor: sensor, crop: false, cameraBody: .alpa12XY)
        let otherBody = try engine.applyingLCC(plan, profile: wide, fields: fields, offsetMM: .zero,
            sensor: sensor, crop: false, cameraBody: .alpa12STC)
        XCTAssertTrue(try XCTUnwrap(sameBody.lccState).complete)
        XCTAssertTrue(try XCTUnwrap(otherBody.lccState).complete)
        XCTAssertEqual(otherBody.lccState?.cameraBody, .alpa12STC, "Keep the active body for stitching, not the calibration body")
        let a = PanoramaRaster(image: sameBody.previewImages[0], context: engine.context, width: 40, height: 30)
        let b = PanoramaRaster(image: otherBody.previewImages[0], context: engine.context, width: 40, height: 30)
        XCTAssertEqual(a.rgba, b.rgba)
        let partial = try engine.applyingLCC(plan, profile: narrow, fields: LCCCorrectionEngine.fields(narrow),
            offsetMM: .zero, sensor: sensor, crop: false, cameraBody: .alpa12STC)
        XCTAssertFalse(try XCTUnwrap(partial.lccState).complete)
        XCTAssertLessThan(try XCTUnwrap(partial.lccState).coveredFraction, 1)
        XCTAssertNotNil(partial.lccState?.suggestedCropRect)
    }

    func testCopyOfLegacySampleKeepsCalibrationProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root)
        var legacy = profile(shifts: [0]); legacy.id = LCCLensProfile.builtInID; legacy.cameraBody = nil
        try store.save(legacy)
        let copy = try store.importProfile(legacy, keepingBoth: true)
        XCTAssertNotEqual(copy.id, legacy.id)
        XCTAssertEqual(copy.calibrationBody, .alpa12Max)
        XCTAssertEqual(try store.load(copy.id).cameraBody, .alpa12Max)
        XCTAssertEqual(try store.load(legacy.id), legacy)
    }

    func testLargeCalibrationDoesNotRelaxActiveBodyTravelLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PanoramaEngine(), plan = try plan(root: root, engine: engine, separation: 90)
        let calibration = profile(shifts: [-25, 0, 25]), fields = try LCCCorrectionEngine.fields(calibration)
        let sensor = SensorSize(width: 36, height: 24, source: "test")
        // Frame centers are 40.5 mm apart: XY can reach them, Max/STC cannot.
        for body in [PanoramaCameraBody.alpa12Max, .alpa12STC] {
            XCTAssertThrowsError(try LCCPositionSolver.solve(plan: plan, fields: fields, sensor: sensor,
                cameraBody: body, allowPairedFlats: false))
        }
        let solution = try LCCPositionSolver.solve(plan: plan, fields: fields, sensor: sensor,
            cameraBody: .alpa12XY, allowPairedFlats: false)
        let centers = [CGPoint(x: -20.25, y: 0), CGPoint(x: 20.25, y: 0)]
        let bounds = try XCTUnwrap(PanoramaCameraBody.alpa12XY.defaultTravel.opticalOriginBounds(centers: centers))
        XCTAssertTrue(bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(solution.offsetMM))
    }

    private func plan(root: URL, engine: PanoramaEngine, separation: Double) throws -> PanoramaPlan {
        let url = root.appendingPathComponent("scene.png"), bounds = CGRect(x: 0, y: 0, width: 80, height: 60)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1, colorSpace: PanoramaEngine.linearSpace)!).cropped(to: bounds)
        try engine.context.writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: PanoramaEngine.linearSpace)
        let source = try PanoramaSource(url: url)
        var options = PanoramaOptions(); options.matchExposure = false; options.avoidMotion = false
        var plan = PanoramaPlan(sources: [source, source], origins: [.zero, CGPoint(x: separation, y: 0)],
            size: CGSize(width: 80 + separation, height: 60), registrationScores: [1, 1], whiteBalance: nil,
            gains: [1, 1], ownership: [], maskWidth: 0, maskHeight: 0,
            optical: .init(center: nil, confidence: 0, explanation: "", occludedEdges: []), options: options,
            previewScale: 1, previewImages: [image, image], preview: nil)
        plan.lccLinearPreviewImages = [image, image]
        return plan
    }
}
