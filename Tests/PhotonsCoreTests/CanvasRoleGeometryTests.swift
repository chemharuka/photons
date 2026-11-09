import XCTest
import Metal
import PhotonsCore

/// **307 — `CanvasRole`, at the product level.** The type and the renderer's one branch on it, with no
/// UI in the way: `.export` is 301's crop frame bit for bit, `.document` is the turned whole
/// photograph's AABB with the frame centred in it, and the two renders of one document are *different
/// rectangles* (which is why `StageAlgorithmVersion.geometry` moves 4 → 5 and the export hash does not).
final class CanvasRoleGeometryTests: XCTestCase {

    private let source = ImageSize(width: 480, height: 320)

    private func geometry(_ degrees: Double, crop: CropRect = .full,
                          source: ImageSize? = nil) -> CropGeometry {
        var g = GeometryGroup.identity
        g.rotationDegrees = degrees
        g.crop = crop.normalizedRect
        return CropGeometry(geometry: g, source: source ?? self.source)
    }

    // MARK: - the two canvases

    func testTheExportCanvasIsTheFrameAndTheDocumentCanvasIsThePhotograph() {
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            let g = geometry(degrees)
            XCTAssertEqual(g.canvas(.export), g.canvas, "\(degrees)°: `.export` is `CropGeometry.canvas`")
            XCTAssertEqual(g.canvas(.export), g.frameSize, "\(degrees)°: the export canvas is the frame")
            XCTAssertEqual(g.canvasInset(.export).x, 0, accuracy: 0)
            XCTAssertEqual(g.canvasInset(.export).y, 0, accuracy: 0)

            XCTAssertEqual(g.canvas(.document).width, Int(g.photoExtent.width.rounded(.up)),
                           accuracy: 0, "\(degrees)°: the document canvas is the turned photograph's AABB")
            let inset = g.canvasInset(.document)
            let box = g.canvasExtent(.document)
            XCTAssertEqual(inset.x + Double(g.frameSize.width) / 2, box.width / 2, accuracy: 1e-9,
                           "\(degrees)°: the frame is centred in the document canvas")
            XCTAssertEqual(inset.y + Double(g.frameSize.height) / 2, box.height / 2, accuracy: 1e-9)
            print(String(format: "307 · %.0f° · export %d×%d inset (%.2f, %.2f) · document %.1f×%.1f"
                         + " inset (%.2f, %.2f)",
                         degrees, g.canvas(.export).width, g.canvas(.export).height,
                         g.canvasInset(.export).x, g.canvasInset(.export).y,
                         box.width, box.height, inset.x, inset.y))
        }
        // The numbers the diagnosis lists for 480×320 / 15°, to the tenth of a pixel.
        let tilted = geometry(15)
        XCTAssertEqual(tilted.canvasExtent(.document).width, 546.5, accuracy: 0.05)
        XCTAssertEqual(tilted.canvasExtent(.document).height, 433.3, accuracy: 0.05)
        XCTAssertEqual(tilted.canvasInset(.document).x, 33.25, accuracy: 0.05)
        XCTAssertEqual(tilted.canvasInset(.document).y, 56.65, accuracy: 0.05)
    }

    func testTheDocumentCanvasNeverClipsAFrameThatReachesOutsideThePhotograph() {
        let g = geometry(15, crop: CropRect(left: -0.2, top: -0.2, right: 1.2, bottom: 1.2))
        let box = g.canvasExtent(.document)
        XCTAssertGreaterThanOrEqual(box.width, g.frameExtentPixels.width - 1e-9,
                                    "the box must hold a frame larger than the photograph")
        XCTAssertGreaterThanOrEqual(box.height, g.frameExtentPixels.height - 1e-9)
    }

    // MARK: - the renderer's one branch

    private func rampImage(_ width: Int, _ height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = 0.6 * Double(x) / Double(max(width - 1, 1))
                    + 0.4 * Double(y) / Double(max(height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "307-role-core")
    }

    private func document(_ degrees: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = degrees
        edit.geometry.crop = .full
        edit.geometry.aspectLock = .original
        return edit
    }

    /// `.export` allocates the crop frame and leaves `frameOrigin` at 0; `.document` allocates the
    /// photograph's AABB and centres the frame inside it. One `switch`, two rectangles.
    func testTheRendererAllocatesTheCanvasTheRoleNames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: rampImage(source.width, source.height),
                                                      identity: "307-core"))
        for degrees in [0.0, 15.0] {
            let export = try graph.render(document(degrees), options: RenderOptions(
                canvasRole: .export, scale: 1, useCache: false, wantsPixels: false))
            let doc = try graph.render(document(degrees), options: RenderOptions(
                canvasRole: .document, scale: 1, useCache: false, wantsPixels: false))
            if let t = export.output { graph.recycle(output: t) }
            if let t = doc.output { graph.recycle(output: t) }
            print("307 · render \(degrees)° · export \(export.canvas.width)×\(export.canvas.height)"
                  + " drawn \(export.drawnRect) · document \(doc.canvas.width)×\(doc.canvas.height)"
                  + " drawn \(doc.drawnRect) expanded \(String(describing: doc.expandedCanvas))")

            XCTAssertEqual(export.canvas, geometry(degrees).canvas, "\(degrees)°: export = the frame")
            XCTAssertNil(export.expandedCanvas, "\(degrees)°: the export role has no baseline")
            XCTAssertEqual(export.drawnRect, ImageRect(x: 0, y: 0,
                                                       width: export.canvas.width,
                                                       height: export.canvas.height),
                           "\(degrees)°: the export picture is its whole canvas")

            let box = geometry(degrees).canvas(.document)
            XCTAssertEqual(doc.canvas, box, "\(degrees)°: the document role allocates the AABB")
            if degrees != 0 {
                XCTAssertNotNil(doc.expandedCanvas, "\(degrees)°: the document role has a baseline")
            }
            XCTAssertEqual(doc.drawnRect, ImageRect(x: 0, y: 0,
                                                    width: box.width, height: box.height),
                           "\(degrees)°: the document picture is the whole AABB (its corners are 0)")
        }
    }

    /// The export render of a full-frame document is **byte-identical whichever role API exists** —
    /// the role is a parameter with a default, not a new code path for `.export`. Pinned by hash so a
    /// future change that lets `.document` leak into the export is caught here, before the goldens.
    func testTheExportRenderIsPinnedByteForByte() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: rampImage(source.width, source.height),
                                                      identity: "307-core-pinned"))
        // 301's own reading of this document: canvas == the crop frame.
        for degrees in [0.0, 15.0] {
            let result = try graph.render(document(degrees), options: RenderOptions(
                canvasRole: .export, scale: 1, useCache: false, wantsPixels: true))
            let display = try XCTUnwrap(result.display)
            let hash = display.sha256()
            print("307 · export pin \(degrees)° · \(display.width)×\(display.height) · \(hash.prefix(16))…")
            // Pinned on this tree, on a synthetic ramp (no RAW needed). Re-pinned for 314: the shipped
            // default sharpen (50 / 2.0) is part of the exported look now, so the numbers moved by
            // design; the claim this pin still carries is "`.export` is one path, not the `.document`
            // one". The two recorded goldens were re-recorded for the same reason.
            // (`render-edit-crop-rot-s0.25` = `ed99453e…`, `render-edit-push-s0.25` = `ee726906…`,
            // both re-measured after the change and equal to the pre-change values); this pin is what
            // catches a leak from the `.document` branch into the default one, at unit-test speed.
            let pinned = degrees == 0
                ? "0d8c84d768302ab9547ea400f889c3679f16b4b134dc121f1c2c15ba72f97ef1"
                : "ef985bad61f35807b7dcda4c4be39e03f62c07c4ec54f9d1347c96523f9e6715"
            XCTAssertEqual(hash, pinned, "\(degrees)°: the export moved — `.export` must stay 301")
        }
    }
}
