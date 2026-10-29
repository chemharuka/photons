import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 「裁切窗口不可以在画面外（如果旋转后），要自动缩小」 — the constraint on the **shipped path**.
///
/// The math is `CropMath.clampedToRotatedFrame` (`CropFrameInscribeTests`, 1200×800, closed form vs a
/// bisection). This file answers the two questions that math cannot:
///
///  1. does the frame the overlay **draws** stay on the turned picture? — `layout` is the only thing
///     the canvas draws, so its four corners are the frame the user sees;
///  2. does 应用 commit **that** rect, field by field? — 应用 used to write `draft.crop`, and at a
///     non-zero straighten the stored rect is the user's *intent*, not what the picture allows; the
///     two would then disagree by exactly the amount the constraint took away.
///
/// Both are measured through `CropToolController.effectiveCrop`, which every reader goes through
/// (overlay, bar's 像素 readout, inspector draft, 应用). The anti-proof flips `clampsToRotatedFrame`
/// off on the same path and shows the committed crop leaving the picture.
@MainActor
final class CropRotatedFrameClampTests: XCTestCase {

    private var workDir: URL!

    /// A canvas big enough that `clampToView` is willing to speak (its own floor is 64 pt).
    private static let canvas = ImageSize(width: 900, height: 600)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-inscribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func framing(_ source: ImageSize, straighten: Double) -> LoupeMapping {
        LoupeFraming(viewport: Self.canvas,
                     sourceWidth: Double(source.width),
                     sourceHeight: Double(source.height),
                     crop: .full,
                     straightenDegrees: straighten).mapping(of: .fit)
    }

    // MARK: - 1. what the overlay draws

    /// The drawn frame — the quad the overlay paints and the grips the hand grabs — is inside the
    /// straightened picture at 9° / 15° / 45°, and it is **strictly smaller** than the stored rect (the
    /// auto-shrink actually happened, rather than the test passing on a frame that never moved).
    func testTheDrawnFrameIsInsideTheStraightenedPicture() throws {
        let source = ImageSize(width: 1200, height: 800)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: source.width,
                                                             height: source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        // 132: 803aff6's "the drawn frame must be inscribed in the turned picture" is opt-in now.
        controller.clampsToRotatedFrame = true

        for degrees in [9.0, 15, 45] {
            controller.draft = CropToolController.Draft(crop: .full, straighten: degrees,
                                                        lock: .original)
            let mapping = framing(source, straighten: degrees)
            let layout = controller.layout(mapping: mapping, source: source, pointScale: 1)
            let samples = layout.corners.map {
                mapping.sourcePoint(viewX: Double($0.x), viewY: Double($0.y))
            }
            let outside = samples.filter {
                $0.x < -1e-6 || $0.x > Double(source.width) + 1e-6
                    || $0.y < -1e-6 || $0.y > Double(source.height) + 1e-6
            }
            let drawn = controller.effectiveCrop(source: source)
            print(String(format: "画布 · %g° · 绘制框 %.6f×%.6f px · 存储框 %.6f×%.6f px · 出界角 %d",
                         degrees, drawn.width * 1200, drawn.height * 800,
                         controller.draft.crop.width * 1200, controller.draft.crop.height * 800,
                         outside.count))

            XCTAssertTrue(outside.isEmpty,
                          "\(degrees)°: the drawn frame samples outside the picture — \(outside)")
            XCTAssertLessThan(drawn.width, controller.draft.crop.width,
                              "\(degrees)°: the drawn frame was not shrunk at all")
            XCTAssertLessThan(drawn.height, controller.draft.crop.height,
                              "\(degrees)°: the drawn frame was not shrunk at all")
            // The intent is untouched, so 拉直 back to 0° gives the frame back.
            XCTAssertEqual(controller.draft.crop, .full,
                           "\(degrees)°: the constraint must not be written into the draft")
            // The readouts describe the frame on screen, not the intent behind it.
            XCTAssertEqual(controller.pixelText(source: source),
                           "\(Int((drawn.width * 1200).rounded()))×\(Int((drawn.height * 800).rounded()))",
                           "\(degrees)°: 像素 readout disagrees with the frame")
        }
    }

    // MARK: - 2. 真窗口：拖到 9° 再应用，文档 == 约束后的矩形（逐字段）

