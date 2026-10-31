import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 202 ② — **the frame must stay inside the canvas however it was moved out.**
///
/// The 196 lane stated the law (the turned frame's four sides inside the canvas) and proved it on the
/// **drag** path only. This probe moves the frame out four ways at two angles and four framings, at
/// the model layer where the geometry lives (no window, no bridge — the projection is the one the
/// camera would give), and records:
///
///   · how often `clampToView` ran and how often it moved the draft;
///   · the drawn frame's turned quad against the canvas, in document pixels, per edge (the 196 law);
///   · the same quad against the picture's own rect on the canvas, in device pixels (the user's
///     「框跑到画布外」), which is only meaningful at 适应 — at 1:1 the canvas is bigger than the window.
@MainActor
final class CropClampMatrixProbe202Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-202-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let source = ImageSize(width: 9520, height: 6336)
    private static let canvas = ImageSize(width: 1600, height: 1000)
    private static let seed = CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60)

    private struct Framing {
        let name: String
        let state: LoupeViewState
    }

    private static let framings: [Framing] = [
        Framing(name: "fit", state: .fit),
        Framing(name: "25%", state: LoupeViewState(mode: .actual, zoom: 0.25,
                                                   centerX: 4760, centerY: 3168)),
        Framing(name: "50%", state: LoupeViewState(mode: .actual, zoom: 0.5,
                                                   centerX: 4760, centerY: 3168)),
        Framing(name: "1:1", state: LoupeViewState(mode: .actual, zoom: 1,
                                                   centerX: 4760, centerY: 3168)),
    ]

    private enum Method: String, CaseIterable {
        case handle, body, zoomThenDrag, panThenDrag

        var title: String {
            switch self {
            case .handle: return "① 拖手柄"
            case .body: return "② 拖框体"
            case .zoomThenDrag: return "③ 缩放后拖"
            case .panThenDrag: return "④ 平移后拖"
            }
        }
    }

    private struct Cell {
        let angle: Double
        let framing: String
        let method: String
        let calls: Int
        let moves: Int
        let draftMoved: Bool
        let crop: CropRect
        let doc: CGRect
        let canvas: CGRect
        let screenQuad: CGRect
        let screenCanvas: CGRect
        /// The visible canvas in frame coordinates (`canvasBounds`) — the upright law.
        let frameBounds: CropRect
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The turned quad of `rect` in document pixels — the test's own arithmetic (196's).
    private func documentBox(_ rect: CropRect, degrees: Double) -> CGRect {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        func image(_ u: Double, _ v: Double) -> CGPoint {
            let turned = rotation.invert(x: u * w - w / 2, y: v * h - h / 2)
            return CGPoint(x: w / 2 + turned.x, y: h / 2 + turned.y)
        }
        return bounds([image(rect.left, rect.top), image(rect.right, rect.top),
                       image(rect.right, rect.bottom), image(rect.left, rect.bottom)])
    }

    private func documentCanvas(degrees: Double) -> CGRect {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let e = LoupeFraming.rotatedExtent(width: w, height: h, degrees: degrees)
        return CGRect(x: (w - e.width) / 2, y: (h - e.height) / 2, width: e.width, height: e.height)
    }

    /// The frame as it is drawn: `CropTool.layout`'s corners, in device pixels.
    private func drawn(controller: CropToolController, mapping: LoupeMapping) -> CGRect {
        bounds(controller.layout(mapping: mapping, source: Self.source).corners)
    }

    private func framing(degrees: Double) -> LoupeFraming {
        LoupeFraming(viewport: Self.canvas,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full, straightenDegrees: degrees, fitScale: 0.9)
    }

    // MARK: - the drags

    /// Drag from `start` outward, `ticks` times, ending at a point far outside the canvas.
    private func drag(controller: CropToolController, mapping: LoupeMapping, from start: CGPoint,
                      ticks: Int = 14, step: Double = 140) {
        XCTAssertTrue(controller.beginDrag(atViewPoint: start, mapping: mapping, source: Self.source),
                      "the drag did not start at \(start)")
        for i in 1...ticks {
            controller.continueDrag(atViewPoint: CGPoint(x: start.x - step * Double(i),
                                                         y: start.y - step * Double(i)),
                                    mapping: mapping, source: Self.source)
        }
        controller.endDrag()
    }

    private func run(method: Method, framing f: Framing, degrees: Double,
                     controller: CropToolController) throws -> Cell {
        controller.draft = CropToolController.Draft(crop: Self.seed, straighten: degrees,
                                                    lock: .original)
        let callsBefore = controller.clampCalls, movesBefore = controller.clampMoves
        let before = controller.draft.crop

        // The camera this method works at. ③ doubles it, ④ pans it, then drags.
        var state = f.state
        if method == .zoomThenDrag, case .actual = state.mode {
            state.zoom = min(2, state.zoom * 2)
        }
        if method == .zoomThenDrag, state.mode == .fit {
            state = LoupeViewState(mode: .actual, zoom: 0.25, centerX: 4760, centerY: 3168)
        }
        let mapping = framing(degrees: degrees).mapping(of: state)
        if method == .panThenDrag {
            state.centerX += 700
            state.centerY += 500
        }
        let map = framing(degrees: degrees).mapping(of: state)
        let _ = mapping

        let rect = drawn(controller: controller, mapping: map)
        let grab: CGPoint
        switch method {
        case .handle:
            grab = CGPoint(x: rect.minX + 2, y: rect.minY + 2)        // the top-left grip
        default:
            grab = CGPoint(x: rect.midX, y: rect.midY)                // the box's interior
        }
        drag(controller: controller, mapping: map, from: grab)

        let crop = controller.draft.crop
        let doc = documentBox(crop, degrees: controller.draft.straighten)
        let canvas = documentCanvas(degrees: controller.draft.straighten)
        let screenQuad = drawn(controller: controller, mapping: map)
        let screenCanvas = CGRect(x: Double(map.originX), y: Double(map.originY),
                                  width: Double(map.contentWidth), height: Double(map.contentHeight))
        let frameBounds = controller.canvasBounds(mapping: map, source: Self.source)
        return Cell(angle: degrees, framing: f.name, method: method.title,
                    calls: controller.clampCalls - callsBefore,
                    moves: controller.clampMoves - movesBefore,
                    draftMoved: crop != before, crop: crop,
                    doc: doc, canvas: canvas, screenQuad: screenQuad, screenCanvas: screenCanvas,
                    frameBounds: frameBounds)
    }

    private func out(_ box: CGRect, of canvas: CGRect, tolerance: Double) -> (String, Double) {
        let d = [canvas.minX - box.minX, canvas.minY - box.minY,
                 box.maxX - canvas.maxX, box.maxY - canvas.maxY].max() ?? 0
        let parts = ["L\(String(format: "%+.1f", canvas.minX - box.minX))",
                     "T\(String(format: "%+.1f", canvas.minY - box.minY))",
                     "R\(String(format: "%+.1f", box.maxX - canvas.maxX))",
                     "B\(String(format: "%+.1f", box.maxY - canvas.maxY))"]
        return (parts.joined(separator: " "), d - tolerance)
    }

    func testTheFrameStaysInsideTheCanvas() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())

        var cells: [Cell] = []
        for degrees in [5.4, 0.0] {
            session.applyEdit { $0.geometry.rotationDegrees = degrees }
            controller.draft = CropToolController.Draft(crop: Self.seed, straighten: degrees,
                                                        lock: .original)
            for f in Self.framings {
                for method in Method.allCases {
                    let cell = try run(method: method, framing: f, degrees: degrees,
                                       controller: controller)
                    cells.append(cell)
                    let (_, docExcess) = out(cell.doc, of: cell.canvas, tolerance: 0.5)
                    let upright = cell.frameBounds
                    let uprightExcess = max(upright.left - cell.crop.left, upright.top - cell.crop.top,
                                            cell.crop.right - upright.right,
                                            cell.crop.bottom - upright.bottom)
                    let (screenDetail, _) = out(cell.screenQuad, of: cell.screenCanvas, tolerance: 1)
                    print(String(format: "202 ② · θ %.1f° · %-4@ · %@ · calls %d moves %d · "
                                 + "quad %@ (excess %.1f px) · rect %@ (excess %.4f) · screen %@ · "
                                 + "crop l %.4f t %.4f r %.4f b %.4f",
                                 degrees, f.name, cell.method, cell.calls, cell.moves,
                                 docExcess > 0 ? "OUT" : "in ", docExcess * 1000,
                                 uprightExcess > 1e-6 ? "OUT" : "in ", uprightExcess, screenDetail,
                                 cell.crop.left, cell.crop.top, cell.crop.right, cell.crop.bottom))
                }
            }
        }

        // The law, stated on whatever the tool actually draws. A turned frame is a quad and the
        // canvas is the document's own AABB (196's law, which does not move with the zoom); an upright
        // frame is a rect of the **visible** canvas (`canvasBounds`, which at 适应 includes the 10 %
        // workspace band a crop may cover — 162).
        for cell in cells {
            if abs(cell.angle) > 1e-9 {
                let (detail, excess) = out(cell.doc, of: cell.canvas, tolerance: 0.5)
                XCTAssertLessThanOrEqual(excess, 0,
                                         "θ \(cell.angle)° \(cell.framing) \(cell.method): the "
                                         + "turned frame leaves the canvas — \(detail) (px)")
            } else {
                let b = cell.frameBounds, c = cell.crop
                XCTAssertTrue(c.left >= b.left - 1e-6 && c.top >= b.top - 1e-6
                              && c.right <= b.right + 1e-6 && c.bottom <= b.bottom + 1e-6,
                              "θ 0° \(cell.framing) \(cell.method): the frame leaves the visible "
                              + "canvas — crop \(c) vs bounds \(b)")
            }
        }
    }
}
