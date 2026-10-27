import XCTest
import Metal
@testable import PhotonsCore

/// P1e — the `showMask` overlay is one pointwise pass (0.46 ms at 4.10 Mpx, `perf-baseline` §6 ②), and a
/// frame that changes nothing used to pay it again: the pass reads the finished frame and the atlas
/// slice, neither of which moved, so it wrote the same bytes back into a new texture 20 times in a row.
///
/// The gate is a **reuse slot** keyed on exactly what the pass reads (the upstream resume key, the
/// display key, the atlas key, the mask id, the slice, the canvas). This file pins the four properties
/// that make it a gate and not a cache that lies:
///
///   ① a frame that changes nothing does **not** submit the pass, and its pixels are the frame that was
///      painted — `showMaskPasses` does not move, `showMaskReused` is true, and the hash is equal;
///   ② the first frame after the overlay appears, is re-shown, or the picture moves **does** submit it —
///      the pass count goes up by exactly one, and the pixels equal a fresh render of the same document
///      (so the frame is current, not yesterday's pixels under a new picture);
///   ③ while a parameter is dragged every frame is painted — ten frames, ten passes, ten distinct hashes
///      in the overlay's own region (a frozen wash would repeat a hash);
///   ④ hiding the overlay submits nothing and returns the frame the document would have produced alone.
///
/// The refutation is deliberate and cheap to run: replace the slot's key comparison with `false` (never
/// paint) and ① fails on the very first frame — the pixels come back equal to the no-overlay render. So
/// ① is measuring "the overlay is in the pixels", not "some counter moved".
final class MaskOverlayGateTests: XCTestCase {

    private let canvas = ImageSize(width: 640, height: 400)

