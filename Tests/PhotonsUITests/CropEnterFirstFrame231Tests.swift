import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 231 — **entering 裁切 on a photo whose preview rung is still resident must draw the whole frame
/// on the first layout, not a top-left quarter that jumps back a second later.**
///
/// The report: 「新的照片，进入裁切界面，裁切框一开始占据左上 1/4 面积，然后等一两秒跳回全图」.
/// The 0.5 preview rung lands first (that is what the ladder shows while the full development runs),
/// and `present` used to publish the *buffer's* size as `CatalogSession.ingestedSourceFrame` while
/// `framing()` divides by `decodeScale` and describes the whole file. The crop tool reads the former
/// (`cropSourceSize`) and the projection reads the latter, so on the 0.5 rung a `.full` crop was drawn
/// at half scale from the canvas origin — exactly a 1/4-area rectangle in the top-left corner — and
/// only the 1.0 rung (a second later) made the two agree.
///
/// This probe drives the **shipped** publication (`publishIngestedSource`, through its test seam),
/// installs a synthetic half-size rung so `framing()` reports the full file, then reads the overlay's
/// own per-frame log: every frame from the entry onwards has to be the final frame.
@MainActor
final class CropEnterFirstFrame231Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-enter-231-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// The rung the loupe shows first: half the stored `1200 × 800`.
    private static let rung = ImageSize(width: 600, height: 400)
    private static let rungScale: Double = 0.5
    private static let stored = ImageSize(width: 1200, height: 800)

    private func makeLoupe() throws -> (LoupeController, CatalogSession, NSWindow) {
        _ = NSApplication.shared
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                            width: Self.stored.width,
                                                            height: Self.stored.height)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        let window = TestWindows.make(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        TestWindows.show(window)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)

        // The 0.5 rung: a synthetic buffer of half the stored size, decoded at scale 0.5, so
        // `framing()` describes the full 1200 × 800 file exactly as the app does.
        let image = LinearImage(width: Self.rung.width, height: Self.rung.height,
                                rgba: [Float16](repeating: 0, count: Self.rung.width * Self.rung.height * 4),
                                colorSpace: "extendedLinearSRGB", decoderVersion: "test")
        loupe.installDecodedRungForTesting(image, scale: Self.rungScale)
        // The same call `present` makes when this rung lands.
        loupe.publishIngestedSourceForTesting(rung: Self.rung, decodeScale: Self.rungScale)
        return (loupe, session, window)
    }

    private func bounds(_ corners: [CGPoint]?) -> CGRect? {
        guard let corners else { return nil }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func testEnteringCropOnThePreviewRungDrawsTheWholeFrameFromTheFirstFrame() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }

        // The publication is rung-independent: the crop tool's frame and the projection's frame are
        // the same number *before* the camera is armed, which is what the entry layout needs.
        XCTAssertEqual(session.maskSourceSize, Self.stored,
                       "231: a 0.5 rung must still publish the full upright file")
        XCTAssertEqual(try XCTUnwrap(loupe.framing()).sourceWidth, Double(Self.stored.width),
                       accuracy: 0.5, "231: the projection describes the full file")
        XCTAssertEqual(loupe.cropSourceSize, Self.stored,
                       "231: the crop tool must describe the same full file as the projection")

        let start = loupe.cropOverlayLayoutFrames.count
        XCTAssertTrue(loupe.setCropWorkspaceActive(true), "裁切 mode did not open")
        // More than three frames from the entry: the arming itself, then the layouts a window/resize
        // tick produces (`refreshCropTool` is the same funnel `viewDidLayout` uses). Every one of them
        // is a frame the overlay may draw.
        for _ in 0..<3 {
            CropUITestSupport.pump(0.01)
            loupe.refreshCropTool()
        }
        CropUITestSupport.pump(0.01)
        XCTAssertTrue(loupe.isCropToolActive)

        let frames = Array(loupe.cropOverlayLayoutFrames.dropFirst(start))
        XCTAssertGreaterThanOrEqual(frames.count, 3, "231: fewer than three frames were laid out")

        let viewport = loupe.viewportPixels
        let canvas = CGRect(x: 0, y: 0,
                            width: Double(viewport.width) / loupe.backingScale,
                            height: Double(viewport.height) / loupe.backingScale)

        var previous: CGRect?
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.crop, .full, "frame \(index): the draft is not the document's full crop")
            guard let rect = frame.corners else {
                XCTFail("frame \(index): the overlay was handed no corners")
                continue
            }
            let quarter = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height / 2)
            XCTAssertFalse(abs(rect.minX - quarter.minX) < 2 && abs(rect.minY - quarter.minY) < 2
                           && abs(rect.width - quarter.width) < 2 && abs(rect.height - quarter.height) < 2,
                           "frame \(index): the 0.5 rung's 1/4 frame was drawn — \(rect) vs \(quarter)")

            if let previous {
                XCTAssertEqual(rect.minX, previous.minX, accuracy: 0.5,
                               "frame \(index): the frame moved after the first layout")
                XCTAssertEqual(rect.minY, previous.minY, accuracy: 0.5,
                               "frame \(index): the frame moved after the first layout")
                XCTAssertEqual(rect.width, previous.width, accuracy: 0.5,
                               "frame \(index): the frame changed size after the first layout")
                XCTAssertEqual(rect.height, previous.height, accuracy: 0.5,
                               "frame \(index): the frame changed size after the first layout")
            }
            previous = rect
            print(String(format: "231 · frame %d · crop l %.3f t %.3f r %.3f b %.3f · rect %@",
                         index, frame.crop.left, frame.crop.top, frame.crop.right, frame.crop.bottom,
                         NSStringFromRect(rect)))
        }

        // The frame is the 90 % whole-frame fit, not a quarter of the canvas.
        let final = try XCTUnwrap(previous)
        XCTAssertGreaterThan(final.width, canvas.width * 0.6,
                             "231: the frame is not the whole picture — \(final) vs \(canvas)")
        XCTAssertGreaterThan(final.height, canvas.height * 0.6,
                             "231: the frame is not the whole picture — \(final) vs \(canvas)")

        // And it is the projection's own frame, value for value.
        let projected = try XCTUnwrap(loupe.cropToolLayout())
        let expected = try XCTUnwrap(bounds(projected.corners))
        XCTAssertEqual(final.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(final.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(final.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(final.height, expected.height, accuracy: 0.5)
    }

    /// 231 — the **second** reproduction condition: the document already carries a crop. Entering
    /// 裁切 must show *that* crop from the first frame, on the whole file, not a `.full` frame and not
    /// a rect measured in the 0.5 rung's half-size grid.
    ///
    /// The first test above starts from `.full`, where the old bug happened to look like the top-left
    /// 1/4. A cropped document is the harder case: the rect is neither `.full` nor origin-anchored, so
    /// the assertion has to compare the projected quad against the **full-source** projection of the
    /// document's own crop. Removing the `decodeScale` division makes the tool measure `600 × 400`
    /// while the projection still describes `1200 × 800`, so every frame shrinks to half size and this
    /// test (and the `.full` one above) goes red.
    func testEnteringCropOnAnAlreadyCroppedDocumentShowsThatCropFromTheFirstFrame() throws {
        let (loupe, session, window) = try makeLoupe()
        defer { window.orderOut(nil) }

        // The document already has a crop — the value the first frame has to show.
        let documentCrop = CropRect(left: 0.2, top: 0.15, right: 0.8, bottom: 0.85)
        session.applyEdit { $0.geometry.crop = documentCrop.normalizedRect }
        session.commitEdit(label: "probe crop", coalesce: false)
        CropUITestSupport.pump(0.02)
        XCTAssertEqual(session.edit.geometry.cropRect, documentCrop,
                       "231: the fixture did not keep the document's crop")

        let start = loupe.cropOverlayLayoutFrames.count
        XCTAssertTrue(loupe.setCropWorkspaceActive(true), "裁切 mode did not open")
        // More than the five frames the case asks for: the entry itself, then one layout per refresh.
        for _ in 0..<5 {
            CropUITestSupport.pump(0.01)
            loupe.refreshCropTool()
        }
        CropUITestSupport.pump(0.01)
        XCTAssertTrue(loupe.isCropToolActive)

        let frames = Array(loupe.cropOverlayLayoutFrames.dropFirst(start))
        XCTAssertGreaterThanOrEqual(frames.count, 5, "231: fewer than five frames were laid out")

        // The rect the whole file projects the document's crop to. This is computed from the
        // **stored** `1200 × 800`, independently of what `cropSourceSize` currently says, so a tool
        // measuring the 600 × 400 rung cannot match it.
        let mapping = try XCTUnwrap(loupe.framing()).mapping(of: loupe.viewState)
        let expectedLayout = CropTool.layout(crop: documentCrop, source: Self.stored,
                                             mapping: mapping, pointScale: loupe.backingScale)
        let canvasRect = try XCTUnwrap(bounds(expectedLayout.corners),
                                       "231: the expected frame has no corners")
        let viewport = loupe.viewportPixels
        let canvas = CGRect(x: 0, y: 0,
                            width: Double(viewport.width) / loupe.backingScale,
                            height: Double(viewport.height) / loupe.backingScale)
        XCTAssertLessThan(canvasRect.width, canvas.width * 0.9,
                          "231: the fixture's crop is not narrower than the canvas")

        for (index, frame) in frames.enumerated() {
            // ① the draft is the document's crop — not `.full`, not a re-seed from the rung.
            XCTAssertEqual(frame.crop, documentCrop,
                           "frame \(index): the draft is not the document's crop")
            guard let rect = frame.corners else {
                XCTFail("frame \(index): the overlay was handed no corners")
                continue
            }
            // ② the rect on the canvas is the whole-file projection from the very first frame.
            XCTAssertEqual(rect.minX, canvasRect.minX, accuracy: 0.5,
                           "frame \(index): the canvas rect is not final — \(rect) vs \(canvasRect)")
            XCTAssertEqual(rect.minY, canvasRect.minY, accuracy: 0.5,
                           "frame \(index): the canvas rect is not final — \(rect) vs \(canvasRect)")
            XCTAssertEqual(rect.width, canvasRect.width, accuracy: 0.5,
                           "frame \(index): the canvas rect is not final — \(rect) vs \(canvasRect)")
            XCTAssertEqual(rect.height, canvasRect.height, accuracy: 0.5,
                           "frame \(index): the canvas rect is not final — \(rect) vs \(canvasRect)")

            let quarter = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height / 2)
            XCTAssertFalse(abs(rect.minX - quarter.minX) < 2 && abs(rect.minY - quarter.minY) < 2
                           && abs(rect.width - quarter.width) < 2 && abs(rect.height - quarter.height) < 2,
                           "frame \(index): the 0.5 rung's 1/4 frame was drawn — \(rect) vs \(quarter)")

            print(String(format: "231 cropped · frame %d · crop l %.3f t %.3f r %.3f b %.3f · rect %@",
                         index, frame.crop.left, frame.crop.top, frame.crop.right, frame.crop.bottom,
                         NSStringFromRect(rect)))
        }
    }

    /// The pure policy the present path uses: the rung's pixels divided by the scale it was decoded
    /// at. At scale 1 this is the old value exactly.
    func testFullSourceSizeDividesTheRungByItsDecodeScale() {
        XCTAssertEqual(LoupeController.fullSourceSize(rung: Self.rung, decodeScale: 0.5),
                       Self.stored)
        XCTAssertEqual(LoupeController.fullSourceSize(rung: Self.stored, decodeScale: 1),
                       Self.stored)
        XCTAssertEqual(LoupeController.fullSourceSize(rung: Self.rung, decodeScale: 0),
                       Self.rung, "a degenerate scale falls back to 1, never to zero")
    }
}