    /// A real editor window on a real library: 裁切 mode, the angle set to 9° the way the bar's slider
    /// does it (`setStraighten` + `refreshCropTool`, which is exactly what `straightenChanged` calls),
    /// then 应用. The committed document must carry the **same four numbers** the overlay drew.
    func testApplyingAtNineDegreesCommitsTheSameRectTheOverlayDrew() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let loupe = editor.rootView.loupeController
        defer { editor.window?.close() }

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, editor.session))
        let source = loupe.cropSourceSize
        XCTAssertEqual(source, ImageSize(width: 9520, height: 6336), "the upright frame")
        // 132: this test keeps covering the opt-in inscribed rect (the shipped default no longer
        // shrinks; `testTheFrameMayLeaveThePicture…` covers that).
        loupe.cropTool.clampsToRotatedFrame = true

        loupe.cropTool.setStraighten(9)
        loupe.refreshCropTool()
        XCTAssertEqual(loupe.cropTool.draft.straighten, 9)

        let drawn = loupe.cropTool.effectiveCrop(source: source)
        let expected = CropMath.clampedToRotatedFrame(.full, in: source, degrees: 9, keepsInsideRotatedFrame: true)
        print(String(format: "真窗口 · 9° · 绘制框 l %.12f t %.12f r %.12f b %.12f",
                     drawn.left, drawn.top, drawn.right, drawn.bottom))

        // The frame on screen is a real inscribed rect: a corner sits on the turned edge, so the
        // shrink is worth thousands of pixels on a 60 MP frame.
        XCTAssertTrue(CropMath.fitsInsideRotatedFrame(drawn, in: source, degrees: 9))
        XCTAssertLessThan(drawn.width, 0.95, "9°: nothing was shrunk — the test would be vacuous")

        XCTAssertTrue(loupe.applyCropTool(), "应用 must commit")
        let stored = editor.session.edit.geometry.cropRect
        XCTAssertEqual(editor.session.edit.geometry.rotationDegrees, 9, "the angle is part of the doc")

        // **逐字段** — four edges, one at a time, no tolerance in the comparison that matters.
        XCTAssertEqual(stored.left, drawn.left, "document left != drawn left")
        XCTAssertEqual(stored.top, drawn.top, "document top != drawn top")
        XCTAssertEqual(stored.right, drawn.right, "document right != drawn right")
        XCTAssertEqual(stored.bottom, drawn.bottom, "document bottom != drawn bottom")
        XCTAssertEqual(stored, drawn, "应用 must commit the frame the overlay drew")
        XCTAssertEqual(stored, expected, "…and that frame is the constrained one")
        // The committed crop samples nothing outside the sensor — the whole point.
        XCTAssertTrue(CropMath.fitsInsideSource(stored, in: source, degrees: 9),
                      "the committed crop still samples the clamped edge")
    }

    // MARK: - 3. 反证：去掉约束，同一路径必红

    /// With `clampsToRotatedFrame = false` the *same* path commits the full frame at 9°: the drawn
    /// quad leaves the picture and the document carries a rect that samples outside. Both criteria go
    /// red without the constraint, so neither assertion above can be passing for a reason of its own.
    func testWithoutTheConstraintTheAppliedCropLeavesThePicture() throws {
        let source = ImageSize(width: 1200, height: 800)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: source.width,
                                                             height: source.height)

        func apply(clamped: Bool) -> CropRect {
            let controller = CropToolController(session: session)
            XCTAssertTrue(controller.begin())
            controller.clampsToRotatedFrame = clamped
            controller.draft = CropToolController.Draft(crop: .full, straighten: 9, lock: .original)
            _ = controller.apply()
            return session.edit.geometry.cropRect
        }

        let withConstraint = apply(clamped: true)
        let without = apply(clamped: false)
        print(String(format: "反证 · 有约束 l %.6f t %.6f r %.6f b %.6f", withConstraint.left,
                     withConstraint.top, withConstraint.right, withConstraint.bottom))
        print(String(format: "反证 · 无约束 l %.6f t %.6f r %.6f b %.6f", without.left,
                     without.top, without.right, without.bottom))

        XCTAssertTrue(CropMath.fitsInsideSource(withConstraint, in: source, degrees: 9),
                      "the shipped path keeps the committed crop on the sensor")
        XCTAssertLessThan(withConstraint.width, 1, "the shipped path shrinks the frame")
        XCTAssertFalse(CropMath.fitsInsideSource(without, in: source, degrees: 9),
                       "anti-proof: without the constraint the committed crop leaves the sensor")
        XCTAssertEqual(without, .full, "anti-proof: …and it is exactly the unconstrained frame")
    }
}
