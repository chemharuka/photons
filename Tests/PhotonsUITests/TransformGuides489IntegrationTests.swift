import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 489 §2.1 — the view-state half on a real editor: the frame is not hit-tested while 引导线 is armed,
/// and it comes back with the lines at 50 % when the switch is turned off.
@MainActor
final class TransformGuides489IntegrationTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-xform489-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testArmedGuideLinesHideTheFrameAndReleaseItsHits() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session))
        CropUITestSupport.pump(0.05)

        let overlay = try XCTUnwrap(loupe.cropOverlayViewForAudit as? CropToolOverlayView)
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let corner = try XCTUnwrap(layout.grips.first { $0.kind == .topLeft }).point

        XCTAssertFalse(overlay.guideLinesArmed)
        XCTAssertEqual(overlay.appliedGuideLineAlpha, 0.5, accuracy: 0.01)
        XCTAssertEqual(loupe.cropHit(atViewPoint: corner), .topLeft)

        loupe.cropTool.setGuideLinesArmed(true)
        CropUITestSupport.pump(0.05)
        XCTAssertTrue(overlay.guideLinesArmed, "引导线激活时裁切框必须不画")
        XCTAssertEqual(overlay.appliedGuideLineAlpha, 1, accuracy: 0.01)
        XCTAssertNil(loupe.cropHit(atViewPoint: corner), "引导线激活时裁切框不接收命中")

        loupe.cropTool.setGuideLinesArmed(false)
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(overlay.guideLinesArmed)
        XCTAssertEqual(overlay.appliedGuideLineAlpha, 0.5, accuracy: 0.01)
        XCTAssertEqual(loupe.cropHit(atViewPoint: corner), .topLeft)
    }
}

// MARK: - 489 §2.3: 自动裁剪 writes once, and only when there is a rotation to cure

extension TransformGuides489IntegrationTests {

    func testAutoCropIsANoOpOnALevelPictureAndOneUndoableWriteAtThirtyDegrees() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let tool = loupe.cropTool
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session))
        CropUITestSupport.pump(0.05)

        let levelHistory = editor.session.history.snapshots.count
        let levelCrop = editor.session.edit.geometry.crop
        // 505 — 自动裁剪 now honours 「不出像素」 (a size change is not that switch's business), and
        // the preference is process-wide: a suite that ticked it earlier would decide this test's
        // answer. Pin it off for the fixture.
        _ = tool.setCropStaysInsidePixels(false)
        XCTAssertFalse(tool.autoCrop(), "a level picture is left byte-identical")
        XCTAssertEqual(editor.session.history.snapshots.count, levelHistory)
        XCTAssertEqual(editor.session.edit.geometry.crop, levelCrop)

        tool.setStraighten(30)
        let before = editor.session.history.snapshots.count
        XCTAssertTrue(tool.autoCrop(), "30° 应求出并写入最大矩形")
        XCTAssertEqual(editor.session.history.snapshots.count, before + 1,
                       "自动裁剪 = 一条历史")
        let geometry = editor.session.edit.geometry
        XCTAssertEqual(geometry.straightenDegrees, 30, accuracy: 1e-9)
        let crop = geometry.crop
        XCTAssertGreaterThan(crop.width * crop.height, 0.01)
        XCTAssertLessThan(crop.width * crop.height, 0.999, "旋转 30° 后不该还是整幅")
        XCTAssertGreaterThanOrEqual(crop.x, -1e-9)
        XCTAssertGreaterThanOrEqual(crop.y, -1e-9)
        XCTAssertLessThanOrEqual(crop.x + crop.width, 1 + 1e-9)
        XCTAssertLessThanOrEqual(crop.y + crop.height, 1 + 1e-9)
    }
}
