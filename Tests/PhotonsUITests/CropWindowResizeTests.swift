import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 169 §1 — 「旋转界面缩放窗口时画布不动但裁切框会被限制 90%，松手后两者再同时跳到调整好的位置」.
///
/// A window drag is a **live resize**. The picture on the canvas is frozen at the pixels it already
/// has while the hand is moving (067/068), so anything that re-projects the frame against the new
/// viewport alone describes a canvas that is not on screen. Every pass must keep the pair
/// (picture, frame) one geometry: frame ⊆ canvas, the frame's own aspect unchanged, its centre at
/// the same fraction of the canvas, and the frozen picture scaled by the very ratio the frame was.
@MainActor
final class CropWindowResizeTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    /// The three window sizes the task names, plus one intermediate size. They share one aspect
    /// (1.6), so a proportional resize has one answer and the canvas itself does not change shape.
    private static let entrySize = NSSize(width: 1600, height: 1000)
    private static let sizes = [NSSize(width: 1200, height: 800),
                                NSSize(width: 1400, height: 875),
                                NSSize(width: 2000, height: 1400)]

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-window-resize-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func fixture() throws -> URL {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
                                "UI tests must run with PHOTONS_TEST_RAW")
        return URL(fileURLWithPath: raw)
    }

    /// A bare canvas (no inspector, no filmstrip): the window **is** the canvas, so a resize keeps
    /// its aspect and the "same fraction of the canvas" criterion is a real one.
    private func makeLoupe() throws -> (LoupeController, CatalogSession, NSWindow) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 240, y: 200),
                                                  size: Self.entrySize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        windows.append(window)
        CropUITestSupport.pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while session.anchorAsset == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        return (loupe, session, window)
    }

    private func canvasRect(_ loupe: LoupeController) -> CGRect {
        let viewport = loupe.viewportPixels
        let scale = loupe.backingScale
        return CGRect(x: 0, y: 0,
                      width: Double(viewport.width) / scale,
                      height: Double(viewport.height) / scale)
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func relativeCentre(_ frame: CGRect, in canvas: CGRect) -> (x: Double, y: Double) {
        (Double((frame.midX - canvas.minX) / max(canvas.width, 1e-9)),
         Double((frame.midY - canvas.minY) / max(canvas.height, 1e-9)))
    }

    /// The picture the layer was actually handed, in view points. A present records its `pictureQuad`
    /// in drawable pixels; the overlay is in points, so the backing scale is the bridge.
    private func presentedPicture(_ loupe: LoupeController) -> CGRect? {
        guard let record = loupe.lastPresented else { return nil }
        let scale = loupe.backingScale
        let q = record.pictureQuad
        return CGRect(x: Double(q.x) / scale, y: Double(q.y) / scale,
                      width: Double(q.width) / scale, height: Double(q.height) / scale)
    }

    private func assertLayoutPass(_ loupe: LoupeController, _ step: String,
                                  entryAspect: Double, entryCentre: (x: Double, y: Double))
        throws {
        let canvas = canvasRect(loupe)
        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "\(step): the overlay is drawing nothing after layout")
        let frame = bounds(layout.corners)
        // ① the frame is inside the canvas
        XCTAssertTrue(CropCanvasClamp.contains(frame, in: canvas, tolerance: 0.5),
                      "\(step): the layout pass left the frame off the canvas")
        // ② its own aspect is the one the crop had at entry (1e-6)
        XCTAssertEqual(frame.width / frame.height, entryAspect, accuracy: 1e-6,
                       "\(step): the layout pass changed the aspect")
        // ③ its centre keeps its place in the canvas
        let relative = relativeCentre(frame, in: canvas)
        XCTAssertEqual(relative.x, entryCentre.x, accuracy: 1e-6,
                       "\(step): the layout pass moved the centre in x")
        XCTAssertEqual(relative.y, entryCentre.y, accuracy: 1e-6,
                       "\(step): the layout pass moved the centre in y")
    }

    /// ④ — the picture on the layer and the frame are the same rectangle at every tick. The frozen
    /// frame is re-presented on each pass, so a viewport-only re-projection shows up as a gap here.
    private func assertFrameMatchesPresentedPicture(_ loupe: LoupeController, _ step: String,
                                                    entryAspect: Double,
                                                    entryCentre: (x: Double, y: Double)) throws {
        try assertLayoutPass(loupe, step, entryAspect: entryAspect, entryCentre: entryCentre)
        let canvas = canvasRect(loupe)
        let frame = bounds(try XCTUnwrap(loupe.cropOverlayLayoutForTesting).corners)
        let picture = try XCTUnwrap(presentedPicture(loupe),
                                    "\(step): no present to measure the canvas against")
        print(String(format: "169 resize · %@ · canvas %@ · frame %@ · picture %@",
                     step, NSStringFromRect(canvas), NSStringFromRect(frame),
                     NSStringFromRect(picture)))
        XCTAssertEqual(frame.minX, picture.minX, accuracy: 1,
                       "\(step): the frame and the canvas disagree on the left edge")
        XCTAssertEqual(frame.minY, picture.minY, accuracy: 1,
                       "\(step): the frame and the canvas disagree on the top edge")
        XCTAssertEqual(frame.maxX, picture.maxX, accuracy: 1,
                       "\(step): the frame and the canvas disagree on the right edge")
        XCTAssertEqual(frame.maxY, picture.maxY, accuracy: 1,
                       "\(step): the frame and the canvas disagree on the bottom edge")
    }

    func testLiveWindowResizeKeepsFrameAndCanvasOneGeometry() throws {
        let url = try fixture()
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)

        // Put the picture that is on the canvas into the frozen-frame slot the live resize re-draws.
        let frame = try loupe.makeFrame(url: url,
                                        viewport: loupe.viewportPixels,
                                        decodeScale: 0.5,
                                        edit: session.edit,
                                        state: loupe.viewState)
        loupe.presentForTesting(frame)
        CropUITestSupport.pump(0.05)
        XCTAssertNotNil(loupe.lastPresented, "nothing was presented to resize")
        // `present` publishes the *decode rung's* size as the ingested frame; the crop tool and the
        // projection both mean the full upright frame here, so restore it before measuring.
        if let asset = session.anchorAsset {
            session.ingestedSourceFrame = (asset.id,
                                           ImageSize(width: asset.width ?? 1, height: asset.height ?? 1))
        }
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)

        let entry = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let entryFrame = bounds(entry.corners)
        let entryCanvas = canvasRect(loupe)
        let entryAspect = entryFrame.width / entryFrame.height
        let entryCentre = relativeCentre(entryFrame, in: entryCanvas)
        print(String(format: "169 resize · entry · canvas %@ · frame %@ · aspect %.6f",
                     NSStringFromRect(entryCanvas), NSStringFromRect(entryFrame), entryAspect))

        loupe.beginLiveResize()
        XCTAssertTrue(loupe.isLiveResizing)

        for size in Self.sizes {
            window.setContentSize(size)
            loupe.view.layoutSubtreeIfNeeded()
            let step = "\(Int(size.width))×\(Int(size.height))"
            // ④a the layout pass alone must already satisfy ①②③ — never "frame first, canvas later".
            try assertLayoutPass(loupe, "\(step) layout", entryAspect: entryAspect,
                                 entryCentre: entryCentre)
            // ④b …and after the frozen present lands, the picture and the frame are one rectangle.
            CropUITestSupport.pump(0.03)
            try assertFrameMatchesPresentedPicture(loupe, step, entryAspect: entryAspect,
                                                   entryCentre: entryCentre)
        }

        loupe.endLiveResize()
        CropUITestSupport.pump(0.1)
        try assertFrameMatchesPresentedPicture(loupe, "release", entryAspect: entryAspect,
                                               entryCentre: entryCentre)
    }
}
