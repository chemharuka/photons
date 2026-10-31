import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 197 ① — 「应用裁剪后重进裁切，只渲染裁切区」.
///
/// The frame job used to render the **document** (`makeJob` → `session.edit`), so a photo that
/// already carried an applied crop came back into 裁切 as that rectangle only: the canvas was
/// `CropMath.canvasSize(crop:)` of the crop, every pixel outside it was missing, and there was no
/// band to put the turned picture's corners in. `CropToolController.previewEdit` (crop → `.full`)
/// existed but only the canvas-geometry key called it.
///
/// The fixture is the shared 072 library: a real editor window (so `makeJob` has a viewport), a real
/// «裁剪 → ↵应用 → 再进裁切» flow through the tool's own commands, and the job's edit read back out of
/// `makeJob`. The pixels come from a synthetic source, exactly like 196's corner suite, so the band
/// sample is a fact about the canvas and not about a decoder.
@MainActor
final class CropPreviewFullCanvasTests: XCTestCase {

    private var workDir: URL!

    /// The stored frame of the 072 fixture — `CropUITestSupport.stored`.
    private static let source = CropUITestSupport.stored
    /// A crop with a band on every side, so "outside the crop, inside the photo" is a real region.
    private static let applied = CropRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-preview-197-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture

    /// A grey photograph with a bright border: every texel is lit (so "is there a photograph here"
    /// is a question the readback can answer), and the border proves the picture's own edges survive
    /// the canvas.
    private func image(_ w: Int, _ h: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0.18, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 6 || y < 6 || x >= w - 6 || y >= h - 6
                let v: Float16 = edge ? 0.9 : 0.18
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "crop-preview-197")
    }

    private func graph(_ tag: String) throws -> RenderGraph {
        try RenderGraph(input: RenderInput(image: image(Self.source.width, Self.source.height),
                                          identity: "crop-preview-197-\(tag)"))
    }

    /// `photonsctl render`'s own options: no viewport, one canvas pixel per picture pixel. This is
    /// the render whose `canvas` **is** `Plan.canvas` — the number the report is about.
    private func wholeRender(_ edit: EditModel, _ graph: RenderGraph) throws -> RenderResult {
        try graph.render(edit, options: RenderOptions(
            canvas: nil, scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
            useCache: false, wantsPixels: false, source: .edited))
    }

    /// The frame texture's channels at one texel, as a litness flag (`rgba16Float`).
    private func lit(_ t: MTLTexture, _ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < t.width, y < t.height else { return false }
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 8,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        let r = Float(Float16(bitPattern: raw[0]))
        let g = Float(Float16(bitPattern: raw[1]))
        let b = Float(Float16(bitPattern: raw[2]))
        return max(r, max(g, b)) > 0.01
    }

    private func fullCanvas() -> ImageSize {
        CropMath.canvasSize(crop: .full, in: Self.source, straightenDegrees: 0, quarterTurns: 0)
    }

    /// 裁剪 → 回车应用 — the user's own two steps, through the tool's commands.
    private func applyCrop(_ loupe: LoupeController, _ session: CatalogSession,
                           _ rect: CropRect = CropPreviewFullCanvasTests.applied) throws {
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)
        loupe.cropTool.draft.crop = rect
        loupe.refreshCropTool()
        XCTAssertTrue(loupe.applyCropTool(), "应用 did not commit the frame")
        CropUITestSupport.pump(0.05)
    }

    // MARK: - ① the canvas is the whole frame again

    func testReenteringCropAfterAnAppliedCropRendersTheWholeCanvas() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        try applyCrop(loupe, session)
        let document = session.edit
        XCTAssertEqual(document.geometry.cropRect.width, Self.applied.width, accuracy: 1e-9,
                       "the fixture did not really apply a crop")

        // 再进裁切 — the moment the report is about.
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)
        let jobEdit = try XCTUnwrap(loupe.frameJobEditForTesting, "the loupe has no frame job")

        XCTAssertEqual(jobEdit.geometry.crop, .full,
                       "the frame job still renders the applied crop")
        XCTAssertEqual(jobEdit.decodeInputs, document.decodeInputs,
                       "dropping the crop must not move the decode key")
        XCTAssertEqual(jobEdit.geometry.straightenDegrees, document.geometry.straightenDegrees,
                       "a draft angle may never reach the render (088)")

        let g = try graph("whole")
        let job = try wholeRender(jobEdit, g)
        let doc = try wholeRender(document, g)
        defer {
            if let t = job.output { g.recycle(output: t) }
            if let t = doc.output { g.recycle(output: t) }
        }

        // ① the canvas is the whole frame.
        XCTAssertEqual(job.canvas, fullCanvas(),
                       "裁切 mode's canvas is not `CropMath.canvasSize(crop: .full)` — it is "
                       + "\(job.canvas.keyString) against the frame's \(fullCanvas().keyString)")
        // …and the document itself still is the crop: the control that says the fix is the tool's
        // preview document, not a changed `RenderGraph`.
        XCTAssertEqual(doc.canvas,
                       CropMath.canvasSize(crop: Self.applied, in: Self.source,
                                           straightenDegrees: 0, quarterTurns: 0),
                       "the control render of the document is no longer the crop")

        // ② the band inside the canvas and outside the crop is **photograph** — the pixels the
        //    old path did not even have a texture for.
        let t = try XCTUnwrap(job.output, "the job render produced no texture")
        let w = t.width, h = t.height
        let probes: [(name: String, x: Int, y: Int)] = [
            ("left", Int(Double(w) * 0.05), h / 2),
            ("top", w / 2, Int(Double(h) * 0.05)),
            ("right", Int(Double(w) * 0.95), h / 2),
            ("bottom", w / 2, Int(Double(h) * 0.95)),
        ]
        var samples: [String] = []
        for probe in probes {
            let on = lit(t, probe.x, probe.y)
            samples.append("\(probe.name)@(\(probe.x),\(probe.y))=\(on ? "photo" : "EMPTY")")
            XCTAssertTrue(on, "197 ① — the band at \(probe.name) is not photograph: \(probe.name) "
                          + "sample (\(probe.x),\(probe.y)) of \(w)×\(h)")
        }
        print("197 ① · job canvas \(job.canvas.keyString) · document canvas \(doc.canvas.keyString) "
              + "· full \(fullCanvas().keyString) · band \(samples.joined(separator: " · "))")

        // ③ dragging the frame / moving the angle while the tool is on keeps it: neither the draft
        //    rect nor the draft angle may shrink the canvas back to a region.
        loupe.cropTool.draft.crop = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        loupe.cropTool.setStraighten(3)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let dragged = try XCTUnwrap(loupe.frameJobEditForTesting)
        XCTAssertEqual(dragged.geometry.crop, .full, "a draft drag put the crop back into the job")
        XCTAssertEqual(dragged.geometry.straightenDegrees, 0,
                       "an unsaved 拉直 tick reached the render — 088 is a quad, not a re-render")
        let draggedRender = try wholeRender(dragged, g)
        defer { if let t = draggedRender.output { g.recycle(output: t) } }
        XCTAssertEqual(draggedRender.canvas, fullCanvas(),
                       "a draft drag/angle moved the render canvas")
    }

    /// ④ 退出裁切并应用 ⇒ 回到正常裁剪渲染，不残留全帧.
    func testLeavingCropRendersTheAppliedCropAgain() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        try applyCrop(loupe, session)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(try XCTUnwrap(loupe.frameJobEditForTesting).geometry.crop, .full,
                       "裁切 mode must still be the whole frame")

        // ↵ 应用 again (same rect → nothing is written) and the mode closes.
        _ = loupe.applyCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.cropTool.isActive, "the tool did not close")

        let after = try XCTUnwrap(loupe.frameJobEditForTesting,
                                  "no job after leaving 裁切 — the loupe lost its document")
        XCTAssertEqual(after, session.edit, "the frame job is not the document again")
        XCTAssertEqual(after.geometry.cropRect.width, Self.applied.width, accuracy: 1e-9,
                       "leaving 裁切 dropped the applied crop")

        let g = try graph("left")
        let render = try wholeRender(after, g)
        if let t = render.output { g.recycle(output: t) }
        let cropped = CropMath.canvasSize(crop: Self.applied, in: Self.source,
                                          straightenDegrees: 0, quarterTurns: 0)
        XCTAssertEqual(render.canvas, cropped,
                       "after 应用 the canvas is \(render.canvas.keyString), not the crop's "
                       + "\(cropped.keyString) — the full frame is still on the job")
        XCTAssertNotEqual(render.canvas, fullCanvas(), "the full canvas survived leaving 裁切")
        print("197 ④ · after leave · job crop \(after.geometry.cropRect.keyString) "
              + "· canvas \(render.canvas.keyString) · crop canvas \(cropped.keyString)")
    }

    /// 反向门 — 没有裁剪的文档进裁切，逐值就是今天的行为：job 的 edit 与 document 相等，画布是整帧，
    /// θ = 0 时 `canvasRect` 仍是 `drawnRect`（196 的锚点）。
    func testAnUncroppedDocumentKeepsTodaysNumbers() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        XCTAssertEqual(session.edit.geometry.cropRect, .full, "the fixture must start uncropped")
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        let document = session.edit
        let jobEdit = try XCTUnwrap(loupe.frameJobEditForTesting)
        XCTAssertEqual(jobEdit, document,
                       "an uncropped document must reach the queue unchanged — "
                       + "\(jobEdit.geometry.cropRect.keyString) vs \(document.geometry.cropRect.keyString)")

        let g = try graph("uncropped")
        let job = try wholeRender(jobEdit, g)
        defer { if let t = job.output { g.recycle(output: t) } }
        XCTAssertEqual(job.canvas, fullCanvas(), "θ = 0 uncropped canvas moved")
        XCTAssertEqual(job.canvas, Self.source, "θ = 0 uncropped canvas is not the picture")
        XCTAssertEqual(job.canvasRect, job.drawnRect,
                       "θ = 0 · the canvas rect and the picture rect must stay one rect")
        print("197 reverse · job == document · canvas \(job.canvas.keyString) "
              + "· canvasRect \(job.canvasRect.keyString) == drawnRect \(job.drawnRect.keyString)")
    }
}
