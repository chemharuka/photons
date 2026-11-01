import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 2026-11-01 — **the crop tool must describe the same document the renderer does, at every quarter
/// turn.**
///
/// `CropGeometry.init(geometry:source:)` applies the document's quarter turn itself, and the crop
/// tool's `sourceSize` is *already* turned (it is what every drag and readout measures with). Feeding
/// the turned size back in swapped the dimensions a second time, so at 90°/270° the tool's `source`,
/// `frameSize` and `canvas` described the un-turned document while `RenderGraph` described the turned
/// one — same screenshot, two aspect ratios. No test pinned it; this one does.
@MainActor
final class CropGeometryOrientationTests: XCTestCase {

    private func makeSession(turns: Int) throws -> (CatalogSession, ImageSize, ImageSize) {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-orient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let upright = session.maskSourceSize
        if turns != 0 { session.applyEdit { $0.geometry.quarterTurns = turns } }
        let turned = session.edit.geometry.orientedSource(upright)
        return (session, upright, turned)
    }

    /// The one invariant: at every quarter turn the tool's geometry is the document's geometry.
    func testTheToolsGeometryMatchesTheRendererAtEveryTurn() throws {
        for turns in [0, 1, 2, 3] {
            let (session, upright, turned) = try makeSession(turns: turns)
            let controller = CropToolController(session: session)

            XCTAssertEqual(controller.sourceSize, turned,
                           "the tool measures in the turned frame (q=\(turns))")

            let geometry = controller.cropGeometry
            XCTAssertEqual(geometry.source, turned,
                           "CropGeometry.source must be the *turned* frame, not the upright one (q=\(turns))")
            XCTAssertEqual(geometry.source, controller.sourceSize,
                           "two spellings of the frame must agree (q=\(turns))")

            // What the renderer will allocate for the same document.
            let rendered = CropMath.canvasSize(crop: geometry.crop, in: upright,
                                               straightenDegrees: 0, quarterTurns: turns,
                                               allowsOutsideSource: true)
            XCTAssertEqual(geometry.canvas, rendered,
                           "the canvas the tool shows must be the one RenderGraph renders (q=\(turns))")
            XCTAssertEqual(controller.effectiveCanvas, rendered, "q=\(turns)")
            XCTAssertEqual(geometry.frameSize, geometry.canvas,
                           "a full crop at a right angle is its own canvas (q=\(turns))")
        }
    }

    /// An odd turn really does swap the dimensions — so the test above cannot pass by accident.
    func testAnOddTurnSwapsTheFrame() throws {
        let (session, upright, turned) = try makeSession(turns: 1)
        let controller = CropToolController(session: session)
        XCTAssertNotEqual(upright, turned, "a 90° turn renames the axes")
        XCTAssertEqual(turned.width, upright.height)
        XCTAssertEqual(turned.height, upright.width)
        XCTAssertEqual(controller.cropGeometry.source, turned)
    }
}