    private func makeGraph(identity: String = "mask-overlay-gate") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: rampImage(), identity: identity))
    }

    /// A ramp with texture, so an overlay at 50 % of a mask's coverage has something to modify and a
    /// one-pixel difference cannot hide in a flat field.
    private func rampImage() -> LinearImage {
        let width = canvas.width, height = canvas.height
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let u = Double(x) / Double(width - 1), v = Double(y) / Double(height - 1)
                rgba[o] = Float16(0.04 + 0.55 * u)
                rgba[o + 1] = Float16(0.03 + 0.50 * v)
                rgba[o + 2] = Float16(0.05 + 0.35 * (1 - u) * v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// One enabled radial mask, selected for display. Two masks so a switch between them is a case.
    private func document(exposure: Double = 0, showing: String? = nil) -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = exposure
        func radial(_ cx: Double, _ cy: Double) -> MaskShape {
            .radialGradient(RadialGradientShape(center: NormalizedPoint(cx, cy),
                                                radius: NormalizedPoint(0.22, 0.30)))
        }
        e.masks = [
            Mask(id: "m-a", feather: 0.05,
                 components: [MaskComponent(id: "a1", feather: 0.0, shape: radial(0.42, 0.5))],
                 adjustments: LocalAdjustments(exposure: 0.2)),
            Mask(id: "m-b", feather: 0.05,
                 components: [MaskComponent(id: "b1", feather: 0.0, shape: radial(0.65, 0.5))],
                 adjustments: LocalAdjustments(exposure: -0.2)),
        ]
        e.showMaskID = showing
        return e
    }

    private func options() -> RenderOptions {
        RenderOptions(canvas: canvas, scale: 1,
                      display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
                      useCache: true, wantsPixels: true)
    }

    @discardableResult
    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> (hash: String, painted: Bool,
                                                                          reused: Bool, shows: Bool) {
        let before = graph.showMaskPasses
        let r = try graph.render(edit, options: options())
        let pixels = try XCTUnwrap(r.display)
        return (pixels.sha256(), graph.showMaskPasses != before,
                r.maskReport?.showMaskReused ?? false, r.showsMask)
    }

    // MARK: - ①②

    func testStaticFramesDoNotSubmitThePassAndTheFirstFrameAfterAChangeDoes() throws {
        let graph = try makeGraph()

        // Warm the pipeline on the document as it is without the overlay.
        let plain = try render(graph, document())
        XCTAssertFalse(plain.painted)
        XCTAssertFalse(plain.shows)

        // ① The first frame that shows the mask: painted, and it is not the plain frame.
        let first = try render(graph, document(showing: "m-a"))
        XCTAssertTrue(first.painted, "the first frame with an overlay must submit the pass")
        XCTAssertTrue(first.shows)
        XCTAssertNotEqual(first.hash, plain.hash, "showMask changed no pixel")

        // Twenty frames of the same document: nothing moves, nothing is submitted, and the pixels are
        // still the ones painted above — a skipped pass must not flash the overlay off.
        let passesBefore = graph.showMaskPasses
        for i in 0..<20 {
            let r = try render(graph, document(showing: "m-a"))
            XCTAssertFalse(r.painted, "static frame \(i) re-submitted the overlay pass")
            XCTAssertTrue(r.reused, "static frame \(i) should report the reuse")
            XCTAssertTrue(r.shows)
            XCTAssertEqual(r.hash, first.hash, "static frame \(i) is not byte-identical to frame ①")
        }
        XCTAssertEqual(graph.showMaskPasses, passesBefore, "20 static frames submitted a pass")

        // ② A change of picture: the very first frame must paint — and must be current. The reference is
        // the same document on a second graph, so "equal" cannot be satisfied by reusing the old slot.
        let moved = document(exposure: 0.35, showing: "m-a")
        let reference = try makeGraph(identity: "mask-overlay-reference")
        let referenceOver = try render(reference, moved)
        XCTAssertTrue(referenceOver.painted)
        let referencePlain = try render(reference, document(exposure: 0.35))
        XCTAssertNotEqual(referenceOver.hash, referencePlain.hash,
                          "the reference itself has no overlay in it")

        let afterMove = try render(graph, moved)
        XCTAssertTrue(afterMove.painted, "the first frame after a change must submit the pass")
        XCTAssertEqual(afterMove.hash, referenceOver.hash,
                       "the first frame after a change is stale — it reused the previous slot")
        XCTAssertNotEqual(afterMove.hash, first.hash)

        // Hiding the overlay: no pass, and the pixels are the document's own again (④).
        let hidden = try render(graph, document(exposure: 0.35))
        XCTAssertFalse(hidden.painted)
        XCTAssertFalse(hidden.shows)
        XCTAssertEqual(hidden.hash, referencePlain.hash, "hiding the overlay left it on screen")

        // Re-showing it: one pass, and back to the same pixels.
        let again = try render(graph, moved)
        XCTAssertTrue(again.painted, "re-showing the overlay must paint the first frame")
        XCTAssertEqual(again.hash, referenceOver.hash)

        // Switching which mask is shown is a change of the pass's own input, not of the picture.
        let switched = try render(graph, document(exposure: 0.35, showing: "m-b"))
        XCTAssertTrue(switched.painted, "switching masks must paint the first frame")
        XCTAssertNotEqual(switched.hash, referenceOver.hash, "the other mask's wash is the same pixels")
    }

    // MARK: - ③

    func testADragPaintsEveryFrame() throws {
        let graph = try makeGraph()
        try render(graph, document(showing: "m-a"))   // warm, and paint the slot once

        var hashes: [String] = []
        var painted = 0
        for i in 0..<10 {
            let r = try render(graph, document(exposure: 0.02 * Double(i + 1), showing: "m-a"))
            painted += r.painted ? 1 : 0
            hashes.append(r.hash)
        }
        XCTAssertEqual(painted, 10, "a drag must submit the pass on every frame")
        XCTAssertEqual(Set(hashes).count, 10,
                       "two drag frames came back identical — the overlay (or the picture) froze")
    }

    // MARK: - the slot's ownership

    /// The slot's texture is handed out as a frame. A caller that recycles it (as every frame path does)
    /// must not put it back in the pool: the next stage allocation would then overwrite the pixels the
    /// slot promises to reuse, and the frame after that would present a torn overlay.
    func testRecyclingTheSlotTextureDoesNotCorruptTheReuse() throws {
        let graph = try makeGraph()
        let opts = RenderOptions(canvas: canvas, scale: 1,
                                 display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
                                 useCache: true, wantsPixels: false)
        let doc = document(showing: "m-a")
        try render(graph, document())                       // warm
        let painted = try graph.render(doc, options: opts)  // the pass runs, the slot takes the texture
        let slotTexture = try XCTUnwrap(painted.output)
        let reference = try render(graph, doc)              // the pixels the overlay must keep showing
        XCTAssertTrue(reference.reused)

        // Three rounds of "present it, hand it back": each one is a chance for a pooled texture to be
        // handed to another stage and overwritten. The pixels must not move.
        for i in 0..<3 {
            graph.recycle(output: slotTexture)
            let again = try graph.render(doc, options: opts)
            XCTAssertEqual(again.maskReport?.showMaskReused, true, "round \(i) re-submitted the pass")
            graph.recycle(output: try XCTUnwrap(again.output))
            let shown = try render(graph, doc)
            XCTAssertEqual(shown.hash, reference.hash,
                           "round \(i): the reused frame is not the frame that was painted")
        }
    }
}
